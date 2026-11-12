# MetalCoverage

A regression suite for the simulator's Metal: one test per Metal feature, run by an iOS-simulator app that is built on
Linux. Every result is checked on the CPU. The checklist is the iOS SDK itself: `inventory.py` lists every method and
property that the iPhoneSimulator SDK's Metal headers declare for iOS, and the report measures the tests against that
list.

```sh
tests/metal/coverage/run.sh                  # build, install, run on the CLI's device; writes a report
tests/metal/coverage/run.sh --only render/   # one area, or any substring of test names
tests/metal/coverage/build.sh                # just the app: $X86SIM_SCRATCH/mtlcov/MetalCoverage.app
```

`run.sh` uses the device of `x86sim install` (`X86SIM_DEVICE` / `X86SIM_STATE`). It writes `results.tsv`,
`covers.tsv`, the launch logs and `report.html` under `$X86SIM_SCRATCH/mtlcov/run-<time>/` (or `--out DIR`). A test
that crashes or hangs is charged to that test, and the app is relaunched at the next one.

## Results

| status | meaning |
|---|---|
| PASS | the feature works; with `claimed=0`, it works although the device does not advertise it |
| FAIL | this stack gets it wrong (the detail says how) |
| CLIENT | Apple's simulator client (MTLSimDriver, or its shader compiler) deviates from iOS itself, as on a Mac |
| REFUSED | Apple's client or Metal's validation refuses the call (an assertion), as on a Mac's simulator |
| CRASH, HANG | the process died, or the app's watchdog (`MTLCOV_TIMEOUT`, default 20 s) ended a test |

## Ground truth

The same app runs unchanged in Apple's iOS simulator on a Mac. Install it with `xcrun simctl install`, then launch it
with `SIMCTL_CHILD_MTLCOV_EXIT=1 SIMCTL_CHILD_MTLCOV_FROM=<n> xcrun simctl launch --console-pty`, starting again after
a crash from the next index. Copy the `launch-<n>.log` files back and run `collect.py <dir>` and then
`report.py <dir>`. A test that fails on both is probably a test bug, or behaviour of Apple's client (CLIENT). A test
that fails only here is a bug of this stack.

## Writing a test

Tests live in `t_<area>.m`; see the header of `mtlcov.h`. A test lists the `Owner selector` pairs it exercises (the
report counts them against the inventory). It states what the device claims with `MC_CLAIM(...)`. It checks results
with `MC_CHECK`, and uses `MC_CLIENT_CHECK` where Apple's own simulator deviates from iOS. Shaders are compiled from
source at run time (`mc_lib`), so the suite needs no Mac to build.
