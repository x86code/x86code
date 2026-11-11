// x86Sim: diagnostic shim: os_log messages to a file, without logd/diagnosticd.
// With X86SIM_NODT (OS_ACTIVITY_MODE=disable) os_log is off; DT mode streams to diagnosticd and blocks
// senders when it stalls. This interposes os_log_type_enabled (true) and _os_log_impl & co. and formats
// the message itself (scalars, strings, objects via -description; privacy annotations ignored).
// Only in processes named in X86SIM_OSLOG or data/oslog.filter (comma-separated program names, or "all").
// Log: data/var/log/oslog.<prog>.<pid>.log
#import <Foundation/Foundation.h>
#include "diagpath.h" // x86Sim: X86SIM_DATA_DIR (the device data directory, set by build/mac-build-diag.sh)
#include <os/log.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <pthread.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
	__attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void*) (unsigned long) &_replacement, (const void*) (unsigned long) &_replacee };

extern void _os_log_impl(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size);
extern void _os_log_error_impl(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size);
extern void _os_log_fault_impl(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size);
extern void _os_log_debug_impl(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size);

static int enabled = -1, fd = -1;
static __thread int busy;

static int on(void)
{
	if (enabled < 0) {
		const char* e = getenv("X86SIM_OSLOG");
		static char fbuf[1024];
#ifdef SIMSHIM_OSLOG
		// x86Sim: built into libsimshim (build/mac-build-arm64-shims.sh simshim) for `x86sim launch --oslog` / `x86sim log
		// stream --app`: only the environment (X86SIM_OSLOG, set for one app through FrontBoard's debug options;
		// DYLD_INSERT_LIBRARIES given that way is replaced by launchd's), log directory X86SIM_OSLOG_DIR
		const char* dir = getenv("X86SIM_OSLOG_DIR");
		if (!dir) e = NULL;
#else
		static char dirbuf[1100]; snprintf(dirbuf, sizeof(dirbuf), "%s/var/log", diag_data_dir());
		const char* dir = dirbuf;
		if (!e) {
			// or the first line of data/oslog.filter (jobs launched by runningboard don't get our environment)
			char fp[1100]; snprintf(fp, sizeof(fp), "%s/oslog.filter", diag_data_dir());
			int ffd = open(fp, O_RDONLY);
			if (ffd >= 0) { ssize_t n = read(ffd, fbuf, sizeof(fbuf) - 1); close(ffd); if (n > 0) { fbuf[n] = 0; fbuf[strcspn(fbuf, "\n")] = 0; e = fbuf; } }
		}
#endif
		const char* me = getprogname();
		int en = 0;
		if (e && me) {
			if (!strcmp(e, "all")) en = 1;
			else {
				char tmp[1024]; strlcpy(tmp, e, sizeof(tmp));
				for (char* t = strtok(tmp, ","); t; t = strtok(NULL, ",")) if (!strcmp(t, me)) en = 1;
			}
		}
		if (en) {
			char p[1024];
			snprintf(p, sizeof(p), "%s/oslog.%s.%d.log", dir, me, getpid());
			fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
		}
		enabled = en && fd >= 0;
	}
	return enabled;
}

static bool d_enabled(os_log_t log, os_log_type_t type)
{
	if (on()) return true;
	return os_log_type_enabled(log, type);
}
DYLD_INTERPOSE(d_enabled, os_log_type_enabled)

