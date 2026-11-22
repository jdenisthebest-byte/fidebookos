#!/usr/bin/env python3
"""Run from the Mesa source root; idempotent.

1. YV12 AndroidHardwareBuffer import:
   RADV's own vkGetAndroidHardwareBufferPropertiesANDROID returns format UNDEFINED / externalFormat 0 for a YV12 buffer, so Skia fails
   ("Failed to create valid YCbCr conversion information") and SurfaceFlinger aborts. Renaming it makes the entrypoint table fall back to
   the common vk_common_ implementation, which reports YV12 as external format G8_B8_R8_3PLANE_420.

2. Disable TMZ protected memory:
   FideBookOS Android's minigbm backend cannot allocate TMZ-protected buffers. Disable RADV's TMZ capability so Android does not select
   protected rendering paths that the allocator cannot satisfy.

3. Multi-queue hardware GFX context multiplexing (queueCount = 4 on RADV_QUEUE_GENERAL):
   Android 17 HWUI (ro.hwui.use_vulkan=true) asserts queueFamilyProperties.queueCount >= 2 on the graphics queue family. Each secondary
   RADV_QUEUE_GENERAL queue (idx > 0) creates its own dedicated kernel amdgpu_ctx entity scheduled natively onto GFX ring 0.

4. FideBookOS 1.25 Hardware GPU Scroll Motion Blur & Liquid Glass Cross-Window Refraction:
   - Velocity-gated 9-tap Gaussian shutter motion blur on swapchain release (fork-safe post-Zygote detection, persist.fidebook.motion_blur).
   - Cross-window Snell's-law Liquid Glass refraction, chromatic dispersion, vibrancy & Fresnel rim highlights in SurfaceFlinger for
     Taskbar, App Menu, and Control Center (persist.fidebook.liquid_glass, Kyant0/AndroidLiquidGlass + styropyr0/Prismal optics)."""
import sys

P = 'src/amd/vulkan/radv_android.c'
OLD = 'VkResult\nradv_GetAndroidHardwareBufferPropertiesANDROID('
NEW = 'static VkResult __attribute__((unused))\nfidebook_unused_radv_GetAndroidHardwareBufferPropertiesANDROID('
PREV_GBOS = 'static VkResult __attribute__((unused))\ngbos_unused_radv_GetAndroidHardwareBufferPropertiesANDROID('

ANB_USAGE_OLD = '   VkImageCreateInfo updated_base_info = *base_info;'
ANB_USAGE_NEW = '''   VkImageCreateInfo updated_base_info = *base_info;
   updated_base_info.usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;'''

WSI_USAGE_OLD = '''   if (!vk_image_is_android_native_buffer_alias(&image->vk) || !create_info)
      return VK_ERROR_INVALID_EXTERNAL_HANDLE;'''
WSI_USAGE_NEW = '''   if (!vk_image_is_android_native_buffer_alias(&image->vk) || !create_info)
      return VK_ERROR_INVALID_EXTERNAL_HANDLE;
   create_info->usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
   image->vk.usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;'''

AHB_IMPORT_OLD = '''      assert(mem->image->vk.android_deferred_create_info);
      struct radv_image_create_info create_info = {
         .vk_info = mem->image->vk.android_deferred_create_info,
         .no_metadata_planes = true,
         .bo_metadata = &metadata,
      };'''
AHB_IMPORT_PREV = '''      assert(mem->image->vk.android_deferred_create_info);
      mem->image->vk.android_deferred_create_info->usage |=
         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      mem->image->vk.usage |=
         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      {
         AHardwareBuffer_Desc fb_desc;
         AHardwareBuffer_describe(buffer, &fb_desc);
         if (fb_desc.usage & 0x1000ULL) {
            mem->image->fidebook_tag = 3u; /* AHARDWAREBUFFER_USAGE_COMPOSER_CLIENT_TARGET */
         } else if (metadata.size_metadata >= 232 && metadata.metadata[56] == 0xF1DE61A5u) {
            mem->image->fidebook_tag = metadata.metadata[57];
         }
      }
      struct radv_image_create_info create_info = {
         .vk_info = mem->image->vk.android_deferred_create_info,
         .no_metadata_planes = true,
         .bo_metadata = &metadata,
      };'''
