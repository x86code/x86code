// FEAT_FP16 Advanced SIMD, instruction by instruction: every combination of 20 special values in three operands
// (zeros, ones, infinities, quiet and signalling NaNs, subnormals, max) plus 2 x 16384 random lanes (raw bit patterns
// and ordinary values), one hash per instruction. fp16x.expected is the output on Apple M-series hardware; under
// x86Sim compare line by line (tests/arm64/run.sh fp16x.sim | diff - tests/arm64/fp16x.expected).
// Line: <name> <hash with every NaN folded to 0x7e00> <raw hash> <NaN results>
// Usage: fp16x            every hash
//        fp16x dump NAME  that instruction's inputs and results, one vector per line (to find a difference)
// Build: xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -mcpu=apple-m1 -O1 -o fp16x.sim fp16x.c
//        (on the Mac itself: xcrun -sdk macosx clang -O1 -mcpu=apple-m1 -o fp16x.mac fp16x.c)
#include <arm_neon.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define NSPEC 20
static const uint16_t spec[NSPEC] = {0x0000, 0x8000, 0x3c00, 0xbc00, 0x7c00, 0xfc00, 0x7e00, 0xfe01, 0x7d00, 0x0001,
                                     0x8001, 0x03ff, 0x0400, 0x7bff, 0xfbff, 0x3555, 0x4248, 0x3800, 0x4200, 0x0200};
#define L (NSPEC * NSPEC * NSPEC + 16384 + 16384)
static uint16_t A[L + 8], B[L + 8], C[L + 8];
static uint32_t rng = 12345;
static uint32_t rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 8; }
static uint16_t real16(void) {  // ordinary values, about 2^-6 .. 2^5
    uint32_t r = rnd();
    return (uint16_t)(((r & 1) << 15) | ((9 + (r >> 1) % 12) << 10) | ((r >> 5) & 0x3ff));
}
static void gen(void) {
    int k = 0;
    for (int i = 0; i < NSPEC; i++)
        for (int j = 0; j < NSPEC; j++)
            for (int m = 0; m < NSPEC; m++, k++) { A[k] = spec[i]; B[k] = spec[j]; C[k] = spec[m]; }
    for (int i = 0; i < 16384; i++, k++) { A[k] = (uint16_t)rnd(); B[k] = (uint16_t)rnd(); C[k] = (uint16_t)rnd(); }
    for (int i = 0; i < 16384; i++, k++) { A[k] = real16(); B[k] = real16(); C[k] = real16(); }
}

static const char *dump_name;
static uint32_t hc, hr, nnan;
static void acc(const char *name, const void *r, int lanes, int i) {
    const uint16_t *u = (const uint16_t *)r;
    for (int l = 0; l < lanes; l++) {
        uint16_t v = u[l];
        hr = hr * 31 + v;
        if ((v & 0x7c00) == 0x7c00 && (v & 0x3ff)) { nnan++; v = 0x7e00; }
        hc = hc * 31 + v;
    }
    if (dump_name && !strcmp(dump_name, name)) {
        printf("%d", i);
        for (int l = 0; l < lanes; l++) printf(" %04x,%04x,%04x>%04x", A[i + l], B[i + l], C[i + l], u[l]);
        printf("\n");
    }
}
static void start(void) { hc = hr = nnan = 0; }
static void end(const char *name) { if (!dump_name) printf("%-14s %08x %08x %5u\n", name, hc, hr, nnan); }

typedef float16x8_t q8;
typedef float16x4_t d4;
#define LDQ(p, i) vld1q_f16((const float16_t *)(p) + (i))
#define LDD(p, i) vld1_f16((const float16_t *)(p) + (i))

// three-same (vector .8h / .4h)
#define T3Q(NAME, INS) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), b = LDQ(B, i), r; \
    __asm__ volatile(INS " %0.8h, %1.8h, %2.8h" : "=w"(r) : "w"(a), "w"(b)); acc(NAME, &r, 8, i); } end(NAME); }
#define T3D(NAME, INS) { start(); for (int i = 0; i < L; i += 4) { d4 a = LDD(A, i), b = LDD(B, i), r; \
    __asm__ volatile(INS " %0.4h, %1.4h, %2.4h" : "=w"(r) : "w"(a), "w"(b)); acc(NAME, &r, 4, i); } end(NAME); }
// accumulating (FMLA / FMLS)
#define T3AQ(NAME, INS) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), b = LDQ(B, i), r = LDQ(C, i); \
    __asm__ volatile(INS " %0.8h, %1.8h, %2.8h" : "+w"(r) : "w"(a), "w"(b)); acc(NAME, &r, 8, i); } end(NAME); }
