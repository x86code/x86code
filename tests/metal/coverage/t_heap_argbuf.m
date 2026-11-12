// x86Sim MetalCoverage: heaps, argument buffers, indirect command buffers.
#import "mtlcov.h"

static NSString* const SRC = MC_MSL
	"kernel void fill(device uint* x [[buffer(0)]], constant uint& v [[buffer(1)]], uint i [[thread_position_in_grid]]) { x[i] = v + i; }\n"
	// argument buffer (tier 1 layout: indices from [[id(n)]])
	"struct AB { device float* in [[id(0)]]; device float* out [[id(1)]]; float k [[id(2)]]; texture2d<float> t [[id(3)]]; };\n"
	"kernel void useab(constant AB& ab [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
	"  ab.out[i] = ab.in[i] * ab.k + ab.t.read(uint2(0, 0)).r; }\n"
	// tier 2: a plain struct of device pointers
	"struct AB2 { device float* in; device float* out; };\n"
	"kernel void useab2(device AB2& ab [[buffer(0)]], uint i [[thread_position_in_grid]]) { ab.out[i] = ab.in[i] + 1; }\n"
	// ICB compute
	"kernel void icbk(device uint* x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] += 10; }\n";

MC_TEST(heap, private_heap, "MTLDevice newHeapWithDescriptor:;MTLHeap newBufferWithLength:options:;MTLHeap newTextureWithDescriptor:;"
        "MTLHeap usedSize;MTLHeap size;MTLHeap maxAvailableSizeWithAlignment:;MTLHeap storageMode;MTLResource heap;MTLResource heapOffset;"
        "MTLComputeCommandEncoder useHeap:") {
	MTLHeapDescriptor* hd = [MTLHeapDescriptor new];
	hd.size = 4 << 20; hd.storageMode = MTLStorageModePrivate;
	id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
	MC_NOTNIL(h, nil);
	id<MTLBuffer> b = [h newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
	MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> t = [h newTextureWithDescriptor:td];
	MC_NOTNIL(b, nil); MC_NOTNIL(t, nil);
	MC_CHECK(b.heap == h && h.usedSize > 0 && h.size >= hd.size, @"heap %p used %lu size %lu", b.heap, (unsigned long)h.usedSize, (unsigned long)h.size);
	// the GPU writes the heap buffer, a blit reads it back
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"fill", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> out = mc_buf(dev, 4096);
	uint32_t v = 77;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce useHeap:h];
	[ce setComputePipelineState:p]; [ce setBuffer:b offset:0 atIndex:0]; [ce setBytes:&v length:4 atIndex:1];
	[ce dispatchThreadgroups:MTLSizeMake(16, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be copyFromBuffer:b sourceOffset:0 toBuffer:out destinationOffset:0 size:4096];
	[be endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(((uint32_t*)out.contents)[1000] == 1077, @"%u", ((uint32_t*)out.contents)[1000]);
	return MC_PASS;
}

MC_TEST(heap, shared_heap, "MTLDevice newHeapWithDescriptor:;MTLHeap newBufferWithLength:options:") {
	MTLHeapDescriptor* hd = [MTLHeapDescriptor new];
	hd.size = 1 << 20; hd.storageMode = MTLStorageModeShared;
	id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
	MC_NOTNIL(h, nil);
	id<MTLBuffer> b = [h newBufferWithLength:4096 options:MTLResourceStorageModeShared];
	MC_NOTNIL(b, nil);
	MC_CHECK(b.contents != NULL, @"shared heap buffer has no contents");
	return MC_PASS;
}

MC_TEST(heap, placement_and_aliasing, "MTLHeap newBufferWithLength:options:offset:;MTLHeapDescriptor type;MTLResource makeAliasable;"
        "MTLResource isAliasable") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple5] || [dev supportsFamily:MTLGPUFamilyMac2]);
	MTLHeapDescriptor* hd = [MTLHeapDescriptor new];
	hd.size = 1 << 20; hd.storageMode = MTLStorageModeShared; hd.type = MTLHeapTypePlacement;
	id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
	MC_NOTNIL(h, nil);
	id<MTLBuffer> a = [h newBufferWithLength:4096 options:MTLResourceStorageModeShared offset:0];
	id<MTLBuffer> b = [h newBufferWithLength:4096 options:MTLResourceStorageModeShared offset:0];  // same memory
	MC_NOTNIL(a, nil); MC_NOTNIL(b, nil);
	((uint32_t*)a.contents)[3] = 0x1234;
	MC_CHECK(((uint32_t*)b.contents)[3] == 0x1234, @"placed buffers at one offset do not alias");
	[a makeAliasable];
	MC_CHECK(a.isAliasable, @"not aliasable");
	return MC_PASS;
}

