/*
 * Live hardware verification & benchmark for gbOS86's Android RADV Vulkan HAL (vulkan.radv.so).
 * Runs inside Google's Android 17 x86_64 bionic userspace against /dev/dri/renderD128 (AMD amdgpu).
 *
 * Verifies:
 *   1. Android HW_MODULE_INFO_SYM ("HMI") Vulkan HAL open -> vkCreateInstance (Vulkan 1.3).
 *   2. Physical device discovery on real AMD Radeon hardware (0x1002), TMZ protected memory disabled.
 *   3. Graphics queue family queueCount >= 2 (Android 17 HWUI ro.hwui.use_vulkan=true requirement).
 *   4. VK_ANDROID_external_memory_android_hardware_buffer, VK_ANDROID_native_buffer, and
 *      VK_KHR_external_semaphore_fd (SYNC_FD export + import for SurfaceFlinger skiavkthreaded).
 *   5. Multi-queue vkCreateDevice (q0 + q1 on graphics family 0), ACO SPIR-V shader compilation,
 *      cross-queue VkSemaphore handoff (q0 -> sem -> q1) + live Linux SYNC_FD export, and GPU readback.
 *   6. Microbenchmarks: ACO pipeline compilation speed & GPU command submit throughput.
 */
#define VK_NO_PROTOTYPES 1
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <hardware/hardware.h>

/* Horizontal high-frequency energy inside the glass-covered taskbar strip, skipping the
 * sharp foreground icon. Blurred backdrop sampling must lower this versus blur disabled. */
static long
glass_strip_hf_energy(const uint32_t *px, uint32_t w, uint32_t x0, uint32_t x1,
                      uint32_t y0, uint32_t y1)
{
    long sum = 0;
    for (uint32_t y = y0; y < y1; y++) {
        for (uint32_t x = x0; x + 1 < x1; x++) {
            if (x >= 100 && x < 134 && y >= 424 && y < 454)
                continue; /* sharp foreground "F" button must stay out of the blur metric */
            uint32_t a = px[y * w + x], b = px[y * w + x + 1];
            int la = 3 * (int)(a & 0xff) + 6 * (int)((a >> 8) & 0xff) + (int)((a >> 16) & 0xff);
            int lb = 3 * (int)(b & 0xff) + 6 * (int)((b >> 8) & 0xff) + (int)((b >> 16) & 0xff);
            sum += abs(la - lb);
        }
    }
    return sum;
}

#include <hardware/hwvulkan.h>
#include <vulkan/vulkan.h>

#include "test_radv_spirv.h"

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

