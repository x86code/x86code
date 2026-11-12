// x86Sim MetalCoverage: render passes, draws, fixed-function state, blending, MSAA, depth/stencil, layered rendering.
#import "mtlcov.h"

static NSString* const SRC = MC_MSL
	"struct VO { float4 p [[position]]; float4 c; float ps [[point_size]]; };\n"
	// full-viewport triangle pair from vertex_id; colour from a constant buffer
	"vertex VO vquad(uint v [[vertex_id]], constant float4& c [[buffer(0)]]) {\n"
	"  float2 p = float2((v & 1) ? 1.0 : -1.0, (v & 2) ? 1.0 : -1.0); VO o; o.p = float4(p, 0.5, 1); o.c = c; o.ps = 1; return o; }\n"
	"fragment float4 color(VO i [[stage_in]]) { return i.c; }\n"
	// vertex descriptor input; per-instance offset; instance/vertex ids into the colour
	"struct VI { float2 pos [[attribute(0)]]; float4 col [[attribute(1)]]; };\n"
	"vertex VO vdesc(VI i [[stage_in]]) { VO o; o.p = float4(i.pos, 0.5, 1); o.c = i.col; o.ps = 1; return o; }\n"
	"vertex VO inst(uint v [[vertex_id]], uint ii [[instance_id]], device const float2* pos [[buffer(0)]]) {\n"
	"  VO o; float2 p = pos[v]; p.x += ii * 0.5; o.p = float4(p, 0.5, 1); o.c = float4(ii / 4.0, v / 8.0, 1, 1); o.ps = 1; return o; }\n"
	"vertex VO pts(uint v [[vertex_id]]) { VO o; o.p = float4(-0.75 + (v % 4) * 0.5, -0.75 + (v / 4) * 0.5, 0.5, 1);\n"
	"  o.c = float4(1, 1, 0, 1); o.ps = 4; return o; }\n"
	"struct MRT { float4 a [[color(0)]]; float4 b [[color(1)]]; float4 c [[color(2)]]; float4 d [[color(3)]]; };\n"
	"fragment MRT mrt(VO i [[stage_in]]) { MRT o; o.a = float4(1,0,0,1); o.b = float4(0,1,0,1); o.c = float4(0,0,1,1); o.d = float4(1,1,1,1); return o; }\n"
	// depth from a constant: a quad at depth z
	"vertex VO quadz(uint v [[vertex_id]], constant float4& c [[buffer(0)]], constant float& z [[buffer(1)]]) {\n"
	"  float2 p = float2((v & 1) ? 1.0 : -1.0, (v & 2) ? 1.0 : -1.0); VO o; o.p = float4(p, z, 1); o.c = c; o.ps = 1; return o; }\n"
	// layered: the layer from the instance
	"struct VL { float4 p [[position]]; float4 c; uint layer [[render_target_array_index]]; };\n"
	"vertex VL layered(uint v [[vertex_id]], uint ii [[instance_id]]) {\n"
	"  float2 p = float2((v & 1) ? 1.0 : -1.0, (v & 2) ? 1.0 : -1.0); VL o; o.p = float4(p, 0.5, 1);\n"
	"  o.c = float4(ii == 0, ii == 1, ii == 2, 1); o.layer = ii; return o; }\n"
	"fragment float4 lcolor(VL i [[stage_in]]) { return i.c; }\n"
	// programmable blending: read the attachment
	"fragment float4 fetch(VO i [[stage_in]], float4 dst [[color(0)]]) { return float4(1.0 - dst.r, dst.g * 0.5, dst.b, 1); }\n"
	// viewport index
	"struct VV { float4 p [[position]]; float4 c; uint vp [[viewport_array_index]]; };\n"
	"vertex VV vports(uint v [[vertex_id]], uint ii [[instance_id]]) {\n"
	"  float2 p = float2((v & 1) ? 1.0 : -1.0, (v & 2) ? 1.0 : -1.0); VV o; o.p = float4(p, 0.5, 1); o.c = float4(ii == 0, ii == 1, 0, 1); o.vp = ii; return o; }\n"
	"fragment float4 vcolor(VV i [[stage_in]]) { return i.c; }\n";

