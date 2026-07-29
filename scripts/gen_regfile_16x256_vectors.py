#!/usr/bin/env python3

import random
from pathlib import Path


REGISTER_COUNT = 16
LANE_COUNT = 8
LANE_WIDTH = 32
REGISTER_WIDTH = 256

REGISTER_MASK = (1 << REGISTER_WIDTH) - 1


def merge_lanes(
    old_data: int,
    new_data: int,
    lane_enable: int,
) -> int:
    result = old_data

    for lane in range(LANE_COUNT):
        if (lane_enable >> lane) & 1:
            lane_mask = (
                ((1 << LANE_WIDTH) - 1)
                << (lane * LANE_WIDTH)
            )

            result = (
                (result & ~lane_mask)
                | (new_data & lane_mask)
            )

    return result & REGISTER_MASK


def pack_lanes(words: list[int]) -> int:
    result = 0

    for lane, word in enumerate(words):
        result |= (
            (word & 0xFFFFFFFF)
            << (lane * LANE_WIDTH)
        )

    return result


def main() -> None:
    root = Path(__file__).resolve().parent.parent

    output_path = (
        root
        / "build"
        / "regfile_16x256_vectors.txt"
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    full_pattern = pack_lanes([
        0x00000000,
        0x11111111,
        0x22222222,
        0x33333333,
        0x44444444,
        0x55555555,
        0x66666666,
        0x77777777,
    ])

    partial_pattern = pack_lanes([
        0xAAAAAAAA,
        0xBBBBBBBB,
        0xCCCCCCCC,
        0xDDDDDDDD,
        0xEEEEEEEE,
        0xFFFFFFFF,
        0x12345678,
        0x89ABCDEF,
    ])

    # Tuple format:
    # clear, write_enable, write_address, lane_mask,
    # write_data, read_address_a, read_address_b
    directed_cycles = [
        (0, 0, 0, 0x00, 0, 0, 15),
        (0, 1, 3, 0xFF, full_pattern, 3, 0),
        (0, 0, 0, 0x00, 0, 3, 3),
        (0, 1, 3, 0x81, partial_pattern, 3, 3),
        (0, 1, 5, 0x0C, partial_pattern, 5, 3),
        (0, 1, 6, 0x00, full_pattern, 6, 5),
        (1, 1, 2, 0xFF, full_pattern, 3, 5),
        (0, 0, 0, 0x00, 0, 3, 5),
        (0, 1, 15, 0xFF, partial_pattern, 15, 0),
        (0, 1, 0, 0x01, full_pattern, 0, 15),
    ]

    rng = random.Random(0x5245473136583235)

    random_cycles = []

    for cycle_index in range(50_000):
        clear = int(
            cycle_index != 0
            and cycle_index % 2_500 == 0
        )

        write_enable = int(rng.random() < 0.72)
        write_address = rng.randrange(REGISTER_COUNT)

        if rng.random() < 0.08:
            lane_mask = 0x00
        elif rng.random() < 0.20:
            lane_mask = 0xFF
        else:
            lane_mask = rng.randrange(1, 256)

        write_data = rng.getrandbits(REGISTER_WIDTH)

        read_address_a = rng.randrange(REGISTER_COUNT)
        read_address_b = rng.randrange(REGISTER_COUNT)

        # Frequently test write-through behavior.
        if write_enable and rng.random() < 0.30:
            read_address_a = write_address

        if write_enable and rng.random() < 0.20:
            read_address_b = write_address

        random_cycles.append((
            clear,
            write_enable,
            write_address,
            lane_mask,
            write_data,
            read_address_a,
            read_address_b,
        ))

    cycles = directed_cycles + random_cycles

    registers = [0] * REGISTER_COUNT
    valid_mask = 0

    with output_path.open(
        "w",
        encoding="ascii",
    ) as vector_file:
        for (
            clear,
            write_enable,
            write_address,
            lane_mask,
            write_data,
            read_address_a,
            read_address_b,
        ) in cycles:
            write_commit = (
                not clear
                and write_enable
                and lane_mask != 0
            )

            if clear:
                valid_mask = 0
            elif write_commit:
                if (valid_mask >> write_address) & 1:
                    old_data = registers[write_address]
                else:
                    old_data = 0

                registers[write_address] = merge_lanes(
                    old_data,
                    write_data,
                    lane_mask,
                )

                valid_mask |= 1 << write_address

            read_valid_a = (
                (valid_mask >> read_address_a) & 1
            )

            read_valid_b = (
                (valid_mask >> read_address_b) & 1
            )

            read_data_a = (
                registers[read_address_a]
                if read_valid_a
                else 0
            )

            read_data_b = (
                registers[read_address_b]
                if read_valid_b
                else 0
            )

            vector_file.write(
                f"{clear:01x} "
                f"{write_enable:01x} "
                f"{write_address:01x} "
                f"{lane_mask:02x} "
                f"{write_data:064x} "
                f"{read_address_a:01x} "
                f"{read_address_b:01x} "
                f"{read_data_a:064x} "
                f"{read_valid_a:01x} "
                f"{read_data_b:064x} "
                f"{read_valid_b:01x} "
                f"{valid_mask:04x}\n"
            )

    print(
        f"Generated {len(cycles)} register-file cycles: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
