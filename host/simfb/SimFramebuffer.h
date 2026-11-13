/*
 * SimFramebuffer.h -- reconstructed interface of Apple's private
 * SimFramebuffer.framework (CoreSimulator-1174.9.2, shipped with Xcode 27.1),
 * as loaded by the runtime's SimFramebufferClient shim via
 *   dlopen(getenv("SIMULATOR_FRAMEBUFFER_FRAMEWORK")) + dlsym() x 59.
 *
 * Purpose: let us write an x86_64 replacement that runs inside the runtime
 * (under Darling), with no CoreSimulator host behind it. It makes up one display
 * and accepts frames from QuartzCore's swapchain.
 *
 * Sources:
 *  [A] arm64 SimFramebuffer (hostfw/.../SimFramebuffer.framework/SimFramebuffer)
 *      -- accessor offsets, ObjC type-encoding strings for every struct, block
 *         signatures, queues.
 *  [Q] x86_64 QuartzCore in RuntimeRoot -- -[CAWindowServer _detectSimDisplays],
 *      CA::WindowServer::SimDisplay::{update_simdisplay_info,map_surfaces,
 *      finish_update,update_display_modes}, SimFlipBook::{swap_frame,
 *      cancel_all_swaps}.
 *  Tags: CONFIRMED = read directly from disassembly; INFERRED = strongly implied;
 *  UNCERTAIN = guess, verify if it matters.
 *
 * ===========================================================================
 *  WHAT QUARTZCORE ACTUALLY CALLS (x86_64, the only consumer that matters now)
 * ===========================================================================
 *  Only 20 of the 59 symbols are imported by QuartzCore:
 *    SFBConnectionCreate, SFBConnectionConnect, SFBConnectionCopyDisplays,
 *    SFBConnectionCopyDisplayByUID, SFBConnectionSetDisplayUpdatedHandler,
 *    SFBDisplayGetType, SFBDisplayGetDisplayUID, SFBDisplayGetName,
 *    SFBDisplayGetCurrentMode, SFBDisplayGetDeviceSize,
 *    SFBDisplayGetCurrentCanvasSize, SFBDisplayGetModeCount, SFBDisplayGetMode,
 *    SFBDisplayCreateSwapchain,
 *    SFBSwapchainSwapBegin, SFBSwapchainSwapAddSurface,
 *    SFBSwapchainSwapSetCallback, SFBSwapchainSwapSubmit, SFBSwapchainSwapCancel.
 *  QuartzCore does NOT set the Connected/Disconnected handlers. It never waits on
 *  a callback to find displays.
 *  The other 39 still have to be exported (the shim dlsym()s all 59, and other
 *  runtime processes such as backboardd may call them). Stubs that return
 *  sensible constants are fine.
 *
 *  Sequence in -[CAWindowServer _detectSimDisplays] (runs on the CA server
 *  thread / main queue):
 *    1. conn = SFBConnectionCreate(kCFAllocatorDefault, <CFSTR name>);  // +1, kept forever
 *         returns NULL  -> give up (no sim displays)
 *    2. CFErrorRef err = NULL; ok = SFBConnectionConnect(conn, &err);
 *         false -> CFRelease(err) if set, give up.
 *       Connect MUST be synchronous: QuartzCore calls CopyDisplays right after
 *       and expects the display list to be there already.
 *    3. displays = SFBConnectionCopyDisplays(conn, &err);   // CFArrayRef, +1
 *         NULL -> release err + conn, give up.
 *       For each element d (SFBDisplayRef):
 *         type = SFBDisplayGetType(d)            // uint32 in eax
 *         uid  = SFBDisplayGetDisplayUID(d)      // CFStringRef, NOT retained by callee.
 *                                                // NULL => display is SKIPPED.
 *         new SimDisplay(uid): CFRetain(d); CFRetain(conn)
 *         SFBDisplayGetType(d) again; name = SFBDisplayGetName(d) (stored unretained,
 *           so it must stay valid as long as d lives)
 *         update_simdisplay_info():
 *            SFBDisplayGetCurrentMode(d, &simdisplay->mode)   // 0x23-byte copy-out
 *            SFBDisplayGetDeviceSize(d)        -> CGSize in xmm0/xmm1
 *            SFBDisplayGetCurrentCanvasSize(d) -> CGSize in xmm0/xmm1
 *            refresh_interval = mode.refresh ? 100.0 / mode.refresh : 0
 *         per-type setup (jump table on type 0..4):
 *            0 = internal/main display: scale from CADeviceInternalDisplayScale()
 *                (MobileGestalt, NOT from SFB), marked main. <-- USE THIS
 *            1 = external-like (0x400), 2/3 = 0x800, 4 = 0xc00 + extra flag
 *         map_surfaces():
 *            requires 1 <= deviceSize.w,h <= 16384 and mode.refresh != 0,
 *            otherwise no swapchain and the display gets an empty mode set.
 *            sc = SFBDisplayCreateSwapchain(d, 2 (presentationMode), NULL (options),
 *                                           &err, canvas.width, canvas.height);
 *            err set -> logs "SimDisplay : failed SFBDisplayCreateSwapchain: %s".
 *            mode.colorspace != 1 -> logs "unsupported SimColorSpace" (non-fatal).
 *            Allocates 3 CA surfaces of canvas.w x canvas.h, format =
 *              mode.pixel_format (passed straight to Display::allocate_surface).
 *            Builds the CA mode list: for i < SFBDisplayGetModeCount(d):
 *              SFBDisplayGetMode(d, i, &m) and packs m.width(14 bits),
 *              m.height(14 bits), m.refresh*0.01 (9 bits); m.is_current ->
 *              current mode, m.is_preferred -> preferred mode.
 *            Display::set_size(device size, canvas size, ...)
 *    4. CFRelease(displays)
 *    5. SFBConnectionSetDisplayUpdatedHandler(conn, dispatch_get_main_queue(),
 *          ^(SFBDisplayRef d, uint64_t changeFlags){...});
 *       The handler finds the CA display by SFBDisplayGetDisplayUID(d) and calls
 *       update_display_modes(), which does unmap_surfaces, CFRelease(old d),
 *       d' = SFBConnectionCopyDisplayByUID(conn, uid) (+1), then
 *       update_simdisplay_info + map_surfaces again (new swapchain).
 *       A fake host never needs to fire this.
 *
 *  Per-frame (SimDisplay::finish_update, on the CA render thread):
 *    CFErrorRef err = NULL;
 *    if (!SFBSwapchainSwapBegin(sc, mach_absolute_time(), &err)) goto fail;
 *    IOSurfaceRef s = <CA surface>->iosurface();        // one of the 3 surfaces
 *    CGRect r = dirty bounds of that surface (ints converted to double)
 *    if (!SFBSwapchainSwapAddSurface(sc, s, 0, 0, &err, r, r)) goto fail;
 *    SFBSwapchainSwapSetCallback(sc, ctx (heap obj, owned by block),
 *                                NULL (queue), ^(CFErrorRef e, SFBSwapchainRef sc,
 *                                     uint64_t t0, uint64_t t1, void *ctx){...});
 *    if (!SFBSwapchainSwapSubmit(sc, &err)) goto fail;
 *    ... surfaces rotate 0->1->2->0 ...
 *    fail: if (err) CFRelease(err);
 *  The callback block (QC side): for each image queue in ctx it calls
 *  ImageQueue::did_display(seq, CATimeWithHostTime(t0), CATimeWithHostTime(t1-t0)),
 *  then frees ctx. So t0 and t1 are mach_absolute_time units: t0 = when shown,
 *  t1 >= t0 (for example t0 + one frame interval). If the callback never fires,
 *  ctx leaks and video/ImageQueue timing stalls, but UI frames keep coming. Fire it.
 *  SimFlipBook::swap_frame (flipbook path): same calls with err = NULL,
 *  AddSurface rect = (0,0,w,h) for both rects, SetCallback(sc, NULL, NULL, block).
 *  SimFlipBook::cancel_all_swaps: SFBSwapchainSwapCancel(sc, NULL).
 *
 *  CA does NOT wait for any fence: no SFBSwapchainAcquireSurfaceFence and no
 *  options dict, so use_fences = false. It also does not throttle on the callback.
 *  Nothing guards against re-rendering into a surface that was just submitted
 *  except the 3-way rotation. If you dump frames, COPY or encode the IOSurface
 *  contents synchronously inside SwapSubmit (or before the next SwapBegin that
 *  reuses it). Holding a reference alone does not stop CA from drawing into it.
 *
 * ===========================================================================
 *  RECOMMENDED MINIMAL FAKE-HOST BEHAVIOUR
 * ===========================================================================
 *  - Register 3 CF classes (_CFRuntimeRegisterClass) "SFBConnection",
 *    "SFBDisplay", "SFBSwapchain". QuartzCore only CFRetain/CFReleases them, so any
 *    CF type works. Real instance sizes (excluding CFRuntimeBase 0x10):
 *    connection 0x78, display 0x168-ish, swapchain 0xb58-ish.
 *  - SFBConnectionCreate: alloc, store name, create a private serial queue.
 *  - SFBConnectionConnect: synchronously build one display (below), mark
 *    connected. If a Connected handler is set, dispatch_async(handlerQueue ?:
 *    connection queue, ^{ handler(display); }). Return true.
 *  - SFBConnectionCopyDisplays: CFArrayCreate(..., &display, 1, &kCFTypeArrayCallBacks).
 *  - SFBConnectionCopyDisplay(conn, id) / CopyDisplayByUID(conn, uid): CFRetain'd
 *    display or NULL.
 *  - Display (portrait, the model's size @3x, 60 Hz):
 *        name        = CFSTR("iPhone")            (any CFString)
 *        uid         = CFSTR("com.x86sim.simfb.display.0")  (MUST be non-NULL)
 *        deviceName  = CFSTR("iPhone")
 *        type        = 0 (main)
 *        display_id  = 1 (any non-zero uint32 is probably fine)
 *        device size = canvas size = 1179 x 2556  (pixels)
 *        flags       = 1 (bit0 = power on; GetPowerState = flags & 1) UNCERTAIN beyond bit 0
 *        supported_surface_flags = 0, presentation modes = 0x4? (bitmask incl. 2) UNCERTAIN
 *        dot pitch   = 460 (ppi?) UNCERTAIN, maxLayers = 1, maxSwapchains = 1
 *        one mode: {mode_id 0, {1179,2556}, 0, 0, 'BGRA', 1, 6000, 1,0,1}
 *        has_extended_properties = false, mask path = NULL, protocols = empty array.
 *  - SFBDisplayCreateSwapchain: alloc swapchain {fb size = requested size,
 *    display_id, swapchain_id = 1.., pixel_format = mode.pixel_format, colorspace 1,
 *    hdr 0, presentation_mode = requested}. Return +1. Never NULL in the happy path.
 *  - SwapBegin: assert no pending swap; pending = true; store time; seq++. Return true.
 *  - SwapAddSurface: CFRetain(surface) into the pending list (max 32), store rects.
 *    Return true.
 *  - SwapSetCallback: store ctx, Block_copy(block), queue (NULL => real impl uses
 *    dispatch_get_global_queue(2 = HIGH, 0)).
 *  - SwapSubmit: lock + read/encode the IOSurface pixels (IOSurfaceLock(kIOSurfaceLockReadOnly),
 *    BaseAddress/BytesPerRow/Width/Height; BGRA8888 premultiplied), CFRelease
 *    surfaces, pending = false. Then dispatch_async(queue, ^{ block(NULL, sc, now,
 *    now + 16.67ms in mach units, ctx); Block_release(block); }). Return true.
 *  - SwapCancel: drop the pending swap. If a callback was set, invoke it with a
 *    non-NULL CFErrorRef (real code: dispatch_sync on the swapchain queue, then
 *    callback with error) UNCERTAIN, or just release it. Return true.
 *  - Everything else: return the stored field, or true/NULL/0.
 *
 * ===========================================================================
 *  OWNERSHIP RULES (CF conventions, CONFIRMED from [A]/[Q])
 * ===========================================================================
 *  Create and Copy functions return +1 (caller CFRelease). Get* return borrowed values.
 *  CFErrorRef *outError: on failure the callee stores a +1 CFError (caller
 *  releases). On success it leaves it untouched; CA pre-initialises it to NULL.
 *  Error domain "SimFramebufferClientErrorDomain"; codes include 10 (too many
 *  surfaces, from AddSurface). Others are unknown.
 *  Handler setters: CFRetain(conn), dispatch_retain(queue), Block_copy(block),
 *  then store on the connection queue with dispatch_barrier_async.
 *
 * ===========================================================================
 *  x86_64 ABI NOTES FOR THE REPLACEMENT
 * ===========================================================================
 *  - Every "bool" return: CA tests only %al. Return a C99 bool.
 *  - SFBDisplayGetModeCount: arm64 returns a uint16 (ldrh), but QuartzCore compares
 *    the FULL 64-bit %rax against a signed 64-bit loop counter. Declare and
 *    implement it as returning CFIndex (zero-extended). Same safety for GetMode's
 *    index argument (CFIndex; real impl rejects negative / >= count).
 *  - CGSize returns ({double,double}) come back in xmm0:xmm1. CGSize arguments go in
 *    xmm0, xmm1 after the integer args. CGRect arguments (32 bytes) are passed in
 *    MEMORY on the stack (SwapAddSurface has 2 of them after the 5 GPR args).
 *    Using the real CGRect/CGSize types in the prototypes gets this right.
 *  - SFBDisplayMode is copied out by value (35 bytes, packed). Write exactly 0x23
 *    bytes; CA's buffer is 0x23 bytes plus padding.
 */
