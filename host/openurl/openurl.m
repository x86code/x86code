// x86Sim: opens URLs in the simulator for tests (as `xcrun simctl openurl`). Run as a job:
//   openurl=host/openurl/openurl
// then write a URL (one per line) to <device>/data/tmp/x86sim-openurl (the file is taken and removed);
// cli/libexec/simtouch.py openurl <url> does that. Log: <device>/data/var/log/x86sim-openurl.log. (Not the prefix's
// /private/var/tmp: a file written there from Linux, into the overlay's upper directory, is not seen inside.)
//
// The app is asked to open the URL through FrontBoard (FBSOpenApplicationService, SpringBoard's open-application
// service, with the URL as the payload), which is what lsd itself does once it has picked the app. Going through
// lsd (LSApplicationWorkspace openURL:) made lsd abort: for a request from another process lsd passes the caller's
// RBSProcessHandle as clientHandle, and it had none for a launchd job. A line starting with
// "ls " still takes that route. "app <bundle id>" opens an app without a URL (apps the home screen doesn't show). The app for a URL is the first LaunchServices claims for its scheme (http/https:
// Safari). SpringBoard checks com.apple.frontboard.launchapplications: the binary carries it in
// __TEXT,__entitlements (openurl.entitlements), which the simulator reads instead of a code signature.
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <xpc/xpc.h>

#define MSG(ret, ...) ((ret(*)(__VA_ARGS__))objc_msgSend)

static FILE* logf_;

static NSString* appForURL(NSURL* url) {
	id w = MSG(id, id, SEL)(NSClassFromString(@"LSApplicationWorkspace"), sel_getUid("defaultWorkspace"));
	NSArray* apps = MSG(id, id, SEL, id)(w, sel_getUid("applicationsAvailableForHandlingURLScheme:"), url.scheme);
	for (id proxy in apps) {
		NSString* bid = MSG(id, id, SEL)(proxy, sel_getUid("bundleIdentifier"));
		if (bid.length) return bid;
	}
	if ([url.scheme hasPrefix:@"http"]) return @"com.apple.mobilesafari";
	return nil;
}

static void openViaFrontBoard(NSURL* url, NSString* u, NSString* app, NSArray* args) {
	NSString* bid = app ?: appForURL(url);
	if (!bid) { fprintf(logf_, "openurl %s: no app for the scheme\n", u.UTF8String); fflush(logf_); return; }
	Class svcClass = NSClassFromString(@"FBSOpenApplicationService");
	Class optClass = NSClassFromString(@"FBSOpenApplicationOptions");
	id svc = MSG(id, id, SEL)(svcClass, sel_getUid("serviceWithDefaultShellEndpoint"));
	// FBSOpenApplicationOptionKeyPayloadURL, ...KeyUnlockDevice, ...KeyActivateSuspended
	NSMutableDictionary* d = [@{ @"__UnlockDevice": @YES, @"__ActivateSuspended": @NO } mutableCopy];
	if (url) d[@"__PayloadURL"] = url;
	if (args.count) d[@"__Arguments"] = args; // FBSOpenApplicationOptionKeyArguments (simctl launch <id> args...)
	id opts = MSG(id, id, SEL, id)(optClass, sel_getUid("optionsWithDictionary:"), d);
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	// x86Sim: arm64 under the JIT often needs >30 s for a cold app to finish FrontBoard's open
	// handshake (Settings ~30 s tap-to-content). Keep 30 s on x86; 120 s when X86SIM_ARCH=arm64.
	const int open_secs = (getenv("X86SIM_ARCH") && !strcmp(getenv("X86SIM_ARCH"), "arm64")) ? 120 : 30;
	__block NSString* result = [NSString stringWithFormat:@"(no reply in %d s)", open_secs];
	void (^completion)(id, NSError*) = ^(id process, NSError* err) {
		result = err ? [NSString stringWithFormat:@"error %@", err] : [NSString stringWithFormat:@"ok %@", process];
		dispatch_semaphore_signal(done);
	};
	MSG(void, id, SEL, id, id, id)(svc, sel_getUid("openApplication:withOptions:completion:"), bid, opts, completion);
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)open_secs * NSEC_PER_SEC));
	fprintf(logf_, "openurl %s -> %s: %s\n", u.UTF8String, bid.UTF8String, result.UTF8String); fflush(logf_);
}

