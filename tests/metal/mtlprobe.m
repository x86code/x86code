// x86Sim: mtlprobe -- Metal stand-in test client, run inside the simulator as a launchd job
// (com.x86sim.mtlprobe=tests/metal/mtlprobe). Goes through the real path: sim Metal.framework ->
// MTLSimDriver -> XPC "com.apple.metal.simulator.mtlprobe" -> metalhostd (Apple's MTLSimImplementation over
// VKMTLDevice) -> mtlvk (Vulkan). Prints one line per check and a summary.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurfaceRef.h>
#import <spawn.h>
#import <sys/wait.h>
#include "shaders/probe_metallib.h"
#include "shaders/probe_source.h"

static int fails, passes;
#define CHECK(cond, ...) do { if (cond) { passes++; printf("PASS "); } else { fails++; printf("FAIL "); } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static double now(void) { return [NSDate timeIntervalSinceReferenceDate]; }


static id<MTLComputePipelineState> pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString* name, MTLFunctionConstantValues* cv) {
	NSError* err = nil;
	id<MTLFunction> f = cv ? [lib newFunctionWithName:name constantValues:cv error:&err] : [lib newFunctionWithName:name];
	if (!f) { printf("INFO function %s: %s\n", name.UTF8String, err ? err.description.UTF8String : "nil"); return nil; }
	double t0 = now();
	id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:f error:&err];
	if (!p) { printf("INFO pipeline %s: %s\n", name.UTF8String, err ? err.description.UTF8String : "nil"); return nil; }
	printf("INFO pipeline %s: threadExecutionWidth=%lu maxTotalThreadsPerThreadgroup=%lu staticThreadgroupMemoryLength=%lu (%.0f ms)\n", name.UTF8String,
		(unsigned long)p.threadExecutionWidth, (unsigned long)p.maxTotalThreadsPerThreadgroup, (unsigned long)p.staticThreadgroupMemoryLength,
		(now() - t0) * 1000);
	return p;
}

