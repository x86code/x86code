// x86Sim MetalCoverage: command buffer life cycle, handlers, errors, events, shared events, fences.
#import "mtlcov.h"

static NSString* const SRC = MC_MSL
	"kernel void inc(device uint* x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] += 1; }\n"
	"kernel void spin(device uint* x [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
	"  uint v = x[i]; for (uint k = 0; k < 200000; k++) v = v * 1664525u + 1013904223u; x[i] = v; }\n"
	"kernel void oob(device uint* x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i * 1000000000u] = 1; }\n";

static void inc_dispatch(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> p, id<MTLBuffer> b) {
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p]; [ce setBuffer:b offset:0 atIndex:0];
	[ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[ce endEncoding];
}

MC_TEST(sync, handlers_and_status, "MTLCommandBuffer addScheduledHandler:;MTLCommandBuffer addCompletedHandler:;MTLCommandBuffer status;"
        "MTLCommandBuffer enqueue;MTLCommandBuffer waitUntilScheduled;MTLCommandBuffer GPUStartTime;MTLCommandBuffer GPUEndTime;"
        "MTLCommandBuffer kernelStartTime;MTLCommandBuffer kernelEndTime;MTLCommandBuffer label;MTLCommandBuffer commandQueue;"
        "MTLCommandBuffer retainedReferences;MTLCommandBuffer error") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"inc", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> b = mc_buf(dev, 256);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	cb.label = @"cb";
	MC_CHECK(cb.status == MTLCommandBufferStatusNotEnqueued && cb.commandQueue == mc_queue(dev) && cb.retainedReferences, @"fresh state");
	__block int order = 0, sched = 0, done = 0;
	[cb addScheduledHandler:^(id<MTLCommandBuffer> c) { (void)c; sched = ++order; }];
	[cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; done = ++order; }];
	inc_dispatch(cb, p, b);
	[cb enqueue];
	MC_CHECK(cb.status == MTLCommandBufferStatusEnqueued, @"after enqueue %ld", (long)cb.status);
	[cb commit];
	[cb waitUntilScheduled];
	[cb waitUntilCompleted];
	for (int i = 0; i < 100 && !done; i++) usleep(10000);
	MC_CHECK(sched == 1 && done == 2, @"handlers: scheduled #%d completed #%d", sched, done);
	MC_CHECK(cb.status == MTLCommandBufferStatusCompleted && !cb.error, @"status %ld error %@", (long)cb.status, cb.error);
	MC_CHECK(cb.GPUEndTime >= cb.GPUStartTime && cb.GPUStartTime > 0, @"GPU times %f %f", cb.GPUStartTime, cb.GPUEndTime);
	MC_CHECK(((uint32_t*)b.contents)[63] == 1, @"work not done");
	return MC_PASS;
}

MC_TEST(sync, in_order_execution, "MTLCommandBuffer commit") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"inc", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> b = mc_buf(dev, 256);
	id<MTLCommandBuffer> last = nil;
	for (int i = 0; i < 200; i++) { last = [mc_queue(dev) commandBuffer]; inc_dispatch(last, p, b); [last commit]; }
	[last waitUntilCompleted];
	MC_CHECK(((uint32_t*)b.contents)[0] == 200, @"%u of 200 increments (a lost write = out of order)", ((uint32_t*)b.contents)[0]);
	return MC_PASS;
}

// a kernel that faults: the command buffer reports an error, the queue keeps working
MC_TEST(sync, gpu_fault_reported, "MTLCommandBuffer error;MTLCommandBuffer status") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"oob", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> b = mc_buf(dev, 256);
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	inc_dispatch(cb, p, b);
	[cb commit]; [cb waitUntilCompleted];
	[detail appendFormat:@"status %ld error %@ ", (long)cb.status, cb.error.localizedDescription];
	id<MTLComputePipelineState> pi = mc_cps(dev, SRC, @"inc", &err);
	id<MTLCommandBuffer> cb2 = [mc_queue(dev) commandBuffer];
	inc_dispatch(cb2, pi, b);
	NSString* e = mc_run(cb2);
	MC_CHECK(!e, @"the queue did not recover: %@", e);
	return MC_PASS;  // whether an out-of-bounds write is reported is the GPU's (Apple's often is not): informational
}

