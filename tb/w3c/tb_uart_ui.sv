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
//   ⑦ ⭐ 2026-10-29 v2：握手后 **22 字段全量回显**（Page0）+ 变化驱动单帧回显
//      + hb 门控 + EC11 参数写回 + tx_busy 流控（详见 §⑧）
//
// ⭐ 判据用「可观测现象」而非内部信号：全部走输出端口（K-106）。
// ⭐ 喂入方式：直接驱动 rx_done_i/rx_data_i（uart_ui 消费的是 uart_rx 的字节流，
//   不模拟完整串行波形 —— 串行层已被 tb_uart_rx 覆盖）。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_uart_ui;

    localparam integer CLK_HZ = 50000000;
    localparam integer BAUD   = 115200;
    // ⭐ 一个字节时间 = CLK_HZ/BAUD ≈ 434 个 clk（⭐ 与真实交付档 115200 一致，2026-10-28）。
    //   空闲归位阈值 GAP_BYTES=16 字节，这里用「远大于 16 字节时间」的静默来触发归位。
    localparam integer BYTE_CLK = CLK_HZ / BAUD;   // ≈ 434

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
    //  ⭐⭐ 2026-10-30：⭐ 触摸控件 3 = 音色循环请求（⭐ 屏按钮闭环）
    wire        timbre_req;
    //  ⭐⭐ 2026-10-31：⭐ 触摸控件 4..14 = page0 控制面板 11 个按钮脉冲
    //     📌 打包成向量 `panel_vec`（低位在前）⇒ 判据可以一条 chk 验全零/独热 ✅
    wire        slide_req, drum_req, kd_req, trans_up_req, trans_dn_req;
    wire        loop_rec_req, loop_play_req, loop_clear_req, gear_req;
    wire        bpm_up_req, bpm_dn_req;
    wire [10:0] panel_vec = {bpm_dn_req, bpm_up_req, gear_req,
                             loop_clear_req, loop_play_req, loop_rec_req,
                             trans_dn_req, trans_up_req, kd_req,
                             drum_req, slide_req};   // ⭐ bit10..bit0 = 控件14..4
    wire [15:0] frame_cnt;
    wire [15:0] resync_cnt;
    wire [15:0] err_cnt;
    wire        hb_ready;

    //  ⭐⭐ 2026-10-29：⭐ Page0 状态回显输入（v2 FSM 的 22 字段来源）
    //     ⭐ 初值全部 = 各信号的复位值（⭐ 与 DUT 镜像复位值一致 ⇒ 握手沿
    //        不会把初值当"变化"多挂起 ⇒ 帧数判据不假红）✅
    reg  [7:0]  st_bpm    = 8'd120;   // ⭐ play_seq.bpm_o 复位 120
    reg  [1:0]  st_timbre = 2'd0;
    reg  [4:0]  st_trans  = 5'd0;
    reg         st_slide  = 1'b0;
    //     {on, pattern}（⭐ 2026-10-31 鼓机五态：复位=开+Pattern I，与镜像
    //      复位值 3'b100 一致 ⇒ 零伪帧）
    reg  [2:0]  st_drum   = 3'b100;
    reg         st_kd     = 1'b0;
    reg  [1:0]  st_loop   = 2'd0;
    reg  [6:0]  st_vol    = 7'd0;
    reg         st_pedal  = 1'b0;
    reg  [1:0]  st_gear   = 2'd1;     // ⭐ fader_gear 复位档 1
    reg  [1:0]  st_scope  = 2'd0;
    reg  [6:0]  st_pvib   = 7'd0;
    reg  [6:0]  st_vvib   = 7'd0;
    reg  [2:0]  st_fxmask = 3'd0;
    //  ⭐⭐ 2026-10-31：《控件位置清单》新输入（⭐ 初值 = DUT 镜像复位值 ⇒ 零伪帧）
    reg  [11:0] st_prate  = 12'd0;   // ⭐ 音高颤音速率 raw（→ t_pr 1.0Hz / j_pr 0）
    reg  [7:0]  st_vrate  = 8'd7;    // ⭐ 音量颤音速率（= FX_RATE_DEF → t_vr 5.2Hz / j_vr 2）
    reg         beat      = 1'b0;    // ⭐ 节拍脉冲（p_bpm 橙点每拍翻转）
    wire        uplink_sw;           // ⭐ b_uplink 实时上行开关（DUT 输出，复位=开启）
    //  ⭐⭐ 2026-10-29：⭐ EC11 参数旋钮【写回】（缺口4）
    reg  [2:0]  par_sel   = 3'd0;
    reg         par_up    = 1'b0;
    reg         par_dn    = 1'b0;

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
        .MODE_PIANO_DEFAULT(MODE_PIANO_DEFAULT),
        //  ⭐⭐ 2026-10-29：⭐ 心跳周期缩到 1ms（⭐ 交付 1000ms）——
        //     ⭐ 既有判据全部在 <380µs 内完成 ⇒ 心跳不会插进旧 burst（零回归）；
        //     ⭐ 新增 ⑫ 段在 ~1ms/2ms 处等两拍心跳（≪ 20ms 看门狗 ✅）
        .HB_MS             (1)
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
        .timbre_req_o  (timbre_req),   // ⭐ 2026-10-30：控件 3 音色循环脉冲
        //  ⭐⭐ 2026-10-31：控件 4..14 = page0 控制面板 11 个按钮脉冲
        .slide_req_o     (slide_req),
        .drum_req_o      (drum_req),
        .kd_req_o        (kd_req),
        .trans_up_req_o  (trans_up_req),
        .trans_dn_req_o  (trans_dn_req),
        .loop_rec_req_o  (loop_rec_req),
        .loop_play_req_o (loop_play_req),
        .loop_clear_req_o(loop_clear_req),
        .gear_req_o      (gear_req),
        .bpm_up_req_o    (bpm_up_req),
        .bpm_dn_req_o    (bpm_dn_req),
        .frame_cnt_o  (frame_cnt),
        .resync_cnt_o (resync_cnt),
        .err_cnt_o    (err_cnt),
        .hb_ready_o   (hb_ready),
        //  ⭐⭐ 2026-10-29：Page0 状态回显输入（v2 FSM 22 字段）
        .st_bpm_i     (st_bpm),
        .st_timbre_i  (st_timbre),
        .st_trans_i   (st_trans),
        .st_slide_i   (st_slide),
        .st_drum_i    (st_drum),
        .st_kd_i      (st_kd),
        .st_loop_i    (st_loop),
        .st_vol_i     (st_vol),
        .st_pedal_i   (st_pedal),
        .st_gear_i    (st_gear),
        .st_scope_i   (st_scope),
        .st_pvib_i    (st_pvib),
        .st_vvib_i    (st_vvib),
        .st_fxmask_i  (st_fxmask),
        //  ⭐⭐ 2026-10-31：《控件位置清单》新端口
        .st_prate_i   (st_prate),
        .st_vrate_i   (st_vrate),
        .beat_i       (beat),
        .uplink_sw_o  (uplink_sw),
        //  ⭐⭐ 2026-10-29：EC11 参数旋钮写回（缺口4）
        .par_sel_i    (par_sel),
        .par_up_i     (par_up),
        .par_dn_i     (par_dn)
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

    // ═══════════════════════════════════════════════════════════════════════
    // 状态回显抓取辅助（⭐ 2026-10-28 新增，⭐ 模块级 task，供 §⑧ 用）
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 回显帧是「背靠背」连续推的（握手后 t0→t1→t2 三帧连发），
    //      且回显启动时机与 testbench 的 @(negedge) **异步** ⇒ 逐帧抓会漏帧头。
    //   ⇒ ⭐ 采用「burst 抓取」：一次性把「直到空闲」的所有字节抓进 cap[]，
    //      再按已知帧长切片核对（⭐ 每帧都以 FF FF FF 结尾 ⇒ 边界确定）。
    integer cap_n;               // ⭐ 抓到的总字节数
    //  ⭐⭐ 2026-10-29：⭐ v2 回显是【22 字段全量 burst】（握手后最长 666 字节）
    //  ⭐⭐ 2026-10-29 晚：⭐ §八 收口后全量 = 47 字段 burst
    //  ⭐⭐ 2026-10-31：⭐ 《控件位置清单》落地后全量 = **56 字段 burst**
    //     （⭐ 最长 ⑬-A = 1293 字节）⇒ 抓取缓冲 2048 仍够 ✅
    reg [7:0] cap [0:2047];
    integer bi;
    integer off;                 // ⭐ expect_frame 链式游标（burst 内逐帧推进）
    integer flen;                // ⭐ expect_frame 的帧长输出

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-10-29：中文词表（UTF-8，⭐ 与 uart_ui.v 的 localparam 逐字节一致）
    //   📌 **自然位宽**（⭐ 与 RTL 的 120 位统一宽度不同）——
    //      ⭐ 本 tb 要把词【拼进 body 期望串】⇒ 中间不许有零填充 ⇒ 每词按
    //        实际字节数定宽（⭐ 拼接后位宽之和 = body 字节数 × 8 ✅）
    // ═══════════════════════════════════════════════════════════════════
    localparam [95:0]  W_ZHIBAN_MOSHI     = {8'hE6,8'h8C,8'h87,8'hE6,8'h9D,8'hBF,8'hE6,8'hA8,8'hA1,8'hE5,8'hBC,8'h8F}; // 指板模式
    localparam [95:0]  W_GANGQIN_MOSHI    = {8'hE9,8'h92,8'hA2,8'hE7,8'h90,8'hB4,8'hE6,8'hA8,8'hA1,8'hE5,8'hBC,8'h8F}; // 钢琴模式
    localparam [71:0]  W_JIZHUNYIN        = {8'hE5,8'h9F,8'hBA,8'hE5,8'h87,8'h86,8'hE9,8'h9F,8'hB3};                    // 基准音
    localparam [71:0]  W_ZUIDIYIN         = {8'hE6,8'h9C,8'h80,8'hE4,8'hBD,8'h8E,8'hE9,8'h9F,8'hB3};                    // 最低音
    localparam [47:0]  W_YUANDIAO         = {8'hE5,8'h8E,8'h9F,8'hE8,8'hB0,8'h83};                                      // 原调
    localparam [47:0]  W_GUANBI           = {8'hE5,8'h85,8'hB3,8'hE9,8'h97,8'hAD};                                      // 关闭
    localparam [23:0]  W_GUAN             = {8'hE5,8'h85,8'hB3};                                                         // 关
    localparam [23:0]  W_KAI              = {8'hE5,8'hBC,8'h80};                                                         // 开
    localparam [47:0]  W_KONGXIAN         = {8'hE7,8'hA9,8'hBA,8'hE9,8'h97,8'hB2};                                      // 空闲
    localparam [95:0]  W_JIANPAN_DAGU     = {8'hE9,8'h94,8'hAE,8'hE7,8'h9B,8'h98,8'hE6,8'h89,8'h93,8'hE9,8'hBC,8'h93};   // 键盘打鼓
    localparam [95:0]  W_YINFU_YANZOU     = {8'hE9,8'h9F,8'hB3,8'hE7,8'hAC,8'hA6,8'hE6,8'hBC,8'h94,8'hE5,8'hA5,8'h8F};   // 音符演奏
    localparam [71:0]  W_ZHU_YINLIANG     = {8'hE4,8'hB8,8'hBB,8'hE9,8'h9F,8'hB3,8'hE9,8'h87,8'h8F};                    // 主音量
    localparam [95:0]  W_YANYIN_TABAN     = {8'hE5,8'hBB,8'hB6,8'hE9,8'h9F,8'hB3,8'hE8,8'hB8,8'hA9,8'hE6,8'h9D,8'hBF};   // 延音踏板
    localparam [95:0]  W_CAIXIA_SHINENG   = {8'hE8,8'hB8,8'hA9,8'hE4,8'hB8,8'h8B,8'hE4,8'hBD,8'hBF,8'hE8,8'h83,8'hBD};   // 踩下使能
    localparam [47:0]  W_SONGKAI          = {8'hE6,8'h9D,8'hBE,8'hE5,8'hBC,8'h80};                                      // 松开
    localparam [95:0]  W_TUIZI_KONGZHI    = {8'hE6,8'h8E,8'hA8,8'hE5,8'hAD,8'h90,8'hE6,8'h8E,8'hA7,8'hE5,8'h88,8'hB6};   // 推子控制
    localparam [23:0]  W_DANG             = {8'hE6,8'hA1,8'hA3};                                                         // 档
    localparam [95:0]  W_YINGAO_CHANYIN   = {8'hE9,8'h9F,8'hB3,8'hE9,8'hAB,8'h98,8'hE9,8'hA2,8'hA4,8'hE9,8'h9F,8'hB3};   // 音高颤音
    localparam [95:0]  W_YINLIANG_CHANYIN = {8'hE9,8'h9F,8'hB3,8'hE9,8'h87,8'h8F,8'hE9,8'hA2,8'hA4,8'hE9,8'h9F,8'hB3};   // 音量颤音
    localparam [119:0] W_SHISHI_SHIBOQI   = {8'hE5,8'hAE,8'h9E,8'hE6,8'h97,8'hB6,8'hE7,8'hA4,8'hBA,8'hE6,8'hB3,8'hA2,8'hE5,8'h99,8'hA8}; // 实时示波器
    localparam [95:0]  W_BOXING_XIANSHI   = {8'hE6,8'hB3,8'hA2,8'hE5,8'hBD,8'hA1,8'hE6,8'h98,8'hBE,8'hE7,8'hA4,8'hBA};   // 波形显示
    localparam [47:0]  W_SHIZHEN          = {8'hE5,8'hA4,8'hB1,8'hE7,8'h9C,8'h9F};                                      // 失真
    localparam [47:0]  W_HECHANG          = {8'hE5,8'h90,8'h88,8'hE5,8'h94,8'hB1};                                      // 合唱
    localparam [47:0]  W_YANCHI           = {8'hE5,8'hBB,8'hB6,8'hE8,8'hBF,8'h9F};                                      // 延迟
    // ── ⭐⭐ 2026-10-31：卡片 B/D 新词（UTF-8，⭐ 与 uart_ui.v 词表逐字节一致）──
    localparam [47:0]  W_DAGU             = {8'hE6,8'h89,8'h93,8'hE9,8'hBC,8'h93};                                      // 打鼓
    localparam [47:0]  W_KAIQI            = {8'hE5,8'hBC,8'h80,8'hE5,8'h90,8'hAF};                                      // 开启
    localparam [95:0]  W_JIANWEI_DAGU     = {8'hE9,8'h94,8'hAE,8'hE4,8'hBD,8'h8D,8'hE6,8'h89,8'h93,8'hE9,8'hBC,8'h93};  // 键位打鼓
    localparam [95:0]  W_SHISHI_SHANGXING = {8'hE5,8'hAE,8'h9E,8'hE6,8'h97,8'hB6,8'hE4,8'hB8,8'h8A,8'hE8,8'hA1,8'h8C};  // 实时上行
    // ── ⭐⭐ 2026-10-29 晚：§八 收口新增词（UTF-8，⭐ 与 uart_ui.v 词表逐字节一致）──
    localparam [23:0]  W_DOT              = {8'hE2,8'h97,8'h8F};                                                          // ●
    localparam [23:0]  W_PLAY             = {8'hE2,8'h96,8'hBA};                                                          // ►（⭐ 2026-10-30 回放态前缀，对齐终稿速查表）
    localparam [119:0] W_XUNHUAN_LUYIN    = {8'hE5,8'hBE,8'hAA,8'hE7,8'h8E,8'hAF,8'hE5,8'hBD,8'h95,8'hE9,8'h9F,8'hB3,8'hE4,8'hB8,8'hAD}; // 循环录音中
    localparam [119:0] W_XUNHUAN_HUIFANG  = {8'hE5,8'hBE,8'hAA,8'hE7,8'h8E,8'hAF,8'hE5,8'h9B,8'h9E,8'hE6,8'h94,8'hBE,8'hE4,8'hB8,8'hAD}; // 循环回放中
    localparam [47:0]  W_ZENGYI           = {8'hE5,8'hA2,8'h9E,8'hE7,8'h9B,8'h8A};                                       // 增益
    localparam [47:0]  W_BUCHANG          = {8'hE8,8'hA1,8'hA5,8'hE5,8'h81,8'hBF};                                       // 补偿
    localparam [47:0]  W_HUNHE            = {8'hE6,8'hB7,8'hB7,8'hE5,8'h90,8'h88};                                       // 混合
    localparam [47:0]  W_FANKUI           = {8'hE5,8'h8F,8'h8D,8'hE9,8'hA6,8'h88};                                       // 反馈
    localparam [47:0]  W_SHENDU           = {8'hE6,8'hB7,8'hB1,8'hE5,8'hBA,8'hA6};                                       // 深度
    localparam [47:0]  W_SULU             = {8'hE9,8'h80,8'h9F,8'hE7,8'h8E,8'h87};                                       // 速率
    localparam [95:0]  W_YANCHI_CD        = {8'hE5,8'hBB,8'hB6,8'hE8,8'hBF,8'h9F,8'hE9,8'h95,8'hBF,8'hE5,8'hBA,8'hA6}; // 延迟长度
    localparam [95:0]  W_HECHANG_CD       = {8'hE5,8'h90,8'h88,8'hE5,8'h94,8'hB1,8'hE9,8'h95,8'hBF,8'hE5,8'hBA,8'hA6}; // 合唱长度
    localparam [23:0]  W_WU               = {8'hE6,8'h97,8'hA0};                                                          // 无

    // ── 抓一个 burst：⭐ 收到至少一个字节，直到 tx_start 连续 4 拍为 0（空闲）──
    //   ⚠️ **在 negedge 采样**（⭐ 与 `feed` 同一约定）——
    //      DUT 用非阻塞在 posedge 更新 `tx_start_o`/`tx_data_o` ⇒
    //      在 negedge 读到的才是**已稳定**的值（⭐ 在 posedge 读会竞态、字节错位/重复）
    task capture_echo;
        integer idle_cnt;
        begin
            bi = 0;
            idle_cnt = 0;
            // ⭐ 等第一个字节（negedge 采样）
            while (tx_start !== 1'b1) @(negedge clk);
            // ⭐ 逐字节收，直到连续 4 拍空闲（帧间隙判据）
            while (1) begin
                if (tx_start === 1'b1) begin
                    cap[bi] = tx_data;
                    bi = bi + 1;
                    idle_cnt = 0;
                end else begin
                    idle_cnt = idle_cnt + 1;
                    if (idle_cnt >= 4 && bi > 0) begin
                        cap_n = bi;
                        disable capture_echo;
                    end
                end
                @(negedge clk);
            end
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-10-29：`expect_frame` —— v2 回显帧核对（⭐ 替代旧 expect_bytes）
    //   📌 帧结构（与 uart_ui.v ③「帧字节」逐段对齐）：
    //      `<名字>`(nlen) + `.txt="`(6B) / `.val=`/`.tim=`/`.bco=`/`.pco=`(各 5B)
    //      + <body>(blen) + [`"`](仅 txt) + `FF FF FF`(3)
    //   📌 名字/body 参数**右对齐**（⭐ 高位零填充无害——按 len 从低位取字节）✅
    //   ⚠️ 取字节用【移位】`s >> (8*(len-1-k))` 取低 8 位——
    //      ⛔ 不用变基 part-select（iverilog 对 `s[8*k +: 8]` 支持不稳）✅
    //   📌 `flen` 输出 = nlen+ilen+blen+quote+3 ⇒ 调用方 `off = off + flen`
    //      链式推进，最后 `chk(off === cap_n)` 验证 burst 恰好走满 ✅
    // ═══════════════════════════════════════════════════════════════════
    task expect_frame;
        input [8*96-1:0]  desc;      // ⭐ 判据名（中文/emoji 各 3B ⇒ 取 96B 宽）
        input integer     off;       // ⭐ 本帧在 cap[] 的起始偏移
        output integer    flen;      // ⭐ 本帧总长（调用方链式推进用）
        input [2:0]       ftype;     // ⭐ 0=txt · 1=val · 2=tim · 3=bco · 4=pco（⭐ 旧 1'b0/1'b1 零扩展兼容）
        input [71:0]      name_str;  // ⭐ 控件名（右对齐，最长 9B = t_dist_st）
        input [3:0]       nlen;      // ⭐ 名字字节数
        input [287:0]     body_str;  // ⭐ body（右对齐，最长 36B = t_hdmi 波形档）
        input [5:0]       blen;      // ⭐ body 字节数
        integer p, k;
        reg ok;
        reg [7:0] nb;
        begin
            p  = off;
            ok = 1'b1;
            // ┚ 名字（逐字节）
            for (k = 0; k < nlen; k = k + 1) begin
                nb = name_str >> (8*(nlen - 1 - k));
                if (cap[p] !== nb[7:0]) ok = 1'b0;
                p = p + 1;
            end
            // ┚ infix：`.val=`/`.tim=`/`.bco=`/`.pco=` (各 5B) 或 `.txt="` (6B)
            if (cap[p] !== 8'h2E) ok = 1'b0;  p = p + 1;   // '.'
            case (ftype)
                3'd1: begin  // .val= (76 61 6C 3D)
                    if (cap[p] !== 8'h76) ok = 1'b0;  p = p + 1;   // 'v'
                    if (cap[p] !== 8'h61) ok = 1'b0;  p = p + 1;   // 'a'
                    if (cap[p] !== 8'h6C) ok = 1'b0;  p = p + 1;   // 'l'
                    if (cap[p] !== 8'h3D) ok = 1'b0;  p = p + 1;   // '='
                end
                3'd2: begin  // .tim= (74 69 6D 3D)
                    if (cap[p] !== 8'h74) ok = 1'b0;  p = p + 1;   // 't'
                    if (cap[p] !== 8'h69) ok = 1'b0;  p = p + 1;   // 'i'
                    if (cap[p] !== 8'h6D) ok = 1'b0;  p = p + 1;   // 'm'
                    if (cap[p] !== 8'h3D) ok = 1'b0;  p = p + 1;   // '='
                end
                3'd3: begin  // .bco= (62 63 6F 3D)
                    if (cap[p] !== 8'h62) ok = 1'b0;  p = p + 1;   // 'b'
                    if (cap[p] !== 8'h63) ok = 1'b0;  p = p + 1;   // 'c'
                    if (cap[p] !== 8'h6F) ok = 1'b0;  p = p + 1;   // 'o'
                    if (cap[p] !== 8'h3D) ok = 1'b0;  p = p + 1;   // '='
                end
                3'd4: begin  // .pco= (70 63 6F 3D)
                    if (cap[p] !== 8'h70) ok = 1'b0;  p = p + 1;   // 'p'
                    if (cap[p] !== 8'h63) ok = 1'b0;  p = p + 1;   // 'c'
                    if (cap[p] !== 8'h6F) ok = 1'b0;  p = p + 1;   // 'o'
                    if (cap[p] !== 8'h3D) ok = 1'b0;  p = p + 1;   // '='
                end
                default: begin  // .txt=" (74 78 74 3D 22)
                    if (cap[p] !== 8'h74) ok = 1'b0;  p = p + 1;   // 't'
                    if (cap[p] !== 8'h78) ok = 1'b0;  p = p + 1;   // 'x'
                    if (cap[p] !== 8'h74) ok = 1'b0;  p = p + 1;   // 't'
                    if (cap[p] !== 8'h3D) ok = 1'b0;  p = p + 1;   // '='
                    if (cap[p] !== 8'h22) ok = 1'b0;  p = p + 1;   // '"'
                end
            endcase
            // ┚ body（逐字节）
            for (k = 0; k < blen; k = k + 1) begin
                nb = body_str >> (8*(blen - 1 - k));
                if (cap[p] !== nb[7:0]) ok = 1'b0;
                p = p + 1;
            end
            // ┚ 收尾引号（仅 txt 帧）
            if (ftype == 3'd0) begin
                if (cap[p] !== 8'h22) ok = 1'b0;
                p = p + 1;
            end
            // ┚ FF FF FF（帧尾三连）
            if (cap[p]   !== 8'hFF) ok = 1'b0;
            if (cap[p+1] !== 8'hFF) ok = 1'b0;
            if (cap[p+2] !== 8'hFF) ok = 1'b0;
            p = p + 3;
            flen = p - off;
            // ⚚ 越界（抓到的字节根本不够一帧）同样判红
            if (cap_n < off + flen) ok = 1'b0;
            if (!ok) begin
                $write("        [echo] 期望帧 @%0d: ftype=%0d nlen=%0d blen=%0d flen=%0d cap_n=%0d\n",
                       off, ftype, nlen, blen, flen, cap_n);
                $write("        实际字节：");
                for (k = 0; k < cap_n; k = k + 1) $write("%02X ", cap[k]);
                $write("\n");
            end
            chk(desc, ok);
        end
    endtask

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

        // ═════════════════════════════════════════════════════════════════
        // ④c 2026-10-30：触摸控件 3 = 音色循环请求（⭐ 屏 b_timbre 按钮闭环）
        // ═════════════════════════════════════════════════════════════════
        //   🔴 **背景**：⭐ 屏上 t_timbre（BASS/GUITAR/PIANO/PAD）原来**没有任何
        //      屏按钮能切**（入口只有板载 S2 / 调试串口 'I'）⇒ 屏侧闭环缺一环 ✗
        //   ✅ **现在**：⭐ 控件 3 → `timbre_req_o` 单周期脉冲 →
        //      `top.v` 并入 `timbre_sel_r` 驱动（0→1→2→3→0 回绕）⇒
        //      ⭐ 下游（note_manager/looper/led）与 t_timbre 回显**全自动闭环** ✅
        //   📌 本 tb 只验 uart_ui 侧脉冲；timbre_sel_r 的三入口并联由队友的
        //      `tb_top_timbre_button.sv` 侧负责（⭐ top.v 已加 `|| ui_timbre_req`）
        feed_frame(8'h65, 8'h03, 8'h00);
        chk("控件3 -> timbre_req 单周期脉冲（屏音色按钮闭环）", timbre_req === 1'b1);
        @(negedge clk);
        chk("控件3 -> timbre_req 仅 1 拍（严格单周期）", timbre_req === 1'b0);
        //  ⭐ 负判据：0x83（bit7 置位）⛔ 不许别名成控件 3（⭐ 与 0x80 同族）
        begin : timbre_alias_guard
            reg mode_before;
            mode_before = mode;
            feed_frame(8'h65, 8'h83, 8'h00);
            chk("touch 0x83: bit7 置位 ⇒ ⛔ 不许别名成控件 3（不发音色脉冲）",
                timbre_req === 1'b0);
            chk("touch 0x83: 且不翻转模式（⛔ 不别名成控件 0）",
                mode === mode_before);
        end

        // ═════════════════════════════════════════════════════════
        // ④d 2026-10-31：控件 4..14 = page0 控制面板 11 个按钮脉冲
        // ═════════════════════════════════════════════════════════
        //   🔴 **背景**：⭐ page0 上 t_slide/t_drum/t_kd/t_trans/t_loop/
        //      t_gear/t_bpm 原来只是文字回显，屏上无入口（只有调试串口）
        //      ⇒ 🔴 "点后可以切换"的用户要求不满足 ✗
        //   ✅ **现在**：⭐ 每字段右端叠一个热区按钮（`65 00 <id>` 帧）⇒
        //      `uart_ui` 发单周期脉冲，top.v 并入对应 `cmd_*_req` ⇒
        //      与调试串口走同一条下游路径，⭐ 回显 FSM 自动闭环 ✅
        //   📌 本 tb 验 uart_ui 侧：⭐ 独热（只发对应脉冲）+ 严格单拍；
        //      并入后的下游行为归 top 级 tb（stub elaborate 已验接线）

        //  控件 4：滑音开/关（b_slide → 'W' 通路）
        feed_frame(8'h65, 8'h04, 8'h00);
        chk("控件4 滑音 -> slide_req 独热单拍（且 ⛔ 不发 timbre_req）",
            panel_vec === 11'b000_0000_0001 && timbre_req === 1'b0);
        @(negedge clk);
        chk("控件4 -> panel_vec 全归零（严格单周期）", panel_vec === 11'd0);

        //  控件 5：鼓机节奏型下一（b_drum → 'D'）
        feed_frame(8'h65, 8'h05, 8'h00);
        chk("控件5 鼓机 -> drum_req 独热单拍", panel_vec === 11'b000_0000_0010);
        @(negedge clk);
        chk("控件5 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 6：键盘打鼓开/关（b_kd → 'K'）
        feed_frame(8'h65, 8'h06, 8'h00);
        chk("控件6 打鼓 -> kd_req 独热单拍", panel_vec === 11'b000_0000_0100);
        @(negedge clk);
        chk("控件6 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 7：移调 +1 半音（b_tr_up → 'F'）
        feed_frame(8'h65, 8'h07, 8'h00);
        chk("控件7 移调+ -> trans_up_req 独热单拍", panel_vec === 11'b000_0000_1000);
        @(negedge clk);
        chk("控件7 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 8：移调 -1 半音（b_tr_dn → 'G'）
        feed_frame(8'h65, 8'h08, 8'h00);
        chk("控件8 移调- -> trans_dn_req 独热单拍", panel_vec === 11'b000_0001_0000);
        @(negedge clk);
        chk("控件8 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 9：循环录音（b_rec → 'R'）
        feed_frame(8'h65, 8'h09, 8'h00);
        chk("控件9 循环录 -> loop_rec_req 独热单拍", panel_vec === 11'b000_0010_0000);
        @(negedge clk);
        chk("控件9 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 10：循环播放（b_play → 'L'）
        feed_frame(8'h65, 8'h0A, 8'h00);
        chk("控件10 循环播 -> loop_play_req 独热单拍", panel_vec === 11'b000_0100_0000);
        @(negedge clk);
        chk("控件10 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 11：循环清空（b_clear → 'C'）
        feed_frame(8'h65, 8'h0B, 8'h00);
        chk("控件11 循环清 -> loop_clear_req 独热单拍", panel_vec === 11'b000_1000_0000);
        @(negedge clk);
        chk("控件11 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 12：推子档位下一（b_gear → 'J'）
        feed_frame(8'h65, 8'h0C, 8'h00);
        chk("控件12 档位 -> gear_req 独热单拍", panel_vec === 11'b001_0000_0000);
        @(negedge clk);
        chk("控件12 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 13：BPM +5（b_bpm_up → BPM shadow）
        feed_frame(8'h65, 8'h0D, 8'h00);
        chk("控件13 BPM+ -> bpm_up_req 独热单拍", panel_vec === 11'b010_0000_0000);
        @(negedge clk);
        chk("控件13 -> panel_vec 全归零", panel_vec === 11'd0);

        //  控件 14：BPM -5（b_bpm_dn → BPM shadow）
        feed_frame(8'h65, 8'h0E, 8'h00);
        chk("控件14 BPM- -> bpm_dn_req 独热单拍", panel_vec === 11'b100_0000_0000);
        @(negedge clk);
        chk("控件14 -> panel_vec 全归零", panel_vec === 11'd0);

        //  ⭐ 控件 15 = b_uplink（实时上行开关：⭐ 2026-10-31 起语义升级——
        //    翻转 uplink_sw_o 1→0，⛔ 仍不发任何面板脉冲）
        //   📌 翻转后由变化检测自动挂 UPL 帧（hb_ready=1 ⇒ 会起一个游离
        //      burst 传完 42B ⇒ 对 ⑤/⑥/⑦ 判据均无害，⑧ 前复位归 1）✅
        feed_frame(8'h65, 8'h0F, 8'h00);
        chk("控件15 b_uplink -> panel_vec 全零（⛔ 不许误发任何面板脉冲）",
            panel_vec === 11'd0);
        chk("控件15 b_uplink -> uplink_sw 1→0（翻转关闭）", uplink_sw === 1'b0);
        //  ⭐ 负判据 2：0x8D（bit7 置位）⛔ 不许别名成控件 13（BPM+）
        feed_frame(8'h65, 8'h8D, 8'h00);
        chk("touch 0x8D: bit7 置位 ⇒ ⛔ 不许别名成控件 13（不发 BPM+ 脉冲）",
            panel_vec === 11'd0);

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
        // ⑧ ⭐⭐ v2 状态回显推送 FSM（56 字段全量 / 缺口2+3 判据）
        // ═══════════════════════════════════════════════════════════════════
        //   判据设计（能红）：握手沿 ⇒ 56 帧全量 burst（ech_pend 最低位优先
        //   = 字段 0..55 顺序：page0 22 帧 + page1 25 帧 + 新 9 帧；⭐ RTL id 22
        //   = 心跳被全量掩码排除 ⇒ tb f22 = RTL id 23）；之后每次变化
        //   只回显受影响字段（同源字段成组：st_vol ⇒ t_vol+j_vol；
        //   st_fxmask ⇒ dist/chor/dly + 三状态灯六帧）。
        //   ⚠️ 本 tb 用 MODE_PIANO_DEFAULT=0（指板）⇒ t_mode 回显指板。
        // ═══════════════════════════════════════════════════════════════════
        // 干净复位：hb_ready 回 0、镜像回复位值（§②/§⑦ 已握过手 ⇒ 必须复位）
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        chk("echo: 复位后 hb_ready=0（干净起点）", hb_ready === 1'b0);

        // ── ⑧-0 门控：握手前的变化【零回显】──────────────────────────
        //   ⭐ 变化检测全部门控在 hb_ready ⇒ 改 st_bpm（120→96）后 10 拍内
        //      tx_start 必须恒 0（⛔ 若门控失效会立刻起推 ⇒ 红）✅
        begin : pre_hb_gate
            integer g;
            st_bpm = 8'd96;          // ⭐ 握手前变化（96 ≠ 镜像复位值 120）
            for (g = 0; g < 10; g = g + 1) begin
                @(negedge clk);
                if (tx_start === 1'b1) begin
                    chk("echo⑧-0 握手前变化零回显（tx_start 恒 0）", 1'b0);
                    disable pre_hb_gate;
                end
            end
            chk("echo⑧-0 握手前变化零回显（tx_start 恒 0）", 1'b1);
        end

        // ── ⑧-1 握手沿 ⇒ 56 帧全量 burst ─────────────────────────────
        //   ⭐ fork/join 并发抓取：hb_ready 在 0x88 字节拍就置位 ⇒ 回显在
        //      握手帧尾之前起推 ⇒ 必须与 feed_frame 并发收（否则漏帧头）。
        //   ⭐ st_bpm=96（握手前改的）⇒ t_bpm 帧体 "96"=2 位 ⇒ page0 22 帧
        //      = 643 字节（⭐ 2026-10-31 新文案：f7 t_drum 25 + f9 t_kd 43
        //      + f14/f15 t_pd/t_vd 各 23）；⭐ page1 25 帧 = 467 字节（bco19+
        //      pco18+led 17/17/16+z_dg..z_lf 14×6+z_pr/z_vr 13×2+t_*_val
        //      21×6/20×4+cur 32+gr 32）；⭐ 新 9 帧 = 176 字节
        //      ⇒ burst 总长 = 1286 字节（56 帧全量）。
        fork
            feed_frame(8'h88, 8'h00, 8'h00);
            capture_echo;
        join
        chk("echo⑧-1 握手后 hb_ready=1", hb_ready === 1'b1);
        chk("echo⑧-1 握手 burst 总长 = 1286 字节（56 帧全量）", cap_n === 1286);

        //   ⭐ 链式核对：off 逐帧推进，最后 off 必须恰好走满 cap_n
        off = 0;
        expect_frame("echo⑧-1 f0  t_mode=指板模式 [FRET]", off, flen, 1'b0,
            "t_mode", 4'd6, {W_ZHIBAN_MOSHI, " [FRET]"}, 6'd19);
        off = off + flen;
        expect_frame("echo⑧-1 f1  t1=关", off, flen, 1'b0,
            "t1", 4'd2, W_GUAN, 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f2  t_base=基准音 C4 (最低音 C3)", off, flen, 1'b0,
            "t_base", 4'd6,
            {W_JIZHUNYIN, ": ", "C4", " (", W_ZUIDIYIN, " ", "C3", ")"}, 6'd28);
        off = off + flen;
        expect_frame("echo⑧-1 f3  t_timbre=BASS", off, flen, 1'b0,
            "t_timbre", 4'd8, "BASS", 6'd4);
        off = off + flen;
        expect_frame("echo⑧-1 f4  t_trans=0 SEMI (原调)", off, flen, 1'b0,
            "t_trans", 4'd7, {"0 SEMI (", W_YUANDIAO, ")"}, 6'd15);
        off = off + flen;
        expect_frame("echo⑧-1 f5  t_slide=关闭 (GLIDE OFF)", off, flen, 1'b0,
            "t_slide", 4'd7, {W_GUANBI, " (GLIDE OFF)"}, 6'd18);
        off = off + flen;
        expect_frame("echo⑧-1 f6  t_bpm=96", off, flen, 1'b0,
            "t_bpm", 4'd5, "96", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f7  t_drum=Pattern I", off, flen, 1'b0,
            "t_drum", 4'd6, {"Pattern ", "I"}, 6'd9);
        off = off + flen;
        expect_frame("echo⑧-1 f8  t_loop=空闲", off, flen, 1'b0,
            "t_loop", 4'd6, W_KONGXIAN, 6'd6);
        off = off + flen;
        expect_frame("echo⑧-1 f9  t_kd=打鼓: 关闭 [音符演奏]", off, flen, 1'b0,
            "t_kd", 4'd4,
            {W_DAGU, ": ", W_GUANBI, " [", W_YINFU_YANZOU, "]"}, 6'd29);
        off = off + flen;
        expect_frame("echo⑧-1 f10 t_vol=主音量: 0%", off, flen, 1'b0,
            "t_vol", 4'd5, {W_ZHU_YINLIANG, ": ", "0", "%"}, 6'd13);
        off = off + flen;
        expect_frame("echo⑧-1 f11 t_pedal=[PEDAL 延音踏板: 松开]", off, flen, 1'b0,
            "t_pedal", 4'd7,
            {"[PEDAL ", W_YANYIN_TABAN, ": ", W_SONGKAI, "]"}, 6'd28);
        off = off + flen;
        expect_frame("echo⑧-1 f12 t_gear=推子控制: 档 2 [音高颤音]", off, flen, 1'b0,
            "t_gear", 4'd6,
            {W_TUIZI_KONGZHI, ": ", W_DANG, " ", "2", " [", W_YINGAO_CHANYIN, "]"},
            6'd34);
        off = off + flen;
        expect_frame("echo⑧-1 f13 t_hdmi=HDMI 实时示波器 (波形显示)", off, flen, 1'b0,
            "t_hdmi", 4'd6,
            {"HDMI: ", W_SHISHI_SHIBOQI, " (", W_BOXING_XIANSHI, ")"}, 6'd36);
        off = off + flen;
        expect_frame("echo⑧-1 f14 t_pd=深度 0%", off, flen, 1'b0,
            "t_pd", 4'd4, {W_SHENDU, " ", "0", "%"}, 6'd9);
        off = off + flen;
        expect_frame("echo⑧-1 f15 t_vd=深度 0%", off, flen, 1'b0,
            "t_vd", 4'd4, {W_SHENDU, " ", "0", "%"}, 6'd9);
        off = off + flen;
        expect_frame("echo⑧-1 f16 t_dist_st=失真 [关]", off, flen, 1'b0,
            "t_dist_st", 4'd9, {W_SHIZHEN, " [", W_GUAN, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-1 f17 t_chor_st=合唱 [关]", off, flen, 1'b0,
            "t_chor_st", 4'd9, {W_HECHANG, " [", W_GUAN, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-1 f18 t_dly_st=延迟 [关]", off, flen, 1'b0,
            "t_dly_st", 4'd8, {W_YANCHI, " [", W_GUAN, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-1 f19 j_vol.val=0", off, flen, 1'b1,
            "j_vol", 4'd5, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f20 z_pd.val=0", off, flen, 1'b1,
            "z_pd", 4'd4, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f21 z_vd.val=0", off, flen, 1'b1,
            "z_vd", 4'd4, "0", 6'd1);
        off = off + flen;
        //   ⭐⭐ page1 25 帧（f22..f46，⭐ §八收口新字段；值为复位默认）
        expect_frame("echo⑧-1 f22 t_loop.bco=63455（空闲浅灰）", off, flen, 3'd3,
            "t_loop", 4'd6, "63455", 6'd5);
        off = off + flen;
        expect_frame("echo⑧-1 f23 t_loop.pco=9509（空闲深字）", off, flen, 3'd4,
            "t_loop", 4'd6, "9509", 6'd4);
        off = off + flen;
        expect_frame("echo⑧-1 f24 led_dist.val=0", off, flen, 1'b1,
            "led_dist", 4'd8, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f25 led_chor.val=0", off, flen, 1'b1,
            "led_chor", 4'd8, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f26 led_dly.val=0", off, flen, 1'b1,
            "led_dly", 4'd7, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f27 z_dg.val=25（增益 16384）", off, flen, 1'b1,
            "z_dg", 4'd4, "25", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f28 z_dt.val=12（补偿 8192）", off, flen, 1'b1,
            "z_dt", 4'd4, "12", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f29 z_cl.val=35（合唱长 736）", off, flen, 1'b1,
            "z_cl", 4'd4, "35", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f30 z_mx.val=50（干湿 128）", off, flen, 1'b1,
            "z_mx", 4'd4, "50", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f31 z_ll.val=50（延 long 8192）", off, flen, 1'b1,
            "z_ll", 4'd4, "50", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f32 z_lf.val=37（反馈 96）", off, flen, 1'b1,
            "z_lf", 4'd4, "37", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f33 z_pr.val=2（速率 7）", off, flen, 1'b1,
            "z_pr", 4'd4, "2", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f34 z_vr.val=2（速率 7）", off, flen, 1'b1,
            "z_vr", 4'd4, "2", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f35 t_dg_val=25%", off, flen, 1'b0,
            "t_dg_val", 4'd8, "25%", 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f36 t_dt_val=12%", off, flen, 1'b0,
            "t_dt_val", 4'd8, "12%", 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f37 t_cl_val=35%", off, flen, 1'b0,
            "t_cl_val", 4'd8, "35%", 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f38 t_mx_val=50%", off, flen, 1'b0,
            "t_mx_val", 4'd8, "50%", 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f39 t_ll_val=50%", off, flen, 1'b0,
            "t_ll_val", 4'd8, "50%", 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f40 t_lf_val=37%", off, flen, 1'b0,
            "t_lf_val", 4'd8, "37%", 6'd3);
        off = off + flen;
        expect_frame("echo⑧-1 f41 t_pd_val=0%", off, flen, 1'b0,
            "t_pd_val", 4'd8, "0%", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f42 t_vd_val=0%", off, flen, 1'b0,
            "t_vd_val", 4'd8, "0%", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f43 t_pr_val=2%", off, flen, 1'b0,
            "t_pr_val", 4'd8, "2%", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f44 t_vr_val=2%", off, flen, 1'b0,
            "t_vr_val", 4'd8, "2%", 6'd2);
        off = off + flen;
        expect_frame("echo⑧-1 f45 cur=EC11: 增益 (0x11)", off, flen, 1'b0,
            "cur", 4'd3, {"EC11: ", W_ZENGYI, " (0x11)"}, 6'd19);
        off = off + flen;
        expect_frame("echo⑧-1 f46 gr=档 2 [音高颤音]", off, flen, 1'b0,
            "gr", 4'd2, {W_DANG, " ", "2", " [", W_YINGAO_CHANYIN, "]"}, 6'd20);
        off = off + flen;
        //   ⭐⭐ 2026-10-31 新 9 帧（f47..f55 = RTL id 48..56 链尾升序；
        //      值 = 复位默认：slide 0 / beat 0 / uplink 开启（⑧ 前复位已归 1）/
        //      prate 1.0Hz / vrate 5.2Hz / j_pr 0 / j_vr 2 / j_pd 0 / j_vd 0）
        expect_frame("echo⑧-1 f47 p_slide.val=0", off, flen, 1'b1,
            "p_slide", 4'd7, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f48 p_bpm.val=0", off, flen, 1'b1,
            "p_bpm", 4'd5, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f49 b_uplink=● 实时上行: 开启", off, flen, 1'b0,
            "b_uplink", 4'd8, {W_DOT, " ", W_SHISHI_SHANGXING, ": ", W_KAIQI},
            6'd24);
        off = off + flen;
        expect_frame("echo⑧-1 f50 t_pr=速率 1.0Hz", off, flen, 1'b0,
            "t_pr", 4'd4, {W_SULU, " ", "1.0", "Hz"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-1 f51 t_vr=速率 5.2Hz", off, flen, 1'b0,
            "t_vr", 4'd4, {W_SULU, " ", "5.2", "Hz"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-1 f52 j_pr.val=0", off, flen, 1'b1,
            "j_pr", 4'd4, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f53 j_vr.val=2", off, flen, 1'b1,
            "j_vr", 4'd4, "2", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f54 j_pd.val=0", off, flen, 1'b1,
            "j_pd", 4'd4, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-1 f55 j_vd.val=0", off, flen, 1'b1,
            "j_vd", 4'd4, "0", 6'd1);
        off = off + flen;
        chk("echo⑧-1 56 帧恰好走满 burst（off=cap_n）", off === cap_n);

        // ── ⑧-2 变化回显：st_bpm 96→120（缺口3 回显链）──────────────
        st_bpm = 8'd120;
        capture_echo;
        chk("echo⑧-2 burst 总长 = 18 字节（仅 t_bpm 单帧）", cap_n === 18);
        off = 0;
        expect_frame("echo⑧-2 t_bpm=120", off, flen, 1'b0,
            "t_bpm", 4'd5, "120", 6'd3);
        off = off + flen;
        chk("echo⑧-2 单帧走满 burst", off === cap_n);

        // ── ⑧-3 触摸切钢琴 ⇒ t_mode 单帧 ────────────────────────────
        feed_frame(8'h65, 8'h00, 8'h00);
        capture_echo;
        chk("echo⑧-3 触摸后 mode=钢琴(1)", mode === 1'b1);
        chk("echo⑧-3 burst 总长 = 36 字节", cap_n === 36);
        off = 0;
        expect_frame("echo⑧-3 t_mode=钢琴模式 [PIANO]", off, flen, 1'b0,
            "t_mode", 4'd6, {W_GANGQIN_MOSHI, " [PIANO]"}, 6'd20);
        off = off + flen;
        chk("echo⑧-3 单帧走满 burst", off === cap_n);

        // ── ⑧-4 Test Mode 切档 ⇒ t1 单帧 ────────────────────────────
        feed_frame(8'h65, 8'h02, 8'h00);
        capture_echo;
        chk("echo⑧-4 切档后 test_mode=1, n=00(4)",
            test_mode === 1'b1 && test_mode_n === 2'b00);
        chk("echo⑧-4 burst 总长 = 13 字节", cap_n === 13);
        off = 0;
        expect_frame("echo⑧-4 t1=4", off, flen, 1'b0, "t1", 4'd2, "4", 6'd1);
        off = off + flen;
        chk("echo⑧-4 单帧走满 burst", off === cap_n);

        // ── ⑧-5 起始音 C6 ⇒ t_base 单帧 ─────────────────────────────
        feed_frame(8'h71, 8'h01, 8'h30);   // val=48 ⇒ base_semi=24 (C6)
        capture_echo;
        chk("echo⑧-5 起始音落地 base_semi=24(C6)", base_semi === 7'd24);
        chk("echo⑧-5 burst 总长 = 44 字节", cap_n === 44);
        off = 0;
        expect_frame("echo⑧-5 t_base=基准音 C6 (最低音 C5)", off, flen, 1'b0,
            "t_base", 4'd6,
            {W_JIZHUNYIN, ": ", "C6", " (", W_ZUIDIYIN, " ", "C5", ")"}, 6'd28);
        off = off + flen;
        chk("echo⑧-5 单帧走满 burst", off === cap_n);

        // ── ⑧-6 音色 ⇒ t_timbre 单帧 ────────────────────────────────
        st_timbre = 2'd2;                   // PIANO
        capture_echo;
        chk("echo⑧-6 burst 总长 = 23 字节", cap_n === 23);
        off = 0;
        expect_frame("echo⑧-6 t_timbre=PIANO", off, flen, 1'b0,
            "t_timbre", 4'd8, "PIANO", 6'd5);
        off = off + flen;
        chk("echo⑧-6 单帧走满 burst", off === cap_n);

        // ── ⑧-7 变调 ±3 ⇒ t_trans 单帧（正/负各一）──────────────────
        st_trans = 5'd3;
        capture_echo;
        chk("echo⑧-7a burst 总长 = 24 字节", cap_n === 24);
        off = 0;
        expect_frame("echo⑧-7a t_trans=+3 SEMI", off, flen, 1'b0,
            "t_trans", 4'd7, {"+", "3", " SEMI"}, 6'd7);
        off = off + flen;
        chk("echo⑧-7a 单帧走满 burst", off === cap_n);

        st_trans = 5'd29;                   // 5'b11101 = -3（补码）
        capture_echo;
        chk("echo⑧-7b burst 总长 = 24 字节", cap_n === 24);
        off = 0;
        expect_frame("echo⑧-7b t_trans=-3 SEMI", off, flen, 1'b0,
            "t_trans", 4'd7, {"-", "3", " SEMI"}, 6'd7);
        off = off + flen;
        chk("echo⑧-7b 单帧走满 burst", off === cap_n);

        // ── ⑧-8 主音量 ⇒ t_vol+j_vol 同源双帧 ───────────────────────
        st_vol = 7'd85;
        capture_echo;
        chk("echo⑧-8 burst 总长 = 44 字节（t_vol 29 + j_vol 15）", cap_n === 44);
        off = 0;
        expect_frame("echo⑧-8a t_vol=主音量: 85%", off, flen, 1'b0,
            "t_vol", 4'd5, {W_ZHU_YINLIANG, ": ", "85", "%"}, 6'd14);
        off = off + flen;
        expect_frame("echo⑧-8b j_vol.val=85", off, flen, 1'b1,
            "j_vol", 4'd5, "85", 6'd2);
        off = off + flen;
        chk("echo⑧-8 双帧走满 burst", off === cap_n);

        // ── ⑧-9 效果器掩码 ⇒ page0 三状态帧 + page1 三状态灯六帧 ────
        st_fxmask = 3'b101;                 // dist 开 / chor 关 / dly 开
        capture_echo;
        chk("echo⑧-9 burst 总长 = 142 字节（31+31+30+17+17+16 六帧）", cap_n === 142);
        off = 0;
        expect_frame("echo⑧-9a t_dist_st=失真 [开]", off, flen, 1'b0,
            "t_dist_st", 4'd9, {W_SHIZHEN, " [", W_KAI, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-9b t_chor_st=合唱 [关]", off, flen, 1'b0,
            "t_chor_st", 4'd9, {W_HECHANG, " [", W_GUAN, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-9c t_dly_st=延迟 [开]", off, flen, 1'b0,
            "t_dly_st", 4'd8, {W_YANCHI, " [", W_KAI, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑧-9d led_dist.val=1", off, flen, 1'b1,
            "led_dist", 4'd8, "1", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-9e led_chor.val=0", off, flen, 1'b1,
            "led_chor", 4'd8, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑧-9f led_dly.val=1", off, flen, 1'b1,
            "led_dly", 4'd7, "1", 6'd1);
        off = off + flen;
        chk("echo⑧-9 六帧走满 burst", off === cap_n);

        // ── ⑧-10 EC11 写回（缺口4）：写同一组 fx 寄存器 + 单拍 commit ──
        //   ⭐ 步进 = 串口最小格点（gain ±256 / mix ±1 / chorlen ±32）
        //   ⭐⭐ 2026-10-29 晚：fx 参数成为 page1 字段数据源 ⇒ 写回【正向回显】
        //      （z_* 仪表 + t_*_val 文本双帧；par_sel 变化额外挂起 cur）✅
        //   ⭐ ⑧-10d/f 的 cur 帧【在最前】：par_sel 先于 par_up 一拍变化 ⇒
        //      CUR 先挂起、FSM 先锁存 cur 快照，期间 mix/chorlen 才挂起 ✅
        begin : ec11_wr
            integer e;
            // gain up：16384 → 16640（par_sel=0 未变 ⇒ 无 cur 帧）
            par_sel = 3'd0;
            @(negedge clk); par_up = 1'b1;
            @(negedge clk); par_up = 1'b0;
            chk("echo⑧-10a gain up 16384->16640", fx_gain === 16'd16640);
            chk("echo⑧-10a fx_commit 单拍脉冲", fx_commit === 1'b1);
            @(negedge clk);
            chk("echo⑧-10a fx_commit 仅 1 拍", fx_commit === 1'b0);
            capture_echo;
            chk("echo⑧-10a burst 总长 = 35 字节（z_dg 14 + t_dg_val 21）",
                cap_n === 35);
            off = 0;
            expect_frame("echo⑧-10a z_dg.val=25", off, flen, 1'b1,
                "z_dg", 4'd4, "25", 6'd2);
            off = off + flen;
            expect_frame("echo⑧-10a t_dg_val=25%", off, flen, 1'b0,
                "t_dg_val", 4'd8, "25%", 6'd3);
            off = off + flen;
            chk("echo⑧-10a 双帧走满 burst", off === cap_n);

            // gain dn：16640 → 16384
            @(negedge clk); par_dn = 1'b1;
            @(negedge clk); par_dn = 1'b0;
            chk("echo⑧-10b gain dn 16640->16384", fx_gain === 16'd16384);
            capture_echo;
            chk("echo⑧-10b burst 总长 = 35 字节（z_dg 14 + t_dg_val 21）",
                cap_n === 35);
            off = 0;
            expect_frame("echo⑧-10b z_dg.val=25", off, flen, 1'b1,
                "z_dg", 4'd4, "25", 6'd2);
            off = off + flen;
            expect_frame("echo⑧-10b t_dg_val=25%", off, flen, 1'b0,
                "t_dg_val", 4'd8, "25%", 6'd3);
            off = off + flen;
            chk("echo⑧-10b 双帧走满 burst", off === cap_n);

            // up/dn 同拍 ⇒ 互斥丢弃：值不变 + 无 commit + 零回显
            @(negedge clk); par_up = 1'b1; par_dn = 1'b1;
            @(negedge clk); par_up = 1'b0; par_dn = 1'b0;
            chk("echo⑧-10c up/dn 同拍互斥丢弃（gain 不变）", fx_gain === 16'd16384);
            chk("echo⑧-10c 同拍丢弃无 commit", fx_commit === 1'b0);
            begin : ec11_echo_gate
                for (e = 0; e < 10; e = e + 1) begin
                    @(negedge clk);
                    if (tx_start === 1'b1) begin
                        chk("echo⑧-10c 同拍丢弃零回显（tx_start 恒 0）", 1'b0);
                        disable ec11_echo_gate;
                    end
                end
                chk("echo⑧-10c 同拍丢弃零回显（tx_start 恒 0）", 1'b1);
            end

            // mix up：128 → 129（⭐ par_sel 0→2 先挂起 cur ⇒ cur 帧最前）
            par_sel = 3'd2;
            @(negedge clk); par_up = 1'b1;
            @(negedge clk); par_up = 1'b0;
            chk("echo⑧-10d mix up 128->129", fx_mix === 8'd129);
            capture_echo;
            chk("echo⑧-10d burst 总长 = 67 字节（cur 32 + z_mx 14 + t_mx_val 21）",
                cap_n === 67);
            off = 0;
            expect_frame("echo⑧-10d cur=EC11: 混合 (0x13)", off, flen, 1'b0,
                "cur", 4'd3, {"EC11: ", W_HUNHE, " (0x13)"}, 6'd19);
            off = off + flen;
            expect_frame("echo⑧-10d z_mx.val=50", off, flen, 1'b1,
                "z_mx", 4'd4, "50", 6'd2);
            off = off + flen;
            expect_frame("echo⑧-10d t_mx_val=50%", off, flen, 1'b0,
                "t_mx_val", 4'd8, "50%", 6'd3);
            off = off + flen;
            chk("echo⑧-10d 三帧走满 burst", off === cap_n);

            // depth dn 下限幅：0 → 0（仍发 commit；值未变 ⇒ 仅 cur 单帧）
            par_sel = 3'd4;
            @(negedge clk); par_dn = 1'b1;
            @(negedge clk); par_dn = 1'b0;
            chk("echo⑧-10e depth dn 下限幅仍 0", fx_depth === 8'd0);
            chk("echo⑧-10e 下限幅仍发 commit", fx_commit === 1'b1);
            @(negedge clk);
            chk("echo⑧-10e commit 仅 1 拍", fx_commit === 1'b0);
            capture_echo;
            chk("echo⑧-10e burst 总长 = 32 字节（仅 cur）", cap_n === 32);
            off = 0;
            expect_frame("echo⑧-10e cur=EC11: 深度 (0x15)", off, flen, 1'b0,
                "cur", 4'd3, {"EC11: ", W_SHENDU, " (0x15)"}, 6'd19);
            off = off + flen;
            chk("echo⑧-10e 单帧走满 burst", off === cap_n);

            // chorlen up：736 → 768（FX_CHORLEN_DEF=736 在串口格点上）
            par_sel = 3'd7;
            @(negedge clk); par_up = 1'b1;
            @(negedge clk); par_up = 1'b0;
            chk("echo⑧-10f chorlen up 736->768", fx_chorlen === 11'd768);
            capture_echo;
            chk("echo⑧-10f burst 总长 = 73 字节（cur 38 + z_cl 14 + t_cl_val 21）",
                cap_n === 73);
            off = 0;
            expect_frame("echo⑧-10f cur=EC11: 合唱长度 (0x18)", off, flen, 1'b0,
                "cur", 4'd3, {"EC11: ", W_HECHANG_CD, " (0x18)"}, 6'd25);
            off = off + flen;
            expect_frame("echo⑧-10f z_cl.val=37", off, flen, 1'b1,
                "z_cl", 4'd4, "37", 6'd2);
            off = off + flen;
            expect_frame("echo⑧-10f t_cl_val=37%", off, flen, 1'b0,
                "t_cl_val", 4'd8, "37%", 6'd3);
            off = off + flen;
            chk("echo⑧-10f 三帧走满 burst", off === cap_n);
        end

        // ── ⑧-11 流控：tx_busy=1 时回显【暂停】，解除后字节完整 ───────
        //   ⭐ 最长帧 52 字节 > `u_tx_fifo` 深度 8 ⇒ 必须 busy 背压（⛔ 不许盲推）
        begin : echo_flowctl
            integer h;
            tx_busy = 1'b1;                // ⭐ 掐住下游
            st_pedal = 1'b1;               // 踩下 ⇒ 触发 t_pedal 回显
            for (h = 0; h < 8; h = h + 1) begin
                @(negedge clk);
                if (tx_start === 1'b1) begin
                    chk("echo⑧-11 busy 期间 tx_start 必须=0（不许盲推溢出）", 1'b0);
                    disable echo_flowctl;
                end
            end
            chk("echo⑧-11 busy 期间 tx_start 恒 0（回显被背压挡住）", 1'b1);
            //   解除 busy ⇒ 回显恢复、完整推出 t_pedal 帧
            tx_busy = 1'b0;
            capture_echo;
            chk("echo⑧-11 流控解除后 burst 总长 = 51 字节", cap_n === 51);
            off = 0;
            expect_frame("echo⑧-11 t_pedal=[PEDAL 延音踏板: 踩下使能]", off, flen,
                1'b0, "t_pedal", 4'd7,
                {"[PEDAL ", W_YANYIN_TABAN, ": ", W_CAIXIA_SHINENG, "]"}, 6'd34);
            off = off + flen;
            chk("echo⑧-11 单帧走满 burst", off === cap_n);
        end

        // ── ⑫ 心跳帧（⭐ 2026-10-29：⭐ 喂屏侧看门狗 tm1 ⇒ 断联闪烁）────────
        //   ⭐ DUT 例化 HB_MS=1 ⇒ 握手后每 1ms 一帧 `tm1.tim=1500` + FF FF FF
        //   📌 帧内容里的 "1500" 是屏侧 tm1 周期（⭐ 成对配置），与 tb 的 1ms 无关
        begin : hb_beat
            integer  p;
            realtime t1, t2;
            reg      ok;
            // ⚚ 第一拍：抓 burst（⭐ 既有判据已全部结束 ⇒ 这里只会是心跳帧）
            capture_echo;
            t1 = $realtime;
            chk("echo⑫-1 心跳帧总长 = 15 字节", cap_n === 15);
            // ⚚ 逐字节核对：tm1.tim=1500 FF FF FF
            ok = 1'b1;
            for (p = 0; p < 15; p = p + 1) begin
                case (p)
                    0:  if (cap[p] !== "t") ok = 1'b0;
                    1:  if (cap[p] !== "m") ok = 1'b0;
                    2:  if (cap[p] !== "1") ok = 1'b0;
                    3:  if (cap[p] !== 8'h2E) ok = 1'b0;  // '.'
                    4:  if (cap[p] !== "t") ok = 1'b0;
                    5:  if (cap[p] !== "i") ok = 1'b0;
                    6:  if (cap[p] !== "m") ok = 1'b0;
                    7:  if (cap[p] !== 8'h3D) ok = 1'b0;  // '='
                    8:  if (cap[p] !== "1") ok = 1'b0;
                    9:  if (cap[p] !== "5") ok = 1'b0;
                    10: if (cap[p] !== "0") ok = 1'b0;
                    11: if (cap[p] !== "0") ok = 1'b0;
                    default: if (cap[p] !== 8'hFF) ok = 1'b0;   // 尾部 3×FF
                endcase
            end
            chk("echo⑫-2 心跳帧内容 = tm1.tim=1500 + FF FF FF", ok);
            // ⚚ 第二拍：间隔 ≈ 1ms（⭐ 0.9~1.2ms 容差：⭐ 帧排出/判据排队的抖动）
            capture_echo;
            t2 = $realtime;
            chk("echo⑫-3 心跳周期 ≈ 1ms（含容差）",
                (t2 - t1) >= 900_000.0 && (t2 - t1) <= 1_200_000.0);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑬ ⭐⭐ 2026-10-29 RTL 三件套（0x88 重发 / 0x19 翻转 / 0x1B 八度循环）
        // ═══════════════════════════════════════════════════════════════════
        //   判据设计（能红）：
        //   A. 二次 0x88（hb_ready 已=1、无握手沿）⇒ 必须再收 56 帧全量 burst，
        //      且内容 = **当前值**（⑧ 残留：钢琴/4/C6/PIANO/-3/120/85%/踩下/101；
        //      page1 残留：led 1/0/1、z_cl=37（chorlen 768）、mix 129 仍 50%、
        //      par_sel=7 ⇒ cur=合唱长度 (0x18)）
        //      —— 修前一个字节都不回（capture_echo 挂死 ⇒ 看门狗 FAIL）✅
        //   B. `71 19 <bit>` ⇒ fx_mask 盲翻转（0→02→07→05），fx_commit 单拍
        //   C. `71 1B 01` ⇒ base_semi 24→0→12→24 循环，base_commit 单拍
        // ═══════════════════════════════════════════════════════════════════

        // ── ⑬-A 二次 0x88 ⇒ 56 帧全量重发（切页返回刷新）────────────────
        //   ⭐ 帧长预算（page0 22 帧 = 644：与 ⑧-1 同源但 t_bpm "120"=3 位
        //      ⇒ 643+1；page1 25 帧 = 473）：
        //      page1 = 19(bco)+18(pco)+17+17+16(led 1/0/1)+14×6+13×2(z_*)
        //      +21×6+20×4(t_*_val)+38(cur)+32(gr 档2)
        //      ⭐ 与 ⑧-1 的 467 差 6B：cur = 合唱长度 (0x18) 38B（⑧-10f 把
        //      par_sel 拨到 7 ⇒ 这里锁存的就是合唱长度而非增益 32B）；
        //      ⭐ 新 9 帧 = 176 ⇒ 1293
        fork
            feed_frame(8'h88, 8'h00, 8'h00);
            capture_echo;
        join
        chk("echo⑬-1 二次 0x88 ⇒ 全量重发 burst = 1293 字节（56 帧）", cap_n === 1293);
        off = 0;
        expect_frame("echo⑬-1 f0  t_mode=钢琴模式 [PIANO]", off, flen, 1'b0,
            "t_mode", 4'd6, {W_GANGQIN_MOSHI, " [PIANO]"}, 6'd20);
        off = off + flen;
        expect_frame("echo⑬-1 f1  t1=4", off, flen, 1'b0, "t1", 4'd2, "4", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f2  t_base=基准音 C6 (最低音 C5)", off, flen, 1'b0,
            "t_base", 4'd6,
            {W_JIZHUNYIN, ": ", "C6", " (", W_ZUIDIYIN, " ", "C5", ")"}, 6'd28);
        off = off + flen;
        expect_frame("echo⑬-1 f3  t_timbre=PIANO", off, flen, 1'b0,
            "t_timbre", 4'd8, "PIANO", 6'd5);
        off = off + flen;
        expect_frame("echo⑬-1 f4  t_trans=-3 SEMI（当前值非陈旧镜像）", off, flen, 1'b0,
            "t_trans", 4'd7, {"-", "3", " SEMI"}, 6'd7);
        off = off + flen;
        expect_frame("echo⑬-1 f5  t_slide=关闭 (GLIDE OFF)", off, flen, 1'b0,
            "t_slide", 4'd7, {W_GUANBI, " (GLIDE OFF)"}, 6'd18);
        off = off + flen;
        expect_frame("echo⑬-1 f6  t_bpm=120", off, flen, 1'b0,
            "t_bpm", 4'd5, "120", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f7  t_drum=Pattern I", off, flen, 1'b0,
            "t_drum", 4'd6, {"Pattern ", "I"}, 6'd9);
        off = off + flen;
        expect_frame("echo⑬-1 f8  t_loop=空闲", off, flen, 1'b0,
            "t_loop", 4'd6, W_KONGXIAN, 6'd6);
        off = off + flen;
        expect_frame("echo⑬-1 f9  t_kd=打鼓: 关闭 [音符演奏]", off, flen, 1'b0,
            "t_kd", 4'd4,
            {W_DAGU, ": ", W_GUANBI, " [", W_YINFU_YANZOU, "]"}, 6'd29);
        off = off + flen;
        expect_frame("echo⑬-1 f10 t_vol=主音量: 85%", off, flen, 1'b0,
            "t_vol", 4'd5, {W_ZHU_YINLIANG, ": ", "85", "%"}, 6'd14);
        off = off + flen;
        expect_frame("echo⑬-1 f11 t_pedal=[PEDAL 延音踏板: 踩下使能]", off, flen,
            1'b0, "t_pedal", 4'd7,
            {"[PEDAL ", W_YANYIN_TABAN, ": ", W_CAIXIA_SHINENG, "]"}, 6'd34);
        off = off + flen;
        expect_frame("echo⑬-1 f12 t_gear=推子控制: 档 2 [音高颤音]", off, flen, 1'b0,
            "t_gear", 4'd6,
            {W_TUIZI_KONGZHI, ": ", W_DANG, " ", "2", " [", W_YINGAO_CHANYIN, "]"},
            6'd34);
        off = off + flen;
        expect_frame("echo⑬-1 f13 t_hdmi=HDMI 实时示波器 (波形显示)", off, flen, 1'b0,
            "t_hdmi", 4'd6,
            {"HDMI: ", W_SHISHI_SHIBOQI, " (", W_BOXING_XIANSHI, ")"}, 6'd36);
        off = off + flen;
        expect_frame("echo⑬-1 f14 t_pd=深度 0%", off, flen, 1'b0,
            "t_pd", 4'd4, {W_SHENDU, " ", "0", "%"}, 6'd9);
        off = off + flen;
        expect_frame("echo⑬-1 f15 t_vd=深度 0%", off, flen, 1'b0,
            "t_vd", 4'd4, {W_SHENDU, " ", "0", "%"}, 6'd9);
        off = off + flen;
        expect_frame("echo⑬-1 f16 t_dist_st=失真 [开]", off, flen, 1'b0,
            "t_dist_st", 4'd9, {W_SHIZHEN, " [", W_KAI, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑬-1 f17 t_chor_st=合唱 [关]", off, flen, 1'b0,
            "t_chor_st", 4'd9, {W_HECHANG, " [", W_GUAN, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑬-1 f18 t_dly_st=延迟 [开]", off, flen, 1'b0,
            "t_dly_st", 4'd8, {W_YANCHI, " [", W_KAI, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑬-1 f19 j_vol.val=85", off, flen, 1'b1,
            "j_vol", 4'd5, "85", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f20 z_pd.val=0", off, flen, 1'b1,
            "z_pd", 4'd4, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f21 z_vd.val=0", off, flen, 1'b1,
            "z_vd", 4'd4, "0", 6'd1);
        off = off + flen;
        //   ⭐⭐ page1 25 帧（f22..f46；值 = ⑧ 残留当前值：灯 1/0/1、
        //      z_cl=37（chorlen 768）、cur=合唱长度（par_sel=7）⇒ 其余同默认）
        expect_frame("echo⑬-1 f22 t_loop.bco=63455（空闲浅灰）", off, flen, 3'd3,
            "t_loop", 4'd6, "63455", 6'd5);
        off = off + flen;
        expect_frame("echo⑬-1 f23 t_loop.pco=9509（空闲深字）", off, flen, 3'd4,
            "t_loop", 4'd6, "9509", 6'd4);
        off = off + flen;
        expect_frame("echo⑬-1 f24 led_dist.val=1", off, flen, 1'b1,
            "led_dist", 4'd8, "1", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f25 led_chor.val=0", off, flen, 1'b1,
            "led_chor", 4'd8, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f26 led_dly.val=1", off, flen, 1'b1,
            "led_dly", 4'd7, "1", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f27 z_dg.val=25（增益 16384）", off, flen, 1'b1,
            "z_dg", 4'd4, "25", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f28 z_dt.val=12（补偿 8192）", off, flen, 1'b1,
            "z_dt", 4'd4, "12", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f29 z_cl.val=37（合唱长 768）", off, flen, 1'b1,
            "z_cl", 4'd4, "37", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f30 z_mx.val=50（干湿 129）", off, flen, 1'b1,
            "z_mx", 4'd4, "50", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f31 z_ll.val=50（延 long 8192）", off, flen, 1'b1,
            "z_ll", 4'd4, "50", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f32 z_lf.val=37（反馈 96）", off, flen, 1'b1,
            "z_lf", 4'd4, "37", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f33 z_pr.val=2（速率 7）", off, flen, 1'b1,
            "z_pr", 4'd4, "2", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f34 z_vr.val=2（速率 7）", off, flen, 1'b1,
            "z_vr", 4'd4, "2", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f35 t_dg_val=25%", off, flen, 1'b0,
            "t_dg_val", 4'd8, "25%", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f36 t_dt_val=12%", off, flen, 1'b0,
            "t_dt_val", 4'd8, "12%", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f37 t_cl_val=37%", off, flen, 1'b0,
            "t_cl_val", 4'd8, "37%", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f38 t_mx_val=50%", off, flen, 1'b0,
            "t_mx_val", 4'd8, "50%", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f39 t_ll_val=50%", off, flen, 1'b0,
            "t_ll_val", 4'd8, "50%", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f40 t_lf_val=37%", off, flen, 1'b0,
            "t_lf_val", 4'd8, "37%", 6'd3);
        off = off + flen;
        expect_frame("echo⑬-1 f41 t_pd_val=0%", off, flen, 1'b0,
            "t_pd_val", 4'd8, "0%", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f42 t_vd_val=0%", off, flen, 1'b0,
            "t_vd_val", 4'd8, "0%", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f43 t_pr_val=2%", off, flen, 1'b0,
            "t_pr_val", 4'd8, "2%", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f44 t_vr_val=2%", off, flen, 1'b0,
            "t_vr_val", 4'd8, "2%", 6'd2);
        off = off + flen;
        expect_frame("echo⑬-1 f45 cur=EC11: 合唱长度 (0x18)", off, flen, 1'b0,
            "cur", 4'd3, {"EC11: ", W_HECHANG_CD, " (0x18)"}, 6'd25);
        off = off + flen;
        expect_frame("echo⑬-1 f46 gr=档 2 [音高颤音]", off, flen, 1'b0,
            "gr", 4'd2, {W_DANG, " ", "2", " [", W_YINGAO_CHANYIN, "]"}, 6'd20);
        off = off + flen;
        //   ⭐⭐ 2026-10-31 新 9 帧（f47..f55；⭐ 值与 ⑧-1 同默认：beat 零脉冲
        //      ⇒ p_bpm 仍 0；uplink 在 ⑧ 前复位归 1 且无人再翻 ⇒ 开启）
        expect_frame("echo⑬-1 f47 p_slide.val=0", off, flen, 1'b1,
            "p_slide", 4'd7, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f48 p_bpm.val=0", off, flen, 1'b1,
            "p_bpm", 4'd5, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f49 b_uplink=● 实时上行: 开启", off, flen, 1'b0,
            "b_uplink", 4'd8, {W_DOT, " ", W_SHISHI_SHANGXING, ": ", W_KAIQI},
            6'd24);
        off = off + flen;
        expect_frame("echo⑬-1 f50 t_pr=速率 1.0Hz", off, flen, 1'b0,
            "t_pr", 4'd4, {W_SULU, " ", "1.0", "Hz"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑬-1 f51 t_vr=速率 5.2Hz", off, flen, 1'b0,
            "t_vr", 4'd4, {W_SULU, " ", "5.2", "Hz"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑬-1 f52 j_pr.val=0", off, flen, 1'b1,
            "j_pr", 4'd4, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f53 j_vr.val=2", off, flen, 1'b1,
            "j_vr", 4'd4, "2", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f54 j_pd.val=0", off, flen, 1'b1,
            "j_pd", 4'd4, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑬-1 f55 j_vd.val=0", off, flen, 1'b1,
            "j_vd", 4'd4, "0", 6'd1);
        off = off + flen;
        chk("echo⑬-1 56 帧恰好走满 burst（off=cap_n）", off === cap_n);

        // ── ⑬-B 翻转变量 0x19：fx_mask 盲翻转（效果器开关按钮）──────────
        //   ⭐ fx_mask 此刻 = 0（⑦ 后复位、⑧ 只动过显示输入 st_fxmask）
        feed_frame_z(8'h71, 8'h19, 8'h02);
        chk("echo⑬-B1 0x19 翻 Bit1: fx_mask 0x00→0x02", fx_mask === 8'h02);
        chk("echo⑬-B1 fx_commit 单拍脉冲", fx_commit === 1'b1);
        @(negedge clk);
        chk("echo⑬-B1 fx_commit 仅 1 拍", fx_commit === 1'b0);
        feed_frame_z(8'h71, 8'h19, 8'h05);
        chk("echo⑬-B2 0x19 翻 Bit0+2: fx_mask 0x02→0x07", fx_mask === 8'h07);
        feed_frame_z(8'h71, 8'h19, 8'h02);
        chk("echo⑬-B3 再翻 Bit1 回落: fx_mask 0x07→0x05", fx_mask === 8'h05);

        // ── ⑬-C 八度循环变量 0x1B：base 24→0→12→24 ─────────────────────
        //   ⭐ base_semi 此刻 = 24（⑧-5 C6）；0x1B 语义 = FPGA 侧自循环
        //   ⭐⭐ base_semi 变化 ⇒ t_base 回显（⑧-5 已证）⇒ 每次循环后
        //      【必须抓掉】（⭐ 否则残留 burst 会污染 §⑭ 的 cap_n 判据）✅
        feed_frame_z(8'h71, 8'h1B, 8'h01);
        chk("echo⑬-C1 0x1B 循环: 24→0 (C4)", base_semi === 7'd0);
        chk("echo⑬-C1 base_commit 单拍脉冲", base_commit === 1'b1);
        @(negedge clk);
        chk("echo⑬-C1 base_commit 仅 1 拍", base_commit === 1'b0);
        capture_echo;
        chk("echo⑬-C1 t_base 回显 = 44 字节单帧", cap_n === 44);
        off = 0;
        expect_frame("echo⑬-C1 t_base=基准音 C4 (最低音 C3)", off, flen, 1'b0,
            "t_base", 4'd6,
            {W_JIZHUNYIN, ": ", "C4", " (", W_ZUIDIYIN, " ", "C3", ")"}, 6'd28);
        off = off + flen;
        chk("echo⑬-C1 单帧走满 burst", off === cap_n);
        feed_frame_z(8'h71, 8'h1B, 8'h01);
        chk("echo⑬-C2 0x1B 循环: 0→12 (C5)", base_semi === 7'd12);
        capture_echo;
        chk("echo⑬-C2 t_base 回显 = 44 字节单帧", cap_n === 44);
        off = 0;
        expect_frame("echo⑬-C2 t_base=基准音 C5 (最低音 C4)", off, flen, 1'b0,
            "t_base", 4'd6,
            {W_JIZHUNYIN, ": ", "C5", " (", W_ZUIDIYIN, " ", "C4", ")"}, 6'd28);
        off = off + flen;
        chk("echo⑬-C2 单帧走满 burst", off === cap_n);
        feed_frame_z(8'h71, 8'h1B, 8'h01);
        chk("echo⑬-C3 0x1B 循环: 12→24 (C6)", base_semi === 7'd24);
        capture_echo;
        chk("echo⑬-C3 t_base 回显 = 44 字节单帧", cap_n === 44);
        off = 0;
        expect_frame("echo⑬-C3 t_base=基准音 C6 (最低音 C5)", off, flen, 1'b0,
            "t_base", 4'd6,
            {W_JIZHUNYIN, ": ", "C6", " (", W_ZUIDIYIN, " ", "C5", ")"}, 6'd28);
        off = off + flen;
        chk("echo⑬-C3 单帧走满 burst", off === cap_n);

        // ═══════════════════════════════════════════════════════════════════
        // ⑭ ⭐⭐ 2026-10-29 晚 §八收口：三态配色 / 状态灯 / page1 动态字段
        // ═══════════════════════════════════════════════════════════════════
        //   判据设计（能红）：
        //   A. st_loop 三态 ⇒ t_loop 文案 + .bco/.pco 三帧成组（§八-2）
        //   B. st_fxmask ⇒ 三灯文本 + 三状态灯 .val 六帧成组（§八-4）
        //   C/D. 串口 0x11/0x16 写 fx 寄存器 ⇒ page1 z_*/t_*_val 正向回显
        //      （⭐ 0x11/0x16 写路径【不触碰 par_sel】⇒ 无 cur 帧）
        //   E. par_sel 变化 ⇒ cur 单帧；F. st_gear ⇒ t_gear+gr 双帧；
        //   G. st_pvib ⇒ t_pd+z_pd+t_pd_val 三帧（⭐ raw 值口径）
        // ═══════════════════════════════════════════════════════════════════

        // ── ⑭-A1 st_loop 0→1（录音）⇒ 文案+配色三帧 ────────────────────
        st_loop = 2'd1;
        capture_echo;
        chk("echo⑭-A1 burst 总长 = 77 字节（t_loop 39 + bco 19 + pco 19）",
            cap_n === 77);
        off = 0;
        expect_frame("echo⑭-A1 t_loop=● 循环录音中 REC", off, flen, 1'b0,
            "t_loop", 4'd6, {W_DOT, " ", W_XUNHUAN_LUYIN, " REC"}, 6'd23);
        off = off + flen;
        expect_frame("echo⑭-A1 t_loop.bco=52517（录音红）", off, flen, 3'd3,
            "t_loop", 4'd6, "52517", 6'd5);
        off = off + flen;
        expect_frame("echo⑭-A1 t_loop.pco=65535（反白）", off, flen, 3'd4,
            "t_loop", 4'd6, "65535", 6'd5);
        off = off + flen;
        chk("echo⑭-A1 三帧走满 burst", off === cap_n);

        // ── ⑭-A2 st_loop 1→2（回放）⇒ 绿底反白 ────────────────────────
        st_loop = 2'd2;
        capture_echo;
        chk("echo⑭-A2 burst 总长 = 77 字节（t_loop 40 + bco 18 + pco 19）",
            cap_n === 77);
        off = 0;
        expect_frame("echo⑭-A2 t_loop=► 循环回放中 PLAY", off, flen, 1'b0,
            "t_loop", 4'd6, {W_PLAY, " ", W_XUNHUAN_HUIFANG, " PLAY"}, 6'd24);
        off = off + flen;
        expect_frame("echo⑭-A2 t_loop.bco=6822（回放绿）", off, flen, 3'd3,
            "t_loop", 4'd6, "6822", 6'd4);
        off = off + flen;
        expect_frame("echo⑭-A2 t_loop.pco=65535（反白）", off, flen, 3'd4,
            "t_loop", 4'd6, "65535", 6'd5);
        off = off + flen;
        chk("echo⑭-A2 三帧走满 burst", off === cap_n);

        // ── ⑭-A3 st_loop 2→0（回空闲）⇒ 灰底深字 ──────────────────────
        st_loop = 2'd0;
        capture_echo;
        chk("echo⑭-A3 burst 总长 = 59 字节（t_loop 22 + bco 19 + pco 18）",
            cap_n === 59);
        off = 0;
        expect_frame("echo⑭-A3 t_loop=空闲", off, flen, 1'b0,
            "t_loop", 4'd6, W_KONGXIAN, 6'd6);
        off = off + flen;
        expect_frame("echo⑭-A3 t_loop.bco=63455（空闲浅灰）", off, flen, 3'd3,
            "t_loop", 4'd6, "63455", 6'd5);
        off = off + flen;
        expect_frame("echo⑭-A3 t_loop.pco=9509（空闲深字）", off, flen, 3'd4,
            "t_loop", 4'd6, "9509", 6'd4);
        off = off + flen;
        chk("echo⑭-A3 三帧走满 burst", off === cap_n);

        // ── ⑭-B st_fxmask 101→110 ⇒ 六帧（三灯文本 + 三状态灯）───────
        st_fxmask = 3'b110;                // dist 关(bit0=0) / chor 开(bit1=1) / dly 开(bit2=1)
        capture_echo;
        chk("echo⑭-B burst 总长 = 142 字节（31+31+30+17+17+16 六帧）",
            cap_n === 142);
        off = 0;
        expect_frame("echo⑭-Ba t_dist_st=失真 [关]", off, flen, 1'b0,
            "t_dist_st", 4'd9, {W_SHIZHEN, " [", W_GUAN, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑭-Bb t_chor_st=合唱 [开]", off, flen, 1'b0,
            "t_chor_st", 4'd9, {W_HECHANG, " [", W_KAI, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑭-Bc t_dly_st=延迟 [开]", off, flen, 1'b0,
            "t_dly_st", 4'd8, {W_YANCHI, " [", W_KAI, "]"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑭-Bd led_dist.val=0", off, flen, 1'b1,
            "led_dist", 4'd8, "0", 6'd1);
        off = off + flen;
        expect_frame("echo⑭-Be led_chor.val=1", off, flen, 1'b1,
            "led_chor", 4'd8, "1", 6'd1);
        off = off + flen;
        expect_frame("echo⑭-Bf led_dly.val=1", off, flen, 1'b1,
            "led_dly", 4'd7, "1", 6'd1);
        off = off + flen;
        chk("echo⑭-B 六帧走满 burst", off === cap_n);

        // ── ⑭-C 0x11 写增益 80 ⇒ 20480 ⇒ z_dg/t_dg_val 双帧 ───────────
        //   ⭐ ⑤ 段同款喂法：0x11 值 ×256 落 fx_gain；pct16h(20480)=31
        feed_frame_z(8'h71, 8'h11, 8'd80);
        chk("echo⑭-C 0x11=80 ⇒ fx_gain=20480", fx_gain === 16'd20480);
        capture_echo;
        chk("echo⑭-C burst 总长 = 35 字节（z_dg 14 + t_dg_val 21）",
            cap_n === 35);
        off = 0;
        expect_frame("echo⑭-C z_dg.val=31", off, flen, 1'b1,
            "z_dg", 4'd4, "31", 6'd2);
        off = off + flen;
        expect_frame("echo⑭-C t_dg_val=31%", off, flen, 1'b0,
            "t_dg_val", 4'd8, "31%", 6'd3);
        off = off + flen;
        chk("echo⑭-C 双帧走满 burst", off === cap_n);

        // ── ⑭-D 0x16 写速率 64 ⇒ 四帧（z_pr/z_vr/t_pr_val/t_vr_val）───
        //   ⭐ rate 直传（非 ×256）；pct8(64)=25 ⇒ z 帧两位数 = 14B
        feed_frame_z(8'h71, 8'h16, 8'd64);
        chk("echo⑭-D 0x16=64 ⇒ fx_rate=64", fx_rate === 8'd64);
        capture_echo;
        chk("echo⑭-D burst 总长 = 70 字节（z_pr 14 + z_vr 14 + t_pr_val 21 + t_vr_val 21）",
            cap_n === 70);
        off = 0;
        expect_frame("echo⑭-D z_pr.val=25", off, flen, 1'b1,
            "z_pr", 4'd4, "25", 6'd2);
        off = off + flen;
        expect_frame("echo⑭-D z_vr.val=25", off, flen, 1'b1,
            "z_vr", 4'd4, "25", 6'd2);
        off = off + flen;
        expect_frame("echo⑭-D t_pr_val=25%", off, flen, 1'b0,
            "t_pr_val", 4'd8, "25%", 6'd3);
        off = off + flen;
        expect_frame("echo⑭-D t_vr_val=25%", off, flen, 1'b0,
            "t_vr_val", 4'd8, "25%", 6'd3);
        off = off + flen;
        chk("echo⑭-D 四帧走满 burst", off === cap_n);

        // ── ⑭-E par_sel 7→3 ⇒ cur 单帧（反馈）────────────────────────
        par_sel = 3'd3;
        capture_echo;
        chk("echo⑭-E burst 总长 = 32 字节（仅 cur）", cap_n === 32);
        off = 0;
        expect_frame("echo⑭-E cur=EC11: 反馈 (0x14)", off, flen, 1'b0,
            "cur", 4'd3, {"EC11: ", W_FANKUI, " (0x14)"}, 6'd19);
        off = off + flen;
        chk("echo⑭-E 单帧走满 burst", off === cap_n);

        // ── ⑭-F st_gear 1→3 ⇒ t_gear+gr 双帧（档 4 [无]）──────────────
        st_gear = 2'd3;
        capture_echo;
        chk("echo⑭-F burst 总长 = 64 字节（t_gear 41 + gr 23）",
            cap_n === 64);
        off = 0;
        expect_frame("echo⑭-F t_gear=推子控制: 档 4 [无]", off, flen, 1'b0,
            "t_gear", 4'd6,
            {W_TUIZI_KONGZHI, ": ", W_DANG, " ", "4", " [", W_WU, "]"}, 6'd25);
        off = off + flen;
        expect_frame("echo⑭-F gr=档 4 [无]", off, flen, 1'b0,
            "gr", 4'd2, {W_DANG, " ", "4", " [", W_WU, "]"}, 6'd11);
        off = off + flen;
        chk("echo⑭-F 双帧走满 burst", off === cap_n);

        // ── ⑭-G st_pvib 0→40 ⇒ t_pd/z_pd/t_pd_val/j_pd 四帧（⭐ raw 口径）─
        //   ⭐ t_pd 系数据源 = 【raw st_pvib】而非百分比 ⇒ 期望 "40"（⛔ 非 15）
        //   ⭐ 2026-10-31 新文案 `深度 40%` + page0 双仓 j_pd 进度条（⭐ 四挂起）
        st_pvib = 7'd40;
        capture_echo;
        chk("echo⑭-G burst 总长 = 73 字节（t_pd 24 + z_pd 14 + t_pd_val 21 + j_pd 14）",
            cap_n === 73);
        off = 0;
        expect_frame("echo⑭-G t_pd=深度 40%", off, flen, 1'b0,
            "t_pd", 4'd4, {W_SHENDU, " ", "40", "%"}, 6'd10);
        off = off + flen;
        expect_frame("echo⑭-G z_pd.val=40", off, flen, 1'b1,
            "z_pd", 4'd4, "40", 6'd2);
        off = off + flen;
        expect_frame("echo⑭-G t_pd_val=40%", off, flen, 1'b0,
            "t_pd_val", 4'd8, "40%", 6'd3);
        off = off + flen;
        expect_frame("echo⑭-G j_pd.val=40", off, flen, 1'b1,
            "j_pd", 4'd4, "40", 6'd2);
        off = off + flen;
        chk("echo⑭-G 四帧走满 burst", off === cap_n);

        // ═════════════════════════════════════════════════════════════════
        // ⑮ ⭐⭐ 2026-10-31：《控件位置清单》新字段专项判据 ────────────────
        //   ⑮-1..3 鼓机五态文案 · ⑮-4 b_uplink 触摸回显 · ⑮-5 节拍橙点 ·
        //   ⑮-6/7 双仓速率 dHz 换算 + 进度条百分比
        // ═════════════════════════════════════════════════════════════════

        // ── ⑮-1 st_drum 开I→开II ⇒ t_drum 单帧 "Pattern II" ──────────
        st_drum = 3'b101;
        capture_echo;
        chk("echo⑮-1 burst 总长 = 26 字节（仅 t_drum）", cap_n === 26);
        off = 0;
        expect_frame("echo⑮-1 t_drum=Pattern II", off, flen, 1'b0,
            "t_drum", 4'd6, {"Pattern ", "II"}, 6'd10);
        off = off + flen;
        chk("echo⑮-1 单帧走满 burst", off === cap_n);

        // ── ⑮-2 st_drum 开II→关 ⇒ t_drum 单帧 "关" ─────────────────
        //   ⭐ 五态循环：I→II→III→IV→关→I；关档 = st_drum[2]=0
        st_drum = 3'b000;
        capture_echo;
        chk("echo⑮-2 burst 总长 = 19 字节（仅 t_drum）", cap_n === 19);
        off = 0;
        expect_frame("echo⑮-2 t_drum=关", off, flen, 1'b0,
            "t_drum", 4'd6, W_GUAN, 6'd3);
        off = off + flen;
        chk("echo⑮-2 单帧走满 burst", off === cap_n);

        // ── ⑮-3 st_kd 0→1 ⇒ t_kd 单帧 `打鼓: 开启 [键位打鼓]` ───────
        st_kd = 1'b1;
        capture_echo;
        chk("echo⑮-3 burst 总长 = 43 字节（仅 t_kd）", cap_n === 43);
        off = 0;
        expect_frame("echo⑮-3 t_kd=打鼓: 开启 [键位打鼓]", off, flen, 1'b0,
            "t_kd", 4'd4,
            {W_DAGU, ": ", W_KAIQI, " [", W_JIANWEI_DAGU, "]"}, 6'd29);
        off = off + flen;
        chk("echo⑮-3 单帧走满 burst", off === cap_n);

        // ── ⑮-4 触摸控件 15 两次 ⇒ b_uplink 关闭/开启 各一帧 ─────────
        //   ⭐ 此刻 uplink_sw=1（⑧ 前复位归 1 后无人再翻）⇒ 先翻 0 再翻 1
        fork
            feed_frame(8'h65, 8'h0F, 8'h00);
            capture_echo;
        join
        chk("echo⑮-4a 触摸后 uplink_sw=0（关闭）", uplink_sw === 1'b0);
        chk("echo⑮-4a burst 总长 = 42 字节（仅 b_uplink 关闭）", cap_n === 42);
        off = 0;
        expect_frame("echo⑮-4a b_uplink=● 实时上行: 关闭", off, flen, 1'b0,
            "b_uplink", 4'd8, {W_DOT, " ", W_SHISHI_SHANGXING, ": ", W_GUANBI},
            6'd24);
        off = off + flen;
        chk("echo⑮-4a 单帧走满 burst", off === cap_n);
        fork
            feed_frame(8'h65, 8'h0F, 8'h00);
            capture_echo;
        join
        chk("echo⑮-4b 触摸后 uplink_sw=1（再开启）", uplink_sw === 1'b1);
        chk("echo⑮-4b burst 总长 = 42 字节（仅 b_uplink 开启）", cap_n === 42);
        off = 0;
        expect_frame("echo⑮-4b b_uplink=● 实时上行: 开启", off, flen, 1'b0,
            "b_uplink", 4'd8, {W_DOT, " ", W_SHISHI_SHANGXING, ": ", W_KAIQI},
            6'd24);
        off = off + flen;
        chk("echo⑮-4b 单帧走满 burst", off === cap_n);

        // ── ⑮-5 beat 上升沿 ⇒ p_bpm 橙点翻转；下降沿零回显 ──────────
        //   ⭐ RTL：beat 变化时仅高电平才翻转 beat_dot_s 并挂 PBEAT ⇒
        //      下降沿只更新电平镜像、⛔ 不挂帧 ✅
        beat = 1'b1;
        capture_echo;
        chk("echo⑮-5a burst 总长 = 14 字节（仅 p_bpm.val=1）", cap_n === 14);
        off = 0;
        expect_frame("echo⑮-5a p_bpm.val=1（第一拍翻转）", off, flen, 1'b1,
            "p_bpm", 4'd5, "1", 6'd1);
        off = off + flen;
        chk("echo⑮-5a 单帧走满 burst", off === cap_n);
        //   ⭐ 负判据：下降沿 10 拍内 tx_start 必须恒 0（⛔ 若误挂帧会红）
        begin : beat_fall_gate
            integer g;
            beat = 1'b0;
            for (g = 0; g < 10; g = g + 1) begin
                @(negedge clk);
                if (tx_start === 1'b1) begin
                    chk("echo⑮-5b beat 下降沿零回显（tx_start 恒 0）", 1'b0);
                    disable beat_fall_gate;
                end
            end
            chk("echo⑮-5b beat 下降沿零回显（tx_start 恒 0）", 1'b1);
        end
        //   ⭐ 第二拍上升沿 ⇒ 橙点翻回 0
        beat = 1'b1;
        capture_echo;
        chk("echo⑮-5c burst 总长 = 14 字节（仅 p_bpm.val=0）", cap_n === 14);
        off = 0;
        expect_frame("echo⑮-5c p_bpm.val=0（第二拍翻回）", off, flen, 1'b1,
            "p_bpm", 4'd5, "0", 6'd1);
        off = off + flen;
        chk("echo⑮-5c 单帧走满 burst", off === cap_n);

        // ── ⑮-6 st_prate 0→2048 ⇒ t_pr+j_pr 双帧（6.5Hz / 50）────────
        //   dHz = 10+((2048×110+2048)>>12) = 65 ⇒ "6.5Hz"；
        //   j_pr = ech_pct12(2048) = (2048>>4)×100>>8 = 50
        st_prate = 12'd2048;
        capture_echo;
        chk("echo⑮-6 burst 总长 = 40 字节（t_pr 26 + j_pr 14）", cap_n === 40);
        off = 0;
        expect_frame("echo⑮-6 t_pr=速率 6.5Hz", off, flen, 1'b0,
            "t_pr", 4'd4, {W_SULU, " ", "6.5", "Hz"}, 6'd12);
        off = off + flen;
        expect_frame("echo⑮-6 j_pr.val=50", off, flen, 1'b1,
            "j_pr", 4'd4, "50", 6'd2);
        off = off + flen;
        chk("echo⑮-6 双帧走满 burst", off === cap_n);

        // ── ⑮-7 st_vrate 7→64 ⇒ t_vr+j_vr 双帧（47.7Hz / 25）────────
        //   dHz = (64×488280+32768)>>16 = 477 ⇒ "47.7Hz"；
        //   j_vr = ech_pct8(64) = 64×100>>8 = 25
        st_vrate = 8'd64;
        capture_echo;
        chk("echo⑮-7 burst 总长 = 41 字节（t_vr 27 + j_vr 14）", cap_n === 41);
        off = 0;
        expect_frame("echo⑮-7 t_vr=速率 47.7Hz", off, flen, 1'b0,
            "t_vr", 4'd4, {W_SULU, " ", "47.7", "Hz"}, 6'd13);
        off = off + flen;
        expect_frame("echo⑮-7 j_vr.val=25", off, flen, 1'b1,
            "j_vr", 4'd4, "25", 6'd2);
        off = off + flen;
        chk("echo⑮-7 双帧走满 burst", off === cap_n);

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

    // ⭐⭐ 看门狗：主流程若挂死（等一个永远不会来的 tx_start）⇒ 判 FAIL
    //    而非仿真无声超时 ✅
    initial begin
        #20_000_000;
        $display("FAIL: tb_uart_ui watchdog timeout（主流程挂死）");
        $finish;
    end

endmodule

`default_nettype wire
