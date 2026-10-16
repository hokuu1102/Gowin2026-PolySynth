// tb_ee_slide_noise.sv · 滑音判据在【真实噪声】下还能不能触发（⭐ 2026-10-16 新增）
//
//   🔴 **为什么要这条 tb**（本文件存在的唯一理由）：
//      现有 `tb_event_extract_slide.sv` 的场景**只驱动参与滑音的那两个轴**
//      （`set_axis(3, …)` / `set_axis(4, …)`），**其余 14 个轴恒为 0**
//      ⇒ ⭐ 它测的是"**理想无噪声**"世界 ⇒ 典型 `C83` 假绿 ✅
//
//   🔴 **它要抓的缺陷**（代码为地面真相）：
//      `rtl/w3a/event_extract.v` 选 A 的规则是
//        **"轴号【最小】的那个 `delta < -DELTA_TH` 的轴"**
//      （HEAD 的 `if (!left_hit && …)` 与现版本的树形编码器都是这个语义）
//      而 `DELTA_TH = 8`，⭐ **规格 `review/滑音触发规格-20261011.md:136` 自己写着
//      "`DELTA_TH = 8` 码 ⇒ 每帧变 ~8 码"** —— 也就是说
//      🔴 **`DELTA_TH` 恰好等于"每帧手指位移"，与噪声同量级**
//      ⇒ ⭐ 只要**任何一个轴号更小的轴**因为噪声/漂移出现 `delta < -8`
//      ⇒ ⭐ **A 就取到那个轴** ⇒ `is_h_adj(A, B)` 不成立 ⇒ 🔴 **滑音不触发** ✅
//
//   ⚠️ **本 tb 在修复前【必红】**（⭐ 有意的 —— 证明判据非空洞）：
//      · 场景① 轴 1 有 −10 的噪声、真 A 是轴 3（−192）、真 B 是轴 4（+192）
//        ⇒ 现状取 A = 1（最小）⇒ `is_h_adj(1,4)` 假 ⇒ **不出滑音** ⇒ 红 ✅
//      · 场景② 轴 0/1/2 都有噪声、真 A 是轴 7（−192）、真 B 是轴 0（+192）
//        ⇒ 现状取 A = 0 ⇒ 但 0 是 B 自己 ⇒ 同样不出 ⇒ 红 ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz
//   ⚠️ 本文件必须【无 BOM】（`tools/check_no_bom.ps1`）

