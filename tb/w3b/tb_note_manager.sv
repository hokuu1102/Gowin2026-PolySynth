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
    localparam integer CLK_PER_SAMPLE = 16;

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

    reg                    vel_upd_valid;
    reg  [AXIS_W-1:0]      vel_upd_axis;
    reg  [VEL_W-1:0]       vel_upd_value;

    reg                    pitch_upd_valid;
    reg  [AXIS_W-1:0]      pitch_upd_axis;
    reg  [PHASE_W-1:0]     pitch_upd_value;

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

    wire [POLY-1:0]         env_active;
    wire [POLY*ENV_W-1:0]   env_level;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind),
        .vel_upd_valid_i(vel_upd_valid), .vel_upd_axis_i(vel_upd_axis),
        .vel_upd_value_i(vel_upd_value),
        .pitch_upd_valid_i(pitch_upd_valid), .pitch_upd_axis_i(pitch_upd_axis),
        .pitch_upd_value_i(pitch_upd_value),
        .default_timbre_i(default_timbre), .evt_timbre_valid_i(evt_timbre_valid),
        .evt_timbre_i(evt_timbre),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_age_o(voice_age),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice)
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
        .env_level_o(env_level), .env_active_o(env_active)
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
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}), .vel_upd_value_i(8'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i(32'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({SP{1'b0}}), .env_level_i({(SP*ENV_W){1'b0}}),
        .voice_gate_o(b_gate), .voice_active_o(), .voice_releasing_o(),
        .voice_axis_o(b_axis_o), .voice_phase_inc_o(), .voice_velocity_o(),
        .voice_timbre_o(), .voice_age_o(b_age),
        .alloc_valid_o(b_alloc_valid), .alloc_voice_o(b_alloc_voice)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // DUT C · 专用池实例（RESERVED_N=4，`T33b` 的地基）
    // ═════════════════════════════════════════════════════════════════════════
    localparam integer RSV_N = 4;
    localparam integer RNORM = POLY - RSV_N;      // 28

    reg  [AXIS_W-1:0]  c_axis;
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
        .vel_upd_valid_i(1'b0), .vel_upd_axis_i({AXIS_W{1'b0}}), .vel_upd_value_i(8'd0),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i(32'd0),
        .default_timbre_i(2'd0), .evt_timbre_valid_i(1'b0), .evt_timbre_i(2'd0),
        .env_active_i({POLY{1'b0}}), .env_level_i({(POLY*ENV_W){1'b0}}),
        .voice_gate_o(c_gate), .voice_active_o(), .voice_releasing_o(),
        .voice_axis_o(), .voice_phase_inc_o(), .voice_velocity_o(),
        .voice_timbre_o(), .voice_age_o(),
        .alloc_valid_o(), .alloc_voice_o(c_alloc_voice)
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
        end
    endtask

    task press_b;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            b_valid = 1'b1; b_axis = ax;
            @(negedge clk);
            b_valid = 1'b0;
        end
    endtask

    task press_c;
        input [AXIS_W-1:0] ax;
        begin
            @(negedge clk);
            c_valid = 1'b1; c_axis = ax;
            @(negedge clk);
            c_valid = 1'b0;
        end
    endtask

    // 走 n 个采样拍
    //    ⚠️⚠️ `sample_tick_i` 必须**恰好高 1 个 clk**（它是"时钟使能"，不是电平）。
    //       我第一版写成"高 `CLK_PER_SAMPLE` 个 clk" ⇒ 每个 `run_ticks(1)`
    //       实际跑了 **16 个采样步** ⇒ 包络快了 16 倍 ⇒
    //       ⭐ "重触发后 15 拍应该还在爬升" 实际早就爬完并衰回 sustain 了
    //       ⇒ 判据假失败。（`K-93` 记录了这条：**tb 的时基必须和被测系统的节拍语义一致**）
    task run_ticks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk); sample_tick = 1'b1;   // ← 只高 1 拍
                @(negedge clk); sample_tick = 1'b0;
                repeat (3) @(negedge clk);
            end
        end
    endtask

    integer i;
    integer n;
    integer gate_count;
    reg [ENV_W-1:0] lvl_a;
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

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 1: 事件 -> voice gate（含 DEFAULT_VEL / 音色锁存）==");
        // ═══════════════════════════════════════════════════════════════════
        chk("复位后 0 个 gate", popcount(voice_gate) == 0);

        press_a(4'd3, 32'h0010_0000, 8'd0);      // vel=0 ⇒ 应用 DEFAULT_VEL
        chk("note_on 后有 1 个 gate", popcount(voice_gate) == 1);
        chk("分配落在最低空闲索引 voice0", alloc_valid === 1'b1 && alloc_voice === 5'd0);
        chk("voice0 的 axis = 3", axis_of(0) === 4'd3);
        chk("voice0 的 phase_inc 正确", phase_of(0) === 32'h0010_0000);
        chk("vel=0 时套用 DEFAULT_VEL(200)", vel_of(0) === 8'd200);
        chk("音色锁存 = 默认音色(1)", timbre_of(0) === 2'd1);

        press_a(4'd5, 32'h0020_0000, 8'd77);
        chk("第二个 note_on 后有 2 个 gate", popcount(voice_gate) == 2);
        chk("分配取下一个最低空闲 voice1", alloc_voice === 5'd1);
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
        chk("vel_update 改到在响的 voice1", vel_of(1) === 8'd240);
        chk("vel_update 不影响已释放的 voice0", vel_of(0) === 8'd200);

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

        press_a(4'd5, 32'h0033_0000, 8'd100);  // ⭐ 重触发
        run_ticks(15);
        chk("重触发后 gate 已抬回（voice1 在响）", voice_gate[1] === 1'b1);
        chk("重触发后电平显著高于 sustain => Attack 确实重起",
            env_of(1) > (lvl_a + 16'd2000));

        run_ticks(60);
        chk("重触发后包络重新回到 sustain 平台", env_of(1) === 16'd6400);

        // ═══════════════════════════════════════════════════════════════════
        $display("== 判据 8: 专用 voice 池（节拍器不参与普通抢占，T33b 地基）==");
        // ═══════════════════════════════════════════════════════════════════
        press_c(4'd0);                          // 普通轴位
        chk("普通轴位落在普通池（< 28）", c_alloc_voice < RNORM);
        press_c(4'd14);                         // ⭐ 专用轴位（节拍器）
        chk("专用轴位落在专用池（>= 28）", c_alloc_voice >= RNORM);
        press_c(4'd15);                         // ⭐ 专用轴位（鼓机）
        chk("第二个专用轴位也落在专用池", c_alloc_voice >= RNORM);
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

        if (errors == 0)
            $display("PASS: note_manager acceptance (T54) - all judgements held");
        else
            $fatal(1, "FAIL: note_manager acceptance has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
