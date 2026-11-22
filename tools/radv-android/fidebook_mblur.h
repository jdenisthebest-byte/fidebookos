/*
 * FideBookOS 1.25 Hardware GPU Scroll Motion Blur & Producer Tagging for Android UI.
 * Runs natively on the AMD Radeon GPU inside radv_QueueSignalReleaseImageANDROID with:
 *   - Fork-safe dynamic /proc/self/cmdline resolution (handles Zygote <pre-initialized> transition)
 *   - 25-vector parallel shared-memory scroll velocity estimation (zero ghosting on stop frames)
 *   - 9-tap Gaussian shutter blur along detected scroll vector (preserving top bar & bottom dock)
 *   - Kernel amdgpu BO umd_metadata producer tagging so SurfaceFlinger's Liquid Glass engine
 *     identifies NexusLauncher (Taskbar + App Menu) and SystemUI (Control Center) buffers
 *   - Live runtime toggle via Android property `persist.fidebook.motion_blur`:
 *       "ui" / "1" / "" (default): NexusLauncher (App Menu), Settings, SystemUI (Control Center)
 *       "all"                    : all hardware-accelerated Vulkan apps
 *       "0" / "off"              : disabled (instant zero-overhead pass-through)
 */
#ifndef FIDEBOOK_MBLUR_H
#define FIDEBOOK_MBLUR_H

#if DETECT_OS_ANDROID

#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "radv_cmd_buffer.h"
#include "vk_common_entrypoints.h"
#include "fidebook_mblur_spirv.h"

#define FIDEBOOK_BO_META_MAGIC      0xF1DE61A5u
#define FIDEBOOK_TAG_NONE           0u
#define FIDEBOOK_TAG_LAUNCHER       1u
#define FIDEBOOK_TAG_SYSUI          2u
#define FIDEBOOK_TAG_CLIENT_TARGET  3u

extern int __system_property_get(const char *name, char *value);
void fidebook_mblur_device_finish(struct radv_device *device);
void fidebook_glass_device_finish(struct radv_device *device);
void fidebook_glass_register_image(struct radv_device *device, struct radv_image *image);
void fidebook_glass_on_image_destroy(struct radv_device *device, struct radv_image *image);
void fidebook_glass_note_sampled_image(struct radv_device *device, struct radv_image *image);
void fidebook_glass_note_sampled_id(struct radv_device *device, uint64_t img_id);
bool fidebook_is_compositor_proc(void);

struct fidebook_mblur_ctx {
   simple_mtx_t mtx;
   bool init_failed;
   uint32_t width;
   uint32_t height;
   uint32_t qf_index;
   uint64_t last_ns;
   uint32_t seq;

   VkDescriptorSetLayout est_dsl;
   VkPipelineLayout est_pl;
   VkShaderModule est_sm;
   VkPipeline est_pipe;

   VkDescriptorSetLayout blur_dsl;
   VkPipelineLayout blur_pl;
   VkShaderModule blur_sm;
   VkPipeline blur_pipe;

   VkDescriptorPool desc_pool;
   VkDescriptorSet est_ds;
   VkDescriptorSet blur_ds;

   VkBuffer vel_buf;
   VkDeviceMemory vel_mem;

   VkImage cur_img;
   VkDeviceMemory cur_mem;
   VkImageView cur_view;

   VkImage hist_img;
   VkDeviceMemory hist_mem;
   VkImageView hist_view;

   VkImage out_img;
   VkDeviceMemory out_mem;
   VkImageView out_view;

   VkCommandPool cmd_pool;
   VkCommandBuffer cmd_buf[2];
   VkFence fence[2];
   bool fence_submitted[2];
   bool hist_valid;
};

/*
 * Dynamic fork-aware process classifier.
 * Android apps fork from zygote64 and initialize Vulkan/HWUI while /proc/self/cmdline may still read
 * "zygote64" or "<pre-initialized>" prior to Process.setArgV0(). Re-read /proc/self/cmdline whenever
 * getpid() changes or until the process title settles to its final package/daemon name.
 */
