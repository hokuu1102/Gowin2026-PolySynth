`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A7 · 相位累加器"只按 `phase_inc` 前进、⛔ 变调时不清零" 检查器
//
//   为什么需要它（`files/20-代码/已知问题与风险清单.md` `K-10`）：
//     DDS 变调的正确做法是**只改 `phase_inc`**。如果（图省事）在改音高时把 `phase_acc`
//     清零，波形就会**从 0 相位重新开始** ⇒ 听感上出现"咔哒"，而且**相位不连续**在
//     频谱上就是宽带杂散。赛题基础题点名"单音实时变调"，这一条是硬判据。
//
//   ⭐ 判据写成**不变量**（而不是"看它有没有变成 0"）：
//       每个 `tick` 之后，`phase_acc` 的增量必须**恰好等于**当时的 `phase_inc`
//       （模 2^W）。因为 `phase_inc` 可能与被检查的那一拍同时变化，
//       **旧值和新值都接受**；除此之外的任何增量（尤其是 0 或负回绕）都报违规。
//     ⇒ 这样不仅抓"清零"，也抓"复位式跳变/漏加/多加"。
//
//   `jump_ok`：⭐ **新音符分配**（voice 重新起音）时相位本来就该从头开始 ——
//       这类**合法跳变**由调用方在那一拍把 `jump_ok` 拉高，检查器跳过该拍。
//       ⚠️ 接线时请把它接到"这一次 tick 是合法的相位重启"那个条件上，
//       ⛔ 不要常量接 1（那等于把检查器关掉）。
//
//   ⚠️ 采样时序：`tick` 是单周期脉冲。检查器把 `tick` 打一拍（`tick_d`）**再取 `phase_acc`**，
//      这样取到的是"本拍更新之后"的值，与被测模块用阻塞还是非阻塞赋值无关。
//
//   用法：
//     chk_phase_advance #(.W(32), .NAME("voice0.phase_acc")) u_a7 (
//         .clk(clk), .rst_n(rst_n), .tick(tick_audio),
//         .acc(phase_acc), .inc(phase_inc), .jump_ok(note_restart),
//         .err_cnt(a7_err));
//
//   负向测试：变调那一拍把 `phase_acc` 清零（且 `jump_ok=0`）⇒ 必触发；`jump_ok=1` 时不报。
// ─────────────────────────────────────────────────────────────
module chk_phase_advance #(
    parameter integer W          = 32,
    parameter         NAME       = "phase_acc",
    parameter integer MAX_REPORT = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         tick,
    input  wire [W-1:0] acc,
    input  wire [W-1:0] inc,
    input  wire         jump_ok,
    output reg [31:0]   err_cnt
);
    reg [W-1:0] acc_p, inc_p;      // 上一次采样到的累加器 / 增量
    reg         tick_d, jump_ok_d;
    reg         started;
    integer     reported;
    reg [W-1:0] d_actual, d_expect_old, d_expect_new;

    initial begin
        acc_p = {W{1'b0}}; inc_p = {W{1'b0}};
        tick_d = 1'b0; jump_ok_d = 1'b0; started = 1'b0;
        reported = 0; err_cnt = 32'd0;
    end

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            tick_d = 1'b0; jump_ok_d = 1'b0; started = 1'b0;
            acc_p = acc; inc_p = inc;
        end else begin
            // ⚠️ 顺序很重要：**先用上一拍锁存的值判定，再更新锁存**。
            //    反过来的话，`jump_ok_d` 会被"tick 之后那一拍"的值覆盖，
            //    ⇒ 合法的相位重启（jump_ok=1 那一拍）会被误判成违规。
            if (tick_d === 1'b1) begin
                if (started !== 1'b1 || jump_ok_d === 1'b1) begin
                    // 第一拍（复位后的起点）与"合法的相位重启"不判
                end else begin
                    d_actual     = acc - acc_p;        // 模 2^W 自动回绕
                    d_expect_old = inc_p;              // 用旧增量
                    d_expect_new = inc;                // 用新增量
                    if (d_actual !== d_expect_old && d_actual !== d_expect_new) begin
                        err_cnt = err_cnt + 32'd1;
                        if (reported < MAX_REPORT) begin
                            reported = reported + 1;
                            $display("ERROR [A7] %0s 相位增量异常：实测 %0d，期望 %0d（旧 inc）或 %0d（新 inc）—— ⛔ 变调只许改 phase_inc，不许清零相位",
                                     NAME, d_actual, d_expect_old, d_expect_new);
                        end
                    end
                end
                acc_p   = acc;
                inc_p   = inc;
                started = 1'b1;
            end

            tick_d    = tick;          // 打一拍：上面取到的是"本拍更新后"的值
            jump_ok_d = jump_ok;
        end
    end
endmodule
