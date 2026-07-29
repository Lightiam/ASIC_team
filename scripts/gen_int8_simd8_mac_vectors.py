#!/usr/bin/env python3

import random
from pathlib import Path

from gen_fp32_add_vectors import resolve
from gen_int8_mac_lane_vectors import dot4, integer_to_fp32_bits


LANE_COUNT = 8
WORD_MASK = 0xFFFFFFFF


def pack_lanes(words: list[int]) -> int:
    packed = 0

    for lane, word in enumerate(words):
        packed |= (
            (word & WORD_MASK)
            << (lane * 32)
        )

    return packed


def main() -> None:
    root = Path(__file__).resolve().parent.parent

    output_path = (
        root
        / "build"
        / "int8_simd8_mac_vectors.txt"
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    zero_words = [0x00000000] * LANE_COUNT
    one_words = [0x00000001] * LANE_COUNT
    maximum_words = [0x80808080] * LANE_COUNT

    lane_identity_lhs = [
        0x01010101,
        0x02020202,
        0x03030303,
        0x04040404,
        0x05050505,
        0x06060606,
        0x07070707,
        0x08080808,
    ]

    lane_identity_rhs = [
        0x01010101
    ] * LANE_COUNT

    mixed_lhs = [
        0x04030201,
        0xFCFDFEFF,
        0x7F7F7F7F,
        0x80808080,
        0x01020304,
        0xFFFFFFFF,
        0x12345678,
        0x89ABCDEF,
    ]

    mixed_rhs = [
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
        0x04030201,
        0xFFFFFFFF,
        0x87654321,
        0x10203040,
    ]

    # Tuple format:
    #   clear, valid, lhs_words, rhs_words
    directed_cycles = [
        (0, 0, zero_words, zero_words),
        (
            0,
            1,
            lane_identity_lhs,
            lane_identity_rhs,
        ),
        (
            0,
            1,
            mixed_lhs,
            mixed_rhs,
        ),
        (
            1,
            1,
            [0xDEADBEEF] * LANE_COUNT,
            [0x12345678] * LANE_COUNT,
        ),
        (0, 0, zero_words, zero_words),
    ]

    # Build 2^25 exactly in every lane.
    directed_cycles.extend(
        (
            0,
            1,
            maximum_words,
            maximum_words,
        )
        for _ in range(512)
    )

    # Adding one at 2^25 must set the inexact flag.
    directed_cycles.extend([
        (0, 1, one_words, one_words),
        (0, 0, zero_words, zero_words),
        (0, 0, zero_words, zero_words),
        (1, 0, zero_words, zero_words),
    ])

    rng = random.Random(0x53494D44384D4143)

    random_cycles = []

    for cycle_index in range(25_000):
        clear = int(
            cycle_index != 0
            and cycle_index % 1_000 == 0
        )

        valid = int(rng.random() < 0.85)

        lhs_words = []
        rhs_words = []

        for _lane in range(LANE_COUNT):
            selector = rng.random()

            if selector < 0.03:
                lhs_word = 0x80808080
                rhs_word = 0x80808080
            elif selector < 0.06:
                lhs_word = 0x80808080
                rhs_word = 0x7F7F7F7F
            elif selector < 0.09:
                lhs_word = 0x00000000
                rhs_word = rng.getrandbits(32)
            else:
                lhs_word = rng.getrandbits(32)
                rhs_word = rng.getrandbits(32)

            lhs_words.append(lhs_word)
            rhs_words.append(rhs_word)

        random_cycles.append(
            (
                clear,
                valid,
                lhs_words,
                rhs_words,
            )
        )

    # Flush the final pipeline entry.
    random_cycles.extend([
        (0, 0, zero_words, zero_words),
        (0, 0, zero_words, zero_words),
    ])

    cycles = directed_cycles + random_cycles

    stage_valid = 0
    stage_values = [0] * LANE_COUNT

    accumulators = [0] * LANE_COUNT
    accumulator_valid = 0

    lane_invalid = [0] * LANE_COUNT
    lane_overflow = [0] * LANE_COUNT
    lane_underflow = [0] * LANE_COUNT
    lane_inexact = [0] * LANE_COUNT

    with output_path.open(
        "w",
        encoding="ascii",
    ) as vector_file:
        for clear, valid, lhs_words, rhs_words in cycles:
            ready = int(not clear)

            old_stage_valid = stage_valid
            old_stage_values = list(stage_values)

            if clear:
                stage_valid = 0
                stage_values = [0] * LANE_COUNT

                accumulators = [0] * LANE_COUNT
                accumulator_valid = 0

                lane_invalid = [0] * LANE_COUNT
                lane_overflow = [0] * LANE_COUNT
                lane_underflow = [0] * LANE_COUNT
                lane_inexact = [0] * LANE_COUNT

                accumulator_update = 0
            else:
                accumulator_update = old_stage_valid

                if old_stage_valid:
                    for lane in range(LANE_COUNT):
                        (
                            result,
                            invalid,
                            overflow,
                            underflow,
                            inexact,
                        ) = resolve(
                            accumulators[lane],
                            old_stage_values[lane],
                        )

                        accumulators[lane] = result
                        accumulator_valid = 1

                        lane_invalid[lane] |= invalid
                        lane_overflow[lane] |= overflow
                        lane_underflow[lane] |= underflow
                        lane_inexact[lane] |= inexact

                if valid and ready:
                    stage_valid = 1

                    stage_values = [
                        integer_to_fp32_bits(
                            dot4(
                                lhs_words[lane],
                                rhs_words[lane],
                            )
                        )
                        for lane in range(LANE_COUNT)
                    ]
                else:
                    stage_valid = 0
                    stage_values = [0] * LANE_COUNT

            lhs_packed = pack_lanes(lhs_words)
            rhs_packed = pack_lanes(rhs_words)
            accumulator_packed = pack_lanes(accumulators)

            invalid_mask = sum(
                lane_invalid[lane] << lane
                for lane in range(LANE_COUNT)
            )

            overflow_mask = sum(
                lane_overflow[lane] << lane
                for lane in range(LANE_COUNT)
            )

            underflow_mask = sum(
                lane_underflow[lane] << lane
                for lane in range(LANE_COUNT)
            )

            inexact_mask = sum(
                lane_inexact[lane] << lane
                for lane in range(LANE_COUNT)
            )

            vector_file.write(
                f"{clear:01x} "
                f"{valid:01x} "
                f"{lhs_packed:064x} "
                f"{rhs_packed:064x} "
                f"{ready:01x} "
                f"{accumulator_packed:064x} "
                f"{accumulator_valid:01x} "
                f"{accumulator_update:01x} "
                f"{invalid_mask:02x} "
                f"{overflow_mask:02x} "
                f"{underflow_mask:02x} "
                f"{inexact_mask:02x} "
                f"{int(bool(invalid_mask)):01x} "
                f"{int(bool(overflow_mask)):01x} "
                f"{int(bool(underflow_mask)):01x} "
                f"{int(bool(inexact_mask)):01x}\n"
            )

    print(
        f"Generated {len(cycles)} SIMD cycles: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
