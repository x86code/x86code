// libarm64jit: arm64 stub dylibs for the three host libraries (libsystem_kernel/platform/pthread).
//
// The iOS 27 cache only has header-only placeholders for them; dyld_sim loads the real ones from the host's
// /usr/lib/system. We generate those at startup: an arm64 MH_DYLIB whose export trie has every name of the
// placeholder's trie (so the list is never maintained by hand). A function export is an 8-byte "svc #i; ret" stub in
// __TEXT; a data export is an absolute symbol pointing at Darling's own variable (or at a guest-specific copy, e.g.
// vm_page_size = 16K). The file lives in a memfd; open() of the install name returns it.
#include "a64.h"
#include <algorithm>
#include <cstdio>
#include <fcntl.h>
#include <map>
#include "macho.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace a64 {

namespace {

u64 uleb(const uint8_t *&p) {
    u64 r = 0; int s = 0;
    for (;;) { uint8_t c = *p++; r |= (u64)(c & 0x7f) << s; s += 7; if (c < 0x80) return r; }
}
void put_uleb(std::vector<uint8_t> &o, u64 v) {
    do { uint8_t c = v & 0x7f; v >>= 7; if (v) c |= 0x80; o.push_back(c); } while (v);
}
size_t uleb_len(u64 v) { size_t n = 1; while (v >= 0x80) { v >>= 7; n++; } return n; }

void walk_trie(const uint8_t *start, const uint8_t *end, const uint8_t *p, std::string &prefix, std::vector<std::string> &out,
               std::vector<u64> *values = nullptr) {
    if (p >= end) return;
    u64 ts = uleb(p);
    if (ts) {
        out.push_back(prefix);
        if (values) { const uint8_t *q = p; u64 fl = uleb(q); values->push_back(fl & 8 /* reexport */ ? ~0ull : uleb(q)); }
    }
    p += ts;
    uint8_t n = *p++;
    for (uint8_t i = 0; i < n; i++) {
        const char *s = (const char *)p;
        size_t len = strlen(s);
        p += len + 1;
        u64 off = uleb(p);
        size_t keep = prefix.size();
        prefix.append(s, len);
        walk_trie(start, end, start + off, prefix, out, values);
        prefix.resize(keep);
    }
}

// ---- export trie writer ----
struct Entry { std::string name; u64 flags, value; };
struct Node {
    const Entry *term = nullptr;
    std::vector<std::pair<std::string, std::unique_ptr<Node>>> edges;
    u32 offset = 0;
};
std::unique_ptr<Node> build(const std::vector<Entry> &v, size_t lo, size_t hi, size_t depth) {
    auto n = std::make_unique<Node>();
    if (lo < hi && v[lo].name.size() == depth) n->term = &v[lo++];
    while (lo < hi) {
        char c = v[lo].name[depth];
        size_t j = lo;
        while (j < hi && v[j].name[depth] == c) j++;
        const std::string &a = v[lo].name, &b = v[j - 1].name;
        size_t L = depth;
        while (L < a.size() && L < b.size() && a[L] == b[L]) L++;
        n->edges.emplace_back(a.substr(depth, L - depth), build(v, lo, j, L));
        lo = j;
    }
    return n;
}
void collect(Node *n, std::vector<Node *> &order) { order.push_back(n); for (auto &e : n->edges) collect(e.second.get(), order); }
std::vector<uint8_t> write_trie(std::vector<Entry> entries) {
    std::sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) { return a.name < b.name; });
    auto root = build(entries, 0, entries.size(), 0);
    std::vector<Node *> order; collect(root.get(), order);
    std::vector<uint8_t> out;
    for (bool changed = true; changed;) {  // node offsets depend on uleb sizes of other offsets: iterate to a fixpoint
        changed = false; u32 off = 0;
        for (Node *n : order) {
            if (n->offset != off) { n->offset = off; changed = true; }
            size_t ts = n->term ? uleb_len(n->term->flags) + uleb_len(n->term->value) : 0;
            off += uleb_len(ts) + ts + 1;
            for (auto &e : n->edges) off += e.first.size() + 1 + uleb_len(e.second->offset);
        }
    }
    for (Node *n : order) {
        if (n->term) {
            put_uleb(out, uleb_len(n->term->flags) + uleb_len(n->term->value));
            put_uleb(out, n->term->flags); put_uleb(out, n->term->value);
        } else out.push_back(0);
        out.push_back((uint8_t)n->edges.size());
        for (auto &e : n->edges) { out.insert(out.end(), e.first.begin(), e.first.end()); out.push_back(0); put_uleb(out, e.second->offset); }
    }
    while (out.size() % 8) out.push_back(0);
    return out;
}

