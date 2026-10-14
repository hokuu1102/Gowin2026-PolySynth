`timescale 1ns/1ps
// T15 semantic controller.  It deliberately owns the distinction between
// selection events and playing events so downstream voice allocation receives
// one unambiguous note_on/note_off/pluck stream.
`default_nettype none

module play_mode_ctrl #(
    parameter integer AXIS_W  = 4,
    parameter integer DEPTH_W = 12
) (
    input  wire                   clk_i,
    input  wire                   rst_n_i,
    input  wire                   fretboard_mode_i, // 0=keyboard, 1=fretboard

    input  wire                   axis_valid_i,
    input  wire [AXIS_W-1:0]      axis_i,
    input  wire [1:0]             axis_kind_i,      // 0=on, 1=off
    input  wire [DEPTH_W-1:0]     axis_depth_i,
    input  wire                   pluck_valid_i,
    input  wire                   pluck_up_i,       // direction retained at capture seam

    output reg                    evt_valid_o,
    output reg  [AXIS_W-1:0]      evt_axis_o,
    output reg  [1:0]             evt_kind_o,       // 0=on, 1=off, 2=pluck
    output reg  [DEPTH_W-1:0]     evt_depth_o
);
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_PLUCK = 2'd2;

    reg                  selected_valid;
    reg [AXIS_W-1:0]     selected_axis;
    reg [DEPTH_W-1:0]    selected_depth;
    reg                  gate_valid;
    reg [AXIS_W-1:0]     gate_axis;
    localparam integer AXIS_COUNT = (1 << AXIS_W);
    reg [AXIS_COUNT-1:0] keyboard_held;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            selected_valid <= 1'b0;
            selected_axis  <= {AXIS_W{1'b0}};
            selected_depth <= {DEPTH_W{1'b0}};
            gate_valid     <= 1'b0;
            gate_axis      <= {AXIS_W{1'b0}};
            keyboard_held  <= {AXIS_COUNT{1'b0}};
            evt_valid_o    <= 1'b0;
            evt_axis_o     <= {AXIS_W{1'b0}};
            evt_kind_o     <= KIND_ON;
            evt_depth_o    <= {DEPTH_W{1'b0}};
        end else begin
            evt_valid_o <= 1'b0;

            if (!fretboard_mode_i) begin
                // Keyboard: threshold crossing and release are directly musical.
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                    //  ⭐⭐ 2026-10-09（`P0-22`）：⭐ **键盘模式也必须维护"正在响的轴"** ✅
                    //   🔴 **原缺陷**：⭐ 键盘分支**从不写 `gate_valid`/`gate_axis`**
                    //      （⭐ 只有拨弦分支 :66-67 写）⇒ ⭐ 键盘模式下 `gate_valid` **恒 0** ✅
                    //      ⇒ 🔴 而指板模式下 OFF 事件的**唯一出口**是 `gate_valid && (axis_i == gate_axis)`
                    //      ⇒ ⭐ `gate_valid=0` 时**一个 OFF 都发不出去** ✅
                    //   🔴 **复现（⭐ 用户实测过的"挂音几分钟不停"）**：
                    //      · ⭐ 键盘模式按住一个键（⭐ `KIND_ON` ⇒ voice 起音）
                    //      · ⭐ 切到【指板】模式（⭐ `fretboard_mode_i=1`，⭐ 它是**运行期信号**：
                    //        `top.v` 的 `play_fretboard_mode = ~ui_mode_piano`
                    //        ⇒ 串口 `'A'` / 屏触摸控件 0 都能随时翻转 ⇒ ⛔ 不是编译期常量）
                    //        ⚠️ **2026-10-13 更正**：本行原写 *"切到 PIANO（`fretboard_mode_i=1`）"*
                    //           —— 🔴 **两处都错**：
                    //           ① ⭐ 极性反了：`fretboard_mode_i=1` 是**指板**，⛔ 不是 PIANO
                    //              （⭐ 端口注释就是 `0=keyboard, 1=fretboard` ✅）
                    //           ② ⭐ `BASS→GUITAR→PIANO→PAD` 是**音色循环**（`'I'`），
                    //              与**演奏模式**是两回事 —— ⚠️ 原文把两者混了 ✅
                    //        📌 挂音的机理不受影响：⭐ 关键是"键盘模式起音、切到指板后松键"
                    //           ⇒ ⭐ 指板分支要 `selected_axis`，⭐ 而键盘模式从没写过它 ✅
                    //      · ⭐ 松键 ⇒ ⭐ 指板分支走 `else if (axis_valid_i)`（⭐ `pluck_valid_i` 为 0）
                    //        ⇒ `axis_i == selected_axis` **不成立**（⭐ 键盘模式从没写过 `selected_axis`）
                    //        ⇒ `gate_valid(0) && …` 为假 ⇒ 🔴 `evt_valid_o` **一拍都不抬**
                    //        ⇒ ⭐ **下游永远收不到 `note_off` ⇒ 挂音** ✅
                    //   ✅ **修法**：⭐ 键盘模式按 `KIND_ON`/`KIND_OFF` 维护 `gate_valid`/`gate_axis`
                    //      ⇒ ⭐ 切到指板模式后，那个音**仍能被放掉** ✅
                    //   📌 **零回归**：⭐ 键盘分支在 `if/else if` 链**最前面**，⭐ 仍优先转发
                    //      ⇒ ⭐ 键盘模式的行为**完全不变**（⭐ 只是多了两个寄存器的影子状态）✅
                    if (axis_kind_i == KIND_ON) begin
                        keyboard_held[axis_i] <= 1'b1;
                        gate_valid <= 1'b1;
                        gate_axis  <= axis_i;
                    end else if (axis_kind_i == KIND_OFF) begin
                        keyboard_held[axis_i] <= 1'b0;
                        //  ⭐ 只在"放掉的正是正在响的那个"时清 ✅
                        if (axis_i == gate_axis) gate_valid <= 1'b0;
                    end
                end
            end else if (pluck_valid_i && selected_valid) begin
                // Fretboard: a pluck is the musical trigger. Direction has
                // already been resolved by async_pluck_capture (UP priority).
                evt_valid_o <= 1'b1;
                evt_axis_o  <= selected_axis;
                evt_kind_o  <= KIND_PLUCK;
                evt_depth_o <= selected_depth;
                gate_valid  <= 1'b1;
                gate_axis   <= selected_axis;
                keyboard_held[selected_axis] <= 1'b0;
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;
                    selected_depth <= axis_depth_i;
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    //  ⭐⭐ 2026-10-09（`P0-22`）：⭐ **换品后松键也要能放掉正在响的音** ✅
                    //   🔴 **原缺陷**：⭐ 原判据只看 `axis_i == gate_axis` ✅
                    //      ⚠️ 而 `gate_axis` **只在拨弦那一拍锁存**（⭐ 此后只有再次拨弦才更新）
                    //      ⇒ ⭐ 而 `selected_axis` 会随**每一次 `KIND_ON`** 更新 ✅
                    //   🔴 **复现（⭐ 吉他上极常见：滑品不重拨）**：
                    //      · ⭐ `axis_evt(6, ON)` ⇒ `selected_axis=6`
                    //      · ⭐ `pluck_evt` ⇒ evt `PLUCK axis=6`，⭐ `gate_axis=6`（⭐ voice 起音）
                    //      · ⭐ `axis_evt(9, ON)` ⇒ ⭐ `selected_axis=9`（⭐ 而 `gate_axis` 仍是 6）
                    //      · ⭐ `axis_evt(9, OFF)` ⇒ ⭐ `axis_i(9) == selected_axis(9)` ⇒ 清 `selected_valid`
                    //        ⚠️ 但 `gate_valid(1) && (9 == 6)` = 假 ⇒ 🔴 **不发 OFF**
                    //        ⇒ ⭐ **步骤②起的音永远不释放 ⇒ 挂音** ✅
                    //   ✅ **修法（⭐ 两条）**：
                    //      ① ⭐ 判据加 `|| (axis_i == selected_axis)` —— ⭐ 松开的正是"当前选中的轴"也算 ✅
                    //      ② ⭐ `evt_axis_o` 改成发 **`gate_axis`**（⭐ 即**正在响的那个轴**）
                    //         ⚠️ 原来发的是 `axis_i`（⭐ 被松开的轴）⇒ ⭐ 两者不等时会放错音 ✅
                    //   📌 **零回归证明**：⭐ 既有场景里 `axis_i == gate_axis`（⭐ 都是 6）
                    //      ⇒ ⭐ `evt_axis_o` 由 `axis_i` 改成 `gate_axis` **得到同一个值** ⇒ 判据不变 ✅
                    // Every keyboard-origin axis survives a mode change until
                    // its own OFF is forwarded, not only the last gate_axis.
                    if (keyboard_held[axis_i]) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o <= axis_i;
                        evt_kind_o <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        keyboard_held[axis_i] <= 1'b0;
                        if (axis_i == gate_axis) gate_valid <= 1'b0;
                    end else if (gate_valid && ((axis_i == gate_axis) || (axis_i == selected_axis))) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= gate_axis;    // ⭐ 释放【正在响】的那个轴
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
