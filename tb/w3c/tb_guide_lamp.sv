`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_guide_lamp.sv · `guide_lamp` 验收（音符事件 → 灯位指引映射层，丙线 P1）
//
// ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **语义已改 —— 灯位由【音高】决定**
//    ⭐ 用户拍板：*"LED 指引要跟着音高走，而且【变调之后】不许指错键"* ✅
//    🔴 原语义（⭐ 灯位 = `axis` = **轨号**）⇒ ⭐ **整场只闪一盏灯**
//       （⭐ 用户报 *"很多都只闪 C3 这一个灯"*）✅
//    ⭐ 新契约：⭐ 帧 `bit[4:0]` = `note_off5` = `MIDI − 45`
//       ⇒ ⭐ `+ transpose_i`（⭐ 变调）⇒ ⭐ **查表「音符号 → 键位」** ⇒ ⭐ 点亮那个键 ✅
//    📌 ⭐ 详见 `rtl/w3c/guide_lamp.v` 头部 §音高语义 ✅
//
// ⭐ 判据（⚠️ 每一条都必须能失败 —— K-56/C21；⭐ 尽量写成【不变量】—— C44）
//
//   ① ⭐ 反证基线：复位后 guide 全 0、无 commit 误报
//   ② ⭐ note_on 置位：喂 C3（offset 3）⇒ guide_key[5] 亮（⭐ 键盘表：C3 = 键 5）
//   ③ ⭐ note_off 清除：同一条音高 ⇒ guide_key[5] 灭（⭐ **ON/OFF 同一套推导**）
//   ④ ⭐ tempo 忽略：喂 kind=2（换速）⇒ 任何灯位都不变（⛔ 伪音符）
//   ⑤ ⭐⭐ 非空洞性：键号 0..15 **每一个**都能被某个（模式, 音高）点亮（满射）
//   ⑥ ⭐ commit 单周期：指引变化那拍拉高恰好 1 拍
//   ⑦ ⭐ 多键并存：两个**不同音高**同时 on ⇒ 两盏灯（⛔ 不再"只闪一盏"）
//   ⑧ ⭐⭐⭐⭐ **表互逆**（⭐ 机械、防手抄错表）：⭐ 遍历 **2 模式 × 32 个 offset**
//        ⇒ ⭐ DUT 点亮的键 **必须** 等于「由 `axis_map.v` 的正向表反推」出来的键
//        ⇒ ⭐ 表里没有的音符号 ⇒ **一盏都不许亮**（⭐ 哨兵规则）
//        ⇒ ⭐ 每条 `note_off` **必须**清掉同一盏灯 ✅
//   ⑨ ⭐⭐⭐⭐ **变调后仍指对键**（⭐ 用户要的那一条）：
//        · ⭐ `transpose=+2` ⇒ ⭐ 点的是"**高 2 个半音**"对应的键（⛔ 不是"键号 +2"）
//        · ⭐ `transpose=−2` ⇒ ⭐ 点的是"**低 2 个半音**"对应的键
//        · ⭐ 出界（⭐ 变调后不在 MIDI 45..76）⇒ ⭐ **不点灯**
//        📌 ⭐ **反例**（⭐ 必红）：⭐ 若忘了接 `transpose_i`（⭐ 或先查表再加变调）
//           ⇒ 🔴 `9b`/`9c`/`9d` 全红 ✅
//   ⑩ ⭐ **哨兵**：⭐ 表里没有的音符号 ⇒ ⭐ **不点灯**，⭐ 尤其
//        🔴 **⛔ 不许误点亮键 0**（⭐ 若把哨兵写成 0 就必红 ✅）
//        🔴🔴 **而且哨兵⛔ 不许与任何【真实键号】撞车** ——
//           ⭐ **2026-10-16：本 tb 的判据 ⑧【真的抓住】**了这个缺陷 ✅
//           ⚠️ 原设计的哨兵 = `4'hF` ⇒ 🔴 **`4'hF` 就是【键 15】本身**！
//              ⇒ 🔴 **键 15 永远点不亮**（⭐ 而它是真的：⭐ `kb` A#3 / ⭐ `fb` C#4）
//              ⇒ ⭐ 当时的红原文（⭐ 已实测）：
//                 `FAIL: mode=0 off=13 (MIDI 58) expected key 15, got 0000`
//           ✅ **已修**：⭐ 表项加宽到 **5 位**、⭐ 哨兵 = **`5'd16`**（⭐ 键号之外）✅
//           📌 ⭐ 判据 **⑤（满射）＋ ⑧（互逆）** 现在**同时**钉住这一条 ——
//              ⚠️ 只要哨兵与任何键撞车 ⇒ 🔴 **两条都红** ✅
//              （⭐ 已实测：⭐ 把哨兵改回 `5'd15` ⇒ 🔴 ⑤⑧ 全红 ✅）
//   Ⓟ ⭐ `P0-28` 消隐：⭐ 已按下的键仍被指引 ⇒ 必须被 `guide_vis_o` 抹掉（⭐ 保留）
//
// ⭐ 正向表**⛔ 不在本文件手抄音符号**：⭐ MIDI 号由**代码算**
//    （⭐ `12*(octave+1) + semitone`，⭐ `C4 = 60`）✅
// ─────────────────────────────────────────────────────────────────────────────

