// libarm64jit: persistent translation cache for the dyld shared cache's code.
//
// Two kinds of file in the cache dir, both keyed <uuid>-<build> (build: kCodegenVersion, code-shaping flags and the
// placement table's hash):
//   <key>.<exe>.bin  per process (warm start / AOT training), written on SIGUSR1 (memlog) or at exit with STATS.
//   <key>.aot        Stage 4 AOT image: the union of every .bin's blocks, translated by one builder process
//                    (X86SIM_A64_AOT_BUILD=1, at its exit). Every ASLR-off process (Speed 7; otherwise .app/
//                    executables, or X86SIM_A64_AOT_PROCS=name,name|all) loads it at start instead of its .bin.
//                    X86SIM_A64_AOT=0 disables.
// When the process runs with ADDR_NO_RANDOMIZE (setarch -R), the key also holds libarm64jit's load base: a file
// is used only when host addresses match too (otherwise the reloc table re-bases the emitted host addresses).
//
// Saves x86 blocks whose guest PC is in the sim shared-cache range to a file under
// X86SIM_A64_JITCACHE_DIR (default $X86SIM_SCRATCH/jitcache), keyed by the dyld cache UUID
// and a build id (bump when emit / StackLayout / fuse_svc / inline objc change). Blocks that
// emit HostCall (svc thunks, CNTPCT, …) are excluded — they bake ASLR-sensitive host pointers.
//
// Load restores the code slab after an identical prelude; emitter-recorded relocations fix
// absolute host Imm64s (objc counters, RSB patch sites, …). Relative jumps to terminal handlers
// stay valid when prelude_size matches. FastDispatch is cleared and refills on use.
#include "a64.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <string>
#include <dirent.h>
#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <set>
#include <sys/personality.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <pwd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <sys/resource.h>
#include <atomic>
#include <mutex>
#include <vector>
#include <unordered_map>
#include <thread>

