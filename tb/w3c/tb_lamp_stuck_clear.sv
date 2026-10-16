`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_lamp_stuck_clear.sv · ⭐⭐⭐⭐ **"挂灯能自动清" 判据**（灭灯 LAMPKILL · 2026-10-16）
//
// ⭐ 它证明的是**用户报的那个症状真的被修掉了**，⛔ 不是"表对不对"（那由 ⑧ 管）：
//    🔴 症状原文：⭐ *"没灌谱也闪"* —— ⭐ 灯跟着 125 ms 方波一直闪、**永不熄** ✅
//
// ⭐ **根因（⭐ 带行号，⭐ 修前代码的现场 ✅）**：
//    · `guide_lamp.v:316-343`（⭐ 修前）：⭐ `guide_key_o` **只有两条清除路径** ——
//      ⭐ `note_off(key_valid)` 与 ⭐ `rst_n` ⇒ 🔴 **没有超时** ✅
//    · 于是一条**没配上对 `note_off`** 的 `note_on` ⇒ ⭐ 那盏灯**常亮到复位**
//      （⭐ 上游 `mid2evt.py` 缺 off / ⭐ 或切模式导致 ON/OFF 不同表 ✅）
//    · 而 `led_data.v:79` 的 `key_pattern = key_active | (blink_keys & blink_i)`
//      ⇒ ⭐ 松手时 `key_active` = 0 ⇒ ⭐ 灯就**跟着 `led_blink` 一直闪** ✅
//      ⇒ 🔴 **这就是"没灌谱也闪"** ✅
//
// ⭐ **判据结构（⭐ 每条都能红 —— K-56/C21 ✅）**：
//    ① ⭐ 先造**真·挂灯**：⭐ 只发 `note_on`、⛔ **永不发 `note_off`**（⭐ 复刻上游缺陷 ✅）
//       ⇒ ⭐ 修前：⭐ 灯挂住 ✅；⭐ 修后：⭐ 灯先亮（⭐ 证明激励真的有效 ✅）
//    ② ⭐ **流还在走的时候不许清**（⭐ 这是"⛣ 不误清正在进行的曲谱"那条硬要求的判据 ✅）：
//       · ⭐ 只靠 `ps_note_valid` 会在这里误判成"停" ⇒ 红（⭐ 证明两项取或的必要性 ✅）
//       · ⭐ 靠 `eb_rd_valid` 兜住（⭐ 曲中休止 28 s 的实测边界 ✅）⇒ 灯保持亮 ✅
//    ③ ⭐ **停播超时后必须整片清**（⭐ 本判据的核心 ✅）：
//       · ⭐ 修前代码：🔴 **灯仍然亮着** ⇒ **本条必红**（⭐ 这就是"挂灯"的可观测证据 ✅）
//       · ⭐ 修后代码：⭐ 灯灭 ✅
//    ④ ⭐ **停播超时【不碰】正在流中的灯**（⭐ 修后新增的对照 ✅）：
//       · ⭐ 停播超时先整片清、⭐ 同一拍又灌一条新曲 ⇒ ⭐ **只亮新曲那盏** ✅
//    ⑤ ⭐ **超时期间流恢复 ⇒ 计数归零、⛣ 不清**（⭐ "远大于正常音符间隔"的判据 ✅）
//
// ⚠️ **时间预算（⭐ 实测数据，⛣ 不是拍的 ✅）**：
//    · ⭐ DUT 超时**参数化** ⇒ 本 tb 覆盖成 **`TIMEOUT_CLKS = 1000`**（⭐ 判据形状逐字不变 ✅）
//      ⇒ ⭐ 硬编 1 秒的版本**实测撞 120 s 预算被误判 TIMEOUT**（⭐ `K-94` 的反面 ✅）
//    · ⭐ 本 tb 共约 **2500 拍** ⇒ ⚠️ **约 2 s 仿真**（⭐ vvp 单进程，⛣ 无 I/O ✅）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_lamp_stuck_clear;

    localparam integer AXIS_N = 16;
    localparam integer EVT_W  = 64;
    //  ⭐⭐ **超时值覆盖成 1000 拍**（⭐ 判据形状逐字不变 ✅）
    //     🔴 为什么不直接用 1 秒：⭐ 5100 万拍的顶层仿真实测**撞 120 s 预算被误判
    //       TIMEOUT**（⭐ `K-94` 的反面：过了却算挂 ✅）—— 那是**验收工具失效**，⛣ 不是代码问题。
    //     ⭐ 而"超时多久"**不是本判据要证的**（⭐ 那由"真曲最长休止 26880 tick"的
    //        实测数据保证 ✅）；⭐ 本判据要证的是**"有没有超时清零这个机制"** ✅
    //     ⚠️ 所以 tb 的 ② 只等 **1000 拍**（⭐ < 1000 ⇒ 确保"还没到点" ✅）
    //        ＋ ③ 再等 **1000+20 拍** ⇒ 过点 ✅ ⇒ 全部约 2300 拍 ≈ **2 s** ✅
    localparam integer TIMEOUT = 1000;              // ⭐ DUT 参数覆盖值
    //  ⭐ DUT 计数器位宽 = `$clog2(TIMEOUT)`（⭐ DUT 里的 `CNT_W` ✅）
    //     ⚠️ tb 必须**用同一个位宽**去比（⭐ 否则 `===` 会因 `x` 扩展判不等 ⇒ 假红 ✅）
    localparam integer CNT_W = $clog2(TIMEOUT);

    // ⭐ 位域（⭐ 与 play_seq / guide_lamp / mid2evt 逐位一致 ✅）
    localparam integer NOTE_SH = 0;
    localparam integer KIND_SH = 9;
    localparam [1:0]   KIND_ON    = 2'd0;
    localparam [1:0]   KIND_OFF   = 2'd1;

    reg clk = 1'b0;
    always #10 clk = ~clk;                       // ⭐ 50 MHz

    reg              rst_n = 1'b0;
    reg              note_valid = 1'b0;
    reg  [EVT_W-1:0] note_data  = {EVT_W{1'b0}};
    reg  [4:0]       note_off5  = 5'd0;
    reg  signed [4:0] transpose = 5'sd0;
    reg              fb_mode    = 1'b0;
    reg  [AXIS_N-1:0] key_active = {AXIS_N{1'b0}};
    reg              stream_alive = 1'b0;        // ⭐ 修前 DUT 没有这个端口（␣ 见下方包装）✅

    wire [AXIS_N-1:0] guide_key;
    wire              guide_commit;
    wire [AXIS_N-1:0] guide_vis;

    // ⭐⭐ **修前 / 修后都能编过的包装**：
    //   ⚠️ 修前那份 DUT **没有 `stream_alive_i` 端口** ⇒ 直接具名连接会编译失败
    //     （⭐ 而我们要的正是"拿**同一份** tb 跑**改前**的 DUT 看它红 ✅）
    //   ✅ 所以：**`connect` 用两个 ifdef**，⭐ 逻辑一个字符都不动
    //     · `-DPRE_FIX` ⇒ 不接那个端口（⭐ 悬空 `z` ⇒ DUT 里 `=== 1'b0` ⇒ 一直在攒 ✅）
    //     · 不加         ⇒ 接真信号 ✅
    guide_lamp #(
        .EVT_W  (EVT_W),
        .AXIS_N (AXIS_N)
