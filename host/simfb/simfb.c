// x86Sim: stand-in for CoreSimulator's SimFramebuffer.framework (arm64 simulator builds).
// There is no host: one built-in display; every submitted frame is copied to
// a shared-memory ring (see "frame output" below; cli/libexec/fbring.py) and, every 2 s, to $SIMFB_OUT (default
// $HOME/framebuffer.bgra) as a 16-byte header {w, h, stride, seq}
// followed by BGRA rows. API and semantics: see SimFramebuffer.h.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <fcntl.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Block.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define EXPORT __attribute__((visibility("default")))

#ifndef WIDTH0  // x86Sim: the arm64 build (iPhone 17, iOS 27) passes 1206 x 2622
#define WIDTH0 1179
#define HEIGHT0 2556
#endif
// Speed 22: the device's screen from sim.env (SIMULATOR_MAINSCREEN_WIDTH/HEIGHT, set per model by mksimdevice.py);
// the build's size when unset.
static uint32_t screen_dim(const char* var, uint32_t dflt) {
	const char* v = getenv(var);
	long n = v ? strtol(v, NULL, 10) : 0;
	return n > 0 && n < 16384 ? (uint32_t)n : dflt;
}
#define WIDTH screen_dim("SIMULATOR_MAINSCREEN_WIDTH", WIDTH0)
#define HEIGHT screen_dim("SIMULATOR_MAINSCREEN_HEIGHT", HEIGHT0)

typedef struct __attribute__((packed)) {
	uint32_t mode_id, width, height, unknown_0c, unknown_10, pixel_format, colorspace, refresh_centihz;
	uint8_t is_preferred, unknown_21, is_current;
} SFBDisplayMode;

// CF runtime (private, stable)
typedef struct {
	CFIndex version;
	const char* className;
	void (*init)(CFTypeRef);
	CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
	void (*finalize)(CFTypeRef);
	Boolean (*equal)(CFTypeRef, CFTypeRef);
	CFHashCode (*hash)(CFTypeRef);
	CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
	CFStringRef (*copyDebugDesc)(CFTypeRef);
	void* reclaim;
	void* refcount;
	uintptr_t requiredAlignment;
} CFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass* cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char* category);

typedef struct { uintptr_t cfisa; uint64_t cfinfo; } CFRuntimeBase;

typedef struct __SFBConnection { CFRuntimeBase base; uint64_t id; } *SFBConnectionRef;
typedef struct __SFBDisplay { CFRuntimeBase base; uint32_t idx; } *SFBDisplayRef;
struct __SFBSwapchain;
typedef void (^SFBSwapchainCallback)(CFErrorRef, struct __SFBSwapchain*, uint64_t, uint64_t, void*);
typedef struct __SFBSwapchain {
	CFRuntimeBase base;
	uint32_t width, height, presentation_mode;
	IOSurfaceRef pending;
	void* cb_context;
	dispatch_queue_t cb_queue;
	SFBSwapchainCallback cb;
	uint64_t seq;
	struct disp* d;
} *SFBSwapchainRef;

static dispatch_queue_t dump_q;
static pthread_mutex_t gpu_lock = PTHREAD_MUTEX_INITIALIZER;
static CFTypeID conn_type, display_type, swapchain_type;

// Models 2: a device with several integrated screens (iPhone Duo: the outer "LCD" 1398x2034 and the inner "LCD-1"
// 2007x2853) gets one SFB display per "integrated" entry of its capabilities.plist ($SIMULATOR_CAPABILITIES, as
// CoreSimulator's framebuffer server publishes them): ID = screenID, name = displayName ("LCD", "LCD-1"), device name,
// size. Each has its own frame ring (the first one $SIMFB_RING, display N <ring>-N.ring) and its own present queue and
// refresh pacing. Every other device has the one display as before (SIMFB_DISPLAYS=1 forces that).
#define MAX_DISPLAYS 4
#define PRESENT_QUEUE 2
struct ring_hdr;
struct waiting { SFBSwapchainRef sc; IOSurfaceRef s; uint64_t target, id, t0ns; };   // target: last command buffer to wait for
struct disp {
	SFBDisplayRef ref;
	uint32_t id, w, h;
	CFStringRef name, devname, uid;
	char ring_path[1024];
	// frame ring
	bool ring_tried;
	struct ring_hdr* ring;
	size_t ring_slot_bytes;
	uint64_t ring_frames;
	uint64_t ring_last_ns;   // RAM 15: last frame copied; ring_trimmed: the slots but the latest given back
	bool ring_trimmed;
	// presents waiting for the GPU, refresh pacing (see below)
	struct waiting present[PRESENT_QUEUE];
	size_t npresent;
	IOSurfaceRef vs_s;
	SFBSwapchainRef vs_sc;
	uint64_t vs_t0ns, vs_last_ns;
	bool vs_armed;
	uint64_t st_submits, st_superseded, st_watchdog, st_ready, st_wait_ns, st_wait_max_ns;
};
static struct disp disps[MAX_DISPLAYS];
static int ndisps;
static struct disp* disp_of(SFBDisplayRef d) { return d && d->idx < (uint32_t)ndisps ? &disps[d->idx] : &disps[0]; }