// MoltenVK's semaphore pattern on one queue: signal A=n; wait A>=n + work + signal R=m; wait R>=m + signal A=n (again).
// shared: the same with MTLSharedEvents, whose values a stall's diagnosis can read.
static MCStatus event_chain(id<MTLDevice> dev, NSMutableString* detail, BOOL shared) {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"inc", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> b = mc_buf(dev, 256);
	id<MTLEvent> A[3], R[2];
	for (int i = 0; i < 3; i++) A[i] = shared ? [dev newSharedEvent] : [dev newEvent];
	for (int i = 0; i < 2; i++) R[i] = shared ? [dev newSharedEvent] : [dev newEvent];
	uint64_t a[3] = { 0 }, r[2] = { 0 };
	NSMutableArray* subs = [NSMutableArray array];
	int frames = 600;
	for (int f = 0; f < frames; f++) {
		int ai = f % 3, ri = f % 2;
		uint64_t n = ++a[ai], m = ++r[ri];
		id<MTLCommandBuffer> c1 = [mc_queue(dev) commandBuffer]; [c1 encodeSignalEvent:A[ai] value:n]; [c1 commit];
		id<MTLCommandBuffer> c2 = [mc_queue(dev) commandBuffer]; [c2 encodeWaitForEvent:A[ai] value:n];
		inc_dispatch(c2, p, b); [c2 encodeSignalEvent:R[ri] value:m]; [c2 commit];
		id<MTLCommandBuffer> c3 = [mc_queue(dev) commandBuffer]; [c3 encodeWaitForEvent:R[ri] value:m];
		[c3 encodeSignalEvent:A[ai] value:n]; [c3 commit];
		[subs addObject:c2];
		if (subs.count > 2) {
			id<MTLCommandBuffer> old = subs[0];
			[subs removeObjectAtIndex:0];
			CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
			while (old.status < MTLCommandBufferStatusCompleted && CFAbsoluteTimeGetCurrent() - t0 < 5) usleep(500);
			if (old.status != MTLCommandBufferStatusCompleted) {
				// diagnosis: an unrelated commit on another queue makes the device's scheduler look again (a lost
				// wake-up then completes it); with shared events, reading every value makes the device observe what
				// the GPU reached (a signal that landed unobserved then completes it)
				id<MTLCommandBuffer> poke = [[dev newCommandQueue] commandBuffer];
				[poke commit]; [poke waitUntilCompleted];
				CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
				while (old.status < MTLCommandBufferStatusCompleted && CFAbsoluteTimeGetCurrent() - t1 < 2) usleep(500);
				NSString* poked = old.status == MTLCommandBufferStatusCompleted ? @"completed (a lost wake-up)" : @"still did not";
				NSMutableString* read = [NSMutableString string];
				if (shared && old.status != MTLCommandBufferStatusCompleted) {
					for (int i = 0; i < 3; i++) [read appendFormat:@"A%d=%llu/%llu ", i, ((id<MTLSharedEvent>)A[i]).signaledValue, a[i]];
					for (int i = 0; i < 2; i++) [read appendFormat:@"R%d=%llu/%llu ", i, ((id<MTLSharedEvent>)R[i]).signaledValue, r[i]];
					CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
					while (old.status < MTLCommandBufferStatusCompleted && CFAbsoluteTimeGetCurrent() - t2 < 2) usleep(500);
					[read appendFormat:@"; after reading the values it %@", old.status == MTLCommandBufferStatusCompleted ?
						@"completed (the GPU's signal had landed unobserved)" : @"still did not"];
				}
				MC_FAILF(@"frame %d: the submit of frame %d did not complete in 5 s (status %ld); after a commit on another queue it %@. %@",
					f, f - 2, (long)old.status, poked, read);
			}
		}
	}
	for (id<MTLCommandBuffer> c in subs) [c waitUntilCompleted];
	MC_CHECK(((uint32_t*)b.contents)[0] == (uint32_t)frames, @"%u of %d increments", ((uint32_t*)b.contents)[0], frames);
	return MC_PASS;
}
MC_TEST(sync, event_chain_moltenvk, "MTLDevice newEvent;MTLCommandBuffer encodeSignalEvent:value:;MTLCommandBuffer encodeWaitForEvent:value:") {
	return event_chain(dev, detail, NO);
}
MC_TEST(sync, event_chain_shared, "MTLDevice newSharedEvent;MTLCommandBuffer encodeSignalEvent:value:;MTLCommandBuffer encodeWaitForEvent:value:") {
	return event_chain(dev, detail, YES);
}

