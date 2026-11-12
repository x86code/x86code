#!/bin/bash
# x86Sim sdkcov: the reference run on Apple's own simulator, on the Mac ($X86SIM_MAC, over ssh). Same app, same
# runtime build where the Mac has it: what fails there too is Apple's behavior, not an x86Sim bug.
# A temporary simulator device (sdkcov-ref-<platform>) is created, used and deleted; other devices are not touched.
# Usage: tests/apps/sdkcov/ref-mac.sh [ios|tvos|watchos] [--no-build]   (default ios)
# Env: RUNTIME (simctl runtime id, default the Mac's newest of the platform), SECS (default 900),
#      OUT (default $X86SIM_SCRATCH/apps/sdkcov-<platform>-ref-<time>). Then report.py's report.md is in OUT.
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
S=$X86SIM_ROOT/tests/apps/sdkcov
plat=${1:-ios}; [ "${1:-}" ] && shift
build=1; [ "${1:-}" = --no-build ] && build=0
MAC=${X86SIM_MAC:?set X86SIM_MAC (ssh host of a Mac with Xcode) in x86sim.env}
case $plat in
	ios) rtname=iOS; dtype=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
	tvos) rtname=tvOS; dtype=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p ;;
	watchos) rtname=watchOS; dtype=com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm ;;
	*) echo "ref-mac: unknown platform $plat" >&2; exit 2 ;;
esac
OUT=${OUT:-$X86SIM_SCRATCH/apps/sdkcov-$plat-ref-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"
[ "$build" = 1 ] && { "$S/build.sh" "$plat" >/dev/null 2>&1 || { echo "ref-mac: build failed" >&2; exit 1; }; }
APP=$X86SIM_SCRATCH/apps/sdkcov-$plat.app
# the whole run happens on the Mac in one ssh session: the app goes over as a tar on stdin, the results come back
# (the remote script is an argument: stdin carries the app)
read -r -d '' REMOTE <<'MAC'
plat=$1 rtname=$2 dtype=$3 rt=$4 secs=$5
set -u
W=$(mktemp -d /tmp/sdkcov-ref.XXXXXX); cd "$W"; tar xf - -C "$W"
exec 3>&1 1>&2
[ -n "$rt" ] || rt=$(xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['platform']=='$rtname' and x['isAvailable']]; print(sorted(r, key=lambda x: [int(p) for p in x['version'].split('.')])[-1]['identifier'])")
dev=$(xcrun simctl create "sdkcov-ref-$plat" "$dtype" "$rt") || exit 1
cleanup() { xcrun simctl shutdown "$dev" >/dev/null 2>&1; xcrun simctl delete "$dev" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
echo "ref-mac: $rt on $dev"
xcrun simctl boot "$dev" && xcrun simctl bootstatus "$dev" -b >/dev/null
xcrun simctl install "$dev" "$W/sdkcov-$plat.app" || exit 1
data=$(xcrun simctl get_app_container "$dev" com.x86sim.test.sdkcov data)
res=$data/Documents/x86test-results.txt
t0=$(date +%s); n=0
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
	ssh -o BatchMode=yes "$MAC" "bash -c $(printf '%q' "$REMOTE") ref $plat $rtname $dtype '${RUNTIME:-}' ${SECS:-900}" > "$OUT/ref.tar"
(cd "$OUT" && tar xf ref.tar && rm ref.tar)
[ -f "$OUT/results.txt" ] || { echo "ref-mac: no results came back" >&2; exit 1; }
python3 "$S/report.py" "$OUT" > "$OUT/report.md"
sed -n '1,/^## Failures/p' "$OUT/report.md" | grep -v '^## Failures'
echo "report: $OUT/report.md"
