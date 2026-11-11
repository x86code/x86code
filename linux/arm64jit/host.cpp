#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/personality.h>
#include <algorithm>
#include <malloc.h>
#include <thread>
#include <map>
#include <unordered_set>
#include <array>
#include <mutex>
#include <string>
// libarm64jit: process setup. Called by the x86_64 host program (host/arm64host) after Darling's libSystem is up.
// Maps the arm64 main executable and dyld_sim, writes the 16K arm64 commpage, builds the stub dylibs for the host
// libraries, then runs _dyld_sim_prepare() and main under the JIT on this (the main) thread. dyld_sim maps the
// runtime's prebuilt shared cache itself (fixed at 0x1C0000000) through the SyscallHelpers table we hand it.
#include "a64.h"
namespace Dynarmic::Backend { bool IsJitCodeAddress(unsigned long host_pc); }
#include "macho.h"
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <ucontext.h>
#include <execinfo.h>
#include <dlfcn.h>

namespace a64 {
bool g_step = getenv("X86SIM_A64_STEP") != nullptr;  // one instruction per Run (exact fault PCs)

const DarwinApi *g_darwin;
// Speed 19: Darling's x86_64 libsystem_platform fills generically: bzero and memset are memset_pattern4, which calls
// memmove once per 4 bytes (a 12.6 MB full-screen bitmap clear = 3.1M calls; ~25% of SpringBoard's main thread when an
// app opens). Guest calls bind to these instead (glibc memset; pattern fills double in place with memcpy). Darling's
// own native callers keep theirs.
namespace {
void fast_bzero(void *p, size_t n) { memset(p, 0, n); }
void *fast_memset(void *p, int c, size_t n) { return memset(p, c, n); }
template <size_t W> void fast_pattern(void *dst, const void *pat, size_t n) {
    auto *d = static_cast<unsigned char *>(dst);
    if (n <= W) { memcpy(d, pat, n); return; }
    memcpy(d, pat, W);
    size_t done = W;
    while (done < n) {  // double the filled prefix (it stays pattern-aligned)
        const size_t k = done < n - done ? done : n - done;
        memcpy(d + done, d, k);
        done += k;
    }
}
const struct { const char *n; void *f; } kFast[] = {
    {"_platform_bzero", (void *)fast_bzero}, {"bzero", (void *)fast_bzero}, {"__bzero", (void *)fast_bzero},
    {"_platform_memset", (void *)fast_memset}, {"memset", (void *)fast_memset},
    {"_platform_memset_pattern4", (void *)fast_pattern<4>}, {"memset_pattern4", (void *)fast_pattern<4>},
    {"_platform_memset_pattern8", (void *)fast_pattern<8>}, {"memset_pattern8", (void *)fast_pattern<8>},
    {"_platform_memset_pattern16", (void *)fast_pattern<16>}, {"memset_pattern16", (void *)fast_pattern<16>},
};
}  // namespace
bool is_fast_fill(const void *fn) {
    for (const auto &f : kFast) if (f.f == fn) return true;
    return false;
}
void *dsym(const char *name) {
    if (!(getenv("X86SIM_A64_FASTFILL") && atoi(getenv("X86SIM_A64_FASTFILL")) == 0))
        for (const auto &f : kFast) if (!strcmp(name, f.n)) return f.f;
    return g_darwin->dlsym((void *)-2 /* RTLD_DEFAULT */, name);
}

static int (*d_open)(const char *, int, ...);
static timespec g_t0;
static double ms_since(const timespec &a) { timespec b; clock_gettime(CLOCK_MONOTONIC, &b); return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6; }

// ---- Mach-O mapping ----------------------------------------------------------------------------------------------
struct Mapped { u64 mh = 0, slide = 0, entry = 0; };

static Mapped map_macho(const std::string &path, bool want_unixthread) {
    int fd = d_open(path.c_str(), O_RDONLY);
    if (fd < 0 && path[0] == '/' && path.compare(0, 20, "/Volumes/SystemRoot/"))  // a Linux path from mldr
        fd = d_open(("/Volumes/SystemRoot" + path).c_str(), O_RDONLY);
    if (fd < 0) die("cannot open %s (errno %d)", path.c_str(), *g_darwin->error());
    struct stat st; fstat(fd, &st);
    auto *file = (const uint8_t *)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (file == MAP_FAILED) die("cannot map %s", path.c_str());
    u64 slice = 0;
    uint32_t magic; memcpy(&magic, file, 4);
    if (magic == 0xbebafecau) {  // fat: the arm64 slice
        uint32_t n = __builtin_bswap32(*(const uint32_t *)(file + 4));
        bool found = false;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *a = file + 8 + i * 20;
            if (__builtin_bswap32(*(const uint32_t *)a) == (uint32_t)CPU_TYPE_ARM64) { slice = __builtin_bswap32(*(const uint32_t *)(a + 8)); found = true; }
        }
        if (!found) die("%s has no arm64 slice", path.c_str());
    }
    auto *mh = (const mach_header_64 *)(file + slice);
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) die("%s is not an arm64 Mach-O", path.c_str());
    if ((mh->cpusubtype & 0xff) == 2) die("%s is arm64e (not supported)", path.c_str());
    u64 lo = ~0ull, hi = 0, pc = 0, entryoff = 0;
    const uint8_t *lc = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const load_command *)lc)->cmdsize) {
        auto *sg = (const segment_command_64 *)lc;
        if (sg->cmd == LC_SEGMENT_64 && !(sg->initprot == 0 && sg->filesize == 0)) {
            lo = std::min(lo, sg->vmaddr); hi = std::max(hi, sg->vmaddr + sg->vmsize);
        } else if (sg->cmd == LC_UNIXTHREAD) {
            pc = *(const u64 *)(lc + 16 + 32 * 8);  // ARM_THREAD_STATE64: x0-x28, fp, lr, sp, pc
        } else if (sg->cmd == LC_MAIN) entryoff = ((const entry_point_command *)lc)->entryoff;
    }
    // Prefer the link address (slide 0); otherwise anywhere. Speed 14: an executable in the placement table goes to
    // its slot in the cache window (reserved by then), so its translations persist like the cache's.
    u64 size = hi - lo;
    void *base = MAP_FAILED;
    // Speed 25: dyld_sim too (its slot was in every runtime's table but it was always mapped "anywhere", so its
    // ~1.6 s of prepare code per process was translated live in every process, never persisted).
    const bool is_dyld = path.size() >= 17 && path.compare(path.size() - 17, 17, "/usr/lib/dyld_sim") == 0;
    if (const Placement *pl = want_unixthread && !is_dyld ? nullptr : placement_find(path.c_str()); pl && size <= pl->slot && placement_claim(pl, fd)) {
        base = mmap((void *)pl->addr, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0);
        if (getenv("X86SIM_A64_STATS")) logf("placement: exe %s at %#lx", pl->key.c_str(), (unsigned long)pl->addr);
    }
    if (base == MAP_FAILED)
        base = mmap((void *)lo, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | (lo ? MAP_FIXED_NOREPLACE : 0), -1, 0);
    if (base == MAP_FAILED) base = mmap(nullptr, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (base == MAP_FAILED) die("no address space for %s", path.c_str());
    Mapped m; m.slide = (u64)base - lo;
    lc = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const load_command *)lc)->cmdsize) {
        auto *sg = (const segment_command_64 *)lc;
        if (sg->cmd != LC_SEGMENT_64 || (sg->initprot == 0 && sg->filesize == 0)) continue;
        int prot = (sg->initprot & 1 ? PROT_READ : 0) | (sg->initprot & 2 ? PROT_WRITE : 0);  // guest code is never host-executed
        if (!prot) prot = PROT_READ;
        if (sg->filesize) {
            void *p = mmap((void *)(sg->vmaddr + m.slide), sg->filesize, prot | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, slice + sg->fileoff);
            if (p == MAP_FAILED) die("cannot map %s %s", path.c_str(), sg->segname);
        }
        if (sg->vmsize > sg->filesize) {
            u64 a = (sg->vmaddr + m.slide + sg->filesize + 4095) & ~4095ull, e = sg->vmaddr + m.slide + sg->vmsize;
            if (e > a) mmap((void *)a, e - a, prot | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        }
        if (sg->fileoff == 0 && sg->filesize) m.mh = sg->vmaddr + m.slide;
    }
    munmap((void *)file, st.st_size);
    close(fd);
    m.entry = want_unixthread ? pc + m.slide : (entryoff ? m.mh + entryoff : 0);
    return m;
}

// ---- commpage ------------------------------------------------------------------------------------------------------
static void map_commpage() {
    constexpr u64 kBase = 0xFFFFFC000ull;
    auto *p = (uint8_t *)mmap((void *)kBase, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (p != (uint8_t *)kBase) { logf("warning: cannot map the arm64 commpage at %#lx", (unsigned long)kBase); return; }
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu > 255) ncpu = 255;
    memcpy(p, "commpage 64-bit", 16);
    u64 caps = 0x00000020 /* kCache64 */ | 0x100 /* kHasNeon */ | 0x400 /* kHasVfp */ | 0x2000 /* kHasFMA */ |
               0x01000000 /* kHasARMv8Crypto */ | 0x02000000 /* kHasARMv81Atomics */ | 0x04000000 /* kHasARMv8Crc32 */ |
               ((u64)ncpu << 16);
    memcpy(p + 0x10, &caps, 8);
    uint16_t ver = 3; memcpy(p + 0x1E, &ver, 2);
    uint32_t caps32 = (uint32_t)caps; memcpy(p + 0x20, &caps32, 4);
    p[0x22] = (uint8_t)ncpu;
    p[0x24] = 14; p[0x25] = 14;  // user page shift 32/64: 16K
    uint16_t line = 64; memcpy(p + 0x26, &line, 2);
    p[0x34] = p[0x35] = p[0x36] = (uint8_t)ncpu;
    p[0x37] = 14;
    u64 mem = (u64)sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE); memcpy(p + 0x38, &mem, 8);
    uint32_t family = 0x1b588bb3; memcpy(p + 0x80, &family, 4);  // CPUFAMILY_ARM_FIRESTORM_ICESTORM (M1)
    mprotect(p, 0x4000, PROT_READ);
}

// ---- SyscallHelpers (dyld_sim's view of the host dyld) -------------------------------------------------------------
// Speed 14: dyld_sim opens an image, reads its header, then reserves the image's whole range "anywhere" and maps the
// segments into it. Anywhere was Linux's top-down placement, so the address depended on every earlier host mapping
// (78 of 115 non-cache code mappings moved between boots). The reservation that follows the open of a file in the
// placement table goes to that file's slot instead (file size/mtime checked; once per process).
static thread_local const Placement *tl_open_place;
static thread_local int tl_open_fd = -1;