#define T3AD(NAME, INS) { start(); for (int i = 0; i < L; i += 4) { d4 a = LDD(A, i), b = LDD(B, i), r = LDD(C, i); \
    __asm__ volatile(INS " %0.4h, %1.4h, %2.4h" : "+w"(r) : "w"(a), "w"(b)); acc(NAME, &r, 4, i); } end(NAME); }
// by element (Rm is v0-v15: "x")
#define TEQ(NAME, INS, IDX) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), b = LDQ(B, i), r; \
    __asm__ volatile(INS " %0.8h, %1.8h, %2.h[" #IDX "]" : "=w"(r) : "w"(a), "x"(b)); acc(NAME, &r, 8, i); } end(NAME); }
#define TED(NAME, INS, IDX) { start(); for (int i = 0; i < L; i += 4) { d4 a = LDD(A, i), r; q8 b = LDQ(B, i); \
    __asm__ volatile(INS " %0.4h, %1.4h, %2.h[" #IDX "]" : "=w"(r) : "w"(a), "x"(b)); acc(NAME, &r, 4, i); } end(NAME); }
#define TEAQ(NAME, INS, IDX) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), b = LDQ(B, i), r = LDQ(C, i); \
    __asm__ volatile(INS " %0.8h, %1.8h, %2.h[" #IDX "]" : "+w"(r) : "w"(a), "x"(b)); acc(NAME, &r, 8, i); } end(NAME); }
#define TEAD(NAME, INS, IDX) { start(); for (int i = 0; i < L; i += 4) { d4 a = LDD(A, i), r = LDD(C, i); q8 b = LDQ(B, i); \
    __asm__ volatile(INS " %0.4h, %1.4h, %2.h[" #IDX "]" : "+w"(r) : "w"(a), "x"(b)); acc(NAME, &r, 4, i); } end(NAME); }
// two-register misc (vector)
#define T2Q(NAME, INS) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), r; \
    __asm__ volatile(INS " %0.8h, %1.8h" : "=w"(r) : "w"(a)); acc(NAME, &r, 8, i); } end(NAME); }
#define T2D(NAME, INS) { start(); for (int i = 0; i < L; i += 4) { d4 a = LDD(A, i), r; \
    __asm__ volatile(INS " %0.4h, %1.4h" : "=w"(r) : "w"(a)); acc(NAME, &r, 4, i); } end(NAME); }
#define T2ZQ(NAME, INS) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), r; \
    __asm__ volatile(INS " %0.8h, %1.8h, #0.0" : "=w"(r) : "w"(a)); acc(NAME, &r, 8, i); } end(NAME); }
// scalar pairwise (FADDP h etc.: the low two lanes)
#define TPS(NAME, INS) { start(); for (int i = 0; i < L; i += 2) { q8 a = LDQ(A, i), r = vdupq_n_f16(0); \
    __asm__ volatile(INS " %h0, %1.2h" : "=w"(r) : "w"(a)); acc(NAME, &r, 1, i); } end(NAME); }
// scalar three-same (h)
#define T3S(NAME, INS) { start(); for (int i = 0; i < L; i++) { q8 a = LDQ(A, i), b = LDQ(B, i), r; \
    __asm__ volatile(INS " %h0, %h1, %h2" : "=w"(r) : "w"(a), "w"(b)); acc(NAME, &r, 1, i); } end(NAME); }
// across lanes
#define TVQ(NAME, INS) { start(); for (int i = 0; i < L; i += 8) { q8 a = LDQ(A, i), r = vdupq_n_f16(0); \
    __asm__ volatile(INS " %h0, %1.8h" : "=w"(r) : "w"(a)); acc(NAME, &r, 1, i); } end(NAME); }