static CFTypeRef dict_get(CFTypeRef d, const char* k) {
	if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) return NULL;
	CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
	CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)d, key);
	CFRelease(key);
	return v;
}
static long dict_int(CFTypeRef d, const char* k) {
	CFTypeRef v = dict_get(d, k);
	long n = 0;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &n);
	return n;
}
static bool dict_str_is(CFTypeRef d, const char* k, const char* want) {
	CFTypeRef v = dict_get(d, k);
	char buf[64];
	return v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)v, buf, sizeof(buf), kCFStringEncodingUTF8) && !strcmp(buf, want);
}
// the "integrated" displays of $SIMULATOR_CAPABILITIES (retained array of dictionaries), NULL when fewer than two
static CFArrayRef integrated_displays(void) {
	const char* path = getenv("SIMULATOR_CAPABILITIES");
	const char* force = getenv("SIMFB_DISPLAYS");
	if (!path || (force && atoi(force) == 1)) return NULL;
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path, strlen(path), false);
	CFReadStreamRef st = url ? CFReadStreamCreateWithFile(NULL, url) : NULL;
	CFPropertyListRef pl = NULL;
	if (st && CFReadStreamOpen(st)) {
		pl = CFPropertyListCreateWithStream(NULL, st, 0, kCFPropertyListImmutable, NULL, NULL);
		CFReadStreamClose(st);
	}
	if (st) CFRelease(st);
	if (url) CFRelease(url);
	CFTypeRef arr = dict_get(dict_get(pl, "capabilities"), "displays");
	if (!arr) arr = dict_get(pl, "displays");
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (arr && CFGetTypeID(arr) == CFArrayGetTypeID())
		for (CFIndex i = 0; i < CFArrayGetCount(arr) && CFArrayGetCount(out) < MAX_DISPLAYS; i++) {
			CFTypeRef e = CFArrayGetValueAtIndex(arr, i);
			if (dict_str_is(e, "displayType", "integrated") && dict_int(e, "width") > 0 && dict_int(e, "height") > 0)
				CFArrayAppendValue(out, e);
		}
	if (pl) CFRelease(pl);
	if (CFArrayGetCount(out) < 2) { CFRelease(out); return NULL; }
	return out;
}

static void swapchain_finalize(CFTypeRef ref) {
	SFBSwapchainRef sc = (SFBSwapchainRef)ref;
	if (sc->pending) CFRelease(sc->pending);
	if (sc->cb) Block_release(sc->cb);
}

static void init_types(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		static const CFRuntimeClass c = { 0, "SFBConnection" }, d = { 0, "SFBDisplay" },
			s = { 0, "SFBSwapchain", NULL, NULL, swapchain_finalize };
		conn_type = _CFRuntimeRegisterClass(&c);
		display_type = _CFRuntimeRegisterClass(&d);
		swapchain_type = _CFRuntimeRegisterClass(&s);
		const char* ring = getenv("SIMFB_RING") ?: "/Volumes/SystemRoot/dev/shm/x86sim-simfb.ring";
		CFArrayRef integ = integrated_displays();
		ndisps = integ ? (int)CFArrayGetCount(integ) : 1;
		for (int i = 0; i < ndisps; i++) {
			struct disp* d = &disps[i];
			d->ref = (SFBDisplayRef)_CFRuntimeCreateInstance(NULL, display_type, sizeof(*d->ref) - sizeof(CFRuntimeBase), NULL);
			d->ref->idx = i;
			CFTypeRef e = integ ? CFArrayGetValueAtIndex(integ, i) : NULL;
			if (i == 0) {
				d->id = 1;
				d->w = WIDTH; d->h = HEIGHT;
				d->name = CFSTR("LCD"); // CA clients pick the main display by this exact name
				d->devname = d->name;
				d->uid = CFSTR("x86Sim-main-display");
				snprintf(d->ring_path, sizeof(d->ring_path), "%s", ring);
			} else {
				d->id = (uint32_t)dict_int(e, "screenID") ?: (uint32_t)(i + 1);
				d->w = (uint32_t)dict_int(e, "width"); d->h = (uint32_t)dict_int(e, "height");
				CFTypeRef n = dict_get(e, "displayName"), dn = dict_get(e, "deviceName");
				d->name = n && CFGetTypeID(n) == CFStringGetTypeID() ? CFStringCreateCopy(NULL, n) : CFStringCreateWithFormat(NULL, NULL, CFSTR("LCD-%d"), i);
				d->devname = dn && CFGetTypeID(dn) == CFStringGetTypeID() ? CFStringCreateCopy(NULL, dn) : d->name;
				d->uid = CFStringCreateWithFormat(NULL, NULL, CFSTR("x86Sim-display-%u"), d->id);
				size_t l = strlen(ring);
				if (l > 5 && !strcmp(ring + l - 5, ".ring")) snprintf(d->ring_path, sizeof(d->ring_path), "%.*s-%u.ring", (int)(l - 5), ring, d->id);
				else snprintf(d->ring_path, sizeof(d->ring_path), "%s-%u", ring, d->id);
			}
			fprintf(stderr, "simfb: display %u %ux%u (%s)\n", d->id, d->w, d->h, d->ring_path);
		}
		if (integ) CFRelease(integ);
	});
}

