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

module tb_uart_ui_followup;

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
    reg [2:0] st_hold=0;
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

    localparam [95:0] W_LISA_RU = 96'he69d8ee890a8e5a682e59bbe;
    localparam [47:0] W_PINPU = 48'he9a291e8b0b1;
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
        .st_hold_i(st_hold),
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
        input [87:0]      name_str;  // ⭐ 控件名（右对齐，最长 9B = t_dist_st）
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


    integer n;reg [7:0] expected_percent;
    task rate_pair(input [7:0] v);
        begin st_vrate=v;capture_echo;off=0;
        expected_percent=(v>=31)?99:((v*100)>>5);
        if(v==0)begin
            expect_frame("volume gauge zero",off,flen,1,"z_vr",4'd4,"0",6'd1);off=off+flen;
            expect_frame("volume percent zero",off,flen,0,"t_vr_val",4'd8,"0%",6'd2);off=off+flen;
            expect_frame("volume Hz zero",off,flen,0,"t_vr",4'd4,{W_SULU," 0.0Hz"},6'd12);off=off+flen;
            expect_frame("volume bar zero",off,flen,1,"j_vr",4'd4,"0",6'd1);off=off+flen;
        end else begin
            expect_frame("volume gauge full",off,flen,1,"z_vr",4'd4,"99",6'd2);off=off+flen;
            expect_frame("volume percent full",off,flen,0,"t_vr_val",4'd8,"99%",6'd3);off=off+flen;
            expect_frame("volume Hz actual max remains 23.1Hz",off,flen,0,"t_vr",4'd4,{W_SULU," 23.1Hz"},6'd13);off=off+flen;
            expect_frame("volume bar full",off,flen,1,"j_vr",4'd4,"99",6'd2);off=off+flen;
        end
        chk("volume rate complete synchronized burst",off===cap_n);end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
        fork feed_frame(8'h88,0,0);capture_echo;join
        rate_pair(0);rate_pair(31);
        st_prate=4095;capture_echo;off=0;
        expect_frame("pitch gauge full",off,flen,1,"z_pr",4'd4,"99",6'd2);off=off+flen;
        expect_frame("pitch percentage follows physical raw input",off,flen,0,"t_pr_val",4'd8,"99%",6'd3);off=off+flen;
        expect_frame("pitch original Hz mapping preserved",off,flen,0,"t_pr",4'd4,{W_SULU," 12.0Hz"},6'd13);off=off+flen;
        expect_frame("pitch bar full",off,flen,1,"j_pr",4'd4,"99",6'd2);off=off+flen;
        chk("pitch rate complete synchronized burst",off===cap_n);
        st_hold=3'b010;capture_echo;off=0;
        expect_frame("current pitch gear is locked",off,flen,0,"t_lock",4'd6,48'hE99481E5AE9A,6'd6);off=off+flen;
        expect_frame("11 character control name is not truncated",off,flen,0,"t_lock_info",4'd11,{48'hE99481E5AE9A," [1]"},6'd10);off=off+flen;
        chk("both lock fields complete",off===cap_n);
        st_hold=3'b110;capture_echo;off=0;
        expect_frame("pitch remains locked",off,flen,0,"t_lock",4'd6,48'hE99481E5AE9A,6'd6);off=off+flen;
        expect_frame("independent locks coexist",off,flen,0,"t_lock_info",4'd11,{48'hE99481E5AE9A," [1][2]"},6'd13);off=off+flen;
        chk("coexisting lock fields complete",off===cap_n);
        st_hold=3'b001;capture_echo;off=0;
        expect_frame("pitch unlocked independently from transpose",off,flen,0,"t_lock",4'd6,96'hE5AE9EE697B6E7949FE69588,6'd12);off=off+flen;
        expect_frame("summary excludes transpose lock",off,flen,0,"t_lock_info",4'd11,{48'hE99481E5AE9A," [",W_WU,"]"},6'd12);off=off+flen;
        chk("transpose does not pollute vibrato summary",off===cap_n);
        st_pedal=1;capture_echo;off=0;
        expect_frame("pedal concise on",off,flen,0,"t_pedal",4'd7,"[PEDAL ON]",6'd10);off=off+flen;chk("pedal on whole frame",off===cap_n);
        st_pedal=0;capture_echo;off=0;
        expect_frame("pedal concise off",off,flen,0,"t_pedal",4'd7,"[PEDAL OFF]",6'd11);off=off+flen;chk("pedal off whole frame",off===cap_n);
        for(n=0;n<4;n=n+1)begin
            st_drum={1'b0,n[1:0]};capture_echo;off=0;
            case(n)
              0:expect_frame("off drum still displays selected I",off,flen,0,"t_drum",4'd6,"Pattern I",6'd9);
              1:expect_frame("off drum still displays selected II",off,flen,0,"t_drum",4'd6,"Pattern II",6'd10);
              2:expect_frame("off drum still displays selected III",off,flen,0,"t_drum",4'd6,"Pattern III",6'd11);
              3:expect_frame("off drum still displays selected IV",off,flen,0,"t_drum",4'd6,"Pattern IV",6'd10);
            endcase
            off=off+flen;chk("drum text frame complete",off===cap_n);
        end
        st_scope=1;capture_echo;off=0;
        expect_frame("HDMI shows current Lissajous mode only",off,flen,0,"t_hdmi",4'd6,{"HDMI: ",W_LISA_RU},6'd18);off=off+flen;
        chk("Lissajous complete UTF8 frame",off===cap_n);
        st_scope=2;capture_echo;off=0;
        expect_frame("HDMI shows current spectrum mode only",off,flen,0,"t_hdmi",4'd6,{"HDMI: ",W_PINPU},6'd12);off=off+flen;
        chk("long to short spectrum frame has no stale suffix",off===cap_n);
        st_scope=0;capture_echo;off=0;
        expect_frame("HDMI wraps back to waveform only",off,flen,0,"t_hdmi",4'd6,{"HDMI: ",48'hE6B3A2E5BDA2},6'd12);off=off+flen;
        chk("waveform complete UTF8 frame",off===cap_n);
        repeat(20)begin @(negedge clk);chk("unchanged HDMI mode does not resend",tx_start!==1);end
        // An in-flight text frame remains intact while the next mode is selected.
        fork
            begin st_scope=1;repeat(12)@(negedge clk);st_scope=2;end
            capture_echo;
        join
        off=0;
        expect_frame("in-flight Lissajous snapshot stays intact",off,flen,0,"t_hdmi",4'd6,{"HDMI: ",W_LISA_RU},6'd18);off=off+flen;
        expect_frame("next frame reflects new spectrum mode",off,flen,0,"t_hdmi",4'd6,{"HDMI: ",W_PINPU},6'd12);off=off+flen;
        chk("both successive mode frames are complete",off===cap_n);
        if(errors)$fatal(1,"FAIL: %0d focused UART checks",errors);
        $display("PASS: new HMI rate ranges, lock fields and concise text (%0d checks)",nchecks);$finish;
    end
    initial begin #20000000;$fatal(1,"FAIL: followup watchdog");end
endmodule
