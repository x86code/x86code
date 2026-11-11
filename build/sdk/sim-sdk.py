#!/usr/bin/env python3
"""x86Sim: a substitute iPhoneSimulator.sdk for the C / Objective-C simulator-side binaries, without Xcode.

Compiling and linking needs headers and link stubs, nothing else from the SDK:
  - link stubs (.tbd, text-based dylib stubs) for every library in the iOS runtime's dyld_sim_shared_cache (the
    runtime runtime-fetch.py downloads without an Apple ID): install name, versions, re-exported libraries and the
    export trie (own and re-exported symbols, weak / thread-local, Objective-C classes, ivars and eh types as
    Apple's own stubs spell them). They carry the runtime's private symbols too (Apple's SDK hides those).
  - headers: the macOS SDK's (build/sdk/macos-sdk.py), symlinked. CoreFoundation, Foundation, objc, libc, dispatch,
    xpc, IOKit, IOSurface, Metal, CoreGraphics and sqlite3 are the same headers on both platforms; where iOS differs
    in a way our code sees, a patched copy (IOS_PATCHES) or a minimal header of our own (IOS_HEADERS).
Against the 27.2 runtime and macOS 27.2 SDK, simhid, simfb, simshim and simaudio come out byte-identical to the
Xcode SDK's builds, the other host/ binaries identical apart from clang's random temp-object names.
Not covered: UIKit / SwiftUI / Swift (iOS-only headers and Swift modules): tests/apps and the Swift probes still
need Xcode's SDK.

Platforms 1: the same for tvOS and watchOS (AppleTVSimulator.sdk / WatchSimulator.sdk), from a tvos-/watchos- runtime:
--platform tvos|watchos, or the platform of --runtime's dir name.

Usage: build/sdk/sim-sdk.py [--platform ios|tvos|watchos] [--runtime runtimes/<dir>] [--mac-sdk sdks/MacOSX.sdk]
                            [--out sdks/<Platform>Simulator.sdk] [--force]"""
import argparse, glob, json, mmap, os, plistlib, re, shutil, struct, sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "../.."))
DEFAULT_RT = "ios-27.2-24B8117-arm64"  # cli/libexec/arm64/device-a64.py
TARGET = "arm64-ios-simulator"  # set from PLATFORMS in main()
# Platforms 1: key (the runtimes/<key>-... prefix) -> tbd target, SDK dir name, canonical name, display name,
# triple sys, LC_BUILD_VERSION platform, clang runtime platform name
PLATFORMS = {
    "ios": ("arm64-ios-simulator", "iPhoneSimulator.sdk", "iphonesimulator", "iOS", "ios", "7", "iossim"),
    "tvos": ("arm64-tvos-simulator", "AppleTVSimulator.sdk", "appletvsimulator", "tvOS", "tvos", "8", "tvossim"),
    "watchos": ("arm64-watchos-simulator", "WatchSimulator.sdk", "watchsimulator", "watchOS", "watchos", "9",
                "watchossim"),
}

# (header relative to the SDK, macOS text, iOS text): iOS headers that differ from macOS in a way our code sees
IOS_PATCHES = [
    # the ObjC type encoding of methods taking an MTLResourceID ({MTLResourceID=(?=QQ)} on iOS; metalhostd's vkmtl)
    ("System/Library/Frameworks/Metal.framework/Headers/MTLTypes.h",
     "typedef struct MTLResourceID\n{\n    uint64_t _impl;\n}",
     "typedef struct MTLResourceID\n{\n    union\n    {\n        uint64_t _impl;\n        uint64_t textureID;\n    };\n}"),
]
# our own minimal headers for iOS-only headers the shared ones include under TARGET_OS_IPHONE
IOS_HEADERS = {
    # CoreImage's CIContext.h (via QuartzCore) names EAGLContext in two method declarations
    "System/Library/Frameworks/OpenGLES.framework/Headers/EAGL.h":
        "// x86Sim substitute SDK (build/sdk/sim-sdk.py): what CoreImage/CIContext.h needs on iOS\n"
        "#import <Foundation/Foundation.h>\n@class EAGLContext, EAGLSharegroup;\n",
}


