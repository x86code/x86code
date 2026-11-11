// x86Sim: metalhostd -- the Metal simulator service of our iOS-simulator device (Darling side).
//
// Does what MTLSimDriverHost.xpc / CoreSimulator's SimMetalHost do on a Mac: loads the runtime's own
// MTLSimImplementation and hands it a listener (init_with_xpc_connection). MTLSimImplementation then serves
// the apps' MTLSimDriver connections (handshake, buffers, serialized object commands and command buffers)
// and replays them on MTLCreateSystemDefaultDevice() -- which in this process is libvkmtl's VKMTLDevice
// (vkmtl.m), forwarding to mtlvk on Vulkan.
//
// Service names: the MTLSimDriver client looks up "com.apple.metal.simulator.<progname>" first and then
// "com.apple.metal.simulator". The launchd job (cli/libexec/mksimdevice.py, X86SIM_METAL) lists the names it
// owns as MachServices; X86SIM_METAL_NAMES (comma-separated) tells us which ones to listen on. Keeping the
// generic name unregistered keeps system processes (backboardd, SpringBoard: CoreAnimation) on their
// software renderer while only opted-in processes get a device.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <xpc/xpc.h>
#import <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include "vkmtl_proto.h"

// marked unavailable on iOS in the SDK, but libxpc in the simulator runtime has it (MTLSimDriverHost's peer
// listener API needs the XPC-service bootstrap we don't have)
extern xpc_connection_t x86_xpc_connection_create_mach_service(const char* name, dispatch_queue_t q, uint64_t flags)
	__asm__("_xpc_connection_create_mach_service");

extern id<MTLDevice> VKMTLCreateSystemDefaultDevice(void);
extern NSArray* VKMTLCopyAllDevices(void);
extern int VKMTLRebind(const char* image_name_part, void* real, void* ours);

#define RT_MTLSIMIMPL "/System/Library/PrivateFrameworks/MTLSimImplementation.framework/MTLSimImplementation"

#if defined(__arm64__)
// x86Sim (Speed 9, arm64 runtime only; the frozen x86 path is not built with this): iOS 27's MTLSimImplementation
// keeps a per-connection context { u32; dispatch_queue_t; shared_ptr<MTLSimApplicationContext> } and sets the app
// pointer (+0x10) only in the connection's init message ("connectionType"). A secondary connection's init names its
// primary's "processRef"; when MTLSimGlobalContext has no application for it, the pointer stays NULL and the next
// command (deleteObject, newObjectCommand_DEPRECATED, ...) reads through it: metalhostd SIGSEGV (guest NULL read at
// MTLSimImplementation+0x218c / +0x1f6c) and every client loses Metal. Instead such a connection is cancelled (the
// client sees XPC_ERROR_CONNECTION_INVALID) and logged.
extern pid_t x86_xpc_connection_get_pid(xpc_connection_t c) __asm__("_xpc_connection_get_pid");
static void (*real_set_event_handler)(xpc_connection_t, xpc_handler_t);
static void guarded_set_event_handler(xpc_connection_t c, xpc_handler_t h) {
	xpc_handler_t hc = Block_copy(h);  // MRC: kept for the connection's lifetime
	real_set_event_handler(c, ^(xpc_object_t e) {
		if (xpc_get_type(e) != XPC_TYPE_DICTIONARY) { hc(e); return; }
		xpc_connection_t r = xpc_dictionary_get_remote_connection(e);
		void** ctx = r ? (void**)xpc_connection_get_context(r) : NULL;
		const bool init = xpc_dictionary_get_value(e, "connectionType") != NULL;
		if (ctx && !ctx[2] && !init) {
			fprintf(stderr, "metalhostd: pid %d messageType %llu on a connection without an application context: cancelled\n",
				x86_xpc_connection_get_pid(r), xpc_dictionary_get_uint64(e, "messageType"));
			xpc_connection_cancel(r);
			return;
		}
		hc(e);
		if (init && ctx && !ctx[2])
			fprintf(stderr, "metalhostd: pid %d init (connectionType %lld, processRef %llu) found no application\n",
				x86_xpc_connection_get_pid(r), xpc_dictionary_get_int64(e, "connectionType"), xpc_dictionary_get_uint64(e, "processRef"));
	});
}
#endif

#if defined(__arm64__)
// x86Sim Platforms 1: tvOS / watchOS have MTLSimImplementation and MetalSerializer in the dyld shared cache, where their
// calls into Metal branch straight to it: no GOT entry for VKMTLRebind, which found 0. Their device then came from the
// real MTLCreateSystemDefaultDevice: MTLSimDriver connecting to com.apple.metal.simulator, i.e. to this process, which
// waited on itself (and backboardd's CoreAnimation on it: no frame ever). Here the entry points themselves become a jump
// to ours ("ldr x16, #8; br x16; .quad ours"), in this process only (the cache's text is a private mapping).
static int patch_entry(void* fn, void* ours) {
	if (!fn || !ours) return 0;
	uintptr_t page = (uintptr_t)fn & ~(uintptr_t)4095;
	if (mprotect((void*)page, 8192, PROT_READ | PROT_WRITE) != 0) {
		fprintf(stderr, "metalhostd: cannot make %p writable: %d\n", fn, errno);
		return 0;
	}
	uint32_t* w = (uint32_t*)fn;
	w[0] = 0x58000050u;  // ldr x16, #8
	w[1] = 0xd61f0200u;  // br x16
	memcpy(&w[2], &ours, sizeof(ours));
	mprotect((void*)page, 8192, PROT_READ | PROT_EXEC);
	sys_icache_invalidate(fn, 16);
	return 1;
}
#endif

