#!/usr/bin/env python3

import random
from pathlib import Path


REGISTER_COUNT = 16
REGISTER_WIDTH = 256
LANE_COUNT = 8
LANE_WIDTH = 32
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


def update_bank(
    registers: list[int],
    valid_mask: int,
    clear: int,
    write_enable: int,
    write_address: int,
    lane_enable: int,
    write_data: int,
) -> int:
    if clear:
        return 0

    write_commit = (
        write_enable
        and lane_enable != 0
    )

    if write_commit:
        old_data = (
            registers[write_address]
            if (valid_mask >> write_address) & 1
            else 0
        )

        registers[write_address] = merge_lanes(
            old_data,
            write_data,
            lane_enable,
        )

        valid_mask |= 1 << write_address

    return valid_mask


def read_bank(
    registers: list[int],
    valid_mask: int,
    address: int,
) -> tuple[int, int]:
    valid = (valid_mask >> address) & 1
    data = registers[address] if valid else 0

    return data, valid


def main() -> None:
    root = Path(__file__).resolve().parent.parent

    output_path = (
        root
        / "build"
        / "register_banks_vectors.txt"
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    vector_pattern = int(
        "11111111"
        "22222222"
        "33333333"
        "44444444"
        "55555555"
        "66666666"
        "77777777"
        "88888888",
        16,
    )

    matrix_pattern = int(
        "aaaaaaaa"
        "bbbbbbbb"
        "cccccccc"
        "dddddddd"
        "eeeeeeee"
        "ffffffff"
        "12345678"
        "89abcdef",
        16,
    )

    # clear,
    # vector write enable/address/lane mask/data/read A/read B,
    # matrix write enable/address/lane mask/data/read A/read B
    directed_cycles = [
        (
            0,
            0, 0, 0x00, 0, 0, 15,
            0, 0, 0x00, 0, 0, 15,
        ),
        (
            0,
            1, 3, 0xFF, vector_pattern, 3, 0,
            1, 3, 0xFF, matrix_pattern, 3, 0,
        ),
        (
            0,
            0, 0, 0x00, 0, 3, 3,
            0, 0, 0x00, 0, 3, 3,
        ),
        (
            0,
            1, 3, 0x81, matrix_pattern, 3, 3,
            1, 3, 0x18, vector_pattern, 3, 3,
        ),
        (
            0,
            1, 7, 0x0F, vector_pattern, 7, 3,
            1, 12, 0xF0, matrix_pattern, 12, 3,
        ),
        (
            1,
            1, 1, 0xFF, vector_pattern, 3, 7,
            1, 2, 0xFF, matrix_pattern, 3, 12,
        ),
        (
            0,
            0, 0, 0x00, 0, 3, 7,
            0, 0, 0x00, 0, 3, 12,
        ),
    ]

    rng = random.Random(0x4E4345524547424B)

    random_cycles = []

    for cycle_index in range(30_000):
        clear = int(
            cycle_index != 0
            and cycle_index % 2_000 == 0
        )

        vector_write_enable = int(
            rng.random() < 0.68
        )

        matrix_write_enable = int(
            rng.random() < 0.68
        )

        vector_write_address = rng.randrange(
            REGISTER_COUNT
        )

        matrix_write_address = rng.randrange(
            REGISTER_COUNT
        )

        vector_lane_enable = (
            0
            if rng.random() < 0.05
            else rng.randrange(1, 256)
        )

        matrix_lane_enable = (
            0
            if rng.random() < 0.05
            else rng.randrange(1, 256)
        )

        vector_write_data = rng.getrandbits(
            REGISTER_WIDTH
        )

        matrix_write_data = rng.getrandbits(
            REGISTER_WIDTH
        )

        vector_read_a = rng.randrange(REGISTER_COUNT)
        vector_read_b = rng.randrange(REGISTER_COUNT)

        matrix_read_a = rng.randrange(REGISTER_COUNT)
        matrix_read_b = rng.randrange(REGISTER_COUNT)

        random_cycles.append((
            clear,

            vector_write_enable,
            vector_write_address,
            vector_lane_enable,
            vector_write_data,
            vector_read_a,
            vector_read_b,

            matrix_write_enable,
            matrix_write_address,
            matrix_lane_enable,
            matrix_write_data,
            matrix_read_a,
            matrix_read_b,
        ))

    cycles = directed_cycles + random_cycles

    vector_registers = [0] * REGISTER_COUNT
    matrix_registers = [0] * REGISTER_COUNT

    vector_valid_mask = 0
    matrix_valid_mask = 0

    with output_path.open(
        "w",
        encoding="ascii",
    ) as vector_file:
        for cycle in cycles:
            (
                clear,

                vector_write_enable,
                vector_write_address,
                vector_lane_enable,
                vector_write_data,
                vector_read_a,
                vector_read_b,

                matrix_write_enable,
                matrix_write_address,
                matrix_lane_enable,
                matrix_write_data,
                matrix_read_a,
                matrix_read_b,
            ) = cycle

            vector_valid_mask = update_bank(
                vector_registers,
                vector_valid_mask,
                clear,
                vector_write_enable,
                vector_write_address,
                vector_lane_enable,
                vector_write_data,
            )

            matrix_valid_mask = update_bank(
                matrix_registers,
                matrix_valid_mask,
                clear,
                matrix_write_enable,
                matrix_write_address,
                matrix_lane_enable,
                matrix_write_data,
            )

            vector_data_a, vector_valid_a = read_bank(
                vector_registers,
                vector_valid_mask,
                vector_read_a,
            )

            vector_data_b, vector_valid_b = read_bank(
                vector_registers,
                vector_valid_mask,
                vector_read_b,
            )

            matrix_data_a, matrix_valid_a = read_bank(
                matrix_registers,
                matrix_valid_mask,
                matrix_read_a,
            )

            matrix_data_b, matrix_valid_b = read_bank(
                matrix_registers,
                matrix_valid_mask,
                matrix_read_b,
            )

            vector_file.write(
                f"{clear:01x} "

                f"{vector_write_enable:01x} "
                f"{vector_write_address:01x} "
                f"{vector_lane_enable:02x} "
                f"{vector_write_data:064x} "
                f"{vector_read_a:01x} "
                f"{vector_read_b:01x} "

                f"{matrix_write_enable:01x} "
                f"{matrix_write_address:01x} "
                f"{matrix_lane_enable:02x} "
                f"{matrix_write_data:064x} "
                f"{matrix_read_a:01x} "
                f"{matrix_read_b:01x} "

                f"{vector_data_a:064x} "
                f"{vector_valid_a:01x} "
                f"{vector_data_b:064x} "
                f"{vector_valid_b:01x} "
                f"{vector_valid_mask:04x} "

                f"{matrix_data_a:064x} "
                f"{matrix_valid_a:01x} "
                f"{matrix_data_b:064x} "
                f"{matrix_valid_b:01x} "
                f"{matrix_valid_mask:04x}\n"
            )

    print(
        f"Generated {len(cycles)} register-bank cycles: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
