#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import random
import struct
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

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


bf16_dot2_reference = load_module(
    "bf16_dot2_reference",
    SCRIPT_DIR / "gen_bf16_dot2_vectors.py",
)

bf24_reference = load_module(
    "bf24_reference",
    SCRIPT_DIR / "gen_bf24_mul_vectors.py",
)

fp32_reference = load_module(
    "fp32_reference",
    SCRIPT_DIR / "gen_fp32_add_vectors.py",
)


def float32_bits(value: float) -> int:
    return struct.unpack(
        ">I",
        struct.pack(">f", value),
    )[0]


def integer_to_bf16(value: int) -> int:
    return (
        float32_bits(float(value)) >> 16
    ) & 0xFFFF


def pack_int8x4(values: list[int]) -> int:
    packed = 0

    for index, value in enumerate(values):
        packed |= (
            (value & 0xFF) <<
            (index * 8)
        )

    return packed


def pack_bf16x2(
    low_value: int,
    high_value: int,
) -> int:
    return (
        integer_to_bf16(low_value)
        |
        (
            integer_to_bf16(high_value)
            << 16
        )
    )


def int8_dot4_addend(
    lhs: int,
    rhs: int,
) -> tuple[int, int, int, int, int]:
    dot = 0

    for index in range(4):
        lhs_byte = (
            lhs >> (index * 8)
        ) & 0xFF

        rhs_byte = (
            rhs >> (index * 8)
        ) & 0xFF

        if lhs_byte & 0x80:
            lhs_byte -= 0x100

        if rhs_byte & 0x80:
            rhs_byte -= 0x100

        dot += lhs_byte * rhs_byte

    return (
        float32_bits(float(dot)),
        0,
        0,
        0,
        0,
    )