AHB_IMPORT_NEW = '''      assert(mem->image->vk.android_deferred_create_info);
      mem->image->vk.android_deferred_create_info->usage |=
         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      mem->image->vk.usage |=
         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      {
         extern void fidebook_glass_register_image(struct radv_device *device, struct radv_image *image);
         AHardwareBuffer_Desc fb_desc;
         AHardwareBuffer_describe(buffer, &fb_desc);
         mem->fidebook_is_ahb = 1;
         mem->image->fidebook_is_ahb = 1;
         mem->image->fidebook_protected = (fb_desc.usage & (1ULL << 14)) != 0;
         if (metadata.size_metadata >= 232 && metadata.metadata[56] == 0xF1DE61A5u) {
            mem->fidebook_ahb_tag = metadata.metadata[57];
            mem->image->fidebook_tag = metadata.metadata[57];
         } else if (fb_desc.usage & 0x1000ULL) {
            mem->fidebook_ahb_tag = 3u; /* AHARDWAREBUFFER_USAGE_COMPOSER_CLIENT_TARGET */
            mem->image->fidebook_tag = 3u;
         }
         fidebook_glass_register_image(device, mem->image);
      }
      struct radv_image_create_info create_info = {
         .vk_info = mem->image->vk.android_deferred_create_info,
         .no_metadata_planes = true,
         .bo_metadata = &metadata,
      };'''

AHB_MEM_PRE_OLD = '''   uint64_t alloc_size = 0;
   VkResult result = radv_bo_from_fd(device, dma_buf, priority, mem, &alloc_size);
   if (result != VK_SUCCESS)
      return result;'''
AHB_MEM_PRE_NEW = '''   uint64_t alloc_size = 0;
   VkResult result = radv_bo_from_fd(device, dma_buf, priority, mem, &alloc_size);
   if (result != VK_SUCCESS)
      return result;
   {
      struct radeon_bo_metadata fb_md;
      AHardwareBuffer_Desc fb_d;
      memset(&fb_md, 0, sizeof(fb_md));
      device->ws->buffer_get_metadata(device->ws, mem->bo, &fb_md);
      AHardwareBuffer_describe(buffer, &fb_d);
      mem->fidebook_is_ahb = 1;
      if (fb_md.size_metadata >= 232 && fb_md.metadata[56] == 0xF1DE61A5u)
         mem->fidebook_ahb_tag = fb_md.metadata[57];
      else if (fb_d.usage & 0x1000ULL)
         mem->fidebook_ahb_tag = 3u;
   }'''

DMH_P = 'src/amd/vulkan/radv_device_memory.h'
DMH_OLD = '''   uint32_t heap_index;
   uint64_t alloc_size;'''
DMH_NEW = '''   uint32_t heap_index;
   uint32_t fidebook_ahb_tag;
   uint8_t fidebook_is_ahb;
   uint64_t alloc_size;'''

MBLUR_INC_OLD = '''bool
radv_android_gralloc_supports_format(VkFormat format, VkImageUsageFlags2KHR usage)'''
MBLUR_INC_NEW = '''#include "fidebook_mblur.h"

bool
radv_android_gralloc_supports_format(VkFormat format, VkImageUsageFlags2KHR usage)'''

DH_P = 'src/amd/vulkan/radv_device.h'
DH_OLD = '''   struct radv_queue *queues;
   uint32_t queue_count;'''
DH_PREV = '''   struct radv_queue *queues;
   uint32_t queue_count;
   void *fidebook_mblur;'''
