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

module tb_top_screen_param_mode;

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

    //  ⭐ 真 UART 发一个字节（⭐ 与 `tb_top_scope_live` 同一套：434 拍/位 = 115200 ✅）
    //     📌 2026-10-28 板载口改档 ⇒ tb 同步适配
    task send_byte;
        input [7:0] cmd;
        integer bi;
        begin
            @(negedge clk); rx = 1'b0; repeat (434) @(negedge clk);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rx = cmd[bi]; repeat (434) @(negedge clk);
            end
            rx = 1'b1; repeat (650) @(negedge clk);
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
    //  ⭐⭐ 判据 ⑫：⭐ **空循环拒绝计数器**（⭐ `rd_reject_r`，`g_sound` 里 ✅）
    //     📌 为什么盯它：⭐ 本 tb 里 looper **一个事件都没录**
    //        ⇒ ⭐ 此刻 `looper_evt_cnt == 0` ⇒ 任何到达 `cmd_recdump_req` 的脉冲
    //           都走**拒绝**分支（⭐ `rd_reject_event` ✅）
    //        ⇒ ⭐ 所以"拒绝计数涨没涨"就是**"脉冲到底有没有到 `cmd_recdump_req`"**
    //           的直接、单调、可证伪的观测点 ✅
    reg [15:0] n_rj = 0;
    always @(posedge clk) if (rst_n && dut.g_sound.rd_reject_event) n_rj = n_rj + 1;

    integer n;reg [15:0] before_gain;reg [31:0] before_bpm;
    initial begin
        repeat(20)@(negedge clk);rst_n=1;repeat(600)@(negedge clk);
        // Screen numeric payload bytes must not act as raw p/o commands.
        send_byte(8'h71);send_byte(8'h11);send_byte(8'h6f);
        send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0 || dut.enc_par_sel!==0 || dut.ui_fx_gain!==16'h6f00)
            $fatal(1,"FAIL: framed numeric payload 6F leaked into raw EC11 mode/selection");
        send_byte(8'h71);send_byte(8'h11);send_byte(8'h70);
        send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0 || dut.enc_par_sel!==0 || dut.ui_fx_gain!==16'h7000)
            $fatal(1,"FAIL: framed numeric payload 70 toggled EC11 mode");
        // Select transpose as the traditional object before entering from screen.
        enc_press;repeat(30)@(negedge clk);
        if(dut.enc_obj_r!==1)$fatal(1,"traditional transpose object setup");
        before_bpm=dut.g_sound.u_play_seq.tick_inc_o;
        send_byte(8'h6f);send_byte(0);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==1)$fatal(1,"FAIL: screen parameter selection did not enter parameter mode");
        before_gain=dut.ui_fx_gain;
        enc_step(1);repeat(30)@(negedge clk);
        if(dut.ui_fx_gain<=before_gain || dut.g_sound.u_play_seq.tick_inc_o!==before_bpm)$fatal(1,"EC11 did not adjust gain exclusively");
        for(n=0;n<8;n=n+1)begin
            send_byte(8'h6f);send_byte(n);send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);
            repeat(30)@(negedge clk);
            if(dut.enc_par_sel!==n[2:0] || dut.enc_param_mode!==1 || dut.ec_par_arm_q!==0)
                $fatal(1,"repeated parameter selection/suffix is not idempotent");
        end
        send_byte(8'h70);send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);
        repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0 || dut.enc_obj_r!==1)$fatal(1,"back did not restore original transpose object");
        send_byte(8'h6f);send_byte(0);repeat(30)@(negedge clk);
        send_byte(8'h71);send_byte(6);send_byte(0);
        send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0 || dut.enc_obj_r!==1)$fatal(1,"page0 did not exit parameter mode");
        send_byte(8'h71);send_byte(6);send_byte(0);
        send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0 || dut.enc_obj_r!==1)$fatal(1,"repeated page0 must not enter parameter mode");
        before_gain=dut.ui_fx_gain;enc_step(1);repeat(30)@(negedge clk);
        if(dut.ui_fx_gain!==before_gain || dut.g_sound.u_play_seq.tick_inc_o!==before_bpm)$fatal(1,"traditional mode still adjusts FX");
        // Legacy raw p toggles and o+n payload priority remain intact,
        // even when n numerically equals a screen frame header.
        send_byte(8'h6f);send_byte(8'h71);repeat(30)@(negedge clk);
        if(dut.enc_par_sel!==1 || dut.enc_param_mode!==1)$fatal(1,"raw o+71 payload was stolen by screen header guard");
        send_byte(8'h70);send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0)$fatal(1,"raw p exit after header-like parameter failed");
        send_byte(8'h70);send_byte(8'h6f);send_byte(8'h65);repeat(30)@(negedge clk);
        if(dut.enc_par_sel!==5 || dut.enc_param_mode!==1)$fatal(1,"raw p/o sequence or o+65 payload regressed");
        send_byte(8'h70);send_byte(8'hff);send_byte(8'hff);send_byte(8'hff);repeat(30)@(negedge clk);
        if(dut.enc_param_mode!==0)$fatal(1,"final raw p exit failed");
        $display("PASS: raw screen select auto-enters parameter mode, real EC11 changes gain, selection is idempotent, back restores transpose");$finish;
    end
    initial begin #50000000;$fatal(1,"FAIL: parameter mode watchdog");end
endmodule