// Is a native address inside an instruction section of its (Darling x86_64) Mach-O image?
bool native_is_code(const void *addr) {
    if (is_fast_fill(addr)) return true;  // our replacements for Darling's fills (host.cpp dsym)
    struct { const char *fname; void *fbase; const char *sname; void *saddr; } info{};
    if (!g_darwin->dladdr(addr, &info) || !info.fbase) return false;
    auto *mh = (const mach_header_64 *)info.fbase;
    const uint8_t *lc = (const uint8_t *)(mh + 1);
    u64 slide = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const load_command *)lc)->cmdsize) {
        auto *sg = (const segment_command_64 *)lc;
        if (sg->cmd == LC_SEGMENT_64 && !strcmp(sg->segname, "__TEXT")) slide = (u64)mh - sg->vmaddr;
    }
    lc = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const load_command *)lc)->cmdsize) {
        auto *sg = (const segment_command_64 *)lc;
        if (sg->cmd != LC_SEGMENT_64) continue;
        auto *sc = (const section_64 *)(sg + 1);
        for (uint32_t k = 0; k < sg->nsects; k++)
            if ((u64)addr >= sc[k].addr + slide && (u64)addr < sc[k].addr + slide + sc[k].size)
                return sc[k].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    }
    return false;
}

// Guest-specific data (arm64 values where they differ from Darling's x86_64 ones).
u64 g_vm_page_size = 16384, g_vm_page_mask = 16383;
int g_vm_page_shift = 14;
int g_cpu_caps = 0;
double g_kernel_version_number = 12377.0;
const char g_kernel_version_string[] = "@(#)VERSION:Darwin Kernel Version 26.0.0: x86Sim arm64 under dynarmic";
const std::map<std::string, const void *> &guest_data() {
    static const std::map<std::string, const void *> m = {
        {"_vm_page_size", &g_vm_page_size}, {"_vm_page_mask", &g_vm_page_mask}, {"_vm_page_shift", &g_vm_page_shift},
        {"_vm_kernel_page_size", &g_vm_page_size}, {"_vm_kernel_page_mask", &g_vm_page_mask},
        {"_vm_kernel_page_shift", &g_vm_page_shift}, {"__cpu_capabilities", &g_cpu_caps},
        {"____kernelVersionNumber", &g_kernel_version_number}, {"____kernelVersionString", g_kernel_version_string},
    };
    return m;
}

std::vector<StubLib> g_libs;
// Platforms 1: the dyld cache's platform (its header's platform field: 7 iOS, 8 tvOS, 9 watchOS simulator). dyld_sim
// refuses a dylib built for another platform ("incompatible platform (have 'iOS-simulator', need 'tvOS-simulator')"),
// so the stubs carry the cache's own. Set by cache_exports, which every stub's export list comes from.
uint32_t g_cache_platform = 7;
u64 g_stub_code_hash = 0xcbf29ce484222325ull;  // FNV-1a over each stub's install name and __TEXT

// A real file with the stub's bytes, for F_GETPATH. dyld_sim records an image's path from F_GETPATH on the fd it
// opened; Darling answers that from /proc/self/fd, which for the memfd is "memfd:libsystem_kernel.dylib (deleted)", and
// every process's XPC service bootstrap then failed on that path in launchd (~120 "Failed to bootstrap path" errors a
// boot). The answer must not be the install name: that is also the dyld cache placeholder's path, and dyld then took the
// stub for the cache image ("Library not loaded: /usr/lib/libSystem.B.dylib" in every process).
std::string stub_real_copy(const std::string &install, const std::vector<uint8_t> &f) {
    // in the JIT cache dir (every phone and builder has one; Linux paths are seen by Darling under /Volumes/SystemRoot):
    // /run/user is not the host's inside a phone's container. One file per library, written once: the bytes differ by
    // process (data exports point at this process's Darling variables), but only the path is used (open() of the
    // install name still returns this process's memfd), so naming it by content made one copy per process.
    const char *jc = getenv("X86SIM_A64_JITCACHE_DIR");
    if (!jc || jc[0] != '/') return "";
    const std::string dir = std::string(jc) + "/stubs", file = dir + "/" + install.substr(install.rfind('/') + 1);
    struct stat st;
    if (stat(file.c_str(), &st) != 0) {
        mkdir(dir.c_str(), 0755);
        const std::string tmp = file + ".tmp." + std::to_string(getpid());
        int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0) return "";
        const bool ok = write(fd, f.data(), f.size()) == (ssize_t)f.size();
        close(fd);
        if (!ok || rename(tmp.c_str(), file.c_str()) != 0) { unlink(tmp.c_str()); if (stat(file.c_str(), &st) != 0) return ""; }
    }
    return "/Volumes/SystemRoot" + file;
}

}  // namespace

