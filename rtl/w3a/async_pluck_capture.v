`timescale 1ns/1ps
// T15: LM393 UP/DOWN asynchronous outputs -> one synchronous pluck event.
// The first synchronized edge is accepted immediately; the refractory period
// only rejects later edges.  A simultaneous UP/DOWN edge is deterministically UP.
//
// ⭐⭐ 2026-10-15：⭐ **删除【回中门控】**（`armed_q`）—— ⭐ 用户明确反对额外限制 ✅
// ---------------------------------------------------------------------------
// 📌 **背景**：⭐ 该门控是**同一天早些时候**为"下拨一次听到两个音"加的
//    （⭐ 当时判定的根因是"回中途中过冲越过 `UP` 阈值"）。⭐ 现在**已定量否证** ✅
//
// 🔴 **否证依据（⭐ 硬件实测，⛔ 不是推断）** —— `files/10-硬件/右手板方案.md`：
//    | 量 | 值 | 出处 |
//    |---|---|---|
//    | ⭐ 摇杆**静止（回中）** | ⭐ **1.737 V** | `:403` |
//    | ⭐ `DOWN_REF`（前推阈值） | ⭐ **1.24 V** | `:422` |
//    | ⭐ `UP_REF`（后拉阈值）   | ⭐ **2.24 V** | `:421` |
//    | ⭐ 迟滞窗口 `ΔV_迟滞`      | ⭐ **17.5 / 18.6 mV** | `:442-443` |
//    ⇒ ⭐ **静止点落在两个阈值【之间】** ⇒ ⭐ 静止时 `UP`/`DOWN` **两路都低** ✓
//    ⇒ 🔴 **要制造"回摆过冲"事件，`PICK` 必须从【静止点】再上冲
//       `2.24 - 1.737 = 503 mV` 以上**（⭐ 相对**前推触发点** 0.116 V 则是 **2.12 V**）
//       —— ⭐ 而实测迟滞窗口只有 **18.6 mV**（⭐ 它只负责"阈值附近不抖"，
//          ⭐ **不提供**任何"越过静止点再反冲 503 mV"的能量来源）✅
//    ⇒ ⭐ 一次前推行程的**位移总量**只有 `1.737 - 0.116 = 1.62 V`，
//       ⭐ 弹簧回中是**单调回到静止点**的机械过程
//       ⇒ 🔴 **"回中途中反冲 503 mV（= 后拉行程的 35%）"物理上不存在** ✅
//    ⇒ ⭐ 于是该门控要挡的**故障序列根本不存在** ⇒ ⭐ 它属于
//       **"给真拨弦加额外限制"**那一类（⭐ 用户明确反对）✗
//
// 🔴 **它还带一个真实风险**：⭐ `armed_q` 只在 `both_low` 时重新武装
//    ⇒ ⚠️ 若摇杆**停在中位以外**（⭐ 阈值未调好 / 装配偏 / 温度漂移）
//       ⇒ 🔴 **`armed_q` 永久卡死 ⇒ 上电后只有第一下响** ✅
//
// 🔴 **"一次下拨出两个音"的真因已另行定位（⭐ 本文件无关）**：
//    ⭐ `event_extract` 在 `enable_i=0` 时静默清 `key_on[]`
//    ⇒ ⭐ `play_mode_ctrl.held_mask` 留**脏位** ⇒ ⭐ 一次拨弦发 N 条
//    （⭐ 修法见 `rtl/w3a/play_mode_ctrl.v` 的 `axis_clr_i` 端口注释）✅
//
// ✅ **本文件现在的语义**（⭐ 回到门控之前）：⭐ 同步后的**第一个沿立即接受**，
//    ⭐ 之后由 `REFRACT_CYC`（`top.v` 实参 30 ms）挡极近抖动；
//    ⭐ `UP`/`DOWN` 同拍时**确定性地判 `UP`** ✅
// 📌 `armed_o` 保留**端口**（⭐ `top.v:4526-4527` 已接 `syn_keep`，⭐ 无害），
//    ⚠️ 但门控没了 ⇒ ⭐ 它**失去语义** ⇒ ⭐ 恒 `1'b1`（⭐ 见声明处注释）✅
// 📌 `both_low_o` 保留且**仍有意义**：⭐ 它就是"两路都低 = 摇杆在中位"的**原始观测量** ✅
`default_nettype none

module async_pluck_capture #(
    parameter integer REFRACT_CYC = 2_500_000
) (
    input  wire clk_i,
    input  wire rst_n_i,
    input  wire pluck_up_async_i,
    input  wire pluck_down_async_i,
    output reg  pluck_valid_o,
    output reg  pluck_up_o,
    //  ⭐ 可观测（`K-106`）：⚠️ 没有它，"为什么这一拨没响"就只能靠猜
    //      （⭐ 分不清"被节流"与"沿没来"）✅
    //  ⚠️ **2026-10-15 更新**：⭐ `armed_o` 的门控语义已随门控一起删除
    //      ⇒ ⭐ 它现在**恒 `1'b1`**（⭐ 见实现处注释）；
    //      ⭐ `both_low_o` **仍有意义** = 摇杆在中位的原始观测量 ✅
    output wire armed_o,
    output wire both_low_o
);
    reg up_ff1, up_ff2, down_ff1, down_ff2;
    reg up_prev, down_prev;
    reg [31:0] refractory_q;
    //  ⭐⭐ 2026-10-15：⭐ **`armed_q`（回中门控）已【整个删除】** ✅
    //     🔴 依据见文件头（⭐ "回中反冲 503 mV 物理上不存在" + "卡死风险"）✅
    //     ⛔ 本模块**不再对真拨弦加任何位置限制**：
    //        ⭐ 唯一的节流是 `refractory_q`（⭐ 挡极近抖动，⭐ 不是位置门控）✅

    wire up_rise   = up_ff2   && !up_prev;
    wire down_rise = down_ff2 && !down_prev;
    //  ⭐ "两路都低" = 摇杆在中位（⭐ 现在**只是观测量**，⛔ 不参与判决）
    wire both_low  = !up_ff2 && !down_ff2;

    //  ⚠️ **`armed_o` 已失去语义**（⭐ 门控删了 ⇒ 没有"武装"这个概念了）：
    //     ⭐ 恒 `1'b1` ⇒ ⭐ 语义 = "本模块**随时**接受下一个沿（⭐ 只要不在 refractory）"✅
    //     📌 **保留端口**是因为 `top.v:4526-4527` 已把它接进 `syn_keep`
    //        （⭐ 动它就要动 `top.v`，⭐ 而本任务只要求删门控）✅
    //     📌 **诊断价值**：⭐ "为什么这一拨没响"现在只剩**一个**原因 = `refractory_q`
    //        （⭐ 要看它需要另接探针，⛔ 本模块没引出）✅
    assign armed_o    = 1'b1;
    assign both_low_o = both_low;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            up_ff1        <= 1'b0;
            up_ff2        <= 1'b0;
            down_ff1      <= 1'b0;
            down_ff2      <= 1'b0;
            up_prev       <= 1'b0;
            down_prev     <= 1'b0;
            refractory_q  <= 32'd0;
            pluck_valid_o <= 1'b0;
            pluck_up_o    <= 1'b0;
        end else begin
            up_ff1    <= pluck_up_async_i;
            up_ff2    <= up_ff1;
            down_ff1  <= pluck_down_async_i;
            down_ff2  <= down_ff1;
            up_prev   <= up_ff2;
            down_prev <= down_ff2;

            pluck_valid_o <= 1'b0;

            //  ⭐ 唯一节流 = refractory（⭐ 门控已删，⛔ 不看位置）✅
            if (refractory_q != 32'd0) begin
                refractory_q <= refractory_q - 32'd1;
            end else if (up_rise || down_rise) begin
                pluck_valid_o <= 1'b1;
                pluck_up_o    <= up_rise; // UP wins if both edges are present.
                refractory_q  <= REFRACT_CYC;
            end
        end
    end
endmodule

`default_nettype wire
