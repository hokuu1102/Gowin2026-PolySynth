// ─────────────────────────────────────────────────────────────────────────────
// tb_top_guide_bit6.sv · ⭐ **逐事件"只亮灯不出声"（保留位 `bit6`）的【顶层】判据**
//                      （2026-10-15 新建）
//
// ⭐ **需求**（⭐ 用户 2026-10-15 拍板）：
//    ⭐ `files/20-代码/ESP32侧需求-引导模式改成上位机逐事件控制-20261015.md`
//    ⇒ ⭐ 把"**哪些音符只亮灯不出声**"从【FPGA 全局开关 `'U'`】
//       改成【**上位机逐事件用保留位 `bit6` 指定**】✅
//
// ⭐ **为什么必须是【顶层】tb**（⭐ ⛔ 不能只测 `play_seq`）：
//    ⭐ 本功能的**全部价值**在**两个消费者的分工**上 ——
//       · ⭐ `u_guide_lamp.note_valid_i`（⭐ LED ⇒ **要亮** ✅）
//       · ⭐ `u_seq_arb.score_valid_i`（⭐ 出声 ⇒ **要静音** ✅）
//    🔴 而这两条**都在 `top.v` 的接线里**（⭐ 模块各自的单测**看不见接线** ✅）
//    ⇒ ⭐ 与 `tb_top_score_path.sv` **同一理由**（⭐ 它也是顶层 tb ✅）
//    📌 ⭐ **做法**：⭐ 在**真 `top.v`** 上、⭐ 用**真串口帧**灌谱
//       （⭐ `0xA5` ＋ 8 字节大端 ⇒ ⭐ `evt_uart_rx ⇒ u_evt_buf ⇒ u_play_seq` ✅）
//
// ⭐ **判据清单（⭐ 四条，⭐ 与任务书逐条对应）**：
//    · ⭐ **① `bit6=1` ⇒ LED 指引亮 ＋ 不出声**（⭐ `score_valid_i` 从未拉高、
//      ⭐ `seq_arb` 的 `score_cnt_o` **不涨** ⇒ ⭐ **不占 voice** ✅）
//    · ⭐ **② `bit6=0` ⇒ 照常出声**（⭐ 证明没把**整条流**门掉 ✅）
//    · ⭐ **③ 混流**：⭐ 同一帧流里 `bit6=1` / `bit6=0` 交替
//      ⇒ ⭐ **只有 `bit6=1` 的不出声**（⭐ 计数逐条对上 ✅）
//    · ⭐⭐ **④ 没被标记的 `note_off` 也必须能熄灯**（⭐ 2026-10-16 · 点灯 LIGHTER 新增）
//      —— ⭐ 闸门**必须【不对称】**：⭐ `note_on` 门控 · ⭐ `note_off` 一律放行
//      ⇒ 🔴 **否则被标记的那盏灯【永远灭不掉】**（⭐ 用户报的"只闪一盏、不换灯"）✅
//      📌 ⭐ 回退 `top.v` 的 `| ps_is_note_off` ⇒ 🔴 **4d 必红** ✅
//
// ⭐ **非空洞性（⭐ `C83` 探针假绿纪律）**：
//    ⭐ ①②③ 都**直接看"有没有进 `seq_arb`"**（⭐ `score_hits` 计数器 ＋
//       ⭐ `sa_score_cnt` 顶层挂钩 ⇒ ⭐ **单调计数器，⛔ 不会侥幸通过** ✅）
//    ⭐ ④ 直接看 `guide_key_o[4]`（⭐ 闸门两侧的**同一个位**，⭐ 一进一出 ✅）
//    📌 ⭐ 回退 `top.v` 的那一行（⭐ 去掉 `& ~evt_guide_only`）
//       ⇒ ⭐ `bit6=1` 的事件**照样进 `seq_arb`** ⇒ 🔴 **①②③ 全部必红** ✅
//
// ⚠️ 串口激励：⭐ 与 `tb_top_score_path` **同档**（⭐ 500 kbaud @ 50 MHz ⇒ `BIT_CYC=100`）✅
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_top_guide_bit6;

    localparam integer BIT_CYC = 100;      // ⭐ top 的串口：500 kbaud @ 50 MHz ✅

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg uart_rx       = 1'b1;    // ⭐ ESP32 那一路（`G22`）—— ⭐ **曲谱** ✅
    reg uart_rx_board = 1'b1;    // ⭐ 板载那一路（`D14`）—— ⭐ 串口屏/命令（⭐ 本 tb 不用）✅
    always #10 clk = ~clk;

    wire esp_tx_o;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_heartbeat;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;

    top #(
        .PA_ON_AFTER_RESET     (0),
        .DEMO_CHORD_ON         (1),            // ⭐ 要真声音链（⭐ 与 `tb_top_score_path` 同档 ✅）
        .DEMO_NOTE_DELAY       (1_000_000),    // ⭐ 演示和弦别来捣乱
        .DEMO_HOLD_CYC         (1_000_000),
        .AUTOTARE_DELAY_CLK    (100),
        .SPAN_WAIT_TIMEOUT_CLK (1_000),
        .HEARTBEAT_DIV         (100)
    ) dut (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN_n(PA_EN_n),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .led_heartbeat(led_heartbeat),
        .spi_miso(6'b111111), .spi_sclk(), .spi_mosi(), .spi_cs_n(),
        .led_sdi(), .led_clk(), .led_le(), .led_oe_n(),
        //  ⭐ 曲谱走【ESP32 独立 UART】（⭐ `G21`/`G22`）✅
        .uart_rx(uart_rx_board), .uart_tx(),
        .esp_uart_rx_i(uart_rx), .esp_uart_tx_o(esp_tx_o)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    //  ⭐⭐ **"别再等了"旗**（⭐ ⚠️ 这是为了"**红得快且指向明确**"✅）：
    //     ⭐ 判据 ①② 跑完之后若**已经红过**，⭐ 判据 ③ 的混流**没必要再等**
    //     （⭐ 状态已经不可信，⚠️ 而且三段自旋会把看门狗跑满）✅
    //     📌 ⭐ 动机：⭐ **M3 变异实测** ——
    //        ⚠️ 不早停 ⇒ 自旋跑满看门狗 ⇒ 🔴 报 `TIMEOUT`（⭐ **看不出是哪条判据坏** ✅）
    //     ⚠️ **注意**：⭐ 它**只跳过判据 ③ 的等待**，⛔ **不跳过任何判据本身** ——
    //        ⭐ ①② 的每一条**照样各跑各的** ⇒ ⭐ **红原文里三条判据都能看见** ✅
    reg skip_rest = 1'b0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 事件打包（⭐ 与 `mid2evt.py` / `play_seq` 位域逐位一致 ✅）
    //     ⭐⭐ 2026-10-15：⭐ **多一个 `bit6`（⭐ 逐事件"只亮灯不出声"）** ✅
    //        `{tick(20), inc(21), axis(4), vel(8), kind(2), timbre(2), bit6, bit5, off5(5)}`
    //     📌 ⭐ 依据：⭐ `rtl/w3c/seq_arb.v:200-201` 写着 `bits 6..0 reserved` **一直是 0**
    //        ⇒ ⭐ 用 `bit6` **不算改协议** ✅
    //     ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **`bit[4:0]` = `note_off5` = `MIDI − 45`** ✅
    //        ⇒ ⭐ **灯位由【音高】决定**（⛔ 不再由 `axis` 决定）——
    //           ⭐ 详见 `rtl/w3c/guide_lamp.v` 头部 §音高语义 ✅
    //        📌 ⭐ 因此下面每条事件的**期望灯位**都按 `note_off5` 算：
    //           ⭐ 键盘表（⭐ 顶层默认钢琴 · `MODE_PIANO_DEFAULT=1`）——
    //           · ⭐ C3  (off  3) ⇒ **键 5**   · ⭐ C#3 (off  4) ⇒ **键 6**
    //           · ⭐ G#3 (off 11) ⇒ **键 14**  · ⭐ B3  (off 14) ⇒ **键 8**
    //           · ⭐ C#4 (off 16) ⇒ **键 9**   · ⭐ D3  (off  5) ⇒ **键 4**
    // ═══════════════════════════════════════════════════════════════════════
    function [63:0] pack;
        input [19:0] tk;
        input [20:0] inc;
        input [3:0]  ax;
        input [7:0]  vel;
        input [1:0]  knd;
        input [4:0]  p5;          // ⭐ `note_off5` = MIDI − 45（⭐ 灯位依据）
        input        gonly;
        begin
            pack = {tk, inc, ax, vel, knd, 2'b00, gonly, 1'b0, p5};
        end
    endfunction

    task pc_send_bit;
        input v;
        input sel;
        begin
            if (sel) uart_rx_board = v; else uart_rx = v;
        end
    endtask

    task pc_send_byte;
        input [7:0] b;
        input       sel;
        integer bit_i;
        begin
            repeat (4) @(posedge clk);
            pc_send_bit(1'b0, sel);               // ⭐ start
            repeat (BIT_CYC) @(posedge clk);
            for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
                pc_send_bit(b[bit_i], sel);       // ⭐ LSB first
                repeat (BIT_CYC) @(posedge clk);
            end
            pc_send_bit(1'b1, sel);               // ⭐ stop
            repeat (BIT_CYC + 40) @(posedge clk);
        end
    endtask

    //  ⭐ 一帧 = `0xA5` ＋ 8 字节【大端】事件 ✅
    task send_frame;
        input [63:0] ev;
        input        sel;
        integer k;
        begin
            pc_send_byte(8'hA5, sel);
            for (k = 7; k >= 0; k = k - 1)
                pc_send_byte(ev[k*8 +: 8], sel);
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ **核心探针**：⭐ "这条音符到底进没进 `seq_arb`" ✅
    //
    //  🔴 **为什么用这个探针**（⭐ 而不是只看 `guide_lamp`）：
    //     ⭐ 本功能的**收益**是"**进不了 `seq_arb` 的音符【不占 voice】**"
    //     （⭐ 用户确认 ✅）⇒ ⭐ 所以判据必须**直接落在 `seq_arb` 的入口上** ✅
    //     ⭐ `score_valid_i` 是**组合**的（⭐ 就是 `top.v` 那条闸表达式）
    //        ⇒ ⭐ 每个时钟沿采样它 ⇒ ⭐ **高过几拍就是几拍**（⭐ 不可能侥幸 ✅）
    //     📌 ⭐ `ps_note_valid` 是**单周期脉冲** ⇒ ⭐ 正常音符 `score_hits` 恰好 **+1** ✅
    // ═══════════════════════════════════════════════════════════════════════
    integer note_pulses = 0;      // ⭐ `play_seq` 吐了几条音符事件
    integer score_hits  = 0;      // ⭐ 其中**真的进了 `seq_arb`** 的条数（⭐ 会占 voice 的）
    integer guided_note = 0;      // ⭐ 其中 `bit6=1`（⭐ 只亮灯）的条数

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.ps_note_valid) begin
                note_pulses = note_pulses + 1;
                if (dut.evt_guide_only) guided_note = guided_note + 1;
            end
            //  ⭐ 本拍 `seq_arb` 的入口被拉高 ⇒ ⭐ 这一条**会进 FIFO / 会占 voice** ✅
            if (dut.g_sound.u_seq_arb.score_valid_i) score_hits = score_hits + 1;
        end
    end

    integer i, spin, wait_i;

    //  ⭐ 有界自旋：等 `evt_cnt_o` 到 `want`（⛔ 不写死拍数 —— ⭐ 免得踩"差一"的坑 ✅）
    task wait_evt;
        input [15:0] want;
        input integer limit;
        begin
            spin = 0;
            while ((dut.g_sound.u_play_seq.evt_cnt_o !== want) && (spin < limit) && !skip_rest) begin
                @(posedge clk);
                spin = spin + 1;
            end
        end
    endtask

    //  ⭐ 有界自旋：等 `score_hits` 到 `want`
    task wait_score_hits;
        input integer want;
        input integer limit;
        begin
            spin = 0;
            while ((score_hits !== want) && (spin < limit) && !skip_rest) begin
                @(posedge clk);
                spin = spin + 1;
            end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ tick 预算：⭐ 120 BPM ⇒ 1 tick = 26041 拍（⭐ 与 `tb_top_score_path` 同口径 ✅）
    //     ⚠️ 本 tb **只用很小的 tick**（⭐ 0/1/2/500）⇒ ⭐ 总仿真时间很短 ✅
    // ═══════════════════════════════════════════════════════════════════════
    initial begin
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        $display("=== tb_top_guide_bit6 (逐事件 bit6 = 只亮灯不出声) ===");
        $display("   play_seq 复位默认 tick_inc = %0d（⭐ 120 BPM = 164927）",
                 dut.g_sound.u_play_seq.tick_inc_o);
        chk(dut.g_sound.u_play_seq.tick_inc_o === 32'd164927,
            "0a tick_inc default is 120 BPM (beat_gen tempo comes from play_seq)");
        //  ⭐ 前置：⭐ 本 tb **不开** `'U'`（⭐ `guide_only_r` 复位 = 0 ✅）
        chk(dut.guide_only_r === 1'b0,
            "0b global 'U' guide mode is OFF -- we are testing the PER-EVENT path");
        chk(dut.evt_guide_only === 1'b0, "0c bit6 decode is 0 at reset");

        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ①：⭐ `bit6=1` ⇒ **LED 亮 ＋ 不出声**（⭐ 不进 `seq_arb`）✅
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ 用 `tick = 960`（⭐ = 1 拍）＋ ⭐ `bit6 = 1`
        //     ⇒ ⭐ 逐事件提前量（960）刚好把它拉进"到期" ⇒ ⭐ **立刻发出**（⭐ 不用等）✅
        //     📌 ⭐ 这同时**顺带验了"逐事件提前一拍"**（⭐ 用户裁定 A ✅）：
        //        ⚠️ 若 `lead_sel_i` 没接 / 没生效 ⇒ 🔴 本事件要等 **960 × 26041 拍**
        //        ⇒ ⭐ 自旋会**跑满上限** ⇒ ⭐ 判据 `1b` **必红**（⭐ 时间上不可能侥幸 ✅）
        $display("== 1  bit6=1  =>  LED 亮 + 不出声（不进 seq_arb）==");
        //  ⭐⭐ 2026-10-16：⭐ 音高 = **C3**（⭐ `note_off5 = 3`）⇒ ⭐ 键盘表 ⇒ **键 5** ✅
        send_frame(pack(20'd960, 21'd37791, 4'd5, 8'd200, 2'd0, 5'd3, 1'b1), 1'b0);
        wait_evt(16'd1, 150_000);
        repeat (2) @(posedge clk);          // ⭐ 等 `guide_lamp` 锁存（⭐ 与既有 tb 同口径 ✅）
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd1,
            "1a the bit6=1 event fired (the per-event 1-beat lead actually reached play_seq)");
        chk(note_pulses === 1,
            "1b exactly one note event was emitted by play_seq (the LED half sees it)");
        chk(guided_note === 1,
            "1c the emitted event really carries bit6=1 (fields survived the whole chain)");
        chk(dut.u_guide_lamp.guide_key_o[5] === 1'b1,
            "1d guide_lamp LIT key 5 (C3)  <-- the LED guide half is ALIVE for bit6=1");
        chk(score_hits === 0,
            "1e seq_arb.score_valid_i was NEVER high  <-- bit6=1 did NOT reach the audio path");
        //  ⭐ `score_cnt_o` = `seq_arb` **自己**记的"曲谱源推了几条"
        //     ⇒ ⭐ 它就是"**有没有占 voice**"的直接证据（⭐ `K-106` 可观测性 ✅）
        chk(dut.g_sound.u_seq_arb.score_cnt_o === 16'd0,
            "1f seq_arb score_cnt_o is still 0  <-- bit6=1 did NOT occupy a voice");
        //  ⭐⭐ **`same_hit` / 挂音纪律**（⭐ 硬约束 ③）：
        //     ⭐ 被标记的音符**根本没有 ON 事件**（⭐ 它压根没进 `seq_arb` ✅）
        //     ⇒ ⭐ **⛔ 不存在"没配对的 OFF"** ⇒ ⭐ **⛔ 不许为它补 OFF** ✅
        //     📌 ⭐ 可观测证据：⭐ `seq_arb` 的入口一拍都没被拉高
        //        ⇒ ⭐ 下游 `note_manager` **看不到它** ⇒ ⭐ 无从"留下挂音" ✅
        chk(dut.g_sound.u_seq_arb.merged_cnt_o === 16'd0,
            "1h nothing at all came out of the arbiter yet (no dangling note to release)");
        chk(dut.eb_rd_valid === 1'b0,
            "1i the buffer is drained (the event was consumed exactly once)");

        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ②：⭐ `bit6=0` ⇒ **照常出声**（⭐ 证明没把整条流门掉）✅
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ `tick = 2` ＋ ⭐ `bit6 = 0` ⇒ ⭐ 等 `cur_tick_r` 走到 2 才发（⭐ ≈ 5.2 万拍 ✅）
        //     📌 ⭐ 若闸门写错成"**整条流都门掉**"（⭐ 例如漏了 `~`）⇒ 🔴 `2c/2d` **必红** ✅
        $display("== 2  bit6=0  =>  照常出声（没把整条流门掉）==");
        //  ⭐⭐ 2026-10-16：⭐ 音高 = **C#3**（⭐ `note_off5 = 4`）⇒ ⭐ 键盘表 ⇒ **键 6** ✅
        //     📌 ⭐ **这样 `2e` 才有非空洞性**：⭐ 若闸门写错成"恒亮" ⇒ 🔴 键 6 会亮 ⇒ 必红 ✅
        send_frame(pack(20'd2, 21'd37791, 4'd6, 8'd200, 2'd0, 5'd4, 1'b0), 1'b0);
        wait_evt(16'd2, 120_000);
        wait_score_hits(1, 120_000);
        repeat (2) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd2, "2a the bit6=0 event fired");
        chk(note_pulses === 2, "2b exactly two note events emitted so far");
        chk(score_hits === 1,
            "2c seq_arb.score_valid_i WAS high once  <-- bit6=0 DID reach the audio path");
        chk(dut.g_sound.u_seq_arb.score_cnt_o === 16'd1,
            "2d seq_arb score_cnt_o is now 1  <-- it DID occupy a voice (normal note)");
        //  ⭐⭐ 2026-10-15：⭐ **`bit6=0` ⛔ 不进 LED 指引** —— ⭐ 这是**需求要的** ✅
        //     ⭐ 需求原文：*"`guide_lamp.note_valid_i = ps_note_valid & evt_guide_only`
        //        ⇒ ⭐ **LED 只指引被标记的那一轨**"* ✅
        //     📌 ⭐ 所以"**正常音符**"在指引层是**不亮**的（⭐ 它自己响的时候，
        //        ⭐ 键灯由 `ee_key_on` 那一路点 —— ⚠️ **与 `guide_lamp` 无关** ✅）
        //     🔴 **本条同时是判据 ① 的【对照】**：⭐ 只有 `bit6` 能决定 LED 指引
        //        ⇒ ⭐ 若闸门写错成"**恒亮**"（⭐ 例如漏了 `&`）⇒ 🔴 **本条必红** ✅
        chk(dut.u_guide_lamp.guide_key_o[6] === 1'b0,
            "2e the bit6=0 note did NOT light the GUIDE lamp (key 6 stays dark)");

        //  ⭐ 判据 ①② 已经**各自跑完、各自报过**（⭐ 红原文里两条都在 ✅）
        //     ⇒ ⭐ 现在才允许"**别再等了**"：⭐ 判据 ③ 的混流若注定要等，就别耗看门狗 ✅
        if (fail_cnt != 0) skip_rest = 1'b1;

        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ③：⭐ **混流** —— `bit6=1` / `bit6=0` 交替 ✅
        //     ⭐ 只有 `bit6=1` 的不出声（⭐ 逐条对账 ✅）
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ 三条一起灌：⭐ (tick 500, bit6=1) · (tick 2, bit6=0) · (tick 3, bit6=1)
        //     📌 ⭐ 第 1 条**立刻到期**（⭐ 500 ≤ 0+960 ✅）⇒ ⭐ 先出
        //     📌 ⭐ 后两条按 `tick` 先后出（⭐ 2 ⇒ 3 ✅）
        //     ⇒ ⭐ 期望：⭐ `evt_cnt` 3 · ⭐ `note_pulses` 5 · ⭐ `guided_note` 3
        //        ⭐ `score_hits` **只涨 1**（⭐ 只有那条 `bit6=0` ✅）
        //        ⭐ `sa_score_cnt` **只涨 1**（⭐ 2 → …）✅
        $display("== 3  mixed stream: bit6=1 / bit6=0 alternating ==");
        //  ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **音高按【期望灯位】选**（⭐ 键盘表）✅
        //     · ⭐ G#3（off 11）⇒ 键 **14**  · ⭐ B3（off 14）⇒ 键 **8**  · ⭐ C#4（off 16）⇒ 键 **9**
        //     📌 ⭐ 这样 `3f`（⭐ 被标记的那条 ⇒ 亮）与 `3g`（⭐ 没标记的那条 ⇒ ⛔ 不亮）
        //        **各自非空洞**（⭐ 只要闸门写错一条就必红 ✅）
        send_frame(pack(20'd500, 21'd37791, 4'd7, 8'd200, 2'd0, 5'd11, 1'b1), 1'b0);
        send_frame(pack(20'd2,   21'd37791, 4'd8, 8'd200, 2'd0, 5'd14, 1'b0), 1'b0);
        send_frame(pack(20'd3,   21'd37791, 4'd9, 8'd200, 2'd0, 5'd16, 1'b1), 1'b0);
        wait_evt(16'd5, 120_000);
        wait_score_hits(2, 120_000);
        repeat (2) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd5,
            "3a all five events were consumed (the stream itself was NOT blocked)");
        chk(note_pulses === 5, "3b five note events emitted by play_seq");
        chk(guided_note === 3,
            "3c three of them carried bit6=1 (2 from the mixed batch + 1 from phase 1)");
        chk(score_hits === 2,
            "3d ONLY the bit6=0 ones reached seq_arb (2 total: 1 in phase 2 + 1 in the mix)");
        chk(dut.g_sound.u_seq_arb.score_cnt_o === 16'd2,
            "3e ONLY the bit6=0 ones took a voice (score_cnt_o == 2)");
        chk(dut.u_guide_lamp.guide_key_o[9] === 1'b1,
            "3f the LAST bit6=1 event (C#4 => key 9) still lit its LED  <-- guide survives in a mix");
        //  ⭐ **对照**：⭐ 混流里那条 `bit6=0`（⭐ B3 ⇒ 键 8）**⛔ 不点亮指引灯** ✅
        //     📌 ⭐ 这两条（`3f` / `3g`）**合起来**才证明"**逐事件**"是真的逐事件 ——
        //        ⚠️ 若 `bit6` 解码接错（⭐ 例如接到 `bit5`）⇒ 🔴 两条**必红** ✅
        chk(dut.u_guide_lamp.guide_key_o[8] === 1'b0,
            "3g the bit6=0 event (B3 => key 8) did NOT light the GUIDE lamp  <-- per-event is per-event");
        chk(dut.eb_ovf === 1'b0, "3h no evt_buf overflow for the whole stream");

        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ④：⭐ **没被 `bit6` 标记的 `note_off` 也必须能熄灯** ✅
        //     （⭐ 2026-10-16 · 点灯 LIGHTER 新增 —— ⭐ 这是 `top.v` 闸门
        //      **必须【不对称】** 的那一条判据 ✅）
        //
        //  🔴 **为什么必须有它**：⭐ 闸门原来对 `note_on` / `note_off` **一视同仁** ⇒
        //     ⭐ 若上位机**只在 `note_on` 上置 `bit6`**（⭐ "给某条音符置 `bit6`"
        //        最自然的实现 ⇒ ⭐ 只置起始那一条）⇒
        //     🔴 **那一盏灯【永远灭不掉】**（⭐ 只有复位才灭）
        //     ⇒ ⭐ 症状：⭐ **整场只有一盏灯在闪、永远不换、永远不灭** ✅
        //     📌 ⭐ 这正是用户实测 *"很多都只闪 C3 这一个灯"* 里
        //        **"只闪一盏 + 不换灯"** 那一半的机理 ✅
        //  ✅ **修法**：⭐ `top.v` 的 `u_guide_lamp.note_valid_i` 加 `| ps_is_note_off`
        //     ⇒ ⭐ **`note_on` 门控 · ⭐ `note_off` 一律放行** ✅
        //  📌 ⭐ **能红实证**：⭐ 去掉那一项（⭐ = 回到 2026-10-15 的写法）
        //     ⇒ 🔴 **4c 必红**（⭐ `guide_key_o[4]` 停在 1，⭐ 灯挂住）✅
        //  ⚠️ ⭐ **本条⛔ 不削弱 2e/3g**：⭐ 那两条验的是 `note_on`，⭐ 而本修法
        //     **⛔ 不放行未标记的 `note_on`** ⇒ ⭐ 它们**照样绿** ✅
        // ═════════════════════════════════════════════════════════════════
        $display("== 4  an UNMARKED note_off must still clear the lamp ==");
        //  ⭐⭐ 2026-10-16：⭐ 音高 = **D3**（⭐ `note_off5 = 5`）⇒ ⭐ 键盘表 ⇒ **键 4** ✅
        //     📌 ⭐ **OFF 必须用【同一个 `note_off5`】**（⭐ 否则它要灭的是**另一盏灯** ✅）
        send_frame(pack(20'd960, 21'd37791, 4'd4, 8'd200, 2'd0, 5'd5, 1'b1), 1'b0);   // ⭐ 标记的 ON
        wait_evt(16'd6, 150_000);
        repeat (2) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd6, "4a the bit6=1 note_on fired");
        chk(dut.u_guide_lamp.guide_key_o[4] === 1'b1,
            "4b the bit6=1 note_on lit key 4's guide lamp (D3)");
        send_frame(pack(20'd0, 21'd37791, 4'd4, 8'd200, 2'd1, 5'd5, 1'b0), 1'b0);     // ⭐ 未标记的 OFF
        wait_evt(16'd7, 150_000);
        repeat (2) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd7, "4c the unmarked note_off was consumed");
        chk(dut.u_guide_lamp.guide_key_o[4] === 1'b0,
            "4d the lamp is NOT stuck: an unmarked note_off cleared it  <-- no hanging lamp");

        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 判据 ⑤：⭐ **重播（节拍器中途不关）时，示范段仍必须能亮灯** ✅
        //     （⭐ 2026-10-17 · ESP32 侧回函点名要求的那条"能红的判据" ✅）
        //
        //  🔴 **缺陷**（`top.v:1000` / `:1797`）：
        //     ```verilog
        //     wire met_start = met_on_r & ~met_on_r_d;      // ⭐ 节拍器【开】的那一拍脉冲
        //     else if (met_start) evt_guide_seen_r <= 1'b0; // ⭐ 唯一清路
        //     ```
        //     ⇒ ⭐ `met_start` 是"**节拍器被打开**"那一拍，⛔ **不是每次起播** ✅
        //     ⇒ 🔴 节拍器一直开着、用户只是**重播** ⇒ 脉冲不会再来
        //        ⇒ `evt_guide_seen_r` 卡在 1（⭐ 判据 ④ 的 bit6=1 ON 已把它置 1）
        //        ⇒ ⭐ `note_valid_i` 的四个或项
        //           （`guide_only_r | evt_guide_only | ~evt_guide_seen_r | ps_is_note_off`）
        //           对 **bit6=0 的 note_on 全为 0** ⇒ 🔴 **拿不到灯** ✅
        //
        //  📌 **场景**：判据 ④ 刚发过一条 bit6=1 的 ON ⇒ 闩锁已置 1
        //     ⭐ 然后【直接】再发一条 bit6=0 的 ON（= 重播，⛔ 全程不碰节拍器）
        //
        //  ⚠️ **本判据今天必红** —— 它钉的就是那个缺陷（⭐ 这正是它存在的意义）✅
        //     ✅ **修法**（`top.v`）：⭐ 清路改挂【真正的起播】（如曲谱流重启 /
        //        `evt_buf` 写侧新一批的首字），⛔ 而不是 `met_start` ✅
        //     📌 判据 ①~④ 不受影响（⭐ 它们各自独立发帧）✅
        // ═════════════════════════════════════════════════════════════════
        $display("== 5  a REPLAY (metronome left ON) must still light bit6=0 events ==");
        chk(dut.evt_guide_seen_r === 1'b1,
            "5a the latch is set by the earlier bit6=1 event (replay precondition)");
        //  ── ⭐ 重播的"新谱开始"：发一条【谱头 tempo 帧】（kind=2, tick=0）──────
        //     ⭐ 这是 `top.v` 里 `ps_new_score` 的触发条件（⭐ 见 `evt_guide_seen_r` 声明处）✅
        //     ⚠️ `inc` 填**当前默认 tick_inc**（164927 = 120 BPM，⭐ 见判据 0a）
        //        ⇒ ⭐ **速度不变**（⛔ 不影响后面 `wait_evt` 的时序）✅
        send_frame(pack(20'd0, 21'd164927, 4'd0, 8'd0, 2'd2, 5'd0, 1'b0), 1'b0);
        repeat (4) @(posedge clk);
        chk(dut.evt_guide_seen_r === 1'b0,
            "5b' the head tempo frame (kind=2, tick=0) cleared the latch  <-- the fix");
        send_frame(pack(20'd2, 21'd37791, 4'd4, 8'd200, 2'd0, 5'd5, 1'b0), 1'b0);  // ⭐ 重播：未标记的 ON
        //  ⚠️ **tick 必须用小值** —— 本 tb 的既有帧用的是 `960 / 2 / 500 / 2 / 3 / 960 / 0`
        //     （⭐ 见 `:243/:278/:317-319/:363/:369`）⇒ ⭐ 内部 tick 计数器是**小步推进**的 ✅
        //     🔴 **我第一版写了 `1440`** ⇒ ⚠️ 事件在 `wait_evt` 的 150 000 拍窗口内**永不到期**
        //        ⇒ 🔴 **5b 假红**（⭐ 不是闩锁的问题，是"事件根本没播"）✅
        //     📌 ⭐ 这正是本项目的老陷阱：**红也要红对原因**（⭐ 否则修完 5b 还是红）✅
        wait_evt(16'd9, 150_000);
        repeat (2) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd9, "5c the replayed bit6=0 note_on fired");
        chk(dut.u_guide_lamp.guide_key_o[4] === 1'b1,
            "5d a REPLAY still lit key 4  <-- RED before the fix: the clear was on met_start only");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_top_guide_bit6 - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_top_guide_bit6 - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗：⭐ 正常路径约 8 万拍 ⇒ ⭐ 给 **150 万拍（= 30 ms）**
    //     ⇒ ⭐ **只有在真的挂死时**才触发（⭐ 那时 `TIMEOUT` 就是正确的判决 ✅）
    //
    //  ⭐⭐ **自旋上限是【判据的一部分】**（⭐ ⚠️ 别为了"保险"调大）：
    //     ⭐ 回退 `top.v` 的闸门 ⇒ ⭐ `bit6=1` **不进 `seq_arb`** 这条会失效，
    //        ⚠️ 而 `evt_cnt_o` **照样会涨** ⇒ ⭐ 若自旋上限太大
    //        ⇒ 🔴 **红的会变成 `TIMEOUT`（⭐ 看不出是哪条判据坏）** ✅
    //     ✅ 现在每个上限 ≈ **实测所需拍数的 1.5~2.3 倍**
    //        （⭐ 实测：⭐ ①9.4 万 · ⭐ ②5.2 万 · ⭐ ③7.8 万 拍 ✅）
    //        ＋ ⭐ `skip_rest` 早停 ⇒ ⭐ **红得又快又指向明确** ✅
    //     📌 ⭐ **实测**：⭐ 正常路径 **24 s**；⭐ 最坏的失败路径（三段自旋跑满）
    //        **≈ 125 s** ⇒ ⭐ 都在 `tb_all.ps1` 的 300 s 预算内 ✅
    initial begin
        #30_000_000;
        $display("FAIL: tb_top_guide_bit6 TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
