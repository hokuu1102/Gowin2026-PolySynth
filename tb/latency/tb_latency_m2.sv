`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_latency_m2 · **T16 / M2 低延迟**（`files/20-代码/仿真与验证方案.md` §三 M2）
//
// 判据（⭐ 权威判定由 `tools/latency_stats.py` 给，见 tb 末尾打印的命令）：
//   · 50 次统计，**数字端延迟 < 2 个音频帧**（2 × 1024 = 2048 clk_sys = 40.96 µs）
//   · **极差 < 0.1 ms**（= 稳定上界、确定性无抖动）
//
// ⭐ 为什么要"分解"而不是只报一个总数：
//   从 `UP/DOWN` 事件到**板上 DAC 真的收到数据位**，中间是两段性质完全不同的延迟：
//     ① **合成链**（`note_manager` → `voice` → `mixer`）—— ⏳ 还没写（`T8`/`T9`/`T10` 是乙的）
//     ② **输出级固有**（`i2s_tx` 只在 `frame_start` 装载 ⇒ **帧量化** + LSBJ 右对齐要等 16 个
//        空 `BCK` 才发数据位 ⇒ **串行化**）—— ✅ 本 tb 用**真的 `clk_gen` + 真的 `i2s_tx`** 实测
//   ⇒ 本 tb 给出 ② 的**硬上界**，于是**留给乙的预算是明确的数**：
//     `2 帧 − ②`。等 `T10` 落地，把桩换成真链，同一个台子直接量端到端。
//
// ⚠️ 桩（`m2_stub_voice`）是**测试台里的占位**，不是 RTL 交付物：它只做
//    「2 拍同步 + 一次门控」，**故意做成最快**（所以量到的是①的下限 3 拍，而不是乙的真实周期数）。
//
// ⚠️ 测量口径（避免"少算/多算一拍"这种经典错误）：
//    两端点**都用同一个 `posedge clk` 监视器观测** —— 事件那一端取"监视器看到引脚为高的那一拍"，
//    输出那一端取"监视器看到 `HP_DIN` 为高的那一拍"。两端的"寄存器晚一拍可见"效应**互相抵消**，
//    ⛔ 不要一端用驱动时刻、另一端用观测时刻（那样会白送/白扣一拍）。
//
// ⭐ 桩的输出取 `24'sh800000`（**最高位为 1**）：`DATA_BITS=16` 取高 16 位 = `0x8000`，
//    整个帧里**只有 MSB 那一位是 1** ⇒ `HP_DIN` 上的**第一个上升沿就是该样点 MSB 被送出的时刻**，
//    判定无歧义（⛔ 用满量程正值的话首位数位是 0，得靠"波形对齐"去猜，那就不算可复现证据了）。
// ─────────────────────────────────────────────────────────────────────────────
module tb_latency_m2;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer MCLK_DIV       = 4;
    localparam integer SLOT_BITS      = CLK_PER_SAMPLE / BCLK_DIV / 2;   // 32
    localparam integer DATA_BITS      = 16;
    localparam integer SAMPLE_W       = 24;
    localparam integer N_TRIALS       = 50;      // M2 要求 50 次
    localparam integer GAP            = 1500;    // 两次事件之间静默（> 1 帧，避免与上一帧的位混淆）
    localparam integer MAX_FRAMES_X1024 = 2 * CLK_PER_SAMPLE;   // 2048
    localparam real    MAX_RANGE_MS   = 0.1;

    localparam integer T = 20;                   // 50 MHz

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // ═══════════════════════════════════════════════════════════════
    // 真实时基 + 真实发送（② 输出级）
    // ═══════════════════════════════════════════════════════════════
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;
    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .BCLK_DIV       (BCLK_DIV),
        .MCLK_DIV       (MCLK_DIV)
    ) u_clk (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (tick_audio), .mclk_en (mclk_en),
        .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .lrclk (lrclk), .frame_start (frame_start)
    );

    // 激励：合成 UP / DOWN 拨弦事件（⛔ 不依赖左手板实物）
    reg up_pulse, down_pulse, stub_clr;
    wire signed [SAMPLE_W-1:0] stub_sample;

    m2_stub_voice #(.SAMPLE_W (SAMPLE_W)) u_stub (
        .clk (clk), .rst_n (rst_n),
        .up (up_pulse), .down (down_pulse), .clr (stub_clr),
        .sample (stub_sample)
    );

    wire HP_BCK, HP_WS, HP_DIN;
    i2s_tx #(
        .SAMPLE_W (SAMPLE_W), .DATA_BITS (DATA_BITS), .SLOT_BITS (SLOT_BITS),
        .JUSTIFY (1), .MSB_DELAY (1), .LRCK_POL (0)
    ) u_tx (
        .clk (clk), .rst_n (rst_n),
        .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .frame_start (frame_start),
        .sample_l (stub_sample), .sample_r (stub_sample),
        .HP_BCK (HP_BCK), .HP_WS (HP_WS), .HP_DIN (HP_DIN)
    );

    // ── A8：X/Z 传播（声明放例化之前）──────────────────────────────
    wire [31:0] a8_din, a8_bck, a8_ws, a8_smp;
    chk_xprop #(.W(1),        .NAME("HP_DIN"))       u_a8_din (.clk(clk), .rst_n(rst_n), .sig(HP_DIN),      .err_cnt(a8_din));
    chk_xprop #(.W(1),        .NAME("HP_BCK"))       u_a8_bck (.clk(clk), .rst_n(rst_n), .sig(HP_BCK),      .err_cnt(a8_bck));
    chk_xprop #(.W(1),        .NAME("HP_WS"))        u_a8_ws  (.clk(clk), .rst_n(rst_n), .sig(HP_WS),       .err_cnt(a8_ws));
    chk_xprop #(.W(SAMPLE_W), .NAME("stub_sample"))  u_a8_smp (.clk(clk), .rst_n(rst_n), .sig(stub_sample), .err_cnt(a8_smp));

    // ═══════════════════════════════════════════════════════════════
    // 激励 + 测量（同一个 `posedge clk`，⛔ 不用延时，避免竞争）
    // ═══════════════════════════════════════════════════════════════
    localparam integer S_IDLE = 0, S_WAIT_OFF = 1, S_WAIT_A = 2, S_WAIT_B = 3, S_WAIT_GAP = 4, S_DONE = 5;

    integer cyc = 0;                 // 全局 clk_sys 拍数（监视器时间基准）
    integer tw = 0;                  // 等待上限用的循环变量
    integer k = 0;                   // 第几次
    integer wait_cnt = 0;
    integer ev_ref = 0;              // ⭐ 事件时刻（= 监视器看到引脚为高的那一拍）
    integer lat_a, lat_b;            // ① 样点算好  ② DAC 收到数据位
    integer a_min, a_max, b_min, b_max, b_sum;
    integer n_up, n_down;
    integer errors = 0;
    integer fd_a, fd_b;
    reg [2:0] st = S_IDLE;
    reg done = 0;

    initial begin
        $dumpfile("build/sim/tb_latency_m2/tb_latency_m2.vcd");
        $dumpvars(0, tb_latency_m2);

        a_min = 1 << 30; a_max = 0; b_min = 1 << 30; b_max = 0; b_sum = 0;
        n_up = 0; n_down = 0;

        fd_a = $fopen("sim/evidence/latency_m2_sample.log", "w");
        fd_b = $fopen("sim/evidence/latency_m2_din.log", "w");

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        // ⚠️ 有上限的等待：万一状态机卡住，⛔ 不能让仿真挂死（tb_all.ps1 会被拖住）
        //    预期约 165k 拍；给到 40 万拍。超时的话下面"统计次数"那项会直接 FAIL。
        //    ⚠️ 循环变量另开一个（⛔ 不能复用 FSM 的 `cyc`，那是时间基准）
        for (tw = 0; tw < 400000; tw = tw + 1) begin
            @(posedge clk);
            if (done === 1'b1) tw = 400000;
        end
        #1;
        $fclose(fd_a);
        $fclose(fd_b);

        $display("");
        $display("==================== M2 低延迟实测（50 次）====================");
        $display("  事件      : UP %0d 次 / DOWN %0d 次（合成激励，⛔ 不依赖左手板实物）", n_up, n_down);
        $display("  ① 事件→样点算好（桩，最快情形）  : min=%0d max=%0d clk（%0.3f µs）",
                 a_min, a_max, a_max * 1e6 / 50e6);
        $display("  ② ⭐ 事件→板上 DAC 收到数据位     : min=%0d max=%0d clk", b_min, b_max);
        $display("     = %0.3f ~ %0.3f µs = %0.4f ~ %0.4f 音频帧",
                 b_min * 1e6 / 50e6, b_max * 1e6 / 50e6,
                 b_min * 48828.125 / 50e6, b_max * 48828.125 / 50e6);
        $display("     均值 = %0.3f clk = %0.4f 帧（1 帧 = %0d clk = 20.48 µs）",
                 b_sum * 1.0 / N_TRIALS, (b_sum * 1.0 / N_TRIALS) * 48828.125 / 50e6, CLK_PER_SAMPLE);
        $display("  极差      : %0d clk = %0.4f ms（判据 < %0.3f ms）",
                 b_max - b_min, (b_max - b_min) * 1e3 / 50e6, MAX_RANGE_MS);
        $display("  ⭐ 输出级固有分量（②−①）: %0d ~ %0d clk = %0.3f ~ %0.3f 帧 —— 帧量化 + 串行化，⛔ 躲不开",
                 b_min - a_max, b_max - a_min, (b_min - a_max) * 48828.125 / 50e6,
                 (b_max - a_min) * 48828.125 / 50e6);
        $display("  ⭐ 留给合成链（`note_manager`+`voice`+`mixer`）的余量 = 2 帧 − ②最坏 = %0d clk = %0.3f µs",
                 MAX_FRAMES_X1024 - b_max, (MAX_FRAMES_X1024 - b_max) * 1e6 / 50e6);
        $display("  A8        : din=%0d bck=%0d ws=%0d sample=%0d", a8_din, a8_bck, a8_ws, a8_smp);
        $display("  证据      : sim/evidence/latency_m2_din.log（50 行）· _sample.log（诊断）");
        $display("  ⭐ 权威判定：python tools\\latency_stats.py sim\\evidence\\latency_m2_din.log --unit cycles --expect-count 50");
        $display("=============================================================");

        if (b_max <= MAX_FRAMES_X1024)
            $display("  ok : 最大延迟 %0d clk = %0.4f 帧 ≤ 2 帧（数字端目标）", b_max, b_max * 48828.125 / 50e6);
        else begin
            $display("FAIL: 最大延迟 %0d clk = %0.4f 帧 > 2 帧（%0d clk）",
                     b_max, b_max * 48828.125 / 50e6, MAX_FRAMES_X1024);
            errors = errors + 1;
        end

        if ((b_max - b_min) * 1e3 / 50e6 <= MAX_RANGE_MS)
            $display("  ok : 极差 %0d clk = %0.4f ms ≤ %0.3f ms（确定性无抖动）",
                     b_max - b_min, (b_max - b_min) * 1e3 / 50e6, MAX_RANGE_MS);
        else begin
            $display("FAIL: 极差 %0d clk = %0.4f ms > %0.3f ms（有抖动）",
                     b_max - b_min, (b_max - b_min) * 1e3 / 50e6, MAX_RANGE_MS);
            errors = errors + 1;
        end

        if (n_up + n_down == N_TRIALS)
            $display("  ok : 统计次数 = %0d（M2 要求 50）", N_TRIALS);
        else begin
            $display("FAIL: 只完成 %0d 次（要求 %0d）", n_up + n_down, N_TRIALS);
            errors = errors + 1;
        end

        if (a8_din == 0 && a8_bck == 0 && a8_ws == 0 && a8_smp == 0)
            $display("  ok : A8 无 X/Z 传播（HP_DIN/HP_BCK/HP_WS/样点）");
        else begin
            $display("FAIL: A8 检测到 X/Z（din=%0d bck=%0d ws=%0d sample=%0d）", a8_din, a8_bck, a8_ws, a8_smp);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("PASS: M2 数字端延迟上界与抖动均达标（50 次，极差 < 0.1 ms）");
        else             $fatal(1, "FAIL: M2 有 %0d 项不达标", errors);

        #100;
        $finish;
    end

    // ── ⚠️ 桩：只做「2 拍同步 + 一次门控」，故意做成最快（量到的是①的下限）──
    always @(posedge clk) begin
        cyc = cyc + 1;

        if (rst_n !== 1'b1) begin
            st       <= S_IDLE;
            wait_cnt <= 0;
            up_pulse <= 1'b0;
            down_pulse <= 1'b0;
            stub_clr <= 1'b1;
        end else begin
            // 抑制期（两次事件之间）把桩清零 ⇒ ⛔ 避免"上一帧的数据位"被当成这一帧的响应
            stub_clr <= (st == S_WAIT_A || st == S_WAIT_B) ? 1'b0 : 1'b1;

            case (st)
                S_IDLE: begin
                    if (k >= N_TRIALS) st <= S_DONE;
                    else begin
                        // ⭐ 相位扫描：613 与 1024 互质 ⇒ 50 次落在 50 个不同相位上
                        //    （每次的静默间隔又与帧长互质，相位覆盖更均匀）
                        wait_cnt <= (k * 613 + 17) % CLK_PER_SAMPLE;
                        st       <= S_WAIT_OFF;
                    end
                end

                S_WAIT_OFF: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else begin
                        if (k % 2 == 0) begin up_pulse   <= 1'b1; n_up   = n_up   + 1; end
                        else            begin down_pulse <= 1'b1; n_down = n_down + 1; end
                        // ⭐ 事件基准 = **下一拍**（监视器/接收端在那一拍才看到引脚为高）
                        ev_ref <= cyc + 1;
                        st     <= S_WAIT_A;
                    end
                end

                S_WAIT_A: begin
                    up_pulse   <= 1'b0;
                    down_pulse <= 1'b0;
                    // ① 样点算好（桩输出变为非 0）
                    if (stub_sample !== {SAMPLE_W{1'b0}}) begin
                        lat_a = cyc - ev_ref;
                        $fdisplay(fd_a, "LATENCY %0d", lat_a);
                        if (lat_a < a_min) a_min = lat_a;
                        if (lat_a > a_max) a_max = lat_a;
                        st <= S_WAIT_B;
                    end
                end

                S_WAIT_B: begin
                    // ② 板上 DAC 真的收到数据位（`HP_DIN` 第一个上升沿 = 该样点 MSB）
                    if (HP_DIN === 1'b1) begin
                        lat_b = cyc - ev_ref;
                        $fdisplay(fd_b, "LATENCY %0d", lat_b);
                        if (lat_b < b_min) b_min = lat_b;
                        if (lat_b > b_max) b_max = lat_b;
                        b_sum = b_sum + lat_b;
                        k        <= k + 1;
                        wait_cnt <= GAP;
                        st       <= S_WAIT_GAP;
                    end
                end

                S_WAIT_GAP: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else              st       <= S_IDLE;
                end

                S_DONE: begin
                    up_pulse   <= 1'b0;
                    down_pulse <= 1'b0;
                    done = 1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

// ─────────────────────────────────────────────────────────────────────────────
// `m2_stub_voice` · **测试台桩**（⛔ 不是交付 RTL，别放进 `rtl/`）
//   代替还没写的 `note_manager` → `voice` → `mixer`：UP/DOWN 事件 → 2 拍同步 → 门控出样点。
//   目的：把①（合成链）压到**最快**，从而量出②（输出级固有延迟）的**硬上界**。
// ─────────────────────────────────────────────────────────────────────────────
module m2_stub_voice #(
    parameter integer SAMPLE_W = 24,
    parameter [SAMPLE_W-1:0] NOTE_VAL = 24'sh800000   // ⭐ 最高位为 1 ⇒ HP_DIN 第一个上升沿含义唯一
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    up,
    input  wire                    down,
    input  wire                    clr,        // 高 = 清音（两次事件之间）
    output reg signed [SAMPLE_W-1:0] sample
);
    reg up_s1, up_s2, dn_s1, dn_s2;

    always @(posedge clk) begin
        if (!rst_n) begin
            up_s1 <= 1'b0; up_s2 <= 1'b0; dn_s1 <= 1'b0; dn_s2 <= 1'b0;
            sample <= {SAMPLE_W{1'b0}};
        end else begin
            up_s1 <= up;     up_s2 <= up_s1;      // 2 拍同步（真实输入都是异步来的）
            dn_s1 <= down;   dn_s2 <= dn_s1;
            if (clr)                        sample <= {SAMPLE_W{1'b0}};
            else if (up_s2 | dn_s2)         sample <= NOTE_VAL;
        end
    end
endmodule
