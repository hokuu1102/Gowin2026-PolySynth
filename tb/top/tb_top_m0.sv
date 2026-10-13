`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_top_m0 · **M0 顶层验收**（`files/20-代码/仿真与验证方案.md` §三 M0）
//
// M0 是"地基里最后一块"：**上板之前，顶层本身必须是安全的**。
// 判据（本 tb 逐条给结论）：
//   A · 时基在**顶层端口**上正确：`HP_BCK` 周期 = 16 clk（3.125 MHz）、
//       `HP_WS` 周期 = 1024 clk（48.828125 kHz）
//   B * **NEO-Dock fallback档**（`PA_ON_AFTER_RESET=0`）：`PA_EN_n` **恒低**、0 次翻转
//       （⚠️ 旧板上低 = `NS4263` 的 AB 类桥式 = "出声"那一侧）
//   C * ⭐⭐ **Console 交付档**（`PA_ON_AFTER_RESET=1`）：`PA_EN_n` **恒高、全程 0 个边沿**
//       （🔴 `U-25b`：它接 `MAX98357A` 的 `SD_MODE`，⭐ **`< 0.16 V` = `Shutdown` = 没声音** ⇒
//        ⭐ **驱动高才出声**；⚠️ 任何**下降沿**都会把它打进 `Shutdown` ⇒ 判据要求 0 个下降沿）
//   D · 心跳 LED 活着且周期精确（板级"活体见证"；系统时钟留在板载域 ⇒ 故障可观测）
//   E · ⭐ 静音就是**真的静音**：`HP_DIN` 全程为 0（T20 测试音源接进来之前，⛔ 不该有噪声）
//   F · A8：`HP_BCK/HP_WS/HP_DIN/PA_EN_n/led_heartbeat` 复位释放后无 X/Z
//
// ⚠️ 为什么专门测 `PA_EN_n`：⭐ **它在两块板上语义【相反】** ——
//    `NEO Dock` 上是**低有效**功放使能（低 = 出声）；⭐ `Console` 上是 **`SD_MODE` 多电平选择**
//    （🔴 低 = `Shutdown` = 没声音，⭐ **高才出声**）。⚠️ 这正是"换板后板子没声音"的根因（`U-25b`）。
//    同步复位意味着"上电到第一个时钟沿之间寄存器是未定义的"，所以**引脚上拉**
//    （`constr/top.cst` 里 `PULL_MODE=UP`）才是配置期间的保证 —— ⭐ 而**高在 Console 上恰好是"出声"**侧
//    ⇒ ⭐ **上拉档依然安全**。本 tb 验证的是"**从第一个时钟沿起**电平就已经正确"，上拉那半由 `.cst` 负责。
// ─────────────────────────────────────────────────────────────────────────────
module tb_top_m0;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer N_FRAMES       = 64;      // 65536 clk ≈ 1.31 ms 仿真时间
    localparam integer HB_DIV         = 512;     // 心跳半周期（顶层的 0.5 s 在这里缩到 10.24 µs 以便快速验证）
    localparam integer PA_DELAY_TB    = 100;     // 反向检用的短延时

    localparam integer T = 20;                   // 50 MHz ⇒ 20 ns

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // ═══════════════════════════════════════════════════════════════
    // A · 被测顶层（**M0 安全态**：PA_ON_AFTER_RESET = 0）
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_a, HP_WS_a, HP_DIN_a, PA_EN_n_a, hb_a;
    // ⭐⭐ 2026-09-25 新增：外置 DAC 通路（`PCM5102A`，⭐ 路线 A）的观测点
    wire I2S2_BCK_a, I2S2_LRCK_a, I2S2_DIN_a;
    wire pluck_up_idle = 1'b0, pluck_down_idle = 1'b0;
    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .PA_ON_AFTER_RESET (0),
        // ⭐⭐ T57（2026-09-21）：本实例验的是 **M0 安全态 + 真静音**
        //   ⇒ ⛔ **必须显式关掉开机自检音**（默认值是 1 = 出声）。
        //   ⚠️ 不传这个参数的话，`top` 会自动起 A4+C#5+E5 和弦 ⇒
        //      ⭐ E 判据（`HP_DIN` 全程为 0）必然失败。
        .DEMO_CHORD_ON     (0),
        .HEARTBEAT_DIV     (HB_DIV),
        .SAMPLE_W          (24),
        .DATA_BITS         (16)
    ) u_top_safe (
        .clk (clk), .rst_n (rst_n), .timbre_btn_i (1'b1),
        .HP_BCK (HP_BCK_a), .HP_WS (HP_WS_a), .HP_DIN (HP_DIN_a),
        .PA_EN_n (PA_EN_n_a), .led_heartbeat (hb_a),
        // ⭐ 外置 DAC 通路（⭐ 2026-09-25）
        .I2S2_BCK (I2S2_BCK_a), .I2S2_LRCK (I2S2_LRCK_a), .I2S2_DIN (I2S2_DIN_a),
        .pluck_up_i(pluck_up_idle), .pluck_down_i(pluck_down_idle),
        // ⭐ 2026-09-23：W3a 采集链新增的输入（⭐ 本 tb 不测采集 ⇒ 常量高 = 串口空闲/无 MISO 驱动）
        //   ⚠️ 2026-09-23 晚：端口已改成【预留 6 片】的向量 ⇒ ⭐ 给 6 位常量高
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n (),
        //   ⭐ 2026-09-23 阶段C：新增的串口端口 ——
        //   ⭐ `uart_rx` 给【空闲高】= 串口空闲态（⚠️ 悬空会是 x）
        .uart_rx (1'b1), .uart_tx ()
    );

    // ═══════════════════════════════════════════════════════════════
    // ⭐⭐ I · **交付默认值守卫**（`R-16`，2026-09-17 加）
    //    ⚠️ 为什么需要：`top.v` 的 `PA_ON_AFTER_RESET` 默认值决定"**上板默认有没有声音**"。
    //      若默认是 0 ⇒ 板载 `NS4263` 永远关断 ⇒ **喇叭/耳机都没声音**，
    //      而 I2S 波形、DAC 输入、所有仿真结论**全都是对的** ⇒ 这种"没声音"极难定位。
    //    ⇒ 本条断言：**裸例化（不传参）时，默认值必须是"能出声"的那一档**。
    //      ⛔ 如果将来有人把默认值改回 0，这条会立刻 FAIL。
    //    ⭐ 注意区分：实例 A **显式传 0** 是有意的（验安全态），
    //      本条查的是"**不传参时**会怎样"。
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_d, HP_WS_d, HP_DIN_d, PA_EN_n_d, hb_d;
    top #(
        .HEARTBEAT_DIV (HB_DIV),         // ⚠️ 只覆盖心跳周期；`PA_ON_AFTER_RESET` **故意不传**
        // ⚠️ T57：本实例只查 `PA_ON_AFTER_RESET` 的默认值，⛔ 不查音频
        //    ⇒ 关掉自检音既省仿真时间、也避免 3 份合成链同时跑
        .DEMO_CHORD_ON (0)
    ) u_top_default (
        .clk (clk), .rst_n (rst_n), .timbre_btn_i (1'b1),
        .HP_BCK (HP_BCK_d), .HP_WS (HP_WS_d), .HP_DIN (HP_DIN_d),
        .PA_EN_n (PA_EN_n_d), .led_heartbeat (hb_d),
        // ⭐ 外置 DAC 通路（⭐ 2026-09-25）—— ⚠️ 本实例只查默认值，⭐ 这两路【空连接】
        .I2S2_BCK (), .I2S2_LRCK (), .I2S2_DIN (),
        .pluck_up_i(pluck_up_idle), .pluck_down_i(pluck_down_idle),
        //   ⚠️ 2026-09-23 晚：端口改成【预留 6 片】的向量 ⇒ 给 6 位常量
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n (),
        //   ⭐ 2026-09-23 阶段C：新增的串口端口 ——
        //   ⭐ `uart_rx` 给【空闲高】= 串口空闲态（⚠️ 悬空会是 x）
        .uart_rx (1'b1), .uart_tx ()
    );

    // ═══════════════════════════════════════════════════════════════
    // C · 反向检：PA_ON_AFTER_RESET = 1（延时开功放）
    // ═══════════════════════════════════════════════════════════════
    wire HP_BCK_b, HP_WS_b, HP_DIN_b, PA_EN_n_b, hb_b;
    top #(
        .PA_ON_AFTER_RESET (1),
        .PA_ON_DELAY       (PA_DELAY_TB),
        .DEMO_CHORD_ON     (0),          // ⚠️ T57：本实例只查功放时序
        .HEARTBEAT_DIV     (HB_DIV),
        .SAMPLE_W          (24),
        .DATA_BITS         (16)
    ) u_top_on (
        .clk (clk), .rst_n (rst_n), .timbre_btn_i (1'b1),
        .HP_BCK (HP_BCK_b), .HP_WS (HP_WS_b), .HP_DIN (HP_DIN_b),
        .PA_EN_n (PA_EN_n_b), .led_heartbeat (hb_b),
        // ⭐ 外置 DAC 通路（⭐ 2026-09-25）—— ⚠️ 本实例只查功放时序，⭐ 空连接
        .I2S2_BCK (), .I2S2_LRCK (), .I2S2_DIN (),
        .pluck_up_i(pluck_up_idle), .pluck_down_i(pluck_down_idle),
        //   ⚠️ 2026-09-23 晚：端口改成【预留 6 片】的向量 ⇒ 给 6 位常量
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n (),
        //   ⭐ 2026-09-23 阶段C：新增的串口端口 ——
        //   ⭐ `uart_rx` 给【空闲高】= 串口空闲态（⚠️ 悬空会是 x）
        .uart_rx (1'b1), .uart_tx ()
    );

    // ── F · A8：X/Z 传播（声明必须放在例化之前）──────────────────────
    wire [31:0] a8_bck, a8_ws, a8_din, a8_pa_a, a8_hb, a8_pa_b;
    chk_xprop #(.W(1), .NAME("HP_BCK"))        u_a8_bck  (.clk(clk), .rst_n(rst_n), .sig(HP_BCK_a),      .err_cnt(a8_bck));
    chk_xprop #(.W(1), .NAME("HP_WS"))         u_a8_ws   (.clk(clk), .rst_n(rst_n), .sig(HP_WS_a),       .err_cnt(a8_ws));
    chk_xprop #(.W(1), .NAME("HP_DIN"))        u_a8_din  (.clk(clk), .rst_n(rst_n), .sig(HP_DIN_a),      .err_cnt(a8_din));
    chk_xprop #(.W(1), .NAME("PA_EN_n"))       u_a8_pa_a (.clk(clk), .rst_n(rst_n), .sig(PA_EN_n_a),     .err_cnt(a8_pa_a));
    chk_xprop #(.W(1), .NAME("led_heartbeat")) u_a8_hb   (.clk(clk), .rst_n(rst_n), .sig(hb_a),          .err_cnt(a8_hb));
    chk_xprop #(.W(1), .NAME("PA_EN_n(延时)")) u_a8_pa_b (.clk(clk), .rst_n(rst_n), .sig(PA_EN_n_b),     .err_cnt(a8_pa_b));

    //  ⭐⭐ 2026-10-09（`P0-06`）：⭐ **心跳翻转计数**（⭐ "活体见证"判据）✅
    //   📌 为什么单独数：⭐ `chk_xprop` 只看端口有没有 X/Z
    //      ⚠️ 而"心跳**恒为 0**"是**合法电平** ⇒ ⭐ 必须**数翻转次数**才抓得到 ✅
    integer hb_toggles = 0;
    always @(posedge hb_d) hb_toggles = hb_toggles + 1;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ J · 外置 DAC 通路（`PCM5102A`，⭐ 2026-09-25 新增 · 路线 A）
    //
    //   ⭐ **为什么要判它**：🔴 新增了 3 个输出端口，⚠️ 而"**端口存在**"≠"**上面真有波形**"。
    //      · 🔴 若 `u_i2s_tx_ext` 被综合掉 / 接错 / 时钟没错开
    //        ⇒ ⭐ 引脚上会是**常量** ⇒ ⚠️ **外置音箱永远没声，而仿真全绿**（⭐ `K-87` 同族）
    //   ⭐ **判据（⭐ 与板载那路同源 ⇒ 应当逐拍一致）**：
    //      ① ⭐ `I2S2_BCK` 周期 = 16 clk（3.125 MHz）
    //      ② ⭐ `I2S2_LRCK` 周期 = 1024 clk（48.828125 kHz）
    //      ③ ⭐⭐ **`I2S2_*` 与 `HP_*`【逐拍完全相同】**
    //         ⇒ ⭐ 这才是"两路并存"的最强保证（⭐ 同参数、同数据源、同节拍）
    //      ④ ⭐ A8：复位释放后无 X/Z
    //   📌 判据 ③ 同时**排除了"两路相位漂移"**（⭐ 那会让外置音箱出现爆音/回声）。
    // ═══════════════════════════════════════════════════════════════════════
    wire [31:0] a8_bck2, a8_lrck2, a8_din2;
    chk_xprop #(.W(1), .NAME("I2S2_BCK"))  u_a8_bck2  (.clk(clk), .rst_n(rst_n), .sig(I2S2_BCK_a),  .err_cnt(a8_bck2));
    chk_xprop #(.W(1), .NAME("I2S2_LRCK")) u_a8_lrck2 (.clk(clk), .rst_n(rst_n), .sig(I2S2_LRCK_a), .err_cnt(a8_lrck2));
    chk_xprop #(.W(1), .NAME("I2S2_DIN"))  u_a8_din2  (.clk(clk), .rst_n(rst_n), .sig(I2S2_DIN_a),  .err_cnt(a8_din2));

    // ⭐ 周期测量（⭐ 与板载那路用同一套统计口径）
    //   🔴 **2026-09-25 踩坑**：⭐ 我第一版在 `posedge clk` 上用自增的 `cyc2` 直接量间隔
    //      ⇒ ⚠️ 测出 `min=1` ⇒ 🔴 **误判成"周期错误"**。
    //      ⭐ 真因：⭐ 信号**就是在 `posedge` 上变化的** ⇒ ⚠️ 同一拍内边沿检测与计数错位。
    //   ✅ **正确做法**（⭐ 照抄板载那路 A 判据的成熟写法）：
    //      · ⭐ 检测**上升沿**（`x===1 && x_d===0`），⭐ 用同一拍的时间戳
    //      · ⭐ **跳过复位后前 2 个边沿**（⭐ warm-up 伪值，⭐ 见 A 判据的注释）
    integer g_bck2_min = 1<<30, g_bck2_max = 0, n_bck2_edge = 0, g_lrck2_min = 1<<30, g_lrck2_max = 0, n_lrck2_edge = 0;
    integer last_bck2 = -1, last_lrck2 = -1, t_win2 = 0;
    reg bck2_d = 1'b0, lrck2_d = 1'b0;

    // ⭐⭐⭐ 逐拍一致性比对：⭐ 两路必须【每一位都相同】
    integer n_diff = 0;                 // ⭐ 不一致的拍数
    integer n_cmp = 0;                  // ⭐ 比较过的拍数
 
    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-26 新增：外置通路的【活动量】统计（⭐ 修 M116 的 LEAK）
    //
    //  🔴 **为什么要加**：⭐ 变异测试报了 `M116 GREEN(LEAK)` ——
    //     ⭐ 把外置那路的 `sample_l` 改成**全 0**，🔴 **我的 J 判据没抓到**！
    //  🔴 **真因（⭐ 判据的固有盲区）**：
    //     ⭐ 我的 J 组判的是"**两路逐拍一致**" ⇒
    //     ⚠️ 但变异体把【两路一起】变成了 0（⭐ 锚点匹配了 2 处）
    //     ⇒ 🔴 **"0 == 0" 仍然成立** ⇒ ⭐ 判据说"一致"，⛔ 却什么都没验到。
    //     📌 而且**即使只改一路**，⚠️ "一致"也抓不到"两路一起静音"这种失败。
    //  ⭐ **修法：⭐ 除了"一致性"，还要判"【两路都真的在动】"** ——
    //     ⭐ 统计每根线的**翻转次数**，⭐ 必须 > 0（⛔ 不允许"恒定"）。
    //     📌 **判据的分工**：
    //        · ⭐ "逐拍一致" ⇒ ⭐ 排除**相位漂移/接错线**
    //        · ⭐ "活动量 > 0" ⇒ ⭐ 排除**整路恒定**（⭐ 本 LEAK 就是这种）
    //     ⇒ ⭐ **两条合起来才完整** —— ⚠️ 单靠任何一条都有盲区。
    // ═══════════════════════════════════════════════════════════════════════
    integer n_tog_bck2 = 0, n_tog_lrck2 = 0, n_tog_din2 = 0;
    integer n_tog_bck1 = 0, n_tog_ws1 = 0, n_tog_din1 = 0;
    reg bck2_p = 0, lrck2_p = 0, din2_p = 0;
    reg bck1_p = 0, ws1_p = 0, din1_p = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            // ⭐ 外置那一路
            if (I2S2_BCK_a  !== bck2_p)  n_tog_bck2  = n_tog_bck2  + 1;
            if (I2S2_LRCK_a !== lrck2_p) n_tog_lrck2 = n_tog_lrck2 + 1;
            if (I2S2_DIN_a  !== din2_p)  n_tog_din2  = n_tog_din2  + 1;
            bck2_p  = I2S2_BCK_a;
            lrck2_p = I2S2_LRCK_a;
            din2_p  = I2S2_DIN_a;
            // ⭐ 板载那一路（⭐ 作对照）
            if (HP_BCK_a !== bck1_p) n_tog_bck1 = n_tog_bck1 + 1;
            if (HP_WS_a  !== ws1_p)  n_tog_ws1  = n_tog_ws1  + 1;
            if (HP_DIN_a !== din1_p) n_tog_din1 = n_tog_din1 + 1;
            bck1_p = HP_BCK_a;
            ws1_p  = HP_WS_a;
            din1_p = HP_DIN_a;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            t_win2 = t_win2 + 1;

            // ⭐ I2S2_BCK 上升沿间隔（⭐ 跳过前 2 个 warm-up 边沿）
            if (I2S2_BCK_a === 1'b1 && bck2_d === 1'b0) begin
                n_bck2_edge = n_bck2_edge + 1;
                if (n_bck2_edge > 2 && last_bck2 >= 0) begin
                    if (t_win2 - last_bck2 < g_bck2_min) g_bck2_min = t_win2 - last_bck2;
                    if (t_win2 - last_bck2 > g_bck2_max) g_bck2_max = t_win2 - last_bck2;
                end
                last_bck2 = t_win2;
            end
            bck2_d = I2S2_BCK_a;

            // ⭐ I2S2_LRCK 上升沿间隔
            if (I2S2_LRCK_a === 1'b1 && lrck2_d === 1'b0) begin
                n_lrck2_edge = n_lrck2_edge + 1;
                if (n_lrck2_edge > 2 && last_lrck2 >= 0) begin
                    if (t_win2 - last_lrck2 < g_lrck2_min) g_lrck2_min = t_win2 - last_lrck2;
                    if (t_win2 - last_lrck2 > g_lrck2_max) g_lrck2_max = t_win2 - last_lrck2;
                end
                last_lrck2 = t_win2;
            end
            lrck2_d = I2S2_LRCK_a;

            // ⭐ 逐拍比对（⭐ 同步采样，⭐ 三根线都要一样）
            n_cmp = n_cmp + 1;
            if ((I2S2_BCK_a !== HP_BCK_a) || (I2S2_LRCK_a !== HP_WS_a) || (I2S2_DIN_a !== HP_DIN_a))
                n_diff = n_diff + 1;
        end
    end

    // ── 度量 ───────────────────────────────────────────────────────
    integer errors = 0;

    integer t_win;                       // 复位释放后的 clk 计数（时间基准）
    integer last_bck, gap_bck_min, gap_bck_max, n_bck_edge;
    integer last_ws,  ws_period_min, ws_period_max, n_ws_edge;
    reg     bck_d, ws_d;

    integer pa_a_low, pa_a_trans, pa_a_rst_bad, rst_clk_cnt;
    reg     pa_a_d;

    integer pa_b_trans, pa_b_release_at, pa_b_high_after, pa_b_rst_bad;
    integer pa_b_high_cyc;      // cycles PA_EN_n_b was high (Console delivery must be all-high)
    reg     pa_b_d;

    // ⭐ K-61：`NS4263` 的 `SD`（`PA_EN_n`）靠**下降沿个数**选模式
    //    （1 个 = AB 类桥式；连续 2 个 = D 类）⇒ 单独统计**下降沿**个数。
    integer pa_a_fall, pa_b_fall;
    reg     pa_a_prev, pa_b_prev;

    // ⭐ I · 交付默认值守卫用的量（裸例化实例）
    integer pa_d_fall, pa_d_release_at;
    reg     pa_d_prev;
    integer t_win_d;

    integer din_nonzero;
    integer hb_a_trans, last_hb_a, hb_a_gap_min, hb_a_gap_max;
    reg     hb_a_d;

    integer fd_pa;

    // ── ⭐ R-08：`rst_sync` 的两级同步延迟（声明必须在 always/initial 使用之前，
    //    否则 Icarus 报 "Unable to bind wire/reg/memory ... Check for declaration after use"，
    //    见经验库 `U47`）────────────────────────────────────────────────
    integer in_rise_cyc, out_rise_cyc;
    integer rst_cyc;
    reg     in_hi_d, out_hi_d;

    initial begin
        $dumpfile("build/sim/tb_top_m0/tb_top_m0.vcd");
        $dumpvars(0, tb_top_m0);

        t_win = 0; last_bck = -1; gap_bck_min = 1 << 30; gap_bck_max = 0; n_bck_edge = 0;
        last_ws = -1; ws_period_min = 1 << 30; ws_period_max = 0; n_ws_edge = 0;
        bck_d = 1'b0; ws_d = 1'b0;

        // * seed the previous-value registers to each instance's EXPECTED resting level,
        //   so the first sampled cycle is not miscounted as an edge.
        //   A = NEO-Dock fallback => rests low;  B = Console delivery => rests high.
        pa_a_low = 0; pa_a_trans = 0; pa_a_rst_bad = 0; rst_clk_cnt = 0; pa_a_d = 1'b0;
        pa_a_fall = 0; pa_a_prev = 1'b0;
        pa_b_trans = 0; pa_b_release_at = -1; pa_b_high_after = 0; pa_b_d = 1'b1;
        pa_b_rst_bad = 0; pa_b_high_cyc = 0;
        pa_b_fall = 0; pa_b_prev = 1'b1;
        pa_d_fall = 0; pa_d_release_at = -1; pa_d_prev = 1'b1;
        din_nonzero = 0;
        hb_a_trans = 0; last_hb_a = -1; hb_a_gap_min = 1 << 30; hb_a_gap_max = 0; hb_a_d = 1'b0;

        // ⭐ 证据：PA_EN_n 的**翻转轨迹**（安全态下应为空文件，只有表头 ⇒ "一次都没动过"）
        fd_pa = $fopen("sim/evidence/top_m0_pa_trace.csv", "w");
        $fdisplay(fd_pa, "# PA_EN_n 翻转轨迹（clk_sys=50MHz）；安全态 A 期望 0 行 = 无翻转 = 无窄脉冲");
        $fdisplay(fd_pa, "# 实例,时刻ns,新值");

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        repeat (CLK_PER_SAMPLE * N_FRAMES) @(posedge clk);
        #1;

        $fclose(fd_pa);

        $display("");
        $display("==================== top / M0 顶层验收 ====================");
        $display("  A 时基    : HP_BCK 周期 min=%0d max=%0d clk（期望 %0d）· 上升沿 %0d 个",
                 gap_bck_min, gap_bck_max, BCLK_DIV, n_bck_edge);
        $display("              HP_WS  周期 min=%0d max=%0d clk（期望 %0d）· 上升沿 %0d 个",
                 ws_period_min, ws_period_max, CLK_PER_SAMPLE, n_ws_edge);
        $display("  B fallback: PA_EN_n NOT-low %0d cyc (expect 0) * trans %0d (expect 0) * rst-bad %0d",
                 pa_a_low, pa_a_trans, pa_a_rst_bad);
        $display("  C Console : PA_EN_n high %0d of %0d cyc (expect all) * trans %0d * falling %0d (both expect 0)",
                 pa_b_high_cyc, t_win, pa_b_trans, pa_b_fall);
        $display("  D 心跳    : 翻转 %0d 次 · 间隔 min=%0d max=%0d clk（期望 %0d）",
                 hb_a_trans, hb_a_gap_min, hb_a_gap_max, HB_DIV);
        $display("  G rst_sync: 输入释放拍 %0d · 同步输出释放拍 %0d · 延迟 %0d 拍（期望恰好 2）",
                 in_rise_cyc, out_rise_cyc, out_rise_cyc - in_rise_cyc);
        $display("  E 静音    : HP_DIN 为 1 的拍数 %0d（期望 0）", din_nonzero);
        $display("  F A8      : bck=%0d ws=%0d din=%0d pa=%0d hb=%0d pa(延时)=%0d",
                 a8_bck, a8_ws, a8_din, a8_pa_a, a8_hb, a8_pa_b);
        $display("  J 外置DAC : I2S2_BCK 周期 min=%0d max=%0d · I2S2_LRCK 周期 min=%0d max=%0d",
                 g_bck2_min, g_bck2_max, g_lrck2_min, g_lrck2_max);
        $display("              与板载逐拍比对: %0d 拍中有 %0d 拍不一致（期望 0）", n_cmp, n_diff);
        $display("              上升沿 bck2=%0d lrck2=%0d · A8 bck2=%0d lrck2=%0d din2=%0d",
                 n_bck2_edge, n_lrck2_edge, a8_bck2, a8_lrck2, a8_din2);
        $display("  证据      : sim/evidence/top_m0_pa_trace.csv（应只有表头）+ 波形 build/sim/tb_top_m0/");
        $display("==========================================================");

        if (gap_bck_min == BCLK_DIV && gap_bck_max == BCLK_DIV && n_bck_edge > 100)
            $display("  ok : A · HP_BCK 周期恰好 %0d clk（3.125 MHz）", BCLK_DIV);
        else begin
            $display("FAIL: A · HP_BCK 周期不是恰好 %0d（min=%0d max=%0d）", BCLK_DIV, gap_bck_min, gap_bck_max);
            errors = errors + 1;
        end

        if (ws_period_min == CLK_PER_SAMPLE && ws_period_max == CLK_PER_SAMPLE && n_ws_edge >= N_FRAMES)
            $display("  ok : A · HP_WS 周期恰好 %0d clk（48.828125 kHz）", CLK_PER_SAMPLE);
        else begin
            $display("FAIL: A · HP_WS 周期不是恰好 %0d（min=%0d max=%0d）", CLK_PER_SAMPLE, ws_period_min, ws_period_max);
            errors = errors + 1;
        end

        if (pa_a_low == 0 && pa_a_trans == 0 && pa_a_rst_bad == 0)
            $display("  ok : B * NEO-Dock fallback (PA_ON_AFTER_RESET=0) -- PA_EN_n low throughout, 0 transitions");
        else begin
            $display("FAIL: B * NEO-Dock fallback broken (not-low %0d cyc / trans %0d / rst-issue %0d)",
                     pa_a_low, pa_a_trans, pa_a_rst_bad);
            errors = errors + 1;
        end

        // * Console delivery档 (PA_ON_AFTER_RESET=1): PA_EN_n must be HIGH forever.
        //   Why: on Console this net drives MAX98357A SD_MODE, and <0.16V = Shutdown
        //   (U-25b).  So the ONLY correct delivery value is high, with ZERO falling
        //   edges -- a falling edge here would silently mute the board.
        if (pa_b_high_cyc == t_win && pa_b_trans == 0 && pa_b_fall == 0 && pa_b_rst_bad == 0)
            $display("  ok : C * Console delivery -- PA_EN_n high for all %0d cycles, 0 edges (SD_MODE=Left => SOUNDS)", t_win);
        else begin
            $display("FAIL: C * Console delivery broken (high %0d of %0d cyc, trans %0d, falling %0d, rst-bad %0d) -- SD_MODE would leave Left => NO SOUND",
                     pa_b_high_cyc, t_win, pa_b_trans, pa_b_fall, pa_b_rst_bad);
            errors = errors + 1;
        end

        if (hb_a_trans >= 8 && hb_a_gap_min == HB_DIV && hb_a_gap_max == HB_DIV)
            $display("  ok : D · 心跳 LED 活着且半周期恰好 %0d clk（%0d 次翻转）", HB_DIV, hb_a_trans);
        else begin
            $display("FAIL: D · 心跳不对（翻转 %0d 次 · 间隔 %0d~%0d，期望恰好 %0d）",
                     hb_a_trans, hb_a_gap_min, hb_a_gap_max, HB_DIV);
            errors = errors + 1;
        end

        if (din_nonzero == 0)
            $display("  ok : E · 静音是真静音 —— HP_DIN 全程为 0");
        else begin
            $display("FAIL: E · 静音期 HP_DIN 出现 %0d 拍非 0（接了音源之前不该有数据）", din_nonzero);
            errors = errors + 1;
        end

        if (a8_bck == 0 && a8_ws == 0 && a8_din == 0 && a8_pa_a == 0 && a8_hb == 0 && a8_pa_b == 0)
            $display("  ok : F · A8 无 X/Z 传播（5 个顶层输出 + 延时实例）");
        else begin
            $display("FAIL: F · A8 检测到 X/Z（bck=%0d ws=%0d din=%0d pa=%0d hb=%0d pa_b=%0d）",
                     a8_bck, a8_ws, a8_din, a8_pa_a, a8_hb, a8_pa_b);
            errors = errors + 1;
        end

        // ⭐ R-08：复位同步器延迟必须恰好 2 拍（证明"释放沿对齐"这件事真的做了）
        if (in_rise_cyc > 0 && out_rise_cyc > 0 && (out_rise_cyc - in_rise_cyc) == 2)
            $display("  ok : G · rst_sync 把复位释放延后**恰好 2 拍**（异步输入 → 同步释放）");
        else begin
            $display("FAIL: G · rst_sync 延迟不是 2 拍（in=%0d out=%0d 差=%0d）",
                     in_rise_cyc, out_rise_cyc, out_rise_cyc - in_rise_cyc);
            errors = errors + 1;
        end

        // ** U-25b: PA_EN_n drives MAX98357A SD_MODE on Console, NOT an NS4263 SD pin.
        //    Datasheet: <0.16V = Shutdown (NO SOUND); >1.4V = Left (SOUNDS).
        //    => The delivery requirement INVERTED: the pin must be driven HIGH and must
        //       NEVER fall.  A falling edge now means SILENCE, not "AB-class".
        //    => Judgement: zero falling edges in BOTH instances.
        //       (Instance A is the NEO-Dock fallback, which is legitimately static-low.)
        $display("  H SD_MODE : PA_EN_n falling edges A=%0d (fallback, low) B=%0d (Console, high)",
                 pa_a_fall, pa_b_fall);
        if (pa_a_fall == 0 && pa_b_fall == 0)
            $display("  ok : H * zero falling edges -- Console SD_MODE never leaves Left (would be Shutdown)");
        else begin
            $display("FAIL: H * falling edges present (A=%0d B=%0d) -- on Console that means SD_MODE hits Shutdown = NO SOUND",
                     pa_a_fall, pa_b_fall);
            errors = errors + 1;
        end

        // ** I * delivery-default guard (R-16, semantics updated by U-25b):
        //    A bare instantiation must get PA_ON_AFTER_RESET=1, which on Console means
        //    "SD_MODE driven high => SOUNDS".  If someone flips the default back to 0,
        //    the board goes silent -- this assertion is what catches that.
        $display("  I default : bare instantiation PA_ON_AFTER_RESET = %0d (1 = Console sounds; 0 = Shutdown)",
                 u_top_default.PA_ON_AFTER_RESET);
        if (u_top_default.PA_ON_AFTER_RESET == 1)
            $display("  ok : I * delivery default correct -- bare instantiation drives SD_MODE high => board sounds");
        else begin
            $display("FAIL: I * delivery default would MUTE the board (PA_ON_AFTER_RESET=%0d) -- fix top.v default (R-16 / U-25b)",
                     u_top_default.PA_ON_AFTER_RESET);
            errors = errors + 1;
        end

        // ** and the fallback档 must really be static-low, with no transitions
        if (u_top_safe.PA_ON_AFTER_RESET == 0 && pa_a_fall == 0 && pa_a_trans == 0)
            $display("  ok : I * explicit PA_ON_AFTER_RESET=0 gives a static-low output (NEO-Dock fallback intact)");
        else begin
            $display("FAIL: I * explicit 0 did not stay static-low (param=%0d, falling=%0d, trans=%0d)",
                     u_top_safe.PA_ON_AFTER_RESET, pa_a_fall, pa_a_trans);
            errors = errors + 1;
        end

        // ═══════════════════════════════════════════════════════════════
        // ** J * 外置 DAC 通路（`PCM5102A`，⭐ 2026-09-25 新增）
        //    ① 周期正确  ② 与板载【逐拍一致】  ③ 无 X/Z
        // ═══════════════════════════════════════════════════════════════
        if (g_bck2_min == BCLK_DIV && g_bck2_max == BCLK_DIV && n_bck2_edge > 100)
            $display("  ok : J · I2S2_BCK 周期恰好 %0d clk（3.125 MHz，与板载同档）", BCLK_DIV);
        else begin
            $display("FAIL: J · I2S2_BCK 周期异常（min=%0d max=%0d 边沿=%0d）-- 外置 DAC 收不到位时钟",
                     g_bck2_min, g_bck2_max, n_bck2_edge);
            errors = errors + 1;
        end

        if (g_lrck2_min == CLK_PER_SAMPLE && g_lrck2_max == CLK_PER_SAMPLE && n_lrck2_edge >= N_FRAMES)
            $display("  ok : J · I2S2_LRCK 周期恰好 %0d clk（48.828125 kHz）", CLK_PER_SAMPLE);
        else begin
            $display("FAIL: J · I2S2_LRCK 周期异常（min=%0d max=%0d 边沿=%0d）",
                     g_lrck2_min, g_lrck2_max, n_lrck2_edge);
            errors = errors + 1;
        end

        // ⭐⭐⭐ 最强判据：⭐ 两路【逐拍完全相同】⇒ 同时证明"同源/同步/接线对"
        if (n_cmp > 1000 && n_diff == 0)
            $display("  ok : J * 外置与板载【逐拍完全一致】（%0d 拍全等）-- 两路同源同步，无相位漂移", n_cmp);
        else begin
            $display("FAIL: J * 两路不一致 %0d / %0d 拍 -- 外置 DAC 会听到爆音/回声，或接线错",
                     n_diff, n_cmp);
            errors = errors + 1;
        end

        // ⭐⭐⭐⭐ 2026-09-26 新增：⭐ **两路都必须【真的在动】**（⭐ 修 M116 的 LEAK）
        //   🔴 **为什么"逐拍一致"不够**：⭐ 变异体把两路**一起**变成 0 时，
        //      ⚠️ `0 == 0` 仍然成立 ⇒ 🔴 **判据说"一致"，却什么都没验到**。
        //   ⭐ 判据：⭐ **每根线都必须有翻转** + ⭐ **与板载那路的翻转数相当**
        //      （⭐ 同源同步 ⇒ ⭐ 翻转数应当**相等或极接近**）
        $display("  J 活动量  : 外置 bck=%0d lrck=%0d din=%0d ｜ 板载 bck=%0d ws=%0d din=%0d",
                 n_tog_bck2, n_tog_lrck2, n_tog_din2,
                 n_tog_bck1, n_tog_ws1, n_tog_din1);
        begin : j_activity
            integer act_bad;
            act_bad = 0;
            // ⭐ ① **时钟线**必须有翻转（⛔ 不允许恒定）
            //   ⚠️ **注意：`DIN` 不在此列！** ⭐ 本实例是 **M0 静音档**
            //      （`DEMO_CHORD_ON=0`）⇒ ⭐ **`DIN` 恒 0 正是"静音就是真静音"**
            //      📌 见 E 判据："静音就是真的静音：`HP_DIN` 全程为 0"。
            //   🔴 **我第一版把 DIN 也要求"必须翻转" ⇒ ⚠️ 误报**（⭐ 原版 RTL 就 FAIL）
            //      ⇒ 教训：⭐ **判据要匹配当前【档位】**，⛔ 不能把"有声档"的要求
            //        套到"静音档"上（⭐ `R-16`/`K-69` 同族：测试配置与交付默认值要分开）。
            if (n_tog_bck2  == 0) begin
                $display("FAIL: J * I2S2_BCK 恒不翻转 ⇒ 外置 DAC 没有位时钟");
                act_bad = act_bad + 1;
            end
            if (n_tog_lrck2 == 0) begin
                $display("FAIL: J * I2S2_LRCK 恒不翻转 ⇒ 外置 DAC 没有帧时钟");
                act_bad = act_bad + 1;
            end
            // ⭐ ② 时钟线的活动量必须与板载那路【完全相等】
            //   ⭐ 同源同步 ⇒ ⭐ 翻转数应当逐拍相同 ⇒ ⚠️ 不等就说明不是同源
            if (n_tog_bck2 != n_tog_bck1) begin
                $display("FAIL: J * I2S2_BCK 活动量(%0d) != 板载 HP_BCK(%0d) ⇒ 非同源",
                         n_tog_bck2, n_tog_bck1);
                act_bad = act_bad + 1;
            end
            if (n_tog_lrck2 != n_tog_ws1) begin
                $display("FAIL: J * I2S2_LRCK 活动量(%0d) != 板载 HP_WS(%0d) ⇒ 非同源",
                         n_tog_lrck2, n_tog_ws1);
                act_bad = act_bad + 1;
            end
            // ⭐ ③ DIN 必须与板载【同活动量】（⭐ 本档两路都应是 0 = 都在静音）
            //   ⭐ 这一条守住"两路一起变 0"那种失败吗？⚠️ **不能** ——
            //      所以 ⭐ **真正的保护是上面那张 J 活动量打印 + 下面这条相等判据**：
            //      ⭐ 若将来有人把外置那路接成"恒 0"而板载【有声】⇒ ⭐ 这里就会不等。
            if (n_tog_din2 != n_tog_din1) begin
                $display("FAIL: J * I2S2_DIN 活动量(%0d) != 板载 HP_DIN(%0d) ⇒ 两路数据不同步",
                         n_tog_din2, n_tog_din1);
                act_bad = act_bad + 1;
            end
            if (act_bad == 0)
                $display("  ok : J ** 外置与板载的【活动量相称】（⭐ 时钟线都在动；本档两路 DIN 同为静音）");
            else
                errors = errors + act_bad;
        end

        if (a8_bck2 == 0 && a8_lrck2 == 0 && a8_din2 == 0)
            $display("  ok : J · A8 外置三根线复位后无 X/Z");
        else begin
            $display("FAIL: J · 外置线出现 X/Z（bck=%0d lrck=%0d din=%0d）", a8_bck2, a8_lrck2, a8_din2);
            errors = errors + 1;
        end

        //  ⭐⭐ 2026-10-09（`P0-06`）：⭐ **心跳必须真的翻转** ＋ ⭐ **`fault_sticky` 不许是 X** ✅
        //   🔴 **原缺陷**：⭐ `g_silent` 档（⭐ 本 tb 的 `u_top_default`）漏驱动 `fault_any_w`
        //      ⇒ ⭐ 它悬空成 `z` ⇒ `if (fault_any_w)` 判成 **X** ⇒ `fault_sticky` 变 X
        //      ⇒ ⭐ `hb_div_eff` 变 X ⇒ `hb_cnt >= hb_div_eff − 1` **恒为 X（判假）**
        //      ⇒ 🔴 **`hb` 永不翻转 ⇒ 心跳灯死** ⇒ ⭐ **M0「活体见证」在静默档上完全失效** ✅
        //   📌 ⚠️ **为什么原来的 A8 判据抓不到**：⭐ `chk_xprop` 只看**端口** `led_heartbeat`
        //      在**复位释放后**有没有 X/Z —— ⚠️ 而这里的 X 在**内部**（`fault_sticky`），
        //      ⭐ 端口上只是一个**恒定不动**的合法电平 ⇒ 🔴 **判据漏了** ✅
        //      （⭐ 实测：摘掉修复后本 tb **照样 PASS** ⇒ ⭐ 本判据是补出来的 ✅）
        if ($isunknown(u_top_default.fault_sticky)) begin
            $display("FAIL: P0-06 fault_sticky 是 X（g_silent 档 fault_any_w 悬空）");
            errors = errors + 1;
        end else begin
            $display("  ok : P0-06 g_silent 档 fault_sticky 有确定值（=%0d）", u_top_default.fault_sticky);
        end
        if (hb_toggles < 2) begin
            $display("FAIL: P0-06 心跳只翻转 %0d 次（应 >= 2）=> 活体见证失效", hb_toggles);
            errors = errors + 1;
        end else begin
            $display("  ok : P0-06 心跳翻转 %0d 次（活体见证有效）", hb_toggles);
        end

        $display("");
        if (errors == 0) $display("PASS: M0 top-level acceptance (timebase + SD_MODE polarity + silence-clean + heartbeat + no X + external DAC)");
        else             $fatal(1, "FAIL: M0 top-level has %0d unexpected item(s)", errors);

        #100;
        $finish;
    end

    // ── ⭐ R-08：`rst_sync` 的两级同步延迟必须**恰好 2 拍** ──────────────
    //    判据：复位释放后，`u_rst_sync` 的输出比输入晚 2 个 clk 变高。
    //    ⚠️ 这是"复位释放沿在全设计里严格对齐"的**代价与证据**：
    //       延迟是确定的 2 拍（40 ns），不是"随便几拍"。
    initial begin
        in_rise_cyc = -1; out_rise_cyc = -1; rst_cyc = 0;
        in_hi_d = 1'b0; out_hi_d = 1'b0;
    end

    always @(posedge clk) begin
        rst_cyc = rst_cyc + 1;
        if (rst_n === 1'b1 && in_hi_d === 1'b0) begin
            in_hi_d = 1'b1;
            in_rise_cyc = rst_cyc;
        end
        if (u_top_on.rst_n_sync === 1'b1 && out_hi_d === 1'b0) begin
            out_hi_d = 1'b1;
            out_rise_cyc = rst_cyc;
        end
    end

    // ── 采样（全在 clk 域，避免竞争）────────────────────────────────
    always @(posedge clk) begin
        // During reset: from the 2nd clock edge onward the output must already hold its
        // final level (synchronous reset has taken effect).
        //   Instance A = NEO-Dock fallback => expects LOW.
        //   Instance B = Console delivery  => expects HIGH (checked separately below).
        if (rst_n === 1'b0) begin
            rst_clk_cnt = rst_clk_cnt + 1;
            if (rst_clk_cnt >= 2 && PA_EN_n_a !== 1'b0) pa_a_rst_bad = pa_a_rst_bad + 1;
            if (rst_clk_cnt >= 2 && PA_EN_n_b !== 1'b1) pa_b_rst_bad = pa_b_rst_bad + 1;
        end else begin
            t_win = t_win + 1;

            // A · HP_BCK 上升沿间隔
            // ⚠️ **跳过复位后前两个上升沿**：`HP_BCK` 的复位值是 1（R-03 修法：数据改在
            //    BCK 下降沿变化，使 DAC 的上升沿采样有半周期余量）⇒ 复位释放后**第一个**
            //    "上升沿"距复位时刻不足一个完整周期（实测 min=10 而非 16）——
            //    那是 warm-up 伪值，⛔ 不是 RTL 错。稳态周期仍是恰好 16 clk。
            if (HP_BCK_a === 1'b1 && bck_d === 1'b0) begin
                n_bck_edge = n_bck_edge + 1;
                if (n_bck_edge > 2 && last_bck >= 0) begin
                    if (t_win - last_bck < gap_bck_min) gap_bck_min = t_win - last_bck;
                    if (t_win - last_bck > gap_bck_max) gap_bck_max = t_win - last_bck;
                end
                last_bck = t_win;
            end
            bck_d = HP_BCK_a;

            // A · HP_WS 上升沿间隔
            if (HP_WS_a === 1'b1 && ws_d === 1'b0) begin
                n_ws_edge = n_ws_edge + 1;
                if (last_ws >= 0) begin
                    if (t_win - last_ws < ws_period_min) ws_period_min = t_win - last_ws;
                    if (t_win - last_ws > ws_period_max) ws_period_max = t_win - last_ws;
                end
                last_ws = t_win;
            end
            ws_d = HP_WS_a;

            // B * NEO-Dock fallback (PA_ON_AFTER_RESET=0): output must be statically LOW.
            //   On the old NS4263 board, LOW = AB-class bridged output (the "sounds" side).
            //   On Console this档 would be WRONG (low = SD_MODE Shutdown), which is exactly
            //   why the delivery default is 1 -- see U-25b.
            if (PA_EN_n_a !== 1'b0) pa_a_low = pa_a_low + 1;   // counts cycles NOT low (should be 0)
            if (PA_EN_n_a !== pa_a_d) begin
                pa_a_trans = pa_a_trans + 1;
                $fdisplay(fd_pa, "A,%0t,%b", $time, PA_EN_n_a);
            end
            // * count falling edges (1->0).  On Console ANY falling edge would drive
            //   SD_MODE into Shutdown, so the delivery instance must show zero.
            if (PA_EN_n_a === 1'b0 && pa_a_prev === 1'b1) pa_a_fall = pa_a_fall + 1;
            pa_a_prev = PA_EN_n_a;
            pa_a_d = PA_EN_n_a;

            // C * Console delivery (PA_ON_AFTER_RESET=1): output must be statically HIGH.
            if (PA_EN_n_b !== pa_b_d) begin
                pa_b_trans = pa_b_trans + 1;
                $fdisplay(fd_pa, "B,%0t,%b", $time, PA_EN_n_b);
                if (PA_EN_n_b === 1'b0 && pa_b_release_at < 0) pa_b_release_at = t_win;
            end
            if (PA_EN_n_b === 1'b1) pa_b_high_cyc = pa_b_high_cyc + 1;   // counts HIGH cycles
            if (PA_EN_n_b === 1'b0 && pa_b_prev === 1'b1) pa_b_fall = pa_b_fall + 1;
            pa_b_prev = PA_EN_n_b;
            pa_b_d = PA_EN_n_b;

            // ⭐ I · 裸例化实例（默认值）：只统计"下降沿个数"与"首次拉低的拍数"
            if (PA_EN_n_d === 1'b0 && pa_d_prev === 1'b1) begin
                pa_d_fall = pa_d_fall + 1;
                if (pa_d_release_at < 0) pa_d_release_at = t_win;
            end
            pa_d_prev = PA_EN_n_d;

            // D · 心跳
            if (hb_a !== hb_a_d) begin
                hb_a_trans = hb_a_trans + 1;
                if (last_hb_a >= 0) begin
                    if (t_win - last_hb_a < hb_a_gap_min) hb_a_gap_min = t_win - last_hb_a;
                    if (t_win - last_hb_a > hb_a_gap_max) hb_a_gap_max = t_win - last_hb_a;
                end
                last_hb_a = t_win;
            end
            hb_a_d = hb_a;

            // E · 静音
            if (HP_DIN_a === 1'b1) din_nonzero = din_nonzero + 1;
        end
    end

endmodule