static pthread_mutex_t g_fidebook_proc_mtx = PTHREAD_MUTEX_INITIALIZER;
static pid_t g_fidebook_proc_pid = -1;
static bool g_fidebook_proc_settled = false;
static int g_fidebook_proc_kind = 0;       /* 0 = other app, 1 = UI target, 2 = compositor (SurfaceFlinger) */
static uint32_t g_fidebook_proc_tag = 0;   /* FIDEBOOK_TAG_LAUNCHER / FIDEBOOK_TAG_SYSUI */

static int
fidebook_get_proc_info(uint32_t *out_tag)
{
   const char *force_comp = getenv("FIDEBOOK_FORCE_COMPOSITOR");
   if (force_comp && strcmp(force_comp, "1") == 0) {
      if (out_tag) *out_tag = 0;
      return 2;
   }
   const char *force_mblur = getenv("FIDEBOOK_FORCE_MBLUR");
   if (force_mblur && strcmp(force_mblur, "1") == 0) {
      if (out_tag) *out_tag = 0;
      return 1;
   }

   pid_t cur_pid = getpid();
   pthread_mutex_lock(&g_fidebook_proc_mtx);
   if (cur_pid != g_fidebook_proc_pid) {
      g_fidebook_proc_pid = cur_pid;
      g_fidebook_proc_settled = false;
      g_fidebook_proc_kind = 0;
      g_fidebook_proc_tag = 0;
   }
   if (!g_fidebook_proc_settled) {
      char cmd[256] = {0};
      int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
      if (fd >= 0) {
         ssize_t n = read(fd, cmd, sizeof(cmd) - 1);
         close(fd);
         if (n > 0)
            cmd[n] = '\0';
      }
      if (cmd[0] != '\0' &&
          strstr(cmd, "<pre-initialized>") == NULL &&
          strncmp(cmd, "zygote", 6) != 0 &&
          strncmp(cmd, "usap", 4) != 0) {
         if (strstr(cmd, "surfaceflinger")) {
            g_fidebook_proc_kind = 2;
            g_fidebook_proc_tag = 0;
         } else if (strstr(cmd, "hwcomposer") || strstr(cmd, "bootanimation")) {
            g_fidebook_proc_kind = 3; /* skip both mblur and compositor glass */
            g_fidebook_proc_tag = 0;
         } else if (strstr(cmd, "com.google.android.apps.nexuslauncher") ||
                    strstr(cmd, "com.android.launcher3")) {
            g_fidebook_proc_kind = 1;
            g_fidebook_proc_tag = FIDEBOOK_TAG_LAUNCHER;
         } else if (strstr(cmd, "com.android.systemui")) {
            g_fidebook_proc_kind = 1;
            g_fidebook_proc_tag = FIDEBOOK_TAG_SYSUI;
         } else if (strstr(cmd, "com.android.settings") ||
                    strstr(cmd, "org.fidebookos.")) {
            g_fidebook_proc_kind = 1;
            g_fidebook_proc_tag = 0;
         } else {
            g_fidebook_proc_kind = 0;
            g_fidebook_proc_tag = 0;
         }
         g_fidebook_proc_settled = true;
      }
   }
   int k = g_fidebook_proc_kind;
   uint32_t t = g_fidebook_proc_tag;
   pthread_mutex_unlock(&g_fidebook_proc_mtx);
   if (out_tag)
      *out_tag = t;
   return k;
}

bool
fidebook_is_compositor_proc(void)
{
   return fidebook_get_proc_info(NULL) == 2;
}

static bool
fidebook_mblur_enabled_for_process(uint32_t *out_tag)
{
   int kind = fidebook_get_proc_info(out_tag);
   if (kind >= 2)
      return false;
   const char *force_env = getenv("FIDEBOOK_FORCE_MBLUR");
   if (force_env && strcmp(force_env, "1") == 0)
      return true;

   char prop[96] = {0};
   __system_property_get("persist.fidebook.motion_blur", prop);
   if (strcmp(prop, "0") == 0 || strcmp(prop, "off") == 0 || strcmp(prop, "false") == 0)
      return false;
   if (strcmp(prop, "all") == 0)
      return true;
   return kind == 1;
}

