// Probe of PyroWave's Vulkan decoder shaders on MoltenVK (issue #13, docs/PYROWAVE_APPLE.md): the device's features,
// whether the shaders compile into Metal pipelines, and the time of the inverse wavelet transform with PyroWave's own
// SPIR-V, laid out as its WaveletBuffers do. Linked straight against libMoltenVK.dylib; see run.sh.
//   probe <idwt.spv> <dequant-mode1.spv> <width> <height> <420|444> <frames> [fp16-stored-levels, default 2]
#include <vulkan/vulkan.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s:%d %s = %d\n", __FILE__, __LINE__, #x, r_); exit(1); } } while (0)

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static uint32_t *read_spv(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *size = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *data = malloc(*size); if (fread(data, 1, *size, f) != *size) exit(1); fclose(f); return data;
}

static VkPhysicalDevice gpu; static VkDevice dev; static VkPhysicalDeviceMemoryProperties memprops;

static uint32_t memtype(uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (memprops.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "no memory type\n"); exit(1);
}

static VkImage make_image(VkFormat fmt, uint32_t w, uint32_t h, uint32_t mips, uint32_t layers) {
    VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ci.imageType = VK_IMAGE_TYPE_2D; ci.format = fmt; ci.extent = (VkExtent3D){ w, h, 1 };
    ci.mipLevels = mips; ci.arrayLayers = layers; ci.samples = VK_SAMPLE_COUNT_1_BIT; ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE; ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage image; CHECK(vkCreateImage(dev, &ci, NULL, &image));
    VkMemoryRequirements req; vkGetImageMemoryRequirements(dev, image, &req);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = req.size; ai.memoryTypeIndex = memtype(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &ai, NULL, &mem)); CHECK(vkBindImageMemory(dev, image, mem, 0));
    return image;
}

static VkImageView make_view(VkImage image, VkFormat fmt, VkImageViewType type, uint32_t mip, uint32_t layer, uint32_t layers) {
    VkImageViewCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    ci.image = image; ci.viewType = type; ci.format = fmt;
    ci.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, mip, 1, layer, layers };
    VkImageView v; CHECK(vkCreateImageView(dev, &ci, NULL, &v)); return v;
}

static VkPipeline make_pipeline(VkShaderModule module, VkPipelineLayout layout, VkBool32 spec, double *ms) {
    VkSpecializationMapEntry entry = { 0, 0, sizeof(VkBool32) };
    VkSpecializationInfo si = { 1, &entry, sizeof(VkBool32), &spec };
    VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    ci.stage = (VkPipelineShaderStageCreateInfo){ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                                                  VK_SHADER_STAGE_COMPUTE_BIT, module, "main", &si };
    ci.layout = layout;
    VkPipeline p; double t0 = now_ms(); CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p)); *ms = now_ms() - t0;
    return p;
}

static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static void report(const char *name, double *v, int n) {
    qsort(v, n, sizeof(double), cmp);
    printf("%s: median %.3f  p95 %.3f  max %.3f  min %.3f (ms, %d frames)\n", name, v[n / 2], v[(int)(n * 0.95)], v[n - 1], v[0], n);
}