static void fill_mode(SFBDisplayRef d, SFBDisplayMode* m) {
	memset(m, 0, sizeof(*m));
	m->width = disp_of(d)->w;
	m->height = disp_of(d)->h;
	m->pixel_format = 'BGRA';
	m->colorspace = 1;
	m->refresh_centihz = 6000;
	// x86Sim: 0x0C is the mode's preferred UI scale (QuartzCore -[CADisplayMode preferredScale] returns it when
	// non-zero; else 2 for a virtual device or a mode at least 1080 high). It was 0, so the 1080p Apple TV's mode said
	// 2 and FrontBoard made its display "960x540@2x": UIScreen.scale 2 (Apple: 1), HeadBoard asked for 3840x2160
	// buffers, MapKit refused snapshots ("Invalid content scale"). The device type's scale, as the Mac's simulator.
	const char* sc = getenv("SIMULATOR_MAINSCREEN_SCALE");
	long scale = sc ? lround(strtod(sc, NULL)) : 0;
	m->unknown_0c = scale > 0 && scale <= 4 ? (uint32_t)scale : 0;
	m->is_preferred = 1;
	m->is_current = 1;
}

// --- connection

EXPORT const char* simFramebufferGetStructName(uint32_t id) { return "unknown"; }
EXPORT CFTypeID SFBConnectionGetTypeID(void) { init_types(); return conn_type; }
EXPORT SFBConnectionRef SFBConnectionCreate(CFAllocatorRef allocator, CFStringRef name) {
	init_types();
	SFBConnectionRef c = (SFBConnectionRef)_CFRuntimeCreateInstance(allocator, conn_type, sizeof(*c) - sizeof(CFRuntimeBase), NULL);
	c->id = 1;
	return c;
}
EXPORT bool SFBConnectionConnect(SFBConnectionRef c, CFErrorRef* error) { return true; }
EXPORT uint64_t SFBConnectionGetID(SFBConnectionRef c) { return 1; }
EXPORT CFArrayRef SFBConnectionCopyDisplays(SFBConnectionRef c, CFErrorRef* error) {
	init_types();
	const void* v[MAX_DISPLAYS];
	for (int i = 0; i < ndisps; i++) v[i] = disps[i].ref;
	return CFArrayCreate(NULL, v, ndisps, &kCFTypeArrayCallBacks);
}
EXPORT SFBDisplayRef SFBConnectionCopyDisplay(SFBConnectionRef c, uint32_t id) {
	init_types();
	for (int i = 0; i < ndisps; i++) if (disps[i].id == id) return (SFBDisplayRef)CFRetain(disps[i].ref);
	return NULL;
}
EXPORT SFBDisplayRef SFBConnectionCopyDisplayByUID(SFBConnectionRef c, CFStringRef uid) {
	init_types();
	for (int i = 0; i < ndisps; i++) if (uid && CFEqual(uid, disps[i].uid)) return (SFBDisplayRef)CFRetain(disps[i].ref);
	return NULL;
}
EXPORT void SFBConnectionSetDisplayConnectedHandler(SFBConnectionRef c, dispatch_queue_t q, void* handler) {}
EXPORT void SFBConnectionSetDisplayDisconnectedHandler(SFBConnectionRef c, dispatch_queue_t q, void* handler) {}
EXPORT void SFBConnectionSetDisplayUpdatedHandler(SFBConnectionRef c, dispatch_queue_t q, void* handler) {}
EXPORT SFBDisplayRef SFBConnectionCreateDisplay(SFBConnectionRef c, void* a, void* b, void* d, void* e) { return NULL; }
EXPORT bool SFBConnectionUpdateDisplay(SFBConnectionRef c, SFBDisplayRef d, void* a, void* b) { return false; }
EXPORT bool SFBConnectionRemoveDisplay(SFBConnectionRef c, SFBDisplayRef d, void* a) { return false; }

// --- display