// x86Sim: `x86sim install`, as `simctl install`: on a Mac, CoreSimulator asks CoreSimulatorBridge (a job inside the
// device) to install, and it calls +[IXAppInstallCoordinator installApplication:consumeSource:options:completion:]
// with MIInstallOptions (developerInstall) and the entitlement com.apple.private.mobileinstall.allowedSPI =
// InstallForLaunchServices/UninstallForLaunchServices. That goes to installcoordinationd, which has installd copy
// the bundle into /var/containers/Bundle/Application; containermanagerd makes the data container and LaunchServices
// registers the app, so the home screen shows its icon. (LSApplicationWorkspace installApplication: answers -4,
// unimplemented, on iOS 26.) Uninstall: +[IXAppInstallCoordinator uninstallAppWithBundleID:...], as the Bridge does.
static BOOL looksLikeObject(id o) { return (uintptr_t)(__bridge void*)o > 4096; }

static void installApp(NSString* path) {
	dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_NOW);
	dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW);
	NSURL* url = [NSURL fileURLWithPath:path];
	NSString* bid = [[NSBundle bundleWithURL:url] bundleIdentifier];
	id opts = [NSClassFromString(@"MIInstallOptions") new];
	MSG(void, id, SEL, BOOL)(opts, sel_getUid("setDeveloperInstall:"), YES);
	// installTargetType 1 = an app (IXSimpleInstaller refuses anything else: "This SPI can only install apps")
	MSG(void, id, SEL, unsigned long)(opts, sel_getUid("setInstallTargetType:"), 1);
	fprintf(logf_, "install: options %s\n", [opts description].UTF8String ?: "(nil)"); fflush(logf_);
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSString* result = @"failed (no answer in 120 s)";
	void (^completion)(id, NSError*) = ^(id rec, NSError* err) {
		result = err ? [NSString stringWithFormat:@"failed %@", err]
			: [NSString stringWithFormat:@"ok %@", looksLikeObject(rec) ? NSStringFromClass(object_getClass(rec)) : @""];
		dispatch_semaphore_signal(done);
	};
	MSG(void, id, SEL, id, BOOL, id, id)(NSClassFromString(@"IXAppInstallCoordinator"),
		sel_getUid("installApplication:consumeSource:options:completion:"), url, NO, opts, completion);
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
	fprintf(logf_, "install %s (%s): %s\n", path.UTF8String, bid.UTF8String ?: "?", result.UTF8String); fflush(logf_);
}

static void uninstallApp(NSString* bid) {
	dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_NOW);
	NSError* err = nil;
	BOOL ok = MSG(BOOL, id, SEL, id, BOOL, BOOL, NSError**)(NSClassFromString(@"IXAppInstallCoordinator"),
		sel_getUid("uninstallAppWithBundleID:requestUserConfirmation:waitForDeletion:error:"), bid, NO, YES, &err);
	fprintf(logf_, "uninstall %s: %s %s\n", bid.UTF8String, ok ? "ok" : "failed", err.description.UTF8String ?: "");
	fflush(logf_);
}

static void openViaLS(NSURL* url, NSString* u) {
	id w = MSG(id, id, SEL)(NSClassFromString(@"LSApplicationWorkspace"), sel_getUid("defaultWorkspace"));
	NSError* err = nil;
	BOOL ok = MSG(BOOL, id, SEL, id, id, NSError**)(w, sel_getUid("openURL:withOptions:error:"), url, @{}, &err);
	fprintf(logf_, "openurl (ls) %s: %d %s\n", u.UTF8String, ok, err.description.UTF8String ?: ""); fflush(logf_);
}

// x86Sim: simctl's other app commands, as CoreSimulatorBridge does them inside a Mac's device. A request is one line
// "req <id> <json>" with "cmd"; the answer is one log line "result <id> <json>" (cli/libexec/appinstall.sh waits for it).
//   launch     {bundle, args, env, stdout, stderr, waitForDebugger, terminate}: FBSOpenApplicationService with the
//              Bridge's debug options (__DebugOptions: __Arguments, __Environment, __StandardOutPath/__StandardErrorPath
//              for --console, __WaitForDebugger); terminate = terminate_running_process first. Answer: pid.
//   terminate  {bundle}: -[FBSSystemService terminateApplication:forReason:andReport:withDescription:completion:]
//   container  {bundle}: LSApplicationProxy bundleURL / dataContainerURL / groupContainerURLs (get_app_container)
//   listapps   {}: every installed app (LSApplicationWorkspace allInstalledApplications), as simctl listapps
//   push       {bundle, payload}: +[UNNotificationRequest requestWithIdentifier:pushPayload:bundleIdentifier:] added
//              through a UNUserNotificationCenter for that bundle (entitlement ...usernotifications.notification-simulator)
//   location   {lat, lon} or {clear}: CLSimulationManager (locationd's simulation interface)
//   addmedia   {paths}: PHPhotoLibrary performChangesAndWait: creationRequestForAssetFrom{Image,Video}AtFileURL:
static NSString* home_;

