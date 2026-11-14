#!/bin/bash
# x86Sim: boot a phone (iOS 27 arm64 runtime, every process under libarm64jit) for SECS seconds and summarise. Each
# phone has its own Darling prefix (A64_DPREFIX, default $X86SIM_SCRATCH/a64prefix: only that container is shut down and
# restarted), device (var/device-a64), state dir (var/run-a64) and frame ring (/dev/shm/x86sim-a64-simfb.ring).
# DNS: own linux/mdnsd server per boot (Speed 26, below). mtlvk is started here only when X86SIM_METAL!=0, on this boot's own
# socket ($ST/mtlvk.sock) and pidfile — never pkill -x mtlvk (would hit a frozen x86 stack's mtlvk).
# Runs in the systemd scope of cli/libexec/limited.sh (40 MB/s IO, memory cap X86SIM_MEM_MAX).
#
# Memory: Stage 2's 6G default was based on cgroup memory.current that missed every guest (darlingserver was
# started by a darling shell *outside* the scope — the TZ link — so guests inherited that foreign cgroup). Real
# Shared boot sum VmRSS at home is ~8.4–9.4 GB (PSS/cgroup ~4.6 GB). Default 12G so MemoryMax does not
# OOM on the sum-RSS guests (6–8G is too low for that accounting). Override with X86SIM_MEM_MAX.
# Usage: SECS=120 cli/libexec/arm64/boot-a64.sh [extra jobs...]   (A64_JOBS=min|slim|std|full: the job list)
#        X86SIM_METAL=0|1|backboardd|all  (default 0 = software; needs host/metalhostd/arm64/metalhostd)
X86SIM_ROOT=${X86SIM_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
export X86SIM_ARCH=arm64
# Safari 1: absolute, as the launcher passes it. launchd_sim gets "/Volumes/SystemRoot$D/data/var/run/launchd_bootstrap.plist"
# and the phone's processes are matched by A64_DEVICE=$D: a relative A64_DEVICE from a shell (A64_DEVICE=var/device-a64)
# aborted launchd_sim ("missing or invalid configuration plist", brk in launchd_sim) at every boot.
A64_DEVICE=$(realpath -m "${A64_DEVICE:-$X86SIM_ROOT/var/device-a64}")
export A64_DEVICE X86SIM_DEVICE=$A64_DEVICE
# Speed 24: a device's iOS version is its <device>/runtime (a runtimes/ dir name, device-a64.py create --ios); A64_RUNTIME
# overrides. Each runtime has its own JIT/AOT cache dir ($X86SIM_SCRATCH/jc-<build>; 27.0: jitcache) and placement table.
A64_RT_DIR=$(cat "$X86SIM_DEVICE/runtime" 2>/dev/null)
export X86SIM_RUNTIME=${A64_RUNTIME:-$X86SIM_ROOT/runtimes/${A64_RT_DIR:-ios-27.2-24B8117-arm64}/RuntimeRoot}
A64_BUILD=$(basename "$(dirname "$X86SIM_RUNTIME")" | sed -n 's/^\(ios\|tvos\|watchos\|xros\)-[0-9.]*-\([0-9A-Za-z]*\)-arm64$/\2/p')
# Platforms 1: the runtime's platform (ios, tvos, watchos): its runtimes/ dir name, else its SystemVersion.plist
A64_PLATFORM=$(basename "$(dirname "$X86SIM_RUNTIME")" | sed -n 's/^\(ios\|tvos\|watchos\|xros\)-.*/\1/p')
if [ -z "$A64_PLATFORM" ]; then
	case $(sed -n '/ProductName/{n;s/.*<string>\(.*\)<\/string>.*/\1/p}' "$X86SIM_RUNTIME/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null) in
	"Apple TVOS") A64_PLATFORM=tvos ;; "Watch OS") A64_PLATFORM=watchos ;; xrOS|visionOS) A64_PLATFORM=xros ;; *) A64_PLATFORM=ios ;;
	esac
fi
# our in-simulator binaries are built per platform: host/<name>/arm64 (iOS), arm64-tvos, arm64-watchos
A64_HOSTDIR=arm64; [ "$A64_PLATFORM" = ios ] || A64_HOSTDIR=arm64-$A64_PLATFORM
export A64_PLATFORM
export X86SIM_STATE=${A64_STATE:-$X86SIM_ROOT/var/run-a64}
. "$X86SIM_ROOT/cli/lib/config.sh"
if [ -z "${X86SIM_A64_JITCACHE_DIR:-}" ] && [ -n "$A64_BUILD" ] && [ "$A64_BUILD" != 24A434 ]; then
	export X86SIM_A64_JITCACHE_DIR=$X86SIM_SCRATCH/jc-$A64_BUILD
