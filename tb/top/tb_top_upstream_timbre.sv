`timescale 1ns/1ps
// tb_top_upstream_timbre.sv -- ⭐⭐ 2026-10-16：⭐ **上行帧 `[7]` 的音色字段，端到端判据**
//
//   ⭐ **背景（⭐ 用户实测症状）**：⭐ *"ESP32 回传【依旧收不到音色】"* ✅
//
//   🔴 **为什么必须单独一条 tb**（⭐ 这是本文件存在的**唯一理由**）：
//      ⭐ `tb/w3c/tb_evt_upstream.sv` **直接驱动 `evt_timbre_i`**
//         ⇒ ⭐ 它只能证明"**模块内部**把音色装进了 `[7]`" ✅
//      🔴 **而它⛔ 证明不了 `top.v` 真的把【发声用的那个音色】接到了 `evt_timbre_i`**
//         —— ⚠️ 而**恰恰就是那一处坏的**（⭐ 见下）✅
//      ⇒ ⭐ 本 tb 跑**真 `top.v`**、⭐ 从**手弹事件注入**一路走到**上行字节** ⇒ ⭐ 端到端 ✅
//
//   ⭐ **判据（⭐ 每条都能失败 ✅）**：
//      ① ⭐ **非空洞前置**：⭐ 上行**未使能**时，⭐ 一个字节都不许发 ✅
//      ② ⭐ `'O'` 使能 ⇒ ⭐ 手弹一个事件 ⇒ ⭐ **恰好 14 B**、⭐ 帧头 / 轴号 / 校验都对 ✅
//      ③ 🔴 **本 tb 的锋芒**：⭐ 音色 = **2**（PIANO）· 轴 = 5
//         ⇒ ⭐ `[7]` 的 `[5:4]` **必须 = 2** ⇒ ⭐ 期望 `[7] = (2<<4)|5 = 8'h25` ✅
//         🔴 **旧代码在这里红**：⭐ `[7] = 8'h05`（⭐ 高 4 位恒为 0 ✅）
//      ④ ⭐ 换个音色（= **1**）＋ 换个轴（= 9）⇒ ⭐ `[7] = 8'h19`（⭐ 排除"碰巧"✅）
//      ⑤ 🔴 **连来两条、⭐ 中间把音色改掉** ⇒ ⭐ **每条帧带【自己】那个音色** ✅
//         ⇒ ⭐ 这一条钉的是"音色必须**随事件进 FIFO**"（⛔ 不是在组帧那一拍裸采 ✅）
//
//   ⭐ **怎么注入手弹事件**：⭐ `force` `top.v` 的 `g_sound.w3a_evt_*`（⭐ 那就是
//      `seq_arb.live_*` 的**真实来源** ✅）⇒ ⭐ 走的是**真接线**（⛔ 不绕过 `seq_arb`/`evt_merge`）✅
//      🔴 **关键**：⭐ 本 tb **⛔ 不去 force `live_timbre_*`** ——
//         ⚠️ 一旦 force 了，⭐ 就把"**手弹不带音色**"这个**真实现状**掩盖掉了 ✅
//         ⇒ ⭐ 那样判据会在**旧代码上也全绿**（⭐ 假绿）✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ ⭐ **本文件必须【无 BOM】**（⭐ 见 `tools/check_no_bom.ps1` ✅）

