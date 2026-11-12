#!/usr/bin/env python3
"""x86Sim sdkcov: the list of everything an SDK offers an app, per platform, for the coverage app (tests/apps/sdkcov).

For every public framework (System/Library/Frameworks, incl. Swift cross-import overlays _A_B.framework) and every
public top-level library (usr/lib/*.tbd, not usr/lib/swift) of Xcode's simulator SDK it records
  - the install name (what the app dlopens),
  - a few representative exports (Objective-C classes first, then C symbols, then Swift type metadata accessors),
    taken from the SDK's .tbd, so only public API is used,
  - whether the platform's simulator runtime ships the binary at all (the dyld_sim_shared_cache map, or a file under
    RuntimeRoot). Not shipped = not supported in the official simulator: the app reports SKIP for it.
Writes manifest-<platform>.json next to this script (committed: the app's bundle carries it; regenerate after an SDK
or runtime update). Usage: tests/apps/sdkcov/gen-manifest.py [ios tvos watchos xros ...]"""
import glob, json, os, re, sys

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.realpath(os.path.join(HERE, "../../.."))
# platform -> (SDK dir; Xcode's, not the sim-sdk.py substitute, whose framework list is macOS's), runtime glob, tbd target
PLATFORMS = {
    "ios": ("iPhoneSimulator.sdk", "ios-*-arm64", "arm64-ios-simulator"),
    "tvos": ("AppleTVSimulator.sdk", "tvos-*-arm64", "arm64-tvos-simulator"),
    "watchos": ("WatchSimulator-xcode.sdk", "watchos-*-arm64", "arm64-watchos-simulator"),
    "xros": ("XRSimulator-xcode.sdk", "xros-*-arm64", "arm64-xros-simulator"),
}
# frameworks the SDK ships as headers / modules only (no binary to load); listed so the report says why
NO_BINARY = "headers or Swift module only (no binary in the SDK)"
# Xcode's diagnostics libraries: injected at launch (DYLD_INSERT_LIBRARIES) by the scheme's diagnostics options, not
# API an app links or loads (libgmalloc replaces malloc: loading it into a running process breaks it; libSystem.B_asan
# is libSystem for Address Sanitizer builds)
XCODE_TOOLS = {"libgmalloc", "libMainThreadChecker", "libBacktraceRecording", "libLeaksAtExit", "libLogRedirect",
               "libViewDebuggerSupport", "libRPAC", "libSystem.B_asan"}
TOOL_REASON = "Xcode diagnostics library (injected by a scheme option, not app API)"


def newest_runtime(pat):
    rts = [d for d in glob.glob(os.path.join(ROOT, "runtimes", pat)) if os.path.isdir(os.path.join(d, "RuntimeRoot"))]
    key = lambda d: [int(x) for x in re.findall(r"\d+", os.path.basename(d).split("-")[1])]
    return max(rts, key=key) if rts else None


def runtime_images(rt):
    m = os.path.join(rt, "RuntimeRoot/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64.map")
    with open(m) as f:
        return {l.strip() for l in f if l.startswith("/")}


def parse_tbd(path, target):
    """install name and the exports for target, from a tbd v4 (YAML) or v5 (JSON)."""
    text = open(path, encoding="utf-8", errors="replace").read()
    if text.lstrip().startswith("{"):  # v5
        d = json.loads(text)
        name = d["main_library"]["install_names"][0]["name"]
        classes, syms = [], []
        for e in d["main_library"].get("exported_symbols", []):
            if e.get("targets") and target not in e["targets"]:
                continue
            for k, v in e.items():
                if not isinstance(v, dict):
                    continue
                classes += v.get("objc_class", [])
                syms += v.get("global", []) + v.get("weak", []) + v.get("thread_local", [])
        return name, classes, syms
    m = re.search(r"install-name:\s*'?([^'\n]+)'?", text)
    name = m.group(1).strip() if m else None
    classes, syms = [], []
    # the main document's exports; an umbrella (UIKit, AVFoundation) has none of its own, so then the re-exported
    # libraries' documents that follow ('--- !tapi-tbd'): dlsym through the umbrella's handle finds those too
    docs = re.split(r"\n(?=--- !tapi)", text)
    main = docs[0]
    if not re.search(r"\nexports:", main):
        main = "\n".join(docs[1:])
    # a line scanner: "- targets: [..]" opens a block, "<key>: [ v, v," lists run until "]"
    ok, key = False, None
    for line in main.splitlines():
        m = re.match(r"\s*- targets:\s*\[([^\]]*)\]", line)
        if m:
            ok, key = target in m.group(1), None
            continue
        m = re.match(r"\s{4,}([a-z-]+):\s*\[(.*)", line)
        if m:
            key, line = m.group(1), m.group(2)
        elif not line.startswith("      ") or key is None:
            key = None if not line.startswith(" ") else key
            continue
        if ok and key in ("objc-classes", "symbols", "weak-symbols", "thread-local-symbols"):
            vals = [v.strip().strip("'") for v in line.split("]")[0].split(",") if v.strip()]
            (classes if key == "objc-classes" else syms).extend(vals)
        if "]" in line:
            key = None
    return name, classes, syms


