// x86Sim: libsimaudio.dylib, the simulator's audio devices on a Linux host.
//
// On a Mac the simulator's CoreAudio is only a HAL *client*: HALC_ProxySystem looks up the host's coreaudiod
// (bootstrap_look_up2 "com.apple.audio.audiohald", forwarded by launchd_sim to the Mac's bootstrap) and every
// device, IOProc and IO cycle is the Mac's (AudioHardwareStartServer is an empty stub in the simulator's
// CoreAudio). Linux has no coreaudiod and its MIG protocol is private, so this library stands in for the host HAL
// inside each process instead: it interposes CoreAudio's public HAL API (AudioObject*, AudioDevice*, the only
// entry points AudioToolbox/AVFAudio use) and presents one output and one input device. Their IO
// thread runs the clients' IOProcs on a clock and moves PCM over a Unix socket to cli/libexec/simaudio.py on Linux,
// which plays it on PipeWire/PulseAudio (pw-cat) and records the microphone from there.
//
// Socket: $X86SIM_AUDIO_SOCKET (Darling path). Per stream one connection: a 16-byte header
//   "x86A" | u32 direction (0 output, 1 input) | u32 sample rate | u32 channels
// then raw float32 interleaved frames (output: sim -> Linux; input: Linux -> sim).
// Linked flat-namespace with weak references: a process that does not load CoreAudio is left untouched.
// X86SIM_AUDIO_LOG=1: log calls on our objects and unknown properties to stderr.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>

typedef int32_t OSStatus;
typedef uint32_t UInt32;
typedef uint32_t AudioObjectID;
typedef struct { UInt32 mSelector, mScope, mElement; } AudioObjectPropertyAddress;
typedef struct { double mSampleRate; UInt32 mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket, mBytesPerFrame,
	mChannelsPerFrame, mBitsPerChannel, mReserved; } ASBD;
typedef struct { double mMinimum, mMaximum; } AudioValueRange;
typedef struct { ASBD mFormat; AudioValueRange mSampleRateRange; } ASRD;
typedef struct { UInt32 mNumberChannels, mDataByteSize; void* mData; } AudioBuffer;
typedef struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[1]; } AudioBufferList;
typedef struct { int16_t mSubframes, mSubframeDivisor; UInt32 mCounter, mType, mFlags; int16_t mHours, mMinutes,
	mSeconds, mFrames; } SMPTETime;
typedef struct { double mSampleTime; uint64_t mHostTime; double mRateScalar; uint64_t mWordClockTime; SMPTETime mSMPTETime;
	UInt32 mFlags, mReserved; } AudioTimeStamp;
typedef OSStatus (*AudioObjectPropertyListenerProc)(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void*);
typedef void (^AudioObjectPropertyListenerBlock)(UInt32, const AudioObjectPropertyAddress*);
typedef OSStatus (*AudioDeviceIOProc)(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*,
	AudioBufferList*, const AudioTimeStamp*, void*);
typedef void (^AudioDeviceIOBlock)(const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*, AudioBufferList*,
	const AudioTimeStamp*);
typedef AudioDeviceIOProc AudioDeviceIOProcID;

#define FCC(s) ((UInt32)(s)[0] << 24 | (UInt32)(s)[1] << 16 | (UInt32)(s)[2] << 8 | (UInt32)(s)[3])
enum { kSys = 1, kOutDev = 0x5801, kInDev = 0x5802, kOutStream = 0x5803, kInStream = 0x5804 };
#define ERR_UNKNOWN FCC("who?")
#define ERR_SIZE FCC("!siz")
#define ERR_OBJ FCC("!obj")
#define ERR_UNSUP FCC("unop")
#define ERR_ILLEGAL FCC("nope")
#define ERR_NOTRUNNING FCC("stop")
#define TS_SAMPLE 1
#define TS_HOST 2
#define TS_RATE 4

// ---- the original entry points (weak: absent when the process has no CoreAudio) ----
#define W __attribute__((weak_import))
extern OSStatus AudioObjectGetPropertyData(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*, void*) W;
extern OSStatus AudioObjectGetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*) W;
extern Boolean AudioObjectHasProperty(AudioObjectID, const AudioObjectPropertyAddress*) W;
extern OSStatus AudioObjectIsPropertySettable(AudioObjectID, const AudioObjectPropertyAddress*, Boolean*) W;
extern OSStatus AudioObjectSetPropertyData(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*) W;
extern OSStatus AudioObjectAddPropertyListener(AudioObjectID, const AudioObjectPropertyAddress*, AudioObjectPropertyListenerProc, void*) W;
extern OSStatus AudioObjectAddPropertyListenerInternal(AudioObjectID, const AudioObjectPropertyAddress*, AudioObjectPropertyListenerProc, void*, uintptr_t) W;
extern OSStatus AudioObjectRemovePropertyListener(AudioObjectID, const AudioObjectPropertyAddress*, AudioObjectPropertyListenerProc, void*) W;
extern OSStatus AudioObjectAddPropertyListenerBlock(AudioObjectID, const AudioObjectPropertyAddress*, dispatch_queue_t, AudioObjectPropertyListenerBlock) W;
extern OSStatus AudioObjectRemovePropertyListenerBlock(AudioObjectID, const AudioObjectPropertyAddress*, dispatch_queue_t, AudioObjectPropertyListenerBlock) W;
extern Boolean AudioObjectExists(AudioObjectID) W;
extern void AudioObjectShow(AudioObjectID) W;
extern OSStatus AudioDeviceCreateIOProcID(AudioObjectID, AudioDeviceIOProc, void*, AudioDeviceIOProcID*) W;
extern OSStatus AudioDeviceCreateIOProcIDWithBlock(AudioDeviceIOProcID*, AudioObjectID, dispatch_queue_t, AudioDeviceIOBlock) W;
extern OSStatus AudioDeviceDestroyIOProcID(AudioObjectID, AudioDeviceIOProcID) W;
extern OSStatus AudioDeviceStart(AudioObjectID, AudioDeviceIOProcID) W;
extern OSStatus AudioDeviceStartAtTime(AudioObjectID, AudioDeviceIOProcID, AudioTimeStamp*, UInt32) W;
extern OSStatus AudioDeviceStop(AudioObjectID, AudioDeviceIOProcID) W;
extern OSStatus AudioDeviceGetCurrentTime(AudioObjectID, AudioTimeStamp*) W;
extern OSStatus AudioDeviceTranslateTime(AudioObjectID, const AudioTimeStamp*, AudioTimeStamp*) W;
extern OSStatus AudioDeviceGetNearestStartTime(AudioObjectID, AudioTimeStamp*, UInt32) W;
extern OSStatus AudioHardwareCreateAggregateDevice(CFDictionaryRef, AudioObjectID*) W;
extern OSStatus AudioHardwareDestroyAggregateDevice(AudioObjectID) W;

