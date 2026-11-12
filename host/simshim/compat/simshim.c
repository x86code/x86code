// x86Sim simulator shim, injected into every simulator process (mksimdevice.py).
// Stands in for host services a Linux host does not provide:
//
// - System power: IORegisterForSystemPower needs IOPMrootDomain, which Darling's
//   iokitd lacks. Return a working registration whose notification port never fires
//   (the "machine" never sleeps). Interposition only reaches callers outside the dyld
//   shared cache (plugins, daemons' own code), which is where these calls come from.
#include <IOKit/IOKitLib.h>
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <bsm/audit.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <mach/mach_time.h>
#include <time.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <semaphore.h>
#include <sqlite3.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
	__attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void*) (unsigned long) &_replacement, (const void*) (unsigned long) &_replacee };

typedef void (*IOServiceInterestCallback)(void* refcon, io_service_t service, uint32_t messageType, void* messageArgument);
extern io_connect_t IORegisterForSystemPower(void* refcon, IONotificationPortRef* thePortRef,
	IOServiceInterestCallback callback, io_object_t* notifier);
extern IOReturn IODeregisterForSystemPower(io_object_t* notifier);
extern IOReturn IOAllowPowerChange(io_connect_t kernelPort, intptr_t notificationID);

// x86Sim (Speed 24): the fake ports are dead names, and IOServiceClose / IOObjectRelease on them succeed here. They
// are MIG calls to the object's port; while this process held the receive right, nothing ever replied. iOS 27.2's
// NSURLSession closes its system-power connection with IOServiceClose when a session is invalidated, so geod's
// session queue blocked for good, and Maps waited for geod at launch (black screen, SpringBoard waiting on Maps).
static mach_port_t fake_ports[64];
static int fake_nports;
static mach_port_t fake_port(void)
{
	mach_port_t port = MACH_PORT_NULL;
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS) {
		mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
		// a dead name: a MIG request on it (io_service_close, io_object_release, ... from code the interposers below
		// don't reach, inside the shared cache) fails at once instead of waiting for a reply nobody sends
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
	}
	int i = __atomic_fetch_add(&fake_nports, 1, __ATOMIC_RELAXED);
	if (i < 64)
		fake_ports[i] = port;
	return port;
}
static int is_fake_port(mach_port_t port)
{
	if (port == MACH_PORT_NULL)
		return 0;
	int n = __atomic_load_n(&fake_nports, __ATOMIC_RELAXED);
	for (int i = 0; i < n && i < 64; i++)
		if (fake_ports[i] == port)
			return 1;
	return 0;
}
static IOReturn shim_IOServiceClose(io_connect_t connect)
{
	return is_fake_port(connect) ? kIOReturnSuccess : IOServiceClose(connect);
}
DYLD_INTERPOSE(shim_IOServiceClose, IOServiceClose)
static kern_return_t shim_IOObjectRelease(io_object_t object)
{
	return is_fake_port(object) ? KERN_SUCCESS : IOObjectRelease(object);
}
DYLD_INTERPOSE(shim_IOObjectRelease, IOObjectRelease)

static io_connect_t shim_IORegisterForSystemPower(void* refcon, IONotificationPortRef* thePortRef,
	IOServiceInterestCallback callback, io_object_t* notifier)
{
	io_connect_t real = IORegisterForSystemPower(refcon, thePortRef, callback, notifier);
	if (real != MACH_PORT_NULL)
		return real;
	if (thePortRef)
		*thePortRef = IONotificationPortCreate(MACH_PORT_NULL);
	if (notifier)
		*notifier = fake_port();
	return fake_port();
}
DYLD_INTERPOSE(shim_IORegisterForSystemPower, IORegisterForSystemPower)

static IOReturn shim_IODeregisterForSystemPower(io_object_t* notifier) { return kIOReturnSuccess; }
DYLD_INTERPOSE(shim_IODeregisterForSystemPower, IODeregisterForSystemPower)

static IOReturn shim_IOAllowPowerChange(io_connect_t kernelPort, intptr_t id) { return kIOReturnSuccess; }
DYLD_INTERPOSE(shim_IOAllowPowerChange, IOAllowPowerChange)

// libsystem_sim_kernel's csops_audittoken serves entitlement blobs itself but fails a short
// buffer with ENOENT instead of ERANGE (Darling's csops syscall gets it right), so libxpc gives up on
// any client whose entitlements exceed its first 0x408-byte guess (lsd: containermanagerd
// then refuses it). Route those ops through csops; the audit token names the same pid.
// Platforms 1: the same libSystem symbol under another name (tvOS/watchOS headers mark syscall() unavailable)
extern int x86sim_syscall(int, ...) __asm("_syscall");
static int is_entitlements_op(unsigned int ops)
{
	return ops == 7 /* CS_OPS_ENTITLEMENTS_BLOB */ || ops == 16 /* CS_OPS_DER_ENTITLEMENTS_BLOB */;
}
extern int csops_audittoken(pid_t pid, unsigned int ops, void* useraddr, size_t usersize, audit_token_t* token);
static int shim_csops_audittoken(pid_t pid, unsigned int ops, void* useraddr, size_t usersize, audit_token_t* token)
{
	if (is_entitlements_op(ops))
	{
		// the raw syscall: csops() in the simulator is libsystem_sim_kernel's own version
		int r = x86sim_syscall(169 /* SYS_csops */, pid, ops, useraddr, usersize);
		if (getenv("X86SIM_SHIMLOG"))
		{
			char line[128];
			int n = snprintf(line, sizeof(line), "simshim: csops_audittoken(%d, %u, %zu) -> %d errno %d\n", pid, ops, usersize, r, r ? errno : 0);
			write(2, line, n);
		}
		return r;
	}
	return csops_audittoken(pid, ops, useraddr, usersize, token);
}
DYLD_INTERPOSE(shim_csops_audittoken, csops_audittoken)

// Same for plain csops() (Security's SecTask uses it): entitlement blobs via the syscall
extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
static int shim_csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize)
{
	if (is_entitlements_op(ops))
		return x86sim_syscall(169 /* SYS_csops */, pid, ops, useraddr, usersize);
	return csops(pid, ops, useraddr, usersize);
}
DYLD_INTERPOSE(shim_csops, csops)

