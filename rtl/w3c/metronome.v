`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// metronome.v · 节拍器（合成 click，走【已有事件通路】）—— W3c（`T33`）
//
// ⭐ 接口来源（唯一权威）：`files/20-代码/鼓机节拍器与Loop方案.md` §二
//   · §2.1 设计：`beat_gen.tick` → 一个短促 click 事件 → `note_manager`
//   · §2.1 重音：**小节首拍 = 高音**（建议 1760 Hz）、其余拍 = 低音（880 Hz）
//   · §2.2 冲突：⭐ **必须用专用 voice**，否则 32 音全响时**节拍器会没声**
//   · 冻结表 §三 接口 ① 的 `note_evt_t` 格式
//
// ⭐⭐ 最关键的架构选择（照抄文档 §2.1 的结论）：
//   **节拍器不是"另一条发声路径"，而是"一个自动按拍的演奏者"** ——
//   它产生的事件与手指产生的事件**格式完全相同**
//   ⇒ ⭐ **零新增音频通路、零新增合规风险**。
//   ⚠️ 反例（⛔ 不要走的路）：自己再写一套振荡器 + 混音 ⇒ 那会
//      ① 新增一条音频通路（合规上要重新论证）② 与主链的采样对齐要另外做。
//
// ── ⭐ 怎么保证"32 音全响时仍有声"（§2.2 的冲突）──────────────────────────
//   `note_manager` 的专用池是按 **`axis_id`** 选的（读源码核实）：
//       `pool_mask[pg] = (cur_axis >= RESERVED_AXIS) ? (pg >= NORMAL_N) : (pg < NORMAL_N)`
//   ⇒ ⭐ 只要本模块发 **`axis_id = 4'hE`（= `RESERVED_AXIS_BASE` 默认值 14）**，
//      事件就**自动落到高索引的专用 voice**，⛔ 不参与普通抢占。
//   ⚠️ 因此**必须同时**把 `note_manager` 的 `RESERVED_N` 设成 ≥1（`top.v` 里现为 0）。
//      ⇒ ⭐ 两者要**成对改**，⛔ 只改一边会静默失效（事件仍进普通池 ⇒ 会被抢掉）。
//      📌 本模块给出 `cfg_warn_o` 做**可观测的自检**（`K-106` 风格：⛔ 不静默）。
//
// ── 为什么"click 包络"要单独做（⛔ 不是复用 `envelope_bank`）──────────────
//   `adsr` 衰减到 sustain 就**停住**且要 ~197 ms（见 `perc_env_bank.v` 头部推算）
//   ⇒ ⭐ 用 `perc_env_bank`（一击到底、~20 ms、衰到 0 自动结束）。
//   ⚠️ 本模块**只负责发事件**，⛔ 不自己产生包络 ——
//      包络由 `note_manager` 那条链上的 `perc_env_bank` 提供。
//      ⇒ 若要"click 用打击包络"，需要 `note_manager` 能按 `axis_id` 选包络类型；
//         ⚠️ **本周先不做**（那要改队友的链），先让 click 走**现有 ADSR** 出声，
//         ⭐ 听感验证放到上板时再定（`T33` 的判据是"**能听到拍子**"）。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`）· ⭐ 组合逻辑用 `assign`（`L67`）
//   · ⭐ **单周期脉冲必须"边沿时刻断言"**（冻结表 §〇 约定 4）
//   · ⭐ 单时钟域、⛔ 不派生时钟；`tick` 只是**使能**性质的事件输入
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module metronome #(
    parameter integer AXIS_W      = 4,
    parameter integer PHASE_W     = 32,
    parameter integer VEL_W       = 8,
    // ⭐ 专用 axis_id（`note_manager.RESERVED_AXIS_BASE` 的默认值 = 14 = 4'hE）
    parameter integer AXIS_ID     = 14,
    // ⭐ 专用 voice 数（⚠️ **必须与 `note_manager.RESERVED_N` 一致**，否则自检告警）
    parameter integer RESERVED_N  = 5,
    // ── 音高（`phase_inc = round(f × 2^32 / f_s)`，`f_s = 50 MHz / 1024`）────
    //
    //   🔴🔴 **2026-09-26 上板实测修复：⭐ 原来这两个常量【小了 1000 倍】**
    //
    //   ⭐ **上板症状**（⭐ 用户实测）：⭐ *"节拍器不太像节拍器，**太沉闷了**，
    //      我还以为是**噪音**"* + *"**音色比较沉**"*。
    //
    //   🔴 **根因：⭐ 常量与注释不符（⭐ 差了 1000 倍）**
    //      ⭐ 注释写的是 `1760 Hz → inc = 151 183`，⭐ **但那个算式是错的**：
    //      ```
    //        正确: inc = f × 2^32 / f_s = 1760 × 2^32 / 48828.125 ≈ 154 800 000
    //        🔴 原值 151 183 ⇒ 反算 f = 151 183 × 48828.125 / 2^32 ≈ **1.7 Hz**
    //      ```
    //      ⇒ 🔴 **实际只有 1.7 Hz / 0.86 Hz —— 是【次声波】！**
    //      ⚠️ 所以听起来是"极低频的噗噗声"，⭐ 完全不像节拍器。
    //      📌 **注意**：⭐ 那个 `151 183` 看起来像是**按 `f_s = 50 MHz` 算的**
    //         （`1760 × 2^32 / 50e6 ≈ 151 183`）—— ⚠️ **但相位累加器跑在
    //         `tick_audio`（音频帧率 48.828 kHz），⛔ 不是 50 MHz！**
    //         ⇒ 🔴 **这正是"用错了采样率"的经典错误**（⭐ `K-128` 同族：
    //            对"帧周期/帧率"的口径搞错）。
    //
    //   ⭐ **正确值**（⭐ 保持注释里的设计意图：强拍 1760 Hz、弱拍 880 Hz）：
    //      · 强拍 `1760 Hz` ⇒ `inc = round(1760 × 2^32 / 48828.125)` = **154 800 000**
    //      · 弱拍 ` 880 Hz` ⇒ `inc` = 强拍的一半 = **77 400 000**（⭐ 正好低八度）
    //   📌 **"强拍高八度"这个关系保留**（⭐ 文档 §2.1："强拍音高更高 / 更响"）。
    //
    //   ⚠️ **若上板仍觉得刺耳** ⇒ 把 `1760` 调低（⭐ 如 1320 Hz = `E6`）即可，⭐ 算式：
    //      `inc = f × 2^32 / 48828.125`（⭐ 用 48828.125，⛔ 不是 50e6）。
    parameter [PHASE_W-1:0] INC_ACCENT = 32'd154800000,   // ⭐ 1760 Hz
    parameter [PHASE_W-1:0] INC_NORMAL = 32'd77400000,    // ⭐  880 Hz（低八度）
    // ── 力度 ────────────────────────────────────────────────────────────────
    //   ⭐ 强拍更响（文档 §2.1："强拍音高更高 / 更响"）—— 两者都要，⛔ 不是只看音高
    //
    //   🔴🔴 **2026-09-26 上板实测调整：⭐ 整体调小**（⭐ 用户要求）
    //
    //   ⭐ **用户原话**：*"要求：减小节拍器的声音"*
    //   ⭐ **背景**：⭐ 上板实测 **节拍器明显比键盘响**，⚠️ 导致：
    //      · 🔴 **键盘被盖住** ⇒ ⭐ 用户*"声音太小了，有点难判断延迟与迟滞"*
    //      · 🔴 **听不出复音**（⭐ 用户：*"按多个音时不太听得出来是否是复音"*）
    //
    //   ⭐ **为什么节拍器偏响**（⭐ 有依据）：
    //      · ⭐ `adsr.v`：`peak_level = velocity << 8` ⇒ ⭐ 力度**线性**决定音量
    //      · ⭐ 节拍器原值 **220 / 140** ⇒ ⭐ 相对峰高 **0.863 / 0.549**
    //      · ⚠️ 而键盘的 `vel_upd` 会把它压到 **64**（⭐ 0.251）⇒ 🔴 **键盘反而更轻**
    //      ⇒ 🔴 **叠加后"节拍器压过键盘"**
    //
    //   ⭐ **改法**：⭐ 整体下调到 **150 / 90**（⭐ 保持"强拍更响"的比例）
    //      · ⭐ 强拍 **150/255 = 0.588**（⭐ 原 0.863，⭐ 降 3.3 dB）
    //      · ⭐ 弱拍 **90/255 = 0.353**（⭐ 原 0.549，⭐ 降 3.8 dB）
    //      ⇒ ⭐ **让键盘成为主角**。
    //   📌 **配套**：⭐ 本轮同时修了"键盘 `vel_upd` 被压到 64"（⭐ `note_manager.v`）
    //      ⇒ ⭐ **键盘升上去 + 节拍器降下来** ⇒ ⭐ 主次关系正确 ✅
    //   ⚠️ **若还偏响/偏轻** ⇒ ⭐ 只改这两个数，⛔ 不动逻辑。
    parameter [VEL_W-1:0]   VEL_ACCENT = 8'd150,
    parameter [VEL_W-1:0]   VEL_NORMAL = 8'd90,
    // 事件类型：0=note_on（与冻结表 §三 的 `kind` 编码一致）
    parameter [1:0]         EVT_KIND   = 2'd0
) (
    input  wire                 clk_i,
    input  wire                 rst_n_i,

    // ── 来自 `beat_gen`（⭐ 都是**单周期脉冲**，边沿时刻断言，约定 4）────────
    input  wire                 beat_i,        // ⭐ 四分音符拍点
    input  wire                 bar_start_i,   // ⭐ 小节起点（= 强拍）
    input  wire                 transport_i,   // ⭐ run 状态（0 ⇒ 不发事件）

    // ── 事件通路出口（→ `note_manager` 的 `note_*` 输入）───────────────────
    output reg                  evt_valid_o,   // ⭐ 单周期脉冲
    output wire [AXIS_W-1:0]    evt_axis_o,
    output wire [PHASE_W-1:0]   evt_phase_inc_o,
    output wire [VEL_W-1:0]     evt_velocity_o,
    output wire [1:0]           evt_kind_o,

    // ── ⭐ 可观测性（`K-106` 纪律：⛔ 不静默）──────────────────────────────
    output wire [15:0]          beat_cnt_o,    // 已发事件总数（饱和）
    output wire [15:0]          accent_cnt_o,  // 其中强拍数（饱和）
    // ⭐ 自检：`RESERVED_N == 0` ⇒ 专用池不存在 ⇒ ⭐ 事件会被普通抢占吃掉
    //    ⚠️ 这是**上板时最难查**的一类问题（"节拍器时有时无"）⇒ 必须可观测
    output wire                 cfg_warn_o
);

    // ── 常量 ────────────────────────────────────────────────────────────────
    // ⚠️ `K-91`：⛔ **不能对 `integer` 参数直接做位选/赋给窄向量** ——
    //    先经一个**显式定宽**的 `localparam` 落成向量再用。
    localparam [AXIS_W-1:0] AXIS_V = AXIS_ID[AXIS_W-1:0];

    // ⭐ 强拍判定：`bar_start` 与 `beat` **同拍**（`beat_gen` 已保证，见其 `L68` 论证）
    //    ⚠️ 用 `bar_start_i` 而不是自己数拍 —— ⭐ **必须与 `beat_gen` 同拍**
    //       （`Looper详细设计.md` §4.3 纪律 3：⛔ 不要自己再分频，否则会错拍）
    wire is_accent = beat_i & bar_start_i;      // 小节首拍 = 强拍
    wire is_normal = beat_i & ~bar_start_i;     // 其余拍 = 弱拍

    // ⭐ 只在实际"出声"时发事件：`transport_i` 为 0 ⇒ 停 ⇒ 一个都不发
    wire fire_accent = beat_i & bar_start_i & transport_i;
    wire fire_normal = beat_i & ~bar_start_i & transport_i;
    wire fire        = fire_accent | fire_normal;

    // ── 事件字段：⭐⭐ **必须与 `evt_valid_o` 同拍锁存** ──────────────────────
    //   🔴 这里踩过一个**真 bug**（2026-09-22，实测抓到 —— 属 `TROUBLESHOOTING 77 号` 同族）：
    //      第一版把 `valid` 做成寄存器（`evt_valid_o <= fire`），
    //      而字段是**组合**的（`is_accent` 直接跟 `beat_i` 走）
    //      ⇒ ⭐ **`valid` 比数据晚一拍**：消费者在 `valid=1` 那一拍读到的
    //        `phase_inc` 已经是"下一拍（弱拍）"的值
    //      ⇒ 🔴 **强拍永远发不出去**（永远响弱拍音）。
    //      ⚠️ 最阴的是：**计数却是对的**（`accent_cnt` 数到了 2）
    //        ⇒ 现象是"**计数说发了强拍，声音却是弱拍**"，⭐ 极难查。
    //   ⭐ 修法：**把字段在同一拍锁存**（与 `valid` 同源、同拍）
    //      ⇒ 即 `TROUBLESHOOTING 77 号` 的纪律：
    //        ⭐ **"脉冲"与"脉冲携带的数据"必须同拍锁存**。
    //   ⚠️ 代价：32+8 bit 寄存器（约 40 FF，可忽略）。
    reg [PHASE_W-1:0] evt_inc_r;
    reg [VEL_W-1:0]   evt_vel_r;

    assign evt_axis_o        = AXIS_V;      // ⭐ 常量 ⇒ 无需寄存
    assign evt_kind_o        = EVT_KIND;    // ⭐ 常量 ⇒ 无需寄存
    assign evt_phase_inc_o   = evt_inc_r;   // ⭐ 寄存后（与 valid 严格同拍）
    assign evt_velocity_o    = evt_vel_r;   // ⭐ 寄存后（与 valid 严格同拍）

    // ── 计数（⭐ 饱和，⛔ 不回绕 —— `K-106` 纪律）────────────────────────────
    reg [15:0] beat_cnt_r;
    reg [15:0] accent_cnt_r;

    assign beat_cnt_o   = beat_cnt_r;
    assign accent_cnt_o = accent_cnt_r;
    assign cfg_warn_o   = (RESERVED_N < 1);

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            evt_valid_o  <= 1'b0;
            evt_inc_r    <= {PHASE_W{1'b0}};
            evt_vel_r    <= {VEL_W{1'b0}};
            beat_cnt_r   <= 16'd0;
            accent_cnt_r <= 16'd0;
        end else begin
            // ⭐ 默认：单周期脉冲"本拍来、下拍走" ⇒ 严格一拍宽
            evt_valid_o <= fire;
            // ⭐⭐ 字段与 `valid` **同一拍**锁存 ⇒ 消费者读到的一定是匹配的数据
            //    ⚠️ 用 `is_accent`（含 `beat_i` 那一拍的值）⇒ 与 `fire` 同源
            evt_inc_r   <= is_accent ? INC_ACCENT : INC_NORMAL;
            evt_vel_r   <= is_accent ? VEL_ACCENT : VEL_NORMAL;

            // ⭐ 计数饱和（⛔ 不回绕：回绕会把"发了 65536 个"显示成"0 个"）
            if (fire && (beat_cnt_r != 16'hFFFF))
                beat_cnt_r <= beat_cnt_r + 16'd1;
            if (fire_accent && (accent_cnt_r != 16'hFFFF))
                accent_cnt_r <= accent_cnt_r + 16'd1;
        end
    end

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    initial begin
        // 🔴 下面两条都会**静默失效**，且现象极难定位
        if (RESERVED_N < 1)
            $display("WARNING [metronome] RESERVED_N=%0d < 1 => note_manager 没有专用 voice，事件会被普通抢占吃掉（32 音全响时听不到节拍器）",
                     RESERVED_N);
        if (INC_ACCENT == INC_NORMAL)
            $display("WARNING [metronome] INC_ACCENT == INC_NORMAL => 强拍与弱拍音高相同（听不出小节起点）");
    end

endmodule

`default_nettype wire
