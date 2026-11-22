/*
 * Offline Vulkan compute fixture runner for the ACTUAL committed glass shaders.
 * Controlled synthetic input only: not an Android app, HAL test or hardware demo.
 *
 * Usage: runner SHADER_DIR CASE_DIR WIDTH HEIGHT FRAMES --synthetic-input
 * Each frame-NNN.pc is the exact little-endian 32-byte driver/shader ABI below.
 * Inputs: frame-NNN.{comp,ov0,ov1,ov2,bg}.rgba, tightly packed RGBA8.
 * Optional frame-NNN.boxes.in (272 bytes) bypasses detection for apply unit tests.
 * Outputs: frame-NNN.out.rgba and frame-NNN.boxes.out (detector readback).
 * Images, descriptor sets and pipelines are reused across frames; inputs change.
 */
#include <vulkan/vulkan.h>

#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct GlassPC {
    int32_t dims[2];
    int32_t ov_count;
    int32_t level;
    int32_t bg_valid;
    int32_t bg_swizzle;
    int32_t blur_px;
    int32_t reserved;
};
_Static_assert(sizeof(struct GlassPC) == 32, "glass PC size");
_Static_assert(offsetof(struct GlassPC, dims) == 0, "dims offset");
_Static_assert(offsetof(struct GlassPC, ov_count) == 8, "ov_count offset");
_Static_assert(offsetof(struct GlassPC, level) == 12, "level offset");
_Static_assert(offsetof(struct GlassPC, bg_valid) == 16, "bg_valid offset");
_Static_assert(offsetof(struct GlassPC, bg_swizzle) == 20, "bg_swizzle offset");
_Static_assert(offsetof(struct GlassPC, blur_px) == 24, "blur_px offset");
_Static_assert(offsetof(struct GlassPC, reserved) == 28, "reserved offset");

struct Boxes {
    uint32_t hdr[4];
    int32_t rects[8][4];
    float params[8][4];
};
_Static_assert(sizeof(struct Boxes) == 272, "box SSBO size");
_Static_assert(offsetof(struct Boxes, rects) == 16, "box rect offset");
_Static_assert(offsetof(struct Boxes, params) == 144, "box params offset");

static void die(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fputs("GLASS_RUNNER_FAIL: ", stderr);
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
    va_end(args);
    exit(1);
}
#define VK_CHECK(expr) do { \
    VkResult result_ = (expr); \
    if (result_ != VK_SUCCESS) die("%s returned %d (line %d)", #expr, result_, __LINE__); \
} while (0)

struct Buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapped;
};
struct Image {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
};
struct Compute {
    VkDescriptorSetLayout descriptors;
    VkPipelineLayout layout;
    VkPipeline pipeline;
    VkDescriptorSet set;
};
struct Runner {
    VkInstance instance;
    VkDebugUtilsMessengerEXT messenger;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
    VkPhysicalDeviceMemoryProperties memory;
    VkCommandPool commands;
    VkCommandBuffer cmd;
    VkFence fence;
    VkDescriptorPool pool;
    struct Image images[6]; /* comp, ov0, ov1, ov2, bg, out */
    struct Buffer staging;
    struct Buffer boxes;
    struct Compute detect;
    struct Compute apply;
    uint32_t width, height;
    size_t bytes;
};
static unsigned validation_errors;
static int validation_enabled;

static VKAPI_ATTR VkBool32 VKAPI_CALL debug_message(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type,
    const VkDebugUtilsMessengerCallbackDataEXT *data, void *user) {
    (void)type;
    (void)user;
    if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) validation_errors++;
    fprintf(stderr, "Vulkan validation: %s\n", data->pMessage);
    return VK_FALSE;
}

