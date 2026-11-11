// VKMTL wire protocol: metalhostd (Darling, our MTLDevice classes) <-> mtlvk (native Linux, Vulkan).
// One AF_UNIX stream connection per metalhostd process. All integers little-endian, fields naturally
// aligned, no padding beyond what is written here. mtlvk/src/proto.rs mirrors this file.
//
// Every message: vkmtl_hdr + `size` payload bytes. Requests that expect a reply carry a nonzero seq;
// the reply has op | VKMTL_REPLY and the same seq. Messages without reply are processed in order, so a
// later request observes earlier ones. mtlvk also sends unsolicited events (seq 0): VKMTL_EV_*.
// File descriptors (memfds of buffer memory) travel as SCM_RIGHTS on the sendmsg of their message.
#ifndef VKMTL_PROTO_H
#define VKMTL_PROTO_H
#include <stdint.h>

#define VKMTL_SOCKET_DEFAULT "/tmp/x86sim-mtlvk.sock"
#define VKMTL_VERSION 1

typedef struct { uint32_t op, size; uint64_t seq; } vkmtl_hdr;

enum {
	VKMTL_REPLY = 0x80000000u,

	// {u32 version, u32 pid} -> {u64 registryID, u64 recommendedMaxWorkingSetSize, u64 maxBufferLength,
	//  u32 hasUnifiedMemory, u32 nameLen, char name[nameLen]}
	VKMTL_HELLO = 1,
	// {u64 id, u64 length, u64 options, u64 fdOffset, u32 hasFd, u32 shared} + fd -> {i32 status, u32 copied, u64 gpuAddress}
	// hasFd=0: mtlvk allocates. shared=0: the fd is a snapshot (contents copied from the fd once).
	// copied=1 in the reply: mtlvk could not import the pages and keeps its own copy (see BUF_WRITE/READ).
	VKMTL_BUF_NEW = 2,
	// {u64 id}  (any object)
	VKMTL_OBJ_DEL = 3,
	// {u64 id, vkmtl_texdesc} -> {i32 status, u32 pad, u64 allocatedSize}
	VKMTL_TEX_NEW = 4,
	// {u64 id, vkmtl_region, u32 level, u32 slice, u64 bytesPerRow, u64 bytesPerImage, u64 dataLen, data}
	VKMTL_TEX_REPLACE = 5,
	// {u64 id, vkmtl_region, u32 level, u32 slice, u64 bytesPerRow, u64 bytesPerImage, u64 dataLen}
	//   -> {i32 status, u32 pad, u64 dataLen, data}
	VKMTL_TEX_GETBYTES = 6,
	// {u64 id}
	VKMTL_QUEUE_NEW = 7,
	// {u64 queue, u64 cb, u32 count, u32 pad, commands...}; async VKMTL_EV_CB_DONE when it completes
	VKMTL_CB_COMMIT = 8,
	// {u64 id, u32 shared, u32 pad}
	VKMTL_EVENT_NEW = 9,
	// {u64 id, u64 value}
	VKMTL_EVENT_SET = 10,
	// {u64 id} -> {u64 value}
	VKMTL_EVENT_GET = 11,
	// copy fallback for buffers mtlvk could not import: {u64 id, u64 offset, u64 len, data}
	VKMTL_BUF_WRITE = 12,
	// {u64 id, u64 offset, u64 len} -> {i32 status, u32 pad, data[len]}
	VKMTL_BUF_READ = 13,
	// {} -> {}  (a barrier: everything sent before has been processed)
	VKMTL_SYNC = 14,
	// stage 4 (compute). Errors come back as {u32 len, char text[len]} at the end of the reply.
	// {u64 id, u64 len, metallib[len]} -> {i32 status, u32 count, count x {u32 functionType, u32 nameLen, name}, err}
	VKMTL_LIB_NEW = 15,
	// {u64 id, u64 library, u32 nameLen, u32 nconst, name, nconst x vkmtl_fconst + bytes} -> {i32 status, u32 functionType, err}
	VKMTL_FUNC_NEW = 16,
	// {u64 id, u64 function, u32 maxTotalThreadsPerThreadgroup, u32 tgSizeIsMultipleOfTEW}
	//   -> {i32 status, u32 threadExecutionWidth, u32 maxTotalThreadsPerThreadgroup, u32 staticThreadgroupMemoryLength, err}
	VKMTL_CPS_NEW = 17,
	// {u64 id, vkmtl_samplerdesc} -> {i32 status, u32 pad, u64 gpuResourceID}
	VKMTL_SAMPLER_NEW = 18,
	// stage 5 (render).
	// {u64 id, vkmtl_rpsdesc, nlayouts x vkmtl_vlayout, nattrs x vkmtl_vattr} -> {i32 status, u32 pad, err}
	VKMTL_RPS_NEW = 19,
	// {u64 id, vkmtl_dssdesc} -> {i32 status, u32 pad}
	VKMTL_DSS_NEW = 20,
	// a texture over a buffer's bytes (IOSurface plane, or newTextureWithDescriptor:offset:bytesPerRow:):
	// {u64 id, u64 buffer, vkmtl_texdesc, u64 offset, u64 bytesPerRow, u32 iosurface, u32 planar} -> as TEX_NEW
	VKMTL_TEX_NEW_BUF = 21,
	// x86Sim: a texture view: {u64 id, u64 parent, u32 pixelFormat, u32 textureType, u64 levelStart, u64 levelCount,
	//  u64 sliceStart, u64 sliceCount, u32 hasSwizzle, u32 swizzle (r,g,b,a bytes)} -> {i32 status, u32 pad, u64 0}
	VKMTL_TEX_VIEW = 22,

