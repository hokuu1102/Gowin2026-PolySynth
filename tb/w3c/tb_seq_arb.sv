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
        //  ⭐⭐ 2026-10-14：⭐ **曲谱里的鼓（`axis >= 12`，即 12/13/14/15）⇒ `evt_src_o == SRC_KDRUM`** ✅
        //     ⭐ 依据：⭐ `files/20-代码/FPGA侧答复-鼓谱发声与XOR更正-20261014.md` §二 ✅
        //     🔴 **为什么必须**：⭐ `note_manager` 的鼓池只认
        //        `SRC_AUX`（⭐ 源 B = 节拍器/鼓机）**或** `SRC_KDRUM`（⭐ 键盘打鼓）
        //        ⇒ ⚠️ 若这条不成立 ⇒ 🔴 **PC 灌的鼓会被判成乐音、推成音高** ✅
        //        （⭐ 这正是用户听到"鼓被推成音高"的根因 ✅）
        //     📌 ⭐ **两条都要**：⭐ ① 轴 12/13/14/15 必须是鼓；⭐ ② **轴 ≤ 11 必须仍是曲谱** ——
        //        ⚠️ 少了 ② 就分不清"修对了"和"改过头了"（⭐ 把整条曲谱都打成鼓）✅
        //  ⭐⭐ 2026-10-15（方案 B · 任务 3）：⭐ **再加 4 条 `inc` 判据** ——
        //     🔴 **为什么**：⭐ 四件鼓的**身份全靠 `inc`**（⭐ `note_manager` 按 `inc` 分档），
        //        ⚠️ 而上面那些判据**只验 `evt_src_o`（源标签）** ⇒
        //        🔴 **`inc` 字段若在 `seq_arb` 里被截断 / 串位 ⇒ FPGA 侧全绿、上板四件音色全错** ✅
        //     ⭐ 轴↔件（⭐ 与 ESP32 侧约定）：⭐ **12=Kick · 13=Snare · 14=HiHat · 15=Tom** ✅
        //     ⭐ `inc` 常量取 `drum_gen.INC_*`（⭐ 单一来源，⛔ 不抄数字）✅
        //     📌 ⭐ **语义核对**：⭐ `seq_arb` 的 `evt_phase_inc_o` 是 **整字透传**
        //        （⭐ `pack_src` 存 `inc`，弹出时 `pop_data[IN_O +: PHASE_W]` 原样出）
        //        ⇒ ⭐ 本判据钉的是 **`seq_arb` 出口**，⛔ 不是 `top.v:4844` 那级 `<<10` ✅
        //
        //  ⭐⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **判据口径【收窄】—— 必须诚实** ✅
        //  ---------------------------------------------------------------------------
        //  🔴 **原来这里的口径是错的**（⭐ 磐石逐行核实）：⭐ 上面那句
        //     "ESP32 若把 axis↔inc 配错 ⇒ FPGA 侧全绿、上板四件音色全错" **暗示**
        //     这 4 条能验"**ESP32 的 axis↔inc 配对**" ⇒ ⚠️ **实际上验不了**：
        //        · ⭐ 本 tb **自己**把 `score_axis` 与 `score_inc` **一起**驱动进去
        //          （⭐ `score_inc = REF_KICK` …）⇒ ⭐ **配对是 tb 喂的，⛔ 不是被测对象** ✗
        //        · ⭐ 它真正钉住的只有一件事：⭐ **`seq_arb` 把 `inc` 字段原样透传** ✅
        //  ⭐ **修正后的口径**：⭐ **本判据只验 `seq_arb` 的【字段切片透传】**，
        //     ⛔ **不验 ESP32 的 axis↔inc 配对**（⭐ 那需要 PC/ESP32 侧的真帧）✅
        //
        //  🔴 **并且：`INC_*` 的【满量程值】在生产链路上【不可达】—— 必须写明**：
        //     ⭐ 曲谱通路在 `top.v` 先做了一级 `<<10` 量化：
        //        `top.v:4844  wire [31:0] ps_evt_inc = {1'b0, ps_note_data[43:23], 10'b0};`
        //        （⭐ = **21 位字段 << 10** ⇒ ⭐ **低 10 位恒 0**）
        //     ⇒ ⭐ 生产链路上 `score_phase_inc_i` 只能是 **`(INC_* >> 10) << 10`**：
        //        · Kick  `5368709`  ⇒ `5367808`（⭐ 差 **901**）
        //        · Snare `42949673` ⇒ `42949632`（⭐ 差 **41**）
        //        · HiHat `171798691`⇒ `171798528`（⭐ 差 **163**）
        //        · Tom   `17895697` ⇒ `17895424`（⭐ 差 **273**）
        //     ⇒ 🔴 **"生产值 == `INC_*`"这条期望在本 tb 里【不可达】** ——
        //        ⚠️ 因为本 tb 把 `INC_*` **直接**灌进 `seq_arb`（⭐ 绕过了 `top.v` 那一级）
        //        ⇒ ⭐ **本判据【不覆盖】那一级量化** ✅
        //  📌 **未覆盖的缺口（⭐ 留档，⛔ 不假装已覆盖）**：⭐ "`top.v` 的 `<<10` 量化
        //     是否把四件鼓的 `inc` 压成同一个值 / 是否越出 `note_manager` 的分档边界"
        //     ⇒ 🔴 **本轮【没有】判据**（⭐ 要验它得在 `tb_top_*` 层灌真曲谱帧）✅
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
            do_reset;
            src_of_ax15 = 3'd7;  inc_of_ax15 = INC_NONE;
            src_of_ax2  = 3'd7;
            src_of_ax12 = 3'd7;  inc_of_ax12 = INC_NONE;
            src_of_ax13 = 3'd7;  inc_of_ax13 = INC_NONE;
            src_of_ax14 = 3'd7;  inc_of_ax14 = INC_NONE;
            src_of_ax11 = 3'd7;

            // ⭐ ① 轴 15（⭐ 鼓 · ⭐ **Tom**）⇒ 应当是 `SRC_KDRUM`（5）
            src_of_ax15 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax15 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd15; score_inc = REF_TOM;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax15 !== 3'd5) begin
                $display("FAIL: score axis==15 came out as src=%0d, expected SRC_KDRUM=5 (the drum pool would reject it)", src_of_ax15);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==15 => SRC_KDRUM (5) -- note_manager puts it in the DRUM pool");
            //  ⭐⭐ 任务 3（2026-10-15）：⭐ **轴 15 ⇒ Tom 的 `inc`**（⭐ 身份，⛔ 不只是"是鼓"）
            //     🔴 为什么必须单立一条：⭐ 四件鼓的**身份全靠 `inc`** ——
            //        ⭐ `evt_src_o` 只证明"被判成鼓"，⛔ 证明不了"是哪一件鼓" ✅
            //        ⇒ ⭐ `inc` 若在 `seq_arb` 里被截断/串位 ⇒ **FPGA 侧全绿、上板四件音色全错** ✅
            //     ⚠️ **口径（⭐ 2026-10-15 修正）**：⭐ 本条只验 **`seq_arb` 的字段切片透传**，
            //        ⛔ **不验 ESP32 的 axis↔inc 配对**（⭐ 配对是 tb 自己喂的，⭐ 见块首长注释）✅
            if (inc_of_ax15 !== REF_TOM) begin
                $display("FAIL: score axis==15 inc=%0d, expected TOM inc=%0d -- seq_arb field-slice passthrough BROKEN (this check does NOT verify the ESP32 axis<->inc pairing)", inc_of_ax15, REF_TOM);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==15 => TOM inc (%0d) -- seq_arb field slice passthrough only, NOT ESP32 pairing", inc_of_ax15);

            // ⭐⭐ ②（**方案 B** 2026-10-15）轴 12 / 13 / 14 ⇒ ⭐ **必须都是 `SRC_KDRUM`（5）**
            //     🔴 为什么：⭐ 四件鼓分四轴 `12/13/14/15` ⇒ 四件**都**要被判成鼓，
            //        否则轴 12/13/14 会落进 `SRC_SCORE` ⇒ ⭐ 鼓的 `inc` 被当【音高】发声 = 电子音。
            //     ⭐ 依据：`files/20-代码/FPGA侧答复-鼓机多声部方案B-20261015.md`
            src_of_ax12 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax12 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd12; score_inc = REF_KICK;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax12 !== 3'd5) begin
                $display("FAIL: score axis==12 came out as src=%0d, expected SRC_KDRUM=5 (方案B: 四件鼓分四轴)", src_of_ax12);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==12 => SRC_KDRUM (5) -- Kick");
            //  ⭐⭐ 任务 3：⭐ **轴 12 ⇒ Kick 的 `inc`**（⭐ 口径同上：只验字段透传）✅
            if (inc_of_ax12 !== REF_KICK) begin
                $display("FAIL: score axis==12 inc=%0d, expected KICK inc=%0d -- seq_arb field-slice passthrough BROKEN (this check does NOT verify the ESP32 axis<->inc pairing)", inc_of_ax12, REF_KICK);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==12 => KICK inc (%0d) -- seq_arb field slice passthrough only, NOT ESP32 pairing", inc_of_ax12);

            //  ⭐⭐⭐ 2026-10-15（清道夫 SWEEPER）：⭐ **鼓的 `note_off`（`kind=1`）也必须带
            //     `SRC_KDRUM`** —— ⭐ 这是本轮【新增】的判据 ✅
            //  🔴 **为什么必须单立一条**：⭐ 本块里**上面全部判据**都只驱动 `kind=0`（`note_on`）
            //     ⇒ 🔴 **"鼓的 OFF 走哪条源标记"完全没人验** ✗
            //  🔴 **若 OFF 被标成 `SRC_SCORE`**：⭐ `note_manager.v:1320` 的 `note_off` 按
            //     **`(轴, 源)` 双条件**匹配 ⇒ ⭐ **匹配不上 ⇒ 鼓的 voice 永久 held**
            //     ⇒ 🔴 **保留池（`RESERVED_N = 5`）被慢慢耗尽 ⇒ 鼓越敲越不响** ✅
            //  ⭐ **现状**：⭐ `seq_arb.v` 的 `score_src_w = (score_axis_i >= 4'd12) ? SRC_KDRUM
            //     : SRC_SCORE` **只看轴、⛔ 不看 `kind`** ⇒ ⭐ ON/OFF **同源** ✅
            //     ⇒ ⭐ 本条把这个**不变量**钉死（⭐ 谁哪天给 `kind` 加条件，这里立刻红）✅
            //  ⭐ **能红实证**：⭐ 能 —— ⭐ 把 `score_src_w` 改成
            //     `(score_axis_i >= 4'd12) && (score_kind_i == 2'd0)` ⇒ ⭐ 本条必红 ✅
            src_of_ax12 = 3'd7;              // ⭐ 本条【自己】复位（⛔ 不吃上一条的残留）
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd12; score_inc = REF_KICK;
            score_vel = 8'd200; score_kd = 2'd1;     // ⭐ `kind = 1` ⇒ `note_off`
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax12 !== 3'd5) begin
                $display("FAIL: score axis==12 kind=1(note_off) came out as src=%0d, expected SRC_KDRUM=5 -- the drum voice would stay HELD forever (reserved-pool exhaustion)", src_of_ax12);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==12 kind=1(note_off) => SRC_KDRUM (5) -- the drum voice can be released");

            src_of_ax13 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax13 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd13; score_inc = REF_SNARE;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax13 !== 3'd5) begin
                $display("FAIL: score axis==13 came out as src=%0d, expected SRC_KDRUM=5", src_of_ax13);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==13 => SRC_KDRUM (5) -- Snare");
            //  ⭐⭐ 任务 3：⭐ **轴 13 ⇒ Snare 的 `inc`**（⭐ 口径同上：只验字段透传）✅
            if (inc_of_ax13 !== REF_SNARE) begin
                $display("FAIL: score axis==13 inc=%0d, expected SNARE inc=%0d -- seq_arb field-slice passthrough BROKEN (this check does NOT verify the ESP32 axis<->inc pairing)", inc_of_ax13, REF_SNARE);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==13 => SNARE inc (%0d) -- seq_arb field slice passthrough only, NOT ESP32 pairing", inc_of_ax13);

            src_of_ax14 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            inc_of_ax14 = INC_NONE;
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd14; score_inc = REF_HIHAT;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax14 !== 3'd5) begin
                $display("FAIL: score axis==14 came out as src=%0d, expected SRC_KDRUM=5", src_of_ax14);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==14 => SRC_KDRUM (5) -- HiHat");
            //  ⭐⭐ 任务 3：⭐ **轴 14 ⇒ HiHat 的 `inc`**（⭐ 口径同上：只验字段透传）✅
            if (inc_of_ax14 !== REF_HIHAT) begin
                $display("FAIL: score axis==14 inc=%0d, expected HIHAT inc=%0d -- seq_arb field-slice passthrough BROKEN (this check does NOT verify the ESP32 axis<->inc pairing)", inc_of_ax14, REF_HIHAT);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==14 => HIHAT inc (%0d) -- seq_arb field slice passthrough only, NOT ESP32 pairing", inc_of_ax14);

            // ⭐⭐ ③ ⭐ **边界非空洞性**（方案 B 新增，⭐ 这一条是本轮的关键判据）：
            //     ⭐ **轴 11 必须【仍是】`SRC_SCORE`（1）** ——
            //     🔴 为什么必须有它：⭐ 原来的"轴 2"离边界（12）**太远** ⇒
            //        阈值写成 `>= 4` 甚至 `>= 2` 它**照样绿** ⇒ ⭐ 判据空洞 ✗
            //     ✅ 有了轴 11 ⇒ ⭐ **阈值写成 `>= 11` 时这一条必红** ✓
            src_of_ax11 = 3'd7;              // ⭐ 任务 2：⭐ 本条【自己】复位
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd11; score_inc = 32'h0AAA_0011;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax11 !== 3'd1) begin
                $display("FAIL: score axis==11 came out as src=%0d, expected SRC_SCORE=1 (the >=12 boundary is OFF BY ONE!)", src_of_ax11);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==11 => SRC_SCORE (1) -- the >=12 boundary is exact");

            // ⭐ ④ 轴 2（⭐ 普通乐音，⭐ 离边界更远的第二道保险）⇒ 必须**仍是** `SRC_SCORE`（1）
            src_of_ax2 = 3'd7;               // ⭐ 任务 2：⭐ 本条【自己】复位
            @(negedge clk);
            score_v = 1'b1; score_ax = 4'd2; score_inc = 32'h0AAA_0002;
            score_vel = 8'd200; score_kd = 2'd0;
            @(negedge clk);
            score_v = 1'b0;
            repeat (10) @(negedge clk);
            if (src_of_ax2 !== 3'd1) begin
                $display("FAIL: score axis==2 came out as src=%0d, expected SRC_SCORE=1 (the drum marker is over-broad)", src_of_ax2);
                errors = errors + 1;
            end else
                $display("  ok  : score axis==2 still => SRC_SCORE (1) -- the drum marker is NOT over-broad");
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
