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

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-14：⭐ **按 v1.1 位域【构造/预测】测试字**（⭐ 换成 14 B 帧后新加 ✅）
    //     📌 ⭐ **为什么必须换测试字**：⭐ 原来那批（`A0A0_…`）**低位几乎全 0**
    //        ⇒ ⚠️ `axis`/`vel`/`kind`/`inc` 就算映射写错也**测不出来** ⇒ 🔴 **弱判据** ✅
    //     ✅ 现在每个字段都填**互不相同的非零值** ⇒ ⭐ 映射错了**必红** ✅
    //     📌 ⭐ 位域与 `rtl/top.v:4506` 的表、`tools/mid2evt.py:124-130` **逐位一致** ✅
    // ═══════════════════════════════════════════════════════════════════════
    function [63:0] mk_word;
        input [19:0] tk;
        input [20:0] ic;
        input [3:0]  ax;
        input [7:0]  vl;
        input [1:0]  kd;
        input [1:0]  tb2;
        begin
            mk_word = {tk, ic, ax, vl, kd, tb2, 7'b0};
        end
    endfunction

    //  ⭐ 预测 14 B 帧的**第 idx 个字节**（⭐ 与 `rec_dump.v` 的 `f_*` **逐位同构** ✅）
    function [7:0] exp_byte;
        input [63:0] w;
        input [7:0]  sq;
        input [3:0]  idx;
        reg   [7:0]  ty, b7, vl8, ck;
        reg   [31:0] tk32, ic32;
        begin
            ty   = (w[10:9] == 2'd1) ? 8'h02 : 8'h01;      // ⭐ [1] 类型
            tk32 = {12'd0, w[63:44]};                       // ⭐ [3..6] tick32
            //  ⭐⭐ 2026-10-18：⭐ `[7] = {pad, is_drum, timbre[1:0], axis[3:0]}`
            //     🔴 改前是 `{4'd0, w[22:19]}`（⭐ 只有 axis）⇒ ⭐ 音色被丢掉 ⇒
            //        ESP32 解出恒 0（BASS）⇒ 用户报"录 BASS 回放 GUITAR" ✅
            //     📌 与 `rtl/w3c/rec_dump.v` 的 `f_b7`、以及 `evt_upstream.v:290`
            //        的 `{1'b0, dr, tm, ax}` **逐位同构** ✅
            //     ⭐ `is_drum` 恒 0：`looper` 录制时就排除鼓（`looper.v:1368`）✅
            b7   = {1'b0, 1'b0, w[8:7], w[22:19]};          // ⭐ [7] {pad,is_drum,timbre,axis}
            ic32 = {1'b0, w[43:23], 10'b0};                 // ⭐ [8..11] inc32（⭐ 还原全 32 位）
            vl8  = w[18:11];                                // ⭐ [12] vel
            //  ⭐ [13] 校验 = XOR 覆盖 **[0..12]（⭐ 含帧头 ✅）**
            ck   = 8'hA5 ^ ty ^ sq
                 ^ tk32[31:24] ^ tk32[23:16] ^ tk32[15:8] ^ tk32[7:0]
                 ^ b7 ^ ic32[31:24] ^ ic32[23:16] ^ ic32[15:8] ^ ic32[7:0] ^ vl8;
            case (idx)
                4'd0:    exp_byte = 8'hA5;
                4'd1:    exp_byte = ty;
                4'd2:    exp_byte = sq;                     // ⭐ 序号随帧号变 ✅
                4'd3:    exp_byte = tk32[31:24];
                4'd4:    exp_byte = tk32[23:16];
                4'd5:    exp_byte = tk32[15:8];
                4'd6:    exp_byte = tk32[7:0];
                4'd7:    exp_byte = b7;                      // ⭐ {pad,is_drum,timbre,axis}
                4'd8:    exp_byte = ic32[31:24];
                4'd9:    exp_byte = ic32[23:16];
                4'd10:   exp_byte = ic32[15:8];
                4'd11:   exp_byte = ic32[7:0];
                4'd12:   exp_byte = vl8;
                default: exp_byte = ck;
            endcase
        end
    endfunction

    initial begin
        //  ⭐⭐⭐ 2026-10-14：⭐ **测试字换成"每个字段都非零且互不相同"** ✅
        //     📌 ⭐ 原来 `A0A0_0000_0000_0001` 这种 ⇒ ⚠️ `inc`/`axis`/`vel`/`kind` 全是 0
        //        ⇒ 🔴 **字段映射写错也测不出来** ✅
        //     📌 ⭐ `kind` 刻意一条 `0`（note_on ⇒ `0x01`）一条 `1`（note_off ⇒ `0x02`）✅
        mem[0] = mk_word(20'h12345, 21'h1ABCD, 4'd5,  8'h5A, 2'd0, 2'd1);  clip_mem[0] = 1'b0;
        mem[1] = mk_word(20'h6789A, 21'h0FEDC, 4'd10, 8'hC3, 2'd1, 2'd2);  clip_mem[1] = 1'b0;
        mem[2] = mk_word(20'h0BEEF, 21'h15555, 4'd15, 8'h07, 2'd0, 2'd3);  clip_mem[2] = 1'b1;   // ⭐ 截断
        mem[3] = mk_word(20'h0CAFE, 21'h1AAAA, 4'd1,  8'hFF, 2'd1, 2'd0);  clip_mem[3] = 1'b0;
        mem[4] = mk_word(20'h0DEAD, 21'h12345, 4'd8,  8'h11, 2'd0, 2'd2);  clip_mem[4] = 1'b1;   // ⭐ 截断
        mem[5] = mk_word(20'h0F00D, 21'h1FFFF, 4'd3,  8'h80, 2'd1, 2'd3);  clip_mem[5] = 1'b0;
        mem[6] = mk_word(20'h01234, 21'h10001, 4'd12, 8'h42, 2'd0, 2'd0);  clip_mem[6] = 1'b0;
        mem[7] = mk_word(20'h0ABCD, 21'h1F0F0, 4'd7,  8'h99, 2'd1, 2'd1);  clip_mem[7] = 1'b0;

        do_reset;
        $display("=== tb_rec_dump（录制回传的导出 FSM）===");

        // ═════════════════════════════════════════════════════════════════
        $display("== D 正常导出：3 条事件 ⇒ 42 字节（14 × 3 = v1.1 帧）==");
        // ═════════════════════════════════════════════════════════════════
        cnt = 16'd3;
        n_done = 0;
        pulse_req;
        wait_done(4000);

        chk(n_rx == 42, "D1 3 events => exactly 42 bytes pushed (14 each = v1.1 frame)");
        //  ⭐⭐ 2026-10-14：⭐ **逐字节验 14 B v1.1 帧**（⭐ 头/类型/序号/tick/axis/inc/vel/校验 ✅）
        //     📌 ⭐ **不匹配时打印"帧号/字节号/实测/期望/源字"** ——
        //        ⚠️ 否则只报一句 FAIL，⛔ 定位不了是哪个字段 ✅
        for (k = 0; k < 3; k = k + 1) begin
            for (b = 0; b < 14; b = b + 1) begin
                if (rx[k*14 + b] !== exp_byte(mem[k], k[7:0], b[3:0])) begin
                    $display("  MISMATCH frame %0d byte %0d: got %02h expected %02h  (word=%016h)",
                             k, b, rx[k*14 + b], exp_byte(mem[k], k[7:0], b[3:0]), mem[k]);
                    fail_cnt = fail_cnt + 1;
                end else begin
                    pass_cnt = pass_cnt + 1;
                end
            end
        end
        chk(frame_cnt === 16'd3, "D4 frame_cnt counts 3 frames");
        //  ⭐⭐ 2026-10-18：⭐ **非空洞判据 —— `byte[7]` 必须真的带音色** ✅
        //     🔴 背景：⭐ 原来 `byte[7]` 只有 `axis`，⭐ `[5:4]`（音色）与 `[6]`（is_drum）
        //        被硬写 0 ⇒ ⭐ ESP32 解出恒 0（BASS）⇒ 用户报"录 BASS、回放 GUITAR" ✅
        //     📌 测试字的音色是 1 / 2 / 3（⭐ 见 `mem[0..2]` 的 `mk_word` 末参数）⇒
        //        ⭐ 三条帧必须分别出现 1 / 2 / 3 —— ⛔ 全是 0 就是老 bug 回来了 ✅
        //     ⚠️ 这条**必须能红**：把 `rec_dump` 的 `f_b7` 改回 `{4'd0, axis}` ⇒ 立刻 FAIL
        chk(rx[0*14 + 7][5:4] === 2'd1, "D8a frame0 byte[7][5:4] == 1 (word0 timbre)");
        chk(rx[1*14 + 7][5:4] === 2'd2, "D8b frame1 byte[7][5:4] == 2 (word1 timbre)");
        chk(rx[2*14 + 7][5:4] === 2'd3, "D8c frame2 byte[7][5:4] == 3 (word2 timbre)");
        chk(rx[0*14 + 7][6]   === 1'b0, "D8d byte[7][6] (is_drum) == 0 -- looper never records drums");
        chk(rx[0*14 + 7][7]   === 1'b0, "D8e byte[7][7] (pad) == 0");
        chk(rx[0*14 + 7][3:0] === 4'd5, "D8f byte[7][3:0] still carries the axis (5)");

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
        chk(n_rx == 56, "E1 ready_i throttling loses NO byte (4 events => 56 bytes = 14 x 4)");
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
        chk(n_rx == 28, "G1 first dump pushed 28 bytes (14 x 2)");
        n_rx = 0;
        pulse_req; wait_done(4000);
        chk(n_rx == 28, "G2 the dump can be triggered AGAIN (no stuck state)");
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
