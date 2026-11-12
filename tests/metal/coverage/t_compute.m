// x86Sim MetalCoverage: compute: dispatch forms, bindings, threadgroup memory, atomics, SIMD-groups, textures, constants.
#import "mtlcov.h"

static NSString* const SRC = MC_MSL
	"kernel void add(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]], device float* c [[buffer(2)]],\n"
	"                uint i [[thread_position_in_grid]]) { c[i] = a[i] + b[i]; }\n"
	"struct P { float k; uint n; };\n"
	"kernel void scale(constant P& p [[buffer(0)]], device float* x [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
	"  if (i < p.n) x[i] *= p.k; }\n"
	"kernel void tgsum(device const uint* in [[buffer(0)]], device uint* out [[buffer(1)]], threadgroup uint* s [[threadgroup(0)]],\n"
	"                  uint t [[thread_index_in_threadgroup]], uint g [[threadgroup_position_in_grid]], uint n [[threads_per_threadgroup]]) {\n"
	"  s[t] = in[g * n + t]; threadgroup_barrier(mem_flags::mem_threadgroup);\n"
	"  for (uint k = n / 2; k > 0; k /= 2) { if (t < k) s[t] += s[t + k]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
	"  if (t == 0) out[g] = s[0]; }\n"
	"kernel void atom(device atomic_uint* c [[buffer(0)]], device atomic_uint* m [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
	"  atomic_fetch_add_explicit(c, 1, memory_order_relaxed); atomic_fetch_max_explicit(m, i, memory_order_relaxed); }\n"
	"kernel void simdk(device uint* out [[buffer(0)]], uint i [[thread_position_in_grid]], uint l [[thread_index_in_simdgroup]],\n"
	"                 uint w [[threads_per_simdgroup]]) {\n"
	"  uint s = simd_sum(i); uint b = simd_broadcast(i, 0); out[i] = (simd_shuffle_down(i, 1) == (l + 1 < w ? i + 1 : i)) ? s - b : 0xffffffff; }\n"
	"kernel void writetex(texture2d<float, access::write> t [[texture(0)]], uint2 p [[thread_position_in_grid]]) {\n"
	"  t.write(float4(p.x / 255.0, p.y / 255.0, 0.5, 1.0), p); }\n"
	"kernel void readwrite(texture2d<float, access::read_write> t [[texture(0)]], uint2 p [[thread_position_in_grid]]) {\n"
	"  t.write(t.read(p) * 0.5, p); }\n"
	"constant float fk [[function_constant(0)]];\n"
	"constant bool fb [[function_constant(1)]];\n"
	"kernel void fconst(device float* x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] = fb ? fk * i : -1.0; }\n"
	"kernel void sample(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4* o [[buffer(0)]],\n"
	"                   uint i [[thread_position_in_grid]]) { o[i] = t.sample(s, float2((i + 0.5) / 4.0, 0.5)); }\n";

