#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import random
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

LANE_COUNT = 8

PRECISION_INT8X4 = 0
PRECISION_BF16X2 = 1
PRECISION_BF24 = 2


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(
        name,
        path,
    )

    if spec is None or spec.loader is None:
        raise RuntimeError(
            f"Unable to load Python reference: {path}"
        )

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    return module


lane_reference = load_module(
    "mixed_lane_reference",
    SCRIPT_DIR /
    "gen_mixed_precision_mac_lane_vectors.py",
)

fp32_reference = load_module(
    "fp32_reference",
    SCRIPT_DIR / "gen_fp32_add_vectors.py",
)


def pack_words(words: list[int]) -> int:
    packed = 0

    for lane_index, word in enumerate(words):
        packed |= (
            (word & 0xFFFF_FFFF)
            << (lane_index * 32)
        )

    return packed


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> tuple[int, int]:
    rng = random.Random(seed)

    accumulators = [0] * LANE_COUNT

    accumulator_invalid_sticky = [False] * LANE_COUNT
    accumulator_overflow_sticky = [False] * LANE_COUNT
    accumulator_underflow_sticky = [False] * LANE_COUNT
    accumulator_inexact_sticky = [False] * LANE_COUNT

    vector_count = 0
    operation_count = 0

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with output_path.open(
        "w",
        encoding="utf-8",
    ) as handle:

        def write_clear() -> None:
            nonlocal accumulators
            nonlocal accumulator_invalid_sticky
            nonlocal accumulator_overflow_sticky
            nonlocal accumulator_underflow_sticky
            nonlocal accumulator_inexact_sticky
            nonlocal vector_count

            accumulators = [0] * LANE_COUNT

            accumulator_invalid_sticky = [False] * LANE_COUNT
            accumulator_overflow_sticky = [False] * LANE_COUNT
            accumulator_underflow_sticky = [False] * LANE_COUNT
            accumulator_inexact_sticky = [False] * LANE_COUNT

            handle.write(
                f"1 0 "
                f"{0:064x} "
                f"{0:064x} "
                f"{0:064x} "
                f"00 00 00 00\n"
            )

            vector_count += 1

        def write_operation(
            precision: int,
            lhs_words: list[int],
            rhs_words: list[int],
        ) -> None:
            nonlocal vector_count
            nonlocal operation_count
            nonlocal accumulators
            nonlocal accumulator_invalid_sticky
            nonlocal accumulator_overflow_sticky
            nonlocal accumulator_underflow_sticky
            nonlocal accumulator_inexact_sticky

            expected_words = [0] * LANE_COUNT

            lane_invalid = 0
            lane_overflow = 0
            lane_underflow = 0
            lane_inexact = 0

            for lane_index in range(LANE_COUNT):
                (
                    addend,
                    pre_invalid,
                    pre_overflow,
                    pre_underflow,
                    pre_inexact,
                ) = lane_reference.calculate_addend(
                    precision,
                    lhs_words[lane_index],
                    rhs_words[lane_index],
                )

                (
                    result,
                    add_invalid,
                    add_overflow,
                    add_underflow,
                    add_inexact,
                ) = fp32_reference.resolve(
                    accumulators[lane_index],
                    addend,
                )

                accumulator_invalid_sticky[lane_index] = (
                    accumulator_invalid_sticky[lane_index] or
                    bool(add_invalid)
                )

                accumulator_overflow_sticky[lane_index] = (
                    accumulator_overflow_sticky[lane_index] or
                    bool(add_overflow)
                )

                accumulator_underflow_sticky[lane_index] = (
                    accumulator_underflow_sticky[lane_index] or
                    bool(add_underflow)
                )

                accumulator_inexact_sticky[lane_index] = (
                    accumulator_inexact_sticky[lane_index] or
                    bool(add_inexact)
                )

                invalid = int(
                    bool(pre_invalid) or
                    accumulator_invalid_sticky[lane_index]
                )

                overflow = int(
                    bool(pre_overflow) or
                    accumulator_overflow_sticky[lane_index]
                )

                underflow = int(
                    bool(pre_underflow) or
                    accumulator_underflow_sticky[lane_index]
                )

                inexact = int(
                    bool(pre_inexact) or
                    accumulator_inexact_sticky[lane_index]
                )

                expected_words[lane_index] = result
                accumulators[lane_index] = result

                lane_invalid |= (
                    invalid << lane_index
                )

                lane_overflow |= (
                    overflow << lane_index
                )

                lane_underflow |= (
                    underflow << lane_index
                )

                lane_inexact |= (
                    inexact << lane_index
                )

            handle.write(
                f"0 "
                f"{precision:x} "
                f"{pack_words(lhs_words):064x} "
                f"{pack_words(rhs_words):064x} "
                f"{pack_words(expected_words):064x} "
                f"{lane_invalid:02x} "
                f"{lane_overflow:02x} "
                f"{lane_underflow:02x} "
                f"{lane_inexact:02x}\n"
            )

            vector_count += 1
            operation_count += 1

        write_clear()

        for index in range(random_count):
            if index != 0 and index % 250 == 0:
                write_clear()

            precision = rng.choice(
                [
                    PRECISION_INT8X4,
                    PRECISION_BF16X2,
                    PRECISION_BF24,
                ]
            )

            lhs_words = []
            rhs_words = []

            for _ in range(LANE_COUNT):
                if precision == PRECISION_INT8X4:
                    lhs_words.append(
                        lane_reference.pack_int8x4(
                            [
                                rng.randint(-8, 8)
                                for _ in range(4)
                            ]
                        )
                    )

                    rhs_words.append(
                        lane_reference.pack_int8x4(
                            [
                                rng.randint(-8, 8)
                                for _ in range(4)
                            ]
                        )
                    )

                elif precision == PRECISION_BF16X2:
                    lhs_words.append(
                        lane_reference.pack_bf16x2(
                            rng.randint(-8, 8),
                            rng.randint(-8, 8),
                        )
                    )

                    rhs_words.append(
                        lane_reference.pack_bf16x2(
                            rng.randint(-8, 8),
                            rng.randint(-8, 8),
                        )
                    )

                else:
                    # One BF24 operand per lane. Bits [31:24] remain zero.
                    lhs_words.append(
                        rng.getrandbits(24)
                    )

                    rhs_words.append(
                        rng.getrandbits(24)
                    )

            write_operation(
                precision,
                lhs_words,
                rhs_words,
            )

        # Cross-precision accumulation in every lane:
        #
        # INT8X4: 1*5 + 2*6 + 3*7 + 4*8 = 70
        # BF16X2: 1*2 + 3*4 = 14
        # BF24:   2*5 = 10
        #
        # Final shared accumulator = 94.

        write_clear()

        write_operation(
            PRECISION_INT8X4,
            [
                lane_reference.pack_int8x4(
                    [1, 2, 3, 4]
                )
                for _ in range(LANE_COUNT)
            ],
            [
                lane_reference.pack_int8x4(
                    [5, 6, 7, 8]
                )
                for _ in range(LANE_COUNT)
            ],
        )

        write_operation(
            PRECISION_BF16X2,
            [
                lane_reference.pack_bf16x2(1, 3)
                for _ in range(LANE_COUNT)
            ],
            [
                lane_reference.pack_bf16x2(2, 4)
                for _ in range(LANE_COUNT)
            ],
        )

        write_operation(
            PRECISION_BF24,
            [
                0x0040_0000
                for _ in range(LANE_COUNT)
            ],
            [
                0x0040_A000
                for _ in range(LANE_COUNT)
            ],
        )

        # Lane 3: infinity*zero + 1*1 -> invalid NaN.

        write_clear()

        lhs_words = [0] * LANE_COUNT
        rhs_words = [0] * LANE_COUNT

        lhs_words[3] = 0x3F80_7F80
        rhs_words[3] = 0x3F80_0000

        write_operation(
            PRECISION_BF16X2,
            lhs_words,
            rhs_words,
        )

        # Lane 5: largest finite BF16 squared -> overflow.

        write_clear()

        lhs_words = [0] * LANE_COUNT
        rhs_words = [0] * LANE_COUNT

        lhs_words[5] = 0x0000_7F7F
        rhs_words[5] = 0x0000_7F7F

        write_operation(
            PRECISION_BF16X2,
            lhs_words,
            rhs_words,
        )

        # Lane 2: smallest BF16 subnormal squared -> underflow.

        write_clear()

        lhs_words = [0] * LANE_COUNT
        rhs_words = [0] * LANE_COUNT

        lhs_words[2] = 0x0000_0001
        rhs_words[2] = 0x0000_0001

        write_operation(
            PRECISION_BF16X2,
            lhs_words,
            rhs_words,
        )

        # Lane 1: BF24 infinity multiplied by zero -> invalid.
        write_clear()

        lhs_words = [0] * LANE_COUNT
        rhs_words = [0] * LANE_COUNT

        lhs_words[1] = 0x007F_8000
        rhs_words[1] = 0x0000_0000

        write_operation(
            PRECISION_BF24,
            lhs_words,
            rhs_words,
        )

        # Lane 6: maximum finite BF24 squared -> overflow.
        write_clear()

        lhs_words = [0] * LANE_COUNT
        rhs_words = [0] * LANE_COUNT

        lhs_words[6] = 0x007F_7FFF
        rhs_words[6] = 0x007F_7FFF

        write_operation(
            PRECISION_BF24,
            lhs_words,
            rhs_words,
        )

        # Lane 4: minimum BF24 subnormal squared -> underflow/inexact.
        write_clear()

        lhs_words = [0] * LANE_COUNT
        rhs_words = [0] * LANE_COUNT

        lhs_words[4] = 0x0000_0001
        rhs_words[4] = 0x0000_0001

        write_operation(
            PRECISION_BF24,
            lhs_words,
            rhs_words,
        )

    return vector_count, operation_count


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/mixed_precision_simd8_vectors.txt"
        ),
    )

    parser.add_argument(
        "--random-count",
        type=int,
        default=4000,
    )

    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0x5349_4D44,
    )

    args = parser.parse_args()

    vector_count, operation_count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {vector_count} mixed-precision SIMD8 vectors "
        f"containing {operation_count} operations: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
