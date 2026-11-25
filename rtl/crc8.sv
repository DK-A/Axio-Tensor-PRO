// ============================================================================
// Module: crc8.sv
// Project: Axio-Tensor PRO
// Description: Synthesizable CRC-8 Engine using polynomial x^8 + x^2 + x + 1 (0x07).
//              Supports concurrent initialization and initial byte accumulation.
// ============================================================================

`timescale 1ns / 1ps

module crc8 (
    input  logic       clk,
    input  logic       rst,
    input  logic       init,       // Reset CRC to 8'h00 or first byte
    input  logic       data_valid, // Process next data byte
    input  logic [7:0] data_in,
    output logic [7:0] crc_out
);

    logic [7:0] crc_reg;

    // Pure combinational CRC-8 step function for polynomial 0x07
    function automatic logic [7:0] next_crc(input logic [7:0] current_crc, input logic [7:0] byte_in);
        logic [7:0] d;
        logic [7:0] c;
        logic [7:0] new_crc;
        begin
            d = byte_in;
            c = current_crc;
            new_crc[0] = d[7] ^ d[6] ^ d[0] ^ c[0] ^ c[6] ^ c[7];
            new_crc[1] = d[6] ^ d[1] ^ d[0] ^ c[0] ^ c[1] ^ c[6];
            new_crc[2] = d[6] ^ d[2] ^ d[1] ^ d[0] ^ c[0] ^ c[1] ^ c[2] ^ c[6];
            new_crc[3] = d[7] ^ d[3] ^ d[2] ^ d[1] ^ c[1] ^ c[2] ^ c[3] ^ c[7];
            new_crc[4] = d[4] ^ d[3] ^ d[2] ^ c[2] ^ c[3] ^ c[4];
            new_crc[5] = d[5] ^ d[4] ^ d[3] ^ c[3] ^ c[4] ^ c[5];
            new_crc[6] = d[6] ^ d[5] ^ d[4] ^ c[4] ^ c[5] ^ c[6];
            new_crc[7] = d[7] ^ d[6] ^ d[5] ^ c[5] ^ c[6] ^ c[7];
            return new_crc;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            crc_reg <= 8'h00;
        end else if (init) begin
            crc_reg <= data_valid ? next_crc(8'h00, data_in) : 8'h00;
        end else if (data_valid) begin
            crc_reg <= next_crc(crc_reg, data_in);
        end
    end

    assign crc_out = crc_reg;

endmodule
