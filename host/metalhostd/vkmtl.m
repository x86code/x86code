// x86Sim: libvkmtl.dylib -- our MTLDevice for the Metal simulator service (metalhostd).
//
// Apple's MTLSimImplementation (the server half of the iOS simulator's Metal transport) replays every app's
// Metal calls on the device MTLCreateSystemDefaultDevice() returns in its process. In metalhostd that is
// VKMTLDevice: Metal objects that forward to mtlvk, a native Linux process running them on Vulkan, over a
// Unix socket in the VKMTL protocol (vkmtl_proto.h). Buffer memory goes over without copies: the memfd
// behind the pages (Darling syscall 599) is passed with SCM_RIGHTS and mtlvk imports the same pages.
//
// Stages 1-3 of PLAN.md: device info, buffers, textures (replaceRegion/getBytes), blit encoders, render
// passes that only clear, command buffers with handlers, shared events, fences. Stage 4: libraries
// (metallibs, translated to SPIR-V by mtlvk), functions with constants, compute pipeline states, samplers,
// compute encoders, GPU addresses of buffers (the runtime's: shaders read pointers through them). Stage 5:
// render pipeline states (vertex descriptors, blending, attachment formats), depth-stencil states, render
// encoders (state, bindings, draws), textures over buffers and IOSurfaces (the surface's pages from
// iosurfaced, imported without copies). Anything else is logged ("vkmtl: unimplemented") and answers zero/nil.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unistd.h>
#include "vkmtl_proto.h"

#define VKLOG(...) do { fprintf(stderr, "vkmtl: " __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } while (0)
static int g_verbose;
#define VKTRACE(...) do { if (g_verbose) VKLOG(__VA_ARGS__); } while (0)

// Platforms 1: the same libSystem symbol under another name (tvOS/watchOS headers mark syscall() unavailable)
extern int x86sim_syscall(int, ...) __asm("_syscall");
#define SYS_X86SIM_MEMFD_FOR_REGION 599

// ---------------------------------------------------------------------------------------------------------
// Connection to mtlvk

static int g_sock = -1;
static pthread_mutex_t g_send_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_seq = 1;
static _Atomic uint64_t g_next_id = 1;

typedef struct pending { uint64_t seq; void* data; uint32_t size; int done; struct pending* next; } pending;
static pending* g_pending;
static pthread_mutex_t g_plock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pcond = PTHREAD_COND_INITIALIZER;

static uint64_t vk_new_id(void) { return atomic_fetch_add(&g_next_id, 1); }

static int write_all(int fd, const void* p, size_t n) {
	const char* c = p;
	while (n) {
		ssize_t w = write(fd, c, n);
		if (w < 0) { if (errno == EINTR) continue; return -1; }
		c += w; n -= w;
	}
	return 0;
}
static int read_all(int fd, void* p, size_t n) {
	char* c = p;
	while (n) {
		ssize_t r = read(fd, c, n);
		if (r < 0) { if (errno == EINTR) continue; return -1; }
		if (r == 0) return -1;
		c += r; n -= r;
	}
	return 0;
}

// Sends one message (with an fd as SCM_RIGHTS when fd >= 0).
static void vk_send_seq(uint32_t op, uint64_t seq, const void* payload, uint32_t size, int fd) {
	vkmtl_hdr h = { op, size, seq };
	pthread_mutex_lock(&g_send_lock);
	if (g_sock < 0) { pthread_mutex_unlock(&g_send_lock); return; }
	if (fd >= 0) {
		struct iovec iov = { &h, sizeof(h) };
		union { struct cmsghdr c; char buf[CMSG_SPACE(sizeof(int))]; } u;
		memset(&u, 0, sizeof(u));
		struct msghdr m = { 0 };
		m.msg_iov = &iov; m.msg_iovlen = 1;
		m.msg_control = u.buf; m.msg_controllen = sizeof(u.buf);
		struct cmsghdr* c = CMSG_FIRSTHDR(&m);
		c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(c), &fd, sizeof(int));
		ssize_t n;
		do { n = sendmsg(g_sock, &m, 0); } while (n < 0 && errno == EINTR);
		if (n != sizeof(h)) VKLOG("sendmsg with fd: %zd errno %d", n, errno);
	} else {
		write_all(g_sock, &h, sizeof(h));
	}
	if (size) write_all(g_sock, payload, size);
	pthread_mutex_unlock(&g_send_lock);
}
static void vk_send(uint32_t op, const void* payload, uint32_t size) { vk_send_seq(op, 0, payload, size, -1); }

// Sends a request and waits for its reply. Returns the reply payload (malloc'd; caller frees) or NULL.
static void* vk_call_fd(uint32_t op, const void* payload, uint32_t size, int fd, uint32_t* out_size) {
	pending p = { atomic_fetch_add(&g_seq, 1), NULL, 0, 0, NULL };
	pthread_mutex_lock(&g_plock);
	p.next = g_pending; g_pending = &p;
	pthread_mutex_unlock(&g_plock);
	vk_send_seq(op, p.seq, payload, size, fd);
	pthread_mutex_lock(&g_plock);
	while (!p.done && g_sock >= 0) pthread_cond_wait(&g_pcond, &g_plock);
	for (pending** pp = &g_pending; *pp; pp = &(*pp)->next) if (*pp == &p) { *pp = p.next; break; }
	pthread_mutex_unlock(&g_plock);
	if (out_size) *out_size = p.size;
	return p.data;
}
static void* vk_call(uint32_t op, const void* payload, uint32_t size, uint32_t* out_size) { return vk_call_fd(op, payload, size, -1, out_size); }

@class VKMTLCommandBuffer;
static void vk_cb_done(uint64_t cb, uint32_t status, uint32_t error, double start, double end);

static void* vk_reader(void* arg) {
	(void)arg;
	pthread_setname_np("vkmtl.reader");
	for (;;) {
		vkmtl_hdr h;
		if (read_all(g_sock, &h, sizeof(h)) < 0) break;
		void* data = h.size ? malloc(h.size) : NULL;
		if (h.size && read_all(g_sock, data, h.size) < 0) { free(data); break; }
		if (h.op & VKMTL_REPLY) {
			pthread_mutex_lock(&g_plock);
			for (pending* p = g_pending; p; p = p->next) if (p->seq == h.seq) { p->data = data; p->size = h.size; p->done = 1; data = NULL; break; }
			pthread_cond_broadcast(&g_pcond);
			pthread_mutex_unlock(&g_plock);
			free(data);
		} else if (h.op == VKMTL_EV_CB_DONE && h.size >= 32) {
			uint64_t cb; uint32_t st, er; double t0, t1;
			memcpy(&cb, data, 8); memcpy(&st, (char*)data + 8, 4); memcpy(&er, (char*)data + 12, 4);
			memcpy(&t0, (char*)data + 16, 8); memcpy(&t1, (char*)data + 24, 8);
			free(data);
			vk_cb_done(cb, st, er, t0, t1);
		} else {
			free(data);
		}
	}
	VKLOG("connection to mtlvk lost");
	// x86Sim: without mtlvk every object fails (a black screen in CA). Exit, so the clients' connections end and
	// launchd's next metalhostd (started on demand) refuses new clients until mtlvk is back: they then get no
	// device and fall back to software rendering (see metalhostd.m).
	// (exit on the main queue: an _exit() from this thread while others were inside darlingserver calls made
	// darlingserver abort in Thread::setPendingCall and took the whole simulator down)
	if (!getenv("X86SIM_VKMTL_KEEP_ON_LOSS")) dispatch_async(dispatch_get_main_queue(), ^{ exit(2); });
	pthread_mutex_lock(&g_plock);
	g_sock = -1;
	pthread_cond_broadcast(&g_pcond);
	pthread_mutex_unlock(&g_plock);
	return NULL;
}

// mtlvk's socket ($X86SIM_MTLVK_SOCKET, a Linux path) as seen from Darling.
void VKMTLSocketAddress(struct sockaddr_un* a) {
	const char* path = getenv("X86SIM_MTLVK_SOCKET");
	memset(a, 0, sizeof(*a));
	a->sun_family = AF_UNIX;
	snprintf(a->sun_path, sizeof(a->sun_path), "/Volumes/SystemRoot%s", path ? path : VKMTL_SOCKET_DEFAULT);
}

static int vk_connect(void) {
	struct sockaddr_un a;
	VKMTLSocketAddress(&a);
	const char* full = a.sun_path;
	for (int attempt = 0; attempt < 50; attempt++) {
		int s = socket(AF_UNIX, SOCK_STREAM, 0);
		if (connect(s, (struct sockaddr*)&a, sizeof(a)) == 0) {
			g_sock = s;
			pthread_t t;
			pthread_create(&t, NULL, vk_reader, NULL);
			return 0;
		}
		if (attempt == 0) VKLOG("connect %s: errno %d (retrying)", full, errno);
		close(s);
		usleep(100000);
	}
	VKLOG("no mtlvk at %s", full);
	return -1;
}

// little-endian payload builder
typedef struct { char* p; size_t n, cap; } wbuf;
static void wb_put(wbuf* b, const void* v, size_t n) {
	if (b->n + n > b->cap) { b->cap = (b->n + n) * 2 + 64; b->p = realloc(b->p, b->cap); }
	memcpy(b->p + b->n, v, n); b->n += n;
}
static void wb_u32(wbuf* b, uint32_t v) { wb_put(b, &v, 4); }
static void wb_u64(wbuf* b, uint64_t v) { wb_put(b, &v, 8); }

// ---------------------------------------------------------------------------------------------------------
// Forwarding base: logs selectors we don't implement (answering zero) instead of raising

static const char* const kProtocols[] = { "MTLDevice", "MTLBuffer", "MTLTexture", "MTLResource", "MTLAllocation",
	"MTLCommandQueue", "MTLCommandBuffer", "MTLBlitCommandEncoder", "MTLRenderCommandEncoder", "MTLCommandEncoder",
	"MTLSharedEvent", "MTLEvent", "MTLFence", "MTLComputeCommandEncoder", "MTLLibrary", "MTLFunction",
	"MTLComputePipelineState", "MTLSamplerState", "MTLRenderPipelineState", "MTLDepthStencilState", NULL };

@interface VKMTLObject : NSObject {
@public
	uint64_t _vkid;
	NSString* _label;
}
@property (copy) NSString* label;
@end

@implementation VKMTLObject
@synthesize label = _label;
- (void)dealloc { [_label release]; [super dealloc]; }
- (NSMethodSignature*)methodSignatureForSelector:(SEL)sel {
	NSMethodSignature* s = [super methodSignatureForSelector:sel];
	if (s) return s;
	for (int i = 0; kProtocols[i]; i++) {
		Protocol* p = objc_getProtocol(kProtocols[i]);
		if (!p) continue;
		for (int req = 1; req >= 0; req--) {
			struct objc_method_description d = protocol_getMethodDescription(p, sel, req, YES);
			if (d.types) return [NSMethodSignature signatureWithObjCTypes:d.types];
		}
	}
	// unknown: guess object-sized arguments and return
	const char* n = sel_getName(sel);
	char types[64] = "@@:";
	for (const char* c = n; *c && strlen(types) < sizeof(types) - 2; c++) if (*c == ':') strcat(types, "@");
	return [NSMethodSignature signatureWithObjCTypes:types];
}
- (void)forwardInvocation:(NSInvocation*)inv {
	VKLOG("unimplemented -[%s %s]", class_getName([self class]), sel_getName(inv.selector));
	NSUInteger n = inv.methodSignature.methodReturnLength;
	if (n) {
		void* z = calloc(1, n);
		[inv setReturnValue:z];
		free(z);
	}
}
@end

// ---------------------------------------------------------------------------------------------------------
// Device

@interface VKMTLDevice : VKMTLObject {
@public
	NSString* _name;
	uint64_t _registryID, _workingSet, _maxBufferLength;
	BOOL _unified;
	NSUInteger _profile;
}
@end

static VKMTLDevice* g_device;

@interface VKMTLResource : VKMTLObject {
@public
	MTLResourceOptions _options;
}
@end

@implementation VKMTLResource
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_options & 0xf); }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options >> 4) & 0xf); }
- (MTLHazardTrackingMode)hazardTrackingMode { return (MTLHazardTrackingMode)((_options >> 8) & 0x3); }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { (void)state; return MTLPurgeableStateNonVolatile; }
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)unfilteredResourceOptions { return _options; }
- (uint64_t)uniqueIdentifier { return _vkid; }
- (BOOL)isPurgeable { return NO; }
- (void)dealloc {
	if (_vkid) vk_send(VKMTL_OBJ_DEL, &_vkid, 8);  // VKMTLBuffer/VKMTLTexture sent it already (and cleared _vkid)
	[super dealloc];
}
@end

// ---------------------------------------------------------------------------------------------------------
// Buffers

@interface VKMTLBuffer : VKMTLResource {
@public
	void* _contents;
	NSUInteger _length;
	size_t _ownedLen;          // our own mmap (newBufferWithLength/Bytes)
	void (^_deallocator)(void*, NSUInteger);
	BOOL _copied;              // mtlvk holds a copy: BUF_WRITE before commits, BUF_READ after
	uint64_t _gpuAddress;      // the buffer's address in mtlvk's (the runtime's) GPU address space
}
@end

static NSMutableSet* g_copiedBuffers;     // VKMTLBuffer with _copied
static pthread_mutex_t g_copied_lock = PTHREAD_MUTEX_INITIALIZER;

