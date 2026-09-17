`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A2 · "锁存脚（`LE`）在移位期间必须保持低" 检查器
//
//   为什么需要它（`files/20-代码/已知问题与风险清单.md` `K-03`）：
//     有些串行-并行驱动器件的锁存脚是**电平有效**的：`LE` 高 = 把内部移位寄存器搬到输出。
//     若 `LE` 在移位期间一直为高，输出就会**跟着移位寄存器一路抖**（现象：灯乱亮）；
//     而且某些器件"模式切换阶段"还要靠 `LE` 的电平决定去留 ⇒ 时序必须干净。
//
//   判据：**只要 `clk_sck`（移位时钟）出现任何跳变，`LE` 就必须为低。**
//         （锁存动作发生在移位结束之后、且此时移位时钟必须处于静止状态。）
//
//   用法：
//     chk_le_shift #(.NAME_LE("tlc_le"), .NAME_SCK("tlc_clk")) u_a2 (
//         .clk(clk), .rst_n(rst_n), .le(tlc_le), .sck(tlc_clk), .err_cnt(a2_err));
//
//   ⭐ 另外两条相关纪律（不在这里判，由别的检查器/比特真值表覆盖）：
//     · `LE` 的**锁存脉冲要够宽** ⇒ 对 `LE` 再挂一个 `chk_min_pulse`（A1）即可；
//     · 移位必须**恰好 8 位** ⇒ 属于协议真值表，见 `files/20-代码/TLC5916驱动验证.md`。
//
//   负向测试：`le=1` 时让 `sck` 跳一次 ⇒ 必触发。
// ─────────────────────────────────────────────────────────────
module chk_le_shift #(
    parameter         NAME_LE    = "le",
    parameter         NAME_SCK   = "sck",
    parameter integer MAX_REPORT = 8
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       le,
    input  wire       sck,
    output reg [31:0] err_cnt
);
    integer reported;
    reg     sck_d, le_d;

    initial begin
        reported = 0; err_cnt = 32'd0; sck_d = 1'b0; le_d = 1'b0;
    end

    // ⚠️ 必须用**斜坡/跳变**判据（`sck !== sck_d`），而不是"只在上升沿查"：
    //    器件是双边沿都不该在 `LE` 高时动，而且用跳变判据能同时抓到"高电平期间整段抖动"。
    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            sck_d = 1'b0; le_d = 1'b0;
        end else begin
            // 本拍内 `sck` 相对上一拍发生了变化 = 出现了一个边沿
            if (sck !== sck_d) begin
                // 边沿时刻 `sck` 的新电平与 `le` 的当前电平都要看：
                // 只要 `le` 在这两拍里为高，就算违规（避免"正好在边沿上翻转"被漏掉）
                if (le === 1'b1 || le_d === 1'b1) begin
                    err_cnt = err_cnt + 32'd1;
                    if (reported < MAX_REPORT) begin
                        reported = reported + 1;
                        $display("ERROR [A2] %0s 为高时 %0s 出现边沿（le=%b/%b sck=%b→%b）—— 锁存脚必须在移位期间保持低",
                                 NAME_LE, NAME_SCK, le_d, le, sck_d, sck);
                    end
                end
            end
            sck_d = sck;
            le_d  = le;
        end
    end
endmodule