static void answer(NSString* rid, NSDictionary* r) {
	NSData* j = [NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
	fprintf(logf_, "result %s %s\n", rid.UTF8String, j ? (const char*)[[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding].UTF8String : "{}");
	fflush(logf_);
}

static NSString* devPath(NSString* p) { return [p hasPrefix:@"/"] ? p : [home_ stringByAppendingPathComponent:p]; }

static NSDictionary* terminateApp(NSString* bid) {
	dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
	id svc = MSG(id, id, SEL)(NSClassFromString(@"FBSSystemService"), sel_getUid("sharedService"));
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSDictionary* r = @{ @"ok": @NO, @"error": @"no answer in 15 s" };
	void (^completion)(BOOL) = ^(BOOL ok) {
		// FBSSystemService answers NO without an error when the app isn't running (CoreSimulatorBridge's message)
		r = ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": @"not running or termination failed" };
		dispatch_semaphore_signal(done);
	};
	// reason 5 = FBSTerminationReasonUserInitiated? the Bridge passes its own; any reason terminates
	MSG(void, id, SEL, id, long, BOOL, id, id)(svc, sel_getUid("terminateApplication:forReason:andReport:withDescription:completion:"),
		bid, 5, NO, @"Termination requested by simulator host", completion);
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
	return r;
}

static NSDictionary* launchApp(NSDictionary* q) {
	NSString* bid = q[@"bundle"];
	if ([q[@"terminate"] boolValue]) terminateApp(bid);
	NSMutableDictionary* d = [@{ @"__UnlockDevice": @YES, @"__ActivateSuspended": @NO } mutableCopy];
	// x86Sim: arguments, environment, standard output paths and wait-for-debugger are FBSDebugOptionKey* values in the
	// FBSOpenApplicationOptionKeyDebuggingOptions dictionary (__DebugOptions), as CoreSimulatorBridge passes them;
	// at the top level FrontBoard only takes __Arguments
	NSMutableDictionary* dbg = [NSMutableDictionary new];
	if ([q[@"args"] count]) d[@"__Arguments"] = dbg[@"__Arguments"] = q[@"args"];
	if ([q[@"env"] count]) dbg[@"__Environment"] = q[@"env"];
	if (q[@"stdout"]) dbg[@"__StandardOutPath"] = devPath(q[@"stdout"]);
	if (q[@"stderr"]) dbg[@"__StandardErrorPath"] = devPath(q[@"stderr"]);
	if ([q[@"waitForDebugger"] boolValue]) dbg[@"__WaitForDebugger"] = @YES;
	if (dbg.count) d[@"__DebugOptions"] = dbg;
	id svc = MSG(id, id, SEL)(NSClassFromString(@"FBSOpenApplicationService"), sel_getUid("serviceWithDefaultShellEndpoint"));
	id opts = MSG(id, id, SEL, id)(NSClassFromString(@"FBSOpenApplicationOptions"), sel_getUid("optionsWithDictionary:"), d);
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSDictionary* r = @{ @"ok": @NO, @"error": @"no reply in 30 s" };
	void (^completion)(id, NSError*) = ^(id process, NSError* err) {
		if (err) r = @{ @"ok": @NO, @"error": err.description ?: @"?" };
		else {
			int pid = [process respondsToSelector:sel_getUid("pid")] ? MSG(int, id, SEL)(process, sel_getUid("pid")) : -1;
			r = @{ @"ok": @YES, @"pid": @(pid) };
		}
		dispatch_semaphore_signal(done);
	};
	MSG(void, id, SEL, id, id, id)(svc, sel_getUid("openApplication:withOptions:completion:"), bid, opts, completion);
	// x86Sim: with __WaitForDebugger FrontBoard answers only once the app runs (after a debugger resumed it): don't
	// hold the helper; the caller finds the waiting process itself (cli/libexec/simctl.py)
	BOOL waits = [q[@"waitForDebugger"] boolValue];
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (waits ? 5 : 30) * NSEC_PER_SEC)) && waits)
		return @{ @"ok": @YES, @"pid": @(-1), @"waiting": @YES };
	return r;
}

static NSString* urlPath(id u) { return [u isKindOfClass:NSURL.class] ? [u path] : nil; }

