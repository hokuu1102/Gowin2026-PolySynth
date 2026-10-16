// tb_ee_multileave.sv · 【同帧多个轴一起离开】时 A 的取法（⭐ 2026-10-16 新增）
//
//   🔴 **为什么必须有这条 tb**（本文件存在的唯一理由）：
//      现有 `tb_event_extract_slide.sv` 的四个场景**每次 `do_snap()` 最多只驱动一个负 delta 轴**
//      （见其 `:165` / `:184-185` / `:199-200` / `:214-215`）⇒ ⭐ **"同帧 ≥2 个轴在离开"这条路径
//      从未被测过** ⇒ 典型 `C83` 假绿 ✅
//
//   🔴 **它抓的缺陷**（2026-10-16 实测，代码为地面真相）：
//      `rtl/w3a/event_extract.v:628-630` 的循环**丢了 `!left_hit` 短路**：
//         ```
//         left_ax_n = {AXIS_W{1'b0}};
//         for (si = 0; si < AXIS_N; si = si + 1)
//             if (left_cand[si]) left_ax_n = si;      // ⭐ 每个命中都覆盖 ⇒ 取【最大】轴号
//         ```
//      而 HEAD（`af9f2cdb`）是 `if (!left_hit && ...) { left_hit=1; left_ax_n=si; }`
//      ⇒ ⭐ 取**第一个**命中 = **最小**轴号。
//      而 `event_extract.v:328` 的注释明写"`left_ax_n` 仍取**最小**轴号"、
//      `:373-377` 的"逐位等价"论证也建立在这个前提上 ⇒ 🔴 **注释与代码相反**。
//
//   ⚠️ **本 tb 在修复前【必红】**（⭐ 这是**有意的** —— 证明判据非空洞，同族 `lampkill-20261016`）：
//      · 场景① 断言 `slide_axis_o == 3`（最小轴号）⇒ 现状取 5 ⇒ **红** ✅
//      · 场景② 断言"必须出滑音"        ⇒ 现状 A 取 6 ⇒ 邻居里没有上升轴 ⇒ **不出滑音** ⇒ **红** ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz
//   ⚠️ 本文件必须【无 BOM】（`tools/check_no_bom.ps1`）

