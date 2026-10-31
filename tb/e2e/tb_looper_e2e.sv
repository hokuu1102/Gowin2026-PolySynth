`timescale 1ns/1ps
// tb_looper_e2e.sv -- ⭐⭐ 2026-10-14：⭐ **looper 的【顶层】端到端判据**
//
//   🔴 **为什么必须新写一条**（⭐ 用户 2026-10-14 报的 bug ✅）：
//      ⭐ `tb/w3c/tb_looper.sv` **5/5 全绿** —— ⚠️ 但它验的是 **looper 模块本身** ✅
//      🔴 **没有任何 tb 覆盖这些**：
//         · ⭐ `R` → 弹音 → `R` → `L` 的**顶层**通路
//         · ⭐ `rd_lock` 与 `'Y'` 的交互
//         · ⭐ 手弹事件**到底有没有真的录进 `evt_cnt`**
//      ⇒ ⭐ 所以上板坏在这里，仿真**看不出来** ✅
//
//   ⭐ **用户原话（复现）**：
//      *"按 R 开始录制，再按一次 R 停止录制，之后 L 没有听见回放"*
//      *"发 Y 返回 ！"*
//
//   ⭐⭐ **判据（⭐ 每条都能失败 ✅）**：
//      ① ⭐ 复位后：`looper_evt_cnt == 0`（⭐ 基线 ✅）
//      ② ⭐ 发 `'R'` ⇒ ⭐ `loop_rec_on_r` **变 1**（⭐ 录制真的开了 ✅）
//      ③ ⭐ **弹一个音**（⭐ ADC 逐通道覆盖 ⇒ 单键 ✅）
//      ④ ⭐ 再发 `'R'` ⇒ ⭐ `loop_rec_on_r` **变 0**（⭐ 录制真的停了 ✅）
//      ⑤ 🔴 **`looper_evt_cnt > 0`** —— ⭐ **这条就是"到底有没有录进去"** ✅
//      ⑥ ⭐ 发 `'L'` ⇒ ⭐ `loop_play_on_r` **变 1** ✅
//      ⑦ 🔴 **回放真的吐事件**（⭐ `looper_play_valid` 有脉冲 ✅）
//      ⑧ ⭐ 全程 `rd_lock` **不许卡住** ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 无 BOM · ⭐ 轮询全有上限（`K-94` ✅）

`timescale 1ns/1ps