static int logon;
#define LOG(...) do { if (logon) { fprintf(stderr, "simaudio[%d]: ", getpid()); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
static const char* fcc(UInt32 v, char* b) { for (int i = 0; i < 4; i++) { char c = (char)(v >> (24 - 8 * i)); b[i] = c >= 32 && c < 127 ? c : '.'; } b[4] = 0; return b; }

static int ours(AudioObjectID o) { return o == kOutDev || o == kInDev || o == kOutStream || o == kInStream; }

// ---- device state ----
#define MAXPROCS 8
struct ioproc { AudioDeviceIOProc proc; void* data; AudioDeviceIOBlock block; dispatch_queue_t queue; int running; int id; };
struct dev {
	AudioObjectID id, stream; int input; UInt32 channels;
	double rate; UInt32 frames;
	struct ioproc procs[MAXPROCS];
	pthread_t thread; int threadrun;
	int sock;                     // Linux connection
	uint64_t t0; double sample0;  // host time at sample time sample0 (anchor of the clock)
	float* ring; size_t ringcap, ringr, ringw;   // input: frames read from Linux
	pthread_mutex_t lock;
	float volume; int mute;
};
static struct dev devs[2] = {
	{ kOutDev, kOutStream, 0, 2, 48000, 512, .sock = -1, .lock = PTHREAD_MUTEX_INITIALIZER, .volume = 1 },
	{ kInDev, kInStream, 1, 1, 48000, 512, .sock = -1, .lock = PTHREAD_MUTEX_INITIALIZER, .volume = 1 },
};
static struct dev* devof(AudioObjectID o) {
	if (o == kOutDev || o == kOutStream) return &devs[0];
	if (o == kInDev || o == kInStream) return &devs[1];
	return NULL;
}
static int nextprocid = 1;
// Platforms 2: the composition of the last aggregate answered with each device (my_CreateAggregateDevice), for 'acom'
static CFDictionaryRef aggdesc[2];
static pthread_mutex_t agglock = PTHREAD_MUTEX_INITIALIZER;

static double ticks_per_sec;
static void timebase(void) {
	if (ticks_per_sec) return;
	mach_timebase_info_data_t tb; mach_timebase_info(&tb);
	ticks_per_sec = 1e9 * tb.denom / tb.numer;
}

// ---- listeners ----
#define MAXL 64
struct listener { AudioObjectID obj; AudioObjectPropertyAddress addr; AudioObjectPropertyListenerProc proc; void* data;
	AudioObjectPropertyListenerBlock block; dispatch_queue_t queue; int used; };
static struct listener listeners[MAXL];
static pthread_mutex_t llock = PTHREAD_MUTEX_INITIALIZER;
static int addrmatch(const AudioObjectPropertyAddress* l, UInt32 sel) {
	return l->mSelector == sel || l->mSelector == FCC("****");
}
static void notify(AudioObjectID obj, UInt32 sel, UInt32 scope) {
	AudioObjectPropertyAddress a = { sel, scope, 0 };
	pthread_mutex_lock(&llock);
	for (int i = 0; i < MAXL; i++) {
		struct listener* l = &listeners[i];
		if (!l->used || l->obj != obj || !addrmatch(&l->addr, sel)) continue;
		if (l->proc) {
			AudioObjectPropertyListenerProc p = l->proc; void* d = l->data;
			dispatch_async(dispatch_get_global_queue(0, 0), ^{ AudioObjectPropertyAddress aa = a; p(obj, 1, &aa, d); });
		} else if (l->block) {
			AudioObjectPropertyListenerBlock b = l->block;
			dispatch_async(l->queue ? l->queue : dispatch_get_global_queue(0, 0), ^{ AudioObjectPropertyAddress aa = a; b(1, &aa); });
		}
	}
	pthread_mutex_unlock(&llock);
}

// ---- Linux connection ----
static int connect_linux(struct dev* d) {
	const char* path = getenv("X86SIM_AUDIO_SOCKET");
	if (!path || !*path) return -1;
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s < 0) return -1;
	struct sockaddr_un a = { 0 }; a.sun_family = AF_UNIX;
	snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
	if (connect(s, (struct sockaddr*)&a, sizeof(a)) != 0) { LOG("connect %s: %s", path, strerror(errno)); close(s); return -1; }
	uint32_t hdr[4] = { 0, (uint32_t)d->input, (uint32_t)d->rate, d->channels };
	memcpy(hdr, "x86A", 4);
	if (write(s, hdr, sizeof(hdr)) != sizeof(hdr)) { close(s); return -1; }
	if (!d->input) { int fl = fcntl(s, F_GETFL); fcntl(s, F_SETFL, fl | O_NONBLOCK); }
	int one = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	LOG("%s stream to Linux: %.0f Hz, %u ch", d->input ? "input" : "output", d->rate, d->channels);
	return s;
}

static void* input_reader(void* arg) {
	struct dev* d = arg; int s = d->sock;
	float buf[1024];
	for (;;) {
		ssize_t n = read(s, buf, sizeof(buf));
		if (n <= 0) break;
		size_t nf = (size_t)n / sizeof(float);
		pthread_mutex_lock(&d->lock);
		for (size_t i = 0; i < nf; i++) {
			d->ring[d->ringw % d->ringcap] = buf[i]; d->ringw++;
			if (d->ringw - d->ringr > d->ringcap) d->ringr = d->ringw - d->ringcap;
		}
		pthread_mutex_unlock(&d->lock);
	}
	return NULL;
}

// ---- IO thread ----
static int anyrunning(struct dev* d) { for (int i = 0; i < MAXPROCS; i++) if (d->procs[i].running) return 1; return 0; }