std::vector<std::string> cache_exports(const std::string &cache_path, const std::string &image, std::vector<u64> *addrs,
                                       u64 *text_lo, u64 *text_hi) {
    struct File { const uint8_t *p; size_t size; };
    std::vector<File> files;
    static const char *suffixes[] = {"", ".01", ".02", ".03", ".04", ".05", ".06", ".07", ".08", ".09", ".10"};
    static auto *dopen = (int (*)(const char *, int, ...))dsym("open");
    for (const char *s : suffixes) {
        int fd = dopen((cache_path + s).c_str(), O_RDONLY);
        if (fd < 0) break;
        struct stat st; fstat(fd, &st);
        void *p = mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (p == MAP_FAILED) die("cannot map %s%s", cache_path.c_str(), s);
        files.push_back({(const uint8_t *)p, (size_t)st.st_size});
    }
    if (files.empty()) die("cannot open the shared cache %s", cache_path.c_str());
    auto rd = [&](u64 addr) -> const uint8_t * {
        for (auto &f : files) {
            uint32_t mo, mc; memcpy(&mo, f.p + 0x10, 4); memcpy(&mc, f.p + 0x14, 4);
            for (uint32_t i = 0; i < mc; i++) {
                u64 a, sz, fo; memcpy(&a, f.p + mo + 32 * i, 8); memcpy(&sz, f.p + mo + 32 * i + 8, 8); memcpy(&fo, f.p + mo + 32 * i + 16, 8);
                if (addr >= a && addr < a + sz) return f.p + fo + (addr - a);
            }
        }
        die("address %#lx is not in the cache", (unsigned long)addr);
    };
    const uint8_t *h = files[0].p;
    {
        uint32_t plat; memcpy(&plat, h + 0xD8, 4);  // dyld_cache_header.platform
        if (plat == 7 || plat == 8 || plat == 9 || plat == 12) g_cache_platform = plat;  // Platforms 2: 12 visionOS
    }
    uint32_t io, ic; memcpy(&io, h + 0x1C0, 4); memcpy(&ic, h + 0x1C4, 4);
    std::vector<std::string> out;
    for (uint32_t i = 0; i < ic; i++) {
        u64 addr; uint32_t po; memcpy(&addr, h + io + 32 * i, 8); memcpy(&po, h + io + 32 * i + 24, 4);
        if (image != (const char *)h + po) continue;
        auto *mh = (const mach_header_64 *)rd(addr);
        const uint8_t *lc = (const uint8_t *)(mh + 1);
        u64 le = 0; uint32_t toff = 0, tsize = 0;
        for (uint32_t k = 0; k < mh->ncmds; k++, lc += ((const load_command *)lc)->cmdsize) {
            auto *sg = (const segment_command_64 *)lc;
            if (sg->cmd == LC_SEGMENT_64 && !strcmp(sg->segname, "__LINKEDIT")) le = sg->vmaddr - sg->fileoff;
            if (sg->cmd == LC_SEGMENT_64 && !strcmp(sg->segname, "__TEXT") && text_lo) { *text_lo = sg->vmaddr; *text_hi = sg->vmaddr + sg->vmsize; }
            if (sg->cmd == LC_DYLD_EXPORTS_TRIE) { toff = ((const linkedit_data_command *)lc)->dataoff; tsize = ((const linkedit_data_command *)lc)->datasize; }
        }
        if (!tsize) die("%s has no export trie in the cache", image.c_str());
        const uint8_t *t = rd(le + toff);
        std::string prefix;
        walk_trie(t, t + tsize, t, prefix, out, addrs);
        if (addrs) for (u64 &v : *addrs) if (v != ~0ull) v += addr;
        break;
    }
    for (auto &f : files) munmap((void *)f.p, f.size);
    if (out.empty()) die("%s: not in the cache or no exports", image.c_str());
    return out;
}

