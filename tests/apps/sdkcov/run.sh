#!/bin/bash
# x86Sim sdkcov: build the SDK coverage app for a running device's platform (iOS, tvOS, watchOS or visionOS, from
# <device>/runtime), install it, launch it and keep it going until it reports "done": a crash or the app's hang
# watchdog ends the process, and the next launch resumes after the check that died (Harness.swift). Then the results,
# the coverage JSON and a Markdown report (report.py) go to OUT, with a screenshot.
# Usage: tests/apps/sdkcov/run.sh <device> [--no-build] [--fresh] [--only ID[,ID...]]
#   --fresh   start over (delete the previous run's results in the app's container)
#   --only    run only the checks whose id contains one of these (e.g. func:Metal,load:UIKit); for debugging: the
#             results file is left alone, results go to the app's stderr (OUT/sdkcov-1.err)
# Env: SECS (overall limit, default 3600), STALL (relaunch when no new result for this long, default 300),
#      RELAUNCH (max relaunches, default 40), OUT (default $X86SIM_SCRATCH/apps/sdkcov-<platform>-<time>).
set -u
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
. "$X86SIM_ROOT/cli/lib/config.sh"
. "$X86SIM_ROOT/cli/lib/pickdevice.sh"
X=$X86SIM_ROOT; S=$X/tests/apps/sdkcov
dev=${1:?usage: tests/apps/sdkcov/run.sh <device> [--no-build] [--fresh]}; shift
pick_device "$dev" || { echo "sdkcov: no device $dev" >&2; exit 2; }
export X86SIM_DEVICE
build=1 fresh=0
ONLY=
while [ $# -gt 0 ]; do case $1 in --no-build) build=0 ;; --fresh) fresh=1 ;; --only) ONLY="--only $2"; shift ;;
	*) echo "sdkcov: unknown option $1" >&2; exit 2 ;; esac; shift; done
