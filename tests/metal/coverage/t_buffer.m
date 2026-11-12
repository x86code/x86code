// x86Sim MetalCoverage: buffers and blit encoders.
#import "mtlcov.h"
#include <sys/mman.h>
#include <mach/mach.h>

MC_TEST(buffer, storage_modes, "MTLDevice newBufferWithLength:options:;MTLDevice newBufferWithBytes:length:options:;"
        "MTLBuffer contents;MTLBuffer length;MTLResource storageMode;MTLResource cpuCacheMode;MTLResource resourceOptions;"
        "MTLResource label;MTLResource allocatedSize") {
	uint32_t src[256];
	for (int i = 0; i < 256; i++) src[i] = i * 2654435761u;
	id<MTLBuffer> a = [dev newBufferWithBytes:src length:sizeof src options:MTLResourceStorageModeShared];
	id<MTLBuffer> wc = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
	id<MTLBuffer> p = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
	MC_NOTNIL(a, nil); MC_NOTNIL(wc, nil); MC_NOTNIL(p, nil);
	MC_CHECK(!memcmp(a.contents, src, sizeof src), @"newBufferWithBytes contents");
	MC_CHECK(a.length == sizeof src && a.storageMode == MTLStorageModeShared && p.storageMode == MTLStorageModePrivate, @"modes");
	MC_CHECK(wc.cpuCacheMode == MTLCPUCacheModeWriteCombined, @"cpuCacheMode %lu", (unsigned long)wc.cpuCacheMode);
	MC_CHECK(p.contents == NULL, @"private buffer has contents");
	a.label = @"a";
	MC_CHECK([a.label isEqual:@"a"], @"label %@", a.label);
	MC_CLIENT_CHECK(a.allocatedSize >= a.length, @"allocatedSize %lu (MTLSimResource answers 0)", (unsigned long)a.allocatedSize);
	return MC_PASS;
}

// over vm_allocate'd pages. (posix_memalign'd pages crash Apple's simulator client itself, on a Mac too:
// xpc_shmem_create_readonly traps on malloc memory.)
MC_TEST(buffer, no_copy, "MTLDevice newBufferWithBytesNoCopy:length:options:deallocator:") {
	size_t len = 16384;
	vm_address_t va = 0;
	MC_CHECK(vm_allocate(mach_task_self(), &va, len, VM_FLAGS_ANYWHERE) == KERN_SUCCESS, @"vm_allocate");
	void* mem = (void*)va;
	memset(mem, 0x5a, len);
	__block BOOL freed = NO;
	@autoreleasepool {
		id<MTLBuffer> b = [dev newBufferWithBytesNoCopy:mem length:len options:MTLResourceStorageModeShared
		                                    deallocator:^(void* p, NSUInteger l) { vm_deallocate(mach_task_self(), (vm_address_t)p, l); freed = YES; }];
		MC_NOTNIL(b, nil);
		MC_CHECK(b.contents == mem, @"contents %p is not the caller's %p", b.contents, mem);
		// the GPU writes the caller's pages
		id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
		id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
		[be fillBuffer:b range:NSMakeRange(4096, 4096) value:0xa5];
		[be endEncoding];
		NSString* e = mc_run(cb);
		MC_CHECK(!e, @"%@", e);
		uint8_t* p = mem;
		MC_CHECK(p[0] == 0x5a && p[4096] == 0xa5 && p[8191] == 0xa5 && p[8192] == 0x5a, @"bytes %02x %02x %02x %02x",
			p[0], p[4096], p[8191], p[8192]);
	}
	for (int i = 0; i < 200 && !freed; i++) usleep(10000);
	MC_CHECK(freed, @"deallocator never ran");
	return MC_PASS;
}

// the same over mmap'd pages (no_copy uses posix_memalign memory, as apps often do)
MC_TEST(buffer, no_copy_mmap, "MTLDevice newBufferWithBytesNoCopy:length:options:deallocator:") {
	size_t len = 16384;
	void* mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	MC_CHECK(mem != MAP_FAILED, @"mmap");
	memset(mem, 0x5a, len);
	id<MTLBuffer> b = [dev newBufferWithBytesNoCopy:mem length:len options:MTLResourceStorageModeShared deallocator:nil];
	MC_NOTNIL(b, nil);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be fillBuffer:b range:NSMakeRange(4096, 4096) value:0xa5];
	[be endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint8_t* p = mem;
	MC_CHECK(p[0] == 0x5a && p[4096] == 0xa5 && p[8192] == 0x5a, @"bytes %02x %02x %02x", p[0], p[4096], p[8192]);
	return MC_PASS;
}

MC_TEST(buffer, gpu_address, "MTLBuffer gpuAddress") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyMetal3]);
	id<MTLBuffer> a = mc_buf(dev, 4096), b = mc_buf(dev, 4096);
	uint64_t ga = a.gpuAddress, gb = b.gpuAddress;
	[detail appendFormat:@"%#llx %#llx ", ga, gb];
	MC_CHECK(ga && gb && ga != gb, @"addresses");
	return MC_PASS;
}

