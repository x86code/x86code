#!/bin/bash
# x86Sim: `x86sim install|uninstall`, as `xcrun simctl install|uninstall` on a Mac (`x86sim launch`: simctl.py).
#   install <path.app>             copy the bundle into the device and have installd install it (through
#                                  LaunchServices -> InstallCoordination -> installd, in host/openurl inside the device)
#   uninstall <bundle id>
# An optional first argument names the device, as simctl's <device>: a device dir, or an arm64 phone's name / folder
# (var/device-a64-<name>, as `x86sim device list` shows; "booted" = the default). Else X86SIM_DEVICE.
# Each waits for the helper's answer in <device>/data/var/log/x86sim-openurl.log and prints it.
. "$(dirname "$0")/../lib/config.sh"
cmd=$1; shift
. "$(dirname "$0")/../lib/pickdevice.sh"
# install <device> <app> / uninstall <device> <bundle id>: a leading device argument when one more follows
if [ $# -ge 2 ] && pick_device "$1"; then shift; fi
export X86SIM_DEVICE
D=$X86SIM_DEVICE/data
LOG=$D/var/log/x86sim-openurl.log
Q=$D/tmp/x86sim-openurl
request() {  # request LINE PATTERN TIMEOUT
	local n; n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
	printf '%s\n' "$1" > "$Q.new" && mv "$Q.new" "$Q"
	for _ in $(seq $(( $3 * 2 ))); do
		sleep 0.5
		r=$(tail -n +$((n + 1)) "$LOG" 2>/dev/null | grep -m1 -E "$2") && { echo "$r"; [[ $r != *failed* && $r != *error* ]]; return; }
	done
	echo "$cmd: no answer in $3 s (is the device booted? see $LOG)" >&2; return 1
}
case $cmd in
install)
	app=${1%/}; [ -f "$app/Info.plist" ] || { echo "usage: x86sim install <path.app>" >&2; exit 2; }
	# staging copy inside the device's data directory (visible inside Darling); installd copies it again
	S=$D/tmp/x86sim-install; mkdir -p "$S"; rm -rf "$S/$(basename "$app")"
	cp -a "$app" "$S/" || exit 1
	request "install tmp/x86sim-install/$(basename "$app")" "^install .*$(basename "$app")" 120 || exit 1
	# Speed 31 (X86SIM_APP_AOT; Speed 32: opt-in after a full slab left placement and image apart; Speed 33: transactional): translate the app ahead of time. Its Mach-Os get placement slots
	# (placeapp.py: existing slots never move) and the AOT image gets their chunks (x86sim-aot update: the app's
	# chunks only, plus any library chunk with new .live training). Processes started from now on use them; until
	# the update has finished, new processes find no image for the new key and translate live.
	if [ "${X86SIM_APP_AOT:-1}" = 1 ]; then
		J=$(sed -n 's/^X86SIM_A64_JITCACHE_DIR=//p' "$X86SIM_DEVICE/sim.env")
		inst=$(ls -td "$D"/Containers/Bundle/Application/*/"$(basename "$app")" 2>/dev/null | head -1)
		if [ -n "$J" ] && [ -n "$inst" ]; then
			# Speed 33: transactional. placement.txt is the image key, so it is committed only together with an image
			# built for it: on any failure the previous placement comes back (the previous image still matches it).
			# Only this app's chunks are built here (--only: its container UUID); library feedback (.live) rebuilds
			# stay with the boot-time update, so an install costs its own app only. A full slab evicts the coldest
			# library chunks instead of failing (x86sim-aot).
			P=$J/placement.txt; B=$J/placement.txt.pre-install
			cp -p "$P" "$B" 2>/dev/null
			u=$(basename "$(dirname "$inst")")
			if python3 "$X86SIM_ROOT/cli/libexec/arm64/placeapp.py" "$J" "$inst" &&
				{ cmp -s "$P" "$B" || "$X86SIM_ROOT/tools/launcher/target/release/x86sim-aot" --jc "$J" --device "$X86SIM_DEVICE" update --only "$u" | tail -1; } &&
				[ "${PIPESTATUS[0]}" = 0 ]; then
				:
			else
				echo "appinstall: AOT update failed; placement restored, $(basename "$app") runs live" >&2
				[ -f "$B" ] && cp -p "$B" "$P"
			fi
		fi
	fi ;;
uninstall)
	[ -n "$1" ] || { echo "usage: x86sim uninstall <bundle id>" >&2; exit 2; }
	request "uninstall $1" "^uninstall $1:" 60 || exit 1
	# Speed 35: the uninstalled app's placement rows (and image chunks) go too, transactionally as on install: the
	# pruned placement.txt is kept only together with an image updated for it (assembly only: no chunk changes).
	if [ "${X86SIM_APP_AOT:-1}" = 1 ]; then
		J=$(sed -n 's/^X86SIM_A64_JITCACHE_DIR=//p' "$X86SIM_DEVICE/sim.env")
		P=$J/placement.txt; B=$J/placement.txt.pre-uninstall
		if [ -n "$J" ] && [ -f "$P" ]; then
			cp -p "$P" "$B"
			python3 "$X86SIM_ROOT/cli/libexec/arm64/placeapp.py" --prune "$J" "$D"; rc=$?
			if [ $rc = 0 ]; then
				"$X86SIM_ROOT/tools/launcher/target/release/x86sim-aot" --jc "$J" --device "$X86SIM_DEVICE" update | tail -1
				[ "${PIPESTATUS[0]}" = 0 ] || { echo "appinstall: AOT update after uninstall failed; placement restored" >&2; cp -p "$B" "$P"; }
			elif [ $rc != 3 ]; then
				cp -p "$B" "$P"
			fi
		fi
	fi ;;
*) echo "appinstall.sh install|uninstall" >&2; exit 2 ;;
esac
