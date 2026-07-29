#!/usr/bin/env python3

from pathlib import Path


DOT4_MAC_OPCODE = 0x4
INT8X4_PRECISION = 0x0

ERROR_NONE = 0x0
ERROR_UNSUPPORTED_OPCODE = 0x1
ERROR_UNSUPPORTED_PRECISION = 0x2
ERROR_INVALID_OPERAND = 0x3


def decode(
    flush: int,
    cmd_valid: int,
    opcode: int,
    precision: int,
    operand_valid: int,
    execute_ready: int,
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
            execute_ready
            if command_executable
            else True
        )
    )

    cmd_accept = int(
        cmd_valid
        and cmd_ready
    )

    execute_valid = int(
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
        execute_valid,
        cmd_accept,
        cmd_error,
        error_code,
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent

    output_path = (
        root
        / "build"
        / "int8_command_decoder_vectors.txt"
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    test_count = 0

    with output_path.open("w", encoding="ascii") as vector_file:
        for flush in range(2):
            for cmd_valid in range(2):
                for opcode in range(16):
                    for precision in range(4):
                        for operand_valid in range(2):
                            for execute_ready in range(2):
                                expected = decode(
                                    flush,
                                    cmd_valid,
                                    opcode,
                                    precision,
                                    operand_valid,
                                    execute_ready,
                                )

                                vector_file.write(
                                    f"{flush:01x} "
                                    f"{cmd_valid:01x} "
                                    f"{opcode:01x} "
                                    f"{precision:01x} "
                                    f"{operand_valid:01x} "
                                    f"{execute_ready:01x} "
                                    f"{expected[0]:01x} "
                                    f"{expected[1]:01x} "
                                    f"{expected[2]:01x} "
                                    f"{expected[3]:01x} "
                                    f"{expected[4]:01x}\n"
                                )

                                test_count += 1

    print(
        f"Generated {test_count} exhaustive decoder vectors: "
        f"{output_path}"
    )


if __name__ == "__main__":
    main()
