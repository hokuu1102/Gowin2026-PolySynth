// ─────────────────────────────────────────────────────────────────────────────
// tb_top_guide_axes.sv · ⭐ **LED 指引"跟着音高走"的【顶层】判据**（2026-10-16 新建）
//                        （⭐ 2026-10-16 二次改：⭐ 点灯依据由 `axis` 改为**音高**）
//
// ⭐ **为什么必须有它**（⭐ 点灯 LIGHTER · 用户实测 *"很多都只闪 C3 这一个灯"*）：
//    ⭐ 现有判据**从来没有验过"两个不同的音高 ⇒ 两盏不同的灯【同时】亮"** ——
//       · `tb_guide_lamp` 验的是**模块级**映射
//       · `tb_top_guide_bit6` 1d/3f 各只验**一盏**灯（⭐ 且受 `bit6` 闸门控制）
//       · `tb_top_score_path` Ca 只验**一个**键（key 5）
//    ⇒ 🔴 **若映射在【顶层】被折叠成一盏灯**（⭐ 例如索引写成常量、⭐ 或位宽被截断、
//       ⭐ 或 `note_off5` 忘了从 `top.v` 接过去），⭐ **上面几条判据【全部】照样绿**
//       ⇒ ⚠️ 这正是用户报的症状，而**无人能发现** ✅
//
// ⭐⭐ **2026-10-16（指北 COMPASS）⭐ 语义变更**：
//    ⭐ 用户拍板：*"LED 指引要跟着音高走，而且【变调之后】不许指错键"* ✅
//    ⇒ ⭐ 灯位 = **音高查表**（⭐ 帧 `bit[4:0]` = `note_off5` = `MIDI − 45`），
//      🔴 **`axis`（轨号）⛔ 不再参与灯位** ✅
//    ⇒ ⭐ 因此本 tb 的判据从"**6 个不同的轴 ⇒ 6 盏灯**"
//      改成"**6 个不同的音高 ⇒ 6 盏灯**"（⭐ 判据 ①）
//      ＋ ⭐ **新增判据 ③：⭐ 同一轨、不同音高 ⇒ 不同的灯**（⭐ **用户要的那一条** ✅）
//    📌 ⭐ 顶层 tb 里 `play_fretboard_mode = 0`（⭐ `MODE_PIANO_DEFAULT=1`）
//       ⇒ ⭐ 走**键盘表 `NOTE2KEY_KB`** ⇒ ⭐ 下面的音高都按**键盘表**选 ✅
//
// ⭐ **本 tb 的判据（⭐ 逐条都能红）**：
//    · ① ⭐⭐ **6 个不同音高 ⇒ 6 盏不同的灯【同时】亮**（⭐ `popcount == 6`）
//      —— 🔴 **折叠成一盏 ⇒ 必红**（⭐ 把 `guide_lamp.v` 的索引写成常量即可复现）
//    · ② ⭐ **清灯清对位**：⭐ 给**其中一个音高**发 `note_off` ⇒ ⭐ **只有那一盏灭**，
//        其余 5 盏**保持亮**（⭐ 防"清灯清错位"与"一清全灭" ✅）
//    · ③ ⭐⭐⭐⭐ **同一轨（`axis` 相同）· 不同音高 ⇒ 点亮【不同】的灯**
//        —— 🔴 **这一条就是用户报的那个 bug 的判据**：
//           ⚠️ 旧语义下同一条轨**只会亮同一盏灯**（⭐ 用户实测"只闪一个灯"）✅
//        📌 ⭐ **反例（必红）**：⭐ 把 `guide_lamp` 改回按 `axis` 选灯
//           ⇒ 🔴 `3b`（两个音高 ⇒ 同一个灯）**必红** ✅
//    · ④ ⭐ **通路贯通**：⭐ `u_led_data.guide_key_i` 必须**逐位等于**
//        `guide_key_o & ~ee_key_on` —— ⭐ 这是 `guide_lamp ⇒ led_data` 那**一根线**的判据
//        （⭐ 现有 tb **一根都没验**：⭐ 它们只看 `guide_key_o`，⭐ 不看它去了哪 ✅）
//
// ⚠️ 串口激励：⭐ 与 `tb_top_guide_bit6` **同档**（⭐ 500 kbaud @ 50 MHz ⇒ `BIT_CYC=100`）✅
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps
`default_nettype none

module tb_top_guide_axes;

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
        .DEMO_CHORD_ON         (1),            // ⭐ 要真声音链（⭐ 与既有顶层 tb 同档 ✅）
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

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 事件打包（⭐ 与 `mid2evt.py` / `score_word.py` / `play_seq` 逐位一致 ✅）
    //     `{tick(20), inc(21), axis(4), vel(8), kind(2), timbre(2), bit6, bit5, off5(5)}`
    //     ⭐ **`bit[4:0]` = `note_off5` = `MIDI − 45`** —— ⭐ **灯位由它决定** ✅
    //     ⭐ 本 tb **全部用 `gonly = 0`**（⭐ = 普通曲谱流 ⇒ `evt_guide_seen_r` 恒 0
    //        ⇒ ⭐ `guide_lamp` 看到的是**裸 `ps_note_valid`**，⭐ 与 `bit6` 闸门无关 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    function [63:0] pack;
        input [19:0] tk;
        input [20:0] inc;
        input [3:0]  ax;
        input [7:0]  vel;
        input [1:0]  knd;
        input [4:0]  p5;          // ⭐ `note_off5`（⭐ 灯位依据）
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
    //  ⭐ 探针：⭐ 数 `guide_key_o` 的**置位数**（⭐ 用来判"是不是都挤到一盏灯"）✅
    //     ⚠️ 用函数（⭐ 组合、⭐ 每拍重算）⇒ ⭐ 不可能"缓存住一个旧值" ✅
    // ═══════════════════════════════════════════════════════════════════════
    function integer popcount16;
        input [15:0] v;
        integer i;
        begin
            popcount16 = 0;
            for (i = 0; i < 16; i = i + 1)
                popcount16 = popcount16 + v[i];
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ **音高 → 键位**（⭐ 键盘表 `NOTE2KEY_KB`，⭐ 与 `rtl/w3a/axis_map.v` 的
    //     `kb_inc[]` 同内容；⭐ 由 `build/exp/note2key_gen.py` 机械反推 ✅）
    //     ⭐ 本 tb 只列**用到的 6 个音高**（⭐ `note_off5` = `MIDI − 45`）：
    //        · ⭐ E3  = MIDI 52 ⇒ off  7 ⇒ **键 0**
    //        · ⭐ C3  = MIDI 48 ⇒ off  3 ⇒ **键 5**
    //        · ⭐ C#4 = MIDI 61 ⇒ off 16 ⇒ **键 9**
    //        · ⭐ A3  = MIDI 57 ⇒ off 12 ⇒ **键 12**
    //        · ⭐ G3  = MIDI 55 ⇒ off 10 ⇒ **键 13**
    //        · ⭐ A#3 = MIDI 58 ⇒ off 13 ⇒ **键 15**
    //        · ⭐ G#3 = MIDI 56 ⇒ off 11 ⇒ **键 14**（⭐ 判据 ③ 用）
    //        · ⭐ D3  = MIDI 50 ⇒ off  5 ⇒ **键 4**（⭐ 判据 ③ 用）
    //     📌 ⭐ 期望位图 = 键 `{3,5,9,12,13,15}` ⇒ `0xB228` ✅
    //     ⭐⭐ 2026-10-18（用户裁定）：⭐ **E3 的指引灯改点【键 3】**（⛔ 不是键 0）——
    //        钢琴没有 E# ⇒ `kb_inc[0]` 与 `kb_inc[3]` 同为 E3 ⇒ 指引指定另一颗 ✅
    //        🔴 改前 `AX6_ALL = 0xB221`（含键 0）⇒ 本 tb 的 1b/1d/1e/1g/2c/3c 全部变红 ✅
    // ═══════════════════════════════════════════════════════════════════════
    localparam [4:0] P_E3   = 5'd7;
    localparam [4:0] P_C3   = 5'd3;
    localparam [4:0] P_Cs4  = 5'd16;
    localparam [4:0] P_A3   = 5'd12;
    localparam [4:0] P_G3   = 5'd10;
    localparam [4:0] P_As3  = 5'd13;
    localparam [4:0] P_Gs3  = 5'd11;
    localparam [4:0] P_D3   = 5'd5;

    // ⭐ 键 3/5/9/12/13/15 全亮 = `0xB228`（⭐ 8+32+512+4096+8192+32768 ✅）
    localparam [15:0] AX6_ALL   = 16'hB228;
    // ⭐ 没点过的键（0,1,2,4,6,7,8,10,11,14）⇒ ⭐ 掩码 = `~AX6_ALL` ✅
    localparam [15:0] AX6_UNSET = 16'h4DD7;
    // ⭐ 清掉键 5（⭐ 那条 `note_off`）之后
    localparam [15:0] AX6_NO5   = 16'hB208;
    // ⭐ 再加上键 14（⭐ 判据 ③）
    localparam [15:0] AX6_WITH14 = 16'hF208;

    integer spin;
    task wait_evt;
        input [15:0] want;
        input integer limit;
        begin
            spin = 0;
            while ((dut.g_sound.u_play_seq.evt_cnt_o !== want) && (spin < limit)) begin
                @(posedge clk);
                spin = spin + 1;
            end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 激励：⭐ **6 个不同音高 · 全部 `tick = 0`（⭐ 立刻到期）· `bit6 = 0`** ✅
    //     ⭐ `axis` **故意全填 0** —— ⚠️ 这就是判据的**要害**：
    //        ⭐ **同一条轨**（⭐ `axis = 0`）＋ ⭐ **6 个不同音高**
    //        ⇒ ⭐ **必须亮 6 盏不同的灯** ✅
    //        🔴 **旧语义下这 6 条只会亮同一盏灯**（⭐ 用户报的那个 bug）✅
    //     📌 ⭐ `inc = 21'h0_93A4` —— ⭐ **照抄真曲**（⭐ `夜洋风景/events.hex:1` 的
    //        `0x00000049D20C1000` ⇒ ⭐ `inc = 0x93A4`，⭐ = A4 ≈ 440 Hz）✅
    // ═══════════════════════════════════════════════════════════════════════
    localparam [20:0] INC_A4 = 21'h0_93A4;

    initial begin
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        $display("=== tb_top_guide_axes (LED 指引：不同音高 ⇒ 不同的灯) ===");
        //  ⭐ 前置：⭐ 本 tb **不碰 `bit6`**（⭐ 全部 `gonly = 0`）⇒
        //     ⭐ `evt_guide_seen_r` 必须**始终为 0** ⇒ ⭐ 走"裸 `ps_note_valid`"那条路 ✅
        //     📌 ⭐ 这一条同时是**判据的前提**：⭐ 若它不为 0，⭐ 后面的灯就"少亮"了 ✅
        chk(dut.guide_only_r === 1'b0, "0a global 'U' guide mode is OFF");
        chk(dut.evt_guide_seen_r === 1'b0, "0b the bit6 sticky flag is still 0 (normal score stream)");
        chk(dut.u_guide_lamp.guide_key_o === 16'h0000, "0c guide bitmap is all 0 after reset");
        //  ⭐ 模式前提：⭐ 顶层默认**钢琴**（⭐ `MODE_PIANO_DEFAULT=1`）⇒ ⭐ 走键盘表 ✅
        //     📌 ⭐ 它**是判据 ① 的前提**（⭐ 指板表下这 6 个音高对应的键**不一样**）✅
        chk(dut.play_fretboard_mode === 1'b0,
            "0d default mode is PIANO => guide_lamp uses the keyboard (kb) table");

        // ═════════════════════════════════════════════════════════════════
        //  ① ⭐⭐ **6 个不同音高（同一条轨）⇒ 6 盏【不同】的灯同时亮** ✅
        // ═════════════════════════════════════════════════════════════════
        $display("== 1  six different PITCHES (same axis) => six different lamps ==");
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_E3,  1'b0), 1'b0);
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_C3,  1'b0), 1'b0);
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_Cs4, 1'b0), 1'b0);
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_A3,  1'b0), 1'b0);
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_G3,  1'b0), 1'b0);
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_As3, 1'b0), 1'b0);
        wait_evt(16'd6, 400_000);
        repeat (4) @(posedge clk);          // ⭐ 等 `guide_lamp` 锁存（⭐ 与既有 tb 同口径 ✅）

        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd6,
            "1a all six events were consumed by play_seq");
        chk(dut.u_guide_lamp.guide_key_o === AX6_ALL,
            "1b the six pitches lit EXACTLY their own keys (0xB228)");
        chk(popcount16(dut.u_guide_lamp.guide_key_o) === 6,
            "1c popcount == 6  <-- NOT all collapsed onto one lamp (the user's symptom)");
        //  ⭐ 2026-10-18：⭐ E3 的键从 **0** 改成 **3**（⭐ 同音换颗，用户裁定）✅
        chk(dut.u_guide_lamp.guide_key_o[3]  === 1'b1 &&
            dut.u_guide_lamp.guide_key_o[5]  === 1'b1 &&
            dut.u_guide_lamp.guide_key_o[9]  === 1'b1 &&
            dut.u_guide_lamp.guide_key_o[12] === 1'b1 &&
            dut.u_guide_lamp.guide_key_o[13] === 1'b1 &&
            dut.u_guide_lamp.guide_key_o[15] === 1'b1,
            "1d each of the six pitches has its OWN lamp lit at the same time");
        chk((dut.u_guide_lamp.guide_key_o & AX6_UNSET) === 16'h0000,
            "1e the keys we never asked for (0,1,2,4,6,7,8,10,11,14) stayed OFF");
        //  ⭐⭐ 判据 ④：⭐ **通路贯通** —— ⭐ `guide_lamp ⇒ led_data` 那**一根线** ✅
        //     ⭐ 消隐后的位图必须**逐位**进到 `led_data.guide_key_i`：
        //        `led_data.guide_key_i == guide_key_o & ~ee_key_on`（⭐ `top.v` 的接线）✅
        //     📌 ⭐ 它**⛔ 不是恒真式**：⭐ 若那根线接错（⭐ 接成 `16'd0` / 接成未消隐的
        //        `guide_key_o` / 接错片）⇒ 🔴 **本条必红** ✅
        chk(dut.u_led_data.guide_key_i === (dut.u_guide_lamp.guide_key_o & ~dut.ee_key_on),
            "1f u_led_data.guide_key_i is wired to (guide_key_o & ~ee_key_on)  <-- the LED path");
        chk(dut.u_led_data.guide_key_i === AX6_ALL,
            "1g led_data sees all six guide bits (no key is pressed in this tb)");

        // ═════════════════════════════════════════════════════════════════
        //  ② ⭐ 清灯清对位：⭐ 只给 C3 发 `note_off` ⇒ ⭐ 只有键 5 那盏灭 ✅
        //     📌 ⭐ 反例（⭐ 会红）：⭐ "清灯清错位"（⭐ 灭了别的灯）、
        //        ⭐ "一清全灭"（⭐ 6 盏全灭）✅
        // ═════════════════════════════════════════════════════════════════
        $display("== 2  one note_off clears exactly ONE lamp ==");
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd1, P_C3, 1'b0), 1'b0);
        wait_evt(16'd7, 200_000);
        repeat (4) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd7, "2a the note_off was consumed");
        chk(dut.u_guide_lamp.guide_key_o[5] === 1'b0,
            "2b C3's lamp (key 5) went OFF on its note_off");
        chk(dut.u_guide_lamp.guide_key_o === AX6_NO5,
            "2c ONLY that lamp cleared -- the other five are still lit (0xB201)");
        chk(popcount16(dut.u_guide_lamp.guide_key_o) === 5,
            "2d popcount == 5 (a single note_off must not wipe the whole bitmap)");

        // ═════════════════════════════════════════════════════════════════
        //  ③ ⭐⭐⭐⭐ **同一轨 · 不同音高 ⇒ 【不同】的灯**（⭐ 用户要的那一条）✅
        //
        //  🔴 **为什么必须有它**：⭐ 用户实测 *"很多都只闪 C3 这一个灯"* ——
        //     ⚠️ 根因就是"**灯位 = `axis`（轨号）**"：⭐ **一条轨只有一盏灯** ✅
        //     ⇒ ⭐ 本条用 **同一个 `axis`（= 0）** 送**【两个不同音高】**，
        //        ⭐ 断言**两盏不同的灯**依次亮起 ✅
        //  📌 ⭐ **反例（必红）**：⭐ 若把 `guide_lamp` 改回按 `axis` 选灯
        //     ⇒ ⭐ 两个音高都落到 `axis=0` 的那一盏 ⇒ 🔴 `3b` 红 ✅
        // ═════════════════════════════════════════════════════════════════
        $display("== 3  SAME axis, different pitches => DIFFERENT lamps (the user's bug) ==");
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_Gs3, 1'b0), 1'b0);  // ⭐ G#3 ⇒ 键 14
        wait_evt(16'd8, 200_000);
        repeat (4) @(posedge clk);
        chk(dut.g_sound.u_play_seq.evt_cnt_o === 16'd8, "3a the same-axis note_on was consumed");
        chk(dut.u_guide_lamp.guide_key_o[14] === 1'b1,
            "3b same axis (0), new pitch (G#3) => a DIFFERENT lamp (key 14) lit");
        chk(dut.u_guide_lamp.guide_key_o === AX6_WITH14,
            "3c only bit14 was added -- the five still-lit lamps are untouched (0xF201)");
        //  ⭐⭐ **决定性对照**：⭐ 再用**另一个音高**（⭐ D3 ⇒ 键 4）⇒ ⭐ 又一盏**新的**灯 ✅
        //     📌 ⭐ 三条事件 `axis` **全是 0** —— ⚠️ 而灯位**各不相同** ✅
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd0, P_D3, 1'b0), 1'b0);   // ⭐ D3 ⇒ 键 4
        wait_evt(16'd9, 200_000);
        repeat (4) @(posedge clk);
        chk(dut.u_guide_lamp.guide_key_o[4] === 1'b1,
            "3d a third pitch on the SAME axis lit yet another lamp (key 4)");
        chk(popcount16(dut.u_guide_lamp.guide_key_o) === 7,
            "3e popcount == 7  <-- a single track drove SEVEN different lamps (was 1 before)");
        send_frame(pack(20'd0, INC_A4, 4'd0, 8'd130, 2'd1, P_Gs3, 1'b0), 1'b0);
        wait_evt(16'd10, 200_000);
        repeat (4) @(posedge clk);
        chk(dut.u_guide_lamp.guide_key_o[14] === 1'b0 && dut.u_guide_lamp.guide_key_o[4] === 1'b1,
            "3f its note_off cleared ONLY key 14 (key 4 and the rest untouched)");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_top_guide_axes - %0d/%0d judgements held", pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_top_guide_axes - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗：⭐ 正常路径约 12 万拍（⭐ 10 帧 × 约 1.1 万拍）⇒ ⭐ 给 150 万拍（= 30 ms）✅
    //     ⇒ ⭐ 只有真的挂死时才触发（⭐ 那时 `TIMEOUT` 就是正确判决 ✅）
    initial begin
        #30_000_000;
        $display("FAIL: tb_top_guide_axes TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