static void path_frame(char *out, size_t size, const char *dir, uint32_t frame, const char *suffix) {
    int n = snprintf(out, size, "%s/frame-%03u.%s", dir, frame, suffix);
    if (n < 0 || (size_t)n >= size) die("fixture path too long");
}
static void read_exact(const char *path, void *out, size_t size) {
    FILE *f = fopen(path, "rb");
    if (!f) die("open %s: %s", path, strerror(errno));
    if (fread(out, 1, size, f) != size || fgetc(f) != EOF || ferror(f))
        die("%s: expected exactly %zu bytes", path, size);
    if (fclose(f)) die("close %s", path);
}
static void write_exact(const char *path, const void *data, size_t size) {
    FILE *f = fopen(path, "wb");
    if (!f) die("create %s: %s", path, strerror(errno));
    if (fwrite(data, 1, size, f) != size || fclose(f)) die("write %s", path);
}
static uint32_t number(const char *s, uint32_t max) {
    char *end;
    errno = 0;
    unsigned long n = strtoul(s, &end, 10);
    if (errno || !*s || *end || !n || n > max) die("invalid positive integer: %s", s);
    return (uint32_t)n;
}
static uint32_t memory_type(struct Runner *r, uint32_t bits, VkMemoryPropertyFlags flags) {
    for (uint32_t i = 0; i < r->memory.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (r->memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
    die("no compatible memory type (bits=%x flags=%x)", bits, flags);
    return 0;
}
static struct Buffer make_buffer(struct Runner *r, VkDeviceSize size, VkBufferUsageFlags usage) {
    struct Buffer b = {0};
    VkBufferCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_CHECK(vkCreateBuffer(r->device, &ci, NULL, &b.buffer));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(r->device, b.buffer, &req);
    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type(r, req.memoryTypeBits,
                                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VK_CHECK(vkAllocateMemory(r->device, &ai, NULL, &b.memory));
    VK_CHECK(vkBindBufferMemory(r->device, b.buffer, b.memory, 0));
    VK_CHECK(vkMapMemory(r->device, b.memory, 0, size, 0, &b.mapped));
    return b;
}
static struct Image make_image(struct Runner *r) {
    struct Image im = {0};
    VkImageCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {r->width, r->height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    VK_CHECK(vkCreateImage(r->device, &ci, NULL, &im.image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(r->device, im.image, &req);
    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type(r, req.memoryTypeBits, 0),
    };
    VK_CHECK(vkAllocateMemory(r->device, &ai, NULL, &im.memory));
    VK_CHECK(vkBindImageMemory(r->device, im.image, im.memory, 0));
    VkImageViewCreateInfo vi = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = im.image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VK_CHECK(vkCreateImageView(r->device, &vi, NULL, &im.view));
    return im;
}

static struct Compute make_compute(struct Runner *r, const char *directory, const char *name,
                                   uint32_t count, uint32_t box_binding, const int *image_map) {
    struct Compute c = {0};
    VkDescriptorSetLayoutBinding bindings[7] = {0};
    for (uint32_t i = 0; i < count; i++) {
        bindings[i].binding = i;
        bindings[i].descriptorType = i == box_binding ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        bindings[i].descriptorCount = 1;
        bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo di = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = count,
        .pBindings = bindings,
    };
    VK_CHECK(vkCreateDescriptorSetLayout(r->device, &di, NULL, &c.descriptors));
    VkPushConstantRange range = {VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(struct GlassPC)};
    VkPipelineLayoutCreateInfo li = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &c.descriptors,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &range,
    };
    VK_CHECK(vkCreatePipelineLayout(r->device, &li, NULL, &c.layout));
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/%s.spv", directory, name) >= (int)sizeof(path)) die("shader path too long");
    FILE *f = fopen(path, "rb");
    if (!f || fseek(f, 0, SEEK_END)) die("cannot read shader %s", path);
    long size = ftell(f);
    if (size < 20 || size % 4 || fseek(f, 0, SEEK_SET)) die("invalid SPIR-V size: %s", path);
    uint32_t *code = malloc((size_t)size);
    if (!code || fread(code, 1, (size_t)size, f) != (size_t)size || fclose(f)) die("read shader %s", path);
    if (code[0] != 0x07230203u) die("invalid SPIR-V magic: %s", path);
    VkShaderModuleCreateInfo si = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = (size_t)size,
        .pCode = code,
    };
    VkShaderModule module;
    VK_CHECK(vkCreateShaderModule(r->device, &si, NULL, &module));
    free(code);
    VkComputePipelineCreateInfo pi = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = module,
            .pName = "main",
        },
        .layout = c.layout,
    };
    VK_CHECK(vkCreateComputePipelines(r->device, VK_NULL_HANDLE, 1, &pi, NULL, &c.pipeline));
    vkDestroyShaderModule(r->device, module, NULL);
    VkDescriptorSetAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = r->pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &c.descriptors,
    };
    VK_CHECK(vkAllocateDescriptorSets(r->device, &ai, &c.set));
    VkDescriptorBufferInfo box_info = {r->boxes.buffer, 0, sizeof(struct Boxes)};
    VkDescriptorImageInfo images[7] = {0};
    VkWriteDescriptorSet writes[7] = {0};
    for (uint32_t i = 0; i < count; i++) {
        writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet = c.set;
        writes[i].dstBinding = i;
        writes[i].descriptorType = bindings[i].descriptorType;
        writes[i].descriptorCount = 1;
        if (i == box_binding) writes[i].pBufferInfo = &box_info;
        else {
            images[i].imageView = r->images[image_map[i]].view;
            images[i].imageLayout = VK_IMAGE_LAYOUT_GENERAL;
            writes[i].pImageInfo = &images[i];
        }
    }
    vkUpdateDescriptorSets(r->device, count, writes, 0, NULL);
    return c;
}