static void compute_tests(id<MTLDevice> dev, id<MTLCommandQueue> q) {
	NSError* err = nil;
	dispatch_data_t dd = dispatch_data_create(probe_metallib, probe_metallib_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	double t0 = now();
	id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&err];
	CHECK(lib != nil, "newLibraryWithData (probe.metallib, %u bytes, iOS-simulator AIR): %s (%.0f ms)", probe_metallib_len,
		lib ? [lib.functionNames componentsJoinedByString:@","].UTF8String : err.description.UTF8String, (now() - t0) * 1000);
	if (!lib) return;
	const int N = 4096;

	// vector add
	id<MTLComputePipelineState> pv = pipeline(dev, lib, @"vadd", nil);
	CHECK(pv && pv.threadExecutionWidth > 0 && pv.maxTotalThreadsPerThreadgroup >= 256, "compute pipeline vadd (width %lu, max %lu)",
		(unsigned long)pv.threadExecutionWidth, (unsigned long)pv.maxTotalThreadsPerThreadgroup);
	id<MTLBuffer> a = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> b = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> c = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	float *fa = a.contents, *fb = b.contents, *fc = c.contents;
	for (int i = 0; i < N; i++) { fa[i] = i * 0.5f; fb[i] = 1000.0f - i; fc[i] = -1; }
	if (pv) {
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pv];
		[ce setBuffer:a offset:0 atIndex:0];
		[ce setBuffer:b offset:0 atIndex:1];
		[ce setBuffer:c offset:0 atIndex:2];
		[ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		[ce endEncoding];
		t0 = now();
		[cb commit];
		[cb waitUntilCompleted];
		int bad = 0;
		for (int i = 0; i < N; i++) if (fc[i] != fa[i] + fb[i]) bad++;
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "vadd float x%d: %d wrong, c[3]=%g (status %lu, %.1f ms)", N, bad, fc[3],
			(unsigned long)cb.status, (now() - t0) * 1000);
	}

	// setBytes
	id<MTLComputePipelineState> ps = pipeline(dev, lib, @"saxpy_bytes", nil);
	if (ps) {
		struct { float scale, bias; uint32_t count; } prm = { 3.0f, -2.0f, N - 5 };
		for (int i = 0; i < N; i++) fc[i] = -7;
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:ps];
		[ce setBuffer:a offset:0 atIndex:0];
		[ce setBuffer:c offset:0 atIndex:1];
		[ce setBytes:&prm length:sizeof(prm) atIndex:2];
		[ce dispatchThreadgroups:MTLSizeMake(N / 128, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		int bad = 0;
		for (int i = 0; i < N; i++) if (fc[i] != (i < N - 5 ? 3.0f * fa[i] - 2.0f : -7.0f)) bad++;
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "setBytes params + dispatchThreadgroups (saxpy): %d wrong", bad);
	} else CHECK(0, "saxpy_bytes pipeline");

	// kernel writing a texture
	id<MTLComputePipelineState> pt = pipeline(dev, lib, @"fill_tex", nil);
	MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:100 height:60 mipmapped:NO];
	td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> wt = [dev newTextureWithDescriptor:td];
	if (pt && wt) {
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pt];
		[ce setTexture:wt atIndex:0];
		[ce dispatchThreads:MTLSizeMake(100, 60, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[100 * 60 * 4];
		[wt getBytes:px bytesPerRow:400 fromRegion:MTLRegionMake2D(0, 0, 100, 60) mipmapLevel:0];
		int bad = 0;
		for (int y = 0; y < 60; y++)
			for (int x = 0; x < 100; x++) {
				const uint8_t* p = px + (y * 100 + x) * 4;
				if (p[0] != x || p[1] != y || p[2] != ((x + y) & 255) || p[3] != 255) bad++;
			}
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "kernel writes a 100x60 RGBA8 texture (getBytes): %d texels wrong, (7,5) = %u,%u,%u,%u",
			bad, px[(5 * 100 + 7) * 4], px[(5 * 100 + 7) * 4 + 1], px[(5 * 100 + 7) * 4 + 2], px[(5 * 100 + 7) * 4 + 3]);
	} else CHECK(0, "fill_tex pipeline / texture");

	// threadgroup memory reduction
	id<MTLComputePipelineState> pr = pipeline(dev, lib, @"reduce_sum", nil);
	if (pr) {
		id<MTLBuffer> in = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
		id<MTLBuffer> part = [dev newBufferWithLength:(N / 256) * 4 options:MTLResourceStorageModeShared];
		uint32_t* iv = in.contents;
		for (int i = 0; i < N; i++) iv[i] = (uint32_t)(i * 7 + 1);
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pr];
		[ce setBuffer:in offset:0 atIndex:0];
		[ce setBuffer:part offset:0 atIndex:1];
		[ce setThreadgroupMemoryLength:256 * 4 atIndex:0];
		[ce dispatchThreadgroups:MTLSizeMake(N / 256, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		int bad = 0;
		uint32_t* pp = part.contents;
		for (int g = 0; g < N / 256; g++) {
			uint32_t want = 0;
			for (int i = 0; i < 256; i++) want += iv[g * 256 + i];
			if (pp[g] != want) bad++;
		}
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "threadgroup-memory reduction (16 groups x 256): %d of %d sums wrong, sum[0]=%u", bad,
			N / 256, pp[0]);
	} else CHECK(0, "reduce_sum pipeline");

	// function constants
	MTLFunctionConstantValues* cv = [[MTLFunctionConstantValues alloc] init];
	float scale = 2.5f; bool neg = true; int32_t offs = 3;
	[cv setConstantValue:&scale type:MTLDataTypeFloat atIndex:0];
	[cv setConstantValue:&neg type:MTLDataTypeBool atIndex:1];
	[cv setConstantValue:&offs type:MTLDataTypeInt withName:@"fc_offset"];
	id<MTLComputePipelineState> pf = pipeline(dev, lib, @"fconst", cv);
	if (pf) {
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pf];
		[ce setBuffer:a offset:0 atIndex:0];
		[ce setBuffer:c offset:0 atIndex:1];
		[ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(pf.threadExecutionWidth, 1, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		int bad = 0;
		for (int i = 0; i < N; i++) if (fc[i] != -(fa[i] * 2.5f + 3.0f)) bad++;
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "function constants (float 2.5, bool true by index; int 3 by name): %d wrong, y[2]=%g",
			bad, fc[2]);
	} else CHECK(0, "fconst pipeline with constants");

	// sampler + texture read
	id<MTLComputePipelineState> pst = pipeline(dev, lib, @"sample_tex", nil);
	MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
	sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
	id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
	if (pst && smp && wt) {
		id<MTLBuffer> out = [dev newBufferWithLength:100 * 60 * 16 options:MTLResourceStorageModeShared];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pst];
		[ce setTexture:wt atIndex:0];
		[ce setSamplerState:smp atIndex:0];
		[ce setBuffer:out offset:0 atIndex:0];
		[ce dispatchThreads:MTLSizeMake(100, 60, 1) threadsPerThreadgroup:MTLSizeMake(16, 4, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		const float* o = out.contents;
		int bad = 0;
		for (int y = 0; y < 60; y++)
			for (int x = 0; x < 100; x++) {
				const float* p = o + (y * 100 + x) * 4;
				if (fabsf(p[0] - x / 255.0f) > 0.002f || fabsf(p[1] - y / 255.0f) > 0.002f || p[3] != 1.0f) bad++;
			}
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "setSamplerState + texture sample in a kernel: %d of 6000 wrong", bad);
	} else CHECK(0, "sample_tex pipeline / sampler (%p %p)", pst, smp);

	// pointers in memory: gpuAddress + useResource
	id<MTLComputePipelineState> pp = pipeline(dev, lib, @"via_ptr", nil);
	if (pp) {
		id<MTLBuffer> args = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
		struct { uint64_t src, dst; uint32_t count; } *ap = args.contents;
		ap->src = a.gpuAddress; ap->dst = c.gpuAddress + 16; ap->count = 100;
		for (int i = 0; i < N; i++) fc[i] = -9;
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pp];
		[ce setBuffer:args offset:0 atIndex:0];
		[ce useResource:a usage:MTLResourceUsageRead];
		[ce useResource:c usage:MTLResourceUsageWrite];
		[ce dispatchThreads:MTLSizeMake(128, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		int bad = 0;
		for (int i = 0; i < 200; i++) {
			float want = (i >= 4 && i < 104) ? fa[i - 4] * 2.0f + 1.0f : -9.0f;
			if (fc[i] != want) bad++;
		}
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "kernel reads buffer pointers (gpuAddress %#llx, %#llx) from memory: %d wrong", a.gpuAddress,
			c.gpuAddress, bad);
	} else CHECK(0, "via_ptr pipeline");

	// runtime-compiled source (client-side compile to AIR by the simulator's Metal compiler)
	t0 = now();
	err = nil;
	id<MTLLibrary> slib = [dev newLibraryWithSource:[NSString stringWithUTF8String:probe_metal_source] options:nil error:&err];
	CHECK(slib != nil, "newLibraryWithSource (probe.metal): %s (%.0f ms)", slib ? [slib.functionNames componentsJoinedByString:@","].UTF8String :
		err.description.UTF8String, (now() - t0) * 1000);
	id<MTLComputePipelineState> sv = slib ? pipeline(dev, slib, @"vadd", nil) : nil;
	if (sv) {
		for (int i = 0; i < N; i++) fc[i] = 0;
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:sv];
		[ce setBuffer:a offset:0 atIndex:0];
		[ce setBuffer:b offset:0 atIndex:1];
		[ce setBuffer:c offset:0 atIndex:2];
		[ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		int bad = 0;
		for (int i = 0; i < N; i++) if (fc[i] != fa[i] + fb[i]) bad++;
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "vadd from newLibraryWithSource: %d wrong", bad);
	}
}


