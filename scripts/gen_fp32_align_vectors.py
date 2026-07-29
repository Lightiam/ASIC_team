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
    mask = (1 << width) - 1
    value &= mask

    if shift_amount == 0:
        return value

    if shift_amount >= width:
        return 1 if value != 0 else 0

    shifted = value >> shift_amount
    discarded_mask = (1 << shift_amount) - 1
    discarded_nonzero = (value & discarded_mask) != 0

    if discarded_nonzero:
        shifted |= 1

    return shifted


def align(a: int, b: int) -> tuple[int, ...]:
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
        large_is_a = 1
        large_sign = a_sign
        small_sign = b_sign
        common_exp = a_exp
        exponent_difference = a_exp - b_exp
        large_sig = a_sig
        small_sig = b_sig
    else:
        large_is_a = 0
        large_sign = b_sign
        small_sign = a_sign
        common_exp = b_exp
        exponent_difference = b_exp - a_exp
        large_sig = b_sig
        small_sig = a_sig

    subtract = large_sign ^ small_sign

    large_extended = large_sig << 3
    small_extended = shift_right_jam(
        small_sig << 3,
        exponent_difference,
    )

    return (
        large_is_a,
        large_sign,
        small_sign,
        subtract,
        common_exp,
        exponent_difference,
        large_extended,
        small_extended,
    )


def random_finite(rng: random.Random) -> int:
    sign = rng.getrandbits(1)

    # Exponent 255 is excluded because it represents infinity or NaN.
    exponent = rng.randrange(0, 255)
    fraction = rng.getrandbits(23)

    return (
        (sign << 31)
        | (exponent << 23)
        | fraction
    )


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    output_path = project_root / "build" / "fp32_align_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed_vectors = [
        (0x00000000, 0x00000000),
        (0x00000000, 0x80000000),
        (0x3F800000, 0x3F800000),
        (0x3F800000, 0xBF800000),
        (0x3F000000, 0x3F800000),
        (0x3F800000, 0x3F000000),
        (0x00000001, 0x00000001),
        (0x007FFFFF, 0x00800000),
        (0x00800000, 0x007FFFFF),
        (0x7F7FFFFF, 0x3F800000),
        (0x3F800000, 0x7F7FFFFF),
        (0xFF7FFFFF, 0x7F7FFFFF),
        (0x3F800001, 0x3F800000),
        (0x3F800000, 0x3F800001),
        (0x40000000, 0x3F800000),
        (0x3F800000, 0x40000000),
        (0xC0000000, 0x3F800000),
        (0x00800000, 0x00000001),
        (0x80800000, 0x00000001),
        (0x3F000001, 0x3F000000),
    ]

    rng = random.Random(0x4E4345414C49474E)

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
            expected = align(a, b)

            vector_file.write(
                f"{a:08x} "
                f"{b:08x} "
                f"{expected[0]:01x} "
                f"{expected[1]:01x} "
                f"{expected[2]:01x} "
                f"{expected[3]:01x} "
                f"{expected[4]:02x} "
                f"{expected[5]:02x} "
                f"{expected[6]:07x} "
                f"{expected[7]:07x}\n"
            )

    print(
        f"Generated {len(vectors)} vectors: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
