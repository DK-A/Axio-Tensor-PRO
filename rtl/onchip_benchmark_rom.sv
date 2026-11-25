// ============================================================================
// Module: onchip_benchmark_rom.sv
// Project: Axio-Tensor PRO
// Description: On-Chip Autonomous Benchmark Pattern Generator (Mode A).
//              Provides continuous, zero-latency streaming of test matrices
//              directly into the systolic array to measure peak sustained GOPS
//              without UART communication bottlenecks.
// ============================================================================

`timescale 1ns / 1ps

module onchip_benchmark_rom #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 8
)(
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic                                  benchmark_en,
    input  logic [$clog2(N)-1:0]                  step_k,
    
    output logic signed [N-1:0][DATA_WIDTH-1:0]   rom_vec_a,
    output logic signed [N-1:0][DATA_WIDTH-1:0]   rom_vec_b
);

    // Pre-calculated deterministic patterns stressing switching activity:
    // Alternating positive/negative values to evaluate dynamic power and max throughput
    always_comb begin
        for (int r = 0; r < N; r++) begin
            // Non-trivial test vector with varying signs:
            // e.g. A[r][k] = ((r + step_k) % 2 == 0) ? 8'sd64 : -8'sd64
            rom_vec_a[r] = ((r + step_k) % 2 == 0) ? 8'sd64 : -8'sd64;
        end
        for (int c = 0; c < N; c++) begin
            // B[k][c] = ((c + step_k) % 2 == 0) ? 8'sd32 : -8'sd32
            rom_vec_b[c] = ((c + step_k) % 2 == 0) ? 8'sd32 : -8'sd32;
        end
    end

endmodule
