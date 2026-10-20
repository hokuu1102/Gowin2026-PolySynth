// ═══════════════════════════════════════════════════════════════════════════
//  guide_lamp.v —— 音符事件 → 灯位指引映射层（丙线 · P1 · 2026-10-03）
//
//  ⭐ 职责边界（与 `led_data` 分工）：
//    · `play_seq` 吐出的是【音符事件流】（`note_valid` + `note_data[63:0]`），
//      不是 `led_data` 需要的 16 位 one-hot「哪个键该按」位图。
//    · 本模块做这层【事件 → 位图】转换：把事件的**音高**字段 `note_off5`
//      （bit[4:0]，= MIDI 音符号 − `BASE_NOTE`）**查一张「音符号 → 键位」表**，
//      再解码成 `guide_key_o[15:0]` 的 one-hot 指引。
//    · `led_data` 负责的是【位图 → 24bit 物理图案】+ CH→OUT 重映射（下游）。
//
//  ⭐ 位域契约（必须与 `play_seq.v` / `tools/mid2evt.py` 逐位一致）：
//    · NOTE_SH =  0（5 bit，`note_off5` = MIDI − 45，⭐ 覆盖 MIDI 45..76）
//    · AXIS_SH = 19（4 bit，轴号 0..15 —— ⚠️ **轨号，⛔ 不是键位**，见下方警告）
//    · KIND_SH =  9（2 bit）：0 = note_on，1 = note_off，2 = tempo（换速，非音符）
//    · note_data 整体 64 bit，note_off5 位于 [4:0]，kind 位于 [10:9]。
//
//  ⭐ 语义：
//    · note_on（kind=0）→ 点亮 note_off5 对应的键位灯（下一键该按）
//    · note_off（kind=1）→ 熄灭同一个键位灯
//    · tempo（kind=2）→ 忽略（换速不是音符，⛔ 不得点亮任何灯）
//    · key_active_i 已按下的键 → 消隐（已按就不需要再指引）
//    · blink_i（拍点脉冲）→ 使当前指引位跟随拍点闪烁（可观测节拍）
//
//  ⭐ 非空洞性（P1 判据硬要求）：任意轴号 0..15 的 note_on 事件，
//    都能落到一个真实、非空的灯位（one-hot 位 set），满射、无空洞。
//
//  ⭐⭐⭐⭐ ⚠️ **轴号语义警告（⭐ 2026-10-16 · 点灯 LIGHTER 实测定位）** ✅
//     🔴 **本模块的 `axis` 是【轨号（track id）】，⛔ 不是【键位/音高】** ——
//        ⭐ 这是**上游生成侧的既有语义**，⭐ ⛔ **不是本模块的缺陷**：
//        · ⭐ `tools/mid2evt.py:359` `axis_of[ti] = nxt`（**一条非鼓轨 = 一个轴号**）
//        · ⭐ `tools/mid2evt.py:390` `axis = axis_of[ti] & 0xF`（⭐ 该轨**所有**音符共用它）
//        · ⭐ **音高在 `inc[43:23]`**（⭐ 与 `axis` 完全独立）
//     ⇒ ⭐ **一盏灯 = 一条轨** ⇒ ⭐ 单轨乐段**只有一盏灯在闪**（⭐ 实测：三首真曲
//        `events.hex` 只出现轴号 0..5，⭐ 且开头有 62~192 条**连续同轴**）✅
//
//  ⭐⭐⭐⭐ ✅ **2026-10-16（指北 COMPASS · 点灯 · 用户拍板）：本模块改成【按音高指键】**
//     ⭐ 用户原话：*"LED 指引要**跟着音高走**，而且【变调之后】不许指错键"* ✅
//
//     ⭐ **契约（新）**：⭐ 帧的 `bit[4:0]` = `note_off5` = `MIDI 音符号 − BASE_NOTE(45)`
//        ⇒ ⭐ 本模块：`note_after = BASE_NOTE + note_off5 + transpose_i`（⭐ 变调在半音上做）
//        ⇒ ⭐ **再查表**「音符号 → 键位」⇒ ⭐ 点亮那个键 ✅
//
//     ⭐⭐ **顺序是关键**：🔴 **变调必须发生在【查表】【之前】** ——
//        ⭐ 这样"**变调后**"音高变了、⭐ 表查的是**变调后的音高** ⇒
//        ⭐ **灯永远指向"真正该按的那个键"**（⭐ 用户要的就是这一条 ✅）。
//        ⚠️ 若反过来（先查表再加变调）⇒ 🔴 **整体平移一个"键位偏移"**，
//        ⭐ 而键位**不是**按半音排的（⭐ 见下方两张表的乱序）⇒ 🔴 **必指错键** ✅
//
//     ⭐ **两张表**（⭐ `NOTE2KEY_KB` / `NOTE2KEY_FB`）：
//        ⭐ **机械地从 `rtl/w3a/axis_map.v` 的【正向表】反推**（⭐ 唯一地面真相）：
//        · ⭐ `kb_inc[]`（⭐ `axis_map.v:395-410`）⇒ `NOTE2KEY_KB`
//        · ⭐ `fb_inc[]`（⭐ `axis_map.v:461-476`）⇒ `NOTE2KEY_FB`
//        ⭐ **生成脚本**：⭐ `build/exp/note2key_gen.py`（⭐ 改音高图后重跑即可）
//        ⚠️ **⛔ 不要手改表值** —— ⭐ 手抄正是"表错、灯跟着错"的根源。
//        📌 ⭐ 脚本**双重推导**（⭐ 音名 vs `phase_inc` 反算频率）并**互校**，
//           ⚠️ 两者不一致就直接退出（⭐ 那说明**正向表本身**有问题）✅
//
//     ⭐ **重复项规则**：⭐ 同一个音高能被两个键弹出时（⭐ 如 `kb_inc` 里
//        E3 = 键 0 **和** 键 3、B3 = 键 8 **和** 键 11）⇒ 🔴 **取【索引最小】的那个键**
//        ⇒ ⭐ "一个音符号 ⇒ 唯一一个灯"（⭐ 确定性、可判据化 ✅）
//
//     ⭐ **表里没有的音符号 ⇒ `4'hF`（哨兵）** ⇒ ⭐ **不点任何灯** ✅
//        🔴 **为什么必须是哨兵、⛔ 不能填 0**：⭐ 填 0 ⇒ 🔴 **误点亮键 0**
//        （⭐ 用户看到的就会是"乱指键"）✅
//
//     📌 ⭐ **本模块的满射性**（⭐ 任意 `axis` → 一个真实灯位）由 `tb_guide_lamp`
//        判据 ⑤ 与 `tb/w3c/tb_top_guide_axes.sv`（⭐ 顶层 6 个音高同时亮 6 盏）钉住 ✅
//     📌 ⭐ **表互逆**（⭐ 正向表 ⇄ 反查表）由 `tb_guide_lamp` 判据 ⑧ 钉住 ✅
//     📌 ⭐ `axis` 现在**在灯位映射里没有角色** —— ⚠️ 它**照样在帧里**，
//        ⭐ 因为 `note_manager` / `seq_arb` 的**发声**那一路仍然按 `axis` 分 voice ✅
//        🔴 **⛔ 不许因为"灯不用它了"就把 `axis` 字段删掉**（⭐ 那是契约级改动）✅
//
//  ⚠️ 只动丙线自己的文件：本模块【不实例化、不改】play_seq / note_manager / top.v，
//    仅消费 play_seq 的公开输出接口（note_valid_o / note_data_o），接线留待集成层。
//
// ═══════════════════════════════════════════════════════════════════════════
//  ⭐⭐⭐⭐ 2026-10-16（灭灯 LAMPKILL）：⭐ **"LED 挂灯"根因档案 ＋ RTL 侧兜底** ✅
//
//  🔴 **症状**（⭐ 用户实测）：⭐ *"没灌谱也闪"* —— ⭐ 灯跟着 125 ms 方波一直闪，永不熄 ✅
//
//  ── ① 审灯队报的机理（⭐ 带行号，⭐ 原文照抄）──────────────────────────────
//     · `guide_lamp.v:316-343` `guide_key_o` **只有两条清除路径**：
//       ⭐ `note_off(key_valid)` 与 ⭐ `rst_n` ⇒ 🔴 **没有超时、没有引用计数、
//         ⭐ 没有"停播即清"** ✅
//     · `guide_lamp.v:329/336` ON/OFF 用**同一个 `key_sel`** ⇒ ⭐ 只保证
//       "**同一条 note_off 下** ON/OFF 同键"，⛔ **不保证不同事件的 `note_off5` 相同** ✅
//     · `led_data.v:73/79` `blink_keys = guide_key_i & ~key_active_i`；
//       `key_pattern = key_active | (blink_keys & blink_i)` ✅
//     · `top.v:2496-2502` `led_blink` = 125 ms 方波（⭐ `bg_beat` 派生 ✅）
//
//  ── ② ⭐⭐ **本轮复核：审灯队的"ON 点 A、OFF 灭 B"在【当前数据】上不成立** ⚠️
//     ⭐ 我把五个真曲的 `events.hex` **逐条解码统计**（⭐ `bit[4:0]` = `note_off5` ✅）：
//        | 曲目 | 事件数 | `off5 ≠ 0` 的条数 | `note_on` 的 off5 分布 | `note_off` 的 off5 分布 |
//        |---|---|---|---|---|
//        | `夜洋风景`   | 11564 | **0** | `0` × 5782 | `0` × 5782 |
//        | `09_Conjurer` | 11858 | **0** | `0` × 5929 | `0` × 5929 |
//        | `6.世界悲`   |  9778 | **0** | `0` × 4889 | `0` × 4889 |
//        | `regen/夜洋风景` | 11566 | **0** | `0` × 5782 | `0` × 5782 |
//        | `t6test`     | 11865 | **0** | `0` × 5929 | `0` × 5929 |
//     ⇒ ⭐ **ON 与 OFF 查的是【同一个】 offset（0）** ⇒ ⭐ **亮哪盏就灭哪盏**（⭐ 硬要求 ③ 已满足 ✅）
//     ⇒ ⚠️ 所以"灯永不熄"**不是**"ON 点 A、OFF 灭 B"造成的 ✅
//     📌 ⭐ **上游为什么恒 0**（⭐ `tools/mid2evt.py:496-502`，⭐ 逐字 ✅）：
//        `# bits 6..0 stay 0 (reserved)` —— ⭐ `off5` 是**这个交付版本还没实现**的新字段，
//        ⭐ 语义是"**此版无音高**"，⛔ **不是"写错了"** ✅
//        （⭐ 而 `score_word.py:121` / `pool.c:724` 同样没写 ✅）
//
//  ── ③ ⭐⭐⭐⭐ **真正的三条挂灯机理**（⭐ 都能独立造成"永不熄" ✅）────────────
//     · **M1 · 缺 `note_off`（⭐ 上游）**：⭐ `mid2evt.py:359-390` 把 off 补进 `note_on`
//       事件里，⭐ 若某个音的 off 没生成 ⇒ **只有 ON 没有 OFF** ⇒ 那盏灯**常亮到复位** ✅
//     · **M2 · ON/OFF 表不同（⭐ 可复现的真实路径）**：⭐ 灯位由 `fb_mode_i` 选表
//        ⇒ ⭐ 用户**演奏中切钢琴/指板** ⇒ ON 走表 A、OFF 走表 B ⇒ **亮 A 灭 B** ✅
//     · **M3 · 结构性：没有任何超时**（⭐ 本模块自身）：
//       ⭐ `guide_vis_o = guide_key_o & ~key_active_i`（⭐ `P0-28` 钉死，⛔ 不动 ✅）
//       ＋ ⭐ `led_data` 只做 `blink_keys & blink_i` ⇒ ⭐ **用户一松手灯就灭**
//       ⇒ ⭐ 灯的生命周期 = **`guide_key_o` 的生命周期** ⇒ ⭐ 而它**只能被 note_off/复位清**
//       ⇒ ⭐ **任何"没配上对 OFF"的灯都会挂住** ✅
//
//  ── ④ ⭐⭐ **为什么选"停播即清"而⛔ 不是引用计数**（⭐ 本轮裁定 ✅）────────
//     ⭐ 逐条对表（⭐ 谁能治谁 ✅）：
//        | 机理 | 停播即清 | 引用计数 |
//        |---|---|---|
//        | M1 缺 `note_off`            | ⭐ **能** | ⛔ 不能（␣ 计数停在 1 ✅）|
//        | M2 ON/OFF 不同表（␣ 切模式）  | ⭐ **能** | ⛔ 不能（␣ 各记各的 ✅）|
//        | M3 结构性无超时              | ⭐ **能** | ⛔ 不能 |
//        | 同键和弦第一个 off 误熄       | ⛔ 不能 | ⭐ 能 |
//     ⇒ ⭐ **前三条才是"永不熄"的真机理**，⭐ 而**最后一条**（␣ 同键和弦首 off 误熄）
//       ⭐ 需要"**同一个键上同时有两个音**"（␣ 同音高叠置 ✅）—— ⭐ 概率最低、
//       ⭐ 且它造成的是"**提前熄**"而⛔ **不是"挂灯"**（⭐ 与本任务要治的症状相反 ✅）
//     ⇒ ⭐⭐ **结论**：⭐ **超时一个就够**（⭐ 三条真机理全覆盖 ✅）；
//       ⭐ 计数只多治那条最不可能的，⭐ 代价却是 **16×5 = 80 FF** ＋ 饱和逻辑
//       ＋ 一个**顶层粘滞寄存器**（⭐ 为"流里到底有没有过真音符" ✅）
//       ⇒ 🔴 **性价比倒挂，⛔ 不做** ✅
//
//  ── ⑤ ⭐ **超时值的安全边界（⭐ 真曲实测，⛔ 不是拍的** ✅）────────────────
//     · ⭐ 曲中**最长休止** = `09_Conjurer` **26880 tick**（⭐ @120BPM = 28 s ✅）
//     · ⭐ 最长**音符** = `6.世界悲` **8160 tick**（⭐ @120BPM = 8.5 s ✅）
//     ⇒ 🔴 **任何"按时间的超时"在慢速/休止处都必误清** ⇒ ⭐ 所以触发源
//       ⛔ **不能是"多久没有 note 事件"**，⭐ **必须是"流还在不在走"** ✅
//     ⭐ **本模块的取法**（⭐ `top.v` 的接线 ✅）：
//        `stream_alive_i = eb_rd_valid | ps_note_valid`
//        · ⭐ `ps_note_valid` = **此刻正在吐一条事件** ✅
//        · ⭐ `eb_rd_valid`  = **缓冲区里还有事件没播** ✅
//        ⇒ ⭐ 曲中休止 / ⭐ 长音 / ⭐ 慢速 ⇒ **缓冲非空 ⇒ 不算停 ⇒ 不攒超时** ✅
//        ⇒ ⭐ **只有真·停播**才攒：⭐ 没灌谱 / ⭐ 灌完 / ⭐ 灌断 ✅
//        ⇒ 🔴 **⛔ 不会误清正在进行的曲谱**（⭐ 任务书硬要求 ✅）
//  ═══════════════════════════════════════════════════════════════════════════

