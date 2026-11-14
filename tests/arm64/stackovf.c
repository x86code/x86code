// GitHub issue #2: a guest stack overflow must fault at the bottom of the thread's stack, not run on into the next
// mapping. Guest code runs on libarm64jit's own 8 MB stacks (GuestThread), which had no guard page: a runaway
// recursion silently wrote into whatever lay below (another thread's guest stack, JIT metadata, malloc memory). The
// Duo's backboardd then died later of the corruption (Xbyak "offset is too big" in EmitX64::Patch, a jump to a data
// page, guest pc 0x2) instead of at the overflow.
// A thread recurses ~9.2 MB deep (1 KB frames). Expected: the process is killed at its first store below the stack
// with "arm64host: guest stack overflow" on stderr and never prints SURVIVED. (Before the guard it either survived,
// having written into a writable mapping below, or died later as "fatal native fault" / "fault inside the fault
// handler", depending on what the layout put below the stack.)
//   tests/arm64/run.sh tests/arm64/stackovf.sim
#include <pthread.h>
#include <stdio.h>
// each level hands its frame to the next, which reads it after its own call returns: no tail/accumulator recursion
static unsigned long recurse(unsigned long n, volatile unsigned char* up) {
    volatile unsigned char pad[1024];
    pad[0] = (unsigned char)n;
    pad[1023] = (unsigned char)(n >> 8);
    unsigned long r = n ? recurse(n - 1, pad) : 0;
    return r + pad[0] + pad[1023] + (up ? up[0] : 0);
}
static void* runner(void* arg) {
    (void)arg;
    printf("recursion returned (%lu)\n", recurse(8400, NULL));
    return NULL;
}
int main(void) {
    pthread_t r;
    pthread_create(&r, NULL, runner, NULL);
    pthread_join(r, NULL);
    printf("SURVIVED: a 9 MB recursion on an 8 MB guest stack did not fault\n");
    return 1;
}
