/*
 * FideBookOS 1.25 Hardware GPU Liquid Glass Cross-Window Refraction Engine for SurfaceFlinger.
 *
 * Optical physics adapted from open-source Android Liquid Glass projects:
 *   - Kyant0/AndroidLiquidGlass (io.github.kyant0:backdrop, Apache-2.0):
 *       Rounded-rectangle Signed Distance Field (sdRoundedBox), meniscus edge lens refraction,
 *       3-channel RGB chromatic dispersion, 1.30x vibrancy boost, and Fresnel rim sheen.
 *   - styropyr0/Prismal & PrismalAGSL (MIT):
 *       Circular-arc dome height field h(t) = sqrt(2t - t^2), continuous interior convex lens,
 *       analytical surface normal, Snell's law refraction (IOR = 1.54), crisp micro-polish,
 *       inner Quick Settings tile meniscus bevels, and dual Blinn-Phong specular highlights.
 *
 * Applies real-time cross-window background refraction to:
 *   1. Taskbar / Dock (com.google.android.apps.nexuslauncher — opaque carrier refracts the current-frame backdrop via bg_img)
 *   2. App Menu / All Apps Drawer (com.google.android.apps.nexuslauncher)
 *   3. Control Center / Quick Settings + Inner Tiles & Notification Shade (com.android.systemui)
 *
 * Live runtime toggle in Settings (with zero reboot required):
 *   - persist.fidebook.liquid_glass       : "1" / "on" / "" (default ON), "0" / "off" (OFF)
 *   - persist.fidebook.liquid_glass_level : "1" (Subtle), "2" (Balanced, default), "3" (Expressive)
 */
#ifndef FIDEBOOK_LIQUID_GLASS_H
#define FIDEBOOK_LIQUID_GLASS_H

#if DETECT_OS_ANDROID

#define FIDEBOOK_GLASS_MAX_OV    3u
#define FIDEBOOK_GLASS_SLOTS     8u
#define FIDEBOOK_GLASS_MAX_PEND  8u
#define FIDEBOOK_GLASS_MAX_LIVE  64u

/* Must match shaders/glass_common.glsl; build_shaders.sh checks the SPIR-V offsets. */
struct fidebook_glass_pc {
   int32_t dims[2];
   int32_t ov_count;
   int32_t level;
   int32_t bg_valid;      /* 1 only for a validated, pixel-aligned compositor scene */
   int32_t bg_swizzle;
   int32_t blur_px;
   int32_t reserved;
};
_Static_assert(sizeof(struct fidebook_glass_pc) == 32, "glass push-constant ABI");

/* Only sample ordinary 2D single-layer RGBA8 images. Protected/TMZ memory,
 * multisampled attachments and exotic views must never be pulled into a
 * cross-window effect. */
static bool
fidebook_glass_image_eligible(const struct radv_image *image)
{
   if (!image)
      return false;
   if (image->fidebook_protected ||
       (image->vk.create_flags & VK_IMAGE_CREATE_PROTECTED_BIT))
      return false;
   if (image->vk.image_type != VK_IMAGE_TYPE_2D ||
       image->vk.samples != VK_SAMPLE_COUNT_1_BIT ||
       image->vk.array_layers != 1 || image->vk.mip_levels != 1)
      return false;
   return image->vk.format == VK_FORMAT_R8G8B8A8_UNORM ||
          image->vk.format == VK_FORMAT_B8G8R8A8_UNORM;
}

/* Test instrumentation tags images created while FIDEBOOK_TEST_NEXT_TAG is
 * set. Driver scratch images must never join the sampled-image registry or the
 * destroy callback would re-enter ctx->mtx. */
static void
fidebook_glass_forget_scratch(VkImage handle)
{
   if (handle == VK_NULL_HANDLE)
      return;
   struct radv_image *image = radv_image_from_handle(handle);
   if (!image)
      return;
   image->fidebook_is_ahb = 0;
   image->fidebook_tag = 0;
   image->fidebook_img_id = 0;
   image->fidebook_protected = 0;
}

struct fidebook_glass_ctx {
   simple_mtx_t mtx;
   bool init_failed;
   bool in_submit;
   uint32_t width;
   uint32_t height;
   uint32_t qf_index;
   uint32_t seq;
   uint64_t next_img_id;

   /* Live AHB image registry so cached VkDescriptorSets resolve safely by monotonic ID */
   uint64_t live_ids[FIDEBOOK_GLASS_MAX_LIVE];
   struct radv_image *live_imgs[FIDEBOOK_GLASS_MAX_LIVE];

   struct radv_image *pending_ov[FIDEBOOK_GLASS_MAX_PEND];
   uint32_t pending_count;

   /* Backdrop for the opaque-carrier Taskbar (NexusLauncher forces its paint
    * alpha to 255 every frame, so the composited target holds no scene behind
    * it). Only a panel-sized, non-protected, untagged AHB sampled during the
    * CURRENT composition qualifies; it is cleared after every submit and when
    * the image is destroyed, so stale frames are never refracted. */
   struct radv_image *pending_bg;

   /* The scratch images are device-wide. Serialise the whole effect onto one
    * queue so independent VkQueues cannot overwrite them concurrently. */
   VkQueue owner_queue;

   VkDescriptorSetLayout det_dsl;
   VkPipelineLayout det_pl;
   VkShaderModule det_sm;
   VkPipeline det_pipe;

   VkDescriptorSetLayout app_dsl;
   VkPipelineLayout app_pl;
   VkShaderModule app_sm;
   VkPipeline app_pipe;

   VkDescriptorPool desc_pool;
   VkDescriptorSet det_ds;
   VkDescriptorSet app_ds;

   /* Storage buffer holding up to 8 detected glass rounded-rect panels:
    *   header: uvec4 count_info (x = num_rects)
    *   rects[8]: ivec4(x0, y0, x1, y1), vec4(radius, bevel_px, kind, layer_idx) */
   VkBuffer box_buf;
   VkDeviceMemory box_mem;

