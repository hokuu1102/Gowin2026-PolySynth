`timescale 1ns/1ps

// T31b audible-separation acceptance at the existing envelope_bank seam.
// Four voices receive the same gate and velocity; only timbre differs.
module tb_timbre_adsr;
    localparam integer POLY = 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg [POLY-1:0] gate = 4'b0000;
    reg [POLY-1:0] retrig_reset = 4'b0000;
    reg [POLY*8-1:0] velocity = {POLY{8'hFF}};
    reg [POLY*2-1:0] timbre = {2'd3, 2'd2, 2'd1, 2'd0};
    wire [POLY*16-1:0] env_level;
    wire [POLY-1:0] env_active;
    integer errors = 0;

    wire [15:0] bass   = env_level[0*16 +: 16];
    wire [15:0] guitar = env_level[1*16 +: 16];
    wire [15:0] piano  = env_level[2*16 +: 16];
    wire [15:0] pad    = env_level[3*16 +: 16];

    always #10 clk = ~clk;

    envelope_bank #(.POLY_TARGET(POLY)) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(gate), .velocity_i(velocity),
        .retrig_reset_i(retrig_reset), .timbre_i(timbre),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    //  ⭐⭐ P5-1（2026-10-03）契约变更：⭐ `envelope_bank` 现在是**共享引擎 +
    //     每拍服务一个 voice**（⭐ 见 `rtl/w3b/envelope_bank.v` 的文件头）⇒
    //     第 v 路要 **tick 后第 (2+v) 拍**才落盘（⭐ 本 tb `POLY=4` ⇒ 共 5 拍）。
    //     ⭐ 每个采样拍后面补 8 拍等待，让轮转走完 ——
    //     ⛔ **判据（期望值/次序）一个字没改**，⭐ 只是补了等待。
    //     📌 副作用：⭐ 每个采样拍从 2 拍变成 10 拍 ⇒ 总仿真时间 ×5
    //        ⇒ ⭐ 下面的看门狗预算同步放大（⭐ 见文件末尾）。
    task automatic tick_n(input integer count);
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(negedge clk); sample_tick = 1'b1;
                @(negedge clk); sample_tick = 1'b0;
                repeat (8) @(negedge clk);
            end
            #1;
        end
    endtask

    task automatic fail(input [8*96-1:0] message);
        begin
            $display("FAIL: %0s levels=%0d/%0d/%0d/%0d active=%b",
                     message, bass, guitar, piano, pad, env_active);
            errors = errors + 1;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        gate = 4'b1111;
        // GUITAR/PIANO are fast attacks, BASS is slightly slower, and PAD is
        // deliberately slow.  This is the first perceptual separation axis.
        tick_n(101);
        if (^env_level === 1'bx)
            fail("envelope contains X during attack");
        if (!(pad < bass && bass < guitar && bass < piano))
            fail("attack ordering is not timbre-specific");

        // Allow every voice to settle.  Original sound-design sustain order:
        // PAD 0.9 > BASS 0.7 > PIANO 0.4 > GUITAR 0.3.
        tick_n(45_000);
        if (^env_level === 1'bx)
            fail("envelope contains X at sustain");
        if (!(pad > bass && bass > piano && piano > guitar))
            fail("sustain ordering does not match four timbre recipes");

        gate = 4'b0000;
        tick_n(8_000);
        if (bass != 16'd0 || env_active !== 4'b1110)
            fail("BASS must release before GUITAR/PIANO/PAD");

        tick_n(12_000);
        if (guitar != 16'd0 || piano == 16'd0 || pad == 16'd0 ||
            env_active !== 4'b1100)
            fail("GUITAR must release before PIANO/PAD");

        tick_n(7_000);
        if (piano != 16'd0 || pad == 16'd0 || env_active !== 4'b1000)
            fail("PIANO must release before PAD");

        if (errors == 0)
            $display("PASS: four timbres have distinct ADSR profiles");
        else
            $fatal(1, "FAIL: timbre ADSR found %0d error(s)", errors);
        $finish;
    end

    initial begin
        //  ⭐ P5-1：⭐ 采样拍周期从 2 拍变 10 拍（⭐ 见 `tick_n` 的说明）
        //     ⇒ ⭐ 看门狗预算同步放大（⭐ 原 5 ms ⇒ 50 ms）
        #50_000_000;
        $fatal(1, "FAIL: tb_timbre_adsr timeout");
    end
endmodule
