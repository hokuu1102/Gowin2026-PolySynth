`timescale 1ns/1ps

// Dedicated Tang Mega 60K Dock bring-up top for the W1-2 pROM proof.
// This is intentionally separate from rtl/top.v. It drives one fixed 440 Hz
// DDS oscillator through the real Gowin pROM and the production I2S transmitter.
module wavetable_tone_top #(
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter integer BCLK_DIV       = 16,
    parameter integer MCLK_DIV       = 4,
    // round(440 * 2^32 / 48828.125) = 38,702,809
    parameter integer TONE_PHASE_INC = 38_702_809,
    parameter integer PA_ON_DELAY    = 1_048_576,
    parameter integer HEARTBEAT_DIV  = 25_000_000
) (
    input  wire clk,
    input  wire rst_n,
    output wire HP_BCK,
    output wire HP_WS,
    output wire HP_DIN,
    output wire PA_EN_n,
    output wire led_heartbeat
);

    wire rst_n_sync;
    rst_sync #(.STAGES(2)) u_rst_sync (
        .clk         (clk),
        .rst_n_async (rst_n),
        .rst_n_sync  (rst_n_sync)
    );

    wire tick_audio;
    wire mclk_en;
    wire bclk_en;
    wire bclk_half_en;
    wire lrclk;
    wire frame_start;

    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .BCLK_DIV       (BCLK_DIV),
        .MCLK_DIV       (MCLK_DIV)
    ) u_clk_gen (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .tick_audio   (tick_audio),
        .mclk_en      (mclk_en),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .lrclk        (lrclk),
        .frame_start  (frame_start)
    );

    wire signed [15:0] wavetable_sample;
    wire               wavetable_valid;

    dds_wavetable_core u_dds_wavetable_core (
        .clk_i         (clk),
        .rst_n_i       (rst_n_sync),
        .sample_tick_i (tick_audio),
        .phase_inc_i   (TONE_PHASE_INC[31:0]),
        .sample_o      (wavetable_sample),
        .valid_o       (wavetable_valid)
    );

    // Hold each pROM response for the next I2S frame. The pROM latency is only
    // one system-clock cycle, leaving more than 1000 clocks before consumption.
    reg signed [15:0] sample_hold;
    always @(posedge clk) begin
        if (!rst_n_sync)
            sample_hold <= 16'sd0;
        else if (wavetable_valid)
            sample_hold <= wavetable_sample;
    end

    // Start at quarter scale for safe first sound. i2s_tx sends the high 16 bits
    // of SAMPLE_W, so the attenuated 16-bit word is left-aligned in 24 bits.
    wire signed [15:0] sample_quarter = sample_hold >>> 2;
    wire signed [23:0] sample_mono = {sample_quarter, 8'b0};

    i2s_tx #(
        .SAMPLE_W  (24),
        .DATA_BITS (16),
        .SLOT_BITS (32),
        .JUSTIFY   (1),
        .MSB_DELAY (1),
        .LRCK_POL  (0)
    ) u_i2s_tx (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .bclk_en      (bclk_en),
        .bclk_half_en (bclk_half_en),
        .frame_start  (frame_start),
        .sample_l     (sample_mono),
        .sample_r     (sample_mono),
        .HP_BCK       (HP_BCK),
        .HP_WS        (HP_WS),
        .HP_DIN       (HP_DIN)
    );

    // NS4263 control: one delayed falling edge selects AB bridge mode, then the
    // pin stays low. Board and FPGA pull-ups keep the amplifier off at startup.
    localparam integer PA_CNT_W = (PA_ON_DELAY < 2) ? 1 : $clog2(PA_ON_DELAY + 1);
    reg [PA_CNT_W-1:0] pa_cnt;
    reg                pa_done;
    reg                pa_en_n_r;

    always @(posedge clk) begin
        if (!rst_n_sync) begin
            pa_cnt    <= {PA_CNT_W{1'b0}};
            pa_done   <= 1'b0;
            pa_en_n_r <= 1'b1;
        end else if (!pa_done) begin
            if (pa_cnt < PA_ON_DELAY[PA_CNT_W-1:0]) begin
                pa_cnt    <= pa_cnt + 1'b1;
                pa_en_n_r <= 1'b1;
            end else begin
                pa_done   <= 1'b1;
                pa_en_n_r <= 1'b0;
            end
        end
    end

    assign PA_EN_n = pa_en_n_r;

    reg [31:0] hb_cnt;
    reg        hb;
    always @(posedge clk) begin
        if (!rst_n_sync) begin
            hb_cnt <= 32'd0;
            hb     <= 1'b0;
        end else if (hb_cnt >= HEARTBEAT_DIV - 1) begin
            hb_cnt <= 32'd0;
            hb     <= ~hb;
        end else begin
            hb_cnt <= hb_cnt + 1'b1;
        end
    end

    assign led_heartbeat = hb;

endmodule