   VkImage comp_img;
   VkDeviceMemory comp_mem;
   VkImageView comp_view;

   VkImage bg_img;
   VkDeviceMemory bg_mem;
   VkImageView bg_view;

   VkImage ov_img[FIDEBOOK_GLASS_MAX_OV];
   VkDeviceMemory ov_mem[FIDEBOOK_GLASS_MAX_OV];
   VkImageView ov_view[FIDEBOOK_GLASS_MAX_OV];

   VkImage out_img;
   VkDeviceMemory out_mem;
   VkImageView out_view;

   VkCommandPool cmd_pool;
   VkCommandBuffer cmd_buf[FIDEBOOK_GLASS_SLOTS];
   /* Completion record of the last submission that used each command buffer.
    * Signalled either directly (caller passed no fence) or by a fence-only
    * submit queued right after the caller's batch. */
   VkFence slot_fence[FIDEBOOK_GLASS_SLOTS];
   bool slot_busy[FIDEBOOK_GLASS_SLOTS];
};

static int
fidebook_liquid_glass_level(void)
{
   const char *env_v = getenv("FIDEBOOK_LIQUID_GLASS");
   if (env_v) {
      if (strcmp(env_v, "0") == 0 || strcmp(env_v, "off") == 0 || strcmp(env_v, "false") == 0)
         return 0;
      if (strcmp(env_v, "3") == 0)
         return 3;
      if (strcmp(env_v, "1") == 0 && getenv("FIDEBOOK_LIQUID_GLASS_LEVEL")) {
         int lv = atoi(getenv("FIDEBOOK_LIQUID_GLASS_LEVEL"));
         return (lv >= 1 && lv <= 3) ? lv : 2;
      }
      return 2;
   }

   char prop[96] = {0};
   __system_property_get("persist.fidebook.liquid_glass", prop);
   if (strcmp(prop, "0") == 0 || strcmp(prop, "off") == 0 || strcmp(prop, "false") == 0)
      return 0;

   char lprop[96] = {0};
   __system_property_get("persist.fidebook.liquid_glass_level", lprop);
   if (strcmp(lprop, "1") == 0 || strcmp(lprop, "subtle") == 0)
      return 1;
   if (strcmp(lprop, "3") == 0 || strcmp(lprop, "expressive") == 0)
      return 3;
   return 2;
}

/* Frosted backdrop radius: level defaults 5/10/16 px at 1080p, runtime override
 * persist.fidebook.liquid_glass_blur (px, 0 disables blur). Scales with panel height. */
static int
fidebook_glass_blur_px(int level, uint32_t height)
{
   int px;
   char prop[48] = {0};
   __system_property_get("persist.fidebook.liquid_glass_blur", prop);
   if (prop[0]) {
      px = atoi(prop);
   } else {
      const char *env = getenv("FIDEBOOK_LIQUID_GLASS_BLUR");
      if (env && env[0])
         px = atoi(env);
      else
         px = (level >= 3) ? 16 : ((level <= 1) ? 5 : 10);
   }
   if (px <= 0)
      return 0;
   if (height > 0)
      px = (int)(((int64_t)px * (int64_t)height + 540) / 1080);
   if (px < 2 && level > 0)
      px = 2;
   if (px > 40)
      px = 40;
   return px;
}

static struct fidebook_glass_ctx *
fidebook_glass_get_ctx(struct radv_device *device)
{
   if (device->fidebook_glass)
      return (struct fidebook_glass_ctx *)device->fidebook_glass;
   struct fidebook_glass_ctx *nctx = calloc(1, sizeof(*nctx));
   if (!nctx)
      return NULL;
   simple_mtx_init(&nctx->mtx, mtx_plain);
   nctx->next_img_id = 1ULL;
   device->fidebook_glass = nctx;
   return nctx;
}

void
fidebook_glass_register_image(struct radv_device *device, struct radv_image *image)
{
   if (!device || !image)
      return;
   if (fidebook_get_proc_info(NULL) != 2)
      return;
   struct fidebook_glass_ctx *ctx = fidebook_glass_get_ctx(device);
   if (!ctx)
      return;

   simple_mtx_lock(&ctx->mtx);
   if (!image->fidebook_img_id)
      image->fidebook_img_id = ctx->next_img_id++;

   int free_slot = -1;
   for (uint32_t i = 0; i < FIDEBOOK_GLASS_MAX_LIVE; i++) {
      if (ctx->live_imgs[i] == image) {
         ctx->live_ids[i] = image->fidebook_img_id;
         simple_mtx_unlock(&ctx->mtx);
         return;
      }
      if (free_slot < 0 && ctx->live_imgs[i] == NULL)
         free_slot = (int)i;
   }
   if (free_slot < 0)
      free_slot = (int)(image->fidebook_img_id % FIDEBOOK_GLASS_MAX_LIVE);
   ctx->live_ids[free_slot] = image->fidebook_img_id;
   ctx->live_imgs[free_slot] = image;
   simple_mtx_unlock(&ctx->mtx);
}

static bool
fidebook_glass_slots_idle(struct radv_device *device, struct fidebook_glass_ctx *ctx)
{
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   for (uint32_t s = 0; s < FIDEBOOK_GLASS_SLOTS; s++) {
      if (!ctx->slot_busy[s])
         continue;
      if (dt->WaitForFences(dev_h, 1, &ctx->slot_fence[s], VK_TRUE, 1000000000ULL) != VK_SUCCESS)
         return false;
      ctx->slot_busy[s] = false;
   }
   return true;
}