#ifndef SIMFRAMEBUFFER_H
#define SIMFRAMEBUFFER_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <IOSurface/IOSurfaceRef.h>   /* IOSurfaceRef (Darling: IOSurface/IOSurface.h if needed) */
#include <CoreGraphics/CGGeometry.h>  /* CGSize / CGRect; replace with the typedefs below if absent */
/*
 * If CoreGraphics headers are not available:
 *   typedef struct { double x, y; } CGPoint;
 *   typedef struct { double width, height; } CGSize;
 *   typedef struct { CGPoint origin; CGSize size; } CGRect;
 * (identical layout, same ABI classification)
 */

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------- */
/*  Opaque CF types                                                           */
/* ------------------------------------------------------------------------- */
typedef struct __SFBConnection *SFBConnectionRef;   /* CFType, GetTypeID      */
typedef struct __SFBDisplay    *SFBDisplayRef;      /* CFType                 */
typedef struct __SFBSwapchain  *SFBSwapchainRef;    /* CFType                 */

/* ------------------------------------------------------------------------- */
/*  Wire structs (from ObjC @encode strings embedded in [A]; all packed,     */
/*  4-byte fields are naturally aligned within them)                         */
/* ------------------------------------------------------------------------- */
typedef struct { uint32_t width, height; } SimSize;           /* 8 bytes */
typedef struct { uint32_t x, y; }          SimPoint;
typedef struct { SimPoint origin; SimSize size; } SimRect;