// ---- stage 5: render pipelines. Every result is checked on the CPU.
static id<MTLRenderPipelineState> rpipe(id<MTLDevice> dev, id<MTLLibrary> lib, NSString* vs, NSString* fs, MTLPixelFormat cf,
	MTLPixelFormat df, NSUInteger samples, MTLVertexDescriptor* vd, BOOL blend) {
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [lib newFunctionWithName:vs];
	d.fragmentFunction = [lib newFunctionWithName:fs];
	d.colorAttachments[0].pixelFormat = cf;
	if (blend) {
		MTLRenderPipelineColorAttachmentDescriptor* c = d.colorAttachments[0];
		c.blendingEnabled = YES;
		c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	d.depthAttachmentPixelFormat = df;
	d.rasterSampleCount = samples;
	if (vd) d.vertexDescriptor = vd;
	NSError* err = nil;
	double t0 = now();
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	printf("INFO render pipeline %s/%s: %s (%.0f ms)\n", vs.UTF8String, fs.UTF8String, p ? "ok" : err.description.UTF8String, (now() - t0) * 1000);
	return p;
}
static id<MTLTexture> rtex(id<MTLDevice> dev, MTLPixelFormat f, NSUInteger w, NSUInteger h, NSUInteger samples, MTLStorageMode sm) {
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = sm;
	if (samples > 1) { d.textureType = MTLTextureType2DMultisample; d.sampleCount = samples; }
	return [dev newTextureWithDescriptor:d];
}
static MTLRenderPassDescriptor* rpass(id<MTLTexture> t, MTLClearColor c) {
	MTLRenderPassDescriptor* p = [MTLRenderPassDescriptor renderPassDescriptor];
	p.colorAttachments[0].texture = t;
	p.colorAttachments[0].loadAction = MTLLoadActionClear;
	p.colorAttachments[0].storeAction = MTLStoreActionStore;
	p.colorAttachments[0].clearColor = c;
	return p;
}
static int near(int a, int b, int tol) { return abs(a - b) <= tol; }
// the triangle (-1,-1) red, (1,-1) green, (-1,1) blue: pixel (x,y) of a 64x64 target is inside when x < y
static int tri_wrong(const uint8_t* px, size_t bpr, int bgra, int* inside) {
	int bad = 0;
	*inside = 0;
	for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
		if (abs(x - y) <= 1) continue;
		const uint8_t* p = px + y * bpr + x * 4;
		int r = p[bgra ? 2 : 0], g = p[1], b = p[bgra ? 0 : 2], a = p[3];
		if (x < y) {
			(*inside)++;
			double xn = (x + 0.5) / 32 - 1, yn = 1 - (y + 0.5) / 32, bb = (xn + 1) / 2, cc = (yn + 1) / 2, aa = 1 - bb - cc;
			if (!near(r, (int)lround(aa * 255), 2) || !near(g, (int)lround(bb * 255), 2) || !near(b, (int)lround(cc * 255), 2) || a != 255) bad++;
		} else if (r != 0 || g != 255 || b != 0 || a != 255) bad++;  // clear colour: green
	}
	return bad;
}
static const float kTriPos[] = { -1, -1, 0, 1,   1, -1, 0, 1,   -1, 1, 0, 1 };
static const float kTriCol[] = { 1, 0, 0, 1,   0, 1, 0, 1,   0, 0, 1, 1 };