MC_TEST(compute, dispatch_threadgroups, "MTLCommandBuffer computeCommandEncoder;MTLDevice newComputePipelineStateWithFunction:error:;"
        "MTLComputeCommandEncoder setComputePipelineState:;MTLComputeCommandEncoder setBuffer:offset:atIndex:;"
        "MTLComputeCommandEncoder dispatchThreadgroups:threadsPerThreadgroup:;MTLLibrary newFunctionWithName:;"
        "MTLDevice newLibraryWithSource:options:error:;MTLComputePipelineState threadExecutionWidth;"
        "MTLComputePipelineState maxTotalThreadsPerThreadgroup") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"add", &err);
	MC_NOTNIL(p, err);
	[detail appendFormat:@"width %lu max %lu ", (unsigned long)p.threadExecutionWidth, (unsigned long)p.maxTotalThreadsPerThreadgroup];
	int n = 4096;
	id<MTLBuffer> a = mc_buf(dev, n * 4), b = mc_buf(dev, n * 4), c = mc_buf(dev, n * 4);
	for (int i = 0; i < n; i++) { ((float*)a.contents)[i] = i; ((float*)b.contents)[i] = 0.5f * i; }
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p];
	[ce setBuffer:a offset:0 atIndex:0]; [ce setBuffer:b offset:0 atIndex:1]; [ce setBuffer:c offset:0 atIndex:2];
	[ce dispatchThreadgroups:MTLSizeMake(n / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	for (int i = 0; i < n; i++) MC_CHECK(((float*)c.contents)[i] == 1.5f * i, @"c[%d] = %f", i, ((float*)c.contents)[i]);
	return MC_PASS;
}

MC_TEST(compute, dispatch_threads_nonuniform, "MTLComputeCommandEncoder dispatchThreads:threadsPerThreadgroup:;"
        "MTLComputeCommandEncoder setBytes:length:atIndex:;MTLComputeCommandEncoder setBufferOffset:atIndex:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple4] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"scale", &err);
	MC_NOTNIL(p, err);
	int n = 1000;
	id<MTLBuffer> x = mc_buf(dev, (n + 16) * 4);
	for (int i = 0; i < n + 16; i++) ((float*)x.contents)[i] = 1;
	struct { float k; uint32_t n; } prm = { 3, (uint32_t)n };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p];
	[ce setBytes:&prm length:sizeof prm atIndex:0];
	[ce setBuffer:x offset:0 atIndex:1];
	[ce setBufferOffset:16 * 4 atIndex:1];  // the kernel's x[0] is element 16
	[ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	float* f = x.contents;
	MC_CHECK(f[15] == 1 && f[16] == 3 && f[16 + n - 1] == 3 && f[16 + n - 1 + 1 - 1] == 3, @"%f %f %f", f[15], f[16], f[16 + n - 1]);
	return MC_PASS;
}

MC_TEST(compute, threadgroup_memory, "MTLComputeCommandEncoder setThreadgroupMemoryLength:atIndex:") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"tgsum", &err);
	MC_NOTNIL(p, err);
	int g = 32, n = 256;
	id<MTLBuffer> in = mc_buf(dev, g * n * 4), out = mc_buf(dev, g * 4);
	for (int i = 0; i < g * n; i++) ((uint32_t*)in.contents)[i] = i;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p];
	[ce setBuffer:in offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1];
	[ce setThreadgroupMemoryLength:n * 4 atIndex:0];
	[ce dispatchThreadgroups:MTLSizeMake(g, 1, 1) threadsPerThreadgroup:MTLSizeMake(n, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	for (int k = 0; k < g; k++) {
		uint32_t want = (uint32_t)(n * (2u * k * n + n - 1) / 2);
		MC_CHECK(((uint32_t*)out.contents)[k] == want, @"group %d: %u want %u", k, ((uint32_t*)out.contents)[k], want);
	}
	return MC_PASS;
}

MC_TEST(compute, atomics, "MTLComputeCommandEncoder dispatchThreadgroups:threadsPerThreadgroup:") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"atom", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> c = mc_buf(dev, 4), m = mc_buf(dev, 4);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p];
	[ce setBuffer:c offset:0 atIndex:0]; [ce setBuffer:m offset:0 atIndex:1];
	[ce dispatchThreadgroups:MTLSizeMake(1000, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(*(uint32_t*)c.contents == 64000 && *(uint32_t*)m.contents == 63999, @"count %u max %u",
		*(uint32_t*)c.contents, *(uint32_t*)m.contents);
	return MC_PASS;
}

MC_TEST(compute, simdgroup_ops, "MTLComputeCommandEncoder dispatchThreadgroups:threadsPerThreadgroup:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple6] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"simdk", &err);
	MC_NOTNIL(p, err);
	NSUInteger w = p.threadExecutionWidth, n = w * 8;
	id<MTLBuffer> o = mc_buf(dev, n * 4);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p];
	[ce setBuffer:o offset:0 atIndex:0];
	[ce dispatchThreadgroups:MTLSizeMake(8, 1, 1) threadsPerThreadgroup:MTLSizeMake(w, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	for (NSUInteger g = 0; g < 8; g++) {
		uint32_t base = (uint32_t)(g * w), sum = (uint32_t)(w * base + w * (w - 1) / 2);
		uint32_t got = ((uint32_t*)o.contents)[base + 1];
		MC_CHECK(got == sum - base, @"group %lu: %u want %u (width %lu)", (unsigned long)g, got, sum - base, (unsigned long)w);
	}
	return MC_PASS;
}

MC_TEST(compute, texture_write_readwrite, "MTLComputeCommandEncoder setTexture:atIndex:;MTLDevice readWriteTextureSupport") {
	NSError* err = nil;
	id<MTLComputePipelineState> pw = mc_cps(dev, SRC, @"writetex", &err);
	MC_NOTNIL(pw, err);
	id<MTLComputePipelineState> prw = mc_cps(dev, SRC, @"readwrite", &err);
	id<MTLTexture> t = mc_tex(dev, MTLPixelFormatRGBA8Unorm, 64, 32, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:pw];
	[ce setTexture:t atIndex:0];
	[ce dispatchThreadgroups:MTLSizeMake(8, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	if (prw) {
		[ce memoryBarrierWithScope:MTLBarrierScopeTextures];
		[ce setComputePipelineState:prw];
		[ce dispatchThreadgroups:MTLSizeMake(8, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	}
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t v = mc_texel_rgba8(t, 40, 20);
	int r = v & 0xff, g = (v >> 8) & 0xff, b = (v >> 16) & 0xff;
	int f = prw ? 2 : 1;
	MC_CHECK(abs(r - 40 / f) <= 1 && abs(g - 20 / f) <= 1 && abs(b - 128 / f) <= 1, @"(40,20) = %08x", v);
	if (!prw) MC_FAILF(@"read_write texture kernel did not compile: %@", err.localizedDescription);
	return MC_PASS;
}

MC_TEST(compute, function_constants, "MTLLibrary newFunctionWithName:constantValues:error:;MTLFunctionConstantValues setConstantValue:type:atIndex:;"
        "MTLFunctionConstantValues setConstantValue:type:withName:;MTLFunction functionConstantsDictionary") {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MC_NOTNIL(l, err);
	MTLFunctionConstantValues* cv = [MTLFunctionConstantValues new];
	float k = 2.5f; bool b = true;
	[cv setConstantValue:&k type:MTLDataTypeFloat atIndex:0];
	[cv setConstantValue:&b type:MTLDataTypeBool withName:@"fb"];
	id<MTLFunction> f = [l newFunctionWithName:@"fconst" constantValues:cv error:&err];
	MC_NOTNIL(f, err);
	id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:f error:&err];
	MC_NOTNIL(p, err);
	id<MTLBuffer> x = mc_buf(dev, 64 * 4);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p]; [ce setBuffer:x offset:0 atIndex:0];
	[ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(((float*)x.contents)[10] == 25.0f, @"x[10] = %f", ((float*)x.contents)[10]);
	return MC_PASS;
}

MC_TEST(compute, samplers, "MTLDevice newSamplerStateWithDescriptor:;MTLComputeCommandEncoder setSamplerState:atIndex:;"
        "MTLSamplerDescriptor minFilter;MTLSamplerDescriptor magFilter;MTLSamplerDescriptor sAddressMode") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"sample", &err);
	MC_NOTNIL(p, err);
	id<MTLTexture> t = mc_tex(dev, MTLPixelFormatRGBA8Unorm, 2, 1, MTLTextureUsageShaderRead);
	uint32_t px[2] = { 0xff000000, 0xffffffff };
	[t replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:px bytesPerRow:8];
	MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
	id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
	MC_NOTNIL(s, nil);
	id<MTLBuffer> o = mc_buf(dev, 4 * 16);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p]; [ce setTexture:t atIndex:0]; [ce setSamplerState:s atIndex:0]; [ce setBuffer:o offset:0 atIndex:0];
	[ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	float* f = o.contents;  // u = 0.125, 0.375, 0.625, 0.875 over 2 texels: 0, 0.25, 0.75, 1 (linear, clamped)
	float want[4] = { 0, 0.25f, 0.75f, 1 };
	for (int i = 0; i < 4; i++) MC_CHECK(fabsf(f[i * 4] - want[i]) < 0.02f, @"sample %d = %f want %f", i, f[i * 4], want[i]);
	return MC_PASS;
}

MC_TEST(compute, indirect_dispatch, "MTLComputeCommandEncoder dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple3] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"atom", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> c = mc_buf(dev, 4), m = mc_buf(dev, 4), ind = mc_buf(dev, 16);
	uint32_t* args = (uint32_t*)((uint8_t*)ind.contents + 4);
	args[0] = 10; args[1] = 2; args[2] = 1;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p];
	[ce setBuffer:c offset:0 atIndex:0]; [ce setBuffer:m offset:0 atIndex:1];
	[ce dispatchThreadgroupsWithIndirectBuffer:ind indirectBufferOffset:4 threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(*(uint32_t*)c.contents == 10 * 2 * 32, @"threads ran %u, want %u", *(uint32_t*)c.contents, 10 * 2 * 32);
	return MC_PASS;
}

MC_TEST(compute, concurrent_dispatch_and_barrier, "MTLCommandBuffer computeCommandEncoderWithDispatchType:;MTLComputeCommandEncoder memoryBarrierWithScope:;"
        "MTLComputeCommandEncoder memoryBarrierWithResources:count:;MTLComputeCommandEncoder dispatchType") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"scale", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> x = mc_buf(dev, 256 * 4);
	for (int i = 0; i < 256; i++) ((float*)x.contents)[i] = 1;
	struct { float k; uint32_t n; } prm = { 2, 256 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
	MC_CHECK(ce.dispatchType == MTLDispatchTypeConcurrent, @"dispatchType");
	[ce setComputePipelineState:p];
	[ce setBytes:&prm length:sizeof prm atIndex:0];
	[ce setBuffer:x offset:0 atIndex:1];
	for (int k = 0; k < 4; k++) {
		[ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		if (k & 1) [ce memoryBarrierWithScope:MTLBarrierScopeBuffers];
		else [ce memoryBarrierWithResources:(id<MTLResource>[]){ x } count:1];
	}
	[ce endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(((float*)x.contents)[100] == 16, @"x = %f after 4 barriered doublings", ((float*)x.contents)[100]);
	return MC_PASS;
}