EXPORT CFTypeID SFBDisplayGetTypeID(void) { init_types(); return display_type; }
EXPORT uint64_t SFBDisplayGetConnectionID(SFBDisplayRef d) { return 1; }
EXPORT uint32_t SFBDisplayGetID(SFBDisplayRef d) { return disp_of(d)->id; }
EXPORT uint32_t SFBDisplayGetType(SFBDisplayRef d) { return 0; }
EXPORT CFStringRef SFBDisplayGetName(SFBDisplayRef d) { return disp_of(d)->name; }
EXPORT CFStringRef SFBDisplayGetDisplayUID(SFBDisplayRef d) { return disp_of(d)->uid; }
// x86Sim: new in iOS 27's SimFramebuffer client interface
EXPORT CFStringRef SFBDisplayGetDeviceName(SFBDisplayRef d) { return disp_of(d)->devname; }
EXPORT CFStringRef SFBDisplayGetMaskPath(SFBDisplayRef d) { return NULL; }
EXPORT uint64_t SFBDisplayGetFlags(SFBDisplayRef d) { return 1; }
EXPORT uint32_t SFBDisplayGetPowerState(SFBDisplayRef d) { return 1; }
EXPORT uint64_t SFBDisplayGetSupportedSurfaceFlags(SFBDisplayRef d) { return 0; }
EXPORT uint32_t SFBDisplayGetSupportedPresentationModes(SFBDisplayRef d) { return 0x7; }
EXPORT uint32_t SFBDisplayGetDotPitch(SFBDisplayRef d) { return 460; }
EXPORT CFIndex SFBDisplayGetMaxLayerCount(SFBDisplayRef d) { return 1; }
EXPORT CFIndex SFBDisplayGetMaxSwapchainCount(SFBDisplayRef d) { return 1; }
EXPORT CGSize SFBDisplayGetDeviceSize(SFBDisplayRef d) { return CGSizeMake(disp_of(d)->w, disp_of(d)->h); }
EXPORT CGSize SFBDisplayGetCurrentCanvasSize(SFBDisplayRef d) { return CGSizeMake(disp_of(d)->w, disp_of(d)->h); }
EXPORT CFIndex SFBDisplayGetCanvasSizeCount(SFBDisplayRef d) { return 0; }
EXPORT CGSize SFBDisplayGetCanvasSize(SFBDisplayRef d, CFIndex i) { return CGSizeZero; }
EXPORT CFIndex SFBDisplayGetModeCount(SFBDisplayRef d) { return 1; }
EXPORT bool SFBDisplayGetMode(SFBDisplayRef d, CFIndex i, SFBDisplayMode* out) {
	if (i != 0 || !out) return false;
	fill_mode(d, out);
	return true;
}
EXPORT void SFBDisplayGetPreferredMode(SFBDisplayRef d, SFBDisplayMode* out) { fill_mode(d, out); }
EXPORT void SFBDisplayGetCurrentMode(SFBDisplayRef d, SFBDisplayMode* out) { fill_mode(d, out); }
EXPORT bool SFBDisplayGetExtendedProperties(SFBDisplayRef d, void* out) { return false; }
EXPORT CFArrayRef SFBDisplayCopyExtendedPropertyProtocols(SFBDisplayRef d) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
EXPORT bool SFBDisplaySetCurrentMode(SFBDisplayRef d, const SFBDisplayMode* m, CFErrorRef* e) { return true; }
EXPORT bool SFBDisplaySetCurrentUIOrientation(SFBDisplayRef d, uint32_t o, CFErrorRef* e) { return true; }
EXPORT bool SFBDisplaySetCanvasSize(SFBDisplayRef d, CGSize s, CFErrorRef* e) { return true; }
EXPORT bool SFBDisplaySetBacklightState(SFBDisplayRef d, int32_t s, CFErrorRef* e) {
	if (ndisps > 1) fprintf(stderr, "simfb: display %u backlight %d\n", disp_of(d)->id, s);
	return true;
}
EXPORT bool SFBDisplaySetBrightnessFactor(SFBDisplayRef d, double f, CFErrorRef* e) { return true; }

EXPORT SFBSwapchainRef SFBDisplayCreateSwapchain(SFBDisplayRef d, uint32_t mode, CFDictionaryRef options, CFErrorRef* error, CGSize size) {
	init_types();
	SFBSwapchainRef sc = (SFBSwapchainRef)_CFRuntimeCreateInstance(NULL, swapchain_type, sizeof(*sc) - sizeof(CFRuntimeBase), NULL);
	sc->width = size.width;
	sc->height = size.height;
	sc->presentation_mode = mode;
	sc->d = disp_of(d);
	fprintf(stderr, "simfb: swapchain %ux%u mode %u display %u\n", sc->width, sc->height, mode, sc->d->id);
	return sc;
}

// --- swapchain

EXPORT CFTypeID SFBSwapchainGetTypeID(void) { init_types(); return swapchain_type; }
EXPORT uint32_t SFBSwapchainGetID(SFBSwapchainRef sc) { return 1; }
EXPORT uint64_t SFBSwapchainGetConnectionID(SFBSwapchainRef sc) { return 1; }
EXPORT uint32_t SFBSwapchainGetDisplayID(SFBSwapchainRef sc) { return sc->d ? sc->d->id : 1; }
EXPORT CGSize SFBSwapchainGetFramebufferSize(SFBSwapchainRef sc) { return CGSizeMake(sc->width, sc->height); }
EXPORT uint32_t SFBSwapchainGetPixelFormat(SFBSwapchainRef sc) { return 'BGRA'; }
EXPORT uint32_t SFBSwapchainGetColorspace(SFBSwapchainRef sc) { return 1; }
EXPORT uint32_t SFBSwapchainGetHDRMode(SFBSwapchainRef sc) { return 0; }
EXPORT uint32_t SFBSwapchainGetPresentationMode(SFBSwapchainRef sc) { return sc->presentation_mode; }
EXPORT uint32_t SFBSwapchainGetMaxSurfacesPerOperation(SFBSwapchainRef sc) { return 32; }
EXPORT bool SFBSwapchainAcquireSurfaceFence(SFBSwapchainRef sc, IOSurfaceRef s, void* a, void* b) { return true; }

static void gpu_hook(void);
EXPORT bool SFBSwapchainSwapBegin(SFBSwapchainRef sc, uint64_t t, CFErrorRef* e) {
	gpu_hook();
	if (sc->pending) { CFRelease(sc->pending); sc->pending = NULL; }
	return true;
}
EXPORT bool SFBSwapchainSwapAddSurface(SFBSwapchainRef sc, IOSurfaceRef s, uint64_t a, uint64_t b, CFErrorRef* e, CGRect src, CGRect dst) {
	if (s) {
		if (sc->pending) CFRelease(sc->pending);
		sc->pending = (IOSurfaceRef)CFRetain(s);
	}
	return true;
}
EXPORT void SFBSwapchainSwapSetCallback(SFBSwapchainRef sc, void* context, dispatch_queue_t queue, SFBSwapchainCallback cb) {
	if (sc->cb) Block_release(sc->cb);
	sc->cb = cb ? Block_copy(cb) : NULL;
	sc->cb_context = context;
	sc->cb_queue = queue;
}