	// async from mtlvk: {u64 cb, u32 status (MTLCommandBufferStatus), u32 error (MTLCommandBufferError),
	//  double gpuStart, double gpuEnd}
	VKMTL_EV_CB_DONE = 100,
	// async from mtlvk: {u64 event, u64 value}  (a shared event's value changed on the GPU)
	VKMTL_EV_EVENT = 101,
};

typedef struct {
	uint32_t textureType, pixelFormat;   // MTLTextureType, MTLPixelFormat
	uint64_t width, height, depth;
	uint32_t mipmapLevelCount, sampleCount;
	uint64_t arrayLength;
	uint64_t resourceOptions;            // MTLResourceOptions (cpu cache | storage | hazard)
	uint64_t usage;                      // MTLTextureUsage
	uint32_t swizzle;                    // MTLTextureSwizzleChannels packed r,g,b,a bytes
	uint32_t allowGPUOptimizedContents;
} vkmtl_texdesc;

typedef struct { uint64_t x, y, z, w, h, d; } vkmtl_region;

// Commands of VKMTL_CB_COMMIT: {u32 kind, u32 size} + size bytes.
enum {
	// {u64 src, u64 srcOffset, u64 dst, u64 dstOffset, u64 size}
	VKMTL_C_COPY_BB = 1,
	// {u64 src, u64 srcOffset, u64 bytesPerRow, u64 bytesPerImage, u64 w, h, d, u64 dst, u32 slice, u32 level,
	//  u64 x, y, z, u64 options}
	VKMTL_C_COPY_BT = 2,
	// {u64 src, u32 slice, u32 level, u64 x, y, z, u64 w, h, d, u64 dst, u64 dstOffset, u64 bytesPerRow,
	//  u64 bytesPerImage, u64 options}
	VKMTL_C_COPY_TB = 3,
	// {u64 src, u32 slice, u32 level, u64 x, y, z, u64 w, h, d, u64 dst, u32 slice, u32 level, u64 x, y, z}
	VKMTL_C_COPY_TT = 4,
	// {u64 buffer, u64 start, u64 length, u32 value, u32 pad}
	VKMTL_C_FILL = 5,
	// {u64 texture}
	VKMTL_C_MIPMAPS = 6,
	// vkmtl_pass: begins a render encoder (ended by VKMTL_C_RE_END or any non-render command)
	VKMTL_C_RENDER_PASS = 7,
	// {u64 event, u64 value}
	VKMTL_C_SIGNAL = 8,
	VKMTL_C_WAIT = 9,
	// compute encoder: BEGIN, state and dispatches, END (stage 4)
	VKMTL_C_CS_BEGIN = 10,      // {u32 dispatchType, u32 pad}
	VKMTL_C_CS_PIPELINE = 11,   // {u64 pipelineState}
	VKMTL_C_CS_BUFFER = 12,     // {u64 buffer (0: unbind), u64 offset, u32 index, u32 pad}
	VKMTL_C_CS_BYTES = 13,      // {u32 index, u32 len, bytes[len]}
	VKMTL_C_CS_TEXTURE = 14,    // {u64 texture (0: unbind), u32 index, u32 pad}
	VKMTL_C_CS_SAMPLER = 15,    // {u64 sampler (0: unbind), u32 index, u32 hasLod, f32 lodMin, f32 lodMax}
	VKMTL_C_CS_TGMEM = 16,      // {u32 length, u32 index}
	VKMTL_C_CS_DISPATCH = 17,   // {u32 kind (0 dispatchThreads, 1 dispatchThreadgroups), u32 pad, u64 grid[3], u64 group[3]}
	VKMTL_C_CS_BARRIER = 18,    // {u64 scope (MTLBarrierScope)}
	VKMTL_C_CS_USE = 19,        // {u64 resource, u32 usage (MTLResourceUsage), u32 isTexture}
	VKMTL_C_CS_END = 20,        // {}
	VKMTL_C_CS_BUFFER_OFFSET = 21, // {u64 offset, u32 index, u32 pad}
	// render encoder (stage 5): VKMTL_C_RENDER_PASS begins it, then state and draws, then RE_END
	// (stage: 0 vertex, 1 fragment)
	VKMTL_C_RE_PIPELINE = 30,   // {u64 renderPipelineState}
	VKMTL_C_RE_BUFFER = 31,     // {u64 buffer (0: unbind), u64 offset, u32 stage, u32 index}
	VKMTL_C_RE_BYTES = 32,      // {u32 stage, u32 index, u32 len, u32 pad, bytes[len]}
	VKMTL_C_RE_TEXTURE = 33,    // {u64 texture (0: unbind), u32 stage, u32 index}
	VKMTL_C_RE_SAMPLER = 34,    // {u64 sampler (0: unbind), u32 stage, u32 index, u32 hasLod, f32 lodMin, f32 lodMax, u32 pad}
	VKMTL_C_RE_BUFFER_OFFSET = 35, // {u64 offset, u32 stage, u32 index}
	VKMTL_C_RE_VIEWPORT = 36,   // {f64 x, y, w, h, znear, zfar}
	VKMTL_C_RE_SCISSOR = 37,    // {u64 x, y, w, h}
	VKMTL_C_RE_CULL = 38,       // {u32 MTLCullMode, u32 pad}
	VKMTL_C_RE_WINDING = 39,    // {u32 MTLWinding, u32 pad}
	VKMTL_C_RE_FILL = 40,       // {u32 MTLTriangleFillMode, u32 pad}
	VKMTL_C_RE_DEPTH_BIAS = 41, // {f32 bias, f32 slope, f32 clamp, u32 pad}
	VKMTL_C_RE_STENCIL_REF = 42, // {u32 front, u32 back}
	VKMTL_C_RE_BLEND_COLOR = 43, // {f32 r, g, b, a}
	VKMTL_C_RE_DSS = 44,        // {u64 depthStencilState (0: default)}
	VKMTL_C_RE_DEPTH_CLIP = 45, // {u32 MTLDepthClipMode, u32 pad}
	VKMTL_C_RE_DRAW = 46,       // {u32 primitive, u32 vertexStart, u32 vertexCount, u32 instanceCount, u32 baseInstance, u32 pad}
	VKMTL_C_RE_DRAW_INDEXED = 47, // {u32 primitive, u32 indexCount, u32 indexType, u32 instanceCount, u64 indexBuffer,
	                              //  u64 indexOffset, i32 baseVertex, u32 baseInstance}
	VKMTL_C_RE_END = 48,        // {}  (store actions set late are already in the pass: it is sent at endEncoding)
	VKMTL_C_RE_USE = 49,        // {u64 resource, u32 usage, u32 isTexture}
	// Platforms 1 (watchOS faces): draws whose arguments a buffer holds (MTLDraw[Indexed]PrimitivesIndirectArguments)
	VKMTL_C_RE_DRAW_INDIRECT = 50, // {u32 primitive, u32 pad, u64 indirectBuffer, u64 indirectOffset}
	VKMTL_C_RE_DRAW_INDEXED_INDIRECT = 51, // {u32 primitive, u32 indexType, u64 indexBuffer, u64 indexOffset,
	                                       //  u64 indirectBuffer, u64 indirectOffset}
};