class Cache:
    """A dyld shared cache and its sub-caches (.01, .02, ...), addressed by unslid VM address."""

    def __init__(self, path):
        self.files = []
        for p in [path] + sorted(g for g in glob.glob(path + ".*") if re.search(r"\.\d+$", g)):
            f = open(p, "rb")
            m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            if not m[:5] == b"dyld_":
                sys.exit(f"sim-sdk: {p} is not a dyld shared cache")
            moff, mcnt = struct.unpack_from("<II", m, 0x10)
            self.files.append((m, [struct.unpack_from("<QQQ", m, moff + i * 32) for i in range(mcnt)]))
        m = self.files[0][0]
        off, cnt = struct.unpack_from("<II", m, 0x1C0)  # imagesOffset / imagesCount (newer caches)
        if not cnt:
            off, cnt = struct.unpack_from("<II", m, 0x18)
        self.images = [struct.unpack_from("<Q", m, off + i * 32)[0] for i in range(cnt)]

    def read(self, addr, n):
        for m, maps in self.files:
            for a, s, fo in maps:
                if a <= addr < a + s:
                    return m[fo + addr - a: fo + addr - a + n]
        raise KeyError(hex(addr))


def uleb(b, i):
    v = s = 0
    while True:
        c = b[i]; i += 1; v |= (c & 0x7F) << s; s += 7
        if c < 0x80:
            return v, i


def version(v):
    a, b, c = v >> 16, (v >> 8) & 0xFF, v & 0xFF
    return f"{a}.{b}.{c}" if c else f"{a}.{b}" if b else f"{a}"


def objc_kinds(names):
    """Symbol names -> tbd v5 symbol kinds, Objective-C ones as Apple's stubs spell them (ld orders by kind)."""
    s, out = set(names), {"global": [], "objc_class": [], "objc_ivar": [], "objc_eh_type": []}
    for n in names:
        if n.startswith("_OBJC_CLASS_$_") and "_OBJC_METACLASS_$_" + n[14:] in s:
            out["objc_class"].append(n[14:])
        elif n.startswith("_OBJC_METACLASS_$_") and "_OBJC_CLASS_$_" + n[18:] in s:
            pass
        elif n.startswith("_OBJC_IVAR_$_"):
            out["objc_ivar"].append(n[13:])
        elif n.startswith("_OBJC_EHTYPE_$_"):
            out["objc_eh_type"].append(n[15:])
        else:
            out["global"].append(n)
    return {k: sorted(v) for k, v in out.items() if v}


def image_tbd(c, addr):
    """(install name, tbd v5 dict) of the image at addr, or None for an image without LC_ID_DYLIB."""
    ncmds, sizeofcmds = struct.unpack_from("<II", c.read(addr, 32), 16)
    lc = c.read(addr + 32, sizeofcmds)
    name, cur, compat, reexp, trie, linkedit, o = None, 0, 0, [], None, None, 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", lc, o)
        if cmd == 0xD:  # LC_ID_DYLIB
            noff, _, cur, compat = struct.unpack_from("<IIII", lc, o + 8)
            name = lc[o + noff: o + size].split(b"\0")[0].decode()
        elif cmd == 0x8000001F:  # LC_REEXPORT_DYLIB
            noff = struct.unpack_from("<I", lc, o + 8)[0]
            reexp.append(lc[o + noff: o + size].split(b"\0")[0].decode())
        elif cmd == 0x19 and lc[o + 8: o + 24].split(b"\0")[0] == b"__LINKEDIT":
            vmaddr, _, fileoff = struct.unpack_from("<QQQ", lc, o + 24)
            linkedit = (vmaddr, fileoff)
        elif cmd == 0x80000033:  # LC_DYLD_EXPORTS_TRIE
            trie = struct.unpack_from("<II", lc, o + 8)
        elif cmd == 0x80000022 and trie is None:  # LC_DYLD_INFO_ONLY: export_off, export_size
            trie = struct.unpack_from("<II", lc, o + 40)
        o += size
    if not name:
        return None
    own, weak, tlv, rex = [], [], [], []
    if trie and trie[1] and linkedit:
        t = c.read(linkedit[0] + trie[0] - linkedit[1], trie[1])
        stack = [(0, "")]
        while stack:
            node, prefix = stack.pop()
            tsize, j = uleb(t, node)
            if tsize:
                flags, _ = uleb(t, j)
                if flags & 0x08:  # EXPORT_SYMBOL_FLAGS_REEXPORT
                    rex.append(prefix)
                elif flags & 0x04:  # WEAK_DEFINITION
                    weak.append(prefix)
                elif flags & 0x03 == 0x01:  # KIND_THREAD_LOCAL
                    tlv.append(prefix)
                else:
                    own.append(prefix)
            j += tsize
            nchild = t[j]; j += 1
            for _ in range(nchild):
                e = t.index(b"\0", j)
                edge = t[j:e].decode(); j = e + 1
                child, j = uleb(t, j)
                stack.append((child, prefix + edge))
    lib = {"install_names": [{"name": name}], "current_versions": [{"version": version(cur)}],
           "compatibility_versions": [{"version": version(compat)}], "target_info": [{"target": TARGET}]}
    if reexp:
        lib["reexported_libraries"] = [{"names": reexp}]
    syms = objc_kinds(own)
    if weak:
        syms["weak"] = sorted(weak)
    if tlv:
        syms["thread_local"] = sorted(tlv)
    if syms:
        lib["exported_symbols"] = [{"text": syms}]
    if rex:
        lib["reexported_symbols"] = [{"text": objc_kinds(rex)}]
    return name, {"tapi_tbd_version": 5, "main_library": lib}