static NSDictionary* appInfo(id proxy) {
	NSMutableDictionary* a = [NSMutableDictionary new];
	#define PUT(key, sel) { id v = [proxy respondsToSelector:sel_getUid(sel)] ? MSG(id, id, SEL)(proxy, sel_getUid(sel)) : nil; \
		if ([v isKindOfClass:NSURL.class]) v = [v path]; if ([v isKindOfClass:NSString.class]) a[key] = v; }
	PUT(@"CFBundleIdentifier", "bundleIdentifier");
	PUT(@"CFBundleDisplayName", "localizedName");
	PUT(@"CFBundleExecutable", "bundleExecutable");
	PUT(@"CFBundleVersion", "bundleVersion");
	PUT(@"CFBundleShortVersionString", "shortVersionString");
	PUT(@"ApplicationType", "applicationType");
	PUT(@"Path", "bundleURL");
	PUT(@"DataContainer", "dataContainerURL");
	#undef PUT
	id groups = [proxy respondsToSelector:sel_getUid("groupContainerURLs")] ? MSG(id, id, SEL)(proxy, sel_getUid("groupContainerURLs")) : nil;
	if ([groups isKindOfClass:NSDictionary.class] && [groups count]) {
		NSMutableDictionary* g = [NSMutableDictionary new];
		for (id k in groups) if (urlPath(groups[k])) g[k] = urlPath(groups[k]);
		a[@"GroupContainers"] = g;
	}
	return a;
}

static NSDictionary* listApps(void) {
	id w = MSG(id, id, SEL)(NSClassFromString(@"LSApplicationWorkspace"), sel_getUid("defaultWorkspace"));
	NSMutableDictionary* all = [NSMutableDictionary new];
	for (id p in MSG(id, id, SEL)(w, sel_getUid("allInstalledApplications"))) {
		NSDictionary* a = appInfo(p);
		if (a[@"CFBundleIdentifier"]) all[a[@"CFBundleIdentifier"]] = a;
	}
	return @{ @"ok": @YES, @"apps": all };
}

static NSDictionary* container(NSString* bid) {
	id p = MSG(id, id, SEL, id)(NSClassFromString(@"LSApplicationProxy"), sel_getUid("applicationProxyForIdentifier:"), bid);
	NSDictionary* a = p ? appInfo(p) : nil;
	if (!a[@"Path"]) return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"no app %@ installed", bid] };
	return @{ @"ok": @YES, @"app": a };
}

static NSDictionary* push(NSString* bid, NSDictionary* payload) {
	dlopen("/System/Library/Frameworks/UserNotifications.framework/UserNotifications", RTLD_NOW);
	id req = MSG(id, id, SEL, id, id, id)(NSClassFromString(@"UNNotificationRequest"),
		sel_getUid("requestWithIdentifier:pushPayload:bundleIdentifier:"), NSUUID.UUID.UUIDString, payload, bid);
	if (!req) return @{ @"ok": @NO, @"error": @"UNNotificationRequest from the payload failed (no \"aps\"?)" };
	id center = MSG(id, id, SEL, id)([NSClassFromString(@"UNUserNotificationCenter") alloc], sel_getUid("initWithBundleIdentifier:"), bid);
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSDictionary* r = @{ @"ok": @NO, @"error": @"no answer in 15 s" };
	void (^completion)(NSError*) = ^(NSError* err) {
		r = err ? @{ @"ok": @NO, @"error": err.description } : @{ @"ok": @YES };
		dispatch_semaphore_signal(done);
	};
	MSG(void, id, SEL, id, id)(center, sel_getUid("addNotificationRequest:withCompletionHandler:"), req, completion);
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
	return r;
}

// x86Sim: simctl location, as CoreSimulatorBridge does it: CLSimulationManager (CoreLocation SPI) talks to locationd's
// com.apple.locationd.simulation service. q: {clear} | {lat, lon} | {points: [[lat, lon]...], speed, distance,
// interval} (simctl location start: interpolated between waypoints) | {scenario: name} (simctl location run) | {list}.
static NSArray* scenarioURLs(id m) {
	id a = MSG(id, id, SEL)(m, sel_getUid("availableScenarios"));
	return [a isKindOfClass:NSArray.class] ? a : @[];
}

static NSString* scenarioName(id m, id u) {
	NSString* n = [m respondsToSelector:sel_getUid("localizedNameForScenario:")] ? MSG(id, id, SEL, id)(m, sel_getUid("localizedNameForScenario:"), u) : nil;
	if (![n isKindOfClass:NSString.class] || !n.length) n = [[([u isKindOfClass:NSURL.class] ? [u path] : [u description]) lastPathComponent] stringByDeletingPathExtension];
	return n;
}

