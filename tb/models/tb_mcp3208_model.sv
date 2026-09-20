`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_mcp3208_model · MCP3208 从机模型（S1）的单元 tb（T2 要求：模型各自自证）
//
// 验证目标：
//   1. 模型能按 DS21298E 帧格式回 12 位结果（B11 先出）；
//   2. 通道号 D2/D1/D0 正确解码（镜像检测）；
//   3. IDVAL 决定返回基准值（不同片返回不同，用于 MISO 独立性验证）。
//
// 判定约定：结论用 FAIL:（带冒号）。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_mcp3208_model;

    localparam integer HALF_NS = 500;   // 1 MHz SCLK 半周期

    reg  cs_n;
    reg  sclk;
    reg  mosi;
    wire miso;

    mcp3208_model #(.IDVAL(12'h400)) dut (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso));

    // 主机侧：发一个 24 bit 命令（5 引导零 + START=1 + SGL=1 + D2D1D0 + 填充）
    // 命令 = {5'b00000, 1'b1, 1'b1, D2,D1,D0, 14'd0}
    reg [23:0] cmd;
    reg [11:0] got;
    integer    i;

    task automatic do_conversion(input [2:0] ch);
        reg [11:0] expected;
        begin
            cmd = {5'b00000, 1'b1, 1'b1, ch, 14'd0};

            // CS 拉低启动
            cs_n = 1'b0;
            #10;

            got = 12'd0;

            // 24 个 SCLK
            for (i = 0; i < 24; i = i + 1) begin
                sclk = 1'b0;
                mosi = cmd[23];          // MSB 先发
                #HALF_NS;
                sclk = 1'b1;
                #HALF_NS;
                cmd = {cmd[22:0], 1'b0};
                // 在第 13 个上升沿起采样 DOUT（模型第 12 个下降沿后送 B11）
                if (i >= 12) begin
                    got = {got[10:0], miso};
                end
            end

            // CS 拉高结束
            sclk = 1'b0;
            cs_n = 1'b1;
            #10;

            // 期望值 = IDVAL + ch
            expected = 12'h400 + ch;
            if (got !== expected) begin
                $fatal(1, "FAIL: ch%0d got=%03h expected=%03h", ch, got, expected);
            end
            else begin
                $display("PASS CH%0d: model returned %03h", ch, got);
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/mcp3208_model/tb_mcp3208_model.vcd");
        $dumpvars(0, tb_mcp3208_model);

        cs_n = 1'b1;
        sclk = 1'b0;
        mosi = 1'b0;
        cmd  = 24'd0;
        got  = 12'd0;
        i    = 0;

        #100;

        do_conversion(3'd0);
        do_conversion(3'd1);
        do_conversion(3'd7);

        $display("PASS: mcp3208_model returns IDVAL+channel correctly");
        #100;
        $finish;
    end

    initial begin
        #200_000;
        $fatal(1, "FAIL: mcp3208_model simulation timeout");
    end

endmodule

`default_nettype wire
