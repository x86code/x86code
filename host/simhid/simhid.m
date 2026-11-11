// x86Sim: stand-in for CoreSimulator's SimulatorHID.framework (x86_64, iOS simulator), loaded by backboardd.
//
// How the runtime uses it (SimulatorClient.framework, IndigoHIDSystemSpawnLoopback(IOHIDEventSystemRef)):
//   path = getenv("SIMULATOR_HID_SYSTEM_MANAGER"); bundle = [NSBundle bundleWithPath:path];
//   cls = [bundle principalClass]  (Info.plist NSPrincipalClass "SimHIDSystem"), must conform to the protocol
//   SimulatorClientHIDSystemManager; manager = [[cls alloc] initUsingHIDService:<backboardd's IOHIDEventSystemRef>
//   error:&err] and is kept forever.
// Apple's SimHIDSystem receives "Indigo" HID messages from Simulator.app over a mach port and dispatches them
// through virtual HID services it adds to that event system (_IOHIDServiceCreateVirtual + _IOHIDEventSystemAddService
// + _IOHIDServiceDispatchEvent). We do the same with a built-in touchscreen, the main-screen buttons and a keyboard,
// fed by a Unix socket (simview / cli/libexec/simtouch.py on Linux) instead of Indigo messages.
//
// Socket: $SIMHID_SOCKET (default <SIMULATOR_SHARED_RESOURCES_DIRECTORY>/simhid.sock), stream, any number of
// clients, one text command per line (a path too long for sun_path: a symlink to a short one, see listen_thread):
//   touch down|move|up <x> <y> [edge]   x, y normalized to the display (0..1, origin top left); edge (on down, kept
//                                  for the whole touch): none|top|left|bottom|right, a touch that begins at that screen
//                                  edge (system gestures: home indicator, Control/Notification Center)
//   touch2 down|move|up <x1> <y1> <x2> <y2>   two fingers (pinch, two-finger pan): one hand event with two finger
//                                  children, finger indexes 1 and 2 with their own identities
//   key down|up <usage>            keyboard usage (page 7), e.g. 4 = 'a', 0x28 = return
//   button home|lock|volup|voldown down|up
//   crown <delta> [x|y|z]          (Platforms 1, Apple Watch) Digital Crown rotation: a scroll event of <delta> on that
//                                  axis (default y) through the crown service
//   @<screenID> <touch command>    (Models 2) the touch on another integrated display (iPhone Duo: @3 = the inner
//                                  "LCD-1"; x, y normalized to that display's framebuffer as simfb publishes it)
//   hinge <degrees>                (Models 2, devices with two integrated displays) the hinge angle: 0 folded (closed),
//   fold | unfold                  180 flat (open); fold / unfold = hinge 0 / 180. CoreMotion reads it from the hinge
//                                  service (Apple vendor motion page 0xff0c, usage 0x21, as CoreMotion's CLAngleNotifier matches it: kIOHIDEventTypeHingeAngle events, copied
//                                  and dispatched) and SpringBoard's device pose picks the outer or inner display.
//   kbidle <seconds>               (arm64) this client's keyboard idle detach: after its last key the on-demand
//                                  keyboard stays attached that long (default SIMHID_KB_IDLE_S). Interactive viewers
//                                  send a long one so a human's typing pauses do not pay the re-attach settle.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
typedef int IOReturn;
typedef uint32_t IOOptionBits;
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <time.h>

typedef struct __IOHIDEvent* IOHIDEventRef;
typedef struct __IOHIDService* IOHIDServiceRef;
typedef struct __IOHIDEventSystem* IOHIDEventSystemRef_;
typedef double IOHIDFloat;

// IOKit private (IOHIDFamily: IOHIDServicePrivate.h / IOHIDEventSystemPrivate.h). The callback table layout was read
// from the runtime's IOKit (__IOHIDServiceCreateVirtualNoInit copies 0x58 bytes when version == 2; the service calls
// +0x8 open, +0x10 close, +0x18 copyProperty, +0x20 setProperty, +0x28 setEventCallback, +0x30/+0x38 schedule/
// unschedule, +0x40 copyEvent, +0x48 setOutputEvent, +0x50 copyMatchingEvent).
typedef struct {
	uint64_t version;
	Boolean (*open)(void* target, void* refcon, IOOptionBits options);
	void (*close)(void* target, void* refcon, IOOptionBits options);
	CFTypeRef (*copyProperty)(void* target, void* refcon, CFStringRef key);
	Boolean (*setProperty)(void* target, void* refcon, CFStringRef key, CFTypeRef value);
	void (*setEventCallback)(void* target, void* refcon, void* callback, void* cbTarget, void* cbRefcon);
	void (*schedule)(void* target, void* refcon, dispatch_queue_t queue);
	void (*unschedule)(void* target, void* refcon, dispatch_queue_t queue);
	IOHIDEventRef (*copyEvent)(void* target, void* refcon, uint32_t type, IOHIDEventRef matching, IOOptionBits options);
	IOReturn (*setOutputEvent)(void* target, void* refcon, IOHIDEventRef event);
	IOHIDEventRef (*copyMatchingEvent)(void* target, void* refcon, CFDictionaryRef matching);
} VirtualCallbacks;
extern IOHIDServiceRef _IOHIDServiceCreateVirtual(CFAllocatorRef, uint64_t serviceID, const VirtualCallbacks*, void* target, void* refcon);
extern void _IOHIDEventSystemAddService(IOHIDEventSystemRef_, IOHIDServiceRef);
extern void _IOHIDServiceDispatchEvent(IOHIDServiceRef, IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t ts, uint32_t transducerType, uint32_t index,
	uint32_t identity, uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
	IOHIDFloat tipPressure, IOHIDFloat barrelPressure, Boolean range, Boolean touch, IOOptionBits options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t ts, uint32_t index, uint32_t identity,
	uint32_t eventMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
	Boolean range, Boolean touch, IOOptionBits options);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t ts, uint32_t usagePage, uint32_t usage,
	Boolean down, IOOptionBits flags);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, CFIndex value);
