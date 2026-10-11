`timescale 1ns/1ps
`default_nettype none
// ═══════════════════════════════════════════════════════════════════════════
// tb_rec_dump.sv · ⭐⭐ 2026-10-11：⭐ **录制回传的导出 FSM 判据** ✅
//
//   ⭐ **被测行为**：⭐ `'Y'` ⇒ ⭐ 把 `looper` 已录的事件按 **9 字节帧**
//      （⭐ `0xA5` ＋ 8 字节【大端】✅）逐条推给 `u_tx_fifo` ✅
//
//   ⭐⭐ **本 tb 最关键的两条**：
//     ⭐ `D3` ⭐ **载荷逐字节等于 `mem[k]` 的大端** ——
//        🔴 它**同时**抓住"地址错"与"**少等一拍**"两种错 ✅
//        （⭐ 因为 `mem[]` 的值**刻意两两不同** ⇒ ⚠️ 读早一拍必然读到上一条 ✅）
//     ⭐ `D8` ⭐ **`ready_i` 节流**：⭐ 中途拉低 `ready` ⇒ ⭐ **一个字节都不许丢** ✅
//
//   ⚠️ **读口模型必须与真 `looper` 一致**：⭐ **同步读**（⭐ 打一拍 ✅）——
//      ⭐ `looper.v:551-560` 记着那条教训：⭐ 异步读 ⇒ 🔴 **BSRAM 推不出来**
//      （⭐ `135168 > 60780` 的综合失败 ✅）⇒ ⭐ 模型也必须寄存 ✅
// ═══════════════════════════════════════════════════════════════════════════