def calculate_addend(
    precision: int,
    lhs: int,
    rhs: int,
) -> tuple[int, int, int, int, int]:
    if precision == PRECISION_INT8X4:
        return int8_dot4_addend(
            lhs,
            rhs,
        )

    if precision == PRECISION_BF16X2:
        return bf16_dot2_reference.dot2_reference(
            lhs,
            rhs,
        )

    if precision == PRECISION_BF24:
        product, flags = (
            bf24_reference.bf24_mul_reference(
                lhs & 0x00FF_FFFF,
                rhs & 0x00FF_FFFF,
            )
        )

        return (
            product,
            (flags >> 3) & 1,
            (flags >> 2) & 1,
            (flags >> 1) & 1,
            flags & 1,
        )

    raise ValueError(
        f"Unsupported precision: {precision}"
    )


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    rng = random.Random(seed)

    accumulator = 0x00000000

    accumulator_invalid_sticky = False
    accumulator_overflow_sticky = False
    accumulator_underflow_sticky = False
    accumulator_inexact_sticky = False

    vector_count = 0

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with output_path.open(
        "w",
        encoding="utf-8",
    ) as handle:

        def write_clear() -> None:
            nonlocal accumulator
            nonlocal accumulator_invalid_sticky
            nonlocal accumulator_overflow_sticky
            nonlocal accumulator_underflow_sticky
            nonlocal accumulator_inexact_sticky
            nonlocal vector_count

            accumulator = 0x00000000

            accumulator_invalid_sticky = False
            accumulator_overflow_sticky = False
            accumulator_underflow_sticky = False
            accumulator_inexact_sticky = False

            handle.write(
                "1 0 00000000 00000000 "
                "00000000 0 0 0 0\n"
            )

            vector_count += 1

        def write_operation(
            precision: int,
            lhs: int,
            rhs: int,
        ) -> None:
            nonlocal accumulator
            nonlocal accumulator_invalid_sticky
            nonlocal accumulator_overflow_sticky
            nonlocal accumulator_underflow_sticky
            nonlocal accumulator_inexact_sticky
            nonlocal vector_count

            (
                addend,
                pre_invalid,
                pre_overflow,
                pre_underflow,
                pre_inexact,
            ) = calculate_addend(
                precision,
                lhs,
                rhs,
            )

            (
                result,
                add_invalid,
                add_overflow,
                add_underflow,
                add_inexact,
            ) = fp32_reference.resolve(
                accumulator,
                addend,
            )

            accumulator_invalid_sticky = (
                accumulator_invalid_sticky or
                bool(add_invalid)
            )

            accumulator_overflow_sticky = (
                accumulator_overflow_sticky or
                bool(add_overflow)
            )

            accumulator_underflow_sticky = (
                accumulator_underflow_sticky or
                bool(add_underflow)
            )

            accumulator_inexact_sticky = (
                accumulator_inexact_sticky or
                bool(add_inexact)
            )

            invalid = int(
                bool(pre_invalid) or
                accumulator_invalid_sticky
            )

            overflow = int(
                bool(pre_overflow) or
                accumulator_overflow_sticky
            )

            underflow = int(
                bool(pre_underflow) or
                accumulator_underflow_sticky
            )

            inexact = int(
                bool(pre_inexact) or
                accumulator_inexact_sticky
            )

            handle.write(
                f"0 "
                f"{precision:x} "
                f"{lhs:08x} "
                f"{rhs:08x} "
                f"{result:08x} "
                f"{invalid:d} "
                f"{overflow:d} "
                f"{underflow:d} "
                f"{inexact:d}\n"
            )

            accumulator = result
            vector_count += 1

        write_clear()

        for index in range(random_count):
            if index != 0 and index % 500 == 0:
                write_clear()

            precision = rng.choice(
                [
                    PRECISION_INT8X4,
                    PRECISION_BF16X2,
                    PRECISION_BF24,
                ]
            )

            if precision == PRECISION_INT8X4:
                lhs_values = [
                    rng.randint(-8, 8)
                    for _ in range(4)
                ]

                rhs_values = [
                    rng.randint(-8, 8)
                    for _ in range(4)
                ]

                lhs = pack_int8x4(lhs_values)
                rhs = pack_int8x4(rhs_values)

            elif precision == PRECISION_BF16X2:
                lhs = pack_bf16x2(
                    rng.randint(-8, 8),
                    rng.randint(-8, 8),
                )

                rhs = pack_bf16x2(
                    rng.randint(-8, 8),
                    rng.randint(-8, 8),
                )

            else:
                # Upper eight lane bits remain reserved and zero.
                lhs = rng.getrandbits(24)
                rhs = rng.getrandbits(24)

            write_operation(
                precision,
                lhs,
                rhs,
            )

        # Cross-precision accumulation:
        #
        # INT8 DOT4:
        #   1*5 + 2*6 + 3*7 + 4*8 = 70
        #
        # BF16 DOT2:
        #   1*2 + 3*4 = 14
        #
        # Shared accumulator result = 84.

        write_clear()

        write_operation(
            PRECISION_INT8X4,
            pack_int8x4([1, 2, 3, 4]),
            pack_int8x4([5, 6, 7, 8]),
        )

        write_operation(
            PRECISION_BF16X2,
            pack_bf16x2(1, 3),
            pack_bf16x2(2, 4),
        )

        # BF24:
        #   2 * 5 = 10
        #
        # Three-precision shared accumulator:
        #   70 + 14 + 10 = 94
        write_operation(
            PRECISION_BF24,
            0x0040_0000,
            0x0040_A000,
        )

        # Infinity * zero + 1 * 1.
        write_clear()

        write_operation(
            PRECISION_BF16X2,
            0x3F80_7F80,
            0x3F80_0000,
        )

        # Largest finite BF16 squared.
        write_clear()

        write_operation(
            PRECISION_BF16X2,
            0x0000_7F7F,
            0x0000_7F7F,
        )

        # Smallest BF16 subnormal squared.
        write_clear()

        write_operation(
            PRECISION_BF16X2,
            0x0000_0001,
            0x0000_0001,
        )

    return vector_count


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/mixed_precision_mac_lane_vectors.txt"
        ),
    )

    parser.add_argument(
        "--random-count",
        type=int,
        default=12_000,
    )

    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0x4D49_5845,
    )

    args = parser.parse_args()

    count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {count} mixed-precision MAC vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