// Models 2: kIOHIDEventTypeHingeAngle (44): fields 1 AngleDegrees, 2 MechanicalAngleDegrees, 3 velocity (deg/s),
// 4 state (0 unknown, 1 closed, 2 open)
extern IOHIDEventRef IOHIDEventCreateHingeAngleEvent(CFAllocatorRef, uint64_t ts, IOOptionBits, double angle, double mechanical, double velocity);
#define kIOHIDEventTypeHingeAngle 44
#define kFieldHingeState ((44 << 16) | 4)
// CoreMotion's CLAngleNotifier drops a hinge event whose phase is 0 ("copied event is invalid")
extern void IOHIDEventSetPhase(IOHIDEventRef, uint16_t phase);
// Platforms 1: the Digital Crown's events (Apple's watchOS SimulatorHID decodes the host's crown messages into these)
extern IOHIDEventRef IOHIDEventCreateScrollEvent(CFAllocatorRef, uint64_t ts, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
	IOOptionBits options);
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t ts, uint32_t page, uint32_t usage, uint32_t version,
	const uint8_t* data, CFIndex length, IOOptionBits options);

#define kDigitizerTransducerHand 3
#define kDigitizerRange 0x1
#define kDigitizerTouch 0x2
#define kDigitizerPosition 0x4
#define kDigitizerIdentity 0x20
#define kFieldDigitizerIsDisplayIntegrated ((11 << 16) | 25)
// x86Sim: how Apple's Simulator marks edge touches (SimulatorKit IndigoHIDMessageForMouseNSEvent, Xcode 27.1): the
// IndigoHIDEdge (0 none, 1 top, 2 left, 3 bottom, 4 right) picks the digitizer event mask from a table, 0x40000 |
// {0, 0x02000000, 0x08000000, 0x01000000, 0x04000000} (the swipe direction away from that edge: top = swipe down,
// bottom = swipe up ...), and SimulatorHID passes that mask to IOHIDEventCreateDigitizerFingerEvent on every phase.
// SpringBoard's system gestures (home indicator, Control/Notification Center) only claim touches carrying these bits.
static const uint32_t edge_mask[5] = { 0x40000, 0x02040000, 0x08040000, 0x01040000, 0x04040000 };
static int touch_edge;

// x86Sim arm64: also mirror to a host-visible log file. stderr under the JIT can be late or
// interleaved with backboardd's own logging; a dedicated file lets us see whether the socket
// thread actually runs handle_line / dispatch.
static FILE* g_logf;
static void slog(const char* fmt, ...) {
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "simhid: "); vfprintf(stderr, fmt, ap); fprintf(stderr, "\n");
	if (!g_logf) {
		const char* p = getenv("SIMHID_LOG");
		char def[512];
		if (!p || !*p) {  // Linux user's scratch, seen through Darling's SystemRoot (same user name)
			struct passwd* pw = getpwuid(getuid());
			snprintf(def, sizeof def, "/Volumes/SystemRoot/home/%s/scratch/x86sim/simhid.log", pw ? pw->pw_name : "");
			p = def;
		}
		g_logf = fopen(p, "a");
		if (g_logf) setvbuf(g_logf, NULL, _IOLBF, 0);
	}
	if (g_logf) {
#if __arm64__
		// wall-clock ns (same clock as the frame ring's slot t_ns) so touches line up with frames (simrecord.py)
		{ struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); fprintf(g_logf, "%llu ", (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec); }
#endif
		fprintf(g_logf, "simhid: ");
		va_list ap2; va_start(ap2, fmt);
		vfprintf(g_logf, fmt, ap2);
		va_end(ap2);
		fprintf(g_logf, "\n");
		fflush(g_logf);
	}
	va_end(ap);
}

typedef struct {
	const char* name;
	uint64_t id;
	CFDictionaryRef props;
	IOHIDServiceRef service;
	dispatch_queue_t queue;
} VService;

