// ============================================================================
// Module: uart_tx.sv
// Project: Axio-Tensor PRO
// Description: High-Speed 8-N-1 UART Transmitter with Ready/Valid Handshake
//              and ABV handshaking assertions.
//              Configurable baud rate (Default: 2,000,000 baud @ 100 MHz clock,
//              CLOCKS_PER_BIT = 50).
// ============================================================================

`timescale 1ns / 1ps

module uart_tx #(
    parameter int CLOCKS_PER_BIT = 50 // 100 MHz / 2 Mbaud = 50 clocks/bit
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       tx_valid,
    input  logic [7:0] tx_byte,
    output logic       tx_ready,
    output logic       tx_out
);

    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        START = 2'b01,
        DATA  = 2'b10,
        STOP  = 2'b11
    } state_t;

    state_t state;

    logic [$clog2(CLOCKS_PER_BIT+1)-1:0] clk_cnt;
    logic [2:0]                          bit_idx;
    logic [7:0]                          tx_data_reg;
    logic                                tx_line;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= IDLE;
            clk_cnt     <= '0;
            bit_idx     <= '0;
            tx_data_reg <= '0;
            tx_line     <= 1'b1; // Mark state (idle high)
        end else begin
            case (state)
                IDLE: begin
                    tx_line <= 1'b1;
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (tx_valid) begin
                        tx_data_reg <= tx_byte;
                        tx_line     <= 1'b0; // Start bit
                        state       <= START;
                    end
                end

                START: begin
                    tx_line <= 1'b0;
                    if (clk_cnt == (CLOCKS_PER_BIT - 1)) begin
                        clk_cnt <= '0;
                        tx_line <= tx_data_reg[0];
                        state   <= DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                DATA: begin
                    tx_line <= tx_data_reg[bit_idx];
                    if (clk_cnt == (CLOCKS_PER_BIT - 1)) begin
                        clk_cnt <= '0;
                        if (bit_idx == 7) begin
                            bit_idx <= '0;
                            tx_line <= 1'b1; // Stop bit
                            state   <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                STOP: begin
                    tx_line <= 1'b1;
                    if (clk_cnt == (CLOCKS_PER_BIT - 1)) begin
                        clk_cnt <= '0;
                        state   <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign tx_ready = (state == IDLE);
    assign tx_out   = tx_line;

    // ------------------------------------------------------------------------
    // Assertion-Based Verification (ABV)
    // ------------------------------------------------------------------------
    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            // Ready/valid protocol assertion: if tx_valid is asserted, data should not change
            // until accepted by tx_ready.
            if ($past(tx_valid && !tx_ready && !rst)) begin
                assert ($stable(tx_byte))
                    else $error("[ABV ERROR] UART TX tx_byte changed while waiting for tx_ready!");
            end
        end
    end
    `endif

endmodule
