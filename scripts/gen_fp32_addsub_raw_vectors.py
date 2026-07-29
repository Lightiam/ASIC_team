#!/usr/bin/env python3

import random
from pathlib import Path


def decode_finite(value: int) -> tuple[int, int, int]:
    sign = (value >> 31) & 1
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF

    if exponent == 0:
        effective_exponent = 1
        significand = fraction
    else:
        effective_exponent = exponent
        significand = (1 << 23) | fraction

    return sign, effective_exponent, significand


def shift_right_jam(value: int, shift_amount: int) -> int:
    width = 27
    value &= (1 << width) - 1

    if shift_amount == 0:
        return value

    if shift_amount >= width:
        return 1 if value != 0 else 0

    shifted = value >> shift_amount
    discarded_mask = (1 << shift_amount) - 1

    if value & discarded_mask:
        shifted |= 1

    return shifted


def calculate(a: int, b: int) -> tuple[int, int, int, int]:
    a_sign, a_exp, a_sig = decode_finite(a)
    b_sign, b_exp, b_sig = decode_finite(b)

    a_is_larger = (
        (a_exp > b_exp)
        or (
            a_exp == b_exp
            and a_sig >= b_sig
        )
    )

    if a_is_larger:
        large_sign = a_sign
        small_sign = b_sign
        common_exponent = a_exp
        exponent_difference = a_exp - b_exp
        large_significand = a_sig
        small_significand = b_sig
    else:
        large_sign = b_sign
        small_sign = a_sign
        common_exponent = b_exp
        exponent_difference = b_exp - a_exp
        large_significand = b_sig
        small_significand = a_sig

    subtract = large_sign ^ small_sign

    large_extended = large_significand << 3
    small_extended = shift_right_jam(
        small_significand << 3,
        exponent_difference,
    )

    if subtract:
        raw_result = large_extended - small_extended
    else:
        raw_result = large_extended + small_extended

    exact_zero = int(raw_result == 0)
    result_sign = 0 if exact_zero else large_sign

    return (
        result_sign,
        common_exponent,
        raw_result,
        exact_zero,
    )


def random_finite(rng: random.Random) -> int:
    sign = rng.getrandbits(1)
    exponent = rng.randrange(0, 255)
    fraction = rng.getrandbits(23)

    return (
        (sign << 31)
        | (exponent << 23)
        | fraction
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output_path = root / "build" / "fp32_addsub_raw_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed_vectors = [
        (0x00000000, 0x00000000),
        (0x80000000, 0x80000000),
        (0x3F800000, 0x3F800000),
        (0x3F800000, 0xBF800000),
        (0x40000000, 0x3F800000),
        (0x40000000, 0xBF800000),
        (0x3F800000, 0x40000000),
        (0xBF800000, 0x40000000),
        (0x3F000000, 0x3F800000),
        (0xBF000000, 0x3F800000),
        (0x00000001, 0x00000001),
        (0x00000001, 0x80000001),
        (0x007FFFFF, 0x00000001),
        (0x00800000, 0x807FFFFF),
        (0x7F7FFFFF, 0x7F7FFFFF),
        (0xFF7FFFFF, 0xFF7FFFFF),
        (0x7F7FFFFF, 0xFF7FFFFF),
        (0x3F800001, 0xBF800000),
        (0x3F800000, 0xBF7FFFFF),
        (0x00800000, 0x80000001),
    ]

    rng = random.Random(0x4E43454144445355)

    random_vectors = [
        (
            random_finite(rng),
            random_finite(rng),
        )
        for _ in range(200_000)
    ]

    vectors = directed_vectors + random_vectors

    with output_path.open("w", encoding="ascii") as vector_file:
        for a, b in vectors:
            result_sign, exponent, significand, exact_zero = calculate(a, b)

            vector_file.write(
                f"{a:08x} "
                f"{b:08x} "
                f"{result_sign:01x} "
                f"{exponent:02x} "
                f"{significand:07x} "
                f"{exact_zero:01x}\n"
            )

    print(f"Generated {len(vectors)} vectors: {output_path}")


if __name__ == "__main__":
    main()
