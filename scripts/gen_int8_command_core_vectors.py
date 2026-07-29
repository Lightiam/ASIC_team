#!/usr/bin/env python3

import random
from pathlib import Path

from gen_fp32_add_vectors import resolve
from gen_int8_mac_lane_vectors import dot4, integer_to_fp32_bits
from gen_int8_register_mac_core_vectors import (
    commit_write,
    pack_lanes,
    preview_read,
    unpack_lanes,
)


REGISTER_COUNT = 16
LANE_COUNT = 8
REGISTER_WIDTH = 256

DOT4_MAC_OPCODE = 0x4
INT8X4_PRECISION = 0x0

ERROR_NONE = 0x0
ERROR_UNSUPPORTED_OPCODE = 0x1
ERROR_UNSUPPORTED_PRECISION = 0x2
ERROR_INVALID_OPERAND = 0x3


def decode_command(
    flush: int,
    cmd_valid: int,
    opcode: int,
    precision: int,
    operand_valid: int,
    execution_ready: int,
) -> tuple[int, int, int, int, int]:
    opcode_supported = opcode == DOT4_MAC_OPCODE
    precision_supported = precision == INT8X4_PRECISION

    command_supported = (
        opcode_supported
        and precision_supported
    )

    command_executable = (
        command_supported
        and bool(operand_valid)
    )

    cmd_ready = int(
        not flush
        and (
            execution_ready
            if command_executable
            else True
        )
    )

    cmd_accept = int(
        cmd_valid
        and cmd_ready
    )

    execute_issue = int(
        cmd_accept
        and command_executable
    )

    cmd_error = int(
        cmd_accept
        and not command_executable
    )

    if not cmd_error:
        error_code = ERROR_NONE
    elif not opcode_supported:
        error_code = ERROR_UNSUPPORTED_OPCODE
    elif not precision_supported:
        error_code = ERROR_UNSUPPORTED_PRECISION
    else:
        error_code = ERROR_INVALID_OPERAND

    return (
        cmd_ready,
        cmd_accept,
        execute_issue,
        cmd_error,
        error_code,
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    output_path = root / "build" / "int8_command_core_vectors.txt"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    zero_data = 0

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

    # register_clear, accumulator_clear,
    # vector write fields,
    # matrix write fields,
    # command valid/opcode/precision/vector source/matrix source
    directed_cycles = [
        # Supported command with invalid operands.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x0, 1, 2,
        ),

        # Unsupported opcode.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x1, 0x0, 1, 2,
        ),

        # Unsupported precision.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x1, 1, 2,
        ),

        # Same-cycle write-through and execution.
        (
            0, 0,
            1, 1, 0xFF, vector_pattern,
            1, 2, 0xFF, matrix_pattern,
            1, 0x4, 0x0, 1, 2,
        ),

        # Execute committed operands.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x0, 1, 2,
        ),

        # Bubble to allow accumulator update.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            0, 0x4, 0x0, 1, 2,
        ),

        # Accumulator clear rejects command during the clear cycle.
        (
            0, 1,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x0, 1, 2,
        ),

        # Execute again after accumulator clear.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x0, 1, 2,
        ),

        # Register clear rejects command.
        (
            1, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x0, 1, 2,
        ),

        # Operands are invalid after register clear.
        (
            0, 0,
            0, 0, 0x00, zero_data,
            0, 0, 0x00, zero_data,
            1, 0x4, 0x0, 1, 2,
        ),
    ]

    rng = random.Random(0x4E4345434D44434F)

    random_cycles = []

    for cycle_index in range(15_000):
        register_clear = int(
            cycle_index != 0
            and cycle_index % 2_500 == 0
        )

        accumulator_clear = int(
            cycle_index != 0
            and cycle_index % 1_000 == 0
        )

        vector_write_enable = int(rng.random() < 0.48)
        matrix_write_enable = int(rng.random() < 0.48)

        vector_write_addr = rng.randrange(REGISTER_COUNT)
        matrix_write_addr = rng.randrange(REGISTER_COUNT)

        vector_lane_mask = (
            0 if rng.random() < 0.04
            else rng.randrange(1, 256)
        )

        matrix_lane_mask = (
            0 if rng.random() < 0.04
            else rng.randrange(1, 256)
        )

        vector_write_data = rng.getrandbits(REGISTER_WIDTH)
        matrix_write_data = rng.getrandbits(REGISTER_WIDTH)

        cmd_valid = int(rng.random() < 0.78)

        selector = rng.random()

        if selector < 0.65:
            opcode = DOT4_MAC_OPCODE
            precision = INT8X4_PRECISION
        elif selector < 0.82:
            opcode = rng.choice([
                value
                for value in range(16)
                if value != DOT4_MAC_OPCODE
            ])
            precision = INT8X4_PRECISION
        else:
            opcode = DOT4_MAC_OPCODE
            precision = rng.randrange(1, 4)

        vector_source = rng.randrange(REGISTER_COUNT)
        matrix_source = rng.randrange(REGISTER_COUNT)

        if vector_write_enable and rng.random() < 0.35:
            vector_source = vector_write_addr

        if matrix_write_enable and rng.random() < 0.35:
            matrix_source = matrix_write_addr

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

            cmd_valid,
            opcode,
            precision,
            vector_source,
            matrix_source,
        ))

    # Flush the final pipeline entry.
    random_cycles.extend([
        (
            0, 0,
            0, 0, 0x00, 0,
            0, 0, 0x00, 0,
            0, 0x4, 0x0, 0, 0,
        ),
        (
            0, 0,
            0, 0, 0x00, 0,
            0, 0, 0x00, 0,
            0, 0x4, 0x0, 0, 0,
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

    with output_path.open("w", encoding="ascii") as vector_file:
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

                cmd_valid,
                opcode,
                precision,
                vector_source,
                matrix_source,
            ) = cycle

            vector_operand, vector_operand_valid = preview_read(
                vector_registers,
                vector_valid_mask,
                register_clear,
                vector_write_enable,
                vector_write_addr,
                vector_lane_mask,
                vector_write_data,
                vector_source,
            )

            matrix_operand, matrix_operand_valid = preview_read(
                matrix_registers,
                matrix_valid_mask,
                register_clear,
                matrix_write_enable,
                matrix_write_addr,
                matrix_lane_mask,
                matrix_write_data,
                matrix_source,
            )

            operand_valid = int(
                vector_operand_valid
                and matrix_operand_valid
            )

            execution_ready = int(
                operand_valid
                and not register_clear
                and not accumulator_clear
            )

            flush = int(
                register_clear
                or accumulator_clear
            )

            (
                cmd_ready,
                cmd_accept,
                execute_issue,
                cmd_error,
                cmd_error_code,
            ) = decode_command(
                flush,
                cmd_valid,
                opcode,
                precision,
                operand_valid,
                execution_ready,
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

                if execute_issue:
                    vector_words = unpack_lanes(vector_operand)
                    matrix_words = unpack_lanes(matrix_operand)

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
                    stage_valid = 0
                    stage_values = [0] * LANE_COUNT

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

            accumulator_packed = pack_lanes(accumulators)

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

                f"{cmd_valid:01x} "
                f"{opcode:01x} "
                f"{precision:01x} "
                f"{vector_source:01x} "
                f"{matrix_source:01x} "

                f"{cmd_ready:01x} "
                f"{cmd_accept:01x} "
                f"{cmd_error:01x} "
                f"{cmd_error_code:01x} "
                f"{execute_issue:01x} "
                f"{operand_valid:01x} "

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
        f"Generated {len(cycles)} command-core cycles: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
