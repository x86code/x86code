# Developing x86Sim

Building from source, the repository layout and day-to-day use from the command line. For the
design, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- **Linux x86-64** with a recent kernel. Darling needs its usual setup: FUSE/overlayfs and a setuid-root `darling`
  binary.
- **A Vulkan GPU**: NVIDIA (proprietary driver) or AMD (RADV), with `VK_EXT_external_memory_host`. Development used an
  NVIDIA RTX 5090. Without a usable GPU, `X86SIM_METAL=0` falls back to software rendering.
- **Darling's build dependencies**: clang/LLVM, cmake, ninja, bison, flex, FUSE, libcap, Python 3, and the rest of
  Darling's [build list](https://docs.darlinghq.org/build-instructions.html); dynarmic also needs boost headers.
- **Rust** (stable, via rustup) for `linux/mtlvk` and metal2vulkan.
- **Python 3** with `PIL` (Pillow) and `dnspython`. The viewer needs PyGObject with GTK 4, `x86sim io recordVideo` needs
  `ffmpeg`, and `x86sim dismiss` needs `tesseract`.
- **Apple's iOS 27 simulator runtime**, not included: `runtime-fetch.py` downloads it straight from Apple's catalogue
  (no Mac, no Apple ID). It needs [`ipsw`](https://github.com/blacktop/ipsw) and 7-Zip.
- **No Mac to run it.** The simulator-side binaries in `host/` and `tests/` are committed. Rebuilding them works on
  Linux: `make sdks` sets up the SDKs without a Mac or an Apple ID (see *Simulator-side binaries*); only Metal shader
  sources and the Swift parts still need Xcode's SDK.

## Layout

```
cli/        x86sim front end; cli/libexec: the scripts it wraps (cli/libexec/arm64: boot, runtime fetch, placement,
            prefetch, shipped training); cli/lib: configuration and device types
host/       simulator-side code (Mach-O, run inside Darling): simhost (x86_64), arm64host, and arm64 builds under
            host/<name>/arm64 of simfb, simhid, simaudio, iosurfaced, metalhostd (+ vkmtl), fpsim2host, netconfig,
            openurl, simshim/{compat,diag}
linux/      native Linux pieces: arm64jit (the JIT host library), mtlvk (Rust, Metal on Vulkan), mdnsd, hostnet
tests/      sample apps (tests/apps), arm64 JIT tests (tests/arm64), Metal (mtlprobe + shaders)
            and IOSurface (iosprobe) tests, perf.py
tools/      launcher/: the launcher GUI, x86sim-aot, x86sim-mcp; debug/: core dumps, stacks, stuck processes,
            Darling install (dinstall.sh); runtime/extract-runtime.py: Apple's runtime image -> RuntimeRoot on Linux
build/      build scripts (mac-build-*.sh) for the host/ and tests/ binaries: on Linux by default (linux-env.sh), or a
            Mac; release/: the AppImage
docs/       ARCHITECTURE, WORKAROUNDS, METAL, RELEASE, protocols/, REPOS, screens/
external/   git submodules: darling, dynarmic and metal2vulkan (x86sim branches of the x86sim forks)
```

## Setup

Pre-built: the AppImage from the GitHub pre-releases sets itself up (host checks, Darling, iOS download, first
phone) from the launcher's Setup page; see [docs/RELEASE.md](RELEASE.md). From source:

1. **Clone with submodules.**
   ```sh
   git clone --recursive https://github.com/x86sim/x86sim.git && cd x86sim
   cp x86sim.env.example x86sim.env      # then edit if needed: paths, GPU settings
   ```
2. **Get the iOS 27.2 runtime** straight from Apple (about 8 GB download, ~23 GB unpacked):
   ```sh
   cli/libexec/arm64/runtime-fetch.py list            # iOS 27.x runtimes in Apple's catalogue
   cli/libexec/arm64/runtime-fetch.py fetch 24B8117   # iOS 27.2 -> runtimes/ios-27.2-24B8117-arm64/
   echo ios-27.2-24B8117-arm64 > var/device-a64/runtime
   ```
   It decrypts Apple's archive (`ipsw`), unpacks the APFS image (`7z`), and remakes every symlink 7-Zip gets wrong
   (`tools/runtime/extract-runtime.py --links`, then `--check`).
   Apple TV and Apple Watch: `runtime-fetch.py list all`, then e.g. `fetch 24K150` (tvOS 27.2, about 4 GB) or
   `fetch 24S118` (watchOS 27.2) into `runtimes/tvos-...` / `runtimes/watchos-...`, and
   `x86sim device create --model "Apple TV 4K (3rd generation) (at 1080p)" tv` or `--model "Apple Watch Series 11 (46mm)"
   watch` (the newest runtime of the model's platform). Boot one with `A64_DEVICE=var/device-a64-tv` as usual.
3. **Build and install Darling** (bin/darling must be setuid root, so this asks for sudo):
   ```sh
   make darling-install                  # configures external/darling -> $X86SIM_PREFIX, builds, installs
   ```
4. **Build the Linux pieces:**
   ```sh
   make mtlvk                            # Metal on Vulkan
   linux/arm64jit/install.sh             # the arm64 JIT, installed into Darling
   (cd tools/launcher && cargo build --release)   # launcher, x86sim-aot, x86sim-mcp
   ```
5. **Pre-translate** (optional, much faster boots and app opens):
   `tools/launcher/target/release/x86sim-aot --device $PWD/var/device-a64 build --full`, or the launcher's
   Pre-translate page.
6. **Boot:** from the launcher, or `X86SIM_METAL=all A64_KEEP=1 cli/libexec/arm64/boot-a64.sh` (see *Usage*).

Commands that need root (installing Darling, killing the setuid `darling` launcher, cores) read the password from
`SUDO_PASS` in the environment or use sudo's prompt or cache. The password is never stored in a file.

## Usage

Phones are started from the launcher, or by hand with `cli/libexec/arm64/boot-a64.sh` (`A64_DEVICE=<dir>` for another
device, `A64_KEEP=1` to keep it running, `A64_STOP_ONLY=1` to stop it). With a phone running:

```sh
x86sim view [--bg]              # GTK window: mouse = touch, keyboard input
x86sim wait home                # wait for the home screen on the framebuffer
x86sim tap X Y                  # device pixels; also: swipe, pinch, pan2, key, type "text", home, lock
x86sim openurl https://example.com
x86sim app com.apple.Preferences
x86sim install MyApp.app        # an iOS-simulator build (arm64), as xcrun simctl install: icon on the home screen
x86sim launch com.example.myapp -arg value   # as simctl launch; also: x86sim uninstall com.example.myapp
x86sim launch --console --terminate-running-process com.example.myapp   # stdout/stderr here (--console-pty: a pty)
x86sim location set 48.8584,2.2945                 # simulated location; `location start|list|run|clear`
x86sim terminate com.example.myapp
x86sim get_app_container com.example.myapp data   # app | data | groups | <group id> (Linux paths)
x86sim listapps [--json]
x86sim push com.example.myapp payload.json   # simulated remote notification
x86sim addmedia photo.jpg clip.mov           # into the Photos library
x86sim log stream --app com.example.myapp    # the app's os_log (relaunched; --match TEXT filters)
x86sim io recordVideo --secs 10 out.mp4      # also: x86sim io screenshot out.png
x86sim screenshot shot.png 3    # newest frame, scaled down 3x
x86sim logs [label] | fps 10
x86sim device models|list|create --model "iPhone 17 Pro" [name]
tests/perf.py all               # short performance run (idle CPU, launch times, frame times, touch latency)
```

Useful environment variables: `X86SIM_METAL=all|backboardd|0` (GPU for every process / backboardd only / software
rendering), `A64_JOBS=min|slim|std|full`, `A64_DROP="label ..."`, `X86SIM_NODT=all,-<label>` (os_log text for one job),
`X86SIM_INSERT=host/simshim/diag/...` (diagnostic shims, built with `make mac-diag`), `X86SIM_MDNS=0`,
`X86SIM_JETSAM=0`, `X86SIM_MEM_MAX`. Debugging: `tools/debug/` (`lastcrash.sh`, `stuck.sh <process>`, `allstacks.sh`,
`sigctx.py`).

## Simulator-side binaries

The Mach-O files in `host/` and `tests/` (`simhost`, `arm64host`, `SimFramebuffer.framework`, `SimulatorHID.framework`,
`libsimshim.dylib`, `libsimaudio.dylib`, `iosurfaced`, `metalhostd`, `fpsim2host`, `netconfig`, `openurl`, `mtlprobe`,
`iosprobe`, the probes, diagnostic shims and sample apps) are our own code and are committed, so nothing needs building
to run. To rebuild them on Linux, put the SDKs in `sdks/` (gitignored, never committed), then run the usual scripts,
e.g. `make mac` and `build/mac-build-arm64-shims.sh`: with `sdks/` present they build locally (`build/linux-env.sh`:
clang + ld64.lld, `build/linux-swiftc.sh`). `X86SIM_BUILD=mac` with `X86SIM_MAC=user@mac` builds on a Mac over ssh
instead. Two ways to fill `sdks/`:

- **`make sdks`: no Mac, no Xcode, no Apple ID.** `build/sdk/macos-sdk.py` downloads `MacOSX.sdk` from Apple's public
  software-update CDN (the Command Line Tools SDK package `xcode-select --install` fetches; about 70 MB).
  `build/sdk/sim-sdk.py` then assembles a substitute `iPhoneSimulator.sdk`: link stubs (`.tbd`) generated from the
  `dyld_sim_shared_cache` of a runtime in `runtimes/` (which `runtime-fetch.py` downloads), plus the macOS SDK's headers,
  which are the same for everything our C and Objective-C code includes (where iOS differs, a patched copy or a minimal
  header of our own). Against the 27.2 runtime and macOS 27.2 SDK it rebuilds every C / Objective-C binary in `host/`
  and `tests/` byte-identically to Xcode's SDK (apart from clang's random temp-object names). Not covered: Swift and
  UIKit (`tests/arm64/objcswift`, `sleepprobe`, `tests/apps`), which need Xcode's own SDK. Using these files means
  accepting Apple's SDK agreement.
- **From Xcode:** copy `iPhoneSimulator.sdk` and `MacOSX.sdk` from Xcode, plus `swift-6.4.2/` from swift.org and
  `swift-lib/` from Xcode's toolchain for the Swift parts.

tvOS and watchOS builds of the same binaries (`host/<name>/arm64-tvos`, `arm64-watchos`) take
`X86SIM_PLATFORM=tvos|watchos build/mac-build-arm64-shims.sh ...` and their own SDK in `sdks/`: `AppleTVSimulator.sdk`
and `WatchSimulator.sdk`, from Xcode or made by `build/sdk/sim-sdk.py --runtime runtimes/<tvos-|watchos-...>` like
the iOS one. Xcode's WatchSimulator.sdk has no IOKit, IOSurface, Metal or SystemConfiguration (private on watchOS),
which our binaries need: use the substitute for watchOS.

`cargo install apple-codesign` for signing either way. Metal shader sources are the exception: `build/linux-metal.sh`
serves recorded Mac-built libraries (`build/metal-cache`) and a changed shader still needs a Mac.

A committed binary can be checked against its source this way too: rebuild it and compare (the only differences
should be the LC_UUID, the code signature and clang's temp-object names in the debug map).

## Shipped pre-translate training

`cli/libexec/arm64/training-<build>.x86t` holds the code blocks each program ran (addresses and how many programs ran
them; no code or content) on the machine that made the release. The planner counts it with the install's own profiles,
so a new install's first image already holds what apps run. Refresh it after using the system apps on a dev build,
adding to what it holds (`--merge`: a block keeps the higher program count) and any other cache dirs (an AppImage
install's `~/.cache/x86sim/jc-<build>`; each dir adds every program's newest profile, a program's blocks counted once):

    T=cli/libexec/arm64/training-24B8117.x86t
    tools/launcher/target/release/x86sim-aot --jc ~/scratch/x86sim/jc-24B8117 export-training \
        --out $T --merge $T ~/.cache/x86sim/jc-24B8117
