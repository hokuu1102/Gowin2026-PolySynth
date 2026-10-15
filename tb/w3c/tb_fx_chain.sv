`timescale 1ns/1ps
// ============================================================================
// tb_fx_chain.sv -- 效果器链（5 级串联）的行为契约
//
//  ⚠️ 本 tb 用【小延迟线】实例化（AW=10 ⇒ 1024 样点）：
//     真实 AW=14 ⇒ 16384 样点，填满要 16384 次推送，仿真太慢。
//     填满逻辑本身由 `tb_fx_delay` 覆盖（它已经全绿），这里只验【链的接线与顺序】。
//  🔴 **AW 不能小于 8**：`fx_delay.v:169` 有 `{{(TAP_W-18){...}}, mod_Q8}`
//     而 `TAP_W = AW + 10` ⇒ AW<8 时重复次数为负 ⇒ 编译报
//     "Concatenation repeat may not be negative"（我第一版用 AW=6 就撞了）
//
//  判据（每条都必须【能红】）：
//    C1  全掩码 = 0 **且颤音深度 = 0** => 输出与输入【逐位相同】   <= 零回归的生死线
//        🔴 注意：2026-10-15 起音量颤音是【常开】的（用户裁定）
//        ⇒ ⭐ **掩码 = 0 不再等于"逐位相同"** —— 还要把深度推到 0 才行
//           （深度 0 ⇒ g=256 ⇒ (x×256)>>8 = x ⇒ 逐位等于输入 ✓）
//        ⚠️ 这是本 tb 第一版会假红的地方（深度默认非 0 时 C1 必红）
//    C2  混响位（bit3）单独置 1 => 也是【逐位相同】（留位直通，无逻辑）
//    C3  失真位（bit0）单独置 1 => 输出【确实被改动】（失真生效）
//    C4  延迟位（bit2）单独置 1 => 输出【确实被改动】（延迟生效，回声回来）
//    C5  合唱位（bit1）单独置 1 => 输出【确实被改动】（合唱生效）
//    C6  ⭐⭐ 延迟与合唱【可以同时开】（两条独立的线）＋ 串联顺序验证
//    C7  流：一进一出，不丢不重
//    C8  可观测：en_mask_o 回显、dly_active_o 跟随、pipe_o 正确
//    C9  无 X 传播
//    C10 非空洞：全 0 与"只开失真"的输出必须不同
// ============================================================================
`default_nettype none

