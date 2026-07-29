#!/usr/bin/env python3

from __future__ import annotations

import argparse
import random
import struct
from pathlib import Path


def float32_bits(value: float) -> int:
    return struct.unpack(
        ">I",
        struct.pack(">f", value),
    )[0]


def integer_to_bf16(value: int) -> int:
    return (float32_bits(float(value)) >> 16) & 0xFFFF


def pack_bf16_pair(
    low_value: int,
    high_value: int,
) -> int:
    return (
        integer_to_bf16(low_value)
        |
        (integer_to_bf16(high_value) << 16)
    )


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    rng = random.Random(seed)

    accumulator = 0
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
            "1 00000000 00000000 00000000\n"
        )
        vector_count += 1

        for index in range(random_count):
            if index != 0 and index % 5000 == 0:
                accumulator = 0

                handle.write(
                    "1 00000000 00000000 00000000\n"
                )
                vector_count += 1

            lhs_0 = rng.randint(-16, 16)
            lhs_1 = rng.randint(-16, 16)

            rhs_0 = rng.randint(-16, 16)
            rhs_1 = rng.randint(-16, 16)

            accumulator += (
                lhs_0 * rhs_0
                +
                lhs_1 * rhs_1
            )

            lhs_word = pack_bf16_pair(
                lhs_0,
                lhs_1,
            )

            rhs_word = pack_bf16_pair(
                rhs_0,
                rhs_1,
            )

            expected = float32_bits(
                float(accumulator)
            )

            handle.write(
                f"0 "
                f"{lhs_word:08x} "
                f"{rhs_word:08x} "
                f"{expected:08x}\n"
            )

            vector_count += 1

    return vector_count


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/bf16_dot2_mac_lane_vectors.txt"
        ),
    )

    parser.add_argument(
        "--random-count",
        type=int,
        default=20_000,
    )

    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0xBF16_D072,
    )

    args = parser.parse_args()

    count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {count} BF16X2 DOT2 lane vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