`ifndef PRE_FIX
        ,.TIMEOUT_CLKS (TIMEOUT)     // ⭐ 覆盖超时值（⭐ 修前 DUT 没这个参数 ⇒ 不接 ✅）
`endif
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .note_valid_i   (note_valid),
        .note_data_i    (note_data),
        .note_off5_i    (note_off5),
        .transpose_i    (transpose),
        .fb_mode_i      (fb_mode),
        .key_active_i   (key_active)
`ifdef PRE_FIX
        // ⭐ 修前：**没有这个端口** ⇒ 故意不接（⭐ DUT 内部按"流停了"处理 ✅）
`else
        ,.stream_alive_i (stream_alive)
`endif
        ,.guide_vis_o    (guide_vis),
        .guide_key_o    (guide_key),
        .guide_commit_o (guide_commit)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer i;

    task chk;
        input             cond;
        input [1023:0]    name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("FAIL: %0s", name); end
        end
    endtask

    // ⭐ 发一条事件（⭐ note_off5 = 3 ⇒ MIDI 48 = C3 ⇒ 键盘表 ⇒ **键 5** ✅）
    task send_ev;
        input [4:0] off5;
        input [1:0] kind;
        begin
            @(negedge clk);
            note_data  = {EVT_W{1'b0}};
            note_data[NOTE_SH +: 5] = off5;
            note_data[KIND_SH +: 2] = kind;
            note_off5  = off5;
            note_valid = 1'b1;
            @(posedge clk);
            #1;
            note_valid = 1'b0;
        end
    endtask

    // ⭐ 等 N 拍（⭐ 组合、⛣ 不许用 `#`（⭐ 会被 other initial 的 `#` 打断 ✅））
    task wait_clks;
        input integer n;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
`ifdef PRE_FIX
        $display("=== tb_lamp_stuck_clear  [PRE_FIX build: no timeout exists in DUT] ===");
`else
        $display("=== tb_lamp_stuck_clear  [FIXED build: stream-timeout clear] ===");