/* Only call once all slots are idle (or the device is being destroyed). */
static void
fidebook_glass_free_images(struct radv_device *device, struct fidebook_glass_ctx *ctx)
{
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   if (ctx->comp_view) { dt->DestroyImageView(dev_h, ctx->comp_view, NULL); ctx->comp_view = VK_NULL_HANDLE; }
   if (ctx->comp_img)  { dt->DestroyImage(dev_h, ctx->comp_img, NULL);       ctx->comp_img = VK_NULL_HANDLE; }
   if (ctx->comp_mem)  { dt->FreeMemory(dev_h, ctx->comp_mem, NULL);         ctx->comp_mem = VK_NULL_HANDLE; }

   if (ctx->bg_view)   { dt->DestroyImageView(dev_h, ctx->bg_view, NULL);   ctx->bg_view = VK_NULL_HANDLE; }
   if (ctx->bg_img)    { dt->DestroyImage(dev_h, ctx->bg_img, NULL);         ctx->bg_img = VK_NULL_HANDLE; }
   if (ctx->bg_mem)    { dt->FreeMemory(dev_h, ctx->bg_mem, NULL);           ctx->bg_mem = VK_NULL_HANDLE; }

   for (uint32_t i = 0; i < FIDEBOOK_GLASS_MAX_OV; i++) {
      if (ctx->ov_view[i]) { dt->DestroyImageView(dev_h, ctx->ov_view[i], NULL); ctx->ov_view[i] = VK_NULL_HANDLE; }
      if (ctx->ov_img[i])  { dt->DestroyImage(dev_h, ctx->ov_img[i], NULL);       ctx->ov_img[i] = VK_NULL_HANDLE; }
      if (ctx->ov_mem[i])  { dt->FreeMemory(dev_h, ctx->ov_mem[i], NULL);         ctx->ov_mem[i] = VK_NULL_HANDLE; }
   }

   if (ctx->out_view) { dt->DestroyImageView(dev_h, ctx->out_view, NULL); ctx->out_view = VK_NULL_HANDLE; }
   if (ctx->out_img)  { dt->DestroyImage(dev_h, ctx->out_img, NULL);       ctx->out_img = VK_NULL_HANDLE; }
   if (ctx->out_mem)  { dt->FreeMemory(dev_h, ctx->out_mem, NULL);         ctx->out_mem = VK_NULL_HANDLE; }

   ctx->width = ctx->height = 0;
}

void
fidebook_glass_on_image_destroy(struct radv_device *device, struct radv_image *image)
{
   if (!device || !image || !device->fidebook_glass)
      return;
   /* Driver-owned scratch images are destroyed while ctx->mtx is held. They
    * were never registered, so do not enter the registry callback and risk a
    * self-deadlock on the non-recursive mutex. */
   if (!image->fidebook_is_ahb && !image->fidebook_tag && !image->fidebook_img_id)
      return;
   struct fidebook_glass_ctx *ctx = (struct fidebook_glass_ctx *)device->fidebook_glass;
   simple_mtx_lock(&ctx->mtx);
   uint32_t dst = 0;
   for (uint32_t i = 0; i < ctx->pending_count; i++) {
      if (ctx->pending_ov[i] != image)
         ctx->pending_ov[dst++] = ctx->pending_ov[i];
   }
   ctx->pending_count = dst;
   if (ctx->pending_bg == image)
      ctx->pending_bg = NULL;
   for (uint32_t i = 0; i < FIDEBOOK_GLASS_MAX_LIVE; i++) {
      if (ctx->live_imgs[i] == image) {
         ctx->live_imgs[i] = NULL;
         ctx->live_ids[i] = 0;
      }
   }
   simple_mtx_unlock(&ctx->mtx);
}

void
fidebook_glass_device_finish(struct radv_device *device)
{
   if (!device || !device->fidebook_glass)
      return;
   struct fidebook_glass_ctx *ctx = (struct fidebook_glass_ctx *)device->fidebook_glass;
   device->fidebook_glass = NULL;

   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   /* Device teardown is the one place a full idle wait is safe and required. */
   dt->DeviceWaitIdle(dev_h);
   fidebook_glass_free_images(device, ctx);

   for (uint32_t s = 0; s < FIDEBOOK_GLASS_SLOTS; s++) {
      if (ctx->slot_fence[s])
         dt->DestroyFence(dev_h, ctx->slot_fence[s], NULL);
   }
   if (ctx->cmd_pool)  dt->DestroyCommandPool(dev_h, ctx->cmd_pool, NULL);
   if (ctx->box_buf)   dt->DestroyBuffer(dev_h, ctx->box_buf, NULL);
   if (ctx->box_mem)   dt->FreeMemory(dev_h, ctx->box_mem, NULL);
   if (ctx->desc_pool) dt->DestroyDescriptorPool(dev_h, ctx->desc_pool, NULL);
   if (ctx->det_pipe)  dt->DestroyPipeline(dev_h, ctx->det_pipe, NULL);
   if (ctx->app_pipe)  dt->DestroyPipeline(dev_h, ctx->app_pipe, NULL);
   if (ctx->det_sm)    dt->DestroyShaderModule(dev_h, ctx->det_sm, NULL);
   if (ctx->app_sm)    dt->DestroyShaderModule(dev_h, ctx->app_sm, NULL);
   if (ctx->det_pl)    dt->DestroyPipelineLayout(dev_h, ctx->det_pl, NULL);
   if (ctx->app_pl)    dt->DestroyPipelineLayout(dev_h, ctx->app_pl, NULL);
   if (ctx->det_dsl)   dt->DestroyDescriptorSetLayout(dev_h, ctx->det_dsl, NULL);
   if (ctx->app_dsl)   dt->DestroyDescriptorSetLayout(dev_h, ctx->app_dsl, NULL);

   simple_mtx_destroy(&ctx->mtx);
   free(ctx);
}

static void
fidebook_glass_note_image_locked(struct radv_device *device, struct fidebook_glass_ctx *ctx,
                                 struct radv_image *image)
{
   if (!image || ctx->in_submit || !fidebook_glass_image_eligible(image))
      return;