static NSDictionary* location(NSDictionary* q) {
	dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_NOW);
	static id m;
	if (!m) m = [NSClassFromString(@"CLSimulationManager") new];
	if (!m) return @{ @"ok": @NO, @"error": @"no CLSimulationManager" };
	if ([q[@"list"] boolValue]) {
		NSMutableArray* names = [NSMutableArray new];
		for (id u in scenarioURLs(m)) [names addObject:scenarioName(m, u)];
		return @{ @"ok": @YES, @"scenarios": names };
	}
	MSG(void, id, SEL)(m, sel_getUid("stopLocationSimulation"));
	MSG(void, id, SEL)(m, sel_getUid("clearSimulatedLocations"));
	if ([q[@"clear"] boolValue]) return @{ @"ok": @YES };
	id (^loc)(double, double) = ^id(double lat, double lon) {
		return MSG(id, id, SEL, double, double)([NSClassFromString(@"CLLocation") alloc], sel_getUid("initWithLatitude:longitude:"), lat, lon);
	};
	if (q[@"scenario"]) {
		id found = nil;
		for (id u in scenarioURLs(m))
			if ([scenarioName(m, u) caseInsensitiveCompare:q[@"scenario"]] == NSOrderedSame) found = u;
		if (!found) return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"no scenario named %@ (location list)", q[@"scenario"]] };
		MSG(void, id, SEL, id)(m, sel_getUid("selectScenario:"), found);
		MSG(void, id, SEL)(m, sel_getUid("startLocationSimulation"));
		return @{ @"ok": @YES, @"scenario": scenarioName(m, found) };
	}
	NSArray* pts = q[@"points"] ?: @[ @[ q[@"lat"] ?: @0, q[@"lon"] ?: @0 ] ];
	for (NSArray* p in pts) MSG(void, id, SEL, id)(m, sel_getUid("appendSimulatedLocation:"), loc([p[0] doubleValue], [p[1] doubleValue]));
	if (pts.count == 1) {
		// one location: delivered every second and repeated (locationd's simulation controller only sends while it has
		// a next location to send)
		MSG(void, id, SEL, double)(m, sel_getUid("setLocationInterval:"), 1.0);
		MSG(void, id, SEL, unsigned long)(m, sel_getUid("setLocationRepeatBehavior:"), 1);
	} else {
		// waypoints (simctl location start): moved along at <speed> m/s (default 20), an update every <distance> m or
		// every <interval> s (default 1 s); stops at the last waypoint
		MSG(void, id, SEL, unsigned long)(m, sel_getUid("setLocationRepeatBehavior:"), 0);
		MSG(void, id, SEL, double)(m, sel_getUid("setLocationSpeed:"), q[@"speed"] ? [q[@"speed"] doubleValue] : 20.0);
		if (q[@"distance"]) MSG(void, id, SEL, double)(m, sel_getUid("setLocationDistance:"), [q[@"distance"] doubleValue]);
		else MSG(void, id, SEL, double)(m, sel_getUid("setLocationInterval:"), q[@"interval"] ? [q[@"interval"] doubleValue] : 1.0);
	}
	MSG(void, id, SEL)(m, sel_getUid("startLocationSimulation"));
	return @{ @"ok": @YES, @"points": @(pts.count) };
}

static NSDictionary* xpcPing(NSString* name) {
	// (marked unavailable in the iOS SDK; present in libxpc)
	xpc_connection_t (*create)(const char*, dispatch_queue_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
	xpc_connection_t c = create(name.UTF8String, NULL, 0);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(m, "x86sim", "ping");
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSString* r = @"no reply in 5 s";
	xpc_connection_send_message_with_reply(c, m, dispatch_get_global_queue(0, 0), ^(xpc_object_t rep) {
		char* d = xpc_copy_description(rep);
		r = @(d); free(d);
		dispatch_semaphore_signal(done);
	});
	dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
	xpc_connection_cancel(c);
	return @{ @"ok": @YES, @"reply": r };
}

static NSDictionary* addMedia(NSArray* paths) {
	dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_NOW);
	id lib = MSG(id, id, SEL)(NSClassFromString(@"PHPhotoLibrary"), sel_getUid("sharedPhotoLibrary"));
	Class cr = NSClassFromString(@"PHAssetChangeRequest");
	NSMutableArray* bad = [NSMutableArray new];
	NSError* err = nil;
	BOOL ok = MSG(BOOL, id, SEL, id, NSError**)(lib, sel_getUid("performChangesAndWait:error:"), ^{
		for (NSString* p in paths) {
			NSURL* u = [NSURL fileURLWithPath:devPath(p)];
			NSString* e = u.pathExtension.lowercaseString;
			BOOL video = [@[ @"mov", @"mp4", @"m4v" ] containsObject:e];
			id r = MSG(id, id, SEL, id)(cr, sel_getUid(video ? "creationRequestForAssetFromVideoAtFileURL:" : "creationRequestForAssetFromImageAtFileURL:"), u);
			if (!r) [bad addObject:p];
		}
	}, &err);
	if (!ok || bad.count) return @{ @"ok": @NO, @"error": err.description ?: @"", @"failed": bad };
	return @{ @"ok": @YES, @"added": @(paths.count) };
}

