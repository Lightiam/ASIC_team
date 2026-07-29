// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// NCE AXI4-Lite CSR backend.
//
// The backend accepts one 32-bit read or write request from the AXI frontend.
//
// 256-bit architectural register writes use eight 32-bit staging words.
// A commit operation transfers selected staged lanes atomically into the
// vector or matrix register bank.
//
// Address map:
//
//   0x000  DEVICE_ID             R
//   0x004  VERSION               R
//   0x008  CONTROL               W
//          bit 0: clear architectural registers
//          bit 1: clear FP32 accumulators
//          bit 2: clear vector/matrix staging-valid masks
//          bit 3: clear command statistics
//
//   0x00C  STATUS                R
//   0x010  COMMAND               W
//   0x014  COMMAND_COUNT         R
//   0x018  COMMAND_ERROR_COUNT   R
//   0x01C  EXECUTE_COUNT         R
//   0x020  LAST_COMMAND          R
//   0x024  LAST_ERROR            R
//
//   0x040  VECTOR_CONFIG         RW
//          bits 3:0:  destination address
//          bits 15:8: lane-enable mask
//   0x044  VECTOR_STAGE_VALID    R
//   0x060–0x07C VECTOR_DATA[0:7] RW
//   0x080  VECTOR_COMMIT         W
//
//   0x0A0  MATRIX_CONFIG         RW
//   0x0A4  MATRIX_STAGE_VALID    R
//   0x0C0–0x0DC MATRIX_DATA[0:7] RW
//   0x0E0  MATRIX_COMMIT         W
//
//   0x100–0x11C ACCUMULATOR[0:7] R
//   0x120  VECTOR_VALID_MASK     R
//   0x124  MATRIX_VALID_MASK     R
//   0x128  LANE_INVALID          R
//   0x12C  LANE_OVERFLOW         R
//   0x130  LANE_UNDERFLOW        R
//   0x134  LANE_INEXACT          R
//   0x138  GLOBAL_FLAGS          R
//
// COMMAND format:
//
//   bits  3:0  opcode
//   bits  5:4  precision
//   bits 11:8  vector source register
//   bits 15:12 matrix source register
// -----------------------------------------------------------------------------

