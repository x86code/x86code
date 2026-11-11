#!/bin/sh
# x86Sim release build: packages for building Darling + our Linux pieces on Ubuntu 24.04 (the CI runner and the local
# docker check in build/release/README in docs/RELEASE.md). Run as root (CI: sudo). LLVM_VERSION picks clang from
# apt.llvm.org (our Darling fork is developed with clang 23; -fno-objc-constant-literals needs a recent clang).
set -e
LLVM_VERSION=${LLVM_VERSION:-23}
export DEBIAN_FRONTEND=noninteractive
# a stalled mirror (GitHub's runners fetch through a mirror list; on 2026-11-11 one stopped answering mid-download and
# apt-get waited for 20+ minutes) times out after 30 s and is retried / the next mirror is tried, instead of hanging
cat > /etc/apt/apt.conf.d/80x86sim-retries <<'APT'
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
APT
# 2026-11-11 the runners' resolver (Azure DNS, via systemd-resolved) stopped answering for the Ubuntu archives while
# other names resolved: then use public resolvers as well
if ! getent hosts archive.ubuntu.com >/dev/null && [ -d /run/systemd/resolve ]; then
	echo "deps: archive.ubuntu.com does not resolve; adding public DNS servers"
	mkdir -p /etc/systemd/resolved.conf.d
	printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=1.0.0.1 8.8.4.4\n' > /etc/systemd/resolved.conf.d/80-x86sim.conf
	systemctl restart systemd-resolved
	for i in 1 2 3 4 5; do getent hosts archive.ubuntu.com >/dev/null && break; sleep 2; done
	getent hosts archive.ubuntu.com || echo "deps: archive.ubuntu.com still does not resolve"
fi
# GitHub's runners fetch Ubuntu through azure.archive.ubuntu.com (mirror list /etc/apt/apt-mirrors.txt); when it does
# not answer (2026-11-11: every request timed out for an hour), use Ubuntu's own archive
if [ -f /etc/apt/apt-mirrors.txt ] && ! curl -fsS --max-time 15 -o /dev/null http://azure.archive.ubuntu.com/ubuntu/dists/noble/InRelease; then
	echo "deps: azure.archive.ubuntu.com not answering; using archive.ubuntu.com"
	printf 'http://archive.ubuntu.com/ubuntu/\tpriority:1\n' > /etc/apt/apt-mirrors.txt
fi
apt-get update -q
# Darling's own list (external/darling/debian/control), minus i386 (TARGET_i386=OFF), plus what our pieces and the
# AppImage need (boost for dynarmic, squashfs/zsync for packing, file/desktop-file-utils for appimagetool's checks)
apt-get install -y -q --no-install-recommends \
	ca-certificates curl wget gnupg lsb-release software-properties-common git cmake ninja-build bison flex pkg-config python3 \
	libfuse-dev libudev-dev libcairo2-dev libgl1-mesa-dev libglu1-mesa-dev libtiff5-dev libfreetype-dev libelf-dev \
	libxml2-dev libegl1-mesa-dev libfontconfig1-dev libbsd-dev libxrandr-dev libxcursor-dev libgif-dev libavutil-dev \
	libpulse-dev libavformat-dev libavcodec-dev libswresample-dev libdbus-1-dev libxkbfile-dev libssl-dev libcap-dev \
	libcap2-bin libvulkan-dev libboost-dev xz-utils file desktop-file-utils squashfs-tools zsync patchelf build-essential ccache
if ! command -v clang-$LLVM_VERSION >/dev/null; then
	curl -fsSL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh
	bash /tmp/llvm.sh "$LLVM_VERSION"
	apt-get install -y -q --no-install-recommends lld-$LLVM_VERSION llvm-$LLVM_VERSION-dev libclang-$LLVM_VERSION-dev
fi
for t in clang clang++ ld.lld ld64.lld llvm-ar llvm-nm llvm-ranlib llvm-strip llvm-objcopy llvm-config lld; do
	[ -x /usr/bin/$t-$LLVM_VERSION ] && ln -sfn /usr/bin/$t-$LLVM_VERSION /usr/local/bin/$t
done
clang --version | head -1
# Darling's fseventsd (fanotify) includes <linux/types.h> with Darling's include path, which misses Debian's multiarch
# asm/ dir (Arch and Fedora have /usr/include/asm)
[ -e /usr/include/asm ] || ln -s x86_64-linux-gnu/asm /usr/include/asm
