// x86Sim: loads the host's network configuration (linux/hostnet/hostnet.py's plist) into the dynamic store named
// with kSCDynamicStoreUseHostServer when X86SIM_HOST_STORE is set (com.x86sim.host-configd: the stand-in for the Mac's configd, which configd_sim's SimulatorSupport
// plugin mirrors into the simulator), or dumps a store: netconfig <plist> | netconfig -dump [delay s]
#import <Foundation/Foundation.h>

// SCDynamicStore is not in the iOS SDK's headers (the runtime's SystemConfiguration has it)
typedef const struct __SCDynamicStore *SCDynamicStoreRef;
extern SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef, CFStringRef, void *, void *);
extern Boolean SCDynamicStoreSetMultiple(SCDynamicStoreRef, CFDictionaryRef, CFArrayRef, CFArrayRef);
extern CFArrayRef SCDynamicStoreCopyKeyList(SCDynamicStoreRef, CFStringRef);
extern CFDictionaryRef SCDynamicStoreCopyMultiple(SCDynamicStoreRef, CFArrayRef, CFArrayRef);
extern int SCError(void);
extern SCDynamicStoreRef SCDynamicStoreCreateWithOptions(CFAllocatorRef, CFStringRef, CFDictionaryRef, void *, void *);
extern const CFStringRef kSCDynamicStoreUseHostServer;  // private: the host's configd (as SimulatorSupport opens it)

int main(int argc, char **argv) {
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		if (argc > 2) sleep(atoi(argv[2]));  // -dump <seconds>: let the boot settle first
		// the store's job may not be loaded yet this early in the boot: retry for 30 s
		SCDynamicStoreRef s = NULL;
		// X86SIM_HOST_STORE: the host's store (com.apple.SystemConfiguration.configd, here com.x86sim.host-configd), else
		// the simulator's
		BOOL host = getenv("X86SIM_HOST_STORE") != NULL;
		NSDictionary *opts = host ? @{ (__bridge NSString *)kSCDynamicStoreUseHostServer: @YES } : nil;
		for (int i = 0; i < 30 && !(s = SCDynamicStoreCreateWithOptions(NULL, CFSTR("x86sim-netconfig"), (__bridge CFDictionaryRef)opts, NULL, NULL)); i++) sleep(1);
		if (!s) { printf("netconfig: no store (SCError %d)\n", SCError()); return 1; }
		if (argc > 1 && strcmp(argv[1], "-dump") == 0) {
			NSArray *keys = CFBridgingRelease(SCDynamicStoreCopyKeyList(s, CFSTR("State:/Network/.*|Setup:/Network/.*")));
			NSDictionary *all = CFBridgingRelease(SCDynamicStoreCopyMultiple(s, (__bridge CFArrayRef)keys, NULL));
			for (NSString *k in [all.allKeys sortedArrayUsingSelector:@selector(compare:)])
				printf("%s = %s\n", k.UTF8String, [[all[k] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
			return 0;
		}
		NSDictionary *keys = [NSDictionary dictionaryWithContentsOfFile:@(argv[1])];
		Boolean ok = SCDynamicStoreSetMultiple(s, (__bridge CFDictionaryRef)keys, NULL, NULL);
		printf("netconfig: set %lu keys: %s\n", (unsigned long)keys.count, ok ? "ok" : "FAILED");
		return ok ? 0 : 1;
	}
}
