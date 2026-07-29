`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi4lite_frontend;

    localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;

    logic clk_i;
    logic rst_ni;

    logic [31:0] s_axi_awaddr_i;
    logic [2:0]  s_axi_awprot_i;
    logic        s_axi_awvalid_i;
    logic        s_axi_awready_o;

    logic [31:0] s_axi_wdata_i;
    logic [3:0]  s_axi_wstrb_i;
    logic        s_axi_wvalid_i;
    logic        s_axi_wready_o;

    logic [1:0] s_axi_bresp_o;
    logic       s_axi_bvalid_o;
    logic       s_axi_bready_i;

    logic [31:0] s_axi_araddr_i;
    logic [2:0]  s_axi_arprot_i;
    logic        s_axi_arvalid_i;
    logic        s_axi_arready_o;

    logic [31:0] s_axi_rdata_o;
    logic [1:0]  s_axi_rresp_o;
    logic        s_axi_rvalid_o;
    logic        s_axi_rready_i;

    logic        write_valid_o;
    logic        write_ready_i;
    logic [31:0] write_addr_o;
    logic [2:0]  write_prot_o;
    logic [31:0] write_data_o;
    logic [3:0]  write_strb_o;
    logic        write_error_i;

    logic        read_valid_o;
    logic        read_ready_i;
    logic [31:0] read_addr_o;
    logic [2:0]  read_prot_o;
    logic [31:0] read_data_i;
    logic        read_error_i;

    integer test_count;
    integer error_count;
    integer random_seed;
    integer test_index;

    nce_axi4lite_frontend dut (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),

        .s_axi_awaddr_i   (s_axi_awaddr_i),
        .s_axi_awprot_i   (s_axi_awprot_i),
        .s_axi_awvalid_i  (s_axi_awvalid_i),
        .s_axi_awready_o  (s_axi_awready_o),

        .s_axi_wdata_i    (s_axi_wdata_i),
        .s_axi_wstrb_i    (s_axi_wstrb_i),
        .s_axi_wvalid_i   (s_axi_wvalid_i),
        .s_axi_wready_o   (s_axi_wready_o),

        .s_axi_bresp_o    (s_axi_bresp_o),
        .s_axi_bvalid_o   (s_axi_bvalid_o),
        .s_axi_bready_i   (s_axi_bready_i),

        .s_axi_araddr_i   (s_axi_araddr_i),
        .s_axi_arprot_i   (s_axi_arprot_i),
        .s_axi_arvalid_i  (s_axi_arvalid_i),
        .s_axi_arready_o  (s_axi_arready_o),

        .s_axi_rdata_o    (s_axi_rdata_o),
        .s_axi_rresp_o    (s_axi_rresp_o),
        .s_axi_rvalid_o   (s_axi_rvalid_o),
        .s_axi_rready_i   (s_axi_rready_i),

        .write_valid_o    (write_valid_o),
        .write_ready_i    (write_ready_i),
        .write_addr_o     (write_addr_o),
        .write_prot_o     (write_prot_o),
        .write_data_o     (write_data_o),
        .write_strb_o     (write_strb_o),
        .write_error_i    (write_error_i),

        .read_valid_o     (read_valid_o),
        .read_ready_i     (read_ready_i),
        .read_addr_o      (read_addr_o),
        .read_prot_o      (read_prot_o),
        .read_data_i      (read_data_i),
        .read_error_i     (read_error_i)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    task automatic record_error (
        input string message
    );
        begin
            error_count = error_count + 1;

            if (error_count <= 20) begin
                $display(
                    "ERROR test=%0d: %s",
                    test_count,
                    message
                );
            end
        end
    endtask

    task automatic run_write (
        input logic [31:0] address,
        input logic [2:0]  protection,
        input logic [31:0] data,
        input logic [3:0]  strobe,
        input integer      aw_delay,
        input integer      w_delay,
        input integer      backend_delay,
        input integer      response_delay,
        input logic        backend_error
    );

        integer cycle_count;
        integer backend_count;
        integer response_count;
        integer backend_handshakes;

        logic aw_done;
        logic w_done;
        logic backend_seen;
        logic response_seen;
        logic completed;

        logic aw_fire;
        logic w_fire;
        logic backend_fire;
        logic response_fire;

        logic [1:0] expected_response;

        begin
            test_count = test_count + 1;

            expected_response =
                backend_error
                ? AXI_RESP_SLVERR
                : AXI_RESP_OKAY;

            aw_done            = 1'b0;
            w_done             = 1'b0;
            backend_seen       = 1'b0;
            response_seen      = 1'b0;
            completed          = 1'b0;
            backend_count      = backend_delay;
            response_count     = response_delay;
            backend_handshakes = 0;

            write_ready_i = 1'b0;
            write_error_i = backend_error;
            s_axi_bready_i = 1'b0;

            for (
                cycle_count = 0;
                (cycle_count < 100) && !completed;
                cycle_count = cycle_count + 1
            ) begin
                @(negedge clk_i);

                if (!aw_done && cycle_count >= aw_delay) begin
                    s_axi_awaddr_i  = address;
                    s_axi_awprot_i  = protection;
                    s_axi_awvalid_i = 1'b1;
                end
                else if (aw_done) begin
                    s_axi_awvalid_i = 1'b0;
                end

                if (!w_done && cycle_count >= w_delay) begin
                    s_axi_wdata_i  = data;
                    s_axi_wstrb_i  = strobe;
                    s_axi_wvalid_i = 1'b1;
                end
                else if (w_done) begin
                    s_axi_wvalid_i = 1'b0;
                end

                if (!backend_seen && write_valid_o) begin
                    backend_seen = 1'b1;
                    backend_count = backend_delay;
                end

                if (backend_seen) begin
                    if (backend_count == 0) begin
                        write_ready_i = 1'b1;
                    end
                    else begin
                        write_ready_i = 1'b0;
                        backend_count = backend_count - 1;
                    end
                end

                if (!response_seen && s_axi_bvalid_o) begin
                    response_seen = 1'b1;
                    response_count = response_delay;
                end

                if (response_seen) begin
                    if (response_count == 0) begin
                        s_axi_bready_i = 1'b1;
                    end
                    else begin
                        s_axi_bready_i = 1'b0;
                        response_count = response_count - 1;
                    end
                end

                @(posedge clk_i);

                aw_fire =
                    s_axi_awvalid_i &&
                    s_axi_awready_o;

                w_fire =
                    s_axi_wvalid_i &&
                    s_axi_wready_o;

                backend_fire =
                    write_valid_o &&
                    write_ready_i;

                response_fire =
                    s_axi_bvalid_o &&
                    s_axi_bready_i;

                if (write_valid_o) begin
                    if (
                        write_addr_o !== address ||
                        write_prot_o !== protection ||
                        write_data_o !== data ||
                        write_strb_o !== strobe
                    ) begin
                        record_error(
                            "Backend write payload mismatch"
                        );
                    end
                end

                if (
                    s_axi_bvalid_o &&
                    s_axi_bresp_o !== expected_response
                ) begin
                    record_error(
                        "Write response mismatch"
                    );
                end

                if (backend_fire) begin
                    backend_handshakes =
                        backend_handshakes + 1;
                end

                #1;

                if (aw_fire) begin
                    aw_done = 1'b1;
                end

                if (w_fire) begin
                    w_done = 1'b1;
                end

                if (response_fire) begin
                    completed = 1'b1;
                end
            end

            if (!aw_done) begin
                record_error(
                    "AW channel did not complete"
                );
            end

            if (!w_done) begin
                record_error(
                    "W channel did not complete"
                );
            end

            if (backend_handshakes != 1) begin
                record_error(
                    "Incorrect backend write handshake count"
                );
            end

            if (!completed) begin
                record_error(
                    "B channel did not complete"
                );
            end

            @(negedge clk_i);

            s_axi_awvalid_i = 1'b0;
            s_axi_wvalid_i  = 1'b0;
            s_axi_bready_i  = 1'b0;

            write_ready_i   = 1'b0;
            write_error_i   = 1'b0;
        end
    endtask

    task automatic run_read (
        input logic [31:0] address,
        input logic [2:0]  protection,
        input logic [31:0] backend_data,
        input integer      ar_delay,
        input integer      backend_delay,
        input integer      response_delay,
        input logic        backend_error
    );

        integer cycle_count;
        integer backend_count;
        integer response_count;
        integer backend_handshakes;

        logic ar_done;
        logic backend_seen;
        logic response_seen;
        logic completed;

        logic ar_fire;
        logic backend_fire;
        logic response_fire;

        logic [1:0] expected_response;

        begin
            test_count = test_count + 1;

            expected_response =
                backend_error
                ? AXI_RESP_SLVERR
                : AXI_RESP_OKAY;

            ar_done            = 1'b0;
            backend_seen       = 1'b0;
            response_seen      = 1'b0;
            completed          = 1'b0;
            backend_count      = backend_delay;
            response_count     = response_delay;
            backend_handshakes = 0;

            read_ready_i  = 1'b0;
            read_data_i   = backend_data;
            read_error_i  = backend_error;
            s_axi_rready_i = 1'b0;

            for (
                cycle_count = 0;
                (cycle_count < 100) && !completed;
                cycle_count = cycle_count + 1
            ) begin
                @(negedge clk_i);

                if (!ar_done && cycle_count >= ar_delay) begin
                    s_axi_araddr_i  = address;
                    s_axi_arprot_i  = protection;
                    s_axi_arvalid_i = 1'b1;
                end
                else if (ar_done) begin
                    s_axi_arvalid_i = 1'b0;
                end

                if (!backend_seen && read_valid_o) begin
                    backend_seen = 1'b1;
                    backend_count = backend_delay;
                end

                if (backend_seen) begin
                    if (backend_count == 0) begin
                        read_ready_i = 1'b1;
                    end
                    else begin
                        read_ready_i = 1'b0;
                        backend_count = backend_count - 1;
                    end
                end

                if (!response_seen && s_axi_rvalid_o) begin
                    response_seen = 1'b1;
                    response_count = response_delay;
                end

                if (response_seen) begin
                    if (response_count == 0) begin
                        s_axi_rready_i = 1'b1;
                    end
                    else begin
                        s_axi_rready_i = 1'b0;
                        response_count = response_count - 1;
                    end
                end

                @(posedge clk_i);

                ar_fire =
                    s_axi_arvalid_i &&
                    s_axi_arready_o;

                backend_fire =
                    read_valid_o &&
                    read_ready_i;

                response_fire =
                    s_axi_rvalid_o &&
                    s_axi_rready_i;

                if (read_valid_o) begin
                    if (
                        read_addr_o !== address ||
                        read_prot_o !== protection
                    ) begin
                        record_error(
                            "Backend read address mismatch"
                        );
                    end
                end

                if (s_axi_rvalid_o) begin
                    if (s_axi_rdata_o !== backend_data) begin
                        record_error(
                            "Read response data mismatch"
                        );
                    end

                    if (
                        s_axi_rresp_o !==
                        expected_response
                    ) begin
                        record_error(
                            "Read response code mismatch"
                        );
                    end
                end

                if (backend_fire) begin
                    backend_handshakes =
                        backend_handshakes + 1;
                end

                #1;

                if (ar_fire) begin
                    ar_done = 1'b1;
                end

                if (response_fire) begin
                    completed = 1'b1;
                end
            end

            if (!ar_done) begin
                record_error(
                    "AR channel did not complete"
                );
            end

            if (backend_handshakes != 1) begin
                record_error(
                    "Incorrect backend read handshake count"
                );
            end

            if (!completed) begin
                record_error(
                    "R channel did not complete"
                );
            end

            @(negedge clk_i);

            s_axi_arvalid_i = 1'b0;
            s_axi_rready_i  = 1'b0;

            read_ready_i    = 1'b0;
            read_data_i     = 32'd0;
            read_error_i    = 1'b0;
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        s_axi_awaddr_i  = '0;
        s_axi_awprot_i  = '0;
        s_axi_awvalid_i = 1'b0;

        s_axi_wdata_i   = '0;
        s_axi_wstrb_i   = '0;
        s_axi_wvalid_i  = 1'b0;

        s_axi_bready_i  = 1'b0;

        s_axi_araddr_i  = '0;
        s_axi_arprot_i  = '0;
        s_axi_arvalid_i = 1'b0;

        s_axi_rready_i  = 1'b0;

        write_ready_i   = 1'b0;
        write_error_i   = 1'b0;

        read_ready_i    = 1'b0;
        read_data_i     = '0;
        read_error_i    = 1'b0;

        test_count      = 0;
        error_count     = 0;
        random_seed     = 32'h4e43_4158;

        repeat (4) begin
            @(posedge clk_i);
        end

        #1;

        if (
            s_axi_awready_o !== 1'b0 ||
            s_axi_wready_o !== 1'b0 ||
            s_axi_arready_o !== 1'b0 ||
            s_axi_bvalid_o !== 1'b0 ||
            s_axi_rvalid_o !== 1'b0
        ) begin
            $fatal(
                1,
                "AXI frontend reset state is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        #1;

        if (
            s_axi_awready_o !== 1'b1 ||
            s_axi_wready_o !== 1'b1 ||
            s_axi_arready_o !== 1'b1
        ) begin
            $fatal(
                1,
                "AXI frontend did not become ready."
            );
        end

        // AW before W.
        run_write(
            32'h0000_0100,
            3'b000,
            32'h1122_3344,
            4'b1111,
            0,
            3,
            0,
            0,
            1'b0
        );

        // W before AW.
        run_write(
            32'h0000_0204,
            3'b001,
            32'haabb_ccdd,
            4'b0110,
            4,
            0,
            2,
            3,
            1'b0
        );

        // Simultaneous channels with error response.
        run_write(
            32'hffff_0000,
            3'b111,
            32'hdead_beef,
            4'b1001,
            0,
            0,
            4,
            4,
            1'b1
        );

        run_read(
            32'h0000_0300,
            3'b000,
            32'h1234_5678,
            0,
            0,
            0,
            1'b0
        );

        run_read(
            32'h0000_0404,
            3'b101,
            32'h89ab_cdef,
            3,
            4,
            5,
            1'b0
        );

        run_read(
            32'hffff_fffc,
            3'b010,
            32'hcafe_babe,
            0,
            2,
            2,
            1'b1
        );

        random_seed = $urandom(random_seed);

        for (
            test_index = 0;
            test_index < 500;
            test_index = test_index + 1
        ) begin
            run_write(
                $urandom,
                $urandom_range(7, 0),
                $urandom,
                $urandom_range(15, 0),
                $urandom_range(4, 0),
                $urandom_range(4, 0),
                $urandom_range(5, 0),
                $urandom_range(5, 0),
                $urandom_range(9, 0) == 0
            );
        end

        for (
            test_index = 0;
            test_index < 500;
            test_index = test_index + 1
        ) begin
            run_read(
                $urandom,
                $urandom_range(7, 0),
                $urandom,
                $urandom_range(4, 0),
                $urandom_range(5, 0),
                $urandom_range(5, 0),
                $urandom_range(9, 0) == 0
            );
        end

        if (error_count == 0) begin
            $display(
                "PASS: nce_axi4lite_frontend passed all %0d protocol transactions.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d transactions.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