   /* Lazily refresh kernel amdgpu BO umd_metadata tag in case producer stamped after first import */
   uint32_t tag = image->fidebook_tag;
   if (tag == 0 && image->fidebook_is_ahb && image->bindings[0].bo &&
       device->ws && device->ws->buffer_get_metadata) {
      struct radeon_bo_metadata md;
      memset(&md, 0, sizeof(md));
      device->ws->buffer_get_metadata(device->ws, image->bindings[0].bo, &md);
      if (md.size_metadata >= 232 && md.metadata[56] == FIDEBOOK_BO_META_MAGIC) {
         tag = md.metadata[57];
         image->fidebook_tag = tag;
      }
   }

   if (tag == FIDEBOOK_TAG_LAUNCHER || tag == FIDEBOOK_TAG_SYSUI) {
      /* Ignore thin SystemUI status bar (h < 180); keep Taskbar (Launcher h >= 36), App Menu & Control Center */
      if (tag == FIDEBOOK_TAG_SYSUI && image->vk.extent.height < 180)
         return;
      if (image->vk.extent.width < 200 || image->vk.extent.height < 36)
         return;
      for (uint32_t i = 0; i < ctx->pending_count; i++) {
         if (ctx->pending_ov[i] == image)
            return;
      }
      if (ctx->pending_count < FIDEBOOK_GLASS_MAX_PEND)
         ctx->pending_ov[ctx->pending_count++] = image;
   } else if (tag == 0 && image->fidebook_is_ahb &&
              image->vk.extent.width >= 600 && image->vk.extent.height >= 400) {
      /* Wallpaper / maximized window drawn below the overlays in THIS frame.
       * Keep the largest candidate so a small app buffer (thumbnail, PiP)
       * never replaces the panel-sized layer the dock sits on. */
      uint64_t new_area = (uint64_t)image->vk.extent.width * image->vk.extent.height;
      uint64_t cur_area = ctx->pending_bg
                             ? (uint64_t)ctx->pending_bg->vk.extent.width * ctx->pending_bg->vk.extent.height
                             : 0;
      if (!ctx->pending_bg || new_area >= cur_area)
         ctx->pending_bg = image;
   }
}

void
fidebook_glass_note_sampled_image(struct radv_device *device, struct radv_image *image)
{
   if (!device || !image)
      return;
   if (fidebook_get_proc_info(NULL) != 2)
      return;
   if (fidebook_liquid_glass_level() <= 0)
      return;
   struct fidebook_glass_ctx *ctx = fidebook_glass_get_ctx(device);
   if (!ctx)
      return;
   simple_mtx_lock(&ctx->mtx);
   fidebook_glass_note_image_locked(device, ctx, image);
   simple_mtx_unlock(&ctx->mtx);
}

void
fidebook_glass_note_sampled_id(struct radv_device *device, uint64_t img_id)
{
   if (!device || !img_id || !device->fidebook_glass)
      return;
   if (fidebook_get_proc_info(NULL) != 2)
      return;
   if (fidebook_liquid_glass_level() <= 0)
      return;
   struct fidebook_glass_ctx *ctx = (struct fidebook_glass_ctx *)device->fidebook_glass;
   simple_mtx_lock(&ctx->mtx);
   struct radv_image *found = NULL;
   for (uint32_t i = 0; i < FIDEBOOK_GLASS_MAX_LIVE; i++) {
      if (ctx->live_ids[i] == img_id && ctx->live_imgs[i] != NULL) {
         found = ctx->live_imgs[i];
         break;
      }
   }
   if (found)
      fidebook_glass_note_image_locked(device, ctx, found);
   simple_mtx_unlock(&ctx->mtx);
}

