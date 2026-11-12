// x86Sim MetalCoverage: textures: types, formats, views, textures over buffers.
#import "mtlcov.h"

// replaceRegion then getBytes of every slice/level/plane of a texture type: the bytes come back.
static NSString* round_trip(id<MTLDevice> dev, MTLTextureType type, NSUInteger samples) {
	MTLTextureDescriptor* d = [MTLTextureDescriptor new];
	d.textureType = type;
	d.pixelFormat = MTLPixelFormatRGBA8Unorm;
	d.width = 16; d.height = type == MTLTextureType1D || type == MTLTextureType1DArray ? 1 : 16;
	d.depth = type == MTLTextureType3D ? 4 : 1;
	d.arrayLength = (type == MTLTextureType2DArray || type == MTLTextureType1DArray || type == MTLTextureTypeCubeArray) ? 3 : 1;
	d.sampleCount = samples;
	d.storageMode = MTLStorageModeShared;
	if (samples > 1) d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageShaderRead | (samples > 1 ? MTLTextureUsageRenderTarget : 0);
	id<MTLTexture> t = [dev newTextureWithDescriptor:d];
	if (!t) return @"newTextureWithDescriptor: nil";
	if (t.textureType != type || t.width != d.width || t.arrayLength != d.arrayLength) return @"descriptor not kept";
	if (samples > 1) return nil;  // made; not CPU accessible
	NSUInteger slices = d.arrayLength * (type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray ? 6 : 1);
	NSUInteger bpr = d.width * 4, bpi = bpr * d.height, n = bpi * d.depth;
	uint8_t *in = malloc(n), *out = malloc(n);
	for (NSUInteger s = 0; s < slices; s++) {
		for (NSUInteger i = 0; i < n; i++) in[i] = (uint8_t)(i * 13 + s * 101);
		MTLRegion r = MTLRegionMake3D(0, 0, 0, d.width, d.height, d.depth);
		[t replaceRegion:r mipmapLevel:0 slice:s withBytes:in bytesPerRow:bpr bytesPerImage:bpi];
		memset(out, 0, n);
		[t getBytes:out bytesPerRow:bpr bytesPerImage:bpi fromRegion:r mipmapLevel:0 slice:s];
		if (memcmp(in, out, n)) { free(in); free(out); return [NSString stringWithFormat:@"slice %lu differs", (unsigned long)s]; }
	}
	free(in); free(out);
	return nil;
}

#define TYPE_TEST(nm, type, samples, claim)                                                                       \
	MC_TEST(texture, nm, "MTLDevice newTextureWithDescriptor:;MTLTexture replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:;" \
	        "MTLTexture getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:;MTLTexture textureType;MTLTexture width;"           \
	        "MTLTexture height;MTLTexture depth;MTLTexture arrayLength;MTLTexture sampleCount;MTLTexture pixelFormat") {                       \
		MC_CLAIM(claim);                                                                                          \
		NSString* e = round_trip(dev, type, samples);                                                              \
		MC_CHECK(!e, @"%@", e);                                                                                    \
		return MC_PASS;                                                                                            \
	}
TYPE_TEST(type_1d, MTLTextureType1D, 1, YES)
TYPE_TEST(type_1d_array, MTLTextureType1DArray, 1, YES)
TYPE_TEST(type_2d, MTLTextureType2D, 1, YES)
TYPE_TEST(type_2d_array, MTLTextureType2DArray, 1, YES)
TYPE_TEST(type_3d, MTLTextureType3D, 1, YES)
TYPE_TEST(type_cube, MTLTextureTypeCube, 1, YES)
TYPE_TEST(type_cube_array, MTLTextureTypeCubeArray, 1, [dev supportsFamily:MTLGPUFamilyApple4] || [dev supportsFamily:MTLGPUFamilyMac2])
TYPE_TEST(type_2d_multisample, MTLTextureType2DMultisample, 4, YES)

