// x86Sim: iosurfaced -- the simulator's "com.apple.IOSurface.Remote" service (Darling side).
//
// On a Mac, CoreSimulator's SimRenderServer hosts IOSurfaceRemoteServer and every simulator process's
// IOSurface.framework talks to it (docs/protocols/IOSURFACE.md). Here the simulator's own IOSurface clients
// talk to this process instead: a launchd job of the device (cli/libexec/mksimdevice.py, X86SIM_IOSURFACE=1).
//
// Surfaces are mmap(MAP_SHARED|MAP_ANON) memory handed out as xpc_shmem ("MemoryObject"). darlingserver moves
// shared anonymous memory into a memfd when it is first shared, so every process that maps the surface (and
// mtlvk, via syscall 599 in metalhostd) sees the same pages.
//
// State: global table of surfaces (id -> Surf), per-connection reference counts (released when the
// connection goes away), mach ports minted by CreateMachPort (we keep the receive right; a lookup by port
// finds the surface by the port's name in our space).
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <stdatomic.h>

extern xpc_connection_t x86_xpc_connection_create_mach_service(const char* name, dispatch_queue_t q, uint64_t flags)
	__asm__("_xpc_connection_create_mach_service");
extern pid_t x86_xpc_connection_get_pid(xpc_connection_t c) __asm__("_xpc_connection_get_pid");
extern xpc_object_t xpc_shmem_create(void* region, size_t length);
extern size_t xpc_shmem_map(xpc_object_t xshmem, void** region);
extern CFDataRef IOCFSerialize(CFTypeRef object, CFOptionFlags options);
extern CFTypeRef IOCFUnserializeBinary(const char* buffer, size_t bufferSize, CFAllocatorRef allocator,
	CFOptionFlags options, CFStringRef* errorString);

#define kIOReturnUnsupported 0xE00002C7u
#define kIOReturnNotFound    0xE00002F0u
#define kIOReturnBadArgument 0xE00002C2u
#define kIOReturnNoMemory    0xE00002BDu
#define kIOReturnNoSpace     0xE00002C3u

#pragma pack(push, 1)
typedef struct {
	uint32_t zero, id, allocSize, width, height, bytesPerRow, offset, pixelFormat, cacheMode, planeCount;
	uint32_t bytesPerElement, elementWidth, elementHeight, seed, subsampling;
	uint8_t flags;
	uint64_t traceID;
	uint8_t pad[3];
} SurfaceState;
typedef struct {
	uint16_t zero, index;
	uint32_t width, height, offset, bytesPerRow, size;
	uint32_t extended[4];
	uint16_t bytesPerElement;
	uint8_t elementWidth, elementHeight, ncomp;
	uint8_t depth[4], bitoff[4], name[4], type[4], range[4];
	uint8_t pad[7];
} PlaneState;
typedef struct {
	uint32_t one, offsetMask, bprMask, maxBpr, maxWidth, maxHeight;
	uint64_t unknown, flags;
} Limits;
#pragma pack(pop)
_Static_assert(sizeof(SurfaceState) == 0x48, "SurfaceState");
_Static_assert(sizeof(PlaneState) == 0x48, "PlaneState");
_Static_assert(sizeof(Limits) == 0x28, "Limits");

#define MAXPLANES 20
typedef struct Surf {
	uint32_t id;
	void* mem;          // page-aligned mapping
	size_t mapsize;     // round_page(alloc)
	bool clientMem;     // ClientProvidedShmem: unmap only
	SurfaceState st;
	PlaneState planes[MAXPLANES];
	CFMutableDictionaryRef values;
	xpc_object_t bulk;  // SetBulkAttachments keys
	mach_port_t port;   // receive right minted by CreateMachPort
	int refs;           // sum of all connections' references
	int useCount, catUse[16];
	uint32_t yuvMatrix;
} Surf;

static NSMutableDictionary<NSNumber*, NSValue*>* gByID;    // id -> Surf*
static NSMutableDictionary<NSNumber*, NSNumber*>* gByPort; // port name -> id
static uint32_t gNextID = 1;
static bool gLog;

#define LOG(...) do { if (gLog) fprintf(stderr, "iosurfaced: " __VA_ARGS__); } while (0)

static Surf* surfFor(uint32_t sid) { return (Surf*)[gByID[@(sid)] pointerValue]; }

