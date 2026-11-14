#!/bin/bash
# x86Sim sdkcov: build the SDK coverage app for each platform's arm64 simulator with swiftc (no Xcode project) into
# $X86SIM_SCRATCH/apps/sdkcov-<platform>.app (bundle id com.x86sim.test.sdkcov on all four).
# Usage: tests/apps/sdkcov/build.sh [ios] [tvos] [watchos] [xros]   (default: all four)
# Linux (build/linux-env.sh) or the Mac (X86SIM_BUILD=mac, over ssh), as tests/apps/build.sh.
set -e
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/build/mac-env.sh"
A=$X86SIM_ROOT/tests/apps; S=$A/sdkcov; OUT=$X86SIM_SCRATCH/apps; mkdir -p "$OUT"
for p in ${*:-ios tvos watchos xros}; do
	multi='<false/>'
	case $p in
	ios) sdk=iphonesimulator; tgt=arm64-apple-ios27.0-simulator; plat=iPhoneSimulator; fam='<integer>1</integer><integer>2</integer>'; extra= ;;
	tvos) sdk=appletvsimulator; tgt=arm64-apple-tvos27.0-simulator; plat=AppleTVSimulator; fam='<integer>3</integer>'; extra= ;;
	# a standalone (watch-only) app: watchOS installs and runs it without an iPhone companion
	watchos) sdk=watchsimulator; tgt=arm64-apple-watchos27.0-simulator; plat=WatchSimulator; fam='<integer>4</integer>'
		# WKBackgroundModes self-care: WKExtendedRuntimeSession runs (refused with error 7 without it); the Health usage
		# strings: the workout check may ask for Health access (an app without them is killed when it asks)
		extra='<key>WKApplication</key><true/><key>WKWatchOnly</key><true/><key>WKBackgroundModes</key><array><string>self-care</string></array><key>NSHealthShareUsageDescription</key><string>sdkcov reads workouts it saved</string><key>NSHealthUpdateUsageDescription</key><string>sdkcov saves a test workout</string>'
		# Xcode's watch SDK: the one in sdks/WatchSimulator.sdk is sim-sdk.py's substitute (macOS headers, no WatchKit)
		[ "$X86SIM_BUILD" = linux ] && export SDK_WATCHOS=$X86SIM_ROOT/sdks/WatchSimulator-xcode.sdk ;;
	# Xcode's visionOS SDK: sdks/XRSimulator.sdk is sim-sdk.py's substitute (iOS's framework list, not visionOS's)
	xros) sdk=xrsimulator; tgt=arm64-apple-xros27.0-simulator; plat=XRSimulator; fam='<integer>7</integer>'; extra=; multi='<true/>'  # volume + immersive spaces
		[ "$X86SIM_BUILD" = linux ] && export SDK_XROS=$X86SIM_ROOT/sdks/XRSimulator-xcode.sdk ;;
	*) echo "sdkcov build: unknown platform $p (ios, tvos, watchos, xros)" >&2; exit 2 ;;
	esac
	[ -f "$S/manifest-$p.json" ] || { echo "sdkcov build: no manifest-$p.json (gen-manifest.py $p)" >&2; exit 1; }
	echo "== sdkcov $p" >&2
	tar cf - -C "$A" common.swift sdkcov | mac "set -e; W=\$(mktemp -d /tmp/sdkcov.XXXXXX); cd \$W; tar xf -
		APP=sdkcov-$p.app; mkdir -p \$APP
		nice xcrun -sdk $sdk swiftc -target $tgt -Onone -parse-as-library -module-name sdkcov \
			-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker sdkcov/sdkcov.entitlements \
			-o \$APP/sdkcov common.swift sdkcov/*.swift sdkcov/checks/*.swift 2>&1 >&2 | grep -v 'directory not found for option -L' >&2 || true
		test -x \$APP/sdkcov
		cp sdkcov/manifest-$p.json \$APP/manifest.json
		cat > \$APP/Info.plist <<PL
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>CFBundleIdentifier</key><string>com.x86sim.test.sdkcov</string>
<key>CFBundleName</key><string>sdkcov</string><key>CFBundleDisplayName</key><string>sdkcov</string>
<key>CFBundleExecutable</key><string>sdkcov</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
<key>DTPlatformName</key><string>$sdk</string><key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array>$fam</array><key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key>$multi</dict>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>BGTaskSchedulerPermittedIdentifiers</key><array><string>com.x86sim.test.sdkcov.refresh</string></array>
<key>NSUserActivityTypes</key><array><string>com.x86sim.test.sdkcov.activity</string></array>
<key>NSLocationWhenInUseUsageDescription</key><string>sdkcov checks Core Location</string>
<key>NSContactsUsageDescription</key><string>sdkcov checks Contacts</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>sdkcov checks EventKit</string>
<key>NSPhotoLibraryUsageDescription</key><string>sdkcov checks Photos</string>
<key>NSMicrophoneUsageDescription</key><string>sdkcov checks audio input</string>
<key>NSSpeechRecognitionUsageDescription</key><string>sdkcov checks Speech</string>
<key>NSHealthShareUsageDescription</key><string>sdkcov checks HealthKit</string>
<key>NSHomeKitUsageDescription</key><string>sdkcov checks HomeKit</string>
<key>NSMotionUsageDescription</key><string>sdkcov checks Core Motion</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>sdkcov checks Core Bluetooth</string>
<key>NSLocalNetworkUsageDescription</key><string>sdkcov checks Network on loopback</string>
<key>NSBonjourServices</key><array><string>_sdkcov._tcp</string></array>
$extra
</dict></plist>
PL
		codesign -f -s - --entitlements sdkcov/sign.entitlements \$APP >&2
		tar cf - \$APP; cd /; rm -rf \$W" | (cd "$OUT" && rm -rf "sdkcov-$p.app" && tar xf -)
	ls -d "$OUT/sdkcov-$p.app"
done
