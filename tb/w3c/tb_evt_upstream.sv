`timescale 1ns/1ps
// tb_evt_upstream.sv -- ⭐ 上行帧 v1.1 的 14 B 实时事件流（⭐ 2026-10-14）
//
//   ⭐ **判据的重点**：🔴 **`phase_inc` 必须是【全宽 32 位】**
//      —— ⭐ 那是本模块存在的**唯一理由**（⭐ 旧 9 B 格式只给 21 位 ⇒ 音高是垃圾 ✅）
//      ⭐ 本 tb 用 **A4 = 38 702 840**（⭐ > 2²¹ = 2 097 152）当刺激
//      ⇒ ⚠️ 若实现把 `inc` 截成 21 位，判据 **必红** ✅
//
//   ⭐ 其余判据：⭐ 帧头/类型/seq/tick/axis/vel/**校验** 逐字节对齐 v1.1；
//      ⭐ `kind` 映射（⭐ 1→`0x02`，⭐ 0/2→`0x01`）；⭐ seq 自增；⭐ tick 锁在**捕获那一拍**；
//      ⭐ 溢出**可见**（⭐ 丢弃计数 + sticky）；⭐ **非空洞**（⭐ 校验不是常数 ✅）
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ ⭐ **本文件必须【无 BOM】**（⭐ 见 `tools/check_no_bom.ps1` ✅）

`timescale 1ns/1ps

