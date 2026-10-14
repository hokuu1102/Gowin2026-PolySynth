`timescale 1ns/1ps
// tb_bpm_bar_quant.sv -- 手动 BPM 对齐小节线的【完备】判据（⭐ 2026-10-14）
//
//   ⭐ **为什么单独一个 tb**：⭐ 对齐逻辑被刻意做成独立小模块
//      ⇒ ⭐ 判据可以**穷举**它的全部语义（⭐ 见 RTL 文件头的 ①~⑤ ✅）
//      ⛔ 不需要例化 `top`（⭐ 那会牵扯 ADC/HDMI 一整套模型 ⇒ 判据噪声大 ✅）
//
//   🔴 **未实现时必红**：⭐ 端口不存在 ⇒ ⭐ 编译不过 ✅
//      ⭐ 端口在但逻辑没填（例如直接透传）⇒ ⭐ 判据 ③ **必红** ✅
//         （⭐ "`set_i` 单独到达不许出 `load_o`" 正是本模块的**全部意义** ✅）
//
//   📌 **非空洞保证**：⭐ 判据 ② 证明"没有 `set_i` 时 `bar_start_i` 永不出 `load_o`"
//      ⇒ ⭐ 否则判据 ③ 的 `load_cnt == 0` 可能只是"什么都没接" ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ ⭐ **本文件必须【无 BOM】**（⭐ 见 `tools/check_no_bom.ps1` ✅）——
//      🔴 有 BOM ⇒ ⭐ iverilog **解析不出本模块** ⇒ ⭐ 报"找不到 root module" ✅

`timescale 1ns/1ps

module tb_bpm_bar_quant;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // ⭐ 50 MHz（20 ns）

    reg        rst_n = 1'b0;
    reg        set   = 1'b0;
    reg  [7:0] val   = 8'd0;
    reg        bar   = 1'b0;

    wire       load;
    wire [7:0] val_o;
    wire       pending;

    bpm_bar_quant dut (
        .clk_i       (clk),
        .rst_n_i     (rst_n),
        .set_i       (set),
        .val_i       (val),
        .bar_start_i (bar),
        .load_o      (load),
        .val_o       (val_o),
        .pending_o   (pending)
    );

    //  ⭐ 装载脉冲监视器：⭐ 在 **negedge** 采样 ⇒ ⭐ 避开 posedge 竞争 ✅
    integer   load_cnt = 0;
    reg [7:0] last_val = 8'd0;
    always @(negedge clk) begin
        if (load) begin
            load_cnt = load_cnt + 1;
            last_val = val_o;
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

    //  ⭐ 单拍 `set_i` 脉冲（⭐ 与 `val_i` 同拍 —— 与 `play_seq.bpm_load_i` 同约定）
    task do_set;
        input [7:0] v;
        begin
            @(negedge clk);
            val = v; set = 1'b1;
            @(posedge clk);
            @(negedge clk);
            set = 1'b0;
        end
    endtask

    //  ⭐ 单拍 `bar_start_i` 脉冲
    task do_bar;
        begin
            @(negedge clk);
            bar = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bar = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_bpm_bar_quant/tb_bpm_bar_quant.vcd");
        $dumpvars(0, tb_bpm_bar_quant);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        // ══ 判据 ①：复位 ⇒ ⭐ 无挂起、无装载 ══
        chk(pending === 1'b0, "reset: pending_o is 0");
        chk(load    === 1'b0, "reset: load_o is 0");

        // ══ 判据 ②：⭐ 非空洞 —— 只给 `bar_start_i`（⛔ 没有 `set_i`）⇒ ⭐ 永不出装载 ══
        load_cnt = 0;
        do_bar; do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 0, "non-vacuous: bar_start alone (no set_i) NEVER loads");

        // ══ 判据 ③：🔴 **本模块的全部意义** —— `set_i` 单独到达 ⇒ ⭐ 只挂起、⛔ 不装载 ══
        load_cnt = 0;
        do_set(8'd140);
        repeat (2) @(negedge clk);
        chk(pending === 1'b1, "set_i arms pending_o");
        chk(load_cnt == 0, "'Q' ALONE does NOT load -- no mid-beat tempo change");

        // ══ 判据 ④：到小节线 ⇒ ⭐ 恰好出一拍 ＋ ⭐ 值配对 ══
        do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 1,      "bar_start applies EXACTLY ONE load pulse");
        chk(last_val == 8'd140, "the applied value is the latched one (140)");
        chk(pending  === 1'b0,  "the pending flag clears after applying");

        // ══ 判据 ⑤：⭐ 一次性 —— 之后的小节线（⭐ 无新 `set_i`）⛔ 不许再装载 ══
        load_cnt = 0;
        do_bar; do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 0, "one-shot: later bars without a new set_i do not re-load");

        // ══ 判据 ⑥：小节线之前**重复改** ⇒ ⭐ 后到者胜 ＋ ⭐ 仍然只出一拍 ══
        load_cnt = 0;
        do_set(8'd100);
        do_set(8'd200);
        repeat (2) @(negedge clk);
        chk(pending === 1'b1, "re-arm keeps pending_o set");
        chk(load_cnt == 0,    "re-arm alone still does not load");
        do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 1,      "re-arm then bar => exactly ONE load (not two)");
        chk(last_val == 8'd200, "the LAST set_i value wins (200)");

        // ══ 判据 ⑦：`set_i` 与 `bar_start_i` **同拍** ⇒ ⭐ `set_i` 优先（⭐ 挂到下一个）══
        load_cnt = 0;
        @(negedge clk);
        val = 8'd90; set = 1'b1; bar = 1'b1;
        @(posedge clk);
        @(negedge clk);
        set = 1'b0; bar = 1'b0;
        repeat (2) @(negedge clk);
        chk(load_cnt == 0,    "same-cycle set+bar: set_i wins, NO load on that cycle");
        chk(pending === 1'b1, "same-cycle set+bar: the request is still pending");
        do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 1,     "same-cycle set+bar applies at the NEXT bar_start");
        chk(last_val == 8'd90, "the value applied is the same-cycle one (90)");

        // ══ 判据 ⑧：复位必须**清掉**挂起（⭐ 否则一个残局会永久挂着 ══
        //            ⚠️ 与 `calib_cmd` 的 `bpm_arm_q` 是**同一类**教训 ✅）
        do_set(8'd222);
        repeat (2) @(negedge clk);
        chk(pending === 1'b1, "pending is set before the reset test");
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        chk(pending === 1'b0, "reset CLEARS pending_o");
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        load_cnt = 0;
        do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 0, "after reset a bar alone still does not load (pending really cleared)");

        // ══ 判据 ⑨：⭐ 端点值也要能过（⭐ 40 / 240 是 `play_seq` 的限幅端点）══
        load_cnt = 0;
        do_set(8'd40);
        do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 1 && last_val == 8'd40, "endpoint 40 BPM survives the round trip");
        load_cnt = 0;
        do_set(8'd240);
        do_bar;
        repeat (2) @(negedge clk);
        chk(load_cnt == 1 && last_val == 8'd240, "endpoint 240 BPM survives the round trip");

        $display("");
        if (errors == 0)
            $display("PASS: bpm_bar_quant -- a manual change arms only, lands exactly ONCE on the next bar_start with the latched value, is one-shot, is reset-cleared, and bar_start alone is inert");
        else
            $fatal(1, "FAIL: tb_bpm_bar_quant had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
