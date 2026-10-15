`timescale 1ns/1ps

// T15 public seam: raw axis and pluck events become playing events.
module tb_play_mode_ctrl;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg fretboard_mode;
    reg axis_valid;
    reg [3:0] axis;
    reg [1:0] axis_kind;
    reg [11:0] axis_depth;
    reg pluck_valid;
    reg pluck_up;
    //  ⭐⭐ 2026-10-15：⭐ **`held_mask` 清零脉冲**（⭐ 模拟 `at_en_ready` 的掉沿 ⇒ 重 tare）
    reg axis_clr;
    wire evt_valid;
    wire [3:0] evt_axis;
    wire [1:0] evt_kind;
    wire [11:0] evt_depth;
    integer errors = 0;
    integer event_n = 0;
    //  ⭐⭐ 2026-10-15：⭐ **数组 16 → 128** ✅
    //     🔴 **为什么**：⭐ 新增"按住 **16** 个轴 ⇒ 拨一次 ⇒ 16 条"＋"逐个松开 ⇒ 16 条 OFF"
    //        ⇒ ⭐ 单次最多 **32** 条事件 ⇒ ⚠️ 原来的 `[0:15]` **装不下** ✅
    //     ⚠️ **为什么必须扩大而不是靠"少测几个"**：⭐ iverilog 对**越界写数组**
    //        **静默丢弃**（⛔ 不报错、⛔ 不警告）⇒ 🔴 判据会**假绿**
    //        （⭐ `L84` 同族：⭐ "判据假设过强/证据不足" ⇒ 结论无效）✅
    reg [3:0] events_axis [0:127];
    reg [1:0] events_kind [0:127];
    //  ⭐ 边界用例的辅助量（⭐ 位图 + 顺序检查 —— ⭐ 逐轴"有没有、对不对"）
    reg [15:0] ax_mask;
    reg        kinds_ok;
    integer    ai;
    //  ⭐⭐ 2026-10-15（⭐ 缝合 STITCHER）：⭐ **按 `kind` 分类计数**（⭐ 新判据要"数 PLUCK / OFF"）✅
    //     📌 **为什么需要**：⭐ 修复后**同一段序列里 PLUCK 与补发的 OFF 会混在一起**
    //        （⭐ 补 OFF FSM 与拨弦 FSM 共用 `evt_*` 单事件口）
    //        ⇒ ⭐ 只数 `event_n` **分不清**"该出的出了"与"不该出的也出了" ✅
    integer    cnt_pluck;
    integer    cnt_off;
    integer    cnt_on;
    integer    ci;

    always #10 clk = ~clk;

    task count_kinds;
        begin
            cnt_pluck = 0; cnt_off = 0; cnt_on = 0;
            for (ci = 0; ci < event_n; ci = ci + 1) begin
                if      (events_kind[ci] == 2'd0) cnt_on    = cnt_on    + 1;
                else if (events_kind[ci] == 2'd1) cnt_off   = cnt_off   + 1;
                else if (events_kind[ci] == 2'd2) cnt_pluck = cnt_pluck + 1;
            end
        end
    endtask

    play_mode_ctrl dut (
        .clk_i(clk), .rst_n_i(rst_n), .fretboard_mode_i(fretboard_mode),
        .axis_valid_i(axis_valid), .axis_i(axis), .axis_kind_i(axis_kind), .axis_depth_i(axis_depth),
        .pluck_valid_i(pluck_valid), .pluck_up_i(pluck_up),
        .axis_clr_i(axis_clr),
        .evt_valid_o(evt_valid), .evt_axis_o(evt_axis), .evt_kind_o(evt_kind), .evt_depth_o(evt_depth)
    );

    task chk;
        input [8*96-1:0] name;
        input cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task axis_evt;
        input [3:0] a;
        input [1:0] k;
        input [11:0] d;
        begin
            @(negedge clk); axis=a; axis_kind=k; axis_depth=d; axis_valid=1'b1;
            @(negedge clk); axis_valid=1'b0;
        end
    endtask

    task pluck_evt;
        input up;
        begin
            @(negedge clk); pluck_up=up; pluck_valid=1'b1;
            @(negedge clk); pluck_valid=1'b0;
        end
    endtask

    always @(posedge clk) if (rst_n && evt_valid) begin
        events_axis[event_n] = evt_axis;
        events_kind[event_n] = evt_kind;
        $display("     [evt #%0d] axis=%0d kind=%0d (depth=%0d)",
                 event_n, evt_axis, evt_kind, evt_depth);
        event_n = event_n + 1;
    end

    initial begin
        fretboard_mode=1'b0; axis_valid=0; axis=0; axis_kind=0; axis_depth=0; pluck_valid=0; pluck_up=0;
        axis_clr=1'b0;
        repeat (3) @(posedge clk); rst_n=1'b1;

        // Keyboard: raw press/release are the playing events; pluck does nothing.
        axis_evt(4'd2, 2'd0, 12'd1000);
        axis_evt(4'd2, 2'd1, 12'd0);
        pluck_evt(1'b1);
        repeat (2) @(posedge clk);
        chk("keyboard forwards threshold note_on", event_n == 2 && events_axis[0] == 4'd2 && events_kind[0] == 2'd0);
        chk("keyboard forwards release note_off", events_axis[1] == 4'd2 && events_kind[1] == 2'd1);

        // Fretboard: press selects only; either pluck direction starts the selected note.
        fretboard_mode=1'b1;
        axis_evt(4'd6, 2'd0, 12'd900);
        repeat (2) @(posedge clk);
        chk("fretboard selection alone is silent", event_n == 2);
        pluck_evt(1'b0);
        repeat (2) @(posedge clk);
        chk("fretboard DOWN pluck starts selected axis", event_n == 3 && events_axis[2] == 4'd6 && events_kind[2] == 2'd2);
        axis_evt(4'd6, 2'd1, 12'd0);
        repeat (2) @(posedge clk);
        chk("releasing a plucked selection sends note_off", event_n == 4 && events_axis[3] == 4'd6 && events_kind[3] == 2'd1);

        axis_evt(4'd9, 2'd0, 12'd800);
        pluck_evt(1'b1);
        repeat (2) @(posedge clk);
        chk("fretboard UP pluck starts a newly selected axis", event_n == 5 && events_axis[4] == 4'd9 && events_kind[4] == 2'd2);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-09（`P0-22`）：⭐ **换品后松键必须放掉【正在响】的音** ✅
        //   🔴 **原缺陷**：⭐ 原判据只看 `axis_i == gate_axis` ✅
        //      ⚠️ 而 `gate_axis` **只在拨弦那一拍锁存**（⭐ 此后只有再次拨弦才更新）
        //      ⇒ ⭐ 松开"新选中的轴"时 `9 != 6` ⇒ 🔴 **不发 OFF ⇒ 挂音** ✅
        //   📌 ⚠️ **搭用例的坑（⭐ 我第一版就栽了）**：⭐ 不能接着上面那一步做 ——
        //      上面 L89-92 的 **UP 拨弦已经把 `gate_axis` 重新锁到 9 了**
        //      ⇒ ⭐ 那时松 9 本来就该放 9 ⇒ ⭐ **判据恒真，测不出东西** ✅
        //   ✅ **正确序列（⭐ 审查原文）**：⭐ 必须**重新复位**后走
        //      ① 按 6（ON）⇒ `selected_axis=6`
        //      ② 拨弦 ⇒ `gate_axis=6`（⭐ voice 起音）
        //      ③ 按 9（ON）⇒ ⭐ `selected_axis=9`（⭐ **而 `gate_axis` 仍是 6**）
        //      ④ 松 9（OFF）⇒ ⭐ 应发 `note_off` 且 `evt_axis` = **6**（⭐ 正在响的那个）✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd6, 2'd0, 12'd900);            // ⭐ ① 选中轴 6
        pluck_evt(1'b0);                          // ⭐ ② 拨弦 ⇒ gate_axis = 6（起音）
        repeat (2) @(posedge clk);
        axis_evt(4'd9, 2'd0, 12'd800);            // ⭐ ③ 换到轴 9（⭐ 不拨弦！）
        repeat (2) @(posedge clk);
        axis_evt(4'd9, 2'd1, 12'd0);              // ⭐ ④ 松开轴 9
        repeat (2) @(posedge clk);
        chk("P0-22 slide-then-release: the SOUNDING note (gate axis 6) gets its note_off",
            event_n == 2 && events_axis[1] == 4'd6 && events_kind[1] == 2'd1);

        //  ═══ ⭐⭐ P0-22 第二条：⭐ **键盘模式 → 指板模式切换后松键** ═══
        //   🔴 **原缺陷**：⭐ 键盘分支**从不写 `gate_valid`** ⇒ ⭐ 切到指板后 `gate_valid=0`
        //      ⇒ 🔴 `evt_valid_o` **一拍都不抬** ⇒ ⭐ **挂音** ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b0;                    // ⭐ 键盘模式
        axis_evt(4'd5, 2'd0, 12'd1000);           // ⭐ 按下
        repeat (2) @(posedge clk);
        fretboard_mode = 1'b1;                    // ⭐ 切到指板模式（⭐ 音色循环 ⇒ 运行期信号）
        axis_evt(4'd5, 2'd1, 12'd0);              // ⭐ 松键
        repeat (2) @(posedge clk);
        chk("P0-22 keyboard->fretboard switch: the release still emits note_off (no stuck note)",
            event_n == 2 && events_kind[1] == 2'd1 && events_axis[1] == 4'd5);

        //  ═══ ⭐⭐ 2026-10-14：⭐ **多轴独立跟踪（新功能判据）** ═══
        //   🔴 **原实现的三个 bug 同一个根因**：⭐ `gate_axis`/`selected_axis` 都是**单个**轴号
        //      ① ⭐ 交替拨弦覆盖 `gate_axis` ⇒ 🔴 旧音收不到 OFF ⇒ **挂音**
        //      ② ⭐ `selected_axis` 单个 ⇒ ⭐ 换品挤掉旧轴 ⇒ 🔴 **第二个音出不来**
        //      ③ ⭐ 一次拨弦只触发"选中的那一个" ⇒ 🔴 **滑音/多轴同时响不了**
        //   ✅ 新语义：⭐ 位图跟踪；⭐ 拨弦触发"所有已按住的轴"；⭐ 松轴放掉正在响的
        //  ─────────────────────────────────────────────────────────────────
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        //  ① 同时按住 6 和 9（⭐ 多轴！）
        axis_evt(4'd6, 2'd0, 12'd900);
        axis_evt(4'd9, 2'd0, 12'd800);
        repeat (2) @(posedge clk);
        chk("M1 two axes held => selection alone is still silent", event_n == 0);
        //  ② 🔴🔴 **2026-10-15：⭐ 契约已【经用户授权】变更** ⭐⭐
        //     ⭐ **旧契约（⭐ 本 tb 原 `:151-159` 那段取舍注释）**：
        //        "一次拨弦触发**一个**轴、多轴时逐次覆盖"
        //        ⇒ 🔴 代价：⭐ "一次拨弦出和弦"**做不到**（⭐ 原注释如实记录过 ✅）
        //     ⭐ **新契约（⭐ 用户 2026-10-15 上板实测后拍板）**：
        //        "一次拨弦 ⇒ 触发**所有**已按住的轴（和弦）" ✅
        //     📌 ⭐ **用户原话**：*"现在指板模式还是只有一个音，所以滑音也测不出来"*
        //        ⇒ ⭐ **滑音要两个轴同时按住** ⇒ ⛔ **单轴永远测不出来** ✅
        //     📌 ⭐ **`P0-22` ① 的具体变化（⭐ 一句话）**：
        //        · ⭐ 旧 = "松**任意**轴 ⇒ 放掉**正在响的那一个**"（⭐ 只有一个 `gate_axis`）
        //        · ⭐ 新 = "松**某**轴 ⇒ **只放掉该轴自己的音**，⭐ 其余轴的音**继续响**"
        //          （⭐ `keyboard_held[]` **逐轴配对** ⇒ ⭐ `note_on`/`note_off` 一一对应）
        //     📌 ⭐ 原注释要求的"必须先重谈 `P0-22` ① 的契约，⛔ 不能偷偷改"
        //        ⇒ ⭐ **本次已履行**：⭐ 用户拍板 ✅ ＋ ⭐ 本处与 RTL 注释都**明写"经用户授权"** ✅
        pluck_evt(1'b0);
        repeat (6) @(posedge clk);
        chk("M2 [contract changed - user authorised] ONE pluck triggers ALL held axes: BOTH 6 and 9",
            event_n == 2
            && events_kind[0] == 2'd2 && events_kind[1] == 2'd2
            && ((events_axis[0] == 4'd6 && events_axis[1] == 4'd9)
             || (events_axis[0] == 4'd9 && events_axis[1] == 4'd6)));
        //  ③ ⭐ **再拨一次 ⇒ 和弦【整个】重触发**（⭐ 每次拨弦都把已按住的轴发全）
        pluck_evt(1'b1);
        repeat (6) @(posedge clk);
        chk("M3 a SECOND pluck re-triggers the WHOLE chord (both axes again, no 'second note missing')",
            event_n == 4
            && events_kind[2] == 2'd2 && events_kind[3] == 2'd2
            && ((events_axis[2] == 4'd6 && events_axis[3] == 4'd9)
             || (events_axis[2] == 4'd9 && events_axis[3] == 4'd6)));
        //  ④ ⭐ **松【一个】轴 ⇒ 只放掉它自己**（⭐ 另一个继续响 —— ⭐ `P0-22` ① 新语义）
        axis_evt(4'd6, 2'd1, 12'd0);
        repeat (6) @(posedge clk);
        chk("M3b releasing axis 6 emits exactly ONE note_off, and it is axis 6 (the other keeps sounding)",
            event_n == 5 && events_kind[4] == 2'd1 && events_axis[4] == 4'd6);
        axis_evt(4'd9, 2'd1, 12'd0);
        repeat (6) @(posedge clk);
        chk("M3c releasing axis 9 emits ITS OWN note_off => every note_on has a matching note_off",
            event_n == 6 && events_kind[5] == 2'd1 && events_axis[5] == 4'd9);
        //  ④ ⭐ **交替拨弦不挂音（⭐ 用户报告的第一症状 ✅）**
        //     ⭐ 复位后：⭐ 拨 6 ⇒ 换 9 再拨 ⇒ 交替 3 轮 ⇒ 每次松键都要能放掉
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd6, 2'd0, 12'd900);
        pluck_evt(1'b0); repeat (2) @(posedge clk);       // ⭐ 拨 6
        axis_evt(4'd6, 2'd1, 12'd0); repeat (2) @(posedge clk);   // ⭐ 松 6 ⇒ 应 OFF
        axis_evt(4'd9, 2'd0, 12'd800);
        pluck_evt(1'b1); repeat (2) @(posedge clk);       // ⭐ 拨 9
        axis_evt(4'd9, 2'd1, 12'd0); repeat (2) @(posedge clk);   // ⭐ 松 9 ⇒ 应 OFF
        axis_evt(4'd6, 2'd0, 12'd900);
        pluck_evt(1'b0); repeat (2) @(posedge clk);       // ⭐ 再拨 6
        axis_evt(4'd6, 2'd1, 12'd0); repeat (2) @(posedge clk);   // ⭐ 再松 6 ⇒ 应 OFF
        //  ⭐ 期望：⭐ 3 个 PLUCK + 3 个 OFF 交替（⭐ 一个都不少 ⇒ 不挂音 ✅）
        chk("M4 alternating pluck/release => every note_on gets its note_off (no stuck note)",
            event_n == 6
            && events_kind[0] == 2'd2 && events_kind[1] == 2'd1
            && events_kind[2] == 2'd2 && events_kind[3] == 2'd1
            && events_kind[4] == 2'd2 && events_kind[5] == 2'd1);
        //  ⑤ ⭐ **按住不放 ⇒ 每次拨弦都再触发一次**（⭐ 用户要的"超过阈值就一直保持可触发" ✅）
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd3, 2'd0, 12'd500);                  // ⭐ 按住不放（⛔ 不松）
        pluck_evt(1'b0); repeat (4) @(posedge clk);      // ⭐ 第 1 次拨
        pluck_evt(1'b1); repeat (4) @(posedge clk);      // ⭐ 第 2 次拨
        pluck_evt(1'b0); repeat (4) @(posedge clk);      // ⭐ 第 3 次拨
        chk("M5 held axis keeps retriggering on every pluck (no one-shot latch)",
            event_n == 3
            && events_kind[0] == 2'd2 && events_kind[1] == 2'd2 && events_kind[2] == 2'd2);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-15（⭐ **新增** · ⭐ **经用户授权的契约变更**）⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐ **和弦 + 逐轴配对**：⭐ 按住 3 个轴 ⇒ 拨一次 ⇒ ⭐ **3 条 `PLUCK` 都出**
        //     ⇒ ⭐ 再**逐个**松开 ⇒ ⭐ **3 条 `note_off` 一一配对**
        //     （⭐ 项目 `T38` 防挂音纪律：⛔ 不许出现"没有 off 的 on" ✅）
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd1, 2'd0, 12'd700);
        axis_evt(4'd2, 2'd0, 12'd700);
        axis_evt(4'd3, 2'd0, 12'd700);
        repeat (2) @(posedge clk);
        pluck_evt(1'b0);
        repeat (8) @(posedge clk);
        chk("M6 three axes held => ONE pluck emits THREE note_on (PLUCK) events",
            event_n == 3
            && events_kind[0] == 2'd2 && events_kind[1] == 2'd2 && events_kind[2] == 2'd2);
        //  ⭐ 位图检查：⭐ 三条 `PLUCK` 必须**恰好覆盖** 轴 1/2/3（⭐ 各一次，⛔ 不重不漏）
        chk("M6b the three PLUCK events cover axes {1,2,3} exactly once each",
            ((16'd1 << events_axis[0]) | (16'd1 << events_axis[1]) | (16'd1 << events_axis[2]))
            == (16'h0002 | 16'h0004 | 16'h0008));
        axis_evt(4'd1, 2'd1, 12'd0);
        repeat (4) @(posedge clk);
        chk("M6c releasing axis 1 emits its OWN note_off (axis 1)",
            event_n == 4 && events_kind[3] == 2'd1 && events_axis[3] == 4'd1);
        axis_evt(4'd2, 2'd1, 12'd0);
        repeat (4) @(posedge clk);
        chk("M6d releasing axis 2 emits its OWN note_off (axis 2)",
            event_n == 5 && events_kind[4] == 2'd1 && events_axis[4] == 4'd2);
        axis_evt(4'd3, 2'd1, 12'd0);
        repeat (4) @(posedge clk);
        chk("M6e releasing axis 3 completes 3 note_on / 3 note_off, perfectly paired (no stuck voice)",
            event_n == 6 && events_kind[5] == 2'd1 && events_axis[5] == 4'd3);

        //  ═══ ⭐⭐ 边界 ①：⭐ 按住【1】个轴 ⇒ 拨一次 ⇒ ⭐ **仍然只出 1 条** ═══
        //   🔴 **为什么必须测**：⭐ "一次拨弦发所有轴" 最容易**改过头**
        //      ⇒ ⭐ 把**单轴**也发成多条 ⇒ 🔴 "一次拨弦一个音"的既有行为被破坏 ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd7, 2'd0, 12'd650);
        repeat (2) @(posedge clk);
        pluck_evt(1'b0);
        repeat (8) @(posedge clk);
        chk("M7 BOUNDARY one axis held => ONE pluck still emits EXACTLY ONE event (N=1, not 2+)",
            event_n == 1 && events_kind[0] == 2'd2 && events_axis[0] == 4'd7);

        //  ═══ ⭐⭐ 边界 ②：⭐ 按住【16】个轴 ⇒ 拨一次 ⇒ ⭐ **16 条**（⭐ 别溢出/别丢）═══
        //   🔴 **为什么必须测**：⭐ 16 是 `held_mask` 的**满位**
        //      ⇒ ⭐ 多拍 FSM 必须**一拍一条、一条不漏**地发满 16 拍 ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        for (ai = 0; ai < 16; ai = ai + 1) axis_evt(ai[3:0], 2'd0, 12'd600);
        repeat (2) @(posedge clk);
        pluck_evt(1'b0);
        repeat (24) @(posedge clk);
        ax_mask  = 16'd0;
        kinds_ok = 1'b1;
        for (ai = 0; ai < 16; ai = ai + 1) begin
            ax_mask = ax_mask | (16'd1 << events_axis[ai]);
            if (events_kind[ai] != 2'd2) kinds_ok = 1'b0;
        end
        chk("M8 BOUNDARY all 16 axes held => ONE pluck emits 16 PLUCK events covering all 16 axes",
            event_n == 16 && ax_mask == 16'hFFFF && kinds_ok);
        //  ⭐ 再**逐个**松开 ⇒ ⭐ 16 条 `note_off` 一一配对（⭐ 防挂音）
        for (ai = 0; ai < 16; ai = ai + 1) axis_evt(ai[3:0], 2'd1, 12'd0);
        repeat (4) @(posedge clk);
        ax_mask  = 16'd0;
        kinds_ok = 1'b1;
        for (ai = 16; ai < 32; ai = ai + 1) begin
            ax_mask = ax_mask | (16'd1 << events_axis[ai]);
            if (events_kind[ai] != 2'd1) kinds_ok = 1'b0;
        end
        chk("M9 all 16 released => 16 matching note_off, one per axis (no stuck voice)",
            event_n == 32 && ax_mask == 16'hFFFF && kinds_ok);

        //  ═══ ⭐⭐ 新增：⭐ **拨弦与轴事件【同拍】⇒ 避让而非丢弃（⛔ 不丢事件）** ═══
        //   🔴 **为什么必须测**：⭐ `evt_*` 是**单事件口** ⇒ ⭐ FSM 与轴事件**必然**要抢出口
        //      ⇒ ⭐ 若实现"忙就丢" ⇒ 🔴 **拨弦被吞**（⭐ 手感上就是"这一拨没响"）
        //   ✅ 正确做法（⭐ 与 `pending_pluck` **同级**）：⭐ **锁一拍**，
        //      ⭐ 等出口空下来**再发**（⭐ 本用例同时验证"同拍按下的轴也算进这一拨"）
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd2, 2'd0, 12'd600);
        axis_evt(4'd5, 2'd0, 12'd600);
        repeat (2) @(posedge clk);
        //  ⭐ 同拍：⭐ 按轴 7（ON）＋ 拨弦（⭐ 同 `tb_play_mode_merge_collision` 的场景，⭐ 但多轴）
        @(negedge clk); axis = 4'd7; axis_kind = 2'd0; axis_valid = 1'b1;
                        pluck_valid = 1'b1; pluck_up = 1'b0;
        @(negedge clk); axis_valid = 1'b0; pluck_valid = 1'b0;
        repeat (12) @(posedge clk);
        ax_mask  = 16'd0;
        kinds_ok = 1'b1;
        for (ai = 0; ai < 3; ai = ai + 1) begin
            ax_mask = ax_mask | (16'd1 << events_axis[ai]);
            if (events_kind[ai] != 2'd2) kinds_ok = 1'b0;
        end
        chk("M10 pluck coinciding with an axis press loses nothing: axes {2,5,7} are ALL plucked",
            event_n == 3 && ax_mask == (16'h0004 | 16'h0020 | 16'h0080) && kinds_ok);

        //  ═══ ⭐⭐ 新增：⭐ **FSM 进行中来的第二拨 ⇒ 锁住、收尾后再起一轮** ═══
        //   🔴 **为什么必须测**：⭐ 和弦要发 N 拍 ⇒ ⚠️ 这 N 拍里**出口是满的**
        //      ⇒ ⭐ 若第二拨被丢 ⇒ 🔴 **连续拨弦会漏**（⭐ 与"逐拍发"这个改动**直接相关**）✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd1, 2'd0, 12'd600);
        axis_evt(4'd2, 2'd0, 12'd600);
        axis_evt(4'd3, 2'd0, 12'd600);
        repeat (2) @(posedge clk);
        @(negedge clk); pluck_valid = 1'b1;   // ⭐ 第 1 拨（⭐ 下一拍起连发 3 条）
        @(negedge clk); pluck_valid = 1'b1;   // ⭐ 第 2 拨 —— ⭐ 此刻 FSM 正在发第 1/2 条
        @(negedge clk); pluck_valid = 1'b0;
        repeat (16) @(posedge clk);
        chk("M11 a second pluck arriving DURING the chord FSM is latched, not lost (2 chords x 3 axes = 6)",
            event_n == 6
            && events_kind[0] == 2'd2 && events_kind[1] == 2'd2 && events_kind[2] == 2'd2
            && events_kind[3] == 2'd2 && events_kind[4] == 2'd2 && events_kind[5] == 2'd2);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-15（⭐ **新增**）：⭐ **脏位（stale `held_mask` bit）** ⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **缺陷（⭐ 逐行证据，⛔ 不是推断）**：
        //     · ⭐ `event_extract.v:396-403`：⭐ `enable_i === 1'b0` 时
        //       **静默清 `key_on[]`/`refr[]`，⛔ 不发任何事件** ✅
        //     · ⭐ `top.v:4468` 的 `.enable_i(at_en_ready)`，
        //       而 `at_en_ready = at_done_dly[15]`（⭐ `top.v:2985-2991`）
        //     · ⭐ 串口 `'T'`（重 tare）⇒ `calib_autotare.v:310-321` 回 `ST_SWEEP`
        //       ⇒ `done_o` 落 0 ⇒ ⭐ `at_en_ready` 落 0 ✅
        //     ⇒ 🔴 **`'T'` 期间【按住的】任何轴**：⭐ 它的 `KIND_OFF` **永远不会来**
        //        （⭐ `key_on[]` 已被清 ⇒ 松手分支 `:437-438` 根本不进）
        //     ⇒ ⭐ 而本模块的 `held_mask` **只由 `KIND_OFF` 清**（⭐ RTL `:188-189`）
        //     ⇒ 🔴 **`held_mask` 里留下一个【永久脏位】**（⭐ 直到复位）✅
        //  🔴 **后果**：⭐ 一次拨弦 ⇒ 发 `popcount(held_mask)` 条 `PLUCK`
        //     ⇒ ⭐ **"一次拨弦出两个音"**（⭐ 100% 复现，⭐ 用户上板症状）✅
        //     ⚠️ ⭐ **本判据在 ⑥ 工作区版上【必红】**（⭐ 会数到 2 条）✅
        //  ⭐ **激励序列（⭐ 最小复现）**：
        //     ① 真实按下轴 2 ＋ 轴 9（⭐ 两个都进 `held_mask`）
        //     ② ⭐ **`enable_i` 掉沿**（⭐ 这里用 `axis_clr` 一拍建模；
        //        真实现场是 `'T'` ⇒ `at_en_ready` 落 0）⇒ ⭐ `held_mask` 应被清空
        //     ③ `enable_i` 回 1 ⇒ ⭐ `event_extract` 对**仍按着的**轴 9 重发 ON
        //        （⭐ `key_on` 已清 ⇒ `key_on==0 && pos>=TRIG_TH` ⇒ 1 帧内自愈）
        //     ④ 轴 2 的松手发生在 `enable_i=0` **期间** ⇒ ⭐ **OFF 永远不来**
        //        ⇒ ⭐ 这里**故意不发** `axis_evt(2, OFF)` —— ⭐ 这就是脏位的来源
        //     ⑤ 拨一次
        //     ⑥ ⭐ **断言：恰好 1 条，且必须是【仍按着的轴 9】**
        //        🔴 修复前：`held_mask = {2,9}` ⇒ FSM 先发**最低置位轴 2**（脏位）
        //           ⇒ ⭐ 数到 **2** ⇒ **必红** ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd2, 2'd0, 12'd900);            // ⭐ ① 轴 2（⭐ 它的 OFF 会被 `'T'` 吞掉）
        axis_evt(4'd9, 2'd0, 12'd800);            // ⭐ ① 轴 9（⭐ 全程按住 ⇒ 这一拨只该响它）
        repeat (2) @(posedge clk);
        chk("M12 setup: two axes held, selection alone is silent", event_n == 0);
        //  ⭐ ② `enable_i` 的【掉沿】—— ⭐ `top.v` 把它引成 `axis_clr_i`
        @(negedge clk); axis_clr = 1'b1;
        @(negedge clk); axis_clr = 1'b0;
        repeat (2) @(posedge clk);
        //  ⭐ ③ 使能恢复 ⇒ 仍按着的轴 9 在 1 帧内自愈重发 ON
        axis_evt(4'd9, 2'd0, 12'd800);
        repeat (2) @(posedge clk);
        //  ⭐ ④ 轴 2 已松手，但它的 OFF 被吞了 ⇒ ⛔ 这里不发 OFF（⭐ 脏位留在 `held_mask`）
        pluck_evt(1'b0);                          // ⭐ ⑤ 拨一次
        repeat (8) @(posedge clk);
        chk("M12 ONE pluck with a stale held_mask bit emits EXACTLY ONE event, for the axis still held (9)",
            event_n == 1 && events_kind[0] == 2'd2 && events_axis[0] == 4'd9);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-15（⭐ **缝合 STITCHER**）：⭐ 鹰眼第二轮抓到的
        //     **3 个缺陷**的**能红判据**（⭐ H1 / H2 / H3 / H4 / H5 ＋ 缺陷 3）⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  📌 **为什么要新加这些**：⭐ 本 tb 原来**只测"轴事件在 FSM 窗口【外】"**
        //     ⇒ 🔴 于是下面三件事**全都没有覆盖**：
        //        · ⭐ 轴事件落在 FSM 窗口**内**（⭐ 掩盖了缺陷 1）
        //        · ⭐ `axis_clr_i` 的**优先级**（⭐ 掩盖了缺陷 2 的两半）
        //        · ⭐ `axis_clr_i` 与 FSM **同拍**（⭐ 掩盖了缺陷 2 的"脏快照"）
        //     ⇒ ⭐ 每一条都写了"**能红**"实证（⭐ 见交付报告）✅

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ H1（🔴 **补空洞**）：⭐ **轴事件落在拨弦 FSM 窗口内**
        //     ⛔ 不许为【已松开的轴】发 `PLUCK` ✅
        //  ───────────────────────────────────────────────────────────────────
        //  🔴 **原空洞**：⭐ 本 tb **从没有**在 FSM 窗口内插过轴事件
        //     ⇒ 🔴 **掩盖了缺陷 1**（⭐ `pluck_todo` 是拨弦那一拍的**快照**，
        //        而 OFF 分支**只清 `held_mask`**、⛔ 不清 `pluck_todo`）✅
        //  ⭐ **序列**：⭐ 按住 {1,2,3} ⇒ 拨弦 ⇒ ⭐ 在第 1 条 `PLUCK` 与第 2 条之间
        //     插一条 `axis_evt(2, OFF)` ⇒ ⭐ 断言：
        //     ① ⭐ 事件数 = **2**（⭐ 只有轴 1 与轴 3）
        //     ② ⭐ 事件轴 = **{1,3}** ⇒ ⭐ **已松的轴 2 一条都不出**
        //        🔴 修复前：⭐ FSM 轮到轴 2 时**仍会发 `PLUCK`** ⇒ ⭐ 数到 **3** 条、轴含 2
        //        ⇒ 🔴 而 `keyboard_held[2]` 被置 1、⭐ 它的 `KIND_OFF` **已经用掉了**
        //        ⇒ 🔴 **永远等不到配对 OFF ⇒ 挂音**（⭐ 这正是缺陷 1 的后果）✅
        //  📌 **顺带钉住轴顺序（⭐ H5）**：⭐ 断言 `events_axis[0]==1 && [1]==3`
        //     ⇒ ⭐ 把"**最低位置位优先**"写成**契约**（⭐ RTL 就是这么实现的：
        //        `pluck_pick` 的 for 循环取**第一个**置位轴）✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd1, 2'd0, 12'd700);
        axis_evt(4'd2, 2'd0, 12'd700);
        axis_evt(4'd3, 2'd0, 12'd700);
        repeat (2) @(posedge clk);
        @(negedge clk); pluck_valid = 1'b1;                        // ⭐ 拨弦
        @(negedge clk); pluck_valid = 1'b0;                        // ⭐ 上一拍已发 PLUCK(轴 1)
                        axis = 4'd2; axis_kind = 2'd1; axis_valid = 1'b1;   // ⭐ 同拍插 OFF(2)
        @(negedge clk); axis_valid = 1'b0;
        repeat (8) @(posedge clk);
        chk("H1 axis released INSIDE the pluck FSM: 2 PLUCK events, axes {1,3}, none for released axis 2",
            event_n == 2
            && events_kind[0] == 2'd2 && events_kind[1] == 2'd2
            && events_axis[0] == 4'd1 && events_axis[1] == 4'd3);

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ H2a（🔴 **补空洞**）：⭐ `axis_clr_i` 与 `axis_evt(9,ON)` **同拍**
        //     ⇒ ⭐ 掉沿那一拍的**新 ON 必须赢**（⭐ 随后拨弦恰好 1 条、`axis==9`）✅
        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ **依据**：⭐ `held_mask <= 0` 与 `held_mask[9] <= 1` 是**非阻塞**赋值
        //     ⇒ ⭐ 同一拍对**同一位**的后一次赋值**胜出**；⭐ 其余位被清 ✅
        //  📌 本用例在修复前后**都绿**（⭐ 它守的是**既有**的优先级语义，⛔ 不是缺陷本身）——
        //     ⭐ 真正**能红**的那一半是 H2b ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd3, 2'd0, 12'd900);            // ⭐ 先按一个轴（⭐ 它应被掉沿清掉）
        repeat (2) @(posedge clk);
        @(negedge clk); axis_clr = 1'b1; axis = 4'd9; axis_kind = 2'd0; axis_valid = 1'b1;
        @(negedge clk); axis_clr = 1'b0; axis_valid = 1'b0;
        repeat (2) @(posedge clk);
        pluck_evt(1'b0);
        repeat (8) @(posedge clk);
        chk("H2a axis_clr + axis_evt(9,ON) same cycle: fresh ON wins, next pluck = 1 event, axis 9",
            event_n == 1 && events_kind[0] == 2'd2 && events_axis[0] == 4'd9);

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ H2b（🔴 **能红**）：⭐ 掉沿那拍**同拍来一条拨弦**
        //     ⇒ ⛔ 不许用**清零前的 `held_mask`** 起跑一轮 ✅
        //  ───────────────────────────────────────────────────────────────────
        //  🔴 **缺陷 2 的另一半**：⭐ `pluck_begin` **不屏蔽 `axis_clr_i`** ✅
        //     ⚠️ 非阻塞赋值 ⇒ ⭐ 掉沿那一拍 `held_mask` **还是旧值**（⭐ 含"脏"轴）
        //     ⇒ 🔴 拨弦会按**脏快照**发 `PLUCK` ✅
        //  ⭐ **序列**：⭐ 按住 3 ⇒ 拨弦（⭐ `held_mask={3}`、`keyboard_held[3]=1`）
        //     ⇒ ⭐ 下一拍**同拍**给 `axis_clr` ＋ `pluck_valid`
        //     ⇒ ⭐ 断言：**一条 `PLUCK` 都不许出**；⭐ 只有补 OFF FSM 那**1 条 `OFF(3)`**
        //        （⭐ 因为掉沿后 `held_mask` 已空 ⇒ ⭐ "没轴按住 ⇒ 没有音可触发"）✅
        //  🔴 修复前：⭐ 会先发 `PLUCK(3)`（脏快照）⇒ ⭐ 数到 **2** 条 ⇒ **必红** ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd3, 2'd0, 12'd900);            // ⭐ 按住轴 3
        pluck_evt(1'b0);                          // ⭐ 拨响（⭐ `keyboard_held[3]=1`）
        repeat (4) @(posedge clk);
        event_n = 0;                              // ⭐ 只看这一段
        @(negedge clk); axis_clr = 1'b1; pluck_valid = 1'b1;   // ⭐ 同拍：掉沿 ＋ 拨弦
        @(negedge clk); axis_clr = 1'b0;                       // ⭐ 拨弦保持第二拍
        @(negedge clk); pluck_valid = 1'b0;
        repeat (8) @(posedge clk);
        count_kinds;
        chk("H2b pluck in the SAME cycle as axis_clr: 0 PLUCK from the stale mask, only recovery OFF(3)",
            event_n == 1 && cnt_pluck == 0
            && events_kind[0] == 2'd1 && events_axis[0] == 4'd3);

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ H3（🔴 **补空洞**）：⭐ `axis_clr_i` 与 FSM **同拍**
        //     ⇒ ⛔ 不许为**脏快照**发事件 ✅
        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ **序列**：⭐ 按住 {1,2,3} ⇒ 拨弦 ⇒ ⭐ 第 1 条 `PLUCK(1)` 之后立刻 `axis_clr`
        //     ⇒ ⭐ 断言：⭐ **`PLUCK` 总数恰好 1**（⭐ 只有轴 1）
        //        ＋ ⭐ 补 OFF FSM 补出**恰好 1 条 `OFF(1)`**（⭐ 轴 1 已响 ⇒ 缺陷 3 的修法）✅
        //  🔴 修复前（⭐ 不清 `pluck_run`/`pluck_todo`）：⭐ FSM 会**继续**发 `PLUCK(2)`、`PLUCK(3)`
        //     ⇒ ⭐ `PLUCK` 总数 **3** ⇒ **必红** ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd1, 2'd0, 12'd700);
        axis_evt(4'd2, 2'd0, 12'd700);
        axis_evt(4'd3, 2'd0, 12'd700);
        repeat (2) @(posedge clk);
        @(negedge clk); pluck_valid = 1'b1;
        @(negedge clk); pluck_valid = 1'b0; axis_clr = 1'b1;   // ⭐ 上一拍已发 PLUCK(1)
        @(negedge clk); axis_clr = 1'b0;
        repeat (8) @(posedge clk);
        count_kinds;
        chk("H3 axis_clr while the chord FSM runs: no stale PLUCK (1 PLUCK axis 1) + recovery OFF(1)",
            event_n == 2 && cnt_pluck == 1
            && events_kind[0] == 2'd2 && events_axis[0] == 4'd1
            && events_kind[1] == 2'd1 && events_axis[1] == 4'd1);

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ 缺陷 3（🔴 **能红**）：⭐ `axis_clr` 掉沿 ⇒ **`keyboard_held` 逐拍补 OFF**
        //     ⇒ ⛔ 不许出现"**永久挂音**" ✅
        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ **忠实复刻生产序列**（⭐ 见 RTL 端口注释里的逐行证据）：
        //     ① ⭐ 按住轴 5 ⇒ 拨响（⭐ `keyboard_held[5]=1`）
        //     ② ⭐ 按 `'T'` ⇒ `at_en_ready` 落 ⇒ ⭐ 这里用 `axis_clr` **一拍**建模
        //     ③ 🔴 **使能为 0 期间松开轴 5** ⇒ ⭐ `event_extract` 的 `key_on[5]` 已被清
        //        ⇒ ⭐ **它不发 OFF**（⭐ 所以这里**故意不发** `axis_evt(5,OFF)`）
        //     ④ ⭐ 使能回来后 `pos<TRIG_TH` ⇒ 🔴 **自愈 ON 也不发**
        //        ⇒ ⭐ `keyboard_held[5]` **永久为 1**、🔴 **那条 voice 永久挂音** ✅
        //  ⭐ **断言**：⭐ 掉沿后**恰好 1 条**事件，⭐ 且必须是 **`OFF(5)`**
        //     （⭐ 即"补 OFF FSM 把那条响着的 voice 放掉了"）✅
        //  🔴 **修复前**（⭐ 只清 `held_mask`、⛔ 不管 `keyboard_held`）：⭐ **0 条** ⇒ **必红** ✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd5, 2'd0, 12'd850);            // ⭐ ① 按住轴 5
        pluck_evt(1'b0);                          // ⭐ ① 拨响 ⇒ keyboard_held[5] = 1
        repeat (4) @(posedge clk);
        event_n = 0;                              // ⭐ 只看掉沿之后
        @(negedge clk); axis_clr = 1'b1;          // ⭐ ② `'T'` ⇒ at_en_ready 落
        @(negedge clk); axis_clr = 1'b0;
        //  ⭐ ③④ 轴 5 在使能为 0 期间被松开 ⇒ ⛔ 不发 OFF、⛔ 也没有自愈 ON
        repeat (8) @(posedge clk);
        count_kinds;
        chk("DEFECT3 axis_clr drains keyboard_held: sounding axis 5 gets its OFF (no stuck voice)",
            event_n == 1 && events_kind[0] == 2'd1 && events_axis[0] == 4'd5);
        //  ⭐ **配对复检**：⭐ 补 OFF 之后，⭐ 该轴**重新**按 + 拨 ⇒ ⭐ 仍是一对一（⭐ 没漏、没多）
        axis_evt(4'd5, 2'd0, 12'd850);
        pluck_evt(1'b0);
        repeat (8) @(posedge clk);
        axis_evt(4'd5, 2'd1, 12'd0);
        repeat (6) @(posedge clk);
        count_kinds;
        chk("DEFECT3b after the drain, axis 5 re-press/pluck/release is still paired (1 PLUCK, 2 OFF)",
            event_n == 3 && cnt_pluck == 1 && cnt_off == 2
            && events_kind[1] == 2'd2 && events_axis[1] == 4'd5
            && events_kind[2] == 2'd1 && events_axis[2] == 4'd5);

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ H4（⭐ 边界）：⭐ `held_mask == 0` 的**零轴拨弦** ⇒ ⭐ 一条事件都不出 ✅
        //  ───────────────────────────────────────────────────────────────────
        //  📌 **依据**：⭐ 拨弦时一个轴都没按住 ⇒ ⭐ **没有音可触发**
        //     ⇒ ⭐ 与旧版一致（⭐ 旧版靠 `pluck_found == 0` 丢掉这次请求）✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        pluck_evt(1'b0);
        repeat (8) @(posedge clk);
        chk("H4 BOUNDARY a pluck with NO axis held emits nothing at all (no phantom note)",
            event_n == 0);

        //  ───────────────────────────────────────────────────────────────────
        //  ⭐ H5（⭐ 契约）：⭐ **轴顺序 = 最低位置位优先** ✅
        //  ───────────────────────────────────────────────────────────────────
        //  📌 **为什么把它写成契约**：⭐ RTL 的实现就是"取 `pluck_todo` 里**最低**的那一位"
        //     （⭐ `pluck_pick` 的 for 循环**命中即停**）⇒ ⭐ 顺序是**确定的**、⭐ 不是"任意"
        //     ⇒ ⭐ 把它钉住，⛔ 免得以后有人把仲裁改成"高优先"或"轮转"而**无人发现** ✅
        //  📌 ⚠️ **注意**：⭐ 这是**本模块的**契约；⭐ 下游 `note_manager` 按轴各自分配 voice
        //     ⇒ ⭐ 顺序**不影响音高**，⭐ 只影响"同一拍里谁先起音"（⭐ 听感上无差别）✅
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        axis_clr = 1'b0;
        event_n = 0;
        fretboard_mode = 1'b1;
        axis_evt(4'd9, 2'd0, 12'd700);            // ⭐ 故意【倒序】按下：9 ⇒ 5 ⇒ 2
        axis_evt(4'd5, 2'd0, 12'd700);
        axis_evt(4'd2, 2'd0, 12'd700);
        repeat (2) @(posedge clk);
        pluck_evt(1'b0);
        repeat (10) @(posedge clk);
        chk("H5 CONTRACT pluck FSM emits ascending axis order (lowest set bit first): 2, 5, 9",
            event_n == 3
            && events_kind[0] == 2'd2 && events_axis[0] == 4'd2
            && events_kind[1] == 2'd2 && events_axis[1] == 4'd5
            && events_kind[2] == 2'd2 && events_axis[2] == 4'd9);

        if (errors == 0) $display("PASS: play-mode controller enforces keyboard and fretboard semantics");
        else $fatal(1, "FAIL: play_mode_ctrl has %0d error(s)", errors);
        $finish;
    end
    //  ⭐ 2026-10-15：⭐ 超时预算 **10000 → 40000 ns** —— ⭐ 新增了两个边界用例
    //     （⭐ 16 轴：⭐ 16 次按下 ＋ 16 拍 FSM ＋ 16 次松开 ⇒ ⭐ 约 90 拍 ＝ 1800 ns）✅
    //  ⭐⭐ 2026-10-15（⭐ 缝合 STITCHER）：⭐ **40000 → 70000 ns** ✅
    //     🔴 **为什么**：⭐ 又加了 **7 个**新用例（⭐ H1 / H2a / H2b / H3 / 缺陷3 ×2 / H4 / H5）
    //        ⇒ ⭐ 约 **150 拍 ＝ 3000 ns**；⭐ 而 `#40000` 是**绝对**超时
    //        ⇒ ⚠️ 留足余量（⭐ 本项目并行回归曾因**预算太紧**假超时 ⇒ 见 `AGENTS.md`）✅
    initial begin #70000; $fatal(1, "FAIL: tb_play_mode_ctrl timeout"); end
endmodule
