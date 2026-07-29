#!/usr/bin/env python3

import random
from pathlib import Path


def decode(value: int) -> tuple[int, int, int, int, int]:
    sign = (value >> 31) & 0x1
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF

    exponent_is_zero = exponent == 0
    exponent_is_ones = exponent == 0xFF
    fraction_is_zero = fraction == 0

    is_zero = exponent_is_zero and fraction_is_zero
    is_subnormal = exponent_is_zero and not fraction_is_zero
    is_normal = not exponent_is_zero and not exponent_is_ones
    is_infinity = exponent_is_ones and fraction_is_zero
    is_nan = exponent_is_ones and not fraction_is_zero
    is_quiet_nan = is_nan and bool((fraction >> 22) & 1)
    is_signaling_nan = is_nan and not bool((fraction >> 22) & 1)

    if is_normal:
        significand = (1 << 23) | fraction
    elif is_subnormal:
        significand = fraction
    else:
        significand = 0

    flags = (
        (int(is_zero) << 0)
        | (int(is_subnormal) << 1)
        | (int(is_normal) << 2)
        | (int(is_infinity) << 3)
        | (int(is_nan) << 4)
        | (int(is_quiet_nan) << 5)
        | (int(is_signaling_nan) << 6)
    )

    return sign, exponent, fraction, significand, flags


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    output_path = project_root / "build" / "fp32_decode_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed_values = [
        0x00000000,  # +0
        0x80000000,  # -0
        0x00000001,  # smallest positive subnormal
        0x007FFFFF,  # largest positive subnormal
        0x80000001,  # smallest negative subnormal
        0x00800000,  # smallest positive normal
        0x80800000,  # smallest negative normal
        0x3F800000,  # +1.0
        0xBF800000,  # -1.0
        0x7F7FFFFF,  # largest finite positive
        0xFF7FFFFF,  # largest finite negative
        0x7F800000,  # +infinity
        0xFF800000,  # -infinity
        0x7FC00000,  # canonical quiet NaN
        0xFFC00000,  # negative quiet NaN
        0x7F800001,  # signaling NaN
        0xFF800001,  # negative signaling NaN
        0x7FFFFFFF,  # quiet NaN with all payload bits
        0xFFFFFFFF,  # negative quiet NaN with payload
    ]

    rng = random.Random(0x4E434546)

    random_values = [
        rng.getrandbits(32)
        for _ in range(200_000)
    ]

    values = directed_values + random_values

    with output_path.open("w", encoding="ascii") as vector_file:
        for value in values:
            sign, exponent, fraction, significand, flags = decode(value)

            vector_file.write(
                f"{value:08x} "
                f"{sign:01x} "
                f"{exponent:02x} "
                f"{fraction:06x} "
                f"{significand:06x} "
                f"{flags:02x}\n"
            )

    print(f"Generated {len(values)} vectors: {output_path}")


if __name__ == "__main__":
    main()
