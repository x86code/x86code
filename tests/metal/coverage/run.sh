#!/bin/bash
# x86Sim MetalCoverage: build, install and run the suite on a booted device; a crash or hang is charged to the test
# that was running and the app is relaunched at the next one. -> <out>/results.tsv, <out>/run.log, report.html
#   tests/metal/coverage/run.sh [--no-build] [--only SUBSTR] [--out DIR]
# The device is the CLI's (X86SIM_DEVICE / X86SIM_STATE, as `x86sim install`).
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
X86SIM_ROOT=$(cd "$H/../../.." && pwd); . "$X86SIM_ROOT/cli/lib/config.sh"
X=$X86SIM_ROOT/cli/x86sim
build=1 only= out=$X86SIM_SCRATCH/mtlcov/run-$(date +%Y%m%d-%H%M%S)
while [ $# -gt 0 ]; do
	case $1 in
		--no-build) build=0; shift ;;
		--only) only=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		*) echo "usage: $0 [--no-build] [--only SUBSTR] [--out DIR]" >&2; exit 2 ;;
	esac
done
APP=$X86SIM_SCRATCH/mtlcov/MetalCoverage.app
mkdir -p "$out"
if [ $build = 1 ]; then "$H/build.sh" "$APP" >/dev/null || exit 1; fi
timeout 300 "$X" install "$APP" 2>&1 | grep -E "\): (ok|failed)" || { echo "install failed" >&2; exit 1; }
printf "index\ttest\tstatus\tms\tclaimed\tdetail\n" > "$out/results.tsv"
: > "$out/covers.tsv"
from=0
while :; do
	env=(--env MTLCOV_EXIT=1 --env MTLCOV_FROM=$from)
	[ -n "$only" ] && env+=(--env "MTLCOV_ONLY=$only")
	log=$out/launch-$from.log
	# the console follows the app until it exits; a test that wedges the GPU path is the watchdog's (exit 3)
	timeout 900 "$X" launch --console --terminate-running-process "${env[@]}" com.x86sim.test.mtlcov > "$log" 2>&1
	cat "$log" >> "$out/run.log"
	grep -a "^MTLCOV RESULT " "$log" | while read -r _ _ i name st ms claimed rest; do
		printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$i" "$name" "$st" "$ms" "${claimed#claimed=}" "$rest"
	done >> "$out/results.tsv"
	grep -a "^MTLCOV COVERS " "$log" | cut -d' ' -f3- | sed 's/ /\t/' >> "$out/covers.tsv"
	grep -aq "^MTLCOV DONE " "$log" && break
	# the test that began and has no result: crashed (or hung, the watchdog says which)
	last=$(grep -a "^MTLCOV BEGIN " "$log" | tail -1)
	[ -z "$last" ] && { echo "the app produced no test (see $log)" >&2; break; }
	i=$(echo "$last" | cut -d' ' -f3); name=$(echo "$last" | cut -d' ' -f4)
	if ! grep -aq "^MTLCOV RESULT $i " "$log"; then
		why=CRASH; grep -aq "^MTLCOV HANG $i " "$log" && why=HANG
		sig=$(grep -a -m1 -E "exception reason|guest pc in|signal [0-9]+ code|Assertion|failed assertion" "$log" | cut -c1-200 | tr '\t' ' ')
		# Apple's simulator client (MTLSimDriver) or Metal's own validation refused the call: as on a Mac's simulator
		echo "$sig" | grep -qE "failed assertion" && why=REFUSED
		printf "%s\t%s\t%s\t0\t1\t%s\n" "$i" "$name" "$why" "$sig" >> "$out/results.tsv"
		echo "$why $name" >&2
	fi
	from=$((i + 1))
done
tail -n +2 "$out/results.tsv" | cut -f3 | sort | uniq -c | tr '\n' ' '; echo
python3 -I "$H/report.py" "$out" && echo "$out/report.html"