static bool
fidebook_glass_ensure_ready(struct radv_device *device, struct fidebook_glass_ctx *ctx,
                            uint32_t qf_index, uint32_t w, uint32_t h)
{
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;
   VkResult r;

   if (ctx->init_failed)
      return false;

   if (!ctx->det_pipe) {
      ctx->qf_index = qf_index;

      /* det_ds: binding 0..2 = ov0..ov2 (readonly rgba8), binding 3 = BoxBuf */
      VkDescriptorSetLayoutBinding det_b[4] = {
         {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
      };
      VkDescriptorSetLayoutCreateInfo det_dsl_ci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 4,
         .pBindings = det_b,
      };
      if (dt->CreateDescriptorSetLayout(dev_h, &det_dsl_ci, NULL, &ctx->det_dsl) != VK_SUCCESS)
         goto fail;

      VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(struct fidebook_glass_pc)};
      VkPipelineLayoutCreateInfo det_pl_ci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &ctx->det_dsl,
         .pushConstantRangeCount = 1,
         .pPushConstantRanges = &pcr,
      };
      if (dt->CreatePipelineLayout(dev_h, &det_pl_ci, NULL, &ctx->det_pl) != VK_SUCCESS)
         goto fail;

      /* app_ds: 0 = comp_img, 1..3 = ov0..ov2, 4 = BoxBuf, 5 = out_img, 6 = bg_img */
      VkDescriptorSetLayoutBinding app_b[7] = {
         {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {5, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
         {6, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
      };
      VkDescriptorSetLayoutCreateInfo app_dsl_ci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 7,
         .pBindings = app_b,
      };
      if (dt->CreateDescriptorSetLayout(dev_h, &app_dsl_ci, NULL, &ctx->app_dsl) != VK_SUCCESS)
         goto fail;

      VkPipelineLayoutCreateInfo app_pl_ci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &ctx->app_dsl,
         .pushConstantRangeCount = 1,
         .pPushConstantRanges = &pcr,
      };
      if (dt->CreatePipelineLayout(dev_h, &app_pl_ci, NULL, &ctx->app_pl) != VK_SUCCESS)
         goto fail;

      VkShaderModuleCreateInfo sm0 = {
         .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
         .codeSize = sizeof(fidebook_glass_detect_spv),
         .pCode = fidebook_glass_detect_spv,
      };
      VkShaderModuleCreateInfo sm1 = {
         .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
         .codeSize = sizeof(fidebook_glass_apply_spv),
         .pCode = fidebook_glass_apply_spv,
      };
      if (dt->CreateShaderModule(dev_h, &sm0, NULL, &ctx->det_sm) != VK_SUCCESS ||
          dt->CreateShaderModule(dev_h, &sm1, NULL, &ctx->app_sm) != VK_SUCCESS)
         goto fail;

      VkComputePipelineCreateInfo cp0 = {
         .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                   VK_SHADER_STAGE_COMPUTE_BIT, ctx->det_sm, "main", NULL},
         .layout = ctx->det_pl,
      };
      VkComputePipelineCreateInfo cp1 = {
         .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                   VK_SHADER_STAGE_COMPUTE_BIT, ctx->app_sm, "main", NULL},
         .layout = ctx->app_pl,
      };
      if (dt->CreateComputePipelines(dev_h, VK_NULL_HANDLE, 1, &cp0, NULL, &ctx->det_pipe) != VK_SUCCESS ||
          dt->CreateComputePipelines(dev_h, VK_NULL_HANDLE, 1, &cp1, NULL, &ctx->app_pipe) != VK_SUCCESS)
         goto fail;

      VkDescriptorPoolSize ps[2] = {
         {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 20},
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

      VkDescriptorSetLayout dsls[2] = {ctx->det_dsl, ctx->app_dsl};
      VkDescriptorSet sets[2] = {VK_NULL_HANDLE, VK_NULL_HANDLE};
      VkDescriptorSetAllocateInfo ds_ai = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
         .descriptorPool = ctx->desc_pool,
         .descriptorSetCount = 2,
         .pSetLayouts = dsls,
      };
      if (dt->AllocateDescriptorSets(dev_h, &ds_ai, sets) != VK_SUCCESS)
         goto fail;
      ctx->det_ds = sets[0];
      ctx->app_ds = sets[1];

      VkBufferCreateInfo bci = {
         .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
         .size = 512,
         .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
         .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      };
      if (dt->CreateBuffer(dev_h, &bci, NULL, &ctx->box_buf) != VK_SUCCESS)
         goto fail;
      VkMemoryRequirements breqs;
      dt->GetBufferMemoryRequirements(dev_h, ctx->box_buf, &breqs);
      VkMemoryAllocateInfo bmai = {
         .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
         .allocationSize = breqs.size,
         .memoryTypeIndex = fidebook_find_mem_type(device, breqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
      };
      if (dt->AllocateMemory(dev_h, &bmai, NULL, &ctx->box_mem) != VK_SUCCESS ||
          dt->BindBufferMemory(dev_h, ctx->box_buf, ctx->box_mem, 0) != VK_SUCCESS)
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
         .commandBufferCount = FIDEBOOK_GLASS_SLOTS,
      };
      if (dt->AllocateCommandBuffers(dev_h, &cb_ai, ctx->cmd_buf) != VK_SUCCESS)
         goto fail;

      VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
      for (uint32_t s = 0; s < FIDEBOOK_GLASS_SLOTS; s++) {
         if (dt->CreateFence(dev_h, &fci, NULL, &ctx->slot_fence[s]) != VK_SUCCESS)
            goto fail;
      }
   }

   if (ctx->qf_index != qf_index)
      return false;

   if (ctx->width != w || ctx->height != h) {
      /* Never destroy/replace scratch memory while an earlier glass submission
       * may still read it. If the GPU has not drained, skip this frame. */
      if (!fidebook_glass_slots_idle(device, ctx))
         return false;
      fidebook_glass_free_images(device, ctx);

      r = fidebook_alloc_scratch_image(device, w, h,
                                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                       &ctx->comp_img, &ctx->comp_mem, &ctx->comp_view);
      if (r != VK_SUCCESS) goto fail;

      r = fidebook_alloc_scratch_image(device, w, h,
                                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                       &ctx->bg_img, &ctx->bg_mem, &ctx->bg_view);
      if (r != VK_SUCCESS) goto fail;

      for (uint32_t i = 0; i < FIDEBOOK_GLASS_MAX_OV; i++) {
         r = fidebook_alloc_scratch_image(device, w, h,
                                          VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                          &ctx->ov_img[i], &ctx->ov_mem[i], &ctx->ov_view[i]);
         if (r != VK_SUCCESS) goto fail;
      }

      r = fidebook_alloc_scratch_image(device, w, h,
                                       VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
                                       &ctx->out_img, &ctx->out_mem, &ctx->out_view);
      if (r != VK_SUCCESS) goto fail;

      fidebook_glass_forget_scratch(ctx->comp_img);
      fidebook_glass_forget_scratch(ctx->bg_img);
      for (uint32_t i = 0; i < FIDEBOOK_GLASS_MAX_OV; i++)
         fidebook_glass_forget_scratch(ctx->ov_img[i]);
      fidebook_glass_forget_scratch(ctx->out_img);

      ctx->width = w;
      ctx->height = h;

      VkDescriptorImageInfo di_comp = {VK_NULL_HANDLE, ctx->comp_view, VK_IMAGE_LAYOUT_GENERAL};
      VkDescriptorImageInfo di_bg   = {VK_NULL_HANDLE, ctx->bg_view,   VK_IMAGE_LAYOUT_GENERAL};
      VkDescriptorImageInfo di_ov[FIDEBOOK_GLASS_MAX_OV] = {
         {VK_NULL_HANDLE, ctx->ov_view[0], VK_IMAGE_LAYOUT_GENERAL},
         {VK_NULL_HANDLE, ctx->ov_view[1], VK_IMAGE_LAYOUT_GENERAL},
         {VK_NULL_HANDLE, ctx->ov_view[2], VK_IMAGE_LAYOUT_GENERAL},
      };
      VkDescriptorImageInfo di_out = {VK_NULL_HANDLE, ctx->out_view, VK_IMAGE_LAYOUT_GENERAL};
      VkDescriptorBufferInfo db_box = {ctx->box_buf, 0, 512};

      VkWriteDescriptorSet writes[11] = {
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->det_ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_ov[0], NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->det_ds, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_ov[1], NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->det_ds, 2, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_ov[2], NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->det_ds, 3, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &db_box, NULL},

         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_comp,  NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_ov[0], NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 2, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_ov[1], NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 3, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_ov[2], NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 4, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &db_box, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 5, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_out,   NULL, NULL},
         {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->app_ds, 6, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,  &di_bg,    NULL, NULL},
      };
      dt->UpdateDescriptorSets(dev_h, 11, writes, 0, NULL);
   }

   return true;