// Perf 1: the sim cache records no inode/mtime for its images (all 0) and expects them on disk, so dyld_sim takes any
// file at a cached image's path for a root: it loads that copy instead of the cache's and counts an overridden cached
// dylib, which turns off libswiftCore's use of the cache's precomputed conformance tables in every process (see
// dyldsim.cpp patch_overridden). ensure-metal-framework.sh puts such a copy at Metal.framework/Metal (CFBundle and the
// MTLCompilerService XPC lookup need the file; dyld must not use it). dyld_sim's stat and open answer ENOENT for every
// path under the runtime root that names an image of the cache, so dyld takes the cache's copy (one copy of Metal's
// ObjC classes, already translated in the image); everything else in the process (CFBundle, xpc) uses the native calls
// and still finds the file. The libsystem stub dylibs are answered before this (stub_fd_for_path).
// X86SIM_A64_DYLD_HIDE_CACHED=0 shows those files to dyld_sim again.
static std::string g_sim_root;
static std::unordered_set<std::string> g_cached_paths;
static void load_cached_paths(const std::string &cache, const std::string &root) {
    if (const char *e = getenv("X86SIM_A64_DYLD_HIDE_CACHED"); e && atoi(e) == 0) return;
    int fd = d_open(cache.c_str(), O_RDONLY);
    if (fd < 0) return;
    uint8_t h[0x200];
    if (pread(fd, h, sizeof h, 0) == (ssize_t)sizeof h) {
        uint32_t io, ic;  // dyld_cache_header.imagesOffset / imagesCount (0x1c0 / 0x1c4)
        memcpy(&io, h + 0x1c0, 4);
        memcpy(&ic, h + 0x1c4, 4);
        if (io && ic && ic < 20000) {
            std::vector<uint8_t> raw((size_t)ic * 32);
            if (pread(fd, raw.data(), raw.size(), io) == (ssize_t)raw.size()) {
                g_cached_paths.reserve(ic);
                for (uint32_t i = 0; i < ic; i++) {
                    uint32_t po;  // dyld_cache_image_info.pathFileOffset
                    memcpy(&po, raw.data() + (size_t)i * 32 + 24, 4);
                    char p[512];
                    ssize_t n = pread(fd, p, sizeof p - 1, po);
                    if (n <= 0) continue;
                    p[n] = 0;
                    g_cached_paths.emplace(p);
                }
            }
        }
    }
    close(fd);
    if (!g_cached_paths.empty()) g_sim_root = root;
}
// path names a shared-cache image under the runtime root (the cache's own copy is used, not this file)
static bool dyld_hides(const char *path) {
    if (g_sim_root.empty() || strncmp(path, g_sim_root.c_str(), g_sim_root.size()) != 0) return false;
    const char *rel = path + g_sim_root.size();
    while (rel[0] == '/' && rel[1] == '/') rel++;
    return *rel == '/' && g_cached_paths.count(rel);
}
static void set_guest_errno(int e) {
    static auto *derr = (int *(*)())dsym("__error");
    if (derr) *derr() = e;
}

// Perf 8: the libsystem stub dylibs go to a fixed address just below the cache window in every process (they went
// anywhere, so every cache GOT entry for libsystem held a different value in each process and the builder). With one
// address, A64StubLinkPass links the cache's libsystem import stubs straight to the stub (guarded), in the image too.
// X86SIM_A64_STUB_FIXED=0: anywhere.
static thread_local u64 tl_stub_addr;
u64 stub_fixed_address(const char *install) {
    static const bool on = !(getenv("X86SIM_A64_STUB_FIXED") && atoi(getenv("X86SIM_A64_STUB_FIXED")) == 0);
    if (!on) return 0;
    if (!strcmp(install, "/usr/lib/system/libsystem_kernel.dylib")) return kStubBase;
    if (!strcmp(install, "/usr/lib/system/libsystem_platform.dylib")) return kStubBase + kStubSlot;
    if (!strcmp(install, "/usr/lib/system/libsystem_pthread.dylib")) return kStubBase + 2 * kStubSlot;
    return 0;
}
static void h_helper_open(GuestThread &t, u32) {
    const char *path = (const char *)t.x(0);
    int fd = stub_fd_for_path(path);
    tl_stub_addr = fd >= 0 ? stub_fixed_address(path) : 0;
    if (fd < 0 && dyld_hides(path)) {
        if (g_trace) logf("dyld_sim open %s -> hidden (cache image)", path);
        set_guest_errno(2);  // ENOENT
        tl_open_place = nullptr;
        tl_open_fd = -1;
        t.set_x(0, (u64)(int64_t)-1);
        return;
    }
    if (fd < 0) fd = d_open(path, (int)t.x(1), (int)t.stack_slot(0));
    if (g_trace) logf("dyld_sim open %s -> %d", path, fd);
    tl_open_place = fd >= 0 ? placement_find(path) : nullptr;
    // RAM 14: placement keys are real paths; a framework moved into the OS cryptex is opened through its symlink
    // (System/Library/PrivateFrameworks/MobileSafariUI.framework -> ../../../System/Cryptexes/OS/...), so the suffix
    // never matched and it loaded "anywhere", never trained or in the image. Retry with the opened file's real path.
    if (fd >= 0 && !tl_open_place) {
        char lp[64], real[4096];
        snprintf(lp, sizeof lp, "/proc/self/fd/%d", fd);
        if (ssize_t n = readlink(lp, real, sizeof real - 1); n > 0) {
            real[n] = 0;
            tl_open_place = placement_find(real);
        }
    }
    tl_open_fd = fd;
    t.set_x(0, (u64)(int64_t)fd);
}
static u64 place_reservation(u64 size, int prot) {
    if (u64 a = tl_stub_addr) {
        tl_stub_addr = 0;
        if (size && size <= kStubSlot) {
            void *p = mmap((void *)a, size, prot, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0);  // in the reserved window
            if (p == (void *)a) return a;
            if (p != MAP_FAILED) munmap(p, size);
        }
        if (getenv("X86SIM_A64_STATS")) logf("stub dylib not at %#lx (reserve %#lx)", (unsigned long)a, (unsigned long)size);
        return 0;
    }
    const Placement *pl = tl_open_place;
    tl_open_place = nullptr;
    if (!pl || !size || size > pl->slot || !placement_claim(pl, tl_open_fd)) {
        if (pl && getenv("X86SIM_A64_STATS")) logf("placement: %s not placed (reserve %#lx, slot %#lx)", pl->key.c_str(), (unsigned long)size, (unsigned long)pl->slot);
        return 0;
    }
    void *p = mmap((void *)pl->addr, size, prot, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) return 0;
    if (getenv("X86SIM_A64_STATS")) logf("placement: %s at %#lx", pl->key.c_str(), (unsigned long)pl->addr);
    return pl->addr;
}
// vm_allocate(task, addr*, size, flags)
static void h_helper_vm_allocate(GuestThread &t, u32 i) {
    if ((t.x(3) & 1) && t.x(1))
        // vm_allocate memory is zeroed read/write (dyld leaves zero-fill tails of segments in it)
        if (u64 a = place_reservation(t.x(2), PROT_READ | PROT_WRITE)) { *(u64 *)t.x(1) = a; t.set_x(0, 0); return; }
    h_generic(t, i);
}
// mmap(addr, len, prot, flags, fd, off): an anonymous non-fixed reservation
static void h_helper_mmap(GuestThread &t, u32 i) {
    constexpr u64 kFixed = 0x10, kAnon = 0x1000;
    if (!t.x(0) && !(t.x(3) & kFixed) && (t.x(3) & kAnon))
        if (u64 a = place_reservation(t.x(1), (int)t.x(2) & 7)) {
            t.set_x(0, a);
            return;
        }
    h_generic(t, i);
}
static void h_helper_stat(GuestThread &t, u32) {
    static auto *dstat = (int (*)(const char *, void *))dsym("stat$INODE64");
    static auto *dfstat = (int (*)(int, void *))dsym("fstat$INODE64");
    int fd = stub_fd_for_path((const char *)t.x(0));
    int r;
    if (fd >= 0) { r = dfstat(fd, (void *)t.x(1)); close(fd); }
    else if (dyld_hides((const char *)t.x(0))) { set_guest_errno(2); r = -1; }  // ENOENT: dyld uses the cache's copy
    else r = dstat((const char *)t.x(0), (void *)t.x(1));
    t.set_x(0, (u64)(int64_t)r);
}
// fcntl(fd, cmd, ...): F_GETPATH (50) on a stub dylib answers its real copy's path (stub_real_copy)
static void h_helper_fcntl(GuestThread &t, u32 i) {
    if ((int)t.x(1) == 50)
        if (const char *p = stub_path_for_fd((int)t.x(0))) {
            snprintf((char *)t.stack_slot(0), 1024, "%s", p);  // MAXPATHLEN
            t.set_x(0, 0);
            return;
        }
    h_variadic(t, i);
}
static void h_helper_vlog(GuestThread &t, u32) {
    std::string s = guest_format((const char *)t.x(0), (const u64 *)t.x(1));
    if (write(2, s.data(), s.size()) < 0) {}
}
static u64 g_all_image_infos[512];
static void h_helper_process_info(GuestThread &t, u32) {
    if (!g_all_image_infos[0]) g_all_image_infos[0] = 17;  // version
    t.set_x(0, (u64)g_all_image_infos);
}
static void h_helper_amfi(GuestThread &t, u32) {  // amfi_check_dyld_policy_self(in, &out): allow everything
    if (t.x(1)) *(u64 *)t.x(1) = 0x7f;
    t.set_x(0, 0);
}
static void h_helper_notify_get(GuestThread &t, u32 i) {
    if (g_thunks[i].native) { h_generic(t, i); return; }
    if (t.x(1)) *(uint32_t *)t.x(1) = 0;
    t.set_x(0, 0);
}