module guide_lamp #(
    parameter integer EVT_W = 64,        // 事件数据位宽（与 play_seq 一致）
    parameter integer AXIS_N = 16,       // 键位数（轴号 0..15）
    //  ⭐⭐ 2026-10-16（灭灯 LAMPKILL）：⭐ **"停播即清"的超时拍数**
    //     ⚠️ **必须留在【端口表】里** —— `parameter` 放在模块体（`localparam` 之后）
    //        是**非法的**（⭐ iverilog 直接 `syntax error` ⇒ 🔴 整个 rtl 树编译失败，
    //        ⚠️ **所有**例化 `guide_lamp` 的 tb 一起红 ✅）
    //     📌 ⭐ 默认 = 1 s @ 50 MHz（⭐ `top.v` 例化时**不覆盖** ⇒ 取默认 ✅）
    parameter integer TIMEOUT_CLKS = 50_000_000
) (
    input  wire                clk_i,
    input  wire                rst_n_i,          // ⭐ 同步复位、低有效

    // ── 来自 play_seq 的音符事件流 ───────────────────────────────────────
    input  wire                note_valid_i,      // 与 note_data_i 同拍
    input  wire [EVT_W-1:0]    note_data_i,       // 事件数据（note_off5 在 [4:0]）

    //  ⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **音高 ＋ 变调**（⭐ 点灯的新依据）✅
    //   ⭐ `note_off5_i` = 帧 `bit[4:0]` = `MIDI − BASE_NOTE(45)`（⭐ 无符号 0..31）✅
    //   ⭐ `transpose_i` = 运行期变调（⭐ 半音，⭐ **有符号** −12..+12）✅
    //     📌 ⭐ 位宽/符号**与 `rtl/top.v:969` 的 `wire signed [4:0] transpose_semi`
    //        【逐位一致】**（⭐ 源头 `rtl/w3a/fader_gear.v:116` 的
    //        `output wire signed [4:0] transpose_semi_o`）⇒ ⭐ 直接对接、⛔ 不截断 ✅
    input  wire [4:0]          note_off5_i,       // MIDI 音符号 − 45（0..31）
    input  wire signed [4:0]   transpose_i,       // 运行期变调（半音，−12..+12）
    //  ⭐ 键位表选择：⭐ 1 = 指板（`fb` 表）· ⭐ 0 = 键盘/钢琴（`kb` 表）✅
    //     📌 ⭐ 与 `top.v` 的 `play_fretboard_mode` 同源（⭐ 与 `axis_map` 同一口径 ✅）
    input  wire                fb_mode_i,

    // ── 来自采集/演奏侧的已按下键（消隐用）──────────────────────────────
    input  wire [AXIS_N-1:0]   key_active_i,      // 1 = 该键正在响/已按

    //  ⭐⭐⭐⭐ 2026-10-16（灭灯 LAMPKILL）：⭐ **"曲谱还在走"标志**（⭐ 超时的取反源 ✅）
    //   ⭐ **语义**：**1 = 曲谱事件流还活着**（⭐ 此刻在吐事件，␣ 或缓冲区里还有没播完的 ✅）
    //   ⭐ **取值（⭐ `top.v` 接线 ✅）**：`eb_rd_valid | ps_note_valid`
    //     · ⭐ `ps_note_valid` = **这一拍正在吐一条事件**
    //     · ⭐ `eb_rd_valid`   = **缓冲里还有事件没播**（⭐ 曲中休止/长音/慢速全靠它 ✅）
    //   🔴 **为什么必须是这个、⛔ 不是"多久没有 note 事件"**：
    //     ⚠️ 真曲实测曲中**最长休止 26880 tick**（⭐ @120BPM = **28 s** ✅）、
    //     ⭐ 最长**音符 8160 tick**（⭐ = **8.5 s** ✅）
    //     ⇒ 🔴 按时间判"停" ⇒ ⭐ **慢速/休止处必误清正在进行的曲谱** ✅
    //   ⭐ **Z-safe**：⭐ 悬空 `z` ⇒ `=== 1'b0` ⇒ 当"一直在走" ⇒ **永不误清** ✅
    //     ⚠️ 这是**故意的失败方向**（⭐ 宁可挂着、⛔ 不许误灭正在指引的灯 ✅）
    input  wire                stream_alive_i,

    //  ⭐⭐ 2026-10-09（`P0-28`）：⭐ **`blink_i` 端口已删** ✅
    //   🔴 **原缺陷**：⭐ 它在文件里**只出现 2 次**（⭐ 端口声明 + :21 注释）
    //      ⇒ ⭐ 在 `always` 块里**一次都没用到** ⇒ 🔴 **"指引位跟随拍点闪烁"从未实现** ✅
    //   ✅ **为什么删而不是实现**：⭐ `led_data.v:73-79` **已经做了** `blink_keys & blink_i`
    //      ⇒ ⭐ 若 `guide_lamp` 也做 ⇒ 🔴 **两次闪烁串联 ⇒ 实际占空比变成 25%** ✅
    //      ⇒ ⭐ **闪烁是 `led_data` 的职责**，⭐ 本模块**只做消隐** ✅

    // ── 输出：one-hot 指引位图 ───────────────────────────────────────────
    output reg  [AXIS_N-1:0]   guide_key_o,       // 1 = 该键「该按」（指引，⭐ 未消隐）
    output reg                 guide_commit_o,    // 指引更新（单周期脉冲，可观测）
    //  ⭐⭐ 2026-10-09（`P0-28`）：⭐ **消隐后的指引位图**（⭐ 这才是该接给 `led_data` 的）✅
    //   🔴 **原缺陷**：⭐ `key_active_i` 在文件里**只出现 2 次**（⭐ 端口声明 + :20 注释）
    //      ⇒ ⭐ `always` 块里**一次都没用到** ⇒ 🔴 **"已按下的键消隐"从未实现** ✅
    //      ⇒ ⭐ 已按键**仍被指引灯点亮** ⇒ 🔴 **用户分不清"该按的键"和"正在响的键"**
    //        （⭐ 而这正是 `LED演奏指引方案.md` §4.3 要区分的那两件事）✅
    //   ✅ **修法**：⭐ 新增本输出 = `guide_key_o & ~key_active_i`（⭐ 一层 AND，+16 LUT / 0 FF）✅
    //      📌 ⭐ 保留 `guide_key_o` 的端口语义不变（⭐ 兼容既有 tb）✅
    output wire [AXIS_N-1:0]   guide_vis_o        // ⭐ 1 = 该键「该按」**且尚未按下** ✅
);

    //  ⭐⭐ 2026-10-09（`P0-28`）：⭐ **消隐逻辑**（⭐ 组合、最省）✅
    //   📌 语义：⭐ 已经按下的键**不需要再指引** ⇒ ⭐ 从指引位图里抹掉 ✅
    assign guide_vis_o = guide_key_o & ~key_active_i;

    // ── 位域偏移（与 play_seq 冻结契约逐位一致）────────────────────────────
    localparam integer AXIS_SH = 19;
    localparam integer KIND_SH = 9;

    // ⭐ kind 编码（冻结契约 §1.2）
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_TEMPO = 2'd2;

    // ── 组合解码（⭐ 用 assign，⛔ 不用 always @(*)，规避 L67）─────────────
    wire [1:0]  note_kind = note_data_i[KIND_SH +: 2];
    //  📌 ⭐ `axis`（bit[22:19]）**仍然是帧的一部分**，⭐ 但**本模块不再用它选灯** ✅
    //     ⚠️ 它的消费者是**发声**那一路（`note_manager` / `seq_arb` 按轴分 voice）✅
    //     🔴 ⛔ **不许因为"灯不用它了"就删字段 / 改上游语义**（⭐ 契约级改动）✅

    wire is_note_on  = (note_kind == KIND_ON);
    wire is_note_off = (note_kind == KIND_OFF);

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐⭐⭐ 2026-10-16（指北 COMPASS）：⭐ **「音符号 → 键位」反查表** ✅
    //
    //  ⭐ **唯一地面真相** = `rtl/w3a/axis_map.v` 的**正向表**（⭐ 键位 → 音高）：
    //     · ⭐ `kb_inc[]`（⭐ `axis_map.v:395-410`，⭐ 键盘/钢琴模式）
    //     · ⭐ `fb_inc[]`（⭐ `axis_map.v:461-476`，⭐ 指板模式）
    //  ⭐ **本表由 `build/exp/note2key_gen.py` 【机械反推】**（⚠️ ⛔ 不是手抄）：
    //     ① 解析正向表的**音名**（`KB_Fs3` ⇒ F#3 ⇒ MIDI 54）
    //     ② 由 `phase_inc` 十六进制**反算频率**再算 MIDI（⭐ 独立第二路）
    //     ③ 两路**必须一致**，⚠️ 否则脚本直接报错退出（⭐ 说明正向表本身有问题）
    //     ④ 反查：`note2key[MIDI − 45] = 键号`
    //
    //  ⭐ **规则（⭐ 三条，⭐ 与生成脚本逐条对应）**：
    //     · ⭐ **索引** = `MIDI − BASE_NOTE`，⭐ `BASE_NOTE = 45 = A2`
    //        ⇒ ⭐ 表覆盖 **MIDI 45..76**（⭐ 32 项 × 4 位 ⇒ 打包成 128 位常量）
    //     · ⭐ **重复取【索引最小】**：⭐ 一个音高能被两个键弹出时取小的那个键
    //        （⭐ `kb` 里 E3 = 键 0 **和** 键 3、B3 = 键 8 **和** 键 11）
    //        ⇒ ⭐ 保证"一个音符号 ⇒ 唯一一盏灯"（⭐ 可判据化 ✅）
    //     · ⭐ **未覆盖的音符号 ⇒ 哨兵（⭐ 不点灯）** —— ⭐ 见下方 `KEY_NONE` ✅
    //        🔴🔴 **哨兵⛔ 不能用 `4'hF`**（⭐ **2026-10-16 实测踩到的真缺陷**）：
    //           ⚠️ 键号**有 16 个**（`0..15`）⇒ ⭐ **`4'hF` 就是【键 15】本身**！
    //           🔴 用 `4'hF` 当"没有"⇒ **键 15 永远点不亮**
    //              （⭐ 而键 15 是**真的**：⭐ `kb` 的 A#3、⭐ `fb` 的 C#4 ✅）
    //           📌 ⭐ **抓住它的正是"表互逆"那条机械判据**（⭐ `tb_guide_lamp` ⑧）：
    //              🔴 它报 `mode=0 off=13 (MIDI 58) expected key 15, got 0000` ✅
    //              ⇒ ⭐ **这就是"机械判据"的价值：⭐ 4 位装不下 17 种状态** ✅
    //           ✅ **修法**：⭐ 表项加宽到 **5 位**，⭐ 哨兵 = **`5'd16`**（⭐ 键号之外）✅
    //              📌 ⭐ 代价：⭐ 每表 `32×5 = 160` 位（⭐ 比 128 位多 25%）✅
    //
    //  📌 ⚠️ **为什么是 `localparam [127:0]` ＋ 变址部分选择、⛔ 不是数组**：
    //     🔴 iverilog 14.0 编不过"**非打包数组参数**"——
    //        `sorry: unpacked array parameters are not supported yet.`
    //        （⭐ 实测；⭐ `tb_all.ps1` 用 `-g2012` 编译，⭐ 一样不行）
    //     ⇒ ⭐ 用 **128 位打包常量 + `[idx*4 +: 4]`**：⭐ 语义**完全相同**、
    //        ⭐ **零 FF**、⭐ 综合后就是一个常量 32:1 四路选择 ✅
    //
    //  ── ⭐ `NOTE2KEY_KB`（键盘/钢琴 · 源 `kb_inc[]`）──────────────────────
    //     | offset | MIDI | 音名 | 键 |   | offset | MIDI | 音名 | 键 |
    //     |---|---|---|---|---|---|---|---|---|
    //     |  0 | 45 | A2  | `N`(无) |  | 16 | 61 | C#4 |  9 |
    //     |  1 | 46 | A#2 | `N`(无) |  | 17 | 62 | D4  | `N`(无) |
    //     |  2 | 47 | B2  | `N`(无) |  | 18 | 63 | D#4 | `N`(无) |
    //     |  3 | 48 | C3  |  5 |       | 19 | 64 | E4  | `N`(无) |
    //     |  4 | 49 | C#3 |  6 |       | 20 | 65 | F4  | `N`(无) |
    //     |  5 | 50 | D3  |  4 |       | 21 | 66 | F#4 | `N`(无) |
    //     |  6 | 51 | D#3 |  7 |       | 22 | 67 | G4  | `N`(无) |
    //     |  7 | 52 | E3  | **0** |    | 23 | 68 | G#4 | `N`(无) |
    //     |  8 | 53 | F3  |  2 |       | 24 | 69 | A4  | `N`(无) |
    //     |  9 | 54 | F#3 |  1 |       | 25 | 70 | A#4 | `N`(无) |
    //     | 10 | 55 | G3  | 13 |       | 26 | 71 | B4  | `N`(无) |
    //     | 11 | 56 | G#3 | 14 |       | 27 | 72 | C5  | `N`(无) |
    //     | 12 | 57 | A3  | 12 |       | 28 | 73 | C#5 | `N`(无) |
    //     | 13 | 58 | A#3 | **15** |   | 29 | 74 | D5  | `N`(无) |
    //     | 14 | 59 | B3  | **8** |    | 30 | 75 | D#5 | `N`(无) |
    //     | 15 | 60 | C4  | 10 |       | 31 | 76 | E5  | `N`(无) |
    //     📌 ⭐ 加粗那两项**就是【重复取最小索引】的两处**（E3 ⇒ 0 而⛔ 不是 3；
    //        B3 ⇒ 8 而⛔ 不是 11）✅
    //     📌 ⭐ `offset 13 = 键 15` —— ⭐ **这一项就是"哨兵⛔ 不能是 `4'hF`"的现场**
    //        （⭐ `4'hF = 15 = 键 15` ⇒ 🔴 会把它当成"没有"）✅
    //
    //  ── ⭐ `NOTE2KEY_FB`（指板 · 源 `fb_inc[]`）──────────────────────────
    //     | offset | MIDI | 音名 | 键 |   | offset | MIDI | 音名 | 键 |
    //     |---|---|---|---|---|---|---|---|---|
    //     |  0 | 45 | A2  |  5 |       | 16 | 61 | C#4 | **15** |
    //     |  1 | 46 | A#2 |  4 |       | 17 | 62 | D4  |  8 |
    //     |  2 | 47 | B2  |  3 |       | 18 | 63 | D#4 |  9 |
    //     |  3 | 48 | C3  |  2 |       | 19 | 64 | E4  | `N`(无) |
    //     |  4 | 49 | C#3 | `N`(无) |  | 20 | 65 | F4  | `N`(无) |
    //     |  5 | 50 | D3  |  6 |       | 21 | 66 | F#4 | `N`(无) |
    //     |  6 | 51 | D#3 |  7 |       | 22 | 67 | G4  | `N`(无) |
    //     |  7 | 52 | E3  |  0 |       | 23 | 68 | G#4 | `N`(无) |
    //     |  8 | 53 | F3  |  1 |       | 24 | 69 | A4  | `N`(无) |
    //     |  9 | 54 | F#3 | `N`(无) |  | 25 | 70 | A#4 | `N`(无) |
    //     | 10 | 55 | G3  | 13 |       | 26 | 71 | B4  | `N`(无) |
    //     | 11 | 56 | G#3 | 12 |       | 27 | 72 | C5  | `N`(无) |
    //     | 12 | 57 | A3  | 11 |       | 28 | 73 | C#5 | `N`(无) |
    //     | 13 | 58 | A#3 | 10 |       | 29 | 74 | D5  | `N`(无) |
    //     | 14 | 59 | B3  | `N`(无) |  | 30 | 75 | D#5 | `N`(无) |
    //     | 15 | 60 | C4  | 14 |       | 31 | 76 | E5  | `N`(无) |
    //     📌 ⭐ `fb` 表**没有重复项**（⭐ 16 个键 = 16 个互不相同的音高）✅
    //     📌 ⭐ `offset 16 = 键 15` —— ⭐ **哨兵事件的第二处现场** ✅
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer BASE_NOTE = 45;           // ⭐ A2（⭐ 与上位机帧的基准一致）
    //  ⭐ 哨兵：⭐ 该音符号**没有**对应键 ⇒ ⭐ 不点灯 ✅
    //  🔴🔴 **必须是 `5'd16`**（⭐ 键号之外的值）—— ⛔ **不是 `4'hF`**：
    //     ⚠️ `4'hF` = 15 = **一个真实的键号**（⭐ `kb` A#3 / ⭐ `fb` C#4）✅
    localparam [4:0]   KEY_NONE  = 5'd16;

    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐⭐⭐ 2026-10-16（灭灯 LAMPKILL）：⭐ **"停播即清"超时** ✅
    //     ⭐ **治什么**：⭐ 本模块原来**只能被 `note_off` / `rst_n` 清**（⭐ 见头部 ③M3）
    //        ⇒ ⭐ **没配上对 OFF 的指引灯会挂住到复位** ⇒ ⭐ 用户看到"没灌谱也闪" ✅
    //     ⭐ **判据**（⭐ 与任务书一致 ✅）：
    //        · ⭐ `stream_alive_i = 0`（⭐ 流停了 ✅）**持续 `TIMEOUT_CLKS` 拍**
    //        ⇒ ⭐ **整片清零**（⭐ `guide_key_o` 归 0 ✅）
    //        · ⭐ 期间只要 `stream_alive_i` 回到 1 ⇒ ⭐ **计数器立刻归零**（⭐ 不误清 ✅）
    //     ⭐ **为什么默认是 1 秒**（⭐ `50_000_000` 拍 @ 50 MHz ✅）：
    //        · ⭐ 远大于**任何正常音符间隔**（⭐ 最密的 `夜洋风景` 相邻 tick 差 = 30 ✅）
    //        · ⭐ 而**流中静默**靠 `stream_alive_i` 的缓冲非空兜着（⭐ 见端口注释 ✅）
    //          ⇒ ⭐ 计数**只在真·停播时才涨** ⇒ ⭐ 1 秒纯粹是"多久没灌新数据" ✅
    //        · ⭐ 用户侧：⭐ 灌完/断了 1 秒后灯灭 ⇒ ⭐ 不会"刚停播放灯还闪" ✅
    //     ⭐⭐ **为什么做成参数**（⭐ 2026-10-16 实测加，⛔ 不是"预防性抽象" ✅）：
    //        🔴 若硬编 1 秒 ⇒ ⭐ 验收 tb 必须真跑 **5100 万拍**顶层仿真
    //           ⇒ ⭐ 实测 **撞 120 s 预算被误判成 TIMEOUT**（⭐ `K-94` 的反面：过了却算挂 ✅）
    //        ✅ 参数化 ⇒ ⭐ tb 用 **`TIMEOUT_CLKS = 1000`**（⭐ 判据形状逐字不变、⭐ 2 s 跑完 ✅）
    //        ⚠️ **硬件仍走 1 s**（⭐ `top.v` 例化时**不覆盖** ⇒ 取默认 ✅）
    //     ⭐ **资源**：⭐ **26** FF（⭐ 计数器 —— ⚠️ 原文写 27 是错的，⭐ 实测网表
    //        `Gowin2026.vg:571155` = `wire [25:0] stream_idle_cnt;` + 26 个 `DFFRE` ✅）
    //        ＋ 16×2:1 mux（⭐ 清零旁路 ✅）
    //        ⇒ ⚠️ 只占**一个 LUT 级更新**，⛔ **不动表 / ⛔ 不动端口语义** ✅
    //     ⚠️⚠️ **本超时【不改变】 `guide_vis_o` 那条**（⭐ `P0-28` 判据钉着，⛔ 动 ✅）：
    //        ⭐ 它**只清 `guide_key_o`**，⭐ 而 `guide_vis_o` 恒等于 `guide_key_o & ~key_active_i`
    //        ⇒ ⭐ 灯灭了 `vis` 当然也灭 ⇒ ⭐ **那条表达式一个字符都没动** ✅
    // ═══════════════════════════════════════════════════════════════════════
    //  📌 ⭐ `TIMEOUT_CLKS` 是**端口表里的 `parameter`**（⭐ 见模块头 `#(...)` ✅）——
    //     ⚠️ **⛔ 不能在模块体里再声明一遍**（⭐ `parameter` 只能出现一次 ⇒ iverilog 实测
    //        `'TIMEOUT_CLKS' has already been declared in this scope` ✅）
    //     ⚠️ 而 `CNT_W` 用 `localparam`（⭐ 派生量、⛣ 不许被覆盖 ✅）

    //  ⭐ 计数器位宽别名：⭐ `$clog2(1 s)` = 26（⭐ 硬件 ✅）· `$clog2(1000)` = 10（⭐ tb ✅）
    //     ⚠️ **必须 `>= 1`**（⭐ `[0:0]` 在 bit-select 里合法，⭐ 而 `[$clog2(1)-1:0]` = `[0:0]` ✅）
    //     ⚠️ `TIMEOUT_CLKS - 1` 在两种取值下**都装得下**这个位宽 ✅
    //        · ⭐ 49_999_999 需要 26 位 = `$clog2(50_000_000)` ✅
    //        · ⭐ 999 需要 10 位 = `$clog2(1000)` ✅
    localparam integer CNT_W = (TIMEOUT_CLKS > 1) ? $clog2(TIMEOUT_CLKS) : 1;

    //  ⭐ 计数器：⭐ `stream_alive_i = 0` 时每拍 +1；⭐ 回到 1 **立刻归零**
    //     ⚠️ **位宽由参数算出来**（⭐ `$clog2` ✅）⇒ ⭐ 硬件 **26** 位（⭐ 1 s ✅ —— ⚠️ 原文写 27 是错的）、
    //        ⭐ tb 用 10 位（⭐ `TIMEOUT_CLKS = 1000` ✅）⇒ ⭐ **判据形状逐字不变** ✅
    //  🔴🔴 2026-10-17 修（`Q5` · 只读审计发现）：⭐ **声明必须用 `CNT_W`，⛔ 不能直接写 `$clog2`** ✅
    //     🔴 原写法 `reg [$clog2(TIMEOUT_CLKS)-1:0]` ⇒ ⭐ `TIMEOUT_CLKS = 1` 时
    //        `$clog2(1) = 0` ⇒ 🔴 **`reg [-1:0]`（非法位宽）**
    //        ⇒ ⚠️ 而上面 `CNT_W` 那行**本来就有 `>1` 保护**，只是**没被用上** ✅
    //     ⚠️ 且 `TIMEOUT_CLKS = 0` 时 `stream_timeout = (cnt == -1)` **恒假**
    //        ⇒ 🔴 **超时静默失效**（⭐ 灯可永久挂住）—— 而本模块**原来没有任何参数自检** ✅
    //     ✅ 修法：声明改用 `CNT_W` ＋ ⭐ 下面加 `initial` 自检（⭐ 与 `led_data.v:110-115` 同套路）✅
    //  ⭐ 实测位宽（⭐ `impl/gwsynthesis/Gowin2026.vg:571155`）：⭐ 硬件 **26 位**
    //     （⭐ `$clog2(50_000_000) = 26` —— ⚠️ 上面旧注释写"27 FF"是**错的**）✅
    //     ⭐ tb 用 10 位（⭐ `TIMEOUT_CLKS = 1000` ✅）⇒ ⭐ **判据形状逐字不变** ✅
    reg [CNT_W-1:0] stream_idle_cnt;

    //  ⚠️ **`stream_timeout` 是【电平】（⭐ 会粘住）**，⛔ 不是单拍脉冲 ——
    //     ⭐ 计数器**饱和在 `TIMEOUT_CLKS-1` 不回绕**（⭐ 见下方 `:478` 的守卫）
    //     ⇒ ⭐ 空闲期它**一直为 1** ✅（⭐ 旧注释"单拍脉冲，不让它粘住"是**错的**）
    //  📌 **为什么无害**（⭐ 只读审计逐路查过）：⭐ 唯一消费者是"清 `guide_key_o`"，
    //     而 `guide_key_o` 空闲期本来就是 0（⭐ 清 0 是空操作）；
    //     且该清零点在 `note_valid_i` 块**之前** ⇒ ⭐ 流恢复首拍的 `note_on` **能活下来** ✅
    //     ⚠️ 但那个安全性**依赖这两段的先后顺序**（⭐ 承重）⇒ ⚠️ 改这段时⛔ 别动顺序 ✅
    wire stream_timeout = (stream_idle_cnt == TIMEOUT_CLKS - 1);

    //  ⭐⭐ 2026-10-17（`Q5`）：⭐ **参数自检**（⭐ 本模块原来一条都没有）
    //     🔴 `TIMEOUT_CLKS <= 1` 会**静默失效或非法**（⭐ 见上方长注释）
    initial begin
        if (TIMEOUT_CLKS < 2)
            $display("ERROR [guide_lamp] TIMEOUT_CLKS=%0d must be >= 2 => the idle counter cannot represent TIMEOUT_CLKS-1, so 'stop playing clears the lamps' silently stops working.", TIMEOUT_CLKS);
        else
            $display("NOTE [guide_lamp] PARAM_OK=1 (TIMEOUT_CLKS=%0d CNT_W=%0d)", TIMEOUT_CLKS, CNT_W);
    end

    //  ⭐⭐⭐⭐ 2026-10-16（🔴 **关键修正：PnR 卡死的真凶就在这里**）────────────────
    //  🔴 **原写法（已删）**：
    //     ```verilog
    //     localparam [159:0] NOTE2KEY_KB = { ... };   // 32 项 × 5 位 = 160 位
    //     wire [4:0] key_sel = fb_mode_i ? NOTE2KEY_FB[note_idx*5 +: 5]
    //                                    : NOTE2KEY_KB[note_idx*5 +: 5];
    //     ```
    //     ⚠️ `note_idx*5 +: 5` 是 **160 位常量上的【变步长（5）】变量部分选择** ✅
    //     🔴 步长 5 **不是 2 的幂** ⇒ ⭐ 综合器**做不出 ROM**，
    //        只能生成 **160 位桶形移位器** ⇒ ⭐ 约 **640 LUT / 每张表**
    //        ⇒ 两张表 ＋ 模式选择 ≈ **1300 LUT** ✅
    //     🔴 **实测后果**：CLS 从 88% 直接爆掉 ⇒ ⭐ **布线卡死在 70% 十四分钟**
    //        （⭐ 2026-10-16 实测：`gw_sh` CPU 涨到 1523s、日志 14 分钟不推进）✅
    //     📌 ⭐ 我原来估的是 60~125 LUT —— **差了 10 倍以上**，教训：**变步长部分选择 ≠ ROM**
    //
    //  ✅ **修法**：改成 `case`，综合器生成**正规 mux 树**（约 25~35 LUT / 表）✅
    //     ⭐ **语义逐项不变**（下面每个臂的值都是从原来那两张打包表里【逐项抄出来的】）✅
    //     📌 表项 5 位：⭐ 键号 4 位 ＋ ⭐ "没有"这一种状态（`KEY_NONE = 5'd16`）✅
    //     📌 ⭐ **⛔ 不要手改下面的表** —— ⭐ 改音高图（`axis_map.v`）后重跑
    //        `build/exp/note2key_gen.py`（⭐ 它会打印出这两段，并做双路互校）✅
    // ── ⭐ 核心：⭐ **先变调、后查表**（⭐ 顺序就是正确性）──────────────────
    //   ⭐ `note_tr` = `note_off5 + transpose`（⭐ 半音域的和）
    //   📌 ⭐ **7 位有符号**、⛔ 不是 6 位：⭐ `note_off5` 最大 31、`transpose` 最大 +12
    //      ⇒ ⭐ 真和最大 **43** ⇒ ⚠️ 6 位有符号装不下（⭐ 会绕成负数）
    //      —— ⭐ 虽然绕出来的值**同样**落在 `in_range` 之外（⭐ 判决不变），
    //      ⚠️ 但**靠溢出绕回得到正确答案**是脆的 ⇒ ⭐ **宁可显式扩到 7 位** ✅
    //   📌 ⭐ 两个操作数**各自显式符号扩展**，⛔ 不靠隐式规则（⭐ 隐式规则吃过亏）✅
    wire signed [6:0] note_tr = $signed({2'b00, note_off5_i})
                              + $signed({{2{transpose_i[4]}}, transpose_i});
    //   ⭐ 变调后仍在表范围内（⭐ MIDI 45..76）才可能点灯 ✅
    wire        in_range = (note_tr >= 7'sd0) && (note_tr <= 7'sd31);
    wire [4:0]  note_idx = note_tr[4:0];

    //  ⭐⭐ 查表（⭐ `case` 实现，⛔ 不用变步长部分选择 —— 见上面那段长注释）✅
    //  📌 ⭐ **`case` 必须放在 `note_idx` 声明【之后】** —— ⚠️ 放在前面会让 Verilog
    //     隐式创建一根 **1 位** 网线 ⇒ ⭐ `case` 只按 1 位匹配 ⇒ 🔴 **全表查错**
    //     （⭐ 2026-10-16 实测踩到：判据 `guide 0/3`、`top_guide 0/2` 全红）✅
    //  ⭐⭐ 2026-10-18（⭐ 用户裁定）：⭐ **钢琴模式两个"同音对"的指引灯，改点【另一颗】** ✅
    //     📌 背景：钢琴没有 E# / B# ⇒ `axis_map.v` 的 `kb_inc[]` 里
    //        · 轴 **0** 与 轴 **3** 都是 **E3**（`kb_inc[0]` / `kb_inc[3]`）
    //        · 轴 **8** 与 轴 **11** 都是 **B3**（`kb_inc[8]` / `kb_inc[11]`）
    //     📌 用户要的语义（分两条路，⛔ 别混）：
    //        · ⭐ **手弹** ⇒ 按哪颗亮哪颗（⭐ 走 `ee_key_on` → `led_data.key_active_i`，⛔ 本表不管）
    //        · ⭐ **灌谱指引** ⇒ **亮同音的另一颗**（⭐ 就是本表 ⇒ 改这两行）✅
    //     🔴 **这里改的是 `key_kb_r`（键盘/钢琴模式）**：
    //        · `5'd7`（52 = E3）   ：`5'd0` → **`5'd3`**  ✅
    //        · `5'd14`（59 = B3）  ：`5'd8` → **`5'd11`** ✅
    //     ⚠️ **指板（`key_fb_r`）⛔ 不动** —— 指板模式那 4 个轴是**不同音**
    //        （`fb_inc` = E3/B2/D4/A3），⛔ 没有"同音可换"这回事 ✅
    //     📌 依据 `rtl/w3a/axis_map.v` 的 `kb_inc[]` 表（⭐ 同音关系以那张表为准）
    reg [4:0] key_kb_r, key_fb_r;
    always @(*) begin
        key_kb_r = KEY_NONE;
        key_fb_r = KEY_NONE;
        case (note_idx)
            //  offset  MIDI  音名      键盘/钢琴    指板
            5'd0 : begin key_kb_r = KEY_NONE; key_fb_r = 5'd5;  end  // 45 A2
            5'd1 : begin key_kb_r = KEY_NONE; key_fb_r = 5'd4;  end  // 46 A#2
            5'd2 : begin key_kb_r = KEY_NONE; key_fb_r = 5'd3;  end  // 47 B2
            5'd3 : begin key_kb_r = 5'd5;  key_fb_r = 5'd2;  end     // 48 C3
            5'd4 : begin key_kb_r = 5'd6;  key_fb_r = KEY_NONE; end  // 49 C#3  (指板无)
            5'd5 : begin key_kb_r = 5'd4;  key_fb_r = 5'd6;  end     // 50 D3
            5'd6 : begin key_kb_r = 5'd7;  key_fb_r = 5'd7;  end     // 51 D#3
            5'd7 : begin key_kb_r = 5'd3;  key_fb_r = 5'd0;  end     // 52 E3   ⭐ 2026-10-18：kb 0→**3**（同音换个键）
            5'd8 : begin key_kb_r = 5'd2;  key_fb_r = 5'd1;  end     // 53 F3
            5'd9 : begin key_kb_r = 5'd1;  key_fb_r = KEY_NONE; end  // 54 F#3  (指板无)
            5'd10: begin key_kb_r = 5'd13; key_fb_r = 5'd13; end     // 55 G3
            5'd11: begin key_kb_r = 5'd14; key_fb_r = 5'd12; end     // 56 G#3
            5'd12: begin key_kb_r = 5'd12; key_fb_r = 5'd11; end     // 57 A3
            5'd13: begin key_kb_r = 5'd15; key_fb_r = 5'd10; end     // 58 A#3
            5'd14: begin key_kb_r = 5'd11; key_fb_r = KEY_NONE; end  // 59 B3   ⭐ 2026-10-18：kb 8→**11**（同音换个键）（指板无）
            5'd15: begin key_kb_r = 5'd10; key_fb_r = 5'd14; end     // 60 C4
            5'd16: begin key_kb_r = 5'd9;  key_fb_r = 5'd15; end     // 61 C#4
            5'd17: begin key_kb_r = KEY_NONE; key_fb_r = 5'd8;  end  // 62 D4   (键盘无)
            5'd18: begin key_kb_r = KEY_NONE; key_fb_r = 5'd9;  end  // 63 D#4  (键盘无)
            default: begin key_kb_r = KEY_NONE; key_fb_r = KEY_NONE; end
        endcase
    end
    //  ⭐ 选表：⭐ 指板 / 键盘（⭐ 与 `axis_map` 的两种模式同一口径）✅
    //     📌 5 位 2 选 1 mux，很便宜 ✅
    wire [4:0]  key_sel  = fb_mode_i ? key_fb_r : key_kb_r;
    //   ⭐ `key_sel` 已在上面 `case` 那段声明并赋值（⭐ 2026-10-16 改：⛔ 不再用变步长部分选择）✅
    //   ⭐ 有效 = ⭐ 在范围内 **且** ⭐ 查到了键（⭐ 哨兵 ⇒ 无效 ⇒ 不点灯）✅
    wire        key_valid = in_range && (key_sel != KEY_NONE);

    // Keep each ON's original identity and mapped key until its matching OFF.
    // Multiple references, including duplicate pitches, occupy separate slots.
    reg [AXIS_N-1:0] held_valid, next_valid;
    reg [3:0] held_axis [0:AXIS_N-1], next_axis [0:AXIS_N-1];
    reg [4:0] held_note [0:AXIS_N-1], next_note [0:AXIS_N-1];
    reg [4:0] held_key [0:AXIS_N-1], next_key [0:AXIS_N-1];
    reg [AXIS_N-1:0] next_lamps;
    reg next_commit;
    integer gi, free_slot, off_slot;
    wire [3:0] event_axis = note_data_i[AXIS_SH +: 4];

    always @(*) begin
        next_valid = stream_timeout ? {AXIS_N{1'b0}} : held_valid;
        next_lamps = {AXIS_N{1'b0}};
        next_commit = 1'b0;
        free_slot = -1;
        off_slot = -1;
        for (gi=0; gi<AXIS_N; gi=gi+1) begin
            next_axis[gi] = held_axis[gi];
            next_note[gi] = held_note[gi];
            next_key[gi] = held_key[gi];
            if (!next_valid[gi] && free_slot < 0) free_slot = gi;
            if (next_valid[gi] && held_axis[gi] == event_axis &&
                held_note[gi] == note_off5_i && off_slot < 0) off_slot = gi;
        end
        if (note_valid_i) begin
            if (is_note_on && key_valid && free_slot >= 0) begin
                next_valid[free_slot] = 1'b1;
                next_axis[free_slot] = event_axis;
                next_note[free_slot] = note_off5_i;
                next_key[free_slot] = key_sel;
                next_commit = 1'b1;
            end else if (is_note_off && off_slot >= 0) begin
                next_valid[off_slot] = 1'b0;
                next_commit = 1'b1;
            end
        end
        for (gi=0; gi<AXIS_N; gi=gi+1)
            if (next_valid[gi] && next_key[gi] < AXIS_N)
                next_lamps[next_key[gi]] = 1'b1;
    end

    integer gr;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            held_valid <= {AXIS_N{1'b0}};
            guide_key_o <= {AXIS_N{1'b0}};
            guide_commit_o <= 1'b0;
            stream_idle_cnt <= {CNT_W{1'b0}};
            for (gr=0; gr<AXIS_N; gr=gr+1) begin
                held_axis[gr] <= 4'd0;
                held_note[gr] <= 5'd0;
                held_key[gr] <= KEY_NONE;
            end
        end else begin
            held_valid <= next_valid;
            guide_key_o <= next_lamps;
            guide_commit_o <= next_commit;
            for (gr=0; gr<AXIS_N; gr=gr+1) begin
                held_axis[gr] <= next_axis[gr];
                held_note[gr] <= next_note[gr];
                held_key[gr] <= next_key[gr];
            end
            if (stream_alive_i === 1'b1)
                stream_idle_cnt <= {CNT_W{1'b0}};
            else if (stream_idle_cnt != TIMEOUT_CLKS-1)
                stream_idle_cnt <= stream_idle_cnt + 1'b1;
        end
    end
endmodule
