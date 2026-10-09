@@@PRIO=P0|SRC=TORCH-4|ORIG=P0-1|MOD=rtl/top.v
### 让 'M' 的回包说实话（本码流没有 Test Mode）
- **位置**：rtl/top.v:72、:67、:1340-1342、:1354-1407、:2391-2395、:2445、:1046、:1378-1394、:1395-1406；tb/w3b/tb_test_mode_top.sv
- **现状**：
```verilog
// rtl/top.v:67（注释）
//   ✅ `1`（**默认**，诊断码流）= 行为与改动前**逐字一致**
// rtl/top.v:72（实际值）
parameter integer TEST_MODE_EN       = 0,
// rtl/top.v:1341-1342（注释）
//  📌 诊断码流（`TEST_MODE_EN=1`）**行为与改动前逐字一致**；默认值保持 1，
//     以免影响现有测试台与上板习惯。
// rtl/top.v:1395-1406（=0 分支）
end else begin : g_no_test_mode
    assign tm_enable_r    = 1'b0;
    assign tm_gate        = {POLY_TARGET{1'b0}};
// rtl/top.v:2391-2395
wire [7:0] tm_reply_byte = !tm_enable_r          ? 8'h34          // '4'
                        : (tm_n_code_r == 2'b00) ? 8'h38 ...
// rtl/top.v:2445
: cmd_test_mode_req? tm_reply_byte    // M: 4/8/A/B/0
```
- **为什么是问题**：交付档 `tm_enable_r ≡ 1'b0`（编译期常量）⇒ `tm_reply_byte ≡ 8'h34 = '4'`。而 rtl/top.v:1046 的回传表把 '4' 定义为"Test Mode 已切至 4" ⇒ 操作者每发一次 'M' 都收到 '4'，永远不变（`tm_n_code_q` 那套状态机在 `g_no_test_mode` 分支里根本不存在），而 `tm_gate/tm_vel/tm_lane_active/tm_phase_inc` 全是常量 0 ⇒ 整条 FFT 验收通路（test_mode_ctrl 不进网表）在交付码流里是死的。test_mode_ctrl 只在 `g_test_mode` 分支例化（rtl/top.v:1378-1394）⇒ 后果：上板做音频验收时，'M' 会告诉你"已进入测试模式"，而实际没有测试音 —— 这是"全绿但没声音"家族的又一例（R-16/K-69 同族）。
- **改法**（二选一，推荐①）：1. 让回包说实话（不改任何功能，1 行）：
```verilog
wire [7:0] tm_reply_byte = (TEST_MODE_EN == 0) ? 8'h2D          // '-' = 本码流无 Test Mode
                        : !tm_enable_r          ? 8'h34
                        : (tm_n_code_r == 2'b00) ? 8'h38
                        : (tm_n_code_r == 2'b01) ? 8'h41
                        : (tm_n_code_r == 2'b10) ? 8'h42 : 8'h30;
```
2. 或者把默认值改回 1（与注释一致），交付时再显式改 0 —— 但那样注释与代码仍然靠"记得"对齐。
- **预期**：收益 = 控制面不再说谎，验收脚本能靠 '-' 自动判定"本码流无 Test Mode"；代价 = 0（1 行、不新增逻辑、不改端口）。必须同步更正 rtl/top.v:67 与 :1341 两处注释（它们现在直接与 :72 矛盾）。
- **怎么验**：新增/改造 tb/w3b/tb_test_mode_top.sv，加一条默认档用例：例化 top（不传 TEST_MODE_EN）→ 发 'M' → 断言回包 ≠ '4'。现在必然红（回的是 '4'）；按改法①修完变绿。同时断言 `dut.g_sound.g_test_mode` 不存在（编译期即可证明）或 `tm_gate === 0`。
- **来源**：TORCH-4【P0-1】
@@@END
@@@PRIO=P0|SRC=TORCH-4|ORIG=P0-2|MOD=sim/gowin_build.ps1,rtl/top.v
### 把 NL0002 模块消失变成硬门 + 白名单
- **位置**：impl/gwsynthesis/Gowin2026.log；rtl/top.v:4091、:4463、:4145、:1095、:1565、:186-196、:4091；sim/evidence/final-batch-20261008/rsc.xml；sim/gowin_build.ps1
- **现状**：
```
WARN  (NL0002) : The module "metronome"          instantiated to "g_sound.u_metronome"       is swept in optimizing(top.v:1565)
WARN  (NL0002) : The module "param_extract"      instantiated to "g_sound.u_param_extract"   is swept in optimizing(top.v:3335)
WARN  (NL0002) : The module "pos_probe"          instantiated to "g_sound.u_pos_probe_dpos"  is swept in optimizing(top.v:3006)
WARN  (NL0002) : The module "right_analog_ctrl"  instantiated to "g_sound.u_right_analog_ctrl" is swept in optimizing(top.v:1754)
WARN  (NL0002) : The module "vibrato_lfo"        instantiated to "g_sound.u_vibrato_lfo"     is swept in optimizing(top.v:4161)
WARN  (NL0002) : The module "led_data"           instantiated to "u_led_data"                is swept in optimizing(top.v:4844)
```
- **为什么是问题**：只有 `u_pos_probe_dpos`（`DPOS_DIAG=0`）是文档写明该被扫掉的（rtl/top.v:186-196）。另外 5 个与注释直接冲突：`u_param_extract`（top.v:4091 声称"它的音高通路…仍在用"，实际 swept ⇒ 手弹滑音/音高跟随丢失，`pitch_upd_*` 只剩 looper 那一路）；`u_vibrato_lfo`（:4145 声称 "internal LFO output is Q1.15, matching oscillator_bank"，实际 swept ⇒ 颤音 `vibrato_mod` 常 0 ⇒ `vib_off` 常 0）；`u_right_analog_ctrl`（:4463 声称"输出 0x7FFF，保证旧硬件仍是满音量"，实际 swept ⇒ 主音量折叠成常量）；`u_metronome`（:1565；`SEL_DRUM=1` 时本该扫掉，但 `cfg_warn` 也一起没了）；`u_led_data`（:4838-4840 三个输入是占位常量）。为什么这条是 P0：本项目的第四道门是"综合 ERROR=0"，`NL0002` 是 **WARN** ⇒ 一个模块整块消失也能过门，而它带走的可能是文档声称"仍在用"的功能。sim/evidence/final-batch-20261008/rsc.xml 的模块清单里确实没有 `g_sound.u_metronome`/`u_param_extract`/`u_vibrato_lfo`/`u_right_analog_ctrl`/`u_led_data`，而 `u_pos_probe`/`u_span_probe` 都在 ⇒ 与日志一致。
- **改法**（把"看不见"变成"可判定"，3 步）：1. 在 sim/gowin_build.ps1 里加一条硬门：日志中出现 `NL0002` 即 FAIL，并配一张显式白名单（当前只允许 `g_sound.u_pos_probe_dpos`，附理由字符串 `DPOS_DIAG=0`）。2. 白名单之外的每个 `NL0002` 必须在 top.v 的注释里写出为什么它该被扫掉。3. 对 `u_param_extract`/`u_vibrato_lfo`/`u_right_analog_ctrl` 三个，必须给一个"它活着"的判据。
- **预期**：收益 = 把"注释声称的功能"与"网表里真有的功能"强制对齐；代价 = 每次构建多一条 grep 判定（<1 s）。不改 RTL 行为。
- **怎么验**：现在跑 `Select-String NL0002 impl/gwsynthesis/Gowin2026.log` ⇒ **6 条** ⇒ 新门必然红。补完白名单 + 注释后应变绿；若有人手滑把 `RIGHT_ADC_ENABLE` 改回 1，`u_right_analog_ctrl` 会从 swept 列表消失 ⇒ 门会提示"白名单过期"，反向也能红。
- **来源**：TORCH-4【P0-2】
@@@END
@@@PRIO=P0|SRC=TORCH-4|ORIG=P0-3|MOD=rtl/w3b/note_manager.v,constr/top.cst
### 给 T3 写口加一级流水并给 g_t3 加 GROUP/GRP_LOC
- **位置**：rtl/w3b/note_manager.v:1515-1570、:1532-1544、:1518、:1528-1534、:1544；impl/pnr/Gowin2026.timing_paths:1-41；impl/pnr/Gowin2026_tr_content.html；rtl/top.v:4390-4395、:325-327；constr/top.cst:518-523；tb/w3b/tb_rot32_diff.sv、tb_transpose.sv
- **现状**：
```verilog
// rtl/w3b/note_manager.v:1518,1528-1534,1544
reg  [4:0]         rot_cnt;                                  // 自由运行 0..31
localparam integer ROT_LANES = (POLY_TARGET > 32) ? 32 : POLY_TARGET;
wire [PHASE_W-1:0] rot_phase = phase_r[rot_cnt];              // ← 32 项 × 32 位寄存器堆读
wire [PHASE_W-1:0] rot_base  = (base_oct_r == 2'd0) ? rot_phase
                                                    : (rot_phase << base_oct_r);
wire [PHASE_W+17-1:0] prod_w = rot_base * semi_ratio;         // ← 唯一一个共享乘法器
// impl/pnr/Gowin2026_tr_content.html（Constraint[1] Path1）
Slack 0.102 | Data Arrival 22.172 | Data Required 22.274 | Setup Relationship 18.181 | Clock Skew 0.008
Arrival Data Path Delay: cell 4.607 (25.555%) · route 13.092 (72.611%) · tC2Q 0.331 (1.834%)
  4.473  rot_phase_20_s83/I2      ← 前一段 tNET = 5.264 ns（rot_cnt_0_s0 扇出 595）
 16.765  n34284_s0/F              （扇出 32）
 22.172  g_t3.phase_tr[28]_24_s0/D ← 本段 tNET = 5.407 ns（R27C96 → R60C141）
```
- **为什么是问题**：`rot_cnt[0]` 扇出 **595**（High Fanout Nets Report：`g_t3.rot_cnt[0] | FANOUT 595 | WORST SLACK 0.102`）⇒ 光把这一位送到 32 项 mux 的每个 LUT 输入就要 **5.264 ns**。影子数组 `phase_tr` 是 32 voice × 32 位 = 1024 FF，`phase_tr[28]_24_s0` 被摆在 R60C141，而驱动它的 LUT 在 R27C96 ⇒ 一个网跨 45 列 × 45 行 = **5.407 ns**。两者合计 **10.671 ns = 数据路径的 59%**；纯逻辑只有 4.607 ns。
- **改法**（结构 + 布局各一刀，都便宜）：① 结构刀：给乘法器→影子数组的写口加 1 级流水（消掉 5.407 ns 那段）：
```verilog
reg [PHASE_W+17-1:0] prod_w_r;
reg [4:0]            rot_cnt_w;
always @(posedge clk_i) begin
    if (!rst_n_i) begin prod_w_r <= 0; rot_cnt_w <= 5'd0; end
    else begin prod_w_r <= prod_w; rot_cnt_w <= rot_cnt; end
end
// 写口改用 prod_w_r / rot_cnt_w
```
代价：轮转窗口从 32 拍变 **33 拍**。预算：`tick_audio` 周期 = 1024 拍，`tdm_render_mixer` 在 `mx_start_dly[31]`（= `ob_valid` 延 32 拍，rtl/top.v:4390-4395）之后才启动、只需 34 拍 ⇒ 32+1+34+7 级流水 ≈ 74 拍，余量 **13.8×** ⇒ 完全放得下。收益：**−5.4 ns**（数据路径 18.079 → ≈12.7 ns ⇒ Fmax 表观 ≈78 MHz）。② 布局刀：给 `g_t3` 加一组 GROUP/GRP_LOC（消掉 5.264 ns 那段的分布半径）：
```text
// constr/top.cst —— 与已有的 h5_ret 同一手法（:518-523）
GROUP t3_rot = { "g_sound.u_note_manager/g_t3.rot_cnt*"
                 "g_sound.u_note_manager/g_t3.rot_phase_*"
                 "g_sound.u_note_manager/g_t3.rot_base_*"
                 "g_sound.u_note_manager/g_t3.prod_w_*"
                 "g_sound.u_note_manager/g_t3.phase_tr*" };
GRP_LOC t3_rot R[20:40]C[80:120];
```
⚠️ 非独占（CLS 已 78%，独占会 PR0004 布不通）—— 与 h5_ret 的注释同一理由。收益：把 `rot_cnt` 的 595 个负载与 1024 个 `phase_tr` FF 收进同一个矩形，目标是把两条 tNET 从 5.264/5.407 压到 ~2 ns ⇒ 再 −5~7 ns。
- **预期**：① 约 +0.3% FF（49 位）、+0 LUT、零功能变化；② 只改 .cst、零 RTL 风险，代价是布局自由度下降（可能把别的路径挤坏 ⇒ 必须复算全量 slack）。⚠️ 顺序：先做 ①（确定性），再单独评估 ②（有副作用）。
- **怎么验**：① 的功能性判据：tb/w3b/tb_rot32_diff.sv / tb_transpose.sv（都是逐位差分 tb）⇒ 若流水导致差一拍，它们必然红（这正是它们存在的意义）。①/② 的时序判据：重跑 PnR 后读 impl/pnr/Gowin2026.timing_paths，断言 `From` 不再是 `g_t3.rot_cnt_0_s0`；并断言 `Actual Fmax > 55.313`。反向证明（防假绿）：把 `phase_tr` 的写口接回 `prod_w`（去掉流水）⇒ Fmax 必须回落。
- **来源**：TORCH-4【P0-3】
@@@END
@@@PRIO=P0|SRC=TORCH-4|ORIG=P0-4|MOD=rtl/top.v,rtl/w3a/event_extract.v
### 把有界丢事件路径接进可读的口
- **位置**：rtl/top.v:3177-3178、:3755-3761、:3981-3984、:1133-1134、:3653-3657、:1095-1096、:2162、:1719；rtl/w3a/event_extract.v:163、:307-315、:323
- **现状**：
```verilog
// rtl/w3a/event_extract.v:163 —— 有界缓冲
localparam integer FIFO_D = 4;
// rtl/w3a/event_extract.v:314-315
overflow_o_r <= 1'b1;                              // ⭐ sticky
if (lost_cnt_r != 8'hFF) lost_cnt_r <= lost_cnt_r + 8'd1;
// rtl/w3a/event_extract.v:323（原文注释）
//     若此刻 FIFO 满 ⇒ push 失败 ⇒ 🔴 **这条 `note_off` 永久丢失**
// rtl/top.v:3177-3178 —— 接到两条【从没人读】的线上
.overflow_o       (ee_ovf),
.lost_cnt_o       (ee_lost)
// rtl/top.v:1095-1096（对 tx_fifo 的原始要求）
//   🔴 **溢出可观测**（⭐ `K-106`）：⭐ `ovf_o` sticky + `drop_cnt_o` 饱和计数
//      ⛔ **没有这两个输出就【等于没修】** —— ⚠️ 只是换了个地方悄悄丢
// rtl/top.v:1133-1134
.ovf_o     (txf_ovf),
.drop_cnt_o(txf_drop),
```
- **为什么是问题**：`grep -c` 全文件计数 = **2**（= 声明 1 + 例化端口 1），即以下 20 条线没有任何消费者：`ee_ovf ee_lost sa_overflow sa_drop_cnt sa_collision_cnt sa_merged_cnt sa_live_cnt sa_score_cnt sa_demo_cnt mg_overflow mg_drop_cnt mg_collision_cnt mg_merged_cnt txf_ovf txf_drop looper_full looper_drop_cnt looper_overflow looper_evt_cnt met_cfg_warn drm_cfg_warn`。无消费者的寄存器没有理由被保留 ⇒ 计数器逻辑被剪掉 ⇒ 'P'/'V' 回包之外，上板无法判断"刚才是不是丢了事件"。而 event_extract 的 FIFO 只有 4 深、seq_arb/evt_merge 只有 6 深、looper 有 `EVT_MAX=2048` 上限 ⇒ 丢事件是设计内的可能事件，现在它 100% 静默 —— 正是 K-106 纪律要禁止的形态。
- **改法**（选 1 条即可，推荐①）：1. 把 sticky 位塞进现成的串口诊断面：'V'（span_probe，rtl/top.v:2162）已经是一个 7 字节回包；把 `ee_ovf|mg_overflow|sa_overflow|txf_ovf|looper_overflow` 折成 1 个字节，在 'V' 回包里多带 1 字节（改 `N_BYTES(7)→8`），或复用 'Q'（DPOS_DIAG 门控）那一格。2. 或者用现成的心跳灯：`fault_any_w`（rtl/top.v:1719）已经在做 OR 汇合，把 `|{ee_ovf, mg_overflow, sa_overflow, txf_ovf}` 也 OR 进去 ⇒ 快闪 = 丢过事件。⚠️ 但要注意 `fault_sticky` 是"只复位才清"，会掩盖后续正常帧（现有注释已说明这是有意为之）。
- **预期**：收益 = 把"永久丢一条 note_off"变成可判定（这正是挂音类 bug 的取证工具）；代价 = ① 多 1 字节回包（人眼无感，500 kbps 下 +20 µs）；② 零额外资源（只是把已有 OR 加宽 1 位）。
- **怎么验**：写一个 tb，把 event_extract 的 FIFO 灌满（连发 ≥5 个同拍事件），断言 `dut.g_sound.ee_ovf === 1'b1` 且该位能通过 'V'/心跳灯观测到。现在必然红（观测不到）；修完变绿。
- **来源**：TORCH-4【P0-4】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-1|MOD=constr/top.sdc
### 给 33 根无约束引脚补延时或带理由的 false_path
- **位置**：constr/top.sdc:62-71、:101-102、:24-26、:39-40；impl/pnr/Gowin2026_tr_content.html（Timing Constraints Report，共 11 条全 Actived）；rtl/top.v:4653-4685、:575-584、:637-646；rtl/drivers/adc_farm.sv:85-95；rtl/w3a/async_pluck_capture.v:36-39
- **现状**：
```
TC_CLOCK            Actived  create_clock -name clk_sys -period 20 …
TC_GENERATED_CLOCK  Actived  create_generated_clock … serial_clk … CLKOUT0
TC_GENERATED_CLOCK  Actived  create_generated_clock … pixel_clk  … CLKOUT1
TC_OUTPUT_DELAY     Actived  set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
TC_OUTPUT_DELAY     Actived  set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
TC_OUTPUT_DELAY     Actived  set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]
TC_FALSE_PATH       Actived  set_false_path -to   [get_ports {PA_EN_n}]
TC_FALSE_PATH       Actived  set_false_path -to   [get_ports {led_heartbeat}]
TC_FALSE_PATH       Actived  set_false_path -from [get_ports {rst_n}]
TC_MAX_DELAY        Actived  set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
TC_MAX_DELAY        Actived  set_max_delay … -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0}] 10.000
```
- **为什么是问题**：时钟侧 ✅ 无漏项（Clock Summary 恰好 3 个时钟，`create_generated_clock` 的对象路径与 RTL 层次逐字对得上；第二条 max_delay 的 get_regs 通配确实命中，异常报告里回的是 `To = u_hdmi/u_scope/gray_launch_3_s0`，`Latch Clk = clk_sys:[F]`，`Required 13.913` ⇒ 不是空对象）。引脚侧 🔴 大面积空白：`set_input_delay` 计数 = **0**；`set_output_delay` 只覆盖 **3 / 66** 根脚。SDC 自己的文件头（:24-26）就写明"在没有 set_output_delay/set_input_delay 时不被分析" ⇒ 下列 33 根脚零时序约束：输出（30）`I2S2_BCK I2S2_LRCK I2S2_DIN`（⚠️ 外置 PCM5102A，是在用的输出）· `led_sdi led_clk led_le led_oe_n[4:0]`（led_clk 是移位时钟）· `ctrl_row_o[3:0] ctrl_ws_o esp_uart_tx_o ws_strip_o[2:0]` · `tmds_d_p_0[2:0] tmds_clk_p_0 hpd_en`；输入（全部）`uart_rx spi_miso[5:0] pluck_up_i pluck_down_i timbre_btn_i ctrl_col_i[3:0] enc_a_i enc_b_i enc_sw_i pedal_sus_i pedal_loop_rec_i pedal_loop_play_i esp_uart_rx_i`。无 `-min`：所有 set_output_delay 只有 -max ⇒ 输出脚没有 hold 检查。逐条判定（⛔ 不要一律当风险）：`spi_miso[*]` 不构成风险（SCLK=1 MHz ⇒ 半周期 500 ns；且 adc_farm 里每片 2 级同步，adc_farm.sv:85-95）；`pluck_up/down` `timbre_btn` `uart_rx` `pedal_*` `enc_*` `ctrl_col_i` 不构成风险（全部经 sync_input 2 级同步）；`I2S2_*` 真空白（与 HP_* 同构，同一 i2s_tx、同 bclk_en/frame_start，rtl/top.v:4653-4685 ⇒ 今天不会错，但改 `u_i2s_tx_ext` 的参数（MSB_DELAY 0 vs 1）时工具不会报警）；`led_clk`/`led_sdi`/`led_le`/`led_oe_n` 真空白（tlc5916_bank 的移位时钟，速率需实测；无约束 ⇒ 工具不优化、不检查）；`ctrl_ws_o` 真空白（WS2812 位时序 ~1.25 µs/位）；`tmds_*` 由 serial_clk/pixel_clk 覆盖内部路径。
- **改法**：
```tcl
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_LRCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_DIN}]
set_false_path -to [get_ports {led_sdi led_clk led_le led_oe_n[*] ctrl_row_o[*] ctrl_ws_o ws_strip_o[*] esp_uart_tx_o hpd_en}]
set_false_path -from [get_ports {uart_rx spi_miso[*] pluck_up_i pluck_down_i timbre_btn_i \
                                 ctrl_col_i[*] enc_a_i enc_b_i enc_sw_i \
                                 pedal_sus_i pedal_loop_rec_i pedal_loop_play_i esp_uart_rx_i}]
```
⚠️ 纪律（沿用 constr/top.sdc:39-40 原文）：`set_false_path` 只给确实不要求时序的路径，且必须逐条写理由。上面输入侧的 false_path 的理由是"全部经 2 级同步器"—— 这比"不写"更诚实（不写 ⇒ 不分析，但没人知道是有意还是漏了）。
- **预期**：收益 = "0 违规"重新变成有覆盖的 0 违规（这条是任务书点名的最阴）；代价 = 0 逻辑、0 时序影响；⚠️ 唯一风险是把某条真需要约束的路径误 false 掉 ⇒ 所以 `led_clk` 建议先量一次实际翻转率再决定是 false_path 还是 set_output_delay。
- **怎么验**：改完重跑 PnR，读 Timing Constraints Report，断言 `TC_INPUT_DELAY` 或 `TC_FALSE_PATH` 的对象计数 = 33；并断言 `Numbers of Setup/Hold Violated Endpoints` 仍为 0/0。反向：临时把 `I2S2_BCK` 的 -max 改成 19.0 ⇒ 必须出现 setup 违例（证明约束真的生效）。
- **来源**：TORCH-4【P1-1】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-2|MOD=sim/gowin_build.ps1
### 给 serial_clk 的"零路径"加存在性断言
- **位置**：impl/pnr/Gowin2026_tr_content.html（Max Frequency Summary）；rtl/hdmi/tmds_serializer.v:22-33；sim/gowin_build.ps1；constr/top.sdc
- **现状**：
```
Max Frequency Summary:
1  clk_sys     50.000(MHz)  55.313(MHz)  7  TOP
2  pixel_clk   25.000(MHz) 137.684(MHz)  8  TOP
   No timing paths to get frequency of serial_clk!
```
```verilog
// rtl/hdmi/tmds_serializer.v:22-33
OSER10 u_oser (.Q(serial[j]), .D0(lane[j][0]), … .D9(lane[j][9]),
               .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst));
```
- **为什么是问题**：`serial_clk` 是 125 MHz / 8 ns 的生成时钟，被 create_generated_clock 正确创建（Actived），但没有任何寄存器到寄存器路径落在它上面 ⇒ Gowin 明确打印 "No timing paths to get frequency of serial_clk!" ⇒ 这个时钟域完全没有 STA 覆盖。今天唯一的消费者是 OSER10 硬原语的 FCLK（其内部时序由原语特性保证）⇒ 当前不是缺陷；但它是**一个已经建好时钟、却零检查的域**：只要将来有人往 serial_clk 上挂一个寄存器（哪怕只是打拍），工具不会报任何东西。
- **改法**（低风险，二选一）：1. 加一条"存在性断言"（推荐）：在 sim/gowin_build.ps1 里断言 `No timing paths to get frequency of serial_clk` 必须出现；若哪天它消失 ⇒ 说明有人在 125 MHz 域加了逻辑 ⇒ 门主动报警要求补约束/补分析。2. 或在 constr/top.sdc 里显式写一行注释块，说明"serial_clk 只进 OSER10 的 FCLK，不承载寄存器逻辑；若承载则必须补 set_max_delay"。
- **预期**：收益 = 把一个"沉默的域"变成"会叫的域"；代价 = 1 行判定。
- **怎么验**：往 tmds_serializer 里临时加 `reg dbg; always @(posedge serial_clk) dbg <= blue[0];` ⇒ 重跑 PnR ⇒ 断言那句 `No timing paths…` 消失（即门报警）。撤掉后恢复。
- **来源**：TORCH-4【P1-2】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-3|MOD=rtl/top.v
### 让 span 忙时的 'S' 回 '!' 而不是 's'
- **位置**：rtl/top.v:1970-1971、:2433-2444、:2253、:2355-2370、:2373；rtl/w3a/calib_span.v:336-345、:247；tb/w3c/tb_span_axis_over_uart.log（对应 tb）
- **现状**：
```verilog
// rtl/top.v:1970-1971
wire       sp_start_gated = cmd_span_req & at_done;        // ⚠️ 没有 ~sp_busy
wire       sp_start_rejected = cmd_span_req & ~at_done;
// rtl/top.v:2253
.start_i       (sp_start_gated),
// rtl/top.v:2433-2444（优先级：ev_need > ev_reject > ev_axis_ok > ev_done > sp_start_rejected > … > cmd_span_req）
wire rep_req = … | cmd_span_req | …;
wire [7:0] rep_byte = ev_need ? axis_char : ev_reject ? rej_why_byte : ev_axis_ok ? 8'h2E
                    : ev_done ? 8'h44 : sp_start_rejected ? 8'h21
                    : (at_done & ~at_done_r) ? 8'h54
                    : cmd_tare_req ? 8'h74 : cmd_span_req ? 8'h73   // 's' = 受理 span
                    : …;
// rtl/w3a/calib_span.v:336-345 —— start_i 只在 S_IDLE 被采样
S_IDLE: begin
    need_press_o <= 1'b0;
    done_o       <= 1'b0;
    if (start_i) begin … state <= S_PROMPT; end
end
```
- **为什么是问题**：span 进行中（`state != S_IDLE && state != S_DONE`，`busy_o=1`）时 `at_done` 仍为 1 ⇒ `sp_start_rejected = 0` ⇒ 仲裁链落到 `cmd_span_req ? 8'h73` ⇒ 回 's'（"已受理"）；而 calib_span 此刻不在 S_IDLE ⇒ `start_i` 被完全忽略 ⇒ 操作者以为"重新开始标定了"，实际还在标上一轮（可能已经标到第 9 轴）。`busy_o` 的定义在 calib_span.v:247：`assign busy_o = (state != S_IDLE) && (state != S_DONE);`
- **改法**（1 行，把"忽略"变成"明拒"）：
```verilog
wire sp_start_gated    = cmd_span_req & at_done & ~sp_busy;   // 忙 ⇒ 不放行
wire sp_start_rejected = cmd_span_req & (~at_done | sp_busy); // 忙 ⇒ 回 '!'
```
⚠️ 必须用组合的 `sp_busy`（不是 `sp_busy_r`）：这里的 `sp_busy` 只用于生成回包，不进 `cal_ch_mux` ⇒ 不会复活 rtl/top.v:2355-2370 记录的那个跨模块组合环。（`cal_ch_mux` 那一处必须继续用 `sp_busy_r`，rtl/top.v:2373 不动。）
- **预期**：收益 = 控制面不再说谎（与 P0-1 同类）；代价 = 1 行、0 资源。
- **怎么验**：tb/w3c/tb_span_axis_over_uart.log 对应的 tb 里加：发 'S' → 在收到第一个轴号后立刻再发一个 'S' → 断言第二个回包是 '!'（而不是 's'）。现在必然红。
- **来源**：TORCH-4【P1-3】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-4|MOD=rtl/top.v
### 把"参与标定的片数"与"实际片数"拆成两个参数
- **位置**：rtl/top.v:1676、:1678、:2010、:1975、:2228、:2536、:1870、:1946、:2229、:2003-2009；rtl/w3a/calib_autotare.v:96、:195-205
- **现状**：
```verilog
// rtl/top.v:1676
localparam integer ADC_N = (RIGHT_ADC_ENABLE != 0) ? 3 : 2;
// rtl/top.v:1678
wire [ADC_N*12-1:0] af_data;      // ADC_N=3 时是 36 位
// rtl/top.v:2010 —— 接到只有 24 位的端口
.sample_data_i (af_data[ADC_N*12-1:0]),
// rtl/w3a/calib_autotare.v:96
input  wire [N_ADC*DW-1:0] sample_data_i,      // N_ADC=2, DW=12 ⇒ 24 位
// rtl/top.v:1975 / 2228 / 2536 —— 三处都把片数写死 2
calib_autotare #( … .N_ADC    (2), … )
calib_span     #( … .N_ADC      (2), .AXIS_TOTAL (16), … )
axis_snapshot  #( … .N_ADC  (2), … )
```
- **为什么是问题**：`ADC_N=3` 时 `af_data` 是 **36 位**，而 `sample_data_i` 只有 **24 位** ⇒ 高 12 位（片 2）被静默丢弃（Verilog 的端口连接是按表达式宽度截断，工具顶多给一条宽度警告，不是 ERROR）⇒ 正是 K-91 家族"宽度不够 ⇒ 静默算错"。实际后果：片 2 的"静止守卫"数据恒为 0 ⇒ calib_autotare 的 `still_r` 判据看不到片 2（calib_autotare.v:195-205 逐片比较）⇒ 与 rtl/top.v:2003-2009 注释声称的"必须给【全部片】"正好相反。`N_ADC` 三处硬编码 2 ⇒ 片 2（右手板 A）永远不会被 tare/span/快照；`at_tare` 只有 2 位（rtl/top.v:1870），`sp_span` 只有 2 位（:1946）⇒ RIGHT_ADC_ENABLE=1 档下，右手板的模拟量走的是未标定的裸码（right_analog_ctrl 自己做 64 点对数 LUT，所以"能用"，但没有零点/满量程归一）。
- **改法**：
```verilog
// ① 宽度：显式截到接收方宽度（把"静默"变成"显式"，并让注释与代码一致）
.sample_data_i (af_data[N_ADC_DATA*12-1:0]),   // 其中 localparam N_ADC_DATA = 2; 并加注释说明片 2 不走标定
// ② 片数：把三处 2 换成同一个 localparam，并加编译期自检
localparam integer N_ADC_CAL = 2;              // ⭐ 参与标定的片数（≠ ADC_N）
calib_autotare #( … .N_ADC(N_ADC_CAL), … )
calib_span     #( … .N_ADC(N_ADC_CAL), … )
axis_snapshot  #( … .N_ADC(N_ADC_CAL), … )
initial if (N_ADC_CAL > ADC_N)
    $fatal(1, "N_ADC_CAL(%0d) > ADC_N(%0d) => 标定片数超过实际片数", N_ADC_CAL, ADC_N);
```
⚠️ 不要直接把 `N_ADC` 全改成 `ADC_N`：那会把 calib_span 的 `AXIS_TOTAL`（= `NCH × N_ADC`，:2229 传 16）与 axis_snapshot 的 16 轴口径一起改坏。先把"参与标定的片数"与"实际片数"拆成两个参数，再决定片 2 要不要进标定。
- **预期**：收益 = 消掉一处静默截断 + 把"片 2 不标定"从隐含变成显式；代价 = 0 逻辑（都是 localparam/注释）。
- **怎么验**：新增 tb 例化 `top #(.RIGHT_ADC_ENABLE(1))`，断言 `$bits(dut.g_sound.af_data) == 36` 且 `dut.g_sound.u_autotare.sample_data_i` 的最高 12 位能反映片 2 的输入（喂一个片 2 特有的码，看守卫是否看见）。现在必然红（高 12 位恒 0）。
- **来源**：TORCH-4【P1-4】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-5|MOD=rtl/top.v
### 把 RESERVED_N 收成单一来源并把 cfg_warn 接进心跳灯
- **位置**：rtl/top.v:1537、:1613、:4013、:4308、:4409、:1523、:1564、:1601、:1654、:4306-4307
- **现状**：
```verilog
// 五处【独立字面量】5 —— 只有 PERC_N 有名字
// :1537  metronome       .RESERVED_N (5),
// :1613  drum_gen        .RESERVED_N (5),
// :4013  note_manager    .RESERVED_N  (5),
// :4308  localparam integer PERC_N   = 5;
// :4409  tdm_render_mixer .RESERVED_N          (5),
// 自检输出（都只被例化端口引用一次）
// :1523 wire        met_cfg_warn;   :1564 .cfg_warn_o     (met_cfg_warn)
// :1601 wire        drm_cfg_warn;   :1654 .cfg_warn_o     (drm_cfg_warn)
// rtl/top.v:4306-4307（原文注释）
//  ⚠️ 下面这个 5 **必须**与 `u_note_manager` / `u_tdm_render_mixer` 的 `.RESERVED_N(5)` 一致（⭐ 三处同源…）
```
- **为什么是问题**：`RESERVED_N` 决定最高 5 路 voice 是保留池（note_manager 的 `pool_mask`、`PERC_N` 的打击包络替换、tdm_render_mixer 的归一化 `NORMAL_N = POLY_TARGET - RESERVED_N` 三处必须同值）。现在它被写成 5 个互不相关的字面量；注释说"三处同源"，实际是五处。更糟：metronome/drum_gen 各自带一个 `cfg_warn_o`（专门检查 `AXIS_ID` 与 `RESERVED_N` 是否配套），而这两根线在 top.v 里没有任何消费者（`grep -c` = 2）⇒ **"专门为防静默失效而加的自检，本身是静默的"**。
- **改法**：
```verilog
// 模块级，参数表之后
localparam integer RESERVED_N = 5;   // ⭐ 单一来源
localparam integer PERC_N     = RESERVED_N;   // :4308 改为派生
// 五处例化统一写 .RESERVED_N (RESERVED_N)
// 自检消费（二选一）：
wire cfg_warn_any = met_cfg_warn | drm_cfg_warn;
assign fault_any_w = (|af_fault) | mx_fault | cfg_warn_any;
```
- **预期**：收益 = 改一处即全动，且配错会在上板可见（快闪）；代价 = 0（一个 localparam + 一个 OR）。
- **怎么验**：临时把 note_manager 的 `.RESERVED_N` 改成 4（其余不动），断言 (a) `met_cfg_warn`/`drm_cfg_warn` 至少一个为 1，(b) 心跳灯进入快闪档。现在 (b) 必然不成立（线没人读）；改完成立。
- **来源**：TORCH-4【P1-5】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-6|MOD=impl/pnr/Gowin2026.rpt.txt,sim/gowin_build.ps1,rtl/top.v
### 把 LW 8/8 饱和与 clk_d 扇出 16957 登记成容量红线
- **位置**：impl/pnr/Gowin2026.rpt.txt:91-99、:103-119；impl/pnr/Gowin2026.log（PR1014 原文）；impl/pnr/Gowin2026_tr_content.html（High Fanout Nets）；sim/gowin_build.ps1
- **现状**：
```
5. Clock Resource Usage Summary
  PRIMARY       | 2/8           | 25%
  LW            | 8/8           | 100%     ← 🔴 饱和
  GCLK_PIN      | 10/40         | 25%
  PLLA          | 1/8           | 13%
6. Global Clock Signals
  clk_d               | PRIMARY | TR BR BL
  u_hdmi/pixel_clk    | PRIMARY | TR BR
  rst_n_sync          | LW      | -
  tick_audio          | LW      | -
  u_hdmi/reset_pipe[1]| LW      | -
  g_sound.u_calib_span/n1750_4 | LW | -
  g_sound.u_looper/n102894_4   | LW | -
  g_sound.u_looper/n104690_3   | LW | -
  g_sound.u_looper/pb_ax_3_8   | LW | -
  g_sound.u_evt_merge/pop_now  | LW | -
  u_hdmi/serial_clk   | HCLK    | BANK3_BANK4_BANK5_HCLK0
WARN  (PR1014) : Generic routing resource will be used to clock signal 'clk_d' by the specified
                 constraint. And then it may lead to the excessive delay or skew
High Fanout Nets Report:  clk_d | FANOUT 16957 | WORST SLACK 0.102 | MAX DELAY 3.316
                          rst_n_sync | FANOUT 13958 | WORST SLACK 5.596 | MAX DELAY 3.020
                          tick_audio | FANOUT  1415 | WORST SLACK 9.254 | MAX DELAY 2.953
Arrival Clock Path Delay: cell 1.288 (31.105%) · route 2.854 (68.895%)
```
- **为什么是问题**：`clk_sys` 有 **16957** 个 FF 负载，分布在 TR/BR/BL 三个象限；主全局时钟网喂不满 ⇒ Gowin 用通用布线补（PR1014）⇒ 时钟插入延迟 **4.142 ns，其中 2.854 ns 是走线**。实测各分支插入差：头号路径的捕获 FF 是 4.142 ns，而 hold 报告里 `u_looper/mem_*_s/CLKB` 是 **2.367 ns** ⇒ **跨分支时钟偏斜 ≈ 1.8 ns = 预算的 10%**（每条路径的 slack 已含它，但 Fmax 那个数不含）。`LW`（长线）资源 **8/8 = 100%** 被 `rst_n_sync`（13958 扇出）与 `tick_audio`（1415）这类本不该占时钟资源的信号吃掉 ⇒ 再加一个高扇出信号，工具就必须把某个现有信号踢到通用布线 ⇒ 时序会不可预测地跳。这就是"布局噪声"的真正注入点。
- **改法**（按性价比排序）：1. 降 `rst_n_sync` 的扇出（13958 ⇒ 分域/分级缓冲）：它是同步复位，13958 个负载放在一根 LW 线上既占资源又造成 3.020 ns 的到达延迟；最省事的做法在 top.v 里把 rst_n_sync 打一拍生成区域副本没有意义（同网），真正有效的是把部分模块的复位改成"门控时钟使能"或用局部同步复位 —— ⚠️ 这是大改，本轮不做，只登记。2. 把 `tick_audio` 从 LW 上摘下来：它是时钟使能，不是时钟；现在它被工具提升成时钟网（1415 扇出）；可试的做法是在 .cst/综合属性上禁止提升（Gowin 支持 syn_keep/CLK 属性），或把它改成局部再生的使能（每个消费模块自己用 10 位计数器产生），从根上消掉高扇出。3. 登记为"容量红线"：把 `LW 8/8` 与 `PRIMARY 2/8` 写进 sim/gowin_build.ps1 的判据里（利用率 ≥ 100% 即 WARN，且任何新增时钟类信号必须重跑并对比 Fmax）。
- **预期**：收益 = 把"改一处 → Fmax 乱跳"变成"可解释、可预警"；代价 = 3 是 0 成本；1/2 是中改（有回归风险，建议单独一轮）。
- **怎么验**：在 top.v 里临时加一个 `reg [9:0] dummy; always @(posedge clk) dummy <= dummy+1;` 并把 `dummy[0]` 引到一个新的 `(* syn_keep *)` 高扇出网（模拟"再加一个时钟类信号"）⇒ 重跑 PnR ⇒ 断言 LW 利用率与 `clk_d` 的 MAX DELAY 必须变化（说明红线是真的）。
- **来源**：TORCH-4【P1-6】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-7|MOD=tb/w3b/tb_p5_osc_equiv.sv,tb/models/oscillator_bank_ref.v
### 把逐位等价 tb 的参数改成生产档并加参数一致性断言
- **位置**：tb/w3b/tb_p5_osc_equiv.sv:65-68、:81-90、:190-193；tb/models/oscillator_bank_ref.v:192、:281-300；rtl/top.v:4205-4206；rtl/w3b/oscillator_bank.v:183-184、:204、:400-405、:414、:417、:314-333
- **现状**：
```verilog
// tb/w3b/tb_p5_osc_equiv.sv:65-68（ref）与 :81-90（dut）—— 两侧【同参数】
.DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(2),
.DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(15_000_000),
.DRUM_CLICK_EN(0)                       // ⚠️ ref 的参数表就到此为止（无 DRUM_CLS_EXT）
// tb/w3b/tb_p5_osc_equiv.sv:190-193（激励 C，注释写着"扫频是本次搬动的重点"）
base_inc[0] = 32'd5_368_709;     // 底鼓
base_inc[1] = 32'd17_895_697;    // 嗵鼓   ← ⚠️ 17.9M ≥ 15M ⇒ 既不是 kick 也不是 tom！
base_inc[2] = 32'd17_179_869;    // 军鼓
base_inc[3] = 32'd171_798_691;   // 踩镲
// rtl/top.v:4205-4206（生产档覆盖）
.DRUM_TOM_MAX     (20_000_000),
.DRUM_TOM_SWEEP_SH(3),
// rtl/w3b/oscillator_bank.v:183-184（模块默认）
parameter integer DRUM_KICK_MAX     = 10_000_000,
parameter integer DRUM_TOM_MAX      = 15_000_000,
```
- **为什么是问题**：分类判据（rtl/w3b/oscillator_bank.v:400-405）：`is_kick = bv < 10M`、`is_tom = 10M ≤ bv < 15M`（tb 档）。激励 C 的嗵鼓 `17_895_697 = 17.9M ≥ 15M` ⇒ `is_kick=0 && is_tom=0` ⇒ `sweep_load = 0`（:417）⇒ 这一 lane 根本不扫频。4 条 lane 里只有 lane 0（底鼓 5.37M）真的走扫频 ⇒ **`DRUM_TOM_SWEEP_SH` 这条算术分支在逐位等价 tb 里一次都没执行过**。生产档用的是 `DRUM_TOM_MAX=20M`/`DRUM_TOM_SWEEP_SH=3` ⇒ 交付档的嗵鼓扫频（17.9M 落进 [10M,20M) ⇒ 会扫，深度 `>>11`）从来没有与 ref 比对过。tb/models/oscillator_bank_ref.v 确实同步了颤音流水（026ed21，:281-300，与 rtl/w3b/oscillator_bank.v:314-333 逐字对应）⇒ 这一处已经对了；但 ref 没有 `DRUM_CLS_EXT`/`drum_cls_i`（参数表末尾是 `DRUM_CLICK_EN`，oscillator_bank_ref.v:192）⇒ 生产档 `.DRUM_CLS_EXT(1)` 的路径只能靠 tb_osc_drum_cls.sv 的功能判据，没有逐位等价判据。
- **改法**（三处，都便宜）：
```verilog
// ① tb_p5_osc_equiv.sv：把两侧参数改成【生产档】，并把激励 C 的嗵鼓放进 20M 档
.DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(3),
.DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(20_000_000),
// ② 加一条"参数一致性断言"：dut 与 ref 的 4 个鼓参数必须逐字相等（现在靠人眼看）
initial begin
    if (u_dut.DRUM_TOM_MAX !== u_ref.DRUM_TOM_MAX ||
        u_dut.DRUM_TOM_SWEEP_SH !== u_ref.DRUM_TOM_SWEEP_SH)
        $fatal(1, "drum params diverge: ref=(%0d,%0d) dut=(%0d,%0d)",
               u_ref.DRUM_TOM_MAX, u_ref.DRUM_TOM_SWEEP_SH,
               u_dut.DRUM_TOM_MAX, u_dut.DRUM_TOM_SWEEP_SH);
end
// ③ 给 ref 补 DRUM_CLS_EXT/drum_cls_i（与 RTL 同步），并新增一档激励：
//    对 dut 传 .DRUM_CLS_EXT(1) + 手写 drum_cls_i，ref 用参数化等价路径
```
⚠️ 纪律（写进 tb 头部注释）：tb/models/*_ref.v 是"基线副本"，凡改动被测模块的算术或参数语义，必须同步 ref 并同步 tb 的参数，否则逐位等价会变成假红（参数不同）或假绿（两侧同源、一起错）。
- **预期**：收益 = 把交付档真正跑的那条扫频算术纳入逐位等价保护；代价 = tb 跑得稍慢（多一条 lane 参与扫频），无 RTL 改动。
- **怎么验**：把 rtl/w3b/oscillator_bank.v:414 的 `bv >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH)` 改成 `bv >> DRUM_SWEEP_LSB_SH`（去掉嗵鼓深度）⇒ 现在必须仍然绿（证明未覆盖），改完 tb 后必须红。
- **来源**：TORCH-4【P1-7】
@@@END
@@@PRIO=P1|SRC=TORCH-4|ORIG=P1-8|MOD=rtl/top.v,sim/gowin_build.ps1
### 给 g_silent 档补齐无驱动网并把该档纳入综合门
- **位置**：rtl/top.v:1235-1268、:1723-1728、:1719、:4789；constr/top.cst:208-272；sim/gowin_build.ps1
- **现状**：
```verilog
// rtl/top.v:1235-1268 —— g_silent 里的【全部】assign，逐条列全：
assign pp_push = 1'b0;              assign pp_data = 8'h00;
assign scope_sample = 24'sd0;       assign scope_valid = tick_audio;
assign sample_mono = {SAMPLE_W{1'b0}};
assign tx_req  = 1'b0;              assign tx_byte = 8'h00;
assign led_blink = 1'b0;            assign led_beat = 1'b0;
assign led_gear_st = 2'd3;          assign led_looper_st = 2'd0;
// ⛔ 没有：spi_sclk / spi_mosi / spi_cs_n[*] / fault_any_w
// rtl/top.v:1723-1728（只有 g_sound 里有）
assign spi_sclk = af_sclk[0];   assign spi_mosi = af_mosi[0];
assign spi_cs_n[ADC_N-1:0] = af_cs_n;   assign spi_cs_n[5:ADC_N] = {(6-ADC_N){1'b1}};
// rtl/top.v:1719（只有 g_sound 里有）
assign fault_any_w = (|af_fault) | mx_fault;
// rtl/top.v:4789（两个分支都要读）
else if (fault_any_w)    fault_sticky <= 1'b1;
```
- **为什么是问题**：`DEMO_CHORD_ON=0` ⇒ `g_silent` ⇒ **8 个输出脚无驱动**（`spi_sclk` `spi_mosi` `spi_cs_n[5:0]`，而 constr/top.cst:208-272 把这 8 根全部做了 IO_LOC）+ **1 个内部网无驱动**（`fault_any_w`）。仿真里：`spi_*` 是 z（tb_top_m0 不看它们，所以不会红）；`fault_any_w` 是 z ⇒ `if (z)` 为假 ⇒ 心跳走慢闪 ⇒ 看起来完全正常。综合里：无驱动的输出网要么被接 0 要么报 CV/EX 警告；`fault_any_w` 的 z 会被当 0 ⇒ `fault_sticky` 在该档永远为 0 ⇒ "有故障 ⇒ 快闪"这个语义在该档结构性失效。关键：**13 个 tb 覆盖 `DEMO_CHORD_ON`，但 `g_silent` 这一支从来没有被综合过**（sim/gowin_build.ps1 只跑默认参数）⇒ 综合门没见过这一档。
- **改法**：
```verilog
// g_silent 里补齐（与 g_sound 同语义的"安全常量"）
assign spi_sclk   = 1'b0;                    // ⭐ SPI 空闲（SCLK 低）
assign spi_mosi   = 1'b0;
assign spi_cs_n   = 6'b111111;               // ⭐ CS 高 = 全部不选中
assign fault_any_w = 1'b0;                   // ⭐ 该档没有 ADC/mixer ⇒ 无故障源
```
并且把 `g_silent` 纳入综合门：sim/gowin_build.ps1 增加一次 `-DEMO_CHORD_ON 0` 的综合-only（不跑 PnR，省 10 分钟）跑，判据 `ERROR=0`。
- **预期**：收益 = M0 安全档从"只在仿真里成立"变成"综合层也成立"；代价 = 4 行 assign + 一次综合（~1 分钟）。
- **怎么验**：现在对 `g_silent` 跑一次综合 ⇒ 必然出现无驱动/未约束告警；补齐后消失。仿真侧可加断言：tb_top_m0 里 `$display("%b", dut.spi_cs_n)` 应为 `6'b111111`（现在是 `zzzzzz`）。
- **来源**：TORCH-4【P1-8】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-1|MOD=rtl/top.v
### 把 60+ 条死线的注释改成实话并加死线白名单
- **位置**：rtl/top.v:1324-1327、:3585-3586、:1325 及全文件；sim/gowin_build.ps1
- **现状**：
```verilog
// rtl/top.v:1324-1327（注释）
//      ⚠️ 未引到引脚 ⇒ ⭐ 综合时**不要**被优化掉：⭐ 它驱动的是寄存器树
//         （⭐ 与 `mg_*` 那组同一手法）⇒ ⭐ 会保留，⭐ 上板可用调试核读。
wire [$clog2(POLY_TARGET):0]   mx_n_active;
// rtl/top.v:3585-3586（注释）
//  ⭐ 可观测（`K-106`：⛔ 不许静默失效）—— ⚠️ **暂未接上板观测口**
//     📌 待办：⭐ 接到串口回传 … ⇒ 现在先留线，⛔ 不悬空
wire        looper_full;  wire [15:0] looper_drop_cnt;  wire looper_overflow;
```
- **为什么是问题**：对 top.v 逐名 `grep -c`，命中数 = 2（= 声明 + 例化端口）的可观测性线共 **60+ 条**：`event_extract`（`ee_ovf` `ee_lost` `ee_slide_v` `ee_two_v` `ee_slide_ax` `ee_slide_dir` `ee_2a` `ee_2b`）；`seq_arb`（`sa_overflow` `sa_drop_cnt` `sa_collision_cnt` `sa_merged_cnt` `sa_live_cnt` `sa_score_cnt` `sa_demo_cnt`）；`evt_merge`（`mg_overflow` `mg_drop_cnt` `mg_collision_cnt` `mg_merged_cnt`）；`uart_tx_fifo`（`txf_ovf` `txf_drop`）；`looper`（`looper_full` `looper_drop_cnt` `looper_overflow` `looper_evt_cnt` `looper_layer_state`）；`tdm_render_mixer`/`oscillator_bank`（`mx_n_active` `ob_phase_dbg`）；`vibrato_lfo`（`vibrato_rate_inc` `vibrato_phase` `vibrato_active`）；`metronome`/`drum_gen`（`met_beat_cnt` `met_accent_cnt` `drm_evt_cnt` `drm_step_cnt` `drm_hit_cnt` `drm_step_evt_cnt` `met_cfg_warn` `drm_cfg_warn`）；`perc_env_bank`（`perc_retrig_cnt` `perc_busy` `perc_active`）；`calib*`（`cal1_ch` `cal1_vld` `at_fail`）；`uart_ui`（`ui_tx_start` `ui_tx_data` `ui_frame_cnt` `ui_resync_cnt` `ui_err_cnt` `ui_hb_ready` `ui_fx_en` `ui_fx_sel`）；`calib_cmd`/`evt_uart_rx`（`cmd_cnt` `cmd_in_frame_cnt` `cmd_resync_cnt` `cmd_unknown_cnt` `cmd_idx` `eu_frame_cnt` `eu_resync_cnt` `eu_hdr_err_cnt` `eu_drop_cnt` `eu_idx` `eu_synced`）；probe（`pp_busy` `np_busy` `vp_busy` `dp_busy`）；LED（`led_busy`）。结论：top.v:1325 那句"它驱动的是寄存器树 ⇒ 会保留"不成立 —— 没有消费者的寄存器没有保留的理由，工具会剪。所以"先留线"不等于"可观测"（rtl/top.v:3586 的注释自己写了"暂未接上板观测口"，但那句"⛔ 不悬空"是误导）。
- **改法**：与 P0-4 同一处方 —— 至少把"丢事件/溢出"那一类（`ee_*`/`sa_*`/`mg_*`/`txf_*`/`looper_*`）接进一个可读的口（'V' 回包多 1 字节，或心跳灯故障位）。其余纯调试计数器允许被剪掉，但必须把注释改成实话（"未接观测口 ⇒ 会被综合剪掉，要用时再引"），否则下一个人会以为它在网表里。
- **预期**：收益 = 注释不再骗人 + 关键计数器真的能读；代价 = 见 P0-4。
- **怎么验**：`grep -c` 的判据可以机械化：在 sim/gowin_build.ps1 里对 top.v 跑一次"凡 wire 声明且只出现 2 次的名字，必须出现在一张已知死线白名单里"，白名单外的出现即 WARN。这样新增死线会被立刻发现。
- **来源**：TORCH-4【P2-1】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-2|MOD=rtl/top.v
### 把 rep 回执拆成两个请求源让 FIFO 排队
- **位置**：rtl/top.v:2433-2447、:1123、:2470-2476；tb（span/uart 链）
- **现状**：
```verilog
wire rep_req  = ev_need | ev_reject | ev_axis_ok | ev_done
              | cmd_tare_req | cmd_span_req | cmd_abort_req | cmd_test_mode_req
              | sp_start_rejected | (at_done & ~at_done_r) | cmd_keydrum_req;
wire [7:0] rep_byte = ev_need          ? axis_char        // ①
                    : ev_reject        ? rej_why_byte      // ②
                    : ev_axis_ok       ? 8'h2E             // ③ '.'
                    : ev_done          ? 8'h44             // ④ 'D'
                    : sp_start_rejected? 8'h21             // ⑤ '!'
                    : (at_done & ~at_done_r) ? 8'h54       // ⑥ 'T'
                    : cmd_tare_req     ? 8'h74             // ⑦ 't'
                    : cmd_span_req     ? 8'h73             // ⑧ 's'
                    : cmd_test_mode_req? tm_reply_byte
                    : cmd_keydrum_req  ? 8'h6B
                    :                    8'h78;            // 'x'
```
- **为什么是问题**：仲裁器每拍只推 1 字节（`u_tx_fifo` 的 `push_i(tx_req)` 是单拍）。若 `cmd_span_req` 与 `ev_axis_ok`（轴标定通过）同拍（窗口 = 1 clk = **20 ns**），`rep_byte` 选 ③ '.' ⇒ **'s' 受理回执永久丢失**（`rep_req` 是 OR，两件事都请求了，但字节只有一个）。同类可被吃掉的还有 't'（被 ①②③④⑤⑥ 吃）、'x'（被 ①~⑨ 吃）、'k'（被 ①~⑩ 吃）。概率极低（20 ns / 人按键毫秒级），但后果是"发 'S' 没回执 ⇒ 操作者再发一次"，而"再发一次"正好撞上 P1-3（忙时回 's' 但被忽略）⇒ 两次都以为成功了。
- **改法**：把 `rep_*` 也做成小 FIFO（与 `u_tx_fifo` 同构，深度 4），即"事件到达即入队，出队再发"。`u_tx_fifo` 已经存在且深度 8（rtl/top.v:1123），最小改法是把 `rep_req/rep_byte` 那一段的"每拍选一个"换成"两个都入队"：
```verilog
assign tx_req  = rep_ev_req | rep_cmd_req | pp_push | vp_push | np_push | …;
assign tx_byte = rep_ev_req ? rep_ev_byte
               : rep_cmd_req ? rep_cmd_byte
               : np_push ? np_data : … ;
```
（`rep_ev_*` = ①②③④⑥；`rep_cmd_*` = ⑤⑦⑧⑨⑩⑪。两组结构上很少同拍，真正同拍时 FIFO 会排队 ⇒ 一个都不丢。）
- **预期**：收益 = 回执不再丢；代价 = 极端情况下回包顺序变化（'s' 可能晚 1 字节 = 20 µs）。
- **怎么验**：写一个 tb 用 `force` 让 `cmd_span_req` 与 `sp_done_cnt` 变化同拍，断言串口同时收到 '.' 与 's'（顺序不限）。现在必然只收到 '.'。
- **来源**：TORCH-4【P2-2】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-3|MOD=rtl/top.v,rtl/w3c/uart_ui.v
### 决定 uart_ui 的发送通路接上还是删掉
- **位置**：rtl/top.v:918-919、:920-921、:885-887、:2470-2476；rtl/w3c/uart_ui.v:76-77
- **现状**：
```verilog
// rtl/top.v:918-921
.tx_busy_i     (1'b1),       // 本版只接收屏的控制帧
.tx_done_i     (1'b0),
.tx_start_o    (ui_tx_start),
.tx_data_o     (ui_tx_data),
// rtl/w3c/uart_ui.v:76-77 —— 这两个端口在模块内【只出现在声明行】
input  wire        tx_busy_i,          // ⭐ tx 忙（⛔ 别喂新字节）
input  wire        tx_done_i,          // ⭐ tx 发送完成（单周期脉冲）
```
- **为什么是问题**：`grep` 全文，`tx_busy_i`/`tx_done_i` 各只命中 1 次（就是声明行）⇒ 硬接 1'b1/1'b0 今天不影响行为（所以不是 P0）；但 `ui_tx_start`/`ui_tx_data` 命中 2 次（声明 + 端口）⇒ 没有接到 `u_tx_fifo` ⇒ **串口屏永远收不到任何回传**。这意味着"屏上显示状态"这条路完全没接，而 rtl/top.v:885-887 的注释只说"本版只接收屏的控制帧" ⇒ 没有写"屏收不到任何东西"。
- **改法**：二选一 —— ① 把 `ui_tx_start`/`ui_tx_data` 接进 `u_tx_fifo` 的 `push_i`/`data_i`（与 `pp_push`/`vp_push` 同构，rtl/top.v:2470-2476 的仲裁器加一路）；② 若确认不要屏回传，删掉这 4 个端口连接并把注释改成"屏的发送通路未接，屏上不会有任何回显"。
- **预期**：① 收益 = 屏可用；代价 = 多一路仲裁（注意 P2-2 的排队问题）。② 收益 = 注释不再误导；代价 = 0。
- **怎么验**：现有 sim/evidence/tb_uart_ui.log 对应的 tb 只验了"收"。加一条：发一个需要回包的屏帧 ⇒ 断言 `dut.uart_tx` 上有波形。现在必然红。
- **来源**：TORCH-4【P2-3】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-4|MOD=rtl/top.v
### 逐条改正 6 处注释↔代码不一致并把 OUTPUT_HEADROOM_SH 提成参数
- **位置**：rtl/top.v:67、:72、:1341、:3776-3779、:3798-3801、:3808、:3810-3813、:1627-1629、:4306-4307、:4413；rtl/w3c/drum_gen.v:161-167
- **现状**：
```
| # | 位置 | 注释说 | 代码是 | 后果 |
| 1 | rtl/top.v:67 vs :72 | "`1`（默认，诊断码流）" | `TEST_MODE_EN = 0` | 见 P0-1（控制面说谎） |
| 2 | rtl/top.v:1341 vs :72 | "默认值保持 1" | `= 0` | 同上 |
| 3 | rtl/top.v:3776-3779 | 表：`2'd0`=嗵鼓 `12_884_902` · `2'd1`=底鼓 `6_442_451` · `2'd2`=军鼓 `17_179_869` · `2'd3`=踩镲 `171_798_691` | `:3798-3801`：`17_895_697` / `5_368_709` / `42_949_673` / `171_798_691` | 🔴 整张表过期。✅ 但代码与 rtl/w3c/drum_gen.v:161-167 的 `INC_*` 逐字一致（已逐条核）⇒ 是注释错，不是逻辑错 |
| 4 | rtl/top.v:3808 | "参照鼓机的 `VEL_*`（底鼓 230 / 军鼓 200 / 嗵鼓 190 / 踩镲 140）" | `:3810-3813`：`200/230/210/175`；而 top 又把鼓机覆盖成 `SNARE 235 / HIHAT 175 / TOM 220`（`:1627-1629`） | 三套数并存 ⇒ 调音时按注释改会改错对象 |
| 5 | rtl/top.v:4306-4307 | "三处同源" | `RESERVED_N` 实为五处 | 见 P1-5 |
| 6 | rtl/top.v:4413 | （任务书/交接把它列为"编译期参数 `OUTPUT_HEADROOM_SH`"） | `.OUTPUT_HEADROOM_SH  (1)` 是字面量，`top` 没有这个参数 | 🔴 A/B 对比必须改源码，不能靠构建参数 ⇒ 与"编译期可切"的说法不符 |
```
- **为什么是问题**：本项目已裁定"代码就是地面真相"（AGENTS.md §五⑤）；六处注释与代码不符，其中第 3 处整张映射表过期、第 4 处三套音量数并存，都会让下一个人"照注释改错"。
- **改法**：逐条按"代码为准"改注释。第 6 条建议真的提成参数：
```verilog
parameter integer OUTPUT_HEADROOM_SH = 1,   // ⭐ −6.02 dB；0 = 不衰减
…
.OUTPUT_HEADROOM_SH  (OUTPUT_HEADROOM_SH)
```
- **预期**：收益 = 消掉一整类"照注释改错"的事故；代价 = 0（第 6 条多 1 个参数 = 1 个新变异点）。
- **怎么验**：把 tb/w3c/tb_drum_timbre_top.sv 或 tb_key_drum.sv 里"鼓机 INC 常量"的比对改成从 drum_gen 里读 `INC_*`（现在 tb_key_drum 已经这么做 ✅）⇒ 然后断言 top.v 注释里的 4 个数与 `u_drum_gen.INC_*` 相等 ⇒ 注释错会红。（注释级的判据可以用一条 grep 做，不必等仿真。）
- **来源**：TORCH-4【P2-4】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-5|MOD=rtl/top.v
### 给 reserved_in_xor 的 7 根异步输入补同步
- **位置**：rtl/top.v:4898-4906、:4885-4887
- **现状**：
```verilog
(* syn_keep = 1 *) wire reserved_in_xor = ^{ctrl_col_i, enc_a_i, enc_b_i, enc_sw_i,
                                            pedal_loop_rec_i,
                                            pedal_loop_play_i, esp_uart_rx_i};
(* syn_keep = 1 *) reg  reserved_in_r;
always @(posedge clk) begin
    if (!rst_n_sync) reserved_in_r <= 1'b0;
    else             reserved_in_r <= reserved_in_xor;
end
```
- **为什么是问题**：这 7 根是板外异步输入（.cst 全部 PULL_MODE=UP），异或树的输出直接进 1 个 FF ⇒ 该 FF 会亚稳态（无 2 级同步）。今天无害：`reserved_in_r` 命中 2 次（声明 + 赋值）⇒ 无人读 ⇒ 会被剪。但它是"为了让脚活着"而故意保留的（syn_keep）⇒ 在时序/CDC 检查里会留一条噪声路径，且下一个人接入真逻辑时会顺手用这根没同步的线（注释里正好写着"接入功能逻辑时把它从异或归并里摘掉"，但没人提醒"这根线本身没同步"）。
- **改法**：把 `reserved_in_r` 换成"每根输入各过一个 `sync_input` 再异或"（7 × 2 = 14 个 FF，成本可忽略），或至少在注释里写明"本网仅用于让脚进网表，⛔ 不可当数据用（无同步器）"。
- **预期**：收益 = 消掉一个未来会踩的坑 + 少一条 CDC 噪声；代价 = 14 FF（本器件 60780 ⇒ 0.02%）。
- **怎么验**：把 `reserved_in_xor` 的某一根输入在 tb 里异步翻转 1000 次，断言 `reserved_in_r` 的采样子序列不出现 x。现在可能出 x（亚稳态传播）。
- **来源**：TORCH-4【P2-5】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-6|MOD=rtl/top.v,rtl/w3c/led_data.v
### 记档 led_data 被 swept 并接上 key_active_i
- **位置**：rtl/top.v:4832-4844、:4819-4820；rtl/w3c/led_data.v；sim/evidence/final-batch-20261008/rsc.xml；sim/evidence/final-batch-20261008/Gowin2026.log
- **现状**：
```verilog
led_data #(.KEY_N(16), .STATUS_N(8)) u_led_data (
    .guide_key_i     (16'd0),            // ⭐ 占位：待 play_seq（甲）
    .key_active_i    (16'd0),            // ⭐ 占位：待 event_extract.key_on（甲）
    .status_i        (8'd0),             // ⭐ 占位：待 UI 状态总线
    .blink_i         (led_blink),        // ⭐ 四分音符拍点
    .pattern_o       (led_pattern),
    .pattern_commit_o(led_pattern_commit));
```
- **为什么是问题**：三个数据输入是编译期常量，`blink_i` 是唯一的变量；若 led_data 的逻辑在"全 0 输入"下与 blink 无关（极可能），则 `pattern_o` 折叠成常量 ⇒ 综合日志里出现 `WARN (NL0002): The module "led_data" … is swept in optimizing(top.v:4844)`（见 P0-2）⇒ **16 颗键灯 + 8 颗状态灯全是死的**，而 `tlc5916_bank` 仍在每次 `pattern_commit` 时把常量图案移位输出（白跑 SPI）。注释自己写了"待甲补输入源" ⇒ 功能缺失是已知的；但没人知道它在网表里已经被整块扫掉了（rsc.xml 里没有 `u_led_data`）。
- **改法**：① 短期：把注释改成"当前为占位常量 ⇒ 综合会把 `u_led_data` 整块扫掉（NL0002），灯带恒灭"，并把它加进 P0-2 的白名单；② 中期：把 event_extract 的 16 位 `key_on` 引出来（现在 rtl/top.v:4819-4820 的注释说"尚未引出成 16 bit 端口"）⇒ 接 `key_active_i`。
- **预期**：① 0 成本；② 收益 = 演奏指引灯可用（评分项），代价 = 多 16 位端口 + 一次 PnR（要重核时序）。
- **怎么验**：加 tb 断言 `dut.u_led_data` 存在（用层次引用强制不被剪）⇒ 现在会红。
- **来源**：TORCH-4【P2-6】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-7|MOD=constr/top.cst
### 把 GROUP/GRP_LOC 手法用到头号路径的锥体上
- **位置**：constr/top.cst:512-523；impl/pnr/Gowin2026_tr_content.html（头号路径 LOC）；rtl/top.v:325-327
- **现状**：
```text
// constr/top.cst:512-523
// H5 (2026-10-02): targeted LOOSE region for the calibration return-path cone.
// Why: with H5 merged, the worst setup path is
//   g_sound.u_calib_span/reject_o -> u_tx_fifo/mem_*[1]/D
// with 20.303 ns of ROUTING (92% of the 22.08 ns path) …
GROUP h5_ret = { "tx_byte_*" "u_tx_fifo/*" "g_sound.u_calib_span/reject_o_*" };
GRP_LOC h5_ret R[45:73]C[1:148];
```
- **为什么是问题**：项目已经证明"用 GROUP/GRP_LOC 把锥体收进一个矩形"是有效的（h5_ret 这一组正是为 92% 走线的路径做的）。而当前头号路径（`n34284_s0` @ R27C96 → `phase_tr[28]_24_s0` @ R60C141）没有任何区域约束 ⇒ 5.407 ns 的单网。同一手法没有用到最需要它的地方。
- **改法**：见 P0-3 的②（`GROUP t3_rot` + 非独占 `GRP_LOC`）。⚠️ 两条纪律：① GROUP 与 GRP_LOC 必须成对（Gowin SUG1018 2.4.1，top.cst:518 已写明）；② CLS 已 **78%** ⇒ 必须非独占，否则会 PR0004（本项目已有 T3 数组+mux 版 490 根不布通的先例，见 rtl/top.v:325-327）。
- **预期**：收益 = 直接打掉 5.4 ns（见 P0-3）；代价 = 布局自由度下降，可能挤坏别的路径 ⇒ 必须"改前改后各留一份 timing_paths 对比"。
- **怎么验**：改完断言 `phase_tr[28]_24_s0` 的 LOC 与驱动它的 LUT 的 LOC 在同一 `R[20:40]C[80:120]` 矩形内，且该网 `tNET < 2.5 ns`。
- **来源**：TORCH-4【P2-7】
@@@END
@@@PRIO=P2|SRC=TORCH-4|ORIG=P2-8|MOD=rtl/top.v,rtl/w3a/calib_autotare.v
### 把重标期间的键盘静默从最长 16 s 降下来
- **位置**：rtl/top.v:1920-1927、:3162、:1911-1916；rtl/w3a/calib_autotare.v:67-71、:99-111、:243-245、:101-103
- **现状**：
```verilog
// rtl/top.v:1920-1927
localparam integer AT_EN_DELAY = 16;
always @(posedge clk) … at_done_dly <= {at_done_dly[AT_EN_DELAY-2:0], at_done};
wire at_en_ready = at_done_dly[AT_EN_DELAY-1];
// rtl/top.v:3162
.enable_i         (at_en_ready),
// rtl/w3a/calib_autotare.v:101-103（注释）
//   ⭐ 做法：⭐ 从 `ST_DONE` 收到 `retrig_i` ⇒ ⭐ **直接跳 `ST_SWEEP`**（⛔ 不重新等 `DELAY_CLK`）
// rtl/w3a/calib_autotare.v:69-70
parameter integer STILL_FRAMES = 4,
parameter integer WAIT_MS      = 1000,     // ⭐ 单通道最长等待（ms）
```
- **为什么是问题**：'T' ⇒ `retrig_i` ⇒ state 从 ST_DONE 跳到 ST_SWEEP ⇒ `at_done` 落 0 ⇒ `event_extract.enable_i = 0` ⇒ 不判任何按键（设计如此，防脏值）。标定时长 = 逐通道等"连续 4 帧静止"（4 × 500 µs = 2 ms）或 `WAIT_MS` 超时（1000 ms）⇒ 8 通道 × 2 片 = 16 个轴 ⇒ 若每个轴都因手在动而超时，**最长 16 × 1 s = 16 s**。⇒ 上板时"按了 'T' 之后琴有十几秒不响"看起来像死机。（对比：rtl/top.v:1911-1916 的注释只算了 `AT_EN_DELAY=16` 拍 = 320 ns，没有算标定本身的时长 —— 这就是"时间常数没算就判卡死"的老坑 C84。）
- **改法**（三选一）：① 保留 event_extract 的使能，改为在 tare 生效的那一帧只屏蔽被标定的那一个轴（`calib_autotare.cal_ch_o` 已知是哪个通道）⇒ 其余 15 个键照常能弹；② 把 `WAIT_MS` 从 1000 降到 200（代价：手在动时更容易跳过该轴）；③ 至少在 rtl/top.v 的注释里把"最长 16 s 无响应"写出来，并在上板手册里提醒。
- **预期**：① 收益最大（重标时琴不死），代价 = 要改 event_extract 的屏蔽口径（有回归风险）；② 0 代码、只改一个参数；③ 0 成本。
- **怎么验**：tb/w3c/tb_span_axis_over_uart.log 同族的 tb 里，让 adc_farm 的 raw 持续抖动（模拟手在动）⇒ 发 'T' ⇒ 断言"从 'T' 到第一个 note_on 可被接受"的时间 < 100 ms。现在必然红（>1 s）。
- **来源**：TORCH-4【P2-8】
@@@END
@@@PRIO=P3|SRC=TORCH-4|ORIG=P3-1|MOD=constr/top.cst
### 给四条 TMDS 显式写上 IO_TYPE=LVDS25
- **位置**：constr/top.cst:495-506、:496-497、:495；impl/pnr/Gowin2026.rpt.txt:157-164；rtl/hdmi/tmds_serializer.v:30、:35
- **现状**：
```text
// constr/top.cst:496-497 —— ⛔ 没有 IO_TYPE
IO_LOC  "tmds_d_p_0[0]" J14,H14;
IO_PORT "tmds_d_p_0[0]" PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
// impl/pnr/Gowin2026.rpt.txt（Pinout by Port Name）
tmds_d_p_0[0] | tmds_d_n_0[0] | J14/4 | Y | out | IOR26[A] | - | LVDS25 | 3.5 | NONE | … | 3.3
```
- **为什么是问题**：.cst 没写 `IO_TYPE`，工具自己推断成 `LVDS25`。而 RTL 侧用的是 `TLVDS_OBUF`（rtl/hdmi/tmds_serializer.v:30、:35）⇒ 实测两者一致（Gowin 的 TMDS 输出就是 TLVDS_OBUF + LVDS25）⇒ 今天不是错。但它是一个没写下来的依赖：换工具版本 / 换 DRIVE 值时，推断结果可能变，而 .cst 里没有任何东西能拦住它。（constr/top.cst:495 的注释写"verified TLVDS differential pairs"，而报告里写 LVDS25 ⇒ 名字层面就已经对不上。）
- **改法**：显式写出来，并把注释改成实测值：
```text
IO_LOC  "tmds_d_p_0[0]" J14,H14;
IO_PORT "tmds_d_p_0[0]" IO_TYPE=LVDS25 PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
// ⭐ 实测（Gowin2026.rpt.txt）：IO Type=LVDS25 · Drive=3.5 · BankVccio=3.3
//    RTL 侧 = TLVDS_OBUF（rtl/hdmi/tmds_serializer.v:30）
```
（4 对共 4 行）
- **预期**：收益 = 电气标准不再靠推断；代价 = 0（若推断值本就正确，PnR 结果不变）。
- **怎么验**：改完重跑 PnR，断言 Pinout 报告里这 4 行的 IO Type 仍是 `LVDS25`；若写错（例如 LVCMOS33）会立刻出现 CT1108 类错误或报告变化。
- **来源**：TORCH-4【P3-1】
@@@END
@@@PRIO=P3|SRC=TORCH-4|ORIG=P3-2|MOD=rtl/top.v
### 给 DRUM_PATTERN_ID 补范围自检
- **位置**：rtl/top.v:232、:699-700、:702-706、:219-231；tb/w3c/tb_key_drum.sv
- **现状**：
```verilog
parameter integer DRUM_PATTERN_ID   = 0,
localparam [1:0] DRUM_PATTERN_INIT = DRUM_PATTERN_ID;   // ⚠️ integer → 2 位 ⇒ 静默截断
reg [1:0] drum_pattern_r;
always @(posedge clk) … if (!rst_n_sync) drum_pattern_r <= DRUM_PATTERN_INIT;
```
- **为什么是问题**：`DRUM_PATTERN_ID = 4` ⇒ `4[1:0] = 0` ⇒ 上电节奏型静默变成 BASIC，而注释（:219-231）说明合法值是 0~3。同类风险：任何 integer 参数赋给窄 localparam（本项目 K-91 家族）。rtl/w3b/oscillator_bank.v / note_manager.v 都有 `PARAM_OK` 自检（`$display("ERROR …")`），top.v 这一段没有。
- **改法**：
```verilog
initial if (DRUM_PATTERN_ID < 0 || DRUM_PATTERN_ID > 3)
    $fatal(1, "ERROR [top] DRUM_PATTERN_ID=%0d 超出 0..3（会被 2 位 localparam 静默截断）", DRUM_PATTERN_ID);
```
- **预期**：收益 = 消掉一个静默截断；代价 = 3 行、0 资源。
- **怎么验**：tb_key_drum.sv 加一条 `top #(.DRUM_PATTERN_ID(4))` 的例化 ⇒ 必须 `$fatal` 退出。现在会静默跑完。
- **来源**：TORCH-4【P3-2】
@@@END
@@@PRIO=P3|SRC=TORCH-4|ORIG=P3-3|MOD=sim/gowin_build.ps1,sim/evidence
### 让每次 PnR 强制写 timing.txt 并归档 =1 档证据
- **位置**：git log -1（026ed21 的 message）；sim/evidence/rightboard-vibrato-fix-20261008/（只有 pnr-rpt-*.txt，没有 timing.txt）；sim/evidence/final-batch-20261008/、sim/evidence/a3-proper-20261008/；sim/gowin_build.ps1
- **现状**：
```
任务书给的"=1 档 ≈57.0 MHz / CLS 81% / 余量 +0.642 ns"这个数，在本仓库里只能从 commit message 读到：
deliver(右手板): 联调档时序达标 —— 一个能上板的版本（=1 档 0/0 · ≈57.0 MHz · 余量 +0.642 ns）
而 sim/evidence/rightboard-vibrato-fix-20261008/ 下没有 timing.txt
（对比 final-batch-20261008/ 与 a3-proper-20261008/ 都有）
```
- **为什么是问题**：`+0.642` 这个数无法与 `18.181` 反算校核（若按 55.313 的口径，`Fmax = 1000/(18.181 − slack)` ⇒ `slack = 0.642` ⇒ `Fmax = 57.06 MHz` ✅ 自洽），但没有原始报告可复核，也没有 CLS 81% 的出处。
- **改法**：把 =1 档那次 PnR 的 `Gowin2026_tr_content.html` / `timing_paths` / `rpt.txt` 归档到 sim/evidence/rightboard-vibrato-fix-20261008/，并让 sim/gowin_build.ps1 每次 PnR 都强制写 `timing.txt`（现在是可选）。
- **预期**：收益 = 交付数字可复核（评委/队友都能验）；代价 = 磁盘（~700 KB/次）。
- **怎么验**：断言 `sim/evidence/*/timing.txt` 的份数 == PnR 次数。现在不成立。
- **来源**：TORCH-4【P3-3】
@@@END
@@@PRIO=P3|SRC=TORCH-4|ORIG=P3-4|MOD=sim/tb_all.ps1
### 把"共 N"的口径写成自动发现 + 默认跳过 2 个工具 tb
- **位置**：sim/tb_all.ps1:65-66、:223-224；AGENTS.md §四
- **现状**：
```powershell
$tbs = @(Get-ChildItem -Path $tbDir -Recurse -Include tb_*.sv -File -ErrorAction SilentlyContinue | …
$skipByDefault = @('tb_export_wav', 'tb_export_key_wav')
```
- **为什么是问题**：实测 `(Get-ChildItem tb -Recurse -Filter 'tb_*.sv').Count` = **131**（新增的是 tb/w3b/tb_osc_drum_cls.sv）。而 `tb_export_wav`/`tb_export_key_wav` 默认被跳过 ⇒ 回归打印的"共 N"不含这两个。按项目纪律（AGENTS.md §四）：判据是"通过数 == 共数"，不写死数字 —— 这条要继续守。
- **改法**：把任务书/交接里的"130 个 tb"改成"自动发现，共数即真值"；并明确写出"默认跳过 2 个工具 tb（tb_export_wav/tb_export_key_wav）"。
- **预期**：收益 = 避免"数字过时"的第三次复发（历史已错三次：48→81→87）；代价 = 0。
- **怎么验**：sim/tb_all.ps1 输出里的"共 N"与 `(Get-ChildItem tb -Recurse -Filter tb_*.sv).Count - 2` 必须相等。
- **来源**：TORCH-4【P3-4】
@@@END
@@@PRIO=P3|SRC=TORCH-4|ORIG=P3-5|MOD=rtl/top.v
### 给两路 i2s_tx 的格式差异加显式契约
- **位置**：rtl/top.v:4619、:4671-4672、:4665-4668、:4611-4621、:4653-4673、:352；tb/w3c/tb_i2s_tx_timing.log（对应 tb）
- **现状**：
```verilog
// rtl/top.v:4611-4621（板载 MAX98357A）
i2s_tx #( … .JUSTIFY   (0), .MSB_DELAY (1), .LRCK_POL  (0) ) u_i2s_tx (…);
// rtl/top.v:4653-4673（外置 PCM5102A）—— ⚠️ 同一个 JUSTIFY=0，但 MSB_DELAY 不同
i2s_tx #( … .JUSTIFY   (0), .MSB_DELAY (0), .LRCK_POL  (0) ) u_i2s_tx_ext (…);
// rtl/top.v:4665-4668（注释已经把陷阱写出来了）
//   📌 **术语陷阱**：⭐ `i2s_tx` 这个模块里的 `JUSTIFY=0` 指的是
//      **"Philips 标准 I2S"**（⭐ 数据在 WS 翻转后【延迟】`MSB_DELAY` 位），
//      ⚠️ ⛔ **不是**字面意义的"左对齐" —— ⚠️ 别被名字误导。
//      ⭐ 真正要"左对齐" ⇒ ⭐ **`JUSTIFY=0` + `MSB_DELAY=0`**。
```
- **为什么是问题**：两路的"格式"完全由 `MSB_DELAY` 区分（1 = 标准 I2S / 0 = 左对齐），而 `JUSTIFY` 两路都是 0。⇒ 任何人读这两处例化时，唯一有效的区分位是 `MSB_DELAY`，而名字最响的 `JUSTIFY` 是个看起来像开关、实际两路相同的参数。本项目已经因为"名字骗人"栽过（`PA_EN_n` 实际是"高 = 出声"，rtl/top.v:352）。注释虽然写清了，但读例化的人不一定读注释。
- **改法**（0 风险，纯可读性）：
```verilog
localparam integer I2S_PHILIPS  = 0;   // ⭐ JUSTIFY=0 = Philips 标准 I2S（⛔ 不是"左对齐"）
// 板载：.JUSTIFY(I2S_PHILIPS) .MSB_DELAY(1)   ← 标准 I2S（实测出声）
// 外置：.JUSTIFY(I2S_PHILIPS) .MSB_DELAY(0)   ← 左对齐（实测出声）
```
或至少在两处例化行尾加同一句行内注释：`// ⭐ 格式差异看 MSB_DELAY，不看 JUSTIFY`。
- **预期**：收益 = 消掉一个"改错参数 ⇒ 没声音/爆音"的入口（C-6 家族）；代价 = 0。
- **怎么验**：tb/w3c/tb_i2s_tx_timing.log 同族的 tb 里加一条：断言 `u_i2s_tx.MSB_DELAY == 1` 且 `u_i2s_tx_ext.MSB_DELAY == 0` 且两者 `JUSTIFY == 0`。⇒ 若有人"顺手把两路参数对齐"，必然红（今天不会红，因为值是对的；这条是把"隐式约定"变成"显式契约"）。
- **来源**：TORCH-4【P3-5】
@@@END
@@@TOTAL SRC=TORCH-4 COUNT=25 P0=4 P1=8 P2=8 P3=5