static void stamp(struct dev* d, double sample, AudioTimeStamp* t) {
	memset(t, 0, sizeof(*t));
	t->mSampleTime = sample;
	t->mHostTime = d->t0 + (uint64_t)((sample - d->sample0) / d->rate * ticks_per_sec);
	t->mRateScalar = 1.0;
	t->mFlags = TS_SAMPLE | TS_HOST | TS_RATE;
}

static void* iothread(void* arg) {
	struct dev* d = arg;
	pthread_setname_np(d->input ? "com.x86sim.simaudio.input" : "com.x86sim.simaudio.output");
	// x86Sim: a time-constraint thread as the HAL's IO thread would be
	struct sched_param sp = { .sched_priority = 47 }; pthread_setschedparam(pthread_self(), SCHED_RR, &sp);
	UInt32 ch = d->channels;
	float *mix = NULL, *buf = NULL, *in = NULL; size_t cap = 0;
	uint64_t n = 0;
	while (d->threadrun) {
		UInt32 frames = d->frames; double rate = d->rate;
		size_t need = (size_t)frames * ch;
		if (need > cap) { cap = need; mix = realloc(mix, cap * 4); buf = realloc(buf, cap * 4); in = realloc(in, cap * 4); }
		double sample = d->sample0 + (double)n * frames;
		AudioTimeStamp now, intime, outtime;
		stamp(d, sample, &now);
		uint64_t wake = now.mHostTime + (uint64_t)(frames / rate * ticks_per_sec);
		mach_wait_until(wake);
		if (!d->threadrun) break;
		stamp(d, sample + frames, &now);
		stamp(d, sample, &intime);
		stamp(d, sample + 2.0 * frames, &outtime);
		memset(mix, 0, need * 4);
		AudioBufferList inl = { 1, { { ch, (UInt32)(need * 4), in } } };
		if (d->input) {
			memset(in, 0, need * 4);
			pthread_mutex_lock(&d->lock);
			size_t avail = d->ringw - d->ringr;
			// keep the latency bounded: skip what piled up beyond two buffers
			if (avail > need * 3) d->ringr = d->ringw - need * 2, avail = need * 2;
			for (size_t i = 0; i < need && i < avail; i++) in[i] = d->ring[(d->ringr + i) % d->ringcap] * (d->mute ? 0 : d->volume);
			d->ringr += need < avail ? need : avail;
			pthread_mutex_unlock(&d->lock);
		}
		for (int i = 0; i < MAXPROCS; i++) {
			struct ioproc* p = &d->procs[i];
			if (!p->running) continue;
			AudioBufferList outl = { 1, { { ch, (UInt32)(need * 4), buf } } };
			memset(buf, 0, need * 4);
			const AudioBufferList* ip = d->input ? &inl : NULL;
			AudioBufferList* op = d->input ? NULL : &outl;
			static AudioBufferList empty = { 0 };
			if (!ip) ip = &empty;
			if (!op) op = (AudioBufferList*)&empty;
			if (p->proc) p->proc(d->id, &now, ip, &intime, op, &outtime, p->data);
			else if (p->block) p->block(&now, ip, &intime, op, &outtime);
			if (!d->input) for (size_t k = 0; k < need; k++) mix[k] += buf[k];
		}
		if (!d->input) {
			if (d->sock < 0) d->sock = connect_linux(d);
			if (d->sock >= 0) {
				float g = d->mute ? 0 : d->volume;
				if (g != 1) for (size_t k = 0; k < need; k++) mix[k] *= g;
				ssize_t w = write(d->sock, mix, need * 4);
				if (w < 0 && errno != EAGAIN) { close(d->sock); d->sock = -1; }
			}
		}
		n++;
		// fell far behind (the process was stopped, e.g. in a debugger): restart the clock
		if (mach_absolute_time() > wake + (uint64_t)(0.5 * ticks_per_sec)) {
			d->sample0 = sample + frames; d->t0 = mach_absolute_time(); n = 0;
		}
	}
	free(mix); free(buf); free(in);
	return NULL;
}

static void dev_start(struct dev* d) {
	if (d->threadrun) return;
	timebase();
	d->t0 = mach_absolute_time();
	if (d->input) {
		if (!d->ring) { d->ringcap = 48000 * 2; d->ring = calloc(d->ringcap, 4); }
		d->ringr = d->ringw = 0;
		d->sock = connect_linux(d);
		if (d->sock >= 0) { pthread_t t; pthread_create(&t, NULL, input_reader, d); pthread_detach(t); }
	}
	d->threadrun = 1;
	pthread_create(&d->thread, NULL, iothread, d);
	notify(d->id, FCC("goin"), FCC("glob"));
}

static void dev_stop(struct dev* d) {
	if (!d->threadrun) return;
	d->threadrun = 0;
	if (!pthread_equal(pthread_self(), d->thread)) pthread_join(d->thread, NULL); else pthread_detach(d->thread);
	d->sample0 += 0;  // the sample clock continues from the anchor on the next start
	if (d->sock >= 0) { shutdown(d->sock, SHUT_RDWR); close(d->sock); d->sock = -1; }
	notify(d->id, FCC("goin"), FCC("glob"));
}

// ---- properties ----
static ASBD fmt(struct dev* d) {
	ASBD f = { d->rate, FCC("lpcm"), 1 | 8 /* float | packed */, 4 * d->channels, 1, 4 * d->channels, d->channels, 32, 0 };
	return f;
}

// put: write a value of size n into out (checking the caller's size)
#define PUT(T, v) do { if (*ioSize < sizeof(T)) return ERR_SIZE; *(T*)out = (v); *ioSize = sizeof(T); return 0; } while (0)
#define PUTCF(s) do { if (*ioSize < sizeof(CFStringRef)) return ERR_SIZE; *(CFStringRef*)out = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); *ioSize = sizeof(CFStringRef); return 0; } while (0)

static int scope_ok(struct dev* d, UInt32 scope) {
	return scope == FCC("glob") || scope == (d->input ? FCC("inpt") : FCC("outp"));
}