static void initialize(struct Runner *r, const char *shaders) {
    int validate = getenv("FIDEBOOK_TEST_VALIDATION") && !strcmp(getenv("FIDEBOOK_TEST_VALIDATION"), "1");
    validation_enabled = validate;
    const char *layer = "VK_LAYER_KHRONOS_validation";
    const char *extension = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    VkDebugUtilsMessengerCreateInfoEXT debug = {
        .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debug_message,
    };
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "fidebook-glass-synthetic-unit-test",
        .apiVersion = VK_API_VERSION_1_0,
    };
    VkInstanceCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = validate ? &debug : NULL,
        .pApplicationInfo = &app,
        .enabledLayerCount = validate ? 1 : 0,
        .ppEnabledLayerNames = &layer,
        .enabledExtensionCount = validate ? 1 : 0,
        .ppEnabledExtensionNames = &extension,
    };
    VK_CHECK(vkCreateInstance(&ci, NULL, &r->instance));
    if (validate) {
        PFN_vkCreateDebugUtilsMessengerEXT create = (PFN_vkCreateDebugUtilsMessengerEXT)
            vkGetInstanceProcAddr(r->instance, "vkCreateDebugUtilsMessengerEXT");
        if (!create) die("requested validation debug messenger unavailable");
        VK_CHECK(create(r->instance, &debug, NULL, &r->messenger));
    }
    uint32_t count = 0;
    VK_CHECK(vkEnumeratePhysicalDevices(r->instance, &count, NULL));
    if (!count) die("no Vulkan device; select the cached lavapipe ICD");
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) die("allocate device list");
    VK_CHECK(vkEnumeratePhysicalDevices(r->instance, &count, devices));
    r->physical = devices[0];
    free(devices);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(r->physical, &props);
    printf("GLASS_TEST_DEVICE (synthetic input, not Android): %s\n", props.deviceName);
    if (props.limits.maxComputeWorkGroupInvocations < 256 || props.limits.maxComputeSharedMemorySize < 12312)
        die("device limits too small for the actual detector");
    VkFormatProperties format;
    vkGetPhysicalDeviceFormatProperties(r->physical, VK_FORMAT_R8G8B8A8_UNORM, &format);
    if (!(format.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT)) die("RGBA8 storage images unsupported");
    uint32_t families = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(r->physical, &families, NULL);
    VkQueueFamilyProperties *queues = calloc(families, sizeof(*queues));
    if (!queues) die("allocate queue list");
    vkGetPhysicalDeviceQueueFamilyProperties(r->physical, &families, queues);
    r->family = UINT32_MAX;
    for (uint32_t i = 0; i < families; i++)
        if (queues[i].queueCount && (queues[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) { r->family = i; break; }
    free(queues);
    if (r->family == UINT32_MAX) die("no compute queue");
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qi = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = r->family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qi,
    };
    VK_CHECK(vkCreateDevice(r->physical, &device_info, NULL, &r->device));
    vkGetDeviceQueue(r->device, r->family, 0, &r->queue);
    vkGetPhysicalDeviceMemoryProperties(r->physical, &r->memory);
    for (unsigned i = 0; i < 6; i++) r->images[i] = make_image(r);
    r->staging = make_buffer(r, r->bytes * 6, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    r->boxes = make_buffer(r, sizeof(struct Boxes), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    VkDescriptorPoolSize sizes[2] = {{VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 9}, {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2}};
    VkDescriptorPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 2,
        .poolSizeCount = 2,
        .pPoolSizes = sizes,
    };
    VK_CHECK(vkCreateDescriptorPool(r->device, &pool, NULL, &r->pool));
    const int detect_map[4] = {1, 2, 3, -1};
    const int apply_map[7] = {0, 1, 2, 3, -1, 5, 4};
    r->detect = make_compute(r, shaders, "glass_detect", 4, 3, detect_map);
    r->apply = make_compute(r, shaders, "glass_apply", 7, 4, apply_map);
    VkCommandPoolCreateInfo commands = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = r->family,
    };
    VK_CHECK(vkCreateCommandPool(r->device, &commands, NULL, &r->commands));
    VkCommandBufferAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = r->commands,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VK_CHECK(vkAllocateCommandBuffers(r->device, &ai, &r->cmd));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VK_CHECK(vkCreateFence(r->device, &fence, NULL, &r->fence));
}

