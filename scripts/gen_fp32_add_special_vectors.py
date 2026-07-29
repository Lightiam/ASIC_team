#!/usr/bin/env python3

import random
from pathlib import Path


CANONICAL_QNAN = 0x7FC00000


def classify(value: int) -> dict[str, bool]:
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF

    exp_ones = exponent == 0xFF
    exp_zero = exponent == 0
    frac_zero = fraction == 0

    is_nan = exp_ones and not frac_zero

    return {
        "zero": exp_zero and frac_zero,
        "infinity": exp_ones and frac_zero,
        "nan": is_nan,
        "signaling_nan": is_nan and ((fraction >> 22) & 1) == 0,
    }


def quiet_nan(value: int) -> int:
    return value | 0x00400000


def resolve(a: int, b: int) -> tuple[int, int, int]:
    ca = classify(a)
    cb = classify(b)

    if ca["signaling_nan"]:
        return 1, quiet_nan(a), 1

    if cb["signaling_nan"]:
        return 1, quiet_nan(b), 1

    if ca["nan"]:
        return 1, quiet_nan(a), 0

    if cb["nan"]:
        return 1, quiet_nan(b), 0

    if (
        ca["infinity"]
        and cb["infinity"]
        and ((a >> 31) != (b >> 31))
    ):
        return 1, CANONICAL_QNAN, 1

    if ca["infinity"]:
        return 1, a, 0

    if cb["infinity"]:
        return 1, b, 0

    if ca["zero"] and cb["zero"]:
        sign = ((a >> 31) & 1) & ((b >> 31) & 1)
        return 1, sign << 31, 0

    if ca["zero"]:
        return 1, b, 0

    if cb["zero"]:
        return 1, a, 0

    return 0, 0, 0


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output_path = root / "build" / "fp32_add_special_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed = [
        (0x00000000, 0x00000000),
        (0x80000000, 0x80000000),
        (0x00000000, 0x80000000),
        (0x80000000, 0x00000000),
        (0x00000000, 0x3F800000),
        (0xBF800000, 0x00000000),
        (0x7F800000, 0x3F800000),
        (0xFF800000, 0xBF800000),
        (0x7F800000, 0x7F800000),
        (0xFF800000, 0xFF800000),
        (0x7F800000, 0xFF800000),
        (0xFF800000, 0x7F800000),
        (0x7FC00001, 0x3F800000),
        (0x3F800000, 0x7FC00002),
        (0x7F800001, 0x3F800000),
        (0x3F800000, 0x7F800002),
        (0x7FC12345, 0x7F800001),
        (0x7F800001, 0x7FC12345),
        (0x3F800000, 0x40000000),
        (0x00000001, 0x00000002),
    ]

    rng = random.Random(0x4E434541)

    random_vectors = [
        (rng.getrandbits(32), rng.getrandbits(32))
        for _ in range(200_000)
    ]

    vectors = directed + random_vectors

    with output_path.open("w", encoding="ascii") as vector_file:
        for a, b in vectors:
            handled, result, invalid = resolve(a, b)

            vector_file.write(
                f"{a:08x} "
                f"{b:08x} "
                f"{handled:01x} "
                f"{result:08x} "
                f"{invalid:01x}\n"
            )

    print(f"Generated {len(vectors)} vectors: {output_path}")


if __name__ == "__main__":
    main()
