`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────
// A4 / A5 · "至多一个有效" 检查器（片选互斥 / 单驱动源）
//
//   ⭐ A4 与 A5 本来是**同一个结构判据**，只是作用对象不同：
//     · **A4**：三片 ADC 的片选**不能同时有效**（同时选中 = 两条数据线抢同一根 MISO）；
//     · **A5**：`MISO` 上**同一时刻只能有一个驱动源**（谁被选中谁驱动）。
//   ⇒ 用一个通用模块 `chk_at_most_one`，挂两处（`NAME` 不同即可）。
//
//   判据：任何时刻，置为**有效电平**的位数 ≤ 1。
//         （全无效是合法的：总线空闲。）
//
//   用法：
//     // A4：三片 ADC 的片选（低有效）
//     chk_at_most_one #(.N(3), .ACTIVE_LOW(1), .NAME("adc_cs_n")) u_a4 (
//         .clk(clk), .rst_n(rst_n), .v({cs2_n, cs1_n, cs0_n}), .err_cnt(a4_err));
//     // A5：`MISO` 的三个候选驱动源（高有效）
//     chk_at_most_one #(.N(3), .ACTIVE_LOW(0), .NAME("miso_drv_en")) u_a5 (
//         .clk(clk), .rst_n(rst_n), .v({en2, en1, en0}), .err_cnt(a5_err));
//
//   ⚠️ 两条实现限制（必须知道，否则会把"没报"当"没问题"）：
//     ① 它是**按 `clk` 采样**的 ⇒ 看不见比一个周期更窄的"同时有效"瞬态
//        （真实的片选互斥由同一调度器保证，采样检查对它足够）；
//     ② 它只判"**同时**有效"，⛔ 不判"该有效的时候是否有效"
//        （例如某片的片选永远是低 ⇒ 这里不报，得靠功能真值表）。
//
//   负向测试：让两位同时有效 ⇒ 必触发。
// ─────────────────────────────────────────────────────────────
module chk_at_most_one #(
    parameter integer N          = 3,
    parameter integer ACTIVE_LOW = 1,
    parameter         NAME       = "v",
    parameter integer MAX_REPORT = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] v,
    output reg [31:0]   err_cnt
);
    integer reported;
    integer i;
    integer n_active;
    reg [N-1:0] act;

    initial begin
        reported = 0; err_cnt = 32'd0;
    end

    always @(posedge clk) begin
        if (rst_n !== 1'b1) begin
            // 复位期不判（此时常有多路同时被拉低/拉高的中间态）
        end else begin
            act = (ACTIVE_LOW == 1) ? ~v : v;
            n_active = 0;
            for (i = 0; i < N; i = i + 1)
                if (act[i] === 1'b1) n_active = n_active + 1;

            if (n_active > 1) begin
                err_cnt = err_cnt + 32'd1;
                if (reported < MAX_REPORT) begin
                    reported = reported + 1;
                    $display("ERROR [A4/A5] %0s 同时有 %0d 路有效（%b）—— 片选必须互斥、MISO 只能有单一驱动源",
                             NAME, n_active, v);
                end
            end
        end
    end
endmodule
