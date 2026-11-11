# Architecture

x86Sim runs Apple's **iOS 27 arm64 simulator runtime** (default: iOS 27.2, 24B8117) on x86-64 Linux. The runtime's
binaries are unchanged. They run under **Darling** (a Darwin compatibility layer: Mach-O loader + XNU syscall/Mach
emulation + `darlingserver`), and their arm64 code is translated to x86-64 by **libarm64jit** (`linux/arm64jit`, built
on dynarmic), just in time or from a pre-translated (AOT) image. Everything CoreSimulator and the Mac host would provide
around the runtime (the launchd handshake, the display, touch input, GPU, cross-process surfaces, DNS, network state,
host file services) is replaced by small programs in this repo: some run **inside Darling** as simulator binaries
(`host/`, arm64 builds under `host/<name>/arm64`), some run **natively on Linux** (`linux/`, `cli/libexec`). Phones are
started by the launcher (`tools/launcher`) through `cli/libexec/arm64/boot-a64.sh`.

```
 Linux host                                             Darling container (one prefix per phone)
 ---------------------------------------------          -------------------------------------------------------------
 launcher (tools/launcher) / x86sim-aot                 darling shell -> simhost (host/simhost, x86_64)
   boot-a64.sh: mksimdevice.py, mtlvk, mdnsresponder,       -> launchd_sim (runtime)  [device: <device>/data]
                simaudio.py, jetsam.py                         -> the runtime's daemons and agents (backboardd, SpringBoard,
   limited.sh scope -> boot-inner.sh -> darling shell             cfprefsd, lsd, runningboardd, ..., apps)
                                                               -> our jobs: metalhostd, iosurfaced, netconfig,
                                                                  fpsim2host, openurl
                                                        every arm64 process: mldr -> arm64host -> libarm64jit.so (ELF)
                                                                             DYLD_INSERT libsimshim (host/simshim/arm64)

 mtlvk (linux/mtlvk, Vulkan)   <== Unix socket + memfds ==  metalhostd (MTLSimImplementation on vkmtl)
 mdnsresponder.py (linux/mdnsd) <== dnssd_ipc socket ======  libsystem_dnssd in every process
 hostnet.py (linux/hostnet) --plist--> netconfig -> host-configd store -> configd_sim's SimulatorSupport
 simview.py / fb2png.py  <== frame ring ===============    SimFramebuffer.framework (host/simfb) in backboardd
 simview.py / simtouch.py  == simhid.sock ==>                 SimulatorHID.framework (host/simhid) in backboardd
 simaudio.py (PipeWire)    <== simaudio.sock ==             libsimaudio (host/simaudio, opt-in) in each process
 darlingserver (Darling, Linux process): Mach IPC, threads, VM, memfd-backed shared memory for every container process
```

## Darling (external/darling, branch x86sim)

Darling provides the Mach-O loader (`mldr`), the XNU syscall and Mach trap emulation (`libsystem_kernel`, in
`darling-xnu`), the Mach IPC/task/thread server (`darlingserver`), `dyld` for the host side and `iokitd`. The iOS
simulator runtime is far more demanding than the macOS userland Darling targets: workloops, cooperative thread pools
(Swift concurrency), ulock, Mach memory entries, guarded fds, getattrlist/fsctl/chflags, PF_ROUTE, csops and more.
All changes are on the `x86sim` branches of our forks ([REPOS.md](REPOS.md)), each marked `x86Sim:` in the source.

Inside Darling the Linux root is `/Volumes/SystemRoot`; the scripts translate paths (`mksimdevice.py darling()`).
Each phone has its own Darling prefix (`A64_DPREFIX`, default `$X86SIM_SCRATCH/a64prefix`); stopping a phone stops only
that prefix's container.

## arm64 code: arm64host and libarm64jit

When `mldr` is asked to run an arm64-only Mach-O, it re-executes itself on `arm64host` (`host/arm64host`, an x86_64
macOS program installed next to mldr) with `X86SIM_A64_EXE` naming the arm64 program, and renames `DYLD_*` to
`X86SIM_A64_DYLD_*`. arm64host starts like any Darling process (native libSystem, TSD, darlingserver), loads the ELF
library `libarm64jit.so` through Darling's elfcalls and hands over: dynarmic runs the arm64 `dyld_sim` and the program,
while `libsystem_kernel`/`platform`/`pthread` stay the process's native x86 libraries.

Inside libarm64jit (`linux/arm64jit`):

