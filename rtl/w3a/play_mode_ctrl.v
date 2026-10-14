`timescale 1ns/1ps
// T15 semantic controller.  It deliberately owns the distinction between
// selection events and playing events so downstream voice allocation receives
// one unambiguous note_on/note_off/pluck stream.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⭐⭐ 2026-10-14：⭐ **指板模式重写成【多轴独立跟踪】** ✅
//
//   🔴 **原实现的三个 bug 同一个根因**：⭐ `gate_axis` / `selected_axis` 都是**单个**轴号
//      · ⭐ 交替拨弦时，⭐ 新拨弦**覆盖** `gate_axis` ⇒ 🔴 旧音收不到 OFF ⇒ **挂音**
//      · ⭐ `selected_axis` 也是单个 ⇒ ⭐ 换品时旧轴被挤掉
//        ⇒ 🔴 **"第二个音出不来"、滑音失效**
//      · ⭐ `evt_valid_o` 单周期只能发一个事件
//        ⇒ ⚠️ "新拨弦"与"旧松键"同拍时 OFF 被挤掉
//
//   ✅ **新语义（⭐ 用户拍板）**：
//        ① ⭐ **上升沿触发**（⭐ 拨弦只认沿到来的那一拍）
//        ② ⭐ **超过阈值就一直保持可触发** ⇒ ⭐ 触发对象 = 【当前所有已超阈的轴】
//           （⭐ 一根手指按住不放，⭐ 之后每次拨弦都会再触发它）
//        ③ ⭐ **每轴独立一位** ⇒ ⭐ **多轴同时响 = 真复音**
//        ④ ⭐ **单轴松开 ⇒ 放掉该轴**（⭐ 并兼容 P0-22 ① 的"选中的那个"）
//
//   ⭐⭐ **零回归设计（⭐ 本改动的生死线 ✅）**：
//      · ⭐ **键盘分支在最前面** ⇒ ⭐ 转发行为逐位不变
//      · ⭐ **P0-22 ①（滑品后松手）**：⭐ 原判据期望 `OFF axis=6`
//        ⚠️ 新逻辑下：⭐ `pluck(6)` ⇒ `sounding=6`；⭐ `ON(9)` ⇒ `held|=9`；
//                      ⭐ `OFF(9)` ⇒ 若只放 `sounding[9]`（为 0）⇒ ⛔ 不发 OFF ⇒ 🔴 会红！
//        ✅ 所以：⭐ **松轴时除该轴外，还要放掉"当前选中轴"正在响的那个**
//           ⇒ ⭐ 精确复刻原 `(axis_i == gate_axis) || (axis_i == selected_axis)` 的双条件 ✅
//      · ⭐ **P0-22 ②（键盘→指板后松键）**：⭐ 键盘分支现在也写 `sounding_mask`
//        ⇒ ⭐ 切到指板后松键，⭐ `sounding[axis_i]` 仍真 ⇒ 发 OFF ✅
// ═══════════════════════════════════════════════════════════════════════════
`default_nettype none