static void request(NSString* rest) {
	NSRange sp = [rest rangeOfString:@" "];
	if (sp.location == NSNotFound) return;
	NSString* rid = [rest substringToIndex:sp.location];
	NSData* j = [[rest substringFromIndex:sp.location + 1] dataUsingEncoding:NSUTF8StringEncoding];
	NSDictionary* q = [NSJSONSerialization JSONObjectWithData:j options:0 error:nil];
	if (![q isKindOfClass:NSDictionary.class]) { answer(rid, @{ @"ok": @NO, @"error": @"bad request" }); return; }
	NSString* c = q[@"cmd"];
	NSDictionary* r;
	if ([c isEqual:@"launch"]) r = launchApp(q);
	else if ([c isEqual:@"terminate"]) r = terminateApp(q[@"bundle"]);
	else if ([c isEqual:@"container"]) r = container(q[@"bundle"]);
	else if ([c isEqual:@"listapps"]) r = listApps();
	else if ([c isEqual:@"push"]) r = push(q[@"bundle"], q[@"payload"]);
	else if ([c isEqual:@"location"]) r = location(q);
	else if ([c isEqual:@"xpcping"]) r = xpcPing(q[@"service"]);
	else if ([c isEqual:@"addmedia"]) r = addMedia(q[@"paths"]);
	else r = @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"unknown cmd %@", c] };
	answer(rid, r);
}

