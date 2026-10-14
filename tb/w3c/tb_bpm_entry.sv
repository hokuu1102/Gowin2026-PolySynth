// tb_bpm_entry.sv · BPM 手动入口的【最小】端到端判据（⭐ 2026-10-11）
//
//   ⭐ **为什么要单独一个 tb**：
//      🔴 在既有的 `tb_play_seq` 里加本判据会**挂死**（⭐ 时序耦合 ✅）
//      ⇒ ⭐ 本 tb **只例化 `play_seq`**、⭐ 只喂 BPM 相关输入 ⇒ ⭐ 时序极简 ✅
//
//   ⭐ **判据（⭐ 端到端 ✅）**：⭐ `tick_inc_o` 必须**真的**按公式变 ✅
//      ⭐ `tick_inc = BPM × 1374 + 47`
//      ⭐ 依据：⭐ `BPM × PPQN × 2^32 / (60 × CLK_HZ)`，⭐ PPQN = 960、⭐ CLK_HZ = 50e6 ✅
//      ✅ ⭐ **关键锚点**：⭐ `120 × 1374 + 47 = 164927` = `TICK_INC_DEFAULT` **逐位相同** ✅
//
//   🔴 **未实现时必红**：⭐ 端口不存在 ⇒ ⭐ 编译不过 ✅
//      （⭐ 端口有但逻辑没填 ⇒ ⭐ `tick_inc_o` 不变 ⇒ ⭐ 下面**全红** ✅）
//
//   ⛔ **纪律**：⭐ Verilog-2001（⭐ `K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ ⭐ **本文件必须【无 BOM】**（⭐ 见 `tools/check_no_bom.ps1` ✅）——
//      🔴 有 BOM ⇒ ⭐ iverilog **解析不出本模块** ⇒ ⭐ 报"找不到 root module" ✅

