#!/bin/bash
# arm64 iOS-simulator builds of the shims loaded into simulator processes (they call
# the guest's frameworks, so they must be guest code): simshim, SimFramebuffer (simfb), SimulatorHID (simhid),
# metalhostd (+vkmtl), iosurfaced, mtlprobe, openurl, netconfig, fpsim2host. Output under host/<name>/arm64/ (mksimdevice.py picks
# them up).
# Usage: build/mac-build-arm64-shims.sh [simshim simaudio simfb simhid metalhostd iosurfaced mtlprobe openurl netconfig fpsim2host]
# Platforms 1: X86SIM_PLATFORM=tvos|watchos builds the same for the tvOS / watchOS simulator (dyld_sim takes only
# Mach-Os of its own platform) into host/<name>/arm64-tvos|arm64-watchos (default ios: host/<name>/arm64).
set -e
. "$(dirname "$0")/mac-env.sh"
case ${X86SIM_PLATFORM:-ios} in
ios) SIMSDK=iphonesimulator; T="-target arm64-apple-ios17.0-simulator"; SUF= ;;
tvos) SIMSDK=appletvsimulator; T="-target arm64-apple-tvos17.0-simulator"; SUF=-tvos ;;
watchos) SIMSDK=watchsimulator; T="-target arm64-apple-watchos10.0-simulator"; SUF=-watchos ;;
# Platforms 2: visionOS
xros) SIMSDK=xrsimulator; T="-target arm64-apple-xros1.0-simulator"; SUF=-xros ;;
*) echo "X86SIM_PLATFORM: ios, tvos, watchos or xros" >&2; exit 1 ;;
esac
W=$(mktemp -d "$X86SIM_SCRATCH/macbuild.XXXXXX"); trap 'rm -rf "$W"' EXIT
CC="xcrun -sdk $SIMSDK clang $T"
# build <dir> <dest> <commands>: stdin (a tar of the sources) is unpacked into /tmp/<dir> on the build host (mac(): the
# Mac over ssh, or this machine with build/linux-env.sh), <commands> make the file named like <dest> there, and it comes
# back as <dest>. A fixed <dir> per target: -g records it, so an unchanged source rebuilds the same binary.
# build_exe: the same for an executable.
build() {
	local name; name=$(basename "$2")
	mac "rm -rf /tmp/$1 && mkdir -p /tmp/$1 && cd /tmp/$1 && tar xf - && { $3; } >&2 && cat $name" > "$W/$name"
	mkdir -p "$(dirname "$2")" && mv "$W/$name" "$2"
}
build_exe() { build "$@" && chmod +x "$2"; }
what=${*:-simshim simfb simhid}
for w in $what; do case $w in
simshim)
	tar cf - -C "$X/host/simshim/compat" simshim.c -C "$X/host/simshim/diag" oslogdiag.m diagpath.h |
	build a64sh "$X/host/simshim/arm64$SUF/compat/libsimshim.dylib" "
		cc() { $CC -O1 -Wall -Wno-unused-variable -Wno-deprecated-declarations \"\$@\"; } &&
		cc -c -o simshim.o simshim.c && cc -c -DSIMSHIM_OSLOG -o oslog.o oslogdiag.m &&
		cc -dynamiclib -framework IOKit -framework CoreFoundation -lobjc -lsqlite3 -o libsimshim.dylib simshim.o oslog.o" ;;
simaudio)
	# Speed 27: the audio devices (CoreAudio HAL stand-in, host/simaudio) for arm64 processes:
	# flat namespace + dynamic lookup, CoreAudio references weak (inert in processes without CoreAudio)
	tar cf - -C "$X/host/simaudio" simaudio.c | build a64sa "$X/host/simaudio/arm64$SUF/libsimaudio.dylib" "$CC \
		-O2 -Wall -Wno-unused-function -dynamiclib -framework CoreFoundation -Wl,-flat_namespace -Wl,-undefined,dynamic_lookup \
		-o libsimaudio.dylib simaudio.c" ;;
