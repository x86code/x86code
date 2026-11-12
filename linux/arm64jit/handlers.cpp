#include <sys/uio.h>
#include <unistd.h>
#include <unordered_map>
#include <mutex>
#include <vector>
// libarm64jit: libsystem_kernel/platform/pthread exports that the generic pass-through can't serve: variadic
// functions, function-pointer arguments (native -> guest trampolines), bool results, Darling names that differ from
// the arm64 ones (64-bit-inode stat), the setjmp family (guest code) and the guest-side init functions (no-ops: the
// native libraries were initialized by the host program's own libSystem).
#include "a64.h"
#include <cstdio>
#include <atomic>
#include <map>
#include <sys/mman.h>
#include <csetjmp>
#include <sys/syscall.h>
#include <asm/prctl.h>

namespace a64 {

static u64 cb(u64 guest_fn) { return guest_fn > 1 ? (u64)guest_callable(guest_fn) : guest_fn; }  // keep SIG_DFL/IGN
static u64 uncb(u64 native) { u64 g = guest_of_callable((const void *)native); return g ? g : native; }

// Calls the thunk's native function with the guest's integer args after translating some of them.
template <int... Fn> static void h_callbacks(GuestThread &t, u32 i) {
    u64 ints[16];
    for (int k = 0; k < 8; k++) ints[k] = t.x(k);
    for (int k = 8; k < 16; k++) ints[k] = t.stack_slot(k - 8);
    ((ints[Fn] = cb(ints[Fn])), ...);
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    t.set_x(0, r.rax);
}

// pthread keys: the values live in the guest's private TSD array (setspecific is guest code), which Darling's native
// pthread never sees, so it could never run a guest key's destructor. The key is allocated natively (one key space
// for both sides) without a destructor; the guest destructor is recorded here and run_guest_tsd_destructors (jit.cpp)
// calls it at thread exit. CoreFoundation's TSD finalizer (NSThread's `finished`, autorelease pools, run loops) is one.
static void h_key_create(GuestThread &t, u32 i) {  // int pthread_key_create(pthread_key_t *key, void (*dtor)(void *))
    const u64 key_ptr = t.x(0), dtor = t.x(1);
    u64 ints[16] = {key_ptr, 0};
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    if ((int)r.rax == 0 && key_ptr) set_guest_key_destructor(*(u64 *)key_ptr, dtor);
    if ((int)r.rax == 0 && key_ptr && (*(u64 *)key_ptr == (u64)kHeapTsdSlot || *(u64 *)key_ptr == 766))
        logf("pthread_key_create: key %lu is a slot the guest-code fast paths use", (unsigned long)*(u64 *)key_ptr);
    t.set_x(0, r.rax);
}
static void h_key_init_np(GuestThread &t, u32 i) {  // int pthread_key_init_np(int key, void (*dtor)(void *))
    const u64 key = t.x(0), dtor = t.x(1);
    u64 ints[16] = {key, 0};
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    if ((int)r.rax == 0) set_guest_key_destructor(key, dtor);
    t.set_x(0, r.rax);
}
static void h_key_delete(GuestThread &t, u32 i) {
    const u64 key = t.x(0);
    u64 ints[16] = {key};
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    if ((int)r.rax == 0) set_guest_key_destructor(key, 0);
    t.set_x(0, r.rax);
}

// Threads the guest creates start in thread_start(): pthread_exit on them unwinds back here (longjmp) and the thread
// returns from its start routine instead. Darling's own pthread_exit killed the whole process (SIGABRT) when called
// from a thread running guest code (backboardd).
struct StartArg { u64 fn, arg; };
// __builtin_setjmp/longjmp: glibc's fortified longjmp (__longjmp_chk) aborted on Darling's thread stacks
using ExitJmp = void *[5];
static thread_local ExitJmp *t_exit_jmp;
static thread_local u64 t_exit_value;
static void *thread_start(void *p) {
    StartArg a = *(StartArg *)p;
    delete (StartArg *)p;
    ExitJmp jb;
    ExitJmp *outer = t_exit_jmp;
    t_exit_jmp = &jb;
    u64 r;
    if (__builtin_setjmp(jb) == 0) r = GuestThread::self().call(a.fn, {a.arg});
    else {
        r = t_exit_value;
        if (g_trace) logf("thread_start: unwound from pthread_exit (tid %ld)", (long)syscall(SYS_gettid));
        GuestThread::self().reset_after_unwind();
        if (g_trace) logf("thread_start: new Jit, returning %#lx", (unsigned long)r);
    }
    t_exit_jmp = outer;
    return (void *)r;
}
static void *start_arg(u64 fn, u64 arg) { return new StartArg{fn, arg}; }
// pthread_create(thread, attr, start, arg) and the variants with the same arguments
static void h_pthread_create(GuestThread &t, u32 i) {
    auto *fn = (int (*)(u64, u64, void *(*)(void *), void *))g_thunks[i].native;
    t.set_x(0, (u32)fn(t.x(0), t.x(1), thread_start, start_arg(t.x(2), t.x(3))));
}
static void h_pthread_create_with_workgroup(GuestThread &t, u32) {  // (thread, workgroup, attr, start, arg)
    static auto *fn = (int (*)(u64, u64, void *(*)(void *), void *))dsym("pthread_create");
    t.set_x(0, (u32)fn(t.x(0), t.x(2), thread_start, start_arg(t.x(3), t.x(4))));
}

static void h_introspection_hook(GuestThread &t, u32 i) {
    auto *fn = (u64(*)(u64))g_thunks[i].native;
    t.set_x(0, uncb(fn(cb(t.x(0)))));
}

static void h_workqueue_setup(GuestThread &t, u32 i) {  // (struct pthread_workqueue_config *, size)
    struct Cfg { uint32_t flags, version; u64 kevent_cb, workloop_cb, workq_cb, serialno_offs, label_offs; } c{};
    size_t n = t.x(1) < sizeof c ? t.x(1) : sizeof c;
    memcpy(&c, (void *)t.x(0), n);
    c.kevent_cb = cb(c.kevent_cb); c.workloop_cb = cb(c.workloop_cb); c.workq_cb = cb(c.workq_cb);
    if (timebase_apple()) {  // convert the timer changes the callbacks hand back (tb_convert_qos_changes)
        static u64 kev, wl;
        kev = c.kevent_cb; wl = c.workloop_cb;
        if (kev) c.kevent_cb = (u64)+[](void **ev, int *n) {
            ((void (*)(void **, int *))kev)(ev, n);
            if (ev && n && *n > 0) tb_convert_qos_changes(*ev, *n);
        };
        if (wl) c.workloop_cb = (u64)+[](u64 *id, void **ev, int *n) {
            ((void (*)(u64 *, void **, int *))wl)(id, ev, n);
            if (ev && n && *n > 0) tb_convert_qos_changes(*ev, *n);
        };
    }
    auto *fn = (int (*)(Cfg *, size_t))g_thunks[i].native;
    t.set_x(0, (u32)fn(&c, t.x(1)));
}

// _simple_* formatters (libsystem_platform's async-signal-safe printf).
static void simple_out(int fd, const std::string &s) {
    if (write(fd, s.data(), s.size()) < 0) {}
}
static void h_simple_dprintf(GuestThread &t, u32) { simple_out((int)t.x(0), guest_format((const char *)t.x(1), (const u64 *)t.sp())); }
static void h_simple_vdprintf(GuestThread &t, u32) { simple_out((int)t.x(0), guest_format((const char *)t.x(1), (const u64 *)t.x(2))); }
static int sappend(u64 b, const std::string &s) {
    static auto *fn = (int (*)(u64, const char *))dsym("_simple_sappend");
    return fn(b, s.c_str());
}
static void h_simple_sprintf(GuestThread &t, u32) { t.set_x(0, (u32)sappend(t.x(0), guest_format((const char *)t.x(1), (const u64 *)t.sp()))); }
static void h_simple_vsprintf(GuestThread &t, u32) { t.set_x(0, (u32)sappend(t.x(0), guest_format((const char *)t.x(1), (const u64 *)t.x(2)))); }
static void h_simple_esprintf(GuestThread &t, u32) { t.set_x(0, (u32)sappend(t.x(0), guest_format((const char *)t.x(2), (const u64 *)t.sp()))); }
static void h_simple_vesprintf(GuestThread &t, u32) { t.set_x(0, (u32)sappend(t.x(0), guest_format((const char *)t.x(2), (const u64 *)t.x(3)))); }


// ---- VM: guest pages are 16K, and libmalloc asks for aligned regions (mask); Darling's maps are 4K-aligned and
// ignore the mask. An "anywhere" request reserves size + alignment, then maps fixed+overwrite at the aligned address.
// Also: >8-argument functions pass their 9th+ int arguments packed by natural size on the Apple arm64 stack.
constexpr int kAnywhere = 1, kOverwrite = 0x4000;
// Guest memory also has to stay below 64 GB (iOS's user address space; xzone malloc's segment table covers no more):
// requests are placed first-fit from a cursor in [12 GB, 63 GB), above the shared cache, below the commpage.
static std::atomic<u64> g_low_cursor{0x300000000ull};
constexpr u64 kLowEnd = 0xFC0000000ull;
static u64 reserve_low(u64 len) {
    len = (len + 0x3fff) & ~0x3fffull;  // keep the cursor 16K-aligned (an unaligned one made every later mmap EINVAL)
    for (int wrapped = 0; wrapped < 2; wrapped++) {
        for (;;) {
            u64 at = g_low_cursor.load();
            if (at + len > kLowEnd) break;
            void *p = mmap((void *)at, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE, -1, 0);
            if (p == (void *)at) { u64 want = at; g_low_cursor.compare_exchange_strong(want, at + len); return at; }
            if (p != MAP_FAILED) munmap(p, len);
            u64 want = at; g_low_cursor.compare_exchange_strong(want, at + 0x100000);  // taken: step 1 MB
        }
        g_low_cursor = 0x300000000ull;
    }
    return 0;
}
u64 reserve_aligned(u64 size, u64 mask) {
    u64 align = (mask | 0x3fff) + 1;
    u64 r = reserve_low(size + align);
    if (!r) return 0;
    u64 a = (r + align - 1) & ~(align - 1);
    if (a > r) munmap((void *)r, a - r);
    u64 end = r + size + align, aend = a + ((size + 0x3fff) & ~0x3fffull);
    if (end > aend) munmap((void *)aend, end - aend);
    return a;
}
// Speed 5: guest pages are 16K, Darling's are 4K. Memory that native code maps for the guest in the host range
// (Mach out-of-line message data, Darling's own vm_allocate) is 4K-granular, and the guest frees it in 16K pages:
// vm_deallocate/munmap then spilled into the next mapping. When that was a libsystem stub image
// (memfd:libsystem_*, mapped by dyld_sim; every GOT entry for libsystem points there) or another dylib, the next
// call into it jumped to an unmapped page (Preferences/SpringBoard SIGSEGVs with guest pc in an unmapped 0x7f... page,
// e.g. from _dispatch_set_priority_and_mach_voucher_slow -> _pthread_set_properties_self). For a host-range request,
// a file-backed mapping that the range only runs into (it does not start inside it) is left mapped: the request is
// trimmed to end where that mapping begins; a request starting 4K- but not 16K-aligned (never one of our 16K guest
// allocations) is also kept inside the mapping that contains its start.
std::atomic<bool> g_stub_guard_armed{false};  // set once dyld_sim has mapped every image (host.cpp)
constexpr u64 kHostRangeLo = 0x100000000000ull;
// Out-of-line memory Darling maps into a received Mach message (4K-granular, host range): its true size, so a later
// guest deallocate in 16K pages can be clipped to it (OOL data is the main source of those regions).
static std::unordered_map<u64, u64> g_ool;
static std::mutex g_ool_mu;
static void record_ool(const uint8_t *msg) {
    uint32_t bits, size;
    memcpy(&bits, msg, 4);
    memcpy(&size, msg + 4, 4);
    if (!(bits & 0x80000000u) || size < 28) return;  // MACH_MSGH_BITS_COMPLEX
    uint32_t n;
    memcpy(&n, msg + 24, 4);
    const uint8_t *d = msg + 28, *end = msg + size;
    std::lock_guard<std::mutex> l(g_ool_mu);
    if (g_ool.size() > 65536) g_ool.clear();  // stale entries (freed some other way)
    for (uint32_t k = 0; k < n && d + 12 <= end; k++) {
        const uint8_t type = d[11];
        if (type == 0) { d += 12; continue; }  // port
        if (d + 16 > end) break;
        u64 addr; uint32_t cnt;
        memcpy(&addr, d, 8);
        memcpy(&cnt, d + 12, 4);
        const u64 bytes = type == 2 ? (u64)cnt * 4 : cnt;  // OOL ports: count names
        if ((type == 1 || type == 2 || type == 3) && addr >= kHostRangeLo && bytes)
            g_ool[addr] = (bytes + 0xfff) & ~0xfffull;
        d += 16;
    }
}
// End of the unmap [a, a+len) clipped at the first file-backed mapping that starts inside (a, a+len).
static u64 clip_unmap(u64 a, u64 len) {
    u64 end = a + len;
    if (!g_stub_guard_armed.load(std::memory_order_relaxed) || a < kHostRangeLo || !len) return end;
    {
        std::lock_guard<std::mutex> l(g_ool_mu);
        if (auto it = g_ool.find(a); it != g_ool.end()) {
            if (it->second < len) end = a + it->second;
            g_ool.erase(it);
        }
    }
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return end;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        unsigned long lo, hi, off, ino; char perms[8], dev[16]; int pos = 0;
        if (sscanf(line, "%lx-%lx %7s %lx %15s %lu %n", &lo, &hi, perms, &off, dev, &ino, &pos) < 6) continue;
        if (lo >= end) break;
        const char *path = line + pos;
        if (lo > a && lo < end && (*path == '/' || ino != 0)) { end = lo; break; }
        // a 4K-aligned start is Darling's own 4K-granular mapping (ours are 16K-aligned): stop at its VMA's end
        if ((a & 0x3fff) && lo <= a && a < hi && hi < end) { end = hi; break; }
    }
    fclose(f);
    return end;
}
static bool guard_unmap(GuestThread &t, u64 a, u64 len, const char *what, u64 *new_len) {
    const u64 end = clip_unmap(a, len);
    *new_len = end - a;
    if (end == a + len) return false;
    static std::atomic<int> n{0};
    if (n++ < 8)
        logf("%s(%#lx, %#lx) would spill into the next file mapping at %#lx: trimmed (lr %#lx)", what, (unsigned long)a,
             (unsigned long)len, (unsigned long)end, (unsigned long)t.x(30));
    return true;
}
// kern_return_t f(task, addr *, size, mask, flags, ...rest) with rest as 64-bit native args
static void vm_map_like(GuestThread &t, u32 i, u64 *ints, int addr_arg, int size_arg, int mask_arg, int flags_arg) {
    u64 *addrp = (u64 *)ints[addr_arg];
    u64 fps[8] = {}; NRet r;
    if ((ints[flags_arg] & kAnywhere) && addrp) {
        u64 a = reserve_aligned(ints[size_arg], mask_arg >= 0 ? ints[mask_arg] : 0);
        if (a) {
            u64 saved = *addrp; *addrp = a;
            u64 f = ints[flags_arg]; ints[flags_arg] = (f & ~(u64)kAnywhere) | kOverwrite;
            a64_ncall(g_thunks[i].native, ints, fps, &r);
            if ((int)r.rax == 0) { t.set_x(0, 0); return; }
            munmap((void *)a, (ints[size_arg] + 0x3fff) & ~0x3fffull);
            *addrp = saved; ints[flags_arg] = f;
        }
    }
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    t.set_x(0, (u32)r.rax);
}
static void load_regs(GuestThread &t, u64 *ints) { for (int k = 0; k < 16; k++) ints[k] = k < 8 ? t.x(k) : 0; }
// munmap(addr, len)
static void h_munmap(GuestThread &t, u32 i) {
    u64 nl;
    if (guard_unmap(t, t.x(0), t.x(1), "munmap", &nl)) {
        if (nl) t.set_x(1, nl); else { t.set_x(0, 0); return; }
    }
    h_generic(t, i);
}
// (mach_)vm_deallocate(task, addr, size)
static void h_vm_deallocate(GuestThread &t, u32 i) {
    u64 nl;
    if (guard_unmap(t, t.x(1), t.x(2), "vm_deallocate", &nl)) {
        if (nl) t.set_x(2, nl); else { t.set_x(0, 0); return; }
    }
    h_generic(t, i);
}
// RAM 12: madvise(addr, len, advice). XNU's MADV_FREE (5) and MADV_FREE_REUSABLE (7) give the kernel the pages of
// anonymous private memory (contents undefined until written again); libmalloc frees with them (tiny/small/medium
// madvise_free, nano, xzone's madvise batches, and its memory-pressure relief), as do libpas/bmalloc and JSC. Darling's
// sys_madvise answered every advice >= 5 with 0 and did nothing, so no freed malloc page ever went back to the host:
// a process kept the high water of its heap for life. Now: Linux MADV_FREE as a probe (it only takes private anonymous
// memory: a range with a file, shared or memfd mapping in it fails with EINVAL, which is the XNU behaviour for those:
// vm_map_reusable_pages skips them), then MADV_DONTNEED so the pages go at once (MADV_FREE alone waits for host
// pressure and stays in PSS). Whole pages inside the range only. MADV_FREE_REUSE (8) / MADV_CAN_REUSE (9) are
// accounting on XNU: 0. X86SIM_A64_MADV_FREE=0: the old pass-through (no-op); X86SIM_A64_MADVLOG=1: census in the log.
static void h_madvise(GuestThread &t, u32 i) {
    static const bool off = getenv("X86SIM_A64_MADV_FREE") && atoi(getenv("X86SIM_A64_MADV_FREE")) == 0;
    static const bool census = getenv("X86SIM_A64_MADVLOG") != nullptr;
    const int adv = (int)t.x(2);
    if (off || (adv != 5 && adv != 7)) {
        if (census) logf("madvise %#lx +%#lx advice %d (pass-through)", (unsigned long)t.x(0), (unsigned long)t.x(1), adv);
        h_generic(t, i);
        return;
    }
    const u64 a = t.x(0), n = t.x(1), pg = 4096;
    const u64 lo = (a + pg - 1) & ~(pg - 1), hi = (a + n) & ~(pg - 1);
    long r = 0;
    if (hi > lo) {
        r = syscall(SYS_madvise, (void *)lo, (size_t)(hi - lo), 8 /* Linux MADV_FREE */);
        if (r == 0) r = syscall(SYS_madvise, (void *)lo, (size_t)(hi - lo), MADV_DONTNEED);
    }
    if (census) {
        static std::atomic<u64> calls{0}, bytes{0}, refused{0};
        const u64 c = ++calls;
        if (r == 0) bytes += hi > lo ? hi - lo : 0; else ++refused;
        if ((c & (c - 1)) == 0 || r != 0)
            logf("madvise free: %lu calls, %lu MB given back, %lu refused (last %#lx +%#lx advice %d -> %ld)",
                 (unsigned long)c, (unsigned long)(bytes >> 20), (unsigned long)refused.load(), (unsigned long)a,
                 (unsigned long)n, adv, r);
    }
    t.set_x(0, 0);  // XNU: KERN_SUCCESS for ranges it skips, too
}
// Align 1: mincore(addr, len, vec). XNU (bsd/kern/kern_mman.c mincore) fills one byte per page of the caller's map,
// and a guest page is 16K here (vm_page_size); the call went through to Darling's sys_mincore, i.e. Linux, which
// writes one byte per 4K page: 4x the bytes the caller sized vec for (a heap overflow behind any multi-page query),
// and per-4K answers. Now: Linux's answer for the whole 16K pages the range touches, folded to one byte per 16K page
// (MINCORE_INCORE if any 4K piece is resident, as XNU reports a page; errors as Linux gives them: ENOMEM unmapped).
static void h_mincore(GuestThread &t, u32 i) {
    const u64 gp = 0x4000, a = t.x(0), n = t.x(1);
    uint8_t *vec = (uint8_t *)t.x(2);
    const u64 lo = a & ~(gp - 1), hi = (a + n + gp - 1) & ~(gp - 1);
    if (!n || hi <= lo) { t.set_x(0, 0); return; }
    const u64 pages4 = (hi - lo) >> 12;
    uint8_t small[256];
    std::vector<uint8_t> big;
    uint8_t *v = small;
    if (pages4 > sizeof small) { big.resize(pages4); v = big.data(); }
    long r = syscall(SYS_mincore, (void *)lo, (size_t)(hi - lo), v);
    if (r != 0) {
        // XNU answers an unmapped range with ENOMEM (KERN_INVALID_ADDRESS). The native call sets the guest's errno:
        // page 0 is never mapped, so mincore(0, 1) fails with ENOMEM before Linux writes anything.
        t.set_x(0, 0); t.set_x(1, 1);
        h_generic(t, i);
        return;
    }
    for (u64 p = 0; p < pages4 / 4; p++)
        vec[p] = ((v[4 * p] | v[4 * p + 1] | v[4 * p + 2] | v[4 * p + 3]) & 1) ? 1 /* MINCORE_INCORE */ : 0;
    t.set_x(0, 0);
}
// RAM 12 census only (X86SIM_A64_MADVLOG): (mach_)vm_behavior_set(task, addr, size, behavior)
static void h_behavior_set(GuestThread &t, u32 i) {
    static const bool census = getenv("X86SIM_A64_MADVLOG") != nullptr;
    if (census) logf("vm_behavior_set %#lx +%#lx behavior %d", (unsigned long)t.x(1), (unsigned long)t.x(2), (int)t.x(3));
    h_generic(t, i);
}
// (mach_)vm_map(task, addr*, size, mask, flags, object, offset, copy | int cur, int max, uint inherit)
static void h_vm_map(GuestThread &t, u32 i) {
    u64 ints[16]; load_regs(t, ints);
    u64 sp = t.sp();
    ints[8] = GuestThread::rd<int32_t>(sp); ints[9] = GuestThread::rd<int32_t>(sp + 4); ints[10] = GuestThread::rd<uint32_t>(sp + 8);
    vm_map_like(t, i, ints, 1, 2, 3, 4);
}
// (mach_)vm_remap[_new](task, addr*, size, mask, flags, src_task, src_addr, copy | cur*, max*, uint inherit)
//
// Speed 30: a shared (copy = FALSE) remap within the task. Darling (darlingserver dtape_share_region) shares private
// memory by copying it into a memfd and then mapping the memfd over the source: stores other threads make between
// the copy and the remap were lost. AttributeGraph grows its process-wide node table that way (data::table::
// grow_region: vm_remap of the old table into a 4x larger region), so a concurrent update's writes (a node's value,
// its flags) vanished: Maps' route card aborted with "attribute failed to set an initial value" (varying
// attributes). Now the source is made read-only first; a thread that writes to it meanwhile faults, waits in
// remap_fault_wait (host.cpp on_fault) until the protection is back, and retries its store on the shared pages.
// Opt-in (X86SIM_A64_REMAP_FREEZE=1): it did not fix the Maps abort (one 1 MB remap there, still aborted), and nothing
// becomes default without three clean gate boots.
std::atomic<u64> g_remap_lo{0}, g_remap_hi{0};
// Speed 36: the whole range [a, a + len) (several mappings after darlingserver's piecewise remap): *prot is the common
// protection (0 if the pieces differ or a hole), *priv whether any piece is private.
static bool remap_prot_of(u64 a, u64 len, int *prot, bool *priv) {
    FILE *m = fopen("/proc/self/maps", "r");
    if (!m) return false;
    char line[512]; u64 covered = a; int common = -1; *priv = false;
    while (fgets(line, sizeof line, m) && covered < a + len) {
        unsigned long lo, hi; char p[5];
        if (sscanf(line, "%lx-%lx %4s", &lo, &hi, p) != 3) continue;
        if (hi <= covered) continue;
        if (lo > covered) break;  // hole
        const int pr = (p[0] == 'r' ? PROT_READ : 0) | (p[1] == 'w' ? PROT_WRITE : 0) | (p[2] == 'x' ? PROT_EXEC : 0);
        if (common >= 0 && pr != common) common = 0; else if (common < 0) common = pr;
        if (p[3] == 'p') *priv = true;
        covered = hi;
    }
    fclose(m);
    *prot = common < 0 ? 0 : common;
    return covered >= a + len;
}
static void h_vm_remap(GuestThread &t, u32 i) {
    u64 ints[16]; load_regs(t, ints);
    u64 sp = t.sp();
    ints[8] = GuestThread::rd<u64>(sp); ints[9] = GuestThread::rd<u64>(sp + 8); ints[10] = GuestThread::rd<uint32_t>(sp + 16);
    static const bool freeze = [] { const char *e = getenv("X86SIM_A64_REMAP_FREEZE"); return e && *e == '1'; }();
    const u64 src = ints[6] & ~0x3fffull, len = ((ints[6] + ints[2] + 0x3fff) & ~0x3fffull) - src;
    int prot = 0; bool priv = false;
    if (!freeze || (u32)ints[7] != 0 || ints[0] != ints[5] || !ints[2] || !remap_prot_of(src, len, &prot, &priv) || !priv ||
        prot != (PROT_READ | PROT_WRITE)) {
        vm_map_like(t, i, ints, 1, 2, 3, 4);
        return;
    }
    static std::mutex mu;  // one frozen range at a time
    std::lock_guard<std::mutex> g(mu);
    g_remap_lo.store(src); g_remap_hi.store(src + len);
    mprotect((void *)src, len, PROT_READ);
    vm_map_like(t, i, ints, 1, 2, 3, 4);
    const bool ok = (u32)t.x(0) == 0;
    mprotect((void *)src, len, prot);
    if (ok && ints[1]) {
        const u64 dst = *(u64 *)ints[1] & ~0xfffull;
        mprotect((void *)dst, ((*(u64 *)ints[1] + ints[2] + 0xfff) & ~0xfffull) - dst, prot);
        if (ints[8]) *(int32_t *)ints[8] = 3;  // VM_PROT_READ | VM_PROT_WRITE
    }
    g_remap_hi.store(0); g_remap_lo.store(0);
    static std::atomic<int> n{0};
    if (n++ < 4) logf("vm_remap shared %#lx+%#lx (frozen, %s)", (unsigned long)src, (unsigned long)len, ok ? "ok" : "failed");
}
// (mach_)vm_allocate(task, addr*, size, flags)
static void h_vm_allocate(GuestThread &t, u32 i) {
    u64 ints[16]; load_regs(t, ints);
    vm_map_like(t, i, ints, 1, 2, -1, 3);
}
// mmap(addr, len, prot, flags, fd, off): non-fixed maps 16K-aligned
static void h_mmap(GuestThread &t, u32 i) {
    u64 ints[16]; load_regs(t, ints);
    u64 fps[8] = {}; NRet r;
    constexpr u64 kFixed = 0x10;
    if (!(ints[3] & kFixed) && ints[1]) {
        if (u64 a = reserve_aligned(ints[1], 0)) {
            u64 save0 = ints[0], save3 = ints[3];
            ints[0] = a; ints[3] |= kFixed;
            a64_ncall(g_thunks[i].native, ints, fps, &r);
            if (r.rax == a) { t.set_x(0, a); return; }
            munmap((void *)a, (ints[1] + 0x3fff) & ~0x3fffull);
            ints[0] = save0; ints[3] = save3;
        }
    }
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    t.set_x(0, r.rax);
}
// mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg | uint rcv_limit)
static void h_msg_overwrite(GuestThread &t, u32 i) {
    u64 ints[16]; load_regs(t, ints);
    ints[8] = GuestThread::rd<uint32_t>(t.sp());
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    t.set_x(0, (u32)r.rax);
    if ((u32)r.rax == 0 && (ints[1] & 2 /* MACH_RCV_MSG */)) record_ool((const uint8_t *)(ints[7] ? ints[7] : ints[0]));
}
// mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
static void h_mach_msg(GuestThread &t, u32 i) {
    const u64 msg = t.x(0), opt = t.x(1);
    h_generic(t, i);
    if ((u32)t.x(0) == 0 && (opt & 2 /* MACH_RCV_MSG */) && msg) record_ool((const uint8_t *)msg);
}