DH_NEW = '''   struct radv_queue *queues;
   uint32_t queue_count;
   void *fidebook_mblur;
   void *fidebook_glass;'''

DC_P = 'src/amd/vulkan/radv_device.c'
DC_OLD = '''   for (unsigned i = 0; i < device->queue_count; i++)
      radv_queue_finish(&device->queues[i]);'''
DC_NEW = '''#if DETECT_OS_ANDROID
   extern void fidebook_mblur_device_finish(struct radv_device *device);
   fidebook_mblur_device_finish(device);
#endif
   for (unsigned i = 0; i < device->queue_count; i++)
      radv_queue_finish(&device->queues[i]);'''

IH_P = 'src/amd/vulkan/radv_image.h'
IH_OLD = '''   unsigned queue_family_mask;
   bool exclusive;'''
IH_PREV = '''   unsigned queue_family_mask;
   uint32_t fidebook_tag;
   bool exclusive;'''
IH_NEW = '''   unsigned queue_family_mask;
   uint32_t fidebook_tag;
   uint8_t fidebook_is_ahb;
   uint8_t fidebook_protected;
   uint64_t fidebook_img_id;
   bool exclusive;'''

IC_P = 'src/amd/vulkan/radv_image.c'
IC_CREATE_OLD = '''   return radv_image_create(_device,
                            &(struct radv_image_create_info){
                               .vk_info = pCreateInfo,
                               .scanout = scanout,
                               .prime_blit_src = prime_blit_src,
                            },
                            pAllocator, pImage, false);'''
IC_CREATE_PREV = '''   VkResult fb_res = radv_image_create(_device,
                            &(struct radv_image_create_info){
                               .vk_info = pCreateInfo,
                               .scanout = scanout,
                               .prime_blit_src = prime_blit_src,
                            },
                            pAllocator, pImage, false);
#if DETECT_OS_ANDROID
   if (fb_res == VK_SUCCESS && pImage && *pImage) {
      const char *t_env = getenv("FIDEBOOK_TEST_NEXT_TAG");
      if (t_env && t_env[0] >= '1' && t_env[0] <= '3')
         radv_image_from_handle(*pImage)->fidebook_tag = (uint32_t)(t_env[0] - '0');
   }
#endif
   return fb_res;'''
IC_CREATE_NEW = '''   VkImageCreateInfo fb_ci_local;
   const VkImageCreateInfo *fb_ci_ptr = pCreateInfo;
#if DETECT_OS_ANDROID
   extern bool fidebook_is_compositor_proc(void);
   extern void fidebook_glass_register_image(struct radv_device *device, struct radv_image *image);
   if (pCreateInfo && pCreateInfo->imageType == VK_IMAGE_TYPE_2D &&
       pCreateInfo->samples == VK_SAMPLE_COUNT_1_BIT &&
       (pCreateInfo->format == VK_FORMAT_R8G8B8A8_UNORM || pCreateInfo->format == VK_FORMAT_B8G8R8A8_UNORM) &&
       (fidebook_is_compositor_proc() || getenv("FIDEBOOK_TEST_NEXT_TAG") != NULL)) {
      fb_ci_local = *pCreateInfo;
      fb_ci_local.usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      fb_ci_ptr = &fb_ci_local;
   }
#endif
   VkResult fb_res = radv_image_create(_device,
                            &(struct radv_image_create_info){
                               .vk_info = fb_ci_ptr,
                               .scanout = scanout,
                               .prime_blit_src = prime_blit_src,
                            },
                            pAllocator, pImage, false);
#if DETECT_OS_ANDROID
   if (fb_res == VK_SUCCESS && pImage && *pImage) {
      const char *t_env = getenv("FIDEBOOK_TEST_NEXT_TAG");
      if (t_env && t_env[0] >= '1' && t_env[0] <= '4') {
         struct radv_image *fb_im = radv_image_from_handle(*pImage);
         fb_im->fidebook_is_ahb = 1;
         fb_im->fidebook_tag = (t_env[0] == '4') ? 0u : (uint32_t)(t_env[0] - '0');
         fidebook_glass_register_image(device, fb_im);
      }
   }
#endif
   return fb_res;'''