static u64 build_syscall_helpers() {
    struct H { const char *native; Handler h; };
    static const H table[] = {
        {"open", h_helper_open}, {"close", nullptr}, {"pread", nullptr}, {"write", nullptr}, {"mmap", h_helper_mmap},
        {"munmap", nullptr}, {"madvise", nullptr}, {"stat", h_helper_stat}, {"fcntl", h_helper_fcntl}, {"ioctl", h_variadic},
        {"issetugid", nullptr}, {"getcwd", nullptr}, {"realpath$DARWIN_EXTSN", nullptr}, {"vm_allocate", h_helper_vm_allocate},
        {"vm_deallocate", nullptr}, {"vm_protect", nullptr}, {"vlog", h_helper_vlog}, {"vwarn", h_helper_vlog},
        {"pthread_mutex_lock", nullptr}, {"pthread_mutex_unlock", nullptr}, {"mach_thread_self", nullptr},
        {"mach_port_deallocate", nullptr}, {"task_self_trap", nullptr}, {"mach_timebase_info", nullptr},
        {"OSAtomicCompareAndSwapPtrBarrier", h_generic_bool}, {"OSMemoryBarrier", nullptr},
        {"getProcessInfo", h_helper_process_info}, {"__error", nullptr}, {"mach_absolute_time", nullptr},
        {"thread_switch", nullptr},
        {"opendir_fake", h_zero}, {"readdir_r", h_zero}, {"closedir", h_zero},  // version 3 (unused)
        {"cs_load_notifier", h_noop}, {"cs_unload_notifier", h_noop},
        {"proc_regionfilename", nullptr}, {"getpid", nullptr}, {"mach_port_insert_right", nullptr},
        {"mach_port_allocate", nullptr}, {"mach_msg", nullptr}, {"abort_with_payload", nullptr},
        {"task_register_dyld_image_infos", nullptr}, {"task_unregister_dyld_image_infos", nullptr},
        {"task_get_dyld_image_infos", nullptr}, {"task_register_dyld_shared_cache_image_info", nullptr},
        {"task_register_dyld_set_dyld_state", nullptr}, {"task_register_dyld_get_process_state", nullptr},
        {"task_info", nullptr}, {"thread_info", nullptr}, {"kdebug_is_enabled", h_generic_bool}, {"kdebug_trace", nullptr},
        {"kdebug_trace_string", nullptr}, {"amfi_check_dyld_policy_self", h_helper_amfi},
        {"notifyMonitorOfMainCalled", h_noop}, {"notifyMonitorOfImageListChanges", h_noop},
        {"mach_msg_destroy", nullptr}, {"mach_port_construct", nullptr}, {"mach_port_destruct", nullptr},
        {"fstat$INODE64", nullptr}, {"vm_copy", nullptr}, {"task_dyld_process_info_notify_get", h_helper_notify_get},
        {"fsgetpath", nullptr}, {"getattrlistbulk", nullptr}, {"getattrlist", nullptr}, {"getfsstat$INODE64", nullptr},
        {"notifyMonitorOfDyldBeforeInitializers", h_noop}, {"sysctlbyname", nullptr},
    };
    constexpr size_t n = sizeof table / sizeof table[0];
    auto *vt = new u64[n + 1];
    vt[0] = 18;
    for (size_t i = 0; i < n; i++) {
        const void *native = dsym(table[i].native);
        Handler h = table[i].h;
        int nfixed = 0;
        if (h == h_variadic || h == h_helper_fcntl) nfixed = 2;  // fd, cmd; the rest on the stack
        if (!h) h = native ? h_generic : h_zero;
        vt[i + 1] = stub_code(add_thunk(std::string("dyld_sim helper ") + table[i].native, h, native, nfixed));
    }
    return (u64)vt;
}