fi
export DPREFIX=${A64_DPREFIX:-$X86SIM_SCRATCH/a64prefix}
export X86SIM_DPREFIX=$DPREFIX
export X86SIM_METAL=${X86SIM_METAL-0}
export X86SIM_MEM_MAX=${X86SIM_MEM_MAX-12G}
X=$X86SIM_ROOT; cd "$X" || exit 1
D=$X86SIM_DEVICE; ST=$X86SIM_STATE; SECS=${SECS:-90}
mkdir -p "$D" "$ST"
# Speed 22: the booted device, for simview (input socket, logs) and the launcher
[ -n "${A64_STOP_ONLY:-}" ] || echo "$D" >"$ST/device"
rm -rf "$D"/data/var/log/*.log
# Speed 1: start this boot's mtlvk when Metal is requested. Own socket + pidfile under var/run-a64.
# Speed 8: A64_MTLVK_SOCKET=<path of a running mtlvk's socket> shares that mtlvk (one per host for several devices; it
# keeps an object table per connection): this boot neither starts nor stops it.
# Shared mtlvk: its lifetime is its clients'. Other phones' darlingservers whose environment names this boot's socket
# (X86SIM_MTLVK_SOCKET; this prefix's own, possibly still running, is not counted). Killing an mtlvk another phone
# renders through crashed that phone's metalhostd -> backboardd -> SpringBoard and every app (a black screen with a
# spinner for ~30-60 s, open apps lost; software rendering if no mtlvk came back): a CLI boot, a launcher phone with
# sharing off, and every non-KEEP boot's exit did it.
a64_mtlvk_users() {
	local want="X86SIM_MTLVK_SOCKET=$1" n=0 p
	for p in /proc/[0-9]*; do
		[ "$(cat "$p/comm" 2>/dev/null)" = darlingserver ] || continue
		tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "darlingserver $DPREFIX " && continue
		tr '\0' '\n' 2>/dev/null < "$p/environ" | grep -qxF "$want" && n=$((n+1))
	done
	echo $n
}
a64_mtlvk_live() {
	local pid
	pid=$(cat "$ST/mtlvk.pid" 2>/dev/null || true)
	[ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = mtlvk ] && [ -S "$ST/mtlvk.sock" ]
}
stop_a64_mtlvk() {
	[ -n "${A64_MTLVK_SOCKET:-}" ] && return 0
	local old users
	if a64_mtlvk_live; then
		users=$(a64_mtlvk_users "$ST/mtlvk.sock")
		if [ "$users" -gt 0 ]; then
			echo "boot-a64: keeping mtlvk (pid $(cat "$ST/mtlvk.pid")): $users other phone(s) render through it" >&2
			return 0
		fi
	fi
	old=$(cat "$ST/mtlvk.pid" 2>/dev/null || true)
	if [ -n "$old" ] && [ -d "/proc/$old" ]; then
		kill "$old" 2>/dev/null || true
		sleep 0.2
		[ -d "/proc/$old" ] && kill -9 "$old" 2>/dev/null || true
	fi
	rm -f "$ST/mtlvk.pid" "$ST/mtlvk.sock"
}
if [ -n "$X86SIM_METAL" ] && [ "$X86SIM_METAL" != 0 ]; then
	# On-disk Metal binary so xpc_bundle can find MTLCompilerService.xpc (see ensure-metal-framework.sh).
	"$X/cli/libexec/arm64/ensure-metal-framework.sh" || {
		echo "boot-a64: ensure-metal-framework failed; pipelines will not compile" >&2
	}
	MTLVK_BIN=${MTLVK:-$X86SIM_MTLVK}
	if [ -n "${A64_MTLVK_SOCKET:-}" ]; then
		if [ -S "$A64_MTLVK_SOCKET" ]; then
			export X86SIM_MTLVK_SOCKET=$A64_MTLVK_SOCKET
			echo "boot-a64: sharing mtlvk at $A64_MTLVK_SOCKET, Metal for: $X86SIM_METAL" >&2
		else
			echo "boot-a64: A64_MTLVK_SOCKET $A64_MTLVK_SOCKET is not a socket: software rendering" >&2
			export X86SIM_METAL=0
		fi
	fi
fi
if [ -n "$X86SIM_METAL" ] && [ "$X86SIM_METAL" != 0 ] && [ -z "${A64_MTLVK_SOCKET:-}" ]; then
	export X86SIM_MTLVK_SOCKET=$ST/mtlvk.sock
	if a64_mtlvk_live && [ "$(a64_mtlvk_users "$ST/mtlvk.sock")" -gt 0 ]; then
		# another phone renders through this boot's earlier mtlvk: use it too (a fresh one would take theirs down)
		echo "boot-a64: reusing mtlvk (pid $(cat "$ST/mtlvk.pid")), other phones use it" >&2
	elif stop_a64_mtlvk && [ -x "$MTLVK_BIN" ]; then
		setsid "$MTLVK_BIN" "$ST/mtlvk.sock" > "$ST/mtlvk.log" 2>&1 &
		echo $! > "$ST/mtlvk.pid"
		for i in $(seq 1 50); do [ -S "$ST/mtlvk.sock" ] && break; sleep 0.1; done
	fi
	mpid=$(cat "$ST/mtlvk.pid" 2>/dev/null || true)
	if [ -S "$ST/mtlvk.sock" ] && [ -n "$mpid" ] && [ -d "/proc/$mpid" ]; then
		echo "boot-a64: mtlvk up (pid $mpid), Metal for: $X86SIM_METAL" >&2
	else
		echo "boot-a64: mtlvk did not start ($MTLVK_BIN, see $ST/mtlvk.log): software rendering" >&2
		export X86SIM_METAL=0
		stop_a64_mtlvk
	fi
fi
MIN="com.apple.cfprefsd.xpc.daemon com.apple.cfprefsd.xpc.daemon.system com.apple.notifyd com.apple.configd_sim
	com.apple.runningboardd com.apple.lsd com.apple.containermanagerd com.apple.containermanagerd.system
	com.apple.mobilegestalt.xpc com.apple.UserEventAgent-System com.apple.securityd com.apple.trustd com.apple.syslogd
	com.apple.mobile.installd com.apple.systemstatusd com.apple.distnoted.xpc.daemon com.apple.tccd
	com.apple.fontservicesd com.apple.iconservices.iconservicesagent com.apple.pluginkit.pkd
	com.apple.cloudd com.apple.diagnosticd com.apple.nsurlsessiond com.apple.appprotectiond com.apple.logd com.apple.logd_helper"
# x86Sim: lean UI set (every arm64 process costs 150-450 MB under the JIT). No chronod (widget extensions, +~0.8 GB);
# A64_JOBS=full adds it (A64_KEEP_WIDGETS=1 keeps the home widgets).
# A64_JOBS=slim drops sleepd + usernotificationsd (~400-450 MB RSS each under the JIT); home + one app
# does not need them. Default std keeps them for cold-boot stability (BKS XPC). A64_SLIM=1 (default)
# parks Spotlight / WidgetRenderer before dyld (X86SIM_A64_SLIM_PARK). Without cloudd+diagnosticd
# in the job set, securityd busy-retries those Mach lookups (~1.9 cores idle). Those two stay
# runnable (not parked): a parked MachServices daemon accepts the lookup then hangs clients forever.
# nsurlsessiond: without it cloudd busy-retries getActiveSessionIdentifiers (~70% of a core + huge log).
# logd + logd_helper (on demand): the log store (data/var/db/diagnostics, uuidtext). Installed apps log into their
# firehose buffer as on Apple's simulator (simshim keeps os_log on for them only) and read it back with OSLogStore
# (scope .currentProcessIdentifier: OSLog's OSLogService reads logd's store). logd asks logd_helper to harvest each
# sender's UUID text (format strings; the dyld cache's at boot): without it every harvest failed ("Error connecting to
# logd_helper") and stored entries came back without their messages ("<compose failure [shared UUID]>"). ~15 MB each.
# appprotectiond (Speed 5): without it SpringBoard's ServerBackedClientPolicyStore retries com.apple.appprotectiond.read
# ~5x/s for the whole boot (on-demand, EnablePressuredExit: idle cost only once looked up).
# openurl: com.x86sim.openurl (arm64 build) so simtouch.py app/openurl works on the a64 device.
# InputUI (Speed 12): the keyboard service (LaunchAngel, on demand: started at SpringBoard's first osservice request).
# Without the job SpringBoard's bootstrap of osservice<com.apple.InputUI> fails ~60 times per boot and text fields get no
# keyboard. assistantd (Apple's plist since Speed 26) serves dictation and settings: without them each failed dictation availability
# check posts "availability changed", the keyboard dock (mic key) re-checks, and the app's main thread spins at 100%
# from the first text field tap, so InputUI's keyboard arbiter times the app out and no keyboard appears.
# assetsd (on demand): the photo library; without it Photos throws in its library view's viewDidLoad.
# geod + navd (Speed 15, on demand): Maps' GeoServices and navigation services. Without them Maps retried both lookups
# without backoff (~85% CPU backgrounded); Speed 14 no-op patched the retry instead, which turned the features off.
# mapssyncd (on demand): Maps' synced places (com.apple.Maps.MapsSync.store, a Core Data store over XPC). Without it
# navd's store lookups failed every 3 s ("Connection init failed at lookup with error 3 - No such process").
# campo (Speed 16): the Siri UI (Campo.app LaunchAngel, launched by RunningBoard as osservice<com.apple.campo> on the
# Siri tap; mksimdevice puts angels where launchd_sim classifies them as angels, see there).
# PosterBoard (Speed 17, on-demand angel): the wallpaper. On a device without a poster store, SpringBoard asks for it and
# it builds the store and selects MercuryPoster for the lock/home screen, as a real sim's first boot does (checked
# against the Mac's iOS 27 devices). Once a poster is chosen SpringBoard hosts that one MercuryPoster extension itself
# (~167 MB PSS before Speed 17's AOT training). FULLUI adds chronod (widgets).
# financed + passd (Speed 20, feature "wallet"): Wallet's FinanceKit opens its Core Data store over XPC from financed;
# without it Wallet trapped ("Could not create CoreDataStore"). healthd/healthappd/finhealthd (feature "health"): on demand.
# medialibraryd (Speed 22, on demand): the music library (com.apple.medialibraryd.xpc), which creates and migrates
# Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb. Without it the file stayed an empty database and Settings > General >
# About aborted counting Songs (ML3DatabaseException "no such table: _MLDatabaseProperties").
# StatusKitAgent (Speed 25, on demand): Focus/availability status. Without it opening a Messages conversation spun the
# main thread at 100% forever: IMCore asks StatusKit per chat item, each sync XPC call failed its lookup, and asked again.
# mobileassetd + assetsubscriptiond (Speed 26, on demand): Siri's UAF assets (Understanding, TTS, ASR: ~870 MB, as a Mac's
# iOS 27 simulator device downloads them). Without them assistantd finds no asset set and Siri says "Data for using Siri
# is downloading" forever; with them it downloads once into the device's data/private/var/MobileAsset.
# corespeechd, sirittsd, siriinferenced, siriknowledged, siriactionsd (Speed 26, on demand): Siri's speech capture,
# speech synthesis, inference, knowledge and actions services, which a Mac's simulator has on demand. Without corespeechd
# assistantd's recording failed at once ("Unable to prepareAudioProvider", kAFAssistantErrorDomain 221).
# searchd + corespotlightservice (Speed 26, on demand): the Spotlight index (com.apple.spotlight.SearchAgent / IndexAgent /
# IndexDelegateAgent) and Spotlight's resources (com.apple.MobileAsset.SpotlightResources). Without them Files' Recents
# showed "Content Unavailable ... unknown error" and apps' CoreSpotlight indexing failed its lookups.
# assistant_cdmd (Speed 27, on demand): Siri's dialog manager (com.apple.assistant.cdm), also the embedding service of
# Spotlight's query parser. Without it the parser's model load failed ("QU model load failed ... com.apple.assistant.cdm
# ... lookup"), its token stayed nil and Spotlight crashed on typing (SPSearchEntity / _CSSuggestionToken).
# nanoregistryd (Speed 27, on demand): the paired-device (Watch) registry, which a Mac's simulator runs. Without it
# NanoRegistry's sync query failed its lookup, NSXPCConnection ran the error handler inline and that dispatch_sync'd onto
# the queue the thread was on: a deadlock inside +[NRPairedDeviceRegistry sharedInstance]'s dispatch_once, which Maps'
# main thread waits on (GEO observer callback): Maps froze on a bare globe, no tiles, no input.
# installcoordinationd (apps feature, on demand): app installs (`x86sim install`, as simctl install: IXAppInstallCoordinator
# -> installcoordinationd -> installd -> LaunchServices). Without it every install failed at once ("Failed to create
# IXPlaceholder ... com.apple.installcoordinationd ... lookup error 3"). Idle cost none until an install looks it up.
# mobiletimerd (on demand): AlarmKit (com.apple.alarmkitservices) and the timer/alarm servers, which a Mac's simulator
# runs. Without it AlarmManager.requestAuthorization() never answered (Cadence's "Allow" did nothing).
# nanotimekitcompaniond (on demand: its Mach services start it) renders the Watch app's faces: without it Face Gallery's
# previews stayed empty (com.apple.nanotimekit.facesnapshotserver: no such process).
# CoreAuthentication.daemon, storekitd, quicklook.ThumbnailsAgent, midiserver-sim (sdkcov, on demand: no RunAtLoad /
# KeepAlive, so no idle cost): LocalAuthentication, StoreKit, QuickLook thumbnails and CoreMIDI, which a Mac's
# simulator serves. Without them LAContext.canEvaluatePolicy, Product.products(for:), QLThumbnailGenerator and
# MIDIClientCreate failed at once (lookup error 3 / serviceConnectionFailed / -10833), where Apple's simulator answers
# (tests/apps/sdkcov, checked against the Mac's iOS 27.2 24B8117). pasteboard.pasted, wcd, voiced and
# accessibility.axassetsd (on demand too): UIPasteboard (a string set was read back as nil), WatchConnectivity
# (WCSession.activate() never called back) and the speech voices (AVSpeechSynthesisVoice.speechVoices() was empty, so
# AVSpeechSynthesizer said nothing). locationd: feature "location" (SpringBoard looks it up at boot, ~94 MB); without it
# CMPedometer.isStepCountingAvailable() never returned. liveactivitiesd (on demand: com.apple.sessionservices): Live
# Activities; without it ActivityAuthorizationInfo().areActivitiesEnabled was false where Apple's simulator says true.
UI="com.apple.installcoordinationd com.apple.mobiletimerd com.apple.backboardd com.apple.SpringBoard com.apple.sleepd com.apple.TextInput.kbd com.apple.FileCoordination
	com.apple.usernotificationsd com.apple.InputUI com.apple.assistantd com.apple.assetsd com.apple.geod com.apple.navd com.apple.Maps.mapssyncd
	com.apple.campo com.apple.FileProvider com.apple.DesktopServicesHelper com.apple.PosterBoard com.apple.financed
	com.apple.passd com.apple.finhealthd com.apple.healthd com.apple.healthappd com.apple.medialibraryd
	com.apple.StatusKitAgent com.apple.mobileassetd com.apple.assetsubscriptiond com.apple.corespeechd com.apple.sirittsd
	com.apple.siriinferenced com.apple.siriknowledged com.apple.siriactionsd com.apple.searchd com.apple.corespotlightservice
	com.apple.assistant_cdmd com.apple.nanoregistryd com.apple.nanotimekitcompaniond
	com.apple.CoreAuthentication.daemon com.apple.storekitd com.apple.quicklook.ThumbnailsAgent com.apple.midiserver-sim
	com.apple.locationd com.apple.pasteboard.pasted com.apple.wcd com.apple.voiced com.apple.accessibility.axassetsd com.apple.liveactivitiesd"
UI_SLIM="com.apple.backboardd com.apple.SpringBoard com.apple.TextInput.kbd com.apple.FileCoordination com.apple.InputUI
	com.apple.assistantd"
FULLUI="com.apple.chronod"
# FileProvider (Speed 16, on demand: started when Files opens): fileproviderd + the sim2host stand-in (host/fpsim2host) give Files its Browse locations (iCloud Drive, On My iPhone, Recently Deleted). Without them Files only
# showed Recents. DesktopServicesHelper (Speed 17, on demand): Files lists On My iPhone (the LocalStorage domain, no
# extension in iOS 27) through DesktopServices, whose com.apple.DesktopServicesHelper.FileService does the file
# operations. Without it the folder stayed "Loading" and New Folder did nothing.
OUR_JOBS="com.x86sim.openurl=host/openurl/$A64_HOSTDIR/openurl
	com.x86sim.fpsim2host=host/fpsim2host/$A64_HOSTDIR/fpsim2host|mach:com.apple.FileProvider.sim2host"
# Platforms 1: tvOS. PineBoard is tvOS's SpringBoard (the home screen, "Top Shelf" and the app switcher); TVSystemUIService
# (angel) draws the system overlays (volume, Control Center). No sleepd, InputUI or nanoregistryd on tvOS.
# geod + mediaremoted (tvOS sdkcov round, on demand, both in Apple's tvOS simulator): without geod an app's MapKit
# retried com.apple.geod ~15000 times in one sdkcov run (and its SwiftUI Map built 19 views, Apple's 21); without
# mediaremoted NowPlaying's MediaSession.requestToBecomeApplicationPrimary() failed (internalFailure: no
# com.apple.mediaremoted.xpc). Both checked against Apple's tvOS 27.2 simulator (tests/apps/sdkcov/ref-mac.sh tvos).
TV_UI="com.apple.installcoordinationd com.apple.backboardd com.apple.Pineboard com.apple.TextInput.kbd
	com.apple.FileCoordination com.apple.usernotificationsd com.apple.assistantd com.apple.TVSystemUIService
	com.apple.PosterBoard com.apple.campo com.apple.splashboardd com.apple.MediaRemoteUI com.apple.assetsubscriptiond
	com.apple.mobileassetd com.apple.tvremoted com.apple.CoreAuthentication.daemon com.apple.storekitd
	com.apple.voiced com.apple.accessibility.axassetsd com.apple.geod com.apple.mediaremoted"
TV_UI_SLIM="com.apple.backboardd com.apple.Pineboard com.apple.TextInput.kbd com.apple.FileCoordination"
# Platforms 1: watchOS. Carousel is watchOS's SpringBoard (the watch face, the app grid, notifications); the watch face
# itself comes from nanotimekitd. nanoregistryd (+ its launch helper) holds the pairing state, unpaired for a watch booted
# on its own. No PosterBoard on watchOS.
# Both: assetsubscriptiond (+ mobileassetd) as on iOS: it makes data/private/var/db/assetsubscriptiond, whose
# UAFAssetSubscriptions.db assistantd opened 100-400 times a boot without it (sqlite "unable to open database file").
# Watch: geod / navd / mapssyncd (on demand) as on iOS: without them the watch's Maps drew its empty grid, no tiles.
# Watch + visionOS: ctkd, syncdefaultsd, accountsd, amsaccountsd (on demand, ~20-50 MB each once looked up), all in
# Apple's simulator (ref-mac.sh watchos / xros, 27.2): without them TKTokenWatcher listed no tokens (Apple's: ctkd's
# com.apple.setoken + setoken:aks), NSUbiquitousKeyValueStore.synchronize() was false (com.apple.kvsd) and StoreKit's
# Storefront.current was nil (Apple's: USA 143441, from the simulator's local App Store sandbox account in accountsd).
# visionOS also: locationd (feature "location": CLLocationManager.locationServicesEnabled() was false, Apple's true),
# FileProvider (on demand: NSFileProviderManager answered NSCocoaErrorDomain 4099, no fileproviderd; Apple's
# NSFileProviderErrorDomain -2001) and devicemanagementclient.managedappsd (on demand: ManagedApp's configuration stream
# yielded nil at once for lack of it; Apple's yields nothing for an unmanaged app). With these ATTrackingManager's
# status read notDetermined (0) as on Apple's, not restricted (1).
WATCH_UI="com.apple.installcoordinationd com.apple.backboardd com.apple.Carousel com.apple.sleepd com.apple.TextInput.kbd
	com.apple.FileCoordination com.apple.usernotificationsd com.apple.assistantd com.apple.campo com.apple.splashboardd
	com.apple.nanoregistryd com.apple.nanoregistrylaunchd com.apple.nanotimekitd com.apple.carouselecomoded
	com.apple.assetsubscriptiond com.apple.mobileassetd com.apple.geod com.apple.navd com.apple.Maps.mapssyncd
	com.apple.CoreAuthentication.daemon com.apple.storekitd com.apple.quicklook.ThumbnailsAgent com.apple.voiced
	com.apple.accessibility.axassetsd com.apple.wcd com.apple.locationd com.apple.healthd
	com.apple.ctkd com.apple.syncdefaultsd com.apple.accountsd com.apple.amsaccountsd"
WATCH_UI_SLIM="com.apple.backboardd com.apple.Carousel com.apple.TextInput.kbd com.apple.FileCoordination
	com.apple.nanoregistryd com.apple.nanotimekitd"
# Platforms 2: visionOS. SurfBoard is its SpringBoard; vhmdd (the simulator's virtual head-mounted display,
# com.apple.vhmdd-sim) and wakeboardd (the hmd presentable / post-process server) put the room on the screen;
# pointeruid is the look-and-pinch pointer. RealityEnvironment (a LaunchAngel) is the room itself and hosts
# com.apple.surfboard.environmentservice: without it SurfBoard aborted in -[SFBSEnvironmentService
# addEnvironmentsObserver:] ("Value for 'endpoint' was unexpectedly nil"). The rest as on iOS, including the on-demand
# services sdkcov needs (searchd + corespotlightservice, CoreAuthentication.daemon ... axassetsd, as above). chronod
# (WidgetCenter) stays the "widgets" feature as on iOS: on visionOS SurfBoard's RealityWidgets starts it at boot and it
# runs the room's widget extensions (Calendar, News, ...): ~350 MB.
XR_UI="com.apple.installcoordinationd com.apple.backboardd com.apple.SurfBoard com.apple.vhmdd com.apple.wakeboardd
	com.apple.RealityEnvironment
	com.apple.PointerUI.pointeruid com.apple.sleepd com.apple.TextInput.kbd com.apple.FileCoordination
	com.apple.usernotificationsd com.apple.assistantd com.apple.splashboardd com.apple.assetsubscriptiond
	com.apple.mobileassetd com.apple.searchd com.apple.corespotlightservice
	com.apple.CoreAuthentication.daemon com.apple.storekitd com.apple.quicklook.ThumbnailsAgent com.apple.midiserver-sim
	com.apple.pasteboard.pasted com.apple.wcd com.apple.voiced com.apple.accessibility.axassetsd
	com.apple.ctkd com.apple.syncdefaultsd com.apple.accountsd com.apple.amsaccountsd
	com.apple.locationd com.apple.FileProvider com.apple.devicemanagementclient.managedappsd"
XR_UI_SLIM="com.apple.backboardd com.apple.SurfBoard com.apple.vhmdd com.apple.wakeboardd com.apple.RealityEnvironment com.apple.TextInput.kbd
	com.apple.FileCoordination"
# No fpsim2host on tvOS / watchOS: their FileProvider has no FPSimulatorSupportInterface (no Files app), so it exited 1
# at every boot.
case $A64_PLATFORM in
	tvos) UI=$TV_UI; UI_SLIM=$TV_UI_SLIM; FULLUI=; OUR_JOBS="com.x86sim.openurl=host/openurl/$A64_HOSTDIR/openurl" ;;
	watchos) UI=$WATCH_UI; UI_SLIM=$WATCH_UI_SLIM; FULLUI=; OUR_JOBS="com.x86sim.openurl=host/openurl/$A64_HOSTDIR/openurl" ;;
	xros) UI=$XR_UI; UI_SLIM=$XR_UI_SLIM; FULLUI=; OUR_JOBS="com.x86sim.openurl=host/openurl/$A64_HOSTDIR/openurl" ;;
esac
case "${A64_JOBS:-std}" in
	min) JOBS="$MIN $OUR_JOBS" ;;
	slim) JOBS="$MIN $UI_SLIM $OUR_JOBS" ;;
	full) JOBS="$MIN $UI $FULLUI $OUR_JOBS" ;;
	*) JOBS="$MIN $UI $OUR_JOBS" ;;
esac
# Speed 18: the device's feature toggles ($D/features.json; definitions, costs and presets in features-def.json, edited
# by tools/launcher: x86sim-aot features, the launcher GUI, x86sim-mcp). A job is left out only when every feature
# listing it is off; boot-critical jobs are never listed. Applied at boot, so changes take effect at the next boot.
eval "$(python3 - "$D/features.json" "$X/cli/libexec/arm64/features-def.json" "$D" <<'PY'
import glob, json, os, plistlib, sys
try:
	prof = json.load(open(sys.argv[1])).get("features", {})
except Exception:
	prof = {}
d = json.load(open(sys.argv[2]))["features"]
on = {f["id"]: prof.get(f["id"], f.get("default", False)) for f in d}
# RAM 15: with the wallpaper off SpringBoard shows the poster's saved snapshot (RuntimeSnapshot-<hardware id>-home), which
# PosterKit keys by the screen. A phone made from another model's data (every new phone copies the main phone's) has
# none for its own screen and its home was black (iPhone 18 Pro Max from an iPhone 17's data). Such a boot runs the
# wallpaper's jobs once: PosterBoard renders and saves this screen's snapshot, later boots find it and stay without.
note = ""
if not on.get("wallpaper"):
	env = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(sys.argv[3], "sim.env")) if "=" in l)
	try:
		want = {(int(float(env["SIMULATOR_MAINSCREEN_WIDTH"])), int(float(env["SIMULATOR_MAINSCREEN_HEIGHT"])))}
	except (KeyError, ValueError):
		want = set()
	want |= {(h, w) for w, h in want}
	have = set()
	for m in glob.glob(os.path.join(sys.argv[3], "data/Library/Application Support/PRBPosterExtensionDataStore/*/Extensions/*/configurations/*/versions/*/RuntimeSnapshotMetadata-*-home.plist")):
		try:
			md = plistlib.load(open(m, "rb"))
			w, h = (float(x) for x in md["PUIPosterSnapshotBundleInfoKeyAssetSize"].strip("{}").split(","))
			sc = float(md.get("PUIPosterSnapshotBundleInfoKeyScale", 1))
			have.add((round(w * sc), round(h * sc)))
		except Exception:
			pass
	if want and not want & have:
		on["wallpaper"] = True
		note = "no wallpaper snapshot for this screen: PosterBoard runs this boot to make one"
keep = {j for f in d if on[f["id"]] for j in f.get("jobs", [])}
drop = sorted({j for f in d if not on[f["id"]] for j in f.get("jobs", [])} - keep)
add = [j for f in d if on[f["id"]] for j in f.get("add_jobs", [])]
park = [p for f in d if not on[f["id"]] for p in f.get("park", [])]
unpark = [p for f in d if on[f["id"]] for p in f.get("unpark", [])]
keepw = any(on[f["id"]] and f.get("keep_widgets") for f in d)
off = [f["id"] for f in d if on[f["id"]] != f.get("default", False) and not (note and f["id"] == "wallpaper")]
print(f'FEAT_NOTE="{note}"')
print(f'FEAT_DROP="{" ".join(drop)}" FEAT_ADD="{" ".join(add)}" FEAT_PARK="{",".join(park)}" FEAT_UNPARK="{" ".join(unpark)}" FEAT_KEEPW={int(keepw)} FEAT_CHANGED="{" ".join(off)}"')
PY
)"
[ -n "$FEAT_CHANGED" ] && echo "  features changed from the defaults: $FEAT_CHANGED"
[ -n "$FEAT_NOTE" ] && echo "  $FEAT_NOTE"
JOBS="$JOBS $FEAT_ADD"
[ "$FEAT_KEEPW" = 1 ] && A64_KEEP_WIDGETS=${A64_KEEP_WIDGETS:-1}
[ -n "$FEAT_PARK" ] && A64_PARK_EXTRA=${A64_PARK_EXTRA:+$A64_PARK_EXTRA,}$FEAT_PARK
# drop_job LABEL: leave a job out of JOBS, as a label or a label=executable entry. (A sed over the multi-line lists
# missed every job at the end of a line: the wallet, siri and maps features' financed, sirittsd and mapssyncd stayed.)
drop_job() {
	local j out=
	for j in $JOBS; do
		case $j in "$1"|"$1"=*) ;; *) out="$out $j" ;; esac
	done
	JOBS=$out
}
# A64_DROP="label ...": leave these jobs out (experiments)
for j in ${A64_DROP:-} $FEAT_DROP; do drop_job "$j"; done
# Platforms 1: the shared lists name iOS jobs a tvOS / watchOS runtime doesn't ship (cfprefsd's system daemon,
# containermanagerd.system, fontservicesd, appprotectiond, ...): those are left out there
if [ "$A64_PLATFORM" != ios ]; then
	left=
	for j in $JOBS; do
		case $j in *=*) continue ;; esac
		[ -f "$X86SIM_RUNTIME/System/Library/LaunchDaemons/$j.plist" ] || [ -f "$X86SIM_RUNTIME/System/Library/LaunchAngels/$j.plist" ] && continue
		drop_job "$j"; left="$left $j"
	done
	[ -n "$left" ] && echo "  not in this $A64_PLATFORM runtime:$left"
fi
# Speed 10: A64_CLONE_FROM=<device dir> starts a new device (no data/ yet) from a copy of that device's data/, like
# simctl clone. A fresh device's first boot otherwise builds the LaunchServices database (lsd) while SpringBoard's icon
# requests wait on it: ~80 s, and SpringBoard was killed and relaunched at ~90 s (home after ~5 min). The store refers
# to the apps' data containers, so the whole data/ is copied (reflinks), without logs, run state, tmp and sockets.
if [ -n "${A64_CLONE_FROM:-}" ] && [ ! -d "$D/data" ] && [ -d "$A64_CLONE_FROM/data/var/db/lsd" ]; then
	mkdir -p "$D"
	cp -a --reflink=auto "$A64_CLONE_FROM/data" "$D/data" || exit 1
	rm -rf "$D/data/var/log" "$D/data/var/run" "$D/data/tmp" "$D/data/simhid.sock" "$D/data/framebuffer.bgra"
	mkdir -p "$D/data/var/log" "$D/data/var/run" "$D/data/tmp"
	echo "  cloned data/ from $A64_CLONE_FROM"
fi
# Speed 21: os_log DT mode (formatted text of every log call on the job's stderr log, and a stream to diagnosticd) is
# off by default: it was ~25% of SpringBoard's CPU per tap (0.84 -> 0.61 CPU-s; tap response 0.57 -> 0.45 s). Real iOS
# never formats on the send path. X86SIM_NODT= (empty) brings the per-job os_log text back, X86SIM_NODT=all,-<label>
# for one job; x86sim-stderr-progs and X86SIM_OSLOG still work per process.
X86SIM_NODT=${X86SIM_NODT-all} X86SIM_JOBLOG=1 python3 cli/libexec/mksimdevice.py "$D" $JOBS "$@" > /dev/null || exit 1
# Speed 8: the container gets a private /dev/shm (X86SIM_PRIVATE_SHM, darlingserver): its remount no longer stacks a
# tmpfs over the host's /dev/shm, and two devices' shm objects stay apart. The frame ring is written to
# /run/user/<uid> (sim.env SIMFB_RING); $SIMFB_RING_LINUX (default /dev/shm/x86sim-a64-simfb.ring) links to it.
export X86SIM_PRIVATE_SHM=1
# Speed 28: the AOT image's huge-page copy (libarm64jit, /tmp/x86sim-a64-img): a boot retries a copy the last one
# dropped for lack of 2 MB pages.
rm -f /tmp/x86sim-a64-img/*.small 2>/dev/null
RING=$(sed -n 's#^SIMFB_RING=/Volumes/SystemRoot##p' "$D/sim.env")
# One /dev/shm link per phone, named after its ring (the launcher's SIMFB_RING_LINUX). A SIMFB_RING_LINUX naming another
# phone's link (e.g. the generic default inherited from the environment) is left alone: re-pointing it made the main
# phone's viewers and the gate read a second phone's screen.
if [ -n "$RING" ]; then
	ln -sfn "$RING" "/dev/shm/$(basename "$RING")"
	if [ -n "${SIMFB_RING_LINUX:-}" ] && [ "$RING" != "$SIMFB_RING_LINUX" ] && [ "$(basename "$SIMFB_RING_LINUX")" = "$(basename "$RING")" ]; then
		ln -sfn "$RING" "$SIMFB_RING_LINUX"
	fi
fi
# Strip home-screen / Today widgets so SpringBoard does not demand WidgetRenderer (even with park).
# A64_KEEP_WIDGETS=1 leaves IconState alone (full profile / wallpaper experiments).
# Platforms 1: SpringBoard's (iOS) only
if [ "${A64_KEEP_WIDGETS:-0}" != 1 ] && [ "$A64_PLATFORM" = ios ]; then
	python3 - "$D/data/Library/SpringBoard" <<'PY'
import os, sys, plistlib
d = sys.argv[1]
os.makedirs(d, exist_ok=True)

def strip(obj):
	if isinstance(obj, list):
		out = []
		for x in obj:
			# RAM 2: also the Shortcuts widget (elementType shortcutsSingle / shortcutsStack, no widgetIdentifier),
			# and any other custom grid element that is not a folder or a widget stack (all are widgets)
			if isinstance(x, dict) and (x.get("elementType") in ("widget", "shortcutsSingle", "shortcutsStack")
					or "widgetIdentifier" in x
					or (x.get("iconType") == "custom" and x.get("elementType") not in (None, "folder", "stack"))):
				continue
			# drop emptied widget stacks / custom placeholders
			if isinstance(x, dict) and x.get("iconType") == "custom" and not x.get("elements") and "widgetIdentifier" not in x and x.get("elementType") != "folder":
				# keep if it still has meaningful keys beyond stack chrome
				keys = set(x) - {"allowsExternalSuggestions","allowsSuggestions","displayIdentifier","elements","gridSize","iconType","uniqueIdentifier"}
				if not keys:
					continue
			sx = strip(x)
			if isinstance(sx, dict) and sx.get("elements") == [] and sx.get("iconType") == "custom":
				continue
			out.append(sx)
		return out
	if isinstance(obj, dict):
		return {k: strip(v) for k, v in obj.items()}
	return obj

# Speed 9: a fresh device has no IconState yet, so SpringBoard wrote its default layout on the first boot, with the
# Maps and Calendar widgets (two blank white tiles: no chronod / WidgetRenderer). Seed the same layout without widgets.
seed = os.path.join(d, "IconState.plist")
if not os.path.exists(seed):
	import uuid
	u = lambda: str(uuid.uuid4()).upper()
	utilities = {"defaultDisplayName": "Utilities", "displayName": "Utilities", "listType": "folder",
		"iconLists": [["com.apple.shortcuts", "com.apple.Passwords"]], "listUniqueIdentifiers": [u()], "uniqueIdentifier": u()}
	layout = {"buttonBar": ["com.apple.mobilesafari", "com.apple.MobileSMS"], "defaultDisplayName": "Folder", "displayName": "Folder",
		"iconLists": [["com.apple.mobilecal", "com.apple.mobileslideshow", "com.apple.Maps", "com.apple.news", "com.apple.Health",
			"com.apple.Passbook", "com.apple.SiriApp", "com.apple.Preferences"],
			["com.apple.Fitness", "com.apple.Bridge", "com.apple.reminders", "com.apple.DocumentsApp", "com.apple.Preview", utilities,
			"com.apple.MobileAddressBook"]],
		"ignored": ["com.apple.TVRemoteApp"], "listUniqueIdentifiers": [u(), u()], "today": [], "uniqueIdentifier": u()}
	with open(seed, "wb") as f:
		plistlib.dump(layout, f)
	print("  seeded a widget-free IconState.plist (fresh device)", flush=True)

for name in ("IconState.plist", "DesiredIconState.plist"):
	path = os.path.join(d, name)
	if not os.path.exists(path):
		continue
	with open(path, "rb") as f:
		data = plistlib.load(f)
	with open(path, "wb") as f:
		plistlib.dump(strip(data), f)
	print(f"  stripped widgets from {name}", flush=True)
PY
fi
UDID=$(sed -n 's/^SIMULATOR_UDID=//p' "$D/sim.env")
L=$DPREFIX/private/var/tmp/com.apple.CoreSimulator.SimDevice.$UDID/launchd.log
rm -f "$L" "$L".1 "$L".2
R="/Volumes/SystemRoot$X86SIM_RUNTIME"
# Default slim park list: path substrings matched in arm64host before dyld. A64_SLIM=0 clears it.
# Do not park MachServices daemons (cloudd, diagnosticd): lookup succeeds then clients block forever
# on the unreplied port. Those are in MIN so securityd's lookups resolve to real (lean) processes.
# Speed 15: Spotlight is no longer parked (the home screen's Search pill showed nothing). It costs ~320 MB PSS.
# A64_PARK overrides the list (old default: Spotlight.app,WidgetRenderer).
PARK_LIST=${A64_PARK-WidgetRenderer}${A64_PARK_EXTRA:+,$A64_PARK_EXTRA}
for u in $FEAT_UNPARK; do PARK_LIST=$(echo ",$PARK_LIST," | sed "s/,$u,/,/g; s/^,//; s/,$//"); done
if [ "${A64_SLIM:-1}" = 1 ] && [ "${A64_JOBS:-std}" != full ]; then
	if grep -q '^X86SIM_A64_SLIM_PARK=' "$D/sim.env" 2>/dev/null; then
		sed -i "s|^X86SIM_A64_SLIM_PARK=.*|X86SIM_A64_SLIM_PARK=$PARK_LIST|" "$D/sim.env"
	else
		echo "X86SIM_A64_SLIM_PARK=$PARK_LIST" >>"$D/sim.env"
	fi
	# File fallback: launchd does not pass sim.env into job environ; arm64host reads this path.
	echo "$PARK_LIST" > "$X86SIM_SCRATCH/a64-slim-park"
else
	rm -f "$X86SIM_SCRATCH/a64-slim-park"
fi
ENVS=$(sed 's/^/"/; s/$/"/' "$D/sim.env" | tr '\n' ' ')
ENVS="$ENVS ${A64_ENV:-}"   # A64_ENV: extra K=V for launchd_sim (e.g. X86SIM_A64_TRACE=1)
# stop only this prefix's container. Its launchers (darling shell, and the `timeout` that holds the mDNSResponder
# link) are found by their command line (this device's path, this state dir, or tests/arm64/run.sh's a64home), so
# the x86_64 container's are never touched. Then darling shutdown, then a sweep of what it misses: darling shutdown
# SIGKILLs darlingserver and the first entry of /proc/<darlingserver>/task/<main>/children only, and launchd is often
# not a child of the main thread (or the entry is another process), so launchd -- pid 1 of the container's pid
# namespace -- survived, reparented to the session's subreaper, with every daemon and app of the old boot under it.
# All of these run as the user: plain kill works where sudo is not available.
# A namespace init is this prefix's when its mount table has the prefix overlay mounted at exactly $DPREFIX.
prefix_procs() {
	local d p
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		case "$(cat "$d/comm" 2>/dev/null)" in
		darlingserver)
			tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "^darlingserver $DPREFIX " && echo "$p" ;;
		mldr)  # Darling processes run under mldr: launchd is comm mldr
			[ "$(awk '/^NSpid:/{print $NF}' "$d/status" 2>/dev/null)" = 1 ] || continue
			awk -v m="$DPREFIX" '$5 == m { f = 1 } END { exit !f }' "$d/mountinfo" 2>/dev/null && echo "$p" ;;
		esac
	done
}
stop_prefix() {
	local pids="" d p i left
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		[ -r "$d/cmdline" ] || continue
		tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qxF "$X86SIM_DARLING" || continue
		tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -q -e "$D/" -e "$ST/" -e "/a64home" && pids="$pids $p"
	done
	if [ -n "$pids" ]; then
		kill -9 $pids 2>/dev/null
		# the setuid darling launchers (real uid 0) refuse the user's signal; they exit with their container
		x86sim_sudo -n kill -9 $pids 2>/dev/null </dev/null
	fi
	# an earlier boot's helper subshells (the 90 s AOT status check, the 60 s prefetch snapshot) outlived the stop,
	# and the launcher showed the phone "starting" while one ran: end those of this device (not this script's)
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		[ "$p" = $$ ] && continue
		[ "$(cat "$d/comm" 2>/dev/null)" = boot-a64.sh ] || continue
		tr '\0' '\n' 2>/dev/null < "$d/environ" | grep -qxF "A64_DEVICE=$D" || continue
		tr '\0' '\n' 2>/dev/null < "$d/environ" | grep -qx 'A64_STOP_ONLY=1' && continue
		pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
	done
	timeout 30 "$X86SIM_DARLING" shutdown 2>/dev/null
	for i in $(seq 1 50); do
		left=$(prefix_procs)
		[ -z "$left" ] && break
		[ "$i" = 1 ] || [ "$i" = 20 ] && echo "boot-a64: ending leftover container processes of $DPREFIX:" $left >&2
		kill -9 $left 2>/dev/null
		sleep 0.1
	done
	local ip; ip=$(cat "$DPREFIX/.init.pid" 2>/dev/null)
	if [ -z "$ip" ] || [ ! -d "/proc/$ip" ] || grep -q "^State:.*Z" "/proc/$ip/status" 2>/dev/null; then
		rm -f "$DPREFIX/.init.pid" "$DPREFIX/.darlingserver.sock"
	fi
}
stop_prefix
# Speed 23: jetsam stand-in (cli/libexec/jetsam.py): reclaims extensions and older
# background apps that RunningBoard keeps suspended, as a device's memorystatus does. Without it every poster
# extension PosterBoard updated at boot (12 of them, ~470 MB PSS) and every app opened stayed resident.
# X86SIM_JETSAM=0: off. Scoped to this prefix's container (jetsam.container_ns).
# The boot's host helpers (jetsam, mDNS, simaudio): stopped before a boot and when a timed boot ends.
stop_helpers() {
	[ -f "$ST/jetsam.pid" ] && kill "$(cat "$ST/jetsam.pid")" 2>/dev/null
	rm -f "$ST/jetsam.pid"
	[ -f "$ST/mdns.pid" ] && kill "$(cat "$ST/mdns.pid")" 2>/dev/null
	# and one whose pidfile a later boot overwrote (two from the day before were still serving var/run-a64); matched by
	# the state dir's name so one started with a relative path (var/run-a64-<name>) is found too
	pkill -f "mdnsresponder.py .*/$(basename "$ST")/mDNSResponder\$" 2>/dev/null
	rm -f "$ST/mdns.pid" "$ST/mDNSResponder"
	[ -f "$ST/simaudio.pid" ] && kill "$(cat "$ST/simaudio.pid")" 2>/dev/null
	rm -f "$ST/simaudio.pid"
}
stop_helpers
# Speed 10: A64_STOP_ONLY=1 stops this device: the container, and its mtlvk unless another phone renders through it
# (A64_KEEP_MTLVK=1: the container only -- the launcher's restart keeps the GPU helper, its stop ends it itself)
if [ "${A64_STOP_ONLY:-0}" = 1 ]; then
	[ "${A64_KEEP_MTLVK:-0}" = 1 ] || stop_a64_mtlvk
	# RAM 15: the frame rings live in /run/user (tmpfs, RAM): a stopped phone's stayed resident (4 frames each, 50 MB
	# for an iPhone 17, 140 MB for the Duo's two screens) until its next boot replaced them. The next boot makes new ones.
	R=$(sed -n 's#^SIMFB_RING=/Volumes/SystemRoot##p' "$D/sim.env" 2>/dev/null)
	[ -n "$R" ] && rm -f "$R" "${R%.ring}"-[0-9].ring
	# a device path too long for a Unix socket: simhid's socket is in /run/user too, data/simhid.sock links to it
	[ -L "$D/data/simhid.sock" ] && rm -f "$(readlink "$D/data/simhid.sock")" "$D/data/simhid.sock"
	exit 0