IC_BIND_OLD = '''      const uint64_t addr = radv_buffer_get_va(mem->bo);

      radv_bind_image_memory(device, image, bind_idx, mem->bo, addr, offset, reqs.memoryRequirements.size);'''
IC_BIND_NEW = '''      const uint64_t addr = radv_buffer_get_va(mem->bo);

      radv_bind_image_memory(device, image, bind_idx, mem->bo, addr, offset, reqs.memoryRequirements.size);
#if DETECT_OS_ANDROID
      if (mem->fidebook_is_ahb) {
         extern void fidebook_glass_register_image(struct radv_device *device, struct radv_image *image);
         image->fidebook_is_ahb = 1;
         if (mem->fidebook_ahb_tag && !image->fidebook_tag)
            image->fidebook_tag = mem->fidebook_ahb_tag;
         fidebook_glass_register_image(device, image);
      }
#endif'''

IC_DESTROY_OLD = '''   if (!image)
      return;

   radv_destroy_image(device, pAllocator, image);'''
IC_DESTROY_NEW = '''   if (!image)
      return;

#if DETECT_OS_ANDROID
   extern void fidebook_glass_on_image_destroy(struct radv_device *device, struct radv_image *image);
   fidebook_glass_on_image_destroy(device, image);
#endif
   radv_destroy_image(device, pAllocator, image);'''

CBH_P = 'src/amd/vulkan/radv_cmd_buffer.h'
CBH_OLD = '''   VkCommandBufferUsageFlags usage_flags;'''
CBH_NEW = '''   VkCommandBufferUsageFlags usage_flags;
   struct radv_image *fidebook_client_target;'''

CBC_P = 'src/amd/vulkan/radv_cmd_buffer.c'
CBC_RESET_OLD = '''   vk_command_buffer_reset(&cmd_buffer->vk);'''
CBC_RESET_NEW = '''   vk_command_buffer_reset(&cmd_buffer->vk);
   cmd_buffer->fidebook_client_target = NULL;'''

CBC_BEGIN_CB_OLD = '''   vk_command_buffer_begin(&cmd_buffer->vk, pBeginInfo);'''
CBC_BEGIN_CB_NEW = '''   vk_command_buffer_begin(&cmd_buffer->vk, pBeginInfo);
   cmd_buffer->fidebook_client_target = NULL;'''

CBC_BEGIN_RENDER_OLD = '''   VK_FROM_HANDLE(radv_cmd_buffer, cmd_buffer, commandBuffer);

   /* From the Vulkan spec 1.4.358:'''
CBC_BEGIN_RENDER_PREV = '''   VK_FROM_HANDLE(radv_cmd_buffer, cmd_buffer, commandBuffer);
#if DETECT_OS_ANDROID
   if (pRenderingInfo && pRenderingInfo->colorAttachmentCount > 0 &&
       pRenderingInfo->pColorAttachments[0].imageView != VK_NULL_HANDLE) {
      VK_FROM_HANDLE(radv_image_view, fb_iv, pRenderingInfo->pColorAttachments[0].imageView);
      if (fb_iv && fb_iv->image && fb_iv->image->fidebook_tag == 3u)
         cmd_buffer->fidebook_client_target = fb_iv->image;
   }
#endif

   /* From the Vulkan spec 1.4.358:'''