- `jit.cpp`: each native thread running guest code has its own dynarmic Jit and an 8 MB guest stack; translated code
  is shared by all threads of the process. Native code can call back into guest code (nested `Jit::Run`).
- `boundary.cpp`: the `svc` boundary. Guest calls into native Darwin functions go through numbered `svc` thunks that
  move arguments between the arm64 and System V conventions; `guest_callable()` gives native code a trampoline into a
  guest function.
- `objc.cpp`: an inline x86 `objc_msgSend` cache probe emitted when `_objc_msgSend` is translated.
- `dyldsim.cpp`: native shortcuts applied to `dyld_sim` before it runs (`X86SIM_A64_DYLD_NATIVE=0` turns them off).
- `jitcache.cpp`: the persistent translation cache in `X86SIM_A64_JITCACHE_DIR` (default `$X86SIM_SCRATCH/jitcache`;
  runtimes other than 27.0 use `$X86SIM_SCRATCH/jc-<build>`), keyed by the dyld cache UUID and a build id that includes
  the codegen version and the placement table's hash. Per-process `.bin` files record what each program ran; the
  `.aot` image holds pre-translated code and is loaded at process start (`X86SIM_A64_AOT=0` disables it).

Non-cache Mach-Os (runtime binaries, apps) get fixed addresses from a placement table
(`cli/libexec/arm64/placement-<build>.txt`, `mkplacement.py`), copied into the cache dir; the AOT image must be built
with the same table.

### Pre-translation (tools/launcher x86sim-aot)

`tools/launcher/core/src/aot.rs` builds the AOT image in chunks: one per dyld-cache dylib, placed runtime Mach-O or
placed app executable. Each chunk is translated by libarm64jit's builder into its own slot of the code slab (translated
code is position dependent, so a slot is fixed once assigned and a rebuilt chunk returns to it); the image
(`<uuid>-<build>.aot`) is assembled from the chunk files. Layout under the cache dir: `placement.txt`,
`aot/config.json`, `aot/manifest.json`, `aot/chunks/`, `aot/progress.json`. What goes in is chosen from training
profiles: the install's own `.bin` files and the shipped `cli/libexec/arm64/training-<build>.x86t`. 90 s after a boot,
`boot-a64.sh` runs `x86sim-aot status` and notes in `$ST/aot-status.txt` how many chunks need rebuilding
(`X86SIM_AOT_AUTOUPDATE=1` rebuilds them right away).

## Booting: boot-a64.sh, simhost and launchd_sim

`cli/libexec/arm64/boot-a64.sh` boots one device (`A64_DEVICE`, default `var/device-a64`; its iOS version is
`<device>/runtime`, `A64_RUNTIME` overrides). It:

1. starts this boot's mtlvk when `X86SIM_METAL` is not `0` (own socket and pidfile in the state dir), or shares a
   running one (`A64_MTLVK_SOCKET`); an mtlvk other phones render through is never stopped;
2. picks the job list (`A64_JOBS=min|slim|std|full`, default `std`; each job's reason is in a comment), applies the
   device's feature toggles (`<device>/features.json`, definitions in `cli/libexec/arm64/features-def.json`) and
   `A64_DROP`, and runs `cli/libexec/mksimdevice.py`;
3. stops this prefix's previous container (its own processes only, found by exact checks), then starts
   `linux/mdnsd/mdnsresponder.py`, `cli/libexec/jetsam.py` and, with `X86SIM_AUDIO=1`, `cli/libexec/simaudio.py`;
4. runs `cli/libexec/arm64/boot-inner.sh` inside the systemd scope of `cli/libexec/limited.sh` (IO cap and memory cap
   `X86SIM_MEM_MAX`), which moves this phone's Darling processes into the scope and runs `darling shell` with
   `host/simhost/simhost`, which execs the runtime's `launchd_sim` with the device's environment.

`mksimdevice.py` writes the device the way CoreSimulator does on a Mac: `<device>/data` (the device's home),
`LaunchDaemons/` and `LaunchAngels/` with only the requested jobs (copied from the runtime, or synthetic
`label=program` jobs for our binaries: arm64 builds from `host/<name>/arm64`, left out when there is none),
`data/var/run/launchd_bootstrap.plist`, and `sim.env` (the `SIMULATOR_*`, `DYLD_*` environment, UDID). Device models
come from `cli/lib/devicetypes-a64.json` (`<device>/model`, `x86sim device create --model`). `simhost` (x86_64: Darling's
host side) plays CoreSimulator's part of the launchd handshake (bootstrap port, the service port MIG request 708, the
holding-tank child). launchd_sim's log is in the prefix at
`private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/launchd.log`.

The launcher (`tools/launcher`, `core/src/sim.rs` and `instance.rs`) runs boot-a64.sh with `A64_KEEP=1`, the phone's
`A64_DPREFIX` and `X86SIM_METAL`, finds a phone's processes by exact checks (its prefix's darlingserver and its
descendants), and starts `simview.py` for its window.

