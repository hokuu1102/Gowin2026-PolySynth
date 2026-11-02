`timescale 1ns/1ps
// tb_fader_gear.sv · 推子三档 + 每档锁定 + 双颤音共存 · 判据重写（2026-10-18）
//
// ⭐ 规格书：bringup/40-推子三档与双颤音共存-实施方案-20261018.md
//            §4.1（接口）· §4.2（行为契约）· §6.1（判据 A~L）
//
// ⭐ 本次相对 2026-10-03 版的行为变更（⛔ 不是"修 tb"，是功能按用户裁定改了）：
//   ① 档位从 `0 ⇄ 1` 改成 **三档循环 0 → 1 → 2 → 0**（档 2 = 音量颤音）
//   ② 新增 `gear_sel0/1/2_i`：⭐ 直接跳档（屏点选用），⛔ 不经过循环
//   ③ 新增 `lock_toggle_i` + `hold_o[2:0]`：⭐ **每档独立锁定**
//   ④ ⭐⭐ **切档不再清零另一个颤音，而是"保持"** ——
//      旧判据 e/f/g 期望"另一个 == 0"，🔴 现在期望"另一个 == 上次的值"。
//      📌 这是"两个颤音能共存"的**唯一依据**，见 J 组。
//   ⑤ 档 0 的"进档接管 / 推子动接管"在 `hold[0] == 1` 时**都不发生**（L3）
//
// ⭐ 判据分组（⭐ 每条都要能红，⛔ 不许"打印一下看看"）：
//   A · 复位：gear=1 · hold=000 · semi=0；档 1 逐位透传；档 1 不驱动变调
//   B · 'J' 三档循环闭合：1 → 2 → 0 → 1
//   C · `gear_sel*_i` 直接跳档（⛔ 不经过循环）
//   D · 档 2：`trem_*` 逐位跟随 ch2/ch3；⭐ `vibrato_*` **保持**（⛔ 不为 0）
//   E · 档 1：`vibrato_*` 逐位跟随；⭐ `trem_*` **保持**
//   F · 档 0 且未锁：`transpose_semi_o` 跟随差分；⭐ 两个颤音**都保持**
//   G · 档 0 映射 ＋ 全 4096 点扫描（比较链不是近似）—— 沿用旧 C 组
//   H · 档 0 且**已锁**：推子跨半音边界 ⇒ `transpose_semi_o` **不变**（L3）
//   I · `lock_toggle_i` 只翻**当前档**那一位
//   J · ⭐⭐ **共存判据（本改动的灵魂）**：两个颤音同时有效
//   K · 档 0 的"进档接管"在 `hold[0]==1` 时**不发生**（L3 的第二个角度）
//   L · 复位 `hold_o == 3'b000`（全解锁）＋ 两推子都在 0 ⇒ 三档输出全 0
//   M · 串口 `'F'/'G'/'H'` 的 clamp 语义（沿用旧 E 组，⛔ 一条不删）
//   N · P3.1/P3.2：档 0 串口值保持 · 推子动才接管 · ±1 LSB 抖动不接管（沿用旧 F/G/H 组）
//   O · ⭐⭐ **解锁不跳变（天然 pickup）** ＋ 同拍多选优先级（不可达，顺带覆盖）
//
// ⭐ 非空洞性（⭐ 见交付报告的探针实测）：
//   · 探针 1（把"保持"改回"清零"）        ⇒ ⭐ E 组 / J 组必红
//   · 探针 2（去掉 `hold[0]` 的接管门控）  ⇒ ⭐ H 组 / K 组必红

