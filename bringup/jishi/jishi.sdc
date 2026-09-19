// ─────────────────────────────────────────────────────────────────────────────
// jishi.sdc · 基石板时序约束（配 `bringup/jishi/jishi_top.v`）
//
// ⭐ 为什么必须有：只写 `.cst`（引脚）、不写 `.sdc` 时，Gowin 报告头是
//    `<Timing Constraints File>: ---` 并出 `WARN (TA1132)` ⇒ **时序分析是空的**
//    —— "0 违规"是因为**压根没分析**（见 经验库 `U52` / `K-45`）。
//    且 ⛔ 必须在 `.gprj` 里登记（`type="file.sdc"`），只放磁盘上不算数。
//
// ⭐ 基石板晶振 = **50 MHz**（与 Dock 同频）⇒ `period 20`，与官方例程一致。
//    ⚠️ 若实测发现不是 50 MHz，⛔ **必须同时改这里和 `CLK_PER_SAMPLE`**
//      （否则 fs / BCLK / LRCLK 全部按比例偏，且时序约束也是错的）。
// ─────────────────────────────────────────────────────────────────────────────

create_clock -name clk_sys -period 20 -waveform {0 10} [get_ports {clk}]

// ⭐ 输出到引脚的路径（I/O 约束）—— 与正式顶层同口径（见 `K-53`）：
//    ⚠️ 只写 `create_clock` 时**进出引脚的路径压根不被分析**，
//      报告的 `Actual Fmax` 会**乐观一大截**（实测：325.9 MHz vs 55.96 MHz）。
//    ⇒ 上板前必须带上这几条，否则"时序余量"是假的。

// I2S 三线 + LED：给一个保守的输出延时预算（10 ns 远小于半周期 160 ns，不会误报）
set_output_delay -clock clk_sys -max 10.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 10.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 10.0 [get_ports {HP_DIN}]
set_output_delay -clock clk_sys -max 10.0 [get_ports {led_heartbeat}]

// 蜂鸣器：**直流控制脚**，无时序要求 ⇒ 明确排除（并写明理由，⛔ 不是"消警告"）
set_false_path -to [get_ports {beep}]

// 复位输入：异步按键、且已由 `rst_sync` 两级同步 ⇒ 不编假的 input_delay
set_false_path -from [get_ports {rst_n}]
