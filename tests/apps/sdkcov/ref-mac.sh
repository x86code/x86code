#!/bin/bash
# x86Sim sdkcov: the reference run on Apple's own simulator, on the Mac ($X86SIM_MAC, over ssh). Same app, same
# runtime build where the Mac has it: what fails there too is Apple's behavior, not an x86Sim bug.
# A temporary simulator device (sdkcov-ref-<platform>) is created, used and deleted; other devices are not touched.
# Usage: tests/apps/sdkcov/ref-mac.sh [ios|tvos|watchos|xros] [--no-build] [--only ID[,ID...]]   (default ios)
#   --only   one launch running just the checks whose id contains one of these (as run.sh --only); their results
#            are printed (the app's stderr is OUT/sdkcov-1.err), no report
# Env: RUNTIME (simctl runtime id, default the Mac's newest of the platform), SECS (default 900),
#      OUT (default $X86SIM_SCRATCH/apps/sdkcov-<platform>-ref-<time>). Then report.py's report.md is in OUT.
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
S=$X86SIM_ROOT/tests/apps/sdkcov
plat=${1:-ios}; [ "${1:-}" ] && shift
build=1 only=
while [ $# -gt 0 ]; do case $1 in --no-build) build=0 ;; --only) only=$2; shift ;;
	*) echo "ref-mac: unknown option $1" >&2; exit 2 ;; esac; shift; done
MAC=${X86SIM_MAC:?set X86SIM_MAC (ssh host of a Mac with Xcode) in x86sim.env}
case $plat in
	ios) rtname=iOS; dtype=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
	tvos) rtname=tvOS; dtype=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p ;;
	watchos) rtname=watchOS; dtype=com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm ;;
	xros) rtname=visionOS,xrOS;   # simctl's platform name, by Xcode version
		dtype=com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K ;;
	*) echo "ref-mac: unknown platform $plat" >&2; exit 2 ;;
