#!/usr/bin/env python3

from __future__ import annotations

import argparse
import random
from pathlib import Path


CANONICAL_QNAN = 0x7FC00000
POSITIVE_INFINITY = 0x7F800000


def decode_bf16(value: int) -> dict[str, int | bool]:
    sign = (value >> 15) & 1
    exponent = (value >> 7) & 0xFF
    fraction = value & 0x7F

    is_zero = exponent == 0 and fraction == 0
    is_infinity = exponent == 0xFF and fraction == 0
    is_nan = exponent == 0xFF and fraction != 0
    is_signalling_nan = is_nan and ((fraction >> 6) & 1) == 0

    if exponent == 0:
        significand = fraction
        exponent2 = -133
    else:
        significand = 0x80 | fraction
        exponent2 = exponent - 134

    return {
        "sign": sign,
        "exponent": exponent,
        "fraction": fraction,
        "is_zero": is_zero,
        "is_infinity": is_infinity,
        "is_nan": is_nan,
        "is_signalling_nan": is_signalling_nan,
        "significand": significand,
        "exponent2": exponent2,
    }


def round_right_even(value: int, shift: int) -> tuple[int, bool]:
    if shift <= 0:
        return value << (-shift), False

    quotient = value >> shift
    remainder = value & ((1 << shift) - 1)

    if remainder == 0:
        return quotient, False

    half = 1 << (shift - 1)

    round_up = (
        remainder > half
        or (
            remainder == half
            and (quotient & 1) != 0
        )
    )

    if round_up:
        quotient += 1

    return quotient, True


def bf16_mul_reference(
    a_bits: int,
    b_bits: int,
) -> tuple[int, int, int, int, int]:
    a = decode_bf16(a_bits)
    b = decode_bf16(b_bits)

    sign = int(a["sign"]) ^ int(b["sign"])

    invalid = 0
    overflow = 0
    underflow = 0
    inexact = 0

    if bool(a["is_nan"]) or bool(b["is_nan"]):
        invalid = int(
            bool(a["is_signalling_nan"])
            or bool(b["is_signalling_nan"])
        )

        return (
            CANONICAL_QNAN,
            invalid,
            overflow,
            underflow,
            inexact,
        )

    if (
        bool(a["is_infinity"]) and bool(b["is_zero"])
    ) or (
        bool(b["is_infinity"]) and bool(a["is_zero"])
    ):
        return (
            CANONICAL_QNAN,
            1,
            0,
            0,
            0,
        )

    if bool(a["is_infinity"]) or bool(b["is_infinity"]):
        result = (
            (sign << 31)
            | POSITIVE_INFINITY
        )

        return result, 0, 0, 0, 0

    if bool(a["is_zero"]) or bool(b["is_zero"]):
        return sign << 31, 0, 0, 0, 0

    significand_product = (
        int(a["significand"])
        * int(b["significand"])
    )

    exponent2 = (
        int(a["exponent2"])
        + int(b["exponent2"])
    )

    msb_position = significand_product.bit_length() - 1
    unbiased_exponent = exponent2 + msb_position

    if unbiased_exponent > 127:
        result = (
            (sign << 31)
            | POSITIVE_INFINITY
        )

        return result, 0, 1, 0, 1

    if unbiased_exponent >= -126:
        significand_fp32 = (
            significand_product
            << (23 - msb_position)
        )

        exponent_field = unbiased_exponent + 127
        fraction_field = significand_fp32 & 0x7FFFFF

        result = (
            (sign << 31)
            | (exponent_field << 23)
            | fraction_field
        )

        return result, 0, 0, 0, 0

    shift_amount = exponent2 + 149

    if shift_amount >= 0:
        fraction_field = (
            significand_product
            << shift_amount
        )

        inexact = 0
    else:
        fraction_field, was_inexact = round_right_even(
            significand_product,
            -shift_amount,
        )

        inexact = int(was_inexact)

    if fraction_field >= (1 << 23):
        result = (
            (sign << 31)
            | (1 << 23)
        )

        underflow = 0
    else:
        result = (
            (sign << 31)
            | fraction_field
        )

        underflow = inexact

    return (
        result,
        invalid,
        overflow,
        underflow,
        inexact,
    )


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    edge_values = [
        0x0000,  # +0
        0x8000,  # -0
        0x0001,  # smallest positive subnormal
        0x007F,  # largest positive subnormal
        0x0080,  # smallest positive normal
        0x3F00,  # 0.5
        0x3F80,  # 1.0
        0xBF80,  # -1.0
        0x4000,  # 2.0
        0x4040,  # 3.0
        0x7F7F,  # largest finite
        0xFF7F,  # largest negative finite
        0x7F80,  # +infinity
        0xFF80,  # -infinity
        0x7FC1,  # quiet NaN
        0x7F81,  # signalling NaN
    ]

    rng = random.Random(seed)
    vectors: list[tuple[int, int]] = []

    for a_bits in edge_values:
        for b_bits in edge_values:
            vectors.append((a_bits, b_bits))

    for _ in range(random_count):
        vectors.append(
            (
                rng.randrange(0x10000),
                rng.randrange(0x10000),
            )
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as handle:
        for a_bits, b_bits in vectors:
            (
                expected_product,
                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact,
            ) = bf16_mul_reference(a_bits, b_bits)

            handle.write(
                f"{a_bits:04x} "
                f"{b_bits:04x} "
                f"{expected_product:08x} "
                f"{expected_invalid:d} "
                f"{expected_overflow:d} "
                f"{expected_underflow:d} "
                f"{expected_inexact:d}\n"
            )

    return len(vectors)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("build/bf16_mul_vectors.txt"),
    )
    parser.add_argument(
        "--random-count",
        type=int,
        default=250_000,
    )
    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0xBF16_2026,
    )

    args = parser.parse_args()

    count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {count} BF16 multiplication vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