// Platforms 2: our device for a UID: ours, or the UID of an aggregate my_CreateAggregateDevice answered with it
static AudioObjectID uid_device(CFStringRef u) {
	if (!u || CFGetTypeID(u) != CFStringGetTypeID()) return 0;
	if (CFEqual(u, CFSTR("x86sim-output"))) return kOutDev;
	if (CFEqual(u, CFSTR("x86sim-input"))) return kInDev;
	AudioObjectID r = 0;
	pthread_mutex_lock(&agglock);
	for (int i = 0; i < 2 && !r; i++) {
		CFStringRef a = aggdesc[i] ? CFDictionaryGetValue(aggdesc[i], CFSTR("uid")) : NULL;
		if (a && CFEqual(a, u)) r = i ? kInDev : kOutDev;
	}
	pthread_mutex_unlock(&agglock);
	return r;
}

static OSStatus getprop(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qsize, const void* qual, UInt32* ioSize, void* out) {
	UInt32 sel = a->mSelector;
	if (obj == kSys) {
		switch (sel) {
		case FCC("dev#"): case FCC("ownd"): {
			UInt32 want = (UInt32)(2 * sizeof(AudioObjectID));
			UInt32 n = *ioSize < want ? *ioSize / 4 : 2;
			AudioObjectID ids[2] = { kOutDev, kInDev };
			memcpy(out, ids, n * 4); *ioSize = n * 4; return 0;
		}
		case FCC("dOut"): case FCC("sOut"): PUT(AudioObjectID, kOutDev);
		case FCC("dIn "): PUT(AudioObjectID, kInDev);
		case FCC("uidd"): {
			AudioObjectID r = 0;
			if (qual && qsize >= sizeof(CFStringRef)) {
				CFStringRef u = *(CFStringRef*)qual;
				if (u && CFStringCompare(u, CFSTR("x86sim-output"), 0) == 0) r = kOutDev;
				if (u && CFStringCompare(u, CFSTR("x86sim-input"), 0) == 0) r = kInDev;
			}
			PUT(AudioObjectID, r);
		}
		case FCC("duid"): {  // Platforms 2: kAudioHardwarePropertyDeviceForUID, an AudioValueTranslation (in/out)
			struct { void* in; UInt32 insz; void* out; UInt32 outsz; } *t = out;
			if (*ioSize < sizeof(*t)) return ERR_SIZE;
			if (!t->in || t->insz < sizeof(CFStringRef) || !t->out || t->outsz < sizeof(AudioObjectID)) return ERR_ILLEGAL;
			CFStringRef u = *(CFStringRef*)t->in;
			AudioObjectID r = uid_device(u);
			if (!r) return -1;  // not ours: the real HAL
			*(AudioObjectID*)t->out = r; *ioSize = sizeof(*t); return 0;
		}
		case FCC("clas"): PUT(UInt32, FCC("asys"));
		case FCC("bcls"): PUT(UInt32, FCC("aobj"));
		case FCC("main"): case FCC("pmut"): case FCC("slep"): case FCC("unld"): case FCC("hogr"): case FCC("user"): PUT(UInt32, 1);
		case FCC("inot"): case FCC("stmo"): case FCC("powh"): PUT(UInt32, 0);
		case FCC("plg#"): case FCC("box#"): case FCC("clk#"): case FCC("prs#"): case FCC("tap#"): *ioSize = 0; return 0;
		case FCC("lnam"): PUTCF("x86sim audio");
		case FCC("lmak"): PUTCF("x86sim");
		}
		{ char b[5]; LOG("system: property %s not ours", fcc(sel, b)); }
		return -1;  // not ours: let the real HAL answer
	}
	struct dev* d = devof(obj);
	char b[5];
	if (obj == d->stream) {
		switch (sel) {
		case FCC("clas"): PUT(UInt32, FCC("astr"));
		case FCC("bcls"): PUT(UInt32, FCC("aobj"));
		case FCC("stdv"): PUT(AudioObjectID, d->id);
		case FCC("sact"): PUT(UInt32, 1);
		case FCC("sdir"): PUT(UInt32, (UInt32)d->input);
		case FCC("term"): PUT(UInt32, d->input ? FCC("micr") : FCC("spkr"));
		case FCC("schn"): PUT(UInt32, 1);
		case FCC("ltnc"): PUT(UInt32, 0);
		case FCC("sfmt"): case FCC("pft "): PUT(ASBD, fmt(d));
		case FCC("sfma"): case FCC("pfta"): {
			double rates[2] = { 44100, 48000 };
			UInt32 n = *ioSize / sizeof(ASRD); if (n > 2) n = 2;
			for (UInt32 i = 0; i < n; i++) {
				ASRD r; r.mFormat = fmt(d); r.mFormat.mSampleRate = rates[i];
				r.mSampleRateRange.mMinimum = r.mSampleRateRange.mMaximum = rates[i]; ((ASRD*)out)[i] = r;
			}
			*ioSize = n * sizeof(ASRD); return 0;
		}
		case FCC("lnam"): PUTCF(d->input ? "Microphone" : "Speaker");
		case FCC("ownd"): *ioSize = 0; return 0;
		}
		LOG("stream %x: unknown property %s", obj, fcc(sel, b));
		return ERR_UNKNOWN;
	}
	int sc = scope_ok(d, a->mScope);
	switch (sel) {
	case FCC("clas"): PUT(UInt32, FCC("adev"));
	case FCC("bcls"): PUT(UInt32, FCC("aobj"));
	case FCC("stdv"): PUT(AudioObjectID, kSys);
	case FCC("lnam"): PUTCF(d->input ? "Linux Microphone" : "Linux Speaker");
	case FCC("lmak"): PUTCF("x86sim");
	case FCC("lmod"): PUTCF("PipeWire");
	case FCC("uid "): PUTCF(d->input ? "x86sim-input" : "x86sim-output");
	case FCC("muid"): PUTCF("x86sim-pipewire");
	case FCC("tran"): PUT(UInt32, FCC("virt"));
	case FCC("clkd"): PUT(UInt32, 0x86);
	case FCC("livn"): PUT(UInt32, 1);
	case FCC("goin"): case FCC("gone"): PUT(UInt32, (UInt32)d->threadrun);
	case FCC("dflt"): case FCC("sflt"): PUT(UInt32, sc ? 1 : 0);
	case FCC("hidn"): case FCC("vfsz"): PUT(UInt32, 0);
	case FCC("ltnc"): case FCC("saft"): PUT(UInt32, 0);
	case FCC("oink"): PUT(int32_t, -1);
	case FCC("ring"): PUT(UInt32, d->frames);
	case FCC("nsrt"): case FCC("asrt"): PUT(double, d->rate);
	case FCC("nsr#"): {
		AudioValueRange r[2] = { { 44100, 44100 }, { 48000, 48000 } };
		UInt32 n = *ioSize / sizeof(AudioValueRange); if (n > 2) n = 2;
		memcpy(out, r, n * sizeof(AudioValueRange)); *ioSize = n * sizeof(AudioValueRange); return 0;
	}
	case FCC("fsiz"): PUT(UInt32, d->frames);
	case FCC("fsz#"): { AudioValueRange r = { 64, 4096 }; PUT(AudioValueRange, r); }
	case FCC("ncyc"): PUT(float, 1.0f);
	case FCC("cstb"): PUT(UInt32, 1);
	case FCC("clok"): PUT(UInt32, FCC("raw0"));
	case FCC("stm#"): {
		if (!sc) { *ioSize = 0; return 0; }
		PUT(AudioObjectID, d->stream);
	}
	case FCC("ownd"): PUT(AudioObjectID, d->stream);
	case FCC("ctrl"): case FCC("akin"): {
		if (sel == FCC("akin")) PUT(AudioObjectID, d->id);
		*ioSize = 0; return 0;
	}
	case FCC("slay"): {
		UInt32 nb = sc ? 1 : 0, need = 4 + nb * sizeof(AudioBuffer);
		if (*ioSize < need) return ERR_SIZE;
		AudioBufferList* l = out; l->mNumberBuffers = nb;
		if (nb) { l->mBuffers[0].mNumberChannels = d->channels; l->mBuffers[0].mDataByteSize = 0; l->mBuffers[0].mData = NULL; }
		*ioSize = need; return 0;
	}
	case FCC("dch2"): { UInt32 c[2] = { 1, d->channels > 1 ? 2 : 1 }; if (*ioSize < 8) return ERR_SIZE; memcpy(out, c, 8); *ioSize = 8; return 0; }
	case FCC("volm"): case FCC("vmvc"): PUT(float, d->volume);
	case FCC("mute"): PUT(UInt32, (UInt32)d->mute);
	case FCC("srnd"): {
		if (!sc) return ERR_UNKNOWN;
		// AudioChannelLayout: tag Stereo (101<<16|2) or Mono (100<<16|1), no bitmap, no descriptions
		UInt32 l[3] = { d->channels > 1 ? (101u << 16 | 2) : (100u << 16 | 1), 0, 0 };
		if (*ioSize < sizeof(l)) return ERR_SIZE;
		memcpy(out, l, sizeof(l)); *ioSize = sizeof(l); return 0;
	}
	case FCC("jack"): PUT(UInt32, 1);
	// Platforms 2: the aggregate properties (our device stands in for the simulator's private aggregate)
	case FCC("acom"): {
		if (*ioSize < sizeof(CFDictionaryRef)) return ERR_SIZE;
		pthread_mutex_lock(&agglock);
		CFDictionaryRef c = aggdesc[d->input];
		if (c) CFRetain(c);
		pthread_mutex_unlock(&agglock);
		if (!c) break;
		*(CFDictionaryRef*)out = c; *ioSize = sizeof(CFDictionaryRef); return 0;
	}
	case FCC("grup"): {
		if (*ioSize < sizeof(CFArrayRef)) return ERR_SIZE;
		CFStringRef u = d->input ? CFSTR("x86sim-input") : CFSTR("x86sim-output");
		*(CFArrayRef*)out = CFArrayCreate(NULL, (const void**)&u, 1, &kCFTypeArrayCallBacks); *ioSize = sizeof(CFArrayRef); return 0;
	}
	case FCC("agrp"): PUT(AudioObjectID, d->id);
	case FCC("amst"): case FCC("apcd"): PUTCF(d->input ? "x86sim-input" : "x86sim-output");
	case FCC("appm"): PUT(UInt32, 0);
	}
	LOG("device %x: unknown property %s scope %s", obj, fcc(sel, b), fcc(a->mScope, (char[5]){0}));
	return ERR_UNKNOWN;
}

