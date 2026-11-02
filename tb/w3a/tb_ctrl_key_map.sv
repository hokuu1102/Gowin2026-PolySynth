`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_ctrl_key_map.sv -- 控制板「键映射」判据（只测 ctrl_key_map，不测扫描/去抖）
//
// 被测：rtl/w3a/ctrl_key_map.v（16 键 -> 命令脉冲）
//
// 为什么要与 tb_ctrl_keypad.sv 分开：
//   tb_ctrl_keypad.sv 走的是"真实矩阵 + 扫描 + 去抖"整条链，
//   它验的是"定位 + 去抖 + 映射"三件事合起来。
//   而本轮新增的 idx 13「loop 发送」需要几条**它表达不了**的判据：
//     · idx 13 短按 ⇒ 恰好一个脉冲（沿触发）
//     · idx 13 长按 ⇒ 仍然只有一个脉冲（⭐ 证明没有长按保护误伤）
//     · 按别的键（尤其 idx 12 / idx 9）⇒ loop_send_req_o 必须为 0（反向证伪）
//   这些判据必须能**直接驱动 key_down/key_up**，所以这里单独做一个抓模块的 tb。
//
// 驱动方式：绕开 ctrl_keypad，直接给 key_level / key_down / key_up 打拍
//   —— 这与 ctrl_key_map 的端口契约完全一致（它就是"去抖后的三组信号"）。
//
// 判据（每条都必须能失败）：
//   A) idx 13 短按 ⇒ loop_send_req_o 出现【正好一个】单周期脉冲
//   B) idx 13 长按 ⇒ 仍然【只有一个】脉冲（证明没被长按保护误伤/不会连发）
//   C) 已有 15 键逐位不变（逐键扫 ⇒ 各 req 恰好一次，且 loop_send 恒 0）
//   D) 反向证伪：按 idx 9（fx 占位）/ idx 12（长按清空）⇒ loop_send_req_o == 0
//   E) 未接板（全 0）⇒ 无任何脉冲
// -----------------------------------------------------------------------------

module tb_ctrl_key_map;

    localparam integer CLK_HZ  = 1000;   // 1 拍 = 1 ms（只为换算 LONG_CYC）
    localparam integer LONG_MS = 600;    // => LONG_CYC = 600 拍

    integer errors = 0;

    task chk;
        input [8*160-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    // ── DUT 输入（直接驱动，绕开扫描/去抖）────────────────────────────────
    reg  [15:0] key_level;
    reg  [15:0] key_down;
    reg  [15:0] key_up;

    // ── DUT 输出 ──────────────────────────────────────────────────────────
    wire met_req, timbre_req, slide_req, scope_req, keydrum_req, gear_req;
    wire trans_up_req, trans_dn_req, drum_pat_req, testmode_req, loop_clr_req;
    wire mode_req, fb_piano, tare_req, span_req, fx_req;
    wire uplink_req;
    integer n_uplink;
    wire trans_reset_req;
    wire loop_send_req;      // ⭐ 本轮新增：idx 13

    ctrl_key_map #(
        .CLK_HZ  (CLK_HZ),
        .LONG_MS (LONG_MS)
    ) u_map (
        .clk                (clk),
        .rst_n              (rst_n),
        .key_level          (key_level),
        .key_down           (key_down),
        .key_up             (key_up),
        .met_req_o          (met_req),
        .timbre_req_o       (timbre_req),
        .slide_req_o        (slide_req),
        .scope_mode_req_o   (scope_req),
        .keydrum_req_o      (keydrum_req),
        .gear_next_req_o    (gear_req),
        .trans_up_req_o     (trans_up_req),
        .trans_down_req_o   (trans_dn_req),
        .trans_reset_req_o  (trans_reset_req),
        .drum_pattern_req_o (drum_pat_req),
        .test_mode_req_o    (testmode_req),
        .loop_clear_req_o   (loop_clr_req),
        .loop_send_req_o    (loop_send_req),   // ⭐ 本轮新增
        .mode_req_o         (mode_req),
        .fb_piano_o         (fb_piano),
        .uplink_toggle_req_o(uplink_req),
        .tare_req_o         (tare_req),
        .span_req_o         (span_req),
        .fx_req_o           (fx_req)
    );

    // ── 脉冲计数 ──────────────────────────────────────────────────────────
    integer n_met, n_timbre, n_slide, n_scope, n_keydrum, n_gear;
    integer n_up, n_dn, n_dpat, n_tmode, n_lclr, n_mode, n_tare, n_span, n_fx;
    integer n_kdown, n_kup;
    integer n_treset;
    integer n_lsend;

    always @(posedge clk) begin
        if (rst_n) begin
            if (met_req)       n_met     = n_met     + 1;
            if (timbre_req)    n_timbre  = n_timbre  + 1;
            if (slide_req)     n_slide   = n_slide   + 1;
            if (scope_req)     n_scope   = n_scope   + 1;
            if (keydrum_req)   n_keydrum = n_keydrum + 1;
            if (gear_req)      n_gear    = n_gear    + 1;
            if (trans_up_req)  n_up      = n_up      + 1;
            if (trans_dn_req)  n_dn      = n_dn      + 1;
            if (drum_pat_req)  n_dpat    = n_dpat    + 1;
            if (testmode_req)  n_tmode   = n_tmode   + 1;
            if (loop_clr_req)  n_lclr    = n_lclr    + 1;
            if (mode_req)      n_mode    = n_mode    + 1;
            if (uplink_req) n_uplink = n_uplink + 1;
            if (tare_req)      n_tare    = n_tare    + 1;
            if (span_req)      n_span    = n_span    + 1;
            if (fx_req)        n_fx      = n_fx      + 1;
            if (trans_reset_req) n_treset = n_treset  + 1;
            if (loop_send_req)   n_lsend  = n_lsend   + 1;
            if (key_down != 16'd0) n_kdown = n_kdown + 1;
            if (key_up   != 16'd0) n_kup   = n_kup   + 1;
        end
    end

    task zero_counters;
        begin
            n_met=0; n_timbre=0; n_slide=0; n_scope=0; n_keydrum=0; n_gear=0;
            n_up=0; n_dn=0; n_dpat=0; n_tmode=0; n_lclr=0; n_mode=0;
            n_uplink=0; n_tare=0; n_span=0; n_fx=0; n_kdown=0; n_kup=0; n_treset=0;
            n_lsend=0;
        end
    endtask

    // ── 驱动原语：一个 key_down 脉冲 + 对应 key_level ─────────────────────
    //   ⭐⭐ 时序契约（关键，踩过）：
    //     `ctrl_keypad` 的 key_down/key_up 是**单拍脉冲**（正好被一个
    //     posedge 采样到一次）。所以这里必须保证：
    //        拉高 → 只跨一个 posedge → 立刻拉低
    //     ⚠️ 若写成 `@(posedge clk); key_down=1; @(posedge clk); key_down=0;`
    //       那就跨了**两个** posedge ⇒ 采样到两次 ⇒ "恰好一个脉冲"判据必红。
    //     ⭐ 正确做法：在 posedge **之后**（相位 180°）拉高，再在同一相位拉低。
    task pulse_down;          // 单拍 key_down[idx]
        input integer idx;
        begin
            #10;                       // posedge 之后的半周期
            key_down[idx] = 1'b1;
            #20;                       // 跨过下一个 posedge（被采样一次）
            key_down[idx] = 1'b0;
        end
    endtask

    task pulse_up;            // 单拍 key_up[idx]
        input integer idx;
        begin
            #10;
            key_up[idx] = 1'b1;
            #20;
            key_up[idx] = 1'b0;
        end
    endtask

    task tap_key;            // 短按：按下（电平 + 单拍沿），保持 N 拍再松开
        input integer idx;
        input integer hold_cycles;
        begin
            key_level[idx] = 1'b1;
            pulse_down(idx);
            repeat (hold_cycles) @(posedge clk);
            pulse_up(idx);
            key_level[idx] = 1'b0;
        end
    endtask

    task hold_key;           // 只按不松（电平 + 一个单拍沿）
        input integer idx;
        begin
            key_level[idx] = 1'b1;
            pulse_down(idx);
        end
    endtask

    task release_key;
        input integer idx;
        begin
            pulse_up(idx);
            key_level[idx] = 1'b0;
        end
    endtask

    integer i, k;

    initial begin
        key_level = 16'd0;
        key_down  = 16'd0;
        key_up    = 16'd0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== A) idx 13 (loop send): short press => exactly ONE pulse ===");
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        tap_key(13, 20);                       // 短按（远小于 LONG_MS=600 拍）
        repeat (5) @(posedge clk);
        chk("A1: idx 13 fires loop_send_req exactly once", n_lsend == 1);
        //  ⭐ 非空判据：证明这一条真的跑到了（不是恒零的假绿）
        chk("A2: non-vacuity -- it DID fire (not silently zero)", n_lsend == 1);
        chk("A3: and it fired NO other command",
            (n_met+n_timbre+n_slide+n_scope+n_keydrum+n_gear+n_up+n_dn
             +n_dpat+n_tmode+n_lclr+n_mode+n_uplink+n_tare+n_span+n_fx+n_treset) == 0);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== B) idx 13 held DOWN (long): still exactly ONE pulse ===");
        //   ⭐ 这一条证明 idx 13 【没有】长按保护：
        //      若误加了阈值判定，长按会"一个都不发"；若误挂在 key_level 上，
        //      则会"每拍都发"。两者都必须红。
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        hold_key(13);
        repeat (LONG_MS * 3) @(posedge clk);   // 远超长按阈值
        chk("B1: after holding far past LONG_MS, still exactly ONE pulse", n_lsend == 1);
        repeat (LONG_MS * 3) @(posedge clk);
        chk("B2: holding even longer does NOT repeat it (one-shot)", n_lsend == 1);
        release_key(13);
        repeat (10) @(posedge clk);
        chk("B3: releasing does NOT produce a second pulse either", n_lsend == 1);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== C) all OTHER keys still map bit-for-bit as before ===");
        //   ⭐ 逐键扫（跳过 12/15，它们的长按语义在 D 里单独验）
        // ═════════════════════════════════════════════════════════════════
        begin : sweep
            integer kk;
            for (kk = 0; kk < 16; kk = kk + 1) begin
                if (kk != 12 && kk != 15) begin
                    zero_counters;
                    tap_key(kk, 20);
                    repeat (5) @(posedge clk);
                    case (kk)
                        0:  chk("C: idx 0  -> met_req once",           n_met == 1);
                        1:  chk("C: idx 1  -> timbre_req once",        n_timbre == 1);
                        2:  chk("C: idx 2  -> slide_req once",         n_slide == 1);
                        3:  chk("C: idx 3  -> scope_mode_req once",    n_scope == 1);
                        4:  chk("C: idx 4  -> keydrum_req once",       n_keydrum == 1);
                        5:  chk("C: idx 5  -> gear_next_req once",     n_gear == 1);
                        6:  chk("C: idx 6  -> trans_up_req once",      n_up == 1);
                        7:  chk("C: idx 7  -> mode_req once",          n_mode == 1);
                        8:  chk("C: idx 8  -> drum_pattern_req once",  n_dpat == 1);
                        9:  chk("C: idx 9  -> fx_req once (placeholder)", n_fx == 1);
                        10: chk("C: idx 10 -> trans_down_req once",    n_dn == 1);
                        11: chk("C: idx 11 -> test_mode_req once",     n_tmode == 1);
                        13: chk("C: idx 13 -> loop_send_req once",     n_lsend == 1);
                        14: chk("C: idx 14 -> trans_reset_req once",   n_treset == 1);
                        default: chk("C: unreachable idx", 1'b0);
                    endcase
                    //  ⭐ 反向证伪：任何非 13 的键都不许产生 loop_send
                    if (kk != 13)
                        chk("C: cross-check -- that key did NOT fire loop_send",
                            n_lsend == 0);
                    //  ⭐ 一次只发一个命令（防止一键多脉冲）
                    chk("C: that key fired exactly ONE command total",
                        (n_met+n_timbre+n_slide+n_scope+n_keydrum+n_gear+n_up+n_dn
                         +n_dpat+n_tmode+n_lclr+n_mode+n_uplink+n_tare+n_span+n_fx+n_treset
                         +n_lsend) == 1);
                end
            end
        end

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== D) reverse disproof: other keys must NOT fire loop_send ===");
        // ═════════════════════════════════════════════════════════════════
        //  D1: idx 9 = fx 占位（最容易与"效果器/loop"混淆）
        zero_counters;
        tap_key(9, 20);
        repeat (5) @(posedge clk);
        chk("D1: idx 9 (fx placeholder) fires fx_req", n_fx == 1);
        chk("D2: idx 9 (fx placeholder) does NOT fire loop_send", n_lsend == 0);

        //  D2: idx 12 short press -- 不许有 loop_clear、更不许有 loop_send
        zero_counters;
        tap_key(12, 20);                       // 短按清空键
        repeat (5) @(posedge clk);
        chk("D3: idx 12 SHORT press does NOT clear the looper", n_lclr == 0);
        chk("D4: idx 12 SHORT press does NOT fire loop_send either", n_lsend == 0);

        //  D3: idx 12 LONG press -- loop_clear 恰好一次，loop_send 仍为 0
        zero_counters;
        hold_key(12);
        repeat (LONG_MS * 2) @(posedge clk);
        chk("D5: idx 12 LONG press fires loop_clear_req exactly once", n_lclr == 1);
        chk("D6: idx 12 LONG press still does NOT fire loop_send", n_lsend == 0);
        repeat (LONG_MS * 2) @(posedge clk);
        chk("D7: idx 12 holding longer is still one-shot (clear)", n_lclr == 1);
        chk("D8: ...and still zero loop_send", n_lsend == 0);
        release_key(12);

        //  D4: idx 15 短按/长按互斥保持原样，loop_send 恒 0
        zero_counters;
        tap_key(15, 20);
        repeat (5) @(posedge clk);
        chk("D9: idx15 SHORT release -> uplink once, no tare", n_uplink == 1 && n_tare == 0);
        chk("D10: idx 15 SHORT press -> NO span (unchanged)",   n_span == 0);
        chk("D11: idx 15 SHORT press -> no loop_send",          n_lsend == 0);

        zero_counters;
        hold_key(15);
        repeat (LONG_MS * 2) @(posedge clk);
        //  ⭐⭐ 2026-10-17（用户裁定删除 span）：⭐ 长按**不再发 span** ✅
        //     🔴 原期望 `n_span == 1`（"长按 = 满量程标定"）—— 该功能已删除，
        //        `span_req_o` 现在恒 0 ⇒ ⭐ 期望必须改成 0，否则判据与实现脱节 ✅
        chk("D12: idx 15 LONG press -> span NEVER fires (span removed 2026-10-17)", n_span == 0);
        chk("D13: idx15 hold -> no uplink, tare or loop_send", n_uplink == 0 && n_tare == 0 && n_lsend == 0);
        release_key(15);
        repeat (10) @(posedge clk);
        //  ⭐⭐ 2026-10-17：⭐ 长按后松手**现在会发 tare** ✅
        //     🔴 原期望 `n_tare == 0`（长按已被 span 吃掉 ⇒ 松手不再发 tare）
        //     ✅ 现在没有长按分支 ⇒ `cal_long_fired` 恒 0 ⇒ 松手必发 `tare_req_o`
        //        ⭐ 这正是用户要的"标定键只相当于发 T" ✅
        chk("D14: LONG release -> uplink once, no tare",
            n_uplink == 1 && n_tare == 0);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== E) nothing pressed at all => no pulse anywhere ===");
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        repeat (50) @(posedge clk);
        chk("E1: idle key_level produces no key_down/key_up",
            (n_kdown == 0) && (n_kup == 0));
        chk("E2: idle produces NO command pulse at all (incl. loop_send)",
            (n_met+n_timbre+n_slide+n_scope+n_keydrum+n_gear+n_up+n_dn+n_dpat
             +n_tmode+n_lclr+n_mode+n_uplink+n_tare+n_span+n_fx+n_treset+n_lsend) == 0);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        if (errors == 0)
            $display("PASS: ctrl_key_map -- idx 13 loop_send is a one-cycle short-press pulse (no long-press guard), every other key still maps bit-for-bit, and no other key can fire loop_send");
        else
            $fatal(1, "FAIL: ctrl_key_map had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