/* _SimDisplayMode = I{_SimSize=II}IIIIICCC, 0x23 bytes, packed. [A] copies it
 * with ldp q0,q1 + ldur w,[#0x1f]. AddMode: is_preferred -> preferred_mode_index,
 * is_current -> current_mode_index (CONFIRMED). */
#pragma pack(push, 1)
typedef struct SFBDisplayMode {
    uint32_t mode_id;        /* 0x00 UNCERTAIN meaning (index/id); CA ignores          */
    SimSize  size;           /* 0x04 width, 0x08 height (pixels). CA: 14-bit fields     */
    uint32_t unknown_0c;     /* 0x0C INFERRED: preferred UI scale (-[CADisplayMode preferredScale] when non-zero) */
    uint32_t unknown_10;     /* 0x10 UNCERTAIN                                          */
    uint32_t pixel_format;   /* 0x14 INFERRED: IOSurface fourcc passed to CA            */
                             /*      allocate_surface. Use 'BGRA' = 0x42475241.         */
    uint32_t colorspace;     /* 0x18 CONFIRMED CA requires 1 (else logs                 */
                             /*      "unsupported SimColorSpace"; 1 = sRGB likely)      */
    uint32_t refresh_centihz;/* 0x1C CONFIRMED scale: CA uses refresh*0.01 as Hz and     */
                             /*      100.0/refresh as frame interval. 60 Hz => 6000.    */
                             /*      MUST be non-zero or no swapchain is created.       */
    uint8_t  is_preferred;   /* 0x20 CONFIRMED                                          */
    uint8_t  unknown_21;     /* 0x21 UNCERTAIN (0)                                      */
    uint8_t  is_current;     /* 0x22 CONFIRMED                                          */
} SFBDisplayMode;            /* sizeof == 0x23 */
#pragma pack(pop)

