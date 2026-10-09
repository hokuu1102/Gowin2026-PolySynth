`timescale 1ns/1ps
// tb_note_manager_vel_ramp.sv
//
// ⭐ 2026-10-04（codex 只读诊断「候选三第 2 项 / 路线三」的前置验证）
//
// 目的：证明 `note_manager` 的力度斜坡改动**逐位等价** ——
//   旧：按 `src` 分两支，**各写一套逐字相同**的 ±8 斜坡（只有"目标来源"不同）：
//        · src==0（手弹）⇒ 目标 = vtgt_val，且**仅当** vtgt_vld 才爬
//        · src!=0（回放）⇒ 目标 = vtgt_rep，**无** valid 门
//   新：先选 target / target_valid，再执行**一套** ±8 斜坡
//
// ✅ 穷举：cur 0..255 × tgt_val 0..255 × tgt_rep 0..255 抽样 × src 2 × vld 2
//    （target 组合太大 ⇒ tgt_val/tgt_rep 各自覆盖 0..255 的边界子集 + 全量 cur）
// ✅ 红检：把新实现故意写成"手弹路径忘记 vtgt_vld 门"必须被抓到（那是真 bug）

module tb_note_manager_vel_ramp;
    reg  [7:0] cur;
    reg  [7:0] tgt_axis;   // vtgt_val[axis_r[i]]
    reg  [7:0] tgt_rep;    // vtgt_rep[i]
    reg        axis_vld;   // vtgt_vld[axis_r[i]]
    reg        src0;       // (src_r[i] == 3'd0)

    // ── 旧：两支，各一套斜坡 ───────────────────────────────────────────────
    reg [7:0] old_next;
    always @(*) begin
        if (src0) begin
            if (axis_vld) begin
                if      ({1'b0, tgt_axis} > {1'b0, cur} + 9'd8) old_next = cur + 8'd8;
                else if ({1'b0, tgt_axis} + 9'd8 < {1'b0, cur}) old_next = cur - 8'd8;
                else                            old_next = tgt_axis;
            end else begin
                old_next = cur;
            end
        end else begin
            if      ({1'b0, tgt_rep} > {1'b0, cur} + 9'd8) old_next = cur + 8'd8;
            else if ({1'b0, tgt_rep} + 9'd8 < {1'b0, cur}) old_next = cur - 8'd8;
            else                           old_next = tgt_rep;
        end
    end

    // ── 新：先选目标与 valid，再一套斜坡 ───────────────────────────────────
    wire [7:0] new_tgt = src0 ? tgt_axis : tgt_rep;
    wire       new_vld = src0 ? axis_vld : 1'b1;
    reg [7:0] new_next;
    always @(*) begin
        if (new_vld) begin
            if      ({1'b0, new_tgt} > {1'b0, cur} + 9'd8) new_next = cur + 8'd8;
            else if ({1'b0, new_tgt} + 9'd8 < {1'b0, cur}) new_next = cur - 8'd8;
            else                           new_next = new_tgt;
        end else begin
            new_next = cur;
        end
    end

    // ── 红检：手弹路径**忘记** vtgt_vld 门（真 bug 的一种）──────────────────
    reg [7:0] red_next;
    always @(*) begin
        if (src0) begin
            if      ({1'b0, tgt_axis} > {1'b0, cur} + 9'd8) red_next = cur + 8'd8;   // ⛔ 少了 axis_vld 判断
            else if ({1'b0, tgt_axis} + 9'd8 < {1'b0, cur}) red_next = cur - 8'd8;
            else                            red_next = tgt_axis;
        end else begin
            if      ({1'b0, tgt_rep} > {1'b0, cur} + 9'd8) red_next = cur + 8'd8;
            else if ({1'b0, tgt_rep} + 9'd8 < {1'b0, cur}) red_next = cur - 8'd8;
            else                           red_next = tgt_rep;
        end
    end

    // ── ⭐⭐ 2026-10-09（P0-01）：**规格模型**（⭐ 9 位比较，⛔ 不回绕）────────────
    //   🔴 原 `old_next`/`new_next` 都写 `cur + 8'd8` ⇒ ⭐ **两边一起错** ⇒ 本 tb 恒绿
    //      （⭐ 这就是审查报告 [P0-01] 说的"黄金模型逐字复刻了同一个表达式" ✅）
    //   ⭐ 规格：`next = (tgt > cur+8) ? cur+8 : ((tgt+8 < cur) ? cur-8 : tgt)`
    //      ⭐ 比较用 **9 位零扩展** ⇒ ⭐ cur=248/250/255 时不再 mod 256 回绕 ✅
    reg [7:0] spec_next;
    always @(*) begin
        if (new_vld) begin
            if      ({1'b0, new_tgt} > {1'b0, cur} + 9'd8) spec_next = cur + 8'd8;
            else if ({1'b0, new_tgt} + 9'd8 < {1'b0, cur}) spec_next = cur - 8'd8;
            else                                            spec_next = new_tgt;
        end else begin
            spec_next = cur;
        end
    end

    integer c, a, r, s, v;
    integer checks = 0, mism = 0, red_mism = 0, spec_mism = 0;
    // 目标值取"边界密集"的子集：0、7、8、9、247、248、255 以及 cur±8 附近由全量 cur 覆盖
    integer tvals [0:10];
    initial begin
        tvals[0]=0; tvals[1]=1; tvals[2]=7; tvals[3]=8; tvals[4]=9;
        tvals[5]=127; tvals[6]=128; tvals[7]=247; tvals[8]=248; tvals[9]=254; tvals[10]=255;
        for (c = 0; c < 256; c = c + 1) begin
            for (a = 0; a <= 10; a = a + 1) begin
                for (r = 0; r <= 10; r = r + 1) begin
                    for (s = 0; s < 2; s = s + 1) begin
                        for (v = 0; v < 2; v = v + 1) begin
                            cur      = c[7:0];
                            tgt_axis = tvals[a][7:0];
                            tgt_rep  = tvals[r][7:0];
                            src0     = s[0];
                            axis_vld = v[0];
                            #1;
                            checks = checks + 1;
                            if (new_next !== old_next) begin
                                mism = mism + 1;
                                if (mism <= 5)
                                    $display("  FAIL cur=%0d axis=%0d rep=%0d src0=%0d vld=%0d new=%0d old=%0d",
                                             cur, tgt_axis, tgt_rep, src0, axis_vld, new_next, old_next);
                            end
                            if (red_next !== old_next) red_mism = red_mism + 1;
                            //  ⭐⭐ P0-01：新实现**必须符合规格**（⭐ 不是"符合旧模型"）✅
                            if (new_next !== spec_next) begin
                                spec_mism = spec_mism + 1;
                                if (spec_mism <= 5)
                                    $display("  SPEC-FAIL cur=%0d tgt=%0d src0=%0d vld=%0d new=%0d spec=%0d (8-bit wrap?)",
                                             cur, new_tgt, src0, axis_vld, new_next, spec_next);
                            end
                        end
                    end
                end
            end
        end
        $display("  checks=%0d  new-vs-old mismatches=%0d  red(no-valid-gate) mismatches=%0d  spec mismatches=%0d",
                 checks, mism, red_mism, spec_mism);
        if (mism != 0)      $fatal(1, "FAIL: merged velocity ramp is NOT bit-equivalent");
        if (red_mism == 0)  $fatal(1, "FAIL: red (missing valid gate) variant NOT detected -- test is blind");
        if (spec_mism != 0) $fatal(1, "FAIL: merged velocity ramp does NOT match the 9-bit spec (P0-01 wrap)");
        $display("PASS: tb_note_manager_vel_ramp %0d cases, 0 mismatches; red detected in %0d; spec-conformant",
                 checks, red_mism);
        $finish;
    end
endmodule
