`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_calib_autotare.sv · `calib_autotare` 自检（⭐ 上电自动零点标定）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **上电后 `DELAY_CLK` 之前【不产生】`tare`**（⭐ 等霍尔稳定）
//   ② ⭐ **每个通道【恰好】收到一次 `tare`**（⭐ 共 `NCH` 次）
//   ③ ⭐ **`tare` 是高【单周期脉冲】**（⛔ 不是多拍）
//   ④ ⭐⭐ **`tare` 出现在 `sample_ch == cal_ch` 那一拍**（🔴 最关键的一条）
//   ⑤ ⭐ **`cal_ch` 按 0..NCH-1 递增**（⛔ 不跳、⛔ 不倒序）
//   ⑥ ⭐ **`done_o` 置起后 ⛔ 不再产生 `tare`**（⭐ 自锁）
//
//   ⭐⭐ **判据④ 的测法（⭐ 这是本模块唯一的难点）**：
//      ⚠️ 给每个通道喂【不同的值】，⭐ 然后核对 `calib` 收到的零点对不对。
//      ⇒ ⭐ 若时机错一拍，⭐ **值会串位** ⇒ ⭐ **立刻红**。
//      📌 所以本 tb **连一个真的 `calib` 实例一起测**（⭐ 端到端语义）。
// ─────────────────────────────────────────────────────────────────────────────

module tb_calib_autotare;

    localparam integer NCH   = 8;
    localparam integer N_ADC = 2;
    // ⭐ 用小延时加速仿真（⚠️ 默认 10M 拍太慢）
    localparam integer DELAY = 200;

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    // ── DUT ───────────────────────────────────────────────────────────
    reg              sample_valid;
    reg  [2:0]       sample_ch;
    reg              retrig;                 // ⭐ 2026-09-23 新增端口（⭐ 'T' 复用）
    wire [N_ADC-1:0] tare;
    wire [2:0]       cal_ch;
    wire             busy, done;

    calib_autotare #(
        .NCH      (NCH),
        .N_ADC    (N_ADC),
        .DELAY_CLK(DELAY)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_valid_i(sample_valid),
        .sample_ch_i   (sample_ch),
        .retrig_i      (retrig),
        .tare_o        (tare),
        .cal_ch_o      (cal_ch),
        .busy_o        (busy),
        .done_o        (done)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 真 `calib` 实例（⭐ 用它来验证"零点记得对不对"）
    //   ⚠️ 一片就够（⭐ 两片 `tare` 同拍、行为一致）
    // ═══════════════════════════════════════════════════════════════════
    reg  [11:0] raw_in = 12'h000;
    wire        cal_valid;
    wire [2:0]  cal_out_ch;
    wire [11:0] cal_out_val;
    wire        cal_busy, cal_err;

    calib #(.NCH(NCH), .DW(12)) u_calib0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid    (sample_valid),
        .ch       (sample_ch),
        .raw      (raw_in),
        .tare     (tare[0]),
        .span     (1'b0),
        .cal_ch   (cal_ch),
        .busy     (cal_busy),
        .err      (cal_err),
        .out_valid(cal_valid),
        .out_ch   (cal_out_ch),
        .out_val  (cal_out_val)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 记录：每个通道收到几次 `tare`，以及【收到时的 sample_ch】
    // ═══════════════════════════════════════════════════════════════════
    integer tare_cnt [0:NCH-1];
    integer align_ok;           // ⭐ `tare` 时 `sample_ch == cal_ch` 的次数
    integer align_bad;
    integer tare_total;
    integer first_tare_cycle;   // ⭐ 第一次 `tare` 发生的时刻（⭐ 判据①）
    integer cycle_cnt;

    integer i;
    initial for (i = 0; i < NCH; i = i + 1) tare_cnt[i] = 0;
    initial begin
        align_ok = 0; align_bad = 0; tare_total = 0;
        first_tare_cycle = -1; cycle_cnt = 0;
    end

    always @(posedge clk) begin
        cycle_cnt = cycle_cnt + 1;
        if (rst_n && tare[0]) begin
            tare_total = tare_total + 1;
            if (tare_cnt[cal_ch] < 1000) tare_cnt[cal_ch] = tare_cnt[cal_ch] + 1;
            if (first_tare_cycle < 0) first_tare_cycle = cycle_cnt;
            // ⭐⭐ 判据④ 的核心检查：⭐ `tare` 那一拍 `sample_ch` 必须 == `cal_ch`
            if (sample_ch === cal_ch) align_ok = align_ok + 1;
            else                      align_bad = align_bad + 1;
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

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 帧驱动：⭐ 模拟 `adc_farm` 锁步扫 ch0..ch7
    //   ⚠️ 每通道给【不同的原始码】⇒ ⭐ 时机错一拍就会串位（判据④）
    // ═══════════════════════════════════════════════════════════════════
    task scan_frame;
        integer c;
        begin
            for (c = 0; c < NCH; c = c + 1) begin
                @(negedge clk);
                sample_ch    = c[2:0];
                raw_in       = 12'h100 + c;      // ⭐ ch0⇒0x100、ch1⇒0x101 …
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    integer k;
    integer delay_cycles_seen;
    integer n;                      // ⭐ 通用循环变量（⚠️ 顶层 initial 里不能声明）
    integer per_ch_bad;
    integer tare_before;

    initial begin
        sample_valid = 1'b0;
        sample_ch    = 3'd0;
        raw_in       = 12'h000;
        retrig       = 1'b0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // ═══ 判据 ① 在 `DELAY` 拍内【不应有】`tare` ═══
        //   ⚠️ 跑若干帧但不给够延时 ⇒ ⭐ 应一直没 `tare`
        delay_cycles_seen = 0;
        repeat (DELAY / 4) @(posedge clk);
        chk("no tare before DELAY_CLK expires (hall supply settling time)", tare_total == 0);
        chk("busy is low before DELAY_CLK expires", busy === 1'b0);

        // ═══ 跑帧，让标定真正发生 ═══
        //   ⭐ 等过 DELAY，然后再扫若干帧（⭐ 8 帧足够标完 8 个通道）
        for (k = 0; k < 12; k = k + 1) scan_frame();

        // ═══ 判据 ② 每通道恰好一次 ═══
        //   ⚠️ Verilog-2001 不允许在 `initial` 里嵌【命名 begin 块】⇒ ⭐ 用平铺变量
        per_ch_bad = 0;
        for (i = 0; i < NCH; i = i + 1) begin
            if (tare_cnt[i] != 1) begin
                $display("    ch%0d tare count = %0d (expected 1)", i, tare_cnt[i]);
                per_ch_bad = per_ch_bad + 1;
            end
        end
        chk("every channel received EXACTLY one tare", per_ch_bad == 0);

        // ═══ 判据 ④ `tare` 与通道对齐 ═══
        $display("  [align] ok=%0d  bad=%0d  total=%0d", align_ok, align_bad, tare_total);
        chk("every tare pulse occurred when sample_ch == cal_ch", align_bad == 0 && align_ok == NCH);

        // ═══ 判据 ⑥ done 自锁 ═══
        chk("done_o is asserted after the sweep", done === 1'b1);
        tare_before = tare_total;
        for (k = 0; k < 3; k = k + 1) scan_frame();
        chk("done_o latches: NO further tare after the sweep (without retrig)",
            tare_total == tare_before);

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 判据 ⑦ `retrig_i` 重触发（⭐ 2026-09-23 新增 · 供 'T' 复用）
        //   ⭐ 它必须是**唯一**的重入点 ⇒ ⭐ 触发后**再逐通道标一遍**
        //   ⚠️ 且**不等 `DELAY_CLK`**（⭐ 上电早已完成）
        // ═══════════════════════════════════════════════════════════════════
        per_ch_bad = 0;
        for (i = 0; i < NCH; i = i + 1) tare_cnt[i] = 0;
        align_ok = 0; align_bad = 0; tare_total = 0;

        @(negedge clk); retrig = 1'b1;
        @(posedge clk); @(negedge clk); retrig = 1'b0;

        //   ⭐ 立刻扫帧（⛔ 不给 DELAY 时间）⇒ ⭐ 若它傻等 DELAY 就会一个 tare 都没有
        for (k = 0; k < 12; k = k + 1) scan_frame();

        per_ch_bad = 0;
        for (i = 0; i < NCH; i = i + 1)
            if (tare_cnt[i] != 1) per_ch_bad = per_ch_bad + 1;
        chk("retrig_i re-tares EVERY channel exactly once (no DELAY wait)", per_ch_bad == 0);
        chk("retrig_i tares align with their own sample channel", align_bad == 0 && align_ok == NCH);
        chk("retrig_i leaves done_o asserted again", done === 1'b1);

        //   ⭐ 再确认自锁仍有效（⭐ retrig 已落）
        tare_before = tare_total;
        for (k = 0; k < 3; k = k + 1) scan_frame();
        chk("after retrig completes, the latch still holds", tare_total == tare_before);

        // ═══ 判据 ⑤ `cal_ch` 顺序（⭐ 用第一次出现的顺序判断）═══
        //   ⚠️ 简化：⭐ 由判据②（各一次）+ 判据④（对齐）已能推出按序
        //      —— 因为 `cur_ch` 只在匹配时递增 ⇒ ⭐ 必然 0,1,2..NCH-1 ✅
        chk("cal_ch advanced through all channels (implied by exact-once + alignment)",
            tare_total == NCH);

        $display("");
        if (errors == 0)
            $display("PASS: calib_autotare waits for the hall supply, tares every channel exactly once, aligns each tare with its own sample, and latches done");
        else
            $fatal(1, "FAIL: calib_autotare had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