static uint64_t num(CFDictionaryRef d, const char* key, uint64_t dflt) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v = CFDictionaryGetValue(d, k);
	CFRelease(k);
	if (!v) return dflt;
	if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int64_t x = 0;
		CFNumberGetValue(v, kCFNumberSInt64Type, &x);
		return (uint64_t)x;
	}
	if (CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue(v);
	return dflt;
}
static bool has(CFDictionaryRef d, const char* key) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	bool r = CFDictionaryContainsKey(d, k);
	CFRelease(k);
	return r;
}
static uint32_t align64(uint64_t x) { return (uint32_t)((x + 63) & ~63ull); }

static void surfFree(Surf* s) {
	LOG("free surface %u\n", s->id);
	[gByID removeObjectForKey:@(s->id)];
	if (s->port) {
		[gByPort removeObjectForKey:@(s->port)];
		mach_port_mod_refs(mach_task_self(), s->port, MACH_PORT_RIGHT_RECEIVE, -1);
	}
	if (s->mem) munmap(s->mem, s->mapsize);
	if (s->values) CFRelease(s->values);
	if (s->bulk) xpc_release(s->bulk);
	free(s);
}

// properties -> layout (docs/protocols/IOSURFACE.md section 5, after IOSurfaceClientCreate_Emulated)
static uint32_t surfCreate(CFDictionaryRef props, xpc_object_t clientShmem, Surf** out) {
	Surf* s = calloc(1, sizeof(Surf));
	uint32_t W = (uint32_t)num(props, "IOSurfaceWidth", 0), H = (uint32_t)num(props, "IOSurfaceHeight", 0);
	uint32_t bpe = (uint32_t)num(props, "IOSurfaceBytesPerElement", 1);
	uint32_t ew = (uint32_t)num(props, "IOSurfaceElementWidth", 1), eh = (uint32_t)num(props, "IOSurfaceElementHeight", 1);
	if (!bpe) bpe = 1;
	if (!ew) ew = 1;
	if (!eh) eh = 1;
	uint32_t offset = (uint32_t)num(props, "IOSurfaceOffset", 0);
	uint32_t bpr = has(props, "IOSurfaceBytesPerRow") ? (uint32_t)num(props, "IOSurfaceBytesPerRow", 0)
	                                                  : align64((uint64_t)((W + ew - 1) / ew) * bpe);
	s->st.width = W; s->st.height = H; s->st.bytesPerElement = bpe; s->st.elementWidth = ew; s->st.elementHeight = eh;
	s->st.offset = offset; s->st.bytesPerRow = bpr;
	s->st.pixelFormat = (uint32_t)num(props, "IOSurfacePixelFormat", 0);
	s->st.cacheMode = (uint32_t)num(props, "IOSurfaceCacheMode", 0);
	s->st.subsampling = (uint32_t)num(props, "IOSurfaceSubsampling", 0);
	if (num(props, "IOSurfacePixelSizeCastingAllowed", 1)) s->st.flags |= 1;
	if (num(props, "_IOSurfaceIsDisplayable", 0) || num(props, "IOSurfaceIsDisplayable", 0)) s->st.flags |= 4;

	// planes: per-plane properties, defaults laid out one after another
	CFArrayRef pi = CFDictionaryGetValue(props, CFSTR("IOSurfacePlaneInfo"));
	uint32_t np = 0, next = offset;
	if (pi && CFGetTypeID(pi) == CFArrayGetTypeID()) {
		np = (uint32_t)CFArrayGetCount(pi);
		if (np > MAXPLANES) np = MAXPLANES;
		for (uint32_t i = 0; i < np; i++) {
			CFDictionaryRef p = CFArrayGetValueAtIndex(pi, i);
			if (!p || CFGetTypeID(p) != CFDictionaryGetTypeID()) { free(s); return kIOReturnBadArgument; }
			PlaneState* ps = &s->planes[i];
			ps->index = (uint16_t)i;
			ps->width = (uint32_t)num(p, "IOSurfacePlaneWidth", W);
			ps->height = (uint32_t)num(p, "IOSurfacePlaneHeight", H);
			ps->bytesPerElement = (uint16_t)num(p, "IOSurfacePlaneBytesPerElement", 1);
			ps->elementWidth = (uint8_t)num(p, "IOSurfacePlaneElementWidth", 1);
			ps->elementHeight = (uint8_t)num(p, "IOSurfacePlaneElementHeight", 1);
			if (!ps->bytesPerElement) ps->bytesPerElement = 1;
			if (!ps->elementWidth) ps->elementWidth = 1;
			if (!ps->elementHeight) ps->elementHeight = 1;
			ps->bytesPerRow = has(p, "IOSurfacePlaneBytesPerRow") ? (uint32_t)num(p, "IOSurfacePlaneBytesPerRow", 0)
				: align64((uint64_t)((ps->width + ps->elementWidth - 1) / ps->elementWidth) * ps->bytesPerElement);
			ps->offset = has(p, "IOSurfacePlaneOffset") ? (uint32_t)num(p, "IOSurfacePlaneOffset", 0) : align64(next);
			ps->size = has(p, "IOSurfacePlaneSize") ? (uint32_t)num(p, "IOSurfacePlaneSize", 0)
				: align64((uint64_t)((ps->height + ps->elementHeight - 1) / ps->elementHeight) * ps->bytesPerRow);
			next = ps->offset + ps->size;
		}
	}
	s->st.planeCount = np;
	uint64_t alloc = has(props, "IOSurfaceAllocSize") ? num(props, "IOSurfaceAllocSize", 0)
		: np ? align64(next) : align64((uint64_t)((H + eh - 1) / eh) * bpr + offset);
	if (!np && H && alloc < offset + (uint64_t)((H + eh - 1) / eh - 1) * bpr + ((W + ew - 1) / ew) * bpe) {
		free(s);
		return kIOReturnBadArgument;
	}
	if (!alloc) alloc = 1;  // zero-size surfaces exist (e.g. values-only); give them a page
	s->st.allocSize = (uint32_t)alloc;
	size_t pg = (size_t)getpagesize();
	s->mapsize = (alloc + pg - 1) & ~(pg - 1);
	if (clientShmem) {
		void* m = NULL;
		size_t sz = xpc_shmem_map(clientShmem, &m);
		if (!sz || sz < alloc) { if (m) munmap(m, sz); free(s); return kIOReturnNoMemory; }
		s->mem = m; s->mapsize = sz; s->clientMem = true;
	} else {
		s->mem = mmap(NULL, s->mapsize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
		if (s->mem == MAP_FAILED) { free(s); return kIOReturnNoMemory; }
	}
	s->values = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	// the kernel's IOSurface keeps the dictionary it was created with as a value (Metal's MTLSharedTextureHandle reads
	// kMetalRegistryID from it to find the texture's device)
	CFDictionarySetValue(s->values, CFSTR("CreationProperties"), props);
	s->id = gNextID++;
	if (gNextID == 0) gNextID = 1;
	s->st.id = s->id;
	gByID[@(s->id)] = [NSValue valueWithPointer:s];
	*out = s;
	LOG("create %u: %ux%u '%.4s' bpe %u bpr %u alloc %u planes %u%s\n", s->id, W, H, (char*)&s->st.pixelFormat,
	    bpe, bpr, s->st.allocSize, np, clientShmem ? " (client memory)" : "");
	return 0;
}

static void putState(xpc_object_t reply, Surf* s) {
	xpc_dictionary_set_data(reply, "SurfaceState", &s->st, sizeof s->st);
}

static PlaneState planeFor(Surf* s, uint32_t i) {
	if (s->st.planeCount) return s->planes[i];
	PlaneState p = {0};
	p.width = s->st.width; p.height = s->st.height; p.offset = s->st.offset; p.bytesPerRow = s->st.bytesPerRow;
	p.size = s->st.allocSize - s->st.offset; p.bytesPerElement = (uint16_t)s->st.bytesPerElement;
	p.elementWidth = (uint8_t)s->st.elementWidth; p.elementHeight = (uint8_t)s->st.elementHeight;
	return p;
}

static xpc_object_t serialize(CFTypeRef obj) {
	CFDataRef d = IOCFSerialize(obj, 1);
	if (!d) return NULL;
	xpc_object_t x = xpc_data_create(CFDataGetBytePtr(d), (size_t)CFDataGetLength(d));
	CFRelease(d);
	return x;
}
static CFTypeRef deserialize(xpc_object_t msg, const char* key) {
	size_t len = 0;
	const void* p = xpc_dictionary_get_data(msg, key, &len);
	if (!p) return NULL;
	return IOCFUnserializeBinary(p, len, NULL, 0, NULL);
}

static const char* const kBulkKeys[] = { "CleanAperture", "PixelAspectRatio", "MasteringDisplayColorVolume", "GammaLevel",
	"EDRFactor", "ContentLightLevelInfo", "FieldCount", "FieldDetail", "YCbCrMatrixIndex", "ColorPrimariesIndex",
	"TransferFunctionIndex", "ChromaLocationTopField", "ChromaLocationBottomField", "ChromaSubsampling",
	"PremultipliedAlpha", NULL };

// per connection: id -> number of references this peer holds
typedef NSMutableDictionary<NSNumber*, NSNumber*> Refs;

static void addRef(Refs* refs, Surf* s) {
	refs[@(s->id)] = @([refs[@(s->id)] intValue] + 1);
	s->refs++;
}
static bool dropRef(Refs* refs, uint32_t sid) {
	int n = [refs[@(sid)] intValue];
	Surf* s = surfFor(sid);
	if (n <= 0 || !s) return false;
	if (n == 1) [refs removeObjectForKey:@(sid)]; else refs[@(sid)] = @(n - 1);
	if (--s->refs <= 0) surfFree(s);
	return true;
}

static void handle(xpc_connection_t peer, Refs* refs, xpc_object_t msg) {
	xpc_object_t reply = xpc_dictionary_create_reply(msg);
	if (!reply) return;
	uint64_t method = xpc_dictionary_get_uint64(msg, "Method");
	uint32_t sid = (uint32_t)xpc_dictionary_get_uint64(msg, "SurfaceID");
	uint32_t kr = 0;
	Surf* s = NULL;
	if (method >= 4 && method <= 26) {
		s = surfFor(sid);
		if (!s) kr = kIOReturnNotFound;
	}
	if (!kr) switch (method) {
	case 0: {  // Initialize
		Limits l = { 1, 63, 63, 0x7fffffff, 0x7fffffff, 0x7fffffff, 0, 1 };
		xpc_dictionary_set_data(reply, "Limits", &l, sizeof l);
		xpc_dictionary_set_uint64(reply, "ProtocolVersion", 1);
		LOG("peer %p connected\n", (void*)peer);
		break;
	}
	case 1: {  // GetDebugInfo
		xpc_object_t ids = xpc_array_create(NULL, 0), rc = xpc_array_create(NULL, 0);
		for (NSNumber* k in gByID) {
			xpc_array_set_uint64(ids, XPC_ARRAY_APPEND, k.unsignedIntValue);
			xpc_array_set_uint64(rc, XPC_ARRAY_APPEND, (uint64_t)surfFor(k.unsignedIntValue)->refs);
		}
		xpc_dictionary_set_value(reply, "DebugSurfaceIDList", ids);
		xpc_dictionary_set_value(reply, "DebugSurfaceRefCount", rc);
		xpc_release(ids); xpc_release(rc);
		break;
	}
	case 2: {  // Create / Lookup
		if (xpc_dictionary_get_value(msg, "PropertiesDictionary")) {
			CFTypeRef props = deserialize(msg, "PropertiesDictionary");
			if (!props || CFGetTypeID(props) != CFDictionaryGetTypeID()) { kr = kIOReturnBadArgument; if (props) CFRelease(props); break; }
			xpc_object_t cs = xpc_dictionary_get_value(msg, "ClientProvidedShmem");
			kr = surfCreate(props, cs, &s);
			if (!kr) LOG("created %u by pid %d\n", s->id, x86_xpc_connection_get_pid(peer));
			CFRelease(props);
		} else if (xpc_dictionary_get_value(msg, "LookupID")) {
			s = surfFor((uint32_t)xpc_dictionary_get_uint64(msg, "LookupID"));
			if (!s) kr = kIOReturnNotFound;
			LOG("lookup id %llu -> %s\n", xpc_dictionary_get_uint64(msg, "LookupID"), s ? "found" : "not found");
		} else {
			mach_port_t p = xpc_dictionary_copy_mach_send(msg, "MachPort");
			NSNumber* id_ = MACH_PORT_VALID(p) ? gByPort[@(p)] : nil;
			s = id_ ? surfFor(id_.unsignedIntValue) : NULL;
			if (!s) kr = kIOReturnNotFound;
			LOG("lookup port %#x -> %u\n", p, s ? s->id : 0);
			if (MACH_PORT_VALID(p)) mach_port_deallocate(mach_task_self(), p);
		}
		if (!kr && s) {
			xpc_object_t shm = xpc_shmem_create(s->mem, s->mapsize);
			if (!shm) { kr = kIOReturnNoMemory; if (s->refs == 0) surfFree(s); s = NULL; break; }
			xpc_dictionary_set_value(reply, "MemoryObject", shm);
			xpc_release(shm);
			addRef(refs, s);
			putState(reply, s);
		}
		s = NULL;  // state already added (or not, on error)
		break;
	}
	case 3:  // Release
		if (!dropRef(refs, sid)) kr = kIOReturnNotFound;
		break;
	case 4:  // Lock
		break;
	case 5:  // Unlock
		if (!(xpc_dictionary_get_uint64(msg, "Options") & 1)) s->st.seed++;
		break;
	case 6: {  // GetPlaneState
		uint64_t i = xpc_dictionary_get_uint64(msg, "PlaneIndex");
		if (i >= MAXPLANES || (s->st.planeCount ? i >= s->st.planeCount : i != 0)) { kr = kIOReturnBadArgument; break; }
		PlaneState p = planeFor(s, (uint32_t)i);
		xpc_dictionary_set_data(reply, "PlaneState", &p, sizeof p);
		break;
	}
	case 7: break;  // BindAccel
	case 8: xpc_dictionary_set_bool(reply, "NeedsBindAccelerator", false); break;
	case 9: {  // SetValue
		CFTypeRef d = deserialize(msg, "PropertiesDictionary");
		if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) { kr = kIOReturnBadArgument; if (d) CFRelease(d); break; }
		// the client sends {"key": k, "value": v} (IOSurfaceSetValue) or {"isSetValues": true, "value": dict}
		// (IOSurfaceSetValues: merge)
		CFTypeRef k = CFDictionaryGetValue(d, CFSTR("key")), v = CFDictionaryGetValue(d, CFSTR("value"));
		if (k && v) CFDictionarySetValue(s->values, k, v);
		else if (v && CFGetTypeID(v) == CFDictionaryGetTypeID()) {
			CFIndex n = CFDictionaryGetCount(v);
			const void** ks = malloc(sizeof(void*) * (size_t)n * 2 + 1);
			CFDictionaryGetKeysAndValues(v, ks, ks + n);
			for (CFIndex i = 0; i < n; i++) CFDictionarySetValue(s->values, ks[i], ks[n + i]);
			free(ks);
		} else kr = kIOReturnBadArgument;
		CFRelease(d);
		break;
	}
	case 10: {  // CopyAllValues
		xpc_object_t x = serialize(s->values);
		if (x) { xpc_dictionary_set_value(reply, "PropertiesDictionary", x); xpc_release(x); }
		break;
	}
	case 11: {  // RemoveValue
		const char* k = xpc_dictionary_get_string(msg, "PropertyKey");
		if (k) {
			CFStringRef ks = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
			CFDictionaryRemoveValue(s->values, ks);
			CFRelease(ks);
		}
		break;
	}
	case 12: CFDictionaryRemoveAllValues(s->values); break;
	case 13:  // SetPurgeable: always non-volatile
		LOG("purgeable %u pid %d new %llu size %u refs %d %ux%u\n", s->id, x86_xpc_connection_get_pid(peer),
		    xpc_dictionary_get_uint64(msg, "NewState"), s->st.allocSize, s->refs, s->st.width, s->st.height);
		xpc_dictionary_set_uint64(reply, "OldState", 0); break;
	case 14: {  // CreateMachPort
		if (!s->port) {
			mach_port_t p = MACH_PORT_NULL;
			if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p) != KERN_SUCCESS) { kr = kIOReturnNoMemory; break; }
			s->port = p;
			gByPort[@(p)] = @(s->id);
		}
		// xpc_dictionary_set_mach_send copies a send right from our receive right
		mach_port_insert_right(mach_task_self(), s->port, s->port, MACH_MSG_TYPE_MAKE_SEND);
		xpc_dictionary_set_mach_send(reply, "MachPort", s->port);
		mach_port_deallocate(mach_task_self(), s->port);
		LOG("surface %u -> port %#x\n", s->id, s->port);
		break;
	}
	case 15: s->useCount++; break;
	case 16: if (s->useCount > 0) s->useCount--; break;
	case 17: xpc_dictionary_set_bool(reply, "IsInUse", s->useCount > 0); break;
	case 18: {  // CopyDataValueBytes
		const char* k = xpc_dictionary_get_string(msg, "PropertyKey");
		uint64_t cap = xpc_dictionary_get_uint64(msg, "BufferSize");
		CFStringRef ks = k ? CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8) : NULL;
		CFTypeRef v = ks ? CFDictionaryGetValue(s->values, ks) : NULL;
		if (ks) CFRelease(ks);
		if (!v || CFGetTypeID(v) != CFDataGetTypeID()) { kr = kIOReturnNotFound; break; }
		uint64_t len = (uint64_t)CFDataGetLength(v);
		xpc_dictionary_set_uint64(reply, "BufferSize", len);
		if (len > cap) { kr = kIOReturnNoSpace; break; }
		xpc_dictionary_set_data(reply, "Buffer", CFDataGetBytePtr(v), len);
		break;
	}
	case 19: break;  // SignalEvent: no GPU events behind surfaces here
	case 20: {  // SetBulkAttachments
		if (!s->bulk) s->bulk = xpc_dictionary_create(NULL, NULL, 0);
		for (int i = 0; kBulkKeys[i]; i++) {
			xpc_object_t v = xpc_dictionary_get_value(msg, kBulkKeys[i]);
			if (v) xpc_dictionary_set_value(s->bulk, kBulkKeys[i], v);
		}
		break;
	}
	case 21:
		if (s->bulk) for (int i = 0; kBulkKeys[i]; i++) {
			xpc_object_t v = xpc_dictionary_get_value(s->bulk, kBulkKeys[i]);
			if (v) xpc_dictionary_set_value(reply, kBulkKeys[i], v);
		}
		break;
	case 22: case 23: case 24: case 25: {
		uint64_t c = xpc_dictionary_get_uint64(msg, "Category");
		if (c >= 16) { kr = kIOReturnBadArgument; break; }
		if (method == 22) { s->catUse[c]++; s->useCount++; }
		else if (method == 23) { if (s->catUse[c] > 0) { s->catUse[c]--; s->useCount--; } }
		else if (method == 24) xpc_dictionary_set_bool(reply, "IsInUse", s->catUse[c] > 0);
		else xpc_dictionary_set_bool(reply, "IsInUse", s->useCount - s->catUse[c] > 0);
		break;
	}
	case 26: xpc_dictionary_set_uint64(reply, "YCbCrMatrixIndex", s->yuvMatrix); break;
	default:
		kr = kIOReturnUnsupported;
	}
	if (s && method >= 4) putState(reply, s);
	if (method != 4 && method != 5 && method != 6) LOG("method %llu surface %u -> %#x\n", method, sid, kr);
	xpc_dictionary_set_uint64(reply, "ErrorCode", kr);
	xpc_connection_send_message(peer, reply);
	xpc_release(reply);
}

