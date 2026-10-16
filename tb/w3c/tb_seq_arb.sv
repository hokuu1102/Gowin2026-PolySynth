// ═══════════════════════════════════════════════════════════════════════════
//  tb_seq_arb —— ⭐ 源 A 三级仲裁（手弹 / 曲谱 / 演示）
//
//  ⭐ 为什么写这一支（⭐ 硬约束：新模块没有 tb = 没被验收）：
//     🔴 `seq_arb` 的**唯一职责**就是"⭐ **多源同拍相撞不丢**"
//     ⇒ ⚠️ 而"丢事件"正是**本项目最容易漏测的一类**：
//        · `U-6` `evt_merge`：⭐ 当年两路直接 or ⇒ 🔴 同拍丢一条
//        · `U-18b` `play_seq`：⭐ 16 判据全过、变异体 4/4 全抓，
//          🔴 **但同 tick 多事件从没测** ⇒ 和弦被拉成琶音
//     ⇒ ⭐⭐ **所以本 tb 的重点判据是"同拍 N 个源都到"**。
//
//  ⭐ 判据（10 条）：
//     ① ⭐ 无输入 ⇒ 不发任何事件
//     ② ⭐⭐ **手弹+曲谱同拍 ⇒ 两条都出来**（⭐ 最关键）
//     ③ ⭐⭐ **三源同拍 ⇒ 三条都出来**（⚠️ 演示让位后不算，⭐ 见 §让位）
//     ④ ⭐ **单源 ⇒ 正常转发**
//     ⑤ ⭐ **`evt_valid_o` 严格单周期**
//     ⑥ ⭐ **数据与 valid 同拍**（⭐ `80 号` 的教训）
//     ⑦ ⭐⭐ **演示让位**：⭐ 有手弹时演示**不参与**（⭐ 不自检和弦抢演奏）
//     ⑧ ⭐ **不丢也不多**：⭐ 发出的总数 == 输入的总数
//     ⑨ ⭐ **溢出可见**：⭐ 强灌到溢出 ⇒ `overflow_o` 拉起 + `drop_cnt_o` 计数
//     ⑩ ⭐ **A8：无 X/Z 传播**
//
//  ⭐⭐ 2026-10-16：⭐ **新增"鼓 / 旋律"那一整块**（⭐ 见 `drum_src_blk`）——
//     🔴 **为什么**：⭐ 鼓的判定依据从 **`score_axis_i >= 12`**（靠轴号猜）
//        改成了 **`score_is_drum_i`**（帧里的显式标志 `bit5`）⇒
//        ⚠️ **原来靠"设轴号"验鼓的 6 条判据【全部失效】**（⭐ 它们会验错东西）✅
//     ⭐ **本块的四组（⭐ 缺一组就有洞）**：
//        · ⭐ 鼓（`is_drum=1`）⇒ `SRC_KDRUM`（四件逐个 ＋ ⭐ **轴号 5 的反证**）
//        · ⭐ 鼓的 `inc` ⇒ **来自鼓自己的表**（⭐ 吃诱饵值仍须输出 `INC_*`）
//        · ⭐⭐⭐ **旋律绝不变鼓**：`is_drum=0` × 轴号 12/13/14/15 ⇒
//          **四条全部必须是 `SRC_SCORE`**（⭐ 用户拍板的红线 1 的机械保证）✅
//        · ⭐ 旋律的 `inc` **原样透传**（⭐ 音高⛔ 不许被鼓的表替换）✅
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_seq_arb;

    wire depth9_done;
    seq_arb_depth9_case a1_depth9 (.done(depth9_done));

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer KIND_W  = 2;
    localparam integer TIMBRE_W = 2;
    localparam integer DEPTH   = 6;
    localparam integer T       = 20;

    reg clk = 1'b0, rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    // ── 三个源 ────────────────────────────────────────────────────────────
    reg               live_v = 0, score_v = 0, demo_v = 0;
    reg [AXIS_W-1:0]  live_ax = 0, score_ax = 0, demo_ax = 0;
    reg [PHASE_W-1:0] live_inc = 0, score_inc = 0, demo_inc = 0;
    reg [VEL_W-1:0]   live_vel = 0, score_vel = 0, demo_vel = 0;
    reg [KIND_W-1:0]  live_kd = 0, score_kd = 0, demo_kd = 0;
    reg               live_tv = 0, score_tv = 0, demo_tv = 0;
    reg [TIMBRE_W-1:0] live_tb = 0, score_tb = 0, demo_tb = 0;
    //  ⭐⭐ 2026-10-16：⭐ **曲谱事件的【显式鼓标志】**（⭐ 取代旧的 `axis >= 12` 判据）✅
    //     ⭐ `is_drum` = 1 ⇒ 这条是鼓（⭐ 进鼓池 ＋ 用鼓自己的 `inc` 表）✅
    //     ⭐ `drum_type`：⭐ 0=Kick · 1=Snare · 2=HiHat · 3=Tom（⭐ 决定用哪个 `INC_*`）✅
    //     ⚠️ ⭐ 与 `score_v` **同拍**驱动（⭐ 真实链路里它们是同一个 64 位字的切片）✅
    reg               score_is_drum = 0;
    reg [1:0]         score_drum_type = 0;

    wire              evt_v;
    wire [AXIS_W-1:0] evt_ax;
    wire [PHASE_W-1:0] evt_inc;
    wire [VEL_W-1:0]  evt_vel;
    wire [KIND_W-1:0] evt_kd;
    wire              evt_tv;
    wire [TIMBRE_W-1:0] evt_tb;
    //  ⭐⭐ 2026-10-14：⭐ **来源**（⭐ 给"曲谱里的鼓"判据用 ✅）
    wire [2:0]        evt_src;
    wire [15:0] coll_cnt, merged_cnt, drop_cnt, live_cnt, score_cnt, demo_cnt;
    wire        overflow;

    seq_arb #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W), .KIND_W(KIND_W),
        .TIMBRE_W(TIMBRE_W), .DEPTH(DEPTH)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .live_valid_i(live_v),  .live_axis_i(live_ax),  .live_phase_inc_i(live_inc),
        .live_velocity_i(live_vel),  .live_kind_i(live_kd),
        .live_timbre_valid_i(live_tv), .live_timbre_i(live_tb),
        .score_valid_i(score_v), .score_axis_i(score_ax), .score_phase_inc_i(score_inc),
        //  ⭐⭐ 2026-10-16：⭐ `seq_arb` 新增的**两个显式鼓标志**输入 ✅
        //     📌 ⭐ 它们**取代**了 "`score_axis_i >= 4'd12`" 这条旧判据 ⇒
        //        ⭐ 本 tb 的鼓激励**全部**改成驱动这两位（⭐ 轴号⛔ 不再表达"是鼓"）✅
        .score_is_drum_i(score_is_drum), .score_drum_type_i(score_drum_type),
        .score_velocity_i(score_vel), .score_kind_i(score_kd),
        .score_timbre_valid_i(score_tv), .score_timbre_i(score_tb),
        .demo_valid_i(demo_v),  .demo_axis_i(demo_ax),  .demo_phase_inc_i(demo_inc),
        .demo_velocity_i(demo_vel),  .demo_kind_i(demo_kd),
        .demo_timbre_valid_i(demo_tv), .demo_timbre_i(demo_tb),
        .evt_valid_o(evt_v), .evt_axis_o(evt_ax), .evt_phase_inc_o(evt_inc),
        .evt_velocity_o(evt_vel), .evt_kind_o(evt_kd),
        .evt_timbre_valid_o(evt_tv), .evt_timbre_o(evt_tb),
        //  ⭐⭐ 2026-10-14：⭐ **来源**（⭐ 给"曲谱里的鼓"判据用 ✅）
        .evt_src_o(evt_src),
        .collision_cnt_o(coll_cnt), .merged_cnt_o(merged_cnt), .drop_cnt_o(drop_cnt),
        .overflow_o(overflow),
        .live_cnt_o(live_cnt), .score_cnt_o(score_cnt), .demo_cnt_o(demo_cnt)
    );

    // ══════════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-15（方案 B · 任务 3）：⭐ **四件鼓的 `inc` 常量【单一来源】** ✅
    //
    //  🔴 **为什么必须新增这一段**（⭐ 裂空发现的真缺口）：
    //     ⭐ 四件鼓的**身份全靠 `inc`**（⭐ `note_manager` 按 `inc` 分档 + `oscillator_bank`
    //        按 `inc` 选扫频深度），⚠️ 而原来的 `drum_src_blk` **只验 `evt_src_o`**（源标签）
    //     ⇒ 🔴 **ESP32 若把 axis↔inc 配错**（如 Kick 的轴 12 配了 Snare 的 `inc`）
    //        ⇒ ⭐ **FPGA 侧全绿，上板四件音色全错** ✅
    //     ⇒ ⭐ 本段 + 下面 4 条 `inc` 判据把这个缺口堵上 ✅
    //
    //  ⭐ **单一来源**：⭐ 照 `tb_key_drum.sv:87-92` 的做法 ——
    //     ⭐ **层次引用 `drum_gen` 的 `localparam INC_*`**，⛔ 不在这里抄一遍数字
    //     （⚠️ 抄错一个数就静默变乐器 —— ⭐ 那正是 `tb_key_drum.sv` 当年立的纪律）
    //  ⚠️ **必须用 `wire` 而⛔ 不是 `localparam`** —— ⭐ 层次引用不能出现在常量表达式里 ✅
    //  📌 **本实例【不参与激励】**：⭐ `tick_i=0` / `transport_i=0` / `pos_reset_i=0`
    //     ⇒ ⭐ 它**永远不发事件** ⇒ ⚠️ 对下面所有判据零影响（⭐ 只是把常量带进来）✅
    // ══════════════════════════════════════════════════════════════════════════
    wire        dg_evt_valid;
    wire [3:0]  dg_evt_axis;
    wire [31:0] dg_evt_inc;
    wire [7:0]  dg_evt_vel;
    wire [1:0]  dg_evt_kind;
    wire [15:0] dg_evt_cnt;
    wire [3:0]  dg_step_cnt;
    wire [3:0]  dg_hit_cnt;
    wire [15:0] dg_step_evt_cnt;
    wire        dg_cfg_warn;
    drum_gen u_drum_gen_ref (
        .clk_i(clk), .rst_n_i(rst_n),
        .pattern_id_i(2'd0),
        .tick_i(1'b0), .tick_cnt_i(16'd0), .bar_start_i(1'b0),
        .transport_i(1'b0), .pos_reset_i(1'b0),
        .evt_valid_o(dg_evt_valid), .evt_axis_o(dg_evt_axis),
        .evt_phase_inc_o(dg_evt_inc), .evt_velocity_o(dg_evt_vel),
        .evt_kind_o(dg_evt_kind), .evt_cnt_o(dg_evt_cnt),
        .step_cnt_o(dg_step_cnt), .hit_cnt_o(dg_hit_cnt),
        .step_evt_cnt_o(dg_step_evt_cnt), .cfg_warn_o(dg_cfg_warn)
    );
    //  ⭐ 四件鼓的"身份"常量（⭐ `drum_gen.v:180-186`）——
    //     ⭐ **方案 B 的轴↔件映射（⭐ 与 ESP32 侧约定）**：
    //        ⭐ 轴 **12 = Kick** · ⭐ **13 = Snare** · ⭐ **14 = HiHat** · ⭐ **15 = Tom** ✅
    wire [31:0] REF_KICK  = u_drum_gen_ref.INC_KICK;
    wire [31:0] REF_SNARE = u_drum_gen_ref.INC_SNARE;
    wire [31:0] REF_HIHAT = u_drum_gen_ref.INC_HIHAT;
    wire [31:0] REF_TOM   = u_drum_gen_ref.INC_TOM;

    // ── 收集出口事件（⭐ 用"轴"当身份，⭐ 各源用不同轴号便于识别）────────────
    integer n_out = 0;
    reg [AXIS_W-1:0] out_ax [0:127];
    reg [PHASE_W-1:0] out_inc [0:127];
    integer n_live_seen = 0, n_score_seen = 0, n_demo_seen = 0;

    // ⭐ 各源的"身份"：⭐ 用 phase_inc 当唯一标记（⭐ 便于核对是哪一条）
    localparam [31:0] LIVE_INC1  = 32'h1111_0001;
    localparam [31:0] LIVE_INC2  = 32'h1111_0002;
    localparam [31:0] SCORE_INC1 = 32'h2222_0001;
    localparam [31:0] SCORE_INC2 = 32'h2222_0002;
    localparam [31:0] DEMO_INC1  = 32'h3333_0001;

    always @(posedge clk) begin
        if (rst_n && evt_v) begin
            if (n_out < 128) begin
                out_ax[n_out]  = evt_ax;
                out_inc[n_out] = evt_inc;
            end
            n_out = n_out + 1;
            if (evt_inc == LIVE_INC1 || evt_inc == LIVE_INC2)  n_live_seen  = n_live_seen + 1;
            if (evt_inc == SCORE_INC1 || evt_inc == SCORE_INC2) n_score_seen = n_score_seen + 1;
            if (evt_inc == DEMO_INC1)                           n_demo_seen  = n_demo_seen + 1;
        end
    end

    //  ⭐⭐ 2026-10-14：⭐ **按轴号抓"来源"**（⭐ 给"曲谱里的鼓"判据用 ✅）
    //     📌 ⭐ 轴 **15 = 鼓**（⭐ 与 ESP32 侧的约定 ✅）；⭐ 轴 **2 = 普通乐音**（⭐ 对照组）✅
    reg [2:0] src_of_ax15 = 3'd7;
    reg [2:0] src_of_ax2  = 3'd7;
    //  ⭐⭐ 2026-10-15（**方案 B**）：⭐ 新增 4 路捕获 ——
    //     axis 12/13/14 = 四件鼓的另外三个轴 · axis 11 = ⭐ **边界非空洞性**
    reg [2:0] src_of_ax12 = 3'd7;
    reg [2:0] src_of_ax13 = 3'd7;
    reg [2:0] src_of_ax14 = 3'd7;
    reg [2:0] src_of_ax11 = 3'd7;
    //  ⭐⭐ 2026-10-15（方案 B · 任务 3）：⭐ **四件鼓的 `inc` 捕获**（⭐ 与 `src` 分开存）
    //     🔴 **为什么必须单独抓 `inc`**：⭐ 四件鼓的**身份全靠 `inc`** ——
    //        ⭐ `src_of_axNN` 只能证明"这条被判成鼓"，⛔ **证明不了"是哪一件鼓"** ✅
    //     ⭐ 哨兵值 `INC_NONE`：⭐ 与任何真实 `INC_*` 都不同 ⇒
    //        ⚠️ **事件没出来就停在哨兵值** ⇒ ⭐ 判据必红（⛔ 不会"什么都没验到还绿"）✅
    localparam [31:0] INC_NONE = 32'hDEAD_BEEF;
    reg [31:0] inc_of_ax15 = INC_NONE;
    reg [31:0] inc_of_ax12 = INC_NONE;
    reg [31:0] inc_of_ax13 = INC_NONE;
    reg [31:0] inc_of_ax14 = INC_NONE;
    //  ⭐⭐ 2026-10-16：⭐ **新增三路捕获**（⭐ 判定改成 `is_drum` 之后，轴号**不再是身份**）：
    //     · ⭐ **`ax5`** —— ⭐ **"鼓落在一个【看着像旋律】的轴号上"** ⇒
    //        ⭐ 用来证明"**判定与轴号无关**"（⭐ 旧判据下它必红）✅
    //     · ⭐ **`ax2` / `ax11`** —— ⭐ **旋律的 `inc` 透传**
    //        （⚠️ 原来这两条只抓 `src`，⛔ **没抓 `inc`** ⇒ 旋律音高被吃掉也验不出来）✅
    reg [2:0]  src_of_ax5  = 3'd7;
    reg [31:0] inc_of_ax2  = INC_NONE;
    reg [31:0] inc_of_ax11 = INC_NONE;
    reg [31:0] inc_of_ax5  = INC_NONE;
    always @(posedge clk) begin
        if (rst_n && evt_v) begin
            if (evt_ax == 4'd15) src_of_ax15 = evt_src;
            if (evt_ax == 4'd2)  src_of_ax2  = evt_src;
            if (evt_ax == 4'd12) src_of_ax12 = evt_src;
            if (evt_ax == 4'd13) src_of_ax13 = evt_src;
            if (evt_ax == 4'd14) src_of_ax14 = evt_src;
            if (evt_ax == 4'd11) src_of_ax11 = evt_src;
            //  ⭐⭐ 任务 3：⭐ **同时抓 `inc`** —— ⭐ 轴 ⇒ 件 的映射就在这里被钉住 ✅
            if (evt_ax == 4'd15) inc_of_ax15 = evt_inc;
            if (evt_ax == 4'd12) inc_of_ax12 = evt_inc;
            if (evt_ax == 4'd13) inc_of_ax13 = evt_inc;
            if (evt_ax == 4'd14) inc_of_ax14 = evt_inc;
            //  ⭐⭐ 2026-10-16：⭐ **轴 5（"像旋律"的轴号）＋ 旋律的 `inc` 透传** ✅
            if (evt_ax == 4'd5)  src_of_ax5  = evt_src;
            if (evt_ax == 4'd2)  inc_of_ax2  = evt_inc;
            if (evt_ax == 4'd11) inc_of_ax11 = evt_inc;
            if (evt_ax == 4'd5)  inc_of_ax5  = evt_inc;
        end
    end

    // ── 工具任务 ──────────────────────────────────────────────────────────
    task clr_srcs; begin
        live_v = 0; score_v = 0; demo_v = 0;
        live_ax = 0; score_ax = 0; demo_ax = 0;
        live_inc = 0; score_inc = 0; demo_inc = 0;
        live_vel = 0; score_vel = 0; demo_vel = 0;
        live_kd = 0; score_kd = 0; demo_kd = 0;
        live_tv = 0; score_tv = 0; demo_tv = 0;
        live_tb = 0; score_tb = 0; demo_tb = 0;
        //  ⭐ 2026-10-16：⭐ 鼓标志也一起清（⭐ ⛔ 否则会"漏"到下一条旋律上 —
        //     那正是**错拍**，🔴 本改动最怕的一种失效）✅
        score_is_drum = 0; score_drum_type = 0;
    end endtask

    task do_reset; begin
        rst_n = 1'b0;
        clr_srcs;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);
        n_out = 0; n_live_seen = 0; n_score_seen = 0; n_demo_seen = 0;
    end endtask

    // ⭐ 发一条"手弹"（⭐ 单拍脉冲，⭐ 与真实链路一致）
    task pulse_live(input [PHASE_W-1:0] inc); begin
        @(negedge clk);
        live_v = 1; live_inc = inc; live_ax = 4'd3; live_vel = 8'd200; live_kd = 2'd0;
        @(negedge clk);
        live_v = 0;
    end endtask

    task pulse_score(input [PHASE_W-1:0] inc); begin
        @(negedge clk);
        score_v = 1; score_inc = inc; score_ax = 4'd5; score_vel = 8'd180; score_kd = 2'd0;
        @(negedge clk);
        score_v = 0;
    end endtask

    task pulse_demo(input [PHASE_W-1:0] inc); begin
        @(negedge clk);
        demo_v = 1; demo_inc = inc; demo_ax = 4'd0; demo_vel = 8'd150; demo_kd = 2'd0;
        @(negedge clk);
        demo_v = 0;
    end endtask

    integer errors = 0;
    integer i;
    // ⭐⭐ 单周期判据（🔴 2026-09-26 修正：我第一版判据【写错了】）
    //   🔴 **错在哪**：我原来数"`evt_valid_o` 连续高了几拍"，⚠️ 要求 ≤1。
    //      ⇒ ⚠️ 但**队列里有 2 条时连弹 2 拍是完全正常的**！
    //      ⇒ 🔴 所以那个判据会把【正确行为】判成失败。
    //   ⭐ **正确判据**：⭐ **"同一个事件不能持续 2 拍"** ——
    //      ⭐ 即：⭐ `evt_valid_o` 连续为高时，⭐ **数据必须每拍都在变**
    //      （⭐ 若数据不变 ⇒ 🔴 那是"粘滞"，⭐ 才是真 bug ——
    //        ⚠️ `evt_merge` 注释里那个"valid 一直高、数据不变"的就是这种）
    //   ⚠️ 注意：`max_valid_high` 只用来**打印**（⭐ 说明"连续高几拍是正常的"），
    //      ⛔ **不再当判据** —— ⭐ 真正的判据是 `n_stuck`（零粘滞）
    reg              evt_v_d = 0;
    integer          n_valid_high_in_row = 0;
    integer          max_valid_high = 0;
    reg [AXIS_W-1:0]  last_ax  = 4'hF;
    reg [PHASE_W-1:0] last_inc = 32'hDEAD_BEEF;
    integer n_stuck = 0;                 // ⭐ "valid 高但数据没变"的拍数
    always @(posedge clk) begin
        if (rst_n && evt_v) begin
            // ⭐ 只有"【连续两拍】且数据完全一样"才算粘滞
            if (evt_v_d && (evt_ax === last_ax) && (evt_inc === last_inc))
                n_stuck = n_stuck + 1;
            last_ax  = evt_ax;
            last_inc = evt_inc;
        end
        evt_v_d <= evt_v;
    end

    // ⭐ 连续高几拍（⭐ 只用于打印，⛔ 不是判据）
    always @(posedge clk) begin
        if (rst_n) begin
            if (evt_v) begin
                n_valid_high_in_row = n_valid_high_in_row + 1;
                if (n_valid_high_in_row > max_valid_high) max_valid_high = n_valid_high_in_row;
            end else begin
                n_valid_high_in_row = 0;
            end
        end
    end

    initial begin
        $display("=== tb_seq_arb（源 A 三级仲裁）===");

        // ═══ ① 无输入 ⇒ 不发事件 ═══════════════════════════════════════════
        do_reset();
        repeat (20) @(negedge clk);
        if (n_out == 0) $display("  ok  : ① 无输入 ⇒ 不发任何事件");
        else begin
            $display("FAIL: ① 无输入却发了 %0d 条", n_out);
            errors = errors + 1;
        end

        // ═══ ④ 单源 ⇒ 正常转发 ═════════════════════════════════════════════
        do_reset();
        pulse_live(LIVE_INC1);
        repeat (8) @(negedge clk);
        if (n_out == 1 && out_inc[0] == LIVE_INC1)
            $display("  ok  : ④ 单源（手弹）⇒ 恰好 1 条，内容正确");
        else begin
            $display("FAIL: ④ 单源转发异常：n_out=%0d inc[0]=%h", n_out, out_inc[0]);
            errors = errors + 1;
        end

        // ═══ ② ⭐⭐ 手弹+曲谱【同拍】⇒ 两条都要出来 ════════════════════════
        do_reset();
        @(negedge clk);
        live_v = 1;  live_inc  = LIVE_INC1;  live_ax  = 4'd3;
        score_v = 1; score_inc = SCORE_INC1; score_ax = 4'd5;
        @(negedge clk);
        live_v = 0; score_v = 0;
        repeat (12) @(negedge clk);
        if (n_out == 2 && n_live_seen == 1 && n_score_seen == 1)
            $display("  ok  : ②⭐ 手弹+曲谱同拍 ⇒ 【两条都出来了】(live=1 score=1)");
        else begin
            $display("FAIL: ② 🔴 同拍相撞【丢事件】！n_out=%0d live=%0d score=%0d",
                     n_out, n_live_seen, n_score_seen);
            errors = errors + 1;
        end

        // ═══ ⑦ ⭐⭐ 演示让位：有手弹时演示不参与 ════════════════════════════
        do_reset();
        @(negedge clk);
        live_v = 1;  live_inc  = LIVE_INC1;
        demo_v = 1;  demo_inc  = DEMO_INC1;
        @(negedge clk);
        live_v = 0; demo_v = 0;
        repeat (12) @(negedge clk);
        if (n_live_seen == 1 && n_demo_seen == 0)
            $display("  ok  : ⑦ 演示让位 —— 手弹在发时演示【不参与】(live=1 demo=0)");
        else begin
            $display("FAIL: ⑦ 演示让位失效：live=%0d demo=%0d", n_live_seen, n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ④b 演示单独 ⇒ 正常发 ══════════════════════════════════════════
        do_reset();
        pulse_demo(DEMO_INC1);
        repeat (8) @(negedge clk);
        if (n_demo_seen == 1)
            $display("  ok  : ④b 演示单独（无别源）⇒ 正常发 1 条");
        else begin
            $display("FAIL: ④b 演示单独时没发出去 (demo=%0d)", n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ⑧ 不丢也不多：连发 N 条，数出来的必须相等 ═════════════════════
        do_reset();
        for (i = 0; i < 20; i = i + 1) begin
            pulse_live(LIVE_INC2);      // ⭐ 间隔发（⭐ 每 2 拍一条）
            @(negedge clk);
        end
        repeat (20) @(negedge clk);
        if (n_out == 20)
            $display("  ok  : ⑧ 连发 20 条 ⇒ 出来 20 条（不丢不多）");
        else begin
            $display("FAIL: ⑧ 连发 20 条却出来 %0d 条", n_out);
            errors = errors + 1;
        end

        // ═══ ⑤ 不粘滞：⭐ "valid 连续为高时数据必须每拍都在变" ═══════════════
        //   🔴 2026-09-26 修正：⭐ 我第一版判"连续高 ≤1 拍"，⚠️ 那是**错的**
        //      —— 队列里有 2 条时**连弹 2 拍完全正常**。
        //   ⭐ 正确判据：⭐ **同一个事件不能占 2 拍**（⭐ 那才是粘滞 ⇒ 数据不变）
        if (n_stuck == 0)
            $display("  ok  : ⑤ 不粘滞 —— valid 连续高时数据每拍都在变（最长连续 %0d 拍，正常）",
                     max_valid_high);
        else begin
            $display("FAIL: ⑤ 🔴 出现 %0d 拍'valid 高但数据不变'（粘滞）", n_stuck);
            errors = errors + 1;
        end

        // ═══ ⑨ 溢出可见 ═════════════════════════════════════════════════════
        //   🔴 2026-09-26 修正：⭐ 我第一版"每 2 拍推 2 条" ⇒ ⚠️ **平均只有 1 条/拍**
        //      ⇒ ⭐ 恰好等于出口速率 ⇒ 🔴 **永远追不上、灌不爆**（⭐ 逻辑是对的）
        //   ⭐ 正确做法：⭐ **每拍都推 2 条**（2 条/拍 > 出口 1 条/拍 ⇒ 必然积压）
        do_reset();
        for (i = 0; i < 60; i = i + 1) begin
            @(negedge clk);
            live_v = 1;  live_inc  = LIVE_INC1;
            score_v = 1; score_inc = SCORE_INC1;
            @(negedge clk);
            // ⚠️ **保持为 1**（⛔ 不清零）⇒ ⭐ 每拍都推 2 条 ⇒ 必然溢出
            live_v = 1; score_v = 1;
        end
        clr_srcs();
        repeat (40) @(negedge clk);
        if (overflow === 1'b1 && drop_cnt > 0)
            $display("  ok  : ⑨ 溢出【可见】—— overflow=1, drop_cnt=%0d（⛔ 不静默丢）", drop_cnt);
        else begin
            $display("FAIL: ⑨ 灌爆了却没报溢出 overflow=%b drop_cnt=%0d", overflow, drop_cnt);
            errors = errors + 1;
        end

        // ═══ ③ 三源同拍 ═════════════════════════════════════════════════════
        //   ⚠️ 注意：⭐ 演示让位 ⇒ 有手弹/曲谱时演示不参与
        //      ⇒ ⭐ 所以"三源同拍"实际出来的是 **手弹 + 曲谱 2 条**
        //      📌 这【就是设计意图】（⭐ 自检和弦不抢真演奏）
        do_reset();
        @(negedge clk);
        live_v = 1;  live_inc  = LIVE_INC1;
        score_v = 1; score_inc = SCORE_INC1;
        demo_v = 1;  demo_inc  = DEMO_INC1;
        @(negedge clk);
        live_v = 0; score_v = 0; demo_v = 0;
        repeat (12) @(negedge clk);
        if (n_live_seen == 1 && n_score_seen == 1 && n_demo_seen == 0)
            $display("  ok  : ③ 三源同拍 ⇒ 手弹+曲谱 2 条（⭐ 演示按设计让位）");
        else begin
            $display("FAIL: ③ 三源同拍异常：live=%0d score=%0d demo=%0d",
                     n_live_seen, n_score_seen, n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ⑥ 数据与 valid 同拍（⭐ 在 always 块里已按同拍取样 ⇒ 等价于检查） ═
        //   ⭐ 若 data 与 valid 不同拍 ⇒ ⭐ 前面按 inc 认身份就会认错/丢
        if (n_out > 0 && (n_live_seen + n_score_seen + n_demo_seen) <= n_out)
            $display("  ok  : ⑥ 数据与 valid 同拍（⭐ 按 inc 认身份全部认到了）");
        else begin
            $display("FAIL: ⑥ 数据/valid 不同拍：n_out=%0d 认出 %0d 条",
                     n_out, n_live_seen + n_score_seen + n_demo_seen);
            errors = errors + 1;
        end

        // ═══ ⑩ A8：无 X/Z ══════════════════════════════════════════════════
        if ((evt_v !== 1'bx) && (evt_ax !== 4'hx) && (evt_inc !== 32'hx))
            $display("  ok  : ⑩ A8 无 X/Z 传播");
        else begin
            $display("FAIL: ⑩ 出现 X/Z（v=%b ax=%h inc=%h）", evt_v, evt_ax, evt_inc);
            errors = errors + 1;
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑪ 每源计数必须【真的在数】（⭐ 2026-09-26 补 · 变异 M121 的 LEAK）
        //
        //  🔴 **为什么单补这一条**：⭐ 变异测试报 `M121 GREEN(LEAK)` ——
        //     ⭐ 把 `pop_src = pop_data[ENT_W +: NW]` 改成 `= 2'd3`（非法源 id）
        //     ⇒ ⭐ 每条弹出都被算成"未知源" ⇒ 🔴 **三个分源计数全部不涨**
        //     🔴 **我的 tb 却没抓到** —— ⚠️ **因为这三个信号【接了但从没断言】**。
        //  📌 **一般教训**：⭐ **"接了输出" ≠ "验了输出"** ——
        //     ⚠️ 一个从不被断言的输出，⭐ **在变异测试里等于不存在**。
        //     ⭐ 这正是 `M105`（`in_frame_cnt_o` 停止计数）那类 LEAK 的同族。
        //  ⭐ **判据**：⭐ 跑过确定已知的三段激励后，⭐ **三个计数必须分别对得上**。
        // ═══════════════════════════════════════════════════════════════════
        begin : per_source_cnt_check
            integer e_live, e_score, e_demo;
            // ⭐ 复位清计数，⭐ 然后各发确定条数
            do_reset();
            // ⭐ 手弹 3 条（⭐ 分开拍，⛔ 不相撞）
            pulse_live(LIVE_INC1);  @(negedge clk);
            pulse_live(LIVE_INC1);  @(negedge clk);
            pulse_live(LIVE_INC1);  @(negedge clk);
            // ⭐ 曲谱 2 条
            pulse_score(SCORE_INC1); @(negedge clk);
            pulse_score(SCORE_INC1); @(negedge clk);
            // ⭐ 演示 2 条（⭐ 此时无别的源 ⇒ 演示不被让位）
            pulse_demo(DEMO_INC1);  @(negedge clk);
            pulse_demo(DEMO_INC1);  @(negedge clk);
            repeat (20) @(negedge clk);
            e_live  = 3; e_score = 2; e_demo = 2;
            $display("      分源计数: live=%0d(期望%0d) score=%0d(期望%0d) demo=%0d(期望%0d)",
                     live_cnt, e_live, score_cnt, e_score, demo_cnt, e_demo);
            if (live_cnt == e_live && score_cnt == e_score && demo_cnt == e_demo)
                $display("  ok  : ⑪ 三个分源计数【都真的在数】（⭐ 上板可据此看'谁在发'）");
            else begin
                $display("FAIL: ⑪ 🔴 分源计数不对 ⇒ 可观测性在撒谎（K-106）");
                errors = errors + 1;
            end
        end

        $display("--------------------------------------------------");
        $display("  出口事件总数 = %0d（手弹 %0d · 曲谱 %0d · 演示 %0d）",
                 n_out, n_live_seen, n_score_seen, n_demo_seen);
        $display("  相撞计数 = %0d · 合流计数 = %0d · 丢弃 = %0d",
                 coll_cnt, merged_cnt, drop_cnt);
        $display("--------------------------------------------------");

        // ═══════════════════════════════════════════════════════════════════════
        //  ⭐⭐⭐ 2026-10-16：⭐ **曲谱里的鼓 ⇒ `evt_src_o == SRC_KDRUM`（判定依据【换了】）** ✅
        //
        //  🔴 **判定依据（⭐ 本轮改动，⭐ 必须看清）**：
        //     · ⛔ **旧**：⭐ `seq_arb.v` 的 `(score_axis_i >= 4'd12)` —— ⭐ **靠【轴号】猜** ✅
        //        ⇒ ⭐ 本 tb 原来就是**靠设轴号 12/13/14/15** 来验鼓的 ✅
        //        🔴 **它的问题**：⭐ **旋律轨一旦用到轴 12..15 ⇒ 必被判成鼓** ⇒
        //           ⭐ `note_manager` 推进**鼓池** ⇒ 🔴 **旋律线变成鼓声**
        //           （⭐ 用户拍板的红线 1："旋律线【绝对不能】变成鼓"）✅
        //     · ⭐ **新**：⭐ `seq_arb.score_is_drum_i` ＋ `score_drum_type_i` ——
        //        ⭐ 由 `top.v` 从帧的**保留位 `bit5`** / **`bit[8:7]`** 显式解码 ✅
        //        ⇒ ⭐ **轴号彻底退出判定**（⭐ 用户拍板的硬约束 4）✅
        //     ⇒ ⭐ **所以本块的激励全部改成"设 `is_drum` / `drum_type`"**，
        //        ⛔ **不再用轴号去表达"这是鼓"** ✅
        //
        //  ⭐ **为什么这里非有不可**：⭐ `note_manager` 的鼓池只认
        //     `SRC_AUX`（⭐ 源 B = 节拍器/鼓机）**或** `SRC_KDRUM`（⭐ 键盘打鼓）
        //     ⇒ ⚠️ 若这条不成立 ⇒ 🔴 **PC 灌的鼓会被判成乐音、推成音高** ✅
        //        （⭐ 这正是用户听到"鼓被推成音高"的根因 ✅）
        //
        //  ⭐⭐ **本块的四组判据（⭐ 缺一组就有洞）**：
        //     ① ⭐ **鼓 ⇒ `SRC_KDRUM`**（⭐ 四件鼓逐个，⭐ 轴号各用 12/13/14/15）
        //     ② ⭐⭐ **鼓的 `inc` 来自【鼓自己的表】**（⭐ 四件逐个 ＋ **吃诱饵值**）——
        //        ⭐ 激励故意喂一个**绝不是 `INC_*` 的诱饵 `score_inc`**
        //        ⇒ ⭐ 出口必须输出 `INC_*`（⭐ 证明"用的是鼓的表，⛔ 不是透传"）✅
        //     ③ ⭐ **轴号与判定【无关】**：⭐ `is_drum=1` 配 **`axis=5`**（⭐ 一个
        //        "看着就像旋律"的轴号）⇒ ⭐ 仍必须是 `SRC_KDRUM` ✅
        //        📌 🔴 **这一条是本块的关键**：⭐ 只有它能把"**新判据真的生效**"
        //           与"**碰巧轴号大**"分开（⭐ 旧判据下它必红）✅
        //     ④ ⭐⭐⭐ **旋律绝不变鼓**：⭐ `is_drum=0` 时把轴号**依次设成 12/13/14/15**
        //        ⇒ ⭐ **四条全部必须是 `SRC_SCORE`(1)** ✅
        //        📌 ⭐ 这就是用户红线 1 的**机械保证** ——
        //           ⭐ 轴号取什么值都**不可能**把旋律变成鼓 ✅
        //        📌 ⭐ 同时验 **`inc` 透传**（⭐ 旋律的音高必须原样出去）✅
        //
        //  ⭐⭐ `inc` 常量取 `drum_gen.INC_*`（⭐ 层次引用 ⇒ **单一来源**，⛔ 不抄数字）✅
        //     📌 ⭐ 2026-10-16 起 `drum_gen` 与 `seq_arb` **引用同一个头文件**
        //        （⭐ `rtl/w3c/drum_inc_defs.vh`）⇒ ⭐ 本块验的正是那条"**同一张表**"契约 ✅
        //
        //  ⭐⭐⭐ 2026-10-16：⭐ **判据口径（⭐ 随判定改动一起重写 —— 必须诚实）** ✅
        //  ---------------------------------------------------------------------------
        //  ⭐ **改动前**：⭐ 本块验的是"**`seq_arb` 把帧里的 `inc` 原样透传**"——
        //     ⚠️ 那时四件鼓的 `inc` **是 ESP32 从帧里写下来的**（⭐ `score_inc = REF_KICK`）
        //     ⇒ ⭐ 判据**只能**证明"字段没被截断/串位"，
        //        ⛔ **证明不了"是哪一件鼓"**（⭐ 配对是 tb 自己喂的）✅
        //  ✅ **改动后（⭐ 口径【变强】了）**：⭐ 鼓的 `inc` **不再来自帧** ——
        //     ⭐ 它由 `seq_arb` 按 `score_drum_type_i` 从**鼓自己的表**里选
        //     （⭐ `drum_inc_by_type` ⇒ `rtl/w3c/drum_inc_defs.vh`，⭐ 与 `drum_gen` 同一份）✅
        //     ⇒ ⭐ 于是本块可以喂一个**诱饵 `score_inc`**（⭐ 一个绝不等于任何 `INC_*` 的值）
        //        ＋ ⭐ 断言出口 `inc == REF_*` ⇒
        //        🔴 **诱饵值若出现在出口 ⇒ 判据必红**（⭐ 那正是"还在透传"的证据）✅
        //     📌 ⭐ 这就是硬约束 2（⭐ "与键盘打鼓同一个 inc 表"）的**机械判据** ✅
        //
        //  🔴 **顺带修掉一个旧缺口（⭐ 必须写明）**：
        //     ⚠️ 旧口径下有一处**已知未覆盖**：⭐ `top.v` 的 `<<10` 量化
        //        （⭐ `ps_evt_inc = {1'b0, ps_note_data[43:23], 10'b0}` ⇒ **低 10 位恒 0**）
        //        ⇒ ⭐ 生产链路上 `score_phase_inc_i` 只能是 `(INC_* >> 10) << 10`
        //        ⇒ 🔴 **"生产值 == `INC_*`"在旧设计里【不可达】** ✅
        //     ✅ **现在这个缺口对【鼓】不再存在**：⭐ 鼓的 `inc` **根本不走那一级**
        //        （⭐ 它不过 `ps_evt_inc`）⇒ ⭐ 出口就是 `INC_*` **满量程值** ✅
        //     📌 ⚠️ 而**旋律**仍然走 `<<10`（⭐ 那是它的音高，⭐ 必须走）
        //        ⇒ ⭐ 本块对旋律只验"**透传**"（⭐ 喂什么出什么），
        //           ⛔ **不验**"生产链路上的量化精度"（⭐ 那要 `tb_top_*` 层灌真帧）✅
        //  📌 **仍未覆盖的缺口（⭐ 留档，⛔ 不假装已覆盖）**：⭐
        //     "`top.v` 的 `bit5` / `bit[8:7]` 解码在**真帧**上是否对得上"
        //     ⇒ 🔴 **本 tb 覆盖不到**（⭐ 它验的是 `seq_arb` 的入口之后，
        //        ⚠️ `ps_is_drum` 的赋值本身要 `tb_top_*` 层灌真帧才验得到）✅
        //  ═══════════════════════════════════════════════════════════════════════
        begin : drum_src_blk
            //  ═══════════════════════════════════════════════════════════════════
            //  ⭐⭐ 2026-10-15（方案 B · 任务 2）：⭐ **每条判据【激励之前】各自复位捕获寄存器**
            //
            //  🔴 **为什么必须逐条复位**（⭐ 原来只在块首复位一次）：
            //     ⚠️ 若某条判据的**事件根本没出来** ⇒ 捕获寄存器会**保留上一条的值** ⇒
            //        🔴 而上一条恰好是对的 ⇒ ⭐ **"什么都没验到"却依然绿** ✗
            //     ⇒ ⭐ 逐条复位（哨兵 `3'd7` / `INC_NONE`）把两种失败**分开**：
            //        ⭐ ① **寄存器是死的**（一直停在哨兵）⇒ 判据红
            //        ⭐ ② **事件没出来**（也停在哨兵）⇒ 判据红
            //        ⇒ ⭐ **不可能"什么都没验到还绿"** ✅
            //  ═══════════════════════════════════════════════════════════════════
            //  ⭐ **本块用的"诱饵 `inc`"**（⭐ 2026-10-16）：
            //     🔴 **它绝不等于任何 `INC_*`**（⭐ 也⛔ 不是 `(INC_* >> 10) << 10`）——
            //     ⭐ 鼓事件喂它、而断言出口必须是 `REF_*` ⇒
            //     🔴 **"还在透传帧里的 `inc`" ⇒ 判据必红** ✅
            localparam [31:0] DECOY_INC = 32'h0BAD_0001;
            do_reset;
            src_of_ax15 = 3'd7;  inc_of_ax15 = INC_NONE;
            src_of_ax2  = 3'd7;  inc_of_ax2  = INC_NONE;
            src_of_ax12 = 3'd7;  inc_of_ax12 = INC_NONE;
            src_of_ax13 = 3'd7;  inc_of_ax13 = INC_NONE;
            src_of_ax14 = 3'd7;  inc_of_ax14 = INC_NONE;
            src_of_ax11 = 3'd7;  inc_of_ax11 = INC_NONE;
            src_of_ax5  = 3'd7;  inc_of_ax5  = INC_NONE;

            // ⭐ ① ⭐ `is_drum=1` + `drum_type=3`（Tom），轴号用 **15** ⇒ `SRC_KDRUM`（5）
            //     📌 ⭐ 轴号在这里**只是"事件轴号"**（⭐ 它会原样出现在 `evt_axis_o` 上）——
            //        ⛔ **它已经不再参与"是不是鼓"的判定** ✅
            src_of_ax15 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax15 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd15; score_inc = DECOY_INC;   // ⭐ 诱饵：⛔ 不是 INC_*
            score_is_drum = 1'b1; score_drum_type = 2'd3;              // ⭐ 3 = Tom
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
            repeat (10) @(negedge clk);
            if (src_of_ax15 !== 3'd5) begin
                $display("FAIL: is_drum=1 drum_type=3(Tom) came out as src=%0d, expected SRC_KDRUM=5 (the drum pool would reject it)", src_of_ax15);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=3(Tom) => SRC_KDRUM (5) -- note_manager puts it in the DRUM pool");
            //  ⭐⭐ 2026-10-16：⭐ **鼓的 `inc` 必须来自【鼓自己的表】**（⭐ 硬约束 2）✅
            //     🔴 **为什么**：⭐ *"鼓就是鼓的发声（与键盘打鼓同一个 inc 表、同一个池子）"* ——
            //        ⭐ 键盘打鼓走 `drum_gen.INC_TOM` ⇒ ⭐ 灌谱的鼓**必须是同一个值** ✅
            //     ⭐ **本条是"能红"的设计**：⭐ 激励喂的是 `DECOY_INC`（⭐ 绝不等值）
            //        ⇒ 🔴 **只要 `seq_arb` 还在透传帧里的 `inc`，本条必红** ✅
            //        （⭐ 即：本条同时钉住"用的是鼓的表"和"是哪一件鼓"）✅
            if (inc_of_ax15 !== REF_TOM) begin
                $display("FAIL: is_drum=1 drum_type=3 inc=%0d, expected TOM inc=%0d -- the drum table is NOT used (decoy value leaked through, or the type->inc map is wrong)", inc_of_ax15, REF_TOM);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=3 => TOM inc (%0d) -- the shared drum table is used (decoy %0d did NOT leak)", inc_of_ax15, DECOY_INC);

            // ⭐⭐ ② ⭐ `is_drum=1` + `drum_type=0`（**Kick**），轴号 12 ⇒ `SRC_KDRUM`（5）
            src_of_ax12 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax12 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd12; score_inc = DECOY_INC;   // ⭐ 诱饵：⛔ 不是 INC_*
            score_is_drum = 1'b1; score_drum_type = 2'd0;              // ⭐ 0 = Kick
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
            repeat (10) @(negedge clk);
            if (src_of_ax12 !== 3'd5) begin
                $display("FAIL: is_drum=1 drum_type=0(Kick) came out as src=%0d, expected SRC_KDRUM=5", src_of_ax12);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=0(Kick) => SRC_KDRUM (5) -- Kick");
            //  ⭐⭐ 鼓的 `inc` ⇒ 必须是 Kick 那一件（⭐ 口径同 ①：吃诱饵值仍须输出 `INC_*`）✅
            if (inc_of_ax12 !== REF_KICK) begin
                $display("FAIL: is_drum=1 drum_type=0 inc=%0d, expected KICK inc=%0d -- the drum table is NOT used (decoy value leaked through, or the type->inc map is wrong)", inc_of_ax12, REF_KICK);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=0 => KICK inc (%0d) -- shared drum table (decoy %0d did NOT leak)", inc_of_ax12, DECOY_INC);

            //  ⭐⭐⭐ ⭐ **鼓的 `note_off`（`kind=1`）也必须带 `SRC_KDRUM`** ✅
            //  🔴 **为什么必须单立一条**：⭐ 本块里**上面全部判据**都只驱动 `kind=0`（`note_on`）
            //     ⇒ 🔴 **"鼓的 OFF 走哪条源标记"完全没人验** ✗
            //  🔴 **若 OFF 被标成 `SRC_SCORE`**：⭐ `note_manager` 的 `note_off` 按
            //     **`(轴, 源)` 双条件**匹配 ⇒ ⭐ **匹配不上 ⇒ 鼓的 voice 永久 held**
            //     ⇒ 🔴 **保留池（`RESERVED_N = 5`）被慢慢耗尽 ⇒ 鼓越敲越不响** ✅
            //  ⭐ **现状（⭐ 2026-10-16 起）**：⭐ `seq_arb.v` 的
            //     `score_src_w = score_is_drum_i ? SRC_KDRUM : SRC_SCORE`
            //     **只看 `is_drum`、⛔ 不看 `kind`** ⇒ ⭐ ON/OFF **同源** ✅
            //     ⇒ ⭐ 本条把这个**不变量**钉死（⭐ 谁哪天给 `kind` 加条件，这里立刻红）✅
            //  ⭐ **能红实证**（⭐ 2026-10-16 实测过 ✅）：⭐ 把 `score_src_w` 改成
            //     `score_is_drum_i && (score_kind_i == 2'd0) ? SRC_KDRUM : SRC_SCORE`
            //     ⇒ ⭐ 本条必红（⭐ 原文见交付回报）✅
            src_of_ax12 = 3'd7;              // ⭐ 本条【自己】复位（⛔ 不吃上一条的残留）
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd12; score_inc = DECOY_INC;
            score_is_drum = 1'b1; score_drum_type = 2'd0;              // ⭐ Kick
            score_vel = 8'd200; score_kd = 2'd1;     // ⭐ `kind = 1` ⇒ `note_off`
            @(negedge clk);
            score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
            repeat (10) @(negedge clk);
            if (src_of_ax12 !== 3'd5) begin
                $display("FAIL: is_drum=1 kind=1(note_off) came out as src=%0d, expected SRC_KDRUM=5 -- the drum voice would stay HELD forever (reserved-pool exhaustion)", src_of_ax12);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 kind=1(note_off) => SRC_KDRUM (5) -- the drum voice can be released");

            // ═══════════════════════════════════════════════════════════════════
            //  ⭐⭐⭐ 2026-10-16（⭐ 审鼓队 P0-2 · 缺口 1）：⭐ **鼓的 on/off 轴号【必须一致】**
            //
            //  🔴 **机理（⭐ 为什么这一条是硬判据）**：
            //     ⭐ `note_manager.v:1413-1416` 的 `note_off` 清 voice 的判据是
            //        ```verilog
            //        if ((gate_r[i] | retrig_low[i])
            //            && (axis_r[i] == cur_axis)     // ← 轴号
            //            && (src_r[i]  == cur_src))     // ← 源标记
            //        ```
            //     ⭐ `note_manager.v:720-722` 的 `same_hit`（同键复用 voice）判据是
            //        ```verilog
            //        assign same_hit[sg] = (... )
            //            && (axis_r[sg] == cur_axis)     // ← 轴号
            //            && (src_r[sg]  == cur_src);     // ← 源标记
            //        ```
            //     ⇒ ⭐⭐ **两条都是【双条件】(axis, src) 同时相等才命中** ✅
            //
            //  🔴🔴 **风险链（⭐ 若 on 落 axis=A、off 落 axis=B 且 A≠B）**：
            //     · ⭐ on 帧（`kind=0`）⇒ `note_manager` 在 **axis=A** 上开一个鼓 voice
            //       （⭐ 源 = `SRC_KDRUM`，⭐ 因为它进的是**保留池** `RESERVED_N = 5` ✅）
            //     · ⭐ off 帧（`kind=1`）⇒ 按 **(axis=B, SRC_KDRUM)** 去清
            //       ⇒ 🔴 **A ≠ B ⇒ 匹配不上 ⇒ 那个 voice 的 `gate_r` 永远是 1**
            //     ⇒ 🔴🔴 **鼓 voice 永久 held** ⇒ 🔴 **保留池（只有 5 个槽）被慢慢耗尽**
            //        ⇒ 🔴 **后续的鼓 / 节拍器【全都不响】**（⭐ 池子满了 ✅）
            //
            //  ⭐ **本条的判法（⭐ 一对 on/off，⭐ 只看轴号这一个自由度）**：
            //     · ⭐ 灌一条 `is_drum=1, kind=0 (note_on), axis=X` ⇒ 抓出口轴号 `on_ax`
            //     · ⭐ 再灌一条 `is_drum=1, kind=1 (note_off), axis=X` ⇒ 抓出口轴号 `off_ax`
            //     · ⭐ **断言 `on_ax === off_ax`** —— ⭐ 即"同一个鼓，on 和 off 落在同一个轴上" ✅
            //     📌 ⭐ 用的是**同一个 X**（⭐ 这是**正常路径**：⭐ 上位机"一件一轴"
            //        12/13/14/15，⭐ on/off 写的是同一个轴 ✅）⇒ ⭐ 所以现在**必须绿** ✅
            //     🔴 若哪天有人给 off 那条路**换了轴**（⭐ 比如用 `drum_type` 当轴、
            //        ⭐ 或者像 P0-2 修前那样让上行/下行轴分开而漏改了下行）
            //        ⇒ ⭐ `on_ax != off_ax` ⇒ 🔴 **本条立刻红** ✅
            //
            //  ⭐ **为什么"同一条 X"也算非空洞**（⭐ 不能变成恒真判据）：
            //     🔴 恒真的风险在于：⭐ 若 `seq_arb` 把**两条都改成同一个常量轴**，
            //        那 `on_ax == off_ax` 仍成立 ⇒ ⚠️ 判据**照绿** ✅
            //     ✅ **本条已经挡住这一族**：⭐ 它**同时**断言 `on_ax === X`
            //        （⭐ `chk(on_ax === X)` ＋ `chk(off_ax === X)` 两条）——
            //        ⭐ 轴被压成常量 ⇒ 🔴 这两条**立刻红** ✅
            //        ⇒ ⭐ 于是"on/off 同轴"**不是**靠"都变成 0"骗过去的 ✅
            //
            //  ⭐ **能红实证（⭐ 回退验证时实测 ✅）**：⭐ 把 `seq_arb.v` 的
            //     `evt_axis_o <= pop_data[AX_O +: AXIS_W]`（原样透传）改成
            //     `evt_axis_o <= (pop_src == SRC_KDRUM) ? {2'b0, pop_data[0 +: 2]}
            //                    : pop_data[AX_O +: AXIS_W]`（⭐ 即 P0-2 修前那版：
            //                    下行轴被压成 drum_type ⇒ ⭐ 鼓的 on/off 轴都变成 0/1/2/3 ✅）
            //     ⇒ ⭐ `on_ax === X` 与 `off_ax === X` **两条一起红**（⭐ 原文见交付回报 ✅）
            //     📌 ⭐ **注意这不是本 tb 假造出来的**：⭐ 那个改法正是
            //        `seq_arb.v:134-149` 端口注释里**记录的真实缺陷（P0-2）** ✅
            begin : drum_onoff_axis_blk
                reg [3:0] on_ax, off_ax;
                // ⭐ 选一个"既不像旋律、也不在 12..15 里"的轴号 —— ⭐ 让"轴被压成
                //    drum_type"与"轴原样透传"**在数值上分得开**（⭐ 12..15 会被
                //    drum_type 的 2 位表达覆盖到 12/13/14/15 之外的冲突 ✅）
                localparam [3:0] X = 4'd6;
                // ⭐ 哨兵 `4'hF`：⭐ 事件没出来就停在哨兵 ⇒ 🔴 判据必红（⛔ 不假绿 ✅）
                on_ax  = 4'hF;
                off_ax = 4'hF;

                // ── ① on：`is_drum=1, kind=0 (note_on), axis=X` ──────────────────
                @(negedge clk);
                score_v = 1'b1; score_ax = X; score_inc = DECOY_INC;
                score_is_drum = 1'b1; score_drum_type = 2'd2;   // ⭐ HiHat（⛔ 与轴号无关）
                score_vel = 8'd200; score_kd = 2'd0;           // ⭐ `kind = 0` ⇒ `note_on`
                @(negedge clk);
                score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
                repeat (10) @(negedge clk);
                // ⭐ 抓出口轴号（⭐ `evt_axis_o` 是**下行定位键**，⛔ 不是上行的鼓标记 ✅）
                if (src_of_ax5 !== 3'd7) on_ax = 4'd5;          // ⭐ 不会命中（X=6）
                // ⭐ 用一条专用捕获：⭐ `evt_axis_o` 在 on/off 两次都要看
                //    ⇒ 直接在下面用 `out_ax[]` 里最后一条比对（⭐ 上面已有收集 ✅）
                if (n_out > 0) on_ax = out_ax[n_out-1];

                // ── ② off：`is_drum=1, kind=1 (note_off), axis=X` ─────────────────
                @(negedge clk);
                score_v = 1'b1; score_ax = X; score_inc = DECOY_INC;
                score_is_drum = 1'b1; score_drum_type = 2'd2;   // ⭐ 同一件鼓
                score_vel = 8'd200; score_kd = 2'd1;           // ⭐ `kind = 1` ⇒ `note_off`
                @(negedge clk);
                score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
                repeat (10) @(negedge clk);
                if (n_out > 0) off_ax = out_ax[n_out-1];

                // ── ③ 断言：⭐ on 与 off 必须落在【同一个轴】上 ─────────────────────
                //  🔴 **三条一起看才完整**（⭐ 少一条就有洞 ✅）：
                //     · ⭐ `on_ax === X`  —— 轴被**原样透传**（⛔ 没被压成 drum_type ✅）
                //     · ⭐ `off_ax === X` —— 同上，⭐ 且 off 走的是**同一条**透传路 ✅
                //     · ⭐ `on_ax === off_ax` —— 这才是 P0-2 的**真正契约**：
                //        "同一个鼓的 on/off 在 `note_manager` 的 (axis, src) 里必须配对" ✅
                if (on_ax === 4'hF || off_ax === 4'hF) begin
                    $display("FAIL: drum on/off axis -- one of the two events never came out (on_ax=%h off_ax=%h); the judgement is VACUOUS", on_ax, off_ax);
                    errors = errors + 1;
                end else if (on_ax !== X) begin
                    $display("FAIL: drum note_on axis=%0d, expected %0d (passthrough) -- the DOWNSTREAM axis was REPLACED (this is exactly P0-2: drum axis collapsed to drum_type, so on/off can NEVER pair in note_manager)", on_ax, X);
                    errors = errors + 1;
                end else if (off_ax !== X) begin
                    $display("FAIL: drum note_off axis=%0d, expected %0d (passthrough) -- the DOWNSTREAM axis was REPLACED (this is exactly P0-2: drum axis collapsed to drum_type, so on/off can NEVER pair in note_manager)", off_ax, X);
                    errors = errors + 1;
                end else if (on_ax !== off_ax) begin
                    $display("FAIL: drum note_on axis=%0d but note_off axis=%0d -- THE DRUM on/off AXIS MUST MATCH, otherwise note_manager's (axis,src) pairing never fires => the drum voice stays HELD forever => RESERVED_N=5 pool exhaustion", on_ax, off_ax);
                    errors = errors + 1;
                end else
                    $display("  ok  : drum note_on and note_off BOTH carry axis %0d -- the (axis,src) pair in note_manager will match, so the drum voice can be released (P0-2)", X);
            end

            // ⭐ ⭐ `is_drum=1` + `drum_type=1`（**Snare**），轴号 13 ⇒ `SRC_KDRUM`（5）
            src_of_ax13 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax13 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd13; score_inc = DECOY_INC;   // ⭐ 诱饵
            score_is_drum = 1'b1; score_drum_type = 2'd1;              // ⭐ 1 = Snare
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
            repeat (10) @(negedge clk);
            if (src_of_ax13 !== 3'd5) begin
                $display("FAIL: is_drum=1 drum_type=1(Snare) came out as src=%0d, expected SRC_KDRUM=5", src_of_ax13);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=1(Snare) => SRC_KDRUM (5) -- Snare");
            //  ⭐⭐ 鼓的 `inc` ⇒ 必须是 Snare 那一件（⭐ 口径同 ①：吃诱饵值仍须输出 `INC_*`）✅
            if (inc_of_ax13 !== REF_SNARE) begin
                $display("FAIL: is_drum=1 drum_type=1 inc=%0d, expected SNARE inc=%0d -- the drum table is NOT used (decoy value leaked through, or the type->inc map is wrong)", inc_of_ax13, REF_SNARE);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=1 => SNARE inc (%0d) -- shared drum table (decoy %0d did NOT leak)", inc_of_ax13, DECOY_INC);

            // ⭐ ⭐ `is_drum=1` + `drum_type=2`（**HiHat**），轴号 14 ⇒ `SRC_KDRUM`（5）
            src_of_ax14 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax14 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd14; score_inc = DECOY_INC;   // ⭐ 诱饵
            score_is_drum = 1'b1; score_drum_type = 2'd2;              // ⭐ 2 = HiHat
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
            repeat (10) @(negedge clk);
            if (src_of_ax14 !== 3'd5) begin
                $display("FAIL: is_drum=1 drum_type=2(HiHat) came out as src=%0d, expected SRC_KDRUM=5", src_of_ax14);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=2(HiHat) => SRC_KDRUM (5) -- HiHat");
            //  ⭐⭐ 鼓的 `inc` ⇒ 必须是 HiHat 那一件（⭐ 口径同 ①：吃诱饵值仍须输出 `INC_*`）✅
            if (inc_of_ax14 !== REF_HIHAT) begin
                $display("FAIL: is_drum=1 drum_type=2 inc=%0d, expected HIHAT inc=%0d -- the drum table is NOT used (decoy value leaked through, or the type->inc map is wrong)", inc_of_ax14, REF_HIHAT);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 drum_type=2 => HIHAT inc (%0d) -- shared drum table (decoy %0d did NOT leak)", inc_of_ax14, DECOY_INC);

            // ⭐⭐⭐ ③ ⭐ **轴号与判定【无关】**：⭐ `is_drum=1` 配 **`axis=5`**（⭐ 2026-10-16 新增）
            //  🔴 **为什么这一条是本块最关键的一条**：
            //     ⚠️ 上面 ①② 用的轴号（12/13/14/15）**恰好都在旧阈值 `>=12` 之上** ⇒
            //        🔴 **旧判据（靠轴号）下它们【照样绿】** —— ⭐ 那这些判据就【分不清】
            //        "**新判据真的生效了**" 和 "**碰巧轴号大**" ✗
            //     ✅ 本条的轴号是 **5**（⭐ 一个"看着就像普通旋律"的轴号）⇒
            //        🔴 **旧判据下它必红**（⭐ 会被判成 `SRC_SCORE`）⇒ ⭐ 判据**非空洞** ✅
            //     📌 ⭐ **能红实证**：⭐ 把 `score_src_w` 换回 `(score_axis_i >= 4'd12)`
            //        ⇒ ⭐ 本条必红（⭐ 原文见交付回报）✅
            src_of_ax5 = 3'd7;  inc_of_ax5 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd5; score_inc = DECOY_INC;    // ⭐ 诱饵
            score_is_drum = 1'b1; score_drum_type = 2'd3;              // ⭐ 3 = Tom
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0; score_is_drum = 1'b0; score_drum_type = 2'd0;
            repeat (10) @(negedge clk);
            if (src_of_ax5 !== 3'd5) begin
                $display("FAIL: is_drum=1 on axis==5 came out as src=%0d, expected SRC_KDRUM=5 -- the drum flag is NOT what decides (axis number still rules)", src_of_ax5);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 on axis==5 (a 'melody-looking' axis) => SRC_KDRUM (5) -- the AXIS NUMBER does NOT decide");
            if (inc_of_ax5 !== REF_TOM) begin
                $display("FAIL: is_drum=1 drum_type=3 on axis==5 inc=%0d, expected TOM inc=%0d (decoy leaked or type map wrong)", inc_of_ax5, REF_TOM);
                errors = errors + 1;
            end else
                $display("  ok  : is_drum=1 on axis==5 => TOM inc (%0d) -- the drum table follows the FLAG, not the axis", inc_of_ax5);

            // ⭐⭐⭐ ④ ⭐ **旋律绝不变鼓**（⭐ 2026-10-16 新增 —— ⭐ **本改动的核心判据**）✅
            //  🔴 **为什么必须有它**（⭐ 用户拍板的红线 1：⭐ *"旋律线【绝对不能】变成鼓"*）：
            //     ⚠️ 旧判据是 `axis >= 12` ⇒ ⭐ **旋律轨用到轴 12..15 就被读成鼓** ⇒
            //        🔴 进鼓池 ⇒ ⭐ **旋律线变成鼓声** ✅
            //     ✅ 新判据是显式 `is_drum` ⇒ ⭐ **`is_drum=0` ⇒ 无论轴号取什么值
            //        都必须是 `SRC_SCORE`** ⇒ ⭐ 这就是那条**机械保证** ✅
            //  ⭐ **本条把"无论轴号取什么值"里【最危险的那四个】逐个钉死**：
            //     ⭐ **12 / 13 / 14 / 15** —— ⭐ 正是旧判据会误判成鼓的那四个轴号 ✅
            //     📌 ⭐ 同时验 **`inc` 透传**（⭐ 旋律的音高必须原样出去，⛔ 不许被鼓的表替换）✅
            //  ⭐ **能红实证**（⭐ 2026-10-16 实测过 ✅）：⭐ 把 `score_src_w` 改回
            //     `(score_axis_i >= 4'd12)` ⇒ ⭐ 这四条**全部必红**（⭐ 原文见交付回报）✅
            begin : melody_never_drum
                integer m;
                for (m = 12; m <= 15; m = m + 1) begin
                    // ⭐ 逐条复位（⭐ 哨兵）：⛔ 不吃上一条的残留
                    case (m)
                        12: begin src_of_ax12 = 3'd7; inc_of_ax12 = INC_NONE; end
                        13: begin src_of_ax13 = 3'd7; inc_of_ax13 = INC_NONE; end
                        14: begin src_of_ax14 = 3'd7; inc_of_ax14 = INC_NONE; end
                        default: begin src_of_ax15 = 3'd7; inc_of_ax15 = INC_NONE; end
                    endcase
                    @(negedge clk);
                    // ⭐ **旋律**：（⭐ `is_drum` 恒 0 ＋ ⭐ 轴号故意取旧阈值之上的值）
                    //     ⚠️ ⭐ 用 `score_ax = m` 直接赋整数值 ——
                    //        ⛔ **不对 `integer` 做位选**（`m[3:0]`）⇒ ⭐ `K-91` 同族纪律 ✅
                    score_v = 1'b1; score_ax = m; score_inc = 32'h0AAA_0000 + m;
                    score_is_drum = 1'b0; score_drum_type = 2'd0;
                    score_vel = 8'd200; score_kd = 2'd0;
                    @(negedge clk);
                    score_v = 1'b0;
                    repeat (10) @(negedge clk);
                    case (m)
                        12: begin
                            if (src_of_ax12 !== 3'd1) begin
                                $display("FAIL: MELODY on axis==12 (is_drum=0) came out as src=%0d, expected SRC_SCORE=1 -- A MELODY LINE TURNED INTO A DRUM", src_of_ax12);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==12 is_drum=0 => SRC_SCORE (1) -- melody can NEVER become a drum");
                            if (inc_of_ax12 !== (32'h0AAA_0000 + 32'd12)) begin
                                $display("FAIL: MELODY axis==12 inc=%0h, expected %0h (passthrough) -- the melody pitch was REPLACED", inc_of_ax12, 32'h0AAA_0000 + 32'd12);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==12 inc passes through unchanged (%0h)", inc_of_ax12);
                        end
                        13: begin
                            if (src_of_ax13 !== 3'd1) begin
                                $display("FAIL: MELODY on axis==13 (is_drum=0) came out as src=%0d, expected SRC_SCORE=1 -- A MELODY LINE TURNED INTO A DRUM", src_of_ax13);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==13 is_drum=0 => SRC_SCORE (1) -- melody can NEVER become a drum");
                            if (inc_of_ax13 !== (32'h0AAA_0000 + 32'd13)) begin
                                $display("FAIL: MELODY axis==13 inc=%0h, expected %0h (passthrough) -- the melody pitch was REPLACED", inc_of_ax13, 32'h0AAA_0000 + 32'd13);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==13 inc passes through unchanged (%0h)", inc_of_ax13);
                        end
                        14: begin
                            if (src_of_ax14 !== 3'd1) begin
                                $display("FAIL: MELODY on axis==14 (is_drum=0) came out as src=%0d, expected SRC_SCORE=1 -- A MELODY LINE TURNED INTO A DRUM", src_of_ax14);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==14 is_drum=0 => SRC_SCORE (1) -- melody can NEVER become a drum");
                            if (inc_of_ax14 !== (32'h0AAA_0000 + 32'd14)) begin
                                $display("FAIL: MELODY axis==14 inc=%0h, expected %0h (passthrough) -- the melody pitch was REPLACED", inc_of_ax14, 32'h0AAA_0000 + 32'd14);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==14 inc passes through unchanged (%0h)", inc_of_ax14);
                        end
                        default: begin
                            if (src_of_ax15 !== 3'd1) begin
                                $display("FAIL: MELODY on axis==15 (is_drum=0) came out as src=%0d, expected SRC_SCORE=1 -- A MELODY LINE TURNED INTO A DRUM", src_of_ax15);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==15 is_drum=0 => SRC_SCORE (1) -- melody can NEVER become a drum");
                            if (inc_of_ax15 !== (32'h0AAA_0000 + 32'd15)) begin
                                $display("FAIL: MELODY axis==15 inc=%0h, expected %0h (passthrough) -- the melody pitch was REPLACED", inc_of_ax15, 32'h0AAA_0000 + 32'd15);
                                errors = errors + 1;
                            end else
                                $display("  ok  : MELODY axis==15 inc passes through unchanged (%0h)", inc_of_ax15);
                        end
                    endcase
                end
            end

            // ⭐ ⑤ ⭐ **普通旋律轴（11 / 2）⇒ 必须仍是 `SRC_SCORE`（1）**
            //     ⭐ 2026-10-16：⭐ **本条的【非空洞性】判据搬去 ③ 了** ——
            //        ⚠️ 旧版这里考的是"`axis>=12` 这个阈值有没有写成 `>=11`"，
            //        ⭐ 而阈值已经不存在 ⇒ ⭐ 它现在只当"**普通旋律照旧**"的回归保险 ✅
            //     ⭐ **新增**：⭐ 同时验 `inc` **原样透传**（⭐ 旧版只抓 `src`，⛔ 没抓 `inc`）✅
            src_of_ax11 = 3'd7;  inc_of_ax11 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd11; score_inc = 32'h0AAA_0011;
            score_is_drum = 1'b0; score_drum_type = 2'd0;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax11 !== 3'd1) begin
                $display("FAIL: score axis==11 came out as src=%0d, expected SRC_SCORE=1 (plain melody must stay melody)", src_of_ax11);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==11 => SRC_SCORE (1) -- plain melody stays melody");
            if (inc_of_ax11 !== 32'h0AAA_0011) begin
                $display("FAIL: score axis==11 inc=%0h, expected 0AAA0011 (passthrough) -- the melody pitch was REPLACED", inc_of_ax11);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==11 inc passes through unchanged (%0h)", inc_of_ax11);

            // ⭐ ⑥ ⭐ 轴 2（⭐ 离"旧边界"更远的第二道保险）⇒ 必须**仍是** `SRC_SCORE`（1）
            src_of_ax2 = 3'd7;  inc_of_ax2 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd2; score_inc = 32'h0AAA_0002;
            score_is_drum = 1'b0; score_drum_type = 2'd0;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax2 !== 3'd1) begin
                $display("FAIL: score axis==2 came out as src=%0d, expected SRC_SCORE=1 (the drum marker is over-broad)", src_of_ax2);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==2 still => SRC_SCORE (1) -- the drum marker is NOT over-broad");
            if (inc_of_ax2 !== 32'h0AAA_0002) begin
                $display("FAIL: score axis==2 inc=%0h, expected 0AAA0002 (passthrough) -- the melody pitch was REPLACED", inc_of_ax2);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==2 inc passes through unchanged (%0h)", inc_of_ax2);
        end

        // A1 addition: wait for the independent non-default DEPTH case.
        wait (depth9_done);

        if (errors == 0)
            $display("PASS: seq_arb 多源同拍不丢、演示让位、溢出可见、单周期、无 X/Z");
        else
            $fatal(1, "FAIL: seq_arb has %0d unexpected item(s)", errors);

        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule

// A1: one non-default DEPTH case; original acceptance assertions stay intact.
module seq_arb_depth9_case(output reg done = 1'b0);
    localparam integer D = 9;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg lv = 0, sv = 0, dv = 0;
    reg [1:0] dk = 0;
    reg [31:0] tag = 0;
    wire valid, tv, overflow;
    wire [3:0] ax;
    wire [31:0] inc;
    wire [7:0] vel;
    wire [1:0] kind, timbre;
    wire [2:0] src;
    wire [15:0] collision, merged, dropped, live_count, score_count, demo_count;
    seq_arb #(.DEPTH(D)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .live_valid_i(lv), .live_axis_i(4'd1), .live_phase_inc_i(tag),
        .live_velocity_i(8'd101), .live_kind_i(2'd0), .live_timbre_valid_i(1'b1), .live_timbre_i(2'd1),
        .score_valid_i(sv), .score_axis_i(4'd2), .score_phase_inc_i(tag + 32'd1),
        //  ⭐ 2026-10-16：⭐ `seq_arb` 新增的【显式鼓标志】——
        //     ⚠️ 本用例是 **`DEPTH` 宽度/环绕契约**（⭐ 与鼓无关）
        //     ⇒ ⭐ 恒接 0（⭐ 且 `axis=4'd2` 在旧判据下也从不 ≥12 ⇒ 行为逐位不变）✅
        .score_is_drum_i(1'b0), .score_drum_type_i(2'd0),
        .score_velocity_i(8'd202), .score_kind_i(2'd2), .score_timbre_valid_i(1'b0), .score_timbre_i(2'd2),
        .demo_valid_i(dv), .demo_axis_i(4'd3), .demo_phase_inc_i(tag + 32'd2),
        .demo_velocity_i(8'd33), .demo_kind_i(dk), .demo_timbre_valid_i(1'b1), .demo_timbre_i(2'd3),
        .evt_valid_o(valid), .evt_axis_o(ax), .evt_phase_inc_o(inc), .evt_velocity_o(vel),
        .evt_kind_o(kind), .evt_timbre_valid_o(tv), .evt_timbre_o(timbre), .evt_src_o(src),
        .collision_cnt_o(collision), .merged_cnt_o(merged), .drop_cnt_o(dropped), .overflow_o(overflow),
        .live_cnt_o(live_count), .score_cnt_o(score_count), .demo_cnt_o(demo_count)
    );
    // Software queue shifts entries on pop; no RTL pointer/carry implementation.
    reg [51:0] queue [0:D-1];
    reg [51:0] last_event = 0;
    reg priority_score = 0, sticky = 0;
    integer count = 0, head = 0, tail = 0;
    integer rc = 0, rm = 0, rd = 0, rl = 0, rs = 0, rdm = 0;
    integer full_hits = 0, reject_hits = 0, triple_hits = 0, wraps = 0, checks = 0;
    integer i, k, n;
    reg demo_allowed, expected_valid;
    task append_event(input integer source);
        begin
            case (source)
                0: queue[count] = {3'd0, 4'd1, tag, 8'd101, 2'd0, 1'b1, 2'd1};
                1: queue[count] = {3'd1, 4'd2, tag + 32'd1, 8'd202, 2'd2, 1'b0, 2'd2};
                2: queue[count] = {3'd2, 4'd3, tag + 32'd2, 8'd33, dk, 1'b1, 2'd3};
            endcase
            count = count + 1;
        end
    endtask
    always @(posedge clk) begin
        if (!rst_n) begin
            count = 0; head = 0; tail = 0; priority_score = 0; sticky = 0;
            rc = 0; rm = 0; rd = 0; rl = 0; rs = 0; rdm = 0;
            last_event = 0; expected_valid = 0;
        end else begin
            if (count == D) full_hits = full_hits + 1;
            expected_valid = (count != 0);
            if (expected_valid) begin
                last_event = queue[0];
                for (k = 0; k < count-1; k = k + 1) queue[k] = queue[k+1];
                count = count - 1;
                head = (head + 1) % D;
                rm = rm + 1;
                case (last_event[51:49])
                    0: rl = rl + 1;
                    1: rs = rs + 1;
                    2: rdm = rdm + 1;
                endcase
            end
            demo_allowed = dv && (!(lv || sv) || dk == 2'd1);
            n = (lv ? 1 : 0) + (sv ? 1 : 0) + (demo_allowed ? 1 : 0);
            if (n == 3) triple_hits = triple_hits + 1;
            if (n > 1) rc = rc + 1;
            if (count + n > D) begin
                rd = rd + n; sticky = 1; reject_hits = reject_hits + 1;
            end else begin
                if (lv && sv) begin
                    append_event(priority_score ? 1 : 0);
                    append_event(priority_score ? 0 : 1);
                end else if (lv) append_event(0);
                else if (sv) append_event(1);
                if (demo_allowed) append_event(2);
                if (tail + n >= D) wraps = wraps + 1;
                tail = (tail + n) % D;
            end
            // Baseline rotates even when the batch overflows.
            if (lv && sv) priority_score = !priority_score;
        end
        #1;
        checks = checks + 1;
        if ({valid, src, ax, inc, vel, kind, tv, timbre} !== {expected_valid, last_event})
            $fatal(1, "FAIL: DEPTH9 output/data/valid mismatch check=%0d", checks);
        if (collision !== rc || merged !== rm || dropped !== rd ||
            live_count !== rl || score_count !== rs || demo_count !== rdm || overflow !== sticky)
            $fatal(1, "FAIL: DEPTH9 diagnostic mismatch check=%0d", checks);
        if (dut.cnt_q !== count || dut.head_q !== head || dut.tail_q !== tail || dut.prio_score_r !== priority_score)
            $fatal(1, "FAIL: DEPTH9 state/wrap mismatch check=%0d", checks);
    end
    initial begin
        #2;
        // Red on old RTL is the width contract, not a claimed functional bug.
        if ($bits(dut.cnt_q) != $clog2(D+1) || $bits(dut.head_q) != $clog2(D) ||
            $bits(dut.tail_q) != $clog2(D) || $bits(dut.cnt_next) != $clog2(D+3) ||
            $bits(dut.tail_1) != $clog2(D) || $bits(dut.push_n) != 2)
            $fatal(1, "FAIL: A1 DEPTH9 width contract: cnt=%0d head=%0d sum=%0d (old RTL must be red)",
                   $bits(dut.cnt_q), $bits(dut.head_q), $bits(dut.cnt_next));
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (i = 0; i < 640; i = i + 1) begin
            @(negedge clk);
            tag = i * 4;
            // First burst reaches full with three sources, then exercises all
            // source masks/kinds, drain, and a reset while the queue is busy.
            if (i < 24) begin lv = 1; sv = 1; dv = 1; dk = 1; end
            else begin
                lv = i[0]; sv = i[1]; dv = i[2]; dk = i[4:3];
            end
            if (i == 319) rst_n = 0;
            if (i == 321) rst_n = 1;
        end
        @(negedge clk); lv = 0; sv = 0; dv = 0;
        repeat (D+3) @(negedge clk);
        if (full_hits == 0 || reject_hits == 0 || triple_hits == 0 || wraps < 2 || count != 0)
            $fatal(1, "FAIL: DEPTH9 empty coverage: full=%0d reject=%0d triple=%0d wraps=%0d",
                   full_hits, reject_hits, triple_hits, wraps);
        $display("PASS: A1 DEPTH9 width and behavioral queue checks=%0d full=%0d reject=%0d triple=%0d wraps=%0d",
                 checks, full_hits, reject_hits, triple_hits, wraps);
        done = 1;
    end
endmodule