static VService touch_svc, buttons_svc, keyboard_svc;
// Models 2: a device with two integrated displays (capabilities) gets a touchscreen per extra display and a hinge
static VService inner_touch_svc, hinge_svc;
static uint32_t inner_display_id;
static VService* cur_touch = &touch_svc;
// Platforms 1: an Apple Watch's Digital Crown, as Apple's watchOS SimulatorHID registers it
// ("com.apple.SimulatorHID.MainScreenDigitalCrownService": Apple vendor usage page 0xff0b, usage 1, built in)
static VService crown_svc;   // the touchscreen of the command being handled (@<screenID> prefix)
static double hinge_deg, hinge_vel;
static uint16_t hinge_phase = 2;
// Models 2: CoreMotion's device state (the magic pose SpringBoard's SBFDevicePoseProvider combines with the angle:
// "hinge .unknown" without it, and no display swap). On a device it is the SPU's {0xff0c, 0x22} report; the simulator
// build of CMDeviceStateManager also observes the distributed notification CMDeviceStateEventSendNotification with
// NSNumber properties A, A0, A1 (device orientation and that of each half, 0..6), B (hinge state, 0..5), C (tabletop
// pose, 0..11), D (stable orientation state, 0..4); -[CMMagicPoseManager createMagicPoseEventFromDeviceStateEvent:]
// copies them 1:1 into a CMMagicPoseEvent. Hinge state from the strings: 1 Closed, 2 PartiallyOpen, 3 OpenFlat.
// the angle for the launcher (which screen to show): <SIMULATOR_SHARED_RESOURCES_DIRECTORY>/hinge, degrees
static void write_hinge_file(double deg) {
	const char* d = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY");
	if (!d) return;
	char p[1100], t[1110];
	snprintf(p, sizeof p, "%s/hinge", d);
	snprintf(t, sizeof t, "%s.tmp", p);
	FILE* f = fopen(t, "w");
	if (!f) return;
	fprintf(f, "%.1f\n", deg);
	fclose(f);
	rename(t, p);
}
static void post_device_state(double deg) {
	write_hinge_file(deg);
	long hs = deg <= 5 ? 1 : deg >= 170 ? 3 : 2;
	Class c = NSClassFromString(@"NSDistributedNotificationCenter");
	id center = c ? ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("defaultCenter")) : nil;
	if (!center) { slog("hinge: no NSDistributedNotificationCenter"); return; }
	NSDictionary* info = @{ @"CMDeviceStateEventPropertyAKey": @1, @"CMDeviceStateEventPropertyA0Key": @1,
		@"CMDeviceStateEventPropertyA1Key": @1, @"CMDeviceStateEventPropertyBKey": @((float)deg),
		@"CMDeviceStateEventPropertyCKey": @0, @"CMDeviceStateEventPropertyDKey": @2 };
	((void (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(center, sel_registerName("postNotificationName:object:userInfo:deliverImmediately:"),
		@"CMDeviceStateEventSendNotification", nil, info, YES);
	slog("hinge: device state B=%ld posted", hs);
}
static IOHIDEventRef hinge_event(void) {
	IOHIDEventRef e = IOHIDEventCreateHingeAngleEvent(kCFAllocatorDefault, mach_absolute_time(), 0, hinge_deg, hinge_deg, hinge_vel);
	if (e) {
		IOHIDEventSetIntegerValue(e, kFieldHingeState, hinge_deg <= 5 ? 1 : 2);
		IOHIDEventSetPhase(e, hinge_phase);
		// CLAngleNotifier takes CMAngle.progress (the fold progress SpringBoard's pose uses, "fold:") from a vendor child
		// {0xff0c, 0x80} of 21 bytes: u64 gesture-began and u64 message-sent continuous timestamps, float progress,
		// flags (bit 0: wake event); without it progress is 0 and the pose stays fully closed
		struct __attribute__((packed)) { uint64_t began, sent; float progress; uint8_t flags; } d = {
			mach_continuous_time(), mach_continuous_time(), (float)(hinge_deg / 180.0), 0 };
		IOHIDEventRef c = IOHIDEventCreateVendorDefinedEvent(kCFAllocatorDefault, mach_absolute_time(), 0xff0c, 0x80, 0,
			(const uint8_t*)&d, sizeof(d), 0);
		if (c) { IOHIDEventAppendEvent(e, c, 0); CFRelease(c); }
	}
	return e;
}
static IOHIDEventSystemRef_ hid_system;

static Boolean v_open(void* t, void* r, IOOptionBits o) {
	// Speed 34: NULL-safe: after the idle detach (_IOHIDServiceTerminate) IOKit calls close / unschedule with a NULL
	// target (backboardd crashed in v_close on the first gate)
	slog("v_open %s", t ? ((VService*)t)->name : "(null)");
	return true;
}
static void v_close(void* t, void* r, IOOptionBits o) { slog("v_close %s", t ? ((VService*)t)->name : "(null)"); }
static CFTypeRef v_copyProperty(void* t, void* r, CFStringRef key) {
	VService* s = t;
	if (!s || !s->props) return NULL;
	CFTypeRef v = CFDictionaryGetValue(s->props, key);
	return v ? CFRetain(v) : NULL;
}
static Boolean v_setProperty(void* t, void* r, CFStringRef key, CFTypeRef value) {
	// keyboard: logged (timestamped) to find when the hardware-keyboard session is up, see the settle in handle_line
	if (t == &keyboard_svc && g_logf && key) {
		char k[96] = ""; CFStringGetCString(key, k, sizeof k, kCFStringEncodingUTF8);
		slog("v_setProperty keyboard %s", k);
	}
	return true;
}
static void v_setEventCallback(void* t, void* r, void* cb, void* a, void* b) {
	slog("v_setEventCallback %s cb=%p", t ? ((VService*)t)->name : "(null)", cb);
}
static void v_schedule(void* t, void* r, dispatch_queue_t q) {
	VService* s = t;
	if (!s) return;
	if (q) dispatch_retain(q);
	s->queue = q;
	slog("v_schedule %s queue=%p", s->name, q);
}
static void v_unschedule(void* t, void* r, dispatch_queue_t q) {
	if (!t) { slog("v_unschedule (null)"); return; }
	slog("v_unschedule %s", ((VService*)t)->name);
	((VService*)t)->queue = NULL;
}
static IOHIDEventRef v_copyEvent(void* t, void* r, uint32_t type, IOHIDEventRef m, IOOptionBits o) {
	if (t == &hinge_svc && (type == kIOHIDEventTypeHingeAngle || type == 0)) { slog("hinge copyEvent %.1f", hinge_deg); return hinge_event(); }
	return NULL;
}
static IOReturn v_setOutputEvent(void* t, void* r, IOHIDEventRef e) { return 0; }
static IOHIDEventRef v_copyMatchingEvent(void* t, void* r, CFDictionaryRef m) {
	if (t == &hinge_svc) { slog("hinge copyMatchingEvent %.1f", hinge_deg); return hinge_event(); }
	return NULL;
}

static const VirtualCallbacks callbacks = { 2, v_open, v_close, v_copyProperty, v_setProperty, v_setEventCallback,
	v_schedule, v_unschedule, v_copyEvent, v_setOutputEvent, v_copyMatchingEvent };

static CFDictionaryRef make_props(NSString* product, int page, int usage, NSDictionary* extra) {
	NSMutableDictionary* d = [NSMutableDictionary dictionaryWithDictionary:@{
		@"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage),
		@"DeviceUsagePairs": @[ @{ @"DeviceUsagePage": @(page), @"DeviceUsage": @(usage) } ],
		@"Product": product, @"Transport": @"Virtual", @"Built-In": @YES, @"Authenticated": @YES,
		@"VendorID": @0x5ac, @"ProductID": @0, @"LocationID": @0 }];
	if (extra) [d addEntriesFromDictionary:extra];
	return (CFDictionaryRef)[d retain];
}

static void add_service(IOHIDEventSystemRef_ sys, VService* s) {
	s->service = _IOHIDServiceCreateVirtual(kCFAllocatorDefault, s->id, &callbacks, s, NULL);
	if (!s->service) { slog("could not create %s", s->name); return; }
	_IOHIDEventSystemAddService(sys, s->service);
	slog("added %s service (id 0x%llx)", s->name, (unsigned long long)s->id);
}

static uint64_t now_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000000000ull + ts.tv_nsec; }

#if __arm64__
// Speed 34: detach the keyboard service again after SIMHID_KB_IDLE_S (default 30; 0 = never) without a key, as a
// hardware keyboard that goes away. While one is attached UIKit runs in hardware-keyboard mode, and SpringBoard's
// focus system then walks the focus environment on every app transition: +80-100 ms of SpringBoard CPU per warm
// Settings tap (630-720 ms vs 530-550 fresh), which is what "the aged system" was (the gate types into Spotlight /
// Settings search, and the attach stayed for the rest of the boot). The next key attaches it again (with the settle).
extern void _IOHIDEventSystemRemoveService(IOHIDEventSystemRef_, IOHIDServiceRef);
extern void _IOHIDServiceTerminate(IOHIDServiceRef);
static uint64_t kb_last_ns;
static uint64_t kb_idle_ns;  // idle detach of the client that sent the last key (kbidle, else SIMHID_KB_IDLE_S)
static uint64_t kb_default_idle_ns;
static int kb_down;  // keys held (no detach while one is down)
static pthread_mutex_t cmd_mu;
static pthread_cond_t kb_cv = PTHREAD_COND_INITIALIZER;
// Sleeps on kb_cv while no keyboard is attached (or it never detaches) instead of polling every 2 s for the whole
// boot: a thread that woke up while backboardd was being torn down at phone shutdown called through a stub that no
// longer pointed at code (guest pc garbage right after its sleep(2), backboardd crash reports at the end of boots).
// Woken by a key under cmd_mu. While a keyboard is attached it polls as before (pthread_cond_timedwait never timed
// out here: the keyboard stayed attached).
static void* kb_idle_thread(void* arg) {
	pthread_mutex_lock(&cmd_mu);
	for (;;) {
		const uint64_t idle = kb_idle_ns ? kb_idle_ns : kb_default_idle_ns;
		if (!keyboard_svc.service || !hid_system || kb_idle_ns == ~0ull || idle == ~0ull) {
			pthread_cond_wait(&kb_cv, &cmd_mu);
			continue;
		}
		pthread_mutex_unlock(&cmd_mu);
		sleep(2);
		pthread_mutex_lock(&cmd_mu);
		// a key-down whose key-up never came (viewer lost focus with a key held) must not keep the keyboard attached
		// forever (+90 ms per tap): held keys count only for 10 minutes after the last key
		const uint64_t since = now_ns() - kb_last_ns;
		if (!keyboard_svc.service || kb_idle_ns == ~0ull || !((kb_down <= 0 || since > 600000000000ull) && since > idle))
			continue;
		IOHIDServiceRef sv = keyboard_svc.service;
		keyboard_svc.service = NULL;
		_IOHIDEventSystemRemoveService(hid_system, sv);
		_IOHIDServiceTerminate(sv);
		CFRelease(sv);
		kb_down = 0;
		slog("keyboard detached (idle)");
	}
	return NULL;
}
#endif

static void dispatch_event(VService* s, IOHIDEventRef e) {
	if (!s->service || !e) {
		slog("dispatch_event drop service=%p e=%p", s ? s->service : NULL, e);
		if (e) CFRelease(e);
		return;
	}
	// x86Sim arm64: call _IOHIDServiceDispatchEvent on this thread. dispatch_async onto the
	// service queue / main queue was a silent no-op under the JIT for socket-thread producers
	// (reads happened, UI never saw touches). Direct dispatch matches Indigo's in-thread path.
	_IOHIDServiceDispatchEvent(s->service, e);
	CFRelease(e);
}

// --- events

static bool touching;
static uint64_t touch_up_ns;  // last touch lift (focus guard for keys, see handle_line)
static uint32_t touch_identity = 2;

static void send_touch(const char* phase, double x, double y, int edge) {
	bool down = !strcmp(phase, "down"), up = !strcmp(phase, "up"), move = !strcmp(phase, "move");
	if (!down && !up && !move) return;
	if (move && !touching) return;
	if (down) { if (touching) send_touch("up", x, y, 0); touching = true; touch_identity++; touch_edge = edge; }
	// (a single-finger down while two fingers are down: the two-finger contact is lifted first, see send_touch2)
	if (up) { if (!touching) return; touching = false; touch_up_ns = now_ns(); }
	uint64_t ts = mach_absolute_time();
	uint32_t mask = kDigitizerPosition | (down || up ? kDigitizerTouch | kDigitizerRange | kDigitizerIdentity : 0);
	mask |= edge_mask[touch_edge];
	bool in = !up;
	IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kDigitizerTransducerHand, 0, 0, mask, 0,
		x, y, 0, in ? 1 : 0, 0, in, in, 0);
	IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
	IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 1, touch_identity, mask,
		x, y, 0, in ? 1 : 0, 0, in, in, 0);
	IOHIDEventSetIntegerValue(finger, kFieldDigitizerIsDisplayIntegrated, 1);
	IOHIDEventAppendEvent(hand, finger, 0);
	CFRelease(finger);
	slog("touch %s (%.4f,%.4f) edge=%d svc=%s %p queue=%p", phase, x, y, touch_edge, cur_touch->name, cur_touch->service, cur_touch->queue);
	dispatch_event(cur_touch, hand);
}