static MTLRenderPassDescriptor* pass(id<MTLTexture> t, MTLClearColor c) {
	MTLRenderPassDescriptor* p = [MTLRenderPassDescriptor renderPassDescriptor];
	p.colorAttachments[0].texture = t;
	p.colorAttachments[0].loadAction = MTLLoadActionClear;
	p.colorAttachments[0].clearColor = c;
	p.colorAttachments[0].storeAction = MTLStoreActionStore;
	return p;
}
static id<MTLTexture> rt(id<MTLDevice> dev) {
	return mc_tex(dev, MTLPixelFormatRGBA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
}
#define RGBA(r, g, b, a) ((uint32_t)(r) | ((uint32_t)(g) << 8) | ((uint32_t)(b) << 16) | ((uint32_t)(a) << 24))

MC_TEST(render, clear, "MTLCommandBuffer renderCommandEncoderWithDescriptor:;MTLRenderPassDescriptor renderPassDescriptor;"
        "MTLRenderPassColorAttachmentDescriptor clearColor;MTLRenderPassAttachmentDescriptor loadAction;MTLRenderPassAttachmentDescriptor storeAction") {
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(1, 0.5, 0.25, 1))] endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	NSUInteger w = mc_count_wrong_rgba8(t, RGBA(255, 128, 64, 255), 1);
	MC_CHECK(w == 0, @"%lu texels wrong, (0,0) = %08x", (unsigned long)w, mc_texel_rgba8(t, 0, 0));
	return MC_PASS;
}

