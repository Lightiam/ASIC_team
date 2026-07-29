#!/usr/bin/env python3

import random
import struct
from pathlib import Path

from gen_fp32_add_vectors import resolve


def signed_int8(value: int) -> int:
    return value - 256 if value & 0x80 else value


def dot4(lhs: int, rhs: int) -> int:
    total = 0

    for index in range(4):
        lhs_element = signed_int8(
            (lhs >> (8 * index)) & 0xFF
        )

        rhs_element = signed_int8(
            (rhs >> (8 * index)) & 0xFF
        )

        total += lhs_element * rhs_element

    return total


def integer_to_fp32_bits(value: int) -> int:
    return struct.unpack(
        ">I",
        struct.pack(">f", float(value)),
    )[0]


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output_path = root / "build" / "int8_mac_lane_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    zero_pair = (0x00000000, 0x00000000)
    one_pair = (0x00000001, 0x00000001)

    # Four products of (-128 × -128) produce the maximum DOT4 result:
    # 4 × 16384 = 65536.
    maximum_pair = (0x80808080, 0x80808080)

    directed_cycles: list[tuple[int, int, int, int]] = [
        (0, 0, *zero_pair),
        (0, 1, *one_pair),
        (0, 0, *zero_pair),
        (0, 1, 0x04030201, 0x01010101),
        (0, 1, 0xFCFDFEFF, 0x01010101),
        (0, 1, 0x7F7F7F7F, 0x01010101),
        (1, 1, 0xDEADBEEF, 0x12345678),
        (0, 0, *zero_pair),
    ]

    # Build a large exact accumulator and then add one. At 2^25, adding one
    # cannot be represented exactly in FP32 and must set the inexact flag.
    directed_cycles.extend(
        (0, 1, *maximum_pair)
        for _ in range(512)
    )

    directed_cycles.extend([
        (0, 1, *one_pair),
        (0, 0, *zero_pair),
        (0, 0, *zero_pair),
        (1, 0, *zero_pair),
        (0, 1, 0xFFFFFFFF, 0xFFFFFFFF),
        (0, 1, 0x01010101, 0x01010101),
        (0, 0, *zero_pair),
        (0, 0, *zero_pair),
    ])

    rng = random.Random(0x4E43454D41434C41)

    random_cycles: list[tuple[int, int, int, int]] = []

    for cycle_index in range(100_000):
        # Periodic clear creates independent accumulation episodes.
        clear = int(
            cycle_index != 0
            and cycle_index % 2_000 == 0
        )

        valid = int(rng.random() < 0.82)
        lhs = rng.getrandbits(32)
        rhs = rng.getrandbits(32)

        random_cycles.append(
            (clear, valid, lhs, rhs)
        )

    # Two bubbles flush any final pipeline entry.
    random_cycles.extend([
        (0, 0, *zero_pair),
        (0, 0, *zero_pair),
    ])

    cycles = directed_cycles + random_cycles

    stage_valid = 0
    stage_fp32 = 0

    accumulator = 0x00000000
    accumulator_valid = 0

    sticky_invalid = 0
    sticky_overflow = 0
    sticky_underflow = 0
    sticky_inexact = 0

    with output_path.open("w", encoding="ascii") as vector_file:
        for clear, valid, lhs, rhs in cycles:
            ready = int(not clear)

            old_stage_valid = stage_valid
            old_stage_fp32 = stage_fp32

            if clear:
                stage_valid = 0
                stage_fp32 = 0

                accumulator = 0x00000000
                accumulator_valid = 0

                sticky_invalid = 0
                sticky_overflow = 0
                sticky_underflow = 0
                sticky_inexact = 0

                accumulator_update = 0
            else:
                accumulator_update = old_stage_valid

                if old_stage_valid:
                    (
                        result,
                        invalid,
                        overflow,
                        underflow,
                        inexact,
                    ) = resolve(
                        accumulator,
                        old_stage_fp32,
                    )

                    accumulator = result
                    accumulator_valid = 1

                    sticky_invalid |= invalid
                    sticky_overflow |= overflow
                    sticky_underflow |= underflow
                    sticky_inexact |= inexact

                if valid and ready:
                    integer_result = dot4(lhs, rhs)
                    stage_fp32 = integer_to_fp32_bits(
                        integer_result
                    )
                    stage_valid = 1
                else:
                    # The old stage entry is consumed every non-clear cycle.
                    stage_fp32 = 0
                    stage_valid = 0

            vector_file.write(
                f"{clear:01x} "
                f"{valid:01x} "
                f"{lhs:08x} "
                f"{rhs:08x} "
                f"{ready:01x} "
                f"{accumulator:08x} "
                f"{accumulator_valid:01x} "
                f"{accumulator_update:01x} "
                f"{sticky_invalid:01x} "
                f"{sticky_overflow:01x} "
                f"{sticky_underflow:01x} "
                f"{sticky_inexact:01x}\n"
            )

    print(f"Generated {len(cycles)} cycles: {output_path}")


if __name__ == "__main__":
    main()