// Generic >8-argument functions: the 9th+ arguments are packed by natural size/alignment on the Apple arm64 stack
// (each 8-byte slot on SysV). Sizes are given for each stack argument (manyargs audit).
template <int... Sz> static void h_stack_args(GuestThread &t, u32 i) {
    u64 ints[16]; load_regs(t, ints);
    u64 off = 0, sp = t.sp(); int k = 8;
    auto take = [&](int sz) {
        off = (off + sz - 1) & ~(u64)(sz - 1);
        ints[k++] = sz == 8 ? GuestThread::rd<u64>(sp + off) : sz == 4 ? GuestThread::rd<uint32_t>(sp + off) : GuestThread::rd<uint16_t>(sp + off);
        off += sz;
    };
    (take(Sz), ...);
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    t.set_x(0, r.rax);
}
// Structs over 16 bytes by value: arm64 passes a pointer, SysV copies the struct onto the stack.
// task_register_dyld_shared_cache_image_info(task, dyld_kernel_image_info_t (40 B), bool, bool)
static void h_dyld_cache_info(GuestThread &t, u32 i) {
    u64 ints[16] = {t.x(0), t.x(2), t.x(3), 0, 0, 0};
    memcpy(&ints[6], (void *)t.x(1), 40);
    u64 fps[8] = {}; NRet r;
    a64_ncall(g_thunks[i].native, ints, fps, &r);
    t.set_x(0, (u32)r.rax);
}

