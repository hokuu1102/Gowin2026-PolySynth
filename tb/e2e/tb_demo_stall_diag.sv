`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_demo_stall_diag.sv · 【诊断型】"自检和弦 → 按键"整链 + `note_manager` 逐次状态打印
//
// ⭐ 唯一目标：回答一个问题 —— **"按键不响的时候，FSM / 队列到底停在哪？"**
//   ⛔ 本 tb **不修任何东西**、⛔ **不改 `rtl/`**（只用例化参数覆盖 + 一处 `defparam`，
//      见下方 §参数）。
//
// ── 复现的症状（用户上板实测、可复现、两次上电一致）─────────────────────────
//   ① 复位后自检和弦（A4+C#5+E5）正常响                                  ✅
//   ② ⭐ 自检和弦【响完】之后，前几下按键全都不响
//   ③ ⭐ 要按十几下才第一次出声，且"按序继承"（先按的先响，音高滞后于按键）
//   ④ ⭐ 同轴按 / 异轴按表现一样
//   ⑤ 另有挂音（"按别的键的话，挂音可能会消失"）
//
// ── 场景（⭐ 按任务书）──────────────────────────────────────────────────────
//   复位 → 等 autotare → 等自检和弦整段走完（`demo_fired`）→ 等队列排空
//   → **同一个键按 3 次**（KEY_A = axis 0）→ **另一个键按 3 次**（KEY_B = axis 8）
//   每次按键 = 按下 → 等"该轴有 voice 被 gate" → 保持 → 松开 → 等它被识别 → 等不应期清零
//
// ── 观测的层次路径（⭐ 全部**已按 rtl/ 核对**，见回报）────────────────────────
//   `u_top.g_sound.<...>`              —— 顶层 `top.v` 的 generate 块 `g_sound`
//   `u_top.g_sound.u_note_manager.*`   —— `note_manager`（`top.v:3252`）
//   `u_top.g_sound.u_seq_arb.cnt_q`    —— `seq_arb` 队列深度（`top.v:2994`）
//   `u_top.g_sound.u_evt_merge.cnt_q`  —— `evt_merge` 队列深度（`top.v:3172`）
//   ⭐ 逐轴"有没有被 gate" **只用输出端口** `nm_gate` / `nm_axis`
//      （`note_manager.voice_gate_o` / `voice_axis_o`）⇒ ⛔ 不依赖内部数组绑定。
//   ⭐ 而 `free_cnt` / `live_cnt` / `gate_cnt` / `retrig_low_cnt` 按任务书要求
//      **自己从 `gate_r[i]` / `retrig_low[i]` / `env_active_r[i]` 算**。
//
// ── 判据（⭐ 每条都能失败 —— `K-56` / `C21`）─────────────────────────────────
//   A ⭐ 自检和弦结束、按键之前：`fifo_cnt == 0` **且** `state == ST_IDLE`
//   B ⭐ 每次按键之后 `N_TICK` 个 `sample_tick` 内：**该轴必须有 voice 被 gate**
//   C1⭐ `fifo_cnt` 任何时刻都不许超过 `FIFO_DEPTH`
//   C2⭐ 按键停止后 `fifo_cnt` 不许持续增长（⇒ FSM 确实在排空）
//   C3⭐ 按键停止后队列必须在有限时间内**回到 0**
//
// ── ⭐⭐ 参数（⛔ 不改 `rtl/`，⭐ 只在例化处覆盖 + 一处 `defparam`）────────────
//   | 参数                 | 上板真值（`top.v` 默认）  | 本 tb     | 为什么 |
//   |----------------------|--------------------------|-----------|--------|
//   | `DEMO_NOTE_DELAY`    | 2_000_000（40 ms）       | 10_000    | 上板整段 52M 拍 ⇒ 仿真跑不动 |
//   | `DEMO_HOLD_CYC`      | 50_000_000（1 s）        | 20_000    | 同上 |
//   | `AUTOTARE_DELAY_CLK` | 10_000_000（200 ms）     | 50_000    | 同上 |
//   | `METRONOME_ON`       | 1                        | **0**     | ⭐ 上电 `met_on_r=0` ⇒ 本来就不响；显式关掉 ⇒ 队列里⛔ 不混入源 B 事件 |
//   | `DPOS_DIAG`          | 0                        | 0         | ⭐ 显式声明（`K-161`：它会拖慢所有顶层 tb） |
//   | `SOURCE_A_SEL`       | 0                        | 0         | ⭐ 走 `seq_arb`（手弹＋演示并存）＝上板档 |
//   | `SPAN_*` 三项        | 见 `top.v`               | 小值      | ⭐ 本 tb ⛔ 不验 span（与 `tb_e2e` 同手法） |
//
//   🔴🔴 **`defparam` 一处**：`u_top.g_sound.u_event_extract.REFRACT_N`：**60 → 4**
//      ⭐ 为什么必须改小（⭐ 这是**仿真可行性**问题，⛔ 不是掩盖缺陷）：
//        · `event_extract.v:301-303`：同轴 `note_on` 之后 `refr[axis] <= REFRACT_N`，
//          而 `refr` **每帧减 1**（`:232-235`）⇒ 不应期 = `REFRACT_N` 帧
//        · `adc_farm` 一帧 = `CLK_HZ/CHANNEL_RATE_HZ` = 25_000 拍 = **500 µs**
//          ⇒ 上板 `REFRACT_N=60` ⇒ 不应期 **30 ms**
//        · ⇒ ⭐ **同轴连按（间隔几 ms）按【设计】会被吞掉**（`:299-301`）
//          ⇒ ⭐ 若不动它，"同一个键按 3 次"里第 2/3 次**必然**没有事件
//          ⇒ 🔴 判据 B 会**假红**（`C21`：判据必须能失败，但⛔ 不能因设计行为而失败）
//        · 取 **4 帧 = 2 ms** ⇒ ⭐ 保留"去抖"语义、⭐ 又让 3 次连按可仿
//      📌 **另外**：本 tb 在每次同轴再按之前**显式轮询 `refr[ax]==0`**（带上限）
//         ⇒ ⭐ 即使这一行 `defparam` 没生效，也只是**变慢**，⛔ 不会假红。
//      ⚠️ 它**只影响 `event_extract` 的输入去抖**，⛔ 与被诊断的
//         `note_manager` 分配 FSM / 队列**没有任何逻辑关系**。
//
//   ⚠️ **帧率没有改**（`adc_farm.CHANNEL_RATE_HZ` 仍是 `top.v` 的 2000）
//      ⇒ ⭐ 一帧 = 500 µs、每轴每帧刷新一次、`snap_valid` 每帧一次
//      ⇒ ⭐ "按下 → 被看见"的最坏延迟 = **1 帧 = 25_000 拍**（判据 B 的窗口按它算）
//
// ── ⭐⭐ 怎么读结果（"停在哪" → 去查哪一行 RTL）─────────────────────────────
//   | DIAG 里看到的样子                         | 含义 | 去查（`文件:行`） |
//   |-------------------------------------------|------|-------------------|
//   | `fifo_cnt` 恒 0、`ee_cnt` 不涨            | 事件根本没到采集链出口 | `rtl/w3a/event_extract.v:288`（`snap_valid_i` 才开扫）· `:299`（`key_on` 未清）· `:301`（`refr` 未清）· `rtl/w3a/axis_snapshot.v:193`（`snap_valid_o` 由 `frame_done` 来） |
//   | `ee_cnt` 涨、`ev` 不涨                    | 事件卡在 `seq_arb`/`evt_merge` | `rtl/w3c/seq_arb.v:247`（`will_overflow`）· `rtl/w3c/evt_merge.v:267` · 看 DIAG 的 `sa_drop`/`mg_drop` |
//   | `ev` 涨、`fifo_cnt` 也涨、`state` 恒 0    | 队列在涨但 FSM 不取 | `rtl/w3b/note_manager.v:457-458`（`fifo_push`/`fifo_pop`）· `:947`（`ST_IDLE` 只认 `!fifo_empty`） |
//   | `state` 卡在 1（`ST_DECIDE`）             | 出边条件全不成立 | `rtl/w3b/note_manager.v:961`（`KIND_OFF`）· `:999`（`same_valid`）· `:1027`（`else` 启动扫描） |
//   | `state` 卡在 2（`ST_SCAN`）               | 扫描计数不前进 | `rtl/w3b/note_manager.v:1090`（`scan_cnt == SCAN_LAST`） |
//   | `state` 卡在 5（`ST_RETRIG`）             | 压低位没被 tick 抬起 | `rtl/w3b/note_manager.v:1078`（出口）· `:928-938`（(f) 段等 `sample_tick_i`） |
//   | `best_valid` **恒 0**（`best_seen=0`）    | 32 路候选**一个都没通过** ⇒ 事件被丢 | `rtl/w3b/note_manager.v:644`（`cand_ok`）· `:636`（`cand_foreign`）· `:498`（`pool_mask`）· `:1114`（`best_valid` 守卫 ⇒ **静默丢音**） |
//   | `retrig_low_cnt` **恒 ≥ 1**               | 重触发压低没解除 ⇒ 该 voice 永久哑 | `rtl/w3b/note_manager.v:935-938`（要 `sample_tick_i`）· `:1048-1049`（`ST_RETRIG` 置位） |
//   | `gate_cnt` 涨但 `live_cnt` 不涨           | 门开了但包络没起 | `rtl/w3b/adsr.v`（`retrig_reset` 优先级）· `rtl/w3b/envelope_bank.v` |
//   | `sa_demo`/`mg_drop` 非 0                  | 上游**丢事件**（队列溢出） | `rtl/w3c/seq_arb.v:247` · `rtl/w3c/evt_merge.v:267` |
//   | `event_lost_o` 非 0                       | `note_manager` 队列溢出丢音 | `rtl/w3b/note_manager.v:445`（`fifo_full`）· `:790`（`lost_cnt_r`） |
//   ⚠️ **本 tb 只产出证据，⛔ 不下"根因"结论。**
//
// ── ⚠️ 预算（⭐ 请先读）──────────────────────────────────────────────────────
//   ⭐ 预计 **~0.8M 拍**（≈ 20~35 s @ 实测 ~40k 拍/秒）⇒ ✅ 在 `tb_all.ps1` 的
//      **120 s 默认预算**内。若 `defparam` 那行没生效（不应期仍是 30 ms），
//      会变成 ~6M 拍 ⇒ 🔴 **会超预算**（⭐ 日志开头会打印实测帧周期与不应期，⭐ 一眼可辨）。
//   📌 要更省：把 `N_PRESS` 改小（每键按几次）。
// ─────────────────────────────────────────────────────────────────────────────

module tb_demo_stall_diag;

    // ═══════════════════════════════════════════════════════════════════════
    // 参数
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer POLY_TARGET = 32;      // ⭐ 必须与 `top.v` 的 `POLY_TARGET` 一致
    localparam integer FIFO_DEPTH  = 32;      // ⭐ 必须与 `note_manager.FIFO_DEPTH` 一致
    localparam integer AXIS_W      = 4;

    // ⭐ 自检和弦 / autotare（⭐ 只为仿真可行性而缩小，见文件头 §参数）
    localparam integer DEMO_DELAY   = 10_000;
    localparam integer DEMO_HOLD    = 20_000;
    localparam integer AUTOTARE_DLY = 50_000;

    // ⭐⭐ 判据 B 的窗口：`N_TICK` 个 `sample_tick`（1 tick = 1024 拍 = 20.48 µs）
    //   ⭐ 依据：按下 → 被 `event_extract` 看见的最坏延迟 = **1 帧**（= 25_000 拍
    //      = 24.4 tick，`adc_farm` 帧周期 500 µs）+ 处理（~100 拍）
    //   ⇒ ⭐ 取 **96 tick = 1.97 ms**（≈ 3.9 帧）⇒ ✅ 余量 3.9×
    localparam integer N_TICK = 96;

    // ⭐ 按键时序
    localparam integer N_PRESS    = 3;        // ⭐ 每个键按几次（任务书：3）
    localparam integer PRESS_HOLD = 50_000;   // ⭐ 看到 gate 后再保持 1 ms（≈ 2 帧）
    localparam integer REL_SETTLE = 5_000;    // ⭐ 松开被识别后再等 0.1 ms
    //   ⭐ 键位（⭐ 用**定宽** localparam，⛔ 不对 `integer` 参数做位选 —— `K-91`）
    localparam [AXIS_W-1:0] KEY_A = 4'd0;     // ⭐ 键 A = 片0 CH0 = 轴 0（自检和弦用过的轴）
    localparam [AXIS_W-1:0] KEY_B = 4'd8;     // ⭐ 键 B = 片1 CH0 = 轴 8（自检和弦没用过的轴）

    // ⭐ `defparam` 的目标值（⭐ 见文件头：60 帧 = 30 ms 会把同轴连按吞掉）
    localparam integer TB_REFRACT_N = 4;

    // ⭐ 轮询上限（⛔ 不许"无声挂死" —— `K-94`）
    localparam integer AT_GUARD      = 400;      // × 1000 拍
    localparam integer DEMO_GUARD    = 400;      // × 1000 拍
    localparam integer TAIL_GUARD    = 40_000;   // 拍（等队列排空）

    integer errors = 0;

    // ═══════════════════════════════════════════════════════════════════════
    // 时钟 / 复位 / DUT 端口
    // ═══════════════════════════════════════════════════════════════════════
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi;
    wire [5:0] spi_cs_n;                         // ⭐ 由 `top` 驱动（⛔ 本 tb 不 assign）
    wire miso_l, miso_r;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        // ⚠️ **必须为 1** —— `DEMO_CHORD_ON == 0` 会走 `g_silent` 分支，
        //    ⚠️ 那条分支**整条合成链都不例化** ⇒ `g_sound.*` 层次不存在
        //    ⇒ 🔴 本 tb 的所有探针 bind 失败（`tb_e2e` 已实测踩过）。
        .DEMO_CHORD_ON     (1),
        .DEMO_NOTE_DELAY   (DEMO_DELAY),
        .DEMO_HOLD_CYC     (DEMO_HOLD),
        .SOURCE_A_SEL      (0),               // ⭐ 0 = 走 `seq_arb`（手弹 + 演示）＝上板档
        .SEL_DRUM          (0),
        .METRONOME_ON      (0),               // ⭐ 源 B 静音（上电 `met_on_r=0` ⇒ 等价）
        .DPOS_DIAG         (0),               // ⭐ `K-161`：⛔ 不要为"顺手"置 1
        .AUTOTARE_DELAY_CLK(AUTOTARE_DLY),
        // ⭐ 缩短 `calib_span` 的等待（⭐ 本 tb ⛔ 不验 span 语义，与 `tb_e2e` 同手法）
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .timbre_btn_i  (1'b1),                // ⭐ 显式接：未按下（⛔ 不留悬空 ⇒ 无 X）
        .pluck_up_i    (1'b0),                // ⭐ 显式接：⛔ 不让拨弦比较器产生假边沿
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
        .uart_rx       (1'b1),                // ⭐ 串口空闲高
        .uart_tx       ()
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ `defparam`：把 `event_extract` 的不应期从 60 帧（30 ms）缩到 4 帧（2 ms）
    //   🔴 **理由见文件头 §参数** —— ⛔ 不是掩盖缺陷，是**让"同轴连按"可仿**。
    //   ⚠️ 它只影响**输入去抖**；本 tb 还会显式轮询 `refr[]` ⇒ 即使本行无效
    //      也只是变慢，⛔ 不会假红。
    // ═══════════════════════════════════════════════════════════════════════
    defparam u_top.g_sound.u_event_extract.REFRACT_N = TB_REFRACT_N;

    // ═══════════════════════════════════════════════════════════════════════
    // ADC 从机（⭐ 复用队友已验证的 `mcp3208_model`，⭐ 用**逐通道**覆盖 ⇒ 能按单键）
    //   ⭐ 电平换算（`tb_e2e` 的口径）：松手 raw 0x7C1(1985) → `pos` 0（tare 后）
    //      按下 raw 0x4D9(1241) → `pos` 744 ≫ `TRIG_TH`=64 ✅
    //   ⚠️ `ovr_en_i` 必须为 0 ⇒ 走 `ch_mask_i` 逐通道路径（⛔ 整片覆盖表达不了"单键"）
    // ═══════════════════════════════════════════════════════════════════════
    localparam [11:0] RAW_REST = 12'h7C1;
    localparam [11:0] RAW_DOWN = 12'h4D9;

    reg [7:0]  l_ch_mask = 8'd0;      // ⭐ 片 0（轴 0..7）
    reg [7:0]  r_ch_mask = 8'd0;      // ⭐ 片 1（轴 8..15）
    reg [11:0] l_ch_val  = RAW_DOWN;
    reg [11:0] r_ch_val  = RAW_DOWN;

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
    //   ⚠️ `spi_cs_n[5:2]` **由 `top.v` 自己驱动**（`top.v:1389`）⇒ ⛔ 本 tb **不 assign**
    //      （`tb_e2e` 那里有一条多余的 `assign`，会与 `top` 形成多驱动 ⇒ 本 tb 不重复它）

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 层次别名（⭐ 只为可读性；⛔ 不改任何行为）
    // ═══════════════════════════════════════════════════════════════════════
    //   —— 输出端口（⭐ 最稳，⛔ 不依赖内部数组）——
    wire [POLY_TARGET-1:0]      nm_gate = u_top.g_sound.nm_gate;      // voice_gate_o
    wire [POLY_TARGET*AXIS_W-1:0] nm_axis = u_top.g_sound.nm_axis;    // voice_axis_o
    wire [POLY_TARGET-1:0]      nm_active = u_top.g_sound.nm_active;  // voice_active_o
    //   —— `note_manager` 内部（⭐ 诊断必需）——
    wire [2:0]  nm_state     = u_top.g_sound.u_note_manager.state;
    wire [5:0]  nm_fifo_cnt  = u_top.g_sound.u_note_manager.fifo_cnt;
    wire [4:0]  nm_fifo_wr   = u_top.g_sound.u_note_manager.fifo_wr;
    wire [4:0]  nm_fifo_rd   = u_top.g_sound.u_note_manager.fifo_rd;
    wire        nm_best_vld  = u_top.g_sound.u_note_manager.best_valid;
    wire        nm_same_vld  = u_top.g_sound.u_note_manager.same_valid;
    wire [1:0]  nm_cur_kind  = u_top.g_sound.u_note_manager.cur_kind;
    wire [3:0]  nm_cur_axis  = u_top.g_sound.u_note_manager.cur_axis;
    wire [2:0]  nm_cur_src   = u_top.g_sound.u_note_manager.cur_src;
    wire [4:0]  nm_scan_cnt  = u_top.g_sound.u_note_manager.scan_cnt;
    wire        nm_same_en_r = u_top.g_sound.u_note_manager.same_en_r;
    wire [4:0]  nm_same_idx  = u_top.g_sound.u_note_manager.same_idx_r;
    wire        nm_cmt_en_r  = u_top.g_sound.u_note_manager.cmt_en_r;
    wire [4:0]  nm_cmt_idx   = u_top.g_sound.u_note_manager.cmt_idx_r;
    wire        nm_lost      = u_top.g_sound.u_note_manager.event_lost_o;
    wire [7:0]  nm_lost_cnt  = u_top.g_sound.u_note_manager.event_lost_cnt_o;
    //   —— 上游可观测（⭐ "事件有没有到" 的判据）——
    wire [15:0] sa_cnt    = u_top.g_sound.u_seq_arb.cnt_q;
    wire [15:0] mg_cnt    = u_top.g_sound.u_evt_merge.cnt_q;
    wire [15:0] sa_drop   = u_top.g_sound.sa_drop_cnt;
    wire [15:0] mg_drop   = u_top.g_sound.mg_drop_cnt;
    wire        mg_ovf    = u_top.g_sound.mg_overflow;
    wire [15:0] sa_demo   = u_top.g_sound.sa_demo_cnt;
    wire [15:0] sa_live   = u_top.g_sound.sa_live_cnt;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 计数器 / 监视器
    // ═══════════════════════════════════════════════════════════════════════
    integer   ee_cnt = 0;          // `event_extract` 出的事件数（⭐ W3a 采集链出口）
    integer   ev_cnt = 0;          // 进入 `note_manager` 的事件数（`note_valid_i`）
    integer   ev_on  = 0, ev_off = 0;
    reg [15:0] ee_axis_mask = 16'd0;   // ⭐ 哪些轴出过事件（sticky）
    reg [15:0] ev_axis_mask = 16'd0;
    reg [15:0] gate_seen_mask = 16'd0; // ⭐ 哪些轴**有过** voice 被 gate（sticky）
    reg        best_seen = 1'b0;       // ⭐ 本窗口内 `best_valid` 曾经为 1
    integer    fifo_max  = 0;
    reg        fifo_over = 1'b0;
    time       fifo_over_t = 0;
    //   ⭐ 按下瞬间读到的 `event_extract.refr[ax]`（帧数）—— ⭐ 打印 + 算等待上限用
    //      ⚠️ **必须声明在用到它的 task 之前**（⭐ 本项目的老坑：Verilog 先声明后使用）
    integer    refr_frames = 0;

    reg [2:0]  state_d = 3'd0;
    integer    mi;

    always @(posedge clk) begin
        // ── 事件计数（⭐ 分清"卡在采集链"还是"卡在合流"）────────────────
        if (u_top.g_sound.ee_valid) begin
            ee_cnt = ee_cnt + 1;
            ee_axis_mask[u_top.g_sound.ee_axis] = 1'b1;
        end
        if (u_top.g_sound.mg_evt_valid) begin
            ev_cnt = ev_cnt + 1;
            ev_axis_mask[u_top.g_sound.mg_evt_axis] = 1'b1;
            if (u_top.g_sound.mg_evt_kind == 2'd0)      ev_on  = ev_on  + 1;
            else if (u_top.g_sound.mg_evt_kind == 2'd1) ev_off = ev_off + 1;
        end

        // ── ⭐ "该轴有 voice 被 gate"：**只用输出端口** `nm_gate`/`nm_axis` ──
        //    ⭐ `voice_gate_o = gate_mask = gate_r & ~retrig_low`（`note_manager.v:418`）
        if (|nm_gate)
            for (mi = 0; mi < POLY_TARGET; mi = mi + 1)
                if (nm_gate[mi]) gate_seen_mask[nm_axis[mi*AXIS_W +: AXIS_W]] = 1'b1;

        if (nm_best_vld) best_seen = 1'b1;

        // ── 判据 C1：`fifo_cnt` 不许超过 `FIFO_DEPTH` ────────────────────
        if (nm_fifo_cnt > FIFO_DEPTH) begin
            if (!fifo_over) fifo_over_t = $time;
            fifo_over = 1'b1;
        end
        if (nm_fifo_cnt > fifo_max) fifo_max = nm_fifo_cnt;

        // ── ⭐ FSM 迁移轨迹（⭐ "定位 FSM 停在哪" 的直接证据）─────────────
        if (state_d !== nm_state) begin
            $display("  [FSM  ] t=%0t state %0d -> %0d  fifo_cnt=%0d cur_kind=%0d cur_axis=%0d cur_src=%0d best_valid=%b",
                     $time, state_d, nm_state, nm_fifo_cnt, nm_cur_kind,
                     nm_cur_axis, nm_cur_src, nm_best_vld);
            state_d = nm_state;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // 函数 / 任务
    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ `free_cnt` / `live_cnt` / `gate_cnt` / `retrig_low_cnt`
    //    —— ⭐ 按任务书要求**自己算**（⭐ 不依赖 `free_mask` 之类可能不存在的名字）
    function integer cnt_gate;
        integer i;
        begin
            cnt_gate = 0;
            for (i = 0; i < POLY_TARGET; i = i + 1)
                if (u_top.g_sound.u_note_manager.gate_r[i]) cnt_gate = cnt_gate + 1;
        end
    endfunction

    function integer cnt_retrig;
        integer i;
        begin
            cnt_retrig = 0;
            for (i = 0; i < POLY_TARGET; i = i + 1)
                if (u_top.g_sound.u_note_manager.retrig_low[i]) cnt_retrig = cnt_retrig + 1;
        end
    endfunction

    // ⭐ `live` = `gate_r | retrig_low | env_active_r`（= `note_manager.v:419` 的 `live_mask`）
    function integer cnt_live;
        integer i;
        begin
            cnt_live = 0;
            for (i = 0; i < POLY_TARGET; i = i + 1)
                if (u_top.g_sound.u_note_manager.gate_r[i]      |
                    u_top.g_sound.u_note_manager.retrig_low[i]  |
                    u_top.g_sound.u_note_manager.env_active_r[i]) cnt_live = cnt_live + 1;
        end
    endfunction

    // ⭐ "该轴当前有没有 voice 被 gate"（⭐ 只用输出端口）
    //   ⚠️ 调用方**每 16 拍查一次**（⭐ 省仿真时间）—— ⭐ 安全：`nm_gate` 一旦置起
    //      至少保持到下一个 `sample_tick`（1024 拍）或 `note_off`，⛔ 不会漏掉 16 拍的窗口。
    function axis_gated;
        input [AXIS_W-1:0] ax;
        integer i;
        reg     f;
        begin
            f = 1'b0;
            for (i = 0; i < POLY_TARGET; i = i + 1)
                if (!f && nm_gate[i] && (nm_axis[i*AXIS_W +: AXIS_W] == ax)) f = 1'b1;
            axis_gated = f;
        end
    endfunction

    task chk;
        input [1023:0] name;
        input          cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ⭐⭐ `[DIAG]` —— ⭐ 任务书要求的字段，**一字不改**
    task print_diag;
        input [255:0] tag;
        integer lc;
        begin
            #1;                                    // ⭐ 让所有 delta 收敛后再读
            lc = cnt_live();
            $display("  [TAG  ] %0s", tag);
            $display("[DIAG] t=%0t ev=%0d  state=%0d fifo_cnt=%0d fifo_wr=%0d fifo_rd=%0d",
                     $time, ev_cnt, nm_state, nm_fifo_cnt, nm_fifo_wr, nm_fifo_rd);
            $display("       best_valid=%b same_valid=%b cur_kind=%0d cur_axis=%0d cur_src=%0d",
                     nm_best_vld, nm_same_vld, nm_cur_kind, nm_cur_axis, nm_cur_src);
            $display("       free_cnt=%0d live_cnt=%0d gate_cnt=%0d retrig_low_cnt=%0d",
                     POLY_TARGET - lc, lc, cnt_gate(), cnt_retrig());
            // ⭐ 补充（⭐ 用来分清"卡在哪一级"，⛔ 不替代上面三条）
            $display("       (x) ee_cnt=%0d mg_ev_cnt=%0d sa_cnt=%0d mg_cnt=%0d lost=%b/%0d sa_drop=%0d mg_drop=%0d ovf=%b",
                     ee_cnt, ev_cnt, sa_cnt, mg_cnt, nm_lost, nm_lost_cnt, sa_drop, mg_drop, mg_ovf);
            $display("       (x) best_seen=%b scan_cnt=%0d same_en=%b same_idx=%0d cmt_en=%b cmt_idx=%0d gate_seen=0x%04h ev_ax=0x%04h",
                     best_seen, nm_scan_cnt, nm_same_en_r, nm_same_idx, nm_cmt_en_r,
                     nm_cmt_idx, gate_seen_mask, ev_axis_mask);
            $display("       (x) nm_active=0x%08h env_active=0x%08h pos[0]=%0d pos[8]=%0d af0_pol=%0d cal0_val=%0d",
                     nm_active, u_top.g_sound.env_active,
                     u_top.g_sound.as_pos[0 +: 12], u_top.g_sound.as_pos[8 +: 12],
                     u_top.g_sound.af0_pol, u_top.g_sound.cal0_val);
        end
    endtask

    // ⭐ 有上限的轮询（⭐ 防"无声挂死" —— `K-94`）
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

    task wait_demo_done;
        integer g;
        begin
            g = 0;
            while ((u_top.g_sound.demo_fired !== 1'b1) && (g < DEMO_GUARD)) begin
                repeat (1000) @(posedge clk);
                g = g + 1;
            end
            if (u_top.g_sound.demo_fired !== 1'b1)
                $display("FAIL: demo chord never finished (demo_fired never 1) within %0d cycles", g * 1000);
            else
                $display("  [demo ] demo_fired=1 (demo_step=%0d) after ~%0d cycles; board value = 40 ms + 1 s",
                         u_top.g_sound.demo_step, g * 1000);
        end
    endtask

    // ⭐ 实测帧周期（⭐ **相邻两条** `af_frame_done` 上升沿之间的拍数）—— ⭐ 用来算轮询上限与打印预算
    //   🔴🔴 老实现（⛔ 已修，这是**本 tb 自己的 bug**）：两个 `while` 都只看 `af_frame_done`
    //      的【电平】—— 第 1 个循环停在"脉冲那一拍"，第 2 个循环在【同一拍】重新判断，
    //      看到的还是【同一条沿】⇒ `c` 恒 0 ⇒ `frame_period = 0`
    //      ⇒ 🔴 下游 `wait_refr_clear(ax, (refr_frames + 4) * 0)` 的上界变成 **0**
    //      ⇒ 🔴 轮询循环【0 拍】就退出 ⇒ 假报"不应期 0 拍内没清"（⭐ 判据没错，**上界**坏了）。
    //   ⭐ 现在必须【先看到它落回 0】（`seen_low` 守卫）才允许结束计数
    //      ⇒ ⭐ 数的必然是**相邻两条**上升沿。
    //   📌 `af_frame_done` 是 `mcp3208_scanner` 的**单拍脉冲**
    //      （`rtl/drivers/mcp3208_scanner.sv:92` 默认清 0、`:129` 只在 ch7 那一拍置 1）。
    localparam integer FRAME_GUARD  = 4_000_000;   // ⭐ 单次等待上限（⛔ 不无声挂死 —— `K-94`）
    localparam integer FRAME_EXPECT = 25_000;      // ⭐ 真值 = CLK_HZ/CHANNEL_RATE_HZ = 50e6/2000 = 500 µs
    integer frame_period = FRAME_EXPECT;           // ⭐ 默认值；⭐ 下面实测覆盖
    task measure_frame_period;
        integer c;
        integer g;
        reg     seen_low;
        begin
            // ① ⭐ 若进来时正好踩在脉冲上，先等它落回 0（⛔ 不让"这一拍"被当成一条沿）
            g = 0;
            while (u_top.g_sound.af_frame_done && (g < FRAME_GUARD)) begin @(posedge clk); g = g + 1; end
            // ② 等第 1 条上升沿
            g = 0;
            while (!u_top.g_sound.af_frame_done && (g < FRAME_GUARD)) begin @(posedge clk); g = g + 1; end
            // ③ 从这条沿起逐拍数，⭐ 直到【先落 0 再抬起】= 相邻的下一条上升沿
            c = 0; seen_low = 1'b0;
            while (!(seen_low && u_top.g_sound.af_frame_done) && (c < FRAME_GUARD)) begin
                @(posedge clk);
                c = c + 1;
                if (!u_top.g_sound.af_frame_done) seen_low = 1'b1;
            end
            frame_period = c;
            $display("  [frame] measured frame period = %0d clk (%0d us); one axis refresh = 1 frame (expected %0d clk = CLK_HZ/CHANNEL_RATE_HZ)",
                     frame_period, frame_period / 50, FRAME_EXPECT);
            // ⭐ 非空洞性判据：⭐ 量到的必须是**真的**帧周期（⛔ 不是 0、⛔ 不是超时值）
            chk("F measured adc frame period is the real one (~25000 clk = 500 us), not 0 and not a timeout",
                (frame_period > 0) && (frame_period < FRAME_GUARD) &&
                (frame_period >= FRAME_EXPECT*96/100) && (frame_period <= FRAME_EXPECT*104/100));
            if (frame_period <= 0) begin
                // ⚠️ **兜底，⛔ 不是修法**：⭐ 上面已计 FAIL ⇒ ⛔ 不掩盖；
                //    ⭐ 但下游轮询上限⛔ 不能是 0（否则它 0 拍退出 ⇒ 又是一条假红）。
                $display("  [frame] WARNING: measurement failed (af_frame_done never pulsed twice within %0d clk) => falling back to the nominal %0d clk for the polling bound",
                         FRAME_GUARD, FRAME_EXPECT);
                frame_period = FRAME_EXPECT;
            end
        end
    endtask

    // ⭐ 等该轴不应期清零（⭐ 否则同轴再按会被 `event_extract` 吞掉 —— ⭐ 那是**设计行为**）
    //   🔴 老实现（⛔ 已修）：上限 = `(refr_frames + 4) * frame_period`，而 `frame_period`
    //      被测成 **0** ⇒ 上限 0 ⇒ 循环【0 拍】就退出 ⇒ 假报"不应期 0 拍内没清"。
    //   ⭐ 现在：① 帧周期已实测正确；② 这里再加**下限保护**（⛔ 上界不许 < 1 帧）；
    //           ③ 把**实际用的上界**打进日志（⭐ 可核对）。
    task wait_refr_clear;
        input [AXIS_W-1:0] ax;
        input integer      max_cyc;
        integer k;
        integer bound;
        reg     done;
        begin
            bound = max_cyc;
            if (bound < frame_period) bound = frame_period;      // ⭐ 至少给 1 帧（⛔ 不许 0）
            $display("  [refr ] wait axis %0d: bound = %0d clk (= %0d frame x %0d clk/frame); refr now = %0d",
                     ax, bound, bound / frame_period, frame_period,
                     u_top.g_sound.u_event_extract.refr[ax]);
            k = 0; done = 1'b0;
            while (!done && (k < bound)) begin
                @(posedge clk);
                if (u_top.g_sound.u_event_extract.refr[ax] === 16'd0) done = 1'b1;
                k = k + 1;
            end
            $display("  [refr ] axis %0d refractory cleared after %0d clk (bound was %0d clk; REFRACT_N was %0d frames at the press)",
                     ax, k, bound, refr_frames);
            if (!done)
                $display("FAIL: axis %0d refractory did NOT clear within %0d cycles (refr=%0d) -- the next press on this axis would be swallowed",
                         ax, bound, u_top.g_sound.u_event_extract.refr[ax]);
        end
    endtask

    // ⭐ 按下 / 松开（⭐ 逐通道覆盖 ⇒ 一次只动**一个**轴）
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

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 一次完整的"按下 → 保持 → 松开"
    // ═══════════════════════════════════════════════════════════════════════
    task press_once;
        input [AXIS_W-1:0] ax;
        input integer      nth;
        input [7:0]        label;
        integer k;
        integer lat;
        reg     found;
        begin
            $display("");
            $display("=== press %0s #%0d : axis %0d (chip %0d ch %0d) ===",
                     label, nth, ax, ax[3:3], ax[2:0]);

            // ⭐ 清观测窗口（⭐ 在时钟沿后 1 ns 做 ⇒ ⛔ 不与 always 竞争）
            @(posedge clk); #1;
            gate_seen_mask = 16'd0;
            best_seen      = 1'b0;

            print_diag("BEFORE press");

            // ── 按下 ──────────────────────────────────────────────────────
            set_key(ax, 1'b1);

            found = 1'b0; lat = -1;
            for (k = 0; (k < N_TICK*1024) && !found; k = k + 16) begin
                repeat (16) @(posedge clk);
                if (axis_gated(ax)) begin found = 1'b1; lat = k; end
            end

            //   ⭐ 此刻该轴的不应期 = `REFRACT_N`（⭐ `note_on` 推入时置的）
            //      ⇒ ⭐ 用它判断 `defparam` 是否生效 + 算后面"等不应期"的上限
            refr_frames = u_top.g_sound.u_event_extract.refr[ax];
            if (refr_frames > 8)
                $display("  [refr ] WARNING: refr=%0d frames => refractory ~%0d clk (~%0d ms). defparam may NOT have taken effect => this run will be SLOW.",
                         refr_frames, refr_frames * frame_period,
                         (refr_frames * frame_period) / 50_000);

            $display("  [gate ] axis=%0d gate_seen=%b first_gate_latency=%0d clk (~%0d sample_tick, window=%0d)",
                     ax, gate_seen_mask[ax], lat, (lat + 1023) / 1024, N_TICK);
            print_diag("AFTER press (window end)");

            // ── ⭐ 判据 B ─────────────────────────────────────────────────
            if (found)
                $display("  ok  : B press axis %0d #%0d => a voice on that axis got GATED (%0d clk, %0d tick)",
                         ax, nth, lat, (lat + 1023) / 1024);
            else begin
                $display("FAIL: B press axis %0d #%0d => NO voice on that axis was gated within %0d sample_tick",
                         ax, nth, N_TICK);
                $display("      state=%0d fifo_cnt=%0d best_valid=%b best_seen=%b ee_cnt=%0d ev=%0d sa_cnt=%0d mg_cnt=%0d lost=%b/%0d",
                         nm_state, nm_fifo_cnt, nm_best_vld, best_seen, ee_cnt, ev_cnt,
                         sa_cnt, mg_cnt, nm_lost, nm_lost_cnt);
                errors = errors + 1;
            end

            // ── 保持 ──────────────────────────────────────────────────────
            repeat (PRESS_HOLD) @(posedge clk);
            print_diag("during press hold");

            // ── 松开 ──────────────────────────────────────────────────────
            set_key(ax, 1'b0);
            found = 1'b0; lat = -1;
            for (k = 0; (k < N_TICK*1024) && !found; k = k + 16) begin
                repeat (16) @(posedge clk);
                if (!axis_gated(ax)) begin found = 1'b1; lat = k; end
            end
            $display("  [rel  ] axis=%0d gate cleared after %0d clk (%0d tick)", ax, lat, (lat + 1023) / 1024);
            print_diag("after release");

            repeat (REL_SETTLE) @(posedge clk);

            // ── ⭐ 等不应期清零（⭐ 同轴再按的前提，⛔ 不是判据）────────────
            wait_refr_clear(ax, (refr_frames + 4) * frame_period);
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // 主流程
    // ═══════════════════════════════════════════════════════════════════════
    integer pi;
    integer c1, c2, c3;
    integer drain_lat;
    reg     drained;

    initial begin
        rst_n = 1'b0;
        l_ch_mask = 8'd0;
        r_ch_mask = 8'd0;

        $display("=== tb_demo_stall_diag : demo chord -> key press, note_manager state trace ===");
        $display("  cfg  : N_TICK=%0d tick (=%0d clk, window for criterion B)", N_TICK, N_TICK*1024);
        $display("  cfg  : N_PRESS=%0d per key; KEY_A axis=%0d ; KEY_B axis=%0d", N_PRESS, KEY_A, KEY_B);
        $display("  cfg  : DEMO_NOTE_DELAY=%0d (board 2_000_000) ; DEMO_HOLD_CYC=%0d (board 50_000_000)",
                 DEMO_DELAY, DEMO_HOLD);
        $display("  cfg  : defparam event_extract.REFRACT_N = %0d (board 60 => 30 ms at 500 us/frame)",
                 TB_REFRACT_N);

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // ── ① 等 autotare（⭐ 不标定的话 `pos` 是脏值，按键判据全不可信）────
        wait_autotare;
        measure_frame_period;
        print_diag("after reset + autotare");

        // ── ② 等自检和弦整段走完 ──────────────────────────────────────────
        //   ⭐ 上板真值：`DEMO_NOTE_DELAY`(40 ms) + `DEMO_HOLD_CYC`(1 s) ≈ 1.04 s
        //      = 52_000_000 拍 ⇒ ⚠️ 仿真跑不动 ⇒ 本 tb 缩小了这两个参数
        //   ⭐ 判据 = **结构信号 `demo_fired`**（⛔ 不是拍脑袋的固定延时）
        wait_demo_done;
        print_diag("demo chord finished (demo_fired=1)");

        // ── ③ 等队列排空（⭐ 带上限，⛔ 不静默挂死）────────────────────────
        drained = 1'b0; drain_lat = -1;
        for (pi = 0; (pi < TAIL_GUARD) && !drained; pi = pi + 1) begin
            @(posedge clk);
            if ((nm_fifo_cnt == 6'd0) && (nm_state == 3'd0)) begin
                drained = 1'b1; drain_lat = pi;
            end
        end
        $display("  [drain] fifo empty + ST_IDLE reached after %0d clk (drained=%b)", drain_lat, drained);
        print_diag("after demo tail drain");

        // ═══ ⭐ 判据 A ═══════════════════════════════════════════════════
        //   ⭐ 自检和弦结束后、按键之前：队列必须是空的、FSM 必须在 `ST_IDLE`
        //   ⭐ 若这里就非 0/非 IDLE ⇒ **直接抓到**"没排空"这一类停摆
        chk("A after demo chord: note_manager fifo_cnt==0 AND state==ST_IDLE",
            (nm_fifo_cnt == 6'd0) && (nm_state == 3'd0));

        // ── ④ 按键：同一个键 N_PRESS 次 ───────────────────────────────────
        for (pi = 0; pi < N_PRESS; pi = pi + 1)
            press_once(KEY_A, pi + 1, "A");

        // ── ⑤ 按键：另一个键 N_PRESS 次（⭐ 异轴 ⇒ 证"同轴/异轴表现一样"）──
        for (pi = 0; pi < N_PRESS; pi = pi + 1)
            press_once(KEY_B, pi + 1, "B");

        // ═══ ⭐ 判据 C ═══════════════════════════════════════════════════
        //   C1：`fifo_cnt` 任何时刻都不许超过 `FIFO_DEPTH`
        $display("  [fifo ] max fifo_cnt seen = %0d (FIFO_DEPTH=%0d) ; over=%b @ t=%0t",
                 fifo_max, FIFO_DEPTH, fifo_over, fifo_over_t);
        chk("C1 note_manager fifo_cnt never exceeded FIFO_DEPTH", !fifo_over);

        //   C2：按键停止后**不许持续增长**（⭐ 若一直涨 ⇒ FSM 没在排空）
        @(posedge clk); #1; c1 = nm_fifo_cnt;
        repeat (4*1024) @(posedge clk);
        #1; c2 = nm_fifo_cnt;
        repeat (4*1024) @(posedge clk);
        #1; c3 = nm_fifo_cnt;
        $display("  [fifo ] after keys released: c1=%0d c2=%0d c3=%0d (must not grow)", c1, c2, c3);
        chk("C2 after keys released, fifo_cnt does NOT keep growing", (c3 <= c1));

        //   C3：按键停止后队列必须回到 0（⭐ FSM 确实在排空）
        drained = 1'b0;
        for (pi = 0; (pi < 8*1024) && !drained; pi = pi + 1) begin
            @(posedge clk);
            if (nm_fifo_cnt == 6'd0) drained = 1'b1;
        end
        print_diag("final (keys released, tail waited)");
        chk("C3 after keys released, fifo_cnt DRAINS back to 0", drained);

        // ⭐ 附加（⭐ 非空洞性检查：说明"事件确实流过全链"）
        $display("  [evts ] ee_cnt=%0d ev=%0d (on=%0d off=%0d) sa_cnt=%0d mg_cnt=%0d sa_drop=%0d mg_drop=%0d",
                 ee_cnt, ev_cnt, ev_on, ev_off, sa_cnt, mg_cnt, sa_drop, mg_drop);
        $display("  [src  ] seq_arb forwarded: live=%0d demo=%0d (demo chord = 3 on + 3 off = 6)",
                 sa_live, sa_demo);
        $display("  [axes ] ee_axis=0x%04h ev_axis=0x%04h gate_seen=0x%04h",
                 ee_axis_mask, ev_axis_mask, gate_seen_mask);
        chk("D the hand-play events really flowed (ee_cnt>0 and ev>0) -- non-vacuous",
            (ee_cnt > 0) && (ev_cnt > 0));
        chk("D no upstream event was dropped (sa_drop==0 and mg_drop==0)",
            (sa_drop == 16'd0) && (mg_drop == 16'd0));
        chk("D note_manager reported no event loss (event_lost_o==0)", (nm_lost === 1'b0));

        $display("");
        if (errors == 0)
            $display("PASS: demo-chord-then-key diagnostic -- the queue drained and every press gated a voice on its own axis");
        else
            $fatal(1, "FAIL: demo-chord-then-key diagnostic had %0d error(s)", errors);

        #1000;
        $finish;
    end

endmodule
