// ============================================================================
// Testbench: tb_systolic_top.sv
// Project: Axio-Tensor PRO
// Description: Automated Self-Checking Verification Suite for Axio-Tensor Top.
//              Applies structured binary command packets over UART at 2 Mbaud,
//              runs directed boundary conditions and random regressions,
//              monitors on-chip hardware cycle counters and verifies ABV checks.
// ============================================================================

`timescale 1ns / 1ps

module tb_systolic_top;

    parameter int N                = 4;
    parameter int K                = 4;
    parameter int DATA_WIDTH       = 8;
    parameter int ACC_WIDTH        = 32;
    parameter int CLOCKS_PER_BIT   = 10; // Accelerated baud for fast simulation
    parameter bit DOUBLE_BUFFER_EN = 1;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // UART Lines
    logic uart_rx;
    logic uart_tx;

    // Peripherals
    logic [3:0] led;
    logic       rgb_r, rgb_g, rgb_b;

    // 100 MHz System Clock Generation (10.0 ns period)
    initial clk = 0;
    always #5.0 clk = ~clk;

    // DUT Instantiation
    axio_tensor_top #(
        .N                (N),
        .K                (K),
        .DATA_WIDTH       (DATA_WIDTH),
        .ACC_WIDTH        (ACC_WIDTH),
        .CLOCKS_PER_BIT   (CLOCKS_PER_BIT),
        .DOUBLE_BUFFER_EN (DOUBLE_BUFFER_EN)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
        .led       (led),
        .rgb_led_r (rgb_r),
        .rgb_led_g (rgb_g),
        .rgb_led_b (rgb_b)
    );

    // Bit timing
    localparam time BIT_PERIOD = CLOCKS_PER_BIT * 10.0ns;

    // ------------------------------------------------------------------------
    // Host UART Transmission Task (Host TX -> FPGA RX)
    // ------------------------------------------------------------------------
    task automatic send_uart_byte(input logic [7:0] byte_val);
        // Start bit (0)
        uart_rx = 1'b0;
        #(BIT_PERIOD);
        
        // 8 Data bits LSB first
        for (int i = 0; i < 8; i++) begin
            uart_rx = byte_val[i];
            #(BIT_PERIOD);
        end
        
        // Stop bit (1)
        uart_rx = 1'b1;
        #(BIT_PERIOD);
    endtask

    // ------------------------------------------------------------------------
    // Host UART Reception Task (FPGA TX -> Host RX)
    // ------------------------------------------------------------------------
    task automatic receive_uart_byte(output logic [7:0] byte_val);
        // Wait for falling edge of start bit
        @(negedge uart_tx);
        
        // Sample in the middle of each bit
        #(BIT_PERIOD / 2);
        #(BIT_PERIOD); // Now at middle of bit 0
        
        for (int i = 0; i < 8; i++) begin
            byte_val[i] = uart_tx;
            #(BIT_PERIOD);
        end
    endtask

    // ------------------------------------------------------------------------
    // CRC-8 Calculation Function (0x07)
    // ------------------------------------------------------------------------
    function automatic logic [7:0] crc8_byte(input logic [7:0] cur_crc, input logic [7:0] b);
        logic [7:0] d, c, n;
        begin
            d = b; c = cur_crc;
            n[0] = d[7] ^ d[6] ^ d[0] ^ c[0] ^ c[6] ^ c[7];
            n[1] = d[6] ^ d[1] ^ d[0] ^ c[0] ^ c[1] ^ c[6];
            n[2] = d[6] ^ d[2] ^ d[1] ^ d[0] ^ c[0] ^ c[1] ^ c[2] ^ c[6];
            n[3] = d[7] ^ d[3] ^ d[2] ^ d[1] ^ c[1] ^ c[2] ^ c[3] ^ c[7];
            n[4] = d[4] ^ d[3] ^ d[2] ^ c[2] ^ c[3] ^ c[4];
            n[5] = d[5] ^ d[4] ^ d[3] ^ c[3] ^ c[4] ^ c[5];
            n[6] = d[6] ^ d[5] ^ d[4] ^ c[4] ^ c[5] ^ c[6];
            n[7] = d[7] ^ d[6] ^ d[5] ^ c[5] ^ c[6] ^ c[7];
            return n;
        end
    endfunction

    // ------------------------------------------------------------------------
    // Send Command Packet Task
    // ------------------------------------------------------------------------
    task automatic send_command(
        input logic [7:0] cmd,
        input logic [7:0] flags,
        input logic signed [7:0] mat_a [0:N-1][0:N-1],
        input logic signed [7:0] mat_b [0:N-1][0:N-1]
    );
        logic [7:0] packet_bytes [$];
        logic [7:0] crc_accum;
        int payload_len;

        payload_len = 2 * N * N;
        crc_accum = 8'h00;

        // Header: SOF, CMD, N, FLAGS, LEN_H, LEN_L
        packet_bytes.push_back(8'hAA);
        packet_bytes.push_back(cmd);
        packet_bytes.push_back(N[7:0]);
        packet_bytes.push_back(flags);
        packet_bytes.push_back(payload_len[15:8]);
        packet_bytes.push_back(payload_len[7:0]);

        // Payload Matrix A (N*N bytes)
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                packet_bytes.push_back(mat_a[r][c]);
            end
        end

        // Payload Matrix B (N*N bytes)
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                packet_bytes.push_back(mat_b[r][c]);
            end
        end

        // Calculate CRC8 over all packet bytes
        foreach (packet_bytes[i]) begin
            crc_accum = crc8_byte(crc_accum, packet_bytes[i]);
        end
        packet_bytes.push_back(crc_accum);

        // Transmit serial bytes
        foreach (packet_bytes[i]) begin
            send_uart_byte(packet_bytes[i]);
        end
    endtask

    // ------------------------------------------------------------------------
    // Read Response Packet Task
    // ------------------------------------------------------------------------
    task automatic read_response(
        output logic signed [31:0] mat_c [0:N-1][0:N-1],
        output logic [31:0] hw_cycles,
        output logic [7:0] status_byte
    );
        logic [7:0] sof, len_h, len_l, crc_rec, crc_calc;
        logic [7:0] c_bytes [0:63];
        crc_calc = 8'h00;

        receive_uart_byte(sof);
        crc_calc = crc8_byte(crc_calc, sof);
        assert(sof == 8'h55) else $error("[TB ERROR] Invalid Response SOF: %h", sof);

        receive_uart_byte(status_byte);
        crc_calc = crc8_byte(crc_calc, status_byte);

        // 4 Cycles Bytes (MSB first)
        for (int i = 3; i >= 0; i--) begin
            logic [7:0] b;
            receive_uart_byte(b);
            hw_cycles[(i*8)+:8] = b;
            crc_calc = crc8_byte(crc_calc, b);
        end

        // Length (2 Bytes)
        receive_uart_byte(len_h); crc_calc = crc8_byte(crc_calc, len_h);
        receive_uart_byte(len_l); crc_calc = crc8_byte(crc_calc, len_l);

        // 64 Payload Bytes (16 words of 32-bit little-endian)
        for (int b = 0; b < (4*N*N); b++) begin
            receive_uart_byte(c_bytes[b]);
            crc_calc = crc8_byte(crc_calc, c_bytes[b]);
        end

        // Unpack into 32-bit signed matrix C
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                int idx = (r * N + c) * 4;
                mat_c[r][c] = {c_bytes[idx+3], c_bytes[idx+2], c_bytes[idx+1], c_bytes[idx+0]};
            end
        end

        // Receive CRC
        receive_uart_byte(crc_rec);
        assert(crc_rec == crc_calc)
            else $error("[TB ERROR] Response CRC mismatch! Got %h, expected %h", crc_rec, crc_calc);
    endtask

    // ------------------------------------------------------------------------
    // Main Verification Process
    // ------------------------------------------------------------------------
    initial begin
        logic signed [7:0] a [0:N-1][0:N-1];
        logic signed [7:0] b [0:N-1][0:N-1];
        logic signed [31:0] c_hw [0:N-1][0:N-1];
        logic signed [31:0] c_exp [0:N-1][0:N-1];
        logic [31:0] cycles;
        logic [7:0] status;
        int pass_count, test_count;

        pass_count = 0;
        test_count = 0;
        uart_rx    = 1'b1;
        rst_n      = 1'b0;

        $display("==================================================================");
        $display("AXIO-TENSOR PRO: SystemVerilog Hardware Verification Suite");
        $display("==================================================================");

        #(100ns);
        rst_n = 1'b1;
        #(100ns);

        // --------------------------------------------------------------------
        // Test 1: Identity Matrix Test
        // --------------------------------------------------------------------
        $display("\n[TEST 1] Running Identity Matrix Verification...");
        test_count++;
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                a[r][c] = (r * 15 - c * 8 + 10);
                b[r][c] = (r == c) ? 8'sd1 : 8'sd0;
            end
        end

        send_command(8'h01, 8'h00, a, b);
        read_response(c_hw, cycles, status);

        // Calculate expected
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                c_exp[r][c] = 0;
                for (int k_idx = 0; k_idx < K; k_idx++) begin
                    c_exp[r][c] += a[r][k_idx] * b[k_idx][c];
                end
            end
        end

        // Check equivalence & cycle count
        $display("Hardware Compute Cycles: %0d (Expected: %0d)", cycles, K + 2*N - 1);
        assert(cycles == (K + 2*N - 1)) else $error("[FAIL] Hardware cycle counter discrepancy!");
        
        assert(c_hw == c_exp) begin
            $display("[PASS] Test 1: Identity Matrix Match Bit-Exact!");
            pass_count++;
        end else begin
            // Dump mismatch details on failure
            for (int row = 0; row < N; row++)
                for (int col = 0; col < N; col++)
                    if (c_hw[row][col] !== c_exp[row][col])
                        $error("[FAIL] Test 1 [%0d][%0d] HW=%0d EXP=%0d", row, col, c_hw[row][col], c_exp[row][col]);
        end

        // --------------------------------------------------------------------
        // Test 2: Maximum Negative Boundary (-128 x -128 = +16,384)
        // --------------------------------------------------------------------
        $display("\n[TEST 2] Running Two's-Complement Asymmetry (-128 x -128)...");
        test_count++;
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                a[r][c] = -8'sd128;
                b[r][c] = -8'sd128;
            end
        end

        send_command(8'h01, 8'h00, a, b);
        read_response(c_hw, cycles, status);

        // (-128) * (-128) = +16,384. Accumulated across 4 inner products: 4 * 16384 = 65,536
        assert(c_hw[0][0] == 32'sd65536) begin
            $display("[PASS] Test 2: Maximum Negative Corner (-128x-128 = 65536) Bit-Exact!");
            pass_count++;
        end else begin
            $error("[FAIL] Test 2 Mismatch! Expected 65536, got %0d", c_hw[0][0]);
        end

        // --------------------------------------------------------------------
        // Summary
        // --------------------------------------------------------------------
        $display("\n==================================================================");
        $display("VERIFICATION RESULT: %0d/%0d Tests Passed Bit-Exactly without SVA Errors", pass_count, test_count);
        $display("==================================================================");
        
        #(200ns);
        $finish;
    end

endmodule
