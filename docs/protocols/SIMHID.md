# simhid: touch, buttons and keyboard

`host/simhid/simhid.m` builds `SimulatorHID.framework`, a stand-in for CoreSimulator's SimulatorHID. backboardd loads
it from `SIMULATOR_HID_SYSTEM_MANAGER` (SimulatorClient's `IndigoHIDSystemSpawnLoopback`): the bundle's principal
class `SimHIDSystem` is created with backboardd's `IOHIDEventSystemRef` and adds virtual HID services to it
(`_IOHIDServiceCreateVirtual`, `_IOHIDEventSystemAddService`, `_IOHIDServiceDispatchEvent`): a built-in
touchscreen, the main-screen buttons (home, lock, volume) and a keyboard. Apple's version receives "Indigo" messages
from Simulator.app over a mach port; ours reads a Unix socket.

Clients: `cli/libexec/simview.py` (mouse, keyboard; Ctrl/Shift+drag = two fingers; F1/Ctrl+H home, F2 lock, F3/F4
volume) and `cli/libexec/simtouch.py` (`x86sim tap|swipe|pinch|pan2|key|type|home|lock|raw`). Device pixel size comes
from the live frame ring / `SIMULATOR_MAINSCREEN_*` (arm64 is 1206×2622).

Arm64 notes: the touchscreen HID props must include `displayUUID` = `x86Sim-main-display` (same as
`SFBDisplayGetDisplayUID`); `BKIOHIDService` copies that property into its displayUUID ivar, and without it
`BKDisplayConvertCAScreenLocationToContext` drops every touch. Dispatch `_IOHIDServiceDispatchEvent` on the
socket thread (not `dispatch_async`) and serialize `handle_line` with a mutex (`dispatch_sync` was a silent
no-op under the A64 JIT).

## Socket protocol

```
Socket: $SIMHID_SOCKET (default <SIMULATOR_SHARED_RESOURCES_DIRECTORY>/simhid.sock), stream, any number of
clients, one text command per line. A path too long for sun_path (104 bytes, Darling's /Volumes/SystemRoot included)
is a symlink to /run/user/<uid>/x86sim-simhid-<SIMULATOR_UDID>.sock (next to the frame ring); clients resolve it
before connecting (Linux's own limit is 108):
  touch down|move|up <x> <y> [edge]   x, y normalized to the display (0..1, origin top left); edge (on down, kept
                                 for the whole touch): none|top|left|bottom|right, a touch that begins at that screen
                                 edge (system gestures: home indicator, Control/Notification Center)
  touch2 down|move|up <x1> <y1> <x2> <y2>   two fingers (pinch, two-finger pan): one hand event with two finger
                                 children, finger indexes 1 and 2 with their own identities
  @<screenID> <touch command>    the touch on another integrated display (iPhone Duo: @3 = the inner "LCD-1"; x, y
                                 normalized to that display's framebuffer as simfb publishes it)
  hinge <degrees> [ms]           devices with two integrated displays: the hinge angle, 0 folded (closed) .. 180 flat
  fold | unfold                  (open), moved there over <ms> (default 600) in 100 Hz reports; fold / unfold = hinge
                                 0 / 180. CoreMotion reads it from the hinge service (vendor page 0xff0c, usage 0x21)
                                 and SpringBoard's device pose picks the outer or inner display
  key down|up <usage>            keyboard usage (page 7), e.g. 4 = 'a', 0x28 = return
  kbidle <seconds>               this client's keyboard idle detach: after its last key the on-demand keyboard stays
                                 attached that long (default SIMHID_KB_IDLE_S, 30; <= 0 never detaches)
  kbsettle <ms>                  this client's wait after the keyboard service is attached (default
                                 SIMHID_KB_SETTLE_MS, 150)
  button home|lock|volup|voldown down|up
  button menu|tv|playpause|side down|up
                                 consumer page: menu 0x46, side = lock (0x30), tv 0x60, playpause 0xcd
  usage <page> <usage> down|up   any page / usage on the buttons service (for finding what a platform reads)
  crown <delta> [x|y|z]          Apple Watch: the Digital Crown turned by <delta> (a scroll event on that axis,
                                 default y; positive = down). The crown service is Apple's: vendor page 0xff0b,
                                 usage 1, built in; there is none on other models
```

On an Apple TV the keyboard is the remote (tvOS turns hardware arrow keys into focus moves, return into select and
escape into back); the Siri Remote's own HID services (buttons, touch surface) are not there. Its buttons are consumer
usages on the buttons service, found by trying them in tvOS 27.2: 0x46 (Menu Escape) is Back, one level as the keyboard's
Escape (0x40, Menu, closes the app from any depth; 0x224 AC Back does nothing), 0x60 the TV button (PineBoard's home
from anywhere), 0xcd play / pause, 0xe2 mute. 0x223 (AC Home) also goes back one level. Holding 0x30 (power) puts the TV
to sleep, and nothing here wakes it again; the launcher does not offer it. On an Apple Watch 0x40 is the crown's
press (watch face / app grid) and a short 0x30 the side button (sleep / wake the screen); a crown step of ~120
scrolls a Settings list about one row.
