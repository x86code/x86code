// x86Sim MetalCoverage: one test per Metal feature, every result checked on the CPU (tests/metal/coverage/README.md).
//
// A test:
//   MC_TEST(render, indexed_uint32, "MTLRenderCommandEncoder drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:") {
//       MC_CLAIM([dev supportsFamily:MTLGPUFamilyApple3]);   // optional: what the device says (default: claimed)
//       ...                                                    // MC_CHECK(cond, fmt, ...) fails the test with a detail
//       return MC_PASS;
//   }
// The covers string lists "Owner selector" pairs, ';'-separated: what report.py counts against the SDK's inventory.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef enum { MC_PASS = 0, MC_FAIL, MC_SKIP, MC_CLIENT } MCStatus;
typedef MCStatus (*MCTestFn)(id<MTLDevice> dev, NSMutableString* detail);

void mc_register(const char* area, const char* name, const char* covers, MCTestFn fn);
// what the device claims for the running test (support it advertises); unset = claimed
void mc_claim(BOOL claimed, const char* what);

#define MC_TEST(area, name, covers)                                                                       \
	static MCStatus mc_t_##area##_##name(id<MTLDevice> dev, NSMutableString* detail);                    \
	__attribute__((constructor)) static void mc_r_##area##_##name(void) {                               \
		mc_register(#area, #name, covers, mc_t_##area##_##name);                                         \
	}                                                                                                    \
	static MCStatus mc_t_##area##_##name(id<MTLDevice> dev, NSMutableString* detail)

#define MC_CLAIM(expr) mc_claim((expr) ? YES : NO, #expr)
#define MC_FAILF(...) do { [detail appendFormat:__VA_ARGS__]; return MC_FAIL; } while (0)
#define MC_CHECK(cond, ...) do { if (!(cond)) { [detail appendFormat:@"%s: ", #cond]; MC_FAILF(__VA_ARGS__); } } while (0)
#define MC_NOTNIL(x, err) do { if (!(x)) MC_FAILF(@"%s is nil%@", #x, (err) ? [@": " stringByAppendingString:[(NSError*)(err) localizedDescription]] : @""); } while (0)
// a deviation from iOS that Apple's simulator client (MTLSimDriver, or its shader compiler) makes itself, as on a Mac:
// reported as CLIENT, not as this stack's failure
#define MC_CLIENT_CHECK(cond, ...) do { if (!(cond)) { [detail appendFormat:@"Apple simulator client: %s: ", #cond]; [detail appendFormat:__VA_ARGS__]; return MC_CLIENT; } } while (0)
#define MC_SKIPF(...) do { [detail appendFormat:__VA_ARGS__]; return MC_SKIP; } while (0)

// helpers (mtlcov.m)
id<MTLLibrary> mc_lib(id<MTLDevice> dev, NSString* src, NSError** err);        // newLibraryWithSource, cached by source
id<MTLComputePipelineState> mc_cps(id<MTLDevice> dev, NSString* src, NSString* fn, NSError** err);
id<MTLCommandQueue> mc_queue(id<MTLDevice> dev);                                // one queue, made once
// commit and wait (at most 10 s): nil when it completed, else what went wrong
NSString* mc_run(id<MTLCommandBuffer> cb);
id<MTLBuffer> mc_buf(id<MTLDevice> dev, NSUInteger len);                        // shared, zeroed
// a shared 2D texture (readable with getBytes)
id<MTLTexture> mc_tex(id<MTLDevice> dev, MTLPixelFormat f, NSUInteger w, NSUInteger h, MTLTextureUsage u);
// render pipeline from one source with vertex `vs` and fragment `fs` (nil: none) into colour format `f`
id<MTLRenderPipelineState> mc_rps(id<MTLDevice> dev, NSString* src, NSString* vs, NSString* fs, MTLPixelFormat f, NSError** err);
// how many 32-bit texels of `t` (BGRA8/RGBA8, w*h) differ from `want` by more than `tol` per channel
NSUInteger mc_count_wrong_rgba8(id<MTLTexture> t, uint32_t want, int tol);
uint32_t mc_texel_rgba8(id<MTLTexture> t, NSUInteger x, NSUInteger y);
// the shader preamble every test source starts with
#define MC_MSL @"#include <metal_stdlib>\nusing namespace metal;\n"
