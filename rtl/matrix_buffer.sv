// ============================================================================
// Module: matrix_buffer.sv
// Project: Axio-Tensor PRO
// Description: Parameterized Activation and Weight Memory with support for
//              Single-Buffer (2*N*N bytes) and Double-Buffer Ping-Pong (4*N*N bytes).
//              Provides parallel vector slice read ports to drive skew buffers.
//
// Memory Layout:
//   - Bank 0: Activation [0 to N*N-1], Weight [0 to N*N-1] (2*N*N bytes)
//   - Bank 1: Activation [0 to N*N-1], Weight [0 to N*N-1] (2*N*N bytes, if enabled)
// ============================================================================

`timescale 1ns / 1ps

module matrix_buffer #(
    parameter int N                = 4,
    parameter int DATA_WIDTH       = 8,
    parameter bit DOUBLE_BUFFER_EN = 1
)(
    input  logic                                  clk,
    input  logic                                  rst,
    
    // Host Write Interface (from UART / Packet Decoder)
    input  logic                                  wr_en_a,       // Write enable for matrix A
    input  logic                                  wr_en_b,       // Write enable for matrix B
    input  logic [$clog2(N*N)-1:0]                wr_addr,       // Byte address within matrix [0 to N*N-1]
    input  logic                                  wr_bank,       // Target bank (0 or 1)
    input  logic signed [DATA_WIDTH-1:0]          wr_data,       // 8-bit signed operand
    
    // Systolic Read Interface (feeds skew buffer during computation)
    input  logic                                  rd_bank,       // Active read bank for accelerator
    input  logic [$clog2(N)-1:0]                  rd_step_k,     // Inner index k (0 to N-1)
    
    // Parallel Vector Outputs to Skew Buffer at time step k:
    // read_vec_a[r] = A[r][k] (column k of matrix A)
    // read_vec_b[c] = B[k][c] (row k of matrix B)
    output logic signed [N-1:0][DATA_WIDTH-1:0]   read_vec_a,
    output logic signed [N-1:0][DATA_WIDTH-1:0]   read_vec_b
);

    localparam int NUM_BANKS = DOUBLE_BUFFER_EN ? 2 : 1;
    localparam int MAT_SIZE  = N * N;

    // Banked Storage Arrays
    // mem_a[bank][row][col], mem_b[bank][row][col]
    logic signed [DATA_WIDTH-1:0] mem_a [0:NUM_BANKS-1][0:N-1][0:N-1];
    logic signed [DATA_WIDTH-1:0] mem_b [0:NUM_BANKS-1][0:N-1][0:N-1];

    // Host Write Logic
    // Maps linear byte address wr_addr to [row, col]
    logic [$clog2(N)-1:0] wr_row;
    logic [$clog2(N)-1:0] wr_col;
    assign wr_row = wr_addr / N;
    assign wr_col = wr_addr % N;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                for (int r = 0; r < N; r++) begin
                    for (int c = 0; c < N; c++) begin
                        mem_a[b][r][c] <= '0;
                        mem_b[b][r][c] <= '0;
                    end
                end
            end
        end else begin
            // Bank 0 write
            if (wr_bank == 1'b0 || !DOUBLE_BUFFER_EN) begin
                if (wr_en_a) mem_a[0][wr_row][wr_col] <= wr_data;
                if (wr_en_b) mem_b[0][wr_row][wr_col] <= wr_data;
            end
            // Bank 1 write (only if double buffering enabled)
            else if (DOUBLE_BUFFER_EN && wr_bank == 1'b1) begin
                if (wr_en_a) mem_a[1][wr_row][wr_col] <= wr_data;
                if (wr_en_b) mem_b[1][wr_row][wr_col] <= wr_data;
            end
        end
    end

    // Combinational Read Port to Skew Buffer
    // For step k:
    //   read_vec_a[r] = mem_a[active_bank][r][k]
    //   read_vec_b[c] = mem_b[active_bank][k][c]
    logic active_bank;
    assign active_bank = DOUBLE_BUFFER_EN ? rd_bank : 1'b0;

    always_comb begin
        for (int r = 0; r < N; r++) begin
            read_vec_a[r] = mem_a[active_bank][r][rd_step_k];
        end
        for (int c = 0; c < N; c++) begin
            read_vec_b[c] = mem_b[active_bank][rd_step_k][c];
        end
    end

endmodule