static void bind_compute(struct Runner *r, struct Compute *c, const struct GlassPC *pc) {
    vkCmdBindPipeline(r->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipeline);
    vkCmdBindDescriptorSets(r->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c->layout, 0, 1, &c->set, 0, NULL);
    vkCmdPushConstants(r->cmd, c->layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(*pc), pc);
}
static void run_frame(struct Runner *r, const char *directory, uint32_t frame) {
    char path[4096];
    struct GlassPC pc;
    path_frame(path, sizeof(path), directory, frame, "pc");
    read_exact(path, &pc, sizeof(pc));
    if (pc.dims[0] != (int32_t)r->width || pc.dims[1] != (int32_t)r->height || pc.ov_count < 0 || pc.ov_count > 3)
        die("invalid frame dimensions or overlay count");
    const char *inputs[5] = {"comp.rgba", "ov0.rgba", "ov1.rgba", "ov2.rgba", "bg.rgba"};
    for (unsigned i = 0; i < 5; i++) {
        path_frame(path, sizeof(path), directory, frame, inputs[i]);
        read_exact(path, (uint8_t *)r->staging.mapped + i * r->bytes, r->bytes);
    }
    path_frame(path, sizeof(path), directory, frame, "boxes.in");
    int manual = access(path, F_OK) == 0;
    memset(r->boxes.mapped, 0, sizeof(struct Boxes));
    if (manual) {
        read_exact(path, r->boxes.mapped, sizeof(struct Boxes));
        if (((struct Boxes *)r->boxes.mapped)->hdr[0] > 8) die("too many fixture boxes");
    } else if (errno != ENOENT) die("cannot inspect %s: %s", path, strerror(errno));

    VK_CHECK(vkResetCommandBuffer(r->cmd, 0));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VK_CHECK(vkBeginCommandBuffer(r->cmd, &begin));
    VkMemoryBarrier host = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
    };
    vkCmdPipelineBarrier(r->cmd, VK_PIPELINE_STAGE_HOST_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         0, 1, &host, 0, NULL, 0, NULL);
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier images[6];
    for (unsigned i = 0; i < 6; i++) {
        images[i] = (VkImageMemoryBarrier){
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = r->images[i].image,
            .subresourceRange = range,
        };
    }
    vkCmdPipelineBarrier(r->cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 6, images);
    VkBufferImageCopy copy = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {r->width, r->height, 1},
    };
    for (unsigned i = 0; i < 5; i++) {
        copy.bufferOffset = i * r->bytes;
        vkCmdCopyBufferToImage(r->cmd, r->staging.buffer, r->images[i].image, VK_IMAGE_LAYOUT_GENERAL, 1, &copy);
    }
    VkClearColorValue poison = {.float32 = {0.65f, 0.35f, 0.85f, 0.25f}};
    vkCmdClearColorImage(r->cmd, r->images[5].image, VK_IMAGE_LAYOUT_GENERAL, &poison, 1, &range);
    for (unsigned i = 0; i < 6; i++) {
        images[i].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        images[i].dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
        images[i].oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    }
    vkCmdPipelineBarrier(r->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         0, 0, NULL, 0, NULL, 6, images);
    if (!manual) {
        bind_compute(r, &r->detect, &pc);
        vkCmdDispatch(r->cmd, 1, 1, 1);
        VkMemoryBarrier detected = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        };
        vkCmdPipelineBarrier(r->cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             0, 1, &detected, 0, NULL, 0, NULL);
    }
    bind_compute(r, &r->apply, &pc);
    vkCmdDispatch(r->cmd, (r->width + 15) / 16, (r->height + 15) / 16, 1);
    VkImageMemoryBarrier output = images[5];
    output.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    output.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    output.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    vkCmdPipelineBarrier(r->cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &output);
    copy.bufferOffset = 5 * r->bytes;
    vkCmdCopyImageToBuffer(r->cmd, r->images[5].image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, r->staging.buffer, 1, &copy);
    VkMemoryBarrier readback = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
    };
    vkCmdPipelineBarrier(r->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &readback, 0, NULL, 0, NULL);
    VK_CHECK(vkEndCommandBuffer(r->cmd));
    VK_CHECK(vkResetFences(r->device, 1, &r->fence));
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &r->cmd,
    };
    VK_CHECK(vkQueueSubmit(r->queue, 1, &submit, r->fence));
    VK_CHECK(vkWaitForFences(r->device, 1, &r->fence, VK_TRUE, UINT64_C(60000000000)));
    path_frame(path, sizeof(path), directory, frame, "out.rgba");
    write_exact(path, (uint8_t *)r->staging.mapped + 5 * r->bytes, r->bytes);
    path_frame(path, sizeof(path), directory, frame, "boxes.out");
    write_exact(path, r->boxes.mapped, sizeof(struct Boxes));
}

