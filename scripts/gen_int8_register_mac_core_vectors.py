#!/usr/bin/env python3

import random
from pathlib import Path

from gen_fp32_add_vectors import resolve
from gen_int8_mac_lane_vectors import dot4, integer_to_fp32_bits


REGISTER_COUNT = 16
LANE_COUNT = 8
LANE_WIDTH = 32
REGISTER_WIDTH = 256

REGISTER_MASK = (1 << REGISTER_WIDTH) - 1


def pack_lanes(words: list[int]) -> int:
    packed = 0

    for lane, word in enumerate(words):
        packed |= (
            (word & 0xFFFFFFFF)
            << (lane * LANE_WIDTH)
        )

    return packed


def unpack_lanes(value: int) -> list[int]:
    return [
        (
            value >> (lane * LANE_WIDTH)
        ) & 0xFFFFFFFF
        for lane in range(LANE_COUNT)
    ]


def merge_lanes(
    old_data: int,
    new_data: int,
    lane_enable: int,
) -> int:
    result = old_data

    for lane in range(LANE_COUNT):
        if (lane_enable >> lane) & 1:
            lane_mask = (
                0xFFFFFFFF
                << (lane * LANE_WIDTH)
            )

            result = (
                (result & ~lane_mask)
                | (new_data & lane_mask)
            )

    return result & REGISTER_MASK


def preview_read(
    registers: list[int],
    valid_mask: int,
    clear: int,
    write_enable: int,
    write_address: int,
    lane_enable: int,
    write_data: int,
    read_address: int,
) -> tuple[int, int]:
    if clear:
        return 0, 0

    write_commit = (
        write_enable
        and lane_enable != 0
    )

    if (
        write_commit
        and write_address == read_address
    ):
        old_data = (
            registers[write_address]
            if (valid_mask >> write_address) & 1
            else 0
        )

        return (
            merge_lanes(
                old_data,
                write_data,
                lane_enable,
            ),
            1,
        )

    read_valid = (
        valid_mask >> read_address
    ) & 1

    read_data = (
        registers[read_address]
        if read_valid
        else 0
    )

    return read_data, read_valid


