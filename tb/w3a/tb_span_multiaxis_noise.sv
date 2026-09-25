// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_multiaxis_noise —— ⭐ 多轴连续标定 + ⭐【逐通道帧间噪声】
//
//  ═══════════════════════════════════════════════════════════════════════════
//  🔴 为什么要写这一支（⭐ 我前面的 tb 有一个【根本性失真】）
//  ═══════════════════════════════════════════════════════════════════════════
//  ⭐ 上板现象（⭐ 用户实测 2026-09-25）：
//        `Ts0.1.2!2!2!2!2!2!2!2!2s!sssssssss`
//        ⇒ ⭐ **轴 0 通过（`.`）· 轴 1 通过（`.`）· 🔴 轴 2 反复被拒（`!`）**
//
//  🔴 **我前面所有 tb 的失真**：
//     ⭐ `mcp3208_model` 的返回值是 `IDVAL + ch` ⇒ ⭐ **一个【恒定值】，零噪声**
//     ⇒ ⚠️ 所以我的 tb 里"轴 2"从来不会失败 ⇒ 🔴 **测不出上板那个现象**
//
//  ⭐⭐ 本 tb 补上这个缺失的变量：⭐ **给每个通道加【独立的帧间噪声】**
//     · ⭐ 噪声幅度 **可参数化**（⭐ 用不同实例扫不同幅度）
//     · ⭐ 与上板一致：⭐ 噪声是**逐帧随机**的（⛔ 不是缓慢漂移）
//
//  ⭐ 本 tb 要回答的问题：
//     🔴 **多大的逐通道噪声，会让"某一轴"开始反复被拒？**
//     · 若阈值 ≈ `STABLE_TOL`(48) ⇒ ✅ 逻辑正确 ⇒ ⭐ 上板噪声就是超了 48
//     · 🔴 若噪声远小于 48 也被拒 ⇒ 🔴 **逻辑有 bug** ⇒ ⭐ 我直接开始修
//
//  ⚠️ 参数与上板保持一致（⭐ 见 `K-129`，⛔ 不缩短超时）
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_multiaxis_noise;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  start_i = 0, abort_i = 0;
    reg  sample_valid_i = 0;
    reg  [2:0]  sample_ch_i = 0;
    reg  [11:0] raw_i = 0;
    wire [N_ADC-1:0] span_o;
    wire [2:0]  cal_ch_o;
    reg  cal_busy_i = 0, cal_err_i = 0;
    wire busy_o, done_o, reject_o, need_press_o;
    wire [3:0]  cur_axis_o, done_cnt_o, rej_cnt_o;
    wire [2:0]  state_o;

    integer spans = 0, rejects = 0;
    reg [3:0] axis_of_reject = 4'hF;
    always @(posedge clk) begin
        if (reject_o) begin
            rejects = rejects + 1;
            axis_of_reject = cur_axis_o;
        end
        if (|span_o) spans = spans + 1;
    end

    calib_span #(
        .NCH(NCH), .N_ADC(N_ADC), .AXIS_TOTAL(AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED), .VOTE_N(VOTE_N),
        // ⚠️ 用【真值比例】：帧 320 拍 ⇒ 超时 320*2000 = 640000（⭐ 与上板同比例）
        .WAIT_TIMEOUT_CLK(320 * 2000),
        .STABLE_TOL(STABLE_TOL), .VOTE_TOL(VOTE_TOL),
        .REJECT_MAX(REJECT_MAX), .POS_W(12)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_i(start_i), .abort_i(abort_i),
        .sample_valid_i(sample_valid_i), .sample_ch_i(sample_ch_i), .raw_i(raw_i),
        .span_o(span_o), .cal_ch_o(cal_ch_o),
        .cal_busy_i(cal_busy_i), .cal_err_i(cal_err_i),
        .busy_o(busy_o), .done_o(done_o),
        .reject_o(reject_o), .need_press_o(need_press_o),
        .cur_axis_o(cur_axis_o), .done_cnt_o(done_cnt_o), .rej_cnt_o(rej_cnt_o),
        .state_o(state_o)
    );

    always @(posedge clk) begin
        if (rst_n && (|span_o)) cal_busy_i <= 1'b1;
        else if (cal_busy_i)     cal_busy_i <= 1'b0;
    end

    // ⭐⭐ 逐通道基值（⭐ 用上板实测的松手值）
    function [11:0] chbase;
        input [2:0] c;
        begin
            case (c)
                3'd0: chbase = 12'd2164;
                3'd1: chbase = 12'd2193;
                3'd2: chbase = 12'd2184;   // ⭐ 上板被拒的那一轴
                3'd3: chbase = 12'd2180;
                3'd4: chbase = 12'd2144;
                3'd5: chbase = 12'd2139;
                3'd6: chbase = 12'd2180;
                default: chbase = 12'd2171;
            endcase
        end
    endfunction

    // ⭐⭐ 噪声幅度（⭐ 由场景设置）
    integer noise_amp = 0;
    integer lfsr = 32'h12345678;
    function integer rnd_mod;                  // ⭐ 0..m-1
        input integer m;
        begin
            lfsr = (lfsr << 1) ^ (lfsr[31] ? 32'h04C11DB7 : 32'h0);
            rnd_mod = (lfsr & 32'h7FFFFFFF) % m;
        end
    endfunction

    localparam integer FRAME = 40;
    reg [2:0] sweep_ch = 0;
    integer dev = 0;

    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            // ⭐ 基值 + 逐帧随机噪声（⭐ 范围 -amp..+amp）
            if (noise_amp > 0)
                dev = rnd_mod(2*noise_amp + 1) - noise_amp;
            else
                dev = 0;
            raw_i = chbase(sweep_ch) + dev[11:0];
            sample_valid_i = 1'b1;
            @(negedge clk);
            sample_valid_i = 1'b0;
            sweep_ch = sweep_ch + 3'd1;
        end
    end

    task run_scene(input integer amp, output integer o_spans, output integer o_rej,
                   output integer o_axis);
        begin
            noise_amp = amp;
            spans = 0; rejects = 0; axis_of_reject = 4'hF;
            rst_n = 0; start_i = 0;
            repeat (5) @(negedge clk);
            rst_n = 1;
            repeat (5) @(negedge clk);
            @(negedge clk); start_i = 1;
            @(negedge clk); start_i = 0;
            // ⭐ 跑足够标定 16 轴（⭐ 每轴 ~8ms @ 帧 320 拍）
            repeat (FRAME * 8 * 3000) @(negedge clk);
            o_spans = spans; o_rej = rejects; o_axis = axis_of_reject;
        end
    endtask

    integer s0, r0, a0;
    integer i;
    integer amps [0:5];
    integer ns [0:5];
    integer rs [0:5];
    integer as [0:5];
    integer fails = 0;

    initial begin
        $display("=== tb_span_multiaxis_noise ===");
        $display("⭐ 多轴连续标定 + 【逐通道帧间噪声】（⭐ 我前面 tb 缺失的变量）");
        $display("⭐ STABLE_TOL=%0d VOTE_TOL=%0d STABLE_NEED=%0d VOTE_N=%0d",
                 STABLE_TOL, VOTE_TOL, STABLE_NEED, VOTE_N);
        $display("⭐ 通道基值 = 上板实测松手值（ch2=2184 就是被拒那轴）");
        $display("");

        // ⭐ 扫噪声幅度
        amps[0] = 0;   amps[1] = 10;  amps[2] = 20;
        amps[3] = 40;  amps[4] = 48;  amps[5] = 60;

        for (i = 0; i < 6; i = i + 1) begin
            run_scene(amps[i], s0, r0, a0);
            ns[i] = s0; rs[i] = r0; as[i] = a0;
            $display("  噪声 ±%-3d  ⇒  span=%-3d  reject=%-3d  最后被拒轴=%0d %s",
                     amps[i], s0, r0, a0,
                     (a0 == 4'hF) ? "(无)" : "");
        end

        $display("--------------------------------------------------");
        $display("⭐ 解读：");
        $display("  · 噪声 < STABLE_TOL(%0d) ⇒ 应当【全部 16 轴通过】(reject=0)", STABLE_TOL);
        $display("  · 噪声 > STABLE_TOL(%0d) ⇒ 稳定判定过不去 ⇒ 拒绝是【正确行为】", STABLE_TOL);
        $display("--------------------------------------------------");

        // ⭐ 判据：噪声小于 STABLE_TOL 时不应有拒绝
        for (i = 0; i < 6; i = i + 1) begin
            if (amps[i] < STABLE_TOL) begin
                if (rs[i] == 0 && ns[i] == AXIS_TOTAL)
                    $display("  ok  : 噪声 ±%-3d (< %0d) ⇒ 16 轴全过, 无拒绝", amps[i], STABLE_TOL);
                else begin
                    $display("  FAIL: 噪声 ±%-3d (< %0d) 却 span=%0d reject=%0d  ⇒ 🔴 逻辑有问题",
                             amps[i], STABLE_TOL, ns[i], rs[i]);
                    fails = fails + 1;
                end
            end
        end

        $display("==================================================");
        if (fails == 0) $display("PASS: 稳定判定阈值行为正确（噪声 < TOL 就能过）");
        else            $display("FAIL: %0d 项不达标 ⇒ 🔴 逻辑缺陷", fails);
        $finish;
    end

    initial begin
        #2000000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
