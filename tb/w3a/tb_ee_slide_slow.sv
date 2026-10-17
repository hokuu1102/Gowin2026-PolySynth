`timescale 1ns/1ps

// tb_ee_slide_slow.sv -- 慢速滑音（用户真实手速）判据
//
//  🔴 背景（父会话实测算术，本次已复核）：
//     TRAVEL_TARE = 744 码 / 16 键 ⇒ 每跨一个键 ≈ 46.5 码
//     帧距 500 µs ⇒ 每帧位移 = 46.5 / (跨键毫秒数 × 2)
//        100 ms/键 ⇒ 0.23 码/帧      50 ms ⇒ 0.47
//         20 ms/键 ⇒ 1.16 码/帧      10 ms ⇒ 2.3
//     ⇒ 现在 `SLIDE_DELTA_TH = 2`（A 侧必须【单帧】掉 > 2 码）
//        ⇒ 必须 **11 ms 内跨一个键**才触发 = "甩"，不是"滑" ✗
//     ⇒ 本 tb 用手速的真实量级 **150 ms 滑完一个键**（≈0.155 码/帧）⇒ 改之前必红
//
//  ⭐ 三件事：
//     ① 150 ms 滑完一个键 ⇒ **必须出滑音**
//     ② 甩（7.5 ms）⇒ 仍然出滑音（快通道没被破坏）
//     ③ 滑完停住 40 帧 ⇒ **不许再出滑音**（⛔ 否则 `slide_active_i` 常高 ⇒ 挂音）
//
//  ⭐ 非空洞保证（`C83`：判据必须"真的走到目标路径"）：
//     · 报"最大单帧降" `< 2` ⇒ 证明**没有**任何一帧能满足旧阈值（这就是"改前必红"的机理）
//     · 报"下降帧数" `> 0` ＋ 预扫后 `key_on[7]` 真的置起 ⇒ A 侧条件确实被喂到
//     · 报"触发帧号" ⇒ 一眼看出早/晚
`default_nettype none

