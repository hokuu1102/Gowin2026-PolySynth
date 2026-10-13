`timescale 1ns/1ps
// ============================================================================
//  slide_ramp.v -- 滑音斜坡（portamento）：把"跳"变成"滑"
//
//  要解决的问题：
//    现在滑音是【一次跳变】-- `pitch_upd_value_i = am_inc_b`（B 的音高）
//    一拍就把 A 的音高设成 B，听觉上是"音高突然跳过去"，不是滑音。
//
//  做法（一阶指数逼近 / one-pole portamento）：
//    每个音频帧把当前值朝目标推进一步：
//        cur <= cur + ((target - cur) >>> SHIFT)
//    误差按 (1 - 2^-SHIFT) 衰减 ⇒ 起始快、尾段慢，**在相位增量上是指数**，
//    而相位增量 ∝ 频率 ⇒ **音高近似【线性】滑动** ⇒ 这才是音乐上自然的滑音。
//    （线性插值相位增量反而会听起来"先慢后快/发飘"，因为人耳听的是对数频率。）
//
//  为什么它便宜：
//    · 全部是"移位 + 加减 + 比较"，**⛔ 不用乘法器**
//    · 只有【一份】状态（同一时刻只有一个音在滑）⇒ ~70 FF
//    · Register 目前只用了 31%（18,518 / 60,780）⇒ FF 极宽裕
//    ⚠️ 对比：之前两次失败的那 +287 LUT 其实是【第二查表口读两套表 + mode mux】，
//       ⛔ 不是斜坡本身。现在第二口已经只读 `fb_inc`（2 个 16 选 1）了。
//
//  语义（依据 review/滑音触发规格-20261011.md 用户裁定）：
//    · 起始值 = **A 的音高**（`start_i`，来自 `axis_map` 主口）
//    · 目标值 = **B 的音高**（`target_i`，来自第二口 `am_inc_b`）
//    · **中途停在两轴之间 ⇒ 停在当前位置** ✅ 天然支持：
//        手指退回 ⇒ 再来一次 trig ⇒ 目标改写，**从当前值接着滑**（不会跳回去）
//    · 到达判据：|target - cur| <= EPS ⇒ 直接落到目标并结束
//        ⚠️ 指数逼近**永远到不了**，所以必须有这一步"收尾吸附"，否则会一直微分抖
//
//  判据（见 tb/w3a/tb_slide_ramp.sv）：每条都必须能失败
//    1) 不滑时输出 = 直通的目标（行为与改动前一致）
//    2) 一次 trig ⇒ 输出【逐步】靠近目标，且【每一帧只走一小步】（⛔ 不是一步到位）
//    3) 单调：全程朝目标方向走，不回头
//    4) 起始值 = start_i（不是从 0 开始）
//    5) 到达后 active 落下，且最终值 == 目标（精确落位）
//    6) 中途改目标 ⇒ 从【当前值】继续（不跳回起点）
//    7) 步数在预期量级（可用来标定"50 ms"）
// ============================================================================
`default_nettype none

module slide_ramp #(
    // 每步衰减：误差按 (1 - 2^-SHIFT) 衰减。
    //  ⭐ **这一个参数就是"滑音时长"的旋钮**（帧周期固定 500 µs）：
    //     SHIFT=3 ⇒ 实测 ~42 步 ≈ 21 ms
    //     SHIFT=4 ⇒ 实测 ~81 步 ≈ 40 ms   ← 交付默认（最接近用户要的 50 ms）
    //     SHIFT=5 ⇒ 约 165 步 ≈ 82 ms
    //  ⚠️ 只改这一个数就能调时长，⛔ 不用动任何结构。
    parameter integer SHIFT = 4,
    // 收尾吸附阈值：|target-cur| <= EPS 就直接落位
    parameter [31:0]  EPS   = 32'd4096
) (
    input  wire        clk,
    input  wire        rst_n,

    // 每帧一个脉冲：斜坡的推进节拍（接 `axis_snapshot.snap_valid_o`）
    input  wire        tick_i,

    // 滑音触发（接 `event_extract.slide_valid_o`）+ 起点/目标
    input  wire        trig_i,
    input  wire [31:0] start_i,     // A 的音高（轴位→表值，主口）
    input  wire [31:0] target_i,    // B 的音高（第二口）

    output reg         active_o,    // 正在滑 ⇒ 上层据此【每帧】发 pitch_upd
    output reg  [31:0] value_o,     // 当前音高（滑的过程中是中间值）
    output reg  [15:0] steps_o      // 本次滑音走了多少步（诊断/标定用）
);

    reg [31:0] cur_r;
    reg [31:0] tgt_r;

    // 有符号差：目标 - 当前
    wire signed [32:0] diff_w = $signed({tgt_r[31], tgt_r}) - $signed({cur_r[31], cur_r});
    wire [32:0]        adiff  = diff_w[32] ? (~diff_w + 33'd1) : diff_w;   // 绝对值
    wire               near_w = (adiff <= {1'b0, EPS});

    // 移位步长：diff >>> SHIFT（算术右移，保留符号）
    wire signed [32:0] step_w  = diff_w >>> SHIFT;
    //  ⚠️ 步长下界：diff 很大时没问题；很小时移位会变 0 ⇒ 靠 near_w 吸附兜住
    //     若不加兜底，|diff| 在 (EPS, EPS<<SHIFT) 之间会"每步走 0"⇒ 永久停住。
    wire signed [32:0] step_min = (diff_w > 0) ? 33'sd1 : -33'sd1;
    wire signed [32:0] step_use = (step_w == 0) ? step_min : step_w;

    wire [32:0] next_w = {cur_r[31], cur_r} + step_use;

    always @(posedge clk) begin
        if (!rst_n) begin
            cur_r    <= 32'd0;
            tgt_r    <= 32'd0;
            active_o <= 1'b0;
            value_o  <= 32'd0;
            steps_o  <= 16'd0;
        end else if (trig_i) begin
            //  ⭐ 目标总是更新
            tgt_r <= target_i;
            //  🔴 **关键**（实测踩到，判据 5b）：**只有【首次起滑】才用 `start_i` 复位当前值**
            //     若每次 trig 都复位 ⇒ ⚠️ 手指中途退回时音高会**跳回起点**再滑
            //     ⇒ 🔴 违反用户规格"中途停在两轴之间 ⇒ **停在当前位置**"（见规格 §七-②）
            //  ✅ 正解：**已经在滑**的时候，trig 只改目标 ⇒ **从当前值接着滑** ✅
            if (!active_o) begin
                cur_r    <= start_i;
                value_o  <= start_i;      // 本拍先发起点 ⇒ 从 A 的音高开始，⛔ 不跳
                steps_o  <= 16'd0;
            end
            active_o <= 1'b1;
        end else if (active_o && tick_i) begin
            if (near_w) begin
                // 收尾吸附：精确落到目标，结束
                cur_r    <= tgt_r;
                value_o  <= tgt_r;
                active_o <= 1'b0;
            end else begin
                cur_r    <= next_w[31:0];
                value_o  <= next_w[31:0];
                steps_o  <= steps_o + 16'd1;
            end
        end
    end

    initial begin
        if (SHIFT < 1)
            $display("ERROR [slide_ramp] SHIFT=%0d must be >= 1", SHIFT);
        else
            $display("NOTE [slide_ramp] PARAM_OK=1 (SHIFT=%0d EPS=%0d)", SHIFT, EPS);
    end

endmodule

`default_nettype wire
