// ============================================================================
// Module: pe.sv
// Project: Axio-Tensor PRO
// Description: Output-Stationary Processing Element with Signed INT8 Arithmetic,
//              Native DSP48E1 Multiply-Accumulate, Sticky Overflow Flag,
//              and Assertion-Based Verification (ABV) Properties.
//
// Theoretical Bounds:
//   - Operands: signed 8-bit [-128, +127]
//   - Intermediate Product: signed 16-bit [-16,256, +16,384]
//   - Safe Accumulation: K <= 131,071 guaranteed overflow-free in INT32
//   - Sticky Overflow: Asserts if K > 131,071 and signed INT32 bounds exceeded
// ============================================================================

`timescale 1ns / 1ps

module pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                          clk,
    input  logic                          rst,
    input  logic                          en,            // Clock enable for forwarding/product pipeline
    input  logic                          acc_en,        // Accumulate enable: high only for K valid steps
    input  logic                          clr_acc,       // Synchronous clear for accumulator
    input  logic                          acc_keep,      // Multi-tile flag: retain accumulator across tiles
    
    // Systolic Wavefront Data Inputs
    input  logic signed [DATA_WIDTH-1:0]  in_a,          // Activation (streams East)
    input  logic signed [DATA_WIDTH-1:0]  in_b,          // Weight (streams South)
    
    // Systolic Forwarding Outputs (Registered 1-cycle delay)
    output logic signed [DATA_WIDTH-1:0]  out_a,
    output logic signed [DATA_WIDTH-1:0]  out_b,
    output logic                          out_acc_en,    // Pipelined acc_en forwarded to downstream PE
    
    // Stationary Accumulator State & Flags
    output logic signed [ACC_WIDTH-1:0]   acc_out,
    output logic                          overflow_sticky
);

    // ------------------------------------------------------------------------
    // Internal Registers
    // ------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]  reg_a;
    logic signed [DATA_WIDTH-1:0]  reg_b;
    logic                          reg_acc_en; // Pipelined acc_en (1-cycle delay matching mult_reg)
    
    // Intermediate product: 16-bit signed
    (* use_dsp = "yes" *) logic signed [(2*DATA_WIDTH)-1:0] mult_reg;
    
    // Accumulator: 32-bit signed
    logic signed [ACC_WIDTH-1:0]   acc_reg;
    logic                          ovf_reg;

    // ------------------------------------------------------------------------
    // Multiply-Accumulate Datapath
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            reg_a           <= '0;
            reg_b           <= '0;
            reg_acc_en      <= 1'b0;
            mult_reg        <= '0;
            acc_reg         <= '0;
            ovf_reg         <= 1'b0;
        end else begin
            // Operand Pipeline Forwarding (en gates data movement through mesh)
            if (en) begin
                reg_a      <= in_a;
                reg_b      <= in_b;
                reg_acc_en <= acc_en;  // Pipeline acc_en alongside data
                mult_reg   <= in_a * in_b; // Native signed 8x8 -> 16-bit product
            end

            // Accumulator Management
            // Only accumulate when pipelined acc_en is asserted (K valid steps only)
            if (clr_acc && !acc_keep) begin
                acc_reg <= '0;
                ovf_reg <= 1'b0;
            end else if (reg_acc_en) begin
                // Check for signed 32-bit overflow before update
                // INT32_MAX = 2,147,483,647 ; INT32_MIN = -2,147,483,648
                if (mult_reg > 0 && acc_reg > (32'sd2147483647 - mult_reg)) begin
                    ovf_reg <= 1'b1; // Positive overflow
                end else if (mult_reg < 0 && acc_reg < (-32'sd2147483648 - mult_reg)) begin
                    ovf_reg <= 1'b1; // Negative overflow
                end
                
                acc_reg <= acc_reg + mult_reg;
            end
        end
    end

    // Continuous Assignments
    assign out_a           = reg_a;
    assign out_b           = reg_b;
    assign out_acc_en      = reg_acc_en;
    assign acc_out         = acc_reg;
    assign overflow_sticky = ovf_reg;

    // ------------------------------------------------------------------------
    // Assertion-Based Verification (ABV) Properties
    // Immediate-style assertions compatible with both xsim and formal tools
    // ------------------------------------------------------------------------
    `ifndef SYNTHESIS
    logic past_valid;
    always_ff @(posedge clk) begin
        if (rst) past_valid <= 1'b0;
        else     past_valid <= 1'b1;
    end

    // Property 1: Product bounds strictly within [-16256, +16384]
    always_ff @(posedge clk) begin
        if (!rst && past_valid && reg_acc_en) begin
            assert ((mult_reg >= -16256) && (mult_reg <= 16384))
                else $error("[ABV ERROR] PE Product out of range [-16256, +16384]: %0d", mult_reg);
        end
    end

    // Property 2: Synchronous clear deterministically zeroes accumulator
    always_ff @(posedge clk) begin
        if (!rst && past_valid && $past(clr_acc && !acc_keep && !rst)) begin
            assert (acc_reg == 32'sd0)
                else $error("[ABV ERROR] PE Accumulator failed to clear synchronously!");
        end
    end

    // Property 3: One-cycle pipeline forwarding delay
    always_ff @(posedge clk) begin
        if (!rst && past_valid && $past(en && !rst)) begin
            assert (reg_a == $past(in_a))
                else $error("[ABV ERROR] PE in_a to out_a forwarding mismatch!");
            assert (reg_b == $past(in_b))
                else $error("[ABV ERROR] PE in_b to out_b forwarding mismatch!");
        end
    end
    `endif

endmodule