// x86Sim: frame output. Every completed present is copied into a ring of RING_SLOTS frame slots in a shared-memory
// file (default /Volumes/SystemRoot/dev/shm/x86sim-simfb.ring, i.e. Linux's /dev/shm; $SIMFB_RING overrides) that
// the Linux viewers mmap (cli/libexec/fbring.py documents the layout). The slot written is never the latest one; its seq
// is zeroed first and set after the copy, then the header's latest/seq are published (release order). The old
// framebuffer.bgra file ($SIMFB_OUT) is still written, but at most every 2 s (and once more for the last frame), for
// tools that read it. The header also carries present statistics (see struct ring_hdr).
#define RING_SLOTS 4
#define RING_HDR 4096
// x86Sim: age_us = publish time - the present's SwapSubmit time (us): a long frame interval with a small age was late
// from CA (the app/render server), a large age was held by the GPU or the refresh pacing (tests/perf.py scroll)
struct ring_slot { _Atomic uint64_t seq; uint64_t time_ns; uint32_t width, height, stride, age_us; };
struct ring_hdr {
	uint32_t magic, version, nslots, slot_bytes, width, height, stride, pad0;
	_Atomic uint64_t seq; _Atomic uint32_t latest; uint32_t pad1;
	uint64_t pad2[2];
	struct ring_slot slots[RING_SLOTS];                    // at 64

	// statistics (at 64 + 32 * RING_SLOTS = 192): counts since the process started
	uint64_t st_submits, st_superseded, st_watchdog, st_copied, st_ready_at_submit;
	uint64_t st_wait_ns, st_wait_max_ns, st_copy_ns, st_copy_max_ns;
	uint64_t st_pid;
};
_Static_assert(__builtin_offsetof(struct ring_hdr, slots) == 64, "ring layout");
_Static_assert(__builtin_offsetof(struct ring_hdr, st_submits) == 192, "ring layout");
static uint64_t file_last_ns;
static dispatch_source_t file_timer;

// x86Sim: a Linux system call (Darling processes are Linux processes): under libarm64jit, "svc #0xfffe" is one, with
// x8 = the x86_64 syscall number
static long linux_syscall3(long n, long a, long b, long c) {
	register long x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c;
	register long x8 __asm__("x8") = n;
	__asm__ volatile("svc #0xfffe" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

// x86Sim: readers on Linux (simview, fbring.wait) sleep in FUTEX_WAIT on the low 32 bits of the header's
// seq instead of polling; every publish wakes them. This is Linux's futex(2) (shared, not FUTEX_PRIVATE: the page
// is a /dev/shm file mapped by other processes).
static void ring_wake(void* addr) {
	linux_syscall3(202 /* futex */, (long)addr, 1 /* FUTEX_WAKE */, 0x7fffffffL);
}
static uint64_t now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom; }
static uint64_t wall_ns(void) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec; }

// RAM 15: a ring holds RING_SLOTS whole frames in a tmpfs file (shared memory: iPhone 17 4 x 12.2 MB, Pro Max 4 x 14.5,
// iPad Pro 13 4 x 22.3, the Duo's inner screen 4 x 22.9 MB) and every slot stays resident once written, though only the
// latest one is read while the screen is still. After RING_IDLE_MS without a frame (a still home screen, the Duo's
// hidden screen) the other slots go back to the system (MADV_REMOVE frees a shared tmpfs range; a later write takes new
// zeroed pages): idle cost one frame per display. SIMFB_RING_IDLE_MS (default 1500; 0 = never trim).
#define RING_IDLE_MS_DEFAULT 1500
static long ring_madvise_remove(void* addr, size_t len) {
	return linux_syscall3(28 /* madvise */, (long)addr, (long)len, 9 /* MADV_REMOVE */);
}
static uint64_t ring_idle_ns;
static dispatch_source_t ring_trim_timer;
static void ring_trim_tick(void) {   // on dump_q (the only writer of slots)
	for (int i = 0; i < ndisps; i++) {
		struct disp* D = &disps[i];
		if (!D->ring || D->ring_trimmed || !D->ring_frames || now_ns() - D->ring_last_ns < ring_idle_ns) continue;
		uint32_t latest = atomic_load(&D->ring->latest);
		long r = 0;
		for (uint32_t k = 0; k < RING_SLOTS; k++)
			if (k != latest) r |= ring_madvise_remove((char*)D->ring + RING_HDR + k * D->ring_slot_bytes, D->ring_slot_bytes);
		D->ring_trimmed = true;
		static int logged;
		if (logged++ < 4) fprintf(stderr, "simfb: display %u idle: %d of %d ring slots given back (%zu MB each)%s\n", D->id,
			RING_SLOTS - 1, RING_SLOTS, D->ring_slot_bytes >> 20, r ? " (madvise failed)" : "");
	}
}

