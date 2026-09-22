`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_uart_rx.sv · `uart_rx` 验收（曲谱下载通路的前置）
//
// ⭐ 判据（⚠️ **每条都必须能失败** —— `K-56`/`C21`；⭐ 尽量写成【不变量】—— `C44`）
//
//   ① ⭐ **反证基线**：空闲（`rx` 恒高）时 `rx_done_o` **一个都不许出**
//      ⚠️ 没有这一步，"恒出完成脉冲"之类的问题会**假通过**
//   ② ⭐⭐ **真实波特率**（`BAUD_DIV=434` = 115200）逐字节正确
//      🔴 原 tb 只测了 `BAUD_DIV=10`（加速值）⇒ ⚠️ **真实速率从没被测过**
//      ⭐ 这正是"移植时最该补的一条"
//   ③ ⭐ **8 个数据位全组合的边界**：`00` / `FF` / `55` / `AA` / `01` / `80`
//      ⭐ 全覆盖的边界才抓得到"位序反了"（⚠️ `55`/`AA` 专门抓 LSB/MSB 颠倒）
//   ④ ⭐⭐ **位序不变量**：`LSB` 先到 ⇒ 发 `0x01` 必须收 `0x01`（⛔ 不是 `0x80`）
//   ⑤ ⭐ **毛刺必须被丢弃**（< 半位宽的低脉冲）
//   ⑥ ⭐ **字节间隔任意** ⇒ 连发中间插大间隔仍全部正确（⭐ 不依赖固定节奏）
//   ⑦ ⭐ **连续背靠背** 发送（无间隔）⇒ ⭐ 一帧接一帧不丢（曲谱下载会满负荷）
//   ⑧ ⭐ **`rx_done_o` 严格单周期**（⚠️ 拉宽会让上游重复取字节）
//   ⑨ ⭐ **同步复位**：`rst_n_i` 拉低后必须回到 IDLE 且清掉输出
// ─────────────────────────────────────────────────────────────────────────────

module tb_uart_rx;

    // ⭐ 用**真实** 115200（原 tb 用 10 是加速值，覆盖不到真实误差）
    localparam integer BAUD_DIV = 434;
    localparam real    BIT_NS   = 20.0 * BAUD_DIV;   // 一位的 ns 数（clk 周期 20ns）

    reg  clk = 1'b0;
    always #10 clk = ~clk;                            // 50 MHz

    reg        rst_n = 1'b0;
    reg        rx    = 1'b1;                          // 空闲高
    wire [7:0] rx_data;
    wire       rx_done;

    integer errors = 0;

    task chk;
        input [8*110-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    uart_rx #(.BAUD_DIV(BAUD_DIV)) dut (
        .clk_i     (clk),
        .rst_n_i   (rst_n),
        .rx_i      (rx),
        .rx_data_o (rx_data),
        .rx_done_o (rx_done)
    );

    // ── 捕获收到的字节（⭐ 在 `rx_done` 那一拍取，边沿时刻 —— 约定 4）────────
    reg [7:0] got_q [0:63];
    integer   got = 0;
    always @(posedge clk) begin
        if (rst_n && rx_done) begin
            got_q[got] = rx_data;
            got = got + 1;
        end
    end

    // ── 单周期宽度监视（判据 ⑧）─────────────────────────────────────────────
    integer width_max = 0;
    integer w = 0;
    always @(posedge clk) begin
        if (rst_n && rx_done) begin
            w = w + 1;
            if (w > width_max) width_max = w;
        end else begin
            w = 0;
        end
    end

    // ── 发送一个字节（LSB 先）───────────────────────────────────────────────
    task send_byte;
        input [7:0] data;
        integer k;
        begin
            rx = 1'b0;                  #(BIT_NS);      // 起始位
            for (k = 0; k < 8; k = k + 1) begin
                rx = data[k];           #(BIT_NS);      // ⭐ LSB 先
            end
            rx = 1'b1;                  #(BIT_NS);      // 停止位
        end
    endtask

    integer i;
    integer base;

    // ⭐ 按**偏离的波特率**发一个字节（`scale` > 1 = 偏慢，< 1 = 偏快）
    //    ⭐ 用途：暴露"采样点必须在位中点"（见判据 ⑩ 与变异体 `M57`）
    task send_byte_skew;
        input [7:0] data;
        input real  scale;
        integer k;
        begin
            rx = 1'b0;              #(BIT_NS * scale);   // 起始位（同样偏）
            for (k = 0; k < 8; k = k + 1) begin
                rx = data[k];       #(BIT_NS * scale);   // ⭐ LSB 先
            end
            rx = 1'b1;              #(BIT_NS * scale);   // 停止位
        end
    endtask

    // 待测字节表（含全部关键边界）
    reg [7:0] pat [0:9];

    initial begin
        $dumpfile("build/sim/tb_uart_rx/tb_uart_rx.vcd");
        $dumpvars(0, tb_uart_rx);

        pat[0]=8'h00; pat[1]=8'hFF; pat[2]=8'h55; pat[3]=8'hAA; pat[4]=8'h01;
        pat[5]=8'h80; pat[6]=8'h7F; pat[7]=8'hFE; pat[8]=8'h5A; pat[9]=8'hA5;

        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：空闲时不许出完成脉冲
        // ═══════════════════════════════════════════════════════════════════
        #(BIT_NS * 12);
        chk("baseline: NO rx_done while the line is idle (rx held high)", got === 0);
        chk("baseline: rx data stays 0 with no traffic", rx_data === 8'h00);

        // ═══════════════════════════════════════════════════════════════════
        // ② ③ ④ 真实波特率逐字节（含位序边界）
        // ═══════════════════════════════════════════════════════════════════
        base = got;
        for (i = 0; i < 10; i = i + 1) begin
            send_byte(pat[i]);
        end
        #(BIT_NS * 12);

        chk("all 10 bytes at the REAL 115200 baud were received", (got - base) === 10);
        for (i = 0; i < 10; i = i + 1) begin
            if ((base + i) < got && got_q[base+i] === pat[i])
                $display("  ok  : byte[%0d] = %02h  (real baud)", i, got_q[base+i]);
            else begin
                $display("  FAIL: byte[%0d] = %02h expected %02h (real baud)",
                         i, ((base+i)<got)?got_q[base+i]:8'hxx, pat[i]);
                errors = errors + 1;
            end
        end
        // ⭐ 判据 ④：位序不变量（专门抓 LSB/MSB 颠倒）
        chk("bit order: 0x01 came back as 0x01 (LSB-first, NOT 0x80)",
            got_q[base+4] === 8'h01 && got_q[base+5] === 8'h80);

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ 字节间隔任意（大间隔后仍正确）
        // ═══════════════════════════════════════════════════════════════════
        base = got;
        send_byte(8'h3C);
        #(BIT_NS * 500);                 // ⭐ 插一个很长的间隔
        send_byte(8'hC3);
        #(BIT_NS * 12);
        chk("arbitrary gap: bytes on BOTH sides of a long idle gap are correct",
            (got - base) === 2 && got_q[base] === 8'h3C && got_q[base+1] === 8'hC3);

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ 背靠背连发（无间隔）—— 曲谱下载是满负荷的
        // ═══════════════════════════════════════════════════════════════════
        base = got;
        for (i = 0; i < 10; i = i + 1) begin
            send_byte(pat[i]);           // ⛔ 不留间隔
        end
        #(BIT_NS * 12);
        chk("back-to-back: 10 consecutive frames with NO gap are all received",
            (got - base) === 10);
        begin : b2b
            integer okc;
            okc = 0;
            for (i = 0; i < 10; i = i + 1)
                if ((base+i) < got && got_q[base+i] === pat[i]) okc = okc + 1;
            if (okc !== 10) begin
                $display("  FAIL: back-to-back only %0d/10 matched", okc);
                errors = errors + 1;
            end else begin
                $display("  ok  : back-to-back 10/10 matched");
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑤ 毛刺必须被丢弃
        // ═══════════════════════════════════════════════════════════════════
        base = got;
        rx = 1'b0;
        #(BIT_NS / 4);                   // ⚠️ 远小于半位
        rx = 1'b1;
        #(BIT_NS * 12);
        chk("glitch: a narrow low pulse produces NO frame", (got - base) === 0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑧ rx_done 严格单周期
        // ═══════════════════════════════════════════════════════════════════
        chk("rx_done_o is exactly 1 clk wide (never wider)", width_max <= 1);

        // ═══════════════════════════════════════════════════════════════════
        // ⑨ 同步复位：拉低后回 IDLE 并清输出
        // ═══════════════════════════════════════════════════════════════════
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        chk("sync reset: rx_data_o cleared", rx_data === 8'h00);
        chk("sync reset: rx_done_o cleared", rx_done === 1'b0);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);
        // ⭐ 复位后还能正常收（⛔ 不是复位就废了）
        base = got;
        send_byte(8'h96);
        #(BIT_NS * 12);
        chk("after reset the receiver still works", (got - base) === 1 && got_q[base] === 8'h96);

        // ═══════════════════════════════════════════════════════════════════
        // ⑩ ⭐⭐ 采样点必须在【位中点】—— 用**波特率偏差**来暴露
        //    🔴 这一条是**变异体 `M57` 暴露出来的盲区**：
        //       它把采样点从 `clk_cnt == MID_CNT`（位中点）改成 `== 0`（位边沿），
        //       而**我上面所有测试都是完美对齐的**（每位恰好 BIT_NS）
        //       ⇒ ⚠️ 在边沿采样**照样读到正确的值** ⇒ **抓不到**。
        //    ⭐ 而真实串口**一定有波特率偏差**（收发双方的分频不可能完全一致）。
        //       ⭐ 偏差会让采样时刻**逐位漂移**：
        //         · 采在**中点** ⇒ 能容忍接近半位（约 ±5% 波特率误差）
        //         · 采在**边沿** ⇒ ⚠️ 只要有一点偏差就采错
        //    ⇒ ⭐ **判据 = 故意用偏快/偏慢的波特率发**，中点采样必须仍然正确。
        //    📌 这正是"判据要打在真正被区分的那条线上"（`C36`）。
        // ═══════════════════════════════════════════════════════════════════
        begin : sample_point
            // ── (a) 发送方偏慢 3%（每位更长）⇒ 采样点逐位向后漂 ──────────────
            base = got;
            send_byte_skew(8'h5A, 1.03);
            #(BIT_NS * 14);
            chk("sample point: a +3% slower transmitter still decodes (mid-bit sampling)",
                (got - base) === 1 && got_q[base] === 8'h5A);

            // ── (b) 发送方偏快 3%（每位更短）⇒ 采样点逐位向前漂 ──────────────
            base = got;
            send_byte_skew(8'hA5, 0.97);
            #(BIT_NS * 14);
            chk("sample point: a -3% faster transmitter still decodes (mid-bit sampling)",
                (got - base) === 1 && got_q[base] === 8'hA5);

            // ── (c) 更狠：偏慢 4%（接近中点采样的容忍上限）──────────────────
            base = got;
            send_byte_skew(8'h3C, 1.04);
            #(BIT_NS * 14);
            chk("sample point: a +4% slower transmitter still decodes",
                (got - base) === 1 && got_q[base] === 8'h3C);
        end

        // ── 结论 ───────────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: uart_rx 8N1 at the REAL 115200 baud (10 patterns, back-to-back, glitch reject, single-cycle done, sync reset)");
        else
            $display("FAIL: uart_rx had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`：没有结论必须算失败）
    initial begin
        #100_000_000;
        $fatal(1, "FAIL: tb_uart_rx timeout");
    end

endmodule