// libSystem's initializer calls this first, before __malloc_init: the cache is mapped, nothing has allocated yet.
static void h_libkernel_init(GuestThread &t, u32) {
    native_malloc_install();
    native_objc_install();  // shared-cache text is mapped; patch before any guest objc runs
    objc_cache_gc_guard(t);
    sim_service_patches(t);
    t.set_x(0, 0);
}

// abort_with_payload(ns, code, payload, size, reason, flags) / abort_with_reason(ns, code, reason, flags): log first
static void h_abort_with(GuestThread &t, u32 i) {
    const char *reason = (const char *)(g_thunks[i].name == "_abort_with_reason" ? t.x(2) : t.x(4));
    logf("%s: namespace %lu code %#lx: %s (lr %#lx)", g_thunks[i].name.c_str(), (unsigned long)t.x(0), (unsigned long)t.x(1),
         reason ? reason : "(null)", (unsigned long)t.x(30));
    h_generic(t, i);
}

// pthread_exit on the main thread (dispatch_main does it): Darling's terminates nothing there and traps ("thread
// didn't terminate", SIGILL). The main thread parks instead; the process ends when another thread calls exit().
// Before parking it runs what a real thread exit runs (cleanup records, guest TSD destructors): libdispatch's queue
// key destructor (_dispatch_queue_cleanup2) is what hands _dispatch_main_q over to the root queue after
// dispatch_main. Without it the main queue was never drained again, so daemons serving on it (filecoordinationd's
// NSXPCListener + NSFileAccessArbiter) never answered (Speed 21: Health / Files blocked on grantAccessClaim).
static void h_pthread_exit(GuestThread &t, u32 i) {
    static auto *is_main = (int (*)())dsym("pthread_main_np");
    const bool main_thread = is_main && is_main();
    // pthread_cleanup_push records are guest code (the macro links them into pthread_self()->__cleanup_stack, at +8
    // in both layouts): run them here, newest first, before Darling sees the thread end.
    {
        static auto *self = (u64 (*)())dsym("pthread_self");
        u64 th = self(), exit_value = t.x(0);
        struct Rec { u64 routine, arg, next; };
        while (Rec *r = *(Rec **)(th + 8)) {
            *(u64 *)(th + 8) = r->next;
            if (r->routine) t.call(r->routine, {r->arg});
        }
        t.set_x(0, exit_value);
    }
    if (main_thread) {
        if (!getenv("X86SIM_A64_MAIN_EXIT_NOTSD")) {
            logf("pthread_exit on the main thread (linux tid %ld, pid %d): TSD destructors, then parking it",
                 (long)syscall(SYS_gettid), (int)getpid());
            // libdispatch's _dispatch_queue_cleanup2 ends in _dispatch_sig_thread (sigsuspend forever on this thread)
            t.run_guest_tsd_destructors();
        } else logf("pthread_exit on the main thread (pid %d): parking it", (int)getpid());
        static auto *dsleep = (unsigned (*)(unsigned))dsym("sleep");
        for (;;) dsleep(100000);
    }
    if (t_exit_jmp) { t_exit_value = t.x(0); __builtin_longjmp(*t_exit_jmp, 1); }
    logf("pthread_exit on a thread not started by us (tid %ld): Darling's pthread_exit", (long)syscall(SYS_gettid));
    guest_backtrace(t);
    h_generic(t, i);
}

