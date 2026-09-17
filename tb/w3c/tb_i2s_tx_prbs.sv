`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_i2s_tx_prbs · **值域/位模式覆盖**（`tb/` 审查发现的两个激励强度缺口）
//
// ⭐ 为什么需要它（2026-09-17 tb 审查发现）：
//    `tb/w3c/tb_i2s_tx.sv` 的正弦表**只有 64 个不同值**（`N_FRAMES=256` ⇒ 每个值重复 4 次），
//    ⇒ 24 bit 里**绝大多数位模式从未出现过**。这类"激励只覆盖一小片值域"的 tb
//    对下面这些缺陷是**盲的**：
//      · 某一位**恒错**（例如 bit13 永远不发）—— 只要那一位在所有测试值里都是同一个极性就看不出来
//      · 相邻位**串扰/粘连**
//      · 低位截断方向错（取高 16 位 vs 取低 16 位）—— 某些值上恰好结果相同
//
// ⚠️ 为什么**不**直接把 `tb_i2s_tx.sv` 的激励换成随机流：
//    那个 tb 同时产出 **M1 的证据链**（`sim/evidence/i2s_tx_l.csv` → FFT 单谱峰 + SNR）。
//    换成随机流会让频谱变成噪声、**毁掉 M1 的证据**。⇒ 覆盖任务交给本 tb（独立文件）。
//
// 本 tb 三种激励（都在同一仿真里跑，各自独立实例 + 独立 S2 解串模型）：
//   ① **LCG 伪随机**（固定种子 ⇒ 可复现）覆盖整个 24 bit 值域
//   ② **逐位走查**：`1<<k`（k=0..23）与 `~(1<<k)` ⇒ 每个数据位都单独出现过一次
//   ③ **边界值**：`0x7FFFFF / 0x800000 / 0 / 0xFFFFFF / 0x0000FF`（截断边界）
//
// 判据：解串回来的样点与激励**逐点一致**（比 16 bit 有效位），且**零不一致**。
// ─────────────────────────────────────────────────────────────────────────────
module tb_i2s_tx_prbs;

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer BCLK_DIV       = 16;
    localparam integer MCLK_DIV       = 4;
    localparam integer SAMPLE_W       = 24;
    localparam integer DATA_BITS      = 16;
    localparam integer SLOT_BITS      = 32;
    localparam integer N_LCG          = 512;    // LCG 帧数
    localparam integer N_WALK         = 48;     // 逐位走查帧数（24 位 × 2）
    localparam integer N_EDGE         = 16;     // 边界值帧数
    localparam integer N_FRAMES       = N_LCG + N_WALK + N_EDGE;
    localparam integer T              = 20;     // 50 MHz

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    integer errors = 0;

    // ── 时基 ────────────────────────────────────────────────────────
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;
    clk_gen #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE), .BCLK_DIV (BCLK_DIV), .MCLK_DIV (MCLK_DIV)
    ) u_clk (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (tick_audio), .mclk_en (mclk_en), .bclk_en (bclk_en),
        .bclk_half_en (bclk_half_en), .lrclk (lrclk), .frame_start (frame_start)
    );

    // ── 被测 + S2 模型 ──────────────────────────────────────────────
    reg  signed [SAMPLE_W-1:0] stim;
    wire HP_BCK, HP_WS, HP_DIN;
    i2s_tx #(
        .SAMPLE_W (SAMPLE_W), .DATA_BITS (DATA_BITS), .SLOT_BITS (SLOT_BITS),
        .JUSTIFY (1), .MSB_DELAY (1), .LRCK_POL (0)
    ) u_tx (
        .clk (clk), .rst_n (rst_n), .bclk_en (bclk_en), .bclk_half_en (bclk_half_en),
        .frame_start (frame_start), .sample_l (stim), .sample_r (stim),
        .HP_BCK (HP_BCK), .HP_WS (HP_WS), .HP_DIN (HP_DIN)
    );
    wire signed [SAMPLE_W-1:0] rx_l, rx_r; wire v_l, v_r;
    i2s_rx_model #(
        .SAMPLE_W (SAMPLE_W), .DATA_BITS (DATA_BITS), .SLOT_BITS (SLOT_BITS),
        .JUSTIFY (1), .MSB_DELAY (1), .LRCK_POL (0)
    ) u_rx (
        .clk (clk), .rst_n (rst_n), .bck (HP_BCK), .ws (HP_WS), .din (HP_DIN),
        .sample_l (rx_l), .sample_r (rx_r), .valid_l (v_l), .valid_r (v_r),
        .recon_l(), .recon_r()
    );

    wire [31:0] a8_din, a8_bck, a8_ws;
    chk_xprop #(.W(1), .NAME("HP_DIN")) u_a8_din (.clk(clk), .rst_n(rst_n), .sig(HP_DIN), .err_cnt(a8_din));
    chk_xprop #(.W(1), .NAME("HP_BCK")) u_a8_bck (.clk(clk), .rst_n(rst_n), .sig(HP_BCK), .err_cnt(a8_bck));
    chk_xprop #(.W(1), .NAME("HP_WS"))  u_a8_ws  (.clk(clk), .rst_n(rst_n), .sig(HP_WS),  .err_cnt(a8_ws));

    // ── 激励生成：帧计数决定"这一帧发什么" ───────────────────────────
    // ⚠️ 与 `tb_i2s_tx.sv` 同样的纪律：**提前一帧**给出下一帧要发的值，
    //    并在**同一个 `tick_audio`** 上把"期望值"锁存下来（⛔ 不要靠"第几个 tick"去索引，
    //    那是 `L54`/`L57` 记过的差一帧坑）。
    reg [31:0] lcg;
    reg signed [SAMPLE_W-1:0] exp_now;
    integer fr;
    integer walk_idx;

    function signed [SAMPLE_W-1:0] next_stim;
        input integer f;
        input [31:0] l;
        begin
            if (f < N_LCG) begin
                next_stim = $signed(l[31:8]);                       // ① LCG
            end else if (f < N_LCG + N_WALK) begin
                // ② 逐位走查：偶数帧 = 1<<k，奇数帧 = ~(1<<k)
                if (((f - N_LCG) % 2) == 0) next_stim = (24'd1 << ((f - N_LCG) / 2));
                else                         next_stim = ~(24'd1 << ((f - N_LCG) / 2));
            end else begin
                // ③ 边界值
                case ((f - N_LCG - N_WALK) % 5)
                    0: next_stim = 24'sh7FFFFF;
                    1: next_stim = 24'sh800000;
                    2: next_stim = 24'sh000000;
                    3: next_stim = 24'shFFFFFF;
                    default: next_stim = 24'sh0000FF;              // 截断边界（只有低 8 位）
                endcase
            end
        end
    endfunction

    integer ok_l, bad_l, ok_r, bad_r, n_seen;

    always @(posedge clk) begin
        if (!rst_n) begin
            fr       <= 0;
            lcg      <= 32'hDEAD_BEEF;      // ⭐ 固定种子 ⇒ 结果可复现
            stim     <= 24'sh000000;
            exp_now  <= 24'sh000000;
            ok_l = 0; bad_l = 0; ok_r = 0; bad_r = 0; n_seen = 0;
        end else if (tick_audio === 1'b1) begin
            // 本帧真正被装载的值 = 当前 `stim`（DUT 在 frame_start 装载）
            exp_now <= stim;
            // 准备下一帧的激励
            lcg <= lcg * 32'd1664525 + 32'd1013904223;
            stim <= next_stim(fr + 1, lcg * 32'd1664525 + 32'd1013904223);
            fr <= fr + 1;
        end
    end

    // 逐点比对（warm-up：跳过复位后前 2 个 valid —— 首个时隙未填满）
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (v_l === 1'b1) begin
                n_seen = n_seen + 1;
                if (n_seen > 2) begin
                    if (rx_l[SAMPLE_W-1 -: DATA_BITS] === exp_now[SAMPLE_W-1 -: DATA_BITS]) ok_l = ok_l + 1;
                    else begin
                        bad_l = bad_l + 1;
                        if (bad_l <= 5)
                            $display("  [x] L frame %0d got 0x%06h exp 0x%06h", n_seen, rx_l, exp_now);
                    end
                end
            end
            if (v_r === 1'b1) begin
                if (rx_r[SAMPLE_W-1 -: DATA_BITS] === exp_now[SAMPLE_W-1 -: DATA_BITS]) ok_r = ok_r + 1;
                else begin
                    bad_r = bad_r + 1;
                    if (bad_r <= 5)
                        $display("  [x] R got 0x%06h exp 0x%06h", rx_r, exp_now);
                end
            end
        end
    end

    initial begin
        $dumpfile("build/sim/tb_i2s_tx_prbs/tb_i2s_tx_prbs.vcd");
        $dumpvars(0, tb_i2s_tx_prbs);

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        repeat (CLK_PER_SAMPLE * (N_FRAMES + 4)) @(posedge clk);
        #1;

        $display("");
        $display("================ i2s_tx value/bit-pattern coverage ================");
        $display("  LCG random  : %0d frames (fixed seed DEADBEEF, reproducible)", N_LCG);
        $display("  bit walk    : %0d frames (1<<k and ~(1<<k) for k=0..23)", N_WALK);
        $display("  edge values : %0d frames (7FFFFF/800000/0/FFFFFF/0000FF)", N_EDGE);
        $display("  L channel   : ok %0d / bad %0d", ok_l, bad_l);
        $display("  R channel   : ok %0d / bad %0d", ok_r, bad_r);
        $display("  A8          : din=%0d bck=%0d ws=%0d", a8_din, a8_bck, a8_ws);
        $display("==================================================================");

        if (bad_l == 0 && ok_l >= N_FRAMES - 4)
            $display("  ok : L channel: every value (incl. all bit patterns) round-trips exactly");
        else begin
            $display("FAIL: L channel mismatch (ok %0d bad %0d)", ok_l, bad_l); errors = errors + 1;
        end

        if (bad_r == 0 && ok_r >= N_FRAMES - 4)
            $display("  ok : R channel: every value round-trips exactly");
        else begin
            $display("FAIL: R channel mismatch (ok %0d bad %0d)", ok_r, bad_r); errors = errors + 1;
        end

        if (a8_din == 0 && a8_bck == 0 && a8_ws == 0) $display("  ok : A8 no X/Z");
        else begin $display("FAIL: A8 detected X/Z (din=%0d bck=%0d ws=%0d)", a8_din, a8_bck, a8_ws); errors = errors + 1; end

        $display("");
        if (errors == 0) $display("PASS: i2s_tx round-trips the full 24-bit value range, every single-bit pattern, and the truncation edge cases");
        else             $fatal(1, "FAIL: i2s_tx coverage test has %0d unexpected result(s)", errors);

        #100;
        $finish;
    end

endmodule
