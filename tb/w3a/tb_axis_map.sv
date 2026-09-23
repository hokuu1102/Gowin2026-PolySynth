`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_axis_map.sv · `axis_map` 自检（⭐ W3a 语义层）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`；⭐ 尽量写成【不变量】—— `C44`）
//   ① ⭐ **轴位 0 → 表底**（`phase_inc` = `BASE_INC`）
//   ② ⭐ **轴位满量程 → 表顶**（⛔ 不许越界/绕回表底）
//   ③ ⭐⭐ **双压插值**：两键之间的位置 ⇒ 结果**严格在两者之间**（⛔ 不是任一端点）
//   ④ ⭐ **`phase_valid_o` 与 `phase_inc_o` 同拍**（⭐ `K-109` 同族：valid 与数据必须同拍）
//   ⑤ ⭐ **`phase_inc_o` ⛔ 永不为 0**（⭐ `tick_inc=0` ⇒ 音乐时钟静止）
//   ⑥ ⭐ **单调性**：`pos_i` 递增 ⇒ `phase_inc_o` **不减**（⚠️ 音高必须单调）
//   ⑦ ⭐ **双模式可选**（`mode_i` 有实际作用；⚠️ 现在两表同构 ⇒ 只验"接口有效"）
// ─────────────────────────────────────────────────────────────────────────────