MC_TEST(blit, copies, "MTLCommandBuffer blitCommandEncoder;MTLBlitCommandEncoder copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:;"
        "MTLBlitCommandEncoder fillBuffer:range:value:;MTLCommandEncoder endEncoding;MTLCommandEncoder label;MTLCommandEncoder device") {
	id<MTLBuffer> a = mc_buf(dev, 65536), b = mc_buf(dev, 65536);
	uint8_t* pa = a.contents;
	for (int i = 0; i < 65536; i++) pa[i] = (uint8_t)(i * 7);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	be.label = @"blit";
	[be copyFromBuffer:a sourceOffset:100 toBuffer:b destinationOffset:4 size:30000];
	[be fillBuffer:b range:NSMakeRange(40000, 1000) value:0xee];
	[be endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint8_t* pb = b.contents;
	MC_CHECK(!memcmp(pb + 4, pa + 100, 30000), @"copy");
	MC_CHECK(pb[40000] == 0xee && pb[40999] == 0xee && pb[41000] == 0 && pb[3] == 0, @"fill/edges");
	return MC_PASS;
}

MC_TEST(blit, buffer_texture, "MTLBlitCommandEncoder copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:;"
        "MTLBlitCommandEncoder copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:;"
        "MTLBlitCommandEncoder copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:;"
        "MTLBlitCommandEncoder copyFromTexture:toTexture:") {
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
	d.storageMode = MTLStorageModePrivate;
	id<MTLTexture> t1 = [dev newTextureWithDescriptor:d], t2 = [dev newTextureWithDescriptor:d], t3 = [dev newTextureWithDescriptor:d];
	id<MTLBuffer> src = mc_buf(dev, 32 * 32 * 4), dst = mc_buf(dev, 32 * 32 * 4);
	uint32_t* s = src.contents;
	for (int i = 0; i < 32 * 32; i++) s[i] = 0x01000000u * (i & 0xff) + i;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:128 sourceBytesPerImage:4096 sourceSize:MTLSizeMake(32, 32, 1)
	         toTexture:t1 destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[be copyFromTexture:t1 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(32, 32, 1)
	          toTexture:t2 destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[be copyFromTexture:t2 toTexture:t3];
	[be copyFromTexture:t3 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(32, 32, 1)
	           toBuffer:dst destinationOffset:0 destinationBytesPerRow:128 destinationBytesPerImage:4096];
	[be endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(!memcmp(src.contents, dst.contents, 4096), @"round trip through three private textures differs");
	return MC_PASS;
}

MC_TEST(blit, mipmaps, "MTLBlitCommandEncoder generateMipmapsForTexture:") {
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [dev newTextureWithDescriptor:d];
	MC_CHECK(t.mipmapLevelCount == 7, @"levels %lu", (unsigned long)t.mipmapLevelCount);
	uint32_t* px = malloc(64 * 64 * 4);
	for (int i = 0; i < 64 * 64; i++) px[i] = (i & 1) ? 0xff0000ffu : 0xff00ff00u;  // alternating red / green columns
	[t replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
	free(px);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be generateMipmapsForTexture:t];
	[be endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t v = 0;
	[t getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:6];
	int r = v & 0xff, g = (v >> 8) & 0xff;
	MC_CHECK(v != 0, @"level 6 never written");
	// an iPhone's GPU box-filters (~(128,128,0)); the iOS simulator (Apple's, on a Mac too) keeps one texel
	MC_CLIENT_CHECK(abs(r - 128) < 8 && abs(g - 128) < 8, @"1x1 level %08x, want ~ (128,128,0): unfiltered", v);
	return MC_PASS;
}

MC_TEST(blit, optimize_and_misc, "MTLBlitCommandEncoder optimizeContentsForGPUAccess:;MTLBlitCommandEncoder optimizeContentsForCPUAccess:;"
        "MTLBlitCommandEncoder updateFence:;MTLBlitCommandEncoder waitForFence:;MTLCommandEncoder pushDebugGroup:;"
        "MTLCommandEncoder popDebugGroup;MTLCommandEncoder insertDebugSignpost:") {
	id<MTLTexture> t = mc_tex(dev, MTLPixelFormatRGBA8Unorm, 16, 16, MTLTextureUsageShaderRead);
	id<MTLFence> f = [dev newFence];
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be pushDebugGroup:@"g"];
	[be insertDebugSignpost:@"s"];
	[be optimizeContentsForGPUAccess:t];
	[be optimizeContentsForCPUAccess:t];
	[be updateFence:f];
	[be popDebugGroup];
	[be endEncoding];
	be = [cb blitCommandEncoder];
	[be waitForFence:f];
	[be endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	return MC_PASS;
}