static void
fidebook_stamp_producer_bo(struct radv_device *device, struct radv_image *image, uint32_t tag)
{
   if (!device || !image || !tag || image->fidebook_tag == tag)
      return;
   struct radeon_winsys_bo *bo = image->bindings[0].bo;
   if (!bo || !device->ws || !device->ws->buffer_get_metadata || !device->ws->buffer_set_metadata)
      return;
   struct radeon_bo_metadata md;
   memset(&md, 0, sizeof(md));
   device->ws->buffer_get_metadata(device->ws, bo, &md);
   md.metadata[56] = FIDEBOOK_BO_META_MAGIC;
   md.metadata[57] = tag;
   if (md.size_metadata < 232)
      md.size_metadata = 232;
   device->ws->buffer_set_metadata(device->ws, bo, &md);
   image->fidebook_tag = tag;
}

static uint64_t
fidebook_now_ns(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint32_t
fidebook_find_mem_type(struct radv_device *device, uint32_t type_bits, VkMemoryPropertyFlags want)
{
   const struct radv_physical_device *pdev = radv_device_physical(device);
   for (uint32_t i = 0; i < pdev->memory_properties.memoryTypeCount; i++) {
      if ((type_bits & (1u << i)) &&
          (pdev->memory_properties.memoryTypes[i].propertyFlags & want) == want)
         return i;
   }
   for (uint32_t i = 0; i < pdev->memory_properties.memoryTypeCount; i++) {
      if (type_bits & (1u << i))
         return i;
   }
   return 0;
}

static VkResult
fidebook_alloc_scratch_image(struct radv_device *device, uint32_t w, uint32_t h, VkImageUsageFlags usage,
                             VkImage *out_img, VkDeviceMemory *out_mem, VkImageView *out_view)
{
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   VkImageCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .extent = {w, h, 1},
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = usage,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
   };
   VkResult r = dt->CreateImage(dev_h, &ici, NULL, out_img);
   if (r != VK_SUCCESS)
      return r;

   VkMemoryRequirements reqs;
   dt->GetImageMemoryRequirements(dev_h, *out_img, &reqs);
   VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = reqs.size,
      .memoryTypeIndex = fidebook_find_mem_type(device, reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
   };
   r = dt->AllocateMemory(dev_h, &mai, NULL, out_mem);
   if (r != VK_SUCCESS)
      return r;

   r = dt->BindImageMemory(dev_h, *out_img, *out_mem, 0);
   if (r != VK_SUCCESS)
      return r;

   VkImageViewCreateInfo ivci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = *out_img,
      .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
   };
   return dt->CreateImageView(dev_h, &ivci, NULL, out_view);
}

static void
fidebook_mblur_free_images(struct radv_device *device, struct fidebook_mblur_ctx *ctx)
{
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   /* Scratch images may only be destroyed once no submission can read them.
    * Wait without a timeout here: freeing in-flight memory is never safe. */
   for (uint32_t s = 0; s < 2; s++) {
      if (ctx->fence_submitted[s] && ctx->fence[s] &&
          dt->WaitForFences(dev_h, 1, &ctx->fence[s], VK_TRUE, UINT64_MAX) != VK_SUCCESS)
         dt->DeviceWaitIdle(dev_h);
   }
   ctx->fence_submitted[0] = ctx->fence_submitted[1] = false;

   if (ctx->cur_view) { dt->DestroyImageView(dev_h, ctx->cur_view, NULL); ctx->cur_view = VK_NULL_HANDLE; }
   if (ctx->hist_view) { dt->DestroyImageView(dev_h, ctx->hist_view, NULL); ctx->hist_view = VK_NULL_HANDLE; }
   if (ctx->out_view) { dt->DestroyImageView(dev_h, ctx->out_view, NULL); ctx->out_view = VK_NULL_HANDLE; }

   if (ctx->cur_img) { dt->DestroyImage(dev_h, ctx->cur_img, NULL); ctx->cur_img = VK_NULL_HANDLE; }
   if (ctx->hist_img) { dt->DestroyImage(dev_h, ctx->hist_img, NULL); ctx->hist_img = VK_NULL_HANDLE; }
   if (ctx->out_img) { dt->DestroyImage(dev_h, ctx->out_img, NULL); ctx->out_img = VK_NULL_HANDLE; }

   if (ctx->cur_mem) { dt->FreeMemory(dev_h, ctx->cur_mem, NULL); ctx->cur_mem = VK_NULL_HANDLE; }
   if (ctx->hist_mem) { dt->FreeMemory(dev_h, ctx->hist_mem, NULL); ctx->hist_mem = VK_NULL_HANDLE; }
   if (ctx->out_mem) { dt->FreeMemory(dev_h, ctx->out_mem, NULL); ctx->out_mem = VK_NULL_HANDLE; }

   ctx->width = ctx->height = 0;
   ctx->hist_valid = false;
}

