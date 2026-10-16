// tb_ee_multineighbor.sv · 补判据（SLIDERECHECK 复核队 2026-10-16）
//
// ⭐ 为什么需要它：⭐ 拆锥队把"B 侧选哪个邻居"从【第一个形成的】改成
//    【行程最大的同排邻居】（⭐ 见 rtl/w3a/event_extract.v:644-686 ✅）
//    ⚠️ 而既有 `tb_event_extract_slide` 的 SLIDE-1..5 **全是单邻居场景**
//       （⭐ 只有 A=3 / B=4 这一对 ✅）⇒ ⭐ **多邻居同时形成**这个场景
//       ⭐ **没有任何判据覆盖**（⭐ C83 型"探针假绿"风险 ✅）
//
// ⭐ 本判据钉住：⭐ **B 必须是"行程最大"的那个同排邻居**（⭐ ⛔ 不是第一个 ✅）
//
// ⭐ 物理邻接（⭐ 从 RTL `is_h_adj` 直接展开，⭐ 每轴最多 2 个同排邻居 ✅）：
//      3 → {2, 4}   ·   4 → {3, 5}   ·   7 → {0, 6}   ·   8 → {9, 15}
//      11 → {10, 12} · 12 → {11, 13}
//    ⚠️ 因为每轴最多 2 个邻居 ⇒ ⭐ 拆锥队声称的"深度 ≤ 4"是**保守上界**
//       （⭐ 真实深度 ≤ 2 ✅）
//
// 🔴 本判据【必须能红】（⭐ 否则它是假判据 ✅）：
//    在 %TEMP% 副本上把 RTL 的"取最大"改回"取第一个" ⇒ ⭐ MULTI-1/2 必红 ✅
//    ⚠️ 那个变异版在【单邻居】场景下与本判据【完全一致】✅
//       ⇒ ⭐ 本条断言红 ⇒ ⭐ **唯一可能**就是"B 的选择规则变了**且**被观测到** ✅
//       ⇒ ⭐ ⛔ 不可能是"判据走空"/"场景没构造出来" ✅
//
// ⭐ 场景①：⭐ A=3（⭐ 下排左 5-4-3-2 段 ✅）的**两个**邻居 2 与 4 同时越阈
//    · ⭐ 轴 4：⭐ delta=+20 > SLIDE_START_TH(4) ✅ · pos=0x200 = **最大** ⇒ 必须是 B ✅
//    · ⭐ 轴 2：⭐ delta=+10 > 4 ✅ · pos=0x100 = **较小** ⇒ ⛔ 不是 B ✅
//    ⇒ ⭐ 正确 B = 4（⭐ 按"行程最大" ✅）
//    ⚠️ 把 pos 安排成"较大行程 = 较大轴号" ⇒ ⭐ "取第一个"(轴 2) 与 "取最大"(轴 4)
//       **在 B 与方向上同时分叉**（⭐ OLD: B=2/dir=−1 ⇒ NEW: B=4/dir=+1 ✅）
//       ⇒ ⭐ 这一条同时钉住 **B 的选择**和 **slide_dir_o** 两条语义 ✅
//
// ⭐ 场景②（⭐ 反向 ⇒ 钉住"取最大不依赖轴号大小" ✅）：
//    ⭐ A=3 时两个邻居都在，⭐ 但把"最大行程"放在**较小的轴号**上
//    · ⭐ 轴 2：⭐ pos=0x200 = **最大** ⇒ 必须是 B ✅
//    · ⭐ 轴 4：⭐ pos=0x100 = 较小 ⇒ ⛔ 不是 B ✅
//    ⇒ ⭐ 正确 B = 2、⭐ 方向 = −1 ✅
//    ⚠️ 在【旧的"取第一个"】规则下这条**同样**给 B=2（⭐ 轴号小的先出现 ✅）
//       ⇒ ⭐ 它**不能**区分两条规则，⭐ 它守的是**另一条**不变式：
//         "取最大"不能被实现成"无脑取大轴号" ✅
//
// ⛔ 纪律：⭐ 不新增参数（⭐ ⭐ 用 RTL 默认阈值：⭐ SLIDE_START_TH=4 ✅）
//    ⭐ Verilog-2001 · ⭐ 同步复位低有效 · ⭐ 单时钟 50 MHz ✅
//    ⚠️ 本文件必须【无 BOM】（⭐ 与 `tb_event_extract_slide.sv` 同口径 ✅）