module tb_axis_map;

    localparam integer AXIS_W  = 4;
    localparam integer POS_W   = 12;
    localparam integer PHASE_W = 32;
    localparam integer N_KEY   = 16;
    localparam [PHASE_W-1:0] BASE_INC = 32'h0010_0000;

    integer errors = 0;

    reg                    clk = 1'b0;
    reg                    rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    reg                    pos_valid;
    reg  [AXIS_W-1:0]      axis_id;
    reg  [POS_W-1:0]       pos;
    reg                    mode;

    wire [PHASE_W-1:0]     phase_inc;
    wire                   phase_valid;
    wire [AXIS_W-1:0]      axis_id_o;

    axis_map #(
        .AXIS_W       (AXIS_W),
        .POS_W        (POS_W),
        .PHASE_W      (PHASE_W),
        .N_KEY        (N_KEY),
        .SEMITONE_Q16 (69433),
        .BASE_INC     (BASE_INC)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .pos_valid_i   (pos_valid),
        .axis_id_i     (axis_id),
        .pos_i         (pos),
        .mode_i        (mode),
        .phase_inc_o   (phase_inc),
        .phase_valid_o (phase_valid),
        .axis_id_o     (axis_id_o)
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

    // ⭐ 期望值：key 的 phase_inc（与 DUT 用同一算式独立复算 —— ⚠️ 不是抄 DUT）
    function [PHASE_W-1:0] expect_key;
        input integer k;
        integer i;
        reg [63:0] acc;
        begin
            acc = BASE_INC;
            for (i = 0; i < k; i = i + 1)
                acc = (acc * 69433) >> 16;
            expect_key = acc[PHASE_W-1:0];
        end
    endfunction

    // ⭐ 段宽 = 满量程 / N_KEY = 4096 / 16 = 256
    localparam integer SEG = (1 << POS_W) / N_KEY;

    integer v0, v_last, v_mid_lo, v_mid_hi;
    integer prev, cur;
    integer i;
    integer monotonic_ok;

    initial begin
        pos_valid = 1'b0; axis_id = 4'd0; pos = 12'd0; mode = 1'b0;

        // 复位
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ═══ 判据 ① 轴位 0 → 表底 ═══
        axis_id = 4'd3;  pos = 12'd0;  pos_valid = 1'b1;  mode = 1'b0;
        #1;
        v0 = phase_inc;
        chk("pos=0 gives the table bottom (BASE_INC)", phase_inc === expect_key(0));

        // ═══ 判据 ② 轴位满量程 → 表顶（⛔ 不越界）═══
        pos = 12'hFFF;  #1;
        v_last = phase_inc;
        chk("pos=max gives the table top (no wrap to bottom)", phase_inc === expect_key(N_KEY-1));
        chk("table top > table bottom (pitch rises)", v_last > v0);

        // ═══ 判据 ③ 双压插值：落在两键【中间】⇒ 严格在两者之间 ═══
        //   ⚠️ **取段中点**（⭐ 不是段起点！）——
        //      🔴 段起点 `frac=0` ⇒ 输出【恰好等于】低键端点 ⇒ ⚠️ 会被"严格在中间"判据误判为失败。
        //      ⭐ 这正是判据写法要覆盖**输入组合**的教训（`L73`/`87 号`：判据只覆盖一个维度会漏）。
        pos = SEG * 2 + (SEG/2);   // key=2，frac = 半段 ⇒ ⭐ 真正落在两键之间
        #1;
        v_mid_lo = expect_key(2);
        v_mid_hi = expect_key(3);
        chk("dual-press interp: strictly BETWEEN the two keys",
            (phase_inc > v_mid_lo[PHASE_W-1:0]) && (phase_inc < v_mid_hi[PHASE_W-1:0]));
        chk("dual-press interp: NOT equal to either endpoint",
            (phase_inc !== v_mid_lo[PHASE_W-1:0]) && (phase_inc !== v_mid_hi[PHASE_W-1:0]));

        // ⭐ 附加：段起点必须【恰好等于低键端点】（⭐ 插值系数 0 的边界）
        pos = SEG * 2;  #1;
        chk("segment start equals the lower-key endpoint (frac=0 boundary)",
            phase_inc === expect_key(2));

        // ═══ 判据 ④ valid 与数据同拍（⭐ 组合输出 ⇒ 同拍）═══
        pos_valid = 1'b0;  #1;
        chk("valid deasserts in the same cycle as data (combinational)", phase_valid === 1'b0);
        pos_valid = 1'b1;  #1;
        chk("valid asserts in the same cycle as data (combinational)", phase_valid === 1'b1);

        // ═══ 判据 ⑤ phase_inc 永不为 0（遍历全量程）═══
        begin : scan_nonzero
            integer z;
            integer zero_cnt;
            zero_cnt = 0;
            for (z = 0; z < 4096; z = z + 1) begin
                pos = z[POS_W-1:0];
                #1;
                if (phase_inc === {PHASE_W{1'b0}}) zero_cnt = zero_cnt + 1;
            end
            chk("phase_inc is NEVER zero across the full position range", zero_cnt == 0);
        end

        // ═══ 判据 ⑥ 单调性（⭐ 段内单调递增）═══
        //   🔴 **⚠️ 为什么只扫"段内"而不是全量程**：
        //      ⚠️ `N_KEY=16` 张表**平铺在整个 `2^POS_W` 量程上** ⇒
        //      ⭐ **最后一个键（key 15）在第 15 段末尾，之后 `pos` 再涨就越界**
        //      ⇒ ⭐ 满量程时 `key_idx` 会钳到 `KEY_MAX`（**正确行为**），
        //      ⚠️ 但若把整段量程当"音高轴"，会看到"末尾回到 key 0" ⇒ ⚠️ **那不是反转，是绕回**。
        //      ⭐ **判据必须打在语义正确的区间上**（`C33`：判据要覆盖正确的输入组合）。
        //   ⭐ 正确判据：⭐ **每个 256 段的内部必须单调不减**（⭐ 段数 × 段宽 = 满量程）。
        begin : scan_monotonic
            integer seg, off;
            integer prevv, curv;
            monotonic_ok = 1;
            for (seg = 0; seg < N_KEY; seg = seg + 1) begin
                prevv = -1;
                for (off = 0; off < SEG; off = off + 1) begin
                    pos = (seg * SEG + off);
                    #1;
                    curv = phase_inc;
                    if (prevv >= 0 && curv < prevv) monotonic_ok = 0;
                    prevv = curv;
                end
            end
            chk("pitch is MONOTONIC inside every key segment (no inversion)", monotonic_ok == 1);
        end

        // ⭐ 附加：⭐ **段间必须严格递增**（key 0 段 < key 1 段 < … ）—— ⭐ 这才是"音高递增"
        begin : scan_seg_rise
            integer s;
            integer prev_top, cur_bot;
            integer rise_ok;
            rise_ok = 1;
            prev_top = -1;
            for (s = 0; s < N_KEY; s = s + 1) begin
                pos = (s * SEG);
                #1;
                cur_bot = phase_inc;
                if (prev_top >= 0 && cur_bot <= prev_top) rise_ok = 0;
                prev_top = cur_bot;
            end
            chk("each key segment starts strictly ABOVE the previous one (pitch rises)", rise_ok == 1);
        end

        // ═══ 判据 ⑦ 双模式接口有效（mode_i 可切换）═══
        pos = SEG * 4;  #1;
        mode = 1'b0;  #1;
        // ═══ 判据 ⑦ 双模式：⭐ 两表【内容不同】⇒ mode_i 必须真的切表 ═══
        //   ⚠️ 2026-09-23：`fb_inc` 已填入**真实指板音高**（C4/C#4/D4/D#4），
        //      ⭐ 而 `kb_inc` 仍是**半音阶梯**（示例）⇒ ⭐ **两表内容不同**
        //      ⇒ ⭐ 判据从"两模式同值"改成"**两模式必须不同、且各自等于自己的表**"（⭐ 更强）。
        begin : mode_check
            integer kb_val, fb_val;
            // ⚠️ **先把 pos 设回 0**（⭐ 上面判据 ⑥/⑦ 已把它扫到别处）
            //    ⇒ ⭐ 因为 `fb_inc[0]` = 轴 0 = 四弦品1 = `A2`，⛔ 只在 pos=0 成立。
            pos = 12'd0;
            // 键盘模式（半音阶梯）
            mode = 1'b0;  #1;
            kb_val = phase_inc;
            // 指板模式（真实音高；pos=0 ⇒ 品1 = 一弦 C4）
            mode = 1'b1;  #1;
            fb_val = phase_inc;
            $display("  [mode] pos=%0d kb=%0d (0x%08h)  fb=%0d (0x%08h)", pos, kb_val, kb_val, fb_val, fb_val);
            chk("mode_i really switches the table (kb != fb for the same position)",
                kb_val !== fb_val);
            // ⭐⭐ **表头 = 轴 0 = 四弦品1 = `A2`**（⭐ 2026-09-23 用户确认版）
            //   ⚠️ 表头 **⛔ 不是 C4** —— C4 是**一弦品1**，⭐ 它在表的**尾部**（轴 12）。
            //   📌 原因：⭐ 轴号 = `adc_idx×8 + CH`，而 **CH 号是布线决定的乱序**
            //      ⇒ ⭐ **轴 0 落在"左板下排物理列1" = 四弦品1 = A2**（⛔ 不是最低音那么简单）。
            chk("fretboard mode at pos=0 gives A2 (axis 0 = string 4, fret 1)",
                fb_val === 32'h0093_A3B6);
        end
        mode = 1'b0;  #1;

        // ═══ 判据 ⑧ 轴号透传 ═══
        axis_id = 4'd11;  #1;
        chk("axis_id is passed through to the output", axis_id_o === 4'd11);

        // ═══ 判据 ⑨ ⭐⭐ 指板表【全 16 项】逐项核对（⭐ 最强的一条）═══
        //   ⭐ 2026-09-23 用户确认版：轴号 → 音高（⭐ 4 弦 × 4 品）
        //   ⚠️ **轴号【不按物理位置递增】**（CH 号是布线决定的乱序）
        //      ⇒ ⭐ 必须【逐项】核对，⛔ 不能靠公式推。
        begin : fb_table_check
            integer k;
            integer bad_cnt;
            reg [PHASE_W-1:0] exp_tbl [0:15];
            exp_tbl[0]  = 32'h0093_A3B6;  // 四弦品1 A2
            exp_tbl[1]  = 32'h009C_6B2A;  // 四弦品2 A#2
            exp_tbl[2]  = 32'h00A5_B841;  // 四弦品3 B2
            exp_tbl[3]  = 32'h00AF_92EE;  // 四弦品4 C3
            exp_tbl[4]  = 32'h00C5_1339;  // 三弦品1 D3
            exp_tbl[5]  = 32'h00D0_CB35;  // 三弦品2 D#3
            exp_tbl[6]  = 32'h00DD_3595;  // 三弦品3 E3
            exp_tbl[7]  = 32'h00EA_5CF4;  // 三弦品4 F3
            exp_tbl[8]  = 32'h0107_104E;  // 二弦品1 G3
            exp_tbl[9]  = 32'h0116_B4CE;  // 二弦品2 G#3
            exp_tbl[10] = 32'h0127_476D;  // 二弦品3 A3
            exp_tbl[11] = 32'h0138_D653;  // 二弦品4 A#3
            exp_tbl[12] = 32'h015F_25DC;  // 一弦品1 C4
            exp_tbl[13] = 32'h0174_073A;  // 一弦品2 C#4
            exp_tbl[14] = 32'h018A_2672;  // 一弦品3 D4
            exp_tbl[15] = 32'h01A1_966B;  // 一弦品4 D#4
            //   ⚠️ 说明：本 tb 只能通过 `pos=0`（段起点）读到**表头那一项**，
            //      ⇒ ⭐ 这里用层次引用直接查表内容（⭐ 表是常量 ⇒ 查表等价于验表）。
            mode = 1'b1;
            bad_cnt = 0;
            for (k = 0; k < 16; k = k + 1) begin
                if (dut.fb_inc[k] !== exp_tbl[k]) begin
                    bad_cnt = bad_cnt + 1;
                    $display("FAIL: fb_inc[%0d] = 0x%08h, expected 0x%08h", k, dut.fb_inc[k], exp_tbl[k]);
                end
            end
            chk("fretboard table: all 16 axes match the confirmed string/fret pitches", bad_cnt == 0);
        end

        $display("");
        if (errors == 0)
            $display("PASS: axis_map maps position to phase_inc, clamps at the table top, interpolates between adjacent keys, stays non-zero and monotonic, and keeps valid in the same cycle as data");
        else
            $fatal(1, "FAIL: axis_map had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