static OSStatus my_GetPropertyData(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32* sz, void* out) {
	if ((ours(o) || o == kSys) && a && sz && out) {
		OSStatus r = getprop(o, a, qs, q, sz, out);
		if (logon > 1) { char b[5], c[5], e[5]; LOG("get %x %s %s el %u -> %s", o, fcc(a->mSelector, b), fcc(a->mScope, c), a->mElement, r == -1 ? "HAL" : fcc((UInt32)r, e)); }
		if (r != -1) return r;
	}
	return AudioObjectGetPropertyData ? AudioObjectGetPropertyData(o, a, qs, q, sz, out) : ERR_OBJ;
}

static OSStatus my_GetPropertyDataSize(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32* sz) {
	if (o == kSys && a && sz && a->mSelector == FCC("duid")) { *sz = sizeof(struct { void* i; UInt32 is; void* o; UInt32 os; }); return 0; }
	if ((ours(o) || o == kSys) && a && sz) {
		char tmp[1024]; UInt32 n = sizeof(tmp);
		OSStatus r = getprop(o, a, qs, q, &n, tmp);
		if (r != -1) {
			if (r == 0) {
				*sz = n;
				// CFString results were created for nothing
				UInt32 s = a->mSelector;
				if (s == FCC("lnam") || s == FCC("lmak") || s == FCC("lmod") || s == FCC("uid ") || s == FCC("muid") ||
					s == FCC("acom") || s == FCC("grup") || s == FCC("amst") || s == FCC("apcd")) CFRelease(*(CFTypeRef*)tmp);
			}
			return r;
		}
	}
	return AudioObjectGetPropertyDataSize ? AudioObjectGetPropertyDataSize(o, a, qs, q, sz) : ERR_OBJ;
}

static Boolean my_HasProperty(AudioObjectID o, const AudioObjectPropertyAddress* a) {
	if ((ours(o) || o == kSys) && a) {
		UInt32 sz; if (my_GetPropertyDataSize(o, a, 0, NULL, &sz) == 0) return 1;
		if (ours(o)) return 0;
	}
	return AudioObjectHasProperty ? AudioObjectHasProperty(o, a) : 0;
}

