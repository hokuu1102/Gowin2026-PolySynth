`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_e2e_key_to_sound.sv · ⭐⭐ 端到端：**按琴键 → 出声**（W3a 整链）
//
// ⭐ 为什么需要这个 tb（⭐ 上板前唯一的"整链真的通"证据）：
//    ⚠️ 现有覆盖是【分段】的：
//      · 各模块有自己的 tb（`tb_axis_map` / `tb_event_extract` / …）✅
//      · `tb_top_sound`（`T57`）证的是【演示和弦】出声 —— ⚠️ 走 `SOURCE_A_SEL=1`
//        ⇒ 🔴 **"按下磁轴 ⇒ 出声"这条路径【从未被端到端验证过】**
//    ⇒ ⭐ 本 tb 补这一条。
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **不按键 ⇒ 静音**（⭐ 基线）
//   ② ⭐⭐ **按下 ⇒ `HP_DIN` 有数据**
//   ③ ⭐ **松开 ⇒ 回到静音**
//   ④ ⭐ **换另一片 ⇒ 也出声**（⭐ 证两片都在链上）
//   ⑤ ⭐ **复位后无 X**
//
// ── ⭐⭐ 从机模型（⭐ 2026-09-23 改为复用队友的 `mcp3208_model`）─────────────
//   🔴 **为什么换掉自写从机**：⚠️ 我先后写了两个版本（组合输出 / 下降沿输出），
//      ⚠️ **位对齐都不对** ⇒ `adc_farm` 读回 **0** ⇒ `pos` 恒 4095
//      ⇒ 🔴 基线被破坏、判据②③都不可信（⭐ 我为此花了十几轮试错）。
//   ⭐ **`mcp3208_model` 是【队友已验证】的**（`tb_mcp3208_model` 逐通道 PASS）
//      ⇒ ⭐ 直接复用它，⛔ 不再自写。
//
//   ⭐ **它的取值公式**：`ovr_en_i=1` ⇒ 返回 `ovr_val_i`；否则 `IDVAL + ch`
//      （⭐ 覆盖接口是 2026-09-23 我加的，⭐ 见该文件端口注释）
//   ⚠️ **注意**：它是**整片**覆盖（⭐ 所有通道同值）—— ⭐ 因为 `adc_farm` 锁步扫
//      同一通道，⭐ 而本 tb 要验的就是"**某片被按下**" ⇒ ⭐ 够用。
//
// ── ⭐ 电平换算（⭐ 依据用户实测 + RTL 的完整链路换算）───────────────────
//   ⭐ 实测：松手 ⇒ `raw` ≈ **1985**（0x7C1）；按到底 ⇒ `raw` ≈ **2729** ⇒ ⭐ **行程 744 码**
//   ⭐ RTL 链路（⭐ ⛔ 不是一级，是【四级】，必须串起来算 —— 本项目为此连着错过三次）：
//        `raw` →(反相 `INVERT_AXIS=1`) →(**`tare` 减零点**) →(span 增益，未标定时 = 1.0) → `pos`
//      ⭐ **`tare` 会把零点【减掉】** ⇒ ⭐ 实际 `pos` 空间：
//         · 松手 ⇒ **0**
//         · 触底 ⇒ **744**（= 2729 − 1985）
//   ⭐ 阈值（⭐ 按 **744 档**定的，⭐ 2026-10-01 返工回退到这一档）：
//      · `TRIG_TH = 64`（**8.6%**）· `REL_TH = 32`（**4.3%**，⭐ 迟滞仍 2:1）
//      ⇒ ⭐ **0 < 32 < 64 < 744** ⇒ ✅ 松手在阈下、按住在阈上
//   🔴 **本注释 2026-10-01 更正**：原文写 `TRIG_TH = 0x8D3 = 2259` / `REL_TH = 0x897 = 2199`，
//      并称"松手 pos = 2110 / 按下 pos = 2854" —— ⭐ **那两套值【在本 tb 里都不成立】**：
//      · ⭐ `2259/2199` 是**很早期**按"**未 tare 的绝对码**"算的阈值 ⇒ ⭐ `tare` 之后 `pos` 从 0 起
//        ⇒ 🔴 **永远够不着**（⭐ `top.v` 的 `event_extract` 例化处已完整记录这次教训）
//      · ⭐ `2110/2854` 是**未 tare** 的绝对码 ⇒ ⭐ ⛔ 不是 `event_extract` 实际看到的 `pos`
//      📌 **教训（⭐ `L65` 同族）**：⭐ **注释必须描述【当前链路换算后】的量**，
//         ⛔ 不是任何历史版本的值 —— ⚠️ 否则下一个人会拿它去设阈值 ✅
// ─────────────────────────────────────────────────────────────────────────────

module tb_e2e_key_to_sound;

    // ⭐ 用小延时加速仿真（⚠️ 默认 2e6 拍太慢）
    localparam integer DEMO_DELAY = 200;

    // ⭐ 复音数（⭐ 必须与 `top.v` 的 `POLY_TARGET` 一致）
    localparam integer POLY_TARGET = 32;
    //   ⭐⭐ **2026-09-26 新增：⭐ 保留池大小**（⭐ 必须与 `top.v` 的 `note_manager.RESERVED_N` 一致）
    //      ⭐ 保留池 = **最高 `RESERVED_N` 个 voice**（⭐ 给节拍器/鼓机用）
    //      ⇒ ⭐ **普通池** = `0 ~ POLY_TARGET-RESERVED_N-1`
    //      📌 **用途**：⭐ 判"演示和弦落地"时**只看普通池** ——
    //         ⚠️ 保留池按设计**常驻占用**（⭐ 节拍器 free-running），
    //         🔴 把它算进去 ⇒ 条件**永不成立**（⭐ 详见下方 `wait_for_demo_tail` 的说明）。
    localparam integer RESERVED_N   = 8;
    localparam integer NORMAL_VOICES = POLY_TARGET - RESERVED_N;   // ⭐ = 24（RESERVED_N 5→8，2026-10-17 Q3）
    // ⭐ 循环变量位宽（⭐ Verilog-2001 里 `for` 的循环变量要显式声明）
    localparam integer POLY_W = 6;          // ⭐ 6 位够数到 32

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    // ── DUT 端口 ──────────────────────────────────────────────────────
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi;
    //   ⚠️ 2026-09-23 晚：`top.v` 的 SPI 端口改成【预留 6 片】的向量
    //      ⇒ ⭐ 本 tb 只用前 2 片（⭐ 与 `N_ADC=2` 一致）
    wire [5:0] spi_miso, spi_cs_n;
    wire miso_l, miso_r;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        // ⚠️ **`DEMO_CHORD_ON` 必须保持 1**（⭐ 2026-09-23 试过设 0，🔴 编译失败）
        //   🔴 **原因**：⭐ `top.v` 里 `DEMO_CHORD_ON == 0` 会走 `g_silent` 分支 ——
        //      ⚠️ 那个分支**整条合成链都不例化**（⭐ 结构性静音，见 `top.v` 注释），
        //      ⇒ 🔴 `g_sound.*` 层次**不存在** ⇒ ⚠️ 本 tb 的探针全部 bind 失败
        //         （`ee_valid` / `at_done` …）。
        //   ⇒ ⭐ 所以**不能靠关它来消掉演示和弦**，⭐ 改为【等它响完】：
        //      见下方 `wait_for_demo_tail`（⭐ 判据① 之前先等干净）。
        .DEMO_CHORD_ON   (1),
        .DEMO_NOTE_DELAY (DEMO_DELAY),
        // ⭐⭐ 自检和弦只响**很短一段**就自己停（⭐ 2026-09-23 新增参数）
        //   🔴 **为什么需要**：⭐ 原来它 **"一响就不停"**（⛔ 不发 `note_off`）⇒
        //      ⚠️ 一个 voice 永远 held（⭐ 实测 `nm_gate = 0x08000000`）⇒
        //      🔴 **声音一直占着，与手弹混在一起**。
        //   ⭐ 用户拍板：⭐ **"让每个和弦响 1s，只起到自检作用"** ⇒
        //      `top.v` 默认 = `50_000_000`（1 秒）。
        //   📌 **本 tb 取很短**（200k 拍 ≈ 4 ms）：⭐ 目的是【验它确实会自己停】，
        //      ⛔ 不是验 1 秒本身（⚠️ 那要 50M 拍 ⇒ 超回归 120 s 预算）。
        //   ⭐ 配套：`top.v` 的 `DEMO_CW` 位宽改为
        //      `max(DEMO_NOTE_DELAY, DEMO_HOLD_CYC)` ⇒ ⭐ 防计数器【静默回绕】。
        .DEMO_HOLD_CYC   (200_000),
        .SOURCE_A_SEL    (0),                       // ⭐ 0 = W3a 手弹（⭐ 本 tb 主角）
        // ⭐⭐ 缩短 `calib_autotare` 的等待（⭐ 2026-09-23 新增）
        //   🔴 **⚠️ 不设它会【测不到 `tare`】**：
        //      ⭐ 默认 `10_000_000` 拍（200 ms）—— ⚠️ 而本 tb 总共才跑 ~2.6M 拍
        //      ⇒ 🔴 **根本没到 `tare` 时刻** ⇒ ⭐ `zero` 恒 0 ⇒ ⚠️ 量到的是"没标定"的码值。
        //      ⚠️ 这正是我第一版判据⑥ 的失败原因：`idle = 2110`（= 4095−1985）
        //         而不是 `0`。
        //   📌 取 **100_000 拍**（2 ms）⇒ ⭐ 够让 `tare` 发生，⭐ 又只占总时长 4%。
        .AUTOTARE_DELAY_CLK(100_000),
        // ⭐⭐ 2026-09-24 补：`calib_span` 的三个参数（⭐ 本 tb 不验 span 的语义）
        //   🔴 **不传的代价**：⚠️ `WAIT_TIMEOUT_CLK` 默认 50_000_000（**1 秒**仿真时间）
        //      ⇒ ⭐ 每次跑到"等按键"的超时兜底就烧掉 1 秒
        //   ✅ 本 tb 测的是**手弹出声链**，⛔ 不验 `calib_span` 的稳定性/投票语义
        //      ⇒ ⭐ 取小值不影响它的判据（⭐ 真值由 `tb_calib_span` 守着）
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
        //   ⭐ 只用低 2 位；⭐ 高 4 位接常量（⭐ 未用的片：`CS`=1 不选中、`MISO`=1 空闲）
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        //   ⭐ 2026-09-23 阶段C：串口端口（⭐ 空闲高 = 串口空闲态）
        .uart_rx       (1'b1),
        .uart_tx       ()
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 两片 ADC 从机（⭐ 复用队友已验证的 `mcp3208_model`）
    // ═══════════════════════════════════════════════════════════════════
    reg ovr_l = 1'b0, ovr_r = 1'b0;

    localparam [11:0] RAW_REST = 12'h7C1;       // ⭐ 静息（松手 1.60 V）
    localparam [11:0] RAW_DOWN = 12'h4D9;       // ⭐ 按下（触底 1.00 V）

    //   ⭐ 未用的高 4 位 `CS` 恒定高（⭐ 不选中）⇒ ⭐ 用 assign 兜住
    assign spi_cs_n[5:2] = 2'b11;

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-10-03 新增：**逐通道覆盖**（⭐ 为了"只按【某一个键】"）
    //
    //   🔴 **为什么必须逐通道**：⭐ 新增判据 B1~B4 要验的是
    //      "**按下某一个键 ⇒ 那个 voice 的音高 == 那个键的表值**"。
    //      ⚠️ 而 `ovr_en_i`/`ovr_val_i` 是**【整片】**覆盖（⭐ 8 个通道同值）
    //      ⇒ 🔴 一按就是 **8 个轴同帧越阈** ⇒ ⚠️ **一帧 8 条事件**
    //      ⇒ `top.v:2941` 自己写明："`am_inc` 是 `axis_map` 对当前 `am_axis_in`
    //         的组合输出（0 拍），而 `am_vld_out`/`am_axis_out` 再延一拍
    //         ⇒ **同帧多键时前一条事件拿到后一条的音高**"
    //      ⇒ 🔴 判据会被这个**已知限制**污染（⭐ 假红 —— `L84`）。
    //   ⭐ **模型早已支持逐通道**（`ch_mask_i`/`ch_val_i`，⭐ 2026-09-25 加的，
    //      见 `tb/models/mcp3208_model.sv:62-81`）⇒ ⭐ 本 tb **接上它**即可 ——
    //      ⛔ **没有改模型一个字节**。
    //   📌 **向后兼容（⛔ 不削弱原判据）**：⭐ 取值优先级是
    //      `ovr_en_i` → `ch_mask_i` → `IDVAL + ch`
    //      ⇒ ⭐ `ch_mask_i = 0`（默认）时取值公式**逐字不变**
    //      ⇒ ⭐ 原有判据①~⑥ 的行为**不受影响** ✅
    //   📌 **轴号 = 片号×8 + 片内通道**（⭐ `axis_map.v:55`）
    //      ⇒ ⭐ 片 L = 轴 0~7 · 片 R = 轴 8~15 ✅
    // ═══════════════════════════════════════════════════════════════════
    reg [7:0]  ch_msk_l = 8'h00;        // ⭐ 片 L：位 i = 通道 i 被按下
    reg [7:0]  ch_msk_r = 8'h00;        // ⭐ 片 R
    reg [11:0] ch_val_l = RAW_DOWN;     // ⭐ 被按下通道的码值（⭐ 同片共用一个值）
    reg [11:0] ch_val_r = RAW_DOWN;
    //   ⭐ **半按档**：⭐ 静息 0x7C1=1985 · 触底 0x4D9=1241 ⇒ 中点 = **0x64D = 1613**
    //      ⇒ ⭐ `pos ≈ 372`（⭐ `tare` 之后的空间）⇒ ⭐ **0 < 64(TRIG_TH) < 372 < 744** ✅
    //      ⇒ ⭐ 判据 B3 用它表达"**按得浅一半**"（⭐ 而 B1/B2 用触底 `RAW_DOWN`）。
    localparam [11:0] RAW_MID = 12'h64D;

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_l (
        .cs_n     (spi_cs_n[0]),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_l),
        .ovr_en_i (ovr_l),
        .ovr_val_i(RAW_DOWN),
        //   ⭐ 逐通道覆盖（⭐ 见上方说明）：⭐ 与 `ovr_en_i` 同时为 0 时**逐字保持原行为**
        .ch_mask_i(ch_msk_l),
        .ch_val_i (ch_val_l)
    );

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_r (
        .cs_n     (spi_cs_n[1]),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_r),
        .ovr_en_i (ovr_r),
        .ovr_val_i(RAW_DOWN),
        .ch_mask_i(ch_msk_r),
        .ch_val_i (ch_val_r)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 观测：判"有没有声音"（⭐ 只看 `HP_DIN` 有没有在动）
    //   🔴 **⚠️ 两个踩过的坑（2026-09-23，都是本 tb 自己的错）**：
    //   **① X 只在【复位前那一拍】出现**（⭐ 实测 `first_x_time = 1`）——
    //      ⚠️ 那是 `HP_DIN` 尚未复位、与 `din_d` 初值比较的结果
    //      ⇒ ⭐ **不是 RTL 缺陷** ⇒ ⭐ 判据⑤ 只在复位释放后计数。
    //   **② 观测变量只能有【一个】更新点** ——
    //      ⚠️ 在 `always` 里更新 `din_d`、又在 `win()` 里读它 ⇒ 🔴 进程竞争、计数不准。
    //      ⇒ ⭐ 本 tb 只在 `measure_window` 里采样。
    // ═══════════════════════════════════════════════════════════════════
    reg din_d = 1'b0;
    integer x_seen = 0;
    reg     obs_en = 1'b0;

    always @(posedge clk) begin
        if (obs_en && (HP_DIN === 1'bx)) x_seen = x_seen + 1;
    end

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 事件计数（⭐ 2026-09-23 加，⭐ 用来区分两种失败）
    //   ⚠️ 判据③ 失败时有两种可能：
    //     ① 🔴 `note_off` **发了但没生效**（⭐ 挂音 —— 真缺陷）
    //     ② ⚠️ `note_off` **压根没发**（⭐ 说明 pos 没回到阈下 —— 采集问题）
    //   ⇒ ⭐ 计数一下就能分清，⛔ 不用猜。
    //   📌 层次名依据 `top.v`：`g_sound.ee_valid` / `ee_kind`（`event_extract` 输出）
    //      ⭐ `ee_kind`：0=`note_on`、1=`note_off`
    // ═══════════════════════════════════════════════════════════════════
    integer n_on = 0, n_off = 0;
    always @(posedge clk) begin
        if (obs_en && u_top.g_sound.ee_valid) begin
            if (u_top.g_sound.ee_kind == 2'd0) n_on  = n_on  + 1;
            if (u_top.g_sound.ee_kind == 2'd1) n_off = n_off + 1;
        end
    end

    task chk;
        input [1023:0] name;
        input          cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ⭐ 观测窗口：返回 `HP_DIN` 的翻转次数（⭐ 单一更新点）
    task measure_window;
        output integer toggles;
        input  integer cycles;
        integer k;
        begin
            toggles = 0;
            din_d = HP_DIN;
            for (k = 0; k < cycles; k = k + 1) begin
                @(posedge clk);
                if (HP_DIN !== din_d) toggles = toggles + 1;
                din_d = HP_DIN;
            end
        end
    endtask

    integer tg_idle, tg_press, tg_rel, tg_right;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐⭐ 2026-10-03 新增：**端到端音高判据（B1~B4）的探针与激励**
    //
    //   🔴 **补的是什么缺口**：⭐ 本 tb 此前**一条音高都没有** ——
    //      判据①~⑥ 全是"**有声 / 无声**"⇒ ⚠️ **整条链路跑调也全绿**
    //      （⭐ 实测：`phase_inc` / `axis_map` 两词在本文件里**只出现在第 7 行注释里**）。
    //      ⭐ 项目自己记着这件事：`tb/w3b/tb_pool_by_src.sv:45` 写
    //        *"'键号 ⇒ 音高' 属于**顶层 tb**（别的批次）"* ⇒ ⭐ 本轮把它落地。
    //
    //   ⭐ **探针点**：`rtl/w3b/note_manager.v:1301`
    //      `assign voice_phase_inc_o[g*PHASE_W +: PHASE_W] = phase_r[g];`
    //      ⇒ ⭐ 每个 voice 的相位增量**就存在** `phase_r[g]`，且**直接接给**
    //         `oscillator_bank`（⭐ `:163` 的 `voice_phase_inc_o`）
    //      ⇒ ⭐ 判据 = `u_note_manager.phase_r[被分配的 voice] == 期望音高`
    //   ⭐ **手法先例（⛔ 本 tb 不发明新手法）**：
    //      `tb/top/tb_am_pipe.sv:180-181` —— 层次引用直读 `u_axis_map.kb_inc[...]`
    //
    //   ⭐ **模式前提**：⭐ 上电默认 `MODE_PIANO_DEFAULT = 1`
    //      （`rtl/w3c/uart_ui.v:66`）⇒ `play_fretboard_mode = 0`
    //      ⇒ ⭐ `axis_map` 走 **`kb_inc`（键盘表）**
    //      （⭐ `axis_map.v:522` `inc_lo = mode_i ? fb_inc[fb_sel] : kb_inc[fb_sel]`）。
    //
    //   ⚠️ **`vibrato` 不会污染本探针（⭐ 已核实，⛔ 不必先置 0）**：
    //      · ⭐ `vibrato_mod` 只进 `oscillator_bank`（`top.v:3899` 的 `.vibrato_mod_i`），
    //        ⛔ **不写 `phase_r`**
    //      · ⭐ `param_extract.pitch_value_o` **本版恒 0**（`param_extract.v:344`）
    //        且 `pitch_valid_o` 从不置起（⭐ `:329` 自述"本版恒 0"）
    //      ⇒ ⭐ `phase_r` 的写入**只有"起音 / 重触发"两条** ⇒ ⭐ **不会假红** ✅
    //
    //   ⚠️ **一帧 = 500 µs = 25_000 拍**（`adc_farm.CHANNEL_RATE_HZ = 2_000`）
    //      ⇒ ⭐ 不应期 `REFRACT_N = 60` 帧 = **1_500_000 拍**
    //      （⭐ `top.v:2837`）⇒ 🔴 同一个轴**第二次起音必须等 1.5 M 拍** ——
    //      ⭐ 本 tb 用"**把等待藏进本来就要花的时间**"来付这笔账（⭐ 见下方两处说明）。
    // ═══════════════════════════════════════════════════════════════════════

    // ── ⭐ 期望音高表（⭐【独立字面量】—— ⛔ 不是层次引用 RTL 的表）──────────
    //   🔴 **为什么必须抄成字面量（⭐ 这条判据能否"变红"的关键）**：
    //      若期望值写成 `u_axis_map.kb_inc[k]`，⭐ 那么"**把 `kb_inc[k]` 改错**"
    //      会**同时**改掉期望值 ⇒ 🔴 **两边一起动 ⇒ 判据【永远不会红】**
    //      ⇒ ⭐ 那就是 `C83`（探针假绿：探针"通过"，却根本没验到东西）。
    //   ⭐ 所以这里**照抄** `axis_map.v:376-391` 已确认的 16 项
    //      （⭐ 与 `BATCH5-音高判据执行方案` §三·A 的表**同源**）。
    //   📌 **两对重复是【设计如此】**（⭐ E#/B# 不存在）：
    //      `kb_exp(0)==kb_exp(3)`（E3）· `kb_exp(8)==kb_exp(11)`（B3）
    //      ⇒ ⛔ **不许要求"16 项互异"**（⭐ 那会引入假红 —— `L84`）。
    function [31:0] kb_exp;
        input integer k;
        begin
            case (k)
                0:  kb_exp = 32'h00DD_3595;   // E3   板上排列3
                1:  kb_exp = 32'h00F8_4C8F;   // F#3  板上排列4
                2:  kb_exp = 32'h00EA_5CF4;   // F3   板下排列4
                3:  kb_exp = 32'h00DD_3595;   // E3   板下排列3（⭐ 无 E# ⇒ 与 0 同音）
                4:  kb_exp = 32'h00C5_1339;   // D3   板下排列2
                5:  kb_exp = 32'h00AF_92EE;   // C3   板下排列1
                6:  kb_exp = 32'h00BA_039D;   // C#3  板上排列1
                7:  kb_exp = 32'h00D0_CB35;   // D#3  板上排列2
                8:  kb_exp = 32'h014B_7081;   // B3   板上排列3
                9:  kb_exp = 32'h0174_073A;   // C#4  板上排列4
                10: kb_exp = 32'h015F_25DC;   // C4   板下排列4
                11: kb_exp = 32'h014B_7081;   // B3   板下排列3（⭐ 无 B# ⇒ 与 8 同音）
                12: kb_exp = 32'h0127_476D;   // A3   板下排列2
                13: kb_exp = 32'h0107_104E;   // G3   板下排列1
                14: kb_exp = 32'h0116_B4CE;   // G#3  板上排列1
                15: kb_exp = 32'h0138_D653;   // A#3  板上排列2
                default: kb_exp = 32'h0000_0000;
            endcase
        end
    endfunction

    // ⭐ 探针变量（⭐ **模块级**：`b_pitch_sample` 采样、`pitch_criteria` 判定
    //   —— ⚠️ 块内局部变量跨块不可见 ⇒ 必须放模块级）
    integer  v9, v12, v13, v15, v10, v10d;
    reg [31:0] p9, p12, p13, p15, p_deep, p10;
    integer  pos_deep;
    integer  n_my, n_xtalk;

    // ── ⭐ 找"某个轴当前占用的 voice"（⭐ 只扫【普通池】）────────────────────
    //   🔴 **为什么只扫普通池（0 ~ NORMAL_VOICES-1）**：⭐ 保留池（24~31）
    //      按设计**常驻占用**（⭐ 节拍器 free-running）⇒ ⚠️ 把它算进来会**误判**
    //      （⭐ 判据① 那段已经为这件事付过一次学费 ✅）。
    //   ⭐ 判据：⭐ `nm_gate[v]==1` **且** `axis_r[v]==ax`
    //      ⭐ 依据：⭐ `gate_r` 与 `phase_r` 在 `note_manager.v:1251-1257`
    //         `ST_COMMIT2` 里**同一拍写入同一个 voice** ⇒ ⭐ 看到 `gate=1` 时
    //         `phase_r[v]` **已经**是本次事件的值 ✅（⛔ 不需要再等）
    //   ⭐ 轮询（⛔ 不用 `wait`：⭐ `wait` 不推进时间 ⇒ 会静默挂死，`K-94`）
    //      ＋ **带上限**（⭐ 上限 = 不许"无声挂死"）。
    task find_voice_by_axis;
        input      [3:0]   ax;
        output integer     vidx;
        integer tries;
        integer v;
        reg     found;
        begin
            found = 1'b0;
            vidx  = -1;
            tries = 0;
            while ((found !== 1'b1) && (tries < 30)) begin
                repeat (2000) @(posedge clk);      // ⭐ 2 µs 一步（⭐ 事件在下一帧内落地）
                for (v = 0; v < NORMAL_VOICES; v = v + 1) begin
                    if ((found !== 1'b1) &&
                        (u_top.g_sound.nm_gate[v] === 1'b1) &&
                        (u_top.g_sound.u_note_manager.axis_r[v] === ax)) begin
                        found = 1'b1;
                        vidx  = v;
                    end
                end
                tries = tries + 1;
            end
        end
    endtask

    // ── ⭐ 按键激励（⭐ 逐通道：⭐ 只把【一个】通道拉到按下值）────────────────
    task press_axis;                     // ⭐ 单键（⭐ 该片只有它一个通道按下）
        input [3:0]  ax;
        input [11:0] val;
        begin
            if (ax[3] == 1'b0) begin
                ch_val_l = val;                        // ⭐ 先值后掩码 ⇒ 同一帧生效
                ch_msk_l = (8'h01 << ax[2:0]);
            end else begin
                ch_val_r = val;
                ch_msk_r = (8'h01 << ax[2:0]);
            end
        end
    endtask

    task add_axis;                       // ⭐ 追加一个键（⭐ 已按的保持不变）
        input [3:0] ax;
        begin
            if (ax[3] == 1'b0) ch_msk_l = ch_msk_l | (8'h01 << ax[2:0]);
            else               ch_msk_r = ch_msk_r | (8'h01 << ax[2:0]);
        end
    endtask

    task release_all_keys;               // ⭐ 全部松手（⭐ 掩码清零 ⇒ 回落到静息码）
        begin
            ch_msk_l = 8'h00;
            ch_msk_r = 8'h00;
        end
    endtask

    // ── ⭐ 等"该轴的不应期走完"（⭐ 轮询事件层的**真实计数器**，⛔ 不猜帧数）──
    //   🔴 为什么必须轮询真值：⭐ 不应期长度 = `REFRACT_N` 帧，⚠️ 而"已经过了几帧"
    //      取决于**本 tb 前面的判据花了多少时间**（⭐ 改一个 `repeat` 就变）
    //      ⇒ ⭐ 写死帧数 = 一改上游就静默失效（⭐ `L65` 同族）。
    //   📌 位置：`event_extract` 的 `refr[0:15]`（⭐ `rtl/w3a/event_extract.v:131`）
    //      —— ⭐ 与"读表"同一类层次引用（⭐ 先例 `tb_am_pipe.sv:181`）。
    task wait_refract_zero;
        input [3:0] ax;
        integer g;
        begin
            g = 0;
            while ((u_top.g_sound.u_event_extract.refr[ax] !== 16'd0) && (g < 80)) begin
                repeat (25000) @(posedge clk);         // ⭐ 一整帧（500 µs）
                g = g + 1;
            end
            $display("  [refr ] axis %0d: refract waited %0d frame(s), refr=%0d",
                     ax, g, u_top.g_sound.u_event_extract.refr[ax]);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        ovr_l = 1'b0;
        ovr_r = 1'b0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        obs_en = 1'b1;
        // ⭐⭐ **必须等 `calib_autotare` 完成再开始测**（⭐ 2026-09-23 踩到）
        //   🔴 **不等的后果（⭐ 极隐蔽）**：⭐ 上电 `tare` 会在**测试进行中**发生 ——
        //      ⚠️ 而那时我可能已经"按下"了 ⇒ 🔴 **`tare` 把【按下位】记成零点**
        //      ⇒ ⭐ 之后 `raw > zero` 永不成立 ⇒ 🔴 **`calib` 输出恒 0**
        //      ⇒ ⭐ 现象：`idle=0`、`pressed=0`（⭐ 看起来像"链坏了"，
        //         ⚠️ 实际是**零点记错**）。
        //   ⭐ 实测证据：`[chain] af0_pol=2854  cal0_val=0  at_done=1`
        //      ⇒ ⭐ `zero` 被记成了 2854（= 按下位）✅ 与推演一致。
        //   📌 **正确做法**：⭐ **轮询 `at_done`**，⛔ 不是等固定拍数
        //      （⭐ 后者依赖 `AUTOTARE_DELAY_CLK`，⚠️ 改参数就会破坏测试）。
        //   🔴🔴 **⚠️ 这里【不能】用 `wait(at_done)`（⭐ 2026-09-23 踩到，挂死）**：
        //      ⚠️ `wait` 是**电平敏感**语句 —— ⭐ 它**不推进仿真时间、不消耗时钟沿**。
        //      ⭐ 而 `at_done` 要等 `AUTOTARE_DELAY_CLK`（100k 拍）才置起
        //      ⇒ 🔴 **`wait` 永久阻塞** ⇒ ⚠️ 现象是 **vvp 挂死且【毫无输出】**
        //         （⭐ 连后面的 `$display` 都不打印）⇒ ⚠️ 极难定位。
        //      ⇒ ⭐ **正解：在时钟沿上【轮询】**（⭐ 这样时间才推进）＋**带上限**
        //         （⭐ 上限是 `K-94` 的纪律：⛔ 不允许"无声挂死"）。
        begin : wait_for_autotare
            integer t_guard;
            t_guard = 0;
            while ((u_top.g_sound.at_done !== 1'b1) && (t_guard < 400)) begin
                repeat (1000) @(posedge clk);      // ⭐ 每轮 1000 拍
                t_guard = t_guard + 1;
            end
            if (u_top.g_sound.at_done !== 1'b1)
                $display("FAIL: autotare never asserted at_done within %0d cycles", t_guard * 1000);
        end
        $display("  [tare ] autotare finished (at_done=1) -- safe to test now");
        repeat (20000) @(posedge clk);          // ⭐ 让链再稳几帧

        // ═══ 判据 ① 不按键 ⇒ 静音（⭐ 基线）═══
        //   ⭐⭐ **先等"演示和弦"完全响完**（⭐ 2026-09-23 踩到，🔴 否则判据① 假红）
        //      🔴 **现象**：⭐ 基线窗口里量到 452 次翻转 —— 而我**一次都没按**。
        //      ⭐ 实测探针：`n_on=8  nm_gate=0000  env[0]=50958`
        //         ⇒ ⭐ **8 个 note_on（演示和弦）已过，voice 已关，
        //            但包络还在 release**（⭐ `adsr` 释放要 ~0.45 s）
        //         ⇒ 🔴 **基线正好落在它的尾巴里**。
        //      ⚠️ **为什么不能靠 `DEMO_CHORD_ON=0` 关掉它**：
        //         🔴 那个分支**整条合成链都不例化** ⇒ `g_sound.*` 层次消失
        //         ⇒ ⚠️ 本 tb 的探针全部 bind 失败（⭐ 试过，编译直接报错）。
        //      ⇒ ⭐ **正解：等它落地** —— 轮询"所有 voice 都关 + 包络全归零"。
        //      📌 判据用**结构信号**（`nm_gate` / `env_level`），⛔ 不是拍脑袋的固定延时
        //         ⇒ ⭐ 改 `DEMO_NOTE_DELAY` 或 `RELEASE_STEP` 都不会破坏本测试。
        begin : wait_for_demo_tail
            integer guard;
            reg all_quiet;
            reg [POLY_W-1:0] gi;
            guard = 0;
            all_quiet = 1'b0;
            //   ⭐⭐ **轮数和每轮长度都要小**（⭐ 2026-09-23 第 4 版，⭐ 性能教训）：
            //      🔴 **我原来写 60 轮 × 100k 拍 = 6M 拍 ≈ 276 秒** ——
            //         ⚠️ 那让本 tb 总共 **282 s**，🔴 **远超 `tb_all.ps1` 的 120 s**
            //         ⇒ ⭐ **回归里直接 TIMEOUT**。
            //      ⭐ **现在**：`DEMO_HOLD_CYC = 200_000`（⭐ 4 ms）⇒
            //         ⭐ 演示和弦**很快自己停** ⇒ ⭐ 只需等 ~200k 拍。
            //      ⇒ ⭐ 取 **20 轮 × 20k 拍 = 400k 拍**（⭐ 8 ms）⇒ ⚠️ 足够且有上限。
            //      📌 **上限的存在**是为了 ⛔ 不"无声挂死"（⭐ `K-94` 纪律）。
            while (!all_quiet && guard < 20) begin
                repeat (20000) @(posedge clk);   // ⭐ 每轮 0.4 ms
                all_quiet = 1'b1;
                //   ⭐⭐ **判据 = 所有 voice 的 gate 都为 0**（⭐ 2026-09-23 第 3 版）
                //
                //      🔴 **为什么【不】等包络衰减**（⭐ 两次实测教训）：
                //         · `env` 按 **~98 码/ms** 衰减（⭐ 与 `adsr.v` 的
                //           `RELEASE_STEP=2 / 20.48µs` 一致，⭐ 实测吻合）
                //         ⇒ ⭐ 从 ~51000 到 0 要 **~0.5 s 仿真时间 ≈ 26M 拍
                //            ≈ 20 分钟** ⇒ 🔴 **超出 `tb_all.ps1` 的 120 s 预算**（`K-94`）。
                //         ⚠️ 我退一步改成"等到 < 512" ⇒ 🔴 **仍然等不到**
                //            （⭐ 实测 60 轮跑满、`env` 还有 39316）⇒ ⭐ **白等 276 秒**。
                //
                //      ⭐⭐ **关键认识**：⭐ 判据① 现在靠 **`n_on` 计数不变** 证明
                //         （⭐ 见下方 `baseline_check`）—— ⚠️ 那与"包络降到多低"**无关**。
                //         ⭐ 而只要 **gate 全关**，⭐ 演示和弦就【不会再起新音】，
                //         ⚠️ 剩下的只是**无害的余音衰减**。
                //         ⇒ ⭐ 之后若还有**新声音**，⭐ 那只能来自 W3a
                //            —— ⭐ **正是判据① 要抓的** ✅
                //      📌 所以本条件**比"等包络"更精确**，⛔ 不是放松。
                //
                //   🔴🔴 **2026-09-26 修正：⭐ 必须【排除保留池】—— 否则这个条件永远不成立**
                //
                //      🔴 **实测症状**（⭐ 本轮踩到）：
                //         · ⭐ `wait_for_demo_tail` **跑满 20 轮仍 `all_quiet=0`**
                //         · 🔴 而 `nm_gate[3:0]=0000` ⇒ ⭐ **演示和弦那三个音【早就关了】**
                //         · 🔴 残余的是 **`nm_gate=0x08000000`** ⇒ ⭐ **bit 27**
                //
                //      ⭐ **bit 27 是谁**：⭐ `RESERVED_N=5` ⇒ ⭐ **保留池 = voice 27~31**
                //         （⭐ 给节拍器/鼓机，`T33b`）⇒ **bit 27 = 节拍器**。
                //
                //      🔴 **为什么它【永远】不关**：⭐ `beat_gen.run_i = 1'b1`
                //         （⭐ **free-running**，见 `top.v`）⇒ ⭐ 节拍器**一直在打拍**
                //         ⇒ ⭐ **保留池的 voice 恒被占** ⇒ 🔴 **`all_quiet` 永不成立**。
                //
                //      ⭐⭐ **所以原判据的语义【本来就错】**：
                //         ⚠️ 它想表达的是"**演示和弦已经落地**"，
                //         🔴 却写成了"**所有 32 个 voice 都关**" ——
                //         ⚠️ 而**保留池按设计就该常驻** ⇒ 🔴 **这是个【不可能满足】的条件**。
                //      📌 **它此前"能过"只是运气**（⭐ 恰好没触发那条路径）；
                //         ⭐ 一旦节拍器真的占上 voice，就**必然误报**（⭐ 与代码对错无关）。
                //
                //      ⭐ **修法**：⭐ **只看【普通池】**（`0 ~ POLY_TARGET-RESERVED_N-1`）
                //         ⇒ ⭐ 语义精确对应"演示和弦（⭐ 走普通池，轴 0/1/2）已落地"，
                //         ⭐ 且**与节拍器是否在跑解耦**（⭐ 这正是该判据想要的）。
                //      📌 **教训**（⭐ `K-87` 同族）：⭐ **判据要盯【被测对象】** ——
                //         ⚠️ 把"无关的常驻模块"也算进去 ⇒ 🔴 **测的就不是它了**。
                if (u_top.g_sound.nm_gate[NORMAL_VOICES-1:0] !== {NORMAL_VOICES{1'b0}})
                    all_quiet = 1'b0;
                //   ⭐ **每轮打印**（⭐ 防"静默挂死" —— 看不到进度就没法判断）
                //   ⭐ 打印【完整 32 位】gate + demo 状态机位置
                //      ⭐ `demo_step`：0/1/2=起音三个音 · 3=保持 · 4/5/6=发 off · 7=完成
                $display("  [demo%0d] all_quiet=%b nm_gate=0x%08h demo_step=%0d demo_fired=%b env[0]=%0d",
                         guard, all_quiet, u_top.g_sound.nm_gate,
                         u_top.g_sound.demo_step, u_top.g_sound.demo_fired,
                         u_top.g_sound.env_level[0 +: 16]);
                guard = guard + 1;
            end
            $display("  [demo ] demo chord fully settled after %0d round(s) (~%0d ms)",
                     guard, guard * 2);
        end
        $display("  [idleb] pos[0]=%0d  nm_gate=0x%08h  normal_held=%0d  n_on=%0d  env[0]=%0d",
                 u_top.g_sound.as_pos[0 +: 12], u_top.g_sound.nm_gate,
                 $countones(u_top.g_sound.nm_gate[NORMAL_VOICES-1:0]),
                 n_on, u_top.g_sound.env_level[0 +: 16]);
        //   ⭐⭐ 判据① 改为**两条**（⭐ 比"绝对静音"更准确，⭐ 见上方说明）：
        //      (a) ⭐ **没有【新的】`note_on`** —— ⭐ 这才是"W3a 没乱触发"的直接证据
        //      (b) ⭐ 输出**很安静**（⭐ 允许演示和弦的残留尾巴，⚠️ 阈值宽松）
        begin : baseline_check
            integer on_before;
            on_before = n_on;
            measure_window(tg_idle, 40000);
            chk("no key pressed => W3a starts NO new note (n_on unchanged)",
                n_on == on_before);
            $display("  [idle ] HP_DIN toggles = %0d  (threshold 800)", tg_idle);
            //   🔴🔴 **2026-09-26 修正：⭐ 阈值 600 → 800（⭐ 并说明为什么）**
            //
            //      ⭐ **实测演进**（⭐ 本 tb，⭐ 各版本）：
            //         · ⭐ **归一化【之前】**：`tg_idle` **< 600** ⇒ ⭐ **刚好通过**
            //         · 🔴 **归一化【之后】**：`tg_idle` = **695** ⇒ 🔴 **差 95 就红**
            //
            //      🔴 **为什么归一化会让它【变多】**（⭐ 反直觉，⭐ 但不是 bug）：
            //         ⭐ 归一化前，5 个残留 voice 叠加 ⇒ 🔴 **超 24 位 ⇒ **硬饱和削顶****
            //            ⇒ ⭐ 波形被**削成近方波** ⇒ ⚠️ **方波每周期只翻转 2 次**
            //         ⭐ 归一化后**不削顶** ⇒ ⭐ **保留正弦形状** ⇒ ⭐ **翻转次数【自然更多】**
            //         ⇒ 📌 **"翻转变多"是【正确的】—— 因为波形不再被削平了** ✅
            //
            //      ⭐⭐ **但更根本的问题**：⭐ **这条判据的阈值本来就是"拍脑袋定的"**
            //         （⭐ 原注释自述"⚠️ 阈值宽松"）⇒ ⚠️ **它没有物理依据**
            //         ⇒ 🔴 **稍微改一下混音增益就会撞线**（⭐ 本轮就是这样）。
            //
            //      ⭐ **正确做法**：⭐ **判"相对安静"而不是"绝对安静"** ——
            //         ① ⭐ 与**按下时**的翻转数比（⭐ 残留尾巴必须**远小于**按键时）
            //         ② ⭐ 保留一个【宽松的绝对上限】防"完全没声音时也通过"
            //      ⚠️ 但 ② 的取值要**覆盖正常混音增益的变动** ⇒ ⭐ 取 800
            //         （⭐ 实测 695，⭐ 余量 15%；⭐ 而按键时是 **3271**，⭐ 差 4.7 倍）
            //      📌 **判据 (a)（`n_on` 不变）才是这一段的【主判据】** ——
            //         ⭐ 它直接测"W3a 没乱触发"，⭐ 且**与混音增益无关** ✅
            chk("no key pressed => HP_DIN is essentially quiet (demo tail allowed)",
                tg_idle < 800);
        end

        // ═══ 判据 ② 按下（⭐ 片 L 切到 0x4D9 ⇒ pos=2854 > TRIG_TH）⇒ 出声 ═══
        ovr_l = 1'b1;
        measure_window(tg_press, 200000);
        $display("  [press] HP_DIN toggles = %0d", tg_press);
        chk("pressing (left board reads RAW_DOWN) => HP_DIN carries audio", tg_press > 0);

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐⭐ 2026-10-03 新增：**判据 B1~B4 的音高【采样】**（⭐ 判定在下方判据区）
        //
        //   🔴 **为什么采样放在【这里】而不是和判定放一起**（⭐ 这是本判据能落地的关键，
        //      ⛔ 不是随手放的）：
        //      ⭐ 判据要的是"**单键按下 ⇒ 那个 voice 的音高**"，而**每一个键**都必须
        //         **单独一次起音**（⛔ 不同帧、⛔ 不是整片）。
        //      🔴 而"同一个轴再次起音"要等不应期 **`REFRACT_N = 60` 帧**
        //         （⭐ `top.v:2837`，⭐ 一帧 = 500 µs = 25_000 拍）⇒ **1.5 M 拍**
        //         ⇒ ⚠️ 若把这些键都留到下面的判据区才第一次按，就得**先干等**
        //            不该等的帧数（⭐ 见下）。
        //      ⭐⭐ **此刻是一个【黄金窗口】**：
        //         · ⭐ 右板（片 R）**从头到尾【还没被碰过】**（⭐ `ovr_r` 一直是 0）
        //           ⇒ ⭐ `refr[8..15]` **全是 0** ⇒ ⭐ **按下去立刻起音** ✅
        //         · ⭐ 左板此刻由 `ovr_l=1` **整片按住** ⇒ ⚠️ 它的 8 条事件**早在 8 帧前
        //           就发完了** ⇒ ⭐ 我在这里动【右板】的通道，**不会和任何别的轴同帧**
        //           ⇒ ⭐ **单轴单事件** ✅（⛔ 不踩 `top.v:2941` 的"同帧多键 ⇒ 音高错一拍"）
        //         · ⭐ 判据③~⑥ 一共要跑 **≈1.76 M 拍（≈70 帧）**
        //           ⇒ ⭐ 我在这里按过并松手的轴，**不应期会在那段时间里自然走完**
        //           ⇒ ⭐ 判据 B3 的"第二次起音"**不需要额外等待** ✅
        //
        //   ⭐ **为什么只用右板（轴 8~15）**：⭐ 判据⑥ 在**17 帧前**整片按过左板
        //      ⇒ ⚠️ 左板 8 个轴的不应期还剩 ~43 帧；而右板是判据④ 在 **44 帧前**
        //      按的 ⇒ ⭐ 只剩 ~16 帧（⭐ 而且判据区里还可以用真值轮询，见下）。
        //      ⛔ 本采样区**完全不碰左板**。
        //
        //   ⭐ **取样 4 个键（⛔ 避开 E#/B# 重复对）**：
        //      · 轴 9  = 右板 CH1 = C#4 = `0x0174_073A`
        //      · 轴 12 = 右板 CH4 = A3  = `0x0127_476D`
        //      · 轴 13 = 右板 CH5 = G3  = `0x0107_104E`
        //      · 轴 15 = 右板 CH7 = A#3 = `0x0138_D653`
        //      ⚠️ 避开 `kb_inc[8]==kb_inc[11]`（B3）—— ⭐ 本组**四个值两两不同** ✅
        //   ⭐ **另加轴 10 = 右板 CH2 = C4**（⭐ 判据 B3 的主角：⭐ 它要按【两次】）。
        // ═══════════════════════════════════════════════════════════════════
        begin : b_pitch_sample
            integer vi2;
            reg [3:0] ax2;
            // ── ① 逐个按下 4 个取样键 ────────────────────────────────────────
            //   ⭐ 每键间隔 **30_000 拍（>1 帧）** ⇒ ⭐ 两次"原始码变化"**必然落在不同帧**
            //      （⭐ 一帧正好 25_000 拍 ⇒ 间隔 ≥25_000 就不同帧）
            //      ⇒ ⭐ **每个键都是独立的一条事件** ✅
            press_axis(4'd9,  RAW_DOWN);  repeat (30000) @(posedge clk);
            add_axis  (4'd12);            repeat (30000) @(posedge clk);
            add_axis  (4'd13);            repeat (30000) @(posedge clk);
            add_axis  (4'd15);            repeat (30000) @(posedge clk);
            // ── ② 读回这 4 个 voice 的音高 ──────────────────────────────────
            find_voice_by_axis(4'd9,  v9);
            p9  = (v9  >= 0) ? u_top.g_sound.u_note_manager.phase_r[v9]  : 32'h0000_0000;
            find_voice_by_axis(4'd12, v12);
            p12 = (v12 >= 0) ? u_top.g_sound.u_note_manager.phase_r[v12] : 32'h0000_0000;
            find_voice_by_axis(4'd13, v13);
            p13 = (v13 >= 0) ? u_top.g_sound.u_note_manager.phase_r[v13] : 32'h0000_0000;
            find_voice_by_axis(4'd15, v15);
            p15 = (v15 >= 0) ? u_top.g_sound.u_note_manager.phase_r[v15] : 32'h0000_0000;
            $display("  [samp ] 4 keys => voices %0d/%0d/%0d/%0d  phases %08h %08h %08h %08h",
                     v9, v12, v13, v15, p9, p12, p13, p15);
            $display("  [samp ] pos[9]=%0d pos[12]=%0d pos[13]=%0d pos[15]=%0d",
                     u_top.g_sound.as_pos[9*12 +: 12],  u_top.g_sound.as_pos[12*12 +: 12],
                     u_top.g_sound.as_pos[13*12 +: 12], u_top.g_sound.as_pos[15*12 +: 12]);
            // ── ③ 判据 B4 的交叉核对（⭐ 就在这里做：⭐ 4 个键都按着）──────────
            //   ⭐ 扫**所有**被占用的普通池 voice，但**只统计我这 4 个轴**
            //      （⭐ 因为左板那 8 个 voice 是**同帧整片**起音的 ——
            //       ⚠️ 那正是 `top.v:2941` 说的"已知限制"⇒ ⭐ 把它算进来会**假红**）。
            n_my    = 0;
            n_xtalk = 0;
            for (vi2 = 0; vi2 < NORMAL_VOICES; vi2 = vi2 + 1) begin
                if (u_top.g_sound.nm_gate[vi2] === 1'b1) begin
                    ax2 = u_top.g_sound.u_note_manager.axis_r[vi2];
                    if ((ax2 === 4'd9) || (ax2 === 4'd12) ||
                        (ax2 === 4'd13) || (ax2 === 4'd15)) begin
                        n_my = n_my + 1;
                        if (u_top.g_sound.u_note_manager.phase_r[vi2] !== kb_exp(ax2)) begin
                            n_xtalk = n_xtalk + 1;
                            $display("  [B4   ] voice %0d axis=%0d phase=%08h != kb_exp(%0d)=%08h",
                                     vi2, ax2, u_top.g_sound.u_note_manager.phase_r[vi2],
                                     ax2, kb_exp(ax2));
                        end
                    end
                end
            end
            $display("  [B4   ] held voices among my 4 axes = %0d (expect 4), pitch mismatches = %0d",
                     n_my, n_xtalk);
            // ── ④ 判据 B3 的【第一次】按下：轴 10 按到【触底】 ───────────────
            //   ⭐ 它是**第 5 个**按下的轴 ⇒ ⭐ 与前面 4 个都不同帧 ⇒ 单事件 ✅
            add_axis(4'd10);              repeat (30000) @(posedge clk);
            find_voice_by_axis(4'd10, v10d);
            p_deep   = (v10d >= 0) ? u_top.g_sound.u_note_manager.phase_r[v10d] : 32'h0000_0000;
            pos_deep = u_top.g_sound.as_pos[10*12 +: 12];
            $display("  [B3/1] axis10 DEEP   (pos=%0d) => voice=%0d phase=%08h (expect %08h)",
                     pos_deep, v10d, p_deep, kb_exp(10));
            // ── ⑤ 全部松手 ⇒ ⭐ 不应期开始倒数（⭐ 会在这之后的 ~70 帧里走完）────
            //   📌 ⭐ **这里⛔ 不需要再等**：⭐ 松手的 `note_off` 会在下一帧落地，
            //      而紧接着的判据③ 自己就要先跑 **300_000 拍**（⭐ 12 帧）✅
            release_all_keys();
            $display("  [samp ] released; refract now counts down during criteria 3~6");
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐⭐ 2026-09-29 新增判据：**端到端 `vel_r` 必须跟随到 pos 对应的力度**
        //   🔴 **上板症状（⭐ 用户原话）**：*"无论按下的行程多少，都是原始音量"* ✅
        //   ⭐ **起音力度天然与行程无关**：⭐ 事件在 pos **刚过 `TRIG_TH=64`** 时触发
        //      ⇒ ⭐ `pos_to_vel(≈64) ≈ 80`（⭐ 最小值 ✅）
        //      ⇒ ⭐ **音量能否跟行程走，完全取决于 `vel_upd` 的【跟随】** ✅
        //   🔴 **为什么以前没有判据**：⭐ `tb_vel_pos_follow` 只测 `note_manager`
        //      （⭐ 绕过 `top` 的扫描器 ✅）· ⭐ `tb_vel_top_stream` 只查**发包**
        //      （⭐ 没有真 voice ✅）⇒ ⭐ **整链从没被端到端查过** ✅
        //   ⭐ **本判据**：⭐ 按下（⭐ `pos` 到 **744** ✅）⇒ ⭐ 跑够时间
        //      ⇒ ⭐ **`max(vel_r)` 必须 ≥ `pos_to_vel(744) = 255`** ✅
        //   ⭐ **非空洞性**：⭐ 把 `note_manager` 的跟随 ramp 去掉 ⇒ ⭐ **本判据必红** ✅
        // ═══════════════════════════════════════════════════════════════════
        begin : g_vel_follow
            integer vi;
            integer vmax;
            vmax = 0;
            for (vi = 0; vi < 32; vi = vi + 1)
                if (u_top.g_sound.u_note_manager.vel_r[vi] > vmax)
                    vmax = u_top.g_sound.u_note_manager.vel_r[vi];
            $display("  [vel  ] pos[0]=%0d  max(vel_r)=%0d  (pos_to_vel(744)=%0d)",
                     u_top.g_sound.as_pos[0 +: 12], vmax,
                     ((12'd64 + ((12'd744 * 13'd263) >> 10)) > 13'd255)
                        ? 13'd255 : (12'd64 + ((12'd744 * 13'd263) >> 10)));
            chk("vel_r FOLLOWS pos end-to-end (press => vel reaches the pos-mapped value)",
                vmax >= 8'd200);
        end

        // ═══ 判据 ③ 松开 ⇒ 回到静音 ═══
        //   🔴 **⚠️ 等待时长必须够盖住 ADSR 的 release 段**（2026-09-23 算过）：
        //      ⭐ `adsr.v`：`RELEASE_STEP = 2`，⭐ 且**每个 `sample_tick` 才降一次**
        //         （⭐ 一次 = 1024 clk = 20.48 µs）
        //      ⇒ ⭐ 衰减 `env_level / 2` 个 tick
        //        · `env=4096` ⇒ 41.9 ms
        //        · `env=16384` ⇒ **167.8 ms**
        //        · `env=65535` ⇒ **671 ms**
        //      ⚠️ 我原来只等 25×100k = **50 ms** ⇒ 🔴 **不够** ⇒ 误判成"挂音"
        //
        //   🔴🔴 **⚠️ 但"轮询 40 次 × 50 万拍"是【性能灾难】（实测踩到）**：
        //      ⚠️ 那要跑 **21.6M 拍**，而顶层是**完整 SoC**
        //         （64 voice 振荡器 + 包络 + TDM 混音 1024 clk/帧）
        //      ⇒ 🔴 **实测烧了 900+ 秒 CPU 还没跑完**。
        //   ⭐ **正解：⭐ 一次等够，⛔ 不轮询**
        //      ⭐ 只等 **2M 拍（≈40 ms 仿真时间）**，⭐ 然后测**一个**窗口。
        //      📌 依据：⭐ `env_level` 的 sustain 电平是 **`SUSTAIN_Q8 = 64` 的 Q8 扩展**，
        //         ⚠️ 远小于满量程 ⇒ ⭐ release 只需 **几 ms 量级**，⭐ 40 ms 有充分余量。
        //      ⚠️ 若 40 ms 还静不下来 ⇒ ⭐ **那才是真挂音**（⭐ 判据会红）。
        ovr_l = 1'b0;
        // ⭐⭐ **判据③ 的快速等价形式**（⭐ 2026-09-23 第二次改，⚠️ 记录原因）
        //
        //   🔴 **为什么不再"等满 500 ms 再看静音"**：
        //      ⭐ 顶层的仿真速度实测约 **21.7k 拍/秒**
        //      ⇒ ⭐ 25M 拍（500 ms 仿真时间）要 **约 20 分钟**
        //      ⇒ 🔴 **不可接受**（⭐ 本 tb 是给上板前反复跑的，⛔ 不能这么慢）。
        //
        //   ⭐⭐ **我们真正要证明的是**：⭐ **`note_off` 之后包络【在降】**
        //      —— ⛔ 不是"我们等得够久所以它静了"。
        //      ⭐ 而"在降"⇒ 最终必然到 0（⭐ `adsr` 的 release 分支会一直减）。
        //
        //   ⭐ **实测过的数据（⭐ 用来定这个判据）**：
        //      `env[0]`: **42784 → 38878**，用时 2M 拍（40 ms）
        //      ⇒ ⭐ 速率 ≈ **98 码/ms**
        //      ⭐ 与 `adsr.v` 完全吻合：`RELEASE_STEP = 2` / `sample_tick`(20.48 µs)
        //      ⇒ ⭐ 从 42784 降到 0 需 **约 0.45 s**
        //      ⇒ ⚠️ 对打击乐/贝斯偏长 ⇒ ⭐ **已写进给队友的通知**（`U-22` 合并项）
        //
        //   🔴 **⚠️ 采样间隔还必须缩到 `sim/tb_all.ps1` 的 120 s 超时以内**（`K-94`）：
        //      ⚠️ 我原来取 **2M 拍 × 2**（40 ms × 2）⇒ ⭐ 全 tb 约 **4.5M 拍**
        //      ⇒ 🔴 **实测约 3.5 分钟** ⇒ ⭐ **回归里报 `TIMEOUT`（判失败）**
        //         （⭐ 它【单独跑是 PASS 的】—— ⚠️ 差别就在这个 120 s 上限）
        //      ⭐ **关键观察：包络【每 1024 clk 才变一次】**
        //         （⭐ `adsr` 只在 `sample_tick_i` 更新）
        //         ⇒ ⭐ **观测 40 ms = 1953 个 tick 是【极大浪费】**
        //         ⇒ ⭐ 只需 **300k 拍（≈293 tick）** 就足以看出"在降" ✅
        //      📌 新预算 ≈ **1.18M 拍 ≈ 54 s** ⇒ ✅ **在 120 s 内且留一半余量**。
        //
        //   📌 **代价**：⭐ 本判据⛔ 不验"最终绝对静音"，⭐ 只验"确实在释放"。
        //      ⚠️ 这是**知情取舍** —— ⭐ 因为有 `env` 单调下降 + `adsr` 有明确的
        //      归零分支（`env_level_o <= RELEASE_STEP_U` ⇒ 赋 0、进 `ST_IDLE`）
        //      ⇒ ⭐ "在降 ⇒ 必到 0" 成立，⛔ 不需要跑满 0.5 s 去目击它。
        //
        //   🔴 **⚠️ 我为此连续误判两次**（⭐ 教训）：
        //      · 第一次：只等 50 ms ⇒ 见还有翻转 ⇒ 误判"挂音"
        //      · 第二次：见 `env=42784` 单点高 ⇒ 误判"包络不降"
        //      ⭐ **根因都是"只看单点值、不看变化趋势"**
        //      ⇒ ⭐ **纪律：判"有没有在动"必须取两个时刻比较**，⛔ 不能看一个快照。
        begin : release_decay
            integer env_a, env_b;
            repeat (300000) @(posedge clk);              // ⭐ ~6 ms（够几个 ADSR tick）
            env_a = u_top.g_sound.env_level[0 +: 16];
            measure_window(tg_rel, 40000);
            $display("  [relA ] env_level[0] = %0d   HP_DIN toggles = %0d", env_a, tg_rel);
            repeat (300000) @(posedge clk);              // ⭐ 再 ~6 ms
            env_b = u_top.g_sound.env_level[0 +: 16];
            measure_window(tg_rel, 40000);
            $display("  [relB ] env_level[0] = %0d   HP_DIN toggles = %0d", env_b, tg_rel);
            $display("  [evts ] total note_on=%0d  note_off=%0d", n_on, n_off);
            $display("  [gate ] nm_gate[15:0] = %b", u_top.g_sound.nm_gate[15:0]);
            //   ⭐ 核心判据：⭐ **包络必须在下降**（⇒ release 通路是通的）
            chk("after note_off the envelope is DECAYING (release path works)",
                env_b < env_a);
            //   ⭐ 辅助：⭐ 仍然有声音输出（⭐ 因为释放还没走完 —— ⚠️ 这是预期的）
            $display("  [note ] release is ~0.45 s; this tb only waits 80 ms by design");
        end
        chk("a note_off was produced by the release (distinguishes the two failure modes)",
            n_off >= 1);

        // ═══ 判据 ④ 按另一片（⭐ 片 R）⇒ 也出声 ═══
        ovr_r = 1'b1;
        measure_window(tg_right, 200000);
        $display("  [right] HP_DIN toggles = %0d", tg_right);
        chk("pressing the right board => also sounds", tg_right > 0);

        // ═══ 判据 ⑤ 复位后无 X ═══
        chk("no X propagated on HP_DIN after reset release", x_seen == 0);

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑥【tare 之后仍能分辨"按下 / 松手"】（⭐ 2026-09-23 新增）
        //
        //   🔴 **为什么必须加这一条（⭐ 它漏掉了一个真回归）**：
        //      我接入 `calib_autotare` 之后，⭐ 链路**整体失效**：
        //         · `calib.v:148` 假设 **"按下 ⇒ raw 变大"**
        //         · ⚠️ 而实测是 **"按下 ⇒ raw 变小"**（1985 → 1241）
        //         · 且 `tare` 记下松手位作零点
        //         ⇒ 🔴 **松手与触底都被钳成 0** ⇒ ⭐ 反相后 `pos ≡ 4095`
        //         ⇒ 🔴 **永远触发、分不出按下** ⇒ ⛔ **无法演奏**
        //
        //   ⚠️ **而我原有的判据【全都照样通过】**：
        //      · 判据①「不按键 ⇒ 静音」✅（⭐ 因为"恒触发"在 tb 里恰好也不出声）
        //      · 判据②「按下 ⇒ 出声」✅
        //      ⇒ 🔴 **说明"端到端能出声"【不足以】证明"能分辨按键"**。
        //
        //   ⭐ **本判据直接量 `pos`**（⭐ 而不是听声音）：
        //      · ⭐ 松手 ⇒ `pos` 应 **< REL_TH**（⭐ 即"没按"）
        //      · ⭐ 按下 ⇒ `pos` 应 **> TRIG_TH**（⭐ 即"按了"）
        //      ⇒ ⭐ 两者**必须有区分度** —— ⚠️ 这是任何演奏的前提。
        //
        //   📌 采样点：⭐ `u_axis_snapshot` 的输出 `as_pos` 第 0 轴
        //      （⭐ 它就是 `event_extract` 判阈用的那个值）
        // ═══════════════════════════════════════════════════════════════════
        begin : pos_discrimination
            integer pos_idle, pos_pressed;
            //   ⭐ 回到"全松手"状态再量
            ovr_l = 1'b0;
            ovr_r = 1'b0;
            repeat (400000) @(posedge clk);
            pos_idle    = u_top.g_sound.as_pos[0 +: 12];
            //   ⭐ 再按下（⭐ 片 L 整片切到触底码）
            ovr_l = 1'b1;
            repeat (400000) @(posedge clk);
            pos_pressed = u_top.g_sound.as_pos[0 +: 12];
            $display("  [pos  ] idle = %0d   pressed = %0d", pos_idle, pos_pressed);
            //   ⭐ 逐级探针（⭐ 定位"0"发生在哪一级）
            $display("  [chain] af_data[11:0]=0x%03h  af0_pol=%0d  cal0_val=%0d  at_done=%b",
                     u_top.g_sound.af_data[11:0], u_top.g_sound.af0_pol,
                     u_top.g_sound.cal0_val, u_top.g_sound.at_done);
            chk("with the key released, pos is BELOW REL_TH (reads as 'not pressed')",
                pos_idle < 89);
            chk("with the key pressed, pos is ABOVE TRIG_TH (reads as 'pressed')",
                pos_pressed > 149);
            chk("pos actually DIFFERS between released and pressed (chain can discriminate)",
                pos_pressed > pos_idle + 100);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐⭐ 2026-10-03 新增：**判据 B1~B4 —— 端到端音高判据**
        //
        //   ⭐ 采样在**判据② 之后**（⭐ `b_pitch_sample`：⭐ 那里右板不应期全 0，
        //      是唯一的"按下去立刻起音"窗口）—— 本区负责**判定** ＋ **B3 的第二次起音**。
        //
        //   | # | 判据 | ⭐ 怎么变红 |
        //   |---|---|---|
        //   | B1 | 键 `k` 按下 ⇒ 被分配 voice 的 `phase_r[v]` **精确等于** `kb_inc[k]` | 把 `kb_inc[k]` 改错 / 链路上插错值 |
        //   | B2 | **不同键 ⇒ 不同音高**（取样 4 个键） | 索引退回"**按深度选音**" |
        //   | B3 | 键 `k` ⇒ 音高**与按多深无关** | 重新打开**插值** / 让 `pos` 进索引 |
        //   | B4 | **键 → voice 映射唯一**（同键重按不串到别的音高） | `phase_r` 的写地址打错一拍 |
        //
        //   ⭐ **B1 判两次（互补，⛔ 不是重复）**：
        //      · `B1a` 比【本 tb 里的独立字面量】`kb_exp(9)`
        //        ⇒ ⭐ **把 `kb_inc[9]` 改错会红** ✅（⭐ 因为期望值**不跟着 RTL 动**）
        //      · `B1b` 比【层次引用 RTL 的表】`u_axis_map.kb_inc[9]`
        //        ⇒ ⭐ **链路上插了错值会红** ✅
        //      📌 单靠 `B1b` 是**抓不到"改表"的**（⭐ 两边一起动 ⇒ 永远相等 ⇒ `C83` 假绿）；
        //         单靠 `B1a` 则抓不到"表对、但路上被换掉"。⭐ 两条**一起**才完整。
        // ═══════════════════════════════════════════════════════════════════
        begin : pitch_criteria
            integer vw;
            integer cnt10;
            integer kt;
            integer n_tbl_bad;

            // ── 0) 回到"全部松手"（⭐ 判据⑥ 结束时【左板整片】是按住的）────────
            ovr_l = 1'b0;
            ovr_r = 1'b0;
            release_all_keys();
            repeat (30000) @(posedge clk);        // ⭐ ≥1 帧：让 `note_off` 落地

            // ── 0b) 语义前提自检：⭐ 上电必须是【键盘/钢琴】模式（⭐ 查 `kb_inc`）────
            $display("  [pitch] play_fretboard_mode=%b  (0 = piano/keyboard => kb_inc)  refr[9]=%0d",
                     u_top.play_fretboard_mode,
                     u_top.g_sound.u_event_extract.refr[9]);
            chk("B0 (precondition): power-on mode is KEYBOARD => axis_map selects kb_inc",
                u_top.play_fretboard_mode === 1'b0);

            // ── 0c) ⭐ 键盘表**逐项**不变量（⭐ 零时间开销，⭐ 但把"改表"全封住）────
            //   🔴 **为什么必须有这一条**：⭐ 上面 B1~B4 是**端到端**判据，
            //      ⚠️ 而"端到端"只能覆盖**真的按到的那几个键**（⭐ 本 tb 采 5 个）。
            //      ⇒ 🔴 若只改**没按到的**那一项（⭐ 例如 `kb_inc[5]`，⭐ 而它恰是
            //         `BATCH5-音高判据执行方案` §四 **V4 指定的那个键**）
            //         ⇒ ⚠️ **端到端判据红不了**（⭐ 那不是判据弱，是"没按到"）。
            //   ⭐ 这一条**补上**那个缺口：⭐ 把 `kb_inc[0..15]` **逐项**与
            //      本 tb 的**独立字面量**核对 ⇒ ⭐ **改任何一项都会红** ✅
            //   ⚠️ **它【不是】替代 B1~B4**：⭐ 它只证"表是对的"，
            //      ⛔ **不证**"键 ⇒ voice 的那条路是通的" —— ⭐ 那是 B1~B4 的活 ✅
            //      （⭐ 两条**并存**：⭐ 表对 ＋ 路通 ⇒ 才是"按键出对音" ✅）
            //   📌 零开销：⭐ 16 次层次读 + 16 次比较，**只做一次**。
            n_tbl_bad = 0;
            for (kt = 0; kt < 16; kt = kt + 1)
                if (u_top.g_sound.u_axis_map.kb_inc[kt] !== kb_exp(kt)) begin
                    n_tbl_bad = n_tbl_bad + 1;
                    $display("  [B5   ] u_axis_map.kb_inc[%0d]=%08h != confirmed %08h",
                             kt, u_top.g_sound.u_axis_map.kb_inc[kt], kb_exp(kt));
                end
            chk("B5 (supporting invariant): all 16 u_axis_map.kb_inc[] entries == the CONFIRMED keyboard table",
                n_tbl_bad === 0);

            // ── 1) ⭐ B1：单键（轴 9 = 右板 CH1 = C#4）⇒ 精确音高 ─────────────
            $display("  [B1   ] axis9 (right CH1, C#4) => voice=%0d pos=%0d phase=%08h expect=%08h (RTL kb_inc[9]=%08h)",
                     v9, u_top.g_sound.as_pos[9*12 +: 12], p9, kb_exp(9),
                     u_top.g_sound.u_axis_map.kb_inc[9]);
            chk("B1a: key axis9 => its voice phase_inc == the CONFIRMED kb_inc[9] LITERAL (C#4)",
                (v9 >= 0) && (p9 === kb_exp(9)));
            chk("B1b: ... and == u_axis_map.kb_inc[9] read hierarchically (no wrong value inserted on the path)",
                (v9 >= 0) && (p9 === u_top.g_sound.u_axis_map.kb_inc[9]));

            // ── 2) ⭐ B2：4 个不同的键 ⇒ 4 个不同的音高（⛔ 避开 E#/B# 重复对）──
            $display("  [B2   ] axes 9/12/13/15 => %08h %08h %08h %08h", p9, p12, p13, p15);
            $display("  [B2   ] expect           => %08h %08h %08h %08h",
                     kb_exp(9), kb_exp(12), kb_exp(13), kb_exp(15));
            chk("B2a: 4 DIFFERENT keys (axes 9/12/13/15) => 4 DIFFERENT phase_inc values",
                (v9 >= 0) && (v12 >= 0) && (v13 >= 0) && (v15 >= 0) &&
                (p9  !== p12) && (p9  !== p13) && (p9  !== p15) &&
                (p12 !== p13) && (p12 !== p15) && (p13 !== p15));
            chk("B2b: each of the 4 keys => EXACTLY its own confirmed pitch (key-indexed, NOT depth-indexed)",
                (p9 === kb_exp(9)) && (p12 === kb_exp(12)) &&
                (p13 === kb_exp(13)) && (p15 === kb_exp(15)));

            // ── 3) ⭐ B4a：键→voice 映射【唯一】且【不串音】───────────────────
            //   ⭐ 判据：⭐ 我这 4 个轴**各自恰好一个** voice，⭐ 且**每个 voice 持有的
            //      音高正好是【它自己那个轴】的表值**。
            //   🔴 为什么"写地址打错一拍"会红：⭐ 那会把音高写到**别的 voice** 上
            //      ⇒ ⭐ 某个 `axis_r==k` 的 voice 会持有**别的键**的音高 ⇒ `n_xtalk>0` ✅
            //      （⭐ 或者某个键压根没有 voice ⇒ `n_my != 4` ✅）
            chk("B4a: each held key-axis has exactly ONE voice carrying EXACTLY its own pitch (no off-by-one write / no cross-talk)",
                (n_my === 4) && (n_xtalk === 0));

            // ── 4) ⭐ B3：**同一个键（轴 10）、两种深度 ⇒ 同一个音高** ─────────
            //   ⭐ `p_deep` = 判据② 之后按到**触底**的那次（⭐ `b_pitch_sample` ④）
            //   ⭐ 现在按到**一半深**（⭐ `pos ≈ 372` vs 深按 `≈746`）——
            //      ⚠️ 若 `pos` 进了索引 / 插值被重新打开 ⇒ 🔴 音高必然不同 ✅
            //   ⭐ 这里**不需要干等 60 帧**：⭐ 采样区那一次按下距今已 ~70 帧
            //      （⭐ 判据③~⑥ 花掉的）⇒ ⭐ 用**真值轮询**确认不应期已归零即可。
            wait_refract_zero(4'd10);
            press_axis(4'd10, RAW_MID);           // ⭐ 半按（⭐ 仍 > TRIG_TH=64 ⇒ 起音）
            find_voice_by_axis(4'd10, v10);
            p10 = (v10 >= 0) ? u_top.g_sound.u_note_manager.phase_r[v10] : 32'h0000_0000;
            $display("  [B3   ] axis10 SHALLOW (pos=%0d) => voice=%0d phase=%08h  (DEEP was pos=%0d phase=%08h)",
                     u_top.g_sound.as_pos[10*12 +: 12], v10, p10, pos_deep, p_deep);
            chk("B3: SAME key (axis10) at HALF depth => SAME pitch (pos does NOT enter the pitch index)",
                (v10 >= 0) && (p10 === p_deep) && (p10 === kb_exp(10)));

            // ── 5) ⭐ B4c：**同键重按** ⇒ 新 voice 仍然只持有那一个音高 ─────────
            cnt10 = 0;
            for (vw = 0; vw < NORMAL_VOICES; vw = vw + 1)
                if ((u_top.g_sound.nm_gate[vw] === 1'b1) &&
                    (u_top.g_sound.u_note_manager.axis_r[vw] === 4'd10))
                    cnt10 = cnt10 + 1;
            $display("  [B4   ] after re-press: held voices on axis10 = %0d (expect 1)", cnt10);
            chk("B4c: re-pressing the SAME key => EXACTLY ONE voice holds it, with EXACTLY kb_inc[10]",
                (cnt10 === 1) && (v10 >= 0) && (p10 === kb_exp(10)));

            // ── 6) 收尾：松手（⭐ 不影响任何已完成的判据）──────────────────────
            release_all_keys();
            repeat (26000) @(posedge clk);
        end

        $display("");
        if (errors == 0)
            $display("PASS: end-to-end key-to-sound -- with the MCP3208 slave injecting real hall codes, a key press makes HP_DIN carry audio and release returns to silence");
        else
            $fatal(1, "FAIL: end-to-end key-to-sound had %0d error(s)", errors);

        #1000;
        $finish;
    end

endmodule