MC_TEST(render, draw_quad, "MTLDevice newRenderPipelineStateWithDescriptor:error:;MTLRenderCommandEncoder setRenderPipelineState:;"
        "MTLRenderCommandEncoder setVertexBytes:length:atIndex:;MTLRenderCommandEncoder drawPrimitives:vertexStart:vertexCount:") {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"color", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	id<MTLTexture> t = rt(dev);
	float c[4] = { 0, 1, 0, 1 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	[re setVertexBytes:c length:16 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	NSUInteger w = mc_count_wrong_rgba8(t, RGBA(0, 255, 0, 255), 0);
	MC_CHECK(w == 0, @"%lu of 4096 wrong", (unsigned long)w);
	return MC_PASS;
}

// vertex descriptor + 16- and 32-bit indices: two triangles of a quad, each its own colour
static NSString* indexed(id<MTLDevice> dev, MTLIndexType it, NSUInteger baseVertex, BOOL withBase) {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"vdesc"];
	d.fragmentFunction = [l newFunctionWithName:@"color"];
	d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
	vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 1;
	vd.attributes[1].format = MTLVertexFormatUChar4Normalized; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 1;
	vd.layouts[1].stride = 12;
	d.vertexDescriptor = vd;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	if (!p) return [NSString stringWithFormat:@"pipeline: %@", err];
	struct V { float x, y; uint8_t c[4]; } verts[16] = { 0 };
	struct V q[6] = { { -1, -1, { 255, 0, 0, 255 } }, { 1, -1, { 255, 0, 0, 255 } }, { -1, 1, { 255, 0, 0, 255 } },
	                  { 1, -1, { 0, 0, 255, 255 } }, { 1, 1, { 0, 0, 255, 255 } }, { -1, 1, { 0, 0, 255, 255 } } };
	memcpy(&verts[baseVertex], q, sizeof q);
	id<MTLBuffer> vb = [dev newBufferWithBytes:verts length:sizeof verts options:0];
	uint32_t i32[6] = { 0, 1, 2, 3, 4, 5 }; uint16_t i16[6] = { 0, 1, 2, 3, 4, 5 };
	if (!withBase) for (int k = 0; k < 6; k++) { i32[k] += (uint32_t)baseVertex; i16[k] += (uint16_t)baseVertex; }
	id<MTLBuffer> ib = it == MTLIndexTypeUInt32 ? [dev newBufferWithBytes:i32 length:24 options:0] : [dev newBufferWithBytes:i16 length:12 options:0];
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	[re setVertexBuffer:vb offset:0 atIndex:1];
	if (withBase)
		[re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:it indexBuffer:ib indexBufferOffset:0
		            instanceCount:1 baseVertex:baseVertex baseInstance:0];
	else
		[re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:it indexBuffer:ib indexBufferOffset:0];
	[re endEncoding];
	NSString* e = mc_run(cb);
	if (e) return e;
	uint32_t a = mc_texel_rgba8(t, 4, 60), b = mc_texel_rgba8(t, 60, 4);
	// texture y runs down: (4,60) is bottom-left (first triangle, red), (60,4) top-right (blue)
	if (a != RGBA(255, 0, 0, 255) || b != RGBA(0, 0, 255, 255)) return [NSString stringWithFormat:@"bottom-left %08x top-right %08x", a, b];
	return nil;
}
MC_TEST(render, indexed_uint16_vertex_descriptor, "MTLRenderCommandEncoder drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:;"
        "MTLRenderCommandEncoder setVertexBuffer:offset:atIndex:;MTLRenderPipelineDescriptor vertexDescriptor") {
	NSString* e = indexed(dev, MTLIndexTypeUInt16, 0, NO); MC_CHECK(!e, @"%@", e); return MC_PASS;
}
MC_TEST(render, indexed_uint32, "MTLRenderCommandEncoder drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:") {
	NSString* e = indexed(dev, MTLIndexTypeUInt32, 0, NO); MC_CHECK(!e, @"%@", e); return MC_PASS;
}
MC_TEST(render, base_vertex, "MTLRenderCommandEncoder drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple3] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSString* e = indexed(dev, MTLIndexTypeUInt16, 7, YES); MC_CHECK(!e, @"%@", e); return MC_PASS;
}

static NSString* instanced(id<MTLDevice> dev, NSUInteger baseInstance, BOOL indirect) {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"inst", @"color", MTLPixelFormatRGBA8Unorm, &err);
	if (!p) return err.localizedDescription;
	float pos[6] = { -1, -1, -0.5f, -1, -1, 1 };  // a thin triangle at the left; instance i moves it 0.5 right
	id<MTLBuffer> pb = [dev newBufferWithBytes:pos length:sizeof pos options:0];
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	[re setVertexBuffer:pb offset:0 atIndex:0];
	if (indirect) {
		MTLDrawPrimitivesIndirectArguments a = { 3, 2, 0, (uint32_t)baseInstance };
		id<MTLBuffer> ib = mc_buf(dev, 64);
		memcpy((uint8_t*)ib.contents + 16, &a, sizeof a);
		[re drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:ib indirectBufferOffset:16];
	} else {
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:2 baseInstance:baseInstance];
	}
	[re endEncoding];
	NSString* e = mc_run(cb);
	if (e) return e;
	// instance k covers x in [-1 + 0.5k, -0.5 + 0.5k]; at y near the bottom: pixels 8k + 1
	NSMutableString* bad = [NSMutableString string];
	for (NSUInteger k = baseInstance; k < baseInstance + 2; k++) {
		uint32_t v = mc_texel_rgba8(t, 16 * k + 1, 62);
		int r = v & 0xff;
		if (abs(r - (int)(k * 255 / 4)) > 2) [bad appendFormat:@"instance %lu: %08x ", (unsigned long)k, v];
	}
	return bad.length ? bad : nil;
}
MC_TEST(render, instanced, "MTLRenderCommandEncoder drawPrimitives:vertexStart:vertexCount:instanceCount:") {
	NSString* e = instanced(dev, 0, NO); MC_CHECK(!e, @"%@", e); return MC_PASS;
}
MC_TEST(render, base_instance, "MTLRenderCommandEncoder drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple3] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSString* e = instanced(dev, 1, NO); MC_CHECK(!e, @"%@", e); return MC_PASS;
}
MC_TEST(render, indirect_draw, "MTLRenderCommandEncoder drawPrimitives:indirectBuffer:indirectBufferOffset:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple3] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSString* e = instanced(dev, 1, YES); MC_CHECK(!e, @"%@", e); return MC_PASS;
}

MC_TEST(render, indirect_indexed_draw, "MTLRenderCommandEncoder drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple3] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"color", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	uint16_t idx[4] = { 0, 1, 2, 3 };
	id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:8 options:0];
	MTLDrawIndexedPrimitivesIndirectArguments a = { 4, 1, 0, 0, 0 };
	id<MTLBuffer> ab = [dev newBufferWithBytes:&a length:sizeof a options:0];
	id<MTLTexture> t = rt(dev);
	float c[4] = { 1, 1, 0, 1 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	[re setVertexBytes:c length:16 atIndex:0];
	[re drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0
	           indirectBuffer:ab indirectBufferOffset:0];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	NSUInteger w = mc_count_wrong_rgba8(t, RGBA(255, 255, 0, 255), 0);
	MC_CHECK(w == 0, @"%lu wrong", (unsigned long)w);
	return MC_PASS;
}