int main(int argc, char** argv) {
	(void)argc; (void)argv;
	setvbuf(stderr, NULL, _IOLBF, 0);
	@autoreleasepool {
		void* impl = dlopen(RT_MTLSIMIMPL, RTLD_NOW);
		if (!impl) { fprintf(stderr, "metalhostd: dlopen MTLSimImplementation: %s\n", dlerror()); return 1; }
		void (*init_with_xpc_connection)(xpc_connection_t, uint64_t, uint64_t) = dlsym(impl, "init_with_xpc_connection");
		if (!init_with_xpc_connection) { fprintf(stderr, "metalhostd: no init_with_xpc_connection\n"); return 1; }
		// MTLSimImplementation (and MetalSerializer) get their device from MTLCreateSystemDefaultDevice: ours
		int n = 0;
		void* real_create = dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
		void* real_all = dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
		const char* images[] = { "MTLSimImplementation", "MetalSerializer", NULL };
		for (int i = 0; images[i]; i++) {
			n += VKMTLRebind(images[i], real_create, (void*)VKMTLCreateSystemDefaultDevice);
			n += VKMTLRebind(images[i], real_all, (void*)VKMTLCopyAllDevices);
		}
		fprintf(stderr, "metalhostd: %d device entry points rebound\n", n);
#if defined(__arm64__)
		if (n == 0) {  // Platforms 1: cache-resident MTLSimImplementation (tvOS / watchOS), see patch_entry
			n = patch_entry(real_create, (void*)VKMTLCreateSystemDefaultDevice) + patch_entry(real_all, (void*)VKMTLCopyAllDevices);
			fprintf(stderr, "metalhostd: %d device entry points patched (MTLSimImplementation in the shared cache)\n", n);
		}
#endif
#if defined(__arm64__)
		real_set_event_handler = dlsym(RTLD_DEFAULT, "xpc_connection_set_event_handler");
		fprintf(stderr, "metalhostd: %d connection handler guards\n",
			VKMTLRebind("MTLSimImplementation", real_set_event_handler, (void*)guarded_set_event_handler));
#endif

		id<MTLDevice> dev = VKMTLCreateSystemDefaultDevice();
		if (!dev) {
			// x86Sim: no mtlvk (not started, or it died): keep the service names but cancel every client connection
			// at once, so MTLSimDriver reports no device and CoreAnimation/apps use their software paths instead of
			// waiting on a service that never answers. mtlvk is looked for again every 10 s; when it is back we exit
			// and launchd starts a serving metalhostd on the next lookup (processes already running stay software).
			fprintf(stderr, "metalhostd: no device (is mtlvk running?): refusing clients\n");
			const char* names = getenv("X86SIM_METAL_NAMES");
			for (NSString* name in [@(names ?: "com.apple.metal.simulator") componentsSeparatedByString:@","]) {
				if (!name.length) continue;
				xpc_connection_t l = x86_xpc_connection_create_mach_service(name.UTF8String, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
				if (!l) continue;
				xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
					if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
						xpc_connection_set_event_handler(peer, ^(xpc_object_t e) { (void)e; });
						xpc_connection_resume(peer);
						xpc_connection_cancel(peer);
					}
				});
				xpc_connection_resume(l);
			}
			dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
			dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
			dispatch_source_set_event_handler(t, ^{
				char path[256];
				const char* sp = getenv("X86SIM_MTLVK_SOCKET");
				snprintf(path, sizeof(path), "/Volumes/SystemRoot%s", sp ? sp : VKMTL_SOCKET_DEFAULT);
				int s = socket(AF_UNIX, SOCK_STREAM, 0);
				struct sockaddr_un a = { 0 };
				a.sun_family = AF_UNIX;
				strlcpy(a.sun_path, path, sizeof(a.sun_path));
				if (connect(s, (struct sockaddr*)&a, sizeof(a)) == 0) { fprintf(stderr, "metalhostd: mtlvk is back, restarting\n"); _exit(0); }
				close(s);
			});
			dispatch_resume(t);
			fprintf(stderr, "metalhostd: CFRunLoopRun (refusing)\n");
			CFRunLoopRun();
			return 0;
		}
		uint64_t registryID = dev.registryID;

		const char* names = getenv("X86SIM_METAL_NAMES");
		NSArray* list = [@(names ?: "com.apple.metal.simulator") componentsSeparatedByString:@","];
		for (NSString* name in list) {
			if (!name.length) continue;
			xpc_connection_t l = x86_xpc_connection_create_mach_service(name.UTF8String, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
			if (!l) { fprintf(stderr, "metalhostd: cannot listen on %s\n", name.UTF8String); continue; }
			init_with_xpc_connection(l, registryID, 0);
			fprintf(stderr, "metalhostd: serving %s (device \"%s\", registryID %#llx)\n", name.UTF8String, dev.name.UTF8String, registryID);
		}
		// x86Sim: CFRunLoopRun keeps the main thread draining the main queue. dispatch_main's
		// pthread_exit parks the A64 JIT main thread in a way that can leave XPC peer handlers
		// unserved (mtlprobe hung in MTLCreateSystemDefaultDevice). Same for the refuse path above.
		fprintf(stderr, "metalhostd: CFRunLoopRun\n");
		CFRunLoopRun();
	}
	return 0;
}