// Diagnostics: print every Objective-C exception's name and reason to stderr (os_log may be
// off), then throw it as usual
extern void objc_exception_throw(id exception) __attribute__((noreturn));
static void shim_print_cfstring(const char* label, CFStringRef s)
{
	char buf[1024] = "(null)";
	if (s)
		CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
	char line[1200];
	int n = snprintf(line, sizeof(line), "simshim: exception %s: %s\n", label, buf);
	write(2, line, n);
}
static void shim_objc_exception_throw(id exception) __attribute__((noreturn));
static void shim_objc_exception_throw(id exception)
{
	CFStringRef (*msg)(id, SEL) = (CFStringRef (*)(id, SEL)) objc_msgSend;
	shim_print_cfstring("name", msg(exception, sel_registerName("name")));
	shim_print_cfstring("reason", msg(exception, sel_registerName("reason")));
	void* frames[48];
	int n = backtrace(frames, 48);
	for (int i = 0; i < n; i++)
	{
		Dl_info info;
		char line[512];
		int len;
		if (dladdr(frames[i], &info) && info.dli_fname)
			len = snprintf(line, sizeof(line), "simshim:   %p %s+%#lx (%s+%#lx)\n", frames[i], strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
				(unsigned long) ((char*) frames[i] - (char*) info.dli_fbase), info.dli_sname ? info.dli_sname : "?", info.dli_saddr ? (unsigned long) ((char*) frames[i] - (char*) info.dli_saddr) : 0);
		else
			len = snprintf(line, sizeof(line), "simshim:   %p\n", frames[i]);
		write(2, line, len);
	}
	objc_exception_throw(exception);
}
DYLD_INTERPOSE(shim_objc_exception_throw, objc_exception_throw)

// With os_log disabled (OS_ACTIVITY_MODE=disable, there is no logd), os_state_add_handler
// returns 0 and BaseBoard's BSLogAddStateCaptureBlockWithTitle returns nil, which SpringBoard
// adds to a set (PaperBoardUI) and crashes. Hand out dummy handles instead.
typedef uint64_t os_state_handle_t;
extern os_state_handle_t os_state_add_handler(dispatch_queue_t queue, void* block);
extern void os_state_remove_handler(os_state_handle_t handle);
#define SHIM_STATE_HANDLE_BASE 0x7a000000ULL
// x86Sim (Speed 24, diagnostics): X86SIM_STATEDUMP=<dir> in a job's environment (X86SIM_JOBENV) keeps its
// state-capture handlers (what sysdiagnose collects: RunningBoard's assertions and process states, ...); creating
// <dir>/req runs them all (every 5 s while it exists) and writes each one's title and data (a binary plist holding a
// description string; `strings` reads it) to <dir>/<pid>.<n>. <dir> must not be in the prefix overlay (the guest
// caches the miss): use a guest path into the device data, e.g. /Volumes/SystemRoot<data>/tmp/x86sim-state.
struct shim_state_hints { uint32_t version; const char* requestor; uint32_t api; uint32_t reason; };
struct shim_state_data { uint32_t type; uint32_t size; char decoder[96]; char title[64]; uint8_t data[]; };
typedef struct shim_state_data* (^shim_state_block)(struct shim_state_hints*);
static struct { dispatch_queue_t q; shim_state_block b; } shim_state[64];
static int shim_nstate;
static void shim_state_run(void* ctx)
{
	char req[512];
	snprintf(req, sizeof req, "%s/req", (const char*) ctx);
	if (access(req, F_OK))
		return;
	for (int i = 0; i < shim_nstate; i++)
		dispatch_async(shim_state[i].q ? shim_state[i].q : dispatch_get_global_queue(0, 0), ^{
			struct shim_state_hints h = { 1, "x86sim", 1, 1 };
			struct shim_state_data* d = shim_state[i].b(&h);
			if (!d)
				return;
			char p[512];
			snprintf(p, sizeof p, "%s/%d.%d", (const char*) ctx, getpid(), i);
			int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
			if (fd >= 0) { dprintf(fd, "%.64s\n", d->title); write(fd, d->data, d->size); close(fd); }
			free(d);
		});
}
static void shim_state_keep(dispatch_queue_t queue, void* block)
{
	static dispatch_source_t timer;
	const char* dir = getenv("X86SIM_STATEDUMP");
	if (!dir || shim_nstate >= 64)
		return;
	shim_state[shim_nstate].q = queue;
	shim_state[shim_nstate].b = Block_copy((shim_state_block) block);
	shim_nstate++;
	if (!timer) {
		timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
		dispatch_set_context(timer, strdup(dir));
		dispatch_source_set_event_handler_f(timer, shim_state_run);
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
		dispatch_resume(timer);
	}
}
static os_state_handle_t shim_os_state_add_handler(dispatch_queue_t queue, void* block)
{
	static uint64_t next = SHIM_STATE_HANDLE_BASE;
	os_state_handle_t h = os_state_add_handler(queue, block);
	shim_state_keep(queue, block);
	return h ? h : __atomic_add_fetch(&next, 1, __ATOMIC_RELAXED);
}
DYLD_INTERPOSE(shim_os_state_add_handler, os_state_add_handler)
static void shim_os_state_remove_handler(os_state_handle_t handle)
{
	if (handle <= SHIM_STATE_HANDLE_BASE || handle > SHIM_STATE_HANDLE_BASE + 0x1000000)
		os_state_remove_handler(handle);
}
DYLD_INTERPOSE(shim_os_state_remove_handler, os_state_remove_handler)

// Diagnostics: log failing sqlite3_open_v2 calls (path, result, message, errno)
static int shim_sqlite3_open_v2(const char* filename, sqlite3** db, int flags, const char* vfs)
{
	int rc = sqlite3_open_v2(filename, db, flags, vfs);
	if (rc != SQLITE_OK)
	{
		char line[1200];
		int n = snprintf(line, sizeof(line), "simshim: sqlite3_open_v2(%s, flags %#x, vfs %s) -> %d %s errno %d\n",
			filename, flags, vfs ? vfs : "-", rc, db && *db ? sqlite3_errmsg(*db) : "?", db && *db ? sqlite3_system_errno(*db) : 0);
		write(2, line, n);
	}
	return rc;
}
DYLD_INTERPOSE(shim_sqlite3_open_v2, sqlite3_open_v2)

