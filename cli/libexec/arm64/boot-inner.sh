#!/bin/bash
# Runs inside cli/libexec/limited.sh (see boot-a64.sh). First darling touch creates darlingserver in
# this scope; join_prefix_cgroup moves any escapees so MemoryMax counts real guest RSS.
# Env: DPREFIX, X86SIM_DARLING, A64_TZNAME, A64_TIMEOUT, A64_CMDFILE, A64_PREFETCH_HOT
set -e
# Speed 11: warm the host page cache with the last boot's hot file ranges (prefetch.py, A64_PREFETCH_HOT from
# boot-a64.sh) while the container starts; from inside this scope, so the reads count against its IO cap
if [ -n "${A64_PREFETCH_HOT:-}" ]; then
	(python3 -I "$(dirname "$0")/prefetch.py" apply $A64_PREFETCH_HOT > /dev/null 2>&1 &)
fi
join_prefix_cgroup() {
	local self_cg p cmd cgfile pid
	self_cg=$(awk -F: '/^0::/{print $NF; exit}' /proc/self/cgroup 2>/dev/null)
	[ -n "$self_cg" ] || return 0
	cgfile=/sys/fs/cgroup${self_cg}/cgroup.procs
	[ -w "$cgfile" ] || return 0
	# one grep per pass (a tr + grep per host process forked ~1,300 times every 3 s)
	for p in $(grep -lsa -- "darlingserver" /proc/[0-9]*/cmdline 2>/dev/null); do
		pid=${p#/proc/}; pid=${pid%/cmdline}
		cmd=$(tr '\0' ' ' < "$p" 2>/dev/null)
		case "$cmd" in
			# "a64prefix " must not match another phone's "a64prefix-<name> "
			*"darlingserver ${DPREFIX} "*) echo "$pid" > "$cgfile" 2>/dev/null || true ;;
		esac
	done
	# only this phone's processes: its guests (SIMULATOR_UDID), Darling's loaders (__mldr_sockpath, A64_DPREFIX) and
	# host helpers (DPREFIX). Every phone's processes have X86SIM_A64_*, and taking those pulled the other running
	# phones into this scope (stopping this phone then killed them too).
	for p in $(grep -lsazxF -e "DPREFIX=$DPREFIX" -e "A64_DPREFIX=$DPREFIX" -e "__mldr_sockpath=$DPREFIX/.darlingserver.sock" \
			${PHONE_UDID:+-e "SIMULATOR_UDID=$PHONE_UDID"} /proc/[0-9]*/environ 2>/dev/null); do
		pid=${p#/proc/}; echo "${pid%/environ}" > "$cgfile" 2>/dev/null || true
	done
}
PHONE_UDID=$(grep -o 'SIMULATOR_UDID=[0-9A-Fa-f-]*' "$A64_CMDFILE" 2>/dev/null | head -1 | cut -d= -f2)
if [ -n "$A64_TZNAME" ] && [ -f "/usr/share/zoneinfo/$A64_TZNAME" ]; then
	timeout 30 "$X86SIM_DARLING" shell ln -sf "/usr/share/zoneinfo/$A64_TZNAME" /private/etc/localtime < /dev/null > /dev/null 2>&1 || true
fi
join_prefix_cgroup
(
	for _ in $(seq 1 30); do
		sleep 3
		# (2026-11-13) a stopped phone's loop ended only after its 90 s: it kept moving the next boot's processes
		# into this (stopped) scope. It ends with this phone's darlingserver.
		pgrep -f "darlingserver ${DPREFIX} " > /dev/null || break
		join_prefix_cgroup
	done
) &
exec timeout "$A64_TIMEOUT" "$X86SIM_DARLING" shell sh -c "$(cat "$A64_CMDFILE")" < /dev/null
