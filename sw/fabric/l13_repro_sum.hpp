// =============================================================================
// l13_repro_sum.hpp -- Layer 13: bit-exact reproducible summation
//
// A Kulisch (super-)accumulator. Every FP32 addend is placed, without
// rounding, into a fixed-point accumulator wide enough to hold the entire
// FP32 exponent range. Addition is then plain integer addition, which is
// associative and commutative, so the sum is identical for any arrival order
// -- the property Layer 13 requires and which IEEE-754 addition does not have.
//
// Rounding happens exactly once, when the accumulator is converted back to a
// float. The result is therefore also the correctly-rounded exact sum, which
// is strictly more accurate than any ordering of naive FP32 addition.
//
// -----------------------------------------------------------------------------
// Width, and why 128 bits is not enough
// -----------------------------------------------------------------------------
// FP32 spans 2^-149 (smallest subnormal) to just under 2^128. Representing
// that range exactly needs 277 bits. A two-limb 128-bit accumulator is 149
// bits short, so it cannot be exact; values at the ends of the range are
// either truncated or dropped entirely, and the "reproducible" sum then
// depends on which addends happened to fall off.
//
// This implementation uses 512 bits (8 x 64-bit limbs), two's complement:
//
//   bit 0    represents 2^-149
//   bit 276  represents 2^127
//   bits 277..511 are carry headroom
//
// 235 bits of headroom means the accumulator cannot overflow for any
// realistic number of addends -- you would need more than 2^235 of them.
//
// Thread safety: an Accumulator is a plain value. Share by copying, or by
// merging with add(), which is what a ring reduction does.
// =============================================================================

#pragma once

#include <array>
#include <bit>
#include <cstdint>
#include <cstring>
#include <span>

namespace lightrail::fabric {

class ReproSum {
public:
    static constexpr int      kLimbs     = 8;             // 512 bits
    static constexpr int      kBits      = kLimbs * 64;
    // Bit index that represents 2^0. Chosen so 2^-149 lands on bit 0.
    static constexpr int      kZeroBit   = 149;
    static constexpr uint32_t kFp32Bias  = 127;

    struct Accumulator {
        std::array<uint64_t, kLimbs> limb{};   // little-endian, two's complement

        void reset() noexcept { limb.fill(0); }

        [[nodiscard]] bool is_negative() const noexcept {
            return (limb[kLimbs - 1] >> 63) != 0U;
        }

        [[nodiscard]] bool is_zero() const noexcept {
            for (uint64_t w : limb)
                if (w != 0U) return false;
            return true;
        }

        friend bool operator==(const Accumulator& a, const Accumulator& b) noexcept {
            return a.limb == b.limb;
        }
    };

    // ---- primitive integer ops ---------------------------------------------

    // dest += src, full width, wrapping (headroom makes wrap unreachable).
    //
    // Carry is propagated with 64-bit arithmetic only. __int128 would be
    // shorter but is a compiler extension, and this header is built with
    // -Wpedantic.
    static void add(Accumulator& dest, const Accumulator& src) noexcept {
        uint64_t carry = 0;
        for (int i = 0; i < kLimbs; ++i) {
            const uint64_t a = dest.limb[i];
            const uint64_t b = src.limb[i];
            const uint64_t s1 = a + b;
            const uint64_t c1 = (s1 < a) ? 1U : 0U;   // overflow of a + b
            const uint64_t s2 = s1 + carry;
            const uint64_t c2 = (s2 < s1) ? 1U : 0U;  // overflow of + carry
            dest.limb[i] = s2;
            carry = c1 + c2;                          // at most 1
        }
    }

    static void negate(Accumulator& a) noexcept {
        uint64_t carry = 1;
        for (int i = 0; i < kLimbs; ++i) {
            const uint64_t t = ~a.limb[i];
            const uint64_t s = t + carry;
            carry = (s < t) ? 1U : 0U;
            a.limb[i] = s;
        }
    }

    // ---- float in -----------------------------------------------------------

    // Adds one FP32 value exactly. Inf and NaN are rejected (returns false)
    // rather than silently poisoning the accumulator.
    static bool add_float(Accumulator& acc, float value) noexcept {
        const uint32_t bits = std::bit_cast<uint32_t>(value);
        const uint32_t exp  = (bits >> 23) & 0xFFU;
        const uint32_t frac = bits & 0x7FFFFFU;
        const bool     neg  = (bits >> 31) != 0U;

        if (exp == 0xFFU) return false;              // Inf or NaN
        if (exp == 0U && frac == 0U) return true;    // +/-0 contributes nothing

        uint64_t mant;
        int      e2;
        if (exp == 0U) {
            // Subnormal: no hidden bit, fixed exponent of -126.
            mant = frac;
            e2   = -126 - 23;
        } else {
            mant = frac | 0x800000U;                 // restore hidden bit
            e2   = static_cast<int>(exp) - static_cast<int>(kFp32Bias) - 23;
        }

        // Bit position of the mantissa's LSB. By construction this is >= 0 for
        // every finite FP32, because kZeroBit was chosen to make it so.
        const int pos = e2 + kZeroBit;

        Accumulator term{};
        place(term, mant, pos);
        if (neg) negate(term);
        add(acc, term);
        return true;
    }

    // Adds a whole span. Returns false if any element was Inf or NaN; the
    // remaining elements are still accumulated so the caller sees a usable
    // partial sum alongside the flag.
    static bool add_span(Accumulator& acc, std::span<const float> xs) noexcept {
        bool ok = true;
        for (float x : xs) ok = add_float(acc, x) && ok;
        return ok;
    }

    // ---- float out ----------------------------------------------------------

    // Converts back to FP32 with round-to-nearest-even. This is the only
    // rounding in the whole pipeline.
    static float to_float(const Accumulator& acc) noexcept;

    // Exact conversion to double when the magnitude permits; used by tests.
    static double to_double(const Accumulator& acc) noexcept;

private:
    // term = mant << pos, where term is zero on entry.
    static void place(Accumulator& term, uint64_t mant, int pos) noexcept {
        if (pos < 0 || pos >= kBits) return;         // outside: contributes 0
        const int limb  = pos / 64;
        const int shift = pos % 64;

        term.limb[limb] = mant << shift;
        // A 24-bit mantissa shifted by up to 63 needs the next limb too.
        if (shift != 0 && limb + 1 < kLimbs)
            term.limb[limb + 1] = mant >> (64 - shift);
    }
};

}  // namespace lightrail::fabric