`timescale 1ns/1ps

module tb_ee_multileave;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;

    //  ⭐ 与 RTL 默认值一致（`event_extract.v:56/62/82/90`）
    localparam [POS_W-1:0] TRIG_TH       = 12'h400;
    localparam signed [DW-1:0] DELTA_TH  = 13'sd8;
    localparam [POS_W-1:0] SLIDE_START_TH = 12'h004;

    reg clk = 1'b0;
    always #10 clk = ~clk;                      // ⭐ 50 MHz

    reg rst_n     = 1'b0;
    reg enable    = 1'b0;
    reg slide_en  = 1'b1;
    reg snap_valid = 1'b0;
    reg [AXIS_N*POS_W-1:0] pos = {AXIS_N*POS_W{1'b0}};
    reg [AXIS_N*DW-1:0]    dlt = {AXIS_N*DW{1'b0}};

    wire                 evt_valid;
    wire [3:0]           evt_axis;
    wire [1:0]           evt_kind;
    wire [POS_W-1:0]     evt_depth;
    wire [AXIS_N-1:0]    key_on;
    wire                 slide_valid;
    wire [3:0]           slide_axis;
    wire signed [1:0]    slide_dir;
    wire [3:0]           slide_axis_b;
    wire                 two_note_valid;
    wire [3:0]           two_note_a, two_note_b;
    wire                 overflow;
    wire [7:0]           lost_cnt;

    event_extract #(
        .AXIS_N(AXIS_N), .POS_W(POS_W), .DW(DW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .enable_i(enable),
        .slide_en_i(slide_en),
        .snap_valid_i(snap_valid),
        .pos_i(pos), .delta_i(dlt),
        .evt_valid_o(evt_valid), .evt_axis_o(evt_axis),
        .evt_kind_o(evt_kind), .evt_depth_o(evt_depth),
        .key_on_o(key_on),
        .slide_valid_o(slide_valid), .slide_axis_o(slide_axis), .slide_dir_o(slide_dir),
        .slide_axis_b_o(slide_axis_b),
        .two_note_valid_o(two_note_valid),
        .two_note_axis_a_o(two_note_a), .two_note_axis_b_o(two_note_b),
        .overflow_o(overflow), .lost_cnt_o(lost_cnt)
    );

    integer errors = 0;

    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (!cond) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end else
                $display("  ok  : %0s", name);
            $fflush();          // ⭐ 超时被杀时保住已打印的内容（⛔ 否则缓冲全丢）
        end
    endtask

    //  ⭐ 在 snap 那一拍抓下 A / B（⭐ 它们是**单周期**脉冲，不能事后查 ✅）
    reg [3:0] cap_ax_a  = 4'd15;
    reg [3:0] cap_ax_b  = 4'd15;
    reg       cap_valid = 1'b0;
    //  🔴 **⛔ 不能写成 `snap_valid && slide_valid`**：`slide_valid_o` 是**寄存器**，
    //     它在 `snap_valid_i` 之后**下一拍**才抬 ⇒ 两个条件永不同时为真 ⇒ 捕获恒失败
    //     （⭐ 我第一版就踩了这个，MLEAVE-3 因此假红 ✅）
    always @(posedge clk) begin
        if (rst_n && slide_valid) begin
            cap_ax_a  <= slide_axis;
            cap_ax_b  <= slide_axis_b;
            cap_valid <= 1'b1;
        end
    end

    task clear_all;
        begin
            pos = {AXIS_N*POS_W{1'b0}};
            dlt = {AXIS_N*DW{1'b0}};
        end
    endtask

    //  ⭐⭐ 2026-10-17：⭐ **判据必须跟 RTL 一起改** —— RTL 的滑音 A 判据
    //     从 `pos_i[si] > REL_TH` 改成了 **`key_on[si]`**，而 `key_on[]` 由
    //     **扫描状态机**维护（`snap_valid_i` 启动扫描、之后每拍一个轴、16 拍一轮）
    //     ⇒ ⭐ 必须先"预扫"一次 snap 让 `key_on` 置起来，再正式 snap ✅
    //     ⚠️ 本 tb 的真 A 轴 `pos` 必须 **>= TRIG_TH(0x400=1024)**，否则 `key_on` 不会置位
    task do_snap;
        begin
            @(negedge clk);
            snap_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            snap_valid = 1'b0;
            repeat (24) @(posedge clk);      // ⭐ 预扫：≥16 拍（扫描一轮）
            @(negedge clk);
            snap_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            snap_valid = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    task reset_dut;
        begin
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            clear_all();
            cap_valid = 1'b0;
            cap_ax_a  = 4'd15;
            cap_ax_b  = 4'd15;
        end
    endtask

    task set_axis;
        input integer ax;
        input [POS_W-1:0] p;
        input signed [DW-1:0] d;
        begin
            pos[ax*POS_W +: POS_W] = p;
            dlt[ax*DW    +: DW]    = d;
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_ee_multileave/tb_ee_multileave.vcd");
        $dumpvars(0, tb_ee_multileave);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        enable = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════
        $display("--- MLEAVE-1：⭐ 轴 3 与轴 5 【同帧一起离开】⇒ A 必须是【最小】轴号 3 ---");
        //   ⭐ 邻居表（`event_extract.v:293-307`，下排左 = 5-4-3-2）：
        //      · 轴 3 的邻居 = {4, 2}  · 轴 5 的邻居 = {4}
        //   ⇒ ⭐ 无论 A 取 3 还是 5，轴 4 都是合法 B（在上升）⇒ **滑音都会出**
        //   ⇒ ⭐ 唯一能分辨的就是 `slide_axis_o`（= A）✅
        //   🔴 现状（取最大）⇒ A = 5 ⇒ 本条**必红** ✅
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(3, TRIG_TH + 12'h200, -13'sd192);   // ⭐ 离开（< −DELTA_TH）✅
        set_axis(5, TRIG_TH + 12'h180, -13'sd192);   // ⭐ 也离开 ✅
        set_axis(4, 12'h080,            13'sd192);   // ⭐ B：同排邻居、在上升 ✅
        do_snap();
        chk(cap_valid,
            "MLEAVE-1a two axes leaving in ONE frame must still raise slide_valid_o (via axis 4)");
        chk(cap_ax_a == 4'd3,
            "MLEAVE-1b A must be the LOWEST leaving axis (3), not the highest (5) -- comment :328 says MIN");

        // ══════════════════════════════════════════════════════════════
        $display("--- MLEAVE-2：⭐ 轴 4 与轴 6 【同帧一起离开】⇒ A 必须取 4（取 6 就【不出滑音】）---");
        //   ⭐ 轴 4 的邻居 = {5, 3} · 轴 6 的邻居 = {7}（上排左 6-7-0-1 的一端）
        //   ⇒ ⭐ A=4 时轴 5 在上升 ⇒ **出滑音**
        //   ⇒ 🔴 A=6 时唯一邻居是 7、而 7 没动 ⇒ **完全不出滑音** ✅
        //   ⇒ ⭐ 本条比 MLEAVE-1 更强：它抓的是"滑音**丢了**"，不只是"A 号错了" ✅
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(4, TRIG_TH + 12'h200, -13'sd192);   // ⭐ 离开 ✅
        set_axis(6, TRIG_TH + 12'h180, -13'sd192);   // ⭐ 也离开 ✅
        set_axis(5, 12'h080,            13'sd192);   // ⭐ B：轴 4 的邻居、在上升 ✅
        do_snap();
        chk(cap_valid,
            "MLEAVE-2a A=4 (lowest) finds neighbour 5 rising => slide MUST fire (A=6 would find nothing)");
        chk(cap_ax_a == 4'd4,
            "MLEAVE-2b A must be the LOWEST leaving axis (4), not the highest (6)");
        chk(cap_ax_b == 4'd5,
            "MLEAVE-2c B must name the adjacent axis 5");

        // ══════════════════════════════════════════════════════════════
        $display("--- MLEAVE-3：⭐ 非空洞 —— 单个轴离开时仍按老行为出滑音（与旧 tb 同口径）---");
        //   ⭐ 保证本 tb 不是"因为整体坏了才红"：单轴离开这条**必须绿** ✅
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(3, TRIG_TH + 12'h200, -13'sd192);
        set_axis(4, 12'h080,            13'sd192);
        do_snap();
        chk(cap_valid,
            "MLEAVE-3 (non-vacuous) a SINGLE leaving axis still fires a slide -- proves the DUT is alive");
        chk(cap_ax_a == 4'd3,
            "MLEAVE-3b single leaving axis => A == that axis");

        $display("");
        if (errors == 0)
            $display("PASS: event_extract multi-axis-leave -- A is the LOWEST leaving axis, and a slide is not lost");
        else
            $fatal(1, "FAIL: tb_ee_multileave had %0d error(s) (A must be the LOWEST leaving axis)", errors);
        //  🔴 **必须有 `$finish`**（⭐ 我第一版漏了 ⇒ `initial` 结束后时钟一直跑
        //     ⇒ 撞 120 s 预算 ⇒ 假"挂死"，VCD 涨到 1.87 GB ✅）
        //     ⚠️ 同族：⭐ `$fatal` 只走失败路径，⭐ 成功路径必须显式收尾 ✅
        $finish;
    end

endmodule
