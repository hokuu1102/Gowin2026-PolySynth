`timescale 1ns/1ps
// ============================================================================
//  tb_led_indicator.sv -- 指示层（第 2 层）验收
//
//  ⭐ 被测契约（⭐ 用户 2026-10-03 给定的 7 路语义，⛔ 不许改）
//  ---------------------------------------------------------
//    led0 音色      : 0=白 1=青 2=紫 3=橙   （常亮）
//    led1 节拍器    : 关=灭 · 开=拍点闪绿（每次 beat_i 亮一段）
//    led2 鼓机      : 关=灭 · 0=红 1=洋红 2=黄 3=橙红
//    led3 键盘打鼓  : 关=灭 · 开=蓝
//    led4 looper    : 空闲=暗蓝常亮 · 录音=红快闪 · 回放=绿常亮
//    led5 推子功能  : 0=紫(变调) 1=青(颤音) 2=黄(摇把) 3=灭(无)
//    led6 指板/键盘 : 指板=橙 · 键盘=绿
//
//  ⭐ 两条纪律（⭐ 都是本项目踩过的坑）
//  -----------------------------------
//   ① **判据写【字面量】**（`X_*` 那些 localparam）—— ⛔ 不引用 DUT 的 localparam，
//      ⚠️ 否则"改 DUT 的表"会**连带改判据** ⇒ 判据恒绿（⭐ 与 `C83` 探针假绿同族）
//   ② **省资源的手法也要被钉住**：⭐ 快闪计数器**全模块共享一个** ⇒
//      ⭐ 本 tb 不只查"颜色对不对"，还**量出快闪周期**（`2^FAST_DIV`）
//      与**拍点闪时长**（`FLASH_CYC`）⇒ ⚠️ 有人把两路接成不同相位/写死常数会红
//
//  ⭐⭐ 两个 DUT 实例（⭐ 这就是"闪烁也能测"的原因）
//  ------------------------------------------------
//    · `u_prod`：**生产参数**（`FAST_DIV=23` / `FLASH_CYC=5_000_000`）
//      ⇒ ⭐ 颜色判据 + ⭐ "拍点闪**确实很长**"（⭐ 真的等 500 k 拍 = 10 ms 仿真）
//    · `u_fast`：`FAST_DIV=10` / `FLASH_CYC=20_000`
//      ⇒ ⭐ 快闪**周期**与占空比、拍点闪**精确时长**都在几千拍内量出来
//    📌 两者**共享同一组激励** ⇒ ⭐ 同一份激励下两套参数的输出必须各自自洽 ✅
//
//  ⚠️ 为什么⛔ 不在 `u_prod` 上量满 5_000_000 拍：⭐ 实测 **5 M 拍 ≈ 103 s**
//     （⭐ vvp 在本设计上约 **48 k 拍/s**）⇒ ⚠️ 逼近 `tb_all.ps1` 的 120 s 预算，
//     一旦与别的任务并行就会**假超时**（⭐ 与"重 tb 误报 TIMEOUT"同族）
//     ⇒ ⭐ 改成"精确长度在参数化实例上量 + 生产实例只钉**下界**"（⭐ 两处都能红）✅
//
//  MUTATION EVIDENCE（⭐ 两次真变异，⭐ 都实测跑过、都【变红】）
//  ---------------------------------------------------------
//    M1 `rtl/w3a/led_indicator.v` 音色 `2'd1` 由 `C_CYAN` 改成 `C_VIOLET`
//        ⇒ (1a) 音色档红 ✅
//    M2 `rtl/w3a/led_indicator.v` 输出级**去掉** `fast_off` 门控
//        （`(blk==BL_FAST) && fast_off` 改成 `1'b0`）⇒ (7c) 快闪周期红 ✅
//    ⛔ 两个变异都只改 RTL、⛔ 不改本 tb ⇒ 判据是**打在 RTL 上**的
// ============================================================================
`default_nettype none

module tb_led_indicator;

    localparam integer NCH          = 7;
    localparam integer FAST_DIV_TB  = 10;        // 快闪周期 = 2^10 = 1024 拍
    localparam integer FLASH_CYC_TB = 20000;     // 拍点闪时长 = 20000 拍（⭐ 精确量）
    localparam integer FLASH_PROD   = 5000000;   // ⭐ 生产默认 `FLASH_CYC`
    localparam integer PROD_FLOOR   = 500000;    // ⭐ 生产实例只钉下界：等 500 k 拍仍须亮

    // ── 判据用的颜色（⭐ 字面量；⛔ 不引用 DUT 的 localparam）────────────────
    localparam [23:0] X_OFF     = 24'h000000;
    localparam [23:0] X_WHITE   = 24'hFFFFFF;
    localparam [23:0] X_CYAN    = 24'h00FFFF;
    localparam [23:0] X_VIOLET  = 24'h8000FF;
    localparam [23:0] X_ORANGE  = 24'hFF8000;
    localparam [23:0] X_GREEN   = 24'h00FF00;
    localparam [23:0] X_RED     = 24'hFF0000;
    localparam [23:0] X_MAGENTA = 24'hFF00FF;
    localparam [23:0] X_YELLOW  = 24'hFFFF00;
    localparam [23:0] X_ORRED   = 24'hFF4000;
    localparam [23:0] X_BLUE    = 24'h0000FF;
    localparam [23:0] X_DIMBLUE = 24'h000030;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    // ── 激励（⭐ 两个实例共享）──────────────────────────────────────────────
    reg [1:0] timbre;
    reg       metro_on;
    reg       beat;
    reg       drum_on;
    reg [1:0] drum_pat;
    reg       keydrum;
    reg [1:0] looper;
    reg [1:0] gear;
    reg       fb_mode;

    wire [NCH*24-1:0] col_prod;
    wire [NCH*24-1:0] col_fast;

    led_indicator #(.N_CH(NCH)) u_prod (
        .clk(clk), .rst_n(rst_n),
        .timbre_i(timbre), .metro_on_i(metro_on), .beat_i(beat),
        .drum_on_i(drum_on), .drum_pat_i(drum_pat), .keydrum_i(keydrum),
        .looper_i(looper), .gear_i(gear), .fb_mode_i(fb_mode),
        .led_col_o(col_prod)
    );

    led_indicator #(.N_CH(NCH), .FAST_DIV(FAST_DIV_TB), .FLASH_CYC(FLASH_CYC_TB)) u_fast (
        .clk(clk), .rst_n(rst_n),
        .timbre_i(timbre), .metro_on_i(metro_on), .beat_i(beat),
        .drum_on_i(drum_on), .drum_pat_i(drum_pat), .keydrum_i(keydrum),
        .looper_i(looper), .gear_i(gear), .fb_mode_i(fb_mode),
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

    // 量测用
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

    // ⭐ 只允许第 idx 颗变（⭐ 防"表接错线 / mux 串线"）
    //   ⚠️ 参数名⛔ 不能叫 `ref` —— ⭐ 它是 SystemVerilog 关键字（`ref` 端口方向）
    //      ⇒ iverilog 报 "Syntax error in task/function port declaration"（⭐ 已踩）
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

    task drive(input [1:0] t, input m_on, input d_on, input [1:0] dp, input kd,
               input [1:0] lp, input [1:0] gr, input fbm);
        begin
            @(negedge clk);
            timbre = t; metro_on = m_on; drum_on = d_on; drum_pat = dp;
            keydrum = kd; looper = lp; gear = gr; fb_mode = fbm;
            @(negedge clk); @(negedge clk);          // ⭐ 输出级是寄存的 ⇒ 等它落定
        end
    endtask

    task pulse_beat;
        begin
            @(negedge clk); beat = 1'b1;
            @(negedge clk); beat = 1'b0;
            @(negedge clk);                          // ⭐ 再等一拍 ⇒ "绿"已打出
        end
    endtask

    initial begin
        timbre = 2'd0; metro_on = 1'b0; beat = 1'b0; drum_on = 1'b0;
        drum_pat = 2'd0; keydrum = 1'b0; looper = 2'd0; gear = 2'd3; fb_mode = 1'b0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ════════════════════════════════════════════════════════════════════
        // (0) 节拍器"开、但还没有拍点" ⇒ 灭
        //   🔴 为什么必须放在【任何拍点之前】：⭐ 生产实例的拍点拉伸长达 100 ms
        //      ⇒ ⚠️ 一旦发过拍点，后面几十万拍里它【本来就该是绿的】
        //      ⇒ ⭐ 这条判据只能在这里做（⭐ 已实测踩到：放在 (6) 里必假红）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (0) 节拍器：开但无拍点 ===");
        drive(2'd0, 1'b1, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(0b) metro on, no beat yet = 灭",        col_prod, 1, X_OFF);
        exp_ch("(0b) metro on, no beat yet = 灭 (fast)", col_fast, 1, X_OFF);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);

        // ════════════════════════════════════════════════════════════════════
        // (1) 音色 4 档
        // ════════════════════════════════════════════════════════════════════
        $display("=== (1) 音色 4 档（led0）===");
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(1a) timbre 0", col_prod, 0, X_WHITE);
        drive(2'd1, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(1b) timbre 1", col_prod, 0, X_CYAN);
        drive(2'd2, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(1c) timbre 2", col_prod, 0, X_VIOLET);
        drive(2'd3, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(1d) timbre 3", col_prod, 0, X_ORANGE);

        // ════════════════════════════════════════════════════════════════════
        // (2) 单路独立性（⭐ 一次只动一路输入 ⇒ 只许那一颗灯变）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (2) 单路独立性 ===");
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        base_cols = col_prod;                        // 基准：只有 led4 暗蓝 + led6 绿 亮着

        drive(2'd1, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_only("(2a) timbre 0->1 only moves led0", col_prod, base_cols, 0, X_CYAN);

        drive(2'd0, 1'b1, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        pulse_beat();
        exp_only("(2b) metro beat only moves led1", col_prod, base_cols, 1, X_GREEN);

        drive(2'd0, 1'b0, 1'b1, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_only("(2c) drum on only moves led2", col_prod, base_cols, 2, X_RED);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b1, 2'd0, 2'd3, 1'b0);
        exp_only("(2d) keydrum only moves led3", col_prod, base_cols, 3, X_BLUE);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd2, 2'd3, 1'b0);
        exp_only("(2e) looper play only moves led4", col_prod, base_cols, 4, X_GREEN);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd1, 1'b0);
        exp_only("(2f) gear 3->1 only moves led5", col_prod, base_cols, 5, X_CYAN);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b1);
        exp_only("(2g) fb_mode 0->1 only moves led6", col_prod, base_cols, 6, X_ORANGE);

        // ════════════════════════════════════════════════════════════════════
        // (3) 七路同时给不同状态（⭐ 防"串线"的最强一条）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (3) 七路组合 ===");
        drive(2'd3, 1'b1, 1'b1, 2'd3, 1'b1, 2'd0, 2'd2, 1'b1);
        pulse_beat();
        exp_ch("(3) combo led0 (timbre 3)",  col_prod, 0, X_ORANGE);
        exp_ch("(3) combo led1 (metro beat)", col_prod, 1, X_GREEN);
        exp_ch("(3) combo led2 (drum 3)",    col_prod, 2, X_ORRED);
        exp_ch("(3) combo led3 (keydrum)",   col_prod, 3, X_BLUE);
        exp_ch("(3) combo led4 (loop idle)", col_prod, 4, X_DIMBLUE);
        exp_ch("(3) combo led5 (gear 2)",    col_prod, 5, X_YELLOW);
        exp_ch("(3) combo led6 (fretboard)", col_prod, 6, X_ORANGE);

        // ════════════════════════════════════════════════════════════════════
        // (4) 鼓机 4 个节奏型 + 关 = 灭
        // ════════════════════════════════════════════════════════════════════
        $display("=== (4) 鼓机 ===");
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(4a) drum off", col_prod, 2, X_OFF);
        drive(2'd0, 1'b0, 1'b1, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(4b) drum pat 0", col_prod, 2, X_RED);
        drive(2'd0, 1'b0, 1'b1, 2'd1, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(4c) drum pat 1", col_prod, 2, X_MAGENTA);
        drive(2'd0, 1'b0, 1'b1, 2'd2, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(4d) drum pat 2", col_prod, 2, X_YELLOW);
        drive(2'd0, 1'b0, 1'b1, 2'd3, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(4e) drum pat 3", col_prod, 2, X_ORRED);

        // ════════════════════════════════════════════════════════════════════
        // (5) 键盘打鼓 + 推子档位 + 模式
        // ════════════════════════════════════════════════════════════════════
        $display("=== (5) 键盘打鼓 / 推子 / 模式 ===");
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b1, 2'd0, 2'd3, 1'b0);
        exp_ch("(5a) keydrum on", col_prod, 3, X_BLUE);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(5b) keydrum off", col_prod, 3, X_OFF);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd0, 1'b0);
        exp_ch("(5c) gear 0 = 变调", col_prod, 5, X_VIOLET);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd1, 1'b0);
        exp_ch("(5d) gear 1 = 颤音", col_prod, 5, X_CYAN);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd2, 1'b0);
        exp_ch("(5e) gear 2 = 摇把(预留)", col_prod, 5, X_YELLOW);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(5f) gear 3 = 无 ⇒ 灭", col_prod, 5, X_OFF);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b1);
        exp_ch("(5g) 指板模式 = 橙", col_prod, 6, X_ORANGE);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(5h) 键盘模式 = 绿", col_prod, 6, X_GREEN);

        // ════════════════════════════════════════════════════════════════════
        // (6) 节拍器：关=灭 · 开(无拍点)=灭 · 拍点=绿 · ⭐ 时长 == FLASH_CYC
        //     ⭐ 精确长度在【参数化实例】上量；生产实例只钉"下界"（⭐ 见文件头）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (6) 节拍器 ===");
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(6a) metro off = 灭", col_prod, 1, X_OFF);
        //  📌 "开但无拍点 = 灭" 那一条在文件开头 (0b) —— ⭐ 那里才是唯一有效的时刻
        //  ⚠️ 这里必须先把节拍器**打开**再发拍点 —— 否则 `blk_c[1]` 是"常亮灭"，
        //     拍点来了也不会亮（⭐ 第一版就栽在这：漏了这行 ⇒ (6c) 假红）
        drive(2'd0, 1'b1, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);

        pulse_beat();
        exp_ch("(6c) beat = 绿（立即）",       col_prod, 1, X_GREEN);
        exp_ch("(6c) beat = 绿（立即, fast）", col_fast, 1, X_GREEN);

        // ⭐ 参数化实例：精确量"亮多久"（应 == FLASH_CYC_TB 拍）
        n_cyc = 0; n_fast = -1;
        while ((n_cyc < FLASH_CYC_TB + 1000) && (n_fast < 0)) begin
            if (col_fast[1*24 +: 24] !== X_GREEN) n_fast = n_cyc;
            @(negedge clk);
            n_cyc = n_cyc + 1;
        end
        // ⭐ 生产实例：只钉【下界】—— 等 500 k 拍（10 ms）仍须亮着
        //   📌 为什么不在这里等满 5_000_000：⭐ 实测 5 M 拍 ≈ 103 s
        //      ⇒ ⚠️ 逼近 120 s 预算 ⇒ 并行时会假超时（⭐ 见文件头说明）
        for (n_cyc = 0; n_cyc < PROD_FLOOR; n_cyc = n_cyc + 1) @(negedge clk);

        $display("  info: 生产默认 FLASH_CYC = %0d 拍（= 100 ms @50 MHz）", FLASH_PROD);
        $display("  info: beat-flash length  fast=%0d (want %0d);  prod still lit after %0d",
                 n_fast, FLASH_CYC_TB, PROD_FLOOR);
        chk("(6d) 拍点闪时长 == FLASH_CYC（参数化实例，精确）",
            (n_fast >= FLASH_CYC_TB - 3) && (n_fast <= FLASH_CYC_TB + 3));
        chk("(6e) 生产实例过了 500 k 拍仍然亮 ⇒ 默认拉伸是【长的】",
            col_prod[1*24 +: 24] === X_GREEN);
        chk("(6f) 此时参数化实例已灭（prod 与 fast 不同步 ⇒ 参数真的生效）",
            col_fast[1*24 +: 24] === X_OFF);

        // ════════════════════════════════════════════════════════════════════
        // (7) looper：空闲=暗蓝 · 回放=绿常亮 · 录音=红【快闪】（⭐ 量周期与占空比）
        // ════════════════════════════════════════════════════════════════════
        $display("=== (7) looper ===");
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        exp_ch("(7a) looper 空闲 = 暗蓝常亮", col_prod, 4, X_DIMBLUE);
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd2, 2'd3, 1'b0);
        exp_ch("(7b) looper 回放 = 绿常亮",   col_prod, 4, X_GREEN);

        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd1, 2'd3, 1'b0);
        //  ⭐ 量 8 个快闪周期（fast 实例：周期应 = 2^FAST_DIV_TB = 1024 拍）
        //  📌 判据用【相邻两个上升沿的最小/最大间隔】—— ⛔ 不用"(末−首)/(边数−1)"：
        //     后者会把"窗口首尾各半个周期"平均进去 ⇒ ⚠️ 差几十拍（⭐ 第一版实测 974）
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

        chk("(7c) 录音 = 红【快闪】：⭐ 相邻上升沿间隔恒 == 2^FAST_DIV",
            (n_edge >= 6) && (min_iv == (1 << FAST_DIV_TB)) && (max_iv == (1 << FAST_DIV_TB)));
        chk("(7d) 快闪占空比 ≈ 50%", (n_on > 8*1024*45/100) && (n_on < 8*1024*55/100));
        chk("(7e) 录音时只有 红 / 灭 两种颜色（⛔ 不串别的颜色）", n_other == 0);
        chk("(7f) 录音时【确实在闪】（⛔ 不是常亮）", n_edge >= 6);

        // ════════════════════════════════════════════════════════════════════
        // (8) A8：无 X/Z
        // ════════════════════════════════════════════════════════════════════
        drive(2'd0, 1'b0, 1'b0, 2'd0, 1'b0, 2'd0, 2'd3, 1'b0);
        chk("(8) no X/Z on led_col_o after reset (A8, 两个实例)",
            (a8_err_prod == 32'd0) && (a8_err_fast == 32'd0));

        if (errors == 0)
            $display("PASS: led_indicator -- 7 路语义 + 共享快闪 + 拍点闪 + 参数化闪烁全部成立");
        else
            $fatal(1, "FAIL: led_indicator has %0d error(s)", errors);
        $finish;
    end

    // 看门狗：⭐ 本 tb 仿真时间约 11 ms（⭐ 生产实例要等 500 k 拍）
    //   ⇒ ⭐ 20 ms 上限足够；⛔ 一挂就报 FAIL（⭐ 而不是让 `tb_all.ps1` 干等 120 s）
    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_led_indicator timeout");
    end

endmodule

`default_nettype wire