CBC_BEGIN_RENDER_NEW = '''   VK_FROM_HANDLE(radv_cmd_buffer, cmd_buffer, commandBuffer);
#if DETECT_OS_ANDROID
   if (pRenderingInfo && pRenderingInfo->colorAttachmentCount > 0 &&
       pRenderingInfo->pColorAttachments[0].imageView != VK_NULL_HANDLE) {
      extern bool fidebook_is_compositor_proc(void);
      VK_FROM_HANDLE(radv_image_view, fb_iv, pRenderingInfo->pColorAttachments[0].imageView);
      if (fb_iv && fb_iv->image) {
         struct radv_image *fb_im = fb_iv->image;
         if (fb_im->fidebook_tag == 3u ||
             (fidebook_is_compositor_proc() && fb_im->fidebook_is_ahb &&
              fb_im->vk.extent.width >= 800 && fb_im->vk.extent.height >= 600 &&
              (fb_im->vk.format == VK_FORMAT_R8G8B8A8_UNORM || fb_im->vk.format == VK_FORMAT_B8G8R8A8_UNORM))) {
            cmd_buffer->fidebook_client_target = fb_im;
         }
      }
   }
#endif

   /* From the Vulkan spec 1.4.358:'''

CBC_BIND_DS_OLD = '''      if (!set)
         continue;

      /* If the set is already bound we only need to update the'''
CBC_BIND_DS_NEW = '''      if (!set)
         continue;
#if DETECT_OS_ANDROID
      if (bind_point == VK_PIPELINE_BIND_POINT_GRAPHICS && set->header.fidebook_sampled_id) {
         extern void fidebook_glass_note_sampled_id(struct radv_device *device, uint64_t img_id);
         fidebook_glass_note_sampled_id(device, set->header.fidebook_sampled_id);
      }
#endif

      /* If the set is already bound we only need to update the'''

DSH_P = 'src/amd/vulkan/radv_descriptor_set.h'
DSH_OLD = '''   uint32_t *mapped_ptr;
   struct radv_descriptor_range *dynamic_descriptors;
};'''
DSH_NEW = '''   uint32_t *mapped_ptr;
   struct radv_descriptor_range *dynamic_descriptors;
   uint64_t fidebook_sampled_id;
};'''

DSC_P = 'src/amd/vulkan/radv_descriptor_set.c'
DSC_IMPL_OLD = '''      ptr += binding_layout->size * writeset->dstArrayElement / 4;
      for (j = 0; j < writeset->descriptorCount; ++j) {'''
DSC_IMPL_NEW = '''#if DETECT_OS_ANDROID
      if ((writeset->descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ||
           writeset->descriptorType == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE) && writeset->pImageInfo) {
         extern void fidebook_glass_note_sampled_image(struct radv_device *device, struct radv_image *image);
         for (j = 0; j < writeset->descriptorCount; ++j) {
            if (writeset->pImageInfo[j].imageView != VK_NULL_HANDLE) {
               VK_FROM_HANDLE(radv_image_view, fb_iv, writeset->pImageInfo[j].imageView);
               if (fb_iv && fb_iv->image && fb_iv->image->fidebook_is_ahb) {
                  set->header.fidebook_sampled_id = fb_iv->image->fidebook_img_id;
                  fidebook_glass_note_sampled_image(device, fb_iv->image);
               }
            }
         }
      }
#endif
      ptr += binding_layout->size * writeset->dstArrayElement / 4;
      for (j = 0; j < writeset->descriptorCount; ++j) {'''

DSC_OLD = '''   radv_update_descriptor_sets_impl(device, NULL, VK_NULL_HANDLE, descriptorWriteCount, pDescriptorWrites,
                                    descriptorCopyCount, pDescriptorCopies);'''
