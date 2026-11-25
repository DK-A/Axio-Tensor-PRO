// ============================================================================
// Module: uart_rx.sv
// Project: Axio-Tensor PRO
// Description: High-Speed 8-N-1 UART Receiver with 3-Stage Metastability Filter.
//              Configurable baud rate (Default: 2,000,000 baud @ 100 MHz clock,
//              CLOCKS_PER_BIT = 50).
// ============================================================================

`timescale 1ns / 1ps

module uart_rx #(
    parameter int CLOCKS_PER_BIT = 50 // 100 MHz / 2 Mbaud = 50 clocks/bit
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       rx_in,
    output logic       rx_valid,
    output logic [7:0] rx_byte
);

    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        START = 2'b01,
        DATA  = 2'b10,
        STOP  = 2'b11
    } state_t;

    state_t state;

    // 3-Stage Synchronizer for metastability avoidance
    logic rx_sync1, rx_sync2, rx_clean;
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
            rx_clean <= 1'b1;
        end else begin
            rx_sync1 <= rx_in;
            rx_sync2 <= rx_sync1;
            rx_clean <= rx_sync2;
        end
    end

    logic [$clog2(CLOCKS_PER_BIT+1)-1:0] clk_cnt;
    logic [2:0]                          bit_idx;
    logic [7:0]                          rx_shift;
    logic                                valid_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            clk_cnt   <= '0;
            bit_idx   <= '0;
            rx_shift  <= '0;
            valid_reg <= 1'b0;
        end else begin
            valid_reg <= 1'b0; // Default single-cycle pulse

            case (state)
                IDLE: begin
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (rx_clean == 1'b0) begin // Falling edge start bit
                        state <= START;
                    end
                end

                START: begin
                    // Sample at middle of start bit
                    if (clk_cnt == (CLOCKS_PER_BIT / 2)) begin
                        if (rx_clean == 1'b0) begin
                            clk_cnt <= '0;
                            state   <= DATA;
                        end else begin
                            state   <= IDLE; // False start glitch
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                DATA: begin
                    if (clk_cnt == (CLOCKS_PER_BIT - 1)) begin
                        clk_cnt          <= '0;
                        rx_shift[bit_idx] <= rx_clean;
                        if (bit_idx == 7) begin
                            bit_idx <= '0;
                            state   <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                STOP: begin
                    if (clk_cnt == (CLOCKS_PER_BIT - 1)) begin
                        clk_cnt   <= '0;
                        state     <= IDLE;
                        valid_reg <= 1'b1; // Complete byte received
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign rx_valid = valid_reg;
    assign rx_byte  = rx_shift;

endmodule
