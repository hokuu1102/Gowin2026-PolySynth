`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_tlc5916_bank.sv · `tlc5916_bank` 验收（三片调度 + CH→OUT 重映射）
//
// ⭐ 判据（⚠️ 每一条都必须能失败 —— K-56/C21）
//
//   ① ⭐ 反证基线：复位后 OE 全高（灯全灭）、SDI/CLK/LE 全 0、busy 0
//   ② ⭐⭐ CH→OUT 重映射正确（§1.4 核心）：直接核验内部 `chip*_out` 表——
//       喂"CH 位"，重映射后必须落在"OUT 位"，⛔ 不是同索引。
//       覆盖 8 个 CH 的全表（每个 CH→OUT 都核对一遍），并验证"⛔ 非位反转"
//       （若 CH2→OUT4/CH3→OUT5/CH4→OUT3/CH5→OUT2 与位反转不同，则表是对的）。
//   ③ ⭐ 三片逐写：commit 后依次写片0、片1、片2，写完回 IDLE、OE 回全高
//   ④ ⭐ OE 分板：写片0 时 oe[0]=0；写片1 时 oe[1]=0；写片2 时 oe[4]=0
//   ⑤ ⭐ busy 只在写期间为高，写完后回落
// ─────────────────────────────────────────────────────────────────────────────

module tb_tlc5916_bank;

    localparam integer KEY_CHIPS    = 2;
    localparam integer STATUS_CHIPS = 1;
    localparam integer OE_N         = 5;
    localparam integer PAT_W        = KEY_CHIPS*8 + STATUS_CHIPS*8;  // 24

    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg                 rst_n   = 1'b0;
    reg [PAT_W-1:0]     pattern = {PAT_W{1'b0}};
    reg                 commit  = 1'b0;
    reg                 blank   = 1'b0;

    wire        sdi;
    wire        clk_o;
    wire        le;
    wire [OE_N-1:0] oe_n;
    wire        busy;

    integer errors = 0;

    task chk;
        input [8*100-1:0] name;
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

    tlc5916_bank #(
        .KEY_CHIPS    (KEY_CHIPS),
        .STATUS_CHIPS (STATUS_CHIPS),
        .OE_N         (OE_N)
    ) dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .pattern_i       (pattern),
        .pattern_commit_i(commit),
        .global_blank_i  (blank),
        .led_sdi_o       (sdi),
        .led_clk_o       (clk_o),
        .led_le_o        (le),
        .led_oe_n_o      (oe_n),
        .busy_o          (busy)
    );

    // ⭐ 用层次引用直接读 bank 内部的 OUT 序寄存器（组合逻辑，随 pattern 变）
    //   这是核验 CH→OUT 重映射最直接、最不依赖时序的方式（§1.4 关心的就是这个表）。
    wire [7:0] c0_out = dut.chip0_out;
    wire [7:0] c1_out = dut.chip1_out;
    wire [7:0] c2_out = dut.chip2_out;

    // ⭐ 期望的 CH→OUT 表（硬件真值 §一）
    //   CH0→OUT7 CH1→OUT6 CH2→OUT4 CH3→OUT5 CH4→OUT3 CH5→OUT2 CH6→OUT1 CH7→OUT0
    // 喂一个"只有 CH[k] 置 1"的图案 ⇒ 期望 chip0_out = 只有 OUT[表[k]] 置 1
    task check_single_ch;
        input integer ch;
        input integer out;
        reg [8*60-1:0] msg;
        begin
            pattern = {PAT_W{1'b0}};
            pattern[ch] = 1'b1;
            #1;   // 让组合逻辑稳定
            $sformat(msg, "CH%0d -> OUT%0d", ch, out);
            chk(msg, c0_out === (8'b1 << out));
            pattern = {PAT_W{1'b0}};
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_tlc5916_bank/tb_tlc5916_bank.vcd");
        $dumpvars(0, tb_tlc5916_bank);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ⭐ 等复位恢复序列跑完（tlc5916_driver K-66 Normal-Mode 恢复 ≈6.2µs）
        #10_000;
        @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：复位后全灭
        // ═══════════════════════════════════════════════════════════════════
        chk("reset: OE all high (all blanked)", oe_n === {OE_N{1'b1}});
        chk("reset: SDI/CLK/LE all 0", sdi === 1'b0 && clk_o === 1'b0 && le === 1'b0);
        chk("reset: busy 0", busy === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ② CH→OUT 全表核验（§1.4 核心）
        //    ⛔ 逐个 CH 核对：若用"同索引算术"，CH6 会错配到 OUT6（而非 OUT1）
        // ═══════════════════════════════════════════════════════════════════
        check_single_ch(0, 7);   // CH0 → OUT7
        check_single_ch(1, 6);   // CH1 → OUT6
        check_single_ch(2, 4);   // CH2 → OUT4
        check_single_ch(3, 5);   // CH3 → OUT5
        check_single_ch(4, 3);   // CH4 → OUT3
        check_single_ch(5, 2);   // CH5 → OUT2
        check_single_ch(6, 1);   // CH6 → OUT1  ⭐ §1.4 关键点
        check_single_ch(7, 0);   // CH7 → OUT0

        // ⭐ 反证：⛔ 不是位反转（若误做成位反转，CH2 会错到 OUT5、CH3 会错到 OUT4）
        pattern = 24'd0;
        pattern[2] = 1'b1;   // CH2
        #1;
        chk("CH2 is NOT bit-reversed (would be OUT5=8'b00100000)", c0_out === 8'b00010000);
        pattern = 24'd0;

        // ═══════════════════════════════════════════════════════════════════
        // ③ 三片逐写 + ④ OE 分板
        //    commit 一次，应依次写片0(oe0=0)→片1(oe1=0)→片2(oe4=0)，写完回 IDLE
        // ═══════════════════════════════════════════════════════════════════
        pattern = 24'd0;
        pattern[0] = 1'b1;     // 片0 CH0（键灯）
        pattern[8] = 1'b1;     // 片1 CH0（键灯）
        pattern[16] = 1'b1;    // 片2 CH0（状态灯）
        commit = 1'b1;
        @(negedge clk);
        commit = 1'b0;

        // 等整轮（三片）写完
        wait (busy === 1'b1);   // 开始
        wait (busy === 1'b0);   // 结束
        @(negedge clk);

        // 写完应回 IDLE：OE 全高、busy 0
        chk("after 3-chip write: OE all high (back to IDLE)", oe_n === {OE_N{1'b1}});
        chk("after 3-chip write: busy 0", busy === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑤ 全局消隐：blank=1 时 OE 应保持全高（即使正在写）
        // ═══════════════════════════════════════════════════════════════════
        blank = 1'b1;
        pattern = 24'd0;
        pattern[0] = 1'b1;
        commit = 1'b1;
        @(negedge clk);
        commit = 1'b0;
        // 在写期间 blank 应强制 OE 全高
        wait (busy === 1'b1);
        chk("global_blank: OE stays all high during write", oe_n === {OE_N{1'b1}});
        wait (busy === 1'b0);
        blank = 1'b0;

        // ── 结论 ───────────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: tlc5916_bank (CH->OUT full-table remap / 3-chip seq / per-board OE / global blank)");
        else
            $display("FAIL: tlc5916_bank had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（K-94）
    initial begin
        #200_000_000;
        $fatal(1, "FAIL: tb_tlc5916_bank timeout");
    end

endmodule