module tb_guide_lamp;

    localparam integer EVT_W  = 64;
    localparam integer AXIS_N = 16;

    // ⭐ 位域偏移（与 play_seq 冻结契约逐位一致）
    localparam integer NOTE_SH = 0;      // ⭐ note_off5（MIDI − 45）
    localparam integer AXIS_SH = 19;
    localparam integer KIND_SH = 9;
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_TEMPO = 2'd2;

    // ⭐ 音高基准（⭐ 与 `guide_lamp.v` 的 `BASE_NOTE` 一致）
    localparam integer BASE_NOTE = 45;   // ⭐ A2
    localparam integer KEY_NONE  = 15;   // ⭐ = `4'hF`（⭐ 表里的"没有这个音"哨兵）

    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg                     rst_n       = 1'b0;
    reg                     note_valid  = 1'b0;
    reg  [EVT_W-1:0]        note_data   = {EVT_W{1'b0}};
    reg  [AXIS_N-1:0]       key_active  = {AXIS_N{1'b0}};
    //  ⭐⭐ 2026-10-09（`P0-28`）：⭐ `blink` 已删（⭐ `guide_lamp` 的 `blink_i` 端口已删）✅
    //   📌 理由：⭐ 闪烁是 `led_data` 的职责（⭐ 它已经做了 `blink_keys & blink_i`）
    //      ⇒ ⚠️ 若 `guide_lamp` 也做 ⇒ 🔴 两次闪烁串联 ⇒ 占空比变 25% ✅
    //
    //  ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **新增的三个激励**（⭐ 灯位的新依据）✅
    reg  [4:0]              note_off5   = 5'd0;      // ⭐ MIDI − 45
    reg  signed [4:0]       transpose   = 5'sd0;     // ⭐ 运行期变调（半音）
    reg                     fb_mode     = 1'b0;      // ⭐ 1 = 指板表 · 0 = 键盘表

    wire [AXIS_N-1:0]       guide_key;
    wire                    guide_commit;
    //  ⭐⭐ 2026-10-09（`P0-28`）：⭐ **消隐后的指引位图**（⭐ 新端口）✅
    wire [AXIS_N-1:0]       guide_vis;

    integer errors = 0;
    integer checks = 0;

    task chk;
        input [8*100-1:0] name;
        input             cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    guide_lamp #(
        .EVT_W  (EVT_W),
        .AXIS_N (AXIS_N)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .note_valid_i   (note_valid),
        .note_data_i    (note_data),
        //  ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **音高 ＋ 变调 ＋ 表选择** ✅
        .note_off5_i    (note_off5),
        .transpose_i    (transpose),
        .fb_mode_i      (fb_mode),
        .key_active_i   (key_active),
        //  ⭐⭐ 2026-10-09（`P0-28`）：⭐ `.blink_i` 已删（⭐ 端口删了）+ ⭐ 接出消隐输出 ✅
        .guide_vis_o    (guide_vis),
        .guide_key_o    (guide_key),
        .guide_commit_o (guide_commit)
    );

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ **正向表（⭐ 与 `rtl/w3a/axis_map.v` 的 `kb_inc[]` / `fb_inc[]` 同内容）**
    //
    //  ⭐ **MIDI 号由【代码】算**（⛔ 不手抄数字）：
    //     `MIDI = 12*(octave+1) + semitone`，⭐ `C4 = 60` ✅
    //     · ⭐ semitone：⭐ C=0 C#=1 D=2 D#=3 E=4 F=5 F#=6 G=7 G#=8 A=9 A#=10 B=11
    //  📌 ⭐ 由 `build/exp/note2key_gen.py` **打印出来**（⭐ 我只是搬过来，
    //     ⚠️ 数字仍然是**代码算的**）✅
    //  📌 ⭐ 这是判据 ⑧「表互逆」的**对照物** ——
    //     ⭐ 它 + `rev_of()` 一起把"**反查表抄错**"变成**必红** ✅
    // ═══════════════════════════════════════════════════════════════════════
    function integer midi;
        input integer octave;
        input integer semitone;
        begin
            midi = 12 * (octave + 1) + semitone;
        end
    endfunction

    integer kb_of [0:15];      // ⭐ 键盘/钢琴：⭐ 键号 → MIDI（⭐ 源 `kb_inc[]`）
    integer fb_of [0:15];      // ⭐ 指板：      ⭐ 键号 → MIDI（⭐ 源 `fb_inc[]`）

    // ⭐ 0 = 键盘表（`kb`）· ⭐ 1 = 指板表（`fb`）
    function integer pitch_of;
        input integer mode;
        input integer k;
        begin
            pitch_of = (mode != 0) ? fb_of[k] : kb_of[k];
        end
    endfunction

    // ⭐ 反查：⭐ (模式, offset) → 键号；⭐ **-1 = 这个音符号没有任何键**
    //   📌 ⭐ **重复项取【索引最小】** —— ⭐ 与 `guide_lamp.v` 的规则**逐字一致** ✅
    function integer rev_of;
        input integer mode;
        input integer off;
        integer k;
        integer m;
        integer found;
        begin
            found = -1;
            m     = BASE_NOTE + off;
            for (k = 0; k < 16; k = k + 1)
                if ((found < 0) && (pitch_of(mode, k) == m)) found = k;
            rev_of = found;
        end
    endfunction

    // ⭐ 位图 → 键号：⭐ 0 位 ⇒ -1（⭐ 没亮）· ⭐ 多位 ⇒ -2（⭐ 不该发生）✅
    function integer bitmap_key;
        input [15:0] bm;
        integer k;
        integer n;
        integer f;
        begin
            n = 0;
            f = -1;
            for (k = 0; k < 16; k = k + 1)
                if (bm[k]) begin n = n + 1; f = k; end
            bitmap_key = (n == 1) ? f : ((n == 0) ? -1 : -2);
        end
    endfunction

    // ── 构造并发送一条事件（⭐ note_off5 在 [4:0]，kind 在 [10:9]）───────────
    //   ⚠️ 时序：note_valid 在 negedge 拉高，DUT 在**下一个 posedge** 采样，
    //      并在**同一 posedge**（非阻塞）更新 guide_key / guide_commit。
    //      ⇒ send_ev 结束时停在【那个 posedge 之后】，commit 仍为高，
    //        调用方【立即】查 guide_key / guide_commit 即可（⛔ 不要再等 negedge）。
    //   📌 ⭐ `axis` 字段**照样填**（⭐ 帧里仍有它、⭐ 发声那一路要用），
    //      ⚠️ 但 ⭐ **灯位已经与它无关** ⇒ 本 tb 故意填变化的轴号，
    //      ⭐ 让"**灯跟着音高、⛔ 不跟着轴号**"这条**在判据里看得见** ✅
    //   📌 ⭐ **同时驱动【端口】与【帧字段】** —— ⭐ 复刻 `top.v` 的接线
    //      （⭐ `ps_note_off5 = ps_note_data[4:0]` ⇒ ⭐ `.note_off5_i(...)`）✅
    //      🔴 **本轮实测踩到的坑**：⭐ 只填 `note_data[4:0]` 而**端口一直是 0** ⇒
    //         ⭐ DUT 永远按 offset 0 查表 ⇒ 🔴 **判据 ⑧ 大面积红**
    //         （⭐ 而它**正好证明**这些判据**不是假绿**：⭐ 激励没接上就一定红 ✅）
    task send_ev;
        input [4:0]  off5;
        input [1:0]  kind;
        input [3:0]  axis;
        begin
            @(negedge clk);
            note_data  = {EVT_W{1'b0}};
            note_data[NOTE_SH +: 5] = off5;
            note_data[AXIS_SH +: 4] = axis;
            note_data[KIND_SH +: 2] = kind;
            note_off5  = off5;        // ⭐ 端口（⭐ 与帧字段同拍、同值）
            note_valid = 1'b1;
            @(posedge clk);          // DUT 采样 note_valid=1，并更新输出
            #1;                       // 让非阻塞赋值落地
            note_valid = 1'b0;        // 关掉 valid，但输出已更新
        end
    endtask

    // ⭐ 便捷：⭐ 给一个"只在键盘模式、不变调"的音符（⭐ 老判据的等价写法）
    task send_off5;
        input [4:0] off5;
        input [1:0] kind;
        begin
            send_ev(off5, kind, 4'd0);
        end
    endtask

    integer i, j, k, md, off, exp, got, bad, hit;
    integer reach_bad;

    initial begin
        $dumpfile("build/sim/tb_guide_lamp/tb_guide_lamp.vcd");
        $dumpvars(0, tb_guide_lamp);

        // ═══════════════════════════════════════════════════════════════════
        //  ⭐ 正向表初始化（⭐ **MIDI 由代码算**，⛔ 不手抄）✅
        //     📌 ⭐ 与 `axis_map.v` 的 `kb_inc[]` / `fb_inc[]` **逐项对应** ✅
        // ═══════════════════════════════════════════════════════════════════
        kb_of[ 0] = midi(3,  4);   // E3
        kb_of[ 1] = midi(3,  6);   // F#3
        kb_of[ 2] = midi(3,  5);   // F3
        kb_of[ 3] = midi(3,  4);   // E3    <-- ⭐ 与键 0 重复
        kb_of[ 4] = midi(3,  2);   // D3
        kb_of[ 5] = midi(3,  0);   // C3
        kb_of[ 6] = midi(3,  1);   // C#3
        kb_of[ 7] = midi(3,  3);   // D#3
        kb_of[ 8] = midi(3, 11);   // B3
        kb_of[ 9] = midi(4,  1);   // C#4
        kb_of[10] = midi(4,  0);   // C4
        kb_of[11] = midi(3, 11);   // B3    <-- ⭐ 与键 8 重复
        kb_of[12] = midi(3,  9);   // A3
        kb_of[13] = midi(3,  7);   // G3
        kb_of[14] = midi(3,  8);   // G#3
        kb_of[15] = midi(3, 10);   // A#3
        fb_of[ 0] = midi(3,  4);   // E3
        fb_of[ 1] = midi(3,  5);   // F3
        fb_of[ 2] = midi(3,  0);   // C3
        fb_of[ 3] = midi(2, 11);   // B2
        fb_of[ 4] = midi(2, 10);   // A#2
        fb_of[ 5] = midi(2,  9);   // A2
        fb_of[ 6] = midi(3,  2);   // D3
        fb_of[ 7] = midi(3,  3);   // D#3
        fb_of[ 8] = midi(4,  2);   // D4
        fb_of[ 9] = midi(4,  3);   // D#4
        fb_of[10] = midi(3, 10);   // A#3
        fb_of[11] = midi(3,  9);   // A3
        fb_of[12] = midi(3,  8);   // G#3
        fb_of[13] = midi(3,  7);   // G3
        fb_of[14] = midi(4,  0);   // C4
        fb_of[15] = midi(4,  1);   // C#4

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("=== tb_guide_lamp (灯位 = 音高查表 + 运行期变调) ===");
        $display("   kb: E3=%0d F#3=%0d C3=%0d B3=%0d A3=%0d | fb: A2=%0d D4=%0d",
                 kb_of[0], kb_of[1], kb_of[5], kb_of[8], kb_of[12],
                 fb_of[5], fb_of[8]);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：复位后全 0、无 commit
        // ═══════════════════════════════════════════════════════════════════
        @(negedge clk);
        chk("baseline: guide all 0 right after reset", guide_key === {AXIS_N{1'b0}});
        chk("baseline: commit is 0 (no spurious)", guide_commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ② note_on 置位：⭐ 键盘模式 · C3（MIDI 48 ⇒ offset 3）⇒ 键 5 亮
        //     ⭐ 键号 = **查表**得到（⭐ 键盘表：C3 = 键 5）✅
        // ═══════════════════════════════════════════════════════════════════
        fb_mode = 1'b0; transpose = 5'sd0;
        send_off5(5'd3, KIND_ON);                       // ⭐ MIDI 48 = C3
        chk("note_on C3(kb) -> guide[5] lit (key 5, NOT the axis)", guide_key[5] === 1'b1);
        chk("note_on C3(kb) -> one-hot (only bit5)", guide_key === 16'h0020);
        chk("note_on C3(kb) -> commit pulsed", guide_commit === 1'b1);

        // ═══════════════════════════════════════════════════════════════════
        // ③ note_off 清除：⭐ **同一条音高** ⇒ 同一盏灯灭（⭐ ON/OFF 同一套推导）
        // ═══════════════════════════════════════════════════════════════════
        send_off5(5'd3, KIND_OFF);
        chk("note_off C3(kb) -> guide[5] off", guide_key[5] === 1'b0);
        chk("note_off C3(kb) -> all 0 again", guide_key === {AXIS_N{1'b0}});

        // ═══════════════════════════════════════════════════════════════════
        // ④ tempo 忽略：kind=2 换速 ⇒ 灯位不变（⛔ 伪音符）
        // ═══════════════════════════════════════════════════════════════════
        send_off5(5'd12, KIND_TEMPO);
        @(negedge clk);
        chk("tempo ignored -> guide stays 0", guide_key === {AXIS_N{1'b0}});
        chk("tempo ignored -> no commit", guide_commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑤⭐ 非空洞性：⭐ 键号 0..15 **每一个**都能被某个（模式, 音高）点亮 ✅
        //     📌 ⭐ **为什么不是"每个键都有一条自己的音高"**：
        //        ⚠️ 键盘表里 E3 = 键 0 **和** 键 3、B3 = 键 8 **和** 键 11
        //        ⇒ ⭐ 按"重复取最小索引"的规则，⭐ 键 3 / 键 11 在**键盘模式**
        //           **永远点不到**（⭐ 这是**规则要的**）——
        //        ⭐ 但它们在**指板模式**点得到（⭐ `fb` 表 16 个键音高互不相同）✅
        //     ⇒ ⭐ **本判据 = "16 个物理键【合起来】都可达"**（⭐ 满射，⭐ 无空洞）✅
        // ═══════════════════════════════════════════════════════════════════
        begin : non_vacuity
            reach_bad = 0;
            for (k = 0; k < 16; k = k + 1) begin
                hit = 0;
                for (md = 0; md < 2; md = md + 1) begin
                    for (off = 0; off < 32; off = off + 1) begin
                        if (rev_of(md, off) == k) hit = 1;
                    end
                end
                if (!hit) begin
                    reach_bad = reach_bad + 1;
                    $display("  FAIL: key %0d is not reachable from ANY (mode,pitch)", k);
                end
                // ⭐ 真去点一次（⭐ 这才是 DUT 级证据，⛔ 不只是表算术）✅
                else begin
                    for (md = 0; md < 2; md = md + 1) begin
                        for (off = 0; off < 32; off = off + 1) begin
                            if ((rev_of(md, off) == k) && (hit == 1)) begin
                                fb_mode = (md != 0);
                                send_ev(off[4:0], KIND_ON, k[3:0]);
                                if (bitmap_key(guide_key) != k) begin
                                    reach_bad = reach_bad + 1;
                                    $display("  FAIL: key %0d not lit: mode=%0d off=%0d => %h",
                                             k, md, off, guide_key);
                                end
                                send_ev(off[4:0], KIND_OFF, k[3:0]);
                                hit = 2;      // ⭐ 只点一次就够
                            end
                        end
                    end
                end
            end
            fb_mode = 1'b0;
            chk("non-vacuity: every physical key 0..15 is reachable & lights its own lamp",
                reach_bad == 0);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ commit 单周期：指引变化那拍恰好 1 拍
        // ═══════════════════════════════════════════════════════════════════
        send_off5(5'd7, KIND_ON);                       // ⭐ E3 ⇒ 键 0
        chk("commit high on change", guide_commit === 1'b1);
        @(posedge clk);                          // 下一拍 DUT 采样 note_valid=0 ⇒ commit 回落
        #1;
        chk("commit falls back to 0 next cycle", guide_commit === 1'b0);
        // 清掉，避免影响 ⑦ 的"只有两 bit"
        send_off5(5'd7, KIND_OFF);

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ 多键并存：⭐ 两个**不同音高** ⇒ 两盏灯（⛔ 互相覆盖）
        //     ⭐ E3（off 7 ⇒ 键 0）+ ⭐ C#4（off 16 ⇒ 键 9）✅
        //     📌 ⭐ 这正是用户要的"**跟着音高走**" ——
        //        🔴 旧语义下这两条事件（⭐ 同一条轨）**只会亮同一盏灯** ✅
        // ═══════════════════════════════════════════════════════════════════
        send_off5(5'd7,  KIND_ON);                      // ⭐ E3  ⇒ 键 0
        send_off5(5'd16, KIND_ON);                      // ⭐ C#4 ⇒ 键 9
        chk("multi: two different PITCHES light two lamps", guide_key[0] === 1'b1 && guide_key[9] === 1'b1);
        chk("multi: only those two bits", guide_key === 16'h0201);
        send_off5(5'd7,  KIND_OFF);
        send_off5(5'd16, KIND_OFF);
        chk("multi: both cleared -> all 0", guide_key === {AXIS_N{1'b0}});

        // ═══════════════════════════════════════════════════════════════════
        // ⑧⭐⭐⭐⭐ **表互逆**（⭐ 机械断言，⭐ 防手抄错表）
        //     ⭐ 遍历 **2 个模式 × 32 个 offset**（⭐ = MIDI 45..76 全覆盖）：
        //        · ⭐ 期望键 = `rev_of()`（⭐ **由正向表机械反推**）✅
        //        · ⭐ DUT 点亮 = 必须**恰好**是那一盏（⭐ 一位、且是那一位）✅
        //        · ⭐ 表里没有的音符号 ⇒ ⭐ **一盏都不许亮**（⭐ 哨兵规则）✅
        //        · ⭐ 紧接着的 `note_off` ⇒ ⭐ **必须清掉**（⭐ 否则是"挂灯"）✅
        //     📌 ⭐ **这一条就是"反查表抄错"的机械保证** ——
        //        ⚠️ 32 项里错一项 ⇒ 🔴 **必红**（⭐ 而且报出**具体是哪个 offset**）✅
        //     📌 ⭐ **非空洞性**：⭐ 本判据**真的驱动 DUT 64 次**并**每次读回位图**，
        //        ⛔ 不是"对表做算术" ⇒ ⭐ 不存在"探针假绿"（⭐ `C83`）✅
        // ═══════════════════════════════════════════════════════════════════
        begin : table_inverse
            bad = 0;
            for (md = 0; md < 2; md = md + 1) begin
                fb_mode = (md != 0);
                for (off = 0; off < 32; off = off + 1) begin
                    exp = rev_of(md, off);
                    send_ev(off[4:0], KIND_ON, off[3:0]);
                    got = bitmap_key(guide_key);
                    if (exp < 0) begin
                        if (got != -1) begin
                            bad = bad + 1;
                            $display("  FAIL: mode=%0d off=%0d (MIDI %0d) is NOT in the table but lit %h",
                                     md, off, BASE_NOTE + off, guide_key);
                        end
                    end
                    else if (got != exp) begin
                        bad = bad + 1;
                        $display("  FAIL: mode=%0d off=%0d (MIDI %0d) expected key %0d, got %h (bitmap_key=%0d)",
                                 md, off, BASE_NOTE + off, exp, guide_key, got);
                    end
                    send_ev(off[4:0], KIND_OFF, off[3:0]);
                    if (guide_key !== {AXIS_N{1'b0}}) begin
                        bad = bad + 1;
                        $display("  FAIL: mode=%0d off=%0d note_off did NOT clear the lamp (%h) -- hanging lamp",
                                 md, off, guide_key);
                    end
                end
            end
            chk("table inverse: all 2 modes x 32 offsets match axis_map's forward table",
                bad == 0);
        end
        fb_mode = 1'b0;

        // ═══════════════════════════════════════════════════════════════════
        // ⑨⭐⭐⭐⭐ **变调后仍指对键**（⭐ 用户拍板的那一条）
        //
        //   ⭐ 用 **A3**（⭐ MIDI 57 ⇒ offset 12）当基准：
        //      · ⭐ `transpose = 0`  ⇒ ⭐ 键 **12**（⭐ 键盘表：A3 = 键 12）✅
        //      · ⭐ `transpose = +2` ⇒ ⭐ 音高 = **B3**（59）⇒ ⭐ 键 **8**
        //      · ⭐ `transpose = −2` ⇒ ⭐ 音高 = **G3**（55）⇒ ⭐ 键 **13**
        //
        //   🔴 **反例 1（⭐ 忘了接 `transpose_i`）**：⭐ 三条都会停在键 12 ⇒ 🔴 9b/9c 红 ✅
        //   🔴 **反例 2（⭐ 先查表、再把"键号"平移 2）**：⭐ 会点键 12+2=**14**
        //      —— ⚠️ 而**正确**答案是键 **8**（⭐ 因为键位**不是**按半音排的）
        //      ⇒ ⭐ 判据**同时**断言 `[8]==1` **和** `[14]==0` ⇒ 🔴 必红 ✅
        //      📌 ⭐ 这一条正是"**必须【先变调、后查表】**"的机械证明 ✅
        // ═══════════════════════════════════════════════════════════════════
        transpose = 5'sd0;  fb_mode = 1'b0;
        send_off5(5'd12, KIND_ON);                       // ⭐ A3 ⇒ 键 12
        chk("9a transpose=0 : A3 (off 12) -> key 12", guide_key === 16'h1000);
        send_off5(5'd12, KIND_OFF);

        transpose = 5'sd2;                               // ⭐ +2 半音 ⇒ B3 ⇒ 键 8
        send_off5(5'd12, KIND_ON);
        chk("9b transpose=+2 : A3+2 = B3 -> key 8  <-- the pitch moved, not the key index",
            guide_key === 16'h0100);
        chk("9b' transpose=+2 did NOT just shift the key index (12+2=14 must be dark)",
            guide_key[14] === 1'b0 && guide_key[12] === 1'b0);
        send_off5(5'd12, KIND_OFF);

        transpose = -5'sd2;                              // ⭐ −2 半音 ⇒ G3 ⇒ 键 13
        send_off5(5'd12, KIND_ON);
        chk("9c transpose=-2 : A3-2 = G3 -> key 13", guide_key === 16'h2000);
        send_off5(5'd12, KIND_OFF);

        //  ⭐⭐⭐ **"先变调后查表"的判别用例**（⭐ 旧写法在这里必错）：
        //     ⭐ E3（off 7）⇒ 键 **0**；⭐ `+1` 半音 ⇒ F3（off 8）⇒ 键 **2** ✅
        //     🔴 若"先查表再平移键号" ⇒ ⭐ 会点键 **1**（⭐ 0+1）⇒ ⭐ 本条必红 ✅
        transpose = 5'sd1;
        send_off5(5'd7, KIND_ON);                        // ⭐ E3 + 1 = F3 ⇒ 键 2
        chk("9d transpose=+1 : E3+1 = F3 -> key 2  (NOT key 0+1=1)",
            guide_key === 16'h0004 && guide_key[1] === 1'b0);
        send_off5(5'd7, KIND_OFF);

        //  ⭐ 出界：⭐ 变调后不在 MIDI 45..76 ⇒ ⭐ **不点灯**（⭐ 也不许乱点）✅
        transpose = 5'sd12;                              // ⭐ offset 31 + 12 = 43 > 31
        send_off5(5'd31, KIND_ON);
        chk("9e out of range (off 31 + 12) -> NOTHING lit", guide_key === {AXIS_N{1'b0}});
        chk("9e' out of range -> no commit", guide_commit === 1'b0);
        transpose = -5'sd12;                             // ⭐ offset 0 − 12 = −12 < 0
        send_off5(5'd0, KIND_ON);
        chk("9f out of range (off 0 - 12) -> NOTHING lit", guide_key === {AXIS_N{1'b0}});

        //  ⭐ 变调后**在范围内、但表里没有**该音 ⇒ ⭐ 也不点灯 ✅
        //     ⭐ C#4（off 16）+ 12 = 73 = C#5 ⇒ ⭐ 键盘表无此项（⭐ 哨兵）✅
        transpose = 5'sd12;
        send_off5(5'd16, KIND_ON);
        chk("9g in range but unmapped (kb C#5) -> NOTHING lit", guide_key === {AXIS_N{1'b0}});
        transpose = 5'sd0;

        // ═══════════════════════════════════════════════════════════════════
        // ⑩⭐ 哨兵 = `4'hF`：⭐ 表里没有的音符号 ⇒ ⭐ **不点灯**
        //     🔴 **本条专钉"哨兵⛔ 不能填 0"**：⭐ 若表里填 0
        //        ⇒ 🔴 **键 0 会被误点亮** ⇒ ⭐ 本条必红 ✅
        //     ⭐ 键盘表里 A2（off 0）/ B2（off 2）都**没有**对应键 ✅
        // ═══════════════════════════════════════════════════════════════════
        fb_mode = 1'b0;
        send_off5(5'd0, KIND_ON);                        // ⭐ A2（键盘表无此项）
        chk("10a unmapped pitch (kb A2) lights NOTHING", guide_key === {AXIS_N{1'b0}});
        chk("10b unmapped pitch must NOT light key 0 (sentinel is 5'd16, not 0)",
            guide_key[0] === 1'b0);
        send_off5(5'd2, KIND_ON);                        // ⭐ B2（键盘表无此项）
        chk("10c unmapped pitch (kb B2) lights NOTHING", guide_key === {AXIS_N{1'b0}});
        //  ⭐ 对照：⭐ **指板表里 A2 = 键 5**（⭐ 同一帧、⭐ 只是模式不同）✅
        //     📌 ⭐ 这一对（10a vs 10d）证明"**模式真的在选表**" ✅
        fb_mode = 1'b1;
        send_off5(5'd0, KIND_ON);
        chk("10d the SAME pitch in fretboard mode -> key 5 (mode really selects the table)",
            guide_key === 16'h0020);
        send_off5(5'd0, KIND_OFF);
        fb_mode = 1'b0;

        // ═══════════════════════════════════════════════════════════════════
        // Ⓟ `P0-28`：⭐ **已按下的键必须被消隐**（⭐ 本段**原样保留**）✅
        //   🔴 **原缺陷**：⭐ `key_active_i` 在 RTL 里**一次都没用到**
        //   ⭐ **判据**：⭐ `key_active = 16'h0008`（⭐ 键 3 正在响）+ ⭐ 点亮键 3
        //      ⇒ ⭐ `guide_key_o[3] == 1`（⭐ 指引位亮）**但** `guide_vis_o[3] == 0`（⭐ 被消隐）✅
        //   📌 ⭐ 点键 3 要用**指板表**（⭐ 键盘表里键 3 是重复项 ⇒ 点不到）：
        //      ⭐ `fb[3] = B2`（⭐ MIDI 47 ⇒ offset 2）✅
        // ═══════════════════════════════════════════════════════════════════
        key_active = 16'h0008;                       // ⭐ 键 3 正在响
        fb_mode = 1'b1;
        send_ev(5'd2, KIND_ON, 4'd3);                // ⭐ B2（指板）⇒ 键 3
        chk("P0-28 a PRESSED key is blanked: guide_key[3]=1 but guide_vis[3]=0",
            guide_key[3] === 1'b1 && guide_vis[3] === 1'b0);
        chk("P0-28 blanking does not disturb other axes: guide_vis == guide_key & ~key_active",
            guide_vis === (guide_key & ~key_active));
        key_active = 16'h0000;                       // ⭐ 松手 ⇒ 指引位恢复可见
        #1;
        chk("P0-28 after release the guide bit is visible again", guide_vis[3] === 1'b1);
        send_ev(5'd2, KIND_OFF, 4'd3);
        fb_mode = 1'b0;

        // ═══════════════════════════════════════════════════════════════════
        // ⭐⭐ 2026-10-17（Q4）：⭐ **每键引用计数** —— 同音高多 voice 时
        //     ⭐ "**第一个 `note_off` ⛔ 不熄灯，最后一个才熄**" ✅
        //
        //  🔴 **缺陷（改前）**：ON 是 `guide_key_o[k] <= 1`、OFF 是 `<= 0`（直接写位）
        //     ⇒ ⚠️ 同音高还有别的 voice 在响时，**第一个 OFF 就把灯灭了** ✅
        //     📌 实测比例（`build/score/*/events.csv`）：OFF 到达时"同音高仍有别的 voice"
        //        = **61~77%** ⇒ ⭐ 按音高指键之后这就是**主行为**（⛔ 不是角落）✅
        //
        //  ⭐ **本段在改前【必红】在 `Q4-b`**（⭐ 那时 `guide_key[9]` 已经是 0）✅
        //  ⭐ **非空洞性**（`Q4-e`）：⭐ 另一个音高的 `note_off` **必须真的灭自己那盏**
        //     ⇒ ⛔ 不是"灯永远不灭"也能通过 ✅
        // ═══════════════════════════════════════════════════════════════════
        $display("== ⑪ Q4 refcount: one note_off must NOT kill a shared lamp ==");
        fb_mode = 1'b0; transpose = 5'sd0;
        //  ⭐ 前置条件：⭐ 键 9（C#4 · off 16）此刻必须是**灭的、计数为 0**
        //     （⭐ 前面每次 ON 都有配对的 OFF ⇒ 天然归零；万一不是，这条先红，指向明确）
        chk("Q4-0 precondition: key 9 is dark before the test", guide_key[9] === 1'b0);

        send_off5(5'd16, KIND_ON);           // ⭐ voice A（C#4 ⇒ 键 9）
        send_off5(5'd16, KIND_ON);           // ⭐ voice B（**同一个音高**）
        chk("Q4-a two voices on the SAME pitch still light exactly one lamp",
            guide_key === 16'h0200);

        send_off5(5'd16, KIND_OFF);          // ⭐ 只撤掉**一根**引用
        chk("Q4-b *** the FIRST note_off KEEPS the lamp ON (this is the Q4 fix) ***",
            guide_key[9] === 1'b1);

        send_off5(5'd16, KIND_OFF);          // ⭐ 最后一根引用
        chk("Q4-c the LAST note_off finally clears it", guide_key[9] === 1'b0);
        chk("Q4-d ... and nothing else is lit", guide_key === {AXIS_N{1'b0}});

        //  ── ⭐ 反向证伪：**不同音高**互不影响（⛔ 不是"灯永远不灭"）──────────
        send_off5(5'd7,  KIND_ON);           // ⭐ E3  ⇒ 键 0
        send_off5(5'd16, KIND_ON);           // ⭐ C#4 ⇒ 键 9
        send_off5(5'd7,  KIND_OFF);          // ⭐ 只撤 E3
        chk("Q4-e NON-VACUOUS: another pitch's note_off DOES clear its own lamp (key0 dark, key9 lit)",
            guide_key[0] === 1'b0 && guide_key[9] === 1'b1);
        send_off5(5'd16, KIND_OFF);
        chk("Q4-f clean at the end", guide_key === {AXIS_N{1'b0}});

        //  ── 饱和自愈：⭐ 8 个 ON（> 饱和值 7）⇒ 8 个 OFF 必须**清得干净**（⛔ 不许留挂灯）──
        begin : q4_sat
            integer si;
            for (si = 0; si < 8; si = si + 1) send_off5(5'd16, KIND_ON);
            chk("Q4-g count saturates at 7 but the lamp is still on", guide_key[9] === 1'b1);
            for (si = 0; si < 8; si = si + 1) send_off5(5'd16, KIND_OFF);
            chk("Q4-h saturation SELF-HEALS: 8 ONs + 8 OFFs leaves every lamp dark (no hanging lamp)",
                guide_key === {AXIS_N{1'b0}});
        end

        // ── 收尾 ────────────────────────────────────────────────────────────
        if (errors == 0) begin
            $display("PASS: tb_guide_lamp (%0d checks)", checks);
        end else begin
            $display("FAIL: tb_guide_lamp errors=%0d", errors);
        end
        $finish;
    end

endmodule