// pthread_get_stackaddr_np / pthread_get_stacksize_np on the calling thread: the guest runs on its GuestThread's
// stack, not on the native one Darling's pthread describes. libdispatch's _dispatch_clear_stack (end of
// _dispatch_queue_cleanup2 after dispatch_main) bzeroed from sp to the native stack's bottom and faulted. Other
// threads: native answer.
static bool on_own_stack(GuestThread &t) {
    static auto *self = (u64 (*)())dsym("pthread_self");
    return t.x(0) == self() && t.stack_base && t.sp() - t.stack_base < t.stack_size;
}
static void h_stackaddr(GuestThread &t, u32 i) {
    if (on_own_stack(t)) t.set_x(0, t.stack_base + t.stack_size); else h_generic(t, i);
}
static void h_stacksize(GuestThread &t, u32 i) {
    if (on_own_stack(t)) t.set_x(0, t.stack_size); else h_generic(t, i);
}

// pthread_kill/__pthread_kill/kill with SIGABRT (libc's abort): log the guest backtrace first
static void h_kill_like(GuestThread &t, u32 i) {
    if (t.x(1) == 6) {
        logf("%s(SIGABRT): guest backtrace", g_thunks[i].name.c_str());
        guest_backtrace(t);
        // Speed 29 debug: X86SIM_A64_ABORT_MSG=<hex addr>[,...]: guest char* globals holding the abort message (e.g.
        // AttributeGraph's precondition text), printed if set
        if (const char *e = getenv("X86SIM_A64_ABORT_MSG"))
            for (const char *q = e; *q;) {
                char *end;
                const u64 a = strtoull(q, &end, 16);
                if (end == q) break;
                if (const char *m = *(const char *const *)a) logf("abort message at %#llx: %.2000s", (unsigned long long)a, m);
                q = *end == ',' ? end + 1 : end;
            }
        // Speed 30 debug: X86SIM_A64_ABORT_TSD=<hex address of a pthread key variable>: that key's value on the
        // aborting thread (guest TSD) and the 0x80 bytes it points to (low bit cleared), plus the frame words of an
        // AttributeGraph UpdateStack chain (count +104, buffer +96 or inline +32, previous link scanned from the dump)
        if (const char *e = getenv("X86SIM_A64_ABORT_TSD")) {
            auto rdv = [](u64 a, void *buf, size_t n) {
                iovec l{buf, n}, r{(void *)a, n};
                return process_vm_readv(getpid(), &l, 1, &r, 1, 0) == (ssize_t)n;
            };
            u64 key = 0, ka = strtoull(e, nullptr, 16);
            rdv(ka, &key, 8);
            u64 v = key < GuestThread::kGuestTsdSlots ? t.tsd[key] : 0;
            logf("abort tsd: key %llu value %#llx (tpidrro %#llx)", (unsigned long long)key, (unsigned long long)v,
                 (unsigned long long)(u64)t.tsd);
            for (int depth = 0; depth < 6 && (v & ~1ull); depth++) {
                u64 st = v & ~1ull, w[16] = {};
                if (!rdv(st, w, sizeof w)) break;
                char line[600]; int n = 0;
                for (int k = 0; k < 16; k++) n += snprintf(line + n, sizeof line - n, " %llx", (unsigned long long)w[k]);
                logf("abort tsd: stack %d @%#llx:%s", depth, (unsigned long long)st, line);
                u64 cnt = w[13], buf = w[12] ? w[12] : st + 32;
                n = 0;
                for (u64 k = 0; k < cnt && k < 40; k++) {
                    u64 fr = 0; rdv(buf + 8 * k, &fr, 8);
                    n += snprintf(line + n, sizeof line - n, " %x/%x", (unsigned)fr, (unsigned)(fr >> 32));
                }
                logf("abort tsd: stack %d frames(%llu):%s", depth, (unsigned long long)cnt, line);
                if (depth == 0 && cnt && getenv("X86SIM_A64_AGOUT")) {  // Speed 31: the top frame's output-value trace
                    u64 fr = 0; rdv(buf + 8 * (cnt - 1), &fr, 8);
                    agout_dump((u32)fr);
                }
                v = w[1];  // guess: previous UpdateStack (checked by the dump shape)
            }
        }
        // X86SIM_A64_ABORT_STRINGS=1: C strings pointed to from the aborting thread's stack (the formatted abort
        // message usually sits in a caller's frame); memory is read with process_vm_readv, so bad pointers are skipped
        if (getenv("X86SIM_A64_ABORT_STRINGS")) {
            auto rd = [](u64 a, void *buf, size_t n) {
                iovec l{buf, n}, r{(void *)a, n};
                return process_vm_readv(getpid(), &l, 1, &r, 1, 0) == (ssize_t)n;
            };
            int shown = 0;
            for (u64 o = 0; o < 0x8000 && shown < 40; o += 8) {
                u64 v;
                if (!rd(t.sp() + o, &v, 8) || v < 0x100000000ull || v >= 0x800000000000ull) continue;
                char b[512];
                if (!rd(v, b, sizeof b)) continue;
                size_t n = 0;
                while (n < sizeof b && b[n] && (b[n] == '\n' || (b[n] >= 32 && b[n] < 127))) n++;
                if (n < 16 || (n < sizeof b && b[n])) continue;
                logf("abort string [sp+%#llx] %#llx: %.*s", (unsigned long long)o, (unsigned long long)v, (int)n, b);
                shown++;
            }
        }
    }
    h_generic(t, i);
}