DSC_PREV = '''#if DETECT_OS_ANDROID
   extern void fidebook_glass_note_sampled_image(struct radv_device *device, struct radv_image *image);
   for (uint32_t fb_i = 0; fb_i < descriptorWriteCount; fb_i++) {
      const VkWriteDescriptorSet *fb_w = &pDescriptorWrites[fb_i];
      if ((fb_w->descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ||
           fb_w->descriptorType == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE) && fb_w->pImageInfo) {
         for (uint32_t fb_j = 0; fb_j < fb_w->descriptorCount; fb_j++) {
            if (fb_w->pImageInfo[fb_j].imageView != VK_NULL_HANDLE) {
               VK_FROM_HANDLE(radv_image_view, fb_iv, fb_w->pImageInfo[fb_j].imageView);
               if (fb_iv && fb_iv->image && fb_iv->image->fidebook_tag)
                  fidebook_glass_note_sampled_image(device, fb_iv->image);
            }
         }
      }
   }
#endif
   radv_update_descriptor_sets_impl(device, NULL, VK_NULL_HANDLE, descriptorWriteCount, pDescriptorWrites,
                                    descriptorCopyCount, pDescriptorCopies);'''
DSC_NEW = '''   radv_update_descriptor_sets_impl(device, NULL, VK_NULL_HANDLE, descriptorWriteCount, pDescriptorWrites,
                                    descriptorCopyCount, pDescriptorCopies);'''

TMZ_P = 'src/amd/vulkan/radv_physical_device.c'
TMZ_OLD = '''bool
radv_tmz_enabled(const struct radv_physical_device *pdev)
{
   const struct radv_instance *instance = radv_physical_device_instance(pdev);

   /* TODO: Fix GFX/SDMA rings hang on GFX9 APUs. */
   const bool radv_supports_tmz = pdev->info.gfx_level >= GFX10 || pdev->info.family == CHIP_VEGA10;

   return pdev->info.has_tmz_support && radv_supports_tmz && !(RADV_DEBUG(instance, NO_TMZ));
}'''
TMZ_NEW = '''bool
radv_tmz_enabled(const struct radv_physical_device *pdev)
{
    (void)pdev;
   return false;
}'''
TMZ_PREVIOUS = '''bool
radv_tmz_enabled(const struct radv_physical_device *pdev)
{
   return false;
}'''

GFX_QCOUNT_OLD = '''         *pQueueFamilyProperties[idx] = (VkQueueFamilyProperties){
            .queueFlags = gfx_flags | radv_queue_family_protected_flag(pdev, RADV_QUEUE_GENERAL),
            .queueCount = 1,
            .timestampValidBits = 64,
            .minImageTransferGranularity = (VkExtent3D){1, 1, 1},
         };'''
GFX_QCOUNT_NEW = '''         *pQueueFamilyProperties[idx] = (VkQueueFamilyProperties){
            .queueFlags = gfx_flags | radv_queue_family_protected_flag(pdev, RADV_QUEUE_GENERAL),
            .queueCount = 4,
            .timestampValidBits = 64,
            .minImageTransferGranularity = (VkExtent3D){1, 1, 1},
         };'''

QH_P = 'src/amd/vulkan/radv_queue.h'
QH_OLD = '''   uint64_t last_shader_upload_seq;
   bool sqtt_present;

   VkCommandPool utrace_command_pool;
};'''
QH_NEW = '''   uint64_t last_shader_upload_seq;
   bool sqtt_present;
   bool dedicated_hw_ctx;

   VkCommandPool utrace_command_pool;
};

static inline uint32_t
radv_queue_hw_ring_index(const struct radv_queue *queue)
{
   return queue->state.qf == RADV_QUEUE_GENERAL ? 0 : queue->vk.index_in_family;
}'''

QC_P = 'src/amd/vulkan/radv_queue.c'
QC_SUBMIT1_OLD = '''   struct radv_winsys_submit_info submit = {
      .ip_type = radv_queue_ring(queue),
      .queue_index = queue->vk.index_in_family,
      .secure = submission->is_protected,
   };'''
QC_SUBMIT1_NEW = '''   struct radv_winsys_submit_info submit = {
      .ip_type = radv_queue_ring(queue),
      .queue_index = radv_queue_hw_ring_index(queue),
      .secure = submission->is_protected,
   };'''

