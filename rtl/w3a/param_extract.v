`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// param_extract.v · W3a 语义层：力度 / 颤音 / 表情
//
// ⭐ 冻结定义（`files/20-代码/代码总览图.md:197`）：
//    *"力度 / 颤音 / 表情"*，⭐ **核心纪律：⭐ "参数永不产生音符"**
//
// ── 🔴🔴 本模块最重要的一条：⭐ **结构上就没有"产生音符"的能力** ──────────────
//   ⭐ **本模块【没有】任何能接到 `note_manager.note_valid_i` 的输出端口。**
//   ⭐ 这**不是**"约定不要输出"，而是 ⭐ **接口上不可能输出**
//      ⇒ ⭐ **"参数误产生音符"这个故障模式被【结构性】消灭**
//         （⭐ 比"人记得别写错"强得多 —— ⭐ 本项目纪律 `C45`：防御要能被证明）。
//   📌 **验收判据**：⭐ **`param_extract` 的输出里⛔ 没有任何端口能连到 `note_valid_i`**。
//
// ── ⭐ 双阈值测速法（力度）────────────────────────────────────────────────────
//   ⭐ 越过【浅阈 t1】记时刻 → 越过【深阈 t2】记时刻
//   ⭐ `Δt = t2 − t1` ⇒ ⭐ **Δt 越小 = 按得越快 = 力度越大**
//   ⚠️ **⛔ 不做除法**（`/` 会综合出除法器 ⇒ ⚠️ 延迟不可控、资源大）
//      ⇒ ⭐ 改用**查表**（`Δt` 的高几位做索引）— 见 §VEL_LUT。
//
// ── ⭐ 与 `event_extract` 的配合（⭐ "先触发后修正"的落地）────────────────────
//   ⚠️ `note_on` 在越过 `t1` 时**立刻**发出（⭐ 用 `DEFAULT_VEL` 起音）
//   ⇒ ⭐ **延迟与力度无关** ⇒ ⭐ **确定性得到保证**。
//   ⭐ `vel_update` 在越过 `t2` 后发出 ⇒ ⭐ **修正"已经在响"的那个 voice**。
//
// ── ⛔ 纪律 ───────────────────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001**（`K-91`：⛔ 不用 SV 专有构造，否则整模块被静默丢弃）
//   · ⭐ **同步复位、低有效**、⭐ **单时钟域 50 MHz**
//   · ⭐ **`valid` 与数据必须同拍**（`K-109`）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module param_extract #(
    // ⭐ 轴数（⭐ 16）
    parameter integer AXIS_N = 16,
    // ⭐ 行程位宽（12 = MCP3208 满量程）
    parameter integer POS_W  = 12,
    // ⭐ 轴号位宽（4 ⇒ 与 `note_manager.AXIS_W` 一致）
    parameter integer AXIS_W = 4,
    // ⭐ 力度位宽（8 ⇒ 与 `note_manager.VEL_W` 一致）
    parameter integer VEL_W  = 8,
    // ⭐ 相位增量位宽（32 ⇒ 与 `note_manager.PHASE_W` 一致）
    parameter integer PHASE_W = 32,

    // ── ⭐ 双阈值（⭐ 测速用；⚠️ 上板可调）──────────────────────────────────
    //   ⭐ **浅阈 t1**：⭐ 越过它 ⇒ `event_extract` 立即发 `note_on`
    parameter [POS_W-1:0] VEL_T1 = 12'h200,
    //   ⭐ **深阈 t2**：⭐ 越过它 ⇒ 记时刻、算 `Δt` ⇒ 发 `vel_update`
    parameter [POS_W-1:0] VEL_T2 = 12'h600,
    //   ⭐ **`Δt` 的饱和上界**（单位：快照帧）
    //      ⚠️ `Δt` 极小时（⭐ 一次快照内越两阈）⇒ ⭐ 力度取**最大**（⛔ 不回绕）
    parameter integer DT_MIN = 1,
    //   ⭐ `Δt` 的映射上界：⭐ `Δt >= DT_MAX` ⇒ 力度取**最小**
    //      ⚠️ 一帧 196 µs ⇒ 10 帧 ≈ 2 ms（⭐ 慢按的典型时长）
    parameter integer DT_MAX = 10,
    //   ⭐ 力度范围（⭐ 与 `note_manager.DEFAULT_VEL=200` 协调）
    parameter [VEL_W-1:0] VEL_MAX = 8'd255,
    parameter [VEL_W-1:0] VEL_MIN = 8'd64,

    // ── ⭐ 音高修正门限（⭐ 滑音才发、⛔ 静止不发）──────────────────────────
    //   ⚠️ 依据（⭐ 变异体 `M97` 守的就是它）：
    //      ⚠️ 若无条件发 `pitch_update` ⇒ 🔴 **静止时疯狂刷参数**
    //      ⇒ ⭐ 必须"**变化超过门限才发**"。
    parameter [POS_W:0] PITCH_DELTA_TH = 13'd32
) (
    input  wire                    clk,
    input  wire                    rst_n,        // ⭐ 同步复位、低有效

    // ── 输入：⭐ 来自 `axis_snapshot`（同帧、原子）──────────────────────────
    input  wire                    snap_valid_i,
    input  wire [AXIS_N*POS_W-1:0] pos_i,

    // ── 输入：⭐ 来自 `event_extract` 的触发事件（⭐ 用于锁存"起音时刻"）────
    input  wire                    evt_valid_i,
    input  wire [AXIS_W-1:0]       evt_axis_i,
    input  wire [1:0]              evt_kind_i,    // ⭐ 0=note_on 1=note_off 2=pluck

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 输出：**只有【参数】通路**（→ `note_manager.vel_upd_*` / `pitch_upd_*`）
    //   🔴 **⛔ 注意：这里【没有】任何 `evt_*` / `note_*` 输出** ——
    //      ⭐ 本模块**结构上无法产生音符事件**（⭐ 见文件头说明）。
    // ═══════════════════════════════════════════════════════════════════════
    output reg                     vel_valid_o,    // ⭐ 力度修正（后到）
    output reg  [AXIS_W-1:0]       vel_axis_o,
    output reg  [VEL_W-1:0]        vel_value_o,

    output reg                     pitch_valid_o,  // ⭐ 音高修正（滑音持续移动）
    output reg  [AXIS_W-1:0]       pitch_axis_o,
    output wire [PHASE_W-1:0]      pitch_value_o   // ⚠️ 本版恒 0（⭐ 见下方 TODO）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 每轴测速状态
    //   ⭐ `t1_seen[i]`  = 已越过浅阈（⭐ 等深阈来算 Δt）
    //   ⭐ `t1_stamp[i]` = 越过浅阈那一刻的**帧计数**
    //   ⭐ `dt_hold[i]`  = 越深阈时算出的 `Δt`（⭐ 供出队用）
    // ═══════════════════════════════════════════════════════════════════════
    reg              t1_seen  [0:AXIS_N-1];
    reg [15:0]       t1_stamp [0:AXIS_N-1];
    reg [15:0]       dt_hold  [0:AXIS_N-1];
    reg              dt_valid [0:AXIS_N-1];    // ⭐ 有新的 Δt 待发
    reg              was_above_t2 [0:AXIS_N-1]; // ⭐ 迟滞：⛔ 避免在 t2 附近反复触发

    // ⭐ 帧计数（⭐ 单纯递增，⛔ 不要求精确周期）
    reg [15:0] frame_cnt;

    // ⭐ 逐轴扫描状态机（⭐ 同 `event_extract`：⭐ **一拍一个轴**，
    //   ⚠️ 教训 —— `for` 循环里改指针会**互相覆盖**）
    localparam integer SAW = (AXIS_N <= 1) ? 1 : $clog2(AXIS_N);
    reg [SAW-1:0] scan_axis;
    reg           scanning;

    // ⭐ 逐轴出队状态机（⭐ 力度修正）
    reg [SAW-1:0] emit_axis;
    reg           emitting;

    integer ai;
    integer ii;

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ 力度映射：`Δt` → `velocity`（⭐ **查表，⛔ 不做除法**）
    //
    //   ⭐ 语义：⭐ **`Δt` 小 ⇒ 力度大**（⭐ 按得快 = 力度大）
    //   ⭐ 映射：`velocity = VEL_MAX − (VEL_MAX − VEL_MIN) × (Δt − DT_MIN) / (DT_MAX − DT_MIN)`
    //      ⚠️ 但**运行期不做除法** ⇒ ⭐ **编译期算好一张表**（`initial` 填，⭐ 综合成常量 ROM）
    //   📌 表深 = `DT_MAX + 2`（⭐ 索引 0..DT_MAX+1，⭐ 超出取 VEL_MIN）
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer LUT_N = DT_MAX + 2;
    reg [VEL_W-1:0] vel_lut [0:LUT_N-1];

    //   ⚠️ 用 `integer` 做**编译期算术**，⭐ 但**落表时用定宽赋值**（⛔ 不直接拼接）
    integer lut_i;
    integer span;      // ⭐ VEL_MAX − VEL_MIN
    integer num;       // ⭐ 分子
    initial begin
        span = VEL_MAX - VEL_MIN;
        for (lut_i = 0; lut_i < LUT_N; lut_i = lut_i + 1) begin
            if (lut_i <= DT_MIN) begin
                // ⭐ Δt 极小（⭐ 一次快照内越两阈）⇒ ⭐ **力度取最大**（⛔ 不回绕）
                vel_lut[lut_i] = VEL_MAX;
            end else if (lut_i >= DT_MAX) begin
                // ⭐ Δt 很大（⭐ 慢按）⇒ ⭐ 力度取最小
                vel_lut[lut_i] = VEL_MIN;
            end else begin
                // ⭐ 线性插值（⭐ 编译期算，⛔ 运行期无除法）
                num = (span * (lut_i - DT_MIN)) / (DT_MAX - DT_MIN);
                vel_lut[lut_i] = VEL_MAX - num[VEL_W-1:0];
            end
        end
    end

    // ⭐ 取力度（⭐ 组合查表；⭐ 索引钳位 ⇒ ⛔ 不越界）
    function [VEL_W-1:0] vel_of;
        input [15:0] dt;
        integer idx;
        begin
            if (dt >= DT_MAX) idx = DT_MAX + 1;
            else if (dt <= DT_MIN) idx = 0;
            else idx = dt;
            vel_of = vel_lut[idx];
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 主逻辑
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk) begin
        if (!rst_n) begin
            for (ai = 0; ai < AXIS_N; ai = ai + 1) begin
                t1_seen[ai]      <= 1'b0;
                t1_stamp[ai]     <= 16'd0;
                dt_hold[ai]      <= 16'd0;
                dt_valid[ai]     <= 1'b0;
                was_above_t2[ai] <= 1'b0;
            end
            frame_cnt    <= 16'd0;
            scan_axis    <= {SAW{1'b0}};
            scanning     <= 1'b0;
            emit_axis    <= {SAW{1'b0}};
            emitting     <= 1'b0;
            vel_valid_o  <= 1'b0;
            vel_axis_o   <= {AXIS_W{1'b0}};
            vel_value_o  <= {VEL_W{1'b0}};
            pitch_valid_o<= 1'b0;
            pitch_axis_o <= {AXIS_W{1'b0}};
        end else begin
            // ⭐ 力度修正默认单周期
            vel_valid_o   <= 1'b0;
            // ⭐ 音高修正：⚠️ 本版恒 0（⭐ 见下方 TODO）
            pitch_valid_o <= 1'b0;
            pitch_axis_o  <= {AXIS_W{1'b0}};

            // ── ⭐ 帧计数（⭐ 每帧 +1，⭐ 用于测 Δt）─────────────────────────
            if (snap_valid_i) frame_cnt <= frame_cnt + 16'd1;

            // ═══════════════════════════════════════════════════════════════
            // ⭐ ① 锁存"起音时刻"：⭐ 收到 `note_on`/`pluck` ⇒ 记 `t1_stamp`
            //   ⚠️ ⭐ 这是"**先触发后修正**"的落地：
            //      ⭐ `event_extract` 在越【浅阈】时已经发了 `note_on`（⭐ 用默认力度），
            //      ⭐ 这里**只记时刻**，⭐ 等越【深阈】再算力度。
            // ═══════════════════════════════════════════════════════════════
            if (evt_valid_i && (evt_kind_i != 2'd1)) begin
                // ⭐ 注意：⛔ 只处理 note_on(0) / pluck(2)，⭐ **note_off(1) 不参与测速**
                t1_stamp[evt_axis_i] <= frame_cnt;
                t1_seen [evt_axis_i] <= 1'b1;
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ ② 逐轴扫描：⭐ 检测"越深阈" ⇒ 算 `Δt`（⭐ 一拍一个轴）
            //   ⚠️ 与 `event_extract` 同款状态机 —— ⛔ 不用 `for` 改共享寄存器
            // ═══════════════════════════════════════════════════════════════
            if (snap_valid_i) begin
                scanning  <= 1'b1;
                scan_axis <= {SAW{1'b0}};
            end else if (scanning) begin
                // ⭐ 当前轴的行程
                //   ⚠️ `pos_i[scan_axis*POS_W +: POS_W]` —— ⭐ 用寄存器做索引是安全的
                if (pos_i[scan_axis*POS_W +: POS_W] >= VEL_T2) begin
                    // ⭐ 已越深阈：⭐ **只在"刚越过"那一刻算一次**（⭐ 迟滞）
                    if (!was_above_t2[scan_axis] && t1_seen[scan_axis]) begin
                        // ⭐⭐ `Δt = 本帧 − 越过浅阈那一帧`
                        //   ⚠️ **必须防下溢**：⭐ 若 `frame_cnt < t1_stamp` ⇒ ⭐ **钳到 0**
                        //      （🔴 变异体 `M96` 守的就是它 —— ⚠️ 下溢回绕会让力度变成假值）
                        if (frame_cnt >= t1_stamp[scan_axis])
                            dt_hold[scan_axis] <= frame_cnt - t1_stamp[scan_axis];
                        else
                            dt_hold[scan_axis] <= 16'd0;    // ⭐ 钳位，⛔ 不回绕

                        dt_valid[scan_axis] <= 1'b1;        // ⭐ 待发 vel_update
                        t1_seen [scan_axis] <= 1'b0;        // ⭐ 一次触发只算一次
                    end
                    was_above_t2[scan_axis] <= 1'b1;
                end else begin
                    was_above_t2[scan_axis] <= 1'b0;        // ⭐ 回落 ⇒ 允许下次再算
                end

                // ⭐ 推进扫描
                if (scan_axis == (AXIS_N - 1)) begin
                    scanning  <= 1'b0;
                    scan_axis <= {SAW{1'b0}};
                end else begin
                    scan_axis <= scan_axis + {{(SAW-1){1'b0}}, 1'b1};
                end
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐ ③ 出队：⭐ 把 `dt_valid` 的轴逐个发成 `vel_update`
            //   ⚠️ **必须"发的那一拍同时锁存数据"** —— ⭐ `K-109`
            // ═══════════════════════════════════════════════════════════════
            if (!emitting) begin
                // ⭐ 找一个待发的轴（⭐ 优先级编码；⭐ 同一帧最多几个 ⇒ 逐个发）
                if (dt_valid[0])       begin emit_axis <= {SAW{1'b0}};              emitting <= 1'b1; end
                else if (AXIS_N > 1  && dt_valid[1])  begin emit_axis <= {{(SAW-1){1'b0}},1'b1}; emitting <= 1'b1; end
                else if (AXIS_N > 2  && dt_valid[2])  begin emit_axis <= {{(SAW-2){1'b0}},2'd2}; emitting <= 1'b1; end
                else if (AXIS_N > 3  && dt_valid[3])  begin emit_axis <= {{(SAW-2){1'b0}},2'd3}; emitting <= 1'b1; end
                else if (AXIS_N > 4  && dt_valid[4])  begin emit_axis <= {{(SAW-3){1'b0}},3'd4}; emitting <= 1'b1; end
                else if (AXIS_N > 5  && dt_valid[5])  begin emit_axis <= {{(SAW-3){1'b0}},3'd5}; emitting <= 1'b1; end
                else if (AXIS_N > 6  && dt_valid[6])  begin emit_axis <= {{(SAW-3){1'b0}},3'd6}; emitting <= 1'b1; end
                else if (AXIS_N > 7  && dt_valid[7])  begin emit_axis <= {{(SAW-3){1'b0}},3'd7}; emitting <= 1'b1; end
                else if (AXIS_N > 8  && dt_valid[8])  begin emit_axis <= {1'b1, {(SAW-1){1'b0}}}; emitting <= 1'b1; end
                else if (AXIS_N > 9  && dt_valid[9])  begin emit_axis <= {{(SAW-4){1'b0}},4'd9}; emitting <= 1'b1; end
                else if (AXIS_N > 10 && dt_valid[10]) begin emit_axis <= {{(SAW-4){1'b0}},4'd10}; emitting <= 1'b1; end
                else if (AXIS_N > 11 && dt_valid[11]) begin emit_axis <= {{(SAW-4){1'b0}},4'd11}; emitting <= 1'b1; end
                else if (AXIS_N > 12 && dt_valid[12]) begin emit_axis <= {{(SAW-4){1'b0}},4'd12}; emitting <= 1'b1; end
                else if (AXIS_N > 13 && dt_valid[13]) begin emit_axis <= {{(SAW-4){1'b0}},4'd13}; emitting <= 1'b1; end
                else if (AXIS_N > 14 && dt_valid[14]) begin emit_axis <= {{(SAW-4){1'b0}},4'd14}; emitting <= 1'b1; end
                else if (AXIS_N > 15 && dt_valid[15]) begin emit_axis <= {{(SAW-4){1'b0}},4'd15}; emitting <= 1'b1; end
            end else begin
                // ⭐ 发出 vel_update（⭐ valid 与数据**同拍锁存**）
                vel_valid_o <= 1'b1;
                vel_axis_o  <= emit_axis;
                vel_value_o <= vel_of(dt_hold[emit_axis]);
                dt_valid[emit_axis] <= 1'b0;
                emitting <= 1'b0;
            end

            // ═══════════════════════════════════════════════════════════════
            // ⭐⭐ ④ 音高修正（`pitch_update`）—— 🔴 **本版恒 0**
            //
            //   ⚠️ **为什么本版不做**：⭐ 音高修正属于【滑音】（⭐ 阶段 2），
            //      而其 `phase_inc` 值必须由 `axis_map` 用插值算出来
            //      ⇒ ⚠️ **要等滑音通路接通**（⭐ 见设计草案 §2.2b）。
            //
            //   ⭐ **但门限参数已就位**（`PITCH_DELTA_TH`）⇒ ⭐ 阶段 2 直接用。
            //   🔴 **TODO(阶段 2)**：⭐ 检测行程变化 > `PITCH_DELTA_TH` ⇒ 发 `pitch_upd`
            //      ⚠️ ⛔ **不许无条件发**（⭐ 变异体 `M97` 守的就是这个）——
            //      ⚠️ 否则**静止时也会疯狂刷参数**，⚠️ 白白占用 `note_manager` 的更新带宽。
            // ═══════════════════════════════════════════════════════════════
        end
    end

    // ⭐ 音高修正值：⚠️ 本版恒 0（⭐ 阶段 2 由滑音通路驱动）
    assign pitch_value_o = {PHASE_W{1'b0}};

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 参数自检
    //   ⚠️ 会**静默失效**的组合：
    //     ① `VEL_T2 <= VEL_T1` ⇒ 🔴 **深阈不超过浅阈** ⇒ ⚠️ 测速无意义
    //        （⭐ `Δt` 恒 0 或负 ⇒ ⭐ **力度恒定** ⇒ ⚠️ 力度功能静默失效）
    //     ② `DT_MAX <= DT_MIN` ⇒ 🔴 映射表退化 ⇒ ⚠️ 力度只有两档
    //     ③ `VEL_MAX <= VEL_MIN` ⇒ ⚠️ 极性与量程都反了
    //     ④ `PITCH_DELTA_TH == 0` ⇒ 🔴 **音高修正如无条件发**（⭐ `M97` 同类）
    // ═══════════════════════════════════════════════════════════════════════
    localparam PARAM_OK = (VEL_T2 > VEL_T1) && (DT_MAX > DT_MIN) &&
                          (VEL_MAX > VEL_MIN) && (PITCH_DELTA_TH > 0);

    initial begin
        if (VEL_T2 <= VEL_T1)
            $display("ERROR [param_extract] VEL_T2 (0x%03h) <= VEL_T1 (0x%03h) => the deep threshold is not above the shallow one => dt is always 0 and VELOCITY IS CONSTANT (silent loss of the feature). PARAM_OK=0.",
                     VEL_T2, VEL_T1);
        if (DT_MAX <= DT_MIN)
            $display("ERROR [param_extract] DT_MAX = %0d <= DT_MIN = %0d => the velocity map degenerates to two levels. PARAM_OK=0.",
                     DT_MAX, DT_MIN);
        if (VEL_MAX <= VEL_MIN)
            $display("ERROR [param_extract] VEL_MAX = %0d <= VEL_MIN = %0d => the velocity range is inverted or empty. PARAM_OK=0.",
                     VEL_MAX, VEL_MIN);
        if (PITCH_DELTA_TH == 0)
            $display("ERROR [param_extract] PITCH_DELTA_TH = 0 => pitch updates would be emitted unconditionally, flooding note_manager. PARAM_OK=0.");
        if (PARAM_OK)
            $display("NOTE [param_extract] PARAM_OK=1 (AXIS_N=%0d VEL_T1=0x%03h VEL_T2=0x%03h DT_MIN=%0d DT_MAX=%0d)",
                     AXIS_N, VEL_T1, VEL_T2, DT_MIN, DT_MAX);
    end

endmodule

`default_nettype wire