// Faults that dynarmic's fastmem handler doesn't recover: report the guest state (last block entry) before Darling's
// handler reports the host side.
static void peek() {
    if (const char *pk = getenv("X86SIM_A64_PEEK"))  // debug: comma-separated guest addresses to dump (8 bytes each)
        for (const char *q = pk; *q;) {
            char *e; u64 a = strtoull(q, &e, 16);
            if (e == q) break;
            logf("peek %#lx: %#lx", (unsigned long)a, (unsigned long)*(u64 *)a);
            q = *e == ',' ? e + 1 : e;
        }
}
static struct sigaction g_old_segv, g_old_bus;
// The cache's CONST_DATA mappings (read-only after dyld's fixups): guest atomics on them fault in fastmem and are
// completed by dynarmic's fallback; those faults are not reported.
static u64 g_const_lo[8], g_const_hi[8];
static int g_nconst;
static void read_const_mappings(const std::string &cache) {
    static const char *suffixes[] = {"", ".01", ".02", ".03", ".04", ".05"};
    for (const char *sfx : suffixes) {
        int fd = d_open((cache + sfx).c_str(), O_RDONLY);
        if (fd < 0) break;
        uint8_t h[0x400]; uint32_t off = 0, cnt = 0;
        if (pread(fd, h, sizeof h, 0) == (ssize_t)sizeof h) { memcpy(&off, h + 0x138, 4); memcpy(&cnt, h + 0x13c, 4); }
        for (uint32_t i = 0; i < cnt && i < 16 && g_nconst < 8; i++) {
            u64 m[7];
            if (pread(fd, m, sizeof m, off + 56 * i) != (ssize_t)sizeof m) break;
            if (m[5] & 4) { g_const_lo[g_nconst] = m[0]; g_const_hi[g_nconst++] = m[0] + m[1]; }
        }
        close(fd);
    }
}
static bool in_const_data(u64 a) {
    for (int i = 0; i < g_nconst; i++) if (a >= g_const_lo[i] && a < g_const_hi[i]) return true;
    return false;
}
static unsigned long hex(const char *p, const char **end) {  // no locale/TLS (strtoul reads the locale via TLS)
    unsigned long v = 0;
    for (;; p++) {
        int d = *p >= '0' && *p <= '9' ? *p - '0' : *p >= 'a' && *p <= 'f' ? *p - 'a' + 10 : -1;
        if (d < 0) break;
        v = v * 16 + d;
    }
    if (end) *end = p;
    return v;
}
// Fatal-fault report: the mapping (from /proc/self/maps, read with raw syscalls into a static buffer) of an address.
static void maps_line(u64 a, char *out, size_t n) {
    static char buf[1 << 20];
    out[0] = 0;
    int fd = (int)syscall(SYS_open, "/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    long len = 0, r;
    while (len < (long)sizeof buf - 1 && (r = syscall(SYS_read, fd, buf + len, sizeof buf - 1 - len)) > 0) len += r;
    syscall(SYS_close, fd);
    buf[len] = 0;
    for (char *l = buf; *l;) {
        char *e = strchr(l, '\n');
        if (e) *e = 0;
        const char *q;
        unsigned long lo = hex(l, &q), hi = hex(*q == '-' ? q + 1 : q, &q);
        if (a >= lo && a < hi) {
            // "lo-hi perms offset ...": report the file offset (= ELF vaddr for these libraries' segments)
            while (*q == ' ') q++;
            while (*q && *q != ' ') q++;
            while (*q == ' ') q++;
            unsigned long off = hex(q, nullptr);
            const char *path = strrchr(l, ' ');
            snprintf(out, n, "%s+%#lx", path ? path + 1 : "?", (unsigned long)(a - lo + off));
            return;
        }
        if (!e) break;
        l = e + 1;
    }
}
// Frame-pointer walk of the native stack (Darling's libraries keep rbp frames); stops at an unreadable frame.
static void native_backtrace(ucontext_t *ctx) {
    char m[256];
    u64 rip = (u64)ctx->uc_mcontext.gregs[REG_RIP], fp = (u64)ctx->uc_mcontext.gregs[REG_RBP];
    maps_line(rip, m, sizeof m);
    logf("  native #0 %#lx %s", (unsigned long)rip, m);
    for (int i = 1; i < 24 && fp && !(fp & 7); i++) {
        u64 frame[2];
        struct iovec local{frame, sizeof frame}, remote{(void *)fp, sizeof frame};
        if (syscall(SYS_process_vm_readv, getpid(), &local, 1, &remote, 1, 0) != (long)sizeof frame || !frame[1]) break;
        maps_line(frame[1], m, sizeof m);
        logf("  native #%d %#lx %s", i, (unsigned long)frame[1], m);
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
}
// Speed 5: a fault whose RIP is not in JIT code (Darling's native libsystem_malloc / kernel / pthread, libarm64jit,
// a jump to a non-exec address) is fatal. Chaining it to Darling's sigexc handler parked the faulting thread in a
// darlingserver sigprocess RPC forever (often holding the zone lock of the malloc that faulted), so the process hung
// at 0% instead of crashing and being restarted by launchd_sim. Now: report (lock-free; a nested fault in the handler
// kills at once; no SIGALRM watchdog: unblocking a pending SIGALRM killed the process mid-report), then SIGKILL. X86SIM_A64_NATIVE_FAULT=chain
// restores the old chaining.
static void fatal_exit(int code) {
    syscall(SYS_kill, getpid(), SIGKILL);
    syscall(SYS_exit_group, 128 + code);
}
extern std::atomic<u64> g_remap_lo, g_remap_hi;  // handlers.cpp h_vm_remap
static void on_fault(int sig, siginfo_t *si, void *uc) {
    auto *ctx = (ucontext_t *)uc;
    // Speed 30: a store into a range h_vm_remap froze for a shared remap: wait until it is writable again, retry
    if (sig == SIGSEGV && si->si_code == SEGV_ACCERR) {
        const u64 a = (u64)si->si_addr;
        if (a >= g_remap_lo.load() && a < g_remap_hi.load()) {
            for (int k = 0; k < 20000000 && a >= g_remap_lo.load() && a < g_remap_hi.load(); k++) sched_yield();
            return;
        }
    }
    // RAM 3: unchecked fastmem: a guest access with a tagged (non-canonical) address is a #GP in JIT code (SI_KERNEL,
    // no address). Dynarmic's fastmem handler calls the access's callback (which drops the tag); nothing to report.
    // With base rbp or rsp it is a #SS instead, which arrives as SIGBUS (also SI_KERNEL): the same handler serves it.
    if ((sig == SIGSEGV || sig == SIGBUS) && si->si_code == SI_KERNEL &&
        Dynarmic::Backend::IsJitCodeAddress((u64)ctx->uc_mcontext.gregs[REG_RIP]) && (g_old_segv.sa_flags & SA_SIGINFO)) {
        g_old_segv.sa_sigaction(sig, si, uc);
        return;
    }
    if (sig == SIGSEGV && si->si_code == SEGV_ACCERR && in_const_data((u64)si->si_addr) && !getenv("X86SIM_A64_FAULTLOG")) {
        struct sigaction *old = &g_old_segv;
        if (old->sa_flags & SA_SIGINFO) { old->sa_sigaction(sig, si, uc); return; }
    }
    // Speed 25: the guest's execute-only pages (PROT_EXEC without PROT_READ: JavaScriptCore's JIT thunks, e.g. the one
    // LinkBuffer::linkCode calls) are protection-key pages on a PKU CPU (Linux's execute-only pkey). The guest never
    // runs them natively, but the translator must read them: News died "fatal native fault" ~11 s after a cold open.
    // Make the page readable (still not writable) and retry the read. Nothing else here uses protection keys.
    if (sig == SIGSEGV && si->si_code == 4 /* SEGV_PKUERR */) {
        const u64 page = (u64)si->si_addr & ~0xfffull;
        if (mprotect((void *)page, 0x1000, PROT_READ | PROT_EXEC) == 0) return;
    }
    // nesting guard without TLS (a Darling-created thread may have no usable glibc TLS): the tid in the handler
    static std::atomic<long> in_handler_tid{0};
    static std::atomic<int> nested{0};
    const long tid = syscall(SYS_gettid);
    if (in_handler_tid.load() == tid) {
        if (nested++ < 2)
            logf("fault inside the fault handler: signal %d addr %p rip %#llx; killing the process", sig, si->si_addr,
                 (unsigned long long)((ucontext_t *)uc)->uc_mcontext.gregs[REG_RIP]);
        fatal_exit(sig);
    }
    long expect = 0;
    in_handler_tid.compare_exchange_strong(expect, tid);
    const u64 rip = (u64)ctx->uc_mcontext.gregs[REG_RIP];
    static const char *nf = getenv("X86SIM_A64_NATIVE_FAULT");
    const bool fatal = !Dynarmic::Backend::IsJitCodeAddress(rip) && !(nf && !strcmp(nf, "chain"));
    char buf[256];
    int n = snprintf(buf, sizeof buf, "signal %d code %d addr %p rip %#llx err %#llx\n", sig, si->si_code, si->si_addr,
                     (unsigned long long)ctx->uc_mcontext.gregs[REG_RIP], (unsigned long long)ctx->uc_mcontext.gregs[REG_ERR]);
    if (n > 0 && buf[n - 1] == '\n') buf[n - 1] = 0;
    logf("%s", buf);
    {
        char m[256];
        maps_line((u64)si->si_addr, m, sizeof m);
        logf("  fault addr in %s", m[0] ? m : "(unmapped)");
        if (GuestThread *t = GuestThread::current()) {
            maps_line(t->jit->GetPC(), m, sizeof m);
            logf("  guest pc in %s", m[0] ? m : "(unmapped)");
            maps_line(t->x(30), m, sizeof m);
            logf("  guest lr in %s", m[0] ? m : "(unmapped)");
        }
    }
    if (getenv("X86SIM_A64_FAULTBYTES")) {  // debug: the faulting host instruction's first bytes
        auto *ip = (const uint8_t *)ctx->uc_mcontext.gregs[REG_RIP];
        logf("rip bytes %02x %02x %02x %02x %02x %02x", ip[0], ip[1], ip[2], ip[3], ip[4], ip[5]);
    }
    if (GuestThread *t = GuestThread::current()) {
        logf("guest pc %#lx lr %#lx sp %#lx x0 %#lx x1 %#lx x8 %#lx", (unsigned long)t->jit->GetPC(), (unsigned long)t->x(30),
             (unsigned long)t->sp(), (unsigned long)t->x(0), (unsigned long)t->x(1), (unsigned long)t->x(8));
        logf("  x19 %#lx x20 %#lx x21 %#lx x22 %#lx host r12 %#llx r13 %#llx",
             (unsigned long)t->x(19), (unsigned long)t->x(20), (unsigned long)t->x(21), (unsigned long)t->x(22),
             (unsigned long long)ctx->uc_mcontext.gregs[REG_R12],
             (unsigned long long)ctx->uc_mcontext.gregs[REG_R13]);
        // Speed 28: every register and the guest code from the block's PC (JIT-written code is gone with the process)
        {
            char b[1024];
            int n = 0;
            for (int i = 0; i < 31; i++) n += snprintf(b + n, sizeof b - n, "%sx%d %#lx", i % 8 ? " " : "", i, (unsigned long)t->x(i)),
                                         (i % 8 == 7 || i == 30) ? (logf("  %s", b), n = 0) : 0;
            u32 w[48]{};
            struct iovec lo{w, sizeof w}, re{reinterpret_cast<void*>(t->jit->GetPC() & ~3ull), sizeof w};
            if (syscall(SYS_process_vm_readv, getpid(), &lo, 1, &re, 1, 0) == (ssize_t)sizeof w)
                for (int i = 0; i < 48; i += 8)
                    logf("  code +%#x: %08x %08x %08x %08x %08x %08x %08x %08x", i * 4, w[i], w[i + 1], w[i + 2], w[i + 3], w[i + 4], w[i + 5], w[i + 6], w[i + 7]);
        }
    }
    if (GuestThread *t = GuestThread::current(); t && si->si_code != SEGV_ACCERR) { logf("  pc in %s, in thunk %s", where(t->jit->GetPC()).c_str(), t->in_thunk >= 0 ? g_thunks[t->in_thunk].name.c_str() : "-"); guest_backtrace(*t); }
    peek();
    if (fatal) {
        native_backtrace(ctx);
        logf("fatal native fault (rip not in JIT code): killing pid %d", (int)getpid());
        fatal_exit(sig);
    }
    if (in_handler_tid.load() == tid) in_handler_tid = 0;
    struct sigaction *old = sig == SIGSEGV ? &g_old_segv : &g_old_bus;
    if (old->sa_flags & SA_SIGINFO) old->sa_sigaction(sig, si, uc);
    else if (old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN) old->sa_handler(sig);
    else { signal(sig, SIG_DFL); raise(sig); }
}
// SIGABRT from native code (Darling's libsystem, dynarmic asserts): native and guest backtraces, then the default.
static const char *g_scratch_abrt = "";  // scratch_dir(), resolved before the handler is installed
static void on_abrt(int, siginfo_t *si, void *uc) {
    // Scratch breadcrumb (survives when per-pid logs truncate): real RIP from ucontext + maps line.
    u64 rip = 0;
    if (uc) rip = (u64)((ucontext_t *)uc)->uc_mcontext.gregs[REG_RIP];
    {
        char path[512];
        snprintf(path, sizeof path, "%s/abrt-%d-%ld.txt", g_scratch_abrt, (int)getpid(), (long)syscall(SYS_gettid));
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd >= 0) {
            char line[512];
            int n = snprintf(line, sizeof line, "pid %d tid %ld si_code %d si_pid %d rip %#lx guest=%d\n",
                             (int)getpid(), (long)syscall(SYS_gettid), si->si_code, si->si_pid, (unsigned long)rip,
                             GuestThread::current() ? 1 : 0);
            if (n > 0) (void)write(fd, line, (size_t)n);
            if (FILE *m = fopen("/proc/self/maps", "r")) {
                char ml[512];
                while (fgets(ml, sizeof ml, m)) {
                    unsigned long lo, hi;
                    if (sscanf(ml, "%lx-%lx", &lo, &hi) == 2 && rip >= lo && rip < hi) {
                        (void)write(fd, ml, strlen(ml));
                        break;
                    }
                }
                fclose(m);
            }
            if (GuestThread *t = GuestThread::current()) {
                n = snprintf(line, sizeof line, "guest_pc %#lx thunk %s\n", (unsigned long)t->jit->GetPC(),
                             t->in_thunk >= 0 ? g_thunks[t->in_thunk].name.c_str() : "-");
                if (n > 0) (void)write(fd, line, (size_t)n);
            }
            fsync(fd);
            close(fd);
        }
    }
    void *bt[32]; int n = backtrace(bt, 32);
    logf("SIGABRT (code %d pid %d) on tid %ld rip %#lx: native backtrace:", si->si_code, si->si_pid,
         (long)syscall(SYS_gettid), (unsigned long)rip);
    for (int i = 0; i < n; i++) {
        Dl_info di{};
        if (dladdr(bt[i], &di) && di.dli_fname) logf("  %p %s+%#lx %s", bt[i], di.dli_fname, (unsigned long)((char *)bt[i] - (char *)di.dli_fbase), di.dli_sname ? di.dli_sname : "");
        else logf("  %p", bt[i]);
    }
    if (GuestThread *t = GuestThread::current()) {
        logf("guest pc %#lx, in thunk %s", (unsigned long)t->jit->GetPC(), t->in_thunk >= 0 ? g_thunks[t->in_thunk].name.c_str() : "-");
        guest_backtrace(*t);
    } else {
        logf("no GuestThread on aborting tid (native-only or TLS cleared)");
    }
    // Speed 27: training passes only (X86SIM_A64_AOT_AUTOSAVE=1): keep what this process translated, as a normal
    // exit does. A process that aborts right after new code ran (Maps' route card: SwiftUI missed its update deadline
    // while translating) otherwise loses exactly the code the image lacks. Not in normal use: the save takes the
    // shared code lock, which the aborting thread may hold.
    if (const char *a = getenv("X86SIM_A64_AOT_AUTOSAVE"); a && atoi(a) == 1) jitcache_save_on_exit();
    signal(SIGABRT, SIG_DFL);
    raise(SIGABRT);
}
// Darling's own (native) abort(): log the native frame-pointer chain (Mach-O frames symbolized with Darwin's
// dladdr) and the guest state before it raises SIGABRT. Installed by overwriting abort's entry with a jump here.
struct DlInfo { const char *fname; void *fbase; const char *sname; void *saddr; };
static void native_frames(u64 fp, u64 first) {
    auto sym = [](u64 a) {
        DlInfo di{};
        if (g_darwin->dladdr((void *)a, &di) && di.fname) {
            const char *b = strrchr(di.fname, '/');
            logf("  %#lx %s`%s+%#lx", (unsigned long)a, b ? b + 1 : di.fname, di.sname ? di.sname : "?", (unsigned long)(a - (u64)(di.saddr ? di.saddr : di.fbase)));
        } else logf("  %#lx", (unsigned long)a);
    };
    if (first) sym(first);
    for (int k = 0; k < 32 && fp > 0x10000 && !(fp & 7); k++) {
        u64 ret = ((u64 *)fp)[1], next = ((u64 *)fp)[0];
        sym(ret);
        if (next <= fp) break;
        fp = next;
    }
}
[[noreturn]] static void native_abort_hook() {
    logf("native abort() (tid %ld): native frames:", (long)syscall(SYS_gettid));
    native_frames((u64)__builtin_frame_address(0), 0);
    if (GuestThread *t = GuestThread::current()) {
        logf("  in thunk %s, guest pc %#lx", t->in_thunk >= 0 ? g_thunks[t->in_thunk].name.c_str() : "-", (unsigned long)t->jit->GetPC());
        guest_backtrace(*t);
    }
    signal(SIGABRT, SIG_DFL);
    syscall(SYS_tgkill, getpid(), syscall(SYS_gettid), SIGABRT);
    _exit(134);
}
static void hook_native_abort() {
    auto *f = (uint8_t *)dsym("abort");
    if (!f) return;
    u64 page = (u64)f & ~0xfffull;
    if (mprotect((void *)page, 0x2000, PROT_READ | PROT_WRITE | PROT_EXEC)) return;
    u64 h = (u64)&native_abort_hook;
    f[0] = 0x48; f[1] = 0xB8; memcpy(f + 2, &h, 8);  // movabs rax, hook
    f[10] = 0xFF; f[11] = 0xE0;                       // jmp rax
    mprotect((void *)page, 0x2000, PROT_READ | PROT_EXEC);
}
// Forward decl: jit.cpp logs SharedStats (block count / code bytes) when a GuestThread exists.
void memlog_shared_stats();
void gheap_stats();

// X86SIM_A64_STATS: the most called svc thunks (counted in jit.cpp CallSVC)
extern u64 g_thunk_counts[0x10000];
static void log_top_thunks(size_t top, const char *prefix) {
    std::vector<std::pair<u64, u32>> v;
    for (u32 i = 0, n = thunk_count(); i < n; i++) if (g_thunk_counts[i]) v.push_back({g_thunk_counts[i], i});
    std::sort(v.rbegin(), v.rend());
    for (size_t k = 0; k < v.size() && k < top; k++) logf("%s%10lu %s", prefix, (unsigned long)v[k].first, g_thunks[v[k].second].name.c_str());
}

// One-shot glibc + anon RSS line (also used by the periodic MEMLOG thread and SIGUSR1).
static void memlog_once() {
    struct mallinfo2 mi = mallinfo2();
    long anon = 0;
    if (FILE *f = fopen("/proc/self/status", "r")) {
        char l[256];
        while (fgets(l, sizeof l, f)) if (!strncmp(l, "RssAnon:", 8)) anon = atol(l + 8);
        fclose(f);
    }
    if (getenv("X86SIM_A64_STATS")) log_top_thunks(25, "memlog: thunk ");  // Speed 6: so far (SIGUSR1; was only at exit)
    logf("memlog: anon %ld MB, glibc arena %zu MB (in use %zu MB, mmapped %zu MB in %zu blocks, free %zu MB)", anon / 1024,
         mi.arena >> 20, mi.uordblks >> 20, mi.hblkhd >> 20, mi.hblks, mi.fordblks >> 20);
    memlog_shared_stats();
    gheap_stats();
    // RAM 11: glibc's mmapped chunks (each its own anon mapping starting with the chunk header: size | IS_MMAPPED),
    // as a size histogram with the first payload words of one of each size, for attribution without ptrace
    int pfd[2];
    if (pipe2(pfd, O_CLOEXEC) == 0) {
      if (FILE *f = fopen("/proc/self/maps", "r")) {
        std::map<u64, std::pair<int, u64>> h;
        std::map<u64, std::array<u64, 4>> w4;
        char l[512];
        while (fgets(l, sizeof l, f)) {
            unsigned long a, b; char perm[8]; int n = 0;
            if (sscanf(l, "%lx-%lx %7s %*s %*s %*s %n", &a, &b, perm, &n) < 3 || strcmp(perm, "rw-p") || l[n]) continue;
            if (a < (64ull << 30)) continue;  // the guest range
            for (u64 x = a; x + 4096 <= b;) {  // adjacent chunks share a VMA: walk it a page at a time
                u64 c[6];  // read through a pipe: a VMA can go away under the scan (EFAULT, not a fault)
                if (write(pfd[1], (const void *)x, sizeof c) != (ssize_t)sizeof c || read(pfd[0], c, sizeof c) != (ssize_t)sizeof c) break;
                const u64 sz = ((c[1] & ~7ull) + 4095) & ~4095ull;  // glibc keeps the mapping's size less 16 here
                if (c[0] == 0 && (c[1] & 2) && sz >= (128u << 10) && x + sz <= b) {
                    auto &e = h[sz]; if (!e.first++) { e.second = x; w4[sz] = {c[2], c[3], c[4], c[5]}; }
                    x += sz;
                } else x += 4096;
            }
        }
        fclose(f);
        std::vector<std::pair<u64, u64>> v;  // bytes, size
        for (auto &[s, e] : h) v.push_back({s * e.first, s});
        std::sort(v.rbegin(), v.rend());
        for (size_t k = 0; k < v.size() && k < 12; k++) {
            const auto &e = h[v[k].second];
            const auto &w = w4[v[k].second];
            logf("memlog: mmapped chunk %lu KB x %d at %#lx: %016lx %016lx %016lx %016lx", (unsigned long)(v[k].second >> 10), e.first,
                 (unsigned long)e.second, (unsigned long)w[0], (unsigned long)w[1], (unsigned long)w[2], (unsigned long)w[3]);
        }
      }
      close(pfd[0]); close(pfd[1]);
    }
}
static void on_usr1(int, siginfo_t *, void *) { memlog_once(); }
// X86SIM_A64_MEMLOG=<seconds>: a native thread logs the ELF side's malloc use (glibc mallinfo2) and the anon RSS.
// SIGUSR1 always dumps one memlog line (no env needed) for live attribution of host anon blobs.
static void start_memlog() {
    struct sigaction su{};
    su.sa_sigaction = on_usr1;
    su.sa_flags = SA_SIGINFO | SA_RESTART;
    sigaction(SIGUSR1, &su, nullptr);
    const char *e = getenv("X86SIM_A64_MEMLOG");
    if (!e || atoi(e) <= 0) return;
    int secs = atoi(e);
    sigset_t all, old;  // RAM 14: native threads block every signal (see gheap.cpp start_scavenger)
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    std::thread([secs] {
        g_non_darling_thread = true;
        for (;;) {
            sleep(secs);
            memlog_once();
        }
    }).detach();
    pthread_sigmask(SIG_SETMASK, &old, nullptr);
}
// RAM 4: every read fault on a file mapping maps the whole fault-around window (fault_around_bytes = 64 KB, or the
// whole large folio) of what is in the page cache; MADV_RANDOM no longer turns that off. A process ends up mapping
// several times the pages it touched (all counted in PSS; Referenced is set on all of them).
// X86SIM_A64_FILETRIM=<secs> (default 15, 0 off): a native thread checks every <secs> whether the process was idle (under 3% CPU)
// and its file RSS grew by >= 2 MB since the last trim; then it drops the page-table entries of clean file pages
// (MADV_DONTNEED: the pages stay in the page cache; a later touch maps them again from there, no I/O). Only where no
// data can be lost: read-only shared mappings (a shared page lives in the page cache anyway), and the parts of a
// dyld shared cache's private mappings whose cache mapping can never be written (max protection without write:
// __TEXT, __LINKEDIT), page by page from /proc/self/pagemap (only present file pages, bit 61; a COW'd page is kept).
// libarm64jit's own patches of guest __TEXT (mprotect, write, mprotect) hold g_text_patch_mu, as does each 2 MB step.
// The AOT image (.map, MAP_PRIVATE rwx: link sites are written at run time) the same way, page by page, with the
// shared emitter lock held for each 2 MB step (every write to translated code happens under it), so a site being
// linked can never lose its new copy-on-write page. X86SIM_A64_FILETRIM_IMAGE=0: leave the image alone.
std::mutex g_text_patch_mu;
std::shared_mutex g_cache_prot_mu;
bool with_shared_code_lock(void (*fn)(void *), void *arg);  // jit.cpp
static long rss_file_kb() {
    long v = -1;
    if (FILE *f = fopen("/proc/self/status", "r")) {
        char l[256];
        while (fgets(l, sizeof l, f)) if (!strncmp(l, "RssFile:", 8)) { v = atol(l + 8); break; }
        fclose(f);
    }
    return v;
}
// file ranges [off, end) of a dyld cache file whose mappings have no write in their max protection; empty if not one
// (RAM 6: rw = the mappings whose max protection has write: __DATA_CONST / __AUTH_CONST, mapped read-only)
static std::vector<std::pair<u64, u64>> cache_ro_ranges(const char *path, bool rw = false) {
    std::vector<std::pair<u64, u64>> r;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return r;
    uint8_t h[0x200];
    if (pread(fd, h, sizeof h, 0) == (ssize_t)sizeof h && !memcmp(h, "dyld_v1", 7)) {
        uint32_t off, cnt;
        memcpy(&off, h + 0x10, 4); memcpy(&cnt, h + 0x14, 4);
        for (uint32_t i = 0; i < cnt && i < 32; i++) {
            struct { u64 addr, size, fileoff; uint32_t maxprot, initprot; } m;
            if (pread(fd, &m, sizeof m, off + 32 * i) != (ssize_t)sizeof m) break;
            if (!(m.maxprot & 2) != rw && m.size) r.push_back({m.fileoff, m.fileoff + m.size});
        }
    }
    close(fd);
    return r;
}
static bool cache_const_trim() {  // X86SIM_A64_FILETRIM_CONST=0: leave the cache's read-only __DATA_CONST alone
    static const bool on = !(getenv("X86SIM_A64_FILETRIM_CONST") && atoi(getenv("X86SIM_A64_FILETRIM_CONST")) == 0);
    return on;
}
static bool priv_trim() {  // X86SIM_A64_FILETRIM_PRIV=0: leave non-cache read-only private file mappings alone
    static const bool on = !(getenv("X86SIM_A64_FILETRIM_PRIV") && atoi(getenv("X86SIM_A64_FILETRIM_PRIV")) == 0);
    return on;
}
static void file_trim_once() {
    struct V { u64 a, b; int kind; };  // 0 cache (g_text_patch_mu), 1 shared, 2 AOT image (emitter lock)
    static const bool image = !(getenv("X86SIM_A64_FILETRIM_IMAGE") && atoi(getenv("X86SIM_A64_FILETRIM_IMAGE")) == 0);
    std::vector<V> v;
    static std::map<std::string, std::vector<std::pair<u64, u64>>> ro;  // per cache file
    if (FILE *f = fopen("/proc/self/maps", "r")) {
        char l[4096];
        while (fgets(l, sizeof l, f)) {
            unsigned long a, b, off, ino;
            char perm[8];
            int path = 0;
            if (sscanf(l, "%lx-%lx %7s %lx %*x:%*x %lu %n", &a, &b, perm, &off, &ino, &path) < 5 || !ino || !path) continue;
            char *n = l + path;
            n[strcspn(n, "\n")] = 0;
            if (n[0] != '/' || !strncmp(n, "/dev/", 5) || !strncmp(n, "/memfd:", 7) || !strncmp(n, "/SYSV", 5)) continue;
            if (perm[0] != 'r' || b - a < 0x10000) continue;
            const size_t nl = strlen(n);
            if (image && perm[3] == 'p' && nl > 4 && !strcmp(n + nl - 4, ".map") && strstr(n, ".aot.")) { v.push_back({a, b, 2}); continue; }
            if (perm[1] == 'w') continue;
            if (perm[3] == 's') { v.push_back({a, b, 1}); continue; }
            if (!strstr(n, "dyld_sim_shared_cache") && !strstr(n, "dyld_shared_cache")) continue;
            auto it = ro.find(n);
            if (it == ro.end()) it = ro.emplace(n, cache_ro_ranges(n)).first;
            for (auto [lo, hi] : it->second) {  // the VMA's part that lies in a never-writable cache mapping
                const u64 s = std::max<u64>(off, lo), e = std::min<u64>(off + (b - a), hi);
                if (s < e) v.push_back({a + (s - off), a + (e - off), 0});
            }
        }
        fclose(f);
    }
    int pm = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (pm < 0) return;
    struct Step { int pm; u64 s, e; bool ok; } st{pm, 0, 0, true};
    // drops the present file pages of [s, e) (at most 2 MB), keeping every private page
    static void (*const step)(void *) = [](void *p) {
        auto &q = *(Step *)p;
        static u64 ent[0x200];
        const u64 n = (q.e - q.s) >> 12;
        if (pread(q.pm, ent, n * 8, (off_t)(q.s >> 12) * 8) != (ssize_t)(n * 8)) { q.ok = false; return; }
        auto file = [&](u64 k) { return (ent[k] >> 63 & 1) && (ent[k] >> 61 & 1); };
        for (u64 i = 0; i < n;) {
            if (!file(i)) { i++; continue; }
            u64 j = i;
            while (j < n && file(j)) j++;
            madvise((void *)(q.s + (i << 12)), (j - i) << 12, MADV_DONTNEED);
            i = j;
        }
    };
    // RAM 6: the dyld cache's __DATA_CONST / __AUTH_CONST (max protection read-write, mapped read-only): ~50-140 MB of
    // clean fault-around file pages per UI process, never written here (0 anonymous pages in them at home). A write
    // needs an mprotect / vm_protect (or a map over them) first; every guest call that can do that holds
    // g_cache_prot_mu shared (handlers.cpp h_cachelock), so with it held exclusive the read-only VMAs found now stay
    // read-only until the pages are dropped. Present file pages only (a COW'd page is anonymous and kept).
    if (cache_const_trim()) {
        std::unique_lock g(g_cache_prot_mu);
        std::vector<V> w;
        if (FILE *f = fopen("/proc/self/maps", "r")) {
            static std::map<std::string, std::vector<std::pair<u64, u64>>> rw;
            char l[4096];
            while (fgets(l, sizeof l, f)) {
                unsigned long a, b, off, ino;
                char perm[8];
                int path = 0;
                if (sscanf(l, "%lx-%lx %7s %lx %*x:%*x %lu %n", &a, &b, perm, &off, &ino, &path) < 5 || !ino || !path) continue;
                char *n = l + path;
                n[strcspn(n, "\n")] = 0;
                if (perm[0] != 'r' || perm[1] == 'w' || perm[3] != 'p' || b - a < 0x10000) continue;
                if (!strstr(n, "dyld_sim_shared_cache") && !strstr(n, "dyld_shared_cache")) {
                    // RAM 9: other read-only private file mappings (a non-cache Mach-O's __TEXT, Assets.car, model
                    // weights, host libraries' text): the same rule, present file pages only. libarm64jit's own text
                    // patches hold g_text_patch_mu (taken per step), guest protection changes g_cache_prot_mu.
                    if (priv_trim() && n[0] == '/' && strncmp(n, "/dev/", 5) && strncmp(n, "/memfd:", 7) &&
                        strncmp(n, "/SYSV", 5) && !strstr(n, ".aot."))
                        w.push_back({a, b, 4});
                    continue;
                }
                auto it = rw.find(n);
                if (it == rw.end()) it = rw.emplace(n, cache_ro_ranges(n, true)).first;
                for (auto [lo, hi] : it->second) {
                    const u64 s = std::max<u64>(off, lo), e = std::min<u64>(off + (b - a), hi);
                    if (s < e) w.push_back({a + (s - off), a + (e - off), 3});
                }
            }
            fclose(f);
        }
        for (const V &m : w) {
            st.ok = true;
            for (u64 s = m.a; s < m.b && st.ok; s += 0x200000) {
                st.s = s; st.e = std::min(m.b, s + 0x200000);
                if (m.kind == 4) { std::lock_guard t(g_text_patch_mu); step(&st); }
                else step(&st);
            }
        }
    }
    for (const V &m : v) {
        if (m.kind == 1) { madvise((void *)m.a, m.b - m.a, MADV_DONTNEED); continue; }
        st.ok = true;
        for (u64 s = m.a; s < m.b && st.ok; s += 0x200000) {
            st.s = s; st.e = std::min(m.b, s + 0x200000);
            if (m.kind == 0) { std::lock_guard g(g_text_patch_mu); step(&st); }
            else if (!with_shared_code_lock(step, &st)) break;
        }
    }
    close(pm);
}
// RAM 4 diagnostics: X86SIM_A64_COWDIFF=<secs> X86SIM_A64_COWDIFF_DIR=<dir>: once, <secs> after start, compare
// every private (COW'd) page of the AOT image mapping with the file and classify the changed bytes by the site kind
// they hit (link head: 8-byte aligned `mov rax, imm64` unlinked / jmp/jcc linked; RSB `mov rcx, imm64`; other), and
// where a linked jump now points (inside the image or not). Written to <dir>/cowdiff-<exe>-<pid>.txt.
static void cow_diff_once() {
    const char *dir = getenv("X86SIM_A64_COWDIFF_DIR");
    if (!dir) return;
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return;
    char l[4096], path[4096] = "";
    unsigned long a = 0, b = 0, off = 0;
    while (fgets(l, sizeof l, f)) {
        int pp = 0;
        unsigned long x, y, o;
        char perm[8];
        if (sscanf(l, "%lx-%lx %7s %lx %*x:%*x %*u %n", &x, &y, perm, &o, &pp) < 4 || !pp) continue;
        char *n = l + pp;
        n[strcspn(n, "\n")] = 0;
        const size_t nl = strlen(n);
        if (nl > 4 && !strcmp(n + nl - 4, ".map") && strstr(n, ".aot.") && y - x > (b - a)) { a = x; b = y; off = o; snprintf(path, sizeof path, "%s", n); }
    }
    fclose(f);
    if (!a) return;
    int pm = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC), fd = open(path, O_RDONLY | O_CLOEXEC);
    const char *exe = getenv("X86SIM_A64_EXE");
    const char *bn = exe && strrchr(exe, '/') ? strrchr(exe, '/') + 1 : "guest";
    char out[512];
    snprintf(out, sizeof out, "%s/cowdiff-%s-%d.txt", dir, bn, (int)getpid());
    FILE *o = fopen(out, "w");
    if (pm < 0 || fd < 0 || !o) { if (o) fclose(o); if (pm >= 0) close(pm); if (fd >= 0) close(fd); return; }
    u64 pages = 0, same = 0, resident = 0, runs = 0;
    u64 k_head_link = 0, k_head_unlink = 0, k_rcx = 0, k_other = 0, to_image = 0, to_outside = 0;
    u64 rcx_to_image = 0, rcx_to_outside = 0, rcx_to_ret = 0;
    uint8_t fp[4096 + 16];
    int samples = 0;
    for (u64 s = a; s < b; s += 4096) {
        u64 e;
        if (pread(pm, &e, 8, (off_t)(s >> 12) * 8) != 8) break;
        if (!(e >> 63 & 1)) continue;
        resident++;
        if (e >> 61 & 1) continue;  // still the file page
        pages++;
        const uint8_t *m = (const uint8_t *)s;
        memset(fp, 0, sizeof fp);
        if (pread(fd, fp, 4096, (off_t)(off + (s - a))) != 4096) continue;
        if (!memcmp(m, fp, 4096)) { same++; continue; }
        for (u64 j = 0; j < 4096;) {
            if (m[j] == fp[j]) { j++; continue; }
            u64 k = j;
            while (k < 4096 && m[k] != fp[k]) k++;
            runs++;
            const u64 al = j & ~7ull;  // shared link heads are 8-byte aligned; rcx imm64 too
            const u64 at = s + al;
            if (fp[al] == 0x48 && fp[al + 1] == 0xB8) {
                if (m[al] == 0xE9 || (m[al] == 0x0F && (m[al + 1] == 0x8F || m[al + 1] == 0x84))) {
                    k_head_link++;
                    const int len = m[al] == 0xE9 ? 5 : 6;
                    int32_t rel; memcpy(&rel, m + al + (len - 4), 4);
                    const u64 t = at + len + rel;
                    (t >= a && t < b ? to_image : to_outside)++;
                } else k_head_unlink++;
                k = std::max<u64>(k, al + 8);
            } else if (al >= 2 && fp[al - 2] == 0x48 && fp[al - 1] == 0xB9) {
                k_rcx++;
                u64 t; memcpy(&t, m + al, 8);
                if (t >= a && t < b) rcx_to_image++; else rcx_to_outside++;
                k = std::max<u64>(k, al + 8);
            } else if (al < 4096 - 8 && al >= 8 && j == al + 2 && fp[al] == 0x48 && fp[al + 1] == 0xB9) {
                k_rcx++; rcx_to_ret++;
            } else {
                k_other++;
                if (samples < 40) {
                    samples++;
                    fprintf(o, "other @+%#lx:", (unsigned long)(s - a + j));
                    for (u64 q = (j >= 12 ? j - 12 : 0); q < std::min<u64>(4096, j + 12); q++) fprintf(o, " %02x", fp[q]);
                    fprintf(o, "  ->");
                    for (u64 q = (j >= 12 ? j - 12 : 0); q < std::min<u64>(4096, j + 12); q++) fprintf(o, " %02x", m[q]);
                    fprintf(o, "\n");
                }
            }
            j = k;
        }
    }
    fprintf(o, "image %s\nresident %lu private %lu identical-to-file %lu diff-runs %lu\n", path, (unsigned long)resident,
            (unsigned long)pages, (unsigned long)same, (unsigned long)runs);
    fprintf(o, "link heads linked %lu (to image %lu, outside %lu), unlinked %lu; rcx imm %lu (image %lu outside %lu ret %lu); other %lu\n",
            (unsigned long)k_head_link, (unsigned long)to_image, (unsigned long)to_outside, (unsigned long)k_head_unlink,
            (unsigned long)k_rcx, (unsigned long)rcx_to_image, (unsigned long)rcx_to_outside, (unsigned long)rcx_to_ret,
            (unsigned long)k_other);
    fclose(o);
    close(pm);
    close(fd);
}
// x86Sim RAM 6: the fast dispatch table (a64:fastdispatch, 1-4 MB per process) is a cache of block lookups hashed by
// crc32 over the whole table, so a process that ran a few thousand blocks has every page of it touched (36 MB over 38
// processes at home). An idle process drops it (same as ClearFastDispatchTable: empty = zero bytes; entries are read
// as one 16-byte access in shared mode, so a reader sees the entry or a miss). Under the shared emitter lock, which
// GetBlock's fill holds. The next wakeup refills what it runs. X86SIM_A64_FDTRIM=0: off.
static void fastdispatch_trim_locked(void *) {
    if (FILE *f = fopen("/proc/self/maps", "r")) {
        char l[512];
        while (fgets(l, sizeof l, f)) {
            unsigned long a, b;
            if (!strstr(l, "[anon:a64:fastdispatch]") || sscanf(l, "%lx-%lx", &a, &b) != 2) continue;
            madvise((void *)a, b - a, MADV_DONTNEED);
        }
        fclose(f);
    }
}
static void fastdispatch_trim() {
    static const bool on = !(getenv("X86SIM_A64_FDTRIM") && atoi(getenv("X86SIM_A64_FDTRIM")) == 0);
    if (on) with_shared_code_lock(fastdispatch_trim_locked, nullptr);
}
static void start_file_trim() {
    if (const char *c = getenv("X86SIM_A64_COWDIFF"); c && atoi(c) > 0) {
        sigset_t all, old;
        sigfillset(&all);
        pthread_sigmask(SIG_SETMASK, &all, &old);
        std::thread([secs = atoi(c)] { g_non_darling_thread = true; sleep(secs); cow_diff_once(); }).detach();
        pthread_sigmask(SIG_SETMASK, &old, nullptr);
    }
    const char *e = getenv("X86SIM_A64_FILETRIM");
    const int secs = e && *e ? atoi(e) : 15;
    if (secs <= 0) return;
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    std::thread([secs] {
        g_non_darling_thread = true;
        setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
        auto cpu = [] { timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; };
        // RAM 9: file pages come back in bursts: a launched daemon maps ~100+ MB of fault-around in its first seconds,
        // and SpringBoard's status bar clock maps ~110 MB of the AOT image every minute (~2700 faults, 0.1 s of CPU).
        // With one check every 15 s (the first at 30 s, its window counting the launch twice) they stayed 15-60 s, and
        // a memcat snapshot caught them or not. Now the file RSS is checked every X86SIM_A64_FILETRIM_TICK s (default
        // 3; busy measured over that real window) and trimmed after a quiet tick; the fast dispatch table (a refill
        // costs) is still dropped only after a quiet window of <secs>.
        const char *te = getenv("X86SIM_A64_FILETRIM_TICK");
        int tick = te && *te ? atoi(te) : 3;
        if (tick <= 0 || tick > secs) tick = secs;
        auto now = [] { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; };
        auto pct = [](double c, double w) { return c * 100.0 / (w > 1 ? w : 1); };
        long base = 0, prev = 0;
        const char *se = getenv("X86SIM_A64_FILETRIM_SETTLE");
        const long settle_kb = (se && *se ? atol(se) : 64) << 10;
        double c0 = cpu(), w0 = now(), fc0 = c0, fw0 = w0;
        for (;;) {
            sleep(tick);
            const double c1 = cpu(), w1 = now(), busy = pct(c1 - c0, w1 - w0);
            c0 = c1; w0 = w1;
            if (w1 - fw0 >= secs * 1e3 - 100) {
                if (pct(c1 - fc0, w1 - fw0) < 3.0) fastdispatch_trim();
                fc0 = c1; fw0 = w1;
            }
            // RAM 11: a foreground app that keeps a few % of CPU (Health ~5%: an animation, a timer) never went quiet,
            // so its whole launch (0.85-1.1 GB of file pages per app: dyld cache, AOT image and index fault-around)
            // stayed mapped as long as it was open. Also trim once the file RSS stopped growing for a tick, grew by
            // >= X86SIM_A64_FILETRIM_SETTLE MB (default 64, 0 off) since the last trim, and CPU is under 25%.
            const long r = rss_file_kb();
            const long grew = r - prev;
            prev = r;
            const bool settled = settle_kb > 0 && busy < 25.0 && grew < 1024 && r - base >= settle_kb;
            if (busy >= 3.0 && !settled) continue;
            if (r < 0 || r - base < 2048) continue;
            timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            file_trim_once();
            clock_gettime(CLOCK_MONOTONIC, &t1);
            base = prev = rss_file_kb();
            c0 = cpu(); w0 = now();
            if (getenv("X86SIM_A64_FILETRIM_LOG"))
                logf("filetrim: RssFile %ld -> %ld MB in %.1f ms (cpu %.1f%%%s)", r >> 10, base >> 10,
                     (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, busy, busy >= 3.0 ? ", settled" : "");
        }
    }).detach();
    pthread_sigmask(SIG_SETMASK, &old, nullptr);
}
static void install_fault_report() {
    start_memlog();
    start_file_trim();
    hook_native_abort();
    g_scratch_abrt = scratch_dir().c_str();
    { struct sigaction sa{}; sa.sa_sigaction = on_abrt; sa.sa_flags = SA_SIGINFO | SA_ONSTACK; sigaction(SIGABRT, &sa, nullptr); }
    struct sigaction sa{};
    // SA_NODEFER: a fault inside the report re-enters on_fault (depth guard: one log line, then kill); with SIGSEGV
    // blocked the kernel killed the process silently and the report stopped after its first line.
    sa.sa_sigaction = on_fault; sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigaction(SIGSEGV, &sa, &g_old_segv); sigaction(SIGBUS, &sa, &g_old_bus);
}

void print_stats() {
    peek();
    if (!getenv("X86SIM_A64_STATS")) return;
    logf("exit after %.1f ms", ms_since(g_t0));
    if (FILE *f = fopen("/proc/self/status", "r")) {
        char l[256];
        while (fgets(l, sizeof l, f)) if (!strncmp(l, "RssAnon", 7) || !strncmp(l, "Threads", 7)) logf("%s", strtok(l, "\n"));
        fclose(f);
    }
    log_top_thunks(12, "  ");
    native_objc_stats();
    jitcache_save_if_shared();
}

}  // namespace a64

