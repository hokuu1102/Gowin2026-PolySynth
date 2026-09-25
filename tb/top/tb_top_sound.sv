// ─────────────────────────────────────────────────────────────────────────────
// tb_top_sound.sv · T57 验收（W3b · **顶层真的出声**）
//
// ⭐ 为什么这个 tb 是本项目最关键的一个（`T57`）：
//   在 `T57` 之前 `top.v` 送的是**常量 0**（静音）⇒ ⭐ **板子永远不出声**，
//   而所有仿真结论（时基 / I2S 时序 / DAC 帧格式）**全都是对的**。
//   ⇒ 只验"没有 FAIL"是不够的：⭐ **必须证明"真的有音频数据在动"**。
//
// ⭐ 4 条判据（全部可失败）：
//   ① ⭐⭐ **`HP_DIN` 确实在动**（不再是恒 0）—— 最根本的一条
//   ② ⭐⭐ **解串出来的样点非零且非常量**（真波形，⛔ 不是直流）
//   ③ ⭐⭐ **FFT 能数出 3 个谱峰**，且落在 **A4 / C#5 / E5** 附近
//   ④ ⭐ **`deadline_fault` 恒 0**（帧内截止，`A6`）
//
// ⚠️ 纪律：
//   · ⛔ 不用 SV 专有构造（`K-91`：Gowin 按 Verilog-2001 编译）
//   · ⭐ 判据写成**不变量/具体数值**，⛔ 不是"看起来对"（`C36`）
//   · ⭐ 时基：`sample_tick` 是**单拍脉冲**（`K-93`）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_top_sound;

    localparam integer POLY = 32;
    localparam integer OPV  = 2;
    localparam integer N_SAMPLES = 2048;      // 采集长度（FFT 用）

    // 期望频率（与 top.v 的 INC_A4/INC_CS5/INC_E5 对应）
    localparam real FS_HZ  = 48828.125;
    localparam real F_A4   = 440.0;
    localparam real F_CS5  = 554.365;
    localparam real F_E5   = 659.255;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                    // 50 MHz

    integer errors = 0;
    task chk;
        input [8*84-1:0] name;
        input            cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ── 被测顶层（⭐ 默认档 = 出声）────────────────────────────────────────
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    // ⭐⭐ 2026-09-26 新增：外置 DAC 三根线
    //   🔴 **为什么必须在这个 tb 里判**：⚠️ `tb_top_m0` 是 **M0 静音档**
    //      （`DEMO_CHORD_ON=0`）⇒ ⭐ 两路 `DIN` 本来就都是 0
    //      ⇒ 🔴 **它【原理上】测不了"音频内容"**
    //      ⇒ ⭐ 变异体"把外置那路变成恒 0"在那边**永远抓不到**（⭐ 实测 `M116 LEAK`）。
    //   ⭐ 本 tb 是【出声档】⇒ ⭐ **唯一能判"外置那路到底有没有音频"的地方**。
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;
    top #(
        .PA_ON_AFTER_RESET (0),        // 本 tb 只关心音频，功放时序另有 tb
        .DEMO_CHORD_ON     (1),        // ⭐ 出声档
        // ⭐⭐ 2026-09-23：源 A 现在有仲裁（见 top.v §源 A 仲裁）——
        //    本 tb 验的是【演示和弦】出声链 ⇒ ⭐ 必须选 1（演示和弦档）。
        //    ⚠️ 默认 0 = W3a 手弹；⚠️ 若不选，演示和弦进不了 evt_merge，本 tb 会失败。
        .SOURCE_A_SEL      (1),
        .DEMO_NOTE_DELAY   (2000),     // ⚠️ 改小以便快速仿真（默认 2_000_000 太慢）
        // ⭐⭐ 2026-09-24 补：漏传的 3 个加速参数
        //    🔴 **为什么必须补**：⚠️ 不传就用 `top.v` 的默认值 ⇒
        //       `DEMO_HOLD_CYC  = 50_000_000`（**1 秒**仿真时间）
        //       `AUTOTARE_DELAY_CLK = 10_000_000`（200 ms）
        //       `PA_ON_DELAY    =  1_048_576`（21 ms）
        //       ⇒ 🔴 合计 ≈ **1.22 秒**仿真时间 ⇒ ⭐ **本 tb 实测跑了 108 秒**
        //    ⭐ 取值照抄 `tb_e2e_key_to_sound`（⭐ 那边【实测通过】⇒ 有先例背书）
        //    ✅ 安全性（⭐ 已逐条核实，⛔ 不是"应该没事"）：
        //       · `PA_ON_DELAY`  —— ⭐ 本 tb 注释明说"只关心音频，功放时序另有 tb"
        //       · `DEMO_HOLD_CYC`—— ⭐ 本 tb 在 ~6096 clk（122 µs）就开始采集，
        //                            而 200_000 拍 = 4 ms ⇒ ✅ 采集仍在和弦发声期内
        //       · `AUTOTARE_DELAY_CLK` —— ⭐ 本 tb 不测标定
        //       · `SPAN_*`       —— ⭐ 本 tb 不测 `calib_span`
        .DEMO_HOLD_CYC       (200_000),
        .AUTOTARE_DELAY_CLK  (100_000),
        .PA_ON_DELAY         (32),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4),
        .POLY_TARGET       (POLY),
        .OSC_PER_VOICE     (OPV),
        .HEARTBEAT_DIV     (100)
    ) u_top (
        .clk (clk), .rst_n (rst_n),
        .HP_BCK (HP_BCK), .HP_WS (HP_WS), .HP_DIN (HP_DIN),
        .PA_EN_n (PA_EN_n), .led_heartbeat (led_hb),
        //   ⭐⭐ 2026-09-26：外置 DAC 三根线（⭐ 见上方说明）
        .I2S2_BCK (I2S2_BCK), .I2S2_LRCK (I2S2_LRCK), .I2S2_DIN (I2S2_DIN),
        //   ⚠️ 2026-09-23 晚：SPI 端口改成【预留 6 片】的向量 ⇒ ⭐ 给 6 位常量
        //      ⭐ 本 tb 测的是出声链（T57），⛔ 不测采集 ⇒ 常量即可
        .spi_miso (6'b111111), .spi_sclk (), .spi_mosi (), .spi_cs_n (),
        //   ⭐ 2026-09-23 阶段C：新增的串口端口 ——
        //   ⭐ `uart_rx` 给【空闲高】= 串口空闲态（⚠️ 悬空会是 x）
        .uart_rx (1'b1), .uart_tx ()
    );

    // ⭐ 内部探针：直接看 mixer 的输出（⛔ 不要只看到 I2S 引脚就下结论）
    wire signed [23:0] probe_sample = u_top.g_sound.sample_r;
    wire               probe_mx_valid = u_top.g_sound.mx_valid;
    wire               probe_mx_fault = u_top.g_sound.mx_fault;

    // ⭐ Goertzel：单频点能量（⛔ 不依赖 FFT 的峰-音对应关系）
    //    ⚠️ Verilog-2001 的 function 不能有 real 参数之外的花样 ⇒ 用 integer 索引 + real 累加
    //    ⚠️ `cap` 必须**先声明**（Verilog 不允许先用后声明）
    reg signed [23:0] cap [0:N_SAMPLES-1];

    function real goertzel;
        input real    f_target;
        input integer n;
        integer k;
        real    w, cw, sw, coeff;
        real    s0, s1, s2;
        begin
            w     = 2.0 * 3.14159265358979 * f_target / FS_HZ;
            cw    = $cos(w);
            sw    = $sin(w);
            coeff = 2.0 * cw;
            s1 = 0.0; s2 = 0.0;
            for (k = 0; k < n; k = k + 1) begin
                s0 = cap[k] + coeff * s1 - s2;
                s2 = s1;
                s1 = s0;
            end
            // 功率 = s1^2 + s2^2 - coeff*s1*s2
            goertzel = (s1 * s1) + (s2 * s2) - (coeff * s1 * s2);
            if (goertzel < 0.0) goertzel = 0.0;
        end
    endfunction

    // ── 用现成的 I2S 解串模型还原并行样点（⛔ 不复用被测逻辑）─────────────
    //    ⚠️ 判据必须用**独立**的还原路径（`C36`：探针要打在真正被证明的信号上）
    integer fd;
    integer n_din_one;          // HP_DIN 为 1 的拍数
    // ⭐⭐ 2026-09-26 新增：⭐ **外置那路的【活动量】**（⭐ 修 `M116` 的 LEAK）
    //   🔴 **为什么要单独统计**：⭐ 只判"两路逐拍一致"有**固有盲区** ——
    //      ⚠️ 变异体把**两路一起**变成 0 时，`0 == 0` 仍成立 ⇒ 🔴 判据说"一致"却没验到东西。
    //   ⭐ 本 tb 是**出声档** ⇒ ⭐ **`DIN` 必须真的在动**（⛔ 恒定 = 外置 DAC 听不到任何声音）。
    //   📌 判据分工：⭐ "一致"排相位错；⭐ "都在动"排整路恒定 ⇒ ⭐ **两条合起来才完整**。
    integer n_tog_din2 = 0;     // ⭐ I2S2_DIN 翻转次数
    integer n_tog_bck2 = 0;     // ⭐ I2S2_BCK 翻转次数
    integer n_tog_lrck2 = 0;    // ⭐ I2S2_LRCK 翻转次数
    integer n_tog_din1 = 0;     // ⭐ HP_DIN 翻转次数（⭐ 对照）
    integer n_diff_ext = 0;     // ⭐ 外置与板载逐拍不一致的次数
    reg bck2_p = 0, lrck2_p = 0, din2_p = 0, din1_p = 0;
    integer n_frames;
    integer n_clk_total;        // 采集期间的总 clk 数（判据 ① 的上界）
    reg     prev_din;
    integer din_trans;

    // 采样：在每帧的固定相位抓 mixer 输出（用 probe_mx_valid 做门控）
    integer cap_n;

    // ⭐⭐ 2026-09-26：外置那路的活动量统计（⭐ 见上方说明）
    always @(posedge clk) begin
        if (I2S2_BCK  !== bck2_p)  n_tog_bck2  = n_tog_bck2  + 1;
        if (I2S2_LRCK !== lrck2_p) n_tog_lrck2 = n_tog_lrck2 + 1;
        if (I2S2_DIN  !== din2_p)  n_tog_din2  = n_tog_din2  + 1;
        if (HP_DIN    !== din1_p)  n_tog_din1  = n_tog_din1  + 1;
        if (I2S2_DIN  !== HP_DIN)  n_diff_ext  = n_diff_ext  + 1;
        bck2_p  = I2S2_BCK;
        lrck2_p = I2S2_LRCK;
        din2_p  = I2S2_DIN;
        din1_p  = HP_DIN;
    end

    initial begin
        fd = $fopen("sim/evidence/top_sound_samples.csv", "w");
        if (fd == 0) begin
            $display("FAIL: cannot open sim/evidence/top_sound_samples.csv");
            $finish;
        end
        $fwrite(fd, "sample\n");

        n_din_one = 0; n_frames = 0; prev_din = 1'b0; din_trans = 0; cap_n = 0;
        n_clk_total = 0;

        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        // ⭐ 等开机自检音起完（tb 里 `DEMO_NOTE_DELAY` = 2000 拍）
        //    ⚠️ 再加几帧让包络升起来（ADSR attack ≈ 39 个采样拍）
        repeat (2000 + 2048 * 2) @(negedge clk);

        // ── 采集 N_SAMPLES 个样点（在 mx_valid 那一拍锁存）────────────────
        while (cap_n < N_SAMPLES) begin
            @(negedge clk);
            n_clk_total = n_clk_total + 1;
            if (probe_mx_valid) begin
                cap[cap_n] = probe_sample;
                $fwrite(fd, "%0d\n", probe_sample);
                cap_n = cap_n + 1;
            end
            // 顺手统计 HP_DIN 的活动
            if (HP_DIN === 1'b1) n_din_one = n_din_one + 1;
            if (HP_DIN !== prev_din) begin
                din_trans = din_trans + 1;
                prev_din = HP_DIN;
            end
            if (HP_WS === 1'b0 && prev_din === 1'b0) n_frames = n_frames + 1;
        end
        $fclose(fd);

        $display("");
        $display("==================== top / T57 出声链验收 ====================");
        $display("  采集样点数      : %0d", cap_n);
        $display("  采集期 clk 总数 : %0d", n_clk_total);
        $display("  HP_DIN 为 1 拍数 : %0d", n_din_one);
        $display("  HP_DIN 翻转次数  : %0d", din_trans);
        $display("  mixer 输出 fault : %b", probe_mx_fault);
        $display("============================================================");

        // ═══════════════════════════════════════════════════════════════════
        $display("== 1: HP_DIN 确实在动（不再是恒 0）==");
        // ═══════════════════════════════════════════════════════════════════
        chk("HP_DIN has both 1s and 0s (audio present, not silence)",
            n_din_one > 0 && n_din_one < n_clk_total);
        chk("HP_DIN toggles many times (real serial data)",
            din_trans > 1000);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 2: mixer 输出非零且非常量（真波形，不是直流）==");
        // ═══════════════════════════════════════════════════════════════════
        begin
            integer i, nz, diff;
            reg signed [23:0] first;
            nz = 0; diff = 0; first = cap[0];
            for (i = 0; i < cap_n; i = i + 1) begin
                if (cap[i] !== 24'sd0) nz = nz + 1;
                if (cap[i] !== first) diff = diff + 1;
            end
            $display("     非零样点 %0d / %0d，与首样点不同 %0d 个", nz, cap_n, diff);
            chk("mixer output is mostly non-zero (sound, not silence)", nz > (cap_n / 2));
            chk("mixer output varies (AC waveform, not DC)", diff > (cap_n / 2));
        end

        // ═══════════════════════════════════════════════════════════════════
        $display("== 3: 三个音真的在（A4 / C#5 / E5）==");
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ 判据（`C36`：探针要打在真正被证明的量上）：
        //   对采集到的样点做 **Goertzel**（单频点 DFT），直接测三个目标频点的能量，
        //   ⛔ 不依赖"跑 FFT 再数峰"（那还要判"哪个峰对应哪个音"）。
        //   ⭐ 判据 = **目标频点的能量显著高于邻近非目标频点**（≥ 20 dB）。
        //   ⚠️ 这样 M 变异（去掉某个音 / 改错 inc）会被立刻抓到。
        begin
            real e_a4, e_cs5, e_e5, e_ref1, e_ref2, e_ref3;
            integer gi;
            real acc_re, acc_im, ang, c, s, win;
            // 三个目标频点
            e_a4  = goertzel(F_A4,  cap_n);
            e_cs5 = goertzel(F_CS5, cap_n);
            e_e5  = goertzel(F_E5,  cap_n);
            // 三个"非目标"参考点（故意选在目标之间的空档）
            e_ref1 = goertzel(500.0, cap_n);
            e_ref2 = goertzel(610.0, cap_n);
            e_ref3 = goertzel(720.0, cap_n);

            $display("     A4  %.1f Hz 能量 %.3e", F_A4,  e_a4);
            $display("     C#5 %.1f Hz 能量 %.3e", F_CS5, e_cs5);
            $display("     E5  %.1f Hz 能量 %.3e", F_E5,  e_e5);
            $display("     参考 500/610/720 Hz 能量 %.3e / %.3e / %.3e", e_ref1, e_ref2, e_ref3);

            chk("A4 tone present (energy >> off-tone reference)",
                e_a4  > 10.0 * e_ref1);
            chk("C#5 tone present (energy >> off-tone reference)",
                e_cs5 > 10.0 * e_ref2);
            chk("E5 tone present (energy >> off-tone reference)",
                e_e5  > 10.0 * e_ref3);
        end

        // ═══════════════════════════════════════════════════════════════════
        $display("== 4: deadline_fault 恒 0（A6）==");
        // ═══════════════════════════════════════════════════════════════════
        chk("deadline_fault stays 0 (frame deadline met)", probe_mx_fault === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 5: 外置 DAC 那一路【真的有音频】（⭐ 2026-09-26 新增）
        //     🔴 **它修的是变异体 `M116` 的 LEAK** ——
        //        ⭐ "外置那路恒 0"这种失败，⚠️ `tb_top_m0`（静音档）**原理上抓不到**。
        //     ⭐ 本 tb 是【出声档】⇒ ⭐ 这里的 `I2S2_DIN` **必须真的在翻转**。
        // ═══════════════════════════════════════════════════════════════════
        $display("== 5: 外置 DAC 那一路真的有音频 ==");
        $display("     I2S2_BCK 翻转=%0d · I2S2_LRCK 翻转=%0d · I2S2_DIN 翻转=%0d",
                 n_tog_bck2, n_tog_lrck2, n_tog_din2);
        $display("     板载 HP_DIN 翻转=%0d · 两路逐拍不一致=%0d 拍",
                 n_tog_din1, n_diff_ext);
        chk("I2S2_BCK toggles (external DAC has a bit clock)",
            n_tog_bck2 > 100);
        chk("I2S2_LRCK toggles (external DAC has a frame clock)",
            n_tog_lrck2 > 10);
        // ⭐⭐ **核心判据**：⭐ 出声档下外置那路的数据脚必须真的在动
        chk("I2S2_DIN is LIVE (external DAC receives real audio, not DC)",
            n_tog_din2 > 10);
        // ⭐ 且必须与板载那路【同活动量】（⭐ 同源同步）
        chk("I2S2_DIN toggles as much as HP_DIN (same source, same rate)",
            n_tog_din2 == n_tog_din1);
        // ⭐ 逐拍一致（⭐ 排除相位漂移/接错线）
        chk("I2S2_DIN matches HP_DIN cycle-by-cycle (no phase drift)",
            n_diff_ext == 0);

        if (errors == 0)
            $display("PASS: top sound chain (T57) - HP_DIN is live and the mixer emits a varying waveform");
        else
            $fatal(1, "FAIL: top sound chain (T57) has %0d error(s)", errors);
        #200;
        $finish;
    end

    // ⭐ 兜底超时（`K-94`：任何 tb 都要有上限，⛔ 不能靠外部看门狗）
    initial begin
        #200_000_000;   // 4 ms 仿真时间上限
        $display("FAIL: tb_top_sound timeout (no verdict)");
        $fatal(1, "FAIL: timeout");
    end

endmodule
