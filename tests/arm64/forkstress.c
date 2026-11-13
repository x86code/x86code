// x86Sim (2026-11-13): fork while other threads allocate. libarm64jit's native guest heap (gheap.cpp, malloc.cpp) has
// its own locks; a fork() while another thread held one left it held in the child, whose first malloc then waited
// forever (launchd_sim's spawn child: a boot hung, black, every process idle). Darwin's fork() takes the malloc locks
// around the fork (_malloc_fork_prepare / _parent / _child, which libarm64jit implements).
// Usage: forkstress [forks] [threads]   prints "FORKSTRESS: N forks, 0 hung" (exit 0) or the hung count (exit 1)
// In a booted device (tests/arm64/run.sh's darling shell did not start binaries here), as a dylib in an app: build
// it with `#define main forkstress_main` and a constructor thread that calls it, inject it with
//   x86sim launch --console --env X86SIM_A64_DYLD_INSERT_LIBRARIES=<sim.env inserts>:<dylib> com.apple.Preferences
// and read FORKSTRESS from the console (2026-11-13: 2-5 of 200 forks hung before the fork fixes, 0 of 2400 after).
// FORKSTRESS_CORE=1: SIGQUIT a hung child first, for a systemd-coredump core (see ~/scratch/g1/corewhere.py).
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static atomic_int stop;

static void *churn(void *arg)
{
	unsigned s = (unsigned)(uintptr_t)arg;
	void *keep[64] = {0};
	while (!atomic_load(&stop)) {
		for (int i = 0; i < 64; i++) {
			s = s * 1103515245u + 12345u;
			free(keep[i]);
			// small classes and the occasional large block
			size_t n = (s >> 8) % 7 == 0 ? 40000 + (s & 0xffff) : 16 + (s >> 16) % 2048;
			keep[i] = malloc(n);
			if (keep[i]) memset(keep[i], 1, n < 64 ? n : 64);
		}
	}
	for (int i = 0; i < 64; i++) free(keep[i]);
	return NULL;
}

int main(int argc, char **argv)
{
	int forks = argc > 1 ? atoi(argv[1]) : 300, nthreads = argc > 2 ? atoi(argv[2]) : 6;
	pthread_t th[32];
	for (int i = 0; i < nthreads && i < 32; i++) pthread_create(&th[i], NULL, churn, (void *)(uintptr_t)(i * 7919 + 1));
	int hung = 0;
	for (int f = 0; f < forks; f++) {
		pid_t pid = fork();
		if (pid == 0) {
			// the child: allocate (every size class path) and leave
			for (int i = 0; i < 200; i++) free(malloc(16 + i * 37));
			free(malloc(100000));
			_exit(0);
		}
		if (pid < 0) { perror("fork"); break; }
		// up to 5 s for the child
		int st, done = 0;
		for (int t = 0; t < 500 && !done; t++) {
			if (waitpid(pid, &st, WNOHANG) == pid) done = 1;
			else { struct timespec ts = {0, 10 * 1000 * 1000}; nanosleep(&ts, NULL); }
		}
		if (!done) {
			hung++;
			fprintf(stderr, "forkstress: child %d of fork %d hung\n", pid, f);
			// FORKSTRESS_CORE=1: SIGQUIT first, for a core of the hung child (systemd-coredump)
			if (getenv("FORKSTRESS_CORE")) { kill(pid, SIGQUIT); sleep(3); }
			kill(pid, SIGKILL);
			waitpid(pid, &st, 0);
		}
	}
	atomic_store(&stop, 1);
	for (int i = 0; i < nthreads && i < 32; i++) pthread_join(th[i], NULL);
	fprintf(stderr, "FORKSTRESS: %d forks, %d hung\n", forks, hung);
	return hung ? 1 : 0;
}