/* _SimDisplayExtendedProperties = {_SimSize=II}IIIb1 x8 -> 0x15 bytes
 * (GetExtendedProperties copies 16 + 8 bytes from display+0x124). */
#pragma pack(push, 1)
typedef struct SFBDisplayExtendedProperties {
    SimSize  size;           /* 0x00 UNCERTAIN meaning (physical size?) */
    uint32_t u08, u0c, u10;  /* 0x08..0x13 UNCERTAIN */
    uint8_t  bits;           /* 0x14 eight 1-bit flags, UNCERTAIN */
} SFBDisplayExtendedProperties; /* 0x15 */
#pragma pack(pop)

/* Real SFBDisplay instance layout ([A], @encode of __SFBDisplay), for reference.
 *  0x000 CFRuntimeBase (16)
 *  0x010 CFStringRef name                 <- SFBDisplayGetName
 *  0x018 CFStringRef displayUID           <- SFBDisplayGetDisplayUID
 *  0x020 CFStringRef deviceName           <- SFBDisplayGetDeviceName (not in shim's list)
 *  0x028 uint64_t    connectionID         <- SFBDisplayGetConnectionID
 *  0x030 _SimDisplayProperties:
 *        0x030 char[64] (name), 0x070 char[64] (uid), 0x0b0 char[64] (deviceName)
 *        0x0f0 uint64 supportedSurfaceFlags  <- GetSupportedSurfaceFlags
 *        0x0f8 uint64 flags                  <- GetFlags; GetPowerState = flags & 1
 *        0x100 uint32 supportedPresentationModes
 *        0x104 SimSize deviceSize            <- GetDeviceSize (as doubles)
 *        0x10c SimSize canvasSize            <- GetCurrentCanvasSize (as doubles)
 *        0x114 uint32 display_id             <- GetID
 *        0x118 uint32 type                   <- GetType
 *        0x11c uint32 dotPitch               <- GetDotPitch
 *        0x120 uint16 maxLayerCount, 0x122 uint16 maxSwapchainCount
 *  0x124 _SimDisplayExtendedProperties (0x15)
 *  0x140 CFArrayRef extendedPropertyProtocols (may be NULL -> Copy returns empty array)
 *  0x148 uint16 modes_count
 *  0x150 uint64 preferred_mode_index, 0x158 uint64 current_mode_index
 *  0x160 SFBDisplayMode *modes
 *  0x168 CFStringRef maskPath             <- GetMaskPath
 *  0x170 bool has_extended_properties     <- GetExtendedProperties return value
 *
 * Real SFBSwapchain layout ([A]):
 *  0x10 uint64 connectionID; 0x18 SimSize framebufferSize; 0x20 uint32 display_id;
 *  0x24 uint32 swapchain_id; 0x28 uint32 pixelFormat; 0x2c uint32 colorspace;
 *  0x30 uint32 hdrMode; 0x34 uint32 presentationMode; 0x38 dispatch_queue_t;
 *  0x40 NSMutableDictionary fences(by IOSurfaceID); 0x48 bool use_fences;
 *  0x49 bool has_pending_swap; 0x4a bool has_callback; 0x50 uint64 pending time (ns);
 *  0x58 uint64 pending_swap_sequence; 0x60.. 32 x 0x58-byte surface slots
 *  {IOSurfaceRef, CGRect src, CGRect dst, uint64 a, uint64 b}.
 */

