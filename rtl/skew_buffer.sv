// ============================================================================
// Module: skew_buffer.sv
// Project: Axio-Tensor PRO
// Description: Triangular Shift Register buffer to skew activation rows
//              and weight columns for 2D systolic wavefront alignment.
//
// Delay Formulation:
//   - Activation row i delayed by i cycles (Row 0: 0 cyc, Row 1: 1 cyc, etc.)
//   - Weight column j delayed by j cycles (Col 0: 0 cyc, Col 1: 1 cyc, etc.)
// ============================================================================

`timescale 1ns / 1ps

module skew_buffer #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 8
)(
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic                                  en,
    
    // Unskewed Parallel Inputs from Memory Buffer
    input  logic signed [N-1:0][DATA_WIDTH-1:0]   raw_a,  // Rows of activations
    input  logic signed [N-1:0][DATA_WIDTH-1:0]   raw_b,  // Columns of weights
    
    // Wavefront Skewed Outputs to Systolic Mesh Boundary
    output logic signed [N-1:0][DATA_WIDTH-1:0]   skewed_a,
    output logic signed [N-1:0][DATA_WIDTH-1:0]   skewed_b
);

    // Row 0 has 0 delay stages, Row i has i delay stages
    genvar i, j, k;
    generate
        for (i = 0; i < N; i++) begin : gen_row_skew
            if (i == 0) begin : gen_no_delay_a
                assign skewed_a[0] = raw_a[0];
            end else begin : gen_shift_reg_a
                logic signed [DATA_WIDTH-1:0] sr_a [0:i-1];
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for (int s = 0; s < i; s++) sr_a[s] <= '0;
                    end else if (en) begin
                        sr_a[0] <= raw_a[i];
                        for (int s = 1; s < i; s++) begin
                            sr_a[s] <= sr_a[s-1];
                        end
                    end
                end
                assign skewed_a[i] = sr_a[i-1];
            end
        end

        for (j = 0; j < N; j++) begin : gen_col_skew
            if (j == 0) begin : gen_no_delay_b
                assign skewed_b[0] = raw_b[0];
            end else begin : gen_shift_reg_b
                logic signed [DATA_WIDTH-1:0] sr_b [0:j-1];
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for (int s = 0; s < j; s++) sr_b[s] <= '0;
                    end else if (en) begin
                        sr_b[0] <= raw_b[j];
                        for (int s = 1; s < j; s++) begin
                            sr_b[s] <= sr_b[s-1];
                        end
                    end
                end
                assign skewed_b[j] = sr_b[j-1];
            end
        end
    endgenerate

endmodule
