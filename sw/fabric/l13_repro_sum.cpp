// =============================================================================
// l13_repro_sum.cpp -- accumulator-to-float conversion
// =============================================================================

#include "l13_repro_sum.hpp"

#include <cmath>

namespace lightrail::fabric {

namespace {

// Index of the highest set bit, or -1 when the value is zero.
int top_bit(const ReproSum::Accumulator& a) noexcept {
    for (int i = ReproSum::kLimbs - 1; i >= 0; --i) {
        if (a.limb[i] != 0U)
            return i * 64 + (63 - std::countl_zero(a.limb[i]));
    }
    return -1;
}

bool bit_at(const ReproSum::Accumulator& a, int pos) noexcept {
    if (pos < 0 || pos >= ReproSum::kBits) return false;
    return ((a.limb[pos / 64] >> (pos % 64)) & 1U) != 0U;
}

// True when any bit strictly below pos is set -- the sticky bit used for
// round-to-nearest-even.
bool any_below(const ReproSum::Accumulator& a, int pos) noexcept {
    if (pos <= 0) return false;
    const int full = pos / 64;
    for (int i = 0; i < full; ++i)
        if (a.limb[i] != 0U) return true;
    const int rem = pos % 64;
    if (rem != 0) {
        const uint64_t mask = (uint64_t{1} << rem) - 1U;
        if ((a.limb[full] & mask) != 0U) return true;
    }
    return false;
}

}  // namespace

float ReproSum::to_float(const Accumulator& acc) noexcept {
    if (acc.is_zero()) return 0.0f;

    Accumulator mag = acc;
    const bool  neg = acc.is_negative();
    if (neg) negate(mag);

    const int msb = top_bit(mag);
    if (msb < 0) return 0.0f;

    // Unbiased exponent of the leading one.
    const int e = msb - kZeroBit;

    if (e > 127) return neg ? -INFINITY : INFINITY;

    // Normal range: take 24 significant bits starting at the MSB.
    if (e >= -126) {
        const int lsb = msb - 23;              // position of the mantissa LSB
        uint64_t  m   = 0;
        for (int i = 0; i < 24; ++i)
            if (bit_at(mag, lsb + i)) m |= (uint64_t{1} << i);

        // Round to nearest, ties to even.
        const bool guard  = bit_at(mag, lsb - 1);
        const bool sticky = any_below(mag, lsb - 1);
        if (guard && (sticky || (m & 1U))) {
            ++m;
            if (m == (uint64_t{1} << 24)) {    // carried out of the mantissa
                m >>= 1;
                if (e + 1 > 127) return neg ? -INFINITY : INFINITY;
                const uint32_t bits =
                    (static_cast<uint32_t>(neg) << 31) |
                    (static_cast<uint32_t>(e + 1 + 127) << 23) |
                    (static_cast<uint32_t>(m) & 0x7FFFFFU);
                return std::bit_cast<float>(bits);
            }
        }

        const uint32_t bits =
            (static_cast<uint32_t>(neg) << 31) |
            (static_cast<uint32_t>(e + 127) << 23) |
            (static_cast<uint32_t>(m) & 0x7FFFFFU);
        return std::bit_cast<float>(bits);
    }

    // Subnormal range: the mantissa LSB is pinned at 2^-149, i.e. bit 0.
    uint64_t   m = 0;
    for (int i = 0; i < 23; ++i)
        if (bit_at(mag, i)) m |= (uint64_t{1} << i);

    const uint32_t bits = (static_cast<uint32_t>(neg) << 31) |
                          (static_cast<uint32_t>(m) & 0x7FFFFFU);
    return std::bit_cast<float>(bits);
}

double ReproSum::to_double(const Accumulator& acc) noexcept {
    if (acc.is_zero()) return 0.0;

    Accumulator mag = acc;
    const bool  neg = acc.is_negative();
    if (neg) negate(mag);

    double out = 0.0;
    for (int i = kLimbs - 1; i >= 0; --i) {
        out = std::ldexp(out, 64);
        out += static_cast<double>(mag.limb[i]);
    }
    out = std::ldexp(out, -kZeroBit);
    return neg ? -out : out;
}

}  // namespace lightrail::fabric
