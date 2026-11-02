`timescale 1ns/1ps
// ============================================================================
//  ctrl_key_map.v -- 控制板 16 键 -> 命令脉冲（与串口 calib_cmd 的输出 OR）
//
//  设计原则（见 files/20-代码/控制板16键功能映射-20261013.md）：
//    列 = 功能组，键号 idx = row*4 + col
//
//    idx  行,列   功能                        输出（与 calib_cmd 同名信号 OR）
//    ---  -----   --------------------------  --------------------------------
//     0   0,0     源 B 开关（交付档=鼓机开/关） met_req_o        （'B'）
//     1   0,1     音色循环                     timbre_req_o     （'I'）
//     2   0,2     滑音开关                     slide_req_o      （'W'）
//     3   0,3     显示切换（HDMI 波形/李萨如）  scope_mode_req_o （'E'）
//     4   1,0     键盘打鼓开关                 keydrum_req_o    （'K'）
//     5   1,1     推子档位切下一档             gear_next_req_o  （'J'）
//     6   1,2     变调 升 1 半音               trans_up_req_o   （'G'）
//     7   1,3     模式 指板/钢琴               mode_req_o       （新增，无串口命令）
//     8   2,0     鼓机节奏型 切下一个          drum_pattern_req_o（'D'）
//     9   2,1     推子【锁定】切换（冻结/实时）  lock_toggle_req_o（⭐ 2026-10-18 起；原为效果器占位）
//    10   2,2     变调 降 1 半音               trans_down_req_o （'F'）
//    11   2,3     Test Mode 进/出             test_mode_req_o  （'M'）
//    12   3,0     looper 清空（长按）          loop_clear_req_o （'C'）
//    13   3,1     loop 发送（导出该层已录事件） loop_send_req_o  （⭐ 2026-10-17 新增，短按）
//    14   3,2     音高归零（恢复默认音高）      trans_reset_req_o（⭐ 2026-10-15 新增）
//    15   3,3     实时回传开关（松手切换一次） uplink_toggle_req_o
//
//  ⭐⭐ 2026-10-17 新增 idx 13「loop 发送」：
//    ⭐ 用户需求：*"控制板加一个 loop 发送按钮"*，⭐ 位置 = 列 1 / 行 3（原「备用」）✅
//    ⭐ 语义：⭐ 把当前 looper 层**已录事件**经串口导出（⭐ = 串口命令 `'Y'`/`CMD_RECDUMP`）
//    ⭐ 实现：⭐ 本模块**只出脉冲**（⭐ 与 `trans_up_req_o` 完全同构）——
//       ⭐ 由 `top.v` 把它 OR 进 `cmd_recdump_req`（⭐ 那边已有空循环拒绝/只读读口 ✅）
//    🔴 🔴 **本键【没有】长按保护** —— 与 idx 12（清空）、idx 15（标定）刻意不同：
//       ⭐ 理由是**发送是非破坏性操作**（⛔ 不清数据、⛔ 不改状态、⛔ 不进录制）
//          ⇒ ⭐ 短按立即生效，⛔ 不需要"防误触"的那 2 s 阈值 ✅
//          ⚠️ 对照：⭐ `loop_clear_req_o`（idx 12）会**清空整层** ⇒ 🔴 必须长按保护 ✅
//    本键不占用 looper 清空键的长按计数器或标志。
//
//  ⭐⭐ 2026-10-15 新增 idx 14「音高归零」：
//    ⭐ 用户需求：*"矩阵键盘加一个键：一键恢复默认音高"*，⭐ 位置 = 列 2 / 行 3 ✅
//    ⭐ 语义落位：⭐ 列 2 = 音高组（滑音 / 变调升 / 变调降）⇒ ⭐ 行 3 列 2 原来是「备用 2」
//       ⇒ ⭐ **不占用任何现有功能**、⭐ 也不与 key 9（`fx_req_o` 占位）冲突 ✅
//    ⭐ 实现：⭐ 本模块**只出脉冲**，⛔ 不持有音高状态 ——
//       ⭐ 由 `top.v` 把它 OR 进 `fader_gear.trans_abs_i`、⭐ 并选值 `8'd12`
//          （⭐ `fader_gear` 内部编码 `12` = 不调 ⇒ ⭐ `transpose_semi_o = 0` ✅）
//       📌 为什么复用 `trans_abs_i` 通路：⭐ `fader_gear` **已经**有"带帧绝对量"入口
//          ⇒ ⭐ **一行 RTL 都不用改 `fader_gear.v`** ✅（⭐ 最省、⭐ 零回归风险）
//
//  长按保护（破坏性/低频操作）：
//    · idx 12 looper 清空：必须**长按** LONG_MS 才发脉冲（防误触）
//    · idx 15 实时回传：短按或长按均在松手时切换一次，不再触发标定。
//
//  为什么与 calib_cmd 的输出【OR】而不是替换：
//    calib_cmd 的下游全部只认这一组 *_req 脉冲，
//    串口与实体键【来源解耦】⇒ 加按键不用动任何下游模块
//    （依据 files/10-硬件/Console引脚与控制接口总表-20261001.md:129-130）
//
//  判据（见 tb/w3a/tb_ctrl_keypad.sv）：逐键按 ⇒ 对应 req 恰好一次、不串扰
// ============================================================================
`default_nettype none

module ctrl_key_map #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer LONG_MS = 2000          // 长按阈值（ms）
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] key_level,   // 去抖后的电平（1 = 按下）
    input  wire [15:0] key_down,    // 按下脉冲
    input  wire [15:0] key_up,      // 松开脉冲

    output reg         met_req_o,
    output reg         timbre_req_o,
    output reg         slide_req_o,
    output reg         scope_mode_req_o,
    output reg         keydrum_req_o,
    output reg         gear_next_req_o,
    output reg         trans_up_req_o,
    output reg         trans_down_req_o,
    //  ⭐⭐ 2026-10-15：⭐ idx 14（列 2 / 行 3）= 一键恢复默认音高 ✅
    //     🔴 **本 reg 只在【命令脉冲块】（下面的块 2）里赋值** ——
    //        ⚠️ 本模块曾因"同一 reg 在两个 always 块里赋值"在综合报
    //        `ERROR (EX2000) : Net ... is constantly driven from multiple places`
    //        （⭐ 而 iverilog 仿真全绿 ⇒ 🔴 "仿真过 ≠ 能综合"）✅
    //     ⭐ 所以：⭐ 复位清零 / 默认清零 / 置位 **三处都在块 2 内** ✅
    output reg         trans_reset_req_o,
    output reg         drum_pattern_req_o,
    output reg         test_mode_req_o,
    output reg         loop_clear_req_o,
    //  ⭐⭐ 2026-10-17：⭐ idx 13（列 1 / 行 3）= loop 发送（非破坏性 ⇒ 短按即发）✅
    //     ⭐ 用户需求：*"控制板加一个 loop 发送按钮"* ✅
    //     🔴 **本 reg 只在【命令脉冲块】（下面的块 2）里赋值** ——
    //        ⚠️ 本模块曾因"同一 reg 在两个 always 块里赋值"在综合报
    //        `ERROR (EX2000) : Net ... is constantly driven from multiple places`
    //        （⭐ 而 iverilog 仿真全绿 ⇒ 🔴 "仿真过 ≠ 能综合"）✅
    //     ⭐ 所以：⭐ 复位清零 / 默认清零 / 置位 **三处都在块 2 内** ✅
    //     ⭐ ⚠️ 它⛔ **不占用** `hold_clr` 计数器 ⇒ ⭐ 没有长按阈值那一档 ✅
    output reg         loop_send_req_o,
    output reg         mode_req_o,        // 新增：模式切换（top.v 需接一个寄存器）
    output reg         fb_piano_o,        // 模式键「目标档」：1 = 钢琴、0 = 指板
    output reg         uplink_toggle_req_o, // idx15 release; state belongs to top
    output reg         tare_req_o, // retained inactive; serial calibration is independent
    output reg         span_req_o,
    //  ⭐⭐ 2026-10-18：⭐ **idx 9（列 1 / 行 2）= 推子【锁定】键** ✅
    //     ⭐ 用户裁定：*"加一个按键，让推子记忆当前档位此时的状态，再按一下取消记忆"*
    //     ⭐ 语义：⭐ 翻转 `fader_gear` **当前档**的锁定位（1 = 冻结，0 = 实时跟随）
    //     🔴 **本 reg 只在【命令脉冲块】（块 2）里赋值** ——
    //        ⚠️ 本模块曾因"同一 reg 在两个 always 块里赋值"在综合报
    //        `ERROR (EX2000) : Net ... is constantly driven from multiple places`
    //        （⭐ 而 iverilog 仿真全绿 ⇒ 🔴 "仿真过 ≠ 能综合"）✅
    //     ⭐ 所以：⭐ 复位清零 / 默认清零 / 置位 **三处都在块 2 内** ✅
    output reg         lock_toggle_req_o,
    //  ⚠️ **`fx_req_o` 保留为【历史占位】**（2026-10-18）：
    //     🔴 用户已明确"效果器那个键不需要了"，本端口在 `top.v` 里**无消费者**。
    //     ⚠️ 但 `tb/w3a/tb_ctrl_key_map.sv:253/281` 与 `tb_ctrl_keypad.sv:346`
    //        仍断言"idx 9 ⇒ fx_req 一次" ⇒ ⛔ **直接改成恒 0 会让那两个 tb 变红**
    //        ⇒ ⭐ 本轮**保持它照旧随 idx 9 出脉冲**（死信号，无副作用），
    //          待那两个 tb 同步更新后再删端口 ✅
    output reg         fx_req_o           // 历史占位（⛔ 无消费者，仅为 tb 兼容保留）
);

    localparam integer LONG_CYC = (CLK_HZ / 1000) * LONG_MS;

    //  🔴🔴 2026-10-17 修（`D9`，只读审计发现）：⭐ **两个隐患一起修**
    //
    //  🔴 隐患 ①：`HW = $clog2(LONG_CYC)` 只能装到 `LONG_CYC - 1`
    //     ⇒ ⭐ 若 `LONG_CYC` 恰为 2 的幂（如 1024），计数器 `[HW-1:0]` 最大 = 1023
    //        ⇒ 🔴 `hold_clr >= LONG_CYC` **永不成立** ⇒ ⭐ **长按永远不触发**
    //     ✅ 修法：`$clog2(LONG_CYC + 1)` —— ⭐ 这才给出"**装得下 `LONG_CYC` 本身**"的位宽 ✅
    //
    //  🔴 隐患 ②（本文件原来的写法）：`LONG_CYC[HW-1:0]` —— ⭐ 对 `integer` localparam 做**位选**
    //     （⭐ 正是 `K-91` 禁的模式）
    //     ⇒ ⭐ `LONG_CYC = 1024`、`HW = 10` ⇒ `1024[9:0] = 0`
    //        ⇒ 🔴 `clr_at_long = (hold_clr >= 0)` = **恒真**
    //        ⇒ 🔴 `:126` 的 `if (!clr_at_long) hold_clr <= hold_clr + 1'b1;` **一步都不涨**
    //        ⇒ 🔴 **长按立刻触发** ⇒ ⭐ **长按保护整体失效**
    //           （⭐ 后果：idx 12 looper **立刻清空** · idx 15 标定**立刻走 span**）✅
    //     ✅ 修法：⭐ 用**定宽常量** `LONG_CYC_C`（比计数器宽 1 位）＋ **零扩展计数器**比较
    //        ⇒ ⭐ 不再有任何截断 ✅
    //
    //  📌 **当前行为逐位不变**：`LONG_CYC = 100_000_000` ⇒ 旧 `HW = $clog2(100e6) = 27`、
    //     新 `HW = $clog2(100e6+1) = 27` ⇒ ⭐ **同一个 27** ✅；且 `100_000_000[26:0]`
    //     本来就装得下 ⇒ ⭐ 比较结果也逐位相同 ✅
    //  📌 **判据**：⭐ 文件尾 `initial` 新增 `LONG_CYC_C == LONG_CYC` 的自检
    //     ＋ 用 `LONG_CYC = 4` 的参数化实例断言"按住 3 拍不发脉冲" ✅
    localparam integer HW       = (LONG_CYC <= 2) ? 1 : $clog2(LONG_CYC + 1);
    localparam [HW:0]  LONG_CYC_C = LONG_CYC;      // ⭐ 定宽、不截断（HW+1 位）

    initial begin
        if (LONG_MS < 1)
            $display("ERROR [ctrl_key_map] LONG_MS=%0d must be >= 1", LONG_MS);
        else
            $display("NOTE [ctrl_key_map] PARAM_OK=1 (CLK_HZ=%0d LONG_MS=%0d LONG_CYC=%0d HW=%0d)",
                     CLK_HZ, LONG_MS, LONG_CYC, HW);

        //  ⭐⭐ 2026-10-17（`D9`）：⭐ **两条定宽自检** —— 这正是原来缺的
        //     ⭐ ① 定宽常量必须**无损**（⛔ 不许截断 ⇒ 否则 `clr_at_long` 可能恒真）
        if (LONG_CYC_C != LONG_CYC)
            $display("ERROR [ctrl_key_map] D9: LONG_CYC_C=%0d TRUNCATED from LONG_CYC=%0d => clr_at_long/cal_at_long may be stuck TRUE => long-press guard broken.",
                     LONG_CYC_C, LONG_CYC);
        //     ⭐ ② 计数器 `[HW-1:0]` 必须**够到** `LONG_CYC`（⛔ 否则长按永不触发）
        if (LONG_CYC > ((1 << HW) - 1))
            $display("ERROR [ctrl_key_map] D9: LONG_CYC=%0d > counter max %0d (HW=%0d) => long-press NEVER fires.",
                     LONG_CYC, (1 << HW) - 1, HW);
    end

    // ── 长按计数器：仅 looper 清空键需要 ─────────────────────────────
    reg [HW-1:0] hold_clr;     // idx 12 looper 清空
    reg          clr_long_fired;

    //  ⭐ 零扩展计数器 ＋ 定宽常量 ⇒ ⭐ **无截断、无恒真**（⭐ 见上方 `D9` 长注释）
    wire clr_at_long = ({1'b0, hold_clr} >= LONG_CYC_C);

    //  🔴🔴 2026-10-14：⭐ **本块【不再碰】`clr_long_fired` / `cal_long_fired`** ✅
    //     ⭐ **原缺陷（⭐ 仿真过、综合报错 ✅）**：
    //        `ERROR (EX2000) : Net 'clr_long_fired' is constantly driven from multiple places`
    //        `ERROR (EX1999) : Found another driver here`
    //     🔴 **根因**：⭐ 两个标志在**本块**（复位 ＋ 松手清零）**和下面的命令脉冲块**
    //        （长按到阈值时置位）里**各写一次** ✅
    //     📌 ⭐ **一个 reg 只能在一个 always 块里赋值** ——
    //        ⚠️ iverilog **容忍**（后写者胜）⇒ 🔴 **仿真全绿、综合报错** ✅
    //     📌 ⭐ 这正是"**仿真过 ≠ 能综合**"（⭐ 本工程 `P1` 的立项理由 ✅）
    //     📌 ⭐ **为什么现在才发现**：⭐ 本模块**此前从未进过网表** ——
    //        ⚠️ `top.v` 一直没例化它 ⇒ 🔴 直到 2026-10-14 接线才暴露 ✅
    //     ✅ **修法**：⭐ 标志**全部归下面的命令脉冲块** ⇒ 本块只管**计数器** ✅
    always @(posedge clk) begin
        if (!rst_n) begin
            hold_clr        <= {HW{1'b0}};
        end else begin
            // idx 12：按住就计数，松手清零
            if (key_level[12]) begin
                if (!clr_at_long) hold_clr <= hold_clr + 1'b1;
            end else begin
                hold_clr       <= {HW{1'b0}};
            end

        end
    end

    // ── 命令脉冲：全部单周期 ────────────────────────────────────────────────
    //   原则：一个 key_down 只产生【一个】脉冲；长按键改用计数器阈值触发。
    always @(posedge clk) begin
        if (!rst_n) begin
            met_req_o          <= 1'b0;
            timbre_req_o       <= 1'b0;
            slide_req_o        <= 1'b0;
            scope_mode_req_o   <= 1'b0;
            keydrum_req_o      <= 1'b0;
            gear_next_req_o    <= 1'b0;
            trans_up_req_o     <= 1'b0;
            trans_down_req_o   <= 1'b0;
            trans_reset_req_o  <= 1'b0;   // ⭐ idx 14（⭐ 与其余脉冲同一块、同一口径 ✅）
            drum_pattern_req_o <= 1'b0;
            test_mode_req_o    <= 1'b0;
            loop_clear_req_o   <= 1'b0;
            loop_send_req_o    <= 1'b0;   // ⭐ idx 13（⭐ 与其余脉冲同一块、同一口径 ✅）
            mode_req_o         <= 1'b0;
            fb_piano_o         <= 1'b0;
            uplink_toggle_req_o <= 1'b0;
            tare_req_o         <= 1'b0;
            span_req_o         <= 1'b0;
            lock_toggle_req_o  <= 1'b0;   // ⭐ idx 9（2026-10-18 新增）
            fx_req_o           <= 1'b0;
            //  ⭐⭐ 2026-10-14：⭐ **两个长按标志的复位【搬到本块】** ✅
            //     🔴 原缺陷见上面块 1 的注释（⭐ 多驱动 ⇒ 综合报错 ✅）
            clr_long_fired     <= 1'b0;
        end else begin
            // 默认全低：单周期脉冲
            met_req_o          <= 1'b0;
            timbre_req_o       <= 1'b0;
            slide_req_o        <= 1'b0;
            scope_mode_req_o   <= 1'b0;
            keydrum_req_o      <= 1'b0;
            gear_next_req_o    <= 1'b0;
            trans_up_req_o     <= 1'b0;
            trans_down_req_o   <= 1'b0;
            trans_reset_req_o  <= 1'b0;   // ⭐ idx 14（⭐ 单周期脉冲的默认低 ✅）
            drum_pattern_req_o <= 1'b0;
            test_mode_req_o    <= 1'b0;
            loop_clear_req_o   <= 1'b0;
            loop_send_req_o    <= 1'b0;   // ⭐ idx 13（⭐ 单周期脉冲的默认低 ✅）
            mode_req_o         <= 1'b0;
            uplink_toggle_req_o <= 1'b0;
            tare_req_o         <= 1'b0;
            span_req_o         <= 1'b0;
            lock_toggle_req_o  <= 1'b0;   // ⭐ idx 9（单周期脉冲的默认低 ✅）
            fx_req_o           <= 1'b0;

            // 行 0 · 节奏/循环组（按下沿直接出脉冲）
            if (key_down[ 0]) met_req_o          <= 1'b1;
            // 行 0 · 音色组
            if (key_down[ 1]) timbre_req_o       <= 1'b1;
            // 行 0 · 音高组
            if (key_down[ 2]) slide_req_o        <= 1'b1;
            // 行 0 · 系统组
            if (key_down[ 3]) scope_mode_req_o   <= 1'b1;

            // 行 1
            if (key_down[ 4]) keydrum_req_o      <= 1'b1;
            if (key_down[ 5]) gear_next_req_o    <= 1'b1;
            if (key_down[ 6]) trans_up_req_o     <= 1'b1;
            // 模式键：发脉冲，同时给出「目标档」
            //   按下瞬间翻转：当前是钢琴(1) 就切到指板(0)，反之亦然
            if (key_down[ 7]) begin
                mode_req_o <= 1'b1;
                fb_piano_o <= ~fb_piano_o;
            end

            // 行 2
            if (key_down[ 8]) drum_pattern_req_o <= 1'b1;
            //  ⭐⭐ 2026-10-18：⭐ **idx 9 = 推子锁定键**（用户裁定）✅
            //     ⭐ 语义：⭐ 翻转 `fader_gear` 当前档的锁定位（1 = 冻结 / 0 = 实时）
            //     ⚠️ `fx_req_o` **同时照旧出脉冲** —— 它已无消费者，保留只为
            //        `tb_ctrl_key_map.sv:253/281` 与 `tb_ctrl_keypad.sv:346` 的旧断言
            //        （⭐ 待那两个 tb 更新后再删端口 ✅）
            if (key_down[ 9]) begin
                lock_toggle_req_o <= 1'b1;
                fx_req_o          <= 1'b1;   // 历史占位（⛔ 无消费者，仅为 tb 兼容）
            end
            if (key_down[10]) trans_down_req_o   <= 1'b1;
            if (key_down[11]) test_mode_req_o    <= 1'b1;

            // 行 3 · 音高组（⭐ 2026-10-15 新增）：⭐ idx 14 = 列 2 / 行 3 ✅
            //   ⭐ 用户需求：*"矩阵键盘加一个键：一键恢复默认音高"* ✅
            //   ⭐ 语义：⭐ 列 2 是音高组（滑音 / 变调升 / 变调降）⇒ ⭐ 归零键落在这里最自然 ✅
            //   📌 ⭐ 本模块**只出脉冲**（⭐ 与 `trans_up_req_o`/`trans_down_req_o` 完全同构）——
            //      ⭐ 音高状态在 `fader_gear` 里，⛔ 本模块不持有 ⇒ ⛔ 不引入第二个状态源 ✅
            if (key_down[14]) trans_reset_req_o  <= 1'b1;

            //  ⭐⭐ 2026-10-17：⭐ **idx 13（列 1 / 行 3）= loop 发送** ✅
            //     ⭐ 用户需求：*"控制板加一个 loop 发送按钮"* ✅
            //     ⭐ 语义：⭐ 导出当前 looper 层**已录事件**（⭐ = 串口 `'Y'`/`CMD_RECDUMP`）
            //        ⭐ 由 `top.v` 把它 OR 进 `cmd_recdump_req`（⭐ 空循环那边已有拒绝 ✅）
            //     🔴 🔴 **短按即发，⛔ 无长按保护** —— 与 idx 12/15 刻意不同：
            //        ⭐ 发送是**非破坏性**的（⛔ 不清数据、⛔ 不改状态）⇒ ⭐ 不需要防误触阈值 ✅
            //        ⚠️ 对照：⭐ idx 12 `loop_clear_req_o` 会**清空整层** ⇒ 🔴 必须长按 ✅
            //     📌 ⭐ 直接挂在 `key_down` 上 ⇒ ⭐ 与 `met_req_o`/`timbre_req_o` 同构
            //        ⇒ ⭐ 天然"一个沿只出一个脉冲"，⛔ 长按不会连发 ✅
            if (key_down[13]) loop_send_req_o    <= 1'b1;

            //  ⭐⭐ 2026-10-14：⭐ **松手清标志**（⭐ 从块 1 搬过来 ✅）
            //     📌 ⭐ 顺序：⭐ 先"松手清"、⭐ 再"阈值置位" ——
            //        ⚠️ 同一拍两者**不可能同时成立**
            //        （⭐ 一个要求 `key_level=0`、⭐ 一个要求 `=1` ✅）
            if (!key_level[12]) clr_long_fired <= 1'b0;

            // 行 3 · looper 清空：长按阈值到达那一刻发一次（且只发一次）
            if (key_level[12] && clr_at_long && !clr_long_fired) begin
                loop_clear_req_o <= 1'b1;
                clr_long_fired   <= 1'b1;
            end

            // Debounced release: one toggle even after a long hold.
            // Calibration remains available through serial T and power-on autotare.
            if (key_up[15]) uplink_toggle_req_o <= 1'b1;
        end
    end

endmodule

`default_nettype wire