def write_stubs(cache_path, out):
    c = Cache(cache_path)
    n = 0
    for addr in c.images:
        try:
            r = image_tbd(c, addr)
        except (KeyError, IndexError, struct.error) as e:
            print(f"sim-sdk: skipped the image at {addr:#x}: {e!r}", file=sys.stderr)
            continue
        if not r:
            continue
        name, tbd = r
        dst = os.path.join(out, name.lstrip("/"))
        dst = (dst[:-6] if dst.endswith(".dylib") else dst) + ".tbd"
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as f:
            json.dump(tbd, f, separators=(",", ":"))
        # what -framework / -l look for: Foo.framework/Versions/A/Foo -> Foo.framework/Foo.tbd, libfoo.A -> libfoo.tbd
        d, b = os.path.split(dst)
        alias = None
        if "/Versions/" in dst:
            alias = dst[:dst.index("/Versions/")] + "/" + b
        elif b.startswith("lib") and b.count(".") > 1:
            alias = os.path.join(d, b.split(".")[0] + ".tbd")
        if alias and not os.path.lexists(alias):
            os.symlink(os.path.relpath(dst, os.path.dirname(alias)), alias)
        n += 1
    print(f"sim-sdk: {n} stubs from {len(c.images)} images", file=sys.stderr)


def link_headers(mac, out):
    """usr/include and every framework's Headers / Modules from the macOS SDK, as relative symlinks."""
    def ln(src, dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if not os.path.lexists(dst):
            os.symlink(os.path.relpath(src, os.path.dirname(dst)), dst)
    ln(os.path.join(mac, "usr/include"), os.path.join(out, "usr/include"))
    for kind in ("Frameworks", "PrivateFrameworks"):
        for fw in sorted(glob.glob(os.path.join(mac, "System/Library", kind, "*.framework"))):
            for sub in ("Headers", "PrivateHeaders", "Modules"):
                src = os.path.realpath(os.path.join(fw, sub))
                if os.path.isdir(src):
                    ln(src, os.path.join(out, "System/Library", kind, os.path.basename(fw), sub))
    for rel, old, new in IOS_PATCHES:
        p = os.path.join(out, rel)
        d = os.path.dirname(p)
        if not os.path.exists(p):
            continue
        text = open(p).read()
        if old not in text:
            print(f"sim-sdk: warning: {rel} changed, not patched for iOS", file=sys.stderr)
            continue
        # the Headers dir becomes a real dir: symlinks to the macOS headers plus the patched copy
        if os.path.islink(d):
            src = os.path.realpath(d); os.unlink(d); os.makedirs(d)
            for e in os.listdir(src):
                os.symlink(os.path.relpath(os.path.join(src, e), d), os.path.join(d, e))
        os.unlink(p)
        with open(p, "w") as f:
            f.write(text.replace(old, new))
    for rel, text in IOS_HEADERS.items():
        p = os.path.join(out, rel)
        if not os.path.lexists(p):
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)


def runtime_version(rt):
    try:
        with open(os.path.join(rt, "RuntimeRoot/System/Library/CoreServices/SystemVersion.plist"), "rb") as f:
            return plistlib.load(f)["ProductVersion"]
    except (OSError, KeyError):
        m = re.search(r"(?:ios|tvos|watchos)-([0-9.]+)-", os.path.basename(rt.rstrip("/")))
        return m[1] if m else "0.0"


