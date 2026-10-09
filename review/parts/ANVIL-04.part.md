@@@PRIO=P0|SRC=ANVIL-04|ORIG=P0-1|MOD=rtl/w3b/wavetable_bank.v
### 把 10 处硬编码 addr_i[9:0] 参数化，并把契约自检升级成能红的 $fatal
- **位置**：rtl/w3b/wavetable_bank.v:26（端口）、:60/:135/:210/:285/:360/:435/:510/:585/:660/:735（10 处地址）、:850-854（自检）
- **现状**：
```verilog
26:    input wire [$clog2(DEPTH)-1:0] addr_i,          // ← 宽度【跟着 DEPTH 走】
60:        .AD({addr_i[9:0], 4'b0000})                  // ← 但切片【写死 10 bit】
850:    initial begin
851:        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
852:            (DEPTH != 1024) || (SAMPLE_W != 16))
853:            $display("ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");
854:    end
```
- **为什么是问题**：`DEPTH` 在全文只有 2 处被引用（:26 的 `$clog2(DEPTH)` 和 :852 的比较），它不参与任何地址运算。10 处 `.AD()` 里的 `addr_i[9:0]` 把字地址写死成 10 bit = 1024 项（`$clog2(1024)=10`）。Gowin pROM 在 `BIT_WIDTH=16` 时用 **`AD[13:4]`** 作字地址，所以 `{addr_i[9:0], 4'b0000}` 对 `DEPTH=1024` 是正确的 —— **坑不在位序，在于"10"这个字面量**。把 `DEPTH` 改成 2048：端口自动变 11 bit，但地址仍只取低 10 bit ⇒ `addr_i[10]` 被静默丢弃 ⇒ `addr 1024` 与 `addr 0` 命中同一表项。:851-853 的守卫抓不住，三重失效：①它是 `$display` 不是 `$error`/`$fatal` ⇒ vvp 退出码仍是 0；②sim/tb_all.ps1:347 把 ERROR 行只当诊断信息，判据是 :346 的 `(?m)^[ \t]*[^A-Za-z]*FAIL:` 或非零退出码 ⇒ ERROR 行不算失败；③就算算失败，`initial` 块在 Gowin 综合里被丢弃（见 P2-6）⇒ 上板前也无人拦。实测（本报告新增探针，源码 review/raw/_probe_depth.v）：iverilog 编译 exit=0；vvp 打印 `ERROR [wavetable_bank] fixed pROM contract is 4x1024x16`，`PROBE addr=0 -> soft=373`、`addr=1 -> soft=597`、**`addr=1024 -> soft=373`（与 addr=0 同值，别名）**、`addr=1025 -> soft=597`（与 addr=1 同值），`$LASTEXITCODE → 0`（守卫没拦住）。373/597 与 tb/w3b/tb_wavetable_bank.sv:307 的 `read_and_check(2'd0, 10'd0, 16'sd373, …)` 和 `rom_soft_t0` 的 `INIT_RAM_00 = 256'h…02550175` 逐值吻合。
- **改法**（参数化，且对 `DEPTH=1024` 逐位等价）：
```verilog
// 10 处统一改成：
.AD({{(14-$clog2(DEPTH)){1'b0}}, addr_i})
// DEPTH=1024 ⇒ {4'b0000, addr_i[9:0]}  —— 与现状逐位相同
// DEPTH=2048 ⇒ {3'b000, addr_i[10:0]} —— 不再丢 bit
```
并把自检从"打印"升级为"能红"：`$fatal(1, "ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");`。⚠️ `$fatal` 会改掉 tb_all.ps1 的退出码语义（`$runExit -ne 0` ⇒ 判失败），这正是想要的；但必须同时确认现有 4 个消费者（oscillator_bank / tb_wavetable_bank / tb_wavetable_bank_prom / tb_akwf_wavetables / tb_wavetable_timbres）都用默认参数，否则会误红。
- **预期**：消除一类静默错数据（读到别的表项 ⇒ 音高/波形全错但"有声音"，与"静音"完全不同，最难定位）。**不是时序收益。**
- **怎么验**：①探针：改造后 `PROBE addr=1024` 必须 ≠ `PROBE addr=0`，且 `DEPTH=1024` 时全部逐点与 tb_wavetable_bank 的 golden 一致（证明没有回归）；②判据门：把 `$display` 改 `$fatal` 后，用一个 `DEPTH=2048` 的 tb 跑 `sim\tb_all.ps1 -Filter wavetable` ⇒ 必须出现 `FAIL:` 行且汇总不是"通过 N / 共 N"。
- **来源**：ANVIL-04【P0-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-04|ORIG=P1-1|MOD=sim/tb_all.ps1,tb/w3b/tb_wavetable_bank_prom.sv
### 删掉 WAVETABLE_BEHAVIORAL 这个空壳宏分支（它守的是同一个分支）
- **位置**：sim/tb_all.ps1:109-122（:117-121）；tb/w3b/tb_wavetable_bank_prom.sv:1-24、:165-167；sim/check_nonempty.ps1:122；sim/check_met_btn_nonempty.ps1:241；build/mut_t3.ps1:37；build/mut_t3b.ps1:25
- **现状**：
```powershell
# sim/tb_all.ps1:117-121
$isPromVariant = $name -like "*_prom*"
if ($isPromVariant) {
  $compileArgs = @("-g2012","-Wall","-s",$name,"-o",$vvpFile) + $rtl + $models + $chk + @($tb.FullName)
} else {
  $compileArgs = @("-g2012","-Wall","-DWAVETABLE_BEHAVIORAL","-s",$name,"-o",$vvpFile) + $rtl + $models + $chk + @($tb.FullName)
}
```
- **为什么是问题**：全仓 grep `WAVETABLE_BEHAVIORAL`：命中 11 处，全部在 `.ps1`/`.sv` 的注释和编译参数里；**`rtl/` 下 0 命中**（rtl/w3b/wavetable_bank.v 里没有任何 `` `ifdef ``）⇒ 两条分支编译的是同一份 RTL；`_prom` 变体只是少传一个没人看的宏 ⇒ tb_wavetable_bank.sv 与 tb_wavetable_bank_prom.sv 是同一份判据的两次拷贝（前者的 512 点段被注释掉了，实际只剩后者那 5 条 `read_and_check` ＋ 后者没有的噪声表统计判据）⇒ **判据数量在涨，覆盖面积没涨**。这正是 C83（探针假绿）的同族：判据看起来在守"综合分支"，实际守的是同一个分支。
- **改法**（二选一，推荐 A）：A · 删掉空壳：把 tb_all.ps1:109-122 的 `$isPromVariant` 分支、以及 check_nonempty.ps1 / check_met_btn_nonempty.ps1 / mut_t3*.ps1 里的 `-DWAVETABLE_BEHAVIORAL` 一并删掉，并在 tb_wavetable_bank_prom.sv 头注释里写明"T31b 之后不存在行为级分支，本 tb 与 tb_wavetable_bank 同源，保留仅因历史"。B · 让宏真的有分支：给 wavetable_bank 加 `` `ifdef WAVETABLE_BEHAVIORAL `` 的 case 常量表分支 ＋ else 的 pROM 分支 —— 但这等于把"仿真/上板双实现"这个已知会漂移的模式再引回来（本项目已经因为 T31b 合并把它删了），⛔ 不推荐。
- **预期**：消除一条恒真的判据；回归从 129 个 tb 里真正少一个零覆盖的条目，或者让这 129 个里每一个都有意义。**不是时序收益。**
- **怎么验**：改完后跑 `sim\tb_all.ps1 -Filter wavetable` —— 若只做 A，tb_wavetable_bank_prom 必须仍然 PASS（它本来就跑同一份 RTL）；真正的"能红"判据是：对 rtl/w3b/wavetable_bank.v 注入一个只影响 `INIT_RAM_*` 常量的变异（如把 `rom_soft_t0` 的 `INIT_RAM_00` 末 4 位 `0175`→`0176`），两个 tb 必须同时变红 —— 若只有 tb_wavetable_bank 红而 `_prom` 不红，说明两者真的不同源（当前会同时红，这就是"同源"的实证）。
- **来源**：ANVIL-04【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-04|ORIG=P1-2|MOD=rtl/w3b/wavetable_bank.v
### 给 wavetable_bank 补一个真正的 valid 脉冲输出（现有 valid_o 是电平延迟）
- **位置**：rtl/w3b/wavetable_bank.v:31、:839-848；消费者 rtl/w3b/oscillator_bank.v:863
- **现状**：
```verilog
31:    output reg valid_o
839:    always @(posedge clk_i) begin
840:        if (!rst_n_i) begin
841:            valid_o  <= 1'b0;
842:            timbre_q <= {TIMBRE_W{1'b0}};
843:        end else begin
844:            valid_o <= rd_en_i;                 // ← 电平延迟，不是脉冲
845:            if (rd_en_i)
846:                timbre_q <= timbre_i;
847:        end
848:    end
--- rtl/w3b/oscillator_bank.v ---
863:        .valid_o  ()                            // ← 悬空
```
- **为什么是问题**：`valid_o` 只是 `rd_en_i` 打一拍。`rd_en_i` 在 oscillator_bank 里是 `req_active = rendering && (cnt < LANES[LW:0])`（oscillator_bank.v:742），`LANES = POLY_TARGET × OSC_PER_VOICE = 32 × 2 = 64`（:259）⇒ 一次采样帧里 `rd_en_i` 连续高 64 拍 ⇒ `valid_o` **连续高 65 拍**。也就是说 `valid_o` 不是"一次读有效"，而是"上一次 `rd_en_i` 的电平"。tb_wavetable_bank.sv:287-289 之所以没踩到，是因为 tb 每读一个点就拉低一拍 `rd_en_i`（:288 与 :315 都显式写 `rd_en_i = 1'b1/0`）。交付网表里它悬空（oscillator_bank.v:863），所以今天不出错；但这是"判据比消费者强"的典型：tb 把一个 65 拍的高电平当成"65 次有效"，而任何新消费者（例如给 tdm_render_mixer 加流控、或给 bringup 做单点探针）按 `valid_o` 计数就会 **64× 过采样**。
- **改法**（推荐 A，最小风险）：A · 把语义写进名字＋加一个真正的脉冲：保留 `output reg valid_o`（= rd_en_i 延迟 1 拍，向后兼容）＋新增 `output reg valid_pulse_o`（只在 rd_en_i 的上升沿后 1 拍为高）；实现：加 `reg rd_en_d;` ⇒ `valid_pulse_o <= rd_en_i & ~rd_en_d;`，成本 **+1 FF**，老消费者（4 个 tb ＋ oscillator_bank）一行不动。B · 直接改语义 `valid_o <= rd_en_i & ~rd_en_d;`：不会打破 tb_wavetable_bank.sv:290 / tb_wavetable_bank_prom.sv:201 的 `valid_o !== 1'b1` 判据（那些 tb 的 `rd_en_i` 本来就是单拍脉冲，上升沿检测后行为逐位相同），但 tb_akwf_wavetables / tb_wavetable_timbres 若连续拉高 `rd_en_i` 就会红（必须先读那两个 tb）⇒ 选 A 更稳。
- **预期**：消除一个"名字骗人"的输出。**不是时序收益**（悬空输出会被工具裁掉，rpt.txt 里也看不到它）。
- **怎么验**：写一个 5 行的探针 tb：把 `rd_en_i` 连续拉高 **8 拍**，断言 `valid_o` 的高电平拍数 —— 改造前 = **9 拍**（含延迟），改造后 `valid_pulse_o` = **1 拍**；判据写成 `FAIL:` 行 ⇒ 可被 tb_all.ps1 抓。
- **来源**：ANVIL-04【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-04|ORIG=P1-3|MOD=rtl/w3b/wavetable_bank.v
### 按音色门控 10 块 pROM 的 CE，把每次读的翻转块数从 10 降到 2
- **位置**：rtl/w3b/wavetable_bank.v:58/:133/:208/:283/:358/:433/:508/:583/:658/:733（10 处 `.CE(rd_en_i)`）＋ :808-815（音色选择在 ROM 之后）
- **现状**：
```verilog
54:    pROM rom_soft_t0_inst (
58:        .CE(rd_en_i),                       // ← 无条件：所有 10 块一起翻转
808:    always @(*) begin                       // ← 选择在【ROM 输出之后】
809:        case (timbre_q)
810:            2'd0: begin rom_soft_sel = rom_soft_t0_inst_do; rom_hard_sel = rom_hard_t0_inst_do; end
```
- **为什么是问题**：TDM 每帧送 64 个地址（LANES=64），采样率 = 50 MHz / 1024 = 48 828 Hz ⇒ BSRAM 读次数 = 64 × 48 828 ≈ **3.125 M 次/秒**；每次读，**10 块** BSRAM 的地址/输出寄存器同时翻转 ⇒ **31.25 M 次 BSRAM 读/秒**；但每拍真正被消费的只有 1~2 张表（`rom_dout` 三选一，见 oscillator_bank.v:845-847）⇒ 有效利用率 ≈ **10%~20%**。功耗实测（impl/pnr/Gowin2026.power.html）：Logic 15.821 mW、**BSRAM 64.634 mW**、DSP 19.557 mW、**Total 204.092 mW** ⇒ BSRAM 占总功耗 **31.7%，是最大单块**；wavetable_bank 的 10 块 pROM 占全部 33 块 BSRAM 的 **30.3%**（rpt.txt：BSRAM 33/118，其中 `--pROM 10`、`--SDPB 7`、`--SDPX9B 16`）⇒ 折算 ≈ **19.6 mW**，其中 4 块是死的（见 P2-1）。
- **改法**（按收益/风险排序）：①按音色门控 CE（推荐，改动最小）：
```verilog
wire ce_t0 = rd_en_i && (timbre_i == 2'd0);
wire ce_t1 = rd_en_i && (timbre_i == 2'd1);
wire ce_t2 = rd_en_i && (timbre_i == 2'd2);
wire ce_t3 = rd_en_i && (timbre_i == 2'd3);
// 10 处 .CE(...) 分别接 ce_t0/ce_t1/...（soft 与 hard 同音色共用一条）
```
为什么安全：`timbre_q` 选中的正是当拍被使能的那一块（两者都在 `rd_en_i` 那拍更新），未选中的块保持旧值而不被选 ⇒ 输出逐位不变；成本 4 个 2 bit 比较器（≈4 LUT）＋ 4 条 CE 网；收益：每次读的翻转块数从 10 → 2（soft ＋ hard 同音色）⇒ 读功耗 **−80%**。②再把 `rom_test_sine`/`rom_noise` 也门控（`ce_test = rd_en_i && test_mode_i`、`ce_noise = rd_en_i && resp_drum`）—— ⚠️ 但它们的选择信号在 oscillator_bank 里，需要新增 2 个输入端口，会打破 4 个 tb 的例化 ⇒ 必须给默认值或用 `===` 兜底（同 `voice_drum_i` 的 z 前科）；收益再 −20%；建议第二步再做，先做①。
- **预期**：读功耗从 10 块降到 2 块，按 BSRAM 64.634 mW × 30.3%（wavetable 占块比例）× 80%（削减比例）估算 ≈ **15.7 mW**（**估算值，非工具直接输出**；工具只给总块功耗，不做实例级分解）。**不是时序收益。**
- **怎么验**：①功能：`sim\tb_all.ps1 -Filter wavetable` 必须全 PASS（输出逐位不变），tb_wavetable_bank.sv:307-311 的 5 条 `read_and_check` 会逐表逐点验证 `timbre_i` 切换后取到的是对的表；②功耗：重跑 PnR 比较 Gowin2026.power.html 的 BSRAM 行，预期从 64.634 mW 下降（⚠️ 功耗模型依赖仿真激励的翻转率，本项目 PnR 不带激励 ⇒ 工具用的是默认翻转率估计，绝对可信度有限，只能做 A/B 相对比较）；③非空洞性：把 `ce_t0` 写成 `rd_en_i && (timbre_i == 2'd1)`（故意门错一格），tb_wavetable_bank 的 `read_and_check(2'd0, 10'd0, 373, 226)` 必须变红。
- **来源**：ANVIL-04【P1-3】
@@@END
@@@PRIO=P1|SRC=ANVIL-04|ORIG=P1-4|MOD=rtl/w3b/oscillator_bank.v
### 把 rom_timbre 的跨模块组合穿透改成每 lane 一份影子寄存器
- **位置**：rtl/w3b/oscillator_bank.v:695-696、:744、:856；源头 rtl/w3b/note_manager.v:1647
- **现状**：
```verilog
// rtl/w3b/note_manager.v:1647
assign voice_timbre_o[g*TIMBRE_W +: TIMBRE_W] = timbre_r[g];      // ← 寄存器输出，64 bit
// rtl/w3b/oscillator_bank.v:695-696   —— 注意：lane_addr 是【寄存器】，lane_timbre 不是
assign lane_addr[g*AW +: AW]       = addr_q;
assign lane_timbre[g*TIMBRE_W +: TIMBRE_W] =
    voice_timbre_i[VOICE_IDX*TIMBRE_W +: TIMBRE_W];               // ← 直穿顶层网，零寄存
// rtl/w3b/oscillator_bank.v:743-744
wire [AW-1:0]      rom_ad     = lane_addr[req_idx*AW +: AW];       // 64:1 × 10 bit
wire [TIMBRE_W-1:0] rom_timbre = lane_timbre[req_idx*TIMBRE_W +: TIMBRE_W];  // 64:1 × 2 bit
// rtl/w3b/oscillator_bank.v:856
.timbre_i (rom_timbre),                                           // → wavetable_bank.timbre_q
```
- **为什么是问题**：`lane_addr` 走 `addr_q`（`phase_q` 的寄存器切片），`lane_timbre` 走顶层输入网 —— 两条并行数据路径的起点深度不同。路径长度：`note_manager.timbre_r[g]`（FF）→ 跨模块长线（64 bit × 2 = 128 根，横跨 32 个 voice 的布局区域）→ 64:1 mux（`req_idx[5:0]` 选择，LUT4 需要 ⌈log₄64⌉ = **3 级**）→ `wavetable_bank.timbre_i` → `timbre_q`（FF）。它是单周期约束路径（clk_sys 20 ns，且被 `set_max_delay 18.181` 再收紧到 18.181 ns）。但它的语义是"静态值"：`voice_timbre_i` 只在 `note_on` 那一刻被 note_manager 改写（oscillator_bank.v:890-892 明确写"后续全局音色变化不会改写在响 voice"）⇒ 这条路径名义上要 1 拍收敛，实际上有 ≥1024 拍的语义余量 ⇒ 典型的"假关键路径"：STA 按单周期卡它，但它的物理需求远低于此。⛔ 不能用 `set_false_path`/`set_multicycle_path` 去"放"它 —— `note_on` 提交正好发生在 `sample_tick` 那一拍，而 TDM 读 lane 0 就在下一拍 ⇒ 最短间隔只有 **1 拍**，放松约束会真的错（读到旧音色）。
- **改法**：把"直穿"变成"寄存"：
```verilog
// 在 gen_voice 里新增每 lane 一份的 2 bit 影子寄存器，与 addr_q 同一个 always 块
reg [TIMBRE_W-1:0] timbre_q_lane;
always @(posedge clk_i) begin
    ...
    timbre_q_lane <= voice_timbre_i[VOICE_IDX*TIMBRE_W +: TIMBRE_W];   // 每拍跟随
end
assign lane_timbre[g*TIMBRE_W +: TIMBRE_W] = timbre_q_lane;
```
成本 64 lane × 2 bit = **+128 FF**（当前 Register 17039/60780 = 29%，占比 +0.2%）。为什么安全：`voice_timbre_i` 是静态值 ⇒ 寄存后与直穿逐位相同，唯一差异是 `note_on` 当拍晚 1 拍生效（那一拍 TDM 还没开始读该 lane）⇒ tb_p5_osc_equiv 的 320 帧逐位等价判据应当仍然 0 mismatch。⚠️ 必须先验证：若某个 tb 检查"`voice_timbre_i` 变化后当拍就能在 `osc_sample_bus_o` 上看到新音色"，加寄存器会红 ⇒ 先跑 `-Filter oscillator` ＋ `-Filter wavetable` ＋ `-Filter p5_osc` 再动手。
- **预期**：把一条 64 bit 宽 × 3 级 mux × 跨模块的单周期路径，变成"本地 FF → 本地 3 级 mux → 本地 FF" ⇒ 路径长度砍掉跨模块那一段。⚠️ 量化收益未知（见 R-1：这条路径不在当前 top-50 关键路径里）⇒ 不能宣称 Fmax 提升，这是预防性改动。
- **怎么验**：①tb_p5_osc_equiv（320 帧，比 64 lane 样点总线 ＋ `osc_valid_o` ＋ 全部 64 个相位累加器）必须 **0 mismatch**；②非空洞性：把新增的 `timbre_q_lane` 故意接成 `voice_timbre_i[(VOICE_IDX^1)*TIMBRE_W +: TIMBRE_W]`（错一个 voice）⇒ tb_p5_osc_equiv 或 tb_wavetable_bank 必须变红。
- **来源**：ANVIL-04【P1-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-04|ORIG=P1-5|MOD=Gowin2026.gprj,rtl/w3b/dds_wavetable_core.v,rtl/w3b/voice.v,rtl/w3b/voice_i2s_chain.v
### 明确 dds_wavetable_core / voice / voice_i2s_chain / wavetable_sine_rom_ip 不在交付网表
- **位置**：Gowin2026.gprj:62、:75、:76、:77；impl/pnr/Gowin2026.rpt.txt §3；impl/gwsynthesis/Gowin2026.log:17-19、:170；sim/tb_all.ps1:53
- **现状**：
```
Gowin2026.gprj:62  <File path="ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v" enable="1"/>
Gowin2026.gprj:75  <File path="rtl/w3b/dds_wavetable_core.v"                   enable="1"/>
Gowin2026.gprj:76  <File path="rtl/w3b/voice.v"                                enable="1"/>
Gowin2026.gprj:77  <File path="rtl/w3b/voice_i2s_chain.v"                      enable="1"/>
rpt.txt §3 Resource Usage Summary:
    BSRAM  33/118
      --SDPB     7
      --SDPX9B  16
      --pROM    10          ← 只有 wavetable_bank 的 10 块；sine ROM 的 pROM 不在
```
- **为什么是问题**：`wavetable_sine_rom_ip` 唯一的例化点：dds_wavetable_core.v:36（＋老 tb 的模型 tb/models/wavetable_sine_rom_ip_model.sv）；`dds_wavetable_core` 的例化点：voice.v:56、rtl/bringup/wavetable_tone_top.v:56；`voice` 的例化点：voice_i2s_chain.v:50；`voice_i2s_chain` 的例化点：**全仓 0 个**（top.v 里 grep voice 只有注释）。综合日志 impl/gwsynthesis/Gowin2026.log：:17-19 只是 `Analyzing Verilog file`（解析，不是综合）；:170 有 `Compiling module 'wavetable_bank'`，全日志没有 `Compiling module 'voice'` / `'dds_wavetable_core'` / `'wavetable_sine_rom_ip'` ⇒ Gowin 只编译被例化的模块 ⇒ 这一整棵子树不在交付网表里。`pROM` 计数 10 就是铁证：若 wavetable_sine_rom_ip 进了网表，这个数会是 **11**。后果：tb/w3b/tb_dds_wavetable_core.sv（48 行模块，95 行 tb）、tb/voice/tb_voice_accept.sv 全绿，但它们验证的 RTL 一个门都没进 FPGA；同时这棵子树里的任何缺陷（含 P1-6）上板永远暴露不出来，也不会被四道门抓到。
- **改法**（三选一）：A · 承认它是死代码并下架：从 .gprj 里把 ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v、rtl/w3b/dds_wavetable_core.v、rtl/w3b/voice.v、rtl/w3b/voice_i2s_chain.v 的 `enable` 改 0（保留文件，tb_dds_wavetable_core 仍能跑 —— 它走 sim/tb_all.ps1 的 `Get-HdlSources rtl` 自动收集，不依赖 gprj；⚠️ 注意 sim/tb_all.ps1:53 是从 rtl/ 目录收集源文件、不看 gprj ⇒ 改 enable 不影响回归，只影响 PnR 的编译清单）。B · 把它接进 top：⛔ 不推荐 —— 会凭空多出 1 块 BSRAM（P1-6 那张 512 点表），而且 voice 是单音架构，与 oscillator_bank 的 64 lane 是两条互斥路线。C · 保留现状但在文档里钉住：在 rtl/w3b/dds_wavetable_core.v 头注释里加一行 `// ⚠️ 本模块【不在】Gowin2026.gprj 的例化树里（pROM 计数 10 可证）—— 它是兼容/参考实现`（最低成本、也最诚实）。
- **预期**：消除"回归在给不存在的硬件打分"这个认知陷阱；若做 A，还能省掉 PnR 的 4 个文件解析时间（量级很小，几十毫秒）。**不是时序收益。**
- **怎么验**：做 A 后重跑 PnR ⇒ rpt.txt 的 `pROM` 必须仍然是 10（证明这 4 个文件本来就没进网表，也证明改动没有副作用）；`sim\tb_all.ps1 -Filter dds` 必须仍然 PASS。
- **来源**：ANVIL-04【P1-5】
@@@END
@@@PRIO=P1|SRC=ANVIL-04|ORIG=P1-6|MOD=rtl/w3b/dds_wavetable_core.v
### 给 512 点 DDS 表加 4 bit 线性插值（或明确它禁止用于交付音频通路）
- **位置**：rtl/w3b/dds_wavetable_core.v:17、:31、:42；表 ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:18、:31；tb/w3b/tb_dds_wavetable_core.sv:71-73；rtl/w3b/wavetable_bank.v:654-728
- **现状**：
```verilog
// rtl/w3b/dds_wavetable_core.v
17:    reg [31:0] phase_acc;                                    // 32 bit 累加器
31:                phase_acc <= phase_acc + phase_inc_i;
42:        .ad    (phase_acc[31:23])                            // 只取高 9 bit ⇒ 512 点
// ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v
18:    input [8:0] ad;                                          // 9 bit = 512 项
31:        .AD({gw_gnd,ad[8:0],gw_gnd,gw_gnd,gw_gnd,gw_gnd})    // AD[13:4] = {1'b0, ad}
```
- **为什么是问题**：累加器 32 bit，表地址 9 bit ⇒ **截断 23 bit**。表本身是理想正弦的精确四舍五入（`sine_512x16.hex` 首 4 行 = `0000 0192 0324 04B6`，与 `32767·sin(2πk/512)` 逐值吻合；tb_dds_wavetable_core.sv:71-73 的期望值 `0/402/804` 也印证）⇒ 表没有误差，误差全部来自"用截断后的相位查表"。截断造成的最大相位误差 = 半个表步 = π/512 = 0.006136 rad ⇒ 输出误差上界 = `32767 × 0.006136 = 201 LSB` ⇒ 误差峰峰值 = **402 LSB**，其基波分量 ≈ `402/π = 128 LSB` ⇒ 相对满幅 `20·log10(128/32767) = −48.2 dBc`。标准 DDS 相位截断公式（W = 保留相位位数）：`SFDR ≈ 6.02·W − 3.92 = 6.02×9 − 3.92 = 50.3 dBc` ⇒ 两条独立估算互相印证：**约 −48 ~ −50 dBc**。对音频的意义：−48 dBc 的杂散在单音下接近可闻阈值，在复音叠加时会以"非谐波边带"形式堆积 ⇒ 数码味/毛刺感的经典来源之一。附带资源问题：这张 512 点表（1 块 BSRAM，8 Kbit 有效容量装在一个 16 Kbit 的 BSRAM 里 ⇒ 一半容量闲置）与 wavetable_bank 的 `rom_test_sine_inst`（:654-728，**1024 点纯正弦**：`memory[0]=0`、`[1]=201`、`[256]=32767`、`[512]=0`、`[511]=201`）是同一条正弦的两个分辨率副本 ⇒ 同一块 FPGA 里存了两份。
- **改法**（按性价比）：①加 4 bit 线性插值（推荐，收益最大）：
```verilog
wire [8:0]  a0 = phase_acc[31:23];
wire [3:0]  frac = phase_acc[22:19];          // 4 bit 小数
wire [8:0]  a1 = a0 + 9'd1;
wire signed [16:0] interp = $signed({s0[15], s0}) +
    ((($signed({s1[15], s1}) - $signed({s0[15], s0})) * $signed({1'b0, frac})) >>> 4);
```
⚠️ 代价：需要 `s0` 与 `s1` 同拍，即两个读口（pROM 是单口）⇒ 要么加第 2 块 BSRAM（+1 块，16 Kbit），要么把 `a0`/`a1` 分两个时钟读（破坏 1 拍读契约，tb_dds_wavetable_core 会红）⇒ 净收益 ≈ +24 dB SFDR（4 bit × 6 dB），代价 +1 BSRAM ＋ 1 个 17×4 乘法器；但 P1-5 说这个模块根本不在网表里 ⇒ 收益当前为 0。②换用 wavetable_bank 的 1024 点表（若有一天真要把 DDS 接进 top）：`phase_acc[31:22]` 取 10 bit ⇒ 相位误差减半 ⇒ +6 dB，且省 1 块 BSRAM。③什么都不做：如果确认 dds_wavetable_core 永远只是兼容/参考实现（见 P1-5 选项 C），就在头注释里写清"本模块不追求 SFDR，禁止用于交付音频通路"，并把这条列进"已知限制"。
- **预期**：① 是 +24 dB SFDR；② 是 +6 dB ＋ −1 BSRAM。⚠️ 在当前交付配置下两者都是 0（模块不在网表里）⇒ 优先级取决于 P1-5 的裁定。
- **怎么验**：①离线、可复现：写一个 20 行脚本读 rtl/w3b/rom/sine_512x16.hex，算 `max_k |32767·sin(2πk/512) − table[k]|` ⇒ 应当 ≤ 0.5（证明表精确）；再算 `max_k |32767·sin(2πk/512) − 32767·sin(2π·floor(k)/512)|` ⇒ 应当 = 201（证明误差来自相位）。②在线：用 tools/peak_count.py / sim/test_mode_fft.ps1 的既有 FFT 流程，跑一个 1 kHz 纯音看非谐波边带地板：改造前应当在 −48 dBc 附近出现杂散；加 4 bit 插值后必须下降到 −70 dBc 以下（门限 −60 dBc）。
- **来源**：ANVIL-04【P1-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-1|MOD=rtl/w3b/wavetable_bank.v
### 用 HARD_ROM_EN 参数关掉 4 块无消费者的 rom_hard（省 4 块 BSRAM）
- **位置**：rtl/w3b/oscillator_bank.v:86-87、:805-812、:845-847；rtl/top.v:4190-4191；tb/w3b/tb_wavetable_bank.sv:307-311；tb/w3b/tb_wavetable_bank_prom.sv:217-220
- **现状**：
```verilog
// rtl/w3b/oscillator_bank.v
86: parameter integer VELOCITY_BLEND_EN = 0,
87: parameter integer FIXED_BLEND_Q     = 0,
803:    wire [8:0] mix_q = (VELOCITY_BLEND_EN != 0) ? velocity_mix_q : FIXED_BLEND_Q_W;
805:    wire signed [WT_W:0] blend_delta = {rom_hard[WT_W-1], rom_hard}
806:                                     - {rom_soft[WT_W-1], rom_soft};
807:    wire signed [WT_W+9:0] blend_product = blend_delta * $signed({1'b0, mix_q});
810:    wire signed [WT_W:0] blend_scaled = blend_product[WT_W+8:8];
811:    wire signed [WT_W:0] blend_sum = {rom_soft[WT_W-1], rom_soft} + blend_scaled;
845:    wire signed [WT_W-1:0] rom_dout = test_mode_i ? rom_test
846:                                                  : (resp_drum_q ? rom_noise : blend_sum[WT_W-1:0]);
// rtl/top.v:4190-4191
.VELOCITY_BLEND_EN(0),
.FIXED_BLEND_Q (0),
```
- **为什么是问题**：`VELOCITY_BLEND_EN = 0` ⇒ `mix_q = FIXED_BLEND_Q_W = FIXED_BLEND_Q = 9'd0`（常量）⇒ `blend_product = blend_delta × 0 = 0` ⇒ `blend_scaled = 0` ⇒ `blend_sum = {rom_soft[15], rom_soft}` ⇒ **rom_hard 没有任何消费者**。Gowin 不会删掉已例化的 pROM 原语（`defparam INIT_RAM_*` 是物理配置）⇒ rpt.txt 实测 `--pROM | 10` = soft×4 ＋ **hard×4** ＋ test ＋ noise。功耗折算：BSRAM 总 64.634 mW / 33 块 ⇒ 每块均摊 1.96 mW ⇒ 4 块死的 hard ROM ≈ **7.84 mW**（≈ 总功耗 204.092 mW 的 **3.8%**）—— 这是按块数均摊的估算，工具不提供实例级分解。
- **改法**：
```verilog
// wavetable_bank 加一个参数，默认关掉 hard 表
parameter integer HARD_ROM_EN = 0,
...
generate if (HARD_ROM_EN) begin : g_hard
    pROM rom_hard_t0_inst ( ... );   // 4 块
end else begin : g_hard_off
    assign rom_hard_t0_inst_do = 16'sd0;   // 4 个常量 0
end endgenerate
```
⚠️ 代价：tb_wavetable_bank.sv:307-311 与 tb_wavetable_bank_prom.sv:217-220 的 `read_and_check(..., want_hard)` 8 条判据会红 ⇒ 必须把 hard 期望值改成"仅在 `HARD_ROM_EN=1` 时检查"，这是判据改动、要写明理由（同 T3 的先例）。更小的改法：只在 top.v 侧不做任何事，而在 wavetable_bank 的例化里传 `.HARD_ROM_EN(0)`，并让 oscillator_bank 的 `blend_delta` 走 `` `ifdef ``/参数分支 ⇒ 两处联动。
- **预期**：**−4 块 BSRAM（BSRAM 33→29，28%→24.6%）· 估算 −7.8 mW**。**不是时序收益。**
- **怎么验**：①PnR：rpt.txt 的 `--pROM` 必须 **10 → 6**；②Gowin2026.power.html 的 BSRAM 行必须下降（A/B 相对比较）；③非空洞性：把 `HARD_ROM_EN` 置 1 再跑一遍，`pROM` 必须回到 10 ⇒ 证明这个参数真的在控制物理资源，不是装饰。
- **来源**：ANVIL-04【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-2|MOD=rtl/w3b/wavetable_bank.v
### 删掉装饰参数 TIMBRE_N / SAMPLE_W 或让自检真能红
- **位置**：rtl/w3b/wavetable_bank.v:17-20、:851-852、:805；例化点 rtl/w3b/oscillator_bank.v:849-852、tb/w3b/tb_wavetable_bank.sv:170、tb/w3b/tb_wavetable_bank_prom.sv:186、tb/w3b/tb_akwf_wavetables.sv:23、tb/w3b/tb_wavetable_timbres.sv:25
- **现状**：
```verilog
17:    parameter integer TIMBRE_N = 4,
18:    parameter integer TIMBRE_W = 2,
19:    parameter integer DEPTH = 1024,
20:    parameter integer SAMPLE_W = 16
851:        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
852:            (DEPTH != 1024) || (SAMPLE_W != 16))
```
- **为什么是问题**：全文引用次数：`TIMBRE_N` = **2**（:17 声明 ＋ :851 自检）；`SAMPLE_W` = **2**（:20 ＋ :852）；`DEPTH` = **3**（:19、:26 的 `$clog2`、:852）；`TIMBRE_W` = **4**（:18、:25、:805、:851）。端口 `sample_soft_o/hard_o/test_o/noise_o` 的宽度是 `[SAMPLE_W-1:0]`，但内部的 `rom_soft_sel`/`rom_*_do` 全部是写死的 `[15:0]` ⇒ `SAMPLE_W ≠ 16` 时端口宽度会变、内部仍是 16 bit ⇒ 静默位宽不匹配（iverilog 会给 warning）。`TIMBRE_N` 完全没有功能作用：case 的分支数由 `TIMBRE_W` 和写死的 `2'd0/1/2` 决定，与 `TIMBRE_N` 无关。
- **改法**：二选一。A（推荐）：删掉 `TIMBRE_N` 与 `SAMPLE_W` 两个参数（外部 5 个例化点都用默认值 ⇒ 删了零影响），并把内部 `[15:0]` 统一改成 `[SAMPLE_W-1:0]`（若保留 SAMPLE_W）。B：保留参数但把 :851-853 的自检改成 `$fatal`（同 P0-1），让它真的守住契约。
- **预期**：消除"改了参数却什么都没发生"的错觉。**零面积、零时序。**
- **怎么验**：删掉参数后 5 个例化点必须编译通过（`iverilog -Wall` 0 error）；再故意传 `.SAMPLE_W(12)` ⇒ 必须编译报错（而不是静默跑）。
- **来源**：ANVIL-04【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-3|MOD=rtl/w3b/wavetable_bank.v
### 给 timbre_i 加显式 Z 兜底，统一仿真与硅片的默认音色
- **位置**：rtl/w3b/wavetable_bank.v:808-815；对照 rtl/w3b/oscillator_bank.v:699-707；例化点 rtl/w3b/oscillator_bank.v:856、tb/w3b/tb_wavetable_bank.sv:172、tb/w3b/tb_wavetable_bank_prom.sv:188、tb/w3b/tb_akwf_wavetables.sv:25、tb/w3b/tb_wavetable_timbres.sv:27
- **现状**：
```verilog
808:    always @(*) begin
809:        case (timbre_q)
810:            2'd0: begin rom_soft_sel = rom_soft_t0_inst_do; rom_hard_sel = rom_hard_t0_inst_do; end
811:            2'd1: begin rom_soft_sel = rom_soft_t1_inst_do; rom_hard_sel = rom_hard_t1_inst_do; end
812:            2'd2: begin rom_soft_sel = rom_soft_t2_inst_do; rom_hard_sel = rom_hard_t2_inst_do; end
813:            default: begin rom_soft_sel = rom_soft_t3_inst_do; rom_hard_sel = rom_hard_t3_inst_do; end
814:        endcase
815:    end
```
- **为什么是问题**：`case`（不是 `casez`）对 `2'bzz`：`2'd0/1/2` 都不匹配 ⇒ 落 `default` ⇒ 选 t3 = PAD。硅片：oscillator_bank 若某天忘了接 `.timbre_i(...)`，综合器把该输入 tie 到 0 ⇒ `timbre_q = 2'd0` ⇒ 选 t0 = BASS。⇒ **仿真给 PAD、上板给 BASS**，且两条路都不报错。这正是本项目已经踩过的坑的同族：oscillator_bank.v:699-707 的 `voice_drum_i` 悬空 = z ⇒ 用 `=== 1'b1` 兜底，注释原文"🔴 若直接拿 z 当三目选择端 ⇒ `rom_dout` 变成 x ⇒ 所有老用例集体假红"。现状：当前 5 个例化点全部接了 `timbre_i` ⇒ 今天不发作，这是潜伏项。
- **改法**（与 `voice_drum_i` 完全同构）：
```verilog
wire timbre_valid = (timbre_i === 2'b00) || (timbre_i === 2'b01) ||
                    (timbre_i === 2'b10) || (timbre_i === 2'b11);
wire [TIMBRE_W-1:0] timbre_safe = timbre_valid ? timbre_i : {TIMBRE_W{1'b0}};
...
if (rd_en_i) timbre_q <= timbre_safe;
```
成本 4 个 2 bit 全等比较器（≈8 LUT）；收益：悬空 ⇒ 仿真和硅片都给 t0（BASS），行为一致且显式。
- **预期**：消除"仿真 PAD / 上板 BASS"的分叉；代价 ≈8 LUT。
- **怎么验**：写一个只接 `clk_i/rst_n_i/rd_en_i/addr_i` 的探针 tb（不接 `timbre_i`），断言 `sample_soft_o` 等于 t0 的表（373）—— 改造前会得到 t3 的值（917）⇒ 判据红。
- **来源**：ANVIL-04【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-4|MOD=rtl/w3b/oscillator_bank.v
### 给 test 表选择加一个与 ROM 数据同拍的标签，消除切档那一帧混表
- **位置**：rtl/w3b/wavetable_bank.v:827-828、:830、:837；rtl/w3b/oscillator_bank.v:845-847、:787-794；rtl/top.v
- **现状**：
```verilog
// wavetable_bank.v
827:    assign sample_soft_o = rom_soft_sel;      // ← 走 timbre_q mux（寄存选择）
828:    assign sample_hard_o = rom_hard_sel;
830:    assign sample_test_o = rom_test_sine_inst_do;   // ← 【绕过】mux
837:    assign sample_noise_o = rom_noise_inst_do;      // ← 【绕过】mux
// oscillator_bank.v
845:    wire signed [WT_W-1:0] rom_dout = test_mode_i ? rom_test          // ← 未寄存
846:                                                  : (resp_drum_q ? rom_noise   // ← 寄存 ✅
847:                                                                 : blend_sum[WT_W-1:0]);
```
- **为什么是问题**：`resp_drum_q` 是与 ROM 数据同拍的寄存标签（oscillator_bank.v:787-794），所以鼓表切换帧对齐。`test_mode_i` 没有对应的寄存器标签 ⇒ 它在 TDM 帧的任意一拍变化时，该帧里 `cnt < k` 的 lane 取正弦表、`cnt ≥ k` 的 lane 取音色表 ⇒ **一帧（64 个 lane）里混两张表**。一帧 = 1/48828 s ≈ **20.5 µs**，混表 ⇒ 一次宽带咔哒。触发条件：`test_mode_i` 由顶层模式切换驱动，只要在音频播放中切档就会发生（概率 = 切档发生在 64 拍窗口内的概率 = **64/1024 = 6.25%**）。
- **改法**（照抄 `resp_drum_q` 的写法，零风险）：
```verilog
reg resp_test_q;
always @(posedge clk_i) begin
    if (!rst_n_i)         resp_test_q <= 1'b0;
    else if (req_active)  resp_test_q <= test_mode_i;
end
wire signed [WT_W-1:0] rom_dout = resp_test_q ? rom_test
                                              : (resp_drum_q ? rom_noise
                                                             : blend_sum[WT_W-1:0]);
```
成本 **+1 FF**；收益：切档帧对齐，杂音从"每次切档 6.25% 概率一次咔哒"降到 **0**。
- **预期**：消除换档那一帧的混表咔哒；代价 +1 FF。⚠️ 需同步 tb/models/oscillator_bank_ref.v（`osc_sample_bus_o` 的逐位值在切档那一帧会变 ⇒ tb_p5_osc_equiv 的 E 段（test 档 20 帧）必须同步更新参考，否则会红）。
- **怎么验**：①`sim\tb_all.ps1 -Filter wavetable` / `-Filter oscillator` 全 PASS；②非空洞性：把 `resp_test_q` 故意换成 `test_mode_i`（即改回旧写法），写一个 tb 在帧中间（`cnt == 32`）翻转 `test_mode_i`，断言该帧的 `osc_sample_bus_o` 的 64 个 lane 全部来自同一张表 ⇒ 旧写法必须红（帧内混表），新写法绿。
- **来源**：ANVIL-04【P2-4】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-5|MOD=tb/w3b/tb_p5_osc_equiv.sv
### 把逐位等价 tb 的参数集改成 top.v 的交付值
- **位置**：tb/w3b/tb_p5_osc_equiv.sv:59-68 vs rtl/top.v:4204-4205
- **现状**：
```verilog
// tb/w3b/tb_p5_osc_equiv.sv:59-68
oscillator_bank_ref #(
    ... .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
    .DETUNE_ON(1), .DETUNE_SH(9),
    .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(8),
    .DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(2),
    .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(15_000_000),      // ← 15M / 2
    .DRUM_CLICK_EN(0)
) u_ref ( ... );
// rtl/top.v:4204-4205（交付配置）
.DRUM_TOM_MAX     (20_000_000),      // ← 20M
.DRUM_TOM_SWEEP_SH(3),               // ← 3
```
- **为什么是问题**：等价 tb 用的是 `DRUM_TOM_MAX=15_000_000` / `DRUM_TOM_SWEEP_SH=2` ⇒ 嗵鼓档上界 **167.6 Hz**、扫频深度 1/4；交付是 `20_000_000` / `3` ⇒ 上界 **223.3 Hz**、深度 1/8 ⇒ `[167.6, 223.3) Hz` 这一段在交付里被判成"嗵鼓"，在等价 tb 里被判成"军鼓/踩镲" ⇒ **一个完整的参数分区在等价判据里是空的** ⇒ 若有人改 oscillator_bank 的鼓分档/扫频逻辑，只要只在 20M/3 区间出错，tb_p5_osc_equiv 照样 0 mismatch 绿，四道门的第②道门形同虚设。这是 C83（探针假绿）的参数维度版本。
- **改法**：A（推荐）：把 tb_p5_osc_equiv.sv:59-68 的参数逐项改成 top.v 的交付值（`DRUM_TOM_MAX=20_000_000`、`DRUM_TOM_SWEEP_SH=3`，并核对 `DRUM_KICK_MAX`/`DRUM_SWEEP_SH`/`DRUM_SWEEP_LSB_SH`/`DETUNE_SH`）；⚠️ 改完必须重跑，且必须确认参考副本 oscillator_bank_ref.v 支持这些参数（它是改动前的实现，参数列表可能不全 ⇒ 可能需要给参考副本补参数默认值）。B（更强）：参数化成两套配置各跑 320 帧（交付档 ＋ 边界档）。
- **预期**：让第②道门真的覆盖交付配置。**零面积、零时序。**
- **怎么验**：做 A 后，故意把 oscillator_bank 的 `DRUM_TOM_MAX` 比较写成 `> 20_000_001`（只影响交付档）⇒ tb_p5_osc_equiv 必须变红；改造前不会红（这就是"能红"的证明）。
- **来源**：ANVIL-04【P2-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-6|MOD=rtl/w3b/wavetable_bank.v
### 把生产 RTL 里的 initial 自检改成 $fatal（综合会静默丢弃 initial）
- **位置**：rtl/w3b/wavetable_bank.v:850-854；rtl/w3b/oscillator_bank.v:902-926；impl/gwsynthesis/Gowin2026.log（:170 附近）；tb/models/prom_model.sv
- **现状**：
```verilog
850:    initial begin
851:        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
852:            (DEPTH != 1024) || (SAMPLE_W != 16))
853:            $display("ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");
854:    end
```
- **为什么是问题**：impl/gwsynthesis/Gowin2026.log 里 wavetable_bank 段（:170 附近）**0 条 warning / 0 条 error**，而同一个日志对 note_manager.v / oscillator_bank.v 都给了 `WARN (EX3791) Expression size ... truncated` ⇒ Gowin 既没实现也没警告，直接丢弃了这个 initial 块。同一份文件里的 oscillator_bank.v:902-926 有 5 个同类自检（`LANES>1024`、`TIMBRE_OK`、`DRUM_KICK_MAX` 截断…）—— 全部同一个命运。项目里已有正确的反例：tb/models/prom_model.sv 用 initial 做仿真专用初始化（那是合法的，因为它是 tb 模型），但生产 RTL 里的 initial 自检既拦不住综合也拦不住回归（见 P0-1 第 2/3 点）。
- **改法**（三选一，推荐 A）：A · 改成 `$fatal` ＋ 在回归里能红（同 P0-1）：`$fatal(1, "ERROR ...")` ⇒ vvp 退出码非零 ⇒ sim/tb_all.ps1:348 判失败（这是唯一真正"能红"的写法）。B · 生成期检查：把契约写进 tools/gen_t31b_wavetable.py（表生成脚本本来就知道 4×1024×16）⇒ 生成阶段就断言。C · 综合期检查：用 `` `ifdef `` ＋ `$error`（Gowin 支持 `$error` 在 elaboration 期报错）—— ⚠️ 需要先验证 Gowin 对 `$error` 的支持，否则又是"看起来能红其实不能"。
- **预期**：把"参数写错没人拦"变成"参数写错编译不过"。**零面积。**
- **怎么验**：把 :851 的条件改成永真（`if (1)`）＋ `$fatal` ⇒ `sim\tb_all.ps1 -Filter wavetable` 必须报 `FAIL:` 且汇总不是"通过 N / 共 N"。
- **来源**：ANVIL-04【P2-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-04|ORIG=P2-7|MOD=constr/top.cst,rtl/w3b/wavetable_bank.v
### 把 10 块 pROM 约束到同一 region，压掉跨 region 长线风险
- **位置**：rtl/w3b/wavetable_bank.v:60/:135/:210/:285/:360/:435/:510/:585/:660/:735（AD）、:58/:133/…/:733（CE）、:59/:134/…/:734（RESET）；constr/top.sdc:54-55
- **现状**：
```
同一条 addr_i[9:0] 驱动 10 × 10 = 100 个 AD 位（每块只有 AD[13:4] 有效，AD[3:0] 被 tie 0）
同一条 rd_en_i 驱动 10 个 CE ＋ valid_o FF ＋ timbre_q FF 的使能 = 12 个负载
同一条 ~rst_n_i 驱动 10 个 RESET ＋ 2 个 FF 的复位 = 12 个负载
```
- **为什么是问题**：GW5AT-60B 的 BSRAM 按 region 分布；10 块 BSRAM 若被布局器撒到不同 region，这 3 条网就变成跨 region 长线，其延迟会直接吃掉 `set_max_delay 18.181` 的预算。由于 R-1 说这条锥当前不在 top-50 关键路径里，所以今天没发作 —— 但它是布局运气：同源重跑差 2~3 MHz（constr/top.sdc:54-55）说明布局器的自由度很大，10 块 BSRAM 的相对位置没有任何约束。
- **改法**：A · 加布局约束（零 RTL 改动）：在 constr/top.cst / 综合属性里把 10 块 pROM 约束到同一个 region（Gowin 用 `INS_LOC`/`REGION` 属性；⚠️ 必须先查本机 Gowin 版本的属性语法，build_cli.tcl 里可能有先例）。B · 合并表结构（改动大）：把 soft/hard 对合成 2048×16 的单块（`AD[10]` 选档），⛔ 但 soft 与 hard 必须同拍可用（`blend_delta` 同时要两者）⇒ B 不可行，除非同时关掉 `VELOCITY_BLEND_EN`（那正是 P2-1 的路线）⇒ P2-1 ＋ B 一起做：关掉 blend ⇒ 每音色只剩 1 张表 ⇒ 4 块 BSRAM（1024×16 每块，没法再合），总 pROM 从 10 → **6**。C · 门控 CE（P1-3）后，CE 网从 1 条变成 4 条，每条 2 个负载 ⇒ 跨 region 风险反而下降（每条更短），这是 P1-3 的附带收益。
- **预期**：A 是抗布局噪声（不提升期望值，但降低方差）；C 是降低长线风险。都无法量化成 Fmax 提升（因为当前不在关键路径）。
- **怎么验**：①做 A 后看 impl/pnr/Gowin2026.rpt.html 的 Clock Region 分布，10 块 pROM 必须落在同一 region；②A/B 实测：同一份 RTL 连跑 2 次 PnR 比较 Fmax —— 若加了约束后方差从 2~3 MHz 收敛到 <1 MHz，则 A 有效（⚠️ 这是唯一能证明"布局运气"的判据，必须跑 A/B/A/B 至少 4 次）。
- **来源**：ANVIL-04【P2-7】
@@@END
@@@PRIO=P3|SRC=ANVIL-04|ORIG=P3-1|MOD=rtl/w3b/wavetable_bank.v
### 把 wavetable_bank 内部线/寄存器统一声明为 signed
- **位置**：rtl/w3b/wavetable_bank.v:33-52（20 根 `wire [15:0]`）、:805-807（`reg [15:0]`）、:827-828（assign 到 `output wire signed [15:0]`）；对照 rtl/w3b/oscillator_bank.v:754-755、:805-806
- **现状**：
```
内部 rom_*_do / rom_soft_sel 全部是 unsigned 的 wire [15:0] / reg [15:0]，
端口是 output wire signed [15:0]；oscillator_bank.v:805-806 的 {rom_hard[WT_W-1], rom_hard} 依赖端口的 signed 语义
```
- **为什么是问题**：等宽（16 → 16）赋值只是位拷贝，signedness 不参与 ⇒ 今天零影响。但 oscillator_bank.v:805-806 的 `{rom_hard[WT_W-1], rom_hard}` 依赖端口的 signed 语义（`wire signed [WT_W-1:0] rom_hard`，oscillator_bank.v:754-755）—— 这个是正确的。风险在未来：若 `WT_W` 改成 17/18（为混音留 headroom），内部 `[15:0]` 的 unsigned 声明会让 `{rom_hard[16], rom_hard}` 这类扩展静默零扩展。
- **改法**：把内部线/寄存器统一声明为 `signed`（或统一用 `wire signed [SAMPLE_W-1:0]`）。
- **预期**：零面积、零时序，纯防错。
- **怎么验**：把 `SAMPLE_W` 改成 17 并跑一个 tb ⇒ 改造前会出现正半周正确、负半周被抬成正值（零扩展）⇒ 明显红。
- **来源**：ANVIL-04【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-04|ORIG=P3-2|MOD=rtl/w3b/dds_wavetable_core.v
### 给 dds_wavetable_core 补 default_nettype none 成对写法
- **位置**：rtl/w3b/dds_wavetable_core.v:1-15；反例 rtl/w3b/wavetable_bank.v:15、:856
- **现状**：
```
wavetable_bank 用 `default_nettype none ＋ 结尾 `default_nettype wire（正确的成对写法）
dds_wavetable_core 两个都没有
```
- **为什么是问题**：端口名拼错（例如把 `.phase_inc_i` 写成 `.phase_in_i`）会静默生成一个隐式 1 bit 线网（Verilog-2001 隐式线网规则），iverilog `-Wall` 只会给一条 warning，回归不会红。
- **改法**：照抄 wavetable_bank.v:15 与 :856 的两行。
- **预期**：零面积，把"拼错端口"从静默变成编译错误。
- **怎么验**：加完之后，故意把 `.ad(phase_acc[31:23])` 写成 `.addr(...)` ⇒ 必须编译报错（而不是静默）。
- **来源**：ANVIL-04【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-04|ORIG=P3-3|MOD=rtl/w3b/wavetable_bank.v
### 把 10 处 OCE(1'b1) 改成与 CE 同源
- **位置**：rtl/w3b/wavetable_bank.v:57/:132/…/:732（10 处）；rtl/w3b/dds_wavetable_core.v:39；tb/models/prom_model.sv:173、:176-185；rtl/w3b/wavetable_bank.v:817-826
- **现状**：
```verilog
173:    assign DO = (READ_MODE == 1'b0) ? bp_reg : pl_reg;
181:            if (OCE) pl_reg <= bp_reg;          // ← OCE 只控制 pipeline 级
183:            if (CE)  bp_reg <= {16'd0, memory[AD[13:4]]};   // ← bypass 级由 CE 控制
```
- **为什么是问题**：`READ_MODE=0` ⇒ `DO = bp_reg`，`OCE` 完全不参与 ⇒ 10 个 `OCE(1'b1)` 常量是装饰（Gowin 会 tie 掉，不占资源）。⚠️ 但真实 Gowin 原语在 `READ_MODE=0` 时 OCE 的行为官方文档没有明说，模型是项目自己写的；若某天把 `READ_MODE` 改成 1，`OCE(1'b1)` 会让 pipeline 级永远使能 ⇒ 变成"无条件 2 拍"，而 `timbre_q` 仍是 1 拍 ⇒ **车道错位**（正是 wavetable_bank.v:817-826 注释警告的 K-167 前科）。
- **改法**：把 `OCE` 从 `1'b1` 改成与 `CE` 同源（`OCE(rd_en_i)`）⇒ 无论 `READ_MODE` 怎么改，两级寄存器的使能永远一致；成本 **0**（只是把常量换成已有的 `rd_en_i`，扇出 +10）。
- **预期**：消除"改 READ_MODE 就车道错位"的雷；代价 0。
- **怎么验**：把 `READ_MODE` 改成 1（两级延迟）⇒ tb_wavetable_bank.sv:290 的 `valid_o !== 1'b1` 必须红（因为数据晚了 1 拍）；改造前也红（`OCE=1'b1` 时 pipeline 级无条件更新）—— 所以这条的"能红"是：改 `READ_MODE=1` 时必须红，这证明"1 拍读契约"这个判据是活的。
- **来源**：ANVIL-04【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-04|ORIG=P3-4|MOD=rtl/w3b/oscillator_bank.v,rtl/w3b/wavetable_bank.v
### 改掉"固定 rom_hard"的互斥注释（代码真值是 rom_soft，两张表都是满幅）
- **位置**：rtl/w3b/oscillator_bank.v:814、:817-820、:819-820、:832；rtl/w3b/wavetable_bank.v:817-826
- **现状**：
```verilog
// 位置 A：rtl/w3b/wavetable_bank.v:817-826 ✅ 与代码/模型一致（prom_model.sv:168-173）—— 不需要改
// 位置 B（真正的冲突）：rtl/w3b/oscillator_bank.v
814:    //   ⭐ `VEL_TIMBRE_BLEND = 0`（默认）⇒ ⭐ **固定 `rom_hard`**（⭐ 音色只由 `timbre` 决定）✅
817:    //  ⚠️⚠️ 2026-09-29 上板实测修正：⭐ **固定用 `rom_hard`，⛔ 不是 `rom_soft`**
832:    //   ⭐ `FIXED_BLEND_Q = 0` ⇒ ⭐ `blend_sum = rom_soft` ⇒ ⭐ 用 **AKWF 的 soft 表**（⭐ 平滑档 ✅）
```
- **为什么是问题**：代码实际是哪个：`FIXED_BLEND_Q = 0` ⇒ `mix_q = 0` ⇒ `blend_product = 0` ⇒ `blend_sum = {rom_soft[15], rom_soft}` ⇒ `rom_dout = blend_sum[15:0] = rom_soft` ⇒ 🔴 **实际交付走 rom_soft**，:814 / :817-820 的"固定 rom_hard"是错的，:832 才是对的（这与项目已知问题③ tdm_render_mixer.v 注释三项全错同一家族）。⚠️ 附带：:819-820 说 rom_soft 是"峰值 16384、音量砍半"的旧表 —— 也不成立：`rom_soft_t0` 的 `INIT_RAM_10 = 256'h7FD3…` ⇒ 峰值 **32723**，`rom_hard_t0` 的 `INIT_RAM_10 = 256'h7F69…` ⇒ 峰值 **32617**，两张都是满幅。
- **改法**：删掉 oscillator_bank.v:814 与 :817-820 的"固定 rom_hard"结论，统一写成"默认 `FIXED_BLEND_Q=0` ⇒ 走 rom_soft（AKWF soft 档），两张表都是满幅"。
- **预期**：零面积。但这条会误导后续优化（例如有人按注释去"修"表选择）。
- **怎么验**：写一个 tb 设 `VELOCITY_BLEND_EN=0, FIXED_BLEND_Q=0`，逐点比对 `osc_sample_bus_o` 与 rom_soft 表 ⇒ 必须逐位相等（证明代码走 soft）；再与 rom_hard 比 ⇒ 必须不等（证明注释错）。
- **来源**：ANVIL-04【P3-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-04|ORIG=P3-5|MOD=rtl/w3b/wavetable_bank.v
### 保留 10 根 rom_*_inst_dout_w 死线（⛔ 不要清理）
- **位置**：rtl/w3b/wavetable_bank.v:34、:39、:44、:49、:50、:52、:55、:130、…、:655、:730；对照 ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:20、:26；tb/models/prom_model.sv:184
- **现状**：
```verilog
.DO({rom_soft_t0_inst_dout_w[15:0], rom_soft_t0_inst_do[15:0]})
```
- **为什么是问题**：`DO` 是 32 bit，但 `BIT_WIDTH=16` ⇒ 只有低 16 bit 是数据；`*_dout_w` 这 10 根线只出现在拼接里，从不被读。✅ 这不是 bug（Gowin 官方生成器也这么写，见 ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:20、:26），且 DO 高 16 bit 在真实原语里是 don't-care（模型 prom_model.sv:184 补 0）⇒ 保留即可，⛔ 不要"清理" —— 删掉会让拼接变成 16 bit，与 32 bit 的 DO 端口宽度不匹配（iverilog 会给 warning，且与官方模板不一致）。
- **改法**：不改（列为"已知无害"）。
- **预期**：避免一次"清理"引入的端口宽度不匹配与官方模板偏离。
- **怎么验**：`-Filter wavetable` 全绿；且 `grep 'rom_soft_t0_inst_dout_w'` 仍只在拼接处出现。
- **来源**：ANVIL-04【P3-5】
@@@END
@@@TOTAL SRC=ANVIL-04 COUNT=19 P0=1 P1=6 P2=7 P3=5