@implementation VKMTLBuffer
- (instancetype)initWithPointer:(void*)p length:(NSUInteger)len options:(MTLResourceOptions)opts owned:(size_t)owned {
	self = [super init];
	_vkid = vk_new_id();
	_contents = p; _length = len; _options = opts; _ownedLen = owned;
	uint64_t off = 0; uint32_t shared = 0;
	int fd = x86sim_syscall(SYS_X86SIM_MEMFD_FOR_REGION, (uint64_t)(uintptr_t)p, (uint64_t)(len ? len : 1), &off, &shared);
	if (fd < 0) VKLOG("buffer %llu: no memfd for %p+%lu (errno %d): mtlvk keeps a copy", _vkid, p, (unsigned long)len, errno);
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_u64(&b, len); wb_u64(&b, opts); wb_u64(&b, off);
	wb_u32(&b, fd >= 0); wb_u32(&b, shared);
	uint32_t rs = 0;
	int32_t* r = vk_call_fd(VKMTL_BUF_NEW, b.p, (uint32_t)b.n, fd, &rs);
	free(b.p);
	if (fd >= 0) close(fd);
	if (!r || rs < 8 || r[0] != 0) {
		VKLOG("buffer %llu (%lu bytes): mtlvk refused", _vkid, (unsigned long)len);
		free(r);
		[self release];
		return nil;
	}
	_copied = r[1] != 0 || fd < 0;
	if (rs >= 16) memcpy(&_gpuAddress, (char*)r + 8, 8);
	free(r);
	VKTRACE("buffer %llu: %p %lu bytes options %#lx fd-offset %llu shared %u%s", _vkid, p, (unsigned long)len, (unsigned long)opts, off, shared, _copied ? " (copied)" : "");
	if (_copied) {
		pthread_mutex_lock(&g_copied_lock);
		if (!g_copiedBuffers) g_copiedBuffers = [[NSMutableSet alloc] init];
		[g_copiedBuffers addObject:[NSValue valueWithNonretainedObject:self]];
		pthread_mutex_unlock(&g_copied_lock);
		[self pushToGPU];
	}
	return self;
}
- (void)pushToGPU {
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_u64(&b, 0); wb_u64(&b, _length); wb_put(&b, _contents, _length);
	vk_send(VKMTL_BUF_WRITE, b.p, (uint32_t)b.n);
	free(b.p);
}
- (void)pullFromGPU {
	uint64_t q[3] = { _vkid, 0, _length };
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_BUF_READ, q, sizeof(q), &rs);
	if (r && rs >= 8 + _length && *(int32_t*)r == 0) memcpy(_contents, r + 8, _length);
	free(r);
}
- (void)dealloc {
	if (_copied) {
		pthread_mutex_lock(&g_copied_lock);
		[g_copiedBuffers removeObject:[NSValue valueWithNonretainedObject:self]];
		pthread_mutex_unlock(&g_copied_lock);
	}
	vk_send(VKMTL_OBJ_DEL, &_vkid, 8);
	_vkid = 0;
	if (_ownedLen) munmap(_contents, _ownedLen);
	if (_deallocator) { _deallocator(_contents, _length); [_deallocator release]; }
	[super dealloc];
}
- (void*)contents { return _contents; }
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return (_length + 4095) & ~(NSUInteger)4095; }
- (void)didModifyRange:(NSRange)range { if (_copied) [self pushToGPU]; (void)range; }
- (uint64_t)gpuAddress { return _gpuAddress; }
- (id<MTLBuffer>)remoteStorageBuffer { return nil; }
- (void)addDebugMarker:(NSString*)m range:(NSRange)r { (void)m; (void)r; }
- (void)removeAllDebugMarkers {}
- (BOOL)isSparse { return NO; }
@end

static void vk_push_copied(void) {
	pthread_mutex_lock(&g_copied_lock);
	for (NSValue* v in g_copiedBuffers) [(VKMTLBuffer*)v.nonretainedObjectValue pushToGPU];
	pthread_mutex_unlock(&g_copied_lock);
}
static void vk_pull_copied(void) {
	pthread_mutex_lock(&g_copied_lock);
	for (NSValue* v in g_copiedBuffers) [(VKMTLBuffer*)v.nonretainedObjectValue pullFromGPU];
	pthread_mutex_unlock(&g_copied_lock);
}

// ---------------------------------------------------------------------------------------------------------
// Textures

static NSUInteger vk_bytes_per_pixel(MTLPixelFormat f) {
	switch (f) {
	case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatR8Snorm:
	case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatStencil8: return 1;
	case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
	case MTLPixelFormatR16Float: case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatRG8Snorm:
	case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint: case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm:
	case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: case MTLPixelFormatDepth16Unorm: return 2;
	case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float: case MTLPixelFormatRG16Unorm:
	case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float:
	case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint:
	case MTLPixelFormatRGBA8Sint: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGB10A2Unorm:
	case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: case MTLPixelFormatBGR10A2Unorm:
	case MTLPixelFormatDepth32Float: case (MTLPixelFormat)255 /* Depth24Unorm_Stencil8 */: return 4;
	case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Unorm:
	case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float:
	case MTLPixelFormatDepth32Float_Stencil8: return 8;
	case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
	default: return 0;
	}
}

// Bytes a region of rows/images covers in the caller's memory.
static size_t vk_region_bytes(MTLPixelFormat f, MTLRegion r, NSUInteger bpr, NSUInteger bpi) {
	NSUInteger bpp = vk_bytes_per_pixel(f);
	NSUInteger rows = r.size.height ? r.size.height : 1, images = r.size.depth ? r.size.depth : 1;
	if (!bpp) return (size_t)bpr * rows * images; // block-compressed etc.: whole rows (over-estimate)
	size_t last_row = (size_t)r.size.width * bpp;
	if (images > 1 && !bpi) bpi = bpr * rows;
	return (images - 1) * (size_t)bpi + (rows - 1) * (size_t)bpr + last_row;
}

@interface VKMTLTexture : VKMTLResource {
@public
	MTLTextureType _type;
	MTLPixelFormat _format;
	NSUInteger _width, _height, _depth, _mips, _array, _samples;
	MTLTextureUsage _usage;
	BOOL _allowOpt;
	MTLTextureSwizzleChannels _swizzle;
	// x86Sim: stage 5: a texture over a buffer's bytes (IOSurface plane or newTextureWithDescriptor:offset:bytesPerRow:)
	id _buffer;              // VKMTLBuffer (retained)
	NSUInteger _bufOffset, _bufBPR;
	IOSurfaceRef _iosurface; // retained
	NSUInteger _plane;
	// x86Sim: texture views: the parent (retained) and where the view starts in it
	id _parent;
	NSUInteger _parentLevel, _parentSlice;
}
@end

static uint32_t vk_swizzle_bits(MTLTextureSwizzleChannels s) {
	return (uint32_t)s.red | (uint32_t)s.green << 8 | (uint32_t)s.blue << 16 | (uint32_t)s.alpha << 24;
}