// wait first, signal later from another queue
MC_TEST(sync, event_cross_queue, "MTLCommandBuffer encodeWaitForEvent:value:;MTLCommandBuffer encodeSignalEvent:value:") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"inc", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> b = mc_buf(dev, 256);
	id<MTLCommandQueue> q2 = [dev newCommandQueue];
	id<MTLEvent> e = [dev newEvent];
	id<MTLCommandBuffer> w = [mc_queue(dev) commandBuffer];
	[w encodeWaitForEvent:e value:1];
	inc_dispatch(w, p, b);
	[w commit];
	usleep(100000);
	MC_CHECK(w.status < MTLCommandBufferStatusCompleted, @"ran before its event was signalled");
	id<MTLCommandBuffer> s = [q2 commandBuffer];
	inc_dispatch(s, p, b);
	[s encodeSignalEvent:e value:1];
	[s commit];
	NSString* er = nil;
	[w waitUntilCompleted];
	if (w.status != MTLCommandBufferStatusCompleted) er = [NSString stringWithFormat:@"status %ld", (long)w.status];
	MC_CHECK(!er, @"%@", er);
	MC_CHECK(((uint32_t*)b.contents)[0] == 2, @"%u increments", ((uint32_t*)b.contents)[0]);
	return MC_PASS;
}

MC_TEST(sync, shared_event_cpu, "MTLDevice newSharedEvent;MTLSharedEvent signaledValue;MTLSharedEvent setSignaledValue:;"
        "MTLSharedEvent notifyListener:atValue:block:;MTLSharedEvent waitUntilSignaledValue:timeoutMS:;MTLSharedEvent newSharedEventHandle") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"inc", &err);
	MC_NOTNIL(p, err);
	id<MTLBuffer> b = mc_buf(dev, 256);
	id<MTLSharedEvent> e = [dev newSharedEvent];
	MTLSharedEventListener* l = [[MTLSharedEventListener alloc] initWithDispatchQueue:dispatch_queue_create("l", 0)];
	__block uint64_t heard = 0;
	[e notifyListener:l atValue:3 block:^(id<MTLSharedEvent> ev, uint64_t v) { (void)ev; heard = v; }];
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	[cb encodeWaitForEvent:e value:2];        // released by the CPU
	inc_dispatch(cb, p, b);
	[cb encodeSignalEvent:e value:3];         // then the GPU
	[cb commit];
	usleep(50000);
	MC_CHECK(cb.status < MTLCommandBufferStatusCompleted, @"ran before the CPU set the value");
	e.signaledValue = 2;
	MC_CHECK([e waitUntilSignaledValue:3 timeoutMS:5000], @"value %llu: the GPU signal never landed", e.signaledValue);
	for (int i = 0; i < 200 && heard != 3; i++) usleep(10000);
	MC_CHECK(heard == 3, @"listener heard %llu", heard);
	MC_CHECK([e newSharedEventHandle] != nil, @"no shared handle");
	return MC_PASS;
}

MC_TEST(sync, fences_between_encoders, "MTLDevice newFence;MTLComputeCommandEncoder updateFence:;MTLComputeCommandEncoder waitForFence:;"
        "MTLRenderCommandEncoder updateFence:afterStages:;MTLRenderCommandEncoder waitForFence:beforeStages:") {
	NSError* err = nil;
	id<MTLComputePipelineState> p = mc_cps(dev, SRC, @"spin", &err), pi = mc_cps(dev, SRC, @"inc", &err);
	MC_NOTNIL(p, err);
	// untracked buffer: only the fence orders the second encoder after the first
	id<MTLBuffer> b = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
	memset(b.contents, 0, 256);
	id<MTLFence> f = [dev newFence];
	id<MTLCommandBuffer> cb = [mc_queue(dev) commandBuffer];
	id<MTLComputeCommandEncoder> c1 = [cb computeCommandEncoder];
	[c1 setComputePipelineState:p]; [c1 setBuffer:b offset:0 atIndex:0];
	[c1 dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[c1 updateFence:f];
	[c1 endEncoding];
	id<MTLComputeCommandEncoder> c2 = [cb computeCommandEncoder];
	[c2 waitForFence:f];
	[c2 setComputePipelineState:pi]; [c2 setBuffer:b offset:0 atIndex:0];
	[c2 dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[c2 endEncoding];
	NSString* e = mc_run(cb);
	MC_CHECK(!e, @"%@", e);
	uint32_t v = 0;
	for (uint32_t k = 0; k < 200000; k++) v = v * 1664525u + 1013904223u;
	MC_CHECK(((uint32_t*)b.contents)[5] == v + 1, @"%u, want %u: the increment did not wait for the fence", ((uint32_t*)b.contents)[5], v + 1);
	return MC_PASS;
}

MC_TEST(sync, untracked_without_fence_is_allowed, "MTLResource hazardTrackingMode") {
	id<MTLBuffer> b = [dev newBufferWithLength:64 options:MTLResourceHazardTrackingModeUntracked];
	MC_CHECK(b.hazardTrackingMode == MTLHazardTrackingModeUntracked, @"mode %lu", (unsigned long)b.hazardTrackingMode);
	return MC_PASS;
}
