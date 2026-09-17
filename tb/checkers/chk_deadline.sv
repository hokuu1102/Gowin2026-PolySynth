`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A6 · 音频帧 deadline 检查器（每 1024 个 clk_sys 周期内必须完成渲染与后处理）
//
//   接口语义（与 `files/20-代码/W3接口冻结表.md` 的节拍域一致）：
//     · tick_audio  —— **音频帧起点**的单周期脉冲（fs 节拍，`clk_sys ÷ 1024`）
//     · frame_done  —— 该帧"渲染 + 后处理"完成的单周期脉冲，**必须出现在下一个 tick 之前**
//     · deadline_fault —— 出 viol 即置 1（顶层把它引出来做状态观测，A6 的可见证据）
//
//   两种违规（都报 `ERROR [A6]`，都累加 viol_cnt）：
//     ① frame_done 距帧起点 > CLK_PER_SAMPLE 个周期（超时）
//     ② 下一个 tick 到来时仍未见到 frame_done（整帧漏完成）
//
//   ⭐ 为什么是"上界"而不是平均值：规则原文要的是「≤5 ms 且**确定性无抖动**」——
//      要的是**稳定上界**。所以这里判的是"每一帧都不许超过 1024 拍"，
//      任何一帧超了就是违规，不看平均。
//
//   负向测试：把 frame_done 推迟到第 1500 拍、或整整一帧不给 ⇒ 必触发。
// ─────────────────────────────────────────────────────────────
module chk_deadline #(
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter         NAME           = "top",
    parameter integer MAX_REPORT     = 8
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick_audio,
    input  wire       frame_done,
    output reg        deadline_fault,
    output reg [31:0] viol_cnt
);
    integer cyc;          // 距本帧起点的周期数
    integer max_cyc;      // 观测到的最大帧内周期数（统计用）
    integer reported;
    reg     done_seen;    // 本帧是否已见到 frame_done
    reg     started;      // 是否已经过至少一次 tick（首个帧不判，避开复位期）

    initial begin
        cyc = 0; max_cyc = 0; reported = 0;
        done_seen = 1'b0; started = 1'b0;
        deadline_fault = 1'b0; viol_cnt = 32'd0;
    end

    // ⚠️ 同一个 always 块内统一用阻塞赋值：本模块是检查器，
    //    没有其它写者，阻塞赋值能避免"frame_done 与 tick 同拍"时的读取顺序坑。
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            cyc = 0; done_seen = 1'b0; started = 1'b0;
            deadline_fault = 1'b0;
        end else begin
            if (frame_done === 1'b1) begin
                done_seen = 1'b1;
                if (cyc > max_cyc) max_cyc = cyc;
                if (cyc > CLK_PER_SAMPLE) begin
                    deadline_fault = 1'b1;
                    viol_cnt = viol_cnt + 32'd1;
                    if (reported < MAX_REPORT) begin
                        reported = reported + 1;
                        $display("ERROR [A6] %0s 帧超时：frame_done 在第 %0d 拍，超过 %0d 拍上限",
                                 NAME, cyc, CLK_PER_SAMPLE);
                    end
                end
            end

            if (tick_audio === 1'b1) begin
                if (started && done_seen !== 1'b1) begin
                    deadline_fault = 1'b1;
                    viol_cnt = viol_cnt + 32'd1;
                    if (reported < MAX_REPORT) begin
                        reported = reported + 1;
                        $display("ERROR [A6] %0s 帧未完成：%0d 拍内未见到 frame_done 就到了下一个 tick",
                                 NAME, cyc);
                    end
                end
                started = 1'b1;
                cyc     = 0;
                done_seen = 1'b0;
            end else begin
                cyc = cyc + 1;
            end
        end
    end
endmodule
