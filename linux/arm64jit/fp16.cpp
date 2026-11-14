// libarm64jit: FEAT_FP16 Advanced SIMD instructions that dynarmic doesn't translate.
//
// iOS 27's RenderBox, CoreImage, Vision, ... use half-precision vector arithmetic (about 70k instructions in the
// shared cache: fmla/fmul by element, three-same arithmetic and compares, conversions). dynarmic hands each of them to
// UserCallbacks::InterpreterFallback; this file executes them on the flushed guest state. Arithmetic lanes are computed
// in binary64 and rounded to binary16 in FPCR's rounding mode (d2h: correctly rounded for add/sub/mul/div/sqrt; fused
// multiply-add can be one ulp off under a directed mode, see fma_h); NaNs follow Arm's FPProcessNaNs. FZ16, DN, AH and
// the FPSR flags are not modelled.
#include "a64.h"
#include <cmath>
#include <cstdint>
#include <cstring>

namespace a64 {

namespace {
using V = Dynarmic::A64::Vector;
inline float h2f(uint16_t h) { _Float16 f; memcpy(&f, &h, 2); return (float)f; }
inline uint16_t f2h(float x) { _Float16 f = (_Float16)x; uint16_t h; memcpy(&h, &f, 2); return h; }
inline uint16_t lane(const V &v, int i) { return (uint16_t)(v[i / 4] >> (16 * (i % 4))); }
inline void set_lane(V &v, int i, uint16_t h) {
    u64 &w = v[i / 4]; int s = 16 * (i % 4);
    w = (w & ~(0xffffull << s)) | ((u64)h << s);
}
inline bool isnan_h(uint16_t h) { return (h & 0x7c00) == 0x7c00 && (h & 0x3ff); }
inline bool issnan_h(uint16_t h) { return isnan_h(h) && !(h & 0x200); }
// FPProcessNaNs: a signalling NaN first (operand 1, then 2), then a quiet one; the result is quiet (FPCR.DN = 0)
inline uint16_t qnan(uint16_t a, uint16_t b) {
    if (issnan_h(a)) return a | 0x200;
    if (issnan_h(b)) return b | 0x200;
    return (isnan_h(a) ? a : b) | 0x200;
}
// x rounded to binary16 in the FPCR rounding mode m (0 RN, 1 RP, 2 RM, 3 RZ). A sum, difference or product of two
// halves is exact in binary64, and a quotient or square root of halves can't fall within 2^-53 (relative) of a half
// without being one, so rounding binary64's (round-to-nearest) value once more in m gives the correctly rounded half.
// (binary32 is enough for round-to-nearest only: its rounding before a directed one is visible.)
inline uint16_t d2h(double x, int m) {
    const _Float16 f = (_Float16)x;
    uint16_t h; memcpy(&h, &f, 2);
    if (m == 0 || std::isnan(x)) return h;
    const double back = (double)f;
    if (back == x) return h;
    const bool want_up = m == 1 || (m == 3 && x < 0);  // the result must not be below x (RP; RZ of a negative)
    if (want_up ? back > x : back < x) return h;       // round-to-nearest already went the right way
    // one step in the wanted direction: within a sign, half bit patterns order like magnitudes
    return (x > 0) == want_up ? (uint16_t)(h + 1) : (uint16_t)(h - 1);
}
// x + y in mode m: an exact zero sum of operands of opposite sign is -0 only when rounding toward -inf
inline uint16_t add_h(uint16_t x, uint16_t y, int m) {
    if (isnan_h(x) || isnan_h(y)) return qnan(x, y);
    const double r = (double)h2f(x) + (double)h2f(y);
    if (std::isnan(r)) return 0x7e00;
    if (r == 0 && !((x & 0x7fff) == 0 && (y & 0x7fff) == 0 && (x >> 15) == (y >> 15))) return m == 2 ? 0x8000 : 0;
    return d2h(r, m);
}
// Arm's default NaN (an invalid operation without a NaN operand: inf - inf, 0 * inf, 0 / 0, sqrt(-x)); x86 makes -NaN
inline uint16_t arith(uint16_t r) { return isnan_h(r) ? 0x7e00 : r; }
inline bool isinf_h(uint16_t h) { return (h & 0x7fff) == 0x7c00; }
inline bool iszero_h(uint16_t h) { return (h & 0x7fff) == 0; }
// FPMulAdd(addend, op1, op2), fused, in mode m (FMLA; FMLS negates op1 first). NaNs: FPProcessNaNs3 (signalling addend,
// op1, op2, then quiet), and a quiet-NaN addend with an inf * 0 product is the default NaN. The product of two halves is
// exact; the sum is rounded once in binary64 (std::fma) and once more to binary16 (exact for round-to-nearest; a
// directed mode can be off by one ulp when the addend dwarfs a tiny product by more than 2^53).
inline uint16_t fma_h(uint16_t d, uint16_t x, uint16_t y, int m) {
    const bool inv_prod = (isinf_h(x) && iszero_h(y)) || (iszero_h(x) && isinf_h(y));
    if (isnan_h(d) || isnan_h(x) || isnan_h(y)) {
        if (isnan_h(d) && !issnan_h(d) && inv_prod && !issnan_h(x) && !issnan_h(y)) return 0x7e00;
        if (issnan_h(d)) return d | 0x200;
        if (issnan_h(x)) return x | 0x200;
        if (issnan_h(y)) return y | 0x200;
        if (isnan_h(d)) return d | 0x200;
        return (isnan_h(x) ? x : y) | 0x200;
    }
    const double r = std::fma((double)h2f(x), (double)h2f(y), (double)h2f(d));
    if (std::isnan(r)) return 0x7e00;
    if (r == 0) {  // an exact zero: zeros of one sign keep it, otherwise -0 only when rounding toward -inf
        const bool pz = iszero_h(x) || iszero_h(y), ps = ((x ^ y) >> 15) & 1;
        if (pz && iszero_h(d) && ps == (d >> 15)) return ps ? 0x8000 : 0;
        return m == 2 ? 0x8000 : 0;
    }
    return d2h(r, m);
}
// FRECPS / FRSQRTS (FPRecipStepFused / FPRSqrtStepFused): op1 is negated first (a NaN op1 comes back with its sign
// flipped), inf * 0 is 2.0 / 1.5, otherwise 2 - op1 * op2 (/ 2) fused (exact in binary64, rounded once)
inline uint16_t step_h(uint16_t x, uint16_t y, bool rsqrt, int m) {
    x ^= 0x8000;
    if (isnan_h(x) || isnan_h(y)) return qnan(x, y);
    if ((isinf_h(x) && iszero_h(y)) || (iszero_h(x) && isinf_h(y))) return rsqrt ? 0x3e00 : 0x4000;
    const double r = (rsqrt ? 3.0 : 2.0) + (double)h2f(x) * h2f(y);
    return arith(d2h(rsqrt ? r / 2 : r, m));
}

float fmax_(float a, float b) { return a > b ? a : b; }
float fmin_(float a, float b) { return a < b ? a : b; }
uint16_t fmax_h(uint16_t a, uint16_t b) { if (isnan_h(a) || isnan_h(b)) return qnan(a, b); float x = h2f(a), y = h2f(b); if (x == 0 && y == 0) return (a & b); return f2h(fmax_(x, y)); }
uint16_t fmin_h(uint16_t a, uint16_t b) { if (isnan_h(a) || isnan_h(b)) return qnan(a, b); float x = h2f(a), y = h2f(b); if (x == 0 && y == 0) return (a | b); return f2h(fmin_(x, y)); }
// FPMaxNum / FPMinNum: only a quiet NaN against an operand that is not a quiet NaN drops out (it becomes -inf / +inf);
// a signalling NaN still goes through the FPMax / FPMin NaN rules (a quiet NaN comes back), and so do signed zeros.
uint16_t maxnm(uint16_t a, uint16_t b) {
    const bool qa = isnan_h(a) && !issnan_h(a), qb = isnan_h(b) && !issnan_h(b);
    if (qa && !qb) a = 0xfc00;
    else if (qb && !qa) b = 0xfc00;
    return fmax_h(a, b);
}
uint16_t minnm(uint16_t a, uint16_t b) {
    const bool qa = isnan_h(a) && !issnan_h(a), qb = isnan_h(b) && !issnan_h(b);
    if (qa && !qb) a = 0x7c00;
    else if (qb && !qa) b = 0x7c00;
    return fmin_h(a, b);
}

// three-same: (U, a, opcode) -> lane op. Returns false for unallocated.
bool op3(int U, int a, int opc, uint16_t x, uint16_t y, uint16_t d, uint16_t &r, int m = 0) {
    float fx = h2f(x), fy = h2f(y);
    switch ((U << 4) | (a << 3) | opc) {
    case 0b00000: r = maxnm(x, y); return true;                               // FMAXNM
    case 0b00001: r = fma_h(d, x, y, m); return true;                         // FMLA
    case 0b00010: r = add_h(x, y, m); return true;                            // FADD
    case 0b00011:                                                              // FMULX: inf * 0 = +-2
        r = isnan_h(x) || isnan_h(y) ? qnan(x, y)
            : ((std::isinf(fx) && fy == 0) || (fx == 0 && std::isinf(fy))) ? f2h(std::signbit(fx) != std::signbit(fy) ? -2.0f : 2.0f)
                                                                          : d2h((double)fx * fy, m);
        return true;
    case 0b00100: r = fx == fy ? 0xffff : 0; return true;                     // FCMEQ
    case 0b00110: r = fmax_h(x, y); return true;                              // FMAX
    case 0b00111: r = step_h(x, y, false, m); return true;                    // FRECPS
    case 0b01000: r = minnm(x, y); return true;                               // FMINNM
    case 0b01001: r = fma_h(d, x ^ 0x8000, y, m); return true;                // FMLS
    case 0b01010: r = isnan_h(x) || isnan_h(y) ? qnan(x, y) : add_h(x, y ^ 0x8000, m); return true;  // FSUB
    case 0b01110: r = fmin_h(x, y); return true;                              // FMIN
    case 0b01111: r = step_h(x, y, true, m); return true;                     // FRSQRTS
    case 0b10011: r = isnan_h(x) || isnan_h(y) ? qnan(x, y) : arith(d2h((double)fx * fy, m)); return true;  // FMUL
    case 0b10100: r = fx >= fy ? 0xffff : 0; return true;                     // FCMGE
    case 0b10101: r = std::fabs(fx) >= std::fabs(fy) ? 0xffff : 0; return true;  // FACGE
    case 0b10111: r = isnan_h(x) || isnan_h(y) ? qnan(x, y) : arith(d2h((double)fx / fy, m)); return true;  // FDIV
    case 0b11010: r = (isnan_h(x) || isnan_h(y) ? qnan(x, y) : add_h(x, y ^ 0x8000, m)) & 0x7fff; return true;  // FABD
    case 0b11100: r = fx > fy ? 0xffff : 0; return true;                      // FCMGT
    case 0b11101: r = std::fabs(fx) > std::fabs(fy) ? 0xffff : 0; return true;  // FACGT
    }
    return false;
}
// pairwise ops of three-same (U=1): FMAXNMP 000, FADDP 010, FMAXP 110; a=1: FMINNMP 000, FMINP 110
bool pairwise(int a, int opc, uint16_t x, uint16_t y, uint16_t &r, int m = 0) {
    switch ((a << 3) | opc) {
    case 0b0000: r = maxnm(x, y); return true;
    case 0b0010: r = add_h(x, y, m); return true;
    case 0b0110: r = fmax_h(x, y); return true;
    case 0b1000: r = minnm(x, y); return true;
    case 0b1110: r = fmin_h(x, y); return true;
    }
    return false;
}

float round_mode(float x, int mode) {  // 0 nearest-even, 1 +inf, 2 -inf, 3 zero, 4 ties-away
    switch (mode) {
    case 0: return std::nearbyint(x);
    case 1: return std::ceil(x);
    case 2: return std::floor(x);
    case 3: return std::trunc(x);
    default: return std::round(x);
    }
}
uint16_t cvt_int(float x, int mode, bool is_unsigned) {
    if (std::isnan(x)) return 0;
    float r = round_mode(x, mode);
    if (is_unsigned) return r <= 0 ? 0 : r >= 65535.f ? 0xffff : (uint16_t)r;
    return (uint16_t)(int16_t)(r <= -32768.f ? -32768 : r >= 32767.f ? 32767 : (int)r);
}
int fpcr_mode(GuestThread &t) {
    switch ((t.jit->GetFpcr() >> 22) & 3) { case 0: return 0; case 1: return 1; case 2: return 2; default: return 3; }
}
// two-reg misc: (U, a, opcode) -> lane op
bool op2(GuestThread &t, int U, int a, int opc, uint16_t x, uint16_t &r) {
    float f = h2f(x);
    switch ((U << 6) | (a << 5) | opc) {
    case 0b0011000: r = f2h(round_mode(f, 0)); return true;   // FRINTN
    case 0b0011001: r = f2h(round_mode(f, 2)); return true;   // FRINTM
    case 0b0011010: r = cvt_int(f, 0, false); return true;    // FCVTNS
    case 0b0011011: r = cvt_int(f, 2, false); return true;    // FCVTMS
    case 0b0011100: r = cvt_int(f, 4, false); return true;    // FCVTAS
    case 0b0011101: r = f2h((float)(int16_t)x); return true;  // SCVTF
    case 0b0101100: r = f > 0 ? 0xffff : 0; return true;      // FCMGT #0
    case 0b0101101: r = f == 0 ? 0xffff : 0; return true;     // FCMEQ #0
    case 0b0101110: r = f < 0 ? 0xffff : 0; return true;      // FCMLT #0
    case 0b0101111: r = x & 0x7fff; return true;              // FABS
    case 0b0111000: r = f2h(round_mode(f, 1)); return true;   // FRINTP
    case 0b0111001: r = f2h(round_mode(f, 3)); return true;   // FRINTZ
    case 0b0111010: r = cvt_int(f, 1, false); return true;    // FCVTPS
    case 0b0111011: r = cvt_int(f, 3, false); return true;    // FCVTZS
    case 0b0111101: r = f2h(1.0f / f); return true;           // FRECPE (exact reciprocal; ARM's is an estimate)
    case 0b1011000: r = f2h(round_mode(f, 4)); return true;   // FRINTA
    case 0b1011001: r = f2h(round_mode(f, fpcr_mode(t))); return true;  // FRINTX
    case 0b1011010: r = cvt_int(f, 0, true); return true;     // FCVTNU
    case 0b1011011: r = cvt_int(f, 2, true); return true;     // FCVTMU
    case 0b1011100: r = cvt_int(f, 4, true); return true;     // FCVTAU
    case 0b1011101: r = f2h((float)x); return true;           // UCVTF
    case 0b1101100: r = f >= 0 ? 0xffff : 0; return true;     // FCMGE #0
    case 0b1101101: r = f <= 0 ? 0xffff : 0; return true;     // FCMLE #0
    case 0b1101111: r = x ^ 0x8000; return true;              // FNEG
    case 0b1111001: r = f2h(round_mode(f, fpcr_mode(t))); return true;  // FRINTI
    case 0b1111010: r = cvt_int(f, 1, true); return true;     // FCVTPU
    case 0b1111011: r = cvt_int(f, 3, true); return true;     // FCVTZU
    case 0b1111101: r = f2h(1.0f / std::sqrt(f)); return true;  // FRSQRTE (exact; ARM's is an estimate)
    case 0b1111111: r = isnan_h(x) ? qnan(x, x) : arith(d2h(std::sqrt((double)f), fpcr_mode(t))); return true;  // FSQRT
    }
    return false;
}
}  // namespace

// Executes the FP16 SIMD instruction insn (at pc) on t's guest state. False if it isn't one we know.
// FJCVTZS Wd, Dn (FEAT_JSCVT, Speed 26): JavaScript ToInt32 of a double (round toward zero, modulo 2^32), PSTATE.Z
// set when the conversion is exact (no fraction, in int32 range, not NaN/inf), N C V cleared. JavaScriptCore emits it
// (WebContent aborted on 0x1e7e000a in JSC). dynarmic doesn't decode it.
static bool fjcvtzs(GuestThread &t, u32 insn) {
    if ((insn & 0xFFFFFC00u) != 0x1E7E0000u) return false;
    auto &j = *t.jit;
    const int Rd = insn & 31, Rn = (insn >> 5) & 31;
    double v; const u64 bits = j.GetVector(Rn)[0]; memcpy(&v, &bits, 8);
    u32 r = 0; bool exact = false;
    if (std::isfinite(v)) {
        const double tz = std::trunc(v);
        // trunc(v) mod 2^32 exactly: |tz| < 2^1024; fmod is exact
        double m = std::fmod(tz, 4294967296.0);
        if (m < 0) m += 4294967296.0;
        r = (u32)(u64)m;
        exact = tz == v && tz >= -2147483648.0 && tz <= 2147483647.0 && !(v == 0 && std::signbit(v));
    }
    if (Rd != 31) j.SetRegister(Rd, r);
    j.SetPstate((j.GetPstate() & 0x0FFFFFFFu) | (exact ? 0x40000000u : 0));
    return true;
}

// FRINT32Z / FRINT32X / FRINT64Z / FRINT64X (scalar, single and double; FEAT_FRINTTS, Speed 27): round to an integral
// value (Z: toward zero, X: the FPCR mode) that fits a 32- or 64-bit integer; NaN, infinity or out of range give that
// width's most negative integer (as a float). An M1 has FEAT_FRINTTS; JavaScriptCore's JIT emits FRINT32Z
// (WebContent aborted: "unimplemented instruction 1e68401f", frint32z d31, d0, loading en.wikipedia.org).
// Encoding 0 0 0 11110 0 ftype 1 0100 op(2) 10000 Rn Rd: op 00 32Z, 01 32X, 10 64Z, 11 64X; ftype 00 single, 01 double.
static bool frintts(GuestThread &t, u32 insn) {
    if ((insn & 0xFFBE7C00u) != 0x1E284000u) return false;
    auto &j = *t.jit;
    const int Rd = insn & 31, Rn = (insn >> 5) & 31, op = (insn >> 15) & 3;
    const bool dbl = (insn >> 22) & 1, is64 = op & 2, x = op & 1;
    const int mode = x ? fpcr_mode(t) : 3;
    const double lim = is64 ? 9223372036854775808.0 : 2147483648.0;  // 2^63 / 2^31
    auto rnd = [&](double v) -> double {
        double r;
        switch (mode) { case 0: r = std::nearbyint(v); break; case 1: r = std::ceil(v); break;
                        case 2: r = std::floor(v); break; default: r = std::trunc(v); }
        if (!std::isfinite(v) || r < -lim || r >= lim) return -lim;
        return r;
    };
    V n = j.GetVector(Rn), out{0, 0};
    if (dbl) {
        double v; memcpy(&v, &n[0], 8);
        const double r = rnd(v); memcpy(&out[0], &r, 8);
    } else {
        float v; const u32 b = (u32)n[0]; memcpy(&v, &b, 4);
        const float r = (float)rnd(v); u32 rb; memcpy(&rb, &r, 4); out[0] = rb;
    }
    j.SetVector(Rd, out);
    return true;
}

// MRS Xt, CNTVCT_EL0 / CNTPCTSS_EL0 / CNTVCTSS_EL0 (Speed 26): dynarmic translates them now (as CNTPCT_EL0); blocks
// translated before (an AOT image built with the same codegen) still end in the fallback here: same value.
static bool mrs_counter(GuestThread &t, u32 insn) {
    const u32 enc = insn & 0xFFFFFFE0u;
    if (enc != 0xD53BE040u && enc != 0xD53BE0A0u && enc != 0xD53BE0C0u) return false;
    const int Rt = insn & 31;
    if (Rt != 31) t.jit->SetRegister(Rt, t.GetCNTPCT());
    return true;
}

bool fp16_interpret(GuestThread &t, u32 insn) {
    if (fjcvtzs(t, insn) || frintts(t, insn) || mrs_counter(t, insn)) return true;
    auto &j = *t.jit;
    const int Rd = insn & 31, Rn = (insn >> 5) & 31, Rm = (insn >> 16) & 31;
    const int Q = (insn >> 30) & 1, U = (insn >> 29) & 1;
    // vector three-same FP16: 0 Q U 01110 a 10 Rm 00 opcode 1 Rn Rd; scalar: 01 U 11110 a 10 Rm 00 opcode 1 Rn Rd
    const bool vec3 = (insn & 0x9F60C400) == 0x0E400400, sc3 = (insn & 0xDF60C400) == 0x5E400400;
    if (vec3 || sc3) {
        const int a = (insn >> 23) & 1, opc = (insn >> 11) & 7;
        const int lanes = sc3 ? 1 : Q ? 8 : 4;
        V n = j.GetVector(Rn), m = j.GetVector(Rm), d = j.GetVector(Rd), r{0, 0};
        if (vec3 && U == 1 && (opc == 0 || opc == 2 || opc == 6) && !(a == 1 && opc == 2)) {  // pairwise
            for (int i = 0; i < lanes; i++) {
                const V &src = i < lanes / 2 ? n : m;
                int k = (i % (lanes / 2)) * 2;
                uint16_t v;
                if (!pairwise(a, opc, lane(src, k), lane(src, k + 1), v, fpcr_mode(t))) return false;
                set_lane(r, i, v);
            }
        } else {
            for (int i = 0; i < lanes; i++) {
                uint16_t v;
                if (!op3(U, a, opc, lane(n, i), lane(m, i), lane(d, i), v, fpcr_mode(t))) return false;
                set_lane(r, i, v);
            }
        }
        j.SetVector(Rd, r);
        return true;
    }
    // vector by element, size 00 (FP16): 0 Q U 01111 00 L M Rm4 opcode H 0 Rn Rd; scalar: 01 U 11111 00 ...
    const bool vel = (insn & 0x9FC00400) == 0x0F000000, sel = (insn & 0xDFC00400) == 0x5F000000;
    if (vel || sel) {
        const int opc = (insn >> 12) & 15, H = (insn >> 11) & 1, L = (insn >> 21) & 1, M = (insn >> 20) & 1;
        const int idx = (H << 2) | (L << 1) | M, rm = (insn >> 16) & 15;
        const int lanes = sel ? 1 : Q ? 8 : 4;
        int kind;  // 0 fmla 1 fmls 2 fmul 3 fmulx
        if (opc == 0b0001 && !U) kind = 0;
        else if (opc == 0b0101 && !U) kind = 1;
        else if (opc == 0b1001) kind = U ? 3 : 2;
        else return false;
        V n = j.GetVector(Rn), d = j.GetVector(Rd), r = sel ? V{0, 0} : d;
        const uint16_t e = lane(j.GetVector(rm), idx);
        const int mode = fpcr_mode(t);
        for (int i = 0; i < lanes; i++) {
            uint16_t v;
            if (kind == 0) op3(0, 0, 1, lane(n, i), e, lane(d, i), v, mode);       // FMLA
            else if (kind == 1) op3(0, 1, 1, lane(n, i), e, lane(d, i), v, mode);  // FMLS
            else if (kind == 2) op3(1, 0, 3, lane(n, i), e, 0, v, mode);           // FMUL
            else op3(0, 0, 3, lane(n, i), e, 0, v, mode);                          // FMULX
            set_lane(r, i, v);
        }
        if (sel) r = {r[0] & 0xffff, 0};
        else if (!Q) r[1] = 0;
        j.SetVector(Rd, r);
        return true;
    }
    // two-reg misc FP16: 0 Q U 01110 a 111100 opcode 10 Rn Rd; scalar: 01 U 11110 a 111100 opcode 10 Rn Rd
    const bool v2 = (insn & 0x9F3E0C00) == 0x0E380800 && ((insn >> 22) & 1), s2 = (insn & 0xDF3E0C00) == 0x5E380800 && ((insn >> 22) & 1);
    if (v2 || s2) {
        const int a = (insn >> 23) & 1, opc = (insn >> 12) & 31;
        const int lanes = s2 ? 1 : Q ? 8 : 4;
        V n = j.GetVector(Rn), r{0, 0};
        for (int i = 0; i < lanes; i++) {
            uint16_t v;
            if (!op2(t, U, a, opc, lane(n, i), v)) return false;
            set_lane(r, i, v);
        }
        j.SetVector(Rd, r);
        return true;
    }
    // scalar pairwise FP16: 01 0 11110 o1 0 11000 opcode 10 Rn Rd (FMAXNMP 01100, FADDP 01101, FMAXP 01111; o1=1:
    // FMINNMP 01100, FMINP 01111)
    if ((insn & 0xFF3E0C00) == 0x5E300800 && !((insn >> 22) & 1)) {
        const int o1 = (insn >> 23) & 1, opc = (insn >> 12) & 31;
        V n = j.GetVector(Rn);
        uint16_t x = lane(n, 0), y = lane(n, 1), v;
        int p = opc == 0b01100 ? 0 : opc == 0b01101 ? 2 : opc == 0b01111 ? 6 : -1;
        if (p < 0 || (o1 && p == 2) || !pairwise(o1, p, x, y, v, fpcr_mode(t))) return false;
        j.SetVector(Rd, {v, 0});
        return true;
    }
    // across lanes FP16: 0 Q 0 01110 o1 0 11000 opcode 10 Rn Rd (FMAXNMV 01100, FMAXV 01111; o1=1 FMINNMV, FMINV)
    if ((insn & 0xBF3E0C00) == 0x0E300800 && !((insn >> 22) & 1) && !U) {
        const int o1 = (insn >> 23) & 1, opc = (insn >> 12) & 31;
        int p = opc == 0b01100 ? 0 : opc == 0b01111 ? 6 : -1;
        if (p < 0) return false;
        V n = j.GetVector(Rn);
        const int lanes = Q ? 8 : 4;
        // Reduce() in the Arm pseudocode pairs lanes as a tree (op(Reduce(lower half), Reduce(upper half))), not left to
        // right. The order shows with a NaN: FMAXNMV / FMINNMV turn a signalling NaN into a quiet NaN that the next
        // FPMaxNum / FPMinNum drops, so the other lane of that pair is lost (Apple M-series hardware does the same).
        uint16_t v[8];
        for (int i = 0; i < lanes; i++) v[i] = lane(n, i);
        for (int w = lanes; w > 1; w /= 2)
            for (int i = 0; i < w / 2; i++) pairwise(o1, p, v[2 * i], v[2 * i + 1], v[i]);
        j.SetVector(Rd, {v[0], 0});
        return true;
    }
    // Scalar integer -> FP16 (SCVTF/UCVTF Hd, Wn/Xn). dynarmic raises UnallocatedEncoding for
    // type=half (`fltsize == 16` early-out in SCVTF_float_int / UCVTF_float_int). Encoding:
    // sf 0 0 0 1 1 1 1 0 | ftype=11 | 1 | rmode=00 | opcode=010/011 | 000000 | Rn | Rd
    // → 0x1EE20000 (SCVTF) / 0x1EE30000 (UCVTF); sf=1 → 0x9EE2/9EE3. Seen as 1ee20184
    // (scvtf h4,w12) from Metal/RenderBox on iOS 27. Mask clears sf and opcode LSB (U).
    if ((insn & 0x7FFEFC00) == 0x1EE20000) {
        const int rmode_opcode = (insn >> 16) & 0x3f;  // bit21|rmode|opcode → 100010 / 100011
        if (rmode_opcode == 0b100010 || rmode_opcode == 0b100011) {
            const int sf = (insn >> 31) & 1;
            const bool is_unsigned = rmode_opcode & 1;
            const u64 ival = j.GetRegister(Rn);
            float f;
            if (is_unsigned) f = sf ? (float)ival : (float)(uint32_t)ival;
            else f = sf ? (float)(int64_t)ival : (float)(int32_t)ival;
            uint16_t h = f2h(f);
            V v = j.GetVector(Rd);
            v[0] = (v[0] & ~0xffffull) | h;
            j.SetVector(Rd, v);
            return true;
        }
    }
    return false;
}

}  // namespace a64
