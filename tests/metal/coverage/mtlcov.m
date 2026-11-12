// x86Sim MetalCoverage: registry, runner, watchdog and helpers (mtlcov.h).
// Runner output on stderr, one line each, flushed (run.sh parses it):
//   MTLCOV BEGIN <i> <area>/<name>
//   MTLCOV RESULT <i> <area>/<name> PASS|FAIL|SKIP|CLIENT <ms> claimed=<0|1> <detail>
//   MTLCOV HANG <i> <area>/<name>        (watchdog: the test ran past MTLCOV_TIMEOUT s; the process exits 3)
//   MTLCOV COVERS <area>/<name> <Owner selector>;...
//   MTLCOV DONE <passed> <failed> <skipped>
// Env: MTLCOV_FROM=<i> first test index, MTLCOV_ONLY=<substring> run matching tests, MTLCOV_TIMEOUT=<s> (default 20),
// MTLCOV_EXIT=1 exit when done (run.sh); results also go to Documents/mtlcov-results.json.
#import "mtlcov.h"
#include <stdatomic.h>
#include <unistd.h>

typedef struct { const char *area, *name, *covers; MCTestFn fn; } MCTest;
static MCTest g_tests[1024];
static int g_ntests;
static BOOL g_claimed;
static NSString* g_claim_what;

void mc_register(const char* area, const char* name, const char* covers, MCTestFn fn) {
	if (g_ntests < 1024) g_tests[g_ntests++] = (MCTest){ area, name, covers, fn };
}
void mc_claim(BOOL claimed, const char* what) { g_claimed = claimed; g_claim_what = @(what); }

static void out(NSString* s) { fprintf(stderr, "MTLCOV %s\n", s.UTF8String); fflush(stderr); }

static int cmp_tests(const void* a, const void* b) {
	const MCTest *x = a, *y = b;
	int c = strcmp(x->area, y->area);
	return c ? c : strcmp(x->name, y->name);
}

static _Atomic(double) g_deadline;  // CFAbsoluteTime the running test must finish by (0: none)
static _Atomic(int) g_running = -1;

int mc_test_count(void) { return g_ntests; }

void mc_run_all(void (^progress)(int i, int n, NSString* name, MCStatus st, NSString* detail)) {
	qsort(g_tests, g_ntests, sizeof(MCTest), cmp_tests);
	const char* from = getenv("MTLCOV_FROM");
	const char* only = getenv("MTLCOV_ONLY");
	double timeout = getenv("MTLCOV_TIMEOUT") ? atof(getenv("MTLCOV_TIMEOUT")) : 20;
	// watchdog: a hung test ends the process (the runner goes on with the next one)
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[NSThread detachNewThreadWithBlock:^{
			for (;;) {
				usleep(250000);
				double d = atomic_load(&g_deadline);
				int i = atomic_load(&g_running);
				if (d > 0 && i >= 0 && CFAbsoluteTimeGetCurrent() > d) {
					out([NSString stringWithFormat:@"HANG %d %s/%s", i, g_tests[i].area, g_tests[i].name]);
					_exit(3);
				}
			}
		}];
	});
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	out([NSString stringWithFormat:@"DEVICE %@ tests %d", dev.name, g_ntests]);
	NSMutableArray* results = [NSMutableArray array];
	int pass = 0, fail = 0, skip = 0;
	for (int i = from ? atoi(from) : 0; i < g_ntests; i++) {
		MCTest* t = &g_tests[i];
		NSString* name = [NSString stringWithFormat:@"%s/%s", t->area, t->name];
		if (only && ![name containsString:@(only)]) continue;
		out([NSString stringWithFormat:@"BEGIN %d %@", i, name]);
		out([NSString stringWithFormat:@"COVERS %@ %s", name, t->covers]);
		g_claimed = YES; g_claim_what = nil;
		NSMutableString* detail = [NSMutableString string];
		atomic_store(&g_running, i);
		atomic_store(&g_deadline, CFAbsoluteTimeGetCurrent() + timeout);
		CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
		MCStatus st;
		@autoreleasepool {
			@try { st = t->fn(dev, detail); }
			@catch (NSException* e) { st = MC_FAIL; [detail appendFormat:@"exception %@: %@", e.name, e.reason]; }
		}
		atomic_store(&g_deadline, 0);
		int ms = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000);
		if (!g_claimed && g_claim_what) [detail appendFormat:@"%s(not claimed: %@)", detail.length ? " " : "", g_claim_what];
		NSString* d1 = [[detail stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] copy];
		const char* sn = st == MC_PASS ? "PASS" : st == MC_FAIL ? "FAIL" : st == MC_CLIENT ? "CLIENT" : "SKIP";
		out([NSString stringWithFormat:@"RESULT %d %@ %s %d claimed=%d %@", i, name, sn, ms, g_claimed, d1]);
		if (st == MC_PASS) pass++; else if (st == MC_FAIL) fail++; else skip++;
		[results addObject:@{ @"test": name, @"status": @(sn), @"ms": @(ms), @"claimed": @(g_claimed), @"detail": d1 }];
		if (progress) progress(i, g_ntests, name, st, d1);
	}
	out([NSString stringWithFormat:@"DONE %d %d %d", pass, fail, skip]);
	NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	[[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil]
		writeToFile:[docs stringByAppendingPathComponent:@"mtlcov-results.json"] atomically:YES];
	if (getenv("MTLCOV_EXIT")) exit(0);
}