/* Swapchain options dictionary key (CFString value "UseFences"; bool NSNumber). */
extern const CFStringRef kSFBSwapchainOptionUseFences;          /* UNCERTAIN: exported symbol, shim does not dlsym it */
/* Display option keys exist too: kSFBDisplayOptionKeyApplyMask, kSFBDisplayOptionKeyMaskPath. */

/* ------------------------------------------------------------------------- */
/*  Block types                                                               */
/* ------------------------------------------------------------------------- */
/* Connected / disconnected: handler(display) on the queue given to the setter.
 * [A] displayCreatedOrUpdatedCallback invokes the connected handler with x1 = display only. */
typedef void (^SFBDisplayConnectedHandler)(SFBDisplayRef display);
typedef void (^SFBDisplayDisconnectedHandler)(SFBDisplayRef display);
/* Updated: QC block encoding "v24@?0^{__SFBDisplay=}8Q16" (CONFIRMED). */
typedef void (^SFBDisplayUpdatedHandler)(SFBDisplayRef display, uint64_t changeFlags);
/* Swap completion: QC encoding "v48@?0^{__CFError=}8^{__SFBSwapchain=}16Q24Q32^v40"
 * (CONFIRMED). t0/t1 are mach_absolute_time units ([A] converts the server's ns
 * values with nsToMachTime). CA: did_display(t0, duration = t1 - t0).
 * error != NULL => swap failed or was cancelled. */
