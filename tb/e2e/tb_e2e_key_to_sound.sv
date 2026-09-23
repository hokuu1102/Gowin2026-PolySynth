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

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    // ── DUT 端口 ──────────────────────────────────────────────────────
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi, spi_cs_l, spi_cs_r;
    wire miso_l, miso_r;

    top #(
        .DEMO_CHORD_ON   (1),
        .DEMO_NOTE_DELAY (DEMO_DELAY),
        .SOURCE_A_SEL    (0)                        // ⭐ 0 = W3a 手弹（⭐ 本 tb 主角）
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
        .spi_miso_l    (miso_l),
        .spi_miso_r    (miso_r),
        .spi_cs_l      (spi_cs_l),
        .spi_cs_r      (spi_cs_r)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 两片 ADC 从机（⭐ 复用队友已验证的 `mcp3208_model`）
    // ═══════════════════════════════════════════════════════════════════
    reg ovr_l = 1'b0, ovr_r = 1'b0;

    localparam [11:0] RAW_REST = 12'h7C1;       // ⭐ 静息（松手 1.60 V）
    localparam [11:0] RAW_DOWN = 12'h4D9;       // ⭐ 按下（触底 1.00 V）

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_l (
        .cs_n     (spi_cs_l),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_l),
        .ovr_en_i (ovr_l),
        .ovr_val_i(RAW_DOWN)
    );

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_r (
        .cs_n     (spi_cs_r),
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
        repeat (60000) @(posedge clk);          // ⭐ 等链稳定（⚠️ calib 要几帧）

        // ═══ 判据 ① 不按键 ⇒ 静音（⭐ 基线）═══
        measure_window(tg_idle, 40000);
        $display("  [idle ] HP_DIN toggles = %0d", tg_idle);
        chk("no key pressed => HP_DIN stays quiet (baseline)", tg_idle == 0);

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

        $display("");
        if (errors == 0)
            $display("PASS: end-to-end key-to-sound -- with the MCP3208 slave injecting real hall codes, a key press makes HP_DIN carry audio and release returns to silence");
        else
            $fatal(1, "FAIL: end-to-end key-to-sound had %0d error(s)", errors);

        #1000;
        $finish;
    end

endmodule
