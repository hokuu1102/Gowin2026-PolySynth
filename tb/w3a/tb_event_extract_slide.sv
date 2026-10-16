// tb_event_extract_slide.sv · 滑音（portamento）判据的【未实现能红】tb（⭐ 2026-10-11）
//
//   ⭐ **规格**：⭐ `review/滑音触发规格-20261011.md` ✅（⭐ 用户 2026-10-11 拍板 ✅）
//   ⭐ **手势**：⭐ 手指**横向**从轴 A 滑到【相邻】轴 B ✅
//      · ⭐ A 的行程**下降**（⭐ `dA < −DELTA_TH` ✅）
//      · ⭐ B 的行程**刚开始形成**（⭐ `dB > +SLIDE_START_TH`，⭐ **很小** ✅）
//      · ⭐ 两者在【窗口】内（⭐ `SLIDE_WIN ≈ 20 ms` ✅）
//      · ⭐ 且 ⭐ `abs(B − A) == 1` ✅
//   ⭐ **力度取 A 的** ✅（⭐ 用户："滑音要在 B 稍微有一点点形成的时候就开始发出，
//      ⛔ 不能等 B 完全按下之后才响" ✅）
//   ⭐ **中途停在两轴之间** ⇒ ⭐ **停在当前位置** ✅
//
//   🔴 **未实现时必红**：⭐ 本版 `slide_valid_o` **恒 0** ✅
//      ⇒ ⭐ 下面"一减一增 ⇒ 必须出滑音"那一条**必红** ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（⭐ `K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ 本文件必须【无 BOM】（⭐ `tools/check_no_bom.ps1` ✅）