// x86Sim: two fingers in one hand event, as a multi-touch digitizer reports them (the hand carries the centroid; a
// finger child per contact with its own index and identity; range/touch/identity bits on the down and up events).
static bool touching2;
static uint32_t touch2_identity = 1000;
static void send_touch2(const char* phase, double x1, double y1, double x2, double y2) {
	bool down = !strcmp(phase, "down"), up = !strcmp(phase, "up"), move = !strcmp(phase, "move");
	if (!down && !up && !move) return;
	if (move && !touching2) return;
	if (down) {
		if (touching) send_touch("up", x1, y1, 0);
		if (touching2) send_touch2("up", x1, y1, x2, y2);
		touching2 = true; touch2_identity += 2;
	}
	if (up) { if (!touching2) return; touching2 = false; }
	uint64_t ts = mach_absolute_time();
	uint32_t mask = kDigitizerPosition | (down || up ? kDigitizerTouch | kDigitizerRange | kDigitizerIdentity : 0);
	mask |= edge_mask[0];
	bool in = !up;
	IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kDigitizerTransducerHand, 0, 0, mask, 0,
		(x1 + x2) / 2, (y1 + y2) / 2, 0, in ? 1 : 0, 0, in, in, 0);
	IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
	double xs[2] = { x1, x2 }, ys[2] = { y1, y2 };
	for (int i = 0; i < 2; i++) {
		IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, i + 1, touch2_identity + i, mask,
			xs[i], ys[i], 0, in ? 1 : 0, 0, in, in, 0);
		IOHIDEventSetIntegerValue(finger, kFieldDigitizerIsDisplayIntegrated, 1);
		IOHIDEventAppendEvent(hand, finger, 0);
		CFRelease(finger);
	}
	dispatch_event(cur_touch, hand);
}