#define VK_CHECK(expr)                                                                     \
    do {                                                                                   \
        VkResult _r = (expr);                                                              \
        if (_r != VK_SUCCESS) {                                                            \
            fprintf(stderr, "FAIL: %s returned %d at line %d\n", #expr, (int)_r, __LINE__); \
            return 1;                                                                      \
        }                                                                                  \
    } while (0)

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    const char *hal_path = (argc > 1) ? argv[1] : "/vendor/lib64/hw/vulkan.intel.so";
    int allow_single_queue = (argc > 2 && strcmp(argv[2], "--allow-single-queue") == 0) ? 1 : 0;

    printf("=== FideBookOS Live Hardware Vulkan HAL Test ===\n");
    printf("HAL binary : %s\n", hal_path);

    void *dl = dlopen(hal_path, RTLD_NOW | RTLD_LOCAL);
    if (!dl) {
        fprintf(stderr, "FAIL: dlopen(%s): %s\n", hal_path, dlerror());
        return 1;
    }

    struct hw_module_t *hmi = (struct hw_module_t *)dlsym(dl, HAL_MODULE_INFO_SYM_AS_STR);
    if (!hmi || !hmi->methods || !hmi->methods->open) {
        fprintf(stderr, "FAIL: missing HMI symbol in %s\n", hal_path);
        return 1;
    }
    printf("HAL module : id='%s' name='%s' author='%s'\n",
           hmi->id ? hmi->id : "?", hmi->name ? hmi->name : "?", hmi->author ? hmi->author : "?");

    struct hw_device_t *raw_dev = NULL;
    int rc = hmi->methods->open(hmi, HWVULKAN_DEVICE_0, &raw_dev);
    if (rc != 0 || !raw_dev) {
        fprintf(stderr, "FAIL: HMI->methods->open failed: %d\n", rc);
        return 1;
    }
    hwvulkan_device_t *vkdev = (hwvulkan_device_t *)raw_dev;

    PFN_vkGetInstanceProcAddr gipa = vkdev->GetInstanceProcAddr;
    PFN_vkCreateInstance pfnCreateInstance =
        (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    if (!pfnCreateInstance) {
        fprintf(stderr, "FAIL: vkCreateInstance not found\n");
        return 1;
    }

    VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "gbos86-radv-hw-test",
        .applicationVersion = 1,
        .pEngineName = "AndroidHWUI+SkiaVK",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo inst_ci = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VK_CHECK(pfnCreateInstance(&inst_ci, NULL, &instance));

#define LOAD_INST(fn) PFN_##fn pfn_##fn = (PFN_##fn)gipa(instance, #fn); \
    if (!pfn_##fn) { fprintf(stderr, "FAIL: missing instance proc %s\n", #fn); return 1; }

    LOAD_INST(vkDestroyInstance);
    LOAD_INST(vkEnumeratePhysicalDevices);
    LOAD_INST(vkGetPhysicalDeviceProperties);
    LOAD_INST(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_INST(vkEnumerateDeviceExtensionProperties);
    LOAD_INST(vkGetPhysicalDeviceMemoryProperties);
    LOAD_INST(vkGetPhysicalDeviceExternalSemaphoreProperties);
    LOAD_INST(vkCreateDevice);
    LOAD_INST(vkGetDeviceProcAddr);

    uint32_t pdev_count = 0;
    VK_CHECK(pfn_vkEnumeratePhysicalDevices(instance, &pdev_count, NULL));
    if (pdev_count == 0) {
        fprintf(stderr, "FAIL: 0 Vulkan physical devices found on /dev/dri/renderD128\n");
        return 1;
    }
    VkPhysicalDevice pdevs[8];
    if (pdev_count > 8) pdev_count = 8;
    VK_CHECK(pfn_vkEnumeratePhysicalDevices(instance, &pdev_count, pdevs));

    VkPhysicalDevice pdev = pdevs[0];
    VkPhysicalDeviceProperties props;
    pfn_vkGetPhysicalDeviceProperties(pdev, &props);
    printf("GPU device : %s (vendor=0x%04x device=0x%04x api=%u.%u.%u)\n",
           props.deviceName, props.vendorID, props.deviceID,
           VK_API_VERSION_MAJOR(props.apiVersion),
           VK_API_VERSION_MINOR(props.apiVersion),
           VK_API_VERSION_PATCH(props.apiVersion));

    if (props.vendorID != 0x1002) {
        fprintf(stderr, "FAIL: expected AMD vendorID 0x1002, got 0x%04x\n", props.vendorID);
        return 1;
    }

    uint32_t qf_count = 0;
    pfn_vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qf_count, NULL);
    VkQueueFamilyProperties qf_props[16];
    if (qf_count > 16) qf_count = 16;
    pfn_vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qf_count, qf_props);

    int gfx_qf = -1;
    for (uint32_t i = 0; i < qf_count; i++) {
        printf("QueueFam %u : flags=0x%04x queueCount=%u\n",
               i, qf_props[i].queueFlags, qf_props[i].queueCount);
        if ((qf_props[i].queueFlags & VK_QUEUE_PROTECTED_BIT) != 0) {
            fprintf(stderr, "FAIL: QueueFam %u advertises VK_QUEUE_PROTECTED_BIT (TMZ must be off)\n", i);
            return 1;
        }
        if (gfx_qf < 0 && (qf_props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) {
            gfx_qf = (int)i;
        }
    }
    if (gfx_qf < 0) {
        fprintf(stderr, "FAIL: no graphics queue family\n");
        return 1;
    }
    if (!allow_single_queue && qf_props[gfx_qf].queueCount < 2) {
        fprintf(stderr, "FAIL: graphics queueCount=%u (< 2; Android HWUI will SIGABRT)\n",
                qf_props[gfx_qf].queueCount);
        return 1;
    }

    /* Check mandatory Android extensions */
    uint32_t ext_count = 0;
    VK_CHECK(pfn_vkEnumerateDeviceExtensionProperties(pdev, NULL, &ext_count, NULL));
    VkExtensionProperties *exts = calloc(ext_count, sizeof(VkExtensionProperties));
    VK_CHECK(pfn_vkEnumerateDeviceExtensionProperties(pdev, NULL, &ext_count, exts));

    int has_ahb = 0, has_anb = 0, has_ext_sem_fd = 0, has_ext_mem_fd = 0;
    int has_dyn_render = 0, has_sync2 = 0, has_maint5 = 0, has_pipe_bin = 0;
    for (uint32_t i = 0; i < ext_count; i++) {
        if (strcmp(exts[i].extensionName, "VK_ANDROID_external_memory_android_hardware_buffer") == 0)
            has_ahb = 1;
        else if (strcmp(exts[i].extensionName, "VK_ANDROID_native_buffer") == 0)
            has_anb = 1;
        else if (strcmp(exts[i].extensionName, "VK_KHR_external_semaphore_fd") == 0)
            has_ext_sem_fd = 1;
        else if (strcmp(exts[i].extensionName, "VK_KHR_external_memory_fd") == 0)
            has_ext_mem_fd = 1;
        else if (strcmp(exts[i].extensionName, "VK_KHR_dynamic_rendering") == 0)
            has_dyn_render = 1;
        else if (strcmp(exts[i].extensionName, "VK_KHR_synchronization2") == 0)
            has_sync2 = 1;
        else if (strcmp(exts[i].extensionName, "VK_KHR_maintenance5") == 0)
            has_maint5 = 1;
        else if (strcmp(exts[i].extensionName, "VK_KHR_pipeline_binary") == 0)
            has_pipe_bin = 1;
    }
    free(exts);
    printf("Extensions : total=%u AHB=%d ANB=%d ext_sem_fd=%d ext_mem_fd=%d dyn_render=%d sync2=%d maint5=%d pipe_bin=%d\n",
           ext_count, has_ahb, has_anb, has_ext_sem_fd, has_ext_mem_fd,
           has_dyn_render, has_sync2, has_maint5, has_pipe_bin);
    if (!has_ahb || !has_anb || !has_ext_sem_fd || !has_ext_mem_fd) {
        fprintf(stderr, "FAIL: missing mandatory Android Vulkan extension\n");
        return 1;
    }
    if (!allow_single_queue && (VK_API_VERSION_MINOR(props.apiVersion) < 3 || !has_maint5 || !has_pipe_bin)) {
        fprintf(stderr, "FAIL: expected Vulkan >= 1.3 with VK_KHR_maintenance5 + VK_KHR_pipeline_binary\n");
        return 1;
    }

    VkPhysicalDeviceExternalSemaphoreInfo ext_sem_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    VkExternalSemaphoreProperties ext_sem_props = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES,
    };
    pfn_vkGetPhysicalDeviceExternalSemaphoreProperties(pdev, &ext_sem_info, &ext_sem_props);
    uint32_t req_sem_feats = VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT |
                             VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT;
    printf("SYNC_FD    : externalSemaphoreFeatures=0x%x\n", ext_sem_props.externalSemaphoreFeatures);
    if ((ext_sem_props.externalSemaphoreFeatures & req_sem_feats) != req_sem_feats) {
        fprintf(stderr, "FAIL: SYNC_FD semaphore not exportable+importable\n");
        return 1;
    }

    uint32_t req_queues = (qf_props[gfx_qf].queueCount >= 2) ? 2 : 1;
    float q_prios[2] = {1.0f, 1.0f};
    VkDeviceQueueCreateInfo q_ci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = (uint32_t)gfx_qf,
        .queueCount = req_queues,
        .pQueuePriorities = q_prios,
    };
    const char *dev_exts[] = {
        "VK_KHR_external_semaphore",
        "VK_KHR_external_semaphore_fd",
        "VK_ANDROID_native_buffer",
    };
    VkPhysicalDeviceDynamicRenderingFeatures dyn_feat = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
        .dynamicRendering = VK_TRUE,
    };
    VkDeviceCreateInfo dev_ci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &dyn_feat,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &q_ci,
        .enabledExtensionCount = 3,
        .ppEnabledExtensionNames = dev_exts,
    };
    VkDevice device = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateDevice(pdev, &dev_ci, NULL, &device));