`timescale 1ns/1ps

module tb_ee_multineighbor;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;

    reg clk = 1'b0;
    always #10 clk = ~clk;                      // ⭐ 50 MHz

    reg rst_n     = 1'b0;
    reg enable    = 1'b0;
    reg slide_en  = 1'b1;                       // ⭐ 滑音开关开着 ✅
    reg snap_valid = 1'b0;
    reg [AXIS_N*POS_W-1:0] pos = {AXIS_N*POS_W{1'b0}};
    reg [AXIS_N*DW-1:0]    dlt = {AXIS_N*DW{1'b0}};

    wire                 slide_valid;
    wire [3:0]           slide_axis;            // ⭐ A（⭐ 应为 3 ✅）
    wire signed [1:0]    slide_dir;
    wire [3:0]           slide_axis_b;          // ⭐ B（⭐ 场景① = 4 ✅）
    wire                 evt_valid;
    wire [3:0]           evt_axis;
    wire [1:0]           evt_kind;
    wire [POS_W-1:0]     evt_depth;
    wire                 overflow;
    wire [7:0]           lost_cnt;

    event_extract #(
        .AXIS_N(AXIS_N), .POS_W(POS_W), .DW(DW)
        // ⭐ 不覆盖任何阈值 ⇒ ⭐ 与 `tb_event_extract_slide` 的 ELABORATION 完全同口径 ✅
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .enable_i(enable),
        .slide_en_i(slide_en),
        .snap_valid_i(snap_valid),
        .pos_i(pos), .delta_i(dlt),
        .evt_valid_o(evt_valid), .evt_axis_o(evt_axis),
        .evt_kind_o(evt_kind), .evt_depth_o(evt_depth),
        .key_on_o(),                            // ⭐ 本判据不用 ✅
        .slide_valid_o(slide_valid), .slide_axis_o(slide_axis),
        .slide_dir_o(slide_dir),
        .slide_axis_b_o(slide_axis_b),
        .two_note_valid_o(),                    // ⭐ 本判据不用 ✅
        .two_note_axis_a_o(), .two_note_axis_b_o(),
        .overflow_o(overflow), .lost_cnt_o(lost_cnt)
    );

    integer errors = 0;
    //  ⭐⭐ 2026-10-16：⭐ `slide_valid_o` 是【单周期脉冲】（⭐ `evt_valid_o` 同风格 ✅）
    //     ⚠️ 第一版我在 `do_snap()` 之后直接读 `slide_valid` ⇒ 🔴 脉冲早已回落
    //        （⭐ `do_snap` 末尾 `repeat (3) @(posedge clk)` ≈ 5 拍 ✅）⇒ 假红 ✅
    //     ⭐ 与 `tb_event_extract_slide.sv` 同口径：⭐ 用【监视器】在脉冲**高电平那一拍**
    //        锁存 B / A / dir ⇒ ⭐ 既断言"产生过"，⭐ 又断言"那一拍的取值正确" ✅
    integer slide_cnt = 0;
    reg [3:0]        cap_b;      // ⭐ 脉冲时锁存的 B ✅
    reg [3:0]        cap_a;      // ⭐ 脉冲时锁存的 A ✅
    reg signed [1:0] cap_dir;    // ⭐ 脉冲时锁存的方向 ✅

    always @(posedge clk) begin
        if (rst_n && slide_valid) begin
            slide_cnt = slide_cnt + 1;
            cap_b   = slide_axis_b;
            cap_a   = slide_axis;
            cap_dir = slide_dir;
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

    task clear_all;
        begin
            pos = {AXIS_N*POS_W{1'b0}};
            dlt = {AXIS_N*DW{1'b0}};
        end
    endtask

    task reset_dut;
        begin
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            clear_all();
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

    //  ⭐⭐ 2026-10-17：⭐ **判据必须跟 RTL 一起改** —— RTL 的滑音 A 判据
    //     从 `pos_i[si] > REL_TH` 改成了 **`key_on[si]`**（扫描状态机维护、带迟滞）
    //     ⇒ ⭐ 必须先"预扫"一次 snap 让 `key_on` 置起来，再正式 snap ✅
    //     ⚠️ 真 A 轴的 `pos` 必须 **>= TRIG_TH(0x400=1024)**，否则 `key_on` 不置位
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

    initial begin
        $dumpfile("build/sim/tb_ee_multineighbor/tb_ee_multineighbor.vcd");
        $dumpvars(0, tb_ee_multineighbor);

        repeat (5) @(negedge clk);
        rst_n   = 1'b1;
        enable  = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════
        $display("--- SCENE 1: BOTH neighbours of A=3 form at once; larger travel on axis 4 ---");
        //   ⭐ 规格依据：⭐ `rtl/w3a/event_extract.v:644-652`（⭐ 用户裁定
        //      "滑音模式开着 ⇒ 相邻先后发生就算滑音"，⭐ B = 行程最大的同排邻居 ✅）
        // ══════════════════════════════════════════════════════════════
        begin : scene1
            integer s0;
            s0 = slide_cnt;
            reset_dut();
            set_axis(3, 12'h900, -13'sd192);   // ⭐ A：⭐ 已按下、⭐ 行程在减（⭐ dA < −DELTA_TH ✅）
            set_axis(4, 12'h200,  13'sd20);    // ⭐ 邻居：⭐ 行程【最大】 ⇒ ⭐ 必须是 B ✅
            set_axis(2, 12'h100,  13'sd10);    // ⭐ 邻居：⭐ 行程较小 ⇒ ⛔ 不是 B ✅
            do_snap();

            //  ⭐① 滑音确实产生过（⭐ 非空洞：⭐ 否则下面几条都是空断言 ✅）
            chk(slide_cnt > s0,
                "MULTI-4a (non-vacuous) slide_valid_o must actually pulse for this multi-neighbour case");

            //  ⭐② B 必须落在【最大行程】的那个邻居（⭐ ⭐ 本判据的核心 ✅）
            //     ⚠️ 两个候选都合格（⭐ delta 都 > SLIDE_START_TH=4 ✅、⭐ 都与 A 同排相邻 ✅）
            //     ⇒ ⭐ 唯一正确的 B = 4（⭐ 行程 0x200 最大 ✅）
            //     🔴 若改成"取第一个形成的" ⇒ ⭐ B 会变成 2（⭐ 轴号更小 ✅）⇒ 本条必红 ✅
            chk(cap_b == 4'd4,
                "MULTI-1 B must be the SAME-ROW neighbour with the LARGEST travel (4), not the first/lowest-axis forming one (2)");

            //  ⭐③ 方向必须跟随【赢下来的那个轴】（⭐ 4 > 3 ⇒ +1 ✅）
            //     🔴 若改成"取第一个" ⇒ ⭐ B=2 ⇒ 方向会变成 −1 ⇒ 本条必红 ✅
            //     ⚠️ 这一条把 `slide_dir_o` 也钉住了 ✅
            chk(cap_dir == 2'sd1,
                "MULTI-2 direction must follow the WINNING axis (best_ax 4 > A 3 => +1), not the first-forming one");

            //  ⭐④ A 必须是"正在离开"的那个轴 3（⭐ 三项条件里的第 1 项没被拆坏 ✅）
            chk(cap_a == 4'd3,
                "MULTI-3 A must still be the leaving axis (3) -- is_h_adj + left-axis pick unchanged");
        end

        // ══════════════════════════════════════════════════════════════
        //  ⭐ SCENE 2（⭐ 反向 ⇒ "取最大"不许被实现成"无脑取大轴号" ✅）
        //     ⭐ 同样 A=3 两邻居同时在，⭐ 但把"最大行程"放在【较小】的轴号上
        // ══════════════════════════════════════════════════════════════
        begin : scene2
            integer s0;
            s0 = slide_cnt;
            reset_dut();
            set_axis(3, 12'h900, -13'sd192);   // ⭐ A = 3 ✅
            set_axis(2, 12'h200,  13'sd20);    // ⭐ 邻居：⭐ 行程【最大】、⭐ 轴号更小 ⇒ 必须是 B ✅
            set_axis(4, 12'h100,  13'sd10);    // ⭐ 邻居：⭐ 行程较小 ⇒ ⛔ 不是 B ✅
            do_snap();

            chk(slide_cnt > s0,
                "MULTI-4b (non-vacuous) scene 2 must also pulse slide_valid_o");

            chk(cap_b == 4'd2,
                "MULTI-5 the largest-travel neighbour may have the SMALLER axis number (2 here), and it must still win");
            chk(cap_dir == -2'sd1,
                "MULTI-6 direction must flip to -1 when the winning neighbour has the smaller axis number");
        end

        $display("");
        if (errors == 0)
            $display("PASS: multi-neighbour slide B-selection -- B is the same-row neighbour with the LARGEST travel (tie -> lowest axis), A stays the leaving axis, direction follows the winning axis");
        else
            $fatal(1, "FAIL: tb_ee_multineighbor had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
