`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_uart_ui.sv · 串口屏人机交互层测试
//
// ⭐ 验证 `uart_ui.v` 的返回帧解析状态机：
//   ① 握手帧 0x88 + FF FF FF → hb_ready 置位
//   ② 触摸帧 0x65 + 控件ID + FF FF FF → 模式翻转 + mode_commit
//   ③ 数值帧 0x71 + 变量序 + 数值 + FF FF FF → 起始音落地 + base_commit
//   ④ 结束符严格三连（单个/两个 FF 不结束帧）
//   ⑤ 空闲归位（半帧后静默 → 回 IDLE + resync_cnt 自增）
//   ⑥ 非法返回码 → err_cnt 自增
//
// ⭐ 判据用「可观测现象」而非内部信号：全部走输出端口（K-106）。
// ⭐ 喂入方式：直接驱动 rx_done_i/rx_data_i（uart_ui 消费的是 uart_rx 的字节流，
//   不模拟完整串行波形 —— 串行层已被 tb_uart_rx 覆盖）。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_uart_ui;

    localparam integer CLK_HZ = 50000000;
    localparam integer BAUD   = 1000000;
    // ⭐ 一个字节时间 = CLK_HZ/BAUD = 50 个 clk。空闲归位阈值 GAP_BYTES=16 字节。
    //   这里用「远大于 16 字节时间」的静默来触发归位。
    localparam integer BYTE_CLK = CLK_HZ / BAUD;   // = 50

    reg  clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg        rst_n = 1'b0;
    reg        rx_done = 1'b0;
    reg  [7:0] rx_data = 8'h00;

    // tx 侧（本 tb 不真正驱动 uart_tx，只给静态握手信号）
    reg        tx_busy = 1'b0;
    reg        tx_done = 1'b0;

    wire        tx_start;
    wire [7:0]  tx_data;
    wire        mode;
    wire [6:0]  base_semi;
    wire        mode_commit;
    //  ⭐⭐ 2026-10-13：⭐ **外部模式翻转输入**（`mode_sw_req_i`，串口 `'A'` 走这条）✅
    //     🔴 **为什么补**：⭐ 上板实测"发 `A` 不回 `a`、模式也不变" ✅
    //        ⚠️ 而本 tb 原来**只测屏触摸那条路** ⇒ ⭐ `mode_sw_req_i` **零判据** ✅
    //        📌 与 `calib_cmd` 那条合起来才是**完整链路**：
    //           ⭐ `calib_cmd` 出脉冲（`tb_calib_cmd` 守）+ ⭐ `uart_ui` 翻转（本条守）✅
    reg         mode_sw = 1'b0;      // ⭐ 初值 0（⛔ 否则从 x 开始，判据会假红）
    wire        base_commit;
    //  ⭐⭐ 2026-10-15：⭐ 效果器从"留位恒 0"改成**运行时参数**（⭐ 见 `uart_ui.v` 的注释表）
    //     📌 所以这里不再有 `fx_en`/`fx_sel`，⭐ 换成 9 个参数 + 1 个提交脉冲 ✅
    wire [7:0]  fx_mask;
    wire [15:0] fx_gain;
    wire [15:0] fx_trim;
    wire [7:0]  fx_mix;
    wire [7:0]  fx_fb;
    wire [7:0]  fx_depth;
    wire [7:0]  fx_rate;
    wire [13:0] fx_dlylen;
    wire [10:0] fx_chorlen;
    wire        fx_commit;
    //  ⭐ 给"0xFF 契约"判据存旧值用（⭐ 见下方 g_ff_contract）✅
    reg  [7:0]  mask_before;
    wire        test_mode;
    wire [1:0]  test_mode_n;
    wire        test_mode_commit;
    wire [15:0] frame_cnt;
    wire [15:0] resync_cnt;
    wire [15:0] err_cnt;
    wire        hb_ready;

    integer errors = 0;
    //  ⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **判据条数改成【运行期计数】** ✅
    //  🔴 **为什么**：⭐ 原来汇总那行写死 `%0d checks", 28` —— ⚠️ 而实际 `chk()` 有
    //     **65 条** ⇒ ⭐ **"28" 是假的**，⛔ 而且它**永远不会随判据增减而变**
    //     ⇒ 🔴 下一个人看到 28 会以为只有 28 条判据在守（⭐ 这正是 `C88` 同族：
    //        "派生常量写死必然过时"）✅
    //  📌 修法：⭐ `chk()` 每次自增 ⇒ ⭐ 打印的数**必然等于实际执行条数** ✅
    integer nchecks = 0;

    task chk;
        input [8*110-1:0] name;
        input             cond;
        begin
            nchecks = nchecks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ⭐ 复位默认模式：0 = 指板 · 1 = 钢琴。
    //   📌 本 tb 用 **0 = 指板默认**（⭐ 与队友那侧的 tb 语义一致），
    //      而【交付默认】是 `top.v` 里的 1（钢琴）—— ⭐ 二者互不影响。
    localparam integer MODE_PIANO_DEFAULT = 0;

    uart_ui #(
        .CLK_HZ            (CLK_HZ),
        .BAUD              (BAUD),
        .GAP_BYTES         (16),
        .MODE_PIANO_DEFAULT(MODE_PIANO_DEFAULT)
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .rx_done_i    (rx_done),
        .rx_data_i    (rx_data),
        .tx_busy_i    (tx_busy),
        .tx_done_i    (tx_done),
        .tx_start_o   (tx_start),
        .tx_data_o    (tx_data),
        .mode_sw_req_i(mode_sw),      // ⭐ 2026-10-13：外部模式翻转（串口 'A'）
        .mode_o       (mode),
        .base_semi_o  (base_semi),
        .mode_commit_o(mode_commit),
        .base_commit_o(base_commit),
        .fx_mask_o    (fx_mask),
        .fx_gain_o    (fx_gain),
        .fx_trim_o    (fx_trim),
        .fx_mix_o     (fx_mix),
        .fx_fb_o      (fx_fb),
        .fx_depth_o   (fx_depth),
        .fx_rate_o    (fx_rate),
        .fx_dlylen_o  (fx_dlylen),
        .fx_chorlen_o (fx_chorlen),
        .fx_commit_o  (fx_commit),
        .test_mode_o  (test_mode),
        .test_mode_n_o(test_mode_n),
        .test_mode_commit_o(test_mode_commit),
        .frame_cnt_o  (frame_cnt),
        .resync_cnt_o (resync_cnt),
        .err_cnt_o    (err_cnt),
        .hb_ready_o   (hb_ready)
    );

    // ── 喂一个字节（单周期 rx_done 脉冲）────────────────────────────────────
    //   ⭐ rx_done 在 negedge 拉高、下一个 negedge 拉低 ⇒ 覆盖一个完整 posedge，
    //      DUT 在该 posedge 采样 rx_done=1 并用非阻塞更新输出。
    task feed;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(negedge clk);
            rx_done = 1'b0;
        end
    endtask

    // ── 喂完一个字节后，在「紧接的 posedge」抓输出 ──────────────────────────
    //   ⭐ commit 脉冲在 rx_done 采样那个 posedge 产生，持续一个周期。
    //     喂字节用的 feed() 停在 negedge，此时 commit 已更新为 1，
    //     用 @(posedge clk) 对齐到「commit 仍为高」的那一拍。
    task feed_capture;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(posedge clk);   // ⭐ DUT 采样 rx_done，本拍输出已更新
            @(negedge clk);
            rx_done = 1'b0;
        end
    endtask

    // ── 喂一帧 = 返回码 + 帧体 + FF FF FF ──────────────────────────────────
    //   ⭐ 最后一个 FF 用 feed_capture（在 posedge 抓输出后停在 negedge），
    //      使调用方在 feed_frame 返回后能立即读到 commit 脉冲（仍为高）。
    task feed_frame;
        input [7:0] retcode;
        input [7:0] body0;   // ⭐ 第一个帧体字节（控件ID/变量序），可为 0 表示"无帧体"
        input [7:0] body1;   // ⭐ 第二个帧体字节（数值），0 表示"无"
        begin
            feed(retcode);
            feed(body0);
            if (body1 != 8'h00) feed(body1);
            feed(8'hFF);
            feed(8'hFF);
            feed_capture(8'hFF);   // ⭐ 第 3 个 FF：帧结束，commit 在此产生
        end
    endtask

    //  ⭐⭐ 2026-10-15：⭐ **严格版发帧 —— `body1` 即使为 0 也照发** ✅
    //     🔴 **为什么需要它**：⭐ 上面 `feed_frame` 有 `if (body1 != 0) feed(body1)`
    //        ⇒ ⭐ **发不出"值 = 0"** ✗ 而对效果器来说 **0 是完全合法的值**
    //        （⭐ 例如"关掉颤音"= depth 0 · "全关"= mask 0）
    //        ⇒ ⚠️ 用 `feed_frame` 测效果器 ⇒ 🔴 **永远测不到 0 那一档** ✅
    task feed_frame_z;
        input [7:0] retcode;
        input [7:0] body0;
        input [7:0] body1;
        begin
            feed(retcode);
            feed(body0);
            feed(body1);           // ⭐ 无条件发（⭐ 含 0）
            feed(8'hFF);
            feed(8'hFF);
            feed_capture(8'hFF);
        end
    endtask

    // ── 静默 N 个 clk（用于触发空闲归位）───────────────────────────────────
    task silence;
        input integer nclk;
        integer i;
        begin
            for (i = 0; i < nclk; i = i + 1) @(negedge clk);
        end
    endtask

    integer i;

    initial begin
        $dumpfile("build/sim/tb_uart_ui/tb_uart_ui.vcd");
        $dumpvars(0, tb_uart_ui);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 复位基线
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐ 复位默认模式由 `MODE_PIANO_DEFAULT` 决定（⛔ 不是写死的"指板"）：
        //      0 = 指板 · 1 = 钢琴。top.v 目前传 1 ⇒ 默认钢琴。
        //   📌 判据必须**跟随该参数**，⛔ 不能写死为 0 ——
        //      否则一旦默认值变更就会假红（2026-09-27 实测 6 个 FAIL 就是这么来的）。
        chk("reset: mode=MODE_PIANO_DEFAULT (0=指板/1=钢琴)",
            mode === ((MODE_PIANO_DEFAULT != 0) ? 1'b1 : 1'b0));
        chk("reset: base_semi=0 (C4)", base_semi === 7'd0);
        chk("reset: hb_ready=0", hb_ready === 1'b0);
        chk("reset: 无 commit 脉冲", mode_commit === 1'b0 && base_commit === 1'b0);
        /*  ⭐⭐ 2026-10-15：⭐ 效果器复位值判据（⭐ 原来是"留位恒 0"）✅
         *  📌 **为什么必须改**：⭐ 效果器现在是**运行时参数** ⇒ ⭐ 复位值由
         *     `FX_*_DEF` 参数决定（⭐ `top.v` 传 `FX_*`，⭐ 本 tb 用模块默认）✅
         *  ⚠️ **判据要点**：⭐ 不能只查"是不是 0" —— 那样**任何值都过** ✗
         *     ⇒ ⭐ 必须**逐项对照参数默认值**（⭐ 非空洞）✅ */
        chk("reset: fx_mask = 默认（全关）",        fx_mask    === 8'd0);
        chk("reset: fx_gain = 默认 16384 (4.0)",    fx_gain    === 16'd16384);
        chk("reset: fx_trim = 默认 8192 (0.25)",    fx_trim    === 16'd8192);
        chk("reset: fx_mix = 默认 128",             fx_mix     === 8'd128);
        chk("reset: fx_fb = 默认 96",               fx_fb      === 8'd96);
        chk("reset: fx_depth = 默认 0（数值恒等）",  fx_depth   === 8'd0);
        chk("reset: fx_rate = 默认 7",              fx_rate    === 8'd7);
        chk("reset: fx_dlylen = 默认 8192（168ms）",fx_dlylen  === 14'd8192);
        chk("reset: fx_chorlen = 默认 736（15ms，⭐ 在 ×32 格点上）", fx_chorlen === 11'd736);
        chk("reset: 无 fx_commit 脉冲",             fx_commit  === 1'b0);
        chk("reset: test_mode 默认关", test_mode === 1'b0 && test_mode_n === 2'd0);

        // ═══════════════════════════════════════════════════════════════════
        // ② 握手帧：0x88 + FF FF FF → hb_ready 置位
        // ═══════════════════════════════════════════════════════════════════
        feed_frame(8'h88, 8'h00, 8'h00);
        @(negedge clk);
        chk("握手 0x88 -> hb_ready=1", hb_ready === 1'b1);
        chk("握手计入 frame_cnt", frame_cnt === 16'd1);
        chk("握手不改 mode", mode === ((MODE_PIANO_DEFAULT != 0) ? 1'b1 : 1'b0));

        // ═══════════════════════════════════════════════════════════════════
        // ③ 触摸帧：0x65 + 控件ID=0 + FF FF FF → 模式翻转 + mode_commit
        // ═══════════════════════════════════════════════════════════════════
        //   控件 0 = 模式切换（见 uart_ui 注释 + 决议清单 §B 第 7 项）
        //   ⭐ 判据 = "翻转到【相反】值"（⛔ 不是写死 =1）
        feed_frame(8'h65, 8'h00, 8'h00);
        chk("触摸控件0 -> mode 翻转 (=~默认)",
            mode === ((MODE_PIANO_DEFAULT != 0) ? 1'b0 : 1'b1));
        chk("mode_commit 单周期脉冲", mode_commit === 1'b1);
        @(negedge clk);
        chk("mode_commit 仅 1 拍（下一拍回落）", mode_commit === 1'b0);

        //   再点一次 → 翻回默认
        feed_frame(8'h65, 8'h00, 8'h00);
        @(negedge clk);
        chk("再次触摸 -> mode 翻回 (=默认)",
            mode === ((MODE_PIANO_DEFAULT != 0) ? 1'b1 : 1'b0));

        // ═══════════════════════════════════════════════════════════════════
        // ③b ⭐⭐ 2026-10-13：**外部模式翻转 `mode_sw_req_i`（串口 `'A'` 走这条）** ✅
        //
        //  🔴 **为什么必须补**：⭐ 上板实测"发 `A` 不回 `a`、模式也不变" ✅
        //     ⚠️ 而本 tb 原来**只测屏触摸那条路** ⇒ ⭐ `mode_sw_req_i` **零判据** ✅
        //  📌 与 `tb_calib_cmd` 那条合起来才是**完整链路**：
        //     ⭐ `calib_cmd` 出脉冲（那边守）+ ⭐ `uart_ui` 翻转（**本条守**）✅
        //  📌 语义要求与屏触摸**逐位一致**：⭐ 翻转 `mode_o` + ⭐ 发一拍 `mode_commit` ✅
        //     ⚠️ 区别：⭐ 它**不经过 UART**，⭐ 是一个**外部单周期脉冲** ✅
        // ═══════════════════════════════════════════════════════════════════
        begin : mode_sw_test
            reg m_before;
            m_before = mode;
            mode_sw = 1'b1;
            @(negedge clk);            // ⭐ 覆盖一个完整 posedge ⇒ DUT 采样到 =1
            chk("mode_sw_req_i -> mode 翻转（与屏触摸同一语义）", mode === ~m_before);
            chk("mode_sw_req_i -> mode_commit 出了脉冲", mode_commit === 1'b1);
            mode_sw = 1'b0;
            @(negedge clk);
            chk("mode_sw_req_i 拉低 -> mode_commit 回落", mode_commit === 1'b0);
            chk("mode_sw_req_i 拉低 -> mode 保持不变（不是电平敏感）", mode === ~m_before);
            //   ⭐ "切换"语义 ⇒ ⭐ **可连发**（与 `'B'`/`'K'`/`'W'` 同构 ✅）
            mode_sw = 1'b1;
            @(negedge clk);
            chk("mode_sw_req_i 可连发（第二次翻回）", mode === m_before);
            mode_sw = 1'b0;
            @(negedge clk);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ④ 数值帧：0x71 + 变量序=1 + 数值=0x18 + FF FF FF → 起始音落地
        // ═══════════════════════════════════════════════════════════════════
        //   变量 1 = 起始音（八度级）。数值 0x18=24 半音 → 高 2 个八度。
        feed_frame(8'h71, 8'h01, 8'h18);
        chk("数值帧 -> base_semi 落地 =12", base_semi === 7'd12);
        chk("base_commit 单周期脉冲", base_commit === 1'b1);
        @(negedge clk);
        chk("base_commit 仅 1 拍", base_commit === 1'b0);

        /*  ═══════════════════════════════════════════════════════════════════
         *  ④c ⭐⭐ 2026-10-15：⭐ **效果器参数（变量 0x10..0x18）** ✅
         *  ═══════════════════════════════════════════════════════════════════
         *  🔴 **为什么这条判据重要**：⭐ 效果器原来是**编译期常量** ⇒ 上板调不了 ✗
         *     ⭐ 现在改成运行时寄存器 ⇒ ⭐ **必须有一条判据证明"帧真的写进去了"** ✅
         *     ⚠️ 否则"参数没生效"和"效果器本身没声音"**分不清** ✗
         *
         *  ⭐ **非空洞设计**：⭐ 每一项都写一个**与默认值不同**的值，再断言它变了 ✅
         *     （⭐ 若只查"等于默认值" ⇒ 🔴 一个寄存器都没接上也照样绿 ✗）
         *  ⚠️ 用 `feed_frame_z`（⭐ 严格版）—— ⭐ 因为要测"值 = 0"这一档 ✅
         *  ═══════════════════════════════════════════════════════════════════ */

        //  ── 0x10 掩码：0 → 0x17（⭐ bit0/1/2 三个效果全开 + bit4 空转）──
        //     ⚠️ **bit4 不是颤音**（⭐ `fx_chain.v` 明写"bit4 空闲"；
        //        ⭐ 颤音级硬接常开、只由 `depth` 控制）⇒ ⭐ 掩码语义只用 bit0/1/2
        //        ⇒ ⭐ **真正的"全开" = `0x07`** ✅
        feed_frame_z(8'h71, 8'h10, 8'h17);
        chk("fx 0x10: mask 0x00 -> 0x17（失真+合唱+延迟全开，⭐ bit4 空转）",
            fx_mask === 8'h17);
        chk("fx 0x10: fx_commit 单周期脉冲", fx_commit === 1'b1);
        @(negedge clk);
        chk("fx 0x10: fx_commit 仅 1 拍", fx_commit === 1'b0);

        //  ── 0x11 失真增益：⭐ 字节 ×256 ⇒ Q4.12（⭐ 2026-10-15 由 ×128 改 ×256）──
        //     ⭐ 值 32 ⇒ 8192 = 2.0（⭐ 与默认 4.0 不同 ⇒ 能区分）✅
        feed_frame_z(8'h71, 8'h11, 8'd32);
        chk("fx 0x11: gain 值32 -> 8192 (Q4.12 = 2.0)", fx_gain === 16'd8192);
        //     ⭐ 值 64 ⇒ 16384 = 4.0（⭐ 回到默认值，⭐ 证明换算是对的）
        feed_frame_z(8'h71, 8'h11, 8'd64);
        chk("fx 0x11: gain 值64 -> 16384 (Q4.12 = 4.0)", fx_gain === 16'd16384);
        //     ⭐ 值 254 ⇒ 65024（⭐ 上界）
        //     🔴 **为什么不是 255**：⭐ `0xFF` 是**帧尾标记**（⭐ 3 连结束）
        //        ⇒ ⭐ `uart_ui` 在 `S_BODY` 里看到 `0xFF` **不计入 `body_len`**
        //        ⇒ 🔴 **`val_q` 拿不到它** ⇒ ⭐ **`0xFF` 无法作为【数据值】传输** ✅
        //     📌 **这是 TJC 协议的固有约束**（⛔ 不是我实现的问题）——
        //        屏侧协议把 `FF FF FF` 保留为帧结束符 ✅
        //     ⭐ **实用影响**：⭐ 效果器掩码只用到 bit 0/1/2/4 ⇒ 最大 `0x17`
        //        ⇒ ⛔ **永远不需要 0xFF** ✅
        feed_frame_z(8'h71, 8'h11, 8'd254);
        chk("fx 0x11: gain 值254 -> 65024（上界）", fx_gain === 16'd65024);

        //  ── 0x12 失真补偿：值 32 ⇒ 8192 = 0.25（默认）· 值 128 ⇒ 32768 = 1.0 ──
        feed_frame_z(8'h71, 8'h12, 8'd128);
        chk("fx 0x12: trim 值128 -> 32768 (Q1.15 = 1.0)", fx_trim === 16'd32768);

        //  ── 0x13 / 0x14：直传（Q0.8）──
        feed_frame_z(8'h71, 8'h13, 8'd200);
        chk("fx 0x13: mix 直传 200", fx_mix === 8'd200);
        feed_frame_z(8'h71, 8'h14, 8'd180);
        chk("fx 0x14: fb 直传 180", fx_fb === 8'd180);

        //  ── 0x15 颤音深度：⭐ 关键 —— 0 表示"数值恒等"（⭐ 旁路的依据）──
        feed_frame_z(8'h71, 8'h15, 8'd96);
        chk("fx 0x15: depth 0 -> 96（颤音开）", fx_depth === 8'd96);
        feed_frame_z(8'h71, 8'h15, 8'd0);
        chk("fx 0x15: depth 回到 0（⭐ 数值恒等，⭐ 这条就是旁路判据）",
            fx_depth === 8'd0);
        feed_frame_z(8'h71, 8'h16, 8'd30);
        chk("fx 0x16: rate 直传 30", fx_rate === 8'd30);

        //  ── 0x17 延迟长度：值 ×128 采样；⭐ 且超 127 要饱和到 16384 ──
        feed_frame_z(8'h71, 8'h17, 8'd64);
        chk("fx 0x17: dlylen 值64 -> 8192 采样（168 ms）", fx_dlylen === 14'd8192);
        feed_frame_z(8'h71, 8'h17, 8'd127);
        chk("fx 0x17: dlylen 值127 -> 16256 采样", fx_dlylen === 14'd16256);
        feed_frame_z(8'h71, 8'h17, 8'd200);
        //  🔴 2026-10-15 修：⭐ 原期望值 `14'd16384` 与 RTL 是【同一个被截断成 0 的字面量】
        //     ⇒ `0 === 0` 恒真 ⇒ 判据永远绿、永远不可能红（⭐ 假绿）。
        //     正确上限 = DEPTH-1 = **16383**（⭐ 端口只有 14 位，2^14 根本装不下）。
        chk("fx 0x17: dlylen 值200 -> 饱和到 16383（= DEPTH-1，⛔ 不是 2^14）", fx_dlylen === 14'd16383);

        //  ── 0x18 合唱长度：值 ×32 采样；⭐ 且超 63 要饱和到 2048 ──
        feed_frame_z(8'h71, 8'h18, 8'd23);
        chk("fx 0x18: chorlen 值23 -> 736 采样（15 ms）", fx_chorlen === 11'd736);
        feed_frame_z(8'h71, 8'h18, 8'd63);
        chk("fx 0x18: chorlen 值63 -> 2016 采样", fx_chorlen === 11'd2016);
        feed_frame_z(8'h71, 8'h18, 8'd200);
        //  🔴 2026-10-15 修：同上 —— 原期望值 `11'd2048` 也是 0。正确上限 = **2047**。
        chk("fx 0x18: chorlen 值200 -> 饱和到 2047（= DEPTH-1，⛔ 不是 2^11）", fx_chorlen === 11'd2047);

        //  ── ⭐ 负向：⭐ 无关的变量序号不许碰效果器 ──
        feed_frame_z(8'h71, 8'h7F, 8'hAA);
        chk("fx 负向: 变量 0x7F 不影响任何效果器参数",
            fx_mask === 8'h17 && fx_gain === 16'd65024 && fx_depth === 8'd0);

        /*  ⭐⭐ 2026-10-15：⭐ **`0xFF` 不能作为数据值的【行为契约】** ✅
         *  ===========================================================================
         *  🔴 **为什么要专门写一条**：⭐ 我第一版判据就栽在这 ——
         *     用 `feed_frame_z(..., 8'hFF)` 想把掩码设成"全开"，
         *     🔴 **它静默不生效**（⭐ `val_q` 根本没被写）⇒ ⭐ 判据红 ✗
         *  📌 **根因**：⭐ 帧体里出现 `0xFF` ⇒ 被当成**帧尾计数** ⇒ ⛔ 不计入 `body_len`
         *     ⇒ ⭐ **`0xFF` 永远到不了 `val_q`** ✅
         *  ⚠️ **这是协议固有约束**（⭐ TJC 用 `FF FF FF` 做帧结束符）
         *     ⇒ ⛔ **不是能修的 bug** ⇒ ⭐ 只能**写进契约**，⛔ 不能让下一个人再踩 ✅
         *  ⭐ **判据**：⭐ 发一个 `val = 0xFF` 的帧 ⇒ ⭐ 目标寄存器**必须不变** ✅
         *     📌 若哪天有人"修好了"它 ⇒ ⭐ 这条会红 ⇒ ⭐ **那时再更新契约** ✅ */
        begin : g_ff_contract
            mask_before = fx_mask;
            //  🔴 **2026-10-15（清道夫 SWEEPER）修**：⭐ 原来这一行是
            //     `feed_frame_z(8'h71, 8'h10, 8'hFF)` —— ⚠️ 而 `feed_frame_z` 的
            //     `body1` 是**无条件发**的 ⇒ ⭐ 实际发出 **6 字节 / 4 个 `0xFF`**：
            //        · ⭐ 前 3 个 `0xFF` 结束帧（⭐ `body_len` 只有 1 < 2 ⇒ ⛔ 不落地 ✅）
            //        · 🔴 **第 4 个 `0xFF` 落进 `S_IDLE`** ⇒ ⭐ `uart_ui.v` 把它判成
            //          "该是返回码却不是" ⇒ 🔴 **`err_cnt` 自增 1** ✗
            //     ⇒ ⭐ 后果：⭐ 下面 ⑥ 的 `err_cnt > 0` **恒真**（⭐ 假绿）✅
            //     ⇒ ✅ 现在**手写 5 个字节**（⭐ 恰好 3 个 `0xFF` 收尾），⛔ 不多发 ✅
            feed(8'h71);
            feed(8'h10);
            feed(8'hFF);
            feed(8'hFF);
            feed_capture(8'hFF);   // ⭐ 第 3 个 FF：帧结束（body_len=1 ⇒ ⛔ 不落地）
            chk("fx 契约: val=0xFF 是帧尾标记 => 寄存器【不变】（协议固有约束）",
                fx_mask === mask_before);
            chk("fx 契约: 且不产生 fx_commit 脉冲（⭐ 帧根本没被当成数据帧落地）",
                fx_commit === 1'b0);
        end
        //  ⭐ 但 `0xFE`（差一位）是**合法数据** ⇒ ⭐ 证明上一条不是"帧整体坏了"
        feed_frame_z(8'h71, 8'h10, 8'hFE);
        chk("fx 契约 非空洞: 0xFE 是合法数据 => 掩码变成 0xFE",
            fx_mask === 8'hFE);
        chk("fx 契约 非空洞: 且 fx_commit 有脉冲", fx_commit === 1'b1);
        @(negedge clk);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **掩码必须能【清零】** ✅
        //  🔴 **为什么必须补**：⭐ 原来**没有任何一条帧写过 `mask = 0`** ——
        //     碰 `V_MASK` 的只有 `0x17` / `0xFF`（被拒）/ `0xFE`
        //     ⇒ 🔴 **"只能置位、不能清零"这一类 bug 一条判据都抓不到** ✗
        //     （⭐ `0xFE` 只清了 bit0，⭐ 而 `0x00` 才是"全关"）
        //  ⭐ 判据：⭐ 发 `mask = 0` ⇒ ⭐ `fx_mask` 必须**真的回到 0** ✅
        //  ═══════════════════════════════════════════════════════════════════
        feed_frame_z(8'h71, 8'h10, 8'd0);
        chk("fx 0x10: mask 0xFE -> 0x00（⭐ 能清零，⛔ 不是只能置位）",
            fx_mask === 8'd0);
        @(negedge clk);

        /*  ⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **帧体首字节的 bit7 不许被截断** ✅
         *  ===========================================================================
         *  🔴 **根因**：⭐ `uart_ui.v` 原来写 `body_q <= rx_data_i[6:0]` —— ⚠️ 而
         *     `body_q` 只有 **7 位** ⇒ 🔴 **最高位被静默丢掉**：
         *        · `0x90` ⇒ 变成 `0x10` ⇒ ⭐ **被当成 `V_MASK`** ⇒ 🔴 **静默写 `fx_mask`**
         *        · `0x91` ⇒ 变成 `0x11`（gain）· `0x98` ⇒ `0x18`（chorlen）…
         *        · `0x80` ⇒ 变成 `0`（⭐ 触摸控件 0）⇒ 🔴 **翻转模式**（⭐ 更严重）
         *     ⇒ ⭐ **这不是"发不进去"，而是"发到别的寄存器上去了"** ✅
         *  ⭐ **修法**：⭐ `body_q` 扩到 **8 位**、比较也按 8 位 ⇒ ⭐ `0x90` 不再别名成
         *     `0x10`，而是落进"未知变量序号"⇒ ⭐ 与 `0x7F` 同处置（⭐ 静默丢弃）✅
         *     📌 **为什么选"扩位"而不是"显式拒绝 `rx_data_i[7]`"**：
         *        ⭐ ① 缺陷本身就是那个 `[6:0]` 切片 ⇒ ⭐ 去掉它是**最小改动**；
         *        ⭐ ② 显式拒绝若要**可观测**就得再加一个计数器（⭐ 否则仍是静默），
         *           ⚠️ 那会牵动端口表与 `top.v` 接线 ⇒ ⭐ 超出本任务范围；
         *        ⭐ ③ 扩位后 `0x80`（触摸）与 `0x90`（数值）**都**不再别名 ⇒
         *           ⭐ **两条通路一起修好**，⛔ 不用分别打补丁 ✅
         *        ⚠️ **保守性**：⭐ 真实 TJC 的 `0x71` 值可能是 **4 字节小端**
         *           （⭐ 见 `files/20-代码/审计-top集成与时钟复位-20260928.md:239`）——
         *           ⭐ 但被别名的是**变量序号那一个字节**，⛔ 与值域宽度无关
         *           ⇒ ⭐ 扩位对 4 字节帧同样正确 ✅
         *  ⭐ **判据（⭐ 修前必红）**：⭐ 发 `71 90 05 FF FF FF` ⇒
         *     ⭐ `fx_mask` **必须不变**（⭐ 修前会静默变成 5）✅
         *  =========================================================================== */
        begin : body_q_hi_bit
            reg [7:0] m_hi_before;
            reg       mode_hi_before;
            m_hi_before   = fx_mask;
            mode_hi_before = mode;
            feed_frame_z(8'h71, 8'h90, 8'd5);   // ⭐ 伪 0x10（bit7 置位）
            chk("fx 0x90: 序号 bit7 置位 ⇒ ⛔ 不许别名成 0x10（修前静默写 mask=5）",
                fx_mask === m_hi_before);
            //  ⭐ 触摸侧同一条根因：`0x80` 不许别名成"控件 0"（⭐ 那会翻转模式）
            feed_frame(8'h65, 8'h80, 8'h00);    // ⭐ 伪控件 0（bit7 置位）
            chk("touch 0x80: 控件号 bit7 置位 ⇒ ⛔ 不许别名成控件 0（修前翻转模式）",
                mode === mode_hi_before);
            chk("touch 0x80: 且不发 mode_commit 脉冲", mode_commit === 1'b0);
        end
        @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ④b A1 Test Mode 切档：触摸控件 2 → 关→4→8→16→32→关 循环
        // ═══════════════════════════════════════════════════════════════════
        //   控件 2 = Test Mode 切档（A1 UI 开关）
        feed_frame(8'h65, 8'h02, 8'h00);
        chk("控件2 第1次 -> test_mode=1, n=00(4)", test_mode === 1'b1 && test_mode_n === 2'b00);
        chk("test_mode_commit 单周期脉冲", test_mode_commit === 1'b1);
        @(negedge clk);
        chk("test_mode_commit 仅 1 拍", test_mode_commit === 1'b0);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第2次 -> n=01(8)", test_mode === 1'b1 && test_mode_n === 2'b01);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第3次 -> n=10(16)", test_mode === 1'b1 && test_mode_n === 2'b10);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第4次 -> n=11(32)", test_mode === 1'b1 && test_mode_n === 2'b11);

        feed_frame(8'h65, 8'h02, 8'h00);
        @(negedge clk);
        chk("控件2 第5次 -> 32 回到关", test_mode === 1'b0 && test_mode_n === 2'b00);

        // ═══════════════════════════════════════════════════════════════════
        // ⑤ 结束符严格三连：两连 FF 不结束帧
        // ═══════════════════════════════════════════════════════════════════
        //   发 0x65 + 控件0 + FF + FF（只有两个 FF）+ 一个非 FF 数据字节
        //   ⇒ 不应触发 mode 翻转（帧未结束）
        feed(8'h65);
        feed(8'h00);
        feed(8'hFF);
        feed(8'hFF);        // ⭐ 只有两个 FF，帧未结束
        feed(8'h00);        // ⭐ 打断 FF 连续（当作数据）
        @(negedge clk);
        chk("两连 FF 不结束帧（mode 未变）",
            mode === ((MODE_PIANO_DEFAULT != 0) ? 1'b1 : 1'b0));

        //   现在补齐第 3 个 FF 之外的剩余：先归位，避免残留半帧影响后续
        silence(BYTE_CLK * 40);   // ⭐ 远大于 16 字节时间 ⇒ 归位
        @(negedge clk);
        chk("半帧静默 -> 空闲归位(resync_cnt>0)", resync_cnt > 16'd0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ 非法返回码 → err_cnt 自增，不影响状态
        // ═══════════════════════════════════════════════════════════════════
        begin : err_cnt_test
            reg [15:0] e_before;
            e_before = err_cnt;      // ⭐ 先存旧值
            feed(8'h42);             // ⭐ 'B'，非法返回码（⭐ 单拍 ⇒ 恰好自增 1）
            @(negedge clk);
            //  🔴 **2026-10-15（清道夫 SWEEPER）修**：⭐ 原来是 `err_cnt > 16'd0`
            //     —— ⚠️ **恒真**：⭐ 上面 `g_ff_contract` 原来多发了一个游离 `0xFF`
            //        落进 `S_IDLE` ⇒ 🔴 **`err_cnt` 早就 ≥ 1 了**
            //     ⇒ 🔴 这条判据**证明不了"非法返回码会自增"**（⭐ 删掉 `S_IDLE` 的
            //        `err_cnt` 自增逻辑它照样绿）✗
            //  ⭐ 现在：⭐ **存旧值 + 断言恰好 +1** ⇒ ⭐ 多一次 / 少一次都会红 ✅
            chk("非法返回码 -> err_cnt 恰好自增 1（⛔ 不是恒真的 >0）",
                err_cnt === e_before + 16'd1);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ 完整回归：再走一遍握手+触摸+数值，确认状态机可复用
        // ═══════════════════════════════════════════════════════════════════
        feed_frame(8'h88, 8'h00, 8'h00);
        feed_frame(8'h65, 8'h00, 8'h00);   // mode 翻转一次
        @(negedge clk);
        chk("回归: 再握手+触摸 mode=~默认",
            mode === ((MODE_PIANO_DEFAULT != 0) ? 1'b0 : 1'b1));
        chk("回归: frame_cnt 累计", frame_cnt >= 16'd4);

        // ═══════════════════════════════════════════════════════════════════
        // 汇总
        // ═══════════════════════════════════════════════════════════════════
        if (errors == 0) begin
            //  ⭐ 运行期计数（⭐ ⛔ 不再写死 28）✅
            $display("PASS: tb_uart_ui (%0d checks)", nchecks);
        end else begin
            $display("FAIL: tb_uart_ui errors=%0d", errors);
        end
        $finish;
    end

endmodule

`default_nettype wire
