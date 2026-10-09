@@@PRIO=P0|SRC=ANVIL-03|ORIG=P0-1|MOD=rtl/w3b/tdm_render_mixer.v
### 把 TDM 时隙的 64:1 选路换成旋转移位寄存器，摘掉交付档最差路径
- **位置**：rtl/w3b/tdm_render_mixer.v:137（夹取）→ :238（64 lane 选择）→ :246-249（加权/移位加减）→ :280（DSP 输入）
- **现状**：
```verilog
137:    wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];
238:            vs_sum = vs_sum + $signed(osc_sample_bus_i[(cnt_sel*OSC_PER_VOICE + oi)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
246:            vs_dif = $signed(osc_sample_bus_i[cnt_sel*2*OSC_SAMPLE_W +: OSC_SAMPLE_W])
247:                   - $signed(osc_sample_bus_i[(cnt_sel*2+1)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
248:            vs_w   = $signed({vs_sum, 3'b0}) + vs_dif;   // ⭐ 8·(L0+L1) + (L0−L1) = 9L0+7L1
249:            vs_c   = vs_w >>> LANE_WS;                   // ⭐ ÷16（权重和）
280:    wire signed [PROD_W-1:0]  prod_c = vs_s * env_s;
```
- **为什么是问题**：交付档（`RIGHT_ADC_ENABLE=1`）timing-rightadc-a3.html 的 Setup Paths Table：第 **1** 名 slack **0.642** `u_tdm_render_mixer/cnt_4_s0/Q → prod_c_0_s/D[15]`；第 **2** 名 **0.702** 同 from → `D[14]`；第 4 名 0.937 → `D[12]`；第 7/8/9/11/14/20/22/23 名 1.087…1.328 同 from → `D[13] A[17] D[11] D[8] A[16] D[10] D[17] A[5]` ⇒ **交付档 top-25 setup 里 11 条是 u_tdm_render_mixer**（14 条是 u_note_manager），第 1、第 2 名就是它；`Actual Fmax = 57.016 MHz`（约束 50）。=0 档（impl/pnr/Gowin2026_tr_content.html，01:13）里它是第 2 名，top-25 里占 **7/25**，slack 依次 0.133/0.604/0.770/0.815/0.823/0.850/0.851。逐节点到达时间（交付档 artifact 原文）：`R52C139[2][A] n48_s43/F 14.017 tINS 0.763` → `R59C135[3][A] n48_s36/I3 14.391 tNET 0.373` → `n48_s36/F 14.982 tINS 0.592` → `R57C130[1][B] n48_s33/I2 15.398 tNET 0.415` → `n48_s33/F 16.858 tINS 1.460 ← ⚠️ 单级 1.46 ns` → `R64C141[1][A] vs_dif_8_s/I0 17.358 tNET 0.501` → `vs_dif_8_s/COUT 17.358`（进位链 0.045 ns/bit）⇒ 减法器本身只花 45 ps/bit（进位链，便宜），但它从 17.358 ns 才开始 —— **20 ns 周期里 86.8% 已经烧在 `cnt` → 64:1 选择 → 加法树这一段上了**，之后还要进 DSP（`prod_c`）⇒ 这一拍里串了 4 件事：`cnt_sel` 夹取 → 64 lane（16 位×2）选择 → 18 位加减（加权）→ DSP 乘法输入。分类：结构性 ✅（不是布局运气）—— 同一 from→to 在交付档占 top-25 的 11 条（=0 档 7 条），不是单点坏运气；且它跨 `D[8..17]`/`A[5..17]` 复制 ⇒ 逻辑结构决定。但"数字本身"是布局运气：**同族切片之间的 slack 散布 = 1.328 − 0.642 = 0.686 ns**（=0 档 0.851 − 0.133 = **0.718 ns**）🔴 这个散布**大于第 1 名的全部余量 0.642 ns** ⇒ "今天过了"对下一次 PnR 没有任何信息量。
- **改法**（按性价比排序）：1. ⭐⭐ 把 64:1 选择换成"旋转移位寄存器"（envelope_bank 已经在用同一招 —— envelope_bank.v:151-153、337-339）：帧起点把 `osc_sample_bus_i` 装进 1024 位移位寄存器，每拍头切片就是当前 voice 的两条 lane，于是 `cnt → mux` 这条选路整段消失，一拍里只剩「加法 + DSP 输入」。📌 数字出处（⛔ 别混档）：选路 ≈ **6.1 ns**（=0 档 dump：`cnt_4_s0` 1.288 → `n101_s44` 7.407）、加权算术 ≈ **2.5 ns**（同 dump：`n101_s33` 14.754 → `vs_dif_17_s` 17.219）、DSP 输入 ≈ **2.6 ns**（同 dump：17.438 → `prod_c_0_s` 20.062）；交付档 dump 也给出同一形状（`n48_s43/F` 14.017 → `vs_dif_8_s/I0` 17.358 = 3.34 ns）。代价 **+1024 FF**，`cnt` 不再参与选路（改为移位计数）；⛔ 不动 `env_level_i` 的选择也可以（512 位同理可选做，或保留）。2. 次选：拆两级流水（选择 1 拍 → 算术 1 拍 → 乘法）：`valid_d` 深度 5 → 7（:857-863），`acc_r` 要跟着"同一 voice"的乘积 ⇒ 需要 1 个 look-ahead 指针（照抄 envelope_bank.v:165-166 的 `svc_i/pre_i`）；代价 +2 拍延迟（一帧 1024 拍，占 0.2%，听感不可闻），tb 的 `POLY+3..POLY+8` 断言窗口要跟着改（:854-855 已经留过口子）。3. ⛔ 不要只把 `cnt_sel` 打一拍（那只挪掉 1.288 ns，见到达时间表第一跳）—— 不够，别浪费一轮 PnR。
- **预期**：削掉 86.8% 里最大的那一块（选路 ≈6.1 ns），预期把这条路径从"最差"挪出 top-25；代价 +1024 FF（CLS 78% 上加布线压力）。
- **怎么验**：①改之前先记基线（交付档 sim/evidence/rightboard-vibrato-fix-20261008/timing-rightadc-a3.html，grep `u_tdm_render_mixer/cnt_4_s0` 与 `prod_c_0_s`）；②改完重跑 PnR（~10 min）`sim\gowin_build.ps1`；③判据（机械）：新的 top-25 setup 表里**不应再出现** From=cnt_4_s0 → To=prod_c_0_s，且最差 slack 必须大于 0.642 ns（否则说明改动没生效或换了个点爆）；④功能不许动：`-Filter tb_tdm_render_mixer`、`-Filter tb_e2e_key_to_sound`。⚠️ 这是时序判据 ⇒ 唯一判据是 PnR 产物，仿真永远测不出来。
- **来源**：ANVIL-03【P0-1】
@@@END
@@@PRIO=P0|SRC=ANVIL-03|ORIG=P0-2|MOD=rtl/w3b/tdm_render_mixer.v,rtl/top.v
### 把单音电平口径统一到代码真值 64（或按用户决定抬 +6.02 dB）
- **位置**：rtl/w3b/tdm_render_mixer.v:594-633（LUT）、:684-685（移位）、:66/:71、:425、:534、:581-585；rtl/top.v:4397-4413
- **现状**：
```verilog
 66:    parameter integer NORM_GAIN_STEP      = 1,
 71:    parameter integer OUTPUT_HEADROOM_SH  = 0      // ⚠️ 模块默认 0
598:                 6'd0:  gain_sqrt_lut = 16'd64;
599:                 6'd1:  gain_sqrt_lut = 16'd64;    // 64/√1  = 64.0   ← ⭐ 交付 N=1 走这条
600:                 6'd2:  gain_sqrt_lut = 16'd45;    // 64/√2  = 45.3
684:            sh_norm_r <= (sh24 * $signed({1'b0, norm_gain_r})) >>> (7 + OUTPUT_HEADROOM_SH);
--- top.v ---
            .OUTPUT_HEADROOM_SH  (1)          // ⭐ 交付档 = 1 ⇒ 实际 >>>8
```
- **为什么是问题**：同一文件里有四套互斥口径（全部原文）：:425 `gain(N) = 128 / √N`（隐含 128 = 1.0）；:534 `基准 44 = 满增益`（44 = 1.0）；:581-585 表格 `44 → 34%`、**`88 → 69%`** ✅（88 = 1.0）；:598-601 `6'd1: 16'd64` / `6'd2: 16'd45` / `6'd3: 16'd37`（64 = 1.0 ← ⭐ 代码实况）。机制（数字全部可复算）：单 voice 满幅两 lane 同相 `L0=L1=32767` ⇒ `vs_c = (9+7)/16 × 32767 = 32767` ⇒ `prod = 32767 × 65535 = 2 147 385 345` ⇒ `sh = acc >>> 16 = ⌊2 147 385 345/65536⌋ = 32766`（📌 刻意保留 ⌊⌋：`>>>` 对正数是向下取整，`2 147 385 345/65 536 = 32 766.9999…` ⇒ 32766 而不是 32767）⇒ `sh24 = 32766 << 8 = 8 388 096` = **99.994% ≈ 2²³ = 100.0% FS**（:395 的 `SCALE_UP = SAMPLE_W-16 = 8`）⇒ 交付档 `×64 >>> 8` = **2 097 024 = 25.0% FS = −12.04 dBFS**；若 `OUTPUT_HEADROOM_SH=0` 才是 50%（−6.02 dB）；文档说的 69% = −3.2 dB ⇒ **差 8.8 dB**。⭐ 实测（交付档路径参数，sim/evidence/tb_velocity_headroom.log）：`INFO: timbre=0 velocity=200 samples=700 osc=32767 env=51200 max_abs=1147904 (136/1000 FS) knee=0 rail=0` ⇒ 正常演奏力度（vel=200，env=51200=78.1% FS）下 **13.6% FS = −17.3 dBFS**；该力度下的理论上限 = `(25599<<8)×64>>>8 = 1 638 336` = 19.5% FS（实测低是因为取到的那一帧加权和不在波峰）。⭐ gain 到底是 64 还是 45 —— 用 timbre=1 的实测钉死：`INFO: timbre=1 velocity=200 … env=51200 max_abs=1540672 (183/1000 FS)`，若 `gain=45` ⇒ 需要 `sh24 = 1540672×256/45 = 8 764 712 > 6 553 344 = (32767×51200>>>16)<<8` = 物理上不可能（`vs_c ≤ 32767`）⇒ ⭐ **`gain=64` 是唯一解**（8.8e6 > 6.55e6 而 64 给 6.16e6 ≤ 6.55e6 ✅）⇒ ⭐ LUT 是地面真相，:581-585 那张"88 ⇒ 69%"的表是作废的意图记录。
- **改法**（⛔ 二选一，不许两个一起默默改）：(a) 承认 64 + −6 dB 裕量：把 :425、:534、:566-591、:581-585 四段散文全部改写成 64 口径，并把 tb_tdm_render_mixer.sv:361-364 的 `128/91/74` 注释一起改（它的断言标签已经写的是 `gain=64`，:300/:356）—— 代价 0（只改注释），收益 = 消灭"下次又有人按 88 去调"的循环（这个循环已经发生 5 轮，见 :542-550）。(b) 真的把单音抬上去（若用户仍觉得小）：top.v:4413 的 `OUTPUT_HEADROOM_SH` 1 → 0（**+6.02 dB**，一行），或把 LUT 换成 88 基准（**+2.76 dB**）—— 代价：软膝阈值 `LIM_TH_W = 7/8 FS`（:746）会更频繁介入（单音从 25% → 50% FS，双音/和弦更容易进膝）⇒ 必须重跑 tb_velocity_headroom（它会在 `vel ≤ 200` 进限幅时 FAIL：:133-136）并重听；⚠️ 这一条是用户决策（响度 vs 动态余量），⛔ 不是我能替他定的。
- **预期**：(a) 代价 0、收益 = 消灭文档循环；(b) 收益 = +6.02 dB 或 +2.76 dB，代价 = 更早进软膝、必须重跑验收 tb。
- **怎么验**：`sim\tb_all.ps1 -Filter tb_velocity_headroom`（打印实测 %FS）、`-Filter tb_tdm_render_mixer`（算术/电平判据）；判据：改 (b) 之后 tb_velocity_headroom 的 INFO 行 %FS 必须变大，且 `knee=0 rail=0` 对 vel≤200 仍然成立（否则就是"修了音量、破了验收"）。
- **来源**：ANVIL-03【P0-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-03|ORIG=P1-1|MOD=tb/w3b/tb_tdm_render_mixer.sv
### 给验收 tb 加一个交付参数实例并让去拉链斜坡有守护
- **位置**：tb/w3b/tb_tdm_render_mixer.sv:57-61 vs rtl/top.v:4397-4413；斜坡代码 rtl/w3b/tdm_render_mixer.v:641-658、:520-525、:650-657；tb 绝对判据 :300、:356、:419-420
- **现状**：
```verilog
--- tb_tdm_render_mixer.sv:57-61   ⚠️ 没传 OUTPUT_HEADROOM_SH ⇒ 用 RTL 默认 0 ---
    tdm_render_mixer #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .OSC_SAMPLE_W(OSW),
        .ENV_W(ENVW), .SAMPLE_W(SW), .CLK_PER_SAMPLE(1024),
        .RENDER_DEADLINE_CYC(927), .NORM_GAIN_STEP(0)      // ⚠️ 0 = 立即模式
    ) dut (
--- rtl/top.v:4409-4413        ⭐ 交付档 ---
            .RESERVED_N          (5),
            .OUTPUT_HEADROOM_SH  (1)
        ) u_tdm_render_mixer (      // ⚠️ 没传 NORM_GAIN_STEP ⇒ 用 RTL 默认 1（去拉链）
```
- **为什么是问题**：两条都要说清。①**6.02 dB 差**：tb 的 `>>>7`，交付是 `>>>8` ⇒ tb 里这些绝对电平判据全部不适用于交付档：:300 `chk("full env => 183808 (weighted lane sum, gain=64)", latched === 24'sd183808);`、:356 `chk("negative magnitude 184064 …", s1 >= -184240 && s1 <= -183888);`、:419-420 `chk("max input clamps to soft-knee ceiling 0x780000 (not wrap)", sSat === 24'sd7864320);` —— 🔴 交付档同样的激励只会给 **3 932 160**，根本没到 `T = 0x700000` ⇒ "限幅器会介入并封顶"这个结论在交付档是假的（交付档那一档输入压根不碰限幅器）。②**去拉链零覆盖**：tdm_render_mixer.v:641-658 的斜坡（:520-525 自述是 2026-09-29 为消"偶发尖音/控制量阶跃"加的）只有 `NORM_GAIN_STEP ≠ 0` 才会走到；机械核查（全仓库 tb 里 NORM_GAIN_STEP 只出现 4 次，全部 = 0）：tb_tdm_render_mixer.sv:60 `.NORM_GAIN_STEP(0)`、:77 `.NORM_GAIN_STEP(0)`、:155 `.NORM_GAIN_STEP(0)`、tb_velocity_headroom.sv:67 `.RESERVED_N(0), .NORM_GAIN_STEP(0)` ⇒ 交付默认的 1 **一次都没被实例化过** ⇒ 交付默认的那条斜坡没有任何一条 tb 走过 ⇒ 改坏它（步长、方向判断、饱和）回归不会红。
- **改法**：1. 给 tb_tdm_render_mixer.sv 加第 4 个实例（照抄 `dut_wide` 的写法），参数 = 交付档：`OUTPUT_HEADROOM_SH(1)` + `NORM_GAIN_STEP(1)` + `RESERVED_N(5)`。2. 该实例的判据一律写成相对量（⛔ 不写死绝对数）：反相/同相比 ≈ 1/8（:339-340 的写法已经是这个路子 ✅）、单调、不回绕、天花板 = `T + W/2` 按该实例自己的移位口径算。3. 斜坡要有 settle 等待：64→45 需要 `(64-45)/1 = 19` 帧（:650-657），一帧 1 个 `render_start` ⇒ 至少等 19 帧再判。
- **预期**：验收 tb 第一次真正跑在交付参数上；去拉链从"零覆盖"变成"有守护"；代价 = tb +1 实例 + ~20 行，⛔ 不动 RTL。
- **怎么验**（先证明它非空洞 —— 按 C83 探针假绿的教训）：①先把 `NORM_GAIN_STEP(1)` 写进现有 tb 的实例（即"未修复代码"）⇒ 现有那批绝对电平判据应当立刻 FAIL（它们编的是 shift=7 的账）⇒ 证明覆盖缺口是真的；②再把 rtl 的斜坡步长改成 0（变异）⇒ 新实例的判据必须 FAIL，旧实例必须仍然 PASS（否则说明新判据没打到斜坡）。
- **来源**：ANVIL-03【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-03|ORIG=P1-2|MOD=tb/models/oscillator_bank_ref.v,tb/w3b/tb_p5_osc_equiv.sv
### 给 P5-② 逐位等价基线补 DRUM_CLS_EXT/drum_cls_i 并加判别性激励
- **位置**：rtl/w3b/oscillator_bank.v:204、:246、:400-404；tb/models/oscillator_bank_ref.v（都没有）；rtl/top.v:4214；rtl/w3b/note_manager.v:832-836、:1363、:1667；tb/w3b/tb_p5_osc_equiv.sv:81-91；sim/evidence/rightboard-vibrato-fix-20261008/README.md:253-256
- **现状**：
```verilog
--- rtl/w3b/oscillator_bank.v ---
204:    parameter integer DRUM_CLS_EXT      = 0
246:    input  wire [POLY_TARGET*2-1:0]                         drum_cls_i,
400:            wire is_kick = drum_v && ((DRUM_CLS_EXT != 0)
401:                ? drum_cls_i[vg*2 + 1]
403:            wire is_tom  = drum_v && ((DRUM_CLS_EXT != 0)
404:                ? drum_cls_i[vg*2 + 0]
--- rtl/top.v ---
4214:            .DRUM_CLS_EXT     (1)
--- rtl/w3b/note_manager.v（分类在提交那一拍算）---
832:    wire [PHASE_W-1:0] cmt_inc_oct = (base_oct_r == 2'd0) ? cmt_inc_r
835:    wire cmt_kick = (cmt_inc_oct <  DRUM_KICK_MAX_C);
1363:                        drum_cls_r[cmt_idx_r*2 +: 2] <= {cmt_kick, cmt_tom};
1667:    assign voice_drum_cls_o = drum_cls_r;
```
- **为什么是问题**：机械对比（跑过）：RTL 端口表比 ref 多【且只多】一行 `input wire [POLY_TARGET*2-1:0] drum_cls_i,`，RTL 参数表比 ref 多【且只多】一行 `parameter integer DRUM_CLS_EXT = 0`。证据覆盖范围（关键）：tb_p5_osc_equiv.sv:81-91 的 DUT 也没传 `DRUM_CLS_EXT` ⇒ 默认 0 ⇒ ⭐ 它的 **320 帧 0 mismatch**（引用于 files/00-总览/交接-逻辑优化-20261003.md:47）**只证明了 `DRUM_CLS_EXT=0` 那一档**，而交付档是 1。两档在"鼓音高扫频装载值"上可以不同（`is_kick/is_tom` 的来源不同：`bv` 实时比较 vs 提交时锁存），触发差异的现实路径是抢占/重触发/起音后再变调（`sweep_load` 在 `rst_v` 或 `act_v` 上升沿重装，:458）⇒ ⚠️ ref 连这个端口都没有 ⇒ 想验也编译不过 —— 所以这不是"我怀疑它错"，而是**覆盖不到**。附带的文档漂移（同一条证据链）：rightboard-vibrato-fix-20261008/README.md:253-256 描述的方案是「给 oscillator_bank 加输入 `phase_raw_i` + Z-safe 回退 + top.v 接 `voice_phase_raw_o`」，但 `phase_raw` 在全仓库 RTL 里 **0 命中**（grep 过 rtl/**/*.v）—— 落地的其实是 `drum_cls_i` 方案（note_manager 提交时锁存，:822-836）⇒ README 的计划段落没有标记为"已被取代" ⇒ 下一个人会去找一个不存在的端口。
- **改法**：1. tb/models/oscillator_bank_ref.v 补 `DRUM_CLS_EXT` 参数 + `drum_cls_i` 端口（它就是 RTL generate 块的副本，两处几行）。2. tb_p5_osc_equiv.sv 再加一对（ref/DUT 各一）实例，`.DRUM_CLS_EXT(1)`，`drum_cls` 同时驱动两边。3. ⭐ 判别性激励（关键，⛔ 不能只跑"分类与 base_inc 一致"的激励）：让 `drum_cls_i` 说"底鼓"而 `base_inc` 落在"嗵鼓"档（或反之），再打一次 `voice_phase_rst` ⇒ 两档的 `sweep_load` 必须不同 ⇒ 这才验到交付档独有的那条路。4. README 的 `phase_raw_i` 段落加一行「⛔ 已被 `drum_cls_i` 方案取代（2026-10-08）」。
- **预期**：交付档的鼓扫频第一次有逐位守护；顺手把一条会误导人的过期方案标注掉；代价 = ref +2 行、tb +~20 行，⛔ 不动 RTL。
- **怎么验**：`sim\tb_all.ps1 -Filter tb_p5_osc_equiv`：①未修复代码：新实例编译不过（ref 无 drum_cls_i 端口）⇒ 这就是缺口的存在性证明；②修好后：把 rtl 的 `? drum_cls_i[vg*2+1] :` 改成 `? bv < DRUM_KICK_MAX_C :`（变异）⇒ 新实例必须 FAIL，旧实例（=0 档）必须仍然 PASS。
- **来源**：ANVIL-03【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-03|ORIG=P1-3|MOD=rtl/w3b/envelope_bank.v
### 让 envelope_bank 对多拍 tick 免疫（否则 32 路包络永久冻结且无声全绿）
- **位置**：rtl/w3b/envelope_bank.v:332-346（服务分支）、:28-30（自述契约）、:59（CNT_STOP）；rtl/clk_gen.v:104；tb/w3b/tb_envelope_bank.sv:45-54
- **现状**：
```verilog
332:        end else if (sample_tick_i) begin
333:            cnt     <= {(AW+1){1'b0}};
334:            running <= 1'b1;
335:        end else if (running) begin
336:            if (cnt != {(AW+1){1'b0}}) begin
343:            if (cnt == CNT_STOP)
344:                running <= 1'b0;
--- 文件头 :28-30 自述 ---
"A testbench must also leave at least 34 clocks between two sample_tick_i pulses"
--- rtl/clk_gen.v:104   ⭐ 单拍脉冲 ✅ ---
104:            tick_audio   <= (cnt == {CW{1'b0}});
```
- **为什么是问题**：`sample_tick_i` 只要是**电平**（连续 2 拍以上为高），每个高拍都会把 `cnt` 清 0 ⇒ `cnt` 永远到不了 `CNT_STOP = POLY_TARGET = 32`（:59）⇒ 服务分支 `else if (running)`（:335）永远轮不到 ⇒ ⭐ **32 路 `env_level_o` 停在复位值 0**，tdm_render_mixer 输出恒 0 ⇒ **无声**，而且**没有任何 tb 会红**（旧设计 32 个并行 adsr 是"每个高拍走一步"，多拍 tick 只是包络变快，不会冻结 ⇒ ⚠️ 这是本次重构**新引入**的失效模式）。现状核对（硬件上是安全的）：clk_gen.v:104 的 `tick_audio <= (cnt == {CW{1'b0}});` 是单拍脉冲 ✅，硬件 `CLK_PER_SAMPLE = 1024`、`tick_audio` 1 拍宽 ⇒ 当前不失败；tb_envelope_bank.sv:45-54 的 `tick()` 也是 1 拍 + 等 8 拍 ✅。⚠️ 但契约没有机械守护：谁把 `tick_audio` 过一级寄存器/换成门控使能（或把 envelope_bank 复用到别的节拍上），就会静默冻结。
- **改法**（推荐 (a)）：(a) 让它对多拍 tick 免疫（1 行）：`end else if (sample_tick_i && !running) begin` ⇒ 轮转进行中忽略新的 tick（语义：一个音频帧只服务一轮，与 32 个并行实例的语义一致）；⚠️ 代价：若 tick 来得太快（<34 clk），该帧的包络不推进（旧设计是推进 1 步）—— 但那种配置本来就已经违反 `CLK_PER_SAMPLE=1024` 的契约，冻结比"推进 2 步"更接近设计意图。(b) 只加守护：`initial` 里加 `PARAM_OK` 风格检查（本项目已有 4 处同样套路：clk_gen/i2s_tx/master_mix/tdm_render_mixer）+ 在 tb_envelope_bank.sv 里加一条"tick 拉高 2 拍"的用例。
- **预期**：消掉一个"无声且全绿"的失效模式（本项目最贵的那一类）；代价：(a) 1 行 RTL + 必须重跑 tb_p5_adsr_diff / tb_envelope_bank / tb_velocity_headroom（⛔ 因为它改了共享引擎）；(b) 0 行 RTL、只加测试。
- **怎么验**：`sim\tb_all.ps1 -Filter tb_envelope_bank`；用例：`sample_tick` 连续 2 拍为高，然后等 40 拍，断言 `env0 === 16_384`（期望推进 1 步）—— 未修复代码实测 0（冻结）⇒ 红 ✅；修复后 ⇒ 16_384 ✅。
- **来源**：ANVIL-03【P1-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-03|ORIG=P2-1|MOD=rtl/w3b/adsr.v
### 给 adsr.v 那段 PnR 引用加历史标注（它引用的是已不在网表里的模块）
- **位置**：rtl/w3b/adsr.v:110-136；rtl/w3b/voice.v:66；rtl/w3b/voice_i2s_chain.v:50；rtl/top.v:1440；rtl/w3b/envelope_bank.v:1-30；impl/gwsynthesis/Gowin2026_syn_resource.html
- **现状**：
```
adsr.v:110-136 大段 PnR 引用："最差 25 条 setup 路径里 24 条都是 …/u_adsr/sustain_product_0_s → …/env_level_o_*_s0/D"
机械核查（跑过）：$t = [IO.File]::ReadAllText('impl/gwsynthesis/Gowin2026_syn_resource.html')
命中数：u_adsr = 0 · u_voice = 0 · voice_i2s = 0
```
- **为什么是问题**：adsr 只被 rtl/w3b/voice.v:66 例化 ← rtl/w3b/voice_i2s_chain.v:50 ← **只有 tb 用**（tb_voice_accept.sv:63、tb_voice_i2s_chain.sv:29、tb_pitch_shift_accept.sv:28）；交付档走的是 rtl/top.v:1440 的 envelope_bank（32 路并行实例已被共享引擎取代，见 envelope_bank.v:1-30）⇒ 那段引用是过期证据，会把人引到不存在的路径上（本项目 §五① 的头号成本）。
- **改法**：把那一段前面加一行历史标注："⛔ 本段描述的是 32 路并行实例时代的路径；该结构已不在交付网表里（impl/gwsynthesis/Gowin2026_syn_resource.html 中 `u_adsr` 0 命中）。当前全设计最差路径见 P0-1。" 并保留 adsr.v —— ⭐ 它仍是 tb_p5_adsr_diff.sv 的参考模型，⛔ 不要删。
- **预期**：下一个人不会去优化一条不在网表里的路径；代价 = 只改注释。
- **怎么验**：`Select-String -Path impl/gwsynthesis/Gowin2026_syn_resource.html -Pattern u_adsr` ⇒ **0 命中**（机械，不用仿真）。
- **来源**：ANVIL-03【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-03|ORIG=P2-2|MOD=rtl/w3c/master_mix.v
### 把 master_mix 的组合穿通输出改成真寄存器
- **位置**：rtl/w3c/master_mix.v:107-128＋:33-34；rtl/top.v:4486-4490；rtl/w3b/tdm_render_mixer.v:799-825、:826-836；tb/w3c/tb_master_mix.sv
- **现状**：
```verilog
107:    wire signed [PROD_W-1:0] prod = sample_i * $signed({1'b0, gain_r});
108:    wire signed [PROD_W-1:0] scaled = prod >>> (GAIN_W - 1);   // >> 15
113:    wire over_pos = ~scaled[PROD_W-1] && (|scaled[PROD_W-2 : SAMPLE_W-1]);
116:    reg signed [SAMPLE_W-1:0] samp_r;
117:    always @(*) begin                       // ⚠️ 组合
128:    assign sample_o = samp_r;
--- rtl/top.v:4486-4490      ⭐ 下游是寄存器 ---
        always @(posedge clk) begin
            if (!rst_n_sync) sample_r <= {SAMPLE_W{1'b0}};
            else if (mm_valid) sample_r <= mm_sample;
```
- **为什么是问题**：交付档 top-25 setup 里没有 `master_mix`（全是 u_tdm_render_mixer / u_note_manager）；=0 档的 25 条 setup 里也没有；master_mix 只出现在 HOLD 段（`gain_r_11_s0 → n169_s0`，2.317 ns，与输出乘法无关）⇒ 当前余量 ≥ 0.85 ns（=0 档第 25 名的 slack），现在不失败 ✅。为什么仍然要盯它：tdm_render_mixer.v:799-825 记着同一个模式的实测代价 —— `samp_r` 组合时"归一化乘法 → 限幅 → 饱和 → 主音量乘法"串在一拍里，实测 `slack = 0.002 ns`、**27 级逻辑**；现在 tdm_render_mixer 那一头已经寄存了（:826-836），这条链的下一段就是 master_mix ⇒ ⭐ P0-2 里任何"把音量抬上去"的改动，最先吃掉的余量就在这里。
- **改法**：把 `samp_r` 变成真寄存器 + `valid_o` 跟着延 1 拍（1 位移位链）。代价：⚠️ 破坏 :33-34 自述的"零延迟透传 valid"契约 ⇒ tb/w3c/tb_master_mix.sv 必须跟着改；真实链上无害（i2s_tx 只在 `frame_start` 装载一次，见 i2s_tx.v:184）。
- **预期**：把 27 级逻辑那类长链从一拍里摘掉，为 P0-2 抬音量腾出余量；代价 = +若干 FF、valid 延迟 1 拍、tb 契约要改。
- **怎么验**：PnR 重跑后确认 master_mix 仍不在 top-25（这是接受改动的判据）；功能 `-Filter tb_master_mix` + `-Filter tb_e2e_key_to_sound`。
- **来源**：ANVIL-03【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-03|ORIG=P2-3|MOD=rtl/w3c/i2s_tx.v,rtl/clk_gen.v
### 给 i2s_tx 补 CLK_PER_SAMPLE == BCLK_DIV×SLOT_BITS×2 的交叉自检
- **位置**：rtl/clk_gen.v:69-74、:86；rtl/top.v:4614、:4656；rtl/w3c/i2s_tx.v:74、:111-113；tb/top/tb_top_m0.sv:350
- **现状**：
```verilog
--- clk_gen.v:69-74   ⭐ 自己承认"本模块查不了，交给调用方" ---
        //    真实约束：`CLK_PER_SAMPLE == BCLK_DIV × SLOT_BITS × 2`
        if ((CLK_PER_SAMPLE % (BCLK_DIV * 2)) != 0)
            $display("ERROR [clk_gen] … 左右时隙不等长", …);
--- clk_gen.v:86 ---
    localparam integer SLOT_BCK = (CLK_PER_SAMPLE / BCLK_DIV) / 2;  // 每声道 BCK 数 = 32
--- top.v:4614 / :4656 ---
        .SLOT_BITS (32),          // ⚠️ 硬编码，与 clk_gen 的 BCLK_DIV 无任何交叉检查
```
- **为什么是问题**：把 `BCLK_DIV` 改成 8（帧内 128 个 BCK）而 `SLOT_BITS` 留 32 ⇒ i2s_tx 每帧只数 64 个 BCK ⇒ `HP_WS`/`HP_DIN` **每帧漂半个帧**（左右声道互换 + 数据落到错误时隙），而 i2s_tx 的 `PARAM_OK`（:111-113）只检查"时隙装得下数据"，查不出这个。⚠️ 为什么只算 P2：tb/top/tb_top_m0.sv:350 直接量 `HP_WS` 周期并断言 `== CLK_PER_SAMPLE` ⇒ 上表这个改动会被现有 tb 抓住（核过它的判据）⇒ 这是契约卫生，不是"没覆盖的洞"。
- **改法**：把 `BCLK_DIV`/`CLK_PER_SAMPLE` 传进 i2s_tx，在它已有的 `initial` 自检里加 `CLK_PER_SAMPLE == BCLK_DIV*SLOT_BITS*2`（照抄 :111-126 的套路，2 行）；或在 tb_top_m0 里显式断言这条恒等式。
- **预期**：把跨模块常量错配变成边界处早报；代价 = 2 行自检（0 硬件）。
- **怎么验**：临时 `BCLK_DIV=8` 重跑 `-Filter tb_top_m0` ⇒ WS 周期判据红（证明检测器在）；加上新检查后 ⇒ 在 i2s_tx 边界就红（更早、更准）。
- **来源**：ANVIL-03【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-03|ORIG=P2-4|MOD=tools
### 把行号口径统一到 ReadAllLines，禁止裸 Get-Content 读 UTF-8 无 BOM 文件
- **位置**：工具链（本机 PowerShell 5.1）；sim/tb_all.ps1:96；bringup/mutation_test.ps1:152；tools/check_ps1_encoding.ps1
- **现状**：
```
$PSVersionTable.PSVersion = 5.1.26100.9444        ← ⭐ 不是 PowerShell 7
rtl/w3b/tdm_render_mixer.v        ReadAllLines= 889   GetContent= 589   ← 少 300 行（34%）
tb/models/oscillator_bank_ref.v   ReadAllLines= 809   GetContent= 549   ← 少 260 行
rtl/w3c/i2s_tx.v                  ReadAllLines= 213   GetContent= 131   ← 少  82 行
rtl/w3c/master_mix.v              ReadAllLines= 143   GetContent= 113   ← 少  30 行
合并实例（master_mix.v，无 BOM）：
Get-Content[55] = "    assign ramp_done  = (gain_r == gain_i);"
真实第 55 行   = ""（空行）  真实第 56 行 = "// ── 主音量（Q1.15 线性增益，[0, 1)）───────"
--- 现状核查（两个长任务脚本是安全的）---
sim/tb_all.ps1:96        $src = Get-Content -LiteralPath $tb.FullName -Raw -Encoding UTF8   # ✅ 显式 UTF8
bringup/mutation_test.ps1:152  $cur = [System.IO.File]::ReadAllBytes($src)                    # ✅ 字节级
```
- **为什么是问题**：裸 `Get-Content` 把 UTF-8 无 BOM 的 RTL/`.md` 按 GBK 解码 ⇒ 非 ASCII 序列把后面的换行吃掉 ⇒ **行数都会变**（tdm_render_mixer 889→589）—— 与项目已归档的 `C72` **同一根因**，但 C72 的记录范围是 `.ps1`，这里证明同样的坑覆盖 `rtl/` 与 `files/**/*.md`（README 直接 Get-Content 出来就是 mojibake，现场看到）。tb_all.ps1 / mutation_test.ps1 不会踩到；⚠️ 但任何"临时一行命令"、任何新写的脚本、以及**本审查报告的行号**都会踩。
- **改法**（三选一，推荐 ①+③）：①所有脚本一律 `-Raw -Encoding UTF8` 或 `[IO.File]::ReadAllText`；**行号一律用 `ReadAllLines`**。②把 tools/check_ps1_encoding.ps1 的规则扩到 RTL/`.md`（判据同款：非 ASCII 字节 > 0 且无 BOM ⇒ 报警），或者干脆给 `rtl/**/*.v`、`files/**/*.md` 也加 BOM（⚠️ 但那会动 git diff，要先确认行尾规则）。③在审查/排查清单里加一行机械检查：`(Get-Content f).Count -ne [IO.File]::ReadAllLines(f).Count` ⇒ 两个数不等就是踩了。
- **预期**：消除"行号指错位置"这一类返工；代价 = 脚本/清单层面的约定，0 硬件。
- **怎么验**：上面那 4 行计数命令本身就是判据（⛔ 不需要仿真）。
- **来源**：ANVIL-03【P2-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-1|MOD=rtl/w3c/master_mix.v
### 删掉 master_mix 里无人读的 gain_diff 并修正注释
- **位置**：rtl/w3c/master_mix.v:72、:78、:77、:79-81
- **现状**：
```verilog
 72:    wire [GAIN_W-1:0] gain_diff;
 78:    assign gain_diff = gain_i - gain_r;   // ⛔ 全文无人读
 77:    注释"用差判方向"（与代码不符，方向其实由 :79-81 的比较决定）
```
- **为什么是问题**：死线网 + 注释与代码不一致（本项目复发缺陷），方向判断实际由 :79-81 的比较决定，注释会误导维护者。
- **改法**：删掉，或真的用它做方向判断；顺带改 :77 注释。
- **预期**：消除死线网与失真注释；代价 0（综合器本来会裁）。
- **怎么验**：`Select-String -Path rtl\w3c\master_mix.v -Pattern 'gain_diff'` 应只剩声明处（或全空）。
- **来源**：ANVIL-03【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-2|MOD=rtl/top.v,rtl/w3c/master_mix.v
### 把 master_mix 的 ramp_busy_o 接到调试通道或删掉端口
- **位置**：rtl/w3c/master_mix.v:63-64；rtl/top.v:4481
- **现状**：
```verilog
rtl/top.v:4481:        .ramp_busy_o  ()      // 模块自己在 :63-64 声明"K-106 可观测性"的输出，在顶层被丢弃
```
- **为什么是问题**：模块自己声明这是 K-106 可观测性输出，却在顶层被丢弃 ⇒ "声明了但看不见"，与 K-106（⛔ 不许静默失效）直接矛盾。
- **改法**：接到已有的调试/LED 通道，或删掉端口（⛔ 别留"声明了但看不见"）。
- **预期**：可观测性契约成立（或消除虚假接口）；代价 0。
- **怎么验**：`Select-String -Path rtl\top.v -Pattern 'ramp_busy'` 应命中一个真实消费者，或该端口在两边都消失。
- **来源**：ANVIL-03【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-3|MOD=rtl/w3c/i2s_tx.v
### 把 i2s_tx 的 LRCK_POL[0] 位选改成 (LRCK_POL != 0)
- **位置**：rtl/w3c/i2s_tx.v:179、:190、:203；对照 rtl/w3b/tdm_render_mixer.v:105-113、:130-136（为它专门写过踩坑记录）
- **现状**：
```verilog
179/190/203: 使用 LRCK_POL[0]     // ⛔ 对 integer 参数做位选（K-91/K-99 明令禁止）
```
- **为什么是问题**：`LRCK_POL[0]` 正是本项目 K-91/K-99 明令禁止的构造；{0,1} 取值下无害，但纪律自相矛盾，且 tdm_render_mixer 为它专门写过踩坑记录。
- **改法**：改 `(LRCK_POL != 0)`。
- **预期**：纪律一致；代价 0（编译期常量）。
- **怎么验**：`Select-String -Path rtl\w3c\i2s_tx.v -Pattern 'LRCK_POL\['` ⇒ 0 命中；`-Filter tb_i2s_tx` 全绿。
- **来源**：ANVIL-03【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-4|MOD=rtl/w3c/i2s_tx.v
### 明确 i2s_tx.top_bits 的截断口径（或加 0x80 四舍五入）
- **位置**：rtl/w3c/i2s_tx.v:136-144；tb/w3b/tb_tdm_render_mixer.sv:349-352
- **现状**：
```verilog
136:    function [DATA_BITS-1:0] top_bits;
142:                if (k < SAMPLE_W) top_bits[DATA_BITS-1-k] = s[SAMPLE_W-1-k];
```
- **为什么是问题**：`top_bits` 取高 16 位 = **截断**低 8 位（不四舍五入）⇒ −0.5 LSB 直流偏置（tb_tdm_render_mixer.sv:349-352 已记录同族现象）。
- **改法**：要么加 `+ 0x80` 再截（⚠️ 必须同时确认饱和路径），要么在注释里写明"故意截断"。
- **预期**：消除 0.5 LSB 直流偏置或把它写成契约；代价 = 一个加法器（或 0，只改注释）。
- **怎么验**：`-Filter tb_i2s_tx`、`-Filter tb_tdm_render_mixer` 全绿；若加 0x80，需新增"满幅不溢出"判据。
- **来源**：ANVIL-03【P3-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-5|MOD=rtl/w3b/envelope_bank.v
### 修正 envelope_bank 里 prod_p 的位宽注释
- **位置**：rtl/w3b/envelope_bank.v:191-196
- **现状**：
```verilog
191-196: 注释说 "this wire is 32 bits wide"，实际 wire [ENV_W+15:0] prod_p = 31 位（ENV_W=16）
```
- **为什么是问题**：注释↔代码不一致（本项目复发缺陷）。乘积上界 `65280×230 = 15 014 400 < 2²⁴` ⇒ 无害。
- **改法**：改注释。
- **预期**：注释与代码一致；代价 0。
- **怎么验**：`Select-String -Path rtl\w3b\envelope_bank.v -Pattern '32 bits wide'` ⇒ 0 命中。
- **来源**：ANVIL-03【P3-5】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-6|MOD=rtl/w3b/adsr.v,rtl/w3b/envelope_bank.v
### 给两份逐字重复的 *_for_timbre 函数加一致性注释
- **位置**：rtl/w3b/adsr.v:45-95 vs rtl/w3b/envelope_bank.v:69-119；tb/w3b/tb_p5_adsr_diff.sv
- **现状**：
```
adsr.v:45-95 与 envelope_bank.v:69-119 的 4 个 *_for_timbre 函数逐字重复两份（A/D/S/R 的 4 组常数）
```
- **为什么是问题**：改一处忘一处就静默分叉。已有 tb/w3b/tb_p5_adsr_diff.sv 兜底 ⇒ 保持现状可接受；若要根治，让 envelope_bank 例化 adsr 的 function 不可行（Verilog-2001）。
- **改法**：建议只加一条"两份必须一致"的注释 + 依赖该 tb。
- **预期**：把静默分叉风险显式化；代价 0。
- **怎么验**：`-Filter tb_p5_adsr_diff` 必须 PASS；注释 grep 命中。
- **来源**：ANVIL-03【P3-6】
@@@END
@@@PRIO=P3|SRC=ANVIL-03|ORIG=P3-7|MOD=rtl/w3b/tdm_render_mixer.v
### 把限幅器的 localparam signed 比较改成逐位判据（工具无关性）
- **位置**：rtl/w3b/tdm_render_mixer.v:746、:780、:782、:788-790 vs :340-347（纪律）；:721-790
- **现状**：
```verilog
:340-347 明写「⛔ 不用 signed 限定符 + 比较（iverilog 会退化成无符号比较）」
:746-750、:780-790 的限幅器就是 localparam signed + 比较
实测（Icarus Verilog version 14.0 (devel)）：
A pos9>MAX_A  = 1 (want 1)     A neg1>MAX_A  = 0 (want 0)
A neg9<MIN_A  = 1 (want 1)     A pos9<MIN_A  = 0 (want 0)
B xneg9>LIM   = 0 (want 0)     B xneg9<-LIM  = 1 (want 1)     B xpos9>LIM = 1 (want 1)
⇒ ⭐ 7/7 全部是有符号正确结果
```
- **为什么是问题**：与 :340-347 的纪律冲突，但**实测 iverilog 14.0 行为正确（7/7）⇒ 不是活缺陷**（⛔ 别当 bug 去"修"）。归 P3 的理由是**工具无关性**，不是"修 bug"。
- **改法**：若要工具无关，改成逐位判据（`sign = sh_norm_w[MSB]` + 幅值无符号比较）。⚠️ 改了必须重跑验收 tb（⛔ 别当"修 bug"轻率动它）。
- **预期**：与自订纪律一致、不依赖工具的有符号语义；代价 = 少量 LUT + 必须重跑验收 tb。
- **怎么验**：`-Filter tb_tdm_render_mixer`、`-Filter tb_velocity_headroom` 必须全绿；且新写法在 iverilog 与 Gowin 两侧给出同结果。
- **来源**：ANVIL-03【P3-7】
@@@END
@@@TOTAL SRC=ANVIL-03 COUNT=16 P0=2 P1=3 P2=4 P3=7