static void draw_tri(id<MTLRenderCommandEncoder> re, id<MTLRenderPipelineState> p) {
	[re setRenderPipelineState:p];
	[re setVertexBytes:kTriPos length:sizeof(kTriPos) atIndex:0];
	[re setVertexBytes:kTriCol length:sizeof(kTriCol) atIndex:1];
	[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

static IOSurfaceRef g_surface;
static id<MTLTexture> g_surfaceTex;

static void render_tests(id<MTLDevice> dev, id<MTLCommandQueue> q) {
	NSError* err = nil;
	dispatch_data_t dd = dispatch_data_create(probe_metallib, probe_metallib_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&err];
	if (!lib) { CHECK(0, "render: library: %s", err.description.UTF8String); return; }
	MTLClearColor green = MTLClearColorMake(0, 1, 0, 1);

	// 1. clear + a triangle with interpolated colours (vertex data from setVertexBytes, no vertex descriptor)
	id<MTLRenderPipelineState> ptri = rpipe(dev, lib, @"tri_vs", @"color_fs", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, 1, nil, NO);
	CHECK(ptri != nil, "render pipeline tri_vs/color_fs (BGRA8)");
	if (ptri) {
		id<MTLTexture> t = rtex(dev, MTLPixelFormatBGRA8Unorm, 64, 64, 1, MTLStorageModeShared);
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpass(t, green)];
		draw_tri(re, ptri);
		[re endEncoding];
		double t0 = now();
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[64 * 64 * 4];
		[t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		int inside = 0, bad = tri_wrong(px, 256, 1, &inside);
		const uint8_t* c = px + 56 * 256 + 8 * 4;
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0 && inside > 1800,
			"clear + coloured triangle: %d of %d texels wrong (%d inside), (8,56) BGRA=%u,%u,%u,%u (%.1f ms)", bad, 64 * 64, inside, c[0], c[1], c[2], c[3],
			(now() - t0) * 1000);
	}

	// 2. indexed quad, vertex descriptor, texture + nearest sampler, setVertexBytes/setFragmentBytes
	MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
	vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0;
	vd.layouts[0].stride = 16;
	id<MTLRenderPipelineState> pq = rpipe(dev, lib, @"quad_vs", @"tex_fs", MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid, 1, vd, NO);
	CHECK(pq != nil, "render pipeline quad_vs/tex_fs (vertex descriptor, RGBA8)");
	if (pq) {
		uint8_t texels[8 * 8 * 4];
		for (int j = 0; j < 8; j++) for (int i = 0; i < 8; i++) {
			uint8_t* p = texels + (j * 8 + i) * 4;
			p[0] = (uint8_t)(i * 32 + 16); p[1] = (uint8_t)(j * 32 + 8); p[2] = (uint8_t)((i ^ j) * 30); p[3] = 255;
		}
		MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
		id<MTLTexture> src = [dev newTextureWithDescriptor:td];
		[src replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:texels bytesPerRow:32];
		MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
		sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
		id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
		const float verts[] = { -1, -1, 0, 1,   1, -1, 1, 1,   -1, 1, 0, 0,   1, 1, 1, 0 };
		const uint16_t idx[] = { 0, 1, 2, 2, 1, 3 };
		id<MTLBuffer> vb = [dev newBufferWithBytes:verts length:sizeof(verts) options:MTLResourceStorageModeShared];
		id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared];
		id<MTLTexture> t = rtex(dev, MTLPixelFormatRGBA8Unorm, 64, 64, 1, MTLStorageModeShared);
		const float xf[4] = { 1, 1, 0, 0 }, tint[4] = { 1, 0.5f, 1, 1 };
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpass(t, MTLClearColorMake(0, 0, 0, 0))];
		[re setRenderPipelineState:pq];
		[re setVertexBuffer:vb offset:0 atIndex:0];
		[re setVertexBytes:xf length:sizeof(xf) atIndex:1];
		[re setFragmentTexture:src atIndex:0];
		[re setFragmentSamplerState:smp atIndex:0];
		[re setFragmentBytes:tint length:sizeof(tint) atIndex:0];
		[re setCullMode:MTLCullModeNone];
		[re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[64 * 64 * 4];
		[t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		int bad = 0;
		for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
			const uint8_t* p = px + y * 256 + x * 4, *e = texels + ((y / 8) * 8 + x / 8) * 4;
			if (p[0] != e[0] || !near(p[1], e[1] / 2, 1) || p[2] != e[2] || p[3] != 255) bad++;
		}
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "indexed quad (uint16), vertex descriptor, texture + sampler, tint: %d of %d wrong, (40,20)=%u,%u,%u,%u",
			bad, 64 * 64, px[20 * 256 + 160], px[20 * 256 + 161], px[20 * 256 + 162], px[20 * 256 + 163]);
	}

	// 3. blending (source alpha over), and 5. scissor
	id<MTLRenderPipelineState> pb = rpipe(dev, lib, @"tri_vs", @"solid_fs", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, 1, nil, YES);
	id<MTLRenderPipelineState> ps = rpipe(dev, lib, @"tri_vs", @"solid_fs", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, 1, nil, NO);
	static const float kFull[] = { -1, -1, 0.5f, 1,   3, -1, 0.5f, 1,   -1, 3, 0.5f, 1 };
	if (pb && ps) {
		id<MTLTexture> t = rtex(dev, MTLPixelFormatBGRA8Unorm, 64, 64, 1, MTLStorageModeShared);
		id<MTLTexture> t2 = rtex(dev, MTLPixelFormatBGRA8Unorm, 64, 64, 1, MTLStorageModeShared);
		const float red50[4] = { 1, 0, 0, 0.5f }, red[4] = { 1, 0, 0, 1 };
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpass(t, MTLClearColorMake(0, 0, 1, 1))];
		[re setRenderPipelineState:pb];
		[re setVertexBytes:kFull length:sizeof(kFull) atIndex:0];
		[re setVertexBytes:kTriCol length:sizeof(kTriCol) atIndex:1];
		[re setFragmentBytes:red50 length:16 atIndex:0];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re endEncoding];
		re = [cb renderCommandEncoderWithDescriptor:rpass(t2, MTLClearColorMake(0, 0, 0, 1))];
		[re setRenderPipelineState:ps];
		[re setVertexBytes:kFull length:sizeof(kFull) atIndex:0];
		[re setVertexBytes:kTriCol length:sizeof(kTriCol) atIndex:1];
		[re setFragmentBytes:red length:16 atIndex:0];
		[re setScissorRect:(MTLScissorRect){ 32, 8, 16, 24 }];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[64 * 64 * 4];
		[t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		int bad = 0;
		for (int i = 0; i < 64 * 64; i++) { const uint8_t* p = px + i * 4; if (!near(p[0], 128, 1) || p[1] != 0 || !near(p[2], 128, 1) || !near(p[3], 191, 1)) bad++; }
		CHECK(bad == 0, "blending 50%% red over blue (src alpha, 1 - src alpha): %d wrong, BGRA=%u,%u,%u,%u", bad, px[0], px[1], px[2], px[3]);
		[t2 getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		bad = 0;
		for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
			int in = x >= 32 && x < 48 && y >= 8 && y < 32;
			const uint8_t* p = px + y * 256 + x * 4;
			if (p[2] != (in ? 255 : 0) || p[1] != 0 || p[0] != 0) bad++;
		}
		CHECK(bad == 0, "scissor rect (32,8 16x24): %d wrong", bad);
	}

	// 4. depth test: Depth32Float cleared to 1, Less + write: z 0.5 red everywhere, z 0.7 green (hidden), z 0.3 blue on the left
	MTLDepthStencilDescriptor* dsd = [MTLDepthStencilDescriptor new];
	dsd.depthCompareFunction = MTLCompareFunctionLess;
	dsd.depthWriteEnabled = YES;
	id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];
	id<MTLRenderPipelineState> pd = rpipe(dev, lib, @"tri_vs", @"solid_fs", MTLPixelFormatBGRA8Unorm, MTLPixelFormatDepth32Float, 1, nil, NO);
	CHECK(dss && pd, "depth-stencil state and pipeline with a Depth32Float attachment");
	if (dss && pd) {
		id<MTLTexture> t = rtex(dev, MTLPixelFormatBGRA8Unorm, 64, 64, 1, MTLStorageModeShared);
		id<MTLTexture> dt = rtex(dev, MTLPixelFormatDepth32Float, 64, 64, 1, MTLStorageModePrivate);
		MTLRenderPassDescriptor* rp = rpass(t, MTLClearColorMake(0, 0, 0, 1));
		rp.depthAttachment.texture = dt;
		rp.depthAttachment.loadAction = MTLLoadActionClear;
		rp.depthAttachment.storeAction = MTLStoreActionDontCare;
		rp.depthAttachment.clearDepth = 1.0;
		float z5[12], z7[12];
		memcpy(z5, kFull, sizeof(z5)); memcpy(z7, kFull, sizeof(z7));
		for (int i = 0; i < 3; i++) { z5[i * 4 + 2] = 0.5f; z7[i * 4 + 2] = 0.7f; }
		const float left[] = { -1, -1, 0.3f, 1,   0, -1, 0.3f, 1,   -1, 1, 0.3f, 1,   0, -1, 0.3f, 1,   0, 1, 0.3f, 1,   -1, 1, 0.3f, 1 };
		const float cr[4] = { 1, 0, 0, 1 }, cg[4] = { 0, 1, 0, 1 }, cbl[4] = { 0, 0, 1, 1 };
		float cols[24] = { 0 };
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
		[re setRenderPipelineState:pd];
		[re setDepthStencilState:dss];
		[re setVertexBytes:cols length:sizeof(cols) atIndex:1];
		[re setVertexBytes:z5 length:sizeof(z5) atIndex:0];
		[re setFragmentBytes:cr length:16 atIndex:0];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re setVertexBytes:z7 length:sizeof(z7) atIndex:0];
		[re setFragmentBytes:cg length:16 atIndex:0];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re setVertexBytes:left length:sizeof(left) atIndex:0];
		[re setFragmentBytes:cbl length:16 atIndex:0];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[64 * 64 * 4];
		[t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		int bad = 0;
		for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
			const uint8_t* p = px + y * 256 + x * 4;
			if (x < 32 ? (p[0] != 255 || p[2] != 0) : (p[2] != 255 || p[0] != 0)) bad++;
			if (p[1] != 0) bad++;
		}
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "depth test (Less, write): %d of %d wrong, (8,8) BGRA=%u,%u,%u (40,8)=%u,%u,%u", bad, 64 * 64,
			px[8 * 256 + 32], px[8 * 256 + 33], px[8 * 256 + 34], px[8 * 256 + 160], px[8 * 256 + 161], px[8 * 256 + 162]);
	}

	// 6. 4x MSAA with a resolve
	id<MTLRenderPipelineState> pm = rpipe(dev, lib, @"tri_vs", @"color_fs", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, 4, nil, NO);
	if (pm) {
		id<MTLTexture> ms = rtex(dev, MTLPixelFormatBGRA8Unorm, 64, 64, 4, MTLStorageModePrivate);
		id<MTLTexture> t = rtex(dev, MTLPixelFormatBGRA8Unorm, 64, 64, 1, MTLStorageModeShared);
		MTLRenderPassDescriptor* rp = rpass(ms, green);
		rp.colorAttachments[0].resolveTexture = t;
		rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
		draw_tri(re, pm);
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		static uint8_t px[64 * 64 * 4];
		[t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		int inside = 0, bad = tri_wrong(px, 256, 1, &inside);
		// on the diagonal: a mix of the triangle and the clear colour
		const uint8_t* d = px + 20 * 256 + 20 * 4;
		CHECK(ms && cb.status == MTLCommandBufferStatusCompleted && bad == 0, "4x MSAA triangle resolved: %d wrong off the edge, edge (20,20) BGRA=%u,%u,%u,%u",
			bad, d[0], d[1], d[2], d[3]);
	} else CHECK(0, "4x MSAA pipeline");

	// 7. into an IOSurface-backed texture (com.apple.IOSurface.Remote), read through IOSurface here and in another process
	NSDictionary* props = @{ (id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4,
	                         (id)kIOSurfacePixelFormat: @((int)'BGRA') };
	IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
	MTLTextureDescriptor* std_ = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
	std_.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	std_.storageMode = MTLStorageModeShared;
	id<MTLTexture> st = s ? [dev newTextureWithDescriptor:std_ iosurface:s plane:0] : nil;
	CHECK(st != nil, "texture over IOSurface %u (64x64 BGRA, bytesPerRow %zu)", s ? IOSurfaceGetID(s) : 0, s ? IOSurfaceGetBytesPerRow(s) : 0);
	if (st && ptri) {
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpass(st, green)];
		draw_tri(re, ptri);
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		int inside = 0, bad = tri_wrong(IOSurfaceGetBaseAddress(s), IOSurfaceGetBytesPerRow(s), 1, &inside);
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "render into the IOSurface, read through IOSurfaceGetBaseAddress: %d wrong", bad);
		// another process looks the surface up by ID and checks the same pixels
		char idbuf[16], path[1024];
		uint32_t psize = sizeof(path);
		snprintf(idbuf, sizeof idbuf, "%u", IOSurfaceGetID(s));
		extern int _NSGetExecutablePath(char*, uint32_t*);
		_NSGetExecutablePath(path, &psize);
		char* args[] = { path, "readsurface", idbuf, NULL };
		extern char** environ;
		// Platforms 1: libSystem's posix_spawn under another name (tvOS/watchOS headers mark it unavailable)
		extern int x86sim_posix_spawn(pid_t*, const char*, const void*, const void*, char* const[], char* const[]) __asm("_posix_spawn");
		pid_t pid = 0;
		int rc = x86sim_posix_spawn(&pid, path, NULL, NULL, args, environ), status = -1;
		if (rc == 0) waitpid(pid, &status, 0);
		CHECK(rc == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, "process %d looked IOSurface %s up and read the rendered pixels (exit %d, spawn %d)",
			pid, idbuf, WIFEXITED(status) ? WEXITSTATUS(status) : -1, rc);
		g_surface = s;
		g_surfaceTex = st;
	}

	// x86Sim Speed 1c: arm64 home is 1206 wide — tight rows 4824, IOSurface stride 4864.
	// Render a known pattern into a 1206-wide surface and check every texel + that the 40-byte
	// pad is untouched (a width*4 write would smear into the pad and shift rows when read back).
	{
		const NSUInteger W = 1206, H = 64;
		NSDictionary* props = @{
			(id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
			(id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((int)'BGRA'),
		};
		IOSurfaceRef wide = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		size_t bpr = wide ? IOSurfaceGetBytesPerRow(wide) : 0;
		CHECK(wide && bpr >= W * 4 && (bpr % 64) == 0,
			"1206-wide IOSurface created (bytesPerRow %zu, tight %zu)", bpr, (size_t)W * 4);
		MTLTextureDescriptor* wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			width:W height:H mipmapped:NO];
		wd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		wd.storageMode = MTLStorageModeShared;
		id<MTLTexture> wt = wide ? [dev newTextureWithDescriptor:wd iosurface:wide plane:0] : nil;
		CHECK(wt != nil, "texture over 1206-wide IOSurface (bytesPerRow %zu)", bpr);
		if (wt && ptri) {
			// Fill pad with 0xCD before the GPU write so a tight write is visible.
			IOSurfaceLock(wide, 0, NULL);
			uint8_t* base = IOSurfaceGetBaseAddress(wide);
			memset(base, 0xCD, bpr * H);
			IOSurfaceUnlock(wide, 0, NULL);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpass(wt, green)];
			draw_tri(re, ptri);
			[re endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			IOSurfaceLock(wide, kIOSurfaceLockReadOnly, NULL);
			base = IOSurfaceGetBaseAddress(wide);
			int inside = 0, bad = tri_wrong(base, bpr, 1, &inside);
			size_t pad = bpr - W * 4, pad_bad = 0;
			for (NSUInteger y = 0; y < H; y++) {
				uint8_t* p = base + y * bpr + W * 4;
				for (size_t i = 0; i < pad; i++) if (p[i] != 0xCD) pad_bad++;
			}
			IOSurfaceUnlock(wide, kIOSurfaceLockReadOnly, NULL);
			CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0 && pad_bad == 0,
				"1206-wide IOSurface render (bpr %zu): %d texel wrong, %zu pad bytes clobbered (inside %d)",
				bpr, bad, pad_bad, inside);
		}
		if (wide) CFRelease(wide);
	}
}

