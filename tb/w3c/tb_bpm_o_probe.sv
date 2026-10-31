`timescale 1ns/1ps
// 临时点测：bpm_o 反算除法器（正式判据进 tb_play_seq 前的快速数学验证）
module tb_bpm_o_probe;
    reg clk = 0, rst_n = 0;
    reg tick_i = 0, run_i = 1, pos_reset_i = 0;
    reg [19:0] lead_i = 0;
    wire lead_sel_i = 0;
    reg bpm_up_i = 0, bpm_dn_i = 0, bpm_load_i = 0;
    reg [15:0] bpm_i = 0;
    wire [31:0] tick_inc_o;
    wire [7:0] bpm_o;
    reg evt_valid_i = 0;
    reg [63:0] evt_data_i = 0;
    wire evt_rd_o, note_valid_o;
    wire [63:0] note_data_o;
    wire tempo_applied_o, evt_underrun_o;
    wire [15:0] evt_cnt_o, tempo_cnt_o;
    wire [19:0] cur_tick_o;

    play_seq u_dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .tick_i(tick_i), .run_i(run_i), .pos_reset_i(pos_reset_i),
        .lead_i(lead_i), .lead_sel_i(lead_sel_i),
        .bpm_up_i(bpm_up_i), .bpm_dn_i(bpm_dn_i),
        .bpm_load_i(bpm_load_i), .bpm_i(bpm_i),
        .tick_inc_o(tick_inc_o), .bpm_o(bpm_o),
        .evt_valid_i(evt_valid_i), .evt_data_i(evt_data_i), .evt_rd_o(evt_rd_o),
        .note_valid_o(note_valid_o), .note_data_o(note_data_o),
        .tempo_applied_o(tempo_applied_o), .evt_underrun_o(evt_underrun_o),
        .evt_cnt_o(evt_cnt_o), .tempo_cnt_o(tempo_cnt_o), .cur_tick_o(cur_tick_o)
    );

    always #10 clk = ~clk;
    integer errors = 0;

    task check(input [7:0] got, input [7:0] exp, input [127:0] name);
        if (got !== exp) begin
            $display("  FAIL: %0s: bpm_o=%0d exp=%0d", name, got, exp);
            errors = errors + 1;
        end else
            $display("  ok  : %0s: bpm_o=%0d", name, got);
    endtask

    // 发一条 kind=2 tempo 事件（tick=0）—— ⭐ 打包与 tb_play_seq 的 mk_event 逐位一致
    task send_tempo(input [31:0] inc);
        begin
            @(negedge clk);
            evt_data_i  = {20'd0, inc[20:0], 4'd0, 8'd100, 2'd2, 2'd0, 7'd0};
            evt_valid_i = 1;
            @(negedge clk);
            evt_valid_i = 0;
            // 等 25 拍让除法器（20 拍 + 启动/完成拍）跑完
            repeat (30) @(negedge clk);
        end
    endtask

    // ⚠️ Verilog-2001 task 按值传参 ⇒ 必须直接驱动外部 reg（⛔ 不能 input 传句柄）
    task pulse_up;  begin @(negedge clk) bpm_up_i  = 1; @(negedge clk) bpm_up_i  = 0; end endtask
    task pulse_dn;  begin @(negedge clk) bpm_dn_i  = 1; @(negedge clk) bpm_dn_i  = 0; end endtask
    task pulse_load;begin @(negedge clk) bpm_load_i= 1; @(negedge clk) bpm_load_i= 0; end endtask

    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        repeat (3) @(negedge clk);
        check(bpm_o, 8'd120, "reset = 120");

        // 60 BPM: 60*1374+47 = 82487
        send_tempo(32'd82487);   check(bpm_o, 8'd60, "tempo evt 60 BPM");
        // 200 BPM: 200*1374+47 = 274847
        send_tempo(32'd274847);  check(bpm_o, 8'd200, "tempo evt 200 BPM");
        // 40 BPM 边界
        send_tempo(32'd55007);   check(bpm_o, 8'd40, "tempo evt 40 BPM (INC_MIN)");
        // 240 BPM 边界
        send_tempo(32'd329807);  check(bpm_o, 8'd240, "tempo evt 240 BPM (INC_MAX)");
        // 非整格点：143*1374+47 = 196529
        send_tempo(32'd196529);  check(bpm_o, 8'd143, "tempo evt 143 BPM (off-grid)");
        // 非整格点向下取整：199*1374+47+1373 = 274846 (不到 200)
        send_tempo(32'd274846);  check(bpm_o, 8'd199, "tempo evt truncates down");
        // evt_inc < 47 → 0
        send_tempo(32'd30);      check(bpm_o, 8'd0, "evt_inc<47 -> 0");
        // 溢出 x>=2^20 → 255
        send_tempo(32'h100040);  check(bpm_o, 8'd255, "x>=2^20 -> saturate 255");
        send_tempo(32'd412247); // 300 BPM, displayed as 255
        pulse_up;
        check(bpm_o, 8'd240, "up from >255 BPM follows actual 240 clamp");
        send_tempo(32'd412247); pulse_dn;
        check(bpm_o, 8'd255, "down above display range stays saturated");
        send_tempo(32'd350417); pulse_dn;
        check(bpm_o, 8'd254, "down from exactly 255 BPM is 254");
        send_tempo(32'd30); pulse_up;
        check(bpm_o, 8'd0, "up after sub-offset tempo follows tick increment");
        send_tempo(32'd30); pulse_dn;
        check(bpm_o, 8'd255, "readback reflects existing unsigned increment behavior");
        // 恢复：装载 90
        @(negedge clk); bpm_i = 16'd90; pulse_load;
        check(bpm_o, 8'd90, "bpm_load 90");
        check(tick_inc_o[7:0], 8'd59, "bpm_load 90 tick_inc[7:0]=123707&0xFF");
        // up 到 240 上限
        repeat (200) pulse_up;
        check(bpm_o, 8'd240, "up x200 clamps at 240");
        // dn 到 40 下限
        repeat (250) pulse_dn;
        check(bpm_o, 8'd40, "dn x250 clamps at 40");
        // 手动杀除法：启动除法后立刻 load
        @(negedge clk);
        evt_data_i  = {20'd0, 21'd82487, 4'd0, 8'd100, 2'd2, 2'd0, 7'd0};
        evt_valid_i = 1;
        @(negedge clk);
        evt_valid_i = 0; bpm_i = 16'd150; bpm_load_i = 1;
        @(negedge clk); bpm_load_i = 0;
        repeat (30) @(negedge clk);
        check(bpm_o, 8'd150, "manual kills divider (60BPM evt then load 150)");

        if (errors == 0) $display("PASS: bpm_o probe all ok");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
