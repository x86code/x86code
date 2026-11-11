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
*) echo "X86SIM_PLATFORM: ios, tvos or watchos" >&2; exit 1 ;;
esac
W=$(mktemp -d "$X86SIM_SCRATCH/macbuild.XXXXXX"); trap 'rm -rf "$W"' EXIT
what=${*:-simshim simfb simhid}
for w in $what; do case $w in
simshim)
	tar cf - -C "$X/host/simshim/compat" simshim.c -C "$X/host/simshim/diag" oslogdiag.m diagpath.h | mac "
	rm -rf /tmp/a64sh && mkdir -p /tmp/a64sh && cd /tmp/a64sh && tar xf - &&
	cc() { xcrun -sdk $SIMSDK clang $T -O1 -Wall -Wno-unused-variable -Wno-deprecated-declarations \"\$@\"; } &&
	cc -c -o simshim.o simshim.c >&2 && cc -c -DSIMSHIM_OSLOG -o oslog.o oslogdiag.m >&2 &&
	cc -dynamiclib -framework IOKit -framework CoreFoundation -lobjc -lsqlite3 -o libsimshim.dylib simshim.o oslog.o >&2 &&
	cat libsimshim.dylib" > "$W/libsimshim.dylib"
	mkdir -p "$X/host/simshim/arm64$SUF/compat" && mv "$W/libsimshim.dylib" "$X/host/simshim/arm64$SUF/compat/libsimshim.dylib" ;;
simaudio)
	# Speed 27: the audio devices (CoreAudio HAL stand-in, host/simaudio) for arm64 processes:
	# flat namespace + dynamic lookup, CoreAudio references weak (inert in processes without CoreAudio)
	mac "rm -rf /tmp/a64sa && mkdir -p /tmp/a64sa && cat > /tmp/a64sa/simaudio.c && cd /tmp/a64sa && xcrun -sdk $SIMSDK clang $T \
		-O2 -Wall -Wno-unused-function -dynamiclib -framework CoreFoundation -Wl,-flat_namespace -Wl,-undefined,dynamic_lookup \
		-o libsimaudio.dylib simaudio.c >&2 && cat libsimaudio.dylib" < "$X/host/simaudio/simaudio.c" > "$W/libsimaudio.dylib"
	mkdir -p "$X/host/simaudio/arm64$SUF" && mv "$W/libsimaudio.dylib" "$X/host/simaudio/arm64$SUF/libsimaudio.dylib" ;;
simfb)
	mac "rm -rf /tmp/a64fb && mkdir -p /tmp/a64fb && cat > /tmp/a64fb/simfb.c && cd /tmp/a64fb && xcrun -sdk $SIMSDK clang $T \
		-DWIDTH0=1206 -DHEIGHT0=2622 -O1 -Wall -Wno-unused-parameter -fvisibility=hidden -dynamiclib \
		-install_name /System/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer -framework CoreFoundation \
		-framework CoreGraphics -framework IOSurface -lobjc -o SimFramebuffer simfb.c >&2 && cat SimFramebuffer" \
		< "$X/host/simfb/simfb.c" > "$W/SimFramebuffer"
	mkdir -p "$X/host/simfb/arm64$SUF/SimFramebuffer.framework" && mv "$W/SimFramebuffer" "$X/host/simfb/arm64$SUF/SimFramebuffer.framework/" ;;
simhid)
	mac "rm -rf /tmp/a64hid && mkdir -p /tmp/a64hid && cat > /tmp/a64hid/simhid.m && cd /tmp/a64hid && xcrun -sdk $SIMSDK clang $T \
		-O1 -Wall -Wno-unused-parameter -fno-objc-arc -dynamiclib -install_name /System/Library/PrivateFrameworks/SimulatorHID.framework/SimulatorHID \
		-framework Foundation -framework IOKit -lobjc -o SimulatorHID simhid.m >&2 && cat SimulatorHID" < "$X/host/simhid/simhid.m" > "$W/SimulatorHID"
	mkdir -p "$X/host/simhid/arm64$SUF/SimulatorHID.framework" && mv "$W/SimulatorHID" "$X/host/simhid/arm64$SUF/SimulatorHID.framework/" ;;
metalhostd)
	# arm64 sim target. Runs under the A64 JIT; talks to native mtlvk.
	tar cf - -C "$X/host/metalhostd" vkmtl.m vkmtl_proto.h metalhostd.m | mac "
	rm -rf /tmp/a64mtl && mkdir -p /tmp/a64mtl && cd /tmp/a64mtl && tar xf - &&
	xcrun -sdk $SIMSDK clang $T -O1 -g -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
		-fno-objc-arc -framework Foundation -framework Metal -framework IOSurface -lobjc \
		-o metalhostd metalhostd.m vkmtl.m >&2 &&
	cat metalhostd" > "$W/metalhostd"
	mkdir -p "$X/host/metalhostd/arm64$SUF" && mv "$W/metalhostd" "$X/host/metalhostd/arm64$SUF/metalhostd"
	chmod +x "$X/host/metalhostd/arm64$SUF/metalhostd" ;;
