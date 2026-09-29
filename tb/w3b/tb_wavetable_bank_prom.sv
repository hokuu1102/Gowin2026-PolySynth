`timescale 1ns/1ps

/* T31b embeds the four generated tables in wavetable_bank, replacing the
 * retired single-sine pROM branch documented below. */
/*

// T48 · wavetable_bank 的 pROM（综合）分支自检 tb。
//
// ⭐ 为什么需要这个独立的 tb：
//    `tb_wavetable_bank.sv` 只测了 `WAVETABLE_BEHAVIORAL` 的 `case` 常量表分支
//    （sim\tb_all.ps1 全局 `-DWAVETABLE_BEHAVIORAL`）。
//    ⛔ 但 Gowin 综合**不设**这个宏 ⇒ 上板走的是 `wavetable_sine_rom_ip`（pROM）分支，
//       该分支在回归里**从未被覆盖** —— 一旦 pROM 分支有 bug，仿真全绿、上板出错。
//
// ⭐ 本 tb 的编译方式（见 sim\tb_all.ps1 的 pROM 变体白名单）：
//    · ⛔ **不传** `-DWAVETABLE_BEHAVIORAL` ⇒ `wavetable_bank` 走 `else`（pROM）分支；
//    · ⭐ 额外把 `tb/models/wavetable_sine_rom_ip_model.sv` 加进编译，
//       用它（`$readmemh` 载入 `sine_512x16.hex`）替代真实 Gowin pROM 黑盒。
//
// 判据（与 `tb_wavetable_bank.sv` 完全同构）：
//    · 512/512 样本逐点匹配 golden；
//    · 单周期确定性读（`rd_en_i` 有效的那一拍后一个时钟沿给出结果）；
//    · `valid_o` 与 `sample_o` 同拍（pROM 分支的 `valid_o <= rd_en_i` 是独立 always，
//      必须与数据输出沿对齐 —— 这正是"valid 同拍"判据要抓的风险）。
module tb_wavetable_bank_prom;
    localparam integer DEPTH = 512;

    reg                 clk_i   = 1'b0;
    reg                 rst_n_i = 1'b0;
    reg                 rd_en_i = 1'b0;
    reg  [8:0]          addr_i  = 9'd0;
    wire signed [15:0]  sample_o;
    wire                valid_o;

    reg [15:0] golden [0:DEPTH-1];
    integer    address;
    integer    errors = 0;
    reg signed [15:0] held_sample;

    always #10 clk_i = ~clk_i;  // 50 MHz

    wavetable_bank dut (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .rd_en_i  (rd_en_i),
        .addr_i   (addr_i),
        .sample_o (sample_o),
        .valid_o  (valid_o)
    );

    task check_response;
        input integer expected_address;
        begin
            if (valid_o !== 1'b1) begin
                $display("FAIL: [prom] valid_o not asserted for address %0d", expected_address);
                errors = errors + 1;
            end
            if ((^sample_o) === 1'bx) begin
                $display("FAIL: [prom] sample_o contains X/Z at address %0d", expected_address);
                errors = errors + 1;
            end else if (sample_o !== $signed(golden[expected_address])) begin
                $display(
                    "FAIL: [prom] address %0d expected %0d (0x%04h), got %0d (0x%04h)",
                    expected_address, $signed(golden[expected_address]),
                    golden[expected_address], sample_o, sample_o
                );
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/wavetable_prom/tb_wavetable_bank_prom.vcd");
        $dumpvars(0, tb_wavetable_bank_prom);
        $readmemh("rtl/w3b/rom/sine_512x16.hex", golden);

        if (golden[0]   !== 16'h0000 || golden[128] !== 16'h7fff ||
            golden[256] !== 16'h0000 || golden[384] !== 16'h8001) begin
            $fatal(1, "FAIL: golden wavetable key values are invalid");
        end

        // ── 复位态：valid=0、sample=0、无 X ──
        rd_en_i = 1'b1;
        addr_i  = 9'd128;
        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0) begin
            $fatal(1, "FAIL: [prom] reset outputs are not valid_o=0 and sample_o=0");
        end
        if (valid_o === 1'bx || (^sample_o) === 1'bx) begin
            $fatal(1, "FAIL: [prom] reset outputs contain X/Z");
        end

        // ── 单点读：valid 与数据同拍、且 rd_en 建立后才变 ──
        rst_n_i = 1'b1;
        rd_en_i = 1'b0;
        @(negedge clk_i);
        rd_en_i = 1'b1;
        addr_i  = 9'd37;
        #1;
        if (valid_o !== 1'b0) begin
            $fatal(1, "FAIL: [prom] valid_o changed before the sampling clock edge");
        end
        @(negedge clk_i);
        check_response(37);

        // ── 读使能关闭时数据保持 ──
        held_sample = sample_o;
        rd_en_i = 1'b0;
        addr_i  = 9'd100;
        @(negedge clk_i);
        if (valid_o !== 1'b0) begin
            $display("FAIL: [prom] valid_o asserted while rd_en_i=0");
            errors = errors + 1;
        end
        if (sample_o !== held_sample) begin
            $display("FAIL: [prom] sample_o changed while rd_en_i=0");
            errors = errors + 1;
        end

        // ── 全表 512 点逐点比对 ──
        rd_en_i = 1'b1;
        addr_i  = 9'd0;
        for (address = 0; address < DEPTH; address = address + 1) begin
            @(negedge clk_i);
            check_response(address);
            if (address < DEPTH-1)
                addr_i = address + 1;
        end

        // ── burst 后关闭读使能 ──
        held_sample = sample_o;
        rd_en_i = 1'b0;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== held_sample) begin
            $display("FAIL: [prom] disabled state after burst is incorrect");
            errors = errors + 1;
        end

        // ── 运行中复位清零 ──
        rd_en_i = 1'b1;
        addr_i  = 9'd128;
        rst_n_i = 1'b0;
        @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_o !== 16'sd0) begin
            $display("FAIL: [prom] post-traffic reset did not clear outputs");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: wavetable_bank pROM path 512/512 samples matched with valid in lockstep");
        else
            $fatal(1, "FAIL: wavetable_bank pROM path found %0d error(s)", errors);

        #20;
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "FAIL: tb_wavetable_bank_prom timeout");
    end
endmodule
*/

// Build without WAVETABLE_BEHAVIORAL as a synthesis-style regression.  T31b
// has no external pROM/IP dependency: the generated ROM constants are shared
// by simulation and the Gowin build.
module tb_wavetable_bank_prom;
`ifdef GOWIN_PRIM_SIM
    // Gowin's official primitive library resolves the global reset through
    // the hierarchical singleton name GSR.GSRO.  The normal lightweight
    // test double does not need it.
    GSR GSR (.GSRI(1'b1));
`endif
    reg clk_i = 1'b0;
    reg rst_n_i = 1'b0;
    reg rd_en_i = 1'b0;
    reg [1:0] timbre_i = 2'd0;
    reg [9:0] addr_i = 10'd0;
    wire signed [15:0] sample_soft_o;
    wire signed [15:0] sample_hard_o;
    wire valid_o;
    integer errors = 0;

    always #10 clk_i = ~clk_i;
    wavetable_bank dut (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .rd_en_i(rd_en_i),
        .timbre_i(timbre_i), .addr_i(addr_i),
        .sample_soft_o(sample_soft_o), .sample_hard_o(sample_hard_o), .valid_o(valid_o)
    );

    task read_and_check;
        input [1:0] t;
        input [9:0] a;
        input signed [15:0] want_soft;
        input signed [15:0] want_hard;
        begin
            @(negedge clk_i);
            timbre_i = t; addr_i = a; rd_en_i = 1'b1;
            @(negedge clk_i);
            if (valid_o !== 1'b1 || sample_soft_o !== want_soft || sample_hard_o !== want_hard) begin
                $display("FAIL: [generated] t=%0d a=%0d expected %0d/%0d got v=%b %0d/%0d",
                         t, a, want_soft, want_hard, valid_o, sample_soft_o, sample_hard_o);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/wavetable_prom/tb_wavetable_bank_prom.vcd");
        $dumpvars(0, tb_wavetable_bank_prom);
        repeat (3) @(negedge clk_i);
        if (valid_o !== 1'b0 || sample_soft_o !== 16'sd0 || sample_hard_o !== 16'sd0)
            $fatal(1, "FAIL: [generated] reset state is not zero");
        rst_n_i = 1'b1;

        read_and_check(2'd0, 10'd256, 16'sd32490, 16'sd32280);
        read_and_check(2'd1, 10'd0,   16'sd4848,  16'sd5588);
        read_and_check(2'd2, 10'd0,   16'sd1123,  16'sd3176);
        read_and_check(2'd3, 10'd0,   16'sd917,   16'sd906);

        if (errors == 0)
            $display("PASS: wavetable_bank generated-table build is deterministic");
        else
            $fatal(1, "FAIL: generated wavetable_bank found %0d error(s)", errors);
        $finish;
    end
endmodule
