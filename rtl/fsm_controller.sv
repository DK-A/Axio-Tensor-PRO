// ============================================================================
// Module: fsm_controller.sv
// Project: Axio-Tensor PRO
// Description: Central Control Finite State Machine with Packet Framing,
//              Cycle-Accurate Hardware Counter (K+2N-2 compute + 1 latch cycle),
//              Multi-Tile acc_keep Support, and Assertion-Based Verification.
// ============================================================================

`timescale 1ns / 1ps

module fsm_controller #(
    parameter int N          = 4,
    parameter int K          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                                  clk,
    input  logic                                  rst,
    
    // UART Stream Interface
    input  logic                                  rx_valid,
    input  logic [7:0]                            rx_byte,
    output logic                                  tx_valid,
    output logic [7:0]                            tx_byte,
    input  logic                                  tx_ready,
    
    // Matrix Buffer Control
    output logic                                  wr_en_a,
    output logic                                  wr_en_b,
    output logic [$clog2(N*N)-1:0]                wr_addr,
    output logic                                  wr_bank,
    output logic signed [DATA_WIDTH-1:0]          wr_data,
    output logic                                  rd_bank,
    output logic [$clog2(N)-1:0]                  rd_step_k,
    output logic                                  k_valid,   // HIGH for exactly K cycles (valid inner product steps)
    
    // Systolic Array Control
    output logic                                  sa_en,
    output logic                                  sa_acc_en, // K-valid gate for accumulation
    output logic                                  sa_clr_acc,
    output logic                                  sa_acc_keep,
    input  logic                                  sa_any_overflow,
    
    // Output FIFO Control
    output logic                                  fifo_load,
    output logic                                  fifo_rd_en,
    input  logic [7:0]                            fifo_data_out,
    input  logic                                  fifo_empty,
    
    // Mode & Status Flags
    output logic                                  benchmark_mode_active,
    output logic [31:0]                           hw_cycle_count,
    output logic [3:0]                            state_leds
);

    // Timing constants
    localparam int TOTAL_PAYLOAD_BYTES = 2 * N * N; // Matrix A (N*N) + Matrix B (N*N)
    localparam int TOTAL_DRAIN_BYTES   = 4 * N * N; // 4 bytes per 32-bit word
    localparam int COMPUTE_CYCLES      = K + 2 * N - 2; // Active compute (e.g. 10 for N=4, K=4)
    localparam int LATCH_CYCLE         = COMPUTE_CYCLES + 1; // Cycle 11: latch accumulators

    // Packet Protocol Constants
    localparam logic [7:0] SOF_CMD  = 8'hAA;
    localparam logic [7:0] SOF_RESP = 8'h55;

    localparam logic [7:0] CMD_COMPUTE   = 8'h01;
    localparam logic [7:0] CMD_BENCHMARK = 8'h02;
    localparam logic [7:0] CMD_RESET_ACC = 8'h03;

    // FSM States
    typedef enum logic [3:0] {
        ST_IDLE          = 4'h0,
        ST_PARSE_HDR     = 4'h1,
        ST_LOAD_PAYLOAD  = 4'h2,
        ST_CHECK_CRC     = 4'h3,
        ST_START_COMP    = 4'h4,
        ST_COMPUTE       = 4'h5,
        ST_LATCH_DRAIN   = 4'h6,
        ST_SEND_RESP_HDR = 4'h7,
        ST_DRAIN_FIFO    = 4'h8,
        ST_SEND_CRC      = 4'h9
    } state_t;

    state_t state;

    // Packet Fields
    logic [7:0]  cmd_reg;
    logic [7:0]  dim_n_reg;
    logic [7:0]  flags_reg;
    logic [15:0] payload_len_reg;
    logic [7:0]  rx_crc_reg;
    logic        crc_err_reg;
    logic        sticky_ovf_reg;

    // Counters
    logic [3:0]                             hdr_idx;
    logic [$clog2(TOTAL_PAYLOAD_BYTES)-1:0] rx_byte_idx;
    logic [$clog2(LATCH_CYCLE+2)-1:0]       comp_cycle_cnt;
    logic [31:0]                            cycle_timer;
    logic [3:0]                             resp_hdr_idx;

    // CRC Engine Signals
    logic       crc_init;
    logic       crc_data_valid;
    logic [7:0] crc_data_in;
    logic [7:0] calculated_crc;

    crc8 u_crc8 (
        .clk        (clk),
        .rst        (rst),
        .init       (crc_init),
        .data_valid (crc_data_valid),
        .data_in    (crc_data_in),
        .crc_out    (calculated_crc)
    );

    // Decode flags
    wire flag_acc_keep = flags_reg[0];
    wire flag_bank_sel = flags_reg[2];

    assign sa_acc_keep = flag_acc_keep;
    assign wr_bank     = flag_bank_sel;
    assign rd_bank     = flag_bank_sel;

    // ------------------------------------------------------------------------
    // FSM State Transition & Datapath Control
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state                 <= ST_IDLE;
            cmd_reg               <= '0;
            dim_n_reg             <= '0;
            flags_reg             <= '0;
            payload_len_reg       <= '0;
            rx_crc_reg            <= '0;
            crc_err_reg           <= 1'b0;
            sticky_ovf_reg        <= 1'b0;
            hdr_idx               <= '0;
            rx_byte_idx           <= '0;
            comp_cycle_cnt        <= '0;
            cycle_timer           <= '0;
            resp_hdr_idx          <= '0;
            wr_en_a               <= 1'b0;
            wr_en_b               <= 1'b0;
            wr_addr               <= '0;
            wr_data               <= '0;
            rd_step_k             <= '0;
            sa_en                 <= 1'b0;
            sa_clr_acc            <= 1'b0;
            fifo_load             <= 1'b0;
            fifo_rd_en            <= 1'b0;
            tx_valid              <= 1'b0;
            tx_byte               <= '0;
            crc_init              <= 1'b1;
            crc_data_valid        <= 1'b0;
            crc_data_in           <= '0;
            benchmark_mode_active <= 1'b0;
            k_valid               <= 1'b0;
            sa_acc_en             <= 1'b0;
        end else begin
            // Default pulse deassertions
            wr_en_a        <= 1'b0;
            wr_en_b        <= 1'b0;
            sa_clr_acc     <= 1'b0;
            fifo_load      <= 1'b0;
            fifo_rd_en     <= 1'b0;
            crc_init       <= 1'b0;
            crc_data_valid <= 1'b0;
            k_valid        <= 1'b0;
            sa_acc_en      <= 1'b0;

            // Latch sticky overflow
            if (sa_any_overflow) sticky_ovf_reg <= 1'b1;

            // Maintain tx_valid until accepted by tx_ready
            if (tx_valid && tx_ready) tx_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    hdr_idx               <= '0;
                    rx_byte_idx           <= '0;
                    comp_cycle_cnt        <= '0;
                    benchmark_mode_active <= 1'b0;
                    sa_en                 <= 1'b0;
                    
                    if (rx_valid && rx_byte == SOF_CMD) begin
                        crc_init       <= 1'b1;
                        crc_data_valid <= 1'b1;
                        crc_data_in    <= SOF_CMD;
                        state          <= ST_PARSE_HDR;
                    end
                end

                ST_PARSE_HDR: begin
                    if (rx_valid) begin
                        crc_data_valid <= 1'b1;
                        crc_data_in    <= rx_byte;

                        case (hdr_idx)
                            4'd0: cmd_reg                <= rx_byte;
                            4'd1: dim_n_reg              <= rx_byte;
                            4'd2: flags_reg              <= rx_byte;
                            4'd3: payload_len_reg[15:8]  <= rx_byte;
                            4'd4: payload_len_reg[7:0]   <= rx_byte;
                        endcase

                        if (hdr_idx == 4'd4) begin
                            hdr_idx     <= '0;
                            rx_byte_idx <= '0;
                            if (cmd_reg == CMD_RESET_ACC) begin
                                sa_clr_acc     <= 1'b1;
                                sticky_ovf_reg <= 1'b0;
                                state          <= ST_CHECK_CRC;
                            end else begin
                                state          <= ST_LOAD_PAYLOAD;
                            end
                        end else begin
                            hdr_idx <= hdr_idx + 1'b1;
                        end
                    end
                end

                ST_LOAD_PAYLOAD: begin
                    if (rx_valid) begin
                        crc_data_valid <= 1'b1;
                        crc_data_in    <= rx_byte;
                        wr_data        <= rx_byte;

                        // First N*N bytes are Matrix A, next N*N bytes are Matrix B
                        if (rx_byte_idx < (N * N)) begin
                            wr_en_a <= 1'b1;
                            wr_addr <= rx_byte_idx[$clog2(N*N)-1:0];
                        end else begin
                            wr_en_b <= 1'b1;
                            wr_addr <= (rx_byte_idx - (N * N));
                        end

                        if (rx_byte_idx == (TOTAL_PAYLOAD_BYTES - 1)) begin
                            state <= ST_CHECK_CRC;
                        end else begin
                            rx_byte_idx <= rx_byte_idx + 1'b1;
                        end
                    end
                end

                ST_CHECK_CRC: begin
                    if (rx_valid) begin
                        rx_crc_reg <= rx_byte;
                        // Compare received CRC byte with computed CRC
                        if (calculated_crc == rx_byte) begin
                            crc_err_reg <= 1'b0;
                            if (cmd_reg == CMD_BENCHMARK) begin
                                benchmark_mode_active <= 1'b1;
                                state                 <= ST_START_COMP;
                            end else if (cmd_reg == CMD_COMPUTE) begin
                                state                 <= ST_START_COMP;
                            end else begin // CMD_RESET_ACC
                                state                 <= ST_SEND_RESP_HDR;
                            end
                        end else begin
                            crc_err_reg <= 1'b1; // CRC Error detected
                            state       <= ST_SEND_RESP_HDR;
                        end
                    end
                end

                ST_START_COMP: begin
                    sa_en          <= 1'b1;
                    sa_acc_en      <= 1'b1;  // First K-valid pulse: aligns with cycle-0 product in PE[0][0]
                    k_valid        <= 1'b1;
                    comp_cycle_cnt <= '0;
                    cycle_timer    <= '0;
                    rd_step_k      <= '0;
                    if (!flag_acc_keep) sa_clr_acc <= 1'b1;
                    state          <= ST_COMPUTE;
                end

                ST_COMPUTE: begin
                    sa_en          <= 1'b1;
                    comp_cycle_cnt <= comp_cycle_cnt + 1'b1;
                    cycle_timer    <= cycle_timer + 1'b1;

                    // Assert k_valid and sa_acc_en for K-1 more cycles (first pulse was in ST_START_COMP)
                    // Total: K pulses of acc_en covering inner product steps 0..K-1
                    if (comp_cycle_cnt < (K - 1)) begin
                        k_valid   <= 1'b1;
                        sa_acc_en <= 1'b1;
                        // Advance matrix read index k for steps 1..K-1
                        rd_step_k <= rd_step_k + 1'b1;
                    end

                    // Deterministic compute completes at K+2N-2 cycles (10 for N=4, K=4)
                    if (comp_cycle_cnt == (COMPUTE_CYCLES - 1)) begin
                        state <= ST_LATCH_DRAIN;
                    end
                end

                ST_LATCH_DRAIN: begin
                    // Latch Cycle (Cycle 11 for N=4): Pulse FIFO parallel load
                    sa_en        <= 1'b0;
                    cycle_timer  <= cycle_timer + 1'b1; // Registers exact K+2N-1 cycles
                    fifo_load    <= 1'b1;               // Latch all accumulators into FIFO
                    resp_hdr_idx <= '0;
                    crc_init     <= 1'b1;               // Initialize CRC for response
                    state        <= ST_SEND_RESP_HDR;
                end

                ST_SEND_RESP_HDR: begin
                    if (tx_ready && !tx_valid) begin
                        tx_valid       <= 1'b1;
                        crc_data_valid <= 1'b1;

                        case (resp_hdr_idx)
                            4'd0: begin tx_byte <= SOF_RESP;                                   crc_data_in <= SOF_RESP; end
                            4'd1: begin tx_byte <= {5'b0, crc_err_reg, sticky_ovf_reg, 1'b1};  crc_data_in <= {5'b0, crc_err_reg, sticky_ovf_reg, 1'b1}; end
                            4'd2: begin tx_byte <= cycle_timer[31:24];                         crc_data_in <= cycle_timer[31:24]; end
                            4'd3: begin tx_byte <= cycle_timer[23:16];                         crc_data_in <= cycle_timer[23:16]; end
                            4'd4: begin tx_byte <= cycle_timer[15:8];                          crc_data_in <= cycle_timer[15:8]; end
                            4'd5: begin tx_byte <= cycle_timer[7:0];                           crc_data_in <= cycle_timer[7:0]; end
                            4'd6: begin tx_byte <= 8'd0;                                       crc_data_in <= 8'd0; end
                            4'd7: begin tx_byte <= TOTAL_DRAIN_BYTES[7:0];                     crc_data_in <= TOTAL_DRAIN_BYTES[7:0]; end
                        endcase

                        if (resp_hdr_idx == 4'd7) begin
                            resp_hdr_idx <= '0;
                            if (crc_err_reg || cmd_reg == CMD_RESET_ACC) begin
                                state <= ST_SEND_CRC;
                            end else begin
                                state <= ST_DRAIN_FIFO;
                            end
                        end else begin
                            resp_hdr_idx <= resp_hdr_idx + 1'b1;
                        end
                    end
                end

                ST_DRAIN_FIFO: begin
                    if (tx_ready && !tx_valid) begin
                        if (!fifo_empty) begin
                            tx_valid       <= 1'b1;
                            tx_byte        <= fifo_data_out;
                            fifo_rd_en     <= 1'b1;
                            crc_data_valid <= 1'b1;
                            crc_data_in    <= fifo_data_out;
                        end else begin
                            state <= ST_SEND_CRC;
                        end
                    end
                end

                ST_SEND_CRC: begin
                    if (tx_ready && !tx_valid) begin
                        tx_valid <= 1'b1;
                        tx_byte  <= calculated_crc; // Send final response CRC
                        state    <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // Output status
    assign hw_cycle_count = cycle_timer;
    assign state_leds     = state;

    // ------------------------------------------------------------------------
    // Assertion-Based Verification (ABV)
    // ------------------------------------------------------------------------
    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            // Ready/valid protocol assertion: tx_valid must hold until acknowledged by tx_ready
            if ($past(tx_valid && !tx_ready && !rst)) begin
                assert (tx_valid)
                    else $error("[ABV ERROR] FSM tx_valid dropped prematurely before tx_ready!");
            end

            // Deterministic compute duration check
            if ($past(state == ST_COMPUTE && comp_cycle_cnt == (COMPUTE_CYCLES - 1))) begin
                assert (state == ST_LATCH_DRAIN)
                    else $error("[ABV ERROR] FSM failed to enter ST_LATCH_DRAIN at exact cycle K+2N-2!");
            end
        end
    end
    `endif

endmodule
