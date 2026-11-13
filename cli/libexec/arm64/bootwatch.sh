#!/bin/bash
# x86Sim (2026-11-13): boot watchdog. A rare boot hangs for good: the screen stays black and every process sits idle in
# its run loop (mach_msg receive), nothing crashed (tvOS ~1 boot in 30, visionOS 2 in ~75; cause not found yet: a lost
# Mach message or wakeup is the suspect). Started in the background by boot-a64.sh: if the phone has not reached its
# home screen A64_STALL_SECS (default 75; a boot takes 8-18 s) after the boot started and the phone is idle (the
# launcher's CPU figure under 15%: a slow but busy first boot is left alone), it saves what the hang looks like to
# <state>/stall-<time>/ (launchd log, every process's threads: comm, wchan, syscall) and asks the launcher to restart
# the phone, once per A64_STALL_COOLDOWN seconds (default 600: a phone that hangs again is left as it is, for a look).
# The restart runs outside this boot's systemd scope (the stop ends the scope and everything in it).
# A64_STALL_SECS=0: off; A64_STALL_TEST=1 (test): home never counts. Usage: bootwatch.sh <device dir> <state dir> <darling prefix>
D=$1 ST=$2 DPREFIX=$3
X=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SECS=${A64_STALL_SECS:-75}
[ "$SECS" -gt 0 ] 2>/dev/null || exit 0
ph=$(basename "$D"); ph=${ph#device-a64-}
MCP=$X/tools/launcher/target/release/x86sim-mcp
[ -x "$MCP" ] || exit 0
mcp() {  # mcp TOOL JSON: one tools/call, prints the result text
	{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bootwatch","version":"1"}}}' \
		'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
		"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; sleep 2; } |
		"$MCP" 2>/dev/null | tail -1
}
status() {  # "<state> <home 0|1> <cpu %>" of this phone
	mcp phones_list '{}' | python3 -c 'import json,sys
d=json.loads(json.load(sys.stdin)["result"]["content"][0]["text"])
p=[x for x in d["phones"] if x["id"]=="device-a64-"+sys.argv[1]]
print(p[0]["state"], int(p[0]["home"]), int(p[0]["cpu_pct"])) if p else print("off 0 0")' "$ph" 2>/dev/null
}
t0=$(date +%s)
while :; do
	sleep 5
	read -r state home cpu <<< "$(status)"
	[ "${A64_STALL_TEST:-0}" = 1 ] && home=0  # test: act as if home never came
	[ "$home" = 1 ] && exit 0
	[ "$state" = off ] || [ "$state" = stopping ] && exit 0
	[ $(( $(date +%s) - t0 )) -lt "$SECS" ] && continue
	# idle twice in a row, 5 s apart (one quiet sample can be a pause)
	[ "${cpu:-100}" -lt 15 ] || { idle=0; continue; }
	idle=$((${idle:-0} + 1)); [ "$idle" -ge 2 ] || continue
	break
done
now=$(date +%Y%m%d-%H%M%S); O=$ST/stall-$now; mkdir -p "$O"
cp "$ST/launchd.log" "$O/" 2>/dev/null
for p in /proc/[0-9]*; do
	grep -qsazxF -e "DPREFIX=$DPREFIX" -e "__mldr_sockpath=$DPREFIX/.darlingserver.sock" "$p/environ" 2>/dev/null || continue
	for t in "$p"/task/*; do
		echo "$(cat "$p/comm" 2>/dev/null) ${p#/proc/} ${t##*/} $(cat "$t/comm" 2>/dev/null) $(cat "$t/wchan" 2>/dev/null) $(cut -d' ' -f1-3 "$t/syscall" 2>/dev/null)"
	done
done > "$O/threads.txt" 2>/dev/null
# a process of the phone with a single thread waiting on a futex is a fork child stuck before its exec (launchd's
# spawn children were): a core of it (systemd-coredump; ptrace is not allowed here) shows the lock: the registers
# (the futex address) and the mappings. Its signal handlers may swallow one signal: QUIT, then ABRT, then SEGV.
for p in /proc/[0-9]*; do
	grep -qsazxF -e "DPREFIX=$DPREFIX" -e "__mldr_sockpath=$DPREFIX/.darlingserver.sock" "$p/environ" 2>/dev/null || continue
	[ "$(ls "$p/task" 2>/dev/null | wc -l)" = 1 ] && [ "$(cat "$p/wchan" 2>/dev/null)" = __futex_wait ] || continue
	pid=${p#/proc/}
	echo "$pid $(cat "$p/comm" 2>/dev/null)" >> "$O/forkstuck.txt"
	for s in QUIT ABRT SEGV; do kill -s $s "$pid" 2>/dev/null || break; sleep 3; [ -d "$p" ] || break; done
	sleep 2
	coredumpctl --no-pager dump "$pid" -o "$O/core.$pid" > /dev/null 2>&1
done
M=$D/.stall-restart
last=$(cat "$M" 2>/dev/null || echo 0)
if [ $(( $(date +%s) - last )) -lt "${A64_STALL_COOLDOWN:-600}" ]; then
	echo "$(date +%T) bootwatch: $ph not home after $SECS s and idle again: left as it is (see $O)" >> "$ST/bootwatch.log"
	exit 0
fi
date +%s > "$M"
echo "$(date +%T) bootwatch: $ph not home after $SECS s, idle (cpu $cpu%): restarting (diagnostics in $O)" >> "$ST/bootwatch.log"
# a transient scope, not a service: a service's end kills what its main process left running (the restarted boot)
(setsid systemd-run --user --quiet --scope --unit="x86sim-bootwatch-$ph-$now" \
	bash -c "$(declare -f mcp); MCP='$MCP'; mcp sim_restart '{\"phone\":\"$ph\"}' >/dev/null" < /dev/null > /dev/null 2>&1 ||
	setsid bash -c "$(declare -f mcp); MCP='$MCP'; mcp sim_restart '{\"phone\":\"$ph\"}' >/dev/null" < /dev/null > /dev/null 2>&1 &)