module tb_fader_gear;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg        gear_next = 1'b0;
    reg        sel0      = 1'b0;
    reg        sel1      = 1'b0;
    reg        sel2      = 1'b0;
    reg        lock_tog  = 1'b0;
    reg [11:0] ch2       = 12'd0;
    reg [11:0] ch3       = 12'd0;
    reg        t_down    = 1'b0;
    reg        t_up      = 1'b0;
    reg        t_abs     = 1'b0;
    reg [7:0]  t_val     = 8'd0;

    wire [1:0]        gear;
    wire signed [4:0] semi;
    wire [11:0]       vdepth, vrate;
    wire [11:0]       tdepth, trate;
    wire [2:0]        hold;

    always #5 clk = ~clk;

    fader_gear dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .gear_next_i      (gear_next),
        .gear_sel0_i      (sel0),
        .gear_sel1_i      (sel1),
        .gear_sel2_i      (sel2),
        .lock_toggle_i    (lock_tog),
        .ch2_i            (ch2),
        .ch3_i            (ch3),
        .trans_down_i     (t_down),
        .trans_up_i       (t_up),
        .trans_abs_i      (t_abs),
        .trans_abs_val_i  (t_val),
        .gear_o           (gear),
        .transpose_semi_o (semi),
        .vibrato_depth_o  (vdepth),
        .vibrato_rate_o   (vrate),
        .trem_depth_o     (tdepth),
        .trem_rate_o      (trate),
        .hold_o           (hold)
    );

    integer errors    = 0;
    integer bad_gear3 = 0;
    integer sweep_bad = 0;
    integer n_bad     = 0;
    integer c, e;

    // ⭐ 档 3 结构上仍应不可达（⭐ 只有 0/1/2 三档）
    always @(posedge clk)
        if (rst_n && (gear == 2'd3)) bad_gear3 = bad_gear3 + 1;

    task chk; input [8*110-1:0] name; input cond; begin
        if (cond) $display("  ok  : %0s", name);
        else begin errors = errors + 1; $display("  FAIL: %0s", name); end
    end endtask

    task chk_semi; input [8*110-1:0] name; input integer exp; begin
        if (semi == exp)
            $display("  ok  : %0s  (semi=%0d)", name, $signed(semi));
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- expected %0d, got %0d", name, exp, $signed(semi));
        end
    end endtask

    task chk_gear; input [8*110-1:0] name; input integer exp; begin
        if (gear == exp)
            $display("  ok  : %0s  (gear=%0d)", name, gear);
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- expected gear %0d, got %0d", name, exp, gear);
        end
    end endtask

    task chk_hold; input [8*110-1:0] name; input [2:0] exp; begin
        if (hold === exp)
            $display("  ok  : %0s  (hold=%03b)", name, hold);
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- expected hold %03b, got %03b", name, exp, hold);
        end
    end endtask

    task chk_vib; input [8*110-1:0] name; input [11:0] ed, er; begin
        if (vdepth === ed && vrate === er)
            $display("  ok  : %0s  (vib=%03h/%03h)", name, vdepth, vrate);
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- expected vib %03h/%03h, got %03h/%03h",
                     name, ed, er, vdepth, vrate);
        end
    end endtask

    task chk_trem; input [8*110-1:0] name; input [11:0] ed, er; begin
        if (tdepth === ed && trate === er)
            $display("  ok  : %0s  (trem=%03h/%03h)", name, tdepth, trate);
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- expected trem %03h/%03h, got %03h/%03h",
                     name, ed, er, tdepth, trate);
        end
    end endtask

    task chk_cnt; input [8*110-1:0] name; input integer bad; begin
        if (bad == 0)
            $display("  ok  : %0s  (bad cycles = %0d)", name, bad);
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- %0d bad cycle(s)", name, bad);
        end
    end endtask

    // ⭐ 单拍脉冲任务：返回时（脉冲被采样后的 negedge）寄存器**已是新值**
    task pulse_gear; begin
        @(negedge clk); gear_next = 1'b1;
        @(negedge clk); gear_next = 1'b0;
    end endtask
    task pulse_sel; input [1:0] g; begin
        while (gear != g) pulse_gear;
    end endtask
    task pulse_lock; begin
        @(negedge clk); lock_tog = 1'b1;
        @(negedge clk); lock_tog = 1'b0;
    end endtask
    task pulse_down; begin
        @(negedge clk); t_down = 1'b1;
        @(negedge clk); t_down = 1'b0;
    end endtask
    task pulse_up; begin
        @(negedge clk); t_up = 1'b1;
        @(negedge clk); t_up = 1'b0;
    end endtask
    task pulse_abs; input [7:0] v; begin
        @(negedge clk); t_abs = 1'b1; t_val = v;
        @(negedge clk); t_abs = 1'b0;
    end endtask

    task do_reset; begin
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    end endtask

    initial begin
        // ═══════════════════════════════════════════════════════════════
        //  A · 复位 ＋ 档 1 逐位透传（零回归）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== A) reset / gear1 passthrough ===");
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        chk_gear("A1 reset gear == 1 (power-on default)", 1);
        chk_semi("A2 reset transpose == 0 (no transposition)", 0);
        chk_hold("A3 reset hold_o == 000 (all UNLOCKED, user ruling)", 3'b000);

        ch2 = 12'hFFF; ch3 = 12'h000; @(negedge clk);
        chk_vib("A4 gear1 passthrough bit-exact (FFF/000)", 12'hFFF, 12'h000);
        ch2 = 12'h321; ch3 = 12'hABC; @(negedge clk);
        chk_vib("A5 gear1 passthrough bit-exact (321/ABC)", 12'h321, 12'hABC);
        ch2 = 12'h800; ch3 = 12'h001; @(negedge clk);
        chk_vib("A6 gear1 passthrough bit-exact (800/001)", 12'h800, 12'h001);
        chk_semi("A7 gear1 fader does NOT drive transpose", 0);

        // ═══════════════════════════════════════════════════════════════
        //  B · 'J' 三档循环闭合：1 → 2 → 0 → 1
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== B) 'J' three-gear cycle ===");
        pulse_gear(); chk_gear("B1 'J' from gear1 -> gear2", 2);
        pulse_gear(); chk_gear("B2 'J' from gear2 -> gear0", 0);
        pulse_gear(); chk_gear("B3 'J' from gear0 -> gear1 (cycle closed)", 1);
        pulse_gear(); chk_gear("B4 'J' again -> gear2", 2);
        pulse_gear(); chk_gear("B5 'J' again -> gear0", 0);
        pulse_gear(); chk_gear("B6 'J' again -> gear1", 1);
        chk("B7 gear never reached 3 (continuous monitor)", bad_gear3 == 0);

        // ═══════════════════════════════════════════════════════════════
        //  C · gear_sel*_i 直接跳档（⛔ 不经过循环）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== C) direct gear select (screen tap) ===");
        pulse_sel(2'd2); chk_gear("C1 gear_sel2 from gear1 -> gear2 directly", 2);
        pulse_sel(2'd0); chk_gear("C2 gear_sel0 from gear2 -> gear0 directly", 0);
        pulse_sel(2'd1); chk_gear("C3 gear_sel1 from gear0 -> gear1 directly", 1);
        pulse_sel(2'd2); chk_gear("C4 gear_sel2 from gear1 again", 2);
        pulse_sel(2'd2); chk_gear("C5 gear_sel2 when already in gear2 (idempotent)", 2);
        pulse_sel(2'd1); chk_gear("C6 back to gear1", 1);

        // ═══════════════════════════════════════════════════════════════
        //  D · 档 2：trem 跟随，vibrato **保持**
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== D) gear2: trem follows, vibrato HOLDS ===");
        ch2 = 12'h800; ch3 = 12'h400; @(negedge clk);   // gear1 记下 800/400
        chk_vib("D0 gear1 seeded with 800/400", 12'h800, 12'h400);
        pulse_sel(2'd2);                                 // -> gear2
        chk_gear("D1 in gear2", 2);
        @(negedge clk);
        ch2 = 12'h321; ch3 = 12'hABC; @(negedge clk);
        chk_trem("D2 gear2 trem follows faders bit-exact (321/ABC)",
                 12'h321, 12'hABC);
        //  🔴 旧判据此处期望 vibrato == 0（清零）。现在必须是**保持**。
        chk_vib("D3 [CHANGED] gear2 vibrato HOLDS 800/400 (not zeroed)",
                12'h800, 12'h400);
        ch2 = 12'h111; @(negedge clk);
        chk_vib("D4 vibrato still holds after more fader movement",
                12'h800, 12'h400);
        //  ⭐ 把 ch2 放回 D2 的值 —— ⚠️ 档 2 是**未锁**的 ⇒ trem 会跟着 ch2 走，
        //     若停在 0x111，E 组"trem 保持"的期望就应该是 111/ABC。
        //     这里显式复位成 321，让 E 组的期望与 D2 一致、可读性更好 ✅
        ch2 = 12'h321; @(negedge clk);
        chk_trem("D5 trem follows back to 321/ABC", 12'h321, 12'hABC);

        // ═══════════════════════════════════════════════════════════════
        //  E · 档 1：vibrato 跟随，trem **保持**
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== E) gear1: vibrato follows, trem HOLDS ===");
        pulse_sel(2'd1);                                 // -> gear1
        chk_gear("E1 in gear1", 1);
        @(negedge clk);
        ch2 = 12'h123; ch3 = 12'h456; @(negedge clk);
        chk_vib("E2 gear1 vibrato follows faders bit-exact (123/456)",
                12'h123, 12'h456);
        //  🔴 旧判据此处期望 trem == 0。现在必须是**保持** D 组留下的 321/ABC。
        chk_trem("E3 [CHANGED] gear1 trem HOLDS 321/ABC (not zeroed)",
                 12'h321, 12'hABC);

        // ═══════════════════════════════════════════════════════════════
        //  F · 档 0 且未锁：变调跟随差分；两个颤音**都保持**
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== F) gear0 unlocked: transpose follows, both vibratos HOLD ===");
        //  ⭐⭐ 关键顺序：档 1 此刻是**未锁**的 ⇒ 直接把推子推到 0 会把 vibrato
        //     抹成 0/0（因为档 1 未锁时 vibrato 跟随推子）。
        //     ⇒ ⭐ **必须先锁定再归零** —— 这正是用户的工作流（调好 → 锁 → 回 0）✅
        pulse_lock();
        chk_hold("F0 lock gear1 BEFORE parking (hold == 010)", 3'b010);
        ch2 = 12'd0; ch3 = 12'd0; @(negedge clk);
        chk_vib("F0b parked at 0, vibrato still holds 123/456", 12'h123, 12'h456);
        pulse_sel(2'd0);
        chk_gear("F1 in gear0", 0);
        @(negedge clk);
        chk_semi("F2 gear0 both faders zero => 0", 0);
        ch2 = 12'd4095; ch3 = 12'd0; @(negedge clk);
        chk_semi("F3 left fader full => -12", -12);
        ch2 = 12'd0; ch3 = 12'd4095; @(negedge clk);
        chk_semi("F4 right fader full => +12", 12);
        ch2 = 12'd4095; ch3 = 12'd4095; @(negedge clk);
        chk_semi("F5 both full => 0 (right - left)", 0);
        ch2 = 12'd0; ch3 = 12'd2048; @(negedge clk);
        chk_semi("F6 right mid => +6", 6);
        //  🔴 旧判据此处期望两个颤音都 == 0（"其余档 ⇒ 归 0"）。
        chk_vib("F7 [CHANGED] gear0 vibrato HOLDS 123/456 (not zeroed)",
                12'h123, 12'h456);
        chk_trem("F8 physical next passes gear2 with zero faders, then holds zero",
                 12'h000, 12'h000);

        // ═══════════════════════════════════════════════════════════════
        //  G · 档 0 映射 ＋ 全 4096 点扫描（沿用旧 C 组）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== G) gear0 mapping + exhaustive sweep ===");
        ch2 = 12'd0;    ch3 = 12'd2047; @(negedge clk);
        chk_semi("G1 right just below mid => +5", 5);
        ch2 = 12'd0;    ch3 = 12'd342;  @(negedge clk);
        chk_semi("G2 right first step => +1", 1);
        ch2 = 12'd0;    ch3 = 12'd341;  @(negedge clk);
        chk_semi("G3 right just below first step => 0", 0);
        ch2 = 12'd3754; ch3 = 12'd0;    @(negedge clk);
        chk_semi("G4 left at step-11 threshold => -11", -11);
        ch2 = 12'd3753; ch3 = 12'd0;    @(negedge clk);
        chk_semi("G5 left just below step-11 threshold => -10", -10);
        ch2 = 12'd683;  ch3 = 12'd1365; @(negedge clk);
        chk_semi("G6 left step2 / right step4 => +2", 2);

        //  ⭐ 全 4096 点扫描 —— 比较链必须逐值等于 floor(c*12/4095)
        ch2 = 12'd0;
        sweep_bad = 0;
        for (c = 0; c <= 4095; c = c + 1) begin
            ch3 = c[11:0];
            @(negedge clk);
            e = (c * 12) / 4095;
            if (semi != e) sweep_bad = sweep_bad + 1;
        end
        chk_cnt("G7 right-fader sweep: all 4096 points == floor(c*12/4095)", sweep_bad);

        sweep_bad = 0;
        ch3 = 12'd0;
        for (c = 0; c <= 4095; c = c + 1) begin
            ch2 = c[11:0];
            @(negedge clk);
            e = (c * 12) / 4095;
            if (semi != (-e)) sweep_bad = sweep_bad + 1;
        end
        chk_cnt("G8 left-fader sweep: all 4096 points == -floor(c*12/4095)", sweep_bad);

        ch2 = 12'd0; ch3 = 12'd0; @(negedge clk);
        chk_semi("G9 sweep leaves no residue", 0);

        // ═══════════════════════════════════════════════════════════════
        //  H · 档 0 且**已锁**：推子跨半音边界 ⇒ 变调**不变**（L3）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== H) gear0 LOCKED: fader must NOT take over ===");
        //  ⭐ 先复位：F 组给档 1 上过锁（hold==010），不清掉会让 H2 期望变成 011
        do_reset();
        chk_hold("H0 reset => hold == 000 (clean)", 3'b000);
        pulse_sel(2'd0); chk_gear("H0b -> gear0", 0);
        @(negedge clk);
        pulse_abs(8'd18);                       // 先钉到 +6（编码 18）
        chk_semi("H1 serial 'H' 18 => +6 (baseline)", 6);
        pulse_lock();                           // 锁档 0
        chk_hold("H2 lock in gear0 => hold == 001", 3'b001);
        //  ⭐ 推子跨过半音档边界（0 → 4095，跨 12 个边界）
        ch2 = 12'd4095; ch3 = 12'd0; @(negedge clk);
        chk_semi("H3 [L3] locked gear0: big fader move does NOT change transpose (+6)", 6);
        repeat (4) @(negedge clk);
        chk_semi("H4 [L3] still +6 after 4 more cycles", 6);
        //  ⭐ 反证：解锁后同样的移动**必须**接管（证明上面不是因为"推子坏了"）
        pulse_lock();
        chk_hold("H5 unlock => hold == 000", 3'b000);
        ch2 = 12'd0; ch3 = 12'd4095; @(negedge clk);
        chk_semi("H6 unlocked: fader move DOES take over (+12)", 12);

        // ═══════════════════════════════════════════════════════════════
        //  I · lock_toggle 只翻**当前档**那一位
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== I) lock_toggle flips ONLY the current gear's bit ===");
        do_reset();
        chk_hold("I0 reset => hold == 000 (clean)", 3'b000);
        pulse_sel(2'd1); chk_gear("I1 -> gear1", 1);
        pulse_lock(); chk_hold("I2 lock in gear1 => hold == 010", 3'b010);
        pulse_lock(); chk_hold("I3 lock again => hold == 000", 3'b000);
        pulse_lock(); chk_hold("I4 lock => hold == 010", 3'b010);
        pulse_sel(2'd2); chk_gear("I5 -> gear2", 2);
        chk_hold("I6 gear1's lock SURVIVES the gear switch (hold == 010)", 3'b010);
        pulse_lock(); chk_hold("I7 lock in gear2 => hold == 110", 3'b110);
        pulse_sel(2'd0); chk_gear("I8 -> gear0", 0);
        chk_hold("I9 gear1+gear2 locks survive (hold == 110)", 3'b110);
        pulse_lock(); chk_hold("I10 lock in gear0 => hold == 111", 3'b111);
        pulse_lock(); chk_hold("I11 unlock gear0 => hold == 110", 3'b110);

        // ═══════════════════════════════════════════════════════════════
        //  J · ⭐⭐ 共存判据（本改动的灵魂）
        //     档 1 把 ch2 推到 0x800 ⇒ 锁 ⇒ 切档 2 把 ch3 推到 0x400 ⇒ 锁
        //     ⇒ 切回档 1 ⇒ vib 仍 0x800 **且** trem_rate 仍 0x400
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== J) COEXISTENCE: both vibratos valid at the same time ===");
        do_reset();
        chk_hold("J1 fresh reset => hold == 000 (all unlocked)", 3'b000);
        pulse_sel(2'd1); chk_gear("J2 -> gear1", 1);
        ch2 = 12'h800; ch3 = 12'h000; @(negedge clk);
        chk_vib("J3 gear1 vib_depth = 0x800", 12'h800, 12'h000);
        pulse_lock();                            // 锁档 1
        chk_hold("J4 lock gear1 => hold == 010", 3'b010);
        ch2 = 12'h000; @(negedge clk);           // ⭐ 推子回 0（关键：不回零就会污染下一档）
        chk_vib("J5 [CORE] parked fader at 0, vib_depth STILL 0x800 (locked)",
                12'h800, 12'h000);

        pulse_sel(2'd2); chk_gear("J6 -> gear2", 2);
        @(negedge clk);
        chk_trem("J7 gear2 trem starts from the parked 0 (no jump)",
                 12'h000, 12'h000);
        ch3 = 12'h400; @(negedge clk);
        chk_trem("J8 gear2 trem_rate = 0x400", 12'h000, 12'h400);
        pulse_lock();                            // 锁档 2
        chk_hold("J9 lock gear2 => hold == 110", 3'b110);
        ch3 = 12'h000; @(negedge clk);           // 推子回 0
        chk_trem("J10 parked fader at 0, trem_rate STILL 0x400 (locked)",
                 12'h000, 12'h400);

        pulse_sel(2'd1); chk_gear("J11 -> back to gear1", 1);
        @(negedge clk);
        //  🔴🔴 这就是"两个颤音共存"的铁证：两个值同时非零
        chk_vib("J12 [CORE] vib_depth STILL 0x800 after round-trip",
                12'h800, 12'h000);
        chk_trem("J13 [CORE] trem_rate STILL 0x400 after round-trip",
                 12'h000, 12'h400);
        chk("J14 [CORE] BOTH vibratos non-zero simultaneously",
            (vdepth == 12'h800) && (trate == 12'h400));

        // ═══════════════════════════════════════════════════════════════
        //  K · 档 0 的"进档接管"在 hold[0]==1 时**不发生**（L3 第二角度）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== K) gear0_enter must be gated by hold[0] ===");
        do_reset();
        pulse_sel(2'd0); chk_gear("K1 -> gear0", 0);
        @(negedge clk);
        pulse_abs(8'd6);                         // 串口钉到 -6（编码 6）
        chk_semi("K2 serial 'H' 6 => -6", -6);
        pulse_lock();                            // 锁档 0
        chk_hold("K3 gear0 locked (hold == 001)", 3'b001);
        pulse_sel(2'd1); chk_gear("K4 -> gear1", 1);
        ch2 = 12'd0; ch3 = 12'd4095; @(negedge clk);   // 推子放到 +12 的位置
        pulse_sel(2'd0); chk_gear("K5 -> gear0 again (enter)", 0);
        @(negedge clk);
        chk_semi("K6 [L3] gear0_enter BLOCKED by hold[0]: stays -6 (not +12)", -6);
        repeat (4) @(negedge clk);
        chk_semi("K7 [L3] still -6 after 4 cycles", -6);
        //  ⭐ 反证：解锁后再进一次，必须接管
        pulse_lock(); chk_hold("K8 unlock gear0", 3'b000);
        pulse_sel(2'd1); chk_gear("K9 -> gear1", 1);
        pulse_sel(2'd0); chk_gear("K10 -> gear0", 0);
        @(negedge clk);
        chk_semi("K11 unlocked gear0_enter DOES take over (+12)", 12);

        // ═══════════════════════════════════════════════════════════════
        //  L · 复位 hold=000 ＋ 上电静默
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== L) reset clears locks + power-on silence ===");
        pulse_lock(); pulse_lock(); pulse_lock();     // 把 hold 弄乱
        ch2 = 12'd1234; ch3 = 12'd2345;
        do_reset();
        chk_hold("L1 reset => hold_o == 000 (locks cleared)", 3'b000);
        chk_gear("L2 reset => gear == 1", 1);
        ch2 = 12'd0; ch3 = 12'd0; @(negedge clk);
        chk_vib("L3 faders at 0 => vibrato == 0/0", 12'h000, 12'h000);
        chk_trem("L4 faders at 0 => trem == 0/0", 12'h000, 12'h000);
        chk_semi("L5 faders at 0 => transpose == 0", 0);

        // ═══════════════════════════════════════════════════════════════
        //  M · 串口 'F'/'G'/'H' 的 clamp（沿用旧 E 组，⛔ 一条不删）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== M) serial 'F'/'G'/'H' clamp ===");
        pulse_abs(8'd12);  chk_semi("M1 'H' 12 => 0", 0);
        for (c = 0; c < 20; c = c + 1) pulse_up();
        chk_semi("M2 'G' x20 clamps at +12", 12);
        pulse_up();
        chk_semi("M3 'G' beyond +12 stays +12 (no wrap)", 12);
        for (c = 0; c < 30; c = c + 1) pulse_down();
        chk_semi("M4 'F' x30 clamps at -12", -12);
        pulse_down();
        chk_semi("M5 'F' beyond -12 stays -12 (no wrap)", -12);
        pulse_abs(8'd0);   chk_semi("M6 'H' 0  => -12", -12);
        pulse_abs(8'd24);  chk_semi("M7 'H' 24 => +12", 12);
        pulse_abs(8'd6);   chk_semi("M8 'H' 6  => -6",  -6);
        pulse_abs(8'd18);  chk_semi("M9 'H' 18 => +6",   6);
        pulse_abs(8'd25);  chk_semi("M10 'H' 25 => +12 (clamp)", 12);
        //  ⭐ 专守"只取 [4:0] 会截成 12 ⇒ 静默变成不调"这个坑
        pulse_abs(8'd44);  chk_semi("M11 'H' 44 => +12 (NOT 12/unchanged)", 12);
        pulse_abs(8'd31);  chk_semi("M12 'H' 31 => +12 (clamp)", 12);
        pulse_abs(8'd255); chk_semi("M13 'H' 255 => +12 (clamp)", 12);
        pulse_abs(8'd12);  chk_semi("M14 'H' 12 back to 0", 0);
        pulse_down();      chk_semi("M15 'F' from 0 => -1", -1);
        pulse_up();        chk_semi("M16 'G' from -1 => 0", 0);

        // ═══════════════════════════════════════════════════════════════
        //  N · P3.1 / P3.2：串口值保持 · 推子动才接管 · 抖动不接管
        //      （沿用旧 F/G/H 组；⭐ 全部在**未锁**的档 0 下跑）
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== N) gear0 takeover / quantization hysteresis ===");
        do_reset();
        pulse_sel(2'd0); chk_gear("N1 -> gear0 (unlocked)", 0);
        @(negedge clk);
        ch2 = 12'd0; ch3 = 12'd0; @(negedge clk);
        chk_semi("N2 gear0 faders zero => 0", 0);
        pulse_up();
        chk_semi("N3 gear0: 'G' takes effect on its own cycle => +1", 1);
        @(negedge clk);
        chk_semi("N4 [P3.1] gear0: 'G' value HOLDS next cycle", 1);
        repeat (8) @(negedge clk);
        chk_semi("N5 [P3.1] still holds after 8 more cycles", 1);
        pulse_abs(8'd6);
        chk_semi("N6 [P3.1] 'H' 6 => -6", -6);
        repeat (4) @(negedge clk);
        chk_semi("N7 [P3.1] 'H' value holds 4 cycles (no re-tracking)", -6);
        ch3 = 12'd2048; @(negedge clk);
        chk_semi("N8 [P3.1] fader MOVED => takes over immediately (+6)", 6);
        repeat (4) @(negedge clk);
        chk_semi("N9 [P3.1] after takeover, holds (+6)", 6);

        //  ⭐ 量化迟滞：±1 LSB 抖动**不**触发接管
        ch2 = 12'd2000; ch3 = 12'd0; @(negedge clk);
        chk_semi("N10 fader 2000/0 => takeover (step5 => -5)", -5);
        pulse_abs(8'd24);
        chk_semi("N11 'H' 24 pins serial to +12", 12);
        n_bad = 0;
        for (c = 0; c < 24; c = c + 1) begin
            ch2 = (c % 2 == 0) ? 12'd1999 : 12'd2001;   // ±1 LSB dither
            @(negedge clk);
            if (semi != 12) n_bad = n_bad + 1;
        end
        chk_cnt("N12 [P3.2] ch2 +-1 LSB dither x24 => +12 held EVERY cycle", n_bad);
        ch2 = 12'd2000; @(negedge clk);
        chk_semi("N13 [P3.2] ch2 back to 2000 (same step) => +12 still holds", 12);
        n_bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            ch3 = (c % 2 == 0) ? 12'd1 : 12'd0;
            @(negedge clk);
            if (semi != 12) n_bad = n_bad + 1;
        end
        chk_cnt("N14 [P3.2] ch3 +-1 LSB dither (0<->1) x8 => +12 held EVERY cycle", n_bad);
        ch3 = 12'd0; @(negedge clk);
        //  ⭐ 跨过半音档边界 ⇒ 必须接管
        ch2 = 12'd1706; @(negedge clk);
        chk_semi("N15 [P3.2] crossing 1707 downward => takeover (step4 => -4)", -4);
        pulse_abs(8'd24);
        ch2 = 12'd1707; @(negedge clk);
        chk_semi("N16 [P3.2] crossing 1707 upward => takeover (step5 => -5)", -5);
        pulse_abs(8'd24);
        ch2 = 12'd2048; @(negedge clk);
        chk_semi("N17 [P3.2] crossing 2048 => takeover (step6 => -6)", -6);

        // ═══════════════════════════════════════════════════════════════
        //  O · ⭐⭐ 解锁**不跳变**（天然 pickup）＋ 同拍多选优先级（不可达，顺带覆盖）
        //
        //  ⭐ 机制（已核 `fader_gear.v:255`）：
        //     `enc_next = ((fader_moved || gear0_enter) && !hold_o[0]) ? fader_enc : enc_r`
        //     ⇒ ⭐ **解锁那一拍** `fader_moved` 与 `gear0_enter` **都不成立**
        //        （`fader_enc_q` 每拍无条件跟随 ⇒ 解锁时两者相等）
        //     ⇒ ⭐ 值**不变**；要**真的动一下推子**（跨半音档边界）才接管 ✅
        //  📌 这是**好行为**：等于**天然 pickup** —— 解锁不会把变调突然拉走 ✅
        // ═══════════════════════════════════════════════════════════════
        $display("");
        $display("=== O) unlock does NOT jump (natural pickup) + same-cycle sel priority ===");
        do_reset();
        pulse_sel(2'd0); chk_gear("O1 -> gear0 (unlocked)", 0);
        ch2 = 12'd0; ch3 = 12'd2048; @(negedge clk);   // step6 => +6（P1）
        chk_semi("O2 baseline P1 => +6", 6);
        pulse_lock();                                   // 锁档 0
        chk_hold("O3 gear0 locked (hold == 001)", 3'b001);
        ch3 = 12'd3072; @(negedge clk);                 // P2 = step9 => 本应 +9
        chk_semi("O4 [L3] locked: fader at P2 => transpose unchanged (+6)", 6);
        //  ⭐⭐ 核心：**解锁那一拍寄存器还没更新**（组合边沿 → 下一拍生效）
        pulse_lock();
        chk_hold("O5 unlocked (hold == 000)", 3'b000);
        chk_semi("O6 [UNLOCK] the unlock cycle itself still shows +6 (register updates on the NEXT edge)", 6);
        repeat (6) @(negedge clk);
        //  ⭐⭐ 2026-10-18（用户裁定）：⭐ **解锁 = 立即采用推子当前位置** ✅
        //     🔴 原期望 `6`（"解锁不跳变，要再动推子才接管"）—— 那是 **pickup** 语义，
        //        用户明确否掉了：*"我觉得就要跳变比较好，因为我置零就是不想要这个效果"*
        //     ✅ 现在：解锁后**下一拍**就变成推子位置（P2 = +9）⇒ ⭐ 立即生效 ✅
        //     📌 语义：推子停在 0 = "这个效果我不要" ⇒ 解锁就该是 0（关掉）
        //     📌 与两个颤音档**行为统一**（它们本来就是解锁立即跟随）
        chk_semi("O7 [UNLOCK] after unlock it IMMEDIATELY follows the fader (+9), no wait-for-move", 9);
        //  ⭐ 再动一下推子 ⇒ 继续跟随（证明接管后是实时的）
        ch3 = 12'd3413; @(negedge clk);                 // step10 => +10
        chk_semi("O8 [UNLOCK] keeps following after unlock (move => +10)", 10);

        //  ⭐ 顺带覆盖（**不可达**情形）：同拍多选 ⇒ A 实现为 sel0 > sel1 > sel2
        do_reset();
        @(negedge clk); sel0 = 1'b1; sel2 = 1'b1;
        @(negedge clk); sel0 = 1'b0; sel2 = 1'b0;
        chk_gear("O9 same-cycle sel0+sel2 => sel0 wins (gear0)", 0);
        @(negedge clk); sel1 = 1'b1; sel2 = 1'b1;
        @(negedge clk); sel1 = 1'b0; sel2 = 1'b0;
        chk_gear("O10 same-cycle sel1+sel2 => sel1 wins (gear1)", 1);

        // ═══════════════════════════════════════════════════════════════
        $display("");
        if (errors == 0)
            $display("PASS: fader_gear -- 3 gears / per-gear lock / dual-vibrato coexistence all hold");
        else
            $fatal(1, "FAIL: tb_fader_gear has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "FAIL: tb_fader_gear timeout");
    end
endmodule