module tb_rec_dump;

    localparam integer ADDR_W = 16;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ── ⭐ "looper 读口"模型（⭐ **同步读**，⭐ 与真 looper 一致 ✅）────────────
    reg [63:0] mem      [0:7];
    reg        clip_mem [0:7];
    reg [63:0] mem_out;
    reg        clip_out;
    wire [ADDR_W-1:0] daddr;
    wire              den;
    always @(posedge clk) begin
        mem_out  <= mem[daddr];
        clip_out <= clip_mem[daddr];
    end

    // ── ⭐ 被测 ─────────────────────────────────────────────────────────────
    reg              req  = 1'b0;
    reg              idle = 1'b1;
    reg [ADDR_W-1:0] cnt  = {ADDR_W{1'b0}};
    reg              ready = 1'b1;
    wire             push;
    //  ⚠️ ⭐ **⛔ 不能叫 `byte`** —— ⚠️ 它在 `-g2012` 下是 **SystemVerilog 关键字**
    //     ⇒ 🔴 `error: Invalid module item`（⭐ 实测踩到 ✅）
    wire [7:0]       byt;
    wire             busy, done;
    wire [15:0]      clip_cnt, frame_cnt;

    rec_dump #(.ADDR_W(ADDR_W), .HDR(8'hA5)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .req_i(req), .idle_i(idle), .cnt_i(cnt),
        .data_i(mem_out), .clip_i(clip_out),
        .ready_i(ready), .push_o(push), .byte_o(byt),
        .dump_en_o(den), .dump_addr_o(daddr),
        .busy_o(busy), .done_o(done),
        .clip_cnt_o(clip_cnt), .frame_cnt_o(frame_cnt)
    );

    // ── ⭐ 收集推出来的字节（⭐ 队列模型 ✅）──────────────────────────────────
    reg [7:0] rx [0:255];
    integer   n_rx = 0;
    always @(posedge clk)
        if (rst_n && push && (n_rx < 256)) begin
            rx[n_rx] = byt;
            n_rx = n_rx + 1;
        end

    integer i, k, b;
    integer n_done;

    task do_reset;
        begin
            rst_n = 1'b0; req = 1'b0; idle = 1'b1; ready = 1'b1;
            cnt = {ADDR_W{1'b0}};
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            n_rx = 0;
        end
    endtask

    task pulse_req;
        begin
            @(negedge clk); req = 1'b1;
            @(negedge clk); req = 1'b0;
        end
    endtask

    //  ⭐ 等到 `done` 或超时（⭐ 看门狗在模块末尾 ✅）
    task wait_done;
        input integer maxc;
        integer w;
        begin
            w = 0;
            while (!done && (w < maxc)) begin @(negedge clk); w = w + 1; end
        end
    endtask

    initial begin
        //  ⭐ 八条事件，⭐ **值刻意两两不同**（⭐ 这样"读早一拍"必然错 ✅）
        mem[0] = 64'hA0A0_0000_0000_0001;  clip_mem[0] = 1'b0;
        mem[1] = 64'hB1B1_0000_0000_0002;  clip_mem[1] = 1'b0;
        mem[2] = 64'hC2C2_0000_0000_0003;  clip_mem[2] = 1'b1;   // ⭐ 截断
        mem[3] = 64'hD3D3_0000_0000_0004;  clip_mem[3] = 1'b0;
        mem[4] = 64'hE4E4_0000_0000_0005;  clip_mem[4] = 1'b1;   // ⭐ 截断
        mem[5] = 64'hF5F5_0000_0000_0006;  clip_mem[5] = 1'b0;
        mem[6] = 64'h0606_0000_0000_0007;  clip_mem[6] = 1'b0;
        mem[7] = 64'h1717_0000_0000_0008;  clip_mem[7] = 1'b0;

        do_reset;
        $display("=== tb_rec_dump（录制回传的导出 FSM）===");

        // ═════════════════════════════════════════════════════════════════
        $display("== D 正常导出：3 条事件 ⇒ 27 字节 ==");
        // ═════════════════════════════════════════════════════════════════
        cnt = 16'd3;
        n_done = 0;
        pulse_req;
        wait_done(4000);

        chk(n_rx == 27, "D1 3 events => exactly 27 bytes pushed (9 each)");
        //  ⭐ 逐帧验：⭐ `0xA5` ＋ 8 字节【大端】 ✅
        for (k = 0; k < 3; k = k + 1) begin
            chk(rx[k*9] === 8'hA5, "D2 frame header byte is 0xA5");
            for (b = 0; b < 8; b = b + 1)
                chk(rx[k*9 + 1 + b] === mem[k][63 - b*8 -: 8],
                    "D3 payload byte matches mem[k] BIG-ENDIAN (catches a 1-cycle-early read)");
        end
        chk(frame_cnt === 16'd3, "D4 frame_cnt counts 3 frames");
        chk(clip_cnt  === 16'd1, "D5 clip_cnt counts 1 clipped entry (index 2)");
        chk(den === 1'b0, "D6 the read port is RELEASED after the dump (dump_en back to 0)");
        chk(busy === 1'b0, "D7 busy is low after the dump");

        // ═════════════════════════════════════════════════════════════════
        $display("== E ready_i 节流：中途拉低 ⇒ 一个字节都不许丢 ==");
        // ═════════════════════════════════════════════════════════════════
        do_reset;
        cnt = 16'd4;
        pulse_req;
        //  ⭐ 等它推几个字节，⭐ 然后把 `ready` 拉低 50 拍 ✅
        repeat (12) @(negedge clk);
        ready = 1'b0;
        repeat (50) @(negedge clk);
        ready = 1'b1;
        wait_done(4000);
        chk(n_rx == 36, "E1 ready_i throttling loses NO byte (4 events => 36 bytes)");
        chk(rx[0] === 8'hA5, "E2 the stream still starts with the header after the stall");

        // ═════════════════════════════════════════════════════════════════
        $display("== F 两个前提：⭐ 层不空闲 / ⭐ 空层 ⇒ ⛔ 都不许启动 ==");
        // ═════════════════════════════════════════════════════════════════
        do_reset;
        cnt = 16'd3;
        idle = 1'b0;                      // ⭐ 层在放音 ⇒ ⛔ 不能抢读口
        pulse_req;
        repeat (60) @(negedge clk);
        chk(n_rx == 0, "F1 NOT idle => the dump must NOT start (the read port is in use)");
        chk(den === 1'b0, "F2 ...and dump_en must stay 0");

        do_reset;
        cnt = 16'd0;                      // ⭐ 空层
        idle = 1'b1;
        pulse_req;
        repeat (60) @(negedge clk);
        chk(n_rx == 0, "F3 empty layer (cnt=0) => no dump at all");

        // ═════════════════════════════════════════════════════════════════
        $display("== G 二次导出：⭐ 必须能重复触发 ==");
        // ═════════════════════════════════════════════════════════════════
        do_reset;
        cnt = 16'd2;
        pulse_req; wait_done(4000);
        chk(n_rx == 18, "G1 first dump pushed 18 bytes");
        n_rx = 0;
        pulse_req; wait_done(4000);
        chk(n_rx == 18, "G2 the dump can be triggered AGAIN (no stuck state)");
        chk(rx[0] === 8'hA5, "G3 the second dump is well-formed too");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_rec_dump - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_rec_dump - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗
    initial begin
        #5_000_000;
        $display("FAIL: tb_rec_dump TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
