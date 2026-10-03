`timescale 1ns/1ps
// tb_top_test_mode_pipe.sv
//
// ⭐ 2026-10-03（codex 只读诊断「路线一①」的**前置验证**）
//
// 目的：证明 `rtl/top.v` 里把 ADSR 的 gate/velocity/retrig 选择
//   · 旧：`tm_enable_r ? {tm_gate,tm_vel,0} : {nm_gate,nm_vel,nm_retrig}`（全局组合）
//   · 新：每声部本地预译码 `tm_local_test_r[v]`（与权威状态**同沿**写入下一状态）
// **逐系统时钟沿**完全等价。
//
// ⛔ 不能只在 sample_tick 比较；⛔ 不能靠"velocity 整条音符不变"论证。
// ✅ 覆盖：全部模式转换（关→4→8→16→32→关）、UART/UI 单独与同时请求、连续请求、
//    reset 在各状态下断言/释放、请求与 tick 同拍/前一拍/后一拍、力度随机变化。
// ✅ 红检：把本地预译码故意改成"晚一拍"必须被抓到（自检本 tb 有效）。

module tb_top_test_mode_pipe;
    localparam integer POLY = 32;
    localparam integer VW   = 8;

    reg clk = 1'b0;
    reg rst_n_sync = 1'b0;
    reg cmd_req = 1'b0;          // 串口 'M'（单拍脉冲）
    reg ui_req  = 1'b0;          // 串口屏触摸（单拍脉冲）
    reg tick_audio = 1'b0;       // 每 1024 拍一个 sample tick
    always #10 clk = ~clk;

    // ── 普通通路（被选择的对象）────────────────────────────────────────────
    reg [POLY-1:0]      nm_gate;
    reg [POLY*VW-1:0]   nm_vel;
    reg [POLY-1:0]      nm_retrig;
    integer i;
    integer seed = 32'h1234_5678;

    // ── 旧：权威状态 + 全局组合选择（= 改动前的行为）───────────────────────
    reg        tm_enable_r;
    reg [1:0]  tm_n_code_r;
    wire [5:0] cnt_r = tm_enable_r ? (6'd4 << tm_n_code_r) : 6'd0;

    // ── 新：下一状态 + 每声部本地预译码（= rtl/top.v 的新实现）──────────────
    wire tm_advance    = cmd_req || ui_req;
    wire tm_enable_next = !rst_n_sync ? 1'b0 :
                          !tm_advance ? tm_enable_r :
                          !tm_enable_r ? 1'b1 :
                          (tm_n_code_r == 2'b11) ? 1'b0 : 1'b1;
    wire [1:0] tm_n_code_next = !rst_n_sync ? 2'b00 :
                          !tm_advance ? tm_n_code_r :
                          !tm_enable_r ? 2'b00 :
                          (tm_n_code_r == 2'b11) ? 2'b00 : (tm_n_code_r + 2'b01);
    wire [5:0] tm_count_next = !tm_enable_next ? 6'd0 : (6'd4 << tm_n_code_next);

    reg [1:0] tm_sel_r   [0:POLY-1];   // 0=普通 / 1=测试声部 / 2=测试模式但非测试声部
    reg [1:0] tm_sel_red [0:POLY-1];   // 红检：用【当前】状态而非下一状态（应差一拍）
    integer v;

    always @(posedge clk) begin
        if (!rst_n_sync) begin
            tm_enable_r <= 1'b0;
            tm_n_code_r <= 2'b00;
        end else if (tm_advance) begin
            if (!tm_enable_r) begin
                tm_enable_r <= 1'b1;
                tm_n_code_r <= 2'b00;
            end else if (tm_n_code_r == 2'b11) begin
                tm_enable_r <= 1'b0;
                tm_n_code_r <= 2'b00;
            end else begin
                tm_n_code_r <= tm_n_code_r + 2'b01;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n_sync) begin
            for (v = 0; v < POLY; v = v + 1) begin
                tm_sel_r[v]   <= 2'd0;
                tm_sel_red[v] <= 2'd0;
            end
        end else begin
            // 新版：从**下一状态**分类（与权威状态同沿写入 ⇒ 沿后完全同步）
            for (v = 0; v < POLY; v = v + 1)
                tm_sel_r[v] <= !tm_enable_next ? 2'd0 : ((v < tm_count_next) ? 2'd1 : 2'd2);
            // 红检：从**当前**状态分类 ⇒ 应当与旧版差一拍
            for (v = 0; v < POLY; v = v + 1)
                tm_sel_red[v] <= !tm_enable_r ? 2'd0 : ((v < cnt_r) ? 2'd1 : 2'd2);
        end
    end

    // ── 三种"选择结果"的逐位表达 ───────────────────────────────────────────
    // 旧（= 改动前 top.v 的表达式，逐位展开）
    wire [POLY-1:0]    old_sel_gate;
    wire [POLY*VW-1:0] old_sel_vel;
    wire [POLY-1:0]    old_sel_retrig;
    genvar g;
    generate for (g = 0; g < POLY; g = g + 1) begin : g_old
        assign old_sel_gate[g] = tm_enable_r ? (g < cnt_r) : nm_gate[g];
        assign old_sel_vel[g*VW +: VW] = tm_enable_r
            ? ((g < cnt_r) ? {VW{1'b1}} : {VW{1'b0}})
            : nm_vel[g*VW +: VW];
        assign old_sel_retrig[g] = tm_enable_r ? 1'b0 : nm_retrig[g];
    end endgenerate

    // 新（= 改动后）
    wire [POLY-1:0]    new_sel_gate;
    wire [POLY*VW-1:0] new_sel_vel;
    wire [POLY-1:0]    new_sel_retrig;
    generate for (g = 0; g < POLY; g = g + 1) begin : g_new
        assign new_sel_gate[g] = (tm_sel_r[g] == 2'd1) ? 1'b1
                               : (tm_sel_r[g] == 2'd2) ? 1'b0
                               : nm_gate[g];
        assign new_sel_vel[g*VW +: VW] = (tm_sel_r[g] == 2'd1) ? {VW{1'b1}}
                                       : (tm_sel_r[g] == 2'd2) ? {VW{1'b0}}
                                       : nm_vel[g*VW +: VW];
        assign new_sel_retrig[g] = (tm_sel_r[g] == 2'd0) ? nm_retrig[g] : 1'b0;
    end endgenerate

    // 红检（从当前状态分类的版本）
    wire [POLY-1:0]    red_sel_gate;
    generate for (g = 0; g < POLY; g = g + 1) begin : g_red
        assign red_sel_gate[g] = (tm_sel_red[g] == 2'd1) ? 1'b1
                               : (tm_sel_red[g] == 2'd2) ? 1'b0
                               : nm_gate[g];
    end endgenerate

    // ── 逐沿比较 ───────────────────────────────────────────────────────────
    integer checks = 0;
    integer mism    = 0;
    integer red_mism = 0;
    integer ticks   = 0;

    always @(posedge clk) begin
        #1;   // 采样稳定后的值
        if (rst_n_sync) begin
            checks = checks + 1;
            if ((new_sel_gate !== old_sel_gate) ||
                (new_sel_vel  !== old_sel_vel)  ||
                (new_sel_retrig !== old_sel_retrig)) begin
                mism = mism + 1;
                if (mism <= 5)
                    $display("  FAIL t=%0t gate %08h/%08h vel %064h/%064h retrig %08h/%08h",
                        $time, new_sel_gate, old_sel_gate, new_sel_vel, old_sel_vel,
                        new_sel_retrig, old_sel_retrig);
            end
            if (red_sel_gate !== old_sel_gate) red_mism = red_mism + 1;
        end
    end

    // ── 激励 ───────────────────────────────────────────────────────────────
    task pulse_cmd;  begin @(negedge clk); cmd_req = 1'b1; @(negedge clk); cmd_req = 1'b0; end endtask
    task pulse_ui;   begin @(negedge clk); ui_req  = 1'b1; @(negedge clk); ui_req  = 1'b0; end endtask
    task both;       begin @(negedge clk); cmd_req = 1'b1; ui_req = 1'b1;
                           @(negedge clk); cmd_req = 1'b0; ui_req = 1'b0; end endtask

    initial begin
        nm_gate = {POLY{1'b0}}; nm_vel = {(POLY*VW){1'b0}}; nm_retrig = {POLY{1'b0}};
        repeat (4) @(negedge clk);
        rst_n_sync = 1'b1;

        // ① 完整模式循环 关→4→8→16→32→关，走两圈
        for (i = 0; i < 12; i = i + 1) begin
            @(negedge clk);
            nm_gate   = $random(seed);
            nm_vel    = $random(seed);
            nm_retrig = $random(seed);
            pulse_cmd;
            repeat (3) @(negedge clk);
        end

        // ② UI 单独入口
        for (i = 0; i < 6; i = i + 1) begin pulse_ui; repeat (2) @(negedge clk); end

        // ③ 同时请求（应当只推进一次）
        for (i = 0; i < 6; i = i + 1) begin both; repeat (2) @(negedge clk); end

        // ④ 连续请求（背靠背脉冲）
        for (i = 0; i < 10; i = i + 1) begin pulse_cmd; end

        // ⑤ 请求与 sample_tick 同拍 / 前一拍 / 后一拍
        for (i = 0; i < 6; i = i + 1) begin
            tick_audio = 1'b1; @(negedge clk); tick_audio = 1'b0;
            pulse_cmd;
            @(negedge clk); tick_audio = 1'b1; @(negedge clk); tick_audio = 1'b0;
            pulse_cmd;
        end

        // ⑥ reset 在各状态下断言/释放
        for (i = 0; i < 6; i = i + 1) begin
            pulse_cmd; repeat (2) @(negedge clk);
            rst_n_sync = 1'b0; repeat (3) @(negedge clk);
            rst_n_sync = 1'b1; repeat (2) @(negedge clk);
        end

        // ⑦ 收尾：长随机段（数千拍，力度/gate/retrig 每拍随机 + 随机请求）
        for (i = 0; i < 6000; i = i + 1) begin
            @(negedge clk);
            nm_vel = $random(seed);
            nm_gate = $random(seed);
            nm_retrig = $random(seed);
            if ((i % 7) == 0) cmd_req = 1'b1; else cmd_req = 1'b0;
            if ((i % 11) == 0) ui_req = 1'b1; else ui_req = 1'b0;
            if ((i % 1024) == 0) begin tick_audio = 1'b1; @(negedge clk); tick_audio = 1'b0; end
            if ((i % 997) == 0) begin rst_n_sync = 1'b0; @(negedge clk); @(negedge clk); rst_n_sync = 1'b1; end
        end
        repeat (5) @(negedge clk);

        $display("  checks=%0d  new-vs-old mismatches=%0d  red(one-cycle-late) mismatches=%0d",
                 checks, mism, red_mism);
        if (mism != 0)      $fatal(1, "FAIL: new per-voice pre-decode is NOT cycle-equivalent");
        if (red_mism == 0)  $fatal(1, "FAIL: the red (one-cycle-late) variant was NOT detected -- test is blind");
        $display("PASS: tb_top_test_mode_pipe %0d per-clock comparisons, 0 mismatches; red variant detected in %0d clocks",
                 checks, red_mism);
        $finish;
    end

    initial begin #2000000; $fatal(1, "FAIL: watchdog"); end
endmodule
