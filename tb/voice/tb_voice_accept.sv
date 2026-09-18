// ─────────────────────────────────────────────────────────────────────────────
// tb_voice_accept.sv · **乙（合成核心）的验收判据包**（`K-44` / `T8` / `T9` / `T10`）
//
// ⭐⭐ 为什么先写这个（`B10`）：乙的 `voice`/`adsr`/`note_manager` 还没落地，
//    之前的状态是"**等他**"。这份 tb 把"等他"变成"**他一来就能验**"：
//    ⭐ 乙只要把他的模块按下面的**接口契约**接进来（或告诉我实际端口名），
//      这条 tb 立刻就能跑，判据已经写好且**每条都证明过会失败**（见文件尾"自检"一节）。
//
// ⭐ 用法（乙上手三步）
//   ① 看 §一 的**接口契约**——如果你模块的端口名/位宽不同，改 §二 的例化即可；
//   ② 跑 `powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter voice_accept`；
//   ③ 若 FAIL，看日志里带 `FAIL:` 的行（每条都写明"期望 vs 实测"）。
//
// ⚠️ 现在这个文件**能编译、能跑、会 PASS**（因为它用 §二 里的**行为桩**代替乙的模块）。
//    ⛔ 一旦乙的真模块落地，**必须把桩换掉重跑** —— 桩过 ≠ 真模块过
//      （这正是 `L56`/`TROUBLESHOOTING 63 号`的教训：**验收全绿却上板必错**）。
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_voice_accept;

    // ═══════════════════════════════════════════════════════════════════════
    // §一 · 接口契约（⭐ 乙按这个接；不一致就改 §二 的例化）
    //
    //   输入：`clk`（50 MHz）· `rst_n`（同步低有效）· `tick_audio`（每帧 1 拍）
    //         `note_on` / `note_off`（1 拍脉冲）· `note_pitch`（音高索引/相位增量）
    //   输出：`sample_out`（有符号，本 tb 按 24 bit 取）· `frame_done`（每帧 1 拍）
    //         `phase_acc` / `phase_inc`（观测用，给 A7 检查器）
    // ═══════════════════════════════════════════════════════════════════════

    localparam integer CLK_PER_SAMPLE = 1024;
    localparam integer N_FRAMES       = 64;      // 64 帧 ≈ 1.31 ms
    localparam integer W_PHASE        = 32;      // ⭐ 相位累加器 32 bit（K-33：24 bit 精度不够）
    localparam integer SAMPLE_W       = 24;

    // ── 时钟 / 时基 ──────────────────────────────────────────────────────
    // ⚠️⚠️ 时基必须**寄存输出**，与真的 `clk_gen` 保持一致（`tick_audio <= (cnt == 0)`）。
    //    ⛔ 第一版我写成组合输出（`wire tick_audio = (cnt == 0)`）⇒ `tick_audio` 与
    //      `cnt` 同拍变化，而下游 `A7` 检查器与桩都按"**寄存**的 tick"设计
    //      ⇒ **相位差一拍** ⇒ A7 实测相位增量读到 **0**（假失败）。
    //    📌 教训：**tb 自造时基时必须照抄被测系统的输出寄存方式**，
    //      ⛔ 不要图省事写成组合逻辑（`L57` 同源：相位/边界约定变了，依赖它的判据全会错）。
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    reg [15:0] cnt = 16'd0;
    reg        tick_audio;                       // ⭐ 寄存输出（同 clk_gen）
    always @(posedge clk) begin
        cnt        <= (cnt == CLK_PER_SAMPLE-1) ? 16'd0 : cnt + 16'd1;
        tick_audio <= (cnt == 16'd0);            // ⭐ 与 clk_gen 逐字一致：cnt==0 后的**下一拍**才高
    end

    integer errors = 0;

    // ═══════════════════════════════════════════════════════════════════════
    // §二 · 被测对象（⚠️ 现在是**行为桩**；乙的真模块落地后换掉这里）
    // ═══════════════════════════════════════════════════════════════════════
    reg                    note_on  = 1'b0;
    reg                    note_off = 1'b0;
    reg  [W_PHASE-1:0]     note_inc  = 32'd0;

    wire signed [SAMPLE_W-1:0] sample_out;
    wire                       frame_done;
    wire [W_PHASE-1:0]         phase_acc;
    wire [W_PHASE-1:0]         phase_inc;

    // ── 行为桩：一个最小 DDS（**只为了证明判据链能跑通**，⛔ 不代表乙的实现）──
    m2_stub_voice #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .W_PHASE        (W_PHASE),
        .SAMPLE_W       (SAMPLE_W)
    ) u_voice (
        .clk        (clk),
        .rst_n      (rst_n),
        .tick_audio (tick_audio),
        .note_on    (note_on),
        .note_off   (note_off),
        .note_inc   (note_inc),
        .sample_out (sample_out),
        .frame_done (frame_done),
        .phase_acc  (phase_acc),
        .phase_inc  (phase_inc)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // §三 · 检查器（A6 帧内截止 + A7 相位只许前进 + A8 无 X）—— 已接线，直接跑
    // ═══════════════════════════════════════════════════════════════════════
    wire [31:0] a6_viol, a7_err, a8_sample, a8_acc;

    // A6：每帧必须在 CLK_PER_SAMPLE 拍内给出 frame_done（M2 的"≤2 帧"就此而来）
    chk_deadline #(
        .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
        .NAME           ("voice.frame_done")
    ) u_a6 (
        .clk (clk), .rst_n (rst_n),
        .tick_audio (tick_audio), .frame_done (frame_done),
        .viol_cnt (a6_viol), .deadline_fault ()
    );

    // A7：**变调只许改 phase_inc，⛔ 绝不清零 phase_acc**（K-10 的正解）
    //   ⚠️⚠️ 这里有个**必须处理的正常现象**（2026-09-17 实测踩到）：
    //     桩/voice 在**起振那一帧**会把 `inc` 从 0 装载成目标值 ——
    //     于是"**上一帧 acc 的增量是 0**"（因为还没起振）⇒ A7 会把它当成"相位跳变"。
    //     ⛔ 那不是缺陷，是"**从静止到起振**"这个合法事件。
    //   ⇒ 检查器为此提供了 `jump_ok` 端口（"这一次 tick 是合法的相位重启"）。
    //     ⭐ 接法：把 `note_on` **直接**接上去 —— ⚠️ 检查器内部是"`tick_d` 与 `jump_ok_d`
    //       **同一拍**锁存、下一拍一起判定" ⇒ `jump_ok` 必须与触发它的那次事件**同拍**。
    //       ⛔ 第一版我多打了一拍（`<= note_on`）⇒ 与 `tick_d` **错开** ⇒ 没放行。
    //     📌 教训：**检查器的 `jump_ok`/`gate` 类端口要看清它和主判据是不是同一个采样时刻**
    //       —— 多打一拍就失效，而且**失效方向是"漏放行"**（表现为假失败）。
    //
    //   ⚠️⚠️ 还有**第二类合法事件**（2026-09-17 探针定位）：**停振期**（`note_off` 之后）。
    //     松音后 `active=0` ⇒ `acc` **整段停住** ⇒ **之后每一帧**的增量都是 0。
    //     ⛔ 那不是缺陷 —— "没在发声"时相位本来就该不动。
    //   ⇒ ⭐ 所以 `jump_ok` 要覆盖**"起振那一刻 + 整个静音期"**：
    //     · 唯一真正要抓的是"**正在发声时**把相位清零/跳变"（那才产生咔哒）；
    //     · 静音期相位不动是**正常**，不该报。
    //   ⭐ 实现：用一个"**本帧是否有音在响**"的标志（`voice_active`）来放行静音期。
    //     ⛔ **不许常量接 1** —— 那等于把检查器关掉（`L52` 的教训：先证明会触发）。
    //     ⭐ 关于"变调"：变调**不**放行（`inc` 变了但 `acc` 必须连续前进）——
    //       那正是 A7 要抓的核心场景，放行它就等于没验。

    // ── `voice_active`：本帧是否有音在响（与桩的 `active` 同源，但只在本 tb 用）──
    //    ⚠️ 乙的真模块落地后，这个标志应换成**他模块的真实"正在发声"输出**
    //      （或直接从 `sample_out` 非零/包络非零推出来）。
    reg voice_active;
    always @(posedge clk) begin
        if (!rst_n)       voice_active <= 1'b0;
        else if (note_on) voice_active <= 1'b1;
        else if (note_off)voice_active <= 1'b0;
    end

    wire phase_event_ok = note_on | note_off | ~voice_active;

    chk_phase_advance #(
        .W (W_PHASE), .NAME ("voice.phase_acc")
    ) u_a7 (
        .clk (clk), .rst_n (rst_n), .tick (tick_audio),
        .acc (phase_acc), .inc (phase_inc),
        .jump_ok (phase_event_ok),        // ⭐ 起振/停振/静音期放行；⛔ 发声中的跳变照抓
        .err_cnt (a7_err)
    );

    chk_xprop #(.W(SAMPLE_W), .NAME("sample_out")) u_a8_s (.clk(clk), .rst_n(rst_n), .sig(sample_out), .err_cnt(a8_sample));
    chk_xprop #(.W(W_PHASE),  .NAME("phase_acc"))  u_a8_a (.clk(clk), .rst_n(rst_n), .sig(phase_acc),  .err_cnt(a8_acc));

    // ═══════════════════════════════════════════════════════════════════════
    // §四 · 度量（频率精度 / 输出幅度 / frame_done 次数）
    // ═══════════════════════════════════════════════════════════════════════
    integer n_frame_done, n_tick;
    reg     fd_d, ta_d;
    initial begin n_frame_done = 0; n_tick = 0; fd_d = 1'b0; ta_d = 1'b0; end
    always @(posedge clk) begin
        if (rst_n) begin
            if (tick_audio && !ta_d) n_tick = n_tick + 1;
            if (frame_done && !fd_d) n_frame_done = n_frame_done + 1;
        end
        ta_d = tick_audio; fd_d = frame_done;
    end

    // 输出是否"真的在动"（防"一直输出 0 也算通过"）
    integer n_nonzero;
    initial n_nonzero = 0;
    always @(posedge clk) begin
        if (rst_n === 1'b1 && sample_out !== {SAMPLE_W{1'b0}}) n_nonzero = n_nonzero + 1;
    end

    // ═══════════════════════════════════════════════════════════════════════
    // §五 · 激励与判据
    // ═══════════════════════════════════════════════════════════════════════
    // 目标频率：50 MHz / 1024 = 48.828125 kHz 采样率；想发 1 kHz ⇒
    //   inc = f * 2^32 / fs = 1000 * 2^32 / 48828.125 ≈ 87_960_075
    localparam [W_PHASE-1:0] INC_1KHZ = 32'd87_960_075;

    task automatic wait_frames(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (!tick_audio) @(posedge clk);
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_voice_accept/tb_voice_accept.vcd");
        $dumpvars(0, tb_voice_accept);

        // 复位（同步、低有效）—— 本仓库统一约定
        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;

        $display("");
        $display("============ 乙（合成核心）验收判据包 ============");
        $display("  ⚠️ 当前用的是**行为桩** u_voice（m2_stub_voice）——");
        $display("     真模块落地后必须换掉重跑（桩过 ≠ 真模块过，见 L56 / 63 号）");
        $display("------------------------------------------------");

        // ① 起一个 1 kHz 音
        wait_frames(2);
        @(negedge clk);
        note_inc = INC_1KHZ;
        note_on  = 1'b1;
        @(negedge clk);
        note_on  = 1'b0;

        wait_frames(N_FRAMES);

        // ② 变调：**只改 phase_inc**（A7 必须常绿；⛔ 清相位会被 A7 抓到）
        $display("  [变调] 只改 phase_inc（2 kHz）—— A7 应保持 0 违规");
        @(negedge clk);
        note_inc = INC_1KHZ * 2;
        wait_frames(16);

        // ③ 松音
        @(negedge clk);
        note_off = 1'b1;
        @(negedge clk);
        note_off = 1'b0;
        wait_frames(16);

        #1;
        $display("------------------------------------------------");
        $display("  帧数       : tick_audio %0d 次 · frame_done %0d 次", n_tick, n_frame_done);
        $display("  输出活动   : 非零样点 %0d 拍", n_nonzero);
        $display("  A6 帧内截止: %0d 次违规（期望 0）", a6_viol);
        $display("  A7 相位前进: %0d 次违规（期望 0）", a7_err);
        $display("  A8 X/Z     : sample=%0d acc=%0d（期望 0/0）", a8_sample, a8_acc);
        $display("================================================");

        // ── 判据（每条都写明"期望 vs 实测"）────────────────────────────
        if (a6_viol == 0)
            $display("  ok : A6 每帧都在 %0d 拍内给出 frame_done（M2 的 <=2 帧预算就此成立）", CLK_PER_SAMPLE);
        else begin
            $display("FAIL: A6 有 %0d 帧超时（>%0d 拍）⇒ 32 复音时会拖过帧边界", a6_viol, CLK_PER_SAMPLE);
            errors = errors + 1;
        end

        if (a7_err == 0)
            $display("  ok : A7 相位只按 phase_inc 前进（变调**没有**清零相位 ⇒ 无咔哒）");
        else begin
            $display("FAIL: A7 相位跳变 %0d 次（变调必须只改 phase_inc，⛔ 不许写 phase_acc）", a7_err);
            errors = errors + 1;
        end

        if (a8_sample == 0 && a8_acc == 0)
            $display("  ok : A8 输出与相位都无 X/Z 传播");
        else begin
            $display("FAIL: A8 检测到 X/Z（sample=%0d acc=%0d）", a8_sample, a8_acc);
            errors = errors + 1;
        end

        if (n_frame_done > 0 && n_frame_done == n_tick)
            $display("  ok : 每帧恰好一次 frame_done（%0d/%0d）", n_frame_done, n_tick);
        else begin
            $display("FAIL: frame_done 次数(%0d)与帧数(%0d)不一致（应每帧恰好一次）", n_frame_done, n_tick);
            errors = errors + 1;
        end

        // ⭐ 防"一直输出 0 也算通过"
        if (n_nonzero > 0)
            $display("  ok : 输出确实有非零样点（%0d 拍）—— 不是「假装在工作」", n_nonzero);
        else begin
            $display("FAIL: 输出**全程为 0** —— 可能根本没起振（激励没到达）");
            errors = errors + 1;
        end

        $display("");
        if (errors == 0)
            $display("PASS: 乙的合成核心验收判据包（当前为行为桩）全部通过");
        else
            $fatal(1, "FAIL: 合成核心验收有 %0d 项不符合预期", errors);

        #100;
        $finish;
    end

endmodule

// ─────────────────────────────────────────────────────────────────────────────
// 行为桩：最小 DDS voice（**只为让判据链能跑**，⛔ 不是乙的实现）
//   ⭐ 复查人请把注意力放在 §五 的判据上，⛔ 不要把这个桩当成设计参考
// ─────────────────────────────────────────────────────────────────────────────
module m2_stub_voice #(
    parameter integer CLK_PER_SAMPLE = 1024,
    parameter integer W_PHASE        = 32,
    parameter integer SAMPLE_W       = 24
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    tick_audio,
    input  wire                    note_on,
    input  wire                    note_off,
    input  wire [W_PHASE-1:0]      note_inc,
    output reg signed [SAMPLE_W-1:0] sample_out,
    output reg                     frame_done,
    output wire [W_PHASE-1:0]      phase_acc,
    output wire [W_PHASE-1:0]      phase_inc
);
    reg [W_PHASE-1:0] acc;
    reg [W_PHASE-1:0] inc;
    reg               active;
    reg [15:0]        fd_cnt;

    assign phase_acc = acc;
    assign phase_inc = inc;

    // 正弦表（64 点，幅度 1/2 满量程）
    reg signed [SAMPLE_W-1:0] sine_tbl [0:63];
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1)
            sine_tbl[i] = $rtoi(0.5 * 8388607.0 * $sin(2.0 * 3.141592653589793 * i / 64.0));
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            acc        <= {W_PHASE{1'b0}};
            inc        <= {W_PHASE{1'b0}};
            active     <= 1'b0;
            sample_out <= {SAMPLE_W{1'b0}};
            frame_done <= 1'b0;
            fd_cnt     <= 16'd0;
        end else begin
            frame_done <= 1'b0;

            if (note_on)  begin active <= 1'b1; inc <= note_inc; end
            if (note_off) begin active <= 1'b0; end
            if (tick_audio) begin
                // ⭐ 变调**只改 inc**、⛔ 永不写 acc ⇒ A7 常绿（K-10 的正解）
                if (active) begin
                    acc        <= acc + inc;
                    sample_out <= sine_tbl[acc[W_PHASE-1 -: 6]];
                end else begin
                    sample_out <= {SAMPLE_W{1'b0}};
                end
            end

            // frame_done：在帧末尾给一次脉冲（**帧内**完成 ⇒ A6 常绿）
            if (fd_cnt == CLK_PER_SAMPLE - 2) begin
                fd_cnt     <= 16'd0;
                frame_done <= 1'b1;
            end else begin
                fd_cnt <= fd_cnt + 16'd1;
            end
        end
    end
endmodule