static void send_key(VService* s, uint32_t page, uint32_t usage, bool down) {
	dispatch_event(s, IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0));
}

typedef struct { int fd; uint64_t kb_idle_ns; int kb_settle_ms; } Client;  // kb_idle_ns 0: default; kb_settle_ms -1: default

// x86Sim (RAM 2): the time of the last user input, for cli/libexec/jetsam.py (an app the user is touching or typing
// into is never reclaimed): <SIMULATOR_SHARED_RESOURCES_DIRECTORY>/tmp/x86sim-input, its mtime touched at each touch,
// key or button command (at most once a second).
static void note_input(void) {
	static uint64_t last;
	static char path[256];
	uint64_t t = now_ns();
	if (last && t - last < 1000000000ull) return;
	last = t;
	if (!*path) {
		const char* dir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY") ?: getenv("HOME") ?: "/tmp";
		snprintf(path, sizeof(path), "%s/tmp/x86sim-input", dir);
	}
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) { (void)!write(fd, "1\n", 2); close(fd); }
}

static void handle_line(char* line, Client* cl) {
	unsigned scr;
	int skip = 0;
	if (line[0] == '@' && sscanf(line, "@%u %n", &scr, &skip) == 1 && skip > 0) {   // Models 2: another display's touch
		if (scr != 1 && (!inner_touch_svc.service || scr != inner_display_id)) { slog("no touchscreen for display %u", scr); return; }
		cur_touch = scr == 1 ? &touch_svc : &inner_touch_svc;
		handle_line(line + skip, cl);
		cur_touch = &touch_svc;
		return;
	}
	double deg;
	int ms = 600;
	if (!strcmp(line, "fold") || !strcmp(line, "unfold") || sscanf(line, "hinge %lf %d", &deg, &ms) >= 1) {
		if (!hinge_svc.service) { slog("no hinge on this device: %s", line); return; }
		double to = !strcmp(line, "fold") ? 0 : !strcmp(line, "unfold") ? 180 : deg < 0 ? 0 : deg > 180 ? 180 : deg;
		// a hinge moving as a hand opens it: 100 Hz reports (the ReportInterval CoreMotion sets) over <ms> with the
		// velocity, phase Began / Changed / Ended (IOHIDEventPhase 1 / 2 / 4); the device state follows the angle
		double from = hinge_deg;
		int steps = ms > 0 ? (ms + 9) / 10 : 0;
		slog("hinge %.1f -> %.1f in %d ms", from, to, ms);
		for (int i = 1; i <= steps; i++) {
			hinge_deg = from + (to - from) * i / steps;
			hinge_vel = (to - from) * 1000.0 / ms;
			hinge_phase = i == 1 ? 1 : 2;
			dispatch_event(&hinge_svc, hinge_event());
			if (i == 1) post_device_state(hinge_deg);
			pthread_mutex_unlock(&cmd_mu);
			usleep(10000);
			pthread_mutex_lock(&cmd_mu);
		}
		hinge_deg = to; hinge_vel = 0; hinge_phase = 4;
		dispatch_event(&hinge_svc, hinge_event());
		hinge_phase = 2;
		post_device_state(hinge_deg);
		return;
	}
	char a[16] = "", b[16] = "";
	double x = 0, y = 0;
	double x2 = 0, y2 = 0;
	if (!strncmp(line, "touch", 5) || !strncmp(line, "key ", 4) || !strncmp(line, "button ", 7)) note_input();
	if (sscanf(line, "touch2 %15s %lf %lf %lf %lf", a, &x, &y, &x2, &y2) == 5) { send_touch2(a, x, y, x2, y2); return; }
	if (sscanf(line, "touch %15s %lf %lf %15s", a, &x, &y, b) >= 3) {
		static const char* edges[5] = { "none", "top", "left", "bottom", "right" };
		int edge = 0;
		for (int i = 1; i < 5; i++) if (!strcmp(b, edges[i])) edge = i;
		send_touch(a, x, y, edge);
		return;
	}
	unsigned usage;
	if (sscanf(line, "key %15s %i", a, &usage) == 2) {
#if __arm64__
		// x86Sim arm64: the keyboard service is attached at the first key command (see initUsingHIDService).
		// Speed 31 held this client's keys for a fixed 1.5 s after every attach (keys 300 ms after the first were
		// lost or scrambled). Input: host keyboard latency (kblat.py) found the attach itself is ready in ~0.1 s
		// (backboardd sets the service's properties within 110 ms) and a burst typed 0 ms after it lands whole; what
		// scrambles keys is a field still taking focus: keys typed < ~0.7 s after the tap that focused it land
		// reordered ("settingsifi") whether or not the keyboard was attached just then. So: a short attach settle
		// (SIMHID_KB_SETTLE_MS, default 150) and a focus guard: a key within SIMHID_KB_TOUCH_GUARD_MS (default 1000)
		// of the last touch lift waits for the rest of it. Every other key goes out at once (was: the first burst
		// after each attach, i.e. after every 5 min pause in the launcher, came 1.2-1.5 s late).
		// The wait does not hold cmd_mu (the caller's lock is dropped around it): touches and keys of other clients
		// and the idle thread go on. This client's later lines queue in the socket, in order.
		int64_t wait_ns = 0;
		if (!keyboard_svc.service && hid_system) {
			add_service(hid_system, &keyboard_svc);
			const char* ms = getenv("SIMHID_KB_SETTLE_MS");
			wait_ns = (int64_t)(cl && cl->kb_settle_ms >= 0 ? cl->kb_settle_ms : ms && *ms ? atoi(ms) : 150) * 1000000;
		}
		{
			static int64_t guard = -1;
			if (guard < 0) { const char* g = getenv("SIMHID_KB_TOUCH_GUARD_MS"); guard = (int64_t)(g && *g ? atoi(g) : 1000) * 1000000; }
			const int64_t since = touch_up_ns ? (int64_t)(now_ns() - touch_up_ns) : INT64_MAX;
			if (guard - since > wait_ns) wait_ns = guard - since;
		}
		if (wait_ns > 0) {
			// kb_last_ns / kb_down first so the idle thread cannot detach the service meanwhile
			kb_last_ns = now_ns(); kb_down++;
			pthread_mutex_unlock(&cmd_mu);
			usleep((useconds_t)(wait_ns / 1000));
			pthread_mutex_lock(&cmd_mu);
			kb_down--;
			slog("key held %lld ms (attach settle / focus guard)", (long long)(wait_ns / 1000000));
		}
		kb_last_ns = now_ns();
		kb_idle_ns = cl ? cl->kb_idle_ns : 0;
		kb_down += !strcmp(a, "down") ? 1 : -1;
		if (kb_down < 0) kb_down = 0;
		pthread_cond_signal(&kb_cv);
#endif
		send_key(&keyboard_svc, 7, usage, !strcmp(a, "down"));
		return;
	}
	int secs;
	if (sscanf(line, "kbsettle %d", &secs) == 1) {
		if (cl) cl->kb_settle_ms = secs;
		slog("client fd=%d kbsettle %d", cl ? cl->fd : -1, secs);
		return;
	}
	if (sscanf(line, "kbidle %d", &secs) == 1) {
#if __arm64__
		// <= 0: never detach after this client's keys (like SIMHID_KB_IDLE_S=0)
		if (cl) cl->kb_idle_ns = secs > 0 ? (uint64_t)secs * 1000000000ull : ~0ull;
		slog("client fd=%d kbidle %d", cl ? cl->fd : -1, secs);
#endif
		return;
	}
	double delta;
	if (sscanf(line, "crown %lf %15s", &delta, a) >= 1) {
		if (!crown_svc.service) { slog("no digital crown on this device: %s", line); return; }
		note_input();
		const char axis = strchr(line + 6, ' ') ? a[0] : 'y';
		dispatch_event(&crown_svc, IOHIDEventCreateScrollEvent(kCFAllocatorDefault, mach_absolute_time(),
			axis == 'x' ? delta : 0, axis == 'y' ? delta : 0, axis == 'z' ? delta : 0, 0));
		slog("crown %.2f (%c)", delta, axis);
		return;
	}
	unsigned page;
	if (sscanf(line, "usage %i %i %15s", &page, &usage, a) == 3) {   // Platforms 1: any page/usage on the buttons service
		note_input();
		send_key(&buttons_svc, page, usage, !strcmp(a, "down"));
		slog("usage 0x%x/0x%x %s", page, usage, a);
		return;
	}
	if (sscanf(line, "button %15s %15s", a, b) == 2) {
		bool down = !strcmp(b, "down");
		// consumer page: 0x40 menu (home), 0x30 power (lock), 0xe9/0xea volume.
		// Platforms 1: tvOS reads 0x40 as the Siri Remote's Back (Menu) and 0x60 as its TV button (PineBoard's home;
		// found by trying usages, see SIMHID.md), 0xcd play / pause; holding 0x30 sleeps the TV. On a watch 0x40 is
		// the crown's press and 0x30 the side button ("side").
		uint32_t u = !strcmp(a, "home") || !strcmp(a, "menu") ? 0x40 : !strcmp(a, "lock") || !strcmp(a, "side") ? 0x30
			: !strcmp(a, "volup") ? 0xe9 : !strcmp(a, "voldown") ? 0xea : !strcmp(a, "tv") ? 0x60
			: !strcmp(a, "playpause") ? 0xcd : 0;
		if (u) send_key(&buttons_svc, 0x0c, u, down);
		else slog("unknown button: %s", a);
		return;
	}
	if (*line) slog("unknown command: %s", line);
}

