<div align="center">

# x86Sim

**Apple's iOS, tvOS and watchOS simulators, running on Linux.**

Run the real iPhone, iPad, Apple TV and Apple Watch simulators on an ordinary x86-64 Linux PC, with GPU graphics,
touch and keyboard input. No Mac required.

[![Latest release](https://img.shields.io/github/v/release/x86sim/x86sim?label=release)](https://github.com/x86sim/x86sim/releases/latest)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

[Download](https://github.com/x86sim/x86sim/releases/latest) · [Quick start](#quick-start) · [Architecture](docs/ARCHITECTURE.md) · [Developing](docs/DEVELOPMENT.md)

<img src="docs/screens/launcher-devices.webp" alt="The x86Sim launcher with an Apple TV, an Apple Watch, an iPhone Duo and an iPhone 17 all running" width="100%">

</div>

## What it does

Apple ships its simulators only for Apple-silicon Macs. x86Sim runs those same simulator runtimes, unmodified, on
Linux: it downloads them from Apple onto your machine, translates their arm64 code to x86-64, and draws their Metal
graphics with Vulkan. You get a launcher where each device is a card with a live screen, and you can run several at
once.

v0.1.0 is the first full release. It is young software: it works, and you should still expect rough edges.

## Quick start

1. Download `x86sim-*-x86_64.AppImage` from the [latest release](https://github.com/x86sim/x86sim/releases/latest).
2. Make it executable and run it:
   ```sh
   chmod +x x86sim-*-x86_64.AppImage
   ./x86sim-*-x86_64.AppImage
   ```
3. Follow the **Setup** page. It checks your computer, prepares the simulator host, downloads iOS 27.2 from Apple
   (about 8 GB), pre-translates it and creates your first phone.

No root is needed where unprivileged user namespaces are available. Where they are not (Ubuntu's default, for
example), Setup asks for your password once.

To add an Apple TV or an Apple Watch, get tvOS 27.2 or watchOS 27.2 on the **Versions** page, then choose
**Add device**.

### Requirements

| | |
|---|---|
| **OS** | x86-64 Linux with glibc 2.39 or newer: Ubuntu 24.04+, Debian 13, Fedora 39+, Arch and derivatives |
| **CPU** | x86-64 with SSE4.1, POPCNT and CX16 |
| **GPU** | A Vulkan GPU and driver: NVIDIA (proprietary driver) or Mesa (RADV, ANV). Without one, rendering falls back to software |
| **Memory** | 8 GB minimum, 16 GB recommended |
| **Disk** | 45 GB free while iOS downloads and unpacks |
| **Kernel** | overlayfs; Linux 6.11 or newer is a little faster |

Setup also looks for a few common programs (`python3`, `curl`, `openssl`, `systemd-run`) and tells you if one is
missing. Everything else comes inside the AppImage.

## Supported devices

| Device | System | Input |
|---|---|---|
| **iPhone** and **iPad**, including the dual-screen iPhone Duo | iOS 27 | Touch and gestures with the mouse, your keyboard |
| **Apple TV** | tvOS 27 | An on-screen Siri Remote, or arrows, Return and Escape |
| **Apple Watch** | watchOS 27 | Touch, a Digital Crown you can drag or scroll, and the side button |

There are 80 device models to choose from. Pairing a watch with a phone is not supported yet.

<table>
<tr>
<td width="50%"><img src="docs/screens/launcher-iphone.webp" alt="An iPhone 17 showing Settings, next to its memory, CPU and per-process figures"></td>
<td width="50%"><img src="docs/screens/launcher-apple-tv.webp" alt="An Apple TV showing tvOS Settings, with the Siri Remote beside it"></td>
</tr>
<tr>
<td align="center"><sub>An iPhone, with its memory, CPU and processes</sub></td>
<td align="center"><sub>An Apple TV and its Siri Remote</sub></td>
</tr>
<tr>
<td width="50%"><img src="docs/screens/launcher-apple-watch.webp" alt="An Apple Watch showing its app grid, with the Digital Crown and side button on its edge"></td>
<td width="50%"><img src="docs/screens/launcher-versions.webp" alt="The Versions page listing installed iOS, tvOS and watchOS versions and those available from Apple"></td>
</tr>
<tr>
<td align="center"><sub>An Apple Watch, with its Digital Crown and side button</sub></td>
<td align="center"><sub>Versions, downloaded straight from Apple</sub></td>
</tr>
</table>

## Features

- **Apple's own simulators, unmodified.** Each runtime is downloaded from Apple on your machine and is never
  redistributed.
- **Fast arm64 to x86-64 translation.** Code is translated just in time, and a one-time pre-translation makes boots
  and app launches quick.
- **GPU rendering.** Metal is translated to Vulkan, including iOS 27's glass effects.
- **Several devices at once.** Each has its own apps, data and settings, isolated in its own container.
- **Memory you can trust.** Every device shows its own memory, CPU and processes. The GPU helper that running devices
  share is shown separately and counted once.
- **Your own apps.** Install and launch arm64 iOS-simulator builds, the kind Xcode produces for the simulator.
- **Developer tools.** A `simctl`-style command line covers install, launch, push notifications, simulated location,
  adding photos, logs, screenshots and video recording. An MCP server (`x86sim-mcp`) drives devices from other tools.
- **Per-device features.** Turn off parts of iOS you don't need on a device, such as Siri, Maps or Wallet, to save
  memory.
- **Updates built in.** The AppImage checks for new releases, downloads them in the background and offers a restart.

### New in v0.1.0

- **Apple TV and Apple Watch**, each with pre-translation included. The Apple TV has a Siri Remote with a clickpad,
  Back, TV, play/pause, mute and volume. The Apple Watch has its Digital Crown and side button on the edge of the
  watch, as on a real one.
- **Honest memory accounting.** The shared GPU helper used to be added to whichever device started it. It is now
  counted once.
- **A cleaner launcher.** "Phones" is now "Devices", repeated information is gone, every button has a tooltip, and
  the common actions have keyboard shortcuts.

The [release notes](https://github.com/x86sim/x86sim/releases/latest) have the full list, with the fixes.

### Known limits

- Maps shows no map tiles: the map data comes from a Mac and is not part of the release.
- Audio is off by default.
- An Apple Watch cannot be paired with a phone yet.

[WORKAROUNDS.md](docs/WORKAROUNDS.md) lists what is approximated.

## How it works

- **[Darling](https://github.com/darlinghq/darling)** provides the macOS-compatible system layer: the Mach-O loader,
  processes, Mach IPC and the file system, extended for the simulators.
- **[dynarmic](https://github.com/azahar-emu/dynarmic)** translates the simulators' arm64 code to x86-64, either just
  in time or ahead of time into a pre-translated image.
- **System calls go native.** The simulator reaches the kernel through a few system libraries, and those stay native
  x86 code.
- **Graphics, input and networking** are served by small native Linux services. Metal runs on Vulkan through
  [metal2vulkan](https://github.com/x86sim/metal2vulkan).

[ARCHITECTURE.md](docs/ARCHITECTURE.md) has the full picture.

## Building from source

```sh
git clone --recursive https://github.com/x86sim/x86sim.git
cd x86sim
cp x86sim.env.example x86sim.env

make darling-install                             # Darling; asks for sudo (bin/darling is setuid root)
make mtlvk                                       # Metal on Vulkan
linux/arm64jit/install.sh                        # the arm64 translator, installed into Darling
(cd tools/launcher && cargo build --release)     # launcher, x86sim-aot, x86sim-mcp
```

[DEVELOPMENT.md](docs/DEVELOPMENT.md) covers the build dependencies, fetching the runtimes and using the command
line. Release AppImages are built by `build/release/` and GitHub Actions; see [RELEASE.md](docs/RELEASE.md).

## License and credits

x86Sim is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). Bundled components
keep their own licenses; see [NOTICE](NOTICE).

x86Sim stands on the work of others: [Darling](https://github.com/darlinghq/darling),
[dynarmic](https://github.com/azahar-emu/dynarmic), [metal2vulkan](https://github.com/x86sim/metal2vulkan),
[ipsw](https://github.com/blacktop/ipsw), [7-Zip](https://www.7-zip.org),
[dnspython](https://github.com/rthalley/dnspython), astcenc and lzfse. Thank you to everyone who has tested
pre-releases and sent fixes.

Apple's simulator runtimes, SDKs and Xcode are not included and are never redistributed. Apple, iPhone, iPad, iOS,
Xcode and Metal are trademarks of Apple Inc. x86Sim is not affiliated with or endorsed by Apple.
