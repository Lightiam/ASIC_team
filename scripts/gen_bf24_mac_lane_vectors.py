#!/usr/bin/env python3

"""Generate BF24 MAC-lane verification vectors."""

from __future__ import annotations

import argparse
import importlib.util
import random
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


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


bf24_reference = load_module(
    "bf24_reference",
    SCRIPT_DIR / "gen_bf24_mul_vectors.py",
)

fp32_reference = load_module(
    "fp32_reference",
    SCRIPT_DIR / "gen_fp32_add_vectors.py",
)


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    rng = random.Random(seed)

    accumulator = 0x00000000

    # These model the sticky status registers inside
    # nce_fp32_accumulator. They clear only on reset/clear.
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
        encoding="ascii",
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
                "1 00000000 00000000 "
                "00000000 0 0 0 0\n"
            )

            vector_count += 1

        def write_operation(
            lhs_bf24: int,
            rhs_bf24: int,
        ) -> None:
            nonlocal accumulator
            nonlocal accumulator_invalid_sticky
            nonlocal accumulator_overflow_sticky
            nonlocal accumulator_underflow_sticky
            nonlocal accumulator_inexact_sticky
            nonlocal vector_count

            lhs_bf24 &= 0xFFFFFF
            rhs_bf24 &= 0xFFFFFF

            product, product_flags = (
                bf24_reference.bf24_mul_reference(
                    lhs_bf24,
                    rhs_bf24,
                )
            )

            (
                result,
                add_invalid,
                add_overflow,
                add_underflow,
                add_inexact,
            ) = fp32_reference.resolve(
                accumulator,
                product,
            )

            product_invalid = (product_flags >> 3) & 1
            product_overflow = (product_flags >> 2) & 1
            product_underflow = (product_flags >> 1) & 1
            product_inexact = product_flags & 1

            # The FP32 accumulator stores its arithmetic status
            # flags as sticky state.
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

            # Product flags describe the operation currently completing.
            # Accumulator flags include the sticky history of FP32 additions.
            invalid = int(
                bool(product_invalid) or
                accumulator_invalid_sticky
            )

            overflow = int(
                bool(product_overflow) or
                accumulator_overflow_sticky
            )

            underflow = int(
                bool(product_underflow) or
                accumulator_underflow_sticky
            )

            inexact = int(
                bool(product_inexact) or
                accumulator_inexact_sticky
            )

            handle.write(
                f"0 "
                f"{lhs_bf24:08x} "
                f"{rhs_bf24:08x} "
                f"{result:08x} "
                f"{invalid:d} "
                f"{overflow:d} "
                f"{underflow:d} "
                f"{inexact:d}\n"
            )

            accumulator = result
            vector_count += 1

        # Randomized accumulation, with regular clears so special values do not
        # permanently dominate the remaining sequence.
        write_clear()

        for index in range(random_count):
            if index != 0 and index % 250 == 0:
                write_clear()

            write_operation(
                rng.getrandbits(24),
                rng.getrandbits(24),
            )

        # Directed ordinary accumulation:
        #
        #   1 × 2 + 3 × 4 = 14
        write_clear()

        write_operation(
            0x3F8000,
            0x400000,
        )

        write_operation(
            0x404000,
            0x408000,
        )

        # Infinity multiplied by zero.
        write_clear()

        write_operation(
            0x7F8000,
            0x000000,
        )

        # Signalling NaN.
        write_clear()

        write_operation(
            0x7F8001,
            0x3F8000,
        )

        # Maximum finite BF24 squared.
        write_clear()

        write_operation(
            0x7F7FFF,
            0x7F7FFF,
        )

        # Minimum BF24 subnormal squared.
        write_clear()

        write_operation(
            0x000001,
            0x000001,
        )

        # Signed-zero behavior.
        write_clear()

        write_operation(
            0x800000,
            0xC04000,
        )

    return vector_count


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/bf24_mac_lane_vectors.txt"
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
        default=0xBF24_AC01,
    )

    args = parser.parse_args()

    vector_count = generate_vectors(
        output_path=args.output,
        random_count=args.random_count,
        seed=args.seed,
    )

    print(
        f"Generated {vector_count} BF24 MAC-lane vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
