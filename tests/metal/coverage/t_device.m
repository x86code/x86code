// x86Sim MetalCoverage: the device, its queries, queues.
#import "mtlcov.h"

MC_TEST(device, identity, "MTLDevice name;MTLDevice registryID;MTLDevice maxThreadsPerThreadgroup;MTLDevice maxBufferLength;"
        "MTLDevice recommendedMaxWorkingSetSize;MTLDevice hasUnifiedMemory;MTLDevice argumentBuffersSupport;"
        "MTLDevice readWriteTextureSupport;MTLDevice maxThreadgroupMemoryLength;MTLDevice location;MTLDevice isLowPower;"
        "MTLDevice isHeadless;MTLDevice isRemovable;MTLDevice currentAllocatedSize") {
	MC_NOTNIL(dev, nil);
	MTLSize t = dev.maxThreadsPerThreadgroup;
	[detail appendFormat:@"%@ registry %#llx maxThreads %lux%lux%lu maxBuffer %lu MB workingSet %llu MB unified %d "
	                     @"argBuffers tier%lu rwTex tier%lu tgMem %lu",
		dev.name, dev.registryID, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth,
		(unsigned long)(dev.maxBufferLength >> 20), dev.recommendedMaxWorkingSetSize >> 20, dev.hasUnifiedMemory,
		(unsigned long)dev.argumentBuffersSupport + 1, (unsigned long)dev.readWriteTextureSupport,
		(unsigned long)dev.maxThreadgroupMemoryLength];
	MC_CHECK(dev.name.length > 0, @"no name");
	MC_CHECK(t.width >= 256, @"maxThreadsPerThreadgroup %lu", (unsigned long)t.width);
	return MC_PASS;
}

// What an iPhone's GPU (A17/A18: Apple9, Metal3) would claim, next to what this device claims: informational.
MC_TEST(device, families, "MTLDevice supportsFamily:") {
	struct { MTLGPUFamily f; const char* n; } fs[] = {
		{ MTLGPUFamilyApple1, "Apple1" }, { MTLGPUFamilyApple2, "Apple2" }, { MTLGPUFamilyApple3, "Apple3" },
		{ MTLGPUFamilyApple4, "Apple4" }, { MTLGPUFamilyApple5, "Apple5" }, { MTLGPUFamilyApple6, "Apple6" },
		{ MTLGPUFamilyApple7, "Apple7" }, { MTLGPUFamilyApple8, "Apple8" }, { MTLGPUFamilyApple9, "Apple9" },
		{ MTLGPUFamilyMac2, "Mac2" }, { MTLGPUFamilyCommon1, "Common1" }, { MTLGPUFamilyCommon2, "Common2" },
		{ MTLGPUFamilyCommon3, "Common3" }, { MTLGPUFamilyMetal3, "Metal3" },
	};
	for (size_t i = 0; i < sizeof fs / sizeof *fs; i++)
		[detail appendFormat:@"%s=%d ", fs[i].n, [dev supportsFamily:fs[i].f]];
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple9]);
	return MC_PASS;
}

MC_TEST(device, sample_counts, "MTLDevice supportsTextureSampleCount:") {
	for (NSUInteger n = 1; n <= 8; n *= 2) [detail appendFormat:@"%lu=%d ", (unsigned long)n, [dev supportsTextureSampleCount:n]];
	MC_CHECK([dev supportsTextureSampleCount:4], @"no 4x MSAA (every iOS GPU has it)");
	return MC_PASS;
}

