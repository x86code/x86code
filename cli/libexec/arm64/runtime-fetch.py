#!/usr/bin/env python3
"""x86Sim (Speed 22): simulator runtimes straight from Apple, no Mac and no Apple ID.

    runtime-fetch.py list [ios|tvos|watchos|all]   27.x runtimes in Apple's catalogue (the one Xcode reads); default ios
    runtime-fetch.py url BUILD            the runtime's download URL (from gdmf.apple.com, as Xcode asks for it)
    runtime-fetch.py fetch BUILD          download into runtimes/<platform>-<ver>-<build>-arm64/ (ios-, tvos-, watchos-),
                                          decrypt, unpack, RuntimeRoot
Platforms 1: the platform is the build's own (builds are unique across platforms in the catalogue).

How Xcode gets them: the catalogue (devimages-cdn .../index2.dvtdownloadableindex) lists each runtime as a MobileAsset
download ("downloadMethod": "mobileAsset", no authentication). mobileassetd asks gdmf.apple.com/v2/assets for asset
type com.apple.MobileAsset.iOSSimulatorRuntime with the Xcode simulator audience and the build it wants
(RequestedBuild); the answer (a JWT) has an updates.cdn-apple.com URL to an encrypted Apple Archive (AEA) and its
ArchiveDecryptionKey. gdmf's certificate chains to Apple's own root CA (fetched from apple.com/appleca).
Unpacking: `ipsw fw aea -b KEY` decrypts the archive to the cryptex disk image, `7z x -snld` reads the APFS image.
Runtimes are never committed (runtimes/ is gitignored).
"""
import base64
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
INDEX = "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"
GDMF = "https://gdmf.apple.com/v2/assets"
APPLE_ROOT = "https://www.apple.com/appleca/AppleIncRootCertificate.cer"
XCODE_SIM_AUDIENCE = "02d8e57e-dd1c-4090-aa50-b4ed2aef0062"


# Platforms 1: key -> (catalogue platform, MobileAsset type, the .simruntime's name prefix). The key is also the
# runtimes/<key>-<version>-<build>-arm64 dir prefix.
PLATFORMS = {
    "ios": ("com.apple.platform.iphoneos", "com.apple.MobileAsset.iOSSimulatorRuntime", "iOS"),
    "tvos": ("com.apple.platform.appletvos", "com.apple.MobileAsset.appleTVOSSimulatorRuntime", "tvOS"),
    "watchos": ("com.apple.platform.watchos", "com.apple.MobileAsset.watchOSSimulatorRuntime", "watchOS"),
}


def catalogue(platforms=("ios",)):
    """(version, build, name, size, archs, platform key) of the arm64 27.x runtimes of these platforms."""
    with urllib.request.urlopen(INDEX) as r:
        d = plistlib.loads(r.read())
    out = []
    for x in d.get("downloadables", []):
        v = x.get("simulatorVersion", {})
        key = next((k for k in platforms if PLATFORMS[k][0] == x.get("platform")), None)
        if key and v.get("version", "").startswith("27"):
            out.append((v["version"], v["buildUpdate"], x.get("name", ""), x.get("fileSize", 0), x.get("architectures"),
                        key))
    return out


def apple_ca(tmp):
    pem = os.path.join(tmp, "apple-root.pem")
    der = os.path.join(tmp, "apple-root.cer")
    urllib.request.urlretrieve(APPLE_ROOT, der)
    subprocess.run(["openssl", "x509", "-inform", "der", "-in", der, "-out", pem], check=True)
    return pem


def asset(build):
    c = next((c for c in catalogue(tuple(PLATFORMS)) if c[1] == build), None)
    if not c:
        sys.exit(f"runtime-fetch: build {build} is not in Apple's catalogue (see `list all`)")
    version, key = c[0], c[5]
    body = {"AssetAudience": XCODE_SIM_AUDIENCE, "AssetType": PLATFORMS[key][1],
            "ClientVersion": 2, "CertIssuanceDay": "2023-12-10", "RequestedBuild": build, "Build": build,
            "SimulatorVersion": version, "ProductVersion": version, "BuildVersion": build}
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run(["curl", "-sf", "--cacert", apple_ca(tmp), "-H", "Content-Type: application/json", "-X", "POST",
                            "--data", json.dumps(body), GDMF], capture_output=True, text=True, check=True).stdout
    p = r.strip().split(".")
    d = json.loads(base64.urlsafe_b64decode(p[1] + "=" * (-len(p[1]) % 4)))
    for a in d.get("Assets", []):
        if a.get("Build") == build:
            return version, a, key
    sys.exit(f"runtime-fetch: gdmf has no asset for {build}: {d.get('Message', d)}")


