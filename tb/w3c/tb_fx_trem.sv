`timescale 1ns/1ps
// ============================================================================
// tb_fx_trem.sv -- 音量颤音（Tremolo）的行为契约
//
//  判据（每条都必须【能红】）：
//    T1  复位：输出静音、valid_o 低
//    T2  硬旁路（en=0）：输出与输入【逐位相同】   <= 零回归的生死线
//    T3  depth=0 => 输出与输入【逐位相同】（单位增益，走乘法器但不改样点）
//    T4  depth>0 => 幅值【真的在摆】（同一输入下，输出最大值明显大于最小值）
//    T5  rate=0 => LFO 不动 => 输出恒定（不摆）
//    T6  速率有效：rate 越大，LFO 走得越快（同样拍数内相位推进更多）
//    T7  流：一进一出，不丢不重
//    T8  可观测：lfo_o 在动、tri_o 是三角波（有升有降）、gain_o 随深度变
//    T9  无 X 传播
//    T10 非空洞：depth=0 与 depth>0 的【输出必须不同】（否则 T4 无意义）
// ============================================================================
`default_nettype none

module tb_fx_trem;

    localparam integer SAMPLE_W = 24;
    localparam integer LFO_W    = 16;
    localparam integer DEPTH_W  = 8;
    localparam integer RATE_W   = 8;
    localparam integer PIPE     = 3;

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
    reg                        en_i = 1'b0;
    reg  [DEPTH_W-1:0]         depth_i = 8'd0;
    reg  [RATE_W-1:0]          rate_i  = 8'd7;

    wire                       valid_o;
    wire signed [SAMPLE_W-1:0] sample_o;
    wire [LFO_W-1:0]           lfo_o;
    wire [7:0]                 tri_o;
    wire [DEPTH_W:0]           gain_o;
    wire [DEPTH_W-1:0]         depth_used_o;
    wire [RATE_W-1:0]          rate_used_o;

    fx_trem #(
        .SAMPLE_W(SAMPLE_W), .LFO_W(LFO_W), .DEPTH_W(DEPTH_W), .RATE_W(RATE_W),
        .DEPTH_DEFAULT(8'd0), .RATE_DEFAULT(8'd7)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .valid_i(valid_i), .sample_i(sample_i),
        .en_i(en_i), .depth_i(depth_i), .rate_i(rate_i),
        .valid_o(valid_o), .sample_o(sample_o),
        .lfo_o(lfo_o), .tri_o(tri_o), .gain_o(gain_o),
        .depth_used_o(depth_used_o), .rate_used_o(rate_used_o)
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
            rst_n = 1'b0; valid_i = 1'b0; sample_i = 24'sd0;
            en_i = 1'b0; depth_i = 8'd0; rate_i = 8'd7;
            n_valid = 0; cap_v = 1'b0; cap_s = 24'sd0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    integer i;
    integer lo, hi;

    initial begin
        // ═══════════════════════════════════════════════════════════════════
        //  T1 复位
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        chk("T1a reset: valid_o is low", valid_o === 1'b0);
        chk("T1b reset: output is silent", sample_o === {SAMPLE_W{1'b0}});

        // ═══════════════════════════════════════════════════════════════════
        //  T2 硬旁路（en=0）—— 数值逐位相同
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b0; depth_i = 8'd255; rate_i = 8'd255;   // 故意给满深度
        repeat (3) @(posedge clk);
        begin : bypass_blk
            integer k; reg ok_all; ok_all = 1'b1;
            for (k = -5; k <= 5; k = k + 1) begin
                clr_cap;
                push($signed(k * 200000));
                if (!(cap_v === 1'b1 && cap_s === $signed(k * 200000))) ok_all = 1'b0;
            end
            chk("T2 en=0 hard bypass: output is BIT-IDENTICAL to input (11 points)", ok_all);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  T3 depth=0 => 单位增益（逐位不变）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; depth_i = 8'd0; rate_i = 8'd255;
        repeat (3) @(posedge clk);
        begin : unity_blk
            integer k; reg ok_all; ok_all = 1'b1;
            for (k = -4; k <= 4; k = k + 1) begin
                clr_cap;
                push($signed(k * 100000));
                if (!(cap_v === 1'b1 && cap_s === $signed(k * 100000))) ok_all = 1'b0;
            end
            chk("T3 depth=0 => unity gain, output unchanged", ok_all);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  T4 depth>0 => 幅值真的在摆
        //     ⚠️ 用大 rate（255）让 LFO 快走：三角波周期 = 2×65536/255 ≈ 514 样点
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; depth_i = 8'd255; rate_i = 8'd255;
        repeat (3) @(posedge clk);
        begin : swing_blk
            integer k;
            reg signed [SAMPLE_W-1:0] x;
            x = 24'sd1000000;              // 固定输入
            lo = 2000000; hi = -2000000;
            for (k = 0; k < 600; k = k + 1) begin
                clr_cap;
                push(x);
                if (cap_v === 1'b1) begin
                    if (cap_s > hi) hi = cap_s;
                    if (cap_s < lo) lo = cap_s;
                end
            end
            chk("T4a depth=255: amplitude really swings (max >> min over one LFO cycle)",
                (hi > 900000) && (lo < 100000));
            chk("T4b the maximum stays at (or below) the input amplitude (no gain boost)",
                hi <= 1000000);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  T5 rate=0 => LFO 不动 => 输出恒定
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; depth_i = 8'd200; rate_i = 8'd0;
        repeat (3) @(posedge clk);
        begin : flat_blk
            integer k; reg ok_flat;
            reg signed [SAMPLE_W-1:0] first;
            ok_flat = 1'b1; first = 24'sd0;
            for (k = 0; k < 40; k = k + 1) begin
                clr_cap;
                push(24'sd1000000);
                if (k == 0) first = cap_s;
                else if (cap_v === 1'b1 && cap_s !== first) ok_flat = 1'b0;
            end
            chk("T5 rate=0 => LFO frozen => output stays constant", ok_flat);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  T6 速率有效：rate 越大，同样拍数内相位推进越多
        // ═══════════════════════════════════════════════════════════════════
        begin : rate_blk
            reg [LFO_W-1:0] ph_slow, ph_fast;
            do_reset;
            en_i = 1'b1; depth_i = 8'd128; rate_i = 8'd1;
            repeat (3) @(posedge clk);
            for (i = 0; i < 50; i = i + 1) push(24'sd0);
            ph_slow = lfo_o;

            do_reset;
            en_i = 1'b1; depth_i = 8'd128; rate_i = 8'd20;
            repeat (3) @(posedge clk);
            for (i = 0; i < 50; i = i + 1) push(24'sd0);
            ph_fast = lfo_o;

            chk("T6 higher rate => LFO phase advances further in the same number of samples",
                ph_fast > ph_slow);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  T7 流：一进一出
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; depth_i = 8'd128; rate_i = 8'd7;
        repeat (3) @(posedge clk);
        n_valid = 0;
        for (i = 0; i < 20; i = i + 1) push($signed(i * 1000));
        chk("T7 stream: exactly one valid_o per valid_i (20 in, 20 out)", n_valid == 20);

        // ═══════════════════════════════════════════════════════════════════
        //  T8 可观测性：tri_o 有升有降（三角波）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; depth_i = 8'd255; rate_i = 8'd255;
        repeat (3) @(posedge clk);
        begin : tri_blk
            integer k; reg seen_up, seen_dn;
            integer prev_t; integer cur_t;
            seen_up = 1'b0; seen_dn = 1'b0; prev_t = -1;
            for (k = 0; k < 600; k = k + 1) begin
                clr_cap;
                push(24'sd0);
                cur_t = tri_o;
                if (prev_t >= 0) begin
                    if (cur_t > prev_t) seen_up = 1'b1;
                    if (cur_t < prev_t) seen_dn = 1'b1;
                end
                prev_t = cur_t;
            end
            chk("T8a tri_o is a real triangle (both rising and falling observed)",
                seen_up && seen_dn);
            chk("T8b gain_o / depth_used_o / rate_used_o expose live values",
                depth_used_o === 8'd255 && rate_used_o === 8'd255);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  T9 无 X 传播
        // ═══════════════════════════════════════════════════════════════════
        chk("T9a no X on sample_o", (^sample_o) !== 1'bx);
        chk("T9b no X on valid_o",  (^valid_o)  !== 1'bx);
        chk("T9c no X on lfo_o",    (^lfo_o)    !== 1'bx);
        chk("T9d no X on gain_o",   (^gain_o)   !== 1'bx);

        // ═══════════════════════════════════════════════════════════════════
        //  T10 非空洞：depth=0 与 depth>0 的输出必须不同
        // ═══════════════════════════════════════════════════════════════════
        begin : novac_blk
            reg signed [SAMPLE_W-1:0] y0, y1;
            do_reset;
            en_i = 1'b1; depth_i = 8'd0; rate_i = 8'd255;
            repeat (3) @(posedge clk);
            for (i = 0; i < 30; i = i + 1) begin clr_cap; push(24'sd1000000); end
            y0 = cap_s;

            do_reset;
            en_i = 1'b1; depth_i = 8'd255; rate_i = 8'd255;
            repeat (3) @(posedge clk);
            for (i = 0; i < 30; i = i + 1) begin clr_cap; push(24'sd1000000); end
            y1 = cap_s;

            chk("T10 non-vacuous: depth=0 and depth=255 give DIFFERENT outputs", y0 !== y1);
        end

        if (errors == 0) $display("PASS: fx_trem -- bypass bit-exact, depth swings, rate controls LFO");
        else $fatal(1, "FAIL: tb_fx_trem has %0d error(s)", errors);
        $finish;
    end

    initial begin #40000000; $fatal(1, "FAIL: tb_fx_trem timeout"); end

endmodule
