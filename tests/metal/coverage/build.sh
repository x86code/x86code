#!/bin/bash
# x86Sim MetalCoverage: build the arm64 iOS-simulator app on Linux (clang + ld64.lld against the repo's sdks/),
# ad-hoc signed. -> $X86SIM_SCRATCH/mtlcov/MetalCoverage.app (or $1)
#   tests/metal/coverage/build.sh [out.app]
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
X86SIM_ROOT=$(cd "$H/../../.." && pwd); . "$X86SIM_ROOT/cli/lib/config.sh"
SDK=$X86SIM_ROOT/sdks/iPhoneSimulator.sdk
RT=$X86SIM_ROOT/sdks/swift-lib/clang/lib/darwin/libclang_rt.iossim.a
APP=${1:-$X86SIM_SCRATCH/mtlcov/MetalCoverage.app}
O=$(dirname "$APP")/obj; mkdir -p "$O"
[ -f "$SDK/SDKSettings.json" ] || { echo "no SDK at $SDK" >&2; exit 2; }
CF=(--target=arm64-apple-ios18.0-simulator -isysroot "$SDK" -fobjc-arc -fmodules -O1 -g0 -Wall -Wno-unused-function -I"$H")
objs=()
for s in "$H"/*.m; do
	o=$O/$(basename "${s%.m}").o
	if [ ! "$o" -nt "$s" ] || [ "$H/mtlcov.h" -nt "$o" ]; then clang "${CF[@]}" -c "$s" -o "$o" & fi
	objs+=("$o")
done
wait
rm -rf "$APP"; mkdir -p "$APP"
ld64.lld -arch arm64 -platform_version ios-simulator 18.0 27.2 -syslibroot "$SDK" -o "$APP/MetalCoverage" "${objs[@]}" \
	-lSystem -lobjc -framework Foundation -framework UIKit -framework Metal -framework QuartzCore -framework IOSurface \
	-framework CoreGraphics "$RT"
cat > "$APP/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.x86sim.test.mtlcov</string>
<key>CFBundleName</key><string>MetalCoverage</string><key>CFBundleDisplayName</key><string>Metal Coverage</string>
<key>CFBundleExecutable</key><string>MetalCoverage</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>DTPlatformName</key><string>iphonesimulator</string><key>MinimumOSVersion</key><string>18.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PL
PATH=$X86SIM_ROOT/build/linux-bin:$PATH codesign -f -s - "$APP" >/dev/null 2>&1
echo "$APP"
