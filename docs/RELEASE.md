# x86Sim releases: one AppImage, set up by the launcher

Goal: download one file, run it, and get a booted phone with as little work as possible. GitHub CI builds it.
Full releases are tagged `v<version>` (first: `v0.1.0`, 2026-11-11); pre-releases `v<version>-pre<N>`.

Status (2026-11-08): the build, the AppImage, the setup wizard (GUI + `x86sim-aot setup` CLI), the no-root "userns"
mode and the CI workflows are written. Tested locally: the Ubuntu 24.04 build (docker, the same script CI runs), the
AppImage in fresh data/cache dirs (`XDG_DATA_HOME`/`XDG_CACHE_HOME`), host checks, catalogue + resumable download
from Apple, linking an existing runtime, and **a phone booted to the home screen from the AppImage's Darling without
root** (userns mode). Not tested yet: the root install (`pkexec`, no password here), the GUI wizard on screen, CI on
GitHub's runners, other distros.

## 1. What a fresh machine needs today (developer setup)

| Step | What | Root? | Machine-specific? |
|---|---|---|---|
| Packages | clang/LLVM (recent: our Darling fork builds with clang 23; `-fno-objc-constant-literals`), cmake, ninja, bison, flex, FUSE, libcap, Darling's `-dev` list, boost headers, Rust stable, Python 3 (+dnspython), curl, openssl | yes (package manager) | distro names differ |
| Darling | `make darling-install`: ~26k ninja targets, installed to `darling-prefix/`, then `bin/darling` chowned root + setuid (`tools/debug/dinstall.sh`) | **yes**: setuid root | the install prefix is **compiled into** the binaries (`darling` execs `$PREFIX/bin/darlingserver`, darlingserver overlays `$PREFIX/libexec/darling`, mldr loads `$PREFIX/libexec/usr/lib/dyld`) |
| arm64jit | `linux/arm64jit/install.sh`: libarm64jit.so, a64hugecopy and host/arm64host (built with Darling's in-tree ld64 and Darling's own SDK) copied into the prefix | no | no |
| mtlvk | `make mtlvk` (Rust, Vulkan through the loader) | no | needs the user's Vulkan driver at run time |
| Launcher | `cargo build --release` in tools/launcher (launcher, x86sim-aot, x86sim-mcp) | no | no |
| iOS runtime | `runtime-fetch.py fetch 24B8117`: Apple catalogue + gdmf, 8 GB download (curl, resumable), `ipsw fw aea` decrypt, aaextract.py, `7z x -snld`, symlink repair (extract-runtime.py). ~45 GB free during, ~27 GB after | no | Apple content: per machine, never redistributed |
| macOS host data | `fetch-macos-host.sh`: GeoServicesData from a **Mac** (Maps tiles) | no | Apple content, needs a Mac: **not in the release** (Maps shows no tiles; boot-a64 prints a note) |
| AOT image | x86sim-aot / Pre-translate page: built from the runtime, keyed by the translator's codegen version (read from libarm64jit.so's `g_build`, core/src/key.rs) | no | derived from Apple's code: local only |
| First phone | `device-a64.py create` / launcher "Add phone"; a fresh phone's first boot can stall once (the launcher restarts it automatically) | no | |
| Kernel | overlayfs (Darling's container), 6.11+ for PROCMAP_QUERY (faster darlingserver; older kernels fall back), no binfmt, no kernel module, no ptrace needs for normal use | - | |
| GPU | Vulkan driver (NVIDIA proprietary, Mesa RADV/ANV) + loader; without one, software rendering | - | yes |

## 2. What goes where

**Inside the AppImage** (161 MB, zstd; nothing from Apple):

```
AppRun                         entry (build/release/AppRun)
usr/share/x86sim/
  VERSION, DARLING_ID          version; content hash of the Darling tree (a new AppImage reinstalls Darling only if it changed)
  payload/                     `git ls-files` of cli host linux tools/debug tools/runtime tests + build outputs at their
                               repo paths (linux/mtlvk/target/release/mtlvk, tools/launcher/target/release/*) — 57 MB
  darling/                     Darling installed with prefix /opt/x86sim/darling (DESTDIR), + libarm64jit.so,
                               a64hugecopy, arm64host — 543 MB unpacked
  bin/ipsw (MIT), bin/7zz + 7z (7-Zip, LGPL-2.1 + unRAR), pylib/dns (dnspython, ISC)
  install-helper.sh            the privileged step (system mode)
  darling-userns.sh            the no-root Darling wrapper (userns mode)
  licenses/                    Darling (GPL-3 / APSL parts), dynarmic (0BSD), metal2vulkan (GPL-2+/LGPL-3+), astcenc (Apache-2)
```

The committed simulator-side binaries in `host/` (simfb, simhid, simshim, simaudio frameworks/dylibs) are **ours**,
built from `host/` sources with `build/mac-build-*.sh`; they link against Apple's SDK stubs but contain no Apple code.
CI has no Apple SDK and needs none (it never rebuilds them). `appimage.sh` refuses to pack if it finds a dyld shared
cache, a `.simruntime`, an SDK, GeoServicesData, a RuntimeRoot or a CoreSimulator Profiles tree.

**Fetched or built on the user's machine, never shipped:** the iOS runtime (straight from Apple's CDN with the same
request Xcode makes; each user downloads their own copy), the Metal binary extracted from it (ensure-metal-framework.sh),
AOT images and JIT caches (derived from Apple's code), GeoServicesData (needs a Mac; optional).

**On disk after setup** (the AppImage mount is read-only and lives only while the AppImage runs, but phones outlive the
launcher, so AppRun copies the payload out once per version):

```
~/.local/share/x86sim/        X86SIM_ROOT, shaped like the checkout so every script and the launcher work unchanged
  app/<version>/               payload copy (+ darling/ in userns mode); the newest two versions are kept
  cli host linux tools tests   -> app/<version>/...      (relative links: Darling resolves them under /Volumes/SystemRoot)
  darling-prefix               -> /opt/x86sim/darling (system mode) or app/<version>/darling-userns (userns mode)
  runtimes/ var/ setup.json    user data, kept across versions
~/.cache/x86sim/              X86SIM_SCRATCH: per-phone Darling prefixes, jc-<build> (AOT + JIT cache), logs
/opt/x86sim/                  system mode only: darling-<id>/ (root-owned, bin/darling setuid), darling -> darling-<id>
```

AppRun sets `X86SIM_ROOT`, `X86SIM_SCRATCH`, `PATH` (bundled ipsw/7z), `X86SIM_PYLIB`, `A64_PREFIX_HEAL=0` (no
Darling build tree to heal from). Subcommands: `x86sim.AppImage [launcher|aot|mcp|x86sim|shell|version]`.
In the checkout nothing changes: `repo_root()` is still the repo, `setup::needed()` is false, the Setup page only checks.

## 3. Root: two modes

Darling's `bin/darling` must be setuid root and its prefix is fixed; an AppImage can carry neither.

- **userns (no root, default when available).** `darling-userns.sh` keeps one "holder" process per Darling build that
  owns an unprivileged user namespace + mount namespace with the Darling tree bind-mounted at `/opt/x86sim/darling`;
  every `darling` command joins it with `nsenter --preserve-credentials -U -m`. Inside, the user is uid 0 and Darling
  starts as usual (overlay mounts are allowed in a user namespace since Linux 5.11). Tested: a phone (iPhone 17,
  iOS 27.2) booted to the home screen, GPU rendering, from a fresh data dir (first boot stalled once as usual, the
  second reached home). Differences seen so far: launchd's domain is `user/0` instead of `user/<uid>`; darlingserver
  can't raise its FD limit above the hard limit or renice itself to -10 (warnings). Inside the namespace `/opt` shows
  only `x86sim/` (the host's other `/opt` entries are hidden from Darling, not from Linux).
  **Not available** where unprivileged user namespaces are blocked: Ubuntu 23.10+ (AppArmor
  `kernel.apparmor_restrict_unprivileged_userns=1`), hardened kernels, some containers. AppRun probes `unshare -r -m true`.
- **system (one password prompt).** The wizard copies `usr/share/x86sim/darling` out of the mount (root can't read a
  user's FUSE mount) to the cache, then `pkexec sh install-helper.sh install <dir> <id>`: copy to
  `/opt/x86sim/darling-<id>`, `chown -R root:root`, `chmod 4755 bin/darling`, atomically switch the
  `/opt/x86sim/darling` link (running phones keep their tree), keep the previous tree. `install-helper.sh uninstall`
  removes `/opt/x86sim`. Without pkexec the page shows the `sudo` command. Used automatically when that exact Darling
  build is already installed there; force either with `X86SIM_DARLING_MODE=system|userns`.

Note: the staged copy and the helper script live in the user's own dirs, so whoever runs as the user could tamper
with them between copy and `pkexec`; the password prompt is the user's own, so this gives nothing beyond what the user
already has. A stricter variant would have the helper read the AppImage file itself (`$APPIMAGE --appimage-extract`
as root) and check `DARLING_ID`.

## 4. First run (the launcher's Setup page)

From the AppImage the launcher opens on **Setup** until it was finished once (or while Darling / iOS are missing);
it stays in the sidebar afterwards. The same steps from a terminal: `x86sim.AppImage aot setup check|install-darling|link-runtime DIR|done`.

1. **This computer**: CPU (x86-64 with SSE4.1/POPCNT/CX16), kernel (overlayfs; 6.11+ noted), memory (16 GB
   recommended, 8 minimum), disk (45 GB free for a download, 10 GB with a runtime), Vulkan (loader, a driver JSON,
   a GPU node; else a warning: software rendering), programs (python3, curl, openssl, setsid, systemd-run, ipsw, 7z),
   dnspython.
2. **Darling**: ready (userns) or Install/Update (system, one password).
3. **Get iOS**: Download iOS 27.2 (the existing fetch with progress, Cancel, Resume — curl `-C -`, tested), or
   "use this folder" to link a runtime already on disk (a checkout's `runtimes/ios-27.2-24B8117-arm64`; relative link).
4. **Pre-translate** (optional): opens the existing Pre-translate page.
5. **First phone**: the existing Add phone dialog; then Done.

## 5. Updates and versioning

- The AppImage carries update information `gh-releases-zsync|x86sim|x86sim|latest-pre|x86sim-*-x86_64.AppImage.zsync`
  and CI publishes the `.zsync`, so AppImageUpdate / AppImageLauncher can delta-update. (Needs a public repo, see §8.)
- A new version gets its own `app/<version>` copy; user data (`runtimes/`, `var/`, caches) is untouched. Darling is
  reinstalled (system mode: one prompt) only when `DARLING_ID` changes.
- AOT images are already invalidated by the translator's codegen version (key.rs reads it from the installed
  libarm64jit.so; `strip --strip-debug` keeps the symbol). Data-format migrations, when needed, go in AppRun keyed on
  `setup.json`'s `done_version`.

## 6. Build and CI

- `build/release/deps-ubuntu.sh`: packages on Ubuntu 24.04 + clang 23 from apt.llvm.org (+ `/usr/include/asm` link:
  Darling's fseventsd includes `<linux/types.h>` without Debian's multiarch dir).
- `build/release/build.sh`: Darling (prefix `/opt/x86sim/darling`, `DESTDIR`), arm64jit, arm64host, mtlvk, launcher;
  reads the checkout only, writes `build/release/out` (gitignored). `CCACHE=1` uses ccache.
- `build/release/appimage.sh`: payload, Darling tree, pinned tools (sha256 checked), licenses, Apple-content check,
  appimagetool (continuous; prints its hash) → `x86sim-<version>-x86_64.AppImage` + `.zsync` + `SHA256SUMS`.
- `build/release/docker-build.sh`: the same in an `ubuntu:24.04` container with the checkout mounted read-only (local
  check of the CI build).
- `.github/workflows/build.yml` (reusable): free disk, shallow recursive submodules with SSH URLs rewritten to HTTPS
  (the forks are public), packages, ccache + cargo caches, build, AppImage, artifact. `ci.yml`: every push to main / PR.
  `release.yml`: tag `v<version>` → GitHub release (marked latest), `v<version>-pre<N>` → pre-release (or a manual
  run naming a tag); each with AppImage, zsync, SHA256SUMS.

Measured locally (Ryzen 7 9800X3D, `-j8`, a phone running alongside): Darling 26k targets ≈ 8.5 min wall, 50 CPU-min
summed over jobs; arm64jit + arm64host < 1 min; mtlvk ≈ 1.5 min; launcher < 30 s; packing ≈ 1 min. Estimate on a
4-vCPU GitHub runner: 30–60 min cold, much less with ccache — well inside the 6 h limit. Disk: Darling build tree
1.7 GB, destdir 0.55 GB, cargo targets 2.2 GB, shallow submodules a few GB: fits the ~14 GB free (+~25 GB after the
cleanup step).

Found and fixed for the Ubuntu toolchain: darlingserver used `PROCMAP_QUERY` from Linux 6.11 headers (Ubuntu 24.04
has 6.8): the definitions are now provided when missing (stable ABI; old kernels answer ENOTTY and the maps parser runs).

**glibc floor:** built on 24.04: glibc 2.38/2.39 symbols, libstdc++ GLIBCXX_3.4.30. Runs on Ubuntu 24.04+, Debian 13,
Fedora 39+, Arch/derivatives; not Ubuntu 22.04 / Debian 12. Mac-side bits are Mach-O and don't care.

## 7. Licensing of what is bundled

Darling: GPL-3.0 with APSL-2.0 / BSD parts (Apple's open-source releases) — source is our public fork; the release
notes should point at the exact submodule commits (GPL offer). dynarmic 0BSD, metal2vulkan GPL-2.0+/LGPL-3.0+ (dual),
astc-encoder Apache-2.0, lzfse BSD-3, ipsw MIT, 7-Zip LGPL-2.1 + unRAR restriction (redistribution fine), dnspython ISC.
Our own code: GPL-3.0-or-later (LICENSE); bundled components and their licenses in NOTICE.

## 8. Decisions (2026-11-08)

1. **Repo visibility: private for now.** Pre-releases are visible to org members only, so AppImageUpdate/zsync does
   not work for anyone else yet. Revisit (public repo or a public releases-only repo) before the first public release.
2. **License: GPL-3.0-or-later** for our own code (LICENSE), components listed in NOTICE; both ship in the AppImage.
3. **Root mode: userns (no root) by default, `pkexec` system install as the fallback**, as implemented.
4. **Distro floor: Ubuntu 24.04+** (glibc 2.39): also Debian 13, Fedora 39+, Arch.
5. **Pre-translate: on by default.** The setup page starts it on its own once iOS and Darling are ready
   (`Setup::aot_auto`); phones work while it runs.
6. **First tag**: `v0.1.0-pre1`; first full release `v0.1.0`.
7. **Pushing**: the gh token has `workflow` scope; push innermost first (darlingserver, darling, then this repo).