using namespace a64;

// Speed 30: set by the a64-penv constructor (end of this file) when it applied a variable
static bool g_penv_applied = false;
extern "C" __attribute__((visibility("default"))) int a64_host_main(int argc, char **argv, char **envp, char **apple, const DarwinApi *api) {
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    g_darwin = api;
    // x86Sim: dynarmic writes /tmp/perf-<pid>.map when PERF_BUILDID_DIR is set (Linux perf symbolize).
    // X86SIM_A64_PERFMAP=1 selects /tmp (the only allowed /tmp use besides that map).
    if (getenv("X86SIM_A64_PERFMAP") && !getenv("PERF_BUILDID_DIR"))
        setenv("PERF_BUILDID_DIR", "/tmp", 0);
    g_trace = getenv("X86SIM_A64_TRACE") != nullptr;
    // "name[,name]": the executable's basename is one of them
    auto exe_listed = [](const char *names) {
        const char *e = getenv("X86SIM_A64_EXE"), *b = strrchr(e, '/');
        return (std::string(",") + names + ",").find(std::string(",") + (b ? b + 1 : e) + ",") != std::string::npos;
    };
    // X86SIM_A64_TRACE_PROC=name[,name]: trace only these executables (set for a whole boot)
    if (const char *tp = getenv("X86SIM_A64_TRACE_PROC"); tp && getenv("X86SIM_A64_EXE")) g_trace = exe_listed(tp);
    if (const char *sp = getenv("X86SIM_A64_STEP_PROC"); sp && getenv("X86SIM_A64_EXE")) g_step = exe_listed(sp);
    d_open = (int (*)(const char *, int, ...))dsym("open");
    boundary_init();

    // The guest executable: from mldr (X86SIM_A64_EXE, argv untouched) or "arm64host <exe> [args]".
    std::string exe;
    if (const char *e = getenv("X86SIM_A64_EXE")) exe = e;
    else if (argc > 1) { exe = argv[1]; argv++; argc--; }
    else { fprintf(stderr, "usage: arm64host <arm64 iOS-simulator executable> [args...]\n"); return 2; }
    // Speed 6: launchd_sim turns ASLR off for the processes it spawns (personality is inherited across fork/exec;
    // only the simulator's jobs, not the host). Same library and code cache address in every process -> they share
    // one relocated AOT image. X86SIM_A64_NOASLR=0 keeps ASLR.
    if (const char *b = strrchr(exe.c_str(), '/'); !strcmp(b ? b + 1 : exe.c_str(), "launchd_sim") &&
                                                    !(getenv("X86SIM_A64_NOASLR") && atoi(getenv("X86SIM_A64_NOASLR")) == 0))
        personality(personality(0xffffffff) | ADDR_NO_RANDOMIZE);
    // X86SIM_A64_SLIM_PARK=substr[,substr]: park matching executables before dyld/JIT so SpringBoard's
    // RunningBoard assertions stay satisfied (process alive) without translating Spotlight/WidgetRenderer
    // (~0.5–1.5 GB PSS each). Replaces the kill-every-5s slim-reaper thrash.
    // Park list: env X86SIM_A64_SLIM_PARK, or file (launchd does not pass env to jobs).
    // File default: <scratch_dir()>/a64-slim-park (written by boot-a64.sh).
    {
        std::string park;
        if (const char *e = getenv("X86SIM_A64_SLIM_PARK")) park = e;
        if (park.empty()) {
            if (FILE *f = fopen((scratch_dir() + "/a64-slim-park").c_str(), "r")) {
                char buf[512];
                if (fgets(buf, sizeof buf, f)) {
                    park = buf;
                    while (!park.empty() && (park.back() == '\n' || park.back() == '\r' || park.back() == ' '))
                        park.pop_back();
                }
                fclose(f);
            }
        }
        if (!park.empty()) {
            // any entry that is a substring of the executable's path (a whole basename is one too)
            bool hit = false;
            for (size_t i = 0; !hit && i <= park.size();) {
                const size_t j = std::min(park.find(',', i), park.size());
                hit = j > i && exe.find(park.substr(i, j - i)) != std::string::npos;
                i = j + 1;
            }
            if (hit) {
                fprintf(stderr, "arm64host: slim-park %s\n", exe.c_str());
                for (;;) pause();
            }
        }
    }
    // mldr hands over the Linux path; the guest (CFBundleGetMainBundle, _NSGetExecutablePath) needs the Darwin one
    if (!exe.empty() && exe[0] == '/' && exe.compare(0, 20, "/Volumes/SystemRoot/")) {
        int fd = d_open(exe.c_str(), O_RDONLY);
        if (fd >= 0) close(fd);
        else exe = "/Volumes/SystemRoot" + exe;
    }

    // Guest environment: mldr renamed DYLD_* to X86SIM_A64_DYLD_* so Darling's dyld ignores them.
    std::vector<char *> genv;
    std::string root, cache_dir;
    // Speed 30: environ when the a64-penv file applied something (its setenv() calls must reach the guest too), envp
    // otherwise (unchanged default)
    for (char **e = g_penv_applied ? environ : envp; *e; e++) {
        std::string s = *e;
        auto pre = [&s](std::string_view p) { return s.compare(0, p.size(), p) == 0; };
        if (pre("X86SIM_A64_DYLD_")) s = s.substr(sizeof("X86SIM_A64_") - 1);
        // Speed 28 (debug): X86SIM_A64_GENV_<NAME>=v reaches the guest as NAME=v (launchd jobs only get X86SIM_A64_*)
        else if (pre("X86SIM_A64_GENV_")) s = s.substr(sizeof("X86SIM_A64_GENV_") - 1);
        else if (pre("X86SIM_A64_EXE=") || pre("X86SIM_A64_JIT=")) continue;
        if (!s.compare(0, 15, "DYLD_ROOT_PATH=")) root = s.substr(15);
        if (!s.compare(0, 22, "DYLD_SHARED_CACHE_DIR=")) cache_dir = s.substr(22);
        genv.push_back(strdup(s.c_str()));
    }
    // 2026-11-03 defaults: JavaScriptCore without its FTL tier (JSC_useFTLJIT=false) unless the guest env sets it.
    // FTL's B3 compiles run translated and cost more than they win here: JS bench 2.06-2.10 s vs 2.53-2.58 s with
    // FTL (DFG off as well: 4.28 s; no JIT: 6.6 s); page loads unchanged. X86SIM_A64_JSC_FTL=1 keeps JSC's default.
    if (!(getenv("X86SIM_A64_JSC_FTL") && atoi(getenv("X86SIM_A64_JSC_FTL")) == 1) &&
        std::none_of(genv.begin(), genv.end(), [](const char *v) { return !strncmp(v, "JSC_useFTLJIT=", 14); }))
        genv.push_back(strdup("JSC_useFTLJIT=false"));
    if (root.empty()) die("DYLD_ROOT_PATH is not set (the arm64 simulator runtime root)");
    if (cache_dir.empty()) {
        cache_dir = root + "/System/Library/Caches/com.apple.dyld/";
        genv.push_back(strdup(("DYLD_SHARED_CACHE_DIR=" + cache_dir).c_str()));
    }
    genv.push_back(nullptr);

    // Stub dylibs for the host libraries, from the cache placeholders' export tries.
    std::string cache = cache_dir + "/dyld_sim_shared_cache_arm64";
    for (const char *lib : {"kernel", "platform", "pthread"}) {
        std::string path = std::string("/usr/lib/system/libsystem_") + lib + ".dylib";
        build_stub_dylib(path, cache_exports(cache, path));
    }
    native_malloc_prepare(cache);
    native_objc_prepare(cache);
    astc_prepare(cache);  // Speed 31: libate's ASTC decode entry (astc.cpp)
    lzfse_prepare(cache);  // Speed 32: libcompression's LZFSE buffer decode entries (lzfse.cpp)
    ax_euid_prepare(cache);  // libAccessibility's root check (handlers.cpp h_geteuid)
    jitcache_prepare(cache, exe);
    read_const_mappings(cache);
    load_cached_paths(cache, root);  // Perf 1: on-disk copies of cache images hidden from dyld_sim
    double t_stubs = ms_since(g_t0);

    // Keep the cache's fixed range free for dyld_sim's MAP_FIXED mappings (RAM 13: and placed files up to 0x300000000).
    mmap((void *)0x1C0000000ull, 0x300000000ull - 0x1C0000000ull, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE, -1, 0);
    map_commpage();
    Mapped main_exe = map_macho(exe, false);
    Mapped dyld = map_macho(root + "/usr/lib/dyld_sim", true);
    dyld_sim_patches(dyld.slide);
    if (!dyld.entry) die("dyld_sim has no entry point");
    u64 helpers = build_syscall_helpers();

    // KernelArgs as dyld_sim expects them below argv: mainExecutable, argc, argv..., 0, envp..., 0, apple..., 0.
    std::vector<u64> ka;
    ka.push_back(main_exe.mh);
    ka.push_back((u64)argc);
    for (int i = 0; i < argc; i++) ka.push_back((u64)argv[i]);
    ka.push_back(0);
    size_t env_at = ka.size();
    for (char *e : genv) if (e) ka.push_back((u64)e);
    ka.push_back(0);
    size_t apple_at = ka.size();
    ka.push_back((u64)strdup(("executable_path=" + exe).c_str()));
    char buf[128];
    snprintf(buf, sizeof buf, "stack_guard=0x%lx", (unsigned long)(((u64)random() << 32 | random()) & ~0xffull)); ka.push_back((u64)strdup(buf));
    snprintf(buf, sizeof buf, "malloc_entropy=0x%lx,0x%lx", (unsigned long)random(), (unsigned long)random()); ka.push_back((u64)strdup(buf));
    ka.push_back((u64)strdup("ptr_munge=0x0"));
    ka.push_back(0);
    auto *kargs = new u64[ka.size()];
    memcpy(kargs, ka.data(), ka.size() * 8);
    u64 gargv = (u64)&kargs[2], genvp = (u64)&kargs[env_at], gapple = (u64)&kargs[apple_at];


    GuestThread &t = GuestThread::self();
    gsample_start(&t);
    install_fault_report();
    double t_setup = ms_since(g_t0);
    svc_bench(t);
    u64 glue = 0;
    u64 args[9] = {(u64)argc, gargv, genvp, gapple, main_exe.mh, dyld.mh, dyld.slide, helpers, (u64)&glue};
    u64 main_fn = t.call(dyld.entry, args, 9).rax;
    g_stub_guard_armed = true;  // stub dylibs are mapped now: refuse later unmaps of them (handlers.cpp)
    logf("stubs %.1f ms, setup %.1f ms, dyld_sim prepare done at %.1f ms; thunk calls %lu", t_stubs, t_setup, ms_since(g_t0),
             (unsigned long)t.svc_count);
    if (!main_fn) die("_dyld_sim_prepare returned no main");
    return (int)t.call(main_fn, {(u64)argc, gargv, genvp, gapple});
}