static OSStatus my_IsPropertySettable(AudioObjectID o, const AudioObjectPropertyAddress* a, Boolean* s) {
	if (ours(o) && a && s) {
		UInt32 sel = a->mSelector;
		*s = sel == FCC("nsrt") || sel == FCC("fsiz") || sel == FCC("volm") || sel == FCC("vmvc") || sel == FCC("mute") ||
			sel == FCC("sfmt") || sel == FCC("pft ");
		return 0;
	}
	return AudioObjectIsPropertySettable ? AudioObjectIsPropertySettable(o, a, s) : ERR_OBJ;
}

static OSStatus my_SetPropertyData(AudioObjectID o, const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32 sz, const void* data) {
	if (!(ours(o) && a && data)) {
		if (o == kSys && a) { char b[5]; LOG("set system %s ignored", fcc(a->mSelector, b)); return 0; }
		return AudioObjectSetPropertyData ? AudioObjectSetPropertyData(o, a, qs, q, sz, data) : ERR_OBJ;
	}
	struct dev* d = devof(o); char b[5];
	LOG("set %x %s", o, fcc(a->mSelector, b));
	switch (a->mSelector) {
	case FCC("nsrt"): case FCC("sfmt"): case FCC("pft "): {
		double r = a->mSelector == FCC("nsrt") ? (sz >= 8 ? *(const double*)data : 0) : (sz >= sizeof(ASBD) ? ((const ASBD*)data)->mSampleRate : 0);
		if (r != 44100 && r != 48000) return ERR_UNSUP;
		if (r != d->rate) {
			int run = d->threadrun;
			if (run) dev_stop(d);
			d->rate = r;
			if (d->sock >= 0) { close(d->sock); d->sock = -1; }
			if (run) dev_start(d);
			notify(d->id, FCC("nsrt"), FCC("glob"));
			notify(d->stream, FCC("sfmt"), FCC("glob"));
			notify(d->stream, FCC("pft "), FCC("glob"));
		}
		return 0;
	}
	case FCC("fsiz"): {
		UInt32 f = sz >= 4 ? *(const UInt32*)data : 0;
		if (f < 64 || f > 4096) return FCC("!val");
		if (f != d->frames) { d->frames = f; notify(d->id, FCC("fsiz"), FCC("glob")); }
		return 0;
	}
	case FCC("volm"): case FCC("vmvc"): d->volume = sz >= 4 ? *(const float*)data : 1; return 0;
	case FCC("mute"): d->mute = sz >= 4 ? (int)*(const UInt32*)data : 0; return 0;
	case FCC("oink"): case FCC("dch2"): case FCC("appm"): return 0;
	case FCC("srnd"): return 0;  // Platforms 2: AUHAL sets the preferred layout on an aggregate (ours: stereo/mono as is)
	}
	return ERR_UNSUP;
}

static OSStatus addlistener(AudioObjectID o, const AudioObjectPropertyAddress* a, AudioObjectPropertyListenerProc p, void* d,
		AudioObjectPropertyListenerBlock blk, dispatch_queue_t q) {
	pthread_mutex_lock(&llock);
	for (int i = 0; i < MAXL; i++) if (!listeners[i].used) {
		listeners[i] = (struct listener){ o, *a, p, d, blk ? Block_copy(blk) : NULL, q, 1 };
		if (q) dispatch_retain(q);
		pthread_mutex_unlock(&llock); return 0;
	}
	pthread_mutex_unlock(&llock);
	return 0;  // full: accept and never call (nothing changes on our devices that a client must see)
}
static OSStatus removelistener(AudioObjectID o, const AudioObjectPropertyAddress* a, AudioObjectPropertyListenerProc p, void* d,
		AudioObjectPropertyListenerBlock blk) {
	pthread_mutex_lock(&llock);
	for (int i = 0; i < MAXL; i++) {
		struct listener* l = &listeners[i];
		if (l->used && l->obj == o && l->addr.mSelector == a->mSelector && l->proc == p && l->data == d && (!blk || l->block == blk || !l->proc)) {
			if (blk && l->block != blk) continue;
			if (l->block) Block_release(l->block);
			if (l->queue) dispatch_release(l->queue);
			memset(l, 0, sizeof(*l)); break;
		}
	}
	pthread_mutex_unlock(&llock);
	return 0;
}
// x86Sim: system-object listeners are recorded as well (default device changes come from us), and still passed on
// so the HAL's own bookkeeping is unchanged
static OSStatus my_AddPropertyListener(AudioObjectID o, const AudioObjectPropertyAddress* a, AudioObjectPropertyListenerProc p, void* d) {
	if (a && (ours(o) || o == kSys)) { addlistener(o, a, p, d, NULL, NULL); if (ours(o)) return 0; }
	return AudioObjectAddPropertyListener ? AudioObjectAddPropertyListener(o, a, p, d) : 0;
}
static OSStatus my_AddPropertyListenerInternal(AudioObjectID o, const AudioObjectPropertyAddress* a, AudioObjectPropertyListenerProc p, void* d, uintptr_t x) {
	if (a && (ours(o) || o == kSys)) { addlistener(o, a, p, d, NULL, NULL); if (ours(o)) return 0; }
	return AudioObjectAddPropertyListenerInternal ? AudioObjectAddPropertyListenerInternal(o, a, p, d, x) : 0;
}
static OSStatus my_RemovePropertyListener(AudioObjectID o, const AudioObjectPropertyAddress* a, AudioObjectPropertyListenerProc p, void* d) {
	if (a && (ours(o) || o == kSys)) { removelistener(o, a, p, d, NULL); if (ours(o)) return 0; }
	return AudioObjectRemovePropertyListener ? AudioObjectRemovePropertyListener(o, a, p, d) : 0;
}
static OSStatus my_AddPropertyListenerBlock(AudioObjectID o, const AudioObjectPropertyAddress* a, dispatch_queue_t q, AudioObjectPropertyListenerBlock b) {
	if (a && b && ours(o)) return addlistener(o, a, NULL, NULL, b, q);
	return AudioObjectAddPropertyListenerBlock ? AudioObjectAddPropertyListenerBlock(o, a, q, b) : 0;
}
static OSStatus my_RemovePropertyListenerBlock(AudioObjectID o, const AudioObjectPropertyAddress* a, dispatch_queue_t q, AudioObjectPropertyListenerBlock b) {
	if (a && ours(o)) return removelistener(o, a, NULL, NULL, b);
	return AudioObjectRemovePropertyListenerBlock ? AudioObjectRemovePropertyListenerBlock(o, a, q, b) : 0;
}
static Boolean my_ObjectExists(AudioObjectID o) {
	if (ours(o)) return 1;
	return AudioObjectExists ? AudioObjectExists(o) : 0;
}
static void my_ObjectShow(AudioObjectID o) {
	if (ours(o)) { fprintf(stderr, "x86sim audio object %x\n", o); return; }
	if (AudioObjectShow) AudioObjectShow(o);
}

