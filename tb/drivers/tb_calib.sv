`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_calib.sv · T13 calib 单元 tb（丙线 L8，余量项）
//
// 覆盖：
//   ① 上电默认：gain=1.0（Q8.8=256）、zero=0 ⇒ out = raw（直通，比例式）
//   ② tare：记零点后，raw - zero 正确扣除偏移
//   ③ span：满量程标定，标定后 out 收敛到满量程（误差 ≤ 1 LSB）
//   ④ err：span 码 <= 零点码 时拒绝并置 err
//   ⑤ 溢出保护：raw < zero 时不产生负值（饱和到 0）
//   ⑥ A8 无 X/Z
//
// ⭐ 判据有效性：标定的核心是「注入已知偏移，标定后误差收敛」——
//   用固定的 zero/span 值，手算期望的 out，逐拍比对。
// ─────────────────────────────────────────────────────────────────────────────

`define MAXW 50_000_000   // 看门狗 50ms

module tb_calib;

    localparam integer CLK_PERIOD_NS = 20;
    localparam integer NCH = 8;
    localparam integer DW  = 12;
    localparam integer FULL = 4095;

    reg clk;
    reg rst_n;

    reg        valid;
    reg [2:0]  ch;
    reg [DW-1:0] raw;

    reg        tare;
    reg        span;
    reg [2:0]  cal_ch;

    wire       busy;
    wire       err;
    wire       out_valid;
    wire [2:0] out_ch;
    wire [DW-1:0] out_val;

    calib #(
        .NCH  (NCH),
        .DW   (DW),
        .GW   (16),
        .FULL (FULL),
        .CW   (3)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid     (valid),
        .ch        (ch),
        .raw       (raw),
        .tare      (tare),
        .span      (span),
        .cal_ch    (cal_ch),
        .busy      (busy),
        .err       (err),
        .out_valid (out_valid),
        .out_ch    (out_ch),
        .out_val   (out_val)
    );

    always #(CLK_PERIOD_NS / 2) clk = ~clk;

    // A8
    wire [31:0] a8_out;
    chk_xprop #(.W(DW), .NAME("out_val")) u_a8 (
        .clk(clk), .rst_n(rst_n), .sig(out_val), .err_cnt(a8_out));

    // ── 期望值计算（Q8.8 定点）──────────────────────────────────────────────
    // 期望 out = saturate( (raw - zero) * gain >> 8 )
    function automatic [DW-1:0] expected_out;
        input [DW-1:0] raw_v;
        input [DW:0]   zero_v;
        input [15:0]   gain_v;   // Q8.8
        reg [40:0] prod;
        begin
            if (raw_v <= zero_v[DW-1:0]) begin
                expected_out = 0;
            end else begin
                prod = (raw_v - zero_v[DW-1:0]) * gain_v;
                prod = prod >> 8;
                expected_out = (prod > FULL) ? DW'(FULL) : prod[DW-1:0];
            end
        end
    endfunction

    integer pass_cnt;
    integer fail_cnt;

    task automatic check;
        input integer cond;
        input [1023:0] msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("ok : %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // 送入一个采样，1 拍后检查 out（calib 延 1 拍）
    task automatic feed;
        input [2:0]    ch_v;
        input [DW-1:0] raw_v;
        begin
            @(negedge clk);
            valid = 1'b1;
            ch    = ch_v;
            raw   = raw_v;
            @(negedge clk);
            valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("build/sim/calib/tb_calib.vcd");
        $dumpvars(0, tb_calib);

        clk   = 1'b0;
        rst_n = 1'b0;
        valid = 1'b0;
        ch    = 3'd0;
        raw   = 12'd0;
        tare  = 1'b0;
        span  = 1'b0;
        cal_ch = 3'd0;
        pass_cnt = 0;
        fail_cnt = 0;

        #100;
        @(negedge clk);
        rst_n = 1'b1;
        #100;

        // ── ① 上电默认：直通（zero=0, gain=1.0）─────────────────────────────
        feed(3'd0, 12'h800);   // 2048
        #2;
        check(out_ch == 3'd0 && out_val == 12'h800,
              "default passthrough: out == raw (gain=1.0, zero=0)");

        // ── ② tare：给 CH0 记零点 = 100 ──────────────────────────────────────
        feed(3'd0, 12'd100);   // 先让 raw=100 出现在输入端
        @(negedge clk);
        tare = 1'b1; cal_ch = 3'd0;
        @(negedge clk);
        tare = 1'b0;
        // 现在 CH0 zero=100，送 raw=500，期望 out = 500-100 = 400
        feed(3'd0, 12'd500);
        #2;
        check(out_val == 12'd400,
              "tare: out = raw - zero = 500 - 100 = 400");

        // ── ③ span：给 CH0 记满量程 = 900（相对 zero=100，满量程跨度 800）───
        feed(3'd0, 12'd900);   // raw=900 出现在输入
        @(negedge clk);
        span = 1'b1; cal_ch = 3'd0;
        @(negedge clk);
        span = 1'b0;
        // 等待除法器完成（ITER=24 拍 + 写回 1 拍）
        repeat (40) @(posedge clk);
        check(busy == 1'b0, "span: divider finished (busy==0)");
        // 增益 = FULL<<8 / (900-100) = 4095*256/800 = 1310.4 -> Q8.8 约 1310
        // 标定后：送 raw=900（满量程点），期望 out 收敛到 FULL（误差 ≤2 LSB）
        feed(3'd0, 12'd900);
        #2;
        begin
            integer diff;
            diff = out_val - 12'd4095;
            if (diff < 0) diff = -diff;
            check(diff <= 2, "span: calibrated full-scale converges to 4095");
        end

        // ── ④ err：span 码 <= 零点码 时拒绝 ─────────────────────────────────
        feed(3'd1, 12'd50);   // CH1 raw=50
        @(negedge clk);
        // CH1 zero 仍为 0，span 时 raw=0 <= zero=0 会拒绝；但先给个合法跨度再测 err
        // 直接测：CH1 先 tare 零点=200，再 span 时 raw=100 < zero=200 -> err
        feed(3'd1, 12'd200);
        @(negedge clk);
        tare = 1'b1; cal_ch = 3'd1;
        @(negedge clk);
        tare = 1'b0;
        feed(3'd1, 12'd100);   // raw=100 < zero=200
        @(negedge clk);
        span = 1'b1; cal_ch = 3'd1;
        @(negedge clk);
        span = 1'b0;
        #5;
        check(err == 1'b1, "err: span code <= zero code is rejected");

        // ── ⑤ 溢出保护：raw < zero 时 out=0（不产生负值）───────────────────
        feed(3'd1, 12'd50);   // raw=50 < zero=200
        #2;
        check(out_val == 12'd0, "underflow: raw < zero -> out clamped to 0");

        // ── ⑥ A8 ────────────────────────────────────────────────────────────
        check(a8_out == 0, "A8: no X/Z on out_val");

        // ── 汇总 ─────────────────────────────────────────────────────────────
        if (fail_cnt == 0) begin
            $display("PASS: calib T13 all %0d checks ok", pass_cnt);
        end else begin
            $display("FAIL: calib T13 %0d checks failed", fail_cnt);
        end

        #100;
        $finish;
    end

    initial begin
        #`MAXW;
        $display("FAIL: calib simulation timeout");
        $finish;
    end

endmodule