// child: IOSurfaceLookup(id), check the triangle; exit status = wrong texels (capped)
static int read_surface(const char* ids) {
	IOSurfaceRef s = IOSurfaceLookup((IOSurfaceID)strtoul(ids, NULL, 0));
	if (!s) { printf("child: IOSurfaceLookup(%s) failed\n", ids); return 255; }
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	int inside = 0, bad = tri_wrong(IOSurfaceGetBaseAddress(s), IOSurfaceGetBytesPerRow(s), 1, &inside);
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	printf("INFO child process %d: IOSurface %s %zux%zu: %d wrong, %d inside\n", getpid(), ids, IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), bad, inside);
	return bad > 254 ? 254 : bad;
}

int main(int argc, char** argv) {
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc > 2 && !strcmp(argv[1], "readsurface")) return read_surface(argv[2]);
	@autoreleasepool {
		double t0 = now();
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		CHECK(dev != nil, "MTLCreateSystemDefaultDevice() = %p (%.0f ms)", dev, (now() - t0) * 1000);
		if (!dev) { printf("SUMMARY %d passed %d failed\n", passes, fails + 1); return 1; }
		printf("INFO name=\"%s\" class=%s registryID=%#llx\n", dev.name.UTF8String, class_getName([(id)dev class]), dev.registryID);
		printf("INFO maxBufferLength=%lu unified=%d lowPower=%d headless=%d recommendedMaxWorkingSet=%llu\n",
			(unsigned long)dev.maxBufferLength, dev.hasUnifiedMemory, dev.isLowPower, dev.isHeadless, dev.recommendedMaxWorkingSetSize);
		MTLSize tg = dev.maxThreadsPerThreadgroup;
		printf("INFO maxThreadsPerThreadgroup=%lux%lux%lu argumentBuffersSupport=%lu\n", (unsigned long)tg.width, (unsigned long)tg.height,
			(unsigned long)tg.depth, (unsigned long)dev.argumentBuffersSupport);
		struct { MTLGPUFamily f; const char* n; } fams[] = { { MTLGPUFamilyApple4, "Apple4" }, { MTLGPUFamilyApple7, "Apple7" },
			{ MTLGPUFamilyApple9, "Apple9" }, { MTLGPUFamilyMac2, "Mac2" }, { MTLGPUFamilyCommon1, "Common1" }, { MTLGPUFamilyCommon2, "Common2" },
			{ MTLGPUFamilyCommon3, "Common3" }, { MTLGPUFamilyMetal3, "Metal3" } };
		printf("INFO families:");
		for (size_t i = 0; i < sizeof(fams) / sizeof(*fams); i++) printf(" %s=%d", fams[i].n, [dev supportsFamily:fams[i].f]);
		printf("\n");
		CHECK(dev.name.length > 0, "device name non-empty");

		// --- stage 2: buffers
		id<MTLBuffer> b1 = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
		CHECK(b1 && b1.length == 65536 && b1.contents, "newBufferWithLength 64K: %p contents %p", b1, b1.contents);
		uint32_t* w = b1.contents;
		for (int i = 0; i < 16384; i++) w[i] = 0x01000000u * (i & 0xff) + i;
		uint8_t pattern[1000];
		for (int i = 0; i < 1000; i++) pattern[i] = (uint8_t)(i * 7 + 3);
		id<MTLBuffer> b2 = [dev newBufferWithBytes:pattern length:sizeof(pattern) options:MTLResourceStorageModeShared];
		CHECK(b2 && memcmp(b2.contents, pattern, sizeof(pattern)) == 0, "newBufferWithBytes 1000: contents round trip");

		// --- stage 2: textures
		MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
		td.storageMode = MTLStorageModeShared;
		id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
		CHECK(tex != nil && tex.width == 64, "newTextureWithDescriptor RGBA8 64x64 shared: %p", tex);
		uint8_t img[64 * 64 * 4], back[64 * 64 * 4];
		for (int i = 0; i < (int)sizeof(img); i++) img[i] = (uint8_t)(i ^ (i >> 8));
		[tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:img bytesPerRow:256];
		memset(back, 0, sizeof(back));
		[tex getBytes:back bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		CHECK(memcmp(img, back, sizeof(img)) == 0, "texture replaceRegion/getBytes round trip (64x64)");
		uint8_t sub[8 * 4 * 4], subback[8 * 4 * 4];
		for (int i = 0; i < (int)sizeof(sub); i++) sub[i] = (uint8_t)(200 + i);
		[tex replaceRegion:MTLRegionMake2D(10, 20, 8, 4) mipmapLevel:0 withBytes:sub bytesPerRow:32];
		[tex getBytes:subback bytesPerRow:32 fromRegion:MTLRegionMake2D(10, 20, 8, 4) mipmapLevel:0];
		CHECK(memcmp(sub, subback, sizeof(sub)) == 0, "texture sub-region replace/getBytes (8x4 at 10,20)");

		// --- stage 3: command buffers, clear, blits
		id<MTLCommandQueue> q = [dev newCommandQueue];
		CHECK(q != nil, "newCommandQueue");
		MTLTextureDescriptor* rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:128 height:96 mipmapped:NO];
		rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		rd.storageMode = MTLStorageModePrivate;
		id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
		CHECK(rt != nil, "private BGRA8 128x96 render target");
		id<MTLBuffer> rb = [dev newBufferWithLength:128 * 96 * 4 options:MTLResourceStorageModeShared];
		memset(rb.contents, 0xee, rb.length);

		id<MTLCommandBuffer> cb = [q commandBuffer];
		__block int completed = 0, scheduled = 0;
		__block MTLCommandBufferStatus seen = 0;
		[cb addScheduledHandler:^(id<MTLCommandBuffer> c) { (void)c; scheduled++; }];
		[cb addCompletedHandler:^(id<MTLCommandBuffer> c) { completed++; seen = c.status; }];
		MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = rt;
		pass.colorAttachments[0].loadAction = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.5, 0.25, 1.0);
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
		CHECK(re != nil, "renderCommandEncoderWithDescriptor (clear)");
		[re endEncoding];
		id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
		[be copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(128, 96, 1)
			toBuffer:rb destinationOffset:0 destinationBytesPerRow:512 destinationBytesPerImage:512 * 96];
		// buffer -> buffer
		[be copyFromBuffer:b1 sourceOffset:1024 toBuffer:b1 destinationOffset:32768 size:4096];
		// buffer -> texture (the 1000-byte pattern buffer's first 8x8 RGBA8 texels = 256 bytes into tex at 40,40)
		[be copyFromBuffer:b2 sourceOffset:0 sourceBytesPerRow:32 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8, 8, 1)
			toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(40, 40, 0)];
		[be fillBuffer:b1 range:NSMakeRange(60000, 100) value:0x5a];
		[be endEncoding];
		id<MTLSharedEvent> ev = [dev newSharedEvent];
		CHECK(ev != nil, "newSharedEvent");
		[cb encodeSignalEvent:ev value:42];
		t0 = now();
		[cb commit];
		[cb waitUntilCompleted];
		double ms = (now() - t0) * 1000;
		usleep(100000); // handlers run asynchronously after waitUntilCompleted may return
		CHECK(cb.status == MTLCommandBufferStatusCompleted, "command buffer completed: status %lu error %s (%.1f ms)", (unsigned long)cb.status,
			cb.error ? cb.error.description.UTF8String : "none", ms);
		CHECK(completed == 1 && seen == MTLCommandBufferStatusCompleted, "addCompletedHandler ran (%d, status %lu)", completed, (unsigned long)seen);
		CHECK(scheduled == 1, "addScheduledHandler ran (%d)", scheduled);
		printf("INFO GPUStartTime=%f GPUEndTime=%f\n", cb.GPUStartTime, cb.GPUEndTime);
		const uint8_t* px = rb.contents;
		int bad = 0;
		for (int i = 0; i < 128 * 96; i++) {
			const uint8_t* p = px + 4 * i;
			// BGRA8 of (r 1.0, g 0.5, b 0.25, a 1.0)
			if (p[0] < 63 || p[0] > 64 || p[1] < 127 || p[1] > 128 || p[2] != 255 || p[3] != 255) bad++;
		}
		CHECK(bad == 0, "GPU clear to (1, 0.5, 0.25, 1) read back via blit: first texel BGRA = %u,%u,%u,%u, %d of %d texels wrong",
			px[0], px[1], px[2], px[3], bad, 128 * 96);
		CHECK(memcmp((char*)b1.contents + 32768, (char*)b1.contents + 1024, 4096) == 0, "blit buffer->buffer (4096 bytes)");
		int fillok = 1;
		for (int i = 60000; i < 60100; i++) if (((uint8_t*)b1.contents)[i] != 0x5a) fillok = 0;
		CHECK(fillok && ((uint8_t*)b1.contents)[60100] != 0x5a, "fillBuffer 100 bytes");
		uint8_t t8[8 * 8 * 4];
		[tex getBytes:t8 bytesPerRow:32 fromRegion:MTLRegionMake2D(40, 40, 8, 8) mipmapLevel:0];
		CHECK(memcmp(t8, pattern, 256) == 0, "blit buffer->texture (8x8 at 40,40), read with getBytes");
		CHECK(ev.signaledValue == 42, "shared event signaled by GPU: %llu", ev.signaledValue);

		// event from the CPU + a command buffer waiting for it
		id<MTLCommandBuffer> cb2 = [q commandBuffer];
		[cb2 encodeWaitForEvent:ev value:50];
		id<MTLBlitCommandEncoder> be2 = [cb2 blitCommandEncoder];
		[be2 fillBuffer:rb range:NSMakeRange(0, 16) value:0x11];
		[be2 endEncoding];
		[cb2 encodeSignalEvent:ev value:60];
		[cb2 commit];
		usleep(200000);
		CHECK(cb2.status != MTLCommandBufferStatusCompleted && ((uint8_t*)rb.contents)[0] != 0x11, "command buffer waits for event value 50 (status %lu)",
			(unsigned long)cb2.status);
		ev.signaledValue = 50;
		[cb2 waitUntilCompleted];
		CHECK(cb2.status == MTLCommandBufferStatusCompleted && ((uint8_t*)rb.contents)[0] == 0x11 && ev.signaledValue == 60,
			"CPU setSignaledValue(50) released it; it signaled 60 (value %llu)", ev.signaledValue);

		// listener
		MTLSharedEventListener* li = [[MTLSharedEventListener alloc] initWithDispatchQueue:dispatch_queue_create("probe.listener", 0)];
		__block uint64_t notified = 0;
		dispatch_semaphore_t sem = dispatch_semaphore_create(0);
		[ev notifyListener:li atValue:70 block:^(id<MTLSharedEvent> e, uint64_t v) { (void)e; notified = v; dispatch_semaphore_signal(sem); }];
		id<MTLCommandBuffer> cb3 = [q commandBuffer];
		[cb3 encodeSignalEvent:ev value:70];
		[cb3 commit];
		long timedout = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
		CHECK(!timedout && notified == 70, "notifyListener:atValue:70 fired (%llu)", notified);

		// many small command buffers
		t0 = now();
		id<MTLCommandBuffer> last = nil;
		for (int i = 0; i < 100; i++) {
			id<MTLCommandBuffer> c = [q commandBuffer];
			id<MTLBlitCommandEncoder> e = [c blitCommandEncoder];
			[e fillBuffer:b1 range:NSMakeRange(i * 4, 4) value:(uint8_t)i];
			[e endEncoding];
			[c commit];
			last = c;
		}
		[last waitUntilCompleted];
		int seqok = 1;
		for (int i = 0; i < 100; i++) if (((uint8_t*)b1.contents)[i * 4 + 3] != (uint8_t)i) seqok = 0;
		CHECK(seqok, "100 command buffers in order (%.1f ms total)", (now() - t0) * 1000);

		// --- stage 4: compute
		compute_tests(dev, q);

		// --- stage 5: render
		render_tests(dev, q);
	}
	printf("SUMMARY %d passed %d failed\n", passes, fails);
	return fails != 0;
}