// Formats an iPhone app uses: write a texel pattern, read it back unchanged.
MC_TEST(texture, formats, "MTLDevice newTextureWithDescriptor:;MTLTexture replaceRegion:mipmapLevel:withBytes:bytesPerRow:;"
        "MTLTexture getBytes:bytesPerRow:fromRegion:mipmapLevel:") {
	struct { MTLPixelFormat f; int bpp; const char* n; } fs[] = {
		{ MTLPixelFormatR8Unorm, 1, "R8Unorm" }, { MTLPixelFormatR8Uint, 1, "R8Uint" }, { MTLPixelFormatRG8Unorm, 2, "RG8Unorm" },
		{ MTLPixelFormatR16Float, 2, "R16Float" }, { MTLPixelFormatR16Uint, 2, "R16Uint" }, { MTLPixelFormatRGBA8Unorm, 4, "RGBA8" },
		{ MTLPixelFormatRGBA8Unorm_sRGB, 4, "RGBA8_sRGB" }, { MTLPixelFormatBGRA8Unorm, 4, "BGRA8" }, { MTLPixelFormatRGB10A2Unorm, 4, "RGB10A2" },
		{ MTLPixelFormatRG11B10Float, 4, "RG11B10F" }, { MTLPixelFormatRGB9E5Float, 4, "RGB9E5" }, { MTLPixelFormatR32Float, 4, "R32Float" },
		{ MTLPixelFormatRG16Float, 4, "RG16Float" }, { MTLPixelFormatRGBA16Float, 8, "RGBA16Float" }, { MTLPixelFormatRG32Float, 8, "RG32Float" },
		{ MTLPixelFormatRGBA16Uint, 8, "RGBA16Uint" }, { MTLPixelFormatRGBA32Float, 16, "RGBA32Float" }, { MTLPixelFormatRGBA32Uint, 16, "RGBA32Uint" },
		{ MTLPixelFormatBGR10_XR, 4, "BGR10_XR" }, { MTLPixelFormatBGRA10_XR, 8, "BGRA10_XR" },
	};
	NSMutableArray* bad = [NSMutableArray array];
	for (size_t i = 0; i < sizeof fs / sizeof *fs; i++) {
		id<MTLTexture> t = mc_tex(dev, fs[i].f, 8, 8, MTLTextureUsageShaderRead);
		if (!t) { [bad addObject:[NSString stringWithFormat:@"%s:nil", fs[i].n]]; continue; }
		NSUInteger bpr = 8 * fs[i].bpp, n = bpr * 8;
		uint8_t in[1024], out[1024];
		for (NSUInteger k = 0; k < n; k++) in[k] = (uint8_t)(k * 37 + 11);
		if (fs[i].f == MTLPixelFormatR16Float || fs[i].f == MTLPixelFormatRG16Float || fs[i].f == MTLPixelFormatRGBA16Float)
			for (NSUInteger k = 0; k < n; k += 2) in[k + 1] &= 0x3b;  // finite halves (no NaN payloads to canonicalize)
		if (fs[i].f == MTLPixelFormatR32Float || fs[i].f == MTLPixelFormatRG32Float || fs[i].f == MTLPixelFormatRGBA32Float)
			for (NSUInteger k = 0; k < n; k += 4) in[k + 3] &= 0x3f;
		if (fs[i].f == MTLPixelFormatRG11B10Float || fs[i].f == MTLPixelFormatRGB9E5Float) continue;  // packed floats: canonical forms vary
		[t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:in bytesPerRow:bpr];
		memset(out, 0, n);
		[t getBytes:out bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		if (memcmp(in, out, n)) [bad addObject:@(fs[i].n)];
	}
	MC_CHECK(bad.count == 0, @"%@", [bad componentsJoinedByString:@" "]);
	return MC_PASS;
}

MC_TEST(texture, views_swizzle, "MTLTexture newTextureViewWithPixelFormat:;MTLTexture newTextureViewWithPixelFormat:textureType:levels:slices:;"
        "MTLTexture newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:;MTLTexture parentTexture;MTLTexture swizzle;"
        "MTLTexture parentRelativeLevel;MTLTexture parentRelativeSlice") {
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:YES];
	d.textureType = MTLTextureType2DArray; d.arrayLength = 2;
	d.storageMode = MTLStorageModeShared;
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
	id<MTLTexture> t = [dev newTextureWithDescriptor:d];
	uint32_t px[64];
	for (int i = 0; i < 64; i++) px[i] = 0x44332211;
	[t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:1 withBytes:px bytesPerRow:32 bytesPerImage:0];
	id<MTLTexture> v1 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Uint];
	id<MTLTexture> v2 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(1, 1)];
	MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleBlue, MTLTextureSwizzleGreen, MTLTextureSwizzleRed, MTLTextureSwizzleOne);
	id<MTLTexture> v3 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(1, 1) swizzle:sw];
	MC_NOTNIL(v1, nil); MC_NOTNIL(v2, nil); MC_NOTNIL(v3, nil);
	MC_CHECK(v2.parentTexture == t, @"parent %p", v2.parentTexture);
	uint32_t got = 0;
	[v2 getBytes:&got bytesPerRow:4 fromRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0];
	MC_CHECK(got == 0x44332211, @"view of slice 1 reads %08x", got);
	MC_CHECK(v3.swizzle.red == MTLTextureSwizzleBlue, @"swizzle not kept");
	MC_CLIENT_CHECK(v2.parentRelativeSlice == 1, @"parentRelativeSlice %lu (MTLSimTexture's own)", (unsigned long)v2.parentRelativeSlice);
	return MC_PASS;
}