## Apple TV and Apple Watch (tvOS / watchOS)

The same pieces run Apple's tvOS 27 and watchOS 27 simulator runtimes (`runtimes/tvos-<ver>-<build>-arm64`,
`watchos-...`; `runtime-fetch.py fetch 24K150` / `24S118`). What differs from iOS:

- **Our in-simulator binaries are built per platform** (`host/<name>/arm64-tvos`, `arm64-watchos`;
  `X86SIM_PLATFORM=tvos|watchos build/mac-build-arm64-shims.sh`): dyld_sim loads only Mach-Os of its own platform.
  mksimdevice.py picks the platform's build from the runtime's SystemVersion.plist. libarm64jit's stub dylibs take
  the dyld cache's platform (its header's `platform` field).
- **launchd_sim has only the system domain.** iOS's launchd_sim runs the jobs in `user/<uid>`, which ends its own
  bootstrap mode once loaded; tvOS's and watchOS's put every job in `system`, which stays in bootstrap mode (every
  request of its jobs deferred, so nothing gets past xpcproxy_sim) until the host sends MIG 700 of subsystem 700
  (launchd_sim the server): a send right to a host port, which launchd_sim also watches for death. simhost sends it
  when `SIMHOST_BOOTSTRAP_DONE=1` (boot-a64.sh, for non-iOS runtimes).
- **Shell and jobs**: PineBoard (tvOS) and Carousel (watchOS) take SpringBoard's place; boot-a64.sh has their job
  lists (`TV_UI`, `WATCH_UI`) and leaves out shared jobs the runtime doesn't ship.
- **The cache holds MTLSimImplementation**, whose calls into Metal can't be rebound: metalhostd patches the two
  device entry points in its own process (WORKAROUNDS.md).
- **Libraries built like device ones**: libdispatch receives large messages with `mach_msg2` and an aux buffer
  (Darling's `mach_msg2_internal` counts receive vectors), and libobjc's `_collecting_in_critical` is found by its
  code, not an iOS address (objc.cpp).
- **Input**: Apple TV has no touchscreen; tvOS takes the hardware keyboard as the remote (arrows, return = select,
  escape = back). An Apple Watch gets simhid's Digital Crown service (`crown <delta> y`; the mouse wheel in
  simview).
- **Device types**: `devicetypes-a64.json` entries with `"platform": "tvos"` / `"watchos"` (`x86sim device create
  --model "Apple TV 4K (3rd generation)"` takes the newest tvOS runtime). Apple TV's capabilities name its display
  `TVOut`; simfb serves it as the main display (`LCD`) all the same.
- Not yet: pairing a watch with a phone (both devices' `ids_simd` must reach each other's Mach ports, which live in
  different Darling containers), pre-translation training for these runtimes.

## simshim (host/simshim)

`libsimshim.dylib` is injected into every simulator process (`DYLD_INSERT_LIBRARIES` in `sim.env`). It interposes the
few host services a Linux host cannot provide, among them system power registration (no IOPMrootDomain), csops
entitlement blobs (sent to Darling's syscall) and sandbox extensions (tokens issued and accepted; nothing is
sandboxed). The arm64 build also includes the os_log formatter used by `x86sim log stream`. Optional diagnostic shims
(`host/simshim/diag`, `X86SIM_INSERT=...`, built with `make mac-diag`) log specific subsystems.

## Jetsam: jetsam.py

The simulator has no memorystatus, and every process carries a few hundred MB under the JIT. `cli/libexec/jetsam.py`
reclaims what a device's jetsam would (idle extensions, suspended background apps, clean idle-exit daemons), reading the
records Darling's `libsystem_kernel` keeps in the container. `X86SIM_JETSAM=0` turns it off.

## Display: simfb and the frame ring