// ---- IOProcs ----
static OSStatus newproc(struct dev* d, AudioDeviceIOProc p, void* data, AudioDeviceIOBlock blk, dispatch_queue_t q, AudioDeviceIOProcID* out) {
	pthread_mutex_lock(&d->lock);
	for (int i = 0; i < MAXPROCS; i++) if (!d->procs[i].id) {
		d->procs[i] = (struct ioproc){ p, data, blk ? Block_copy(blk) : NULL, q, 0, nextprocid++ };
		*out = (AudioDeviceIOProcID)(uintptr_t)(0x58000000 + d->procs[i].id);
		pthread_mutex_unlock(&d->lock);
		LOG("device %x: IOProc %d created", d->id, d->procs[i].id);
		return 0;
	}
	pthread_mutex_unlock(&d->lock);
	return ERR_ILLEGAL;
}
static struct ioproc* findproc(struct dev* d, AudioDeviceIOProcID id) {
	uintptr_t v = (uintptr_t)id;
	for (int i = 0; i < MAXPROCS; i++) {
		struct ioproc* p = &d->procs[i];
		if (!p->id) continue;
		if (v == 0x58000000 + (uintptr_t)p->id || (p->proc && (uintptr_t)p->proc == v)) return p;
	}
	return NULL;
}
static OSStatus my_CreateIOProcID(AudioObjectID o, AudioDeviceIOProc p, void* data, AudioDeviceIOProcID* out) {
	if (ours(o) && devof(o)->id == o) { if (!p || !out) return ERR_ILLEGAL; return newproc(devof(o), p, data, NULL, NULL, out); }
	return AudioDeviceCreateIOProcID ? AudioDeviceCreateIOProcID(o, p, data, out) : ERR_OBJ;
}
static OSStatus my_CreateIOProcIDWithBlock(AudioDeviceIOProcID* out, AudioObjectID o, dispatch_queue_t q, AudioDeviceIOBlock b) {
	if (ours(o) && devof(o)->id == o) { if (!b || !out) return ERR_ILLEGAL; return newproc(devof(o), NULL, NULL, b, q, out); }
	return AudioDeviceCreateIOProcIDWithBlock ? AudioDeviceCreateIOProcIDWithBlock(out, o, q, b) : ERR_OBJ;
}
static OSStatus my_DestroyIOProcID(AudioObjectID o, AudioDeviceIOProcID id) {
	if (!ours(o)) return AudioDeviceDestroyIOProcID ? AudioDeviceDestroyIOProcID(o, id) : ERR_OBJ;
	struct dev* d = devof(o); struct ioproc* p = findproc(d, id);
	if (!p) return ERR_ILLEGAL;
	if (p->running) { p->running = 0; if (!anyrunning(d)) dev_stop(d); }
	pthread_mutex_lock(&d->lock);
	if (p->block) Block_release(p->block);
	memset(p, 0, sizeof(*p));
	pthread_mutex_unlock(&d->lock);
	return 0;
}
static OSStatus my_Start(AudioObjectID o, AudioDeviceIOProcID id) {
	if (!ours(o)) return AudioDeviceStart ? AudioDeviceStart(o, id) : ERR_OBJ;
	struct dev* d = devof(o);
	LOG("device %x: start %p", o, (void*)id);
	if (id) { struct ioproc* p = findproc(d, id); if (!p) return ERR_ILLEGAL; p->running = 1; }
	dev_start(d);
	return 0;
}
static OSStatus my_StartAtTime(AudioObjectID o, AudioDeviceIOProcID id, AudioTimeStamp* t, UInt32 flags) {
	if (!ours(o)) return AudioDeviceStartAtTime ? AudioDeviceStartAtTime(o, id, t, flags) : ERR_OBJ;
	OSStatus r = my_Start(o, id);
	if (r == 0 && t) { struct dev* d = devof(o); stamp(d, d->sample0, t); }
	return r;
}
static OSStatus my_Stop(AudioObjectID o, AudioDeviceIOProcID id) {
	if (!ours(o)) return AudioDeviceStop ? AudioDeviceStop(o, id) : ERR_OBJ;
	struct dev* d = devof(o);
	LOG("device %x: stop %p", o, (void*)id);
	if (id) { struct ioproc* p = findproc(d, id); if (p) p->running = 0; }
	if (!id || !anyrunning(d)) dev_stop(d);
	return 0;
}
static double cursample(struct dev* d) {
	return d->sample0 + (double)(mach_absolute_time() - d->t0) / ticks_per_sec * d->rate;
}
static OSStatus my_GetCurrentTime(AudioObjectID o, AudioTimeStamp* t) {
	if (!ours(o)) return AudioDeviceGetCurrentTime ? AudioDeviceGetCurrentTime(o, t) : ERR_OBJ;
	struct dev* d = devof(o);
	if (!d->threadrun) return ERR_NOTRUNNING;
	stamp(d, cursample(d), t);
	return 0;
}
static OSStatus my_TranslateTime(AudioObjectID o, const AudioTimeStamp* in, AudioTimeStamp* out) {
	if (!ours(o)) return AudioDeviceTranslateTime ? AudioDeviceTranslateTime(o, in, out) : ERR_OBJ;
	struct dev* d = devof(o);
	if (!d->threadrun) return ERR_NOTRUNNING;
	double s;
	if (in->mFlags & TS_SAMPLE) s = in->mSampleTime;
	else if (in->mFlags & TS_HOST) s = d->sample0 + ((double)in->mHostTime - (double)d->t0) / ticks_per_sec * d->rate;
	else return ERR_ILLEGAL;
	stamp(d, s, out);
	return 0;
}
static OSStatus my_GetNearestStartTime(AudioObjectID o, AudioTimeStamp* t, UInt32 flags) {
	if (!ours(o)) return AudioDeviceGetNearestStartTime ? AudioDeviceGetNearestStartTime(o, t, flags) : ERR_OBJ;
	struct dev* d = devof(o);
	if (!d->threadrun) return ERR_NOTRUNNING;
	double s = cursample(d); double f = d->frames;
	s = (double)((uint64_t)((s - d->sample0) / f) + 2) * f + d->sample0;
	stamp(d, s, t);
	return 0;
}
// Platforms 2: the simulator's AudioToolbox (AQME, visionOS's PHASE/AudioIOUnit) wraps the default device in a private
// aggregate ("iOSSimulatorAudioDevice-<pid>-<n>", master and subdevices by UID). Our devices already have the IO it
// wants, so the aggregate is the device itself: the output, or the input when the aggregate has no output channels.
static OSStatus my_CreateAggregateDevice(CFDictionaryRef desc, AudioObjectID* out) {
	if (logon) { LOG("CreateAggregateDevice:"); CFShow(desc); }
	if (!desc || !out) return ERR_ILLEGAL;
	int wantOut = 0, wantIn = 0, ours = 0, other = 0;
	CFArrayRef subs = CFDictionaryGetValue(desc, CFSTR("subdevices"));
	if (subs && CFGetTypeID(subs) == CFArrayGetTypeID()) {
		for (CFIndex i = 0; i < CFArrayGetCount(subs); i++) {
			CFDictionaryRef sd = CFArrayGetValueAtIndex(subs, i);
			if (!sd || CFGetTypeID(sd) != CFDictionaryGetTypeID()) continue;
			CFStringRef uid = CFDictionaryGetValue(sd, CFSTR("uid"));
			if (uid && CFGetTypeID(uid) == CFStringGetTypeID() && CFStringHasPrefix(uid, CFSTR("x86sim-"))) ours++; else other++;
			CFNumberRef ci = CFDictionaryGetValue(sd, CFSTR("channels-in")), co = CFDictionaryGetValue(sd, CFSTR("channels-out"));
			int n = 0;
			if (co && CFGetTypeID(co) == CFNumberGetTypeID() && CFNumberGetValue(co, kCFNumberIntType, &n) && n > 0) wantOut = 1;
			n = 0;
			if (ci && CFGetTypeID(ci) == CFNumberGetTypeID() && CFNumberGetValue(ci, kCFNumberIntType, &n) && n > 0) wantIn = 1;
		}
	}
	CFStringRef master = CFDictionaryGetValue(desc, CFSTR("master"));
	if (master && CFGetTypeID(master) == CFStringGetTypeID()) {
		if (CFEqual(master, CFSTR("x86sim-output"))) { ours++; wantOut = 1; }
		else if (CFEqual(master, CFSTR("x86sim-input"))) { ours++; if (!wantOut) wantIn = 1; }
	}
	if (!ours || other) return ERR_UNSUP;
	*out = wantOut || !wantIn ? kOutDev : kInDev;
	pthread_mutex_lock(&agglock);
	CFDictionaryRef *slot = &aggdesc[*out == kInDev], old = *slot;
	*slot = CFDictionaryCreateCopy(NULL, desc);
	pthread_mutex_unlock(&agglock);
	if (old) CFRelease(old);
	LOG("CreateAggregateDevice -> %x", *out);
	return 0;
}
static OSStatus my_DestroyAggregateDevice(AudioObjectID o) {
	if (o == kOutDev || o == kInDev) return 0;
	return AudioHardwareDestroyAggregateDevice ? AudioHardwareDestroyAggregateDevice(o) : ERR_OBJ;
}