// Speed 29 debug: per-process environment from a file, applied before every other static initializer of this library
// (many knobs are read once into static consts). File: $X86SIM_A64_PENV_FILE or <scratch_dir()>/a64-penv,
// lines "<program basename> K=V [K=V...]" ("*" for every program; '#' comments). Used to bisect one app's knobs without rebooting the phone.
__attribute__((constructor(101))) static void a64_penv() {
    // (g_penv_applied: declared above main's environment loop)
    const char *exe = getenv("X86SIM_A64_EXE");
    if (!exe) return;
    const char *b = strrchr(exe, '/');
    b = b ? b + 1 : exe;
    const char *fn = getenv("X86SIM_A64_PENV_FILE");
    FILE *f = fopen(fn ? fn : (scratch_dir() + "/a64-penv").c_str(), "r");
    if (!f) return;
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        char *save = nullptr, *tok = strtok_r(line, " \t\n", &save);
        if (!tok || *tok == '#' || (strcmp(tok, b) != 0 && strcmp(tok, "*") != 0)) continue;  // "*": every program
        while ((tok = strtok_r(nullptr, " \t\n", &save)))
            if (char *eq = strchr(tok, '=')) { *eq = 0; setenv(tok, eq + 1, 1); g_penv_applied = true; }
    }
    fclose(f);
}

