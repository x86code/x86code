// x86Sim: stand-in for the Mac host's FileProvider simulator support service, com.apple.FileProvider.sim2host.
//
// In an iOS simulator, FileProvider (fileproviderd, its extensions, apps) sends the file operations a simulator process
// can't do itself to the host's fileproviderd: open by file id, openat/mkdirat/unlinkat/renameat on behalf of the
// extension, xattrs, dataless files... (+[FPDaemonConnection simulatorHostConnection], the NSXPCInterface from
// FPSimulatorSupportInterface()). There is no Mac here: this simulator job (cli/libexec/arm64/boot-a64.sh: com.x86sim.fpsim2host,
// MachServices com.apple.FileProvider.sim2host; simshim keeps the connection a simulator one) does them in-process.
// Without it the On My iPhone extension failed "can't resolve did=... [78: Function not implemented]" and Files could
// not open any document.
//
// The calls are handled in -forwardInvocation: with the protocol's own method signatures, so argument types come from
// FileProvider itself. Every method's signature is logged at start (data/var/log/fpsim2host.log), and every call.
// All 16 methods are answered: open by id, openat/mkdirat/unlinkat/
// renameat, xattrs, package lookup (FileProvider's own fpfs_pkg_path_lookup on the path), directory entries
// (getattrlistbulk records), dataless files (SF_DATALESS + sparse logical size; materialize copies the content in and
// clears the flag; nothing faults on read), purgeable and sync-root marks (kept in xattrs), materialization handlers
// (kept, never called: there are no dataless faults).
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/mount.h>
#include <sys/attr.h>
#include <stdbool.h>
#include <ftw.h>
#include <stdio.h>

#include <dlfcn.h>
static NSXPCInterface* (*FPSimulatorSupportInterface)(void);   // FileProvider.framework, not in the SDK stubs
extern ssize_t fsgetpath(char* buf, size_t bufsize, fsid_t* fsid, uint64_t objid);
extern int renameatx_np(int fromfd, const char* from, int tofd, const char* to, unsigned int flags);
extern const char* _protocol_getMethodTypeEncoding(Protocol* p, SEL sel, BOOL required, BOOL instance);

static FILE* logf_;
#define LOG(...) do { if (logf_) { fprintf(logf_, __VA_ARGS__); fputc('\n', logf_); fflush(logf_); } } while (0)

static Protocol* proto;
static NSMutableDictionary* handlers;   // materialization handlers by path
// FileProvider.framework: package detection for a path (FileProvider's own code, as the Mac host runs it)
static int (*fpfs_pkg_path_lookup)(const char* path, const char* root, bool accept_demoted, bool* is_pkg, bool* is_demoted,
	uint64_t* type, unsigned detection);

// "@?<v@?@\"NSFileHandle\"@\"NSError\">" -> the block's own type string "v@?@@" (quotes, class names dropped)
static NSString* blockTypes(const char* ext) {
	const char* lt = strchr(ext, '<');
	if (!lt) return nil;
	NSMutableString* out = [NSMutableString string];
	int depth = 0;
	for (const char* p = lt + 1; *p; p++) {
		if (*p == '<') { depth++; continue; }
		if (*p == '>') { if (depth-- == 0) break; continue; }
		if (depth) continue;
		if (*p == '"') { p = strchr(p + 1, '"'); if (!p) break; continue; }
		if (isdigit((unsigned char) *p)) continue;
		[out appendFormat:@"%c", *p];
	}
	return out;
}

// the extended type at index i of a method (0 = return, 1 = self, 2 = _cmd, 3.. = arguments, i.e. NSInvocation index + 1)
static NSString* extArgType(SEL sel, NSUInteger argIndex) {
	const char* e = _protocol_getMethodTypeEncoding(proto, sel, YES, YES);
	if (!e) e = _protocol_getMethodTypeEncoding(proto, sel, NO, YES);
	if (!e) return nil;
	// walk: type, offset, type, offset...
	NSUInteger idx = 0;
	const char* p = e;
	while (*p) {
		const char* start = p;
		// one type: may contain "..." and <...>
		if (*p == '@' && p[1] == '?' && p[2] == '<') {
			int depth = 0;
			p += 2;
			do { if (*p == '<') depth++; else if (*p == '>') depth--; else if (*p == '"') p = strchr(p + 1, '"'); p++; } while (depth && *p);
		} else if (*p == '@' && p[1] == '"') {
			p = strchr(p + 2, '"') + 1;
		} else {
			while (*p && strchr("rnNoORV", *p)) p++;
			if (*p == '^') p++;
			if (*p == '{' || *p == '(' || *p == '[') {
				char open = *p, close = open == '{' ? '}' : open == '(' ? ')' : ']';
				int depth = 0;
				do { if (*p == open) depth++; else if (*p == close) depth--; p++; } while (depth && *p);
			} else if (*p) p++;
		}
		NSString* t = [[NSString alloc] initWithBytes:start length:p - start encoding:NSUTF8StringEncoding];
		while (isdigit((unsigned char) *p)) p++;
		if (idx == argIndex) return t;
		idx++;
	}
	return nil;
}

