@@@PRIO=P0|SRC=ANVIL-12|ORIG=P0-01|MOD=rtl/hdmi/hdmi_scope.v,rtl/hdmi/tmds_serializer.v,rtl/top.v,constr/top.sdc
### 把 HDMI 域复位改成域内同步产生，消掉跨域异步复位
- **位置**：rtl/hdmi/hdmi_scope.v:17-22、:37-38、:9-22；rtl/hdmi/tmds_serializer.v:22-28、:27；rtl/top.v:1228-1232、:510-515；constr/top.sdc:88-90、:102；rtl/hdmi/video_timing.v:23；rtl/hdmi/tmds_encoder.v:56；rtl/hdmi/waveform_scope.v:40、:55/83/102/116；rtl/rst_sync.v:39；rtl/sync_input.v:45；impl/pnr/Gowin2026_tr_content.html（Recovery/Removal 表）
- **现状**：
```verilog
// rtl/hdmi/hdmi_scope.v:17-22（跨域异步复位 #1）
17:     hdmi_clk u_clk (.clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
18:         .serial_clk(serial_clk), .lock(lock));
19:     always @(posedge pixel_clk or negedge rst_n) begin
20:         if (!rst_n) reset_pipe <= 0;
21:         else reset_pipe <= {reset_pipe[0], lock};
22:     end
// :37-38（跨域异步复位 #2，送进 OSER10）
37:     tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
38:         .rst(!rst_n), .blue(blue), .green(green), .red(red),
// rtl/hdmi/tmds_serializer.v:22-28（.RESET 落在 125 MHz 的 FCLK 硬宏上）
27:             .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst)
// rtl/top.v:1228-1232（rst_n 的真实来源 = clk_sys 域的 rst_n_sync）
1228:     hdmi_scope u_hdmi (.clk(clk), .rst_n(rst_n_sync),
// rtl/top.v:510-515
510:     wire rst_n_sync;
511:     rst_sync #(.STAGES(2)) u_rst_sync (.clk(clk), .rst_n_async(rst_n), .rst_n_sync(rst_n_sync));
```
- **为什么是问题**：①存在性是结构性的、可穷举证明。9 个模块里每一处复位都列了出来，只有 2 处是「异步复位 + 跨域」：`hdmi_scope.v:19`（`posedge pixel_clk or negedge rst_n`，clk_sys → pixel_clk）🔴；`hdmi_scope.v:38` → `tmds_serializer.v:27`（OSER10 `.RESET`，clk_sys → pixel_clk ＋ serial_clk）🔴；其余（video_timing.v:23、tmds_encoder.v:56、waveform_scope.v:40/:55/:83/:102/:116、clk_gen.v:78/95、rst_sync.v:39、sync_input.v:45）全部同域 ✅。⇒ 全设计最薄的三条余量正好就是上表前两行：Removal #1 slack **+0.335** `u_rst_sync/sync_chain_1_s0/Q → u_hdmi/u_serializer/lanes[3].u_oser/RESET`（Launch clk_sys:[R] Latch pixel_clk:[R]，路径明细 tC2Q 0.130 ns ＋ tNET 0.991 ns，fanout **13958**，R73C54[0][A] → IOR24[A]）；Removal #5 slack **+0.520** 同源 → `u_hdmi/reset_pipe_1_s0/CLEAR`；Recovery #1 slack **+1.032** 同源 → 同一 OSER10/RESET（Launch clk_sys:[R] Latch serial_clk:[R]（4 ns 周期），tC2Q 0.331 ns ＋ tNET 2.465 ns，同一根 fanout 13958 的网）。②为什么是布局运气而不是结构性长路径（本条最重要的判断）：最差 removal 的整条数据路径只有 **1.121 ns**（tC2Q 0.130 ＋ tNET 0.991），而报告明细给的需求时刻 = **42.971 ns**（活动时钟沿 40.000 ns ＋ 时钟路径）、到达时刻 = **43.307 ns** ⇒ 两者只差 0.336 ns；⚠️ 这是 removal（异步复位的"保持"），它的需求里**不含 18.181 ns 的预算** ⇒ `set_max_delay` 保护不了它。也就是说它不是一条长组合路径，而是一条"把 `rst_n_sync` 从 R73C54 拉到芯片右侧 I/O 环 IOR24"的广播网：终点 OSER10 是硬宏、位置被 TMDS 引脚锁死在右边缘（constr/top.cst:496-506：J14/J15/K17/G15）；起点 `sync_chain_1_s0` 由布局器自由摆放（当前 R73C54）⇒ slack 只取决于"布局器这次把 rst_n_sync 放哪"：布线从 0.991 ns 变成 1.33 ns 就翻负。本项目同源重跑差 2~3 MHz（在 55 MHz 处 = **0.69~1.05 ns**）—— +0.335 ns 的余量比这个噪声带小 2~3 倍 ⇒ ⭐ 结论：今天报告写 0/0 是"这一版布局的运气"，不是"设计安全"。缺陷的存在是结构性的，余量的符号是运气。③为什么现在没炸：pixel_clk/serial_clk 与 clk_sys 同源（同一 PLL、ODIV1=40/ODIV0=8），rst_n_sync 的释放沿与 pixel 沿的相对相位在这版布局里恰好让 removal 正 0.335 ns；PLL 相位、器件温度（recovery 用慢档、removal 用快档）任一变化都会动这个数。
- **改法**：把 HDMI 域的复位变成域内同步产生，让跨域异步复位从设计里消失（⛔ 不是加 false path 掩盖）：
```verilog
// hdmi_scope.v —— 替换 :9-22 的 reset_pipe 段
wire pixel_clk, serial_clk, lock;
// ① 像素域：无异步复位的同步器（只有 D 端跨域，复位本身不再跨域）
reg [2:0] rstn_pix = 3'b000;          // initial 只影响仿真；硅片 FF 上电 INIT=0
always @(posedge pixel_clk)
    rstn_pix <= {rstn_pix[1:0], (lock & rst_n)};   // rst_n 是 clk_sys 域电平，只当【数据】采
wire video_reset_n = rstn_pix[2];     // 现在它是【pixel 域 FF 的输出】
// ② 串行域：同样无异步复位；把 lock 并进来（同时解掉 P1-01）
reg [2:0] rstn_ser = 3'b000;
always @(posedge serial_clk)
    rstn_ser <= {rstn_ser[1:0], (lock & rst_n)};
wire serial_reset = ~rstn_ser[2];
// ③ OSER10 的 RESET 改由串行域驱动（替换 :38 的 .rst(!rst_n)）
tmds_serializer u_serializer (... .rst(serial_reset), ...);
```
constr/top.sdc 里给这两条新增的 D 端跨域路径（clk_sys → pixel_clk / serial_clk）加明确预算（⛔ 不用 false path）：
```
set_max_delay -from [get_regs {u_rst_sync/sync_chain_1_s0}] -to [get_regs {u_hdmi/rstn_pix_0* u_hdmi/rstn_ser_0*}] 12.000
```
（12 ns 的依据：这是准静态控制信号，只在按复位键时变一次；给 12 ns 足够宽松，又不会像 false path 那样完全放弃检查。⚠️ 语法必须先按 H5…20261002.md P8 的教训验证 —— `get_regs` 通配曾经让构建直接 TA2003 失败，所以先跑一次只改 SDC 的 PnR 看 Constraints Report 里对象非空。）⚠️ 两个必须一起处理的细节：1. `rstn_pix[0]` 的 D 端是 `lock & rst_n` 两个来源，上面那条 `-from get_regs` 只覆盖 `rst_n_sync` 这一半；另一半来自 PLL 的 LOCK 引脚（rtl/hdmi/hdmi_clk.v:43，不是寄存器）⇒ 要么再加一条 `-from [get_pins {u_hdmi/u_clk/u_pll/LOCK}]`，要么接受工具给的默认 I/O 预算；⛔ 不要用 `set_false_path` 一刀切（那会把 D 端真实的建立检查一起删掉，top.sdc:88-90 的纪律原文）。2. 这一改动会让 constr/top.sdc:88-90 那段注释（"不许用 `set_clock_groups -asynchronous` 切开 clk_sys 与 HDMI，因为会删掉 `u_rst_sync → OSER10/RESET` 的真实 recovery/removal"）失效并必须同步改写：改完之后那条路径本来就不存在了（不是被例外删掉，而是结构上没有了）⇒ 注释要改成新的理由。
- **预期**：收益 = 全设计最薄的 removal **+0.335 → 预期 ≥ +0.9**；+0.520 那条一并消失；recovery +1.032 那条消失。附带可能释放 1 条 LW 长线（`u_hdmi/reset_pipe[1]` 当前占 LW，而 LW 已 8/8 = 100%，见 P2-02）。代价（逻辑）≈ **6 FF + 6 LUT**，全部在 pixel_clk/serial_clk 域 ⇒ clk_sys 逻辑增量 0（u_hdmi 当前总占用 = 178 FF / 219 LUT / 2 BSRAM，加 6 FF 后 184 FF，+0.04% 全设计）。代价（Fmax）⭐ 预期 55.060 MHz 不变（18.181 预算里没有这些路径；setup 前 25 名无任何 HDMI 端点）。代价（风险）复位释放晚 2 拍（80 ns @25 MHz / 8 ns @125 MHz）⇒ 对视频无影响；但必须重跑全量回归（tb/models/hdmi_primitives_model.sv:36 的 OSER10 模型认 RESET 极性）。
- **怎么验**：①正向：改完跑 `sim\gowin_build.ps1`（≈10 min）⇒ 在 impl/pnr/Gowin2026_tr_content.html 的 Removal Paths Table 里搜 `u_hdmi`：改前 `#1 +0.335 u_rst_sync/sync_chain_1_s0/Q → u_hdmi/u_serializer/lanes[3].u_oser/RESET`；改后该行的 launch 必须是 `rstn_ser_*_s0`（serial 域），且 removal 表最小值 ≥ +0.9，Recovery 表里 `clk_sys → serial_clk` 的条目归零。②反向（必须能红）：把 hdmi_scope.v:38 改回 `.rst(!rst_n_sync)`（或把 rstn_ser 的第一级 D 端直接接 clk_sys 源），重跑 PnR ⇒ **+0.335 / fanout 13958 那条必须原样复现**；不复现 = 机制判断错了，必须重查。③四道门：综合 ERROR=0 → `-Filter waveform_scope`（+ `-Filter top_m0`）→ 干净 PnR 0/0 无 PR0004 → 全量回归通过数==共数。
- **来源**：ANVIL-12【P0-01】
@@@END
@@@PRIO=P0|SRC=ANVIL-12|ORIG=P0-02|MOD=rtl/hdmi/waveform_scope.v,tb/hdmi/tb_waveform_scope.sv
### 把 waveform_scope 的纵轴缩放从 1/16384 改成 1/65536，消掉 −6.58 dBFS 饱和
- **位置**：rtl/hdmi/waveform_scope.v:65-75、:70、:69、:71-72；tb/hdmi/tb_waveform_scope.sv:25-35、:42、:112、:125、:79、:83、:110-113；rtl/top.v:4492；rtl/w3c/master_mix.v:128
- **现状**：
```verilog
// rtl/hdmi/waveform_scope.v:65-75
65:     function [8:0] sample_y;
66:         input signed [23:0] s;
67:         reg signed [10:0] y_calc;
68:         begin
69:             // Signed slice is exactly s >>> 14, including negative rounding.
70:             y_calc = 11'sd240 - $signed(s[23:14]);      // ← 缩放因子 1/16384
71:             if (y_calc < 0) sample_y = 9'd0;
72:             else if (y_calc > 479) sample_y = 9'd479;
73:             else sample_y = y_calc[8:0];
74:         end
75:     endfunction
// 测试台的 oracle（tb/hdmi/tb_waveform_scope.sv:25-35）—— 与上面逐字等价
25:     function integer map_y(input integer s);
29:             if(s>=0) scaled=s/16384;
30:             else scaled=-((-s+16383)/16384);
31:             map_y=240-scaled;
32:             if(map_y<0) map_y=0;
33:             if(map_y>479) map_y=479;
35:     endfunction
```
- **为什么是问题**：饱和条件 `240 − (s >> 14) < 0` ⇒ `s > 240 × 16384 = 3 932 160`；24 位满幅 = `2^23 − 1 = 8 388 607` ⇒ **可显示上限 = 3 932 160 / 8 388 607 = 0.4688 FS = 20·log10(0.4688) = −6.58 dBFS**。满幅正弦被削平的比例：`|sin θ| > 0.4688` ⇒ θ ∈ (27.95°,152.05°) ∪ (207.95°,332.05°) ⇒ `248.2°/360° = 68.9%` 的列贴在 y=0 或 y=479 两条轨上 ⇒ 满幅正弦看起来像带圆角的方波。这个幅度范围恰好是交付信号的范围：`scope_sample` 直接接 master_mix 的输出（rtl/top.v:4492 `assign scope_sample = mm_sample;`），而 master_mix 的输出寄存器就在 rtl/w3c/master_mix.v:128，正常演奏电平在 −6 dBFS 以上是常态。⭐⭐ 最刺眼的一条：mode 4（满幅方波，tb:42）现在画出来的是「整屏纯绿」—— 满幅方波的两个电平是 +FS 与 −FS ⇒ `sample_y` 分别返回 0 与 479（都被 clamp）；而绘制规则是「本列画 `point_q ↔ segment_previous` 之间的整段垂直线」（:110-113）⇒ 相邻两列一个 0 一个 479 ⇒ 每一列都画满 0..479 ⇒ 绿色像素 = 640 × 480 = 307 200 = 满屏；测试台对此打印 `PASS: mode=4 full frame exact pixels`（:125）—— 因为它算的也是同一件事（C83 探针假绿的教科书级实例：判据不能区分"改前"和"改后" = 判据不存在）。⭐ 为什么测试台永远抓不到：tb:31-33 把 RTL 的 `240 − s/16384` 和两级 clamp 逐字抄了一遍，然后拿"抄来的模型"去比"被测的 RTL" ⇒ 它验证的是实现，不是需求。
- **改法**：
```verilog
// rtl/hdmi/waveform_scope.v:70  —— 一行
-            y_calc = 11'sd240 - $signed(s[23:14]);   // 1/16384：饱和点 0.469 FS = −6.58 dBFS
+            y_calc = 11'sd240 - $signed(s[23:16]);   // 1/65536：任何 24 位输入都不饱和
```
`$signed(s[23:16])` 是 8 位有符号切片，恰好等于 `s >>> 16`（含负数向 −∞ 取整），与 :69 的注释同一条数学。零饱和的证明：`s ∈ [−2^23, 2^23−1]` ⇒ `s>>>16 ∈ [−128, 127]` ⇒ `y_calc = 240 − that ∈ [113, 368]` ⊂ `[0, 479]` ✅ 永不进 clamp（:71-72 变成死代码，可留作保险）。位宽检查：`y_calc` 仍只需 `[−128, 368]` ⊂ 11 位有符号 `[−1024,1023]` ✅ 不用改位宽。代价：波形只占屏幕高度的 `(368−113+1)/480 = 53.3%`（±128 行），但形状 100% 忠实；对典型演奏电平（−6 dBFS 附近）仍有 ±64 行的可见幅度。替代方案（`s[23:15]`，占 94% 屏高）：饱和点抬到 `0.9375 FS = −0.56 dBFS`，但满幅正弦仍有 `22.7%` 的列贴轨 ⇒ 不变量阈值只能放宽到 25%，判据就没那么利了；本报告推荐 `s[23:16]`。同步改 oracle：tb:29-31 的 `16384 → 65536`（:31 的 240 不动）。⭐ 必须同时加一条"独立不变量"（否则修完还是假绿）：
```verilog
// tb/hdmi/tb_waveform_scope.sv
//  ① 新增一个满幅正弦激励（现有 6 个模式里没有正弦满幅）
//   case 里加:  6: stimulus=$rtoi(8388607.0*$sin(index*6.283185307179586/71.0));
// ② 统计「贴轨列」并断言（用 tb 自己的 last_y，⛔ 不引用 DUT 内部信号、⛔ 不复制 map_y 的 clamp）
if (de_o && (r==8'h00 && g==8'hff) && (last_y==0 || last_y==479)) rail_cols = rail_cols + 1;
// ③ 模式结束时：
if (mode==4)  assert (greens <= 60*640*480/100);   // 满幅方波：改前=100%（满屏），改后=53.3%
if (mode==6)  assert (rail_cols <= 5*640/100);     // 满幅正弦：改前=68.9%，改后=0%
```
（`last_y` 的语义见 :83：任务末尾把 px/py 存进 last_x/last_y，它正是"当前输出对应的那一列"。绿色像素计数已经在 :79 `greens=greens+1;` 里现成 —— 只要把它从"打印用"提升成"断言用"，改动量 = 3 行。）
- **预期**：收益 = 可显示范围 `0.469 FS → 1.00 FS`（**+6.6 dB**，永不饱和）；满幅正弦贴轨列 `68.9% → 0%`；满幅方波从「整屏纯绿 307 200 px」恢复成「两条水平线 + 竖边 = 53.3% 屏」。代价（逻辑）**0**（只是把位选从 `[23:14]` 改成 `[23:16]`，加法器位宽与 clamp 都不用动）；代价（Fmax）**0**（该函数在 pixel_clk 25 MHz 域，且不在 setup 前 25 名里）；代价（垂直分辨率）满幅只占 53% 屏高（±128 行）⇒ 若嫌小，可改成"两档显示"（默认 >>>16，满幅档 >>>15），但那要加控制位，不建议；代价（测试）必须同步改 oracle + 加不变量，否则回归会红（tb_waveform_scope 会 FAIL）—— 这是好事，说明判据是活的。
- **怎么验**：①正向：`sim\tb_all.ps1 -Filter waveform_scope` ⇒ 改完（RTL + oracle + 不变量）必须 PASS，且 green/rail 计数落在断言阈值内。②反向（两道，缺一不可）：①把 :70 改回 `[23:14]`（但 oracle 保持 65536）⇒ 必须 FAIL（证明 oracle 真的在比对）；②oracle 与 RTL 同时改回 `[23:14]`，只留新加的独立不变量 ⇒ 必须 FAIL（满幅方波 `green_total = 307 200` = 100% > 60% 阈值）⇒ 证明不变量是独立于实现的，不是抄的。⭐ 只做①不做② = 还是假绿。③四道门。
- **来源**：ANVIL-12【P0-02】
@@@END
@@@PRIO=P1|SRC=ANVIL-12|ORIG=P1-01|MOD=rtl/hdmi/hdmi_scope.v
### 让 OSER10 的 RESET 受 PLL lock 门控
- **位置**：rtl/hdmi/hdmi_scope.v:16-22、:9-11、:19-22、:38；rtl/rst_sync.v:42；rtl/hdmi/hdmi_clk.v:43；tb/models/hdmi_primitives_model.sv:36；rtl/hdmi/video_timing.v、rtl/hdmi/waveform_scope.v、rtl/hdmi/tmds_encoder.v；bringup/hdmi_640x480/H4-验证记录-20261001.md；tb/top/tb_top_m0.sv
- **现状**：
```verilog
 9:     wire pixel_clk, serial_clk, lock;
10:     reg [1:0] reset_pipe;
11:     wire video_reset_n = reset_pipe[1];
19:     always @(posedge pixel_clk or negedge rst_n) begin
20:         if (!rst_n) reset_pipe <= 0;
21:         else reset_pipe <= {reset_pipe[0], lock};      // ← lock 只在这里被用
22:     end
38:         .rst(!rst_n), .blue(blue), .green(green), .red(red),   // ← 与 lock 无关
```
- **为什么是问题**：`rst_n_sync` 在上电后 **2 个 clk_sys 周期（40 ns）** 就释放（rtl/rst_sync.v:42，纯同步器，无异步端口）⇒ `.rst(!rst_n)` 在 **40 ns** 后就变成 0。而 Gowin PLLA 从复位释放到 `LOCK=1` 是 **数十 µs~1 ms** 量级（PLL 环路锁定时间，本项目没有任何实测数字，⛔ 这里不编造具体值，只给"≫ 40 ns"这个可证的量级关系）⇒ 在这整段窗口里：`OSER10.RESET = 0`（脱离复位）、`PCLK/FCLK` 还没稳/还没起 ⇒ 10 位并串转换器的内部相位计数器在一个未定义的状态下起跑。器件手册对 OSER10 的要求是「两路时钟稳定且 RESET 保持有效直到稳定」；video_timing/waveform_scope/tmds_encoder 都靠 `video_reset_n`（含 lock）保住了，只有 OSER10 漏了。
- **改法**：见 P0-01 的②③（同一个文件、同一次改动；`lock` 并进 `rstn_ser` 的 D 端）。最小改动版（如果只想解本条、不动 CDC）：rtl/hdmi/hdmi_scope.v:38 `.rst(~video_reset_n)`；⚠️ 但这个最小版会把 OSER10 的 RESET 变成 pixel_clk 驱动 ⇒ 制造 `pixel_clk → serial_clk` 的新跨域（H5…20261002.md §1.4-1 实测过：`pixel_clk → serial_clk` setup **−0.516 ns**）⇒ ⭐ 必须按 P0-01 的串行域同步器做，不要图省事。
- **预期**：收益 = 序列化器起跑相位确定；代价 = 已含在 P0-01 的 6 FF 里（本条不额外增加任何资源）。
- **怎么验**：tb/models/hdmi_primitives_model.sv:36 的 OSER10 模型认 RESET（`always @(posedge FCLK or negedge FCLK or posedge RESET)`）⇒ 在 tb/top/tb_top_m0.sv（或新 tb）里把 `lock` 强制为 0 保持 100 拍，断言 `dut.u_hdmi.u_serializer.lanes[0].u_oser.RESET === 1'b1` 全程成立。改前必红（40 ns 后 RESET 就变 0 了），改后绿。
- **来源**：ANVIL-12【P1-01】
@@@END
@@@PRIO=P1|SRC=ANVIL-12|ORIG=P1-02|MOD=rtl/hdmi/hdmi_scope.v
### 让 hpd_en 等 video_reset_n（先确认 K13 的板级语义）
- **位置**：rtl/hdmi/hdmi_scope.v:16；rtl/top.v:382；constr/top.cst（hpd_en 落 K13/4，DRIVE=12 PULL_UP）；impl/pnr/Gowin2026.rpt.txt:165；rtl/hdmi/README.md；tb/top/tb_top_m0.sv
- **现状**：
```verilog
16:     assign hpd_en = 1'b1;
```
- **为什么是问题**：`hpd_en` 是 HDMI 的 HPD（热插拔检测）方向控制/使能。恒 1 ⇒ ①上电瞬间（lock 还没起、pixel_clk 还没跑）源端就已经"声明在线"；②PLL 未锁期间 OSER10 的输出是未定义序列（见 P1-01），监视器会尝试去锁一个不存在的 TMDS 时钟（125 MHz 时钟道此时也没稳）⇒ 部分显示器会进入"无信号→反复重试"状态，或者锁到一个错误的时序上。这条与 P1-01 是同一个根因的两个出口（"未锁就对外宣称可用"）。
- **改法**：
```verilog
// rtl/hdmi/hdmi_scope.v:16
-    assign hpd_en = 1'b1;
+    assign hpd_en = video_reset_n;   // lock 稳定 2 个 pixel 周期后才对外声明在线
```
⚠️ 若 `hpd_en` 在硬件上其实是"5V 使能"而不是"HPD 上报"，那恒 0 会让监视器完全看不到源 —— **上板前必须先确认 K13 的板级语义**（rtl/hdmi/README.md 与 constr/top.cst 都没有写它接什么），⛔ 不确定就不要改，只记录。这是本条与 P0-01 的唯一区别：P0-01 无论如何都该改，本条要先确认板级。
- **预期**：收益 = 上电握手时序正确，消除"显示器抓未锁信号"这一类现场怪象；代价 = **0 逻辑**（video_reset_n 已经存在，hpd_en 是纯组合输出，无 FF）。风险提示：这是唯一一条可能改变板级行为的 P1，需要上板确认（一次 PnR + 一次烧写 ≈ 12 min）。
- **怎么验**：tb 里 `lock=0` 期间断言 `hpd_en === 1'b0`；改前必红。
- **来源**：ANVIL-12【P1-02】
@@@END
@@@PRIO=P1|SRC=ANVIL-12|ORIG=P1-03|MOD=tb/models/hdmi_primitives_model.sv,rtl/hdmi/hdmi_clk.v
### 把 HDMI PLL 模型的参数守卫扩到全部频率决定项并显式钉死 MDIV_FRAC_SEL
- **位置**：tb/models/hdmi_primitives_model.sv:4-27、:4-9、:19-26、:20-21；rtl/hdmi/hdmi_clk.v:29-42、:34、:30；bringup/hdmi_640x480/rtl/hdmi_clk_h4.v:29；bringup/hdmi_ref_720p/vendor/sipeed/TMDS_PLL_60HZ.v:69；C:\Gowin\Gowin_V1.9.12.03_x64\IDE\simlib\gw5a\prim_sim.v；constr/top.sdc:75-76；bringup/hdmi_640x480/H4-验证记录-20261001.md:21、:22；tb/clk_gen/tb_clk_gen_badparam.sv
- **现状**：
```verilog
 4: module PLLA #(
 5:     parameter FCLKIN="50", IDIV_SEL=1, FBDIV_SEL=1, MDIV_SEL=20,
 6:     ODIV0_SEL=8, ODIV1_SEL=40,
 7:     CLKOUT0_EN="TRUE", CLKOUT1_EN="TRUE", CLKOUT2_EN="FALSE",
19:     initial begin LOCK=0; CLKOUT0=0; CLKOUT1=0; end
20:     initial if (MDIV_SEL!=20 || ODIV0_SEL!=8 || ODIV1_SEL!=40)
21:         $fatal(1,"HDMI PLL model supports only the verified 25/125 MHz mode");
22:     always #4 CLKOUT0 = (RESET || PLLPWD) ? 0 : ~CLKOUT0;      // ← 125 MHz 硬编码
23:     always @(posedge CLKIN or posedge RESET) begin
24:         if (RESET) begin CLKOUT1<=0; LOCK<=0; end
25:         else begin CLKOUT1<=~CLKOUT1; LOCK<=!PLLPWD; end        // ← 25 MHz 硬编码
26:     end
```
- **为什么是问题**：频率由 **6 个** defparam 决定（FCLKIN · IDIV_SEL · FBDIV_SEL · MDIV_SEL · MDIV_FRAC_SEL · ODIV0/1_SEL；公式出处 H4-验证记录-20261001.md:21 `VCO = 50 × (MDIV_SEL + MDIV_FRAC_SEL/8) ∈ [700, 1400] MHz`、:22 `ODIV1_SEL = 5 × ODIV0_SEL`）。守卫只查 3 个 ⇒ 把 `IDIV_SEL` 从 1 改成 2（pixel_clk 直接变 12.5 MHz、帧率掉一半），全部 tb 依然绿（模型照旧按 #4 和 CLKIN 分频输出 125/25 MHz）。更硬的一条：rtl/hdmi/hdmi_clk.v:29-42 没有 `defparam u_pll.MDIV_FRAC_SEL = ...`，而它的同源兄弟 bringup/hdmi_640x480/rtl/hdmi_clk_h4.v:29 显式写了 `MDIV_FRAC_SEL = 3`，厂商参考 TMDS_PLL_60HZ.v:69 也显式写了 `= 0`。⭐ 想补上这一行会直接编译失败 —— 因为模型 :4-9 的参数表里没有 `MDIV_FRAC_SEL` ⇒ `defparam u_pll.MDIV_FRAC_SEL = 0;` 在 iverilog 下报 "parameter not found"，所有例化 top 的 tb 一起挂（这是"改一处必须同时改两处"的硬耦合，必须先说清楚）。当前值是对的（所以不是 bug，是隐患）：Gowin 原语默认值 `parameter MDIV_FRAC_SEL = 0; // 0~7` ⇒ VCO = 50×20 = **1000 MHz** ∈ [700,1400] ✅、CLKOUT0 = 1000/8 = 125 MHz、CLKOUT1 = 1000/40 = 25 MHz ✅ 与 constr/top.sdc:75-76 的 `-divide_by 8 -multiply_by 20` / `-divide_by 40 -multiply_by 20` 一致 ⇒ 依赖一个未写进 RTL 的原语默认值；H4 的教训正是"这一族参数写错会报 PA1019/静默给错频率"。
- **改法（两文件必须同一次改）**：
```verilog
// ① tb/models/hdmi_primitives_model.sv:4-9 —— 补参数
     parameter FCLKIN="50", IDIV_SEL=1, FBDIV_SEL=1, MDIV_SEL=20,
-    ODIV0_SEL=8, ODIV1_SEL=40,
+    ODIV0_SEL=8, ODIV1_SEL=40, MDIV_FRAC_SEL=0,
// ② 同文件 :20-21 —— 守卫扩到全部频率决定项
-    initial if (MDIV_SEL!=20 || ODIV0_SEL!=8 || ODIV1_SEL!=40)
+    initial if (IDIV_SEL!=1 || FBDIV_SEL!=1 || MDIV_SEL!=20 || MDIV_FRAC_SEL!=0
+                || ODIV0_SEL!=8 || ODIV1_SEL!=40 || FCLKIN!="50")
          $fatal(1,"HDMI PLL model supports only the verified 25/125 MHz mode");
// ③ rtl/hdmi/hdmi_clk.v:34 之后 —— 显式钉死分数分频
+    defparam u_pll.MDIV_FRAC_SEL = 0;
```
- **预期**：收益 = 频率配置从"隐式依赖默认值"变成"显式且被 tb 守卫"，一次改错立刻 $fatal；代价 = **0 逻辑**（模型不进综合；RTL 只多一行 defparam）。
- **怎么验**：把 rtl/hdmi/hdmi_clk.v:30 的 `IDIV_SEL = 1` 改成 `2` ⇒ `sim\tb_all.ps1 -Filter top_m0` 必须 `$fatal`；改前（现在的模型）必绿 —— 这就是洞的证明。
- **来源**：ANVIL-12【P1-03】
@@@END
@@@PRIO=P1|SRC=ANVIL-12|ORIG=P1-04|MOD=rtl/sync_input.v
### 给 sync_input 补 W>1 / STAGES<2 的参数自检并新建直接 tb
- **位置**：rtl/sync_input.v:31-40、:45-52、:32、:10-11；rtl/top.v:575-584、:585-589；rtl/clk_gen.v:61-75；tb/top/tb_top_m0.sv:542-543
- **现状**：
```verilog
31: module sync_input #(
32:     parameter integer W      = 1,     // 位宽（多比特请**逐位**同步后再做一致性检查）
33:     parameter integer STAGES = 2,     // 同步级数（≥2）
34:     parameter [W-1:0] RESET_VAL = {W{1'b0}}     // ← 默认 0
45:     always @(posedge clk) begin
46:         if (!rst_n) begin
47:             for (i = 0; i < STAGES; i = i + 1) chain[i] <= RESET_VAL;
48:         end else begin
49:             chain[0] <= async_in;
50:             for (i = 1; i < STAGES; i = i + 1) chain[i] <= chain[i-1];
51:         end
52:     end
// rtl/top.v:575-584（正确用法：低有效按键必须传 RESET_VAL(1'b1)）
575:     sync_input #(
576:         .W         (1),
577:         .STAGES    (2),
578:         .RESET_VAL (1'b1)
579:     ) u_timbre_btn_sync (
```
- **为什么是问题**：`RESET_VAL` 默认 0；对低有效按键（PULL_MODE=UP ⇒ 空闲 1、按下 0）默认值恰好等于「按下」。忘了传 `RESET_VAL(1'b1)` 时，复位释放后 `sync_out` 会先保持 **2 个 clk（40 ns）的 0**，再被输入拉回 1 ⇒ 即"上电白送一个 40 ns 的按下窗口"。⭐ 今天不咬人：消费方是 debounce（top.v:585-589，`ACTIVE_LOW(1)`、`DB_MS = 5`）⇒ 40 ns 的假按下要 5 ms 才成立，被过滤掉 125 000 倍。⚠️ 但它是一颗定时炸弹：任何不带去抖的消费方（例如将来直接用 sync_out 驱动一个边沿检测 FSM）会把这 40 ns 当成一次真实按键 ⇒ 上电即切音色/开节拍器，而且现象是"偶发、复现不了"。第二条：W>1 时本模块把多位放进同一条链，而模块头部 :32 自己写着"多比特请逐位同步"—— 即参数允许一个它明确说不安全的用法（多比特偏斜会产生不可能的组合，见 :10-11 的注释）。第三条（覆盖缺口）：sync_input 没有任何直接测试台 —— tb/ 下 131 个 tb_*.sv 里，sync_input 只被 top 间接例化，没有 tb/sync_input/；rst_sync 有（tb/top/tb_top_m0.sv:542-543 的判据 G："释放延后恰好 2 拍"），sync_input 没有。
- **改法**（与 clk_gen.v:61-75 的 PARAM_OK 同款，仿真是唯一能拦的地方）：
```verilog
// rtl/sync_input.v —— 紧跟 :34 之后
initial begin
    if (W > 1)
        $display("ERROR [sync_input] W=%0d>1：本模块对多比特不做一致性处理，请逐位例化（见模块头 :32）", W);
    if (STAGES < 2)
        $display("ERROR [sync_input] STAGES=%0d<2：亚稳态隔离不足", STAGES);
end
```
- **预期**：收益 = 把"未来某人按默认值例化一个低有效按键/多比特总线"这类静默错误提前到仿真启动即报；代价 = **0 逻辑**（initial 综合时被忽略，syn.log 里只有 EX3858 级别的提示）。
- **怎么验**：新建 tb/sync_input/tb_sync_input.sv（tb_all.ps1 自动发现 `tb/**/tb_*.sv`，所以加文件即自动进契约，回归的"共数"会从当前值 +1）：①例化 `sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1))`，`async_in` 恒 1；②断言「复位释放后的第一个 clk 起 `sync_out === 1'b1` 恒成立」；③反向：把 `RESET_VAL` 改成默认值（删掉 `.RESET_VAL(1'b1)`）⇒ 断言必须在前 2 拍 FAIL（40 ns 的假按下窗口）。这条断言同时把"两级同步恰好 2 拍"和"复位值必须等于空闲电平"两件事钉死。
- **来源**：ANVIL-12【P1-04】
@@@END
@@@PRIO=P2|SRC=ANVIL-12|ORIG=P2-01|MOD=rtl/clk_gen.v,tb/clk_gen/tb_clk_gen.sv
### 在 tb 里断言 frame_start 恒等于 tick_audio
- **位置**：rtl/clk_gen.v:104-109、:89、:88、:61-63；tb/clk_gen/tb_clk_gen.sv:39-40；rtl/top.v:799；rtl/w3b/voice_i2s_chain.v:47；rtl/bringup/wavetable_tone_top.v:50；rtl/w3c/i2s_tx.v:90；impl（rsc.xml）
- **现状**：
```verilog
104:            tick_audio   <= (cnt == {CW{1'b0}});                       // 帧起点
109:            frame_start  <= at_bclk_edge && (bpos == {BW{1'b0}});
```
- **为什么是问题**：可代数证明：`at_bclk_edge = (cnt[clog2(BCLK_DIV)-1:0] == 0)`（:89），`bpos = cnt >> clog2(BCLK_DIV)`（:88）⇒ `at_bclk_edge && (bpos==0)` = 「低 4 位全 0」∧「高 6 位全 0」= `cnt == 0` = `tick_audio` ⇒ ⭐ 两者逐位恒等，对任何满足 PARAM_OK（:61-63：BCLK_DIV 为 2 的幂且 ≤ CLK_PER_SAMPLE）的参数都成立。旁证：tb/clk_gen/tb_clk_gen.sv:39-40 要求 "frame_start 间隔恒 = CLK_PER_SAMPLE，且必须与 bclk_en 同拍" —— 而 bclk_en 也在 `cnt%16==0`，所以三者同拍，测试台其实一直在验同一件事。资源旁证：rsc.xml 里 `u_clk_gen Register="13"`，而 RTL 声明了 **16** 个 FF（cnt[9:0] + 6 个输出）⇒ 综合已经吃掉了 3 个（其中 mclk_en 1 个、frame_start 与 tick_audio 合并 1 个）。
- **改法**（二选一，建议选 B）：A（改端口）：删掉 `clk_gen.frame_start`，top.v:799 / rtl/w3b/voice_i2s_chain.v:47 / rtl/bringup/wavetable_tone_top.v:50 三处例化把 `.frame_start(tick_audio)`；i2s_tx.v:90 的端口保留；收益 −1 FF、−1 个比较器（≈1~2 LUT）；⚠️ 改动面 4 个文件 + tb_clk_gen 的端口列表 ⇒ 收益（0.004% LUT）远小于风险，不划算。B（不改端口，加断言）：在 tb/clk_gen/tb_clk_gen.sv 里加 `assert(frame_start === tick_audio)`；收益 = 把"这两个名字是同一个东西"变成机器可查的契约；若将来有人把 BCLK_DIV 改成不整除或加相位偏移，断言立刻红；代价 = **0**。
- **预期**：B 方案 0 代价换来机器可查的等价契约。
- **怎么验**：把 clk_gen.v:109 改成 `frame_start <= at_bclk_half && (bpos == {BW{1'b0}});` ⇒ 新断言必须 FAIL（同时 tb_clk_gen 的"与 bclk_en 同拍"检查也会红）。
- **来源**：ANVIL-12【P2-01】
@@@END
@@@PRIO=P2|SRC=ANVIL-12|ORIG=P2-02|MOD=impl/pnr/Gowin2026.rpt.txt,sim/gowin_build.ps1
### 把"LW 8/8 用满"写进构建判据
- **位置**：impl/pnr/Gowin2026.rpt.txt:97、:108-117、:110-117；sim/gowin_build.ps1；bringup/hdmi_640x480/H5…20261002.md §1.4-2、附录 B step 3
- **现状**：
```
 97: LW            | 8/8           | 100%
108: clk_d          | PRIMARY        |  TR BR BL
110: rst_n_sync     | LW             |  -
111: tick_audio     | LW             |  -
112: u_hdmi/reset_pipe[1]| LW             |  -
113: g_sound.u_calib_span/n1750_4| LW             |  -
114: g_sound.u_looper/n102894_4| LW             |  -
115: g_sound.u_looper/n104690_3| LW             |  -
116: g_sound.u_looper/pb_ax_3_8| LW             |  -
117: g_sound.u_evt_merge/pop_now| LW             |  -
```
- **为什么是问题**：器件只有 **8** 条长线资源，已经用满。这三条关键广播网占着它们：`rst_n_sync`（fanout **13958**，见 P0-01 明细）、`tick_audio`（每 1024 clk 一次的全设计使能）、`u_hdmi/reset_pipe[1]`（= video_reset_n，驱动 video_timing + waveform_scope + 3 个 tmds_encoder）⇒ 下一次任何改动只要多出一个"高扇出需要低偏斜"的网，工具就没有长线可用，只能退到通用布线（H5…20261002.md §1.4-2 记录过：通用布线一段网 **4.7 ns**）⇒ 这是下一个改动最容易踩的隐形地雷，而它现在没有任何约束/检查在看着。
- **改法（只做机械检查，不主动改布局）**：1. 把"LW 8/8"写进 sim/gowin_build.ps1 的通过判据里（现在是只看 0/0 和 Fmax）：`Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern "LW\s+\|\s+8/8"` ⇒ 命中时打印警告。2. 想真正释放一条：P0-01 的改法会让 `u_hdmi/reset_pipe[1]` 变成 `rstn_pix[2]`（扇出不变 ⇒ 不保证释放），⭐ 所以不要把"释放 LW"当成 P0-01 的收益去承诺，只能"重跑后看 rpt.txt:110-117 有没有少一行"。3. ⛔ 不要用 `CLOCK_LOC "rst_n_sync" BUFG = SR|LOGIC` —— H5…20261002.md 附录 B step 3 已实测：约束被接受但无效（仍 LW），且 Fmax 更差（50.527 → **49.671**）。
- **预期**：把"长线用满"从隐形变成每次构建可见；代价 = 一段脚本检查。
- **怎么验**：改完后 impl/pnr/Gowin2026.rpt.txt 的 LW 行；判据 = `8/8` 变成 `7/8` 或至少不新增。
- **来源**：ANVIL-12【P2-02】
@@@END
@@@PRIO=P2|SRC=ANVIL-12|ORIG=P2-03|MOD=rtl/hdmi/README.md
### 把 TMDS 串行通路的速率余量论证写进 README
- **位置**：impl/pnr/Gowin2026_tr_content.html:176；sim/evidence/final-batch-20261008/timing.txt:64-79；rtl/hdmi/README.md:48-50；bringup/hdmi_640x480/H4-验证记录-20261001.md:57、:58
- **现状**：
```
报告的 Max Frequency Summary 只有 clk_sys（timing.txt:64-79），serial_clk 一栏直接写
"No timing paths to get frequency of serial_clk!"（:176）
serial_clk 在报告里的 53 次出现全部归类：除了 8 条 recovery ＋ 8 条 removal（全部是 OSER10/RESET）之外，没有任何数据路径
```
- **为什么是问题**：⇒ **"0 违例"对 125 MHz 并串转换是「空真」**：OSER10 是硬宏，PCLK → FCLK 的 10:1 搬运在宏内部，STA 看不见。速率核算：每 lane = `25 MHz × 10 bit` = **250 Mb/s**（FCLK = 5 × PCLK = 125 MHz，DDR 每 FCLK 周期 2 位 × 5 = 10 位/像素）；器件额定（DS981 Table 3-38，出处 H4-验证记录-20261001.md:57）**2000 Mb/s** ⇒ 用量 **12.5%**；同板已上板实测过的 H4 = **1537.5 Mb/s**（:58）⇒ 本设计只用到它的 **16.3%** ⇒ 风险极低，但必须写成"靠额定值 + H4 外推"，⛔ 不能写成"时序报告已证明"。
- **改法**：不改 RTL。把上面这段写进 rtl/hdmi/README.md 的 Validation 段（现在是 README.md:48-50 只说了模型"不是物理 PLL/串行器时序的证据"，但没有给出速率余量论证）。若要真闭环：H4 已经在 **6.15 倍**速率上出图（1537.5 / 250）⇒ 这条外推比任何一次新构建都便宜。
- **预期**：收益 = 防止后续 agent 把"0 违例"误读成"串行器已验证"（这正是 K-45/L31 那一类坑）；代价 = 0。
- **怎么验**：README 里能 grep 到速率余量论证（250 Mb/s / 12.5% / H4 6.15×）。
- **来源**：ANVIL-12【P2-03】
@@@END
@@@PRIO=P2|SRC=ANVIL-12|ORIG=P2-04|MOD=rtl/hdmi/hdmi_scope.v
### 给 reset_pipe 的 lock 加连续 8 拍滤波
- **位置**：rtl/hdmi/hdmi_scope.v:19-22；rtl/hdmi/hdmi_clk.v:43；tb/models/hdmi_primitives_model.sv:25；tb/top/tb_top_m0.sv
- **现状**：
```verilog
19:     always @(posedge pixel_clk or negedge rst_n) begin
20:         if (!rst_n) reset_pipe <= 0;
21:         else reset_pipe <= {reset_pipe[0], lock};
22:     end
```
- **为什么是问题**：`lock` 是 PLL 的状态引脚，不是寄存器输出；Gowin PLLA 在锁定边缘/电源扰动时 `LOCK` 会抖动（脉冲宽度 1~2 个 clk_sys 周期 = 20~40 ns 级别）。当前逻辑：`lock` 低 1 拍 ⇒ `reset_pipe[0]=0` ⇒ 下一拍 `video_reset_n=0` ⇒ video_timing 的 x/y 归零、waveform_scope 全部寄存器清零、frame_ready 丢失 ⇒ 画面黑一帧、快照要重新等一次 vblank（**16.8 ms 一帧**）。即：一次 20 ns 的 LOCK 抖动 = 至少一帧黑屏 + 一次快照重建。（rtl/hdmi/hdmi_clk.v:43 `assign lock = pll_lock;` —— 裸引线，没有任何滤波。）
- **改法**：把 `lock` 换成"连续 N 拍为高"的滤波版（N=8，pixel 域 = 320 ns，远小于 PLL 的锁定时间）：
```verilog
// rtl/hdmi/hdmi_scope.v —— 替换 :19-22
reg [2:0] lock_cnt;
always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) lock_cnt <= 3'd0;
    else if (!lock)             lock_cnt <= 3'd0;
    else if (lock_cnt != 3'd7)  lock_cnt <= lock_cnt + 3'd1;
end
wire lock_stable = (lock_cnt == 3'd7);
always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) reset_pipe <= 2'b00;
    else        reset_pipe <= {reset_pipe[0], lock_stable};
end
```
- **预期**：收益 = 抗 LOCK 抖动（画面不再因 PLL 状态脚抖动而黑一帧）；代价 = **3 FF + 1 个 3 输入比较器（≈2 LUT）**，全在 pixel 域 ⇒ clk_sys Fmax 增量 0。
- **怎么验**：在 tb/top/tb_top_m0.sv 里 `force dut.u_hdmi.u_clk.u_pll.LOCK = 0;` 保持 1 拍再放开（模型 tb/models/hdmi_primitives_model.sv:25 的 LOCK 是 reg，可 force）⇒ 断言 `dut.u_hdmi.reset_pipe` 不出现回落；改前必红。
- **来源**：ANVIL-12【P2-04】
@@@END
@@@PRIO=P2|SRC=ANVIL-12|ORIG=P2-05|MOD=rtl/hdmi/tmds_encoder.v
### 给 tmds_encoder 的 disparity 加法加显式 6 位中间量（消 EX3791）
- **位置**：rtl/hdmi/tmds_encoder.v:45、:46、:50、:53、:22、:43、:47、:48、:35；sim/evidence/final-batch-20261008/syn.log（EX3791）；bringup/hdmi_640x480/H4-验证记录-20261001.md:48；tb/hdmi/；bringup/hdmi_640x480/tb/tb_hdmi_640x480.sv、tb_hdmi_modes.sv、build_hdmi_640x480.ps1
- **现状**：
```verilog
22:     reg signed [5:0] disparity, next_disparity;
43:         end else if ((disparity == 0) || (ones_qm == 4)) begin
45:             if (qm[8]) next_disparity = disparity + (2*ones_qm - 8);
46:             else       next_disparity = disparity + (8 - 2*ones_qm);
50:             next_disparity = disparity + 2*qm[8] + (8 - 2*ones_qm);
53:             next_disparity = disparity - 2*(!qm[8]) + (2*ones_qm - 8);
告警原文：WARN (EX3791) : Expression size 32 truncated to fit in target size 6
```
- **为什么是问题**：`ones_qm` 是 4 位无符号 ⇒ `2*ones_qm` 按 32 位整数运算 ⇒ 整个表达式是 32 位无符号（Verilog 混合符号规则），截断到 6 位就是 two's complement 取模 64。数学范围：`2·ones_qm − 8 ∈ [−8, 8]`，`disparity ∈ [−8, 8]`（TMDS 运行不一致性的经典界）⇒ 真值 ∈ `[−16, 16]` ⊂ 6 位有符号 `[−32, 31]` ⇒ 截断不丢信息（模 64 与真值一致）。`disparity` 的比较 :43/:47/:48 用的是有符号比较（声明带 signed）✅ 正确。旁证：这 4 条告警在已验证过的 H4 基线里一模一样存在（H4-验证记录-20261001.md:48："与 640×480 基线相同的 5 行（4× EX3791 + 1× PR1014）"）⇒ 不是回归。
- **改法（只为消警 + 防未来改位宽时踩坑，逻辑等价）**：
```verilog
// 显式声明中间量，让工具不再报 32→6 截断（逻辑逐位不变）
reg signed [5:0] dq;
always @* begin
    dq = 2*ones_qm - 8;      // 有符号 6 位，范围 [-8,8]
    ...
    if (qm[8]) next_disparity = disparity + dq;
    else       next_disparity = disparity - dq;
```
- **预期**：收益 = syn.log 里 EX3791 从 4 条 → 0 条（告警清零 ⇒ 下一次真正的位宽 bug 不会被淹没）；代价 = **0 逻辑**（综合会折叠成同样的加法器），但要重跑 tb（逐位等价）。
- **怎么验**：改完 `-Filter waveform_scope` 与 `-Filter top_m0` 必须全绿；把 `dq` 故意改成 `8 - 2*ones_qm`（错号）⇒ 必须 FAIL。⚠️ 注意覆盖边界：tmds_encoder 在根 tb/ 树里没有直接测试台（tb/hdmi/ 只有 tb_waveform_scope.sv，它不例化编码器）；编码器的全帧检查在 bringup/hdmi_640x480/tb/tb_hdmi_640x480.sv / tb_hdmi_modes.sv（由 bringup/hdmi_640x480/build_hdmi_640x480.ps1 驱动，⛔ 不在 sim\tb_all.ps1 的自动发现范围内）⇒ 改编码器必须额外跑一次 bringup 的 tb，否则等于没验。⭐ 同节附：消隐期把 disparity 清零（:35 `next_disparity = 0;`）是合法且有意为之，⛔ 不要"修"：它使运行不一致性每行重置 ⇒ 界天然有界（`|disparity| ≤ 8`），而 TMDS 的接收侧只解 10 位符号、不跟踪发送侧的 disparity，所以这是自由的设计选择，不是规范违背（把它改成"保持"反而会让不一致性跨行累积）。
- **来源**：ANVIL-12【P2-05】
@@@END
@@@PRIO=P3|SRC=ANVIL-12|ORIG=P3-01|MOD=rtl/clk_gen.v
### 记档：clk_gen.mclk_en 是死输出，不建议改
- **位置**：rtl/clk_gen.v:34、:105；rtl/top.v:785、:795、:346；rtl/w3b/voice_i2s_chain.v；rtl/bringup/wavetable_tone_top.v；impl/pnr/Gowin2026_tr_content.html；impl/pnr/Gowin2026.rpt.txt；rsc.xml
- **现状**：
```verilog
 34:     output reg  mclk_en,      // MCLK 使能：每 MCLK_DIV 个 clk 一个周期
105:             mclk_en      <= (cnt[$clog2(MCLK_DIV)-1:0] == { $clog2(MCLK_DIV){1'b0} });
```
- **为什么是问题**：证据（机械可查）：`mclk_en` 在 impl/pnr/Gowin2026_tr_content.html 里出现 **0 次**、在 impl/pnr/Gowin2026.rpt.txt 里出现 **0 次** ⇒ 该网根本没进网表（综合已删）。rtl/top.v:346 自己写着 `// ── 音频（板载 DAC = MAX98357A，⛔ 不需要 MCLK）──` ⇒ 板上没有任何器件需要 MCLK。rsc.xml：`u_clk_gen Register="13"`，而 RTL 声明 16 个 FF ⇒ 有 3 个没进网表。
- **改法**：不建议改。删端口要动 top.v / voice_i2s_chain.v / wavetable_tone_top.v **3 个文件 + tb 端口表**，换来 **1 个 FF + 1 个 2 输入 NOR ≈ 1 LUT（占 27271 LUT 的 0.004%）** ⇒ 性价比为负，⛔ 不要动。本条写进报告的唯一目的：下次有人看到 `mclk_en` 不要以为它有用（避免"以为在跑、其实被优化掉"的误判）。
- **预期**：避免负收益改动；代价 0。
- **怎么验**：`Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'mclk_en'` 为 0 命中。
- **来源**：ANVIL-12【P3-01】
@@@END
@@@PRIO=P3|SRC=ANVIL-12|ORIG=P3-02|MOD=rtl/clk_gen.v
### 把 clk_gen 的参数守卫搬到综合期（实例化一个不存在的模块名）
- **位置**：rtl/clk_gen.v:61-75、:52-53、:88-92、:105、:48-51；rtl/top.v:788；tb/clk_gen/tb_clk_gen_badparam.sv
- **现状**：
```verilog
61:     localparam PARAM_OK = is_pow2(CLK_PER_SAMPLE) && is_pow2(BCLK_DIV) && is_pow2(MCLK_DIV)
62:                           && (BCLK_DIV >= 2) && (MCLK_DIV >= 2)
63:                           && (CLK_PER_SAMPLE >= BCLK_DIV);
65:     initial begin
66:         if (!PARAM_OK)
67:             $display("ERROR [clk_gen] 参数必须全为 2 的幂 ...");
```
- **为什么是问题**：`$clog2` 被当移位量/位选用（:88-92、:105）⇒ 只有 2 的幂才等于真除法/真取模。`initial` 在综合时被完全忽略（syn.log 里只有 `EX3858 System task 'display' is ignored`）⇒ 上板路径上唯一的守卫是"人记得检查"。:52-53 的注释已承认这一点，但没有替代方案。
- **改法（把守卫搬到综合期，用"实例化一个不存在的模块"这一条工具无关的硬报错）**：
```verilog
// rtl/clk_gen.v —— 紧跟 :63 之后（generate 在参数非法时展开一个不存在的模块名）
generate
    if (!PARAM_OK) begin : g_param_guard
        // 模块名本身就是错误信息：非法时综合/elaborate 必然 ERROR 并打印这一行
        clk_gen_PARAM_ERROR_CLK_PER_SAMPLE_BCLK_DIV_MCLK_DIV_must_be_power_of_2 u_fail();
    end
endgenerate
```
⚠️ 报错文案不如 $display 友好，所以 initial 那段要留着（initial 给人看、generate 守卫给工具看）。⛔ 不要用 `BAD[BAD]` 之类的越界位选去触发报错 —— Gowin 对常量越界的处理未见文档保证，而"例化不存在的模块"在任何工具上都是必然 ERROR。
- **预期**：把"静默错频率"（:48-51 注释里已写明：BCLK_DIV=12 时 BCLK 比预期低 33%）变成"构建失败"；代价 = 0 逻辑（参数合法时 generate 分支不展开，网表逐字不变）。
- **怎么验**：①`sim\tb_all.ps1 -Filter clk_gen_badparam`（tb/clk_gen/tb_clk_gen_badparam.sv 已存在）必须绿；②把 rtl/top.v:788 的 `.CLK_PER_SAMPLE (1024)` 临时改成 `1000` ⇒ 综合必须 ERROR（改前：syn.log 里一条 ERROR 都没有，构建照常产出位流 ⇒ 这就是"静默"的证据）。
- **来源**：ANVIL-12【P3-02】
@@@END
@@@PRIO=P3|SRC=ANVIL-12|ORIG=P3-03|MOD=rtl/hdmi/video_timing.v,rtl/hdmi/tmds_encoder.v,rtl/hdmi/tmds_serializer.v,rtl/hdmi/hdmi_clk.v
### 给四个 HDMI 文件补 timescale，并记下帧率 −0.69% 的正确修法
- **位置**：rtl/hdmi/video_timing.v（第 1 行直接是 module）、rtl/hdmi/tmds_encoder.v:1、rtl/hdmi/tmds_serializer.v:1、rtl/hdmi/hdmi_clk.v:1、:2-11、:32-35、:32-34；rtl/hdmi/waveform_scope.v:1、rtl/hdmi/hdmi_scope.v:1、rtl/clk_gen.v:23、rtl/rst_sync.v:1、rtl/sync_input.v:1；rtl/hdmi/hdmi_scope.v:17；tb/hdmi/tb_waveform_scope.sv:62；bringup/hdmi_640x480/tb/tb_hdmi_modes.sv
- **现状**：
```
位置（缺 timescale）：rtl/hdmi/video_timing.v（第 1 行直接是 module）、rtl/hdmi/tmds_encoder.v:1、
rtl/hdmi/tmds_serializer.v:1、rtl/hdmi/hdmi_clk.v:1。
对照：waveform_scope.v:1 / hdmi_scope.v:1 / clk_gen.v:23 / rst_sync.v:1 / sync_input.v:1 都有。
```
- **为什么是问题**：Verilog 的 `timescale` 是编译顺序相关的全局指令，缺省的文件继承前一个文件的值。这 4 个文件当前没有任何 `#delay` ⇒ 今天影响为 0；风险在于"改文件顺序/新加文件"会静默改变时间单位（本项目已因编译顺序/编码踩过 C72 那类静默坑）。帧率部分：rtl/hdmi/video_timing.v:2-11 的 VESA 参数逐条核对正确：`H = 640+16+96+48 = 800` ✅、`V = 480+10+2+33 = 525` ✅（与 VESA 640×480@60 完全一致）、同步极性负（:32-35 的 ! 与 tb/hdmi/tb_waveform_scope.sv:62 的 `hs=!(px>=656&&px<752)` 一致）✅；帧率 = `25 000 000 / (800×525) = 59.5238 Hz`，比 VESA 名义 **59.94 Hz 低 0.69%**。
- **改法**：①四个文件补 `` `timescale 1ns/1ps ``（0 风险）；②若现场遇到"某台显示器不接受"⇒ 一行切换 hdmi_clk 的分数档：rtl/hdmi/hdmi_scope.v:17 加 `.USE_252(1)` ⇒ `MDIV_SEL=63, ODIV0=25, ODIV1=125` ⇒ `VCO = 50×63 = 3150 MHz` ⚠️ **超出 [700,1400]** ⇒ **PA1019，不可用**！⇒ ⭐ 正确做法是把 rtl/hdmi/hdmi_clk.v:32-34 改成 `MDIV_SEL=25/ODIV0=50/ODIV1=250`（VCO=1250 MHz ∈ 范围，pixel=25.2 MHz → 60.00 Hz），⛔ 不要直接翻 `USE_252`（它的 MDIV=63 组合在 GW5AT-60B 上非法，这是文件里现成的一个陷阱）。
- **预期**：消除时间单位静默漂移；帧率修法有正确路径。
- **怎么验**：PnR 里搜 PA1019（必须 0）；帧率用 tb_hdmi_modes.sv 的全帧计数换算。
- **来源**：ANVIL-12【P3-03】
@@@END
@@@PRIO=P3|SRC=ANVIL-12|ORIG=P3-04|MOD=rtl/hdmi,evidence/h5
### 记档：HDMI 四条已结案项，不要重开
- **位置**：evidence/h5/experiment-tree-20261003/；bringup/hdmi_640x480/H5…20261002.md 附录 H.1、附录 E/F/G、附录 B step 3、附录 C.3；rtl/hdmi/README.md:32-35；rtl/hdmi/video_timing.v、tmds_encoder.v、tmds_serializer.v、hdmi_clk.v
- **现状**：
```
| H5「两条线/残影」显示修复（音频触发窗口） | ⭐ 用户 2026-10-04 明确「现在 h5 不需要显示修复」⇒ 已结案。补丁完整保存在
  evidence/h5/experiment-tree-20261003/，⛔ 不要再并入（H5…20261002.md 附录 H.1）。但注意：该补丁当年把 clk_sys 从
  53.425 打到 50.085（同一条 ADSR 锥退化 1.248 ns）⇒ 若将来真要重开，必须先读附录 E/F/G 的全部失败记录。