// Sandbox extensions: the simulator's libsystem_sandbox issues them through __mac_syscall("Sandbox"), which
// Darling does not implement (ENOSYS), and nothing is sandboxed here anyway. Issue opaque tokens and accept any
// token. Without them PosterBoard could not hand poster paths to its extensions ("cannot extend access ...
// sandbox errno=78") and drew no wallpaper.
extern char* sandbox_extension_issue_file(const char*, const char*, uint32_t);
extern char* sandbox_extension_issue_file_to_process(const char*, const char*, uint32_t, audit_token_t);
extern char* sandbox_extension_issue_file_to_process_by_pid(const char*, const char*, uint32_t, pid_t);
extern char* sandbox_extension_issue_file_to_self(const char*, const char*, uint32_t);
extern char* sandbox_extension_issue_generic(const char*, uint32_t);
extern char* sandbox_extension_issue_generic_to_process(const char*, uint32_t, audit_token_t);
extern char* sandbox_extension_issue_generic_to_process_by_pid(const char*, uint32_t, pid_t);
extern char* sandbox_extension_issue_mach(const char*, const char*, uint32_t);
extern char* sandbox_extension_issue_mach_to_process(const char*, const char*, uint32_t, audit_token_t);
extern char* sandbox_extension_issue_mach_to_process_by_pid(const char*, const char*, uint32_t, pid_t);
extern char* sandbox_extension_issue_iokit_registry_entry_class(const char*, const char*, uint32_t);
extern char* sandbox_extension_issue_iokit_registry_entry_class_to_process(const char*, const char*, uint32_t, audit_token_t);
extern char* sandbox_extension_issue_iokit_registry_entry_class_to_process_by_pid(const char*, const char*, uint32_t, pid_t);
extern int64_t sandbox_extension_consume(const char*);
extern int sandbox_extension_release(int64_t);
static char* fake_token(const char* cls, const char* what)
{
	char buf[1200];
	snprintf(buf, sizeof(buf), "x86sim-sandbox-extension;%s;%s", cls ? cls : "", what ? what : "");
	return strdup(buf);
}
#define SB_FILE(name, ...) static char* shim_##name(const char* cls, const char* path, uint32_t flags, ##__VA_ARGS__) { return fake_token(cls, path); } DYLD_INTERPOSE(shim_##name, name)
#define SB_GEN(name, ...) static char* shim_##name(const char* cls, uint32_t flags, ##__VA_ARGS__) { return fake_token(cls, NULL); } DYLD_INTERPOSE(shim_##name, name)
SB_FILE(sandbox_extension_issue_file)
SB_FILE(sandbox_extension_issue_file_to_process, audit_token_t t)
SB_FILE(sandbox_extension_issue_file_to_process_by_pid, pid_t p)
SB_FILE(sandbox_extension_issue_file_to_self)
SB_GEN(sandbox_extension_issue_generic)
SB_GEN(sandbox_extension_issue_generic_to_process, audit_token_t t)
SB_GEN(sandbox_extension_issue_generic_to_process_by_pid, pid_t p)
SB_FILE(sandbox_extension_issue_mach)
SB_FILE(sandbox_extension_issue_mach_to_process, audit_token_t t)
SB_FILE(sandbox_extension_issue_mach_to_process_by_pid, pid_t p)
SB_FILE(sandbox_extension_issue_iokit_registry_entry_class)
SB_FILE(sandbox_extension_issue_iokit_registry_entry_class_to_process, audit_token_t t)
SB_FILE(sandbox_extension_issue_iokit_registry_entry_class_to_process_by_pid, pid_t p)
static int64_t shim_sandbox_extension_consume(const char* token)
{
	if (!token) { errno = EINVAL; return -1; }
	static int64_t next = 1;
	return __atomic_fetch_add(&next, 1, __ATOMIC_RELAXED);
}
DYLD_INTERPOSE(shim_sandbox_extension_consume, sandbox_extension_consume)
static int shim_sandbox_extension_release(int64_t handle) { return 0; }
DYLD_INTERPOSE(shim_sandbox_extension_release, sandbox_extension_release)

// x86Sim: no Metal here. IconFoundation's -[IFConcreteImage ICRIconLayer] (and CALayer, which calls it) builds the icon layer natively
// (ICRIconLayer: needs an RBDevice, i.e. Metal, and the image's layer data, which iconservicesagent cannot
// produce with its software renderer: "layer data size zero", TextureIOError.usingSoftwareRenderer), else nil.
// SpringBoard's home screen asks for native layers only (SBHGetIconLayerFromIconServicesImage without the
// CGImage-fallback option), so every icon loaded asynchronously after a cache miss stayed a gray placeholder
// (only icons served synchronously from a warm cache, which go the UIImage path, had colour). Fall back to a
// plain CALayer with the flat CGImage as contents, as SBHGetIconLayerFromIconServicesImage itself does with
// that option.
static IMP shim_ifimage_calayer_orig;
static id shim_ifimage_calayer(id self, SEL sel)
{
	id layer = ((id (*)(id, SEL)) shim_ifimage_calayer_orig)(self, sel);
	static int n;
	if (n++ < 3) { char b[160]; int k = snprintf(b, sizeof b, "simshim: IFConcreteImage ICRIconLayer -> %p\n", (void*) layer); write(2, b, k); }
	if (layer)
		return layer;
	void* image = ((void* (*)(id, SEL)) objc_msgSend)(self, sel_registerName("CGImage"));
	Class ca = objc_getClass("CALayer");
	if (!image || !ca)
		return nil;
	// off the main thread CA aborts on an implicit transaction: use an explicit background one, as
	// SBHGetIconLayerFromIconServicesImage does
	Class tx = objc_getClass("CATransaction");
	bool bg = !pthread_main_np() && tx;
	if (bg) {
		((void (*)(Class, SEL)) objc_msgSend)(tx, sel_registerName("begin"));
		if (class_respondsToSelector(object_getClass((id) tx), sel_registerName("activateBackground:")))
			((void (*)(Class, SEL, BOOL)) objc_msgSend)(tx, sel_registerName("activateBackground:"), YES);
	}
	layer = ((id (*)(Class, SEL)) objc_msgSend)(ca, sel_registerName("layer"));
	((void (*)(id, SEL, id)) objc_msgSend)(layer, sel_registerName("setContents:"), (id) image);
	double scale = ((double (*)(id, SEL)) objc_msgSend)(self, sel_registerName("scale"));
	if (scale > 0)
		((void (*)(id, SEL, double)) objc_msgSend)(layer, sel_registerName("setContentsScale:"), scale);
	if (bg)
		((void (*)(Class, SEL)) objc_msgSend)(tx, sel_registerName("commit"));
	return layer;
}
static void shim_ifimage_added(const struct mach_header* mh, intptr_t slide)
{
	if (shim_ifimage_calayer_orig)
		return;
	Class c = objc_getClass("IFConcreteImage");
	Method m = c ? class_getInstanceMethod(c, sel_registerName("ICRIconLayer")) : NULL;
	if (!m)
		return;
	shim_ifimage_calayer_orig = method_setImplementation(m, (IMP) shim_ifimage_calayer);
	write(2, "simshim: hooked IFConcreteImage ICRIconLayer\n", 45);
}
__attribute__((constructor)) static void shim_ifimage_init(void)
{
	_dyld_register_func_for_add_image(shim_ifimage_added);
}

