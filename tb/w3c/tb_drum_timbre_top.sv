// ─────────────────────────────────────────────────────────────────────────────
// tb_drum_timbre_top.sv · ⭐ 「鼓机的音色**不跟着键盘走**」契约（2026-09-29 新增）
//
// 🔴 **为什么必须新增这个 tb**（⭐ 用户上板实测反馈）
//
//   ⭐ 用户原话：*"换键盘音色的时候，鼓的声音也跟着变了"*
//      ⇒ ⭐ 鼓机和键盘**听起来像同一件乐器**（⛔ 鼓必须有自己的音色）。
//
//   🔎 **根因**（⭐ 代码级，⭐ `top.v` 改之前）：
//      · ⭐ `top.v` 把源 B（节拍器/鼓机）的 `b_timbre_valid_i` **恒接 `1'b0`**
//      · ⭐ 而 `note_manager.v:426` 是
//        `new_timbre = cur_timbre_valid ? cur_timbre : default_timbre_i`
//        ⇒ ⭐ `valid=0` ⇒ ⭐ 走**兜底分支** ⇒ ⭐ 拿到 `default_timbre_i`
//      · ⭐ 而 `top.v:3081` 把 `default_timbre_i` 接的是
//        **`timbre_sel_r`（⭐ 键盘当前音色）**
//      ⇒ 🔴 **鼓的音色 = 键盘的音色** ✅（现象与用户描述**完全吻合**）
//
//   ✅ **修法**（⭐ 只动 `top.v` 的接线，⛔ 不碰 `note_manager`）：
//      ⭐ 源 B 改喂 **`valid=1` + 固定值 `DRUM_TIMBRE`**
//      ⇒ ⭐ 鼓**永远**用 `DRUM_TIMBRE`，⭐ 键盘怎么切都不影响 ✅
//
// ⭐ **本 tb 的判据**（⭐ 每条都必须能红 —— `K-56`/`C21`/`C83`）
//    T1 ⭐ 正拍（`bar_start`）之后鼓机真的发出 **Kick + HiHat**（⭐ 前置条件，⛔ 防空转）
//    T2 ⭐ 合流后（`evt_merge` 出口）**每个 axis-15 事件**都带
//       `timbre_valid=1` + `timbre=DRUM_TIMBRE(2)`（⭐ 修前：`valid=0` ⇒ **必红**）
//    T3 ⭐ `note_manager` 真的给鼓的 voice **锁存了 timbre=2**
//       （⭐ 修前：⭐ 走兜底 ⇒ 锁存的是键盘的 **3** ⇒ **必红**）
//    T4 ⭐ **解耦证明**：⭐ 把键盘音色**强制成 3（PAD）**，⭐ 鼓仍然是 **2**
//       （⭐ 这就是用户听到的那个 bug —— ⭐ "鼓跟着键盘变"）
//
// ⚠️⚠️ **`force` 必须离开时钟沿**（⭐ `U74` 的教训）：
//    与 `@(posedge clk)` 同刻会被 **delta 竞争**吃掉 ⇒ 谁都看不见。
//    ⇒ ⭐ 本 tb 一律 `@(posedge clk); #5; force ...`
//
// ⚠️ **判据名必须纯 ASCII、<= 128 字节**（⭐ 本机 `vvp` 会把非 ASCII 打乱）
// ⚠️ **非空洞性**（⭐ `C83`：判据必须能红）：
//    ⭐ 把 `top.v` 的 `src_b_timbre_valid` 退回 `1'b0` ⇒ ⭐ **T2/T3/T4 必红** ✅
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_drum_timbre_top;

    localparam integer NAME_W = 8*110;
    // ⭐ 与 `top.v` 的两个常量对齐
    localparam [1:0] DRUM_T = 2'd2;      // ⭐ `top.DRUM_TIMBRE`（PIANO = 25% 脉冲）
    localparam [1:0] KEYB_T = 2'd3;      // ⭐ 本 tb 把键盘音色**强制成 PAD**（⭐ 与鼓不同）
    // ⭐ 鼓的"身份"（⭐ `drum_gen.v` 的 `INC_KICK` / `INC_HIHAT`）
    localparam [31:0] INC_KICK  = 32'd5_368_709;
    localparam [31:0] INC_HIHAT = 32'd171_798_691;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;

    task chk;
        input [NAME_W-1:0] name;
        input              cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // DUT（⭐ 例化方式照抄 `tb_met_start_top.sv` ⇒ ⭐ 参数与它一致）
    // ═════════════════════════════════════════════════════════════════════════
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0] spi_cs_n;

    //  ⭐⭐ 2026-09-30：⭐ **显式选定"源 B = 鼓机"**（⭐ 本 tb 的被测对象）
    //     🔴 **为什么必须写这一行**：⭐ 本 tb 验的是**鼓机**（`AXIS_ID=15`）的
    //        音色与合流路径 ⇒ ⚠️ 而 `top.SEL_DRUM` 的**主树默认档 = 0（节拍器）**
    //        （⭐ 2026-09-30 裁定：默认档必须与 5 份文档 ＋ `上板操作手册` 的
    //         "四条铁律"一致；⭐ 鼓机要验就**另编 `SEL_DRUM=1` 的 `.fs`**）
    //        ⇒ 🔴 若沿用默认值，源 B 选的是节拍器 ⇒ `drm_evt_valid` **到不了**
    //           `evt_merge` 出口 ⇒ T1~T5 **全红**（⭐ 而鼓机本身是好的 ✅）。
    //     📌 **纪律**：⭐ 凡"验某一路"的 tb **必须显式声明自己需要的档**，
    //        ⛔ 不依赖顶层默认值（⭐ 本 tb 原来就是靠默认值才促成那次默认档改动 ✅）
    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .SEL_DRUM              (1),
        .AUTOTARE_DELAY_CLK    (100_000),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .led_heartbeat (led_hb),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        .uart_rx       (1'b1),
        .uart_tx       ()
    );

    assign spi_cs_n[5:2] = 4'b1111;

    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );
    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // 探针（⭐ 路径已核实 —— 与 `tb_met_start_top` 同一套）
    // ═════════════════════════════════════════════════════════════════════════
    //   ⭐ ① 鼓机自己的输出（⭐ 前置条件用）
    wire        drm_v   = u_top.g_sound.drm_evt_valid;
    wire [31:0] drm_inc = u_top.g_sound.drm_evt_inc;
    //   ⭐ ② `evt_merge` 出口（⭐ 带 **timbre sideband** —— ⭐ 本轮修的就是它）
    wire        mg_v    = u_top.g_sound.mg_evt_valid;
    wire [3:0]  mg_ax   = u_top.g_sound.mg_evt_axis;
    wire        mg_tv   = u_top.g_sound.mg_evt_timbre_valid;
    wire [1:0]  mg_t    = u_top.g_sound.mg_evt_timbre;

    integer n_drm        = 0;
    integer n_drm_kick   = 0;
    integer n_drm_hih    = 0;
    reg [31:0] drm_inc_first = 32'hDEAD_BEEF;
    //   ⭐ 只统计 **axis = 15**（鼓机）的合流事件 —— ⚠️ 源 A（演示和弦）也在同一条口上
    integer n_mg_drum    = 0;
    integer n_mg_tv_bad  = 0;      // ⭐ `timbre_valid` 不为 1 的个数
    integer n_mg_t_bad   = 0;      // ⭐ `timbre` 不等于 `DRUM_T` 的个数

    always @(posedge clk) begin
        if (rst_n) begin
            if (drm_v) begin
                if (n_drm == 0) drm_inc_first = drm_inc;
                n_drm = n_drm + 1;
                if (drm_inc == INC_KICK)  n_drm_kick = n_drm_kick + 1;
                if (drm_inc == INC_HIHAT) n_drm_hih  = n_drm_hih  + 1;
            end
            if (mg_v && (mg_ax === 4'hF)) begin
                n_mg_drum = n_mg_drum + 1;
                if (mg_tv !== 1'b1)   n_mg_tv_bad = n_mg_tv_bad + 1;
                if (mg_t !== DRUM_T)  n_mg_t_bad  = n_mg_t_bad  + 1;
            end
        end
    end

    //   ⭐ 造一个"小节起点"（⭐ 手法与 `tb_met_start_top` 一致：
    //      ⛔ 不等真实节拍 —— ⚠️ 120 BPM 下每拍 2500 万拍，仿真跑不完）
    task one_bar_start;
        begin
            @(posedge clk); #5;                       // ⭐ 离开时钟沿（U74）
            force u_top.g_sound.bg_bar_start = 1'b1;
            @(posedge clk);                           // ⭐ 恰好一个 posedge 采样
            #5;
            release u_top.g_sound.bg_bar_start;
            repeat (2000) @(posedge clk);             // ⭐ 让合流 + voice 分配走完
        end
    endtask

    integer i;
    integer n_axis15_voice;      // ⭐ axis=15 且 gate 高的 voice 个数（⭐ 诊断信息）
    integer n_axis15_timbre;     // ⭐ 其中 timbre == DRUM_T 的个数

    initial begin
        $dumpfile("build/sim/tb_drum_timbre_top/tb_drum_timbre_top.vcd");
        $dumpvars(0, tb_drum_timbre_top);

        rst_n = 1'b0;
        repeat (200) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // ── T4 的"现场"：⭐ 键盘音色强制成 3（PAD）──────────────────────────
        //    🔴 **这就是 bug 的触发条件**：⭐ 修之前鼓会**跟着**变成 3 ✅
        @(posedge clk); #5;
        force u_top.timbre_sel_r = KEYB_T;
        repeat (10) @(posedge clk);
        chk("T0 precondition: keyboard timbre forced to PAD(3)",
            u_top.timbre_sel_r === KEYB_T);

        // ── 开源 B（⭐ 鼓机）──────────────────────────────────────────────
        //    ⭐ `src_b_valid` 串了 `met_on_r`（运行时开关）⇒ ⭐ 必须打开它
        //    ⚠️ `force` 离开时钟沿（U74）
        @(posedge clk); #5;
        force u_top.met_on_r = 1'b1;
        repeat (10) @(posedge clk);

        // ── 造一个小节起点 ⇒ ⭐ 鼓机的 step 0（Kick + HiHat）──────────────
        n_drm = 0; n_drm_kick = 0; n_drm_hih = 0; drm_inc_first = 32'hDEAD_BEEF;
        n_mg_drum = 0; n_mg_tv_bad = 0; n_mg_t_bad = 0;
        one_bar_start();

        $display("  info: drum events=%0d (kick=%0d hihat=%0d)  first_inc=%h",
                 n_drm, n_drm_kick, n_drm_hih, drm_inc_first);
        $display("  info: merged axis-15 events=%0d  timbre_valid_bad=%0d  timbre_bad=%0d",
                 n_mg_drum, n_mg_tv_bad, n_mg_t_bad);

        // ── T1：⭐ 前置条件 —— ⭐ 鼓机确实在正拍发了 Kick + HiHat ─────────────
        chk("T1 drum machine emitted Kick+HiHat at the bar start",
            (n_drm >= 2) && (drm_inc_first === INC_KICK) &&
            (n_drm_kick >= 1) && (n_drm_hih >= 1));

        // ── T2：⭐⭐ 合流后每个鼓事件都带【固定音色】────────────────────────
        //    🔴 修前：⭐ `b_timbre_valid_i` 恒 0 ⇒ ⭐ 这里 `timbre_valid` 全是 0 ⇒ **必红**
        chk("T2 every merged drum event carries timbre_valid=1 (non-vacuous)",
            (n_mg_drum >= 2) && (n_mg_tv_bad == 0));
        chk("T3 every merged drum event carries timbre = DRUM_TIMBRE(2)",
            (n_mg_drum >= 2) && (n_mg_t_bad == 0));

        // ── T4：⭐⭐ **解耦证明** —— ⭐ `note_manager` 真的给鼓锁存了 2（⛔ 不是键盘的 3）
        //    ⭐ 这才是"**上板听得见**"的那一环（⭐ 音色最终由 `voice_timbre_o` 决定）
        n_axis15_voice = 0; n_axis15_timbre = 0;
        for (i = 0; i < 32; i = i + 1) begin
            if ((u_top.g_sound.u_note_manager.axis_r[i] === 4'hF) &&
                (u_top.g_sound.u_note_manager.gate_r[i] === 1'b1)) begin
                n_axis15_voice = n_axis15_voice + 1;
                if (u_top.g_sound.u_note_manager.timbre_r[i] === DRUM_T)
                    n_axis15_timbre = n_axis15_timbre + 1;
                $display("  info: drum voice %0d  axis=%h  timbre=%0d  phase_inc=%h  (keyboard timbre=%0d)",
                         i, u_top.g_sound.u_note_manager.axis_r[i],
                         u_top.g_sound.u_note_manager.timbre_r[i],
                         u_top.g_sound.u_note_manager.phase_r[i], KEYB_T);
            end
        end
        //   ⭐⭐ **诊断信息（⭐ ⛔ 不断言 —— 它是【已知问题】，⭐ 见汇报）**：
        //      ⭐ 4 件乐器**共用 `AXIS_ID=15`**，⭐ 而 `note_manager.same_hit` **只比轴号**
        //      （⭐ `note_manager.v:375`）⇒ ⭐ 同一步的第二件乐器**复用同一个 voice**
        //      ⇒ 🔴 **正拍的 Kick 会被紧随其后的 HiHat 覆盖**（⭐ 只剩 HiHat）。
        //      📌 本行就是"**实测到只有 1 个 voice**"的证据 ✅
        $display("  info: voices with axis=15 and gate high = %0d  (2 drum events were emitted)",
                 n_axis15_voice);
        chk("T4 note_manager latched a voice for the drum (axis 15, gate high)",
            n_axis15_voice >= 1);
        chk("T4b the drum voice timbre is DRUM_TIMBRE(2), NOT the keyboard's 3",
            (n_axis15_voice >= 1) && (n_axis15_timbre == n_axis15_voice));

        // ── T5：⭐ 再切一次键盘音色 ⇒ ⭐ 鼓的音色**必须不变**（⭐ 解耦的动态证明）
        @(posedge clk); #5;
        force u_top.timbre_sel_r = 2'd0;          // ⭐ 键盘改成 BASS
        repeat (10) @(posedge clk);
        one_bar_start();                          // ⭐ 再敲一个小节
        n_axis15_voice = 0; n_axis15_timbre = 0;
        for (i = 0; i < 32; i = i + 1) begin
            if ((u_top.g_sound.u_note_manager.axis_r[i] === 4'hF) &&
                (u_top.g_sound.u_note_manager.gate_r[i] === 1'b1)) begin
                n_axis15_voice = n_axis15_voice + 1;
                if (u_top.g_sound.u_note_manager.timbre_r[i] === DRUM_T)
                    n_axis15_timbre = n_axis15_timbre + 1;
            end
        end
        chk("T5 after the keyboard timbre changed, the drum timbre is STILL 2",
            (n_axis15_voice >= 1) && (n_axis15_timbre == n_axis15_voice));

        release u_top.met_on_r;
        release u_top.timbre_sel_r;

        if (errors == 0)
            $display("PASS: drum_timbre_top -- the drum machine keeps its own timbre when the keyboard timbre changes");
        else
            $fatal(1, "FAIL: drum_timbre_top has %0d error(s)", errors);

        #200;
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: tb_drum_timbre_top 自身超时");
        $finish;
    end

endmodule
