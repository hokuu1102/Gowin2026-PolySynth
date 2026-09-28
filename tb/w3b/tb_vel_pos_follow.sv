// ─────────────────────────────────────────────────────────────────────────────
// tb_vel_pos_follow.sv · ⭐ 「位置式力度 —— 音量实时跟随位置」判据
//                        （⭐ 2026-09-28 新增）
//
// ⭐ 为什么必须有这个 tb（⭐ `K-56`：**"全绿"本身不证明任何事**）：
//    ⭐ 用户已定的方案（`files/20-代码/位置式力度-方案-20260928.md`）要求
//       「**音量实时跟随位置变化**」⇒ ⭐ **按浅了音量必须能变【小】**。
//    🔴 而改前的 `note_manager`（`(d)` 段）有一道闸门
//       `if (vel_upd_value_i > vel_r[i])` ⇒ ⭐ **只能调大、⛔ 不能调小**
//       ⇒ 🔴 **"实时跟随"根本不成立**（⭐ 只能"越按越响"，松回无效）。
//    ⇒ ⭐ 本 tb 的 **J3 就是专门打这道闸门的**，并且
//       ⭐ **已在【未改】的 `note_manager.v` 上确认它会 FAIL**（⭐ 见文件尾 §非空洞性）。
//
// ⭐ 覆盖的 6 条判据（⭐ 逐条机械可判，⛔ 没有"看起来对"）：
//    ① `note_on`（位置 → 力度）⇒ ⭐ gate 拉高、包络爬到该力度的 sustain
//    ② 保持 gate 不变，**按深**（`vel` 变大）⇒ ⭐ 包络**变大**并停在新 sustain
//    ③ 保持 gate 不变，**松回一半**（`vel` 变小）⇒ ⭐ 包络**变小**   ← ⭐ **关键**
//    ④ `note_off` ⇒ ⭐ 走 release、包络**衰减到 0**、`active` 落下
//    ⑤ `note_off` **之后**再发 `vel_upd` ⇒ ⭐ 力度**冻结**（`vel_r` 不变）
//       —— ⭐ 这一条正是用户原话「**抬起的时候不再改变力度**」
//    ⑥ 守卫：**别的轴**的 `vel_upd` ⛔ 不得改本 voice（⭐ 轴号寻址）
//
// ⚠️ **本 tb 的激励一律用【位置】表达**（⭐ 不是直接写力度）：
//    每条先给一个 `pos`，再用 `pos_to_vel` 换成力度 ⇒
//    ⭐ 判据的语义就是"**音量跟随位置**"，⛔ 不是"跟随一个抽象的数"。
//
// 🔴🔴 **判据名必须【纯 ASCII】（⭐ 这是实测踩出来的，⛔ 不是洁癖）**：
//    ⚠️ `chk()` 的判据名走的是 `reg [8*N-1:0]` **位向量 → 字符串** 这条路，
//    而 **iverilog 在这条路上会把非 ASCII 字节判成非法 UTF-8 并替换成 `�`**
//    （⭐ 实测：判据名里的中文全部变成 `�`，`note_on` 这种 ASCII 片段反而活着；
//      📌 与此对照，`$display` 里**字面量**的中文是**正常的** ——
//      ⭐ 所以"现象 / 说明"可以用中文字面量，⭐ 但**判据名必须 ASCII**）。
//    ⇒ ⭐ 纪律：`chk()` 的第一个参数 **⛔ 只用 ASCII**。
//      （⭐ 同族教训见 `C72`：编码问题最怕"**静默**改内容"而不是报错。）
//
// 🔴 **非空洞性（⭐ `files/20-代码/重大更正-20260928.md` §十一 的硬纪律）**：
//    ⭐ 判据必须**先证明它能失败**。做法（⛔ **不动仓库里的任何文件**）：
//      ① 把 `rtl/w3b/note_manager.v` 复制到 `%TEMP%`
//      ② 把 `(d)` 段改回 `if (vel_upd_value_i > vel_r[i]) vel_r[i] <= vel_upd_value_i;`
//      ③ ⭐ 用那个副本**替换**编译源里的仓库文件（⭐ 仓库文件本身⛔ 不动）
//      ⇒ ⭐ **J3 必须 FAIL**（⭐ 实测结果见答复；⛔ 不是"我推演应该会"）。
//
// ⚠️ 语法纪律（`K-91`）：⛔ **Verilog-2001**，⛔ 不用 SV 专有构造
//    （iverilog 接受 ≠ Gowin 接受；判据是**真跑一次综合**）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_vel_pos_follow;

    localparam integer POLY       = 4;     // ⭐ 4 档：FSM 扫描短、tb 跑得快
    localparam integer AXIS_W     = 4;
    localparam integer PHASE_W    = 32;
    localparam integer VEL_W      = 8;
    localparam integer TIMBRE_W   = 2;
    localparam integer ENV_W      = 16;
    localparam integer AGE_W      = 16;
    localparam integer IDX_W      = 2;     // $clog2(4)
    localparam integer EVT_LOST_W = 4;

    //  ⚠️ `sample_tick_i` 是**时钟使能**（高 1 个 clk），⛔ 不是电平
    //     （⭐ `K-93`：tb 的时基必须与被测系统的节拍语义一致）
    //  ⭐ 64 clk/采样拍 ≫ note_manager 的扫描长度（POLY+4 = 8 clk）⇒ 一定扫得完
    localparam integer CLK_PER_SAMPLE = 64;

    //  ⭐ 包络参数：⭐ **加速**到 tb 跑得动（⭐ 与判据的"方向"无关，只影响要等多少拍）
    //     · attack 669/拍 ⇒ 力度 113 时约 44 拍爬满
    //     · decay  3200/拍
    //     · sustain Q8 = 64 ⇒ ⭐ `sustain_level = 力度 × 64`（⭐ 便于用等式判据）
    //     · release 400/拍 ⇒ 从 9024 衰到 0 约 23 拍
    localparam integer ATTACK_STEP  = 669;
    localparam integer DECAY_STEP   = 3200;
    localparam integer SUSTAIN_Q8   = 64;
    localparam integer RELEASE_STEP = 400;

    // ⭐ 判据名缓冲区：⭐ 80 字节（纯 ASCII）⇒ ⛔ 不会截断
    localparam integer NAME_W = 8*80;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;

    task chk;
        input [NAME_W-1:0] name;      // ⚠️ ⛔ 只传 ASCII（见文件头 §判据名必须纯 ASCII）
        input              cond;
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
    // ⭐⭐ 位置 → 力度：⭐ 与 `rtl/top.v` 的 `pos_to_vel` **逐字节相同**的一段
    //
    //    ⭐ 用户已定：`vel = 64 + ((pos × 263) >> 10)`，饱和到 255
    //       （⭐ `263 = 256 + 8 − 1` ⇒ `(pos<<8)+(pos<<3)−pos` ⇒ ⛔ 无乘法器）
    //
    //    ⚠️ **诚实说明（⛔ 不夸大本判据的覆盖范围）**：
    //       这是**副本** —— 本 tb ⛔ **不例化 `top.v`**
    //       （⭐ 那要拉进整条 ADC / I2S 链，代价与收益不成比例）。
    //       ⇒ ⭐ **它证明不了"top.v 里那一份没被改坏"**。
    //       ⭐ 那一份由**独立脚本**守护：把 `top.v` 的函数文本**抽取**出来
    //          包成一个小模块、跑**同一张表**（⭐ 执行记录见答复）。
    //       📌 但**本表本身仍是有意义的判据**：它锁住"这个公式必须给出这些数"，
    //          而且本 tb 的**所有激励值**都由它导出 ⇒ 一旦公式被改，
    //          J1c/J2a/J3a 会**同时**失败，⛔ 不会静默。
    // ═════════════════════════════════════════════════════════════════════════
    function [7:0] pos_to_vel;
        input [11:0] p;
        reg   [21:0] p22;
        reg   [21:0] prod;
        reg   [12:0] v13;
        begin
            p22        = {10'd0, p};                       // ⭐ 显式零扩展（⛔ 不靠上下文推导）
            prod       = (p22 << 8) + (p22 << 3) - p22;    // ⭐ ×263（⛔ 无乘法器）
            v13        = 13'd64 + prod[21:10];             // ⭐ >>10 再 +64（⭐ 力度下限 64）
            pos_to_vel = (v13 > 13'd255) ? 8'd255 : v13[7:0];   // ⭐ 饱和到 255
        end
    endfunction

    // ⭐ ADSR 的 sustain 电平：⭐ `sustain_level = (vel<<8) × SUSTAIN_Q8 >> 8`
    //    （⭐ 与 `adsr.v:50-52` 同式 ⇒ ⭐ 判据里才能用**等式**而不是"大概变大"）
    function [ENV_W-1:0] sustain_of;
        input [VEL_W-1:0] v;
        begin
            sustain_of = (({v, {8{1'b0}}} * SUSTAIN_Q8) >> 8);
        end
    endfunction

    // ── 激励 / 观测 ─────────────────────────────────────────────────────────
    reg                    sample_tick;
    reg                    note_valid;
    reg  [AXIS_W-1:0]      note_axis;
    reg  [PHASE_W-1:0]     note_phase_inc;
    reg  [VEL_W-1:0]       note_velocity;
    reg  [1:0]             note_kind;          // 0 = on · 1 = off

    reg                    vel_upd_valid;
    reg  [AXIS_W-1:0]      vel_upd_axis;
    reg  [VEL_W-1:0]       vel_upd_value;

    wire [POLY-1:0]         voice_gate;
    wire [POLY-1:0]         voice_active;
    wire [POLY*AXIS_W-1:0]  voice_axis;
    wire [POLY*VEL_W-1:0]   voice_velocity;
    wire [POLY*ENV_W-1:0]   env_level;
    wire [POLY-1:0]         env_active;
    wire [POLY-1:0]         voice_retrig_reset;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W),
        .FIFO_DEPTH(8), .EVT_LOST_CNT_W(EVT_LOST_W)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind),
        .vel_upd_valid_i(vel_upd_valid), .vel_upd_axis_i(vel_upd_axis),
        .vel_upd_value_i(vel_upd_value),
        .pitch_upd_valid_i(1'b0), .pitch_upd_axis_i({AXIS_W{1'b0}}),
        .pitch_upd_value_i({PHASE_W{1'b0}}),
        .default_timbre_i({TIMBRE_W{1'b0}}), .evt_timbre_valid_i(1'b0),
        .evt_timbre_i({TIMBRE_W{1'b0}}),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(), .voice_age_o(),
        .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(), .alloc_voice_o(),
        .event_lost_o(), .event_lost_cnt_o(), .event_lost_clr_i(1'b0)
    );

    // ⭐ 真包络（⭐ 必须用真的 —— ⭐ 本 tb 的判据就是"包络电平跟着力度走"，
    //    ⚠️ 用桩就只是自证循环）
    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W),
        .ATTACK_STEP(ATTACK_STEP), .DECAY_STEP(DECAY_STEP),
        .SUSTAIN_Q8(SUSTAIN_Q8), .RELEASE_STEP(RELEASE_STEP)
    ) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ── 切片辅助 ────────────────────────────────────────────────────────────
    function [ENV_W-1:0] env_of;
        input integer v;
        begin env_of = env_level[v*ENV_W +: ENV_W]; end
    endfunction
    function [VEL_W-1:0] vel_of;
        input integer v;
        begin vel_of = voice_velocity[v*VEL_W +: VEL_W]; end
    endfunction
    function [AXIS_W-1:0] axis_of;
        input integer v;
        begin axis_of = voice_axis[v*AXIS_W +: AXIS_W]; end
    endfunction
    function integer gate_count;
        integer k; integer c;
        begin
            c = 0;
            for (k = 0; k < POLY; k = k + 1) if (voice_gate[k]) c = c + 1;
            gate_count = c;
        end
    endfunction
    // ⭐ 唯一的 gate 为高的 voice 下标（⛔ 找不到返回 −1 ⇒ 判据会失败，⛔ 不静默）
    function integer gated_idx;
        integer k;
        begin
            gated_idx = -1;
            for (k = 0; k < POLY; k = k + 1)
                if (voice_gate[k] && (gated_idx < 0)) gated_idx = k;
        end
    endfunction

    // ── 时基：走 n 个采样拍（`sample_tick` 恰好高 1 个 clk）──────────────────
    task run_ticks;
        input integer n;
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk); sample_tick = 1'b1;
                @(negedge clk); sample_tick = 1'b0;
                repeat (CLK_PER_SAMPLE - 2) @(negedge clk);
            end
        end
    endtask

    // ── 激励：一个 note 事件（kind 0 = on · 1 = off）─────────────────────────
    task pulse_note;
        input [AXIS_W-1:0]  ax;
        input [VEL_W-1:0]   v;
        input [1:0]         k;
        begin
            @(negedge clk);
            note_valid = 1'b1; note_axis = ax; note_velocity = v; note_kind = k;
            note_phase_inc = 32'h0001_0000;
            @(negedge clk);
            note_valid = 1'b0; note_velocity = {VEL_W{1'b0}};
        end
    endtask

    // ── 激励：一个 vel_upd（⭐ 在 top.v 里由 `vu_*` 每 164 µs 发一条）──────────
    task pulse_velupd;
        input [AXIS_W-1:0] ax;
        input [VEL_W-1:0]  v;
        begin
            @(negedge clk);
            vel_upd_valid = 1'b1; vel_upd_axis = ax; vel_upd_value = v;
            @(negedge clk);
            vel_upd_valid = 1'b0;
        end
    endtask

    // ⭐ 安全的切片读（⛔ `vidx < 0` 时返回 0，⭐ 不让越界读变成 x 传播）
    function [ENV_W-1:0] env_safe;
        input integer v;
        begin env_safe = (v >= 0) ? env_level[v*ENV_W +: ENV_W] : {ENV_W{1'b0}}; end
    endfunction
    function [VEL_W-1:0] vel_safe;
        input integer v;
        begin vel_safe = (v >= 0) ? voice_velocity[v*VEL_W +: VEL_W] : {VEL_W{1'b0}}; end
    endfunction

    integer         vidx;
    reg [ENV_W-1:0] lvl1, lvl2, lvl3;
    reg [VEL_W-1:0] held_vel;

    // ⭐ 四个位置（⭐ 判据全部由它们导出 ⇒ 语义 = "音量跟随位置"）
    localparam [11:0] P_PRESS = 12'd192;   // ⭐ 刚越 `TRIG_TH`(64) 的浅按
    localparam [11:0] P_DEEP  = 12'd600;   // ⭐ 按深
    localparam [11:0] P_HALF  = 12'd300;   // ⭐ 松回一半
    localparam [11:0] P_FULL  = 12'd744;   // ⭐ 满行程

    initial begin
        $dumpfile("build/sim/tb_vel_pos_follow/tb_vel_pos_follow.vcd");
        $dumpvars(0, tb_vel_pos_follow);

        sample_tick    = 1'b0;
        note_valid     = 1'b0;
        note_axis      = {AXIS_W{1'b0}};
        note_phase_inc = 32'h0001_0000;
        note_velocity  = {VEL_W{1'b0}};
        note_kind      = 2'd0;
        vel_upd_valid  = 1'b0;
        vel_upd_axis   = {AXIS_W{1'b0}};
        vel_upd_value  = {VEL_W{1'b0}};

        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        run_ticks(4);

        // ⭐ 先把"位置 → 力度"这张表打印出来（⭐ 判据的输入，便于人工核对）
        //    📌 这几行是**中文字面量**，⛔ 不走 `chk()` 的位向量通路 ⇒ 显示正常
        $display("  INFO: 位置 → 力度映射（⭐ vel = 64 + ((pos×263)>>10)，饱和 255）");
        $display("  INFO:   P_PRESS(%0d) = %0d", P_PRESS, pos_to_vel(P_PRESS));
        $display("  INFO:   P_DEEP (%0d) = %0d", P_DEEP,  pos_to_vel(P_DEEP));
        $display("  INFO:   P_HALF (%0d) = %0d", P_HALF,  pos_to_vel(P_HALF));
        $display("  INFO:   P_FULL (%0d) = %0d", P_FULL,  pos_to_vel(P_FULL));

        // ═════════════════════════════════════════════════════════════════
        // ① ⭐ 按下（位置 = P_PRESS）⇒ `note_on`（⭐ 起音力度 = f(pos)）
        // ═════════════════════════════════════════════════════════════════
        pulse_note(4'd0, pos_to_vel(P_PRESS), 2'd0);
        run_ticks(150);                    // ⭐ 足够走完 attack(≈44) + decay(≈7)

        vidx = gated_idx();
        chk("J1a: note_on -> exactly ONE voice gate is high", gate_count() == 1);
        chk("J1b: that voice carries axis 0", (vidx >= 0) && (axis_of(vidx) == 4'd0));
        chk("J1c: attack velocity == pos_to_vel(pos at trigger)", (vidx >= 0) && (vel_of(vidx) == pos_to_vel(P_PRESS)));
        lvl1 = env_safe(vidx);
        chk("J1d: env settled at sustain_of(that velocity)  [= vel * 64]", lvl1 == sustain_of(pos_to_vel(P_PRESS)));

        // ═════════════════════════════════════════════════════════════════
        // ② ⭐ 保持 gate 不变，**按深**（vel 变大）⇒ 包络【变大】
        // ═════════════════════════════════════════════════════════════════
        pulse_velupd(4'd0, pos_to_vel(P_DEEP));
        run_ticks(60);                     // ⭐ 足够从 lvl1 爬到新 sustain(≈11 拍)

        chk("J2a: pressing DEEPER made vel LARGER", (vidx >= 0) && (vel_of(vidx) == pos_to_vel(P_DEEP)));
        chk("J2b: vel_upd did NOT touch gate (params never make notes)", gate_count() == 1);
        lvl2 = env_safe(vidx);
        chk("J2c: env became LARGER", lvl2 > lvl1);
        chk("J2d: and it settled at the NEW sustain (not rising forever)", lvl2 == sustain_of(pos_to_vel(P_DEEP)));

        // ═════════════════════════════════════════════════════════════════
        // ③ ⭐⭐ **关键判据**：**松回一半**（vel 变小）⇒ 包络【变小】
        //     🔴 未改的 `note_manager`（`if value > vel_r[i]`）⇒ ⭐ **本条必须 FAIL**
        // ═════════════════════════════════════════════════════════════════
        pulse_velupd(4'd0, pos_to_vel(P_HALF));
        run_ticks(60);

        chk("J3a: easing BACK made vel SMALLER (positional = up AND down)", (vidx >= 0) && (vel_of(vidx) == pos_to_vel(P_HALF)));
        lvl3 = env_safe(vidx);
        chk("J3b: *** env became SMALLER ***  [MUST FAIL on the un-fixed note_manager]", lvl3 < lvl2);
        chk("J3c: and it settled at the NEW sustain", lvl3 == sustain_of(pos_to_vel(P_HALF)));

        $display("  INFO: 包络电平  L1(pos=%0d)=%0d  L2(pos=%0d)=%0d  L3(pos=%0d)=%0d",
                 P_PRESS, lvl1, P_DEEP, lvl2, P_HALF, lvl3);

        // ═════════════════════════════════════════════════════════════════
        // ⑥ ⭐ 守卫：**别的轴**的 vel_upd ⛔ 不得改本 voice（⭐ 轴号寻址）
        // ═════════════════════════════════════════════════════════════════
        held_vel = vel_safe(vidx);
        pulse_velupd(4'd3, pos_to_vel(P_FULL));    // ⭐ 轴 3（⭐ 本 tb 的音在轴 0）
        run_ticks(4);
        chk("J6: vel_upd on ANOTHER axis must NOT change this voice", (vidx >= 0) && (vel_of(vidx) == held_vel));

        // ═════════════════════════════════════════════════════════════════
        // ④ ⭐ 松手 ⇒ `note_off` ⇒ release ⇒ 衰减到 0
        // ═════════════════════════════════════════════════════════════════
        pulse_note(4'd0, {VEL_W{1'b0}}, 2'd1);     // kind 1 = off
        run_ticks(4);
        chk("J4a: note_off dropped the gate", gate_count() == 0);
        chk("J4b: env started to DECAY (release path is live)", env_safe(vidx) < lvl3);

        run_ticks(150);
        chk("J4c: env decayed all the way to 0", env_safe(vidx) == {ENV_W{1'b0}});
        chk("J4d: env_active fell", (vidx >= 0) && (env_active[vidx] == 1'b0));

        // ═════════════════════════════════════════════════════════════════
        // ⑤ ⭐ **抬起后不再改变力度**（⭐ 用户原话）——
        //     `note_manager` 侧由 `gate_mask` 保证：⭐ 松手 ⇒ `gate_r=0` ⇒ 门关
        //     ⚠️ 这条是**守卫**（⛔ 不是非空洞性判据）：未改的代码**也**通过
        //        （⭐ 因为 `gate_mask` 那道门本来就在）⇒ ⭐ 它守的是"改的时候
        //        ⛔ 不要把这道门一起拆掉"。
        // ═════════════════════════════════════════════════════════════════
        held_vel = vel_safe(vidx);
        pulse_velupd(4'd0, pos_to_vel(P_FULL));    // ⭐ 按到底（力度最大）⇒ ⛔ 必须无效
        run_ticks(8);
        chk("J5a: after note_off a vel_upd must NOT change vel (FROZEN)", (vidx >= 0) && (vel_of(vidx) == held_vel));
        chk("J5b: and env was not pushed back up (still 0)", env_safe(vidx) == {ENV_W{1'b0}});

        if (errors == 0)
            $display("PASS: vel_pos_follow acceptance - volume follows position (up AND down), frozen on release");
        else
            $fatal(1, "FAIL: vel_pos_follow acceptance has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
