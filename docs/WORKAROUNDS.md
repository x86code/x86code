# Workarounds vs faithful fixes

Every change in this project is either a **faithful fix** (Darling or a stand-in now behaves as XNU / CoreSimulator /
the Mac host does) or a **workaround** (something is skipped, faked or approximated so the simulator gets further).
This list is about the workarounds; the faithful fixes are the bulk of the Darling branches. Each entry says where it lives and what a faithful version would need.

Legend: **W** = workaround, **S** = stand-in for a Mac/CoreSimulator component (faithful in intent, partial in
coverage), **F** = faithful fix listed for contrast because it replaced an earlier workaround.

## Stand-ins for the Mac host and CoreSimulator (S)

| What | Where | Coverage / gap |
|---|---|---|
| CoreSimulator's launchd handshake (bootstrap port, service port, holding tank) | host/simhost | MIG 708 and the holding-tank child; on tvOS / watchOS also the host's MIG 700 (the host port launchd_sim watches, which ends the system domain's bootstrap mode). Other requests are logged and dropped. |
| SimFramebuffer.framework (display) | host/simfb | One built-in display, no external displays, no host compositor. Frames are copied (not shared) into the ring. |
| SimulatorHID.framework (input) | host/simhid | Touchscreen (1-2 fingers), buttons, keyboard over a socket; Apple Watch: the Digital Crown (scroll events through Apple's crown service, page 0xff0b). Apple TV: no Siri Remote services, the hardware keyboard stands in (arrows, return = select, escape = back). No Indigo protocol, no accelerometer/pencil/game controllers. |
| MTLSimDriverHost / SimMetalHost (GPU) | host/metalhostd + linux/mtlvk + metal2vulkan | The runtime's own MTLSimImplementation on a Vulkan-backed device; feature coverage is what metal2vulkan translates (see METAL.md). |
| SimRenderServer's com.apple.IOSurface.Remote | host/iosurfaced | Surfaces as shared anonymous memory; no compression, no GPU-private surfaces. |
| Host mDNSResponder | linux/mdnsd | Unicast DNS (GetAddrInfo, QueryRecord). Register/Browse/Resolve are accepted but return nothing (no multicast DNS, no Bonjour). |
| Host configd (network state for configd_sim's SimulatorSupport) | linux/hostnet + host/netconfig + com.x86sim.host-configd | A snapshot of the default-route interface at boot; not updated when Linux networking changes. |
| Host fileproviderd (com.apple.FileProvider.sim2host) | host/fpsim2host | All 16 methods. Dataless files are SF_DATALESS + a sparse file of the logical size: nothing faults on read (materialization handlers are kept but never called); purgeable and sync-root marks are only recorded (xattrs). |
| `simctl openurl` / `simctl launch` / terminate / get_app_container / listapps / push / location / addmedia / io | host/openurl (com.x86sim.openurl) + cli/libexec/simctl.py | Opens through FrontBoard's open-application service with the Bridge's debug options (arguments, environment, `--console` through stdout/stderr files the CLI follows, `--wait-for-debugger`), carrying the Bridge's entitlements. `--console` follows stdout/stderr files; `--console-pty` gives the app a Linux pty (opened by path through `/Volumes/SystemRoot/dev/pts/N`). `location` (set/clear/list/run/start) goes through CLSimulationManager to locationd as on a Mac. |
| `simctl install` / `uninstall` (CoreSimulatorBridge in the device) | host/openurl + cli/libexec/appinstall.sh | Same call as CoreSimulatorBridge (IXAppInstallCoordinator with developer MIInstallOptions), from a launchd job instead of the Bridge; the bundle is first copied into the device's tmp directory (staging), installd then copies it as on a Mac. No `installationInfo` result, no app data containers (`simctl install_app_data`). |
| Device type (CoreSimulator's `.simdevicetype`: capabilities.plist via `SIMULATOR_CAPABILITIES`) | cli/lib/devicetypes-a64.json, cli/lib/devicetype-*.json, mksimdevice.py | The models in devicetypes-a64.json (`<device>/model`). The profile's other parts (chrome, framebuffer mask PDF, sensor-bar image) are not used. |
| Host /System/Library lookups by absolute path | cli/libexec/arm64/boot-a64.sh (links into the Darling prefix) | CoreSpotlight.framework (the runtime's copy) and host data fetched from a Mac by fetch-macos-host.sh (GeoServicesData); others the simulator might open on the host path are absent. |
| Host time zone (/etc/localtime) | cli/libexec/arm64/boot-inner.sh | Links the container's /private/etc/localtime to Linux's zone. |
| Host macOS version seen by simulator processes | Darling sysctl_kern.c: kern.osproductversion = 26.4 for iOS, tvOS and watchOS simulator processes | A fixed value; the real host is Linux. |

## Workarounds in the simulator processes (W)

| Workaround | Where | Why / faithful alternative |
|---|---|---|
| **Icon-layer fallback**: when `-[IFConcreteImage ICRIconLayer]` returns nil, return a CALayer with the flat CGImage | simshim.c | ICRIconLayer needs an RBDevice and layer data that iconservicesagent's software renderer does not produce, so the first SpringBoard showed gray icons. Faithful: iconservicesagent rendering layer data on the Metal stand-in. |
| **Dummy sandbox extensions**: `sandbox_extension_issue_*` return opaque tokens, `consume`/`release` accept any token | simshim.c | Darling has no `__mac_syscall("Sandbox")` (ENOSYS) and nothing is sandboxed. Faithful: a sandbox (MACF) implementation. |
| **os_log disabled**: `OS_ACTIVITY_MODE=disable` for every launchd job (mksimdevice.py) and, from simshim, for the runtime's processes launched by SpringBoard/RunningBoard (installed apps, under `Containers/Bundle/Application`, keep os_log: logd stores it and OSLogStore reads it back); `os_state_add_handler` returns dummy handles meanwhile | mksimdevice.py, simshim.c | Volume under the JIT: logd crashed every process in `firehose_buffer_create` (Mach memory entries) at first; without a draining diagnosticd, DT-mode senders block or flood lookups. `X86SIM_NODT=all,-<label>` / `x86sim-stderr-progs` turn logging back on per process for debugging. Faithful: logd + diagnosticd running on Darling's memory entries. |
| **System-domain jobs loaded into the user domain** (`LimitLoadToSessionType: System` dropped) | mksimdevice.py | iOS only. launchd_sim's system domain stays in bootstrap mode unless the host sends MIG 700 (CoreSimulator does; simhost does it for tvOS / watchOS, whose launchd_sim has only the system domain: `A64_BOOTSTRAP_DONE=1` tries it on iOS). Faithful: MIG 700 on iOS too, keeping system-only jobs in the system domain. |
| **Metal entry points patched in metalhostd** (tvOS / watchOS) | host/metalhostd/metalhostd.m | Their MTLSimImplementation is in the dyld shared cache and calls Metal directly, so there is no GOT entry to rebind; `MTLCreateSystemDefaultDevice` / `MTLCopyAllDevices` become a jump to vkmtl's in metalhostd only. Faithful: a real MTLSimDriverHost on the host side. |
| **Sim-to-host connections kept as simulator connections** (`xpc_connection_enable_sim2host_4sim` skipped for Metal, IOSurface, FileProvider host services) | simshim.c | Our stand-ins run inside the simulator on the simulator's libxpc, which drops macOS-format messages. Faithful: running them as macOS processes on the host libxpc (Darling's), which would need the sim-to-host XPC path. |
| **System power** registration that never fires | simshim.c | Darling's iokitd has no IOPMrootDomain; the device never sleeps. |
| **tvOS sleep declined** (`-[PBPowerManager sleepSystemWithReason:completion:]` completes with NO, nothing changes) | simshim.c | PineBoard's sleep sends HDMI-CEC standby and cycles the display mode for sleep; neither answers without an HDMI sink, so the power state stayed "going down to sleep", the hot-black window covered the screen and every wake failed (error 8001): a black TV until restarted. `X86SIM_TV_SLEEP=1` keeps PineBoard's. Faithful: a CEC / display stand-in that answers standby and the mode cycle. |
| **Parked executables never reclaimed** | cli/libexec/jetsam.py | A parked process (X86SIM_A64_SLIM_PARK) holds next to no memory; the watch's Carousel relaunched WidgetRenderer_Snapshots at once after every kill. |
| **csops entitlement blobs** go to Darling's syscall instead of libsystem_sim_kernel's | simshim.c | The runtime's version fails a short buffer with ENOENT instead of ERANGE. Faithful fix would be in the runtime (not ours) or a matching kernel answer. |
| **Siri session language** pre-set (`com.apple.assistant.backedup` "Session Language" = en-US) | mksimdevice.py | assistantd would set it on a Mac's device; without it AFPreferences recomputes in a loop on the main thread. |
| **Permission prompts answered by OCR** (`x86sim dismiss`: tesseract finds "Allow" buttons and taps them) | simtouch.py | Test convenience only. |
| **Package lookup by extension** (fpsim2host pkgLookup: a directory whose extension is a registered package UTType is a package) | host/fpsim2host | Linux file systems carry no bundle bit; a Mac's host does the same LaunchServices check. |
| **os_log for one app through libsimshim** (`x86sim launch --oslog`, `log stream --app`): messages formatted into a file | host/simshim (oslogdiag.m built in) | Formats like the shim, not like logd (privacy annotations ignored, no subsystem/category columns). Faithful: logd + diagnosticd. |
| **The standard boot lists its jobs** (`A64_JOBS` sets in boot-a64.sh, trimmed by the device's feature toggles) instead of loading every LaunchDaemon of the runtime | cli/libexec/arm64/boot-a64.sh | Jobs are added as apps need them, each with the reason in a comment. A Mac's device loads the whole set. |
| **Fresh container per boot**: the phone's previous container is stopped (its own processes, found by exact checks, then `darling shutdown` and a sweep of what it misses) | cli/libexec/arm64/boot-a64.sh | Leftover processes and two launchd_sims on one device break new boots; killing processes inside a running container leaves darlingserver in a state where new jobs hang. |
| **statfs reports `apfs`** for local Linux file systems | Darling (libsystem_kernel statfs conversion) | FileProvider only accepts APFS volumes (the iOS simulator only runs on APFS). |
| **chflags flags stored in an xattr** (`user.x86sim.bsdflags`, hidden from listxattr) | Darling (helper/misc/bsdflags.h) | Linux has no BSD file flags; this keeps them per file across processes. |
| **fsctl answers APFS requests as for a plain directory tree**; unknown ones ENOTTY | Darling (misc/fsctl.c) | Enough for FileProvider's sync-root and dir-stat queries. |
| **O_SYMLINK on regular files/directories reopens through /proc/self/fd** | Darling (fcntl/openat.c) | Linux O_PATH descriptors can't be read; XNU's O_SYMLINK only differs for symlinks. |
| **setrlimit(RLIMIT_NOFILE) below the current limit succeeds and changes nothing** | Darling (misc/setrlimit.c) | mldr keeps each thread's darlingserver socket at the top of the process's initial fd range; a lowered limit made thread creation abort (revisiond). Faithful: Darling's internal fds below the limit, or a limit enforced only on the process's own fds. |
| **Document ids are the inode's low 32 bits**; fsgetpath/openbyid_np resolve ids (and object id 2, the volume root) only from paths some process got from getattrlist | Darling (getattrlist_generic.c, misc/fsgetpath.c) | Linux can't open by inode number. A file nobody has stat'ed through getattrlist since its id was handed out cannot be found by id. |
| **setattrlist ACL / owner UUIDs accepted and ignored**; getattrlist answers the newer volume attributes (FSTYPENAME = statfs's "apfs", MOUNTEXTFLAGS/FSSUBTYPE/OWNER 0, SPACEUSED) | Darling (helper/xattr/setattrlist_generic.c, getattrlist_generic.c) | Linux files here have no ACLs; installd's staging removes ACLs and reads the volume type. |
| **VRAM render targets**: a render-target texture over an IOSurface of >= 1M pixels is a device-local texture in mtlvk, copied to the surface's pages at the end of each command buffer that wrote it | linux/mtlvk (conn.rs; `MTLVK_VRAM_TARGETS=0` off, `MTLVK_VRAM_MIN_PIXELS`) | Drawing into imported host pages made each blended layer cross PCIe (8-12 ms GPU per frame). CPU writes to such a surface after the texture was made are not seen by the GPU (small surfaces stay in host pages for that reason: iconservicesagent's icons). Faithful: IOSurfaces allocated in GPU memory with explicit CPU access (lock/unlock) synchronization, as on a Mac. |
| `NOTE_WL_SYNC_IPC` knotes accepted as no-ops; `memorystatus_control`, `kqueue_workloop_ctl` succeed | Darling (darling-xnu, libkqueue) | No memory pressure / jetsam, no sync-IPC priority inheritance. |
| `SIOCGCONNINFO` left ENOTTY | Darling (sockets) | Answering it made Network.framework abort on a recursive lock. |
| Runtime symlinks that 7-Zip skips or writes empty | tools/runtime/extract-runtime.py | Made again from the image's own listing after extraction (DEVELOPMENT.md setup step 2). |

## Diagnostics that change behaviour only when enabled (opt-in)

`host/simshim/diag/*` (via `X86SIM_INSERT`), `X86SIM_SHIMLOG`, `X86SIM_JOBLOG` (default on in boot-a64.sh),
`X86SIM_KEEPALIVE`, `MTLVK_LOG`, `MTLVK_DUMP_PASSES`/`MTLVK_DUMP_REPLACE`, `X86SIM_VKMTL_LOG`/`X86SIM_VKMTL_DUMP`,
`X86SIM_IOSURFACE_LOG`, `X86SIM_MDNS_LOG`. They are not workarounds but are listed so they are not mistaken for
required parts.

## Replaced workarounds (F, for history)

- `xpc_init_services` was skipped in simshim (launchd_sim never answered the pid-domain uncork); removed once the
  underlying Darling bugs were fixed.
- Settings' gray row icons were first blamed on Metal; they also happen with software rendering and remain open
  (in-process IconServices store lookup misses).
- The workloop interposer (`host/simshim/diag/workloop_shim.c`) predates kernel workloops in Darling; it is kept for
  reference and not used.
- simfb's fixed 40 ms delay before copying a frame was replaced by waiting for GPU completion.

## Backlog (not started or unfinished)

- Home indicator gestures: a swipe up from the bottom edge doesn't go home or open the app switcher. Check that
  simview/simhid send edge-swipe touches the way SpringBoard's system gesture recognizers expect (edge/region flags,
  digitizer surface events).
- Apple's simulator MCP server: research what Apple ships (which tool, the transport, and which simctl/CoreSimulator calls
  it makes) and make it work against x86sim. If it needs macOS, provide a compatible MCP server on Linux backed by x86sim
  (boot, install, launch, screenshot, tap/type, logs).
- Scroll wheel in simview: wheel and touchpad scroll events should scroll the content (as on a Mac simulator:
  scroll events or a synthesized two-finger pan), not be ignored.

- Audio: host/simaudio (in-process HAL stand-in) + cli/libexec/simaudio.py (PipeWire), opt-in with
  `X86SIM_AUDIO=1`; AVAudioEngine fails at the output unit's initialize. A faithful version would
  answer coreaudiod's MIG protocol on `com.apple.audio.audiohald`.
- Clipboard sync (`x86sim pbcopy/pbpaste`, Linux clipboard <-> pasted), rotation (`x86sim rotate`), software
  keyboard toggle: not started.