rt=$(cat "$X86SIM_DEVICE/runtime" 2>/dev/null); plat=${rt%%-*}
case $plat in ios|tvos|watchos|xros) ;; *) echo "sdkcov: $X86SIM_DEVICE: unsupported runtime '$rt'" >&2; exit 2 ;; esac
SECS=${SECS:-3600}; STALL=${STALL:-300}; RELAUNCH=${RELAUNCH:-40}
OUT=${OUT:-$X86SIM_SCRATCH/apps/sdkcov-$plat-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"
BID=com.x86sim.test.sdkcov; APP=$X86SIM_SCRATCH/apps/sdkcov-$plat.app
xs() { "$X/cli/x86sim" "$@"; }
[ "$build" = 1 ] && { nice "$S/build.sh" "$plat" || exit 1; }
xs install "$X86SIM_DEVICE" "$APP" >"$OUT/install.log" 2>&1 || { echo "install FAILED: $(tail -1 "$OUT/install.log")"; exit 1; }
DATA=$(xs get_app_container "$BID" data 2>/dev/null)
[ -d "$DATA" ] || { echo "sdkcov: no data container for $BID" >&2; exit 1; }
RES=$DATA/Documents/x86test-results.txt
rm -f "$X86SIM_DEVICE"/data/tmp/sdkcov-*.out "$X86SIM_DEVICE"/data/tmp/sdkcov-*.err
[ "$fresh" = 1 ] && rm -f "$RES" "$DATA/Documents/sdkcov-progress" "$DATA/Documents/sdkcov-coverage.json"
# a finished previous run starts over by itself (Harness.prepare); an unfinished one resumes
echo "sdkcov $plat on $(basename "$X86SIM_DEVICE"): results $RES"
# WidgetKit needs chronod, which is the device's "widgets" feature (off by default: ~350-750 MB): on for sdkcov devices
grep -qs '"widgets": *true' "$X86SIM_DEVICE/features.json" ||
	echo "  note: feature \"widgets\" is off on this device: WidgetKit fails (x86sim-aot features, or features.json)"
lines() { [ -f "$RES" ] && wc -l < "$RES" || echo 0; }
done_() { [ -f "$RES" ] && grep -q "^X86TEST sdkcov done " "$RES"; }
t0=$(date +%s); launches=0; last=$(lines); lastt=$t0
launch() {
	launches=$((launches + 1))
	xs terminate "$BID" >/dev/null 2>&1
	# the app's stdout / stderr per launch (abort messages, Swift runtime errors) in the device's tmp, copied to OUT
	xs launch --stdout=tmp/sdkcov-$launches.out --stderr=tmp/sdkcov-$launches.err "$BID" $ONLY >>"$OUT/launch.log" 2>&1 ||
		echo "  launch $launches failed: $(tail -1 "$OUT/launch.log")"
	sleep 5
}
# a first launch of a finished run starts over: the app resets when it sees "done"
launch
if [ -n "$ONLY" ]; then   # one launch; its stderr is the result
	for _ in $(seq $((SECS / 2))); do [ -z "$(xs pidof "$BID" 2>/dev/null)" ] && break
		grep -q "X86TEST sdkcov done " "$X86SIM_DEVICE/data/tmp/sdkcov-1.err" 2>/dev/null && break; sleep 2; done
	cp "$X86SIM_DEVICE"/data/tmp/sdkcov-1.* "$OUT/" 2>/dev/null
	grep "X86TEST" "$OUT/sdkcov-1.err" | grep -v -e " only " -e " done "
	[ -n "$(xs pidof "$BID" 2>/dev/null)" ] || { echo "app exited; stderr tail:"; grep -v X86TEST "$OUT/sdkcov-1.err" | tail -15; }
	exit 0
fi
while ! done_; do
	sleep 5
	now=$(date +%s); n=$(lines)
	[ "$n" != "$last" ] && { last=$n; lastt=$now; printf '\r  %s results, %s launches, %s s ' "$n" "$launches" $((now - t0)); }
	[ $((now - t0)) -gt "$SECS" ] && { echo; echo "  gave up after $SECS s"; break; }
	pid=$(xs pidof "$BID" 2>/dev/null)
	if [ -z "$pid" ] || [ $((now - lastt)) -gt "$STALL" ]; then
		[ "$launches" -ge "$RELAUNCH" ] && { echo; echo "  gave up after $launches launches"; break; }
		echo; echo "  $([ -z "$pid" ] && echo "app not running (crash / watchdog)" || echo "no progress in $STALL s"): relaunch; last: $(tail -1 "$RES" 2>/dev/null | cut -c1-160)"
		launch; lastt=$(date +%s)
	fi
done
echo
cp "$RES" "$OUT/results.txt" 2>/dev/null
for f in "$X86SIM_DEVICE"/data/tmp/sdkcov-*.out "$X86SIM_DEVICE"/data/tmp/sdkcov-*.err; do [ -s "$f" ] && cp "$f" "$OUT/"; done
cp "$DATA/Documents/sdkcov-coverage.json" "$OUT/coverage.json" 2>/dev/null
find "$DATA/Library/Logs/DiagnosticReports" "$X86SIM_DEVICE/data/Library/Logs/DiagnosticReports" -name 'sdkcov*' -newer "$OUT/install.log" -exec cp {} "$OUT/" \; 2>/dev/null
xs screenshot "$OUT/screen.png" 2 >/dev/null 2>&1
python3 "$S/report.py" "$OUT" > "$OUT/report.md"
sed -n '1,/^## Failures/p' "$OUT/report.md" | grep -v '^## Failures'
grep -c ' FAIL ' "$OUT/results.txt" 2>/dev/null | sed 's/^/FAIL lines: /'
echo "report: $OUT/report.md"
done_ && ! grep -q ' FAIL ' "$OUT/results.txt" && { echo PASS; exit 0; }
echo FAIL; exit 1
