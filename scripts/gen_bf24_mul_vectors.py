#!/usr/bin/env python3

"""Generate BF24 × BF24 -> FP32 multiplication verification vectors."""

from __future__ import annotations

import argparse
import random
from pathlib import Path


BF24_SIGN_MASK = 0x800000
BF24_EXP_MASK = 0x7F8000
BF24_FRAC_MASK = 0x007FFF
BF24_QUIET_BIT = 0x004000

FP32_CANONICAL_QNAN = 0x7FC00000
FP32_INFINITY = 0x7F800000


def decode_bf24(value: int) -> tuple[int, int, int]:
    """Return sign, exponent, and fraction fields."""

    value &= 0xFFFFFF

    sign = (value >> 23) & 1
    exponent = (value >> 15) & 0xFF
    fraction = value & BF24_FRAC_MASK

    return sign, exponent, fraction


def finite_components(exponent: int, fraction: int) -> tuple[int, int]:
    """Represent a finite nonzero BF24 number as significand * 2**exponent2."""

    if exponent == 0:
        return fraction, -141

    return (1 << 15) | fraction, exponent - 142


def round_right_nearest_even(value: int, shift: int) -> tuple[int, bool]:
    """Round value / 2**shift using round-to-nearest, ties-to-even."""

    if shift <= 0:
        return value << (-shift), False

    quotient = value >> shift
    remainder = value & ((1 << shift) - 1)
    half = 1 << (shift - 1)

    round_up = (
        remainder > half
        or (remainder == half and (quotient & 1) != 0)
    )

    return quotient + int(round_up), remainder != 0


def bf24_mul_reference(a: int, b: int) -> tuple[int, int]:
    """Return FP32 result and packed exception flags."""

    sign_a, exponent_a, fraction_a = decode_bf24(a)
    sign_b, exponent_b, fraction_b = decode_bf24(b)

    sign_product = sign_a ^ sign_b

    a_zero = exponent_a == 0 and fraction_a == 0
    b_zero = exponent_b == 0 and fraction_b == 0

    a_infinity = exponent_a == 0xFF and fraction_a == 0
    b_infinity = exponent_b == 0xFF and fraction_b == 0

    a_nan = exponent_a == 0xFF and fraction_a != 0
    b_nan = exponent_b == 0xFF and fraction_b != 0

    a_signalling_nan = a_nan and (fraction_a & BF24_QUIET_BIT) == 0
    b_signalling_nan = b_nan and (fraction_b & BF24_QUIET_BIT) == 0

    invalid = False
    overflow = False
    underflow = False
    inexact = False

    if a_nan or b_nan:
        invalid = a_signalling_nan or b_signalling_nan
        result = FP32_CANONICAL_QNAN

    elif (a_infinity and b_zero) or (b_infinity and a_zero):
        invalid = True
        result = FP32_CANONICAL_QNAN

    elif a_infinity or b_infinity:
        result = (sign_product << 31) | FP32_INFINITY

    elif a_zero or b_zero:
        result = sign_product << 31

    else:
        significand_a, exponent2_a = finite_components(
            exponent_a,
            fraction_a,
        )

        significand_b, exponent2_b = finite_components(
            exponent_b,
            fraction_b,
        )

        significand_product = significand_a * significand_b
        product_exponent2 = exponent2_a + exponent2_b

        msb_position = significand_product.bit_length() - 1
        unbiased_exponent = product_exponent2 + msb_position

        if unbiased_exponent > 127:
            result = (sign_product << 31) | FP32_INFINITY
            overflow = True
            inexact = True

        elif unbiased_exponent >= -126:
            shift = msb_position - 23

            rounded_significand, inexact = round_right_nearest_even(
                significand_product,
                shift,
            )

            if rounded_significand >= (1 << 24):
                rounded_significand >>= 1
                unbiased_exponent += 1

            if unbiased_exponent > 127:
                result = (sign_product << 31) | FP32_INFINITY
                overflow = True
                inexact = True
            else:
                encoded_exponent = unbiased_exponent + 127
                fraction = rounded_significand & 0x7FFFFF

                result = (
                    (sign_product << 31)
                    | (encoded_exponent << 23)
                    | fraction
                )

        else:
            shift_amount = product_exponent2 + 149

            rounded_fraction, inexact = round_right_nearest_even(
                significand_product,
                -shift_amount,
            )

            if rounded_fraction >= (1 << 23):
                # Rounded to minimum normal FP32.
                result = (sign_product << 31) | 0x00800000
                underflow = False
            else:
                result = (
                    (sign_product << 31)
                    | (rounded_fraction & 0x7FFFFF)
                )

                # Tininess detection after rounding.
                underflow = inexact

    flags = (
        (int(invalid) << 3)
        | (int(overflow) << 2)
        | (int(underflow) << 1)
        | int(inexact)
    )

    return result & 0xFFFFFFFF, flags


def directed_values() -> list[int]:
    """Important BF24 normal, subnormal, infinity, and NaN encodings."""

    positive = [
        0x000000,  # +0
        0x000001,  # minimum subnormal
        0x000002,
        0x003FFF,
        0x004000,
        0x007FFE,
        0x007FFF,  # maximum subnormal
        0x008000,  # minimum normal
        0x008001,
        0x010000,
        0x3E8000,  # 0.25
        0x3F0000,  # 0.5
        0x3F7FFF,  # immediately below 1.0
        0x3F8000,  # 1.0
        0x3F8001,  # immediately above 1.0
        0x3FC000,  # 1.5
        0x400000,  # 2.0
        0x404000,  # 3.0
        0x408000,  # 4.0
        0x7EFFFF,
        0x7F0000,
        0x7F7FFE,
        0x7F7FFF,  # maximum finite
        0x7F8000,  # +infinity
        0x7F8001,  # signalling NaN
        0x7FBFFF,  # signalling NaN
        0x7FC000,  # quiet NaN
        0x7FFFFF,  # quiet NaN
    ]

    negative = [
        value | BF24_SIGN_MASK
        for value in positive
    ]

    return positive + negative


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    """Write directed and random verification vectors."""

    values = directed_values()
    pairs: list[tuple[int, int]] = []

    for a in values:
        for b in values:
            pairs.append((a, b))

    rng = random.Random(seed)

    for _ in range(random_count):
        pairs.append(
            (
                rng.getrandbits(24),
                rng.getrandbits(24),
            )
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="ascii") as output_file:
        for a, b in pairs:
            product, flags = bf24_mul_reference(a, b)

            output_file.write(
                f"{a:06x} {b:06x} {product:08x} {flags:x}\n"
            )

    return len(pairs)


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path("build/bf24_mul_vectors.txt"),
    )

    parser.add_argument(
        "--random-count",
        type=int,
        default=250_000,
    )

    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0xBF240001,
    )

    args = parser.parse_args()

    vector_count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {vector_count} BF24 multiplication vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