// RAM 1: no transparent huge pages for anonymous memory in guest processes. With THP "always" on the host, the
// first touch of a 2 MB-aligned stretch of a guest heap, a thread stack or the JIT's metadata faults a whole 2 MB page
// (~124 MB of huge pages over an idle phone, mostly untouched 4 KB pages). The AOT image and the dyld cache are file
// mappings and never used THP here. Per process (inherited across fork/exec), not a host setting.
// X86SIM_A64_THP=1 keeps the host default.
__attribute__((constructor(102))) static void a64_no_thp() {
    const char *e = getenv("X86SIM_A64_THP");
    if (e && atoi(e) == 1) return;
    // Perf 12: with the AOT image's huge-page copy (X86SIM_A64_AOT_HUGE=1), except what asks for it: this prctl had
    // silently refused the copy's 2 MB mappings (MADV_HUGEPAGE). PR_THP_DISABLE_EXCEPT_ADVISED is Linux 6.18+; on older
    // kernels, or without the copy, everything off as before.
    const char *h = getenv("X86SIM_A64_AOT_HUGE");
    if (h && atoi(h) == 1 && prctl(PR_SET_THP_DISABLE, 1, 1 << 1 /* PR_THP_DISABLE_EXCEPT_ADVISED */, 0, 0) == 0) return;
    prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0);
}