// x86Sim arm64: serialize with a mutex instead of dispatch_sync. dispatch_sync from the
// socket pthread onto cmd_q was observed to consume socket bytes without ever running the
// block under the A64 JIT (no touch logs, no UI). Mutex + direct call stays on this GuestThread.
static pthread_mutex_t cmd_mu = PTHREAD_MUTEX_INITIALIZER;
static void* client_thread(void* arg) {
	int fd = (int)(intptr_t)arg;
	Client cl = { fd, 0, -1 };
	slog("client_thread fd=%d", fd);
	char buf[4096];
	size_t n = 0;
	for (;;) {
		ssize_t r = read(fd, buf + n, sizeof(buf) - 1 - n);
		if (r <= 0) break;
		n += r;
		buf[n] = 0;
		char* start = buf;
		char* nl;
		while ((nl = strchr(start, '\n'))) {
			*nl = 0;
			if (nl > start && nl[-1] == '\r') nl[-1] = 0;
			pthread_mutex_lock(&cmd_mu);
			handle_line(start, &cl);
			pthread_mutex_unlock(&cmd_mu);
			start = nl + 1;
		}
		n = strlen(start);
		memmove(buf, start, n);
		if (n >= sizeof(buf) - 1) n = 0;
	}
	slog("client_thread fd=%d done", fd);
	close(fd);
	return NULL;
}