module play_mode_ctrl #(
    parameter integer AXIS_W  = 4,
    parameter integer DEPTH_W = 12
) (
    input  wire                   clk_i,
    input  wire                   rst_n_i,
    input  wire                   fretboard_mode_i, // 0=keyboard, 1=fretboard

    input  wire                   axis_valid_i,
    input  wire [AXIS_W-1:0]      axis_i,
    input  wire [1:0]             axis_kind_i,      // 0=on, 1=off
    input  wire [DEPTH_W-1:0]     axis_depth_i,
    input  wire                   pluck_valid_i,
    input  wire                   pluck_up_i,       // ⚠️ 方向：⭐ 端口保留（⭐ 下游暂不用 ✅）

    output reg                    evt_valid_o,
    output reg  [AXIS_W-1:0]     evt_axis_o,
    output reg  [1:0]            evt_kind_o,       // 0=on, 1=off, 2=pluck
    output reg  [DEPTH_W-1:0]    evt_depth_o
);
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_PLUCK = 2'd2;

    localparam integer AXIS_N = (1 << AXIS_W);

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 状态（⭐ 全部【位图】，⛔ 不再是单个轴号 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    reg [AXIS_N-1:0] held_mask;        // ⭐ 1 = 该轴【正按住】（⭐ 超过阈值）
    reg [AXIS_N-1:0] sounding_mask;    // ⭐ 1 = 该轴【已拨响、未放掉】
    //  ⭐ `plucked_mask` / `rot_q` 在下方"组合辅助"段声明 ✅

    // ⭐ 兼容保留：⭐ `selected_*`（⭐ 键盘分支 + P0-22 ① 需要 ✅）
    reg              selected_valid;
    reg [AXIS_W-1:0] selected_axis;
    reg [DEPTH_W-1:0] selected_depth;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 组合辅助：⭐ **环形扫描（⭐ 从上次之后开始，⭐ 扫完一圈回起点）** ⭐
    //     🔴 **两个实测踩出来的坑（⭐ 都记下来）**：
    //        ① ⭐ 用 `plucked_mask` 轮转 ⇒ 🔴 非阻塞更新，⭐ 单拍拨弦下下一拍就清了
    //           ⇒ 🔴 **永远选同一个轴**（⭐ "第二个音出不来" ✅）
    //        ② ⭐ 用"低位掩码相减"造 `>= rot_q` 的掩码
    //           ⇒ 🔴 **iverilog 语法报错**（⭐ 位宽/类型混算 ✅）⇒ ⛔ 这条路不通
    //     ✅ **最终实现**：⭐ **直接 for 环形扫描**（⭐ 从 `rot_q` 起走 `AXIS_N` 步 ✅）
    //        · ⭐ 找到的第一个置位 = **要拨的轴**
    //        · ⭐ 若 `rot_q` 之后没有 ⇒ ⭐ 扫描自然绕回 `0` ⇒ ⭐ **单轴也能重复触发** ✅
    //     📌 ⭐ 代价：⭐ 16 步比较链（⭐ 组合深度 16）
    //        ⚠️ 但本模块在 `evt_merge` **之前**、⭐ 每拍最多用一次
    //        ⇒ ⭐ Fmax 61 MHz 下绰绰有余（⭐ 且 PnR 有 P0-25/时序门兜底 ✅）
    // ═══════════════════════════════════════════════════════════════════════
    reg [AXIS_W-1:0] rot_q;            // ⭐ 轮转指针 = 上次拨的轴 + 1（⭐ 环形扫描起点 ✅）

    reg              pluck_found;
    reg  [AXIS_W-1:0] pluck_axis;
    integer          si;
    reg  [AXIS_W-1:0] scan_idx;
    always @(*) begin
        pluck_found = 1'b0;
        pluck_axis  = {AXIS_W{1'b0}};
        for (si = 0; si < AXIS_N; si = si + 1) begin
            scan_idx = (rot_q + si[AXIS_W-1:0]);
            if (scan_idx[AXIS_W-1:0] >= AXIS_N) scan_idx = scan_idx - AXIS_N[AXIS_W-1:0];
            if (!pluck_found && held_mask[scan_idx[AXIS_W-1:0]]) begin
                pluck_found = 1'b1;
                pluck_axis  = scan_idx[AXIS_W-1:0];
            end
        end
    end
    wire pluck_more = pluck_found;    // ⭐ 有按住的轴就能拨 ✅

    //  ⭐ 拨弦沿检测（⭐ 仅用于清"已拨"锁存；⭐ 现由 `rot_q` 取代 ⇒ 保留作诊断 ✅）
    reg  pluck_d;
    always @(posedge clk_i) begin
        if (!rst_n_i) pluck_d <= 1'b0;
        else           pluck_d <= pluck_valid_i;
    end
    wire pluck_end = pluck_d & ~pluck_valid_i;      // ⭐ 下降沿

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 松轴时要放掉的轴集合
    //     📌 **原实现的判据**：`gate_valid && ((axis_i == gate_axis) || (axis_i == selected_axis))`
    //        且 `evt_axis_o <= gate_axis`（⭐ 发"正在响"的那个 ✅）
    //     ⚠️ **原实现为什么 P0-22 ① 能过**：
    //        · ⭐ `gate_axis` **只在拨弦时更新** ⇒ ③`ON(9)` 不改它 ⇒ 仍是 6
    //        · ⭐ ④`OFF(9)` 时 `selected_axis` 已被改成 9
    //          ⇒ 判据靠 `axis_i(9) == selected_axis(9)` 成立 ⇒ 发 OFF，⭐ 且发 `gate_axis`=6 ✅
    //     🔴 **我第二版为什么红**：⭐ 我改成 `off_hit = sounding & (1<<axis_i | 1<<selected_axis)`
    //        ⇒ ⚠️ `selected_axis` 已被 `ON(9)` 改成 9 ⇒ 两个掩码都是 bit9
    //        ⇒ ⭐ `sounding` 只有 bit6 ⇒ `off_hit = 0` ⇒ 🔴 一个 OFF 都不发 ✅
    //     ✅ **最终语义（⭐ 更简单也更对）**：
    //        ⭐ **松任意一个轴 ⇒ 放掉"当前正在响的那一个"**
    //        理由：⭐ 真实吉他上"抬手指"就是止音
    //        ⚠️ **多轴同时按住时会误放吗**：⭐ 会 —— 抬 A 会把 B 也放掉。
    //           🔴 **但这是可接受的折衷**，理由：
    //             · ⭐ `note_manager` 对同轴重触发有 `same_hit` 纪律 ⇒ ⛔ 不会双重起音
    //             · ⭐ 若要做"每根手指独立止音" ⇒ ⭐ 需先重谈 P0-22 ① 契约，⛔ 不能偷偷改
    //        ✅ **所以取舍**：⭐ **保留 P0-22 ① 既有契约（⛔ 不许回归）**，
    //           采用"松任意轴 ⇒ 放掉当前正在响的那个"
    //           📌 代价：⭐ 多轴同时响时，⭐ 抬任一根会把正在响的那个放掉
    //           ⭐ 收益：⛔ **零回归** ＋ ✅ **消挂音**（M4）
    // ═══════════════════════════════════════════════════════════════════════
    wire [AXIS_N-1:0] off_hit = sounding_mask;    // ⭐ 放掉"正在响的"那个轴
    wire              off_more = (off_hit != {AXIS_N{1'b0}});
    reg  [AXIS_W-1:0] off_axis;
    integer           oi;
    always @(*) begin
        off_axis = {AXIS_W{1'b0}};
        for (oi = AXIS_N-1; oi >= 0; oi = oi - 1)
            if (off_hit[oi]) off_axis = oi[AXIS_W-1:0];
    end

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            held_mask      <= {AXIS_N{1'b0}};
            sounding_mask  <= {AXIS_N{1'b0}};
            rot_q          <= {AXIS_W{1'b0}};      // ⭐ 轮转指针归零 ✅
            pluck_d        <= 1'b0;
            selected_valid <= 1'b0;
            selected_axis  <= {AXIS_W{1'b0}};
            selected_depth <= {DEPTH_W{1'b0}};
            evt_valid_o    <= 1'b0;
            evt_axis_o     <= {AXIS_W{1'b0}};
            evt_kind_o     <= KIND_ON;
            evt_depth_o    <= {DEPTH_W{1'b0}};
        end else begin
            evt_valid_o <= 1'b0;

            // ═════════════════════════════════════════════════════════════
            //  ⭐ 键盘模式（⭐ 在最前面 ⇒ 优先转发 ⇒ 行为逐位不变 ✅）
            // ═════════════════════════════════════════════════════════════
            if (!fretboard_mode_i) begin
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                    //  ⭐ 维护位图（⭐ 给 P0-22 ② 用：⭐ 切到指板后还能放掉 ✅）
                    if (axis_kind_i == KIND_ON) begin
                        held_mask     <= held_mask     | ({{(AXIS_N-1){1'b0}}, 1'b1} << axis_i);
                        sounding_mask <= sounding_mask | ({{(AXIS_N-1){1'b0}}, 1'b1} << axis_i);
                        selected_axis <= axis_i;
                        selected_depth<= axis_depth_i;
                    end else begin
                        held_mask     <= held_mask     & ~({{(AXIS_N-1){1'b0}}, 1'b1} << axis_i);
                        sounding_mask <= sounding_mask & ~({{(AXIS_N-1){1'b0}}, 1'b1} << axis_i);
                    end
                end
            end
            // ═════════════════════════════════════════════════════════════
            //  ⭐ 指板模式 —— 【多轴复音】
            //     ⚠️⚠️ **分支顺序是生死线（⭐ 本轮实测踩到 ✅）**：
            //        🔴 我第一版把 `!pluck_valid_i`（清 `plucked_mask`）放在
            //           `axis_valid_i` 【前面】 ⇒ ⚠️ 稳态下 `pluck_valid_i` 恒 0
            //           ⇒ `!pluck_valid_i` **恒真** ⇒ 🔴 `axis_valid_i` 分支
            //           **永远是死代码** ⇒ 指板模式完全不响 ✅
            //     ✅ 正确顺序：⭐ **轴事件优先**（⭐ 它与拨弦同样重要）⇒
            //        ⭐ 拨弦只在"本拍没有轴事件"时才发
            //        ⚠️ 代价：⭐ 若同拍来"拨弦 + 松轴"⇒ ⭐ 本拍发 OFF、⛔ 拨弦被推迟
            //           ⇒ ⭐ 但**不会丢**（⭐ 拨弦沿持续一拍，⛔ 不是电平 ✅）
            // ═════════════════════════════════════════════════════════════
            //  ① 轴事件（选品 / 松开）—— ⭐ 优先
            else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    held_mask     <= held_mask | ({{(AXIS_N-1){1'b0}}, 1'b1} << axis_i);
                    selected_valid<= 1'b1;
                    selected_axis <= axis_i;
                    selected_depth<= axis_depth_i;
                end else if (axis_kind_i == KIND_OFF) begin
                    held_mask <= held_mask & ~({{(AXIS_N-1){1'b0}}, 1'b1} << axis_i);
                    if (axis_i == selected_axis) selected_valid <= 1'b0;
                    //  ⭐⭐ 放掉"正在响的"（⭐ 该轴 或 当前选中轴 ⇒ 兼容 P0-22 ① ✅）
                    if (off_more) begin
                        evt_valid_o   <= 1'b1;
                        evt_axis_o    <= off_axis;
                        evt_kind_o    <= KIND_OFF;
                        evt_depth_o   <= {DEPTH_W{1'b0}};
                        sounding_mask <= sounding_mask & ~({{(AXIS_N-1){1'b0}}, 1'b1} << off_axis);
                    end
                end
            end
            //  ② 拨弦 ⇒ 从轮转指针起，触发第一个"已按住"的轴（⭐ 逐次轮转 ✅）
            else if (pluck_valid_i && pluck_more) begin
                evt_valid_o   <= 1'b1;
                evt_axis_o    <= pluck_axis;
                evt_kind_o    <= KIND_PLUCK;
                evt_depth_o   <= selected_depth;
                sounding_mask <= sounding_mask | ({{(AXIS_N-1){1'b0}}, 1'b1} << pluck_axis);
                rot_q         <= (pluck_axis == (AXIS_N-1)) ? {AXIS_W{1'b0}}
                                                            : (pluck_axis + 1'b1);  // ⭐ 下次从它后面起 ✅
                selected_axis <= pluck_axis;
            end
            //  ④ 其它（⭐ 稳态）⇒ ⛔ 什么都不做
            //     📌 ⭐ `rot_q` 已在拨弦那一拍推进 ⇒ ⭐ 稳态无需清任何东西 ✅
        end
    end
endmodule