int main(int argc, char **argv) {
    if (argc < 7) {
        fprintf(stderr, "usage: probe <idwt.spv> <dequant-mode1.spv> <width> <height> <420|444> <frames> [fp16-stored-levels]\n");
        return 2;
    }
    const char *spvIdwt = argv[1], *spvDequant = argv[2];
    uint32_t W = atoi(argv[3]), H = atoi(argv[4]); int is444 = !strcmp(argv[5], "444"); int frames = atoi(argv[6]);
    uint32_t halfLevels = argc > 7 ? atoi(argv[7]) : 2;
    int warm = 100;

    // Linked directly, MoltenVK needs no portability enumeration (that is an extension of the Vulkan loader).
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "pyrowave-probe", 1, "none", 1, VK_API_VERSION_1_2 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL };
    VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1; CHECK(vkEnumeratePhysicalDevices(inst, &n, &gpu)); if (n == 0) return 3;

    VkPhysicalDeviceVulkan11Properties p11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES };
    VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES, &p11 };
    VkPhysicalDeviceVulkan13Properties p13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES, &p12 };
    VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p13 };
    vkGetPhysicalDeviceProperties2(gpu, &props);
    VkPhysicalDeviceVulkan11Features f11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
    VkPhysicalDeviceVulkan12Features f12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f11 };
    VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &f12 };
    VkPhysicalDeviceFeatures2 feats = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f13 };
    vkGetPhysicalDeviceFeatures2(gpu, &feats);
    vkGetPhysicalDeviceMemoryProperties(gpu, &memprops);

    printf("device: %s, api %u.%u.%u, driverID %d (%s %s), vendor 0x%x\n", props.properties.deviceName,
           VK_VERSION_MAJOR(props.properties.apiVersion), VK_VERSION_MINOR(props.properties.apiVersion), VK_VERSION_PATCH(props.properties.apiVersion),
           p12.driverID, p12.driverName, p12.driverInfo, props.properties.vendorID);
    printf("subgroup: size %u (min %u max %u), ops 0x%x (basic1 vote2 arith4 ballot8 shuffle10 shufflerel20), stages 0x%x, requiredSubgroupSizeStages 0x%x\n",
           p11.subgroupSize, p13.minSubgroupSize, p13.maxSubgroupSize, p11.subgroupSupportedOperations, p11.subgroupSupportedStages, p13.requiredSubgroupSizeStages);
    uint32_t need = VK_SUBGROUP_FEATURE_VOTE_BIT | VK_SUBGROUP_FEATURE_BALLOT_BIT | VK_SUBGROUP_FEATURE_ARITHMETIC_BIT |
                    VK_SUBGROUP_FEATURE_SHUFFLE_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT | VK_SUBGROUP_FEATURE_BASIC_BIT;
    printf("PyroWave subgroup requirement (vote, ballot, arithmetic, shuffle, shuffle-relative, basic): %s\n", (p11.subgroupSupportedOperations & need) == need ? "met" : "NOT met");
    printf("features: shaderFloat16 %d, storageBuffer8BitAccess %d, synchronization2 %d, subgroupSizeControl %d, computeFullSubgroups %d, writeWithoutFormat %d\n",
           f12.shaderFloat16, f12.storageBuffer8BitAccess, f13.synchronization2, f13.subgroupSizeControl, f13.computeFullSubgroups, feats.features.shaderStorageImageWriteWithoutFormat);
    printf("limits: maxTexelBufferElements %u, maxComputeSharedMemorySize %u, maxComputeWorkGroupInvocations %u, timestampPeriod %.3f, timestampComputeAndGraphics %d\n",
           props.properties.limits.maxTexelBufferElements, props.properties.limits.maxComputeSharedMemorySize,
           props.properties.limits.maxComputeWorkGroupInvocations, props.properties.limits.timestampPeriod, props.properties.limits.timestampComputeAndGraphics);

    struct { VkFormat f; const char *name; } fmts[] = { { VK_FORMAT_R16_SFLOAT, "R16_SFLOAT" }, { VK_FORMAT_R32_SFLOAT, "R32_SFLOAT" },
        { VK_FORMAT_R8_UNORM, "R8_UNORM" }, { VK_FORMAT_R16_UNORM, "R16_UNORM" }, { VK_FORMAT_R8_UINT, "R8_UINT" }, { VK_FORMAT_R16_UINT, "R16_UINT" }, { VK_FORMAT_R32_UINT, "R32_UINT" } };
    for (size_t i = 0; i < sizeof fmts / sizeof *fmts; i++) {
        VkFormatProperties fp; vkGetPhysicalDeviceFormatProperties(gpu, fmts[i].f, &fp);
        printf("format %-11s sampled %d, storage image %d, uniform texel buffer %d\n", fmts[i].name,
               !!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT), !!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT),
               !!(fp.bufferFeatures & VK_FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER_BIT));
    }

    // Device
    float prio = 1; uint32_t qn = 0; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, NULL);
    VkQueueFamilyProperties qprops[8]; if (qn > 8) qn = 8; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, qprops);
    uint32_t family = 0; for (uint32_t i = 0; i < qn; i++) if (qprops[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { family = i; break; }
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &prio };
    VkPhysicalDeviceVulkan12Features e12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    e12.shaderFloat16 = f12.shaderFloat16; e12.storageBuffer8BitAccess = f12.storageBuffer8BitAccess;
    VkPhysicalDeviceVulkan13Features e13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &e12 };
    e13.synchronization2 = f13.synchronization2; e13.subgroupSizeControl = f13.subgroupSizeControl; e13.computeFullSubgroups = f13.computeFullSubgroups;
    VkPhysicalDeviceFeatures2 e2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &e13 };
    e2.features.shaderStorageImageWriteWithoutFormat = VK_TRUE;
    const char *dext[] = { "VK_KHR_portability_subset" };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &e2, 0, 1, &qci, 0, NULL, 1, dext };
    CHECK(vkCreateDevice(gpu, &dci, NULL, &dev));
    VkQueue queue; vkGetDeviceQueue(dev, family, 0, &queue);

    // Pipelines
    size_t sz; uint32_t *code = read_spv(spvIdwt, &sz);
    VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sz, code };
    VkShaderModule idwtModule; CHECK(vkCreateShaderModule(dev, &smci, NULL, &idwtModule));
    VkSamplerCreateInfo sci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    sci.magFilter = sci.minFilter = VK_FILTER_NEAREST; sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sci.addressModeU = sci.addressModeV = sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT; sci.maxLod = 0;
    VkSampler sampler; CHECK(vkCreateSampler(dev, &sci, NULL, &sampler));
    VkDescriptorSetLayoutBinding b[2] = {
        { 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL } };
    VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 2, b };
    VkDescriptorSetLayout dsl; CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 16 };
    VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &dsl, 1, &pcr };
    VkPipelineLayout pl; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));
    double ms0, ms1;
    VkPipeline pipeNoShift = make_pipeline(idwtModule, pl, VK_FALSE, &ms0), pipeShift = make_pipeline(idwtModule, pl, VK_TRUE, &ms1);
    printf("iDWT pipelines created: %.1f ms and %.1f ms (cold: SPIR-V to MSL to Metal)\n", ms0, ms1);

    // Dequantisation pipeline (STORAGE_MODE 1, texel buffers), created only to prove that it compiles.
    code = read_spv(spvDequant, &sz);
    smci.codeSize = sz; smci.pCode = code;
    VkShaderModule dqModule; CHECK(vkCreateShaderModule(dev, &smci, NULL, &dqModule));
    VkDescriptorSetLayoutBinding db[5] = {
        { 0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 2, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 3, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 4, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL } };
    VkDescriptorSetLayoutCreateInfo ddslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 5, db };
    VkDescriptorSetLayout ddsl; CHECK(vkCreateDescriptorSetLayout(dev, &ddslci, NULL, &ddsl));
    VkPushConstantRange dpcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 20 };
    VkPipelineLayoutCreateInfo dplci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &ddsl, 1, &dpcr };
    VkPipelineLayout dpl; CHECK(vkCreatePipelineLayout(dev, &dplci, NULL, &dpl));
    VkPipeline dqPipe = make_pipeline(dqModule, dpl, VK_FALSE, &ms0);
    printf("dequantisation pipeline (texel-buffer mode) created: %.1f ms\n", ms0);
    (void)dqPipe;

    // Images, laid out as PyroWave's WaveletBuffers::allocate_images does.
    uint32_t AW = (W + 31) & ~31u, AH = (H + 31) & ~31u; if (AW < 128) AW = 128; if (AH < 128) AH = 128;
    VkImage hi = make_image(VK_FORMAT_R16_SFLOAT, AW / 2, AH / 2, halfLevels, 12);
    VkImage lo = halfLevels < 5 ? make_image(VK_FORMAT_R32_SFLOAT, AW / 2 >> halfLevels, AH / 2 >> halfLevels, 5 - halfLevels, 12) : VK_NULL_HANDLE;
    VkImage planes[3]; VkImageView planeViews[3];
    for (int c = 0; c < 3; c++) {
        uint32_t pw = (c && !is444) ? W / 2 : W, ph = (c && !is444) ? H / 2 : H;
        planes[c] = make_image(VK_FORMAT_R8_UNORM, pw, ph, 1, 1);
        planeViews[c] = make_view(planes[c], VK_FORMAT_R8_UNORM, VK_IMAGE_VIEW_TYPE_2D, 0, 0, 1);
    }
    VkImageView sampleView[3][5], llView[3][5];
    for (int c = 0; c < 3; c++) for (uint32_t l = 0; l < 5; l++) {
        VkImage img = l < halfLevels ? hi : lo; VkFormat fmt = l < halfLevels ? VK_FORMAT_R16_SFLOAT : VK_FORMAT_R32_SFLOAT; uint32_t mip = l < halfLevels ? l : l - halfLevels;
        sampleView[c][l] = make_view(img, fmt, VK_IMAGE_VIEW_TYPE_2D_ARRAY, mip, 4 * c, 4);
        llView[c][l] = make_view(img, fmt, VK_IMAGE_VIEW_TYPE_2D, mip, 4 * c, 1);
    }

    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, family };
    VkCommandPool pool; CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    // To GENERAL
    {
        VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
        VkCommandBuffer cb; CHECK(vkAllocateCommandBuffers(dev, &cai, &cb));
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        CHECK(vkBeginCommandBuffer(cb, &bi));
        VkImage all[] = { hi, lo, planes[0], planes[1], planes[2] };
        for (int i = 0; i < 5; i++) {
            if (!all[i]) continue;
            VkImageMemoryBarrier ib = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
            ib.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; ib.newLayout = VK_IMAGE_LAYOUT_GENERAL; ib.srcQueueFamilyIndex = ib.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            ib.image = all[i]; ib.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0, VK_REMAINING_ARRAY_LAYERS };
            ib.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
        }
        CHECK(vkEndCommandBuffer(cb));
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb };
        CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); CHECK(vkQueueWaitIdle(queue));
    }

    // Random coefficients in every band image, so that texture reads move real data (never-written memory is cheap).
    {
        VkImage targets[2] = { hi, lo }; uint32_t levelsOf[2] = { halfLevels, 5 - halfLevels }; uint32_t bytes[2] = { 2, 4 };
        uint32_t baseW[2] = { AW / 2, (AW / 2) >> halfLevels }, baseH[2] = { AH / 2, (AH / 2) >> halfLevels };
        VkDeviceSize need = 0;
        for (int t = 0; t < 2; t++) if (targets[t]) for (uint32_t m = 0; m < levelsOf[t]; m++) {
            VkDeviceSize sz2 = (VkDeviceSize)12 * (baseW[t] >> m) * (baseH[t] >> m) * bytes[t]; if (sz2 > need) need = sz2;
        }
        VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, need, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_SHARING_MODE_EXCLUSIVE };
        VkBuffer staging; CHECK(vkCreateBuffer(dev, &bci, NULL, &staging));
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(dev, staging, &req);
        VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, memtype(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
        VkDeviceMemory smem; CHECK(vkAllocateMemory(dev, &mai, NULL, &smem)); CHECK(vkBindBufferMemory(dev, staging, smem, 0));
        void *map; CHECK(vkMapMemory(dev, smem, 0, need, 0, &map));
        VkCommandPoolCreateInfo up = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, family };
        VkCommandPool upPool; CHECK(vkCreateCommandPool(dev, &up, NULL, &upPool));
        uint32_t seed = 12345;
        for (int t = 0; t < 2; t++) if (targets[t]) for (uint32_t m = 0; m < levelsOf[t]; m++) {
            uint32_t w = baseW[t] >> m, h = baseH[t] >> m; size_t count = (size_t)12 * w * h;
            for (size_t i = 0; i < count; i++) {
                seed = seed * 1664525u + 1013904223u; float v = ((float)(seed >> 8) / 16777216.0f - 0.5f) * 0.1f;
                if (bytes[t] == 2) ((_Float16 *)map)[i] = (_Float16)v; else ((float *)map)[i] = v;
            }
            VkCommandBufferAllocateInfo ucai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, upPool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
            VkCommandBuffer ucb; CHECK(vkAllocateCommandBuffers(dev, &ucai, &ucb));
            VkCommandBufferBeginInfo ubi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
            CHECK(vkBeginCommandBuffer(ucb, &ubi));
            VkBufferImageCopy region = { 0, 0, 0, { VK_IMAGE_ASPECT_COLOR_BIT, m, 0, 12 }, { 0, 0, 0 }, { w, h, 1 } };
            vkCmdCopyBufferToImage(ucb, staging, targets[t], VK_IMAGE_LAYOUT_GENERAL, 1, &region);
            CHECK(vkEndCommandBuffer(ucb));
            VkSubmitInfo usi = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &ucb };
            CHECK(vkQueueSubmit(queue, 1, &usi, VK_NULL_HANDLE)); CHECK(vkQueueWaitIdle(queue));
        }
    }

    // Descriptor sets: one per pass.
    int passes = 0; struct { int c, l; } plan[16];
    for (int l = 4; l >= 0; l--) for (int c = 0; c < 3; c++) {
        if (l == 0 && c && !is444) continue;
        plan[passes].c = c; plan[passes].l = l; passes++;
    }
    VkDescriptorPoolSize dps[2] = { { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 16 }, { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 16 } };
    VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 16, 2, dps };
    VkDescriptorPool dpool; CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
    VkDescriptorSet sets[16];
    for (int i = 0; i < passes; i++) {
        VkDescriptorSetAllocateInfo dai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dpool, 1, &dsl };
        CHECK(vkAllocateDescriptorSets(dev, &dai, &sets[i]));
        int c = plan[i].c, l = plan[i].l;
        int toPlane = (l == 0) || (l == 1 && c && !is444);
        VkDescriptorImageInfo in = { sampler, sampleView[c][l], VK_IMAGE_LAYOUT_GENERAL };
        VkDescriptorImageInfo out = { VK_NULL_HANDLE, toPlane ? planeViews[c] : llView[c][l - 1], VK_IMAGE_LAYOUT_GENERAL };
        VkWriteDescriptorSet w[2] = {
            { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, sets[i], 0, 0, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &in },
            { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, sets[i], 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &out } };
        vkUpdateDescriptorSets(dev, 2, w, 0, NULL);
    }

    // One command buffer per frame, each with its own pair of timestamps.
    int total = warm + frames;
    VkQueryPoolCreateInfo qpci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, NULL, 0, VK_QUERY_TYPE_TIMESTAMP, 2 * total };
    VkQueryPool qp; CHECK(vkCreateQueryPool(dev, &qpci, NULL, &qp));
    VkCommandBuffer *cbs = malloc(sizeof(VkCommandBuffer) * total);
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, total };
    CHECK(vkAllocateCommandBuffers(dev, &cai, cbs));
    for (int f = 0; f < total; f++) {
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        CHECK(vkBeginCommandBuffer(cbs[f], &bi));
        vkCmdResetQueryPool(cbs[f], qp, 2 * f, 2);
        vkCmdWriteTimestamp(cbs[f], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, qp, 2 * f);
        int currentLevel = 4;
        for (int i = 0; i < passes; i++) {
            int c = plan[i].c, l = plan[i].l;
            if (l != currentLevel) {
                VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT };
                vkCmdPipelineBarrier(cbs[f], VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
                currentLevel = l;
            }
            int toPlane = (l == 0) || (l == 1 && c && !is444);
            uint32_t bw = AW >> (l + 1), bh = AH >> (l + 1);
            int32_t pc[4]; pc[0] = (int32_t)bh; pc[1] = (int32_t)bw; float inv[2] = { 1.0f / bh, 1.0f / bw }; memcpy(&pc[2], inv, 8);
            vkCmdBindPipeline(cbs[f], VK_PIPELINE_BIND_POINT_COMPUTE, toPlane ? pipeShift : pipeNoShift);
            vkCmdBindDescriptorSets(cbs[f], VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &sets[i], 0, NULL);
            vkCmdPushConstants(cbs[f], pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, pc);
            vkCmdDispatch(cbs[f], (bh + 15) / 16, (bw + 15) / 16, 1);
        }
        vkCmdWriteTimestamp(cbs[f], VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, qp, 2 * f + 1);
        CHECK(vkEndCommandBuffer(cbs[f]));
    }
    double t0 = now_ms();
    for (int f = 0; f < total; f++) {
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cbs[f] };
        CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    }
    CHECK(vkQueueWaitIdle(queue));
    double wall = now_ms() - t0;
    uint64_t *ts = malloc(sizeof(uint64_t) * 2 * total);
    CHECK(vkGetQueryPoolResults(dev, qp, 0, 2 * total, sizeof(uint64_t) * 2 * total, ts, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
    double *gpuMs = malloc(sizeof(double) * frames);
    for (int f = 0; f < frames; f++) gpuMs[f] = (double)(ts[2 * (warm + f) + 1] - ts[2 * (warm + f)]) * props.properties.limits.timestampPeriod / 1e6;
    printf("%ux%u %s, %d passes, fp16-stored levels %u\n", W, H, is444 ? "4:4:4" : "4:2:0", passes, halfLevels);
    // Single frames read near zero here (seen on an Apple M6), so the timestamps are not trusted: the throughput line
    // below is the figure to use.
    report("MoltenVK iDWT ms by timestamp queries (coarse)", gpuMs, frames);
    printf("MoltenVK iDWT throughput, queue of %d frames submitted back to back: %.3f ms per frame (wall)\n", total, wall / total);

    // Latency: submit and wait, one frame at a time.
    double *lat = malloc(sizeof(double) * 200);
    for (int f = 0; f < 200; f++) {
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cbs[warm + f % frames] };
        double a = now_ms(); CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); CHECK(vkQueueWaitIdle(queue)); lat[f] = now_ms() - a;
    }
    report("MoltenVK iDWT submit-to-idle wall ms", lat, 200);
    return 0;
}
