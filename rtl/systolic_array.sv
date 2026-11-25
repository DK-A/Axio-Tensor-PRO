// ============================================================================
// Module: systolic_array.sv
// Project: Axio-Tensor PRO
// Description: Parameterized N x N 2D Systolic Array Mesh with Output-Stationary
//              Processing Elements, Horizontal Activation Forwarding,
//              Vertical Weight Forwarding, and Aggregated Overflow Flag.
// ============================================================================

`timescale 1ns / 1ps

module systolic_array #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic                                  en,
    input  logic                                  acc_en,   // K-valid pulse: high for K cycles only
    input  logic                                  clr_acc,
    input  logic                                  acc_keep,
    
    // Wavefront Skewed Inputs along West and North boundaries
    input  logic signed [N-1:0][DATA_WIDTH-1:0]   in_a, // Row inputs (West boundary)
    input  logic signed [N-1:0][DATA_WIDTH-1:0]   in_b, // Col inputs (North boundary)
    
    // Flattened Accumulator Output Matrix (N*N words of ACC_WIDTH)
    output logic signed [N-1:0][N-1:0][ACC_WIDTH-1:0] acc_matrix,
    output logic                                      any_overflow
);

    // Interconnect wires between PEs:
    // a_wire[r][c] is the activation leaving PE(r, c) heading to PE(r, c+1)
    // b_wire[r][c] is the weight leaving PE(r, c) heading to PE(r+1, c)
    // en_wire[r][c] is the pipelined acc_en leaving PE(r,c) — forwarded East and South
    logic signed [DATA_WIDTH-1:0] a_wire [0:N-1][0:N-1];
    logic signed [DATA_WIDTH-1:0] b_wire [0:N-1][0:N-1];
    logic                         en_wire [0:N-1][0:N-1]; // pipelined acc_en per PE
    logic [N-1:0][N-1:0] pe_ovf;

    genvar r, c;
    generate
        for (r = 0; r < N; r++) begin : gen_rows
            for (c = 0; c < N; c++) begin : gen_cols

                // Boundary input muxing: West boundary takes in_a, internal takes from west neighbor
                logic signed [DATA_WIDTH-1:0] pe_in_a;
                logic signed [DATA_WIDTH-1:0] pe_in_b;
                logic                         pe_acc_en_in;

                if (c == 0) begin : gen_west_boundary
                    assign pe_in_a      = in_a[r];
                    assign pe_acc_en_in = (r == 0) ? acc_en : en_wire[r-1][c]; // propagate South
                end else begin : gen_internal_west
                    assign pe_in_a      = a_wire[r][c-1];
                    // For r==0: get acc_en from west neighbor; otherwise diagonal already captured
                    assign pe_acc_en_in = en_wire[r][c-1];
                end

                // Boundary input muxing: North boundary takes in_b, internal takes from north neighbor
                if (r == 0) begin : gen_north_boundary
                    assign pe_in_b = in_b[c];
                end else begin : gen_internal_north
                    assign pe_in_b = b_wire[r-1][c];
                end

                // Instantiate Processing Element
                pe #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) u_pe (
                    .clk             (clk),
                    .rst             (rst),
                    .en              (en),
                    .acc_en          (pe_acc_en_in),
                    .clr_acc         (clr_acc),
                    .acc_keep        (acc_keep),
                    .in_a            (pe_in_a),
                    .in_b            (pe_in_b),
                    .out_a           (a_wire[r][c]),
                    .out_b           (b_wire[r][c]),
                    .out_acc_en      (en_wire[r][c]),
                    .acc_out         (acc_matrix[r][c]),
                    .overflow_sticky (pe_ovf[r][c])
                );

            end
        end
    endgenerate

    // OR-reduction of sticky overflow flags across all N*N PEs
    logic ovf_reduced;
    always_comb begin
        ovf_reduced = 1'b0;
        for (int row = 0; row < N; row++) begin
            for (int col = 0; col < N; col++) begin
                ovf_reduced = ovf_reduced | pe_ovf[row][col];
            end
        end
    end
    assign any_overflow = ovf_reduced;

endmodule