// x86Sim Platforms 1: tvOS system sleep. PineBoard's sleep (power button held, Settings > Sleep Now, the idle timer) runs
// -[PBPowerManager sleepSystemWithReason:completion:]: its own will-sleep step sends HDMI-CEC standby through
// +[PBExternalControlSystem sendAction:withCompletion:] and then cycles the display mode for sleep, and neither ever
// answers here (no HDMI sink, no CEC). The power state stayed "going down to sleep" (2), PineBoard's hot-black window
// covered the screen, and every wake was refused ("Unable to wake device for launch ... (wake failed)", power manager
// error 8001): a black TV until the device was restarted. The simulator has no TV to put in standby: the request
// completes at once as declined (NO, nil) and the system stays awake. X86SIM_TV_SLEEP=1 keeps PineBoard's own.
static void shim_pb_sleep(id self, SEL sel, unsigned long reason, void (^completion)(BOOL, id))
{
	(void) self; (void) sel;
	char b[120];
	int k = snprintf(b, sizeof b, "simshim: PineBoard sleep request (reason %lu) declined: no TV to put in standby\n", reason);
	write(2, b, k);
	if (completion)
		completion(NO, nil);
}
static void shim_pb_added(const struct mach_header* mh, intptr_t slide)
{
	static bool done;
	if (done)
		return;
	Class c = objc_getClass("PBPowerManager");
	Method m = c ? class_getInstanceMethod(c, sel_registerName("sleepSystemWithReason:completion:")) : NULL;
	if (!m)
		return;
	done = true;
	method_setImplementation(m, (IMP) shim_pb_sleep);
	write(2, "simshim: hooked PBPowerManager sleepSystemWithReason:completion:\n", 65);
}
// x86Sim Platforms 2 (visionOS): wakeboardd (the compositor) opens the named semaphore "wakeboardd.first-boot" and,
// when it has no count (the first wakeboardd since the device booted), keeps the display "pulsing until system shell
// (backboardd) comes up". Here that never ended: its real-time render loop never started, so backboardd's compositor
// layer timed out every 10 s (com.apple.compositor.layer -1000) and nothing was ever drawn. The semaphore is given its
// count before wakeboardd looks, as on its later starts. X86SIM_XR_PULSE=1 keeps the first-boot pulse.
// DEBUG (Platforms 2): log compositor-layer errors with their userInfo (the underlying error a -1000 wraps)
static id (*orig_err)(id, SEL, id, long, id);
static id dbg_err(id cls, SEL sel, id domain, long code, id info)
{
	if (code == -1000 && info) {
		id d = ((id (*)(id, SEL))objc_msgSend)(info, sel_registerName("description"));
		const char* c = d ? ((const char* (*)(id, SEL))objc_msgSend)(d, sel_registerName("UTF8String")) : "?";
		fprintf(stderr, "simshim: -1000 userInfo: %s\n", c);
	}
	return orig_err(cls, sel, domain, code, info);
}

static id (*orig_nst)(id, SEL, id);
static id dbg_nst(id self, SEL sel, id desc)
{
	id r = orig_nst(self, sel, desc);
	fprintf(stderr, "simshim: MTLSimDevice newSharedTextureWithDescriptor -> %p\n", (void*)r);
	return r;
}
static id (*orig_tinit)(id, SEL, id, unsigned long, void*, unsigned long, void*, id, id, BOOL);
static id dbg_tinit(id self, SEL sel, id desc, unsigned long fmt, void* surf, unsigned long plane, void* ref, id heap, id dev, BOOL shareable)
{
	id r = orig_tinit(self, sel, desc, fmt, surf, plane, ref, heap, dev, shareable);
	fprintf(stderr, "simshim: MTLSimTexture init iosurface %p plane %lu ref %p shareable %d -> %p\n", surf, plane, ref, shareable, (void*)r);
	return r;
}
static void dbg_add_image(const struct mach_header* mh, intptr_t slide)
{
	(void)mh; (void)slide;
	static int done;
	Class d = objc_getClass("MTLSimDevice"), t = objc_getClass("MTLSimTexture");
	if (done || !d || !t) return;
	done = 1;
	Method m = class_getInstanceMethod(d, sel_registerName("newSharedTextureWithDescriptor:"));
	if (m) orig_nst = (void*)method_setImplementation(m, (IMP)dbg_nst);
	m = class_getInstanceMethod(t, sel_registerName("initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:shareable:"));
	if (m) orig_tinit = (void*)method_setImplementation(m, (IMP)dbg_tinit);
	fprintf(stderr, "simshim: MTLSimDriver debug hooks %p %p\n", (void*)orig_nst, (void*)orig_tinit);
}

__attribute__((constructor)) static void shim_wb_init(void)
{
	const char* e = getenv("X86SIM_XR_PULSE");
	if (strcmp(getprogname(), "wakeboardd") || (e && *e == '1')) return;
	if (getenv("X86SIM_XR_ERRLOG")) {
		Method m = class_getClassMethod(objc_getClass("NSError"), sel_registerName("errorWithDomain:code:userInfo:"));
		if (m) orig_err = (void*)method_setImplementation(m, (IMP)dbg_err);
		_dyld_register_func_for_add_image(dbg_add_image);
	}
	sem_unlink("wakeboard.is-running");   // left by a wakeboardd that crashed: its successor got EACCES and aborted
	sem_t* s = sem_open("wakeboardd.first-boot", O_CREAT, 0644, 1);
	if (s == SEM_FAILED) { fprintf(stderr, "simshim: wakeboardd.first-boot: %d\n", errno); return; }
	sem_trywait(s);   // take the count if there is one, then give one back: exactly one either way
	sem_post(s);
	fprintf(stderr, "simshim: wakeboardd.first-boot given a count (no boot pulse)\n");
	// EXPERIMENT (Platforms 2): the compositor's state machine goes to Run (7) only while its "run requested" byte is
	// set (a layer asked for the display); otherwise it settles in Idle / DisplayOff and its real-time render context
	// never starts, so no layer ever gets the frame pacing it waits for. The read of that byte (ldarb w23 at
	// 0x10001a4f4 in wakeboardd 24N120) becomes mov w23, #1.
	const char* r = getenv("X86SIM_XR_RUN");
	if (r && *r == '0') return;
	const struct mach_header* mh = NULL;
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char* n = _dyld_get_image_name(i);
		if (n && strlen(n) >= 23 && !strcmp(n + strlen(n) - 23, "/usr/libexec/wakeboardd")) { mh = _dyld_get_image_header(i); break; }
	}
	if (!mh) { fprintf(stderr, "simshim: wakeboardd image not found\n"); return; }
	// and from Idle the target is 4 - display-on (DisplayOff, or Idle): mov w8, #4 at 0x10001a4a0 becomes #7 (Run)
	uint32_t* insn = (uint32_t*)((uintptr_t)mh + (0x10001a4f4 - 0x100000000));
	uint32_t* insn2 = (uint32_t*)((uintptr_t)mh + (0x10001a4a0 - 0x100000000));
	if (*insn != 0x08dffd17u || *insn2 != 0x52800088u) { fprintf(stderr, "simshim: wakeboardd run check not found (%#x %#x)\n", *insn, *insn2); return; }
	uintptr_t page = (uintptr_t)insn2 & ~(uintptr_t)4095;
	if (mprotect((void*)page, 8192, PROT_READ | PROT_WRITE) != 0) { fprintf(stderr, "simshim: mprotect %d\n", errno); return; }
	*insn = 0x52800037u;    // mov w23, #1
	*insn2 = 0x528000e8u;   // mov w8, #7
	mprotect((void*)page, 8192, PROT_READ | PROT_EXEC);
	sys_icache_invalidate(insn2, 0x60);
	fprintf(stderr, "simshim: wakeboardd always runs its compositor\n");
}

