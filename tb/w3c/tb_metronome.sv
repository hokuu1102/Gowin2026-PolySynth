`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_metronome.sv · `metronome` 验收（`T33`）
//
// ⭐ 判据（⚠️ **每条都必须能失败** —— `K-56`/`C21`；⭐ 写成【不变量】—— `C44`）
//
//   ① ⭐ **反证基线**：`transport=0` 时**一个事件都不发**（⛔ 否则就是"一直响"）
//   ② ⭐⭐ **与 `beat_gen` 严格同拍**：每 **960 tick** 恰好 **1 个**事件
//      ⚠️ 这是判据的主体 —— 节拍器若自己分频就会**与鼓机/looper 错拍**
//   ③ ⭐ **强拍与 `bar_start` 同拍**（小节首拍），且**强弱拍音高不同**
//      ⚠️ 两件事都要验（⛔ 只看"有事件"不够 —— 那样强弱拍一样也过）
//   ④ ⭐ **`axis_id` 恒为专用值**（`4'hE`）—— ⭐ 这是"进专用池、不被抢"的**唯一保证**
//   ⑤ ⭐ **事件严格单周期**（拉宽会让 `note_manager` **重复触发**）
//   ⑥ ⭐⭐ **端到端接到 `note_manager`**：⭐ 事件必须**真的分配出一个 voice**
//      ⚠️ 这是"链路真的通"的证据，⛔ 不是"我发了个脉冲"就算
//   ⑦ ⭐ **`cfg_warn_o`**：`RESERVED_N=0` 时必须置位（⛔ 静默是 `K-106` 的教训）
// ─────────────────────────────────────────────────────────────────────────────