static void ring_open(struct disp* D, size_t stride, size_t height) {
	if (D->ring_tried) return;
	D->ring_tried = true;
	const char* path = D->ring_path;
	size_t ring_slot_bytes;
	struct ring_hdr* ring;
	D->ring_slot_bytes = ring_slot_bytes = (stride * height + 4095) & ~(size_t)4095;
	size_t len = RING_HDR + RING_SLOTS * ring_slot_bytes;
	char tmp[1100];
	snprintf(tmp, sizeof(tmp), "%s.%d", path, getpid());
	int fd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0644);   // a new file per process, renamed into place: readers
	if (fd < 0 || ftruncate(fd, len) != 0) {                   // of an older ring see its inode go away
		fprintf(stderr, "simfb: no frame ring at %s\n", path);
		if (fd >= 0) { close(fd); unlink(tmp); }
		return;
	}
	void* m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (m == MAP_FAILED) { unlink(tmp); fprintf(stderr, "simfb: frame ring mmap failed\n"); return; }
	D->ring = ring = m;
	ring->magic = 'RBFS';   // "SFBR" in memory (little-endian)
	ring->version = 2;   // 2: every publish wakes futex waiters on the low word of seq (ring_wake)
	ring->nslots = RING_SLOTS;
	ring->slot_bytes = (uint32_t)ring_slot_bytes;
	ring->st_pid = getpid();
	rename(tmp, path);
	fprintf(stderr, "simfb: frame ring %s (%d slots of %zu bytes)\n", path, RING_SLOTS, ring_slot_bytes);
	if (!ring_trim_timer) {
		const char* e = getenv("SIMFB_RING_IDLE_MS");
		long ms = e ? atol(e) : RING_IDLE_MS_DEFAULT;
		if (ms > 0) {
			ring_idle_ns = (uint64_t)ms * 1000000ull;
			ring_trim_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dump_q);
			dispatch_source_set_timer(ring_trim_timer, dispatch_time(DISPATCH_TIME_NOW, ring_idle_ns), ring_idle_ns / 2, 100 * NSEC_PER_MSEC);
			dispatch_source_set_event_handler(ring_trim_timer, ^{ ring_trim_tick(); });
			dispatch_resume(ring_trim_timer);
		}
	}
}

static void file_write(const void* px, uint32_t w, uint32_t h, uint32_t stride, uint64_t seq) {   // on dump_q
	static const char* path;
	static char buf[1024];
	if (!path) {
		path = getenv("SIMFB_OUT");
		if (!path) { snprintf(buf, sizeof(buf), "%s/framebuffer.bgra", getenv("HOME") ?: "/tmp"); path = buf; }
	}
	uint32_t hdr[4] = { w, h, stride, (uint32_t)seq };
	char tmp[1100];
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) {
		write(fd, hdr, sizeof(hdr));
		write(fd, px, (size_t)stride * h);
		close(fd);
		rename(tmp, path);
	}
	file_last_ns = now_ns();
}
static uint64_t file_seq;   // ring frame last written to the file
static void file_from_ring(void) {   // on dump_q: the ring's latest slot (only dump_q writes slots); display 1 only
	struct ring_hdr* ring = disps[0].ring;
	size_t ring_slot_bytes = disps[0].ring_slot_bytes;
	if (!ring) return;
	uint64_t seq = atomic_load(&ring->seq);
	if (!seq || seq == file_seq) return;
	uint32_t slot = atomic_load(&ring->latest);
	struct ring_slot* rs = &ring->slots[slot];
	file_write((char*)ring + RING_HDR + slot * ring_slot_bytes, rs->width, rs->height, rs->stride, seq);
	file_seq = seq;
}

static void dump(SFBSwapchainRef sc, IOSurfaceRef s, uint64_t submit_ns) {   // on dump_q
	struct disp* D = sc->d ?: &disps[0];
	uint64_t t0 = now_ns();
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	uint32_t w = (uint32_t)IOSurfaceGetWidth(s), h = (uint32_t)IOSurfaceGetHeight(s), stride = (uint32_t)IOSurfaceGetBytesPerRow(s);
	uint64_t seq = ++sc->seq;
	ring_open(D, stride, h);
	struct ring_hdr* ring = D->ring;
	size_t ring_slot_bytes = D->ring_slot_bytes;
	if (ring && (size_t)stride * h <= ring_slot_bytes) {
		uint32_t slot = (atomic_load_explicit(&ring->latest, memory_order_relaxed) + 1) % RING_SLOTS;
		struct ring_slot* rs = &ring->slots[slot];
		atomic_store_explicit(&rs->seq, 0, memory_order_relaxed);
		atomic_thread_fence(memory_order_release);
		memcpy((char*)ring + RING_HDR + slot * ring_slot_bytes, IOSurfaceGetBaseAddress(s), (size_t)stride * h);
		rs->time_ns = wall_ns(); rs->width = w; rs->height = h; rs->stride = stride;
		{ uint64_t age = submit_ns ? (now_ns() - submit_ns) / 1000 : 0; rs->age_us = age > 0xffffffffu ? 0xffffffffu : (uint32_t)age; }
		ring->width = w; ring->height = h; ring->stride = stride;
		D->ring_last_ns = now_ns(); D->ring_trimmed = false;
		atomic_store_explicit(&rs->seq, ++D->ring_frames, memory_order_release);
		atomic_store_explicit(&ring->latest, slot, memory_order_release);
		atomic_store_explicit(&ring->seq, D->ring_frames, memory_order_release);
		ring_wake((void*)&ring->seq);
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		// the file (display 1 only): at most every 2 s, from the ring; the timer writes a newer last frame later
		if (D == &disps[0] && now_ns() - file_last_ns >= 2000000000ull) file_from_ring();
		if (D == &disps[0] && !file_timer) {
			file_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dump_q);
			dispatch_source_set_timer(file_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
			dispatch_source_set_event_handler(file_timer, ^{ if (now_ns() - file_last_ns >= 1900000000ull) file_from_ring(); });
			dispatch_resume(file_timer);
		}
	} else {   // no ring: every frame to the file, as before (display 1)
		if (D == &disps[0]) file_write(IOSurfaceGetBaseAddress(s), w, h, stride, seq);
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	}
	uint64_t dt = now_ns() - t0;
	if (ring) {
		pthread_mutex_lock(&gpu_lock);
		ring->st_submits = D->st_submits; ring->st_superseded = D->st_superseded; ring->st_watchdog = D->st_watchdog;
		ring->st_ready_at_submit = D->st_ready; ring->st_wait_ns = D->st_wait_ns; ring->st_wait_max_ns = D->st_wait_max_ns;
		pthread_mutex_unlock(&gpu_lock);
		ring->st_copied++; ring->st_copy_ns += dt; if (dt > ring->st_copy_max_ns) ring->st_copy_max_ns = dt;
	}
	if (seq == 1 || seq % 600 == 0) fprintf(stderr, "simfb: frame %llu %ux%u (display %u)\n", (unsigned long long)seq, w, h, D->id);
}