// x86Sim Platforms 2 (visionOS): RealityKit's spatial audio. When its PHASE engine fails to start (here AudioToolbox's
// AQME finds no "Default-InputOutput" device: AudioIOUnit::Initialize -10851), REPHASEContext still turns every
// scene-understanding mesh into an audio occluder, and -[PHASEMaterial initWithEngine:...] throws "Cannot create a
// PHASEMaterial with nil or invalid PHASEEngine": backboardd (the RealityKit render server) aborted every few seconds
// and the compositor never got a frame. Without an engine the occluder calls do nothing (occluders only shape sound).
static id (*shim_re_create_orig)(id, SEL, const void*);
static void (*shim_re_void_orig[4])(id, SEL, const void*);
static bool shim_re_noengine(id self)
{
	id e = ((id (*)(id, SEL)) objc_msgSend)(self, sel_registerName("maybeEngine"));
	static bool said;
	if (!e && !said) {
		said = true;
		write(2, "simshim: RealityKit has no audio engine: audio occluders skipped\n", 65);
	}
	return e == nil;
}
static id shim_re_create(id self, SEL sel, const void* o)
{
	return shim_re_noengine(self) ? nil : shim_re_create_orig(self, sel, o);
}
#define SHIM_RE_VOID(k) static void shim_re_void##k(id self, SEL sel, const void* o) \
	{ if (!shim_re_noengine(self)) shim_re_void_orig[k](self, sel, o); }
SHIM_RE_VOID(0) SHIM_RE_VOID(1) SHIM_RE_VOID(2) SHIM_RE_VOID(3)
static void shim_re_added(const struct mach_header* mh, intptr_t slide)
{
	static bool done;
	(void) mh; (void) slide;
	if (done)
		return;
	Class c = objc_getClass("REPHASEContext");
	if (!c || !class_getInstanceMethod(c, sel_registerName("maybeEngine")))
		return;
	done = true;
	Method m = class_getInstanceMethod(c, sel_registerName("createPHASEShapeAndOccluder:"));
	if (m)
		shim_re_create_orig = (id (*)(id, SEL, const void*)) method_setImplementation(m, (IMP) shim_re_create);
	static const char* const sels[4] = { "addOccluder:", "updateOccluder:", "applyOccluderAdditions:", "applyOccluderUpdates:" };
	IMP imps[4] = { (IMP) shim_re_void0, (IMP) shim_re_void1, (IMP) shim_re_void2, (IMP) shim_re_void3 };
	for (int k = 0; k < 4; k++) {
		m = class_getInstanceMethod(c, sel_registerName(sels[k]));
		if (m)
			shim_re_void_orig[k] = (void (*)(id, SEL, const void*)) method_setImplementation(m, imps[k]);
	}
}
__attribute__((constructor)) static void shim_re_init(void)
{
	_dyld_register_func_for_add_image(shim_re_added);
}

// x86Sim Platforms 2 (visionOS): SurfBoard blanks the headset like a phone's auto-lock. Without user activity its
// user-active display assertion lapses right after boot ("Display assertions updated ... displayActive: 0" ->
// "Transitioning headset to not in use..." -> "Display will blank"), it locks the system and RealitySimulation puts its
// black reveal dome back over everything ("SurfBoard Display Blank" obscure assertion): the simulator showed black.
// A simulator display stays on (as the iOS simulator's never auto-locks). X86SIM_XR_BLANK=1 keeps SurfBoard's behavior.
// -[SFBDisplayController _queue_blankHeadsetIfNeeded:] is objc_direct (no method to swizzle): its first instruction
// (sub sp, sp, #0x50 at 0x22d278 in SurfBoardFramework 24N120) becomes ret.
__attribute__((constructor)) static void shim_sfb_init(void)
{
	const char* e = getenv("X86SIM_XR_BLANK");
	if ((e && *e == '1') || strcmp(getprogname(), "SurfBoard"))
		return;
	const struct mach_header* mh = NULL;
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char* n = _dyld_get_image_name(i);
		size_t l = n ? strlen(n) : 0;
		if (l >= 19 && !strcmp(n + l - 19, "/SurfBoardFramework")) { mh = _dyld_get_image_header(i); break; }
	}
	if (!mh) { fprintf(stderr, "simshim: SurfBoardFramework not loaded: headset blank kept\n"); return; }
	// and -[SFBDisplayController _queue_acquireUserPresentDisplayBlankAssertionIfNeeded] (direct too, 0x22ca34: cbz x0),
	// which obscures the display while no user presence is detected
	uint32_t* insn = (uint32_t*)((uintptr_t)mh + 0x22d278);
	uint32_t* insn2 = (uint32_t*)((uintptr_t)mh + 0x22ca34);
	if (*insn != 0xd10143ffu || *insn2 != 0xb40006c0u) {
		fprintf(stderr, "simshim: SurfBoard headset blank not found (%#x %#x): kept\n", *insn, *insn2);
		return;
	}
	uintptr_t page = (uintptr_t)insn2 & ~(uintptr_t)4095;
	if (mprotect((void*)page, 8192, PROT_READ | PROT_WRITE) != 0) { fprintf(stderr, "simshim: mprotect %d\n", errno); return; }
	*insn = 0xd65f03c0u;   // ret
	*insn2 = 0xd65f03c0u;  // ret
	mprotect((void*)page, 8192, PROT_READ | PROT_EXEC);
	sys_icache_invalidate(insn2, 0x848);
	fprintf(stderr, "simshim: SurfBoard never blanks the headset (simulator display stays on)\n");
}

