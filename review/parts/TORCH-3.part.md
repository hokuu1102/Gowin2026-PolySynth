@@@PRIO=P0|SRC=TORCH-3|ORIG=P0-01|MOD=rtl/top.v
### 给 g_silent 档补上 fault_any_w 的驱动
- **位置**：rtl/top.v:1121、:1719、:4786-4790、:4793、:4802、:1235、:1269、:1239-1268、:56-58、:5-9；tb/top/tb_top_m0.sv
- **现状**：
```verilog
// top.v:1121（模块级声明，generate 之外）
wire       fault_any_w;
// top.v:1719（在 end else begin : g_sound 之内 —— 见 top.v:1269）
        assign fault_any_w = (|af_fault) | mx_fault;
// top.v:4786-4790（模块级消费，两个分支都看得到）
    reg fault_sticky;
    always @(posedge clk) begin
        if (!rst_n_sync)         fault_sticky <= 1'b0;
        else if (fault_any_w)    fault_sticky <= 1'b1;   // ⭐ sticky
    end
```
- **为什么是问题**：top.v 用 `generate if (DEMO_CHORD_ON == 0) ... g_silent ... else ... g_sound`（top.v:1235 / :1269）产生两个互斥分支。`g_silent` 分支逐个显式驱动了 10 根跨分支共享线（`pp_push`/`pp_data`/`scope_sample`/`scope_valid`/`sample_mono`/`tx_req`/`tx_byte`/`led_blink`/`led_beat`/`led_gear_st`/`led_looper_st`，见 top.v:1239-1268）—— 唯独漏了 `fault_any_w`。⇒ 当 `DEMO_CHORD_ON == 0`（tb/top/tb_top_m0.sv 正是这一档，见 top.v:56-58 的说明）：**仿真**：`fault_any_w` = z ⇒ `if (fault_any_w)` 为 X ⇒ `fault_sticky` 变 X ⇒ `hb_div_eff = fault_sticky ? (HEARTBEAT_DIV>>3) : HEARTBEAT_DIV`（top.v:4793）变 X ⇒ `hb_cnt >= hb_div_eff - 1`（top.v:4802）恒为 X（判为假）⇒ 🔴 **`hb` 永不翻转 ⇒ 心跳灯死** ⇒ 🔴 **M0"活体见证"（本设计唯一的故障可观测手段，top.v:5-9 写明是为此存在的）在静默档上完全失效**。**硅片**：综合对"无驱动网线"通常接 0（并给一条极易被刷屏淹没的 warning）⇒ `fault_sticky` 恒 0 ⇒ 🔴 **故障指示永远不亮** ⇒ `adc_farm` SPI 挂 / `tdm_render_mixer` 超时出了也没人知道。
- **改法**（top.v，g_silent 分支内，与 `tx_req` 同段）：`assign fault_any_w = 1'b0;   // ⭐ 静音档：两个故障源都不存在 ⇒ 明确"无故障"`
- **预期**：收益 = M0 档心跳灯恢复确定性、故障指示恢复语义；代价 = **1 行、0 资源**。
- **怎么验**：1. 加一条 tb 断言（或在 tb/top/tb_top_m0.sv 内）：`DEMO_CHORD_ON=0` 下，复位释放后 `assert (!$isunknown(dut.fault_sticky))` 且在 `4*HEARTBEAT_DIV` 拍内 `led_heartbeat` 必须翻转 ≥2 次；未修复：`fault_sticky` = x ⇒ 断言立即红；`led_heartbeat` 恒 x/0 ⇒ 超时红。2. 机械旁证（一行、不可绕过）：`select-string -Path rtl/top.v -Pattern 'assign\s+fault_any_w'` 必须返回 2 行（两个分支各 1）；当前只有 1 行。
- **来源**：TORCH-3【P0-01】
@@@END
@@@PRIO=P0|SRC=TORCH-3|ORIG=P0-02|MOD=rtl/rst_sync.v,rtl/drivers/debounce.sv,rtl/drivers/calib.sv,rtl/drivers/adc_farm.sv,rtl/w3c/looper.v,rtl/hdmi/hdmi_scope.v,rtl/hdmi/video_timing.v,rtl/hdmi/tmds_encoder.v
### 把 16 个异步复位端口改成同步复位（rst_sync 的同步释放被整段抵消）
- **位置**：rtl/rst_sync.v:39-45、:8-12；rtl/drivers/debounce.sv:66、:88、:108、:127、:140、:152、:157；rtl/drivers/calib.sv:175、:257、:345；rtl/drivers/adc_farm.sv:218；rtl/w3c/looper.v:293、:793；rtl/hdmi/hdmi_scope.v:19；rtl/hdmi/video_timing.v:23；rtl/hdmi/tmds_encoder.v:56；rtl/top.v:592、:654、:1693、:2481、:2501、:3606；constr/top.sdc:90、:88-90；impl/pnr/Gowin2026.timing_paths
- **现状**：
```verilog
// 发射端 rtl/rst_sync.v:39-45
    always @(posedge clk) begin
        // ⚠️ 这里**故意不用 `if (!rst_n_sync)`**：本模块自己就是复位的源头，
        //    用输入直接灌链即可（否则就成了自复位）。
        sync_chain <= {sync_chain[STAGES-2:0], rst_n_async};
    end
    assign rst_n_sync = sync_chain[STAGES-1];
接收端（全部使用 rst_n_sync 作【异步】复位）：
debounce.sv:66/88/108/127/140/152/157（共 7 处）· calib.sv:175/257/345（2 个实例 ⇒ ×2）· adc_farm.sv:218
· looper.v:293/793 · hdmi_scope.v:19 · video_timing.v:23 · tmds_encoder.v:56（3 个实例）
顶层接线：top.v:592 / :654 .rst_n(rst_n_sync) · :1693（adc_farm）· :2481/:2501（calib ×2）· :3606 .rst_n_i(rst_n_sync)（looper）
```
- **为什么是问题**：`rst_n_sync` 由 `rst_sync` 在 `posedge clk` 上更新 ⇒ 它的释放沿与 `clk_sys` 沿严格对齐（仅差 clk-to-Q）。把这个信号接进 `negedge rst_n` 端口后，**释放（de-assert）对每个 FF 的异步复位端而言是【异步】的** ⇒ 每个 FF 各自在自己的 recovery/removal 窗里判定，可以落在不同的 clk 沿上：若 `rst_n_sync` 在 `T` 拍上升，FF-A 在 `T+1` 脱离复位、FF-B 因 removal 不足在 `T+2` 才脱离 ⇒ 🔴 **同一个复位源，各模块释放相差 1~2 拍（20~40 ns）**，正是 rst_sync.v:8-12 明文要消灭的现象。项目自己的报告数字：constr/top.sdc:90 记录 **`recovery +1.490 ns` / `removal +0.217 ns`** ⇒ ⭐ **removal 余量只有 0.217 ns（= 1.1% 个时钟周期）** —— 任何一点布局噪声都能把它吃掉。本次 PnR 的真实 HOLD 余量（impl/pnr/Gowin2026.timing_paths）：`HOLD +0.137 ns → g_sound.u_looper/ep_mem_ep_mem_0_5_s`（L=3）、`+0.190 ns`、`+0.194 ns`…… ⇒ 全设计最薄的 25 条余量里有 6 条落在 `u_looper`/`u_note_manager`，而 `u_looper` 恰好是异步复位模块。
- **改法**（推荐 = 保守、零行为改动，只改复位端）：把上述 **16 个** `always @(posedge clk or negedge rst_n)` 统一改成同步复位（与本项目 W3接口冻结表 §〇 约定 2 一致）：
```verilog
// 例：debounce.sv:66
    always @(posedge clk) begin          // ⛔ 去掉 `or negedge rst_n`
        if (!rst_n) begin ... end else begin ... end
```
若因"必须异步置位"而不能改（只有 hdmi_scope.v:19 的 `reset_pipe` 有正当理由，因为它要同步 lock），则必须走标准写法：**异步置位 + 同步释放的两级同步器**，并且该同步器本身用 `(* async_reg *)` 标注：
```verilog
    (* async_reg = "true" *) reg [1:0] rst_sync_pix;
    always @(posedge pixel_clk or negedge rst_n)     // 断言异步
        if (!rst_n) rst_sync_pix <= 2'b00;
        else        rst_sync_pix <= {rst_sync_pix[0], 1'b1};   // 释放同步
    wire video_reset_n = rst_sync_pix[1];
```
（⛔ 不要用 `set_false_path` 把 recovery/removal 藏起来 —— top.sdc:88-90 已经明文禁止这条路，理由正确。）
- **预期**：收益 = 全设计复位释放沿严格同沿（rst_sync 的设计意图真正落地）；`removal` 从 **+0.217 ns** 变成普通 setup 路径（有 18 ns 预算）；消除"某次上电某个模块慢一拍"这类偶发、不可复现的怪病（用户主诉的那一类）。代价 = 同步复位生效晚 1 拍（20 ns）；debounce/calib 的复位语义完全不变（它们本来就是同步逻辑）；需要重跑全量回归 + 一次 PnR。⚠️ 风险点：tlc5916_driver 的 K-66 恢复序列依赖复位后的固定相位，debounce/calib 不涉及，故无连带。
- **怎么验**：新增 tb/cdc/tb_reset_release_order.sv（或加进 tb/top/tb_top_m0.sv）：1. 用 `rand` 让 `rst_n` 的释放沿相对 `clk_sys` 随机偏移 0..19 ns（跑 200 个种子）；2. 释放后第 3 拍，断言下列模块的所有状态 FF 全部处于复位初值（用 `$isunknown` + 初值比对）：`u_timbre_btn_debounce.key_level` · `u_pedal_sus_debounce.key_level` · `g_sound.u_calib0.zero_r` · `g_sound.u_calib1.zero_r` · `g_sound.u_looper.state` · `g_sound.u_adc_farm.fault_r`；3. 未修复：在某个种子下这些 FF 的"脱离复位拍号"不相等 ⇒ 断言红；已修复：200 个种子下全部相等 ⇒ 绿。📌 这条判据必须跑多相位，单相位跑一次是抓不到的（这正是本缺陷能活到今天的原因）。
- **来源**：TORCH-3【P0-02】
@@@END
@@@PRIO=P0|SRC=TORCH-3|ORIG=P0-03|MOD=rtl/top.v,rtl/w3c/evt_uart_rx.v
### 把 SCORE_UART_ENABLE 默认改回 0（或给曲谱独立 UART / 加帧尾校验）
- **位置**：rtl/top.v:3495、:3472-3494、:3725、:3725-3729、:829-837、:3693-3694、:3699-3701、:3703-3707、:3710-3711、:3480-3489、:3490-3494、:499；rtl/w3c/evt_uart_rx.v:175-187、:87；rtl/w3b/note_manager.v（(axis,src) 双条件）；tb/w3c/tb_evt_uart_rx_screen.sv；tb/top/tb_e2e_key_to_sound.sv
- **现状**：
```verilog
// top.v:3495
        localparam integer SCORE_UART_ENABLE = 1;
// top.v:3725-3729
            .score_valid_i    (SCORE_UART_ENABLE ? eu_evt_valid : 1'b0),
            .score_axis_i     (SCORE_UART_ENABLE ? score_evt_axis : 4'd0),
            .score_phase_inc_i(SCORE_UART_ENABLE ? score_evt_inc  : 32'd0),
            .score_velocity_i (SCORE_UART_ENABLE ? score_evt_vel  : 8'd0),
            .score_kind_i     (SCORE_UART_ENABLE ? score_evt_kind : 2'd0),
// evt_uart_rx.v:175-187 —— 只在 idx==0 位置看帧头（本模块自己的安全设计）
                if (idx_q == 4'd0) begin
                    // ---- ⭐ 只在【第 0 字节位置】看帧头（⛔ 不扫描）----------
                    if (byte_is_a5) begin
                        idx_q    <= 4'd1;
                        all_a5_q <= 1'b1;      // ⭐ 帧头是 0xA5 ⇒ 起始为真
```
- **为什么是问题**：top.v:829-837 与 :3693-3694 都写明：同一个 `uart_rx` 的 `ur_done`/`ur_data` 被三路共用（uart_ui 串口屏 · calib_cmd 命令 · evt_uart_rx 曲谱事件），三路各自维护帧边界。evt_uart_rx 的帧头是 0xA5，帧长 9 字节；只要任意另一路的合法载荷里出现 0xA5，且它恰好落在 evt_uart_rx 的 `idx_q == 0`，就会被当成帧头 ⇒ 注入一条 64 bit 伪事件。top.v:3699-3701 记录了实测：喂 8 个串口屏数值帧（数据含 0xA5）⇒ 产生 8 条伪事件，其中 `axis = 15` · `inc = 0x1FFFFF` · `kind = 0`（note_on）。致命之处在 top.v:3703-3707：伪事件带 `score` 源，而 note_manager 的 `note_off` 按 `(axis, src)` 双条件匹配 ⇒ 手弹（live）的 note_off 永远清不掉这条 score voice ⇒ 🔴 **`gate_r` 永久为 1**。用户实测症状（top.v:3710-3711 原文）：「按同键不能清」「按所有键也不能清」「持续几分钟」「断电才清」「~50% 概率」「按一阵后累积」。🔴 关键退化：top.v:3480-3489 记载，2026-09-28 曾把本参数默认置 0 作为缓解，2026-09-30 为了"曲谱与 looper 同时可用"又把默认改回 1 ⇒ 那道缓解被撤掉了，而注入通路未被修（top.v:3490-3494 自认"遗留风险…理论通路仍然存在"）。
- **改法**（按性价比排序）：1. ⭐ 零成本、立即止血：把 top.v:3495 改回 `localparam integer SCORE_UART_ENABLE = 0;`（top.v:3486-3489 已证明 `= 0` 只关曲谱 UART，looper 照常可用 ⇒ 不牺牲任何已交付功能）。2. ⭐ 结构性修法（真正闭环）：给曲谱一条独立 UART 引脚。引脚申请单已留了 `esp_uart_rx_i`（G22），但 top.v:499 注释说它"← ESP32 的 TX"⇒ 应把曲谱改走 `esp_uart_rx_i` + 它自己的 `uart_rx` 实例，与 uart_ui/calib_cmd 物理分线 ⇒ 注入在原理上不可能。3. ⭐ 协议加固（若必须共用一条线）：evt_uart_rx 增加帧尾校验（如第 9 字节 = 前 8 字节的 XOR），校验不过 ⇒ `hdr_err_cnt_o++` 且不产生事件；伪事件概率从"载荷含 0xA5"降到 2⁻⁸。
- **预期**：方案 1：收益 = 消除用户主诉的头号"偶发怪病"；代价 = 曲谱 UART 关闭（looper/手弹/鼓机/节拍器全不受影响），**1 行**。方案 2：收益 = 曲谱与串口屏真并存且零注入；代价 = 1 个 uart_rx 实例（~120 FF）+ .cst 1 行 + ESP32 侧分线。方案 3：收益 = 保留共用线；代价 = 上位机 tools/evt2uart.py 必须同步加校验字节（⚠️ 协议变更）。
- **怎么验**：tb/w3c/tb_evt_uart_rx_screen.sv 已存在且已能复现（top.v:3494 指向它）。把它的判据改成硬断言：注入 8 个含 0xA5 的屏幕数值帧后 `assert (u_evt_uart_rx.frame_cnt_o == 0)`（未修复 ⇒ == 8 ⇒ 红）、`assert (u_evt_uart_rx.hdr_err_cnt_o >= 8)`（未修复 ⇒ == 0 ⇒ 红）。再加一条端到端判据（tb/top/tb_e2e_key_to_sound.sv 家族）：注入伪事件后发同轴的 `live` note_off，断言 `u_note_manager.gate_r` 对应位归 0；未修复：恒 1 ⇒ 红（这就是"挂音"的机器判据）。
- **来源**：TORCH-3【P0-03】
@@@END
@@@PRIO=P0|SRC=TORCH-3|ORIG=P0-04|MOD=constr/top.sdc,rtl/hdmi/tmds_serializer.v,sim/gowin_build.ps1
### 把 125 MHz serial_clk 域的零验证变成可测或显式豁免
- **位置**：constr/top.sdc:74-76、:88-90、:89；sim/evidence/final-batch-20261008/timing.txt:64-79、:44-63；rtl/hdmi/tmds_serializer.v:21-33；rtl/hdmi/hdmi_clk.v:33；bringup/hdmi_640x480/evidence-h4/RESULT.md:53；evidence/h5/
- **现状**：
```tcl
# top.sdc:74-76
create_generated_clock -name serial_clk -source [get_ports {clk}] -master_clock clk_sys -divide_by 8 -multiply_by 20 [get_pins {u_hdmi/u_clk/u_pll/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {clk}] -master_clock clk_sys -divide_by 40 -multiply_by 20 [get_pins {u_hdmi/u_clk/u_pll/CLKOUT1}]
// tmds_serializer.v:21-28
    generate for (j=0; j<4; j=j+1) begin : lanes
        OSER10 u_oser (.Q(serial[j]), .D0(lane[j][0]), ... .D9(lane[j][9]),
            .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(rst));
```
- **为什么是问题**：timing.txt 的 Max Frequency Summary 只有 1 行（`clk_sys` 50.000 MHz 约束 / 55.060 MHz 实际 / Logic Level 10 / TOP）⇒ 🔴 `serial_clk`（8.000 ns / 125 MHz）与 `pixel_clk`（40.000 ns / 25 MHz）在 Clock Summary 里存在（timing.txt:44-63），但 Fmax 汇总里一条都没有 ⇒ **没有任何数据路径的时序是被"以 125 MHz 为目标"验证过的**。原因：OSER10 是硬宏，PCLK → FCLK 的 10:1 搬运发生在宏内部，STA 看不见（top.sdc:89 的注释也承认这一点）。⇒ 本项目自己的证据文件 bringup/hdmi_640x480/evidence-h4/RESULT.md:53 原文："报告的 setup/hold 违例端点各 0、TNS 各 0 ns；但 serial Actual Fmax 不可得，0 违例不等于验证通过 768.75 MHz 的串行化器。" 而当前配置 `ODIV0_SEL=8`（hdmi_clk.v:33）⇒ `50×20/8 = 125 MHz` FCLK，每 lane **10×25 = 250 Mb/s**。⚠️ 同时 top.sdc:88-90 刻意不用 `set_clock_groups -asynchronous`（理由正确：会删掉 OSER10 RESET 的真实 recovery/removal）⇒ 于是这个域既没有 Fmax、也没有被显式豁免，处于"约束真空"。
- **改法**：1. ⭐ 把不可测变成可测（首选）：在 tmds_serializer 的 OSER10 前后各插一级可测寄存器做"影子通路"，仅用于 STA（用 `(* syn_keep *)` + `dont_touch`，不接输出）：
```verilog
(* syn_keep = "true", dont_touch = "true" *) reg [9:0] lane_shadow [0:3];
always @(posedge pixel_clk) lane_shadow[0] <= blue;   // PCLK 侧影子
```
⇒ 让工具至少能报 `pixel_clk` 的 Fmax，并把 `serial_clk` 的存在显式化。2. ⭐ 显式记录"serial 域不可 STA"这件事：在 top.sdc 里加带理由的注释 + 一条 `set_false_path`（写明"OSER10 内部，宏外不可分析"），⛔ 不要留成"没写"（没写 = 没人知道是漏了还是故意的）。3. ⭐ 上板闭环（唯一真判据）：用示波器/眼图量 `tmds_clk_p` 的 125 MHz 与 `tmds_d_p_0` 的 250 Mb/s 眼宽，记录到 evidence/h5/。这是本项唯一能"红"的方式。
- **预期**：收益 = 把"H5 显示通路"从"看起来全绿"变成"有明确验证边界"；代价 = 方案 1 多 ~40 FF、方案 2 零成本、方案 3 需要仪器。
- **怎么验**：机械判据：Fmax 汇总必须覆盖所有 `create_generated_clock` 的时钟 —— `$fmax = (Get-Content sim/evidence/*/timing.txt | Select-String 'Actual Fmax').Count`；`$gen = (Get-Content constr/top.sdc | Select-String 'create_generated_clock').Count`；当前 `$fmax = 1, $gen = 2` ⇒ 红。该脚本必须在 sim/gowin_build.ps1 的验收里硬失败（⛔ 现在是"人看报告"，没有机械门）。
- **来源**：TORCH-3【P0-04】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-01|MOD=rtl/hdmi/waveform_scope.v,constr/top.sdc
### 去掉 waveform_scope 的负沿半周期 hack，改用时钟对 + datapath_only
- **位置**：rtl/hdmi/waveform_scope.v:34-43；constr/top.sdc:101-102、:97；impl/pnr/Gowin2026.timing_paths；tb/hdmi
- **现状**：
```verilog
// waveform_scope.v:34-43
    // The PLL pixel rising edge coincides with a source rising edge. Launch
    // the CDC bundle on the source falling edge to provide a real 10 ns
    // setup/hold separation instead of relying on a false-path exception.
    reg [9:0] gray_launch;
    reg full_launch;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 0; full_launch <= 0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end
// top.sdc:101-102
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
set_max_delay -from [get_clocks {clk_sys}] -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0}] 10.000
```
- **为什么是问题**：`sample_clk = clk_sys = 50 MHz` ⇒ 一个周期 20 ns，正沿到负沿 10 ns。`gray_launch`/`full_launch` 在负沿发射，接收侧 `gray_meta`/`full_meta` 在 `pixel_clk`（25 MHz，40 ns）正沿采样 ⇒ 作者用它把"同沿发射"改成"错开半个周期"，得到 10 ns 的发射侧预算。🔴 风险 1（致命）：top.sdc:102 的目标用的是 `gray_launch_*_s0`/`full_launch_s0` —— 这是 Gowin 综合后加的 `_s0` 后缀网名，不是 RTL 名。综合若把它们改成 `_s1`、合并进 `_s83`、或把 10 位打散重命名（本设计里 `_s0/_s1/_s83` 三种后缀都真实出现过，见 Gowin2026.timing_paths 的 `rot_phase_20_s83` / `phase_r[31]_9_s1`）⇒ `get_regs {...}` 匹配到空集 ⇒ `set_max_delay 10.000` 不生效 ⇒ 该路径回落到 top.sdc:101 的 18.181 ns（更松）⇒ 🔴 **唯一的跨域时序检查被静默删除**。⚠️ 而 SDC 自己的验收要求（top.sdc:97）"Constraints Report 全部 Actived 且对象非空"是人工步骤，没有任何 CI 门。🔴 风险 2：`always @(negedge sample_clk)` 是全设计唯一的负沿寄存器（`grep -r "always @(negedge" rtl/` ⇒ 1 处）。在 Gowin 的 CLS 里，FF 的时钟极性需要在时钟网上插反相器（或走专用资源）⇒ 引入额外的时钟插入延迟/偏斜，而 10 ns 的预算假设偏斜为 0。若偏斜 1.5 ns ⇒ 真实预算只剩 8.5 ns。🔴 风险 3：top.sdc 里没有 `create_generated_clock` 或 `set_clock_groups` 描述这个负沿域，`set_max_delay -from clk_sys -to clk_sys` 是否把"负沿发射"算成半周期取决于工具；作者靠"显式钉 10 ns"绕过，但这等于放弃了工具自己的边沿推导。
- **改法**（推荐 = 彻底去掉负沿）：
```verilog
// waveform_scope.v —— 改回正沿，用"两级 + 灰码 + 独立约束"换取确定性
    (* async_reg = "true" *) reg [9:0] gray_launch;
    (* async_reg = "true" *) reg       full_launch;
    always @(posedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 10'd0; full_launch <= 1'b0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end
```
并把约束改成按 RTL 名 + 交叉时钟对（⛔ 不用综合后网名）：
```tcl
set_max_delay -datapath_only -from [get_clocks {clk_sys}] -to [get_clocks {pixel_clk}] 20.000
set_max_delay -datapath_only -from [get_clocks {clk_sys}] -to [get_clocks {serial_clk}] 8.000
set_false_path -hold -from [get_clocks {clk_sys}] -to [get_clocks {pixel_clk}]
```
（`-datapath_only` 让工具只约束数据路径，避免把时钟偏斜算进去；灰码保证单比特变化 ⇒ 不需要 hold 约束。）
- **预期**：收益 = 跨域约束不再依赖综合后网名（不会静默失配）；去掉负沿寄存器 ⇒ 少一个时钟反相资源、少一份偏斜；约束从"手工 10 ns"变成"工具可推导的时钟对关系"。代价 = 回到正沿后发射侧预算从 10 ns 变回 20 ns 的同沿关系 ⇒ 需要 `-datapath_only` + 灰码配合；必须重跑一次 PnR 确认 `pixel_clk` 侧没有新的 setup 违例（预计无，因为该路径逻辑极浅：`wr_gray` 是寄存器，到 `gray_launch` 只有布线）。
- **怎么验**：①约束对象非空（机械、可进 CI）：`Select-String -Path impl/pnr/Gowin2026_tr_content.html -Pattern 'gray_launch_|full_launch_' -SimpleMatch` —— 未修复：若综合改名，这里一个都搜不到 ⇒ 红。②负沿寄存器数量必须为 0（修复后）：`(Select-String -Path rtl/hdmi/waveform_scope.v -Pattern 'always\s*@\s*\(\s*negedge').Count` 期望 0。③时序：tb/hdmi 家族里加一条跨域一致性断言 —— 在 `pixel_clk` 侧解码 `gray_sync` 得到的二进制指针，永远不得跳过（单调、步长 ≤1）；把 `sample_clk` 相位随机化 200 次，未修复时会在某个相位抓到"跳 2"⇒ 红。
- **来源**：TORCH-3【P1-01】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-02|MOD=rtl/hdmi/hdmi_scope.v,rtl/hdmi/hdmi_clk.v
### 让 HDMI 域复位异步断言 + 同步释放，并让 OSER10.RESET 不再跨两域
- **位置**：rtl/hdmi/hdmi_scope.v:9-22、:19、:37-38；rtl/hdmi/hdmi_clk.v:17-18、:18；rtl/top.v:1228；constr/top.sdc:88-90、:90；tb/models/hdmi_primitives_model.sv:36；tb/hdmi；files/20-代码/H5显示修复与时序拉锯-记录与方向-20261002.md:695
- **现状**：
```verilog
// hdmi_scope.v:9-22
    wire pixel_clk, serial_clk, lock;
    reg [1:0] reset_pipe;
    wire video_reset_n = reset_pipe[1];
    hdmi_clk u_clk (.clk(clk), .rst_n(rst_n), .pixel_clk(pixel_clk),
        .serial_clk(serial_clk), .lock(lock));
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[0], lock};
    end
// hdmi_scope.v:37-38
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(!rst_n), .blue(blue), .green(green), .red(red),
// hdmi_clk.v:17-18
    PLLA u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
```
- **为什么是问题**：顶层把 `rst_n_sync`（`clk_sys` 域的寄存器输出）接到 `u_hdmi.rst_n`（top.v:1228 `.rst_n(rst_n_sync)`）。于是：1. hdmi_scope.v:19 用它作 `pixel_clk` 域的异步复位 ⇒ 释放沿与 `pixel_clk` 无固定关系 ⇒ `reset_pipe[0]`/`reset_pipe[1]` 可能不在同一拍释放 ⇒ `video_reset_n` 出现 1 拍的中间态 ⇒ video_timing / 3 个 tmds_encoder 可能差一拍脱离复位（与 P0-02 同族，但在跨域场景下更危险）。2. hdmi_scope.v:38 把 `!rst_n`（= `!rst_n_sync`）直接送 `OSER10.RESET` ⇒ 该复位被 `PCLK`(25 MHz) 与 `FCLK`(125 MHz) 两个时钟同时采样 ⇒ **跨 2 个域的异步复位**。项目自己量过：**recovery +1.490 ns / removal +0.217 ns**（top.sdc:90、H5显示修复与时序拉锯-记录与方向-20261002.md:695）⇒ 🔴 **removal 只有 0.217 ns（0.217/8 = 2.7% 个 125 MHz 周期）**。3. hdmi_clk.v:18 用 `!rst_n` 复位 PLL。`rst_n_sync` 一旦被按下（按键）⇒ PLL 停机 ⇒ `pixel_clk`/`serial_clk` 直接消失 ⇒ 此时 OSER10 的 RESET 也被断言，顺序不可控（PLL 停止与 OSER10 复位谁先谁后取决于布线）⇒ 上电/复位窗口里 TMDS 输出未定义序列（ANVIL-12 的 P1-01 已指出同一问题）。
- **改法**：
```verilog
// hdmi_scope.v —— ① pixel 域复位改成"异步断言 + 同步释放"，且由 lock 门控
    (* async_reg = "true" *) reg [2:0] reset_pipe;
    always @(posedge pixel_clk or negedge rst_n)
        if (!rst_n)        reset_pipe <= 3'b000;
        else               reset_pipe <= {reset_pipe[1:0], lock};   // 3 级：lock 也是异步源
    wire video_reset_n = reset_pipe[2];
    wire serial_reset_n = reset_pipe[2];        // ⭐ serial 域用同一个"已同步到 pixel 域"的释放沿
// hdmi_scope.v:37-38 —— ② OSER10 的 RESET 改由已同步的复位驱动（⛔ 不再用裸 rst_n）
    tmds_serializer u_serializer (.pixel_clk(pixel_clk), .serial_clk(serial_clk),
        .rst(!video_reset_n), .blue(blue), .green(green), .red(red),
// hdmi_clk.v:18 —— ③ PLL 复位保持由 clk_sys 域驱动（正确），但必须在 .cst 里给 CLKIN 的 PLL 加 lock 上拉/时序
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
```
⚠️ 不要为了消警告加 `set_clock_groups -asynchronous` —— top.sdc:88-90 已论证那会把真实检查一起删掉。
- **预期**：收益 = `removal` 从 **+0.217 ns** 变成同域同步路径（40 ns 预算）；消除 PLL 未锁期间 OSER10 输出未定义序列；代价 = 复位释放晚 3 个 `pixel_clk`（120 ns），对视频完全无影响；必须重跑全量回归（tb/models/hdmi_primitives_model.sv:36 的 OSER10 模型认 RESET 极性）。
- **怎么验**：tb/hdmi 里加：随机化 `rst_n` 释放相位（0..19 ns，200 种子），断言 `u_hdmi.reset_pipe` 的 3 位在同一拍变为全 1，且 `u_serializer.lanes[0].u_oser.RESET` 的释放沿落在 `video_reset_n` 释放之后 ≥1 个 `pixel_clk`；未修复：会在某个相位抓到"`reset_pipe[0]` 先脱离、`[1]` 后脱离"⇒ 红。
- **来源**：TORCH-3【P1-02】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-03|MOD=rtl/w3a/async_pluck_capture.v
### 让 async_pluck_capture 的"同时跳变确定 UP"成真
- **位置**：rtl/w3a/async_pluck_capture.v:1-4、:17、:17-22、:36-49、:36-39；rtl/top.v:3200-3202、:3202；tb/w3a/tb_async_pluck_capture.sv
- **现状**：
```verilog
// async_pluck_capture.v:1-4
// T15: LM393 UP/DOWN asynchronous outputs -> one synchronous pluck event.
// The first synchronized edge is accepted immediately; the refractory period
// only rejects later edges.  A simultaneous UP/DOWN edge is deterministically UP.
// :17-22, 36-49
    reg up_ff1, up_ff2, down_ff1, down_ff2;
    reg up_prev, down_prev;
    reg [31:0] refractory_q;
    wire up_rise   = up_ff2   && !up_prev;
    wire down_rise = down_ff2 && !down_prev;
            up_ff1    <= pluck_up_async_i;
            up_ff2    <= up_ff1;
            down_ff1  <= pluck_down_async_i;
            down_ff2  <= down_ff1;
            up_prev   <= up_ff2;
            down_prev <= down_ff2;
            pluck_valid_o <= 1'b0;
            if (refractory_q != 32'd0) begin
                refractory_q <= refractory_q - 32'd1;
            end else if (up_rise || down_rise) begin
                pluck_valid_o <= 1'b1;
                pluck_up_o    <= up_rise; // UP wins if both edges are present.
                refractory_q  <= REFRACT_CYC;
            end
```
- **为什么是问题**：`up_ff1/up_ff2` 与 `down_ff1/down_ff2` 是两条完全独立的 2 级同步链（:36-39）。当 UP 与 DOWN 在同一个 `clk_sys` 沿附近跳变（LM393 比较器开漏上拉，两路可以同时翻转），两级 FF 的亚稳态解除时间服从指数分布，两路互不相关 ⇒ 若 `up_ff2` 先变 1（第 N 拍）：`up_rise=1` ⇒ `pluck_up_o <= 1`，且 `refractory_q <= 1_500_000`；若 `down_ff2` 晚 1 拍变 1（第 N+1 拍）：`refractory_q != 0` ⇒ `else if (up_rise || down_rise)` 分支根本不执行 ⇒ 🔴 **DOWN 事件被静默丢弃**。⇒ 结果不是"确定 UP"，而是"先解除亚稳态的那一路赢，另一路被吃"。🔴 实际后果：用户同时拨动/摇杆回弹瞬间两路都动时，拨弦方向随机（这一次 UP、下一次 DOWN）。`REFRACT_CYC = 1_500_000`（top.v:3202）= **30 ms**，意味着一旦判错，30 ms 内不再接受任何修正。
- **改法**（保持"UP 优先"语义，但让它确定）：
```verilog
// async_pluck_capture.v —— 先合并成"任一路有上升沿"，再用【同拍可见】的组合优先
    (* async_reg = "true" *) reg [1:0] up_sync, down_sync;   // 见 P1-04
    reg [1:0] up_prev2, down_prev2;
    wire up_rise_c   = up_sync[1]   && !up_prev2[1];
    wire down_rise_c = down_sync[1] && !down_prev2[1];
    reg pending_dir_q, pending_en_q;
    always @(posedge clk_i) begin
        ...
        if (!pending_en_q) begin
            if (up_rise_c) begin
                pending_en_q <= 1'b1; pending_dir_q <= 1'b1;
            end else if (down_rise_c) begin
                pending_en_q <= 1'b1; pending_dir_q <= 1'b0;
            end
        end else begin
            pending_en_q <= 1'b0;
            if (refractory_q == 32'd0) begin
                pluck_valid_o <= 1'b1;
                pluck_up_o    <= pending_dir_q | down_rise_c;   // ⭐ UP 永远优先
                refractory_q  <= REFRACT_CYC;
            end
        end
    end
```
（核心：把"方向判定"与"不应期开闸"解耦 —— 先记录两路是否都来了，再统一决定方向。⛔ 不要在 refractory 分支里吞事件。）
- **预期**：收益 = 拨弦方向确定（UP 恒优先）；代价 = 首次拨弦晚 1 拍（20 ns）—— 对 30 ms 不应期完全无感；多 2 个 FF。⚠️ 必须同步更新 top.v:3200-3202 的注释（它现在写着"此处只兜住摇杆回弹，不延迟首次拨弦"）。
- **怎么验**：tb/w3a/tb_async_pluck_capture.sv（若无则新建）：对 `up`/`down` 施加相对偏移 0/1/2 拍的成对上升沿，每个偏移跑 100 个随机相位种子，断言 `pluck_up_o === 1'b1` 恒成立；未修复：偏移 1 拍时，约 50% 的种子 `pluck_up_o == 0`（DOWN 先解除）⇒ 红。另加一条：断言 `pluck_valid_o` 的脉冲数 == 注入的成对事件数（未修复时 DOWN 被吞 ⇒ 少脉冲）。
- **来源**：TORCH-3【P1-03】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-04|MOD=rtl/w3c/uart_rx.v,rtl/w3a/async_pluck_capture.v,rtl/hdmi/waveform_scope.v,rtl/hdmi/hdmi_scope.v
### 给 4 处手写同步器补 async_reg 属性
- **位置**：rtl/rst_sync.v:37；rtl/sync_input.v:42；rtl/w3c/uart_rx.v:107、:111-119；rtl/w3a/async_pluck_capture.v:17、:36-39；rtl/hdmi/waveform_scope.v:47-48、:55-62；rtl/hdmi/hdmi_scope.v:10、:19-22；rtl/drivers/debounce.sv:9-12
- **现状**：
```verilog
// 有标注的，仅 2 处
// rst_sync.v:37
    (* async_reg = "true" *) reg [STAGES-1:0] sync_chain;
// sync_input.v:42
    (* async_reg = "true" *) reg [W-1:0] chain [0:STAGES-1];
// 缺标注的，4 处 / 20 个 FF
// rtl/w3c/uart_rx.v:107  —— 2 FF
    reg         rx_d1, rx_d2;       // ⭐ 两级同步打拍
// rtl/w3a/async_pluck_capture.v:17  —— 4 FF
    reg up_ff1, up_ff2, down_ff1, down_ff2;
// rtl/hdmi/waveform_scope.v:47-48  —— 22 FF
    reg [9:0] gray_meta, gray_sync;
    reg full_meta, full_sync;
// rtl/hdmi/hdmi_scope.v:10  —— 2 FF
    reg [1:0] reset_pipe;
```
- **为什么是问题**：`(* async_reg = "true" *)` 在 Gowin/Synplify 里的作用是禁止对这两级做重定时（retiming）、合并、以及把两级塞进同一 CLB 共享时钟。没有它：综合器可以把 `rx_d1`/`rx_d2` 重定时合并（因为逻辑上 `rx_d2` 只是 `rx_i` 的两拍延迟）⇒ 🔴 **2 级同步器退化成 1 级** ⇒ 亚稳态 MTBF 从 `e^(t_r/τ)` 的平方级掉回线性级；τ 与 `t_r` 依工艺而定，保守估计 MTBF 掉 3~6 个数量级（从"万年一遇"掉到"几天一遇"）。`waveform_scope.v:47-48` 的 `gray_meta`/`gray_sync` 是 10 位总线：两级若被塞进同一 CLB，10 位的位间偏斜在同一个时钟沿上不可控 ⇒ 灰码"单比特变化"的前提被破坏。⚠️ 而本项目自己的纪律（rtl/drivers/debounce.sv:9-12）明文写着 K-62 要求所有板外异步输入走 `sync_input`："本模块在端口层面不例化 sync_input…由顶层负责同步（与 K-62「仍待做：把 SPI/按键输入实际接上 sync_input」一致）" ⇒ 🔴 **K-62 至今是"待做"，而不是"已做"** —— 这条纪律在文档里存在、在代码里只落实了 3 处。
- **改法（4 处各 1 行）**：
```verilog
// uart_rx.v:107
    (* async_reg = "true" *) reg rx_d1, rx_d2;
// async_pluck_capture.v:17
    (* async_reg = "true" *) reg up_ff1, up_ff2, down_ff1, down_ff2;
// waveform_scope.v:47-48
    (* async_reg = "true" *) reg [9:0] gray_meta, gray_sync;
    (* async_reg = "true" *) reg full_meta, full_sync;
// hdmi_scope.v:10
    (* async_reg = "true" *) reg [1:0] reset_pipe;
```
⭐ 更彻底的做法：把 uart_rx.v:111-119、async_pluck_capture.v:36-39、waveform_scope.v:55-62、hdmi_scope.v:19-22 全部改成例化 `sync_input`（它已有 async_reg + 参数化级数 + RESET_VAL）⇒ 一处标注、全设计受益，且下次新增同步器不会漏。
- **预期**：收益 = 同步器结构上不可能被优化掉；MTBF 回到设计意图；灰码总线位间偏斜可控；代价 = **4 行属性（或 4 处例化替换）**、0 资源变化；⚠️ 替换成 sync_input 时要逐位（W=1）以免引入 P1-10 的多比特问题。
- **怎么验**：1. 静态（进 CI）：脚本扫描 rtl/，凡出现"两级同名前缀 FF 且第二级由第一级驱动、第一级由 `_i`/`_async` 驱动"的模式，必须同时在同一行或紧邻上一行出现 `async_reg`；当前会报 4 处违规。2. 动态：跑 Gowin 综合，检查综合后网表里同步器是否仍是 2 个独立 FF（用 impl/gwsynthesis/Gowin2026_syn.rpt.html 的寄存器列表）；未修复：可能在某个综合设置（`-retiming`）下变成 1 个 FF ⇒ 红。
- **来源**：TORCH-3【P1-04】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-05|MOD=constr/top.sdc
### 给 18 类未约束 I/O 补输入/输出延时
- **位置**：constr/top.sdc:62-71、:23-28、:60；rtl/top.v:349-501；rtl/w3a/ws2812_driver.v:59-61、:21-29；rtl/drivers/tlc5916_driver.sv:117；rtl/w3c/uart_rx.v:111；rtl/drivers/adc_farm.sv:90；rtl/top.v:575、:637；rtl/w3a/async_pluck_capture.v:36
- **现状**：
```tcl
# top.sdc:62-71 —— 这就是全部 I/O 约束
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]
set_false_path -to [get_ports {PA_EN_n}]
set_false_path -to [get_ports {led_heartbeat}]
set_false_path -from [get_ports {rst_n}]
未约束的输出：ctrl_ws_o（C22，WS2812 800 kHz）· spi_sclk/spi_mosi/spi_cs_n[5:0]（1 MHz）·
led_sdi/led_clk/led_le/led_oe_n[4:0]（1 MHz，TLC5916 tSU 8.5 ns）· I2S2_BCK/LRCK/DIN（与 HP_* 完全相同）·
uart_tx/esp_uart_tx_o（500 kbps）· tmds_d_p_0[2:0]/tmds_clk_p_0（250 Mb/s/lane）
未约束的输入（全部板外异步）：uart_rx · spi_miso[5:0] · timbre_btn_i · pedal_sus_i · pluck_up_i/pluck_down_i ·
ctrl_col_i[3:0] · enc_a_i/enc_b_i/enc_sw_i · pedal_loop_rec_i/pedal_loop_play_i · esp_uart_rx_i
```
- **为什么是问题**：top.sdc:23-28 自己写明："它只约束寄存器→寄存器的路径。进出引脚的路径…在没有 `set_output_delay`/`set_input_delay` 时不被分析" ⇒ 对同步器而言，"不被分析"意味着 `port → chain[0]` 的建立时间没有预算。亚稳态 MTBF ∝ `e^(t_r/τ)`，其中 `t_r = T_clk − t_su − t_route`；没有约束 ⇒ 工具不会去缩短 `t_route` ⇒ 若综合/布局把 `chain[0]` 放得离引脚很远（AC1/I0 慢档，20 ns 周期下 route 可达 5~8 ns），`t_r` 被吃掉 25~40% ⇒ **MTBF 掉好几个数量级**。对输出而言：`ctrl_ws_o` 的 T0H=**17 clk = 340 ns** / T1H=**35 clk = 700 ns**（ws2812_driver.v:59-61）是寄存输出，但 `dout_o` 是 `assign`（组合，见 P1-08）⇒ 其边沿位置 = FF clk-to-Q + 未约束的布线延迟。WS2812 的容限是 ±150 ns，看起来很宽，但 `led_sdi/led_clk` 的 TLC5916 **tSU 只有 8.5 ns**（tlc5916_driver.sv:117 注释）⇒ 一个未约束的 10 ns 布线差就能吃掉全部建立余量。
- **改法**（constr/top.sdc 追加；数值取"外部器件要求"，⛔ 不要用 false_path 图省事）：
```tcl
set_output_delay -clock clk_sys -max 50.0 [get_ports {ctrl_ws_o}]
set_output_delay -clock clk_sys -min -50.0 [get_ports {ctrl_ws_o}]
set_output_delay -clock clk_sys -max 40.0 [get_ports {spi_sclk spi_mosi}]
set_output_delay -clock clk_sys -max 40.0 [get_ports {spi_cs_n[*]}]
set_output_delay -clock clk_sys -max 40.0 [get_ports {led_sdi led_clk led_le}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {I2S2_BCK I2S2_LRCK I2S2_DIN}]
set_output_delay -clock clk_sys -max 100.0 [get_ports {uart_tx esp_uart_tx_o}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {uart_rx spi_miso[*] timbre_btn_i pedal_sus_i}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {pluck_up_i pluck_down_i}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {ctrl_col_i[*] enc_a_i enc_b_i enc_sw_i}]
set_input_delay -clock clk_sys -max 10.0 [get_ports {pedal_loop_rec_i pedal_loop_play_i esp_uart_rx_i}]
```
- **预期**：收益 = 11 个异步输入的同步器首次获得真实建立预算 ⇒ MTBF 可量化、可优化；WS2812/SPI/TLC5916 的位边沿首次被工具守住；外置 I2S 与板载 I2S 同约束（消除"板载对、外置错"的隐患）。代价 = ⚠️ 会新增一批 setup 报告条目，可能暴露真实违例（这正是目的）；`set_output_delay -max 2.0` 对 `I2S2_*` 会把内部预算压到 18 ns（与板载一致）—— 已验证板载那路可过（top.sdc:60 实测 11.827 ns 路径）。
- **怎么验**：机械判据：SDC 里出现的 I/O 端口名必须覆盖 top.v 的全部非直流端口 —— 脚本列出 `get_ports` 行，检查 `ctrl_ws_o/spi_sclk/spi_miso/spi_cs_n/led_sdi/I2S2_BCK/uart_tx/esp_uart_tx_o/enc_a_i/esp_uart_rx_i` 是否缺失；当前会报 10 个未约束端口 ⇒ 红。修复后必须绿，并同时要求 PnR 的 setup/hold 违例仍为 0/0。
- **来源**：TORCH-3【P1-05】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-06|MOD=rtl/w3b/note_manager.v,rtl/w3b/tdm_render_mixer.v,constr/top.sdc
### 拆掉全设计最差 25 条路径（T3 旋转链 + prod_c 进位链）并核验 required
- **位置**：impl/pnr/Gowin2026.timing_paths；rtl/w3b/note_manager.v（g_t3）；rtl/w3b/tdm_render_mixer.v（prod_c/vs_dif）；constr/top.sdc:101、:81-83；rtl/top.v:329、:324-327；tb/w3b/tb_note_manager_t3.sv
- **现状**：
```
前 6 条（按 slack 升序，机械解析自 timing_paths）：
| 1 | +0.102 | 22.172 | 22.274 | 12 | g_sound.u_note_manager/g_t3.phase_tr[28]_24_s0 | 结构性 |
| 2 | +0.133 | 20.062 | 20.194 | 21 | g_sound.u_tdm_render_mixer/prod_c_0_s | 结构性（21 级！）|
| 3 | +0.154 | 22.120 | 22.274 | 12 | g_sound.u_note_manager/g_t3.phase_tr[24]_24_s0 | 结构性 |
| 4 | +0.191 | 22.066 | 22.257 | 12 | g_sound.u_note_manager/g_t3.phase_tr[26]_30_s0 | 结构性 |
| 5 | +0.208 | 22.066 | 22.274 | 12 | g_sound.u_note_manager/g_t3.phase_tr[10]_30_s0 | 结构性 |
| 6 | +0.604 | 19.611 | 20.215 | 21 | g_sound.u_tdm_render_mixer/prod_c_0_s | 结构性 |
路径 #2：g_sound.u_tdm_render_mixer/cnt_4_s0 → n4361_s3 → n41_s88 → n101_s44 → n101_s37 → n101_s33
  → vs_dif_4_s → vs_dif_5_s → … → vs_dif_17_s → prod_c_0_s
⭐ vs_dif_4..17 连续 14 跳、每跳约 0.045 ns —— 这是 Gowin ALU 进位链的单级延迟 ⇒ 14 级串行进位链
全 25 条统计：u_note_manager（T3 旋转器 g_t3.*）19/25（全部 L=12，slack +0.102~+0.823，data 21.447~22.172）；
u_tdm_render_mixer（prod_c）6/25（L=20~21，slack +0.133~+0.851，data 19.360~20.062）；其他模块 0/25
```
- **为什么是问题**：全部 25 条都是模块内路径 —— 用户担心的"跨模块组合穿透导致长路径"在本版 PnR 里不是最差路径的主因；真正的头号瓶颈是 T3 变调（`T3_ENABLE=1`，top.v:329）的旋转/乘法链与 TDM 混音的饱和累加链。⚠️ 但余量只有 **+0.102 ns（= 0.56% 个周期）** ⇒ 用户实测的"同源重跑差 2~3 MHz"（≈0.7~1.1 ns 的周期变化）足以把 #1~#8 全部打成负 slack ⇒ 🔴 这就是"偶发红/偶发绿"的机械来源。🔴 附带发现（约束覆盖存疑）：报告里 `required` 是 **22.274 / 22.257 / 20.194 / 20.215 ns**，而 top.sdc:101 写的是 **18.181 ns**。若这 25 条被 18.181 覆盖 ⇒ required 应为 ≈18.18、slack 应为 −4 ns 级（与"0 违例"矛盾）；若未被覆盖 ⇒ 🔴 `set_max_delay -from clk_sys -to clk_sys 18.181` 对这 25 条最差路径不生效。两种解释都指向一个必须查清的事实：`Actual Fmax = 55.060 MHz`（= 1/18.162 ns）与路径表的 required 不自洽 ⇒ 该 Fmax 是 top.sdc:81-83 自己承认的"外推值"，不能当作 18.181 ns 目标的达标证据。
- **改法**：1. ⭐ 立刻（零风险）：把 top.sdc:101 的 `set_max_delay` 换成显式、可核验的写法，并加 `-datapath_only`：`set_max_delay -datapath_only -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181`，然后重新生成 Constraints Report，确认这 25 条路径的 required 真的变成 18.181；⛔ 在那之前，"0 setup 违例"不能作为 18.181 ns 达标的证据。2. ⭐ 治本（T3 链）：note_manager 的 `g_t3` 旋转器插一级流水（把 `rot_base`/`prod_w` 拆成两级），代价 = 变调生效晚 1 拍（20 ns），听感无影响；预期把 #1/#3~#14 的 slack 从 0.1~0.6 ns 抬到 2~3 ns。3. ⭐ 治本（prod_c 链）：tdm_render_mixer 的 `vs_dif` 进位链拆成两拍累加（先算 16 路、再算后 16 路），代价 = 混音晚 1 拍（在 1024 拍帧预算里完全装得下，当前只用 100/1024）。4. ⭐ 保底（若不能改 RTL）：把 `T3_ENABLE` 置 0（top.v:329）出正式码流 —— top.v:324-327 已记录"影子数组版 `T_Lut 29622`，比 T3 关的基线还低 1417" ⇒ 关掉 T3 是净收益。
- **预期**：改法 1：收益 = 约束可信；代价 = 0。改法 2/3：收益 = 最差 slack 从 +0.102 ns 抬到 >2 ns（抗住 ±2~3 MHz 布局噪声）；代价 = 各 1 拍延迟 + 需重跑全量回归 + 一次 PnR。改法 4：收益 = 直接去掉 19/25 条最差路径（note_manager 那 19 条全部消失）；代价 = 失去 T3 实时变调（用户已裁定"最终效果没问题就行"，需确认）。
- **怎么验**：机械判据（可进 CI）：最差 setup slack 必须 >= 1.0 ns（抗布局噪声）—— 解析 timing_paths 的 SETUP 块第一个数取最小；当前 min = 0.102 ⇒ 红（< 1.0）；另：required 必须 == 18.181（±0.01）⇒ 当前 = 22.274 ⇒ 红（约束未覆盖）。②行为判据：tb/w3b/tb_note_manager_t3.sv 家族必须证明"插流水后变调值逐位不变，只是晚 1 拍"。
- **来源**：TORCH-3【P1-06】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-07|MOD=rtl/top.v,rtl/drivers/calib.sv,sim/gowin_build.ps1
### 改正"全设计只有 1 个 DSP"的文档并把资源数做成机械判据
- **位置**：rtl/top.v:4258；rtl/drivers/calib.sv:373；rtl/top.v:2479、:2499；sim/evidence/final-batch-20261008/pnr-rpt.txt
- **现状**：
```verilog
// top.v:4258
        // ⭐ TDM 混音 + 饱和（T56）—— ⭐ 全设计**只有 1 个 DSP**
// calib.sv:373
            prod_r <= dclamp * gain_rd;
（u_calib0 @ top.v:2479、u_calib1 @ top.v:2499 ⇒ 2 个 12×12 乘法器）
实测资源（sim/evidence/final-batch-20261008/pnr-rpt.txt）：
DSP                         | 22/118                              |  19%
--MULT12X12                 | 6
--MULT27X36                 | 6
--MULTALU27X18              | 7
CLS                         | 23228/29952                         |  78%
Register                    | 16975/60780                         |  28%
```
- **为什么是问题**：文档断言 1 个，实测 22 个 ⇒ **差 22 倍**。这直接影响三件事：1. 资源预算失真：DSP 已用 19%（22/118）；若后续按"还有 117 个 DSP 可用"做设计决策，会踩空。2. 时序理解失真：DSP 有固定的流水/组合延迟（`MULT12X12` 组合路径约 4~6 ns @AC1/I0）；最差路径 #2（`u_tdm_render_mixer/prod_c`，Logic Level 21）里 `prod_c` 很可能就是一个乘法器输出寄存器 ⇒ 把乘法器当"LUT 拼的浅逻辑"来估时序，必然低估。3. `calib` 的 2 个乘法器在 `pos` 通路的关键位置上（`prod_r` 直接决定 `pos` ⇒ 决定按键触发）⇒ 它们是 `axis_snapshot → event_extract` 链路的一环，⛔ 不是"无关紧要的角落"。
- **改法**：1. ⭐ 立即改正文档：top.v:4258 改为 `// ⭐ TDM 混音 + 饱和（T56）—— 实测 PnR：DSP 22/118（19%）；--MULT12X12 6 · --MULT27X36 6 · --MULTALU27X18 7（见 sim/evidence/final-batch-20261008/pnr-rpt.txt）；⚠️ 原注释"全设计只有 1 个 DSP"与实测不符（差 22 倍）⇒ 已作废`。2. ⭐ 把资源数字做成机械判据（进 sim/gowin_build.ps1 验收）：解析 pnr-rpt.txt 的 `DSP` 行，与 RTL 里 `*` 的出现次数（grep -c 乘号）做量级核对；偏差 > 2× 则 FAIL。3. ⭐（可选）把 calib 的乘法器换成移位相加：`gain_rd` 是 `(4095<<8)/(span-zero)` 的商，不是常数 ⇒ 不能强度缩减 ⇒ 保留 DSP 是正确的；但应在注释里写明"这 2 个 DSP 是必须的"。
- **预期**：收益 = 资源/时序模型回到地面真相；代价 = **1 段注释 + 1 条 CI 检查**，0 资源。
- **怎么验**：`$dsp = (Select-String -Path sim/evidence/final-batch-20261008/pnr-rpt.txt -Pattern '^DSP\s+\|').Line`；`$claim = (Select-String -Path rtl/top.v -Pattern '只有\s*\*?\*?1\s*个\s*DSP').Count`；`if ($claim -gt 0 -and $dsp -notmatch '22/118') { "RED: 文档 DSP 声明与实测不符"; exit 1 }` ⇒ 当前红。
- **来源**：TORCH-3【P1-07】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-08|MOD=rtl/w3a/ws2812_driver.v,rtl/top.v,constr/top.sdc
### 给 WS2812 数据脚加输出寄存与输出约束，并消掉跨模块 8:1 mux
- **位置**：rtl/w3a/ws2812_driver.v:130、:129-130、:21-29、:59-61；rtl/top.v:5003-5014、:4957、:5005-5011；constr/top.sdc；tb/w3a/tb_ws2812_driver.sv
- **现状**：
```verilog
// ws2812_driver.v:129-130
    // High for T0H or T1H cycles, then low for the rest of the cell.
    assign dout_o = (state == S_SEND) && (bit_t < (cur_bit ? T1H : T0H));
// top.v:4957
    assign ctrl_ws_o  = ws_dout;          // ⭐ 控制板灯带（C22）
// top.v:5003-5014 —— led_indicator 的 168 位寄存输出 → 组合 8:1 mux → ws2812 写口
    always @* begin
        case (ws_wr_addr)
            5'd0: ws_wr_data = led_col_flat[  0 +: 24];
            ...
            5'd6: ws_wr_data = led_col_flat[144 +: 24];
            default: ws_wr_data = 24'h000000;
        endcase
    end
```
- **为什么是问题**：1. 组合直出引脚：`dout_o` 由 `state`（FF）· `bit_t`（FF）· `cur_bit`（FF）经 1 个比较器 + 1 个 mux 产生 ⇒ 引脚边沿 = FF clk-to-Q + 组合延迟 + 未约束的输出布线延迟。WS2812 要求（ws2812_driver.v:21-29）：T0H = 17 clk = 340 ns（spec 350 ±150）、T1H = 35 clk = 700 ns（spec 700 ±150）、BIT_CYC = 62 clk = 1240 ns（spec 1250 ±600）⇒ 位周期容限很宽，但：`bit_t < (cur_bit ? T1H : T0H)` 存在同沿竞争（`bit_t`、`cur_bit`、`state` 同一个时钟沿更新）⇒ mux + 比较器在沿后可能产生短毛刺，对 800 kHz 无影响（毛刺 ns 级），⚠️ 但对 `led_sdi/led_clk` 那类 tSU=8.5 ns 的器件（TLC5916）就不一定（见 P1-05）；且 `ctrl_ws_o` 不在 SDC 里 ⇒ 布线延迟完全未表征。2. 跨模块组合穿透：`led_indicator.led_col_o`（168 FF）→ top.v:5003 的 8:1 × 24 位 mux → `ws2812_driver.mem[]` 写口，⛔ 中间没有寄存器。24 位 × 8 选 1 = 约 48~72 LUT，2 级逻辑；虽浅，但它是"A 的输出不经过任何寄存器就进 B 的输入"的教科书例子。3. 扇出：`led_col_flat`（168 位）同时扇出到 8 个 case 分支 ⇒ 每一位扇出 8（top.v:5005-5011）⇒ 布线压力。
- **改法**：
```verilog
// ① ws2812_driver.v —— 输出加一级寄存（引脚时序可预测）
    reg dout_r;
    always @(posedge clk) begin
        if (!rst_n) dout_r <= 1'b0;
        else        dout_r <= (state == S_SEND) && (bit_t < (cur_bit ? T1H : T0H));
    end
    assign dout_o = dout_r;
// ② top.v:5003-5014 —— 把 mux 的结果打一拍（切断跨模块组合链）
    reg [23:0] ws_wr_data_r;
    always @(posedge clk) ws_wr_data_r <= ws_wr_data_mux;   // ws_wr_data_mux = 原 case 结果
    // ⚠️ 但 ws_wr_data 必须与 ws_wr_addr 同拍 ⇒ 地址也要一起打拍（或把整个 case 挪进寄存器）
```
⭐ 更干净的做法：把 `led_col_flat → mem[]` 的搬运整体移进 ws2812_driver 的一个帧缓冲写端口，用 `led_col_flat` 直接做 `mem` 的初始值（wr_en 由 top 的装载器给）⇒ 消掉 top.v 里的 8:1 mux（省 ~72 LUT），且写口与地址天然同拍。
```tcl
# ③ constr/top.sdc —— 补输出约束（见 P1-05）
set_output_delay -clock clk_sys -max 50.0 -min -50.0 [get_ports {ctrl_ws_o}]
```
- **预期**：①：收益 = 引脚边沿只含 clk-to-Q + 布线，时序可分析；代价 = 数据晚 1 clk（20 ns）⇒ 必须把 `T0H/T1H` 各 +1 或把 `BIT_CYC` 检查重算（⚠️ 否则 T0H 变 360 ns、T1H 变 720 ns —— 仍在 spec 内，但注释必须同步）。②/③：收益 = 切断跨模块组合链、省 LUT、边沿被约束；代价 = 1 拍延迟（写口）+ 需重跑 tb_ws2812_driver。
- **怎么验**：1. 时序：tb/w3a/tb_ws2812_driver.sv 里逐位量 `dout_o` 的高电平拍数，断言 `高拍数 ∈ {17±1, 35±1}` 且 `低拍数 = 62 − 高拍数`；加输出寄存后未同步改 `T0H/T1H` ⇒ 变 `{18,36}` ⇒ 红。2. 组合穿透（静态）：脚本检查 `assign ctrl_ws_o` 的驱动源是否经过寄存器 —— 当前 `dout_o` 是 `assign`（组合）⇒ 红；修复后必须指向一个 `reg`。3. 约束覆盖：见 P1-05 的机械脚本（`ctrl_ws_o` 当前不在 `get_ports` 列表 ⇒ 红）。
- **来源**：TORCH-3【P1-08】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-09|MOD=rtl/w3a/axis_snapshot.v,rtl/top.v
### 给 axis_snapshot 的 pos_o/delta_o 加一级寄存（连 snap_valid 一起打拍）
- **位置**：rtl/w3a/axis_snapshot.v:202-214、:211；rtl/top.v:2785-2787、:1202、:3258、:2888、:2936、:2753-2757、:3137；tb/w3a/tb_axis_snapshot.sv
- **现状**：
```verilog
// axis_snapshot.v:202-214
    generate
        for (gi = 0; gi < AXIS_N; gi = gi + 1) begin : gen_out
            // ⭐ 本帧行程（⭐ 快照那一拍 cur 就是本帧值）
            assign pos_o[gi*POS_W +: POS_W] = cur[gi];
            // ⭐⭐ 带符号增量：delta = cur − prev
            assign delta_o[gi*DW +: DW] = {1'b0, cur[gi]} - {1'b0, prev[gi]};
        end
    endgenerate
// top.v:2785-2787 —— 消费点 ①：16:1 mux → 22 位三项加减 → 寄存器
        wire [11:0] vu_pos = as_pos[vu_ax_r*12 +: 12];
        wire [7:0]  vu_vel = pos_to_vel(vu_pos);
// top.v:1202 —— pos_to_vel 内部：22 位 (p<<8) + (p<<3) − p
            prod       = (p22 << 8) + (p22 << 3) - p22;    // ⭐ ×263（⛔ 无乘法器）
// top.v:3258 —— 消费点 ②：16:1 mux → 寄存器
                    am_pos_in  <= as_pos[pm_axis*12 +: 12];
// top.v:2888 —— 消费点 ③：16:1 mux → pos_probe
            .pos_i      (as_pos[np_axis_r*12 +: 12]),
// top.v:2936 —— 消费点 ④（仅 DPOS_DIAG=1）：16 组并联减法 + 16 路最大值比较
                    if ({1'b0, dpos_abs_f(as_pos[dpi*12 +: 12], as_pos_d[dpi])} > {1'b0, dpos_pk_r}) begin
```
- **为什么是问题**：`pos_o` 是 **192 位**（16×12）、`delta_o` 是 **208 位**（16×13）的组合总线，源头是 32 个 `reg` 数组（`cur[]`/`prev[]`，共 **384 FF**）。⇒ `cur[]` 的每一位扇出到 4 个不同模块的 16:1 mux（event_extract · param_extract · pos_probe · vu_*）＋ `delta_o` 的 16 个 13 位减法器（axis_snapshot.v:211）→ event_extract。⇒ 消费点① 的完整组合链：`axis_snapshot.cur[]`（FF）→ 16:1 mux（12 位，2 级 LUT）→ `pos_to_vel` 的 22 位 3 项加减（`<<8` + `<<3` − 1，约 2~3 级 LUT4/ALU）→ `vu_val_r`（FF）；合计约 5 级逻辑。这是教科书式的"A 的输出不经过任何寄存器就进 B 的组合逻辑"，且 `as_pos` 是 192 位宽的高扇出总线。⚠️ 本次 PnR 里它没有进前 25 名（见 P1-06）⇒ 说明当前布局把它排得不错，但它是结构性的（逻辑深度 5 级 + 192 位扇出），属于"布局运气在帮忙"的那一类：一旦 axis_snapshot 与 event_extract/vu_* 被摆远，2~3 MHz 的布局噪声就可能把它推进红区。
- **改法**（按代价排序）：1. ⭐ 零风险、先做：在 axis_snapshot 出口加一级寄存（`pos_o`/`delta_o` 各打一拍），同时把 `snap_valid_o` 一起打第二拍（⛔ 必须同拍，否则犯 K-109"valid 与 data 不同拍"的老毛病）：
```verilog
    reg [AXIS_N*POS_W-1:0] pos_r;  reg [AXIS_N*DW-1:0] delta_r;  reg snap_r;
    always @(posedge clk) begin
        if (!rst_n) begin pos_r <= 0; delta_r <= 0; snap_r <= 0; end
        else begin
            for (gi=0; gi<AXIS_N; gi=gi+1) begin
                pos_r[gi*POS_W +: POS_W] <= cur[gi];
                delta_r[gi*DW +: DW]     <= {1'b0, cur[gi]} - {1'b0, prev[gi]};
            end
            snap_r <= snap_valid_o;
        end
    end
    assign pos_o = pos_r; assign delta_o = delta_r;
```
⚠️ 代价：`snap_valid_o` 整体晚 1 拍 ⇒ 必须同步检查 `event_extract` 的 `REFRACT_N(60)`（top.v:3137）与 `calib_span` 的 `STABLE_NEED/VOTE_N` 是否按"帧"计（是，按帧 ⇒ 不受影响）⇒ 收益：192+208 位的高扇出总线变成寄存器到寄存器的干净起点，消费点①的链缩短 2 级。2. ⭐ 治本：把"16:1 选轴"挪进 axis_snapshot 内部，对 16 个轴各算一份 `vel` 并寄存（`pos_to_vel` 复用同一函数 ⇒ 公式仍只有一份），下游直接按轴取；⚠️ 代价 = 16 × 22 位加法器（约 350 LUT）—— 与 top.v:2753-2757 记录的"Fmax 余量只有 +0.18%"相冲，需实测。
- **预期**：改法 1 = 收益（结构链 −2 级、扇出被寄存器隔断）/ 代价（1 拍延迟 + 需回归）；改法 2 = 收益（彻底消除选轴 mux）/ 代价（+350 LUT，可能挤掉时序余量）。
- **怎么验**：1. 静态：脚本断言 `axis_snapshot.pos_o`/`delta_o` 的驱动必须经过寄存器；当前是 `assign ... = cur[gi]`（组合）⇒ 红。2. 动态（K-109 同拍性）：tb/w3a/tb_axis_snapshot.sv 断言 `snap_valid_o` 拉高的那一拍，`pos_o` 必须等于本帧写入的最后一个通道值；加寄存器但忘了把 `snap_valid_o` 一起打拍 ⇒ 该断言在"帧边界"抓错值 ⇒ 红。3. 时序：加寄存器后重跑 PnR，断言最差 slack 不下降（当前 +0.102 ns 是全局最差，不受此影响，但要看 `vu_*` 相关路径的余量）。
- **来源**：TORCH-3【P1-09】
@@@END
@@@PRIO=P1|SRC=TORCH-3|ORIG=P1-10|MOD=rtl/top.v
### 给 7 个板外异步输入补同步器并让 esp_uart_rx_i 走自己的 uart_rx
- **位置**：rtl/top.v:4898-4900、:498-501、:4902-4906、:4885-4887、:575、:637；rtl/drivers/adc_farm.sv:90；rtl/drivers/debounce.sv:178-181；tb/top
- **现状**：
```verilog
// top.v:4898-4900
    (* syn_keep = 1 *) wire reserved_in_xor = ^{ctrl_col_i, enc_a_i, enc_b_i, enc_sw_i,
                                                pedal_loop_rec_i,
                                                pedal_loop_play_i, esp_uart_rx_i};
// top.v:498-501
    output wire esp_uart_tx_o,      // G21 · PMOD0 针 9 · IO2（出 · → ESP32 的 RX）
    input  wire esp_uart_rx_i,      // G22 · PMOD0 针 10 · IO3（入 · ← ESP32 的 TX · 上拉）
    output wire [2:0] ws_strip_o    // W19/W20/F19 · PMOD1 针 11/12/9 · IO0/IO1/IO2（出）
// top.v:4902-4906 —— 异或结果【直接】进一个 FF，无任何同步
    (* syn_keep = 1 *) reg  reserved_in_r;
    always @(posedge clk) begin
        if (!rst_n_sync) reserved_in_r <= 1'b0;
        else             reserved_in_r <= reserved_in_xor;
    end
```
- **为什么是问题**：`grep -r "sync_input" rtl/` 的全部例化只有 3 处：top.v:575（`timbre_btn_i`）· top.v:637（`pedal_sus_i`）· adc_farm.sv:90（`spi_miso` ×N_ADC）。⇒ 下列 7 个（按位算 10 位）板外异步输入没有任何同步器：`ctrl_col_i[3:0]`（4 位，F15/C20/D20/D19，4×4 矩阵列入）· `enc_a_i`（E19，EC11 A 相）· `enc_b_i`（C19）· `enc_sw_i`（C18）· `pedal_loop_rec_i`（E18）· `pedal_loop_play_i`（B22）· `esp_uart_rx_i`（G22，ESP32 UART 接收）。两条风险：1. `reserved_in_r` 是"10 位异步信号的异或"直接进 FF（top.v:4905）⇒ 该 FF 会亚稳态；今天它没有消费者 ⇒ 无功能后果；⚠️ 但它是"下一个接入者"的陷阱：一旦有人读 `reserved_in_r`（或读 `reserved_in_xor`）做任何判断，就拿到一个未同步的 10 位异步组合值。2. `esp_uart_rx_i` 是已声明的功能端口（top.v:499 注释"← ESP32 的 TX"）⇒ ESP32 线一接上，它就是第二个 UART 入口，而它没有 `sync_input`、没有 `uart_rx` 实例。⚠️ 这正是 P0-03 推荐的结构性修法（"曲谱走独立 UART"）所依赖的那根线 ⇒ 两条缺陷在同一根线上会师。
- **改法**：
```verilog
// top.v —— 每个异步输入在【进入任何逻辑之前】先过 sync_input（与 timbre/pedal 完全同款）
    // ── ① 4×4 矩阵列入（上拉 ⇒ 空闲 1、按下 0）—— 逐位同步
    wire [3:0] ctrl_col_s;
    genvar gc;
    generate for (gc=0; gc<4; gc=gc+1) begin : g_col_sync
        sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_col_sync (
            .clk(clk), .rst_n(rst_n_sync), .async_in(ctrl_col_i[gc]), .sync_out(ctrl_col_s[gc]));
    end endgenerate
    // ── ② EC11 A/B/SW —— 逐位同步（⚠️ A/B 必须【逐位】且【同一拍】，否则正交解码会误判方向）
    wire enc_a_s, enc_b_s, enc_sw_s;
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_enc_a  (.clk(clk), .rst_n(rst_n_sync), .async_in(enc_a_i),  .sync_out(enc_a_s));
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_enc_b  (.clk(clk), .rst_n(rst_n_sync), .async_in(enc_b_i),  .sync_out(enc_b_s));
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_enc_sw (.clk(clk), .rst_n(rst_n_sync), .async_in(enc_sw_i), .sync_out(enc_sw_s));
    // ── ③ 踏板 looper 两键
    wire pl_rec_s, pl_play_s;
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_pl_rec  (.clk(clk), .rst_n(rst_n_sync), .async_in(pedal_loop_rec_i),  .sync_out(pl_rec_s));
    sync_input #(.W(1), .STAGES(2), .RESET_VAL(1'b1)) u_pl_play (.clk(clk), .rst_n(rst_n_sync), .async_in(pedal_loop_play_i), .sync_out(pl_play_s));
    // ── ④ ESP32 UART —— 必须走【自己的】uart_rx 实例（顺带修 P0-03 的结构性方案）
    wire [7:0] esp_ur_data; wire esp_ur_done;
    uart_rx #(.BAUD_DIV(100)) u_uart_rx_esp (
        .clk_i(clk), .rst_n_i(rst_n_sync), .rx_i(esp_uart_rx_i),
        .rx_data_o(esp_ur_data), .rx_done_o(esp_ur_done));
    // ── ⑤ 异或归并改用【同步后】的值（或把已同步的从归并里摘掉）
    (* syn_keep = 1 *) wire reserved_in_xor = ^{ctrl_col_s, enc_a_s, enc_b_s, enc_sw_s,
                                                pl_rec_s, pl_play_s};
```
⚠️ 纪律（top.v:4885-4887 自己写的）：接入功能逻辑时，必须把该端口从 `reserved_in_xor` 里摘掉 —— 上面已按此把 7 个全部摘出并各自同步。
- **预期**：收益 = K-62 从"仍待做"变成"已做"；消除 10 位异步值进 FF 的亚稳态；EC11 A/B 逐位同拍同步 ⇒ 正交解码方向不会因位偏斜而误判；`esp_uart_rx_i` 有了真正的 `uart_rx` ⇒ 顺带打通 P0-03 的结构性修法。代价 = 7 个 `sync_input`（每个 2 FF）= 14 FF + 1 个 `uart_rx`（约 120 FF）≈ **134 FF**（占 60780 的 0.2%）；输入响应晚 2 拍（40 ns）—— 对机械按键/踏板完全无感。
- **怎么验**：1. 静态（进 CI）：脚本列出 top.v 全部 `input wire` 端口，断言每一个要么 (a) 被 `sync_input` 例化的 `.async_in` 消费，要么 (b) 被 `uart_rx` 的 `.rx_i` 消费，要么 (c) 在显式白名单里（如 clk/rst_n）；当前会报 7 个违规 ⇒ 红。2. 动态：tb/top 家族里对 `enc_a_i`/`enc_b_i` 注入相对偏斜 0/1 拍的成对跳变，断言 `debounce.enc_cw/enc_ccw` 不产生 `enc_err`（debounce.sv:178-181 的非法跳变分支）；未修复：位偏斜会让 A/B 看起来"同时变化" ⇒ `enc_err` 置位 ⇒ 红。
- **来源**：TORCH-3【P1-10】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-01|MOD=rtl/drivers/adc_farm.sv,rtl/top.v
### 实现 adc_farm 的死片检测（现在 fault_r 恒 0）
- **位置**：rtl/drivers/adc_farm.sv:216-221；rtl/top.v:1719、:4766-4777、:1986-1988；tb/drivers/tb_adc_farm.sv
- **现状**：
```verilog
    // ── 故障（预留 sticky，当前未实现死片检测，保持 0）─────────────────────
    reg [N_ADC-1:0] fault_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
    end
    assign fault = fault_r;
```
- **为什么是问题**：`always` 块只有复位分支、没有 else ⇒ `fault_r` 是"只被复位"的寄存器 ⇒ **恒 0**。而 top.v:1719 把它当故障源用：`assign fault_any_w = (|af_fault) | mx_fault;` ⇒ 🔴 `|af_fault` 恒 0 ⇒ 心跳灯的"快闪"只能由 `mx_fault`（tdm_render_mixer.deadline_fault_o）触发。top.v:4766-4777 声称"两者都接上了、都能看见"—— 只对了一半。⚠️ 叠加 P0-01（g_silent 档悬空）⇒ 故障见证在两个方向上都漏。
- **改法**（把"预留"变成"真实现"，或至少把谎话删掉）：
```verilog
// 方案 A（推荐，实现最小可用的死片检测）：
//   MCP3208 在 CS 有效期间 DOUT 恒为 0/1（断线、无供电）⇒ 该片 raw 恒 0 或 4095。
//   用一个 16 帧窗口统计：若某片 16 帧的样本【全相同】⇒ 判定死片。
    reg [3:0]  stuck_cnt [0:N_ADC-1];
    reg [11:0] last_sample [0:N_ADC-1];
    integer    fi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (fi=0; fi<N_ADC; fi=fi+1) begin
                stuck_cnt[fi] <= 4'd0; last_sample[fi] <= 12'd0; fault_r[fi] <= 1'b0;
            end
        end else if (sample_valid) begin
            for (fi=0; fi<N_ADC; fi=fi+1) begin
                if (sample_data_packed[fi*12 +: 12] == last_sample[fi]) begin
                    if (stuck_cnt[fi] == 4'd15) fault_r[fi] <= 1'b1;   // ⭐ sticky
                    else stuck_cnt[fi] <= stuck_cnt[fi] + 4'd1;
                end else begin
                    stuck_cnt[fi] <= 4'd0; fault_r[fi] <= 1'b0;
                end
                last_sample[fi] <= sample_data_packed[fi*12 +: 12];
            end
        end
    end
// 方案 B（若暂不实现）：把 top.v:1719 改成 assign fault_any_w = mx_fault; 并删掉 af_fault 的引用，
//   同时在 adc_farm 的注释里写明"fault 端口当前恒 0，⛔ 不可作为故障判据"。
```
- **预期**：收益 = 排线松/ADC 掉电首次可观测（心跳灯 8 Hz 快闪）；代价 = 方案 A 约 N_ADC×16 FF + 若干比较器（N_ADC=2 ⇒ 32 FF），⚠️ 需注意"用户按住键不动时 raw 帧间变化可达 ~23 码"（top.v:1986-1988）⇒ 阈值要留够，⛔ 不能用"完全相同"，应用"16 帧内 |Δ| ≤ 2 码"作为卡死判据。
- **怎么验**：tb/drivers/tb_adc_farm.sv 里把某一片的 `adc_miso` 恒接 0（模拟断线），断言 16 帧内 `fault[该片] === 1'b1` 且 `top.fault_sticky === 1'b1`，且 `led_heartbeat` 半周期变成 `HEARTBEAT_DIV>>3`；未修复：fault 恒 0 ⇒ 红。
- **来源**：TORCH-3【P2-01】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-02|MOD=rtl/drivers/adc_farm.sv
### 让影子反串行器与片 0 driver 同拍采样 MISO
- **位置**：rtl/drivers/adc_farm.sv:125-127、:161-163；rtl/drivers/mcp3208_driver.sv:111-114、:110-114；tb/drivers/tb_adc_farm.sv
- **现状**：
```verilog
// adc_farm.sv:125-127 —— 用"打一拍再比"检测 SCLK 上升沿 ⇒ 比 driver 晚 1 clk
    reg        sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];
    wire sclk_rise = (sclk_r == 1'b0 && adc_sclk[0] == 1'b1);
// adc_farm.sv:161-163 —— 在 sclk_rise 那一拍（= driver 置高后的【下一拍】）移位
        end else if (cs_active && sclk_rise) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1)
                miso_shift[gi] <= {miso_shift[gi][22:0], miso_sync[gi]};
        end
// mcp3208_driver.sv:110-114 —— 片 0 在【置高那一拍】就采样
                        //产生spi时钟的上升沿
                        adc_sclk <= 1'b1;
                        //mode 0 :在上升沿读取MISO数据
                        rx_shift <= {rx_shift[22:0], adc_miso};
```
- **为什么是问题**：片 0 的 `rx_shift` 在第 T 拍采 `miso_sync[0]`；片 1..N−1 的 `miso_shift` 在第 T+1 拍采 `miso_sync[g]` ⇒ 两者相差 1 个 `clk_sys` = 20 ns。`SCLK = 1 MHz` ⇒ 半周期 500 ns，MISO 由从机在 SCLK 下降沿更新 ⇒ 在上升沿附近 MISO 稳定 ⇒ 今天不会出错。⚠️ 但这是结构性的 1 拍错位：一旦 `SCLK_HZ` 提到 25 MHz 以上（半周期 < 20 ns），或 `sync_input` 的级数从 2 改成 3，片 0 与片 1..N 就会采到相邻两个 bit ⇒ 🔴 **静默的 1-bit 移位错误**（现象：读数整体除以 2 或加倍，看起来像"增益标定错了"）。
- **改法**：让两侧同拍。⭐ 正解：把 `miso_shift` 的移位条件从 `sclk_rise` 改为与 driver 同源的组合条件，或在 adc_farm 里也做一级 `adc_sclk` 的边沿寄存并把片 0 的采样也推后一拍（统一到 T+1）：
```verilog
// 统一方案：改为在 adc_farm 里【只用 shadow_hold】，并把片 0 的数据也走同一级 shadow
//   （即在 adc_farm 里为片 0 也建一份 shadow_hold[0]，与片 1..N 完全同式）
```
- **预期**：收益 = 片间零偏斜，`SCLK_HZ` 提升不再触发静默错位；代价 = **+24 FF**（片 0 的影子）+ 需重跑 tb_adc_farm。
- **怎么验**：tb/drivers/tb_adc_farm.sv 里把 `SCLK_HZ` 参数化到 25 MHz（半周期 20 ns = 1 clk），断言两片的 `sample_data_packed` 逐位相等（同一从机模型喂同样的 MISO）；未修复：片 1 会采到下一个 bit ⇒ 相差 2 倍 ⇒ 红。
- **来源**：TORCH-3【P2-02】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-03|MOD=rtl/top.v
### 给心跳分频的 >>3 加下溢保护
- **位置**：rtl/top.v:50、:4793、:4798-4808、:49；tb/top/tb_top_m0.sv
- **现状**：
```verilog
// top.v:50
    parameter integer HEARTBEAT_DIV     = 25_000_000,
// top.v:4793
    wire [31:0] hb_div_eff = fault_sticky ? (HEARTBEAT_DIV >> 3) : HEARTBEAT_DIV;
// top.v:4798-4808
    always @(posedge clk) begin
        if (!rst_n_sync) begin
            hb_cnt <= 32'd0;
            hb     <= 1'b0;
        end else if (hb_cnt >= hb_div_eff - 1) begin
            hb_cnt <= 32'd0;
            hb     <= ~hb;
```
- **为什么是问题**：`HEARTBEAT_DIV` 是 `integer`（有符号 32 位）；`HEARTBEAT_DIV >> 3` 在 < 8 时得到 0。`hb_div_eff` 是 `wire [31:0]`（无符号）⇒ `0 - 1` = **32'hFFFFFFFF** = 4 294 967 295 ⇒ `hb_cnt` 必须数到 4 294 967 294 拍 = **85.9 秒**才翻转一次。🔴 触发条件：`HEARTBEAT_DIV < 8` 且 `fault_sticky == 1`。⚠️ 而 top.v:49 明文写着"tb 会传小值以便快速验证" ⇒ 所有传小值的 tb，一旦锁存故障，心跳灯就停摆 ⇒ 任何"用心跳灯判活"的 tb 判据会超时假红（或假绿 —— 若它只等固定拍数）。
- **改法**：
```verilog
// top.v:4793
    wire [31:0] hb_div_eff = fault_sticky ? ((HEARTBEAT_DIV >> 3) < 2 ? 32'd2 : (HEARTBEAT_DIV >> 3))
                                          : ((HEARTBEAT_DIV     < 2 ? 32'd2 : HEARTBEAT_DIV));
// 或加一条参数自检：
    initial if (HEARTBEAT_DIV < 8)
        $display("WARNING [top] HEARTBEAT_DIV=%0d < 8 => fault fast-blink (>>3) underflows to 0 and the heartbeat wedges for ~86 s", HEARTBEAT_DIV);
```
- **预期**：收益 = 小参数 tb 的心跳判据恢复可靠；代价 = **1 行**。
- **怎么验**：tb/top/tb_top_m0.sv（或任意 `HEARTBEAT_DIV=4` 的 tb）里断言 `fault_sticky=1` 之后 `HEARTBEAT_DIV>>3 * 4` 拍内 `led_heartbeat` 必须翻转 ≥2 次；未修复：恒不翻转 ⇒ 红。
- **来源**：TORCH-3【P2-03】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-04|MOD=rtl/top.v
### 把 rep_req/rep_byte 的 10 级优先编码器打一拍
- **位置**：rtl/top.v:2433-2447、:2470-2476、:2326-2328、:2422-2431、:1126-1127、:742-746；tb/w3a/tb_span_axis_over_uart.sv、tb/w3c/tb_uart_calib_chain.sv
- **现状**：
```verilog
// top.v:2433-2447
        wire       rep_req  = ev_need   | ev_reject | ev_axis_ok | ev_done
                            | cmd_tare_req | cmd_span_req | cmd_abort_req | cmd_test_mode_req
                            | sp_start_rejected | (at_done & ~at_done_r)
                            | cmd_keydrum_req;   // ⭐ 'K' 键盘打鼓切换（⭐ 2026-10-01）
        wire [7:0] rep_byte = ev_need          ? axis_char        // ⭐ ① 轴号（⭐ 最要紧）
                            : ev_reject        ? rej_why_byte     // 🔴 被拒（⭐ 带原因码，见上）
                            : ev_axis_ok       ? 8'h2E            // '.' ⭐ 本轴通过
                            : ev_done          ? 8'h44            // 'D' ⭐ 全部完成
                            : sp_start_rejected? 8'h21            // '!' 🔴 'S' 被拒（正忙）
                            : (at_done & ~at_done_r) ? 8'h54      // 'T' ⭐ autotare 完成
                            : cmd_tare_req     ? 8'h74            // 't' ⭐ 受理 tare
                            : cmd_span_req     ? 8'h73            // 's' ⭐ 受理 span
                            : cmd_test_mode_req? tm_reply_byte    // M: 4/8/A/B/0
                            : cmd_keydrum_req  ? 8'h6B            // 'k' ⭐ 受理键盘打鼓切换
                            :                    8'h78;           // 'x' ⭐ 受理取消
// top.v:2470-2476
        assign tx_req  = rep_req | pp_push | vp_push | np_push
                       | ((DPOS_DIAG != 0) ? dp_push : 1'b0);
        assign tx_byte = np_push ? np_data
                       : (((DPOS_DIAG != 0) && dp_push) ? dp_data
                       : (vp_push ? vp_data : (pp_push ? pp_data : rep_byte)));
```
- **为什么是问题**：`rep_byte` 是 10 级优先 mux，其中两级（`axis_char` @ top.v:2326-2328、`rej_why_byte` @ top.v:2422-2431）本身就是 4~6 级优先 mux（`rej_why_byte` 是 6 级）⇒ 叠加后 `tx_byte` 的总组合深度约 **12~16 级 LUT**。`tx_byte`/`tx_req` 直连 `uart_tx_fifo.push_i`/`data_i`（top.v:1126-1127），中间无寄存器 ⇒ 这是一条 `calib_span`/`calib_autotare`/`calib_cmd`/`uart_ui`/`pos_probe` 的 FF → 12~16 级组合 → FIFO FF 的路径。⚠️ 它没有进本次 PnR 的前 25 名（说明布局给了它好位置），但它是结构性的，且扇入极宽（跨 5 个模块的输出）⇒ 属于"布局运气在帮忙"的一类。
- **改法**：把优先编码器打一拍（回包晚 20 ns，人眼完全无感）：
```verilog
    reg        rep_req_r;  reg [7:0] rep_byte_r;
    always @(posedge clk) begin
        if (!rst_n_sync) begin rep_req_r <= 1'b0; rep_byte_r <= 8'h00; end
        else             begin rep_req_r <= rep_req; rep_byte_r <= rep_byte; end
    end
    assign tx_req  = rep_req_r | pp_push | vp_push | np_push | ...;
    assign tx_byte = np_push ? np_data : (... : rep_byte_r);
```
⚠️ 注意：`rep_req` 里有 `cmd_tare_req` 等单拍脉冲 ⇒ 打一拍会把脉冲延迟 1 拍，必须确认 calib_cmd 的脉冲宽度 ≥ 1 拍（是，见 top.v:742-746 的注释"单周期脉冲"）⇒ 安全。
- **预期**：收益 = 切断一条 12~16 级、跨 5 模块的组合链，时序余量更稳；代价 = 回包晚 20 ns，+9 FF。
- **怎么验**：1. 静态：断言 `uart_tx_fifo.push_i` 的驱动源必须是寄存器（当前是 `rep_req | ...` 组合 ⇒ 红）。2. 动态：tb/w3a/tb_span_axis_over_uart.sv / tb/w3c/tb_uart_calib_chain.sv（均已存在）断言回包字符序列逐字节不变（打一拍不改序列，只改时间）⇒ 未修复与已修复都应绿，故这条的判据是"序列不变 + 静态检查"，⛔ 不能靠行为 tb 抓。
- **来源**：TORCH-3【P2-04】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-05|MOD=rtl/top.v
### 给 cal_ch_mux 的组合环加机械护栏
- **位置**：rtl/top.v:2373、:2355-2371、:2361、:2491、:2509；tb/top/tb_top_sound.sv、tb/top/*
- **现状**：
```verilog
// top.v:2373
        wire [2:0] cal_ch_mux = sp_busy_r ? sp_ch : at_ch;
// top.v:2355-2360（历史记录，证明这里真的出过组合环）
        //   🔴🔴 **为什么必须用 `sp_busy_r`（⭐ 打过一拍）而不是 `sp_busy`**：
        //      ⚠️ `sp_busy` 是 `calib_span.busy_o`（⭐ **组合输出**）
        //      ⇒ ⭐ `cal_ch_mux` 随它**立即变化** ⇒ ⭐ 而 `cal_ch_mux` 又喂给 `calib`
        //      ⇒ 🔴 **`cal_ch_mux` → `calib` → 采集通路 → `calib_span` → `sp_busy`
        //         → `cal_ch_mux` 形成【跨模块组合环】**
```
- **为什么是问题**：现状用 `sp_busy_r`（寄存器）打断了环 ✅。但 `cal_ch_mux` 仍是 `calib_span.sp_ch`（FF）与 `calib_autotare.at_ch`（FF）的 2:1 组合 mux，直连 `calib.cal_ch`（两个实例，top.v:2491/:2509）⇒ 结构上仍是"A 的 FF → 组合 mux → B 的组合输入"，深度 1 级，风险很低，但：⚠️ 若将来有人把 `sp_busy_r` 换回 `sp_busy`（看起来"少一拍更实时"），组合环立刻复活（仿真在时间 0 挂死，已实测）⇒ 这是一条必须留下"为什么不能改回去"的机械护栏的位置。
- **改法**：加一条编译期/仿真期护栏（比注释硬）：
```verilog
// top.v:2373 附近
    // ⛔ 护栏：cal_ch_mux 的选择信号必须是寄存器（防止组合环复活）
    initial begin
        if (!$isunknown(sp_busy_r) && (sp_busy_r !== 1'b0) && (sp_busy_r !== 1'b1))
            $fatal(1, "ERROR [top] cal_ch_mux selector is not a clean register => the cross-module combinational loop (cal_ch_mux->calib->calib_span->sp_busy->cal_ch_mux) is back");
    end
```
⭐ 更实用的是加一条 tb 超时护栏：tb/top/* 统一加 `initial #1ms $fatal("simulation wedged at time 0 => combinational loop")` —— top.v:2361 记录了当时的真实现象正是"零输出超时"。
- **预期**：收益 = 组合环不可能再静默复活；代价 = **1 条 initial**（仅仿真）。
- **怎么验**：把 top.v:2373 临时改成 `sp_busy ? sp_ch : at_ch`，跑 tb/top/tb_top_sound.sv ⇒ 未加护栏：iverilog 在时间 0 反复求值、零输出超时（无明确报错）；加了护栏：立即 `$fatal` 并指名组合环 ⇒ 红得清楚。
- **来源**：TORCH-3【P2-05】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-06|MOD=rtl/w3c/pos_probe.v
### 把 pos_probe 的 3 个常数乘法换成移位相加
- **位置**：rtl/w3c/pos_probe.v:179、:257、:270、:55-63、:135-173；rtl/top.v:2125、:2882、:2995、:2991-2993、:1167-1171；tb/w3c/tb_pos_probe.sv
- **现状**：
```verilog
// pos_probe.v:179
    wire [11:0] cur_x100 = {8'd0, cur_digit} * 12'd100;
// pos_probe.v:257
                            rem  <= rem - ({8'd0, cur_thou} * 12'd1000);
// pos_probe.v:270
                            rem  <= rem - ({8'd0, cur_ten} * 12'd10);
// pos_probe.v:55-63（作者自己的实测记录）
//  ③ 🔴🔴 **BCD 转换必须【流水化】**（⭐ 2026-09-24 PnR 实测后重写）：
//     ⚠️ 第一版把"比较 → 减 → 比较 → 减 → 比较 → 减"写成**一整条组合链**
//     ⇒ 🔴 **最差时序路径 23.519 ns**（⭐ 目标 20 ns）
//        ⇒ ⭐ **Actual Fmax 从 54.6 MHz 掉到 50.011 MHz**（⭐ 余量只剩 0.02%）
```
- **为什么是问题**：`cur_digit`/`cur_thou`/`cur_ten` 各是 10 级优先比较器（pos_probe.v:135-173），其输入 `rem` 是寄存器，其输出经 12 位常数乘法 + 12 位减法回到 `rem` ⇒ 单级链 = `rem(FF)` → 10 级优先比较器 → 常数乘法（LUT 拼） → 12 位减法 → `rem(FF)`。作者已把它拆成 4 拍流水（`bcd_stage`）⇒ 今天单级只有 1 个比较器 + 1 个乘法 + 1 个减法。⚠️ 但本模块被例化 3 次（top.v:2125 u_pos_probe · top.v:2882 u_pos_probe_cal · top.v:2995 u_pos_probe_dpos）⇒ 9 个常数乘法器的等价逻辑；⚠️ `u_pos_probe_dpos` 在 `DPOS_DIAG=0` 时被优化掉（top.v:2991-2993）⇒ 实际 6 个。
- **改法**：把 3 个乘法器换成移位相加（常数 100 = 64+32+4、1000 = 1024−16−8、10 = 8+2）：
```verilog
// pos_probe.v:179
    wire [11:0] cur_x100 = (cur_digit << 6) + (cur_digit << 5) + (cur_digit << 2);   // ×100
// pos_probe.v:257
    rem <= rem - ((cur_thou << 10) - (cur_thou << 4) - (cur_thou << 3));            // ×1000
// pos_probe.v:270
    rem <= rem - ((cur_ten << 3) + (cur_ten << 1));                                  // ×10
```
（⛔ 注意左操作数位宽：`cur_digit` 是 4 位 ⇒ 必须先零扩展到 12 位再移位，否则先截断再移位，静默算错 —— 见 top.v:1167-1171 的同类教训。）
- **预期**：收益 = 3 个常数乘法器变成 2~3 个加法器，省 LUT 且链更短；代价 = 需重跑 tb_pos_probe*（已存在：sim/evidence/tb_pos_probe.log / tb_pos_probe_axis.log）。
- **怎么验**：tb/w3c/tb_pos_probe.sv 对 `pos_i` 扫 0..4095 全量，断言回包 4 位十进制逐个正确；未修复位宽（写成 `(cur_digit << 6)` 而不先扩展）⇒ `cur_digit=9` 时 `9<<6` 在 4 位里截断 ⇒ 输出错 ⇒ 红。
- **来源**：TORCH-3【P2-06】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-07|MOD=rtl/hdmi/waveform_scope.v
### 把 gray_launch 与 full_launch 合成一个 CDC 向量
- **位置**：rtl/hdmi/waveform_scope.v:38-42、:47-48、:55-62、:89-90；tb/hdmi
- **现状**：
```verilog
// waveform_scope.v:38-42
    reg [9:0] gray_launch;
    reg full_launch;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 0; full_launch <= 0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end
// waveform_scope.v:55-62 —— 两个 bundle 各自 2 级同步，互不相关
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            gray_meta <= 0; gray_sync <= 0;
            full_meta <= 0; full_sync <= 0;
        end else begin
            gray_meta <= gray_launch; gray_sync <= gray_meta;
            full_meta <= full_launch; full_sync <= full_meta;
        end
    end
// waveform_scope.v:89-90 —— 用 full_sync 门控 gray 派生的地址
            if (x_i == 0 && y_i == 480 && full_sync) begin
                copy_base <= wr_seen - 10'd640;
```
- **为什么是问题**：`gray_launch`（10 位）与 `full_launch`（1 位）在同一个负沿更新，但在接收侧各自独立同步 2 级（10 条 + 1 条路径，位间/信号间偏斜不可控）⇒ 可能出现 `full_sync=1` 而 `gray_sync` 还是上一代（或反之），使 `copy_base = wr_seen − 640` 的 `wr_seen` 与 `full_sync` 的语义差 1 个采样。⚠️ 实际后果很小（`copy_base` 只影响显示窗口起点，偏差 1 个采样 = 20.48 µs 的显示位移），但它破坏了"同一快照"的语义，且 `full_launch` 是电平（不是脉冲）⇒ 在 `history_full` 从 0→1 的那一次跳变上必然出现这个窗口。
- **改法**：把两个 bundle 合成一个灰码化的向量，一次同步：
```verilog
// 发射侧：{full, gray} 作为一个 11 位灰码字（full 是 sticky ⇒ 只需在它变化时确保 gray 同步更新）
    reg [10:0] cdc_launch;
    always @(negedge sample_clk)
        if (!sample_rst_n) cdc_launch <= 11'd0;
        else               cdc_launch <= {history_full, wr_gray};
// 接收侧：一次 2 级同步
    (* async_reg = "true" *) reg [10:0] cdc_meta, cdc_sync;
    always @(posedge pixel_clk)
        if (!pixel_rst_n) begin cdc_meta <= 0; cdc_sync <= 0; end
        else              begin cdc_meta <= cdc_launch; cdc_sync <= cdc_meta; end
    wire [9:0] gray_sync = cdc_sync[9:0];
    wire       full_sync = cdc_sync[10];
```
⚠️ 严格来说 `{full, gray}` 整体不是灰码（两个字段同时变），但 `full` 是 sticky 单比特、`gray` 是单比特变化 ⇒ 最坏情况是"多取或少取 1 个采样"，与现状等价，而单次同步消除了"两 bundle 代际不一致"这个额外自由度 ⇒ 净改善。
- **预期**：收益 = CDC bundle 从 2 个减到 1 个，代际一致；代价 = **11 FF 变 11 FF（0 增量）**。
- **怎么验**：tb/hdmi 里在 `pixel_clk` 侧断言 `full_sync` 首次变 1 的那一拍，`wr_seen` 必须 ≥ 640（否则 `copy_base` 会下溢成 10 位回绕值）。把 `sample_clk`/`pixel_clk` 的相对相位随机化 200 次 ⇒ 未修复时会在某个相位抓到 `wr_seen < 640` ⇒ 红。
- **来源**：TORCH-3【P2-07】
@@@END
@@@PRIO=P2|SRC=TORCH-3|ORIG=P2-08|MOD=rtl/clk_gen.v,constr/top.sdc,rtl/top.v
### 改正"无 PLL/单时钟域"的文档并给 HDMI 加编译期总闸
- **位置**：rtl/clk_gen.v:2；constr/top.sdc:2；rtl/hdmi/hdmi_clk.v:17-28；rtl/top.v:1228-1232、:5-9、:1247-1248、:4492-4493；rtl/hdmi/hdmi_scope.v:16；sim/evidence/final-batch-20261008/timing.txt:34-63
- **现状**：
```verilog
// clk_gen.v:2
// clk_gen.v · L1 时基（⛔ 不用 PLL、无门控时钟、全设计单时钟域）
// top.sdc:2
# top.sdc · **时序约束**（files/20-代码/W3接口冻结表.md §〇：单时钟域、无 PLL）
// hdmi_clk.v:17-28
    PLLA u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(!rst_n), .PLLPWD(1'b0),
        .LOCK(pll_lock), .CLKOUT0(serial_clk), .CLKOUT1(pixel_clk),
// top.v:1228-1232 —— 无条件例化（没有 generate 门控）
    hdmi_scope u_hdmi (.clk(clk), .rst_n(rst_n_sync),
        .sample_i(scope_sample), .valid_i(scope_valid),
```
- **为什么是问题**：clk_gen.v:2 与 top.sdc:2 都断言"单时钟域、无 PLL"，而实际有 3 个时钟域（clk_sys 50 MHz · pixel_clk 25 MHz · serial_clk 125 MHz，见 timing.txt:34-63）。top.v:5-9 记载了本项目最惨痛的历史教训：K-41"上一个项目把全设计换成 PLL 时钟后板子全死、连 UART 都没输出"。⇒ 🔴 **当前设计在顶层无条件例化了一个 PLLA + 4 对 LVDS**，而文档仍在说"无 PLL" ⇒ 新加入者读文档会做出错误假设（例如认为"任何信号都能当同步信号用"）。资源代价：PLL ×1（PLLA）+ OSER10 ×4 + TLVDS_OBUF ×4 + 4 对差分引脚 —— 全部无条件占用，即使 `hpd_en=1'b1`（hdmi_scope.v:16）根本没有消费者。
- **改法**：1. ⭐ 改文档（必须，1 行）：clk_gen.v:2 改为 `// clk_gen.v · L1 时基（⛔ 本模块不用 PLL；⚠️ 全设计【不是】单时钟域 —— HDMI 另有 pixel_clk/serial_clk，见 hdmi_clk.v）`；top.sdc:2 同样更正。2. ⭐ 给 HDMI 加编译期总闸（与 TEST_MODE_EN/DPOS_DIAG 同一手法）：
```verilog
parameter integer HDMI_SCOPE_EN = 0,   // ⭐ 默认关：不需要示波器显示时不占 PLL/4 对差分脚
...
generate if (HDMI_SCOPE_EN != 0) begin : g_hdmi
    hdmi_scope u_hdmi (...);
end else begin : g_no_hdmi
    assign scope_sample = 24'sd0; assign scope_valid = 1'b0;
    assign tmds_d_p_0 = 3'b000; assign tmds_d_n_0 = 3'b111;
    assign tmds_clk_p_0 = 1'b0; assign tmds_clk_n_0 = 1'b1;
    assign hpd_en = 1'b0;
end endgenerate
```
⚠️ 注意 `scope_sample`/`scope_valid` 在 `g_sound`/`g_silent` 里已被 assign（top.v:1247-1248、:4492-4493）⇒ 必须把这两个 assign 一起挪进 generate（否则多驱动）。3. ⭐（可选）把 `hpd_en` 接到真实用途或删掉 —— 现在是 `assign hpd_en = 1'b1;`（hdmi_scope.v:16），无人消费。
- **预期**：收益 = 文档与地面真相一致（⛔ 不再误导）；可选地释放 1 个 PLL + 4 对差分脚；代价 = 文档改动 2 行；加总闸需要动 top.v 的 generate 结构（中等风险，需重跑全量回归）。
- **怎么验**：机械判据：文档声称"无 PLL/单时钟域"时，RTL 里不得出现 PLL 原语 —— `$pll = Select-String -Path rtl -Recurse -Pattern 'PLLA|rPLL|PLLVR'`；`$claim = Select-String -Path rtl/clk_gen.v,constr/top.sdc -Pattern '无 PLL|单时钟域'`；`if ($pll.Count -gt 0 -and $claim.Count -gt 0) { "RED: 文档声称无 PLL 但 RTL 里有 $($pll.Count) 处 PLL 原语"; exit 1 }` ⇒ 当前红。
- **来源**：TORCH-3【P2-08】
@@@END
@@@PRIO=P3|SRC=TORCH-3|ORIG=P3-01|MOD=constr/top.sdc
### 把 top.sdc 注释里的 19.417 改成实际生效的 18.181
- **位置**：constr/top.sdc:91-101、:91-96、:101-102；rtl/hdmi/waveform_scope.v:38-43
- **现状**：
```tcl
# top.sdc:91-96
#   ③ `gray_launch`/`full_launch` 走的是 `negedge sample_clk` 半周期预算（10 ns，
#      见 `rtl/hdmi/waveform_scope.v:38-43`）⇒ 必须**显式钉住 10 ns**，
#      否则会被下面那条 19.417 意外放宽。
#
# 📌 取值：19.417 ns ≈ 51.5 MHz（精确值 19.4174757 ⇒ 这里**略紧**）。
#    挑战档 = 18.181 ns（≈55 MHz，精确 18.1818182 ⇒ **略松**，确保严格达标）。
# top.sdc:101-102（实际生效的值）
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
set_max_delay -from [get_clocks {clk_sys}] -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0}] 10.000
```
- **为什么是问题**：注释里"下面那条 19.417"指的是已经被改成 18.181 的那条 ⇒ 注释过期。本项目 AGENTS.md §五③ 明文记录"注释↔代码不一致"是复发缺陷（tdm_render_mixer.v 三项全错）⇒ 一个读注释的人会以为当前跑的是"51.5 MHz 门槛档（19.417）"，而实际跑的是"挑战档（18.181 ≈ 55 MHz）"⇒ 会误判余量的含义（把 55 MHz 的成绩当成 51.5 MHz 的成绩）。
- **改法**：
```tcl
# top.sdc:91-96 —— 改为与代码一致
#   ③ `gray_launch`/`full_launch` 走的是 `negedge sample_clk` 半周期预算（10 ns，
#      见 `rtl/hdmi/waveform_scope.v:38-43`）⇒ 必须**显式钉住 10 ns**，
#      否则会被下面那条 **18.181** 意外放宽。
#
# 📌 当前生效值 = **18.181 ns（≈55 MHz，挑战档）** —— 见下方 :101。
#    门槛档 19.417 ns（≈51.5 MHz）**未启用**；切换时改 :101 一处即可。
```
- **预期**：收益 = 读者不再误判余量口径；代价 = **6 行注释**。
- **怎么验**：脚本比对 top.sdc 里出现的所有 `\d+\.\d+` 数值与该文件里 `set_max_delay` 的实际参数，注释中提到的"下面那条 N"必须等于紧邻的下一条 `set_max_delay` 的数值；当前 19.417 ≠ 18.181 ⇒ 红。
- **来源**：TORCH-3【P3-01】
@@@END
@@@PRIO=P3|SRC=TORCH-3|ORIG=P3-02|MOD=rtl/top.v,rtl/clk_gen.v
### 把 9 处参数自检从 $display 升级成 $fatal
- **位置**：rtl/w3c/uart_rx.v:196、:185-197、:189-194、:198-204；rtl/top.v:2719、:2723、:2669、:2681、:2688、:2692、:2826、:2832、:2835、:2817-2818、:2825；rtl/clk_gen.v:67、:73、:72-74、:65-75、:46-53；rtl/drivers/adc_farm.sv（无自检）
- **现状**：
```verilog
// uart_rx.v:196 —— 正确：硬失败
            $fatal(1, "ERROR [uart_rx] BAUD_DIV=%0d < 4 => bit-midpoint sampling is unusable ...");
// top.v:2826 —— 同族缺陷，但只打印
                $display("ERROR [top] VEL_AXIS_N=%0d != SYS_AXIS_N=%0d => %0d axis/axes get ATTACK velocity but NO follow ...",
                         VEL_AXIS_N, SYS_AXIS_N, ...);
// top.v:2681 —— 同上
            if (TRAVEL_TARE > 12'd1023)
                $display("ERROR [top] TRAVEL_TARE(%0d) > calib.MAX_TRAVEL(1023) => ... (K-124)", TRAVEL_TARE);
```
- **为什么是问题**：`$display` 在仿真里不阻止运行、在综合里被完全忽略 ⇒ `VEL_AXIS_N != SYS_AXIS_N`（top.v:2825）这类会导致部分轴"有起音力度但完全没有跟随"的缺陷（top.v:2817-2818 自认"同族 K-56：全绿不证明任何事"）只留一行可能被刷屏淹没的日志，而综合照常进行、缺陷原样进板。uart_rx.v:185-197 已经把这条教训写成"必须硬失败"，但 top.v/clk_gen.v 的同类检查没有跟上。
- **改法**：把 top.v:2669/2681/2688/2692/2826/2832/2835 与 clk_gen.v:67/73 的 `$display` 改成 `$fatal(1, ...)`。⚠️ 例外：clk_gen.v:72-74 的"`CLK_PER_SAMPLE` 不能被 `2×BCLK_DIV` 整除"可以保持 `$display`（它是"配置建议"而非"必然缺陷"），但要在注释里写明理由（照 uart_rx.v:198-204 的先例）。
- **预期**：收益 = 量纲/轴数错配不可能静默进板；代价 = ⚠️ 可能打断现有 tb（若有 tb 故意传错参数来验"自检能报"）⇒ 需先 grep 全部 tb 确认（tb/** 里搜 VEL_AXIS_N / TRAVEL_TARE / PARAM_OK）。
- **怎么验**：机械判据：凡消息里含 "ERROR [top]" 或 "ERROR [clk_gen]" 的行，必须使用 `$fatal` —— `Select-String -Path rtl/top.v,rtl/clk_gen.v -Pattern 'ERROR \[(top|clk_gen)\]' -Context 1,0 | Where-Object { $_.Line -notmatch '\$fatal' }`；当前有 9 处 ⇒ 红。
- **来源**：TORCH-3【P3-02】
@@@END
@@@PRIO=P3|SRC=TORCH-3|ORIG=P3-03|MOD=rtl/top.v
### 让 led_drum_on 与 src_b_valid 共用同一个 sel_drum
- **位置**：rtl/top.v:4982、:3867-3869、:4979-4980、:3848、:110；tb/top/tb_top_led_strip.sv
- **现状**：
```verilog
// top.v:4982 —— 指示层用的表达式
    wire led_drum_on = (SEL_DRUM == 1) && (METRONOME_ON != 0) && met_on_r;
// top.v:3867-3869 —— 真实进 evt_merge 的门控
        wire        src_b_valid = (sel_drum ? drm_evt_valid : met_evt_valid)
                                  & (METRONOME_ON != 0)
                                  & met_on_r;
// top.v:4979-4980 —— 作者自己承认这是双份真相
    //      🔴 **与 `g_sound` 里 `src_b_valid` 的算式逐项一致** ⇒ ⭐ 改一处必须改两处
    //         （⭐ 否则指示灯会说"鼓机在响"而实际不响 —— ⚠️ 比不亮更坏）
```
- **为什么是问题**：`led_drum_on` 用 `(SEL_DRUM == 1)` 字面量，而真实门控用 `sel_drum`（top.v:3848 定义的 wire）。今天两者等价，但：若有人把 `SEL_DRUM` 参数改成"运行时信号"（top.v:110 的注释明确说将来要这么做："只需把 `sel_drum` 换成寄存器即可"），`led_drum_on` 会继续读编译期常量 ⇒ 🔴 指示灯说谎（用户最讨厌的一类）。且 `led_drum_on` 没有包含 `drm_evt_valid`/`met_evt_valid` ⇒ 它表示的是"源 B 已使能"而不是"正在发声"，而注释把它当"正在发声"用（"只有三者都成立时，鼓机才真的在出声"）。
- **改法**：
```verilog
// top.v:4982 —— 单一来源：引用同一个 sel_drum
    wire led_drum_on = sel_drum && (METRONOME_ON != 0) && met_on_r;
```
⚠️ `sel_drum` 声明在 `g_sound` 内（top.v:3848），而 `led_drum_on` 在 `g_sound` 之外（top.v:4982）⇒ 必须把 `sel_drum` 提到模块层（照 `tx_req`/`led_blink` 的先例，由两个 generate 分支各自驱动）。
- **预期**：收益 = 指示灯不再能说谎；代价 = 需把 `sel_drum` 提到模块层（小改，但涉及 generate 边界，需回归）。
- **怎么验**：tb/top/tb_top_led_strip.sv（已存在，见 top.v:1263）里加：把 `SEL_DRUM` 参数改成一个运行时寄存器后，断言 `led_drum_on` 与 `src_b_valid` 在同拍等价；未修复：`led_drum_on` 恒等于 `SEL_DRUM==1` ⇒ 断言红。
- **来源**：TORCH-3【P3-03】
@@@END
@@@PRIO=P3|SRC=TORCH-3|ORIG=P3-04|MOD=rtl/clk_gen.v
### 把 clk_gen 的 initial 自检升级成 $fatal
- **位置**：rtl/clk_gen.v:65-75、:66、:72、:46-53；rtl/w3c/uart_rx.v:189-194、:198-204；tb/（grep BCLK_DIV/PARAM_OK）
- **现状**：
```verilog
    initial begin
        if (!PARAM_OK)
            $display("ERROR [clk_gen] 参数必须全为 2 的幂且 BCLK_DIV/MCLK_DIV >= 2、CLK_PER_SAMPLE >= BCLK_DIV：...",
                     CLK_PER_SAMPLE, BCLK_DIV, MCLK_DIV);
        // ⭐ R-05：跨模块一致性 —— `i2s_tx` 的每声道时隙数必须与这里算出来的一致。
        if ((CLK_PER_SAMPLE % (BCLK_DIV * 2)) != 0)
            $display("ERROR [clk_gen] CLK_PER_SAMPLE(%0d) 不能被 2×BCLK_DIV(%0d) 整除 ⇒ 左右时隙不等长",
                     CLK_PER_SAMPLE, BCLK_DIV * 2);
    end
```
- **为什么是问题**：clk_gen.v:46-53 的注释自己写明"非 2 的幂会【静默给错频率】"（例如 `BCLK_DIV=12` ⇒ 实际仍按 ÷16 走 ⇒ BCLK 比预期低 33%）。这种"频率错了但一切看起来正常"的缺陷，与 uart_rx.v:189-194 描述的"`BAUD_DIV<4` ⇒ 毛刺保护静默失效"属于同一族（K-87），而 uart_rx 已经升级成 `$fatal` ⇒ clk_gen 的自检只留一行日志，综合时完全被忽略 ⇒ 缺陷原样进板。
- **改法**：clk_gen.v:66 与 :72 的 `$display` → `$fatal(1, ...)`（保留消息原文）。⚠️ 先 grep tb/ 确认没有 tb 故意传非法参数来验自检。
- **预期**：收益 = 频率错配不可能静默进板；代价 = **2 处关键字**。
- **怎么验**：加一条 tb（或临时改参数）：`clk_gen #(.BCLK_DIV(12))` ⇒ 未修复：仿真跑完、只打印 ERROR ⇒ 若判据是"仿真必须终止"则红；已修复：`$fatal` 立即终止 ⇒ 绿。
- **来源**：TORCH-3【P3-04】
@@@END
@@@PRIO=P3|SRC=TORCH-3|ORIG=P3-05|MOD=rtl/clk_gen.v,rtl/top.v
### 处理 clk_gen 的 lrclk/mclk_en 死输出（防止被误当权威 WS）
- **位置**：rtl/clk_gen.v:37、:37-38、:105、:108；rtl/top.v:785-800、:795、:798；rtl/w3c/i2s_tx.v:39-40、:34-41
- **现状**：
```verilog
// clk_gen.v:37-38
    output reg  lrclk,        // 帧时钟电平：低 = 左声道（标准 I2S）
    output reg  frame_start   // 本周期是"帧内第 0 个 BCLK"（给 i2s_tx 对齐用）
// top.v:785-800 —— lrclk/mclk_en 被声明但无人使用
    wire tick_audio, mclk_en, bclk_en, bclk_half_en, lrclk, frame_start;
    clk_gen #(
        .CLK_PER_SAMPLE (1024),   // fs = 50 MHz ÷ 1024 = 48.828125 kHz
        .BCLK_DIV       (16),     // BCLK = 3.125 MHz（= 64 × fs）
        .MCLK_DIV       (4)       // MCLK = 12.5 MHz（板载 DAC 不用，留作观测）
    ) u_clk_gen (
        ...
        .mclk_en      (mclk_en),
        ...
        .lrclk        (lrclk),
// i2s_tx.v:39-40 的注释明确说明为什么不用它：
// *"HP_WS 由本模块自己的计数器决定…⛔ 不要直通 clk_gen 的 lrclk 寄存器 —— 它比位边界晚一拍，会让 WS 与数据错开半个 BCK。"*
```
- **为什么是问题**：`lrclk` 与 `mclk_en` 被 clk_gen 寄存产生（各 1 FF + 各自的比较器），顶层连线后没有任何消费者 ⇒ 综合会剪掉下游，但 clk_gen 内部的寄存器因为是模块输出，在模块级综合时不会被剪（顶层综合可能剪，取决于工具）⇒ 最小后果：浪费 2 FF + 2 个比较器（可忽略）；⚠️ 真后果：下一个人看到 `lrclk` 被接出来，会以为它是"权威的 WS"，而 i2s_tx.v:39-40 的警告在另一个文件里 ⇒ 重蹈"WS 与数据错开半个 BCK"的覆辙（i2s_tx.v:34-41 记录这是踩过两次才定下来的）。
- **改法**（二选一）：
```verilog
// 方案 A（推荐）：顶层删掉这两根线，并在 clk_gen 的端口注释里标注"仅供观测/未使用"
//   top.v:785 → wire tick_audio, bclk_en, bclk_half_en, frame_start;   // ⛔ 不再引 mclk_en/lrclk
//   top.v:795/798 → 删除 .mclk_en(...) / .lrclk(...)
// 方案 B：保留，但在 clk_gen.v:37-38 的端口注释加一行
//   // ⚠️ `lrclk` **⛔ 不要直通 `i2s_tx` 的 WS**（见 i2s_tx.v:39-40：它比位边界晚一拍）
```
- **预期**：收益 = 消除"误用权威 WS"的陷阱；代价 = **方案 A 删 4 行**（需确认无 tb 引用 `dut.lrclk`）。
- **怎么验**：脚本断言 top.v 里 clk_gen 例化的每个输出端口都在模块层被消费至少一次；当前 `mclk_en`/`lrclk` 违规 ⇒ 红。
- **来源**：TORCH-3【P3-05】
@@@END
@@@TOTAL SRC=TORCH-3 COUNT=27 P0=4 P1=10 P2=8 P3=5