void print_stats();
static void h_exit(GuestThread &t, u32 i) {  // __exit: the guest process ends here
    if (getenv("X86SIM_A64_AOT_BUILD")) jitcache_aot_build(t);
    print_stats();
    jitcache_save_on_exit();
    ((void (*)(int))g_thunks[i].native)((int)t.x(0));
}

// ---- guest timebase (Speed 10) ---------------------------------------------------------------------------------------
// X86SIM_A64_TIMEBASE=apple: the guest sees Apple silicon's timebase (125/3, a 24 MHz counter) instead of Darling's
// 1/1 (mach time in ns). Code compiled for arm64 inlines 125/3 in places (libswift_Concurrency's deadline conversion,
// libdispatch's dispatch_time_to_nsecs/_from_nsec), so with 1/1 those deadlines were ~41x off. Values cross at the
// thunks: returned mach times are scaled down (ns * 3 / 125), mach-time arguments up (ticks * 125 / 3) before Darling
// sees them (mach_wait_until, mk_timer_arm*, mach_eventlink_*wait_until, EVFILT_TIMER with NOTE_MACHTIME, and the
// changes workqueue threads hand back). CNTVCT_EL0 counts at 24 MHz (jit.cpp). Default since Speed 11; X86SIM_A64_TIMEBASE=1to1 gives the guest
// Darling's 1/1 again (with the Swift deadline patch, jit.cpp; rebuild the image).
bool strict_monitor() {
    static const bool on = getenv("X86SIM_A64_STRICT_MONITOR") && atoi(getenv("X86SIM_A64_STRICT_MONITOR")) == 1;
    return on;
}
bool timebase_apple() {
    static const bool on = [] { const char *e = getenv("X86SIM_A64_TIMEBASE"); return !e || strcmp(e, "1to1") != 0; }();
    return on;
}
u64 tb_ns_to_ticks(u64 ns) { return (u64)((unsigned __int128)ns * 3 / 125); }
static bool tb_debug() {  // X86SIM_A64_TB_DEBUG=1: log the first 40 converted values per process
    static std::atomic<int> n{0};
    static const bool on = getenv("X86SIM_A64_TB_DEBUG") != nullptr;
    return on && n.fetch_add(1) < 40;
}
static u64 tb_ticks_to_ns(u64 t) {
    const unsigned __int128 ns = (unsigned __int128)t * 125 / 3;
    return ns > ~0ull ? ~0ull : (u64)ns;
}
static void h_tb_ret(GuestThread &t, u32 i) { h_generic(t, i); t.set_x(0, tb_ns_to_ticks(t.x(0))); }
static void h_tb_info(GuestThread &t, u32) {  // mach_timebase_info(_trap)(mach_timebase_info_t)
    if (auto *p = (uint32_t *)t.x(0)) { p[0] = 125; p[1] = 3; }
    t.set_x(0, 0);
}
static void h_tb_get_times(GuestThread &t, u32 i) {  // mach_get_times(u64 *abs, u64 *cont, timespec *)
    u64 *a = (u64 *)t.x(0), *c = (u64 *)t.x(1);
    h_generic(t, i);
    if (a) *a = tb_ns_to_ticks(*a);
    if (c) *c = tb_ns_to_ticks(*c);
}
template <int Arg> static void h_tb_out(GuestThread &t, u32 i) {  // a u64* result (mk_timer_cancel's result_time)
    u64 *p = (u64 *)t.x(Arg);
    h_generic(t, i);
    if (p && t.x(0) == 0) *p = tb_ns_to_ticks(*p);
}
template <int... Args> static void h_tb_in(GuestThread &t, u32 i) {  // mach-time arguments
    if (tb_debug()) logf("tb: %s x%d %#lx", g_thunks[i].name.c_str(), (int)(sizeof...(Args)), (unsigned long)t.x(0));
    ((t.set_x(Args, tb_ticks_to_ns(t.x(Args)))), ...);
    h_generic(t, i);
}
// EVFILT_TIMER with NOTE_MACHTIME: data (and the NOTE_LEEWAY leeway in ext[1]) are mach ticks. The changelist is
// copied (callers may reuse theirs). Layouts are the same on both architectures.
template <size_t Size, size_t FflagsOff, size_t DataOff, int ExtLeewayOff>
static void h_tb_kevent(GuestThread &t, u32 i) {
    constexpr int16_t kTimer = -7;
    constexpr uint32_t kMachTime = 0x100, kLeeway = 0x10;
    const int n = (int)t.x(2);
    const uint8_t *cl = (const uint8_t *)t.x(1);
    bool any = false;
    for (int k = 0; cl && k < n && !any; k++) {
        int16_t f; uint32_t ff;
        memcpy(&f, cl + k * Size + 8, 2); memcpy(&ff, cl + k * Size + FflagsOff, 4);
        any = f == kTimer && (ff & kMachTime);
        if (f == kTimer && !any && tb_debug()) {
            int64_t d; memcpy(&d, cl + k * Size + DataOff, 8);
            logf("tb: %s timer without NOTE_MACHTIME fflags %#x data %ld", g_thunks[i].name.c_str(), ff, (long)d);
        }
    }
    if (!any) return h_generic(t, i);
    std::vector<uint8_t> copy(cl, cl + (size_t)n * Size);
    for (int k = 0; k < n; k++) {
        uint8_t *e = copy.data() + k * Size;
        int16_t f; uint32_t ff;
        memcpy(&f, e + 8, 2); memcpy(&ff, e + FflagsOff, 4);
        if (f != kTimer || !(ff & kMachTime)) continue;
        int64_t d; memcpy(&d, e + DataOff, 8);
        if (tb_debug()) {
            uint16_t fl; memcpy(&fl, e + 10, 2);
            logf("tb: %s ident %#lx flags %#x fflags %#x data %ld now %lu", g_thunks[i].name.c_str(), (unsigned long)*(u64 *)e, fl, ff, (long)d,
                 (unsigned long)tb_ns_to_ticks(GuestThread::self().GetCNTPCT() * 125 / 3));
        }
        if (d > 0) { d = (int64_t)std::min<u64>(tb_ticks_to_ns((u64)d), (u64)INT64_MAX); memcpy(e + DataOff, &d, 8); }
        if (ExtLeewayOff >= 0 && (ff & kLeeway)) {
            u64 l; memcpy(&l, e + ExtLeewayOff, 8); l = tb_ticks_to_ns(l); memcpy(e + ExtLeewayOff, &l, 8);
        }
    }
    t.set_x(1, (u64)copy.data());
    h_generic(t, i);
}
// Speed 11: a workqueue thread hands its changes back (libdispatch's timer re-arms, mostly the event manager's) by
// returning from the kevent/workloop callback that Darling's native libpthread called: the native thread then passes
// them to __workq_kernreturn itself, past every thunk. Unconverted, each NOTE_MACHTIME deadline was ~41x early, i.e.
// already past: the oneshot timer fired at once and was re-armed, and Darling's kevent manager thread spun at 100% in
// 8 processes (its event log: the same EVFILT_TIMER idents ~400k times a second). Converted in place after the
// callback (the list is the thread's own buffer; Darling finds it again by its address).
void tb_convert_qos_changes(void *list, int n) {
    constexpr int16_t kTimer = -7;
    constexpr uint32_t kMachTime = 0x100, kLeeway = 0x10;
    for (int k = 0; list && k < n; k++) {
        uint8_t *e = (uint8_t *)list + k * 72;
        int16_t f; uint32_t ff;
        memcpy(&f, e + 8, 2); memcpy(&ff, e + 24, 4);
        if (f != kTimer || !(ff & kMachTime)) continue;
        int64_t d; memcpy(&d, e + 32, 8);
        if (tb_debug()) logf("tb: workq return ident %#lx fflags %#x data %ld", (unsigned long)*(u64 *)e, ff, (long)d);
        if (d > 0) { d = (int64_t)std::min<u64>(tb_ticks_to_ns((u64)d), (u64)INT64_MAX); memcpy(e + 32, &d, 8); }
        if (ff & kLeeway) { u64 l; memcpy(&l, e + 48, 8); l = tb_ticks_to_ns(l); memcpy(e + 48, &l, 8); }
    }
}
static Handler timebase_handler(const std::string &n) {
    if (!timebase_apple()) return nullptr;
    // struct kevent (32 B): fflags +12, data +16. kevent64_s (48 B): fflags +12, data +16, ext[1] +40.
    // kevent_qos_s (72 B): qos +12, udata +16, fflags +24, xflags +28, data +32, ext[4] +40 (leeway ext[1] +48).
    static const std::map<std::string, Handler> m = {
        {"_mach_absolute_time", h_tb_ret}, {"_mach_absolute_time_kernel", h_tb_ret}, {"_mach_continuous_time", h_tb_ret},
        {"_mach_continuous_time_kernel", h_tb_ret}, {"_mach_approximate_time", h_tb_ret},
        {"_mach_continuous_approximate_time", h_tb_ret}, {"_kdebug_timestamp", h_tb_ret},
        {"_mach_timebase_info", h_tb_info}, {"_mach_timebase_info_trap", h_tb_info}, {"_mach_get_times", h_tb_get_times},
        {"_mk_timer_cancel", h_tb_out<1>}, {"_mach_wait_until", h_tb_in<0>}, {"_mk_timer_arm", h_tb_in<1>},
        {"_mk_timer_arm_leeway", h_tb_in<2, 3>},
        // x86Sim: mach eventlink deadlines (os_eventlink: AUAudioUnit's out-of-process render pipe); unconverted, the
        // 24 MHz guest deadline was already past in Darling's ns clock and every render wait timed out at once
        {"_mach_eventlink_wait_until", h_tb_in<4>}, {"_mach_eventlink_signal_wait_until", h_tb_in<5>},
        {"___mach_eventlink_wait_until", h_tb_in<2>}, {"___mach_eventlink_signal_wait_until", h_tb_in<3>},
        {"_kevent", h_tb_kevent<32, 12, 16, -1>}, {"_kevent64", h_tb_kevent<48, 12, 16, 40>},
        {"_kevent_qos", h_tb_kevent<72, 24, 32, 48>}, {"_kevent_id", h_tb_kevent<72, 24, 32, 48>},
    };
    auto it = m.find(n);
    return it == m.end() ? nullptr : it->second;
}