// x86Sim Platforms 2 (visionOS): a worn headset. SurfBoard counts a user as present from the headset's gaze or
// proximity signals (in Xcode, Simulator.app feeds gaze samples: -[SFBHeadset _simulator_updateGazeSample:error:]).
// With neither, the headset is never "in use": the system stays locked from boot ("Performing keybag lock
// immediately", isLayoutLocked 1), the Digital Crown's Home UI is refused ("Cannot show home when device is not
// allowing it") and the lock screen never comes up. Here the headset reports proximity, as one being worn does:
// -[SFBHeadset isProximityPresent] answers YES and the presence monitor gets the don event its headset would send.
// X86SIM_XR_PRESENCE=0: no simulated wearer.
static Boolean (*shim_sfb_prox_orig)(id, SEL);
static id (*shim_sfb_upm_init_orig)(id, SEL, id, id);
static Boolean shim_sfb_prox(id self, SEL sel)
{
	(void) self; (void) sel;
	return true;
}
static id shim_sfb_upm_init(id self, SEL sel, id headset, id queue)
{
	id m = shim_sfb_upm_init_orig(self, sel, headset, queue);
	if (!m || !headset || !queue)
		return m;
	SEL don = sel_registerName("headset:proximityPresenceDidChange:timestamp:");
	Method dm = class_getInstanceMethod(object_getClass(m), don);
	if (!dm) { write(2, "simshim: SFBUserPresenceMonitor has no proximity handler\n", 57); return m; }
	char t[16] = { 0 };
	method_getArgumentType(dm, 4, t, sizeof t);
	bool dbl = t[0] == 'd';
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), (dispatch_queue_t) queue, ^{
		if (dbl)
			((void (*)(id, SEL, id, BOOL, double)) objc_msgSend)(m, don, headset, YES, (double) clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9);
		else
			((void (*)(id, SEL, id, BOOL, uint64_t)) objc_msgSend)(m, don, headset, YES, mach_absolute_time());
		write(2, "simshim: simulated headset worn (proximity present)\n", 52);
	});
	return m;
}
// and the unlock that follows a wearer on a device without a passcode: SurfBoard locks the keybag at boot and only a
// lock screen interaction (SleepLockScreen, never shown here) asks to unlock. -[SFBLockScreenController
// unlockWithRequest:completion:] with an SFBSUnlockRequest, sent on the display controller's queue.
static void (*shim_sfb_setlsc_orig)(id, SEL, id);
static void shim_sfb_setlsc(id self, SEL sel, id lsc)
{
	shim_sfb_setlsc_orig(self, sel, lsc);
	if (!lsc)
		return;
	id q = ((id (*)(id, SEL)) objc_msgSend)(self, sel_registerName("queue"));
	Class rc = objc_getClass("SFBSUnlockRequest");
	if (!q || !rc) { write(2, "simshim: no queue or SFBSUnlockRequest: no boot unlock\n", 55); return; }
	CFRetain((CFTypeRef) lsc);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), (dispatch_queue_t) q, ^{
		id req = ((id (*)(id, SEL, id)) objc_msgSend)(((id (*)(id, SEL)) objc_msgSend)((id) rc, sel_registerName("alloc")),
			sel_registerName("initWithReason:"), (id) CFSTR("x86Sim simulated wearer"));
		((void (*)(id, SEL, id, void (^)(id, id))) objc_msgSend)(lsc, sel_registerName("unlockWithRequest:completion:"), req,
			^(id a, id b) {
				char m[200];
				int k = snprintf(m, sizeof m, "simshim: boot unlock finished (%p %p)\n", (void*) a, (void*) b);
				write(2, m, k);
			});
		// then what a headset's transition to in use tells its observers: -[SFBDisplayController
		// _observers_displayControllerDidUnblankHeadset:] (objc_direct: self in x0, the headset in x1). The headset
		// already counts as in use here (queuedState 2: _queue_unblankHeadsetIfNeeded: returns at once), so the
		// cover sheet never heard of a display that is on (_displayIsOn) and kept the layout locked (no Home View)
		const struct mach_header* fh = NULL;
		for (uint32_t i = 0; i < _dyld_image_count(); i++) {
			const char* n = _dyld_get_image_name(i);
			size_t l = n ? strlen(n) : 0;
			if (l >= 19 && !strcmp(n + l - 19, "/SurfBoardFramework")) { fh = _dyld_get_image_header(i); break; }
		}
		Ivar hv = class_getInstanceVariable(object_getClass(self), "_headset");
		uint32_t* fn = fh ? (uint32_t*)((uintptr_t)fh + 0x22d904) : NULL;
		if (!fn || !hv || *fn != 0xaa1e03e2u) { write(2, "simshim: headset unblank not found\n", 35); return; }
		id hs = object_getIvar(self, hv);
		((void (*)(id, id)) fn)(self, hs);
		write(2, "simshim: display on (observers told)\n", 37);
		write(2, "simshim: boot unlock requested\n", 31);
	});
}
static void shim_sfb_presence_added(const struct mach_header* mh, intptr_t slide)
{
	static bool done;
	(void) mh; (void) slide;
	if (done)
		return;
	Class h = objc_getClass("SFBHeadset"), u = objc_getClass("SFBUserPresenceMonitor");
	Method hp = h ? class_getInstanceMethod(h, sel_registerName("isProximityPresent")) : NULL;
	Method ui = u ? class_getInstanceMethod(u, sel_registerName("initWithHeadset:queue:")) : NULL;
	if (!hp || !ui)
		return;
	done = true;
	shim_sfb_prox_orig = (Boolean (*)(id, SEL)) method_setImplementation(hp, (IMP) shim_sfb_prox);
	shim_sfb_upm_init_orig = (id (*)(id, SEL, id, id)) method_setImplementation(ui, (IMP) shim_sfb_upm_init);
	Class dc = objc_getClass("SFBDisplayController");
	Method sl = dc ? class_getInstanceMethod(dc, sel_registerName("setLockScreenController:")) : NULL;
	if (sl)
		shim_sfb_setlsc_orig = (void (*)(id, SEL, id)) method_setImplementation(sl, (IMP) shim_sfb_setlsc);
	write(2, "simshim: hooked SurfBoard headset presence\n", 43);
}
__attribute__((constructor)) static void shim_sfb_presence_init(void)
{
	const char* e = getenv("X86SIM_XR_PRESENCE");
	if (!strcmp(getprogname(), "SurfBoard") && !(e && *e == '0'))
		_dyld_register_func_for_add_image(shim_sfb_presence_added);
}

__attribute__((constructor)) static void shim_pb_init(void)
{
	const char* e = getenv("X86SIM_TV_SLEEP");
	if (!strcmp(getprogname(), "PineBoard") && !(e && *e == '1'))
		_dyld_register_func_for_add_image(shim_pb_added);
}