fail:
   ctx->init_failed = true;
   fidebook_glass_free_images(device, ctx);
   return false;
}

static VkCommandBuffer
fidebook_glass_record_cb(struct radv_device *device, struct fidebook_glass_ctx *ctx,
                         uint32_t qf_index, struct radv_image *target_img, int level,
                         uint32_t *out_slot)
{
   *out_slot = 0;
   if (!fidebook_glass_image_eligible(target_img))
      return VK_NULL_HANDLE;
   uint32_t w = target_img->vk.extent.width;
   uint32_t h = target_img->vk.extent.height;
   if (w < 320 || h < 240 || w > 4096 || h > 4096)
      return VK_NULL_HANDLE;

   /* Pick up to 3 most-topmost overlay layers matching screen bounds */
   struct radv_image *chosen[FIDEBOOK_GLASS_MAX_OV] = {NULL, NULL, NULL};
   uint32_t ov_cnt = 0;
   uint32_t start_i = (ctx->pending_count > FIDEBOOK_GLASS_MAX_OV)
                         ? (ctx->pending_count - FIDEBOOK_GLASS_MAX_OV)
                         : 0;
   for (uint32_t i = start_i; i < ctx->pending_count && ov_cnt < FIDEBOOK_GLASS_MAX_OV; i++) {
      struct radv_image *ov = ctx->pending_ov[i];
      if (!ov || ov == target_img)
         continue;
      if (ov->vk.extent.width > w || ov->vk.extent.height > h ||
          !fidebook_glass_image_eligible(ov))
         continue;
      chosen[ov_cnt++] = ov;
   }
   if (ov_cnt == 0)
      return VK_NULL_HANDLE;

   /* Accept only a near-panel-sized backdrop from this composition; anything
    * smaller is an app layer, not what lies behind the dock. */
   struct radv_image *bg_src = ctx->pending_bg;
   int bg_swizzle = 0;
   if (bg_src) {
      if (bg_src == target_img || !fidebook_glass_image_eligible(bg_src) ||
          (uint64_t)bg_src->vk.extent.width * 4 < (uint64_t)w * 3 ||
          (uint64_t)bg_src->vk.extent.height * 4 < (uint64_t)h * 3 ||
          bg_src->vk.extent.width > 4096 || bg_src->vk.extent.height > 4096) {
         bg_src = NULL;
      } else if (bg_src->vk.format != target_img->vk.format) {
         bg_swizzle = 1; /* scratch keeps the target's byte order */
      }
   }

   if (!fidebook_glass_ensure_ready(device, ctx, qf_index, w, h))
      return VK_NULL_HANDLE;

   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;
   uint32_t slot = ctx->seq % FIDEBOOK_GLASS_SLOTS;

   /* Do not reset a command buffer that the GPU may still be executing. If an
    * earlier effect has not drained within one second, skip this frame rather
    * than corrupting in-flight work. */
   if (ctx->slot_busy[slot]) {
      if (dt->WaitForFences(dev_h, 1, &ctx->slot_fence[slot], VK_TRUE, 1000000000ULL) != VK_SUCCESS)
         return VK_NULL_HANDLE;
      ctx->slot_busy[slot] = false;
   }
   ctx->seq++;

   VkCommandBuffer cb = ctx->cmd_buf[slot];
   if (dt->ResetCommandBuffer(cb, 0) != VK_SUCCESS)
      return VK_NULL_HANDLE;
   VkCommandBufferBeginInfo bi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   if (dt->BeginCommandBuffer(cb, &bi) != VK_SUCCESS)
      return VK_NULL_HANDLE;

   VkImage target_h = radv_image_to_handle(target_img);
   VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

   /* 1. Transition target_img, bg_src & overlay sources to TRANSFER_SRC and scratch images to TRANSFER_DST */
   VkImageMemoryBarrier pre_b[4 + FIDEBOOK_GLASS_MAX_OV * 2];
   uint32_t nb = 0;
   pre_b[nb++] = (VkImageMemoryBarrier){
      VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
      VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
      VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, target_h, range,
   };
   pre_b[nb++] = (VkImageMemoryBarrier){
      VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
      0, VK_ACCESS_TRANSFER_WRITE_BIT,
      VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->comp_img, range,
   };
   if (bg_src) {
      pre_b[nb++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         0, VK_ACCESS_TRANSFER_WRITE_BIT,
         VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->bg_img, range,
      };
      pre_b[nb++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
         VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, radv_image_to_handle(bg_src), range,
      };
   }
   for (uint32_t i = 0; i < ov_cnt; i++) {
      pre_b[nb++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
         VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, radv_image_to_handle(chosen[i]), range,
      };
      pre_b[nb++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         0, VK_ACCESS_TRANSFER_WRITE_BIT,
         VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->ov_img[i], range,
      };
   }
   dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                          0, 0, NULL, 0, NULL, nb, pre_b);

   VkImageCopy full_copy = {
      .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .extent = {w, h, 1},
   };
   dt->CmdCopyImage(cb, target_h, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    ctx->comp_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &full_copy);

   /* Live backdrop for the opaque Taskbar. NEVER copy target_img here: it
    * already holds the carrier (and on partial redraw last frame's glass),
    * which would feed back into itself. */
   if (bg_src) {
      uint32_t bw = bg_src->vk.extent.width;
      uint32_t bh = bg_src->vk.extent.height;
      VkImage bg_h = radv_image_to_handle(bg_src);
      if (bw == w && bh == h) {
         dt->CmdCopyImage(cb, bg_h, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                          ctx->bg_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &full_copy);
      } else {
         VkImageBlit bg_blit = {
            .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
            .srcOffsets = {{0, 0, 0}, {(int32_t)bw, (int32_t)bh, 1}},
            .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
            .dstOffsets = {{0, 0, 0}, {(int32_t)w, (int32_t)h, 1}},
         };
         dt->CmdBlitImage(cb, bg_h, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                          ctx->bg_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                          1, &bg_blit, VK_FILTER_LINEAR);
      }
   }

   VkClearColorValue zero_col = {{0.0f, 0.0f, 0.0f, 0.0f}};
   for (uint32_t i = 0; i < ov_cnt; i++) {
      uint32_t ow = chosen[i]->vk.extent.width;
      uint32_t oh = chosen[i]->vk.extent.height;
      int32_t dst_x = (ow < w) ? (int32_t)((w - ow) / 2) : 0;
      /* Bottom-anchor short Launcher taskbar strips; top-anchor full-height overlays */
      int32_t dst_y = (oh < h / 2 && chosen[i]->fidebook_tag == FIDEBOOK_TAG_LAUNCHER)
                         ? (int32_t)(h - oh)
                         : 0;
      if (ow < w || oh < h)
         dt->CmdClearColorImage(cb, ctx->ov_img[i], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &zero_col, 1, &range);

      VkImageCopy ov_copy = {
         .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
         .srcOffset = {0, 0, 0},
         .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
         .dstOffset = {dst_x, dst_y, 0},
         .extent = {ow, oh, 1},
      };
      dt->CmdCopyImage(cb, radv_image_to_handle(chosen[i]), VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       ctx->ov_img[i], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &ov_copy);
   }

   /* 2. Transition scratch images to GENERAL for compute & restore source images to SHADER_READ_ONLY */
   VkImageMemoryBarrier comp_b[4 + FIDEBOOK_GLASS_MAX_OV * 2];
   uint32_t nc = 0;
   comp_b[nc++] = (VkImageMemoryBarrier){
      VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
      VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->comp_img, range,
   };
   /* Without a backdrop bg_img is only a valid dummy binding (bg_valid=0). */
   comp_b[nc++] = (VkImageMemoryBarrier){
      VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
      bg_src ? VK_ACCESS_TRANSFER_WRITE_BIT : 0, VK_ACCESS_SHADER_READ_BIT,
      bg_src ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->bg_img, range,
   };
   if (bg_src) {
      comp_b[nc++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_SHADER_READ_BIT,
         VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, radv_image_to_handle(bg_src), range,
      };
   }
   comp_b[nc++] = (VkImageMemoryBarrier){
      VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
      0, VK_ACCESS_SHADER_WRITE_BIT,
      VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->out_img, range,
   };
   for (uint32_t i = 0; i < ov_cnt; i++) {
      comp_b[nc++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->ov_img[i], range,
      };
      comp_b[nc++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_SHADER_READ_BIT,
         VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, radv_image_to_handle(chosen[i]), range,
      };
   }
   for (uint32_t i = ov_cnt; i < FIDEBOOK_GLASS_MAX_OV; i++) {
      comp_b[nc++] = (VkImageMemoryBarrier){
         VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
         0, VK_ACCESS_SHADER_READ_BIT,
         VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->ov_img[i], range,
      };
   }
   dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                          VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                          0, 0, NULL, 0, NULL, nc, comp_b);

   struct fidebook_glass_pc pc = {
      .dims = {(int32_t)w, (int32_t)h},
      .ov_count = (int32_t)ov_cnt,
      .level = level,
      .bg_valid = bg_src != NULL, /* current-frame, panel-sized, non-protected */
      .bg_swizzle = bg_swizzle,
      .blur_px = fidebook_glass_blur_px(level, h),
      .reserved = 0,
   };

   /* 3. Detect exact live glass panel bounding boxes (Taskbar, App Menu, Control Center) */
   dt->CmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->det_pipe);
   dt->CmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->det_pl, 0, 1, &ctx->det_ds, 0, NULL);
   dt->CmdPushConstants(cb, ctx->det_pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);
   dt->CmdDispatch(cb, 1, 1, 1);

   VkMemoryBarrier mb_box = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
   };
   dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                          0, 1, &mb_box, 0, NULL, 0, NULL);

   /* 4. Apply dual-zone Snell's-law refraction + convex dome + tile bevels + RGB dispersion + Fresnel rim */
   dt->CmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->app_pipe);
   dt->CmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx->app_pl, 0, 1, &ctx->app_ds, 0, NULL);
   dt->CmdPushConstants(cb, ctx->app_pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);
   dt->CmdDispatch(cb, (w + 15) / 16, (h + 15) / 16, 1);

   /* 5. Copy refracted frame back into target_img before HWC scanout semaphore signals */
   VkImageMemoryBarrier post_b[2] = {
      {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
       VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
       VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
       VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, ctx->out_img, range},
      {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
       VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
       VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
       VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, target_h, range},
   };
   dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
                          VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 2, post_b);

   dt->CmdCopyImage(cb, ctx->out_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    target_h, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &full_copy);

   VkImageMemoryBarrier fin_b = {
      VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
      VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, target_h, range,
   };
   dt->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                          0, 0, NULL, 0, NULL, 1, &fin_b);

   if (dt->EndCommandBuffer(cb) != VK_SUCCESS)
      return VK_NULL_HANDLE;
   *out_slot = slot;
   return cb;
}