typedef void (^SFBSwapchainCallback)(CFErrorRef error, SFBSwapchainRef swapchain,
                                     uint64_t presentedHostTime, uint64_t endHostTime,
                                     void *context);

/* ------------------------------------------------------------------------- */
/*  SFBConnection (13)                                                       */
/* ------------------------------------------------------------------------- */
CFTypeID         SFBConnectionGetTypeID(void);
/* +1. name is CFStringCreateCopy'd. Real impl: CFRuntime instance 0x78 bytes,
 * id from a global counter, concurrent queue "com.apple.SimFramebuffer.%llu" (QoS 0x15). */
SFBConnectionRef SFBConnectionCreate(CFAllocatorRef allocator, CFStringRef name);
/* Synchronous (dispatch_barrier_sync on the connection queue + mach checkin to the
 * server). Returns false and sets *error on failure. */
bool             SFBConnectionConnect(SFBConnectionRef conn, CFErrorRef *error);
uint64_t         SFBConnectionGetID(SFBConnectionRef conn);                 /* conn+0x10 */
/* +1 CFArray of SFBDisplayRef. Synchronous; loads from the server if not cached. */
CFArrayRef       SFBConnectionCopyDisplays(SFBConnectionRef conn, CFErrorRef *error);
/* +1 or NULL. No error arg. */
SFBDisplayRef    SFBConnectionCopyDisplay(SFBConnectionRef conn, uint32_t displayID);
SFBDisplayRef    SFBConnectionCopyDisplayByUID(SFBConnectionRef conn, CFStringRef displayUID);
/* Setter: retains queue, copies block, stores it asynchronously (barrier). queue may be NULL? UNCERTAIN */
void SFBConnectionSetDisplayConnectedHandler(SFBConnectionRef conn, dispatch_queue_t queue,
                                             SFBDisplayConnectedHandler handler);
void SFBConnectionSetDisplayDisconnectedHandler(SFBConnectionRef conn, dispatch_queue_t queue,
                                                SFBDisplayDisconnectedHandler handler);
void SFBConnectionSetDisplayUpdatedHandler(SFBConnectionRef conn, dispatch_queue_t queue,
                                           SFBDisplayUpdatedHandler handler);
/* Host-side / test APIs (create a display from the client side). Not used by
 * QuartzCore. Signatures UNCERTAIN: CreateDisplay takes 7 integer/pointer args
 * (conn + 6). [A] forwards them to _SFBConnectionCreateOrUpdateDisplay(conn, NULL, a1..a6).
 * Args 2..4 must be non-NULL (properties ptr, modes ptr, ...). Fake: return NULL/false. */
SFBDisplayRef SFBConnectionCreateDisplay(SFBConnectionRef conn, void *a1, void *a2, void *a3,
                                         void *a4, void *a5, CFErrorRef *error /*UNCERTAIN*/);
bool          SFBConnectionUpdateDisplay(SFBConnectionRef conn, SFBDisplayRef display, void *a2,
                                         void *a3, void *a4, void *a5, CFErrorRef *error /*UNCERTAIN*/);
bool          SFBConnectionRemoveDisplay(SFBConnectionRef conn, SFBDisplayRef display,
                                         void *a2 /*non-NULL*/, void *a3 /*non-NULL*/ /*UNCERTAIN*/);