// x86Sim: button haptics. backboardd's BKButtonHapticsController enters a dispatch group, asks ButtonResolver
// -[BRButtonResolverController scheduleReadyNotificationOnDispatchQueue:withBlock:] and leaves the group in that block;
// every later haptics configuration waits on the group first (_configureAsyncWithBlock: -> dispatch_group_wait
// forever). ButtonResolver reports ready only once the button-haptics hardware answers, and there is none here: the
// first side-button press (lock) queued a configuration that never ran, and the unlock that followed froze the phone
// (SpringBoard's AnimationKit waited on it with the screen dimmed). The block now also runs 2 s after it was scheduled
// if ButtonResolver has not called it, and runs once either way: no hardware, zero haptic slots.
static IMP shim_br_ready_orig;
static void shim_br_ready(id self, SEL sel, dispatch_queue_t q, void (^blk)(void))
{
	if (!blk || !q) {
		((void (*)(id, SEL, dispatch_queue_t, void (^)(void))) shim_br_ready_orig)(self, sel, q, blk);
		return;
	}
	int* fired = calloc(1, sizeof(int));
	void (^b)(void) = Block_copy(blk);
	void (^once)(void) = ^{
		if (__sync_bool_compare_and_swap(fired, 0, 1))
			b();
	};
	((void (*)(id, SEL, dispatch_queue_t, void (^)(void))) shim_br_ready_orig)(self, sel, q, once);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), q, ^{
		if (__sync_bool_compare_and_swap(fired, 0, 1)) {
			write(2, "simshim: ButtonResolver not ready after 2 s (no button haptics hardware): ready block run\n", 90);
			b();
		}
	});
}
static void shim_br_added(const struct mach_header* mh, intptr_t slide)
{
	if (shim_br_ready_orig)
		return;
	Class c = objc_getClass("BRButtonResolverController");
	Method m = c ? class_getInstanceMethod(c, sel_registerName("scheduleReadyNotificationOnDispatchQueue:withBlock:")) : NULL;
	if (m)
		shim_br_ready_orig = method_setImplementation(m, (IMP) shim_br_ready);
}
__attribute__((constructor)) static void shim_br_init(void)
{
	_dyld_register_func_for_add_image(shim_br_added);
}

// x86Sim (arm64, Speed 11): iconservicesagent keeps its icon store (IconsCache/<uuid>/, which also holds the Metal
// shader cache __METAL_CACHE__ it points MTLSetShaderCachePath at) only if the store directory's owner is
// "_iconservices", the daemon's user on a device. Here every process runs as the host user, so the store was wiped
// at every launch ("one or more preconditions have been met to delete previous cache"): every boot re-rendered all
// icons and MTLCompilerService recompiled RenderBox's pipelines (~12 CPU-s, home 8-11 s later). In iconservicesagent
// only, a file owned by our own uid reports "_iconservices" as its owner account name.
static IMP shim_owner_orig[2];
static id shim_owner_name(id self, SEL sel, int k)
{
	id num = ((id (*)(id, SEL)) objc_msgSend)(self, sel_registerName("fileOwnerAccountID"));
	if (num && ((unsigned (*)(id, SEL)) objc_msgSend)(num, sel_registerName("unsignedIntValue")) == getuid())
		return (id) CFSTR("_iconservices");
	return ((id (*)(id, SEL)) shim_owner_orig[k])(self, sel);
}
static id shim_owner_name0(id self, SEL sel) { return shim_owner_name(self, sel, 0); }
static id shim_owner_name1(id self, SEL sel) { return shim_owner_name(self, sel, 1); }
static void shim_owner_added(const struct mach_header* mh, intptr_t slide)
{
	static const char* cls[2] = { "NSDictionary", "NSFileAttributes" };
	static const IMP imp[2] = { (IMP) shim_owner_name0, (IMP) shim_owner_name1 };
	SEL sel = sel_registerName("fileOwnerAccountName");
	for (int k = 0; k < 2; k++) {
		Class c = shim_owner_orig[k] ? Nil : objc_getClass(cls[k]);
		if (!c)
			continue;
		// only a method the class itself defines (NSFileAttributes may inherit NSDictionary's)
		unsigned n = 0;
		Method* ms = class_copyMethodList(c, &n);
		for (unsigned i = 0; i < n; i++)
			if (method_getName(ms[i]) == sel) {
				shim_owner_orig[k] = method_setImplementation(ms[i], imp[k]);
				char b[96]; int l = snprintf(b, sizeof b, "simshim: hooked %s fileOwnerAccountName\n", cls[k]); write(2, b, l);
			}
		free(ms);
	}
}
__attribute__((constructor)) static void shim_owner_init(void)
{
	if (!strcmp(getprogname(), "iconservicesagent"))
		_dyld_register_func_for_add_image(shim_owner_added);
}

// x86Sim (arm64, Speed 24): the simulator build of RunningBoard never suspends an app whose Info.plist lists the
// "audio" background mode (-[RBProcess _lock_suspend]: "Ignoring suspend because this process is simulated and has
// background audio capabilities"; a device suspends it unless it holds a running assertion, e.g. while it plays).
// Maps and Health stayed running in the background after every use (~1 GB each; jetsam.py only reclaims suspended
// processes). _lock_suspend is objc_direct (not swizzlable): -supportsBackgroundAudio answers NO when called from
// that one site, found by its log string in RunningBoard's __TEXT (the bl right before the cbz w0 that skips the
// message), so it holds for any runtime's build. The audio domain checks (RBPropertyDomainRestriction) see the
// real value.
static uintptr_t shim_rb_site;   // return address of _lock_suspend's [props supportsBackgroundAudio]
static IMP shim_rb_audio_orig[2];
static BOOL shim_rb_audio(id self, SEL sel, int k, uintptr_t ret)
{
	BOOL r = ((BOOL (*)(id, SEL)) shim_rb_audio_orig[k])(self, sel);
	if (ret != shim_rb_site)
		return r;
	static int n;
	if (r && n++ < 20)
		write(2, "simshim: RunningBoard suspends a background-audio app\n", 54);
	return NO;
}
__attribute__((noinline)) static BOOL shim_rb_audio0(id self, SEL sel) { return shim_rb_audio(self, sel, 0, (uintptr_t) __builtin_return_address(0)); }
__attribute__((noinline)) static BOOL shim_rb_audio1(id self, SEL sel) { return shim_rb_audio(self, sel, 1, (uintptr_t) __builtin_return_address(0)); }
static uintptr_t shim_rb_find_site(const struct mach_header* mh)
{
	unsigned long size = 0;
	const uint8_t* text = getsegmentdata((const struct mach_header_64*) mh, "__TEXT", &size);
	static const char msg[] = "Ignoring suspend because this process is simulated and has background audio";
	const uint8_t* str = text ? memmem(text, size, msg, sizeof msg - 1) : NULL;
	if (!str)
		return 0;
	while (str > text && str[-1])
		str--;   // the format string starts with "%{public}@ "
	const uint32_t* code = (const uint32_t*) text;
	for (unsigned long i = 1; i < size / 4; i++) {
		uint32_t add = code[i], adrp = code[i - 1];
		if ((add & 0xffc00000) != 0x91000000 || (adrp & 0x9f000000) != 0x90000000)
			continue;
		int64_t pg = ((int64_t) ((((adrp >> 5) & 0x7ffff) << 2) | ((adrp >> 29) & 3)) << 43) >> 31;
		uintptr_t target = (((uintptr_t) &code[i - 1]) & ~(uintptr_t) 0xfff) + pg + ((add >> 10) & 0xfff);
		if (target != (uintptr_t) str)
			continue;
		// back to "bl objc_msgSend; cbz w0" (the log-enabled checks are "bl; bl _OUTLINED; cbz w0")
		for (unsigned long j = i - 1; j > 1 && j + 24 > i; j--)
			if ((code[j] & 0xff00001f) == 0x34000000 && (code[j - 1] & 0xfc000000) == 0x94000000 &&
			    (code[j - 2] & 0xfc000000) != 0x94000000)
				return (uintptr_t) &code[j];
	}
	return 0;
}
static void shim_rb_added(const struct mach_header* mh, intptr_t slide)
{
	Dl_info di;
	if (shim_rb_site || !dladdr(mh, &di) || !strstr(di.dli_fname, "RunningBoard.framework/RunningBoard"))
		return;
	shim_rb_site = shim_rb_find_site(mh);
	if (!shim_rb_site) {
		write(2, "simshim: RunningBoard suspend site not found\n", 45);
		return;
	}
	static const char* cls[2] = { "RBBundleProperties", "RBLSBundleProperties" };
	static const IMP imp[2] = { (IMP) shim_rb_audio0, (IMP) shim_rb_audio1 };
	SEL sel = sel_registerName("supportsBackgroundAudio");
	for (int k = 0; k < 2; k++) {
		Class c = objc_getClass(cls[k]);
		unsigned n = 0;
		Method* ms = c ? class_copyMethodList(c, &n) : NULL;
		for (unsigned i = 0; i < n; i++)
			if (method_getName(ms[i]) == sel)
				shim_rb_audio_orig[k] = method_setImplementation(ms[i], imp[k]);
		free(ms);
	}
	char b[96]; int l = snprintf(b, sizeof b, "simshim: RunningBoard suspend site +0x%lx\n", (unsigned long) (shim_rb_site - (uintptr_t) mh)); write(2, b, l);
}
__attribute__((constructor)) static void shim_rb_init(void)
{
	if (!strcmp(getprogname(), "runningboardd"))
		_dyld_register_func_for_add_image(shim_rb_added);
}