`timescale 1ns/1ps

module tb_event_extract_slide;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;

    //  ⭐ 与 RTL 默认值一致（⭐ 便于核对 ✅）
    localparam [POS_W-1:0] TRIG_TH = 12'h400;   // ⭐ 25% 行程 = "完全按下"
    localparam [POS_W-1:0] START_TH = 12'h040;  // ⭐ 起滑阈值（⭐ 规格新增 ✅）

    reg clk = 1'b0;
    always #10 clk = ~clk;                      // ⭐ 50 MHz

    reg rst_n = 1'b0;
    reg enable = 1'b0;
    //  ⭐⭐ 2026-10-11：⭐ **滑音开关** —— ⭐ 本 tb 测的是"**开着**"时的判据 ✅
    //     📌 ⭐ `top.v` 里它默认 = 0（⭐ 由 `'W'` 切换 ✅）
    //     ⚠️ ⭐ 若不接 ⇒ ⭐ 是 `z` ⇒ ⭐ Z-safe 判成"关" ⇒ ⭐ 判据全红 ✅（⭐ 实测过 ✅）
    reg slide_en = 1'b1;
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
    //  ⭐⭐ 2026-10-13：⭐ **B 的轴号**（⭐ 滑音音高通路用它取 `fb_inc[B]` ✅）
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
        //  ⭐⭐ 2026-10-13：⭐ **B 的轴号**（⭐ 滑音音高通路要用它取 `fb_inc[B]` ✅）
        .slide_axis_b_o(slide_axis_b),
        .two_note_valid_o(two_note_valid),
        .two_note_axis_a_o(two_note_a), .two_note_axis_b_o(two_note_b),
        .overflow_o(overflow), .lost_cnt_o(lost_cnt)
    );

    integer errors = 0;
    integer slide_cnt = 0;
    integer two_cnt = 0;

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

    //  ⭐ 监视器：⭐ 记下"滑音出现过"与"双音出现过" ✅
    always @(posedge clk) begin
        if (rst_n && slide_valid)    slide_cnt = slide_cnt + 1;
        if (rst_n && two_note_valid) two_cnt   = two_cnt + 1;
    end

    //  ⭐ 清空所有轴
    task clear_all;
        begin
            pos = {AXIS_N*POS_W{1'b0}};
            dlt = {AXIS_N*DW{1'b0}};
        end
    endtask

    //  ⭐ 发一个快照脉冲（⭐ 与 `axis_snapshot` 同语义：⭐ 一帧一次 ✅）
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

    //  ⭐⭐ 2026-10-11：⭐ **每个场景前必须复位** ✅
    //   🔴 **为什么**：⭐ `left_v_r`（⭐ "最近有轴离开" ✅）**会跨场景残留** ✅
    //      ⚠️ 窗口 = 1000 帧，⭐ 而我的场景只隔 ~10 帧
    //      ⇒ 🔴 上一个场景的"离开"**仍然在窗口内** ⇒ ⭐ `SLIDE-2` 会被污染成"滑音" ✅
    //   📌 ⭐ 语义上确实如此（⭐ "A 离开后窗口内 B 形成" **就是**滑音 ✅）
    //      ⇒ ⭐ 要测"两轴都增"这一条，⭐ 必须**干净复位** ✅
    task reset_dut;
        begin
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            clear_all();
        end
    endtask

    //  ⭐ 设某个轴的行程与增量
    task set_axis;
        input integer ax;
        input [POS_W-1:0] p;
        input signed [DW-1:0] d;
        begin
            pos[ax*POS_W +: POS_W] = p;
            dlt[ax*DW    +: DW]    = d;
        end
    endtask

    integer i;

    initial begin
        $dumpfile("build/sim/tb_event_extract_slide/tb_event_extract_slide.vcd");
        $dumpvars(0, tb_event_extract_slide);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        enable = 1'b1;
        repeat (5) @(negedge clk);

        // ══════════════════════════════════════════════════════════════
        $display("--- 判据①：⭐ 一减一增 ＋ 相邻 ＋ 在窗口内 ⇒ **必须出滑音** ---");
        //   ⭐ 场景：⭐ 轴 3 已按下（⭐ 完全 ✅），⭐ 轴 4 **刚开始形成**（⭐ 小 ✅）
        //      ⭐ 轴 3 行程在**下降**（⭐ dA < 0 ✅），⭐ 轴 4 在**上升**（⭐ dB > 0 ✅）
        //   🔴 **本版 `slide_valid_o` 恒 0** ⇒ ⭐ 本条**必红** ✅
        // ══════════════════════════════════════════════════════════════
        reset_dut();
        set_axis(3, TRIG_TH + 12'h200, -13'sd192);   // ⭐ A：⭐ 已按下、⭐ 行程在减 ✅
        set_axis(4, 12'h080,            13'sd192);   // ⭐ B：⭐ 刚开始形成（⭐ 0x80 = 2× START_TH ✅）
        do_snap();
        //  ⭐⭐ 2026-10-13：⭐ **B 的轴号必须是 4** ✅（⭐ 滑音音高通路要靠它取 `fb_inc[B]` ✅）
        //     📌 ⭐ 为什么⛔ 不能用 `slide_dir_o` 推：⭐ "相邻"是【物理布局】✅
        //        ⇒ ⭐ B ≠ A±1（⭐ 例如 A=7 时 B 可以是 6 或 0 ✅）
        chk(slide_axis_b == 4'd4,
            "SLIDE-1b slide_axis_b_o must name the ADJACENT axis B (4 here), not A+/-1 by number");
        chk(slide_cnt > 0,
            "SLIDE-1 a release on axis 3 + a tiny press on adjacent axis 4 MUST raise slide_valid_o");

        // ══════════════════════════════════════════════════════════════
        $display("--- 判据②：⭐ 两轴都【在增】⇒ 那是【双音】，⛔ 不许报成滑音 ---");
        //   ⭐ 分界：⭐ 滑音 = **一减一增** ✅ · ⭐ 双音 = **都不减** ✅
        // ══════════════════════════════════════════════════════════════
        begin : neg_two
            integer s0;
            s0 = slide_cnt;
            reset_dut();
            set_axis(3, TRIG_TH + 12'h100, 13'sd192);   // ⭐ 两轴都在**增** ✅
            set_axis(4, TRIG_TH + 12'h100, 13'sd192);
            do_snap();
            chk(slide_cnt == s0,
                "SLIDE-2 two axes BOTH increasing is a TWO-NOTE, NOT a slide");
        end

        // ══════════════════════════════════════════════════════════════
        $display("--- 判据③：⭐ 非相邻轴 ⇒ ⛔ 不许报滑音 ---");
        //   ⭐ 规格：⭐ `abs(B − A) == 1` ✅
        // ══════════════════════════════════════════════════════════════
        begin : neg_far
            integer s0;
            s0 = slide_cnt;
            reset_dut();
            set_axis(2, TRIG_TH + 12'h200, -13'sd192);
            set_axis(7, 12'h080,            13'sd192);   // ⭐ 隔了 5 根轴 ✅
            do_snap();
            chk(slide_cnt == s0,
                "SLIDE-3 a far-apart pair must NOT be reported as a slide (needs |B-A| == 1)");
        end

        // ══════════════════════════════════════════════════════════════
        $display("--- 判据④：⭐ 只有 A 在减、⭐ B 没动 ⇒ ⛔ 不许报滑音 ---");
        //   ⭐ 那是**普通的释放** ✅
        // ══════════════════════════════════════════════════════════════
        begin : neg_rel
            integer s0;
            s0 = slide_cnt;
            reset_dut();
            set_axis(3, TRIG_TH + 12'h200, -13'sd192);   // ⭐ A 在减 ✅
            set_axis(4, 12'h000,            13'sd0);    // ⭐ B 完全没动 ✅
            do_snap();
            chk(slide_cnt == s0,
                "SLIDE-4 a plain release (no adjacent key forming) must NOT be a slide");
        end

        // ══════════════════════════════════════════════════════════════
        $display("--- 判据⑤：⭐ 非空洞 —— 监视器本身在工作 ---");
        //   ⭐ 若 `slide_cnt` 永远是 0，⭐ 判据②③④ 就是**空洞**的 ✅
        //   ⇒ ⭐ 必须证明"计数器**能**涨"（⭐ 用①已经证明了 ✅）
        // ══════════════════════════════════════════════════════════════
        chk(slide_cnt > 0,
            "SLIDE-5 (non-vacuous) the slide monitor can actually increment (proved by SLIDE-1)");

        $display("");
        if (errors == 0)
            $display("PASS: event_extract slide detection -- release+tiny-adjacent-press within the window is a slide, two-note/far/plain-release are NOT");
        else
            $fatal(1, "FAIL: tb_event_extract_slide had %0d error(s) (expected RED before the feature is implemented)", errors);

        #100;
        $finish;
    end

endmodule
