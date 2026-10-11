// ─────────────────────────────────────────────────────────────────────────────
// tb_pool_by_src.sv · 交付章程 §26.3 判据 a / b / c / d
//
// ⭐ 被验的修复（2026-10-01 "修B"）：
//   `rtl/w3b/note_manager.v`
//     · 进不进【保留池】由【来源】定，⛔ 不再由轴号定：
//         assign pool_mask[pg]   = (cur_src == SRC_AUX) ? (pg >= NORMAL_N)
//                                                       : (pg <  NORMAL_N);
//     · 是不是【打击乐 voice】也由同一个信号导出（§26.3-e 的"同源派生"）：
//         assign voice_drum_o[g] = (src_r[g] == SRC_AUX);
//   来源编码（见 `rtl/top.v`：`.a_src_i(src_a_src)` · `.b_src_i(3'd3)` · `.c_src_i(3'd4)`）：
//     0 = live 手弹 · 1/2 = 曲谱/demo · 3 = 源 B（节拍器/鼓机）· 4 = looper
//
// 🔴 它修的缺陷：物理键 14/15（G#3/A#3）无声 —— 旧规则按【轴号】判
//   （`cur_axis >= 14` 选池、`axis_r[g] >= 14` 判鼓）
//   ⇒ 物理键 14/15 被送进只有 5 个 voice 的保留池 ＋ 被打上"鼓 voice"标志。
//
// ⭐ 本 tb 覆盖的 4 条判据：
//   a) 端到端 source tag 可观测 —— 从 `note_src_i` 入队 ⇒ 到 `pool_mask`/`voice_drum_o`
//      【每一级】都抓一次快照并断言（⛔ 不是只在中段断言）：
//        级 1/5 FIFO 条目 `fifo_src[wr]`
//        级 2/5 队列头     `head_src`
//        级 3/5 锁存寄存器 `cur_src`
//        级 4/5 组合掩码   `pool_mask`
//        级 5/5 输出标志   `voice_drum_o`
//      （⭐ 内部信号用层次引用 `dut_n.xxx` 读取，与 `tb_note_manager` 读
//        `u_top.g_sound.xxx` 是同一手法）
//   b) ⭐⭐ 差分等价（最关键）—— `src=0`（手弹）在【轴 14/15】上的行为，
//      必须与在【轴 0..13】上的行为【逐位相同】：
//        · 16 次按键 16 次都必须落进【普通池】（`alloc_voice < NORMAL_N=28`）
//        · 16 个 voice 的 `voice_drum_o` 必须【全为 0】（⛔ 不是鼓）
//        · 16 次观测到的 `pool_mask` 必须【逐位相同】（含 x 也抓得住）
//      ⇒ 这就是"换规则对现场演奏【无副作用】"的证明。
//   c) 悬空 tag 安全 —— 把 `note_src_i` **故意悬空**（⛔ 不接 ⇒ `z`）：
//        ① `pool_mask` ⛔ 不是全 `x`（也不是"部分 x"）
//        ② 事件不丢（仍然分配到 voice）
//      ⚠️ 依据：旧回退版实测"悬空 ⇒ pool_mask 全 x ⇒ 6/6 事件全丢"。
//   d) ⭐⭐ 端到端音高 —— ⛔ 不能只断言"有声音"：
//        · 轴 14/15 的 `voice_phase_inc_o` 必须【逐位等于】`note_phase_inc_i`
//          （⭐ 即没有被鼓机逻辑改写）
//        · 该 voice 必须【不是鼓 voice】（`voice_drum_o=0`）——
//          ⚠️ 因为鼓标志会让 `oscillator_bank` 改读噪声表 ⇒ 音高再对也听不到
//        · 非空洞性：`src=3` 必须真的把 `voice_drum_o` 置 1（⛔ 否则上一条是同义反复）
//      📌 ⚠️ **本 tb 只做 `note_manager` 侧**：完整的
//         "`phase_inc == axis_map(kb_inc[k])`"（键号 ⇒ 音高）属于**顶层 tb**（别的批次）。
//      📌 章程 §26.3 的 e（`pool_mask` 与 `voice_drum_o` 同源派生）已由
//         `tb_note_manager` 判据 8 覆盖；f 是流程、⛔ 不是 tb 能判的东西。
//
// ⚠️ 语法纪律（`K-91`）：Verilog-2001 构造，⛔ 不用 SV 专有特性
//    （iverilog 接受 ≠ Gowin 接受）。`$display` 字符串一律 **纯 ASCII**
//    （⛔ 避免 GBK 控制台把日志弄成乱码 —— 实测过）。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_pool_by_src;

    localparam integer POLY       = 32;
    localparam integer AXIS_W     = 4;
    localparam integer PHASE_W    = 32;
    localparam integer VEL_W      = 8;
    localparam integer TIMBRE_W   = 2;
    localparam integer ENV_W      = 16;
    localparam integer AGE_W      = 16;
    localparam integer IDX_W      = 5;              // $clog2(32)
    localparam integer RSV_N      = 4;              // RESERVED_N（与 tb_note_manager 的 DUT C 同档）
    localparam integer NORMAL_N   = POLY - RSV_N;   // 28
    localparam integer EVT_LOST_W = 8;
    localparam integer FW         = 5;              // $clog2(FIFO_DEPTH=32)
    localparam [2:0]   SRC_AUX    = 3'd3;           // 源 B = 节拍器 / 鼓机
    //  ⭐⭐ 2026-10-11（`P1-59`）：⭐ **源 5 = 键盘打鼓**（⭐ 从"未使用编码"变成**已定义**）✅
    //     🔴 **为什么本 tb 必须跟着改**：⭐ 它原来有一条判据
    //        `a7: unused src code 5 behaves like hand-play`（⭐ 那时 5 确实空闲 ✅）
    //        ⇒ ⭐ 现在 5 = 键盘打鼓 ⇒ ⭐ **它必须进保留池 ＋ 判为打击乐** ✅
    //     📌 ⭐ 而"**未使用编码 ⇒ 当手弹**"这条口径**没有消失** ——
    //        ⭐ 只是**挪到了 6/7**（⭐ 本 tb 已把扫描范围扩到 `0..7` ✅）
    localparam [2:0]   SRC_KDRUM  = 3'd5;           // ⭐ 键盘打鼓（⭐ `P1-59`）
    localparam [2:0]   ST_IDLE    = 3'd0;           // ⭐ 与 RTL 的 `ST_IDLE` 编码一致

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;

    task chk;
        input [8*72-1:0] name;
        input            cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ── 辅助函数 ────────────────────────────────────────────────────────────
    //  ⭐ 规格（⛔ 不是抄 RTL）：由【来源】推出应有的 `pool_mask`。
    //     源 B(3) 或 ⭐ **键盘打鼓(5)** ⇒ 保留池（高位 `pg >= NORMAL_N`）；
    //     其余（0/1/2/4 及未用编码 6/7）⇒ 普通池。
    function [POLY-1:0] exp_mask;
        input [2:0] s;
        integer q;
        begin
            for (q = 0; q < POLY; q = q + 1)
                exp_mask[q] = ((s === SRC_AUX) || (s === SRC_KDRUM))
                              ? (q >= NORMAL_N) : (q < NORMAL_N);
        end
    endfunction

    function integer count_x;
        input [POLY-1:0] v;
        integer q;
        begin
            count_x = 0;
            for (q = 0; q < POLY; q = q + 1)
                if (v[q] === 1'bx) count_x = count_x + 1;
        end
    endfunction

    function integer popcount;
        input [POLY-1:0] m;
        integer q; integer c;
        begin
            c = 0;
            for (q = 0; q < POLY; q = q + 1) if (m[q]) c = c + 1;
            popcount = c;
        end
    endfunction

    function [PHASE_W-1:0] inc_at;
        input [POLY*PHASE_W-1:0] bus;
        input integer            v;
        begin inc_at = bus[v*PHASE_W +: PHASE_W]; end
    endfunction

    function [AXIS_W-1:0] axis_at;
        input [POLY*AXIS_W-1:0] bus;
        input integer           v;
        begin axis_at = bus[v*AXIS_W +: AXIS_W]; end
    endfunction

    // ═════════════════════════════════════════════════════════════════════════
    // DUT N · 主实例（来源可变）—— 覆盖判据 a / b / d
    //    ⚠️ **端口全部接上**（悬空会变 `z` ⇒ 判据假红，见 `tb_note_manager:246` 的同款注释）
    // ═════════════════════════════════════════════════════════════════════════
    reg                    sample_tick = 1'b0;
    reg                    note_valid;
    reg  [AXIS_W-1:0]      note_axis;
    reg  [PHASE_W-1:0]     note_phase_inc;
    reg  [VEL_W-1:0]       note_velocity;
    reg  [1:0]             note_kind;
    reg  [2:0]             note_src;

    wire [POLY-1:0]         voice_gate;
    wire [POLY-1:0]         voice_active;
    wire [POLY-1:0]         voice_releasing;
    wire [POLY*AXIS_W-1:0]  voice_axis;
    wire [POLY*PHASE_W-1:0] voice_phase_inc;
    wire [POLY*VEL_W-1:0]   voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY-1:0]         voice_drum_o;
    wire [POLY*AGE_W-1:0]   voice_age;
    wire [POLY-1:0]         voice_retrig_reset;
    wire                    alloc_valid;
    wire [IDX_W-1:0]        alloc_voice;
    wire                    event_lost;
    wire [EVT_LOST_W-1:0]   event_lost_cnt;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(RSV_N), .DEFAULT_VEL(200), .IDX_W(IDX_W),
        .FIFO_DEPTH(32), .EVT_LOST_CNT_W(EVT_LOST_W)
    ) dut_n (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind),
        .note_src_i(note_src),                       // ⭐ 判据 a/b/d 的【可变来源】
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}),
        .vel_upd_src_i(3'd0), .pitch_upd_src_i(3'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({POLY{1'b0}}), .env_level_i({(POLY*ENV_W){1'b0}}),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_drum_o(voice_drum_o),
        .voice_age_o(voice_age), .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice),
        .event_lost_o(event_lost), .event_lost_cnt_o(event_lost_cnt),
        .event_lost_clr_i(1'b0)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // DUT Z · 判据 c 专用实例 —— 🔴 **`note_src_i` 故意【不接】**（悬空 = `z`）
    //   ⚠️ 除这一个端口外，其余端口【全部接上】——
    //      否则"事件丢失"可能来自别的悬空端口，判据就指错了根因。
    //   📌 本实例的 `note_src_i` **不在下面的端口表里**，这就是"悬空"。
    // ═════════════════════════════════════════════════════════════════════════
    reg                    z_valid;
    reg  [AXIS_W-1:0]      z_axis;
    reg  [PHASE_W-1:0]     z_inc;
    wire [POLY-1:0]        z_gate;
    wire [POLY-1:0]        z_drum;
    wire [IDX_W-1:0]       z_alloc_voice;
    wire                   z_alloc_valid;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(RSV_N), .DEFAULT_VEL(200), .IDX_W(IDX_W),
        .FIFO_DEPTH(32), .EVT_LOST_CNT_W(EVT_LOST_W)
    ) dut_z (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(z_valid), .note_axis_i(z_axis),
        .note_phase_inc_i(z_inc), .note_velocity_i(8'd100),
        .note_kind_i(2'd0),
        //  🔴🔴 这里**故意**没有 `.note_src_i(...)` ⇒ 该输入悬空 = `z`（判据 c）
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}),
        .vel_upd_value_i({VEL_W{1'b0}}),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}),
        .vel_upd_src_i(3'd0), .pitch_upd_src_i(3'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({POLY{1'b0}}), .env_level_i({(POLY*ENV_W){1'b0}}),
        .voice_gate_o(z_gate), .voice_active_o(), .voice_releasing_o(),
        .voice_axis_o(), .voice_phase_inc_o(), .voice_velocity_o(),
        .voice_timbre_o(), .voice_drum_o(z_drum), .voice_age_o(),
        .voice_retrig_reset_o(),
        .alloc_valid_o(z_alloc_valid), .alloc_voice_o(z_alloc_voice),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ── 快照寄存器（每一级一个）──────────────────────────────────────────────
    reg [2:0]              obs_fifo_src;      // 级 1/5：FIFO 条目
    reg [2:0]              obs_head_src;      // 级 2/5：队列头
    reg [2:0]              obs_cur_src;       // 级 3/5：锁存寄存器
    reg [POLY-1:0]         obs_pool_mask;     // 级 4/5：池掩码（组合）
    reg [POLY-1:0]         obs_drum_bus;      // 级 5/5：鼓标志位图（输出）
    reg [POLY*PHASE_W-1:0] obs_inc_bus;
    reg [POLY*AXIS_W-1:0]  obs_axis_bus;
    reg                    obs_got_fifo, obs_got_head, obs_got_cur, obs_alloc;
    reg [IDX_W-1:0]        obs_alloc_voice;

    reg [2:0]              zobs_fifo_src;
    reg [2:0]              zobs_head_src;
    reg [2:0]              zobs_cur_src;
    reg [POLY-1:0]         zobs_pool_mask;
    reg [POLY-1:0]         zobs_drum_bus;
    reg                    zobs_got_fifo, zobs_got_head, zobs_got_cur, zobs_alloc;
    reg [IDX_W-1:0]        zobs_alloc_voice;

    // ── 激励任务 ────────────────────────────────────────────────────────────
    task do_reset;
        begin
            rst_n      = 1'b0;
            note_valid = 1'b0;
            z_valid    = 1'b0;
            sample_tick = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
        end
    endtask

    //  ⚠️ `sample_tick_i` 是**时钟使能**（⛔ 不是电平）：必须**恰好高 1 个 clk**
    //     （`K-93`：写成"高 N 拍"会让每个 tick 变成 N 个采样步 ⇒ 时基错乱）。
    //  ⭐ 本 tb 的 4 条判据都只依赖**分配**（⛔ 不吃 `sample_tick`）；
    //     这里仍走一个 tick，是为了把 `retrig_reset_r` 清干净、⛔ 不留半清状态。
    task run_ticks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk); sample_tick = 1'b1;
                @(negedge clk); sample_tick = 1'b0;
                repeat (2) @(negedge clk);
            end
        end
    endtask

    // ⭐ 发一条 `note_on`，并把它**在流水线每一级**的样子抓进快照。
    //   ⚠️ 本任务假设"发事件时队列是空的"（每次调用前都等到了 alloc）⇒
    //      `fifo_rd == fifo_wr == wr`，于是 `fifo_src[wr]` 就是本次事件那条。
    task press_probe_n;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [2:0]         s;
        integer g;
        reg [FW-1:0] wr;
        begin
            obs_got_fifo = 1'b0; obs_got_head = 1'b0; obs_got_cur = 1'b0;
            obs_alloc    = 1'b0;
            obs_alloc_voice = {IDX_W{1'b0}};
            obs_pool_mask = {POLY{1'bx}};
            obs_drum_bus  = {POLY{1'bx}};
            obs_inc_bus   = {(POLY*PHASE_W){1'bx}};
            obs_axis_bus  = {(POLY*AXIS_W){1'bx}};
            @(negedge clk);
            wr = dut_n.fifo_wr;
            note_src = s; note_axis = ax; note_phase_inc = inc;
            note_velocity = 8'd100; note_kind = 2'd0; note_valid = 1'b1;
            @(negedge clk);
            note_valid = 1'b0;
            obs_fifo_src = dut_n.fifo_src[wr];       // 级 1/5
            obs_got_fifo = 1'b1;
            g = 0;
            while ((g < 64) && !obs_alloc) begin
                // 级 2/5：出队前那一拍看队列头
                if (!obs_got_head && (dut_n.state === ST_IDLE) && (dut_n.fifo_cnt != 0)) begin
                    obs_head_src = dut_n.head_src;
                    obs_got_head = 1'b1;
                end
                // 级 3/5 + 4/5：`ST_IDLE -> ST_DECIDE` 之后 `cur_src` 已锁存
                if (!obs_got_cur && (dut_n.state !== ST_IDLE)) begin
                    obs_cur_src   = dut_n.cur_src;
                    obs_pool_mask = dut_n.pool_mask;
                    obs_got_cur   = 1'b1;
                end
                // 级 5/5：分配发生那一拍看输出
                if (alloc_valid) begin
                    obs_alloc       = 1'b1;
                    obs_alloc_voice = alloc_voice;
                    obs_drum_bus    = voice_drum_o;
                    obs_inc_bus     = voice_phase_inc;
                    obs_axis_bus    = voice_axis;
                end
                @(negedge clk);
                g = g + 1;
            end
        end
    endtask

    // ⭐ 判据 c 专用：同一个探针，但打在 `dut_z` 上（`note_src_i` 悬空）
    task press_probe_z;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        integer g;
        reg [FW-1:0] wr;
        begin
            zobs_got_fifo = 1'b0; zobs_got_head = 1'b0; zobs_got_cur = 1'b0;
            zobs_alloc    = 1'b0;
            zobs_alloc_voice = {IDX_W{1'b0}};
            zobs_pool_mask = {POLY{1'bx}};
            zobs_drum_bus  = {POLY{1'bx}};
            @(negedge clk);
            wr = dut_z.fifo_wr;
            z_axis = ax; z_inc = inc; z_valid = 1'b1;
            @(negedge clk);
            z_valid = 1'b0;
            zobs_fifo_src = dut_z.fifo_src[wr];
            zobs_got_fifo = 1'b1;
            g = 0;
            while ((g < 64) && !zobs_alloc) begin
                if (!zobs_got_head && (dut_z.state === ST_IDLE) && (dut_z.fifo_cnt != 0)) begin
                    zobs_head_src = dut_z.head_src;
                    zobs_got_head = 1'b1;
                end
                if (!zobs_got_cur && (dut_z.state !== ST_IDLE)) begin
                    zobs_cur_src   = dut_z.cur_src;
                    zobs_pool_mask = dut_z.pool_mask;
                    zobs_got_cur   = 1'b1;
                end
                if (z_alloc_valid) begin
                    zobs_alloc       = 1'b1;
                    zobs_alloc_voice = z_alloc_voice;
                    zobs_drum_bus    = z_drum;
                end
                @(negedge clk);
                g = g + 1;
            end
        end
    endtask

    // ── 统计量 ──────────────────────────────────────────────────────────────
    integer sa, kb, kc, ax_tmp;
    integer a_bad_fifo, a_bad_head, a_bad_cur, a_bad_mask, a_bad_drum, a_bad_pool, a_bad_alloc;
    integer a5_bad;
    //  ⭐⭐ 2026-10-11（`P1-59`）：⭐ **未使用编码 6/7 的反向判据计数** ✅
    //     ⭐ 原来这个角色由 `a5_bad` 兼（⭐ 那时 5 是空闲编码 ✅）；
    //     ⭐ 现在 5 已定义 ⇒ ⭐ 把"未用 ⇒ 当手弹"这条口径**挪到 6/7** ✅
    integer a67_bad;
    integer b_bad_pool, b_bad_drum, b_bad_mask;
    integer c_bad_x, c_bad_mask, c_bad_alloc, c_seen_x;
    reg [POLY-1:0]  b_mask0;
    reg [POLY-1:0]  b_mask [0:15];
    reg [IDX_W-1:0] b_alloc[0:15];
    reg [IDX_W-1:0]   d14_v, d15_v, d0_v, daux_v;
    reg [PHASE_W-1:0] d14_inc, d15_inc, d0_inc, daux_inc;
    reg [AXIS_W-1:0]  d14_ax, d15_ax;
    reg               d14_drum, d15_drum, d0_drum, daux_drum;

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐⭐ "能红"论证（把 RTL 那两行改回【按轴号】判 ⇒ 哪几条会红？）
    //
    //   改回成：
    //     assign pool_mask[pg]   = (cur_axis >= RESERVED_AXIS) ? (pg >= NORMAL_N)
    //                                                          : (pg <  NORMAL_N);
    //     assign voice_drum_o[g] = (axis_r[g] >= RESERVED_AXIS);
    //
    //   ① 判据 a ⇒ 🔴 红
    //      本 tb 的 a 用 `src=3`（源 B）在【轴 3】上发事件：
    //        · 新规则：`src==3` ⇒ 保留池（`pg >= 28`）✅
    //        · 旧规则：轴 3 < 14 ⇒ 普通池（`pg < 28`）🔴
    //      ⇒ `a4`（pool_mask 与来源推导的掩码逐位相等）·`a5`（鼓标志）·`a6`（落在正确的池）
    //        三条必红。⚠️ 如实记录：a1/a2/a3 在旧规则下【仍绿】——
    //        那三级只搬 src 标记，与"选哪个池 / 是不是鼓"无关。
    //
    //   ② 判据 b ⇒ 🔴 红（最关键）
    //      b 用 `src=0` 依次按 16 个轴。旧规则下轴 14/15 被送进保留池 ＋ 被打成鼓 voice
    //      ⇒ b1（16/16 落普通池）· b2（16 个 voice 的 drum=0）· b3（pool_mask 逐位相同）
    //        · b5/b6（轴 14/15 ⛔ 不在保留池）· b7（轴 14/15 的 drum=0）全红。
    //      📌 这一组就是"物理键 14/15 无声"这条缺陷的**正面判据**。
    //
    //   ③ 判据 c ⇒ 🔴 红（⚠️ 现状下 c1/c2/c3/c4 红；M1 下只有 c2 红）
    //      c 断言"`note_src_i` 悬空时 `pool_mask` 不含 x 且事件不丢"。
    //        · 现状：`pool_mask` 由 `cur_src` 决定，而 `note_src_i` 是**直接**进 FIFO 的
    //          （`fifo_src[fifo_wr] <= note_src_i;`），⛔ 没有 `vu_src_w`/`pu_src_w`
    //          那样的 Z-safe 解码 ⇒ 悬空 ⇒ `cur_src = 3'bzzz` ⇒ `pool_mask` **32 位全 x**
    //          ⇒ `cand_ok = x` ⇒ `ST_SCAN` 的 `if (cand_ok && cand_better)` 取假
    //          ⇒ `best_valid` 恒 0 ⇒ `ST_COMMIT` 不提交 ⇒ 🔴 **事件静默丢弃**（实测 3/3）。
    //        · M1（按轴）：`pool_mask` 只由 `cur_axis` 决定 ⇒ 无 x ⇒ c1/c3/c4 绿；
    //          ⚠️ 但 c2 仍红 —— c 的第 3 个事件发在**轴 14** 上，旧规则把它送进保留池，
    //          而 c2 要求"悬空 = 手弹(0) ⇒ 普通池"。
    //      ⇒ ⭐ 结论：c1/c3/c4 是【本次修复引入的新缺口】，⛔ 不是旧缺陷（`K-56` 同族）。
    //        ⚠️ 本任务⛔ 不许改 RTL ⇒ 最小修法（M2，已实测全绿）：
    //          在 `vu_src_w` 旁边加一段同构的解码，并让 FIFO 写它：
    //            wire [2:0] ns_src_w = (note_src_i === 3'd1) ? 3'd1 :
    //                                  (note_src_i === 3'd2) ? 3'd2 :
    //                                  (note_src_i === 3'd3) ? 3'd3 :
    //                                  (note_src_i === 3'd4) ? 3'd4 : 3'd0;
    //            fifo_src[fifo_wr] <= ns_src_w;      // 原来是 <= note_src_i
    //
    //   ④ 判据 d ⇒ 🔴 红
    //      d 断言轴 14/15（`src=0`）的 voice：phase_inc 逐位相等 **且** 不是鼓 voice，
    //      并有 `src=3` 的非空洞性对照。旧规则下 `axis_r=14/15` ⇒ `voice_drum_o=1`
    //      ⇒ **d5 红**；`src=3` 发在轴 5 上 ⇒ 旧规则给 drum=0 ⇒ **d6 红**；
    //      那个 voice 也被送进普通池 ⇒ **d8 红**。
    //      ⚠️ 如实说明：d1/d2/d3（phase_inc 逐位相等）在旧规则下【仍绿】——
    //         因为 `note_manager` 内部**没有任何路径会改写 `phase_r`**
    //         （鼓机的音色改写发生在 `oscillator_bank` 的"读噪声表"那一步）。
    //      ⇒ ⭐ 所以 d 必须写成"phase_inc 相等 ⭐ **且** 不是鼓 voice"这一对，
    //         ⛔ 只写 phase_inc 相等是**抓不住这个缺陷的**（`C83` 同族：判据要盯
    //         真正被改写的那一层）。
    //
    //   ⭐⭐ 上面每条都用【真实变异】跑过（⛔ 不是纸上推演）——
    //      变异体建在仓库外的临时副本上，⛔ 不改本仓库任何文件：
    //        M1 = 把两行改回按轴 · M2 = 加 ③ 里的 Z-safe 解码
    //      实测（`iverilog` + `vvp`，同一份 tb）：
    //        · 现状（未改）      ：22 ok / 4 FAIL  —— 红的正好是 c1/c2/c3/c4
    //        · M1（改回按轴）    ：13 ok / 13 FAIL —— a4,a5,a6 · b1,b2,b3,b5,b6,b7 ·
    //                              c2 · d5,d6,d8 ⇒ ⭐ **b 与 d 都红** ✅
    //        · M2（加 Z-safe 解码）：全绿（PASS）⇒ ⭐ 证明 c 的红⛔ 不是判据写错，
    //                              而是 RTL 缺一段解码 ✅
    // ═════════════════════════════════════════════════════════════════════════

    initial begin
        note_valid = 1'b0; note_axis = {AXIS_W{1'b0}}; note_phase_inc = 32'd0;
        note_velocity = {VEL_W{1'b0}}; note_kind = 2'd0; note_src = 3'd0;
        z_valid = 1'b0; z_axis = {AXIS_W{1'b0}}; z_inc = 32'd0;
        sample_tick = 1'b0;
        do_reset;

        // ═══════════════════════════════════════════════════════════════════
        $display("== a: source tag observable at EVERY pipeline stage ==");
        // ═══════════════════════════════════════════════════════════════════
        //  8 个来源各发一次（轴 = 来源编号，⛔ 互不重叠 ⇒ 都是"新占 voice"）：
        //    0=live · 1=score · 2=demo · 3=源 B · ⭐ **5=键盘打鼓（`P1-59` 起已定义）**
        //    · 4=looper · ⭐ **6/7=未使用编码**
        //  ⭐ `6/7` 是**未使用**编码 ⇒ 按"悬空/未用 = 手弹"的口径，应落普通池 ✅
        a_bad_fifo = 0; a_bad_head = 0; a_bad_cur = 0;
        a_bad_mask = 0; a_bad_drum = 0; a_bad_pool = 0; a_bad_alloc = 0;
        a5_bad = 0; a67_bad = 0;
        for (sa = 0; sa < 8; sa = sa + 1) begin
            press_probe_n(sa[AXIS_W-1:0], 32'h0001_0000 + sa, sa[2:0]);
            $display("  INFO a: src=%0d fifo=%b head=%b cur=%b mask_x=%0d alloc=%0d voice=%0d drum=%b",
                     sa, obs_fifo_src, obs_head_src, obs_cur_src,
                     count_x(obs_pool_mask), obs_alloc, obs_alloc_voice,
                     obs_drum_bus[obs_alloc_voice]);
            //  ⭐ 级 1..3 只对【已定义的 6 个编码】(0..5) 断言"逐位透传"：
            //     ⭐ **2026-10-11（`P1-59`）：上界 5 → 6**（⭐ 因为 5 现在是**已定义**的
            //        键盘打鼓，⭐ `ns_src_w` **必须逐位透传它** ✅）
            //     编码 6/7 仍是【未使用】⇒ 允许（而且应当）被归一化成手弹(0)
            //     （⭐ 与 `vu_src_w`/`pu_src_w` 的"未用编码 ⇒ 当手弹"同一口径）。
            if (sa < 6) begin
                if (obs_fifo_src !== sa[2:0])        a_bad_fifo = a_bad_fifo + 1;
                if (obs_head_src !== sa[2:0])        a_bad_head = a_bad_head + 1;
                if (obs_cur_src  !== sa[2:0])        a_bad_cur  = a_bad_cur  + 1;
            end
            //  ⭐⭐ `sa == 5`（键盘打鼓）：⭐ **必须进保留池 ＋ 判为打击乐 ＋ 拿到 voice** ✅
            //     🔴 **这是 `P1-59` 新增的语义** —— ⭐ 原来 5 是空闲编码，
            //        ⚠️ 所以本条原来是"应当落【普通】池" ✅
            if (sa == 5) begin
                if ((obs_alloc_voice <  NORMAL_N) ||
                    (obs_drum_bus[obs_alloc_voice] !== 1'b1) || !obs_alloc)
                    a5_bad = a5_bad + 1;
            end
            //  ⭐ `sa >= 6`（仍未使用的编码）：⭐ 按"未用 ⇒ 当手弹"⇒ ⭐ 普通池 ＋ drum=0 ✅
            if (sa >= 6) begin
                if ((obs_alloc_voice >= NORMAL_N) ||
                    (obs_drum_bus[obs_alloc_voice] !== 1'b0) || !obs_alloc)
                    a67_bad = a67_bad + 1;
            end
            if ((count_x(obs_pool_mask) != 0) ||
                (obs_pool_mask !== exp_mask(sa[2:0]))) a_bad_mask = a_bad_mask + 1;
            if (obs_drum_bus[obs_alloc_voice] !==
                (((sa[2:0] === SRC_AUX) || (sa[2:0] === SRC_KDRUM)) ? 1'b1 : 1'b0))
                                                     a_bad_drum = a_bad_drum + 1;
            if (((sa[2:0] === SRC_AUX) || (sa[2:0] === SRC_KDRUM))
                ? (obs_alloc_voice <  NORMAL_N)
                : (obs_alloc_voice >= NORMAL_N))
                                                     a_bad_pool = a_bad_pool + 1;
            if (!obs_alloc)                          a_bad_alloc = a_bad_alloc + 1;
        end
        chk("a1: src tag is stored in the FIFO entry (stage 1/5)", a_bad_fifo == 0);
        chk("a2: src tag is visible at the queue head (stage 2/5)", a_bad_head == 0);
        chk("a3: src tag is latched into cur_src (stage 3/5)", a_bad_cur == 0);
        chk("a4: pool_mask is x-free and equals the src-derived mask (stage 4/5)", a_bad_mask == 0);
        chk("a5: voice_drum_o[alloc] == (src is AUX or KDRUM) (stage 5/5)", a_bad_drum == 0);
        chk("a6: every src got a voice, in the pool its source demands", (a_bad_alloc == 0) && (a_bad_pool == 0));
        chk("a7: src code 5 (keyboard drums) => reserved pool + drum=1 + allocated (P1-59)", a5_bad == 0);
        chk("a8: UNUSED src codes 6/7 behave like hand-play (normal pool, drum=0)", a67_bad == 0);
        run_ticks(1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== b: differential equivalence -- src=0 on axis 14/15 vs axis 0..13 ==");
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        b_bad_pool = 0; b_bad_drum = 0; b_bad_mask = 0;
        b_mask0 = {POLY{1'bx}};
        for (kb = 0; kb < 16; kb = kb + 1) begin
            press_probe_n(kb[AXIS_W-1:0], 32'h0001_0000 + kb, 3'd0);
            b_alloc[kb] = obs_alloc_voice;
            b_mask [kb] = obs_pool_mask;
            if (kb == 0) b_mask0 = obs_pool_mask;
            if (obs_pool_mask !== b_mask0)                b_bad_mask = b_bad_mask + 1;
            if (obs_alloc_voice >= NORMAL_N)              b_bad_pool = b_bad_pool + 1;
            if (obs_drum_bus[obs_alloc_voice] !== 1'b0)   b_bad_drum = b_bad_drum + 1;
            $display("  INFO b: axis=%0d src=0 alloc_voice=%0d normal_pool=%0d drum=%b mask_x=%0d",
                     kb, obs_alloc_voice, (obs_alloc_voice < NORMAL_N),
                     obs_drum_bus[obs_alloc_voice], count_x(obs_pool_mask));
        end
        chk("b1: all 16 live (src=0) presses land in the NORMAL pool (< 28)", b_bad_pool == 0);
        chk("b2: voice_drum_o is 0 for all 16 live voices (no key is a drum)", b_bad_drum == 0);
        chk("b3: pool_mask is bit-identical for axis 14/15 and axis 0..13 under src=0", b_bad_mask == 0);
        chk("b4: the 16 live presses occupy 16 distinct voices", popcount(voice_gate) == 16);
        chk("b5: axis 14 (G#3) with src=0 is NOT routed to the reserved pool", b_alloc[14] < NORMAL_N);
        chk("b6: axis 15 (A#3) with src=0 is NOT routed to the reserved pool", b_alloc[15] < NORMAL_N);
        chk("b7: voice_drum_o is 0 on the axis-14 and axis-15 voices",
            (voice_drum_o[b_alloc[14]] === 1'b0) && (voice_drum_o[b_alloc[15]] === 1'b0));
        run_ticks(1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== c: dangling note_src_i (z) -- pool_mask must be x-free, no event lost ==");
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        c_bad_x = 0; c_bad_mask = 0; c_bad_alloc = 0; c_seen_x = 0;
        for (kc = 0; kc < 3; kc = kc + 1) begin
            ax_tmp = kc * 7;                     // 轴 0 / 7 / 14
            press_probe_z(ax_tmp[AXIS_W-1:0], 32'h0005_0000 + kc);
            $display("  INFO c: axis=%0d fifo=%b(x=%0d) head=%b cur=%b mask_x=%0d alloc=%0d voice=%0d",
                     ax_tmp, zobs_fifo_src, ((^zobs_fifo_src) === 1'bx),
                     zobs_head_src, zobs_cur_src, count_x(zobs_pool_mask),
                     zobs_alloc, zobs_alloc_voice);
            if ((^zobs_fifo_src) === 1'bx)                       c_seen_x = c_seen_x + 1;
            if (count_x(zobs_pool_mask) != 0)                    c_bad_x = c_bad_x + 1;
            if (zobs_pool_mask !== exp_mask(3'd0))               c_bad_mask = c_bad_mask + 1;
            if (!zobs_alloc)                                     c_bad_alloc = c_bad_alloc + 1;
        end
        chk("c0 (setup): the note_src_i port of DUT Z really is floating (z)",
            dut_z.note_src_i === 3'bzzz);
        chk("c1: pool_mask has NO x bit while note_src_i dangles", c_bad_x == 0);
        chk("c2: a dangling tag behaves like hand-play (src=0) -- Z-safe decode", c_bad_mask == 0);
        chk("c3: no event is lost while note_src_i dangles (alloc still happens)", c_bad_alloc == 0);
        chk("c4: all 3 dangling-tag events occupy voices", popcount(z_gate) == 3);
        run_ticks(1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== d: end-to-end pitch -- axis 14/15 keep phase_inc and are not drums ==");
        // ═══════════════════════════════════════════════════════════════════
        do_reset;
        //  轴 14 / 15（本缺陷的两个物理键）＋ 轴 0（对照）＋ 轴 5（源 B，非空洞性对照）
        press_probe_n(4'd14, 32'h0012_3456, 3'd0);
        d14_v    = obs_alloc_voice;
        d14_inc  = inc_at(obs_inc_bus, obs_alloc_voice);
        d14_ax   = axis_at(obs_axis_bus, obs_alloc_voice);
        d14_drum = obs_drum_bus[obs_alloc_voice];

        press_probe_n(4'd15, 32'h00AB_CDEF, 3'd0);
        d15_v    = obs_alloc_voice;
        d15_inc  = inc_at(obs_inc_bus, obs_alloc_voice);
        d15_ax   = axis_at(obs_axis_bus, obs_alloc_voice);
        d15_drum = obs_drum_bus[obs_alloc_voice];

        press_probe_n(4'd0, 32'h0011_2233, 3'd0);
        d0_v    = obs_alloc_voice;
        d0_inc  = inc_at(obs_inc_bus, obs_alloc_voice);
        d0_drum = obs_drum_bus[obs_alloc_voice];

        press_probe_n(4'd5, 32'h0022_3344, 3'd3);
        daux_v    = obs_alloc_voice;
        daux_inc  = inc_at(obs_inc_bus, obs_alloc_voice);
        daux_drum = obs_drum_bus[obs_alloc_voice];

        $display("  INFO d: ax14 voice=%0d inc=%08x drum=%b | ax15 voice=%0d inc=%08x drum=%b",
                 d14_v, d14_inc, d14_drum, d15_v, d15_inc, d15_drum);
        $display("  INFO d: ax0  voice=%0d inc=%08x drum=%b | aux(src=3,ax5) voice=%0d inc=%08x drum=%b",
                 d0_v, d0_inc, d0_drum, daux_v, daux_inc, daux_drum);

        chk("d1: axis 14 (src=0) keeps phase_inc bit-exact (not rewritten)", d14_inc === 32'h0012_3456);
        chk("d2: axis 15 (src=0) keeps phase_inc bit-exact (not rewritten)", d15_inc === 32'h00AB_CDEF);
        chk("d3: axis 0 control also keeps phase_inc bit-exact", d0_inc === 32'h0011_2233);
        chk("d4: the axis-14/15 voices really carry axis 14/15",
            (d14_ax === 4'd14) && (d15_ax === 4'd15));
        chk("d5: axis-14/15 voices are NOT drum voices (pitch drives the wavetable)",
            (d14_drum === 1'b0) && (d15_drum === 1'b0));
        chk("d6 (non-vacuous): src=3 raises voice_drum_o (d5 is not trivial)",
            daux_drum === 1'b1);
        chk("d7: the src=3 voice also keeps phase_inc bit-exact",
            daux_inc === 32'h0022_3344);
        chk("d8: the src=3 voice sits in the reserved pool (>= 28)", daux_v >= NORMAL_N);
        //  📌 ⚠️ 完整的"键 k => phase_inc == axis_map(kb_inc[k])"判据属于**顶层 tb**
        //     （⭐ 本 tb 只能证明"note_manager 没有改写音高"这一段）。
        run_ticks(1);

        if (errors == 0)
            $display("PASS: pool-by-source judgements (26.3 a/b/c/d) all held");
        else
            $fatal(1, "FAIL: pool-by-source (26.3 a/b/c/d) has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