`timescale 1ns/1ps

module tb_ee_slide_noise;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;

    localparam [POS_W-1:0] TRIG_TH        = 12'h400;
    localparam signed [DW-1:0] DELTA_TH   = 13'sd8;
    localparam [POS_W-1:0] SLIDE_START_TH = 12'h004;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n      = 1'b0;
    reg enable     = 1'b0;
    reg slide_en   = 1'b1;
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
            $fflush();
        end
    endtask

    //  ⭐ 捕获：`slide_valid_o` 是寄存器，在 snap 之后【下一拍】才抬
    reg [3:0] cap_a  = 4'd15;
    reg [3:0] cap_b  = 4'd15;
    reg       cap_v  = 1'b0;
    always @(posedge clk) begin
        if (rst_n && slide_valid) begin
            cap_a  <= slide_axis;
            cap_b  <= slide_axis_b;
            cap_v  <= 1'b1;
        end
    end

    task clear_all;
        begin
            pos = {AXIS_N*POS_W{1'b0}};
            dlt = {AXIS_N*DW{1'b0}};
        end
    endtask

    //  ⭐⭐ 2026-10-17（🔴 **判据必须跟 RTL 一起改**）：
    //     RTL 的滑音 A 判据从 `pos_i[si] > REL_TH` 改成了 **`key_on[si]`**，
    //     而 `key_on[]` 由**扫描状态机**维护：
    //       `event_extract.v:618`  ⭐ `snap_valid_i` 那一拍**启动**本轮扫描
    //       `:626-679`             ⭐ 之后**每拍扫一个轴**，16 拍一轮
    //       `:630`                 ⭐ `pos >= TRIG_TH` ⇒ `key_on <= 1`
    //     ⇒ 🔴 原来的 `do_snap` 只等 3 拍 ⇒ **扫描没跑完** ⇒ `key_on` 全 0
    //        ⇒ ⭐ 滑音判据永不成立 ⇒ **判据必红**（这正是它该有的行为：暴露了"判据没跟上"）✅
    //  ✅ **修法**：⭐ **先"预扫"一次 snap**（让扫描把 `key_on` 置起来），
    //     等 **≥16 拍**（扫描一轮），**再正式 snap** —— 那一拍 `key_on` 就是"上一帧按下"的结果 ✅
    //     📌 ⭐ **这样也更接近真实**：真板上帧距 500 µs，每帧都完整扫一轮 ✅
    //     📌 本 tb 的 `TRIG_TH = 12'h400 = 1024`（模块默认）⇒ ⭐ 噪声轴 `pos = 0x100 = 256`
    //        **低于** `TRIG_TH` ⇒ `key_on` 保持 0 ⇒ ⭐ **被正确排除** ✅
    //        （⚠️ 这正是上一版 `pos > REL_TH` 做不到的事：上板 `REL_TH = 32` ⇒ 256 挡不住）
    task do_snap;
        begin
            //  ── ① 预扫：让扫描状态机把 `key_on[]` 置起来 ──────────────────
            @(negedge clk);
            snap_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            snap_valid = 1'b0;
            repeat (24) @(posedge clk);      // ⭐ ≥ 16 拍（扫描一轮）+ 余量

            //  ── ② 正式 snap：这一拍的 `key_on` = 上一帧扫描的结果 ────────
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
            cap_v = 1'b0; cap_a = 4'd15; cap_b = 4'd15;
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
        $dumpfile("build/sim/tb_ee_slide_noise/tb_ee_slide_noise.vcd");
        $dumpvars(0, tb_ee_slide_noise);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        enable = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════
        $display("--- NOISE-1: 轴 1 有 -10 噪声，真 A=3(-192)、真 B=4(+192) ---");
        //   ⭐ 邻居表：下排左 = 5-4-3-2 ⇒ 3 与 4 是邻居 ✅
        //   ⚠️ 轴 1 的 -10 是【纯噪声量级】（DELTA_TH=8 ⇒ 10 刚过线）
        //   🔴 现状：A 取【最小】= 1 ⇒ is_h_adj(1,4) 假 ⇒ 不出滑音 ⇒ 本条必红
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(1, 12'h100, -13'sd10);    // ⭐ 噪声：刚过 DELTA_TH
        set_axis(3, 12'h600, -13'sd192);   // ⭐ 真 A（离开）
        set_axis(4, 12'h080,  13'sd192);   // ⭐ 真 B（形成）
        do_snap();
        chk(cap_v,
            "NOISE-1a a REAL slide (A=3 -> B=4) MUST still fire when another axis has noise-level delta");
        chk(cap_a == 4'd3,
            "NOISE-1b A must be the axis the finger actually LEFT (3), not the lowest noisy one (1)");
        chk(cap_b == 4'd4,
            "NOISE-1c B must be the adjacent axis that formed (4)");

        // ══════════════════════════════════════════════════════════════
        $display("--- NOISE-2: 轴 0/1/2 都有噪声，真 A=7(-192)、真 B=0(+192) ---");
        //   ⭐ 邻居表：上排左 = 6-7-0-1 ⇒ 7 与 0 是邻居 ✅
        //   🔴 现状：A 取最小 = 0 ⇒ 而 0 就是 B ⇒ 同样不出 ⇒ 本条必红
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(0, 12'h080,  13'sd192);   // ⭐ 真 B（形成）
        set_axis(1, 12'h100, -13'sd11);    // ⭐ 噪声
        set_axis(2, 12'h100, -13'sd9);     // ⭐ 噪声
        set_axis(7, 12'h600, -13'sd192);   // ⭐ 真 A（离开）
        do_snap();
        chk(cap_v,
            "NOISE-2a a REAL slide (A=7 -> B=0) MUST still fire when lower axes only have noise");
        chk(cap_a == 4'd7,
            "NOISE-2b A must be 7 (the axis actually left), not the lowest noisy axis (0)");

        // ══════════════════════════════════════════════════════════════
        $display("--- NOISE-3: 非空洞 —— 无噪声时仍必须出滑音（与旧 tb 同口径）---");
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(3, 12'h600, -13'sd192);
        set_axis(4, 12'h080,  13'sd192);
        do_snap();
        chk(cap_v,  "NOISE-3 (non-vacuous) a clean slide still fires");
        chk(cap_a == 4'd3, "NOISE-3b and A is 3");

        // ══════════════════════════════════════════════════════════════
        $display("--- NOISE-4: 纯噪声（没人滑）⇒ ⛔ 不许出滑音 ---");
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(1, 12'h100, -13'sd12);
        set_axis(3, 12'h100, -13'sd10);
        set_axis(4, 12'h100,  13'sd11);
        do_snap();
        chk(!cap_v,
            "NOISE-4 pure noise must NOT be reported as a slide (no finger actually moved)");

        $display("");
        if (errors == 0)
            $display("PASS: event_extract slide survives realistic per-axis noise");
        else
            $fatal(1, "FAIL: tb_ee_slide_noise had %0d error(s) (EXPECTED RED: A is picked as the LOWEST leaving axis, so noise on a lower axis kills the slide)", errors);
        $finish;
    end

endmodule
