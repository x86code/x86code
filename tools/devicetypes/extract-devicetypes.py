#!/usr/bin/env python3
"""x86Sim: regenerate cli/lib/devicetypes-a64.json and cli/lib/devicetype-<model>.json from a Mac's Xcode.

    tools/devicetypes/extract-devicetypes.py [--mac user@host] [--runtime 27.2] [--include-unsupported]

Copies (ssh + tar) each device type's profile.plist and capabilities.plist from the Mac's
/Library/Developer/CoreSimulator/Profiles/DeviceTypes, and asks `xcrun simctl list runtimes -j` which device types the
runtime supports (its supportedDeviceTypes: product family, minRuntimeVersion/maxRuntimeVersion and the runtime
profile's unsupportedDeviceTypes already applied). Every iPhone/iPad the runtime supports gets an entry:
    name -> model (modelIdentifier), class (productClass), w/h/pitch (capabilities ScreenDimensionsCapability),
            scale ("%f"), suffix (environment SIMULATOR_LEGACY_ASSET_SUFFIX), json (devicetype-<model lowercase>.json)
and devicetype-<model>.json is the capabilities.plist as JSON (what SIMULATOR_CAPABILITIES carries). Device types
sharing a model identifier (iPad 8GB/16GB variants) share one capabilities file, the first one listed.
Only data derived from the plists is written; no Apple binaries.
--include-unsupported also takes iPhone/iPad types the runtime refuses but whose minRuntimeVersion allows (iPhone Duo,
iPhone19,4, on 27.2: the runtime profile's unsupportedDeviceTypes), with a "note". The committed files are
`extract-devicetypes.py --include-unsupported` against Xcode 27.2 (27B52).
Platforms 1: Apple TV and Apple Watch device types are added after the iPhones and iPads, with "platform": "tvos" /
"watchos" (an entry without "platform" is iOS). Which of them a 27.x runtime takes comes from each profile's product
family (3 = Apple TV, 4 = Apple Watch) and min/maxRuntimeVersion, so the Mac needs no tvOS/watchOS runtime installed.
"""
import io
import json
import os
import plistlib
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = os.path.join(ROOT, "cli/lib")
DT = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes"


def ints(v):
    """plutil -convert json's form (the committed files): integral reals as integers"""
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, dict):
        return {k: ints(x) for k, x in v.items()}
    if isinstance(v, list):
        return [ints(x) for x in v]
    return v


def ver(s):
    return [int(x) for x in s.split(".")]


def main():
    mac, rtver, unsupported = "bobby@192.168.1.217", "27.2", False
    a = sys.argv[1:]
    while a:
        o = a.pop(0)
        if o == "--mac":
            mac = a.pop(0)
        elif o == "--runtime":
            rtver = a.pop(0)
        elif o == "--include-unsupported":
            unsupported = True
        else:
            sys.exit(__doc__)
    runtimes = json.loads(subprocess.check_output(["ssh", mac, "xcrun simctl list runtimes -j 2>/dev/null"]))
    rt = [r for r in runtimes["runtimes"] if r["version"] == rtver and r["platform"] == "iOS"][-1]
    supported = [d["bundlePath"].rstrip("/").rsplit("/", 1)[1] for d in rt["supportedDeviceTypes"]
                 if d["productFamily"] in ("iPhone", "iPad")]
    tar = subprocess.check_output(["ssh", mac, f"cd '{DT}' && tar cf - */Contents/Resources/profile.plist "
                                              "*/Contents/Resources/capabilities.plist"])
    files = {}
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        for m in t.getmembers():
            if m.isfile():
                files[m.name] = plistlib.load(t.extractfile(m))
    bundles = list(supported)
    if unsupported:
        for p in sorted(files):
            b = p.split("/")[0]
            prof = files.get(b + "/Contents/Resources/profile.plist", {})
            if b not in bundles and b.startswith(("iPhone", "iPad")) and set(prof.get("supportedProductFamilyIDs", [])) & {1, 2} \
                    and ver(prof.get("minRuntimeVersion", "0")) <= ver(rtver) \
                    and ver(rtver) <= ver(prof.get("maxRuntimeVersion", "99.99")):
                bundles.append(b)
    # Platforms 1: (bundle, platform) for every device type; iOS first, as before
    plat = {b: None for b in bundles}
    # Platforms 2: Apple Vision Pro (product family 7, "xros")
    for fam, key in ((3, "tvos"), (4, "watchos"), (7, "xros")):
        # newest first, as Xcode's own lists show them (model identifier generation, then name)
        cands = []
        for p in sorted(files):
            b = p.split("/")[0]
            prof = files.get(b + "/Contents/Resources/profile.plist", {})
            if p.endswith("/profile.plist") and fam in prof.get("supportedProductFamilyIDs", []) \
                    and ver(prof.get("minRuntimeVersion", "0")) <= ver(rtver) <= ver(prof.get("maxRuntimeVersion", "99.99")) \
                    and "arm64" in prof.get("supportedArchs", ["arm64"]):
                cands.append(b)
        gen = lambda b: [int(x) for x in "".join(c if c.isdigit() else " " for c in files[b + "/Contents/Resources/profile.plist"]["modelIdentifier"]).split()]
        for b in sorted(cands, key=lambda b: (gen(b), b), reverse=True):
            plat[b] = key
    bundles = list(plat)
    out, written = {}, set()
    for b in bundles:
        prof = files[b + "/Contents/Resources/profile.plist"]
        caps = files[b + "/Contents/Resources/capabilities.plist"]
        sd = caps["capabilities"]["ScreenDimensionsCapability"]
        model = prof["modelIdentifier"]
        js = "devicetype-%s.json" % model.lower()
        out[b[:-len(".simdevicetype")]] = {
            "model": model, "class": prof["productClass"],
            "w": str(ints(sd["main-screen-width"])), "h": str(ints(sd["main-screen-height"])),
            "scale": "%f" % sd["main-screen-scale"], "pitch": "%f" % sd.get("main-screen-pitch", 0),  # Apple TV: none (an external display)
            "suffix": prof.get("environment", {}).get("SIMULATOR_LEGACY_ASSET_SUFFIX",
                                                       "" if plat[b] else
                                                       "ipad" if 2 in prof["supportedProductFamilyIDs"] else "iphone"),
            "json": js}
        if plat[b]:
            out[b[:-len(".simdevicetype")]]["platform"] = plat[b]
        elif b not in supported:
            out[b[:-len(".simdevicetype")]]["note"] = (
                f"iOS {rtver} lists it as unsupported (Xcode can't create it on this runtime); it has a build of its "
                f"own (iPhone Duo: 27.2 24B91016s, runtime-fetch.py fetch 24B91016s)")
        if js not in written:
            written.add(js)
            with open(os.path.join(LIB, js), "w") as f:
                json.dump(ints(caps), f, indent=1, sort_keys=True)
    with open(os.path.join(LIB, "devicetypes-a64.json"), "w") as f:
        json.dump(out, f, indent=1)
    print(f"{sum(1 for v in out.values() if 'platform' in v)} of them Apple TV / Apple Watch / Apple Vision Pro")
    print(f"{len(out)} device types ({len(written)} capability files) for iOS {rtver} {rt['buildversion']}")


main()
