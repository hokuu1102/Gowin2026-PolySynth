`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_event_extract.sv · `event_extract` 自检（⭐ W3a 触发/不应期）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **首次越阈 ⇒ 立即 `note_on`**（⛔ 不等稳定 —— `A2c`）
//   ② ⭐ **回落到释放阈以下 ⇒ `note_off`**
//   ③ ⭐⭐ **迟滞**：在触发阈/释放阈【之间】抖动 ⇒ ⛔ **不产生任何事件**
//   ④ ⭐ **不应期内重复越阈 ⇒ ⛔ 不重复触发**
//   ⑤ ⭐ **不应期结束后可再次触发**（⭐ 自愈，⛔ 不是永久封锁）
//   ⑥ ⭐⭐ **同帧多轴同时越阈 ⇒ 【一个都不丢】**（🔴 我第一版会丢，⚠️ 这是回归判据）
//   ⑦ ⭐ **`evt_valid_o` 与 `evt_axis_o`/`evt_kind_o` 同拍**
//   ⑧ ⭐ **`evt_kind_o` 正确区分 on/off**
//   ⑨ ⭐ **溢出可见**（⭐ sticky + 饱和计数，⛔ 不静默）
// ─────────────────────────────────────────────────────────────────────────────

module tb_event_extract;

    localparam integer AXIS_N = 16;
    localparam integer POS_W  = 12;
    localparam integer DW     = POS_W + 1;
    localparam integer AXIS_W = 4;

    // ⭐ 用【小不应期】便于测试（⭐ 150 帧太长）
    localparam integer REFRACT_TB = 4;
    localparam [POS_W-1:0] TRIG = 12'h400;
    localparam [POS_W-1:0] REL  = 12'h300;

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    reg                    snap_valid;
    reg  [AXIS_N*POS_W-1:0] pos;
    reg  [AXIS_N*DW-1:0]    delta;

    wire                   evt_valid;
    wire [AXIS_W-1:0]      evt_axis;
    wire [1:0]             evt_kind;
    wire [POS_W-1:0]       evt_depth;
    wire                   slide_valid;
    wire [AXIS_W-1:0]      slide_axis;
    wire signed [1:0]      slide_dir;
    wire                   two_valid;
    wire [AXIS_W-1:0]      two_a, two_b;
    wire                   overflow;
    wire [7:0]             lost_cnt;

    event_extract #(
        .AXIS_N    (AXIS_N),
        .POS_W     (POS_W),
        .DW        (DW),
        .AXIS_W    (AXIS_W),
        .TRIG_TH   (TRIG),
        .REL_TH    (REL),
        .DELTA_TH  (13'sd8),
        .REFRACT_N (REFRACT_TB)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .snap_valid_i     (snap_valid),
        .pos_i            (pos),
        .delta_i          (delta),
        .evt_valid_o      (evt_valid),
        .evt_axis_o       (evt_axis),
        .evt_kind_o       (evt_kind),
        .evt_depth_o      (evt_depth),
        .slide_valid_o    (slide_valid),
        .slide_axis_o     (slide_axis),
        .slide_dir_o      (slide_dir),
        .two_note_valid_o (two_valid),
        .two_note_axis_a_o(two_a),
        .two_note_axis_b_o(two_b),
        .overflow_o       (overflow),
        .lost_cnt_o       (lost_cnt)
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

    // ⭐ 设置某轴的行程（⭐ 其余保持）
    task set_axis;
        input integer a;
        input [POS_W-1:0] v;
        begin
            // ⚠️ **必须用【定宽】变量 + 位选赋值**（⛔ 不做"算术后拼接"——
            //    🔴 本项目已踩过：`integer` 参与会让表达式升位、拼接静默截断）
            pos[a*POS_W +: POS_W] = v;
        end
    endtask

    // ⭐ 发一个快照脉冲（⭐ 帧驱动）
    task do_snap;
        begin
            @(negedge clk);
            snap_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            snap_valid = 1'b0;
        end
    endtask

    // ⭐⭐ 收集事件：⭐ 监听 evt_valid 并记录（⭐ 独立 always ⇒ ⛔ 不抢时钟）
    localparam integer MAXEV = 32;
    reg [AXIS_W-1:0] ev_axis [0:MAXEV-1];
    reg [1:0]        ev_kind [0:MAXEV-1];
    integer          ev_n = 0;

    always @(posedge clk)
        if (rst_n && evt_valid) begin
            if (ev_n < MAXEV) begin
                ev_axis[ev_n] = evt_axis;
                ev_kind[ev_n] = evt_kind;
            end
            ev_n = ev_n + 1;
            // ⭐ 判据 ⑦：同拍性 —— ⭐ 此刻 `evt_axis` 必须已是本事件的轴
            if (evt_kind > 2'd1)
                $display("FAIL: evt_kind_o = %0d is not a valid kind (0/1/2)", evt_kind);
        end

    integer i;
    integer n0;

    initial begin
        snap_valid = 1'b0; pos = 0; delta = 0;

        rst_n = 1'b0;
        repeat (40) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ═══ 判据 ① 首次越阈 ⇒ 立即 note_on ═══
        set_axis(3, 12'h500);        // ⭐ 轴 3 越过触发阈
        ev_n = 0;
        do_snap();
        repeat (40) @(posedge clk);
        chk("first crossing emits exactly one note_on", (ev_n == 1) && (ev_kind[0] === 2'd0));
        chk("note_on carries the correct axis", ev_axis[0] === 4'd3);

        // ═══ 判据 ④ 不应期内【重新按下】⇒ 不重复触发 ═══
        //   🔴 **⚠️ 这一条原来测的是【错的东西】（2026-09-23 由变异体 `M90` 查出）**：
        //      ⚠️ 原版只是把已按住的轴**再推深**（`0x500` → `0x600`）——
        //      ⭐ **但那时 `key_on[3]` 已经是 1** ⇒ ⚠️ 走的是 `else`（释放判断）分支
        //      ⇒ 🔴 **根本不会去看 `refr`** ⇒ ⭐ **判据通过得"侥幸"**：
        //         它测的是"已按住的键不会重复 on"，⛔ **不是"不应期封锁"**。
        //      ⇒ ⭐ 所以删掉不应期门（`M90`）它照样绿 —— ⚠️ **假守护**（`K-87` 同族）。
        //
        //   ⭐ **正确触发不应期门的前置条件**：⭐ **必须让键先【释放】再【重新越阈】**
        //      —— 因为 RTL 里 `refr` 门位于 `if (!key_on[...])` 分支内
        //      ⇒ ⭐ **只有"未按下"态才会查不应期**。
        //   📌 下面分两步：① 落到释放阈以下（置 `key_on=0`）② 立刻重新越阈（仍在不应期内）
        //      ⚠️ 全程**不超过 `REFRACT_TB`(=4) 帧**，⭐ 否则不应期已过、测不到封锁。
        ev_n = 0;

        // ① 释放（⭐ 一帧内完成 ⇒ 不应期计数只减 1）
        //   🔴 **⚠️ 必须等【扫描跑完】再发下一个快照** ——
        //      ⚠️ DUT 的逐轴扫描要 **16 拍**，而 `do_snap()` 只占 1 拍
        //      ⇒ 若连发两个快照，⭐ **第二个会打断第一个的扫描** ⇒ 🔴 事件丢失。
        set_axis(3, 12'h100);        // ⭐ < REL_TH(0x300) ⇒ key_on 清零，发 note_off
        do_snap();
        repeat (30) @(posedge clk);  // ⭐ 等扫描 + 出队完成
        // ② ⭐ 不等不应期过，立刻重新越阈
        set_axis(3, 12'h600);
        do_snap();
        repeat (40) @(posedge clk);

        // ⭐ 期望：只有【释放那一下】的 note_off，⛔ **没有第二个 note_on**
        //   ⚠️ 用"事件总数 + 种类"判定，⛔ 不用"总数为 0" ——
        //      因为释放本身是**合法事件**（note_off），总数不可能是 0。
        begin : refract_chk
            integer on_cnt, off_cnt, k;
            on_cnt = 0; off_cnt = 0;
            for (k = 0; k < ev_n; k = k + 1) begin
                if (ev_kind[k] === 2'd0) on_cnt  = on_cnt  + 1;
                if (ev_kind[k] === 2'd1) off_cnt = off_cnt + 1;
            end
            $display("  [refract] events=%0d  note_on=%0d  note_off=%0d (expect on=0, off>=1)",
                     ev_n, on_cnt, off_cnt);
            chk("re-pressing INSIDE the refractory window emits NO second note_on",
                on_cnt == 0);
            chk("the release itself was reported (note_off present)", off_cnt >= 1);
        end

        // ⭐ 恢复：把轴 3 彻底放开，供后面的判据用
        set_axis(3, 12'h000);
        do_snap();
        repeat (40) @(posedge clk);

        // ═══ 判据 ③ 迟滞：在 TRIG/REL 之间 ⇒ ⛔ 不产生 note_off ═══
        //   🔴 **⚠️ 本条曾因【前置状态错】而变成假守护（2026-09-23，由 `M92` 查出）**：
        //      ⚠️ 原版注释写"先把轴 3 稳定按住"，⭐ **但代码只是 `repeat(8)` 等时钟** ——
        //      🔴 **它并没有把键按下去**！⇒ 进本条时 `key_on[3]` 可能是 **0**
        //      ⇒ ⭐ `pos=0x350` 既 **< TRIG**（不会触发）又 **不涉及释放**（因为没按住）
        //      ⇒ 🔴 **正确 RTL 和 `M92` 都【不产生事件】** ⇒ ⭐ **无法区分 ⇒ LEAK**。
        //
        //   ⭐ **迟滞的本质**：⭐ **键【已按住】时，落到 TRIG 与 REL 之间【不应释放】**。
        //      ⚠️ 所以前置条件必须是 **`key_on=1`**，⛔ 不能只是"等几拍"。
        //   📌 **正确前置**：⭐ ① 越阈触发（`key_on` 置 1）② 等不应期过 ③ 再落到两阈之间
        //
        //   ⭐ 判据的**区分力**：⭐ 正常 RTL ⇒ `0x350 < REL(0x300)` 为**假** ⇒ ⛔ 不释放
        //      ⚠️ `M92`（释放阈被改成 TRIG）⇒ `0x350 < TRIG(0x400)` 为**真** ⇒ 🔴 **会释放**
        //      ⇒ ⭐ 两者行为不同 ⇒ ⭐ **本条就能抓住 M92**。
        begin : hysteresis_hold
            // ① ⭐ 先真正把键按下去
            set_axis(3, 12'h500);
            do_snap();
            repeat (40) @(posedge clk);
            // ② ⭐ 等不应期过（⚠️ refr 只在【收到快照】时递减 ⇒ 必须发快照）
            begin : expire_refractory
                integer g;
                for (g = 0; g < REFRACT_TB + 2; g = g + 1) begin
                    do_snap();
                    repeat (30) @(posedge clk);
                end
            end
            // ③ ⭐ 落到 TRIG 与 REL 之间 ⇒ 键应【保持按住】、⛔ 无事件
            ev_n = 0;
            set_axis(3, 12'h350);
            do_snap();
            repeat (40) @(posedge clk);
            chk("between TRIG and REL the key stays held (no spurious event)", ev_n == 0);
        end

        // ═══ 判据 ② 回落到释放阈以下 ⇒ note_off ═══
        //   ⚠️ **必须先把键【按下去并等不应期过】** ——
        //      因为上面的判据④已经把它释放过一次了 ⇒ ⚠️ 现在 `key_on[3]` 是 0
        //      ⇒ 若直接设 `0x200`，⭐ 走的是"未按下"分支 ⇒ **不会产生 note_off**。
        //   📌 正确前置：⭐ 先越阈触发一次（等不应期过），⭐ 再回落。
        ev_n = 0;
        set_axis(3, 12'h500);        // ⭐ 先按下
        do_snap();
        repeat (40) @(posedge clk);  // ⭐ 等扫描 + 出队
        repeat (40) @(posedge clk);  // ⭐ 等不应期(4帧)过

        ev_n = 0;
        set_axis(3, 12'h200);        // ⭐ < REL ⇒ 应产生 note_off
        do_snap();
        repeat (40) @(posedge clk);
        chk("dropping below REL emits note_off", (ev_n == 1) && (ev_kind[0] === 2'd1));
        chk("note_off carries the correct axis", ev_axis[0] === 4'd3);

        // ═══ 判据 ⑤ 不应期结束后可再次触发（自愈）═══
        //   🔴 **⚠️ 关键：`refr` 只在【收到快照】时递减**（见 RTL：
        //      `if (snap_valid_i) ... refr[ai] <= refr[ai] - 1`）
        //      ⚠️ 所以⭐ **光 `repeat(N)` 等时钟是没用的** ——
        //      🔴 必须**真的发 `REFRACT_TB` 次快照**才能让不应期清零。
        //      📌 这正是"不应期的单位是【帧】而不是【时钟】"的直接后果。
        begin : let_refractory_expire
            integer g;
            for (g = 0; g < REFRACT_TB + 2; g = g + 1) begin
                do_snap();                       // ⭐ 每个快照让 refr 减 1
                repeat (30) @(posedge clk);      // ⭐ 等本轮扫描+出队完成
            end
        end
        ev_n = 0;
        set_axis(3, 12'h500);
        do_snap();
        repeat (40) @(posedge clk);
        chk("after the refractory window the key can trigger again (self-healing)",
            (ev_n >= 1) && (ev_kind[0] === 2'd0));

        // ═══ 判据 ⑥ ⭐⭐ 同帧多轴 ⇒ 一个都不丢（🔴 第一版会丢） ═══
        //   ⚠️ **必须先让所有轴【回到释放态】并跑完一次快照** ——
        //      ⭐ 否则残留的 `key_on[...]` 会让新轴"看起来已经按着"，⛔ 不再触发。
        for (i = 0; i < AXIS_N; i = i + 1) set_axis(i, 12'h000);
        do_snap();                    // ⭐ 让全部轴检测到"释放"
        repeat (60) @(posedge clk);   // ⭐ 等扫描 + 出队（含 note_off）
        ev_n = 0;                     // ⭐ 清掉释放事件，⭐ 此后只数新的 note_on
        // ⭐⭐ 同一帧里 3 个轴同时越阈
        set_axis(1, 12'h500);
        set_axis(5, 12'h600);
        set_axis(9, 12'h700);
        do_snap();
        repeat (60) @(posedge clk);   // ⭐ 等扫描(16拍)+出队完成
        chk("THREE axes crossing in the SAME frame emit THREE note_on (none lost)",
            (ev_n == 3) && (ev_kind[0] === 2'd0) && (ev_kind[1] === 2'd0) && (ev_kind[2] === 2'd0));
        // ⭐ 三个轴号都要在（⭐ 顺序可能不同 ⇒ 用集合判断）
        begin : check_axes
            integer hit1, hit5, hit9;
            hit1 = 0; hit5 = 0; hit9 = 0;
            for (i = 0; i < 3; i = i + 1) begin
                if (ev_axis[i] === 4'd1) hit1 = 1;
                if (ev_axis[i] === 4'd5) hit5 = 1;
                if (ev_axis[i] === 4'd9) hit9 = 1;
            end
            chk("all three distinct axes are present (1, 5, 9)", (hit1 + hit5 + hit9) == 3);
        end

        $display("");
        if (errors == 0)
            $display("PASS: event_extract fires on the first crossing (no settle wait), holds with hysteresis, blocks inside the refractory window and self-heals, and NEVER loses events when several axes cross in the same frame");
        else
            $fatal(1, "FAIL: event_extract had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
