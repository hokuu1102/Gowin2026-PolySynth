// ─────────────────────────────────────────────────────────────────────────────
// tb_top_score_path.sv · ⭐ **曲谱链路的【顶层】判据**（2026-10-11 新建）
//
// ⭐ **为什么必须有它**：
//    ⭐ `tb_score_chain` 验的是"`evt_buf` ＋ `play_seq` **两个模块之间**的握手"，
//    ⚠️ 而**`top.v` 里那条接线本身**（⭐ `eu_evt_* → u_evt_buf → u_play_seq →
//       seq_arb.score / guide_lamp`）**没有任何判据覆盖** ✅
//    🔴 接线错了（⭐ 接了旧源 / 漏接 / 接反）⇒ ⚠️ **全部静默** ——
//       ⭐ 而"事件静默丢失"正是本项目**头号缺陷族**（⭐ `K-106` / `P0-29`）✅
//
// ⭐⭐ **本 tb 的核心判据（⭐ 一眼看出"改前/改后"的差别）**：
//    ⭐ 灌一条 **`tick = 8`** 的曲谱事件 ⇒ ⭐ 在 `cur_tick_r` 走到 8 **之前**：
//       · ⭐ `u_evt_buf` 里**存着它**（`eb_rd_valid == 1`）
//       · ⭐ `play_seq` **一条都还没吐**（`evt_cnt_o == 0`）  ← ⭐⭐ **判据 A**
//    ⇒ ⭐ 这**正是改前的行为差别**：🔴 改前 `eu_evt_valid` **直连** `seq_arb`
//       ⇒ ⭐ 事件**当拍就进合成链** ⇒ 🔴 `tick` 字段**完全被忽略** ✅
//    ⭐ 然后等它**按 tick 自己出来**（`evt_cnt_o == 1`）⇒ ⭐ 证明链路真的在按音乐位置跑 ✅
//
// ⭐ **判据清单**：
//    · A ⭐⭐ **未来事件被【缓冲】住、⛔ 不立刻发**（`eb_rd_valid==1` 且 `evt_cnt_o==0`）✅
//    · B ⭐ **到点自己出来**（`evt_cnt_o` 变 1、⭐ `note_valid_o` 脉冲 1 次）✅
//    · C ⭐ **LED 指引位被点亮**（`u_guide_lamp.guide_key_o[axis] == 1`）
//      —— ⭐ 这是"**指引那半复活**"的直接证据（⭐ 改前 `guide_key_i` 是常量 0 ✅）
//    · D ⭐ **缓冲排空**（`u_evt_buf` 非空标志归 0）✅
//    · E ⭐ **没溢出**（`eb_ovf == 0`）✅
//    · F ⭐⭐ **`kind=2` 换速真的进了 `beat_gen`**（`play_seq.tick_inc_o` 变成事件里的值）
//      ＋ ⭐ **不产生音符** ✅
//
// ⚠️ 串口激励：⭐ 与 `tb_test_mode_top` **同档**（⭐ 500 kbaud @ 50 MHz ⇒ `BIT_CYC=100`）✅
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_top_score_path;

    localparam integer BIT_CYC = 100;      // ⭐ top 的串口：500 kbaud @ 50 MHz ✅

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    //  ⭐⭐ 2026-10-11：⭐ **两条 UART 分开驱动**（⭐ 这是本轮接线的判据基础 ✅）
    reg uart_rx       = 1'b1;    // ⭐ ESP32 那一路（`G22`）—— ⭐ **曲谱** ✅
    reg uart_rx_board = 1'b1;    // ⭐ 板载那一路（`D14`）—— ⭐ **串口屏/命令** ✅
    always #10 clk = ~clk;

    wire esp_tx_o;               // ⭐ ESP32 那一路的发送（`G21`）✅

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_heartbeat;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;

    top #(
        .PA_ON_AFTER_RESET     (0),
        .DEMO_CHORD_ON         (1),            // ⭐ 要真声音链
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
        //  ⭐⭐ 2026-10-11：⭐ **曲谱现在走【ESP32 独立 UART】**（⭐ `G21`/`G22`）✅
        //     🔴 **改前**：⭐ 本 tb 把曲谱帧发在**板载口**（`uart_rx`）上 ——
        //        ⚠️ 那时曲谱与串口屏/命令**共用一条线**（⭐ `P0-02` 那条 P1 的根因 ✅）
        //     ✅ **现在**：⭐ 板载口**只**接串口屏/命令 ⇒ ⭐ **恒定空闲**
        //        ＋ ⭐ 曲谱帧发到 `esp_uart_rx_i` ✅
        //     📌 ⭐ 判据依据：⭐ `files/10-硬件/Console拓展板接线需求-20261003.md:562/564`
        //        （⭐ 命令/调试 + 串口屏共用 `XH_SCREEN`；⭐ ESP32 **独立** `XH_ESP32` ✅）
        .uart_rx(uart_rx_board), .uart_tx(),
        .esp_uart_rx_i(uart_rx), .esp_uart_tx_o(esp_tx_o)
    );

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

    // ── ⭐ 事件打包（⭐ 与 `mid2evt.py` / `play_seq` 位域逐位一致 ✅）──────────
    //  ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **低 7 位不再是"全 0"** ✅
    //     ⭐ 新位域：`bit6` = 只亮灯不出声 · `bit5` = `is_drum` ·
    //        ⭐ **`bit[4:0]` = `note_off5` = `MIDI − 45`**（⭐ **灯位由它决定** ✅）
    //     📌 ⭐ 详见 `rtl/w3c/guide_lamp.v` 头部 §音高语义 ✅
    function [63:0] pack;
        input [19:0] tk;
        input [20:0] inc;
        input [3:0]  ax;
        input [7:0]  vel;
        input [1:0]  knd;
        input [4:0]  p5;          // ⭐ `note_off5`（⭐ 灯位依据）
        begin
            pack = {tk, inc, ax, vel, knd, 2'b00, 1'b0, 1'b0, p5};
        end
    endfunction

    //  ⭐⭐ 2026-10-11：⭐ **`sel` 选哪条线**（⭐ 0 = ESP32 口（曲谱）· ⭐ 1 = 板载口（屏/命令））✅
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

    // ── ⭐ 观测：⭐ `play_seq` 吐了几个音符 ✅ ────────────────────────────────
    integer note_pulses;
    always @(posedge clk) begin
        if (rst_n && dut.g_sound.u_play_seq.note_valid_o)
            note_pulses = note_pulses + 1;
    end

    integer i;
    integer spin;
    //  ⭐⭐ 2026-10-11：⭐ **G 段专用**（⭐ 两条 UART 各归各 ✅）
    integer ga_evt0;
    reg     ga_buf0;
    //  ⭐⭐ 2026-10-11：⭐ **`ga_fr0` = 帧计数基线**（⭐ 单调 ⇒ ⭐ 判据不会假绿 ✅）
    reg [15:0] ga_fr0;
    integer gb_seen;
    //  ⭐⭐ 2026-10-11：⭐ **H 段（曲谱音高量纲）专用** ✅
    reg [31:0] h_inc = 32'd0;
    reg [63:0] h_f   = 64'd0;
    //  ⭐ 抓"音符脉冲那一拍"的 `ps_evt_inc`（⭐ 它是组合的，⭐ 只在 `ps_note_valid` 时有效 ✅）
    //  ⚠️ **两个信号的层次【不一样】**（⭐ 实测踩到编译错才发现 ✅）：
    //     · ⭐ `ps_note_valid` 在 **`top` 模块级**（⭐ `top.v:1184` ✅）
    //     · ⭐ `ps_evt_inc`   在 **`g_sound` 里**（⭐ `top.v:3965` ✅）
    always @(posedge clk)
        if (dut.ps_note_valid) h_inc <= dut.g_sound.ps_evt_inc;
    //  ⭐⭐ 2026-10-11：⭐ **`TICK_AT` 从 3 改成 1** —— ⭐ **纯粹为了仿真速度** ✅
    //     🔴 **为什么可以**：⭐ 判据要证的是"**事件先被缓冲、⭐ 到点才发**"
    //        ⇒ ⭐ `tick = 1`（⭐ 复位后**第一个** tick）**同样**能证它 ✅
    //        （⭐ 若 `tick = 0` 则"到点"与"立刻"不可区分 ⇒ ⚠️ **判据会变空** ✅）
    //     📌 ⭐ 实测动机：⭐ `tick = 3` 要等 **78k 拍**，⭐ 而顶层 50 MHz 全跑**很慢**
    //        ⇒ ⚠️ 这个 tb 一度 **300 s 都跑不完**（⭐ 见 `tb_all.ps1` 的 `$heavyTb` 注释 ✅）
    localparam integer TICK_AT = 1;

    initial begin
        note_pulses = 0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        $display("=== tb_top_score_path (曲谱链路【顶层】判据) ===");
        $display("   play_seq 复位默认 tick_inc = %0d（⭐ 120 BPM = 164927）",
                 dut.g_sound.u_play_seq.tick_inc_o);
        chk(dut.g_sound.u_play_seq.tick_inc_o === 32'd164927,
            "0a tick_inc default is 120 BPM (beat_gen tempo now comes from play_seq)");

        // ═════════════════════════════════════════════════════════════════
        $display("== A 未来事件必须被【缓冲】住（tick=%0d），⛔ 不许立刻发 ==", TICK_AT);
        // ═════════════════════════════════════════════════════════════════
        send_frame(pack(20'd1, 21'd37791, 4'd5, 8'd200, 2'd0, 5'd3), 1'b0);
        @(negedge clk);
        chk(dut.eb_rd_valid === 1'b1, "Aa the event is sitting in u_evt_buf (rd_valid == 1)");
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd0,
            "Ab play_seq has emitted NOTHING yet (tick has not arrived) <-- the key change");
        chk(note_pulses == 0, "Ac no note yet");
        chk(dut.eb_ovf === 1'b0, "Ad no overflow for a single event");

        // ═════════════════════════════════════════════════════════════════
        $display("== B/C/D 到点自己出来 + LED 指引点亮 + 缓冲排空 ==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ 有界自旋（⛔ 不写死拍数 —— ⭐ 免得又踩"差一"的坑 ✅）
        spin = 0;
        while ((dut.g_sound.u_play_seq.evt_cnt_o === 16'd0) && (spin < 2_000_000)) begin
            @(posedge clk);
            spin = spin + 1;
        end
        $display("   info: 等了 %0d 拍（⭐ tick=%0d @120 BPM ≈ %0d 拍）",
                 spin, TICK_AT, TICK_AT * 26041);
        //  ⚠️ **必须再等两拍**：⭐ `note_valid_o` 与 `evt_cnt_o` 是**同一沿**更新的，
        //     ⭐ 而 `guide_lamp` 要**再下一个沿**才把它锁进 `guide_key_o` ✅
        //     📌 ⭐ 实测：⭐ 不等 ⇒ 🔴 `Ca` 假红（⭐ 链路其实是对的 ✅）
        repeat (2) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd1,
            "Ba play_seq emitted the event once its tick arrived");
        chk(note_pulses == 1, "Bb exactly ONE note was emitted (no duplicate)");
        chk(dut.g_sound.u_play_seq.note_data_o[22:19] === 4'd5,
            "Bc the emitted event carries axis 5 (fields survived the whole chain)");
        //  ⭐⭐ **LED 指引**：⭐ 这一位就是"**该按哪个键**" ✅
        //  ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **灯位依据已从 `axis` 改成【音高】** ✅
        //     ⭐ 本条事件：⭐ `axis = 5`（⭐ **轨号**，⛔ 与灯无关）＋
        //        ⭐ `note_off5 = 3` ⇒ ⭐ MIDI 48 = **C3** ⇒ ⭐ **键盘表：C3 = 键 5** ✅
        //     📌 ⭐ 所以"**点亮键 5**"这件事**同时**证明：
        //        ⭐ ① `guide_lamp` 还活着 · ⭐ ② **音高字段真的走到了灯那一路** ✅
        //     ⚠️ ⭐ 若 `note_off5` 丢了（⭐ 例如 `top.v` 忘了接 `ps_note_off5`）
        //        ⇒ 🔴 `Ca` **必红**（⭐ offset 0 = A2 = 键盘表无此项 ⇒ 不点灯 ✅）
        chk(dut.u_guide_lamp.guide_key_o[5] === 1'b1,
            "Ca guide_lamp lit key 5 (C3's key -- the LED guide half is ALIVE) <-- the whole point");
        chk(dut.u_guide_lamp.guide_key_o[4] === 1'b0,
            "Cb other keys are NOT lit (one-hot, no crosstalk)");
        @(negedge clk);
        chk(dut.eb_rd_valid === 1'b0, "Da u_evt_buf drained after the event was consumed");

        // ═════════════════════════════════════════════════════════════════
        $display("== F kind=2 换速：⭐ 真的进了 beat_gen，⭐ 且不产生音符 ==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐ 60 BPM 的 `tick_inc` = 82463（⭐ 契约 §1.3 速查表 ✅）
        send_frame(pack(20'd0, 21'd82463, 4'd0, 8'd0, 2'd2, 5'd0), 1'b0);
        @(negedge clk);
        spin = 0;
        while ((dut.g_sound.u_play_seq.tempo_cnt_o === 16'd0) && (spin < 200_000)) begin
            @(posedge clk);
            spin = spin + 1;
        end
        chk(dut.g_sound.u_play_seq.tick_inc_o === 32'd82463,
            "Fa tick_inc_o now carries the tempo from the kind=2 event");
        chk(dut.g_sound.u_play_seq.tempo_cnt_o === 16'd1, "Fb tempo applied exactly once");
        chk(note_pulses == 1, "Fc a kind=2 event produces NO note (count still 1)");
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd2, "Fd it was still counted as consumed");

        // ═════════════════════════════════════════════════════════════════
        $display("== G 两条 UART 必须【各归各】：曲谱只认 ESP32 那一路 ==");
        // ═════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-11：⭐ **这是本轮接线的判据** ✅
        //     ⭐ 依据：⭐ `files/10-硬件/Console拓展板接线需求-20261003.md`
        //        · `:562` 命令/调试 + 串口屏 → `XH_SCREEN`（**共用一条** ✅）
        //        · `:564` ESP32 → `XH_ESP32`（**独立一条** ✅）
        //  🔴 **`Ga` 为什么必须存在**：⭐ 它就是 `P0-02` 那条 P1 的**根因判据** ——
        //     ⚠️ 改前曲谱接收器挂在**板载口**上 ⇒ ⭐ 屏帧/命令流的载荷里的 `0xA5`
        //        会被当帧头 ⇒ 🔴 **伪曲谱事件**（⭐ `P0-02` 只治了标 ✅）
        //     ✅ 现在曲谱只认 ESP32 那一路 ⇒ ⭐ **板载口上发真曲谱帧也不该进缓冲** ✅
        ga_fr0  = dut.eu_frame_cnt;
        ga_evt0 = dut.g_sound.u_play_seq.evt_cnt_o;
        ga_buf0 = dut.eb_rd_valid;
        send_frame(pack(20'd1, 21'd1_111_111, 4'd7, 8'd150, 2'd0, 5'd0), 1'b1);   // ⭐ 发在【板载口】
        @(negedge clk);
        //  🔴🔴 **`Ga` 的第一版查的是 `eb_rd_valid` —— ⚠️ 而变异体实测它【会假绿】** ✅
        //     ⭐ 原因：⭐ `tick = 1` 的事件**早已到期** ⇒ ⭐ `play_seq` 会**立刻把它取走**
        //        ⇒ ⚠️ 等我查的时候 `eb_rd_valid` **已经回到 0** ⇒ 🔴 **判据侥幸通过** ✅
        //     📌 ⭐ **这正是"变异体测试"的价值**：⭐ 它在**修法正确**的情况下
        //        ⚠️ 也暴露了"**判据本身太弱**" ✅
        //  ✅ **改成查【帧计数】`eu_frame_cnt`** —— ⭐ 它是**单调计数器**：
        //     ⭐ 一旦收满一帧就 **+1**、⭐ **取走也⛔ 不会回退** ⇒ ⭐ **不可能假绿** ✅
        chk(dut.eu_frame_cnt === ga_fr0,
            "Ga the BOARD uart must NOT feed the score receiver (frame_cnt unchanged)");
        chk(dut.g_sound.u_play_seq.evt_cnt_o === ga_evt0,
            "Ga2 no score event was consumed from the board uart");

        //  ⭐ `Gb`：⭐ **ESP32 的 TX 必须是【活】的**（⛔ 不是恒定空闲）——
        //     ⚠️ 改前它是 `assign esp_uart_tx_o = 1'b1;` ⇒ 🔴 **永远不发** ✅
        //     ⭐ 做法：⭐ 在**板载口**发 `'P'`（诊断探针）⇒ ⭐ 它会把回包推进 `u_tx_fifo`
        //        ⇒ ⭐ 两个 `uart_tx` **镜像**同时发 ⇒ ⭐ **ESP32 那一路必须出现起始位（拉低）** ✅
        gb_seen = 0;
        fork
            begin : gb_watch
                integer gk;
                //  ⭐ 12000 拍 = **240 µs** ⇒ ⭐ 足够（⭐ `'P'` 一个字节 ≈ 1000 拍
                //     ＋ ⭐ `pos_probe` 的启动延迟 ✅）；⛔ 不设 60000（⭐ 那是纯浪费 ✅）
                for (gk = 0; gk < 12000; gk = gk + 1) begin
                    @(posedge clk);
                    if (esp_tx_o === 1'b0) gb_seen = 1;
                end
            end
            begin : gb_send
                pc_send_byte(8'h50, 1'b1);       // ⭐ `'P'` = 位置探针（⭐ 会回包）
            end
        join
        chk(gb_seen == 1, "Gb the ESP32 uart TX is ALIVE (a start bit appeared) -- not tied to 1");

        // ═════════════════════════════════════════════════════════════════
        $display("== H ⭐⭐ 曲谱音高的【量纲】：inc 必须按【采样率】解释 ==");
        // ═════════════════════════════════════════════════════════════════
        //  🔴🔴 **本条是 2026-10-11 发现的重大缺陷的判据** ✅
        //     · ⭐ `tools/mid2evt.py:115` 是 **`FS = 50_000_000.0`**
        //       ⇒ ⭐ 它给 MIDI 69（A4 = 440 Hz）写
        //          `inc = round(440 × 2^32 / 50e6) = **37791**` ✅
        //     · ⭐ 而 `oscillator_bank` 的相位**按 `sample_tick_i` 推进**
        //       （⭐ `oscillator_bank.v:725` 的 `phase_q <= phase_q + lane_inc`
        //         在 `sample_tick_i` 门控内 ✅）⇒ ⭐ 时钟是 **48.828125 kHz** ✅
        //     ⇒ 🔴 **直接零扩展用** ⇒ ⭐ 实际频率 = `37791/2^32 × 48828.125 = **0.43 Hz**`
        //        ⇒ ⭐ **低 1024 倍（正好 10 个八度）** ⇒ 🔴 **整条曲谱变成次声波** ✅
        //     📌 ⭐ **为什么以前没暴露**：⭐ 这条链路在 2026-10-11 之前
        //        **结构上不可能工作**（⭐ `play_seq` 从未被例化 ✅）
        //        ＋ ⭐ `P0-02` 门控把载荷全挡掉 ✅ ⇒ ⭐ **从来没人听到过** ✅
        //     📌 ⭐ **契约的洞**：⭐ `play_seq接口冻结契约.md:145-150` **只定义了
        //        `tick_inc`（速度）的量纲**（⭐ `2^32 × f / 50e6` ✅ —— ⭐ 那**是对的**，
        //        因为 `beat_gen` 的相位**按系统时钟**推进 ✅）
        //        ⇒ ⚠️ **`phase_inc`（音高）的量纲【没有定义】** ✅
        //     ✅ **修法**：⭐ 在 `top.v` 把**音高**那条路的 `inc` **左移 10 位**
        //        （⭐ `50e6 ÷ 48828.125 = 1024 = 2^10` ✅）⇒ ⭐ 正好补上 ✅
        //     ⛔ **注意（⭐ 关键）**：⭐ **只能移【音高】** ——
        //        ⚠️ `kind=2` 的 `inc` 是 `tick_inc`（⭐ 走 `play_seq.tick_inc_o` → `beat_gen`）
        //        ⇒ ⭐ **它的量纲本来就是对的** ⇒ ⛔ **不许移** ✅
        //  ⚠️ 判据口径：⭐ 把 `ps_evt_inc` **按采样率**换算成 Hz ⇒ ⭐ 必须是 **440 Hz** ✅
        //     📌 ⭐ **非空洞性内建**：⭐ 未修时 `37791` 换算出来是 **0 Hz** ⇒ ⭐ 必红 ✅
        h_f = (h_inc * 64'd48828) >> 32;          // ⭐ 频率（⭐ 整数 Hz ✅）
        $display("   info: 曲谱事件的 inc=%0d ⇒ 按采样率换算 = %0d Hz（⭐ 期望 440）", h_inc, h_f);
        chk((h_f >= 64'd439) && (h_f <= 64'd441),
            "H1 the score note's phase_inc yields 440 Hz at the SAMPLE rate (not 50 MHz)");
        chk(h_inc > 32'd2_097_151,
            "H2 non-vacuity: the value must have been SCALED up past the 21-bit wire field");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_top_score_path - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_top_score_path - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗：⭐ tick=8 约 21 万拍 ⇒ ⭐ 给 300 万拍（⭐ 只在真挂死时触发 ✅）
    initial begin
        #60_000_000;
        $display("FAIL: tb_top_score_path TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