esac
OUT=${OUT:-$X86SIM_SCRATCH/apps/sdkcov-$plat-ref-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"
[ "$build" = 1 ] && { "$S/build.sh" "$plat" >/dev/null 2>&1 || { echo "ref-mac: build failed" >&2; exit 1; }; }
APP=$X86SIM_SCRATCH/apps/sdkcov-$plat.app
# the whole run happens on the Mac in one ssh session: the app goes over as a tar on stdin, the results come back
# (the remote script is an argument: stdin carries the app)
read -r -d '' REMOTE <<'MAC'
plat=$1 rtname=$2 dtype=$3 rt=$4 secs=$5 only=$6
set -u
W=$(mktemp -d /tmp/sdkcov-ref.XXXXXX); cd "$W"; tar xf - -C "$W"
exec 3>&1 1>&2
[ -n "$rt" ] || rt=$(xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['platform'] in '$rtname'.split(',') and x['isAvailable']]; print(sorted(r, key=lambda x: [int(p) for p in x['version'].split('.')])[-1]['identifier'])")
dev=$(xcrun simctl create "sdkcov-ref-$plat" "$dtype" "$rt") || exit 1
cleanup() { xcrun simctl shutdown "$dev" >/dev/null 2>&1; xcrun simctl delete "$dev" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
echo "ref-mac: $rt on $dev"
xcrun simctl boot "$dev" && xcrun simctl bootstatus "$dev" -b >/dev/null
xcrun simctl install "$dev" "$W/sdkcov-$plat.app" || exit 1
# tvOS / watchOS / visionOS: func:HomeKit.manager's HMHomeManager asks for Home access; the prompt would take focus from the app
# for the rest of the run (More_tvOS.swift's focus, window and snapshot checks need the app active; on the watch the
# app stayed inactive behind it, applicationState 1): grant it up front
# (simctl privacy over ssh fails here: "Failed to create TCC authorization record: Operation not permitted"; the
# device's TCC.db takes the row directly, as simctl would write it)
case $plat in tvos|watchos|xros) xcrun simctl privacy "$dev" grant homekit com.x86sim.test.sdkcov >/dev/null 2>&1 ||
	sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Library/TCC/TCC.db" "insert or replace into access
		(service, client, client_type, auth_value, auth_reason, auth_version, flags) values
		('kTCCServiceWillow', 'com.x86sim.test.sdkcov', 0, 2, 4, 1, 0)" || echo "ref-mac: HomeKit not pre-granted" ;; esac
data=$(xcrun simctl get_app_container "$dev" com.x86sim.test.sdkcov data)
res=$data/Documents/x86test-results.txt
t0=$(date +%s); n=0
if [ -n "$only" ]; then   # one launch; its stderr is the result
	# --console-pty: the app's stdout / stderr come back through simctl (a --stderr file stays empty here)
	xcrun simctl launch --console-pty "$dev" com.x86sim.test.sdkcov --only "$only" >"$W/sdkcov-1.err" 2>&1 &
	sleep 5
	while [ $(( $(date +%s) - t0 )) -lt "$secs" ] && ! grep -q "X86TEST sdkcov done " "$W/sdkcov-1.err" 2>/dev/null; do
		xcrun simctl spawn "$dev" launchctl list 2>/dev/null | grep -q "com.x86sim.test.sdkcov" || break
		sleep 2
	done
	xcrun simctl terminate "$dev" com.x86sim.test.sdkcov >/dev/null 2>&1; sleep 1; kill %1 2>/dev/null
	cd "$W" && tar cf - sdkcov-*.err 2>/dev/null >&3
	exit 0
fi
while [ $(( $(date +%s) - t0 )) -lt "$secs" ]; do
	grep -q "^X86TEST sdkcov done " "$res" 2>/dev/null && break
	if ! xcrun simctl spawn "$dev" launchctl list 2>/dev/null | grep -q "UIKitApplication:com.x86sim.test.sdkcov"; then
		n=$((n + 1)); [ $n -gt 40 ] && break
		xcrun simctl launch --stderr="$W/sdkcov-$n.err" "$dev" com.x86sim.test.sdkcov >/dev/null
	fi
	sleep 3
done
cp "$res" "$W/results.txt" 2>/dev/null; cp "$data/Documents/sdkcov-coverage.json" "$W/coverage.json" 2>/dev/null
xcrun simctl io "$dev" screenshot "$W/screen.png" >/dev/null 2>&1
cd "$W" && tar cf - results.txt coverage.json screen.png sdkcov-*.err 2>/dev/null >&3
MAC
tar cf - -C "$(dirname "$APP")" "$(basename "$APP")" |
	ssh -o BatchMode=yes "$MAC" "bash -c $(printf '%q' "$REMOTE") ref $plat $rtname $dtype '${RUNTIME:-}' ${SECS:-900} '$only'" > "$OUT/ref.tar"
(cd "$OUT" && tar xf ref.tar && rm ref.tar)
if [ -n "$only" ]; then
	tr -d '\r' < "$OUT/sdkcov-1.err" | grep "^X86TEST" | grep -v -e " only " -e " done " | cut -d' ' -f3-
	grep -q "X86TEST sdkcov done " "$OUT/sdkcov-1.err" 2>/dev/null ||
		{ echo "ref-mac: the app did not finish; stderr tail:"; grep -v X86TEST "$OUT/sdkcov-1.err" 2>/dev/null | tail -15; }
	echo "stderr: $OUT/sdkcov-1.err"; exit 0
fi
[ -f "$OUT/results.txt" ] || { echo "ref-mac: no results came back" >&2; exit 1; }
python3 "$S/report.py" "$OUT" > "$OUT/report.md"
sed -n '1,/^## Failures/p' "$OUT/report.md" | grep -v '^## Failures'
echo "report: $OUT/report.md"
