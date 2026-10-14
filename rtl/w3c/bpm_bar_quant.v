`timescale 1ns/1ps
// bpm_bar_quant.v -- align a MANUAL tempo change to the next bar line.
//
//   ⭐ 2026-10-14（用户要求）：⭐ **手动 `'Q'` 改 BPM 要落在小节线上** ✅
//
//   🔴 **为什么单独一个模块**（⛔ 不塞进 `play_seq`）：
//      · ⭐ `play_seq` 的 `bpm_load_i` 契约是"**立即写寄存器**"（⭐ 已有 tb 覆盖）
//        ⇒ ⚠️ 在那里改语义 ⇒ 🔴 必须改 `tb_bpm_entry` / `tb_play_seq` 的既有判据
//      · ⭐ 本模块只做"**延迟到小节线**"这一件事 ⇒ ⭐ 判据可以写得极简且完备 ✅
//      · ⭐ 且 `play_seq` **一行不改** ⇒ ⭐ 它的全部既有判据继续有效 ✅
//
//   ⭐⭐ **曲谱 tempo（`kind=2`）【不经过】本模块** ✅
//      🔴 为什么：⭐ 曲谱作者**本来就把它排在小节线上**
//         ⇒ ⚠️ 再对齐一次 ⇒ 🔴 **整首曲子的变速被推后一个小节** ✅
//      ⇒ ⭐ 本模块**只接串口 `'Q'` 那一路**（⭐ `top.v` 里接线即证明 ✅）
//
//   ⭐ 语义（⭐ 与判据一一对应）：
//      ① `set_i` 到达 ⇒ ⭐ **只挂起**（`load_o` 保持 0）
//      ② `bar_start_i` 到达 ＋ 有挂起 ⇒ ⭐ `load_o` **出【一拍】**，`val_o` = 挂起值
//      ③ 小节线之前再来 `set_i` ⇒ ⭐ **覆盖挂起值**（⭐ 后到者胜 ✅），⭐ 仍只出一次
//      ④ `set_i` 与 `bar_start_i` **同拍** ⇒ ⭐ `set_i` 优先（⭐ 挂起到【下一个】小节）
//         📌 窗口 = 1/3840 拍 ⇒ ⭐ 概率 ~0.03%，⚠️ 且行为仍正确（只是晚一小节）✅
//      ⑤ 复位 ⇒ ⭐ 清挂起（⛔ 不遗留）
//
//   📌 **不会永久悬挂的依据**：⭐ `top.v` 的 `beat_gen` 是 **free-running**
//      （`run_i = 1'b1` ⇒ `bar_start_o` 周期性必然到来 ✅）
//      ⇒ ⚠️ 所以本模块**不需要**超时兜底（⭐ 少一个 29 位计数器 ✅）
//
//   ⛔ 纪律：Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz
//   ⚠️ 本文件必须【无 BOM】（⭐ 见 `tools/check_no_bom.ps1`）
`default_nettype none

module bpm_bar_quant (
    input  wire       clk_i,
    input  wire       rst_n_i,

    // ⭐ 手动改速请求（⭐ 单拍脉冲，⭐ 与 `val_i` 同拍 —— 与 `play_seq.bpm_load_i` 同约定）
    input  wire       set_i,
    input  wire [7:0] val_i,

    // ⭐ 小节起点（⭐ `beat_gen.bar_start_o`，单拍脉冲）
    input  wire       bar_start_i,

    // ⭐ 对齐后的"装载"脉冲（⭐ → `play_seq.bpm_load_i`）
    output reg        load_o,
    output reg  [7:0] val_o,        // ⭐ 与 `load_o` **同拍有效**（⭐ 与 `val_i` 同约定）

    // ⭐ 可观测（`K-106`：⭐ "挂着还没生效"必须看得见，⛔ 不许静默）
    output reg        pending_o
);
    //  ⭐ 挂起值。⚠️ 它**只被本模块自己的判据读**（⭐ 见下方 `bar_start_i` 分支）
    //     ⇒ ⭐ 综合**不可能**把它剪掉（⭐ 与"纯观测线"不同 ✅）
    reg [7:0] pend_q;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            pend_q    <= 8'd0;
            pending_o <= 1'b0;
            load_o    <= 1'b0;
            val_o     <= 8'd0;
        end else begin
            //  ⭐ `load_o` 是**单拍脉冲** ⇒ ⭐ 默认清零（⭐ 与 `pluck_valid_o` 同一套路）
            load_o <= 1'b0;

            if (set_i === 1'b1) begin
                //  ⭐ 判据 ①：⭐ **只挂起**，⛔ 本拍**不出** `load_o` ✅
                //  ⭐ 判据 ③：⭐ 再来一次 ⇒ ⭐ 覆盖（⭐ 不需要"已有挂起"的条件 ✅）
                pend_q    <= val_i;
                pending_o <= 1'b1;
            end else if ((pending_o === 1'b1) && (bar_start_i === 1'b1)) begin
                //  ⭐ 判据 ②：⭐ 到小节线 ⇒ ⭐ 出一拍 ＋ 清挂起 ✅
                //     📌 `val_o` 与 `load_o` **同一拍锁存** ⇒ ⭐ 下游看到的是**配对的**值 ✅
                val_o     <= pend_q;
                load_o    <= 1'b1;
                pending_o <= 1'b0;
            end
            //  ⭐ 判据 ⑤：⭐ 复位分支已在上面清 `pending_o`（⭐ `pend_q` 无需清 ——
            //     它只在 `pending_o` 为真时被读 ✅）
        end
    end
endmodule

`default_nettype wire