// geteuid() as libAccessibility sees it: the Mac user (501), not root. A simulator process runs as the Mac user, but
// Darling answers 0 for every process. iOS 27's libAccessibility reads its preferences directly unless the caller is
// root; then it asks the AX server in backboardd over IPC with a 1 s timeout. backboardd is "root" too, so it blocked on
// its own server, and every app's AX preference read (a dozen at Settings' launch: button shapes, reduce motion, ...)
// waited out the timeout: Settings showed a black screen for ~17 s. Only calls from libAccessibility's code: launchd_sim's
// domain is uid 0, and a non-root launchd refused to bootstrap any job. X86SIM_A64_AX_EUID overrides (0: as before).
static u64 g_ax_lo, g_ax_hi;
void ax_euid_prepare(const std::string &cache) {
    cache_exports(cache, "/usr/lib/libAccessibility.dylib", nullptr, &g_ax_lo, &g_ax_hi);
}
static void h_geteuid(GuestThread &t, u32) {
    static const u64 ax = [] { const char *e = getenv("X86SIM_A64_AX_EUID"); return e ? strtoull(e, nullptr, 10) : 501ull; }();
    static auto *dgeteuid = (uid_t (*)())dsym("geteuid");
    const u64 lr = t.x(30);
    if (ax && lr >= g_ax_lo && lr < g_ax_hi) { t.set_x(0, ax); return; }
    t.set_x(0, dgeteuid ? (u64)dgeteuid() : 0);
}

