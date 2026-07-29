#!/usr/bin/env python3

import random
from fractions import Fraction
from pathlib import Path


CANONICAL_QNAN = 0x7FC00000


def classify(value: int) -> dict[str, bool]:
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF

    exponent_zero = exponent == 0
    exponent_ones = exponent == 0xFF
    fraction_zero = fraction == 0

    is_nan = exponent_ones and not fraction_zero

    return {
        "zero": exponent_zero and fraction_zero,
        "infinity": exponent_ones and fraction_zero,
        "nan": is_nan,
        "signaling_nan": (
            is_nan
            and ((fraction >> 22) & 1) == 0
        ),
    }


def quiet_nan(value: int) -> int:
    return value | 0x00400000


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
        result = Fraction(
            significand << binary_shift,
            1,
        )
    else:
        result = Fraction(
            significand,
            1 << (-binary_shift),
        )

    return -result if sign else result


def round_ratio_to_even(
    numerator: int,
    denominator: int,
) -> int:
    quotient, remainder = divmod(
        numerator,
        denominator,
    )

    doubled_remainder = remainder << 1

    if (
        doubled_remainder > denominator
        or (
            doubled_remainder == denominator
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

    rounded_fraction = round_ratio_to_even(
        numerator << 149,
        denominator,
    )

    if rounded_fraction == 0:
        return sign << 31

    if rounded_fraction >= (1 << 23):
        return (
            (sign << 31)
            | 0x00800000
        )

    return (
        (sign << 31)
        | rounded_fraction
    )


def resolve(a: int, b: int) -> tuple[int, int, int, int, int]:
    class_a = classify(a)
    class_b = classify(b)

    if class_a["signaling_nan"]:
        return quiet_nan(a), 1, 0, 0, 0

    if class_b["signaling_nan"]:
        return quiet_nan(b), 1, 0, 0, 0

    if class_a["nan"]:
        return quiet_nan(a), 0, 0, 0, 0

    if class_b["nan"]:
        return quiet_nan(b), 0, 0, 0, 0

    if (
        class_a["infinity"]
        and class_b["infinity"]
        and ((a >> 31) != (b >> 31))
    ):
        return CANONICAL_QNAN, 1, 0, 0, 0

    if class_a["infinity"]:
        return a, 0, 0, 0, 0

    if class_b["infinity"]:
        return b, 0, 0, 0, 0

    if class_a["zero"] and class_b["zero"]:
        result_sign = (
            ((a >> 31) & 1)
            & ((b >> 31) & 1)
        )

        return result_sign << 31, 0, 0, 0, 0

    if class_a["zero"]:
        return b, 0, 0, 0, 0

    if class_b["zero"]:
        return a, 0, 0, 0, 0

    exact_result = (
        fp32_to_fraction(a)
        + fp32_to_fraction(b)
    )

    rounded_result = fraction_to_fp32(
        exact_result
    )

    result_exponent = (
        rounded_result >> 23
    ) & 0xFF

    result_fraction = (
        rounded_result
        & 0x7FFFFF
    )

    overflow = int(
        result_exponent == 0xFF
        and result_fraction == 0
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

    underflow = int(
        inexact
        and result_exponent == 0
    )

    return (
        rounded_result,
        0,
        overflow,
        underflow,
        inexact,
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output_path = root / "build" / "fp32_add_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed_vectors = [
        (0x00000000, 0x00000000),
        (0x80000000, 0x80000000),
        (0x00000000, 0x80000000),
        (0x80000000, 0x00000000),

        (0x3F800000, 0x3F800000),
        (0x3F800000, 0xBF800000),
        (0x40000000, 0xBF800000),

        (0x7F800000, 0x3F800000),
        (0xFF800000, 0xBF800000),
        (0x7F800000, 0xFF800000),
        (0xFF800000, 0x7F800000),

        (0x7FC00001, 0x3F800000),
        (0x3F800000, 0x7FC00002),
        (0x7F800001, 0x3F800000),
        (0x3F800000, 0x7F800002),
        (0x7FC12345, 0x7F800001),
        (0x7F800001, 0x7FC12345),

        (0x3F800000, 0x33800000),
        (0x3F800001, 0x33800000),
        (0xBF800000, 0xB3800000),
        (0xBF800001, 0xB3800000),

        (0x00000001, 0x00000001),
        (0x007FFFFF, 0x00000001),
        (0x00800000, 0x80000001),
        (0x00800001, 0x80800000),
        (0x00000001, 0x80000001),

        (0x7F7FFFFF, 0x72800000),
        (0x7F7FFFFF, 0x73000000),
        (0x7F7FFFFF, 0x7F7FFFFF),
        (0xFF7FFFFF, 0xFF7FFFFF),
    ]

    rng = random.Random(0x4E43454650333241)

    random_vectors = [
        (
            rng.getrandbits(32),
            rng.getrandbits(32),
        )
        for _ in range(250_000)
    ]

    vectors = directed_vectors + random_vectors

    with output_path.open("w", encoding="ascii") as vector_file:
        for a, b in vectors:
            (
                result,
                invalid,
                overflow,
                underflow,
                inexact,
            ) = resolve(a, b)

            vector_file.write(
                f"{a:08x} "
                f"{b:08x} "
                f"{result:08x} "
                f"{invalid:01x} "
                f"{overflow:01x} "
                f"{underflow:01x} "
                f"{inexact:01x}\n"
            )

    print(f"Generated {len(vectors)} vectors: {output_path}")


if __name__ == "__main__":
    main()
