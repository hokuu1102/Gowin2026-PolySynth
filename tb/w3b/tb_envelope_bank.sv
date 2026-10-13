`timescale 1ns/1ps

module tb_envelope_bank;

    localparam integer POLY = 4;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg                    rst_n       = 1'b0;
    reg                    sample_tick = 1'b0;
    reg  [POLY-1:0]         gate        = {POLY{1'b0}};
    reg  [POLY*8-1:0]       velocity    = {(POLY*8){1'b0}};
    wire [POLY*16-1:0]      env_level;
    wire [POLY-1:0]         env_active;

    wire [15:0] env0 = env_level[0*16 +: 16];
    wire [15:0] env1 = env_level[1*16 +: 16];
    wire [15:0] env2 = env_level[2*16 +: 16];
    wire [15:0] env3 = env_level[3*16 +: 16];

    integer errors = 0;
    //  ⭐⭐ 2026-10-11（⭐ `P1-03`）：⭐ **差分判据用**（⭐ 单拍 / 双拍 tick 各一次 ✅）
    reg [15:0] e_one;
    reg [15:0] e_two;
    //  ⭐⭐ 2026-10-11（⭐ `P1-03b`）：⭐ **持续高电平**那一侧的结果 ✅
    reg [15:0] e_stuck;

    envelope_bank #(
        .POLY_TARGET (POLY),
        .ATTACK_STEP (16_384),
        .DECAY_STEP  (8_192),
        .SUSTAIN_Q8  (128),
        .RELEASE_STEP(4_096)
    ) dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (sample_tick),
        .gate_i        (gate),
        .velocity_i    (velocity),
        .env_level_o   (env_level),
        .env_active_o  (env_active)
    );

    //  ⭐⭐ P5-1（2026-10-03）契约变更：⭐ `envelope_bank` 现在是**共享引擎 +
    //     每拍服务一个 voice**（⭐ 见 `rtl/w3b/envelope_bank.v` 的文件头）⇒
    //     第 v 路要 **tick 后第 (2+v) 拍**才落盘（⭐ 本 tb `POLY=4` ⇒ 共 5 拍）。
    //     ⭐ 因此 `tick()` 必须**等轮转走完**再让判据采样 ——
    //     ⛔ **判据（期望值）一个字没改**，⭐ 只是补了等待。
    task automatic tick;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
            repeat (8) @(negedge clk);
            #1;
        end
    endtask

    task automatic tick_n;
        //  ⭐⭐ 2026-10-11（⭐ `P1-03`）：⭐ **参数化脉宽的 tick** ✅
        //     ⭐ `n` = `sample_tick` 保持高电平的**拍数** ✅
        //     📌 ⭐ **等待部分与 `tick()` 逐字相同** ⇒ ⭐ 两次测量**只差脉宽** ✅
        //        （⭐ 这样差分判据才成立 ✅）
        input integer n;
        integer k;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            for (k = 0; k < n; k = k + 1) @(negedge clk);
            sample_tick = 1'b0;
            repeat (8) @(negedge clk);
            #1;
        end
    endtask

    task automatic expect_levels(
        input [15:0] e0,
        input [15:0] e1,
        input [15:0] e2,
        input [15:0] e3,
        input [3:0]  active_mask
    );
        begin
            if (env0 !== e0 || env1 !== e1 || env2 !== e2 || env3 !== e3 || env_active !== active_mask) begin
                $display("FAIL: levels got=%0d/%0d/%0d/%0d active=%b expected=%0d/%0d/%0d/%0d active=%b",
                         env0, env1, env2, env3, env_active, e0, e1, e2, e3, active_mask);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_envelope_bank/tb_envelope_bank.vcd");
        $dumpvars(0, tb_envelope_bank);

        velocity[0*8 +: 8] = 8'd255;
        velocity[1*8 +: 8] = 8'd128;
        velocity[2*8 +: 8] = 8'd64;
        velocity[3*8 +: 8] = 8'd32;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        tick();
        expect_levels(0, 0, 0, 0, 4'b0000);

        gate[0] = 1'b1;
        tick();
        expect_levels(0, 0, 0, 0, 4'b0001);
        tick();
        expect_levels(16_384, 0, 0, 0, 4'b0001);

        gate[1] = 1'b1;
        tick();
        expect_levels(32_768, 0, 0, 0, 4'b0011);
        tick();
        expect_levels(49_152, 16_384, 0, 0, 4'b0011);

        // Releasing voice 0 must not reset or stall voice 1.
        gate[0] = 1'b0;
        tick();
        expect_levels(49_152, 32_768, 0, 0, 4'b0011);
        tick();
        expect_levels(45_056, 24_576, 0, 0, 4'b0011);

        // A third gate starts from zero without perturbing the two older voices.
        gate[2] = 1'b1;
        tick();
        expect_levels(40_960, 16_384, 0, 0, 4'b0111);
        tick();
        expect_levels(36_864, 16_384, 16_384, 0, 4'b0111);

        // ═════════════════════════════════════════════════════════════════
        $display("== P1-03：⭐ 多拍 `sample_tick` 必须与单拍【等价】==");
        // ═════════════════════════════════════════════════════════════════
        //  🔴 **缺陷（⭐ 审查 `[P1-03]`）**：⭐ `sample_tick_i` 若是**电平**
        //     （⭐ 连续 ≥2 拍为高 ✅），⭐ 每个高拍都会把 `cnt` 清 0
        //     ⇒ 🔴 `cnt` **永远到不了** `CNT_STOP = POLY_TARGET = 32`
        //     ⇒ ⭐ **32 路包络永久冻结** ⇒ 🔴 **无声** —— ⚠️ 而**所有 tb 都绿** ✅
        //     📌 ⭐ 这正是本项目**最贵的那一类**失效（⭐ 静默 + 假绿 ✅）
        //  ✅ **判据（⭐ 差分）**：⭐ 同样激励下，
        //     ⭐ **2 拍 tick 的结果必须 == 1 拍 tick 的结果** ✅
        //     🔴 **未修复时**：⭐ 2 拍那一侧 `env0` **不会推进** ⇒ ⭐ **必红** ✅
        //  ⚠️ ⭐ **为什么用差分而⛔ 不是写死期望值**：⭐ 这样判据**不依赖 ADSR 的绝对档位**
        //     （⭐ 换参数 / 换 `POLY_TARGET` 也不会假红 ✅）
        //  📌 ⭐ **为什么它现在才被发现**：⭐ 交付档 `clk_gen.v:104` 给的是**单拍脉冲**
        //     （⭐ `tick_audio <= (cnt == 0)` ✅）⇒ ⚠️ 生产路径上**不会**出现多拍
        //     ⇒ 🔴 **但它是一条"踩上就永久无声"的雷**（⭐ 任何上游改成电平就中招 ✅）

        //  ① 单拍 tick 的基准
        //     ⚠️ ⭐ **必须来【多轮】**：⭐ 本 tb 自己证明"**新开门的语音第 1 轮给 0**"
        //        （⭐ 见上方 `expect_levels(40_960, 16_384, **0**, 0, ...)` ✅）
        //        ⇒ ⭐ 第 1 轮只做**门控上升沿检测**，⭐ 攻击量要到第 2 轮才装载 ✅
        //     📌 ⭐ 实测踩到：⭐ 只来 1 轮 ⇒ ⭐ `e_one = 0` ⇒ ⚠️ 判据的非空洞性守卫先响 ✅
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        gate = {POLY{1'b0}}; gate[0] = 1'b1;
        tick_n(1); tick_n(1); tick_n(1);
        e_one = env0;

        //  ② 2 拍 tick（⭐ 电平）—— ⭐ **等待与 ① 完全相同**（⭐ 只有脉宽不同 ✅）
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        gate = {POLY{1'b0}}; gate[0] = 1'b1;
        tick_n(2); tick_n(2); tick_n(2);
        e_two = env0;

        if (e_one === 16'd0) begin
            $display("FAIL: P1-03 (non-vacuous) the 1-cycle reference did not advance (env0=0)");
            errors = errors + 1;
        end else if (e_two !== e_one) begin
            $display("FAIL: P1-03 a 2-cycle sample_tick is NOT equivalent: 1-cycle=%0d 2-cycle=%0d",
                     e_one, e_two);
            errors = errors + 1;
        end else begin
            $display("  ok  : P1-03 a 2-cycle sample_tick == a 1-cycle one (env0=%0d)", e_one);
        end

        // ═════════════════════════════════════════════════════════════════
        $display("== P1-03b：⭐ **持续为高**的 `sample_tick`（⭐ 已知缺口，⭐ 本轮【不修】）==");
        // ═════════════════════════════════════════════════════════════════
        //  🔴 **⚠️ 审查原文的前提【是错的】，⭐ 这里如实记录** ✅：
        //     ⭐ 它说 *"`sample_tick_i` 只要是电平（连续 2 拍以上为高），
        //        每个高拍都会把 `cnt` 清 0 ⇒ `cnt` 永远到不了 `CNT_STOP`"* ✅
        //     🔴 **实测：不成立** —— ⭐ 上面 `P1-03` 的差分判据在**未修复**的 RTL 上
        //        **就绿了**（⭐ 2 拍与 1 拍给出**同一个** `env0` ✅）
        //     ⭐ **为什么**：⭐ `sample_tick_i` 一拉低，⭐ `running` 分支**立刻接管**
        //        ⇒ ⭐ 轮转**只是被推迟**，⛔ **不会冻结** ✅
        //
        //  🔴 **真正的缺口（⭐ 已实测）**：⭐ `sample_tick_i` **持续为高**（⭐ 永不拉低 ✅）
        //     ⇒ ⭐ `cnt` 每拍被清 0、⭐ `running` 分支**永远轮不到**
        //     ⇒ ⭐ 32 路包络**冻结**（⭐ `env0` 一直 0 ✅）
        //
        //  ⚠️⚠️ **为什么本轮【不修】（⭐ 实测代价 > 收益 ✅）**：
        //     ⭐ 修法 `sample_tick_i && !running`（⭐ 审查给的 1 行 ✅）
        //        ⇒ ⭐ **"轮转进行中忽略新的 tick"** ✅
        //     🔴 **但它会打破一个真实契约**：⭐ `tb_note_manager_sus` 用
        //        **比一轮（33 拍）更快**的 `sample_tick` 来加速仿真 ✅
        //        ⇒ ⭐ 改动后它的 `S1c`/`S1d`（⭐ "无踏板释放 ⇒ 音消失"）**变红** ✅
        //        （⭐ 实测：⭐ 19/19 → 17/19 ✅）
        //     ⭐ 而**交付路径上两者逐位等价**（⭐ `clk_gen` 给单拍脉冲、
        //        ⭐ 帧间隔 1024 拍 ≫ 33 ✅）⇒ ⭐ **收益只是"防御性"的** ✅
        //     ⇒ ⭐ **结论：⭐ 为一个防御性收益去改真实契约，⛔ 不值得** ⇒ **回退** ✅
        //  📌 ⭐ **本判据（`P1-03`）保留为常驻不变量**：⭐ 它守的是
        //     "**多拍 tick ⛔ 不许改变结果**" ✅ —— ⭐ 若有人把 RTL 改成"多拍就冻"，
        //     ⭐ 它会**红** ✅
        //  📌 ⭐ **`P1-03b`（持续为高）本轮【故意不做成判据】** ——
        //     ⚠️ 因为修法已判定不落地 ⇒ ⭐ 做成判据只会留下一条**永久红** ✅
        //     📌 ⭐ 已记入 `sim/evidence/p1-03-20261011/README.md` ✅
        //     ⭐ **若将来要修**（⭐ 例如 `sample_tick` 的来源改成不可信 ✅），
        //     ⭐ 必须**同时**处理 `tb_note_manager_sus` 的 tick 速率契约 ✅

        if (errors == 0)
            $display("PASS: envelope_bank keeps per-voice ADSR state independent");
        else
            $display("FAIL: envelope_bank independence had %0d error(s)", errors);

        $finish(errors != 0);
    end

    initial begin
        #2_000_000;
        $fatal(1, "FAIL: tb_envelope_bank timeout");
    end

endmodule
