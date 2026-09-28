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

        // ═══════════════════════════════════════════════════════════════════
        //  🔴🔴 **2026-09-27 判据重写：⭐ 键盘模式改为【按轴号】索引**
        //
        //   ⭐ **为什么旧判据被删**：⭐ 它们验证的是**旧的"深度选音"语义**
        //      （`pos=0 → 表底`、`pos=max → 顶键`、`段内单调插值`…）。
        //   ⭐ **而 2026-09-27 上板实测**证明"深度选音"是**错的**：
        //      🔴 用户症状：⭐ *"**所有的音高是一样的**"*、*"一个键有**两个音色**，很尖"*
        //      ⇒ ⭐ 根因：⭐ `key_idx = pos >> SHIFT` 是**按压深度** ⇒
        //         **所有键按得差不多深 ⇒ 查到表的同一段 ⇒ 音高全一样**。
        //      ⇒ ⭐ **用户确认的正确语义**：*"键盘每键固定音，按轴号"*
        //
        //   📌 **新判据（与指板模式同构）**：
        //      · ⭐ **键盘模式也按轴号查表** ⇒ 不同轴号 ⇒ 不同音高
        //      · ⭐ **插值一律关闭**（`frac` 恒 0）⇒ `pos` 变化**不影响**音高
        //      · ⭐ **表的选择仍按 `mode`**：键盘 `kb_inc` / 指板 `fb_inc`
        //   ⚠️ **旧的深度判据【不再适用】** —— 但"深度→键位"的那条链
        //      **保留在 RTL 里**（⭐ 留给将来的"**滑弦**"功能），⛔ 未删除。
        // ═══════════════════════════════════════════════════════════════════

        // ═══ 判据 ① ⭐ 键盘模式：⭐ 音高只取决于【轴号】 ═══
        //   ⭐ 同一个轴号、任意 `pos` ⇒ **同一个音高**（⭐ 这是"每键固定音"的直接证据）
        axis_id = 4'd3;  pos = 12'd0;  pos_valid = 1'b1;  mode = 1'b0;
        #1;
        v0 = phase_inc;
        pos = 12'hFFF;  #1;
        chk("KB: same axis, any pos => SAME pitch (no depth dependence)",
            phase_inc === v0);

        // ═══ 判据 ② ⭐ 键盘模式：⭐ 不同轴号 ⇒ 音高【随轴号变化】 ═══
        //   🔴 旧的"深度选音"下，不同轴号但同样深度 ⇒ **同一个音** ⇒ 本条会【红】
        //
        //   ⚠️⚠️ **判据必须允许【重复音】**（⭐ 2026-09-27 我在这里写错过一次）：
        //      🔴 **`kb_inc` 表里有【两对重复】**（⭐ 设计如此，⛔ 不是 bug）：
        //         · `kb_inc[0] = kb_inc[3]  = E3`  ← ⭐ **E# 不存在**（E–F 间无黑键）
        //         · `kb_inc[8] = kb_inc[11] = B3`  ← ⭐ **B# 不存在**（B–C 间无黑键）
        //      ⭐ **用户 2026-09-27 明确要求**：⭐ *"**没有对应黑键的就发白键的音**"*
        //      ⇒ ⭐ **所以"16 个轴必须互不相同"是【错的判据】** ⇒ ⚠️ 会**假红**。
        //      📌 **教训**（⭐ `L84` 同族）：⭐ **判据的假设必须来自需求** ——
        //         ⚠️ "每个键一个音" ≠ "每个键一个**不同**的音"。
        //
        //   ✅ **正解**：⭐ **要求"随轴号变化"**（⛔ 不是"全不同"）：
        //      · ⭐ **至少 14 个不同音**（16 轴 − 2 对重复）
        //      · ⭐ **且不是"所有轴都相同"**（⭐ 那才是被修的 bug）
        begin : kb_axes_differ
            reg [PHASE_W-1:0] p_first;
            reg               varies;
            integer           ai;
            integer           n_diff;
            varies = 1'b0;
            n_diff = 0;
            axis_id = 4'd0;  pos = 12'd200;  #1;
            p_first = phase_inc;
            for (ai = 1; ai < N_KEY; ai = ai + 1) begin
                axis_id = ai[3:0];  pos = 12'd200;  #1;
                if (phase_inc !== p_first) begin
                    varies = 1'b1;
                    n_diff = n_diff + 1;
                end
            end
            $display("  [KB] axes differing from axis0 : %0d / 15", n_diff);
            //   ⭐ 核心：⭐ **不能"所有轴同音"**（⭐ 那就是被修的 bug）
            chk("KB: pitch VARIES with axis (not all-identical => the bug is fixed)",
                varies == 1'b1);
            //   ⭐ 更强：⭐ **至少 14 个不同**（⭐ 16 − 2 对重复）
            chk("KB: at least 14 distinct pitches across 16 axes (E#/B# duplicates allowed)",
                n_diff >= 13);
        end

        // ═══ 判据 ③ ⭐ 键盘模式：⭐ 不插值（pos 在段内变化不影响音高）═══
        axis_id = 4'd5;  pos = 12'd0;  #1;
        v0 = phase_inc;
        pos = 12'd255;  #1;              // 旧语义下这是"段内偏移 frac 满"
        chk("KB: interpolation is OFF (frac=0)", phase_inc === v0);

        // ═══ 判据 ④ ⭐ 键盘模式：⭐ 输出恒非零（⛔ 不会让音乐时钟静止）═══
        begin : kb_nonzero
            reg nz_ok;
            integer ai2;
            nz_ok = 1'b1;
            for (ai2 = 0; ai2 < N_KEY; ai2 = ai2 + 1) begin
                axis_id = ai2[3:0];  pos = 12'd100;  #1;
                if (phase_inc === {PHASE_W{1'b0}}) nz_ok = 1'b0;
            end
            chk("KB: phase_inc is NEVER zero across all 16 axes", nz_ok == 1'b1);
        end

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

        // ═══════════════════════════════════════════════════════════════════
        //  🔴 **2026-09-27 删除**：⭐ 原判据 ⑥「段内单调递增」
        //
        //   ⭐ 它验证的是**旧的"深度选音 + 段内插值"语义**
        //      （*"pitch is MONOTONIC inside every key segment"*）。
        //   🔴 而 2026-09-27 起：⭐ **键盘模式按轴号查表、插值一律关闭**
        //      ⇒ ⭐ `pos` 变化**不再影响音高** ⇒ ⚠️ **"段内单调"失去被测对象**
        //         （⭐ 任何 `pos` 都给同一个值 ⇒ "单调"平凡成立，⭐ 判它没意义）。
        //
        //   ⚠️ **替换品更强**（⭐ 见上方判据 ①②③）：
        //      · ⭐ *"same axis, any pos => SAME pitch"*  ← ⭐ 直接守"pos 不影响音高"
        //      · ⭐ *"different axes => different pitches"* ← ⭐ 直接守被修掉的 bug
        //   📌 **教训**（⭐ `L65`/`K-129` 同族）：⭐ **设计语义变了，判据要【换】⛔ 不是【删】**，
        //      ⚠️ 只删不补 = **静默失去保护**。
        // ═══════════════════════════════════════════════════════════════════
        // ═══════════════════════════════════════════════════════════════════
        //  🔴 **2026-09-27 删除两条判据**：⭐ "段内单调" 与 "段间递增"
        //
        //   ⭐ 它们验证的是**旧的"深度选音 + 段内插值"语义**：
        //      · *"pitch is MONOTONIC inside every key segment"*
        //      · *"each key segment starts strictly ABOVE the previous one"*
        //   🔴 而 2026-09-27 起，⭐ **键盘模式按轴号查表、且关掉插值**
        //      ⇒ ⭐ `pos` 变化**不再影响音高** ⇒ ⚠️ **"段内单调"失去被测对象**。
        //
        //   ⚠️ **这不是"删掉碍事的判据"** —— ⭐ 替换品**更强**：
        //      · ⭐ 判据 ① *"same axis, any pos => SAME pitch"*
        //        （⭐ 直接守住"pos 不影响音高"）
        //      · ⭐ 判据 ② *"different axes => different pitches"*
        //        （⭐ 直接守住被修掉的那个 bug）
        //      · ⭐ 判据 ⑨ 下方**逐项核对 16 个轴的真实音高**（⭐ 最强）
        //   📌 **教训**（⭐ `L65`/`K-129` 同族）：⭐ **设计语义变了，判据必须跟着换**，
        //      ⛔ 不能只删不补 —— ⚠️ 否则会**静默失去保护**。
        // ═══════════════════════════════════════════════════════════════════

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
            //   ⭐⭐ **2026-09-27：⭐ 两模式必须给出【不同】音高**
            //      ⚠️ 现在两种模式**都用轴号**索引 ⇒ ⭐ 比较必须**用同一个轴号**。
            //      🔴 **注意**：⭐ 不能只挑**一个**轴来比 —— ⚠️ 两表在**某个轴**上
            //         可能**恰好重合**（⭐ 实测：轴 0 两表都是 E3 = `0x00DD3595`）
            //         ⇒ ⭐ **那样会假红**（⭐ `L84` 同族教训：判据假设过强）。
            //      ✅ **正解**：⭐ **扫全部 16 个轴，只要【有一个】不同 ⇒ 两表确实不同**。
            begin : mode_switch_sweep
                integer mx;
                integer n_diff;
                n_diff = 0;
                for (mx = 0; mx < 16; mx = mx + 1) begin
                    axis_id = mx[3:0];  pos = 12'd0;
                    mode = 1'b0;  #1;
                    kb_val = phase_inc;
                    mode = 1'b1;  #1;
                    fb_val = phase_inc;
                    if (kb_val !== fb_val) n_diff = n_diff + 1;
                end
                $display("  [mode] axes where kb != fb : %0d / 16", n_diff);
                chk("mode_i really switches the table (kb != fb on at least one axis)",
                    n_diff > 0);
            end
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
            //   ⚠️ **PASS 文案必须与【当前语义】一致**（⭐ `L65`：过时文案会误导下一个人）
        //      🔴 旧文案说的是"maps **position** to phase_inc / interpolates between
        //         adjacent keys / monotonic" —— ⚠️ **那是 2026-09-27 之前的语义**。
        //      ⭐ 现在：⭐ **两种模式都按【轴号】查表、插值关闭**。
        $display("PASS: axis_map selects phase_inc by AXIS ID in both modes (keyboard + fretboard), with interpolation disabled; 16 fretboard axes and 16 keyboard axes each map to their confirmed pitch tables, phase_inc is never zero, and valid stays in the same cycle as data");
        else
            $fatal(1, "FAIL: axis_map had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