MC_TEST(device, queries, "MTLDevice minimumLinearTextureAlignmentForPixelFormat:;MTLDevice heapBufferSizeAndAlignWithLength:options:;"
        "MTLDevice heapTextureSizeAndAlignWithDescriptor:;MTLDevice supportsRasterizationRateMapWithLayerCount:;"
        "MTLDevice supportsVertexAmplificationCount:;MTLDevice areRasterOrderGroupsSupported;MTLDevice supports32BitFloatFiltering;"
        "MTLDevice supports32BitMSAA;MTLDevice supportsBCTextureCompression;MTLDevice supportsPullModelInterpolation;"
        "MTLDevice supportsShaderBarycentricCoordinates;MTLDevice supportsFunctionPointers;MTLDevice supportsRaytracing;"
        "MTLDevice supportsDynamicLibraries;MTLDevice supportsQueryTextureLOD;MTLDevice maxArgumentBufferSamplerCount;"
        "MTLDevice sparseTileSizeInBytes;MTLDevice supportsPrimitiveMotionBlur;MTLDevice supportsRenderDynamicLibraries;"
        "MTLDevice supportsFunctionPointersFromRender;MTLDevice supportsRaytracingFromRender;MTLDevice maxTransferRate;"
        "MTLDevice peerGroupID;MTLDevice depth24Stencil8PixelFormatSupported") {
	NSUInteger a = [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatRGBA8Unorm];
	MTLSizeAndAlign sa = [dev heapBufferSizeAndAlignWithLength:1000 options:MTLResourceStorageModePrivate];
	MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
	td.storageMode = MTLStorageModePrivate;
	MTLSizeAndAlign ta = [dev heapTextureSizeAndAlignWithDescriptor:td];
	[detail appendFormat:@"linearAlign %lu heapBuf %lu/%lu heapTex %lu/%lu rrm %d amp2 %d rog %d f32filter %d f32msaa %d bc %d "
	                     @"pull %d bary %d fnptr %d rt %d dylib %d lod %d samplers %lu",
		(unsigned long)a, (unsigned long)sa.size, (unsigned long)sa.align, (unsigned long)ta.size, (unsigned long)ta.align,
		[dev supportsRasterizationRateMapWithLayerCount:1], [dev supportsVertexAmplificationCount:2], dev.rasterOrderGroupsSupported,
		dev.supports32BitFloatFiltering, dev.supports32BitMSAA, dev.supportsBCTextureCompression, dev.supportsPullModelInterpolation,
		dev.supportsShaderBarycentricCoordinates, dev.supportsFunctionPointers, dev.supportsRaytracing, dev.supportsDynamicLibraries,
		dev.supportsQueryTextureLOD, (unsigned long)dev.maxArgumentBufferSamplerCount];
	MC_CHECK(a > 0 && sa.size >= 1000 && sa.align > 0 && ta.size >= 64 * 64 * 4, @"sizes");
	return MC_PASS;
}

MC_TEST(device, queues, "MTLDevice newCommandQueue;MTLDevice newCommandQueueWithMaxCommandBufferCount:;"
        "MTLDevice newCommandQueueWithDescriptor:;MTLCommandQueue commandBuffer;MTLCommandQueue commandBufferWithUnretainedReferences;"
        "MTLCommandQueue commandBufferWithDescriptor:;MTLCommandQueue label;MTLCommandQueue device") {
	id<MTLCommandQueue> q1 = [dev newCommandQueue], q2 = [dev newCommandQueueWithMaxCommandBufferCount:2];
	MTLCommandQueueDescriptor* qd = [MTLCommandQueueDescriptor new];
	qd.maxCommandBufferCount = 4;
	id<MTLCommandQueue> q3 = [dev newCommandQueueWithDescriptor:qd];
	MC_NOTNIL(q1, nil); MC_NOTNIL(q2, nil); MC_NOTNIL(q3, nil);
	q1.label = @"cov";
	MC_CHECK([q1.label isEqual:@"cov"] && q1.device == dev, @"label/device");
	MTLCommandBufferDescriptor* cd = [MTLCommandBufferDescriptor new];
	cd.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
	id<MTLCommandBuffer> cbs[] = { [q1 commandBuffer], [q2 commandBufferWithUnretainedReferences], [q3 commandBufferWithDescriptor:cd] };
	for (int i = 0; i < 3; i++) {
		MC_NOTNIL(cbs[i], nil);
		NSString* e = mc_run(cbs[i]);
		MC_CHECK(!e, @"%@", e);
	}
	return MC_PASS;
}

// More command buffers than the queue allows in flight: commandBuffer blocks until one completes, never forever.
MC_TEST(device, queue_backpressure, "MTLCommandQueue commandBuffer;MTLCommandBuffer commit;MTLCommandBuffer waitUntilCompleted") {
	id<MTLCommandQueue> q = [dev newCommandQueueWithMaxCommandBufferCount:2];
	id<MTLCommandBuffer> last = nil;
	for (int i = 0; i < 64; i++) { last = [q commandBuffer]; [last commit]; }
	[last waitUntilCompleted];
	MC_CHECK(last.status == MTLCommandBufferStatusCompleted, @"status %ld", (long)last.status);
	return MC_PASS;
}