/* ------------------------------------------------------------------------- */
/*  SFBDisplay (30) -- all Get* are plain field reads (no IPC), CONFIRMED      */
/* ------------------------------------------------------------------------- */
CFTypeID     SFBDisplayGetTypeID(void);
uint64_t     SFBDisplayGetConnectionID(SFBDisplayRef d);          /* +0x28 */
uint32_t     SFBDisplayGetID(SFBDisplayRef d);                    /* +0x114 */
uint32_t     SFBDisplayGetType(SFBDisplayRef d);                  /* +0x118; 0 = main */
CFStringRef  SFBDisplayGetName(SFBDisplayRef d);                  /* +0x10, borrowed */
CFStringRef  SFBDisplayGetDisplayUID(SFBDisplayRef d);            /* +0x18, borrowed, MUST be non-NULL */
CFStringRef  SFBDisplayGetMaskPath(SFBDisplayRef d);              /* +0x168, may be NULL */
uint64_t     SFBDisplayGetFlags(SFBDisplayRef d);                 /* +0xf8 */
uint32_t     SFBDisplayGetPowerState(SFBDisplayRef d);            /* flags & 1 */
uint64_t     SFBDisplayGetSupportedSurfaceFlags(SFBDisplayRef d); /* +0xf0 */
uint32_t     SFBDisplayGetSupportedPresentationModes(SFBDisplayRef d); /* +0x100 bitmask? */
uint32_t     SFBDisplayGetDotPitch(SFBDisplayRef d);              /* +0x11c */
uint16_t     SFBDisplayGetMaxLayerCount(SFBDisplayRef d);         /* +0x120 */
uint16_t     SFBDisplayGetMaxSwapchainCount(SFBDisplayRef d);     /* +0x122 */
CGSize       SFBDisplayGetDeviceSize(SFBDisplayRef d);            /* +0x104 u32 pair -> doubles */
CGSize       SFBDisplayGetCurrentCanvasSize(SFBDisplayRef d);     /* +0x10c u32 pair -> doubles */
CFIndex      SFBDisplayGetCanvasSizeCount(SFBDisplayRef d);       /* real impl: always 0 */
CGSize       SFBDisplayGetCanvasSize(SFBDisplayRef d, CFIndex index); /* real impl: always {0,0} */
/* See ABI note: real return is uint16, but return a zero-extended CFIndex. */
CFIndex      SFBDisplayGetModeCount(SFBDisplayRef d);             /* +0x148 */
/* Copies mode[index] (0x23 bytes) to *out. false if index < 0 or >= count. out must be non-NULL. */
bool         SFBDisplayGetMode(SFBDisplayRef d, CFIndex index, SFBDisplayMode *out);
void         SFBDisplayGetPreferredMode(SFBDisplayRef d, SFBDisplayMode *out); /* asserts index valid */
void         SFBDisplayGetCurrentMode(SFBDisplayRef d, SFBDisplayMode *out);   /* asserts index valid */
/* Returns has_extended_properties; copies 0x15 bytes into *out only if true. */
bool         SFBDisplayGetExtendedProperties(SFBDisplayRef d, SFBDisplayExtendedProperties *out);
/* +1 CFArray (copy of +0x140, or a new empty array). */
CFArrayRef   SFBDisplayCopyExtendedPropertyProtocols(SFBDisplayRef d);

/* Setters: synchronous request/reply IPC (message ids in parens). Return true on success,
 * else *error (+1). A fake host can just update its local state and return true. */
bool SFBDisplaySetCurrentMode(SFBDisplayRef d, const SFBDisplayMode *mode, CFErrorRef *error); /* 0x0f */
bool SFBDisplaySetCurrentUIOrientation(SFBDisplayRef d, uint32_t orientation, CFErrorRef *error); /* 0x10 */
bool SFBDisplaySetCanvasSize(SFBDisplayRef d, CGSize size, CFErrorRef *error);           /* 0x11; size in xmm0/xmm1 */
bool SFBDisplaySetBacklightState(SFBDisplayRef d, int32_t state, CFErrorRef *error);      /* 0x13 */
bool SFBDisplaySetBrightnessFactor(SFBDisplayRef d, double factor, CFErrorRef *error);    /* 0x14 */

/* Synchronous IPC (msg 0x09, _SimDisplaySwapchain {SimSize size; u32 display_id;
 * u32 swapchain_id; u32 pixelFormat; u32 colorspace; u32 hdrMode; u32 presentationMode}).
 * The client fills size, display_id and presentationMode. The server fills the rest.
 * options: NSDictionary/CFDictionary or NULL; only key "UseFences" (bool) is read.
 * QuartzCore: (d, 2, NULL, &err, canvas.width, canvas.height).
 * Returns +1 swapchain, or NULL + *error. */
SFBSwapchainRef SFBDisplayCreateSwapchain(SFBDisplayRef d, uint32_t presentationMode,
                                          CFDictionaryRef options, CFErrorRef *error,
                                          CGSize framebufferSize /* xmm0, xmm1 */);

