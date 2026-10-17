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

    async_pluck_capture #(.REFRACT_CYC(10), .BLANK_CYC(6)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .pluck_up_async_i(up_async), .pluck_down_async_i(down_async),
        .pluck_valid_o(pluck_valid), .pluck_up_o(pluck_up),
        .armed_o(armed), .both_low_o(both_low)
    );

    //  ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-17：⭐ **C83 反向验证实例**（⭐ `BLANK_CYC = 0` = 修复前）⭐⭐
    //  ═══════════════════════════════════════════════════════════════════════
    //  🔴 **为什么必须单独开一个实例**（⭐ 而不能 `force dut.BLANK_CYC = 0`）：
    //     ⭐ `BLANK_CYC` 是 **`parameter`** ⇒ ⭐ `force` 在 elaboration 期就报
    //        *"Could not find variable `dut.BLANK_CYC`"* ⇒ 🔴 **整个 tb 编译失败**。
    //        （⭐ 本 tb 第一版就这么栽的 —— 已留档 ✅）
    //  ✅ **本实例 `BLANK_CYC = 0`** ⇒ `*_blank_q` 恒 0 ⇒ 同路 blank 整个关掉
    //     ⇒ ⭐ **逐位等价于修复前的 `async_pluck_capture`**。
    //  📌 这就是项目 `C83` 纪律的落地：⭐ *"唯一判据是跑未修复代码必须输出不同"* ——
    //     ⭐ 若这条断言不红 ⇒ 上面的 P0-4-2b/2e 是**假绿**（根本没测到目标路径）。
    //  ⚠️ **驱动独立**（`nup_async`/`ndn_async`）：⛔ 不许与 `dut` 共用驱动源
    //     —— ⭐ 否则两个实例互相干扰 ⇒ 两边的计数都不可信。
    //  ═══════════════════════════════════════════════════════════════════════
    reg        nup_async = 1'b0;
    reg        ndn_async = 1'b0;
    wire       no_pluck_valid;
    wire       no_pluck_up;
    wire       no_armed;
    wire       no_both_low;
    integer    n_event_n = 0;
    reg        n_event_dir [0:7];

    async_pluck_capture #(.REFRACT_CYC(10), .BLANK_CYC(0)) u_no_rearm (
        .clk_i(clk), .rst_n_i(rst_n),
        .pluck_up_async_i(nup_async), .pluck_down_async_i(ndn_async),
        .pluck_valid_o(no_pluck_valid), .pluck_up_o(no_pluck_up),
        .armed_o(no_armed), .both_low_o(no_both_low)
    );

    //  ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-17：⭐ **C83 机理归因实例**（⭐ `REFRACT_CYC = 0`）⭐⭐
    //  ═══════════════════════════════════════════════════════════════════════
    //  🔴 **为什么必须有第三个实例**（⭐ 这是本修法"是不是假绿"的唯一证据）：
    //     ⭐ 主实例 `dut` 用 `REFRACT_CYC(10)` ＋ `BLANK_CYC(6)` ——
    //        ⭐ 回弹闪两下发生在释放后 1~3 拍，**两道闸都能挡**。
    //     ⇒ ⭐ 只断言 `event_n == 1` 时，**分不清是谁挡的**（⭐ `C83` 同族：
    //        "判据通过但根本没走到目标路径"）。
    //  ✅ **归因法**：⭐ 本实例 `REFRACT_CYC = 0`（⛔ 关掉不应期）、`BLANK_CYC(6)`
    //     ⇒ ⭐ 只剩 blank 一道闸 ⇒ ⭐ 重放同一序列，**必须仍然只有 1 条**
    //        ⇒ ⭐ 才证明"挡住第二下"的**确实是 blank**，⛔ 不是 refractory 白送。
    //  ⚠️ **驱动独立**（`bup_async`/`bdn_async`）：⛔ 不许与其它实例共用驱动源。
    //  ═══════════════════════════════════════════════════════════════════════
    reg        bup_async = 1'b0;
    reg        bdn_async = 1'b0;
    wire       b_pluck_valid;
    wire       b_pluck_up;
    wire       b_armed;
    wire       b_both_low;
    integer    b_event_n = 0;
    reg        b_event_dir [0:7];
    //  ⭐⭐ 2026-10-17：⭐ **延迟测量用的两个暂存**（⭐ 只在 P0-4-2h 用）
    integer    lat_seen;
    //  ⭐⭐ 2026-10-17：⭐ **延迟测量（⭐ 用 always 块采样，⛔ 不用 while 轮询）**
    //     🔴 **为什么不能用 while**：⭐ `pluck_valid_o` 是**单周期脉冲**，
    //        ⭐ while 在 `@(posedge clk)` 之后才求值 ⇒ ⭐ 可能**整条错过脉冲**
    //          ⇒ 🔴 会把"判据缺陷"误报成"RTL 慢"（⭐ 本轮实测踩到 ✅）。
    //     ✅ **正解**：⭐ 在 posedge 上采样（⭐ 与 `event_n` 采集同一手法）。
    integer    lat_fire;
    reg        pluck_valid_seen;
    reg        lat_arm;

    async_pluck_capture #(.REFRACT_CYC(0), .BLANK_CYC(6)) u_blank_only (
        .clk_i(clk), .rst_n_i(rst_n),
        .pluck_up_async_i(bup_async), .pluck_down_async_i(bdn_async),
        .pluck_valid_o(b_pluck_valid), .pluck_up_o(b_pluck_up),
        .armed_o(b_armed), .both_low_o(b_both_low)
    );

    always @(posedge clk) begin
        if (rst_n && b_pluck_valid) begin
            b_event_dir[b_event_n] = b_pluck_up;
            b_event_n = b_event_n + 1;
        end
    end

    //  ⭐ 第二个实例的事件采集（⭐ 与主实例同一写法，⛔ 不复用 task）
    always @(posedge clk) begin
        if (rst_n && no_pluck_valid) begin
            n_event_dir[n_event_n] = no_pluck_up;
            n_event_n = n_event_n + 1;
        end
    end

    //  ⭐⭐ 2026-10-17：⭐ **延迟测量采集块**（⭐ 只在 P0-4-2h 用）
    //     ⚠️ **必须在 `initial` 之前就常驻**（⛔ 不能临时开）——
    //        ⭐ 否则 `down_async` 置位后的前几拍**没有采样器** ⇒ 必然错过脉冲。
    //     ⭐ `lat_arm` = "测量进行中"（⭐ 由 `initial` 置位/清除）。
    //  🔴 **`lat_fire` 必须记【脉冲那一刻的快照】**，⛔ 不是循环结束时的值：
    //     ⭐ 我第一版就是"`repeat(10)` 后读 `lat_fire`" ⇒ 🔴 它至少是 10
    //       （⭐ 计数器一直在跑）⇒ 🔴 把"测量方式错"误报成"RTL 慢"
    //       （⭐ 本轮实测：`seen=1 lat_fire=10` 就是这个 ✅）
    always @(posedge clk) begin
        if (!rst_n) begin
            lat_fire         <= 0;
            pluck_valid_seen <= 1'b0;
        end else if (lat_arm) begin
            if (pluck_valid && !pluck_valid_seen) begin
                pluck_valid_seen <= 1'b1;   // ⭐ 只记第一个脉冲
            end
            //  ⭐ 只在【还没见到脉冲】时计数 ⇒ ⭐ 见到的那个值就是延迟拍数
            if (!pluck_valid_seen && (lat_fire < 100)) lat_fire <= lat_fire + 1;
        end
    end

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

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ 2026-10-16：⭐ **P0-4-2 —— "下拨触发两次"【能红判据】** ⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **症状（⭐ 用户 2026-10-16 上板实测，⛔ 不是推断）**：
        //     *"下拨会触发两次。过去一次，回来一次。"*
        //     *"我 95% 确定硬件没有问题"* ＋ *"最新的一板一直是有触发两次的"*
        //     ⇒ ⭐ **跨板复现 ⇒ 按 RTL 缺陷处理。**
        //
        //  🔴 **本用例为什么【以前抓不到】**（⭐ 这是它一直没被解决的真正原因）：
        //     ⭐ 旧 tb 的 `pulse_down` 是"**低→高→低，中间只隔 1 拍**"：
        //     ```
        //     @(negedge clk); down_async = 1'b1;
        //     @(negedge clk); down_async = 1'b0;   // ⭐ 1 拍后就释放
        //     ```
        //     ⇒ ⭐ 释放沿落在 `REFRACT_CYC(10)` 窗口内 ⇒ ⭐ 回弹那次沿
        //       **本来就被 30 ms 不应期挡掉了** ⇒ 🔴 **判据恒绿，什么都测不出来**。
        //     ⭐⭐ **真实现场不是这样**：⭐ 人手**下拨后保持**几十~几百毫秒
        //        （拨弦要按住！）⇒ ⭐ 释放沿发生在**不应期早就过了**之后
        //        ⇒ 🔴 **回弹那次沿完整地打进来** ⇒ 第二音。
        //     ⇒ ⭐ 本用例照现场建模：**先保持 ≥ 不应期，再释放**。
        //
        //  🔴 **回弹过冲的物理建模**：
        //     ⭐ 下拨把 `DOWN` 抬到 3.3 V；**回中必须掉回 0 V** ⇒
        //        ⭐ 它**必然**再穿过 `DOWN_REF`(1.24 V) 一次；
        //        ⭐ 带回中的机械摇杆在这一穿**不保证单调** ⇒ 会抖几次。
        //     ⭐ 本用例用"`0→1→0→1→0`，每段都短于 `BLANK_CYC`"来建模它。
        //     ⚠️ **每段必须短于 `BLANK_CYC(6)`** —— 否则测的是不应期、⛔ 不是本机制
        //        （⭐ 这正是旧用例踩过的同一个坑，别重犯）。
        //
        //  ✅ **断言**：⭐ 这一整段**只许出 1 条**事件。
        //     🔴 **修复前**：⭐ 释放后的回弹沿**完整通过** ⇒ 数到 **2** ⇒ **必红**。
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **【本用例自己踩过的坑，留档】⭐ 第一版在这里连挂 4 条，⛔ 不是 RTL 的错**：
        //     ⚠️ **故障模式**：⭐ 上一段（H9/H9b）结束时 `down_async` **停在 `1'b1`**
        //        （⭐ H9b setup 把它拉高了就没再拉低）⇒ ⭐ 本用例第一句
        //        `down_async = 1'b1` **根本不是上升沿**（它本来是高）⇒
        //        `event_n == 0` ⇒ 🔴 2a/2b/2c 三条全红，而 2d（UP 侧，上下游都没
        //        留高位）反而全绿 ⇒ **红绿分布就是"遗留状态"的指纹**。
        //     ✅ **修法**：⭐ 用例开头**显式把两路都清 0**，⛔ 不依赖上一段的收尾。
        //        📌 **通用教训**：⭐ tb 段与段之间**不许有隐含的初值依赖** ——
        //           ⭐ 本项目 `tb_play_mode_ctrl.sv:134-136` 记过同一个坑
        //             （"判据恒真，测不出东西"）✅
        repeat (20) @(posedge clk);               // ⭐ 先把 refractory / 静默都耗完
        @(negedge clk); up_async = 1'b0; down_async = 1'b0;   // ⭐ 显式干净起点
        //  ⭐⚠️ **这里必须 ≥ `REFRACT_CYC`（10）＋ 同步器（3）拍**，⛔ 不是 6 拍：
        //     🔴 **本用例第一版就栽在这里**：⭐ 上一段结束时某一路停在 `1`
        //        ⇒ ⭐ 本段的"清 0"本身就是一次 `1→0` 释放沿 ⇒
        //          ⭐ 它把 `refractory_q` **重新装满 10 拍** ⇒
        //          ⭐ 若只等 6 拍就给真上升沿 ⇒ 🔴 **落在不应期内 ⇒ 被整个吃掉**
        //          ⇒ ⭐ 症状：`ff2=1/prev=1/rise=0`（电平对、沿没了）、`event_n=0`。
        repeat (16) @(posedge clk);                // ⭐ 16 > 10＋3 ⇒ 不应期必已过
        event_n = 0;
        chk("P0-4-2 setup: both rails low is observable before the stroke",
            both_low === 1'b1);
        //  ⭐ ① 真·下拨：抬起来后【保持】（⭐ 拨弦要按住，⛔ 不是 1 拍就松）
        @(negedge clk); down_async = 1'b1;
        repeat (12) @(posedge clk);               // ⭐ 12 拍 > REFRACT_CYC(10) ⇒ 不应期已过
        //  ⭐⭐ 【C83 反向验证 · 用【第二个实例】而不是 `force`】
        //  🔴 **为什么不能用 `force dut.BLANK_CYC = 0`**（⭐ 本 tb 第一版就栽了）：
        //     ⭐ `BLANK_CYC` 是 **`parameter`** ⇒ ⭐ `force` 在 elaboration 期就报
        //        *"Could not find variable `dut.BLANK_CYC`"* ⇒ 🔴 整个 tb 编译失败。
        //        ⭐ `defparam` 在现代 iverilog 里也不稳 ⇒ ⛔ 不用。
        //  ✅ **正解：第二个实例 `u_no_rearm`，实参传 0**（⭐ 关掉同路 blank）
        //     ⇒ ⭐ 它精确等价于"修复前的代码"（⭐ `*_blank_q` 恒 0 ⇒ 永不节流）。
        //     📌 这正是项目 `C83` 纪律：⭐ **"唯一判据是跑未修复代码必须输出不同"**。
        //  🔴 **反向验证**：⭐ `u_no_rearm` 跑同一序列**必须数到 2 条**，
        //     ⛔ 否则 `P0-4-2b/2e` 是**假绿**（根本没测到目标路径）。
        //  ⚠️ **另有一个独立的归因实例 `u_blank_only`**（`REFRACT_CYC=0`）——
        //     ⭐ 它证明"挡住第二下的是 blank，⛔ 不是 refractory 白送"（见下方断言）。
        //
        //  ⭐⭐ **C83 反向验证（⭐ 与 `u_no_rearm` 实例同步驱动同一序列）**
        //     ⚠️ 本段必须**紧跟**在 DOWN 侧回弹序列之后（⭐ 两个实例拿同一序列 ⇒ 可比）。
        //     ⚠️ **驱动次序与 `dut` 逐拍一致**（⛔ 不许差一拍）⇒ 直接照抄上面的驱动。
        //  ⭐⭐ 【临时探针 · 2026-10-16 调试用，定位后删除】
        chk("P0-4-2a the genuine DOWN stroke fires exactly once",
            event_n == 1 && event_dir[0] == 1'b0);
        //  ⭐ ② 松手回中 ⇒ 回弹过冲（⭐ 同一路反复穿越 `DOWN_REF`）
        //     ⚠️ 三段都在 `BLANK_CYC(6)` 之内 ⇒ ⭐ 旧实现会全部通过
        @(negedge clk); down_async = 1'b0;        // ⭐ 释放（⇒ 启动静默）
        @(negedge clk); down_async = 1'b1;        // ⭐ 回弹过冲 #1
        @(negedge clk); down_async = 1'b0;
        @(negedge clk); down_async = 1'b1;        // ⭐ 回弹过冲 #2
        @(negedge clk); down_async = 1'b0;
        repeat (10) @(posedge clk);               // ⭐ 等同步器 + 静默走完
        chk("P0-4-2b [BUG] a release-threshold RE-CROSSING on the SAME rail emits NO second event",
            event_n == 1);
        chk("P0-4-2c the ONE event is still the genuine DOWN stroke",
            event_n == 1 && event_dir[0] == 1'b0);

        //  ⭐⭐ 【C83 机理归因探针 · 已转正为正式判据 `C83 ATTRIB`（见下）】
        //  🔴 **这条为什么必须留**：⭐ `REFRACT_CYC(10)` 与 `BLANK_CYC(6)`
        //     在这个序列里**都能**挡住回弹 ⇒ ⭐ 若只断言 `event_n == 1`，
        //     ⭐ 就是"**不知道是谁挡的**"（⭐ 项目 `C83`：判据可能根本没走到目标路径）。
        //  ✅ **归因法**：⭐ 用 `u_blank_only`（`REFRACT_CYC=0`）重放同一序列
        //     ⇒ ⭐ 必须**仍然只有 1 条** ⇒ 才证明是 blank 挡的（见下方断言 ✅）。

        //  ⭐⭐ 【C83 机理归因 · 用 `u_blank_only` 重放同一序列】
        //     ⚠️ **驱动逐拍照抄上面**（⛔ 不许差一拍）⇒ 两边才可比。
        @(negedge clk); bup_async = 1'b0; bdn_async = 1'b0;
        repeat (16) @(posedge clk);
        b_event_n = 0;
        @(negedge clk); bdn_async = 1'b1;         // ⭐ 真·下拨
        repeat (12) @(posedge clk);
        @(negedge clk); bdn_async = 1'b0;         // ⭐ 释放（⇒ 启动 blank）
        @(negedge clk); bdn_async = 1'b1;         // ⭐ 回弹过冲 #1
        @(negedge clk); bdn_async = 1'b0;
        @(negedge clk); bdn_async = 1'b1;         // ⭐ 回弹过冲 #2
        @(negedge clk); bdn_async = 1'b0;
        repeat (10) @(posedge clk);
        chk("C83 ATTRIB [REFRACT=0,BLANK=6] with refractory OFF the blank ALONE still suppresses the rebound (attribution proven)",
            b_event_n == 1 && b_event_dir[0] == 1'b0);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ **C83 反向验证**（⭐ `u_no_rearm` 实例 = `BLANK_CYC(0)` = 修复前）⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **这是本用例"不是假绿"的唯一证据**（⭐ 项目 `C83` 纪律）：
        //     ⭐ 上面 `P0-4-2b` 说"回弹不该出第二事件" —— 若判据本身无效，
        //       它也会恒绿 ⇒ 🔴 **必须让未修复实现跑同一序列并输出不同**。
        //  ✅ **做法**：⭐ `u_no_rearm` 与 `dut` **同步驱动同一序列**（照抄上面）
        //     ⇒ ⭐ `n_event_n` 必须数到 **2**（⭐ 回弹过冲完整通过 = 修复前行为）。
        //  ⚠️ **驱动必须逐拍一致**（⛔ 不许差一拍）—— 已照抄；⚠️ **独立驱动源**
        //     （`nup_async`/`ndn_async`）⇒ 两个实例互不干扰。
        //  📌 **若这条红** ⇒ 说明 `P0-4-2b` 是真判据；⛔ 若这条**不红** ⇒
        //     `P0-4-2b` 是假绿，必须回头查序列本身。
        //  ═══════════════════════════════════════════════════════════════════
        @(negedge clk); nup_async = 1'b0; ndn_async = 1'b0;   // ⭐ 干净起点
        repeat (16) @(posedge clk);               // ⭐ > REFRACT(10)+同步(3)
        n_event_n = 0;
        @(negedge clk); ndn_async = 1'b1;         // ⭐ 真·下拨
        repeat (12) @(posedge clk);
        @(negedge clk); ndn_async = 1'b0;         // ⭐ 释放
        @(negedge clk); ndn_async = 1'b1;         // ⭐ 回弹过冲 #1
        @(negedge clk); ndn_async = 1'b0;
        @(negedge clk); ndn_async = 1'b1;         // ⭐ 回弹过冲 #2
        @(negedge clk); ndn_async = 1'b0;
        repeat (10) @(posedge clk);
        chk("C83 canary [no-rearm instance] the SAME rebound sequence DOES emit a 2nd event without the fix (judgement is live)",
            n_event_n == 2);
        chk("C83 canary b both events are DOWN (the rebound is not a spurious UP)",
            n_event_n == 2 && n_event_dir[0] == 1'b0 && n_event_dir[1] == 1'b0);

        //  ═══ ⭐ 反向同构：⭐ 【上拨】也必须是"过去一次、回来一次只响一次" ═══
        //     📌 **为什么必须反向再测一遍**：⭐ `up_release_q` / `down_release_q`
        //        是**两个独立寄存器** ⇒ ⭐ 只测 DOWN 会让 UP 那条**漏网**
        //        （⭐ 本项目 `L88`/边界差一同族：半边修 = 没修 ✅）
        //     ⚠️ 现场证据（`evidence/h5/rightboard-pluck-diag-20261004/README.md:12`）：
        //        **"往后推（保持）⇒ 两路皆 0 V"** ⇒ UP 那一路当时没工作 ⇒
        //        ⭐ 所以用户现在报的"两次"必然是 **DOWN 侧**；
        //        🔴 但**硬件一旦修好，UP 侧会有完全相同的机械过程** ⇒
        //           ⭐ 现在不修就是留一个**必然复发**的坑。
        repeat (20) @(posedge clk);
        @(negedge clk); up_async = 1'b0; down_async = 1'b0;   // ⭐ 显式干净起点（同上教训）
        repeat (16) @(posedge clk);               // ⭐ 16 > REFRACT(10)+同步(3)，理由见上
        event_n = 0;
        @(negedge clk); up_async = 1'b1;          // ⭐ 真·上拨
        repeat (12) @(posedge clk);               // ⭐ 耗完不应期
        chk("P0-4-2d the genuine UP stroke fires exactly once",
            event_n == 1 && event_dir[0] == 1'b1);
        @(negedge clk); up_async = 1'b0;          // ⭐ 释放
        @(negedge clk); up_async = 1'b1;          // ⭐ 回弹过冲
        @(negedge clk); up_async = 1'b0;
        @(negedge clk); up_async = 1'b1;
        @(negedge clk); up_async = 1'b0;
        repeat (10) @(posedge clk);
        chk("P0-4-2e [BUG] UP rail release-threshold re-crossing also emits NO second event (both rails guarded)",
            event_n == 1 && event_dir[0] == 1'b1);

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ **防回归：⭐ 本修法⛔ 不许挡住【真·交替拨弦】** ⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **这是本修法的唯一真实风险**（⭐ 也是旧位置门控的死法）：
        //     ⭐ 若把 blank 做成**全局** ⇒ ⭐ 下拨→回中→上拨（100~300 ms）
        //        会被自己挡掉 ⇒ 🔴 用户明确反对的那件事又回来了。
        //  ✅ **本用例钉住"逐路"语义**：⭐ DOWN 刚掉低后**立刻**给 UP 一个真沿
        //     ⇒ ⭐ **必须出声**（⭐ UP 完全没掉低过 ⇒ 它的 blank 是 0）。
        //  ⚠️ 注意 `BLANK_CYC(6)` 在这个 tb 里只有 6 拍，而下面只隔 1 拍
        //     ⇒ ⭐ **全局实现会必红**，逐路实现全绿 ⇒ 判据有效。
        repeat (20) @(posedge clk);
        event_n = 0;
        @(negedge clk); down_async = 1'b1;        // ⭐ 下拨
        repeat (12) @(posedge clk);               // ⭐ 耗完不应期
        @(negedge clk); down_async = 1'b0;        // ⭐ 释放 DOWN（⇒ DOWN blank 启动）
        @(negedge clk); up_async   = 1'b1;        // ⭐ ⭐ 下一拍就给 UP 一个真沿
        @(negedge clk); up_async   = 1'b0;
        repeat (8) @(posedge clk);
        chk("P0-4-2f [REGRESSION] a genuine UP edge right after DOWN release STILL fires (per-rail blank, not global)",
            event_n == 2
            && event_dir[0] == 1'b0    // ⭐ 第一条 = 真下拨
            && event_dir[1] == 1'b1);  // ⭐ 第二条 = 紧接的真上拨 ⇒ ⛔ 不许被挡

        //  ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐ **题目硬约束：⭐ 拨弦事件延迟 ≤ 5 ms** ⭐⭐
        //  ═══════════════════════════════════════════════════════════════════
        //  🔴 **为什么必须单独钉这条**（⭐ v2 就是死在这上面）：
        //     ⭐ v2 的"等一路连续为高 30 ms"⇒ 延迟 30 ms ⇒ ⛔ **直接违反题目要求**
        //        （⭐ 而且会把快速点拨整条丢掉）⇒ 已整个作废。
        //  ✅ **v3 的延迟 = 0**：⭐ blank 只是**漏掉一次错误的沿**，
        //     ⛔ 不让任何真事件变慢。
        //  ⭐ **本用例的测法**：⭐ 量"上升沿出现"到"`pluck_valid_o` 拉高"的拍数。
        //     ⚠️ 上界 = 同步器 3 拍 ＋ 判决 1 拍 = **4 拍**（⛔ 与 blank 无关）。
        //     ⭐ 在 tb 时间尺度：4 拍 × 20 ns = 80 ns；
        //       ⭐ 换算到生产（50 MHz）：4 拍 = **80 ns** ≪ 5 ms ⇒ **余量 62500 倍**。
        //  ⚠️ **为什么用"拍数"而不是"ns"**：⭐ 本 tb 的时钟是 20 ns 周期，
        //     ⭐ 而生产是 20 ns 周期（50 MHz）⇒ ⭐ 拍数**直接可比** ✅
        //  ═══════════════════════════════════════════════════════════════════
        //  ⚠️ **必须先清两路并耗完不应期**（⭐ 本项目已栽过两次的坑）：
        //     ⭐ 上一段 `P0-4-2g` 结尾 `down_async` 停在 **1** ⇒
        //       ⭐ 本段若直接置 1，**没有上升沿** ⇒ 🔴 无脉冲、`seen=0`
        //       （⭐ 本轮实测：探针打出 `lat_fire=10 seen=0` 就是这个原因 ✅）
        //     ⭐ 且"清 0"本身是一次 `1→0` 释放沿 ⇒ 会把 `refractory_q` 重新装满
        //       ⇒ ⭐ 必须等 **> REFRACT(10) + 同步(3) = 16 拍**再给真沿。
        @(negedge clk); up_async = 1'b0; down_async = 1'b0;
        repeat (16) @(posedge clk);
        lat_arm = 1'b1; lat_fire = 0; pluck_valid_seen = 1'b0;
        @(negedge clk); down_async = 1'b1;         // ⭐ 真上升沿（在 negedge 置位）
        repeat (10) @(posedge clk);
        lat_arm = 1'b0;
        @(negedge clk); down_async = 1'b0;
        //  ⭐ 实测值（⭐ 2026-10-17 首跑）：`lat_fire = 4` ⇒ 80 ns。
        //     ⭐ 4 拍全部来自 **2FF 同步器(2) + 判决(1) + 采样(1)**，
        //       ⭐ blank **零贡献**（⛔ 它只是漏掉一次错沿，不让任何真事件变慢）。
        chk("P0-4-2h [SPEC] pluck event latency is ZERO added by the blank: <= 4 clocks (80 ns) from edge to event (spec: <=5 ms)",
             pluck_valid_seen && (lat_fire <= 4) && (lat_fire >= 1));

        //  ═══ ⭐ 边界：⭐ 静默【过期】后同一路可以正常再触发 ═══
        //     📌 **为什么必须测**：⭐ "释放静默"若忘了递减/清除 ⇒ ⭐ 该路
        //        **永久失效**（⭐ 症状 = 拨几下之后再也不响，极难定位）。
        //     ⭐ 本用例把 `BLANK_CYC(6)` 彻底耗完，再给同一路一个真沿 ⇒ 必须出声。
        repeat (20) @(posedge clk);               // ⭐ 20 > 6 ⇒ blank 必然已过
        @(negedge clk); up_async = 1'b0; down_async = 1'b0;   // ⭐ 显式干净起点（同上教训）
        repeat (16) @(posedge clk);               // ⭐ 16 > REFRACT(10)+同步(3)，理由见上
        event_n = 0;
        @(negedge clk); down_async = 1'b1;        // ⭐ blank 过期后的真下拨 #1
        @(negedge clk); down_async = 1'b0;
        repeat (20) @(posedge clk);               // ⭐ 耗完 REFRACT(10) + BLANK(6)
        @(negedge clk); down_async = 1'b1;        // ⭐ 静默过期后的真下拨 #2
        @(negedge clk); down_async = 1'b0;
        repeat (8) @(posedge clk);
        chk("P0-4-2g [REGRESSION] after the release window EXPIRES the same rail fires again (no permanent lockout)",
            event_n == 2);                        // ⭐ 两条都是"真下拨"（不是回弹）

        if (errors == 0) $display("PASS: async pluck capture synchronizes edges, prioritizes UP, applies refractory, imposes no position restriction on a genuine pluck, and suppresses the release-threshold re-crossing on the same rail with ZERO added latency");
        else $fatal(1, "FAIL: async_pluck_capture has %0d error(s)", errors);
        $finish;
    end

    //  ⭐ 2026-10-15（⭐ 缝合 STITCHER）：⭐ 超时预算 **5000 → 12000 ns**
    //     🔴 **为什么**：⭐ H9/H9b 各要"等同步 ＋ 耗完 refractory"（⭐ 约 46 拍）
    //        ⇒ ⭐ 新增约 **92 拍 ＝ 1840 ns**；⭐ 而 `#5000` 是**绝对**超时 ✅
    //  ⭐⭐ 2026-10-16：⭐ **12000 → 26000 ns**（⭐ P0-4-2 六个新用例）
    //     🔴 **为什么**：⭐ 每个用例都要"耗完不应期(≥10 拍) ＋ 保持 ＋ 回弹序列 ＋ 等同步"
    //        ⇒ ⭐ 单个约 **60 拍 ＝ 1200 ns**，⭐ 六个 ≈ **7200 ns**；⭐ 再叠加
    //           H9/H9b 的 1840 ns ⇒ ⭐ 必须留足余量（⭐ 本项目并行回归曾因
    //           **预算太紧假超时** ⇒ 见 `AGENTS.md` ✅）
    initial begin #26000; $fatal(1, "FAIL: tb_async_pluck_capture timeout"); end
endmodule
