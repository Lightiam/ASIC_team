#!/usr/bin/env python3

import random
import struct
from pathlib import Path


def signed_int8(value: int) -> int:
    return value - 256 if value & 0x80 else value


def dot4(lhs: int, rhs: int) -> int:
    result = 0

    for index in range(4):
        lhs_element = signed_int8((lhs >> (index * 8)) & 0xFF)
        rhs_element = signed_int8((rhs >> (index * 8)) & 0xFF)
        result += lhs_element * rhs_element

    return result


def float32_bits(value: int) -> int:
    packed = struct.pack(">f", float(value))
    return struct.unpack(">I", packed)[0]


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    output_path = project_root / "build" / "int8_dot4_fp32_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    directed_vectors = [
        (0x00000000, 0x00000000),
        (0x7F7F7F7F, 0x7F7F7F7F),
        (0x80808080, 0x80808080),
        (0x80808080, 0x7F7F7F7F),
        (0x7F7F7F7F, 0x80808080),
        (0xFFFFFFFF, 0xFFFFFFFF),
        (0x01010101, 0x01010101),
        (0x01FF7F80, 0xFF017F80),
        (0x04030201, 0xFCFDFEFF),
        (0x12345678, 0x87654321),
        (0xAAAAAAAA, 0x55555555),
    ]

    rng = random.Random(0x4E4345)

    random_vectors = [
        (rng.getrandbits(32), rng.getrandbits(32))
        for _ in range(100_000)
    ]

    vectors = directed_vectors + random_vectors

    with output_path.open("w", encoding="ascii") as vector_file:
        for lhs, rhs in vectors:
            integer_result = dot4(lhs, rhs)
            integer_raw = integer_result & ((1 << 18) - 1)
            fp32_result = float32_bits(integer_result)

            vector_file.write(
                f"{lhs:08x} "
                f"{rhs:08x} "
                f"{integer_raw:05x} "
                f"{fp32_result:08x}\n"
            )

    print(f"Generated {len(vectors)} vectors: {output_path}")


if __name__ == "__main__":
    main()