int main(int argc, char** argv) {
	(void)argc; (void)argv;
	setvbuf(stderr, NULL, _IOLBF, 0);
	gLog = getenv("X86SIM_IOSURFACE_LOG") != NULL;
	gByID = [NSMutableDictionary new];
	gByPort = [NSMutableDictionary new];
	// all state lives on the main queue: one serial queue for every peer
	dispatch_queue_t q = dispatch_get_main_queue();
	xpc_connection_t l = x86_xpc_connection_create_mach_service("com.apple.IOSurface.Remote", q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
	if (!l) { fprintf(stderr, "iosurfaced: cannot listen\n"); return 1; }
	xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		Refs* refs = [Refs new];
		xpc_connection_set_target_queue(peer, q);
		xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
			if (xpc_get_type(m) == XPC_TYPE_DICTIONARY) { @autoreleasepool { handle(peer, refs, m); } return; }
			if (m == XPC_ERROR_CONNECTION_INVALID) {
				// the peer is gone: drop its references
				int n = 0;
				for (NSNumber* k in refs.allKeys) {
					int c = [refs[k] intValue];
					for (int i = 0; i < c; i++) dropRef(refs, k.unsignedIntValue);
					n += c;
				}
				LOG("peer gone, %d references released, %lu surfaces left\n", n, (unsigned long)gByID.count);
			}
		});
		[refs retain];
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(l);
	fprintf(stderr, "iosurfaced: serving com.apple.IOSurface.Remote\n");
	// x86Sim: CFRunLoopRun keeps the main thread draining the main queue. dispatch_main's
	// pthread_exit parks the A64 JIT main thread so XPC peer handlers never run (backboardd
	// hangs after "simfb: swapchain" waiting for Initialize). Same fix as metalhostd.
	fprintf(stderr, "iosurfaced: CFRunLoopRun\n");
	CFRunLoopRun();
	return 0;
}