static NSError* posixError(int e) {
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:e userInfo:nil];
}

static NSFileHandle* handle(int fd) {
	return fd < 0 ? nil : [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
}

static int rmTreeEntry(const char* path, const struct stat* sb, int flag, struct FTW* ftw) {
	return remove(path);
}

@interface NSInvocation (Private)
- (void)invokeUsingIMP:(IMP)imp;
@end

@interface Sim2Host : NSObject
@end

@implementation Sim2Host

- (NSMethodSignature*)methodSignatureForSelector:(SEL)sel {
	struct objc_method_description d = protocol_getMethodDescription(proto, sel, YES, YES);
	if (!d.types) d = protocol_getMethodDescription(proto, sel, NO, YES);
	if (d.types) return [NSMethodSignature signatureWithObjCTypes:d.types];
	return [super methodSignatureForSelector:sel];
}

- (BOOL)respondsToSelector:(SEL)sel {
	if (protocol_getMethodDescription(proto, sel, YES, YES).types || protocol_getMethodDescription(proto, sel, NO, YES).types)
		return YES;
	return [super respondsToSelector:sel];
}

// argument i (2.. = after self/_cmd) as an integer or an object
static long long intArg(NSInvocation* inv, NSUInteger i) {
	const char* t = [inv.methodSignature getArgumentTypeAtIndex:i];
	while (*t && strchr("rnNoORV", *t)) t++;
	NSUInteger size; NSGetSizeAndAlignment(t, &size, NULL);
	long long v = 0;
	if (size <= sizeof(v)) {
		[inv getArgument:&v atIndex:i];
		if (size == 4 && strchr("ilc s", *t)) v = (int) v; // signed 32-bit
		else if (size == 4) v = (unsigned int) v;
		else if (size == 2) v = (short) v;
		else if (size == 1) v = (signed char) v;
	}
	return v;
}
static id objArg(NSInvocation* inv, NSUInteger i) {
	__unsafe_unretained id o = nil;
	[inv getArgument:&o atIndex:i];
	return o;
}

// call the completion block (the last argument) with the given values: objects for '@' slots in order, integers for
// the others (nums[i] for the i-th non-object slot, the last one repeated); an NSError slot gets err
static void replyv(NSInvocation* inv, NSArray* objs, const long long* nums, int nnums, NSError* err);
static void reply(NSInvocation* inv, NSArray* objs, long long num, NSError* err) {
	replyv(inv, objs, &num, 1, err);
}
// a call that answers only success or an error: r < 0 fails with errno
static void replyStatus(NSInvocation* inv, int r) {
	int e = errno;
	LOG("  -> %d errno %d", r, r < 0 ? e : 0);
	reply(inv, @[], 0, r < 0 ? posixError(e) : nil);
}
static void replyv(NSInvocation* inv, NSArray* objs, const long long* nums, int nnums, NSError* err) {
	NSUInteger last = inv.methodSignature.numberOfArguments - 1;
	id block = objArg(inv, last);
	if (!block) return;
	NSString* ext = extArgType(inv.selector, last + 1);
	NSString* bt = blockTypes(ext.UTF8String ?: "");
	if (!bt.length) { LOG("  no block type for %s", sel_getName(inv.selector)); return; }
	NSMethodSignature* bs = [NSMethodSignature signatureWithObjCTypes:bt.UTF8String];
	NSInvocation* bi = [NSInvocation invocationWithMethodSignature:bs];
	[bi setTarget:block];
	NSUInteger oi = 0, ni = 0;
	for (NSUInteger a = 1; a < bs.numberOfArguments; a++) {
		const char* t = [bs getArgumentTypeAtIndex:a];
		if (*t == '@') {
			// the last object slot that the extended type calls NSError gets the error
			id v = nil;
			BOOL isErr = a == bs.numberOfArguments - 1 && [ext containsString:@"NSError\">"];
			if (isErr) v = err;
			else if (oi < objs.count) { v = objs[oi] == (id) [NSNull null] ? nil : objs[oi]; oi++; }
			[bi setArgument:&v atIndex:a];
		} else {
			long long v = nums[ni < (NSUInteger) nnums ? ni : (NSUInteger) nnums - 1];
			ni++;
			[bi setArgument:&v atIndex:a];   // little-endian: the low bytes
		}
	}
	[bi retainArguments];
	struct Block_layout { void* isa; int flags, reserved; void (*invoke)(void); } * bl = (__bridge void*) block;
	[bi invokeUsingIMP:(IMP) bl->invoke];
}

- (void)forwardInvocation:(NSInvocation*)inv {
	SEL sel = inv.selector;
	const char* name = sel_getName(sel);
	NSUInteger n = inv.methodSignature.numberOfArguments;
	NSMutableString* args = [NSMutableString string];
	for (NSUInteger i = 2; i + 1 < n; i++) {
		const char* t = [inv.methodSignature getArgumentTypeAtIndex:i];
		if (*t == '@') [args appendFormat:@" %@", objArg(inv, i)];
		else [args appendFormat:@" %lld", intArg(inv, i)];
	}
	LOG("%s%s", name, args.UTF8String);

	if (!strcmp(name, "sim_requestProtocolVersion:completionHandler:")) {
		// the host's protocol version: answer the one the client speaks
		long long v = intArg(inv, 2);
		reply(inv, @[], v, nil);
		LOG("  -> version %lld", v);
		return;
	}
	if (!strcmp(name, "sim_openByID:device:oflag:completionHandler:")) {
		uint64_t objid = (uint64_t) intArg(inv, 2);
		fsid_t fsid = { { (int32_t) intArg(inv, 3), 0 } };
		int oflag = (int) intArg(inv, 4);
		char path[PATH_MAX];
		ssize_t r = fsgetpath(path, sizeof(path), &fsid, objid);
		if (r < 0) { int e = errno; LOG("  -> fsgetpath errno %d", e); reply(inv, @[[NSNull null]], 0, posixError(e)); return; }
		int fd = open(path, oflag | O_CLOEXEC);
		int e = errno;
		LOG("  -> %s fd %d errno %d", path, fd, fd < 0 ? e : 0);
		reply(inv, @[handle(fd) ?: [NSNull null]], 0, fd < 0 ? posixError(e) : nil);
		return;
	}
	if (!strcmp(name, "sim_openAt:path:flags:permissions:completionHandler:")) {
		NSFileHandle* dir = objArg(inv, 2);
		NSString* path = objArg(inv, 3);
		int fd = openat(dir ? dir.fileDescriptor : AT_FDCWD, path.fileSystemRepresentation, (int) intArg(inv, 4) | O_CLOEXEC, (int) intArg(inv, 5));
		int e = errno;
		LOG("  -> fd %d errno %d", fd, fd < 0 ? e : 0);
		reply(inv, @[handle(fd) ?: [NSNull null]], 0, fd < 0 ? posixError(e) : nil);
		return;
	}
	if (!strcmp(name, "sim_mkdirAt:path:permissions:completionHandler:")) {
		NSFileHandle* dir = objArg(inv, 2);
		NSString* path = objArg(inv, 3);
		int r = mkdirat(dir ? dir.fileDescriptor : AT_FDCWD, path.fileSystemRepresentation, (mode_t) intArg(inv, 4));
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_unlinkAt:path:flag:recursive:completionHandler:")) {
		NSFileHandle* dir = objArg(inv, 2);
		NSString* path = objArg(inv, 3);
		int flag = (int) intArg(inv, 4);
		BOOL recursive = intArg(inv, 5) != 0;
		int r;
		if (recursive) {
			char full[PATH_MAX];
			if (dir && path.fileSystemRepresentation[0] != '/') {
				char dpath[PATH_MAX];
				fcntl(dir.fileDescriptor, F_GETPATH, dpath);
				snprintf(full, sizeof(full), "%s/%s", dpath, path.fileSystemRepresentation);
			} else
				snprintf(full, sizeof(full), "%s", path.fileSystemRepresentation);
			r = nftw(full, rmTreeEntry, 32, FTW_DEPTH | FTW_PHYS);
		} else
			r = unlinkat(dir ? dir.fileDescriptor : AT_FDCWD, path.fileSystemRepresentation, flag);
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_renameAt:from:tofd:to:flags:completionHandler:")) {
		NSFileHandle* fromDir = objArg(inv, 2);
		NSString* from = objArg(inv, 3);
		NSFileHandle* toDir = objArg(inv, 4);
		NSString* to = objArg(inv, 5);
		int r = renameatx_np(fromDir ? fromDir.fileDescriptor : AT_FDCWD, from.fileSystemRepresentation,
			toDir ? toDir.fileDescriptor : AT_FDCWD, to.fileSystemRepresentation, (unsigned) intArg(inv, 6));
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_setOrClearXattr:data:onFile:completionHandler:")) {
		NSString* xname = objArg(inv, 2);
		NSData* data = objArg(inv, 3);
		NSFileHandle* fh = objArg(inv, 4);
		int r = data ? fsetxattr(fh.fileDescriptor, xname.UTF8String, data.bytes, data.length, 0, 0)
			: fremovexattr(fh.fileDescriptor, xname.UTF8String, 0);
		if (r < 0 && !data && errno == ENOATTR) r = 0;   // removing an absent xattr is done
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_pkgLookup:name:acceptDemotedPkg:detection:completionHandler:")) {
		// (isPackage, isDemoted, type, error) for name in dir (or dir itself). The Mac's fileproviderd runs FileProvider's
		// own package detection on the host path (bundle bit, registered package extensions); so do we, with the same
		// function the framework uses for paths (fpfs_pkg_path_lookup: no host round trip).
		NSFileHandle* dir = objArg(inv, 2);
		NSString* pname = objArg(inv, 3);
		BOOL accept = intArg(inv, 4) != 0;
		unsigned detection = (unsigned) intArg(inv, 5);
		char dpath[PATH_MAX] = "", full[PATH_MAX];
		if (dir) fcntl(dir.fileDescriptor, F_GETPATH, dpath);
		if (pname.length) snprintf(full, sizeof(full), "%s%s%s", dpath, dpath[0] ? "/" : "", pname.fileSystemRepresentation);
		else snprintf(full, sizeof(full), "%s", dpath);
		bool isPkg = false, demoted = false;
		uint64_t type = 0;
		int r = fpfs_pkg_path_lookup ? fpfs_pkg_path_lookup(full, NULL, accept, &isPkg, &demoted, &type, detection) : 0;
		int e = errno;
		// x86Sim: a Mac's fileproviderd also takes directories whose extension LaunchServices registers as a package
		// type (.app, .bundle, ...) for packages, bundle bit or not; Linux file systems never carry the bundle bit,
		// and FileProvider's own lookup (detection 0, as LocalStorage asks) answered "plain directory" for them.
		struct stat st;
		if (r == 0 && !isPkg && pname.length && pname.pathExtension.length && stat(full, &st) == 0 && S_ISDIR(st.st_mode)) {
			Class ut = NSClassFromString(@"UTType");
			// the type of a directory with this extension (app -> com.apple.application-bundle, bundle -> com.apple.bundle)
			id dir = ut ? ((id (*)(id, SEL, id)) objc_msgSend)(ut, sel_getUid("typeWithIdentifier:"), @"public.directory") : nil;
			id t = dir ? ((id (*)(id, SEL, id, id)) objc_msgSend)(ut, sel_getUid("typeWithFilenameExtension:conformingToType:"), pname.pathExtension, dir) : nil;
			id pkg = ut ? ((id (*)(id, SEL, id)) objc_msgSend)(ut, sel_getUid("typeWithIdentifier:"), @"com.apple.package") : nil;
			if (t && pkg && ((BOOL (*)(id, SEL, id)) objc_msgSend)(t, sel_getUid("conformsToType:"), pkg)) isPkg = true;
			LOG("  pkgLookup: %s by extension: type %s -> package %d", pname.UTF8String, [[t description] UTF8String] ?: "nil", isPkg);
		}
		long long nums[3] = { isPkg, demoted, (long long) type };
		replyv(inv, @[], nums, 3, r < 0 ? posixError(e) : nil);
		LOG("  -> %s: package %d demoted %d type %llu (r %d errno %d)", full, isPkg, demoted, (unsigned long long) type, r, r < 0 ? e : 0);
		return;
	}
	if (!strcmp(name, "sim_makeDatalessFileAt:type:documentSize:entryCount:completionHandler:")) {
		// APFS makes the item dataless: SF_DATALESS, the logical size, no data; reading it faults the provider in to
		// materialize it. Here: the flag (Darling keeps BSD flags per file) and, for a file, a sparse file of the
		// logical size. There are no faults: reading gives zeros until materializeFile.
		NSFileHandle* fh = objArg(inv, 2);
		long long size = intArg(inv, 4);
		struct stat st;
		int r = fstat(fh.fileDescriptor, &st);
		if (r == 0 && S_ISREG(st.st_mode) && size >= 0) r = ftruncate(fh.fileDescriptor, size);
		if (r == 0) r = fchflags(fh.fileDescriptor, st.st_flags | SF_DATALESS);
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_unsetDatalessBitAt:completionHandler:")) {
		NSFileHandle* fh = objArg(inv, 2);
		struct stat st;
		int r = fstat(fh.fileDescriptor, &st);
		if (r == 0 && (st.st_flags & SF_DATALESS)) r = fchflags(fh.fileDescriptor, st.st_flags & ~SF_DATALESS);
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_materializeFile:from:size:completionHandler:")) {
		// the provider's downloaded content (from) becomes the dataless file's data (APFS swaps the extents in);
		// here it is copied and the dataless flag cleared
		NSFileHandle* dst = objArg(inv, 2);
		NSFileHandle* src = objArg(inv, 3);
		long long size = intArg(inv, 4);
		int r = 0, e = 0;
		char buf[65536];
		off_t off = 0;
		while (r == 0 && (size < 0 || off < size)) {
			size_t want = sizeof(buf);
			if (size >= 0 && (long long) want > size - off) want = (size_t) (size - off);
			ssize_t n = pread(src.fileDescriptor, buf, want, off);
			if (n < 0) { r = -1; break; }
			if (n == 0) break;
			if (pwrite(dst.fileDescriptor, buf, n, off) != n) { r = -1; break; }
			off += n;
		}
		if (r == 0) r = ftruncate(dst.fileDescriptor, off);
		struct stat st;
		if (r == 0 && fstat(dst.fileDescriptor, &st) == 0 && (st.st_flags & SF_DATALESS))
			r = fchflags(dst.fileDescriptor, st.st_flags & ~SF_DATALESS);
		e = errno;
		LOG("  -> %lld bytes, %d errno %d", (long long) off, r, r < 0 ? e : 0);
		reply(inv, @[], 0, r < 0 ? posixError(e) : nil);
		return;
	}
	if (!strcmp(name, "sim_markPurgeable:flags:syncRoot:completionHandler:")) {
		// APFS purgeable marking (the system may delete the file's data under storage pressure). Nothing purges here;
		// the flags are kept in an xattr so they can be read back.
		NSFileHandle* fh = objArg(inv, 2);
		uint64_t flags = (uint64_t) intArg(inv, 3);
		int r = fsetxattr(fh.fileDescriptor, "com.apple.x86sim.purgeable", &flags, sizeof(flags), 0, 0);
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_setSyncRoot:flags:completionHandler:")) {
		// APFS marks the directory a File Provider sync root. Darling's fsctl answers "no enclosing sync root" for
		// every item (misc/fsctl.c); the mark is kept in an xattr.
		NSFileHandle* fh = objArg(inv, 2);
		int flags = (int) intArg(inv, 3);
		int r = fsetxattr(fh.fileDescriptor, "com.apple.x86sim.syncroot", &flags, sizeof(flags), 0, 0);
		replyStatus(inv, r);
		return;
	}
	if (!strcmp(name, "sim_registerMaterializationHandler:forURL:completionHandler:")) {
		// the host calls the handler when something reads a dataless item under the URL. Without dataless faults
		// (see makeDatalessFileAt) it is never called; it is kept so unregister finds it.
		id handler = objArg(inv, 2);
		NSURL* url = objArg(inv, 3);
		if (url && handler) handlers[url.path] = handler;
		LOG("  -> registered (%lu)", (unsigned long) handlers.count);
		reply(inv, @[], 0, nil);
		return;
	}
	if (!strcmp(name, "sim_unregisterMaterializationHandlerForURL:completionHandler:")) {
		NSURL* url = objArg(inv, 2);
		if (url) [handlers removeObjectForKey:url.path];
		LOG("  -> unregistered (%lu)", (unsigned long) handlers.count);
		reply(inv, @[], 0, nil);
		return;
	}
	if (!strcmp(name, "sim_dirEntryHelper:completionHandler:")) {
		// the next directory entries of the directory, as getattrlistbulk records (FileProvider's fpfs_fgetdirentries
		// reads up to 32 KB of length-prefixed records and parses each with ATTR_CMN_RETURNED_ATTRS), and their count.
		// The descriptor is shared with the client's, so successive calls continue where the last one stopped.
		NSFileHandle* fh = objArg(inv, 2);
		struct attrlist al = { ATTR_BIT_MAP_COUNT, 0,
			ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_FSID | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME |
			ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_ACCTIME | ATTR_CMN_OWNERID | ATTR_CMN_GRPID |
			ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS | ATTR_CMN_GEN_COUNT | ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID |
			ATTR_CMN_PARENTID | ATTR_CMN_ADDEDTIME,
			0, ATTR_DIR_LINKCOUNT | ATTR_DIR_ENTRYCOUNT, ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE |
			ATTR_FILE_DATALENGTH, ATTR_CMNEXT_LINKID };
		NSMutableData* d = [NSMutableData dataWithLength:0x8000];
		int n = getattrlistbulk(fh.fileDescriptor, &al, d.mutableBytes, d.length, FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED);
		int e = errno;
		if (n < 0) { reply(inv, @[[NSNull null]], 0, posixError(e)); LOG("  -> errno %d", e); return; }
		// the records' total length
		size_t used = 0;
		for (int i = 0; i < n; i++) used += *(uint32_t*) ((char*) d.bytes + used);
		d.length = used;
		reply(inv, @[d], n, nil);
		LOG("  -> %d entries, %zu bytes", n, used);
		return;
	}
	// anything else: not supported here
	LOG("  -> ENOTSUP (not implemented)");
	reply(inv, @[], 0, posixError(ENOTSUP));
}
@end

@interface Delegate : NSObject <NSXPCListenerDelegate>
@end
@implementation Delegate
- (BOOL)listener:(NSXPCListener*)listener shouldAcceptNewConnection:(NSXPCConnection*)c {
	c.exportedInterface = FPSimulatorSupportInterface();
	c.exportedObject = [Sim2Host new];
	LOG("connection from pid %d", c.processIdentifier);
	[c resume];
	return YES;
}
@end

int main(int argc, char** argv) {
	@autoreleasepool {
		const char* home = getenv("HOME");
		char p[1024];
		snprintf(p, sizeof(p), "%s/var/log/fpsim2host.log", home ? home : "/tmp");
		logf_ = fopen(p, "a");
		void* fp = dlopen("/System/Library/Frameworks/FileProvider.framework/FileProvider", RTLD_NOW);
		dlopen("/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers", RTLD_NOW); // x86Sim: UTType (pkgLookup)
		FPSimulatorSupportInterface = fp ? dlsym(fp, "FPSimulatorSupportInterface") : NULL;
		fpfs_pkg_path_lookup = fp ? dlsym(fp, "fpfs_pkg_path_lookup") : NULL;
		handlers = [NSMutableDictionary new];
		if (!FPSimulatorSupportInterface) { LOG("fpsim2host: no FPSimulatorSupportInterface (%s)", dlerror()); return 1; }
		NSXPCInterface* iface = FPSimulatorSupportInterface();
		proto = iface.protocol;
		LOG("fpsim2host: protocol %s", proto ? protocol_getName(proto) : "(none)");
		unsigned cnt = 0;
		struct objc_method_description* m = protocol_copyMethodDescriptionList(proto, YES, YES, &cnt);
		for (unsigned i = 0; i < cnt; i++)
			LOG("  %s %s", sel_getName(m[i].name), _protocol_getMethodTypeEncoding(proto, m[i].name, YES, YES) ?: m[i].types);
		free(m);
		static Delegate* d;
		d = [Delegate new];
		// initWithMachServiceName: is marked unavailable on iOS in the SDK; the runtime has it
		NSXPCListener* l = ((id (*)(id, SEL, id)) objc_msgSend)([NSXPCListener alloc], sel_registerName("initWithMachServiceName:"), @"com.apple.FileProvider.sim2host");
		l.delegate = d;
		[l resume];
		[[NSRunLoop mainRunLoop] run];
	}
	return 0;
}