module nce_axi_csr_backend (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Backend write request
    input  logic         write_valid_i,
    output logic         write_ready_o,
    input  logic [31:0]  write_addr_i,
    input  logic [31:0]  write_data_i,
    input  logic [3:0]   write_strb_i,
    output logic         write_error_o,

    // Backend read request
    input  logic         read_valid_i,
    output logic         read_ready_o,
    input  logic [31:0]  read_addr_i,
    output logic [31:0]  read_data_o,
    output logic         read_error_o,

    // Clear controls
    output logic         register_clear_o,
    output logic         accumulator_clear_o,

    // Vector register-bank write interface
    output logic         vector_write_enable_o,
    output logic [3:0]   vector_write_addr_o,
    output logic [7:0]   vector_write_lane_enable_o,
    output logic [255:0] vector_write_data_o,

    // Matrix register-bank write interface
    output logic         matrix_write_enable_o,
    output logic [3:0]   matrix_write_addr_o,
    output logic [7:0]   matrix_write_lane_enable_o,
    output logic [255:0] matrix_write_data_o,

    // Command interface
    output logic         cmd_valid_o,
    input  logic         cmd_ready_i,

    output logic [3:0]   cmd_opcode_o,
    output logic [1:0]   cmd_precision_o,
    output logic [3:0]   cmd_vector_source_addr_o,
    output logic [3:0]   cmd_matrix_source_addr_o,

    input  logic         cmd_accept_i,
    input  logic         cmd_error_i,
    input  logic [1:0]   cmd_error_code_i,
    input  logic         execute_issue_i,
    input  logic         operand_valid_i,

    // Execution results and status
    input  logic [255:0] accumulator_i,
    input  logic         accumulator_valid_i,
    input  logic         accumulator_update_i,

    input  logic [7:0]   lane_invalid_i,
    input  logic [7:0]   lane_overflow_i,
    input  logic [7:0]   lane_underflow_i,
    input  logic [7:0]   lane_inexact_i,

    input  logic         invalid_i,
    input  logic         overflow_i,
    input  logic         underflow_i,
    input  logic         inexact_i,

    input  logic [15:0]  vector_valid_mask_i,
    input  logic [15:0]  matrix_valid_mask_i
);

    localparam logic [31:0] DEVICE_ID_VALUE = 32'h4E43_4530;
    localparam logic [31:0] VERSION_VALUE   = 32'h0001_0000;

    localparam logic [31:0] ADDR_DEVICE_ID           = 32'h0000_0000;
    localparam logic [31:0] ADDR_VERSION             = 32'h0000_0004;
    localparam logic [31:0] ADDR_CONTROL             = 32'h0000_0008;
    localparam logic [31:0] ADDR_STATUS              = 32'h0000_000C;
    localparam logic [31:0] ADDR_COMMAND             = 32'h0000_0010;
    localparam logic [31:0] ADDR_COMMAND_COUNT       = 32'h0000_0014;
    localparam logic [31:0] ADDR_COMMAND_ERROR_COUNT = 32'h0000_0018;
    localparam logic [31:0] ADDR_EXECUTE_COUNT       = 32'h0000_001C;
    localparam logic [31:0] ADDR_LAST_COMMAND        = 32'h0000_0020;
    localparam logic [31:0] ADDR_LAST_ERROR          = 32'h0000_0024;

    localparam logic [31:0] ADDR_VECTOR_CONFIG       = 32'h0000_0040;
    localparam logic [31:0] ADDR_VECTOR_STAGE_VALID  = 32'h0000_0044;

    localparam logic [31:0] ADDR_VECTOR_DATA0        = 32'h0000_0060;
    localparam logic [31:0] ADDR_VECTOR_DATA1        = 32'h0000_0064;
    localparam logic [31:0] ADDR_VECTOR_DATA2        = 32'h0000_0068;
    localparam logic [31:0] ADDR_VECTOR_DATA3        = 32'h0000_006C;
    localparam logic [31:0] ADDR_VECTOR_DATA4        = 32'h0000_0070;
    localparam logic [31:0] ADDR_VECTOR_DATA5        = 32'h0000_0074;
    localparam logic [31:0] ADDR_VECTOR_DATA6        = 32'h0000_0078;
    localparam logic [31:0] ADDR_VECTOR_DATA7        = 32'h0000_007C;
    localparam logic [31:0] ADDR_VECTOR_COMMIT       = 32'h0000_0080;

    localparam logic [31:0] ADDR_MATRIX_CONFIG       = 32'h0000_00A0;
    localparam logic [31:0] ADDR_MATRIX_STAGE_VALID  = 32'h0000_00A4;

    localparam logic [31:0] ADDR_MATRIX_DATA0        = 32'h0000_00C0;
    localparam logic [31:0] ADDR_MATRIX_DATA1        = 32'h0000_00C4;
    localparam logic [31:0] ADDR_MATRIX_DATA2        = 32'h0000_00C8;
    localparam logic [31:0] ADDR_MATRIX_DATA3        = 32'h0000_00CC;
    localparam logic [31:0] ADDR_MATRIX_DATA4        = 32'h0000_00D0;
    localparam logic [31:0] ADDR_MATRIX_DATA5        = 32'h0000_00D4;
    localparam logic [31:0] ADDR_MATRIX_DATA6        = 32'h0000_00D8;
    localparam logic [31:0] ADDR_MATRIX_DATA7        = 32'h0000_00DC;
    localparam logic [31:0] ADDR_MATRIX_COMMIT       = 32'h0000_00E0;

    localparam logic [31:0] ADDR_ACCUMULATOR0        = 32'h0000_0100;
    localparam logic [31:0] ADDR_ACCUMULATOR1        = 32'h0000_0104;
    localparam logic [31:0] ADDR_ACCUMULATOR2        = 32'h0000_0108;
    localparam logic [31:0] ADDR_ACCUMULATOR3        = 32'h0000_010C;
    localparam logic [31:0] ADDR_ACCUMULATOR4        = 32'h0000_0110;
    localparam logic [31:0] ADDR_ACCUMULATOR5        = 32'h0000_0114;
    localparam logic [31:0] ADDR_ACCUMULATOR6        = 32'h0000_0118;
    localparam logic [31:0] ADDR_ACCUMULATOR7        = 32'h0000_011C;

    localparam logic [31:0] ADDR_VECTOR_VALID_MASK   = 32'h0000_0120;
    localparam logic [31:0] ADDR_MATRIX_VALID_MASK   = 32'h0000_0124;
    localparam logic [31:0] ADDR_LANE_INVALID        = 32'h0000_0128;
    localparam logic [31:0] ADDR_LANE_OVERFLOW       = 32'h0000_012C;
    localparam logic [31:0] ADDR_LANE_UNDERFLOW      = 32'h0000_0130;
    localparam logic [31:0] ADDR_LANE_INEXACT        = 32'h0000_0134;
    localparam logic [31:0] ADDR_GLOBAL_FLAGS        = 32'h0000_0138;

    logic [3:0]   vector_destination_q;
    logic [7:0]   vector_lane_mask_q;
    logic [255:0] vector_stage_data_q;
    logic [7:0]   vector_stage_valid_q;

    logic [3:0]   matrix_destination_q;
    logic [7:0]   matrix_lane_mask_q;
    logic [255:0] matrix_stage_data_q;
    logic [7:0]   matrix_stage_valid_q;

    logic [31:0] command_count_q;
    logic [31:0] command_error_count_q;
    logic [31:0] execute_count_q;
    logic [31:0] last_command_q;
    logic        last_command_error_q;
    logic [1:0]  last_command_error_code_q;

    logic write_fire;
    logic full_write_strobe;

    logic [3:0] control_write_value;

    logic vector_commit_complete;
    logic matrix_commit_complete;

    logic clear_stage_valid;
    logic clear_statistics;

    function automatic logic [31:0] apply_write_strobes (
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strobes
    );

        integer byte_index;

        begin
            apply_write_strobes = old_value;

            for (
                byte_index = 0;
                byte_index < 4;
                byte_index = byte_index + 1
            ) begin
                if (strobes[byte_index]) begin
                    apply_write_strobes[
                        (byte_index * 8) +: 8
                    ] = new_value[
                        (byte_index * 8) +: 8
                    ];
                end
            end
        end
    endfunction

    assign full_write_strobe =
        (write_strb_i == 4'b1111);

    assign write_fire =
        write_valid_i &&
        write_ready_o;

    assign control_write_value =
        write_strb_i[0]
        ? write_data_i[3:0]
        : 4'd0;

    assign vector_commit_complete =
        (vector_lane_mask_q != 8'd0) &&
        (
            (
                vector_stage_valid_q &
                vector_lane_mask_q
            )
            ==
            vector_lane_mask_q
        );

    assign matrix_commit_complete =
        (matrix_lane_mask_q != 8'd0) &&
        (
            (
                matrix_stage_valid_q &
                matrix_lane_mask_q
            )
            ==
            matrix_lane_mask_q
        );

    assign cmd_valid_o =
        rst_ni &&
        write_valid_i &&
        (write_addr_i == ADDR_COMMAND) &&
        full_write_strobe;

    assign cmd_opcode_o =
        write_data_i[3:0];

    assign cmd_precision_o =
        write_data_i[5:4];

    assign cmd_vector_source_addr_o =
        write_data_i[11:8];

    assign cmd_matrix_source_addr_o =
        write_data_i[15:12];

    // Register the clear controls as one-cycle pulses.
    //
    // This removes a combinational path from write_ready_o through the
    // command decoder and back into write_ready_o.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            register_clear_o    <= 1'b0;
            accumulator_clear_o <= 1'b0;
        end
        else begin
            register_clear_o    <= 1'b0;
            accumulator_clear_o <= 1'b0;

            if (
                write_fire &&
                !write_error_o &&
                (write_addr_i == ADDR_CONTROL)
            ) begin
                register_clear_o <=
                    control_write_value[0];

                accumulator_clear_o <=
                    control_write_value[1];
            end
        end
    end

    assign clear_stage_valid =
        write_fire &&
        !write_error_o &&
        (write_addr_i == ADDR_CONTROL) &&
        control_write_value[2];

    assign clear_statistics =
        write_fire &&
        !write_error_o &&
        (write_addr_i == ADDR_CONTROL) &&
        control_write_value[3];

    // Register architectural register-bank commits as one-cycle pulses.
    // This breaks the combinational path from AXI write readiness through
    // register-file forwarding and back into command readiness.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            vector_write_enable_o      <= 1'b0;
            vector_write_addr_o        <= 4'd0;
            vector_write_lane_enable_o <= 8'd0;
            vector_write_data_o        <= 256'd0;

            matrix_write_enable_o      <= 1'b0;
            matrix_write_addr_o        <= 4'd0;
            matrix_write_lane_enable_o <= 8'd0;
            matrix_write_data_o        <= 256'd0;
        end
        else begin
            vector_write_enable_o <= 1'b0;
            matrix_write_enable_o <= 1'b0;

            if (
                write_fire &&
                !write_error_o &&
                (write_addr_i == ADDR_VECTOR_COMMIT)
            ) begin
                vector_write_enable_o      <= 1'b1;
                vector_write_addr_o        <= vector_destination_q;
                vector_write_lane_enable_o <= vector_lane_mask_q;
                vector_write_data_o        <= vector_stage_data_q;
            end

            if (
                write_fire &&
                !write_error_o &&
                (write_addr_i == ADDR_MATRIX_COMMIT)
            ) begin
                matrix_write_enable_o      <= 1'b1;
                matrix_write_addr_o        <= matrix_destination_q;
                matrix_write_lane_enable_o <= matrix_lane_mask_q;
                matrix_write_data_o        <= matrix_stage_data_q;
            end
        end
    end

    always @* begin
        write_ready_o = rst_ni;
        write_error_o = 1'b0;

        if (write_addr_i[1:0] != 2'b00) begin
            write_error_o = 1'b1;
        end
        else begin
            case (write_addr_i)
                ADDR_CONTROL,
                ADDR_VECTOR_CONFIG,
                ADDR_VECTOR_DATA0,
                ADDR_VECTOR_DATA1,
                ADDR_VECTOR_DATA2,
                ADDR_VECTOR_DATA3,
                ADDR_VECTOR_DATA4,
                ADDR_VECTOR_DATA5,
                ADDR_VECTOR_DATA6,
                ADDR_VECTOR_DATA7,
                ADDR_MATRIX_CONFIG,
                ADDR_MATRIX_DATA0,
                ADDR_MATRIX_DATA1,
                ADDR_MATRIX_DATA2,
                ADDR_MATRIX_DATA3,
                ADDR_MATRIX_DATA4,
                ADDR_MATRIX_DATA5,
                ADDR_MATRIX_DATA6,
                ADDR_MATRIX_DATA7: begin
                    write_error_o = 1'b0;
                end

                ADDR_COMMAND: begin
                    if (!full_write_strobe) begin
                        write_error_o = 1'b1;
                    end
                    else begin
                        write_ready_o = rst_ni && cmd_ready_i;
                        write_error_o = cmd_error_i;
                    end
                end

                ADDR_VECTOR_COMMIT: begin
                    write_error_o =
                        !full_write_strobe ||
                        !write_data_i[0] ||
                        !vector_commit_complete;
                end

                ADDR_MATRIX_COMMIT: begin
                    write_error_o =
                        !full_write_strobe ||
                        !write_data_i[0] ||
                        !matrix_commit_complete;
                end

                default: begin
                    write_error_o = 1'b1;
                end
            endcase
        end
    end

    assign read_ready_o =
        rst_ni;

    always @* begin
        read_data_o  = 32'd0;
        read_error_o = 1'b0;

        if (read_addr_i[1:0] != 2'b00) begin
            read_error_o = 1'b1;
        end
        else begin
            case (read_addr_i)
                ADDR_DEVICE_ID: begin
                    read_data_o = DEVICE_ID_VALUE;
                end

                ADDR_VERSION: begin
                    read_data_o = VERSION_VALUE;
                end

                ADDR_CONTROL: begin
                    read_data_o = 32'd0;
                end

                ADDR_STATUS: begin
                    read_data_o[0]    = cmd_ready_i;
                    read_data_o[1]    = operand_valid_i;
                    read_data_o[2]    = accumulator_valid_i;
                    read_data_o[3]    = accumulator_update_i;
                    read_data_o[4]    = invalid_i;
                    read_data_o[5]    = overflow_i;
                    read_data_o[6]    = underflow_i;
                    read_data_o[7]    = inexact_i;
                    read_data_o[8]    = last_command_error_q;
                    read_data_o[10:9] = last_command_error_code_q;
                    read_data_o[11]   = execute_issue_i;
                    read_data_o[12]   = cmd_accept_i;
                end

                ADDR_COMMAND_COUNT: begin
                    read_data_o = command_count_q;
                end

                ADDR_COMMAND_ERROR_COUNT: begin
                    read_data_o = command_error_count_q;
                end

                ADDR_EXECUTE_COUNT: begin
                    read_data_o = execute_count_q;
                end

                ADDR_LAST_COMMAND: begin
                    read_data_o = last_command_q;
                end

                ADDR_LAST_ERROR: begin
                    read_data_o[0]   = last_command_error_q;
                    read_data_o[2:1] = last_command_error_code_q;
                end

                ADDR_VECTOR_CONFIG: begin
                    read_data_o[3:0]  = vector_destination_q;
                    read_data_o[15:8] = vector_lane_mask_q;
                end

                ADDR_VECTOR_STAGE_VALID: begin
                    read_data_o[7:0] = vector_stage_valid_q;
                end

                ADDR_VECTOR_DATA0: read_data_o = vector_stage_data_q[31:0];
                ADDR_VECTOR_DATA1: read_data_o = vector_stage_data_q[63:32];
                ADDR_VECTOR_DATA2: read_data_o = vector_stage_data_q[95:64];
                ADDR_VECTOR_DATA3: read_data_o = vector_stage_data_q[127:96];
                ADDR_VECTOR_DATA4: read_data_o = vector_stage_data_q[159:128];
                ADDR_VECTOR_DATA5: read_data_o = vector_stage_data_q[191:160];
                ADDR_VECTOR_DATA6: read_data_o = vector_stage_data_q[223:192];
                ADDR_VECTOR_DATA7: read_data_o = vector_stage_data_q[255:224];

                ADDR_MATRIX_CONFIG: begin
                    read_data_o[3:0]  = matrix_destination_q;
                    read_data_o[15:8] = matrix_lane_mask_q;
                end

                ADDR_MATRIX_STAGE_VALID: begin
                    read_data_o[7:0] = matrix_stage_valid_q;
                end

                ADDR_MATRIX_DATA0: read_data_o = matrix_stage_data_q[31:0];
                ADDR_MATRIX_DATA1: read_data_o = matrix_stage_data_q[63:32];
                ADDR_MATRIX_DATA2: read_data_o = matrix_stage_data_q[95:64];
                ADDR_MATRIX_DATA3: read_data_o = matrix_stage_data_q[127:96];
                ADDR_MATRIX_DATA4: read_data_o = matrix_stage_data_q[159:128];
                ADDR_MATRIX_DATA5: read_data_o = matrix_stage_data_q[191:160];
                ADDR_MATRIX_DATA6: read_data_o = matrix_stage_data_q[223:192];
                ADDR_MATRIX_DATA7: read_data_o = matrix_stage_data_q[255:224];

                ADDR_ACCUMULATOR0: read_data_o = accumulator_i[31:0];
                ADDR_ACCUMULATOR1: read_data_o = accumulator_i[63:32];
                ADDR_ACCUMULATOR2: read_data_o = accumulator_i[95:64];
                ADDR_ACCUMULATOR3: read_data_o = accumulator_i[127:96];
                ADDR_ACCUMULATOR4: read_data_o = accumulator_i[159:128];
                ADDR_ACCUMULATOR5: read_data_o = accumulator_i[191:160];
                ADDR_ACCUMULATOR6: read_data_o = accumulator_i[223:192];
                ADDR_ACCUMULATOR7: read_data_o = accumulator_i[255:224];

                ADDR_VECTOR_VALID_MASK: begin
                    read_data_o[15:0] = vector_valid_mask_i;
                end

                ADDR_MATRIX_VALID_MASK: begin
                    read_data_o[15:0] = matrix_valid_mask_i;
                end

                ADDR_LANE_INVALID: begin
                    read_data_o[7:0] = lane_invalid_i;
                end

                ADDR_LANE_OVERFLOW: begin
                    read_data_o[7:0] = lane_overflow_i;
                end

                ADDR_LANE_UNDERFLOW: begin
                    read_data_o[7:0] = lane_underflow_i;
                end

                ADDR_LANE_INEXACT: begin
                    read_data_o[7:0] = lane_inexact_i;
                end

                ADDR_GLOBAL_FLAGS: begin
                    read_data_o[0] = invalid_i;
                    read_data_o[1] = overflow_i;
                    read_data_o[2] = underflow_i;
                    read_data_o[3] = inexact_i;
                end

                default: begin
                    read_data_o  = 32'd0;
                    read_error_o = 1'b1;
                end
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            vector_destination_q <= 4'd0;
            vector_lane_mask_q   <= 8'd0;
            vector_stage_data_q  <= 256'd0;
            vector_stage_valid_q <= 8'd0;

            matrix_destination_q <= 4'd0;
            matrix_lane_mask_q   <= 8'd0;
            matrix_stage_data_q  <= 256'd0;
            matrix_stage_valid_q <= 8'd0;

            command_count_q             <= 32'd0;
            command_error_count_q       <= 32'd0;
            execute_count_q             <= 32'd0;
            last_command_q              <= 32'd0;
            last_command_error_q        <= 1'b0;
            last_command_error_code_q   <= 2'd0;
        end
        else begin
            if (clear_stage_valid) begin
                vector_stage_valid_q <= 8'd0;
                matrix_stage_valid_q <= 8'd0;
            end
            else if (write_fire && !write_error_o) begin
                case (write_addr_i)
                    ADDR_VECTOR_CONFIG: begin
                        vector_destination_q <=
                            write_strb_i[0]
                            ? write_data_i[3:0]
                            : vector_destination_q;

                        vector_lane_mask_q <=
                            write_strb_i[1]
                            ? write_data_i[15:8]
                            : vector_lane_mask_q;
                    end

                    ADDR_VECTOR_DATA0: begin
                        vector_stage_data_q[31:0] <=
                            apply_write_strobes(
                                vector_stage_data_q[31:0],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[0] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA1: begin
                        vector_stage_data_q[63:32] <=
                            apply_write_strobes(
                                vector_stage_data_q[63:32],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[1] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA2: begin
                        vector_stage_data_q[95:64] <=
                            apply_write_strobes(
                                vector_stage_data_q[95:64],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[2] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA3: begin
                        vector_stage_data_q[127:96] <=
                            apply_write_strobes(
                                vector_stage_data_q[127:96],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[3] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA4: begin
                        vector_stage_data_q[159:128] <=
                            apply_write_strobes(
                                vector_stage_data_q[159:128],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[4] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA5: begin
                        vector_stage_data_q[191:160] <=
                            apply_write_strobes(
                                vector_stage_data_q[191:160],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[5] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA6: begin
                        vector_stage_data_q[223:192] <=
                            apply_write_strobes(
                                vector_stage_data_q[223:192],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[6] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_DATA7: begin
                        vector_stage_data_q[255:224] <=
                            apply_write_strobes(
                                vector_stage_data_q[255:224],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            vector_stage_valid_q[7] <= 1'b1;
                        end
                    end

                    ADDR_VECTOR_COMMIT: begin
                        vector_stage_valid_q <=
                            vector_stage_valid_q &
                            ~vector_lane_mask_q;
                    end

                    ADDR_MATRIX_CONFIG: begin
                        matrix_destination_q <=
                            write_strb_i[0]
                            ? write_data_i[3:0]
                            : matrix_destination_q;

                        matrix_lane_mask_q <=
                            write_strb_i[1]
                            ? write_data_i[15:8]
                            : matrix_lane_mask_q;
                    end

                    ADDR_MATRIX_DATA0: begin
                        matrix_stage_data_q[31:0] <=
                            apply_write_strobes(
                                matrix_stage_data_q[31:0],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[0] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA1: begin
                        matrix_stage_data_q[63:32] <=
                            apply_write_strobes(
                                matrix_stage_data_q[63:32],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[1] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA2: begin
                        matrix_stage_data_q[95:64] <=
                            apply_write_strobes(
                                matrix_stage_data_q[95:64],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[2] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA3: begin
                        matrix_stage_data_q[127:96] <=
                            apply_write_strobes(
                                matrix_stage_data_q[127:96],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[3] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA4: begin
                        matrix_stage_data_q[159:128] <=
                            apply_write_strobes(
                                matrix_stage_data_q[159:128],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[4] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA5: begin
                        matrix_stage_data_q[191:160] <=
                            apply_write_strobes(
                                matrix_stage_data_q[191:160],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[5] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA6: begin
                        matrix_stage_data_q[223:192] <=
                            apply_write_strobes(
                                matrix_stage_data_q[223:192],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[6] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_DATA7: begin
                        matrix_stage_data_q[255:224] <=
                            apply_write_strobes(
                                matrix_stage_data_q[255:224],
                                write_data_i,
                                write_strb_i
                            );

                        if (|write_strb_i) begin
                            matrix_stage_valid_q[7] <= 1'b1;
                        end
                    end

                    ADDR_MATRIX_COMMIT: begin
                        matrix_stage_valid_q <=
                            matrix_stage_valid_q &
                            ~matrix_lane_mask_q;
                    end

                    default: begin
                    end
                endcase
            end

            if (clear_statistics) begin
                command_count_q           <= 32'd0;
                command_error_count_q     <= 32'd0;
                execute_count_q           <= 32'd0;
                last_command_q            <= 32'd0;
                last_command_error_q      <= 1'b0;
                last_command_error_code_q <= 2'd0;
            end
            else begin
                if (cmd_accept_i) begin
                    command_count_q <=
                        command_count_q + 32'd1;

                    last_command_q <= {
                        16'd0,
                        cmd_matrix_source_addr_o,
                        cmd_vector_source_addr_o,
                        2'b00,
                        cmd_precision_o,
                        cmd_opcode_o
                    };

                    last_command_error_q <=
                        cmd_error_i;

                    last_command_error_code_q <=
                        cmd_error_code_i;

                    if (cmd_error_i) begin
                        command_error_count_q <=
                            command_error_count_q + 32'd1;
                    end
                end

                if (execute_issue_i) begin
                    execute_count_q <=
                        execute_count_q + 32'd1;
                end
            end
        end
    end

    logic unused_read_valid;

    assign unused_read_valid =
        read_valid_i;

endmodule

`default_nettype wire
