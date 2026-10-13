`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_axis_snapshot.sv · `axis_snapshot` 自检（⭐ W3a 16 轴原子快照）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **轴号 = 片号×8 + 通道号**（⭐ 两块板 CH 号重复 ⇒ ⛔ 不能只按 CH 号写）
//   ② ⭐⭐ **一个 `sample_valid` 同时写多片**（⭐ 锁步 ⇒ 一拍写 N_ADC 个轴）
//   ③ ⭐ **快照脉冲 = 帧边界**（`frame_done` 后一拍）
//   ④ ⭐⭐ **`delta = 本帧 − 上帧`**（⭐ 滑音/双音判据的原料）
//      ⚠️ **必须带符号**：行程减少 ⇒ delta 为负（⚠️ 这是滑音判据的一半）
//   ⑤ ⭐ **`snap_valid_o` 与 `pos_o`/`delta_o` 同拍**（⭐ `K-109` 同族）
//   ⑥ ⭐ **复位后全 0**（⛔ 不留 X）
//   ⑦ ⭐ **`pos_o` 是本帧值**（⛔ 不是上一帧 —— ⚠️ 这是最容易错的方向）
// ─────────────────────────────────────────────────────────────────────────────

module tb_axis_snapshot;

    localparam integer AXIS_N = 16;
    localparam integer N_ADC  = 2;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;

    integer errors = 0;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    reg                    sample_valid;
    reg  [2:0]             sample_ch;
    reg  [N_ADC*POS_W-1:0] sample_data;
    reg                    frame_done;

    wire                   snap_valid;
    wire [AXIS_N*POS_W-1:0] pos;
    wire [AXIS_N*DW-1:0]    delta;
    wire [AXIS_N-1:0]       axis_seen;

    axis_snapshot #(
        .AXIS_N (AXIS_N),
        .N_ADC  (N_ADC),
        .POS_W  (POS_W),
        .DW     (DW)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_valid_i(sample_valid),
        .sample_ch_i   (sample_ch),
        .sample_data_i (sample_data),
        .frame_done_i  (frame_done),
        .snap_valid_o  (snap_valid),
        .pos_o         (pos),
        .delta_o       (delta),
        .axis_seen_o   (axis_seen)
    );

    task chk;
        input [1023:0] name;
        input          cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ⭐ 取轴 i 的 pos / delta
    function [POS_W-1:0] pget;
        input integer i;
        begin pget = pos[i*POS_W +: POS_W]; end
    endfunction
    function signed [DW-1:0] dget;
        input integer i;
        begin dget = delta[i*DW +: DW]; end
    endfunction

    // ⭐ 送一个通道样本（两片同时给不同值，⭐ 用来验"多片独立"）
    //   🔴 **⚠️ 关键：激励必须在【negEdge】设、在【posEdge】采**
    //      ⚠️ 我第一版在 `@(posedge clk)` 之后直接改信号 ⇒ 🔴 **与 DUT 采样竞争**
    //      ⇒ DUT 采到的是**改之前**的值 ⇒ ⚠️ **测试全假失败**（RTL 其实是对的）。
    //   📌 本项目既有教训：`85 号`/`L55` —— ⭐ **激励要在沿【之前】设好**
    task send_ch;
        input [2:0]       ch;
        input [POS_W-1:0] d0;      // 片 0
        input [POS_W-1:0] d1;      // 片 1
        begin
            @(negedge clk);            // ⭐ 在沿与沿【之间】设激励
            sample_ch    = ch;
            sample_data  = {d1, d0};
            sample_valid = 1'b1;
            @(posedge clk);            // ⭐ 这一拍 DUT 采到
            @(negedge clk);
            sample_valid = 1'b0;       // ⭐ 单周期脉冲
            @(posedge clk);
        end
    endtask

    // ⭐ 扫完一帧：ch 0..7（⭐ 每通道给 d0/d1）
    task scan_frame;
        input [POS_W-1:0] base0;
        input [POS_W-1:0] base1;
        integer c;
        reg [POS_W-1:0] v0, v1;      // ⭐ **先用【定宽】变量接住，再拼接**
        begin
            for (c = 0; c < 8; c = c + 1) begin
                // 🔴 **⚠️ 踩过的坑（2026-09-23，本 tb 第一版）**：
                //    ⚠️ 我原来直接写 `sample_data = {(base1+c),(base0+c)}`，
                //      而 `c` 是 **32 位 `integer`** ⇒ 🔴 **加法表达式整体升到 32 位**
                //      ⇒ **拼接变成 64 位后被截断** ⇒ 🔴 **片 1 的数据被挤掉**
                //      （⭐ 实测：`{12'h900+c, 12'h800+c}` 得到 `000800`，高位**静默丢失**）
                //    ⭐ 正确做法：**先落成 `POS_W` 宽的变量，再拼接**。
                //    📌 这是本项目的老毛病：`83 号` / `L49` —— ⚠️ **位宽不写清 ⇒ 静默截断**。
                v0 = base0 + c[POS_W-1:0];
                v1 = base1 + c[POS_W-1:0];

                @(negedge clk);
                sample_ch    = c[2:0];
                sample_data  = {v1, v0};   // ⭐ 两侧都是定宽 ⇒ ⛔ 不升位
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
            // ⭐ 帧结束（⭐ 同样在 negEdge 设）
            @(negedge clk);
            frame_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            frame_done = 1'b0;
            // ⭐⭐ **等 delta 稳定**：⭐ 快照脉冲在 `frame_done` 后一拍产生，
            //    而 `prev` 在那一拍才更新 ⇒ ⭐ **必须等过那一拍再返回**，
            //    ⚠️ 否则 tb 读到的是【上一帧的 prev】算出来的旧 delta。
            @(posedge clk);   // 快照拍
            @(posedge clk);   // ⭐ 再等一拍，确保 prev/delta 都已稳定
        end
    endtask

    //  ⭐⭐ 2026-10-09（`P0-13`）：⭐ **"真实生产者时序"的帧驱动** ✅
    //   🔴 与 `scan_frame` 的**唯一区别**：⭐ `frame_done` 与 **ch7 的 `sample_valid` 同拍** ✅
    //      📌 真实 `mcp3208_scanner` 就是这样（⭐ 同一个 `always`、同一个 `if (driver_done)`）——
    //         ⚠️ 而老 `scan_frame` 把 `frame_done` 放在 8 个样本**之后 2 拍**（⭐ 比真机宽松 2 拍）
    //         ⇒ 🔴 **这正是老 tb 抓不到 `P0-13` 的原因之一**（⭐ 另一原因是它只判轴 3）✅
    //   📌 只新增、⛔ 不改老任务 ⇒ ⭐ 现有判据的时序一字不变 ✅
    task scan_frame_real;
        input [POS_W-1:0] base0;
        input [POS_W-1:0] base1;
        integer c;
        reg [POS_W-1:0] v0, v1;
        begin
            for (c = 0; c < 8; c = c + 1) begin
                v0 = base0 + c[POS_W-1:0];
                v1 = base1 + c[POS_W-1:0];
                //  ⭐⭐ P0-13 关键：⭐ **`frame_done` 必须比 ch7 的 `sample_valid` 早 1 拍** ✅
                //   📌 真机链路（⭐ 这才是缺陷的成因）：
                //      · `frame_done_i` ← `adc_farm`（⭐ **不延**，⭐ 与 scanner 的 ch7 同拍）
                //      · `sample_valid_i`/`sample_data_i` ← **`calib`**（⭐ **延 1 拍**）
                //      ⇒ ⭐ 所以到达 `axis_snapshot` 时：⭐ `frame_done` **领先** ch7 的 `sample_valid` **1 拍** ✅
                //   ⚠️ 老 `scan_frame` 把 `frame_done` 放在**之后 2 拍** ⇒ 🔴 **方向反了** ⇒ 抓不到 ✅
                if (c == 7) begin
                    @(negedge clk); frame_done = 1'b1;
                    @(posedge clk);
                    @(negedge clk); frame_done = 1'b0;
                end
                @(negedge clk);
                sample_ch    = c[2:0];
                sample_data  = {v1, v0};
                sample_valid = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
                @(posedge clk);
            end
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    integer i;
    integer snap_total = 0;

    // ⭐ 快照脉冲计数（⭐ 用**独立的 always** ⇒ ⛔ 不 fork、⛔ 不干扰帧驱动）
    //   ⚠️ 这就是上一版 `fork` 想做但做砸了的事：⭐ **用 always 计数才是对的**
    always @(posedge clk)
        if (rst_n && snap_valid) snap_total = snap_total + 1;

    //  ⭐⭐ 2026-10-09（`P0-13`）：⭐ **快照当拍锁存 `pos_o`**（⭐ 这就是下游消费者看到的内容）✅
    //   📌 为什么要锁存：⭐ `pos_o` 是**组合输出**（⭐ 由 `cur` 直接组合）
    //      ⇒ ⭐ 必须**在 `snap_valid` 那一拍**采，⛔ 不能等几拍后再读
    //      （⭐ 否则 `cur` 已被本帧后续样本改写 ⇒ 判据失真）✅
    reg [AXIS_N*POS_W-1:0] snap_pos_r;
    always @(posedge clk)
        if (rst_n && snap_valid) snap_pos_r <= pos;

    // ⭐ 判据 ⑤：快照有效时 pos 必须同拍有值（⭐ 组合输出 ⇒ 同拍）
    always @(posedge clk)
        if (rst_n && snap_valid)
            if (pos === {AXIS_N*POS_W{1'b0}})
                $display("FAIL: snap_valid asserted but pos_o was all-zero (valid/data not same-cycle)");

    //  ⭐⭐ 2026-10-11（⭐ `P2-27`）：⭐ **监视"每次快照的 `delta` 是否全 0"** ✅
    //     📌 ⭐ 用途：⭐ 喂**位置恒定**的多帧 ⇒ ⭐ 正确实现下 `delta` 必须**每次全 0** ✅
    //     🔴 ⭐ 未修复时：⭐ **第 1 帧** `delta = cur − 0 = cur` ⇒ ⭐ 这里会涨 ⇒ 判据必红 ✅
    integer delta_bad = 0;
    integer snap_cnt  = 0;
    integer di;
    integer p227_k;
    always @(posedge clk) begin
        if (rst_n && snap_valid) begin
            snap_cnt = snap_cnt + 1;
            for (di = 0; di < AXIS_N; di = di + 1)
                if (delta[di*DW +: DW] != {DW{1'b0}}) delta_bad = delta_bad + 1;
        end
    end

    initial begin
        sample_valid = 1'b0; sample_ch = 3'd0; sample_data = 0; frame_done = 1'b0;

        // ── 复位 ──────────────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ═══ 判据 ⑥ 复位后全 0 ═══
        chk("after reset all 16 axes read 0", pos === {AXIS_N*POS_W{1'b0}});
        chk("after reset all deltas read 0", delta === {AXIS_N*DW{1'b0}});
        chk("after reset axis_seen is 0", axis_seen === {AXIS_N{1'b0}});

        // ═══ 判据 ①② 轴号映射 + 多片同拍写 ═══
        //   ⭐ 送 ch=0，片0 给 0x100，片1 给 0x200
        //   ⇒ ⭐ 轴 0（片0×8+0）应 = 0x100；⭐ 轴 8（片1×8+0）应 = 0x200
        send_ch(3'd0, 12'h100, 12'h200);
        chk("axis 0 (adc0 ch0) holds the adc0 sample", pget(0) === 12'h100);
        chk("axis 8 (adc1 ch0) holds the adc1 sample  [axis = adc*8+ch]", pget(8) === 12'h200);
        chk("ONE sample_valid wrote BOTH chips at once (lockstep)", (pget(0) === 12'h100) && (pget(8) === 12'h200));

        // ⭐ 再来一个通道验证别的轴
        send_ch(3'd3, 12'h333, 12'h444);
        chk("axis 3 (adc0 ch3) correct", pget(3) === 12'h333);
        chk("axis 11 (adc1 ch3) correct", pget(11) === 12'h444);

        // ═══ 判据 ⑦ pos_o 是本帧值 ═══
        //   ⭐ 上一步写的是 cur（本帧）⇒ ⭐ pos_o 必须立刻反映（⛔ 不是上一帧）
        chk("pos_o reflects the CURRENT frame, not the previous one", pget(3) === 12'h333);

        // ═══ 判据 ③④⑤ 快照 + delta ═══
        //   🔴 **⚠️ 我第一版用 `fork ... join` 起了一个"监视快照脉冲"的并行进程** ——
        //      ⚠️ 它和 `scan_frame` **抢同一个时钟沿** ⇒ 🔴 **把帧驱动的节拍打乱**
        //      ⇒ 实测 `delta` 恒 0（⚠️ 而单独顺序跑 `scan_frame` 时 delta 是对的 = +16）。
        //   ⭐ 改成 **顺序驱动 + 计数**（⛔ 不 fork）⇒ ⭐ 判据等价、时序可控。
        //   ⚠️ 计数用上面的 `always`（`snap_total`），⛔ 不用局部变量。

        // 第 1 帧：base 0x800 / 0x900
        scan_frame(12'h800, 12'h900);
        // 第 2 帧：⭐ 全部 +0x10（⭐ 行程【增大】⇒ delta 应为正）
        scan_frame(12'h810, 12'h910);

        //  ⚠️⚠️ 2026-10-11（⭐ `P2-27`）：⭐ **本条判据的期望值必须改** ✅
        //     ⭐ **为什么**：⭐ 新契约是"**第 1 帧不出快照**"（⭐ `primed` 抑制 ✅）
        //        ⇒ ⭐ 前面各段若只跑**单帧**，⭐ 现在**不再产生快照** ✅
        //        ⇒ ⭐ 而 `snap_total` 是**全局**计数（⭐ 从复位起累加 ✅）
        //     📌 ⭐ 本条判据的**原意**是"快照脉冲确实发生了" ✅
        //        ⇒ ⭐ 所以断言 **`>= 1`**（⛔ 不是 `>= 2` —— 那个数字**依赖前面跑了几帧** ⚠️）
        //     ⭐ 新契约的**完整**验证在下面 `P2-27` 段（⭐ 复位后喂恒定位置的多帧 ✅）
        chk("snapshot pulse occurred (frame_done produced snap_valid)", snap_total >= 1);

        // ⭐ 第 2 帧后：delta 应 = +0x10（增大）
        //   ⚠️ 8 个通道都在涨 ⇒ 两个片的所有轴都应 +0x10
        chk("delta is POSITIVE when travel increases (axis 0)", dget(0) === 13'sd16);
        chk("delta is POSITIVE when travel increases (axis 8)", dget(8) === 13'sd16);

        // ═══ 判据 ④ 关键：行程【减少】⇒ delta 必须为【负】═══
        //   ⭐ 这是滑音判据的一半（"先按下的键行程变小"）
        scan_frame(12'h7F0, 12'h8F0);      // ⭐ 比上一帧少 0x20
        chk("delta is NEGATIVE when travel decreases (axis 0)  [slide prerequisite]",
            dget(0) === -13'sd32);
        chk("delta is NEGATIVE when travel decreases (axis 8)",
            dget(8) === -13'sd32);

        // ⭐ 判据：负增量的【符号】必须真的对（⛔ 不是回绕成大正数）
        chk("negative delta is not a wrapped unsigned value", dget(0) < 0);

        //  ═══ ⭐⭐ 2026-10-09（`P0-13`）：⭐ 真实生产者时序下，⭐ 快照里的【最后一轴】必须是【本帧】值 ═══
        //    🔴 **原缺陷**：⭐ `snap_valid_o <= frame_done_i`（延 1 拍）
        //       ⚠️ 而 `cur[7] <= …` 是**非阻塞** ⇒ 要到 `T+2` 才落定
        //       ⇒ 🔴 快照当拍（`T+1`）读到的 `cur[7]`/`cur[15]` 还是**上一帧**的值 ✅
        //       ⇒ ⭐ 轴 7/15 恒滞后一帧（**500 µs**）⇒ ⭐ 和弦跨轴 7/15 时被拆到两帧 ✅
        //    ✅ **修法后**：⭐ `snap_valid_o` 与 `cur[7]` 的写入同源 ⇒ ⭐ 快照里 16 轴**同帧原子** ✅
        //    📌 ⭐ **本判据在未修复代码上必红**（⭐ 实测：`snap_pos_r` 的轴15 = 上一帧的 0x207）✅
        scan_frame_real(12'h100, 12'h200);
        scan_frame_real(12'h300, 12'h400);   // ⭐ 本帧：轴7 = 0x307 · 轴15 = 0x407
        $display("      [dbg] P0-13 快照当拍：轴7=0x%03h（本帧应 0x307）· 轴15=0x%03h（本帧应 0x407）",
                 snap_pos_r[7*POS_W +: POS_W], snap_pos_r[15*POS_W +: POS_W]);
        chk("P0-13 last axis 15 in the snapshot is the CURRENT frame value (real producer timing)",
            snap_pos_r[15*POS_W +: POS_W] === 12'h407);
        chk("P0-13 last axis 7 in the snapshot is the CURRENT frame value (real producer timing)",
            snap_pos_r[7*POS_W +: POS_W] === 12'h307);

        // ═══════════════════════════════════════════════════════════════════
        $display("--- 判据：⭐ P2-27 —— 位置不变 ⇒ 每次快照的 delta 必须【全 0】---");
        // ═══════════════════════════════════════════════════════════════════
        //  🔴 **缺陷（⭐ 审查 `[P2-27]`）**：⭐ `first_ch_of_frame` 复位为 0
        //     ⇒ ⭐ 第 1 帧不固化 `prev` ⇒ ⭐ `prev` 保持复位值 0
        //     ⇒ 🔴 **第 1 帧 `delta = cur − 0 = cur`**（⭐ 最大 +4095 ✅）
        //     📌 ⭐ **为什么现在才修**：⭐ 阶段 2 接上滑音后，
        //        ⭐ "全部轴 delta 都为正且很大" ⇒ ⭐ 双音判据（`dA≥0` 且 `dB≥0`）
        //        在**第 1 帧对所有轴**成立 ⇒ 🔴 **上电 / 重标定后多发一个音** ✅
        //  ✅ **判据**：⭐ 喂【位置完全不变】的多帧 ⇒ ⭐ 每次快照的 `delta` 必须**全 0** ✅
        //     🔴 **未修复时**：⭐ 第 1 帧 `delta = 0x400` ⇒ ⭐ `delta_bad` 涨 ⇒ **必红** ✅
        //     ⭐ **非空洞**：⭐ 还必须**至少出现 1 次快照** ✅
        rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
        repeat (4) @(negedge clk);
        delta_bad = 0; snap_cnt = 0;
        for (p227_k = 0; p227_k < 3; p227_k = p227_k + 1)
            scan_frame(12'h400, 12'h400);        // ⭐ 位置恒定（⭐ 两片同值 ✅）
        chk("P2-27 (non-vacuous) at least one snapshot happened", snap_cnt > 0);
        chk("P2-27 with a CONSTANT position every snapshot delta is 0 (the first frame must not emit)",
            delta_bad == 0);

        $display("");
        if (errors == 0)
            $display("PASS: axis_snapshot maps (adc,ch)->axis, commits all chips in one cycle, emits a per-frame pulse, and produces a SIGNED per-axis delta (the raw material for slide/two-note detection)");
        else
            $fatal(1, "FAIL: axis_snapshot had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