backboardd loads `SimFramebuffer.framework` from `SIMULATOR_FRAMEBUFFER_FRAMEWORK`. Ours (`host/simfb`) reports one
built-in display named `LCD` (QuartzCore treats a main display with any other name as absent), gives CoreAnimation IOSurface
swapchains and copies each completed present into a shared-memory ring ([protocols/SIMFB.md](protocols/SIMFB.md)), written under
`/run/user/<uid>` (`SIMFB_RING` in `sim.env`) and linked from `/dev/shm` (`SIMFB_RING_LINUX`, default
`/dev/shm/x86sim-a64-simfb.ring`). Every publish wakes Linux readers through a futex on the ring's seq word
(ring version 2), so they sleep while the screen doesn't change. Linux readers: `simview.py` (GTK4 window),
`fb2png.py` (screenshots), `fpsmeter.py`, `framecheck.py`.

## Input: simhid

backboardd loads `SimulatorHID.framework` from `SIMULATOR_HID_SYSTEM_MANAGER`. Ours (`host/simhid`) adds virtual
touchscreen, button and keyboard HID services to backboardd's event system and feeds them from
`<device>/data/simhid.sock`, a line protocol ([protocols/SIMHID.md](protocols/SIMHID.md)) used by `simview.py` and
`simtouch.py`.

## GPU: metalhostd, vkmtl, mtlvk

On a Mac, simulator processes' Metal goes through `MTLSimDriver` over XPC to the host's `MTLSimDriverHost`, which
replays it on the Mac's GPU. Here `host/metalhostd` (a simulator job) loads the runtime's own `MTLSimImplementation`
and gives it a Metal device implemented by `vkmtl.m`, which forwards every object and command buffer over a Unix
socket (VKMTL protocol, [protocols/METAL.md](protocols/METAL.md)) to `linux/mtlvk`, a native Rust process that runs
it on Vulkan with **metal2vulkan** (`external/metal2vulkan`, branch x86sim: Metal API on Vulkan + AIR to SPIR-V
translation). Buffer and texture memory is shared without copies: simulator memory is memfd-backed (darlingserver),
metalhostd obtains the fd with syscall 599 and passes it with `SCM_RIGHTS`; mtlvk imports it
(`VK_EXT_external_memory_host`). Render targets over IOSurfaces of the screen's size are the exception: mtlvk draws
them in VRAM and copies them to the surface's pages once per command buffer (blending into host pages crossed PCIe
for every layer). CoreAnimation's render server, the wallpaper and apps all use it
(`X86SIM_METAL=all`, the launcher's default; `0` = software rendering, which is also boot-a64.sh's default when run
by hand). Details: [METAL.md](METAL.md).

## Cross-process surfaces: iosurfaced

IOSurfaces shared between processes (CoreAnimation layers, video, WebKit) are served on a Mac by CoreSimulator's
SimRenderServer as `com.apple.IOSurface.Remote`. `host/iosurfaced` implements that service inside the simulator;
surfaces are shared anonymous memory (memfds in darlingserver) handed out as `xpc_shmem`
([protocols/IOSURFACE.md](protocols/IOSURFACE.md)).

## Network: mdnsresponder and netconfig

The simulator resolves names through the host's mDNSResponder socket (`/var/run/mDNSResponder`).
`linux/mdnsd/mdnsresponder.py` implements the dnssd_ipc protocol on Linux (real DNS via dnspython) at
`$ST/mDNSResponder` (one server per boot, started by boot-a64.sh), linked into the container's `/var/run`
(`X86SIM_MDNS=0`: none).
Network state (what a Mac's configd publishes) comes from `linux/hostnet/hostnet.py` (the Linux default-route
interface as Setup:/State: keys), loaded by `host/netconfig` into a second `configd_sim` registered as
`com.apple.SystemConfiguration.configd` (`com.x86sim.host-configd`), which the simulator's configd_sim mirrors. Sockets
and routing sockets themselves are Darling's (PF_ROUTE, socket options, EVFILT_SOCK).

## Host file services: fpsim2host

FileProvider sends some operations to the Mac host's fileproviderd (`com.apple.FileProvider.sim2host`): open by file
id, openat/mkdirat/... on behalf of extensions, package lookup, directory entries, dataless files.
`host/fpsim2host` (job `com.x86sim.fpsim2host`) serves that interface inside the simulator.

## Audio: simaudio

`host/simaudio/arm64/libsimaudio.dylib`, injected into each process, provides the audio devices a Mac's CoreSimulator
and coreaudiod would, and streams PCM over `simaudio.sock` to `cli/libexec/simaudio.py` (PipeWire), started by
boot-a64.sh. Opt-in with `X86SIM_AUDIO=1` (see [WORKAROUNDS.md](WORKAROUNDS.md)).

## Test helpers inside the device

