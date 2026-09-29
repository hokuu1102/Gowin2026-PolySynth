// ─────────────────────────────────────────────────────────────────────────────
// tb_met_btn_top.sv · ⭐ 「节拍器开关按键（S2 / AB13）」在 `top.v` 里的行为契约
//                      （2026-09-28 新增）
//
// 🔴 **为什么必须新增这个 tb**：
//    ⭐ 用户要求"用 AB13 的 S2 控制节拍器开关"（按一下开、再按一下关）。
//    ⚠️ `tb_debounce` 只验证 `debounce` 模块本身；`tb_metronome` 只验证
//       `metronome` 模块本身 ⇒ ⭐ **两者对 `top.v` 的覆盖率都是零**
//       （⭐ 与 `tb_vel_pos_follow` 对 `top.v` 零覆盖是同一类问题，见 `L88`）
//    ⇒ ⭐ 本 tb 补上 `top.v` 里这条链的契约：
//        同步 → 去抖 → 翻转 → **门控 `src_b_valid`** → 悬空(Z)安全
//
// ⭐ **判据清单（逐条机械可判；⛔ 全部用 `===` ⇒ 见到 `x`/`z` 也算 FAIL）**
//    M1  复位后 `met_on_r === 0`                    （⛔ 不会自己响）
//    M2  `met_btn_i = Z` ⇒ `met_btn_s === 1`        （⭐ Z-safe 的【直接】判据）
//    M3  `met_btn_i = Z` 持续 > 5 ms ⇒ `met_on_r === 0`
//        ⭐⭐ **这条保护现有 9 个不接 `met_btn_i` 的 tb**（它们看到的就是 Z）
//    M4  抖动抑制：按 100k 拍（< 250k）后松开 ⇒ `met_on_r` 仍 0、`met_btn_down` 0 次
//    M5  长按 > 5 ms ⇒ `met_on_r === 1`，且 `met_btn_down` **恰好 1 次**
//    M6  松开 > 5 ms ⇒ `met_on_r` 仍 1（⭐ 不是电平直通），`met_btn_down` 仍 1 次
//    M7  再长按 ⇒ `met_on_r === 0`，`met_btn_down` **恰好 2 次**（⭐ 真的是翻转）
//    M8  门控：`force met_evt_valid = 1` 且 `met_on_r = 0` ⇒ `src_b_valid === 0`
//    M9  门控：再 `force met_on_r = 1`                  ⇒ `src_b_valid === 1`
//    M10 撤销 force ⇒ `src_b_valid === 0`
//
// ⭐⭐ **非空洞性（`C21`/`C83`：判据必须能失败）**
//    见文件末尾「变异记录」注释块 —— ⭐ 每条变异都注明**预期哪条判据变红**。
//
// ⚠️ **判据名必须纯 ASCII**（`chk()` 走位向量→字符串通路）
// ⚠️ **语法纪律**：Verilog-2001，⛔ 不用 SV 专有构造（`K-91`）
//
// ⚠️ **时序口径**：`debounce` 的 `DB_CYC = (50e6/1000)*5 = 250_000` 拍
//    ⇒ ⭐ 长按 / 松开都用 **300_000 拍**（> 250_000，留余量）
// ⚠️⚠️ **本 tb 实测 172 s** ⇒ ⭐ **已登记进 `sim/tb_all.ps1` 的 `$heavyTb`**（300 s 预算）
//    —— 🔴 ⛔ 不登记的话，回归的**默认 120 s 预算**会把"跑完了"误判成 **TIMEOUT**（⭐ 见 `K-94` 反面）。
//    📌 **教训**：⭐ **新增一个 tb 时，必须同步估它的仿真时长**，⭐ 超过 120 s 就要登记。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_met_btn_top;

    localparam integer NAME_W     = 8*90;
    localparam integer DB_CYC     = 250_000;   // ⭐ 与 debounce.sv 同口径（5 ms @50 MHz）
    localparam integer HOLD_LONG  = 300_000;   // > DB_CYC ⇒ 一定被去抖器采到
    localparam integer HOLD_SHORT = 100_000;   // < DB_CYC ⇒ 一定被滤掉

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    // ⭐ 三态驱动：`1'bz` 用来【模拟 tb 不接这个端口】（⭐ 悬空 = Z）
    //    ⚠️ 这正是现有 9 个例化 `top` 的 tb 的真实情况
    reg met_btn_i_r;

    integer errors = 0;
    integer dn_cnt = 0;      // ⭐ `met_btn_down` 累计次数（"一次按下只产生一次"契约）

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
    // DUT：完整 `top`（例化方式与 `tb_vel_top_stream.sv` 一致）
    //   ⭐ `DEMO_CHORD_ON` 保持默认 1 ⇒ ⭐ 走 `g_sound` 分支（探针路径依赖它）
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
        // ⭐⭐ 本轮新增的端口（⭐ 唯一新增的一根线）
        .met_btn_i     (met_btn_i_r),
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
    assign spi_cs_n[5:2] = 4'b1111;

    //  ⚠️ 从机仍要挂（否则 SPI 悬空）；⭐ 本 tb 的判据完全不依赖 ADC 数据
    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );
    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // 层次化探针
    //   ⭐ `met_btn_s` / `met_btn_down` / `met_on_r` 在 `top` 的**模块层**（⛔ 不在 generate 里）
    //   ⭐ `src_b_valid` / `met_evt_valid` 在 `g_sound` 块内（`DEMO_CHORD_ON=1`）
    // ═════════════════════════════════════════════════════════════════════════
    wire met_btn_s   = u_top.met_btn_s;
    wire met_btn_dn  = u_top.met_btn_down;
    wire met_on      = u_top.met_on_r;
    wire src_b_valid = u_top.g_sound.src_b_valid;

    //  ⭐ 契约监视：`key_down` 必须是"一次按下只产生一次"的 1 拍脉冲
    //     ⚠️ 在 posedge 读 `met_btn_dn` 得到的是【本拍更新前】的值 ——
    //        对"累计几次"无影响（脉冲恰好 1 拍高，必被采到一次）。
    always @(posedge clk) begin
        if (rst_n && met_btn_dn) dn_cnt = dn_cnt + 1;
    end

    // ═════════════════════════════════════════════════════════════════════════
    // 激励
    // ═════════════════════════════════════════════════════════════════════════
    initial begin
        $dumpfile("build/sim/tb_met_btn_top/tb_met_btn_top.vcd");
        $dumpvars(0, tb_met_btn_top);

        met_btn_i_r = 1'b1;              // ⭐ 上电 = 未按下（与硬件上拉一致）
        rst_n       = 1'b0;
        repeat (200) @(posedge clk);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);

        // ── M1：复位后默认【关】──────────────────────────────────────────
        chk("M1 reset_default_is_OFF (met_on_r===0)", met_on === 1'b0);

        // ── M2/M3：悬空(Z) 必须按"未按下"处理 ─────────────────────────────
        //    ⭐ M2 是【直接】判据；M3 是【行为】判据（持续 > DB_CYC 也不开）
        met_btn_i_r = 1'bz;
        repeat (HOLD_LONG) @(posedge clk);
        chk("M2 floating_input_Z_is_read_as_released (met_btn_s===1)", met_btn_s === 1'b1);
        chk("M3 floating_input_Z_keeps_metronome_OFF_for_over_5ms", met_on === 1'b0);

        // ── M4：抖动抑制（100k 拍 < 250k）─────────────────────────────────
        met_btn_i_r = 1'b0;                          // 按下
        repeat (HOLD_SHORT) @(posedge clk);
        met_btn_i_r = 1'b1;                          // 松开（⛔ 未达去抖门限）
        repeat (100) @(posedge clk);
        chk("M4 short_press_100k_cycles_is_filtered_out (no toggle, 0 events)",
            (met_on === 1'b0) && (dn_cnt == 0));

        // ── M5：长按 ⇒ 开 ────────────────────────────────────────────────
        met_btn_i_r = 1'b0;
        repeat (HOLD_LONG) @(posedge clk);
        chk("M5 long_press_turns_metronome_ON (met_on_r===1)", met_on === 1'b1);
        chk("M5b exactly_ONE_key_down_event_per_press (K-01)", dn_cnt == 1);

        // ── M6：松开 ⇒ 保持开（⛔ 不是电平直通）──────────────────────────
        met_btn_i_r = 1'b1;
        repeat (HOLD_LONG) @(posedge clk);
        chk("M6 release_does_NOT_change_state (still ON)", met_on === 1'b1);
        chk("M6b release_produces_no_extra_key_down", dn_cnt == 1);

        // ── M7：再长按 ⇒ 关 ──────────────────────────────────────────────
        met_btn_i_r = 1'b0;
        repeat (HOLD_LONG) @(posedge clk);
        chk("M7 second_long_press_turns_metronome_OFF (met_on_r===0)", met_on === 1'b0);
        chk("M7b exactly_TWO_key_down_events_after_two_presses", dn_cnt == 2);

        // ── M8/M9/M10：门控契约（⭐ 这才是"按键控制出声"的真正契约）──────
        //    ⭐ 用 `force` 把 `met_evt_valid` 钉成 1 ⇒ `src_b_valid` 应当
        //       **只由 `met_on_r` 决定** ⇒ ⛔ 去掉 `& met_on_r` 时 M8 必红。
        force u_top.g_sound.met_evt_valid = 1'b1;
        #5;
        chk("M8 gate_blocks_metronome_when_OFF (src_b_valid===0)", src_b_valid === 1'b0);

        force u_top.met_on_r = 1'b1;
        #5;
        chk("M9 gate_passes_metronome_when_ON (src_b_valid===1)", src_b_valid === 1'b1);

        release u_top.met_on_r;
        release u_top.g_sound.met_evt_valid;
        #5;
        chk("M10 gate_returns_to_blocked_after_release (src_b_valid===0)",
            src_b_valid === 1'b0);

        if (errors == 0)
            $display("PASS: met_btn_top -- S2/AB13 metronome switch obeys its contract");
        else
            $fatal(1, "FAIL: met_btn_top has %0d error(s)", errors);

        #200;
        $finish;
    end

endmodule

// ─────────────────────────────────────────────────────────────────────────────
// 变异记录（⭐ 非空洞性：`C21`/`C83` —— 判据必须【能红】）
//
//   ⭐ 工具：`sim/check_met_btn_nonempty.ps1`
//      ⭐ **⛔ 不碰 `rtl/`** —— 它在 `build/_mut_metbtn/<id>/` 下生成 `top.v` 的
//      **变异副本**再编译 ⇒ ⭐ 随时可重跑，⛔ 不会污染工作区（⭐ 比"就地改源码"安全）。
//
//   | 变异 | 改什么 | ⭐ **实测**变红的判据 |
//   |---|---|---|
//   | **MUT1** | `src_b_valid` 去掉 `& met_on_r` | ✅ **M8** |
//   | **MUT2** | `wire met_btn_s = met_btn_i;`（去掉 Z-safe） | ✅ **M2** |
//   | **MUT3** | `debounce` 的 `.ACTIVE_LOW (1)` ⇒ `(0)` | ✅ **M3 / M4 / M6 / M6b** |
//   | **MUT4** | `met_on_r <= ~met_on_r` ⇒ `<= 1'b1` | ✅ **M7** |
//
//   ⚠️ **MUT3 的预期最初写错了**：我原以为它会打掉 **M5**（"按下开不了"），
//      ⭐ 实测是 **M3/M4/M6** —— ⭐ 因为极性反了以后**空闲态被当成"按下"**
//      ⇒ ⚠️ 一上电就把节拍器打开了（⭐ 而不是"按不开"）。
//      📌 **教训**：⭐ "某个变异该让哪条判据变红"**本身也必须实测**，⛔ 不能靠推理。
//
//   🔴 **一条已知的、本 tb 【测不到】的变异**（⭐ 如实记录，⛔ 不假装覆盖）：
//      `sync_input` 的 `.RESET_VAL(1'b1)` ⇒ `1'b0` ⇒ ⚠️ **本 tb 全绿**。
//      ⭐ 根因：复位窗口只有 **200 拍**，而 `debounce` 要 **250_000 拍**才翻转
//      ⇒ ⭐ 该变异**行为上等价**（静默）⇒ ⚠️ **不是判据漏了，是这个变异没有可观测效果**。
// ─────────────────────────────────────────────────────────────────────────────
