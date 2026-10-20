// -----------------------------------------------------------------------------
// Testbench: Layer 12 in-network collective reduction ALU.
//
// The property that matters is order independence: a ring may deliver
// contributions in any order, and SUM/MIN/MAX must still produce the same
// answer. Each is checked by reducing the same multiset in several
// permutations and comparing.
//
// Also checked: identity re-arm on last, per-slot independence, PASS
// semantics, and the slot_complete barrier bits.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_collective_alu;

    localparam int unsigned SLOTS     = 16;
    localparam int unsigned SLOT_BITS = 4;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic                      clear_i;
    logic [1:0]                clear_op_i;
    logic                      in_valid_i;
    logic                      in_ready_o;
    logic [1:0]                op_i;
    logic [SLOT_BITS-1:0]      slot_i;
    logic signed [31:0]        payload_i;
    logic                      last_i;
    logic                      out_valid_o;
    logic                      out_ready_i;
    logic signed [31:0]        out_payload_o;
    logic [SLOT_BITS-1:0]      out_slot_o;
    logic                      out_last_o;
    logic [SLOTS-1:0]          slot_complete_o;

    nce_collective_alu #(.SLOTS(SLOTS)) dut (
        .clk_i (clk), .rst_ni (rst_n),
        .clear_i (clear_i), .clear_op_i (clear_op_i),
        .in_valid_i (in_valid_i), .in_ready_o (in_ready_o),
        .op_i (op_i), .slot_i (slot_i), .payload_i (payload_i), .last_i (last_i),
        .out_valid_o (out_valid_o), .out_ready_i (out_ready_i),
        .out_payload_o (out_payload_o), .out_slot_o (out_slot_o),
        .out_last_o (out_last_o),
        .slot_complete_o (slot_complete_o)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    localparam logic [1:0] COLL_SUM  = 2'b00;
    localparam logic [1:0] COLL_MIN  = 2'b01;
    localparam logic [1:0] COLL_MAX  = 2'b10;
    localparam logic [1:0] COLL_PASS = 2'b11;

    task automatic do_clear (input logic [1:0] op);
        begin
            @(negedge clk);
            clear_op_i = op;
            clear_i    = 1'b1;
            @(posedge clk);
            @(negedge clk);
            clear_i    = 1'b0;
        end
    endtask

    // Push one contribution and wait for the result beat.
    task automatic push (
        input logic [1:0]        op,
        input logic [SLOT_BITS-1:0] slot,
        input logic signed [31:0] payload,
        input logic               last
    );
        begin
            @(negedge clk);
            op_i       = op;
            slot_i     = slot;
            payload_i  = payload;
            last_i     = last;
            in_valid_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            in_valid_i = 1'b0;
        end
    endtask

    // Reduce a 4-element multiset in a given order; return the final payload.
    function automatic logic signed [31:0] expect_reduce (
        input logic [1:0] op,
        input logic signed [31:0] a, b, c, d
    );
        logic signed [31:0] acc;
        begin
            case (op)
                COLL_SUM: acc = a + b + c + d;
                COLL_MIN: begin
                    acc = a;
                    if (b < acc) acc = b;
                    if (c < acc) acc = c;
                    if (d < acc) acc = d;
                end
                COLL_MAX: begin
                    acc = a;
                    if (b > acc) acc = b;
                    if (c > acc) acc = c;
                    if (d > acc) acc = d;
                end
                default: acc = d;     // PASS forwards the last payload
            endcase
            expect_reduce = acc;
        end
    endfunction

    // Drive four contributions in a chosen order, last flag on the 4th.
    task automatic reduce4 (
        input logic [1:0] op,
        input logic [SLOT_BITS-1:0] slot,
        input logic signed [31:0] p0, p1, p2, p3,
        output logic signed [31:0] result
    );
        begin
            push(op, slot, p0, 1'b0);
            push(op, slot, p1, 1'b0);
            push(op, slot, p2, 1'b0);
            push(op, slot, p3, 1'b1);
            result = out_payload_o;
        end
    endtask

    initial begin
        logic signed [31:0] r_a, r_b, r_c, exp;

        clear_i     = 1'b0;
        clear_op_i  = COLL_SUM;
        in_valid_i  = 1'b0;
        op_i        = COLL_SUM;
        slot_i      = '0;
        payload_i   = '0;
        last_i      = 1'b0;
        out_ready_i = 1'b1;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- SUM: order independence -----------------------------------------
        do_clear(COLL_SUM);
        reduce4(COLL_SUM, 4'd0,  10,  -3,  7, 100, r_a);
        do_clear(COLL_SUM);
        reduce4(COLL_SUM, 4'd0, 100,   7, -3,  10, r_b);
        do_clear(COLL_SUM);
        reduce4(COLL_SUM, 4'd0,  -3, 100, 10,   7, r_c);

        exp = expect_reduce(COLL_SUM, 10, -3, 7, 100);
        checks++;
        if (!(r_a === r_b && r_a === r_c && r_a === exp)) begin
            errors++;
            $display("FAIL [sum-order]: %0d %0d %0d expected %0d", r_a, r_b, r_c, exp);
        end
        else $display("  SUM  order-independent: %0d across 3 orders", r_a);

        // ---- MIN -------------------------------------------------------------
        do_clear(COLL_MIN);
        reduce4(COLL_MIN, 4'd1, 50, -20, 7, 33, r_a);
        do_clear(COLL_MIN);
        reduce4(COLL_MIN, 4'd1, 33, 7, 50, -20, r_b);
        checks++;
        if (!(r_a === r_b && r_a === -20)) begin
            errors++;
            $display("FAIL [min]: %0d %0d expected -20", r_a, r_b);
        end
        else $display("  MIN  order-independent: %0d", r_a);

        // ---- MAX -------------------------------------------------------------
        do_clear(COLL_MAX);
        reduce4(COLL_MAX, 4'd2, 50, -20, 7, 33, r_a);
        do_clear(COLL_MAX);
        reduce4(COLL_MAX, 4'd2, -20, 33, 50, 7, r_b);
        checks++;
        if (!(r_a === r_b && r_a === 50)) begin
            errors++;
            $display("FAIL [max]: %0d %0d expected 50", r_a, r_b);
        end
        else $display("  MAX  order-independent: %0d", r_a);

        // ---- PASS forwards the payload unchanged -----------------------------
        do_clear(COLL_SUM);
        push(COLL_PASS, 4'd3, 32'hDEAD, 1'b1);
        checks++;
        if (out_payload_o !== 32'hDEAD) begin
            errors++;
            $display("FAIL [pass]: got %h expected DEAD", out_payload_o);
        end

        // ---- negative sums and signedness ------------------------------------
        do_clear(COLL_SUM);
        reduce4(COLL_SUM, 4'd4, -100, -200, -300, -400, r_a);
        checks++;
        if (r_a !== -1000) begin
            errors++;
            $display("FAIL [negative-sum]: got %0d expected -1000", r_a);
        end

        // ---- slots are independent -------------------------------------------
        do_clear(COLL_SUM);
        push(COLL_SUM, 4'd5,  11, 1'b0);
        push(COLL_SUM, 4'd6, 500, 1'b0);
        push(COLL_SUM, 4'd5,  22, 1'b1);
        checks++;
        if (out_payload_o !== 33) begin
            errors++;
            $display("FAIL [slot-isolation]: slot5 got %0d expected 33", out_payload_o);
        end
        push(COLL_SUM, 4'd6, 500, 1'b1);
        checks++;
        if (out_payload_o !== 1000) begin
            errors++;
            $display("FAIL [slot-isolation]: slot6 got %0d expected 1000", out_payload_o);
        end
        else $display("  slots independent: slot5=33 slot6=1000");

        // ---- last re-arms the slot to identity -------------------------------
        // After the previous SUM completed on slot 5, a fresh reduction must
        // start from 0 rather than carrying 33 forward.
        push(COLL_SUM, 4'd5, 4, 1'b1);
        checks++;
        if (out_payload_o !== 4) begin
            errors++;
            $display("FAIL [re-arm]: got %0d expected 4 (slot not reset on last)",
                     out_payload_o);
        end
        else $display("  slot re-armed to identity after last");

        // ---- barrier bits ----------------------------------------------------
        checks++;
        if (slot_complete_o[5] !== 1'b1) begin
            errors++;
            $display("FAIL [barrier]: slot 5 complete bit not set");
        end

        // ---- out_slot / out_last are reported --------------------------------
        checks++;
        if (out_slot_o !== 4'd5 || out_last_o !== 1'b1) begin
            errors++;
            $display("FAIL [metadata]: slot=%0d last=%b", out_slot_o, out_last_o);
        end

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: collective ALU passed all %0d checks.", checks);
        else
            $display("FAIL: collective ALU had %0d errors in %0d checks.", errors, checks);
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1, "collective alu mismatch");
        $finish;
    end

endmodule

`default_nettype wire