MC_TEST(render, primitive_points_lines, "MTLRenderCommandEncoder drawPrimitives:vertexStart:vertexCount:") {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"pts", @"color", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	[re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:16];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	// 16 points of size 4 at ndc (-0.75 + 0.5i): pixel centres 8 + 16i
	NSUInteger lit = 4096 - mc_count_wrong_rgba8(t, RGBA(255, 255, 0, 255), 0);
	MC_CHECK(lit == 16 * 16, @"%lu texels lit, want 256 (16 points of 4x4)", (unsigned long)lit);
	MC_CHECK(mc_texel_rgba8(t, 8, 8) == RGBA(255, 255, 0, 255), @"point centre (8,8) = %08x", mc_texel_rgba8(t, 8, 8));
	return MC_PASS;
}

MC_TEST(render, scissor_viewport, "MTLRenderCommandEncoder setScissorRect:;MTLRenderCommandEncoder setViewport:") {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"color", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	id<MTLTexture> t = rt(dev);
	float c[4] = { 1, 0, 0, 1 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	[re setVertexBytes:c length:16 atIndex:0];
	[re setViewport:(MTLViewport){ 0, 0, 32, 64, 0, 1 }];          // left half
	[re setScissorRect:(MTLScissorRect){ 8, 16, 32, 32 }];         // x 8..39, y 16..47 -> lit: x 8..31, y 16..47
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	NSUInteger lit = 4096 - mc_count_wrong_rgba8(t, RGBA(255, 0, 0, 255), 0);
	MC_CHECK(lit == 24 * 32, @"%lu lit, want %d", (unsigned long)lit, 24 * 32);
	MC_CHECK(mc_texel_rgba8(t, 40, 20) == RGBA(0, 0, 0, 255) && mc_texel_rgba8(t, 10, 20) == RGBA(255, 0, 0, 255), @"edges");
	return MC_PASS;
}

MC_TEST(render, multiple_viewports, "MTLRenderCommandEncoder setViewports:count:;MTLRenderCommandEncoder setScissorRects:count:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple5] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vports", @"vcolor", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p];
	MTLViewport vp[2] = { { 0, 0, 32, 64, 0, 1 }, { 32, 0, 32, 64, 0, 1 } };
	MTLScissorRect sr[2] = { { 0, 0, 64, 64 }, { 0, 0, 64, 64 } };
	[re setViewports:vp count:2];
	[re setScissorRects:sr count:2];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:2];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t l = mc_texel_rgba8(t, 10, 30), r = mc_texel_rgba8(t, 50, 30);
	MC_CHECK(l == RGBA(255, 0, 0, 255) && r == RGBA(0, 255, 0, 255), @"left %08x right %08x", l, r);
	return MC_PASS;
}

static NSString* blend_test(id<MTLDevice> dev, MTLPixelFormat f, NSUInteger bpp) {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"vquad"];
	d.fragmentFunction = [l newFunctionWithName:@"color"];
	d.colorAttachments[0].pixelFormat = f;
	d.colorAttachments[0].blendingEnabled = YES;
	d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	if (!p) return [NSString stringWithFormat:@"pipeline: %@", err.localizedDescription];
	id<MTLTexture> t = mc_tex(dev, f, 16, 16, MTLTextureUsageRenderTarget);
	float c[4] = { 1, 0, 0, 0.25f };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 1, 1))];
	[re setRenderPipelineState:p];
	[re setVertexBytes:c length:16 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	if (e) return e;
	uint8_t px[16] = { 0 };
	[t getBytes:px bytesPerRow:16 * bpp fromRegion:MTLRegionMake2D(5, 5, 1, 1) mipmapLevel:0];
	float r, b;
	if (bpp == 4) { r = px[0] / 255.f; b = px[2] / 255.f; }
	else if (bpp == 8) { __fp16* h = (__fp16*)px; r = h[0]; b = h[2]; }
	else { float* ff = (float*)px; r = ff[0]; b = ff[2]; }
	if (fabsf(r - 0.25f) > 0.01f || fabsf(b - 0.75f) > 0.01f) return [NSString stringWithFormat:@"r %f b %f, want 0.25 0.75", r, b];
	return nil;
}
MC_TEST(render, blend_rgba8, "MTLRenderPipelineColorAttachmentDescriptor blendingEnabled;MTLRenderPipelineColorAttachmentDescriptor sourceRGBBlendFactor;"
        "MTLRenderPipelineColorAttachmentDescriptor destinationRGBBlendFactor;MTLRenderPipelineColorAttachmentDescriptor rgbBlendOperation") {
	NSString* e = blend_test(dev, MTLPixelFormatRGBA8Unorm, 4); MC_CHECK(!e, @"%@", e); return MC_PASS;
}
MC_TEST(render, blend_rgba16float, "MTLRenderPipelineColorAttachmentDescriptor blendingEnabled") {
	NSString* e = blend_test(dev, MTLPixelFormatRGBA16Float, 8); MC_CHECK(!e, @"%@", e); return MC_PASS;
}
// Vulkan's hdr example blends into RGBA32Float: Apple7+ (A14) GPUs blend 32-bit float formats
MC_TEST(render, blend_rgba32float, "MTLRenderPipelineColorAttachmentDescriptor blendingEnabled") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple7] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSString* e = blend_test(dev, MTLPixelFormatRGBA32Float, 16); MC_CHECK(!e, @"%@", e); return MC_PASS;
}