MC_TEST(texture, over_buffer, "MTLBuffer newTextureWithDescriptor:offset:bytesPerRow:;MTLTexture buffer;MTLTexture bufferOffset;MTLTexture bufferBytesPerRow") {
	NSUInteger align = [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatRGBA8Unorm];
	NSUInteger bpr = ((16 * 4 + align - 1) / align) * align;
	id<MTLBuffer> b = mc_buf(dev, bpr * 16 + align);
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	id<MTLTexture> t = [b newTextureWithDescriptor:d offset:align bytesPerRow:bpr];
	MC_NOTNIL(t, nil);
	MC_CHECK(t.buffer == b && t.bufferOffset == align && t.bufferBytesPerRow == bpr, @"buffer properties");
	((uint32_t*)((uint8_t*)b.contents + align + bpr * 5))[7] = 0xdeadbeef;
	uint32_t v = 0;
	[t getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(7, 5, 1, 1) mipmapLevel:0];
	MC_CHECK(v == 0xdeadbeef, @"texel (7,5) %08x: the texture does not see the buffer's bytes", v);
	return MC_PASS;
}

MC_TEST(texture, compressed_astc_etc, "MTLDevice newTextureWithDescriptor:;MTLTexture replaceRegion:mipmapLevel:withBytes:bytesPerRow:") {
	// one 4x4 ASTC block and one ETC2 block, uploaded and read back as blocks
	MTLPixelFormat fs[] = { MTLPixelFormatASTC_4x4_LDR, MTLPixelFormatETC2_RGB8, MTLPixelFormatEAC_RGBA8 };
	NSUInteger bs[] = { 16, 8, 16 };
	for (int i = 0; i < 3; i++) {
		id<MTLTexture> t = mc_tex(dev, fs[i], 4, 4, MTLTextureUsageShaderRead);
		MC_NOTNIL(t, nil);
		uint8_t in[16], out[16] = { 0 };
		for (int k = 0; k < 16; k++) in[k] = (uint8_t)(k * 29 + 3);
		[t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:in bytesPerRow:bs[i]];
		[t getBytes:out bytesPerRow:bs[i] fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
		MC_CHECK(!memcmp(in, out, bs[i]), @"format %lu block differs", (unsigned long)fs[i]);
	}
	return MC_PASS;
}

MC_TEST(texture, memoryless, "MTLDevice newTextureWithDescriptor:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple2]);
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
	d.storageMode = MTLStorageModeMemoryless;
	d.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> t = [dev newTextureWithDescriptor:d];
	MC_NOTNIL(t, nil);
	MC_CHECK(t.storageMode == MTLStorageModeMemoryless, @"storageMode %lu", (unsigned long)t.storageMode);
	return MC_PASS;
}

// 16-bit packed formats: every iOS GPU has them (Apple1+); a Mac's GPUs do not
MC_TEST(texture, formats_packed16, "MTLDevice newTextureWithDescriptor:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple1]);
	MTLPixelFormat fs[] = { MTLPixelFormatB5G6R5Unorm, MTLPixelFormatA1BGR5Unorm, MTLPixelFormatABGR4Unorm, MTLPixelFormatBGR5A1Unorm };
	for (int i = 0; i < 4; i++) {
		id<MTLTexture> t = mc_tex(dev, fs[i], 8, 8, MTLTextureUsageShaderRead);
		MC_NOTNIL(t, nil);
		uint16_t in[64], out[64] = { 0 };
		for (int k = 0; k < 64; k++) in[k] = (uint16_t)(k * 997 + 3);
		[t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:in bytesPerRow:16];
		[t getBytes:out bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
		MC_CHECK(!memcmp(in, out, sizeof in), @"format %lu differs", (unsigned long)fs[i]);
	}
	return MC_PASS;
}
