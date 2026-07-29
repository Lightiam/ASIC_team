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
    fp32 = float32_bits(float(value))
    return (fp32 >> 16) & 0xFFFF


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    rng = random.Random(seed)

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    accumulator = 0
    vector_count = 0

    with output_path.open(
        "w",
        encoding="utf-8",
    ) as handle:
        # Initial clear.
        handle.write(
            "1 0000 0000 00000000\n"
        )
        vector_count += 1

        for index in range(random_count):
            if index != 0 and index % 5000 == 0:
                accumulator = 0

                handle.write(
                    "1 0000 0000 00000000\n"
                )
                vector_count += 1

            lhs_integer = rng.randint(-16, 16)
            rhs_integer = rng.randint(-16, 16)

            accumulator += (
                lhs_integer *
                rhs_integer
            )

            lhs_bf16 = integer_to_bf16(
                lhs_integer
            )

            rhs_bf16 = integer_to_bf16(
                rhs_integer
            )

            expected_accumulator = float32_bits(
                float(accumulator)
            )

            handle.write(
                f"0 "
                f"{lhs_bf16:04x} "
                f"{rhs_bf16:04x} "
                f"{expected_accumulator:08x}\n"
            )

            vector_count += 1

    return vector_count


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/bf16_mac_lane_vectors.txt"
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
        default=0xBF16_4D41,
    )

    args = parser.parse_args()

    count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {count} BF16 MAC lane vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
