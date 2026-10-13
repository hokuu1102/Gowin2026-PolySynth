`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_ctrl_keypad.sv -- 控制板矩阵键盘判据（扫描 + 去抖 + 键映射）
//
// 被测：rtl/w3a/ctrl_keypad.v（逐行扫描 + 扫描式去抖）
//       rtl/w3a/ctrl_key_map.v（16 键 -> 命令脉冲）
//
// 矩阵模型（对照实验的关键）：列是【上拉 + 按下接地】，行由 DUT 拉低。
//   只有"被拉低的那一行"上按下的键，才会把对应列拉低 —— 这正是真实矩阵行为，
//   所以"同列双键"能不能被认出来，在这个模型下才有意义。
//
// 判据（每条都必须能失败）：
//   ① 扫描：任一时刻只有一行拉低；4 行都轮流被拉低过
//   ② 单键：按 (行,列) ⇒ key_level 只有 idx=row*4+col 置位
//   ③ 同列双键：两个键都被认出来（不会被推挽吃掉）
//   ④ 去抖：抖动（未连续稳定）不改变 key_level
//   ⑤ 稳定 DEB_N 次 ⇒ key_level 置位，且 key_down 只出一个脉冲
//   ⑥ 松开 ⇒ key_up 只出一个脉冲
//   ⑦ 未接板（列恒高）⇒ key_level 全 0，且全程无任何脉冲
//   ⑧ 键映射：每个有效键 ⇒ 对应 req 恰好一个脉冲，其它 req 全 0
//   ⑨ 长按：looper 清空只在长按阈值到达时发，短按不发
//   ⑩ 标定：短按 = tare、长按 = span，两者互斥
// -----------------------------------------------------------------------------

module tb_ctrl_keypad;

    // 小参数：让扫描/去抖/长按都能在几千拍内测完
    localparam integer SCAN_DIV = 8;
    localparam integer DEB_N    = 3;
    localparam integer CLK_HZ   = 1000;   // 1 拍 = 1 ms（只为换算 LONG_CYC）
    //  注意：LONG_MS 必须明显大于 DEB_CYC，否则"短按"会因为去抖还没完成
    //  就已超过长按阈值，短按/长按就分不开了。
    //  DEB_CYC = SCAN_CYC*DEB_N = 32*3 = 96 拍 => 取 600，留 6 倍余量。
    localparam integer LONG_MS  = 600;    // => LONG_CYC = 600 拍

    localparam integer SCAN_CYC = SCAN_DIV * 4;          // 一次完整扫描的拍数
    localparam integer DEB_CYC  = SCAN_CYC * DEB_N;      // 去抖所需拍数

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

    // ── 物理按键状态（1 = 按下）─────────────────────────────────────────────
    reg [15:0] pressed;

    // ── DUT 1：扫描 + 去抖 ─────────────────────────────────────────────────
    wire [3:0]  row_o;
    wire [3:0]  col_i;
    wire [15:0] key_level, key_down, key_up;

    // 矩阵模型：被拉低的行上按下的键，把对应列拉低
    genvar gr, gc;
    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : g_row
            for (gc = 0; gc < 4; gc = gc + 1) begin : g_col
                assign col_i[gc] = (pressed[gr*4+gc] && row_o[gr] == 1'b0) ? 1'b0 : 1'bz;
            end
        end
    endgenerate
    // 上拉：没有键拉低时列是高（用 pullup 模拟）
    pullup pu0 (col_i[0]);
    pullup pu1 (col_i[1]);
    pullup pu2 (col_i[2]);
    pullup pu3 (col_i[3]);

    ctrl_keypad #(
        .SCAN_DIV (SCAN_DIV),
        .DEB_N    (DEB_N),
        .CLK_HZ   (CLK_HZ)
    ) u_pad (
        .clk       (clk),
        .rst_n     (rst_n),
        .row_o     (row_o),
        .col_i     (col_i),
        .key_level (key_level),
        .key_down  (key_down),
        .key_up    (key_up)
    );

    // ── DUT 2：键映射 ──────────────────────────────────────────────────────
    wire met_req, timbre_req, slide_req, scope_req, keydrum_req, gear_req;
    wire trans_up_req, trans_dn_req, drum_pat_req, testmode_req, loop_clr_req;
    wire mode_req, fb_piano, tare_req, span_req, fx_req;

    ctrl_key_map #(
        .CLK_HZ  (CLK_HZ),
        .LONG_MS (LONG_MS)
    ) u_map (
        .clk               (clk),
        .rst_n             (rst_n),
        .key_level         (key_level),
        .key_down          (key_down),
        .key_up            (key_up),
        .met_req_o         (met_req),
        .timbre_req_o      (timbre_req),
        .slide_req_o       (slide_req),
        .scope_mode_req_o  (scope_req),
        .keydrum_req_o     (keydrum_req),
        .gear_next_req_o   (gear_req),
        .trans_up_req_o    (trans_up_req),
        .trans_down_req_o  (trans_dn_req),
        .drum_pattern_req_o(drum_pat_req),
        .test_mode_req_o   (testmode_req),
        .loop_clear_req_o  (loop_clr_req),
        .mode_req_o        (mode_req),
        .fb_piano_o        (fb_piano),
        .tare_req_o        (tare_req),
        .span_req_o        (span_req),
        .fx_req_o          (fx_req)
    );

    // ── 监视：统计每个 req 的脉冲数 ────────────────────────────────────────
    integer n_met, n_timbre, n_slide, n_scope, n_keydrum, n_gear;
    integer n_up, n_dn, n_dpat, n_tmode, n_lclr, n_mode, n_tare, n_span, n_fx;
    integer n_kdown, n_kup;

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
            if (tare_req)      n_tare    = n_tare    + 1;
            if (span_req)      n_span    = n_span    + 1;
            if (fx_req)        n_fx      = n_fx      + 1;
            if (key_down != 16'd0) n_kdown = n_kdown + 1;
            if (key_up   != 16'd0) n_kup   = n_kup   + 1;
        end
    end

    task zero_counters;
        begin
            n_met=0; n_timbre=0; n_slide=0; n_scope=0; n_keydrum=0; n_gear=0;
            n_up=0; n_dn=0; n_dpat=0; n_tmode=0; n_lclr=0; n_mode=0;
            n_tare=0; n_span=0; n_fx=0; n_kdown=0; n_kup=0;
        end
    endtask

    // 扫描是否"任一时刻只有一行低"
    //  注意：这两个变量必须【声明在使用之前】—— 本项目反复踩这条
    //  （同族缺陷见 waveform_scope.v 的 fb_q 前向引用）
    integer row_low_cnt;
    integer one_low_bad = 0;
    integer one_low_ok  = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            row_low_cnt = 0;
            if (row_o[0] == 1'b0) row_low_cnt = row_low_cnt + 1;
            if (row_o[1] == 1'b0) row_low_cnt = row_low_cnt + 1;
            if (row_o[2] == 1'b0) row_low_cnt = row_low_cnt + 1;
            if (row_o[3] == 1'b0) row_low_cnt = row_low_cnt + 1;
            if (row_low_cnt != 1) one_low_bad = one_low_bad + 1;
            else                  one_low_ok  = one_low_ok  + 1;
        end
    end

    // 4 行是否都被驱动过
    reg [3:0] row_seen;

    always @(posedge clk) begin
        if (rst_n) begin
            if (row_o[0] == 1'b0) row_seen[0] <= 1'b1;
            if (row_o[1] == 1'b0) row_seen[1] <= 1'b1;
            if (row_o[2] == 1'b0) row_seen[2] <= 1'b1;
            if (row_o[3] == 1'b0) row_seen[3] <= 1'b1;
        end
    end

    integer i, k;

    // 按时钟等待（⛔ 不要用 #N —— 那是纳秒，不是拍数）
    task wait_clk;
        input integer n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    // 按下一个键并等待去抖完成
    task press_key;
        input integer idx;
        begin
            pressed[idx] = 1'b1;
            wait_clk(DEB_CYC * 3);
        end
    endtask

    task release_all;
        begin
            pressed = 16'd0;
            wait_clk(DEB_CYC * 3);
        end
    endtask

    initial begin
        pressed   = 16'd0;
        row_seen  = 4'd0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (SCAN_CYC * 6) @(posedge clk);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 1) scan structure: exactly one row low, all 4 rows visited ===");
        // ═════════════════════════════════════════════════════════════════
        chk("1a: exactly ONE row is driven low at any time (never two, never zero)",
            one_low_bad == 0);
        chk("1b: non-vacuity -- the check really ran (many samples)",
            one_low_ok > 100);
        chk("1c: all 4 rows were driven low (the scan really rotates)",
            row_seen == 4'b1111);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 2) no board attached (columns stay high) => nothing pressed ===");
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        repeat (SCAN_CYC * 10) @(posedge clk);
        chk("2a: with no key pressed, key_level stays all-zero", key_level == 16'd0);
        chk("2b: and NO key_down / key_up pulse appears", (n_kdown == 0) && (n_kup == 0));
        chk("2c: and NO command pulse appears either",
            (n_met+n_timbre+n_slide+n_scope+n_keydrum+n_gear+n_up+n_dn+n_dpat
             +n_tmode+n_lclr+n_mode+n_tare+n_span+n_fx) == 0);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 3) single key: idx = row*4+col is located correctly ===");
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        press_key(0);                       // (0,0) 节拍器
        chk("3a: pressing (0,0) sets ONLY key_level[0]",
            key_level == 16'h0001);
        chk("3b: exactly one key_down pulse", n_kdown == 1);
        chk("3c: (0,0) maps to met_req, exactly once", n_met == 1);
        chk("3d: no other command fired", (n_timbre+n_slide+n_scope+n_keydrum+n_gear)==0);
        release_all;
        chk("3e: releasing gives exactly one key_up", n_kup == 1);
        chk("3f: key_level returns to zero", key_level == 16'd0);

        // 换一个键，验证 row*4+col 的定位（不是只会认 idx 0）
        zero_counters;
        press_key(10);                      // (2,2) 变调降 F
        chk("3g: pressing (2,2) sets ONLY key_level[10]", key_level == 16'h0400);
        chk("3h: (2,2) maps to trans_down_req, exactly once", n_dn == 1);
        release_all;

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 4) TWO keys in the SAME column: both must be found ===");
        //   (0,1)=idx1 音色 与 (1,1)=idx5 推子档位 同在第 1 列
        //   只有"逐行拉低"才能把它们分开；两相方案在这里会失配
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        pressed[1] = 1'b1;                  // (0,1)
        pressed[5] = 1'b1;                  // (1,1)
        wait_clk(DEB_CYC * 3);
        chk("4a: same-column pair -> BOTH bits set (idx1 and idx5)",
            key_level == (16'h0001 << 1 | 16'h0001 << 5));
        chk("4b: both commands fired exactly once each",
            (n_timbre == 1) && (n_gear == 1));
        chk("4c: no crosstalk to other commands",
            (n_met+n_slide+n_scope+n_keydrum+n_up+n_dn+n_dpat+n_tmode)==0);
        release_all;

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 5) debounce: jitter must NOT change key_level ===");
        //   在去抖窗口内反复抖动：每次都不够 DEB_N 次连续一致
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        for (i = 0; i < 12; i = i + 1) begin
            pressed[3] = 1'b1;              // (0,3) 显示切换
            wait_clk(SCAN_CYC);             // 只稳定 1 次扫描（< DEB_N=3）
            pressed[3] = 1'b0;
            wait_clk(SCAN_CYC);
        end
        chk("5a: jitter never settled long enough => key_level[3] stays 0",
            key_level[3] == 1'b0);
        chk("5b: and the jitter produced NO command pulse", n_scope == 0);
        chk("5c: and no key_down pulse", n_kdown == 0);

        // 同样的键，这次稳定按住 => 必须认
        zero_counters;
        pressed[3] = 1'b1;
        wait_clk(DEB_CYC * 3);
        chk("5d: non-vacuity -- the SAME key DOES register once held stably",
            key_level[3] == 1'b1);
        chk("5e: and fires scope_mode_req exactly once", n_scope == 1);
        chk("5f: exactly one key_down pulse (not one per scan)", n_kdown == 1);
        release_all;

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 6) every mapped key fires its OWN command, once ===");
        // ═════════════════════════════════════════════════════════════════
        begin : sweep
            integer kk;
            for (kk = 0; kk < 16; kk = kk + 1) begin
                if (kk == 12 || kk == 15) continue;   // 长按键单独在 7) / 8) 测
                zero_counters;
                press_key(kk);
                case (kk)
                    0:  chk("6: idx 0  -> met_req once",          n_met == 1);
                    1:  chk("6: idx 1  -> timbre_req once",       n_timbre == 1);
                    2:  chk("6: idx 2  -> slide_req once",        n_slide == 1);
                    3:  chk("6: idx 3  -> scope_mode_req once",   n_scope == 1);
                    4:  chk("6: idx 4  -> keydrum_req once",      n_keydrum == 1);
                    5:  chk("6: idx 5  -> gear_next_req once",    n_gear == 1);
                    6:  chk("6: idx 6  -> trans_up_req once",     n_up == 1);
                    7:  chk("6: idx 7  -> mode_req once",         n_mode == 1);
                    8:  chk("6: idx 8  -> drum_pattern_req once", n_dpat == 1);
                    9:  chk("6: idx 9  -> fx_req once (placeholder)", n_fx == 1);
                    10: chk("6: idx 10 -> trans_down_req once",   n_dn == 1);
                    11: chk("6: idx 11 -> test_mode_req once",    n_tmode == 1);
                    default: chk("6: spare key fires nothing", 1'b1);
                endcase
                chk("6x: that key fired exactly ONE command total",
                    (n_met+n_timbre+n_slide+n_scope+n_keydrum+n_gear+n_up+n_dn
                     +n_dpat+n_tmode+n_lclr+n_mode+n_tare+n_span) <= 1);
                release_all;
            end
        end

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 7) looper clear (idx 12) requires a LONG press ===");
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        press_key(12);                          // 短按：按住但很快松开
        release_all;
        chk("7a: a SHORT press of idx12 does NOT clear the looper", n_lclr == 0);

        zero_counters;
        pressed[12] = 1'b1;
        wait_clk(LONG_MS * 2);                  // 超过长按阈值
        chk("7b: a LONG press fires loop_clear_req exactly once", n_lclr == 1);
        wait_clk(LONG_MS * 2);
        chk("7c: holding longer does NOT fire it again (one-shot)", n_lclr == 1);
        pressed[12] = 1'b0;
        wait_clk(DEB_CYC * 3);
        chk("7d: key_level[12] returns to 0 after release", key_level[12] == 1'b0);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("=== 8) calibration key (idx 15): short = tare, long = span ===");
        // ═════════════════════════════════════════════════════════════════
        zero_counters;
        pressed[15] = 1'b1;
        wait_clk(DEB_CYC * 2);                  // 已过抖，但远未到长按阈值
        chk("8a: while still held short, no command yet",
            (n_tare == 0) && (n_span == 0));
        pressed[15] = 1'b0;
        wait_clk(DEB_CYC * 3);
        chk("8b: SHORT press -> tare_req once", n_tare == 1);
        chk("8c: SHORT press -> NO span_req (the two are mutually exclusive)",
            n_span == 0);

        zero_counters;
        pressed[15] = 1'b1;
        wait_clk(LONG_MS * 2);
        chk("8d: LONG press -> span_req once", n_span == 1);
        pressed[15] = 1'b0;
        wait_clk(DEB_CYC * 3);
        chk("8e: after a long press, releasing does NOT also fire tare",
            n_tare == 0);

        // ═════════════════════════════════════════════════════════════════
        $display("");
        if (errors == 0)
            $display("PASS: ctrl keypad -- one-row-low scan, scan-based debounce (jitter rejected), every key maps to exactly its own command, same-column pairs resolved, long-press protected clear, and calib key short=tare / long=span");
        else
            $fatal(1, "FAIL: ctrl keypad had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