// Special handlers that don't use g_thunks[i].native (everything else does)
bool special_needs_native(const std::string &n) {
    static const char *own[] = {"___libkernel_init", "_pthread_create_with_workgroup_np", "__simple_dprintf", "__simple_vdprintf",
                                "__simple_sprintf", "__simple_vsprintf", "__simple_esprintf", "__simple_vesprintf",
                                "____chkstk_darwin", "_thread_chkstk_darwin"};
    for (const char *o : own) if (n == o) return false;
    return true;
}
// Speed 28: the simulator's libsystem_platform re-exports the host's, so sys_icache_invalidate / sys_cache_control
// reached Darling's x86_64 libplatform, where they do nothing: no guest IC IVAU ever ran, and code a process writes
// at an address it ran before (JavaScriptCore's JIT reusing freed executable memory) kept its stale translation.
// WebContent then ran old code over new data (NULL reads in JIT code on en.wikipedia.org; with the AOT image JSC is
// fast enough to tier up and recycle code). They now invalidate the range in the JIT, as an arm64 IC IVAU loop would.
// X86SIM_A64_ICACHE_NATIVE=0: the old no-op (debug).
static void icache_invalidate(GuestThread &t, u64 a, u64 n) {
    static const bool off = getenv("X86SIM_A64_ICACHE_NATIVE") && atoi(getenv("X86SIM_A64_ICACHE_NATIVE")) == 0;
    if (!n || !t.jit || off) return;
    const u64 lo = a & ~u64(63), hi = (a + n + 63) & ~u64(63);
    if (getenv("X86SIM_A64_ICLOG")) logf("sys_icache_invalidate %#lx +%#lx", (unsigned long)a, (unsigned long)n);
    t.jit->InvalidateCacheRange(lo, hi - lo);
}
static void h_icache_invalidate(GuestThread &t, u32) { icache_invalidate(t, t.x(0), t.x(1)); }
static void h_cache_control(GuestThread &t, u32) {
    // int sys_cache_control(int function, void *start, size_t len): 1 = kCacheFunctionPrepareForExecution,
    // 2 = kCacheFunctionFlushDcache (nothing to do here), other functions: ENOTSUP
    const u64 fn = t.x(0) & 0xffffffffu;
    if (fn == 1) icache_invalidate(t, t.x(1), t.x(2));
    t.set_x(0, fn == 1 || fn == 2 ? 0 : 45);
}

// RAM 6: see g_cache_prot_mu (host.cpp file trim)
template <Handler H> static void h_cachelock(GuestThread &t, u32 i) {
    std::shared_lock g(g_cache_prot_mu);
    H(t, i);
}
Handler special_handler(const std::string &n, int *nfixed, const char **native_name) {
    static const std::map<std::string, int> variadic = {
        {"_open", 2}, {"_open$NOCANCEL", 2}, {"_openat", 3}, {"_openat$NOCANCEL", 3}, {"_fcntl", 2}, {"_fcntl$NOCANCEL", 2},
        {"_ioctl", 2}, {"_syscall", 1}, {"_semctl", 3}, {"_sem_open", 2}, {"_shm_open", 2}, {"_msgsys", 1}, {"_semsys", 1},
        {"_shmsys", 1}, {"_open_dprotected_np", 4}, {"_openat_dprotected_np", 5}, {"_guarded_open_np", 4},
        {"_guarded_open_dprotected_np", 6}, {"_panic", 1},
    };
    if (auto it = variadic.find(n); it != variadic.end()) { *nfixed = it->second; return h_variadic; }
    // Darling (x86_64) keeps the 32-bit-inode structs under the plain names; arm64 only has the 64-bit ones.
    static const std::map<std::string, const char *> renamed = {
        {"_stat", "stat$INODE64"}, {"_fstat", "fstat$INODE64"}, {"_lstat", "lstat$INODE64"}, {"_fstatat", "fstatat$INODE64"},
        {"_statfs", "statfs$INODE64"}, {"_fstatfs", "fstatfs$INODE64"}, {"_getfsstat", "getfsstat$INODE64"},
        {"___stat", "stat$INODE64"}, {"___fstat", "fstat$INODE64"}, {"___lstat", "lstat$INODE64"},
        {"___fstatat", "fstatat$INODE64"}, {"___statfs", "statfs$INODE64"}, {"___fstatfs", "fstatfs$INODE64"},
        {"___getfsstat", "getfsstat$INODE64"}, {"_getdirentries", "__getdirentries64"},
        {"_mach_absolute_time_kernel", "mach_absolute_time"}, {"_mach_continuous_time_kernel", "mach_continuous_time"},
        {"_cthread_yield", "sched_yield"},
    };
    const auto ren = renamed.find(n);
    if (ren != renamed.end()) *native_name = ren->second;
    if (Handler h = timebase_handler(n)) return h;  // (the *_kernel variants with their renamed native)
    if (ren != renamed.end()) return h_generic;
    static const std::map<std::string, Handler> special = {
        {"____chkstk_darwin", h_noop}, {"_thread_chkstk_darwin", h_noop}, {"_geteuid", h_geteuid},
        {"_sys_icache_invalidate", h_icache_invalidate}, {"_sys_cache_control", h_cache_control}, {"_sys_dcache_flush", h_noop},
        {"___libkernel_init", h_libkernel_init}, {"___libkernel_platform_init", h_zero}, {"___libkernel_voucher_init", h_zero},
        {"___libkernel_init_after_boot_tasks", h_zero}, {"___libplatform_init", h_zero}, {"___pthread_init", h_zero},
        {"___pthread_late_init", h_zero}, {"_mach_init", h_zero}, {"__pthread_yield_to_enqueuer_4dispatch", h_zero},
        {"__pthread_mutex_enable_legacy_mode", h_zero}, {"_pthread_prefer_alternate_cluster_self", h_zero},
        {"_pthread_create", h_pthread_create}, {"_pthread_create_suspended_np", h_pthread_create},
        {"_pthread_create_from_mach_thread", h_pthread_create}, {"_pthread_create_with_workgroup_np", h_pthread_create_with_workgroup},
        {"_pthread_once", h_callbacks<1>}, {"_pthread_atfork", h_callbacks<0, 1, 2>},
        {"_pthread_get_stackaddr_np", h_stackaddr}, {"_pthread_get_stacksize_np", h_stacksize},
        {"_pthread_key_create", h_key_create}, {"_pthread_key_init_np", h_key_init_np}, {"_pthread_key_delete", h_key_delete},
        {"__os_once", h_callbacks<2>}, {"__os_alloc_once", h_callbacks<2>},
        {"__pthread_workqueue_init", h_callbacks<0>}, {"__pthread_workqueue_init_with_kevent", h_callbacks<0, 1>},
        {"__pthread_workqueue_init_with_workloop", h_callbacks<0, 1, 2>}, {"_pthread_workqueue_setdispatch_np", h_callbacks<0>},
        {"_pthread_workqueue_setup", h_workqueue_setup}, {"_pthread_introspection_hook_install", h_introspection_hook},
        {"_mach_msg_server", h_callbacks<0>}, {"_mach_msg_server_once", h_callbacks<0>},
        {"_mach_msg_server_importance", h_callbacks<0>}, {"___sigaction", h_sigaction}, {"___platform_sigaction", h_platform_sigaction},
        {"_mach_vm_map", h_cachelock<h_vm_map>}, {"_vm_map", h_cachelock<h_vm_map>}, {"_mach_vm_remap", h_cachelock<h_vm_remap>},
        {"_vm_remap", h_cachelock<h_vm_remap>}, {"_mach_vm_remap_new", h_cachelock<h_vm_remap>},
        {"_vm_remap_new", h_cachelock<h_vm_remap>}, {"_mach_vm_allocate", h_cachelock<h_vm_allocate>},
        {"_vm_allocate", h_cachelock<h_vm_allocate>}, {"_mmap", h_cachelock<h_mmap>}, {"_munmap", h_munmap}, {"___munmap", h_munmap},
        {"_madvise", h_madvise}, {"___madvise", h_madvise}, {"_mincore", h_mincore},
        {"_mach_vm_behavior_set", h_behavior_set}, {"_vm_behavior_set", h_behavior_set},
        {"_mach_vm_deallocate", h_vm_deallocate}, {"_vm_deallocate", h_vm_deallocate}, {"___mmap", h_cachelock<h_mmap>},
        {"_mprotect", h_cachelock<h_generic>}, {"___mprotect", h_cachelock<h_generic>},
        {"_mach_vm_protect", h_cachelock<h_generic>}, {"_vm_protect", h_cachelock<h_generic>},
        {"__kernelrpc_mach_vm_protect_trap", h_cachelock<h_generic>}, {"_mach_msg_overwrite", h_msg_overwrite}, {"_mach_msg", h_mach_msg},
        {"__exit", h_exit}, {"___exit", h_exit}, {"_abort_with_payload", h_abort_with}, {"_abort_with_reason", h_abort_with}, {"_pthread_exit", h_pthread_exit}, {"___pthread_kill", h_kill_like}, {"_pthread_kill", h_kill_like},
        {"___kill", h_kill_like}, {"_kill", h_kill_like},
        {"_thread_get_state", h_thread_get_state}, {"_thread_set_state", h_thread_set_state}, {"_thread_get_register_pointer_values", h_thread_get_register_pointer_values},
        {"___abort_with_payload", h_abort_with},
        {"_exception_raise_state", h_stack_args<8>}, {"_exception_raise_state_identity", h_stack_args<4, 8, 8>},
        {"_host_swap_exception_ports", h_stack_args<8, 8>}, {"_task_swap_exception_ports", h_stack_args<8, 8>},
        {"_thread_swap_exception_ports", h_stack_args<8, 8>}, {"_kext_request", h_stack_args<8>},
        {"_mach_msg_overwrite_trap", h_stack_args<4>}, {"_task_register_dyld_shared_cache_image_info", h_dyld_cache_info},
        // security_token_t (8 B) + audit_token_t (32 B) by value: not used by the simulator, Darling has no host_security
        {"_host_security_create_task_token", h_missing}, {"_host_security_set_task_token", h_missing},
        {"__simple_dprintf", h_simple_dprintf}, {"__simple_vdprintf", h_simple_vdprintf},
        {"__simple_sprintf", h_simple_sprintf}, {"__simple_vsprintf", h_simple_vsprintf},
        {"__simple_esprintf", h_simple_esprintf}, {"__simple_vesprintf", h_simple_vesprintf},
    };
    if (auto it = special.find(n); it != special.end()) return it->second;
    // bool results: x86 callees only define al; arm64 callers expect w0 zero-extended.
    if (n.find("CompareAndSwap") != std::string::npos || n.find("TestAnd") != std::string::npos ||
        n.find("trylock") != std::string::npos || n.find("Try") != std::string::npos || n == "_kdebug_is_enabled" ||
        n == "_kdebug_using_continuous_time")
        return h_generic_bool;
    return nullptr;
}