// VKMTL_RPS_NEW
typedef struct {
	uint32_t pixelFormat, blendingEnabled, srcRGB, dstRGB, rgbOp, srcAlpha, dstAlpha, alphaOp, writeMask, pad;
} vkmtl_colorattachment;
typedef struct {
	uint64_t vertexFunction, fragmentFunction;   // VKMTLFunction ids (fragment 0: none)
	vkmtl_colorattachment color[8];
	uint32_t depthFormat, stencilFormat, rasterSampleCount, alphaToCoverage, alphaToOne, rasterizationEnabled;
	uint32_t inputPrimitiveTopology, hasVertexDescriptor, nlayouts, nattrs;
} vkmtl_rpsdesc;
typedef struct { uint32_t index, stride, stepFunction, stepRate; } vkmtl_vlayout;
typedef struct { uint32_t index, format, offset, bufferIndex; } vkmtl_vattr;

// VKMTL_DSS_NEW (MTLStencilDescriptor fields; enabled=0: that face's descriptor is nil)
typedef struct { uint32_t enabled, compare, stencilFail, depthFail, depthStencilPass, readMask, writeMask, pad; } vkmtl_stencil;
typedef struct { uint32_t depthCompare, depthWrite; vkmtl_stencil front, back; } vkmtl_dssdesc;

// function constant value of VKMTL_FUNC_NEW: index (or ~0 with a name), MTLDataType, value size, name length;
// followed by the name and the value bytes.
typedef struct { uint32_t index, type, size, nameLen; } vkmtl_fconst;

typedef struct {
	uint32_t minFilter, magFilter, mipFilter, sAddress, tAddress, rAddress, borderColor, normalized;
	float lodMinClamp, lodMaxClamp;
	uint32_t lodAverage, maxAnisotropy, compareFunction, supportArgumentBuffers;
} vkmtl_samplerdesc;

#define VKMTL_MAX_COLOR 8
typedef struct {
	uint64_t texture;          // 0: none
	uint32_t level, slice, depthPlane, loadAction, storeAction, pad;
	double clear[4];           // colour; depth uses clear[0], stencil (uint) clear[1]
	uint64_t resolveTexture;   // 0: none
	uint32_t resolveLevel, resolveSlice;
} vkmtl_attachment;

typedef struct {
	vkmtl_attachment color[VKMTL_MAX_COLOR], depth, stencil;
	uint64_t renderTargetWidth, renderTargetHeight, renderTargetArrayLength, defaultRasterSampleCount;
} vkmtl_pass;

#endif