// x86Sim: a Linux system call (Darling processes are Linux processes): under libarm64jit, "svc #0xfffe" is one, with
// x8 = the x86_64 syscall number (as in simfb)
static long linux_syscall3(long n, long a, long b, long c) {
	register long x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c;
	register long x8 __asm__("x8") = n;
	__asm__ volatile("svc #0xfffe" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

static volatile BOOL wake;

// x86Sim (RAM 2): what is on screen, for cli/libexec/jetsam.py. RunningBoard never backgrounds or suspends an app
// that keeps a background mode (Maps: its darwin role stays UI_FOCAL at the home screen), so the Linux side can't tell
// it left the screen; FrontBoard can. A request is <data>/tmp/x86sim-frontmost.req (its own file, so it never races
// the openurl trigger), optionally with Darling pids, one per line; the answer <data>/tmp/x86sim-frontmost (written
// .new, then renamed):
//   line 1        SBSCopyFrontmostApplicationDisplayIdentifier (empty: nil, "?": not found). It answers nil for every
//                 app here (also with Maps on screen), so jetsam.py no longer uses it; kept for diagnosis.
//   (An FBSDisplayLayoutMonitor was tried too: it delivered one nil layout and nothing after it; not kept.)
//   pid <pid> <visible> <task state>   per requested pid: RunningBoard's state (RBSProcessHandle currentState):
//                 visible = 1 with the com.apple.frontboard.visibility endowment (FrontBoard shows the process),
//                 0 without, -1 unknown; task state RBSTaskState (-1 unknown); scenes (RAM 4): visibility
//                 endowments of a UIScene FrontBoard shows (0 = left at the home screen), -1 unknown.
//   "dump <pid> <bundle id>" lines (diagnosis): RunningBoard's full state and BKSApplicationStateMonitor's.
static void dumpState(NSString* arg, NSMutableString* o) {
	NSArray* f = [arg componentsSeparatedByString:@" "];
	int pid = [f[0] intValue];
	NSString* bid = f.count > 1 ? f[1] : nil;
	dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
	Class idc = NSClassFromString(@"RBSProcessIdentifier"), hc = NSClassFromString(@"RBSProcessHandle");
	id ident = MSG(id, id, SEL, int)(idc, sel_getUid("identifierWithPid:"), pid);
	id h = ident ? MSG(id, id, SEL, id, id*)(hc, sel_getUid("handleForIdentifier:error:"), ident, NULL) : nil;
	id st = h ? MSG(id, id, SEL)(h, sel_getUid("currentState")) : nil;
	[o appendFormat:@"dump %d state %@\n", pid, [st debugDescription]];
	Class mc = NSClassFromString(@"BKSApplicationStateMonitor");
	if (mc && bid) {
		static id mon;
		if (!mon) mon = MSG(id, id, SEL)(MSG(id, id, SEL)(mc, sel_getUid("alloc")), sel_getUid("init"));
		unsigned st2 = MSG(unsigned, id, SEL, id)(mon, sel_getUid("applicationStateForApplication:"), bid);
		id info = [mon respondsToSelector:sel_getUid("applicationInfoForApplication:")] ?
			MSG(id, id, SEL, id)(mon, sel_getUid("applicationInfoForApplication:"), bid) : nil;
		[o appendFormat:@"dump %d bks %u %@\n", pid, st2, info];
	}
}

static void frontmost(NSString* home, NSString* req) {
	static NSString* (*copyFront)(void);
	static BOOL looked;
	if (!looked) {
		looked = YES;
		void* h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
		if (h) copyFront = (NSString* (*)(void))dlsym(h, "SBSCopyFrontmostApplicationDisplayIdentifier");
		if (!copyFront) { fprintf(logf_, "openurl: no SBSCopyFrontmostApplicationDisplayIdentifier\n"); fflush(logf_); }
		dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
	}
	NSString* bid = copyFront ? CFBridgingRelease((__bridge CFTypeRef)copyFront()) : nil;
	NSMutableString* o = [NSMutableString stringWithFormat:@"%@\n", bid ?: (copyFront ? @"" : @"?")];
	Class idc = NSClassFromString(@"RBSProcessIdentifier"), hc = NSClassFromString(@"RBSProcessHandle");
	for (NSString* line in [req componentsSeparatedByString:@"\n"]) {
		if ([line hasPrefix:@"dump "]) { dumpState([line substringFromIndex:5], o); continue; }
		int pid = line.intValue;
		if (pid <= 0) continue;
		long vis = -1, task = -1, scenes = -1;
		id ident = idc ? MSG(id, id, SEL, int)(idc, sel_getUid("identifierWithPid:"), pid) : nil;
		id h = ident ? MSG(id, id, SEL, id, id*)(hc, sel_getUid("handleForIdentifier:error:"), ident, NULL) : nil;
		id st = h ? MSG(id, id, SEL)(h, sel_getUid("currentState")) : nil;
		if (st) {
			NSSet* en = MSG(id, id, SEL)(st, sel_getUid("endowmentNamespaces"));
			vis = [en containsObject:@"com.apple.frontboard.visibility"] ? 1 : 0;
			task = (long)MSG(unsigned char, id, SEL)(st, sel_getUid("taskState"));
			// RAM 4: the visibility endowments FrontBoard gives per UIScene it shows (env "UIScene:<workspace>/<scene id>").
			// An app left at the home screen keeps the env-less visibility endowment, its role, BKS state 8 and
			// "frontmost", but loses its scene's endowment: the one signal here that it went off screen.
			scenes = 0;
			for (id info in MSG(id, id, SEL)(st, sel_getUid("endowmentInfos"))) {
				NSString* ns = [info respondsToSelector:sel_getUid("endowmentNamespace")] ? MSG(id, id, SEL)(info, sel_getUid("endowmentNamespace")) : nil;
				NSString* env = [info respondsToSelector:sel_getUid("environment")] ? MSG(id, id, SEL)(info, sel_getUid("environment")) : nil;
				if ([ns isEqual:@"com.apple.frontboard.visibility"] && [env isKindOfClass:NSString.class] && [env hasPrefix:@"UIScene:"])
					scenes++;
			}
		}
		[o appendFormat:@"pid %d %ld %ld %ld\n", pid, vis, task, scenes];
	}
	NSString* out = [home stringByAppendingString:@"/tmp/x86sim-frontmost"];
	NSString* tmp = [out stringByAppendingString:@".new"];
	[o writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil];
	rename(tmp.UTF8String, out.UTF8String);
}

// x86Sim: waits for the request file to be renamed into place (see main)
static void* watchThread(void* arg) {
	long ifd = (long)arg;
	char buf[4096];
	for (;;) {
		long r = linux_syscall3(0 /* read */, ifd, (long)buf, sizeof(buf));
		if (r == -4 /* EINTR */)
			continue;
		if (r <= 0)
			return NULL; // the 5 s fallback poll stays
		wake = YES;
		CFRunLoopStop(CFRunLoopGetMain());
	}
}

int main(void) {
	@autoreleasepool {
		NSString* home = @(getenv("HOME") ?: "/private/var/tmp");
		home_ = home;
		// x86Sim: diagnosis: this process's os_log into var/log/oslog.openurl.<pid>.log through libsimshim, when <data>/tmp/x86sim-openurl.oslog exists
		if (access([home stringByAppendingString:@"/tmp/x86sim-openurl.oslog"].UTF8String, F_OK) == 0) {
			setenv("X86SIM_OSLOG", "all", 1);
			setenv("X86SIM_OSLOG_DIR", [home stringByAppendingString:@"/var/log"].UTF8String, 1);
		}
		logf_ = fopen([home stringByAppendingString:@"/var/log/x86sim-openurl.log"].UTF8String, "a");
		dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
		dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
		fprintf(logf_, "openurl: ready\n"); fflush(logf_);
		const char* path = [home stringByAppendingString:@"/tmp/x86sim-openurl"].UTF8String;
		// x86Sim: wait for the request file instead of polling it every 0.3 s (~40 wakeups a second at idle, and up to
		// 0.3 s added to every `x86sim app`). The writers rename x86sim-openurl.new over it: a Linux inotify watch on the
		// directory (IN_MOVED_TO/IN_CLOSE_WRITE; Darling processes make Linux syscalls directly, as simfb's futex does)
		// whose descriptor a dispatch read source waits on. (A DISPATCH_SOURCE_TYPE_VNODE on the directory never
		// registered under Darling's libkqueue.) The run loop still runs between requests (CoreLocation
		// delivers on the main queue); a 5 s poll stays as a fallback, 0.3 s if the watch can't be set up.

		int dirfd = open([home stringByAppendingString:@"/tmp"].UTF8String, O_RDONLY);
		long ifd = dirfd >= 0 ? linux_syscall3(294 /* inotify_init1 */, 02000000 /* IN_CLOEXEC; blocking: watchThread reads it */, 0, 0) : -1;
		if (ifd >= 0) {
			char fdpath[64];
			snprintf(fdpath, sizeof(fdpath), "/proc/self/fd/%d", dirfd);
			if (linux_syscall3(254 /* inotify_add_watch */, ifd, (long)fdpath, 0x80 | 0x8 /* IN_MOVED_TO|IN_CLOSE_WRITE */) < 0)
				ifd = -1;
		}
		if (ifd >= 0) {
			// x86Sim: a thread of its own blocks in read() on the inotify descriptor. A dispatch read source on it (on
			// the main queue, later on a serial queue) delivered the first event only: libdispatch never got the next
			// one, so every request after the first waited for the 5 s fallback. CFRunLoopStop is
			// thread-safe and isn't lost when the loop isn't waiting yet (its next run returns at once).
			pthread_t th;
			pthread_create(&th, NULL, watchThread, (void*)ifd);
			pthread_detach(th);
			fprintf(logf_, "openurl: watching %s/tmp (inotify)\n", home.UTF8String); fflush(logf_);
		}
		for (;;) {
			@autoreleasepool {
				if (!wake)
					// returns after one source was handled (the vnode event, or anything else on the main queue)
					[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
						beforeDate:[NSDate dateWithTimeIntervalSinceNow:ifd >= 0 ? 5.0 : 0.3]];
				wake = NO;
				NSString* freq = [home stringByAppendingString:@"/tmp/x86sim-frontmost.req"];
				NSString* fr = [NSString stringWithContentsOfFile:freq encoding:NSUTF8StringEncoding error:nil];
				if (unlink(freq.UTF8String) == 0)
					frontmost(home, fr ?: @"");
				NSString* s = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
				if (!s) continue;
				unlink(path);
				for (NSString* line in [s componentsSeparatedByString:@"\n"]) {
					NSString* u = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
					if ([u hasPrefix:@"req "]) { request([u substringFromIndex:4]); continue; }
					// "app <bundle id>[\t<arg>...]": launch (arguments tab-separated)
					if ([u hasPrefix:@"app "]) {
						NSArray* f = [[u substringFromIndex:4] componentsSeparatedByString:@"\t"];
						NSString* bid = [f[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
						openViaFrontBoard(nil, bid, bid, [f subarrayWithRange:NSMakeRange(1, f.count - 1)]);
						continue;
					}
					// "install <path>" (absolute, or relative to the device's data directory), "uninstall <bundle id>"
					if ([u hasPrefix:@"install "]) {
						installApp(devPath([[u substringFromIndex:8] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]));
						continue;
					}
					if ([u hasPrefix:@"uninstall "]) {
						uninstallApp([[u substringFromIndex:10] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
						continue;
					}
					BOOL ls = [u hasPrefix:@"ls "];
					if (ls) u = [[u substringFromIndex:3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
					if (!u.length) continue;
					NSURL* url = [NSURL URLWithString:u];
					if (!url) { fprintf(logf_, "openurl %s: not a URL\n", u.UTF8String); fflush(logf_); continue; }
					if (ls) openViaLS(url, u); else openViaFrontBoard(url, u, nil, nil);
				}
			}
		}
	}
}