static void run_all(void) {
    T3Q("fadd.8h", "fadd") T3D("fadd.4h", "fadd") T3Q("fsub.8h", "fsub") T3D("fsub.4h", "fsub")
    T3Q("fmul.8h", "fmul") T3D("fmul.4h", "fmul") T3Q("fdiv.8h", "fdiv") T3D("fdiv.4h", "fdiv")
    T3Q("fmax.8h", "fmax") T3D("fmax.4h", "fmax") T3Q("fmin.8h", "fmin") T3D("fmin.4h", "fmin")
    T3Q("fmaxnm.8h", "fmaxnm") T3D("fmaxnm.4h", "fmaxnm") T3Q("fminnm.8h", "fminnm") T3D("fminnm.4h", "fminnm")
    T3Q("fabd.8h", "fabd") T3D("fabd.4h", "fabd") T3Q("fmulx.8h", "fmulx") T3D("fmulx.4h", "fmulx")
    T3Q("frecps.8h", "frecps") T3D("frecps.4h", "frecps") T3Q("frsqrts.8h", "frsqrts") T3D("frsqrts.4h", "frsqrts")
    T3Q("fcmeq.8h", "fcmeq") T3Q("fcmge.8h", "fcmge") T3Q("fcmgt.8h", "fcmgt") T3Q("facge.8h", "facge") T3Q("facgt.8h", "facgt")
    T3Q("faddp.8h", "faddp") T3D("faddp.4h", "faddp") T3Q("fmaxp.8h", "fmaxp") T3Q("fminp.8h", "fminp")
    T3Q("fmaxnmp.8h", "fmaxnmp") T3Q("fminnmp.8h", "fminnmp")
    T3AQ("fmla.8h", "fmla") T3AD("fmla.4h", "fmla") T3AQ("fmls.8h", "fmls") T3AD("fmls.4h", "fmls")
    TEQ("fmul.8h[3]", "fmul", 3) TED("fmul.4h[0]", "fmul", 0) TED("fmul.4h[5]", "fmul", 5) TEQ("fmulx.8h[7]", "fmulx", 7)
    TEAQ("fmla.8h[2]", "fmla", 2) TEAD("fmla.4h[6]", "fmla", 6) TEAQ("fmls.8h[1]", "fmls", 1) TEAD("fmls.4h[4]", "fmls", 4)
    T2Q("fabs.8h", "fabs") T2Q("fneg.8h", "fneg") T2Q("fsqrt.8h", "fsqrt") T2D("fsqrt.4h", "fsqrt")
    T2Q("frecpe.8h", "frecpe") T2Q("frsqrte.8h", "frsqrte") T2D("frsqrte.4h", "frsqrte")
    T2Q("frintn.8h", "frintn") T2Q("frintm.8h", "frintm") T2Q("frintp.8h", "frintp") T2Q("frintz.8h", "frintz")
    T2Q("frinta.8h", "frinta") T2Q("frintx.8h", "frintx") T2Q("frinti.8h", "frinti")
    T2Q("fcvtzs.8h", "fcvtzs") T2D("fcvtzs.4h", "fcvtzs") T2Q("fcvtzu.8h", "fcvtzu") T2Q("fcvtns.8h", "fcvtns")
    T2Q("fcvtms.8h", "fcvtms") T2Q("fcvtas.8h", "fcvtas") T2Q("fcvtps.8h", "fcvtps") T2Q("fcvtnu.8h", "fcvtnu")
    T2Q("scvtf.8h", "scvtf") T2D("scvtf.4h", "scvtf") T2Q("ucvtf.8h", "ucvtf")
    T2ZQ("fcmeq0.8h", "fcmeq") T2ZQ("fcmge0.8h", "fcmge") T2ZQ("fcmgt0.8h", "fcmgt") T2ZQ("fcmle0.8h", "fcmle") T2ZQ("fcmlt0.8h", "fcmlt")
    TPS("faddp.h", "faddp") TPS("fmaxnmp.h", "fmaxnmp") TPS("fminnmp.h", "fminnmp") TPS("fmaxp.h", "fmaxp") TPS("fminp.h", "fminp")
    T3S("fabd.h", "fabd") T3S("fmulx.h", "fmulx") T3S("frecps.h", "frecps") T3S("frsqrts.h", "frsqrts")
    TVQ("fmaxnmv.8h", "fmaxnmv") TVQ("fminnmv.8h", "fminnmv") TVQ("fmaxv.8h", "fmaxv") TVQ("fminv.8h", "fminv")
}

static void set_rmode(unsigned m) {  // FPCR.RMode = bits 23:22
    uint64_t f;
    __asm__ volatile("mrs %0, fpcr" : "=r"(f));
    f = (f & ~(3ull << 22)) | ((uint64_t)m << 22);
    __asm__ volatile("msr fpcr, %0" : : "r"(f));
}

int main(int argc, char **argv) {
    if (argc > 2 && !strcmp(argv[1], "dump")) dump_name = argv[2];
    gen();
    run_all();
    // rounding modes: a few instructions that round their result, again under RZ and RP
    for (unsigned m = 1; m <= 3; m += 2) {
        set_rmode(m == 1 ? 3 : 1);
        const char *t = m == 1 ? "RZ" : "RP";
        char n1[32], n2[32], n3[32], n4[32], n5[32];
        snprintf(n1, 32, "fadd.8h.%s", t); snprintf(n2, 32, "fmul.4h.%s", t); snprintf(n3, 32, "fmla.8h.%s", t);
        snprintf(n4, 32, "fdiv.8h.%s", t); snprintf(n5, 32, "frintx.8h.%s", t);
        T3Q(n1, "fadd") T3D(n2, "fmul") T3AQ(n3, "fmla") T3Q(n4, "fdiv") T2Q(n5, "frintx")
        set_rmode(0);
    }
    if (!dump_name) printf("done %d lanes\n", L);
    return 0;
}