QC_SUBMIT2_OLD = '''   struct radv_winsys_submit_info submit = {
      .ip_type = radv_queue_ring(queue),
      .queue_index = queue->vk.index_in_family,
      .cs_array = cs_array,'''
QC_SUBMIT2_NEW = '''   struct radv_winsys_submit_info submit = {
      .ip_type = radv_queue_ring(queue),
      .queue_index = radv_queue_hw_ring_index(queue),
      .cs_array = cs_array,'''

QC_SUBMIT3_OLD = '''   struct radv_winsys_submit_info submit = {
      .ip_type = radv_queue_ring(queue),
      .queue_index = queue->vk.index_in_family,
      .cs_array = &cs,
      .cs_count = 1,
   };'''
QC_SUBMIT3_NEW = '''   struct radv_winsys_submit_info submit = {
      .ip_type = radv_queue_ring(queue),
      .queue_index = radv_queue_hw_ring_index(queue),
      .cs_array = &cs,
      .cs_count = 1,
   };'''

QC_INIT_OLD = '''   if (queue->state.qf == RADV_QUEUE_VIDEO_ENC && device->hw_vcn_enc_ctx)
      queue->hw_ctx = device->hw_vcn_enc_ctx;
   else
      queue->hw_ctx = device->hw_ctx[queue->priority];

   VkResult result = vk_queue_init(&queue->vk, &device->vk, create_info, idx);
   if (result != VK_SUCCESS)
      return result;'''
QC_INIT_NEW = '''   queue->dedicated_hw_ctx = false;
   if (queue->state.qf == RADV_QUEUE_VIDEO_ENC && device->hw_vcn_enc_ctx) {
      queue->hw_ctx = device->hw_vcn_enc_ctx;
   } else if (queue->state.qf == RADV_QUEUE_GENERAL && idx > 0) {
      VkResult ctx_result = device->ws->ctx_create(device->ws, queue->priority, &queue->hw_ctx);
      if (ctx_result != VK_SUCCESS)
         return ctx_result;
      queue->dedicated_hw_ctx = true;
   } else {
      queue->hw_ctx = device->hw_ctx[queue->priority];
   }

   VkResult result = vk_queue_init(&queue->vk, &device->vk, create_info, idx);
   if (result != VK_SUCCESS) {
      if (queue->dedicated_hw_ctx) {
         device->ws->ctx_destroy(queue->hw_ctx);
         queue->hw_ctx = NULL;
         queue->dedicated_hw_ctx = false;
      }
      return result;
   }'''

QC_FAIL_OLD = '''fail:
   vk_queue_finish(&queue->vk);
   return result;
}'''
QC_FAIL_NEW = '''fail:
   vk_queue_finish(&queue->vk);
   if (queue->dedicated_hw_ctx) {
      device->ws->ctx_destroy(queue->hw_ctx);
      queue->hw_ctx = NULL;
      queue->dedicated_hw_ctx = false;
   }
   return result;
}'''

QC_FINI_OLD = '''   radv_queue_state_finish(&queue->state, device);
   vk_queue_finish(&queue->vk);
}'''
QC_FINI_NEW = '''   radv_queue_state_finish(&queue->state, device);
   vk_queue_finish(&queue->vk);
   if (queue->dedicated_hw_ctx) {
      device->ws->ctx_destroy(queue->hw_ctx);
      queue->hw_ctx = NULL;
      queue->dedicated_hw_ctx = false;
   }
}'''

QDBG_P = 'src/amd/vulkan/tools/radv_debug_hang.c'
QDBG_OLD1 = '   if (!ws->ctx_wait_idle(queue->hw_ctx, ring, queue->vk.index_in_family))'
QDBG_NEW1 = '   if (!ws->ctx_wait_idle(queue->hw_ctx, ring, radv_queue_hw_ring_index(queue)))'
QDBG_OLD2 = '   ws->ctx_wait_idle(queue->hw_ctx, ring, queue->vk.index_in_family);'
QDBG_NEW2 = '   ws->ctx_wait_idle(queue->hw_ctx, ring, radv_queue_hw_ring_index(queue));'