namespace a64 {

namespace {

constexpr u64 kCacheLo = 0x1c0000000ull;
// RAM 13: the persisted window ends at 0x300000000 (was 0x2c0000000): placed files also go above the cache window's
// old top, into the free 1 GB below the guest VM range (handlers.cpp / gheap.cpp start at 0x300000000).
constexpr u64 kCacheHi = 0x300000000ull;
// CODEGEN_VERSION: bump whenever translated code would change (emitter, IR passes, StackLayout, fuse_svc, inline objc,
// the cache format, reloc kinds). Speed 18: it replaces the libarm64jit build-id hash, so a rebuild that leaves codegen
// alone keeps every image chunk (tools/launcher x86sim-aot mirrors this value: core/src/key.rs).
// Loading still checks what can be checked: the prelude size and handler layout, reloc kinds, the image UUID.
// History (newest first):
//   0x40 Perf 22: every malloc_create_zone zone, malloc_size, kdebug, assert_owner, pthread_main_np as guest code
//   0x3c Perf 21: CheckBit terminals branch on the IsZero ZF
//   0x3b Perf 20: conditional branches on the live host flags after SetNZCV
//   0x3a Perf 19: r15 points 128 bytes into the JitState (disp8 guest registers)
//   0x38 Perf 18: QoS encode/decode, recursive unfair lock as guest code
//   0x37 Perf 17: zone API, malloc_default_zone, malloc_good_size fast paths
//   0x35 Perf 16: malloc/calloc/free fast paths as guest code (long ones in dead libmalloc functions)
//   0x33 Perf 15: strncmp, memchr, strchr, strnlen, os_unfair_lock fast paths as guest code
//   0x30 Perf 14: NZCV, x0, x8 pinned in r12-r14
//   0x2a Perf 9: forward block links skip the halt check
//   0x29 Perf 8: import stubs link to the libsystem stub dylibs, fixed in the cache window; their svc thunk blocks persisted
//   0x25 Perf 7: PopRSB hit path inline per return site
//   0x24 Perf 6: RSB 32 entries
//   0x23 Perf 5: spills to free callee-saved GPRs first
//   0x22 Perf 4: GetSetElimination forwards W<->X
//   0x21 Perf 1f: no objc_msgSend hit/miss counters
//   0x20 Perf 1c: image RSB push sites linked at load
//   0x1f Perf 1b: unlinked RSB entries go to the fast dispatch handler
//   0x1e Perf 1: dyld_sim's some_image_overridden count patched (dyldsim.cpp)
//   0x1d RAM 13: host calls through a fixed stub page (no reach limit)
//   0x1c LSE atomics/CAS/CASP drop a top-byte tag inline
//   0x1b RAM 3: unchecked fastmem (no inline address check, r13 allocatable)
//   0x1a Speed 35: inline FRINTA/FRINTX, FCVTAS/FCVTAU in image chunks
//   0x19 Speed 25: RSB push sites persisted unlinked
//   0x18 RSB on
//   0x17 Swift scan steps found per runtime
//   0x15 Speed 20: lock-free exclusive monitor
constexpr u64 kCodegenVersion = 0x00000040ull;
// kCodegenVersion (bits 0-15), code-shaping env flags (16-18), placement table hash (32-63). The load base is not
// part of it (relocations cover every base; a mapped image is keyed by its layout instead, see LoadPersistentCache).
u64 g_build = kCodegenVersion;
std::string g_key, g_aot_path;
bool g_aot_eligible = false;
bool g_aot_loaded = false;

uint8_t g_uuid[16]{};
bool g_uuid_ok = false;
std::string g_dir;
std::string g_path;
std::string g_cache_file;  // the main dyld cache file (Linux path)
std::weak_ptr<Dynarmic::A64::Jit::SharedCode> g_shared;

}  // namespace

// Simulator scratch dir: $X86SIM_SCRATCH, else <home>/scratch/x86sim. launchd jobs get no sim.env, so the home comes
// from the passwd entry of the real uid (HOME may be scrubbed or the guest's), then $HOME.
const std::string &scratch_dir() {
    static const std::string d = [] {
        if (const char *s = getenv("X86SIM_SCRATCH"); s && *s) return std::string(s);
        const char *home = nullptr;
        if (struct passwd *pw = getpwuid(getuid())) home = pw->pw_dir;
        if (!home || !*home) home = getenv("HOME");
        return std::string(home ? home : "") + "/scratch/x86sim";
    }();
    return d;
}

namespace {
std::string default_dir() {
    if (const char *d = getenv("X86SIM_A64_JITCACHE_DIR")) return d;
    return scratch_dir() + "/jitcache";
}
// X86SIM_A64_JITCACHE=0: no .bin / image load or save
bool jitcache_off() {
    static const bool off = getenv("X86SIM_A64_JITCACHE") && atoi(getenv("X86SIM_A64_JITCACHE")) == 0;
    return off;
}

// Speed 14: placement.txt lines "addr slot fsize mtime key" (hex addr/slot; key = path from RuntimeRoot/ on, or the
// app bundle path from Containers/ on). The table's hash is part of the key: another layout drops the image.
std::vector<Placement> g_place;
std::string g_runtime_root;  // Linux path of RuntimeRoot/ (from the cache path)
std::vector<bool> g_place_used;
std::mutex g_place_mu;
u32 placement_load(const std::string &dir) {
    if (const char *e = getenv("X86SIM_A64_PLACEMENT"); e && atoi(e) == 0) return 0;
    FILE *f = fopen((dir + "/placement.txt").c_str(), "r");
    if (!f) return 0;
    u32 h = 2166136261u;
    char line[4096];
    while (fgets(line, sizeof line, f)) {
        for (char *c = line; *c; c++) h = (h ^ (uint8_t)*c) * 16777619u;
        Placement p{};
        int n = 0;
        if (sscanf(line, "%lx %lx %lu %lu %n", &p.addr, &p.slot, &p.fsize, &p.mtime, &n) != 4 || !n) continue;
        p.key = line + n;
        while (!p.key.empty() && (p.key.back() == '\n' || p.key.back() == '\r')) p.key.pop_back();
        // inside the cache window's free top only (reserved PROT_NONE by host.cpp; nothing else maps there)
        if (p.addr < 0x2ac000000ull || p.addr + p.slot > kCacheHi || (p.addr & 0x3fff) || p.key.empty()) continue;
        g_place.push_back(p);
    }
    fclose(f);
    g_place_used.assign(g_place.size(), false);
    return g_place.empty() ? 0 : h;
}

bool aot_eligible(const std::string &exe) {
    if (const char *a = getenv("X86SIM_A64_AOT"); a && atoi(a) == 0) return false;
    const char *b = strrchr(exe.c_str(), '/');
    std::string base = b ? b + 1 : exe;
    // Speed 28 (debug): X86SIM_A64_AOT_EXCLUDE=name,name keeps those processes off the image (bisecting)
    if (const char *x = getenv("X86SIM_A64_AOT_EXCLUDE"); x && (std::string(",") + x + ",").find("," + base + ",") != std::string::npos)
        return false;
    if (const char *l = getenv("X86SIM_A64_AOT_PROCS")) {
        std::string list = std::string(",") + l + ",";
        // Speed 7: "all" only where the image can be mapped shared (ASLR off: launchd_sim's children); elsewhere it
        // would be a private ~200 MB copy.
        if (list == ",all,") return (personality(0xffffffff) & ADDR_NO_RANDOMIZE) != 0;
        return list.find("," + base + ",") != std::string::npos;
    }
    // Speed 9: metalhostd is back on the image. Its Speed 8 NULL reads (MTLSimImplementation+0x218c/+0x1f6c) were not
    // the image: the logs show them in runs without it too. A command on a connection whose init found no
    // application context (NULL MTLSimApplicationContext*); host/metalhostd now cancels such connections.
    // Speed 9: not launchd_sim. Its libarm64jit lands elsewhere, so its prelude matches the image's only by chance
    // (near/far host calls); when it did, it built a layout of its own: a private 234 MB .map file, +60 MB PSS and
    // a 3 s slower start for the process every other one waits on.
    if (base == "launchd_sim") return false;
    // Speed 7: every process that can map the image shared (ASLR off: launchd_sim's children). With lazy metadata a
    // daemon pays ~1 MB for it and its shared-cache code becomes shared pages. Elsewhere: apps and backboardd.
    if (personality(0xffffffff) & ADDR_NO_RANDOMIZE) return true;
    return exe.find(".app/") != std::string::npos || (b && !strcmp(b + 1, "backboardd"));
}

}  // namespace

const Placement *placement_find(const char *path) {
    const size_t n = strlen(path);
    for (const auto &p : g_place)
        if (n >= p.key.size() && !memcmp(path + n - p.key.size(), p.key.data(), p.key.size()) &&
            (n == p.key.size() || path[n - p.key.size() - 1] == '/'))
            return &p;
    return nullptr;
}

bool placement_claim(const Placement *p, int fd) {
    struct stat st;
    if (fstat(fd, &st) || (u64)st.st_size != p->fsize || (u64)st.st_mtime != p->mtime) return false;
    std::lock_guard<std::mutex> l(g_place_mu);
    const size_t i = p - g_place.data();
    if (g_place_used[i]) return false;
    g_place_used[i] = true;
    return true;
}

void jitcache_prepare(const std::string &cache_path, const std::string &exe) {
    // Speed 7: FastDispatch table per process: 256K entries (4 MB) for apps and backboardd, whose hot sets need it;
    // 64K (1 MB) for daemons. X86SIM_A64_FD_ENTRIES=n overrides.
    {
        const char *b = strrchr(exe.c_str(), '/');
        size_t n = exe.find(".app/") != std::string::npos || (b && !strcmp(b + 1, "backboardd")) ? 0x40000 : 0x10000;
        if (const char *e = getenv("X86SIM_A64_FD_ENTRIES")) n = strtoul(e, nullptr, 0);
        Dynarmic::A64::Jit::SetFastDispatchEntries(n);
    }
    g_dir = default_dir();
    // cache_path is often a Darling path (/Volumes/SystemRoot/...); this ELF uses glibc fopen.
    std::string linux_path = cache_path;
    const char *prefix = "/Volumes/SystemRoot";
    if (linux_path.rfind(prefix, 0) == 0)
        linux_path = linux_path.substr(strlen(prefix));
    // Collapse accidental double slashes in the directory join from host.cpp.
    while (linux_path.find("//") != std::string::npos)
        linux_path.replace(linux_path.find("//"), 2, "/");
    if (size_t r = linux_path.find("/System/Library/Caches/com.apple.dyld/"); r != std::string::npos)
        g_runtime_root = linux_path.substr(0, r + 1);
    g_cache_file = linux_path;
    FILE *f = fopen(linux_path.c_str(), "rb");
    if (!f) {
        logf("jitcache: cannot open %s", linux_path.c_str());
        return;
    }
    // dyld_cache_header.uuid at 0x58 on this cache format.
    if (fseek(f, 0x58, SEEK_SET) != 0 || fread(g_uuid, 1, 16, f) != 16) {
        fclose(f);
        logf("jitcache: cannot read UUID");
        return;
    }
    fclose(f);
    g_uuid_ok = true;
    char hex[40];
    for (int i = 0; i < 16; i++) sprintf(hex + 2 * i, "%02x", g_uuid[i]);
    auto on = [](const char *e, bool dflt) { const char *v = getenv(e); return v ? atoi(v) == 1 : dflt; };
    g_build = kCodegenVersion | (u64)on("X86SIM_A64_FUSE_SVC", false) << 16 | (u64)on("X86SIM_A64_INLINE_OBJC", true) << 17 |
              (u64)timebase_apple() << 18 |
              (u64)strict_monitor() << 19 | (u64)memcheck() << 20;  // CNTFRQ and the Swift deadline patch are in the code
    if (u32 ph = placement_load(g_dir)) {
        g_build |= (u64)ph << 32;
        if (getenv("X86SIM_A64_STATS")) logf("placement: %zu files, table %08x", g_place.size(), ph);
    }
    char bh[24];
    snprintf(bh, sizeof bh, "%016llx", (unsigned long long)g_build);
    g_key = std::string(hex) + "-" + bh;
    const char *b = strrchr(exe.c_str(), '/');
    g_path = g_dir + "/" + g_key + "." + (b ? b + 1 : exe.c_str()) + ".bin";
    g_aot_path = g_dir + "/" + g_key + ".aot";
    g_aot_eligible = aot_eligible(exe);
    if (getenv("X86SIM_A64_STATS"))
        logf("jitcache: path %s", g_path.c_str());
}

u64 jitcache_image_code_bytes() {
    if (!g_uuid_ok || !g_aot_eligible || jitcache_off()) return 0;
    u64 code = 0;
    if (FILE *f = fopen(g_aot_path.c_str(), "rb")) {
        if (fseek(f, 32, SEEK_SET) || fread(&code, 8, 1, f) != 1) code = 0;  // PersistHeader::code_size
        fclose(f);
    }
    return code;
}

void jitcache_try_load(Dynarmic::A64::Jit::SharedCode &shared) {
    if (!g_uuid_ok) return;
    // Speed 28 (debug): X86SIM_A64_LIVE_ONLY=name,name: no image and no .bin (every block translated live)
    if (const char *x = getenv("X86SIM_A64_LIVE_ONLY")) {
        const size_t sl = g_path.rfind('/');
        const std::string f = g_path.substr(sl + 1);  // <key>.<exe>.bin
        for (std::string l = std::string(x) + ","; !l.empty();) {
            const std::string n = l.substr(0, l.find(','));
            l = l.substr(l.find(',') + 1);
            if (!n.empty() && f.size() > n.size() + 5 && f.compare(f.size() - n.size() - 5, n.size() + 5, "." + n + ".bin") == 0) {
                logf("jitcache: live only (X86SIM_A64_LIVE_ONLY)");
                g_uuid_ok = false;  // no save either
                return;
            }
        }
    }
    if (jitcache_off()) return;
    // Perf 8: blocks of the libsystem stub dylibs (fixed in the cache window) are in the image and the .bin files. The
    // first process of a key records the stubs' code hash; one whose stubs differ neither loads nor saves.
    {
        const std::string hp = g_dir + "/" + g_key + ".stubs";
        unsigned long long want = 0;
        FILE *f = fopen(hp.c_str(), "r");
        if (f && fscanf(f, "%llx", &want) != 1) want = 0;
        if (f) fclose(f);
        if (!want) {
            const std::string tmp = hp + ".tmp." + std::to_string(getpid());
            if (FILE *w = fopen(tmp.c_str(), "w")) { fprintf(w, "%016llx\n", (unsigned long long)stub_code_hash()); fclose(w); }
            if (link(tmp.c_str(), hp.c_str()) != 0 && (f = fopen(hp.c_str(), "r"))) { if (fscanf(f, "%llx", &want) != 1) want = 0; fclose(f); }
            unlink(tmp.c_str());
        }
        if (want && want != stub_code_hash()) {
            logf("jitcache: stub dylib code %016llx is not this key's %016llx: no image or .bin", (unsigned long long)stub_code_hash(), want);
            g_uuid_ok = false;
            return;
        }
    }
    struct stat st;
    const std::string &path = g_aot_eligible && stat(g_aot_path.c_str(), &st) == 0 ? g_aot_path : g_path;
    if (stat(path.c_str(), &st) != 0) return;
    timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    // Speed 6: the AOT image's code is mapped from a relocated copy shared by every process with the same layout
    // (X86SIM_A64_AOT_SHARE=0: private copy as before).
    const bool share = &path == &g_aot_path && !(getenv("X86SIM_A64_AOT_SHARE") && atoi(getenv("X86SIM_A64_AOT_SHARE")) == 0);
    size_t n = Dynarmic::A64::Jit::LoadPersistentCache(shared, path, g_uuid, g_build, kCacheLo, kCacheHi, share);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    g_aot_loaded = n && &path == &g_aot_path;
    if (n)
        logf("jitcache: loaded %zu blocks from %s (%.1f MB, %.0f ms)", n, path.c_str(), st.st_size / 1048576.0,
             (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
    else
        logf("jitcache: load miss or mismatch for %s", path.c_str());
}

void jitcache_try_save(Dynarmic::A64::Jit::SharedCode &shared, const std::string &to) {
    if (!g_uuid_ok) return;
    const std::string &dst = to.empty() ? g_path : to;
    if (jitcache_off()) return;
    mkdir(g_dir.c_str(), 0755);
    std::string tmp = dst + ".tmp." + std::to_string(getpid());  // Speed 8: two sim instances save the same <exe>.bin
    size_t bytes = Dynarmic::A64::Jit::SavePersistentCache(shared, tmp, g_uuid, g_build, kCacheLo, kCacheHi);
    if (!bytes) {
        if (getenv("X86SIM_A64_STATS")) logf("jitcache: nothing to save");
        return;
    }
    if (rename(tmp.c_str(), dst.c_str()) != 0) {
        logf("jitcache: rename failed");
        unlink(tmp.c_str());
        return;
    }
    logf("jitcache: saved %.1f MB to %s", bytes / 1048576.0, dst.c_str());
}

// Speed 5: the cache used to be written only on SIGUSR1 or at exit with X86SIM_A64_STATS, so normal use never warmed
// it. Now a low-priority thread saves this process's .bin once translation has been quiet (<500 new blocks per 10 s)
// for ~20 s, or every 120 s while it keeps growing, when at least
// kMinNewBlocks blocks were added since the last save/load, and __exit saves under the same threshold
// (jitcache_save_on_exit). The snapshot holds the shared lock only for the copy (no unlink; see SavePersistentCache).
// X86SIM_A64_JITCACHE_AUTOSAVE=0 turns both off.
constexpr u64 kMinNewBlocks = 5000;
std::atomic<u64> g_saved_blocks{0};

// Speed 9: not in a process that loaded the AOT image (X86SIM_A64_AOT_AUTOSAVE=1 to keep it, for training .bins). Its
// .bin is never read back while the image exists, yet every such process wrote one of ~240 MB (the image's blocks
// registered so far): ~6.5 GB per boot.
// Speed 31: training feedback from processes on the AOT image. Their .bin is never written (above), so blocks the image
// lacks (untrained paths of cache libraries, placed app code) were translated live on every start, forever. With
// X86SIM_A64_AOT_LIVE=1 (opt-in; Speed 32: as a default it grew the image past the slab) such a process keeps <key>.<exe>.live: the union of the descriptors it translated itself
// (header like an A64JC06 file, descriptor count at +40, 24-byte entries from +160, no code). tools/launcher's hot set
// reads them like training .bins, so `x86sim-aot update` moves those blocks into their library's chunk.
static bool live_env() {
    // Speed 33: default on (=0 off) now that feedback rebuilds stay in their slots (x86sim-aot)
    static const bool on = [] { const char *e = getenv("X86SIM_A64_AOT_LIVE"); return !e || atoi(e) != 0; }();
    return on;
}
static bool live_on() {
    return live_env() && g_aot_loaded && g_uuid_ok && !getenv("X86SIM_A64_AOT_BUILD");
}
std::atomic<u64> g_live_saved{0};
// RAM 2 (JIT): the .live file was the union of every session's live translations, forever (SpringBoard.live: 1.2M
// descriptors; the training set grew ~400 MB a day, so each full build left more out). Now it is what this program
// used in its last kLiveKeep sessions: its live translations and the image blocks it ran (both are training, the
// image blocks keep their place), each entry with the number of sessions since it was last used. Entries: u64
// descriptor, u32 flags (bit 0: translated live at some point), u32 age; header byte 48 = 2 ("A64JC06" files of
// format 1 have zeros there and only live translations: read with flags 1, age 0). Several processes of one program
// (WebContent) share the file: the last writer's view wins.
constexpr u32 kLiveKeep = 8;
struct LiveEnt {
    u32 flags, age;
};
static std::mutex g_live_mu;
static std::unordered_map<u64, LiveEnt> *g_live_set;  // this session's view (file entries aged once + what it used)
static void save_live(Dynarmic::A64::Jit::SharedCode &sc, const char *why) {
    if (!live_on()) return;
    const u64 n = Dynarmic::A64::Jit::GetSharedStats(sc).blocks;
    if (n < g_live_saved.load() + 500) return;
    std::lock_guard lk(g_live_mu);
    g_live_saved = n;
    std::string path = g_path.substr(0, g_path.size() - 4) + ".live";
    if (!g_live_set) {
        g_live_set = new std::unordered_map<u64, LiveEnt>;
        if (FILE *f = fopen(path.c_str(), "rb")) {
            uint8_t h[160];
            u64 m = 0;
            if (fread(h, 1, 160, f) == 160 && !memcmp(h, "A64JC06", 8) && (memcpy(&m, h + 40, 8), m < (1u << 26))) {
                const bool v2 = h[48] == 2;
                g_live_set->reserve(m);
                uint8_t e[24];
                for (u64 i = 0; i < m && fread(e, 1, 24, f) == 24; i++) {
                    u64 x;
                    LiveEnt le{1, 0};
                    memcpy(&x, e, 8);
                    if (v2) memcpy(&le, e + 8, 8);
                    le.age++;  // one more session; reset below for what this one uses
                    if (le.age <= kLiveKeep) (*g_live_set)[x] = le;
                }
            }
            fclose(f);
        }
    }
    for (u64 d : Dynarmic::A64::Jit::GetDynamicDescriptors(sc, kCacheLo, kCacheHi)) (*g_live_set)[d] = {1, 0};
    for (u64 d : Dynarmic::A64::Jit::GetUsedImageDescriptors(sc, kCacheLo, kCacheHi)) {
        auto [it, fresh] = g_live_set->try_emplace(d, LiveEnt{0, 0});
        if (!fresh) it->second.age = 0;
    }
    std::vector<std::pair<u64, LiveEnt>> d(g_live_set->begin(), g_live_set->end());
    std::sort(d.begin(), d.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    const std::string tmp = path + ".tmp." + std::to_string(getpid());
    FILE *f = fopen(tmp.c_str(), "wb");
    if (!f) return;
    uint8_t h[160]{};
    memcpy(h, "A64JC06", 8);
    memcpy(h + 8, g_uuid, 16);
    memcpy(h + 24, &g_build, 8);
    const u64 cnt = d.size();
    memcpy(h + 40, &cnt, 8);
    h[48] = 2;
    fwrite(h, 1, 160, f);
    uint8_t e[24]{};
    size_t live_n = 0, cur = 0;
    for (const auto &[x, le] : d) {
        memcpy(e, &x, 8);
        memcpy(e + 8, &le, 8);
        fwrite(e, 1, 24, f);
        live_n += le.flags & 1;
        cur += le.age == 0;
    }
    const bool ok = fclose(f) == 0;
    if (ok && rename(tmp.c_str(), path.c_str()) == 0)
        logf("jitcache: %s live save: %zu descriptors (%zu used this session, %zu ever translated live) to %s", why, d.size(), cur, live_n, path.c_str());
    else
        unlink(tmp.c_str());
}

static bool autosave_on() {
    const char *e = getenv("X86SIM_A64_JITCACHE_AUTOSAVE");
    const char *a = getenv("X86SIM_A64_AOT_AUTOSAVE");
    if (g_aot_loaded && !(a && atoi(a) == 1)) return false;
    return !(e && atoi(e) == 0) && !jitcache_off() && !getenv("X86SIM_A64_AOT_BUILD");
}
static void save_if_grown(Dynarmic::A64::Jit::SharedCode &sc, const char *why) {
    if (!autosave_on()) return;  // the image is loaded after the saver thread starts
    const u64 n = Dynarmic::A64::Jit::GetSharedStats(sc).blocks;
    if (n < g_saved_blocks.load() + kMinNewBlocks) return;
    timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    jitcache_try_save(sc);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    g_saved_blocks = n;
    logf("jitcache: %s save at %llu blocks (%.0f ms)", why, (unsigned long long)n,
         (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
}

void jitcache_set_shared(const std::shared_ptr<Dynarmic::A64::Jit::SharedCode> &sp) {
    g_shared = sp;
    g_saved_blocks = Dynarmic::A64::Jit::GetSharedStats(*sp).blocks;  // what the load brought in
    if (!g_uuid_ok || (!autosave_on() && !live_env())) return;
    // The thread is not a Darling thread: with signals unblocked, a process-directed signal delivered to it made
    // mldr abort (metalhostd SIGABRT on the saver's tid). Block everything here; the guest's threads take them.
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    std::thread([] {
        g_non_darling_thread = true;
        setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
        // Busy processes (SpringBoard, backboardd, Preferences) never stop translating entirely: "quiet" is under
        // 500 new blocks per 10 s, and a save is forced every 120 s while the hot set keeps growing.
        u64 last = 0;
        int quiet = 0, since = 0;
        for (;;) {
            sleep(10);
            auto sp = g_shared.lock();
            if (!sp) return;
            const u64 n = Dynarmic::A64::Jit::GetSharedStats(*sp).blocks;
            quiet = n - last < 500 ? quiet + 1 : 0;
            last = n;
            since++;
            if (quiet >= 2 || since >= 12) {
                const u64 before = g_saved_blocks.load();
                save_if_grown(*sp, quiet >= 2 ? "idle" : "periodic");
                save_live(*sp, quiet >= 2 ? "idle" : "periodic");
                if (g_saved_blocks.load() != before) since = 0;
            }
        }
    }).detach();
    pthread_sigmask(SIG_SETMASK, &old, nullptr);
}

void jitcache_save_on_exit() {
    if (auto sp = g_shared.lock()) save_live(*sp, "exit");
    if (!autosave_on()) return;
    if (auto sp = g_shared.lock()) save_if_grown(*sp, "exit");
}

// X86SIM_A64_AOT_BUILD=1, at the builder's exit: translate the union of every training .bin's blocks (same key)
// on this thread and save them as the AOT image. Stops short of the code cache's end (a full cache is cleared).
// The AOT builder translates blocks of placed files too: map each file's segments (read-only; code needs no fixups)
// at its slot, as dyld_sim would in a sim process. Returns the number mapped.
int placement_map_all() {
    int n = 0;
    for (const auto &p : g_place) {
        // Speed 31: app keys ("Containers/...") resolve under the device's data dir (tools/launcher passes it as
        // X86SIM_A64_AOT_DEVICE_DATA); before, the app tier's files were never mapped and their chunks faulted.
        static const char *dev_data = getenv("X86SIM_A64_AOT_DEVICE_DATA");
        const bool app = p.key.rfind("Containers/", 0) == 0;
        if (app ? !dev_data : g_runtime_root.empty()) continue;
        const std::string path = app ? std::string(dev_data) + "/" + p.key : g_runtime_root + p.key;
        const bool is_dyld = p.key == "usr/lib/dyld_sim";
        int fd = open(path.c_str(), O_RDONLY);
        if (fd < 0) continue;
        struct stat st;
        uint8_t hdr[0x10000];
        u64 slice = 0;
        ssize_t got = fstat(fd, &st) == 0 && (u64)st.st_size == p.fsize ? pread(fd, hdr, sizeof hdr, 0) : -1;
        if (got >= 8 && !memcmp(hdr, "\xca\xfe\xba\xbe", 4)) {  // fat: the arm64 slice
            const uint32_t nf = __builtin_bswap32(*(const uint32_t *)(hdr + 4));
            for (uint32_t i = 0; i < nf && 8 + 20 * (i + 1) <= (uint32_t)got; i++)
                if (__builtin_bswap32(*(const u32 *)(hdr + 8 + 20 * i)) == 0x0100000Cu) slice = __builtin_bswap32(*(const u32 *)(hdr + 16 + 20 * i));
            got = slice ? pread(fd, hdr, sizeof hdr, slice) : -1;
        }
        if (got < 32 || *(const u32 *)hdr != 0xfeedfacfu) { close(fd); continue; }
        const u32 ncmds = *(const u32 *)(hdr + 16);
        u64 lo = ~0ull;
        for (int pass = 0; pass < 2; pass++) {
            u32 off = 32;
            for (u32 i = 0; i < ncmds && off + 72 <= (u32)got; i++) {
                const u32 cmd = *(const u32 *)(hdr + off), cs = *(const u32 *)(hdr + off + 4);
                if (cmd == 0x19) {
                    u64 vm, vs, fo, fs; memcpy(&vm, hdr + off + 24, 8); memcpy(&vs, hdr + off + 32, 8);
                    memcpy(&fo, hdr + off + 40, 8); memcpy(&fs, hdr + off + 48, 8);
                    const int ip = *(const int *)(hdr + off + 60);
                    if (!(ip == 0 && fs == 0)) {
                        if (pass == 0) lo = std::min(lo, vm);
                        else if (fs) mmap((void *)(p.addr + vm - lo), fs, PROT_READ | (is_dyld ? PROT_WRITE : 0), MAP_PRIVATE | MAP_FIXED, fd, slice + fo);
                    }
                }
                if (!cs) break;
                off += cs;
            }
        }
        close(fd);
        // dyld_sim runs patched (dyld_sim_patches, as host.cpp applies it at load): translate the same code
        if (is_dyld && lo != ~0ull) dyld_sim_patches(p.addr - lo);
        n++;
    }
    return n;
}

// Speed 18: the chunked AOT image (tools/launcher, x86sim-aot). X86SIM_A64_AOT_JOB=<job file>: this builder translates
// the listed chunks, one library / executable each, every one into its own slot of the slab, and saves each as a chunk
// file (A64CK01). x86sim-aot assembles the chunks into the <key>.aot image (its own assembler).
// Job file lines:
//   progress <file>                 JSON lines appended per chunk (and every ~100K blocks)
//   pool <file>                     union the constant pool of an existing chunk (every chunk kept in the image)
//   region <bytes>                  new constants go from this pool offset on (disjoint per parallel builder)
//   chunk <name> <slot_off> <slot_size> <out> <entries>
// Entries file (u64 LE): n_ranges, n_ranges x (lo, hi), n_hot, hot descriptors (hottest first), n_static, static PCs.
// Hot blocks are emitted first (contiguous at the slot start); then the static entries and every direct successor
// inside the ranges, breadth first. A block is only ever entered at its exact guest PC, so a guess that lands in
// data is translated but never runs: the guest must branch to that PC, i.e. it is code (immutable cache pages; a
// written page invalidates as before).
static void aot_job(GuestThread &t, Dynarmic::A64::Jit::SharedCode &sc, const char *job) {
    FILE *jf = fopen(job, "r");
    if (!jf) { logf("aot job: cannot open %s", job); return; }
    FILE *prog = nullptr;
    std::vector<uint8_t> pool;
    size_t region = 0;
    struct Chunk { std::string name, out, entries; u64 off, size; };
    std::vector<Chunk> chunks;
    char line[8192];
    while (fgets(line, sizeof line, jf)) {
        char a[4096], b[4096], c[4096];
        unsigned long long x, y;
        if (sscanf(line, "progress %4095s", a) == 1) prog = fopen(a, "a");
        else if (sscanf(line, "pool %4095s", a) == 1) {
            auto p = Dynarmic::A64::Jit::ReadPersistentPool(a);
            if (p.size() > pool.size()) pool.resize(p.size(), 0);
            for (size_t i = 0; i < p.size(); i++) if (p[i]) pool[i] = p[i];
        } else if (sscanf(line, "region %llu", &x) == 1) region = x;
        else if (sscanf(line, "chunk %4095s %llu %llu %4095s %4095s", a, &x, &y, b, c) == 5) chunks.push_back({a, b, c, x, y});
    }
    fclose(jf);
    auto emit = [&](const char *fmt, auto... args) {
        if (!prog) return;
        fprintf(prog, fmt, args...);
        fputc('\n', prog);
        fflush(prog);
    };
    if (!pool.empty() || region) Dynarmic::A64::Jit::SetConstantPoolRegion(sc, pool, std::max(region, pool.size()));
    if (!g_place.empty()) logf("aot job: mapped %d of %zu placed files", placement_map_all(), g_place.size());
    const u64 cap = Dynarmic::A64::Jit::CodeCapacity(sc);
    timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    emit("{\"event\":\"start\",\"chunks\":%zu,\"pid\":%d,\"codegen\":%llu}", chunks.size(), getpid(), (unsigned long long)kCodegenVersion);
    for (size_t ci = 0; ci < chunks.size(); ci++) {
        const Chunk &ch = chunks[ci];
        timespec c0, c1;
        clock_gettime(CLOCK_MONOTONIC, &c0);
        std::vector<u64> ranges, hot, stat;
        if (FILE *ef = fopen(ch.entries.c_str(), "rb")) {
            auto rd = [&](std::vector<u64> &v, u64 mul) {
                u64 n = 0;
                if (fread(&n, 8, 1, ef) != 1 || n > (1ull << 28)) return false;
                v.resize(n * mul);
                return fread(v.data(), 8, v.size(), ef) == v.size();
            };
            const bool ok = rd(ranges, 2) && rd(hot, 1) && rd(stat, 1);
            fclose(ef);
            if (!ok) { emit("{\"event\":\"chunk\",\"name\":\"%s\",\"i\":%zu,\"state\":\"error\",\"why\":\"entries\"}", ch.name.c_str(), ci); continue; }
        }
        if (ch.off + ch.size > cap) { emit("{\"event\":\"chunk\",\"name\":\"%s\",\"i\":%zu,\"state\":\"error\",\"why\":\"slot beyond slab\"}", ch.name.c_str(), ci); continue; }
        auto in_range = [&](u64 pc) {
            if (pc & 3) return false;
            for (size_t i = 0; i < ranges.size(); i += 2) if (pc >= ranges[i] && pc + 4 <= ranges[i + 1]) return true;
            return false;
        };
        Dynarmic::A64::Jit::BeginChunk(sc, ch.off);
        std::set<u64> seen;
        std::vector<u64> work, succ;
        u64 blocks = 0, tick = 0;
        bool overflow = false;
        // Stop this far before the slot end: the check runs before each PretranslateCollect, which can emit tens of KB
        // (a block and its far code). size/8 alone left 16 KB in a 128 KB slot ("all" scope) and the code ran past it.
        const u64 margin = std::min<u64>(std::max<u64>(ch.size / 8, 64 << 10), std::min<u64>(ch.size / 2, 256 << 10));
        const u64 limit = ch.off + ch.size - margin;
        // to: where the successors go (nullptr: not followed)
        auto one = [&](u64 d, std::vector<u64> *to) {
            if (!in_range(d & ((1ull << 56) - 1)) || !seen.insert(d).second) return;
            if (Dynarmic::A64::Jit::ChunkCodeEnd(sc) > limit) { overflow = true; return; }
            succ.clear();
            if (t.jit->PretranslateCollect(d, succ)) blocks++;
            if (to) for (u64 s : succ) if (!seen.count(s)) to->push_back(s);
            if (blocks - tick >= 100000) {
                tick = blocks;
                emit("{\"event\":\"progress\",\"name\":\"%s\",\"i\":%zu,\"blocks\":%llu,\"used\":%llu}", ch.name.c_str(), ci,
                     (unsigned long long)blocks, (unsigned long long)(Dynarmic::A64::Jit::ChunkCodeEnd(sc) - ch.off));
            }
        };
        // hot blocks first (contiguous at the slot start), then their successors and the static entries, depth first
        // from each entry (a function's blocks stay together)
        // without static entries (scope "hot": the trained blocks only) nothing is followed
        std::vector<u64> next;
        for (u64 d : hot) { if (overflow) break; one(d, stat.empty() ? nullptr : &next); }
        const u64 hot_used = Dynarmic::A64::Jit::ChunkCodeEnd(sc) - ch.off, hot_blocks = blocks;
        work.assign(next.rbegin(), next.rend());
        for (size_t i = 0; !overflow; i++) {
            while (!work.empty() && !overflow) {
                const u64 d = work.back();
                work.pop_back();
                one(d, &work);
            }
            if (i >= stat.size()) break;
            work.push_back(stat[i]);
        }
        const u64 used = Dynarmic::A64::Jit::ChunkCodeEnd(sc) - ch.off;
        const std::string tmp = ch.out + ".tmp." + std::to_string(getpid());
        // Never save code that ran past the slot: it would overlap the next chunk in the image (assembly refuses it).
        const bool past_slot = used > ch.size;
        if (past_slot) logf("aot: %s: code ran %llu bytes past its %llu-byte slot; not saved", ch.name.c_str(),
                            (unsigned long long)(used - ch.size), (unsigned long long)ch.size);
        size_t bytes = blocks && !past_slot ? Dynarmic::A64::Jit::SaveChunk(sc, tmp, g_uuid, g_build, kCacheLo, kCacheHi, ch.off) : 0;
        if (bytes && rename(tmp.c_str(), ch.out.c_str()) != 0) { unlink(tmp.c_str()); bytes = 0; }
        Dynarmic::A64::Jit::DiscardCode(sc, ch.off, ch.off + used);
        clock_gettime(CLOCK_MONOTONIC, &c1);
        emit("{\"event\":\"chunk\",\"name\":\"%s\",\"i\":%zu,\"state\":\"%s\",\"blocks\":%llu,\"used\":%llu,\"bytes\":%zu,\"overflow\":%s,\"secs\":%.2f,\"pool\":%zu,\"hot_used\":%llu,\"hot_blocks\":%llu}",
             ch.name.c_str(), ci, bytes ? "done" : (blocks ? "error" : "empty"), (unsigned long long)blocks, (unsigned long long)used, bytes,
             overflow ? "true" : "false", (c1.tv_sec - c0.tv_sec) + (c1.tv_nsec - c0.tv_nsec) / 1e9, Dynarmic::A64::Jit::ConstantPoolUsed(sc),
             (unsigned long long)hot_used, (unsigned long long)hot_blocks);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    emit("{\"event\":\"end\",\"secs\":%.2f}", (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
    if (prog) fclose(prog);
}

void jitcache_aot_build(GuestThread &t) {
    auto sp = g_shared.lock();
    if (!g_uuid_ok || !sp) { logf("aot: no shared code / cache key"); return; }
    if (const char *job = getenv("X86SIM_A64_AOT_JOB")) { aot_job(t, *sp, job); return; }
    timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    std::set<u64> descs;
    int files = 0;
    if (DIR *d = opendir(g_dir.c_str())) {
        // Any build's training files for this image: the hot set (block PCs) outlives codegen changes.
        const std::string pre = g_key.substr(0, 32) + "-";
        while (dirent *e = readdir(d)) {
            std::string n = e->d_name;
            if (n.rfind(pre, 0) != 0 || n.size() < 4 || n.compare(n.size() - 4, 4, ".bin") != 0) continue;
            auto v = Dynarmic::A64::Jit::ReadPersistentDescriptors(g_dir + "/" + n, g_uuid, 0);
            logf("aot: %s: %zu blocks", n.c_str(), v.size());
            descs.insert(v.begin(), v.end());
            files++;
        }
        closedir(d);
    }
    const u64 limit = (u64)(getenv("X86SIM_A64_CODECACHE_MB") ? atoi(getenv("X86SIM_A64_CODECACHE_MB")) : 256) * 7 / 8 << 20;
    if (!g_place.empty()) logf("aot: mapped %d of %zu placed files", placement_map_all(), g_place.size());
    size_t done = 0;
    for (u64 ld : descs) {
        if (Dynarmic::A64::Jit::GetSharedStats(*sp).code_bytes > limit) { logf("aot: code cache limit reached"); break; }
        t.jit->Pretranslate(ld);
        done++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    logf("aot: %d files, %zu unique blocks, translated %zu in %.1f s", files, descs.size(), done,
         (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
    jitcache_try_save(*sp, g_aot_path);
}

void jitcache_save_if_shared() {
    // RAM 2 (JIT): SIGUSR1 (memlog) in a process on the AOT image wrote a whole-slab .bin (1.2-1.3 GB: every image
    // block it had registered) over its training profile; it saves only its .live there, like the autosave thread.
    if (g_aot_loaded && !autosave_on()) {
        if (auto sp = g_shared.lock()) save_live(*sp, "memlog");
        return;
    }
    if (auto sp = g_shared.lock()) {
        jitcache_try_save(*sp);
        g_saved_blocks = Dynarmic::A64::Jit::GetSharedStats(*sp).blocks;
    }
}

const std::string &jitcache_cache_file() { return g_cache_file; }
std::string jitcache_path() { return g_path; }

}  // namespace a64
