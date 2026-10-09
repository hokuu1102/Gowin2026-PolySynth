@@@PRIO=P0|SRC=ANVIL-01|ORIG=P0-1|MOD=rtl/w3b/note_manager.v
### 修掉力度斜坡的 8 位截断回绕（vel_r ≥ 248 时回绕到 0~7，重放满力度音立刻掉 31 dB）
- **位置**：rtl/w3b/note_manager.v:1064-1081（两处镜像：手弹支 :1069-1072、回放支 :1076-1078）；vel_r 声明 :439
- **现状**：
```verilog
1069:                            if (vtgt_vld[axis_r[i]]) begin
1070:                                if      (vtgt_val[axis_r[i]] > vel_r[i] + 8'd8) vel_r[i] <= vel_r[i] + 8'd8;
1071:                                else if (vtgt_val[axis_r[i]] + 8'd8 < vel_r[i]) vel_r[i] <= vel_r[i] - 8'd8;
1072:                                else                                            vel_r[i] <= vtgt_val[axis_r[i]];
1073:                            end
1076:                            if      (vtgt_rep[i] > vel_r[i] + 8'd8) vel_r[i] <= vel_r[i] + 8'd8;
1077:                            else if (vtgt_rep[i] + 8'd8 < vel_r[i]) vel_r[i] <= vel_r[i] - 8'd8;
1078:                            else                                    vel_r[i] <= vtgt_rep[i];
```
- **为什么是问题**：`vel_r` 是 `reg [7:0]`，`8'd8` 是 8 位常量 ⇒ 加法表达式自定宽度 = 8 位（IEEE 1364-2001 §5.1.1，比较不会把操作数加宽到 9 位）⇒ `vel_r + 8'd8` 是 mod 256：`vel_r=248 ⇒ +8=0`，`250 ⇒ 2`，`255 ⇒ 7`，而 `tgt > 0/2/7` 几乎恒真 ⇒ `vel_r` 被写回 0~7。可达性三路实锤：①回放支（src≠0）无 `vtgt_vld` 门，提交那拍 `vel_r[i] = vtgt_rep[i] = cmt_vel_r`（:1365/:1385），事件力度 = 255 时**第一个 sample_tick 就命中**（`255 > 255+8(=7)` 真 ⇒ `vel_r <= 7`），录一段满力度再回放即复现；②力度上限确实 255（rtl/w3a/param_extract.v:96 `VEL_MAX = 8'd255`、:189 `vel_lut[lut_i] = VEL_MAX`）；③`adsr.v` 里 `peak = velocity << 8` ⇒ 255→65280、7→1792 = **−31.2 dB**，随后在 0↔248 之间锯齿（32 拍 = 655 µs ≈ 1.53 kHz 颤音）。同时违反文件自己的纪律：:1024-1031 明写"⛔ 不许 vel_r 一拍整值跳、每采样拍最多 ±8"（K-154），本 bug 是一拍跳 248。为什么现有 tb 全绿：tb/w3b/tb_note_manager_vel_ramp.sv:28/:35 的黄金模型**逐字复制了同一个表达式**（`if (tgt_axis > cur + 8'd8) old_next = cur + 8'd8;`），而激励 :70-71 `tvals = {0,1,7,8,9,127,128,247,248,254,255} × cur=0..255` 恰好扫到失败点 ⇒ 两边一起错、比出来相等 ⇒ mism=0 ⇒ PASS（C83 探针假绿教科书样本）；另一 tb 最大力度是 tb/w3b/tb_note_manager.sv:591 `vel_upd_value = 8'd240` ⇒ 248~255 全区间零覆盖。
- **改法**：9 位比较，两侧零扩展后比较，加法不再截断（1 行 × 2 处）：
```verilog
if ({1'b0, vtgt_val[axis_r[i]]} > {1'b0, vel_r[i]} + 9'd8) vel_r[i] <= vel_r[i] + 8'd8;
```
不需要加钳位：上升支成立前提是 `tgt > vel_r+8`（9 位）⇒ `vel_r+8 < tgt ≤ 255` ⇒ 和必 ≤254，天然不溢出；下降支同理。
- **预期**：修一个 −31 dB 的可听功能缺陷；代价 ≈ 每 voice 每分支 +1 LUT × 2 分支 × 32 voice ≈ **+64~128 LUT（<0.5% T_Lut）**，无时序影响（不在关键路径上）。
- **怎么验**：①把 tb_note_manager_vel_ramp.sv 的黄金模型改成规格式（`next = (tgt > cur+8) ? min(cur+8,255) : ((tgt+8 < cur) ? max(cur-8,0) : tgt)`，比较用 9 位）⇒ 未修复 RTL 在 `cur ∈ 248..255` 必然 mismatch ⇒ RED；②tb_note_manager.sv 加定向：`note_velocity = 8'd255` → 等 1 个 sample_tick → 断言 `vel_of(i) === 8'd255`（当前必 FAIL，值为 7）；③变异测试：把 `8'd8` 改成 `9'd8`（只加宽一侧）⇒ 必须仍然 RED。
- **来源**：ANVIL-01【P0-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-01|ORIG=P1-1|MOD=rtl/w3b/note_manager.v
### 给 T3 轮转-共享乘法器链切一级流水，摘掉全设计第 1 条关键路径（slack +0.102 ns）
- **位置**：rtl/w3b/note_manager.v:1532-1544（读侧）＋ :1575-1578（写侧）
- **现状**：
```verilog
1532:    wire [PHASE_W-1:0] rot_phase = phase_r[rot_cnt];
1533:    wire [PHASE_W-1:0] rot_base  = (base_oct_r == 2'd0) ? rot_phase : (rot_phase << base_oct_r);
1540:    wire [4:0]         ratio_idx  = semi_cur + 5'd12;
1541:    wire [16:0]        semi_ratio = semi_ratio_of(ratio_idx);
1544:    wire [PHASE_W+17-1:0] prod_w = rot_base * semi_ratio;
1575:            if (rot_ok)
1576:                phase_tr[rot_cnt] <= ((semi_cur == 5'sd0) ||
1577:                                      (src_r[rot_cnt] == 3'd3) || (src_r[rot_cnt] == 3'd4))
1578:                                   ? rot_base : (prod_w >>> 15);
```
证据（impl/pnr/Gowin2026.timing_paths 第 1 条，逐节点到达时间）：`rot_cnt_0_s0` 0.000→1.288；布线 →`rot_phase_20_s83` 1.288→4.142（2.85 ns 纯布线）；**32:1 读 mux** `rot_phase_20_s83/s71/s65/s62/s61` 4.142→10.398（**6.26 ns / 5 级 LUT**）；布线 →`rot_base_22_s1` 10.398→11.502（1.10 ns）；八度移位 `rot_base_22_s1/s0` 11.502→12.586（1.08 ns / 2 级）；**共享乘法器** `prod_w_0_s` 13.589→16.123（**2.53 ns，DSP**，`rsc.xml` 实锤 MULT27X36 ×1）；选择 mux `n34284_s0` 16.296→16.765（0.47 ns）；**末段布线** →`phase_tr[28]_24_s0` 16.765→**22.172**（**5.41 ns**，到 1024 个 FF 的写译码）；合计 22.172 ns（required 22.274），**slack +0.102 ns**。
- **为什么是问题**：一整个 18.181 ns 周期里 `rot_cnt → 32:1 mux → 移位 → DSP → 写译码` 串成一条组合链：mux 及其前布线 9.11 ns（50%）、DSP 2.53 ns、末段布线 5.41 ns（24%）。结构性判定（跨构建复现）：2026-10-02 最差路径 `fifo_ax → n1577 → same_idx_0/1 → same_valid_* → scan_cnt`（本模块 FIFO 读 mux＋优先编码）；2026-10-03 `env_active_r_25 → oscillator_bank/lane_active → same_valid_* → scan_cnt`；2026-10-09 本次 `rot_cnt → rot_phase → rot_base → prod_w → phase_tr` ⇒ 4 次归档构建里 3 次最差路径落在 note_manager（或穿过它）且每次换一条链 ⇒ 排除布局运气。布局噪声机制也在这里：+0.102 ns 余量 ⇒ 约 0.65 ns 布线抖动就能翻掉 2 MHz。⚠️ 必须同时看第 2 名：tdm_render_mixer 那条 20.062 ns / slack +0.133 ⇒ 只修 T3 链 Fmax 只从 55.313 → 55.4 MHz（+0.1 MHz），要真涨必须两条一起切。
- **改法**：推荐 A（切在 mux 与 DSP 之间）：加一级流水 `rot_phase_r <= phase_r[rot_cnt]; rot_src_r <= src_r[rot_cnt];`（35 FF），下一拍用 `rot_phase_r` 算 `rot_base`/`prod_w`/写 `phase_tr`；为对齐，`rot_cnt` 与旁路判据 `semi_cur==0` 各延一拍（`rot_cnt_d1` 5 FF、`semi_bypass_d1` 1 FF）。B（切在 DSP 输出）：只寄存 `prod_w`（49 FF），摘掉 DSP 的 2.53 ns＋部分末段布线，收益小（≈5 ns）且要处理"寄存后写哪个 lane"。
- **预期**：A 方案代价 +41 FF，T3 刷新周期 32 → 64 拍 = 1.28 µs（远小于 1 ms 短滑音，语义无损），`phase_tr` 的"≤32 拍"契约要改成 ≤64 拍（tb_transpose.sv 的 T1_SETTLE 需同步）；收益把 9.11 ns 的 mux 段从链上摘掉 ⇒ 该路径降到 ≈13 ns ⇒ 不再是最差。B 方案 +49 FF、收益 ≈5 ns。
- **怎么验**：①sim/gowin_build.ps1 重跑 PnR，断言新 timing_paths 第 1 条**不再是** `rot_phase/rot_base/prod_w`；同时看 timing.txt 的 Actual Fmax 与 `Numbers of Setup Violated Endpoints`；②功能等价：tb/w3b/tb_transpose.sv 的 T1（与基线逐位差分）在放宽到 64 拍后仍 PASS，再补"0 档逐位恒等"用例（`transpose_semi_i` 悬空 ⇒ `semi_cur` 恒 0 ⇒ 输出 == `phase_r[g]`）；③🔴 tb_p5_osc_equiv 对此改动**无效**（它只比 oscillator_bank vs 自己的旧副本，相位语义变了它也不知道），别拿它当"没坏"的证据。
- **来源**：ANVIL-01【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-01|ORIG=P1-2|MOD=rtl/w3b/note_manager.v
### 把每轴力度查表从 32 voice 循环体里挪出去，省掉 32 个读端口与 32 份 RAM 副本
- **位置**：rtl/w3b/note_manager.v:1064-1081（循环体内两次查表）；vtgt_val/vtgt_vld 声明 :457-458
- **现状**：
```verilog
1064:            if (sample_tick_i) begin
1065:                for (i = 0; i < POLY_TARGET; i = i + 1)
1066:                    if (gate_mask[i]) begin
1067:                        if (src_r[i] == 3'd0) begin
1069:                            if (vtgt_vld[axis_r[i]]) begin
1070:                                if (vtgt_val[axis_r[i]] > vel_r[i] + 8'd8) ...
```
- **为什么是问题**：`vtgt_val` 是 `reg [7:0] vtgt_val [0:15]`（:457，16 项 × 8 位），`vtgt_vld` 是 16 位（:458），它们在每个 voice 的循环体里被按 `axis_r[i]` 索引 ⇒ 综合器面对 32 个独立读地址。成本：每 voice 一份 16:1 mux（8 位）= 32×8×5 LUT = **1280 LUT**（LUT4 当 2:1 mux ⇒ 16:1 = 4 级）；`vtgt_vld` 同上 32×5 = **160 LUT**；若被识别成分布式 RAM 并复制 32 份 ≈ 32×(16×8/16) ≈ **256 LUT**（`syn.log:152-153` 明确 `Extracting RAM for identifier 'vtgt_val'/'vtgt_vld'`）⇒ 无论哪条路成本 ≥256 LUT、上限 ~1440 LUT（本模块 9618 LUT 的 2.7%~15%）。并且它串在 `vel_r[i]` 的 CE 上：CE 条件 = `sample_tick_i & gate_mask[i] & (src/比较)`，比较的输入就是这个查表结果 ⇒ **32 voice × 8 位 = 256 个 CE 端点同时被这个宽 mux 驱动**（impl/pnr/Gowin2026_tr_content.html 里 4517 端点违例是同一机制）。文件自己算过这笔账的一半（:470-471：64 项目标表 ⇒ 每 voice 一个 64:1 mux ⇒ +6000 LUT），却漏掉了已经在树上的这 16:1。
- **改法**：把"按轴查表"从每拍 × 每 voice 降到每事件一次 + 每次 `vel_upd` 一次：①`vel_upd` 到达时（已有同构代码 :1053-1058 非手弹支）把同轴同源的 voice 直接写 `vtgt_rep[i]`，手弹支照此办（去掉 `src_r[i]==3'd0` 分叉，统一写 `vtgt_rep[i]`）；②提交/重触发时初始化 `vtgt_rep[cmt_idx_r] <= vtgt_vld[cmt_axis_r] ? vtgt_val[cmt_axis_r] : cmt_vel_r;`（全场只剩 1 个 16:1 mux，40 LUT），"更新早于 voice 出现"的自愈性（:449-451 的 K-154 论证）仍保留；③斜坡段 :1064-1081 改成只读 `vtgt_rep[i]`，不查任何表。
- **预期**：**−256 ~ −1400 LUT**（1%~5% T_Lut，CLS 78% 的机器上就是 1~4 个点），并把一条宽 mux 从 256 个 CE 的路径上摘掉；代价：手弹与回放共用一套 per-voice 目标 ⇒ 需保留"每轴目标只在按住期间有效"语义（:1175-1187 清位逻辑要跟着挪），改动面约 30 行，风险中等（属"两套目标合并"，必须先补 tb）。
- **怎么验**：①A/B 综合对比 syn.log 的 `T_Lut`（当前 9618）与 rsc.xml 的 note_manager 行，预期 −256 以上；②功能：tb_note_manager.sv 力度跟随组（:606-610、:1186 附近）＋ tb_note_manager_vel_ramp.sv 必须全绿，并新增"更新先到、voice 后到"定向用例（该自愈性现在只有注释、没有 tb 钉住）；③反向：故意删掉 `vtgt_vld[cmt_axis_r]` 三元判断 ⇒ 必须 RED。
- **来源**：ANVIL-01【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-01|ORIG=P1-3|MOD=rtl/w3b/note_manager.v
### 补上"满队列排空拍数 > 一帧"的自检并纠正 22.4 µs 的错误论证
- **位置**：rtl/w3b/note_manager.v:99（论证）＋ :1125-1390（FSM 实际拍数）＋ :1703（自检）
- **现状**：
```verilog
99:    //       ⭐ 但**听感延迟不受影响** —— `adsr` 的 `gate` 只在 `sample_tick_i`（每 1024 拍）采样，
100:   //          22.4 µs 仍在一帧内（见文件头 `K-103` 的同一论证）。
1703:        if ((POLY_TARGET + 4) > 1024)
1704:            $display("ERROR [note_manager] POLY_TARGET+4=%0d > 1024（每帧可用 clk）=> 扫描跑不完一帧",
```
- **为什么是问题**：逐状态数拍（每个 note_on 事件）：拍 0 `fifo_push` 入队（:945-957）；拍 1 `ST_IDLE` 取头锁存（:1126-1137）；拍 2 `ST_DECIDE` 判同轴/开扫（:1217-1224）；拍 3~34 `ST_SCAN` **32 拍**（:1272-1287，scan_cnt 0→31）；拍 35 `ST_COMMIT` 只锁存 cmt_*（:1306-1328）；拍 36 `ST_COMMIT2` 真正写寄存器（:1352-1389）⇒ **单事件 = 36 拍**（= POLY_TARGET + 4，文件里那个 +4 恰好对，但含义是"一个事件"）。而 FIFO 深度 32（:102）⇒ 最坏突发（32 个 note_on 背靠背）排空 = **32 × 36 = 1152 拍 = 23.04 µs > 1024 拍 = 20.48 µs**。文件 :99 写的 `32×35 = 1120 拍 = 22.4 µs` **两个数都错**：(a) 每事件是 36 不是 35（ST_COMMIT2 是后加的，:390-396）；(b) **1120 > 1024**，"仍在一帧内"算术上不成立。后果（有界但真实）：最坏突发下最后几个事件的 gate 会在下一个 sample_tick 才被 ADSR 看见 ⇒ 最多 +1 帧 = 20.48 µs 额外延迟；而 :20-28 整个"代价免费"的论证（K-103）正是建立在这条之上。自检漏了这一维：:1703 只查单事件（POLY_TARGET+4 = 36 ≤ 1024 恒真，**永不触发**），没有查 `FIFO_DEPTH × (POLY_TARGET+4)`。
- **改法**：自检加一条（编译期可算，零硬件成本）：
```verilog
localparam integer FRAME_CLK = 1024;                      // CLK_PER_SAMPLE（与 clk_gen 同值）
if (FIFO_DEPTH * (POLY_TARGET + 4) > FRAME_CLK)
    $display("WARNING [note_manager] 满队列排空 %0d 拍 > 一帧 %0d 拍 => 尾部事件晚一帧生效",
             FIFO_DEPTH*(POLY_TARGET+4), FRAME_CLK);
```
并把 :99-101 注释改成实测拍数（36），把"仍在一帧内"改成"最坏溢出 1 帧"。
- **预期**：**零 RTL 代价**（只加自检 + 改注释）；收益是把一条假论证从文档里拔掉（它是"分配延迟 ≤34 拍/免费"整条链的承重墙）。若真要不超帧：`FIFO_DEPTH ≤ 28`（28×36 = 1008 ≤ 1024）或把 ST_SCAN 的 32 拍改成两拍两个 voice。
- **怎么验**：tb_note_manager.sv 加"32 个 note_on 连发"用例，记录"第 32 个事件的 gate 生效时刻 − note_valid 时刻"，断言 ≤ 1024 拍（当前 ≈1152 ⇒ RED）；再断言 `event_lost_o` 仍为 0（证明是排队不是丢弃）。
- **来源**：ANVIL-01【P1-3】
@@@END
@@@PRIO=P1|SRC=ANVIL-01|ORIG=P1-4|MOD=rtl/w3b/note_manager.v,rtl/top.v
### 纠正 T3_EN 交付档口径与三套互斥的验收 T_Lut 数字
- **位置**：rtl/w3b/note_manager.v:65-81（"把 T3 关起来"）vs rtl/top.v:329 / :4014-4015；note_manager.v:1437 / :1571 / :1622；:189
- **现状**：
```verilog
 65:    //   📌 **为什么要有它**（⭐ 详见 `files/20-代码/T3-后续计划-20261003.md` §三 `P1`）：
 70:    //      ⇒ ⭐ 用户 2026-10-03 拍板"**暂不做大改**" ⇒ ⭐ **把 T3 关起来，让主线恢复可交付** ✅
 81:    parameter integer T3_EN       = 0,
--- rtl/top.v ---
329:    parameter integer T3_ENABLE               = 1
4014:            // ⭐⭐ 2026-10-04：⭐ **T3 变调总闸**（⭐ 交付档 = 1，⭐ 见 `T3_ENABLE` 的说明 ✅）
4015:            .T3_EN       (T3_ENABLE)
```
- **为什么是问题**：①交付档 T3 是开的（sim/evidence/a3-proper-20261008/syn.log:151 实锤 `T3_EN=1`），而模块头 :70-81 告诉读者"关着"⇒ 任何按文件头推理的人都会得出相反结论（例如"那段 phase_tr 不参与综合"——它参与，而且它就是全设计第 1 条关键路径）；②验收数三套并存：:1437/:1622 = `37026 ± 100`、:1571 = `31039`、实测 **27140**（a3-proper/rsc.xml）/ **27271**（final-batch/README.md:33）⇒ 拿 37026 当门槛会得到"差 9800 LUT"的假红；③:189 写"悬空 ⇒ 0 档 ⇒ 逐位恒等"，但交付档 `transpose_semi_i` 是接上的（rtl/top.v:4059 `.transpose_semi_i (transpose_semi)` ← `u_fader_gear.transpose_semi_o`，:1786）⇒ "0 档恒等"在交付档只在用户没动推子时成立，不是结构性保证。
- **改法**：把 :65-81 整段改成"交付档 = top.v 的 `T3_ENABLE`；本模块默认 0 仅为模块级 tb 兼容"，并把三个 T_Lut 数改成带日期与出处的唯一一个（`27140 @ a3-proper-20261008`），其余标"历史值，勿用作门槛"。
- **预期**：零 RTL 代价；收益 = 防止下一轮"照文件头推理 ⇒ 判断错方向"（本项目已因"证据基础没核对"浪费过整轮，见 AGENTS.md §五①）。
- **怎么验**：在 sim/ 里加 grep 式检查（或 CI 脚本）：note_manager.v 中出现的 T_Lut 数字必须能在最新 rsc.xml 里找到，找不到就报错；手工复核 `Select-String note_manager.v -Pattern "T_Lut"` 当前返回 3 个互斥数字。
- **来源**：ANVIL-01【P1-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-01|ORIG=P1-5|MOD=rtl/w3b/note_manager.v
### 在重触发写路径上补写 drum_cls_r，消除"相位与分类来自两个事件"
- **位置**：rtl/w3b/note_manager.v:1363（提交路径，有）＋ :1236-1268（重触发路径，没有）；比较器 :832-836、:835-836
- **现状**：
```verilog
1360:                        //  ⭐⭐ 2026-10-08（`A3` 正确修法）：⭐ **鼓分类与"占 voice"同拍写**
1363:                        drum_cls_r[cmt_idx_r*2 +: 2] <= {cmt_kick, cmt_tom};
1239:                        gate_r[same_idx_r]     <= 1'b0;
1258:                        src_r[same_idx_r]      <= cur_src;
1259:                        phase_r[same_idx_r]    <= cur_inc;     // ← 相位被改写
1260:                        vel_r[same_idx_r]      <= new_vel;
1262:                        age_r[same_idx_r]      <= {AGE_W{1'b0}};
1267:                        vtgt_rep[same_idx_r]   <= new_vel;
                        //  ← drum_cls_r 缺席
```
- **为什么是问题**：`drum_cls` 是 `phase_inc` 的派生量（:835-836 用 `cmt_inc_oct` 比 `DRUM_KICK_MAX_C`/`DRUM_TOM_MAX_C`）。重触发把 `phase_r` 改成新事件的 `cur_inc`，却把分类留在旧值 ⇒ 同一个 voice 的"相位"和"分类"来自两个不同事件 ⇒ oscillator_bank 会按上一个鼓的表去扫这一个鼓。这正是文件自己在 :414-415 为 `src_r` 立的纪律（"必须与 axis_r 在同一条写路径上更新，⛔ 否则留下源不明的 voice"）的同构违背。可达性（诚实评估：低，但不是零）：需要"同轴 + 同源"（`same_hit` 要求 `axis_r` 与 `src_r` 都相等，:688-690）且两次音高不同；分类只在 `src_r==3`（鼓机）时被 oscillator_bank 使用（:1660 `voice_drum_o = (src_r[g]==SRC_AUX)`）⇒ 同一根轴同一来源通常是同一件鼓（同音高）⇒ 现实中很难触发。但曲谱/looper 回放（src=1/2/4）在同轴换音高时会改写 `phase_r`，此时分类字段虽不被使用却已语义漂移（一旦将来把 DRUM_CLS_EXT 扩展到回放路径就会立刻变成真 bug）。
- **改法**：在 ST_RETRIG 里补一行（复用同一套比较器，:832-836 的表达式换成 `cur_inc`）：
```verilog
wire [PHASE_W-1:0] cur_inc_oct = (base_oct_r == 2'd0) ? cur_inc : (cur_inc << base_oct_r);
// ST_RETRIG 内：
drum_cls_r[same_idx_r*2 +: 2] <= {(cur_inc_oct < DRUM_KICK_MAX_C),
                                  (cur_inc_oct >= DRUM_KICK_MAX_C) && (cur_inc_oct < DRUM_TOM_MAX_C)};
```
- **预期**：消除"两处真相"；代价 ≈ **+4~8 LUT**（一个 32 位变移位 ＋ 两个常量比较，只在重触发拍用，可被共享），**0 FF**（复用已有 drum_cls_r）；时序上新比较器挂在 `same_idx_r` 的写译码上，属短路径。
- **怎么验**：tb/w3b/tb_osc_drum_cls.sv 现在只测"提交那一刻"（README §三 A1/A2/A3/B1-B3）；补一条：同轴同源先起"底鼓"（`phase_inc=8M`），在 `env_active` 未落前再起"嗵鼓"（`phase_inc=17M`）⇒ 断言 `voice_drum_cls_o[v] == 2'b01`（tom）；当前实现会给出 `2'b10`（kick）⇒ RED。
- **来源**：ANVIL-01【P1-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-1|MOD=rtl/w3b/note_manager.v
### 把两处 integer 参数位选改成显式定宽常量（FIFO_DEPTH[FW:0] / SCAN_LAST[SW-1:0]）
- **位置**：rtl/w3b/note_manager.v:558、:1281（vs 文件自己的纪律 :56，以及它正确的写法 :404-405）
- **现状**：
```verilog
 56:    //   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
404:    localparam [PHASE_W-1:0] DRUM_KICK_MAX_C = DRUM_KICK_MAX;   // ← 正确：显式定宽常量
405:    localparam [PHASE_W-1:0] DRUM_TOM_MAX_C  = DRUM_TOM_MAX;
558:    wire fifo_full  = (fifo_cnt == FIFO_DEPTH[FW:0]);            // ← 违规
1281:                    if (scan_cnt == SCAN_LAST[SW-1:0]) begin       // ← 违规
```
- **为什么是问题**：本项目已有一次实测事故，files/20-代码/evt_merge设计说明.md:90-92 原文："🔴 bug 3：`DEPTH[15:0]` 对 `integer` 参数做位选（K-91）… K-91 明确禁止，而第一版就写了 ⇒ ⚠️ 索引比较全部失效。"若 `fifo_full` 恒假 ⇒ 写指针绕过 32 深队列覆盖未读事件 ⇒ 静默丢音（丢 note_off 就是挂音，正是 T38/K-106 要防的失效模式），且 `event_lost_o` 永不置位。诚实评估（概率低，但覆盖为零）：现有 tb 用 `FIFO_DEPTH=4`（tb/w3b/tb_note_manager.sv:125），溢出判据全绿（sim/evidence/tb_note_manager.log:73-87）⇒ 只证明了 `FIFO_DEPTH[2:0]==4` 这一种情况；交付档 32 从未在仿真里溢出过一次。`SCAN_LAST[SW-1:0]` 若失效则"永远扫不完" ⇒ 整机无声，板上显然没发生 ⇒ 该构造在 Gowin 里是能工作的 ⇒ 本条不是"正在出错"，而是"规则违背 + 交付档零覆盖"。
- **改法**：（1 行 × 2 处，与 :404-405 同款）
```verilog
localparam [FW:0]   FIFO_FULL_C = FIFO_DEPTH[FW:0];     // 或 localparam [FW:0] FIFO_FULL_C = FIFO_DEPTH;
localparam [SW-1:0] SCAN_LAST_C = SCAN_LAST[SW-1:0];
wire fifo_full = (fifo_cnt == FIFO_FULL_C);
if (scan_cnt == SCAN_LAST_C) ...
```
- **预期**：**0 LUT / 0 FF**（纯常量定宽）；收益 = 消除 K-91 家族的最后两处，并把"交付档 32 深溢出"变成可测。
- **怎么验**：把 tb_note_manager.sv 的主实例改成 `FIFO_DEPTH=32`（或在 section 10 加第二个 32 深实例），灌 33+ 个事件，断言 `event_lost_o==1` 且 `lost_cnt` 守恒（`served + lost == sent`）；同时读 syn.log 确认该行不再出现 EX3791/无新告警。
- **来源**：ANVIL-01【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-2|MOD=rtl/w3b/note_manager.v
### 把 best_valid==0 的丢弃接进已有的丢失计数与 sticky 标志
- **位置**：rtl/w3b/note_manager.v:1304-1328（守卫）＋ :576-582（FIFO 侧对照实现）＋ :270（纪律）
- **现状**：
```verilog
1304:                    //  ✅ **修法**：加 `if (best_valid)` 守卫 ⇒ ⭐ 无候选时**什么都不做**
1305:                    //     （该事件被丢弃，但⛔ 不会污染无关 voice）。
1306:                    if (best_valid) begin
1325:                    end else begin
1327:                        cmt_en_r <= 1'b0;
1328:                    end
```
对照：FIFO 丢事件有 `lost_sticky_r` / `lost_cnt_r`（:580-582、:967-974），且 :270 明写纪律"任何容量有限的队列都必须有可观测的溢出指示"。
- **为什么是问题**：这是第二条静默丢事件路径（丢的是 note_on ⇒ 少一个音，用户会以为"键没响应"），而它没有任何指示。文件自己在 :782 承认"若真排空 ⇒ best_valid=0 ⇒ 事件被丢"，:1300-1303 还给出可达条件（`POLY_TARGET=4, RESERVED_N=0` 的小实例只需 4 个 voice 同时 retrig_low）。
- **改法**：复用现有计数器（0 新端口）：
```verilog
// ST_COMMIT 的 else 支：
if (!best_valid && !lost_cnt_sat) lost_cnt_r <= lost_cnt_r + 1'b1;
if (!best_valid)                  lost_sticky_r <= 1'b1;
```
- **预期**：+2 LUT（`lost_cnt_sat` 已在 :582）；收益 = 把"第二条静默丢音路径"接进已有的 `event_lost_o`（上层 UART/灯带已经在读它）。
- **怎么验**：小实例（`POLY_TARGET=4, RESERVED_N=0`）连发 5 个同轴异源 note_on 制造"无候选"，断言 `event_lost_o==1`（当前恒 0 ⇒ RED）。
- **来源**：ANVIL-01【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-3|MOD=rtl/w3b/note_manager.v
### 用 1 位 sticky 替掉 age_r 的 16 输入 NOR，并把 1.342 s 年龄饱和写成契约
- **位置**：rtl/w3b/note_manager.v:936-941（年龄自增）；仲裁比较 :801；sample_tick 周期 :358-359
- **现状**：
```verilog
937:            if (sample_tick_i) begin
938:                for (i = 0; i < POLY_TARGET; i = i + 1)
939:                    if (live_mask[i] && (age_r[i] != {AGE_W{1'b1}}))
940:                        age_r[i] <= age_r[i] + 1'b1;
```
- **为什么是问题**：两个独立机制。①CE 路径：`age_r[i]` 的使能 = `sample_tick_i & live_mask[i] & (age_r[i] != 16'hFFFF)` ⇒ 最后一项是 **16 输入 NOR = 4 级 LUT4**，压在 32 voice × 16 位 = 512 个 CE 端点上；再叠 `sample_tick_i` 自身扇出（本模块内 ≈98 个负载：年龄 32 ＋ 斜坡 32 ＋ retrig_reset 清 1 ＋ 重触发环 32）⇒ 就是"CE 大面积违例"的同一机制，只是这次最差路径被 T3 链盖住了。②仲裁退化：sample_tick 周期 = 1024 clk @50 MHz = **20.48 µs**（:358-359 自述）⇒ 16 位饱和时间 = 65535 × 20.48 µs = **1.342 s**。按住任何音超过 1.34 s，所有 voice 的 `age_r` 全 = 0xFFFF ⇒ `cand_better` 的 `(cls==2) && (age > best_age)`（:801）恒假 ⇒ 抢占退化成"最低索引优先"，不是"最老优先"。文件对此只字未提。
- **改法**：饱和改成 1 位 sticky（:939 换成 `if (live_mask[i] && !age_sat[i])`，进位时置 `age_sat[i]`），去掉 16 输入 NOR；仲裁要么把 `AGE_W` 提到 20（2^20 × 20.48 µs = 21.5 s，+128 FF），要么在文档/tb 里明写"1.342 s 之后按索引抢"。
- **预期**：−32×4 ≈ **−128 LUT**、512 个 CE 各短 2 级；代价 = +32 FF（sticky）。
- **怎么验**：tb 里让 5 个 voice 保持 > 1.342 s（sample_tick 加速或直接 force age_r），断言抢占对象 == 最早分配的那个；当前会抢到索引最小的那个 ⇒ RED。
- **来源**：ANVIL-01【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-4|MOD=rtl/w3b/note_manager.v
### 把 FIFO 队头寄存一拍，让 7 个 32:1 宽 mux 消失并允许 RAM 推断
- **位置**：rtl/w3b/note_manager.v:543-553（声明）＋ :585-591（组合读）＋ :98（记账）；死数组 fifo_v :867/:946
- **现状**：
```verilog
543:    reg                    fifo_v   [0:FIFO_DEPTH-1];
545:    reg [PHASE_W-1:0]      fifo_inc [0:FIFO_DEPTH-1];
585:    wire [AXIS_W-1:0]  head_axis = fifo_ax [fifo_rd];
586:    wire [PHASE_W-1:0] head_inc  = fifo_inc[fifo_rd];
 98:    //    ⚠️ 代价极小：每条事件 64 bit ⇒ 多 16×64 = **1024 bit**（60K 总 BSRAM 2124 kb 的 **0.05%**）。
```
- **为什么是问题**：①`fifo_v` 是死数组：只在 :867 复位、:946 写入，从不被读（全仓 grep 只有这三处；`fifo_empty` 走 `fifo_cnt`，:559），而 syn.log:155 还专门为它 `Extracting RAM for identifier 'fifo_v'`；②读是组合的 ⇒ 不能映射 BSRAM（BSRAM 读需同步）⇒ 变成 7 个 32:1 mux：`head_inc` 一项就 ≈ **352 LUT**（32 位 × 5 级 2:1），全组 ≈ **570 LUT**；③rsc.xml 实测 `note_manager: Bsram=2` ⇒ 深度 16→32 的真实代价不是 1024 bit/2124 kb = 0.05%，而是"LUT/FF 阵列（或 LUTRAM）＋ 2 个 BSRAM 的粒度分配"，:98 的账差一个数量级以上（36 Kb / 2124 Kb = 1.7%）。
- **改法**：把队头寄存一拍（`head_*_r <= fifo_*[fifo_rd]`，52 FF），ST_IDLE 用 `head_*_r`；读地址变寄存器 ⇒ 允许 LUTRAM/BSRAM 推断，且 570 LUT 的 mux 从"地址→锁存"路径上消失。
- **预期**：+52 FF、事件延迟 +1 拍（36→37，仍在一帧内，见 P1-3 的账）；收益是消掉 ≈570 LUT 的组合 mux 并让存储可推断。
- **怎么验**：A/B 综合看 `T_Lut`；syn.log 里 `fifo_inc` 是否从 `Extracting RAM` 变成 BSRAM 行；tb_note_manager.sv 全绿（这条改动必须逐用例回归，因为它动了取事件的时序）。
- **来源**：ANVIL-01【P2-4】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-5|MOD=rtl/w3b/note_manager.v
### 给扫描预译码的双编码一致性加仿真断言
- **位置**：rtl/w3b/note_manager.v:711-740（scan_cnt 与 scan_sel 两套编码）＋ :748（索引取自 scan_cnt）
- **现状**：
```verilog
714:    (* syn_preserve = 1 *) reg [POLY_TARGET-1:0] scan_sel;
717:    (* syn_keep = 1 *) wire [SCAN_ATTR_W-1:0] scan_group [0:SCAN_GROUPS-1];
726:                    assign leaf[scan_l] = {SCAN_ATTR_W{scan_sel[scan_g*8+scan_l]}} &
727:                        {hold_mask[...], pool_mask[...], free_mask[...], gate_mask[...],
728:                         env_active_r[...], axis_r[...], src_r[...],
729:                         env_level_r[...], age_r[...]};
738:            assign scan_merge[scan_g+1] = scan_merge[scan_g] | scan_group[scan_g];
748:    wire [IDX_W-1:0]   cand_idx   = scan_cnt[IDX_W-1:0];      // ← 索引来自【另一套编码】
```
- **为什么是问题**：候选的属性值来自 `scan_sel`（one-hot），而索引来自 `scan_cnt`（二进制）——同一件事的两套编码。只要 `scan_sel` 不是严格 one-hot（被工具重新编码、被毛刺、被 syn_preserve 被忽略），`scan_merge` 的 OR 树会把两个 voice 的属性按位或出一个"幽灵候选"，而提交时写的是 `scan_cnt` 那个 voice ⇒ 把 A 的属性写到 B 身上（例如把 27 号 voice 的 axis/src/phase 写进 3 号）。`syn_preserve` 是 Synopsys 系属性；sim/evidence/a3-proper-20261008/syn.log 对 note_manager 只有 2 条告警（:163 EX3045、:164 EX3791），既没有"属性被忽略"也没有"属性被采纳"的回执 ⇒ 无法从现有证据判定它是否生效。另注：:738 是串行 OR 链（`scan_merge[g+1]` 依赖 `scan_merge[g]`），而 :624 注释写"⛔ 无链式依赖 ⇒ 深度 ~5 级"——注释与代码不符（见 P3-2）。
- **改法**：保留结构，加一致性断言（仿真期零硬件代价）：
```verilog
// synopsys translate_off
always @(posedge clk_i) if (state==ST_SCAN)
    if (scan_sel !== ({{(POLY_TARGET-1){1'b0}},1'b1} << scan_cnt))
        $display("ERROR [note_manager] scan_sel/scan_cnt 失同步：sel=%b cnt=%0d", scan_sel, scan_cnt);
// synopsys translate_on
```
并在 syn.log 里显式确认 syn_preserve/syn_keep 是否被 Gowin 采纳（不采纳就换 `(* keep = 1 *)` 或直接删掉预译码，回到 32:1 mux —— 但 `d449504` 记载预译码带来 clk_sys 50.040→53.425 MHz，所以必须先测再动）。
- **预期**：0 硬件代价；收益 = 把"一次静默写错 voice"从板上现象变成仿真报错。
- **怎么验**：故意把 `scan_sel <= scan_sel << 1` 改成 `<= {scan_sel[30:0], 1'b0}`（丢一位）⇒ 断言必须报错；若断言不报错而功能全绿，说明断言是空的（C83 反向验证）。
- **来源**：ANVIL-01【P2-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-6|MOD=rtl/w3b/note_manager.v
### 把 default_timbre 随事件入队，别再读活的边带
- **位置**：rtl/w3b/note_manager.v:805-808（兜底读 default_timbre_i）；锁存点 :1133 附近
- **现状**：
```verilog
805:    // Timbre is stored with the event.  Allocation may start dozens of clocks
806:    // after note_valid_i, so sampling the live sideband here would assign a
807:    // later event's timbre to the wrong voice.
808:    wire [TIMBRE_W-1:0] new_timbre = cur_timbre_valid ? cur_timbre : default_timbre_i;
```
- **为什么是问题**：理由（"提交可能晚几十拍，读活边带会张冠李戴"）完全适用于 `default_timbre_i`，但兜底支恰恰读的就是它 ⇒ 提交时刻（最长 **36 拍 = 720 ns**，见 P1-3 的表）与事件到达时刻的 `default_timbre_i` 可以不同。窗口 720 ns 对人手不可能，但串口/自检脚本可以在同一拍连发 default_timbre 切换 ＋ note_on ⇒ 得到"事件属于旧音色、却用了新音色"。属理论窗口（P3 级严重度），但它是代码与自己的注释矛盾，这类"注释对、代码错"在本项目已发生过（AGENTS.md §五③）。
- **改法**：把 `default_timbre_i` 也随事件入队（`fifo_dtimbre`，2 位 × 32 = **64 FF**），:1133 附近一起锁存。
- **预期**：+64 FF；收益是消除"事件音色取决于提交时刻"的窗口，让注释与代码一致。
- **怎么验**：tb 在 `note_valid` 后第 5 拍改 `default_timbre`，断言该 voice 的 `timbre_of` == 事件当时的默认值（当前会取新值 ⇒ RED）。
- **来源**：ANVIL-01【P2-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-7|MOD=rtl/w3b/note_manager.v,rtl/top.v
### 给 DRUM_TOM_MAX 的模块默认值与交付值加一条同值断言
- **位置**：rtl/w3b/note_manager.v:111 vs rtl/top.v:3996-3997
- **现状**：
```verilog
111:    parameter integer DRUM_TOM_MAX  = 15_000_000    // ⭐ ≈171 Hz（嗵鼓 / 军鼓 之间）
--- rtl/top.v ---
3996:            .DRUM_KICK_MAX (10_000_000),
3997:            .DRUM_TOM_MAX  (20_000_000),
```
sim/evidence/a3-proper-20261008/syn.log:151 实锤编译参数 `DRUM_TOM_MAX=20000000`；sim/evidence/a3-proper-20261008/README.md:76-81 已把这个坑写成"本修法最容易踩的坑"，但代码里没有任何机械保护。
- **为什么是问题**：`note_manager` 与 `oscillator_bank` 的默认值不同（15 M vs 20 M），谁少传一处就得到"分类与扫档对不上"的鼓音，且不报任何错。
- **改法**：把 note_manager 的默认值改成与 oscillator_bank 同一个数，或在 initial 自检里断言"两个模块的阈值参数同值"（跨模块做不到就退而求其次：在 top.v 里加 `initial if (DRUM_TOM_MAX != 20_000_000) $display("ERROR ...")`）。
- **预期**：零硬件代价；收益 = 把"文档里的坑"变成编译/仿真期的错。
- **怎么验**：把 rtl/top.v:3997 改成 `15_000_000`（少传一个值），当前全绿；加断言后必须报 ERROR。
- **来源**：ANVIL-01【P2-7】
@@@END
@@@PRIO=P2|SRC=ANVIL-01|ORIG=P2-8|MOD=rtl/w3b/note_manager.v
### 给非 2 的幂 FIFO_DEPTH 与 POLY_TARGET>32 加编译期自检
- **位置**：rtl/w3b/note_manager.v:956（指针自增）＋ :543-553（数组长度）＋ :1528-1529（ROT_LANES）＋ :1692-1706（自检清单）
- **现状**：
```verilog
956:                fifo_wr           <= fifo_wr + 1'b1;         // FW = $clog2(FIFO_DEPTH)
407:    localparam integer FW = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
1528:    localparam integer ROT_LANES = (POLY_TARGET > 32) ? 32 : POLY_TARGET;
1575:            if (rot_ok)  phase_tr[rot_cnt] <= ...
```
- **为什么是问题**：①`FIFO_DEPTH=20`（非 2 的幂）：`FW=5`，指针走 0..31，而数组只有 `[0:19]` ⇒ 写/读到数组外（仿真得 x，综合里高位地址被丢 ⇒ 静默串扰）；自检（:1700）只查下界 `FIFO_DEPTH < FIFO_MIN`，不查"必须是 2 的幂"。②`POLY_TARGET=64`：`phase_tr` 声明 `[0:63]`（:1519），但 `rot_cnt` 只有 5 位（:1518）⇒ lane 32..63 永远不被刷新（`rot_ok` 只挡"越界写"，挡不住"漏刷"）⇒ 那些 voice 的 `voice_phase_inc_o` 恒 0 ⇒ 永久无声；自检没有这一条。
- **改法**：自检加两条（编译期常量、零硬件）：
```verilog
if ((FIFO_DEPTH & (FIFO_DEPTH-1)) != 0) $display("ERROR [note_manager] FIFO_DEPTH=%0d 必须是 2 的幂（指针按位宽回绕）", FIFO_DEPTH);
if (POLY_TARGET > 32) $display("ERROR [note_manager] POLY_TARGET=%0d > 32 ⇒ phase_tr 只有前 32 lane 被轮转刷新", POLY_TARGET);
```
- **预期**：零硬件代价；收益 = 把两个静默错配变成编译期 ERROR。
- **怎么验**：用 `-P` 覆盖参数做两次 dry-run 综合/编译，断言两条 ERROR 都出现。
- **来源**：ANVIL-01【P2-8】
@@@END
@@@PRIO=P3|SRC=ANVIL-01|ORIG=P3-1|MOD=rtl/w3b/note_manager.v
### 删掉死声明与死数组（RESERVED_AXIS / KIND_PLUCK / RT_* / fifo_v）
- **位置**：rtl/w3b/note_manager.v:285、:283、:381-383、:543（＋:867、:946）
- **现状**：
```verilog
285:    localparam [AXIS_W-1:0] RESERVED_AXIS = RESERVED_AXIS_BASE;
283:    localparam [1:0] KIND_PLUCK = 2'd2;
381-383:    RT_NONE / RT_LOW / RT_HIGH
543:    reg fifo_v [0:FIFO_DEPTH-1];
```
证据：`RESERVED_AXIS` 全仓只有 :285 定义 ＋ :219/oscillator_bank.v:230/metronome.v:21 的注释提到（2026-10-01"修B"把按轴判池改成按源判池后遗留）；`KIND_PLUCK` 在 note_manager 内零引用（play_mode_ctrl.v:29 是另一个模块的同名常量），`cur_kind` 只与 `KIND_OFF` 比（:1141）⇒ pluck 走 note_on 语义，无人写下这条语义；`RT_NONE/RT_LOW/RT_HIGH` 只在 :489/:497/:505 的注释里出现（2026-09-28 改成"每 voice 位图"后的遗留）；`fifo_v` 无任何读（读侧走 `fifo_cnt`，:559），syn.log:155 还为它抽了 RAM。
- **为什么是问题**：32 FF ＋ 写译码白付；源码上它是"看起来有 valid 位"的假象，与"注释即契约"的核心资产冲突。
- **改法**：删（或把 `fifo_v` 改成"真的有读"的用途）。
- **预期**：综合器本来会裁掉，收益是源码可信度。
- **怎么验**：`grep -n "RESERVED_AXIS\|KIND_PLUCK\|RT_LOW" rtl/w3b/note_manager.v` 应只剩定义处（或全空）。
- **来源**：ANVIL-01【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-01|ORIG=P3-2|MOD=rtl/w3b/note_manager.v
### 按代码改写四处失真注释（优先编码方向 / OR 树深度 / 拍数 / 延迟契约）
- **位置**：rtl/w3b/note_manager.v:695、:624、:99、:20/:31
- **现状**：
```verilog
695: 注释"最低索引优先编码（升序扫 + 只在未命中时赋值）" | 代码 :700-701 `for (qi = POLY_TARGET-1; qi >= 0; qi = qi-1) if (same_hit[qi]) same_idx = qi;`（降序 + 无条件覆盖）
624: 注释"同轴位重触发检测（组合 OR 树，⛔ 无链式依赖 ⇒ 深度 ~5 级）" | 代码 :738 `scan_merge[scan_g+1] = scan_merge[scan_g] | scan_group[scan_g];` = 4 级串行 ripple
 99: 注释"32×35 = 1120 拍 = 22.4 µs 仍在一帧内" | 代码：每事件 36 拍；1120 > 1024（见 P1-3）
 20/:31: 注释"分配延迟 ≤ 34 拍" | 代码：36 拍（ST_COMMIT2/ST_RETRIG 两次加级后未更新）
```
- **为什么是问题**：:695 结果正确（最后写入者=最低索引）但推理链是反的，下一个人照注释改就会改错；:624 深度被低估且"无链式依赖"是错的；:99 与 :20/:31 的契约数字失真（对外冻结表写的就是 34）。
- **改法**：四处按代码改写；并把"延迟契约"改成 36 拍（或实测值）。
- **预期**：零硬件代价；收益 = 契约与代码一致，防止照错注释改错。
- **怎么验**：写一条 tb 计时用例，实测 `note_valid` → `alloc_valid_o` 的拍数（当前 36），断言 ≤ 36；注释里的数字由脚本核对。
- **来源**：ANVIL-01【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-01|ORIG=P3-3|MOD=rtl/w3b/note_manager.v
### 删掉恒真的 same_en_r 守卫与不可达分支
- **位置**：rtl/w3b/note_manager.v:1237、:1529、:609、:874/:1220
- **现状**：
```verilog
1237:    if (same_en_r) begin            // ST_RETRIG 只能从 :1216 进入，那里无条件 same_en_r <= 1'b1 ⇒ 必为 1；:1222 的清零只在开扫支
1529:    wire rot_ok = (rot_cnt < ROT_LANES);   // ROT_LANES 是 integer 32，rot_cnt 5 位零扩展后恒 < 32 ⇒ 交付档（POLY_TARGET=32）恒为 1
 609:    if (RESERVED_N == 0) assign pool_mask[pg] = 1'b1;   // 交付档 RESERVED_N=5 ⇒ 走 else；该分支只在 tb 用
 874/:1220: {{(POLY_TARGET-1){1'b0}}, 1'b1}              // POLY_TARGET=1 ⇒ 零宽复制（非法/无意义）
```
- **为什么是问题**：`same_en_r` 这个 FF 事实上是死状态，`if` 的 else 支不可达；`rot_ok` 在交付档恒 1（工具会折叠），只在 POLY_TARGET<32 时有意义；零宽复制在 POLY_TARGET=1 时非法/无意义，而 POLY_TARGET=1 的实例没有 tb。
- **改法**：`same_en_r` 直接删（把 ST_RETRIG 的写从 if 里拿出来）；`rot_ok` 加注释"仅小实例有效"；零宽复制改成 `{{POLY_TARGET{1'b0}}} | 1'b1` 形式。
- **预期**：−1 FF、少一层嵌套。
- **怎么验**：删 `if (same_en_r)` 后 tb_note_manager 必须逐条不变（若变了说明 same_en_r 不是恒真，判断被证伪）。
- **来源**：ANVIL-01【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-01|ORIG=P3-4|MOD=rtl/w3b/note_manager.v,rtl/top.v
### 把三路顶层无人读的诊断输出（672 bit）接进遥测或显式删除
- **位置**：rtl/w3b/note_manager.v:1672、:1638、:1661 vs rtl/top.v:4128、:4129、:4137（＋声明 :1295、:1313）
- **现状**：
```
voice_releasing_o（32 bit，:1672） | rtl/top.v:4128 `.voice_releasing_o (),` 空连接
voice_axis_o（32×4=128 bit，:1638） | rtl/top.v:4129 → nm_axis；nm_axis 在 top.v 里只有 :1295 声明 ＋ :4129 这一处（零消费者），grep 计数 = 2
voice_age_o（32×16=512 bit，:1661） | rtl/top.v:4137 → nm_age；同样只有 :1313 声明 ＋ :4137（零消费者），grep 计数 = 2
```
- **为什么是问题**：工具会把它们整段裁掉（所以不是资源问题），但出事时手里没有任何诊断信号：抢占对象、年龄、释放态这三个"最难查的现场"全都接不出来。
- **改法**：接进 waveform_scope/UART 遥测，或显式删除并在注释里写"本设计不提供该诊断"。
- **预期**：零资源变化；收益 = 现场可观测性（或消除虚假接口）。
- **怎么验**：top.v 里 nm_axis/nm_age 若被任何逻辑读走，grep 计数必须 > 2。
- **来源**：ANVIL-01【P3-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-01|ORIG=P3-5|MOD=rtl/w3b/note_manager.v
### 把复位核查的阴性结论与 Z-safe 的真实命运写进注释
- **位置**：rtl/w3b/note_manager.v:849-905、:371-373、:429、:1551-1557（已复位）；:544-553（未复位）；:698-702（无 latch）；:308-327、:913、:1166、:1497（Z-safe）
- **现状**：
```
✅ 已复位：全部 per-voice（gate_r/axis_r/src_r/phase_r/vel_r/timbre_r/age_r/vtgt_rep，:849-859）、vtgt_val/vtgt_vld（:863-866）、fifo_v（:867）、fifo_wr/rd/cnt（:868-870）、retrig_low、state、scan_cnt/scan_sel、best_*、cur_*、cmt_*、same_*、retrig_reset_r、sus_hold_r、drum_cls_r、lost_*（:871-905）、env_level_r/env_active_r（:371-373）、base_oct_r（:429）、T3 的 semi_cur/semi_tgt/port_cnt/rot_cnt/phase_tr（:1551-1557）
⚠️ 未复位：fifo_ax/inc/vel/knd/timbre_valid/timbre/src（:544-553）。无害：读侧只在 !fifo_empty 时锁存（:1127），fifo_empty 由已复位的 fifo_cnt 导出（:559）⇒ X 不会传播
✅ 无推断 latch：全文件唯一 always @(*)（:698-702）有默认赋值 same_idx = 0；sim.log 对 note_manager 没有任何 latch 告警（:163-164 只有 EX3045/EX3791）
✅ 无 CDC：全部输入同属 clk_sys；sus_pedal_i/timbre 由顶层 u_pedal_sus_sync/u_timbre_btn_sync 同步，transpose_semi_i 来自同域寄存器 u_fader_gear.transpose_semi_o（rtl/top.v:1786 → :4059）
⚠️ Z 悬空语义：:308-327（vu_src_w/pu_src_w/ns_src_w）、:913、:1166、:1497 用 ===/!== 做 Z-safe 解码；syn.log:163 `WARN (EX3045) : Case inequality operator always evaluates to true due to comparison with 'x' or 'z'`（:1497）⇒ trans_known 在硬件里恒 1
```
- **为什么是问题**：复位基本完整、缺口无害，但"只有 fifo_v 被复位"反而误导读者以为数据数组都复位了；Z-safe 是纯仿真兼容层、对硬件语义零影响，不写清楚会被误当成鲁棒性机制。
- **改法**：在 :544-553 注释里写清"X 不会传播"的推理；在 :308-327 等处注明"Z-safe 仅仿真，硬件恒 1（EX3045 实证）"；把"无 latch / 无 CDC"作为已验证的阴性结论写进交付说明。
- **预期**：零硬件代价；收益 = 防止误读为鲁棒性机制、防止误以为数据数组已复位。
- **怎么验**：交付说明中 grep "EX3045" 与 "latch" 各应命中对应结论；注释核对脚本对 :544-553 附近有"X 不传播"字样。
- **来源**：ANVIL-01【P3-5】
@@@END
@@@TOTAL SRC=ANVIL-01 COUNT=19 P0=1 P1=5 P2=8 P3=5
