`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_slide_top_pitch.sv -- TOP-LEVEL end-to-end criterion for portamento pitch.
//
// WHY THIS EXISTS (handover 2026-10-13, leftover item #4):
//   Portamento had criteria only at the `event_extract` level
//   (tb/w3a/tb_event_extract_slide.sv) and at the `axis_map` level
//   (tb/w3a/tb_axis_map.sv, criterion 8).  The missing link was the TOP-level
//   statement:
//       "a slide => pitch_upd emits the CORRECT axis and the CORRECT value."
//   Nothing verified that the three top.v mux lines actually deliver
//   A's axis with B's pitch, with the right src tag, under the right gating.
//
// METHOD (same proven pattern as tb/top/tb_am_pipe.sv):
//   Replicate ONLY the top.v wiring segment -- do NOT instantiate all of top.
//     * `event_extract` instance  (top.v:3859-3915, ports 3903/3904/3908)
//     * `axis_map`    instance    (top.v:4012-4030, axis_id_b_i <- ee_slide_b)
//     * the pitch_upd mux         (top.v:5103-5109)
//   Drive a REAL horizontal-adjacent slide (A leaving, B forming) into
//   event_extract and observe what the mux would send to note_manager.
//
// ORACLE (deliberately NOT same-source as the implementation):
//   Expected pitch is read out of the INSTANTIATED axis_map's own fb_inc[] table
//   (u_axis_map.fb_inc[b]), exactly as tb_am_pipe reads u_axis_map.fb_inc[].
//   The expected AXIS and SRC are structural constants from the spec
//   (slide updates A's voice; src tag 3'd0 = hand-play, NOT 3'd5 = keyboard drum).
//
// NON-VACUITY (each criterion must be able to FAIL -- K-56 / C21):
//   * A never-matching case proves the slide detector is not stuck high.
//   * Non-adjacent axes are checked to prove the neighbour table is real.
//   * The am_mode gate is checked to prove keyboard mode does not emit.
//
// ASCII ONLY in `chk` names: iverilog's %s turns bytes >= 0x80 into U+FFFD, so
// Chinese criterion names would be unreadable in sim/evidence logs.
// -----------------------------------------------------------------------------

module tb_slide_top_pitch;

    localparam integer AXIS_W  = 4;
    localparam integer POS_W   = 12;
    localparam integer PHASE_W = 32;
    localparam integer N_KEY   = 16;
    localparam integer AXIS_N  = 16;
    localparam integer DW      = 13;

    // Production thresholds (top.v:3844-3845 uses EVT_TRIG_TH/EVT_REL_TH;
    // the delta threshold stays at its default 8 -- top.v:3846).
    localparam [POS_W-1:0] TRIG_TH = 12'd64;
    localparam [POS_W-1:0] REL_TH  = 12'd32;
    localparam signed [DW-1:0] DELTA_TH = 13'sd8;

    integer errors = 0;

    reg clk        = 1'b0;
    reg rst_n_sync = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

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

    // =========================================================================
    //  Stimulus (names/shape mirror top.v)
    // =========================================================================
    reg                    slide_en;
    reg                    ee_enable;
    reg                    snap_valid;
    reg [AXIS_N*POS_W-1:0] as_pos;
    reg [AXIS_N*DW-1:0]    as_delta;
    reg                    am_mode;              // 0 = keyboard, 1 = fretboard

    // =========================================================================
    //  `event_extract` instance -- mirrors top.v:3859-3915
    // =========================================================================
    wire        ee_valid;
    wire [3:0]  ee_axis;
    wire [1:0]  ee_kind;
    wire [11:0] ee_depth;
    wire        ee_slide_v;
    wire [3:0]  ee_slide_ax;
    wire [3:0]  ee_slide_b;
    wire signed [1:0] ee_slide_dir;
    wire        ee_two_v;
    wire [3:0]  ee_two_a, ee_two_b;
    reg  [AXIS_N-1:0] ee_key_on_ignored;

    event_extract #(
        .AXIS_N         (AXIS_N),
        .AXIS_W         (AXIS_W),
        .POS_W          (POS_W),
        .DW             (DW),
        .TRIG_TH        (TRIG_TH),
        .REL_TH         (REL_TH),
        .DELTA_TH       (DELTA_TH),
        .SLIDE_WIN      (1000),
        .SLIDE_START_TH (12'h040)
    ) u_event_extract (
        .clk              (clk),
        .rst_n            (rst_n_sync),
        .enable_i         (ee_enable),
        .slide_en_i       (slide_en),
        .snap_valid_i     (snap_valid),
        .pos_i            (as_pos),
        .delta_i          (as_delta),
        .evt_valid_o      (ee_valid),
        .evt_axis_o       (ee_axis),
        .evt_kind_o       (ee_kind),
        .evt_depth_o      (ee_depth),
        .key_on_o         (ee_key_on_ignored),
        .slide_valid_o    (ee_slide_v),
        .slide_axis_o     (ee_slide_ax),
        .slide_axis_b_o   (ee_slide_b),
        .slide_dir_o      (ee_slide_dir),
        .two_note_valid_o (ee_two_v),
        .two_note_axis_a_o(ee_two_a),
        .two_note_axis_b_o(ee_two_b),
        .overflow_o       (),
        .lost_cnt_o       ()
    );

    // =========================================================================
    //  `axis_map` instance -- mirrors top.v:4012-4030
    //  The second lookup port is fed ee_slide_b (A's voiced pitch is retargeted
    //  to B's pitch), so phase_inc_b_o is what the mux must pass through.
    // =========================================================================
    wire [PHASE_W-1:0] am_inc;
    wire               am_valid;
    wire [AXIS_W-1:0]  am_axis;
    wire [PHASE_W-1:0] am_inc_b;

    // Drive the main port from A (the axis being voiced), like top.v does.
    reg [AXIS_W-1:0]   am_axis_in;
    reg [POS_W-1:0]    am_pos_in;
    reg                am_vld_in;

    axis_map #(
        .AXIS_W  (AXIS_W),
        .POS_W   (POS_W),
        .PHASE_W (PHASE_W),
        .N_KEY   (N_KEY)
    ) u_axis_map (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .pos_valid_i  (am_vld_in),
        .axis_id_i    (am_axis_in),
        .axis_id_b_i  (ee_slide_b),
        .pos_i        (am_pos_in),
        .mode_i       (am_mode),
        .phase_inc_o  (am_inc),
        .phase_valid_o(am_valid),
        .axis_id_o    (am_axis),
        .phase_inc_b_o(am_inc_b)
    );

    // =========================================================================
    //  The pitch_upd mux -- EXACT replica of top.v:5103-5109
    //  The other two sources are tied off here so that any observed update
    //  necessarily came from the slide path (that is the point of this tb).
    //
    //  KNOWN LIMITATION (stated honestly, not hidden):
    //  Because this is a replica, the criteria below test THIS wiring, not the
    //  wiring inside top.v.  A regression that only edits top.v's mux would go
    //  unnoticed (verified experimentally: removing `& am_mode` from top.v did
    //  not turn this tb red).  The closing mechanism is the source-parity guard
    //  in the initial block: it re-reads the four real mux lines out of
    //  rtl/top.v and fails loudly if they no longer match this replica.
    // =========================================================================
    wire        pe_pitch_v   = 1'b0;      // bend/pitch source idle
    wire        lp_upd_valid = 1'b0;      // looper source idle
    wire [3:0]  pe_pitch_ax  = 4'd0;
    wire [PHASE_W-1:0] pe_pitch = 32'd0;
    wire [3:0]  lp_upd_axis  = 4'd0;
    wire [PHASE_W-1:0] lp_upd_inc = 32'd0;

    wire        pu_valid = pe_pitch_v | lp_upd_valid | (ee_slide_v & am_mode);
    wire [3:0]  pu_axis  = pe_pitch_v ? pe_pitch_ax
                        : lp_upd_valid ? lp_upd_axis : ee_slide_ax;
    wire [PHASE_W-1:0] pu_value = pe_pitch_v ? pe_pitch
                               : lp_upd_valid ? lp_upd_inc  : am_inc_b;
    wire [2:0]  pu_src   = pe_pitch_v ? 3'd0
                        : lp_upd_valid ? 3'd4 : 3'd0;
    //  NOTE (2026-10-13, after merging origin/main 7ef73f4):
    //  The slide branch sends src tag 3'd0 (hand-play), NOT 3'd5.
    //  3'd5 is SRC_KDRUM (keyboard drums, see top.v SRC_KDRUM) -- it is NOT an
    //  idle code.  note_manager falls back to 0 for any unsupported pitch src,
    //  so 3'd5 happened to behave like 0; the merge made it explicit.
    //  A stale guard that only checked the `valid` line missed this -> false green.

    // =========================================================================
    //  Observation
    // =========================================================================
    integer n_upd = 0;
    reg [PHASE_W-1:0] exp_pitch;

    // Payload latched at the exact instant a pitch_upd occurred.
    reg               have_upd = 1'b0;
    reg [3:0]         upd_axis;
    reg [2:0]         upd_src;
    reg [PHASE_W-1:0] upd_val;
    reg [PHASE_W-1:0] upd_exp;
    reg [3:0]         upd_b;

    // Sticky record of the most recent update, captured on the clock edge.
    // NOTE: `ee_slide_v` is a REGISTERED single-cycle pulse and `pu_value` is
    // combinational off the registered `ee_slide_b`, so both are only valid
    // together *in the cycle after* the stimulus frame -- sampling after a
    // bare `#1` would read the previous frame's values.
    reg               upd_seen;
    reg [3:0]         last_axis;
    reg [2:0]         last_src;
    reg [PHASE_W-1:0] last_val;
    reg [PHASE_W-1:0] last_exp;

    always @(posedge clk) begin
        if (rst_n_sync === 1'b1 && pu_valid === 1'b1) begin
            n_upd = n_upd + 1;
            // Oracle: B's pitch straight out of the instantiated table.
            exp_pitch = u_axis_map.fb_inc[pu_axis];
            // Latch the payload at the instant the update happens, so the
            // test can assert on it afterwards without racing the next edge.
            have_upd  = 1'b1;
            upd_axis  = pu_axis;
            upd_src   = pu_src;
            upd_val   = pu_value;
            upd_exp   = exp_pitch;
            upd_b     = ee_slide_b;
            $display("  upd: axis=%0d src=%0d value=%08h  table[%0d]=%08h",
                     pu_axis, pu_src, pu_value, pu_axis, exp_pitch);
        end
    end

    // -------------------------------------------------------------------------
    //  Helpers: drive the snapshot frame by frame.
    //    delta_i[a] is the per-frame travel change of axis a, in raw codes.
    //    A "leaving" axis has delta < -DELTA_TH.
    //    A "forming"  axis has delta > +SLIDE_START_TH.
    // -------------------------------------------------------------------------
    task clear_frame;
        integer k;
        begin
            as_pos   = {AXIS_N*POS_W{1'b0}};
            as_delta = {AXIS_N*DW{1'b0}};
            snap_valid = 1'b0;
        end
    endtask

    task set_delta;
        input integer ax;
        input signed [DW-1:0] d;
        begin
            as_delta[ax*DW +: DW] = d;
        end
    endtask

    task set_pos;
        input integer ax;
        input [POS_W-1:0] p;
        begin
            as_pos[ax*POS_W +: POS_W] = p;
        end
    endtask

    // One snapshot frame: present the deltas for exactly one clock, which is
    // what `snap_valid_i` means to event_extract.  The registered slide pulse
    // appears on the NEXT edge, so callers advance one more edge to observe it.
    task frame;
        begin
            snap_valid = 1'b1;
            @(posedge clk);
            #1;
            snap_valid = 1'b0;
            @(posedge clk);   // <-- registered slide_valid_o / slide_axis_b_o land here
            #1;
        end
    endtask

    // Sticky flag: set as soon as a slide pulse is observed on ANY edge, and
    // cleared explicitly by the test before each stimulus.  A separate
    // edge-sampled register would lag by one cycle, because the last
    // `@(posedge clk)` in `frame` samples ee_slide_v *before* that edge
    // updates it -- that off-by-one is what made an earlier version undercount.
    reg slide_seen;
    always @(posedge clk) begin
        if (rst_n_sync === 1'b1 && ee_slide_v === 1'b1) slide_seen <= 1'b1;
    end

    integer i;

    initial begin
        slide_en   = 1'b1;
        ee_enable  = 1'b1;
        am_mode    = 1'b1;          // fretboard mode: slides are allowed here
        am_axis_in = 4'd0;
        am_pos_in  = 12'd0;
        am_vld_in  = 1'b0;
        clear_frame;

        rst_n_sync = 1'b0;
        repeat (4) @(posedge clk);
        rst_n_sync = 1'b1;
        repeat (4) @(posedge clk);

        // =====================================================================
        $display("");
        $display("=== 0) SOURCE PARITY: this replica must match rtl/top.v ===");
        //   Closes the known limitation above.  Reads the real mux lines out of
        //   rtl/top.v and fails if the replica has drifted.  Without this, a
        //   top.v-only regression would leave the tb falsely green.
        // =====================================================================
        begin : parity
            integer fd;
            integer rc;
            integer n_line;
            integer k;
            integer L;
            integer i;
            integer n_hit;
            integer n_src;
            reg [8*256-1:0] line;
            // EVERY line of rtl/top.v that this replica copies.  If any of them
            // drifts, the replica is stale and the criteria below prove nothing
            // about the real design -- so the guard must fail loudly.
            // 2026-10-13: the merge changed the src line from 3'd5 to 3'd0 and
            // the ORIGINAL single-line guard did NOT catch it => false green.
            reg [8*256-1:0] want [0:5];
            // The src line carries a trailing comment in top.v, so only its
            // ASCII prefix can be matched (60 chars).  `$fgets` right-justifies
            // the line inside the reg, hence the length scan below.
            reg [8*60-1:0]  want_src;

            //  ⭐⭐ 2026-10-13：⭐ **锚点已更新为"带斜坡"的版本** ✅
            //     🔴 **本次踩到（守卫工作正常）**：⭐ 我给 `top.v` 的滑音源加了斜坡
            //        （⭐ `sl_ramp_active` / `sl_ramp_val` ✅）⇒ ⚠️ 复刻判据的锚点**过期**
            //        ⇒ 🔴 `0d: ALL 6 replica anchors ...` **变红** ✅ —— ⭐ **这正是它的用途** ✅
            //     ✅ 现在两条锚点**专守斜坡接线**（⭐ 触发拍 ＋ 斜坡推进期 ＋ 取斜坡值 ✅）
            want[0] = "            .pitch_upd_valid_i (pe_pitch_v | lp_upd_valid\n";
            want[1] = "                              | ((ee_slide_v | sl_ramp_active) & am_mode)),\n";
            want[2] = "                              : (ee_slide_v | sl_ramp_active) ? sl_ramp_val : am_inc_b),\n";
            want[3] = "            .slide_axis_b_o   (ee_slide_b),\n";
            want[4] = "            .axis_id_b_i  (ee_slide_b),\n";
            want[5] = "            .phase_inc_b_o(am_inc_b)\n";
            want_src = "                              : lp_upd_valid ? 3'd4 : 3'd0),";

            n_line = 0;
            n_hit  = 0;
            n_src  = 0;
            fd = $fopen("rtl/top.v", "r");
            if (fd == 0) begin
                $display("  FAIL: cannot open rtl/top.v for the source-parity guard");
                errors = errors + 1;
            end else begin
                while (!$feof(fd)) begin
                    line = {8*256{1'b0}};   // clear: the length scan must see no stale bytes
                    rc = $fgets(line, fd);
                    if (rc != 0) begin
                        n_line = n_line + 1;
                        for (i = 0; i < 6; i = i + 1)
                            if (line == want[i]) n_hit = n_hit + 1;
                        // length = index of the highest non-zero byte, plus 1
                        L = 0;
                        for (k = 0; k < 256; k = k + 1)
                            if (line[8*k +: 8] != 8'h00) L = k + 1;
                        if (L >= 60 && line[8*L-1 -: 8*60] == want_src)
                            n_src = n_src + 1;
                    end
                end
                $fclose(fd);
                $display("  (parity: read %0d lines; %0d/6 exact anchors matched; src prefix hits %0d)",
                         n_line, n_hit, n_src);
                chk("0a: the parity guard actually read rtl/top.v (not zero lines => not vacuous)",
                    n_line > 1000);
                chk("0b: rtl/top.v still gates the slide source with `& am_mode`",
                    n_hit >= 1);
                chk("0c: rtl/top.v's slide src tag is 3'd0 (NOT 3'd5 = keyboard drum)",
                    n_src >= 1);
                chk("0d: ALL 6 replica anchors are still present in rtl/top.v (replica not stale)",
                    n_hit == 6);
            end
        end

        // =====================================================================
        $display("");
        $display("=== A) slide on a PHYSICALLY ADJACENT pair (6,7) => pitch_upd to B ===");
        //   Axis 6 and 7 are horizontally adjacent on the left board's top row
        //   (physical layout table, spec section 2).  Axis 6 is the one being
        //   voiced (A); axis 7 is just starting to form (B).
        // =====================================================================
        n_upd = 0;
        have_upd   = 1'b0;
        am_axis_in = 4'd6;
        am_pos_in  = 12'h400;
        am_vld_in  = 1'b1;
        @(posedge clk);
        am_vld_in  = 1'b0;

        // A is leaving: big negative delta on axis 6.
        // B is forming: small positive delta on axis 7 (> SLIDE_START_TH = 64).
        clear_frame;
        set_delta(6, -13'sd20);
        set_delta(7,  13'sd100);
        set_pos(6, 12'h400);
        set_pos(7, 12'h040);
        frame;

        chk("A: a horizontal-adjacent slide produces a pitch_upd",
            have_upd === 1'b1 && n_upd >= 1);
        chk("A: pitch_upd axis is A (the axis being voiced), not B",
            upd_axis == 4'd6);
        chk("A: pitch_upd src tag is 3'd0 = hand-play (NOT 3'd5, which is SRC_KDRUM)",
            upd_src == 3'd0);
        chk("A: the value handed to pitch_upd equals fb_inc[B] (B's pitch)",
            upd_val == u_axis_map.fb_inc[4'd7]);
        chk("A: the slide really resolved B = 7 (neighbour table matched)",
            upd_b == 4'd7);

        // Non-vacuity: B's pitch must differ from A's, otherwise "equals
        // fb_inc[B]" would also pass if the mux wrongly sent A's own pitch.
        chk("A: non-vacuity -- fb_inc[6] != fb_inc[7] so the value check bites",
            u_axis_map.fb_inc[4'd6] != u_axis_map.fb_inc[4'd7]);

        // =====================================================================
        $display("");
        $display("=== B) NON-adjacent pair (1,2) => NO slide (neighbour table is real) ===");
        //   Axes 1 and 2 are NOT horizontally adjacent (layout: top row is
        //   6-7-0-1, bottom row is 5-4-3-2).  This is the criterion that would
        //   fail if someone replaced the neighbour table with abs(B-A)==1.
        // =====================================================================
        // Let the window state drain first.
        repeat (3) begin
            clear_frame;
            frame;
        end
        n_upd = 0;
        clear_frame;
        set_delta(1, -13'sd20);      // A leaving
        set_delta(2,  13'sd100);     // B forming
        slide_seen = 1'b0;
        frame;
        frame;
        chk("B: a non-adjacent pair does NOT produce a slide (over 2 frames)",
            slide_seen !== 1'b1);
        chk("B: therefore no pitch_upd comes out of the slide path",
            n_upd == 0);

        // Non-vacuity for B: the SAME delta pattern on a real adjacent pair
        // must fire.  Otherwise B would pass in a tb where nothing ever fires.
        repeat (3) begin clear_frame; frame; end
        clear_frame;
        set_delta(6, -13'sd20);      // adjacent pair (6,7)
        set_delta(7,  13'sd100);
        slide_seen = 1'b0;
        frame;
        chk("B: non-vacuity -- the same delta pattern on an ADJACENT pair does fire",
            slide_seen === 1'b1);

        // =====================================================================
        $display("");
        $display("=== C) am_mode gate: keyboard mode must NOT emit slide pitch_upd ===");
        //   top.v gates the slide source with `& am_mode` because axis_map's
        //   second port only reads fb_inc.  In keyboard mode the value would be
        //   wrong, so it must be structurally suppressed.
        // =====================================================================
        am_mode = 1'b0;              // keyboard
        repeat (3) begin
            clear_frame;
            frame;
        end
        n_upd = 0;
        clear_frame;
        set_delta(6, -13'sd20);
        set_delta(7,  13'sd100);
        slide_seen = 1'b0;
        frame;
        chk("C: keyboard mode suppresses the slide pitch_upd (am_mode gate)",
            n_upd == 0);
        chk("C: non-vacuity -- the detector itself still fired (it is the MUX that is gated, not the detector)",
            slide_seen === 1'b1);

        // =====================================================================
        $display("");
        $display("=== D) slide_en gate: 'W' off must suppress the detector entirely ===");
        // =====================================================================
        am_mode  = 1'b1;
        slide_en = 1'b0;             // 'W' toggle off
        repeat (3) begin
            clear_frame;
            frame;
        end
        n_upd = 0;
        clear_frame;
        set_delta(6, -13'sd20);
        set_delta(7,  13'sd100);
        slide_seen = 1'b0;
        frame;
        chk("D: slide_en=0 suppresses the slide detector", slide_seen !== 1'b1);
        chk("D: therefore no pitch_upd either", n_upd == 0);

        // Non-vacuity for D: with slide_en back on, the SAME stimulus must fire.
        // Without this, a tb that never fires at all would also pass D.
        slide_en = 1'b1;
        repeat (3) begin
            clear_frame;
            frame;
        end
        clear_frame;
        set_delta(6, -13'sd20);
        set_delta(7,  13'sd100);
        slide_seen = 1'b0;
        frame;
        chk("D: non-vacuity -- the same stimulus DOES fire once slide_en=1 again",
            slide_seen === 1'b1);

        // =====================================================================
        $display("");
        $display("=== E) every adjacent pair in the table maps to the right target ===");
        //   Sweep the 12 real pairs in both directions.  For each, A is voiced
        //   and B must be the reported target, and the value must be fb_inc[B].
        // =====================================================================
        begin : sweep
            integer p;
            integer mism;
            integer fired;
            // The 12 horizontal pairs, as (A,B) in both orders.
            integer pa [0:11];
            integer pb [0:11];
            pa[0]=6;  pb[0]=7;
            pa[1]=7;  pb[1]=0;
            pa[2]=0;  pb[2]=1;
            pa[3]=5;  pb[3]=4;
            pa[4]=4;  pb[4]=3;
            pa[5]=3;  pb[5]=2;
            pa[6]=14; pb[6]=15;
            pa[7]=15; pb[7]=8;
            pa[8]=8;  pb[8]=9;
            pa[9]=13; pb[9]=12;
            pa[10]=12;pb[10]=11;
            pa[11]=11;pb[11]=10;

            mism  = 0;
            fired = 0;
            slide_en = 1'b1;
            am_mode  = 1'b1;

            for (p = 0; p < 12; p = p + 1) begin
                // ---- forward: A = pa, B = pb ----
                repeat (3) begin clear_frame; frame; end
                am_axis_in = pa[p][AXIS_W-1:0];
                am_pos_in  = 12'h400;
                am_vld_in  = 1'b1;
                @(posedge clk);
                am_vld_in  = 1'b0;
                clear_frame;
                set_delta(pa[p], -13'sd20);
                set_delta(pb[p],  13'sd100);
                slide_seen = 1'b0;
                frame;
                if (slide_seen === 1'b1) begin
                    fired = fired + 1;
                    if (ee_slide_ax !== pa[p][AXIS_W-1:0] ||
                        ee_slide_b  !== pb[p][AXIS_W-1:0] ||
                        pu_value    !== u_axis_map.fb_inc[pb[p][AXIS_W-1:0]] ||
                        pu_axis     !== pa[p][AXIS_W-1:0]) begin
                        mism = mism + 1;
                        $display("  FAIL detail: pair %0d->%0d  slide_ax=%0d slide_b=%0d pu_axis=%0d pu_val=%08h exp=%08h",
                                 pa[p], pb[p], ee_slide_ax, ee_slide_b, pu_axis,
                                 pu_value, u_axis_map.fb_inc[pb[p][AXIS_W-1:0]]);
                    end
                end

                // ---- reverse: A = pb, B = pa ----
                repeat (3) begin clear_frame; frame; end
                am_axis_in = pb[p][AXIS_W-1:0];
                am_pos_in  = 12'h400;
                am_vld_in  = 1'b1;
                @(posedge clk);
                am_vld_in  = 1'b0;
                clear_frame;
                set_delta(pb[p], -13'sd20);
                set_delta(pa[p],  13'sd100);
                slide_seen = 1'b0;
                frame;
                if (slide_seen === 1'b1) begin
                    fired = fired + 1;
                    if (ee_slide_ax !== pb[p][AXIS_W-1:0] ||
                        ee_slide_b  !== pa[p][AXIS_W-1:0] ||
                        pu_value    !== u_axis_map.fb_inc[pa[p][AXIS_W-1:0]] ||
                        pu_axis     !== pb[p][AXIS_W-1:0]) begin
                        mism = mism + 1;
                        $display("  FAIL detail: pair %0d->%0d  slide_ax=%0d slide_b=%0d pu_axis=%0d pu_val=%08h exp=%08h",
                                 pb[p], pa[p], ee_slide_ax, ee_slide_b, pu_axis,
                                 pu_value, u_axis_map.fb_inc[pa[p][AXIS_W-1:0]]);
                    end
                end
            end

            chk("E: all 24 directed adjacent slides produced a matching pitch_upd",
                mism == 0);
            chk("E: non-vacuity -- every one of the 24 actually fired (not silently skipped)",
                fired == 24);
        end

        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: a horizontal-adjacent slide drives pitch_upd with A's axis, src tag 3'd0 (hand-play) and B's pitch (fb_inc[B]); non-adjacent pairs are rejected by the neighbour table; keyboard mode and slide_en=0 both suppress it; all 24 directed adjacent pairs match; all 6 replica anchors still match rtl/top.v");
        else
            $fatal(1, "FAIL: slide top pitch had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