@implementation VKMTLTexture
// A new texture's fields from its descriptor, and the descriptor as TEX_NEW / TEX_NEW_BUF send it.
- (vkmtl_texdesc)vk_takeDescriptor:(MTLTextureDescriptor*)d {
	_vkid = vk_new_id();
	_type = d.textureType; _format = d.pixelFormat;
	_width = d.width; _height = d.height; _depth = d.depth; _mips = d.mipmapLevelCount;
	_array = d.arrayLength; _samples = d.sampleCount; _usage = d.usage;
	_options = d.resourceOptions;
	_allowOpt = d.allowGPUOptimizedContents;
	_swizzle = d.swizzle;
	return (vkmtl_texdesc){ (uint32_t)_type, (uint32_t)_format, _width, _height, _depth, (uint32_t)_mips, (uint32_t)_samples, _array,
		_options, _usage, vk_swizzle_bits(_swizzle), _allowOpt };
}
- (instancetype)initWithDescriptor:(MTLTextureDescriptor*)d {
	self = [super init];
	vkmtl_texdesc td = [self vk_takeDescriptor:d];
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_put(&b, &td, sizeof(td));
	uint32_t rs = 0;
	int32_t* r = vk_call(VKMTL_TEX_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	if (!r || rs < 4 || r[0] != 0) {
		VKLOG("texture %llu: mtlvk refused (format %lu %lux%lux%lu type %lu usage %#lx options %#lx)", _vkid,
			(unsigned long)_format, (unsigned long)_width, (unsigned long)_height, (unsigned long)_depth, (unsigned long)_type,
			(unsigned long)_usage, (unsigned long)_options);
		free(r);
		[self release];
		return nil;
	}
	free(r);
	VKTRACE("texture %llu: format %lu %lux%lux%lu mips %lu usage %#lx options %#lx", _vkid, (unsigned long)_format,
		(unsigned long)_width, (unsigned long)_height, (unsigned long)_depth, (unsigned long)_mips, (unsigned long)_usage, (unsigned long)_options);
	return self;
}
- (MTLTextureType)textureType { return _type; }
- (MTLPixelFormat)pixelFormat { return _format; }
- (NSUInteger)width { return _width; }
- (NSUInteger)height { return _height; }
- (NSUInteger)depth { return _depth; }
- (NSUInteger)mipmapLevelCount { return _mips; }
- (NSUInteger)arrayLength { return _array; }
- (NSUInteger)sampleCount { return _samples; }
- (MTLTextureUsage)usage { return _usage; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return _allowOpt; }
- (MTLTextureSwizzleChannels)swizzle { return _swizzle; }
- (BOOL)isShareable { return NO; }
- (BOOL)isSparse { return NO; }
- (IOSurfaceRef)iosurface { return _iosurface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (id<MTLTexture>)parentTexture { return _parent; }
- (id<MTLTexture>)rootResource { return _parent ? [_parent rootResource] ?: _parent : nil; }
- (NSUInteger)parentRelativeLevel { return _parentLevel; }
- (NSUInteger)parentRelativeSlice { return _parentSlice; }
// x86Sim: texture views (MercuryPoster's wallpaper uses newTextureViewWithPixelFormat:textureType:levels:slices:)
- (id<MTLTexture>)vk_viewWithFormat:(MTLPixelFormat)pf type:(MTLTextureType)tt levels:(NSRange)levels slices:(NSRange)slices
	swizzle:(const MTLTextureSwizzleChannels*)swz {
	VKMTLTexture* v = [[VKMTLTexture alloc] init];
	v->_vkid = vk_new_id();
	v->_type = tt; v->_format = pf;
	v->_width = MAX(_width >> levels.location, 1); v->_height = MAX(_height >> levels.location, 1);
	v->_depth = tt == MTLTextureType3D ? MAX(_depth >> levels.location, 1) : 1;
	v->_mips = levels.length;
	v->_samples = _samples; v->_usage = _usage; v->_options = _options; v->_allowOpt = _allowOpt;
	v->_array = (tt == MTLTextureTypeCube || tt == MTLTextureTypeCubeArray) ? MAX(slices.length / 6, 1) :
		(tt == MTLTextureType2DArray || tt == MTLTextureType1DArray || tt == MTLTextureType2DMultisampleArray) ? slices.length : 1;
	v->_swizzle = swz ? *swz : _swizzle;
	v->_parent = [self retain]; v->_parentLevel = levels.location; v->_parentSlice = slices.location;
	v->_buffer = [_buffer retain]; v->_bufOffset = _bufOffset; v->_bufBPR = _bufBPR;
	if (_iosurface) { v->_iosurface = (IOSurfaceRef)CFRetain(_iosurface); v->_plane = _plane; }
	wbuf b = { 0 };
	wb_u64(&b, v->_vkid); wb_u64(&b, _vkid); wb_u32(&b, (uint32_t)pf); wb_u32(&b, (uint32_t)tt);
	wb_u64(&b, levels.location); wb_u64(&b, levels.length); wb_u64(&b, slices.location); wb_u64(&b, slices.length);
	wb_u32(&b, swz != NULL);
	wb_u32(&b, swz ? vk_swizzle_bits(*swz) : 0);
	uint32_t rs = 0;
	int32_t* r = vk_call(VKMTL_TEX_VIEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	if (!r || rs < 4 || r[0] != 0) {
		VKLOG("texture view of %llu: mtlvk refused (format %lu type %lu levels %lu+%lu slices %lu+%lu)", _vkid, (unsigned long)pf,
			(unsigned long)tt, (unsigned long)levels.location, (unsigned long)levels.length, (unsigned long)slices.location,
			(unsigned long)slices.length);
		free(r);
		[v release];
		return nil;
	}
	free(r);
	VKTRACE("texture %llu: view of %llu format %lu", v->_vkid, _vkid, (unsigned long)pf);
	return (id<MTLTexture>)v;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pf {
	NSUInteger slices = (_type == MTLTextureTypeCube || _type == MTLTextureTypeCubeArray) ? _array * 6 : _array;
	return [self vk_viewWithFormat:pf type:_type levels:NSMakeRange(0, _mips) slices:NSMakeRange(0, MAX(slices, 1)) swizzle:NULL];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:(MTLTextureType)tt levels:(NSRange)levels slices:(NSRange)slices {
	return [self vk_viewWithFormat:pf type:tt levels:levels slices:slices swizzle:NULL];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:(MTLTextureType)tt levels:(NSRange)levels slices:(NSRange)slices
	swizzle:(MTLTextureSwizzleChannels)swizzle {
	return [self vk_viewWithFormat:pf type:tt levels:levels slices:slices swizzle:&swizzle];
}
- (id<MTLBuffer>)buffer { return _iosurface ? nil : (id<MTLBuffer>)_buffer; }
- (NSUInteger)bufferOffset { return _iosurface ? 0 : _bufOffset; }
- (NSUInteger)bufferBytesPerRow { return _iosurface ? 0 : _bufBPR; }
- (void)dealloc {
	vk_send(VKMTL_OBJ_DEL, &_vkid, 8);  // before the buffer it lives in
	_vkid = 0;
	[_buffer release];
	[_parent release];
	if (_iosurface) CFRelease(_iosurface);
	[super dealloc];
}
// x86Sim: a texture over `buffer`'s bytes from `offset` (rows `bpr` apart); an IOSurface's plane when `surface` is set.
- (instancetype)initWithDescriptor:(MTLTextureDescriptor*)d buffer:(id)buffer offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr
	iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane planar:(BOOL)planar {
	self = [super init];
	vkmtl_texdesc td = [self vk_takeDescriptor:d];
	_buffer = [buffer retain]; _bufOffset = offset; _bufBPR = bpr; _plane = plane;
	if (surface) _iosurface = (IOSurfaceRef)CFRetain(surface);
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_u64(&b, ((VKMTLObject*)buffer)->_vkid); wb_put(&b, &td, sizeof(td));
	wb_u64(&b, offset); wb_u64(&b, bpr); wb_u32(&b, surface != NULL); wb_u32(&b, planar);
	uint32_t rs = 0;
	int32_t* r = vk_call(VKMTL_TEX_NEW_BUF, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	if (!r || rs < 4 || r[0] != 0) {
		VKLOG("texture %llu over buffer %llu: mtlvk refused (format %lu %lux%lu usage %#lx%s)", _vkid, ((VKMTLObject*)buffer)->_vkid,
			(unsigned long)_format, (unsigned long)_width, (unsigned long)_height, (unsigned long)_usage, surface ? ", IOSurface" : "");
		free(r);
		[self release];
		return nil;
	}
	free(r);
	VKTRACE("texture %llu: format %lu %lux%lu over buffer %llu +%lu row %lu%s", _vkid, (unsigned long)_format, (unsigned long)_width,
		(unsigned long)_height, ((VKMTLObject*)buffer)->_vkid, (unsigned long)offset, (unsigned long)bpr, surface ? " (IOSurface)" : "");
	return self;
}
- (NSUInteger)firstMipmapInTail { return _mips; }
- (NSUInteger)tailSizeInBytes { return 0; }
- (MTLTextureCompressionType)compressionType { return MTLTextureCompressionTypeLossless; }
// x86Sim: iOS 27 MTLSimTexture compressionMetadata (lossy/compressed layouts); none of ours are compressed.
- (id)compressionMetadata { return nil; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _vkid; return r; }
- (NSUInteger)allocatedSize {
	NSUInteger bpp = vk_bytes_per_pixel(_format) ?: 4;
	return _width * _height * _depth * _array * bpp * _samples * (_mips > 1 ? 2 : 1);
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void*)bytes
	bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
	size_t n = vk_region_bytes(_format, region, bpr, bpi);
	vkmtl_region r = { region.origin.x, region.origin.y, region.origin.z, region.size.width, region.size.height, region.size.depth };
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_put(&b, &r, sizeof(r)); wb_u32(&b, (uint32_t)level); wb_u32(&b, (uint32_t)slice);
	wb_u64(&b, bpr); wb_u64(&b, bpi); wb_u64(&b, n); wb_put(&b, bytes, n);
	vk_send(VKMTL_TEX_REPLACE, b.p, (uint32_t)b.n);
	free(b.p);
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void*)bytes bytesPerRow:(NSUInteger)bpr {
	[self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:bpr bytesPerImage:0];
}
- (void)getBytes:(void*)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)region
	mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
	size_t n = vk_region_bytes(_format, region, bpr, bpi);
	vkmtl_region r = { region.origin.x, region.origin.y, region.origin.z, region.size.width, region.size.height, region.size.depth };
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_put(&b, &r, sizeof(r)); wb_u32(&b, (uint32_t)level); wb_u32(&b, (uint32_t)slice);
	wb_u64(&b, bpr); wb_u64(&b, bpi); wb_u64(&b, n);
	uint32_t rs = 0;
	char* rep = vk_call(VKMTL_TEX_GETBYTES, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	if (rep && rs >= 16 && *(int32_t*)rep == 0) {
		uint64_t got; memcpy(&got, rep + 8, 8);
		memcpy(bytes, rep + 16, got < n ? got : n);
	} else {
		VKLOG("texture %llu: getBytes failed", _vkid);
	}
	free(rep);
}
- (void)getBytes:(void*)bytes bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
	[self getBytes:bytes bytesPerRow:bpr bytesPerImage:0 fromRegion:region mipmapLevel:level slice:0];
}
@end

// ---------------------------------------------------------------------------------------------------------
// Events and fences

@interface VKMTLSharedEvent : VKMTLObject {
@public
	NSMutableArray* _listeners; // [value, block, listener]
}
- (void)checkListeners;
@end

static NSHashTable* g_events; // weak VKMTLSharedEvent with listeners
static pthread_mutex_t g_events_lock = PTHREAD_MUTEX_INITIALIZER;

@implementation VKMTLSharedEvent
- (instancetype)initShared:(BOOL)shared {
	self = [super init];
	_vkid = vk_new_id();
	uint64_t p[2] = { _vkid, shared };
	vk_send(VKMTL_EVENT_NEW, p, sizeof(p));
	return self;
}
- (void)dealloc {
	pthread_mutex_lock(&g_events_lock);
	[g_events removeObject:self];
	pthread_mutex_unlock(&g_events_lock);
	vk_send(VKMTL_OBJ_DEL, &_vkid, 8);
	[_listeners release];
	[super dealloc];
}
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (uint64_t)signaledValue {
	uint32_t rs = 0;
	uint64_t* r = vk_call(VKMTL_EVENT_GET, &_vkid, 8, &rs);
	uint64_t v = (r && rs >= 8) ? *r : 0;
	free(r);
	return v;
}
- (void)setSignaledValue:(uint64_t)v {
	uint64_t p[2] = { _vkid, v };
	vk_send(VKMTL_EVENT_SET, p, sizeof(p));
	[self checkListeners];
}
- (BOOL)waitUntilSignaledValue:(uint64_t)v timeoutMS:(uint64_t)ms {
	for (uint64_t t = 0; t <= ms; t++) { if (self.signaledValue >= v) return YES; usleep(1000); }
	return NO;
}
- (void)notifyListener:(MTLSharedEventListener*)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
	@synchronized (self) {
		if (!_listeners) _listeners = [[NSMutableArray alloc] init];
		[_listeners addObject:@[ @(value), [[block copy] autorelease], listener ?: (id)[NSNull null] ]];
	}
	pthread_mutex_lock(&g_events_lock);
	if (!g_events) g_events = [[NSHashTable weakObjectsHashTable] retain];
	[g_events addObject:self];
	pthread_mutex_unlock(&g_events_lock);
	[self checkListeners];
}
- (void)checkListeners {
	NSArray* fire = nil;
	@synchronized (self) {
		if (!_listeners.count) return;
		uint64_t v = self.signaledValue;
		NSIndexSet* idx = [_listeners indexesOfObjectsPassingTest:^BOOL(NSArray* l, NSUInteger i, BOOL* stop) {
			(void)i; (void)stop; return [l[0] unsignedLongLongValue] <= v; }];
		fire = [[_listeners objectsAtIndexes:idx] retain];
		[_listeners removeObjectsAtIndexes:idx];
	}
	for (NSArray* l in fire) {
		MTLSharedEventNotificationBlock b = l[1];
		id listener = l[2];
		dispatch_queue_t q = [listener isKindOfClass:[MTLSharedEventListener class]] ? [(MTLSharedEventListener*)listener dispatchQueue] : nil;
		uint64_t v = [l[0] unsignedLongLongValue];
		[self retain];
		dispatch_async(q ?: dispatch_get_global_queue(0, 0), ^{ b((id<MTLSharedEvent>)self, v); [self release]; });
	}
	[fire release];
}
@end

static void vk_check_all_listeners(void) {
	pthread_mutex_lock(&g_events_lock);
	NSArray* all = [g_events allObjects];
	pthread_mutex_unlock(&g_events_lock);
	for (VKMTLSharedEvent* e in all) [e checkListeners];
}

@interface VKMTLFence : VKMTLObject
@end
@implementation VKMTLFence
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
@end

@implementation VKMTLBuffer (VKTextures)
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor*)d offset:(NSUInteger)o bytesPerRow:(NSUInteger)bpr {
	return (id<MTLTexture>)[[VKMTLTexture alloc] initWithDescriptor:d buffer:self offset:o bytesPerRow:bpr iosurface:NULL plane:0 planar:NO];
}
@end

// ---------------------------------------------------------------------------------------------------------
// Command queues, buffers, encoders

@interface VKMTLCommandQueue : VKMTLObject {
@public
	NSUInteger _max;
}
@end

typedef NS_ENUM(int, VKCBState) { VKCBRecording, VKCBCommitted, VKCBDone };

@interface VKMTLCommandBuffer : VKMTLObject {
@public
	VKMTLCommandQueue* _queue;
	wbuf _cmds;
	uint32_t _count;
	NSMutableArray* _scheduled;
	NSMutableArray* _completed;
	MTLCommandBufferStatus _status;
	NSError* _error;
	double _start, _end;
	BOOL _retained;
	pthread_mutex_t _lock;
	pthread_cond_t _cond;
	NSMutableArray* _keep;     // resources used (retained until completion, like retainedReferences)
}
- (void)addCommand:(uint32_t)kind data:(const void*)d size:(uint32_t)n;
- (void)appendCommands:(const void*)d size:(size_t)n count:(uint32_t)count;
- (void)keep:(id)o;
@end

static NSMutableDictionary* g_inflight; // @(cb id) -> VKMTLCommandBuffer
static pthread_mutex_t g_inflight_lock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_completion_queue;

@interface VKMTLEncoder : VKMTLObject {
@public
	VKMTLCommandBuffer* _cb;
}
@end
@implementation VKMTLEncoder
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (void)insertDebugSignpost:(NSString*)s { (void)s; }
- (void)pushDebugGroup:(NSString*)s { (void)s; }
- (void)popDebugGroup {}
- (void)updateFence:(id<MTLFence>)f { (void)f; }
- (void)waitForFence:(id<MTLFence>)f { (void)f; }
- (void)updateFence:(id<MTLFence>)f afterStages:(MTLRenderStages)s { (void)f; (void)s; }
- (void)waitForFence:(id<MTLFence>)f beforeStages:(MTLRenderStages)s { (void)f; (void)s; }
- (void)barrierAfterQueueStages:(NSUInteger)a beforeStages:(NSUInteger)b { (void)a; (void)b; }
- (void)dealloc { [_cb release]; [super dealloc]; }
@end

@interface VKMTLBlitCommandEncoder : VKMTLEncoder
@end

@implementation VKMTLBlitCommandEncoder
static uint64_t vid(id o) { return o ? ((VKMTLObject*)o)->_vkid : 0; }
- (void)endEncoding {}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)dof size:(NSUInteger)n {
	uint64_t c[5] = { vid(src), so, vid(dst), dof, n };
	[_cb keep:src]; [_cb keep:dst];
	[_cb addCommand:VKMTL_C_COPY_BB data:c size:sizeof(c)];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi
	sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
	destinationOrigin:(MTLOrigin)o options:(MTLBlitOption)opt {
	wbuf b = { 0 };
	wb_u64(&b, vid(src)); wb_u64(&b, so); wb_u64(&b, bpr); wb_u64(&b, bpi);
	wb_u64(&b, size.width); wb_u64(&b, size.height); wb_u64(&b, size.depth);
	wb_u64(&b, vid(dst)); wb_u32(&b, (uint32_t)slice); wb_u32(&b, (uint32_t)level);
	wb_u64(&b, o.x); wb_u64(&b, o.y); wb_u64(&b, o.z); wb_u64(&b, opt);
	[_cb keep:src]; [_cb keep:dst];
	[_cb addCommand:VKMTL_C_COPY_BT data:b.p size:(uint32_t)b.n];
	free(b.p);
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi
	sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
	destinationOrigin:(MTLOrigin)o {
	[self copyFromBuffer:src sourceOffset:so sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:size toTexture:dst
		destinationSlice:slice destinationLevel:level destinationOrigin:o options:MTLBlitOptionNone];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)o
	sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)dof destinationBytesPerRow:(NSUInteger)bpr
	destinationBytesPerImage:(NSUInteger)bpi options:(MTLBlitOption)opt {
	wbuf b = { 0 };
	wb_u64(&b, vid(src)); wb_u32(&b, (uint32_t)slice); wb_u32(&b, (uint32_t)level);
	wb_u64(&b, o.x); wb_u64(&b, o.y); wb_u64(&b, o.z);
	wb_u64(&b, size.width); wb_u64(&b, size.height); wb_u64(&b, size.depth);
	wb_u64(&b, vid(dst)); wb_u64(&b, dof); wb_u64(&b, bpr); wb_u64(&b, bpi); wb_u64(&b, opt);
	[_cb keep:src]; [_cb keep:dst];
	[_cb addCommand:VKMTL_C_COPY_TB data:b.p size:(uint32_t)b.n];
	free(b.p);
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)o
	sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)dof destinationBytesPerRow:(NSUInteger)bpr
	destinationBytesPerImage:(NSUInteger)bpi {
	[self copyFromTexture:src sourceSlice:slice sourceLevel:level sourceOrigin:o sourceSize:size toBuffer:dst destinationOffset:dof
		destinationBytesPerRow:bpr destinationBytesPerImage:bpi options:MTLBlitOptionNone];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so
	sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl
	destinationOrigin:(MTLOrigin)dor {
	wbuf b = { 0 };
	wb_u64(&b, vid(src)); wb_u32(&b, (uint32_t)ss); wb_u32(&b, (uint32_t)sl);
	wb_u64(&b, so.x); wb_u64(&b, so.y); wb_u64(&b, so.z);
	wb_u64(&b, size.width); wb_u64(&b, size.height); wb_u64(&b, size.depth);
	wb_u64(&b, vid(dst)); wb_u32(&b, (uint32_t)ds); wb_u32(&b, (uint32_t)dl);
	wb_u64(&b, dor.x); wb_u64(&b, dor.y); wb_u64(&b, dor.z);
	[_cb keep:src]; [_cb keep:dst];
	[_cb addCommand:VKMTL_C_COPY_TT data:b.p size:(uint32_t)b.n];
	free(b.p);
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl toTexture:(id<MTLTexture>)dst
	destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl sliceCount:(NSUInteger)sc levelCount:(NSUInteger)lc {
	for (NSUInteger s = 0; s < sc; s++)
		for (NSUInteger l = 0; l < lc; l++) {
			NSUInteger w = MAX(src.width >> (sl + l), 1), h = MAX(src.height >> (sl + l), 1), d = MAX(src.depth >> (sl + l), 1);
			[self copyFromTexture:src sourceSlice:ss + s sourceLevel:sl + l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, d)
				toTexture:dst destinationSlice:ds + s destinationLevel:dl + l destinationOrigin:MTLOriginMake(0, 0, 0)];
		}
}
- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst {
	NSUInteger slices = src.textureType == MTLTextureTypeCube || src.textureType == MTLTextureTypeCubeArray ? src.arrayLength * 6 : src.arrayLength;
	[self copyFromTexture:src sourceSlice:0 sourceLevel:0 toTexture:dst destinationSlice:0 destinationLevel:0 sliceCount:slices
		levelCount:MIN(src.mipmapLevelCount, dst.mipmapLevelCount)];
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
	uint64_t c[4] = { vid(buffer), range.location, range.length, value };
	[_cb keep:buffer];
	[_cb addCommand:VKMTL_C_FILL data:c size:sizeof(c)];
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)t {
	uint64_t c = vid(t);
	[_cb keep:t];
	[_cb addCommand:VKMTL_C_MIPMAPS data:&c size:8];
}
- (void)synchronizeResource:(id<MTLResource>)r { (void)r; }
- (void)synchronizeTexture:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t { (void)t; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t { (void)t; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
@end


// ---------------------------------------------------------------------------------------------------------
// Stage 4: libraries, functions, compute pipeline states, samplers, compute encoders

static NSError* vk_error(NSString* domain, NSInteger code, const char* text, uint32_t len) {
	NSString* msg = text ? [[[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding] autorelease] : @"mtlvk refused";
	return [NSError errorWithDomain:domain code:code userInfo:@{ NSLocalizedDescriptionKey: msg ?: @"mtlvk refused" }];
}
// The {u32 len, text} error at `off` of a reply.
static NSError* vk_reply_error(NSString* domain, NSInteger code, const char* r, uint32_t rs, uint32_t off) {
	uint32_t len = 0;
	if (r && rs >= off + 4) { memcpy(&len, r + off, 4); if (off + 4 + len > rs) len = rs - off - 4; }
	return vk_error(domain, code, r && len ? r + off + 4 : NULL, len);
}

@interface VKMTLLibrary : VKMTLObject {
@public
	NSArray<NSString*>* _names;
	NSMutableDictionary<NSString*, NSNumber*>* _types;
	NSString* _overrideTriple;
}
@end
@interface VKMTLFunction : VKMTLObject {
@public
	VKMTLLibrary* _library;
	NSString* _name;
	MTLFunctionType _type;
	MTLFunctionOptions _fnOptions;
}
@end

@implementation VKMTLFunction
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (NSString*)name { return _name; }
- (MTLFunctionType)functionType { return _type; }
- (MTLFunctionOptions)options { return _fnOptions; }
- (MTLPatchType)patchType { return MTLPatchTypeNone; }
- (NSInteger)patchControlPointCount { return -1; }
- (NSArray*)vertexAttributes { return nil; }
- (NSArray*)stageInputAttributes { return nil; }
- (NSDictionary*)functionConstantsDictionary { return @{}; }
- (NSString*)description { return [NSString stringWithFormat:@"<VKMTLFunction %@ type %lu>", _name, (unsigned long)_type]; }
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [_library release]; [_name release]; [super dealloc]; }
@end

static int g_dump_libs;
static _Atomic int g_dump_n;

@implementation VKMTLLibrary
- (instancetype)initWithBytes:(const void*)p length:(size_t)n error:(NSError**)error {
	self = [super init];
	_vkid = vk_new_id();
	if (g_dump_libs) {
		// x86Sim: into $X86SIM_VKMTL_DUMP_DIR (a Darling path), default $HOME/tmp (the device's data/tmp for metalhostd)
		char path[1024], dflt[900];
		const char* dir = getenv("X86SIM_VKMTL_DUMP_DIR");
		if (!dir) { snprintf(dflt, sizeof(dflt), "%s/tmp", getenv("HOME") ?: "/private/tmp"); dir = dflt; }
		snprintf(path, sizeof(path), "%s/lib-%d-%d.metallib", dir, getpid(), atomic_fetch_add(&g_dump_n, 1));
		FILE* f = fopen(path, "wb");
		if (f) { fwrite(p, 1, n, f); fclose(f); VKLOG("library %llu (%zu bytes) saved to %s", _vkid, n, path); }
	}
	wbuf b = { 0 };
	wb_u64(&b, _vkid); wb_u64(&b, n); wb_put(&b, p, n);
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_LIB_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	int32_t st = -1; uint32_t count = 0;
	if (r && rs >= 8) { memcpy(&st, r, 4); memcpy(&count, r + 4, 4); }
	if (st != 0) {
		NSError* e = vk_reply_error(MTLLibraryErrorDomain, MTLLibraryErrorInternal, r, rs, 8);
		VKLOG("library %llu (%zu bytes): mtlvk refused: %s", _vkid, n, e.localizedDescription.UTF8String);
		if (error) *error = e;
		free(r);
		[self release];
		return nil;
	}
	NSMutableArray* names = [NSMutableArray array];
	_types = [[NSMutableDictionary alloc] init];
	uint32_t off = 8;
	for (uint32_t i = 0; i < count && off + 8 <= rs; i++) {
		uint32_t ty, nl; memcpy(&ty, r + off, 4); memcpy(&nl, r + off + 4, 4); off += 8;
		if (off + nl > rs) break;
		NSString* name = [[[NSString alloc] initWithBytes:r + off length:nl encoding:NSUTF8StringEncoding] autorelease];
		off += nl;
		[names addObject:name];
		_types[name] = @(ty);
	}
	_names = [names copy];
	free(r);
	VKTRACE("library %llu: %zu bytes, functions %s", _vkid, n, [_names componentsJoinedByString:@","].UTF8String);
	return self;
}
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [_names release]; [_types release]; [_overrideTriple release]; [super dealloc]; }
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (NSArray<NSString*>*)functionNames { return _names; }
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
// MTLSimImplementation sets "air64-apple-macosx10.14.0" (for the Mac's compiler); metal2vulkan takes the
// simulator's triple as it is, so it is only remembered.
- (NSString*)overrideTriple { return _overrideTriple; }
- (void)setOverrideTriple:(NSString*)t { [_overrideTriple release]; _overrideTriple = [t copy]; VKTRACE("library %llu: overrideTriple %s", _vkid, t.UTF8String); }
- (NSString*)installName { return nil; }
- (id<MTLFunction>)newFunctionWithName:(NSString*)name constants:(MTLFunctionConstantValues*)cv error:(NSError**)error {
	if (!name) return nil;
	wbuf b = { 0 };
	uint64_t fid = vk_new_id();
	const char* nm = name.UTF8String;
	uint32_t nl = (uint32_t)strlen(nm), nconst = 0;
	wbuf cb = { 0 };
	if (cv) {
		// MTLFunctionConstantValues has no public getters: vk_constant_values() reads what its setters recorded
		extern uint32_t vk_constant_values(MTLFunctionConstantValues* cv, wbuf* out);
		nconst = vk_constant_values(cv, &cb);
	}
	wb_u64(&b, fid); wb_u64(&b, _vkid); wb_u32(&b, nl); wb_u32(&b, nconst); wb_put(&b, nm, nl);
	if (cb.n) wb_put(&b, cb.p, cb.n);
	free(cb.p);
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_FUNC_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	int32_t st = -1; uint32_t ty = 0;
	if (r && rs >= 8) { memcpy(&st, r, 4); memcpy(&ty, r + 4, 4); }
	if (st != 0) {
		NSError* e = vk_reply_error(MTLLibraryErrorDomain, MTLLibraryErrorFunctionNotFound, r, rs, 8);
		VKLOG("function %s: mtlvk refused: %s", nm, e.localizedDescription.UTF8String);
		if (error) *error = e;
		free(r);
		return nil;
	}
	free(r);
	VKMTLFunction* f = [[VKMTLFunction alloc] init];
	f->_vkid = fid;
	f->_library = [self retain];
	f->_name = [name copy];
	f->_type = (MTLFunctionType)ty;
	VKTRACE("function %llu: %s type %u, %u constants", fid, nm, ty, nconst);
	return (id<MTLFunction>)f;
}
- (id<MTLFunction>)newFunctionWithName:(NSString*)name { return [self newFunctionWithName:name constants:nil error:NULL]; }
- (id<MTLFunction>)newFunctionWithName:(NSString*)name constantValues:(MTLFunctionConstantValues*)cv error:(NSError**)error {
	return [self newFunctionWithName:name constants:cv error:error];
}
- (void)newFunctionWithName:(NSString*)name constantValues:(MTLFunctionConstantValues*)cv
	completionHandler:(void (^)(id<MTLFunction>, NSError*))handler {
	NSError* e = nil;
	id<MTLFunction> f = [self newFunctionWithName:name constants:cv error:&e];
	handler(f, e);
	[f release];
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor*)d error:(NSError**)error {
	VKMTLFunction* f = (VKMTLFunction*)[self newFunctionWithName:d.name constants:d.constantValues error:error];
	if (f) f->_fnOptions = d.options;
	return (id<MTLFunction>)f;
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor*)d completionHandler:(void (^)(id<MTLFunction>, NSError*))handler {
	NSError* e = nil;
	id<MTLFunction> f = [self newFunctionWithDescriptor:d error:&e];
	handler(f, e);
	[f release];
}
@end

// Function constant values: MTLFunctionConstantValues keeps them in a private MTLFunctionConstantValuesInternal
// whose layout we don't know and has no getters, so its three setters are swizzled (in metalhostd only) to
// record what is set, keyed by the object.
static NSMapTable* g_cv_records; // MTLFunctionConstantValues -> NSMutableArray of @[index or name, type, NSData]
static pthread_mutex_t g_cv_lock = PTHREAD_MUTEX_INITIALIZER;

static size_t vk_data_type_size(MTLDataType t) {
	switch (t) {
	case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: return 1;
	case MTLDataTypeBool2: case MTLDataTypeChar2: case MTLDataTypeUChar2: case MTLDataTypeShort: case MTLDataTypeUShort: case MTLDataTypeHalf: return 2;
	case MTLDataTypeBool3: case MTLDataTypeChar3: case MTLDataTypeUChar3: return 3;
	case MTLDataTypeBool4: case MTLDataTypeChar4: case MTLDataTypeUChar4: case MTLDataTypeShort2: case MTLDataTypeUShort2: case MTLDataTypeHalf2:
	case MTLDataTypeInt: case MTLDataTypeUInt: case MTLDataTypeFloat: return 4;
	case MTLDataTypeShort3: case MTLDataTypeUShort3: case MTLDataTypeHalf3: return 6;
	case MTLDataTypeShort4: case MTLDataTypeUShort4: case MTLDataTypeHalf4: case MTLDataTypeInt2: case MTLDataTypeUInt2: case MTLDataTypeFloat2:
	case MTLDataTypeLong: case MTLDataTypeULong: return 8;
	case MTLDataTypeInt3: case MTLDataTypeUInt3: case MTLDataTypeFloat3: return 12;
	case MTLDataTypeInt4: case MTLDataTypeUInt4: case MTLDataTypeFloat4: return 16;
	default: return 0;
	}
}

static void (*real_setIndex)(id, SEL, const void*, MTLDataType, NSUInteger);
static void (*real_setName)(id, SEL, const void*, MTLDataType, NSString*);
static void (*real_setRange)(id, SEL, const void*, MTLDataType, NSRange);
static void vk_cv_record(id cv, id key, MTLDataType t, const void* v) {
	size_t n = vk_data_type_size(t);
	if (!n || !v) return;
	pthread_mutex_lock(&g_cv_lock);
	if (!g_cv_records) g_cv_records = [[NSMapTable weakToStrongObjectsMapTable] retain];
	NSMutableArray* a = [g_cv_records objectForKey:cv];
	if (!a) { a = [NSMutableArray array]; [g_cv_records setObject:a forKey:cv]; }
	[a addObject:@[ key, @(t), [NSData dataWithBytes:v length:n] ]];
	pthread_mutex_unlock(&g_cv_lock);
}
static void my_setIndex(id self, SEL sel, const void* v, MTLDataType t, NSUInteger i) { vk_cv_record(self, @(i), t, v); real_setIndex(self, sel, v, t, i); }
static void my_setName(id self, SEL sel, const void* v, MTLDataType t, NSString* n) { vk_cv_record(self, [[n copy] autorelease], t, v); real_setName(self, sel, v, t, n); }
static void my_setRange(id self, SEL sel, const void* v, MTLDataType t, NSRange r) {
	size_t n = vk_data_type_size(t);
	for (NSUInteger i = 0; i < r.length && n; i++) vk_cv_record(self, @(r.location + i), t, (const char*)v + i * n);
	real_setRange(self, sel, v, t, r);
}
static void vk_hook_constant_values(void) {
	Class c = [MTLFunctionConstantValues class];
	Method m;
	if ((m = class_getInstanceMethod(c, @selector(setConstantValue:type:atIndex:)))) real_setIndex = (void*)method_setImplementation(m, (IMP)my_setIndex);
	if ((m = class_getInstanceMethod(c, @selector(setConstantValue:type:withName:)))) real_setName = (void*)method_setImplementation(m, (IMP)my_setName);
	if ((m = class_getInstanceMethod(c, @selector(setConstantValues:type:withRange:)))) real_setRange = (void*)method_setImplementation(m, (IMP)my_setRange);
}
uint32_t vk_constant_values(MTLFunctionConstantValues* cv, wbuf* out) {
	pthread_mutex_lock(&g_cv_lock);
	NSArray* a = [[[g_cv_records objectForKey:cv] copy] autorelease];
	pthread_mutex_unlock(&g_cv_lock);
	uint32_t n = 0;
	for (NSArray* e in a) {
		id key = e[0];
		NSData* d = e[2];
		vkmtl_fconst fc = { 0, (uint32_t)[e[1] unsignedIntValue], (uint32_t)d.length, 0 };
		const char* name = NULL;
		if ([key isKindOfClass:[NSString class]]) { fc.index = ~0u; name = [key UTF8String]; fc.nameLen = (uint32_t)strlen(name); }
		else fc.index = [key unsignedIntValue];
		wb_put(out, &fc, sizeof(fc));
		if (name) wb_put(out, name, fc.nameLen);
		wb_put(out, d.bytes, d.length);
		n++;
	}
	if (cv && !a.count) VKLOG("function constant values %p: none recorded", cv);
	return n;
}

@interface VKMTLComputePipelineState : VKMTLObject {
@public
	NSUInteger _tew, _maxTotal, _staticTG;
	BOOL _icb;
}
@end
@implementation VKMTLComputePipelineState
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (NSUInteger)threadExecutionWidth { return _tew; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _maxTotal; }
- (NSUInteger)staticThreadgroupMemoryLength { return _staticTG; }
- (BOOL)supportIndirectCommandBuffers { return _icb; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _vkid; return r; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { (void)d; return 0; }
- (MTLShaderValidation)shaderValidation { return MTLShaderValidationDefault; }
- (MTLSize)requiredThreadsPerThreadgroup { return MTLSizeMake(0, 0, 0); }
- (uint64_t)uniqueIdentifier { return _vkid; }
// x86Sim: iOS 27 persistent-kernel / forward-progress queries on compute pipelines.
- (NSInteger)forwardProgressUsage { return 0; }
- (MTLSize)recommendedPersistentThreadgroupsPerGridForThreadsPerThreadgroup:(MTLSize)tpt {
	(void)tpt; return MTLSizeMake(0, 0, 0);
}
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [super dealloc]; }
@end

@interface VKMTLSamplerState : VKMTLObject {
@public
	uint64_t _rid;
}
@end
@implementation VKMTLSamplerState
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _rid; return r; }
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [super dealloc]; }
@end

@interface VKMTLComputeCommandEncoder : VKMTLEncoder {
@public
	MTLDispatchType _dispatchType;
}
@end
@implementation VKMTLComputeCommandEncoder
- (instancetype)initWithCB:(VKMTLCommandBuffer*)cb type:(MTLDispatchType)t {
	self = [super init];
	_cb = [cb retain];
	_dispatchType = t;
	uint32_t c[2] = { (uint32_t)t, 0 };
	[_cb addCommand:VKMTL_C_CS_BEGIN data:c size:sizeof(c)];
	return self;
}
- (MTLDispatchType)dispatchType { return _dispatchType; }
- (void)endEncoding { [_cb addCommand:VKMTL_C_CS_END data:NULL size:0]; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)p {
	uint64_t c = vid(p);
	[_cb keep:p];
	[_cb addCommand:VKMTL_C_CS_PIPELINE data:&c size:8];
}
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
	uint64_t c[3] = { vid(b), o, (uint32_t)i };
	[_cb keep:b];
	[_cb addCommand:VKMTL_C_CS_BUFFER data:c size:sizeof(c)];
}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained*)bs offsets:(const NSUInteger*)os withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self setBuffer:bs[k] offset:os ? os[k] : 0 atIndex:r.location + k];
}
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { (void)s; [self setBuffer:b offset:o atIndex:i]; }
- (void)setBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {
	uint64_t c[2] = { o, (uint32_t)i };
	[_cb addCommand:VKMTL_C_CS_BUFFER_OFFSET data:c size:sizeof(c)];
}
- (void)setBytes:(const void*)p length:(NSUInteger)n atIndex:(NSUInteger)i {
	wbuf b = { 0 };
	wb_u32(&b, (uint32_t)i); wb_u32(&b, (uint32_t)n); wb_put(&b, p, n);
	[_cb addCommand:VKMTL_C_CS_BYTES data:b.p size:(uint32_t)b.n];
	free(b.p);
}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {
	uint64_t c[2] = { vid(t), (uint32_t)i };
	[_cb keep:t];
	[_cb addCommand:VKMTL_C_CS_TEXTURE data:c size:sizeof(c)];
}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained*)ts withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self setTexture:ts[k] atIndex:r.location + k];
}
- (void)vkSampler:(id<MTLSamplerState>)s index:(NSUInteger)i lod:(BOOL)lod min:(float)mn max:(float)mx {
	struct { uint64_t s; uint32_t index, hasLod; float mn, mx; } c = { vid(s), (uint32_t)i, lod, mn, mx };
	[_cb keep:s];
	[_cb addCommand:VKMTL_C_CS_SAMPLER data:&c size:sizeof(c)];
}
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self vkSampler:s index:i lod:NO min:0 max:0]; }
- (void)setSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)mn lodMaxClamp:(float)mx atIndex:(NSUInteger)i {
	[self vkSampler:s index:i lod:YES min:mn max:mx];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained*)ss withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self setSamplerState:ss[k] atIndex:r.location + k];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained*)ss lodMinClamps:(const float*)mn lodMaxClamps:(const float*)mx withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self setSamplerState:ss[k] lodMinClamp:mn[k] lodMaxClamp:mx[k] atIndex:r.location + k];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)n atIndex:(NSUInteger)i {
	uint32_t c[2] = { (uint32_t)n, (uint32_t)i };
	[_cb addCommand:VKMTL_C_CS_TGMEM data:c size:sizeof(c)];
}
- (void)vkDispatch:(uint32_t)kind grid:(MTLSize)g group:(MTLSize)t {
	struct { uint32_t kind, pad; uint64_t g[3], t[3]; } c = { kind, 0, { g.width, g.height, g.depth }, { t.width, t.height, t.depth } };
	[_cb addCommand:VKMTL_C_CS_DISPATCH data:&c size:sizeof(c)];
}
- (void)dispatchThreads:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { [self vkDispatch:0 grid:g group:t]; }
- (void)dispatchThreadgroups:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { [self vkDispatch:1 grid:g group:t]; }
- (void)memoryBarrierWithScope:(MTLBarrierScope)s {
	uint64_t c = s;
	[_cb addCommand:VKMTL_C_CS_BARRIER data:&c size:8];
}
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained*)r count:(NSUInteger)n {
	(void)r; (void)n;
	[self memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {
	if (!r) return;
	struct { uint64_t id; uint32_t usage, isTex; } c = { vid(r), (uint32_t)u, [(id)r isKindOfClass:[VKMTLTexture class]] };
	[_cb keep:r];
	[_cb addCommand:VKMTL_C_CS_USE data:&c size:sizeof(c)];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { (void)s; [self useResource:r usage:u]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained*)rs count:(NSUInteger)n usage:(MTLResourceUsage)u {
	for (NSUInteger k = 0; k < n; k++) [self useResource:rs[k] usage:u];
}
- (void)useHeap:(id<MTLHeap>)h { (void)h; VKLOG("useHeap: heaps are not implemented"); }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained*)h count:(NSUInteger)n { (void)h; (void)n; VKLOG("useHeaps: heaps are not implemented"); }
- (void)setImageblockWidth:(NSUInteger)w height:(NSUInteger)h { (void)w; (void)h; }
@end

// ---------------------------------------------------------------------------------------------------------
// Stage 5: render pipeline states, depth-stencil states, render encoders

@interface VKMTLRenderPipelineState : VKMTLObject
@end
@implementation VKMTLRenderPipelineState
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _vkid; return r; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 0; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLShaderValidation)shaderValidation { return MTLShaderValidationDefault; }
- (uint64_t)uniqueIdentifier { return _vkid; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { (void)d; return 0; }
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [super dealloc]; }
@end

@interface VKMTLDepthStencilState : VKMTLObject
@end
@implementation VKMTLDepthStencilState
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _vkid; return r; }
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [super dealloc]; }
@end