module tb_evt_upstream;

    localparam integer PHASE_W = 32;
    localparam integer AXIS_W  = 4;
    localparam integer VEL_W   = 8;
    localparam integer FIFO_D  = 16;

    //  ⭐ A4 @ fs = 48.828 kHz ⇒ phase_inc = 440/48828 × 2³² ≈ 38 702 840
    //     🔴 **> 2²¹ = 2 097 152** ⇒ ⭐ 21 位装不下（⭐ 这就是判据的锋芒 ✅）
    localparam [31:0] A4_INC = 32'd38702840;
    //  ⭐ 另一个音（⭐ 用来证"校验不是常数" ✅）
    localparam [31:0] E6_INC = 32'd155072916;

    reg clk = 1'b0;
    always #10 clk = ~clk;                       // ⭐ 50 MHz

    reg        rst_n     = 1'b0;
    reg        evt_valid = 1'b0;
    reg  [AXIS_W-1:0]  evt_axis = 4'd0;
    reg  [PHASE_W-1:0] evt_inc  = 32'd0;
    reg  [VEL_W-1:0]   evt_vel  = 8'd0;
    reg  [1:0]         evt_kind = 2'd0;
    reg        tick_step = 1'b0;
    reg        enable    = 1'b0;
    reg        ready     = 1'b1;

    wire        push;
    wire [7:0]  byte_o;
    wire        busy;
    wire [15:0] frame_cnt, drop_cnt;
    wire        overflow;
    wire [7:0]  seq;
    wire [31:0] tick;
    wire [4:0]  level;

    evt_upstream #(
        .PHASE_W(PHASE_W), .AXIS_W(AXIS_W), .VEL_W(VEL_W), .FIFO_D(FIFO_D)
    ) dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .evt_valid_i   (evt_valid),
        .evt_axis_i    (evt_axis),
        .evt_phase_inc_i(evt_inc),
        .evt_velocity_i(evt_vel),
        .evt_kind_i    (evt_kind),
        .tick_step_i   (tick_step),
        .enable_i      (enable),
        .ready_i       (ready),
        .push_o        (push),
        .byte_o        (byte_o),
        .busy_o        (busy),
        .frame_cnt_o   (frame_cnt),
        .drop_cnt_o    (drop_cnt),
        .overflow_o    (overflow),
        .seq_o         (seq),
        .tick_o        (tick),
        .level_o       (level)
    );

    //  ⭐ 收字节（⭐ negedge 采样 ⇒ ⭐ 避开 posedge 竞争 ✅）
    reg [7:0] rx [0:63];
    integer   rx_n = 0;
    always @(negedge clk) begin
        if (push && ready && (rx_n < 64)) begin
            rx[rx_n] = byte_o;
            rx_n     = rx_n + 1;
        end
    end

    integer errors = 0;
    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (!cond) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end else
                $display("  ok  : %0s", name);
        end
    endtask

    //  ⭐ 发一个事件（⭐ 单拍 `evt_valid` ✅）
    task send_evt;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vel;
        input [1:0]         kd;
        begin
            @(negedge clk);
            evt_valid = 1'b1; evt_axis = ax; evt_inc = inc; evt_vel = vel; evt_kind = kd;
            @(posedge clk);
            @(negedge clk);
            evt_valid = 1'b0;
        end
    endtask

    //  ⭐ 等 `n` 个字节被收走（⭐ 带超时，⛔ 不静默挂死 ✅）
    task wait_bytes;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while ((rx_n < n) && (guard < 20000)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 20000) begin
                $display("FAIL: timeout waiting for %0d bytes (got %0d)", n, rx_n);
                errors = errors + 1;
            end
        end
    endtask

    //  ⭐⭐ 2026-10-14 更正：⭐ **校验 = XOR 覆盖 [0..12]（⭐ 含帧头 0xA5）** ✅
    //     🔴 原口径是 `[1..12]`（⛔ 不含 0xA5）⇒ ⚠️ 与 ESP32 侧
    //        `frame_format.py:165`（`for x in b[:-1]`）**不一致** ✅
    //     📌 ⭐ 依据：⭐ `files/20-代码/FPGA侧答复-鼓谱发声与XOR更正-20261014.md` §三 ✅
    function [7:0] ck_of;
        input integer base;
        integer i;
        begin
            ck_of = 8'd0;
            for (i = 0; i <= 12; i = i + 1) ck_of = ck_of ^ rx[base + i];
        end
    endfunction

    integer base;
    reg [7:0] ck_a, ck_b;

    initial begin
        $dumpfile("build/sim/tb_evt_upstream/tb_evt_upstream.vcd");
        $dumpvars(0, tb_evt_upstream);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        // ══ 判据 ①：复位 ⇒ ⭐ 无帧、FIFO 空、无溢出 ══
        chk(frame_cnt === 16'd0, "reset: frame_cnt is 0");
        chk(level     === 5'd0,  "reset: FIFO level is 0");
        chk(overflow  === 1'b0,  "reset: overflow is 0");

        // ══ 判据 ②：⛔ **未使能时不许收**（⭐ 默认关 ⇒ 零回归的依据 ✅）══
        send_evt(4'd5, A4_INC, 8'd200, 2'd0);
        repeat (20) @(negedge clk);
        chk(rx_n == 0,          "disabled: NO bytes emitted");
        chk(level === 5'd0,     "disabled: the event is NOT even buffered");
        chk(frame_cnt === 16'd0,"disabled: frame_cnt stays 0");

        // ══ 判据 ③：使能后，一个事件 ⇒ ⭐ 恰好一帧 14 B ══
        enable = 1'b1;
        repeat (3) @(negedge clk);
        //  ⭐ 先走几个 tick，好让 tick 非 0（⭐ 便于验证"锁在捕获那一拍" ✅）
        repeat (7) begin @(negedge clk); tick_step = 1'b1; @(negedge clk); tick_step = 1'b0; end
        rx_n = 0;
        base = 0;
        send_evt(4'd5, A4_INC, 8'd200, 2'd0);
        wait_bytes(14);
        repeat (4) @(negedge clk);
        chk(rx_n == 14, "one event => exactly 14 bytes");

        // ══ 判据 ④：帧头 / 类型 / seq / axis / vel ══
        chk(rx[0] === 8'hA5, "byte[0] is the 0xA5 header");
        chk(rx[1] === 8'h01, "kind=0 (note_on) maps to type 0x01");
        chk(rx[2] === 8'd0,  "first frame carries seq 0");
        chk(rx[7] === 8'h05, "byte[7] carries axis 5");
        chk(rx[12] === 8'd200,"byte[12] carries velocity 200");

        // ══ 判据 ⑤：🔴 **本模块存在的理由 —— `inc` 必须是全宽 32 位** ══
        //  ⭐ 大端：`inc[31:24] [23:16] [15:8] [7:0]`
        chk({rx[8], rx[9], rx[10], rx[11]} === A4_INC,
            "*** byte[8..11] carry the FULL 32-bit phase_inc (A4 = 38702840) ***");
        chk({rx[8], rx[9], rx[10], rx[11]} > 32'd2097152,
            "non-vacuity: the value really exceeds the old 21-bit wire field");
        chk({rx[8], rx[9], rx[10], rx[11]} !== {11'd0, A4_INC[20:0]},
            "*** NOT the 21-bit truncation (the old format's bug) ***");

        // ══ 判据 ⑥：tick 是 32 位大端，且 = 捕获那一刻的值 ══
        chk({rx[3], rx[4], rx[5], rx[6]} === 32'd7,
            "byte[3..6] carry the tick latched AT CAPTURE TIME (=7)");

        // ══ 判据 ⑦：校验 = XOR[0..12]，⭐ **含帧头 0xA5**（⭐ 2026-10-14 更正 ✅）══
        ck_a = ck_of(0);
        chk(rx[13] === ck_a, "byte[13] equals XOR of bytes [0..12] (INCLUDING the 0xA5 header)");
        chk(rx[13] !== 8'd0, "non-vacuity: the checksum is not a constant 0");

        // ══ 判据 ⑧：`kind=1` ⇒ `0x02`（note_off）；⭐ seq 自增 ══
        rx_n = 0; base = 0;
        send_evt(4'd9, A4_INC, 8'd100, 2'd1);
        wait_bytes(14);
        repeat (4) @(negedge clk);
        chk(rx[1] === 8'h02, "kind=1 (note_off) maps to type 0x02");
        chk(rx[2] === 8'd1,  "seq increments per event (now 1)");
        chk(rx[7] === 8'h09, "axis 9 survived");
        chk(rx[13] === ck_of(0), "checksum still holds for the second frame");

        // ══ 判据 ⑨：`kind=2`（pluck）⇒ ⭐ 也算 note_on（⭐ 0x01）══
        rx_n = 0; base = 0;
        send_evt(4'd6, E6_INC, 8'd50, 2'd2);
        wait_bytes(14);
        repeat (4) @(negedge clk);
        chk(rx[1] === 8'h01, "kind=2 (pluck) is treated as note_on (0x01)");
        chk({rx[8], rx[9], rx[10], rx[11]} === E6_INC, "a second, larger inc survives intact");
        ck_b = ck_of(0);
        chk(ck_b !== ck_a, "non-vacuity: different events give DIFFERENT checksums");
        chk(rx[13] === ck_b, "checksum holds for the third frame");

        // ══ 判据 ⑩：⭐ 溢出**可见**（⭐ 顶住 ready ⇒ FIFO 灌满 ⇒ 丢弃 + sticky ✅）══
        ready = 1'b0;                       // ⭐ 不让它排空
        repeat (40) send_evt(4'd1, A4_INC, 8'd10, 2'd0);   // ⭐ 远超 FIFO_D=16
        repeat (4) @(negedge clk);
        chk(drop_cnt !== 16'd0, "overflow: drop_cnt is non-zero (loss is COUNTED)");
        chk(overflow === 1'b1,  "overflow: the sticky flag is set (loss is VISIBLE)");
        ready = 1'b1;
        repeat (400) @(negedge clk);
        chk(busy === 1'b0, "after draining, busy_o returns low");

        // ══ 判据 ⑪：⛔ 关闭后不许再发（⭐ 且 FIFO 已排空 ✅）══
        repeat (200) @(negedge clk);
        enable = 1'b0;
        repeat (5) @(negedge clk);
        rx_n = 0;
        send_evt(4'd2, A4_INC, 8'd1, 2'd0);
        repeat (30) @(negedge clk);
        chk(rx_n == 0, "re-disabled: no further frames are emitted");

        $display("");
        if (errors == 0)
            $display("PASS: evt_upstream -- v1.1 14-byte frames with the FULL 32-bit phase_inc, correct type/seq/tick/axis/vel/XOR, gated by enable, and overflow is counted and sticky");
        else
            $fatal(1, "FAIL: tb_evt_upstream had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