// A socket path that does not fit sockaddr_un.sun_path (104 bytes on Darwin; the Linux path plus Darling's
// /Volumes/SystemRoot, e.g. a long home or device name) used to be cut short by strlcpy: unlink removed the real path,
// bind made a truncated sibling, and the next boot failed with EADDRINUSE. Such a socket now lives next to the phone's
// frame ring (SIMFB_RING's directory, /run/user/<uid>), named after the phone, and the expected path becomes a symlink
// to its Linux path: the clients (simview, simtouch, the launcher) are on Linux, nothing in the guest connects.
// Reported with a fix by Prathamesh913 (x86sim/x86sim#1).
static const char kSystemRoot[] = "/Volumes/SystemRoot";

static bool short_socket(const char* path, char* out, size_t n) {
	char dir[256];
	const char* ring = getenv("SIMFB_RING");
	const char* slash = ring ? strrchr(ring, '/') : NULL;
	if (slash && strncmp(ring, kSystemRoot, sizeof(kSystemRoot) - 1) == 0)
		snprintf(dir, sizeof(dir), "%.*s", (int)(slash - ring), ring);
	else
		snprintf(dir, sizeof(dir), "%s/run/user/%u", kSystemRoot, (unsigned)getuid());
	const char* udid = getenv("SIMULATOR_UDID");
	uint64_t h = 1469598103934665603ull;  // FNV-1a of the path, for a phone without a UDID
	for (const char* p = path; *p; p++) h = (h ^ (uint8_t)*p) * 1099511628211ull;
	int w = udid && *udid ? snprintf(out, n, "%s/x86sim-simhid-%s.sock", dir, udid)
	                      : snprintf(out, n, "%s/x86sim-simhid-%016llx.sock", dir, (unsigned long long)h);
	return w > 0 && (size_t)w < n;
}

static void* listen_thread(void* arg) {
	char path[256], bound[256];
	struct sockaddr_un a = { 0 };
	const char* env = getenv("SIMHID_SOCKET");
	const char* dir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY") ?: getenv("HOME") ?: "/tmp";
	if (env) snprintf(path, sizeof(path), "%s", env); else snprintf(path, sizeof(path), "%s/simhid.sock", dir);
	bool linked = strlen(path) >= sizeof(a.sun_path);
	if (linked && !short_socket(path, bound, sizeof(a.sun_path))) {
		slog("cannot listen on %s: path too long (%zu bytes) and no short path fits", path, strlen(path));
		return NULL;
	}
	if (!linked) snprintf(bound, sizeof(bound), "%s", path);
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	a.sun_family = AF_UNIX;
	strlcpy(a.sun_path, bound, sizeof(a.sun_path));
	unlink(bound);
	if (bind(s, (struct sockaddr*)&a, sizeof(a)) != 0 || listen(s, 8) != 0) {
		slog("cannot listen on %s: errno %d", bound, errno);
		return NULL;
	}
	if (linked) {
		// the link names the Linux path; the guest's view of it (/Volumes/SystemRoot/...) means nothing to the clients
		const char* target = strncmp(bound, kSystemRoot, sizeof(kSystemRoot) - 1) == 0 ? bound + sizeof(kSystemRoot) - 1 : bound;
		unlink(path);
		if (symlink(target, path) != 0) slog("cannot link %s -> %s: errno %d", path, target, errno);
		slog("listening on %s (%s is too long for sun_path)", target, path);
	} else {
		slog("listening on %s", path);
	}
	for (;;) {
		// x86Sim: Darling's accept() crashes with a NULL address (it converts the sockaddr back unconditionally)
		struct sockaddr_un peer; socklen_t plen = sizeof(peer);
		int c = accept(s, (struct sockaddr*)&peer, &plen);
		if (c < 0) { if (errno == EINTR) continue; slog("accept: errno %d", errno); usleep(100000); continue; }
		pthread_t t;
		pthread_create(&t, NULL, client_thread, (void*)(intptr_t)c);
		pthread_detach(t);
	}
	return NULL;
}