// x86Sim: GPU completion for presents. With CA's Metal renderer (host/metalhostd, X86SIM_METAL) the GPU may still be
// writing the surface when CA submits it: CA passes no fence to SFBSwapchainSwapAddSurface (both extra arguments are
// 0) and never calls SFBSwapchainAcquireSurfaceFence; on a Mac the host's GPU reads of the surface are ordered after
// the simulator's GPU writes by the driver (implicit IOSurface sync). Here we track it in-process: every
// MTLSimCommandBuffer committed in this process gets a completed handler (fired by MTLSimDriver when metalhostd/mtlvk
// report the GPU finished, after which the surface's shared pages hold the result). A present waits for every
// command buffer committed before SwapSubmit, then the surface is copied. Without Metal (software renderer) nothing
// is outstanding and the copy happens at once. A newer present supersedes an older one still waiting.
static uint64_t gpu_commits;            // command buffers committed so far (their seq: 1..gpu_commits)
static uint64_t gpu_outstanding[4096];  // seqs of committed, not yet completed command buffers (ring of slots)
static size_t gpu_noutstanding;
// x86Sim: presents waiting for the GPU are a FIFO of up to PRESENT_QUEUE (CA rotates 3 swapchain surfaces, so a
// surface isn't drawn into again until two newer presents are out). The single waiting slot of before dropped every
// present that came while the previous one still waited (GPU latency ~9 ms vs a 16 ms frame: up to 60% of the
// presents of a home-screen swipe). Only when the queue is full is the oldest dropped ("superseded").
static uint64_t present_ids;   // struct waiting's id: identifies a waiting present for its watchdog (a counter, unique)
static IMP orig_commit;
static uint64_t stat_waited, stat_immediate, stat_frames;

