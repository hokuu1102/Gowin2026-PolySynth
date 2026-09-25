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

        // ═══ 判据 ② 轴位满量程 → 落在【最后一个键】（⛔ 不越界、⛔ 不绕回表底）═══
        //   🔴 **⚠️ 判据名一度是错的（2026-09-23 由变异体 `M77` 查出）**：
        //      ⚠️ 原来叫 *"clamps at the table top"* —— ⭐ **但守住它的【不是钳位】**：
        //      ⭐ 真正保证不越界的是 **`key_idx` 的位宽**（4 位 ⇒ 最大 15 ⇒ 天然 ≤ `N_KEY-1`）。
        //      🔴 而 RTL 里那个三元钳位 **是死代码**（`key_idx >= N_KEY` 恒 False）⇒
        //         ⚠️ **删掉它这条判据照样通过**（⭐ 实测：变异体 `M77` = LEAK）。
        //      ⇒ ⭐ 判据名必须反映【真实机制】，⛔ 否则会让人误判"保护在哪里"（`K-87` 同族）。
        //   📌 **这条判据仍然保留**：⭐ 它守的是**可观测结果**（"满量程得到顶键"）——
        //      ⚠️ 将来若有人把中间量改回窄切片，⭐ **它就会红** ⇒ ⭐ 仍是有效守护。
        pos = 12'hFFF;  #1;
        v_last = phase_inc;
        chk("pos=max lands on the LAST key (width guarantees no overrun, no wrap)",
            phase_inc === expect_key(N_KEY-1));
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
        //
        //   🔴🔴 **2026-09-26 修正（⭐ 上板实测驱动的语义变更）**：
        //      ⚠️ 原判据假设"**指板模式也用 `pos_i` 选表**" ⇒ ⭐ 靠 `pos=0` 读表头。
        //      🔴 **但上板实测：⭐ 那样"所有键同深度 = 同音高"**（⭐ 用户症状）。
        //      ⇒ ⭐ **指板模式已改成用【轴号】`axis_id_i` 选表**（⭐ 见 `axis_map.v` 的
        //         §"指板模式必须用轴号选音"）。
        //      ⇒ ⭐ **本判据必须跟着改**：⭐ 扫【轴号】而不是扫 `pos`。
        //      📌 **教训**（⭐ 同族 `K-129`/`81 号`）：⭐ **判据要随设计意图走** ——
        //         ⚠️ 设计从"深度选音"改成"轴号选音"，⭐ 判据不同步就会【误报回归】。
        begin : mode_check
            integer kb_val, fb_val;
            //   ⭐ 先把 `pos` 设 0（⭐ 键盘模式仍用深度 ⇒ ⭐ 这样能读到键盘表头）
            pos = 12'd0;
            // 键盘模式（半音阶梯；⭐ 仍按【深度】选表）
            mode = 1'b0;  #1;
            kb_val = phase_inc;
            //   ⭐⭐ **指板模式：⭐ 扫轴号**（⭐ 这是本次修正的核心）
            //      ⭐ 判据：⭐ **不同轴号必须给出不同音高**（⭐ 这正是用户要的"按键分音"）
            mode = 1'b1;
            begin : fb_sweep
                integer ax;
                integer n_distinct;
                reg [31:0] first_val;
                reg seen_same_as_first;
                n_distinct         = 0;
                first_val          = 32'd0;
                seen_same_as_first = 1'b0;
                for (ax = 0; ax < 16; ax = ax + 1) begin
                    axis_id = ax[3:0];  #1;
                    fb_val  = phase_inc;
                    if (ax == 0) first_val = fb_val;
                    else if (fb_val !== first_val) n_distinct = n_distinct + 1;
                    else seen_same_as_first = 1'b1;
                    if (ax < 4 || ax == 15)
                        $display("  [fret] axis=%0d -> 0x%08h (%0d Hz)",
                                 ax, fb_val,
                                 (fb_val * 48828125) / 1000000000);
                end
                //   ⭐⭐ **核心判据：⭐ 16 个轴必须给出【互不相同】的音高**
                //      🔴 这正是上板症状的回归防线（⭐ 旧版这里恒为同一个值）
                chk("fretboard: all 16 axes give DIFFERENT pitches (the actual bug)",
                    n_distinct == 15);
                //   ⭐ 轴 0 = 四弦品1 = A2（⭐ 2026-09-23 用户确认版）
                axis_id = 4'd0;  #1;
                chk("fretboard axis 0 == E3 (0x00DD_3595) [left board upper row col3]",
                    phase_inc === 32'h00DD_3595);
                //   ⭐ 轴 15 = D#4（⭐ 表尾）
                axis_id = 4'd15;  #1;
                chk("fretboard axis 15 == C#4 (0x0174_073A) [right board upper row col2]",
                    phase_inc === 32'h0174_073A);
            end
            //   ⭐ 两模式必须不同（⭐ 回到轴 0 + pos 0 比较）
            axis_id = 4'd0;  pos = 12'd0;  mode = 1'b1;  #1;
            fb_val = phase_inc;
            $display("  [mode] pos=%0d kb=%0d (0x%08h)  fb=%0d (0x%08h)",
                     pos, kb_val, kb_val, fb_val, fb_val);
            chk("mode_i really switches the table (kb != fb for the same axis/pos)",
                kb_val !== fb_val);
        end
        mode = 1'b0;  #1;

        // ═══ 判据 ⑧ 轴号透传 ═══
        axis_id = 4'd11;  #1;
        chk("axis_id is passed through to the output", axis_id_o === 4'd11);

        // ═══ 判据 ⑨ ⭐⭐ 指板表【全 16 项】逐项核对（⭐ 最强的一条）═══
        //   ⭐ 2026-09-26 **上板实测锚定版**：轴号 → 音高（⭐ 4 弦 × 4 品）
        //   ⚠️ **轴号【不按物理位置递增】**（CH 号是布线决定的乱序）
        //      ⇒ ⭐ 必须【逐项】核对，⛔ 不能靠公式推。
        //
        //   🔴🔴 **2026-09-26 修正：⭐ 本表按【物理位置 ↔ 轴号】的实测锚定重排**
        //      ⭐ **旧表**（`轴k = FB_AXk`）🔴 **错在"按轴号升序填半音阶"** ⇒
        //         ⚠️ 上板表现：*"音高不太符合直觉"*。
        //      ⭐ **锚定依据**（⭐ 决定性）：
        //         ⭐ 用户提供**上板听到的现状图**，与"旧表 + 物理对应"**8 格全吻合**：
        //         ```
        //           物理上排(列1~4): E3  F3  A2  A#2   <= 旧表 轴6 轴7 轴0 轴1
        //           物理下排(列1~4): D#3 D3  C3  B2    <= 旧表 轴5 轴4 轴3 轴2
        //         ```
        //         ⇒ ⭐ **【轴号 ↔ 物理位置】被实测确认**（⭐ 与
        //            `霍尔键位-CH映射-20260923.md` §二 一致）⇒ ⭐ 可确定性重排。
        //      ⭐ **新表 = 目标**（⭐ 文档 §3.2 指板模式）：
        //         · 三弦 = 左板**上排** ⇒ 列1~4 = `D3 D#3 E3 F3`
        //         · 四弦 = 左板**下排** ⇒ 列1~4 = `A2 A#2 B2 C3`
        //         · 二弦 = 右板**下排** ⇒ 列1~4 = `G3 G#3 A3 A#3`
        //         · 一弦 = 右板**上排** ⇒ 列1~4 = `C4 C#4 D4 D#4`
        //      📌 **右板那 8 个是按同一规律推算的** —— ⚠️ 用户右手板**还没接线**，
        //         ⭐ 等接上后**用同样方法实测锚定**（⛔ 别当已验证）。
        begin : fb_table_check
            integer k;
            integer bad_cnt;
            reg [PHASE_W-1:0] exp_tbl [0:15];
            //   ── ⭐ 左板（轴 0~7）────────────────────────────────────────────
            exp_tbl[0]  = 32'h00DD_3595;  // 左板上排列3  E3
            exp_tbl[1]  = 32'h00EA_5CF4;  // 左板上排列4  F3
            exp_tbl[2]  = 32'h00AF_92EE;  // 左板下排列4  C3
            exp_tbl[3]  = 32'h00A5_B841;  // 左板下排列3  B2
            exp_tbl[4]  = 32'h009C_6B2A;  // 左板下排列2  A#2
            exp_tbl[5]  = 32'h0093_A3B6;  // 左板下排列1  A2
            exp_tbl[6]  = 32'h00C5_1339;  // 左板上排列1  D3
            exp_tbl[7]  = 32'h00D0_CB35;  // 左板上排列2  D#3
            //   ── ⭐ 右板（轴 8~15，⭐ 按同规律推算、⚠️ 待实测锚定）────────────
            exp_tbl[8]  = 32'h018A_2672;  // 右板上排列3  D4
            exp_tbl[9]  = 32'h01A1_966B;  // 右板上排列4  D#4
            exp_tbl[10] = 32'h0138_D653;  // 右板下排列4  A#3
            exp_tbl[11] = 32'h0127_476D;  // 右板下排列3  A3
            exp_tbl[12] = 32'h0116_B4CE;  // 右板下排列2  G#3
            exp_tbl[13] = 32'h0107_104E;  // 右板下排列1  G3
            exp_tbl[14] = 32'h015F_25DC;  // 右板上排列1  C4
            exp_tbl[15] = 32'h0174_073A;  // 右板上排列2  C#4
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
            $display("PASS: axis_map maps position to phase_inc, lands on the last key at full scale, interpolates between adjacent keys, stays non-zero and monotonic, and keeps valid in the same cycle as data");
        else
            $fatal(1, "FAIL: axis_map had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
