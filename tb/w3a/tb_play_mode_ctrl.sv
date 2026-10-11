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
    wire evt_valid;
    wire [3:0] evt_axis;
    wire [1:0] evt_kind;
    wire [11:0] evt_depth;
    integer errors = 0;
    integer event_n = 0;
    reg [3:0] events_axis [0:15];
    reg [1:0] events_kind [0:15];

    always #10 clk = ~clk;

    play_mode_ctrl dut (
        .clk_i(clk), .rst_n_i(rst_n), .fretboard_mode_i(fretboard_mode),
        .axis_valid_i(axis_valid), .axis_i(axis), .axis_kind_i(axis_kind), .axis_depth_i(axis_depth),
        .pluck_valid_i(pluck_valid), .pluck_up_i(pluck_up),
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
        event_n = event_n + 1;
    end

    initial begin
        fretboard_mode=1'b0; axis_valid=0; axis=0; axis_kind=0; axis_depth=0; pluck_valid=0; pluck_up=0;
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

        if (errors == 0) $display("PASS: play-mode controller enforces keyboard and fretboard semantics");
        else $fatal(1, "FAIL: play_mode_ctrl has %0d error(s)", errors);
        $finish;
    end
    initial begin #10000; $fatal(1, "FAIL: tb_play_mode_ctrl timeout"); end
endmodule