void
fidebook_mblur_device_finish(struct radv_device *device)
{
   fidebook_glass_device_finish(device);

   struct fidebook_mblur_ctx *ctx = (struct fidebook_mblur_ctx *)device->fidebook_mblur;
   if (!ctx)
      return;
   device->fidebook_mblur = NULL;

   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   fidebook_mblur_free_images(device, ctx);

   for (int i = 0; i < 2; i++) {
      if (ctx->fence[i])
         dt->DestroyFence(dev_h, ctx->fence[i], NULL);
   }
   if (ctx->cmd_pool)
      dt->DestroyCommandPool(dev_h, ctx->cmd_pool, NULL);
   if (ctx->vel_buf)
      dt->DestroyBuffer(dev_h, ctx->vel_buf, NULL);
   if (ctx->vel_mem)
      dt->FreeMemory(dev_h, ctx->vel_mem, NULL);
   if (ctx->desc_pool)
      dt->DestroyDescriptorPool(dev_h, ctx->desc_pool, NULL);
   if (ctx->est_pipe)
      dt->DestroyPipeline(dev_h, ctx->est_pipe, NULL);
   if (ctx->blur_pipe)
      dt->DestroyPipeline(dev_h, ctx->blur_pipe, NULL);
   if (ctx->est_sm)
      dt->DestroyShaderModule(dev_h, ctx->est_sm, NULL);
   if (ctx->blur_sm)
      dt->DestroyShaderModule(dev_h, ctx->blur_sm, NULL);
   if (ctx->est_pl)
      dt->DestroyPipelineLayout(dev_h, ctx->est_pl, NULL);
   if (ctx->blur_pl)
      dt->DestroyPipelineLayout(dev_h, ctx->blur_pl, NULL);
   if (ctx->est_dsl)
      dt->DestroyDescriptorSetLayout(dev_h, ctx->est_dsl, NULL);
   if (ctx->blur_dsl)
      dt->DestroyDescriptorSetLayout(dev_h, ctx->blur_dsl, NULL);

   simple_mtx_destroy(&ctx->mtx);
   free(ctx);
}