iosurfaced)
	# Foundation + IOKit (IOCFSerialize), not IOSurface.framework.
	tar cf - -C "$X/host/iosurfaced" iosurfaced.m | mac "
	rm -rf /tmp/a64ios && mkdir -p /tmp/a64ios && cd /tmp/a64ios && tar xf - &&
	xcrun -sdk $SIMSDK clang $T -O1 -g -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
		-fno-objc-arc -framework Foundation -framework IOKit -lobjc \
		-o iosurfaced iosurfaced.m >&2 &&
	cat iosurfaced" > "$W/iosurfaced"
	mkdir -p "$X/host/iosurfaced/arm64$SUF" && mv "$W/iosurfaced" "$X/host/iosurfaced/arm64$SUF/iosurfaced"
	chmod +x "$X/host/iosurfaced/arm64$SUF/iosurfaced" ;;
mtlprobe)
	tar cf - -C "$X/tests/metal" mtlprobe.m shaders/probe_metallib.h shaders/probe_source.h | mac "
	rm -rf /tmp/a64probe && mkdir -p /tmp/a64probe && cd /tmp/a64probe && tar xf - &&
	xcrun -sdk $SIMSDK clang $T -O1 -g -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new \
		-fobjc-arc -framework Foundation -framework Metal -framework IOSurface \
		-o mtlprobe mtlprobe.m >&2 &&
	cat mtlprobe" > "$W/mtlprobe"
	mkdir -p "$X/tests/metal/arm64$SUF" && mv "$W/mtlprobe" "$X/tests/metal/arm64$SUF/mtlprobe"
	chmod +x "$X/tests/metal/arm64$SUF/mtlprobe" ;;
openurl)
	# arm64 sim target. Linux inotify via svc #0xfffe.
	tar cf - -C "$X/host/openurl" openurl.m openurl.entitlements | mac "
	rm -rf /tmp/a64openurl && mkdir -p /tmp/a64openurl && cd /tmp/a64openurl && tar xf - &&
	xcrun -sdk $SIMSDK clang $T -O1 -g -Wall -Wno-deprecated-declarations \
		-fobjc-arc -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,openurl.entitlements \
		-o openurl openurl.m >&2 &&
	cat openurl" > "$W/openurl"
	mkdir -p "$X/host/openurl/arm64$SUF" && mv "$W/openurl" "$X/host/openurl/arm64$SUF/openurl"
	chmod +x "$X/host/openurl/arm64$SUF/openurl" ;;
netconfig)
	# Speed 26: the host network configuration into com.x86sim.host-configd (mksimdevice skips the job when this build
	# is missing: the arm64 phone then had no network state and every request failed "offline", -1009)
	tar cf - -C "$X/host/netconfig" netconfig.m | mac "
	rm -rf /tmp/a64netcfg && mkdir -p /tmp/a64netcfg && cd /tmp/a64netcfg && tar xf - &&
	xcrun -sdk $SIMSDK clang $T -O1 -g -Wall -Wno-deprecated-declarations \
		-fobjc-arc -framework Foundation -framework SystemConfiguration -o netconfig netconfig.m >&2 &&
	cat netconfig" > "$W/netconfig"
	mkdir -p "$X/host/netconfig/arm64$SUF" && mv "$W/netconfig" "$X/host/netconfig/arm64$SUF/netconfig"
	chmod +x "$X/host/netconfig/arm64$SUF/netconfig" ;;
fpsim2host)
	# Speed 16: the FileProvider sim2host stand-in (job com.x86sim.fpsim2host, started when Files opens)
	tar cf - -C "$X/host/fpsim2host" fpsim2host.m | mac "
	rm -rf /tmp/a64fpsh && mkdir -p /tmp/a64fpsh && cd /tmp/a64fpsh && tar xf - &&
	xcrun -sdk $SIMSDK clang $T -O1 -g -Wall -Wno-deprecated-declarations \
		-fobjc-arc -framework Foundation -o fpsim2host fpsim2host.m >&2 &&
	cat fpsim2host" > "$W/fpsim2host"
	mkdir -p "$X/host/fpsim2host/arm64$SUF" && mv "$W/fpsim2host" "$X/host/fpsim2host/arm64$SUF/fpsim2host"
	chmod +x "$X/host/fpsim2host/arm64$SUF/fpsim2host" ;;
*) echo "unknown target: $w" >&2; exit 1 ;;
esac; done
file "$X"/host/sim*/arm64$SUF/*/* "$X"/host/sim*/arm64$SUF/*/*/* \
	"$X"/host/metalhostd/arm64$SUF/metalhostd "$X"/host/iosurfaced/arm64$SUF/iosurfaced \
	"$X"/tests/metal/arm64$SUF/mtlprobe "$X"/host/openurl/arm64$SUF/openurl "$X"/host/netconfig/arm64$SUF/netconfig "$X"/host/fpsim2host/arm64$SUF/fpsim2host 2>/dev/null | grep -i mach || true