fi
# the marks of the last boot (Darling pids are reused)
rm -rf "$DPREFIX/private/var/run/x86sim-suspended" "$DPREFIX/private/var/run/x86sim-jetsam" \
	"$DPREFIX/private/var/run/x86sim-unsupported.log"
# libarm64jit's per-process logs (X86SIM_A64_LOG, <exe>.<pid>.log): the last boot's are kept as x86sim-a64.prev, older
# ones go. They were never removed: ~100 files a boot, 7000 files / 253 MB in a day on an sdkcov device.
if [ -d "$DPREFIX/private/var/tmp/x86sim-a64" ]; then
	rm -rf "$DPREFIX/private/var/tmp/x86sim-a64.prev"
	mv "$DPREFIX/private/var/tmp/x86sim-a64" "$DPREFIX/private/var/tmp/x86sim-a64.prev"
	mkdir -p "$DPREFIX/private/var/tmp/x86sim-a64"
fi
# the Darling pieces our build fixed (libsystem_kernel ...), also into a recreated prefix: cli/libexec/arm64/prefix-heal.sh
[ "${A64_PREFIX_HEAL:-1}" != 0 ] && sh "$X/cli/libexec/arm64/prefix-heal.sh" "$DPREFIX"
# Speed 27: frameworks a Mac host has in /System/Library/Frameworks that the simulator opens there by absolute path (not
# under its runtime root): CoreSpotlight reads its localized strings
# from [NSBundle bundleWithPath:@"/System/Library/Frameworks/CoreSpotlight.framework"]. Without it every CoreSpotlight string was nil (PHOTO_TOKEN) and
# Spotlight crashed on the first typed letter ("attempt to insert nil object" in -[_CSSuggestionToken init...]). The
# booted runtime's own copy (its real path) is linked in the prefix's upper layer at every boot.
for fw in CoreSpotlight; do
	mkdir -p "$DPREFIX/System/Library/Frameworks"
	ln -sfn "/Volumes/SystemRoot$(realpath "$X86SIM_RUNTIME")/System/Library/Frameworks/$fw.framework" \
		"$DPREFIX/System/Library/Frameworks/$fw.framework"
