`timescale 1ns/1ps
// tb_top_ctrl_wire.sv -- ⭐⭐ 2026-10-14：⭐ **控制板 16 键 + EC11 接进 `top.v` 的端到端判据**
//
//   ⭐ **为什么必须单独一条**：
//      ⭐ `tb/w3a/tb_ctrl_keypad.sv` 验的是**两个模块本身**（⭐ 扫描/去抖/映射 ✅）
//      🔴 **但它⛔ 不验"接进 `top.v` 之后命令真的到了下游"** ——
//         ⚠️ 而那一层恰恰是**最容易出错**的地方：
//            · 🔴 **多驱动**（⭐ `ctrl_row_o` 的常量驱动行忘了删 ⇒ 综合报错）
//            · 🔴 **OR 漏了一条**（⭐ 键按下但命令不触发）
//            · 🔴 **串口被顶掉**（⭐ 把 OR 写成替换 ⇒ 串口命令失效 ✅）
//      ⇒ ⭐ 本 tb **三条都覆盖** ✅
//
//   ⭐⭐ **判据（⭐ 每条都能失败 ✅）**：
//      ① ⭐ 无按键 ⇒ ⭐ **什么都不许翻转**（⭐ 非空洞基线 ✅）
//      ② ⭐ 键 idx 0（节拍器 `B`）⇒ ⭐ `met_on_r` **翻转** ✅
//      ③ ⭐ 再按一次 ⇒ ⭐ **翻回去** ✅
//      ④ ⭐ 键 idx 2（滑音 `W`）⇒ ⭐ `slide_on_r` 翻转 ✅
//      ⑤ ⭐ 键 idx 1（音色 `I`）⇒ ⭐ `timbre_sel_r` **自增** ✅
//      ⑥ 🔴 **串口命令仍然有效**（⭐ 用户明确要求"串口命令也要保留" ✅）：
//         ⭐ 用**真 UART** 发 `'B'` ⇒ ⭐ `met_on_r` **照样翻转** ✅
//      ⑦ ⭐ EC11 旋转（⭐ 对象 = BPM）⇒ ⭐ `tick_inc_o` **+1374**（⭐ = +1 BPM ✅）
//      ⑧ ⭐ EC11 按压 ⇒ ⭐ 对象切换 ⇒ ⭐ 再旋转 ⇒ ⭐ `tick_inc_o` **不动**（⭐ 已切到变调 ✅）
//
//   ⚠️ **为什么能跑得快**：⭐ `defparam` 把扫描/去抖调到最小
//      （⭐ `SCAN_DIV 12500→4` · `DEB_N 8→2` · EC11 `DB_MS 5→1` ✅）
//      ⇒ ⚠️ 否则一次扫描 1 ms、一次去抖 8 ms、EC11 一步 5 ms ⇒ 🔴 仿真跑不动 ✅
//
//   ⚠️ **纪律（⭐ 本 tb 第一版踩到）**：
//      🔴 iverilog **⛔ 不接受 `begin : name` 块内的 `reg` 声明**
//         ⇒ ⚠️ 报 `Syntax error in variable list` ✅
//      🔴 且 **块标签⛔ 不能与模块级信号重名**（⭐ 否则 `already declared` ✅）
//      ⇒ ⭐ 本版**所有临时量都声明在模块级**、⭐ 块标签一律加 `_blk` 后缀 ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ ⭐ **本文件必须【无 BOM】**（⭐ 见 `tools/check_no_bom.ps1` ✅）

`timescale 1ns/1ps