/* ------------------------------------------------------------------------- */
/*  SFBSwapchain (16)                                                        */
/* ------------------------------------------------------------------------- */
CFTypeID  SFBSwapchainGetTypeID(void);
uint32_t  SFBSwapchainGetID(SFBSwapchainRef sc);                  /* +0x24 */
uint64_t  SFBSwapchainGetConnectionID(SFBSwapchainRef sc);        /* +0x10 */
uint32_t  SFBSwapchainGetDisplayID(SFBSwapchainRef sc);           /* +0x20 */
CGSize    SFBSwapchainGetFramebufferSize(SFBSwapchainRef sc);     /* +0x18 u32 pair -> doubles */
uint32_t  SFBSwapchainGetPixelFormat(SFBSwapchainRef sc);         /* +0x28 */
uint32_t  SFBSwapchainGetColorspace(SFBSwapchainRef sc);          /* +0x2c */
uint32_t  SFBSwapchainGetHDRMode(SFBSwapchainRef sc);             /* +0x30 */
uint32_t  SFBSwapchainGetPresentationMode(SFBSwapchainRef sc);    /* +0x34 */
uint32_t  SFBSwapchainGetMaxSurfacesPerOperation(SFBSwapchainRef sc); /* constant 32 */

/* No IPC. Asserts !has_pending_swap ("API MISUSE: SFBSwapchain already has a pending
 * swap operation"). Stores hostTime converted to ns, assigns a new global sequence,
 * sets has_pending_swap. Always returns true; error is never written. */
bool SFBSwapchainSwapBegin(SFBSwapchainRef sc, uint64_t hostTime /*mach_absolute_time*/,
                           CFErrorRef *error);
/* No IPC. Requires a pending swap. CFRetains surface into the first free of 32 slots.
 * No free slot -> *error = code 10 ("Too many surfaces"), return false.
 * a/b are stored verbatim (64-bit); CA always passes 0,0 (layer index / flags? UNCERTAIN).
 * x86_64: sc=rdi surface=rsi a=rdx b=rcx error=r8, src rect at [rsp], dst rect at [rsp+0x20]. */
bool SFBSwapchainSwapAddSurface(SFBSwapchainRef sc, IOSurfaceRef surface,
                                uint64_t a, uint64_t b, CFErrorRef *error,
                                CGRect srcRect, CGRect dstRect);
/* Requires a pending swap (asserts) and block != NULL. Retains sc, Block_copy, dispatch_retain(queue)
 * and registers {sequence, ctx, queue, block} asynchronously on the swapchain queue.
 * queue == NULL -> callback later runs on dispatch_get_global_queue(2 = HIGH, 0). */
void SFBSwapchainSwapSetCallback(SFBSwapchainRef sc, void *context, dispatch_queue_t queue,
                                 SFBSwapchainCallback callback);
/* Sends present (msg with _SimSwapchainPresent {Q seq; Q time; Q ?; SimRect; SimRect; 6 x u32})
 * plus one IOSurface mach port per surface (IOSurfaceCreateMachPort), then clears the
 * pending swap. Completion arrives asynchronously from the server
 * (_SimSwapchainPresentCallback {Q seq?; Q t0_ns; Q t1_ns; u32 status}) and calls the
 * registered block. error may be NULL. */
bool SFBSwapchainSwapSubmit(SFBSwapchainRef sc, CFErrorRef *error);
/* If no pending swap: returns true. If a callback was registered, it is pulled
 * off the swapchain queue (dispatch_sync) and completed with an error. Then a
 * SwapchainCancel message (0x12) is sent. error may be NULL. Exact callback
 * semantics are UNCERTAIN. */
bool SFBSwapchainSwapCancel(SFBSwapchainRef sc, CFErrorRef *error);
/* Only meaningful when use_fences; otherwise returns true at once. Waits up to timeout
 * (dispatch_group_wait) for the host to release `surface`. */
bool SFBSwapchainAcquireSurfaceFence(SFBSwapchainRef sc, IOSurfaceRef surface,
                                     dispatch_time_t timeout);

/* ------------------------------------------------------------------------- */
/*  Misc                                                                     */
/* ------------------------------------------------------------------------- */
/* Debug: struct id (4..0x16) -> "SimStructSimDisplayMode" etc., else "(unknown)". */
const char *simFramebufferGetStructName(uint32_t structID);

#ifdef __cplusplus
}
#endif
#endif /* SIMFRAMEBUFFER_H */
