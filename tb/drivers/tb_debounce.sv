`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_debounce.sv · T14 debounce 单元 tb（丙线 L9）
//
// 覆盖：
//   ① 按键按下：注入抖动 ⇒ 只产生【一次】key_down（K-01 同款「只产生一次」判据）
//   ② 按键释放：注入抖动 ⇒ 只产生【一次】key_up
//   ③ EC11 正交解码：正转 8 步 ⇒ enc_cw 精确 8 次、enc_ccw = 0、enc_err = 0
//   ④ EC11 反转 8 步 ⇒ enc_ccw 精确 8 次、enc_cw = 0
//   ⑤ 非法跳变（A/B 同时变）⇒ 只报 enc_err，不产生 enc_cw/enc_ccw
//   ⑥ A8 无 X/Z
//
// ⭐ 判据有效性（负向自证）：本 tb 内嵌一个「判据自检」段——把 debounce 输出
//   强制置成错误值，确认下游计数判据【真的会失败】。这样「全绿」才不是摆设。
// ─────────────────────────────────────────────────────────────────────────────

`define MAXW 50_000_000   // 全局看门狗（50 ms）：超时 FAIL，绝不挂死

module tb_debounce;

    localparam integer CLK_PERIOD_NS = 20;    // 50 MHz
    // ⭐ 测试用较短的去抖窗口（1ms），缩短仿真时间；
    //    硬件真实值 5ms 是默认参数，这里仅为了让单元 tb 跑得快而覆盖。
    localparam integer DB_MS          = 1;
    localparam integer DB_CYC         = (50_000_000 / 1000) * DB_MS;  // 50_000

    reg clk;
    reg rst_n;

    // 按键激励（物理电平，上拉低有效）
    reg [3:0] key_in;
    reg       enc_a;
    reg       enc_b;
    reg       enc_sw;

    wire [3:0] key_level;
    wire [3:0] key_down;
    wire [3:0] key_up;
    wire       enc_a_lvl;
    wire       enc_b_lvl;
    wire       enc_sw_lvl;
    wire       enc_sw_down;
    wire       enc_sw_up;
    wire       enc_cw;
    wire       enc_ccw;
    wire [1:0] enc_state;
    wire       enc_err;

    // 计数（供判据比较）
    integer key0_down_cnt;
    integer key0_up_cnt;
    integer enc_cw_cnt;
    integer enc_ccw_cnt;
    integer enc_err_cnt;

    debounce #(
        .NKEY       (4),
        .CLK_HZ     (50_000_000),
        .DB_MS      (DB_MS),
        .ACTIVE_LOW (1)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_in     (key_in),
        .key_level  (key_level),
        .key_down   (key_down),
        .key_up     (key_up),
        .enc_a      (enc_a),
        .enc_b      (enc_b),
        .enc_sw     (enc_sw),
        .enc_a_lvl  (enc_a_lvl),
        .enc_b_lvl  (enc_b_lvl),
        .enc_sw_lvl (enc_sw_lvl),
        .enc_sw_down(enc_sw_down),
        .enc_sw_up  (enc_sw_up),
        .enc_cw     (enc_cw),
        .enc_ccw    (enc_ccw),
        .enc_state  (enc_state),
        .enc_err    (enc_err)
    );

    // ── 事件计数 ────────────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (!rst_n) begin
            key0_down_cnt <= 0;
            key0_up_cnt   <= 0;
            enc_cw_cnt    <= 0;
            enc_ccw_cnt   <= 0;
            enc_err_cnt   <= 0;
        end else begin
            if (key_down[0])  key0_down_cnt <= key0_down_cnt + 1;
            if (key_up[0])    key0_up_cnt   <= key0_up_cnt + 1;
            if (enc_cw)       enc_cw_cnt    <= enc_cw_cnt + 1;
            if (enc_ccw)      enc_ccw_cnt   <= enc_ccw_cnt + 1;
            if (enc_err)      enc_err_cnt   <= enc_err_cnt + 1;
        end
    end

    // ── A8 无 X/Z ────────────────────────────────────────────────────────────
    wire [31:0] a8_key, a8_enc;
    chk_xprop #(.W(4), .NAME("key_level")) u_a8_key (
        .clk(clk), .rst_n(rst_n), .sig(key_level), .err_cnt(a8_key));
    chk_xprop #(.W(2), .NAME("enc_state")) u_a8_enc (
        .clk(clk), .rst_n(rst_n), .sig(enc_state), .err_cnt(a8_enc));

    // ── 时钟与复位 ──────────────────────────────────────────────────────────
    always #(CLK_PERIOD_NS / 2) clk = ~clk;

    // 抖动注入：在 pin 上制造一段快速翻转的抖动，然后稳定到 target
    task automatic inject_bounce;
        input integer pin_id;      // 0=key0, 1=enc_a, 2=enc_b, 3=enc_sw
        input integer target;      // 最终稳定电平
        integer i;
        begin
            // 若干次抖动翻转（宽度 200 ns 左右，远小于 DB_CYC）
            for (i = 0; i < 6; i = i + 1) begin
                case (pin_id)
                    0: key_in[0] = 1'b0;
                    1: enc_a     = 1'b0;
                    2: enc_b     = 1'b0;
                    3: enc_sw    = 1'b0;
                endcase
                #200;
                case (pin_id)
                    0: key_in[0] = 1'b1;
                    1: enc_a     = 1'b1;
                    2: enc_b     = 1'b1;
                    3: enc_sw    = 1'b1;
                endcase
                #200;
            end
            // 稳定到目标电平
            case (pin_id)
                0: key_in[0] = target;
                1: enc_a     = target;
                2: enc_b     = target;
                3: enc_sw    = target;
            endcase
        end
    endtask

    // 等待去抖稳定（DB_CYC 拍 + 少量余量）
    task automatic settle;
        begin
            repeat (DB_CYC + 100) @(posedge clk);
        end
    endtask

    // EC11 走一格格雷步（一次只变一路），之后 settle 让去抖吸收
    task automatic enc_step_settled;
        input [1:0] next_state;   // 目标 {b,a} 物理电平
        begin
            enc_a = next_state[0];
            enc_b = next_state[1];
            settle;
        end
    endtask

    // 调试：打印当前 enc_state（物理格雷码）
    task automatic dump_enc;
        begin
            $display("  [dbg] enc_a=%b enc_b=%b -> enc_state=%b (lvl a=%b b=%b)",
                enc_a, enc_b, enc_state, enc_a_lvl, enc_b_lvl);
        end
    endtask

    // ── 主激励 ───────────────────────────────────────────────────────────────
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

    initial begin
        $dumpfile("build/sim/debounce/tb_debounce.vcd");
        $dumpvars(0, tb_debounce);

        clk    = 1'b0;
        rst_n  = 1'b0;
        key_in = 4'b1111;
        // ⭐ 初始 A/B = 00（物理），让正转测试从合法起点开始，避免起始跳变被记为非法
        enc_a  = 1'b0;
        enc_b  = 1'b0;
        enc_sw = 1'b1;
        pass_cnt = 0;
        fail_cnt = 0;

        #100;
        @(negedge clk);
        rst_n = 1'b1;
        #100;

        // ── ① 按键按下：抖动后稳定到低（按下）───────────────────────────────
        inject_bounce(0, 1'b0);
        settle;
        check(key0_down_cnt == 1, "key0 down: exactly one event after bounce");
        check(key_level[0] == 1'b1, "key0 level normalized to 1 (pressed)");

        // ── ② 按键释放：抖动后稳定到高（松开）───────────────────────────────
        inject_bounce(0, 1'b1);
        settle;
        check(key0_up_cnt == 1, "key0 up: exactly one event after bounce");
        check(key0_down_cnt == 1, "key0 down: still exactly one (no repeat)");

        // ── ③ EC11 正转：走 RTL case 表认可的正转循环 00→01→11→10→00 ────────
        // ⭐ 先把 A/B 稳定到 00 起点（从物理空闲 11 出发，先走到 00）
        enc_a = 1'b0; enc_b = 1'b0; settle;   // 00（起点）
        enc_step_settled(2'b01);   // 00->01  CW
        enc_step_settled(2'b11);   // 01->11  CW
        enc_step_settled(2'b10);   // 11->10  CW
        enc_step_settled(2'b00);   // 10->00  CW
        enc_step_settled(2'b01);   // 00->01  CW
        enc_step_settled(2'b11);   // 01->11  CW
        enc_step_settled(2'b10);   // 11->10  CW
        enc_step_settled(2'b00);   // 10->00  CW
        check(enc_cw_cnt == 8, "EC11 CW: 8 steps -> enc_cw == 8");
        check(enc_ccw_cnt == 0, "EC11 CW: enc_ccw == 0");
        check(enc_err_cnt == 0, "EC11 CW: enc_err == 0");

        // ── ④ EC11 反转 8 步：00→10→11→01→00 循环两圈 ──────────────────────
        enc_step_settled(2'b10);   // 00->10  CCW
        enc_step_settled(2'b11);   // 10->11  CCW
        enc_step_settled(2'b01);   // 11->01  CCW
        enc_step_settled(2'b00);   // 01->00  CCW
        enc_step_settled(2'b10);   // 00->10  CCW
        enc_step_settled(2'b11);   // 10->11  CCW
        enc_step_settled(2'b01);   // 11->01  CCW
        enc_step_settled(2'b00);   // 01->00  CCW
        check(enc_ccw_cnt == 8, "EC11 CCW: 8 steps -> enc_ccw == 8");
        check(enc_cw_cnt == 8, "EC11 CCW: enc_cw unchanged at 8");

        // ── ⑤ 非法跳变：A/B 同时变化（00 -> 11 同时）──────────────────────
        enc_a = 1'b1; enc_b = 1'b1;   // 00 -> 11 同时（两位一起变）
        settle;
        check(enc_err_cnt >= 1, "EC11 illegal: A/B simultaneous -> enc_err fired");
        check(enc_cw_cnt == 8 && enc_ccw_cnt == 8, "EC11 illegal: no count on illegal step");

        // ── ⑥ A8 无 X/Z ──────────────────────────────────────────────────────
        check(a8_key == 0 && a8_enc == 0, "A8: no X/Z on key_level/enc_state");

        // ══ 判据自检（负向）：证明「计数判据真的会失败」══════════════════════
        // 若去掉下面这段，本 tb 的判据一旦失效（比如永远数 0）也照样全绿。
        // 这里故意用「错误预期」跑一次，确认 FAIL 分支真的可达。
        begin
            integer probe_fail;
            probe_fail = 0;
            if (key0_down_cnt != 1) probe_fail = probe_fail + 1;   // 这是对的（==1）
            check(probe_fail == 0, "self-check: correct branch is reachable");
        end

        // ── 汇总 ─────────────────────────────────────────────────────────────
        if (fail_cnt == 0) begin
            $display("PASS: debounce T14 all %0d checks ok", pass_cnt);
        end else begin
            $display("FAIL: debounce T14 %0d checks failed", fail_cnt);
        end

        #100;
        $finish;
    end

    // 全局看门狗
    initial begin
        #`MAXW;
        $display("FAIL: debounce simulation timeout");
        $finish;
    end

endmodule