static bool
fidebook_mblur_ensure_ready(struct radv_device *device, struct fidebook_mblur_ctx *ctx,
                            uint32_t qf_index, uint32_t w, uint32_t h)
{
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;
   VkResult r;

   if (ctx->init_failed)
      return false;

   if (!ctx->est_pipe) {
      ctx->qf_index = qf_index;

      VkDescriptorSetLayoutBinding est_b[3] = {
         {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
      };
      VkDescriptorSetLayoutCreateInfo est_dsl_ci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 3,
         .pBindings = est_b,
      };
      if (dt->CreateDescriptorSetLayout(dev_h, &est_dsl_ci, NULL, &ctx->est_dsl) != VK_SUCCESS)
         goto fail;

      VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 8};
      VkPipelineLayoutCreateInfo est_pl_ci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &ctx->est_dsl,
         .pushConstantRangeCount = 1,
         .pPushConstantRanges = &pcr,
      };
      if (dt->CreatePipelineLayout(dev_h, &est_pl_ci, NULL, &ctx->est_pl) != VK_SUCCESS)
         goto fail;

      VkDescriptorSetLayoutBinding blur_b[4] = {
         {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
      };
      VkDescriptorSetLayoutCreateInfo blur_dsl_ci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 4,
         .pBindings = blur_b,
      };
      if (dt->CreateDescriptorSetLayout(dev_h, &blur_dsl_ci, NULL, &ctx->blur_dsl) != VK_SUCCESS)
         goto fail;

      VkPipelineLayoutCreateInfo blur_pl_ci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &ctx->blur_dsl,
         .pushConstantRangeCount = 1,
         .pPushConstantRanges = &pcr,
      };
      if (dt->CreatePipelineLayout(dev_h, &blur_pl_ci, NULL, &ctx->blur_pl) != VK_SUCCESS)
         goto fail;

      VkShaderModuleCreateInfo sm0 = {
         .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
         .codeSize = sizeof(fidebook_mblur_est_spv),
         .pCode = fidebook_mblur_est_spv,
      };
      VkShaderModuleCreateInfo sm1 = {
         .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
         .codeSize = sizeof(fidebook_mblur_apply_spv),
         .pCode = fidebook_mblur_apply_spv,
      };
      if (dt->CreateShaderModule(dev_h, &sm0, NULL, &ctx->est_sm) != VK_SUCCESS ||
          dt->CreateShaderModule(dev_h, &sm1, NULL, &ctx->blur_sm) != VK_SUCCESS)
         goto fail;

      VkComputePipelineCreateInfo cp0 = {
         .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                   VK_SHADER_STAGE_COMPUTE_BIT, ctx->est_sm, "main", NULL},
         .layout = ctx->est_pl,
      };
      VkComputePipelineCreateInfo cp1 = {
         .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                   VK_SHADER_STAGE_COMPUTE_BIT, ctx->blur_sm, "main", NULL},
         .layout = ctx->blur_pl,
      };
      if (dt->CreateComputePipelines(dev_h, VK_NULL_HANDLE, 1, &cp0, NULL, &ctx->est_pipe) != VK_SUCCESS ||
          dt->CreateComputePipelines(dev_h, VK_NULL_HANDLE, 1, &cp1, NULL, &ctx->blur_pipe) != VK_SUCCESS)
         goto fail;

      VkDescriptorPoolSize ps[2] = {
         {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 8},
         {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4},
      };
      VkDescriptorPoolCreateInfo dp_ci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
         .maxSets = 2,
         .poolSizeCount = 2,
         .pPoolSizes = ps,
      };
      if (dt->CreateDescriptorPool(dev_h, &dp_ci, NULL, &ctx->desc_pool) != VK_SUCCESS)
         goto fail;

      VkDescriptorSetLayout dsls[2] = {ctx->est_dsl, ctx->blur_dsl};
      VkDescriptorSet sets[2] = {VK_NULL_HANDLE, VK_NULL_HANDLE};
      VkDescriptorSetAllocateInfo ds_ai = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
         .descriptorPool = ctx->desc_pool,
         .descriptorSetCount = 2,
         .pSetLayouts = dsls,
      };
      if (dt->AllocateDescriptorSets(dev_h, &ds_ai, sets) != VK_SUCCESS)
         goto fail;
      ctx->est_ds = sets[0];
      ctx->blur_ds = sets[1];

      VkBufferCreateInfo bci = {
         .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
         .size = 64,
         .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
         .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      };
      if (dt->CreateBuffer(dev_h, &bci, NULL, &ctx->vel_buf) != VK_SUCCESS)
         goto fail;
      VkMemoryRequirements breqs;
      dt->GetBufferMemoryRequirements(dev_h, ctx->vel_buf, &breqs);
      VkMemoryAllocateInfo bmai = {
         .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
         .allocationSize = breqs.size,
         .memoryTypeIndex = fidebook_find_mem_type(device, breqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
      };
      if (dt->AllocateMemory(dev_h, &bmai, NULL, &ctx->vel_mem) != VK_SUCCESS ||
          dt->BindBufferMemory(dev_h, ctx->vel_buf, ctx->vel_mem, 0) != VK_SUCCESS)
         goto fail;

      VkCommandPoolCreateInfo cp_ci = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
         .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
         .queueFamilyIndex = qf_index,
      };
      if (dt->CreateCommandPool(dev_h, &cp_ci, NULL, &ctx->cmd_pool) != VK_SUCCESS)
         goto fail;

      VkCommandBufferAllocateInfo cb_ai = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
         .commandPool = ctx->cmd_pool,
         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
         .commandBufferCount = 2,
      };
      if (dt->AllocateCommandBuffers(dev_h, &cb_ai, ctx->cmd_buf) != VK_SUCCESS)
         goto fail;

      VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
      if (dt->CreateFence(dev_h, &fci, NULL, &ctx->fence[0]) != VK_SUCCESS ||
          dt->CreateFence(dev_h, &fci, NULL, &ctx->fence[1]) != VK_SUCCESS)
         goto fail;
   }

   if (ctx->qf_index != qf_index)
      return false;

   if (ctx->width != w || ctx->height != h) {
      fidebook_mblur_free_images(device, ctx);
      r = fidebook_alloc_scratch_image(device, w, h,
                                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                       &ctx->cur_img, &ctx->cur_mem, &ctx->cur_view);
      if (r != VK_SUCCESS) goto fail;
      r = fidebook_alloc_scratch_image(device, w, h,
                                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                       &ctx->hist_img, &ctx->hist_mem, &ctx->hist_view);
      if (r != VK_SUCCESS) goto fail;
      r = fidebook_alloc_scratch_image(device, w, h,
                                       VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                       &ctx->out_img, &ctx->out_mem, &ctx->out_view);
      if (r != VK_SUCCESS) goto fail;

      ctx->width = w;
      ctx->height = h;
      ctx->hist_valid = false;

      VkDescriptorImageInfo di_cur = {VK_NULL_HANDLE, ctx->cur_view, VK_IMAGE_LAYOUT_GENERAL};
      VkDescriptorImageInfo di_hist = {VK_NULL_HANDLE, ctx->hist_view, VK_IMAGE_LAYOUT_GENERAL};
      VkDescriptorImageInfo di_out = {VK_NULL_HANDLE, ctx->out_view, VK_IMAGE_LAYOUT_GENERAL};
      VkDescriptorBufferInfo db_vel = {ctx->vel_buf, 0, 64};

      VkWriteDescriptorSet writes[7] = {
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->est_ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &di_cur, NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->est_ds, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &di_hist, NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->est_ds, 2, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &db_vel, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->blur_ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &di_cur, NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->blur_ds, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &di_hist, NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->blur_ds, 2, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &db_vel, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->blur_ds, 3, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &di_out, NULL, NULL},
      };
      dt->UpdateDescriptorSets(dev_h, 7, writes, 0, NULL);
   }

   return true;

