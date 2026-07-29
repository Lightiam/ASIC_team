#!/usr/bin/env python3

import random
from fractions import Fraction
from pathlib import Path


def fp32_to_fraction(value: int) -> Fraction:
    sign = (value >> 31) & 1
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF

    if exponent == 0:
        significand = fraction
        binary_shift = -149
    else:
        significand = (1 << 23) | fraction
        binary_shift = exponent - 150

    if binary_shift >= 0:
        result = Fraction(significand << binary_shift, 1)
    else:
        result = Fraction(
            significand,
            1 << (-binary_shift),
        )

    return -result if sign else result


def round_ratio_to_even(numerator: int, denominator: int) -> int:
    quotient, remainder = divmod(numerator, denominator)
    twice_remainder = remainder << 1

    if (
        twice_remainder > denominator
        or (
            twice_remainder == denominator
            and (quotient & 1)
        )
    ):
        quotient += 1

    return quotient


def floor_log2_fraction(
    numerator: int,
    denominator: int,
) -> int:
    exponent = (
        numerator.bit_length()
        - denominator.bit_length()
    )

    if exponent >= 0:
        if numerator < (denominator << exponent):
            exponent -= 1
    else:
        if (numerator << (-exponent)) < denominator:
            exponent -= 1

    return exponent


def fraction_to_fp32(value: Fraction) -> int:
    if value == 0:
        return 0x00000000

    sign = 1 if value < 0 else 0
    magnitude = abs(value)

    numerator = magnitude.numerator
    denominator = magnitude.denominator

    binary_exponent = floor_log2_fraction(
        numerator,
        denominator,
    )

    if binary_exponent >= -126:
        scale = 23 - binary_exponent

        if scale >= 0:
            rounded_significand = round_ratio_to_even(
                numerator << scale,
                denominator,
            )
        else:
            rounded_significand = round_ratio_to_even(
                numerator,
                denominator << (-scale),
            )

        if rounded_significand >= (1 << 24):
            rounded_significand >>= 1
            binary_exponent += 1

        if binary_exponent > 127:
            return (
                (sign << 31)
                | 0x7F800000
            )

        encoded_exponent = binary_exponent + 127
        encoded_fraction = (
            rounded_significand
            - (1 << 23)
        )

        return (
            (sign << 31)
            | (encoded_exponent << 23)
            | encoded_fraction
        )

    # Subnormal rounding uses a fixed quantum of 2^-149.
    rounded_fraction = round_ratio_to_even(
        numerator << 149,
        denominator,
    )

    if rounded_fraction == 0:
        return sign << 31

    if rounded_fraction >= (1 << 23):
        # Rounded up to the smallest normal value.
        return (
            (sign << 31)
            | 0x00800000
        )

    return (
        (sign << 31)
        | rounded_fraction
    )


def is_infinity(value: int) -> bool:
    return (
        ((value >> 23) & 0xFF) == 0xFF
        and (value & 0x7FFFFF) == 0
    )


def random_finite_nonzero(
    rng: random.Random,
) -> int:
    sign = rng.getrandbits(1)
    exponent = rng.randrange(0, 255)
    fraction = rng.getrandbits(23)

    if exponent == 0 and fraction == 0:
        fraction = 1

    return (
        (sign << 31)
        | (exponent << 23)
        | fraction
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output_path = (
        root
        / "build"
        / "fp32_round_pack_vectors.txt"
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    directed_vectors = [
        # Exact arithmetic
        (0x3F800000, 0x3F800000),
        (0x3F800000, 0xBF800000),
        (0x40000000, 0xBF800000),

        # Round-to-nearest-even ties
        (0x3F800000, 0x33800000),
        (0x3F800001, 0x33800000),
        (0xBF800000, 0xB3800000),
        (0xBF800001, 0xB3800000),

        # Small operands and sticky-bit behavior
        (0x3F800000, 0x00000001),
        (0x3F800000, 0x80000001),
        (0xBF800000, 0x00000001),
        (0xBF800000, 0x80000001),

        # Subnormal and normal boundary
        (0x00000001, 0x00000001),
        (0x007FFFFF, 0x00000001),
        (0x00800000, 0x80000001),
        (0x00800001, 0x80800000),
        (0x00000002, 0x80000001),

        # Cancellation
        (0x3F800001, 0xBF800000),
        (0x00800000, 0x80800000),
        (0x00000001, 0x80000001),

        # Largest finite and overflow boundary
        (0x7F7FFFFF, 0x72800000),
        (0x7F7FFFFF, 0x73000000),
        (0x7F7FFFFF, 0x7F7FFFFF),
        (0xFF7FFFFF, 0xF3000000),
        (0xFF7FFFFF, 0xFF7FFFFF),
    ]

    rng = random.Random(0x4E4345524F554E44)

    random_vectors = [
        (
            random_finite_nonzero(rng),
            random_finite_nonzero(rng),
        )
        for _ in range(200_000)
    ]

    vectors = directed_vectors + random_vectors

    with output_path.open(
        "w",
        encoding="ascii",
    ) as vector_file:
        for a, b in vectors:
            exact_result = (
                fp32_to_fraction(a)
                + fp32_to_fraction(b)
            )

            rounded_result = fraction_to_fp32(
                exact_result
            )

            overflow = int(
                is_infinity(rounded_result)
            )

            if overflow:
                inexact = 1
            else:
                rounded_fraction = fp32_to_fraction(
                    rounded_result
                )

                inexact = int(
                    rounded_fraction != exact_result
                )

            result_exponent = (
                rounded_result >> 23
            ) & 0xFF

            # Tininess after rounding.
            underflow = int(
                inexact
                and result_exponent == 0
            )

            vector_file.write(
                f"{a:08x} "
                f"{b:08x} "
                f"{rounded_result:08x} "
                f"{inexact:01x} "
                f"{overflow:01x} "
                f"{underflow:01x}\n"
            )

    print(
        f"Generated {len(vectors)} vectors: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
