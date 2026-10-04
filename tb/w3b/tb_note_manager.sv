// ─────────────────────────────────────────────────────────────────────────────
// tb_note_manager.sv · `T54` 验收（W3b · 32 voice 分配 / 抢占 / 释放 / 参数更新）
//
// ⭐ 为什么这个 tb 必须存在（`K-56`）：
//   "全绿"本身不证明任何事 —— ⭐ **判据必须能失败**。
//   本 tb 的每一条都写成**可失败的具体数值断言**（⛔ 不是"看起来对"）。
//
// ⭐ 覆盖的 8 条判据（对应 `任务清单.md` `T54` 验收栏 + 冻结表要求）：
//   ① 事件 → voice gate 正确（note_on 置位、note_off 清位、DEFAULT_VEL、音色锁存）
//   ② ⭐ **支持"更新在响 voice"**（`vel_update` / `pitch_update` 按 `axis_id` 寻址）
//      —— 冻结表 §三 的**核心要求**（双阈值测速法靠它落地）
//   ③ ⭐ **同轴位重触发复用同一 voice**（⛔ 不吃掉第二个 voice）
//   ④ ⭐ **重触发真的让 ADSR 重起 Attack**（用真 `envelope_bank` 验 —— 最易静默失效）
//   ⑤ ⭐⭐ **抢占顺序**：空闲 → Release 且电平最低 → 年龄最老；**并列取最低索引**
//   ⑥ ⭐ **滑音不改 gate**（冻结表铁律：**参数永不产生音符**）
//   ⑦ ⭐ **`POLY_TARGET` 参数化**（32 档 + 4 档各一实例）
//   ⑧ ⭐ **专用 voice 池**（`T33b` 的地基）：节拍器轴位 ⛔ 不与普通轴位抢
//
// ⚠️ 为什么抢占要在 **`POLY_TARGET=4`** 的小实例上验：
//   `AXIS_W=4` ⇒ **只有 16 个不同轴位** ⇒ ⛔ **按不出 32 个同时按下的音**。
//   ⇒ 抢占的"占满"必须用**小复音数**才能构造出来（4 档：按 4 个就满）。
//
// ⚠️ 语法纪律（`K-91`）：⛔ **Verilog-2001**，⛔ 不用 SV 专有构造
//    （iverilog 接受 ≠ Gowin 接受；判据是**真跑一次综合**）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_note_manager;

    localparam integer POLY     = 32;
    localparam integer AXIS_W   = 4;
    localparam integer PHASE_W  = 32;
    localparam integer VEL_W    = 8;
    localparam integer TIMBRE_W = 2;
    localparam integer ENV_W    = 16;
    localparam integer AGE_W    = 16;
    localparam integer IDX_W    = 5;      // $clog2(32)
    // ⭐⭐ `K-106`：溢出计数位宽。⚠️ 本 tb 用 **4 bit**（饱和于 15）而不是默认 8 bit，
    //    ⭐ **故意**的 —— 这样"计数饱和"这条纪律**也能被判据覆盖**（灌 40 个 ⇒ 计数停在 15）。
    localparam integer EVT_LOST_W = 4;
    // ⚠️ T66: note_manager now SCANS (POLY_TARGET+4 = 36 cycles per allocation),
    // so a 'sample tick' must be longer than that or the FSM never finishes.
    localparam integer CLK_PER_SAMPLE = 64;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    reg [8*72-1:0] msg;                   // 便于拼串

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

    // ═════════════════════════════════════════════════════════════════════════
    // DUT A · 主实例（POLY_TARGET=32，接真 envelope_bank）
    // ═════════════════════════════════════════════════════════════════════════
    reg                    sample_tick;
    reg                    note_valid;
    reg  [AXIS_W-1:0]      note_axis;
    reg  [PHASE_W-1:0]     note_phase_inc;
    reg  [VEL_W-1:0]       note_velocity;
    reg  [1:0]             note_kind;
    //  ⭐⭐ A1（2026-09-29）：⭐ 事件**来源标记**（⭐ 0=live 手弹 / 1=score 曲谱 / 2=demo / 3=源B）
    //     ⭐ 只有本 tb 的**主实例**用它（⭐ 判据在文件尾 `a1_src_isolated_off`）
    //  ⭐⭐ 2026-09-30：⭐ **位宽 2 → 3**（⭐ 与 `note_manager.note_src_i` 同步；
    //     本 tb 只用到 0/1 两个值 ⇒ ⭐ 行为不变 ✅）
    reg  [2:0]             note_src = 3'd0;

    reg                    vel_upd_valid;
    reg  [AXIS_W-1:0]      vel_upd_axis;
    reg  [VEL_W-1:0]       vel_upd_value;
    //  ⭐⭐ A2（2026-09-29）：⭐ **参数更新通路的来源标记**（⭐ 0=手弹 / 1=曲谱）
    //     ⚠️ **只有主实例用它**（⭐ 判据在文件尾 `a2_upd_src_isolated`）✅
    reg  [2:0]             vel_upd_src = 3'd0;

    reg                    pitch_upd_valid;
    reg  [AXIS_W-1:0]      pitch_upd_axis;
    reg  [PHASE_W-1:0]     pitch_upd_value;
    reg  [2:0]             pitch_upd_src = 3'd0;   // ⭐ A2

    reg  [TIMBRE_W-1:0]    default_timbre;
    reg                    evt_timbre_valid;
    reg  [TIMBRE_W-1:0]    evt_timbre;

    wire [POLY-1:0]         voice_gate;
    wire [POLY-1:0]         voice_active;
    wire [POLY-1:0]         voice_releasing;
    wire [POLY*AXIS_W-1:0]  voice_axis;
    wire [POLY*PHASE_W-1:0] voice_phase_inc;
    wire [POLY*VEL_W-1:0]   voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY*AGE_W-1:0]   voice_age;
    wire                    alloc_valid;
    wire [IDX_W-1:0]        alloc_voice;

    // ⭐⭐ `K-106`：溢出可观测性（本节判据专用）
    wire                    event_lost;
    wire [EVT_LOST_W-1:0]   event_lost_cnt;
    reg                     event_lost_clr = 1'b0;

    wire [POLY-1:0]         env_active;
    wire [POLY*ENV_W-1:0]   env_level;
    //  ⭐ 重触发/抢占的包络清零脉冲（→ envelope_bank.retrig_reset_i）
    wire [POLY-1:0]         voice_retrig_reset;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W),
        // ⭐⭐ `K-106`：**故意把深度压到 4** —— 这样很容易灌满、从而**真的触发溢出**，
        //    ⚠️ 用默认 32 要灌 33 个事件才能溢出，判据会变长且脆。
        //    ⭐ 深度**本来就是参数**（`T66` 时就参数化了）⇒ 本 tb 覆盖"溢出的行为"，
        //      ⛔ 不断言"默认值是多少"（那由 `FIFO_MIN` 自检 + §K-106 文档管）。
        .FIFO_DEPTH(4), .EVT_LOST_CNT_W(EVT_LOST_W)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind),
        // ⭐ A1：来源标记（⭐ 本实例的判据要**按源**区分 `note_off`）
        .note_src_i(note_src),
        .vel_upd_valid_i(vel_upd_valid), .vel_upd_axis_i(vel_upd_axis),
        .vel_upd_value_i(vel_upd_value),
        //  ⭐ A2：更新通路的来源标记（⭐ 判据要**按源**区分"这次更新是谁发的"）
        .vel_upd_src_i(vel_upd_src),
        .pitch_upd_valid_i(pitch_upd_valid), .pitch_upd_axis_i(pitch_upd_axis),
        .pitch_upd_value_i(pitch_upd_value),
        .pitch_upd_src_i(pitch_upd_src),
        .default_timbre_i(default_timbre), .evt_timbre_valid_i(evt_timbre_valid),
        .evt_timbre_i(evt_timbre),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_age_o(voice_age),
        .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice),
        // ⭐⭐ `K-106`：事件队列溢出可观测性
        .event_lost_o(event_lost), .event_lost_cnt_o(event_lost_cnt),
        .event_lost_clr_i(event_lost_clr)
    );

    // ⭐ 真包络（判据 ④ 必须用真 ADSR —— 用桩就证明不了"Attack 重起"）
    //    ⚠️ 这里**故意用更快的包络参数**：默认 `DECAY_STEP=4` 时从峰值衰到 sustain
    //       要 (25600-6400)/4 = **4800 个采样拍** ⇒ tb 跑不动，且"还在 decay 中"
    //       会让"重触发"的观测判据失去意义（⚠️ 我第一版就踩了这个：
    //       200 拍后包络仍在 25360、**根本没到 sustain**，于是把
    //       "重触发后电平**上升**" 误判成了失败）。
    //    ⇒ 加速后：attack ≈ 39 拍、decay = 6 拍、release = 2 拍 ⇒ 观测干净。
    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W),
        .ATTACK_STEP(669), .DECAY_STEP(3200), .SUSTAIN_Q8(64), .RELEASE_STEP(3200)
    ) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐⭐ K-169（2026-09-30）：⭐ **振荡器相位复位判据专用实例** ✅
    //
    //   🔴 **为什么必须把 `oscillator_bank` 接进来**：
    //      ⭐ `K-169` 的失效**不发生在 `note_manager` 内部** ——
    //      ⭐ `note_manager` 的 `retrig_reset_r` **本来就发了**
    //         （⭐ `tb/w3b/tb_retrig_reset_span.sv:303-317` 已经证明"Release 尾巴里
    //          重按"这条路**确实产生了清零脉冲** ✅）
    //      🔴 是 **`oscillator_bank` 盯着 `voice_active`（= `live_mask`，**电平派生**）
    //         的上升沿** ⇒ ⭐ Release 尾巴里重按时**看不到边沿** ⇒ 复位被跳过 ✅
    //      ⇒ ⭐ **判据必须落在【相位寄存器】上** ⇒ ⭐ 必须把振荡器接进来 ✅
    //      📌 这正是 `C83`（探针假绿）的反面用法：⭐ **判据要盯真正失效的那个寄存器** ✅
    //
    //   ⚠️ **参数选择（⭐ 都是为了让判据"锐利"）**：
    //      · ⭐ `DBG_LANE=1` = **voice0 的第 2 个 lane**（⭐ `OSC_PER_VOICE=2`）
    //      · ⭐ `DETUNE_ON=1` ⇒ ⭐ 该 lane 的 `phase_seed = 1/4 周期`
    //        = `32'h4000_0000` ⇒ ⭐ **种子是个独特值**
    //        ⛔ 不会和"相位恰好为 0"混淆 ⇒ ⭐ 判据更锐利 ✅
    //      · ⭐ `DETUNE_SH=8` 显式写死（⛔ 不依赖默认值 —— `top.v` 就把它改成了 9）
    //      · ⚠️ `test_mode_i=0` 是**必需的**：⭐ 复位在 test 覆盖下**故意不做** ✅
    //   ⚠️ 本实例**只驱动观测线**，⛔ 不影响 DUT A/B/C 的任何输入 ✅
    // ═════════════════════════════════════════════════════════════════════════
    wire [POLY*2*16-1:0]   ob_samples;
    wire                   ob_valid;
    wire [PHASE_W-1:0]     ob_phase_dbg;

    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(2), .PHASE_W(PHASE_W),
        .OSC_SAMPLE_W(16), .TIMBRE_N(4), .TIMBRE_W(TIMBRE_W),
        .WT_DEPTH(1024), .WT_W(16),
        .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0),
        .ENABLE_FM(0), .DBG_LANE(1),
        .DETUNE_ON(1), .DETUNE_SH(8)
    ) u_osc_k169 (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(voice_active),
        .base_phase_inc_i(voice_phase_inc),
        .voice_timbre_i(voice_timbre),
        .voice_velocity_i(voice_velocity),
        .vibrato_mod_i(16'sd0),
        .test_mode_i(1'b0),
        .test_lane_active_i({(POLY*2){1'b0}}),
        .test_phase_inc_i({(POLY*2*PHASE_W){1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(ob_samples), .osc_valid_o(ob_valid),
        .phase_acc_dbg_o(ob_phase_dbg),
        //  ⭐ K-169 的**关键连线**：⭐ 起音相位复位 = **note_on 事件边沿**
        //     （⭐ ⛔ 不再是"`voice_active` 的上升沿" ✅）
        .voice_phase_rst_i(voice_retrig_reset)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // DUT B · 小实例（POLY_TARGET=4）—— ⭐ **抢占判据在这里验**
    // ═════════════════════════════════════════════════════════════════════════
    localparam integer SP = 4;
    localparam integer SI = 2;

    reg  [AXIS_W-1:0]  b_axis;
    reg                b_valid;
    wire [SP-1:0]      b_gate;
    wire [SP*AXIS_W-1:0] b_axis_o;
    wire [SP*AGE_W-1:0]  b_age;
    wire               b_alloc_valid;
    wire [SI-1:0]      b_alloc_voice;

    note_manager #(
        .POLY_TARGET(SP), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(SI)
    ) dut_b (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(b_valid), .note_axis_i(b_axis),
        .note_phase_inc_i(32'h0001_0000), .note_velocity_i(8'd100),
        .note_kind_i(2'd0),
        // ⭐ A1：本实例只有**单一来源**（手弹/live = 0）⇒ 恒接 0
        //    ⚠️ 必须**显式**接：留空 ⇒ `z` ⇒ `src_r == cur_src` 比较变 `x` ⇒ 🔴 判据假红
        .note_src_i(3'd0),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}), .vel_upd_value_i(8'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i(32'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({SP{1'b0}}), .env_level_i({(SP*ENV_W){1'b0}}),
        .voice_gate_o(b_gate), .voice_active_o(), .voice_releasing_o(),
        .voice_axis_o(b_axis_o), .voice_phase_inc_o(), .voice_velocity_o(),
        .voice_timbre_o(), .voice_age_o(b_age),
        // ⭐ 新端口留空（本实例用桩包络，不验重触发清零）
        .voice_retrig_reset_o(),
        .alloc_valid_o(b_alloc_valid), .alloc_voice_o(b_alloc_voice),
        // ⭐ `K-106`：本实例不验溢出 ⇒ 输出悬空、清输入接 0
        //    ⚠️ 这也顺带验证了"**老例化不接新端口仍然合法**"（新输入恒 0）
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // DUT C · 专用池实例（RESERVED_N=4，`T33b` 的地基）
    // ═════════════════════════════════════════════════════════════════════════
    localparam integer RSV_N = 4;
    localparam integer RNORM = POLY - RSV_N;      // 28

    reg  [AXIS_W-1:0]  c_axis;
    //  ⭐⭐ 2026-10-01 修B：⭐ **本实例的来源（可变）** —— ⭐ 因为【池改由来源选】了 ✅
    //   🔴 **改前**：⭐ `.note_src_i` **硬接 `3'd0`**，⭐ 而池按**轴号**选 ⇒ ⭐ 用轴 14/15 就能命中保留池
    //   ⭐ **改后**：⭐ 池按**来源**选（⭐ `src == SRC_AUX`，⭐ 即源 B = 3）⇒ ⭐ 本实例必须能**切来源** ✅
    reg  [2:0]         c_src;
    reg                c_valid;
    wire [POLY-1:0]    c_gate;
    wire [IDX_W-1:0]   c_alloc_voice;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(RSV_N), .DEFAULT_VEL(200), .IDX_W(IDX_W)
    ) dut_c (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(c_valid), .note_axis_i(c_axis),
        .note_phase_inc_i(32'h0001_0000), .note_velocity_i(8'd100),
        .note_kind_i(2'd0),
        // ⭐ A1：本实例的**来源**（⭐ 2026-10-01 修B 后改为**可变** —— 因为池按来源选 ✅）
        //    ⚠️ 必须**显式**接：留空 ⇒ `z` ⇒ `src_r == cur_src` 比较变 `x` ⇒ 🔴 判据假红
        .note_src_i(c_src),
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}), .vel_upd_value_i(8'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i(32'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({POLY{1'b0}}), .env_level_i({(POLY*ENV_W){1'b0}}),
        .voice_gate_o(c_gate), .voice_active_o(), .voice_releasing_o(),
        .voice_axis_o(), .voice_phase_inc_o(), .voice_velocity_o(),
        .voice_timbre_o(), .voice_age_o(),
        // ⭐ 新端口留空（本实例用桩包络，不验重触发清零）
        .voice_retrig_reset_o(),
        .alloc_valid_o(), .alloc_voice_o(c_alloc_voice),
        // ⭐ `K-106`：本实例不验溢出 ⇒ 输出悬空、清输入接 0
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ── 切片辅助函数 ────────────────────────────────────────────────────────
    function [AXIS_W-1:0] axis_of;
        input integer v;
        begin axis_of = voice_axis[v*AXIS_W +: AXIS_W]; end
    endfunction
    function [PHASE_W-1:0] phase_of;
        input integer v;
        begin phase_of = voice_phase_inc[v*PHASE_W +: PHASE_W]; end
    endfunction
    function [VEL_W-1:0] vel_of;
        input integer v;
        begin vel_of = voice_velocity[v*VEL_W +: VEL_W]; end
    endfunction
    function [TIMBRE_W-1:0] timbre_of;
        input integer v;
        begin timbre_of = voice_timbre[v*TIMBRE_W +: TIMBRE_W]; end
    endfunction
    function [ENV_W-1:0] env_of;
        input integer v;
        begin env_of = env_level[v*ENV_W +: ENV_W]; end
    endfunction
    function [AXIS_W-1:0] b_axis_of;
        input integer v;
        begin b_axis_of = b_axis_o[v*AXIS_W +: AXIS_W]; end
    endfunction
    function [AGE_W-1:0] b_age_of;
        input integer v;
        begin b_age_of = b_age[v*AGE_W +: AGE_W]; end
    endfunction

    function integer popcount;
        input [POLY-1:0] m;
        integer k; integer c;
        begin
            c = 0;
            for (k = 0; k < POLY; k = k + 1) if (m[k]) c = c + 1;
            popcount = c;
        end
    endfunction

    function integer b_popcount;
        input [SP-1:0] m;
        integer k; integer c;
        begin
            c = 0;
            for (k = 0; k < SP; k = k + 1) if (m[k]) c = c + 1;
            b_popcount = c;
        end
    endfunction

    // ── 激励任务 ────────────────────────────────────────────────────────────
    // T66: allocation is pipelined, so wait for the FSM to drain.
    // Waiting on alloc_valid only covers the ALLOCATE path; the retrigger and
    // note_off paths do not raise it, so also allow a fixed settle time.
    // T66: latch the allocate pulse while settling (it is 1 cycle wide and
    // happens before settle returns, so sampling afterwards always misses it).
    reg               saw_alloc;
    reg [IDX_W-1:0]   saw_alloc_voice;
    task settle; begin
        saw_alloc = 1'b0;
        repeat (POLY + 8) begin
            @(negedge clk);
            if (alloc_valid) begin
                saw_alloc       = 1'b1;
                saw_alloc_voice = alloc_voice;
            end
        end
    end endtask

    task press_a;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        input [VEL_W-1:0]   vel;
        begin
            @(negedge clk);
            note_valid = 1'b1; note_axis = ax; note_phase_inc = inc;
            note_velocity = vel; note_kind = 2'd0;
            @(negedge clk);
            note_valid = 1'b0;
            settle;
        end
    endtask

    task release_a;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            note_valid = 1'b1; note_axis = ax; note_kind = 2'd1;
            note_phase_inc = {PHASE_W{1'b0}}; note_velocity = {VEL_W{1'b0}};
            @(negedge clk);
            note_valid = 1'b0;
            settle;
        end
    endtask

    task press_b;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            b_valid = 1'b1; b_axis = ax;
            @(negedge clk);
            b_valid = 1'b0;
            settle;
        end
    endtask

    task press_c;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            c_valid = 1'b1; c_axis = ax;
            @(negedge clk);
            c_valid = 1'b0;
            settle;
        end
    endtask

    //  ⭐⭐ A2（2026-09-29）新增：⭐ 一条**带来源**的 `vel_upd`（⭐ 1 拍脉冲）
    task pulse_velupd_src;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  v;
        input [1:0]        s;
        begin
            @(negedge clk);
            vel_upd_valid = 1'b1; vel_upd_axis = ax; vel_upd_value = v;
            vel_upd_src   = s;
            @(negedge clk);
            vel_upd_valid = 1'b0;
        end
    endtask

    // 走 n 个采样拍
    //    ⚠️⚠️ `sample_tick_i` 必须**恰好高 1 个 clk**（它是"时钟使能"，不是电平）。
    //       我第一版写成"高 `CLK_PER_SAMPLE` 个 clk" ⇒ 每个 `run_ticks(1)`
    //       实际跑了 **16 个采样步** ⇒ 包络快了 16 倍 ⇒
    //       ⭐ "重触发后 15 拍应该还在爬升" 实际早就爬完并衰回 sustain 了
    //       ⇒ 判据假失败。（`K-93` 记录了这条：**tb 的时基必须和被测系统的节拍语义一致**）
    //  ⭐⭐ P5-1（2026-10-03）契约变更：⭐ `envelope_bank` 现在是**共享引擎 +
    //     每拍服务一个 voice**（⭐ 见 `rtl/w3b/envelope_bank.v` 的文件头）⇒
    //     **每帧必须留出 ≥34 拍**让 32 路全部更新完（⭐ 本 tb `POLY=32`
    //     ⇒ 轮转共 33 拍）⛔ 否则第 N 路之后**永远不更新**。
    //     ⇒ ⭐ 帧间空拍 **3 → 40**（⭐ 帧周期 5 → 42 拍）。
    //     ⛔ **判据一个字没改**，⭐ 只是把"拍"的**真实时长**放长 ——
    //        ⭐ 所有判据都是按**采样拍数**计的（⭐ `run_ticks(n)` = n 帧），
    //        ⛔ 不按 clk 数 ⇒ ⭐ 语义不变 ✅
    //     📌 代价：⭐ 仿真时间 ×8.4（⭐ 实测本 tb 仅 ~7 s ⇒ 约 60 s，⭐ 预算 300 s ✅）
    task run_ticks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk); sample_tick = 1'b1;   // ← 只高 1 拍
                @(negedge clk); sample_tick = 1'b0;
                repeat (40) @(negedge clk);
            end
        end
    endtask

    //  ⭐⭐ A2 新增：⭐ 数"松手后到包络归零"用了几个**采样拍**
    //   ⚠️ 上限 64 拍 ⇒ ⛔ 绝不静默死循环（⭐ `K-106` 同族纪律）
    //   ⚠️ **定义必须晚于 `run_ticks`**（⭐ 它要调用后者 ✅）
    task rel_ticks;
        input  integer v;
        output integer k;
        begin
            k = 0;
            while ((env_of(v) !== {ENV_W{1'b0}}) && (k < 64)) begin
                run_ticks(1);
                k = k + 1;
            end
        end
    endtask

    integer i;
    integer n;
    integer gate_count;
    reg [ENV_W-1:0] lvl_a;

    // ⭐⭐ 重触发清零监视（判据 4b）——
    //   ⭐ 判据写成【不变量】（⛔ 不是"抓某个波形"），
    //      这样即使上板是**偶发**（⭐ 用户实测"不好复现"），只要发生就必被抓到。
    //
    //   🔴 盯的是：⭐ **包络在非零时被"重新起振"**。
    //      判据 = 每个采样拍检查：⭐ 若某 voice 的 gate 在【上一拍还是低】的情况下
    //      变为高，则它的包络在那一拍**必须已经是 0**（= 清零脉冲确实生效了）。
    //      ⚠️ 老 bug 的表现正是"gate 抬高时包络还很高"（残余 6400 或更多）。
    //
    //   ⭐⭐ P5-1（2026-10-03）契约变更：⭐ `envelope_bank` 现在是**共享引擎 +
    //      32 拍轮转**（⭐ 见其文件头）⇒ ⭐ 第 v 路要 **tick 后第 (2+v) 拍**
    //      才落盘 ⇒ ⭐ 而 `note_manager` 的重触发在 tick 后 **1 拍**就把 gate
    //      抬回来（⭐ 它只管自己的门，⛔ 不等包络）⇒ ⭐ **上升沿那一拍读到的是
    //      轮转前的旧值**（⭐ 清零其实已经在 tick 上发生，⭐ 只是还没扫到 voice1）。
    //   ⭐ **判据语义不变**（⭐ ⛔ 没有放松）：⭐ 包络**只在 tick 上变**
    //      （⭐ 每 42 拍一次，⭐ 而本检查窗口只有 `POLY+4 = 36` 拍）
    //      ⇒ ⭐ "上升沿后 36 拍" 与 "上升沿那一拍" 读到的**是同一个值**
    //      ⇒ ⭐ 若清零脉冲**没生效**，⭐ 这里照样会红（⭐ 非空洞性保持 ✅）。
    reg        watch_voice;
    integer    watch_idx;
    reg        watch_gate_d;
    reg [ENV_W-1:0] watch_env_at_gate_rise;
    reg        watch_bad_rise;          // 🔴 见到"带残余电平的 gate 上升沿" ⇒ 违规
    reg        watch_pending;           // ⭐ P5-1：等轮转扫完该 voice 再判
    integer    watch_wait;

    always @(posedge clk) begin
        watch_gate_d <= voice_gate[watch_idx];
        if (watch_voice) begin
            //  ⭐ gate 上升沿：包络必须为 0（清零脉冲已生效）
            if (voice_gate[watch_idx] && !watch_gate_d) begin
                watch_env_at_gate_rise <= env_of(watch_idx);
                watch_pending          <= 1'b1;
                watch_wait             <= 0;
            end else if (watch_pending) begin
                if (watch_wait >= (POLY + 4)) begin
                    watch_pending <= 1'b0;
                    if (env_of(watch_idx) !== {ENV_W{1'b0}})
                        watch_bad_rise = 1'b1;
                end else begin
                    watch_wait <= watch_wait + 1;
                end
            end
        end
    end
    reg [AGE_W-1:0] age_a;
    reg [AGE_W-1:0] age_b;

    initial begin
        sample_tick      = 1'b0;
        note_valid       = 1'b0;
        note_axis        = {AXIS_W{1'b0}};
        note_phase_inc   = 32'h0010_0000;
        note_velocity    = {VEL_W{1'b0}};
        note_kind        = 2'd0;
        vel_upd_valid    = 1'b0;
        vel_upd_axis     = {AXIS_W{1'b0}};
        vel_upd_value    = {VEL_W{1'b0}};
        pitch_upd_valid  = 1'b0;
        pitch_upd_axis   = {AXIS_W{1'b0}};
        pitch_upd_value  = 32'd0;
        default_timbre   = 2'd1;
        evt_timbre_valid = 1'b0;
        evt_timbre       = 2'd0;
        b_valid          = 1'b0;
        b_axis           = {AXIS_W{1'b0}};
        c_valid          = 1'b0;
        c_axis           = {AXIS_W{1'b0}};
        c_src            = 3'd0;          // ⭐ 2026-10-01 修B：⭐ 复位默认 = 手弹（live）✅

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 1: 事件 -> voice gate（含 DEFAULT_VEL / 音色锁存）==");
        // ═══════════════════════════════════════════════════════════════════
        chk("复位后 0 个 gate", popcount(voice_gate) == 0);

        press_a(4'd3, 32'h0010_0000, 8'd0);      // vel=0 ⇒ 应用 DEFAULT_VEL
        chk("note_on 后有 1 个 gate", popcount(voice_gate) == 1);
        chk("分配落在最低空闲索引 voice0", saw_alloc === 1'b1 && saw_alloc_voice === 5'd0);
        chk("voice0 的 axis = 3", axis_of(0) === 4'd3);
        chk("voice0 的 phase_inc 正确", phase_of(0) === 32'h0010_0000);
        chk("vel=0 时套用 DEFAULT_VEL(200)", vel_of(0) === 8'd200);
        chk("音色锁存 = 默认音色(1)", timbre_of(0) === 2'd1);

        press_a(4'd5, 32'h0020_0000, 8'd77);
        chk("第二个 note_on 后有 2 个 gate", popcount(voice_gate) == 2);
        chk("分配取下一个最低空闲 voice1", saw_alloc === 1'b1 && saw_alloc_voice === 5'd1);
        chk("vel 非 0 时用事件值(77)", vel_of(1) === 8'd77);

        // ⭐ Looper 每层覆盖音色（`K-82`）
        evt_timbre_valid = 1'b1; evt_timbre = 2'd3;
        press_a(4'd7, 32'h0040_0000, 8'd88);
        evt_timbre_valid = 1'b0;
        chk("evt_timbre 覆盖默认音色（Looper 每层）", timbre_of(2) === 2'd3);

        release_a(4'd3);
        chk("note_off(axis3) 后 gate 少一个", popcount(voice_gate) == 2);
        chk("被关的是 voice0", voice_gate[0] === 1'b0);
        chk("voice1 仍在响", voice_gate[1] === 1'b1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 2: 支持'更新在响 voice'（vel_update / pitch_update）==");
        // ═══════════════════════════════════════════════════════════════════
        @(negedge clk);
        vel_upd_valid = 1'b1; vel_upd_axis = 4'd5; vel_upd_value = 8'd240;
        @(negedge clk);
        vel_upd_valid = 1'b0;
        //  ⭐⭐ 2026-09-28 **契约变更**（⭐ 修"又响又尖"，⭐ 见 `K-154`）：
        //     ⭐ 力度现在是【斜坡】—— 每音频采样拍最多变 **±8**（⭐ 满量程 0.65 ms）
        //     📌 ⭐ **用户 2026-09-28 拍板选 ±8**（⭐ 折中：⭐ 削掉突变 + 延迟几乎无感）
        //     ⇒ ⛔ **不再"一拍到位"**（⭐ 旧契约"立即 == 240"正是【被修掉的行为】）
        //     ⭐ 新契约更强：⭐ **先过渡、再收敛到 240** ✅
        //     ⚠️ **不要假设起始值**（⭐ 探针实测起始是 **77**，⛔ 不是 200）
        run_ticks(1);       // ⭐ 至少一个采样拍才可能开始过渡
        //  ⚠️ 2026-09-29: criterion NAMES must be ASCII-only.
        //     vvp mangles non-ASCII $display output on this machine (measured:
        //     the bytes get rewritten AND the FOLLOWING ASCII char is eaten),
        //     so an automated verdict that matches the criterion name must not
        //     rely on Chinese text.  The ASSERTIONS below are unchanged.
        chk("vel_update takes effect (left the start point, ramping toward 240)",
            (vel_of(1) > 8'd0) && (vel_of(1) < 8'd240));
        run_ticks(40);      // ⭐ (240−77)/8 = 21 拍，⭐ 留 ~2× 余量
        chk("vel_update converges to 240 (ramp completed)", vel_of(1) === 8'd240);
        chk("vel_update leaves the released voice0 untouched", vel_of(0) === 8'd200);

        @(negedge clk);
        pitch_upd_valid = 1'b1; pitch_upd_axis = 4'd5; pitch_upd_value = 32'h00AB_CDEF;
        @(negedge clk);
        pitch_upd_valid = 1'b0;
        chk("pitch_update 改到在响的 voice1", phase_of(1) === 32'h00AB_CDEF);

        // 对**空闲** axis 发修正 ⇒ ⛔ 不该凭空造出 voice
        gate_count = popcount(voice_gate);
        @(negedge clk);
        vel_upd_valid = 1'b1; vel_upd_axis = 4'd9; vel_upd_value = 8'd123;
        @(negedge clk);
        vel_upd_valid = 1'b0;
        chk("对空闲 axis 的修正不产生新 voice", popcount(voice_gate) == gate_count);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 6: 滑音不产生音符（冻结表铁律）==");
        // ═══════════════════════════════════════════════════════════════════
        gate_count = popcount(voice_gate);
        @(negedge clk);
        pitch_upd_valid = 1'b1; pitch_upd_axis = 4'd5; pitch_upd_value = 32'h0000_1111;
        @(negedge clk);
        pitch_upd_valid = 1'b0;
        chk("滑音不改 gate 数（参数不产生音符）", popcount(voice_gate) == gate_count);
        chk("滑音后 axis 归属不变", axis_of(1) === 4'd5);
        chk("滑音确实改了 phase_inc", phase_of(1) === 32'h0000_1111);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 3: 同轴位重触发复用同一 voice ==");
        // ═══════════════════════════════════════════════════════════════════
        // ⚠️ 重触发是**两步走**（压 gate → 等采样拍 → 抬 gate → 等采样拍）
        //    ⇒ ⛔ 不能"按完立刻查"：那一刻 gate 正被**故意**压低。
        gate_count = popcount(voice_gate);
        press_a(4'd5, 32'h0033_0000, 8'd100);
        run_ticks(3);                          // ⭐ 等重触发走完两步
        chk("重触发后 gate 数不变（没多吃 voice）", popcount(voice_gate) == gate_count);
        chk("重触发仍落在 voice1", voice_gate[1] === 1'b1);
        chk("重触发更新了 phase_inc", phase_of(1) === 32'h0033_0000);
        chk("重触发更新了 vel", vel_of(1) === 8'd100);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 4: 重触发真的让 ADSR 重起 Attack（最易静默失效）==");
        // ═══════════════════════════════════════════════════════════════════
        // 包络参数：peak = 100<<8 = 25600；SUSTAIN_Q8=64 ⇒ sustain = 6400
        // ⚠️ 判据必须落在 **sustain 平台**上：
        //    · 若重触发**没生效** ⇒ ADSR 停在 ST_SUSTAIN ⇒ 电平**恒为 6400**
        //    · 若重触发**生效**   ⇒ 回 ST_ATTACK ⇒ 电平**从 6400 往 25600 爬**
        //    ⇒ ⭐ 判据 = "重触发后电平**显著高于** sustain"（⛔ 不是"低于"，我第一版写反了）
        run_ticks(60);
        lvl_a = env_of(1);
        chk("长跑后包络落在 sustain 平台（6400）", lvl_a === 16'd6400);

        // ⭐⭐ 重触发前先武装"清零监视"：⛔ 必须在 `press_a` **之前** 复位，
        //     否则会漏掉重触发那一拍。
        watch_voice    = 1;
        watch_idx      = 1;
        watch_bad_rise = 1'b0;

        press_a(4'd5, 32'h0033_0000, 8'd100);  // ⭐ 重触发
        run_ticks(15);
        watch_voice = 0;
        chk("重触发后 gate 已抬回（voice1 在响）", voice_gate[1] === 1'b1);
        chk("重触发后电平显著高于 sustain => Attack 确实重起",
            env_of(1) > (lvl_a + 16'd2000));

        // ═══════════════════════════════════════════════════════════════════
        // 🔴🔴 判据 4b：⭐ **gate 重新抬高时包络必须已经在 0**（2026-09-27 新增）
        //
        //   ⚠️ 这条守的是**上板实测的"偶发刺耳尖音"**：
        //      🔴 旧行为把 `gate` 压低仅 **1 个 sample_tick（20.5 µs）** 就抬高，
        //         而 ADSR 归零需要 `65535/RELEASE_STEP` 个采样拍 ⇒ **包络几乎没掉**；
        //         `gate` 一回来 ADSR 直接回 `ST_ATTACK` 并从**残余电平**往 peak 爬
        //         ⇒ ⭐ 旧尾巴 + 新 Attack 叠加 ⇒ **幅度 ~11 倍**（示波器实测）。
        //   ⭐ 判据写成【不变量】—— 每个 gate 上升沿都检查，⛔ 不依赖复现某个波形。
        //   📌 与 `L55` 同一套写法：不变量 + 只盯"真正驱动行为的那一层"。
        // ═══════════════════════════════════════════════════════════════════
        chk("⭐ gate 重新抬高时包络为 0（⛔ 无残余电平起振）",
            watch_bad_rise === 1'b0);

        run_ticks(60);
        chk("重触发后包络重新回到 sustain 平台", env_of(1) === 16'd6400);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 8: 专用 voice 池（节拍器不参与普通抢占，T33b 地基）==");
        // ═══════════════════════════════════════════════════════════════════
        //   ⭐⭐ 2026-10-01 修B：⭐ **池改由【来源】选**（⛔ 不再按轴号）⇒ 本节激励与判据同步 ✅
        //   🔴 **旧判据**：⭐ 用轴 14/15 去命中保留池 —— ⚠️ 那正是**被修掉的行为**
        //      （⭐ 它是"物理键 14/15 不响"的根因 ⚠️）
        //   ✅ **新判据（两条，⭐ 缺一不可）**：
        //      ① ⭐ **手弹（`src=0`）无论哪个轴都进普通池** —— ⭐ 这就是"键 14/15 出声"的**正面判据** ✅
        //      ② ⭐ **源 B（`src=3`）无论哪个轴都进保留池** —— ⭐ 节拍器/鼓机照旧 ✅（非空洞性）
        c_src = 3'd0;
        press_c(4'd0);                          // ⭐ 手弹，轴 0
        chk("手弹（src=0）轴 0 落在普通池（< 28）", c_alloc_voice < RNORM);
        c_src = 3'd0;
        press_c(4'd14);                         // ⭐ **修B 的正面判据**：手弹的轴 14（G#3）
        chk("⭐ 修B：手弹（src=0）的轴 14 落在【普通池】—— 键 14/15 出声的判据", c_alloc_voice < RNORM);
        c_src = 3'd3;                           // ⭐ 源 B（节拍器/鼓机）
        press_c(4'd14);                         // ⭐ 源 B 即使轴号是 14，也进保留池 ✅
        chk("源 B（src=3）落在专用池（>= 28）", c_alloc_voice >= RNORM);
        c_src = 3'd3;
        press_c(4'd15);
        chk("第二个源 B 事件也落在专用池", c_alloc_voice >= RNORM);
        chk("两个专用 voice 互不相同", c_gate[28] === 1'b1 && c_gate[29] === 1'b1);
        chk("普通轴位 gate 也在（互不干扰）", c_gate[0] === 1'b1);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 5: 抢占顺序（在 POLY_TARGET=4 小实例上验）==");
        // ═══════════════════════════════════════════════════════════════════
        // 5a) 空闲优先 + 并列取最低索引：按 4 个轴 ⇒ 拿 voice0..3
        press_b(4'd0); press_b(4'd1); press_b(4'd2); press_b(4'd3);
        chk("4 个轴占满 4 个 voice", b_popcount(b_gate) == 4);
        chk("占的是 voice0..3", b_gate === 4'b1111);
        chk("axis 归属正确", b_axis_of(0) === 4'd0 && b_axis_of(3) === 4'd3);

        // 5b) ⭐ 真抢占：再按第 5 个轴（axis4）⇒ 池满 ⇒ 必须抢占**最老**的
        //     ⚠️ 此刻所有年龄都是 0（还没走过 sample_tick）⇒ 并列 ⇒ 取**最低索引 voice0**
        press_b(4'd4);
        chk("占满后第 5 个音仍被分配（不静默丢音）", b_popcount(b_gate) == 4);
        chk("并列取最低索引 => 抢占 voice0", b_axis_of(0) === 4'd4);
        chk("其余三个不受影响", b_axis_of(1) === 4'd1 &&
                               b_axis_of(2) === 4'd2 &&
                               b_axis_of(3) === 4'd3);

        // 5c) ⭐ 年龄最老优先
        //     ⚠️ 关键：**年龄只在 `sample_tick_i` 那一拍才 +1**（不是每个 clk）
        //        ⇒ 必须**先跑一段采样拍**把在场 voice 变老，⛔ 否则全同龄、只能看到"并列取最低索引"。
        //     ⚠️ 我第一版把"抢完 voice0 再跑 6 拍"当成"voice0 更年轻"—— **错了**：
        //        那 6 拍会把 **所有** 在场 voice 一起加 6 ⇒ 仍然同龄。
        run_ticks(6);                           // ① 先把 voice0..3 一起变老
        age_a = b_age_of(0);
        chk("跑过采样拍后年龄已增长（voice0）", age_a > 0);

        press_b(4'd4);                          // ② 池满 ⇒ 抢最老；此刻同龄 ⇒ 取最低索引 voice0
        chk("同龄时取最低索引 => 抢 voice0", b_axis_of(0) === 4'd4);
        chk("抢完后 voice0 变年轻（年龄被清零）", b_age_of(0) < age_a);
        age_b = b_age_of(1);
        chk("voice1 仍然老（未被抢）", age_b === age_a);

        // ③ ⭐ 现在 voice0(年轻) vs voice1..3(老) ⇒ 再按一个必须抢 **voice1**（最老 + 最低索引）
        press_b(4'd5);
        chk("抢到的是最老且最低索引的 voice1", b_axis_of(1) === 4'd5);
        chk("voice0（较年轻）未被抢", b_axis_of(0) === 4'd4);
        chk("voice2/3 未被抢", b_axis_of(2) === 4'd2 && b_axis_of(3) === 4'd3);

        // 5d) ⭐ 抢占②：Release 且电平最低优先于"年龄最老"
        //     ⚠️ 本小实例没接 envelope_bank（env_active_i 恒 0）⇒ 候选②永不命中，
        //        这正是"②不命中就退到③"的路径，已由 5b/5c 覆盖。
        //        ⭐ 候选②的正确性由 `tb_note_manager_env` 场景覆盖（接真包络）。
        chk("小实例上无 X", ^b_gate !== 1'bx);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 7: POLY_TARGET 参数化（32 档已全程使用；再验 16 轴占满）==");
        // ═══════════════════════════════════════════════════════════════════
        // 清场（主实例）
        for (i = 0; i < 16; i = i + 1) release_a(i[AXIS_W-1:0]);
        run_ticks(400);
        chk("清场后主实例 0 个 gate", popcount(voice_gate) == 0);

        // 16 个不同轴位 ⇒ 16 个不同 voice（空闲优先、最低索引）
        for (i = 0; i < 16; i = i + 1)
            press_a(i[AXIS_W-1:0], 32'h0001_0000 + i, 8'd100);
        chk("16 个轴占 16 个 voice", popcount(voice_gate) == 16);
        chk("占的是最低的 voice0..15", voice_gate[15:0] === 16'hFFFF);
        chk("voice16..31 仍空闲（AXIS_W=4 只有 16 轴）",
            voice_gate[31:16] === 16'h0000);

        // ⭐ 关键：`AXIS_W=4` ⇒ 最多 16 个同时按下的音
        //    ⇒ ⭐ **`POLY_TARGET=32` 不是"浪费"** —— 它给 Looper 多层 + 专用 voice 用
        //      （`K-92` 已记录这个"轴位数 < 复音数"的事实）
        n = popcount(voice_gate);
        chk("同时可按下的上限 = 16（受 AXIS_W 限制，非 POLY_TARGET）", n == 16);

        // ---- 9: mid-retrigger voice must stay BUSY (not stealable) ----
        // Guards the K-103-era fix: during the 2-tick retrigger hold the gate is
        // low, but the voice is still in use.  If live_mask drops the hold term,
        // the voice looks free and a different axis can grab it -- and then the
        // retrigger yanks the gate back up, stealing the new note's voice.
        // NOTE: this section builds its OWN clean state; earlier sections leave
        // many voices sounding, so nothing may be assumed about voice ownership.
        $display("== 9: mid-retrigger voice is not stealable ==");
        begin
            integer v9;
            integer total_before;
            integer stolen_axis;

            // clean slate: release every axis and let the envelopes finish
            for (v9 = 0; v9 < 16; v9 = v9 + 1) release_a(v9[AXIS_W-1:0]);
            run_ticks(400);
            chk("section 9: clean slate (0 gates)", popcount(voice_gate) == 0);

            // start axis 5 -> it takes the lowest free voice (voice0)
            press_a(4'd5, 32'h0010_0000, 8'd100);
            chk("section 9: axis 5 owns voice0", axis_of(0) === 4'd5);
            total_before = popcount(voice_gate);
            chk("section 9: exactly 1 gate before the test", total_before == 1);

            // retrigger axis 5, then IMMEDIATELY press a different axis
            @(negedge clk);
            note_valid = 1'b1; note_axis = 4'd5; note_phase_inc = 32'h0033_0000;
            note_velocity = 8'd100; note_kind = 2'd0;
            @(negedge clk);
            note_valid = 1'b0;
            @(negedge clk);
            note_valid = 1'b1; note_axis = 4'd11; note_phase_inc = 32'h0055_0000;
            note_velocity = 8'd100; note_kind = 2'd0;
            @(negedge clk);
            note_valid = 1'b0;
            settle;

            chk("section 9: axis 5 still owns voice0 (hold kept it busy)",
                axis_of(0) === 4'd5);
            // ⚠️ `voice_gate` is the EXTERNAL gate, which is deliberately 0 while
            // axis 5 is mid-retrigger (that is how the ADSR sees a fresh edge).
            // So the right judgement is ownership, not the raw gate count.
            chk("section 9: the other axis landed on a DIFFERENT voice",
                axis_of(1) === 4'd11);
            chk("section 9: axis 5 was NOT stolen (still on voice0)",
                axis_of(0) === 4'd5);
        end

        // ═════════════════════════════════════════════════════════════════════
        // section 10 · ⭐⭐ `K-106`：事件队列【溢出可观测性】
        //
        //   🔴 修的是什么：`fifo_push = note_valid_i && !fifo_full` ⇒ 溢出**静默丢弃**。
        //      ⚠️ 丢的若是 `note_off` ⇒ **挂音**（`T38` 要防的失效模式）。
        //   ⭐ 本节判据（⚠️ **每一条都能失败** —— `K-56`/`C21`）：
        //      ① 灌满后继续发 ⇒ **`event_lost_o` 置位**（sticky）
        //      ② 计数 = **灌入数 − 深度**（精确值，⛔ 不是"大于 0"）
        //      ③ 计数**饱和**（⛔ 不回绕 —— 回绕会把"丢 16 个"显示成"丢 0 个"）
        //      ④ sticky **只置位、不自动清**（⛔ 不被后续正常帧掩盖）
        //      ⑤ `event_lost_clr_i` 能**清掉**（且清后能再次置位 ⇒ 不是死锁）
        //      ⑥ 溢出期间**没被丢的事件仍然被正确分配**（⛔ 不是"溢出就全废"）
        //      ⑦ ⚠️ **反证**：不灌满时 `event_lost_o` **必须为 0**（否则判据①是空的）
        // ═════════════════════════════════════════════════════════════════════
        begin : fifo_overflow
            integer n_press;
            integer expected_cnt;
            integer v9;                       // ⚠️ 本命名块自己的循环变量（块间不共享）

            // ── ⑦ 反证基线：先确认"没溢出时指示为 0" ────────────────────────
            //    ⚠️ 没有这一步，判据① 可能因为"标志恒 1"而假通过（`C36`）
            event_lost_clr = 1'b1; @(negedge clk); event_lost_clr = 1'b0;
            @(negedge clk);
            chk("K-106: baseline - event_lost is 0 BEFORE any overflow",
                event_lost === 1'b0);
            chk("K-106: baseline - lost count is 0 BEFORE any overflow",
                event_lost_cnt === {EVT_LOST_W{1'b0}});

            // 先释放干净，避免上几节残留的 voice 干扰
            for (v9 = 0; v9 < 16; v9 = v9 + 1) release_a(v9[AXIS_W-1:0]);
            run_ticks(400);

            // ── 灌入：连续 12 个事件，而 FIFO 深度 = 4 ──────────────────────
            //    ⭐ 关键：**背靠背连发**（每个事件只隔 1 拍）⇒ FSM 来不及排空
            //      ⇒ 前 4 个进队列，**后 8 个被丢**。
            //    ⚠️ 用不同轴位，便于随后检查"谁真的被服务了"。
            @(negedge clk);
            for (n_press = 0; n_press < 12; n_press = n_press + 1) begin
                note_valid    = 1'b1;
                note_axis     = n_press[AXIS_W-1:0];
                note_phase_inc= 32'h0010_0000 + n_press;
                note_velocity = 8'd100;
                note_kind     = 2'd0;              // note_on
                @(negedge clk);
                note_valid    = 1'b0;
                @(negedge clk);                    // ⭐ 只隔 1 拍 ⇒ 必然溢出
            end

            // ── ① sticky 置位 ───────────────────────────────────────────────
            chk("K-106: event_lost asserts after overflowing the queue",
                event_lost === 1'b1);

            // ⭐⭐ 必须先**把队列排空**再验守恒 —— 突发刚结束时 FSM 还没分配
            //    （实测：此刻 `popcount=0`，若马上验守恒会误报 12 ≠ 7+0）。
            //    ⚠️ 这是"判据要打在**稳态**上，⛔ 不是过渡过程"（`C33`）。
            settle;
            run_ticks(300);

            // ── ② ⭐⭐ 计数守恒（**不变量**，⛔ 不是硬编码常数）─────────────────
            //    🔴 我第一版写的是 `12 - 4 = 8`，**实测是 7** ⇒ 判据红了。
            //       ⚠️ 查下去发现**是我的模型错了，RTL 是对的**：
            //       FIFO 深度 4，但**FSM 同时在排空** ⇒ 一次突发里能被吸收的不止 4 个。
            //       实测：`fifo_cnt` 最大到 4（✅ 没溢出覆盖），**服务了 5 个**（轴 0..4），
            //       丢了 7 个（轴 5..11）。
            //    ⭐ 教训（`C36`）：⭐ **判据要写成【不变量】而不是"我算出来的那个数"** ——
            //       硬编码常数会把"我的模型错"误报成"被测错"。
            //    ⭐ 正确的不变量 = **【守恒】**：
            //        灌入总数 = 被服务数 + 被丢弃数
            //      ⚠️ 它同时能抓到两种真 bug：① 静默丢（丢了但不计数）
            //                              ② 重复计数（计数比实际丢的多）
            expected_cnt = 12 - popcount(voice_gate);
            if (event_lost_cnt !== expected_cnt[EVT_LOST_W-1:0]) begin
                $display("  FAIL: K-106: lost count = %0d, but CONSERVATION says %0d (12 pressed - %0d served)",
                         event_lost_cnt, expected_cnt, popcount(voice_gate));
                errors = errors + 1;
            end else begin
                $display("  ok  : K-106: lost count = %0d and 12 = %0d served + %0d lost (conservation holds)",
                         event_lost_cnt, popcount(voice_gate), event_lost_cnt);
            end
            // ⭐ 并且必须真的丢了一些、又真的服务了一些（⛔ 否则上面那条是空的）
            chk("K-106: the burst really did overflow (lost > 0)", event_lost_cnt > 0);
            chk("K-106: the burst was not entirely lost (served > 0)", popcount(voice_gate) > 0);

            // ── ③ sticky 不被后续正常事件掩盖 ──────────────────────────────
            //    ⚠️ 溢出早已停止，此刻**正在正常处理**队列里剩下的事件
            //       ⇒ 若 sticky 被"正常帧"清掉，这一条会红
            //    ⭐ 记下 settle 前的读数，之后必须**一字不变**（⛔ 不许再涨/被清）
            expected_cnt = event_lost_cnt;
            settle;
            chk("K-106: sticky stays set while later events are processed normally",
                event_lost === 1'b1);
            chk("K-106: lost count is unchanged by later normal events",
                event_lost_cnt === expected_cnt[EVT_LOST_W-1:0]);

            // ── ⑥ 没被丢的事件仍被正确分配 ─────────────────────────────────
            //    ⭐ 被服务的**第一个**事件（轴 0）必须真的拿到 voice
            //    ⚠️ 反过来说：我们不能只说"报了个错就算了"，功能必须仍然工作
            chk("K-106: the events that FIT were still allocated (axis 0 got a voice)",
                axis_of(0) === 4'd0 || axis_of(1) === 4'd0 || axis_of(2) === 4'd0);
            chk("K-106: overflow did NOT wedge the FSM (some gate is active)",
                popcount(voice_gate) > 0);

            // ── ⑤ clr 能清，且之后还能再次置位 ─────────────────────────────
            event_lost_clr = 1'b1; @(negedge clk); event_lost_clr = 1'b0;
            @(negedge clk);
            chk("K-106: event_lost_clr_i clears the sticky flag",
                event_lost === 1'b0);
            chk("K-106: event_lost_clr_i clears the lost count",
                event_lost_cnt === {EVT_LOST_W{1'b0}});

            // 再次灌满 ⇒ 必须能**重新**置位（⛔ 不是清完就永久失效）
            // ⭐ 先清干净在响的音，否则"轴位重触发"会走另一条路径
            for (v9 = 0; v9 < 16; v9 = v9 + 1) release_a(v9[AXIS_W-1:0]);
            run_ticks(400);
            @(negedge clk);
            for (n_press = 0; n_press < 12; n_press = n_press + 1) begin
                note_valid = 1'b1; note_axis = n_press[AXIS_W-1:0];
                note_phase_inc = 32'h0020_0000; note_velocity = 8'd100;
                note_kind = 2'd0;
                @(negedge clk);
                note_valid = 1'b0;
                @(negedge clk);
            end
            chk("K-106: sticky can RE-ASSERT after being cleared (not a one-shot lockout)",
                event_lost === 1'b1);

            // ── ③b 计数**饱和**而不回绕 ────────────────────────────────────
            //    ⭐ 本 tb 取 EVT_LOST_W=4 ⇒ 饱和于 15。⚠️ 若不饱和而回绕，
            //       "丢 16 个"会显示成 **0** —— 那是另一种静默（与 `K-106` 直接冲突）。
            //    ⇒ 灌到超过 15 个丢失，确认读数**停在 15**（⛔ 不是 0）
            begin : sat_check
                integer k2;
                event_lost_clr = 1'b1; @(negedge clk); event_lost_clr = 1'b0;
                @(negedge clk);
                for (k2 = 0; k2 < 40; k2 = k2 + 1) begin
                    note_valid = 1'b1; note_axis = k2[AXIS_W-1:0];
                    note_phase_inc = 32'h0030_0000; note_velocity = 8'd100;
                    note_kind = 2'd0;
                    @(negedge clk);
                    note_valid = 1'b0;
                    @(negedge clk);
                end
                if (event_lost_cnt !== {EVT_LOST_W{1'b1}}) begin
                    $display("  FAIL: K-106: lost count = %0d after massive overflow, expected SATURATION at %0d (a wrapping counter would read 0!)",
                             event_lost_cnt, {EVT_LOST_W{1'b1}});
                    errors = errors + 1;
                end else begin
                    $display("  ok  : K-106: lost count SATURATED at %0d (did not wrap to 0)",
                             event_lost_cnt);
                end
                chk("K-106: sticky is set under massive overflow too", event_lost === 1'b1);
            end
        end

        // ═════════════════════════════════════════════════════════════════════
        // ⭐⭐ A1（2026-09-29）：⭐ `note_off` **按来源隔离** ✅
        //   🔴 守的缺陷（用户上板实测）：⭐ looper 回放（`score`）时，按**同一个轴**
        //      的手弹键 ⇒ 回放的 `note_off` 把**手弹**的 voice 也清了
        //      ⇒ ⭐ **手弹的音死掉、而且它自己不再回来** ✅
        //   ⭐ 判据（两条核心 + 一条非空洞性前置）：
        //      · 前置：⭐ `live` 在轴 7 起音 ⇒ 必须**真的**分配到一个 gate=1 的 voice
        //        （⛔ 否则后面两条就是**空洞**的 —— `K-56`/`C83` 纪律）
        //      · ① ⭐ `score`(1) 的 `note_off` 打在同轴的 `live` voice 上 ⇒ ⛔ **不许清**
        //      · ② ⭐ `live` (0) 的 `note_off` 打在同轴的 `live` voice 上 ⇒ ✅ **必须清**
        //   📌 **非空洞性**（⭐ 做法与结果见报告）：⭐ 把 `rtl/w3b/note_manager.v` 的
        //      off 分支改回只有 `axis_r[i] == cur_axis` ⇒ ⭐ **①必红**、前置与②仍绿 ✅
        // ═════════════════════════════════════════════════════════════════════
        begin : a1_src_isolated_off
            integer         vi;
            reg [IDX_W-1:0] v_ax7;
            // ── 清场：所有轴松手 + 等包络落干净（⛔ 不让上一节的残留污染判据）──
            note_src = 2'd0;
            for (vi = 0; vi < 16; vi = vi + 1) release_a(vi[AXIS_W-1:0]);
            run_ticks(400);
            // ── 前置：以 `live`(0) 在轴 7 起音 ──────────────────────────────
            note_src = 2'd0;
            press_a(4'd7, 32'h0050_0000, 8'd100);
            v_ax7 = saw_alloc_voice;
            chk("A1 setup: live note_on on the test axis allocated a gated voice",
                (saw_alloc === 1'b1) && (axis_of(v_ax7) === 4'd7)
                && (voice_gate[v_ax7] === 1'b1));
            // ── ① `score`(1) 的同轴 `note_off` ⇒ ⛔ **不许清** ──────────────
            note_src = 2'd1;
            release_a(4'd7);
            chk("A1: score note_off must NOT clear a live voice on the same axis",
                voice_gate[v_ax7] === 1'b1);
            // ── ② `live`(0) 的同轴 `note_off` ⇒ ✅ **必须清** ───────────────
            note_src = 2'd0;
            release_a(4'd7);
            chk("A1: live note_off still clears the live voice on the same axis",
                voice_gate[v_ax7] === 1'b0);
        end

        // ═════════════════════════════════════════════════════════════════════
        // ⭐⭐ A2（2026-09-29）：⭐ **参数更新通路【按来源隔离】** ✅
        //   🔴 守的缺陷：⭐ `note_manager` 的 (d) 力度跟随 / (e) 音高修正 原来
        //      **只按 `axis` 匹配** ⇒ ⚠️ 一旦 looper 回放也驱动这两条通路
        //      ⇒ 🔴 回放的插值更新会把**同一轴上手弹的 voice 一起拖走**
        //      （⭐ 听感：手弹的音量/音高被回放的手势带着跑）✅
        //      📌 **与 A1 修的 `note_off` 是同一个缺陷类**（⭐ 都缺"来源"这一维）
        //   ⭐ 判据（六条）：
        //      · 前置：⭐ 手弹在轴 9 起音 ⇒ 必须**真的**有 gate=1 的 voice
        //      · ① ⭐ `src=1`（回放）的 `vel_upd` 打在**只有手弹**的轴上 ⇒ ⛔ **不许动它**
        //      · ② ⭐ `src=0`（手弹）的 `vel_upd` 打在同一轴 ⇒ ✅ **必须动它**
        //      · ③ ⭐ 回放 voice（轴 10）**必须被自己的更新**驱动到目标 ✅
        //      · ④ ⭐ 对称面：⭐ 手弹的更新打在**回放 voice** 的轴上 ⇒ ⛔ **不许动它**
        //      · ⑤ ⭐⭐ **释放尾音等价**（⭐ 用户症状"回放没有 release 尾音"的直接判据）：
        //          ⭐ "手弹驱动到 240" 与 "回放驱动到 240" 的**释放拍数必须相同**，
        //          且**必须长于**"停在起点 80"的对照 ✅
        //          🔴 **为什么这条最重要**：⭐ `adsr.v` 的 release 是**每采样拍固定步长**
        //             ⇒ ⭐ **尾音长度 ∝ 松手时的包络电平 ∝ 力度** ✅
        //             📌 所以"力度到没到终点"就是"尾音长不长" ✅
        //   📌 **非空洞性**（⭐ 两次禁用实验，⭐ 输出见报告）：
        //      · 去掉 (d) 段的两条 `vu_src_w` 条件（⭐ 恢复"只按轴"）⇒ ⭐ **①必红**
        //      · 去掉 (d) 段"非手弹 ⇒ 写 `vtgt_rep`"那一支 ⇒ ⭐ **⑤必红**（⭐ 回放腿停在 80）
        // ═════════════════════════════════════════════════════════════════════
        begin : a2_upd_src_isolated
            integer         vi;
            integer         vl, vr, vlow, rl_live, rl_rep, rl_low;
            reg [VEL_W-1:0] vhold;
            // ── 清场：所有轴松手 + 等包络落干净 ────────────────────────────
            note_src     = 2'd0;
            vel_upd_src  = 2'd0;
            pitch_upd_src= 2'd0;
            for (vi = 0; vi < 16; vi = vi + 1) release_a(vi[AXIS_W-1:0]);
            run_ticks(400);

            // ── 前置：手弹（src=0）在轴 9 起音 ─────────────────────────────
            note_src = 2'd0;
            press_a(4'd9, 32'h0090_0000, 8'd100);
            vl = saw_alloc_voice;
            chk("A2 setup: live note_on allocated a gated voice on axis 9",
                (saw_alloc === 1'b1) && (axis_of(vl) === 4'd9)
                && (voice_gate[vl] === 1'b1));

            // ── ① 回放源（src=1）的更新打在【只有手弹】的轴上 ⇒ ⛔ 不许动 ────
            vhold = vel_of(vl);
            pulse_velupd_src(4'd9, 8'd230, 2'd1);
            run_ticks(40);
            chk("A2: a replayed (src=1) vel_upd must NOT move the live (src=0) voice",
                vel_of(vl) === vhold);

            // ── ② 手弹源（src=0）的更新打在同一轴 ⇒ ✅ 必须动 ──────────────
            pulse_velupd_src(4'd9, 8'd230, 2'd0);
            run_ticks(40);
            chk("A2: the live (src=0) vel_upd still drives the live voice",
                vel_of(vl) === 8'd230);

            // ── ③ 回放 voice（src=1，轴 10）必须被【自己的】更新驱动 ────────
            note_src = 2'd1;
            press_a(4'd10, 32'h00A0_0000, 8'd60);
            vr = saw_alloc_voice;
            chk("A2 setup: replayed note_on allocated a gated voice on axis 10",
                (saw_alloc === 1'b1) && (axis_of(vr) === 4'd10)
                && (voice_gate[vr] === 1'b1));
            pulse_velupd_src(4'd10, 8'd220, 2'd1);
            run_ticks(40);
            chk("A2: a replayed (src=1) vel_upd DOES drive its own (src=1) voice",
                vel_of(vr) === 8'd220);

            // ── ④ 对称面：⭐ 手弹源（src=0）的更新打在【回放 voice】的轴 ⇒ ⛔ 不许动 ──
            vhold = vel_of(vr);
            pulse_velupd_src(4'd10, 8'd90, 2'd0);
            run_ticks(40);
            chk("A2: a live (src=0) vel_upd must NOT move the replayed (src=1) voice",
                vel_of(vr) === vhold);

            // ═════════════════════════════════════════════════════════════════
            // ⑤ ⭐⭐ **释放尾音等价**（⭐ 用户症状"回放没有 release 尾音"的直接判据）
            //   ⭐ 三条腿：⭐ ①手弹驱动到 240 · ②回放驱动到 240 · ③不给更新（停在 80）
            //   ⭐ 判据：⭐ ①②**释放拍数相同**，⭐ 且**都长于**③ ✅
            //   📌 **非空洞性**：⭐ 去掉"非手弹 ⇒ 写 `vtgt_rep`"那一支 ⇒ ⭐ ②停在 80
            //      ⇒ ⭐ **②的释放拍数掉到 ③ 的水平 ⇒ 本判据必红** ✅
            // ═════════════════════════════════════════════════════════════════
            note_src      = 2'd0;
            vel_upd_src   = 2'd0;
            pitch_upd_src = 2'd0;
            for (vi = 0; vi < 16; vi = vi + 1) release_a(vi[AXIS_W-1:0]);
            run_ticks(400);

            // 腿 A：手弹（src=0）驱动 80 → 240
            note_src = 2'd0;
            press_a(4'd11, 32'h00B0_0000, 8'd80);
            vl = saw_alloc_voice;
            pulse_velupd_src(4'd11, 8'd240, 2'd0);
            run_ticks(220);                 // ⭐ 力度爬完 + 包络走到 sustain(240)
            release_a(4'd11);
            rel_ticks(vl, rl_live);

            // 腿 B：回放（src=1）驱动 80 → 240（⭐ 与腿 A **逐参数相同**）
            note_src = 2'd1;
            press_a(4'd12, 32'h00C0_0000, 8'd80);
            vr = saw_alloc_voice;
            pulse_velupd_src(4'd12, 8'd240, 2'd1);
            run_ticks(220);
            release_a(4'd12);
            rel_ticks(vr, rl_rep);

            // 腿 C：⭐ **对照** —— 不给任何更新（⭐ 停在起点 80）
            note_src = 2'd0;
            press_a(4'd13, 32'h00D0_0000, 8'd80);
            vlow = saw_alloc_voice;
            run_ticks(220);
            release_a(4'd13);
            rel_ticks(vlow, rl_low);

            $display("  INFO: release sample-ticks  live(240)=%0d  replayed(240)=%0d  start-only(80)=%0d",
                     rl_live, rl_rep, rl_low);
            chk("A2: the replayed note's release lasts EXACTLY as long as the live note's",
                (rl_live > 0) && (rl_rep == rl_live));
            chk("A2: the END velocity really drives the tail (start-only is SHORTER)",
                rl_low < rl_live);
        end

        // ═════════════════════════════════════════════════════════════════════
        // ⭐⭐ A3'（2026-09-29）：⭐ **voice 复用【按来源】判定** ✅
        //   🔴 守的缺陷（⭐ 用户上板实测）：⭐ **先按住一个键、再开始回放** ⇒
        //      ⭐ 回放（`score`）在同轴的 `note_on` **命中手弹那个 voice** ⇒
        //      🔴 走"同轴重触发"路径：包络被清零 ＋ `src_r` 被改判成回放源
        //      ⇒ ⭐ 回放的 `note_off` 一到就把手弹的音杀掉，而**手弹不会再发
        //      `note_on`**（⭐ 键一直按着）⇒ 🔴 **键还按着却永久静音** ✅
        //      📌 用户原话："从回放一开始就没声了"，⭐ 且**只在"先按键、后回放"时出现**
        //   ⭐ 判据（A 组 = ⛔ 不许接管；B 组 = ⭐ 清的只能是回放自己的）：
        //      · 前置：⭐ 手弹在轴 6 起音并**爬到 sustain**（⭐ 记下 `vel` / `env`）
        //      · A① ⭐ 回放的 `note_on` 必须**分配到一个【新的】voice**（`alloc` 必须发生）
        //      · A② ⭐ 同轴上必须**同时有两个** gate=1 的 voice（⭐ "并存"的直接判据）
        //      · A③ ⭐ 手弹 voice 的 `vel` / `phase_inc` **一个都不许变**
        //        （⭐ 重触发路径正是改写这两个 ⇒ ⭐ 它们是最灵敏的探针 ✅）
        //      · A④ ⭐ 手弹 voice 的**包络不许被清零**（⭐ 重触发必发 `retrig_reset`）
        //      · B① ⭐ 回放的 `note_off` 之后，同轴**恰好剩一个** gate=1 的 voice
        //      · B② ⭐ 那个剩下的**就是手弹的**（⭐ `gate` 仍为 1 ✅）
        //      · B③ ⭐ 手弹自己的 `note_off` **仍然清得掉它** —— ⭐ 这是
        //        "`src_r` 没被回放改判"的**行为学证明**（⭐ `src_r` 不是输出端口）✅
        //   📌 **非空洞性**（⭐ 两次跑的输出见报告）：⭐ 去掉 `same_hit` 的
        //      `&& (src_r[sg] == cur_src)` ⇒ ⭐ **A①②③④ 全红** ✅
        // ═════════════════════════════════════════════════════════════════════
        begin : a3_src_aware_reuse
            integer         vi;
            integer         g6;
            reg [IDX_W-1:0] v3l, v3r;
            reg [VEL_W-1:0] v3l_vel;
            reg [ENV_W-1:0] v3l_env;
            // ── 清场：所有轴松手 + 等包络落干净（⛔ 不让上一节残留污染判据）──
            note_src = 2'd0;
            for (vi = 0; vi < 16; vi = vi + 1) release_a(vi[AXIS_W-1:0]);
            run_ticks(400);

            // ── 前置：手弹（src=0）在轴 6 起音，⭐ 并让它爬到 sustain ────────
            note_src = 2'd0;
            press_a(4'd6, 32'h0060_0000, 8'd100);
            v3l = saw_alloc_voice;
            chk("A3 setup: live note_on on axis 6 allocated a gated voice",
                (saw_alloc === 1'b1) && (axis_of(v3l) === 4'd6)
                && (voice_gate[v3l] === 1'b1));
            run_ticks(200);                  // ⭐ attack(39 拍) + decay(6 拍) 早已走完
            v3l_vel = vel_of(v3l);
            v3l_env = env_of(v3l);
            chk("A3 setup: the live voice reached sustain before the replay",
                (v3l_vel === 8'd100) && (v3l_env !== {ENV_W{1'b0}}));

            // ── A：回放（src=1）在【同一轴】起音 ⇒ ⛔ 不许接管手弹的 voice ──
            //   ⚠️ 故意换一个**不同的** `vel` / `phase_inc` ⇒ ⭐ 一旦被接管，A③必红
            note_src = 2'd1;
            press_a(4'd6, 32'h00C0_0000, 8'd40);
            v3r = saw_alloc_voice;
            chk("A3-A: replayed note_on must NOT take over the live voice",
                (saw_alloc === 1'b1) && (v3r !== v3l));
            g6 = 0;
            for (vi = 0; vi < POLY; vi = vi + 1)
                if (voice_gate[vi] && (axis_of(vi) === 4'd6)) g6 = g6 + 1;
            chk("A3-A: live and replayed voices COEXIST on the same axis", g6 === 2);
            chk("A3-A: the live voice keeps its velocity (not retriggered)",
                vel_of(v3l) === v3l_vel);
            chk("A3-A: the live voice keeps its phase_inc (not retriggered)",
                phase_of(v3l) === 32'h0060_0000);
            run_ticks(3);
            chk("A3-A: the live voice envelope was NOT reset",
                env_of(v3l) > (v3l_env >> 1));

            // ── B：回放的 `note_off` ⇒ ⭐ 只清回放那个 voice ────────────────
            note_src = 2'd1;
            release_a(4'd6);
            g6 = 0;
            for (vi = 0; vi < POLY; vi = vi + 1)
                if (voice_gate[vi] && (axis_of(vi) === 4'd6)) g6 = g6 + 1;
            chk("A3-B: replayed note_off leaves EXACTLY one voice on the axis",
                g6 === 1);
            chk("A3-B: the surviving voice is the live one (still gated)",
                voice_gate[v3l] === 1'b1);
            chk("A3-B: the replayed voice was the one cleared",
                voice_gate[v3r] === 1'b0);
            // ── B③：手弹自己的 `note_off` 仍然清得掉它 ─────────────────────
            note_src = 2'd0;
            release_a(4'd6);
            chk("A3-B: live note_off still clears the live voice (tag intact)",
                voice_gate[v3l] === 1'b0);
        end

        // ═════════════════════════════════════════════════════════════════════
        // ⭐⭐ A3' 续（2026-09-29）：⭐ **池满时的【抢占】也不许抢"同轴但异源且仍按住"** ✅
        //   🔴 守的缺陷：⭐ `same_hit` 的来源判据只挡住"**复用**"这条路；
        //      ⚠️ 池满时新音走的是 `ST_SCAN` 的**抢占**路 ⇒ 🔴 候选比较
        //      （`cand_ok`/`cand_better`）**只看 空闲/已 Release/年龄，⛔ 不看来源**
        //      ⇒ ⭐ 手弹那个"最老的" voice 会被回放**抢走并在 `ST_COMMIT2` 里改判**
        //      ⇒ 🔴 **症状与 A3' 修的那个一模一样**（⭐ 键还按着却静音）✅
        //   ⭐ 判据（C 组）：
        //      · 前置① ⭐ 池**真的**满了（⭐ 数 `gate=1` 的 voice 必须 == `POLY`）
        //      · 前置② ⭐ 手弹那个 voice 必须是**最老的**（⭐ `age > 0`，而填充的全是 0）
        //        —— ⚠️ 否则"抢最老的"本来就抢不到它 ⇒ **判据会空洞**（`C83` 纪律）
        //      · C① ⭐ 回放的 `note_on` 必须**分配成功**（⭐ 池满 ⇒ 必然走抢占）
        //      · C② ⭐ 抢占的牺牲品**不是**手弹那个 voice
        //      · C③ ⭐ 手弹 voice 仍 gate=1、仍在轴 6、**力度仍是自己的 100**
        //        （⭐ 被改判时 `vel_r` 会变成回放的 40 ⇒ 这条是最灵敏的探针 ✅）
        //   📌 **非空洞性**（⭐ 变异点见报告）：⭐ 去掉 `& ~cand_foreign` ⇒ **C②③ 必红** ✅
        //   ⚠️ 构造要点：⭐ 填充必须用 **(轴, 源) 各不相同**的 pair（⭐ 否则同源会走
        //      "复用"而⛔ 不占新 voice）⇒ ⭐ 并**避开 (轴 6, 源 0)**（手弹自己）与
        //      **(轴 6, 源 1)**（⭐ 回放要用的）—— ⚠️ 否则回放那条会命中已有 voice
        //      ⇒ 变成重触发 ⇒ ⭐ 判据空洞 ✅
        // ═════════════════════════════════════════════════════════════════════
        begin : a3c_steal_avoid
            integer         vi;
            integer         f;
            integer         gcnt;
            integer         fcnt;
            integer         fok;
            //  ⚠️⚠️ `s3` **必须是 3 bit**：⭐ 清场要遍历 `s3 = 0..3`（4 个源）
            //     ⇒ 🔴 若写成 `reg [1:0]`，则常量 `2'd4` 会被**截断成 0**
            //     ⇒ 循环条件 `s3 < 2'd4` 恒为假 ⇒ 🔴 **整个清场循环一次都不执行**
            //     （⭐ 第一版正是踩了这个：实测 `alloc-ok=30`（少 1 个）、
            //      `gated=31` —— ⚠️ 因为 a2 留在轴 10/src1 的 voice **没被清掉**，
            //      它占着池，还被填充用的 (轴10, src1) 命中 ⇒ 走了重触发 ✅）
            reg [2:0]       s3;
            reg [IDX_W-1:0] v3c;
            // ── 清场：⭐ 所有轴 × **所有 4 个源**都松手 ⇒ ⛔ 不留上一节任何残留 ──
            //   ⚠️ **为什么必须按【源】清**（⭐ A3' 的直接后果）：⭐ 同轴异源是**两个
            //      独立 voice** ⇒ 🔴 只发 `src=0` 的 `note_off` **清不掉**上一节
            //      留下的 `src=1/2/3` voice ⇒ ⚠️ 它会一直按住 ⇒ ⭐ 池里永远少一个空位
            //      ⇒ 🔴 "铺满池"这条前置就**永远不成立**（⭐ 第一版正是踩了这个：
            //        实测 `gated=31/32`，⭐ 因为 a2 留了一个 `src=1` 的 voice 没被清掉）✅
            for (s3 = 3'd0; s3 < 3'd4; s3 = s3 + 3'd1) begin
                note_src = s3[1:0];
                for (vi = 0; vi < 16; vi = vi + 1) release_a(vi[AXIS_W-1:0]);
            end
            note_src = 2'd0;
            run_ticks(400);

            // ── 前置：手弹（src=0）在轴 6 起音 ⇒ ⭐ 再跑 20 个采样拍把它做成【最老】──
            note_src = 2'd0;
            press_a(4'd6, 32'h0060_0000, 8'd100);
            v3c = saw_alloc_voice;
            chk("A3-C setup: live note_on on axis 6 allocated a gated voice",
                (saw_alloc === 1'b1) && (axis_of(v3c) === 4'd6)
                && (voice_gate[v3c] === 1'b1));
            run_ticks(20);          // ⭐ 手弹的 age 变 20；⭐ 后面填充的 age 全是 0

            // ── 铺满池：⭐ 31 个 (轴, 源) 各不相同的 pair ⇒ ⛔ 不走同源重触发 ────
            f = 0;
            fok = 0;
            for (vi = 0; (vi < 16) && (f < 31); vi = vi + 1)
                for (s3 = 3'd0; (s3 < 3'd3) && (f < 31); s3 = s3 + 3'd1) begin
                    if (!((vi == 6) && ((s3 == 3'd0) || (s3 == 3'd1)))) begin
                        note_src = s3[1:0];
                        press_a(vi[AXIS_W-1:0], 32'h0010_0000, 8'd60);
                        if (saw_alloc === 1'b1) fok = fok + 1;
                        f = f + 1;
                    end
                end
            //  ⭐⭐ **前置判据必须是"没有空闲 voice"**（⭐ 即 `live_mask` 全 1），
            //     ⛔ **不是"`gate=1` 的个数 == POLY"** —— ⚠️ 两者**不等价**：
            //     ⭐ `gate_mask = gate_r & ~retrig_low` ⇒ ⭐ 一个正在**重触发压低**
            //     窗口里的 voice **照样占着池**（`live_mask=1` ⇒ `free_mask=0`），
            //     但 `gate=0` ⇒ ⚠️ 用 gate 数当判据会**假红**（⭐ 第一版实测 31/32）✅
            //      📌 分配器真正看的是 `free_mask`（⭐ `cand_free`）⇒ ⭐ 判据要用同一个量 ✅
            gcnt = 0;
            fcnt = 0;
            for (vi = 0; vi < POLY; vi = vi + 1) begin
                if (voice_gate[vi])   gcnt = gcnt + 1;
                if (voice_active[vi] === 1'b0) fcnt = fcnt + 1;
            end
            $display("  INFO: A3-C fills=%0d alloc-ok=%0d gated=%0d free(live_mask=0)=%0d / %0d",
                     f, fok, gcnt, fcnt, POLY);
            //  ⭐ 诊断：⭐ 找出"占着池但 `gate=0`"的 voice（⭐ 期望 0 个）
            //     ⚠️ 这种 voice 是**合法的**（⭐ 正在 `retrig_low` 压低，或只剩 Release 尾巴）
            //     ⇒ ⭐ 它**照样占池**（`free_mask=0`）⇒ ⭐ 打印出来便于日后定位 ✅
            for (vi = 0; vi < POLY; vi = vi + 1)
                if ((voice_active[vi] === 1'b1) && (voice_gate[vi] === 1'b0))
                    $display("  INFO: A3-C busy-not-gated idx=%0d axis=%0d age=%0d env=%0d",
                             vi, axis_of(vi), voice_age[vi*AGE_W +: AGE_W], env_of(vi));
            chk("A3-C setup: the voice pool is COMPLETELY full (no free voice left)",
                fcnt === 0);
            chk("A3-C setup: the live voice is the OLDEST (age > 0, fills are age 0)",
                voice_age[v3c*AGE_W +: AGE_W] > {AGE_W{1'b0}});

            // ── C：池满时回放（src=1）在轴 6 起音 ⇒ ⛔ 不许抢走手弹的 voice ────
            note_src = 2'd1;
            press_a(4'd6, 32'h00C0_0000, 8'd40);
            chk("A3-C: the replayed note_on still allocated (via preemption)",
                (saw_alloc === 1'b1) && (axis_of(saw_alloc_voice) === 4'd6));
            chk("A3-C: the preemption victim is NOT the live voice on that axis",
                saw_alloc_voice !== v3c);
            chk("A3-C: the live voice survives with its OWN velocity (not re-tagged)",
                (voice_gate[v3c] === 1'b1) && (axis_of(v3c) === 4'd6)
                && (vel_of(v3c) === 8'd100));
            // ── 收尾：把手弹那条清掉（⭐ 本块是最后一个，但⛔ 不留半清状态）────
            note_src = 2'd0;
            release_a(4'd6);
        end

        // ═════════════════════════════════════════════════════════════════════
        // ⭐⭐ K-169（2026-09-30）：⭐ **"旧音还在 Release 尾巴里时重按" ⇒ 相位必须复位** ✅
        //
        //  🔴 **守的缺陷**：⭐ 起音相位复位挂在 `voice_active`（= `live_mask`）的
        //     **上升沿** ⇒ ⚠️ `live_mask = gate_r | retrig_low | env_active_i`
        //     是**电平派生**的 ⇒ ⭐ 上一个音**还没释放完**时重按同一个轴
        //     ⇒ ⭐ `live_mask` **恒为 1** ⇒ 🔴 **上升沿不存在** ⇒ ⭐ 复位被跳过
        //     ⇒ 🔴 新音从残留相位起振 ⇒ ⭐ 两个失谐 lane 的 0°/90° 初相丢失
        //     ⇒ 🔴 起音幅度随机（⭐ 用户原话：*"不同时间按下，音量不同"* ✅）
        //
        //  ⭐ **判据（4 条，⭐ 全是可失败的具体数值）**：
        //     · 前置① ⭐ 重按之前该 voice 确实"**gate 已落但还在响**"（= Release 尾巴 ✅）
        //        —— ⚠️ 否则"重按"会走**新分配**那条路（⭐ 有上升沿）⇒ **判据空洞** ✅
        //     · 前置② ⭐ 重按之前相位**不等于**种子（⭐ 证明"确实需要一次复位" ✅）
        //        —— ⭐ **非空洞性的核心**：⭐ 若相位本来就等于种子，
        //           那"重按后等于种子"**什么都没证明**（`C83`）✅
        //     · 前置③ ⭐ 新起音确实落在 **voice0**（⭐ 观测 lane = voice0 的 lane1 ✅）
        //        —— ⚠️ 否则**看错了寄存器**，判据会静默失去意义 ✅
        //     · ① ⭐ 重按之后**相位必须回到种子** `32'h4000_0000` ✅
        //
        //  📌 **非空洞性（红→绿，⭐ 见报告）**：
        //     ⭐ 把 `oscillator_bank` 的判据改回【只看 `lane_active` 上升沿】
        //     （⭐ 即改动前的旧边沿检测）⇒ ⭐ **第 ① 条必红**
        //     （⭐ 实测相位停在 `0x4066_0000` 而⛔ 不是种子）✅
        //     ⭐ 恢复"事件边沿 || 电平边沿"⇒ ⭐ **全绿** ✅
        // ═════════════════════════════════════════════════════════════════════
        begin : k169_phase_reset_on_repress
            reg [2:0]         s4;
            reg [IDX_W-1:0]   v169;
            reg [PHASE_W-1:0] ph_pre;
            integer           vi4;
            // ── 清场：⭐ 所有轴 × **所有 4 个源**都松手（⭐ 与 A3-C 同一手法）────
            //   ⚠️ **必须按【源】清**：⭐ 同轴异源是**独立 voice** ⇒ 🔴 只发 `src=0`
            //      清不掉上一节（A3-C）留下的 `src=1/2/3` voice ⇒ ⭐ 池里仍有占用
            //      ⇒ ⭐ 新音可能被分到**非 voice0** ⇒ 🔴 前置③ 会假红 ✅
            for (s4 = 3'd0; s4 < 3'd4; s4 = s4 + 3'd1) begin
                note_src = s4[1:0];
                for (vi4 = 0; vi4 < 16; vi4 = vi4 + 1) release_a(vi4[AXIS_W-1:0]);
            end
            note_src = 2'd0;
            run_ticks(400);      // ⭐ 让所有 Release 尾巴归零（`env_active` 全 0）

            // ── 起音（轴 2）⇒ ⭐ 跑 5 个采样拍让相位【离开种子】────────────────
            //   ⚠️ `press_a` 里的 `settle` **不产生 `sample_tick`** ⇒ ⭐ 这 5 拍
            //      就是**精确的** 5 个采样步（⭐ 与 `run_ticks` 的语义一致 ✅）
            press_a(4'd2, 32'h0010_0000, 8'd100);
            v169 = saw_alloc_voice;
            run_ticks(5);

            // ── 松手 ⇒ ⭐ 进 Release 尾巴（⭐ 但**还没释放完**）────────────────
            //   ⭐ `release_a` 也不产生 tick ⇒ ⭐ `run_ticks(1)` 只走 **1 个**
            //      释放步 ⇒ ⭐ 包络残值 3345-3200 = 145 > 0 ⇒ `live_mask` 仍为 1 ✅
            release_a(4'd2);
            run_ticks(1);

            chk("K-169 setup: voice live in release tail (gate=0, active=1)",
                (voice_gate[v169] === 1'b0) && (voice_active[v169] === 1'b1));
            ph_pre = ob_phase_dbg;
            chk("K-169 setup: phase != seed before re-press (non-vacuous)",
                ph_pre !== 32'h4000_0000);
            chk("K-169 setup: the fresh voice is voice0 (probe lane matches)",
                v169 === {IDX_W{1'b0}});

            // ── 重按**同一个轴** ⇒ ⭐ 走"同轴重触发复用"⇒ ⭐ 没有 `live_mask` 上升沿
            press_a(4'd2, 32'h0010_0000, 8'd100);
            run_ticks(1);        // ⭐ 相位复位就在这一拍生效
            $display("  INFO: K-169 phase before re-press = %08x, after = %08x",
                     ph_pre, ob_phase_dbg);
            chk("K-169: re-press in release tail reloads the phase seed",
                ob_phase_dbg === 32'h4000_0000);

            // ── 收尾：⭐ 松手并等尾巴归零（⛔ 不留半清状态）──────────────────
            note_src = 2'd0;
            release_a(4'd2);
            run_ticks(400);
        end

        if (errors == 0)
            $display("PASS: note_manager acceptance (T54) - all judgements held");
        else
            $fatal(1, "FAIL: note_manager acceptance has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