MC_TEST(argbuf, encoder_tier1, "MTLFunction newArgumentEncoderWithBufferIndex:;MTLArgumentEncoder encodedLength;MTLArgumentEncoder setArgumentBuffer:offset:;"
        "MTLArgumentEncoder setBuffer:offset:atIndex:;MTLArgumentEncoder setTexture:atIndex:;MTLArgumentEncoder constantDataAtIndex:;"
        "MTLComputeCommandEncoder useResource:usage:") {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MC_NOTNIL(l, err);
	id<MTLFunction> f = [l newFunctionWithName:@"useab"];
	id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:f error:&err];
	MC_NOTNIL(p, err);
	id<MTLArgumentEncoder> ae = [f newArgumentEncoderWithBufferIndex:0];
	MC_NOTNIL(ae, nil);
	id<MTLBuffer> ab = mc_buf(dev, ae.encodedLength), in = mc_buf(dev, 1024), out = mc_buf(dev, 1024);
	for (int i = 0; i < 256; i++) ((float*)in.contents)[i] = i;
	id<MTLTexture> t = mc_tex(dev, MTLPixelFormatR32Float, 1, 1, MTLTextureUsageShaderRead);
	float tv = 0.5f;
	[t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&tv bytesPerRow:4];
	[ae setArgumentBuffer:ab offset:0];
	[ae setBuffer:in offset:0 atIndex:0];
	[ae setBuffer:out offset:0 atIndex:1];
	*(float*)[ae constantDataAtIndex:2] = 3;
	[ae setTexture:t atIndex:3];
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p]; [ce setBuffer:ab offset:0 atIndex:0];
	[ce useResource:in usage:MTLResourceUsageRead]; [ce useResource:out usage:MTLResourceUsageWrite];
	[ce useResource:t usage:MTLResourceUsageRead];
	[ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(((float*)out.contents)[100] == 300.5f, @"out[100] = %f", ((float*)out.contents)[100]);
	return MC_PASS;
}

MC_TEST(argbuf, tier2_gpu_addresses, "MTLBuffer gpuAddress;MTLComputeCommandEncoder useResource:usage:") {
	MC_CLAIM(dev.argumentBuffersSupport == MTLArgumentBuffersTier2);
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"useab2", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> in = mc_buf(dev, 1024), out = mc_buf(dev, 1024), ab = mc_buf(dev, 16);
	for (int i = 0; i < 256; i++) ((float*)in.contents)[i] = i;
	((uint64_t*)ab.contents)[0] = in.gpuAddress; ((uint64_t*)ab.contents)[1] = out.gpuAddress;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p]; [ce setBuffer:ab offset:0 atIndex:0];
	[ce useResource:in usage:MTLResourceUsageRead]; [ce useResource:out usage:MTLResourceUsageWrite];
	[ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(((float*)out.contents)[200] == 201, @"out[200] = %f", ((float*)out.contents)[200]);
	return MC_PASS;
}

MC_TEST(icb, compute_icb, "MTLDevice newIndirectCommandBufferWithDescriptor:maxCommandCount:options:;MTLIndirectCommandBuffer indirectComputeCommandAtIndex:;"
        "MTLIndirectComputeCommand setComputePipelineState:;MTLIndirectComputeCommand setKernelBuffer:offset:atIndex:;"
        "MTLIndirectComputeCommand concurrentDispatchThreadgroups:threadsPerThreadgroup:;MTLComputeCommandEncoder executeCommandsInBuffer:withRange:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple4] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLComputePipelineDescriptor* pd = [MTLComputePipelineDescriptor new];
	pd.computeFunction = [l newFunctionWithName:@"icbk"];
	pd.supportIndirectCommandBuffers = YES;
	id<MTLComputePipelineState> p = [dev newComputePipelineStateWithDescriptor:pd options:0 reflection:nil error:&err];
	MC_NOTNIL(p, err);
	MTLIndirectCommandBufferDescriptor* d = [MTLIndirectCommandBufferDescriptor new];
	d.commandTypes = MTLIndirectCommandTypeConcurrentDispatch;
	d.inheritBuffers = NO; d.inheritPipelineState = NO; d.maxKernelBufferBindCount = 1;
	id<MTLIndirectCommandBuffer> icb = [dev newIndirectCommandBufferWithDescriptor:d maxCommandCount:2 options:0];
	MC_NOTNIL(icb, nil);
	id<MTLBuffer> x = mc_buf(dev, 256);
	for (int i = 0; i < 2; i++) {
		id<MTLIndirectComputeCommand> c = [icb indirectComputeCommandAtIndex:i];
		[c setComputePipelineState:p];
		[c setKernelBuffer:x offset:0 atIndex:0];
		[c concurrentDispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	}
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce useResource:x usage:MTLResourceUsageRead | MTLResourceUsageWrite];
	[ce executeCommandsInBuffer:icb withRange:NSMakeRange(0, 2)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(((uint32_t*)x.contents)[7] == 20, @"x[7] = %u, want 20 (two commands)", ((uint32_t*)x.contents)[7]);
	return MC_PASS;
}