MC_TEST(render, msaa_resolve, "MTLRenderPipelineDescriptor rasterSampleCount;MTLRenderPassAttachmentDescriptor resolveTexture;"
        "MTLStoreActionMultisampleResolve") {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"inst"];
	d.fragmentFunction = [l newFunctionWithName:@"color"];
	d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	d.rasterSampleCount = 4;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	MC_NOTNIL(p, err);
	MTLTextureDescriptor* md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
	md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.storageMode = MTLStorageModePrivate; md.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> ms = [dev newTextureWithDescriptor:md];
	id<MTLTexture> t = rt(dev);
	float pos[6] = { -1, -1, 1, -1, -1, 1 };  // lower-left half: the diagonal is an edge
	id<MTLBuffer> pb = [dev newBufferWithBytes:pos length:sizeof pos options:0];
	MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = ms;
	rp.colorAttachments[0].resolveTexture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
	[re setRenderPipelineState:p];
	[re setVertexBuffer:pb offset:0 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	// inside: blue 255; outside: 0; on the diagonal some texel holds a blend
	int partial = 0;
	for (int i = 0; i < 64; i++) { int b = (mc_texel_rgba8(t, i, i) >> 16) & 0xff; if (b > 20 && b < 235) partial++; }
	uint32_t in = mc_texel_rgba8(t, 5, 58), out = mc_texel_rgba8(t, 58, 5);
	MC_CHECK(((in >> 16) & 0xff) == 255 && ((out >> 16) & 0xff) == 0, @"inside %08x outside %08x", in, out);
	MC_CHECK(partial > 16, @"only %d edge texels are blends: no multisampling", partial);
	return MC_PASS;
}

MC_TEST(render, depth_test, "MTLDevice newDepthStencilStateWithDescriptor:;MTLRenderCommandEncoder setDepthStencilState:;"
        "MTLRenderPassDescriptor depthAttachment;MTLRenderPassDepthAttachmentDescriptor clearDepth;MTLDepthStencilDescriptor depthCompareFunction;"
        "MTLDepthStencilDescriptor depthWriteEnabled") {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"quadz"];
	d.fragmentFunction = [l newFunctionWithName:@"color"];
	d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	MC_NOTNIL(p, err);
	MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
	dd.depthCompareFunction = MTLCompareFunctionLess; dd.depthWriteEnabled = YES;
	id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
	MTLTextureDescriptor* zd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
	zd.storageMode = MTLStorageModePrivate; zd.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> z = [dev newTextureWithDescriptor:zd], t = rt(dev);
	MTLRenderPassDescriptor* rp = pass(t, MTLClearColorMake(0, 0, 0, 1));
	rp.depthAttachment.texture = z; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.loadAction = MTLLoadActionClear;
	rp.depthAttachment.storeAction = MTLStoreActionDontCare;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
	[re setRenderPipelineState:p];
	[re setDepthStencilState:ds];
	float red[4] = { 1, 0, 0, 1 }, green[4] = { 0, 1, 0, 1 }, z1 = 0.3f, z2 = 0.6f;
	[re setVertexBytes:red length:16 atIndex:0]; [re setVertexBytes:&z1 length:4 atIndex:1];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re setVertexBytes:green length:16 atIndex:0]; [re setVertexBytes:&z2 length:4 atIndex:1];  // behind: rejected
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	NSUInteger w = mc_count_wrong_rgba8(t, RGBA(255, 0, 0, 255), 0);
	MC_CHECK(w == 0, @"%lu texels not red: the farther quad passed the depth test", (unsigned long)w);
	return MC_PASS;
}

