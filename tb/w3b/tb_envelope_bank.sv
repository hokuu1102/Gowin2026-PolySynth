`timescale 1ns/1ps

module tb_envelope_bank;

    localparam integer POLY = 4;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg                    rst_n       = 1'b0;
    reg                    sample_tick = 1'b0;
    reg  [POLY-1:0]         gate        = {POLY{1'b0}};
    reg  [POLY*8-1:0]       velocity    = {(POLY*8){1'b0}};
    wire [POLY*16-1:0]      env_level;
    wire [POLY-1:0]         env_active;

    wire [15:0] env0 = env_level[0*16 +: 16];
    wire [15:0] env1 = env_level[1*16 +: 16];
    wire [15:0] env2 = env_level[2*16 +: 16];
    wire [15:0] env3 = env_level[3*16 +: 16];

    integer errors = 0;

    envelope_bank #(
        .POLY_TARGET (POLY),
        .ATTACK_STEP (16_384),
        .DECAY_STEP  (8_192),
        .SUSTAIN_Q8  (128),
        .RELEASE_STEP(4_096)
    ) dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (sample_tick),
        .gate_i        (gate),
        .velocity_i    (velocity),
        .env_level_o   (env_level),
        .env_active_o  (env_active)
    );

    //  ⭐⭐ P5-1（2026-10-03）契约变更：⭐ `envelope_bank` 现在是**共享引擎 +
    //     每拍服务一个 voice**（⭐ 见 `rtl/w3b/envelope_bank.v` 的文件头）⇒
    //     第 v 路要 **tick 后第 (2+v) 拍**才落盘（⭐ 本 tb `POLY=4` ⇒ 共 5 拍）。
    //     ⭐ 因此 `tick()` 必须**等轮转走完**再让判据采样 ——
    //     ⛔ **判据（期望值）一个字没改**，⭐ 只是补了等待。
    task automatic tick;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
            repeat (8) @(negedge clk);
            #1;
        end
    endtask

    task automatic expect_levels(
        input [15:0] e0,
        input [15:0] e1,
        input [15:0] e2,
        input [15:0] e3,
        input [3:0]  active_mask
    );
        begin
            if (env0 !== e0 || env1 !== e1 || env2 !== e2 || env3 !== e3 || env_active !== active_mask) begin
                $display("FAIL: levels got=%0d/%0d/%0d/%0d active=%b expected=%0d/%0d/%0d/%0d active=%b",
                         env0, env1, env2, env3, env_active, e0, e1, e2, e3, active_mask);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_envelope_bank/tb_envelope_bank.vcd");
        $dumpvars(0, tb_envelope_bank);

        velocity[0*8 +: 8] = 8'd255;
        velocity[1*8 +: 8] = 8'd128;
        velocity[2*8 +: 8] = 8'd64;
        velocity[3*8 +: 8] = 8'd32;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        tick();
        expect_levels(0, 0, 0, 0, 4'b0000);

        gate[0] = 1'b1;
        tick();
        expect_levels(0, 0, 0, 0, 4'b0001);
        tick();
        expect_levels(16_384, 0, 0, 0, 4'b0001);

        gate[1] = 1'b1;
        tick();
        expect_levels(32_768, 0, 0, 0, 4'b0011);
        tick();
        expect_levels(49_152, 16_384, 0, 0, 4'b0011);

        // Releasing voice 0 must not reset or stall voice 1.
        gate[0] = 1'b0;
        tick();
        expect_levels(49_152, 32_768, 0, 0, 4'b0011);
        tick();
        expect_levels(45_056, 24_576, 0, 0, 4'b0011);

        // A third gate starts from zero without perturbing the two older voices.
        gate[2] = 1'b1;
        tick();
        expect_levels(40_960, 16_384, 0, 0, 4'b0111);
        tick();
        expect_levels(36_864, 16_384, 16_384, 0, 4'b0111);

        if (errors == 0)
            $display("PASS: envelope_bank keeps per-voice ADSR state independent");
        else
            $display("FAIL: envelope_bank independence had %0d error(s)", errors);

        $finish(errors != 0);
    end

    initial begin
        #2_000_000;
        $fatal(1, "FAIL: tb_envelope_bank timeout");
    end

endmodule