def patch_once(path, old, new, previous=None):
    source = open(path).read()
    if previous and previous in source:
        open(path, 'w').write(source.replace(previous, new, 1))
        print('updated patch:', path)
    elif new in source:
        print('already patched:', path)
    elif source.count(old) != 1:
        sys.exit(f'{path}: anchor found {source.count(old)} times:\n{old}')
    else:
        open(path, 'w').write(source.replace(old, new, 1))
        print('patched:', path)


patch_once(P, OLD, NEW, PREV_GBOS)
patch_once(P, ANB_USAGE_OLD, ANB_USAGE_NEW)
patch_once(P, WSI_USAGE_OLD, WSI_USAGE_NEW)
patch_once(P, AHB_MEM_PRE_OLD, AHB_MEM_PRE_NEW)
patch_once(P, AHB_IMPORT_OLD, AHB_IMPORT_NEW, AHB_IMPORT_PREV)
patch_once(P, MBLUR_INC_OLD, MBLUR_INC_NEW)
patch_once(DMH_P, DMH_OLD, DMH_NEW)
patch_once(DH_P, DH_OLD, DH_NEW, DH_PREV)
patch_once(DC_P, DC_OLD, DC_NEW)
patch_once(IH_P, IH_OLD, IH_NEW, IH_PREV)
patch_once(IC_P, IC_CREATE_OLD, IC_CREATE_NEW, IC_CREATE_PREV)
patch_once(IC_P, IC_BIND_OLD, IC_BIND_NEW)
patch_once(IC_P, IC_DESTROY_OLD, IC_DESTROY_NEW)
patch_once(CBH_P, CBH_OLD, CBH_NEW)
patch_once(CBC_P, CBC_RESET_OLD, CBC_RESET_NEW)
patch_once(CBC_P, CBC_BEGIN_CB_OLD, CBC_BEGIN_CB_NEW)
patch_once(CBC_P, CBC_BEGIN_RENDER_OLD, CBC_BEGIN_RENDER_NEW, CBC_BEGIN_RENDER_PREV)
patch_once(CBC_P, CBC_BIND_DS_OLD, CBC_BIND_DS_NEW)
patch_once(DSH_P, DSH_OLD, DSH_NEW)
patch_once(DSC_P, DSC_OLD, DSC_NEW, DSC_PREV)
patch_once(DSC_P, DSC_IMPL_OLD, DSC_IMPL_NEW)
patch_once(TMZ_P, TMZ_OLD, TMZ_NEW, TMZ_PREVIOUS)
patch_once(TMZ_P, GFX_QCOUNT_OLD, GFX_QCOUNT_NEW)
patch_once(QH_P, QH_OLD, QH_NEW)
patch_once(QC_P, QC_SUBMIT1_OLD, QC_SUBMIT1_NEW)
patch_once(QC_P, QC_SUBMIT3_OLD, QC_SUBMIT3_NEW)
patch_once(QC_P, QC_SUBMIT2_OLD, QC_SUBMIT2_NEW)
patch_once(QC_P, QC_INIT_OLD, QC_INIT_NEW)
patch_once(QC_P, QC_FAIL_OLD, QC_FAIL_NEW)
patch_once(QC_P, QC_FINI_OLD, QC_FINI_NEW)
patch_once(QDBG_P, QDBG_OLD1, QDBG_NEW1)
patch_once(QDBG_P, QDBG_OLD2, QDBG_NEW2)

for check_p in (QC_P, QDBG_P):
    if 'queue->vk.index_in_family' in open(check_p).read():
        sys.exit(f'{check_p}: unpatched queue->vk.index_in_family remains')
