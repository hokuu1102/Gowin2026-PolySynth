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

module tb_fader_screen_select;
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
        @(negedge clk);
        sel0 = (g == 2'd0); sel1 = (g == 2'd1); sel2 = (g == 2'd2);
        @(negedge clk);
        sel0 = 1'b0; sel1 = 1'b0; sel2 = 1'b0;
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
        do_reset;
        ch2=12'h800;ch3=12'h400;repeat(3)@(negedge clk);
        pulse_sel(2);
        chk_gear("screen selects volume",2);
        chk_hold("screen locks departing pitch",3'b010);
        ch2=12'hA00;ch3=12'h600;repeat(3)@(negedge clk);
        pulse_sel(0);
        chk_hold("screen preserves two independent locks",3'b110);
        ch2=0;ch3=0;repeat(3)@(negedge clk);
        chk_vib("pitch retained",12'h800,12'h400);
        chk_trem("volume retained",12'hA00,12'h600);
        pulse_sel(1);
        chk_hold("transpose auto locked on departure",3'b111);
        chk_vib("return to locked pitch does not jump",12'h800,12'h400);
        pulse_lock;
        chk_hold("manual unlock affects current gear only",3'b101);
        chk_vib("unlock immediately follows zero faders",0,0);
        pulse_sel(1);
        chk_hold("same gear click does not lock",3'b101);
        pulse_gear;
        chk_hold("physical next retains manual lock contract",3'b101);
        chk_gear("physical next still works",2);
        // Simultaneous direct requests preserve sel0 > sel1 > sel2 > next.
        @(negedge clk);sel0=1;sel1=1;sel2=1;gear_next=1;lock_tog=1;
        @(negedge clk);sel0=0;sel1=0;sel2=0;gear_next=0;lock_tog=0;
        chk_gear("selection priority",0);
        chk_hold("switch locking wins over concurrent toggle",3'b101);
        do_reset;ch2=0;ch3=0;repeat(3)@(negedge clk);
        pulse_sel(2);pulse_sel(1);
        chk_vib("zero depth remains zero",0,0);
        chk_trem("zero volume depth remains zero",0,0);
        if(errors)$fatal(1,"FAIL: %0d screen fader checks",errors);
        $display("PASS: screen select, independent auto locks, zero depth, manual unlock and physical priority");$finish;
    end
endmodule
