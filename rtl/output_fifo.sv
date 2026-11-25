// ============================================================================
// Module: output_fifo.sv
// Project: Axio-Tensor PRO
// Description: Output Drain Serialization FIFO. Latches N*N 32-bit accumulator
//              results in parallel and serializes them into bytes (4*N*N bytes)
//              to stream across the UART transmitter.
//              Includes Assertion-Based Verification (ABV) underflow checks.
// ============================================================================

`timescale 1ns / 1ps

module output_fifo #(
    parameter int N         = 4,
    parameter int ACC_WIDTH = 32
)(
    input  logic                                            clk,
    input  logic                                            rst,
    
    // Parallel Load Port (from Systolic Array upon compute completion)
    input  logic                                            load_matrix,
    input  logic signed [N-1:0][N-1:0][ACC_WIDTH-1:0]       matrix_in,
    
    // Serial Read Port (to UART Transmitter)
    input  logic                                            rd_en,
    output logic [7:0]                                      data_out,
    output logic                                            empty,
    output logic                                            full,
    output logic [$clog2(4*N*N+1)-1:0]                      count
);

    localparam int TOTAL_BYTES = N * N * 4; // 4 bytes per 32-bit word

    // Serialization storage buffer: TOTAL_BYTES
    logic [7:0] fifo_mem [0:TOTAL_BYTES-1];
    logic [$clog2(TOTAL_BYTES+1)-1:0] rd_ptr;
    logic [$clog2(TOTAL_BYTES+1)-1:0] byte_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr     <= '0;
            byte_count <= '0;
            for (int i = 0; i < TOTAL_BYTES; i++) fifo_mem[i] <= 8'h00;
        end else if (load_matrix) begin
            // Parallel capture of N*N 32-bit words into little-endian bytes
            int byte_idx;
            byte_idx = 0;
            for (int r = 0; r < N; r++) begin
                for (int c = 0; c < N; c++) begin
                    // Little-endian byte ordering: byte 0 (LSB) to byte 3 (MSB)
                    fifo_mem[byte_idx + 0] <= matrix_in[r][c][7:0];
                    fifo_mem[byte_idx + 1] <= matrix_in[r][c][15:8];
                    fifo_mem[byte_idx + 2] <= matrix_in[r][c][23:16];
                    fifo_mem[byte_idx + 3] <= matrix_in[r][c][31:24];
                    byte_idx = byte_idx + 4;
                end
            end
            rd_ptr     <= '0;
            byte_count <= TOTAL_BYTES;
        end else if (rd_en && !empty) begin
            rd_ptr     <= rd_ptr + 1'b1;
            byte_count <= byte_count - 1'b1;
        end
    end

    assign data_out = fifo_mem[rd_ptr];
    assign empty    = (byte_count == 0);
    assign full     = (byte_count == TOTAL_BYTES);
    assign count    = byte_count;

    // ------------------------------------------------------------------------
    // Assertion-Based Verification (ABV)
    // ------------------------------------------------------------------------
    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            // Underflow check: rd_en must not assert when FIFO is empty
            assert (!(rd_en && empty))
                else $error("[ABV ERROR] Output FIFO underflow! rd_en asserted while empty.");
            
            // Pointer bound check
            assert (rd_ptr <= TOTAL_BYTES)
                else $error("[ABV ERROR] Output FIFO rd_ptr exceeded bounds!");
        end
    end
    `endif

endmodule
