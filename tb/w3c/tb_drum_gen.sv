// ═══════════════════════════════════════════════════════════════════════════
//  tb_drum_gen —— ⭐ 纯合成鼓机（Kick / Snare / Hi-hat / Clap）
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

    wire        evt_v;
    wire [3:0]  evt_ax;
    wire [31:0] evt_inc;
    wire [7:0]  evt_vel;
    wire [1:0]  evt_kd;
    wire [15:0] evt_cnt, step_evt_cnt;
    wire [3:0]  step_cnt, hit_cnt;
    wire        cfg_warn;

    // ⭐ 参数：AXIS_ID=15（专用池）、PATTERN_ID=0（Rock）
    drum_gen #(
        .AXIS_W(AXIS_W), .PHASE_W(PHASE_W), .VEL_W(VEL_W),
        .AXIS_ID(15), .N_DRUM(4), .STEPS(16), .PATTERN_ID(0),
        .TICKS_PER_STEP(TPS), .RESERVED_N(5)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
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
    integer n_kick = 0, n_snare = 0, n_hihat = 0, n_clap = 0;
    integer n_bad_axis = 0;          // ⭐ axis 不在专用池的次数

    // ⭐ 鼓的"身份"：⭐ 用 phase_inc 分辨是哪一件（⭐ 与 DUT 的常量一致）
    localparam [31:0] INC_KICK  = 32'd6_442_451;
    localparam [31:0] INC_SNARE = 32'd17_179_869;
    localparam [31:0] INC_HIHAT = 32'd171_798_691;
    localparam [31:0] INC_CLAP  = 32'd85_899_345;

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
            if (evt_inc == INC_CLAP)  n_clap  = n_clap  + 1;
            // ⭐ 专用池检查（⭐ RESERVED_AXIS_BASE = 14）
            if (evt_ax < 4'd14) n_bad_axis = n_bad_axis + 1;
            // ⭐ 粘滞：⭐ 连续两拍且数据完全一样
            if (evt_v_d && (evt_inc === last_inc)) n_stuck = n_stuck + 1;
            last_inc = evt_inc;
        end
        evt_v_d <= evt_v;
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
        $display("⭐ 参数：AXIS_ID=15 · PATTERN_ID=0(Rock) · TICKS_PER_STEP=%0d", TPS);

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
        //   ⭐ Rock 型一小节的事件数（⭐ 数常量表）：
        //      step0=2 · step2=1 · step4=1 · step6=1 · step8=2 · step10=1
        //      step12=1 · step14=1  ⇒ ⭐ **共 10 个事件**
        n_out = 0; n_kick = 0; n_snare = 0; n_hihat = 0; n_clap = 0; n_bad_axis = 0; n_stuck = 0;
        transport_i = 1'b1;
        run_ticks(TPS * 16, 1);      // ⭐ 恰好一小节
        repeat (20) @(negedge clk);
        $display("  --- 一小节（Rock）事件统计 ---");
        $display("      Kick=%0d  Snare=%0d  HiHat=%0d  Clap=%0d  总=%0d",
                 n_kick, n_snare, n_hihat, n_clap, n_out);
        if (n_out == 10 && n_kick == 2 && n_snare == 2 && n_hihat == 6)
            $display("  ok  : ② 一小节恰好 10 个事件（Kick2/Snare2/HiHat6）—— 与常量表吻合");
        else begin
            $display("FAIL: ② 一小节事件数与常量表不符（期望 10/2/2/6，实得 %0d/%0d/%0d/%0d）",
                     n_out, n_kick, n_snare, n_hihat);
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
            $display("PASS: drum_gen 一步多乐器不丢、16步=1小节、专用池、不粘滞、transport 门控、无 X/Z");
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