def pick(classes, syms, fw):
    """up to 3 representative exports: dlsym names (no leading _) / ObjC classes."""
    out = []
    pref = [c for c in classes if not c.startswith("_")]
    # a class named after the framework's own prefix first (CHHapticEngine for CoreHaptics), then the rest
    initials = "".join(ch for ch in fw if ch.isupper())  # CoreHaptics -> CH, UIKit -> UIK
    pref.sort(key=lambda c: (0 if initials[:2] and c.startswith(initials[:2]) else 1, len(c), c))
    out += [{"objc": c} for c in pref[:2]]
    cs = sorted((s for s in syms if s.startswith("_") and not s.startswith("_$s") and (not s.startswith("__") or s.startswith("__Z"))
                 and not s.startswith("_OBJC_")), key=lambda s: (len(s), s))
    out += [{"sym": s[1:]} for s in cs[:3 - len(out)]]
    if len(out) < 3:
        # Swift-only: a type metadata accessor (…Ma) is a plain function every Swift module exports
        sw = sorted((s for s in syms if s.startswith("_$s") and s.endswith("Ma")), key=lambda s: (len(s), s))
        sw = sw or sorted((s for s in syms if s.startswith("_$s")), key=lambda s: (len(s), s))
        out += [{"sym": s[1:]} for s in sw[:3 - len(out)]]
    return out


def build(plat):
    sdkname, rtpat, target = PLATFORMS[plat]
    sdk = os.path.join(ROOT, "sdks", sdkname)
    rt = newest_runtime(rtpat)
    if not os.path.isdir(sdk) or not rt:
        sys.exit(f"gen-manifest: {plat}: need sdks/{sdkname} and runtimes/{rtpat}")
    imgs = runtime_images(rt)
    rr = os.path.join(rt, "RuntimeRoot")
    ver = json.load(open(os.path.join(sdk, "SDKSettings.json")))["Version"]
    items = []
    fwdir = os.path.join(sdk, "System/Library/Frameworks")
    entries = [("framework", n[:-10], os.path.join(fwdir, n)) for n in sorted(os.listdir(fwdir)) if n.endswith(".framework")]
    entries += [("library", os.path.basename(t)[:-4], t) for t in sorted(glob.glob(os.path.join(sdk, "usr/lib/*.tbd")))
                if not os.path.islink(t)]
    for kind, name, p in entries:
        tbd = p if kind == "library" else (glob.glob(os.path.join(p, "*.tbd")) + glob.glob(os.path.join(p, "Versions/A/*.tbd")) + [None])[0]
        it = {"kind": kind, "name": name}
        if name in XCODE_TOOLS or name.split(".")[0] in XCODE_TOOLS:
            it.update(status="skip", reason=TOOL_REASON)
            items.append(it)
            continue
        if not tbd:
            it.update(status="skip", reason=NO_BINARY)
            items.append(it)
            continue
        inst, classes, syms = parse_tbd(tbd, target)
        it["path"] = inst
        shipped = inst in imgs or os.path.exists(os.path.join(rr, inst.lstrip("/")))
        if not shipped:
            it.update(status="skip", reason=f"not in the {plat} {os.path.basename(rt).split('-')[1]} simulator runtime")
        else:
            it["status"] = "test"
            it["probes"] = pick(classes, syms, name)
        items.append(it)
    out = {"platform": plat, "sdk": f"{sdkname[:-4]} {ver}", "runtime": os.path.basename(rt), "items": items}
    dst = os.path.join(HERE, f"manifest-{plat}.json")
    with open(dst, "w") as f:
        json.dump(out, f, indent=1)
    t = sum(i["status"] == "test" for i in items)
    print(f"{plat}: {len(items)} entries ({t} testable, {len(items) - t} skipped) -> {os.path.relpath(dst, ROOT)}")


if __name__ == "__main__":
    for p in sys.argv[1:] or list(PLATFORMS):
        build(p)