static void format(char* out, size_t outsz, const char* fmt, const uint8_t* buf, uint32_t size)
{
	size_t o = 0;
	const uint8_t* p = buf + 2;
	const uint8_t* end = buf + size;
	int nargs = size >= 2 ? buf[1] : 0, used = 0;
#define PUT(...) do { if (o < outsz) o += snprintf(out + o, outsz - o, __VA_ARGS__); } while (0)
	for (const char* f = fmt; *f && o < outsz - 1; f++) {
		if (*f != '%') { out[o++] = *f; out[o] = 0; continue; }
		if (f[1] == '%') { out[o++] = '%'; out[o] = 0; f++; continue; }
		// spec: %[{annot}][flags][width][.prec][len]conv
		const char* s = f + 1;
		if (*s == '{') { while (*s && *s != '}') s++; if (*s) s++; }
		char spec[32]; size_t k = 0; spec[k++] = '%';
		while (*s && strchr("-+ #0123456789.*", *s) && k < 20) spec[k++] = *s++;
		while (*s && strchr("hlqjztL", *s) && k < 26) spec[k++] = *s++;
		char conv = *s;
		if (!conv) break;
		spec[k++] = conv; spec[k] = 0;
		f = s;
		// skip count args (precision/width '*' or %.*P)
		const uint8_t* a = NULL; uint8_t desc = 0, asz = 0;
		while (used < nargs && p + 2 <= end) {
			desc = p[0]; asz = p[1]; a = p + 2; p += 2 + asz; used++;
			if ((desc >> 4) == 1) { a = NULL; continue; } // count
			break;
		}
		if (!a) { PUT("<?>"); continue; }
		int type = desc >> 4;
		if (desc & 0x1 && type != 0) { /* private */ }
		switch (conv) {
		case 'd': case 'i': case 'u': case 'x': case 'X': case 'o': case 'c': {
			long long v = 0;
			if (asz == 1) v = *(int8_t*) a; else if (asz == 2) v = *(int16_t*) a; else if (asz == 4) v = *(int32_t*) a; else if (asz == 8) v = *(int64_t*) a;
			char sp2[40]; size_t j = 0; sp2[j++] = '%';
			for (size_t q = 1; q < k - 1 && j < 30; q++) if (!strchr("hlqjztL*", spec[q])) sp2[j++] = spec[q];
			sp2[j++] = 'l'; sp2[j++] = 'l'; sp2[j++] = conv == 'c' ? 'd' : conv; sp2[j] = 0;
			PUT(sp2, v);
			break;
		}
		case 'f': case 'g': case 'e': {
			double v = asz == 8 ? *(double*) a : 0;
			PUT("%g", v);
			break;
		}
		case 's': {
			const char* str = asz == 8 ? *(const char**) a : NULL;
			PUT("%s", str ? str : "(null)");
			break;
		}
		case '@': {
			id obj = asz == 8 ? *(__unsafe_unretained id*) a : nil;
			const char* d = "(null)";
			@try { if (obj) d = [[obj description] UTF8String]; } @catch (id e) { d = "<exc>"; }
			PUT("%s", d ? d : "(null)");
			break;
		}
		case 'p': PUT("%p", asz == 8 ? *(void**) a : NULL); break;
		case 'P': PUT("<data>"); break;
		case 'm': PUT("<errno>"); break;
		default: PUT("<%c>", conv); break;
		}
	}
	out[o < outsz ? o : outsz - 1] = 0;
}

static void emit(os_log_t log, os_log_type_t type, const char* fmt, uint8_t* buf, uint32_t size)
{
	if (busy || !on()) return;
	busy = 1;
	// no lock: formatting calls -description, which may take locks other logging threads hold;
	// each line goes out in one write() (O_APPEND)
	static __thread char* out;
	static __thread char* line;
	if (!out) { out = malloc(8192); line = malloc(8400); }
	if (out && line) {
		@autoreleasepool {
			format(out, 8192, fmt, buf, size);
			struct timeval tv; gettimeofday(&tv, NULL);
			int n = snprintf(line, 8400, "%ld.%03d [%x] %s%s\n", (long) tv.tv_sec % 100000, (int) tv.tv_usec / 1000,
				(unsigned) pthread_mach_thread_np(pthread_self()),
				type == OS_LOG_TYPE_ERROR ? "E: " : type == OS_LOG_TYPE_FAULT ? "F: " : "", out);
			write(fd, line, n < 8400 ? n : 8399);
			// x86Sim: call stack for messages containing the first line of data/oslog.bt (max 8 per process)
			static char bt[256]; static int btinit, btn;
#ifndef SIMSHIM_OSLOG
			if (!btinit) { btinit = 1; char bp[1100]; snprintf(bp, sizeof(bp), "%s/oslog.bt", diag_data_dir()); int bfd = open(bp, O_RDONLY);
				if (bfd >= 0) { ssize_t k = read(bfd, bt, sizeof(bt) - 1); close(bfd); if (k > 0) { bt[k] = 0; char* nl = strchr(bt, '\n'); if (nl) *nl = 0; } } }
			if (bt[0] && btn < 8 && strstr(out, bt)) { btn++; const char* st = [[[NSThread callStackSymbols] description] UTF8String]; write(fd, st, strlen(st)); write(fd, "\n", 1); }
#else
			(void) bt; (void) btinit; (void) btn;
#endif
		}
	}
	busy = 0;
}

static void d_impl(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size)
{
	emit(log, type, format, buf, size);
	if (!on()) _os_log_impl(dso, log, type, format, buf, size); // the real one crashes on a forced-enabled log
}
DYLD_INTERPOSE(d_impl, _os_log_impl)
static void d_error(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size)
{
	emit(log, OS_LOG_TYPE_ERROR, format, buf, size);
	if (!on()) _os_log_error_impl(dso, log, type, format, buf, size); // the real one crashes on a forced-enabled log
}
DYLD_INTERPOSE(d_error, _os_log_error_impl)
static void d_fault(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size)
{
	emit(log, OS_LOG_TYPE_FAULT, format, buf, size);
	if (!on()) _os_log_fault_impl(dso, log, type, format, buf, size); // the real one crashes on a forced-enabled log
}
DYLD_INTERPOSE(d_fault, _os_log_fault_impl)
static void d_debug(void* dso, os_log_t log, os_log_type_t type, const char* format, uint8_t* buf, uint32_t size)
{
	emit(log, type, format, buf, size);
	if (!on()) _os_log_debug_impl(dso, log, type, format, buf, size); // the real one crashes on a forced-enabled log
}
DYLD_INTERPOSE(d_debug, _os_log_debug_impl)
