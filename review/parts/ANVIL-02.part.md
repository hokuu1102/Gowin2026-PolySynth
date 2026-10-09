@@@PRIO=P0|SRC=ANVIL-02|ORIG=P0-1|MOD=rtl/w3b/vibrato_lfo.v,rtl/w3b/oscillator_bank.v,rtl/w3a/right_analog_ctrl.v
### 给颤音深度加音域约束，阻止低音在 LFO 峰值处相位增量翻负（音高跳 +3.27 个八度）
- **位置**：rtl/w3b/vibrato_lfo.v:43（深度定标，无上限）、:92-102、:128；rtl/w3b/oscillator_bank.v:299-304、:333、:469；rtl/w3a/right_analog_ctrl.v:112；rtl/top.v:1775-1789
- **现状**：
```verilog
 43:     wire [15:0] depth_target_w = {depth_raw_i, 3'b000}; // 12-bit -> Q1.15
128:     assign mod_o            = depth_active_r ? mod_w : 16'sd0;
--- oscillator_bank.v ---
333:     wire signed [PHASE_W-1:0] vib_off = vib_mul_r >>> 15;
469:             assign inc_main_w[vg*PHASE_W +: PHASE_W] = bv + vib_off[PHASE_W-1:0] + so_v;
--- right_analog_ctrl.v ---
112:                     vibrato_depth_o <= sample_data_i;
```
- **为什么是问题**：`fader_gear` 在档 1（上电默认）把 `ch2_i` 原样透传到 `vibrato_depth_o` ⇒ 推子行程 = `depth_raw_i` 0..4095 全量程可达。机制逐步：`depth_q` 峰值 = `4095 × 8` = **32760**；`triangle_q` 峰值 ±32767（Q1.15）；`mod_w = mod_product[30:15]` 峰值 = `32767 × 32760 / 32768` = **32759**；`vib_mul_r = mod × VIB_REF_INC`（38 700 000）峰值 **1.2677e12**；`vib_off = vib_mul_r >>> 15` 峰值 **38 689 000** ⇒ 归纳 **`vib_off_peak = 9448.2 × depth_raw_i`**；A4 的 `bv` = `440 × 2^32 / 48828.125` = **38 702 840** ⇒ 满深度时 `vib_off_peak ≈ bv(A4)` ⇒ 颤音摆幅 = ±100% 频率。`inc_main_w = bv + vib_off`（mod 2³²）在 `vib_off < −bv` 时翻成负数，翻负门限：低 B(5弦) 30.87 Hz / bv 2 715 000 / depth_raw ≥ **287**（**7.0%** 行程）；E1 41.20 Hz / 3 624 000 / **384**（9.4%）；E2 82.41 Hz / 7 249 000 / **767**（18.7%）；A2 110.0 Hz / 9 676 000 / **1024**（25.0%）；A4 440 Hz / 38 702 840 / 4096（100%，刚好不到）。后果（E1 + depth_raw=4095）：`inc = 3 624 000 − 38 689 000 = −35 065 000` ⇒ 相位累加器倒着走，等效 `|f| = 35 065 000 / 87 961 = 398.7 Hz` ⇒ 41.2 Hz 的音在三角波负半周（LFO 周期的一半）变成 398.7 Hz 倒放 ⇒ 音高跳 +3.27 个八度，不是噪声而是明确的错音。oscillator_bank.v:296-304 的注释承认"这是共享的绝对偏移（⛔ 不是每 lane 按各自基频比例）"并记成 `K-95`；2026-09-28 那次修复（tb/models/oscillator_bank_ref.v:371-391）只修掉"混合符号求值导致 vib_off 符号位被当幅值"这一个 Verilog 求值规则坑，"绝对偏移 > 基频增量"这个物理问题从来没被处理过 ⇒ K-95 记的是"按不按比例"，没记"绝对偏移能超过基频"。
- **改法**：（A）立即止血：在 `depth_target_w` 之前插上限，取 ±50 cents @ A4（50 cents = `2^(50/1200) − 1` = 2.93% ⇒ `vib_off ≤ 0.0293 × 38.7 M = 1.134 M` ⇒ `depth_q ≤ 960` ⇒ `depth_raw ≤ 120`）：
```verilog
localparam [11:0] DEPTH_MAX_RAW = 12'd120;   // ±50 cents @ A4（= 2.93%）
wire [11:0] depth_eff = (depth_raw_i > DEPTH_MAX_RAW) ? DEPTH_MAX_RAW : depth_raw_i;
wire [15:0] depth_target_w = {depth_eff, 3'b000};
```
验证上限足够：最低可听音 20 Hz ⇒ `bv = 1 759 220` > 1 134 000 ✅ 永不翻负。（B）结构修法（把绝对偏移改成比例偏移，真正关掉 K-95）：不需要 32 个乘法器 —— 一帧 1024 clk，TDM 只吃 `LANES+2 = 66` 拍，还剩 958 拍，用一个共享乘法器 + 32 拍轮转算 `vib_off[voice] = (bv[voice] >>> 15) × vibrato_mod`。
- **预期**：(A) 收益 = 消灭"错音"级缺陷，代价 = 16 LUT（1 个 12 位比较 + 1 个 12 位 2:1 mux），对 Fmax 可忽略。(B) 收益 = 同上 + 颤音深度与音高解耦；代价 = **1 个 DSP**（32×16⇒48 位；当前 DSP 22/118 够）、**32 × 32 = 1024 FF**（Register 17039/60780 ⇒ +6%，利用率 29%→31%）、新增 32 拍状态机（占一帧 3.1%，与 66 拍 TDM 完全并行不冲突）；⚠️ `vib_off` 从共享变 per-voice ⇒ inc 加法器输入从 1 根扇出 32 变 32 根独立（P1-9 扇出问题反而缓解），但 1024 FF 给 CLS 78% 的布线加压；⚠️ 需实测 Fmax（当前最差余量只有 +0.102 ns）。
- **怎么验**：新建 tb（例化 oscillator_bank，`DRUM_PITCH_ENV_EN=0`）：激励 `voice_active=1`、`base_inc[0]=32'd3_624_000`（E1）、`voice_drum=0`、`DETUNE_ON=0`，`vibrato_mod_i` 手动扫过 −32768…+32767（每拍一个值，共 32 拍）；断言 A1 `inc_main_w[31]` 恒为 0（现在在 `vibrato_mod_i ≤ −3_624_000` 时是 1）、A2 `phase_q` 单调不减、A3 `|phase_q 每拍增量 − 3_624_000| ≤ 1_134_000`（±50 cents 上限）。反证：把 `depth_eff` 两行注释掉重跑 ⇒ A1/A2/A3 必须 FAIL（三条全绿就是空判据，C83）。再跑 `sim\tb_all.ps1 -Filter vibrato` 与 `-Filter p5_osc_equiv`；⚠️ tb_vibrato_lfo.sv:63-96 只查 mod 的符号与过零、不查幅度（`depth_raw` 最大 12'hFFF，`RATE_MIN_INC/RATE_MAX_INC` 被改成 100/200 且 fast_dut 的 `RATE_*` = 32'h4000_0000）⇒ 改 `depth_target_w` 不会打红它，所以新 tb 是必须的。改 (B) 时 tb_p5_osc_equiv 必须仍 PASS（它比全部 64 个 `phase_q` 逐位），但 (B) 会把 `vib_off` 变成 per-voice 轮转值、与参考副本的"共享即时值"不再逐位相同 ⇒ 参考副本必须同步改，否则是假红。
- **来源**：ANVIL-02【P0-1】
@@@END
@@@PRIO=P0|SRC=ANVIL-02|ORIG=P0-2|MOD=rtl/w3b/vibrato_lfo.v
### 删掉死寄存器 rate_target_q 并把 44 位乘法云收窄到 22 位
- **位置**：rtl/w3b/vibrato_lfo.v:38-42（44 位乘法）、:48/:83/:104（死寄存器三处引用）、:108-123（用 rate_target_w 而非 rate_target_q）
- **现状**：
```verilog
 38:     wire [31:0] rate_span = RATE_MAX_INC - RATE_MIN_INC;
 39:     wire [43:0] rate_product = {32'd0, rate_raw_i} * {12'd0, rate_span};
 40:     wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
 41:                               ? RATE_MAX_INC
 42:                               : RATE_MIN_INC + rate_product[43:12];
 48:     reg [31:0]       rate_target_q;
 83:             rate_target_q  <= RATE_MIN_INC;
104:                 rate_target_q <= rate_target_w;
110:                     if (rate_inc_q < rate_target_w) begin
111:                         if ((rate_target_w - rate_inc_q) > RATE_SLEW_STEP)
```
- **为什么是问题**：(a) 死寄存器（确定性事实）：`rate_target_q` 花掉 **32 个 FF**，一个负载都没有；它的存在说明作者本来打算把 `rate_target_w` 打一拍再用于 slew —— 那一拍正好能把乘法云从 `rate_inc_q` 的反馈环里切出去，这一刀没接上。(b) 结构路径：`rate_raw_i`（来自 top.v:1788 `.vibrato_rate_o(vib_rate_sel)`）→ `{32'd0, rate_raw_i} * 945`（**44 位宽**；945 = `RATE_MAX_INC − RATE_MIN_INC` = 1031 − 86）→ `rate_product[43:12]` → `RATE_MIN_INC + …`（32 位加）→ **32 位比较 `rate_inc_q < rate_target_w`** → 32 位加/减 ±16 → `rate_inc_q` /D。宽度事实：`rate_raw_i` 只有 12 个有效位，`rate_span = 945` 只有 10 位，真实积上限 = `4095 × 945 = 3 869 775` = **22 位**（2^22 = 4 194 304）⇒ 声明的 44 位里有 **22 位是纯零填充**；945 = `0b11_1011_0001` ⇒ 6 个非零部分积 ⇒ 每一级加法树的位宽都被声明成 44 位。⚠️ 诚实边界：Gowin 的常量乘法优化**有可能**把 `{32'd0, rate_raw_i}` 收窄回 12 位（那么 44 位只是名义宽度、无实际代价），必须用综合报告确认，不能假设；但无论收窄与否，(a) 的死寄存器是确定的。
- **改法**：改法一（确定收益、零行为风险）把宽度收窄到真实需要的 22 位，与现写法逐位等价（44 位积 = 22 位积零扩展 ⇒ `rate_product[43:12]` = `product[21:12]` 零扩展）：
```verilog
localparam [21:0] RATE_SPAN22 = 22'd945;                  // = RATE_MAX_INC - RATE_MIN_INC
wire [21:0] rate_product = rate_raw_i * RATE_SPAN22;       // 12×10 -> 22 位，够
wire [31:0] rate_target_w = (rate_raw_i == 12'hFFF)
                          ? RATE_MAX_INC
                          : RATE_MIN_INC + rate_product[21:12];
```
改法二（把死寄存器接上，完成作者本来意图）：把 `110/111/115/116` 的 `rate_target_w` 换成 `rate_target_q`。⚠️ 改法二会改行为且会打红 tb_vibrato_lfo：该 tb 用 `CTRL_SLEW_DIV=1`（⇒ `slew_count_q >= 0` 恒真 ⇒ 每次 commit 都 slew）、`RATE_MIN_INC=100`、`RATE_MAX_INC=200`、`RATE_SLEW_STEP=10`，断言 :78 `rate_inc == 32'd110`、:79 `== 32'd120`、:80 `== 32'd130`；用 `rate_target_q` 后第 1 次 commit 时它还是旧目标（100）⇒ `rate_inc == 100` ⇒ 78/79/80 三条全红（随后 110/120/130 依次后移一拍）。推荐顺序：先做改法一 + 删掉死寄存器，把"要不要接这一拍"当成独立决策、带自己的契约变更走。
- **预期**：改法一 = 6 级加法树的位宽从 44 → 22，每级进位链减半（ALU 估算 `6 × 44/2 = 132` → `6 × 22/2 = 66`，**省 66 ALU**，占 PnR 总 ALU 7372 的 0.9%），深度不变，代价 0。删死寄存器 = **省 32 FF**（Register 17039 → 17007，0.19%），代价 0。改法二 = 把整个乘法云 + 第一级加法移出反馈环；代价 = 行为变更 + 打红 3 条既有断言，颤音速率变化滞后 1 次 commit（**0.5 ms**，听感不可闻）。
- **怎么验**：(1) 改法一的等价性判据：临时把 `rate_product[21:12]` 写成 `rate_product[20:11]`（差 1 位）⇒ tb_vibrato_lfo 的 78/79/80 必须变红；若不变红说明该 tb 对 rate 的数值没有约束（只对步长有约束），需补精确值断言。(2) 44 位是否真有代价：改前/改后各跑一次 `sim\gowin_build.ps1`，`Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'LUT|ALU|DSP|Register'`，判据 ALU 下降 ≈66 ⇒ 44 位确实白付；ALU 不变 ⇒ 工具已自动收窄，改法一只是防工具不优化，收益为零（也要如实记录）。(3) 是不是关键路径：探针 SDC（⛔ 不碰 constr/top.sdc）`set_max_delay -from [get_pins {g_sound.u_vibrato_lfo/rate_target_q_*_s0/Q}] -to [get_pins {g_sound.u_vibrato_lfo/rate_inc_q_*_s0/D}] 5.000`，读 Gowin2026_tr_content.html 的 Logic Level 与 Data Delay：改前 `Data Delay > 8 ns` 或 `Logic Level ≥ 12` ⇒ 结构性长路径，改法一/二都要做；`Data Delay < 5 ns` ⇒ 布局掩盖，降级为 P2，只做删死寄存器。
- **来源**：ANVIL-02【P0-2】
@@@END
@@@PRIO=P0|SRC=ANVIL-02|ORIG=P0-3|MOD=rtl/w3b/vibrato_lfo.v
### 用手写 16 级 ripple-carry 取负改成 `(~x)+16'd1`，把 16 级 LUT 链压成一条进位链
- **位置**：rtl/w3b/vibrato_lfo.v:52-76
- **现状**：
```verilog
 53:     wire [14:0] tri_mag = phase_q[30] ? ~phase_q[29:15] : phase_q[29:15];
 56:     function [15:0] twos_complement16;
 61:             carry = 1'b1;
 62:             for (bit_i = 0; bit_i < 16; bit_i = bit_i + 1) begin
 63:                 twos_complement16[bit_i] = (~value[bit_i]) ^ carry;
 64:                 carry = (~value[bit_i]) & carry;
 68:     wire [15:0] triangle_bits = phase_q[31]
 69:                                ? twos_complement16({1'b0, tri_mag})
 70:                                :  {1'b0, tri_mag};
 72:     wire signed [31:0] mod_product = triangle_q * $signed(depth_q);
 75:     wire [15:0] mod_bits = mod_product[30:15];
```
- **为什么是问题**：第 64 行 `carry = (~value[bit_i]) & carry;` 是一条纯 2 输入 AND 串联链，`carry` 只能经 `bit_i = 0 → 15` 逐级传播 ⇒ **16 个 LUT 级联**。⚠️ 关键：这不是加法器 —— Gowin 的专用进位链（ALU 资源，每单元 2 bit）只在综合器识别出 `+`/`−` 运算符时才被推断，而这里是手写 `&` 链，综合器没有义务映射成进位链；而作者写这段的动机恰恰是绕开 Gowin 的 `+`/`-` 宽度推断 ⇒ 大概率是 16 级普通 LUT 链。这条链全部串在一拍里：`phase_q[31] → tri_mag（15 位 2:1 mux）→ twos_complement16（16 级 LUT 链）→ triangle_q → mod_product = triangle_q × $signed(depth_q)（16×16 有符号乘法）→ mod_product[30:15] → mod_o → u_oscillator_bank/vibrato_mod_r/D`。sim/evidence/rightboard-vibrato-fix-20261008/README.md:12-14 记录的修前实测最差路径正是这一条的上游：`u_vibrato_lfo/phase_q_17_s0/Q → u_oscillator_bank/gen_lane[*].phase_q_*_s0/D`，**21.4 ns**（约束 18.181）、slack **−3.272 ns**、**1630 个端点同时违例**、TNS **−2718.329 ns**。那次修复在 oscillator_bank 侧插了 `vibrato_mod_r`/`vib_mul_r` 两级流水，把终点从 `gen_lane[*].phase_q` 拉回到 `vibrato_mod_r`，**但链本身的 16 级 ripple-carry 一级没减**，只是不再是最差路径了（当前 impl/pnr/Gowin2026.timing_paths 里 `vibrato_lfo` 出现 **0** 次）⇒ 结论：结构性长路径，当前被布局掩盖。
- **改法**：`~x + 1` 就是 16 位补码取负，与现有函数逐位等价，且不会触发作者担心的宽度扩张（两个操作数都是 16 位 ⇒ 结果 16 位）：
```verilog
    // 删掉 twos_complement16 整个 function，替换为：
    wire [15:0] tri_pos = {1'b0, tri_mag};          // 16 位，MSB 恒 0
    wire [15:0] tri_neg = (~tri_pos) + 16'd1;       // 16 位进位链取负，与旧函数逐位相同
    wire [15:0] triangle_bits = phase_q[31] ? tri_neg : tri_pos;
```
`(~tri_pos)` 是 16 位取反（16 个 LUT，并行、不在关键路径上）；`+ 16'd1` 是一条 16 位进位链 = **8 个 ALU**（每 ALU 2 bit）⇒ 延迟约 **0.3~0.5 ns**，而不是 16 级 LUT 的 **8~11 ns**；两个操作数都是 `16'd` 字面量宽度 ⇒ 结果宽度 = max(16,16) = 16。
- **预期**：延迟从 **16 级 LUT** 降到 **1 条进位链**，估算省 **8~10 ns**（按 Gowin LUT4 一级 ~0.5~0.7 ns 含布线）；资源省 16 个 LUT2（`^` 那 16 个 XOR 保留在进位链的 ALU 里），`ALU +8`、`LUT −16`；代价 **0**（逐位等价，无 FF，无行为变更）。对 Fmax 当前不体现（不在 Top-25），但这是把 vibrato_lfo 整条链余量从薄变厚最便宜的一刀。
- **怎么验**：(1) 逐位等价判据（必须做）：新 tb 用同一个 `phase_q` 序列驱动新旧两份 vibrato_lfo（或把旧 function 留成 `_ref` 模块），激励 fast instance（`RATE_MIN_INC = RATE_MAX_INC = 32'h4000_0000`）跑满 4 个完整三角波周期、`depth_raw` 扫 96 / 4095 两档共 ≥64 拍，断言 `dut.mod_o === ref.mod_o`（每一拍）；反证：把 `(~tri_pos) + 16'd1` 改成 `+ 16'd0` ⇒ 必须全红。⚠️ 现有 tb_vibrato_lfo.sv:93-96 只查 mod 的符号与过零（`>0`/`==0`/`<0`），查不出 1 LSB 的取负错误（−0 与 −1 都能满足 `<0`）⇒ 必须补逐位比对。(2) 是不是 16 级 LUT 链的实测判据：探针 SDC `set_max_delay -from [get_pins {g_sound.u_vibrato_lfo/phase_q_*_s0/Q}] -to [get_pins {g_sound.u_vibrato_lfo/mod_product_*_s0/D}] 4.000`，`Select-String -Path impl\pnr\Gowin2026_tr_content.html -Pattern 'vibrato_lfo'`：改前 Logic Level ≥ 16 ⇒ 确认是 16 级 LUT 链；改后应降到 ≤ 3（1 级取反 + 1 级进位链 + 1 级 mux）；⚠️ 若改前 `Logic Level ≤ 5` ⇒ 工具已映射成进位链 ⇒ 降级为 P3（只是可读性问题），并如实记录。
- **来源**：ANVIL-02【P0-3】
@@@END
@@@PRIO=P0|SRC=ANVIL-02|ORIG=P0-4|MOD=rtl/w3b/oscillator_bank.v,rtl/w3b/note_manager.v
### 把鼓扫频深度也在提交拍锁存，堵住 DRUM_CLS_EXT=1 仍存在的 32 拍深度窗口
- **位置**：rtl/w3b/oscillator_bank.v:407-420（深度仍由 bv 算）、:367（bv 来源）；rtl/top.v:4232、:4205-4206；rtl/w3b/note_manager.v:1518、1560、1575-1578、1615
- **现状**：
```verilog
407:             //   ⭐ **本档的扫频深度**（⭐ `bv >> (LSB_SH + 本档 SH)` ⇒ ⭐ 纯连线 ✅）
411:             wire [DRUM_SWEEP_W-1:0] sweep_kick =
412:                 bv >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH);
413:             wire [DRUM_SWEEP_W-1:0] sweep_tom  =
414:                 bv >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH);
367:             wire [PHASE_W-1:0] bv = base_phase_inc_i[vg*PHASE_W +: PHASE_W];
--- top.v ---
4232:             .base_phase_inc_i   (nm_phase),
--- note_manager.v ---
1560:             rot_cnt  <= rot_cnt + 5'd1;                 // ⭐ 自由运行（⭐ 5 位回绕 ✅）
1575:             if (rot_ok)
1576:                 phase_tr[rot_cnt] <= ((semi_cur == 5'sd0) ||
1577:                                       (src_r[rot_cnt] == 3'd3) || (src_r[rot_cnt] == 3'd4))
1578:                                    ? rot_base : (prod_w >>> 15);
1615:         assign voice_phase_inc_o[gp*PHASE_W +: PHASE_W] = phase_tr[gp];
```
- **为什么是问题**：`rot_cnt` 是 50 MHz 下的自由运行计数器（note_manager.v:1560 的 `rot_cnt <= rot_cnt + 5'd1;` 无条件执行）⇒ `phase_tr[g]` 每 **32 拍（0.64 µs）** 才被重写一次，而 `sample_tick_i` 的周期是 **1024 拍（20.48 µs）**；两者同源但 `rot_cnt` 在哪个拍恰好等于 `g` 是固定的、与 `sample_tick_i` 无关。A3 的正确修法（sim/evidence/a3-proper-20261008/README.md）把分类（`is_kick`/`is_tom`）搬到 note_manager.ST_COMMIT2 提交那一刻 ⇒ 分类零窗口 ✅；🔴 但 `sweep_load` 里的 `sweep_kick`/`sweep_tom` 仍然乘 `bv`（:411-414）—— `bv` 就是那个轮转刷新、最多滞后 32 拍的值 ⇒ "深度"这一半仍然是旧值。数字（用 top.v:4205-4206 的实际参数 `DRUM_TOM_MAX=20_000_000`、`DRUM_TOM_SWEEP_SH=3`、`DRUM_SWEEP_LSB_SH=8`、`DRUM_KICK_SWEEP_SH=0`）：同一 voice 上底鼓(5 368 709)紧跟嗵鼓(17 895 697) ⇒ 期望 `17 895 697 >> 11` = **8 739**，实际取到滞后的 `bv = 5 368 709` ⇒ `5 368 709 >> 11` = **2 621** ⇒ **浅 3.33×**；嗵鼓紧跟底鼓 ⇒ 期望 `5 368 709 >> 8` = **20 971**，实际 `17 895 697 >> 8` = **69 905** ⇒ 超 16 位 ⇒ 截断成 `69 905 − 65 536` = **4 369** ⇒ **深 4.8×**（且带截断）。⇒ 底鼓的起音频率 = 标称 × (1 + 深度/标称) 里那个"深度"直接错 ⇒ 起音扫频要么完全听不出、要么过度到糊；这正是 A3 想消灭的"鼓不像鼓"家族缺陷的另一半。为什么 A3 的记录没发现它：a3-proper-20261008/README.md 的 6 条判据（tb_osc_drum_cls.sv 的 A1/A2/A3/B1/B2/B3）全部只驱动 `base_phase_inc_i` 的静态值，没有"同一 voice 上先后两件不同鼓"的时序场景 ⇒ 分类对了、深度错了，判据照样全绿。
- **改法**：（A）最小改动（推荐）：让 note_manager 在 ST_COMMIT2 提交时顺便把扫频深度也锁存（与 `drum_cls_r` 同一个 64 FF 块、同一拍），新开一根 `voice_drum_depth_o[POLY_TARGET*DRUM_SWEEP_W-1:0]`（32 × 16 = 512 bit），oscillator_bank 在 `DRUM_CLS_EXT != 0` 时直接用它、不再乘 `bv`。新增 FF **512**（note_manager 侧 32 × 16）、新增端口 512 bit 一根总线、删掉 `DRUM_CLS_EXT=1` 档下 `sweep_kick`/`sweep_tom` 两个 32 位移位器（纯连线，省 0 LUT）；参数门控与 `DRUM_CLS_EXT` 同一个参数 ⇒ `DRUM_CLS_EXT=0`（全部 tb）时新端口不参与综合、Z 悬空不传播 ⇒ 老 tb 一个不改 ✅。（B）零成本替代（若不想加 FF）：把 `sweep_load` 的装载延迟到"`phase_tr[g]` 已刷过至少一次"之后再认 —— 即在 `gen_voice` 里加一个"本 voice 的 phase_tr 自上次起音以来已刷新"的标志（32 × 1 = 32 FF），条件不满足就不装载（保持 0 ⇒ 不扫频），代价是丢一拍扫频（起音第一个采样拍不扫），听感影响小于"深度错 3.3×"。
- **预期**：(A) 代价 Register 17039 → 17551（+3.0%，利用率 29% → 31%），CLS 78% 上加 512 个 FF 的布线压力；收益 = 消除 3.33×/4.8× 的起音深度错。(B) 代价 +32 FF、丢一拍扫频；收益同上。
- **怎么验**：新判据（tb_drum_pitch_env 的时序扩展，或新建 tb_drum_sweep_window.sv）：单实例 oscillator_bank，`DRUM_CLS_EXT=1`，`DRUM_PITCH_ENV_EN=1`；激励（同一 voice 0，两击）：第 1 击 `drum_cls_i[1]=1`（底鼓）、`base_inc[0]=32'd5_368_709`，跑 8 拍；第 2 击 `drum_cls_i[0]=1`（嗵鼓）、`base_inc[0]=32'd17_895_697`，⚠️ 关键：在"base_inc 改变后的第 1 拍"就发 `voice_phase_rst_i[0]=1`（窗口内起音）。断言 W1 装载那一拍的 `sweep_q == 17_895_697 >> 11 == 16'd8739`（现在会拿到 `5_368_709 >> 11 == 2621` ⇒ FAIL）、W2 随后 `sweep_q` 的衰减曲线与 W1 的初值一致（τ = 2^10 拍）。反证（必须做）：把 note_manager 的 phase_tr 轮转人为改成"提交当拍立即刷新该 lane"（探针副本）⇒ W1 必须转绿 ⇒ 证明红是窗口造成的。顺带跑 `-Filter drum`、`-Filter osc`。⚠️ 参考副本同步纪律：若走 (A) 并新增端口，tb/models/oscillator_bank_ref.v 必须同步加同一条路径（且只在 `DRUM_CLS_EXT!=0` 时生效），否则 tb_p5_osc_equiv 会假红（历史坑，见 rightboard-vibrato-fix-20261008/README.md:77-83）。
- **来源**：ANVIL-02【P0-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-02|ORIG=P1-5|MOD=rtl/w3b/oscillator_bank.v,tb/models/oscillator_bank_ref.v,tb/w3b/tb_p5_osc_equiv.sv
### 把逐位等价判据的 test 档激励换成生产形状并补测退出沿
- **位置**：rtl/w3b/oscillator_bank.v:437-441＋:453-454；tb/models/oscillator_bank_ref.v:320-323＋:492；rtl/w3b/test_mode_ctrl.v:78-82；tb/w3b/tb_p5_osc_equiv.sv:209-217
- **现状**：
```verilog
--- RTL（每 voice 一份）---
440:             wire act_v = test_mode_i ? test_lane_active_i[vg*OSC_PER_VOICE]
441:                                      : voice_active_i[vg];
453:                 end else if (sample_tick_i) begin
454:                     act_d <= act_v;
--- 参考副本（每 lane 一份）---
321:             wire lane_active = test_mode_i
322:                              ? test_lane_active_i[g]
323:                              : voice_active_i[VOICE_IDX];
492:                     lane_active_d <= lane_active;
--- test_mode_ctrl.v（奇数 lane 恒为 0）---
 80:                 assign test_lane_active_o[LANE] = selected && (o == 0);
--- tb_p5_osc_equiv.sv ---
210:         test_mode = 1'b1;
211:         test_lane_active = 64'hFFFF_FFFF_FFFF_FFFF;
215:         test_mode = 1'b0;
217:         $display("--------------------------------------------------");
```
- **为什么是问题**：RTL 把 `act_d` 上提到 voice 级（P5-② 的优化），取的是该 voice 的 osc0 那一位 `test_lane_active_i[vg*2]`；参考副本保留 lane 级，lane `2vg+1`（失谐副本）取 `test_lane_active_i[2vg+1]`。在生产激励下（test_mode_ctrl.v:80 奇数 lane 恒为 0）：test 档中（voice 被选中）RTL `act_d_bus[vg]` = **1**，参考副本 lane `2vg+1` 的 `lane_active_d` = **0**。⇒ 在 `test_mode_i: 1 → 0` 的第一个 `sample_tick_i`，若 `voice_active_i[vg] = 1`（含 Release 尾巴，`live_mask = gate_r | retrig_low | env_active_i`）：RTL 走 `lane_active && !act_d_bus[VOICE_IDX]` = `1 && !1` = **0**，且 `phase_rst_lane` = 0 ⇒ 不装载 ⇒ 走 else 继续累加；参考副本 lane 2vg+1 走 `1 && !0` = **1** ⇒ 装载 `phase_seed`（90°）＋装载 `sweep_load`。⇒ 同拍 `phase_q` 不同 ⇒ tb_p5_osc_equiv.sv:117-155 的 `PHCMP(奇数 lane)` 会报 mismatch。这是"生产可达"的状态：top.v:4219 `.voice_active_i(nm_active)`，而保留池（节拍器/鼓机）的 `live_mask` 恒为 1（top.v:4261-4270 记录了"节拍器 EVT_KIND 是常量 note_on、⛔ 永不发 note_off"）⇒ 离开 Test Mode 那一刻，保留池那几个 voice 确实处在 `voice_active = 1`。为什么 tb 抓不到（两个独立缺口）：①:211 用 `64'hFFFF_FFFF_FFFF_FFFF` ⇒ 奇数 lane 也被置 1 ⇒ 参考副本 lane `2vg+1` 的 `lane_active_d` 也变成 1 ⇒ 两侧同值、差异被抹平；②:215-217 `test_mode = 1'b0;` 之后紧接着 `$display` 和 `$finish` ⇒ 退出沿那一拍从来没有被比过。
- **改法**：改法一（改判据，零 RTL 风险，推荐先做）：在 E 段末尾补 4 帧并把激励换成生产形状：
```verilog
        test_mode = 1'b1;
        test_lane_active = 64'h5555_5555_5555_5555;   // ⭐ 生产形状：只有偶数 lane
        for (i = 0; i < 64; i = i + 1)
            test_phase_inc[i*32 +: 32] = 32'd2_000_000 + i * 32'd999_983;
        for (f = 0; f < 20; f = f + 1) frame;
        // ⭐⭐ 新增：退出沿 + 退出后 4 帧，voice_active 保持全 1（模拟保留池恒响）
        voice_active = 32'hFFFF_FFFF;
        test_mode = 1'b0;
        for (f = 0; f < 4; f = f + 1) frame;
```
改法二（修 RTL，让两侧真正等价）：把 `act_d_bus` 的语义改成"该 voice 的任一 lane 在响"：
```verilog
wire act_v = test_mode_i ? (test_lane_active_i[vg*OSC_PER_VOICE] |
                            test_lane_active_i[vg*OSC_PER_VOICE + 1])
                         : voice_active_i[vg];
```
⚠️ 这一改会动 `sweep_q` 的装载条件（:458），而 tb_drum_pitch_env / tb_oscillator_bank 可能依赖现行为 ⇒ 必须先跑 tb 再改。
- **预期**：改法一 = 把"逐位等价"这句话变成真的（生产可达状态下成立），代价 **0**（只改 tb），对 Fmax 0。改法二 = 同上 + 消除 1 帧（20.5 µs）的"起音相位复位被跳过"；代价 = 1 个 OR 门/voice，可能打红 tb_drum_pitch_env（需实测）。
- **怎么验**：`sim\tb_all.ps1 -Filter p5_osc_equiv`：补完 4 帧后第一次跑就应该红（`FAIL frame N: lane 1 PHASE ref=… dut=…`，且全是奇数 lane）；若 0 mismatch ⇒ 我的分析错了（本身是有价值的证伪），本条降级为 P3，并把这个"退出沿已覆盖"的事实写回 tb 注释。反向验证：把 :211 改回 `64'hFFFF_FFFF_FFFF_FFFF` ⇒ 必须转绿 ⇒ 证明红是激励形状造成的，不是流水/时序问题。
- **来源**：ANVIL-02【P1-5】
@@@END
@@@PRIO=P1|SRC=ANVIL-02|ORIG=P1-6|MOD=rtl/w3b/oscillator_bank.v
### 给扫频深度自检补上 DRUM_TOM_MAX 一路（现在只守 KICK）
- **位置**：rtl/w3b/oscillator_bank.v:911-925（自检）、:411-414（两个深度都要守）；rtl/top.v:4195-4206、:4200-4201
- **现状**：
```verilog
918:         if ((DRUM_PITCH_ENV_EN != 0)
919:             && (((DRUM_KICK_MAX - 1) >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH))
920:                 >= (1 << DRUM_SWEEP_W)))
921:             $display("ERROR [oscillator_bank] 扫频深度被截断：DRUM_KICK_MAX=%0d >> (%0d+%0d) 超过 %0d 位",
922:                      DRUM_KICK_MAX, DRUM_SWEEP_LSB_SH, DRUM_KICK_SWEEP_SH, DRUM_SWEEP_W);
--- top.v ---
4195:             //   ⭐ **① `DRUM_TOM_MAX` 15M → 20M**（⭐ 嗵鼓档上界 167.6 → **223.3 Hz**）
4200:             //      📌 **自检**：⭐ `oscillator_bank.v` 的 `sweep_q`"扫频深度截断"自检**只守 `DRUM_KICK_MAX`**
4201:             //         ⇒ ⭐ 抬高 `DRUM_TOM_MAX` **不会**触发它 ✅
4205:             .DRUM_TOM_MAX     (20_000_000),
4206:             .DRUM_TOM_SWEEP_SH(3),
```
- **为什么是问题**：`DRUM_SWEEP_W = 16` ⇒ 可表示深度上限 65 535。当前交付（TOM_MAX=20M, TOM_SH=3）：`20 000 000 >> 11` = **9 765** < 65 536 ✅ 存 9 765；把 `DRUM_TOM_SWEEP_SH` 改成 **0**：`20 000 000 >> 8` = **78 125** ≥ 65 536 🔴 实际存 `78 125 & 0xFFFF` = **12 589**，🔴 自检不报警（只看 KICK）；`DRUM_TOM_MAX=40M`（TOM_SH=3）：19 531 ✅；`DRUM_TOM_MAX=200M`（TOM_SH=3）：`200 000 000 >> 11` = **97 656** 🔴 实际存 `97 656 & 0xFFFF` = **32 120**，🔴 不报警。⇒ TOM_SH=0 那一行的净效果：嗵鼓扫频深度从"设计意图 78 125"变成"实际 12 589" ⇒ **浅 6.2 倍**，零报错、零警告 —— 这正是 K-106（⛔ 不许静默失效）要防的事，但防线只铺了一半。
- **改法**：在 :922 之后镜像一份 TOM 的检查，并补一条 `so_v` 的移位溢出检查（见 P2-11）：
```verilog
        if ((DRUM_PITCH_ENV_EN != 0)
            && (((DRUM_TOM_MAX - 1) >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH))
                >= (1 << DRUM_SWEEP_W)))
            $display("ERROR [oscillator_bank] 嗵鼓扫频深度被截断：DRUM_TOM_MAX=%0d >> (%0d+%0d) 超过 %0d 位",
                     DRUM_TOM_MAX, DRUM_SWEEP_LSB_SH, DRUM_TOM_SWEEP_SH, DRUM_SWEEP_W);
```
- **预期**：把"参数调错 ⇒ 静默变浅"变成"参数调错 ⇒ 仿真启动就报 ERROR"；代价 **0**（initial 块只在仿真跑，综合器忽略；oscillator_bank.v:899-901 已确立这套路）；对 Fmax **0**（initial 不进网表）。
- **怎么验**：探针副本（⛔ 不碰交付树）里把 `.DRUM_TOM_SWEEP_SH(3)` 改成 `0`，跑 `sim\tb_all.ps1 -Filter drum`：改前日志里没有任何 `ERROR [oscillator_bank] 嗵鼓扫频深度被截断` ⇒ 缺陷确认；改后必须打印该行（且是 ERROR 不是 WARNING）；反向验证：改回 `3` ⇒ 必须不再打印。
- **来源**：ANVIL-02【P1-6】
@@@END
@@@PRIO=P1|SRC=ANVIL-02|ORIG=P1-7|MOD=rtl/w3b/voice_i2s_chain.v
### 把 voice_i2s_chain 的 JUSTIFY 从 1 改成 0，与生产 top.v 对齐
- **位置**：rtl/w3b/voice_i2s_chain.v:71-77＋:4；rtl/top.v:4616-4620；rtl/w3c/i2s_tx.v:21-29、:160-165；rtl/w3b/voice.v:101
- **现状**：
```verilog
--- voice_i2s_chain.v ---
 71:     i2s_tx #(
 72:         .SAMPLE_W  (24),
 73:         .DATA_BITS (16),
 74:         .SLOT_BITS (32),
 75:         .JUSTIFY   (1),
 76:         .MSB_DELAY (1),
 77:         .LRCK_POL  (0)
--- top.v（生产通路 = 0）---
4619:         .JUSTIFY   (0),           // ⭐ 0 = 标准 I2S 左对齐（MAX98357A）
4620:         .MSB_DELAY (1),           // 标准 I2S 的 MSB 延迟 = 1 BCK（⛔ 不用改）
--- i2s_tx.v ---
 21: //    · `JUSTIFY=0` 左对齐（Philips 标准 I2S）—— ⭐ **当前默认**（Tang Console / `MAX98357A`）
 22: //    · `JUSTIFY=1` 右对齐（LSBJ / 日本格式）—— ⚠️ 旧板 NEO Dock / `PT8211` 用这个
160:             if (JUSTIFY == 0) begin
161:                 i2 = b - MSB_DELAY;                    // 左对齐：数据占 [MSB_DELAY, +DATA_BITS)
164:                 i2 = b - (SLOT_BITS - DATA_BITS);      // 右对齐（LSBJ）：数据占时隙尾部
```
- **为什么是问题**：`SLOT_BITS = 32`、`DATA_BITS = 16` ⇒ `JUSTIFY=1` 把 16 位数据放在时隙的 **BCK 16..31**（尾部），`JUSTIFY=0` 放在 **BCK 1..16** ⇒ 同一个 32 位时隙里两种配置的数据位置相差 **15 个 BCK**。新板（MAX98357A / PCM5102A）按 Philips 标准 I2S 解析 ⇒ 读 **BCK 1..16** ⇒ 在 `JUSTIFY=1` 下读到的是时隙头部，而数据在尾部 ⇒ 读到的全是填充位（静音或错位数据）。voice.v:101 把 16 位样本放到 24 位的高 16 位（`sample_out <= {scaled_16, {(SAMPLE_W-16){1'b0}}};`），`i2s_tx.top_bits()` 取高 16 位 ⇒ 拿到 `scaled_16` ✅ —— 所以问题纯粹是 `JUSTIFY`，不是位宽。这是"T10 集成缝"（voice_i2s_chain.v:3 自称）在新板上的确定性失效：任何人在新板上例化这个 chain（bringup/synth_check_top.v:341 已经这么做了）都会得到静音。
- **改法**：`.JUSTIFY (0),` 与 top.v:4619 一致（新板 MAX98357A / PCM5102A = 标准 I2S）；并把 voice_i2s_chain.v:4 的注释"the production I2S TX"改成明确口径（它是 T10 历史缝，不是生产通路）。
- **预期**：新板上这条链从静音变出声；代价 **0**（参数常量）；对 Fmax **0**（voice_i2s_chain 不在 rtl/top.v 的网表里，见 P2-20）。
- **怎么验**：`sim\tb_all.ps1 -Filter i2s`；⚠️ 现有 tb_i2s_tx* 直接例化 i2s_tx 并显式传参 ⇒ 抓不到 chain 里的参数写错。需要新判据：新 tb（例化 voice_i2s_chain，不传 JUSTIFY）断言 J1 chain 内 u_i2s_tx 的 JUSTIFY 参数值 == top.v 生产实例的值（defparam 反射不可行 ⇒ 改为在同一 tb 里并列例化生产参数版 i2s_tx 与 chain，同激励比 HP_DIN 逐位）、J2 同一个 16 位样本经两条路输出的 HP_DIN 序列逐位相同；反证：把 chain 的 JUSTIFY 改回 1 ⇒ J1/J2 必须红。
- **来源**：ANVIL-02【P1-7】
@@@END
@@@PRIO=P1|SRC=ANVIL-02|ORIG=P1-8|MOD=rtl/w3b/oscillator_bank.v,rtl/clk_gen.v
### 把 LANES 自检的判据从 LANES>1024 改成 LANES+2 ≤ CLK_PER_SAMPLE
- **位置**：rtl/w3b/oscillator_bank.v:899-905（自检）、:718-738（TDM 实际拍数）；rtl/clk_gen.v:26
- **现状**：
```verilog
899:     // ⚠️ 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）：
900:     //    ⭐ `LANES` 必须 ≤ `CLK_PER_SAMPLE`（1024），否则 **TDM 跑不完一帧**
902:     initial begin
903:         if (LANES > 1024)
904:             $display("ERROR [oscillator_bank] LANES=%0d > 1024（每帧可用 clk 数）=> TDM 跑不完一帧，A6 必然失败",
905:                      LANES);
--- oscillator_bank.v TDM ---
729:             if (cnt == LANES[LW:0])
730:                 rendering <= 1'b0;          // 全部取完
734:             valid_r <= (cnt == LANES[LW:0]);
--- clk_gen.v ---
 26:     parameter integer CLK_PER_SAMPLE = 1024,   // fs 分频：50 MHz / 1024 = 48.828125 kHz
```
- **为什么是问题**：oscillator_bank 没有 `CLK_PER_SAMPLE` 参数，自检里的 `1024` 是一个手抄的魔数。`cnt` 走 `0 → LANES`（**LANES+1 个状态**），再加 `valid_r` 那一拍 ⇒ **共 LANES+2 拍**。对照表：`CLK_PER_SAMPLE=1024`（当前）一帧可用 1024 拍、TDM 需要 66、自检判"64 > 1024?"= 否、结果 ✅ 余量 15.5×；512 ✅；256 ✅；128 ✅；**64** ⇒ 一帧 64 拍、TDM 需要 **66**、自检仍判"否"🔴 ⇒ **TDM 跨帧**：`osc_valid_o` 在新一帧的 `sample_tick_i` 之后才拉高 ⇒ tdm_render_mixer 读到**半旧半新**的样本总线，**零报错**。⇒ 自检的判据写错了：它守的是 `LANES > 1024`，而真正的不变量是 **`LANES + 2 ≤ CLK_PER_SAMPLE`**；并且 `1024` 这个数在 clk_gen.v 和 oscillator_bank.v 两处各写一遍（跨模块常量重复，AGENTS.md 记录的复发缺陷类）。
- **改法**：给 oscillator_bank 加参数 `parameter integer CLK_PER_SAMPLE = 1024,`（与 clk_gen.CLK_PER_SAMPLE 同源，顶层必须显式传同一个值），自检改为：
```verilog
    initial begin
        // ⭐ 真正的不变量：TDM 必须在【一帧之内】跑完（cnt 走 0..LANES 再加 valid 一拍）
        if ((LANES + 2) > CLK_PER_SAMPLE)
            $display("ERROR [oscillator_bank] TDM 需要 LANES+2=%0d 拍 > 一帧 CLK_PER_SAMPLE=%0d ⇒ 跨帧，A6 失败（现象=随机丢样本）",
                     LANES + 2, CLK_PER_SAMPLE);
```
并在 top.v:4163-4215 的例化里补 `.CLK_PER_SAMPLE(CLK_PER_SAMPLE)`（top.v 已有同名参数）。
- **预期**：把"改 CLK_PER_SAMPLE ⇒ 静默丢样本"变成"启动即 ERROR"；代价 = 1 个参数 + 1 行 initial（`LANES + 2` 是编译期常量，**0 硬件**）；对 Fmax **0**。
- **怎么验**：探针副本把 clk_gen 的 `CLK_PER_SAMPLE` 改 `64`、oscillator_bank 传 `64`：改前日志无任何 ERROR（tb 直接驱动 `sample_tick_i`、不看 clk_gen，所以除 tb_p5_osc_equiv 外看不出问题）；改后必须打印 ERROR。更强的判据（新 tb，端到端）：tb_top_* 里把 `CLK_PER_SAMPLE` 传 `64`，断言 `osc_valid_o` 在下一个 `sample_tick_i` 之前必须已经拉高过一次 ⇒ 现在必红。
- **来源**：ANVIL-02【P1-8】
@@@END
@@@PRIO=P1|SRC=ANVIL-02|ORIG=P1-9|MOD=rtl/w3b/oscillator_bank.v,rtl/w3b/note_manager.v
### 把 vib_off 的 1024 负载扇出拆成每 voice 一份（⛔ 这条路上不许加流水）
- **位置**：rtl/w3b/oscillator_bank.v:446-447、:466-471、:531-533、:569-571、:682-683；rtl/w3b/note_manager.v:1560、:1615
- **现状**：
```verilog
446:             wire [PHASE_W-1:0] so_v =
447:                 {{(PHASE_W-DRUM_SWEEP_W){1'b0}}, sweep_q} << DRUM_SWEEP_LSB_SH;
469:             assign inc_main_w[vg*PHASE_W +: PHASE_W] = bv + vib_off[PHASE_W-1:0] + so_v;
470:             assign inc_det_w [vg*PHASE_W +: PHASE_W] =
471:                 inc_main_w[vg*PHASE_W +: PHASE_W] + dv;
531:             wire [PHASE_W-1:0] lane_inc_base =
532:                 (OSC_IDX != 0) ? inc_det_w[VOICE_IDX*PHASE_W +: PHASE_W]
533:                                : inc_main_w[VOICE_IDX*PHASE_W +: PHASE_W];
569:             wire [PHASE_W-1:0] lane_inc = test_mode_i
570:                              ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
571:                              : lane_inc_base;
682:                         if (lane_active)
683:                             phase_q <= phase_q + lane_inc;
```
- **为什么是问题**：串联深度（Verilog 左结合 ⇒ `bv + vib_off` 先算，再 `+ so_v`）：偶数 lane（`OSC_IDX=0`）**3 级** = `(bv + vib_off)` → `+ so_v` → `test_mode_i` mux → `phase_q + lane_inc`；**奇数 lane（`OSC_IDX=1`）4 级** = 再插一级 `+ dv`。⚠️ 这是"深度最优"的：4 项和用 2 输入加法器最少就是 3 级（`(bv+dv) + (vib_off+so_v)`），再加相位累加那一级 = 4 级，换任何写法都不会更浅 ⇒ 不是写法不好，是结构本身的深度。ALU 占用（Gowin ALU = 每单元 2 bit 进位链；PnR 报告 ALU 7372）：`bv + vib_off` 32 个 × 32 位 = 512；`+ so_v` 32 × 32 = 512；`+ dv`（仅奇数 lane 用，但 32 个都综合出来）32 × 32 = 512；`phase_q + lane_inc` **64** × 32 = **1024**；小计 **2 560** ⇒ 这四组加法器独占 ALU 7372 的 **34.7%**（还没算 sweep_dec 的 32 × 16 位 = 256）。扇出：`vib_off[31:0]` 是一根共享网（:333 一个 48 位寄存器的切片），负载 = `32 voice × 32 bit` = **1 024**；`so_v` 同理。当前状态（已 grep 证实）：impl/pnr/Gowin2026.timing_paths 的 25 条 setup 最差路径里 oscillator_bank 出现 **0 次** ⇒ 当前被布局掩盖。但它曾经是：rightboard-vibrato-fix-20261008/README.md:26 修前最差路径就是 `u_vibrato_lfo/phase_q_17_s0 → gen_lane[*].phase_q_*`，Data Delay 21.4 ns、slack −3.272、1630 端点违例；那次是在链的起点（`vibrato_mod_i`）插了两级流水把 21.4 ns 砍成两段，**链中间这 3~4 级加法器一级没减**。
- **改法**：🔴 关键警告：⛔ **不能**在这条路上加流水寄存器。`bv = base_phase_inc_i[vg*32 +: 32]`，而 `base_phase_inc_i` = `note_manager.voice_phase_inc_o` = `phase_tr[gp]` 数组元素直连（note_manager.v:1615）；`phase_tr[rot_cnt]` 由自由运行的 `rot_cnt`（note_manager.v:1560，无条件自增）每 32 拍刷新一次 ⇒ `bv` 在哪个拍变化与 `sample_tick_i` 无关（32 与 1024 同源但相位固定且不重合）⇒ 在 `inc_main_w`/`inc_det_w` 上加一拍寄存器会让 `sample_tick_i` 那一拍采样到上一个 32 拍窗口的增量 ⇒ 行为改变，tb_p5_osc_equiv（逐位比 64 个 phase_q）必红。安全杠杆只有：(a) 把 `dv` 与 `inc_det_w` 包进 `generate if (OSC_PER_VOICE > 1)`（当前无收益，因 OSC_PER_VOICE=2）；(b) **降低 `vib_off` 扇出**：拆成"每 voice 复制一份寄存器"（32 × 32 = **1024 FF**），把 1 根扇出 1024 的网变成 32 根扇出 32 的网（Gowin 自己会复制驱动，但复制点由工具决定、不可控）；(c) 把 `phase_q + lane_inc` 的加法器从 64 减到 32 需要把 `lane_inc` 预寄存到每 lane 一份（2048 FF），但预寄存会让 `sample_tick_i` 采到上一拍的值 ⇒ 只有在"预寄存使能严格等于 sample_tick_i 且 bv 相邻两拍不变"时才等价，而 bv 每 32 拍变一次 ⇒ **有 1/32 的拍不等价** ⇒ 🔴 不成立。⇒ 诚实结论：这条路径在当前架构下没有"零风险显著降深度"的改法，真正能动的只有 (b) 扇出复制（加 FF 换布线），以及把 P0-2/P0-3 修掉（把上游链腾出来，让布局器有余量照顾这里）。
- **预期**：(b) 收益 = 把 1 根 1024 负载的网拆成 32 根 32 负载的网，⚠️ 具体省多少 ns 必须实测；代价 = **+1024 FF**（利用率 29% → 31%），CLS 78% 上加布线压力。对 Fmax ⚠️ **可能双向**：Register 上升会占布线资源 ⇒ 当前 **+0.102 ns** 的余量有翻红风险 ⇒ 必须完整跑 PnR + 全量回归。
- **怎么验**：(1) 定向过约束探针（只读副本的 SDC，⛔ 不碰 constr/top.sdc）：`set_max_delay -from [get_pins {g_sound.u_oscillator_bank/vib_mul_r_*_s0/Q}] -to [get_pins {g_sound.u_oscillator_bank/gen_lane[*].phase_q_*_s0/D}] 8.000`，读 impl/pnr/Gowin2026_tr_content.html 该路径的 Data Delay 与 Logic Level：`Data Delay ≥ 12 ns` ⇒ 结构性瓶颈，(b) 值得做；`≤ 8 ns` ⇒ 布局掩盖，降级为 P2，只做记录。(2) (b) 的收益判据（必须成对跑，禁止只看一次 PnR）：基线 Fmax 55.313 MHz，同源重跑噪声 **2~3 MHz** ⇒ 单次对照无意义；做法 = 同一份 RTL 连跑 3 次 PnR 取 Fmax 的 min/median/max 得噪声带，加 (b) 后连跑 3 次取 min/median/max 对比，判据 **(b) 的 median 比基线的 median 高 ≥ 1.0 MHz 才算有效**；若两组区间重叠 ⇒ 判为"无结论"（⛔ 不许拿一次 55.9 当收益）。每次都要确认 0 setup / 0 hold：`sim\gowin_build.ps1` 后 `Select-String -Path sim\evidence\gowin_m0_timing.txt -Pattern 'Violated|Actual Fmax'`。
- **来源**：ANVIL-02【P1-9】
@@@END
@@@PRIO=P1|SRC=ANVIL-02|ORIG=P1-10|MOD=rtl/w3b/oscillator_bank.v,tb/models/oscillator_bank_ref.v
### 删掉"固定 rom_hard"的过时注释并钉住"交付音色 = rom_soft"的不变式
- **位置**：rtl/w3b/oscillator_bank.v:813-820（注释说固定 rom_hard）、:831-833（同文件 18 行后说固定 rom_soft）、:800-812＋:845-847（代码真值）、:86（参数名）；rtl/top.v:4190-4191；tb/models/oscillator_bank_ref.v:696-699
- **现状**：
```verilog
813:     //  ⭐⭐ 2026-09-29 修 bug②：⭐ **力度→音色 的耦合【默认关闭】**
814:     //   ⭐ `VEL_TIMBRE_BLEND = 0`（默认）⇒ ⭐ **固定 `rom_hard`**（⭐ 音色只由 `timbre` 决定）✅
817:     //  ⚠️⚠️ 2026-09-29 上板实测修正：⭐ **固定用 `rom_hard`，⛔ 不是 `rom_soft`**
820:     //        ⇒ 🔴 而 `rom_soft`（⭐ 旧表：⭐ 4 块相同、峰值 16384）**听不出音色切换** ＋ **音量砍半** ✅
831:     //  ⭐⭐ 2026-09-29 合并：⭐ **演奏通路固定走 `blend_sum`**（⭐ 队友版 ✅）
832:     //   ⭐ `FIXED_BLEND_Q = 0` ⇒ ⭐ `blend_sum = rom_soft` ⇒ ⭐ 用 **AKWF 的 soft 表**（⭐ 平滑档 ✅）
800:     wire [8:0] velocity_mix_q = (resp_velocity_q == 8'hFF) ? 9'd256 : {1'b0, resp_velocity_q};
802:     localparam [8:0] FIXED_BLEND_Q_W = FIXED_BLEND_Q;
803:     wire [8:0] mix_q = (VELOCITY_BLEND_EN != 0) ? velocity_mix_q : FIXED_BLEND_Q_W;
805:     wire signed [WT_W:0] blend_delta = {rom_hard[WT_W-1], rom_hard} - {rom_soft[WT_W-1], rom_soft};
807:     wire signed [WT_W+9:0] blend_product = blend_delta * $signed({1'b0, mix_q});
810:     wire signed [WT_W:0] blend_scaled = blend_product[WT_W+8:8];
811:     wire signed [WT_W:0] blend_sum = {rom_soft[WT_W-1], rom_soft} + blend_scaled;
845:     wire signed [WT_W-1:0] rom_dout = test_mode_i ? rom_test
846:                                                   : (resp_drum_q ? rom_noise : blend_sum[WT_W-1:0]);
--- top.v ---
4190:             .VELOCITY_BLEND_EN(0),
4191:             .FIXED_BLEND_Q (0),
```
- **为什么是问题**：`VELOCITY_BLEND_EN = 0` ⇒ `mix_q = FIXED_BLEND_Q_W = 9'd0` ⇒ `blend_product = blend_delta × 0 = 0` ⇒ `blend_scaled = 0` ⇒ `blend_sum = {rom_soft[15], rom_soft} + 0` ⇒ `rom_dout = blend_sum[15:0]` = **`rom_soft`**（非鼓、非 test 档）⇒ 交付音色 = `rom_soft`（AKWF 的 soft 表），`rom_hard` 在 :817-820 的说法与代码相反。另外 :814 提到的参数名 `VEL_TIMBRE_BLEND` 在整个文件里不存在（实际参数是 `VELOCITY_BLEND_EN`，:86）⇒ 同一段注释里参数名也是错的。⚠️ 风险等级不是"文档洁癖"：AGENTS.md §五③ 把"注释↔代码不一致"列为本项目复发缺陷，而且这里的不一致指向相反的音色决策 ⇒ 任何人"按注释修代码"就会把交付音色从 soft 翻成 hard ⇒ 直接改变听感 + 可能打红电平类判据。
- **改法**：删掉 :817-820 那四行（rom_hard 的"上板实测修正"），或明确标注为历史并写清"已被 :831-833 的合并版取代"；把 :814 的 `VEL_TIMBRE_BLEND` 改成 `VELOCITY_BLEND_EN`；在 :811 旁加一行不变式 `FIXED_BLEND_Q=0 ⇒ rom_dout == rom_soft（演奏通路）`；tb/models/oscillator_bank_ref.v:696-699 是同一段过时注释的副本 ⇒ 一起改（否则下次同步会把它再抄回来）。
- **预期**：消除"按注释改代码 ⇒ 翻音色"的地雷；消除参数名错误；代价 **0**（只改注释）；对 Fmax **0**。
- **怎么验**：这条不是"跑 tb 能红"，是"读代码能红"：`Select-String -Path rtl\w3b\oscillator_bank.v -Pattern '固定.*rom_hard|blend_sum = rom_soft'` —— 改前两处都命中 ⇒ 矛盾确认；改后只剩一处（或只剩带"历史"标注的一处）。行为侧反向验证（证明"代码真值是 soft"能被测出来）：把 `FIXED_BLEND_Q` 从 0 改成 256（⇒ hard）跑 `-Filter wavetable_timbres` 与 `-Filter soft_hard`；若这些 tb 不变红，说明交付音色没有判据保护 ⇒ 补一条"`rom_dout` 必须等于 `wavetable_bank.sample_soft_o`"的断言（比注释更硬的契约）。
- **来源**：ANVIL-02【P1-10】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-11|MOD=rtl/w3b/oscillator_bank.v
### 给 so_v 的左移定标补溢出自检
- **位置**：rtl/w3b/oscillator_bank.v:445-447（so_v）、:918-922（现有自检守的是另一个量）
- **现状**：
```verilog
445:             //   ⭐ **当前额外增量**（⭐ 左移定标 ⇒ ⭐ 纯连线、⛔ 无乘法器 ✅）
446:             wire [PHASE_W-1:0] so_v =
447:                 {{(PHASE_W-DRUM_SWEEP_W){1'b0}}, sweep_q} << DRUM_SWEEP_LSB_SH;
918:         if ((DRUM_PITCH_ENV_EN != 0)
919:             && (((DRUM_KICK_MAX - 1) >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH))
920:                 >= (1 << DRUM_SWEEP_W)))
```
- **为什么是问题**：:447 是一个 **32 位**表达式左移，`{16'b0, sweep_q}` 占 bit `15:0`，左移 `DRUM_SWEEP_LSB_SH` 后有效位落在 `[15+LSB_SH : LSB_SH]`；不丢位的条件是 `DRUM_SWEEP_LSB_SH + DRUM_SWEEP_W ≤ PHASE_W`，即 `LSB_SH ≤ 16`。对照：8（当前）⇒ 有效位 `[23:8]` ✅；16 ⇒ `[31:16]` ✅；**17** ⇒ `sweep_q[15]` 落到 bit 32 丢失，偏移上限从 `65535×131072` 掉到 `32767×131072`（**减半**）🔴 不报；**24** ⇒ 只保留 `sweep_q[7:0]`，偏移上限 **÷256** 🔴 不报。:918 的自检算的是 `(DRUM_KICK_MAX-1) >> (LSB_SH + KICK_SH)`（即 `sweep_kick` 的装载值），与 `so_v` 的移位溢出是两个不同的量 ⇒ 把 `DRUM_SWEEP_LSB_SH` 从 8 调到 17，:918 的判据会变得更宽松（右移量更大、装载值更小），于是自检更不会报，而 `so_v` 正在丢高位。
- **改法**：在 :922 之后补一条（与 P1-6 的 TOM 检查并列）：
```verilog
        if ((DRUM_PITCH_ENV_EN != 0)
            && ((DRUM_SWEEP_LSB_SH + DRUM_SWEEP_W) > PHASE_W))
            $display("ERROR [oscillator_bank] so_v 左移溢出：DRUM_SWEEP_LSB_SH=%0d + DRUM_SWEEP_W=%0d > PHASE_W=%0d ⇒ 扫频偏移高位移出被静默截断",
                     DRUM_SWEEP_LSB_SH, DRUM_SWEEP_W, PHASE_W);
```
- **预期**：把"改定标 ⇒ 静默丢高位"变成"启动即 ERROR"；代价 **0**（initial，不进网表）。
- **怎么验**：探针副本把 `DRUM_SWEEP_LSB_SH` 改 17，跑 `sim\tb_all.ps1 -Filter drum`：改前无任何 ERROR（tb_drum_pitch_env 若判据只查"扫频存在"而非"深度精确值"，照样全绿）；改后必须打印新 ERROR；反向：改回 8 ⇒ 必须不打印。
- **来源**：ANVIL-02【P2-11】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-12|MOD=rtl/w3b/oscillator_bank.v,rtl/w3b/test_mode_ctrl.v
### 先做实验判定奇数 lane 的 test-mode 覆盖 mux 是否白付 ≈1000 个 LUT4
- **位置**：rtl/w3b/oscillator_bank.v:566-571、:490-492；rtl/w3b/test_mode_ctrl.v:80-82；rtl/top.v:1358
- **现状**：
```verilog
566:             //   ⭐⭐ 把"本 lane 的相位增量"接上（⭐ 算术已在 `gen_voice` 算好 ✅）
567:             //     ⭐ `test_mode_i` 仍**直接覆盖** ⇒ ⭐ **test-mode 一个 bit 不变** ✅
569:             wire [PHASE_W-1:0] lane_inc = test_mode_i
570:                              ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
571:                              : lane_inc_base;
--- test_mode_ctrl.v ---
 80:                 assign test_lane_active_o[LANE] = selected && (o == 0);
 81:                 assign test_phase_inc_o[LANE*PHASE_W +: PHASE_W] =
 82:                     (selected && (o == 0)) ? VOICE_INC : {PHASE_W{1'b0}};
--- oscillator_bank.v ---
490:             wire lane_active = test_mode_i
491:                              ? test_lane_active_i[g]
492:                              : voice_active_i[VOICE_IDX];
```
- **为什么是问题**：对 `OSC_IDX == 1` 的 32 个 lane：①`test_phase_inc_i[g*32 +: 32]` 在生产接线（test_mode_ctrl.v:82）下是编译期常量 0（常量跨模块传播后）；②于是 :569 退化成 `lane_inc = test_mode_i ? 32'd0 : lane_inc_base` = `lane_inc_base & {32{~test_mode_i}}` ⇒ **32 个 2 输入 AND**；③而 `test_mode_i` 是运行期寄存器（top.v:1358 `assign tm_enable_r = tm_enable_q;`）⇒ 综合器不能折叠这 32 个 AND；④但 `test_mode_i=1` 时 `lane_active = test_lane_active_i[g] = 0`（:80）⇒ 相位冻结 ⇒ 这 32 个 AND 的输出从不被使用。⇒ **32 lane × 32 bit = 1 024 个 AND2 纯白付**（按 Gowin LUT4 一个 LUT 放一个 2 输入函数估 ≈1 024 个 LUT4，占 LUT 27135 的 **3.8%**）。⚠️ 诚实标注：这是结构性推断不是实测，两个不确定点：①Gowin 是否真的做了跨模块常量传播（若没做，`test_phase_inc_i` 被视为变量 ⇒ mux 是 32 个 2:1 mux，**更大**）；②Gowin 是否把 2 个独立 AND2 打包进 1 个 LUT4（打包则只有 ~512）。必须用实验判定。
- **改法**：实验（只读探针副本）把奇数 lane 的覆盖去掉：
```verilog
            // 探针：奇数 lane 的 test 覆盖在 test 档下是 don't-care（lane_active=0 ⇒ 相位冻结）
            wire [PHASE_W-1:0] lane_inc = (test_mode_i && (OSC_IDX == 0))
                             ? test_phase_inc_i[g*PHASE_W +: PHASE_W]
                             : lane_inc_base;
```
判据：综合报告 LUT 下降 **≥ 500** 且所有 tb 全绿 ⇒ 白付确认，落地（但必须同步改 tb/models/oscillator_bank_ref.v，否则 tb_p5_osc_equiv 假红 —— 它在 :211-213 给全部 64 个 lane 都写了非零 `test_phase_inc`，正是靠 :569 的覆盖）；LUT 下降 **< 100** ⇒ 工具已折叠 ⇒ 降级为 P3，如实记录。
- **预期**：收益（若成立）= `LUT −500 ~ −1000`（LUT 27135 → 约 26200），当前最差余量只有 **+0.102 ns**，降 LUT 是唯一对整设计单向有利的动作；代价 **0**（不改行为，只要 tb 的 test 激励同步改成生产形状 —— 与 P1-5 的改法一同一次改动）；对 Fmax 预期正向，但受 2~3 MHz 布局噪声限制，需按 P1-9 的 3 次重复法判定。
- **怎么验**：`sim\gowin_build.ps1` 后 `Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'LUT,ALU,ROM16'`，判据 = LUT 的差值（探针 vs 基线），**必须 ≥500 才落地**；功能侧 tb_p5_osc_equiv（改完参考副本后）必须 PASS，tb_oscillator_bank / tb_test_mode_top / tb_top_test_mode_pipe 必须全绿。
- **来源**：ANVIL-02【P2-12】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-13|MOD=rtl/w3b/test_mode_ctrl.v
### 把 test_mode_ctrl 的 6 位 clamp 改成按 POLY_TARGET 定宽
- **位置**：rtl/w3b/test_mode_ctrl.v:42-47、:72；rtl/top.v:1352；tb/w3b/tb_test_mode_ctrl.sv:22
- **现状**：
```verilog
 42:     wire [5:0] test_n0_c = (TEST_N0 > POLY_TARGET) ? POLY_TARGET : TEST_N0;
 43:     wire [5:0] test_n1_c = (TEST_N1 > POLY_TARGET) ? POLY_TARGET : TEST_N1;
 44:     wire [5:0] test_n2_c = (TEST_N2 > POLY_TARGET) ? POLY_TARGET : TEST_N2;
 45:     wire [5:0] test_n3_c = (TEST_N3 > POLY_TARGET) ? POLY_TARGET : TEST_N3;
 47:     reg [5:0] selected_n_r;
 72:             (* syn_keep = 1 *) wire selected = mode_enabled && (v < selected_n_r);
```
- **为什么是问题**：`POLY_TARGET` 是 `parameter integer`（32 位），`wire [5:0]` 只能表示 0..63。当前（`POLY_TARGET=32, TEST_N3=32`）：`32 > 32` 假 ⇒ 真值 32 ⇒ `6'd32` ✅ ⇒ active_n 32、正常；`POLY_TARGET=64, TEST_N3=64`：`64 > 64` 假 ⇒ 真值 **64** ⇒ 截断 `6'd0` 🔴 ⇒ active_n **0** ⇒ selected **全 0**；`POLY_TARGET=64, TEST_N3=100`：`100 > 64` 真 ⇒ `POLY_TARGET=64` ⇒ 截断 `6'd0` 🔴 ⇒ active_n **0** ⇒ 全 0。⇒ 只要 `POLY_TARGET ≥ 64`（本设计 POLY_TARGET=32，但它是参数，而 oscillator_bank 的 LANES 上限自检允许到 1024），Test Mode 会静默什么都不选，`active_n_o` 报 0，M4 判据（谱峰数 4/8/16/32）拿到的是静音。注释本身承认这个 clamp 的目的是"`active_n_o` 不能与 gate 的种群不一致"（:40-41）—— 而 6 位截断恰好把那个一致性又破坏了。
- **改法**：
```verilog
    localparam integer NW = $clog2(POLY_TARGET + 1);   // 32 -> 6 ; 64 -> 7
    wire [NW-1:0] test_n0_c = (TEST_N0 > POLY_TARGET) ? POLY_TARGET : TEST_N0;
    ...
    reg [NW-1:0] selected_n_r;
    // active_n_o 的端口宽度也要同步（当前是 [5:0]）
```
⚠️ 若暂时不想动接口宽度，最小替代：加一条自检（见 P2-14），在 `POLY_TARGET > 63` 时直接 `$display("ERROR ...")` ⇒ 至少不再静默。
- **预期**：参数化正确性，消除"改 POLY_TARGET ⇒ 测试模式静默失效"；代价 = `selected_n_r` 从 6 → 7 位（+1 FF，组合）、`active_n_o` 端口宽度 +1（**接口变更** ⇒ top.v:1352 与 tb_test_mode_ctrl.sv:22 的位宽要同步）；对 Fmax **0**。
- **怎么验**：新判据（tb_test_mode_ctrl.sv 的第二个实例）双实例差分：`dut32`：`POLY_TARGET=32, TEST_N0..N3 = 4/8/16/32` ⇒ 断言 active_n == 4/8/16/32；`dut64`：`POLY_TARGET=64, TEST_N0..N3 = 8/16/32/64` ⇒ 断言 active_n == 8/16/32/64。判据：dut64 在 `n_code=2'b11` 时必须 `active_n == 64` 且 `voice_gate` 的 popcount == 64；现在 dut64 会给出 `active_n == 0`、popcount == 0 ⇒ FAIL。
- **来源**：ANVIL-02【P2-13】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-14|MOD=rtl/w3b/test_mode_ctrl.v
### 给 test_mode_ctrl 补上全文缺失的参数自检
- **位置**：rtl/w3b/test_mode_ctrl.v:19-22（参数）、:86-88（文件末尾无 initial）；对照 oscillator_bank.v:902-926、vibrato_lfo.v:133-140、clk_gen.v:54-75
- **现状**：
```verilog
 19:     parameter integer TEST_N0       = 4,
 20:     parameter integer TEST_N1       = 8,
 21:     parameter integer TEST_N2       = 16,
 22:     parameter integer TEST_N3       = 32
 86:     endgenerate
 88: endmodule
```
- **为什么是问题**：`TEST_N0..N3` 直接决定 M4 验收判据（谱峰数必须 = 4/8/16/32）的目标值，没有任何检查 ⇒ 以下全是静默的：`TEST_N0=32, TEST_N3=4` ⇒ `active_n_o` 对 code 00 报 32、对 code 11 报 4 ⇒ 验收表整个反了，而 tb_test_mode_ctrl.sv:142-145 写死了 `check_mode(2'b00, 4)` ⇒ 它会红（这一条有保护），但只例化 top 的端到端 tb 没有这条断言 ⇒ 端到端静默；`TEST_N1=6`（非 2 的幂）⇒ 6 个非相干音 ⇒ 谱峰数 6 ⇒ M4 期望表（4/8/16/32）对不上；`TEST_N0=0` ⇒ Test Mode 打开却没有任何音 ⇒ 静默静音；`TEST_N2 > TEST_N3` ⇒ `active_n_o` 非单调，`'M'` 命令的"关→4→8→16→32→关"循环（top.v:1369-1374）语义错乱。
- **改法**：在 `endmodule` 前加：
```verilog
    initial begin
        if (!((TEST_N0 > 0) && (TEST_N0 <= TEST_N1) && (TEST_N1 <= TEST_N2) && (TEST_N2 <= TEST_N3)))
            $display("ERROR [test_mode_ctrl] TEST_N 必须满足 0 < N0 <= N1 <= N2 <= N3：%0d/%0d/%0d/%0d",
                     TEST_N0, TEST_N1, TEST_N2, TEST_N3);
        if ((TEST_N0 > POLY_TARGET) || (TEST_N3 > POLY_TARGET))
            $display("ERROR [test_mode_ctrl] TEST_N=%0d/%0d/%0d/%0d 超过 POLY_TARGET=%0d（会被 clamp，active_n_o 与设计意图不一致）",
                     TEST_N0, TEST_N1, TEST_N2, TEST_N3, POLY_TARGET);
        if (POLY_TARGET > 63)
            $display("ERROR [test_mode_ctrl] POLY_TARGET=%0d > 63：active_n_o 的 6 位宽会截断（见 K-106）",
                     POLY_TARGET);
        if (OSC_PER_VOICE < 1)
            $display("ERROR [test_mode_ctrl] OSC_PER_VOICE=%0d 非法", OSC_PER_VOICE);
    end
```
- **预期**：把 4 类静默误配变成启动 ERROR（K-106 口径）；代价 **0**（initial 不进网表）；对 Fmax **0**。
- **怎么验**：探针副本把 `TEST_N2` 改成 `8`（破坏单调），跑 `sim\tb_all.ps1 -Filter test_mode`：改前无任何 ERROR（tb_test_mode_ctrl 只检查它自己传的 4/8/16/32）；改后必须打印单调性 ERROR。
- **来源**：ANVIL-02【P2-14】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-15|MOD=rtl/w3b/vibrato_lfo.v
### 把 slew_count_q 从 integer 收窄到 $clog2 位宽
- **位置**：rtl/w3b/vibrato_lfo.v:50（声明）、:85、:108-109、:122；rtl/top.v:4150（CTRL_SLEW_DIV=10）
- **现状**：
```verilog
 50:     integer          slew_count_q;
 85:             slew_count_q   <= 0;
108:                 if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
109:                     slew_count_q <= 0;
122:                     slew_count_q <= slew_count_q + 1;
```
- **为什么是问题**：`integer` = **32 位有符号**，实际取值范围是 `0 .. CTRL_SLEW_DIV-1` = **0..9**（CTRL_SLEW_DIV=10，top.v:4150）。资源差：FF 当前 **32** 应为 **4**（`reg [3:0]`）⇒ **−28 FF**；加法器 32 位 ⇒ **16 ALU** 应为 4 位 ⇒ **2 ALU** ⇒ **−14 ALU**；比较器 32 位 `>= 9` 应为 4 位 ⇒ LUT 从 ~8 降到 ~1。另外 :122 的 `slew_count_q <= slew_count_q + 1` 在 `CTRL_SLEW_DIV = 1` 时（tb_vibrato_lfo.sv:17）永远走不到（:108 的 `>= 0` 恒真），但综合器仍会建那个 32 位加法器。⚠️ 诚实标注：这是资源/面积结论，不是时序结论；它不在最差路径上（:108 的比较器输出只驱动 `slew_count_q` 与一个 2:1 mux），但 32 位加法器 + 32 位比较器 ≈ 30 个 LUT + 28 个 FF，在当前 CLS 78%、最差余量 +0.102 ns 的环境下，任何 LUT/FF 都是净负担。
- **改法**：
```verilog
    localparam integer SLEW_W = $clog2(CTRL_SLEW_DIV + 1);   // 10 -> 4
    reg [SLEW_W-1:0]  slew_count_q;
    ...
    if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
        slew_count_q <= {SLEW_W{1'b0}};
    ...
    end else begin
        slew_count_q <= slew_count_q + 1'b1;
    end
```
⚠️ `CTRL_SLEW_DIV = 1` 时 `$clog2(2) = 1` ⇒ `reg [0:0]`，`>= 0` 恒真 ⇒ 行为不变 ✅。
- **预期**：`FF −28`、`ALU −14`、`LUT −25~30`；代价 **0**（逐位等价；`CTRL_SLEW_DIV ≤ 16` 时完全等价，`> 16` 时宽度自动跟上）；对 Fmax 不体现在单条路径上，但降 LUT/FF 对 **+0.102 ns** 的全局余量单向有利。
- **怎么验**：`sim\tb_all.ps1 -Filter vibrato`，tb_vibrato_lfo.sv:78-80（110/120/130）与 :84（phase 不被清零）必须保持 PASS。反向验证：把比较改成 `>`（而不是 `>=`）⇒ 78/79/80 必须红（证明这条判据真的锁住了 slew 步长）。
- **来源**：ANVIL-02【P2-15】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-16|MOD=rtl/w3b/voice.v,rtl/w3b/voice_i2s_chain.v
### 删掉 voice.v 里从未被使用的 CLK_PER_SAMPLE 死参数
- **位置**：rtl/w3b/voice.v:7（声明，全文仅此一处）；rtl/w3b/voice_i2s_chain.v:36、:51（传了）、:42（clk_gen 真的用它）
- **现状**：
```verilog
--- voice.v ---
  7:     parameter integer CLK_PER_SAMPLE = 1024,
--- voice_i2s_chain.v ---
 36:         .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
 51:         .CLK_PER_SAMPLE (CLK_PER_SAMPLE),
 42:         .tick_audio   (tick_audio_o),
```
- **为什么是问题**：`voice` 只通过 `tick_audio`（时钟使能）感知采样率 ⇒ 它不需要 `CLK_PER_SAMPLE`，但参数被留着并透传 ⇒ 造成"改了它就会生效"的错觉。具体后果：把 `voice_i2s_chain.CLK_PER_SAMPLE` 从 1024 改成 2048：clk_gen 的 `tick_audio` 周期从 1024 拍变 2048 拍 ⇒ 采样率 **48.83 kHz → 24.41 kHz**（音高掉一个八度、I2S 时序全错）；`voice` 内部什么都不变；**零报错、零警告**。
- **改法**：二选一（⛔ 不要留着不说）：删掉 voice.v:7 的 `CLK_PER_SAMPLE` 并从 voice_i2s_chain.v:36 的命名参数列表里去掉（voice_i2s_chain 自己的那个保留，因为 clk_gen 要用）；或加自检 `initial if (CLK_PER_SAMPLE < 2) $display("ERROR ...")` 并在注释里写明"本参数当前未被使用"（K-106 口径）。
- **预期**：消除"改参数不生效"的静默陷阱，符合 K-106；代价 **0**；对 Fmax **0**。
- **怎么验**：机械判据 `(Select-String -Path rtl\w3b\voice.v -Pattern 'CLK_PER_SAMPLE').Count`：当前 **1**（只有声明）⇒ 死参数确认；改后 **0**（删掉）。
- **来源**：ANVIL-02【P2-16】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-17|MOD=rtl/w3b/voice.v,rtl/w3c/i2s_tx.v
### 把 voice 的 SAMPLE_W 从名义 24 位改成真实 16 位（或在代码旁写明低 8 位恒 0）
- **位置**：rtl/w3b/voice.v:92、:101；rtl/w3c/i2s_tx.v:136-142；rtl/w3b/voice_i2s_chain.v:72-73
- **现状**：
```verilog
--- voice.v ---
 92:     wire signed [15:0] scaled_16 = scaled_wide[15:0];
101:                 sample_out <= {scaled_16, {(SAMPLE_W-16){1'b0}}};
--- i2s_tx.v ---
136:     function [DATA_BITS-1:0] top_bits;
142:                 if (k < SAMPLE_W) top_bits[DATA_BITS-1-k] = s[SAMPLE_W-1-k];
--- voice_i2s_chain.v ---
 72:         .SAMPLE_W  (24),
 73:         .DATA_BITS (16),
```
- **为什么是问题**：`sample_out[7:0]` 由 `{(SAMPLE_W-16){1'b0}}` 驱动 ⇒ **恒为 0**（8 个常量零）。`i2s_tx` 的 `top_bits` 取 `[SAMPLE_W-1 : SAMPLE_W-DATA_BITS]` = **`[23:8]`** ⇒ 正好是 `scaled_16` ✅ 所以功能正确。但：①模块对外宣称 `SAMPLE_W=24`、`sample_dbg_o[23:0]`，而有效精度是 16 位；②adsr 的 `ENV_W=16`、wavetable 的 `SAMPLE_W=16` ⇒ 整条链的真实精度是 16 位，24 位是空壳；③任何"读 `sample_dbg_o` 判断精度"的判据都会被误导（`sample_dbg_o[7:0]` 恒 0 是**可测的**）。
- **改法**：二选一：把 `SAMPLE_W` 改成 **16**，`i2s_tx` 的 `SAMPLE_W` 也改成 16（`top_bits` 取 `[15:0]`，行为逐位不变），`sample_dbg_o` 变 `[15:0]`；或保留 24 位但在 :101 旁加注释写明"低 8 位恒 0；有效精度 = 16 位（上游 adsr/波表都是 16 位）"。
- **预期**：口径诚实；若改成 16 位则 `sample_out` 的 8 个常量 FF 被省掉（**−8 FF/lane**）；代价 **0**（改 16 位是逐位等价：`top_bits` 从 `[23:8]` 变 `[15:0]`，取到的都是 `scaled_16`）；对 Fmax **0**（voice 不在生产网表，见 P2-20）。
- **怎么验**：新断言（加进 tb_dds_wavetable_core.sv 或新 tb）：S1 `voice.sample_out[7:0]` 恒为 0（连续 ≥256 拍，含满幅包络）；S2 若 `SAMPLE_W` 被改成 16，则 `sample_out[15:0]` 与旧 `sample_out[23:8]` 逐位相同。改前 S1 必绿（证明低 8 位是空壳）、S2 无法评估；改后 S2 必绿；反向：把 :101 改成 `{scaled_16, {(SAMPLE_W-16){1'b1}}}` ⇒ S1 必红（证明判据不是空判据）。
- **来源**：ANVIL-02【P2-17】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-18|MOD=rtl/w3b/voice.v
### 把 voice.v 的 NOTE_VELOCITY 从 integer 改成定宽 8 位，去掉位选
- **位置**：rtl/w3b/voice.v:10、:78；对照纪律 rtl/w3b/oscillator_bank.v:50
- **现状**：
```verilog
 10:     parameter integer NOTE_VELOCITY  = 255,
 78:         .velocity_i    (NOTE_VELOCITY[7:0]),
--- oscillator_bank.v 纪律 ---
 50: //   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
```
- **为什么是问题**：`NOTE_VELOCITY` 是 `integer`（32 位），`NOTE_VELOCITY[7:0]` 取低 8 位：255（当前）⇒ `8'hFF` ⇒ 255 ✅；**300** ⇒ `8'h2C` = **44** 🔴 不报；**256** ⇒ `8'h00` = **0**（静音！）🔴 不报；**511** ⇒ `8'hFF` = 255 🔴 不报。⇒ `NOTE_VELOCITY=256`（一个非常自然的"满量程"写法）会让 adsr 的 `peak_level = {velocity_i, 8'b0} = 0` ⇒ 包络峰值恒为 0 ⇒ 整条 T10 链静音，零报错。当前状态：Gowin2026.gprj:76 把 voice.v 列为 `enable="1"` ⇒ 它会被 Gowin 编译且编译通过（否则整个工程报错）⇒ 这一条不是"现在就坏"，是"下一个改这个参数的人会静默踩坑"，且与本文件自己引用的 K-91 纪律冲突。
- **改法**：
```verilog
    parameter [7:0] NOTE_VELOCITY  = 8'd255,     // ⭐ 直接声明成 8 位，⛔ 不做位选
```
并把 :78 改成 `.velocity_i(NOTE_VELOCITY)`。若必须保留 32 位语义，就加定宽常量 `localparam [7:0] NOTE_VELOCITY_W = NOTE_VELOCITY;`（与 oscillator_bank 的 `DRUM_KICK_MAX_C` 同款）。
- **预期**：消除"参数 >255 ⇒ 静默截断"，与 K-91 纪律一致；代价 **0**（`8'd255` 与 `255[7:0]` 在当前值下逐位相同）；对 Fmax **0**。
- **怎么验**：机械判据（比 tb 更硬）`Select-String -Path rtl\w3b\voice.v -Pattern 'parameter integer NOTE_VELOCITY|NOTE_VELOCITY\['`：当前两处都命中 ⇒ 违规确认；改后只剩一处（`parameter [7:0]`）。行为侧：把 `NOTE_VELOCITY` 传 256 跑 `sim\tb_all.ps1 -Filter dds`：改前 `velocity_i = 0` ⇒ `env_level_o` 峰值 0 ⇒ 若 tb 没有"输出非零"的断言，它会绿（这就是静默）⇒ 先确认这个 tb 有没有这条断言，没有就补一条 `env_level_o` 峰值 `> 0` 的断言。
- **来源**：ANVIL-02【P2-18】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-19|MOD=tb/models/oscillator_bank_ref.v,tb/w3b/tb_p5_osc_equiv.sv
### 给逐位等价参考副本补上 DRUM_CLS_EXT / drum_cls_i
- **位置**：tb/models/oscillator_bank_ref.v:54-192（参数列表）、:193-240（端口列表）、:404-406（鼓判据）；rtl/top.v:4214；tb/w3b/tb_p5_osc_equiv.sv:81-90；sim/evidence/a3-proper-20261008/README.md:25、:68
- **现状**：
```verilog
--- oscillator_bank_ref.v（只有 bv 比较那一路）---
404:             wire is_kick_drum = lane_drum[g] && (base_inc <  DRUM_KICK_MAX_C);
405:             wire is_tom_drum  = lane_drum[g] && (base_inc >= DRUM_KICK_MAX_C)
406:                                              && (base_inc <  DRUM_TOM_MAX_C);
--- top.v 生产例化 ---
4214:             .DRUM_CLS_EXT     (1)
```
- **为什么是问题**：参考副本的端口列表没有 `drum_cls_i`，参数列表没有 `DRUM_CLS_EXT`。tb_p5_osc_equiv.sv:81-90 例化 DUT 时不传 `DRUM_CLS_EXT` ⇒ 走默认 0 ⇒ 与参考副本口径一致 ⇒ 判据绿 ⇒ **"逐位等价"这句话的覆盖面是 `DRUM_CLS_EXT=0`，而生产用的是 `1`** ⇒ P5-② 那次"算术上提"的等价性证明对生产档不成立（虽然 `DRUM_CLS_EXT=1` 那一路的改动在 :400-405 是纯新增分支、风险低 —— 但没有判据）。另外 `DRUM_CLS_EXT=0` 与 `=1` 本来就不等价（前者按变调后的 `bv` 分类，后者按提交时刻的分类）—— a3-proper-20261008/README.md:25 明写"鼓种由按的哪个键决定，⛔ 不被变调带走" ⇒ 这不是 bug，是故意的语义差异，但必须有一条判据把它钉住，否则将来没人知道两档的差异边界在哪。
- **改法**：（A）给参考副本加同款参数与端口（同步纪律，与 rightboard-vibrato-fix-20261008/README.md:77-83 同一套路）：参数列表加 `parameter integer DRUM_CLS_EXT = 0`、端口列表加 `input wire [POLY_TARGET*2-1:0] drum_cls_i,`、`gen_voice` 内 `is_kick_drum`/`is_tom_drum` 改成与 RTL 逐字相同的三目。（B）tb_p5_osc_equiv.sv 加一对双实例差分（`DRUM_CLS_EXT=1` 的 DUT vs `=1` 的参考），激励用 tb_osc_drum_cls.sv 已有的模式（`base` 与 `cls` 故意不一致）。
- **预期**："逐位等价"这句话覆盖生产档；两档的语义差异边界被钉住；代价 = 参考副本 +~15 行、tb +1 个实例；对 Fmax **0**（只在 tb 里）。
- **怎么验**：反向验证（必须做）：①在 (B) 的差分 tb 里，把 RTL 的 `(DRUM_CLS_EXT != 0) ? drum_cls_i[...] : (bv < ...)` 的三目条件改成 `1'b1`（一律听外部）；②断言 `DRUM_CLS_EXT=0` 的实例必须红（因为它不该听外部）。⚠️ 这与 a3-proper-20261008/README.md:68 记录的既有反向验证同型（"去掉参数门控 ⇒ B1/B2/B3 FAIL"），说明这套反向验证套路在本项目已经跑通，直接复用即可。
- **来源**：ANVIL-02【P2-19】
@@@END
@@@PRIO=P2|SRC=ANVIL-02|ORIG=P2-20|MOD=rtl/w3b/voice.v,rtl/w3b/voice_i2s_chain.v,Gowin2026.gprj
### 明确 voice.v / voice_i2s_chain.v 不在生产网表这件事（三选一）
- **位置**：Gowin2026.gprj:76-77；rtl/top.v（从不例化）；bringup/synth_check_top.v:341；sim/gowin_build.ps1:38-69；rtl/w3b/tdm_render_mixer.v:378、:440
- **现状**：
```xml
        <File path="rtl/w3b/voice.v" type="file.verilog" enable="1"/>
        <File path="rtl/w3b/voice_i2s_chain.v" type="file.verilog" enable="1"/>
```
- **为什么是问题**：rtl/top.v 从不例化它们（全仓 grep：唯一例化点是 bringup/synth_check_top.v:341）；sim/gowin_build.ps1:38-69 的守卫只做单向检查（"top.v 例化的 ⇒ 必须在 gprj 里"），不检查反向。✅ 好处：它们不影响 Fmax（不在网表）⇒ 本报告里针对 voice.v / voice_i2s_chain.v 的所有时序类结论都不影响 51.5 MHz 门槛。🔴 风险：它们仍被 Gowin 编译 ⇒ 一个语法错误会打断整个工程（K-91 家族：`N'()`/`logic`/`always_ff` 会让"整个模块被丢弃而仿真全绿"，但那是在 top.v 的网表里；这里是"编译不过 ⇒ 工程报错"，反而更安全）；它们没有任何综合/时序证据，但 Gowin2026.gprj 把它们标成 `enable="1"` ⇒ 读者会以为它们在生产路径上；tdm_render_mixer.v:378 与 :440 的注释就在拿 voice_i2s_chain.v 的接线当论据用。
- **改法**：三选一，必须显式选一个：①从 Gowin2026.gprj 里删掉这两条（它们属于 bringup/synth_check.gprj:50-51，那里已经有一份）；②保留，但在两个文件的头注释里明写"⚠️ 本文件不在 rtl/top.v 的网表里；只被 bringup/synth_check_top.v 例化；其 PnR 证据见 bringup/"；③给 sim/gowin_build.ps1 加反向守卫：gprj 里 `enable="1"` 的文件若未被任何顶层例化，打 WARNING（不 FAIL，避免误伤）。
- **预期**：消除"这两个模块在生产路径上"的错觉；tdm_render_mixer.v 的两处论证不再悬空；代价 **0**（方案 2 只加注释；方案 3 加 ~10 行 PS）；对 Fmax **0**。
- **怎么验**：机械判据：`$gprj = Select-String -Path Gowin2026.gprj -Pattern 'rtl/w3b/(voice|voice_i2s_chain)\.v.*enable="1"'`；`$inst = Select-String -Path rtl\top.v -Pattern '\bvoice\b|\bvoice_i2s_chain\b'`：当前 `$gprj` 命中 **2** 条、`$inst` 命中 **0** 条 ⇒ 缺口确认；改后（方案 1）`$gprj` 命中 0 条。
- **来源**：ANVIL-02【P2-20】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-21|MOD=rtl/w3b/oscillator_bank.v
### 用定宽常量 LANES_C 替掉本文件自己对 integer 参数做的位选
- **位置**：rtl/w3b/oscillator_bank.v:50（纪律）、:259（声明）、:714/:729/:742/:876（使用）
- **现状**：
```verilog
 50: //   · ⛔ 不对 `integer` 参数做位选（`K-91` 顺带发现）
259:     localparam integer LANES = POLY_TARGET * OSC_PER_VOICE;
714:     reg [LW:0]  cnt;          // 0 .. LANES（需要 LW+1 位才装得下 LANES）
729:             if (cnt == LANES[LW:0])
742:     wire          req_active = rendering && (cnt < LANES[LW:0]);
876:         end else if (rendering && (cnt >= 1) && (cnt <= LANES[LW:0])) begin
```
- **为什么是问题**：`LANES` 是 `integer`（32 位有符号），`LANES[LW:0]` 是它的位选。当前无害：`LANES=64`、`LW=6`、`LANES[6:0] = 7'd64` ✅，`cnt` 也是 `[6:0]` ⇒ 比较正确；Gowin 与 Icarus 都接受（gprj 里的 oscillator_bank.v 编译通过、位流已出）。风险：①与同文件第 50 行的纪律直接冲突 ⇒ 下一个维护者不知道该守哪条；②`LANES` 若变成非 2 的幂（如 96），`LW=7`、`LANES[7:0] = 96` ✅ 仍然对 —— 所以这个写法恰好是安全的，真正脆弱的是 `LW` 本身（`$clog2`）。
- **改法**：统一口径（与 :275-276 的 `DRUM_KICK_MAX_C` 同一套路）：
```verilog
    localparam [LW:0] LANES_C = LANES;      // ⭐ 落定宽常量，⛔ 不对 integer 做位选
    if (cnt == LANES_C) ...
    wire req_active = rendering && (cnt < LANES_C);
```
并把 :50 的纪律注释补一句"本文件的 `LANES_C`/`DRUM_KICK_MAX_C`/`DRUM_TOM_MAX_C` 就是这条纪律的落地形式"。
- **预期**：纪律与代码一致；`LANES_C` 是编译期常量 ⇒ **0 硬件**；代价 **0**；对 Fmax **0**。
- **怎么验**：`Select-String -Path rtl\w3b\oscillator_bank.v -Pattern 'LANES\['`：当前命中 **4 处**（714/729/742/876 里的 `LANES[LW:0]`，其中 714 是注释）⇒ 违规确认；改后 **0 处**；功能侧 tb_p5_osc_equiv 必须仍 PASS（`LANES_C` 与 `LANES[LW:0]` 同值）。
- **来源**：ANVIL-02【P3-21】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-22|MOD=rtl/w3b/oscillator_bank.v,tb/models/oscillator_bank_ref.v
### 删掉未读的 FM 三端口债务说明与死变量 integer si
- **位置**：rtl/w3b/oscillator_bank.v:251-253（端口）、:871（integer si）、:893-894（注释）、:908-910；rtl/top.v:4250-4252；tb/models/oscillator_bank_ref.v:750
- **现状**：
```verilog
251:     input  wire                                             fm_cfg_valid_i,
252:     input  wire [15:0]                                      fm_ratio_i,
253:     input  wire [15:0]                                      fm_index_i,
871:     integer si;
893:     //  · `fm_cfg_valid_i` / `fm_ratio_i` / `fm_index_i`：`ENABLE_FM=0` ⇒ **忽略**
894:     //    （`A2c`：先留接口、后加，且**不计入吞吐量**）。
--- top.v ---
4250:             .fm_cfg_valid_i     (1'b0),
4251:             .fm_ratio_i         (16'd0),
4252:             .fm_index_i         (16'd0),
```
- **为什么是问题**：端口 = **33 位未读输入**，当前顶层接常量 0 ⇒ 综合器把端口折掉 ⇒ 0 硬件；但任何直接例化 oscillator_bank 的 tb 都必须接它们（否则 `default_nettype none` 下会报未连接，或接 z）⇒ 这是接口债务，A2c 已经记录。`integer si` 是未使用的仿真变量，`iverilog -Wall` 可能报警（sim/tb_all.ps1:119 用了 `-Wall`，但只对 tb 编译；rtl/ 也在编译命令行里 ⇒ 理论上会出警告）；它不产生硬件，但是"复制粘贴遗留"的证据。
- **改法**：`si` 直接删（oscillator_bank.v:871 与 oscillator_bank_ref.v:750 两处）；FM 三端口保留（A2c 是有意为之），但在 :893 的说明里补一句硬口径"`ENABLE_FM != 0` 时本模块不会做任何 FM ⇒ 该参数当前是空开关"（:908-910 已有 WARNING，把它升级为与 K-106 一致的措辞即可）。
- **预期**：清掉 1 个死变量 ×2 份；把"FM 参数是空开关"变成显式口径；代价 **0**；对 Fmax **0**。
- **怎么验**：`Select-String -Path rtl\w3b\oscillator_bank.v,tb\models\oscillator_bank_ref.v -Pattern 'integer si;'`：当前命中 **2 处** ⇒ 确认；改后 **0 处**。
- **来源**：ANVIL-02【P3-22】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-23|MOD=rtl/w3b/oscillator_bank.v
### 给 DBG_LANE 补范围自检（越界时调试输出出 x 而判据假绿）
- **位置**：rtl/w3b/oscillator_bank.v:94（参数）、:885（位选）、:289（lane_phase 宽度）、:902-926（自检里没有 DBG_LANE）；tb/w3b/tb_p5_osc_equiv.sv:143-146
- **现状**：
```verilog
 94:     parameter integer DBG_LANE      = 0,
885:     assign phase_acc_dbg_o  = lane_phase[DBG_LANE*PHASE_W +: PHASE_W];
289:     wire [LANES*PHASE_W-1:0] lane_phase;     // 供调试观测
```
- **为什么是问题**：`lane_phase` 是 `[LANES*PHASE_W-1:0]` = `[2047:0]`；`DBG_LANE = 64` ⇒ 索引 `[2048 +: 32]` ⇒ 完全越界。仿真：`phase_acc_dbg_o` = `32'hxxxxxxxx`（tb_p5_osc_equiv.sv:143-146 比 `ref_dbg !== dut_dbg` ⇒ 两侧同为 x 时会恰好相等，判据**不会红**）；综合：Gowin 对越界位选的行为未定义（可能报错、可能给常量 0）。⇒ 这是 K-106（⛔ 不许静默失效）的又一个缺口：参数越界没有任何提示。
- **改法**：
```verilog
        if ((DBG_LANE < 0) || (DBG_LANE >= LANES))
            $display("ERROR [oscillator_bank] DBG_LANE=%0d 越界（合法 0..%0d）", DBG_LANE, LANES-1);
```
- **预期**：把越界从"静默 x"变成"启动 ERROR"；代价 **0**（initial）；对 Fmax **0**。
- **怎么验**：探针副本把 `DBG_LANE` 传 64，跑 `sim\tb_all.ps1 -Filter p5_osc_equiv`：改前无 ERROR，且 `ref_dbg !== dut_dbg` 两侧同为 x ⇒ 判据绿（假绿）；改后必须打印 ERROR；反向：`DBG_LANE=63` ⇒ 必须不打印。
- **来源**：ANVIL-02【P3-23】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-24|MOD=rtl/w3b/test_mode_ctrl.v,rtl/w3b/oscillator_bank.v
### 给 selected_n_r 加 syn_keep 并把"死端口"写明
- **位置**：rtl/w3b/test_mode_ctrl.v:24-26（clk_i/rst_n_i/sample_tick_i）、:48-55、:57-62、:72；消费侧 rtl/w3b/oscillator_bank.v:569-571、:668
- **现状**：
```verilog
 24:     input  wire                                         clk_i,
 25:     input  wire                                         rst_n_i,
 26:     input  wire                                         sample_tick_i,
 57:     // Combinational configuration is intentional: disabling Test Mode mutes
 58:     // every test output immediately, and a mode switch settles within one
 59:     // sample period. clk_i/sample_tick_i remain on the frozen interface for
 60:     // integration symmetry with the rendering chain.
 61:     wire mode_enabled = rst_n_i & enable_i;
 62:     assign active_n_o = mode_enabled ? selected_n_r : 6'd0;
 72:             (* syn_keep = 1 *) wire selected = mode_enabled && (v < selected_n_r);
```
- **为什么是问题**：(a) 未使用端口：`clk_i`/`sample_tick_i` 各 1 位未读（全文没有任何 `always @(posedge clk_i)`，唯一的时序块是 :48-55 的 `always @(*)`）；`rst_n_i` 被 :61 用（组合）。这是 K-88 家族（静默忽略输入），但注释 :57-60 显式说明了理由 ⇒ 口径可接受，只需补一条自检或注释里的"当前不参与逻辑"字样。(b) 组合直通（跨模块穿透）：路径 = top.v 的 `tm_n_code_r`（寄存器）→ test_mode_ctrl 的 `always @(*)` case（6 位 4:1 mux）→ `v < selected_n_r`（6 位比较 × 32）→ `selected` → `test_phase_inc_o`（2048 位）→ **跨模块** → oscillator_bank 的 `lane_inc` mux → 相位累加器的加法器 ⇒ 这条链在同一个 50 MHz 拍内从 note_manager/top 的寄存器一直穿到相位累加器，中间没有任何寄存级。⚠️ `syn_keep` 只加在 `selected` 上（:72），没有加在 `selected_n_r`（6 位，扇出 32 个比较器 + `active_n_o`）⇒ 依赖工具自动复制。安全边界：相位只在 `sample_tick_i` 更新，而 `tm_n_code_r` 由 UART 命令驱动（远慢于采样）⇒ 功能上安全；风险是这条链是"看起来短、实际跨模块 + 大扇出"的典型，一旦 test_mode_ctrl 被放在远处就会变长。
- **改法**：(a) 在 :57-60 的注释里加一句"⚠️ `clk_i`/`sample_tick_i` 当前不参与任何逻辑（纯接口对称）"。(b) 低风险改法：在 top.v 里把 test_mode_ctrl 的三个输出各打一拍再送 oscillator_bank（3 × 1 位 + 2048 位 + 256 位 ⇒ **+2304 FF**，太贵）；更便宜：只给 `test_phase_inc_o` 打一拍（2048 FF）—— ⚠️ 打一拍后 `test_mode` 与 `test_phase_inc` 不同拍，会与 oscillator_bank.v:668 的 `!test_mode_i` 门控错位一拍 ⇒ 进/出 Test Mode 的那一拍行为变化 ⇒ 必须先跑 tb_top_test_mode_pipe / tb_test_mode_top。(c) 零成本改法（推荐）：只在 `selected_n_r` 上加 `(* syn_keep = 1 *)`（与 `selected` 同款），把"复制多少份"的控制权从工具手里拿回来。
- **预期**：(c) 收益 = `selected_n_r` 的复制点显式化，避免 33 个负载共用一个远端驱动；代价 **0**（一个属性）。(b) 收益 = 把跨模块链切成两段；代价 **+2048 FF** + 进出 Test Mode 的错位风险 ⇒ 当前**不建议做**。
- **怎么验**：`Select-String -Path rtl\w3b\test_mode_ctrl.v -Pattern 'clk_i|sample_tick_i'`：当前 `clk_i` 命中 **1** 次（声明）、`sample_tick_i` 命中 **1** 次（声明）+ :59 注释 ⇒ 死端口确认。(b) 的判据：tb_top_test_mode_pipe 必须保持 PASS；tb_test_mode_top / tb_test_mode_fft 必须全绿。
- **来源**：ANVIL-02【P3-24】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-25|MOD=rtl/w3b/voice_i2s_chain.v
### 处理 voice_i2s_chain 里悬空的 mclk_en / lrclk
- **位置**：rtl/w3b/voice_i2s_chain.v:29-32（声明）、:43-47（clk_gen 驱动）；rtl/clk_gen.v:34
- **现状**：
```verilog
 29:     wire mclk_en;
 30:     wire bclk_en;
 31:     wire bclk_half_en;
 32:     wire lrclk;
 43:         .mclk_en      (mclk_en),
 44:         .bclk_en      (bclk_en),
 45:         .bclk_half_en (bclk_half_en),
 46:         .lrclk        (lrclk),
 47:         .frame_start  (frame_start)
```
- **为什么是问题**：全文再没有任何引用 `mclk_en` 或 `lrclk`（`bclk_en`/`bclk_half_en`/`frame_start` 都送进了 i2s_tx）。`lrclk`：i2s_tx 自带 WS 生成（它用 `frame_start` + `bclk_half_en`，没有 `lrclk` 输入端口）⇒ `clk_gen.lrclk` 是冗余输出。`mclk_en`：**12.5 MHz MCLK 使能**被算出来却没人用 ⇒ 这个 chain 不输出 MCLK；对 PT8211 无害（它从 BCK 派生），但对需要 MCLK 的 DAC（如某些 PCM5102A 模块、AK4490 类）⇒ 必须外接 MCLK，而这条 chain 拿不到 ⇒ 这是一个功能缺口，不只是"死信号"。
- **改法**：二选一：①删掉 `mclk_en`/`lrclk` 两个 wire 声明，并把 clk_gen 的对应端口留空（`.mclk_en()` / `.lrclk()`）；②保留并在 :29-32 旁写"⚠️ 当前未使用：`mclk_en`（本 chain 不输出 MCLK，PT8211 不需要）/ `lrclk`（i2s_tx 自带 WS）"。若将来要驱动需要 MCLK 的 DAC：把 `mclk_en` 引到一个 `HP_MCLK` 输出脚（clk_gen.v:34 的注释已经定义了它是 12.5 MHz = 256 × fs ✅）。
- **预期**：消除"这条 chain 有 MCLK"的错觉；明确 DAC 兼容边界；代价 **0**；对 Fmax **0**（不在生产网表）。
- **怎么验**：`Select-String -Path rtl\w3b\voice_i2s_chain.v -Pattern 'mclk_en'` 与 `-Pattern 'lrclk'`：当前各命中 **2** 次（声明 + 连接）⇒ 悬空确认（有连接、无消费者）；改后各 **0** 次。
- **来源**：ANVIL-02【P3-25】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-26|MOD=rtl/w3b/vibrato_lfo.v
### 给颤音深度加与 rate 同款的 slew 限幅
- **位置**：rtl/w3b/vibrato_lfo.v:108-120（rate 有限幅）、:92-102（depth 没有）、:88
- **现状**：
```verilog
108:                 if (slew_count_q >= (CTRL_SLEW_DIV - 1)) begin
110:                     if (rate_inc_q < rate_target_w) begin
111:                         if ((rate_target_w - rate_inc_q) > RATE_SLEW_STEP)
112:                             rate_inc_q <= rate_inc_q + RATE_SLEW_STEP;
--- depth（没有限幅）---
 93:                     if (depth_raw_i <= DEPTH_OFF) begin
 95:                         depth_q        <= 16'd0;          // ⭐ 一步归 0
 97:                         depth_q <= depth_target_w;        // ⭐ 一步到目标
101:                     depth_q        <= depth_target_w;     // ⭐ 一步到目标
```
- **为什么是问题**：rate：每次 commit 最多动 `RATE_SLEW_STEP = 16`（`RATE_MIN_INC=86` → `RATE_MAX_INC=1031`，跨度 945）⇒ 最少 60 次 commit = 30 ms 才走完全程（`CTRL_SLEW_DIV=10` × 2 kHz commit ⇒ 每 5 ms 一步）。depth：`depth_raw` 从 96 到 4095 ⇒ `depth_q` 从 **768** 一步跳到 **32760**（**+42×**），或从 32760 一步归 0。⇒ 非对称设计。后果不是"咔声"（相位连续，:88 的 `phase_q <= phase_q + rate_inc_q` 不受 depth 影响），而是颤音深度的瞬变：若用户在推子中间抖动，`depth_q` 会随每个 commit（**0.5 ms**）跳变 ⇒ 颤音幅度以 2 kHz 更新、无平滑 ⇒ 听感上像"颤音在抖"（尤其在死区边界 96/64 附近来回穿越时，`depth_q` 会在 768 与 0 之间反复跳）。死区（64..95）能防住端点断续（:9-10 的注释就是这个目的），但防不住"深度抖动"。
- **改法**：镜像 rate 的 slew 结构给 depth 加一级限幅（复用同一个 `slew_count_q` 节拍）：
```verilog
    localparam [15:0] DEPTH_SLEW_STEP = 16'd256;   // 每 5 ms 最多动 256（满量程 32760 ⇒ 约 0.64 s 走完）
    ...
                    if (depth_active_r) begin
                        if (depth_raw_i <= DEPTH_OFF) begin
                            depth_active_r <= 1'b0;
                            depth_q        <= 16'd0;
                        end else if (depth_target_w > depth_q + DEPTH_SLEW_STEP) begin
                            depth_q <= depth_q + DEPTH_SLEW_STEP;
                        end else if (depth_q > depth_target_w + DEPTH_SLEW_STEP) begin
                            depth_q <= depth_q - DEPTH_SLEW_STEP;
                        end else begin
                            depth_q <= depth_target_w;
                        end
                    end
```
⚠️ 代价：tb_vibrato_lfo.sv:66-73 的 4 条断言用单次 commit 检查 depth 是否立即生效（:66 `depth_raw = 12'd120; commit;`、:67 查 `depth_active`）；:67 只查 `depth_active`（不受限幅影响）✅，但若有限幅，`depth_q` 会从 0 开始爬 ⇒ `mod` 的幅度会小很多 ⇒ :93-96 的三角波符号检查可能受影响（它们用 `fast_dut` 且 `depth_raw = 12'hFFF`，`commit` 只做 1 次 ⇒ 限幅下 `depth_q` 只爬到 256/32760 = 0.8% ⇒ **`fast_mod` 会变成 0** ⇒ :93 `fast_mod > 0` 直接 FAIL）⇒ **加限幅会打红 tb_vibrato_lfo 的 4 条三角波断言** ⇒ 必须同步改 tb（把 `commit` 换成"跑够时间让 depth 爬满"）。**契约变更，必须显式记录。**
- **预期**：收益 = 消除"推子抖动 ⇒ 颤音幅度抖"，depth 与 rate 口径一致；代价 = 16 位比较 + 16 位加/减（~32 LUT），🔴 打红 tb_vibrato_lfo.sv:93-96 四条，必须同步改 tb；对 Fmax **0**（不在最差路径上）。
- **怎么验**：新判据（加进 tb_vibrato_lfo）：D1 一次 commit 后 `depth_q` 的变化量 ≤ `DEPTH_SLEW_STEP`；D2 连续 200 次 commit 后 `depth_q` 到达 `depth_target_w`（证明它最终会到）；D3 depth 在死区边界（96↔64）反复穿越时，`depth_q` 的相邻差 ≤ `DEPTH_SLEW_STEP`。反向验证：把 `DEPTH_SLEW_STEP` 改成 `16'hFFFF`（等于没限幅）⇒ D1/D3 必须红。
- **来源**：ANVIL-02【P3-26】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-27|MOD=rtl/w3b/oscillator_bank.v,tb/models/oscillator_bank_ref.v
### 给 PHASE_QUARTER 的重复次数补 PHASE_W<2 自检
- **位置**：rtl/w3b/oscillator_bank.v:277-280；tb/models/oscillator_bank_ref.v:477；rtl/top.v:4166
- **现状**：
```verilog
277:     //  ⭐⭐ 2026-10-04（P5-②）：⭐ **1/4 周期初相** —— ⭐ 原来写在 lane 里，
278:     //     ⭐ 现在提成**共享常量**（⭐ 只有 `OSC_IDX==1` 那个 lane 用它 ✅）
280:     localparam [PHASE_W-1:0] PHASE_QUARTER = {{(PHASE_W-2){1'b0}}, 2'b01} << (PHASE_W - 2);
--- 参考副本 ---
477:                 ? ({{(PHASE_W-2){1'b0}}, 2'b01} << (PHASE_W - 2))   // ⭐ 1/4 周期
```
- **为什么是问题**：`PHASE_W = 32`（top.v:4166 显式传 32）⇒ `{{30{1'b0}}, 2'b01} = 32'h0000_0001`，左移 30 ⇒ **`32'h4000_0000`** ✅ 正确。脆弱点：`(PHASE_W-2)` 是重复次数，`PHASE_W = 1` ⇒ `{(-1){1'b0}}` ⇒ **非法**（IEEE 1364-2001 §4.1.1：重复次数必须是常数表达式且 ≥ 0，负值报错）；`PHASE_W = 2` ⇒ `{{0{1'b0}}, 2'b01} << 0` = `2'b01` ⇒ "1/4 周期"实际是 1/4 周期（2 位累加器的 1/4 = 0.5 ⇒ 取整 1）⇒ 巧合正确。更直白的等价写法：`localparam [PHASE_W-1:0] PHASE_QUARTER = {2'b01, {(PHASE_W-2){1'b0}}};`（把 `2'b01` 放在高位，不依赖移位）—— `PHASE_W ≥ 2` 时与现写法逐位相同，且读起来就是"1/4 周期 = 最高两位是 01"。
- **改法**：⚠️ 注意三目表达式两支都要能 elaborate，所以 `{(-1){1'b0}}` 仍可能报错 ⇒ 更稳的做法是显式断言：
```verilog
    initial if (PHASE_W < 2)
        $display("ERROR [oscillator_bank] PHASE_W=%0d < 2 ⇒ PHASE_QUARTER 的重复次数非法", PHASE_W);
```
并保留现写法（当前 `PHASE_W=32`，K-106 口径下"显式报错"比"改写"更小风险）。
- **预期**：参数越界时启动即报错，而不是 elaboration 崩；代价 **0**；对 Fmax **0**。
- **怎么验**：探针副本把 `PHASE_W` 传 1，跑 `sim\tb_all.ps1 -Filter p5_osc_equiv`：改前 elaboration 阶段报错（iverilog 的 `{(-1){...}}` 会给出 "Illegal number of repetitions"）或给出 x ⇒ 现象不定；改后必须先打印 `ERROR [oscillator_bank] PHASE_W=1 < 2`；反向：`PHASE_W=32` ⇒ 必须不打印，且 tb_p5_osc_equiv PASS。
- **来源**：ANVIL-02【P3-27】
@@@END
@@@PRIO=P3|SRC=ANVIL-02|ORIG=P3-28|MOD=rtl/w3b/oscillator_bank.v
### 把 sample_bus_r 的变址写入改成移位寄存器（或至少换成译码树）
- **位置**：rtl/w3b/oscillator_bank.v:870-879；tb/w3b/tb_p5_osc_equiv.sv:131-138
- **现状**：
```verilog
870:     reg [LANES*OSC_SAMPLE_W-1:0] sample_bus_r;
871:     integer si;
873:     always @(posedge clk_i) begin
874:         if (!rst_n_i) begin
875:             sample_bus_r <= {(LANES*OSC_SAMPLE_W){1'b0}};
876:         end else if (rendering && (cnt >= 1) && (cnt <= LANES[LW:0])) begin
877:             sample_bus_r[(cnt-1)*OSC_SAMPLE_W +: OSC_SAMPLE_W] <= rom_dout;
878:         end
879:     end
```
- **为什么是问题**：:877 是变量下标的部分选择写，综合出 **64 个 7 位比较器**（`cnt-1 == k`，k=0..63，每个约 2 个 LUT4 ⇒ ≈128 LUT4）、**64 × 16 = 1024 个 FF 每个带独立使能**（1024 个使能网）、`rom_dout`（16 位）**扇出 1024**（每 lane 一份）。等价改写：lane k 的样本在 `cnt == k+1` 那一拍写入槽 k，从 `cnt=1` 到 `cnt=64` 依次写入 `rom_dout` ⇒ 槽 0 最先写、槽 63 最后写 ⇒ 等价于一条"从高位移入"的移位寄存器：
```verilog
    always @(posedge clk_i) begin
        if (!rst_n_i)
            sample_bus_r <= {(LANES*OSC_SAMPLE_W){1'b0}};
        else if (rendering && (cnt >= 1) && (cnt <= LANES[LW:0]))
            sample_bus_r <= {rom_dout, sample_bus_r[LANES*OSC_SAMPLE_W-1:OSC_SAMPLE_W]};
    end
```
验算：第一次移入（cnt=1，rom_dout = lane 0）⇒ 槽 63（最高 16 位）得到 lane 0 ✅；第二次（cnt=2，lane 1）⇒ 槽 62 得到 lane 1，槽 63 保持 lane 0 ✅；…第 64 次（cnt=64，lane 63）⇒ 槽 0（最低 16 位）得到 lane 63 ✅ ⇒ 最终 `sample_bus_r[k*16 +: 16]` = lane k 的样本，与现写法逐位相同 ✅。对照：FF 1024 → **1024**（不变）；译码器 **64 × 7 位比较器 ≈ 128 LUT4** → **0**；写使能网 64 组 → **1 组**；`rom_dout` 扇出 1024 → **16**。⚠️ 代价（必须算清）：移位寄存器每拍都让全部 1024 个 FF 翻转（使能有效期间），而变址写入只翻转 16 个 —— 使能有效的拍数 = `LANES` = **64 拍/帧**（一帧 1024 拍 ⇒ **6.25%** 的时间）；翻转量 64 拍 × 1024 FF = **65 536 次/帧** vs 现写法 64 × 16 = **1 024 次/帧** ⇒ **动态功耗升约 64 倍**（但只占 6.25% 的时间，绝对量仍小）⚠️ 功耗是 `Gowin2026.power.html` 可查的量 ⇒ 必须实测对比再决定。
- **改法**：见上方代码。若功耗不可接受，退而求其次：保留变址写入，但把 64 个比较器换成 `cnt` 的二进制译码树（`cnt-1` 的 6→64 译码），代价从 64 个 7 位比较器（~128 LUT4）降到 1 个 6→64 译码器（~64 LUT4），收益减半但零功耗代价。
- **预期**：移位寄存器方案 = `LUT −128`、`rom_dout` 扇出 1024 → 16（对布线有利），代价 = 动态翻转 ×64（占 6.25% 时间）⇒ 必须查 power.html；译码树方案 = `LUT −64`，代价 0。
- **怎么验**：功能判据（必须逐位，不能只看波形）：在 tb_p5_osc_equiv 里 `osc_sample_bus_o` 已经被逐位比对（:131-138）⇒ 改完只要 tb_p5_osc_equiv PASS，就证明"lane k → 槽 k"的映射没变 ✅。反向验证：把移位方向写反（`{sample_bus_r[1022:0], rom_dout}`）⇒ tb_p5_osc_equiv 的 `osc_sample_bus mismatch` 必须红（且应报出全部 64 条 lane 的差异）。资源判据：`sim\gowin_build.ps1` 后 `Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'LUT,ALU,ROM16'`，判据 LUT 下降 **≥64**（译码树）或 **≥100**（移位寄存器）；功耗判据：impl/pnr/Gowin2026.power.html 的 dynamic power 对比（移位寄存器方案必须查）。
- **来源**：ANVIL-02【P3-28】
@@@END
@@@TOTAL SRC=ANVIL-02 COUNT=28 P0=4 P1=6 P2=10 P3=8
