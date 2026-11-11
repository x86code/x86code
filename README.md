<div align="center">

# x86Sim

**Apple's iOS simulator on Linux.**

Run the real iOS 27 simulator on an ordinary x86-64 Linux PC, with GPU graphics, touch and keyboard input. No Mac
required.

[Download](https://github.com/x86sim/x86sim/releases) · [Architecture](docs/ARCHITECTURE.md) · [Developing](docs/DEVELOPMENT.md) · [Releasing](docs/RELEASE.md)

<img src="docs/screens/arm64/32-speed1c-gpu-home.png" width="220" alt="iOS 27 home screen">&nbsp;&nbsp;
<img src="docs/screens/arm64/33-speed2-settings-gpu.png" width="220" alt="iOS 27 Settings">

</div>

> [!NOTE]
> x86Sim is in early pre-release. It works, but expect rough edges.

## Features

- **Apple's unmodified iOS 27 simulator**, downloaded from Apple on your machine
- **Fast arm64 → x86-64 translation**, with an optional one-time pre-translation of iOS for quick starts
- **GPU rendering**: Metal is translated to Vulkan, including iOS 27's glass effects
- **Touch, gestures and host-keyboard input** in a native viewer window
- **Many device models**: iPhones and iPads, including dual-screen models, plus Apple TV (tvOS 27) and Apple Watch
  (watchOS 27, Digital Crown on the mouse wheel)
- **Several phones at once**, each with its own apps and data, isolated in a container
- **Lightweight**: boots in about 20 seconds; about 0.8–1.1 GB of RAM per phone

## Getting started

1. Download the latest `x86sim-*-x86_64.AppImage` from [Releases](https://github.com/x86sim/x86sim/releases).
2. Make it executable and run it:
   ```sh
   chmod +x x86sim-*-x86_64.AppImage
   ./x86sim-*-x86_64.AppImage
   ```
3. Follow the Setup page. It checks your system, prepares the simulator host, downloads iOS from Apple (about 8 GB),
   pre-translates it and creates your first phone.

No root is needed on most systems. Where unprivileged user namespaces are unavailable, setup asks for your password
once.

### Requirements

| | |
|---|---|
| **OS** | Linux x86-64; Ubuntu 24.04 or newer is tested |
| **GPU** | Vulkan with `VK_EXT_external_memory_host` (NVIDIA proprietary or AMD RADV) |
| **Disk** | about 40 GB for iOS and its pre-translated image |
| **Memory** | 8 GB or more recommended |

## How it works

Apple ships the iOS 27 simulator only for Apple-silicon Macs. x86Sim makes it run on a PC:

- **[Darling](https://github.com/darlinghq/darling)** provides the macOS-compatible system layer: processes, Mach IPC
  and the file system, extended for the iOS simulator.
- **[dynarmic](https://github.com/azahar-emu/dynarmic)** translates iOS's arm64 code to x86-64, either just in time or
  ahead of time.
- **System calls go native.** iOS reaches the kernel through a few system libraries, whose calls are handed straight
  to x86 code.
- **Graphics, input and networking** are served by small native Linux services; Metal runs on Vulkan through
  [metal2vulkan](https://github.com/x86sim/metal2vulkan).

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture and [WORKAROUNDS.md](docs/WORKAROUNDS.md) for what is
approximated.

## Building from source

```sh
git clone --recursive https://github.com/x86sim/x86sim.git
cd x86sim
```

Then follow [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Release AppImages are built by `build/release/` and GitHub
Actions.

## License

x86Sim is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). Bundled components
keep their own licenses; see [NOTICE](NOTICE).

Apple's iOS runtimes, SDKs and Xcode are not included and are never redistributed. Apple, iPhone, iPad, iOS, Xcode and
Metal are trademarks of Apple Inc. x86Sim is not affiliated with or endorsed by Apple.