VKAPI_ATTR VkResult VKAPI_CALL
radv_QueueSubmit2(VkQueue _queue, uint32_t submitCount, const VkSubmitInfo2 *pSubmits, VkFence _fence)
{
   VK_FROM_HANDLE(radv_queue, queue, _queue);
   struct radv_device *device = radv_queue_device(queue);

   if (submitCount == 0 || !pSubmits || queue->state.qf != RADV_QUEUE_GENERAL ||
       fidebook_get_proc_info(NULL) != 2 || !device->fidebook_glass) {
      return vk_common_QueueSubmit2(_queue, submitCount, pSubmits, _fence);
   }

   /* Protected submissions and capture-excluded content never enter the glass
    * pipeline, even though this port currently disables TMZ. */
   for (uint32_t s = 0; s < submitCount; s++) {
      if (pSubmits[s].flags & VK_SUBMIT_PROTECTED_BIT)
         return vk_common_QueueSubmit2(_queue, submitCount, pSubmits, _fence);
   }

   int level = fidebook_liquid_glass_level();
   struct fidebook_glass_ctx *ctx = (struct fidebook_glass_ctx *)device->fidebook_glass;
   VkDevice dev_h = radv_device_to_handle(device);
   const struct vk_device_dispatch_table *dt = &device->vk.dispatch_table;

   simple_mtx_lock(&ctx->mtx);
   if (ctx->in_submit || level <= 0 || ctx->pending_count == 0) {
      if (level <= 0)
         ctx->pending_count = 0;
      /* RenderEngine records and submits one composition at a time, so what
       * was noted before this submit belongs to it; never let a backdrop
       * outlive the composition that sampled it. */
      if (!ctx->in_submit && ctx->pending_count == 0)
         ctx->pending_bg = NULL;
      simple_mtx_unlock(&ctx->mtx);
      return vk_common_QueueSubmit2(_queue, submitCount, pSubmits, _fence);
   }

   /* One shared set of scratch images cannot be used by two VkQueues at once. */
   if (ctx->owner_queue && ctx->owner_queue != _queue) {
      simple_mtx_unlock(&ctx->mtx);
      return vk_common_QueueSubmit2(_queue, submitCount, pSubmits, _fence);
   }

   /* Check if any submitted command buffer rendered into the SurfaceFlinger HWC client target */
   int match_s = -1;
   struct radv_image *target_img = NULL;
   for (uint32_t s = 0; s < submitCount; s++) {
      for (uint32_t c = 0; c < pSubmits[s].commandBufferInfoCount; c++) {
         VK_FROM_HANDLE(radv_cmd_buffer, cmd_buf, pSubmits[s].pCommandBufferInfos[c].commandBuffer);
         if (cmd_buf && cmd_buf->fidebook_client_target) {
            match_s = (int)s;
            target_img = cmd_buf->fidebook_client_target;
         }
      }
   }

   if (match_s < 0 || !target_img) {
      simple_mtx_unlock(&ctx->mtx);
      return vk_common_QueueSubmit2(_queue, submitCount, pSubmits, _fence);
   }
   ctx->owner_queue = _queue;

   ctx->in_submit = true;
   uint32_t slot = 0;
   VkCommandBuffer glass_cb = fidebook_glass_record_cb(device, ctx, queue->vk.queue_family_index,
                                                        target_img, level, &slot);
   ctx->pending_count = 0;
   ctx->pending_bg = NULL; /* never carry a backdrop into a later frame */
   ctx->in_submit = false;

   if (glass_cb == VK_NULL_HANDLE) {
      simple_mtx_unlock(&ctx->mtx);
      return vk_common_QueueSubmit2(_queue, submitCount, pSubmits, _fence);
   }

   uint32_t orig_cb_cnt = pSubmits[match_s].commandBufferInfoCount;
   STACK_ARRAY(VkSubmitInfo2, mod_submits, submitCount);
   STACK_ARRAY(VkCommandBufferSubmitInfo, mod_cbs, orig_cb_cnt + 1);

   memcpy(mod_submits, pSubmits, submitCount * sizeof(VkSubmitInfo2));
   memcpy(mod_cbs, pSubmits[match_s].pCommandBufferInfos, orig_cb_cnt * sizeof(VkCommandBufferSubmitInfo));
   mod_cbs[orig_cb_cnt] = (VkCommandBufferSubmitInfo){
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
      .commandBuffer = glass_cb,
   };
   mod_submits[match_s].commandBufferInfoCount = orig_cb_cnt + 1;
   mod_submits[match_s].pCommandBufferInfos = mod_cbs;

   /* The caller's fence and semaphores are passed through untouched. When the
    * caller supplied a fence, the slot's completion record is a fence-only
    * submit right after it: Vulkan signals it once all previously submitted
    * work on this queue (including the glass command buffer) has completed. */
   bool app_fence = _fence != VK_NULL_HANDLE;
   dt->ResetFences(dev_h, 1, &ctx->slot_fence[slot]);
   ctx->slot_busy[slot] = true;

   simple_mtx_unlock(&ctx->mtx);

   VkResult res = vk_common_QueueSubmit2(_queue, submitCount, mod_submits,
                                         app_fence ? _fence : ctx->slot_fence[slot]);
   bool tracked = res == VK_SUCCESS;
   if (tracked && app_fence)
      tracked = vk_common_QueueSubmit2(_queue, 0, NULL, ctx->slot_fence[slot]) == VK_SUCCESS;

   if (!tracked) {
      /* Without a completion record the slot cannot be proven idle. Wait for
       * the queue (bounded by the driver) so the command buffer is never reset
       * while the GPU may still execute it. */
      if (res == VK_SUCCESS)
         dt->QueueWaitIdle(_queue);
      simple_mtx_lock(&ctx->mtx);
      ctx->slot_busy[slot] = false;
      simple_mtx_unlock(&ctx->mtx);
   }

   STACK_ARRAY_FINISH(mod_cbs);
   STACK_ARRAY_FINISH(mod_submits);
   return res;
}

#endif /* DETECT_OS_ANDROID */
#endif /* FIDEBOOK_LIQUID_GLASS_H */
