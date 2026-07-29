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


def shift_right_jam(value: int, amount: int) -> int:
    width = 27
    value &= (1 << width) - 1

    if amount == 0:
        return value

    if amount >= width:
        return 1 if value != 0 else 0

    shifted = value >> amount
    discarded = value & ((1 << amount) - 1)

    if discarded:
        shifted |= 1

    return shifted


def raw_addsub(a: int, b: int) -> tuple[int, int, int, int]:
    a_sign, a_exp, a_sig = decode_finite(a)
    b_sign, b_exp, b_sig = decode_finite(b)

    a_is_larger = (
        a_exp > b_exp
        or (
            a_exp == b_exp
            and a_sig >= b_sig
        )
    )

    if a_is_larger:
        large_sign = a_sign
        small_sign = b_sign
        exponent = a_exp
        difference = a_exp - b_exp
        large_sig = a_sig
        small_sig = b_sig
    else:
        large_sign = b_sign
        small_sign = a_sign
        exponent = b_exp
        difference = b_exp - a_exp
        large_sig = b_sig
        small_sig = a_sig

    subtract = large_sign ^ small_sign

    large_extended = large_sig << 3
    small_extended = shift_right_jam(
        small_sig << 3,
        difference,
    )

    if subtract:
        raw = large_extended - small_extended
    else:
        raw = large_extended + small_extended

    exact_zero = int(raw == 0)
    result_sign = 0 if exact_zero else large_sign

    return result_sign, exponent, raw, exact_zero


def normalize(
    result_sign: int,
    exponent: int,
    raw: int,
    exact_zero: int,
) -> tuple[int, int, int, int, int]:
    if exact_zero or raw == 0:
        return 0, 0, 0, 0, 1

    if (raw >> 27) & 1:
        significand = (raw >> 1) | (raw & 1)
        normalized_exponent = min(exponent + 1, 0xFF)
    else:
        raw_27 = raw & ((1 << 27) - 1)
        leading_index = raw_27.bit_length() - 1
        desired_shift = 26 - leading_index
        exponent_room = max(exponent - 1, 0)
        actual_shift = min(desired_shift, exponent_room)

        significand = (
            raw_27 << actual_shift
        ) & ((1 << 27) - 1)

        normalized_exponent = exponent - actual_shift

    is_subnormal = int(
        normalized_exponent == 1
        and ((significand >> 26) & 1) == 0
    )

    return (
        result_sign,
        normalized_exponent,
        significand,
        is_subnormal,
        0,
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
    output_path = root / "build" / "fp32_normalize_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed = [
        (0x00000000, 0x00000000),
        (0x80000000, 0x80000000),
        (0x3F800000, 0x3F800000),
        (0x3F800000, 0xBF800000),
        (0x40000000, 0xBF800000),
        (0x3F800000, 0xBF7FFFFF),
        (0x3F800001, 0xBF800000),
        (0x00800000, 0x807FFFFF),
        (0x00800000, 0x80000001),
        (0x007FFFFF, 0x00000001),
        (0x00000001, 0x00000001),
        (0x00000002, 0x80000001),
        (0x7F7FFFFF, 0x7F7FFFFF),
        (0xFF7FFFFF, 0xFF7FFFFF),
        (0x7F7FFFFF, 0xFF7FFFFF),
        (0x01000000, 0x80800000),
        (0x3F000000, 0xBEFFFFFF),
        (0x00800001, 0x80800000),
        (0x3F800000, 0x33800000),
        (0xBF800000, 0xB3800000),
    ]

    rng = random.Random(0x4E43454E4F524D)

    random_vectors = [
        (
            random_finite(rng),
            random_finite(rng),
        )
        for _ in range(200_000)
    ]

    vectors = directed + random_vectors

    with output_path.open("w", encoding="ascii") as vector_file:
        for a, b in vectors:
            sign, exponent, raw, exact_zero = raw_addsub(a, b)

            (
                expected_sign,
                expected_exponent,
                expected_significand,
                expected_subnormal,
                expected_zero,
            ) = normalize(
                sign,
                exponent,
                raw,
                exact_zero,
            )

            vector_file.write(
                f"{a:08x} "
                f"{b:08x} "
                f"{expected_sign:01x} "
                f"{expected_exponent:02x} "
                f"{expected_significand:07x} "
                f"{expected_subnormal:01x} "
                f"{expected_zero:01x}\n"
            )

    print(f"Generated {len(vectors)} vectors: {output_path}")


if __name__ == "__main__":
    main()