done
# Private frameworks too: TextToSpeech opens [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/
# TextToSpeechMauiSupport.framework"] (the built-in voices, TTSResources): on a Mac that is the host's copy. Without it
# AVSpeechSynthesisVoice.speechVoices() was empty (axassetsd's VoiceDB: OnDiskVoiceError) and AVSpeechSynthesizer silent.
for fw in TextToSpeechMauiSupport; do
	mkdir -p "$DPREFIX/System/Library/PrivateFrameworks"
	ln -sfn "/Volumes/SystemRoot$(realpath "$X86SIM_RUNTIME")/System/Library/PrivateFrameworks/$fw.framework" \
		"$DPREFIX/System/Library/PrivateFrameworks/$fw.framework"
done
# The SF Symbols catalogs: CoreLocationUI's button drawing (and IconServices, SocialLayer) opens [NSBundle bundleWithPath:
# @"/System/Library/CoreServices/CoreGlyphs.bundle"], on a Mac the host's copy. Without it -[CLLocationButtonDrawing
# _computeImageMetrics] bailed before setting its size: CLLocationButton.sizeThatFits was 1x1 (Apple: 204x51).
for b in CoreGlyphs CoreGlyphsPriority CoreGlyphsPrivate; do
	[ -d "$X86SIM_RUNTIME/System/Library/CoreServices/$b.bundle" ] || continue
	mkdir -p "$DPREFIX/System/Library/CoreServices"
	ln -sfn "/Volumes/SystemRoot$(realpath "$X86SIM_RUNTIME")/System/Library/CoreServices/$b.bundle" \
		"$DPREFIX/System/Library/CoreServices/$b.bundle"