def default_runtime(plat="ios"):
    d = os.path.join(ROOT, "runtimes", DEFAULT_RT)
    if plat == "ios" and os.path.isdir(d):
        return d
    # else the newest runtime not limited to particular models (device-a64.py restricted_to)
    found = []
    for e in os.listdir(os.path.join(ROOT, "runtimes")) if os.path.isdir(os.path.join(ROOT, "runtimes")) else []:
        m = re.match(re.escape(plat) + r"-([0-9.]+)-([0-9A-Za-z]+)-arm64$", e)
        if not m:
            continue
        try:
            with open(os.path.join(ROOT, "runtimes", e, "profile.plist"), "rb") as f:
                if b"restrictedToDeviceTypes" in f.read():
                    continue
        except OSError:
            pass
        found.append(([int(x) for x in m[1].split(".")], e))
    if not found:
        sys.exit(f"sim-sdk: no {plat} runtime in runtimes/ (download one first: x86sim runtime / runtime-fetch.py)")
    return os.path.join(ROOT, "runtimes", max(found)[1])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--platform", choices=sorted(PLATFORMS), help="default: --runtime's platform, else ios")
    ap.add_argument("--runtime", help="runtimes/<dir> (default: %s, else the newest unrestricted)" % DEFAULT_RT)
    ap.add_argument("--mac-sdk", default=os.path.join(ROOT, "sdks/MacOSX.sdk"))
    ap.add_argument("--out", help="default: sdks/<Platform>Simulator.sdk")
    ap.add_argument("--force", action="store_true", help="replace an existing --out")
    a = ap.parse_args()
    plat = a.platform
    if not plat and a.runtime:
        plat = next((k for k in PLATFORMS if os.path.basename(a.runtime.rstrip("/")).startswith(k + "-")), None)
    plat = plat or "ios"
    global TARGET
    TARGET, sdkdir, canon, disp, sysname, platid, rtname = PLATFORMS[plat]
    out = os.path.abspath(a.out or os.path.join(ROOT, "sdks", sdkdir))
    mac = os.path.realpath(a.mac_sdk)
    if os.path.lexists(out) and not a.force:
        print(f"sim-sdk: {out} exists (--force replaces it)", file=sys.stderr)
        return
    if not os.path.isdir(os.path.join(mac, "usr/include")):
        sys.exit(f"sim-sdk: no macOS SDK at {mac} (build/sdk/macos-sdk.py fetches one)")
    rt = os.path.realpath(a.runtime or default_runtime(plat))
    caches = glob.glob(os.path.join(rt, "RuntimeRoot/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64"))
    if not caches:
        sys.exit(f"sim-sdk: no dyld_sim_shared_cache_arm64 in {rt}")
    ver = runtime_version(rt)
    tmp = out + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    write_stubs(caches[0], tmp)
    link_headers(mac, tmp)
    # Platforms 1: frameworks that are private on this platform but public on macOS (watchOS: SystemConfiguration; the
    # runtime's Frameworks/X.framework is a link to PrivateFrameworks/X.framework): -framework X finds the private stub
    for fw in glob.glob(os.path.join(tmp, "System/Library/Frameworks/*.framework")):
        n = os.path.basename(fw)[:-len(".framework")]
        priv = os.path.join(tmp, "System/Library/PrivateFrameworks", n + ".framework", n + ".tbd")
        if not os.path.lexists(os.path.join(fw, n + ".tbd")) and os.path.exists(priv):
            os.symlink(os.path.relpath(priv, fw), os.path.join(fw, n + ".tbd"))
    settings = {
        "CanonicalName": f"{canon}{ver}", "DisplayName": f"Simulator - {disp} {ver} (x86Sim substitute)",
        "Version": ver, "MaximumDeploymentTarget": f"{ver}.99", "DefaultDeploymentTarget": ver, "IsBaseSDK": "YES",
        "x86SimSubstitute": {"runtime": os.path.basename(rt), "macSDK": os.path.basename(mac)},
        "SupportedTargets": {canon: {
            "Archs": ["arm64"], "LLVMTargetTripleVendor": "apple", "LLVMTargetTripleSys": sysname,
            "LLVMTargetTripleEnvironment": "simulator", "BuildVersionPlatformID": platid,
            "ClangRuntimeLibraryPlatformName": rtname, "PlatformFamilyName": disp,
            "MinimumDeploymentTarget": "12.0", "MaximumDeploymentTarget": f"{ver}.99", "DefaultDeploymentTarget": ver}},
    }
    with open(os.path.join(tmp, "SDKSettings.json"), "w") as f:
        json.dump(settings, f, indent=1)
    if os.path.lexists(out):
        shutil.rmtree(out) if os.path.isdir(out) and not os.path.islink(out) else os.unlink(out)
    os.rename(tmp, out)
    print(f"sim-sdk: {disp} {ver} substitute SDK ({os.path.basename(rt)} + {os.path.basename(mac)}) -> {out}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