simfb)
	tar cf - -C "$X/host/simfb" simfb.c | build a64fb "$X/host/simfb/arm64$SUF/SimFramebuffer.framework/SimFramebuffer" "$CC \
		-DWIDTH0=1206 -DHEIGHT0=2622 -O1 -Wall -Wno-unused-parameter -fvisibility=hidden -dynamiclib \
		-install_name /System/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer -framework CoreFoundation \
		-framework CoreGraphics -framework IOSurface -lobjc -o SimFramebuffer simfb.c" ;;
simhid)
	tar cf - -C "$X/host/simhid" simhid.m | build a64hid "$X/host/simhid/arm64$SUF/SimulatorHID.framework/SimulatorHID" "$CC \
		-O1 -Wall -Wno-unused-parameter -fno-objc-arc -dynamiclib -install_name /System/Library/PrivateFrameworks/SimulatorHID.framework/SimulatorHID \
		-framework Foundation -framework IOKit -lobjc -o SimulatorHID simhid.m" ;;
metalhostd)
	# arm64 sim target. Runs under the A64 JIT; talks to native mtlvk.
	tar cf - -C "$X/host/metalhostd" vkmtl.m vkmtl_proto.h metalhostd.m | build_exe a64mtl "$X/host/metalhostd/arm64$SUF/metalhostd" "$CC \
		-O1 -g -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
		-fno-objc-arc -framework Foundation -framework Metal -framework IOSurface -lobjc -o metalhostd metalhostd.m vkmtl.m" ;;
iosurfaced)
	# Foundation + IOKit (IOCFSerialize), not IOSurface.framework.
	tar cf - -C "$X/host/iosurfaced" iosurfaced.m | build_exe a64ios "$X/host/iosurfaced/arm64$SUF/iosurfaced" "$CC \
		-O1 -g -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
		-fno-objc-arc -framework Foundation -framework IOKit -lobjc -o iosurfaced iosurfaced.m" ;;
mtlprobe)
	tar cf - -C "$X/tests/metal" mtlprobe.m shaders/probe_metallib.h shaders/probe_source.h |
	build_exe a64probe "$X/tests/metal/arm64$SUF/mtlprobe" "$CC -O1 -g -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
		-fobjc-arc -framework Foundation -framework Metal -framework IOSurface -o mtlprobe mtlprobe.m" ;;
openurl)
	# arm64 sim target. Linux inotify via svc #0xfffe.
	tar cf - -C "$X/host/openurl" openurl.m openurl.entitlements | build_exe a64openurl "$X/host/openurl/arm64$SUF/openurl" "$CC \
		-O1 -g -Wall -Wno-deprecated-declarations \
		-fobjc-arc -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,openurl.entitlements -o openurl openurl.m" ;;
netconfig)
	# Speed 26: the host network configuration into com.x86sim.host-configd (mksimdevice skips the job when this build
	# is missing: the arm64 phone then had no network state and every request failed "offline", -1009)
	tar cf - -C "$X/host/netconfig" netconfig.m | build_exe a64netcfg "$X/host/netconfig/arm64$SUF/netconfig" "$CC \
		-O1 -g -Wall -Wno-deprecated-declarations -fobjc-arc -framework Foundation -framework SystemConfiguration \
		-o netconfig netconfig.m" ;;
fpsim2host)
	# Speed 16: the FileProvider sim2host stand-in (job com.x86sim.fpsim2host, started when Files opens)
	tar cf - -C "$X/host/fpsim2host" fpsim2host.m | build_exe a64fpsh "$X/host/fpsim2host/arm64$SUF/fpsim2host" "$CC \
		-O1 -g -Wall -Wno-deprecated-declarations -fobjc-arc -framework Foundation -o fpsim2host fpsim2host.m" ;;
*) echo "unknown target: $w" >&2; exit 1 ;;
esac; done
file "$X"/host/sim*/arm64$SUF/*/* "$X"/host/sim*/arm64$SUF/*/*/* \
	"$X"/host/metalhostd/arm64$SUF/metalhostd "$X"/host/iosurfaced/arm64$SUF/iosurfaced \
	"$X"/tests/metal/arm64$SUF/mtlprobe "$X"/host/openurl/arm64$SUF/openurl "$X"/host/netconfig/arm64$SUF/netconfig "$X"/host/fpsim2host/arm64$SUF/fpsim2host 2>/dev/null | grep -i mach || true
