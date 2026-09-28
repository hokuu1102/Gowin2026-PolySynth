// ===========================================================================
//  tb_ee_adj.sv -- event_extract FIFO 水位诊断（相邻轴同帧越阈）
//
//  目的：⭐ 逐拍观察 `q_cnt`/`q_wr`/`q_rd`/`scan_axis`，定位"3 个轴只出 2 条事件"
//        的真正原因（2026-09-28）。
//
//  ⭐ 背景（已实测）：原始代码下，相邻轴 (1,2,3) 同帧越阈 ⇒ **丢事件**；
//     间隔轴 (1,5,9) ⇒ 正常。⇒ 现有验收 tb 因轴距=4 而恰好避开（假守护）。
// ===========================================================================
`timescale 1ns/1ps

module tb_ee_adj;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = 13;
    localparam integer AXIS_W = 4;

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;              // 50 MHz

    reg                     enable = 1;
    reg                     snap = 0;
    reg  [AXIS_N*POS_W-1:0] pos = 0;
    reg  [AXIS_N*DW-1:0]    delta = 0;

    wire                    evt_valid;
    wire [AXIS_W-1:0]       evt_axis;
    wire [1:0]              evt_kind;
    wire [POS_W-1:0]        evt_depth;
    wire                    overflow;
    wire [7:0]              lost_cnt;

    event_extract #(
        .AXIS_N    (AXIS_N),
        .POS_W     (POS_W),
        .DW        (DW),
        .AXIS_W    (AXIS_W),
        .TRIG_TH   (12'h400),
        .REL_TH    (12'h300),
        .REFRACT_N (4)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable_i     (enable),
        .snap_valid_i (snap),
        .pos_i        (pos),
        .delta_i      (delta),
        .evt_valid_o  (evt_valid),
        .evt_axis_o   (evt_axis),
        .evt_kind_o   (evt_kind),
        .evt_depth_o  (evt_depth),
        .slide_valid_o(),
        .slide_axis_o (),
        .slide_dir_o  (),
        .two_note_valid_o(),
        .two_note_axis_a_o(),
        .two_note_axis_b_o(),
        .overflow_o   (overflow),
        .lost_cnt_o   (lost_cnt)
    );

    integer cctr = 0;
    always @(posedge clk) cctr = cctr + 1;

    //  ⭐ 事件记录
    integer n_ev = 0;
    reg [3:0] ev_ax [0:15];
    reg [1:0] ev_kd [0:15];
    always @(posedge clk) begin
        if (rst_n && evt_valid) begin
            ev_ax[n_ev] = evt_axis;
            ev_kd[n_ev] = evt_kind;
            n_ev = n_ev + 1;
        end
    end

    //  ⭐ 逐拍监视
    reg mon = 0;
    always @(posedge clk) begin
        if (rst_n && mon)
            $display("    c=%0d scan=%0d scanng=%0d qcnt=%0d qwr=%0d qrd=%0d | ev=%0d ax=%0d kd=%0d",
                     cctr, dut.scan_axis, dut.scanning, dut.q_cnt, dut.q_wr, dut.q_rd,
                     evt_valid, evt_axis, evt_kind);
    end

    task set_axis;
        input integer a;
        input [11:0] v;
        begin
            pos[a*POS_W +: POS_W] = v;
        end
    endtask

    task do_snap;
        begin
            @(negedge clk);
            snap = 1;
            @(negedge clk);
            snap = 0;
        end
    endtask

    integer i;
    initial begin
        $display("");
        $display("==============================================================");
        $display(" event_extract FIFO watermark: ADJACENT axes (1,2,3) same frame");
        $display("==============================================================");
        repeat (10) @(negedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        //  先让所有轴回释放态
        for (i = 0; i < AXIS_N; i = i + 1) set_axis(i, 12'h000);
        do_snap();
        repeat (60) @(negedge clk);
        n_ev = 0;

        //  ⭐ 相邻三轴同帧越阈
        set_axis(1, 12'h500);
        set_axis(2, 12'h600);
        set_axis(3, 12'h700);
        mon = 1;
        do_snap();
        repeat (24) @(negedge clk);
        mon = 0;
        repeat (40) @(negedge clk);

        $display("");
        $display("  == RESULT ==");
        $display("   events emitted = %0d   (expected 3)", n_ev);
        for (i = 0; i < n_ev; i = i + 1)
            $display("     ev[%0d] axis=%0d kind=%0d %s", i, ev_ax[i], ev_kd[i],
                     (ev_kd[i] == 2'd0) ? "(note_on)" : "(note_off)");
        $display("   overflow=%0d lost_cnt=%0d", overflow, lost_cnt);
        if (n_ev == 3) $display("   ✅ PASS: all three adjacent axes emitted");
        else           $display("   🔴 FAIL: %0d of 3 events lost/delayed", 3 - n_ev);
        $display("==============================================================");
        $finish;
    end

endmodule