@protocol SimulatorClientHIDSystemManager <NSObject>
- (instancetype)initUsingHIDService:(IOHIDEventSystemRef_)system error:(NSError**)error;
@end

@interface SimHIDSystem : NSObject <SimulatorClientHIDSystemManager>
@end

@implementation SimHIDSystem
- (instancetype)initUsingHIDService:(IOHIDEventSystemRef_)system error:(NSError**)error {
	if (!(self = [super init])) return nil;
	if (!system) { if (error) *error = [NSError errorWithDomain:@"SimHID" code:1 userInfo:nil]; [self release]; return nil; }
	// displayUUID must match SFBDisplayGetDisplayUID ("x86Sim-main-display"): BKIOHIDService
	// _setUpInitialProperties copies the HID property "displayUUID" into its ivar; without it,
	// BKDisplayConvertCAScreenLocationToContext gets a null UUID and drops every touch.
	touch_svc = (VService){ "touchscreen", 0x7863000000000001ull,
		make_props(@"com.apple.SimulatorHID.ScreenTouchService.x86Sim-main-display", 0x0d, 0x04, @{
			@"DisplayIntegrated": @YES,
			@"SupportsInk": @NO,
			@"displayUUID": @"x86Sim-main-display",
		}) };
	buttons_svc = (VService){ "buttons", 0x7863000000000002ull, make_props(@"x86Sim buttons", 0x0c, 0x01, nil) };
	keyboard_svc = (VService){ "keyboard", 0x7863000000000003ull, make_props(@"x86Sim keyboard", 0x01, 0x06, nil) };
	add_service(system, &touch_svc);
	add_service(system, &buttons_svc);
	{
		const char* model = getenv("SIMULATOR_MODEL_IDENTIFIER");
		if (model && !strncmp(model, "Watch", 5)) {
			crown_svc = (VService){ "crown", 0x7863000000000006ull,
				make_props(@"com.apple.SimulatorHID.MainScreenDigitalCrownService", 0xff0b, 0x01, nil) };
			add_service(system, &crown_svc);
		}
	}
	// Models 2: the second integrated display of $SIMULATOR_CAPABILITIES (as host/simfb publishes it: SFB display
	// <screenID>, UID x86Sim-display-<screenID>) gets its own touchscreen, and the device a hinge sensor
	{
		const char* cp = getenv("SIMULATOR_CAPABILITIES");
		NSDictionary* caps = cp ? [NSDictionary dictionaryWithContentsOfFile:@(cp)] : nil;
		NSArray* disps = [caps[@"capabilities"] isKindOfClass:[NSDictionary class]] ? caps[@"capabilities"][@"displays"] : caps[@"displays"];
		int n = 0;
		for (NSDictionary* d in [disps isKindOfClass:[NSArray class]] ? disps : @[]) {
			if (![d isKindOfClass:[NSDictionary class]] || ![d[@"displayType"] isEqual:@"integrated"]) continue;
			if (n++ == 1) inner_display_id = [d[@"screenID"] unsignedIntValue];
		}
		if (n >= 2 && inner_display_id) {
			NSString* uid = [NSString stringWithFormat:@"x86Sim-display-%u", inner_display_id];
			inner_touch_svc = (VService){ "touchscreen-inner", 0x7863000000000004ull,
				make_props([@"com.apple.SimulatorHID.ScreenTouchService." stringByAppendingString:uid], 0x0d, 0x04, @{
					@"DisplayIntegrated": @YES, @"SupportsInk": @NO, @"displayUUID": uid }) };
			hinge_svc = (VService){ "hinge", 0x7863000000000005ull, make_props(@"x86Sim hinge", 0xff0c, 0x21, nil) };
			const char* h = getenv("SIMHID_HINGE");
			hinge_deg = h && *h ? atof(h) : 0;
			add_service(system, &inner_touch_svc);
			add_service(system, &hinge_svc);
			write_hinge_file(hinge_deg);
		}
	}
#if __arm64__
	// x86Sim arm64: an attached keyboard service puts UIKit in hardware-keyboard mode, so a text field never shows the
	// software keyboard. Attach it only when the host first types (like Xcode's simulator does); SIMHID_KEYBOARD=1: at start.
	hid_system = system;
	const char* kb = getenv("SIMHID_KEYBOARD");
	if (kb && *kb == '1')
		add_service(system, &keyboard_svc);
	else {  // Speed 34: idle detach of an on-demand keyboard (SIMHID_KEYBOARD=1 keeps it attached)
		const char* is = getenv("SIMHID_KB_IDLE_S");
		const int idle = is && *is ? atoi(is) : 30;
		// the thread also runs with SIMHID_KB_IDLE_S=0 (default "never"), so a client's kbidle still applies
		kb_default_idle_ns = idle > 0 ? (uint64_t)idle * 1000000000ull : ~0ull;
		{
			pthread_t kt;
			pthread_create(&kt, NULL, kb_idle_thread, NULL);
			pthread_detach(kt);
		}
	}
#else
	add_service(system, &keyboard_svc);
#endif
	pthread_t t;
	pthread_create(&t, NULL, listen_thread, NULL);
	pthread_detach(t);
	slog("SimHIDSystem ready");
	return self;
}
@end
