`timescale 1ns/1ps
// ============================================================================
// tb_fx_dist.sv -- 数字失真（硬削）的行为契约
//
//  判据（每条都必须【能红】）：
//    D1  复位：输出静音、valid_o 低、削波计数为 0
//    D2  硬旁路（en=0）：输出与输入【逐位相同】  <= 这是"零回归"的生死线
//    D3  单位增益 + 单位补偿：小信号【不被改动】（逐位相同）
//    D4  硬削：大信号被夹到 ±满量程（不是回绕）
//    D5  连续增益：增益变大 => 削波次数变多（单调）
//    D6  补偿：trim=0 => 输出恒 0；trim 减半 => 输出幅值减半
//    D7  流：一进一出，不丢不重；valid_o 与 sample_o 同拍
//    D8  可观测：削波计数在削波时涨、旁路时不涨；峰值反映削波【前】的幅值
//    D9  预留档位 sel=1/2/3 的行为【确定为与 0 相同】（不是未定义）
//    D10 无 X 传播
// ============================================================================
`default_nettype none

module tb_fx_dist;

    localparam integer SAMPLE_W  = 24;
    localparam integer GAIN_W    = 16;
    localparam integer TRIM_W    = 16;
    localparam integer PIPE      = 5;          // 与 DUT 的流水线深度一致

    //  Q4.12 的 1.0 / Q1.15 的 1.0
    localparam [GAIN_W-1:0] G_ONE  = 16'd4096;
    localparam [TRIM_W-1:0] T_ONE  = 16'd32768;

    //  满量程
    localparam signed [SAMPLE_W-1:0] FS_MAX =  24'sh7FFFFF;
    localparam signed [SAMPLE_W-1:0] FS_MIN = -24'sh800000;

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

    // ── DUT 接口 ──────────────────────────────────────────────────────────
    reg                        valid_i = 1'b0;
    reg  signed [SAMPLE_W-1:0] sample_i = 24'sd0;
    reg                        en_i = 1'b0;
    reg  [1:0]                 sel_i = 2'd0;
    reg  [GAIN_W-1:0]          gain_i = G_ONE;
    reg  [TRIM_W-1:0]          trim_i = T_ONE;

    wire                       valid_o;
    wire signed [SAMPLE_W-1:0] sample_o;
    wire [15:0]                clip_cnt_o;
    wire [GAIN_W-1:0]          gain_used_o;
    wire [TRIM_W-1:0]          trim_used_o;
    wire [SAMPLE_W-1:0]        peak_o;

    fx_dist #(
        .SAMPLE_W  (SAMPLE_W),
        .GAIN_W    (GAIN_W),
        .TRIM_W    (TRIM_W),
        .GAIN_DEFAULT (G_ONE),
        .TRIM_DEFAULT (T_ONE)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .valid_i(valid_i), .sample_i(sample_i),
        .en_i(en_i), .sel_i(sel_i), .gain_i(gain_i), .trim_i(trim_i),
        .valid_o(valid_o), .sample_o(sample_o),
        .clip_cnt_o(clip_cnt_o), .gain_used_o(gain_used_o),
        .trim_used_o(trim_used_o), .peak_o(peak_o)
    );

    // ── 激励：送一个样点，等 PIPE 拍收结果 ───────────────────────────────
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
            //  等流水线走完（留 3 拍余量）
            repeat (PIPE + 3) @(negedge clk);
        end
    endtask

    //  采样：抓"最近一次 valid_o=1 时的 sample_o"
    always @(posedge clk) if (rst_n && valid_o) begin
        cap_s   = sample_o;
        cap_v   = 1'b1;
        n_valid = n_valid + 1;
    end

    //  每次 push 前清掉抓取标志
    task clr_cap;
        begin cap_v = 1'b0; end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0; valid_i = 1'b0; sample_i = 24'sd0;
            en_i = 1'b0; sel_i = 2'd0; gain_i = G_ONE; trim_i = T_ONE;
            n_valid = 0; cap_v = 1'b0; cap_s = 24'sd0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    //  期望值（参考实现：与 DUT 同一套算法，但用行为级写法）
    //    y = sat( sat(x*gain>>12) * trim>>15 )
    function signed [SAMPLE_W-1:0] expect_y;
        input signed [SAMPLE_W-1:0] x;
        input [GAIN_W-1:0] g;
        input [TRIM_W-1:0] t;
        reg signed [SAMPLE_W+GAIN_W-1:0] xg;
        reg signed [SAMPLE_W+TRIM_W-1:0] y;
        reg signed [SAMPLE_W-1:0] xg_c;
        begin
            xg   = (x * $signed({1'b0, g})) >>> 12;
            xg_c = (xg > FS_MAX) ? FS_MAX : ((xg < FS_MIN) ? FS_MIN : xg[SAMPLE_W-1:0]);
            y    = (xg_c * $signed({1'b0, t})) >>> 15;
            expect_y = (y > FS_MAX) ? FS_MAX : ((y < FS_MIN) ? FS_MIN : y[SAMPLE_W-1:0]);
        end
    endfunction

    integer i;
    integer clip_before, clip_after;
    reg signed [SAMPLE_W-1:0] small_x, big_x;

    initial begin
        small_x = 24'sd1000;          // 小信号（不削波）
        big_x   = 24'sd800000;        // 大信号（削波）

        // ═══════════════════════════════════════════════════════════════════
        //  D1 复位
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        chk("D1a reset: valid_o is low", valid_o === 1'b0);
        chk("D1b reset: output is silent", sample_o === {SAMPLE_W{1'b0}});
        chk("D1c reset: clip count is 0", clip_cnt_o === 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        //  D2 硬旁路（en=0）—— 数值逐位相同（零回归的生死线）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b0;
        gain_i = 16'd16384;           // 故意给个会削波的增益
        trim_i = 16'd8192;
        repeat (3) @(posedge clk);
        begin : bypass_blk
            integer k;
            reg ok_all;
            ok_all = 1'b1;
            for (k = 0; k < 8; k = k + 1) begin
                clr_cap;
                push($signed(k * 100000 - 400000));      // 覆盖正负
                if (!(cap_v === 1'b1 && cap_s === $signed(k * 100000 - 400000)))
                    ok_all = 1'b0;
            end
            chk("D2 en=0 hard bypass: output is BIT-IDENTICAL to input (8 points)", ok_all);
        end
        chk("D2b en=0: clip counter did NOT move", clip_cnt_o === 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        //  D3 单位增益 + 单位补偿 => 小信号逐位不变
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; sel_i = 2'd0;
        gain_i = G_ONE; trim_i = T_ONE;
        repeat (3) @(posedge clk);
        begin : unity_blk
            integer k;
            reg ok_all;
            ok_all = 1'b1;
            for (k = -6; k <= 6; k = k + 1) begin
                clr_cap;
                push($signed(k * 50000));
                if (!(cap_v === 1'b1 && cap_s === $signed(k * 50000))) ok_all = 1'b0;
            end
            chk("D3 unity gain+trim: small signals pass through unchanged", ok_all);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  D4 硬削：大信号被夹到 ±满量程（不是回绕）
        //     ⚠️ 量纲要算对（我第一版算错了）：
        //        FS_MAX = 2^23−1 = 8 388 607
        //        输入 800000 × 增益 4.0 = 3 200 000  < FS_MAX ⇒ 【不削波】
        //        ⇒ 必须用增益 12.0（49152）才越界：800000 × 12 = 9 600 000 ✓
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; sel_i = 2'd0;
        gain_i = 16'd49152;           // 12.0（越界才削）
        trim_i = T_ONE;               // 1.0 => 削完不缩
        repeat (3) @(posedge clk);
        clr_cap; push(big_x);
        chk("D4a hard clip: big positive input saturates to FS_MAX", cap_v === 1'b1 && cap_s === FS_MAX);
        clr_cap; push(-big_x);
        chk("D4b hard clip: big negative input saturates to FS_MIN", cap_v === 1'b1 && cap_s === FS_MIN);
        chk("D4c hard clip: clip counter moved", clip_cnt_o !== 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        //  D5 连续增益：增益越大，削波越多（单调）＋ 非空洞
        //     ⚠️ 第一版是【空洞地通过】：输入 600000 × 增益 ≤ 12 = 7.2M < FS_MAX
        //        ⇒ 一次都没削 ⇒ 计数恒 0 ⇒ 单调性平凡成立 ✗
        //     ⇒ 现在用 800000，且【额外要求最大增益那次确实削了】（非空洞）✓
        // ═══════════════════════════════════════════════════════════════════
        begin : mono_blk
            integer g;
            integer prev_cnt;
            integer cnt_at_max;
            reg ok_mono;
            ok_mono = 1'b1;
            prev_cnt = -1;
            cnt_at_max = 0;
            for (g = 1; g <= 12; g = g + 1) begin
                do_reset;
                en_i = 1'b1;
                gain_i = g * 4096;            // 1.0 .. 12.0
                trim_i = T_ONE;
                repeat (3) @(posedge clk);
                for (i = 0; i < 16; i = i + 1) push(big_x);
                if (prev_cnt >= 0 && clip_cnt_o < prev_cnt) ok_mono = 1'b0;
                prev_cnt = clip_cnt_o;
                cnt_at_max = clip_cnt_o;
            end
            chk("D5a continuous gain: more gain => more clipping (monotonic in 1.0..12.0)", ok_mono);
            chk("D5b non-vacuous: at gain 12.0 clipping actually happened", cnt_at_max != 0);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  D6 补偿：trim=0 => 输出 0；trim 减半 => 幅值减半
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; gain_i = G_ONE; trim_i = 16'd0;
        repeat (3) @(posedge clk);
        clr_cap; push(24'sd100000);
        chk("D6a trim=0 => output is exactly 0", cap_v === 1'b1 && cap_s === 24'sd0);

        do_reset;
        en_i = 1'b1; gain_i = G_ONE; trim_i = 16'd16384;   // 0.5
        repeat (3) @(posedge clk);
        clr_cap; push(24'sd100000);
        chk("D6b trim=0.5 => output amplitude halves (100000 -> 50000)",
            cap_v === 1'b1 && cap_s === 24'sd50000);

        // ═══════════════════════════════════════════════════════════════════
        //  D7 流：一进一出，不丢不重
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; gain_i = G_ONE; trim_i = T_ONE;
        repeat (3) @(posedge clk);
        n_valid = 0;
        for (i = 0; i < 20; i = i + 1) push($signed(i * 1000));
        chk("D7a stream: exactly one valid_o per valid_i (20 in, 20 out)", n_valid == 20);

        // ═══════════════════════════════════════════════════════════════════
        //  D8 可观测性
        //     ⚠️ 同样要用【真的会削波】的增益（49152 = 12.0）
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        en_i = 1'b1; gain_i = 16'd49152; trim_i = T_ONE;
        repeat (3) @(posedge clk);
        clr_cap; push(big_x);
        chk("D8a peak_o reports the PRE-clip magnitude (saturated at FS_MAX)",
            peak_o === FS_MAX);
        chk("D8b gain_used_o / trim_used_o expose the live parameters",
            gain_used_o === 16'd49152 && trim_used_o === T_ONE);

        // ═══════════════════════════════════════════════════════════════════
        //  D9 预留档位 sel=1/2/3 的行为【确定为与 0 相同】
        // ═══════════════════════════════════════════════════════════════════
        begin : sel_blk
            integer k;
            reg ok_all;
            ok_all = 1'b1;
            for (k = 1; k <= 3; k = k + 1) begin
                do_reset;
                en_i = 1'b1; sel_i = k[1:0];
                gain_i = 16'd49152; trim_i = T_ONE;
                repeat (3) @(posedge clk);
                clr_cap; push(big_x);
                if (!(cap_v === 1'b1 && cap_s === FS_MAX)) ok_all = 1'b0;
            end
            chk("D9 reserved slots sel=1/2/3 behave as hard clip (defined, not X)", ok_all);
        end

        // ═══════════════════════════════════════════════════════════════════
        //  D10 无 X 传播
        // ═══════════════════════════════════════════════════════════════════
        chk("D10a no X on sample_o", (^sample_o) !== 1'bx);
        chk("D10b no X on valid_o",  (^valid_o)  !== 1'bx);
        chk("D10c no X on clip_cnt_o", (^clip_cnt_o) !== 1'bx);
        chk("D10d no X on peak_o", (^peak_o) !== 1'bx);

        if (errors == 0) $display("PASS: fx_dist -- bypass bit-exact, hard clip saturates, gain monotonic, trim scales");
        else $fatal(1, "FAIL: tb_fx_dist has %0d error(s)", errors);
        $finish;
    end

    initial begin #20000000; $fatal(1, "FAIL: tb_fx_dist timeout"); end

endmodule