static void destroy_compute(struct Runner *r, struct Compute *c) {
    vkDestroyPipeline(r->device, c->pipeline, NULL);
    vkDestroyPipelineLayout(r->device, c->layout, NULL);
    vkDestroyDescriptorSetLayout(r->device, c->descriptors, NULL);
}
static void destroy_buffer(struct Runner *r, struct Buffer *b) {
    vkUnmapMemory(r->device, b->memory);
    vkDestroyBuffer(r->device, b->buffer, NULL);
    vkFreeMemory(r->device, b->memory, NULL);
}
static void destroy(struct Runner *r) {
    VK_CHECK(vkDeviceWaitIdle(r->device));
    vkDestroyFence(r->device, r->fence, NULL);
    vkDestroyCommandPool(r->device, r->commands, NULL);
    vkDestroyDescriptorPool(r->device, r->pool, NULL);
    destroy_compute(r, &r->apply);
    destroy_compute(r, &r->detect);
    destroy_buffer(r, &r->boxes);
    destroy_buffer(r, &r->staging);
    for (unsigned i = 0; i < 6; i++) {
        vkDestroyImageView(r->device, r->images[i].view, NULL);
        vkDestroyImage(r->device, r->images[i].image, NULL);
        vkFreeMemory(r->device, r->images[i].memory, NULL);
    }
    vkDestroyDevice(r->device, NULL);
    if (r->messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT fn = (PFN_vkDestroyDebugUtilsMessengerEXT)
            vkGetInstanceProcAddr(r->instance, "vkDestroyDebugUtilsMessengerEXT");
        fn(r->instance, r->messenger, NULL);
    }
    vkDestroyInstance(r->instance, NULL);
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 7) die("usage: %s SHADER_DIR CASE_DIR WIDTH HEIGHT FRAMES --synthetic-input", argv[0]);
    uint32_t endian = 1;
    if (*(uint8_t *)&endian != 1) die("fixture format requires a little-endian host");
    struct Runner r = {0};
    r.width = number(argv[3], 8192);
    r.height = number(argv[4], 8192);
    uint32_t frames = number(argv[5], 1000);
    /* argv[6] is an explicit acknowledgement to prevent confusing this with
     * the existing physical Android HAL test runner. */
    if (strcmp(argv[6], "--synthetic-input")) die("last argument must be --synthetic-input");
    r.bytes = (size_t)r.width * r.height * 4;
    initialize(&r, argv[1]);
    for (uint32_t frame = 0; frame < frames; frame++) run_frame(&r, argv[2], frame);
    destroy(&r);
    if (validation_errors) die("%u Vulkan validation errors", validation_errors);
    printf("GLASS_COMPUTE_READBACK_OK: %u synthetic frame(s), Vulkan validation=%s\n", frames,
           validation_enabled ? "enabled (zero errors)" : "disabled (layer not requested)");
    return 0;
}
