`timescale 1ns/1ps
// ============================================================================
//  tb_led_indicator.sv -- 指示层（第 2 层）验收
//
//  ⭐⭐ 2026-10-15：按【控制板第 3 版】改成 8 颗灯（用户裁定"灯序一起改"）
//  ---------------------------------------------------------
//  出处：files/20-代码/控制板16键功能映射-20261013.md（第 3 版）
//    led0 音色       : 0=白 1=青 2=紫 3=橙             （常亮）
//    led1 16 键行为  : 指板=橙 · 键盘=绿 · 键盘打鼓=蓝+快闪（覆盖）
//    led2 推子功能   : 0=紫(变调) 1=青(颤音) 2=黄(摇把/将来效果页) 3=灭(无)
//    led3 节奏       : 鼓机关+节拍器关=灭 · 鼓机关+节拍器开=绿
//                      鼓机开=节奏型色 · 节拍器开 ⇒ 每拍【暗】100 ms
//    led4 looper     : 空闲=暗蓝常亮 · 录音=红快闪 · 回放=绿常亮 · 武装中=黄快闪
//    led5 EC11+音高  : 变调>0=暖橙 · <0=冷蓝 · =0=灭 · 滑音=青；
//                      EC11 动过 ⇒ 临时 黄(BPM)/紫(音高)，1 秒后回落
//    led6 HDMI       : 波形=蓝 · 李萨如=品红 · FFT=绿（⭐ 2026-10-15：三档）
//    led7 效果器     : 关=灭 · 开=按 sel 分色（失真橙红/合唱青/延迟紫/混响绿）
//
//  🔴 **与上一版的语义变化（必须知道）**：
//     · 7 颗 → 8 颗；灯序整个变了
//     · 节拍器旧版 = "无拍点灭、拍点亮"；第 3 版 = **常绿 + 每拍暗一下**
//       ⇒ 所以"(0b) 开但无拍点 = 灭"这条**改成 = 绿**（不是 bug，是契约变了）
//
//  ⭐ 两条纪律（都是本项目踩过的坑）
//  -----------------------------------
//   ① **判据写【字面量】**（`X_*` 那些 localparam）—— 不引用 DUT 的 localparam，
//      否则"改 DUT 的表"会连带改判据 ⇒ 判据恒绿（与 C83 探针假绿同族）
//   ② **省资源的手法也要被钉住**：快闪计数器全模块共享一个 ⇒
//      本 tb 不只查"颜色对不对"，还量出快闪周期（2^FAST_DIV）
//      与拍点闪时长（FLASH_CYC）⇒ 有人把两路接成不同相位/写死常数会红
//
//  ⭐⭐ 两个 DUT 实例（这就是"闪烁也能测"的原因）
//  ------------------------------------------------
//    · `u_prod`：生产参数（FAST_DIV=23 / FLASH_CYC=5_000_000）
//    · `u_fast`：FAST_DIV=10 / FLASH_CYC=20_000
//      ⇒ 快闪周期与占空比、拍点闪精确时长都在几千拍内量出来
//    📌 两者共享同一组激励 ⇒ 同一份激励下两套参数的输出必须各自自洽
//
//  ⚠️ 为什么不在 u_prod 上量满 5_000_000 拍：实测 5 M 拍 ≈ 103 s
//     （vvp 在本设计上约 48 k 拍/s）⇒ 逼近 120 s 预算，并行时会假超时
//     ⇒ 改成"精确长度在参数化实例上量 + 生产实例只钉下界"
//
//  MUTATION EVIDENCE（两次真变异，都实测跑过、都变红）
//  ---------------------------------------------------------
//    M1 led_indicator.v 音色 2'd1 由 C_CYAN 改成 C_VIOLET ⇒ (1b) 红
//    M2 led_indicator.v 输出级去掉 fast_off 门控 ⇒ (7c) 快闪周期红
//    ⛔ 两个变异都只改 RTL、不改本 tb ⇒ 判据是打在 RTL 上的
// ============================================================================
`default_nettype none

