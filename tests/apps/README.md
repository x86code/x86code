# Test apps (regression suite for third-party apps)

Small purpose-built iOS apps, built for the arm64 iOS Simulator on the Mac with `swiftc` (no Xcode project), installed
with `x86sim install` and checked logs-first. Every check prints `X86TEST <app> <check> PASS|FAIL <detail>` to stderr
and appends it to `Documents/x86test-results.txt` in the app's data container.

| app | exercises |
|---|---|
| x86ui | SwiftUI List (200 rows), NavigationStack push/pop, repeating animation, TextField + keyboard, SF Symbols, UIGraphicsImageRenderer → PNG |
| x86net | URLSession HTTPS GET + JSON, download task, WKWebView page load (+ JS `document.title`) |
| x86data | UIKit scene lifecycle, Core Data (SQLite store, model built in code), files (write/rename/attributes), UserDefaults, Core Image blur → PNG, local notification (authorization prompt, schedule, delivery) |

    tests/apps/build.sh [app...]                 build on the Mac (X86SIM_MAC) into $X86SIM_SCRATCH/apps/
    tests/apps/run.sh <phone> [--no-build] [app...]
                                                 build, install, launch, wait for "done", answer permission prompts
                                                 (simtouch dismiss), check results, launchd lines, crash reports;
                                                 screenshot per app in $X86SIM_SCRATCH/apps/run-<time>/

`<phone>` is a phone's name, folder or dir (as `x86sim install`). The phone must be running.
Apps without the UIScene lifecycle trap in iOS 27's UIKit (`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`),
so every app here uses scenes.

## sdkcov: the whole SDK, on iOS, tvOS, watchOS and visionOS

`sdkcov/` is one SwiftUI app, built from the same sources for the iOS, tvOS, watchOS and visionOS simulators, that walks through
everything the latest SDK (27.2) offers an app:

1. **Every framework and library** in Xcode's simulator SDK (`System/Library/Frameworks/*`, including Swift cross-import
   overlays, and `usr/lib/*`): `dlopen` by install name, then its representative exports resolve (Objective-C classes,
   C / C++ symbols, Swift type metadata), taken from the SDK's `.tbd` so only public API is used. The list is
   `sdkcov/manifest-<platform>.json` (`gen-manifest.py`, committed; regenerate after an SDK or runtime update).
2. **Functional checks** per framework (`sdkcov/checks/*.swift`): real work with results checked, all offline and
   offscreen: Metal shaders compiled at run time and their pixels read back, SceneKit / OpenGL ES / Core Image /
   SwiftUI / Charts rendering, AVAssetWriter + VideoToolbox encode / decode, offline AVAudioEngine rendering, AAC,
   Core ML compiling and running a model built in the app, Vision OCR, keychain, Core Data / SwiftData, TCP / UDP /
   HTTP on loopback, WKWebView running JavaScript, and so on.
3. **Coverage**: `Documents/sdkcov-coverage.json` per framework (load result, functional checks), one summary line.

SKIP, never FAIL, for what Apple's own simulator does not support either: frameworks the runtime does not ship, Xcode's
injected diagnostics libraries, and hardware the simulator lacks, reported as the framework itself reports it
(cameras, NFC, UWB, Bluetooth, motion, haptics, ARKit tracking, Apple Intelligence). The app carries the simulated
entitlements Xcode embeds for its capabilities (`sdkcov.entitlements`: keychain, app groups, HealthKit, HomeKit,
Siri, iCloud, push) in `__TEXT,__entitlements`.

    tests/apps/sdkcov/build.sh [ios] [tvos] [watchos] [xros]
    tests/apps/sdkcov/run.sh <device> [--no-build] [--fresh] [--only ID[,ID...]]

`run.sh` picks the platform from the device's runtime, installs, launches, and relaunches until the app reports
`done`: a crash or a hang (the app's watchdog) is reported as FAIL for that check and the next launch resumes after
it. Results, coverage JSON, `report.md` (`report.py`), the app's stdout / stderr per launch and a screenshot go to
`$X86SIM_SCRATCH/apps/sdkcov-<platform>-<time>/`. `--only func:Metal,load:UIKit` runs just those checks once and
prints their results (stderr only; the results file is left alone).

watchOS and visionOS build against Xcode's own simulator SDKs, copied from the Mac to `sdks/WatchSimulator-xcode.sdk` and
`sdks/XRSimulator-xcode.sdk` (`sdks/XRSimulator.sdk` is sim-sdk.py's substitute, which has iOS's framework list).
`ref-mac.sh xros` needs a visionOS simulator runtime installed on the Mac.
The sdkcov devices run with the "widgets" feature on (`features.json`), as WidgetKit needs chronod; run.sh says so
when a device has it off. Boot them with `X86SIM_AUDIO=1` for the audio checks (simaudio: real-time output, PHASE,
OpenAL, speech). The first speech synthesis after a boot can time out while its extension is translated.

Building on Linux: the toolchain has no SwiftDataMacros plugin and its Foundation macros expand to the open-source
module names, so `checks/Data.swift` writes out what `@Model` and `#Predicate` expand to.