module tb_fx_chain;

    localparam integer SAMPLE_W = 24;
    localparam integer AW       = 10;         // 小延迟线（1024 样点）；必须 >= 8
    localparam integer AW_CH    = 10;         // 合唱线（本 tb 也用 1024，省仿真时间）
    localparam integer MIX_W    = 8;
    localparam integer FB_W     = 8;
    localparam integer GAIN_W   = 16;
    localparam integer TRIM_W   = 16;
    localparam integer DEPTH_W  = 8;
    localparam integer RATE_W   = 8;
    localparam integer LFO_W    = 16;
    localparam integer PIPE     = 16;         // legacy diagnostic port width (not cycle count)

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    task chk;
        input [8*110-1:0] name;
        input             cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    reg                        valid_i = 1'b0;
    reg  signed [SAMPLE_W-1:0] sample_i = 24'sd0;
    reg  [7:0]                 en_mask_i = 8'd0;
    reg  [1:0]                 dist_sel_i = 2'd0;
    reg  [GAIN_W-1:0]          dist_gain_i = 16'd4096;
    reg  [TRIM_W-1:0]          dist_trim_i = 16'd32768;
    reg  [AW-1:0]              dly_delay_i = 10'd16;
    reg  [AW_CH-1:0]           chor_delay_i = 10'd16;   // ⭐ 合唱基础延迟
    reg  [MIX_W-1:0]           dly_mix_i = 8'd128;
    reg  [FB_W-1:0]            dly_fb_i = 8'd0;
    reg  [DEPTH_W-1:0]         trem_depth_i = 8'd0;    // ⭐ 默认 0（见下）
    reg  [RATE_W-1:0]          trem_rate_i = 8'd255;

    wire                       valid_o;
    wire signed [SAMPLE_W-1:0] sample_o;
    wire [7:0]                 en_mask_o;
    wire                       dly_active_o;
    wire                       chor_active_o;
    wire                       dly_primed_o;
    wire [15:0]                dist_clip_cnt_o;
    wire [LFO_W-1:0]           trem_lfo_o;
    wire [PIPE-1:0]            pipe_o;

    fx_chain #(
        .SAMPLE_W(SAMPLE_W), .AW(AW), .AW_CH(AW_CH), .MIX_W(MIX_W), .FB_W(FB_W),
        .GAIN_W(GAIN_W), .TRIM_W(TRIM_W),
        .DEPTH_W(DEPTH_W), .RATE_W(RATE_W), .LFO_W(LFO_W),
        .PIPE_TOTAL(PIPE)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .valid_i(valid_i), .sample_i(sample_i),
        .en_mask_i(en_mask_i),
        .dist_sel_i(dist_sel_i), .dist_gain_i(dist_gain_i), .dist_trim_i(dist_trim_i),
        .dly_delay_i(dly_delay_i), .chor_delay_i(chor_delay_i),
        .dly_mix_i(dly_mix_i), .dly_fb_i(dly_fb_i),
        .trem_depth_i(trem_depth_i), .trem_rate_i(trem_rate_i),
        .valid_o(valid_o), .sample_o(sample_o),
        .en_mask_o(en_mask_o), .dly_active_o(dly_active_o),
        .chor_active_o(chor_active_o), .dly_primed_o(dly_primed_o),
        .dist_clip_cnt_o(dist_clip_cnt_o), .trem_lfo_o(trem_lfo_o), .pipe_o(pipe_o)
    );

    reg signed [SAMPLE_W-1:0] cap_s;
    reg                       cap_v;
    integer                   n_valid;

    task push;
        input signed [SAMPLE_W-1:0] s;
        begin
            @(negedge clk);
            sample_i = s;
            valid_i  = 1'b1;
            @(negedge clk);
            valid_i  = 1'b0;
            repeat (PIPE + 3) @(negedge clk);
        end
    endtask

    always @(posedge clk) if (rst_n && valid_o) begin
        cap_s = sample_o; cap_v = 1'b1; n_valid = n_valid + 1;
    end

    task clr_cap; begin cap_v = 1'b0; end endtask

    task do_reset;
        begin
            rst_n = 1'b0; valid_i = 1'b0; sample_i = 24'sd0; en_mask_i = 8'd0;
            //  ⭐ 颤音是常开的 ⇒ 每个测试都必须从【深度 0】开始
            //     （否则"掩码=0 就逐位相同"这类判据会假红）
            trem_depth_i = 8'd0;
            n_valid = 0; cap_v = 1'b0; cap_s = 24'sd0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    //  把延迟线填满（小实例只需 2*DEPTH 次推送）
    task prime_delay;
        integer k;
        begin
            for (k = 0; k < (1 << (AW+1)); k = k + 1) push(24'sd0);
        end
    endtask

    integer i;
    reg signed [SAMPLE_W-1:0] y_all_off, y_dist_only;

    initial begin
        // ═══════════════════════════════════════════════════════════════════
        //  C1 全掩码 = 0 => 逐位相同（零回归的生死线）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'd0;
        repeat (3) @(posedge clk);
        begin : alloff_blk
            integer k; reg ok_all; ok_all = 1'b1;
            for (k = -6; k <= 6; k = k + 1) begin
                clr_cap;
                push($signed(k * 300000));
                if (!(cap_v === 1'b1 && cap_s === $signed(k * 300000))) ok_all = 1'b0;
            end
            chk("C1 all-off (mask=0): output is BIT-IDENTICAL to input (13 points)", ok_all);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  C2 混响位单独置 1 => 也是逐位相同（留位直通）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_1000;          // 只有 bit3
        repeat (3) @(posedge clk);
        begin : rev_blk
            integer k; reg ok_all; ok_all = 1'b1;
            for (k = -4; k <= 4; k = k + 1) begin
                clr_cap;
                push($signed(k * 250000));
                if (!(cap_v === 1'b1 && cap_s === $signed(k * 250000))) ok_all = 1'b0;
            end
            chk("C2 reverb bit alone (bit3): placeholder passthrough, output unchanged", ok_all);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  C3 失真位单独置 1 => 输出确实被改动
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_0001;          // bit0 = 失真
        dist_gain_i = 16'd49152;           // 12.0（会削波）
        dist_trim_i = 16'd32768;           // 1.0
        repeat (3) @(posedge clk);
        clr_cap; push(24'sd800000);
        chk("C3a distortion bit alone: output IS changed (hard clip bites)",
            cap_v === 1'b1 && cap_s === 24'sh7FFFFF);
        chk("C3b distortion clip counter moved", dist_clip_cnt_o !== 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        //  C4 延迟位单独置 1 => 输出确实被改动（先填满延迟线）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_0100;          // bit2 = 延迟
        dly_delay_i = 10'd16;              // 16 样点
        dly_mix_i   = 8'd128;              // 0.5
        dly_fb_i    = 8'd0;
        repeat (3) @(posedge clk);
        prime_delay;                       // 填满
        clr_cap; push(24'sd500000);
        chk("C4a delay bit alone: dry is still in its own slot (mix=0.5 halves it)",
            cap_v === 1'b1 && cap_s === 24'sd250000);
        //  再推 24 个样点，看回声出来（延迟 16 样点）
        begin : echo_blk
            integer k; reg seen;
            seen = 1'b0;
            for (k = 0; k < 24; k = k + 1) begin
                clr_cap;
                push(24'sd0);
                if (cap_v === 1'b1 && cap_s !== 24'sd0) seen = 1'b1;
            end
            chk("C4b delay bit alone: the echo DOES come back (non-zero after D samples)", seen);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  C5 合唱位单独置 1 => 输出确实被改动
        //     🔴 **我第一版写错了**：用 `prime_delay`（写**全 0**）填线
        //        ⇒ 湿声恒为 0 ⇒ 合唱再怎么调抽头，输出恒 = 干声×0.5
        //        ⇒ 判据永远看到 200000 ⇒ **测不出合唱** ✗
        //     ✅ 正确：用**有变化的信号**填线（这里填锯齿），
        //        这样抽头一动，读出来的值就变 ⇒ 输出跟着变 ✓
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_0010;          // bit1 = 合唱
        dly_mix_i = 8'd128;                // 0.5
        repeat (3) @(posedge clk);
        begin : prime_ramp_blk
            integer k;
            for (k = 0; k < (1 << (AW+1)); k = k + 1)
                push($signed(k * 20000 - 5000000));   // 锯齿（覆盖正负）
        end
        begin : chor_blk
            integer k; reg seen_diff;
            seen_diff = 1'b0;
            for (k = 0; k < 80; k = k + 1) begin
                clr_cap;
                push(24'sd400000);
                if (cap_v === 1'b1 && cap_s !== 24'sd200000) seen_diff = 1'b1;
            end
            chk("C5 chorus bit alone: output IS modulated (differs from the plain mix)",
                seen_diff);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  C6 ⭐⭐ 延迟与合唱【可以同时开】（2026-10-15 用户要求）
        //     两条各自独立的延迟线 ⇒ 两级都跑，而且【串联】（合唱在前）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_0110;          // bit1 + bit2 同时置
        repeat (3) @(posedge clk);
        chk("C6a delay+chorus bits together: BOTH stages are active",
            dly_active_o === 1'b1 && chor_active_o === 1'b1);

        do_reset;
        en_mask_i = 8'b0000_0010;          // 只有合唱
        repeat (3) @(posedge clk);
        chk("C6b chorus bit alone: chorus on, delay off",
            chor_active_o === 1'b1 && dly_active_o === 1'b0);

        do_reset;
        en_mask_i = 8'b0000_0100;          // 只有延迟
        repeat (3) @(posedge clk);
        chk("C6c delay bit alone: delay on, chorus off",
            dly_active_o === 1'b1 && chor_active_o === 1'b0);

        do_reset;
        en_mask_i = 8'b0000_0000;
        repeat (3) @(posedge clk);
        chk("C6d no delay/chorus bit: both off",
            dly_active_o === 1'b0 && chor_active_o === 1'b0);

        //  ⭐ 串联验证：两位同开 ⇒ 输出必须与"只开其中一个"都【不同】
        //     ⚠️ 必须用【有变化的信号】填线（全 0 或全常数会让三个输出趋同 ⇒ 判据空洞）
        begin : series_blk
            reg signed [SAMPLE_W-1:0] y_ch, y_dly, y_both;
            //  只开合唱
            do_reset;
            en_mask_i = 8'b0000_0010; dly_mix_i = 8'd128;
            repeat (3) @(posedge clk);
            for (i = 0; i < (1 << (AW+1)); i = i + 1)
                push($signed(i * 20000 - 5000000));       // 锯齿填线
            clr_cap; push(24'sd400000);
            y_ch = cap_s;
            //  只开延迟
            do_reset;
            en_mask_i = 8'b0000_0100; dly_mix_i = 8'd128;
            repeat (3) @(posedge clk);
            for (i = 0; i < (1 << (AW+1)); i = i + 1)
                push($signed(i * 20000 - 5000000));
            clr_cap; push(24'sd400000);
            y_dly = cap_s;
            //  两个都开
            do_reset;
            en_mask_i = 8'b0000_0110; dly_mix_i = 8'd128;
            repeat (3) @(posedge clk);
            for (i = 0; i < (1 << (AW+1)); i = i + 1)
                push($signed(i * 20000 - 5000000));
            clr_cap; push(24'sd400000);
            y_both = cap_s;
            chk("C6e series: chorus+delay together differs from either one alone",
                (y_both !== y_ch) && (y_both !== y_dly));
        end

        // ═══════════════════════════════════════════════════════════════════
        //  C7 流：一进一出
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_0111;          // 失真+合唱+延迟（⭐ bit4 已空闲，不再用）
        repeat (3) @(posedge clk);
        n_valid = 0;
        for (i = 0; i < 20; i = i + 1) push($signed(i * 1000));
        chk("C7 stream: exactly one valid_o per valid_i with 4 stages on (20 in, 20 out)",
            n_valid == 20);

        // ═══════════════════════════════════════════════════════════════════
        //  C8 可观测性
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'b0000_0111;
        repeat (3) @(posedge clk);
        chk("C8a en_mask_o echoes the mask", en_mask_o === 8'b0000_0111);
        // Independently measured by tb_fx_chain_latency_contract: input n -> output n+17.
        chk("C8b pipe_o reports the measured 17-cycle pipeline depth", pipe_o === 16'd17);

        // ═══════════════════════════════════════════════════════════════════
        //  C11 ⭐⭐ 音量颤音【固定常开】（2026-10-15 用户裁定）
        //      ⭐ 掩码 = 0（所有开关效果都关）时，只要深度 > 0，它【仍然在调制】
        //      ⇒ 证明它**没有使能位**、不靠掩码 ✓
        //      ⚠️ 这条同时是 C1 的"非空洞"对照：
        //         同一个掩码（0），深度 0 ⇒ 逐位相同；深度 255 ⇒ 幅值在摆 ✓
        // ═══════════════════════════════════════════════════════════════════
        begin : trem_always_blk
            integer k;
            reg signed [SAMPLE_W-1:0] x;
            integer lo11, hi11;
            x = 24'sd1000000;
            lo11 = 2000000; hi11 = -2000000;
            do_reset;
            en_mask_i = 8'd0;              // ⭐ 所有开关效果都关
            trem_depth_i = 8'd255;         // ⭐ 但颤音深度推满
            trem_rate_i  = 8'd255;         // 让它快速摆动
            repeat (3) @(posedge clk);
            for (k = 0; k < 600; k = k + 1) begin
                clr_cap;
                push(x);
                if (cap_v === 1'b1) begin
                    if (cap_s > hi11) hi11 = cap_s;
                    if (cap_s < lo11) lo11 = cap_s;
                end
            end
            chk("C11a tremolo is ALWAYS ON: mask=0 + depth=255 still modulates",
                (hi11 > 900000) && (lo11 < 100000));
            chk("C11b and it never boosts above the input amplitude", hi11 <= 1000000);

            //  对照：同一个掩码，深度 = 0 ⇒ 逐位相同（这就是 C1 在测的）
            do_reset;
            en_mask_i = 8'd0;
            trem_depth_i = 8'd0;
            repeat (3) @(posedge clk);
            clr_cap; push(24'sd1000000);
            chk("C11c same mask but depth=0 => bit-identical passthrough",
                cap_v === 1'b1 && cap_s === 24'sd1000000);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  C9 无 X 传播
        // ═══════════════════════════════════════════════════════════════════
        chk("C9a no X on sample_o", (^sample_o) !== 1'bx);
        chk("C9b no X on valid_o",  (^valid_o)  !== 1'bx);
        chk("C9c no X on en_mask_o",(^en_mask_o)!== 1'bx);
        chk("C9d no X on chor_active_o",(^chor_active_o) !== 1'bx);

        // ═══════════════════════════════════════════════════════════════════
        //  C10 非空洞：全 0 与"只开失真"的输出必须不同
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_mask_i = 8'd0;
        repeat (3) @(posedge clk);
        clr_cap; push(24'sd800000);
        y_all_off = cap_s;

        do_reset;
        en_mask_i = 8'b0000_0001;
        dist_gain_i = 16'd49152; dist_trim_i = 16'd32768;
        repeat (3) @(posedge clk);
        clr_cap; push(24'sd800000);
        y_dist_only = cap_s;

        chk("C10 non-vacuous: all-off and distortion-only give DIFFERENT outputs",
            y_all_off !== y_dist_only);

        if (errors == 0) $display("PASS: fx_chain -- all-off bit-exact, reverb placeholder, delay+chorus run TOGETHER in series");
        else $fatal(1, "FAIL: tb_fx_chain has %0d error(s)", errors);
        $finish;
    end

    initial begin #40000000; $fatal(1, "FAIL: tb_fx_chain timeout"); end

endmodule
