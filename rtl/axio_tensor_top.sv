// ============================================================================
// Module: axio_tensor_top.sv
// Project: Axio-Tensor PRO
// Description: Top-Level FPGA Accelerator integrating Systolic Datapath,
//              High-Speed UART (2 Mbaud), Ping-Pong Buffers, FSM Controller,
//              Hardware Cycle Counter, and Physical Arty S7 Peripherals.
// ============================================================================

`timescale 1ns / 1ps

module axio_tensor_top #(
    parameter int N                = 4,
    parameter int K                = 4,
    parameter int DATA_WIDTH       = 8,
    parameter int ACC_WIDTH        = 32,
    parameter int CLOCKS_PER_BIT   = 50, // 100 MHz / 2 Mbaud = 50
    parameter bit DOUBLE_BUFFER_EN = 1
)(
    input  logic       clk,          // 100 MHz system clock from Arty S7 oscillator
    input  logic       rst_n,        // Active-low push-button reset (btn[0])
    
    // UART Physical Interface (FTDI USB-UART)
    input  logic       uart_rx,      // Arty S7 Pin V12 (from Host TX)
    output logic       uart_tx,      // Arty S7 Pin R12 (to Host RX)
    
    // Physical Board Indicators
    output logic [3:0] led,          // 4 User Green LEDs (FSM State)
    output logic       rgb_led_r,    // RGB LED Red (Error / Sticky Overflow)
    output logic       rgb_led_g,    // RGB LED Green (Active / Success)
    output logic       rgb_led_b     // RGB LED Blue (Computing)
);

    // Active-high internal reset
    logic rst;
    assign rst = ~rst_n;

    // ------------------------------------------------------------------------
    // Internal Interconnect Signals
    // ------------------------------------------------------------------------
    // UART signals
    logic       rx_valid;
    logic [7:0] rx_byte;
    logic       tx_valid;
    logic [7:0] tx_byte;
    logic       tx_ready;

    // Buffer signals
    logic                          wr_en_a;
    logic                          wr_en_b;
    logic [$clog2(N*N)-1:0]        wr_addr;
    logic                          wr_bank;
    logic signed [DATA_WIDTH-1:0]  wr_data;
    logic                          rd_bank;
    logic [$clog2(N)-1:0]          rd_step_k;

    logic signed [N-1:0][DATA_WIDTH-1:0] mat_vec_a;
    logic signed [N-1:0][DATA_WIDTH-1:0] mat_vec_b;

    // Benchmark ROM signals
    logic                                benchmark_mode;
    logic signed [N-1:0][DATA_WIDTH-1:0] rom_vec_a;
    logic signed [N-1:0][DATA_WIDTH-1:0] rom_vec_b;

    // Multiplexed inputs to Skew Buffer
    logic signed [N-1:0][DATA_WIDTH-1:0] skew_in_a;
    logic signed [N-1:0][DATA_WIDTH-1:0] skew_in_b;

    // Skew Buffer outputs to Systolic Array
    logic signed [N-1:0][DATA_WIDTH-1:0] skewed_a;
    logic signed [N-1:0][DATA_WIDTH-1:0] skewed_b;

    // Systolic Array Control & Status
    logic                                sa_en;
    logic                                sa_acc_en;  // K-valid accumulation gate
    logic                                sa_clr_acc;
    logic                                sa_acc_keep;
    logic                                sa_overflow;
    logic signed [N-1:0][N-1:0][ACC_WIDTH-1:0] acc_matrix;

    // FIFO signals
    logic        fifo_load;
    logic        fifo_rd_en;
    logic [7:0]  fifo_data_out;
    logic        fifo_empty;
    logic        fifo_full;
    logic [31:0] hw_cycles;
    logic [3:0]  fsm_state_leds;

    // ------------------------------------------------------------------------
    // Submodule Instantiations
    // ------------------------------------------------------------------------
    // 1. High-Speed UART Receiver
    uart_rx #(
        .CLOCKS_PER_BIT (CLOCKS_PER_BIT)
    ) u_uart_rx (
        .clk      (clk),
        .rst      (rst),
        .rx_in    (uart_rx),
        .rx_valid (rx_valid),
        .rx_byte  (rx_byte)
    );

    // 2. High-Speed UART Transmitter
    uart_tx #(
        .CLOCKS_PER_BIT (CLOCKS_PER_BIT)
    ) u_uart_tx (
        .clk      (clk),
        .rst      (rst),
        .tx_valid (tx_valid),
        .tx_byte  (tx_byte),
        .tx_ready (tx_ready),
        .tx_out   (uart_tx)
    );

    // 3. Matrix Activation & Weight Buffer
    matrix_buffer #(
        .N                (N),
        .DATA_WIDTH       (DATA_WIDTH),
        .DOUBLE_BUFFER_EN (DOUBLE_BUFFER_EN)
    ) u_matrix_buffer (
        .clk        (clk),
        .rst        (rst),
        .wr_en_a    (wr_en_a),
        .wr_en_b    (wr_en_b),
        .wr_addr    (wr_addr),
        .wr_bank    (wr_bank),
        .wr_data    (wr_data),
        .rd_bank    (rd_bank),
        .rd_step_k  (rd_step_k),
        .read_vec_a (mat_vec_a),
        .read_vec_b (mat_vec_b)
    );

    // 4. On-Chip Benchmark ROM Pattern Generator
    onchip_benchmark_rom #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_benchmark_rom (
        .clk          (clk),
        .rst          (rst),
        .benchmark_en (benchmark_mode),
        .step_k       (rd_step_k),
        .rom_vec_a    (rom_vec_a),
        .rom_vec_b    (rom_vec_b)
    );

    // Mux inputs to skew buffer: choose Benchmark ROM or Host Matrix Buffer
    assign skew_in_a = benchmark_mode ? rom_vec_a : mat_vec_a;
    assign skew_in_b = benchmark_mode ? rom_vec_b : mat_vec_b;

    // 5. Triangular Skew Buffer
    skew_buffer #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_skew_buffer (
        .clk      (clk),
        .rst      (rst),
        .en       (sa_en),
        .raw_a    (skew_in_a),
        .raw_b    (skew_in_b),
        .skewed_a (skewed_a),
        .skewed_b (skewed_b)
    );

    // 6. Parameterized Systolic Array Mesh
    systolic_array #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_systolic_array (
        .clk          (clk),
        .rst          (rst),
        .en           (sa_en),
        .acc_en       (sa_acc_en),
        .clr_acc      (sa_clr_acc),
        .acc_keep     (sa_acc_keep),
        .in_a         (skewed_a),
        .in_b         (skewed_b),
        .acc_matrix   (acc_matrix),
        .any_overflow (sa_overflow)
    );

    // 7. Output Serialization FIFO
    output_fifo #(
        .N         (N),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_output_fifo (
        .clk         (clk),
        .rst         (rst),
        .load_matrix (fifo_load),
        .matrix_in   (acc_matrix),
        .rd_en       (fifo_rd_en),
        .data_out    (fifo_data_out),
        .empty       (fifo_empty),
        .full        (fifo_full),
        .count       ()
    );

    // 8. Central Controller FSM
    fsm_controller #(
        .N          (N),
        .K          (K),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_fsm (
        .clk                   (clk),
        .rst                   (rst),
        .rx_valid              (rx_valid),
        .rx_byte               (rx_byte),
        .tx_valid              (tx_valid),
        .tx_byte               (tx_byte),
        .tx_ready              (tx_ready),
        .wr_en_a               (wr_en_a),
        .wr_en_b               (wr_en_b),
        .wr_addr               (wr_addr),
        .wr_bank               (wr_bank),
        .wr_data               (wr_data),
        .rd_bank               (rd_bank),
        .rd_step_k             (rd_step_k),
        .sa_en                 (sa_en),
        .sa_acc_en             (sa_acc_en),
        .sa_clr_acc            (sa_clr_acc),
        .sa_acc_keep           (sa_acc_keep),
        .sa_any_overflow       (sa_overflow),
        .fifo_load             (fifo_load),
        .fifo_rd_en            (fifo_rd_en),
        .fifo_data_out         (fifo_data_out),
        .fifo_empty            (fifo_empty),
        .benchmark_mode_active (benchmark_mode),
        .hw_cycle_count        (hw_cycles),
        .state_leds            (fsm_state_leds)
    );

    // ------------------------------------------------------------------------
    // Board Peripherals & Status Indicators
    // ------------------------------------------------------------------------
    assign led = fsm_state_leds;

    // RGB LED behavior:
    // - Blue active when computing (sa_en == 1)
    // - Green active when idle and ready
    // - Red active if sticky overflow was flagged
    assign rgb_led_b = sa_en;
    assign rgb_led_r = sa_overflow;
    assign rgb_led_g = (~sa_en) && (~sa_overflow);

endmodule
