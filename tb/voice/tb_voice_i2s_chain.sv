`timescale 1ns/1ps

module tb_voice_i2s_chain;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer SAMPLE_W       = 24;
    localparam integer DATA_BITS      = 16;
    localparam integer N_FRAMES       = 1024;
    localparam [31:0]  INC_FS_DIV_64  = 32'd67_108_864;
    localparam integer SUSTAIN_LEVEL  = 65_025;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg        rst_n    = 1'b0;
    reg        note_on  = 1'b0;
    reg        note_off = 1'b0;
    reg [31:0] note_inc = INC_FS_DIV_64;

    wire HP_BCK;
    wire HP_WS;
    wire HP_DIN;
    wire tick_audio;
    wire signed [SAMPLE_W-1:0] sample_dbg;
    wire voice_done;
    wire [31:0] phase_acc;
    wire [31:0] phase_inc;

    voice_i2s_chain #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .ATTACK_STEP    (65_535),
        .DECAY_STEP     (65_535),
        .SUSTAIN_Q8     (255),
        .RELEASE_STEP   (65_535)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .note_on_i      (note_on),
        .note_off_i     (note_off),
        .note_inc_i     (note_inc),
        .HP_BCK         (HP_BCK),
        .HP_WS          (HP_WS),
        .HP_DIN         (HP_DIN),
        .tick_audio_o   (tick_audio),
        .sample_dbg_o   (sample_dbg),
        .voice_done_o   (voice_done),
        .phase_acc_dbg_o(phase_acc),
        .phase_inc_dbg_o(phase_inc)
    );

    wire signed [SAMPLE_W-1:0] rx_l;
    wire signed [SAMPLE_W-1:0] rx_r;
    wire signed [SAMPLE_W-1:0] recon_l;
    wire signed [SAMPLE_W-1:0] recon_r;
    wire rx_valid_l;
    wire rx_valid_r;

    i2s_rx_model #(
        .SAMPLE_W      (SAMPLE_W),
        .DATA_BITS     (DATA_BITS),
        .SLOT_BITS     (32),
        .JUSTIFY       (1),
        .MSB_DELAY     (1),
        .LRCK_POL      (0),
        .RECON_FILTER  (0)
    ) u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .bck      (HP_BCK),
        .ws       (HP_WS),
        .din      (HP_DIN),
        .sample_l (rx_l),
        .sample_r (rx_r),
        .valid_l  (rx_valid_l),
        .valid_r  (rx_valid_r),
        .recon_l  (recon_l),
        .recon_r  (recon_r)
    );

    reg signed [15:0] golden_wavetable [0:511];
    reg signed [SAMPLE_W-1:0] frame_expected [0:N_FRAMES+16];

    integer errors = 0;
    integer tx_count = 0;
    integer rx_count_l = 0;
    integer rx_count_r = 0;
    integer point_ok_l = 0;
    integer point_ok_r = 0;
    integer golden_ok = 0;
    integer golden_bad = 0;
    integer done_count = 0;
    integer fd;
    integer addr;
    reg signed [32:0] golden_product;
    reg signed [32:0] golden_zero;
    reg signed [16:0] golden_scaled;

    initial begin
        $readmemh("rtl/w3b/rom/sine_512x16.hex", golden_wavetable);
        fd = $fopen("sim/evidence/voice_i2s_chain_l.csv", "w");
        $fdisplay(fd, "# T10 decoded left channel; fs=48828.125 Hz; expected tone=762.939453125 Hz");

        $dumpfile("build/sim/tb_voice_i2s_chain/tb_voice_i2s_chain.vcd");
        $dumpvars(0, tb_voice_i2s_chain);

        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (8) @(negedge clk);
        note_on = 1'b1;
        @(negedge clk);
        note_on = 1'b0;

        repeat (CLK_PER_SAMPLE * (N_FRAMES + 8)) @(posedge clk);
        #1;
        $fclose(fd);

        if (point_ok_l < N_FRAMES - 4 || point_ok_r < N_FRAMES - 4) begin
            $display("FAIL: decoded I2S did not match committed voice samples: L=%0d R=%0d", point_ok_l, point_ok_r);
            errors = errors + 1;
        end
        if (golden_ok < N_FRAMES - 16 || golden_bad != 0) begin
            $display("FAIL: voice samples did not match wavetable/envelope golden: ok=%0d bad=%0d", golden_ok, golden_bad);
            errors = errors + 1;
        end
        if (rx_count_l < N_FRAMES || rx_count_r < N_FRAMES) begin
            $display("FAIL: insufficient decoded frames: L=%0d R=%0d expected>=%0d", rx_count_l, rx_count_r, N_FRAMES);
            errors = errors + 1;
        end

        $display("T10_CHAIN decoded_l=%0d decoded_r=%0d point_ok_l=%0d point_ok_r=%0d golden_ok=%0d golden_bad=%0d",
                 rx_count_l, rx_count_r, point_ok_l, point_ok_r, golden_ok, golden_bad);
        if (errors == 0)
            $display("PASS: real DDS+ADSR voice round-trips through I2S and matches the golden samples");
        else
            $display("FAIL: T10 voice/I2S chain had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // i2s_tx commits sample_dbg when tick_audio/frame_start is observed.
    always @(posedge clk) begin
        if (rst_n && tick_audio && tx_count < N_FRAMES + 16) begin
            frame_expected[tx_count] = sample_dbg;
            tx_count = tx_count + 1;
        end

        if (rst_n && voice_done) begin
            done_count = done_count + 1;
            if (done_count > 6) begin
                addr = ((phase_acc - phase_inc) >> 23) & 9'h1ff;
                golden_product = $signed(golden_wavetable[addr]) * SUSTAIN_LEVEL;
                golden_zero = golden_product[32]
                              ? golden_product + 33'sd65535
                              : golden_product;
                golden_scaled = golden_zero >>> 16;
                if (sample_dbg[SAMPLE_W-1 -: DATA_BITS] === golden_scaled[15:0])
                    golden_ok = golden_ok + 1;
                else begin
                    golden_bad = golden_bad + 1;
                    if (golden_bad <= 4)
                        $display("FAIL: golden mismatch done=%0d addr=%0d got=%0d expected=%0d",
                                 done_count, addr, $signed(sample_dbg[SAMPLE_W-1 -: DATA_BITS]),
                                 $signed(golden_scaled[15:0]));
                end
            end
        end

        if (rst_n && rx_valid_l) begin
            if (rx_count_l < tx_count &&
                rx_l[SAMPLE_W-1 -: DATA_BITS] === frame_expected[rx_count_l][SAMPLE_W-1 -: DATA_BITS])
                point_ok_l = point_ok_l + 1;
            else if (rx_count_l < N_FRAMES)
                errors = errors + 1;

            if (rx_count_l >= 16 && rx_count_l < N_FRAMES + 16)
                $fdisplay(fd, "%0d", $signed(rx_l[SAMPLE_W-1 -: DATA_BITS]));
            rx_count_l = rx_count_l + 1;
        end

        if (rst_n && rx_valid_r) begin
            if (rx_count_r < tx_count &&
                rx_r[SAMPLE_W-1 -: DATA_BITS] === frame_expected[rx_count_r][SAMPLE_W-1 -: DATA_BITS])
                point_ok_r = point_ok_r + 1;
            else if (rx_count_r < N_FRAMES)
                errors = errors + 1;
            rx_count_r = rx_count_r + 1;
        end
    end

    initial begin
        #30_000_000;
        $fatal(1, "FAIL: tb_voice_i2s_chain timeout");
    end

endmodule