// x86Sim: the Metal stand-in (host/metalhostd). MTLSimDriver marks its connections to com.apple.metal.simulator[.<proc>]
// as sim-to-host (xpc_connection_enable_sim2host_4sim: messages packed in the host's macOS XPC format, for the
// Mac-side SimMetalHost). Our service, metalhostd, runs inside the simulator on the simulator's libxpc, which drops
// such messages (the handshake failed with an XPC error), so those connections stay plain simulator connections.
// The same holds for com.apple.IOSurface.Remote (host/iosurfaced) and com.apple.FileProvider.sim2host
// (host/fpsim2host). iOS 27 may call enable_sim2host before the connection's name is set (MTLSimDriver, possibly
// IOSurface.Remote); sim2host framing on such an unnamed connection hung its first sync message
// (MTLCreateSystemDefaultDevice against metalhostd), so unnamed connections stay simulator connections too. Host
// services that really are forwarded set their name first.
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t c);
static void shim_xpc_connection_enable_sim2host_4sim(xpc_connection_t c)
{
	const char* name = xpc_connection_get_name(c);
	static int logged;
	if (getenv("X86SIM_SIMSHIM_XPC_LOG") && logged < 32) {
		logged++;
		fprintf(stderr, "simshim: enable_sim2host name=%s\n", name ? name : "(null)");
	}
	if (!name || strncmp(name, "com.apple.metal.simulator", 25) == 0 || strcmp(name, "com.apple.IOSurface.Remote") == 0 ||
	    strcmp(name, "com.apple.FileProvider.sim2host") == 0)
		return;
	xpc_connection_enable_sim2host_4sim(c);
}
DYLD_INTERPOSE(shim_xpc_connection_enable_sim2host_4sim, xpc_connection_enable_sim2host_4sim)

// x86Sim: diagnostics, opt-in. Apps get no log file from launchd here; if the Darling file
// /private/var/tmp/x86sim-stderr-progs (~/.darling/private/var/tmp/) lists a process name (comma-separated, e.g.
// "Preferences,Photos,Maps"), that process sends stderr, and its os_log (DT mode), to
// /private/var/tmp/x86sim-<name>.log. Off by default: DT mode also streams to diagnosticd (see X86SIM_NODT).
static void shim_quiet_os_log(void)
{
	// x86Sim: no logd and no diagnosticd here. Processes that launchd starts get OS_ACTIVITY_MODE=disable from
	// cli/libexec/mksimdevice.py, but apps and extensions that SpringBoard/RunningBoard start don't, and their os_log
	// looked up com.apple.diagnosticd for every message (Spotlight and the Maps widget: ~45,000 failed lookups in
	// a few minutes, darlingserver at 90% CPU and launchd_sim at 40%, the UI stalled). libtrace reads the
	// variable at its first log call, after this constructor.
	if (!getenv("OS_ACTIVITY_MODE") && !getenv("OS_ACTIVITY_DT_MODE"))
		setenv("OS_ACTIVITY_MODE", "disable", 1);
}

__attribute__((constructor)) static void shim_app_stderr_init(void)
{
	char buf[1024] = "";
	int lf = open("/private/var/tmp/x86sim-stderr-progs", O_RDONLY);
	ssize_t got = lf >= 0 ? read(lf, buf, sizeof buf - 1) : 0;
	if (lf >= 0)
		close(lf);
	buf[got > 0 ? got : 0] = 0;
	for (char* q = buf; *q; q++) if (*q == '\n' || *q == ' ') *q = ',';
	const char* p = getprogname();
	size_t n = strlen(p);
	for (const char* s = buf; *s; ) {
		const char* e = strchr(s, ',');
		size_t l = e ? (size_t) (e - s) : strlen(s);
		// x86Sim: "name+" also turns on info/debug messages (OS_ACTIVITY_MODE=debug)
		int dbg = l > 0 && s[l - 1] == '+';
		if (dbg) l--;
		if (l == n && !strncmp(s, p, n)) {
			// x86Sim: launchd jobs get OS_ACTIVITY_MODE=disable (mksimdevice.py), which also silences DT mode
			if (dbg) setenv("OS_ACTIVITY_MODE", "debug", 1);
			else if (getenv("OS_ACTIVITY_MODE") && !strcmp(getenv("OS_ACTIVITY_MODE"), "disable")) unsetenv("OS_ACTIVITY_MODE");
			char path[256];
			snprintf(path, sizeof path, "/private/var/tmp/x86sim-%s.log", p);
			int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
			if (fd >= 0) { dup2(fd, 2); close(fd); setenv("OS_ACTIVITY_DT_MODE", "1", 1); }
			break;
		}
		if (!e)
			break;
		s = e + 1;
	}
	shim_quiet_os_log();
}

