// ─────────────────────────────────────────────────────────────────────────────
// tb_vel_top_stream.sv · ⭐ 「位置式力度流」在 `top.v` 里的**行为契约**（2026-09-28 新增）
//
// 🔴 **为什么必须新增这个 tb**：
//    `tb_vel_pos_follow.sv` 只例化 `note_manager` + `envelope_bank`
//    ⇒ ⭐ **它对 `top.v` 的覆盖率 = 零**
//      （⭐ 已用对照实验证明：把 `rtl/top.v` 换成 HEAD 版，那个 tb 依然 18/18 全过）
//    ⇒ ⭐ 本 tb 补上 `top.v` 里 `vu_*` 那段流的契约：
//        8 轴轮转 / 死区 16 / 1 拍脉冲 / `VEL_TRIG_TH` 门控 / valid 与数据同拍。
//
// ⭐ **手法：用 `force` 完全接管 `as_pos` 与 `tick_audio`**
//    · ⛔ 不走 ADC 模型、⛔ 不等 `calib_autotare`、⛔ 不依赖帧时序
//    ⇒ ⭐ 判据**完全确定**（不引入被测系统之外的时序假设）
//    📌 层次路径已核实：`as_pos`/`vu_*` 在 `g_sound` 块内；`tick_audio` 在顶层。
//
// ⭐ **判据清单（逐条机械可判）**
//    ① `vu_ax_r` **8 轴轮转**（每个 `tick_audio` 走一格，0→7→0）
//    ② **死区 16**：`Δpos = 16` ⇒ ⛔ 不发；`Δpos = 17` ⇒ 发
//    ③ `vu_valid_r` **恰好 1 拍脉冲**（⛔ 从不连续 2 拍高）
//    ④ **`VEL_TRIG_TH` 门控**：`pos = 64`（不 > 64）⇒ ⛔ 不发；`pos = 65` ⇒ 发
//       ⭐ 这正是"抬起后力度冻结"的机制
//    ⑤ ⭐ **valid 与数据同拍**（`L70`）：每个包里 `vu_val` 必须等于
//       **当拍 pos** 算出的力度 —— ⛔ 若 valid 比数据晚一拍，这条会 FAIL
//
// ⚠️ **判据名必须纯 ASCII**（`chk()` 走位向量→字符串通路，见 `tb_vel_pos_follow.sv` 的说明）
// ⚠️ **语法纪律**：Verilog-2001，⛔ 不用 SV 专有构造（`K-91`）
//
// ⭐⭐ **非空洞性（`C21`/`C83`：判据必须能失败）—— 2026-09-28 实测，3 个定点变异**
//
//   | 变异 | 预期 FAIL | 实测 |
//   |---|---|---|
//   | `VEL_DEADZONE` 16 → 15 | T3 | ✅ **T3 FAIL** |
//   | `VEL_TRIG_TH` 64 → 63 | T5 | ✅ **T5 FAIL** |
//   | `vu_axis_r <= vu_ax_r + 1` | T2c / T8 | ✅ **T2c / T8 FAIL** |
//
//   🔴🔴 **第 3 个变异第一次跑时【全过】—— 抓出了本 tb 自己的空洞判据**：
//      ⚠️ 我原先把"轴号对齐"检查放在 `tick1` 的【第三个】negedge，
//         而那时 `vu_valid_r` 已被下一个 posedge 清 0
//         ⇒ `if (vu_vld && ...)` **永不成立** ⇒ ⭐ **判据是空洞的**。
//      ✅ 修法：把检查移到 **`force tick_audio=0` 之后的第一个 negedge**
//         （⭐ 那一刻 `vu_valid_r` 仍为高、`vu_axis_r` 仍是本 tick 锁存的轴）。
//      📌 **教训**：⭐ **"判据全绿"必须先证明它【能红】** —— 否则它可能只是没被执行过。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_vel_top_stream;

    //  ⭐ 与被测同值（`top.v:1712-1713`）
    localparam integer VEL_TRIG_TH  = 64;
    localparam integer VEL_DEADZONE = 16;

    //  ⭐ 判据名缓冲区：90 字节（纯 ASCII）⇒ ⛔ 不会截断
    localparam integer NAME_W = 8*90;

    reg clk = 1'b0;
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
    // DUT：完整 `top`（例化方式与 `tb_e2e_key_to_sound.sv` 一致）
    // ═════════════════════════════════════════════════════════════════════════
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0] spi_cs_n;

    top #(
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

    //  ⭐ 未用的高 4 位片选恒高（不选中）
    assign spi_cs_n[5:2] = 2'b11;

    //  ⚠️ 从机仍要挂（否则 SPI 悬空）；但 `pos` 由 `force` 控制，⛔ 不依赖它们
    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );
    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // 层次化探针（⭐ 路径已核实：`vu_*` 在 `g_sound` 块内）
    // ═════════════════════════════════════════════════════════════════════════
    wire [2:0]  vu_ax   = u_top.g_sound.vu_ax_r;
    wire        vu_vld  = u_top.g_sound.vu_valid_r;
    wire [3:0]  vu_axis = u_top.g_sound.vu_axis_r;
    wire [7:0]  vu_val  = u_top.g_sound.vu_val_r;

    // ═════════════════════════════════════════════════════════════════════════
    // 位置 → 力度：⭐ 与 `top.v` 的 `pos_to_vel` **逐位相同**（唯一映射口径）
    // ═════════════════════════════════════════════════════════════════════════
    function [7:0] pos_to_vel;
        input [11:0] p;
        reg   [21:0] p22;
        reg   [21:0] prod;
        reg   [12:0] v13;
        begin
            p22        = {10'd0, p};
            prod       = (p22 << 8) + (p22 << 3) - p22;     // ×263（⛔ 无乘法器）
            v13        = 13'd64 + prod[21:10];              // >>10 再 +64
            pos_to_vel = (v13 > 13'd255) ? 8'd255 : v13[7:0];
        end
    endfunction

    // ═════════════════════════════════════════════════════════════════════════
    // 激励与观测
    // ═════════════════════════════════════════════════════════════════════════
    integer pkt_cnt;          // 本段收到的包数
    integer rot_bad;          // 轮转不符的次数
    integer max_run;          // `vu_valid_r` 最长连续高拍数
    integer run_len;
    integer align_bad;        // 包里 `vu_val` 与当拍 pos 不符的次数
    integer axis_bad;         // 包里 `vu_axis` 与 `vu_ax_r` 不符的次数
    reg [11:0] cur_pos;       // ⭐ 当前强制给 8 个轴的 pos

    //  ⭐ 脉冲宽度监视：`vu_valid_r` ⛔ 不得连续 2 拍高
    //     ⚠️ 在 `posedge clk` 读 `vu_vld` 得到的是【本拍更新前】的值
    //        —— 对"连续几拍高"这个性质无影响（只是整体平移一拍）。
    always @(posedge clk) begin
        if (!rst_n) begin run_len = 0; end
        else if (vu_vld) begin
            run_len = run_len + 1;
            if (run_len > max_run) max_run = run_len;
        end else begin
            run_len = 0;
        end
    end

    //  ⭐ 同拍监视：包有效时，`vu_val` 必须等于**当拍** `cur_pos` 的力度
    //     ⚠️ 这里读到的 `vu_vld` 是"上一拍置起的"，而 `vu_val_r` 也正是那一拍锁存的值
    //        ⇒ ⭐ 两者同拍 ⇒ 判据成立。
    //     📌 `vu_axis_r` ⛔ 不能在这里比（`vu_ax_r` 每 tick 都 +1 ⇒ 会差 1）
    //        ⇒ ⭐ 轴号判据放在 `tick1` 里（用"本 tick 要扫的轴"作参考）
    always @(posedge clk) begin
        if (rst_n && vu_vld) begin
            pkt_cnt = pkt_cnt + 1;
            if (vu_val !== pos_to_vel(cur_pos)) align_bad = align_bad + 1;
        end
    end

    //  ── 把 8 个轴都设成同一个 `pos`（⭐ 这样无论扫到哪个轴，值都一样）──
    task set_pos;
        input [11:0] p;
        begin
            cur_pos = p;
            force u_top.g_sound.as_pos = {96'd0, {8{p}}};
        end
    endtask

    //  ── 走一个 `tick_audio`（⭐ 恰好 1 拍高），并顺带查 8 轴轮转 ──
    //     ⭐ 关键：`vu_ax_r` 在 tick 的 posedge 用【非阻塞】赋值更新
    //        ⇒ ⛔ 不能在同一个 `always @(posedge)` 里读（会读到旧值 ⇒ 误报）
    //        ⇒ ⭐ 这里"取更新前的值 → 等一拍 → 比更新后的值"
    task tick1;
        integer ax_before;
        begin
            ax_before = vu_ax;                      // ⭐ 本 tick 要扫的轴（posedge P 之前的值）
            @(negedge clk); force u_top.tick_audio = 1'b1;
            @(negedge clk); force u_top.tick_audio = 1'b0;
            //  ⭐⭐ **必须在这里检查**（P 之后的第一个 negedge）：
            //     · `vu_valid_r` ⭐ **仍为高**（它在 P 置起，要到【下一个】 posedge 才清）
            //     · `vu_axis_r`  = `ax_before`（与 valid 同拍锁存）
            //     · `vu_ax_r`    = `ax_before + 1`（P 已经 +1）
            //  🔴 **踩过的坑**：原先把这两个检查放在【第三个】 negedge ——
            //     那时 `vu_valid_r` 已被清 0 ⇒ `if (vu_vld && ...)` **永不成立**
            //     ⇒ ⭐ **轴号判据是【空洞】的**（变异 `vu_axis_r <= vu_ax_r + 1` 竟然全过）。
            //      📌 这就是"非空洞性测试"的价值（`C83` 探针假绿）。
            if (vu_ax !== ((ax_before + 1) % 8)) rot_bad = rot_bad + 1;
            if (vu_vld && (vu_axis !== ax_before)) axis_bad = axis_bad + 1;
            @(negedge clk);
        end
    endtask

    //  ── 走 n 个 tick，并返回这一段收到的包数 ──
    task run_ticks;
        input integer n;
        integer t;
        begin
            pkt_cnt = 0;
            for (t = 0; t < n; t = t + 1) tick1;
        end
    endtask

    integer n_before;

    initial begin
        $dumpfile("build/sim/tb_vel_top_stream/tb_vel_top_stream.vcd");
        $dumpvars(0, tb_vel_top_stream);

        pkt_cnt = 0; rot_bad = 0; max_run = 0; run_len = 0;
        align_bad = 0; axis_bad = 0; cur_pos = 12'd0;

        //  ⭐ 先接管 `as_pos` 与 `tick_audio`（⛔ 不让 `axis_snapshot`/`clk_gen` 干扰）
        force u_top.g_sound.as_pos = {96'd0, {8{12'd0}}};
        force u_top.tick_audio     = 1'b0;

        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═════════════════════════════════════════════════════════════════
        // ① pos = 0（⛔ 不过 VEL_TRIG_TH）⇒ 应当【一个包都没有】
        // ═════════════════════════════════════════════════════════════════
        set_pos(12'd0);
        run_ticks(8);
        chk("T1: pos=0 (below VEL_TRIG_TH) => NO vel_upd packets", pkt_cnt == 0);

        // ═════════════════════════════════════════════════════════════════
        // ② pos = 300 ⇒ 每个轴【首次】都该发一包（Δ 从 0 跳到 300 ≫ 死区）
        //     ⭐ 同时验证 `vu_val` 等于 pos_to_vel(300)
        // ═════════════════════════════════════════════════════════════════
        align_bad = 0; axis_bad = 0;
        set_pos(12'd300);
        run_ticks(8);
        chk("T2a: pos=300 => exactly ONE packet per axis (8 total)", pkt_cnt == 8);
        chk("T2b: every packet value == pos_to_vel(300)", (align_bad == 0) && (pos_to_vel(12'd300) == 8'd141));
        chk("T2c: every packet axis == vu_ax_r of that cycle", axis_bad == 0);

        // ═════════════════════════════════════════════════════════════════
        // ③ ⭐ 死区：Δpos = 16 ⇒ ⛔ 一个包都不发
        // ═════════════════════════════════════════════════════════════════
        set_pos(12'd316);
        run_ticks(8);
        chk("T3: deadzone -- delta=16 => NO packet (deadzone is 16)", pkt_cnt == 0);

        // ═════════════════════════════════════════════════════════════════
        // ④ ⭐ 死区边界：Δpos = 17 ⇒ 每个轴都发
        // ═════════════════════════════════════════════════════════════════
        align_bad = 0;
        set_pos(12'd317);
        run_ticks(8);
        chk("T4a: delta=17 (just over deadzone) => packet per axis", pkt_cnt == 8);
        chk("T4b: value tracks pos=317", align_bad == 0);

        // ═════════════════════════════════════════════════════════════════
        // ⑤ ⭐⭐ VEL_TRIG_TH 门控：pos = 64（**不 > 64**）⇒ ⛔ 不发
        //     ⚠️ 注意此时 Δ 很大（64 vs 317）⇒ ⭐ 只有门控能挡住它
        //     📌 这正是"抬起后力度冻结"的机制
        // ═════════════════════════════════════════════════════════════════
        set_pos(12'd64);
        run_ticks(8);
        chk("T5: pos=64 (NOT > VEL_TRIG_TH) => NO packet even though delta is huge", pkt_cnt == 0);

        // ═════════════════════════════════════════════════════════════════
        // ⑥ pos = 65（刚过门）⇒ 每个轴都发，且值 = pos_to_vel(65) = 80
        // ═════════════════════════════════════════════════════════════════
        align_bad = 0;
        set_pos(12'd65);
        run_ticks(8);
        chk("T6a: pos=65 (just over threshold) => packet per axis", pkt_cnt == 8);
        chk("T6b: value == pos_to_vel(65) == 80", (align_bad == 0) && (pos_to_vel(12'd65) == 8'd80));

        // ═════════════════════════════════════════════════════════════════
        // ⑦ ⭐ 8 轴轮转 + 1 拍脉冲宽度（全局累计判据）
        // ═════════════════════════════════════════════════════════════════
        chk("T7a: vu_ax_r rotates 0->1->...->7->0 on EVERY tick_audio", rot_bad == 0);
        chk("T7b: vu_valid_r is exactly a ONE-cycle pulse (never 2 in a row)", max_run <= 1);

        // ═════════════════════════════════════════════════════════════════
        // ⑧ 全段汇总
        // ═════════════════════════════════════════════════════════════════
        chk("T8: all packets had val/axis aligned with the SAME cycle (L70)", (align_bad == 0) && (axis_bad == 0));

        if (errors == 0)
            $display("PASS: vel_top_stream -- the top-level vu_* stream obeys its contract");
        else
            $fatal(1, "FAIL: vel_top_stream has %0d error(s)", errors);

        #200;
        $finish;
    end

endmodule