def fetch(build):
    version, a, key = asset(build)
    name = PLATFORMS[key][2]
    dst = os.path.join(ROOT, "runtimes", f"{key}-{version}-{build}-arm64")
    dl = os.path.join(dst, "download")
    os.makedirs(dl, exist_ok=True)
    aar = os.path.join(dl, "runtime.aar")
    url = a["__BaseURL"] + a["__RelativePath"]
    print(f"{name} {version} ({build}): {a['_DownloadSize'] / 1e9:.1f} GB from {url}", flush=True)
    if not (os.path.exists(aar) and os.path.getsize(aar) == a["_DownloadSize"]):
        subprocess.run(["curl", "-f", "-C", "-", "-o", aar, url], check=True)
    if os.path.getsize(aar) != a["_DownloadSize"]:
        sys.exit("runtime-fetch: size mismatch")
    # Apple's measurement of the download (SHA-1, catalogue _Measurement)
    want = a.get("_Measurement")
    if isinstance(want, str):
        want = base64.b64decode(want)
    if a.get("_MeasurementAlgorithm") == "SHA-1" and want:
        h = hashlib.sha1()
        with open(aar, "rb") as f:
            for b in iter(lambda: f.read(1 << 24), b""):
                h.update(b)
        if h.digest() != want:
            # not yet checked which bytes Apple measures (the .aar or its payload): warn, 7z/aaextract still fail loudly
            print("runtime-fetch: WARNING: SHA-1 of the download differs from Apple's _Measurement", file=sys.stderr)
    out = os.path.join(dst, "decrypted")
    os.makedirs(out, exist_ok=True)
    subprocess.run(["ipsw", "fw", "aea", aar, "-b", a["ArchiveDecryptionKey"], "-o", out], check=True)
    # the decrypted AEA is an Apple Archive (pbzx inside) holding AssetData/Restore/<n>.dmg: aaextract.py
    for f in list(os.listdir(out)):
        if not f.endswith(".dmg") and open(os.path.join(out, f), "rb").read(4) == b"AA01":
            subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "aaextract.py"),
                            os.path.join(out, f), "extract", os.path.join(dst, "bundle")], check=True, stdout=subprocess.DEVNULL)
            os.unlink(os.path.join(out, f))
    dmgs = [os.path.join(dp, f) for d in (out, os.path.join(dst, "bundle")) for dp, _, fs in os.walk(d) for f in fs
            if f.endswith(".dmg")]
    if not dmgs:
        sys.exit(f"runtime-fetch: no disk image in {out}")
    dmg = max(dmgs, key=os.path.getsize)
    subprocess.run(["7z", "x", "-snld", "-y", "-o" + os.path.join(dst, "extracted"), dmg], stdout=subprocess.DEVNULL)
    rr = os.path.join("extracted/Library/Developer/CoreSimulator/Profiles/Runtimes", f"{name} {version}.simruntime",
                      "Contents/Resources/RuntimeRoot")
    if not os.path.isdir(os.path.join(dst, rr)):
        sys.exit(f"runtime-fetch: no {rr} after unpacking")
    # 7z writes some links as empty files (a link through another link) and others as absolute host paths missing
    # RuntimeRoot (180 of 261 on 24A434/24B8117: lsd then registered no apps, SpringBoard aborted on
    # "Got nil for _systemAppInfo"). Remake every link from the image's listing, then verify.
    ext = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                       "..", "tools", "runtime", "extract-runtime.py")
    ext = os.path.normpath(ext)
    subprocess.run([sys.executable, "-I", ext, "--links", dmg, os.path.join(dst, "extracted")], check=True)
    chk = subprocess.run([sys.executable, "-I", ext, "--check", dmg, os.path.join(dst, "extracted")],
                         capture_output=True, text=True)
    if chk.returncode != 0 or not chk.stdout.rstrip().endswith(" 0 wrong"):
        sys.exit("runtime-fetch: symlinks still wrong after repair:\n" + chk.stdout[-2000:])
    os.unlink(aar)  # the image is kept (bundle/AssetData/Restore/*.dmg), the 8 GB download and decrypt are not
    for d in (out, dl):
        try:
            os.rmdir(d)
        except OSError:
            pass
    link = os.path.join(dst, "RuntimeRoot")
    if not os.path.lexists(link):
        os.symlink(rr, link)
    print(dst)


def main():
    a = sys.argv[1:] or ["list"]
    if a[0] == "list":
        which = a[1] if len(a) > 1 else "ios"
        if which != "all" and which not in PLATFORMS:
            sys.exit(f"runtime-fetch: platform {which}: one of {', '.join(PLATFORMS)} or all")
        for v, b, name, size, arch, key in catalogue(tuple(PLATFORMS) if which == "all" else (which,)):
            have = os.path.isdir(os.path.join(ROOT, "runtimes", f"{key}-{v}-{b}-arm64", "RuntimeRoot"))
            mark = "  (downloaded)" if have else ""
            print(f"{b:12} {name:42} {size / 1e9:4.1f} GB{mark}")
    elif a[0] == "url" and len(a) > 1:
        v, x, _ = asset(a[1])
        print(x["__BaseURL"] + x["__RelativePath"])
    elif a[0] == "fetch" and len(a) > 1:
        fetch(a[1])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