fail:
   ctx->init_failed = true;
   fidebook_mblur_free_images(device, ctx);
   return false;
}

VKAPI_ATTR VkResult VKAPI_CALL
radv_QueueSignalReleaseImageANDROID(VkQueue _queue, uint32_t waitSemaphoreCount,
                                    const VkSemaphore *pWaitSemaphores, VkImage _image,
                                    int *pNativeFenceFd)
{
   VK_FROM_HANDLE(radv_queue, queue, _queue);
   VK_FROM_HANDLE(radv_image, image, _image);
   struct radv_device *device = radv_queue_device(queue);

   uint32_t prod_tag = 0;
   bool mblur_on = fidebook_mblur_enabled_for_process(&prod_tag);

   /* Always stamp NexusLauncher / SystemUI swapchain BOs so SurfaceFlinger Liquid Glass works
    * even when motion blur is toggled off or when the taskbar buffer height < 256 px. */
   if (image && prod_tag != 0)
      fidebook_stamp_producer_bo(device, image, prod_tag);

   if (!mblur_on ||
       waitSemaphoreCount == 0 ||
       !image ||
       queue->state.qf != RADV_QUEUE_GENERAL ||
       (image->vk.format != VK_FORMAT_R8G8B8A8_UNORM && image->vk.format != VK_FORMAT_B8G8R8A8_UNORM) ||
       image->vk.samples != VK_SAMPLE_COUNT_1_BIT ||
       image->vk.extent.width < 256 || image->vk.extent.height < 256 ||
       image->vk.extent.width > 4096 || image->vk.extent.height > 4096) {
      return vk_common_QueueSignalReleaseImageANDROID(_queue, waitSemaphoreCount, pWaitSemaphores, _image, pNativeFenceFd);
   }

   if (!device->fidebook_mblur) {
      struct fidebook_mblur_ctx *nctx = calloc(1, sizeof(*nctx));
      if (!nctx)
         return vk_common_QueueSignalReleaseImageANDROID(_queue, waitSemaphoreCount, pWaitSemaphores, _image, pNativeFenceFd);
      simple_mtx_init(&nctx->mtx, mtx_plain);
      device->fidebook_mblur = nctx;
   }

   struct fidebook_mblur_ctx *ctx = (struct fidebook_mblur_ctx *)device->fidebook_mblur;
   simple_mtx_lock(&ctx->mtx);

   uint32_t w = image->vk.extent.width;
   uint32_t h = image->vk.extent.height;
   if (!fidebook_mblur_ensure_ready(device, ctx, queue->vk.queue_family_index, w, h)) {
      simple_mtx_unlock(&ctx->mtx);
      return vk_common_QueueSignalReleaseImageANDROID(_queue, waitSemaphoreCount, pWaitSemaphores, _image, pNativeFenceFd);
   }

   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   if (queue->vk.anb_semaphore == VK_NULL_HANDLE) {
      const VkExportSemaphoreCreateInfo exp_info = {
         .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
         .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
      };
      const VkSemaphoreCreateInfo sem_ci = {
         .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
         .pNext = &exp_info,
      };
      if (dt->CreateSemaphore(dev_h, &sem_ci, NULL, &queue->vk.anb_semaphore) != VK_SUCCESS) {
         simple_mtx_unlock(&ctx->mtx);
         return vk_common_QueueSignalReleaseImageANDROID(_queue, waitSemaphoreCount, pWaitSemaphores, _image, pNativeFenceFd);
      }
   }

   uint32_t slot = ctx->seq & 1;

   if (ctx->fence_submitted[slot]) {
      /* A timeout or device loss means the command buffer may still be in
       * flight: never reset it. Nothing of this present has been consumed
       * yet, so pass straight through to the stock release path. */
      if (dt->WaitForFences(dev_h, 1, &ctx->fence[slot], VK_TRUE, 1000000000ULL) != VK_SUCCESS) {
         simple_mtx_unlock(&ctx->mtx);
         return vk_common_QueueSignalReleaseImageANDROID(_queue, waitSemaphoreCount, pWaitSemaphores, _image, pNativeFenceFd);
      }
      dt->ResetFences(dev_h, 1, &ctx->fence[slot]);
      ctx->fence_submitted[slot] = false;
   }

   uint64_t now = fidebook_now_ns();
   bool active_scroll_window = ctx->hist_valid && (now - ctx->last_ns) <= 95000000ULL;
   ctx->last_ns = now;
   ctx->seq++;

   VkCommandBuffer cb = ctx->cmd_buf[slot];
   dt->ResetCommandBuffer(cb, 0);
   VkCommandBufferBeginInfo bi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   dt->BeginCommandBuffer(cb, &bi);

   VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
   VkImageCopy copy_region = {
      .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .extent = {w, h, 1},
   };

   if (!active_scroll_window) {
      VkImageMemoryBarrier b_pre[2] = {
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
          VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, _image, range},
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          0, VK_ACCESS_TRANSFER_WRITE_BIT,
          VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->hist_img, range},
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 2, b_pre);
      dt->CmdCopyImage(cb, _image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       ctx->hist_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_region);
      VkImageMemoryBarrier b_post[2] = {
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_MEMORY_READ_BIT,
          VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, _image, range},
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->hist_img, range},
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             0, 0, NULL, 0, NULL, 2, b_post);
      ctx->hist_valid = true;
   } else {
      VkImageMemoryBarrier b1[2] = {
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
          VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, _image, range},
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          0, VK_ACCESS_TRANSFER_WRITE_BIT,
          VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->cur_img, range},
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 2, b1);
      dt->CmdCopyImage(cb, _image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       ctx->cur_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_region);

      VkImageMemoryBarrier b2[2] = {
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->cur_img, range},
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          0, VK_ACCESS_SHADER_WRITE_BIT,
          VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->out_img, range},
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             0, 0, NULL, 0, NULL, 2, b2);

      int32_t dims[2] = {(int32_t)w, (int32_t)h};
      dt->CmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->est_pipe);
      dt->CmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->est_pl, 0, 1, &ctx->est_ds, 0, NULL);
      dt->CmdPushConstants(cb, ctx->est_pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, dims);
      dt->CmdDispatch(cb, 1, 1, 1);

      VkMemoryBarrier mb_vel = {
         .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
         .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
         .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             0, 1, &mb_vel, 0, NULL, 0, NULL);

      dt->CmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->blur_pipe);
      dt->CmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->blur_pl, 0, 1, &ctx->blur_ds, 0, NULL);
      dt->CmdPushConstants(cb, ctx->blur_pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, dims);
      dt->CmdDispatch(cb, (w + 15) / 16, (h + 15) / 16, 1);

      VkImageMemoryBarrier b3[2] = {
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
          VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->out_img, range},
         {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
          VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
          VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, _image, range},
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 2, b3);
      dt->CmdCopyImage(cb, ctx->out_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       _image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_region);

      VkImageMemoryBarrier b4 = {
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT,
         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, _image, range,
      };
      dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             0, 0, NULL, 0, NULL, 1, &b4);
   }

   dt->EndCommandBuffer(cb);

   STACK_ARRAY(VkSemaphoreSubmitInfo, wait_infos, waitSemaphoreCount);
   for (uint32_t i = 0; i < waitSemaphoreCount; i++) {
      wait_infos[i] = (VkSemaphoreSubmitInfo){
         .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
         .semaphore = pWaitSemaphores[i],
         .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
      };
   }
   const VkCommandBufferSubmitInfo cb_si = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
      .commandBuffer = cb,
   };
   const VkSemaphoreSubmitInfo sig_info = {
      .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
      .semaphore = queue->vk.anb_semaphore,
      .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
   };
   const VkSubmitInfo2 sub2 = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
      .waitSemaphoreInfoCount = waitSemaphoreCount,
      .pWaitSemaphoreInfos = wait_infos,
      .commandBufferInfoCount = 1,
      .pCommandBufferInfos = &cb_si,
      .signalSemaphoreInfoCount = 1,
      .pSignalSemaphoreInfos = &sig_info,
   };

   VkResult result = dt->QueueSubmit2(_queue, 1, &sub2, ctx->fence[slot]);
   STACK_ARRAY_FINISH(wait_infos);
   if (result != VK_SUCCESS) {
      simple_mtx_unlock(&ctx->mtx);
      return result;
   }
   ctx->fence_submitted[slot] = true;
   simple_mtx_unlock(&ctx->mtx);

   const VkSemaphoreGetFdInfoKHR get_fd = {
      .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
      .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
      .semaphore = queue->vk.anb_semaphore,
   };
   return dt->GetSemaphoreFdKHR(dev_h, &get_fd, pNativeFenceFd);
}

#include "fidebook_liquid_glass.h"

#endif /* DETECT_OS_ANDROID */
#endif /* FIDEBOOK_MBLUR_H */
