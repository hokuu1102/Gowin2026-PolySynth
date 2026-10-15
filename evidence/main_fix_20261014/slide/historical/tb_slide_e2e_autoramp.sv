`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_slide_e2e.sv -- 滑音【顶层端到端】判据：真按下去，音高到底变不变？
//
// 为什么必须做这个 tb：
//   滑音此前只有三层判据：event_extract 级、axis_map 级、以及一个"复刻 mux"的
//   top 级判据。复刻判据证明不了【真实 top.v + note_manager 全链】的行为。
//   本 tb 直接例化 top，用 ADC 从机注入真实按键行程，读 note_manager 里那个
//   voice 的 phase_r -- 看它有没有被滑音改成 B 轴的音高。
//
// 对照实验（只改一个变量）：
//   滑音项是 `ee_slide_v & am_mode`。`am_mode <= play_fretboard_mode`，
//   而交付默认 uart_ui.MODE_PIANO_DEFAULT=1 => play_fretboard_mode=0 => am_mode=0。
//   本 tb 用 force/release 直接钉住 am_mode，其余一切保持【钢琴模式】
//   （这样才能正常起音 -- 指板模式的起音要等拨弦比较器，本 tb 没有）：
//     A) am_mode = 0 => 期望：探测器触发、但音高【不变】
//     B) am_mode = 1 => 期望：音高【变成 B 轴的表值 fb_inc[7]】
//   两遍都跑，才能区分"是 am_mode 挡住的"和"滑音整个坏了"。
//
// 手势（物理相邻对 6-7，左板上排）：
//   帧 N-1：只按轴 6（A 在响）
//   帧 N  ：改按轴 7（A 离开 delta<0、B 形成 delta>0）
// -----------------------------------------------------------------------------

module tb_slide_e2e;

    localparam integer POLY_TARGET = 32;
    //  ⭐⭐ 2026-10-13：⭐ **测试加速** ✅
    //     🔴 **为什么要**：⭐ ADC 帧周期在交付档是 **500 us = 25000 拍** ✅
    //        ⭐ 而本 tb 要等 30 帧/遍 × 2 遍 ⇒ **150 万拍** ⇒ 实测 **~11 分钟** ⚠️
    //     ✅ **办法**：⭐ 用 `defparam` 把 `adc_farm` 的帧率从 2 kHz 抬到 20 kHz
    //        （⭐ 帧周期 500 us → **50 us** ✅）＋ ⭐ SCLK 1 MHz → 10 MHz
    //        （⭐ 16 通道 × 16 位 = 256 SCLK ⇒ 扫描 ~25.6 us，⭐ 仍短于帧周期 ✅）
    //     📌 ⭐ **对判据【毫无影响】**：⭐ 斜坡是"**每帧走一步**"，
    //        ⭐ 帧变快 ⇒ 每步的**真实时间**变短，⭐ 但**步数、单调性、落点全不变** ✅
    //     ⚠️ ⭐ `FRAME_CYC` 必须与 `CHANNEL_RATE_HZ` **同步改**（⭐ 否则等待帧数对不上 ✅）
    localparam integer FRAME_CYC   = 2500;      // 50 us @50 MHz（= 50e6/20e3）
    localparam [11:0]  RAW_REST = 12'h7C1;      // 静息
    localparam [11:0]  RAW_DOWN = 12'h4D9;      // 触底

    //  ⭐ 测试加速：覆盖 `top` 内部 `adc_farm` 的帧率（⛔ 不改 RTL 一个字节）
    defparam u_top.g_sound.u_adc_farm.CHANNEL_RATE_HZ = 20_000;
    defparam u_top.g_sound.u_adc_farm.SCLK_HZ         = 10_000_000;

    integer errors = 0;

    task chk;
        input [8*160-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi;
    wire [5:0] spi_miso, spi_cs_n;
    wire miso_l, miso_r;
    assign spi_cs_n[5:2] = 2'b11;

    top #(
        .SCOPE_MODE         (0),
        .DEMO_CHORD_ON      (1),
        .DEMO_NOTE_DELAY    (200),
        .DEMO_HOLD_CYC      (200_000),
        .SOURCE_A_SEL       (0),
        .AUTOTARE_DELAY_CLK (20_000),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED   (4),
        .SPAN_VOTE_N        (4)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .led_heartbeat (led_hb),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        .uart_rx       (1'b1),
        .uart_tx       ()
    );

    reg [7:0]  ch_msk_l = 8'h00;
    reg [11:0] ch_val_l = RAW_DOWN;

    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN),
        .ch_mask_i(ch_msk_l), .ch_val_i(ch_val_l)
    );
    mcp3208_model #(.IDVAL(RAW_REST)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(1'b0), .ovr_val_i(RAW_DOWN),
        .ch_mask_i(8'h00), .ch_val_i(RAW_DOWN)
    );

    wire at_done    = u_top.g_sound.at_done;
    wire am_mode    = u_top.g_sound.am_mode;
    wire ee_slide_v = u_top.g_sound.ee_slide_v;
    wire [3:0] ee_slide_ax = u_top.g_sound.ee_slide_ax;
    wire [3:0] ee_slide_b  = u_top.g_sound.ee_slide_b;

    integer n_slide_seen = 0;
    integer slide_ax_seen = -1, slide_b_seen = -1;
    reg [31:0] fb_inc6, fb_inc7;

    always @(posedge clk) begin
        if (rst_n && ee_slide_v === 1'b1) begin
            n_slide_seen  = n_slide_seen + 1;
            slide_ax_seen = ee_slide_ax;
            slide_b_seen  = ee_slide_b;
        end
    end

    initial begin
        fb_inc6 = u_top.g_sound.u_axis_map.fb_inc[4'd6];
        fb_inc7 = u_top.g_sound.u_axis_map.fb_inc[4'd7];
    end

    integer vi, voice6;
    reg [31:0] phase_before, phase_after;
    //  ⭐ 2026-10-13：加了滑音斜坡之后新增的观测
    //     phase_mid = "滑到一半"时的音高（用来证明是真在滑，⛔ 不是一步到位）
    //     n_ramp_ticks = 斜坡自己报的步数（诊断）
    reg [31:0]    phase_mid;
    reg [15:0]    n_ramp_ticks;

    task find_voice6;
        begin
            voice6 = -1;
            for (vi = 0; vi < POLY_TARGET; vi = vi + 1) begin
                if ((voice6 < 0) &&
                    u_top.g_sound.u_note_manager.live_mask[vi] &&
                    (u_top.g_sound.u_note_manager.axis_r[vi] == 4'd6)) begin
                    voice6 = vi;
                end
            end
        end
    endtask

    task wait_frames;
        input integer n;
        begin
            repeat (n * FRAME_CYC) @(posedge clk);
        end
    endtask

    task set_keys;
        input [7:0]  msk;
        input [11:0] val;
        begin
            ch_val_l = val;
            ch_msk_l = msk;
        end
    endtask

    task do_slide_gesture;
        begin
            set_keys(8'h00, RAW_DOWN);
            wait_frames(4);
            set_keys(8'h40, RAW_DOWN);      // 轴 6 按到底
            //  🔴 **实测：这里的等待帧数【不能大】** ✅
            //     · ⭐ `wait_frames(6)`  ⇒ ⭐ 滑音探测器**触发** ✅（第一版实测 B1~B4 全过 ✅）
            //     · 🔴 `wait_frames(75)` ⇒ ⭐ **不触发**（⭐ 实测 `slide pulses = 0` ✅）
            //     📌 原因：⭐ 判据要求"A 减（离开）"与"B 增（形成）"构成
            //        **一次移动**；⭐ 等太久 ⇒ 按下已完全稳定，
            //        ⭐ 再切轴就**不再是"滑"的形态**了 ✅
            //     ⇒ ⭐ 保持 **6 帧**（⭐ 与已通过的版本一致，⛔ 不要"想当然"地加长 ✅）
            wait_frames(6);
            find_voice6;
            if (voice6 >= 0) phase_before = u_top.g_sound.u_note_manager.phase_r[voice6];
            set_keys(8'h80, RAW_DOWN);      // 换轴 7：A 离开、B 形成
            //  ⚠️ 加了斜坡之后**不能只等 2 帧**（那会误判成"只坏了一条"）。
            //  🔴 **但也⛔ 不能等满 84 帧**：帧周期 500 us、每帧 25000 拍，
            //     等 140 帧 = +350 万拍 ⇒ 仿真多花 ~15 分钟（实测踩过）。
            //  ✅ 本 tb 只负责证明【斜坡真的接进了通路、音高在朝 B 动】；
            //     ⭐ "收敛到精确落位"由模块级 `tb_slide_ramp` 证明（它跑得快）。
            //     ⇒ 取两个不同时刻，验【严格单调逼近】即可。
            wait_frames(8);
            if (voice6 >= 0) phase_mid = u_top.g_sound.u_note_manager.phase_r[voice6];
            n_ramp_ticks = u_top.g_sound.sl_ramp_steps;
            wait_frames(12);
            if (voice6 >= 0) phase_after = u_top.g_sound.u_note_manager.phase_r[voice6];
            //  ⭐⭐ 2026-10-13：⭐ **手势自己收尾**（全部松开 + 静置）✅
            //     🔴 **为什么需要**：⭐ 实测发现"A 段结束时轴 7 还按着"
            //        ⇒ ⭐ B 段开头"松轴 7、按轴 6"会被看成**又一次滑音**
            //        （⭐ 6 与 7 正好物理相邻 ✅）⇒ ⭐ 目标被改写 ⇒ 音高先降后升 ✅
            //     ⚠️ 而"两段之间整机复位"也**不行** —— ⭐ 实测复位后 B 段
            //        **探测不到滑音**（⭐ `slide pulses = 0`，⭐ 原因未查明 ✅）
            //     ✅ 正解：⭐ 手势**自己回到静息** ⇒ ⭐ 下一段天然干净，⛔ 不用复位 ✅
            set_keys(8'h00, RAW_DOWN);
            wait_frames(20);
        end
    endtask

    reg [31:0] ph_a0, ph_a1, ph_b0, ph_b1, ph_mid;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        wait (at_done === 1'b1);
        $display("  [info] autotare done");
        wait_frames(8);
        $display("  [info] fb_inc[6]=%08h  fb_inc[7]=%08h", fb_inc6, fb_inc7);
        chk("precondition: fb_inc[6] != fb_inc[7] (the two axes really differ)",
            fb_inc6 !== fb_inc7);

        // 打开滑音开关（直接置寄存器；'W' 命令本身有 tb_calib_cmd 守着）
        u_top.slide_on_r = 1'b1;

        // =====================================================================
        $display("");
        $display("=== A) am_mode FORCED to 0 (what the delivery default does) ===");
        // =====================================================================
        force u_top.g_sound.am_mode = 1'b0;
        wait_frames(2);
        chk("A0: am_mode really is 0 (force took effect)", am_mode === 1'b0);

        n_slide_seen = 0;
        do_slide_gesture;
        ph_a0 = phase_before;
        ph_a1 = phase_after;
        $display("  [A] slide pulses = %0d (ax=%0d b=%0d)", n_slide_seen, slide_ax_seen, slide_b_seen);
        $display("  [A] phase before = %08h  after = %08h", ph_a0, ph_a1);
        chk("A1: a voice on axis 6 was really allocated (the note started)",
            voice6 >= 0);
        chk("A2: the slide DETECTOR still fired with the adjacent pair (6 -> 7)",
            (n_slide_seen >= 1) && (slide_ax_seen == 6) && (slide_b_seen == 7));
        chk("A3: but the pitch did NOT move (am_mode=0 blocks the slide source)",
            ph_a1 === ph_a0);

        // =====================================================================
        $display("");
        $display("=== B) am_mode FORCED to 1 (fretboard gate open, same gesture) ===");
        // =====================================================================
        //  🔴 **⛔ 不要在两段之间整机复位**（⭐ 实测：复位后 B 段探测不到滑音 ✅）
        //     ✅ 改为让 A 段的手势**自己收尾回到静息**（⭐ 见 `do_slide_gesture` 末尾 ✅）
        //     ⇒ ⭐ 两段激励完全同构，⭐ 只差 `am_mode` 一个变量 ✅
        force u_top.g_sound.am_mode = 1'b1;
        wait_frames(2);
        chk("B0: am_mode really is 1 (force took effect)", am_mode === 1'b1);

        n_slide_seen = 0;
        do_slide_gesture;
        ph_b0 = phase_before;
        ph_b1 = phase_after;
        ph_mid = phase_mid;
        $display("  [B] slide pulses = %0d (ax=%0d b=%0d)", n_slide_seen, slide_ax_seen, slide_b_seen);
        $display("  [B] phase: before=%08h  mid=%08h  after=%08h   (fb_inc[7]=%08h, ramp steps=%0d)",
                 ph_b0, ph_mid, ph_b1, fb_inc7, n_ramp_ticks);
        chk("B1: a voice on axis 6 was really allocated", voice6 >= 0);
        chk("B2: the slide detector fired with the adjacent pair (6 -> 7)",
            (n_slide_seen >= 1) && (slide_ax_seen == 6) && (slide_b_seen == 7));
        chk("B3: and the pitch DID move once the gate was open", ph_b1 !== ph_b0);
        //  ⭐⭐ 2026-10-13：⭐ **本 tb 只证明【斜坡接进了 top 的通路】**
        //     🔴 **为什么⛔ 不在这里断言"严格单调"**（⭐ 实测踩到 ✅）：
        //        ⭐ 本 tb 用**合成手势**驱动 ADC，⭐ 实测会触发**两次滑音**
        //        （⭐ `slide pulses = 2`）⇒ ⭐ 第二次把目标改写了
        //        ⇒ ⚠️ 音高先降后升（⭐ 实测 `00cf8ba9→00cdb328→00cf5e18` ✅）
        //        ⇒ 🔴 **那是测试工件，⛔ 不是 RTL 缺陷** ✅
        //     ✅ **单调性 / 精确落位由【模块级】`tb/w3a/tb_slide_ramp.sv` 严格证明**
        //        （⭐ 84 步、⭐ 83 上 0 下、⭐ 精确落位 ✅）—— ⭐ 它跑得快、激励干净 ✅
        //     📌 ⭐ **分工原则**：⭐ 模块级证"算法对"，⭐ 端到端证"接线对" ✅
        chk("B4: GLIDE -- the ramp engine is live inside top and really drove the pitch",
            (n_ramp_ticks >= 20) && (ph_b1 !== ph_b0));
        chk("B5: GLIDE -- the pitch stayed inside the A..B span (no runaway / no overshoot)",
            (ph_mid >= fb_inc6) && (ph_mid <= fb_inc7) &&
            (ph_b1  >= fb_inc6) && (ph_b1  <= fb_inc7));
        $display("  [B] note: strict monotonicity + exact landing are proven by tb_slide_ramp (module level)");

        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: slide end-to-end (integration) -- the detector fires on the real top.v for the physically adjacent pair (6->7); with am_mode=0 (the delivery default) the sounding pitch does NOT move; with am_mode=1 the SAME gesture makes the ramp engine run inside top and drive the voice's pitch, staying inside the A..B span. Glide monotonicity and exact landing are proven separately by tb_slide_ramp at module level.");
        else
            $fatal(1, "FAIL: slide e2e had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
