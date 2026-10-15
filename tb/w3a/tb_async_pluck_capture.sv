`timescale 1ns/1ps

// T15 public seam: two asynchronous comparator outputs become one clean pluck
// event.  UP must win when both synchronized edges occur in the same cycle.
module tb_async_pluck_capture;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg up_async = 1'b0;
    reg down_async = 1'b0;
    wire pluck_valid;
    wire pluck_up;
    wire armed;
    wire both_low;
    integer errors = 0;
    integer event_n = 0;
    reg event_dir [0:7];

    always #10 clk = ~clk;

    async_pluck_capture #(.REFRACT_CYC(10)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .pluck_up_async_i(up_async), .pluck_down_async_i(down_async),
        .pluck_valid_o(pluck_valid), .pluck_up_o(pluck_up),
        .armed_o(armed), .both_low_o(both_low)
    );

    task chk;
        input [8*96-1:0] name;
        input cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task pulse_up;
        begin
            @(negedge clk); up_async = 1'b1;
            @(negedge clk); up_async = 1'b0;
        end
    endtask

    task pulse_down;
        begin
            @(negedge clk); down_async = 1'b1;
            @(negedge clk); down_async = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && pluck_valid) begin
            event_dir[event_n] = pluck_up;
            event_n = event_n + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        pulse_up;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chk("UP edge produces exactly one pluck", event_n == 1);
        chk("UP edge is labelled UP", event_dir[0] == 1'b1);
        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-15（⭐ 缝合 STITCHER）：⭐ **H10 —— `armed_o` 的断言** ⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **原空洞**：⭐ `armed_o` **一条断言都没有** ⇒ ⭐ 变异体
        //     （⭐ `assign armed_o = 1'b0;` / 恒 `x`）**测不出来** ✅
        //  ⭐ **判据选择（⭐ 我的判断：加断言，⛔ 不删端口）** —— 三条理由：
        //     ① ⭐ `top.v` 已把 `armed_o` 接进 `syn_keep`
        //        ⇒ 🔴 **删端口会让 `top.v` 一起编译失败**（⭐ 而本任务 ⛔ 不许动 `top.v`）✅
        //     ② ⭐ 它是 `K-106` 要求的**可观测端口**（⭐ 回答"为什么这一拨没响"）
        //        ⇒ ⭐ 删掉等于**把诊断能力也删了** ✅
        //     ③ ⭐ 断言能把**新语义**钉成契约：⭐ 门控删了 ⇒ `armed_o` **恒 1**
        //        （⭐ 唯一的节流是 `refractory_q`）⇒ 🔴 谁把门控加回来，⭐ 这条**立刻红** ✅
        chk("H10 armed_o is ALWAYS 1'b1 (post-gate semantics: only refractory throttles)",
            armed === 1'b1);

        // Repeated comparator chatter during refractory time must not retrigger.
        pulse_down;
        repeat (2) @(posedge clk);
        @(negedge clk);
        chk("refractory suppresses a second immediate edge", event_n == 1);

        // Wait beyond both the synchronizer latency and the full refractory
        // interval before asking for a fresh edge.
        repeat (12) @(posedge clk);
        pulse_down;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chk("edge is accepted again after refractory", event_n == 2);
        chk("DOWN edge is labelled DOWN", event_dir[1] == 1'b0);

        repeat (12) @(posedge clk);
        @(negedge clk); up_async = 1'b1; down_async = 1'b1;
        @(negedge clk); up_async = 1'b0; down_async = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chk("simultaneous UP and DOWN create one event", event_n == 3);
        chk("simultaneous UP and DOWN chooses UP", event_dir[2] == 1'b1);

        /*  ⭐⭐ 2026-10-15：⭐ **"回中门控 / 过冲"用例已【整个删除】** ✅
         *  ===========================================================================
         *  🔴 **原用例**（⭐ 本 tb 旧 `:90-139`）：⭐ "下拨 ⇒ 回中途中过冲把 `UP` 抬起
         *     ⇒ 只准出 1 条" ✗
         *  🔴 **为什么删**：⭐ 那条序列**物理上不存在** —— ⭐ 依据（⭐ 硬件实测，
         *     ⛔ 不是推断）：`files/10-硬件/右手板方案.md`
         *     · ⭐ 摇杆静止（回中）= **1.737 V**（`:403`）
         *     · ⭐ `DOWN_REF` = **1.24 V**（`:422`）／`UP_REF` = **2.24 V**（`:421`）
         *     · ⇒ ⭐ 静止点**落在两阈值之间** ⇒ ⭐ 静止时两路都低 ✓
         *     · ⇒ 🔴 要让"回摆过冲"触发 `UP`，⭐ `PICK` 必须从静止点再上冲
         *       **503 mV**（⭐ = 后拉行程的 **35%**；⭐ 相对前推触发点则是 **2.12 V**）
         *     · ⭐ 而实测迟滞窗口只有 **18.6 mV**（`:442-443`）
         *       ⇒ ⭐ 它只管"阈值附近不抖"，⛔ **不提供反冲的能量来源**
         *     · ⭐ 弹簧回中是**单调回到静止点**的机械过程
         *       ⇒ 🔴 **"反冲 503 mV"不存在** ✗
         *  ⛔ **不许"改对它"**：⭐ 那会把一个**不存在的故障**固化成契约（⭐ 后患无穷）✅
         *  ⭐ 该门控（`armed_q`）已从 RTL **整个删除** —— ⭐ 它属于用户明确反对的
         *     **"给真拨弦加额外限制"**那一类，⭐ 且带
         *     "`armed_q` 卡死 ⇒ 上电只有第一下响"的风险 ✅
         *  📌 **本判据的替代（⭐ 保覆盖，⛔ 不是删完就没事了）**：
         *     ⭐ 现在要守的是**反面** —— ⭐ **真·交替拨弦（下拨 ⇒ 回中 ⇒ 上拨）
         *     两下都必须出声**，⛔ **不许再被任何位置门控挡掉** ✅ */

        //  ⭐ 真·交替拨弦：⭐ DOWN ⇒ 回中 ⇒ UP ⇒ ⭐ **两下都要出声** ✅
        //     ⚠️ 两沿之间**必须耗完 refractory**（⭐ 本 tb 实参 `REFRACT_CYC(10)`）
        //        ⇒ ⭐ 否则第二下是被 `refractory` 挡的，⭐ 判据就**测不到门控**了
        //        （⭐ 这正是旧用例第一版栽的那个坑，⭐ 记下来别再犯）✅
        repeat (20) @(posedge clk);
        event_n = 0;                             // ⭐ 重新计数，只看这一段
        pulse_down;                              // ⭐ ① 真·下拨
        repeat (6) @(posedge clk);
        chk("alternating pluck: a genuine DOWN stroke fires (no position gate in the way)",
            event_n == 1 && event_dir[0] == 1'b0);
        repeat (20) @(posedge clk);               // ⭐ 耗完 refractory
        pulse_up;                                // ⭐ ② 回中后的真·上拨
        repeat (6) @(posedge clk);
        chk("alternating pluck: the following genuine UP stroke ALSO fires (no extra restriction)",
            event_n == 2 && event_dir[1] == 1'b1);
        chk("both_low_o still reports the centred state after both strokes settle",
            both_low === 1'b1);

        /*  ═══════════════════════════════════════════════════════════════════════
         *  ⭐⭐ 2026-10-15（⭐ 缝合 STITCHER）：⭐ **H9 —— "删门控"的【能红】判据** ⭐⭐
         *  ═══════════════════════════════════════════════════════════════════════
         *  🔴 **原空洞（⭐ 排查指出的第 3 条）**：⭐ 上面那段"替代用例"**带门控也全绿** ✅
         *     为什么？⭐ 因为它的**两条拨弦之间都回到了"两路都低"**
         *     （⭐ 中间有 `repeat (20)` 的空档 ⇒ `both_low=1` ⇒ `armed_q` **重新武装**）
         *     ⇒ 🔴 它根本**没测到门控** —— ⭐ 只测到了"门控不挡正常交替" ✅
         *  ✅ **补法**：⭐ **制造"两路不全低"**（⭐ 把另一路**保持在高**）
         *     ＋ ⭐ **耗完 refractory**（⭐ 本 tb 实参 `REFRACT_CYC(10)`）
         *     ⇒ ⭐ 再给一个**新沿** ⇒ ⭐ 断言**仍出声** ✅
         *     🔴 **带门控（⭐ 删门控之前的实现）必红**：⭐ `armed_q <= both_low`
         *        恒为 **0** ⇒ ⭐ 新沿被**永久**挡掉 ⇒ ⭐ `event_n == 0` ✅
         *  📌 ⚠️ **一个物理常识**：⭐ 若"另一路保持在高"，⭐ 则"同一路的**新上升沿**"
         *     **逻辑上不可能**（⭐ 它已经在高）⇒ ⭐ 所以本用例**两个方向都测**：
         *       ① ⭐ `up_async` 保持高 ⇒ ⭐ 给一个**真的 `down` 上升沿** ✅
         *       ② ⭐ `down_async` 保持高 ⇒ ⭐ 给一个**真的 `up` 上升沿** ✅
         *     ⇒ ⭐ 覆盖"两路不全低"的**两种**情形（⭐ 排查原文只写了 ①，⭐ 这里补全 ②）✅
         *  📌 **为什么这不是"给真拨弦加限制"的反面**：⭐ 本用例守的是
         *     **"边沿判决⛔ 不许有【位置】前置条件"** —— ⭐ 只要 `refractory` 过了，
         *     一个真实的比较器边沿**就必须**出声 ✅
         *  ═══════════════════════════════════════════════════════════════════════ */

        //  ⭐ ① `up_async` 保持高 ⇒ ⭐ `both_low` 恒 0 ⇒ ⭐ 真的 `down` 上升沿也必须出声
        repeat (20) @(posedge clk);               // ⭐ 先把 refractory 彻底耗完
        up_async = 1'b1;
        repeat (20) @(posedge clk);               // ⭐ 等同步器（2 级）＋ 耗完 refractory
        event_n = 0;                              // ⭐ 重新计数
        chk("H9 setup: both_low_o is FALSE while the UP line is held (so a position gate could never re-arm)",
            both_low === 1'b0);
        @(negedge clk); down_async = 1'b1;        // ⭐ 真的 `down` 新沿
        @(negedge clk); down_async = 1'b0;
        repeat (6) @(posedge clk);
        chk("H9 a genuine DOWN edge fires even though both_low_o is NEVER true (no position gate)",
            event_n == 1 && event_dir[0] == 1'b0);
        chk("H10b armed_o is still 1'b1 while both_low_o is false (no gate to disarm it)",
            armed === 1'b1);

        //  ⭐ ② 反向：⭐ `down_async` 保持高 ⇒ ⭐ 真的 `up` 上升沿也必须出声
        up_async = 1'b0; down_async = 1'b1;       // ⭐ ⚠️ 这一步本身会产生一个 `down` 上升沿
        repeat (20) @(posedge clk);               // ⭐ 等它出完 ＋ 耗完 refractory
        event_n = 0;
        chk("H9b setup: both_low_o is FALSE while the DOWN line is held",
            both_low === 1'b0);
        @(negedge clk); up_async = 1'b1;          // ⭐ 真的 `up` 新沿
        @(negedge clk); up_async = 1'b0;
        repeat (6) @(posedge clk);
        chk("H9b a genuine UP edge fires even though both_low_o is NEVER true (no position gate)",
            event_n == 1 && event_dir[0] == 1'b1);

        if (errors == 0) $display("PASS: async pluck capture synchronizes edges, prioritizes UP, applies refractory, and imposes no position restriction on a genuine pluck");
        else $fatal(1, "FAIL: async_pluck_capture has %0d error(s)", errors);
        $finish;
    end

    //  ⭐ 2026-10-15（⭐ 缝合 STITCHER）：⭐ 超时预算 **5000 → 12000 ns**
    //     🔴 **为什么**：⭐ H9/H9b 各要"等同步 ＋ 耗完 refractory"（⭐ 约 46 拍）
    //        ⇒ ⭐ 新增约 **92 拍 ＝ 1840 ns**；⭐ 而 `#5000` 是**绝对**超时 ✅
    initial begin #12000; $fatal(1, "FAIL: tb_async_pluck_capture timeout"); end
endmodule
