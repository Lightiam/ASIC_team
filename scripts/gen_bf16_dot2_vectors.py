#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import random
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)

    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bf16_reference = load_module(
    "bf16_reference",
    SCRIPT_DIR / "gen_bf16_mul_vectors.py",
)

fp32_reference = load_module(
    "fp32_reference",
    SCRIPT_DIR / "gen_fp32_add_vectors.py",
)


def dot2_reference(
    lhs: int,
    rhs: int,
) -> tuple[int, int, int, int, int]:
    lhs_0 = lhs & 0xFFFF
    lhs_1 = (lhs >> 16) & 0xFFFF

    rhs_0 = rhs & 0xFFFF
    rhs_1 = (rhs >> 16) & 0xFFFF

    (
        product_0,
        invalid_0,
        overflow_0,
        underflow_0,
        inexact_0,
    ) = bf16_reference.bf16_mul_reference(
        lhs_0,
        rhs_0,
    )

    (
        product_1,
        invalid_1,
        overflow_1,
        underflow_1,
        inexact_1,
    ) = bf16_reference.bf16_mul_reference(
        lhs_1,
        rhs_1,
    )

    (
        result,
        add_invalid,
        add_overflow,
        add_underflow,
        add_inexact,
    ) = fp32_reference.resolve(
        product_0,
        product_1,
    )

    return (
        result,
        int(invalid_0 or invalid_1 or add_invalid),
        int(overflow_0 or overflow_1 or add_overflow),
        int(underflow_0 or underflow_1 or add_underflow),
        int(inexact_0 or inexact_1 or add_inexact),
    )


def generate_vectors(
    output_path: Path,
    random_count: int,
    seed: int,
) -> int:
    directed = [
        (0x00000000, 0x00000000),
        (0x3F803F80, 0x3F803F80),
        (0x40403F80, 0x40804000),
        (0xBF803F80, 0x40004000),
        (0x3F807F80, 0x3F800000),
        (0x00007F7F, 0x00007F7F),
        (0x00000001, 0x00000001),
        (0x7FC13F80, 0x3F803F80),
        (0x7F813F80, 0x3F803F80),
    ]

    rng = random.Random(seed)
    vectors = list(directed)

    for _ in range(random_count):
        vectors.append(
            (
                rng.randrange(1 << 32),
                rng.randrange(1 << 32),
            )
        )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with output_path.open(
        "w",
        encoding="utf-8",
    ) as handle:
        for lhs, rhs in vectors:
            (
                result,
                invalid,
                overflow,
                underflow,
                inexact,
            ) = dot2_reference(lhs, rhs)

            handle.write(
                f"{lhs:08x} "
                f"{rhs:08x} "
                f"{result:08x} "
                f"{invalid:d} "
                f"{overflow:d} "
                f"{underflow:d} "
                f"{inexact:d}\n"
            )

    return len(vectors)


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "build/bf16_dot2_vectors.txt"
        ),
    )

    parser.add_argument(
        "--random-count",
        type=int,
        default=100_000,
    )

    parser.add_argument(
        "--seed",
        type=lambda value: int(value, 0),
        default=0xBF16_D072,
    )

    args = parser.parse_args()

    count = generate_vectors(
        args.output,
        args.random_count,
        args.seed,
    )

    print(
        f"Generated {count} BF16X2 DOT2 vectors: "
        f"{args.output.resolve()}"
    )


if __name__ == "__main__":
    main()