__attribute__((constructor)) static void init(void) {
	logon = getenv("X86SIM_AUDIO_LOG") ? atoi(getenv("X86SIM_AUDIO_LOG")) ?: 1 : 0;  // 2: every property read too
	timebase();
}

#define INTERPOSE(rep, orig) __attribute__((used)) static struct { const void* r; const void* o; } _ip_##orig \
	__attribute__((section("__DATA,__interpose"))) = { (const void*)&rep, (const void*)&orig }
INTERPOSE(my_GetPropertyData, AudioObjectGetPropertyData);
INTERPOSE(my_GetPropertyDataSize, AudioObjectGetPropertyDataSize);
INTERPOSE(my_HasProperty, AudioObjectHasProperty);
INTERPOSE(my_IsPropertySettable, AudioObjectIsPropertySettable);
INTERPOSE(my_SetPropertyData, AudioObjectSetPropertyData);
INTERPOSE(my_AddPropertyListener, AudioObjectAddPropertyListener);
INTERPOSE(my_AddPropertyListenerInternal, AudioObjectAddPropertyListenerInternal);
INTERPOSE(my_RemovePropertyListener, AudioObjectRemovePropertyListener);
INTERPOSE(my_AddPropertyListenerBlock, AudioObjectAddPropertyListenerBlock);
INTERPOSE(my_RemovePropertyListenerBlock, AudioObjectRemovePropertyListenerBlock);
INTERPOSE(my_ObjectExists, AudioObjectExists);
INTERPOSE(my_ObjectShow, AudioObjectShow);
INTERPOSE(my_CreateIOProcID, AudioDeviceCreateIOProcID);
INTERPOSE(my_CreateIOProcIDWithBlock, AudioDeviceCreateIOProcIDWithBlock);
INTERPOSE(my_DestroyIOProcID, AudioDeviceDestroyIOProcID);
INTERPOSE(my_Start, AudioDeviceStart);
INTERPOSE(my_StartAtTime, AudioDeviceStartAtTime);
INTERPOSE(my_Stop, AudioDeviceStop);
INTERPOSE(my_GetCurrentTime, AudioDeviceGetCurrentTime);
INTERPOSE(my_TranslateTime, AudioDeviceTranslateTime);
INTERPOSE(my_GetNearestStartTime, AudioDeviceGetNearestStartTime);
INTERPOSE(my_CreateAggregateDevice, AudioHardwareCreateAggregateDevice);
INTERPOSE(my_DestroyAggregateDevice, AudioHardwareDestroyAggregateDevice);