static bool gpu_done_upto(uint64_t target) {
	for (size_t i = 0; i < gpu_noutstanding; i++) if (gpu_outstanding[i] <= target) return false;
	return true;
}
// x86Sim: scanout at the display's refresh. CA's SimDisplay does not wait for the swap callback (finished_update is
// the replaced buffer's seed), so presents came whenever CA rendered: up to ~94 a second while dragging, unevenly
// spaced. A present whose GPU work is done now waits for the next refresh slot after the previous publish (a display
// shows a frame at vsync); a newer ready present replaces one still waiting (counted as superseded). Frames that come
// slower than the refresh are published at once. SIMFB_HZ (default 60) sets the rate, 0 publishes immediately.
static uint64_t vs_period_ns;
static void vsync_fire(struct disp* D) {   // on dump_q
	pthread_mutex_lock(&gpu_lock);
	IOSurfaceRef s = D->vs_s; SFBSwapchainRef sc = D->vs_sc; uint64_t t0ns = D->vs_t0ns;
	D->vs_s = NULL; D->vs_sc = NULL; D->vs_armed = false;
	uint64_t now = now_ns();
	// keep the slot grid while frames keep coming; start a new one after a pause
	D->vs_last_ns = (now - D->vs_last_ns < 2 * vs_period_ns) ? D->vs_last_ns + vs_period_ns : now;
	if (D->vs_last_ns > now) D->vs_last_ns = now;
	pthread_mutex_unlock(&gpu_lock);
	if (s) { dump(sc, s, t0ns); CFRelease(s); CFRelease(sc); }
}
static void present_fire_locked(struct disp* D, size_t i) {   // gpu_lock held: copy waiting present i (and drop it from the queue)
	struct waiting* present = D->present;
	SFBSwapchainRef sc = present[i].sc;
	IOSurfaceRef s = present[i].s;
	uint64_t t0ns = present[i].t0ns;
	uint64_t w = now_ns() - present[i].t0ns;
	D->st_wait_ns += w; if (w > D->st_wait_max_ns) D->st_wait_max_ns = w;
	memmove(&present[i], &present[i + 1], (D->npresent - i - 1) * sizeof(present[0]));
	D->npresent--;
	stat_frames++;
	if (!vs_period_ns) {
		const char* hz = getenv("SIMFB_HZ");
		double f = hz ? atof(hz) : 60;
		vs_period_ns = f > 0 ? (uint64_t)(1e9 / f) : 1;
	}
	if (vs_period_ns <= 1) { dispatch_async(dump_q, ^{ dump(sc, s, t0ns); CFRelease(s); CFRelease(sc); }); return; }
	if (D->vs_s) { CFRelease(D->vs_s); CFRelease(D->vs_sc); D->st_superseded++; }
	D->vs_s = s; D->vs_sc = sc; D->vs_t0ns = t0ns;
	if (!D->vs_armed) {
		D->vs_armed = true;
		uint64_t now = now_ns(), next = D->vs_last_ns + vs_period_ns;
		if (next <= now) dispatch_async(dump_q, ^{ vsync_fire(D); });
		else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(next - now)), dump_q, ^{ vsync_fire(D); });
	}
}
static void present_fire_ready_locked(struct disp* D) {   // in order: the oldest first, stop at the first not ready
	while (D->npresent && gpu_done_upto(D->present[0].target)) present_fire_locked(D, 0);
}
static void gpu_completed(uint64_t seq) {
	pthread_mutex_lock(&gpu_lock);
	for (size_t i = 0; i < gpu_noutstanding; i++)
		if (gpu_outstanding[i] == seq) { gpu_outstanding[i] = gpu_outstanding[--gpu_noutstanding]; break; }
	for (int i = 0; i < ndisps; i++) present_fire_ready_locked(&disps[i]);
	pthread_mutex_unlock(&gpu_lock);
}
static void hooked_commit(id self, SEL cmd) {
	pthread_mutex_lock(&gpu_lock);
	uint64_t seq = ++gpu_commits;
	if (gpu_noutstanding < sizeof(gpu_outstanding) / sizeof(gpu_outstanding[0])) gpu_outstanding[gpu_noutstanding++] = seq;
	pthread_mutex_unlock(&gpu_lock);
	void (^h)(id) = ^(id cb) { gpu_completed(seq); };
	((void (*)(id, SEL, void (^)(id)))objc_msgSend)(self, sel_registerName("addCompletedHandler:"), h);
	((void (*)(id, SEL))orig_commit)(self, cmd);
}
static void gpu_hook(void) {   // MTLSimDriver may load after us: retried at every SwapBegin until found
	static bool done;
	if (done) return;
	Class c = objc_getClass("MTLSimCommandBuffer");
	if (!c) return;
	done = true;
	SEL sel = sel_registerName("commit");
	Method m = class_getInstanceMethod(c, sel);   // inherited from Metal's _MTLCommandBuffer
	if (!m) return;
	orig_commit = method_getImplementation(m);
	// override on MTLSimCommandBuffer only (class_addMethod), so other _MTLCommandBuffer subclasses keep theirs
	if (!class_addMethod(c, sel, (IMP)hooked_commit, method_getTypeEncoding(m))) {
		orig_commit = method_setImplementation(class_getInstanceMethod(c, sel), (IMP)hooked_commit);
	}
	fprintf(stderr, "simfb: presents wait for GPU completion of MTLSimCommandBuffers\n");
}
// a present still waiting after 1 s (e.g. mtlvk died and completions never come) is copied anyway, with the older ones
static void present_watchdog(struct disp* D, uint64_t id) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dump_q, ^{
		pthread_mutex_lock(&gpu_lock);
		for (size_t i = 0; i < D->npresent; i++) {
			if (D->present[i].id != id) continue;
			fprintf(stderr, "simfb: present waited 1 s for the GPU (%zu command buffers outstanding), copying anyway\n", gpu_noutstanding);
			for (size_t k = 0; k <= i; k++) { D->st_watchdog++; present_fire_locked(D, 0); }
			break;
		}
		pthread_mutex_unlock(&gpu_lock);
	});
}

EXPORT bool SFBSwapchainSwapSubmit(SFBSwapchainRef sc, CFErrorRef* e) {
	IOSurfaceRef s = sc->pending;
	sc->pending = NULL;
	if (s) {
		static dispatch_once_t once;
		dispatch_once(&once, ^{ dump_q = dispatch_queue_create("simfb.dump", DISPATCH_QUEUE_SERIAL); });
		CFRetain(sc);
		struct disp* D = sc->d ?: &disps[0];
		struct waiting* present = D->present;
		pthread_mutex_lock(&gpu_lock);
		D->st_submits++;
		if (D->npresent == PRESENT_QUEUE) {   // full: the oldest is dropped
			CFRelease(present[0].s); CFRelease(present[0].sc); D->st_superseded++;
			memmove(&present[0], &present[1], (D->npresent - 1) * sizeof(present[0]));
			D->npresent--;
		}
		uint64_t id = ++present_ids;
		present[D->npresent++] = (struct waiting){ sc, s, gpu_commits, id, now_ns() };
		present_fire_ready_locked(D);
		bool now = D->npresent == 0;
		if (now) { stat_immediate++; D->st_ready++; } else stat_waited++;
		if ((stat_immediate + stat_waited) % 600 == 1)
			fprintf(stderr, "simfb: %llu presents waited for the GPU, %llu were ready at submit; %llu copied\n",
				(unsigned long long)stat_waited, (unsigned long long)stat_immediate, (unsigned long long)stat_frames);
		pthread_mutex_unlock(&gpu_lock);
		if (!now) present_watchdog(D, id);
	}
	SFBSwapchainCallback cb = sc->cb;
	void* ctx = sc->cb_context;
	dispatch_queue_t q = sc->cb_queue ?: dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
	sc->cb = NULL;
	if (cb) {
		uint64_t now = mach_absolute_time();
		CFRetain(sc);
		dispatch_async(q, ^{
			cb(NULL, sc, now, now + 16666666, ctx);
			Block_release(cb);
			CFRelease(sc);
		});
	}
	return true;
}
EXPORT bool SFBSwapchainSwapCancel(SFBSwapchainRef sc, CFErrorRef* e) {
	if (sc->pending) { CFRelease(sc->pending); sc->pending = NULL; }
	return true;
}
