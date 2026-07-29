#!/usr/bin/env python3

import struct
from pathlib import Path


def float32_bits(value: int) -> int:
    packed = struct.pack(">f", float(value))
    return struct.unpack(">I", packed)[0]


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    output_path = project_root / "build" / "int18_to_fp32_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    minimum = -(1 << 17)
    maximum = (1 << 17) - 1
    mask = (1 << 18) - 1

    with output_path.open("w", encoding="ascii") as vector_file:
        for value in range(minimum, maximum + 1):
            raw_input = value & mask
            expected = float32_bits(value)

            vector_file.write(
                f"{raw_input:05x} {expected:08x}\n"
            )

    print(
        f"Generated {maximum - minimum + 1} exhaustive vectors:"
        f" {output_path}"
    )


if __name__ == "__main__":
    main()