| rtl/hdmi/{video_timing,tmds_encoder,tmds_serializer,hdmi_clk}.v 的"共享文件"身份 | rtl/hdmi/README.md:32-35 明写：
  这四个文件与 bringup/hdmi_640x480 共享，⛔ 不得改默认值（除非重做 bringup 的字节级位流比对）⇒ P0-01/P1-01 改的是
  hdmi_scope.v/tmds_serializer.v 的连线，动 tmds_serializer.v 前必须先确认 bringup 那边会不会一起红。
| CLOCK_LOC "rst_n_sync" BUFG = SR|LOGIC | 已实测无效（仍 LW）且更差（50.527 → 49.671）⇒ ⛔ 不要再试。
| place_option/route_option/timing_driven 算法组合 | 两组都失败（3906 / 103 unrouted nets，各 100 分钟）⇒ ⛔ 不要再试。
```
- **为什么是问题**：这四条都已实测/裁定，重开就是浪费 10 分钟 × N 次 PnR。
- **改法**：不改，只记档。
- **预期**：避免重复投入；代价 0。
- **怎么验**：引用本表即可（每条都带原始证据出处）。
- **来源**：ANVIL-12【P3-04】
@@@END
@@@TOTAL SRC=ANVIL-12 COUNT=15 P0=2 P1=4 P2=5 P3=4