MC_TEST(render, stencil, "MTLDepthStencilDescriptor frontFaceStencil;MTLStencilDescriptor stencilCompareFunction;MTLStencilDescriptor depthStencilPassOperation;"
        "MTLRenderCommandEncoder setStencilReferenceValue:;MTLRenderPassDescriptor stencilAttachment") {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"vquad"];
	d.fragmentFunction = [l newFunctionWithName:@"color"];
	d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	d.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	MC_NOTNIL(p, err);
	MTLStencilDescriptor* write = [MTLStencilDescriptor new];
	write.stencilCompareFunction = MTLCompareFunctionAlways; write.depthStencilPassOperation = MTLStencilOperationReplace;
	MTLStencilDescriptor* test = [MTLStencilDescriptor new];
	test.stencilCompareFunction = MTLCompareFunctionEqual;
	MTLDepthStencilDescriptor *dw = [MTLDepthStencilDescriptor new], *dt = [MTLDepthStencilDescriptor new];
	dw.frontFaceStencil = dw.backFaceStencil = write;
	dt.frontFaceStencil = dt.backFaceStencil = test;
	id<MTLDepthStencilState> sw = [dev newDepthStencilStateWithDescriptor:dw], st = [dev newDepthStencilStateWithDescriptor:dt];
	MTLTextureDescriptor* sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:64 height:64 mipmapped:NO];
	sd.storageMode = MTLStorageModePrivate; sd.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> s = [dev newTextureWithDescriptor:sd], t = rt(dev);
	MTLRenderPassDescriptor* rp = pass(t, MTLClearColorMake(0, 0, 0, 1));
	rp.stencilAttachment.texture = s; rp.stencilAttachment.clearStencil = 0; rp.stencilAttachment.loadAction = MTLLoadActionClear;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
	[re setRenderPipelineState:p];
	float black[4] = { 0, 0, 0, 1 }, white[4] = { 1, 1, 1, 1 };
	// write 7 into the left half only
	[re setDepthStencilState:sw]; [re setStencilReferenceValue:7];
	[re setScissorRect:(MTLScissorRect){ 0, 0, 32, 64 }];
	[re setVertexBytes:black length:16 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	// draw white everywhere where stencil == 7
	[re setDepthStencilState:st];
	[re setScissorRect:(MTLScissorRect){ 0, 0, 64, 64 }];
	[re setVertexBytes:white length:16 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t l1 = mc_texel_rgba8(t, 10, 10), r1 = mc_texel_rgba8(t, 50, 10);
	MC_CHECK(l1 == 0xffffffff && r1 == RGBA(0, 0, 0, 255), @"left %08x right %08x", l1, r1);
	return MC_PASS;
}

MC_TEST(render, multiple_render_targets, "MTLRenderPassDescriptor colorAttachments;MTLRenderPipelineDescriptor colorAttachments") {
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"vquad"];
	d.fragmentFunction = [l newFunctionWithName:@"mrt"];
	for (int i = 0; i < 4; i++) d.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA8Unorm;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	MC_NOTNIL(p, err);
	MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
	id<MTLTexture> ts[4];
	for (int i = 0; i < 4; i++) {
		ts[i] = mc_tex(dev, MTLPixelFormatRGBA8Unorm, 16, 16, MTLTextureUsageRenderTarget);
		rp.colorAttachments[i].texture = ts[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear;
		rp.colorAttachments[i].storeAction = MTLStoreActionStore;
	}
	float c[4] = { 0 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
	[re setRenderPipelineState:p]; [re setVertexBytes:c length:16 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t want[4] = { RGBA(255, 0, 0, 255), RGBA(0, 255, 0, 255), RGBA(0, 0, 255, 255), 0xffffffff };
	for (int i = 0; i < 4; i++) MC_CHECK(mc_count_wrong_rgba8(ts[i], want[i], 0) == 0, @"target %d: %08x", i, mc_texel_rgba8(ts[i], 3, 3));
	return MC_PASS;
}

MC_TEST(render, layered_rendering, "MTLRenderPassDescriptor renderTargetArrayLength;MTLRenderPipelineDescriptor inputPrimitiveTopology") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple5] || [dev supportsFamily:MTLGPUFamilyMac2]);
	NSError* err = nil;
	id<MTLLibrary> l = mc_lib(dev, SRC, &err);
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"layered"];
	d.fragmentFunction = [l newFunctionWithName:@"lcolor"];
	d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
	MC_NOTNIL(p, err);
	MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
	td.textureType = MTLTextureType2DArray; td.arrayLength = 3; td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> t = [dev newTextureWithDescriptor:td];
	MTLRenderPassDescriptor* rp = pass(t, MTLClearColorMake(0, 0, 0, 1));
	rp.renderTargetArrayLength = 3;
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
	[re setRenderPipelineState:p];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:3];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t want[3] = { RGBA(255, 0, 0, 255), RGBA(0, 255, 0, 255), RGBA(0, 0, 255, 255) };
	for (NSUInteger s = 0; s < 3; s++) {
		uint32_t v = 0;
		[t getBytes:&v bytesPerRow:4 bytesPerImage:4 fromRegion:MTLRegionMake2D(5, 5, 1, 1) mipmapLevel:0 slice:s];
		MC_CHECK(v == want[s], @"layer %lu = %08x", (unsigned long)s, v);
	}
	return MC_PASS;
}