`host/openurl` (job `com.x86sim.openurl`) opens URLs and apps through FrontBoard (`x86sim openurl|app|launch`), reading
requests from `<device>/data/tmp/x86sim-openurl`. It also installs and removes apps (`x86sim install|uninstall`,
`cli/libexec/appinstall.sh`), the way CoreSimulatorBridge does on a Mac: `+[IXAppInstallCoordinator
installApplication:consumeSource:options:completion:]` -> installcoordinationd -> installd (copies the bundle into
`data/Containers/Bundle/Application/<uuid>`) -> containermanagerd (data container) -> lsd (registration) ->
SpringBoard (icon). The device type's capabilities (`cli/lib/devicetype-<model>.json`) are written as
`<device>/capabilities.plist` and given to MobileGestalt with `SIMULATOR_CAPABILITIES`.

simctl's developer commands (`cli/libexec/simctl.py`: `x86sim launch|terminate|get_app_container|listapps|push|
location|addmedia|log stream|io|pidof`) go to the same job as one-line JSON requests (`req <id> <json>`, answered by a
`result <id> <json>` log line). The job does what CoreSimulatorBridge does inside a Mac's device, with the Bridge's
entitlements: FrontBoard's debug options (`__DebugOptions`: arguments, environment, stdout/stderr paths for
`--console`, wait-for-debugger), `FBSSystemService` termination, `LSApplicationProxy` containers,
`+[UNNotificationRequest requestWithIdentifier:pushPayload:bundleIdentifier:]` for `push`, `CLSimulationManager` for
`location` (locationd's `com.apple.locationd.simulation` service: one point repeated every second, waypoints moved along
at a speed with updates by interval or distance, or one of the runtime's scenarios in CoreLocation.framework/Support/
SimulationScenarios; nanoregistryd must run), `PHPhotoLibrary` change requests for `addmedia`.
`--console-pty` passes a Linux pty's path (`/Volumes/SystemRoot/dev/pts/N`) as the app's stdout/stderr. `log stream --app` relaunches the app with
`X86SIM_OSLOG`, which turns on libsimshim's built-in os_log formatter (`host/simshim/diag/oslogdiag.m` compiled in):
messages go to `data/var/log/oslog.<prog>.<pid>.log` without logd/diagnosticd. `io recordVideo` encodes the frame
ring with ffmpeg.

## CLI

`cli/x86sim` reads `x86sim.env` through `cli/lib/config.sh` (also used by every script; `cli/lib/x86config.py` for
Python) and dispatches to the scripts in `cli/libexec` (`x86sim help` lists the commands). Defaults are the arm64
runtime (`runtimes/ios-27.2-24B8117-arm64/RuntimeRoot`) and device (`var/device-a64`). Large scratch files (Darling
prefixes, JIT/AOT caches) are in `$X86SIM_SCRATCH`.

## Data flows at a glance

| Flow | From | Channel | To |
|---|---|---|---|
| frames | backboardd (simfb) | ring in `/run/user/<uid>`, linked as `$SIMFB_RING_LINUX` | simview, fb2png, framecheck |
| input | simview, simtouch | `<device>/data/simhid.sock` (text lines) | backboardd (simhid) |
| Metal | every Metal client | XPC `com.apple.metal.simulator[.<proc>]` | metalhostd |
| Metal | metalhostd (vkmtl) | Unix socket `mtlvk.sock` (state dir, or a shared one) + memfds | mtlvk (Vulkan) |
| IOSurface | IOSurface.framework | XPC `com.apple.IOSurface.Remote` + xpc_shmem | iosurfaced |
| DNS | libsystem_dnssd | `/var/run/mDNSResponder` -> the boot's `mDNSResponder` socket | mdnsresponder.py |
| network state | hostnet.py | plist -> netconfig -> host-configd | configd_sim (SimulatorSupport) |
| audio | libsimaudio | `simaudio.sock` | simaudio.py (PipeWire) |
| host files | FileProvider | XPC `com.apple.FileProvider.sim2host` | fpsim2host |
| install app | x86sim install (appinstall.sh copies the .app into `data/tmp/x86sim-install`) | `<device>/data/tmp/x86sim-openurl` | openurl job -> InstallCoordination -> installd |
| open URL/app | x86sim openurl/app | `<device>/data/tmp/x86sim-openurl` | openurl job -> FrontBoard |
| simctl commands | x86sim launch/push/... (simctl.py) | `req <id> <json>` in `<device>/data/tmp/x86sim-openurl`, `result` lines in its log | openurl job -> FrontBoard, UserNotifications, Photos, CoreLocation, LaunchServices |