done
# Bundles Darling's own tree also has (a macOS stub, no resources): the Sign in with Apple button drawing takes its
# Apple logo PDF and strings from +[AKUIBundleProvider bundle] = [NSBundle bundleWithPath:@"/System/Library/
# PrivateFrameworks/AuthKitUI.framework"], on a Mac the host's copy. Here it was Darling's stub: no logo, and every app
# showing an ASAuthorizationAppleIDButton / SignInWithAppleButton aborted (assertion "page" in _DrawLogoPDFIntoContext).
# Darling's stub stays (its x86_64 binary): the runtime copy's entries it lacks are linked into a real directory in the
# prefix's upper layer, which the overlay merges with Darling's.
DLOWER=${X86SIM_DARLING_ROOT:-$X/darling-prefix/libexec/darling}
for fw in PrivateFrameworks/AuthKitUI; do
	src="$(realpath "$X86SIM_RUNTIME")/System/Library/$fw.framework" dst="$DPREFIX/System/Library/$fw.framework"
	[ -d "$src" ] || continue
	[ -L "$dst" ] && rm -f "$dst"
	mkdir -p "$dst"
	for e in "$src"/*; do
		[ -e "$DLOWER/System/Library/$fw.framework/${e##*/}" ] || ln -sfn "/Volumes/SystemRoot$e" "$dst/${e##*/}"
	done
done
# TextToSpeech's voice database (axassetsd, /var/mobile/Library/Accessibility/voicedb.sqlite) is refilled at every
# start by its loaders, each skipped when com.apple.SpeakSelection's PreferencesLastLoadedOn says it already loaded in
# this boot: the value is kern.boottime, which here is the Linux host's for every device boot. So after the first
# boot the rows were cleared and never reloaded: AVSpeechSynthesisVoice.speechVoices() empty. A device boot is a new
# boot for it: the marker goes.
python3 - "$D/data/Library/Preferences/com.apple.SpeakSelection.plist" <<'PY' 2>/dev/null
import plistlib, sys
try:
	d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
	sys.exit(0)
if d.pop("PreferencesLastLoadedOn", None) is not None:
	plistlib.dump(d, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)
PY
# Speed 27: and host data a Mac has in /System/Library (cli/libexec/arm64/fetch-macos-host.sh fetches it from the Mac
# into runtimes/macos-host): geod seeds its resource manifest from /System/Library/GeoServicesData/ResourceManifest.json;
# without it there was no active tile group and Maps drew a bare globe grid without ever requesting a tile.
for d in GeoServicesData; do
	if [ -d "$X/runtimes/macos-host/System/Library/$d" ]; then
		ln -sfn "/Volumes/SystemRoot$X/runtimes/macos-host/System/Library/$d" "$DPREFIX/System/Library/$d"
	else
		echo "  note: no runtimes/macos-host/System/Library/$d (cli/libexec/arm64/fetch-macos-host.sh): Maps has no tiles"
	fi
done
# Speed 27: the audio devices (what a Mac's CoreSimulator/coreaudiod provide): host/simaudio/arm64/libsimaudio.dylib in
# each process (mksimdevice, X86SIM_AUDIO) streams PCM to cli/libexec/simaudio.py (PipeWire). Without an input device
# Siri's recording failed at once (corespeechd: "siriInputSource 'sino'. No Input available", AudioQueue -66680 finding
# Default-InputOutput, prepareRecordForStream -11790) and Siri never got further.
if [ "${X86SIM_AUDIO:-0}" != 0 ]; then
	setsid python3 "$X/cli/libexec/simaudio.py" "$ST/simaudio.sock" > "$ST/simaudio.log" 2>&1 < /dev/null &
	echo $! > "$ST/simaudio.pid"
fi
if [ "${X86SIM_JETSAM:-1}" != 0 ]; then
	setsid python3 "$X/cli/libexec/jetsam.py" > "$ST/jetsam.log" 2>&1 < /dev/null &
	echo $! > "$ST/jetsam.pid"
fi
sleep 1

# Host zone name (no darling yet). The TZ link itself must run *inside* limited.sh so it does not birth
# darlingserver in the caller's cgroup (that was the Stage 2/3 escape: only timeout+darling stayed under MemoryMax).
TZNAME=$(readlink -f /etc/localtime 2>/dev/null | sed -n 's#^.*/zoneinfo/##p')
H="/Volumes/SystemRoot$X/host/simhost/simhost"

# Payload for `darling shell sh -c` — raw text so $ENVS quote tokens are only parsed by that inner sh.
A64_TIMEOUT=$([ "${A64_KEEP:-0}" = 1 ] && echo 86400 || echo $((SECS + 5)))
CMDFILE=$ST/simhost.cmd
# Speed 26: DNS. On a Mac the simulator's libsystem_dnssd talks to the host's mDNSResponder at /var/run/mDNSResponder;
# linux/mdnsd/mdnsresponder.py plays it. Without one every lookup failed with -1003
# (mobileassetd could not fetch Siri's assets, News/Spotlight/Settings search had no network). Own server per boot
# ($ST/mDNSResponder), linked into this container's /var/run. X86SIM_MDNS=0: none.
MDNS_LINK=
if [ "${X86SIM_MDNS:-1}" != 0 ]; then
	setsid python3 -I "$X/linux/mdnsd/mdnsresponder.py" "$ST/mDNSResponder" > "$ST/mdnsresponder.log" 2>&1 < /dev/null &
	echo $! > "$ST/mdns.pid"
	MDNS_LINK="ln -sf '/Volumes/SystemRoot$ST/mDNSResponder' /var/run/mDNSResponder;"
fi
# Platforms 1: tvOS / watchOS launchd_sim has only the system domain, which stays in bootstrap mode (every request of its
# jobs deferred) until the host's MIG 700: simhost sends it (host/simhost/simhost.c). A64_BOOTSTRAP_DONE=1: on iOS too
# (experiments; its jobs are in the user domain, which ends bootstrap mode itself).
BDONE=
if [ "$A64_PLATFORM" != ios ] || [ "${A64_BOOTSTRAP_DONE:-0}" = 1 ]; then
	BDONE="SIMHOST_BOOTSTRAP_DONE=1"
fi
cat > "$CMDFILE" <<CMDEOF
$MDNS_LINK $BDONE exec "$H" /usr/bin/env $ENVS "$R/sbin/launchd_sim" "/Volumes/SystemRoot$D/data/var/run/launchd_bootstrap.plist"
CMDEOF

# Speed 14: fixed placement of non-cache Mach-Os (libarm64jit; mkplacement.py): the jitcache dir gets the committed
# table when it has none (the table is part of the JIT cache key: the AOT image must be built with the same one)
JC=${X86SIM_A64_JITCACHE_DIR:-$X86SIM_SCRATCH/jitcache}
mkdir -p "$JC"
[ -f "$JC/placement.txt" ] || cp "$X/cli/libexec/arm64/placement-${A64_BUILD:-24A434}.txt" "$JC/placement.txt" 2>/dev/null
# Speed 14: the early set (pages in first-touch order up to ~home) is read in that order here, outside the IO-capped
# scope: ~1-2 s of sequential reads instead of ~10-20 s at 40 MB/s, competing with the boot's own faults. The rest
# (prefetch.hot) stays a capped WILLNEED inside the scope. A64_PREFETCH_EARLY_CAPPED=1: the early set capped too.
PF_INNER="$ST/prefetch.early $ST/prefetch.hot"
if [ "${A64_PREFETCH:-1}" != 0 ] && [ "${A64_PREFETCH_EARLY_CAPPED:-0}" != 1 ] && [ -f "$ST/prefetch.early" ]; then
	(python3 -I "$X/cli/libexec/arm64/prefetch.py" read "$ST/prefetch.early" > "$ST/prefetch-read.log" 2>&1 &)
	PF_INNER="$ST/prefetch.hot"
fi
(cli/libexec/limited.sh env \
	DPREFIX="$DPREFIX" \
	X86SIM_DARLING="$X86SIM_DARLING" \
	A64_TZNAME="$TZNAME" \
	A64_TIMEOUT="$A64_TIMEOUT" \
	A64_CMDFILE="$CMDFILE" \
	A64_PREFETCH_HOT="$([ "${A64_PREFETCH:-1}" != 0 ] && echo "$PF_INNER")" \
	"$X/cli/libexec/arm64/boot-inner.sh" > "$ST/lsim.out" 2>&1 &)
# Speed 18: 90 s in, check the chunked AOT image against this runtime / placement / codegen (tools/launcher x86sim-aot
# status, low priority) and note in $ST/aot-status.txt how many chunks need rebuilding: a translator rebuild with a new
# CODEGEN_VERSION, a runtime update or a newly placed app no longer silently boots without an image. The launcher
# offers the rebuild; X86SIM_AOT_AUTOUPDATE=1 runs `x86sim-aot update` (2 builders, nice 19, idle IO) right away.
AOTBIN=$X/tools/launcher/target/release/x86sim-aot
if [ -x "$AOTBIN" ]; then
	# Launch 1: and only once the phone is idle (its scope used under half a core over 5 s; at most 5 min more): the
	# check reads the image, its index and every training profile (~7 CPU s, ~12 s, GBs of IO, 1.8 GB RSS) and landed in
	# the middle of any app opened ~1.5 min after boot.
	(sleep 90
	 CGS=/sys/fs/cgroup$(awk -F: '/^0::/{print $NF; exit}' /proc/self/cgroup)/cpu.stat
	 for _ in $(seq 60); do
		u0=$(awk '/^usage_usec/{print $2}' "$CGS" 2>/dev/null) || break; [ -n "$u0" ] || break; sleep 5
		u1=$(awk '/^usage_usec/{print $2}' "$CGS" 2>/dev/null); [ $(( ${u1:-0} - u0 )) -lt 2500000 ] && break
	 done
	 nice -n 19 ionice -c 3 "$AOTBIN" --jc "$JC" --device "$D" status > "$ST/aot-status.txt" 2>&1
	 if [ "${X86SIM_AOT_AUTOUPDATE:-0}" = 1 ] && grep -q "need rebuilding" "$ST/aot-status.txt"; then
		"$AOTBIN" --jc "$JC" --device "$D" update --workers 2 > "$ST/aot-update.log" 2>&1
	 fi) < /dev/null > /dev/null 2>&1 &
fi
# Speed 11: 60 s in (home is up), record which ranges of the dyld cache and the AOT image this boot's processes
# have mapped in; the next boot prefetches them (boot-inner.sh). A64_PREFETCH=0: neither.
if [ "${A64_PREFETCH:-1}" != 0 ]; then
	# Speed 14: prefetch.early = the pages present up to A64_PREFETCH_EARLY_SECS (default 24, ~home), snapshotted
	# every 3 s and saved by first-touch time; prefetch.hot = everything mapped 60 s in (read after, capped)
	# (nullglob: before the image's first load there is no .map yet, and a literal "*.map" crashed the recording)
	shopt -s nullglob
	PF_FILES=("$X86SIM_RUNTIME"/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64* "$JC"/*.map "$JC"/*.map.idx)
	shopt -u nullglob
	pf_record() { python3 -I "$X/cli/libexec/arm64/prefetch.py" record "$1" "${PF_FILES[@]}"; }
	PF_ES=${A64_PREFETCH_EARLY_SECS:-24}
	# early: also every other mapped file of the runtime, the jitcache dir and the darling prefix (non-cache dylibs,
	# app executables, the .aot itself): what the boot otherwise faults in at the scope's 40 MB/s
	(nice -n 19 python3 -I "$X/cli/libexec/arm64/prefetch.py" record-seq "$ST/prefetch.early" "$PF_ES" 3 "${PF_FILES[@]}" \
		"$X86SIM_RUNTIME/" "$JC/" "$X/darling-prefix/"
	 sleep $((60 - PF_ES)); pf_record "$ST/prefetch.hot") > "$ST/prefetch.log" 2>&1 &
fi
sleep 3
(timeout $((SECS + 2)) tail -n +1 -F "$L" 2>/dev/null | grep --line-buffered -v -E "failed lookup|Last log repeated" > "$ST/launchd.log" &)
# a boot that hangs before home (black, every process idle): diagnostics + one restart (cli/libexec/arm64/bootwatch.sh)
[ "${A64_BOOTWATCH:-0}" = 1 ] && (bash "$X/cli/libexec/arm64/bootwatch.sh" "$D" "$ST" "$DPREFIX" < /dev/null > /dev/null 2>&1 &)
sleep "$SECS"
echo "== spawns/exits"
grep -E "Successfully spawned|exited due|exited with" "$ST/launchd.log" | sed "s/^[0-9-]* [0-9:.]* //; s/\[[0-9]*\]//g; s/ because.*//; s/, ran for.*//; s/<Notice>: //" | sort | uniq -c | cut -c1-140
echo "== lsim.out (tail)"; tail -5 "$ST/lsim.out"
# Report cgroup containment
echo "== cgroup containment"
# This boot's own scope (the one this script runs in); a phone's processes are those of its Darling prefix (as
# boot-inner.sh's join_prefix_cgroup matches them). Before, the scope with the most memory and every process of any
# phone counted: another running phone's processes were reported as OUT of this one.
SCOPE=$(awk -F: '/^0::/{print $NF; exit}' /proc/$$/cgroup 2>/dev/null); SCOPE=${SCOPE##*/}
case $SCOPE in x86sim-*.scope) ;; *) SCOPE="" ;; esac
if [ -n "$SCOPE" ]; then
	CG=$(systemctl --user show "$SCOPE" -p ControlGroup --value 2>/dev/null)
	echo "scope=$SCOPE memory.current=$(cat /sys/fs/cgroup$CG/memory.current 2>/dev/null) memory.max=$(cat /sys/fs/cgroup$CG/memory.max 2>/dev/null)"
	in=0; out=0; in_rss=0; out_rss=0
	for p in /proc/[0-9]*; do
		[ -r "$p/environ" ] || continue
		grep -qsazxF -e "DPREFIX=$DPREFIX" -e "A64_DPREFIX=$DPREFIX" -e "__mldr_sockpath=$DPREFIX/.darlingserver.sock" "$p/environ" 2>/dev/null || continue
		cg=$(awk -F: '/^0::/{print $NF; exit}' "$p/cgroup" 2>/dev/null)
		rss=$(awk '/^VmRSS/{print $2}' "$p/status" 2>/dev/null); rss=${rss:-0}
		case "$cg" in
			*"$SCOPE"*) in=$((in+1)); in_rss=$((in_rss+rss)) ;;
			*) out=$((out+1)); out_rss=$((out_rss+rss)); echo "  OUT pid=${p#/proc/} rss=$((rss/1024))MB cg=$cg" ;;
		esac
	done
	# darlingserver for this prefix
	for p in /proc/[0-9]*; do
		[ -r "$p/cmdline" ] || continue
		tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -qF "darlingserver $DPREFIX " || continue
		cg=$(awk -F: '/^0::/{print $NF; exit}' "$p/cgroup" 2>/dev/null)
		rss=$(awk '/^VmRSS/{print $2}' "$p/status" 2>/dev/null); rss=${rss:-0}
		case "$cg" in
			*"$SCOPE"*) echo "  darlingserver IN rss=$((rss/1024))MB" ;;
			*) echo "  darlingserver OUT rss=$((rss/1024))MB cg=$cg"; out=$((out+1)); out_rss=$((out_rss+rss)) ;;
		esac
	done
	echo "guests IN=$in ($((in_rss/1024)) MB) OUT=$out ($((out_rss/1024)) MB)"