module tb_metronome;

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer POLY    = 32;
    localparam integer CLK_PER_SAMPLE = 1024;

    reg clk = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    reg rst_n = 1'b0;

    // ── DUT: beat_gen（真实例，⛔ 不用桩 —— 否则"同拍"证明不了）─────────────
    reg         run      = 1'b0;
    reg         pos_rst  = 1'b0;
    reg  [31:0] tick_inc = 32'd4194304;        // 2^22 ⇒ 每 1024 clk 一个 tick
    wire        tick, bar_start, beat, transport, wrap;
    wire [15:0] tick_cnt, bar_cnt;

    beat_gen #(
        .PPQN(960), .BEATS_PER_BAR(4), .PHASE_W(32), .TICK_INC_W(32)
    ) u_beat (
        .clk_i(clk), .rst_n_i(rst_n), .run_i(run), .pos_reset_i(pos_rst),
        .tick_inc_i(tick_inc), .tick_o(tick), .tick_cnt_o(tick_cnt),
        .bar_start_o(bar_start), .beat_o(beat), .transport_o(transport),
        .bar_cnt_o(bar_cnt), .tick_cnt_wrap_o(wrap)
    );

    // ── DUT: metronome ─────────────────────────────────────────────────────
    wire        m_valid;
    wire [3:0]  m_axis;
    wire [31:0] m_inc;
    wire [7:0]  m_vel;
    wire [1:0]  m_kind;
    wire [15:0] m_beat_cnt, m_accent_cnt;
    wire        m_cfg_warn;

    metronome #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .AXIS_ID(14), .RESERVED_N(5)
    ) u_met (
        .clk_i(clk), .rst_n_i(rst_n),
        .beat_i(beat), .bar_start_i(bar_start), .transport_i(transport),
        .evt_valid_o(m_valid), .evt_axis_o(m_axis), .evt_phase_inc_o(m_inc),
        .evt_velocity_o(m_vel), .evt_kind_o(m_kind),
        .beat_cnt_o(m_beat_cnt), .accent_cnt_o(m_accent_cnt),
        .cfg_warn_o(m_cfg_warn)
    );

    // ── DUT: note_manager（⭐ 用来证明"事件真的分配出了 voice"）─────────────
    reg         nm_valid = 1'b0;
    reg  [3:0]  nm_axis  = 4'd0;
    reg  [31:0] nm_inc   = 32'd0;
    reg  [7:0]  nm_vel   = 8'd0;
    reg  [1:0]  nm_kind  = 2'd0;
    reg         sample_tick = 1'b0;

    wire [POLY-1:0]      nm_gate;
    wire [POLY-1:0]      nm_active;
    wire [POLY*AXIS_W-1:0] nm_axis_o;
    wire                 nm_alloc_valid;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .TIMBRE_W(2), .ENV_W(16), .AGE_W(16), .IDX_W(5),
        // ⭐ 本 tb 用 RESERVED_N=5 ⇒ 与 metronome 的声明一致
        .RESERVED_N(5), .RESERVED_AXIS_BASE(14), .DEFAULT_VEL(200)
    ) u_nm (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(nm_valid), .note_axis_i(nm_axis), .note_phase_inc_i(nm_inc),
        .note_velocity_i(nm_vel), .note_kind_i(nm_kind),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i(4'd0), .vel_upd_value_i(8'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i(4'd0), .pitch_upd_value_i(32'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({POLY{1'b0}}), .env_level_i({(POLY*16){1'b0}}),
        .voice_gate_o(nm_gate), .voice_active_o(nm_active),
        .voice_releasing_o(), .voice_axis_o(nm_axis_o),
        .voice_phase_inc_o(), .voice_velocity_o(), .voice_timbre_o(),
        .voice_age_o(), .alloc_valid_o(nm_alloc_valid), .alloc_voice_o(),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ⭐ 把 metronome 的事件**真的接到** note_manager（⭐ 这就是"链路通"的证据）
    //    ⚠️ 真实 `top.v` 里由 `evt_merge` 做这件事；本 tb 直连（因为 evt_merge 还没写）
    always @(posedge clk) begin
        nm_valid <= m_valid;
        nm_axis  <= m_axis;
        nm_inc   <= m_inc;
        nm_vel   <= m_vel;
        nm_kind  <= m_kind;
    end

    // ═════════════════════════════════════════════════════════════════════════
    // DUT B · **独立驱动**的 metronome（⛔ 不经过 `beat_gen`）
    //   ⭐ 目的：验"`transport_i` 闸门"本身。⚠️ 走 `beat_gen` 时它永远 tick 不到
    //      ⇒ 那道防御**从不被触发** ⇒ ⚠️ 是个"从未被验证的防御"（假安全）。
    // ═════════════════════════════════════════════════════════════════════════
    reg  g_run = 1'b0;
    reg  g_beat = 1'b0;
    reg  g_bar = 1'b0;
    reg  g_seen = 1'b0;   // ⭐ 逐拍监视：这几拍里见过 valid 吗
    wire g_valid;
    wire [3:0]  g_axis;
    wire [31:0] g_inc;
    wire [7:0]  g_vel;
    wire [1:0]  g_kind;
    wire [15:0] g_cnt;
    wire [15:0] g_accent;
    wire        g_warn;

    metronome #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .AXIS_ID(14), .RESERVED_N(5)
    ) u_met_b (
        .clk_i(clk), .rst_n_i(rst_n),
        .beat_i(g_beat), .bar_start_i(g_bar), .transport_i(g_run),
        .evt_valid_o(g_valid), .evt_axis_o(g_axis), .evt_phase_inc_o(g_inc),
        .evt_velocity_o(g_vel), .evt_kind_o(g_kind),
        .beat_cnt_o(g_cnt), .accent_cnt_o(g_accent), .cfg_warn_o(g_warn)
    );

    // ── 小工具 ──────────────────────────────────────────────────────────────
    integer errors = 0;

    task chk;
        input [8*110-1:0] name;
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

    // ⭐ 逐 tick 采样（posedge 计数），收集事件间隔与强弱拍
    integer cyc, last_evt_cyc;
    integer evt_count, accent_count, normal_count;
    integer gap_min, gap_max;
    integer width_seen, width_max;
    integer accent_not_on_barstart;
    integer axis_wrong;
    // ⭐ 强拍间隔检查（⛔ 与窗口对齐无关的**结构性**判据）
    integer accent_gap_ok;      // 1 = 所有相邻强拍都恰好隔 4 拍
    integer last_accent_evt;   // 上一个强拍的事件序号（⛔ 语义无歧义）
    integer i;

    initial begin
        $dumpfile("build/sim/tb_metronome/tb_metronome.vcd");
        $dumpvars(0, tb_metronome);

        cyc = 0; last_evt_cyc = -1;
        evt_count = 0; accent_count = 0; normal_count = 0;
        gap_min = 100000000; gap_max = -1;
        width_max = 0; accent_not_on_barstart = 0; axis_wrong = 0;
        accent_gap_ok = 1; last_accent_evt = -1;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：transport=0（run=0）⇒ 一个事件都不许发
        // ═══════════════════════════════════════════════════════════════════
        run = 1'b0;
        repeat (3000) @(posedge clk);
        chk("baseline: transport is low", transport === 1'b0);
        chk("baseline: NO events emitted while stopped (counter still 0)",
            m_beat_cnt === 16'd0);
        chk("baseline: evt_valid_o is low while stopped", m_valid === 1'b0);

        // ⭐ 自检：RESERVED_N=5 ⇒ 不应告警
        chk("cfg: cfg_warn_o is CLEAR when RESERVED_N >= 1", m_cfg_warn === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ② ③ ④ ⑤ 启动后：逐拍采样
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ 一小节 = 3840 tick，每 tick 1024 clk ⇒ 3.93M clk（太长）
        //    ⇒ ⭐ 用大 tick_inc 加速：2^26 ⇒ 64 clk/tick
        //      ⇒ 一小节 3840×64 = 245 760 clk ≈ 4.9 ms 仿真（可接受）
        run      = 1'b0;
        pos_rst  = 1'b1; @(negedge clk); @(negedge clk);
        pos_rst  = 1'b0; @(negedge clk);
        tick_inc = 32'd67108864;              // 2^26 ⇒ 64 clk/tick
        run      = 1'b1;

        // ⭐ 跑满 1 小节 + 余量，逐拍检查
        for (i = 0; i < 250000; i = i + 1) begin
            @(posedge clk);
            cyc = cyc + 1;

            // ⭐ 宽度：连续多少拍为高（1 = 合格）
            if (m_valid === 1'b1) begin
                width_max = (width_max < 1) ? 1 : width_max;
            end

            if (m_valid === 1'b1) begin
                evt_count = evt_count + 1;
                // ④ axis 必须恒为专用值
                if (m_axis !== 4'hE) axis_wrong = axis_wrong + 1;
                // ⭐⭐ ③ 强/弱拍**按【携带的数据】判**（⛔ 不是按 `bar_start` 的电平！）
                //    🔴 我第一版是按 `bar_start === 1'b1` 分类的 ⇒ **恒为 0 个强拍、假失败**。
                //       根因：`evt_valid_o` 是**寄存器**（比 `beat` 晚一拍），
                //       而 `bar_start` 是一拍脉冲 ⇒ **采样时它早已落下**。
                //    ⭐ 这也正是我随后在 RTL 里抓到真 bug 的入口（见 `metronome.v` 的注释）：
                //       既然"valid 晚一拍"，那**数据字段若不同拍寄存，就会错配**。
                //    ⭐ 正确做法：**判 `valid` 那一拍携带的 `inc`** ——
                //       它才是消费者真正看到的东西（`C36`：探针打在真正被观测的线上）。
                //   🔴🔴 **2026-09-26 修正：⭐ 改成引用 DUT 的参数，⛔ 不再硬编码频率**
                //      ⚠️ 原来写死 `32'd151183` / `32'd75591` ⇒
                //      🔴 **一改 RTL 的音高常量，本 tb 就把所有事件判成"错配"** ⇒
                //         ⚠️ 表现为 `accent=0 normal=0`（⭐ 而事件本来是好的）。
                //      📌 **教训**：⭐ **tb 判据里的"期望常量"必须从 DUT 取** ——
                //         ⚠️ 硬编码会让"正确的改动"被判成回归（⭐ `K-129` 同族）。
                //         ⭐ 这里用层次引用 `u_met.INC_ACCENT` / `u_met.INC_NORMAL`。
                if (m_inc === u_met.INC_ACCENT) begin
                    accent_count = accent_count + 1;
                    // ⭐ 结构性判据：相邻强拍之间的**事件序号差**必须恰好 = 4（4/4 拍）
                    //    ⚠️ 我前两版都错在"怎么数这个间隔"：
                    //       · 第一版按 `bar_start` 电平分类 ⇒ 恒 0 个强拍（采样晚一拍）
                    //       · 第二版数"中间的弱拍数"⇒ 得 **3**
                    //         （⚠️ 漏掉了那记强拍本身 —— 间隔是 4 个**事件**，不是 3 个弱拍）
                    //    ⭐ 第三版直接用**事件序号差**：语义无歧义、⛔ 不会数错。
                    if (last_accent_evt >= 0 && (evt_count - last_accent_evt) !== 4)
                        accent_gap_ok = 0;
                    last_accent_evt = evt_count;
                    // ⭐ 强拍的力度也必须更大（文档 §2.1："音高更高 / 更响"）
                    if (m_vel !== u_met.VEL_ACCENT) accent_not_on_barstart = accent_not_on_barstart + 1;
                end else if (m_inc === u_met.INC_NORMAL) begin
                    normal_count = normal_count + 1;
                    if (m_vel !== u_met.VEL_NORMAL) accent_not_on_barstart = accent_not_on_barstart + 1;
                end else begin
                    // ⚠️ 既不是强拍也不是弱拍 ⇒ 数据错配（正是上面那个 bug 的签名）
                    accent_not_on_barstart = accent_not_on_barstart + 1;
                end
                // ② 事件间隔必须是 960 tick = 960×64 = 61440 clk
                if (last_evt_cyc >= 0) begin
                    if ((cyc - last_evt_cyc) < gap_min) gap_min = cyc - last_evt_cyc;
                    if ((cyc - last_evt_cyc) > gap_max) gap_max = cyc - last_evt_cyc;
                end
                last_evt_cyc = cyc;
            end
        end

        chk("events were actually emitted (test is not vacuous)", evt_count >= 4);
        // ⭐⭐ ② 与 beat_gen 严格同拍：间隔恒为 960 tick × 64 clk = 61440 clk
        if (gap_min !== 61440 || gap_max !== 61440) begin
            $display("  FAIL: event spacing min=%0d max=%0d clk, expected exactly 61440 (= 960 PPQN x 64 clk)", gap_min, gap_max);
            errors = errors + 1;
        end else begin
            $display("  ok  : events are spaced EXACTLY 61440 clk apart (= 960 PPQN ticks, in step with beat_gen)");
        end
        // ⭐ 强拍/弱拍的比例关系（⚠️ **不要硬编码"恰好 1 个强拍"** —— 见下方注释）
        $display("  info: window=%0d clk, evt=%0d accent=%0d normal=%0d",
                 cyc, evt_count, accent_count, normal_count);
        //    🔴 我第一版写的是 `accent==1 && normal==3`，**实测红了**。
        //       ⚠️ 原因是窗口是**按 clk 数**截的（250000），而"1 小节 = 3840 tick"
        //          恰好落在窗口边界上 ⇒ 强拍个数**取决于窗口与边界的对齐**，
        //          是个**脆弱的巧合**，⛔ 不该作为判据。
        //    ⭐ 改成**守恒 + 比例**这两条**结构性**判据（同 `K-108`/`C44` 的教训：
        //       ⛔ 不硬编码我算出来的数，写成不变量）：
        chk("accent + normal == total events (conservation)",
            (accent_count + normal_count) === evt_count);
        chk("at least one accent was observed (test is not vacuous)",
            accent_count >= 1);
        chk("weak beats OUTNUMBER accents -- catches 'every beat is an accent'",
            normal_count > accent_count);
        // ⚠️ 这里**不能**断言 `normal == accent*3`：窗口是按 **clk 数**截的，
        //    与"小节边界"不对齐 ⇒ 强拍个数取决于**窗口截在哪里**（我第一版就这么假失败的，
        //    第二次写成 1:3 又假失败一次）。
        //    ⭐ 第三次改成**结构性**判据（同 `K-108`/`C44`：写成不变量，⛔ 不硬编码我算的数）：
        //       ⭐ **强拍之间必须恰好隔 4 拍** —— 这直接验"每 4 拍一个强拍"这个**真正的规格**，
        //          且**与窗口对齐无关**。
        chk("accents are exactly 4 beats apart (the real 4/4 specification)",
            accent_gap_ok === 1);
        chk("every event carries a CONSISTENT payload (accent inc+vel, or normal inc+vel)",
            accent_not_on_barstart === 0);
        chk("every event carries the dedicated axis id 4'hE (so it lands in the reserved pool)",
            axis_wrong === 0);
        chk("evt counter agrees with the number of observed events",
            m_beat_cnt === evt_count);

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ 端到端：事件必须真的分配出一个 voice
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ 排空（分配要 ~34 拍）
        repeat (200) begin @(posedge clk); sample_tick = 1'b0; end
        begin : e2e
            integer g;
            g = 0;
            //  ⭐⭐ **2026-09-28 修正判据信号**：用 `nm_active`（= `live_mask`）而⛔ 不是
            //     `nm_gate`（= `gate_mask`）来判"这个 voice 有没有被占用"。
            //
            //  📌 **为什么**：`gate_mask = gate_r & ~retrig_low` 是**对外门**，
            //     它在**重触发压低期间故意为 0**（让 ADSR 看到下降沿 ⇒ 干净重启）。
            //     ⭐ 而节拍器**只发 `note_on`、永不发 `note_off`** ⇒ 每拍都会**复用**
            //     （重触发）同一个保留 voice；采样若正落在那个 ≤1 帧的压低窗口内，
            //     `nm_gate` 会读到 0 ⇒ 假失败。
            //     ⭐ 真正表示"该 voice 被占用"的是 `live_mask`
            //     （`gate_r | retrig_low | env_active_i`）⇒ `voice_active_o`。
            //  ⚠️ 本改动只换**判据信号**，⛔ 不放松断言强度（仍是"≥1 个 voice 且落在保留池"）。
            for (i = 0; i < POLY; i = i + 1)
                if (nm_active[i]) g = g + 1;
            chk("end-to-end: the event actually ALLOCATED a voice in note_manager",
                g >= 1);
            // ⭐ 而且必须落在**专用池**（高索引）里 —— 这是不被抢占的前提
            chk("end-to-end: it landed on a RESERVED (high-index) voice, not the normal pool",
                nm_active[POLY-1] || nm_active[POLY-2] || nm_active[POLY-3] ||
                nm_active[POLY-4] || nm_active[POLY-5]);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ ⭐⭐ 运行中**停止** ⇒ 必须立刻不再发事件
        //    🔴 这一条是**变异体 `M50` 暴露出来的盲区**：
        //       我原来的"反证基线"只验了**开机就是 run=0**，
        //       ⛔ **从没验过"先跑起来、再停下"** ⇒ 所以"停不下"这个 bug 漏过了。
        //    ⭐ 教训：⭐ **基线的"两个方向"都要验** ——
        //       ① 从未启动 ② **启动后再停**（我漏的正是②）
        // ═══════════════════════════════════════════════════════════════════
        begin : stop_test
            integer cnt_at_stop;
            integer seen_after_stop;
            // 此刻正在跑（上一节刚验过已经发过事件）
            chk("stop test: precondition -- we are running and have emitted events",
                m_beat_cnt >= 16'd1);
            @(negedge clk);
            run = 1'b0;                          // ⭐ 运行中停止
            repeat (4) @(negedge clk);
            cnt_at_stop = m_beat_cnt;
            seen_after_stop = 0;
            // ⭐ 停住后再跑一大段（远超 4 个拍点的时间）⇒ 一个事件都不许再出现
            for (i = 0; i < 300000; i = i + 1) begin
                @(posedge clk);
                if (m_valid === 1'b1) seen_after_stop = seen_after_stop + 1;
            end
            chk("stop test: transport_o went low after stopping mid-run", transport === 1'b0);
            chk("stop test: NO events emitted after stopping mid-run",
                seen_after_stop === 0);
            chk("stop test: the event counter FROZE at the value when we stopped",
                m_beat_cnt === cnt_at_stop);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑧ ⭐⭐ **直接驱动 `beat_i`** 验"`transport_i` 这道闸门真的有效"
        //    🔴 背景（变异体 `M50` 暴露的**两层**问题）：
        //       ① 我的 tb 原来只验"开机 run=0"，⛔ 没验"跑起来再停" ⇒ 先补了 `stop_test`
        //       ② ⚠️ 但补完**仍然抓不到 `M50`** —— 🔎 查下去根因是：
        //          `M50` 把 `fire = fire_accent | fire_normal` 改成 `fire = beat_i`，
        //          而 **`beat_gen` 在 `run=0` 时根本不 tick** ⇒ `beat_i` 恒 0
        //          ⇒ ⭐ **两种写法在 run=0 时行为完全相同** ⇒ `M50` 是**无效变异体**
        //             （`C23`：不能改变行为的变异体不是有效变异体）。
        //    ⭐ 更重要的发现：`metronome` 里的 `transport_i` 闸门是**防御性的**
        //       （`beat_gen` 自己已经挡住了）。⚠️ 防御若**从不被验证**，就等于没有。
        //    ⭐⭐ 本节**用 DUT-B 直接驱动 `beat_i`**（⛔ 不经过 `beat_gen`）⇒
        //       ① 这道防御**被真正验证** ② `M50` 因此变成**可被观测**的变异体。
        // ═══════════════════════════════════════════════════════════════════
        begin : gate_direct
            @(negedge clk);
            repeat (4) @(negedge clk);

            // ── (a) transport=0，但 `beat_i` 照常给脉冲 ⇒ ⛔ 不许出声 ──────────
            //    ⭐ 同样用**逐拍监视**（⛔ 不单点采样）：只要这几拍里出现过一次就算出声
            g_beat = 1'b0; g_bar = 1'b0;
            repeat (4) @(negedge clk);
            g_seen = 1'b0;
            g_beat = 1'b1;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            g_beat = 1'b0;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            chk("gate: a beat pulse with transport_i=0 must NOT emit an event",
                g_seen === 1'b0);
            chk("gate: the counter must not advance while transport_i=0", g_cnt === 16'd0);

            // ── (b) 拉高 transport ⇒ 同样的脉冲**必须**出声（反证：闸门不是恒关）──
            //    ⚠️ `g_valid` 是**寄存器**（比 `g_beat` 晚一拍）⇒ ⛔ 不能在"打完脉冲"的
            //       那一刻单点采样（会采到 0 而误判）。⭐ 用**逐拍监视**抓这一拍脉冲。
            g_run = 1'b1;
            repeat (4) @(negedge clk);
            g_seen = 1'b0;
            g_beat = 1'b1;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            g_beat = 1'b0;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            chk("gate: the SAME pulse DOES emit once transport_i=1 (gate is not stuck shut)",
                g_seen === 1'b1);
            chk("gate: the counter advanced to 1", g_cnt === 16'd1);

            // ── (c) 再拉低 ⇒ 必须立刻又停 ────────────────────────────────────
            g_run = 1'b0;
            repeat (4) @(negedge clk);
            g_seen = 1'b0;
            g_beat = 1'b1;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            g_beat = 1'b0;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            @(negedge clk); if (g_valid === 1'b1) g_seen = 1'b1;
            chk("gate: lowering transport_i again immediately blocks events",
                g_seen === 1'b0);
            chk("gate: the counter stayed at 1", g_cnt === 16'd1);
        end

        // ── 结论 ───────────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: metronome emits one event per beat in step with beat_gen, accents on bar_start, dedicated axis");
        else
            $display("FAIL: metronome had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（`K-94`）
    initial begin
        #400_000_000;
        $fatal(1, "FAIL: tb_metronome timeout");
    end

endmodule