def commit_write(
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

    if write_enable and lane_enable != 0:
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


def main() -> None:
    root = Path(__file__).resolve().parent.parent

    output_path = (
        root
        / "build"
        / "int8_register_mac_core_vectors.txt"
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    vector_pattern = pack_lanes([
        0x01010101,
        0x02020202,
        0x03030303,
        0x04040404,
        0x05050505,
        0x06060606,
        0x07070707,
        0x08080808,
    ])

    matrix_pattern = pack_lanes([
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
    ])

    mixed_vector = pack_lanes([
        0x04030201,
        0xFCFDFEFF,
        0x7F7F7F7F,
        0x80808080,
        0x01020304,
        0xFFFFFFFF,
        0x12345678,
        0x89ABCDEF,
    ])

    mixed_matrix = pack_lanes([
        0x01010101,
        0x01010101,
        0x01010101,
        0x01010101,
        0x04030201,
        0xFFFFFFFF,
        0x87654321,
        0x10203040,
    ])

    zero_data = 0

    # Cycle format:
    #
    # register_clear, accumulator_clear,
    # vector_write_enable, vector_write_addr, vector_lane_mask, vector_data,
    # matrix_write_enable, matrix_write_addr, matrix_lane_mask, matrix_data,
    # exec_valid, vector_source_addr, matrix_source_addr
    directed_cycles = [
        # Invalid source registers.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 1, 2,
        ),

        # Same-cycle register loading and execution through forwarding.
        (
            0, 0,
            1, 1, 0xFF, vector_pattern,
            1, 2, 0xFF, matrix_pattern,
            1, 1, 2,
        ),

        # Execute the committed operands again.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 1, 2,
        ),

        # Load a second operand pair.
        (
            0, 0,
            1, 3, 0xFF, mixed_vector,
            1, 4, 0xFF, mixed_matrix,
            1, 3, 4,
        ),

        # Bubble.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            0, 3, 4,
        ),

        # Clear only accumulators; register contents remain valid.
        (
            0, 1,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 1, 2,
        ),

        # Execute after accumulator clear.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 1, 2,
        ),

        # Clear only architectural registers.
        (
            1, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 1, 2,
        ),

        # Sources are now invalid.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 1, 2,
        ),
    ]

    rng = random.Random(0x4E43455245474D41)

    random_cycles = []

    for cycle_index in range(20_000):
        register_clear = int(
            cycle_index != 0
            and cycle_index % 2_500 == 0
        )

        accumulator_clear = int(
            cycle_index != 0
            and cycle_index % 1_000 == 0
        )

        vector_write_enable = int(
            rng.random() < 0.48
        )

        matrix_write_enable = int(
            rng.random() < 0.48
        )

        vector_write_addr = rng.randrange(
            REGISTER_COUNT
        )

        matrix_write_addr = rng.randrange(
            REGISTER_COUNT
        )

        vector_lane_mask = (
            0
            if rng.random() < 0.04
            else rng.randrange(1, 256)
        )

        matrix_lane_mask = (
            0
            if rng.random() < 0.04
            else rng.randrange(1, 256)
        )

        vector_write_data = rng.getrandbits(
            REGISTER_WIDTH
        )

        matrix_write_data = rng.getrandbits(
            REGISTER_WIDTH
        )

        exec_valid = int(rng.random() < 0.75)

        vector_source_addr = rng.randrange(
            REGISTER_COUNT
        )

        matrix_source_addr = rng.randrange(
            REGISTER_COUNT
        )

        # Frequently execute newly written operands in the same cycle.
        if vector_write_enable and rng.random() < 0.35:
            vector_source_addr = vector_write_addr

        if matrix_write_enable and rng.random() < 0.35:
            matrix_source_addr = matrix_write_addr

        random_cycles.append((
            register_clear,
            accumulator_clear,

            vector_write_enable,
            vector_write_addr,
            vector_lane_mask,
            vector_write_data,

            matrix_write_enable,
            matrix_write_addr,
            matrix_lane_mask,
            matrix_write_data,

            exec_valid,
            vector_source_addr,
            matrix_source_addr,
        ))

    # Flush the final SIMD pipeline entry.
    random_cycles.extend([
        (
            0, 0,
            0, 0, 0x00, 0,
            0, 0, 0x00, 0,
            0, 0, 0,
        ),
        (
            0, 0,
            0, 0, 0x00, 0,
            0, 0, 0x00, 0,
            0, 0, 0,
        ),
    ])

    cycles = directed_cycles + random_cycles

    vector_registers = [0] * REGISTER_COUNT
    matrix_registers = [0] * REGISTER_COUNT

    vector_valid_mask = 0
    matrix_valid_mask = 0

    stage_valid = 0
    stage_values = [0] * LANE_COUNT

    accumulators = [0] * LANE_COUNT
    accumulator_valid = 0

    lane_invalid = [0] * LANE_COUNT
    lane_overflow = [0] * LANE_COUNT
    lane_underflow = [0] * LANE_COUNT
    lane_inexact = [0] * LANE_COUNT

    with output_path.open(
        "w",
        encoding="ascii",
    ) as vector_file:
        for cycle in cycles:
            (
                register_clear,
                accumulator_clear,

                vector_write_enable,
                vector_write_addr,
                vector_lane_mask,
                vector_write_data,

                matrix_write_enable,
                matrix_write_addr,
                matrix_lane_mask,
                matrix_write_data,

                exec_valid,
                vector_source_addr,
                matrix_source_addr,
            ) = cycle

            vector_operand, vector_operand_valid = preview_read(
                vector_registers,
                vector_valid_mask,
                register_clear,
                vector_write_enable,
                vector_write_addr,
                vector_lane_mask,
                vector_write_data,
                vector_source_addr,
            )

            matrix_operand, matrix_operand_valid = preview_read(
                matrix_registers,
                matrix_valid_mask,
                register_clear,
                matrix_write_enable,
                matrix_write_addr,
                matrix_lane_mask,
                matrix_write_data,
                matrix_source_addr,
            )

            operand_valid = int(
                vector_operand_valid
                and matrix_operand_valid
            )

            simd_ready = int(
                not accumulator_clear
            )

            exec_ready = int(
                simd_ready
                and operand_valid
                and not register_clear
                and not accumulator_clear
            )

            operand_error = int(
                exec_valid
                and not operand_valid
                and not register_clear
            )

            transaction_accepted = int(
                exec_valid
                and exec_ready
            )

            old_stage_valid = stage_valid
            old_stage_values = list(stage_values)

            if accumulator_clear:
                stage_valid = 0
                stage_values = [0] * LANE_COUNT

                accumulators = [0] * LANE_COUNT
                accumulator_valid = 0

                lane_invalid = [0] * LANE_COUNT
                lane_overflow = [0] * LANE_COUNT
                lane_underflow = [0] * LANE_COUNT
                lane_inexact = [0] * LANE_COUNT

                accumulator_update = 0
            else:
                accumulator_update = old_stage_valid

                if old_stage_valid:
                    for lane in range(LANE_COUNT):
                        (
                            result,
                            invalid,
                            overflow,
                            underflow,
                            inexact,
                        ) = resolve(
                            accumulators[lane],
                            old_stage_values[lane],
                        )

                        accumulators[lane] = result
                        accumulator_valid = 1

                        lane_invalid[lane] |= invalid
                        lane_overflow[lane] |= overflow
                        lane_underflow[lane] |= underflow
                        lane_inexact[lane] |= inexact

                if transaction_accepted:
                    vector_words = unpack_lanes(
                        vector_operand
                    )

                    matrix_words = unpack_lanes(
                        matrix_operand
                    )

                    stage_values = [
                        integer_to_fp32_bits(
                            dot4(
                                vector_words[lane],
                                matrix_words[lane],
                            )
                        )
                        for lane in range(LANE_COUNT)
                    ]

                    stage_valid = 1
                else:
                    stage_values = [0] * LANE_COUNT
                    stage_valid = 0

            vector_valid_mask = commit_write(
                vector_registers,
                vector_valid_mask,
                register_clear,
                vector_write_enable,
                vector_write_addr,
                vector_lane_mask,
                vector_write_data,
            )

            matrix_valid_mask = commit_write(
                matrix_registers,
                matrix_valid_mask,
                register_clear,
                matrix_write_enable,
                matrix_write_addr,
                matrix_lane_mask,
                matrix_write_data,
            )

            accumulator_packed = pack_lanes(
                accumulators
            )

            invalid_mask = sum(
                lane_invalid[lane] << lane
                for lane in range(LANE_COUNT)
            )

            overflow_mask = sum(
                lane_overflow[lane] << lane
                for lane in range(LANE_COUNT)
            )

            underflow_mask = sum(
                lane_underflow[lane] << lane
                for lane in range(LANE_COUNT)
            )

            inexact_mask = sum(
                lane_inexact[lane] << lane
                for lane in range(LANE_COUNT)
            )

            vector_file.write(
                f"{register_clear:01x} "
                f"{accumulator_clear:01x} "

                f"{vector_write_enable:01x} "
                f"{vector_write_addr:01x} "
                f"{vector_lane_mask:02x} "
                f"{vector_write_data:064x} "

                f"{matrix_write_enable:01x} "
                f"{matrix_write_addr:01x} "
                f"{matrix_lane_mask:02x} "
                f"{matrix_write_data:064x} "

                f"{exec_valid:01x} "
                f"{vector_source_addr:01x} "
                f"{matrix_source_addr:01x} "

                f"{exec_ready:01x} "
                f"{operand_valid:01x} "
                f"{operand_error:01x} "

                f"{accumulator_packed:064x} "
                f"{accumulator_valid:01x} "
                f"{accumulator_update:01x} "

                f"{invalid_mask:02x} "
                f"{overflow_mask:02x} "
                f"{underflow_mask:02x} "
                f"{inexact_mask:02x} "

                f"{int(bool(invalid_mask)):01x} "
                f"{int(bool(overflow_mask)):01x} "
                f"{int(bool(underflow_mask)):01x} "
                f"{int(bool(inexact_mask)):01x} "

                f"{vector_valid_mask:04x} "
                f"{matrix_valid_mask:04x}\n"
            )

    print(
        f"Generated {len(cycles)} execution-core cycles: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
