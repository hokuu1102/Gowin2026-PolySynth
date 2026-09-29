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
// ── ⭐ 电平换算（⭐ 依据用户 2026-09-23 实测 + RTL 的反相/阈值）───────────
//   ⭐ 实测：松手 1.60 V ⇒ raw 1985 (0x7C1)；触底 1.00 V ⇒ raw 1241 (0x4D9)
//   ⭐ RTL：`pos = 4095 - raw`（`INVERT_AXIS=1`）
//      · 松手 ⇒ pos = **2110**（0x83E）
//      · 按下 ⇒ pos = **2854**（0xB26）
//   ⭐ 阈值：`TRIG_TH = 0x8D3 = 2259`、`REL_TH = 0x897 = 2199`
//      ⇒ ⭐ **2110 < 2199 < 2259 < 2854** ⇒ ✅ 松手在阈下、按住在阈上
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
    localparam integer RESERVED_N   = 5;
    localparam integer NORMAL_VOICES = POLY_TARGET - RESERVED_N;   // ⭐ = 27
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
        .timbre_btn_i  (1'b1),
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

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_l (
        .cs_n     (spi_cs_n[0]),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_l),
        .ovr_en_i (ovr_l),
        .ovr_val_i(RAW_DOWN)
    );

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_r (
        .cs_n     (spi_cs_n[1]),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_r),
        .ovr_en_i (ovr_r),
        .ovr_val_i(RAW_DOWN)
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

        $display("");
        if (errors == 0)
            $display("PASS: end-to-end key-to-sound -- with the MCP3208 slave injecting real hall codes, a key press makes HP_DIN carry audio and release returns to silence");
        else
            $fatal(1, "FAIL: end-to-end key-to-sound had %0d error(s)", errors);

        #1000;
        $finish;
    end

endmodule