MC_TEST(render, programmable_blending, "MTLRenderCommandEncoder drawPrimitives:vertexStart:vertexCount:") {
	MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple1]);
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"fetch", MTLPixelFormatRGBA8Unorm, &err);
	MC_CLIENT_CHECK(p, @"%@", err.localizedDescription);
	id<MTLTexture> t = rt(dev);
	float c[4] = { 0 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0.25, 1, 0.5, 1))];
	[re setRenderPipelineState:p]; [re setVertexBytes:c length:16 atIndex:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t v = mc_texel_rgba8(t, 7, 7);
	MC_CHECK(abs((int)(v & 0xff) - 191) <= 1 && abs((int)((v >> 8) & 0xff) - 128) <= 1 && abs((int)((v >> 16) & 0xff) - 128) <= 1,
		@"%08x, want (191,128,128)", v);
	return MC_PASS;
}

static NSString* ff_draw(id<MTLDevice> dev, void (^state)(id<MTLRenderCommandEncoder>), NSUInteger vstart, id<MTLTexture>* out) {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"color", MTLPixelFormatRGBA8Unorm, &err);
	if (!p) return err.localizedDescription;
	id<MTLTexture> t = rt(dev);
	float c[4] = { 1, 1, 1, 1 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	[re setRenderPipelineState:p]; [re setVertexBytes:c length:16 atIndex:0];
	state(re);
	[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:vstart vertexCount:3];
	[re endEncoding];
	*out = t;
	return mc_run(cb);
}
// vertices 0,1,2 = (-1,-1) (1,-1) (-1,1): counter-clockwise in normalized device coordinates (y up)
MC_TEST(render, cull_mode_winding, "MTLRenderCommandEncoder setCullMode:;MTLRenderCommandEncoder setFrontFacingWinding:") {
	id<MTLTexture> t = nil;
	NSString* e = ff_draw(dev, ^(id<MTLRenderCommandEncoder> re) {
		[re setFrontFacingWinding:MTLWindingCounterClockwise]; [re setCullMode:MTLCullModeFront]; }, 0, &t);
	MC_CHECK(!e, @"%@", e);
	NSUInteger lit = mc_count_wrong_rgba8(t, RGBA(0, 0, 0, 255), 0);  // texels not left black
	MC_CHECK(lit == 0, @"%lu texels lit: a CCW triangle drawn with CCW front and front culling", (unsigned long)lit);
	e = ff_draw(dev, ^(id<MTLRenderCommandEncoder> re) {
		[re setFrontFacingWinding:MTLWindingClockwise]; [re setCullMode:MTLCullModeFront]; }, 0, &t);
	MC_CHECK(!e, @"%@", e);
	lit = mc_count_wrong_rgba8(t, RGBA(0, 0, 0, 255), 0);
	MC_CHECK(lit > 1900, @"%lu texels lit: with CW front the CCW triangle is a back face and stays", (unsigned long)lit);
	return MC_PASS;
}
MC_TEST(render, fill_mode_lines, "MTLRenderCommandEncoder setTriangleFillMode:") {
	id<MTLTexture> t = nil;
	NSString* e = ff_draw(dev, ^(id<MTLRenderCommandEncoder> re) { [re setTriangleFillMode:MTLTriangleFillModeLines]; }, 0, &t);
	MC_CHECK(!e, @"%@", e);
	NSUInteger lit = mc_count_wrong_rgba8(t, RGBA(0, 0, 0, 255), 0);
	MC_CHECK(lit > 60 && lit < 400, @"%lu texels lit: want only the triangle's outline", (unsigned long)lit);
	return MC_PASS;
}
MC_TEST(render, depth_bias_clip_blend_color, "MTLRenderCommandEncoder setDepthBias:slopeScale:clamp:;MTLRenderCommandEncoder setDepthClipMode:;"
        "MTLRenderCommandEncoder setBlendColorRed:green:blue:alpha:") {
	id<MTLTexture> t = nil;
	NSString* e = ff_draw(dev, ^(id<MTLRenderCommandEncoder> re) {
		[re setDepthBias:0 slopeScale:0 clamp:0]; [re setDepthClipMode:MTLDepthClipModeClamp]; [re setBlendColorRed:0 green:0 blue:0 alpha:0]; }, 0, &t);
	MC_CHECK(!e, @"%@", e);
	return MC_PASS;
}