module tb_ee_slide_slow;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;

    localparam [POS_W-1:0] P_A0 = 12'h500;   // ⭐ A 起始行程（> TRIG_TH = 12'h400）
    localparam integer     A_AX = 7;         // ⭐ A 的轴号（`nb_of(7)` = {0, 6}）
    localparam integer     B_AX = 6;         // ⭐ B = A 的同排相邻轴（`nb_of(6)` = {7}）
    localparam integer     TRAVEL = 47;      // ⭐ 一个键 ≈ 46.5 码 ⇒ 取 47

    reg clk = 1'b0;
    always #10 clk = ~clk;                   // ⭐ 50 MHz

    reg rst_n      = 1'b0;
    reg enable     = 1'b1;
    reg slide_en   = 1'b1;
    reg snap_valid = 1'b0;
    reg [AXIS_N*POS_W-1:0] pos = {AXIS_N*POS_W{1'b0}};
    reg [AXIS_N*DW-1:0]    dlt = {AXIS_N*DW{1'b0}};

    wire              evt_valid;
    wire [3:0]        evt_axis;
    wire [1:0]        evt_kind;
    wire [POS_W-1:0]  evt_depth;
    wire [AXIS_N-1:0] key_on;
    wire              slide_valid;
    wire [3:0]        slide_axis, slide_axis_b;
    wire signed [1:0] slide_dir;
    wire              two_note_valid;
    wire [3:0]        two_note_a, two_note_b;
    wire              overflow;
    wire [7:0]        lost_cnt;

    event_extract #(
        .AXIS_N(AXIS_N), .POS_W(POS_W), .DW(DW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .enable_i(enable), .slide_en_i(slide_en),
        .snap_valid_i(snap_valid),
        .pos_i(pos), .delta_i(dlt),
        .evt_valid_o(evt_valid), .evt_axis_o(evt_axis), .evt_kind_o(evt_kind),
        .evt_depth_o(evt_depth), .key_on_o(key_on),
        .slide_valid_o(slide_valid), .slide_axis_o(slide_axis), .slide_dir_o(slide_dir),
        .slide_axis_b_o(slide_axis_b),
        .two_note_valid_o(two_note_valid),
        .two_note_axis_a_o(two_note_a), .two_note_axis_b_o(two_note_b),
        .overflow_o(overflow), .lost_cnt_o(lost_cnt)
    );

    integer errors    = 0;
    integer slide_cnt = 0;
    integer first_slide_frame = -1;
    integer frame_now = 0;
    integer down_frames = 0;
    integer max_down = 0;      // ⭐ 最大单帧下降量（正数）
    integer up_frames = 0;
    integer rest_extra = 0;    // ⭐ 停住之后又多出来的滑音拍数（应为 0）
    integer d_now;

    always @(posedge clk) begin
        if (rst_n && slide_valid) begin
            slide_cnt = slide_cnt + 1;
            if (first_slide_frame < 0) first_slide_frame = frame_now;
        end
    end

    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (!cond) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end else
                $display("  ok  : %0s", name);
        end
    endtask

    task set_axis;
        input integer         ax;
        input [POS_W-1:0]     p;
        input signed [DW-1:0] d;
        begin
            pos[ax*POS_W +: POS_W] = p;
            dlt[ax*DW    +: DW]    = d;
        end
    endtask

    task clear_all;
        begin
            pos = {AXIS_N*POS_W{1'b0}};
            dlt = {AXIS_N*DW{1'b0}};
        end
    endtask

    //  ⭐ 一帧 = 一个快照脉冲 + 扫描跑完（≥16 拍）
    task snap_once;
        begin
            @(negedge clk);
            snap_valid = 1'b1;
            @(negedge clk);
            snap_valid = 1'b0;
            repeat (22) @(negedge clk);
        end
    endtask

    task reset_dut;
        begin
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            clear_all();
            slide_cnt = 0;
            first_slide_frame = -1;
            frame_now = 0;
            down_frames = 0;
            max_down = 0;
            up_frames = 0;
            rest_extra = 0;
        end
    endtask

    integer prev_a, prev_b, na, nb, kk, cnt_at_rest;

    //  ⭐ 滑音场景：从 A 滑到 B，`steps` 帧走完 `TRAVEL` 码，然后停住 40 帧
    task slide_case;
        input integer steps;
        integer k;
        begin
            reset_dut();
            //  ⭐ 预扫：让 `key_on[7]` 置起来（A 真的被按下）
            prev_a = P_A0;
            prev_b = 0;
            set_axis(A_AX, prev_a[POS_W-1:0], 13'sd0);
            set_axis(B_AX, prev_b[POS_W-1:0], 13'sd0);
            snap_once();
            repeat (4) @(negedge clk);
            if (!key_on[A_AX]) begin
                $display("FAIL: key_on[%0d] did not rise during the pre-scan", A_AX);
                errors = errors + 1;
            end
            //  ⭐ 逐帧移动
            for (k = 1; k <= steps; k = k + 1) begin
                na = P_A0 - ((TRAVEL * k) / steps);
                nb =          ((TRAVEL * k) / steps);
                d_now = na - prev_a;
                if (d_now < 0) begin
                    down_frames = down_frames + 1;
                    if (-d_now > max_down) max_down = -d_now;
                end
                if ((nb - prev_b) > 0) up_frames = up_frames + 1;
                set_axis(A_AX, na[POS_W-1:0], (na - prev_a));
                set_axis(B_AX, nb[POS_W-1:0], (nb - prev_b));
                prev_a = na;
                prev_b = nb;
                frame_now = k;
                snap_once();
            end
            //  ⭐ 停住 40 帧：⛔ 不许再出滑音（防 `slide_active_i` 常高 ⇒ 挂音）
            kk = slide_cnt;
            for (k = 0; k < 40; k = k + 1) begin
                set_axis(A_AX, prev_a[POS_W-1:0], 13'sd0);
                set_axis(B_AX, prev_b[POS_W-1:0], 13'sd0);
                snap_once();
            end
            rest_extra = slide_cnt - kk;
            $display("INFO: steps=%0d 帧 (= %0d ms) | 下降帧=%0d 最大单帧降=%0d 上升帧=%0d",
                     steps, (steps * 500) / 1000, down_frames, max_down, up_frames);
            $display("INFO: slide_cnt=%0d  首拍在 %0d 帧 (= %0d ms)  停住后新增=%0d",
                     slide_cnt, first_slide_frame, (first_slide_frame * 500) / 1000, rest_extra);
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_ee_slide_slow/tb_ee_slide_slow.vcd");
        $dumpvars(0, tb_ee_slide_slow);

        //  ═════════════════════════════════════════════════════════════
        //  ① ⭐ 用户手速：150 ms 滑完一个键（300 帧 × 500 µs）
        //
        //  ⭐ **期望值怎么来的**（⭐ `SLIDE_ACC_TH = 24` = 半个键 ⇒ 为什么首拍是 ~160 而不是 300）：
        //     · ⭐ 行程 `TRAVEL = 47` 码分 300 帧走完（`floor(47k/300)`）⇒ 300 帧里只有 **47 帧**
        //       真的动了 1 码，其余 253 帧 `d == 0`（⭐ 累积器对 `d==0` **保持**，⭐ 这正是本修法的关键）
        //     · ⭐ 累积量在第 k 帧 = `floor(47k/300)` ⇒ 达 **24**（半键）在第 `ceil(24·300/47) = 154` 帧
        //     · ⭐ 但出脉冲还要同时满足：① 判据读的是**本帧之前**的累积值（⭐ 差 1 帧）
        //        ② 慢速通道要求"**本帧确实在动**"（`d<0`）③ B 侧同一帧也要 `acc_b>=24 && d>0`
        //        ⇒ ⭐ 第一个"三条件同时成立"的**步进帧** = **第 160 帧 = 80 ms**（= 150 ms/2 − 少量量化）
        //     · ⭐ 拍数 23 = 第 160 帧之后到滑完（第 300 帧）之间的**步进帧数**（≈22）+ 交叉那一拍
        //     📌 这条判据要守的是"**滑到一半就出声**"，⛔ 不是"最后一刻才反应"
        //        ⇒ 所以我们卡 `first_slide_frame <= 55% × 300`（=165）✅
        //  ═════════════════════════════════════════════════════════════
        $display("== 1: 150 ms 滑完一个键（手速真实量级）==");
        slide_case(300);
        chk((max_down > 0) && (max_down < 2),
            "per-frame delta never reaches the old fast threshold (<2) => the old rule CANNOT fire");
        chk(down_frames > 0, "the slide really produced decreasing frames");
        chk(slide_cnt > 0, "SLOW SLIDE (150 ms per key) fires slide_valid");
        //  ⭐ `SLIDE_ACC_TH` 默认 = 24 = **半个键** ⇒ 滑到 ~150 ms/2 ≈ 75 ms 就该出声
        //     ⇒ ⭐ 触发帧号必须**明显小于**滑完的帧数（⛔ 不是"最后一刻才反应"）
        chk((first_slide_frame > 0) && (first_slide_frame <= (300 * 55) / 100),
            "half-key threshold => fires MID-slide (<=55% of the 150 ms), not at the very end");
        chk(rest_extra == 0, "no extra slide pulses after the finger stops (no hang/note_off suppression)");

        //  ═════════════════════════════════════════════════════════════
        //  ② 甩（7.5 ms = 15 帧）⇒ 快通道仍然工作
        //  ═════════════════════════════════════════════════════════════
        $display("== 2: 7.5 ms 甩一个键（快通道）==");
        slide_case(15);
        chk(slide_cnt > 0, "FAST slide (7.5 ms per key) still fires slide_valid");

        if (errors == 0)
            $display("PASS: slow (150 ms/key) and fast (7.5 ms/key) slides both fire, and a resting finger is silent");
        else
            $fatal(1, "FAIL: tb_ee_slide_slow has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "FAIL: tb_ee_slide_slow timeout");
    end
endmodule

`default_nettype wire