module tb_top_ctrl_wire;

    reg clk = 1'b0, rst_n = 1'b0, rx = 1'b1;
    always #10 clk = ~clk;                      // ⭐ 50 MHz

    // ── ⭐ 控制板矩阵 + EC11（⭐ 由本 tb 驱动 ✅）─────────────────────────
    wire [3:0] ctrl_row_w;
    reg  [3:0] ctrl_col_r;
    reg        enc_a = 1'b1, enc_b = 1'b1, enc_sw = 1'b1;

    wire sclk, mosi;
    wire [5:0] cs, miso;

    top dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(rx),
        .timbre_btn_i(1'b1), .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_cs_n(cs), .spi_miso(miso),
        //  ⭐⭐ 控制板（⭐ 2026-10-14 新接 ✅）
        .ctrl_row_o (ctrl_row_w),
        .ctrl_col_i (ctrl_col_r),
        .enc_a_i    (enc_a),
        .enc_b_i    (enc_b),
        .enc_sw_i   (enc_sw)
    );

    //  ⭐ 三个 ADC 模型（⭐ 与 `tb_top_scope_live` 同一套 ✅）
    mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3] = 3'b111;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ **仿真提速**：⭐ 把扫描/去抖调到最小（⭐ ⛔ 不改 RTL，只 defparam ✅）
    // ═══════════════════════════════════════════════════════════════════════
    defparam dut.u_ctrl_keypad.SCAN_DIV = 4;      // ⭐ 250 µs → 80 ns
    defparam dut.u_ctrl_keypad.DEB_N    = 2;      // ⭐ 8 次扫描 → 2 次
    //  ⭐⭐ EC11 去抖：⭐ **`CLK_HZ` 也必须调小** ✅
    //     ⚠️ 只调 `DB_MS` 不够：⭐ `DB_CYC = (CLK_HZ/1000) × DB_MS`
    //        ⇒ ⭐ `DB_MS=1` 仍是 **50000 拍/步** ⇒ 🔴 一次 4 步 = 20 万拍
    //        ⇒ 🔴 **实测：整条 tb 撞上 120 s 预算被 iverilog 判超时** ✅
    //     ✅ 把 `CLK_HZ` 调到 **50 kHz** ⇒ ⭐ `DB_CYC = 50 拍` ⇒ ⭐ 一步只要 200 拍 ✅
    defparam dut.u_enc_debounce.CLK_HZ  = 50_000;
    defparam dut.u_enc_debounce.DB_MS   = 1;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ **矩阵模型**：⭐ 当前被拉低的那一行里，被按下的键把对应列拉低 ✅
    //     📌 与真板一致：⭐ 行**逐行拉低**、列**上拉只读** ⇒ ⭐ 同列两键也不推挽 ✅
    // ═══════════════════════════════════════════════════════════════════════
    reg [15:0] pressed = 16'd0;
    integer    rr, cc2;
    always @(*) begin
        ctrl_col_r = 4'b1111;
        for (rr = 0; rr < 4; rr = rr + 1) begin
            if (!ctrl_row_w[rr]) begin
                for (cc2 = 0; cc2 < 4; cc2 = cc2 + 1) begin
                    if (pressed[rr*4 + cc2]) ctrl_col_r[cc2] = 1'b0;
                end
            end
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

    //  ⭐ 真 UART 发一个字节（⭐ 与 `tb_top_scope_live` 同一套：100 拍/位 ✅）
    task send_byte;
        input [7:0] cmd;
        integer bi;
        begin
            @(negedge clk); rx = 1'b0; repeat (100) @(negedge clk);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rx = cmd[bi]; repeat (100) @(negedge clk);
            end
            rx = 1'b1; repeat (150) @(negedge clk);
        end
    endtask

    //  ⭐ 按下一个键并保持
    task press_key;
        input integer idx;
        begin
            @(negedge clk);
            pressed[idx] = 1'b1;
            repeat (400) @(negedge clk);        // ⭐ 够 2 次扫描（⭐ 1 次 = 16 拍 ✅）
        end
    endtask

    task release_all;
        begin
            @(negedge clk);
            pressed = 16'd0;
            repeat (400) @(negedge clk);
        end
    endtask

    //  ⭐ EC11 走一步（⭐ 格雷序列 ✅）
    //     📌 ⭐ **方向必须严格按 `debounce.v` 的合法表**（⭐ `enc_state = {enc_b, enc_a}` ✅）：
    //        · ⭐ **CW**  = `00→01→11→10→00`
    //        · ⭐ **CCW** = `00→10→11→01→00`
    //     🔴 **本 tb 第一版写错了**：⭐ 从空闲 `11` 起直接跳到 `01`
    //        ⇒ ⚠️ `11→01` 是 **CCW** ⇒ 🔴 净 **3×CW − 1×CCW = +2 BPM**
    //        ⇒ ⭐ 而判据期望 **+1** ⇒ 🔴 **假失败**（⭐ 是 tb 错、⛔ 不是 RTL 错 ✅）
    //     ✅ **正确写法**：⭐ 从空闲 `11` 起，⭐ **CW = `11→10→00→01→11`** ✅
    //     📌 ⭐ 每步保持 **300 拍** = `DB_CYC(50)` 的 **6 倍** ⇒ ⭐ 稳够 ✅
    task enc_step;
        input cwd;
        begin
            if (cwd) begin
                // ⭐ CW：11 → 10 → 00 → 01 → 11
                @(negedge clk); enc_a = 1'b0; enc_b = 1'b1; repeat (300) @(negedge clk);
                @(negedge clk); enc_a = 1'b0; enc_b = 1'b0; repeat (300) @(negedge clk);
                @(negedge clk); enc_a = 1'b1; enc_b = 1'b0; repeat (300) @(negedge clk);
                @(negedge clk); enc_a = 1'b1; enc_b = 1'b1; repeat (300) @(negedge clk);
            end else begin
                // ⭐ CCW：11 → 01 → 00 → 10 → 11
                @(negedge clk); enc_a = 1'b1; enc_b = 1'b0; repeat (300) @(negedge clk);
                @(negedge clk); enc_a = 1'b0; enc_b = 1'b0; repeat (300) @(negedge clk);
                @(negedge clk); enc_a = 1'b0; enc_b = 1'b1; repeat (300) @(negedge clk);
                @(negedge clk); enc_a = 1'b1; enc_b = 1'b1; repeat (300) @(negedge clk);
            end
        end
    endtask

    //  ⭐ EC11 按压
    task enc_press;
        begin
            @(negedge clk); enc_sw = 1'b0; repeat (300) @(negedge clk);
            @(negedge clk); enc_sw = 1'b1; repeat (300) @(negedge clk);
        end
    endtask

    //  ══ ⭐ 判据用的临时量 —— **必须声明在模块级** ══
    //     🔴 iverilog ⛔ 不接受 `begin : name` 块内的 `reg` 声明 ✅
    reg [31:0] inc_a, inc_b;
    reg        b_met0, b_sl0, b_before;
    reg [1:0]  b_timbre;
    //  ⭐⭐ 判据 ⑨：⭐ **监视 `cmd_loop_clear_req` 有没有幻影脉冲** ✅
    integer    n_lclr = 0;
    always @(posedge clk) if (rst_n && dut.cmd_loop_clear_req) n_lclr = n_lclr + 1;

    initial begin
        $dumpfile("build/sim/tb_top_ctrl_wire/tb_top_ctrl_wire.vcd");
        $dumpvars(0, tb_top_ctrl_wire);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (600) @(negedge clk);

        // ══ 判据 ①：⭐ **非空洞基线** —— 不按键 ⇒ ⭐ 什么都不许翻转 ══
        begin : base_blk
            b_met0 = dut.met_on_r; b_sl0 = dut.slide_on_r;
            repeat (2000) @(negedge clk);
            chk(dut.met_on_r   === b_met0, "baseline: with NO key pressed, met_on_r does not move");
            chk(dut.slide_on_r === b_sl0,  "baseline: with NO key pressed, slide_on_r does not move");
        end

        // ══ 判据 ②③：⭐ 键 idx 0（节拍器 `B`）⇒ `met_on_r` 翻转、再按翻回 ══
        begin : k0_blk
            b_before = dut.met_on_r;
            press_key(0);
            chk(dut.met_on_r !== b_before,
                "*** key idx 0 (metronome 'B') TOGGLES met_on_r -- the keypad really reaches the downstream ***");
            release_all;
            b_before = dut.met_on_r;
            press_key(0);
            chk(dut.met_on_r !== b_before, "key idx 0 pressed again toggles back");
            release_all;
        end

        // ══ 判据 ④：⭐ 键 idx 2（滑音 `W`）⇒ `slide_on_r` 翻转 ══
        begin : k2_blk
            b_before = dut.slide_on_r;
            press_key(2);
            chk(dut.slide_on_r !== b_before, "key idx 2 (slide 'W') toggles slide_on_r");
            release_all;
        end

        // ══ 判据 ⑤：⭐ 键 idx 1（音色 `I`）⇒ `timbre_sel_r` 自增 ══
        begin : k1_blk
            b_timbre = dut.timbre_sel_r;
            press_key(1);
            chk(dut.timbre_sel_r === (b_timbre + 2'd1),
                "key idx 1 (timbre 'I') steps timbre_sel_r by one");
            release_all;
        end

        // ══ 判据 ⑥：🔴 **串口命令【仍然有效】**（⭐ 用户明确要求"串口命令也要保留" ✅）══
        //     ⭐ 这条直接证伪"把 OR 写成替换"这种改法 ✅
        begin : serial_blk
            b_before = dut.met_on_r;
            send_byte(8'h42);                       // ⭐ 'B'（节拍器切换）
            repeat (400) @(negedge clk);
            chk(dut.met_on_r !== b_before,
                "*** the SERIAL 'B' command STILL toggles met_on_r (the OR kept the serial path alive) ***");
        end

        // ══ 判据 ⑦：⭐ EC11 旋转（⭐ 对象 = BPM）⇒ ⭐ `tick_inc_o` +1374 ══
        begin : enc_bpm_blk
            inc_a = dut.g_sound.u_play_seq.tick_inc_o;
            enc_step(1'b1);                         // ⭐ 顺时针一格
            repeat (200) @(negedge clk);
            inc_b = dut.g_sound.u_play_seq.tick_inc_o;
            chk(inc_b === (inc_a + 32'd1374),
                "*** EC11 CW with object=BPM raises tick_inc_o by exactly 1374 (= +1 BPM) ***");
        end

        // ══ 判据 ⑧：⭐ 按压 ⇒ 对象切换 ⇒ ⭐ 再旋转 ⇒ `tick_inc_o` **不动** ══
        //     📌 ⭐ 切到"变调"之后，⭐ 旋钮改的是 `transpose_semi`，⛔ 不再是 BPM ✅
        begin : enc_obj_blk
            enc_press;                              // ⭐ 对象：BPM → 变调
            inc_a = dut.g_sound.u_play_seq.tick_inc_o;
            enc_step(1'b1);                         // ⭐ 顺时针一格
            repeat (200) @(negedge clk);
            inc_b = dut.g_sound.u_play_seq.tick_inc_o;
            chk(inc_b === inc_a,
                "*** after the EC11 press the object is TRANSPOSE, so tick_inc_o must NOT move ***");
        end

        // ══ 判据 ⑨：🔴 **键盘不许【幻影】触发 looper 清空**（⭐ 2026-10-14 用户报的 bug ✅）══
        //     ⭐ 依据：⭐ `top.v` 里 `cmd_loop_clear_req = cc_loop_clear_req | km_loop_clear_req`
        //        ⇒ ⚠️ 若键盘**幻影**触发 idx 12（looper 清空）
        //        ⇒ 🔴 looper 被清 ⇒ ⭐ `looper_evt_cnt = 0`
        //        ⇒ ⭐ 症状（⭐ 用户原话）：⭐ `'Y'` 回 `'!'` ＋ ⭐ `L` **没回放** ✅
        //     📌 ⭐ 所以本判据是**回归防线**：⭐ 无按键时那条线**必须一直是 0** ✅
        //     📌 同时查 `rd_lock` —— ⭐ 它卡住会**同时**拒掉 `'Y'` 与 `R`/`L`/`C` ✅
        begin : no_phantom_blk
            n_lclr = 0;
            repeat (30000) @(negedge clk);      // ⭐ 无按键 ⇒ 扫很多轮（⭐ 约 1900 次扫描 ✅）
            chk(n_lclr == 0,
                "*** NO key pressed => cmd_loop_clear_req stays quiet (a phantom clear would wipe the looper) ***");
            chk(dut.rd_lock === 1'b0,
                "*** rd_lock is LOW at rest (a stuck rd_lock would reject R/L/C AND 'Y') ***");
            chk(dut.g_sound.looper_evt_cnt === 16'd0,
                "looper_evt_cnt is 0 when nothing has been recorded (sanity)");
        end

        // ══ 判据 ⑩：⭐ **`'U'` 指引模式**（⭐ 2026-10-14 新加 ✅）══
        //     ⭐ 依据：⭐ `files/20-代码/LED指引-实现计划清单-20261014.md` §L1 ✅
        //     🔴 **必须验三条**（⚠️ 少一条就是"看起来做了、其实没做到"）：
        //        ① ⭐ `'U'` 能切换（⭐ 命令通路 ✅）
        //        ② ⭐ 切了之后，⭐ **曲谱的【出声】那一路真的被闸住** ✅
        //        ③ ⭐ 关掉之后**必须恢复**（⭐ 防"改过头、再也出不了声" ✅）
        //     📌 ⭐ **怎么低成本验 ②③**：⭐ 用 `force` 直接驱动 `ps_note_valid`
        //        ⇒ ⭐ 就能在**完全不灌谱**的前提下，看 `seq_arb.score_valid_i` 通不通 ✅
        //     📌 ⚠️ `ps_note_valid` / `guide_only_r` 都在**模块级** ⇒ 路径是 `dut.xxx` ✅
        begin : guide_mode_blk
            send_byte(8'h55);                        // ⭐ 'U'
            repeat (3000) @(negedge clk);
            chk(dut.guide_only_r === 1'b1, "*** 'U' turns GUIDE MODE on (guide_only_r = 1) ***");

            force dut.ps_note_valid = 1'b1;          // ⭐ 伪造"有音符到达" ✅
            repeat (4) @(negedge clk);
            chk(dut.g_sound.u_seq_arb.score_valid_i === 1'b0,
                "*** in GUIDE MODE the score's AUDIO path is gated OFF (seq_arb.score_valid_i = 0) ***");
            release dut.ps_note_valid;

            send_byte(8'h55);                        // ⭐ 'U' ⇒ 关
            repeat (3000) @(negedge clk);
            chk(dut.guide_only_r === 1'b0, "'U' again turns the guide mode back OFF");

            force dut.ps_note_valid = 1'b1;
            repeat (4) @(negedge clk);
            chk(dut.g_sound.u_seq_arb.score_valid_i === 1'b1,
                "*** back in NORMAL mode the score's audio path is OPEN again (no over-gating) ***");
            release dut.ps_note_valid;
        end

        // ══ 判据 ⑪：⭐⭐ 2026-10-15：⭐ **键 idx 14（列 2 / 行 3）⇒ 一键恢复默认音高** ══
        //     ⭐ 用户需求：*"矩阵键盘加一个键：一键恢复默认音高"* ✅
        //     ⭐ 为什么放在**本 tb**（⭐ 而不是 `tb_ctrl_keypad`）：
        //        ⭐ 本 tb 跑的是**真 `top.v`** ⇒ ⭐ 验的是**接线**（⭐ OR ＋ mux ✅）
        //        ⭐ 而 `tb_ctrl_keypad` 只能验"模块本身出了脉冲"（⭐ 到不了 `fader_gear` ✅）
        //     ⭐ 链路：⭐ 键 14 ⇒ `u_ctrl_key_map.trans_reset_req_o`
        //        ⇒ ⭐ `top.v` 把它 OR 进 `u_fader_gear.trans_abs_i`、⭐ 并选值 `8'd12`
        //        ⇒ ⭐ `enc_r = 12` ⇒ ⭐ `transpose_semi_o = 12 − 12 = 0` ✅
        //     🔴 **必须能红**（⭐ 三条，⛔ 缺任一条就是空洞判据）：
        //        ① ⭐ **非空洞前置**：⭐ 先按 idx 6（变调升 `G`）3 次
        //           ⇒ ⭐ `transpose_semi` **必须先离开 0** ——
        //           ⚠️ 否则"按 14 之后是 0"**毫无信息量**（⭐ 本来就可能是 0 ✅）
        //        ② ⭐ 按 idx 14 ⇒ ⭐ **恰好回到 0**（⭐ 不是"变小了"✅）
        //        ③ ⭐ 换个偏移**再来一次** ⇒ ⭐ 还是 0（⭐ 排除"碰巧"✅）
        //     📌 ⭐ 观测点 = **模块级 `dut.transpose_semi`** ——
        //        ⭐ 它直接喂 `note_manager.transpose_semi_i` ⇒ ⭐ 是"下游真正看到的那个值" ✅
        //        （⭐ 若只想盯寄存器，⭐ `dut.g_sound.u_fader_gear.enc_r === 5'd12` 亦可 ✅）
        begin : key14_pitch_reset_blk
            // ⭐ ① 先让它偏离 0
            press_key(6); release_all;
            press_key(6); release_all;
            press_key(6); release_all;
            repeat (200) @(negedge clk);
            chk(dut.transpose_semi !== 5'sd0,
                "*** non-vacuity: key idx 6 (transpose UP x3) really moved transpose_semi OFF zero ***");

            // ⭐ ② 按 idx 14 ⇒ ⭐ 回默认音高
            press_key(14); release_all;
            repeat (200) @(negedge clk);
            chk(dut.transpose_semi === 5'sd0,
                "*** key idx 14 (col2/row3) RESETS the pitch to DEFAULT: transpose_semi == 0 ***");
            chk(dut.g_sound.u_fader_gear.enc_r === 5'd12,
                "*** and the underlying encoding is exactly 12 (= no transposition) ***");

            // ⭐ ③ 换个偏移再来一次 ⇒ ⭐ 仍是 0（⭐ 排除"碰巧"✅）
            press_key(6); release_all;
            press_key(6); release_all;
            repeat (200) @(negedge clk);
            chk(dut.transpose_semi === 5'sd2,
                "*** two more UP presses => transpose_semi is exactly +2 (the counter really works) ***");
            press_key(14); release_all;
            repeat (200) @(negedge clk);
            chk(dut.transpose_semi === 5'sd0,
                "*** key idx 14 resets AGAIN from a DIFFERENT offset (not a one-off coincidence) ***");
        end

        $display("");
        if (errors == 0)
            $display("PASS: control-board wiring -- the 4x4 keypad really toggles the downstream state, the serial path is preserved alongside it, and the EC11 routes to BPM or transpose depending on the selected object");
        else
            $fatal(1, "FAIL: tb_top_ctrl_wire had %0d error(s)", errors);

        #100;
        $finish;
    end

    initial begin
        #2000000;                                   // ⭐ 2 ms 上限（⭐ 含判据⑨的 30000 拍监视 ✅）
        $display("FAIL: tb_top_ctrl_wire timed out");
        $fatal(1, "timeout");
    end

endmodule