MC_TEST(render, occlusion_query, "MTLRenderPassDescriptor visibilityResultBuffer;MTLRenderCommandEncoder setVisibilityResultMode:offset:") {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"color", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> vis = mc_buf(dev, 32);
	memset(vis.contents, 0xcc, 32);
	id<MTLTexture> t = rt(dev);
	MTLRenderPassDescriptor* rp = pass(t, MTLClearColorMake(0, 0, 0, 1));
	rp.visibilityResultBuffer = vis;
	float c[4] = { 1, 1, 1, 1 };
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
	[re setRenderPipelineState:p]; [re setVertexBytes:c length:16 atIndex:0];
	[re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];  // 4096 samples
	[re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:8];
	[re setScissorRect:(MTLScissorRect){ 0, 0, 10, 10 }];
	[re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];  // 100 samples
	[re setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:16];
	[re setScissorRect:(MTLScissorRect){ 0, 0, 1, 1 }];
	[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:0];       // nothing
	[re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
	[re endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint64_t* v = vis.contents;
	MC_CHECK(v[0] == 4096 && v[1] == 100 && v[2] == 0, @"counts %llu %llu %llu, want 4096 100 0", v[0], v[1], v[2]);
	return MC_PASS;
}

MC_TEST(render, parallel_encoder, "MTLCommandBuffer parallelRenderCommandEncoderWithDescriptor:;MTLParallelRenderCommandEncoder renderCommandEncoder") {
	NSError* err = nil;
	id<MTLRenderPipelineState> p = mc_rps(dev, SRC, @"vquad", @"color", MTLPixelFormatRGBA8Unorm, &err);
	MC_NOTNIL(p, err);
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLParallelRenderCommandEncoder> pe = [cb parallelRenderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 0, 1))];
	MC_NOTNIL(pe, nil);
	float red[4] = { 1, 0, 0, 1 }, blue[4] = { 0, 0, 1, 1 };
	id<MTLRenderCommandEncoder> a = [pe renderCommandEncoder], b = [pe renderCommandEncoder];
	[a setRenderPipelineState:p]; [a setVertexBytes:red length:16 atIndex:0];
	[a setScissorRect:(MTLScissorRect){ 0, 0, 32, 64 }];
	[a drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[b setRenderPipelineState:p]; [b setVertexBytes:blue length:16 atIndex:0];
	[b setScissorRect:(MTLScissorRect){ 32, 0, 32, 64 }];
	[b drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[a endEncoding]; [b endEncoding]; [pe endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(mc_texel_rgba8(t, 5, 5) == RGBA(255, 0, 0, 255) && mc_texel_rgba8(t, 60, 5) == RGBA(0, 0, 255, 255),
		@"left %08x right %08x", mc_texel_rgba8(t, 5, 5), mc_texel_rgba8(t, 60, 5));
	return MC_PASS;
}

MC_TEST(render, load_store_actions, "MTLRenderPassAttachmentDescriptor loadAction;MTLLoadActionLoad;MTLStoreActionDontCare") {
	id<MTLTexture> t = rt(dev);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:pass(t, MTLClearColorMake(0, 0, 1, 1))] endEncoding];
	MTLRenderPassDescriptor* rp = pass(t, MTLClearColorMake(1, 0, 0, 1));
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;  // keeps blue
	[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	MC_CHECK(mc_count_wrong_rgba8(t, RGBA(0, 0, 255, 255), 0) == 0, @"load lost the first pass: %08x", mc_texel_rgba8(t, 1, 1));
	return MC_PASS;
}