// ---- setjmp family as guest code -----------------------------------------------------------------------------------
// jmp_buf (ours, private to these functions): x19-x28, x29, x30, sp, d8-d15. The signal mask is not saved.
// pthread_getspecific/setspecific/_pthread_setspecific_static: guest code on the guest's TSD array (jit.cpp).
bool is_guest_code_export(const std::string &n) {
    if (is_guest_libc_export(n)) return true;
    if (n == "_pthread_getspecific" || n == "_pthread_setspecific" || n == "__pthread_setspecific_static") return true;
    if (n == "_mach_absolute_time" && timebase_apple()) return true;
    return n == "_setjmp" || n == "__setjmp" || n == "_sigsetjmp" || n == "_longjmp" || n == "__longjmp" || n == "_siglongjmp";
}
size_t emit_guest_code(const std::string &n, uint32_t *o, u32 slow) {
    if (is_guest_libc_export(n)) return emit_guest_libc(n, o, slow);
    if (n == "_mach_absolute_time") {  // 125/3 timebase: the counter is mach time (no svc round trip)
        o[0] = 0xD53BE020; o[1] = 0xD65F03C0;  // mrs x0, cntpct_el0; ret
        return 2;
    }
    if (n == "_pthread_getspecific") {
        static const uint32_t c[] = {0xD53BD068, 0xF8607900, 0xD65F03C0};  // mrs x8, tpidrro_el0; ldr x0, [x8, x0, lsl #3]; ret
        memcpy(o, c, sizeof c);
        return 3;
    }
    if (n == "_pthread_setspecific" || n == "__pthread_setspecific_static") {  // the guest's own TSD array
        static const uint32_t c[] = {
            0xD53BD068,  // mrs x8, tpidrro_el0
            0xF8207901,  // str x1, [x8, x0, lsl #3]
            0x52800000,  // mov w0, #0
            0xD65F03C0,  // ret
        };
        memcpy(o, c, sizeof c);
        return 4;
    }
    static const uint32_t setjmp_code[] = {
        0xA9005013,  // stp x19, x20, [x0]
        0xA9015815,  // stp x21, x22, [x0, #16]
        0xA9026017,  // stp x23, x24, [x0, #32]
        0xA9036819,  // stp x25, x26, [x0, #48]
        0xA904701B,  // stp x27, x28, [x0, #64]
        0xA905781D,  // stp x29, x30, [x0, #80]
        0x910003E1,  // mov x1, sp
        0xF9003001,  // str x1, [x0, #96]
        0x6D07A408,  // stp d8, d9, [x0, #120]
        0x6D08AC0A,  // stp d10, d11, [x0, #136]
        0x6D09B40C,  // stp d12, d13, [x0, #152]
        0x6D0ABC0E,  // stp d14, d15, [x0, #168]
        0x52800000,  // mov w0, #0
        0xD65F03C0,  // ret
    };
    static const uint32_t longjmp_code[] = {
        0xA9405013,  // ldp x19, x20, [x0]
        0xA9415815,  // ldp x21, x22, [x0, #16]
        0xA9426017,  // ldp x23, x24, [x0, #32]
        0xA9436819,  // ldp x25, x26, [x0, #48]
        0xA944701B,  // ldp x27, x28, [x0, #64]
        0xA945781D,  // ldp x29, x30, [x0, #80]
        0xF9403002,  // ldr x2, [x0, #96]
        0x9100005F,  // mov sp, x2
        0x6D47A408,  // ldp d8, d9, [x0, #120]
        0x6D48AC0A,  // ldp d10, d11, [x0, #136]
        0x6D49B40C,  // ldp d12, d13, [x0, #152]
        0x6D4ABC0E,  // ldp d14, d15, [x0, #168]
        0x7100003F,  // cmp w1, #0
        0x1A9F1420,  // csinc w0, w1, wzr, ne
        0xD65F03C0,  // ret
    };
    bool lj = n.find("longjmp") != std::string::npos;
    const uint32_t *src = lj ? longjmp_code : setjmp_code;
    size_t cnt = lj ? sizeof longjmp_code / 4 : sizeof setjmp_code / 4;
    memcpy(o, src, cnt * 4);
    return cnt;
}

}  // namespace a64