// ---- helpers ----

static NSMutableDictionary* g_libs;
id<MTLLibrary> mc_lib(id<MTLDevice> dev, NSString* src, NSError** err) {
	if (!g_libs) g_libs = [NSMutableDictionary dictionary];
	id<MTLLibrary> l = g_libs[src];
	if (l) return l;
	MTLCompileOptions* o = [MTLCompileOptions new];
	l = [dev newLibraryWithSource:src options:o error:err];
	if (l) g_libs[src] = l;
	return l;
}
id<MTLComputePipelineState> mc_cps(id<MTLDevice> dev, NSString* src, NSString* fn, NSError** err) {
	id<MTLLibrary> l = mc_lib(dev, src, err);
	id<MTLFunction> f = [l newFunctionWithName:fn];
	if (!f) return nil;
	return [dev newComputePipelineStateWithFunction:f error:err];
}
id<MTLCommandQueue> mc_queue(id<MTLDevice> dev) {
	static id<MTLCommandQueue> q;
	if (!q) q = [dev newCommandQueue];
	return q;
}
NSString* mc_run(id<MTLCommandBuffer> cb) {
	dispatch_semaphore_t s = dispatch_semaphore_create(0);
	[cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_semaphore_signal(s); }];
	[cb commit];
	if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)))
		return [NSString stringWithFormat:@"command buffer did not complete in 10 s (status %ld)", (long)cb.status];
	if (cb.status != MTLCommandBufferStatusCompleted || cb.error)
		return [NSString stringWithFormat:@"command buffer status %ld error %@", (long)cb.status, cb.error];
	return nil;
}
id<MTLBuffer> mc_buf(id<MTLDevice> dev, NSUInteger len) {
	id<MTLBuffer> b = [dev newBufferWithLength:len options:MTLResourceStorageModeShared];
	memset(b.contents, 0, len);
	return b;
}
id<MTLTexture> mc_tex(id<MTLDevice> dev, MTLPixelFormat f, NSUInteger w, NSUInteger h, MTLTextureUsage u) {
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	d.usage = u;
	return [dev newTextureWithDescriptor:d];
}
id<MTLRenderPipelineState> mc_rps(id<MTLDevice> dev, NSString* src, NSString* vs, NSString* fs, MTLPixelFormat f, NSError** err) {
	id<MTLLibrary> l = mc_lib(dev, src, err);
	if (!l) return nil;
	MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:vs];
	if (fs) d.fragmentFunction = [l newFunctionWithName:fs];
	d.colorAttachments[0].pixelFormat = f;
	return [dev newRenderPipelineStateWithDescriptor:d error:err];
}
uint32_t mc_texel_rgba8(id<MTLTexture> t, NSUInteger x, NSUInteger y) {
	uint32_t v = 0;
	[t getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
	return v;
}
NSUInteger mc_count_wrong_rgba8(id<MTLTexture> t, uint32_t want, int tol) {
	NSUInteger w = t.width, h = t.height, wrong = 0;
	uint32_t* px = malloc(w * h * 4);
	[t getBytes:px bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
	for (NSUInteger i = 0; i < w * h; i++)
		for (int c = 0; c < 4; c++)
			if (abs((int)((px[i] >> (c * 8)) & 0xff) - (int)((want >> (c * 8)) & 0xff)) > tol) { wrong++; break; }
	free(px);
	return wrong;
}