`timescale 1ns/1ps

module tb_top_upstream_timbre;

    reg clk = 1'b0, rst_n = 1'b0, rx = 1'b1;
    always #10 clk = ~clk;                      // ⭐ 50 MHz

    //  ── ⭐ 控制板（⭐ 本 tb 一律不按键 ⇒ ⛔ 不产生幻影命令 ✅）────────────
    wire [3:0] ctrl_row_w;
    wire sclk, mosi;
    wire [5:0] cs, miso;

    top dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(rx),
        .timbre_btn_i(1'b1), .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_cs_n(cs), .spi_miso(miso),
        .ctrl_row_o (ctrl_row_w),
        .ctrl_col_i (4'b1111),                  // ⭐ 无按键（⭐ 列上拉 ⇒ 全 1 ✅）
        .enc_a_i    (1'b1),
        .enc_b_i    (1'b1),
        .enc_sw_i   (1'b1)
    );

    //  ⭐ 三个 ADC 模型（⭐ 与 `tb_top_ctrl_wire` 同一套 ✅）
    mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3] = 3'b111;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ **上行字节抓取**（⭐ 就在 `top.v` 的模块级 `up_push_w`/`up_byte_w` 上 ✅）
    //     ⚠️ ⭐ `up_push_w` **已经与了 `ready_i`**（⭐ `evt_upstream.v` 的
    //        `assign push_o = (st_q == S_PUSH) && ready_i;`）⇒ ⭐ 条件只要它 ✅
    //     📌 ⭐ negedge 采样：⭐ 那时 `sr_q` 尚未移位 ⇒ ⭐ 抓到的正是**本拍要发的那个字节** ✅
    //        （⭐ 与 `tb_evt_upstream.sv` 同一手法 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    reg [7:0] rxq [0:255];
    integer   rxn = 0;
    always @(negedge clk) begin
        if (dut.up_push_w && (rxn < 256)) begin
            rxq[rxn] = dut.up_byte_w;
            rxn      = rxn + 1;
        end
    end

    //  ⭐ A4 @ fs = 48.828 kHz ⇒ phase_inc ≈ 38 702 840（⭐ > 2²¹ ⇒ 只有全宽 32 位装得下 ✅）
    localparam [31:0] A4_INC = 32'd38702840;

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

    //  ⭐ 真 UART 发一个字节（⭐ 434 拍/位 = 115200 ⇒ 与板载 `BAUD_DIV=434` 同档 ✅）
    //     📌 2026-10-28 板载口改档 500 kbps → 115200 ⇒ tb 同步适配
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

    //  ⭐⭐ **注入一条手弹事件** —— ⭐ force `top.v` 里 `seq_arb` 的**真实上游** ✅
    //     📌 只持续 **1 拍**（⭐ `evt_valid` 是单周期脉冲 ⇒ 一条事件 ✅）
    task force_event;
        input [3:0]  ax;
        input [31:0] inc;
        input [7:0]  vel;
        input [1:0]  kd;
        begin
            @(negedge clk);
            force dut.g_sound.w3a_evt_valid = 1'b1;
            force dut.g_sound.w3a_evt_axis  = ax;
            force dut.g_sound.w3a_evt_inc   = inc;
            force dut.g_sound.w3a_evt_vel   = vel;
            force dut.g_sound.w3a_evt_kind  = kd;
            @(posedge clk);
            @(negedge clk);
            release dut.g_sound.w3a_evt_valid;
            release dut.g_sound.w3a_evt_axis;
            release dut.g_sound.w3a_evt_inc;
            release dut.g_sound.w3a_evt_vel;
            release dut.g_sound.w3a_evt_kind;
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-16：⭐ **64 位曲谱帧的打包**（⭐ 与 `play_seq` / `mid2evt.py` 逐位一致 ✅）
    //     📌 位域（⭐ `rtl/top.v:5015-5025` 的权威表 ✅）：
    //        tick  : bit[63:44]  20 bit
    //        inc   : bit[43:23]  21 bit
    //        axis  : bit[22:19]   4 bit
    //        vel   : bit[18:11]   8 bit
    //        kind  : bit[10:9]    2 bit
    //        timbre: bit[8:7]     2 bit   ← ⭐ 对鼓 = `drum_type`（⭐ 复用 ✅）
    //        bit6  : 只亮灯不出声（⭐ `evt_guide_only`）
    //        bit5  : ⭐ **`is_drum`**
    //        bit[4:0]: `note_off5`（⭐ LED 灯位用，⭐ 与鼓无关）
    // ═══════════════════════════════════════════════════════════════════════
    function [63:0] score_frame;
        input [3:0]  ax;             // ⭐ 轴号（⭐ 鼓：一件一轴 12/13/14/15 ✅）
        input [1:0]  dt;             // ⭐ drum_type（0=Kick 1=Snare 2=HiHat 3=Tom ✅）
        begin
            score_frame = {20'd0, 21'd0, ax, 8'd200, 2'd0, dt, 1'b0, 1'b1, 5'd0};
        end
    endfunction

    //  ⭐⭐ **注入一条【曲谱】事件**（⭐ 与上面 `force_event` 同一手法 ✅）
    //     📌 `ps_note_valid` / `ps_note_data` 是 **`top` 模块级**的中间量
    //        （⭐ `play_seq.note_valid_o` / `note_data_o` 的**真实接线** ✅）
    //     ⭐ force 它们 ⇒ ⭐ `ps_is_drum` / `ps_drum_type` / `ps_evt_*`
    //        **全部自动变成真值**（⭐ 它们是 `ps_note_data` 的**组合切片** ✅）
    //        ⇒ ⭐ 于是走的是 `top.v` 的 `bit5` / `bit[8:7]` **解码**那一级 ✅
    //     ⚠️ `bit6` 必须写 **0** —— ⭐ 否则 `score_valid_i` 被
    //        `~evt_guide_only` 闸掉 ⇒ 🔴 事件根本不进 `seq_arb` ✅
    task force_score_event;
        input [3:0] ax;
        input [1:0] dt;
        begin
            @(negedge clk);
            force dut.ps_note_valid = 1'b1;
            force dut.ps_note_data  = score_frame(ax, dt);
            @(posedge clk);
            @(negedge clk);
            release dut.ps_note_valid;
            release dut.ps_note_data;
        end
    endtask

    //  ⭐ 等够 `n` 个字节（⭐ 带超时 ⇒ ⛔ 不静默挂死 ✅）
    //     ⚠️ ⭐ 一帧 14 B @ 115200 = **60760 拍**（⭐ 板载口 2026-10-28 改档后）
    //        ⇒ ⭐ 超时预算必须按帧算（⭐ 500 kbps 时代是 14000 拍 ✅）
    task wait_bytes;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while ((rxn < n) && (guard < 400000)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 400000) begin
                $display("FAIL: timeout waiting for %0d bytes (got %0d)", n, rxn);
                errors = errors + 1;
            end
        end
    endtask

    //  ⭐ 校验 = XOR 覆盖 **[0..12]（⭐ 含帧头 0xA5）**（⭐ 与 ESP32 侧 `frame_format.py` 同口径 ✅）
    function [7:0] ck_of;
        input integer base;
        integer i;
        begin
            ck_of = 8'd0;
            for (i = 0; i <= 12; i = i + 1) ck_of = ck_of ^ rxq[base + i];
        end
    endfunction

    //  ⭐ 只等若干拍（⭐ 让事件穿过 `seq_arb` → `evt_merge` → FIFO ✅）
    task idle;
        input integer n;
        begin
            repeat (n) @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_top_upstream_timbre/tb_top_upstream_timbre.vcd");
        $dumpvars(0, tb_top_upstream_timbre);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (600) @(negedge clk);

        // ══ 判据 ①：⭐ **非空洞前置** —— 上行未使能 ⇒ ⭐ 一个字节都不许发 ══
        begin : dis_blk
            force dut.timbre_sel_r = 2'd2;      // ⭐ PIANO
            idle(10);
            rxn = 0;
            force_event(4'd5, A4_INC, 8'd200, 2'd0);
            idle(4000);
            chk(rxn == 0,
                "baseline (non-vacuity): with the upstream DISABLED, ZERO bytes are emitted");
            chk(dut.up_enable_r === 1'b0, "and up_enable_r really is 0 at this point");
        end

        // ══ 使能上行（⭐ `'O'` = `CMD_UPSTREAM` = `0x4F` ✅）══
        begin : en_blk
            send_byte(8'h4F);
            idle(2000);
            chk(dut.up_enable_r === 1'b1, "'O' (0x4F) turns the real-time upstream ON");
        end

        // ══ 判据 ②③：⭐ 手弹 + 音色 = 2 ⇒ ⭐ `[7]` 的 `[5:4]` **必须是 2** ══
        //     🔴 **这就是用户报的那个 bug 的判据** ✅
        //  ⭐⭐ 2026-10-16（`CALIBRATE-R`）：⭐ **本块的期望值已随"鼓标记"改动重订** ✅
        //     ⚠️ **旧期望**：⭐ `[7] = (2<<4)|轴号` = `8'h25`（⭐ 低半字节 = 轴号 5）✅
        //     ✅ **新期望**：⭐ `[7] = (2<<4)|鼓标记` = `8'h20`（⭐ 低半字节 = **鼓标记** 0）✅
        //     📌 ⭐ **为什么**：⭐ `seq_arb` 拆出了 `evt_up_axis_o`（⭐ 只给上行帧）——
        //        ⭐ 鼓回传 `drum_type`、⭐ **其余一切来源回传 0** ✅
        //        ⚠️ 而本块激励是**手弹**（`SRC_LIVE`）⇒ ⭐ 低半字节必然是 0 ✅
        //     🔴 **同时钉住"轴号不再藏在 `[7]`"**：⭐ `[7][3:0] === 0`（⛔ 不是 5）✅
        begin : timbre2_blk
            force dut.timbre_sel_r = 2'd2;      // ⭐ PIANO
            idle(20);
            rxn = 0;
            force_event(4'd5, A4_INC, 8'd200, 2'd0);
            wait_bytes(14);
            idle(20);

            chk(rxn == 14, "one hand-play event => exactly 14 bytes");
            chk(rxq[0] === 8'hA5, "byte[0] is the 0xA5 header");
            chk(rxq[1] === 8'h01, "kind=0 (note_on) => type 0x01");
            //  ⭐⭐ 2026-10-16（`CALIBRATE-R` 重订口径）：⭐ **`[7]` 的低半字节 = 【鼓标记】，
            //     ⛔ 不再是轴号** ✅
            //  🔴 **为什么改**：⭐ 2026-10-16 为了给 ESP32 上行帧加"鼓"标记，
            //     `seq_arb` 拆出了**第二条输出** `evt_up_axis_o`（⭐ 只给上行帧）：
            //       · 鼓（`pop_src == SRC_KDRUM`）⇒ 回传 `drum_type`（0..3）
            //       · 其余一切来源 ⇒ 回传 **0**
            //     ⚠️ 而 `evt_axis_o`（⭐ 下行 voice 定位键）**原样透传轴号、⛔ 一个字都没动** ✅
            //     ⇒ ⭐ **本 tb 的激励是"手弹"（`SRC_LIVE`）⇒ 低半字节必然是 0** ✅
            //  📌 ⭐ 于是 `[7]` 的新口径（⭐⭐ 2026-10-17 起）：
            //       `bit[7] = 0`（留位）· `bit[6] = is_drum` · `bit[5:4] = 音色` · `bit[3:0] = 鼓标记` ✅
            //       ⚠️ 本条是**手弹**（⭐ `SRC_LIVE`）⇒ `is_drum = 0` ⇒ `bit[6]` 也是 0 ✅
            //          ⇒ ⭐ 下面那几条**精确到整字节**的断言（`0x20`/`0x10`/`0x30`）**值不变** ✅
            //  📌 ⭐ 轴号**没有丢**：⭐ 它在 `[8..11]` 的 `phase_inc` 里
            //     （⭐ ESP32 侧 `note_from_axis_inc` 用它反算音高 ⇒ ⭐ 这才是权威音高 ✅）
            //  ⭐ **鼓标记（非零）由 `tb_seq_arb` 覆盖**（⭐ `evt_up_axis_o` 的出处）✅
            chk(rxq[7][3:0] === 4'd0,
                "*** byte[7] low nibble is the DRUM MARKER, and a hand-play event is NOT a drum => it is 0 ***");
            chk({rxq[8], rxq[9], rxq[10], rxq[11]} === A4_INC,
                "byte[8..11] carry the FULL 32-bit phase_inc");
            chk(rxq[13] === ck_of(0),
                "byte[13] equals XOR of bytes [0..12] (INCLUDING the 0xA5 header)");
            /*  🔴🔴 **本 tb 的核心判据** —— ⭐ 这一条在旧代码上**必红** ✅
             *  ⭐ 旧代码：⭐ 手弹那一路的音色在 `top.v` 里是 `1'b0`/`2'd0`
             *     ⇒ ⭐ `mg_evt_timbre` **恒为 0** ⇒ ⭐ `[7]` 的 `[5:4]` 恒为 0
             *     ⇒ ⭐ `[7] = {4'b0, 鼓标记} = 8'h00`（⭐ 现在 `[7]` 已不再含轴号 ✅）
             *  ⭐ 修好后：⭐ 回传取"**发声实际用的音色**" = `timbre_sel_r` = 2
             *     ⇒ ⭐ `[7] = (2<<4)|0 = 8'h20` ✅ */
            chk(rxq[7] === 8'h20,
                "*** hand-play frame: byte[7] = 0x20 => timbre 2 in bits[5:4], drum marker 0 in bits[3:0] ***");
            chk(((rxq[7] >> 4) & 8'h03) === 2'd2,
                "*** the FRAME's timbre field == 2, i.e. the timbre that actually SOUNDED ***");
            chk(rxq[7] !== 8'h00,
                "non-vacuity: the timbre field is NOT the old hard-zero form (0x00)");
        end

        // ══ 判据 ④：⭐ 换个音色 + 换个轴 ⇒ ⭐ 字段跟着变（⭐ 排除"碰巧"✅）══
        begin : timbre1_blk
            force dut.timbre_sel_r = 2'd1;      // ⭐ GUITAR
            idle(20);
            rxn = 0;
            force_event(4'd9, A4_INC, 8'd100, 2'd0);
            wait_bytes(14);
            idle(20);
            chk(rxq[7] === 8'h10,
                "*** a DIFFERENT timbre (1) + a hand-play (drum marker 0) => byte[7] = 0x10 ***");
            chk(((rxq[7] >> 4) & 8'h03) === 2'd1,
                "*** and the frame's timbre field tracks it (now 1) ***");
        end

        // ══ 判据 ⑤：🔴 **连来两条、⭐ 中间把音色改掉** ⇒ ⭐ 各带各的音色 ══
        //     ⭐ 机理：⭐ 第 1 条事件**已经进 FIFO 并在发帧**（⭐ 一帧 14000 拍 ✅）
        //        ⇒ ⭐ 此时注入第 2 条（⭐ 音色 = 1），⭐ 然后**立刻再改音色 = 2** ✅
        //     🔴 **旧写法（⭐ 组帧那一拍裸采 `evt_timbre_i`）**：
        //        ⚠️ 第 2 帧要等第 1 帧发完才组帧 ⇒ ⭐ 那时裸采到的是 **2** ⇒ 🔴 **红** ✅
        //     ✅ **新写法（⭐ 写侧锁存进 FIFO）**：⭐ 第 2 帧锁的是**它自己**的 1 ✅
        begin : burst_blk
            force dut.timbre_sel_r = 2'd3;      // ⭐ PAD
            idle(20);
            rxn = 0;
            force_event(4'd1, A4_INC, 8'd200, 2'd0);   // ⭐ 第 1 条：音色 3
            idle(300);                                  // ⭐ 让它进 FIFO 并开始发帧
            force dut.timbre_sel_r = 2'd1;              // ⭐ 改音色
            idle(20);
            force_event(4'd2, A4_INC, 8'd200, 2'd0);   // ⭐ 第 2 条：音色 1
            idle(20);
            force dut.timbre_sel_r = 2'd2;              // 🔴 再改（⭐ 旧写法会误采到它 ✅）
            wait_bytes(28);
            idle(20);

            chk(rxn == 28, "two back-to-back events => exactly 2 frames (28 bytes)");
            chk(rxq[7] === 8'h30,
                "*** burst frame #1 keeps ITS OWN timbre: [7] = 0x30 (timbre 3, drum marker 0) ***");
            chk(rxq[21] === 8'h10,
                "*** burst frame #2 carries ITS OWN timbre: [7] = 0x10 (timbre 1, drum marker 0) ***");
            chk(rxq[21] !== 8'h20,
                "*** and it did NOT pick up the later timbre 2 (the timbre travels WITH the event) ***");
            chk(rxq[13] === ck_of(0),  "frame #1 checksum holds with the new byte[7]");
            chk(rxq[27] === ck_of(14), "frame #2 checksum holds with the new byte[7]");
        end

        release dut.timbre_sel_r;

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐⭐ 2026-10-16（⭐ 校尺队 · 缺口 2）：⭐ **上行鼓标记的【端到端】判据**
        //
        //  🔴 **现状（⭐ 本块补的洞）**：⭐ `seq_arb.evt_up_axis_o`（⭐ 鼓回传
        //     `drum_type`、⭐ 其余回传 0）只有【模块级】判据（`tb_seq_arb`），
        //     🔴 **没有【顶层端到端】判据** —— ⭐ 即"灌真帧 → 上行 14B 帧 →
        //     检查 `byte[7]` 的低半字节"这一整条**接线**从没被验过 ✅
        //
        //  ⭐ **口径（⭐ 与 `seq_arb.v:412-419` 逐字一致 ✅）**：
        //     ```verilog
        //     evt_up_axis_o <= (pop_src == SRC_KDRUM)
        //                     ? {2'b0, pop_data[0 +: TIMBRE_W]}   // ⭐ 鼓 ⇒ drum_type
        //                     : {AXIS_W{1'b0}};                    // ⭐ 其余 ⇒ 0
        //     ```
        //     ⭐ 而 `evt_upstream.v:264` 组帧：`b_axis = {2'b0, tm, ax}`
        //     ⇒ ⭐ `byte[7]` 的低半字节 = `evt_up_axis_o[3:0]`
        //        = **鼓 ⇒ `drum_type`** · **手弹/其余 ⇒ 0** ✅
        //
        //  ⭐ **可判性（⭐ 校尺队点出的关键限制，⭐ 必须诚实写明）**：
        //     ⚠️ 鼓的 `drum_type` 与手弹在低半字节上**都是 0**（⭐ Kick 也是 0 ✅）
        //     ⇒ ⭐ **`drum_type = 0` 的那一条"⛔ 不可判"**（⭐ 与手弹完全同值 ✅）
        //     ✅ **可判的是 `drum_type` 非零**：⭐ 1 / 2 / 3 **必须**分别回传
        //        1 / 2 / 3 ⇒ ⭐ 若 `seq_arb` 的"鼓回传 drum_type"整段掉了
        //        （⭐ 比如又退回了"回传 0"）⇒ 🔴 **这三条立刻红** ✅
        //     📌 ⭐ **非空洞性（⭐ 校尺队特别点名的一条 ✅）**：⭐
        //        `drum_type = 2`（HiHat）⇒ ⭐ 低半字节**必须是 2、⛔ 不许是 0** ——
        //        ⭐ 即"**鼓回传 drum_type**"这件事被**单独钉死** ✅
        //        （⭐ 若只测 `drum_type=0` ⇒ 🔴 与手弹同值 ⇒ 判据**恒真** ✅）
        //
        //  ⭐ **怎么注入（⭐ 本块的做法 ✅）**：⭐ `force` `top.v` 的
        //     **模块级中间量** `ps_note_valid` / `ps_note_data`
        //     （⭐ = `play_seq.note_valid_o` / `note_data_o` 的**真实接线** ✅）
        //     ⇒ ⭐ `ps_is_drum = ps_note_data[5]` ·
        //        `ps_drum_type = ps_note_data[8:7]`
        //        （⭐ `rtl/top.v:1675-1676` ✅）**全部自动变成真值**
        //     ⇒ ⭐ 走的是 `top.v` 的 **`bit5` / `bit[8:7]` 解码**那一级 ✅
        //     🔴 **为什么⛔ 不能直接 force `score_is_drum_i`**：⭐ 那样就把
        //        **`top.v` 的解码本身**旁路掉了 ⇒ 🔴 `bit5`/`bit[8:7]` 接错也照绿 ✅
        //     ⚠️ `bit6`（`evt_guide_only`）必须写 **0** —— ⭐ 否则
        //        `score_valid_i = ... & ~evt_guide_only` 把它**闸掉** ⇒
        //        🔴 事件根本不进 `seq_arb`（⭐ 本块会红，⭐ 但那测的是 bit6 ✅）
        //     ⚠️ **同时 force `timbre_sel_r = 0`**（⭐ 手弹对照用 ✅）
        //
        //  ⭐ **每条注入后等一帧（⭐ 14 B @ 500 kbps = 14000 拍 ✅）**
        //
        //  ⭐ **能红实证（⭐ 回退验证时实测 ✅）**：⭐ 把 `seq_arb.v:417-419` 改成
        //     ```verilog
        //     evt_up_axis_o <= {AXIS_W{1'b0}};      // ⭐ 全回传 0（⭐ 即"鼓标记整段掉了"）
        //     ```
        //     ⇒ ⭐ `dt=1/2/3` 的**三条判据全部必红**（⭐ 低半字节变成 0 ✅）
        //     📌 ⭐ **注意这不是假造**：⭐ 那正是 `seq_arb.v:134-151` 端口注释里
        //        记录的 **P0-1 修前**那一版（⭐ 当时 `evt_axis_o` 同时被改成鼓标记 ✅）
        // ═══════════════════════════════════════════════════════════════════
        begin : drum_upstream_blk
            integer dti;
            reg [3:0] exp_dt [0:3];
            // ⭐ 四件的轴号（⭐ 一件一轴：⭐ Kick 12 · Snare 13 · HiHat 14 · Tom 15 ✅）
            //    📌 ⭐ 轴号在这里**不参与鼓标记判定**（⭐ 那是 `drum_type` 的事 ✅）
            //       ⇒ ⭐ 但**真实链路里一件一轴** ⇒ ⭐ 照真实口径写 ✅
            reg [3:0] dt_axis [0:3];
            reg [7:0] got_byte7;
            dt_axis[0] = 4'd12; dt_axis[1] = 4'd13;
            dt_axis[2] = 4'd14; dt_axis[3] = 4'd15;
            exp_dt[0]  = 4'd0;  exp_dt[1]  = 4'd1;
            exp_dt[2]  = 4'd2;  exp_dt[3]  = 4'd3;
            force dut.timbre_sel_r = 2'd0;       // ⭐ BASS（⭐ 让 `[7]` = `8'h0?` ✅）
            idle(20);

            for (dti = 0; dti <= 3; dti = dti + 1) begin
                rxn = 0;
                force_score_event(dt_axis[dti], dti[1:0]);   // ⭐ `drum_type = dti` ✅
                wait_bytes(14);
                idle(20);
                got_byte7 = rxq[7];
                chk(rxn == 14, "drum: exactly one 14-byte frame came out");
                chk(rxq[0] === 8'hA5, "drum: byte[0] is the 0xA5 header");
                chk(rxq[1] === 8'h01, "drum: kind=0 (note_on) => type 0x01");
                //  ⭐ 低半字节 = 鼓标记（⭐ `evt_up_axis_o[3:0]` ✅）
                //     ⚠️ ⭐ **`dti == 0`（Kick）这一条与手弹同值** ⇒
                //        ⭐ 单独看**不可判**（⭐ 校尺队已点名 ✅）——
                //        ⭐ 但**它仍然必须写**（⭐ 它是"上行链在鼓上也真的通"的
                //           **回归保险**：⭐ 万一鼓的 `is_drum` 整段掉了、⭐
                //           事件被判成乐音 ⇒ 🔴 它会因为别的判据先红 ✅）
                //     ✅ **真正能单独钉死"鼓回传 drum_type"的是 `dti = 1/2/3`**
                if (exp_dt[dti] == 4'd0)
                    chk(got_byte7[3:0] === 4'd0,
                        "drum_type=0 (Kick) => byte[7] low nibble = 0 (NOT independently decidable vs hand-play, but must still hold)");
                else
                    chk(got_byte7[3:0] === exp_dt[dti][3:0],
                        "*** drum_type non-zero: byte[7] low nibble MUST equal drum_type (this is the decidable one) ***");
                //  ⭐⭐ **非空洞性（⭐ 校尺队特别点名 ✅）**：⭐
                //     `dti = 2`（HiHat）⇒ ⭐ 低半字节**必须是 2、⛔ 不许是 0** ——
                //     ⭐ 若 `seq_arb` 的"鼓回传 drum_type"整段掉了（⭐ 退回全 0 ✅）
                //     ⇒ 🔴 **这一条立刻红**（⭐ 而 `dti=0` 那条不会红 ✅）
                if (dti == 2)
                    chk(got_byte7[3:0] !== 4'd0,
                        "non-vacuity (HiHat, drum_type=2): byte[7] low nibble is 2, NOT 0 -- the drum_type DOES travel upstream");
                //  ⭐⭐ 2026-10-17（🔴 协议变更）：⭐ 高 2 位**不再都是保留位** ✅
                //     ⭐ 新布局（⭐ `evt_upstream.v` 的 `b_axis`）：
                //        `byte[7] = {1'b0, is_drum, timbre[1:0], axis[3:0]}`
                //     · `bit[7]`   = ⭐ **仍然是保留位，必须恒 0** ✅
                //     · `bit[6]`   = ⭐ **`is_drum`**（⭐ 1 = 这条是鼓 ✅）
                //     ⇒ 🔴 旧断言 `[7:6] === 2'b00` 在**鼓事件**上**必然红** ——
                //        ⚠️ 不是回归，是**契约变了**（⭐ 本次改动就是为 ESP32 加这一位）
                //     📌 本段是**鼓**事件 ⇒ ⭐ `bit[6]` **必须为 1**（⭐ 这就是新判据本身）✅
                chk(got_byte7[7] === 1'b0,
                    "drum: byte[7] bit[7] is still the reserved bit and must stay 0");
                chk(got_byte7[6] === 1'b1,
                    "*** drum: byte[7] bit[6] = is_drum MUST be 1 (new protocol bit for ESP32) ***");
                //  ⚠️⚠️ **诚实的边界（⭐ 校尺队口径 ✅）**：⭐ `bit[5:4]`（音色字段）
                //     **本条【⛔ 不断言】** —— ⭐ 因为 `bit[8:7]` 被**复用**成 `drum_type`
                //     （⭐ `rtl/top.v:1651-1655` 记录的既定设计 ✅）⇒ ⭐
                //     `ps_evt_timbre = drum_type` ⇒ ⭐ 曲谱鼓的**音色字段**也 = `drum_type`
                //     ⇒ ⭐ 于是 `byte[7]` 会是 `{2'b00, drum_type, drum_type}`（⭐ 如 HiHat = 0x22 ✅）
                //     📌 ⭐ **这不是 bug**（⭐ 是"鼓的音色由哪件鼓决定 ⇒ timbre 无意义"的既定取舍 ✅）；
                //        ⭐ 也**不是本缺口要判的东西** —— ⭐ **低半字节（`evt_up_axis_o`）才是鼓标记 ✅**
                //     ⚠️ 若把它写成"必须是 0"⇒ 🔴 会把**正确行为**判成失败（⭐ 那正是本项目
                //        最怕的"判据说谎"✅）⇒ ⭐ 所以**只验保留位**，⛔ 不碰音色段 ✅
            end
            release dut.timbre_sel_r;
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐ **对照（⭐ 手弹 `is_drum = 0`）⇒ 低半字节必须是 0**
        //     ⚠️ ⭐ **诚实的边界（⭐ 校尺队已点名 ✅）**：⭐
        //        鼓的 `drum_type=0`（Kick）**与手弹在低半字节上都是 0**
        //        ⇒ ⭐ **本条"⛔ 不能区分鼓 vs 手弹"** ✅
        //     ✅ **但它仍然有价值**：⭐
        //        ① ⭐ 它证明"**手弹不被误标成鼓**"（⭐ 即 `evt_up_axis_o`
        //           的 `else` 分支对 `SRC_LIVE` 真的回传 0 ✅）——
        //           ⭐ 若手弹也回传非零 ⇒ 🔴 **ESP32 会把每个手弹都当成鼓** ✅
        //        ② ⭐ 它与上面鼓的 `dt=1/2/3` **合起来**才能"区分"：
        //           ⭐ 非零 = 鼓且知道是哪一件 · ⭐ 0 = 手弹**或** Kick ✅
        //        📌 ⭐ **这就是"真正可判的"边界** —— ⭐ 校尺队要的就是这个诚实度 ✅
        // ═══════════════════════════════════════════════════════════════════
        begin : handplay_vs_drum_blk
            force dut.timbre_sel_r = 2'd0;       // ⭐ BASS（⭐ 与鼓块同口径 ✅）
            idle(20);
            rxn = 0;
            force_event(4'd5, A4_INC, 8'd200, 2'd0);   // ⭐ 手弹（`SRC_LIVE` ✅）
            wait_bytes(14);
            idle(20);
            chk(rxn == 14, "hand-play: exactly one 14-byte frame came out");
            chk(rxq[7][3:0] === 4'd0,
                "hand-play (is_drum=0) => byte[7] low nibble is 0 -- a hand-play is NEVER marked as a drum upstream");
            release dut.timbre_sel_r;
        end

        // ══════════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ⑥：**键盘打鼓** ⇒ `byte[7][3:0]` 必须是 `drum_type`（⛔ 不再是 0）
        //
        //  🔴 **本条钉的就是那个缺陷**（⭐ ESP32 侧 2026-10-16 回函 §二 确认）：
        //     原实现把 `[3:0]` 接 `seq_arb.evt_up_axis_o`，而它只在
        //     `pop_src == SRC_KDRUM` 时给值 —— ⭐ **键盘打鼓走 `live_*`**
        //     ⇒ `pop_src = SRC_LIVE` ⇒ 🔴 **`[3:0] = 0`** ⇒ 被 ESP32 解成"旋律" ✅
        //     📌 修法见 `rtl/top.v` 的 `up_drum_mark_w`（⭐ 三路鼓按 `12 + drum_type` 统一反推）
        //
        //  ⭐ **激励与推演**：`key_drum_r = 1` + 物理轴 **8**
        //     · `key_drum_sel  = sa_axis[3:2] = 8[3:2] = 2'd2`
        //     · `key_drum_dtype = (sel == 2'd2) ? 2'd1` ⇒ **1 = Snare**
        //     · `key_drum_axis = 12 + 1 = 13` ⇒ `mg_evt_axis[1:0] = 1`
        //     · `src_a_timbre  = key_drum_dtype = 1`（⭐ `valid=1`）
        //     ⭐⭐ 2026-10-17（🔴 协议变更）：⭐ `src_a_src = key_drum_r ? 3'd5 : ...`
        //        ⇒ ⭐ `up_is_drum_w = 1` ⇒ **`byte[7]` 的 `bit[6]` 现在也是 1** ✅
        //     ⇒ ⭐ **`byte[7] = {1'b0, 1'b1, 2'd1, 4'd1} = 8'h51`**
        //        （⭐ = 旧的 `0x11` **＋ `0x40`**，⭐ 只多了 `is_drum` 那一位 ✅）
        //        （⭐ `bit[5:4]`/`bit[3:0]` 与 ESP32 回函 §六 点名的"键盘打鼓 Snare"逐位不变 ✅）
        //
        //  ⚠️ **本条在"修复 `[3:0]` 之前"必红**（⭐ 旧实现给 `0x10`：`[5:4]=1` 对、`[3:0]=0` 错）✅
        //     ⭐ 而在"加 `is_drum` 之前"也必红（⭐ 那时是 `0x11`，⭐ 差的正是 `bit[6]`）✅
        //
        //  🔴🔴 **⛔ 本块必须放在【最后一个】**（⭐ 2026-10-16 实测踩到）：
        //     ⚠️ 上行帧**一帧要 ~14000 拍**（⭐ 20.48 µs 音频帧）⇒
        //        `wait_bytes(14)` 读完**仍有帧在飞** ⇒ 🔴 它的**键盘鼓标记会落到
        //        下一个用例的读取里** ⇒ ⭐ 实测把后面 5 条判据（⭐ 判据⑤ 与 灌谱鼓那几条）
        //        **全部染红**（⭐ 症状极具迷惑性：红的全是"鼓标记必须是 0"那几条 ✅）
        //     ✅ 放在末尾 ⇒ 没有"下一个用例"可污染 ✅
        //     📌 同族 `C34`（换执行方式改变隐含前提）· `L108`（聚焦 tb 只覆盖关心的调用链）
        // ══════════════════════════════════════════════════════════════════════
        begin : kdrum_blk
            force dut.key_drum_r   = 1'b1;
            force dut.timbre_sel_r = 2'd2;      // ⭐ 故意设成 PIANO：⛔ 不该影响鼓音色
            idle(20);
            rxn = 0;
            force_event(4'd8, A4_INC, 8'd200, 2'd0);
            wait_bytes(14);
            idle(20);

            chk(rxn == 14, "a keyboard-drum event still emits exactly 14 bytes");
            chk(rxq[7][3:0] === 4'd1,
                "*** KEYBOARD DRUM: byte[7][3:0] must be the drum_type (1 = Snare), NOT 0 ***");
            chk(((rxq[7] >> 4) & 8'h03) === 2'd1,
                "*** KEYBOARD DRUM: bits[5:4] must also be the drum_type (1 = Snare) ***");
            chk(rxq[7] === 8'h51,
                "*** KEYBOARD DRUM Snare => byte[7] = 0x51 = {1'b0, is_drum=1, timbre=1, axis=1} ***");
            chk(rxq[7][6] === 1'b1,
                "*** and the new is_drum bit[6] is 1 for a keyboard drum ***");
            //  ⭐ **非空洞**：若 `[3:0]` 退回旧行为（恒 0）⇒ 上面第一条必红
            chk(rxq[7] !== 8'h10,
                "non-vacuity: 0x10 is the OLD (broken) value where the drum marker was 0");
            chk(rxq[7] !== 8'h11,
                "non-vacuity: 0x11 is the value BEFORE is_drum was added -- bit[6] must differ");

            release dut.key_drum_r;
            release dut.timbre_sel_r;
        end

        $display("");
        if (errors == 0)
            $display("PASS: top-level upstream timbre -- a hand-play event's frame carries the timbre that actually SOUNDED in bits[5:4] (bits[3:0] is now the DRUM MARKER, which is 0 for hand-play), and the timbre travels with its own event through the FIFO");
        else
            $fatal(1, "FAIL: tb_top_upstream_timbre had %0d error(s)", errors);

        #100;
        $finish;
    end

    initial begin
        #100000000;                                  // ⭐ 100 ms 上限（⭐ 8 帧 ≈ 486000 拍 @115200 ✅）
        $display("FAIL: tb_top_upstream_timbre timed out");
        $fatal(1, "timeout");
    end

endmodule