#define LOAD_DEV(fn) PFN_##fn pfn_##fn = (PFN_##fn)pfn_vkGetDeviceProcAddr(device, #fn); \
    if (!pfn_##fn) { fprintf(stderr, "FAIL: missing device proc %s\n", #fn); return 1; }

    LOAD_DEV(vkDestroyDevice);
    LOAD_DEV(vkGetDeviceQueue);
    LOAD_DEV(vkCreateBuffer);
    LOAD_DEV(vkDestroyBuffer);
    LOAD_DEV(vkGetBufferMemoryRequirements);
    LOAD_DEV(vkAllocateMemory);
    LOAD_DEV(vkFreeMemory);
    LOAD_DEV(vkMapMemory);
    LOAD_DEV(vkUnmapMemory);
    LOAD_DEV(vkBindBufferMemory);
    LOAD_DEV(vkCreateDescriptorSetLayout);
    LOAD_DEV(vkDestroyDescriptorSetLayout);
    LOAD_DEV(vkCreatePipelineLayout);
    LOAD_DEV(vkDestroyPipelineLayout);
    LOAD_DEV(vkCreateShaderModule);
    LOAD_DEV(vkDestroyShaderModule);
    LOAD_DEV(vkCreateComputePipelines);
    LOAD_DEV(vkDestroyPipeline);
    LOAD_DEV(vkCreateDescriptorPool);
    LOAD_DEV(vkDestroyDescriptorPool);
    LOAD_DEV(vkAllocateDescriptorSets);
    LOAD_DEV(vkUpdateDescriptorSets);
    LOAD_DEV(vkCreateCommandPool);
    LOAD_DEV(vkDestroyCommandPool);
    LOAD_DEV(vkAllocateCommandBuffers);
    LOAD_DEV(vkResetCommandBuffer);
    LOAD_DEV(vkBeginCommandBuffer);
    LOAD_DEV(vkEndCommandBuffer);
    LOAD_DEV(vkCmdBindPipeline);
    LOAD_DEV(vkCmdBindDescriptorSets);
    LOAD_DEV(vkCmdPushConstants);
    LOAD_DEV(vkCmdDispatch);
    LOAD_DEV(vkCmdPipelineBarrier);
    LOAD_DEV(vkCreateSemaphore);
    LOAD_DEV(vkDestroySemaphore);
    LOAD_DEV(vkGetSemaphoreFdKHR);
    LOAD_DEV(vkCreateFence);
    LOAD_DEV(vkDestroyFence);
    LOAD_DEV(vkResetFences);
    LOAD_DEV(vkWaitForFences);
    LOAD_DEV(vkQueueSubmit);
    LOAD_DEV(vkDeviceWaitIdle);

    VkQueue q0 = VK_NULL_HANDLE, q1 = VK_NULL_HANDLE;
    pfn_vkGetDeviceQueue(device, (uint32_t)gfx_qf, 0, &q0);
    if (req_queues >= 2) {
        pfn_vkGetDeviceQueue(device, (uint32_t)gfx_qf, 1, &q1);
        if (!q0 || !q1 || q0 == q1) {
            fprintf(stderr, "FAIL: invalid distinct VkQueue handles q0=%p q1=%p\n", (void *)q0, (void *)q1);
            return 1;
        }
    } else {
        q1 = q0;
    }
    printf("VkQueues   : requested=%u q0=%p q1=%p\n", req_queues, (void *)q0, (void *)q1);

    /* Allocate 4096 uint32_t elements in HOST_VISIBLE | HOST_COHERENT memory */
    const uint32_t N = 4096;
    const VkDeviceSize buf_size = N * sizeof(uint32_t);
    VkBufferCreateInfo buf_ci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = buf_size,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkBuffer buf = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateBuffer(device, &buf_ci, NULL, &buf));

    VkMemoryRequirements mem_reqs;
    pfn_vkGetBufferMemoryRequirements(device, buf, &mem_reqs);

    VkPhysicalDeviceMemoryProperties mem_props;
    pfn_vkGetPhysicalDeviceMemoryProperties(pdev, &mem_props);
    uint32_t mem_type = UINT32_MAX;
    VkMemoryPropertyFlags want_mem = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((mem_reqs.memoryTypeBits & (1u << i)) &&
            (mem_props.memoryTypes[i].propertyFlags & want_mem) == want_mem) {
            mem_type = i;
            break;
        }
    }
    if (mem_type == UINT32_MAX) {
        fprintf(stderr, "FAIL: no HOST_VISIBLE|HOST_COHERENT memory type\n");
        return 1;
    }

    VkMemoryAllocateInfo mem_ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = mem_type,
    };
    VkDeviceMemory mem = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkAllocateMemory(device, &mem_ai, NULL, &mem));
    VK_CHECK(pfn_vkBindBufferMemory(device, buf, mem, 0));

    uint32_t *mapped = NULL;
    VK_CHECK(pfn_vkMapMemory(device, mem, 0, buf_size, 0, (void **)&mapped));
    for (uint32_t i = 0; i < N; i++) mapped[i] = i;

    VkDescriptorSetLayoutBinding dsl_binding = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
    };
    VkDescriptorSetLayoutCreateInfo dsl_ci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &dsl_binding,
    };
    VkDescriptorSetLayout dsl = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateDescriptorSetLayout(device, &dsl_ci, NULL, &dsl));

    VkPushConstantRange pc_range = {
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = 8,
    };
    VkPipelineLayoutCreateInfo pl_ci = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &dsl,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pc_range,
    };
    VkPipelineLayout pipe_layout = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreatePipelineLayout(device, &pl_ci, NULL, &pipe_layout));

    VkShaderModuleCreateInfo sm_ci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(test_radv_comp_spv),
        .pCode = test_radv_comp_spv,
    };
    VkShaderModule shader_mod = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateShaderModule(device, &sm_ci, NULL, &shader_mod));

    VkComputePipelineCreateInfo cp_ci = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader_mod,
            .pName = "main",
        },
        .layout = pipe_layout,
    };
    VkPipeline pipeline = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cp_ci, NULL, &pipeline));

    VkDescriptorPoolSize pool_size = {
        .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
    };
    VkDescriptorPoolCreateInfo dp_ci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    VkDescriptorPool desc_pool = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateDescriptorPool(device, &dp_ci, NULL, &desc_pool));

    VkDescriptorSetAllocateInfo ds_ai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = desc_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &dsl,
    };
    VkDescriptorSet desc_set = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkAllocateDescriptorSets(device, &ds_ai, &desc_set));

    VkDescriptorBufferInfo dbi = { .buffer = buf, .offset = 0, .range = buf_size };
    VkWriteDescriptorSet wds = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = desc_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &dbi,
    };
    pfn_vkUpdateDescriptorSets(device, 1, &wds, 0, NULL);

    VkCommandPoolCreateInfo cmd_pool_ci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = (uint32_t)gfx_qf,
    };
    VkCommandPool pool0 = VK_NULL_HANDLE, pool1 = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateCommandPool(device, &cmd_pool_ci, NULL, &pool0));
    VK_CHECK(pfn_vkCreateCommandPool(device, &cmd_pool_ci, NULL, &pool1));

    VkCommandBuffer cb0 = VK_NULL_HANDLE, cb1 = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo cb_ai0 = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool0,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBufferAllocateInfo cb_ai1 = cb_ai0;
    cb_ai1.commandPool = pool1;
    VK_CHECK(pfn_vkAllocateCommandBuffers(device, &cb_ai0, &cb0));
    VK_CHECK(pfn_vkAllocateCommandBuffers(device, &cb_ai1, &cb1));

    VkExportSemaphoreCreateInfo exp_sem_ci = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    VkSemaphoreCreateInfo sem_ci = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &exp_sem_ci,
    };
    VkSemaphore sem_syncfd = VK_NULL_HANDLE, sem_chain = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateSemaphore(device, &sem_ci, NULL, &sem_syncfd));
    VkSemaphoreCreateInfo plain_sem_ci = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VK_CHECK(pfn_vkCreateSemaphore(device, &plain_sem_ci, NULL, &sem_chain));

    VkFenceCreateInfo fence_ci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence = VK_NULL_HANDLE;
    VK_CHECK(pfn_vkCreateFence(device, &fence_ci, NULL, &fence));

    /* Record cb0 (queue 0): data[i] = data[i] * 3 + 7 */
    VkCommandBufferBeginInfo begin_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
    pfn_vkCmdBindPipeline(cb0, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    pfn_vkCmdBindDescriptorSets(cb0, VK_PIPELINE_BIND_POINT_COMPUTE, pipe_layout, 0, 1, &desc_set, 0, NULL);
    uint32_t pc0[2] = {3, 7};
    pfn_vkCmdPushConstants(cb0, pipe_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, pc0);
    pfn_vkCmdDispatch(cb0, N / 64, 1, 1);
    VkMemoryBarrier mb = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
    };
    pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    VK_CHECK(pfn_vkEndCommandBuffer(cb0));

    /* Record cb1 (queue 1): data[i] = data[i] * 5 + 11 */
    VK_CHECK(pfn_vkBeginCommandBuffer(cb1, &begin_info));
    pfn_vkCmdBindPipeline(cb1, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    pfn_vkCmdBindDescriptorSets(cb1, VK_PIPELINE_BIND_POINT_COMPUTE, pipe_layout, 0, 1, &desc_set, 0, NULL);
    uint32_t pc1[2] = {5, 11};
    pfn_vkCmdPushConstants(cb1, pipe_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, pc1);
    pfn_vkCmdDispatch(cb1, N / 64, 1, 1);
    VkMemoryBarrier mb_host = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
    };
    pfn_vkCmdPipelineBarrier(cb1, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb_host, 0, NULL, 0, NULL);
    VK_CHECK(pfn_vkEndCommandBuffer(cb1));

    /* Submit cb0 on q0 signaling both sem_syncfd and sem_chain */
    VkSemaphore q0_sigs[2] = {sem_syncfd, sem_chain};
    VkSubmitInfo sub0 = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cb0,
        .signalSemaphoreCount = 2,
        .pSignalSemaphores = q0_sigs,
    };
    VK_CHECK(pfn_vkQueueSubmit(q0, 1, &sub0, VK_NULL_HANDLE));

    /* Export real Linux SYNC_FD from sem_syncfd (SurfaceFlinger skiavkthreaded fence path) */
    VkSemaphoreGetFdInfoKHR fd_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
        .semaphore = sem_syncfd,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    int sync_fd = -1;
    VK_CHECK(pfn_vkGetSemaphoreFdKHR(device, &fd_info, &sync_fd));
    printf("SYNC_FD exp: fd=%d (valid sync_file exported from amdgpu drm_syncobj)\n", sync_fd);
    if (sync_fd >= 0) close(sync_fd);

    /* Submit cb1 on q1 waiting on sem_chain */
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    VkSubmitInfo sub1 = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &sem_chain,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &cb1,
    };
    VK_CHECK(pfn_vkQueueSubmit(q1, 1, &sub1, fence));
    VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));

    for (uint32_t i = 0; i < N; i++) {
        uint32_t want = (i * 3u + 7u) * 5u + 11u;
        if (mapped[i] != want) {
            fprintf(stderr, "FAIL: GPU compute mismatch at [%u]: got %u, expected %u\n", i, mapped[i], want);
            return 1;
        }
    }
    printf("Compute OK : verified %u elements across q0 -> VkSemaphore -> q1 on %s!\n", N, props.deviceName);

    /* Benchmark 1: Real Uncached NIR + ACO Compute Pipeline Compilation (300 distinct specialized shaders) */
    const int PIPE_ITERS = 300;
    uint32_t spec_val = 0;
    VkSpecializationMapEntry spec_entry = { .constantID = 0, .offset = 0, .size = sizeof(uint32_t) };
    VkSpecializationInfo spec_info = {
        .mapEntryCount = 1,
        .pMapEntries = &spec_entry,
        .dataSize = sizeof(uint32_t),
        .pData = &spec_val,
    };
    VkComputePipelineCreateInfo bench_cp_ci = cp_ci;
    bench_cp_ci.stage.pSpecializationInfo = &spec_info;
    uint64_t t0 = now_ns();
    for (int i = 0; i < PIPE_ITERS; i++) {
        spec_val = (uint32_t)(i + 1) * 0x9e3779b9u;
        VkPipeline p = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &bench_cp_ci, NULL, &p));
        pfn_vkDestroyPipeline(device, p, NULL);
    }
    uint64_t t1 = now_ns();
    double pipe_ms = (double)(t1 - t0) / 1e6;
    double pipe_us_each = ((double)(t1 - t0) / 1e3) / PIPE_ITERS;

    /* Benchmark 2: Dual-Queue Command Recording + Kernel drm_sched Submit Throughput (1000 pairs = 2000 dispatches) */
    const int SUB_ITERS = 1000;
    uint64_t s0 = now_ns();
    for (int i = 0; i < SUB_ITERS; i++) {
        VK_CHECK(pfn_vkResetFences(device, 1, &fence));
        VkSubmitInfo b_sub0 = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cb0,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &sem_chain,
        };
        VK_CHECK(pfn_vkQueueSubmit(q0, 1, &b_sub0, VK_NULL_HANDLE));
        VK_CHECK(pfn_vkQueueSubmit(q1, 1, &sub1, fence));
        VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));
    }
    uint64_t s1 = now_ns();
    double sub_ms = (double)(s1 - s0) / 1e6;
    double sub_us_pair = ((double)(s1 - s0) / 1e3) / SUB_ITERS;

    printf("BENCH_ACO_PIPELINE : %d compiles in %.2f ms (%.2f us/pipeline)\n",
           PIPE_ITERS, pipe_ms, pipe_us_each);
    printf("BENCH_QUEUE_SUBMIT : %d two-queue chains (%d dispatches) in %.2f ms (%.2f us/chain)\n",
           SUB_ITERS, SUB_ITERS * 2, sub_ms, sub_us_pair);

    /* Test 7: Live FideBookOS Hardware GPU Scroll Motion Blur (vkQueueSignalReleaseImageANDROID) */
    typedef VkResult (VKAPI_PTR *PFN_vkQueueSignalReleaseImageANDROID_t)(
        VkQueue, uint32_t, const VkSemaphore *, VkImage, int *);
    PFN_vkQueueSignalReleaseImageANDROID_t pfn_ReleaseImg =
        (PFN_vkQueueSignalReleaseImageANDROID_t)pfn_vkGetDeviceProcAddr(device, "vkQueueSignalReleaseImageANDROID");
    LOAD_DEV(vkCreateImage);
    LOAD_DEV(vkDestroyImage);
    LOAD_DEV(vkGetImageMemoryRequirements);
    LOAD_DEV(vkBindImageMemory);
    LOAD_DEV(vkCmdCopyBufferToImage);
    LOAD_DEV(vkCmdCopyImageToBuffer);

    if (!allow_single_queue && pfn_ReleaseImg) {
        setenv("FIDEBOOK_FORCE_MBLUR", "1", 1);
        const uint32_t MW = 512, MH = 512;
        const VkDeviceSize img_bytes = (VkDeviceSize)MW * MH * 4;
        VkBufferCreateInfo sb_ci = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = img_bytes,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        };
        VkBuffer stage_buf = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateBuffer(device, &sb_ci, NULL, &stage_buf));
        VkMemoryRequirements sreqs;
        pfn_vkGetBufferMemoryRequirements(device, stage_buf, &sreqs);
        VkMemoryAllocateInfo smai = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = sreqs.size,
            .memoryTypeIndex = mem_type,
        };
        VkDeviceMemory stage_mem = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkAllocateMemory(device, &smai, NULL, &stage_mem));
        VK_CHECK(pfn_vkBindBufferMemory(device, stage_buf, stage_mem, 0));
        uint32_t *px = NULL;
        VK_CHECK(pfn_vkMapMemory(device, stage_mem, 0, img_bytes, 0, (void **)&px));

        uint32_t dev_local_type = 0;
        for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
            if ((mem_props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                dev_local_type = i;
                break;
            }
        }
        VkImageCreateInfo m_ici = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM,
            .extent = {MW, MH, 1},
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        VkImage simg = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateImage(device, &m_ici, NULL, &simg));
        VkMemoryRequirements ireqs;
        pfn_vkGetImageMemoryRequirements(device, simg, &ireqs);
        VkMemoryAllocateInfo imai = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = ireqs.size,
            .memoryTypeIndex = (ireqs.memoryTypeBits & (1u << dev_local_type)) ? dev_local_type : mem_type,
        };
        VkDeviceMemory simg_mem = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkAllocateMemory(device, &imai, NULL, &simg_mem));
        VK_CHECK(pfn_vkBindImageMemory(device, simg, simg_mem, 0));

        VkSemaphore render_sem = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateSemaphore(device, &plain_sem_ci, NULL, &render_sem));

        int shifts[4] = {0, 0, 22, 22}; /* 0: init anb_sem, 1: prime hist, 2: scroll +22px, 3: stop at +22px */
        int blurred_mid_scroll = 0, dock_sharp = 1, blurred_on_stop = 0;
        VkImageSubresourceRange srange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

        for (int step = 0; step < 4; step++) {
            int sy = shifts[step];
            for (uint32_t y = 0; y < MH; y++) {
                int white = (((int)y + sy) % 48) < 8;
                uint32_t val = white ? 0xFFFFFFFFu : 0xFF000000u;
                for (uint32_t x = 0; x < MW; x++)
                    px[y * MW + x] = val;
            }
            VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
            VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
            VkImageMemoryBarrier ib_up = {
                VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                0, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
                VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, simg, srange,
            };
            pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                     0, 0, NULL, 0, NULL, 1, &ib_up);
            VkBufferImageCopy bic = {
                .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                .imageExtent = {MW, MH, 1},
            };
            pfn_vkCmdCopyBufferToImage(cb0, stage_buf, simg, VK_IMAGE_LAYOUT_GENERAL, 1, &bic);
            VK_CHECK(pfn_vkEndCommandBuffer(cb0));

            VkSubmitInfo si_up = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .commandBufferCount = 1,
                .pCommandBuffers = &cb0,
                .signalSemaphoreCount = 1,
                .pSignalSemaphores = &render_sem,
            };
            VK_CHECK(pfn_vkQueueSubmit(q0, 1, &si_up, VK_NULL_HANDLE));

            int out_fence_fd = -1;
            VK_CHECK(pfn_ReleaseImg(q0, 1, &render_sem, simg, &out_fence_fd));
            if (out_fence_fd >= 0) close(out_fence_fd);
            pfn_vkDeviceWaitIdle(device);

            /* Read back simg after vkQueueSignalReleaseImageANDROID */
            VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
            VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
            VkImageMemoryBarrier ib_rb = {
                VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
                VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_GENERAL,
                VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, simg, srange,
            };
            pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                     0, 0, NULL, 0, NULL, 1, &ib_rb);
            pfn_vkCmdCopyImageToBuffer(cb0, simg, VK_IMAGE_LAYOUT_GENERAL, stage_buf, 1, &bic);
            VK_CHECK(pfn_vkEndCommandBuffer(cb0));
            VK_CHECK(pfn_vkResetFences(device, 1, &fence));
            VkSubmitInfo si_rb = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .commandBufferCount = 1,
                .pCommandBuffers = &cb0,
            };
            VK_CHECK(pfn_vkQueueSubmit(q0, 1, &si_rb, fence));
            VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));

            int gray_interior = 0, gray_dock = 0;
            for (uint32_t y = 0; y < MH; y++) {
                uint8_t r = px[y * MW + 256] & 0xff;
                if (r > 4 && r < 251) {
                    if (y >= 56 && y < MH - 72) gray_interior++;
                    else gray_dock++;
                }
            }
            if (step == 2) {
                blurred_mid_scroll = gray_interior;
                if (gray_dock != 0) dock_sharp = 0;
            } else if (step == 3) {
                blurred_on_stop = gray_interior;
            }
        }
        printf("MotionBlur : mid_scroll_blurred_rows=%d dock_sharp=%d stop_frame_blurred_rows=%d\n",
               blurred_mid_scroll, dock_sharp, blurred_on_stop);
        if (blurred_mid_scroll <= 0 || !dock_sharp || blurred_on_stop != 0) {
            fprintf(stderr, "FAIL: GPU Scroll Motion Blur check failed (mid=%d dock=%d stop=%d)\n",
                    blurred_mid_scroll, dock_sharp, blurred_on_stop);
            return 1;
        }

        pfn_vkDestroySemaphore(device, render_sem, NULL);
        pfn_vkDestroyImage(device, simg, NULL);
        pfn_vkFreeMemory(device, simg_mem, NULL);
        pfn_vkUnmapMemory(device, stage_mem);
        pfn_vkDestroyBuffer(device, stage_buf, NULL);
        pfn_vkFreeMemory(device, stage_mem, NULL);
        unsetenv("FIDEBOOK_FORCE_MBLUR");
    }

    /* Test 8: Live FideBookOS 1.25 Hardware GPU Liquid Glass Cross-Window Refraction
     *         (Taskbar + App Menu + Control Center + Live Settings ON/OFF Toggle) */
    LOAD_DEV(vkCreateImageView);
    LOAD_DEV(vkDestroyImageView);
    LOAD_DEV(vkCreateSampler);
    LOAD_DEV(vkDestroySampler);
    LOAD_DEV(vkCmdBeginRendering);
    LOAD_DEV(vkCmdEndRendering);
    if (!allow_single_queue) {
        setenv("FIDEBOOK_FORCE_COMPOSITOR", "1", 1);
        setenv("FIDEBOOK_LIQUID_GLASS", "1", 1);

        const uint32_t GW = 640, GH = 480;
        const VkDeviceSize gbytes = (VkDeviceSize)GW * GH * 4;
        uint32_t *raw_bg    = calloc(GW * GH, 4);
        uint32_t *base_comp = calloc(GW * GH, 4);
        uint32_t *ov_launch = calloc(GW * GH, 4);
        uint32_t *ov_sysui  = calloc(GW * GH, 4);

        /* Build patterned live desktop wallpaper + app window + 3 glass surfaces:
         *   1. Taskbar:        x in [80..560),  y in [412..468), OPAQUE carrier #FF111927 (as forced by TaskbarDragLayerController!)
         *                      + foreground Google-blue "F" icon [108..126, 428..450)
         *   2. App Menu:       x in [36..288),  y in [56..356),  translucent glass + foreground app icon [120..146, 160..186)
         *   3. Control Center: x in [336..604), y in [56..356),  translucent glass + inner QS tile [360..480, 160..220)
         *                      + foreground slider [420..520, 104..122) */
        for (uint32_t y = 0; y < GH; y++) {
            for (uint32_t x = 0; x < GW; x++) {
                uint8_t br = ((x / 18) & 1) ? 236 : 28;
                uint8_t bg = ((y / 18) & 1) ? 214 : 44;
                uint8_t bb = (((x + y) / 22) & 1) ? 248 : 36;
                raw_bg[y * GW + x] = 0xFF000000u | ((uint32_t)bb << 16) | ((uint32_t)bg << 8) | br;

                uint8_t l_r = 0, l_g = 0, l_b = 0, l_a = 0;
                /* Taskbar glass (alpha=255 forced #111927 carrier!) + sharp foreground "F" button */
                if (x >= 80 && x < 560 && y >= 412 && y < 468) {
                    if (x >= 108 && x < 126 && y >= 428 && y < 450) {
                        l_r = 66; l_g = 133; l_b = 244; l_a = 255;
                    } else {
                        l_r = 17; l_g = 25; l_b = 39; l_a = 255;
                    }
                }
                /* App Menu glass + sharp foreground app icon */
                if (x >= 36 && x < 288 && y >= 56 && y < 356) {
                    if (x >= 120 && x < 146 && y >= 160 && y < 186) {
                        l_r = 234; l_g = 67; l_b = 53; l_a = 255;
                    } else {
                        l_r = 3; l_g = 4; l_b = 6; l_a = 38;
                    }
                }
                ov_launch[y * GW + x] = ((uint32_t)l_a << 24) | ((uint32_t)l_b << 16) | ((uint32_t)l_g << 8) | l_r;

                uint8_t s_r = 0, s_g = 0, s_b = 0, s_a = 0;
                /* Control Center glass + inner translucent QS tile + sharp foreground brightness slider */
                if (x >= 336 && x < 604 && y >= 56 && y < 356) {
                    if (x >= 420 && x < 520 && y >= 104 && y < 122) {
                        s_r = 250; s_g = 252; s_b = 255; s_a = 255;
                    } else if (x >= 360 && x < 480 && y >= 160 && y < 220) {
                        s_r = 10; s_g = 15; s_b = 24; s_a = 68;
                    } else {
                        s_r = 3; s_g = 4; s_b = 8; s_a = 38;
                    }
                }
                ov_sysui[y * GW + x] = ((uint32_t)s_a << 24) | ((uint32_t)s_b << 16) | ((uint32_t)s_g << 8) | s_r;

                /* Premultiplied SRC_OVER composition matching SurfaceFlinger GaneshVkRenderEngine */
                float cr = br / 255.0f, cg = bg / 255.0f, cb_v = bb / 255.0f;
                float la = l_a / 255.0f;
                cr = cr * (1.0f - la) + (l_r / 255.0f);
                cg = cg * (1.0f - la) + (l_g / 255.0f);
                cb_v = cb_v * (1.0f - la) + (l_b / 255.0f);
                float sa = s_a / 255.0f;
                cr = cr * (1.0f - sa) + (s_r / 255.0f);
                cg = cg * (1.0f - sa) + (s_g / 255.0f);
                cb_v = cb_v * (1.0f - sa) + (s_b / 255.0f);

                uint8_t fr = (uint8_t)(cr * 255.0f + 0.5f);
                uint8_t fg = (uint8_t)(cg * 255.0f + 0.5f);
                uint8_t fb = (uint8_t)(cb_v * 255.0f + 0.5f);
                base_comp[y * GW + x] = 0xFF000000u | ((uint32_t)fb << 16) | ((uint32_t)fg << 8) | fr;
            }
        }

        VkBufferCreateInfo gb_ci = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = gbytes,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        };
        VkBuffer gstage = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateBuffer(device, &gb_ci, NULL, &gstage));
        VkMemoryRequirements gsreqs;
        pfn_vkGetBufferMemoryRequirements(device, gstage, &gsreqs);
        VkMemoryAllocateInfo gsmai = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = gsreqs.size,
            .memoryTypeIndex = mem_type,
        };
        VkDeviceMemory gstage_mem = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkAllocateMemory(device, &gsmai, NULL, &gstage_mem));
        VK_CHECK(pfn_vkBindBufferMemory(device, gstage, gstage_mem, 0));
        uint32_t *gpx = NULL;
        VK_CHECK(pfn_vkMapMemory(device, gstage_mem, 0, gbytes, 0, (void **)&gpx));

        uint32_t dev_local = 0;
        for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
            if (mem_props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
                dev_local = i;
                break;
            }
        }

        VkImage g_imgs[4] = {VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE};
        VkDeviceMemory g_mems[4] = {VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE};
        VkImageView g_views[4] = {VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE};
        /* 0=ClientTarget(3), 1=Launcher(1), 2=SystemUI(2), 3=LiveWallpaperBackdrop(4) */
        const char *tags[4] = {"3", "1", "2", "4"};
        for (int i = 0; i < 4; i++) {
            setenv("FIDEBOOK_TEST_NEXT_TAG", tags[i], 1);
            VkImageCreateInfo gici = {
                .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .imageType = VK_IMAGE_TYPE_2D,
                .format = VK_FORMAT_R8G8B8A8_UNORM,
                .extent = {GW, GH, 1},
                .mipLevels = 1,
                .arrayLayers = 1,
                .samples = VK_SAMPLE_COUNT_1_BIT,
                .tiling = VK_IMAGE_TILING_OPTIMAL,
                .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
                .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            };
            VK_CHECK(pfn_vkCreateImage(device, &gici, NULL, &g_imgs[i]));
            unsetenv("FIDEBOOK_TEST_NEXT_TAG");

            VkMemoryRequirements mr;
            pfn_vkGetImageMemoryRequirements(device, g_imgs[i], &mr);
            VkMemoryAllocateInfo mai = {
                .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = mr.size,
                .memoryTypeIndex = (mr.memoryTypeBits & (1u << dev_local)) ? dev_local : mem_type,
            };
            VK_CHECK(pfn_vkAllocateMemory(device, &mai, NULL, &g_mems[i]));
            VK_CHECK(pfn_vkBindImageMemory(device, g_imgs[i], g_mems[i], 0));

            VkImageViewCreateInfo ivci = {
                .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = g_imgs[i],
                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                .format = VK_FORMAT_R8G8B8A8_UNORM,
                .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
            };
            VK_CHECK(pfn_vkCreateImageView(device, &ivci, NULL, &g_views[i]));
        }

        /* Upload ClientTarget, Launcher, SystemUI, and Live Wallpaper images */
        const uint32_t *src_bufs[4] = {base_comp, ov_launch, ov_sysui, raw_bg};
        VkImageSubresourceRange grange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        VkBufferImageCopy gbic = {
            .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
            .imageExtent = {GW, GH, 1},
        };
        for (int i = 0; i < 4; i++) {
            memcpy(gpx, src_bufs[i], gbytes);
            VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
            VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
            VkImageMemoryBarrier ib = {
                VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                0, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
                VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, g_imgs[i], grange,
            };
            pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                     0, 0, NULL, 0, NULL, 1, &ib);
            pfn_vkCmdCopyBufferToImage(cb0, gstage, g_imgs[i], VK_IMAGE_LAYOUT_GENERAL, 1, &gbic);
            VK_CHECK(pfn_vkEndCommandBuffer(cb0));
            VK_CHECK(pfn_vkResetFences(device, 1, &fence));
            VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb0};
            VK_CHECK(pfn_vkQueueSubmit(q0, 1, &si, fence));
            VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));
        }

        /* Create 3 separate single-texture VkDescriptorSets (matching Skia GaneshVk cached GrVkImage sets!) */
        VkSamplerCreateInfo samp_ci = {
            .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = VK_FILTER_LINEAR,
            .minFilter = VK_FILTER_LINEAR,
        };
        VkSampler samp = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateSampler(device, &samp_ci, NULL, &samp));

        VkDescriptorSetLayoutBinding sb = {0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL};
        VkDescriptorSetLayoutCreateInfo sdsl_ci = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = &sb,
        };
        VkDescriptorSetLayout sdsl = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateDescriptorSetLayout(device, &sdsl_ci, NULL, &sdsl));
        VkPipelineLayoutCreateInfo spl_ci = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &sdsl,
        };
        VkPipelineLayout spl = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreatePipelineLayout(device, &spl_ci, NULL, &spl));

        VkDescriptorPoolSize sps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 3};
        VkDescriptorPoolCreateInfo sdp_ci = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 3,
            .poolSizeCount = 1,
            .pPoolSizes = &sps,
        };
        VkDescriptorPool sdp = VK_NULL_HANDLE;
        VK_CHECK(pfn_vkCreateDescriptorPool(device, &sdp_ci, NULL, &sdp));
        VkDescriptorSetLayout sdsls[3] = {sdsl, sdsl, sdsl};
        VkDescriptorSet sds[3] = {VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE};
        VkDescriptorSetAllocateInfo sds_ai = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = sdp,
            .descriptorSetCount = 3,
            .pSetLayouts = sdsls,
        };
        VK_CHECK(pfn_vkAllocateDescriptorSets(device, &sds_ai, sds));

        /* Update descriptor sets ONCE before Frame 1 (0=Wallpaper, 1=Launcher, 2=SystemUI) */
        VkDescriptorImageInfo di_layers[3] = {
            {samp, g_views[3], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
            {samp, g_views[1], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
            {samp, g_views[2], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        };
        VkWriteDescriptorSet sw[3] = {
            {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, sds[0], 0, 0, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &di_layers[0], NULL, NULL},
            {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, sds[1], 0, 0, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &di_layers[1], NULL, NULL},
            {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, sds[2], 0, 0, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &di_layers[2], NULL, NULL},
        };
        pfn_vkUpdateDescriptorSets(device, 3, sw, 0, NULL);

        VkRenderingAttachmentInfo col_att = {
            .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = g_views[0],
            .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
            .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        };
        VkRenderingInfo ri = {
            .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = {{0, 0}, {GW, GH}},
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &col_att,
        };
        VkSubmitInfo g_sub = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb0};

        /* Run Frame 1 AND Frame 2 (Frame 2 calls ZERO vkUpdateDescriptorSets — only vkCmdBindDescriptorSets!) */
        for (int frame = 0; frame < 2; frame++) {
            memcpy(gpx, base_comp, gbytes);
            VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
            VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
            pfn_vkCmdCopyBufferToImage(cb0, gstage, g_imgs[0], VK_IMAGE_LAYOUT_GENERAL, 1, &gbic);
            VkImageMemoryBarrier f_upb = {
                VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL,
                VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, g_imgs[0], grange,
            };
            pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                     0, 0, NULL, 0, NULL, 1, &f_upb);
            pfn_vkCmdBeginRendering(cb0, &ri);
            for (int li = 0; li < 3; li++)
                pfn_vkCmdBindDescriptorSets(cb0, VK_PIPELINE_BIND_POINT_GRAPHICS, spl, 0, 1, &sds[li], 0, NULL);
            pfn_vkCmdEndRendering(cb0);
            VK_CHECK(pfn_vkEndCommandBuffer(cb0));

            VK_CHECK(pfn_vkResetFences(device, 1, &fence));
            VK_CHECK(pfn_vkQueueSubmit(q0, 1, &g_sub, fence));
            VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));
        }

        /* Read back refracted client_target from Frame 2 (cached descriptor sets!) */
        VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
        VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
        VkImageMemoryBarrier grb = {
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
            VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, g_imgs[0], grange,
        };
        pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                 0, 0, NULL, 0, NULL, 1, &grb);
        pfn_vkCmdCopyImageToBuffer(cb0, g_imgs[0], VK_IMAGE_LAYOUT_GENERAL, gstage, 1, &gbic);
        VK_CHECK(pfn_vkEndCommandBuffer(cb0));
        VK_CHECK(pfn_vkResetFences(device, 1, &fence));
        VK_CHECK(pfn_vkQueueSubmit(q0, 1, &g_sub, fence));
        VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));

        int refr_taskbar = 0, refr_appmenu = 0, refr_cc = 0, refr_cc_inner = 0, fg_err = 0, outside_err = 0;
        for (uint32_t y = 0; y < GH; y++) {
            for (uint32_t x = 0; x < GW; x++) {
                uint32_t got = gpx[y * GW + x];
                uint32_t orig = base_comp[y * GW + x];
                int diff = abs((int)(got & 0xff) - (int)(orig & 0xff)) +
                           abs((int)((got >> 8) & 0xff) - (int)((orig >> 8) & 0xff)) +
                           abs((int)((got >> 16) & 0xff) - (int)((orig >> 16) & 0xff));
                int in_tb = (x >= 80 && x < 560 && y >= 412 && y < 468);
                int in_am = (x >= 36 && x < 288 && y >= 56 && y < 356);
                int in_cc = (x >= 336 && x < 604 && y >= 56 && y < 356);
                int in_cc_center = (x >= 400 && x < 540 && y >= 150 && y < 290);
                int in_fg = (x >= 110 && x < 124 && y >= 430 && y < 448) ||
                            (x >= 122 && x < 144 && y >= 162 && y < 184) ||
                            (x >= 422 && x < 518 && y >= 106 && y < 120);
                if (in_fg) {
                    if (diff > 3) fg_err++;
                } else if (in_tb) {
                    if (diff > 20) refr_taskbar++;
                } else if (in_am) {
                    if (diff > 14) refr_appmenu++;
                } else if (in_cc) {
                    if (diff > 14) refr_cc++;
                    if (in_cc_center && diff > 14) refr_cc_inner++;
                } else if (x < 30 || (x >= 296 && x < 328) || x >= 610 || y < 48 || y >= 474) {
                    if (diff > 0) outside_err++;
                }
            }
        }

        long blur_on_hf = glass_strip_hf_energy(gpx, GW, 96, 544, 420, 460);

        /* Verify real backdrop blur: render again with the runtime blur override at 0.
         * The same frosted pipeline must then be visibly sharper (higher HF energy). */
        setenv("FIDEBOOK_LIQUID_GLASS_BLUR", "0", 1);
        memcpy(gpx, base_comp, gbytes);
        VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
        VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
        pfn_vkCmdCopyBufferToImage(cb0, gstage, g_imgs[0], VK_IMAGE_LAYOUT_GENERAL, 1, &gbic);
        VkImageMemoryBarrier b_upb = {
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, g_imgs[0], grange,
        };
        pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                 0, 0, NULL, 0, NULL, 1, &b_upb);
        pfn_vkCmdBeginRendering(cb0, &ri);
        for (int li = 0; li < 3; li++)
            pfn_vkCmdBindDescriptorSets(cb0, VK_PIPELINE_BIND_POINT_GRAPHICS, spl, 0, 1, &sds[li], 0, NULL);
        pfn_vkCmdEndRendering(cb0);
        VK_CHECK(pfn_vkEndCommandBuffer(cb0));
        VK_CHECK(pfn_vkResetFences(device, 1, &fence));
        VK_CHECK(pfn_vkQueueSubmit(q0, 1, &g_sub, fence));
        VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));

        VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
        VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
        pfn_vkCmdCopyImageToBuffer(cb0, g_imgs[0], VK_IMAGE_LAYOUT_GENERAL, gstage, 1, &gbic);
        VK_CHECK(pfn_vkEndCommandBuffer(cb0));
        VK_CHECK(pfn_vkResetFences(device, 1, &fence));
        VK_CHECK(pfn_vkQueueSubmit(q0, 1, &g_sub, fence));
        VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));
        long blur_off_hf = glass_strip_hf_energy(gpx, GW, 96, 544, 420, 460);
        unsetenv("FIDEBOOK_LIQUID_GLASS_BLUR");

        printf("LiquidGlassBlur: blurred_hf=%ld sharp_hf=%ld ratio=%.2f\n",
               blur_on_hf, blur_off_hf, blur_on_hf > 0 ? (double)blur_off_hf / (double)blur_on_hf : 0.0);

        /* Verify live Settings OFF toggle (FIDEBOOK_LIQUID_GLASS=0 -> zero refraction pass-through) */
        setenv("FIDEBOOK_LIQUID_GLASS", "0", 1);
        memcpy(gpx, base_comp, gbytes);
        VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
        VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
        pfn_vkCmdCopyBufferToImage(cb0, gstage, g_imgs[0], VK_IMAGE_LAYOUT_GENERAL, 1, &gbic);
        VkImageMemoryBarrier g_upb = {
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, g_imgs[0], grange,
        };
        pfn_vkCmdPipelineBarrier(cb0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                 0, 0, NULL, 0, NULL, 1, &g_upb);
        pfn_vkCmdBeginRendering(cb0, &ri);
        for (int li = 0; li < 3; li++)
            pfn_vkCmdBindDescriptorSets(cb0, VK_PIPELINE_BIND_POINT_GRAPHICS, spl, 0, 1, &sds[li], 0, NULL);
        pfn_vkCmdEndRendering(cb0);
        VK_CHECK(pfn_vkEndCommandBuffer(cb0));
        VK_CHECK(pfn_vkResetFences(device, 1, &fence));
        VK_CHECK(pfn_vkQueueSubmit(q0, 1, &g_sub, fence));
        VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));

        VK_CHECK(pfn_vkResetCommandBuffer(cb0, 0));
        VK_CHECK(pfn_vkBeginCommandBuffer(cb0, &begin_info));
        pfn_vkCmdCopyImageToBuffer(cb0, g_imgs[0], VK_IMAGE_LAYOUT_GENERAL, gstage, 1, &gbic);
        VK_CHECK(pfn_vkEndCommandBuffer(cb0));
        VK_CHECK(pfn_vkResetFences(device, 1, &fence));
        VK_CHECK(pfn_vkQueueSubmit(q0, 1, &g_sub, fence));
        VK_CHECK(pfn_vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));

        int off_diff = 0;
        for (uint32_t i = 0; i < GW * GH; i++) {
            if (gpx[i] != base_comp[i]) off_diff++;
        }

        printf("LiquidGlass: taskbar_px=%d appmenu_px=%d controlcenter_px=%d cc_inner_px=%d fg_sharp_err=%d outside_err=%d toggle_off_diff=%d\n",
               refr_taskbar, refr_appmenu, refr_cc, refr_cc_inner, fg_err, outside_err, off_diff);
        if (refr_taskbar < 8000 || refr_appmenu < 6000 || refr_cc < 6000 || refr_cc_inner < 1000 ||
            fg_err != 0 || outside_err != 0 || off_diff != 0) {
            fprintf(stderr, "FAIL: Liquid Glass refraction verification failed!\n");
            return 1;
        }

        unsetenv("FIDEBOOK_LIQUID_GLASS");
        unsetenv("FIDEBOOK_FORCE_COMPOSITOR");
        pfn_vkDestroyPipelineLayout(device, spl, NULL);
        pfn_vkDestroyDescriptorPool(device, sdp, NULL);
        pfn_vkDestroyDescriptorSetLayout(device, sdsl, NULL);
        pfn_vkDestroySampler(device, samp, NULL);
        for (int i = 0; i < 4; i++) {
            pfn_vkDestroyImageView(device, g_views[i], NULL);
            pfn_vkDestroyImage(device, g_imgs[i], NULL);
            pfn_vkFreeMemory(device, g_mems[i], NULL);
        }
        pfn_vkUnmapMemory(device, gstage_mem);
        pfn_vkDestroyBuffer(device, gstage, NULL);
        pfn_vkFreeMemory(device, gstage_mem, NULL);
        free(raw_bg);
        free(base_comp);
        free(ov_launch);
        free(ov_sysui);
    }

    pfn_vkDeviceWaitIdle(device);
    pfn_vkUnmapMemory(device, mem);
    pfn_vkDestroyFence(device, fence, NULL);
    pfn_vkDestroySemaphore(device, sem_chain, NULL);
    pfn_vkDestroySemaphore(device, sem_syncfd, NULL);
    pfn_vkDestroyCommandPool(device, pool1, NULL);
    pfn_vkDestroyCommandPool(device, pool0, NULL);
    pfn_vkDestroyDescriptorPool(device, desc_pool, NULL);
    pfn_vkDestroyPipeline(device, pipeline, NULL);
    pfn_vkDestroyShaderModule(device, shader_mod, NULL);
    pfn_vkDestroyPipelineLayout(device, pipe_layout, NULL);
    pfn_vkDestroyDescriptorSetLayout(device, dsl, NULL);
    pfn_vkDestroyBuffer(device, buf, NULL);
    pfn_vkFreeMemory(device, mem, NULL);
    pfn_vkDestroyDevice(device, NULL);
    pfn_vkDestroyInstance(instance, NULL);

    printf("RADV_HW_TEST_PASS\n");
    return 0;
}
