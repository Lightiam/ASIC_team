#!/usr/bin/env python3

from __future__ import annotations

import argparse
import random
import struct
from pathlib import Path


LANE_COUNT = 8


def float32_bits(value: float) -> int:
    return struct.unpack(
        ">I",
        struct.pack(">f", value),
    )[0]


def integer_to_bf16(value: int) -> int:
    return (float32_bits(float(value)) >> 16) & 0xFFFF


def pack_bf16x2_lanes(
    low_values: list[int],
    high_values: list[int],
) -> int:
    packed = 0

    for lane_index in range(LANE_COUNT):
        lane_word = (
            integer_to_bf16(low_values[lane_index])
            |
            (
                integer_to_bf16(
                    high_values[lane_index]
                )
                << 16
            )
        )

        packed |= (
            lane_word <<
            (lane_index * 32)
        )

    return packed


def pack_fp32_lanes(
    values: list[int],
) -> int:
    packed = 0

    for lane_index, value in enumerate(values):
        packed |= (
            float32_bits(float(value))
            << (lane_index * 32)
        )

    return packed


def generate_vectors(
    output_path: Path,
    operation_count: int,
    seed: int,
) -> int:
    rng = random.Random(seed)

    accumulator = [0] * LANE_COUNT
    vector_count = 0

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with output_path.open(
        "w",
        encoding="utf-8",
    ) as handle:
        handle.write(
            f"1 "
            f"{0:064x} "
            f"{0:064x} "
            f"{0:064x}\n"
        )
        vector_count += 1

        for operation_index in range(operation_count):
            if (
                operation_index != 0
                and operation_index % 1000 == 0
            ):
                accumulator = [0] * LANE_COUNT

                handle.write(
                    f"1 "
                    f"{0:064x} "
                    f"{0:064x} "
                    f"{0:064x}\n"
                )
                vector_count += 1

            lhs_low = [
                rng.randint(-8, 8)
                for _ in range(LANE_COUNT)
            ]

            lhs_high = [
                rng.randint(-8, 8)
                for _ in range(LANE_COUNT)
            ]

            rhs_low = [
                rng.randint(-8, 8)
                for _ in range(LANE_COUNT)
            ]

            rhs_high = [
                rng.randint(-8, 8)
                for _ in range(LANE_COUNT)
            ]

            for lane_index in range(LANE_COUNT):
                accumulator[lane_index] += (
                    lhs_low[lane_index]
                    * rhs_low[lane_index]
                    +
                    lhs_high[lane_index]
                    * rhs_high[lane_index]
                )

            packed_lhs = pack_bf16x2_lanes(
                lhs_low,
                lhs_high,
            )

            packed_rhs = pack_bf16x2_lanes(
                rhs_low,
                rhs_high,
            )

            packed_expected = pack_fp32_lanes(
                accumulator
            )

            handle.write(
                f"0 "
                f"{packed_lhs:064x} "
                f"{packed_rhs:064x} "
                f"{packed_expected:064x}\n"
            )

            vector_count += 1

    return vector_count


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/bf16_simd8_vectors.txt"
        ),
    )

    parser.add_argument(
        "--operation-count",
        type=int,
        default=5000,
    )

    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0xBF16_5208,
    )

    args = parser.parse_args()

    count = generate_vectors(
        output_path=args.output,
        operation_count=args.operation_count,
        seed=args.seed,
    )

    print(
        f"Generated {count} BF16X2 SIMD8 vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