module tb_led_indicator;

    localparam integer NCH          = 8;
    localparam integer FAST_DIV_TB  = 10;        // 快闪周期 = 2^10 = 1024 拍
    localparam integer FLASH_CYC_TB = 20000;     // 拍点闪时长 = 20000 拍（精确量）
    localparam integer FLASH_PROD   = 5000000;   // 生产默认 FLASH_CYC
    localparam integer PROD_FLOOR   = 500000;    // 生产实例只钉下界：等 500 k 拍仍须亮
    localparam integer ENC_HOLD_TB  = 30000;     // EC11 临时色保持（参数化实例用短的）

    // ── 判据用的颜色（字面量；不引用 DUT 的 localparam）────────────────────
    localparam [23:0] X_OFF      = 24'h000000;
    localparam [23:0] X_WHITE    = 24'hFFFFFF;
    localparam [23:0] X_CYAN     = 24'h00FFFF;
    localparam [23:0] X_VIOLET   = 24'h8000FF;
    localparam [23:0] X_ORANGE   = 24'hFF8000;
    localparam [23:0] X_GREEN    = 24'h00FF00;
    localparam [23:0] X_RED      = 24'hFF0000;
    localparam [23:0] X_MAGENTA  = 24'hFF00FF;
    localparam [23:0] X_YELLOW   = 24'hFFFF00;
    localparam [23:0] X_ORRED    = 24'hFF4000;
    localparam [23:0] X_BLUE     = 24'h0000FF;
    localparam [23:0] X_DIMBLUE  = 24'h000030;
    localparam [23:0] X_COOLBLUE = 24'h0080FF;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    // ── 激励（两个实例共享）────────────────────────────────────────────────
    reg [1:0] timbre;
    reg       fb_mode;
    reg       keydrum;
    reg [1:0] gear;
    reg       metro_on;
    reg       beat;
    reg       drum_on;
    reg [1:0] drum_pat;
    reg [1:0] looper;
    reg signed [4:0] transpose;
    reg       slide;
    reg       enc_act;
    reg       enc_obj;
    reg  [1:0] scope_mode;         // ⭐ 2026-10-15：三档（波形/李萨如/FFT）
    reg       fx_en;
    reg [1:0] fx_sel;

    wire [NCH*24-1:0] col_prod;
    wire [NCH*24-1:0] col_fast;

    led_indicator #(.N_CH(NCH)) u_prod (
        .clk(clk), .rst_n(rst_n),
        .timbre_i(timbre), .fb_mode_i(fb_mode), .keydrum_i(keydrum),
        .gear_i(gear), .metro_on_i(metro_on), .beat_i(beat),
        .drum_on_i(drum_on), .drum_pat_i(drum_pat), .looper_i(looper),
        .transpose_i(transpose), .slide_i(slide),
        .enc_act_i(enc_act), .enc_obj_i(enc_obj),
        .scope_mode_i(scope_mode), .fx_en_i(fx_en), .fx_sel_i(fx_sel),
        .led_col_o(col_prod)
    );

    led_indicator #(.N_CH(NCH), .FAST_DIV(FAST_DIV_TB), .FLASH_CYC(FLASH_CYC_TB),
                    .ENC_HOLD_CYC(ENC_HOLD_TB)) u_fast (
        .clk(clk), .rst_n(rst_n),
        .timbre_i(timbre), .fb_mode_i(fb_mode), .keydrum_i(keydrum),
        .gear_i(gear), .metro_on_i(metro_on), .beat_i(beat),
        .drum_on_i(drum_on), .drum_pat_i(drum_pat), .looper_i(looper),
        .transpose_i(transpose), .slide_i(slide),
        .enc_act_i(enc_act), .enc_obj_i(enc_obj),
        .scope_mode_i(scope_mode), .fx_en_i(fx_en), .fx_sel_i(fx_sel),
        .led_col_o(col_fast)
    );

    // ── A8：复位释放后输出上不许有 X/Z ──────────────────────────────────────
    reg [31:0] a8_err_prod, a8_err_fast;
    chk_xprop #(.W(NCH*24), .NAME("led_col_o(prod)")) u_a8p (
        .clk(clk), .rst_n(rst_n), .sig(col_prod), .err_cnt(a8_err_prod)
    );
    chk_xprop #(.W(NCH*24), .NAME("led_col_o(fast)")) u_a8f (
        .clk(clk), .rst_n(rst_n), .sig(col_fast), .err_cnt(a8_err_fast)
    );

    // ── 记账 ────────────────────────────────────────────────────────────────
    integer errors = 0;
    integer jj;
    reg     okall;
    reg [NCH*24-1:0] base_cols;

    integer n_cyc, n_fast, n_on, n_edge, n_other, first_e, last_e, period;
    integer prev_e, min_iv, max_iv;
    integer ti, pi, k;
    reg     lit, prev_lit;

    task chk(input [8*256-1:0] name, input cond);
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task exp_ch(input [8*256-1:0] name, input [NCH*24-1:0] bus,
                input integer idx, input [23:0] want);
        begin
            if (bus[idx*24 +: 24] === want)
                $display("  ok  : %0s [led%0d] = %06h", name, idx, want);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s [led%0d] = %06h want %06h", name, idx,
                         bus[idx*24 +: 24], want);
            end
        end
    endtask

    // 只允许第 idx 颗变（防"表接错线 / mux 串线"）
    task exp_only(input [8*256-1:0] name, input [NCH*24-1:0] got,
                  input [NCH*24-1:0] ref_cols, input integer idx, input [23:0] want);
        begin
            okall = (got[idx*24 +: 24] === want);
            for (jj = 0; jj < NCH; jj = jj + 1)
                if ((jj != idx) && (got[jj*24 +: 24] !== ref_cols[jj*24 +: 24]))
                    okall = 1'b0;
            if (okall)
                $display("  ok  : %0s (only led%0d changed -> %06h)", name, idx, want);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (led%0d = %06h want %06h, or some OTHER led moved too)",
                         name, idx, got[idx*24 +: 24], want);
            end
        end
    endtask

    //  ⭐ 基准驱动：把所有输入设成一个确定的"安静"状态
    task drive_all(input [1:0] t, input fbm, input kd, input [1:0] gr,
                   input m_on, input d_on, input [1:0] dp, input [1:0] lp,
                   input signed [4:0] tr, input sl, input ea, input eo,
                   input [1:0] sm, input fe, input [1:0] fs);
        begin
            @(negedge clk);
            timbre = t; fb_mode = fbm; keydrum = kd; gear = gr;
            metro_on = m_on; drum_on = d_on; drum_pat = dp; looper = lp;
            transpose = tr; slide = sl; enc_act = ea; enc_obj = eo;
            scope_mode = sm; fx_en = fe; fx_sel = fs;
            @(negedge clk); @(negedge clk);          // 输出级是寄存的 ⇒ 等它落定
        end
    endtask

    //  ⭐ 常用的"安静"基准（只有 led4 暗蓝 + led6 蓝 亮着）
    task drive_idle;
        begin
            drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                      5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        end
    endtask

    task pulse_beat;
        begin
            @(negedge clk); beat = 1'b1;
            @(negedge clk); beat = 1'b0;
            @(negedge clk);                          // 再等一拍
        end
    endtask

    task pulse_enc;
        begin
            @(negedge clk); enc_act = 1'b1;
            @(negedge clk); enc_act = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        drive_idle;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ════════════════════════════════════════════════════════════════════
        // (0) 节拍器：第 3 版语义 = 常绿 + 每拍暗一下
        //   🔴 与上一版不同：旧版"开但无拍点 = 灭"，第 3 版 = **绿**
        //      理由：文档写"绿 = 鼓机关但节拍器开" ⇒ 底色是绿的，拍点只是让它暗一下
        // ════════════════════════════════════════════════════════════════════
        $display("=== (0) 节拍器：常绿 + 每拍暗一下（第 3 版语义）===");
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b1, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(0a) metro on, no beat yet = 绿（底色）", col_prod, 3, X_GREEN);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(0b) metro off = 灭", col_prod, 3, X_OFF);

        // ════════════════════════════════════════════════════════════════════
        // (1) 音色 4 档（led0）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (1) 音色 4 档（led0）===");
        drive_idle;
        exp_ch("(1a) timbre 0", col_prod, 0, X_WHITE);
        drive_all(2'd1, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(1b) timbre 1", col_prod, 0, X_CYAN);
        drive_all(2'd2, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(1c) timbre 2", col_prod, 0, X_VIOLET);
        drive_all(2'd3, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(1d) timbre 3", col_prod, 0, X_ORANGE);

        // ════════════════════════════════════════════════════════════════════
        // (2) 单路独立性（一次只动一路输入 ⇒ 只许那一颗灯变）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (2) 单路独立性 ===");
        drive_idle;
        base_cols = col_prod;                        // 基准：只有 led4 暗蓝 + led6 蓝

        drive_all(2'd1, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_only("(2a) timbre 0->1 only moves led0", col_prod, base_cols, 0, X_CYAN);

        drive_all(2'd0, 1'b1, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_only("(2b) fb_mode 0->1 only moves led1", col_prod, base_cols, 1, X_ORANGE);

        drive_all(2'd0, 1'b0, 1'b0, 2'd1, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_only("(2c) gear 3->1 only moves led2", col_prod, base_cols, 2, X_CYAN);

        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b1, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_only("(2d) drum on only moves led3", col_prod, base_cols, 3, X_RED);

        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd2,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_only("(2e) looper play only moves led4", col_prod, base_cols, 4, X_GREEN);

        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd3, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_only("(2f) transpose 0->+3 only moves led5", col_prod, base_cols, 5, X_ORANGE);

        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 2'd0);
        exp_only("(2g) scope_mode 0->1 only moves led6", col_prod, base_cols, 6, X_MAGENTA);

        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0);
        exp_only("(2h) fx_en 0->1 only moves led7", col_prod, base_cols, 7, X_ORRED);

        // ════════════════════════════════════════════════════════════════════
        // (3) 八路同时给不同状态（防"串线"的最强一条）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (3) 八路组合 ===");
        drive_all(2'd3, 1'b1, 1'b0, 2'd2, 1'b0, 1'b1, 2'd3, 2'd0,
                  -5'sd2, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 2'd2);
        exp_ch("(3) combo led0 (timbre 3)",      col_prod, 0, X_ORANGE);
        exp_ch("(3) combo led1 (fretboard)",     col_prod, 1, X_ORANGE);
        exp_ch("(3) combo led2 (gear 2)",        col_prod, 2, X_YELLOW);
        exp_ch("(3) combo led3 (drum 3)",        col_prod, 3, X_ORRED);
        exp_ch("(3) combo led4 (loop idle)",     col_prod, 4, X_DIMBLUE);
        exp_ch("(3) combo led5 (transpose -2)",  col_prod, 5, X_COOLBLUE);
        exp_ch("(3) combo led6 (lissajous)",     col_prod, 6, X_MAGENTA);
        exp_ch("(3) combo led7 (fx sel 2)",      col_prod, 7, X_VIOLET);

        // ════════════════════════════════════════════════════════════════════
        // (4) 鼓机 4 个节奏型 + 关 = 灭（led3）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (4) 鼓机（led3）===");
        drive_idle;
        exp_ch("(4a) drum off", col_prod, 3, X_OFF);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b1, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(4b) drum pat 0", col_prod, 3, X_RED);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b1, 2'd1, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(4c) drum pat 1", col_prod, 3, X_MAGENTA);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b1, 2'd2, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(4d) drum pat 2", col_prod, 3, X_YELLOW);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b1, 2'd3, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(4e) drum pat 3", col_prod, 3, X_ORRED);
        //  鼓机 + 节拍器同开 ⇒ 底色仍是节奏型色（节拍器只让它暗一下）
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b1, 1'b1, 2'd1, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(4f) drum+metro: base is still the pattern colour", col_prod, 3, X_MAGENTA);

        // ════════════════════════════════════════════════════════════════════
        // (5) 16 键行为（led1）· 推子档位（led2）· looper 4 态（led4）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (5) 16 键行为 / 推子 / looper ===");
        drive_all(2'd0, 1'b0, 1'b1, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5a) keydrum on = 蓝", col_prod, 1, X_BLUE);
        drive_all(2'd0, 1'b1, 1'b1, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5b) keydrum OVERRIDES the mode (still blue)", col_prod, 1, X_BLUE);
        drive_idle;
        exp_ch("(5c) keyboard mode = 绿", col_prod, 1, X_GREEN);

        drive_all(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5d) gear 0 = 变调", col_prod, 2, X_VIOLET);
        drive_all(2'd0, 1'b0, 1'b0, 2'd1, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5e) gear 1 = 颤音", col_prod, 2, X_CYAN);
        drive_all(2'd0, 1'b0, 1'b0, 2'd2, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5f) gear 2 = 摇把(预留，将来效果页)", col_prod, 2, X_YELLOW);
        drive_idle;
        exp_ch("(5g) gear 3 = 无 ⇒ 灭", col_prod, 2, X_OFF);

        drive_idle;
        exp_ch("(5h) looper 空闲 = 暗蓝常亮", col_prod, 4, X_DIMBLUE);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd2,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5i) looper 回放 = 绿常亮", col_prod, 4, X_GREEN);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd3,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(5j) looper 武装中 = 黄（快闪，见 (7)）", col_prod, 4, X_YELLOW);

        // ════════════════════════════════════════════════════════════════════
        // (6) led5（EC11+音高）· led6（HDMI）· led7（效果器）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (6) led5 音高 / led6 HDMI / led7 效果器 ===");
        drive_idle;
        exp_ch("(6a) transpose 0 = 灭", col_prod, 5, X_OFF);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd7, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(6b) transpose > 0 = 暖橙", col_prod, 5, X_ORANGE);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  -5'sd7, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(6c) transpose < 0 = 冷蓝", col_prod, 5, X_COOLBLUE);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd7, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(6d) slide OVERRIDES transpose = 青", col_prod, 5, X_CYAN);

        //  EC11 临时色（分时）：动过 ⇒ 显示"它现在管什么"，1 秒后回落
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd7, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 2'd0);
        exp_ch("(6e) EC11 active, obj=BPM = 黄", col_prod, 5, X_YELLOW);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd7, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 2'd0);
        exp_ch("(6f) EC11 active, obj=pitch = 紫", col_prod, 5, X_VIOLET);

        drive_idle;
        exp_ch("(6g) HDMI waveform = 蓝", col_prod, 6, X_BLUE);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 2'd0);
        exp_ch("(6h) HDMI lissajous = 品红", col_prod, 6, X_MAGENTA);
        //  ⭐⭐ 2026-10-15 新增：第三档 FFT
        //     🔴 这条判据就是为那个【位宽截断 bug】加的 ——
        //        修之前 scope_mode_i 只有 1 位 ⇒ 2'd2 截断成 0 ⇒ 这里会显示"蓝"⇒ 红 ✅
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 2'd2, 1'b0, 2'd0);
        exp_ch("(6h2) HDMI FFT = 绿（⛔ 不是波形的蓝）", col_prod, 6, X_GREEN);

        drive_idle;
        exp_ch("(6i) fx off = 灭", col_prod, 7, X_OFF);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0);
        exp_ch("(6j) fx on sel=0 (失真) = 橙红", col_prod, 7, X_ORRED);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 2'd1);
        exp_ch("(6k) fx on sel=1 (合唱) = 青", col_prod, 7, X_CYAN);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 2'd2);
        exp_ch("(6l) fx on sel=2 (延迟) = 紫", col_prod, 7, X_VIOLET);
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 2'd3);
        exp_ch("(6m) fx on sel=3 (混响，留位) = 绿", col_prod, 7, X_GREEN);

        // ════════════════════════════════════════════════════════════════════
        // (7) 闪烁：快闪周期（参数化实例精确量）+ 拍点闪时长
        // ════════════════════════════════════════════════════════════════════
        $display("=== (7) 闪烁 ===");
        //  拍点闪：第 3 版语义 = 常绿 + 每拍【暗】FLASH_CYC 拍
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b1, 1'b0, 2'd0, 2'd0,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        pulse_beat();
        exp_ch("(7a) beat = 暗（立即，第 3 版语义）", col_prod, 3, X_OFF);
        exp_ch("(7a) beat = 暗（立即, fast）",        col_fast, 3, X_OFF);

        //  参数化实例：精确量"暗多久"（应 == FLASH_CYC_TB 拍）
        n_cyc = 0; n_fast = -1;
        while ((n_cyc < FLASH_CYC_TB + 1000) && (n_fast < 0)) begin
            if (col_fast[3*24 +: 24] === X_GREEN) n_fast = n_cyc;
            @(negedge clk);
            n_cyc = n_cyc + 1;
        end
        //  生产实例：只钉下界 —— 等 500 k 拍（10 ms）仍须是暗的
        for (n_cyc = 0; n_cyc < PROD_FLOOR; n_cyc = n_cyc + 1) @(negedge clk);

        $display("  info: 生产默认 FLASH_CYC = %0d 拍（= 100 ms @50 MHz）", FLASH_PROD);
        $display("  info: beat-dark length  fast=%0d (want %0d);  prod still dark after %0d",
                 n_fast, FLASH_CYC_TB, PROD_FLOOR);
        chk("(7b) 拍点暗时长 == FLASH_CYC（参数化实例，精确）",
            (n_fast >= FLASH_CYC_TB - 3) && (n_fast <= FLASH_CYC_TB + 3));
        chk("(7c) 生产实例过了 500 k 拍仍然是暗的 ⇒ 默认拉伸是长的",
            col_prod[3*24 +: 24] === X_OFF);
        chk("(7d) 此时参数化实例已回绿（prod 与 fast 不同步 ⇒ 参数真的生效）",
            col_fast[3*24 +: 24] === X_GREEN);

        //  快闪：looper 录音 = 红快闪（量 8 个周期）
        drive_all(2'd0, 1'b0, 1'b0, 2'd3, 1'b0, 1'b0, 2'd0, 2'd1,
                  5'sd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        //  判据用【相邻两个上升沿的最小/最大间隔】—— 不用"(末−首)/(边数−1)"：
        //  后者会把"窗口首尾各半个周期"平均进去 ⇒ 差几十拍（第一版实测 974）
        n_on = 0; n_edge = 0; n_other = 0; first_e = -1; last_e = -1;
        prev_e = -1; min_iv = 1000000; max_iv = -1;
        prev_lit = 1'b0;
        for (k = 0; k < 8*1024; k = k + 1) begin
            lit = (col_fast[4*24 +: 24] === X_RED);
            if (lit) n_on = n_on + 1;
            if ((col_fast[4*24 +: 24] !== X_RED) && (col_fast[4*24 +: 24] !== X_OFF))
                n_other = n_other + 1;
            if (lit && !prev_lit) begin
                n_edge = n_edge + 1;
                if (first_e < 0) first_e = k;
                if (prev_e >= 0) begin
                    if ((k - prev_e) < min_iv) min_iv = k - prev_e;
                    if ((k - prev_e) > max_iv) max_iv = k - prev_e;
                end
                prev_e = k;
                last_e = k;
            end
            prev_lit = lit;
            @(negedge clk);
        end
        period = (n_edge >= 2) ? ((last_e - first_e) / (n_edge - 1)) : -1;
        $display("  info: rec blink: edges=%0d on=%0d/%0d iv=[%0d..%0d] (want %0d) other_col=%0d",
                 n_edge, n_on, 8*1024, min_iv, max_iv, (1 << FAST_DIV_TB), n_other);

        chk("(7e) 录音 = 红【快闪】：相邻上升沿间隔恒 == 2^FAST_DIV",
            (n_edge >= 6) && (min_iv == (1 << FAST_DIV_TB)) && (max_iv == (1 << FAST_DIV_TB)));
        chk("(7f) 快闪占空比 ≈ 50%", (n_on > 8*1024*45/100) && (n_on < 8*1024*55/100));
        chk("(7g) 录音时只有 红 / 灭 两种颜色（不串别的颜色）", n_other == 0);
        chk("(7h) 录音时确实在闪（不是常亮）", n_edge >= 6);

        // ════════════════════════════════════════════════════════════════════
        // (8) A8：无 X/Z
        // ════════════════════════════════════════════════════════════════════
        drive_idle;
        chk("(8) no X/Z on led_col_o after reset (A8, 两个实例)",
            (a8_err_prod == 32'd0) && (a8_err_fast == 32'd0));

        if (errors == 0)
            $display("PASS: led_indicator -- 8 路语义（控制板第 3 版）+ 共享快闪 + 拍点闪 + 参数化闪烁全部成立");
        else
            $fatal(1, "FAIL: led_indicator has %0d error(s)", errors);
        $finish;
    end

    // 看门狗：本 tb 仿真时间约 11 ms（生产实例要等 500 k 拍）
    //   20 ms 上限足够；一挂就报 FAIL（而不是让 tb_all.ps1 干等 120 s）
    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_led_indicator timeout");
    end

endmodule

`default_nettype wire