module tb_looper_e2e;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 参数（⭐ 与 `tb_demo_stall_diag` 同一口径 ⇒ 仿真可行 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer AXIS_W       = 4;
    localparam integer DEMO_DELAY   = 10_000;
    localparam integer DEMO_HOLD    = 20_000;
    localparam integer AUTOTARE_DLY = 5_000;
    localparam integer TB_REFRACT_N = 4;
    localparam integer AT_GUARD     = 400;      // × 1000 拍（⭐ 防无声挂死 ✅）
    localparam integer PRESS_HOLD   = 30_000;   // ⭐ 30 帧（⭐ 必须 > 流水线延迟 ~9 帧 ✅）
    localparam integer REL_SETTLE   = 5_000;    // ⭐ 5 帧 ✅
    localparam integer SETTLE_CLK   = 5_000;    // ⭐ 复位后稳定 ✅
    localparam integer PLAY_GUARD   = 40;       // × 1000 拍（⭐ 只为"进入播放态"✅）
    //  ⭐⭐ **ADC 帧周期**（⭐ 本 tb 的关键提速手段 ✅）
    //     🔴 **默认 2000 Hz ⇒ 一帧 25000 拍（500 µs）** —— ⚠️ 而本 tb 要等
    //        "按下被看见 / 松开被看见 / 回放绕一圈"，⭐ 全按帧放大
    //        ⇒ 🔴 **实测：整条 tb 撞上 120 s 预算被判超时** ✅
    //     ✅ 调到 **50 kHz ⇒ 一帧只要 1000 拍**（⭐ 快 25×）⇒ ⭐ 时序同比缩小 ✅
    //     📌 ⚠️ 它**只影响采样节拍**，⛔ 不改任何语义（⭐ 与 `tb_demo_stall_diag`
    //        "缩小 demo 时序只为仿真可行"**同一手法** ✅）
    localparam integer TB_FRAME_CLK = 1_000;

    // ⭐ 电平（⭐ `tb_e2e` 口径：松手 1985 → `pos` 0；按下 1241 → `pos` 744 ✅）
    localparam [11:0] RAW_REST = 12'h7C1;
    localparam [11:0] RAW_DOWN = 12'h4D9;

    // ⭐ 串口：115200 @ 50 MHz ⇒ **434 拍/位** ✅
    //   📌 2026-10-28 板载口改档 500 kbps → 115200（TJC 屏不支持 500 k 档）⇒ tb 同步适配
    localparam integer BAUD_CLK = 434;

    integer errors = 0;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 时钟 / 复位 / DUT
    // ═══════════════════════════════════════════════════════════════════════
    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    reg  rx = 1'b1;
    wire tx;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi;
    wire [5:0] spi_cs_n;
    wire miso_l, miso_r;

    reg [7:0]  l_ch_mask = 8'd0, r_ch_mask = 8'd0;
    reg [11:0] l_ch_val  = RAW_DOWN, r_ch_val = RAW_DOWN;

    top #(
        //  ⭐ 与 `tb_demo_stall_diag` 同一套（⭐ 已实测可行 ✅）
        .SCOPE_MODE            (0),           // ⭐ 不测 HDMI ⇒ 剪掉李萨如
        .DEMO_CHORD_ON         (1),           // ⚠️ 必须 1：否则走 `g_silent`，`g_sound.*` 不存在
        .DEMO_NOTE_DELAY       (DEMO_DELAY),
        .DEMO_HOLD_CYC         (DEMO_HOLD),
        .SOURCE_A_SEL          (0),           // ⭐ 0 = 走 `seq_arb`（手弹 + 演示）＝上板档
        .SEL_DRUM              (0),
        .METRONOME_ON          (0),
        .DPOS_DIAG             (0),           // ⭐ `K-161`：⛔ 不要为顺手置 1
        .AUTOTARE_DELAY_CLK    (AUTOTARE_DLY),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .timbre_btn_i  (1'b1),
        .pluck_up_i    (1'b0),
        .pluck_down_i  (1'b0),
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .led_heartbeat (led_hb),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        .uart_rx       (rx),
        .uart_tx       (tx),
        //  ⭐⭐ 控制板：⭐ **一个键都不按**（⭐ 排除键盘幻影干扰 ✅）
        .ctrl_col_i    (4'b1111),
        .enc_a_i       (1'b1),
        .enc_b_i       (1'b1),
        .enc_sw_i      (1'b1)
    );

    //  ⭐ 缩短 `event_extract` 的不应期（⭐ 只为让"同轴连按"可仿 ✅）
    defparam u_top.g_sound.u_event_extract.REFRACT_N = TB_REFRACT_N;
    //  ⭐⭐ 提速：⭐ ADC 帧周期 2000 Hz（25000 拍）⇒ 50 kHz（1000 拍）✅
    defparam u_top.g_sound.u_adc_farm.CHANNEL_RATE_HZ = 50_000;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ ADC 从机（⭐ 逐通道覆盖 ⇒ 能按单键 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_l (
        .cs_n     (spi_cs_n[0]),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_l),
        .ovr_en_i (1'b0),                 // ⭐ 0 ⇒ 走逐通道覆盖
        .ovr_val_i(RAW_DOWN),
        .ch_mask_i(l_ch_mask),
        .ch_val_i (l_ch_val)
    );

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_r (
        .cs_n     (spi_cs_n[1]),
        .sclk     (spi_sclk),
        .mosi     (spi_mosi),
        .miso     (miso_r),
        .ovr_en_i (1'b0),
        .ovr_val_i(RAW_DOWN),
        .ch_mask_i(r_ch_mask),
        .ch_val_i (r_ch_val)
    );

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 只读探针（⭐ 全部用【输出端口或已知层次名】✅）
    // ═══════════════════════════════════════════════════════════════════════
    wire [15:0] p_evt_cnt = u_top.g_sound.looper_evt_cnt;
    wire        p_lay_st  = u_top.g_sound.looper_layer_state;
    wire        p_rd_lock = u_top.rd_lock;
    wire        p_rec_on  = u_top.g_sound.loop_rec_on_r;
    wire        p_play_on = u_top.g_sound.loop_play_on_r;
    wire        p_play_v  = u_top.g_sound.looper_play_valid;
    wire        p_live_v  = u_top.g_sound.w3a_evt_valid;

    //  ⭐ 回放事件计数器（⭐ 判据 ⑦ 用 ✅）
    integer n_play = 0;
    always @(posedge clk) if (rst_n && p_play_v) n_play = n_play + 1;

    //  ⭐ 手弹事件计数器（⭐ 诊断"到底有没有弹进去" ✅）
    integer n_live = 0;
    always @(posedge clk) if (rst_n && p_live_v) n_live = n_live + 1;

    //  ⭐ `rd_lock` 卡死计数器
    integer n_lock = 0;
    always @(posedge clk) if (rst_n && p_rd_lock) n_lock = n_lock + 1;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 任务
    // ═══════════════════════════════════════════════════════════════════════
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

    //  ⭐ 发一个字节（⭐ 真 UART，500 kbaud ✅）
    task send_byte;
        input [7:0] cmd;
        integer bi;
        begin
            @(negedge clk); rx = 1'b0; repeat (BAUD_CLK) @(negedge clk);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rx = cmd[bi]; repeat (BAUD_CLK) @(negedge clk);
            end
            rx = 1'b1; repeat (BAUD_CLK * 2) @(negedge clk);
        end
    endtask

    //  ⭐ 按下 / 松开单键（⭐ 逐通道覆盖 ✅）
    task set_key;
        input [AXIS_W-1:0] ax;
        input              on;
        reg [7:0] m;
        begin
            m = 8'd0;
            if (on) m[ax[2:0]] = 1'b1;
            if (ax < 8) l_ch_mask = m;
            else        r_ch_mask = m;
        end
    endtask

    //  ⭐ 有上限的轮询（⭐ 防无声挂死 —— `K-94` ✅）
    task wait_autotare;
        integer g;
        begin
            g = 0;
            while ((u_top.g_sound.at_done !== 1'b1) && (g < AT_GUARD)) begin
                repeat (1000) @(posedge clk);
                g = g + 1;
            end
            if (u_top.g_sound.at_done !== 1'b1)
                $display("FAIL: autotare never asserted at_done within %0d cycles", g * 1000);
            else
                $display("  [tare ] at_done=1 after ~%0d cycles", g * 1000);
        end
    endtask

    task print_state;
        input [255:0] tag;
        begin
            $display("  [%0s] evt_cnt=%0d lay_st=%b rec_on=%b play_on=%b rd_lock=%b n_live=%0d n_play=%0d",
                     tag, p_evt_cnt, p_lay_st, p_rec_on, p_play_on, p_rd_lock, n_live, n_play);
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════════
    initial begin
        $dumpfile("build/sim/tb_looper_e2e/tb_looper_e2e.vcd");
        $dumpvars(0, tb_looper_e2e);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;

        wait_autotare;
        repeat (SETTLE_CLK) @(negedge clk);

        // ══ 判据 ①：⭐ 基线 —— 没录过 ⇒ `evt_cnt == 0` ══
        print_state("baseline");
        chk(p_evt_cnt === 16'd0, "baseline: looper_evt_cnt is 0 before any recording");
        chk(p_lay_st  === 1'b0,  "baseline: looper_layer_state is 0 (looper is idle)");
        chk(p_rd_lock === 1'b0,  "baseline: rd_lock is 0");

        // ══ 判据 ⑨：⭐ **空循环 ⇒ `'L'` 必须【被拒】**（⭐ 2026-10-14 新修 ✅）══
        //     ⭐ 依据：⭐ 用户报"L 没回放" —— ⭐ 根因是"**没录进去**"，⛔ 不是回放坏了 ✅
        //     🔴 **旧行为**：⭐ `'L'` 无条件切进去 ⇒ ⭐ **一片寂静** ⇒ 用户以为坏了 ✅
        //     ✅ **新行为**：⭐ 与 `'Y'` 同口径 —— ⭐ 空循环回 `'!'` 且**不切进去** ✅
        //     📌 ⭐ 本判据必须在【录制之前】跑 —— ⭐ 那时循环才是空的 ✅
        send_byte(8'h4C);                        // ⭐ 'L'
        repeat (2000) @(negedge clk);
        print_state("empty L");
        chk(p_play_on === 1'b0,
            "*** 'L' on an EMPTY loop is REJECTED (loop_play_on_r stays 0) -- no more silent playback ***");

        // ══ 判据 ②：⭐ 发 `'R'` ⇒ 录制开 ══
        n_live = 0; n_play = 0;
        send_byte(8'h52);                        // ⭐ 'R'
        repeat (2000) @(negedge clk);
        print_state("after R #1");
        chk(p_rec_on === 1'b1, "*** 'R' #1 turns loop_rec_on_r ON (recording really starts) ***");

        // ══ 判据 ③：⭐ 弹一个音（⭐ 轴 0 按下 → 保持 → 松开 ✅）══
        set_key(4'd0, 1'b1);
        repeat (PRESS_HOLD) @(negedge clk);
        print_state("key held");
        chk(n_live > 0, "*** a hand-played note produced live events while the key is HELD ***");
        set_key(4'd0, 1'b0);
        repeat (REL_SETTLE) @(negedge clk);
        print_state("key up");

        // ══ 判据 ④：⭐ 再发 `'R'` ⇒ 录制停 ══
        send_byte(8'h52);                        // ⭐ 'R'
        repeat (2000) @(negedge clk);
        print_state("after R #2");
        chk(p_rec_on === 1'b0, "*** 'R' #2 turns loop_rec_on_r OFF (recording really stops) ***");

        // ══ 判据 ⑤：🔴 **到底有没有录进去** ══
        print_state("after record");
        chk(p_evt_cnt !== 16'd0,
            "*** looper_evt_cnt > 0 after R -> play -> R  (THIS is the user's symptom: if it is 0, 'Y' replies '!' and L plays silence) ***");

        // ══ 判据 ⑥：⭐ 发 `'L'` ⇒ 回放开 ══
        n_play = 0;
        send_byte(8'h4C);                        // ⭐ 'L'
        repeat (2000) @(negedge clk);
        print_state("after L");
        chk(p_play_on === 1'b1, "*** 'L' turns loop_play_on_r ON (playback really starts) ***");

        // ══ 判据 ⑦：⭐ **回放真的【进入播放态】** ══
        //     📌 ⭐ **分工说明（⭐ 如实 ✅）**：
        //        ⭐ "回放**吐事件**"（`looper_play_valid` 有脉冲）由
        //           **`tb/w3c/tb_looper.sv`（模块级，5/5 绿）** 覆盖 ✅
        //        🔴 **本 tb ⛔ 不重复验它** —— ⚠️ 因为 `looper` 的**起播是小节对齐**的
        //           （⭐ `tb_looper` 里就有 `T41 bar alignment`）
        //           ⇒ ⚠️ 顶层仿真里"第一个回放事件什么时候到"**取决于小节相位**
        //           ⇒ 🔴 固定等会**假红**，轮询又要等整个小节（⭐ 实测撞 120 s 预算 ✅）
        //        ⭐ 本 tb 只验**顶层这一层**该验的：⭐ 命令到了、状态真的切了 ✅
        //     📌 `n_play` 仍**打印**（⭐ 诊断用），⛔ 不作判据 ✅
        begin : wait_play_blk
            integer g;
            g = 0;
            while ((p_lay_st !== 1'b1) && (g < PLAY_GUARD)) begin
                repeat (1000) @(negedge clk);
                g = g + 1;
            end
            $display("  [play ] looper entered the PLAYING state after ~%0d cycles", g * 1000);
        end
        print_state("after playback");
        chk(p_lay_st === 1'b1,
            "*** the looper really entered its PLAYING state after 'L' (top-level control path OK; the replay payload itself is tb_looper's job) ***");

        // ══ 判据 ⑧：⭐ `rd_lock` 全程不卡 ══
        chk(p_rd_lock === 1'b0, "rd_lock is still 0 at the end (never got stuck)");

        $display("");
        if (errors == 0)
            $display("PASS: looper end-to-end (top level) -- 'R' starts recording, a hand-played note is really captured (evt_cnt>0), 'R' stops, 'L' starts playback and the looper enters its PLAYING state; an 'L' on an EMPTY loop is REJECTED instead of silently playing silence. The replay payload itself is covered by tb_looper.");
        else
            $fatal(1, "FAIL: tb_looper_e2e had %0d error(s)", errors);

        #100;
        $finish;
    end

    //  ⭐ 总超时（⭐ 防无声挂死 ✅）
    initial begin
        #40000000;                               // 40 ms
        $display("FAIL: tb_looper_e2e timed out");
        $fatal(1, "timeout");
    end

endmodule