// The encoder records into its own list; endEncoding sends the pass (with the store actions known by then), the
// list, and RE_END to the command buffer.
@interface VKMTLRenderCommandEncoder : VKMTLEncoder {
@public
	vkmtl_pass _pass;
	wbuf _rc;
	uint32_t _rcount;
	BOOL _ended;
}
@end

@implementation VKMTLRenderCommandEncoder
static void vk_att(vkmtl_attachment* a, MTLRenderPassAttachmentDescriptor* d, VKMTLCommandBuffer* cb) {
	a->texture = vid(d.texture);
	if (d.texture) [cb keep:d.texture];
	a->level = (uint32_t)d.level; a->slice = (uint32_t)d.slice; a->depthPlane = (uint32_t)d.depthPlane;
	a->loadAction = (uint32_t)d.loadAction; a->storeAction = (uint32_t)d.storeAction;
	a->resolveTexture = vid(d.resolveTexture);
	if (d.resolveTexture) [cb keep:d.resolveTexture];
	a->resolveLevel = (uint32_t)d.resolveLevel; a->resolveSlice = (uint32_t)d.resolveSlice;
}
- (instancetype)initWithPass:(MTLRenderPassDescriptor*)p cb:(VKMTLCommandBuffer*)cb {
	self = [super init];
	_cb = [cb retain];
	memset(&_pass, 0, sizeof(_pass));
	for (int i = 0; i < VKMTL_MAX_COLOR; i++) {
		MTLRenderPassColorAttachmentDescriptor* c = p.colorAttachments[i];
		if (!c.texture) continue;
		vk_att(&_pass.color[i], c, cb);
		MTLClearColor cc = c.clearColor;
		_pass.color[i].clear[0] = cc.red; _pass.color[i].clear[1] = cc.green; _pass.color[i].clear[2] = cc.blue; _pass.color[i].clear[3] = cc.alpha;
	}
	if (p.depthAttachment.texture) { vk_att(&_pass.depth, p.depthAttachment, cb); _pass.depth.clear[0] = p.depthAttachment.clearDepth; }
	if (p.stencilAttachment.texture) { vk_att(&_pass.stencil, p.stencilAttachment, cb); _pass.stencil.clear[1] = p.stencilAttachment.clearStencil; }
	_pass.renderTargetWidth = p.renderTargetWidth; _pass.renderTargetHeight = p.renderTargetHeight;
	_pass.renderTargetArrayLength = p.renderTargetArrayLength; _pass.defaultRasterSampleCount = p.defaultRasterSampleCount;
	return self;
}
- (void)dealloc { free(_rc.p); [super dealloc]; }
- (void)cmd:(uint32_t)kind data:(const void*)d size:(uint32_t)n {
	wb_u32(&_rc, kind); wb_u32(&_rc, n); wb_put(&_rc, d, n);
	_rcount++;
}
- (void)endEncoding {
	if (_ended) return;
	_ended = YES;
	// unknown store actions (the app never set them): store; a multisample attachment with a resolve texture resolves
	vkmtl_attachment* all[VKMTL_MAX_COLOR + 2];
	for (int i = 0; i < VKMTL_MAX_COLOR; i++) all[i] = &_pass.color[i];
	all[VKMTL_MAX_COLOR] = &_pass.depth; all[VKMTL_MAX_COLOR + 1] = &_pass.stencil;
	for (int i = 0; i < VKMTL_MAX_COLOR + 2; i++)
		if (all[i]->storeAction == MTLStoreActionUnknown) all[i]->storeAction = all[i]->resolveTexture ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
	[_cb addCommand:VKMTL_C_RENDER_PASS data:&_pass size:sizeof(_pass)];
	[_cb appendCommands:_rc.p size:_rc.n count:_rcount];
	[_cb addCommand:VKMTL_C_RE_END data:NULL size:0];
}
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i { if (i < VKMTL_MAX_COLOR) _pass.color[i].storeAction = (uint32_t)a; }
- (void)setDepthStoreAction:(MTLStoreAction)a { _pass.depth.storeAction = (uint32_t)a; }
- (void)setStencilStoreAction:(MTLStoreAction)a { _pass.stencil.storeAction = (uint32_t)a; }
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)o atIndex:(NSUInteger)i { (void)o; (void)i; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)o { (void)o; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)o { (void)o; }

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p {
	uint64_t c = vid(p);
	[_cb keep:p];
	[self cmd:VKMTL_C_RE_PIPELINE data:&c size:8];
}
- (void)vkBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o stage:(uint32_t)st index:(NSUInteger)i {
	struct { uint64_t b, o; uint32_t st, i; } c = { vid(b), o, st, (uint32_t)i };
	[_cb keep:b];
	[self cmd:VKMTL_C_RE_BUFFER data:&c size:sizeof(c)];
}
- (void)vkBufferOffset:(NSUInteger)o stage:(uint32_t)st index:(NSUInteger)i {
	struct { uint64_t o; uint32_t st, i; } c = { o, st, (uint32_t)i };
	[self cmd:VKMTL_C_RE_BUFFER_OFFSET data:&c size:sizeof(c)];
}
- (void)vkBytes:(const void*)p length:(NSUInteger)n stage:(uint32_t)st index:(NSUInteger)i {
	wbuf b = { 0 };
	wb_u32(&b, st); wb_u32(&b, (uint32_t)i); wb_u32(&b, (uint32_t)n); wb_u32(&b, 0); wb_put(&b, p, n);
	[self cmd:VKMTL_C_RE_BYTES data:b.p size:(uint32_t)b.n];
	free(b.p);
}
- (void)vkTexture:(id<MTLTexture>)t stage:(uint32_t)st index:(NSUInteger)i {
	struct { uint64_t t; uint32_t st, i; } c = { vid(t), st, (uint32_t)i };
	[_cb keep:t];
	[self cmd:VKMTL_C_RE_TEXTURE data:&c size:sizeof(c)];
}
- (void)vkSampler:(id<MTLSamplerState>)s stage:(uint32_t)st index:(NSUInteger)i lod:(BOOL)lod min:(float)mn max:(float)mx {
	struct { uint64_t s; uint32_t st, i, lod; float mn, mx; uint32_t pad; } c = { vid(s), st, (uint32_t)i, lod, mn, mx, 0 };
	[_cb keep:s];
	[self cmd:VKMTL_C_RE_SAMPLER data:&c size:sizeof(c)];
}
// vertex stage
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self vkBuffer:b offset:o stage:0 index:i]; }
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { (void)s; [self vkBuffer:b offset:o stage:0 index:i]; }
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained*)bs offsets:(const NSUInteger*)os withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkBuffer:bs[k] offset:os ? os[k] : 0 stage:0 index:r.location + k];
}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self vkBufferOffset:o stage:0 index:i]; }
- (void)setVertexBufferOffset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { (void)s; [self vkBufferOffset:o stage:0 index:i]; }
- (void)setVertexBytes:(const void*)p length:(NSUInteger)n atIndex:(NSUInteger)i { [self vkBytes:p length:n stage:0 index:i]; }
- (void)setVertexBytes:(const void*)p length:(NSUInteger)n attributeStride:(NSUInteger)s atIndex:(NSUInteger)i { (void)s; [self vkBytes:p length:n stage:0 index:i]; }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self vkTexture:t stage:0 index:i]; }
- (void)setVertexTextures:(const id<MTLTexture> __unsafe_unretained*)ts withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkTexture:ts[k] stage:0 index:r.location + k];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self vkSampler:s stage:0 index:i lod:NO min:0 max:0]; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)mn lodMaxClamp:(float)mx atIndex:(NSUInteger)i {
	[self vkSampler:s stage:0 index:i lod:YES min:mn max:mx];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained*)ss withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkSampler:ss[k] stage:0 index:r.location + k lod:NO min:0 max:0];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained*)ss lodMinClamps:(const float*)mn lodMaxClamps:(const float*)mx withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkSampler:ss[k] stage:0 index:r.location + k lod:YES min:mn[k] max:mx[k]];
}
// fragment stage
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self vkBuffer:b offset:o stage:1 index:i]; }
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained*)bs offsets:(const NSUInteger*)os withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkBuffer:bs[k] offset:os ? os[k] : 0 stage:1 index:r.location + k];
}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self vkBufferOffset:o stage:1 index:i]; }
- (void)setFragmentBytes:(const void*)p length:(NSUInteger)n atIndex:(NSUInteger)i { [self vkBytes:p length:n stage:1 index:i]; }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self vkTexture:t stage:1 index:i]; }
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained*)ts withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkTexture:ts[k] stage:1 index:r.location + k];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self vkSampler:s stage:1 index:i lod:NO min:0 max:0]; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)mn lodMaxClamp:(float)mx atIndex:(NSUInteger)i {
	[self vkSampler:s stage:1 index:i lod:YES min:mn max:mx];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained*)ss withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkSampler:ss[k] stage:1 index:r.location + k lod:NO min:0 max:0];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained*)ss lodMinClamps:(const float*)mn lodMaxClamps:(const float*)mx withRange:(NSRange)r {
	for (NSUInteger k = 0; k < r.length; k++) [self vkSampler:ss[k] stage:1 index:r.location + k lod:YES min:mn[k] max:mx[k]];
}
// fixed-function state
- (void)setViewport:(MTLViewport)v {
	double c[6] = { v.originX, v.originY, v.width, v.height, v.znear, v.zfar };
	[self cmd:VKMTL_C_RE_VIEWPORT data:c size:sizeof(c)];
}
- (void)setViewports:(const MTLViewport*)v count:(NSUInteger)n { if (n) [self setViewport:v[0]]; }
- (void)setScissorRect:(MTLScissorRect)r {
	uint64_t c[4] = { r.x, r.y, r.width, r.height };
	[self cmd:VKMTL_C_RE_SCISSOR data:c size:sizeof(c)];
}
- (void)setScissorRects:(const MTLScissorRect*)r count:(NSUInteger)n { if (n) [self setScissorRect:r[0]]; }
- (void)setCullMode:(MTLCullMode)m { uint32_t c[2] = { (uint32_t)m, 0 }; [self cmd:VKMTL_C_RE_CULL data:c size:8]; }
- (void)setFrontFacingWinding:(MTLWinding)w { uint32_t c[2] = { (uint32_t)w, 0 }; [self cmd:VKMTL_C_RE_WINDING data:c size:8]; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { uint32_t c[2] = { (uint32_t)m, 0 }; [self cmd:VKMTL_C_RE_FILL data:c size:8]; }
- (void)setDepthClipMode:(MTLDepthClipMode)m { uint32_t c[2] = { (uint32_t)m, 0 }; [self cmd:VKMTL_C_RE_DEPTH_CLIP data:c size:8]; }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)cl {
	struct { float b, s, cl; uint32_t pad; } c = { b, s, cl, 0 };
	[self cmd:VKMTL_C_RE_DEPTH_BIAS data:&c size:sizeof(c)];
}
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b {
	uint32_t c[2] = { f, b };
	[self cmd:VKMTL_C_RE_STENCIL_REF data:c size:8];
}
- (void)setStencilReferenceValue:(uint32_t)v { [self setStencilFrontReferenceValue:v backReferenceValue:v]; }
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
	float c[4] = { r, g, b, a };
	[self cmd:VKMTL_C_RE_BLEND_COLOR data:c size:sizeof(c)];
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)d {
	uint64_t c = vid(d);
	[_cb keep:d];
	[self cmd:VKMTL_C_RE_DSS data:&c size:8];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)m offset:(NSUInteger)o { (void)m; (void)o; }
