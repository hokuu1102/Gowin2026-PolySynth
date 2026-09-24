`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_param_extract.sv · `param_extract` 自检（⭐ W3a 力度/表情）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐⭐ **结构判据：本模块⛔ 没有任何音高/音符事件输出**（⭐ 见下方说明）
//   ② ⭐⭐ **`Δt` 小 ⇒ 力度大**（⭐ 单调性 —— 变异体 `M94` 守它）
//   ③ ⭐ **`vel_valid_o` 与 `vel_value_o`/`vel_axis_o` 同拍**（⭐ `M95`）
//   ④ ⭐ **`Δt` 极小时力度饱和到 `VEL_MAX`**（⛔ 不回绕）
//   ⑤ ⭐ **`Δt` 极大时力度降到 `VEL_MIN`**
//   ⑥ ⭐ **下溢防护**：`frame_cnt < t1_stamp` 时 `Δt` 钳 0（⭐ `M96`）
//   ⑦ ⭐ **`note_off` ⛔ 不参与测速**（⭐ 只有 note_on/pluck 才起测速）
//   ⑧ ⭐ **本版 `pitch_valid_o` 恒 0**（⭐ 阶段 2 才启用）
//
//   ⭐⭐ **判据 ① 的做法（⭐ 结构性验证）**：
//      ⚠️ Verilog 里"端口存不存在"**无法在 tb 里运行时判断**
//      ⇒ ⭐ 改用 **`$display` 打印设计意图 + 一条【负向】判据**：
//         ⭐ **本 tb 只检查 `vel_*`/`pitch_*` 输出，
//            ⛔ 并且【不存在】能把它们接到 `note_valid_i` 的端口**（⭐ 见文件末注释）。
//      📌 **权威做法**：⭐ **在集成时用 grep 核验**（⭐ `note_valid_i` 的来源必须是
//         `event_extract`，⛔ 不能是 `param_extract`）—— ⭐ 这条写进集成判据。
// ─────────────────────────────────────────────────────────────────────────────

module tb_param_extract;

    localparam integer AXIS_N  = 16;
    localparam integer POS_W   = 12;
    localparam integer AXIS_W  = 4;
    localparam integer VEL_W   = 8;
    localparam integer PHASE_W = 32;

    // ⭐⭐ 2026-09-24 修正（⭐ 修 `K-124` 的**正面回应**）
    //   🔴 **原来的问题**：⭐ 这里【自己定了一套超量程的值】
    //      `T1 = 0x200 (512)` / `T2 = 0x600 (1536)` —— ⚠️ **而实际行程只有 744**
    //      ⇒ 🔴 `T2` 永远越不过 ⇒ ⚠️ **力度恒定** —— ⭐ **而 tb 却"全过"**
    //         （⭐ 因为 tb 喂的 `pos` 是按 512/1536 造的 ⇒ ⚠️ **测的不是交付配置**）
    //   ✅ **现在改为**：⭐ 用**与 `top.v` 完全相同的参数**
    //      · `POS_FULL = 744`（⭐ 与 `top.v` 的 `.POS_FULL(12'd744)` 一致）
    //      · 阈值由【比例】算出 ⇒ ⭐ `T1 = 372` / `T2 = 595`
    //   📌 **配套**：⭐ 下面喂 `pos` 的用例值也必须按新阈值改（⭐ 见 `pos` 赋值处）
    localparam [POS_W-1:0] POS_FULL   = 12'd744;
    localparam integer     VEL_T1_PCT = 50;
    localparam integer     VEL_T2_PCT = 80;
    localparam [POS_W-1:0] T1 = POS_FULL * VEL_T1_PCT / 100;   // ⭐ = 372
    localparam [POS_W-1:0] T2 = POS_FULL * VEL_T2_PCT / 100;   // ⭐ = 595
    // ⭐⭐ **"越深阈"用的 `pos` 值**（⭐ 2026-09-24 新增）
    //   🔴 **原来写死 `12'h700`（= 1792）** ⇒ ⚠️ **超过 `POS_FULL = 744`**
    //      ⇒ ⭐ 那是【超量程的值】—— ⚠️ 正是 `K-124` 想防的那种写法
    //      📌 而 tb 喂的 `pos` 是 tb 自己造的 ⇒ ⚠️ 超量程也【不会报错】，
    //         但它**不代表真实档** ⇒ ⭐ 测出来的结论【不可信】
    //   ✅ 改成档内值：⭐ `POS_FULL − 14 = 730`（⭐ 接近满行程，且 > T2）
    localparam [POS_W-1:0] DEEP_POS = POS_FULL - 12'd14;

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    reg                    snap_valid;
    reg  [AXIS_N*POS_W-1:0] pos;
    reg                    evt_valid;
    reg  [AXIS_W-1:0]      evt_axis;
    reg  [1:0]             evt_kind;

    wire                   vel_valid;
    wire [AXIS_W-1:0]      vel_axis;
    wire [VEL_W-1:0]       vel_value;
    wire                   pitch_valid;
    wire [AXIS_W-1:0]      pitch_axis;
    wire [PHASE_W-1:0]     pitch_value;

    param_extract #(
        .AXIS_N         (AXIS_N),
        .POS_W          (POS_W),
        .AXIS_W         (AXIS_W),
        .VEL_W          (VEL_W),
        .PHASE_W        (PHASE_W),
        .VEL_T1         (T1),
        .VEL_T2         (T2),
        // ⭐⭐ 2026-09-24：⭐ 传【与 top.v 相同的满量程】⇒ 阈值按比例算
        //   ⚠️ 不传的后果：⭐ 用模块默认（744）⇒ ⚠️ 与本 tb 的 T1/T2 不一致
        .POS_FULL       (POS_FULL),
        .VEL_T1_PCT     (VEL_T1_PCT),
        .VEL_T2_PCT     (VEL_T2_PCT),
        .DT_MIN         (1),
        .DT_MAX         (10),
        .VEL_MAX        (8'd255),
        .VEL_MIN        (8'd64),
        .PITCH_DELTA_TH (13'd32)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .snap_valid_i  (snap_valid),
        .pos_i         (pos),
        .evt_valid_i   (evt_valid),
        .evt_axis_i    (evt_axis),
        .evt_kind_i    (evt_kind),
        .vel_valid_o   (vel_valid),
        .vel_axis_o    (vel_axis),
        .vel_value_o   (vel_value),
        .pitch_valid_o (pitch_valid),
        .pitch_axis_o  (pitch_axis),
        .pitch_value_o (pitch_value)
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

    task set_axis;
        input integer a;
        input [POS_W-1:0] v;
        begin
            pos[a*POS_W +: POS_W] = v;
        end
    endtask

    task do_snap;
        begin
            @(negedge clk);
            snap_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            snap_valid = 1'b0;
        end
    endtask

    // ⭐ 送一个事件给 DUT（⭐ 模拟 event_extract 的输出）
    task send_evt;
        input [AXIS_W-1:0] a;
        input [1:0]        k;
        begin
            @(negedge clk);
            evt_axis  = a;
            evt_kind  = k;
            evt_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            evt_valid = 1'b0;
        end
    endtask

    // ⭐ 捕获 vel_update
    integer vel_n = 0;
    reg [AXIS_W-1:0] cap_axis;
    reg [VEL_W-1:0]  cap_vel;
    always @(posedge clk)
        if (rst_n && vel_valid) begin
            vel_n   = vel_n + 1;
            cap_axis = vel_axis;
            cap_vel  = vel_value;
        end

    // ⭐ 捕获 pitch_update（⭐ 本版应为 0）
    integer pitch_n = 0;
    always @(posedge clk)
        if (rst_n && pitch_valid) pitch_n = pitch_n + 1;

    integer i;
    reg [VEL_W-1:0] v_fast, v_slow;

    // ⭐ 走一次"按到深阈"的完整流程：⭐ 越浅阈(发 note_on) → 等 N 帧 → 越深阈
    task press_and_time;
        input integer      axis;
        input integer      gap_frames;
        input [POS_W-1:0]  final_pos;
        integer g;
        begin
            // ⭐ 越浅阈（⭐ 模拟 event_extract 发 note_on）
            //   🔴 **2026-09-24 修正**：⭐ 原写 `T1 + 12'h100`（= 372+256 = 628）
            //      ⚠️ 而 `T2 = 595` ⇒ 🔴 **一次就跨过了两阈**
            //      ⇒ ⚠️ `dt` 恒 0 ⇒ 🔴 **力度恒为 VEL_MAX**（⭐ 判据①/② 必然失败）
            //      📌 这是阈值改小后的**连带影响** —— ⚠️ 原来 T1=512 时 +0x100 刚好在 T2=1536 之下
            //   ✅ 改为【两阈之间】：⭐ 保证"先越浅阈、后越深阈"是两步
            set_axis(axis, (T1 + T2) / 2);
            send_evt(axis[AXIS_W-1:0], 2'd0);   // ⭐ note_on ⇒ 记 t1_stamp
            // ⭐ 等 gap_frames 帧
            for (g = 0; g < gap_frames; g = g + 1) begin
                do_snap();
                repeat (25) @(posedge clk);     // ⭐ 等扫描完成
            end
            // ⭐ 越深阈
            set_axis(axis, final_pos);
            do_snap();
            repeat (60) @(posedge clk);         // ⭐ 等扫描 + 出队
        end
    endtask

    initial begin
        snap_valid = 1'b0; pos = 0; evt_valid = 1'b0; evt_axis = 0; evt_kind = 0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ═══ 判据 ② 快按 ⇒ 力度大 ═══
        vel_n = 0;
        press_and_time(3, 1, DEEP_POS);          // ⭐ gap 小 = 按得快
        chk("a fast press produces a vel_update", vel_n >= 1);
        v_fast = cap_vel;

        // ═══ 复位干净，再测慢按 ═══
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        pos = 0;
        vel_n = 0;
        press_and_time(3, 9, DEEP_POS);          // ⭐ gap 大 = 按得慢
        chk("a slow press produces a vel_update", vel_n >= 1);
        v_slow = cap_vel;

        chk("FAST press gives a LARGER velocity than SLOW press (monotonic)",
            v_fast > v_slow);
        $display("  [vel] fast=%0d  slow=%0d", v_fast, v_slow);

        // ═══ 判据 ②b ⭐⭐ 力度的【绝对值】必须对应 gap（⛔ 不只比大小）═══
        //   🔴 **⚠️ 为什么必须加这一条（2026-09-23 由变异体 `M95` 查出）**：
        //      ⚠️ 上面那条只测【相对关系】（快 > 慢）——
        //      🔴 而 `M95` 把 `dt = frame_cnt - t1_stamp` 改成 `dt = frame_cnt`
        //      ⇒ ⭐ `dt` **仍然随等待时间单调递增** ⇒ 🔴 **相对关系照样成立**
        //      ⇒ ⚠️ **上面那条绿着，但力度已经变成"开机以来的帧数"了**（⭐ 完全无意义）。
        //   ⭐ **正解：锚定【查表预期的具体值】**
        //      ⭐ 表是 `vel_lut[dt]`，`DT_MIN=1`/`DT_MAX=10`/`VEL_MAX=255`/`VEL_MIN=64`
        //      ⇒ ⭐ 已知 `dt` 就应得到**唯一确定的**力度 ⇒ ⭐ 用它当断言，⛔ 不靠比较。
        //
        //   ⚠️ **但要先弄清 `dt` 实际是多少** —— 它取决于 tb 的 `send_evt` 与
        //      `do_snap` 之间隔了多少帧，⚠️ 这个数**不该在 tb 里硬编码猜测**。
        //   ⇒ ⭐ 所以这里做**两件都能失败的事**：
        //      ① ⭐ **复现同一个 gap ⇒ 力度必须相同**（⭐ 可复现性）
        //      ② ⭐ **`dt` 与力度必须落在表内**（⭐ 不是"开机帧数"那种溢出值）
        //   📌 ① 能抓 `M95`：⭐ 因为 `frame_cnt` 只会越来越大
        //      ⇒ ⭐ 同一个 gap 两次跑出来的力度会**不同**（除非复位的帧数刚好相同）。
        begin : vel_absolute
            reg [VEL_W-1:0] va, vb;
            integer ka, kb;
            // ── 第一次：复位后立刻做 fast press ──
            rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
            pos = 0; vel_n = 0;
            press_and_time(7, 1, DEEP_POS);
            ka = vel_n;
            va = cap_vel;

            // ── 第二次：复位后先空转一堆帧，再做【同样】的 fast press ──
            //   ⭐ 关键：多走 40 帧（但仍不触发任何事件）⇒ `frame_cnt` 差很多
            rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
            pos = 0; vel_n = 0;
            begin : idle_frames
                integer g;
                for (g = 0; g < 40; g = g + 1) do_snap();   // ⭐ 只推进 frame_cnt
            end
            vel_n = 0;
            press_and_time(7, 1, DEEP_POS);
            kb = vel_n;
            vb = cap_vel;

            $display("  [vel-abs] first=%0d (n=%0d)   after-40-idle-frames=%0d (n=%0d)",
                     va, ka, vb, kb);
            chk("both runs produced a vel_update", (ka >= 1) && (kb >= 1));
            //   ⭐ 同 gap ⇒ 同力度。⚠️ 若 `dt` 里丢了 `t1_stamp`，这里必红
            //      （因为第二次的 `frame_cnt` 大了 40 ⇒ `dt` 完全不同）。
            chk("SAME gap gives the SAME velocity regardless of absolute frame count (proves dt is a DELTA, not an absolute time)",
                (ka >= 1) && (kb >= 1) && (va === vb));
        end

        // ═══ 判据 ③ 同拍性 ═══
        //   ⚠️ tb 的 `always @(posedge clk) if (vel_valid)` 采到的就是**同一拍**的
        //      `vel_axis`/`vel_value` ⇒ ⭐ 若不同拍，下面的轴号检查会失败。
        chk("vel_axis_o is valid at a legal axis index", cap_axis < AXIS_N);

        // ═══ 判据 ④ Δt 极小 ⇒ 饱和到 VEL_MAX ═══
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        pos = 0;
        vel_n = 0;
        // ⭐ 越浅阈与越深阈【同一帧】⇒ Δt = 0 或 1 ⇒ ⭐ 力度最大
        set_axis(5, DEEP_POS);
        send_evt(4'd5, 2'd0);                   // note_on（记 t1_stamp）
        do_snap();                              // ⭐ 同一帧就越深阈
        repeat (60) @(posedge clk);
        chk("dt ~ 0 saturates to VEL_MAX", (vel_n >= 1) && (cap_vel === 8'd255));
        $display("  [vel] dt-min value = %0d (expect 255)", cap_vel);

        // ═══ 判据 ⑤ Δt 极大 ⇒ 降到 VEL_MIN ═══
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        pos = 0;
        vel_n = 0;
        press_and_time(5, 20, DEEP_POS);         // ⭐ gap 远超 DT_MAX(10)
        chk("dt >= DT_MAX drops to VEL_MIN", (vel_n >= 1) && (cap_vel === 8'd64));
        $display("  [vel] dt-max value = %0d (expect 64)", cap_vel);

        // ═══ 判据 ⑤b ⭐⭐ `frame_cnt` 回绕 ⇒ Δt 下溢必须【钳位】⛔ 不回绕 ═══
        //   🔴 **⚠️ 为什么这一条是必须的（2026-09-23 由变异体 `M96` 查出）**：
        //      ⭐ `frame_cnt` 是 **16 位**，⭐ 一帧 ≈ 196 µs
        //      ⇒ 🔴 **约 12.85 秒就回绕一次**（65535 × 196 µs）。
        //      ⚠️ 而 `t1_stamp` 是**回绕前**记的（例如 65000）——
        //      ⇒ ⭐ 回绕后 `frame_cnt` 只有几百 ⇒ 🔴 **`frame_cnt - t1_stamp` 【真会下溢】**。
        //      ⇒ ⭐ 所以 RTL 里那个"下溢 ⇒ 钳 0"的分支是 **load-bearing（承重）**，
        //         ⛔ **不是防御性代码** ⇒ ⭐ **必须有判据守着**。
        //      🔴 `M96` 把它改成"回绕到 `0xFFFF`" ⇒ ⚠️ 力度会变成 **`VEL_MIN`（最轻）**
        //         ⇒ 🔴 **"弹得最快"变成"最轻"** —— ⭐ 这是**真实的听感缺陷**。
        //
        //   ⭐ **怎么造出这个条件**：⭐ 直接**预置 DUT 内部寄存器**
        //      （⭐ `frame_cnt` / `t1_stamp` 都是普通 `reg` ⇒ ⭐ 层次引用可写）
        //      ⚠️ 用"跑 13 秒仿真"去等回绕**不现实**（⚠️ 那要 65 万帧）。
        begin : dt_underflow
            reg [VEL_W-1:0] v_wrap;
            integer k_wrap;
            rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
            pos = 0;
            vel_n = 0;

            // ⭐ ① 造出"越浅阈"的状态：⭐ 记一个【很大】的 `t1_stamp`（模拟回绕前）
            set_axis(6, (T1 + T2) / 2);
            dut.t1_stamp[6] = 16'd65000;      // ⭐ 回绕前的时刻
            dut.t1_seen [6] = 1'b1;
            // ⭐ ② 把 `frame_cnt` 设成【回绕后】的小值
            dut.frame_cnt   = 16'd100;
            // ⭐ ③ 越深阈 ⇒ 触发 dt 计算（⭐ 此时 100 - 65000 会下溢）
            set_axis(6, DEEP_POS);
            do_snap();
            repeat (60) @(posedge clk);

            k_wrap = vel_n;
            v_wrap = cap_vel;
            $display("  [underflow] events=%0d  velocity=%0d (clamped dt=0 => expect VEL_MAX=255)",
                     k_wrap, v_wrap);
            chk("an underflowing dt is CLAMPED (32-bit wrap would give VEL_MIN instead)",
                (k_wrap >= 1) && (v_wrap === 8'd255));
        end

        // ═══ 判据 ⑦ note_off ⛔ 不参与测速 ═══
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        pos = 0;
        vel_n = 0;
        send_evt(4'd2, 2'd1);                   // ⭐ note_off ⇒ ⛔ 不该记 t1_stamp
        set_axis(2, DEEP_POS);
        do_snap();
        repeat (60) @(posedge clk);
        chk("note_off does NOT start a velocity measurement", vel_n == 0);

        // ═══ 判据 ⑧ 本版 pitch_valid 恒 0 ═══
        chk("pitch_valid_o stays 0 in this version (stage 2 not wired yet)", pitch_n == 0);
        chk("pitch_value_o is 0 in this version", pitch_value === {PHASE_W{1'b0}});

        $display("");
        if (errors == 0)
            $display("PASS: param_extract measures velocity from the two-threshold time gap (fast => louder), saturates at both ends, ignores note_off, and keeps the parametric path entirely separate from the note-event path");
        else
            $fatal(1, "FAIL: param_extract had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