`timescale 1ns/1ps

module tb_bpm_entry;

    localparam integer EVT_W = 64;
    //  ⭐ 120 BPM 的 `tick_inc`（⭐ 与 `play_seq.TICK_INC_DEFAULT` 同值 ✅）
    localparam [31:0] INC_120 = 32'd164927;
    //  ⭐ 每 1 BPM 的增量（⭐ 与 RTL 里的 `INC_PER_BPM` 同值 ✅）
    localparam [31:0] PER_BPM = 32'd1374;
    //  ⭐ 限幅端点 ✅
    localparam [31:0] INC_MIN = 32'd55007;    // ⭐ 40 BPM
    localparam [31:0] INC_MAX = 32'd329807;   // ⭐ 240 BPM

    reg clk = 1'b0;
    always #10 clk = ~clk;                    // ⭐ 50 MHz（20 ns）

    reg rst_n = 1'b0;

    //  ⭐ BPM 手动入口
    reg         bpm_up   = 1'b0;
    reg         bpm_dn   = 1'b0;
    reg         bpm_load = 1'b0;
    reg  [15:0] bpm_val  = 16'd0;

    //  ⭐ 其余端口（⭐ 本 tb 不关心 ⇒ ⭐ 固定 ✅）
    reg                    evt_valid = 1'b0;
    reg  [EVT_W-1:0]       evt_data  = {EVT_W{1'b0}};
    wire [31:0]            tick_inc;
    wire                   evt_rd, note_valid, tempo_applied, underrun;
    wire [EVT_W-1:0]       note_data;
    wire [15:0]            evt_cnt, tempo_cnt;
    wire [19:0]            cur_tick;

    play_seq #(
        .EVT_W(EVT_W), .TICK_INC_DEFAULT(INC_120)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .tick_i         (1'b0),           // ⭐ 本判据与 tick 无关 ✅
        .run_i          (1'b1),
        .pos_reset_i    (1'b0),
        .bpm_up_i       (bpm_up),
        .bpm_dn_i       (bpm_dn),
        .bpm_load_i     (bpm_load),
        .bpm_i          (bpm_val),
        .tick_inc_o     (tick_inc),
        .evt_valid_i    (evt_valid),
        .evt_data_i     (evt_data),
        .evt_rd_o       (evt_rd),
        .note_valid_o   (note_valid),
        .note_data_o    (note_data),
        .tempo_applied_o(tempo_applied),
        .evt_underrun_o (underrun),
        .evt_cnt_o      (evt_cnt),
        .tempo_cnt_o    (tempo_cnt),
        .cur_tick_o     (cur_tick),
        //  ⭐ 2026-10-14：⭐ 新增 `lead_i` ⇒ **必须显式接 0**
        //     ⚠️ 不接 = 悬空 = `Z` ⇒ 🔴 比较判据变 `X` ⇒ 事件流全乱
        //        （⭐ 与 `ctrl_col_i` 同族 —— 本轮全量回归刚抓过 ✅）
        .lead_i         (20'd0)          // ⭐ 0 = 演奏模式（⭐ 逐位不变 ✅）
    );

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

    //  ⭐ 发一个 `bpm_load` 脉冲（⭐ 单周期 ✅）
    task do_load;
        input [15:0] v;
        begin
            @(negedge clk);
            bpm_val  = v;
            bpm_load = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bpm_load = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task do_up;
        begin
            @(negedge clk);
            bpm_up = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bpm_up = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task do_dn;
        begin
            @(negedge clk);
            bpm_dn = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bpm_dn = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    integer cnt0;

    initial begin
        $dumpfile("build/sim/tb_bpm_entry/tb_bpm_entry.vcd");
        $dumpvars(0, tb_bpm_entry);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ══ 判据 ①：复位默认 = 120 BPM（⭐ 且 ⛔ 不是 0 ⇒ 0 会让时钟静止 ✅）══
        chk(tick_inc === INC_120,
            "reset default tick_inc = 164927 (120 BPM, NOT 0)");

        // ══ 判据 ②：绝对装载（⭐ 串口 'Q' 走的就是这条 ✅）══
        do_load(16'd140);
        chk(tick_inc === (32'd140 * PER_BPM + 32'd47),
            "bpm_load 140 => tick_inc = 140*1374+47 = 192407");

        // ══ 判据 ③：⭐ 关键锚点 —— 120 BPM 必须【精确】回到 `INC_120` ══
        //   📌 ⭐ 这就是偏置选 47 的目的 ✅
        do_load(16'd120);
        chk(tick_inc === INC_120,
            "bpm_load 120 => tick_inc is BIT-IDENTICAL to TICK_INC_DEFAULT (the anchor)");

        // ══ 判据 ④：两个端点 ══
        do_load(16'd40);
        chk(tick_inc === INC_MIN, "bpm_load 40 => tick_inc = 55007 (the slowest)");
        do_load(16'd240);
        chk(tick_inc === INC_MAX, "bpm_load 240 => tick_inc = 329807 (the fastest)");

        // ══ 判据 ⑤：超范围 ⇒ ⭐ 限幅（⛔ 不报错、⛔ 不越界 ✅）══
        do_load(16'd10);
        chk(tick_inc === INC_MIN, "bpm_load 10 clamps UP to 40 BPM (55007)");
        do_load(16'd250);
        chk(tick_inc === INC_MAX, "bpm_load 250 clamps DOWN to 240 BPM (329807)");
        do_load(16'd0);
        chk(tick_inc === INC_MIN, "bpm_load 0 clamps to 40 BPM (0 would stop the clock)");

        // ══ 判据 ⑥：相对步进（⭐ 留给 EC11 的那条 ✅）══
        do_load(16'd120);
        do_up;
        chk(tick_inc === (INC_120 + PER_BPM), "bpm_up from 120 => +1374 (exactly +1 BPM)");
        do_dn;
        chk(tick_inc === INC_120, "bpm_dn from 121 => back to 164927 (exactly -1 BPM)");

        // ══ 判据 ⑦：相对步进也必须限幅 ══
        do_load(16'd240);
        do_up;
        chk(tick_inc === INC_MAX, "bpm_up at 240 BPM stays clamped (no overrun)");
        do_load(16'd40);
        do_dn;
        chk(tick_inc === INC_MIN, "bpm_dn at 40 BPM stays clamped (no underrun)");

        // ══ 判据 ⑧：可观测（⭐ `K-106`：⛔ 不许静默 ✅）══
        cnt0 = tempo_cnt;
        do_load(16'd150);
        chk(tempo_cnt > cnt0,
            "every manual change increments tempo_cnt_o (visible, not silent)");

        // ══ 判据 ⑨：非空洞 —— `tick_inc_o` 必须【真的变过】══
        begin : nonvac
            reg [31:0] a, b;
            do_load(16'd100);
            a = tick_inc;
            do_load(16'd200);
            b = tick_inc;
            chk(a !== b, "non-vacuous: different BPM really produce different tick_inc");
        end

        $display("");
        if (errors == 0)
            $display("PASS: play_seq BPM entry -- tick_inc = BPM*1374+47, anchored exactly at 120 BPM, clamped to 40..240, and observable");
        else
            $fatal(1, "FAIL: tb_bpm_entry had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