- (void)setVertexAmplificationCount:(NSUInteger)n viewMappings:(const MTLVertexAmplificationViewMapping*)v { (void)n; (void)v; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m stages:(NSUInteger)s { (void)s; [self setTriangleFillMode:m]; }
- (void)textureBarrier {}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b { (void)s; (void)a; (void)b; }
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained*)r count:(NSUInteger)n afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b {
	(void)r; (void)n; (void)a; (void)b; }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {
	if (!r) return;
	struct { uint64_t id; uint32_t usage, isTex; } c = { vid(r), (uint32_t)u, [(id)r isKindOfClass:[VKMTLTexture class]] };
	[_cb keep:r];
	[self cmd:VKMTL_C_RE_USE data:&c size:sizeof(c)];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { (void)s; [self useResource:r usage:u]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained*)rs count:(NSUInteger)n usage:(MTLResourceUsage)u {
	for (NSUInteger k = 0; k < n; k++) [self useResource:rs[k] usage:u];
}
- (void)useResources:(const id<MTLResource> __unsafe_unretained*)rs count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)s {
	(void)s; [self useResources:rs count:n usage:u];
}
- (void)useHeap:(id<MTLHeap>)h { (void)h; VKLOG("useHeap: heaps are not implemented"); }
- (void)useHeap:(id<MTLHeap>)h stages:(MTLRenderStages)s { (void)h; (void)s; VKLOG("useHeap: heaps are not implemented"); }
// draws
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i baseInstance:(NSUInteger)bi {
	uint32_t c[6] = { (uint32_t)t, (uint32_t)s, (uint32_t)n, (uint32_t)i, (uint32_t)bi, 0 };
	[self cmd:VKMTL_C_RE_DRAW data:c size:sizeof(c)];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i {
	[self drawPrimitives:t vertexStart:s vertexCount:n instanceCount:i baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {
	[self drawPrimitives:t vertexStart:s vertexCount:n instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it indexBuffer:(id<MTLBuffer>)b
	indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi {
	struct { uint32_t t, n, it, i; uint64_t b, o; int32_t bv; uint32_t bi; } c = { (uint32_t)t, (uint32_t)n, (uint32_t)it, (uint32_t)i, vid(b), o, (int32_t)bv, (uint32_t)bi };
	[_cb keep:b];
	[self cmd:VKMTL_C_RE_DRAW_INDEXED data:&c size:sizeof(c)];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it indexBuffer:(id<MTLBuffer>)b
	indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i {
	[self drawIndexedPrimitives:t indexCount:n indexType:it indexBuffer:b indexBufferOffset:o instanceCount:i baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o {
	[self drawIndexedPrimitives:t indexCount:n indexType:it indexBuffer:b indexBufferOffset:o instanceCount:1 baseVertex:0 baseInstance:0];
}
// Platforms 1: indirect draws (watchOS face rendering uses both); the arguments stay in the buffer for mtlvk to read
- (void)drawPrimitives:(MTLPrimitiveType)t indirectBuffer:(id<MTLBuffer>)ib indirectBufferOffset:(NSUInteger)io {
	struct { uint32_t t, pad; uint64_t ib, io; } c = { (uint32_t)t, 0, vid(ib), io };
	[_cb keep:ib];
	[self cmd:VKMTL_C_RE_DRAW_INDIRECT data:&c size:sizeof(c)];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexType:(MTLIndexType)it indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o
	indirectBuffer:(id<MTLBuffer>)ib indirectBufferOffset:(NSUInteger)io {
	struct { uint32_t t, it; uint64_t b, o, ib, io; } c = { (uint32_t)t, (uint32_t)it, vid(b), o, vid(ib), io };
	[_cb keep:b];
	[_cb keep:ib];
	[self cmd:VKMTL_C_RE_DRAW_INDEXED_INDIRECT data:&c size:sizeof(c)];
}
@end

@implementation VKMTLCommandBuffer
- (instancetype)initWithQueue:(VKMTLCommandQueue*)q retained:(BOOL)retained {
	self = [super init];
	_vkid = vk_new_id();
	_queue = [q retain];
	_retained = retained;
	_status = MTLCommandBufferStatusNotEnqueued;
	_scheduled = [[NSMutableArray alloc] init];
	_completed = [[NSMutableArray alloc] init];
	_keep = [[NSMutableArray alloc] init];
	pthread_mutex_init(&_lock, NULL);
	pthread_cond_init(&_cond, NULL);
	return self;
}
- (void)dealloc {
	free(_cmds.p);
	[_queue release]; [_scheduled release]; [_completed release]; [_keep release]; [_error release];
	pthread_mutex_destroy(&_lock); pthread_cond_destroy(&_cond);
	[super dealloc];
}
- (void)keep:(id)o { if (o) [_keep addObject:o]; }
- (void)addCommand:(uint32_t)kind data:(const void*)d size:(uint32_t)n {
	wb_u32(&_cmds, kind); wb_u32(&_cmds, n); wb_put(&_cmds, d, n);
	_count++;
}
- (void)appendCommands:(const void*)d size:(size_t)n count:(uint32_t)count {
	if (n) wb_put(&_cmds, d, n);
	_count += count;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (id<MTLCommandQueue>)commandQueue { return (id<MTLCommandQueue>)_queue; }
- (BOOL)retainedReferences { return _retained; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (MTLCommandBufferStatus)status { return _status; }
- (NSError*)error { return _error; }
- (CFTimeInterval)GPUStartTime { return _start; }
- (CFTimeInterval)GPUEndTime { return _end; }
- (CFTimeInterval)kernelStartTime { return _start; }
- (CFTimeInterval)kernelEndTime { return _end; }
- (id<MTLLogContainer>)logs { return nil; }
- (void)pushDebugGroup:(NSString*)s { (void)s; }
- (void)popDebugGroup {}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
	VKMTLBlitCommandEncoder* e = [[VKMTLBlitCommandEncoder alloc] init];
	e->_cb = [self retain];
	return [(id<MTLBlitCommandEncoder>)e autorelease];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor*)d { (void)d; return [self blitCommandEncoder]; }
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor*)d {
	return [(id<MTLRenderCommandEncoder>)[[VKMTLRenderCommandEncoder alloc] initWithPass:d cb:self] autorelease];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t {
	return [(id<MTLComputeCommandEncoder>)[[VKMTLComputeCommandEncoder alloc] initWithCB:self type:t] autorelease];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder { return [self computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor*)d {
	return [self computeCommandEncoderWithDispatchType:d ? d.dispatchType : MTLDispatchTypeSerial];
}
- (void)encodeSignalEvent:(id<MTLEvent>)e value:(uint64_t)v {
	uint64_t c[2] = { vid(e), v };
	[self keep:e];
	[self addCommand:VKMTL_C_SIGNAL data:c size:sizeof(c)];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)e value:(uint64_t)v {
	uint64_t c[2] = { vid(e), v };
	[self keep:e];
	[self addCommand:VKMTL_C_WAIT data:c size:sizeof(c)];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)e value:(uint64_t)v timeout:(uint64_t)t { (void)t; [self encodeWaitForEvent:e value:v]; }
- (void)presentDrawable:(id<MTLDrawable>)d { (void)d; }
- (void)addScheduledHandler:(MTLCommandBufferHandler)b { @synchronized (self) { [_scheduled addObject:[[b copy] autorelease]]; } }
- (void)addCompletedHandler:(MTLCommandBufferHandler)b {
	BOOL now = NO;
	@synchronized (self) {
		if (_status >= MTLCommandBufferStatusCompleted) now = YES;
		else [_completed addObject:[[b copy] autorelease]];
	}
	if (now) b((id<MTLCommandBuffer>)self);
}
- (void)enqueue { if (_status < MTLCommandBufferStatusEnqueued) _status = MTLCommandBufferStatusEnqueued; }
- (void)commit {
	if (_status >= MTLCommandBufferStatusCommitted) { VKLOG("command buffer committed twice"); return; }
	_status = MTLCommandBufferStatusCommitted;
	pthread_mutex_lock(&g_inflight_lock);
	if (!g_inflight) g_inflight = [[NSMutableDictionary alloc] init];
	g_inflight[@(_vkid)] = self;
	pthread_mutex_unlock(&g_inflight_lock);
	// x86Sim: scheduled handlers run before the command buffer goes to mtlvk. Run after it, a fast completion (on the
	// completion queue) could call the completed handlers first: MTLSimImplementation then sent the client "completed"
	// (message 101, the client drops the command buffer's ref) before "scheduled" (100), and the client crashed looking
	// the ref up (SpringBoard SIGSEGV in -[MTLSimDevice commandBufferForReference:]). Metal always
	// reports scheduled before completed.
	NSArray* sched;
	@synchronized (self) {
		if (_status < MTLCommandBufferStatusScheduled) _status = MTLCommandBufferStatusScheduled;
		sched = [_scheduled copy];
		[_scheduled removeAllObjects];
	}
	for (MTLCommandBufferHandler h in sched) h((id<MTLCommandBuffer>)self);
	[sched release];
	vk_push_copied();
	wbuf b = { 0 };
	wb_u64(&b, _queue->_vkid); wb_u64(&b, _vkid); wb_u32(&b, _count); wb_u32(&b, 0);
	wb_put(&b, _cmds.p, _cmds.n);
	VKTRACE("commit cb %llu: %u commands, %zu bytes", _vkid, _count, _cmds.n);
	vk_send(VKMTL_CB_COMMIT, b.p, (uint32_t)b.n);
	free(b.p);
	pthread_mutex_lock(&_lock);
	pthread_cond_broadcast(&_cond);
	pthread_mutex_unlock(&_lock);
}
- (void)finishWithStatus:(uint32_t)st error:(uint32_t)er start:(double)t0 end:(double)t1 {
	vk_pull_copied();
	NSArray* done;
	@synchronized (self) {
		_start = t0; _end = t1;
		if (st != MTLCommandBufferStatusCompleted) {
			_error = [[NSError alloc] initWithDomain:MTLCommandBufferErrorDomain code:er ?: MTLCommandBufferErrorInternal userInfo:nil];
			VKLOG("command buffer %llu failed (status %u error %u)", _vkid, st, er);
		}
		_status = st;
		done = [_completed copy];
		[_completed removeAllObjects];
	}
	for (MTLCommandBufferHandler h in done) h((id<MTLCommandBuffer>)self);
	[done release];
	[_keep removeAllObjects];
	pthread_mutex_lock(&_lock);
	pthread_cond_broadcast(&_cond);
	pthread_mutex_unlock(&_lock);
	vk_check_all_listeners();
}
- (void)waitUntilScheduled {
	pthread_mutex_lock(&_lock);
	while (_status < MTLCommandBufferStatusScheduled) pthread_cond_wait(&_cond, &_lock);
	pthread_mutex_unlock(&_lock);
}
- (void)waitUntilCompleted {
	pthread_mutex_lock(&_lock);
	while (_status < MTLCommandBufferStatusCompleted && g_sock >= 0) pthread_cond_wait(&_cond, &_lock);
	pthread_mutex_unlock(&_lock);
}
@end

static void vk_cb_done(uint64_t cbid, uint32_t status, uint32_t error, double start, double end) {
	pthread_mutex_lock(&g_inflight_lock);
	VKMTLCommandBuffer* cb = [g_inflight[@(cbid)] retain];
	[g_inflight removeObjectForKey:@(cbid)];
	pthread_mutex_unlock(&g_inflight_lock);
	if (!cb) { VKLOG("completion for unknown command buffer %llu", cbid); return; }
	VKTRACE("cb %llu done: status %u", cbid, status);
	dispatch_async(g_completion_queue, ^{
		@autoreleasepool { [cb finishWithStatus:status error:error start:start end:end]; }
		[cb release];
	});
}

@implementation VKMTLCommandQueue
- (id<MTLDevice>)device { return (id<MTLDevice>)g_device; }
- (id<MTLCommandBuffer>)commandBuffer {
	return [(id<MTLCommandBuffer>)[[VKMTLCommandBuffer alloc] initWithQueue:self retained:YES] autorelease];
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences {
	return [(id<MTLCommandBuffer>)[[VKMTLCommandBuffer alloc] initWithQueue:self retained:NO] autorelease];
}
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor*)d {
	return [(id<MTLCommandBuffer>)[[VKMTLCommandBuffer alloc] initWithQueue:self retained:d.retainedReferences] autorelease];
}
- (void)insertDebugCaptureBoundary {}
- (void)setMaxCommandBufferCount:(NSUInteger)n { _max = n; }
- (NSUInteger)maxCommandBufferCount { return _max; }
- (void)dealloc { vk_send(VKMTL_OBJ_DEL, &_vkid, 8); [super dealloc]; }
@end

// ---------------------------------------------------------------------------------------------------------
// Device

@implementation VKMTLDevice
- (NSString*)name { return _name; }
- (uint64_t)registryID { return _registryID; }
- (NSUInteger)featureProfile { return _profile; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return YES; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return _unified; }
- (uint64_t)recommendedMaxWorkingSetSize { return _workingSet; }
- (NSUInteger)maxBufferLength { return _maxBufferLength; }
- (NSUInteger)currentAllocatedSize { return 0; }
- (NSUInteger)location { return 1; /* MTLDeviceLocationSlot */ }
- (NSUInteger)locationNumber { return 0; }
- (uint64_t)maxTransferRate { return 0; }
- (uint64_t)peerGroupID { return 0; }
- (uint32_t)peerIndex { return 0; }
- (uint32_t)peerCount { return 0; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 64); }
- (NSUInteger)maxThreadgroupMemoryLength { return 32768; }
// per-stage binding-table sizes (MetalSerializer checks encoder ranges against them)
- (NSUInteger)maxComputeBuffers { return 31; }
- (NSUInteger)maxComputeTextures { return 128; }
- (NSUInteger)maxComputeSamplers { return 16; }
- (NSUInteger)maxVertexBuffers { return 31; }
- (NSUInteger)maxVertexTextures { return 128; }
- (NSUInteger)maxVertexSamplers { return 16; }
- (NSUInteger)maxFragmentBuffers { return 31; }
- (NSUInteger)maxFragmentTextures { return 128; }
- (NSUInteger)maxFragmentSamplers { return 16; }
- (NSUInteger)maxViewportCount { return 16; }
// one entry per threadgroup-memory index (the deserializer checks setThreadgroupMemoryLength's index < count)
- (NSArray*)maxComputeLocalMemorySizes {
	static NSArray* a;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableArray* m = [NSMutableArray array];
		for (int i = 0; i < 31; i++) [m addObject:@32768];
		a = [m copy];
	});
	return a;
}
- (NSUInteger)maxArgumentBufferSamplerCount { return 1024; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier2; }
- (MTLReadWriteTextureTier)readWriteTextureSupport { return MTLReadWriteTextureTier2; }
- (BOOL)areProgrammableSamplePositionsSupported { return NO; }
- (BOOL)areRasterOrderGroupsSupported { return NO; }
- (BOOL)supports32BitFloatFiltering { return YES; }
- (BOOL)supports32BitMSAA { return YES; }
- (BOOL)supportsBCTextureCompression { return YES; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { return NO; }
- (BOOL)supportsQueryTextureLOD { return YES; }
- (BOOL)supportsPullModelInterpolation { return NO; }
- (BOOL)supportsShaderBarycentricCoordinates { return NO; }
- (BOOL)supportsFunctionPointers { return NO; }
- (BOOL)supportsRaytracing { return NO; }
- (BOOL)supportsDynamicLibraries { return NO; }
// x86Sim: iOS 27 Metal sim device queries (MTLSimDriver / MTLSimImplementation 24A434). supportsFP8 and
// set*GlobalConstantsBase/Size: were removed; getters for *GlobalConstants* still exist on the client and
// fall through forwardInvocation (nil/0). These stubs avoid unimplemented spam and match Common3/Mac2.
- (BOOL)supportsPVRTC { return NO; }
- (BOOL)supportsRGBTextureBuffers { return YES; }
- (BOOL)supportsTextureMultifetch { return NO; }
- (BOOL)supportsMXUNarrowTileSizes { return NO; }
- (BOOL)supportsMXU { return NO; }
- (BOOL)supportsSIMDGroupParallelForwardProgress { return NO; }
- (void)useInternalResidencySet:(id)set { (void)set; }
- (void)useInternalResidencySets:(const id*)sets count:(NSUInteger)count { (void)sets; (void)count; }
- (id)genericAddressSpaceDispatchInfo { return nil; }
- (BOOL)supportsTextureSampleCount:(NSUInteger)n { return n == 1 || n == 2 || n == 4 || n == 8; }
- (BOOL)supportsFamily:(MTLGPUFamily)f {
	return f == MTLGPUFamilyMac2 || f == MTLGPUFamilyCommon1 || f == MTLGPUFamilyCommon2 || f == MTLGPUFamilyCommon3;
}
- (BOOL)supportsFeatureSet:(MTLFeatureSet)fs { (void)fs; return NO; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)f { (void)f; return 256; }
// x86Sim: MetalSerializer's validateIOSurfaceDescriptor requires bytesPerRow % this == 0 (0 fails everything);
// mtlvk's runtime takes any row pitch (it copies where Vulkan's linear images can't alias the rows)
- (NSUInteger)iosurfaceTextureAlignmentBytes { return 16; }
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes { return 16; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)f { (void)f; return 256; }
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)len options:(MTLResourceOptions)o {
	(void)o; MTLSizeAndAlign r = { (len + 4095) & ~(NSUInteger)4095, 4096 }; return r; }
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor*)d {
	NSUInteger bpp = vk_bytes_per_pixel(d.pixelFormat) ?: 4;
	MTLSizeAndAlign r = { ((d.width * d.height * d.depth * d.arrayLength * bpp * 2) + 65535) & ~(NSUInteger)65535, 65536 }; return r; }
- (BOOL)allowLibrariesFromOtherPlatforms { return YES; }
- (void)setAllowLibrariesFromOtherPlatforms:(BOOL)b { (void)b; }
- (BOOL)shouldMaximizeConcurrentCompilation { return NO; }
- (void)setShouldMaximizeConcurrentCompilation:(BOOL)b { (void)b; }
- (NSUInteger)maximumConcurrentCompilationTaskCount { return 1; }

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)opts {
	size_t map = (MAX(len, 1) + 4095) & ~(size_t)4095;
	void* p = mmap(NULL, map, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (p == MAP_FAILED) return nil;
	VKMTLBuffer* b = [[VKMTLBuffer alloc] initWithPointer:p length:len options:opts owned:map];
	if (!b) munmap(p, map);
	return (id<MTLBuffer>)b;
}
- (id<MTLBuffer>)newBufferWithBytes:(const void*)bytes length:(NSUInteger)len options:(MTLResourceOptions)opts {
	size_t map = (MAX(len, 1) + 4095) & ~(size_t)4095;
	void* p = mmap(NULL, map, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (p == MAP_FAILED) return nil;
	memcpy(p, bytes, len);
	VKMTLBuffer* b = [[VKMTLBuffer alloc] initWithPointer:p length:len options:opts owned:map];
	if (!b) munmap(p, map);
	return (id<MTLBuffer>)b;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void*)p length:(NSUInteger)len options:(MTLResourceOptions)opts deallocator:(void (^)(void*, NSUInteger))d {
	VKMTLBuffer* b = [[VKMTLBuffer alloc] initWithPointer:p length:len options:opts owned:0];
	if (b && d) b->_deallocator = [d copy];
	return (id<MTLBuffer>)b;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor*)d {
	return (id<MTLTexture>)[[VKMTLTexture alloc] initWithDescriptor:d];
}
- (id<MTLCommandQueue>)newCommandQueue { return [self newCommandQueueWithMaxCommandBufferCount:64]; }
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n {
	VKMTLCommandQueue* q = [[VKMTLCommandQueue alloc] init];
	q->_vkid = vk_new_id();
	q->_max = n;
	vk_send(VKMTL_QUEUE_NEW, &q->_vkid, 8);
	return (id<MTLCommandQueue>)q;
}
- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor*)d {
	return [self newCommandQueueWithMaxCommandBufferCount:d.maxCommandBufferCount];
}
- (id<MTLSharedEvent>)newSharedEvent { return (id<MTLSharedEvent>)[[VKMTLSharedEvent alloc] initShared:YES]; }
- (id<MTLSharedEvent>)newSharedEventWithOptions:(NSUInteger)o { (void)o; return [self newSharedEvent]; }
- (id<MTLEvent>)newEvent { return (id<MTLEvent>)[[VKMTLSharedEvent alloc] initShared:NO]; }
- (id<MTLFence>)newFence { VKMTLFence* f = [[VKMTLFence alloc] init]; f->_vkid = vk_new_id(); return (id<MTLFence>)f; }
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError**)error {
	const void* p = NULL; size_t n = 0;
	dispatch_data_t map = dispatch_data_create_map(data, &p, &n);
	VKMTLLibrary* l = [[VKMTLLibrary alloc] initWithBytes:p length:n error:error];
	[map release];
	return (id<MTLLibrary>)l;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL*)url error:(NSError**)error {
	NSData* d = [NSData dataWithContentsOfURL:url options:0 error:error];
	return d ? (id<MTLLibrary>)[[VKMTLLibrary alloc] initWithBytes:d.bytes length:d.length error:error] : nil;
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString*)path error:(NSError**)error { return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:error]; }
- (id<MTLComputePipelineState>)vkComputeWithFunction:(id<MTLFunction>)f maxTotal:(NSUInteger)maxTotal multiple:(BOOL)multiple icb:(BOOL)icb
	label:(NSString*)label error:(NSError**)error {
	if (![(id)f isKindOfClass:[VKMTLFunction class]]) {
		VKLOG("compute pipeline: function %s is not ours", f ? class_getName([(id)f class]) : "nil");
		if (error) *error = vk_error(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "no function", 11);
		return nil;
	}
	uint64_t id_ = vk_new_id();
	wbuf b = { 0 };
	wb_u64(&b, id_); wb_u64(&b, vid(f)); wb_u32(&b, (uint32_t)maxTotal); wb_u32(&b, multiple);
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_CPS_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	int32_t st = -1;
	if (r && rs >= 16) memcpy(&st, r, 4);
	if (st != 0) {
		NSError* e = vk_reply_error(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, r, rs, 16);
		VKLOG("compute pipeline %s: mtlvk refused: %s", f.name.UTF8String, e.localizedDescription.UTF8String);
		if (error) *error = e;
		free(r);
		return nil;
	}
	VKMTLComputePipelineState* p = [[VKMTLComputePipelineState alloc] init];
	p->_vkid = id_;
	uint32_t v[3]; memcpy(v, r + 4, 12);
	p->_tew = v[0]; p->_maxTotal = v[1]; p->_staticTG = v[2]; p->_icb = icb;
	p.label = label;
	free(r);
	VKTRACE("compute pipeline %llu: %s width %lu max %lu", id_, f.name.UTF8String, (unsigned long)p->_tew, (unsigned long)p->_maxTotal);
	return (id<MTLComputePipelineState>)p;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError**)error {
	return [self vkComputeWithFunction:f maxTotal:0 multiple:NO icb:NO label:nil error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f options:(MTLPipelineOption)o
	reflection:(MTLAutoreleasedComputePipelineReflection*)refl error:(NSError**)error {
	(void)o;
	if (refl) *refl = nil;
	return [self vkComputeWithFunction:f maxTotal:0 multiple:NO icb:NO label:nil error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor*)d options:(MTLPipelineOption)o
	reflection:(MTLAutoreleasedComputePipelineReflection*)refl error:(NSError**)error {
	(void)o;
	if (refl) *refl = nil;
	return [self vkComputeWithFunction:d.computeFunction maxTotal:d.maxTotalThreadsPerThreadgroup
		multiple:d.threadGroupSizeIsMultipleOfThreadExecutionWidth icb:d.supportIndirectCommandBuffers label:d.label error:error];
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor*)d {
	vkmtl_samplerdesc sd = { (uint32_t)d.minFilter, (uint32_t)d.magFilter, (uint32_t)d.mipFilter, (uint32_t)d.sAddressMode,
		(uint32_t)d.tAddressMode, (uint32_t)d.rAddressMode, (uint32_t)d.borderColor, d.normalizedCoordinates, d.lodMinClamp, d.lodMaxClamp,
		d.lodAverage, (uint32_t)d.maxAnisotropy, (uint32_t)d.compareFunction, d.supportArgumentBuffers };
	uint64_t id_ = vk_new_id();
	wbuf b = { 0 };
	wb_u64(&b, id_); wb_put(&b, &sd, sizeof(sd));
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_SAMPLER_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	int32_t st = -1;
	if (r && rs >= 16) memcpy(&st, r, 4);
	if (st != 0) { VKLOG("sampler: mtlvk refused"); free(r); return nil; }
	VKMTLSamplerState* s = [[VKMTLSamplerState alloc] init];
	s->_vkid = id_;
	memcpy(&s->_rid, r + 8, 8);
	s.label = d.label;
	free(r);
	return (id<MTLSamplerState>)s;
}
// x86Sim: stage 5
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor*)d iosurface:(IOSurfaceRef)s plane:(NSUInteger)plane {
	if (!s) return nil;
	// the surface's memory in this process (mapped from iosurfaced's MemoryObject): a buffer over it (memfd, syscall
	// 599) and the plane's texture over that buffer -- the GPU renders into the same pages every process maps
	void* base = IOSurfaceGetBaseAddress(s);
	size_t alloc = IOSurfaceGetAllocSize(s);
	size_t planes = IOSurfaceGetPlaneCount(s);
	size_t off = planes ? (size_t)((char*)IOSurfaceGetBaseAddressOfPlane(s, plane) - (char*)base) : 0;
	size_t bpr = planes ? IOSurfaceGetBytesPerRowOfPlane(s, plane) : IOSurfaceGetBytesPerRow(s);
	if (!base || !alloc) { VKLOG("IOSurface %u: no memory (emulated IOSurfaces are per-process: is iosurfaced running?)", IOSurfaceGetID(s)); return nil; }
	VKMTLBuffer* b = [[VKMTLBuffer alloc] initWithPointer:base length:alloc options:MTLResourceStorageModeShared owned:0];
	if (!b) return nil;
	if (b->_copied) VKLOG("IOSurface %u: mtlvk could not import its pages: the texture is a copy", IOSurfaceGetID(s));
	VKMTLTexture* t = [[VKMTLTexture alloc] initWithDescriptor:d buffer:b offset:off bytesPerRow:bpr iosurface:s plane:plane planar:planes > 0];
	VKTRACE("IOSurface %u '%.4s' %zux%zu plane %lu -> texture %llu", IOSurfaceGetID(s), (char*)&(OSType){ IOSurfaceGetPixelFormat(s) },
		IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), (unsigned long)plane, t ? t->_vkid : 0);
	[b release];
	return (id<MTLTexture>)t;
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor*)d {
	vkmtl_dssdesc dd = { (uint32_t)d.depthCompareFunction, d.depthWriteEnabled };
	MTLStencilDescriptor* faces[2] = { d.frontFaceStencil, d.backFaceStencil };
	vkmtl_stencil* out[2] = { &dd.front, &dd.back };
	for (int i = 0; i < 2; i++) {
		MTLStencilDescriptor* f = faces[i];
		if (!f) continue;
		*out[i] = (vkmtl_stencil){ 1, (uint32_t)f.stencilCompareFunction, (uint32_t)f.stencilFailureOperation, (uint32_t)f.depthFailureOperation,
			(uint32_t)f.depthStencilPassOperation, f.readMask, f.writeMask, 0 };
	}
	uint64_t id_ = vk_new_id();
	wbuf b = { 0 };
	wb_u64(&b, id_); wb_put(&b, &dd, sizeof(dd));
	uint32_t rs = 0;
	int32_t* r = vk_call(VKMTL_DSS_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	if (!r || rs < 4 || r[0] != 0) { VKLOG("depth-stencil state: mtlvk refused"); free(r); return nil; }
	free(r);
	VKMTLDepthStencilState* s = [[VKMTLDepthStencilState alloc] init];
	s->_vkid = id_;
	s.label = d.label;
	return (id<MTLDepthStencilState>)s;
}
- (id<MTLRenderPipelineState>)vkRenderWithDescriptor:(MTLRenderPipelineDescriptor*)d error:(NSError**)error {
	id vf = d.vertexFunction, ff = d.fragmentFunction;
	if (![vf isKindOfClass:[VKMTLFunction class]] || (ff && ![ff isKindOfClass:[VKMTLFunction class]])) {
		VKLOG("render pipeline: functions %s/%s are not ours", vf ? class_getName([vf class]) : "nil", ff ? class_getName([ff class]) : "nil");
		if (error) *error = vk_error(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "no function", 11);
		return nil;
	}
	vkmtl_rpsdesc rd;
	memset(&rd, 0, sizeof(rd));
	rd.vertexFunction = vid(vf); rd.fragmentFunction = vid(ff);
	for (int i = 0; i < 8; i++) {
		MTLRenderPipelineColorAttachmentDescriptor* c = d.colorAttachments[i];
		if (!c || c.pixelFormat == MTLPixelFormatInvalid) continue;
		rd.color[i] = (vkmtl_colorattachment){ (uint32_t)c.pixelFormat, c.blendingEnabled, (uint32_t)c.sourceRGBBlendFactor,
			(uint32_t)c.destinationRGBBlendFactor, (uint32_t)c.rgbBlendOperation, (uint32_t)c.sourceAlphaBlendFactor,
			(uint32_t)c.destinationAlphaBlendFactor, (uint32_t)c.alphaBlendOperation, (uint32_t)c.writeMask, 0 };
	}
	rd.depthFormat = (uint32_t)d.depthAttachmentPixelFormat; rd.stencilFormat = (uint32_t)d.stencilAttachmentPixelFormat;
	rd.rasterSampleCount = (uint32_t)(d.rasterSampleCount ?: 1);
	rd.alphaToCoverage = d.alphaToCoverageEnabled; rd.alphaToOne = d.alphaToOneEnabled;
	rd.rasterizationEnabled = d.rasterizationEnabled;
	rd.inputPrimitiveTopology = (uint32_t)d.inputPrimitiveTopology;
	wbuf lay = { 0 }, att = { 0 };
	MTLVertexDescriptor* vd = d.vertexDescriptor;
	uint32_t used = 0;  // layouts the attributes use
	for (uint32_t i = 0; vd && i < 31; i++) {
		MTLVertexAttributeDescriptor* a = vd.attributes[i];
		if (!a || a.format == MTLVertexFormatInvalid) continue;
		vkmtl_vattr va = { i, (uint32_t)a.format, (uint32_t)a.offset, (uint32_t)a.bufferIndex };
		wb_put(&att, &va, sizeof(va));
		rd.nattrs++;
		if (a.bufferIndex < 32) used |= 1u << a.bufferIndex;
	}
	for (uint32_t i = 0; vd && i < 31; i++) {
		MTLVertexBufferLayoutDescriptor* l = vd.layouts[i];
		if (!l || !(used & (1u << i))) continue;
		vkmtl_vlayout vl = { i, (uint32_t)l.stride, (uint32_t)l.stepFunction, (uint32_t)l.stepRate };
		wb_put(&lay, &vl, sizeof(vl));
		rd.nlayouts++;
	}
	rd.hasVertexDescriptor = rd.nattrs > 0;
	uint64_t id_ = vk_new_id();
	wbuf b = { 0 };
	wb_u64(&b, id_); wb_put(&b, &rd, sizeof(rd));
	if (lay.n) wb_put(&b, lay.p, lay.n);
	if (att.n) wb_put(&b, att.p, att.n);
	free(lay.p); free(att.p);
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_RPS_NEW, b.p, (uint32_t)b.n, &rs);
	free(b.p);
	int32_t st = -1;
	if (r && rs >= 8) memcpy(&st, r, 4);
	if (st != 0) {
		NSError* e = vk_reply_error(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, r, rs, 8);
		VKLOG("render pipeline %s/%s: mtlvk refused: %s", [vf name].UTF8String, ff ? [ff name].UTF8String : "-", e.localizedDescription.UTF8String);
		if (error) *error = e;
		free(r);
		return nil;
	}
	free(r);
	VKMTLRenderPipelineState* p = [[VKMTLRenderPipelineState alloc] init];
	p->_vkid = id_;
	p.label = d.label;
	VKTRACE("render pipeline %llu: %s/%s", id_, [vf name].UTF8String, ff ? [ff name].UTF8String : "-");
	return (id<MTLRenderPipelineState>)p;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor*)d error:(NSError**)error {
	return [self vkRenderWithDescriptor:d error:error];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor*)d options:(MTLPipelineOption)o
	reflection:(MTLAutoreleasedRenderPipelineReflection*)refl error:(NSError**)error {
	(void)o;
	if (refl) *refl = nil;
	return [self vkRenderWithDescriptor:d error:error];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor*)d completionHandler:(MTLNewRenderPipelineStateCompletionHandler)h {
	NSError* e = nil;
	id<MTLRenderPipelineState> p = [self vkRenderWithDescriptor:d error:&e];
	h(p, e);
	[p release];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor*)d options:(MTLPipelineOption)o
	completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)h {
	(void)o;
	NSError* e = nil;
	id<MTLRenderPipelineState> p = [self vkRenderWithDescriptor:d error:&e];
	h(p, nil, e);
	[p release];
}
- (void)getDefaultSamplePositions:(MTLSamplePosition*)p count:(NSUInteger)n {
	for (NSUInteger i = 0; i < n; i++) p[i] = MTLSamplePositionMake(0.5f, 0.5f);
}
@end

// ---------------------------------------------------------------------------------------------------------
// MTLCreateSystemDefaultDevice / MTLCopyAllDevices in this process

// Methods of Metal.framework's _MTLDevice that don't depend on the device (the pipeline-descriptor
// deserializers MetalSerializer calls on its device): added to VKMTLDevice with Apple's implementation.
static void vk_borrow_device_methods(void) {
	Class from = objc_getClass("_MTLDevice"), to = objc_getClass("VKMTLDevice");
	const char* sels[] = { "newComputePipelineDescriptorWithSerializedData:deserializationContext:",
		"newRenderPipelineDescriptorWithSerializedData:deserializationContext:",
		"newTileRenderPipelineDescriptorWithSerializedData:deserializationContext:",
		"newMeshRenderPipelineDescriptorWithSerializedData:deserializationContext:", NULL };
	for (int i = 0; sels[i]; i++) {
		Method m = from ? class_getInstanceMethod(from, sel_registerName(sels[i])) : NULL;
		if (m) class_addMethod(to, method_getName(m), method_getImplementation(m), method_getTypeEncoding(m));
		else VKLOG("_MTLDevice has no %s", sels[i]);
	}
}

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void vk_make_device(void) {
	g_verbose = getenv("X86SIM_VKMTL_LOG") != NULL;
	g_dump_libs = getenv("X86SIM_VKMTL_DUMP") != NULL;
	vk_hook_constant_values();
	vk_borrow_device_methods();
	g_completion_queue = dispatch_queue_create("vkmtl.completion", DISPATCH_QUEUE_SERIAL);
	if (vk_connect() < 0) return;
	uint32_t hello[2] = { VKMTL_VERSION, (uint32_t)getpid() };
	uint32_t rs = 0;
	char* r = vk_call(VKMTL_HELLO, hello, sizeof(hello), &rs);
	if (!r || rs < 32) { VKLOG("mtlvk did not answer HELLO"); free(r); return; }
	VKMTLDevice* d = [[VKMTLDevice alloc] init];
	memcpy(&d->_registryID, r, 8); memcpy(&d->_workingSet, r + 8, 8); memcpy(&d->_maxBufferLength, r + 16, 8);
	uint32_t unified, nl; memcpy(&unified, r + 24, 4); memcpy(&nl, r + 28, 4);
	d->_unified = unified != 0;
	d->_name = [[NSString alloc] initWithBytes:r + 32 length:MIN(nl, rs - 32) encoding:NSUTF8StringEncoding];
	free(r);
	// MTLDeviceFeatureProfile: 10001 = Mac2 + Common3 (a non-Apple GPU Mac: no tile shaders/imageblocks).
	// The client derives its GPU families and limits from this value alone (PROTOCOL.md section 1).
	const char* prof = getenv("X86SIM_METAL_PROFILE");
	d->_profile = prof ? strtoul(prof, NULL, 0) : 10001;
	d->_vkid = vk_new_id();
	g_device = d;
	VKLOG("device \"%s\" registryID %#llx featureProfile %lu", d->_name.UTF8String, d->_registryID, (unsigned long)d->_profile);
}

id<MTLDevice> VKMTLCreateSystemDefaultDevice(void) {
	pthread_once(&g_once, vk_make_device);
	return [(id<MTLDevice>)g_device retain];
}
NSArray* VKMTLCopyAllDevices(void) {
	pthread_once(&g_once, vk_make_device);
	return g_device ? [[NSArray alloc] initWithObjects:g_device, nil] : [[NSArray alloc] init];
}

// Points every GOT entry of `image_name_part` images that holds `real` at `ours` (the images bind
// MTLCreateSystemDefaultDevice from Metal.framework; chained fixups are resolved at load, so a scan for the
// bound value finds them).
int VKMTLRebind(const char* image_name_part, void* real, void* ours) {
	int patched = 0;
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char* name = _dyld_get_image_name(i);
		if (!name || !strstr(name, image_name_part)) continue;
		const struct mach_header_64* mh = (const struct mach_header_64*)_dyld_get_image_header(i);
		intptr_t slide = _dyld_get_image_vmaddr_slide(i);
		const struct load_command* lc = (const struct load_command*)(mh + 1);
		for (uint32_t c = 0; c < mh->ncmds; c++, lc = (const struct load_command*)((const char*)lc + lc->cmdsize)) {
			if (lc->cmd != LC_SEGMENT_64) continue;
			const struct segment_command_64* seg = (const struct segment_command_64*)lc;
			if (strncmp(seg->segname, "__DATA", 6) != 0 && strcmp(seg->segname, "__AUTH_CONST") != 0) continue;
			const struct section_64* sect = (const struct section_64*)(seg + 1);
			for (uint32_t s = 0; s < seg->nsects; s++) {
				uint32_t type = sect[s].flags & SECTION_TYPE;
				if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS && strcmp(sect[s].sectname, "__got") != 0 &&
					strcmp(sect[s].sectname, "__auth_got") != 0) continue;
				void** p = (void**)(sect[s].addr + slide);
				size_t n = sect[s].size / sizeof(void*);
				for (size_t k = 0; k < n; k++) {
					if (p[k] != real) continue;
					uintptr_t page = (uintptr_t)&p[k] & ~(uintptr_t)4095;
					mprotect((void*)page, 8192, PROT_READ | PROT_WRITE);
					p[k] = ours;
					patched++;
				}
			}
		}
	}
	return patched;
}
