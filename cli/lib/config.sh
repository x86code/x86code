# x86Sim: configuration for every script (sourced, POSIX sh). The caller sets X86SIM_ROOT (the repo root).
# Order: environment > config file ($X86SIM_CONFIG, default $X86SIM_ROOT/x86sim.env) > defaults below.
# The sudo password is never configured here: scripts that need root read SUDO_PASS from the environment
# (or use a cached sudo).
: "${X86SIM_ROOT:?X86SIM_ROOT must be set}"
_x86sim_keys="X86SIM_ARCH X86SIM_PREFIX X86SIM_RUNTIME X86SIM_DEVICE X86SIM_STATE X86SIM_SCRATCH X86SIM_MTLVK X86SIM_MAC X86SIM_SCREENS X86SIM_BOOT_SECS X86SIM_DPREFIX X86SIM_DARLING_BUILD X86SIM_METAL MTLVK_DEVICE VK_ICD_FILENAMES MESA_VK_DEVICE_SELECT DISPLAY"
_x86sim_saved=""
for _k in $_x86sim_keys; do
	eval "_v=\${$_k+set}"
	if [ "$_v" = set ]; then eval "_x86sim_env_$_k=\$$_k"; _x86sim_saved="$_x86sim_saved $_k"; fi
done
_cfg=${X86SIM_CONFIG:-$X86SIM_ROOT/x86sim.env}
if [ -f "$_cfg" ]; then . "$_cfg"; fi
for _k in $_x86sim_saved; do eval "$_k=\$_x86sim_env_$_k"; done
: "${X86SIM_PREFIX:=$X86SIM_ROOT/darling-prefix}"
: "${X86SIM_ARCH:=arm64}"
: "${X86SIM_RUNTIME:=$X86SIM_ROOT/runtimes/ios-27.2-24B8117-arm64/RuntimeRoot}"
: "${X86SIM_DEVICE:=$X86SIM_ROOT/var/device-a64}"
: "${X86SIM_STATE:=$X86SIM_ROOT/var/run}"
: "${X86SIM_SCRATCH:=$HOME/scratch/x86sim}"
: "${X86SIM_MTLVK:=$X86SIM_ROOT/linux/mtlvk/target/release/mtlvk}"
: "${X86SIM_MAC:=}"
: "${X86SIM_SCREENS:=$X86SIM_ROOT/docs/screens}"
: "${X86SIM_BOOT_SECS:=86400}"
# Darling build directory (cmake -B)
: "${X86SIM_DARLING_BUILD:=$X86SIM_ROOT/external/darling/build}"
: "${X86SIM_DPREFIX:=${DPREFIX:-$HOME/.darling}}"   # the Darling container prefix (DPREFIX)
export X86SIM_ARCH X86SIM_ROOT X86SIM_PREFIX X86SIM_RUNTIME X86SIM_DEVICE X86SIM_STATE X86SIM_SCRATCH X86SIM_MTLVK X86SIM_MAC \
	X86SIM_SCREENS X86SIM_BOOT_SECS X86SIM_DPREFIX X86SIM_DARLING_BUILD
for _k in X86SIM_METAL MTLVK_DEVICE VK_ICD_FILENAMES MESA_VK_DEVICE_SELECT; do eval "if [ -n \"\${$_k+x}\" ]; then export $_k; fi"; done
# the chosen device's frame ring unless the caller chose one: the /dev/shm link boot-a64.sh makes for that device
# (var/device-a64 -> x86sim-a64-simfb.ring, var/device-a64-<name> -> x86sim-a64-<name>-simfb.ring, as mksimdevice.py and
# the launcher's ring_for). A fixed default made screenshot / wait / fps read the main phone's ring for every device.
if [ -z "${SIMFB_RING_LINUX+x}" ]; then
	_v=$(basename "${A64_DEVICE:-$X86SIM_DEVICE}")
	export SIMFB_RING_LINUX=/dev/shm/x86sim-${_v#device-}-simfb.ring
fi
# derived
X86SIM_DARLING="$X86SIM_PREFIX/bin/darling"
X86SIM_DVIEW=/Volumes/SystemRoot   # Linux / as seen inside Darling
mkdir -p "$X86SIM_STATE" "$X86SIM_SCRATCH" 2>/dev/null
export X86SIM_DARLING X86SIM_DVIEW
unset _k _v _cfg _x86sim_saved _x86sim_keys
# run a command as root: SUDO_PASS from the environment, else sudo's own prompt on a terminal, else only a cached
# sudo (sudo -n: an unattended empty or wrong password, repeated, trips faillock)
x86sim_sudo() {
	if [ -n "$SUDO_PASS" ]; then printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"
	elif [ -t 0 ]; then sudo "$@"
	else sudo -n "$@"; fi
}