StubLib build_stub_dylib(const std::string &install, const std::vector<std::string> &exports) {
    constexpr u64 kPage = 0x4000, kCodeStart = 0x1000;
    std::vector<uint32_t> code;
    std::vector<Entry> entries;
    struct Data { std::string name; const void *src; bool ours; };
    std::vector<Data> data;
    int nfunc = 0, ndata = 0, nmissing = 0;
    for (const auto &name : exports) {
        if (auto it = guest_data().find(name); it != guest_data().end()) {
            data.push_back({name, it->second, true}); ndata++; continue;
        }
        u64 at = kCodeStart + code.size() * 4;
        if (is_guest_code_export(name)) {
            const void *nat = dsym(name.c_str() + 1);  // slow path of guest-code fast paths
            uint32_t buf[64]; size_t n = emit_guest_code(name, buf, nat ? add_thunk(name, h_generic, nat) : 0);
            code.insert(code.end(), buf, buf + n);
            entries.push_back({name, 0, at}); nfunc++; continue;
        }
        int nfixed = 0; const char *native_name = nullptr;
        Handler h = special_handler(name, &nfixed, &native_name);
        const void *native = dsym(native_name ? native_name : name.c_str() + 1);
        if (native && !h && !native_is_code(native)) {
            data.push_back({name, native, false}); ndata++; continue;
        }
        // special handlers that call the native function: without one they would call NULL
        if (h && !native && h != h_noop && h != h_zero && special_needs_native(name)) {
            if (getenv("X86SIM_A64_STATS")) logf("%s: special handler but no native function (missing)", name.c_str());
            h = h_missing;
        }
        if (!h) h = native ? h_generic : h_missing;
        if (!native && (h == h_generic || h == h_generic_bool || h == h_variadic)) h = h_missing;
        if (h == h_missing) nmissing++;
        u32 idx = add_thunk(name, h, native, nfixed);
        code.push_back(0); code.push_back(0);
        emit_stub(&code[code.size() - 2], idx);
        entries.push_back({name, 0, at}); nfunc++;
    }
    // Data exports are copies in our __DATA (dyld adds the image base even to absolute exports of a dylib that
    // overrides cache clients' binds). A Darling variable's size is the gap to the next exported data symbol (<= 4K);
    // values are snapshotted now (constants such as mach_task_self_, NDR_record; vm_page_size is our own 16K).
    u64 text_size = (kCodeStart + code.size() * 4 + kPage - 1) & ~(kPage - 1);
    {  // crash reports name the export of a stub pc (where())
        std::vector<std::pair<u64, std::string>> fn;
        for (auto &e : entries) fn.push_back({e.value, e.name});
        register_stub_symbols(install.substr(install.rfind('/') + 1), std::move(fn));
    }
    std::vector<const uint8_t *> starts;
    for (auto &d : data) starts.push_back((const uint8_t *)d.src);
    std::sort(starts.begin(), starts.end());
    std::vector<uint8_t> dseg;
    for (auto &d : data) {
        size_t size = 4096;
        auto nx = std::upper_bound(starts.begin(), starts.end(), (const uint8_t *)d.src);
        if (nx != starts.end() && (size_t)(*nx - (const uint8_t *)d.src) < size) size = *nx - (const uint8_t *)d.src;
        if (d.ours) size = d.name == "____kernelVersionString" ? strlen((const char *)d.src) + 1 : 8;
        while (dseg.size() % 16) dseg.push_back(0);
        entries.push_back({d.name, 0, text_size + dseg.size()});
        // Tables of per-library state start empty in the guest (its own libc/libdispatch fill them through the
        // native _os_alloc_once); copying Darling's would hand the guest the host libraries' state.
        if (d.name == "__os_alloc_once_table" || d.name == "_port_obj_table") dseg.insert(dseg.end(), size, 0);
        else dseg.insert(dseg.end(), (const uint8_t *)d.src, (const uint8_t *)d.src + size);
    }
    u64 data_size = (dseg.size() + kPage - 1) & ~(kPage - 1);
    if (!data_size) data_size = kPage;
    std::vector<uint8_t> trie = write_trie(entries);
    u64 le_off = text_size + data_size;
    u64 str_off = le_off + trie.size();
    u64 le_size = trie.size() + 8;

    std::vector<uint8_t> f(le_off + le_size, 0);
    auto *mh = (mach_header_64 *)f.data();
    mh->magic = MH_MAGIC_64; mh->cputype = CPU_TYPE_ARM64; mh->cpusubtype = 0; mh->filetype = MH_DYLIB;
    mh->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_NO_REEXPORTED_DYLIBS;
    uint8_t *lc = f.data() + sizeof *mh;
    auto add = [&](const void *cmd, size_t size) { memcpy(lc, cmd, size); lc += size; mh->ncmds++; mh->sizeofcmds += size; };
    struct { segment_command_64 seg; section_64 sect; } text{};
    text.seg = {LC_SEGMENT_64, sizeof text, "__TEXT", 0, text_size, 0, text_size, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_READ | VM_PROT_EXECUTE, 1, 0};
    strcpy(text.sect.sectname, "__text"); strcpy(text.sect.segname, "__TEXT");
    text.sect.addr = kCodeStart; text.sect.size = code.size() * 4; text.sect.offset = kCodeStart; text.sect.align = 2;
    text.sect.flags = S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    add(&text, sizeof text);
    segment_command_64 le{LC_SEGMENT_64, sizeof le, "__LINKEDIT", le_off, (le_size + kPage - 1) & ~(kPage - 1), le_off, le_size, VM_PROT_READ, VM_PROT_READ, 0, 0};
    segment_command_64 dsg{LC_SEGMENT_64, sizeof dsg, "__DATA", text_size, data_size, text_size, data_size, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, 0, 0};
    add(&dsg, sizeof dsg);
    add(&le, sizeof le);
    std::vector<uint8_t> id(sizeof(dylib_command) + ((install.size() + 8) & ~7ull), 0);
    auto *dc = (dylib_command *)id.data();
    dc->cmd = LC_ID_DYLIB; dc->cmdsize = id.size(); dc->dylib.name_offset = sizeof *dc; dc->dylib.timestamp = 1;
    dc->dylib.current_version = 0x10000; dc->dylib.compatibility_version = 0x10000;
    memcpy(id.data() + sizeof *dc, install.data(), install.size());
    add(id.data(), id.size());
    linkedit_data_command ex{LC_DYLD_EXPORTS_TRIE, sizeof ex, (uint32_t)le_off, (uint32_t)trie.size()};
    add(&ex, sizeof ex);
    symtab_command st{LC_SYMTAB, sizeof st, (uint32_t)str_off, 0, (uint32_t)str_off, 8};
    add(&st, sizeof st);
    dysymtab_command dst{}; dst.cmd = LC_DYSYMTAB; dst.cmdsize = sizeof dst;
    add(&dst, sizeof dst);
    uuid_command uu{LC_UUID, sizeof uu, {}};
    for (size_t k = 0; k < install.size(); k++) uu.uuid[k % 16] ^= (uint8_t)(install[k] * 31 + k);
    uu.uuid[6] = (uu.uuid[6] & 0x0f) | 0x40;
    add(&uu, sizeof uu);
    build_version_command bv{LC_BUILD_VERSION, sizeof bv, g_cache_platform /* PLATFORM_*SIMULATOR */, 0x1b0000, 0x1b0000, 0};
    add(&bv, sizeof bv);
    if (sizeof *mh + mh->sizeofcmds > kCodeStart) die("stub dylib header overflow");
    memcpy(f.data() + kCodeStart, code.data(), code.size() * 4);
    if (!dseg.empty()) memcpy(f.data() + text_size, dseg.data(), dseg.size());
    memcpy(f.data() + le_off, trie.data(), trie.size());
    f[str_off] = ' ';

    for (size_t k = 0; k < install.size() + text_size; k++)
        g_stub_code_hash = (g_stub_code_hash ^ (k < install.size() ? (uint8_t)install[k] : f[k - install.size()])) * 0x100000001b3ull;
    StubLib lib; lib.install_name = install; lib.size = f.size();
    lib.fd = memfd_create(install.c_str() + install.rfind('/') + 1, MFD_CLOEXEC);
    if (lib.fd < 0 || pwrite(lib.fd, f.data(), f.size(), 0) != (ssize_t)f.size()) die("cannot write the stub dylib for %s", install.c_str());
    lib.path = stub_real_copy(install, f);
    if (g_trace || getenv("X86SIM_A64_STATS"))
        logf("%s: %d functions (%d not in Darling), %d data", install.c_str(), nfunc, nmissing, ndata);
    g_libs.push_back(lib);
    return lib;
}

u64 stub_code_hash() { return g_stub_code_hash; }

const char *stub_path_for_fd(int fd) {
    struct stat a, b;
    if (g_libs.empty() || fstat(fd, &a) != 0) return nullptr;
    for (auto &l : g_libs)
        if (!l.path.empty() && fstat(l.fd, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino) return l.path.c_str();
    return nullptr;
}

int stub_fd_for_path(const char *path) {
    for (auto &l : g_libs)
        if (l.install_name == path) return dup(l.fd);
    return -1;
}

}  // namespace a64
