`timescale 1ns/1ps
// tb_fader_gear.sv · P3 推子档位状态机 · 聚焦判据（2026-10-03）
//                 ＋ P3.1 档 0「推子值变化时才接管」（2026-10-03 用户拍板 A′）
//                 ＋ P3.2 边沿检测改用【量化档位】⇒ ±1 LSB 抖动不接管（2026-10-03）
//
// ⭐ 来源：files/20-代码/T3-后续计划-20261003.md §P3 ＋ §七（P3.1）
//          ＋ files/00-总览/T3变调与推子功能状态机-设计定稿-20261001.md §四
//
// ⭐ 判据分组（⭐ 每条都要能红，⭐ 例外见 G 组 ③）：
//   A · 复位 = 档 1，且 vibrato_* 【逐位等于】ch2_i/ch3_i（⭐ 零回归）
//   B · 'J' 切到档 0 ⇒ CH2/CH3 语义**真的换了**（vibrato_* 停、transpose 跟随）
//   C · 档 0 映射：左满 ⇒ −12 · 右满 ⇒ +12 · 双满 ⇒ 0
//        ＋ ⭐ **全 4096 点扫描**：⭐ 逐值等于 floor(ch*12/4095)（⭐ 比较链不是近似）
//   D · 'J' 只能在 档 0 ⇄ 档 1 之间（⭐ 档 2/3 结构上不可达）
//   E · 'F'/'G'/'H' 改 transpose_semi_o 且 clamp 在 ±12
//   F · ⭐ 共用目标寄存器 ＋ ⭐⭐ P3.1：⭐ 档 0 下串口值**生效并保持**、
//        推子一动就接管、接管后保持（⭐ 档 0 推子跟随**仍然成立** ✅）
//   G · ⭐⭐ P3.1 新增：⭐ 切档瞬间接管当前推子位置（④）＋ 复位后不误触发（③）
//        ⚠️⚠️ **③（G11~G15）是【冒烟检查】，⛔ 不是"能红"判据** ——
//            ⭐ 它结构上不可观测（⭐ 实测 M3/M4 把复位值写错**全 PASS**）。
//            ⭐ 详见 G 组头部的说明（⭐ 判据本身逐条保留，⛔ 一条不删）。
//   H · ⭐⭐ P3.2 新增：⭐ **量化迟滞** —— ⭐ ±1 LSB 抖动**不**触发接管（①）
//        ＋ ⭐ **跨过半音档边界才**触发接管（②）
//        🔴 病灶：⭐ P3.1 的 `fader_moved` 比较**原始 12 位** ⇒
//           ⭐ 推子静止时 ADC 抖 ±1 LSB ⇒ ⭐ 每拍为真 ⇒ ⭐ 档 0 串口又失效。
//
// ⭐ 非空洞性（⭐ 见交付报告的"能红证据"）：
//   · 去掉【档位 mux】⇒ B 组必红（vibrato 不再停、transpose 不再跟随）
//   · 去掉【clamp】  ⇒ C/E 组必红（越界后回绕成 −13/+13/错档）
//   · ⭐ P3.1：去掉【推子边沿检测】⇒ F 组必红（F4/F5/F7/F9：串口值只活 1 拍）
//   · ⭐ P3.1：去掉【切档接管】    ⇒ G 组必红（G4/G9：切档后沿用旧编码）
//   · ⭐ P3.2：把 `fader_moved` **改回原始 12 位比较** ⇒ ⭐ H4/H5/H6/H11 必红
//     （⭐ 实测：H4 bad=24/24 · H6 bad=8/8 · H11 bad=8/8 —— ⭐ 见交付报告）

module tb_fader_gear;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg        gear_next = 1'b0;
    reg [11:0] ch2       = 12'd0;
    reg [11:0] ch3       = 12'd0;
    reg        t_down    = 1'b0;
    reg        t_up      = 1'b0;
    reg        t_abs     = 1'b0;
    reg [7:0]  t_val     = 8'd0;

    wire [1:0]        gear;
    wire signed [4:0] semi;
    wire [11:0]       vdepth, vrate;

    always #5 clk = ~clk;

    fader_gear dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .gear_next_i      (gear_next),
        .ch2_i            (ch2),
        .ch3_i            (ch3),
        .trans_down_i     (t_down),
        .trans_up_i       (t_up),
        .trans_abs_i      (t_abs),
        .trans_abs_val_i  (t_val),
        .gear_o           (gear),
        .transpose_semi_o (semi),
        .vibrato_depth_o  (vdepth),
        .vibrato_rate_o   (vrate)
    );

    integer errors    = 0;
    integer bad_gear  = 0;
    integer sweep_bad = 0;
    // ⭐ P3.2：⭐ H 组"逐拍保持"计数（⭐ 0 = 每一拍都保持住）
    integer h_bad     = 0;
    integer c, e;

    // ⭐ D 组的**连续**监视：⭐ 任何一拍出现档 2/3 都记一笔
    always @(posedge clk)
        if (rst_n && (gear == 2'd2 || gear == 2'd3)) bad_gear = bad_gear + 1;

    task chk; input [8*100-1:0] name; input cond; begin
        if (cond) $display("  ok  : %0s", name);
        else begin errors = errors + 1; $display("  FAIL: %0s", name); end
    end endtask

    task chk_semi; input [8*100-1:0] name; input integer exp; begin
        if (semi == exp)
            $display("  ok  : %0s  (semi=%0d)", name, $signed(semi));
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- expected %0d, got %0d", name, exp, $signed(semi));
        end
    end endtask

    // ⭐ P3.2：⭐ "逐拍保持"判据 —— ⭐ 把**坏拍数**打出来（⭐ 比布尔更可核）
    task chk_cnt; input [8*100-1:0] name; input integer bad; begin
        if (bad == 0)
            $display("  ok  : %0s  (bad cycles = %0d)", name, bad);
        else begin
            errors = errors + 1;
            $display("  FAIL: %0s -- %0d bad cycle(s)", name, bad);
        end
    end endtask

    // ⭐ 单拍脉冲：⭐ 任务返回时（= 脉冲被采样后的那个 negedge）寄存器**已是新值** ✅
    task pulse_gear; begin
        @(negedge clk); gear_next = 1'b1;
        @(negedge clk); gear_next = 1'b0;
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

    initial begin
        // ═══════════════════════════════════════════════════════════════
        //  A · ⭐ 复位 = 档 1 ＋ 逐位透传（⭐ 零回归）
        // ═══════════════════════════════════════════════════════════════
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        chk("A1 reset gear == 1 (power-on default)", gear == 2'd1);
        chk_semi("A2 reset transpose == 0 (no transposition)", 0);

        ch2 = 12'hFFF; ch3 = 12'h000; @(negedge clk);
        chk("A3 gear1 passthrough bit-exact (FFF/000)",
            vdepth === 12'hFFF && vrate === 12'h000);
        ch2 = 12'h321; ch3 = 12'hABC; @(negedge clk);
        chk("A4 gear1 passthrough bit-exact (321/ABC)",
            vdepth === 12'h321 && vrate === 12'hABC);
        ch2 = 12'h800; ch3 = 12'h001; @(negedge clk);
        chk("A5 gear1 passthrough bit-exact (800/001)",
            vdepth === 12'h800 && vrate === 12'h001);
        ch2 = 12'h000; ch3 = 12'hFFE; @(negedge clk);
        chk("A6 gear1 passthrough bit-exact (000/FFE)",
            vdepth === 12'h000 && vrate === 12'hFFE);
        chk_semi("A7 gear1 fader does NOT drive transpose", 0);

        // ═══════════════════════════════════════════════════════════════
        //  B · ⭐ 'J' 切到档 0 ⇒ CH2/CH3 语义**真的换了**
        // ═══════════════════════════════════════════════════════════════
        pulse_gear();
        chk("B1 'J' from gear1 -> gear0", gear == 2'd0);
        ch2 = 12'hFFF; ch3 = 12'h321; @(negedge clk);
        chk("B2 gear0: vibrato no longer follows faders",
            vdepth === 12'h000 && vrate === 12'h000);
        //   ch2=4095 ⇒ 左档位 12 · ch3=0x321=801 ⇒ 右档位 2 ⇒ 2−12 = −10
        chk_semi("B3 gear0: transpose now follows faders (-10)", -10);

        // ═══════════════════════════════════════════════════════════════
        //  C · ⭐ 档 0 映射（⭐ 各占半程）
        // ═══════════════════════════════════════════════════════════════
        ch2 = 12'd4095; ch3 = 12'd0;    @(negedge clk);
        chk_semi("C1 left fader full => -12", -12);
        ch2 = 12'd0;    ch3 = 12'd4095; @(negedge clk);
        chk_semi("C2 right fader full => +12", 12);
        ch2 = 12'd4095; ch3 = 12'd4095; @(negedge clk);
        chk_semi("C3 both faders full => 0 (right - left)", 0);
        ch2 = 12'd0;    ch3 = 12'd0;    @(negedge clk);
        chk_semi("C4 both faders zero => 0", 0);
        ch2 = 12'd0;    ch3 = 12'd2048; @(negedge clk);
        chk_semi("C5 right mid => +6", 6);
        ch2 = 12'd0;    ch3 = 12'd2047; @(negedge clk);
        chk_semi("C6 right just below mid => +5", 5);
        ch2 = 12'd0;    ch3 = 12'd342;  @(negedge clk);
        chk_semi("C7 right first step => +1", 1);
        ch2 = 12'd0;    ch3 = 12'd341;  @(negedge clk);
        chk_semi("C8 right just below first step => 0", 0);
        ch2 = 12'd3754; ch3 = 12'd0;    @(negedge clk);
        chk_semi("C9 left at step-11 threshold => -11", -11);
        ch2 = 12'd3753; ch3 = 12'd0;    @(negedge clk);
        chk_semi("C10 left just below step-11 threshold => -10", -10);
        ch2 = 12'd683;  ch3 = 12'd1365; @(negedge clk);
        chk_semi("C11 left step2 / right step4 => +2", 2);

        // ── ⭐ C12：⭐ 全 4096 点扫描 —— 比较链必须**逐值等于** floor(ch*12/4095)
        ch2 = 12'd0;
        for (c = 0; c <= 4095; c = c + 1) begin
            ch3 = c[11:0];
            @(negedge clk);
            e = (c * 12) / 4095;
            if (semi != e) sweep_bad = sweep_bad + 1;
        end
        chk("C12a right-fader sweep: all 4096 points == floor(c*12/4095)",
            sweep_bad == 0);
        sweep_bad = 0;
        ch3 = 12'd0;
        for (c = 0; c <= 4095; c = c + 1) begin
            ch2 = c[11:0];
            @(negedge clk);
            e = (c * 12) / 4095;
            if (semi != (-e)) sweep_bad = sweep_bad + 1;
        end
        chk("C12b left-fader sweep: all 4096 points == -floor(c*12/4095)",
            sweep_bad == 0);
        ch2 = 12'd0; ch3 = 12'd0; @(negedge clk);
        chk_semi("C13 sweep left no residue", 0);

        // ═══════════════════════════════════════════════════════════════
        //  D · ⭐ 'J' 只在 档 0 ⇄ 档 1（⭐ 档 2/3 不可达）
        // ═══════════════════════════════════════════════════════════════
        pulse_gear(); chk("D1 2nd press -> gear1", gear == 2'd1);
        ch2 = 12'h456; ch3 = 12'h789; @(negedge clk);
        chk("D2 gear1 again: vibrato follows faders",
            vdepth === 12'h456 && vrate === 12'h789);
        pulse_gear(); chk("D3 3rd press -> gear0", gear == 2'd0);
        pulse_gear(); chk("D4 4th press -> gear1", gear == 2'd1);
        pulse_gear(); chk("D5 5th press -> gear0", gear == 2'd0);
        pulse_gear(); chk("D6 6th press -> gear1", gear == 2'd1);
        chk("D7 gear never reached 2/3 (continuous monitor)", bad_gear == 0);

        // ═══════════════════════════════════════════════════════════════
        //  E · ⭐ 'F'/'G'/'H'（⭐ 档 1 ⇒ 推子不驱动变调 ⇒ 命令能钉住）
        // ═══════════════════════════════════════════════════════════════
        pulse_abs(8'd12);
        chk_semi("E1 'H' 12 => no transposition", 0);
        for (c = 0; c < 20; c = c + 1) pulse_up();
        chk_semi("E2 'G' x20 clamps at +12", 12);
        pulse_up();
        chk_semi("E3 'G' beyond +12 stays +12 (no wrap)", 12);
        for (c = 0; c < 30; c = c + 1) pulse_down();
        chk_semi("E4 'F' x30 clamps at -12", -12);
        pulse_down();
        chk_semi("E5 'F' beyond -12 stays -12 (no wrap)", -12);
        pulse_abs(8'd0);   chk_semi("E6 'H' 0  => -12", -12);
        pulse_abs(8'd24);  chk_semi("E7 'H' 24 => +12", 12);
        pulse_abs(8'd6);   chk_semi("E8 'H' 6  => -6",  -6);
        pulse_abs(8'd18);  chk_semi("E9 'H' 18 => +6",   6);
        pulse_abs(8'd25);  chk_semi("E10 'H' 25 => +12 (clamp)", 12);
        //   ⭐ E11 专守"只取 [4:0] 会截成 12 ⇒ 静默变成不调"这个坑
        pulse_abs(8'd44);  chk_semi("E11 'H' 44 => +12 (NOT 12/unchanged)", 12);
        pulse_abs(8'd31);  chk_semi("E12 'H' 31 => +12 (clamp)", 12);
        pulse_abs(8'd255); chk_semi("E13 'H' 255 => +12 (clamp)", 12);
        pulse_abs(8'd12);  chk_semi("E14 'H' 12 back to 0", 0);
        pulse_down();      chk_semi("E15 'F' from 0 => -1", -1);
        pulse_up();        chk_semi("E16 'G' from -1 => 0", 0);

        // ═══════════════════════════════════════════════════════════════
        //  F · ⭐ 共用目标寄存器 ＋ ⭐⭐ P3.1（A′）：⭐ 档 0 下串口**生效并保持**
        //
        //   ⭐ 语义变更（⭐ 2026-10-03 用户拍板 A′，⭐ 见 §七）：
        //      P3  版：⭐ 档 0 **每拍跟踪** ⇒ 串口值只活 1 拍（⭐ 旧 F4 期望 0）
        //      P3.1版：⭐ 档 0 只在**推子值变化时**接管 ⇒ 串口值**保持** ✅
        //   ⚠️ 本条只改「**何时接管**」—— ⛔ 判据语义（档 0 串口/推子共用同一寄存器）
        //      没删；⭐ "档 0 推子跟随"由 F8/F9 继续守住 ✅
        // ═══════════════════════════════════════════════════════════════
        pulse_gear();                       // -> gear0
        chk("F1 in gear0", gear == 2'd0);
        ch2 = 12'd0; ch3 = 12'd0; @(negedge clk);
        chk_semi("F2 gear0 faders zero => 0", 0);
        pulse_up();
        chk_semi("F3 gear0: 'G' takes effect on its own cycle => +1", 1);
        @(negedge clk);
        //   ⭐⭐ 旧判据 "F4 gear0: fader re-asserts next cycle" 期望 0 ⇒ 改为期望 1
        chk_semi("F4 [P3.1] gear0: 'G' value HOLDS next cycle (serial kept)", 1);
        repeat (8) @(negedge clk);
        chk_semi("F5 [P3.1] gear0: still holds after 8 more cycles", 1);
        pulse_abs(8'd6);
        chk_semi("F6 [P3.1] gear0: 'H' 6 => -6", -6);
        repeat (4) @(negedge clk);
        chk_semi("F7 [P3.1] gear0: 'H' value holds 4 cycles (no re-tracking)", -6);
        //   ⭐ "档 0 推子跟随"**仍然成立** —— ⭐ 只是改成"推子动一下才接管"
        ch3 = 12'd2048; @(negedge clk);
        chk_semi("F8 [P3.1] gear0: fader MOVED => takes over immediately (+6)", 6);
        repeat (4) @(negedge clk);
        chk_semi("F9 [P3.1] gear0: after takeover, holds (+6, fader untouched)", 6);
        pulse_down();
        chk_semi("F10 [P3.1] gear0: 'F' from +6 => +5 (serial wins while fader still)", 5);
        repeat (4) @(negedge clk);
        chk_semi("F11 [P3.1] gear0: +5 holds 4 cycles", 5);

        // ═══════════════════════════════════════════════════════════════
        //  G · ⭐⭐ P3.1 新增判据（⭐ 来源：§七 第 3 / 4 条）
        //     ⭐ ④ 切档瞬间（档 1 → 档 0）接管**当前**推子位置
        //     ⭐ ③ 复位后不误触发（⭐ `fader_enc_q` 复位 = 推子初值对应的编码）
        // ═══════════════════════════════════════════════════════════════
        // ④-a ⭐ 先在档 1 用串口把编码钉在 +12，再切档 ⇒ ⭐ 必须是推子位置
        pulse_gear(); chk("G1 back to gear1", gear == 2'd1);
        ch2 = 12'd0; ch3 = 12'd3754; @(negedge clk);   // 右档位 11
        pulse_abs(8'd24);
        chk_semi("G2 gear1: 'H' 24 => +12 (serial pins in gear1)", 12);
        pulse_gear();                                  // -> gear0
        chk("G3 in gear0", gear == 2'd0);
        @(negedge clk);                                // ⭐ 接管发生在切档后的下一拍
        chk_semi("G4 [P3.1] gear1->gear0 takes over CURRENT fader (+11, not +12)", 11);
        repeat (4) @(negedge clk);
        chk_semi("G5 [P3.1] after gear-switch takeover, holds (+11)", 11);
        // ④-b ⭐ 再走一轮（⭐ 每次切进来都要重新接管）
        ch3 = 12'd0; @(negedge clk);
        chk_semi("G6 gear0: fader moved => 0", 0);
        pulse_gear(); chk("G7 -> gear1", gear == 2'd1);
        ch2 = 12'd1024; ch3 = 12'd0; @(negedge clk);   // 左档位 3
        pulse_abs(8'd24);                              // 串口 +12（⭐ 档 1 能钉住）
        chk_semi("G8 gear1: 'H' 24 => +12 again", 12);
        pulse_gear(); chk("G9 -> gear0", gear == 2'd0);
        @(negedge clk);
        chk_semi("G10 [P3.1] 2nd gear-switch also takes over (-3, not +12)", -3);

        // ③ ⚠️⚠️ **本组是【冒烟检查】—— ⛔ 不是"能红"判据**（⭐ 2026-10-03 裁定）
        //    🔴 **为什么**：⭐ 本组在**结构上不可观测** ——
        //       ⭐ P3.1 实测：⭐ M3（⭐ 去掉边沿寄存器的复位赋值）与
        //          M4（⭐ 把复位值写错）**全部 PASS**。⭐ 机制：
        //         · `gear_o` 复位 = **1** ⇒ ⭐ 档 0 的接管分支当拍**根本不成立**
        //         · ⭐ 且切进档 0 的**那一拍**由 `gear0_enter` **无条件**兜底
        //         · ⭐ 而 `fader_enc_q` 每拍被**无条件刷新**（⭐ `<= fader_enc`）
        //       ⇒ ⭐ **1 拍自愈** ⇒ ⭐ 复位值写错也测不出来。
        //    ⭐ 处置（⭐ 用户二选一，⭐ 取 (a)）：
        //       (a) ⭐ **明确标注为冒烟检查**（⭐ 本组现状）—— ⛔ 不声称"能红"，
        //           ⭐ 但它仍能抓"复位后输出 X / 不确定"这类**真实**故障 ✅
        //       (b) ⚠️ 造层次探针（⭐ `dut.fader_enc_q`）让它真能红 ——
        //           ⭐ 项目里已有先例，⚠️ 但真实风险已被"1 拍自愈"覆盖 ⇒ ⭐ 不做。
        //    📌 **判据本身逐条保留**（⛔ 一条不删），⭐ 只在名字里标 `[smoke]`。
        //
        //    把推子**按在复位初值（0）上**跨过复位
        //    ⇒ ⭐ 复位后**不动推子**进档 0 ⇒ 必须是【确定的 0】（⛔ 不是 X）
        //      ⚠️ `chk_semi` 用 `==` ⇒ ⭐ X 一定 FAIL（⭐ 这正是本条的守点）
        ch2 = 12'd0; ch3 = 12'd0;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        chk("G11 [smoke] reset -> gear back to 1", gear == 2'd1);
        pulse_gear();                                  // -> gear0（⭐ 切档接管）
        @(negedge clk);
        chk_semi("G12 [smoke] after reset, untouched faders in gear0 => 0 (determinate)", 0);
        repeat (8) @(negedge clk);
        chk_semi("G13 [smoke] stays 0 for 8 cycles (no false 'fader moved')", 0);
        // ③-b ⭐ 复位时推子**不在**初值上 ⇒ 复位后第一次进档 0 仍须是确定值
        ch2 = 12'hFFF; ch3 = 12'd0;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        pulse_gear();                                  // -> gear0
        @(negedge clk);
        chk_semi("G14 [smoke] reset w/ fader at FFF => -12 (determinate, not X)", -12);
        repeat (4) @(negedge clk);
        chk_semi("G15 [smoke] and it holds (-12)", -12);

        // ═══════════════════════════════════════════════════════════════
        //  H · ⭐⭐ P3.2 新增判据（⭐ 2026-10-03）
        //
        //   🔴 **病灶（⭐ P3.1 留下的、⭐ 上板才暴露的真问题）**：
        //      ⭐ P3.1 的 `fader_moved` 比较的是**原始 12 位**
        //      （⭐ `(ch2_i != ch2_q) || (ch3_i != ch3_q)`）⇒
        //      ⚠️ 推子**静止**时 ADC 抖 ±1 LSB ⇒ ⭐ 该式**每拍为真**
        //      ⇒ ⭐ 档 0 下串口设的值**仍被覆盖**（⭐ A′ 的目的落空）。
        //      📌 本项目 `calib` 目前**旁路**（⭐ `rtl/top.v:1637` 附近）
        //         ⇒ ⭐ 抖动**没有任何滤波** ⇒ ⭐ 这个风险是**真的**。
        //   ⭐ **修法**：⭐ 比较对象换成**量化后的档位编码** `fader_enc`（0..24）
        //      ⇒ ⭐ ±1 LSB 只要**没跨过半音档边界** ⇒ ⛔ 不触发接管
        //      （⭐ 相当于**天然的迟滞/死区** ✅）
        //   ⭐ 档边界（⭐ = `gear_step_of` 的阈值，⭐ 见 `rtl/w3a/fader_gear.v`）：
        //      … 342(step1) | 683(step2) | 1024(step3) | 1365(step4) |
        //        1707(step5) | 2048(step6) | 2389 | 2730 | 3072 | 3413 | 3754 | 4095
        //      ⇒ ⭐ 2000 落在 **step 5 的中间**（⭐ 1999/2001 都还是 step 5）
        //      ⇒ ⭐ 1706 = step 4 · 1707 = step 5 · 2048 = step 6（⭐ 三条边界样本）
        //   ⚠️ 组字母 `H` ⛔ 与串口命令 `'H'` **无关**（⭐ 只是 A..G 的下一组）。
        // ═══════════════════════════════════════════════════════════════
        chk("H1 [P3.2] still in gear0 (carried over from G)", gear == 2'd0);
        //   ⭐ 把推子放到 step 5 的**中间**（⭐ 2000；⭐ ±1 LSB 都还在 step 5）
        ch2 = 12'd2000; ch3 = 12'd0; @(negedge clk);
        chk_semi("H2 [P3.2] fader 2000/0 => takeover (step5 => -5)", -5);
        pulse_abs(8'd24);
        chk_semi("H3 [P3.2] 'H' 24 pins serial to +12", 12);

        // ① ⭐⭐ ±1 LSB 抖动 **不**触发接管（⭐ 每拍都查 ⇒ ⛔ 不能"只活 1 拍"）
        //    🔴 能红证据：⭐ 把 `fader_moved` 改回原始 12 位比较 ⇒ ⭐ 本拍必红
        h_bad = 0;
        for (c = 0; c < 24; c = c + 1) begin
            ch2 = (c % 2 == 0) ? 12'd1999 : 12'd2001;   // ⭐ ±1 LSB dither
            @(negedge clk);
            if (semi != 12) h_bad = h_bad + 1;
        end
        chk_cnt("H4 [P3.2] ch2 +-1 LSB dither x24 => serial +12 held EVERY cycle",
                h_bad);
        //   ⭐ 抖动回到中间值（⭐ 原始位仍变过，⭐ 但档位没变）⇒ ⭐ 仍不接管
        ch2 = 12'd2000; @(negedge clk);
        chk_semi("H5 [P3.2] ch2 back to 2000 (same step) => +12 still holds", 12);
        //   ⭐ CH3 也抖（⭐ 0<->1 都还是 step 0）⇒ ⭐ 仍不接管
        h_bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            ch3 = (c % 2 == 0) ? 12'd1 : 12'd0;
            @(negedge clk);
            if (semi != 12) h_bad = h_bad + 1;
        end
        chk_cnt("H6 [P3.2] ch3 +-1 LSB dither (0<->1) x8 => +12 held EVERY cycle",
                h_bad);
        ch3 = 12'd0; @(negedge clk);

        // ② ⭐⭐ **跨过半音档边界才**触发接管（⭐ 用户真的推动了推子）
        ch2 = 12'd1706; @(negedge clk);   // ⭐ step 4（⭐ 1707 是 step5 的下边界）
        chk_semi("H7 [P3.2] crossing the 1707 edge downward => takeover (step4 => -4)",
                 -4);
        pulse_abs(8'd24);
        chk_semi("H8 [P3.2] serial re-pinned to +12", 12);
        ch2 = 12'd1707; @(negedge clk);   // ⭐ step 5
        chk_semi("H9 [P3.2] crossing the 1707 edge upward => takeover (step5 => -5)",
                 -5);
        pulse_abs(8'd24);
        ch2 = 12'd2048; @(negedge clk);   // ⭐ step 6
        chk_semi("H10 [P3.2] crossing the 2048 edge => takeover (step6 => -6)", -6);
        //   ⭐ 边界**同侧**的 ±1 抖动 ⇒ ⭐ 仍不接管（⭐ 再次钉住串口值）
        pulse_abs(8'd24);
        h_bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            ch2 = (c % 2 == 0) ? 12'd2049 : 12'd2048;   // ⭐ 都还在 step 6
            @(negedge clk);
            if (semi != 12) h_bad = h_bad + 1;
        end
        chk_cnt("H11 [P3.2] +-1 LSB dither just ABOVE the 2048 edge => +12 held EVERY cycle",
                h_bad);

        if (errors == 0)
            $display("PASS: fader_gear gear table / clamp / zero-regression all hold");
        else
            $fatal(1, "FAIL: tb_fader_gear has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL: tb_fader_gear timeout");
    end
endmodule
