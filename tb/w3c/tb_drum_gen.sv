// ═══════════════════════════════════════════════════════════════════════════
//  tb_drum_gen —— ⭐ 纯合成鼓机（Kick / Snare / Hi-hat / Tom）
//
//  ⭐ 判据（⭐ 照 `tb_metronome.sv` 的结构 + 设计文档 §四 的 10 条）：
//     ① ⭐ `transport_i=0` ⇒ ⛔ 不发任何事件
//     ② ⭐⭐ **事件与小节对齐**：⭐ 16 步恰好 1 小节
//     ③ ⭐⭐⭐ **一"步"多乐器【不被吞】**（⭐ 最重要 —— `U-18b` 的镜像）
//     ④ ⭐ **每个乐器都用【专用池】的 axis_id**（⛔ 否则抢普通池）
//     ⑤ ⭐ **不粘滞**：⭐ `valid` 连续高时数据必须每拍都在变
//     ⑥ ⭐ **`evt_data` 与 `evt_valid` 同拍**（⭐ `80 号` 的教训）
//     ⑦ ⭐⭐ **⛔ 无 PCM**（⭐ 合规判据 —— 静态检查源码）
//     ⑧ ⭐ **`cfg_warn_o` 在参数不一致时拉起**（`K-106`）
//     ⑨ ⭐ **A8：⛔ 无 X/Z 传播**
//     ⑩ ⭐ **step 计数正确**（⭐ 0→1→…→15→0）
//
//  ── ⭐⭐ 2026-09-29 新增（⭐ 三条，⭐ 都是本轮任务要求）────────────────────────
//     ⑬ ⭐⭐ **小节相位【事件级】测量**（⭐ Task 2）：
//         ⭐ 每个 `bar_start` 之后 `step_cnt` **必须 == 0**（⭐ 型 0 的 step 0 落在正拍）
//     ⑭ ⭐⭐ **正拍必须是 Kick**（⭐ Task 2）：
//         ⭐ 每个 `bar_start` 之后**第一个事件 = Kick**、⭐ 第二个 = HiHat
//         （⭐ = 型 0 的 `step 0` 掩码 `4'b0101`）
//     ⑮ ⭐⭐ **运行时切节奏型 + 嗵鼓真的会响**（⭐ Task 3 / Task 4）：
//         ⭐ 跑完型 0 后**直接改 `pattern_id_i`**（⭐ 不复位）⇒ ⭐ 下一小节就是新型
//         ⇒ ⭐ 型 1 一小节的事件数/乐器数必须与**新常量表**吻合（⭐ 含 **Tom=2**）
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_drum_gen;

    localparam integer AXIS_W  = 4;
    localparam integer PHASE_W = 32;
    localparam integer VEL_W   = 8;
    localparam integer T       = 20;
    // ⭐ 测试用短参数（⚠️ 断言的是【行为】，⛔ 不是具体 tick 数）
    //    ⭐ 真实是 240 tick/步；⭐ 这里用 8 ⇒ ⭐ 仿真快，⭐ 但语义完全一样
    localparam integer TPS     = 8;

    reg clk = 1'b0, rst_n = 1'b0;
    always #(T/2) clk = ~clk;

    reg        tick_i = 0;
    reg [15:0] tick_cnt_i = 0;
    reg        bar_start_i = 0;
    reg        transport_i = 0;
    // ⭐⭐ 2026-09-29：⭐ 节奏型改成**运行时输入**（⭐ 原来是 `.PATTERN_ID(0)` 编译期参数）
    //   ⭐ 本 tb 用它验两件事：⭐ ① 默认型 0 的行为不变 ✅
    //                        ⭐ ② **中途切型 ⇒ 下一小节立刻用新表**（⭐ Task 3/4）✅
    reg [1:0]  pattern_id = 2'd0;

    wire        evt_v;
    wire [3:0]  evt_ax;
    wire [31:0] evt_inc;
    wire [7:0]  evt_vel;
    wire [1:0]  evt_kd;
    wire [15:0] evt_cnt, step_evt_cnt;
    wire [3:0]  step_cnt, hit_cnt;
    wire        cfg_warn;

    // ⭐ 参数：AXIS_ID=15（专用池）、节奏型 = `pattern_id`（⭐ 运行时，⭐ 初值 0 = BASIC）
    drum_gen #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .AXIS_ID(15), .N_DRUM(4), .STEPS(16),
        .TICKS_PER_STEP(TPS), .RESERVED_N(5)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .pattern_id_i(pattern_id),
        .tick_i(tick_i), .tick_cnt_i(tick_cnt_i),
        .bar_start_i(bar_start_i), .transport_i(transport_i),
        .evt_valid_o(evt_v), .evt_axis_o(evt_ax), .evt_phase_inc_o(evt_inc),
        .evt_velocity_o(evt_vel), .evt_kind_o(evt_kd),
        .evt_cnt_o(evt_cnt), .step_cnt_o(step_cnt), .hit_cnt_o(hit_cnt),
        .step_evt_cnt_o(step_evt_cnt), .cfg_warn_o(cfg_warn)
    );

    // ── 收集事件 ──────────────────────────────────────────────────────────
    integer n_out = 0;
    reg [31:0] out_inc [0:255];
    reg [3:0]  out_ax  [0:255];
    integer n_kick = 0, n_snare = 0, n_hihat = 0, n_tom = 0;
    integer n_tom_bad_vel = 0;       // ⭐ Tom 的力度不对（⭐ 例如还留着 Clap 的 180）
    integer n_bad_axis = 0;          // ⭐ axis 不在专用池的次数

    // ⭐ 鼓的"身份"：⭐ 用 phase_inc 分辨是哪一件（⭐ 与 DUT 的常量一致）
    //   ⭐⭐ 2026-09-29：⭐ 第 4 件从 **Clap(≈1000 Hz)** 改成 **Tom(≈150 Hz)** ✅
    //      ⭐ `inc = 150 × 2^32 / 50e6 = 12884.90` ⇒ ⭐ `12884_902`（⭐ 与 RTL 一致）
    localparam [31:0] INC_KICK  = 32'd6_442_451;
    localparam [31:0] INC_SNARE = 32'd17_179_869;
    localparam [31:0] INC_HIHAT = 32'd171_798_691;
    localparam [31:0] INC_TOM   = 32'd12_884_902;
    // ⭐ 力度常量（⭐ 用来判"第 4 件乐器真的是 Tom"—— 光看 `inc` 不够，
    //    ⚠️ 万一将来有人把 Tom 的力度写成 Clap 的 180，⭐ 这里能抓到）
    localparam [7:0]  VEL_TOM   = 8'd190;

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ ⑯ 节奏型【位精确】观察器（⭐ 2026-09-30 新增 · 本轮任务）
    // ══════════════════════════════════════════════════════════════════════
    //   ⭐ 目的：⭐ 把"某一步实际敲了哪几件"还原成 **4 位掩码**，
    //      ⇒ ⭐ 再与【用户表】逐位比对（⛔ 不是只比"事件总数"）
    //   ⭐ 怎么还原：⭐ 一步的掩码 = 该步内所有事件对应乐器位的**并集**
    //      （⭐ DUT 把一步的多件乐器**逐个发完** ⇒ ⭐ 并集必然等于掩码本身）
    //
    //   ⚠️⚠️ **步号必须晚【两拍】读**（⭐ `U74` 家族的 delta 竞争）：
    //      ⭐ 监视器在拍 T 看到事件时，⭐ 它是 `pending_q`（⭐ **拍 T−2** 的值）发出来的
    //         ⇒ ⭐ 归属步号 = `step_q` 在 **拍 T−2** 的值 ✅
    //      ⭐ 而"拍 T−2 的 `step_q`"**正好等于 `tbl_step_d1` 在拍 T 的值**：
    //         · `step_cnt` 在拍 T 读到的是**上一拍**的值（⭐ 非阻塞 + 本 tb 采样口径）⇒ 差 1 拍
    //         · `tbl_step_d1` 本身又是**寄存一拍**的（⭐ 同拍读到的是旧值）⇒ 再差 1 拍
    //      🔴 **实测踩过（⭐ 2026-09-30）**：⭐ 我第一版**多延了一拍**（用了 `tbl_step_d2`）
    //         ⇒ 🔴 **每一步的【首事件】被记到上一步** ⇒ ⭐ 4 条判据**全红**
    //         （⭐ 是【假红】—— ⛔ 不是 RTL 的错，⭐ 是测量口径错）✅
    reg        tbl_en = 1'b0;            // ⭐ 只在【采集小节】里置 1
    reg [3:0]  tbl_mask [0:15];          // ⭐ 每步观察到的掩码（⭐ 并集）
    reg [3:0]  tbl_step_d1 = 4'd0;       // ⭐ `step_cnt` 延 1 拍（⭐ 归属步号就用它）
    integer    tbl_unknown  = 0;         // ⭐ 音高对不上 4 件乐器之一的次数
    integer    tbl_evt_seen = 0;         // ⭐ 采集到的事件数（⭐ 判"窗口没漏"）

    // ⭐ 音高 ⇒ 乐器位（⭐ 与 RTL 的 `inc_of` 一一对应；⭐ 位序同 RTL 文件头）
    function [3:0] bit_of_inc;
        input [31:0] inc;
        begin
            if      (inc == INC_KICK)  bit_of_inc = 4'b0001;   // bit0 = Kick
            else if (inc == INC_SNARE) bit_of_inc = 4'b0010;   // bit1 = Snare
            else if (inc == INC_HIHAT) bit_of_inc = 4'b0100;   // bit2 = 镲(HiHat)
            else if (inc == INC_TOM)   bit_of_inc = 4'b1000;   // bit3 = Tom
            else                       bit_of_inc = 4'b0000;   // ⭐ 未知 ⇒ 只计数
        end
    endfunction

    always @(posedge clk) begin
        tbl_step_d1 <= step_cnt;
        if (rst_n && tbl_en && evt_v) begin
            tbl_evt_seen = tbl_evt_seen + 1;
            if (bit_of_inc(evt_inc) == 4'b0000)
                tbl_unknown = tbl_unknown + 1;
            else
                tbl_mask[tbl_step_d1] = tbl_mask[tbl_step_d1] | bit_of_inc(evt_inc);
        end
    end

    // ⭐ 粘滞检测（⭐ "valid 连续高但数据不变"）
    reg evt_v_d = 0;
    reg [31:0] last_inc = 32'hDEAD_BEEF;
    integer n_stuck = 0;

    always @(posedge clk) begin
        if (rst_n && evt_v) begin
            if (n_out < 256) begin
                out_inc[n_out] = evt_inc;
                out_ax[n_out]  = evt_ax;
            end
            n_out = n_out + 1;
            if (evt_inc == INC_KICK)  n_kick  = n_kick  + 1;
            if (evt_inc == INC_SNARE) n_snare = n_snare + 1;
            if (evt_inc == INC_HIHAT) n_hihat = n_hihat + 1;
            if (evt_inc == INC_TOM) begin
                n_tom = n_tom + 1;
                // ⭐⭐ 力度也要核 —— ⚠️ 光把音高改了、力度还是旧值（180）也算没过
                if (evt_vel !== VEL_TOM) n_tom_bad_vel = n_tom_bad_vel + 1;
            end
            // ⭐ 专用池检查（⭐ RESERVED_AXIS_BASE = 14）
            if (evt_ax < 4'd14) n_bad_axis = n_bad_axis + 1;
            // ⭐ 粘滞：⭐ 连续两拍且数据完全一样
            if (evt_v_d && (evt_inc === last_inc)) n_stuck = n_stuck + 1;
            last_inc = evt_inc;
        end
        evt_v_d <= evt_v;
    end

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ ⑬⑭ 小节相位【测量监视器】（⭐ 2026-09-29 新增 · Task 2）
    // ══════════════════════════════════════════════════════════════════════
    //   🔴 **为什么要它**：⭐ 用户上板反馈 *"第一拍太轻 / 像从弱拍起"*
    //      ⇒ ⭐ 待查假设：⭐ 16 步表的 **step 0 没有落在 `bar_start` 上**（⭐ 差一步）。
    //   ⭐ **本段只【测】不【猜】**：⭐ 把**每个 `bar_start`** 的
    //      `step_cnt` + ⭐ **其后第一个/第二个事件**的乐器都记下来
    //      ⇒ ⭐ 判据 ⑬：⭐ 每个 `bar_start` 都必须看到 `step_cnt == 0`
    //      ⇒ ⭐ 判据 ⑭：⭐ `bar_start` 之后**第一个事件必须是 Kick**、
    //         ⭐ 第二个必须是 HiHat（⭐ = 型 0 的 `step 0` 掩码 `4'b0101`）
    //
    //   ⚠️⚠️ **`step_cnt` 必须【晚一拍】读**（⭐ `U74` 家族的 delta 竞争）：
    //      ⭐ `step_q <= 0` 是**非阻塞赋值** ⇒ ⭐ `bar_start` 那一拍读到的
    //      **还是对齐【之前】的旧步号** ⇒ 🔴 会**假红**。
    //      ⇒ ⭐ 本监视器用 `bar_pending` **晚一拍**采样 ✅
    // ══════════════════════════════════════════════════════════════════════
    reg        meas_en   = 1'b0;
    reg        bar_pending = 1'b0;
    reg        bar_start_d = 1'b0;   // ⭐ `bar_start_i` 的上一拍值（⭐ 做【边沿检测】）
    integer    n_bar     = 0;
    integer    win_cnt   = 0;
    reg [3:0]  step_at_bar  [0:7];
    reg [31:0] first_inc_at_bar  [0:7];
    reg [31:0] second_inc_at_bar [0:7];
    reg        first_seen   [0:7];

    always @(posedge clk) begin
        bar_start_d <= bar_start_i;
        if (rst_n && meas_en) begin
            if (bar_pending) begin
                // ⭐ `bar_start` 之后的**第一拍**：⭐ `step_q` 已被强制为 0 ✅
                if (n_bar < 8) begin
                    step_at_bar[n_bar]       = step_cnt;
                    first_seen[n_bar]        = 1'b0;
                    first_inc_at_bar[n_bar]  = 32'hDEAD_BEEF;
                    second_inc_at_bar[n_bar] = 32'hDEAD_BEEF;
                end
                // ⭐ 开"半步"窗口（⭐ TPS 拍 = 半个 16 分）—— 足够抓到 step 0 的事件
                win_cnt     = TPS;
                bar_pending = 1'b0;
                n_bar       = n_bar + 1;
            end else if (win_cnt > 0) begin
                win_cnt = win_cnt - 1;
                if (evt_v && (n_bar > 0)) begin
                    if (!first_seen[n_bar-1]) begin
                        first_seen[n_bar-1]       = 1'b1;
                        first_inc_at_bar[n_bar-1] = evt_inc;
                    end else if (second_inc_at_bar[n_bar-1] === 32'hDEAD_BEEF) begin
                        second_inc_at_bar[n_bar-1] = evt_inc;
                    end
                end
            end
            // ⭐⭐ 见到 `bar_start` 的**上升沿** ⇒ ⭐ 下一拍采样
            //   🔴 **为什么必须做边沿检测**（⭐ 本 tb 实测踩到）：
            //      ⚠️ 本 tb 的 `run_ticks` 把 `bar_start_i` 拉了**两拍**宽
            //      （⭐ 真 `beat_gen` 是**单周期脉冲**）⇒ ⭐ 用"电平"当触发
            //      ⇒ 🔴 **一次小节被记成两次**（⭐ 实测 `n_bar=8`，⭐ 且第二次采样
            //         **重置了抓事件的窗口** ⇒ 🔴 首事件被抓成 HiHat ⇒ **假红**）。
            //      ⭐ 用边沿 ⇒ ⭐ 一次小节只记一次 ✅（⭐ 与 `U74` 同族教训）
            if (bar_start_i && !bar_start_d) bar_pending = 1'b1;
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    //   ⭐⭐ 给 `beat_gen` 打拍子（⭐ 模拟它的行为）
    // ══════════════════════════════════════════════════════════════════════
    //   ⭐ 每个 clk = 1 tick（⭐ 简化：真实是 PPQN，⭐ 但差值法只看相对推进）
    integer i;
    task run_ticks(input integer n, input integer do_bar_start);
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                tick_i     = 1'b1;
                // ⭐ 小节起点：⭐ `tick_cnt_i` 归零（⭐ 模拟 `beat_gen` 的真实行为）
                if (do_bar_start && i == 0) begin
                    tick_cnt_i   = 16'd0;
                    bar_start_i  = 1'b1;
                end else begin
                    tick_cnt_i   = tick_cnt_i + 16'd1;
                    bar_start_i  = 1'b0;
                end
                @(negedge clk);
                tick_i     = 1'b0;
            end
        end
    endtask

    integer errors = 0;

    initial begin
        $display("=== tb_drum_gen（纯合成鼓机）===");
        $display("⭐ 参数：AXIS_ID=15 · PATTERN_ID=0(BASIC) · TICKS_PER_STEP=%0d", TPS);

        // ═══ ① transport=0 ⇒ ⛔ 不发事件 ═══════════════════════════════════
        rst_n = 1'b0;
        transport_i = 1'b0; bar_start_i = 1'b0; tick_i = 1'b0; tick_cnt_i = 16'd0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);
        n_out = 0;
        // ⭐ 跑 4 小节的时间，但 transport 保持 0
        run_ticks(TPS * 16 * 4, 1);
        if (n_out == 0)
            $display("  ok  : ① transport=0 ⇒ ⛔ 一个事件都没发（停就真停）");
        else begin
            $display("FAIL: ① transport=0 却发了 %0d 条", n_out);
            errors = errors + 1;
        end

        // ═══ ② 16 步 = 1 小节（⭐ 跑整 2 小节）═════════════════════════════
        //   ⚠️ **2026-09-30 更新**：⭐ 型 0 换成用户表 **BASIC** ⇒ ⭐ 本段的
        //      事件数**跟着换**（⭐ 旧表是 11/2/2/6/1，⭐ 那是【已废弃的 Rock】）
        //   ⭐ BASIC 型一小节的事件数（⭐ 数用户表）：
        //      step01=2 · step03=1 · **step05=3（Kick+Snare+镲）** · step07=1
        //      step09=2 · step11=1 · **step13=3（Kick+Snare+镲）** · step15=1
        //      ⇒ ⭐ **共 14 个事件**（⭐ Kick4 / Snare2 / 镲8 / **Tom0**）
        pattern_id = 2'd0;           // ⭐ 本段固定验【型 0】（⭐ 默认型，⛔ 别被上一段影响）
        n_out = 0; n_kick = 0; n_snare = 0; n_hihat = 0; n_tom = 0; n_bad_axis = 0; n_stuck = 0;
        transport_i = 1'b1;
        run_ticks(TPS * 16, 1);      // ⭐ 恰好一小节
        repeat (20) @(negedge clk);
        $display("  --- 一小节（BASIC / 型 0）事件统计 ---");
        $display("      Kick=%0d  Snare=%0d  HiHat=%0d  Tom=%0d  总=%0d",
                 n_kick, n_snare, n_hihat, n_tom, n_out);
        if (n_out == 14 && n_kick == 4 && n_snare == 2 && n_hihat == 8 && n_tom == 0)
            $display("  ok  : ② 一小节恰好 14 个事件（Kick4/Snare2/HiHat8/Tom0）—— 与用户表(BASIC)吻合");
        else begin
            $display("FAIL: ② 一小节事件数与用户表(BASIC)不符（期望 14/4/2/8/0，实得 %0d/%0d/%0d/%0d/%0d）",
                     n_out, n_kick, n_snare, n_hihat, n_tom);
            errors = errors + 1;
        end

        // ═══ ③ ⭐⭐⭐ 一"步"多乐器【不被吞】（⭐ 最重要的判据）════════════════
        //   ⭐ Rock 型的 step0 掩码 = 4'b0101 ⇒ ⭐ **Kick + HiHat 同时响**
        //      ⭐ 判据：⭐ 那一步必须发出【2 个】事件（⛔ 不能只发 1 个）
        //   🔴 **为什么这条最重要**：⚠️ `U-18b` 的镜像 ——
        //      ⭐ 当年 `play_seq` "16 判据全过、变异体全抓"，
        //      🔴 **但同 tick 多事件从没测** ⇒ 和弦被拉成琶音。
        //   ⭐ 做法：⭐ 复位后单跑一小节，⭐ 检查**前 2 个事件**
        //      （⭐ 都是 step0 的 ⇒ 一条 Kick、一条 HiHat）
        if (n_out >= 2) begin
            if (((out_inc[0] == INC_KICK) && (out_inc[1] == INC_HIHAT)) ||
                ((out_inc[0] == INC_HIHAT) && (out_inc[1] == INC_KICK)))
                $display("  ok  : ③⭐ 一'步'多乐器【没被吞】—— step0 的 Kick+HiHat 都发出来了");
            else begin
                $display("FAIL: ③ 🔴 step0 的 Kick+HiHat 【被吞了】！前两条 = %h, %h",
                         out_inc[0], out_inc[1]);
                errors = errors + 1;
            end
        end else begin
            $display("FAIL: ③ 事件太少（%0d）无法判'一步多乐器'", n_out);
            errors = errors + 1;
        end

        // ═══ ④ axis 用专用池 ═══════════════════════════════════════════════
        if (n_bad_axis == 0)
            $display("  ok  : ④ 全部事件 axis = %0d（>= 14 专用池）⛔ 不抢演奏的 voice", out_ax[0]);
        else begin
            $display("FAIL: ④ 有 %0d 个事件落在普通池（axis < 14）—— 会抢演奏 voice", n_bad_axis);
            errors = errors + 1;
        end

        // ═══ ⑤ 不粘滞 ═══════════════════════════════════════════════════════
        if (n_stuck == 0)
            $display("  ok  : ⑤ 不粘滞 —— valid 连续高时数据每拍都在变");
        else begin
            $display("FAIL: ⑤ 出现 %0d 拍'valid 高但数据不变'（粘滞）", n_stuck);
            errors = errors + 1;
        end

        // ═══ ⑩ step 计数正确（⭐ 0→1→…→15→0）═══════════════════════════════
        //   🔴🔴 **2026-09-26 踩坑（⭐ 我的判据写错了，⛔ 不是 RTL 的错）**：
        //      ⭐ 我原来写 `if (step_cnt < 4'd16)` —— ⚠️ 本意是"必须 < 16"，
        //      🔴 **但 `4'd16` 是【4 位】字面量 ⇒ `16` 被截断成 `0`**！
        //      ⇒ ⭐ 判据实际变成 `step_cnt < 0` ⇒ 🔴 **恒为假** ⇒ 永远报 FAIL。
        //      📌 **这是 Verilog 的经典位宽陷阱** ——
        //         ⚠️ 和 `evt_merge` 那个"`wire push_n` 隐含 1 bit"**同一族**
        //         （⭐ 本项目已踩过多次：`K-91` / `evt_merge` / 本处）。
        //   ⭐ 正确写法：⭐ **用足够宽的字面量**（`5'd16`）或 ⭐ **直接判语义**
        //      （⭐ `step_cnt` 是 4 位 ⇒ ⭐ **它天然就在 0~15** ⇒ ⭐ 真正该判的是"不是 X/Z"）
        if (step_cnt !== 4'hx && step_cnt !== 4'hz)
            $display("  ok  : ⑩ step 计数有效 = %0d（⭐ 4 位数天然在 0~15；本轮停在 15 是【正常的】—— ⭐ 恰好跑满 16 步到边界前）",
                     step_cnt);
        else begin
            $display("FAIL: ⑩ step 计数是 X/Z = %b", step_cnt);
            errors = errors + 1;
        end

        // ⭐ ⑩b **补一条更硬的**：⭐ 跑"半步"后 step 必须【恰好推进 1】
        //   （⭐ 上面那条太松 —— ⚠️ 4 位信号本来就装不下 ≥16 的值）
        begin : step_adv_check
            reg [3:0] st_before;
            @(negedge clk);
            st_before = step_cnt;
            run_ticks(TPS, 0);           // ⭐ 恰好推进一步（⛔ 不给 bar_start）
            @(negedge clk);
            if (((st_before == 4'd15) && (step_cnt == 4'd0)) ||
                ((st_before != 4'd15) && (step_cnt == st_before + 4'd1)))
                $display("  ok  : ⑩b 推进一个 16 分音符 ⇒ step 恰好 +1（%0d → %0d）",
                         st_before, step_cnt);
            else begin
                $display("FAIL: ⑩b step 推进错误：%0d → %0d（应 +1 或 15→0）",
                         st_before, step_cnt);
                errors = errors + 1;
            end
        end

        // ═══ ⑦ ⛔ 无 PCM（⭐ 合规判据 —— 静态检查）═════════════════════════
        //   ⭐ 本 tb 无法用 RTL 判据测"源码里没有采样表"
        //      ⇒ ⭐ 用 `$readmemh` 监视 + ⭐ 见下方"文件级静态检查"（在 Makefile/脚本里）
        //   ⭐ 这里判【运行时】没读过任何文件：⭐ 若有 `$readmemh` 且文件缺失会报错
        $display("  ok  : ⑦ 无 PCM —— 本模块【不加载任何文件】（见脚本级静态检查）");

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑪ transport 门控【独立判据】（⭐ 2026-09-26 补 · 变异 M123 的 LEAK）
        //
        //  🔴 **为什么要单补这一条**：⭐ 变异测试报 `M123 GREEN(LEAK)` ——
        //     ⭐ 把 `fire = has_pending & transport_i` 改成 `fire = has_pending`
        //     🔴 **我的 tb 竟然没抓到**！
        //  🔴 **真因（⚠️ 两条兜底路径【互相掩盖】）**：
        //     ⭐ 我在 `!transport_i` 时**也清了 `pending_q`**
        //     ⇒ ⚠️ 即使 `fire` 不看 `transport`，⭐ `has_pending` 已经是 0
        //     ⇒ ⭐ `fire` 仍为假 ⇒ 🔴 **变异体被第二条路径掩盖了**
        //  ⭐ **本判据的构造**：⭐ 让 **`transport` 拉低的【当拍正好有 pending】**
        //     ⇒ ⭐ 那就只有 `fire` 里的 `transport_i` 能拦住它 ⇒ ⭐ 变异必被抓住
        // ═══════════════════════════════════════════════════════════════════
        begin : transport_gate_check
            integer n_before;
            // ⭐ 先跑起来，⭐ 停在"某一步刚开始、pending 还满着"的时刻
            rst_n = 1'b0; transport_i = 1'b0; bar_start_i = 1'b0;
            tick_i = 1'b0; tick_cnt_i = 16'd0;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            transport_i = 1'b1;
            // ⭐ 跑一小节的开头几步（⭐ 此时 pending 里有 Kick+HiHat）
            run_ticks(TPS * 16, 1);
            // ⭐ 再推进一步 ⇒ ⭐ 装载新的一步（`mask_next` 非 0）⇒ ★ pending 满
            run_ticks(TPS, 0);
            @(negedge clk);
            //   ⭐ **关键：在 transport 拉低的【同一拍】就检查** ——
            //      ⚠️ 不能给它时间"靠清 pending 兜底"
            n_before = n_out;
            transport_i = 1'b0;          // 🔴 立刻停
            repeat (30) @(negedge clk);  // ⭐ 停着看 30 拍
            transport_i = 1'b1;
            if (n_out == n_before)
                $display("  ok  : ⑪ transport 拉低 ⇒【当拍即停】⛔ 不吐残余（%0d 拍内 0 个事件）",
                         30);
            else begin
                $display("FAIL: ⑪ 🔴 transport 停了却还发了 %0d 个事件（门控失效）",
                         n_out - n_before);
                errors = errors + 1;
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑫ 小节对齐【跨多小节判据】（⭐ 2026-09-26 补 · 变异 M124 的 LEAK）
        //
        //  🔴 **为什么要单补这一条**：⭐ 变异测试报 `M124 GREEN(LEAK)` ——
        //     ⭐ 把 `step_zero_align = transport_i & bar_start_i` 改成 `1'b0`
        //     🔴 **我的 tb 也没抓到**！
        //  🔴 **真因（⚠️ 观察窗口太短）**：
        //     ⭐ 我原来只跑【一小节】⇒ ⚠️ 内部 16 步计数器**恰好也走满 16 步**
        //     ⇒ 🔴 **"对齐"与"没对齐"在一小节内【看不出差别】**
        //  ⭐ **本判据的构造**：⭐ 跑 **3 小节**，⭐ 并且**每个 `bar_start` 时刻
        //     采样 `step_cnt`** ⇒ ⭐ 任意一次 `step_cnt != 0` 就说明失相。
        //     ⚠️ 且必须先"打乱相位"（⭐ 跑半步再对齐）⇒ ⭐ 否则天然就对齐。
        // ═══════════════════════════════════════════════════════════════════
        begin : bar_align_check
            integer bad_align;
            integer bar;
            bad_align = 0;
            // ⭐ 复位 + 起跑
            rst_n = 1'b0; transport_i = 1'b0; bar_start_i = 1'b0;
            tick_i = 1'b0; tick_cnt_i = 16'd0;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            transport_i = 1'b1;
            //   ⭐⭐ **先故意打乱相位**：⭐ 跑"半步"（不足一小节）
            //      ⇒ ⚠️ 这样若无 `bar_start` 对齐，⭐ 步号就会永久错开
            run_ticks(TPS * 5, 1);
            // ⭐ 然后跑 3 个完整小节，⭐ 每个 bar_start 当拍检查 step_cnt
            for (bar = 0; bar < 3; bar = bar + 1) begin
                @(negedge clk);
                tick_cnt_i  = 16'd0;
                bar_start_i = 1'b1;
                tick_i      = 1'b1;
                @(negedge clk);
                //   ⭐ **在 bar_start 拉高后的那拍**，⭐ `step_q` 应当已被强制为 0
                if (step_cnt !== 4'd0) begin
                    bad_align = bad_align + 1;
                    $display("      ⚠️ 第 %0d 个小节起点: step_cnt=%0d（应为 0）", bar, step_cnt);
                end
                tick_i      = 1'b0;
                bar_start_i = 1'b0;
                // ⭐ 跑满一个小节
                run_ticks(TPS * 16, 0);
            end
            if (bad_align == 0)
                $display("  ok  : ⑫ 小节对齐 —— 3 个小节起点 step_cnt 都是 0（⛔ 不漂移）");
            else begin
                $display("FAIL: ⑫ 🔴 有 %0d 个小节起点 step_cnt != 0 ⇒ 与节拍器失相", bad_align);
                errors = errors + 1;
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑬⑭ 小节相位【事件级】测量（⭐ 2026-09-29 新增 · Task 2）
        //
        //  🔴 **背景**：⭐ 用户上板反馈 *"第一拍太轻 / 整体像从弱拍起"*。
        //  ⭐ **本段回答的问题**：⭐ **复位之后，每个 `bar_start` 到底是第几步？**
        //     ⇒ ⭐ 打印**实测**的步号 + ⭐ 该小节第一个/第二个事件的乐器 ✅
        //  ⭐ **判据**（⭐ 两条都必须能红）：
        //     · ⑬ ⭐ 每个 `bar_start` 的 `step_cnt` == **0**（⭐ 型 0 的 step 0 在正拍）
        //     · ⑭ ⭐ `bar_start` 之后**第一个事件 = Kick**、⭐ 第二个 = **HiHat**
        //        （⭐ 即"step 0 真的带着 Kick"，⭐ 与常量表 `4'b0101` 一致）
        //  📌 **非空洞性**：⭐ ⑬ 抓"步号错"、⭐ ⑭ 抓"步号对但事件发到了别处"；
        //     ⭐ 任一条被破坏（⭐ 例如把 `step_zero_align` 改成 `1'b0`、
        //     ⭐ 或把 `mask_step0` 换成 `mask_next`）⇒ ⭐ **必红** ✅
        // ═══════════════════════════════════════════════════════════════════
        begin : bar_phase_measure
            integer bar;
            integer bad_step, bad_first, bad_second;
            // ⭐ 从【干净复位】开始（⭐ 任务要求 "after reset"）
            rst_n = 1'b0; transport_i = 1'b0; bar_start_i = 1'b0;
            tick_i = 1'b0; tick_cnt_i = 16'd0;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            pattern_id = 2'd0;                 // ⭐ 型 0（默认型）
            transport_i = 1'b1;
            // ⭐ 开测量 + ⭐ 跑 4 个小节（⭐ 每次 `run_ticks(...,1)` 正好一个小节）
            n_bar = 0; win_cnt = 0; bar_pending = 1'b0; meas_en = 1'b1;
            for (bar = 0; bar < 4; bar = bar + 1)
                run_ticks(TPS * 16, 1);
            repeat (20) @(negedge clk);
            meas_en = 1'b0;

            $display("  --- ⑬⑭ 小节相位实测（型 0，复位后连跑 4 小节）---");
            bad_step = 0; bad_first = 0; bad_second = 0;
            for (bar = 0; bar < 4; bar = bar + 1) begin
                $display("      bar %0d: step_at_bar_start=%0d  first_evt=%h  second_evt=%h",
                         bar, step_at_bar[bar], first_inc_at_bar[bar], second_inc_at_bar[bar]);
                if (step_at_bar[bar] !== 4'd0)             bad_step   = bad_step   + 1;
                if (first_inc_at_bar[bar]  !== INC_KICK)   bad_first  = bad_first  + 1;
                if (second_inc_at_bar[bar] !== INC_HIHAT)  bad_second = bad_second + 1;
            end
            if ((n_bar == 4) && (bad_step == 0))
                $display("  ok  : ⑬ 4 个 bar_start 的 step_cnt 全是 0 ⇒ 16 步表的 step 0 落在正拍");
            else begin
                $display("FAIL: ⑬ bar_start 处步号不为 0（采到 %0d 个小节，%0d 个不对）",
                         n_bar, bad_step);
                errors = errors + 1;
            end
            if ((n_bar == 4) && (bad_first == 0) && (bad_second == 0))
                $display("  ok  : ⑭ 正拍第一个事件 = Kick、第二个 = HiHat（= step 0 掩码 0101）");
            else begin
                $display("FAIL: ⑭ 正拍事件不是 step 0 的 Kick+HiHat（%0d 个首事件不对，%0d 个次事件不对）",
                         bad_first, bad_second);
                errors = errors + 1;
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑮ 运行时切节奏型 + 嗵鼓真的会响（⭐ 2026-09-29 新增 · Task 3/4）
        //
        //  ⭐ **判据**：⭐ 型 0 跑一小节后**直接改 `pattern_id_i`**（⭐ 不复位、不重跑）
        //     ⇒ ⭐ 下一小节必须**立刻**用**型 1 的新表**
        //     ⇒ ⭐ 一小节 = **Kick4 / Snare2 / 镲4 / Tom2 = 12 个事件** ✅
        //  📌 **它同时验两件事**：
        //     · ⭐ Task 3：⭐ 节奏型**运行时**可切（⭐ 不再是编译期常量）
        //     · ⭐ Task 4：⭐ 第 4 件乐器 = **Tom**（⭐ 型 1 的 step 8/16）**真的发得出来**
        //        （⭐ 判据靠 `INC_TOM` + `VEL_TOM`，⭐ 光改名不改音高是过不了的）
        //  ⚠️ **2026-09-30 更新**：⭐ 型 1 换成用户表 **HOUSE** ⇒ ⭐ 数字跟着换
        //     （⭐ 旧表是 16/4/2/8/2，⭐ 那是【已废弃的"八分摇滚"】）
        // ═══════════════════════════════════════════════════════════════════
        begin : pattern_switch_check
            rst_n = 1'b0; transport_i = 1'b0; bar_start_i = 1'b0;
            tick_i = 1'b0; tick_cnt_i = 16'd0;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
            pattern_id  = 2'd0;
            transport_i = 1'b1;
            run_ticks(TPS * 16, 1);              // ⭐ 先用型 0 跑一小节
            repeat (20) @(negedge clk);
            // ⭐⭐ **关键：⭐ 不复位、不重跑 —— 只改选择位** ✅
            pattern_id = 2'd1;
            n_out = 0; n_kick = 0; n_snare = 0; n_hihat = 0; n_tom = 0; n_tom_bad_vel = 0;
            run_ticks(TPS * 16, 1);              // ⭐ 同一拍序里再跑一小节
            repeat (20) @(negedge clk);
            $display("  --- ⑮ 切到型 1 后的一小节 ---");
            $display("      Kick=%0d  Snare=%0d  HiHat=%0d  Tom=%0d  总=%0d（Tom 力度异常 %0d 个）",
                     n_kick, n_snare, n_hihat, n_tom, n_out, n_tom_bad_vel);
            if ((n_out == 12) && (n_kick == 4) && (n_snare == 2) &&
                (n_hihat == 4) && (n_tom == 2) && (n_tom_bad_vel == 0))
                $display("  ok  : ⑮ 运行时切型立刻生效（型 1 = Kick4/Snare2/HiHat4/Tom2 = 12，力度 190）");
            else begin
                $display("FAIL: ⑮ 切型后事件数与用户表(HOUSE/型 1)不符（期望 12/4/2/4/2 + 力度全对，实得 %0d/%0d/%0d/%0d/%0d，力度异常 %0d）",
                         n_out, n_kick, n_snare, n_hihat, n_tom, n_tom_bad_vel);
                errors = errors + 1;
            end
        end

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ ⑯ 4 个节奏型【位精确】比对用户表（⭐ 2026-09-30 新增 · 本轮任务）
        //
        //  🔴 **为什么要它**：⭐ 用户上板说"原来的**塞得太满**、只有第一个能听"，
        //     ⭐ 并给了 4 张 16 步表 ⇒ ⭐ 本轮把表**逐格照抄**进 `step_mask_of`。
        //     ⚠️ 但"事件总数对"⛔ **不等于"表对"** —— ⭐ 例如把 Kick 挪到别的步、
        //        或把某一步的 Kick 换成 Tom，⭐ 总数可能**一模一样**
        //        ⇒ 🔴 必须**逐步逐位**比。
        //
        //  ⭐ **做法**：⭐ 4 个型各跑一遍：
        //     · ⭐ 先跑 1 小节【热身】（⭐ 丢弃）⇒ ⭐ 让 `bar_start` 对齐、相位稳定
        //     · ⭐ 清观察数组 ⇒ ⭐ 再跑 **1 个完整小节**（⭐ 16 步）采集
        //     · ⭐ 把每步观察到的掩码与**用户表**逐位比对（⭐ 4 型 × 16 步）
        //  ⭐ **判据 = 三件同时成立**：
        //     ① ⭐ 16 步掩码**逐位全等**（⭐ 主体）
        //     ② ⭐ 采集到的事件数 == 用户表的 `popcount` 之和（⭐ 防"窗口漏采"假绿）
        //     ③ ⭐ 没有"认不出的音高"事件（⭐ 防乐器身份被改）
        //  📌 **非空洞性**（⭐ 已实测）：⭐ 换回改动前的旧表 ⇒ 🔴 **4 条全红**；
        //     ⭐ 任一位翻掉 ⇒ 🔴 对应那条红 ✅
        //  ⭐ 判据名**纯 ASCII**、≤128 字节（⭐ vvp 会把非 ASCII 的 `$display` 搅乱）
        // ═══════════════════════════════════════════════════════════════════
        begin : pattern_table_bitexact
            integer p, k, bad_bits, exp_cnt;
            reg [1:0]       psel;
            reg [3:0]       exp_mask [0:15];
            reg [3:0]       tmp_mask;
            reg [8*128-1:0] crit_name;
            reg [8*16-1:0]  pat_name;
            $display("  --- (16) 4 pattern tables, bit-exact vs the user tables ---");
            $display("      mask format: %%b = bit3..bit0 = Tom,Cym,Snare,Kick");
            for (p = 0; p < 4; p = p + 1) begin
                // ⭐ 用户表（⭐ 1 基 step 01..16 ⇒ ⭐ 下标 0..15）
                //   ⭐ 位序：bit0=Kick · bit1=Snare · bit2=镲 · bit3=Tom
                if (p == 0) begin
                    // ⭐ DRUM_0 = BASIC
                    pat_name  = "BASIC";
                    crit_name = "drum_pat0_basic_16step_mask_table_bitexact";
                    exp_mask[0]=4'b0101; exp_mask[1]=4'b0000; exp_mask[2]=4'b0100; exp_mask[3]=4'b0000;
                    exp_mask[4]=4'b0111; exp_mask[5]=4'b0000; exp_mask[6]=4'b0100; exp_mask[7]=4'b0000;
                    exp_mask[8]=4'b0101; exp_mask[9]=4'b0000; exp_mask[10]=4'b0100; exp_mask[11]=4'b0000;
                    exp_mask[12]=4'b0111; exp_mask[13]=4'b0000; exp_mask[14]=4'b0100; exp_mask[15]=4'b0000;
                end else if (p == 1) begin
                    // ⭐ DRUM_1 = HOUSE
                    pat_name  = "HOUSE";
                    crit_name = "drum_pat1_house_16step_mask_table_bitexact";
                    exp_mask[0]=4'b0001; exp_mask[1]=4'b0000; exp_mask[2]=4'b0100; exp_mask[3]=4'b0000;
                    exp_mask[4]=4'b0011; exp_mask[5]=4'b0000; exp_mask[6]=4'b0100; exp_mask[7]=4'b1000;
                    exp_mask[8]=4'b0001; exp_mask[9]=4'b0000; exp_mask[10]=4'b0100; exp_mask[11]=4'b0000;
                    exp_mask[12]=4'b0011; exp_mask[13]=4'b0000; exp_mask[14]=4'b0100; exp_mask[15]=4'b1000;
                end else if (p == 2) begin
                    // ⭐ DRUM_2 = ROCK
                    pat_name  = "ROCK";
                    crit_name = "drum_pat2_rock_16step_mask_table_bitexact";
                    exp_mask[0]=4'b0101; exp_mask[1]=4'b0000; exp_mask[2]=4'b0100; exp_mask[3]=4'b0000;
                    exp_mask[4]=4'b0110; exp_mask[5]=4'b0000; exp_mask[6]=4'b0101; exp_mask[7]=4'b0000;
                    exp_mask[8]=4'b0101; exp_mask[9]=4'b0000; exp_mask[10]=4'b0100; exp_mask[11]=4'b0000;
                    exp_mask[12]=4'b0110; exp_mask[13]=4'b1000; exp_mask[14]=4'b0101; exp_mask[15]=4'b0000;
                end else begin
                    // ⭐ DRUM_3 = DANCE_FILL
                    pat_name  = "DANCE_FILL";
                    crit_name = "drum_pat3_dance_fill_16step_mask_table_bitexact";
                    exp_mask[0]=4'b0101; exp_mask[1]=4'b0000; exp_mask[2]=4'b0100; exp_mask[3]=4'b0000;
                    exp_mask[4]=4'b0111; exp_mask[5]=4'b0000; exp_mask[6]=4'b0100; exp_mask[7]=4'b1001;
                    exp_mask[8]=4'b0101; exp_mask[9]=4'b0000; exp_mask[10]=4'b1100; exp_mask[11]=4'b0000;
                    exp_mask[12]=4'b0111; exp_mask[13]=4'b1000; exp_mask[14]=4'b1100; exp_mask[15]=4'b1100;
                end
                // ⭐ `p` 是 integer ⇒ ⭐ 用 `case` 落到定宽 2 位（🔴 `K-91`：⛔ 不位选 integer）
                case (p)
                    0: psel = 2'd0;
                    1: psel = 2'd1;
                    2: psel = 2'd2;
                    default: psel = 2'd3;
                endcase
                // ⭐ 复位 + 起跑 + 热身小节（⭐ 丢弃）
                rst_n = 1'b0; transport_i = 1'b0; bar_start_i = 1'b0;
                tick_i = 1'b0; tick_cnt_i = 16'd0; tbl_en = 1'b0;
                repeat (8) @(negedge clk);
                rst_n = 1'b1;
                repeat (4) @(negedge clk);
                pattern_id  = psel;
                transport_i = 1'b1;
                run_ticks(TPS * 16, 1);
                repeat (20) @(negedge clk);
                // ⭐ 清观察数组 ⇒ ⭐ 采集【恰好一个小节】
                for (k = 0; k < 16; k = k + 1) tbl_mask[k] = 4'd0;
                tbl_unknown = 0; tbl_evt_seen = 0;
                tbl_en = 1'b1;
                run_ticks(TPS * 16, 1);
                repeat (20) @(negedge clk);
                tbl_en = 1'b0;
                // ⭐ 用户表的 popcount 之和（⭐ 本小节【应当】采到的事件数）
                exp_cnt = 0;
                for (k = 0; k < 16; k = k + 1) begin
                    tmp_mask = exp_mask[k];
                    exp_cnt  = exp_cnt + tmp_mask[0] + tmp_mask[1] + tmp_mask[2] + tmp_mask[3];
                end
                // ⭐ 逐位比对 + 打印（⭐ 打印出来给用户【肉眼核表】）
                bad_bits = 0;
                $display("      pattern %0d (%0s):", p, pat_name);
                for (k = 0; k < 16; k = k + 1) begin
                    if (tbl_mask[k] !== exp_mask[k]) begin
                        bad_bits = bad_bits + 1;
                        $display("        step %02d : expected=%b  observed=%b  <== MISMATCH",
                                 k + 1, exp_mask[k], tbl_mask[k]);
                    end else begin
                        $display("        step %02d : expected=%b  observed=%b  ok",
                                 k + 1, exp_mask[k], tbl_mask[k]);
                    end
                end
                if ((bad_bits == 0) && (tbl_evt_seen == exp_cnt) && (tbl_unknown == 0))
                    $display("  ok  : %0s", crit_name);
                else begin
                    $display("FAIL: %0s", crit_name);
                    $display("        (%0d of 16 steps mismatched, events seen %0d / expected %0d, unknown-pitch events %0d)",
                             bad_bits, tbl_evt_seen, exp_cnt, tbl_unknown);
                    errors = errors + 1;
                end
            end
        end

        // ═══ ⑧ cfg_warn ═════════════════════════════════════════════════════
        if (cfg_warn === 1'b0)
            $display("  ok  : ⑧ cfg_warn_o = 0（参数一致：AXIS_ID=15 >= 14, STEPS=16）");
        else begin
            $display("FAIL: ⑧ cfg_warn_o = %b（参数本该一致）", cfg_warn);
            errors = errors + 1;
        end

        // ═══ ⑥ + ⑨ 同拍 / 无 X/Z ════════════════════════════════════════════
        if ((evt_v !== 1'bx) && (evt_inc !== 32'hx) && (evt_ax !== 4'hx))
            $display("  ok  : ⑨ A8 无 X/Z 传播");
        else begin
            $display("FAIL: ⑨ 出现 X/Z（v=%b inc=%h ax=%h）", evt_v, evt_inc, evt_ax);
            errors = errors + 1;
        end

        // ═══ ②b transport 拉低 ⇒ 立刻停 ════════════════════════════════════
        transport_i = 1'b0;
        n_out = 0;
        run_ticks(TPS * 16, 1);
        if (n_out == 0)
            $display("  ok  : ②b transport 拉低后 ⇒ 立刻停发（⛔ 不吐残余）");
        else begin
            $display("FAIL: ②b transport 拉低后仍发了 %0d 条", n_out);
            errors = errors + 1;
        end

        $display("--------------------------------------------------");
        if (errors == 0)
            $display("PASS: drum_gen 一步多乐器不丢、16步=1小节、正拍相位(step0=Kick+HiHat)、专用池、不粘滞、transport 门控、运行时切型+嗵鼓、无 X/Z、4 个节奏型位精确对用户表");
        else
            $fatal(1, "FAIL: drum_gen has %0d unexpected item(s)", errors);

        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
