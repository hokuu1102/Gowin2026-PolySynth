@@@PRIO=P0|SRC=TORCH-2|ORIG=P0-1|MOD=rtl/w3a/axis_snapshot.v
### 让 snap_valid 由"本帧最后一个样本"派生（现在末轴旧一帧）
- **位置**：rtl/drivers/mcp3208_scanner.sv:123-131；rtl/drivers/adc_farm.sv:107；rtl/top.v:2542-2545；rtl/w3a/axis_snapshot.v:148-151、:191-194；rtl/drivers/calib.sv:369-384；tb/w3a/tb_axis_snapshot.sv:101-139、:126-137、:184；tb/w3a/tb_span_with_real_adc_farm.sv
- **现状**：
```verilog
// rtl/drivers/mcp3208_scanner.sv:123-131  —— frame_done 与 ch7 的 sample_valid 【同拍】
if (driver_done) begin
    sample_channel <= driver_channel;
    sample_data    <= driver_data;
    sample_valid   <= 1'b1;
    if (driver_channel == 3'd7) begin
        frame_done <= 1'b1;          // ⭐ 与上面 sample_valid 同一拍、同一 always
        state      <= STATE_WAIT_PERIOD;
// rtl/top.v:2542-2545  —— 快照看到的 sample_* 来自 calib（延 1 拍），frame_done 来自 adc_farm（不延）
.sample_valid_i(cal0_vld),      // ⭐ 两片同拍 ⇒ 用一个即可
.sample_ch_i   (cal0_ch),
.sample_data_i (cal_packed),
.frame_done_i  (af_frame_done),
// rtl/w3a/axis_snapshot.v:191-194  —— snap_valid 只延 1 拍
always @(posedge clk) begin
    if (!rst_n) snap_valid_o <= 1'b0;
    else        snap_valid_o <= frame_done_i;
end
```
- **为什么是问题**（逐拍算）：`T`：adc_farm（= scanner）`sample_valid=1, ch=7` 且 `frame_done=1`（scanner 同拍）。`T+1`：`calib.out_valid=1, out_ch=7, out_val=本帧值`（`v_r <= valid` 恰好 1 拍，`out_*` 是 `always @(*)` 组合输出，三者同拍 —— 已核对 calib.sv:369-384）；同时 `snap_valid_o <= frame_done_i(=1 @T)` ⇒ `snap_valid_o` 在 `T+1` 拉高。`cur[7] <= sample_data_i[...]` 是非阻塞，在 `T+1` 的时钟沿才写入 ⇒ `cur[7]` 从 `T+2` 起才是本帧值。⇒ **`snap_valid_o=1` 的那一拍（`T+1`），`cur[7]`/`cur[15]` 仍是上一帧的值**（`T+2` 才更新）⇒ 快照内容是 `ch0..ch6`（本帧 N）＋ `ch7`（上一帧 N−1）⇒ 轴 **7 和 15 固定滞后一个帧周期 = 500 µs**。为什么这不是布局运气：这是代码结构决定的（生产者同拍、消费者差 1 拍），换任何布局都一样 ⇒ **【结构性】**。⚠️ 为什么 130 个 tb 全绿（假绿证据）：tb/w3a/tb_axis_snapshot.sv:101-139 的 `scan_frame` 把 `frame_done` 放在 8 个 `sample_valid` 之后（:126-137：`@(negedge clk); frame_done = 1'b1; @(posedge clk); @(negedge clk); frame_done = 1'b0;`）⇒ tb 的 `frame_done` 比 `ch7` 的 `sample_valid` 晚 2 拍，比真实生产者（同拍）宽松 2 拍；且它的判据查的是轴 3（:184 `pget(3) === 12'h333`），不是最后一轴 7/15 ⇒ 生产者的真实时序 + 最末轴，这两件事同时没人验 ⇒ 典型 C83（探针假绿）。
- **改法**（⛔ 不碰 calib、⛔ 不改 tb 契约）：把 `snap_valid_o` 的来源从 `frame_done_i` 改成"本帧最后一个样本"：
```verilog
// rtl/w3a/axis_snapshot.v  替换 :191-194
reg last_ch_r;
always @(posedge clk) begin
    if (!rst_n) begin last_ch_r <= 1'b0; snap_valid_o <= 1'b0; end
    else begin
        last_ch_r    <= sample_valid_i && (sample_ch_i == 3'd7);   // ⭐ 与写侧同一条件
        snap_valid_o <= last_ch_r;                                 // ⭐ 与写侧同源 ⇒ 流水长度无关
    end
end
```
为什么零回归：老 tb 里 `frame_done` 与 `ch7` 的 `sample_valid` 之间隔了 2 拍，但"最后一个样本"就是 `ch7` ⇒ 新写法在老 tb 下与原写法逐位相同（都是 `ch7` 后 1 拍）；而在真实链上（`frame_done` 与 `ch7` 同拍），新写法把快照推迟到 `ch7` 写入之后 ⇒ 修好。（若担心 `frame_done` 与 `ch7` 不同拍的其它集成，可加一条自检：`frame_done_i` 与 `sample_valid_i && sample_ch_i==3'd7` 若在 N 拍内不同时出现 ⇒ `$display("ERROR ...")`。）
- **预期**：收益 = 恢复"16 轴同帧原子"契约；轴 7/15 的触发/释放延迟从 **+500 µs 归 0**；和弦跨轴 7/15 时不再被拆到两帧。代价 = **+1 FF**（last_ch_r）、快照脉冲晚 1 拍（0 拍净增：原写法在真实链上也是 T+1）；⛔ 不动 calib、⛔ 不动 adc_farm、⛔ 不动端口 ⇒ 集成零风险。
- **怎么验**：①先写一个红探针：把 tb_axis_snapshot.sv 的 `scan_frame` 改成"`frame_done` 与 `ch7` 的 `sample_valid` 同拍"，并把判据从 `pget(3)` 换成 `pget(7)`/`pget(15)` ⇒ 改前必红（读到上一帧值），改后必绿。②端到端：在 tb/w3a/tb_span_with_real_adc_farm.sv 这类真 adc_farm 的 tb 里，断言"每一帧快照里 16 个轴都来自同一帧"（例如给 ch7 一个逐帧变化的斜坡，检查 `pos[7]` 与 `pos[6]` 同帧）。③上板：给轴 7 和轴 0 同时按键，看事件间隔是否 > 一个帧周期。
- **来源**：TORCH-2【P0-1】
@@@END
@@@PRIO=P0|SRC=TORCH-2|ORIG=P0-2|MOD=rtl/top.v,rtl/w3c/evt_uart_rx.v
### 裁定 SCORE_UART_ENABLE（默认 1 已上线，0xA5 伪事件 ⇒ 永久挂音）
- **位置**：rtl/top.v:3495、:1011-1019、:3725-3735、:3480、:3690、:3713、:3692-3711、:497-499；rtl/w3c/evt_uart_rx.v:87；rtl/w3b/note_manager.v:1150-1156；rtl/w3c/seq_arb.v:178；tb/w3c/tb_evt_uart_rx_screen.sv:13-20、:117-124、:143、:162
- **现状**：
```verilog
// rtl/top.v:3495  —— ⭐ 默认值 = 1（开）
localparam integer SCORE_UART_ENABLE = 1;
// rtl/top.v:1011-1019  —— 与 uart_ui(:916-917) / calib_cmd(:963-964) 共用同一对 ur_done/ur_data
evt_uart_rx #(
    .BAUD     (500_000),
    ...
) u_evt_uart_rx (
    .rx_done_i     (ur_done),
    .rx_data_i     (ur_data),
// rtl/top.v:3725  —— 默认档下它真的接到了 seq_arb 的曲谱口
.score_valid_i    (SCORE_UART_ENABLE ? eu_evt_valid : 1'b0),
// rtl/w3c/evt_uart_rx.v:87
parameter [7:0]   HEADER    = 8'hA5
// rtl/w3b/note_manager.v:1150-1156  —— 只清 (轴,源) 都匹配的 voice
                                && (src_r[i]  == cur_src)) begin
```
- **为什么是问题**：伪事件的源标签是 `score`(3'd1)（seq_arb:178 SRC_SCORE），而手弹是 `live`(3'd0)；note_manager 的 `note_off` 判据是 `(axis_r[i] == cur_axis) && (src_r[i] == cur_src)` 双条件 ⇒ 手弹（live）的 `note_off` **结构上不可能**清掉 `score` 的 voice ⇒ 那个 voice 的 `gate_r` 永久为 1。触发条件：任何一路合法载荷里出现 `0xA5` 且它落在 `idx==0`，且其后还有 ≥8 个字节（tb/w3c/tb_evt_uart_rx_screen.sv:13-20、:117-124、:143、:162 就是照这个构造的）。top.v:3692-3711 自述："⭐ 证据（仿真 tb/w3c/tb_evt_uart_rx_screen.sv，⛔ 不是推测）：… 实测：喂 8 个屏幕数值帧（数据含 0xA5）⇒ 产生了 8 条伪事件，其中 `axis = 15`（保留轴）· `inc = 0x1FFFFF` · `kind = 0`（note_on）"，且与用户实测吻合：「按同键不能清」「按所有键也不能清」「持续几分钟」「断电才清」「~50% 概率」。🔴 文档与代码冲突（必须裁定）：同一文件里两处注释仍写"默认 0 = 禁用"—— top.v:3690（`2026-09-28：默认【禁用】—— 这是一条【已证明】的伪事件注入路径`）与 top.v:3713（`修法（最小变量）：把曲谱通路做成编译期开关，默认 0`），而 top.v:3480 又写"2026-09-30：默认由 0 改成 1"、:3495 实际是 1 ⇒ 注释有三代版本混在一起，只有 :3495 是地面真相，而地面真相 = 风险已上线。
- **改法**（二选一，按用户取舍）：A（最小、立刻降风险）：top.v:3495 改回 0；代价 = 曲谱 UART 关闭（looper 照常，因为 looper 已走 evt_merge 源 C）。B（保功能、治根因）：给曲谱一路独立 UART 线（top.v:497-499 已经有 `esp_uart_rx_i` 这类独立脚），或把 evt_uart_rx 的帧同步从"`idx==0` 看 0xA5"升级为带长度/校验和的帧（⚠️ 这要动 tools/mid2evt.py 的打包侧，属跨线改动）。无论 A/B：把 top.v:3690/:3713 两处过时注释改成与 :3495 一致（否则下一个人会照注释把开关打开）。
- **预期**：A 的收益 = **彻底关闭一条已证明的永久挂音路径**；代价 = 曲谱功能不可用（用户需知情）。B 的收益 = 两个功能都要；代价 = 引脚/协议改动 + 打包侧同步。
- **怎么验**：①`sim/tb_all.ps1` 里跑 tb/w3c/tb_evt_uart_rx_screen.sv —— 该 tb 已经在 :162 打印 `decoded axis = %0d (14/15 = reserved, keyboard can NEVER clear it)` ⇒ 它现在就是红的证据源；把它升级为"伪事件数必须 == 0"的断言式判据，则开关=1 时必红、=0 时必绿。②顶层判据：喂含 0xA5 的屏幕帧，然后只用手弹 note_off 清场，断言 `nm_gate` 全 0。
- **来源**：TORCH-2【P0-2】
@@@END
@@@PRIO=P0|SRC=TORCH-2|ORIG=P0-3|MOD=rtl/w3a/param_extract.v,rtl/top.v
### 把 param_extract 的起音时刻判据从事件改成 pos 本身
- **位置**：rtl/w3a/param_extract.v:251-255、:261-286、:269-283、:187-189、:158；rtl/w3a/event_extract.v:359-365；rtl/top.v:4090-4094、:4096、:4069、:4093-4094；tb/w3a/tb_param_extract.sv
- **现状**：
```verilog
// rtl/w3a/param_extract.v:251-255  —— t1 只在【事件】到达时锁存
if (evt_valid_i && (evt_kind_i != 2'd1)) begin
    // ⭐ 注意：⛔ 只处理 note_on(0) / pluck(2)，⭐ **note_off(1) 不参与测速**
    t1_stamp[evt_axis_i] <= frame_cnt;
    t1_seen [evt_axis_i] <= 1'b1;
end
// :269-283  —— 扫描到该轴时判"越深阈"，且一旦越阈就置 was_above_t2
if (pos_i[scan_axis*POS_W +: POS_W] >= VEL_T2_EFF) begin
    if (!was_above_t2[scan_axis] && t1_seen[scan_axis]) begin
        ...
        dt_valid[scan_axis] <= 1'b1;        // ⭐ 待发 vel_update
    end
    was_above_t2[scan_axis] <= 1'b1;        // ⭐ 无条件置位（不论 t1_seen）
end
// rtl/w3a/event_extract.v:359-365  —— 出队是"下一拍才置 evt_valid_o"
if (q_cnt != 0) begin
    evt_valid_o <= 1'b1;                      // ⭐ 与下面三个字段同一拍
// rtl/top.v:4090-4094  —— 承诺的恢复路径
//   ⚠️ **`param_extract` 的力度三件套现在是【有意不使用】**（⛔ 不是漏接线）：
//      · ⭐ 将来若要恢复"敲击速度"式力度 ⇒ 把下行换回 `pe_vel_v`/`pe_vel_ax`/`pe_vel` 即可
```
- **为什么是问题**（逐拍算）：event_extract 扫描到轴 `i` 在 `snap_valid` 后第 `1+i` 拍 ⇒ 该拍 push（`q_push_now=1`），`q_cnt` 在该拍末变 1；下一拍（`2+i`）`q_cnt != 0` ⇒ `evt_valid_o <= 1`（寄存）⇒ `evt_valid_o` 在 **`3+i`** 拍才高。param_extract 的扫描与 event_extract 锁步（同一 `snap_valid_i` 起扫、一拍一轴）⇒ 它在 **`1+i`** 拍就已经判完轴 `i` ⇒ param_extract 判轴 `i` 的那一刻，`t1_seen[i]` 还是 0（事件要 `3+i` 才到）⇒ **`Δt` 不计算**；同时 `was_above_t2[i] <= 1` 被无条件置位 ⇒ 此后只要手指还按着（`pos ≥ VEL_T2_EFF`），`!was_above_t2` 恒假 ⇒ 这一次按键的 `Δt` 永远算不出来；要等 `pos` 掉回 `VEL_T2_EFF` 以下（`was_above_t2` 清零）才有下一次机会。⇒ **同帧跨双阈（快按）= `Δt` 应为 0 ⇒ 力度应取 `VEL_MAX`（`vel_lut[0..DT_MIN] = VEL_MAX`，:187-189），实际却是"一条都不发"。** ⚠️ 这也解释了历史症状："感受不到力度反馈"（top.v:4069）+ 旧实现"只允许调大 ⇒ 慢按给 64 被 `>` 挡掉、快按给 255 才生效" ⇒ 快按恰恰是唯一本应生效的那一种，而它被这条时序错拍吃掉了。⚠️ 当前影响被遮蔽但恢复路径是坏的：top.v:4096 现在把 `vel_upd_*` 接的是位置式力度流（`vu_valid_r`），param_extract 的力度输出无人使用 ⇒ 眼下不痛；但 top.v:4093-4094 把"换回 `pe_vel_*`"写成正式恢复路径 ⇒ 照那句注释做，力度功能依然是坏的（而且坏得极隐蔽：波形全对、只是不发 vel_update）。
- **改法**（⛔ 不动 event_extract、⛔ 不动端口）：把"起音时刻"的判据从事件改成 `pos` 本身，让扫描自洽：
```verilog
// rtl/w3a/param_extract.v  在扫描分支里（:269 之前）插入 T1 检测
if (pos_i[scan_axis*POS_W +: POS_W] >= VEL_T1_EFF) begin
    if (!t1_seen[scan_axis]) begin
        t1_stamp[scan_axis] <= frame_cnt;      // ⭐ 同帧首越浅阈 ⇒ Δt = 0
        t1_seen [scan_axis] <= 1'b1;
    end
end else begin
    t1_seen[scan_axis] <= 1'b0;                // ⭐ 回落 ⇒ 允许下一次
end
//   ⚠️ 同帧跨双阈时 t1_seen 要到下一拍才可见 ⇒ 让 T2 判定用"上一拍的 t1_seen"
//      （即把 T2 判定也打一拍，或在同拍用 pos >= T1 直接短路成 Δt=0 ⇒ 取 VEL_MAX）
```
最小改法：把 :271 的条件改成 `if (!was_above_t2[scan_axis] && (t1_seen[scan_axis] || (pos_i[scan_axis*POS_W +: POS_W] >= VEL_T1_EFF)))` 并让 `Δt = 0`（即 `dt_hold <= 0`）⇒ 同帧跨双阈直接取 `VEL_MAX`，语义与 `vel_lut` 的 `lut_i <= DT_MIN ⇒ VEL_MAX` 完全一致。
- **预期**：收益 = 恢复"快按 = 最大力度"这条契约；代价 = 0 LUT（复用已有的 `VEL_T1_EFF` 比较器，VEL_T1_EFF 现在只有自检在用 ⇒ 比较器基本免费）；回归风险 = 低（只影响 param_extract 的 `vel_*`，而 top.v 当前不消费它 ⇒ 对既有 tb 影响面小，但 tb/w3a/tb_param_extract.sv 的判据必须复核）。
- **怎么验**：新 tb 用例（或加进 tb_param_extract.sv）：一帧内把某轴 `pos` 从 0 直接给到 `> VEL_T2_EFF`（同时 event_extract 在同一帧发 `note_on`）⇒ 改前：`vel_valid_o` 一次都不脉冲（必红）；改后：脉冲一次且 `vel_value_o == VEL_MAX`。再补一条"跨帧"用例（第 N 帧越 T1、第 N+3 帧越 T2）⇒ 两版都应绿（防回归）。
- **来源**：TORCH-2【P0-3】
@@@END
@@@PRIO=P1|SRC=TORCH-2|ORIG=P1-4|MOD=rtl/top.v,rtl/w3b/note_manager.v
### 给键盘打鼓独立源标签（现在与源 B 同标签，轴 14/15 抢音）
- **位置**：rtl/top.v:3842-3843、:3834-3843、:3953、:4004-4013、:3774-3779、:3793；rtl/w3b/note_manager.v:1150-1156、:135、:1250-1258；rtl/w3c/metronome.v:48、:170；tb_pool_by_src / tb_key_drum / tb_top_drum_timbre
- **现状**：
```verilog
// rtl/top.v:3834-3843
//  ⭐⭐ 2026-10-01：⭐ **打鼓模式下把来源标成 `SRC_AUX(3)`** ——
//     ⭐ 这一条是**整个功能的关键** ...
//     ⚠️ **代价（⭐ 已评估）**：⭐ 鼓垫与"源 B（节拍器/鼓机）"**共用保留池**
//        （⭐ `RESERVED_N = 5`）⇒ ⚠️ 两者同时响时抢 5 个 voice；
wire [2:0]  src_a_src = key_drum_r ? 3'd3
                      : ((SOURCE_A_SEL == 1) ? 3'd2 : sa_src);
// rtl/top.v:3953  —— 源 B 也是 3'd3
.b_src_i          (3'd3),
// rtl/w3c/metronome.v:48 / :170
parameter integer AXIS_ID     = 14,
parameter [1:0]         EVT_KIND   = 2'd0
```
- **为什么是问题**：键盘打鼓的映射（top.v:3774-3779 / :3793）里，轴 14/15 是真实键（`axis[3:2]==2'd3` = 板2 左两列 = 踩镲，轴 12~15）；而节拍器的 `AXIS_ID = 14`（`EVT_KIND` 恒 2'd0 = note_on），源标签同为 `3'd3`。note_manager 的 `same_hit[sg] = (axis_r[sg]==cur_axis) && (src_r[sg]==cur_src)` ⇒ 节拍器在轴 14 的 note_on 会命中用户在轴 14 的踩镲 voice（同轴同源）⇒ 走"同轴重触发"复用路径，把用户那个 voice 直接改判/重触发（ST_RETRIG 分支，note_manager.v:1250-1258）。⇒ 症状：打鼓模式下每来一拍，轴 14 的踩镲音被节拍器抢走/打断；`RESERVED_N=5` 的池还要被两路瓜分。top.v:3838-3841 的注释只承认了"共用保留池"，没有承认"同标签导致 `(轴,源)` 隔离失效"这一条。
- **改法**（三选一）：A（最省、语义最正）：给键盘打鼓自己的源标签 `3'd5`（3 位编码现在只用 0~4，`3'd5/6/7` 空闲，见 note_manager.v:135 的编码表）；同时把 note_manager 的 `pool_mask` 与 `voice_drum_o` 判据从 `cur_src == SRC_AUX` 扩成 `(cur_src == SRC_AUX) || (cur_src == SRC_KDRUM)` ⇒ 仍进保留池，但隔离独立。B（不改 RTL 结构）：note_manager.RESERVED_N 从 5 提到 8，并把节拍器/鼓机的 AXIS_ID 与真实键轴错开（⚠️ 但轴 14/15 是物理键，错开就只能选未使用的轴号，而 16 轴全被占用 ⇒ B 不可行）。C：打鼓模式下禁止 `met_on_r`（用户用 'B' 关掉源 B）—— 这只是规避，⛔ 不是修。
- **预期**：A 的收益 = 打鼓与节拍器彻底不互相抢音；代价 = `src` 位宽已 3 位（够）、`pool_mask`/`voice_drum_o` 各多一个 3 位比较（约 +6 LUT × 2）、top.v 一个常数改动；回归风险 = 中（tb_pool_by_src / tb_key_drum / tb_top_drum_timbre 的源标签判据要跟着加一档）。
- **怎么验**：新 tb：开 `key_drum_r` + `SEL_DRUM=0` + `met_on_r=1`，先在轴 14 手敲一下（记下 `nm_gate` 的位），再等节拍器在轴 14 发 note_on ⇒ 断言"手敲那个 voice 的 `axis_r`/`src_r`/`vel_r` 没有被覆盖"。改前必红（被 `same_hit` 复用），改后必绿。
- **来源**：TORCH-2【P1-4】
@@@END
@@@PRIO=P1|SRC=TORCH-2|ORIG=P1-5|MOD=rtl/top.v,rtl/w3c/looper.v
### 把 vel_upd 两路合并的隐式不变量变成断言或真仲裁
- **位置**：rtl/top.v:4096-4098、:4116、:3630、:4110-4111、:4113-4115；rtl/w3c/looper.v:393、:789、:931；tb/w3c/tb_score_looper_coexist
- **现状**：
```verilog
// rtl/top.v:4096-4098
.vel_upd_valid_i   (vu_valid_r | lp_upd_valid),
.vel_upd_axis_i    (vu_valid_r ? vu_axis_r : lp_upd_axis),
.vel_upd_value_i   (vu_valid_r ? vu_val_r  : lp_upd_vel),
// rtl/top.v:4116
.vel_upd_src_i     (vu_valid_r ? 3'd0 : 3'd4),
// rtl/w3c/looper.v:393  —— live_busy 只看【手弹力度流】，⛔ 不看手弹事件流
wire live_busy = (live_vel_valid_i === 1'b1);
// rtl/top.v:3630  —— live_vel_valid_i 接的正是 vu_valid_r
.live_vel_valid_i (vu_valid_r),
```
- **为什么是问题**：`lp_upd_valid` 只在 `play_upd_valid_o <= pb_msk`（looper.v:931）处产生，而该引擎整体被 `~live_busy` 门控（`eng_en_w`，looper.v:789）⇒ 由于 `live_busy ≡ vu_valid_r`，`lp_upd_valid=1` 时 `vu_valid_r` 必然=0 ⇒ 当前不丢。⇒ 但这是隐式不变量：top.v 的两路 mux 语义是"`vu_valid_r` 优先、另一路直接丢"，而"另一路不会同时来"这件事没有任何断言/没有计数器/没有注释把它和 `live_busy` 的定义绑在一起。⚠️ 脆弱点：`live_busy` 的定义是 `live_vel_valid_i`，不是 `live_valid_i`（手弹事件）；若将来有人把它改成"手弹事件也避让"（更保守、看起来更对），或把 `live_vel_valid_i` 换成 `w3a_evt_valid`，则 `lp_upd_valid` 与 `vu_valid_r` 可同拍 ⇒ looper 的力度更新被静默丢弃，且 `mg_drop_cnt` 之类计数器一个都不动（这条路径不经过任何 FIFO）。症状会是："loop 回放只有起音力度、没有插值滑行" —— 正是 top.v:4110-4111 记过的老症状。
- **改法**（三件，任一即可，建议一起）：1. 在 top.v 的 mux 旁边加断言式自检（组合，仿真期）：`if (vu_valid_r && lp_upd_valid) $display("ERROR [top] vel_upd 两路同拍 ⇒ looper 更新被丢");` 2. 把 looper.v:393 的注释与 top.v:4113-4115 的注释交叉引用（现在两边各说一半，靠读代码的人自己拼）。3. 更稳：给这两路加一个 2 选 1 的仲裁 + 丢计数（把 looper 的那条排队一拍，像 evt_merge 那样），而不是"OR 起来 + 优先"。
- **预期**：收益 = 把一条静默失效变成可见；代价 = 一条 `$display`（0 面积）或一个 1 位计数器（1 FF）；回归风险 = 极低。
- **怎么验**：把 looper.v:393 临时改成 `wire live_busy = 1'b0;`（模拟"口径变了"）⇒ 改前：`$display` 在 tb_score_looper_coexist 里出现；改后（不加自检）什么都不打印、但 loop 力度更新真的丢了 ⇒ 这就是"静默"的证据。
- **来源**：TORCH-2【P1-5】
@@@END
@@@PRIO=P1|SRC=TORCH-2|ORIG=P1-6|MOD=rtl/w3a/axis_map.v,rtl/top.v
### 用 generate 门控 axis_map 的插值链（现在靠常量折叠，40 位乘法器是雷）
- **位置**：rtl/w3a/axis_map.v:519-544、:547-549、:513-518；rtl/top.v:3257-3267、:3267、:3283；rtl/w3b/note_manager.v:69、:1429-1453；tb/w3a/tb_axis_map.sv
- **现状**：
```verilog
// rtl/w3a/axis_map.v:519-544
wire [FRAC_W-1:0] frac = {FRAC_W{1'b0}};
wire [PHASE_W-1:0] inc_lo = mode_i ? fb_inc[fb_sel] : kb_inc[fb_sel];
wire [KW-1:0]      hi_sel = (fb_sel >= KEY_MAX) ? KEY_MAX : (fb_sel + 1'b1);
wire [PHASE_W-1:0] inc_hi = mode_i ? fb_inc[hi_sel] : kb_inc[hi_sel];
wire [PHASE_W-1:0] inc_delta = inc_hi - inc_lo;
wire [PHASE_W+FRAC_W-1:0] interp_raw = inc_delta * frac;    // ⚠️ 40 位
wire [PHASE_W-1:0] interp = (SHIFT < 1) ? {PHASE_W{1'b0}} : interp_raw[PHASE_W+FRAC_W-1:SHIFT];
wire [PHASE_W-1:0] phase_calc = inc_lo + interp;
wire [PHASE_W-1:0] phase_safe = (phase_calc == {PHASE_W{1'b0}}) ? {{(PHASE_W-1){1'b0}}, 1'b1}
                                                                : phase_calc;
assign phase_inc_o   = phase_safe;
assign phase_valid_o = pos_valid_i;      // ⭐ 直通 ⇒ 与数据同拍
assign axis_id_o     = axis_id_i;        // ⭐ 透传
// rtl/top.v:3267  —— 组合输出的唯一断点
am_inc_out  <= am_inc;   // ⭐ 打一拍，与 am_vld_out/am_axis_out 严格同拍
```
- **为什么是问题**：路径：`am_axis_in[3:0]`(FF) → `fb_sel` → `kb_inc`/`fb_inc` 两张 16×32 表 + `mode_i` 2:1 ⇒ 等效 **32:1 × 32 位** mux → `inc_lo` → `+ interp`（当前 `interp ≡ 0`）→ **32 位 `== 0` 比较** → `am_inc_out[31:0]`(FF)。跨模块边界数 = 1（top ↔ axis_map），纯组合，没有任何流水断点 ⇒ 这段深度固定由代码结构决定 ⇒ 【结构性】。⚠️ 量级判断（要说清）：16:1 的 32 位 mux 在 4 输入 LUT 上约 3 级，加 2:1 与零比较 ⇒ 约 4~5 级；这不是本设计的最长路径（最长在 note_manager 的 32 voice 扫描，见 P1-8）⇒ 结论：【结构性】但浅；在 Fmax 余量薄（+0.642 ns）时值得知道它在，但⛔ 不要把它当主因去大改。⚠️ 没有 PnR 报告来证明它是不是某条违例的端点 ⇒ 这一条必须由 PnR 的路径报告确认，⛔ 不许当成已证。🔴 真正的雷：`interp_raw = inc_delta * frac` 声明是 `PHASE_W+FRAC_W = 40` 位；现在 `frac` 是常量 0 ⇒ 综合器必然折叠成 0（按常量传播推理；⚠️ 未在综合报告里核实）；但 axis_map.v:513-518 明确说这条链是为将来的"滑弦"功能保留的 ⇒ 一旦有人把 `frac` 变成真实信号，一个 40 位×8 位的组合乘法器会直接出现在 `am_inc_out` 的组合锥里，而本器件 DSP 已到 98%（note_manager.v:69）⇒ 大概率落成 LUT 阵列 ⇒ Fmax 直接崩。
- **改法**：1. ⛔ 不要删（注释说明是留给滑弦的）；改法 = 把折叠这件事变成"结构上保证"：把 `frac` 从 `wire [FRAC_W-1:0] frac = {FRAC_W{1'b0}};` 改成 `localparam [FRAC_W-1:0] FRAC_ZERO = {FRAC_W{1'b0}};` 并用 `generate if` 把插值链整段门控掉（与 note_manager.T3_EN 的 generate 门控是同一手法，见 note_manager.v:1429-1453）：
```verilog
generate if (INTERP_EN) begin : g_interp
    ... inc_hi / inc_delta / interp_raw / interp ...
end else begin : g_no_interp
    assign interp = {PHASE_W{1'b0}};
end endgenerate
```
⇒ 关闭时乘法器结构上不存在（⛔ 不依赖综合器的常量折叠），打开时也看得见代价。2. 若确认要保留插值能力：把 `interp_raw` 的乘法打一拍（插值本来就允许 1 拍延迟），把组合锥切断 —— ⚠️ 但那会改 `phase_valid_o` 与 `phase_inc_o` 的同拍关系 ⇒ 必须同步 top.v 的 `am_inc_out` 流水。
- **预期**：收益 = 消除"将来一改就崩"的雷；代价 = 0（关闭档下 LUT/FF 均不变，因为本来就被折叠）；回归风险 = 低（tb/w3a/tb_axis_map.sv 的行为不变）。
- **怎么验**：综合报告对比 —— 在 `INTERP_EN=0` 与 `INTERP_EN=1` 两种参数下各跑一次综合，看 axis_map 的 LUT/DSP 计数与逻辑级数（Gowin 的 Report → Logic Level）。若 `INTERP_EN=1` 时 DSP/LUT 暴涨且级数 +10 ⇒ 这条雷已证实。
- **来源**：TORCH-2【P1-6】
@@@END
@@@PRIO=P1|SRC=TORCH-2|ORIG=P1-7|MOD=rtl/w3b/note_manager.v
### 把 same_idx 的 32 级优先链改成两级归约
- **位置**：rtl/w3b/note_manager.v:696-702、:794、:1192-1203；tb/w3b/tb_note_manager.sv；sim/evidence/gowin_m0_timing.txt
- **现状**：
```verilog
reg [IDX_W-1:0] same_idx;
integer qi;
always @(*) begin
    same_idx = {IDX_W{1'b0}};
    for (qi = POLY_TARGET - 1; qi >= 0; qi = qi - 1)
        if (same_hit[qi]) same_idx = qi;
end
```
- **为什么是问题**：语义上这是"取最低索引的 `same_hit`"（降序扫描 + 覆盖 ⇒ 最后一次赋值 = 最小索引）。综合器要实现的是一串 `if (same_hit[k]) same_idx = k;` 的级联；若综合器不把它识别为优先编码器，就会落成 **32 级串联的 5 位 mux 链**；即使识别成优先树，也是 5 级 + 32 输入的归约。这是本项目反复强调的那一类："看起来并行、被综合成串行链"。⚠️ 没有综合报告来证明它实际是链还是树 ⇒ 这一条必须由综合/布局报告确认，在确认前只能标为【结构性风险，未证实】。⚠️ 同族的还有 note_manager.v:794 注释自述的"升序扫描 + 严格优于"（`cand_better`）—— 那条已经被 `d449504`（"note_manager 扫描预译码"）优化过一次，见 P1-8。
- **改法**（两级归约，深度从 32 降到 8+4）：
```verilog
// 4 组 × 8 个，组内取最低，再在 4 个组结果里取第一个有效组
// 组内：wire [IDX_W-1:0] g_lo[0:3]; wire g_any[0:3];
//   for (l = 7; l >= 0; l = l-1) if (same_hit[g*8+l]) g_lo[g] = g*8+l;  // 8 级
// 组间：same_idx = g_any[0] ? g_lo[0] : g_any[1] ? g_lo[1] : ...         // 4 级
```
或者直接用 `casez` 对 `same_hit` 的 one-hot 做 priority 编码（`casez` 在多数综合器上会走优先树）。
- **预期**：收益 = 若当前真是 32 级链，可省 ~4~5 级 LUT；代价 = 多写约 15 行（0 面积增量，甚至更小）；回归风险 = 低（语义完全等价，tb_note_manager 可守）。
- **怎么验**：①综合报告的 Logic Level（对比改前后）；②若可达，用 tb/w3b/tb_note_manager.sv 在同一拍让多个 voice 的 `same_hit` 同时为 1，断言 `same_idx` == 最小索引（这是语义判据，两版都应绿 ⇒ 它守的是等价性，⛔ 不守时序）。
- **来源**：TORCH-2【P1-7】
@@@END
@@@PRIO=P1|SRC=TORCH-2|ORIG=P1-8|MOD=rtl/w3b/note_manager.v
### 把 32 voice 扫描的 scan_merge 串行 OR 链改成平衡树并拆属性向量
- **位置**：rtl/w3b/note_manager.v:714-740、:754-801、:754-755；sim/evidence/gowin_m0_timing.txt；commit d449504；tb_note_manager / tb_pool_by_src / tb_nm_no_leak / tb_transpose
- **现状**：
```verilog
// rtl/w3b/note_manager.v:714-740
(* syn_preserve = 1 *) reg [POLY_TARGET-1:0] scan_sel;
localparam integer SCAN_GROUPS = (POLY_TARGET + 7) / 8;
localparam integer SCAN_ATTR_W = 5 + AXIS_W + 3 + ENV_W + AGE_W;   // = 5+4+3+16+16 = 44
(* syn_keep = 1 *) wire [SCAN_ATTR_W-1:0] scan_group [0:SCAN_GROUPS-1];
wire [SCAN_ATTR_W-1:0] scan_merge [0:SCAN_GROUPS];
assign scan_merge[0] = {SCAN_ATTR_W{1'b0}};
            assign leaf[scan_l] = {SCAN_ATTR_W{1'b0}};
            assign scan_group[scan_g] = leaf[0] | leaf[1] | ... | leaf[7];
            assign scan_merge[scan_g+1] = scan_merge[scan_g] | scan_group[scan_g];
// :754-755  —— 44 位属性一次取回
assign {cand_hold, cand_pool, cand_free, cand_gate, cand_active,
        cand_axis, cand_src, cand_env, cand_age} = scan_merge[SCAN_GROUPS];
```
- **为什么是问题**：组合锥：`scan_sel`(32 位 one-hot FF) → `{44{scan_sel[k]}} & attr[k]`（1 级 AND）→ 组内 8 路 OR（3 级）→ `scan_merge` **串行 4 级 OR**（SCAN_GROUPS=4）→ `cand_cls`/`cand_foreign`（`cand_axis==cur_axis` 4 位比较 + `cand_src!=cur_src` 3 位比较，1~2 级）→ `cand_ok`/`cand_better`（2 级）→ `best_*`(FF) ⇒ 合计约 **10~12 级 LUT**，每拍扫 1 个 voice，32 拍扫完。【结构性】，而且已经被 PnR 证实为关键路径族：commit `d449504` "fix(timing): clk_sys 50.040 → 53.425 MHz（+6.85%）—— note_manager 扫描预译码 + test_mode_ctrl 译码去共享【代修】" —— 这次优化的对象就是这段代码（`scan_sel` 预译码 + `SCAN_GROUPS`）。⚠️ 但注意 PnR 噪声：+6.85% 是那一次布局的结果；同源重跑差 2~3 MHz ⇒ "这条是结构性关键路径族"成立，"它现在还剩多少余量"不成立（必须看当次报告）。⚠️ `(* syn_preserve=1 *)` 与 `(* syn_keep=1 *)` 是故意阻止综合器优化掉这一层（保 one-hot 与组边界）—— 这是一把双刃剑：它保住了译码深度可控，但也禁止了综合器把它重构成更浅的树。
- **改法（可选，收益需先测）**：1. `scan_merge` 的串行 4 级 OR 链改成平衡树（`(g0|g1) | (g2|g3)`）⇒ 从 4 级降到 2 级，省 ~2 级，零代价。2. 把 44 位属性向量拆成"先只归约比较用的字段"（`hold/pool/free/gate/active/axis/src` = 15 位）与"只在选中后读的字段"（`env/age` = 32 位）—— 现在 `env/age` 每一拍都参与 8 路 OR + 4 级链，而它们只在 `cand_cls` 判定后才用；拆开后主锥只归约 15 位 ⇒ 每级 LUT 数大幅下降，级数也少 1~2 级；⚠️ 代价 = env/age 的读取要按 `scan_sel` 再选一次（又是一级 mux）⇒ 需实测权衡。3. ⛔ 不要动 `(* syn_preserve *)`/`(* syn_keep *)`，除非有综合报告证明它们反而有害。
- **预期**：改法 1 = 省 2 级 LUT、0 面积；改法 2 = 每级 LUT 数明显下降，但多一级 mux（需实测）；回归风险 = 中（这段是 note_manager 的分配核心 ⇒ 必跑 tb_note_manager / tb_pool_by_src / tb_nm_no_leak / tb_transpose）。
- **怎么验**：这条只能靠 PnR：跑一次干净 PnR，读 sim/evidence/gowin_m0_timing.txt 里 `u_note_manager` 的最差路径，确认端点是否落在 `cand_better`/`best_*`。⚠️ 若改前后 Fmax 差异 < 2 MHz ⇒ 落在布局噪声内，判为无效（这是本项目自己的判据）。
- **来源**：TORCH-2【P1-8】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-9|MOD=rtl/w3c/seq_arb.v,rtl/w3c/evt_merge.v
### 记档：seq_arb/evt_merge 溢出整拍全丢（不可达，只补可见性）
- **位置**：rtl/w3c/seq_arb.v:376-385；rtl/w3c/evt_merge.v:361-374；rtl/w3a/event_extract.v:319-343；rtl/w3c/looper.v:893；rtl/w3b/note_manager.v:37、:39；tb/w3c/tb_seq_arb.sv
- **现状**：
```verilog
// rtl/w3c/seq_arb.v:376-385  —— 溢出：整拍全丢（含 note_off），只记数
end else begin
    // 🔴 **溢出**：⭐ 丢弃并**记数 + 置 sticky 标志**（⛔ 不静默）
    overflow_o <= 1'b1;
    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                   : (drop_cnt_o + push_n);
    cnt_q <= cnt_after_pop;
end
// rtl/w3a/event_extract.v:319-343  —— 唯一有"重试"的地方：只有 push 成功才清 key_on
```
- **为什么是问题**：event_extract 的 `note_off` 有重试机制（推不进 ⇒ `key_on` 保持 1 ⇒ 下一帧重试，帧率 2 kHz ⇒ ≤500 µs）。但一旦事件离开 event_extract，进入 seq_arb(6 深)/evt_merge(6 深)/note_manager(32 深)，任何一次溢出都是"永久丢失"，没有任何重试。丢 `note_off` 的后果 = 永久挂音（note_manager 只在收到 KIND_OFF 时清 `gate_r`）。可达性（诚实评估）：seq_arb `DEPTH=6`，每拍最多弹 1 条，要溢出需 `cnt_after_pop ≥ 4` 且 `push_n ≥ 3`；稳态速率 live ≤ 1/帧（500 µs）、score ≤ 1/帧、demo 只在无人时发 ⇒ 稳态不可达。evt_merge `DEPTH=6`，三源同拍才 `push_n=3`；B（节拍器）≤ 1/960 tick、C（looper）≤ 1/PPQN tick（looper.v:893：PPQN=960 ⇒ 120 BPM 时 **0.52 ms/条**）⇒ 结构上不可达。note_manager `DEPTH=32` vs 最坏突发 18（note_manager.v:37,39）⇒ 有 14 槽余量。⇒ 判定：不可达，属"理论缺口"。⚠️ 但代价是零（计数器已有），所以值得把"丢 note_off 必须能看见"这条在 top 层真正接出来（见 P2-10）。
- **改法**：⛔ 不建议为不可达分支加复杂度（这正是本项目 K-91 同族的纪律）。建议只做一件事：把 `overflow_o`/`drop_cnt_o` 在 top.v 里引到某个可见的地方（LED / UART 诊断字节），让"理论上会挂音"变成"上板能看见"。
- **预期**：把已知边界变成可见；代价 0（复用已有计数器）。
- **怎么验**：tb/w3c/tb_seq_arb.sv 补一个"把 FIFO 灌满再同拍来 3 条（含 1 条 note_off）"的用例，断言 `drop_cnt_o` 增加且 note_off 确实丢了 ⇒ 把这个已知行为钉成契约（⛔ 不是修它）。
- **来源**：TORCH-2【P2-9】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-10|MOD=rtl/top.v
### 把 K-106 的 overflow/drop 计数器接到可见处
- **位置**：rtl/top.v:3036-3037、:3177-3178、:3464-3470、:3755-3761、:3905-3908、:3981-3984、:3589、:3655、:3979-3980
- **现状**：
```verilog
// rtl/top.v:3036-3037  声明
wire        ee_slide_v, ee_two_v, ee_ovf;
wire [7:0]  ee_lost;
// rtl/top.v:3177-3178  连接（此后全文件再无引用）
.overflow_o       (ee_ovf),
.lost_cnt_o       (ee_lost)
// rtl/top.v:3464-3470  声明；:3755-3761 连接 —— 之后无引用
wire [15:0] sa_collision_cnt;
wire [15:0] sa_merged_cnt;
wire [15:0] sa_drop_cnt;
wire        sa_overflow;
// rtl/top.v:3905-3908 声明；:3981-3984 连接 —— 之后无引用
wire [15:0] mg_collision_cnt;
wire [15:0] mg_merged_cnt;
wire [15:0] mg_drop_cnt;
wire        mg_overflow;
```
- **为什么是问题**：每个信号恰好出现 2 次 = 声明 + 端口连接（grep 结果）。top.v:3979-3980 的注释自述"⚠️ 未引到引脚，但综合时不要被优化掉：它们驱动的是寄存器 → 会保留；⭐ 上板可用调试核读"。⚠️ 但如果当前工程里没有例化任何调试核（在 top.v 的例化清单里没看到），这些寄存器就是纯死寄存器：占 FF、占布线、上板一个字都读不出来 ⇒ "丢音必须能看见"这条纪律在交付层面是空头支票。
- **改法**（选一，按成本排序）：最省：把 `ee_ovf | sa_overflow | mg_overflow | looper_overflow` 或起来接到一个已有的空闲 LED（top.v 已有灯带/心跳 LED 通路）⇒ 1 个 LUT + 1 根线。次省：把它们打包成一个字节，挂到已有的 UART 诊断命令（top.v 里已经有 'P'/'N'/'Q' 这类探针命令框架）。最全：接 Gowin 在线逻辑分析仪（⚠️ 会占资源，且必须单独跑 PnR）。
- **预期**：收益 = 把 4 条"容量有限"的路径从"不可见"变成"可发现"；代价 = 1 LUT + 1 根引脚（若走 LED）。
- **怎么验**：tb/w3c/tb_seq_arb.sv 灌溢出 ⇒ 断言那个 LED 信号 = 1。
- **来源**：TORCH-2【P2-10】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-11|MOD=rtl/w3a/event_extract.v,rtl/w3a/axis_map.v
### 把 event_extract 的 FW 改成派生，并纠正 K-91 的错误机制描述
- **位置**：rtl/w3a/event_extract.v:163-164、:305、:307；rtl/w3a/axis_map.v:94-99、:99；rtl/w3b/note_manager.v:558；review/raw/_probe_intsel.v
- **现状**：
```verilog
// rtl/w3a/event_extract.v:163-164  —— FW 是【写死】的，⛔ 不是 $clog2(FIFO_D)
localparam integer FIFO_D = 4;
localparam integer FW     = 2;      // ⭐ 指针位宽（$clog2(4)）
// :305,307
refr  [scan_axis] <= REFRACT_N[15:0];
...
if (q_cnt < FIFO_D[FW:0]) begin
// rtl/w3a/axis_map.v:94-97  —— 🔴 机制描述是【错的】
//      ⇒ 🔴 **`N_KEY` 是 `integer`，Verilog-2001 ⛔ 不允许对 `integer` 参数做位选**
//      ⇒ 实测 `N_KEY[3:0]` 求值为 **0**（⛔ 不是 16）⇒ ⭐ **钳位恒成立**
我实测的探针（review/raw/_probe_intsel.v，iverilog 14.0 -g2001）：
FIFO_D[FW:0]      = 4 (expect 4)
FIFO_D[2:0]       = 4 (expect 4)
REFRACT_N[15:0]   = 60 (expect 60)
GREEN: FIFO_D[FW:0] == 4 => 该处安全
GREEN: REFRACT_N[15:0] == 60 => 该处安全
```
- **为什么是问题**：`integer` 的位选是合法的（IEEE 1364-2001 允许对 32 位整数做位选），iverilog 实测求值正确。axis_map 当年那次"`N_KEY[3:0]` 得 0"的真因是位宽不够：`N_KEY = 16 = 5'b10000`，取 `[3:0]` ⇒ 截断成 0（不是"不允许位选"）⇒ K-91 那条纪律的结论对、理由错。⚠️ 理由错是有代价的：它让后来的人以为"只要换成 localparam 就安全"，而真正的风险是"位选宽度 < 参数所需位宽"。按这个真机制复查本链的每一处位选：`event_extract.v:307` `FIFO_D[FW:0]`, `FW=2`（**写死**）、参数值 4、需要 3 位 ⇒ ✅ 现在安全（4 < 8）；`event_extract.v:305` `REFRACT_N[15:0]`、60、6 位 ⇒ ✅ 安全；`note_manager.v:558` `FIFO_DEPTH[FW:0]`, `FW=clog2(FIFO_DEPTH)`、32、6 位 ⇒ ✅ 结构上恒安全（`[k:0]` 恰好容纳 `2^k`）；`axis_map.v:99` `N_KEY[KW-1:0]`（已改成先落 localparam）、16、5 位 ⇒ ✅ 安全。
- **改法**：1. event_extract.v:164 把 `FW` 改成派生：`localparam integer FW = (FIFO_D <= 1) ? 1 : $clog2(FIFO_D);`（⚠️ 若 `FIFO_D` 不是 2 的幂，`q_cnt < FIFO_D` 的比较仍正确，但指针回绕会错 ⇒ 建议同时加自检）。2. axis_map.v:94-97 把机制描述改成真因（"位选宽度不足 ⇒ 截断"，并点名 `16[3:0] == 0`）—— ⚠️ 这条注释现在是 K-91 的"权威出处"，错下去会继续误导。3. 加一条通用自检（可放在 tb 侧）：对每个"参数位选"断言 `位选宽度 >= $clog2(参数+1)`。
- **预期**：收益 = 消除一个"改一个常量就全静默"的雷；代价 = 0 面积（纯参数）；回归风险 = 0（FW 值不变）。
- **怎么验**：把 event_extract.v:163 的 `FIFO_D` 临时改成 8（⛔ 不改 `FW=2`），跑 tb/w3a/tb_event_extract.sv ⇒ `q_cnt < 8[2:0]=0` 恒假 ⇒ 一个事件都发不出来 ⇒ 必红；改 `FW` 成派生后 ⇒ 同一实验必绿。这就是"能红"的证明。
- **来源**：TORCH-2【P2-11】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-12|MOD=rtl/top.v,rtl/w3a/axis_map.v
### 清理 axis_map 的两条顶层冗余线与 4 条内部死链
- **位置**：rtl/top.v:3013-3014、:3284-3285；rtl/w3a/axis_map.v:113、:183、:189、:519、:526-534、:513-515
- **现状**：
```verilog
// rtl/top.v:3013-3014  声明
wire        am_valid;
wire [3:0]  am_axis;
// rtl/top.v:3284-3285  连接 —— 全文件再无引用（top 用的是 am_vld_out/am_axis_out/am_inc_out）
.phase_valid_o(am_valid),
.axis_id_o    (am_axis)
// rtl/w3a/axis_map.v:513-515  —— 作者自己承认
//   ⚠️ **`key_idx`/`key_sel`/插值链【保留不删】** ——
//      ⭐ 留给将来的"**滑弦**"功能 ...
//      📌 它们现在**没有消费者**，综合器会**自动优化掉**（⛔ 不占资源）。
```
- **为什么是问题**：`am_valid` = `pos_valid_i`（= `am_vld_in`）的直通；`am_axis` = `axis_id_i`（= `am_axis_in`）的直通 ⇒ 与已有的 `am_vld_in`/`am_axis_in` 完全同值 ⇒ 纯冗余线。axis_map 内部：`key_idx`(:113)、`key_sel`(:183)、`sel_key`(:189)、`inc_hi`(:527)、`inc_delta`(:531)、`interp_raw`(:532)、`interp`(:533) 全部无消费者（`frac ≡ 0`）⇒ 死逻辑。
- **改法**：top.v：把 `am_valid`/`am_axis` 两个 wire 与两处端口连接删掉（端口保留、接 `()`），或加一行注释说明"这两个组合输出故意不用，用的是寄存后的 `am_*_out`"（否则下一个人会以为漏接了）。axis_map：⛔ 不要删（作者有意留给滑弦）⇒ 但必须按 P1-6 用 generate 门控，否则"死逻辑"会在某天变成"活乘法器"。
- **预期**：收益 = 消除误导（读代码的人不会以为这两条是有效通路）；代价 = 0（死逻辑本来就被综合掉）；回归风险 = 0。
- **怎么验**：综合报告的 Unused/Removed 清单，或读 top.v 的网表 —— `am_valid`/`am_axis` 应出现在"被优化掉"的列表里。
- **来源**：TORCH-2【P2-12】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-13|MOD=rtl/top.v,rtl/w3c/play_seq.v
### 记档：play_seq 从未被例化，仲裁速率论证用错了对象
- **位置**：rtl/top.v:4821、:4838；rtl/w3c/seq_arb.v:34；rtl/w3c/evt_merge.v:52；rtl/w3c/play_seq.v；rtl/w3c/guide_lamp.v；rtl/w3c/led_data.v:11；rtl/w3c/drum_gen.v:39；rtl/top.v:3725-3735
- **现状**：
```verilog
// rtl/top.v:4821
//      · `guide_key`（哪些键该按）→ 正确来源是 `play_seq`，但**尚未例化**（甲）。
// rtl/top.v:4838
.guide_key_i     (16'd0),            // ⭐ 占位：待 play_seq（甲）
grep -n "play_seq" rtl/ 的全部命中：top.v（3 处，全是注释/占位）、evt_merge.v:52（注释）、
drum_gen.v:39（注释）、guide_lamp.v（5 处，注释 + 端口名）、led_data.v:11（注释）、play_seq.v 自己、seq_arb.v:34（注释）
⇒ play_seq 在 rtl/ 里没有任何例化点。
```
- **为什么是问题**：seq_arb 的"源 2 = 曲谱"实际接的是 `evt_uart_rx`（top.v:3725-3735），而 play_seq（64 位事件流 + tick 调度 + 变速）是一块悬空模块。⚠️ seq_arb.v:34 与 evt_merge.v:52 的速率论证都写着"曲谱 `play_seq` ≤1 条/tick" —— 这个论证的对象不是当前链上的那个源。当前源（evt_uart_rx）的速率上限是 UART 波特率 / 9 字节（500 kbps ⇒ 9 字节 ≈ 180 µs/条 ⇒ **≈5.5k 条/s**），比 play_seq 的 1/PPQN tick 快得多 ⇒ **evt_merge/seq_arb 的"深度够不够"论证，用错了被论证的对象。**
- **改法**：1. 把 seq_arb.v:34 / evt_merge.v:52 的速率论证改成按 `evt_uart_rx` 的真实上限重算（500 kbps ⇒ 最短 9 字节连续帧 ≈ 180 µs/条 ⇒ 1 条/9000 拍 ⇒ 仍远低于 1 条/拍 ⇒ 结论不变，但依据要换）。2. 若 play_seq 是已废弃的路线 ⇒ 在 play_seq.v 头部写明"未例化，被 evt_uart_rx 取代"，⛔ 否则下一个人会照任务清单去审一条不在链上的通路。
- **预期**：收益 = 消除"审错对象"；代价 = 0（纯注释）；回归风险 = 0。
- **怎么验**：`grep -rn "play_seq" rtl/ | grep -v "^rtl/w3c/play_seq.v"` ⇒ 只应看到注释，若出现例化 ⇒ 说明已接线（那时本条的速率论证就要重做）。
- **来源**：TORCH-2【P2-13】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-14|MOD=rtl/top.v
### 把键盘打鼓映射表注释更新为实际常量
- **位置**：rtl/top.v:3774-3779、:3798-3801、:3996-3997、:4205、:3783-3786、:3788-3789；rtl/w3b/note_manager.v:835-836；rtl/w3c/drum_gen.v:163-167；tb/w3c/tb_key_drum.sv
- **现状**：
```verilog
// rtl/top.v:3776-3779  —— ⚠️ 注释表（旧值）
//      | `2'd0` | 0~3   | 板1 右两列 | ⭐ **嗵鼓** | `12_884_902`（≈150 Hz）|
//      | `2'd1` | 4~7   | 板1 左两列 | ⭐ **底鼓** | `6_442_451`（≈75 Hz）|
//      | `2'd2` | 8~11  | 板2 右两列 | ⭐ **军鼓** | `17_179_869`（≈200 Hz）|
//      | `2'd3` | 12~15 | 板2 左两列 | ⭐ **踩镲** | `171_798_691`（≈2000 Hz）|
// rtl/top.v:3798-3801  —— ✅ 实际生效的常量（新值）
wire [31:0] key_drum_inc = (key_drum_sel == 2'd0) ? 32'd17_895_697    // ⭐ 嗵鼓 ≈200 Hz
                         : (key_drum_sel == 2'd1) ? 32'd5_368_709     // ⭐ 底鼓 ≈60 Hz
                         : (key_drum_sel == 2'd2) ? 32'd42_949_673    // ⭐ 军鼓 ≈480 Hz
                         :                          32'd171_798_691;  // ⭐ 踩镲 ≈1920 Hz
// rtl/top.v:3996-3997  —— note_manager 侧；:4205 同值给 oscillator_bank
.DRUM_KICK_MAX (10_000_000),
.DRUM_TOM_MAX  (20_000_000),
```
- **为什么是问题**：分类判据（note_manager.v:835-836）：`cmt_kick = inc < 10M`；`cmt_tom = 10M ≤ inc < 20M`。按注释表：军鼓 `17_179_869` 落在 `[10M, 20M)` ⇒ 被判成嗵鼓（🔴 静默换乐器）；底鼓 `6_442_451` < 10M ⇒ 底鼓 ✅；嗵鼓 `12_884_902` ⇒ `[10M,20M)` ⇒ 嗵鼓 ✅；踩镲 ✅。按实际代码：军鼓 `42_949_673` ≥ 20M ⇒ 既非底鼓也非嗵鼓 ✅（符合注释表第 3 列的意图）⇒ 代码是对的、注释是过时的；但 top.v:3783-3786 又写"这 4 个常量必须与 drum_gen.v 的 `INC_*` 逐字一致 …抄错一个数就静默变成另一件乐器" —— 而这 4 个数的"权威副本"在注释里是错的。
- **改法**：1. 把 top.v:3776-3779 的表格更新为实际值（`17_895_697 / 5_368_709 / 42_949_673 / 171_798_691`），⚠️ 整行替换（本项目源码编辑纪律：`old_string` 必须覆盖整行，否则会留残行）。2. 把 drum_gen.v:163-167 的 `INC_*` 与 top.v 的这 4 个数做单一来源（提到参数或 include）—— ⚠️ top.v:3788-3789 自己说"本处是【有意重复】的常量 —— 单一来源修法留待后续" ⇒ 这条是已知债，建议按 tb_key_drum.sv 已有的"直接拿 `u_drum_gen.INC_*` 比对"手法扩成 4 件乐器全覆盖。
- **预期**：收益 = 消除"照注释改就换乐器"；代价 = 0（注释）/ 少量重构（单一来源）；回归风险 = 低（tb_key_drum 已守）。
- **怎么验**：tb/w3c/tb_key_drum.sv 加一条：断言 `top.key_drum_inc[sel]` 与 drum_gen 对应乐器的 `INC_*` 逐值相等（4 个 sel 全覆盖）⇒ 现在应该绿（代码一致）；若把注释表的值填回代码 ⇒ 必红（这就是"注释有毒"的证明）。
- **来源**：TORCH-2【P2-14】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-15|MOD=rtl/w3b/note_manager.v,rtl/top.v
### 裁定 T3_EN 的交付档并回写冲突文档
- **位置**：rtl/w3b/note_manager.v:65-81、:65-70、:1559-1577、:1564-1566；rtl/top.v:329、:4014-4015；sim/gowin_build.ps1；sim/evidence/gowin_m0_timing.txt
- **现状**：
```verilog
// rtl/w3b/note_manager.v:65-70
//   📌 **为什么要有它**（⭐ 详见 `files/20-代码/T3-后续计划-20261003.md` §三 `P1`）：
//      ⭐ T3 变调**功能正确、但装不下** —— ⭐ 32 lane 输出旁路 mux = **1025 LUT**
//      ⇒ 🔴 布线失败 `PR0004 659 unrouted`；⚠️ 三条减重路（读侧 mux 1025 /
//      写侧 mux ~1400 / 每 lane 乘法器 DSP 98%）**全部实测不通**。
//      ⇒ ⭐ 用户 2026-10-03 拍板"**暂不做大改**" ⇒ ⭐ **把 T3 关起来，让主线恢复可交付** ✅
// rtl/top.v:329 / :4014-4015
parameter integer T3_ENABLE               = 1
// ⭐⭐ 2026-10-04：⭐ **T3 变调总闸**（⭐ 交付档 = 1，⭐ 见 `T3_ENABLE` 的说明 ✅）
.T3_EN       (T3_ENABLE)
// rtl/w3b/note_manager.v:1564-1566  —— T3_EN=1 的一条减重路自述
//        （⭐ 实测数组版 `T3_EN=1`：`CLS 85%` · **490 根不布通**）✅
```
- **为什么是问题**：note_manager 的参数默认 = 0，文件头记录的用户裁决 = "把 T3 关起来"，且记录了两次布线失败（`PR0004 659 unrouted`、`490 根不布通`、`CLS 85%`）；而 top.v 的实际交付档 = `T3_ENABLE = 1` ⇒ T3 变调核心（含 32 lane 旁路 mux）参与综合 ⇒ 两者不可能同时为真。而战场事实给的 CLS 是 78% / 81%（都 < 85%），说明当前这次 PnR 要么 T3 的减重实现（note_manager.v:1559-1577 的"共享乘法器 + 轮转"）真的把 1025 LUT 压下去了，要么那些实测数字对应的是 `T3_ENABLE=0` 的档。⚠️ 无法在本次会话里裁定（⛔ 不跑 PnR、⛔ 不改 RTL）⇒ 按本项目"代码即地面真相"的判据：地面真相 = `T3_ENABLE=1`，但文件头那段"用户拍板关掉"的记录与它直接冲突 ⇒ 必须由用户/负责人裁定并回写文档。
- **改法（先查证，再改）**：1. 查证（一次性、可判真假）：跑一次干净 PnR（sim/gowin_build.ps1），看 ①有没有 `PR0004`/`unrouted`；②CLS 是多少；③Report → Logic Level 里 `u_note_manager` 的最差路径端点是不是 `phase_tr`/`semi_cur` 那族。2. 若 T3_EN=1 真的不布通 ⇒ top.v:329 改 `T3_ENABLE = 0`（与文件头一致），并把 top.v:4014 的注释"交付档 = 1"改成 0。3. 若 T3_EN=1 布得通 ⇒ 把 note_manager.v:65-70 那段改成历史记录（加"⚠️ 已于 2026-10-0X 用共享乘法器 + 轮转版本解决，交付档 = 1"），否则它会永久误导。
- **预期**：若 T3 必须关 ⇒ 收益 = 恢复可交付（CLS 大幅下降、余量变厚）；代价 = 变调功能不可用。若 T3 能开 ⇒ 收益 = 保住功能；代价 = 0（只改注释）。
- **怎么验**：`grep -c "PR0004" sim/evidence/gowin_m0_timing.txt` + 看 `Actual Fmax` 与 CLS。这是唯一能裁定的判据。
- **来源**：TORCH-2【P2-15】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-16|MOD=rtl/top.v
### 处理 event_lost_clr_i 硬接 0（或注明是故意）
- **位置**：rtl/top.v:4141、:49；rtl/w3b/note_manager.v:966-973
- **现状**：
```verilog
// rtl/top.v:4141
.event_lost_clr_i  (1'b0)
// rtl/w3b/note_manager.v:966-973
lost_cnt_r    <= fifo_drop ? {{(EVT_LOST_CNT_W-1){1'b0}}, 1'b1}
                           : (event_lost_clr_i ? {EVT_LOST_CNT_W{1'b0}} : lost_cnt_r);
...
if (fifo_drop)                  lost_sticky_r <= 1'b1;   // ⭐ sticky：只置位，⛔ 不自动清
```
- **为什么是问题**：`EVT_LOST_CNT_W = 8` ⇒ 计数饱和于 255；sticky 只置位。top.v:49 的注释承认"已有例化不接新输入也合法（`event_lost_clr_i` 悬空=恒 0 ⇒ 只置位不清）" —— 但 top.v 是显式硬接 0（比悬空更明确）⇒ 上板后无法把"丢过"复位，即"开机自检丢过 2 条"这件事会永久显示，无法区分"这次开机丢的"和"上次开机丢的"。
- **改法**：接一个可写的软复位（例如已有 UART 命令 'C'/某个空闲命令的脉冲），或至少在 top.v:4141 旁注明"故意恒 0：让 sticky 从开机起一直有效，便于上板发现历史丢音"。⚠️ 后者是"可接受的取舍"，但必须写清，否则看起来像漏接线。
- **预期**：收益 = 能区分"本次/历史"；代价 = 1 根线（若接命令）；回归风险 = 0。
- **怎么验**：tb_note_manager 里先制造一次 `fifo_drop`，再拉 `event_lost_clr_i` 一拍，断言 `lost_cnt_o` 归 0 且 sticky 归 0 ⇒ 当前（顶层硬接 0）时这条在顶层必红。
- **来源**：TORCH-2【P2-16】
@@@END
@@@PRIO=P2|SRC=TORCH-2|ORIG=P2-17|MOD=rtl/w3c/evt_merge.v
### 统一 evt_merge 三路 push 的 Z 防护口径
- **位置**：rtl/w3c/evt_merge.v:220-221、:229、:222-228；tb/w3c/tb_evt_merge.sv、tb_evt_merge_diff.sv
- **现状**：
```verilog
// rtl/w3c/evt_merge.v:220-221  —— 裸取
wire push_a = a_valid_i;
wire push_b = b_valid_i;
// rtl/w3c/evt_merge.v:229  —— 硬化（注释解释了为什么）
wire push_c = (c_valid_i === 1'b1);
```
- **为什么是问题**：`c_valid_i` 的硬化是为了"老 tb 不接新端口 ⇒ 悬空 z ⇒ 不能让它把 `push_n` 变成 x"（注释 :222-228）。但 `a_valid_i`/`b_valid_i` 走的是裸取：若某个老 tb 不接它们（悬空），`push_a = z` ⇒ `(push_a ? 2'd1 : 2'd0)` 在 z 下求值为 x ⇒ `push_n` 变 x ⇒ 整个 FIFO 计数变 x。⚠️ 现实中 `a_valid_i` 接的是 `seq_arb.evt_valid_o`（寄存输出，恒 0/1）⇒ 顶层无风险；但 evt_merge 是被单独例化的 tb 对象（tb/w3c/tb_evt_merge.sv、tb_evt_merge_diff.sv）⇒ 口径不一致本身就是坑。
- **改法**：统一成 `=== 1'b1`（A/B/C 三条一致），并在注释里写明"三条源一律：只有明确的 1 才算有事件"。
- **预期**：收益 = 口径统一、消除"z 传 x"这一类不确定性；代价 = **+2 个比较器**（约 2 LUT）；回归风险 = 低（对已接线的 tb 行为不变）。
- **怎么验**：写一个故意不接 `a_valid_i` 的例化（悬空），断言 `evt_valid_o` 不出现 x（用 `$isunknown` 或 `!== 1'b0/1'b1` 判）⇒ 改前必红。
- **来源**：TORCH-2【P2-17】
@@@END
@@@PRIO=P3|SRC=TORCH-2|ORIG=P3-18|MOD=rtl/w3a/param_extract.v
### 把 param_extract 的 emit 优先编码器参数化（现在 SAW-3/SAW-4 会负复制）
- **位置**：rtl/w3a/param_extract.v:303-318、:304-306、:158；rtl/top.v:3294；tb/w3a/tb_param_extract.sv
- **现状**：
```verilog
// rtl/w3a/param_extract.v:304-306
else if (AXIS_N > 1  && dt_valid[1])  begin emit_axis <= {{(SAW-1){1'b0}},1'b1}; emitting <= 1'b1; end
else if (AXIS_N > 2  && dt_valid[2])  begin emit_axis <= {{(SAW-2){1'b0}},2'd2}; emitting <= 1'b1; end
else if (AXIS_N > 3  && dt_valid[3])  begin emit_axis <= {{(SAW-2){1'b0}},2'd3}; emitting <= 1'b1; end
// ...
else if (AXIS_N > 12 && dt_valid[12]) begin emit_axis <= {{(SAW-4){1'b0}},4'd12}; emitting <= 1'b1; end
```
- **为什么是问题**：`SAW = $clog2(AXIS_N)`（:158）。当 `AXIS_N = 8` ⇒ `SAW = 3` ⇒ 表达式里出现 `{{(SAW-4){1'b0}}, 4'd12}` = `{{-1{1'b0}}, 4'd12}` ⇒ 复制次数为负 ⇒ Verilog-2001 里这是非法的常量表达式。`AXIS_N > 12` 是常量假，综合器可能把整条分支剪掉；但精化（elaboration）阶段仍需先构造该表达式，多数编译器（含 iverilog）会直接报错 ⇒ 该模块名为参数化、实际只能取 `AXIS_N ≥ 16`。⚠️ 没有实测（本次未编译 `AXIS_N=8` 的变体）⇒ 标为"待实测确认"。✅ 当前 top.v:3294 传 `.AXIS_N(16)` ⇒ 交付档无影响。
- **改法**：把这 16 条 `else if` 换成参数化的循环 + 两级归约（与 P1-7 同一个改法）：
```verilog
integer e;
always @(*) begin
    emit_axis = {SAW{1'b0}}; emitting_n = 1'b0;
    for (e = AXIS_N-1; e >= 0; e = e - 1)
        if (dt_valid[e]) begin emit_axis = e[SAW-1:0]; emitting_n = 1'b1; end
end
```
⚠️ 但注意：这个写法会引入 P1-7 那类优先链 ⇒ 正确做法是两级归约（组内 + 组间），既参数化、深度又只有 `clog2` 级。
- **预期**：收益 = 恢复真正的参数化（`AXIS_N = 8` 可用）+ 深度从 16 级降到 4+2 级；代价 = 重写约 20 行；回归风险 = 中（必须跑 tb_param_extract 的多轴同帧用例）。
- **怎么验**：`iverilog -g2001 -DAXIS_N=8` 编译 param_extract.v 的一个薄 wrapper ⇒ 改前应报"replication count negative/zero"；改后应编译通过。
- **来源**：TORCH-2【P3-18】
@@@END
@@@PRIO=P3|SRC=TORCH-2|ORIG=P3-19|MOD=rtl/w3a/axis_snapshot.v
### 给 axis_snapshot 的首帧 delta 加 prev_valid 屏蔽
- **位置**：rtl/w3a/axis_snapshot.v:85、:104-110、:148-151、:211-212；rtl/top.v:3162；rtl/w3a/event_extract.v:404-407；tb/w3a/tb_axis_snapshot.sv
- **现状**：
```verilog
// rtl/w3a/axis_snapshot.v:104-110
if (!rst_n) begin
    for (wi = 0; wi < AXIS_N; wi = wi + 1) begin
        cur [wi] <= {POS_W{1'b0}};
        prev[wi] <= {POS_W{1'b0}};
    end
    seen <= {AXIS_N{1'b0}};
    first_ch_of_frame <= 1'b0;      // ⚠️ 复位为 0 ⇒ 首帧 ch0 不会锁 prev
end
```
- **为什么是问题**：复位后 `first_ch_of_frame = 0` ⇒ 第一帧的 `ch0` 不触发 `prev <= cur` ⇒ 首帧的 `delta = cur − 0 = cur`（最大 4095，而非真实的 `cur − prev`）⇒ 后果：首帧 `delta` 是伪值。✅ 当前无害，因为：①event_extract 的 `enable_i` 由 `at_en_ready` 门控（top.v:3162），标定完成前事件层停摆；②`delta_i` 在 event_extract 里只用于阶段 2 的滑音/双音（event_extract.v:404-407 仍是 TODO）⇒ `as_delta` 的 208 位在整条链上没有任何消费者（param_extract 也不收 delta）。⚠️ 但阶段 2 一旦落地，这个首帧伪值就会变成"开机瞬间的伪滑音"。⚠️ 另外 `seen`/`axis_seen_o` 也受同一拍影响（诊断用）。
- **改法**：把 `first_ch_of_frame <= 1'b1;` 放进复位分支（一行）⇒ 首帧 ch0 就锁 `prev`（= 复位后的 `cur` = 0）⇒ 首帧 `delta = cur − 0`，仍然是伪值 —— ⚠️ 因为 `prev` 本来就是 0。真正的修法：加一个 `prev_valid_r`，`delta_o` 在 `prev_valid_r = 0` 时输出 0（"没有上一帧 ⇒ 增量为 0"），并把它作为 delta 的"有效"前提（阶段 2 的滑音判据要一起用）。或（最省）：在 axis_snapshot.v 头部写明"首帧 delta 无意义，消费者必须自己屏蔽"。
- **预期**：收益 = 阶段 2 落地时不会踩到开机伪滑音；代价 = 1 FF（prev_valid_r）+ 13 位 AND；回归风险 = 低（tb_axis_snapshot 的 delta 判据要复核是否依赖首帧值）。
- **怎么验**：tb_axis_snapshot 加一条：复位后只扫一帧，断言 `delta` 全 0（改前：`delta == pos != 0` ⇒ 必红）。
- **来源**：TORCH-2【P3-19】
@@@END
@@@PRIO=P3|SRC=TORCH-2|ORIG=P3-20|MOD=tb/models/evt_merge_ref.v,tb/w3c/tb_evt_merge_diff.sv
### 让 evt_merge_ref 与 RTL 逐字同宽（现在 diff tb 只验算法不验位宽）
- **位置**：tb/models/evt_merge_ref.v:178-179、:233、:247；rtl/w3c/evt_merge.v:182-187、:239-241、:253-255、:230-237；tb/w3c/tb_evt_merge_diff.sv；tb/w3b/tb_integration_consts.sv
- **现状**：
```verilog
// tb/models/evt_merge_ref.v:178-179  —— ref 用 16 位
localparam [15:0] DEPTH_C  = DEPTH;
localparam [15:0] DEPTH_M1 = DEPTH_C - 16'd1;
// :233
                       + (push_c ? 16'd1 : 16'd0);
// :247
wire [15:0] off_c = (push_a ? 16'd1 : 16'd0) + (push_b ? 16'd1 : 16'd0);
// rtl/w3c/evt_merge.v:182-187  —— RTL 已减宽
localparam integer CNT_W = (DEPTH < 2) ? 1 : $clog2(DEPTH + 1);
localparam integer PTR_W = (DEPTH < 2) ? 1 : $clog2(DEPTH);
localparam integer SUM_W = $clog2(DEPTH + 3);
localparam integer OFF_W = 2;
```
- **为什么是问题**：tb/w3c/tb_evt_merge_diff.sv 的价值在于"RTL 与 ref 逐拍差分"。但 ref 的所有中间量都是 16 位，而 RTL 是 `CNT_W/PTR_W/SUM_W/OFF_W` 的窄位 ⇒ 任何只在窄位上才暴露的缺陷（evt_merge.v:230-237 自述的那个经典坑：`wire push_n` 不写位宽 ⇒ 隐含 1 位 ⇒ `1+1=2` 截断成 0 ⇒ "单源正常、一相撞就什么都没发生"）在 diff tb 里永远不会红 —— 因为 ref 侧 `push_n` 是 16 位，`1+1` 得 2，行为"正确" ⇒ diff tb 守的是算法，不守位宽。而本项目历史上恰恰栽在位宽上（evt_merge 第一版、axis_map 的 `N_KEY[3:0]`、tb_axis_snapshot 的 `integer c` 拼接截断 —— 见 tb_axis_snapshot.sv:108-114）。
- **改法**：1. 让 ref 的 `CNT_W/PTR_W/SUM_W/OFF_W` 与 RTL 逐字相同（把 RTL 的 localparam 复制过去），这样"减宽"这件事本身也进入差分范围。2. 或加一个独立的位宽自检 tb：对每个 `wire`/`localparam` 断言"声明宽度 == 语义所需宽度"（机械但有效；本项目已有 tb/w3b/tb_integration_consts.sv 这种"常量一致性" tb 的先例）。
- **预期**：收益 = diff tb 从"守算法"升级到"守算法 + 守位宽"；代价 = ref 改约 6 行；回归风险 = 低（ref 语义不变）。
- **怎么验**：故意把 RTL 的 `push_n` 改回 `wire push_n = ...;`（不写位宽）⇒ 当前 diff tb 必绿（漏抓）；把 ref 也减宽后 ⇒ 同一变异必红。这就是判据。
- **来源**：TORCH-2【P3-20】
@@@END
@@@TOTAL SRC=TORCH-2 COUNT=20 P0=3 P1=5 P2=9 P3=3
