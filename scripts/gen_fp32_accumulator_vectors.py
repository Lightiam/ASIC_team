#!/usr/bin/env python3

import random
from pathlib import Path

from gen_fp32_add_vectors import resolve


SPECIAL_VALUES = [
    0x00000000,  # +0
    0x80000000,  # -0
    0x00000001,  # smallest positive subnormal
    0x80000001,  # smallest negative subnormal
    0x007FFFFF,  # largest positive subnormal
    0x00800000,  # smallest positive normal
    0x3F800000,  # +1.0
    0xBF800000,  # -1.0
    0x7F7FFFFF,  # largest positive finite
    0xFF7FFFFF,  # largest negative finite
    0x7F800000,  # +infinity
    0xFF800000,  # -infinity
    0x7FC00001,  # quiet NaN
    0x7F800001,  # signaling NaN
]


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
    output_path = root / "build" / "fp32_accumulator_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Each tuple is:
    #   clear, valid, addend
    directed_cycles = [
        (0, 0, 0x00000000),
        (0, 1, 0x3F800000),  # 0 + 1 = 1
        (0, 1, 0x40000000),  # 1 + 2 = 3
        (0, 1, 0xBF000000),  # 3 - 0.5 = 2.5
        (1, 1, 0x42F60000),  # clear; valid input must be ignored
        (0, 0, 0x00000000),
        (0, 1, 0x00000001),
        (0, 1, 0x00000001),
        (0, 1, 0x007FFFFF),
        (1, 0, 0x00000000),
        (0, 1, 0x7F7FFFFF),
        (0, 1, 0x73000000),  # overflow path
        (1, 0, 0x00000000),
        (0, 1, 0x7F800000),
        (0, 1, 0xFF800000),  # invalid: +inf + -inf
        (1, 0, 0x00000000),
        (0, 1, 0x7F800001),  # signaling NaN
        (0, 1, 0x3F800000),
        (1, 1, 0x7F800001),  # ignored because clear is asserted
        (0, 1, 0x3F800000),
        (0, 1, 0x33800000),  # tie-to-even/inexact case
        (0, 0, 0xDEADBEEF),
    ]

    rng = random.Random(0x4E4345414343554D)

    cycles = list(directed_cycles)

    # Start a new accumulation episode every 50 cycles. This prevents one
    # injected NaN or infinity from dominating the remaining random tests.
    for _ in range(2_000):
        cycles.append(
            (
                1,
                rng.getrandbits(1),
                rng.getrandbits(32),
            )
        )

        for _ in range(49):
            valid = int(rng.random() < 0.80)

            if rng.random() < 0.05:
                addend = rng.choice(SPECIAL_VALUES)
            else:
                addend = random_finite(rng)

            cycles.append((0, valid, addend))

    accumulator = 0x00000000
    accumulator_valid = 0

    sticky_invalid = 0
    sticky_overflow = 0
    sticky_underflow = 0
    sticky_inexact = 0

    with output_path.open("w", encoding="ascii") as vector_file:
        for clear, valid, addend in cycles:
            ready = int(not clear)

            if clear:
                accumulator = 0x00000000
                accumulator_valid = 0

                sticky_invalid = 0
                sticky_overflow = 0
                sticky_underflow = 0
                sticky_inexact = 0

            elif valid and ready:
                (
                    result,
                    invalid,
                    overflow,
                    underflow,
                    inexact,
                ) = resolve(accumulator, addend)

                accumulator = result
                accumulator_valid = 1

                sticky_invalid |= invalid
                sticky_overflow |= overflow
                sticky_underflow |= underflow
                sticky_inexact |= inexact

            vector_file.write(
                f"{clear:01x} "
                f"{valid:01x} "
                f"{addend:08x} "
                f"{ready:01x} "
                f"{accumulator:08x} "
                f"{accumulator_valid:01x} "
                f"{sticky_invalid:01x} "
                f"{sticky_overflow:01x} "
                f"{sticky_underflow:01x} "
                f"{sticky_inexact:01x}\n"
            )

    print(f"Generated {len(cycles)} cycles: {output_path}")


if __name__ == "__main__":
    main()