fi
# A64_SLIM=1 (default): report parked helpers (X86SIM_A64_SLIM_PARK). Parking replaced a kill loop (slim-reaper.sh):
# SpringBoard holds RunningBoard assertions and relaunched them within ~1 s, which burned a core in xpcproxy_sim and
# never saved memory.
if [ "${A64_SLIM:-1}" = 1 ]; then
	echo "== slim park status"
	parked=""
	for p in /proc/[0-9]*; do
		pid=${p#/proc/}
		[ -r "$p/comm" ] || continue
		c=$(cat "$p/comm" 2>/dev/null) || continue
		case "$c" in
			Spotlight|WidgetRenderer_*|pkd)
				# launchd does not put SLIM_PARK in job environ; detect via pause + tiny RSS
				w=$(cat "$p/wchan" 2>/dev/null || true)
				r=$(awk '/^VmRSS/{print $2}' "$p/status" 2>/dev/null); r=${r:-0}
				case "$w" in
					*pause*)
						echo "  $c pid=$pid rss_mb=$((r/1024)) (parked)"
						parked="$parked $c"
						;;
					*)
						[ "$r" -lt 51200 ] && echo "  $c pid=$pid rss_mb=$((r/1024)) wchan=$w"
						;;
				esac
				;;
		esac
	done
	echo "  parked:$parked"
fi
# A64_KEEP=1: leave the device running (the container outlives the launcher's timeout); else stop this prefix
if [ "${A64_KEEP:-0}" != 1 ]; then
	stop_prefix
	stop_a64_mtlvk
	stop_helpers   # the mDNS server outlived every timed boot (test devices left one each)
fi