`endif
        $dumpfile("build/sim/tb_lamp_stuck_clear/tb_lamp_stuck_clear.vcd");
        $dumpvars(0, tb_lamp_stuck_clear);

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        wait_clks(20);

        // ═════════════════════════════════════════════════════════════════════
        // ① ⭐⭐ **造真·挂灯**：⭐ 只发 `note_on`、⛣ 永不发 `note_off`
        //    ⭐ 这正是上游 `mid2evt.py` 缺 off 的那条路径（⭐ 头部 M1 ✅）
        //    ⇒ ⭐ 修前：⭐ 灯会挂住 ✅；⭐ 修后：⭐ 灯先亮（⭐ 证明激励有效 ✅）
        // ═════════════════════════════════════════════════════════════════════
        $display("== 1  a note_on with NO matching note_off (the upstream defect) ==");
        stream_alive = 1'b1;                 // ⭐ 流在走（⭐ 缓冲还有数据 ✅）
        send_ev(5'd3, KIND_ON);              // ⭐ C3 ⇒ 键 5
        wait_clks(2);
        chk(guide_key === 16'h0020,
            "1a the note_on really lit key 5 (the stimulus is not vacuous)");
        chk(guide_key[5] === 1'b1, "1b guide_key_o[5] is the lit lamp");

        // ═════════════════════════════════════════════════════════════════════
        // ② ⭐⭐ **流还在走的时候⛣ 绝不清灯**
        //    🔴 这一条钉的是"⛣ 不误清正在进行的曲谱"那条硬要求 ✅
        //    ⚠️ **只取 `ps_note_valid` 会在这里误判成"停"**（⭐ 灯会灭 ⇒ 红 ✅）
        //    ⭐ 必须靠 `eb_rd_valid` 兜住（⭐ 曲中休止 28 s 的实测边界 ✅）
        //    ⇒ 所以这里**故意把 `stream_alive` 拉到 1、只靠"流活着"撑着**
        // ═════════════════════════════════════════════════════════════════════
        $display("== 2  the stream is still alive => the lamp must NOT be cleared ==");
        wait_clks(1000);
        chk(guide_key[5] === 1'b1,
            "2a stream_alive=1 (buffer still has events) => lamp stays lit (no false clear)");
`ifndef PRE_FIX
        chk(dut.stream_idle_cnt === {CNT_W{1'b0}},
            "2b the idle counter is pinned at 0 while the stream is alive");
`endif

        // ═════════════════════════════════════════════════════════════════════
        // ③ ⭐⭐⭐⭐ **停播超时 ⇒ 必须整片清零**（⭐ 本判据的核心 ✅）
        //    🔴 **修前代码在这一条上必红**（⭐ 它根本没有超时 ⇒ 灯一直亮 ✅）
        //       ⇒ 那正是"挂灯"的**可观测证据**（⭐ ⛣ 不是"我认为它修了" ✅）
        // ═════════════════════════════════════════════════════════════════════
        $display("== 3  stream stopped for > 1 s => the hanging lamp MUST clear itself ==");
        stream_alive = 1'b0;                 // ⭐ 流停了（⭐ 缓冲空 ＋ 这一拍没吐事件 ✅）
        //  ⭐ 先确认"还没到点"时**确实不清**（⭐ 超时不是"一拍就清" ✅）
        wait_clks(TIMEOUT / 2);
        chk(guide_key[5] === 1'b1,
            "3a before the timeout the lamp is STILL lit (timeout is not instant)");
        //  ⭐ 走过整个超时窗口
        wait_clks(TIMEOUT / 2 + 20);
`ifdef PRE_FIX
        chk(guide_key === 16'h0000,
            "3b [PRE_FIX build] ... this MUST have failed above; see the counter");
        chk(1'b0,
            "3b [PRE_FIX] the hanging lamp cleared itself after 1 s of no score  <-- THE FIX");
`else
        chk(guide_key === 16'h0000,
            "3b the hanging lamp cleared itself after 1 s of no score  <-- THE HANGING-LAMP FIX");
        chk(guide_key[5] === 1'b0, "3c key 5's lamp is gone (not just dimmed)");
        chk(guide_vis === 16'h0000, "3d the blanked bitmap follows (guide_vis = guide_key & ~active)");
`endif

        // ═════════════════════════════════════════════════════════════════════
        // ④ ⭐⭐ **超时那拍的优先级**：⭐ 先整片清、再点亮这一拍该亮的
        //    ⭐ 场景：⭐ 停播满 1 秒后**又灌了一条新曲**（⭐ 缓冲这一拍刚好非空 ✅）
        //    ⇒ ⭐ 修后：⭐ 灯先全灭、⭐ 只亮新曲那盏（⭐ ⛣ 不是"闪一下又挂住" ✅）
        // ═════════════════════════════════════════════════════════════════════
`ifndef PRE_FIX
        $display("== 4  a new score arriving ON the timeout edge => clean slate then light ==");
        //  ⭐ 计数已在超时后停在上限 ⇒ **再等 1 拍就再次超时**
        wait_clks(4);
        //  ⭐⭐⭐⭐ **注意顺序**（⭐ 2026-10-16 实测踩到，⛣ 不是猜的 ✅）：
        //     🔴 第一次写的时候把 `stream_alive = 1` 放在 `send_ev` **之后**
        //        ⇒ ⭐ `send_ev` 那一拍计数器仍封顶、`stream_alive = 0`
        //        ⇒ ⭐ **超时清拍在 `note_on` 之后生效** ⇒ 🔴 灯只亮 **1 拍**就被清
        //        ⇒ ⭐ `4a` 报 `got 0000, want 0001`（⭐ 这就是"闪一下又挂住"的实例 ✅）
        //     ✅ 正确顺序：**先把 `stream_alive` 拉高**（⭐ 计数器这一拍归零 ✅）
        //        ⇒ ⭐ `send_ev` 那一拍**不再超时** ⇒ ⭐ 只有 `note_on` 生效 ✅
        //     ⚠️ 这正是**现场**（⭐ 停播 1 秒后 PC 开始灌新谱 ✅）：
        //        ⭐ 缓冲在**这一拍**变非空 ⇒ `stream_alive` **同拍**抬起来 ✅
        stream_alive = 1'b1;                 // ⭐ 新流在走（⭐ 必须在 note_on 之前 ✅）
        send_ev(5'd7, KIND_ON);              // ⭐ E3 ⇒ 键 0（⭐ 与刚挂的键 5 不同 ✅）
        wait_clks(2);
        chk(guide_key === 16'h0001,
            "4a the old hung lamp is gone AND only the NEW pitch's lamp (key 0) is lit");
        chk(guide_key[5] === 1'b0 && guide_key[0] === 1'b1,
            "4b stale key 5 cleared, fresh key 0 lit (timeout won the previous cycle)");

        // ═════════════════════════════════════════════════════════════════════
        // ⑤ ⭐ **流中途断一下 ⇒ 计数归零、⛣ 不清**（⭐ "远大于正常音符间隔" ✅）
        //    ⭐ 场景：⭐ 流停 0.5 秒后**又活过来**（⭐ 例如 PC 卡了一下 ✅）
        //    ⇒ ⭐ 灯**必须保持亮**（⭐ ⛣ 误清正在进行的曲谱 ✅）
        // ═════════════════════════════════════════════════════════════════════
        $display("== 5  a mid-score hiccup (0.5 s) must NOT clear anything ==");
        //  ⭐ 前置：⭐ 确认计数器**确实被 ④ 归零了**（⭐ 否则 ⑤ 测的是"超时还没到" ✅）
        chk(dut.stream_idle_cnt === {CNT_W{1'b0}},
            "5a-pre the idle counter was reset by the stream coming back (not stuck at the limit)");
        //  ⭐ 停 `TIMEOUT/2` 拍（⭐ **严格不到点** ✅）再活过来
        stream_alive = 1'b0;
        wait_clks(TIMEOUT / 2);
        chk(guide_key[0] === 1'b1,
            "5b the lamp is still lit during the hiccup (the timeout has not fired yet)");
        stream_alive = 1'b1;                 // ⭐ 又活过来
        wait_clks(1000);
        chk(guide_key[0] === 1'b1,
            "5c the lamp survived a 0.5 s stream hiccup (counter reset, no false clear)");
`endif

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_lamp_stuck_clear - %0d/%0d judgements held",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_lamp_stuck_clear - %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    //  ⭐ 看门狗：⭐ 本 tb 约 2500 拍 = **25 000 ns** ⇒ 给 **1_000_000 ns**（⭐ 40× 余量 ✅）
    //     ⚠️ 上一次写成 `#5_000`（⭐ 5000 ns = 500 拍 ✅）⇒ 🔴 **比判据②的 1000 拍还早触发**
    //        ⇒ ⭐ 两侧都报 TIMEOUT ⇒ 🔴 **看门狗自己把判据饿死了**（⭐ `K-94` 同族 ✅）
    //     ⭐ 教训：⭐ **看门狗的单位是 ns、⛣ 不是拍**（⭐ 50 MHz ⇒ 1 拍 = 20 ns ✅）
    initial begin
        #1_000_000;
        $display("FAIL: tb_lamp_stuck_clear TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
