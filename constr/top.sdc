# ─────────────────────────────────────────────────────────────────────────────
# top.sdc · **时序约束**（`files/20-代码/W3接口冻结表.md` §〇：单时钟域、无 PLL）
#
# ⚠️ 为什么必须有这个文件（2026-09-17 实测）：
#    只写 `constr/top.cst`（引脚）时，Gowin 报告里会是
#        `<Timing Constraints File>: ---`
#        `WARN (TA1132): 'clk' was determined to be a clock but was not created.`
#    ⇒ **时序分析是空的**。此时"布局布线通过、生成了 bitstream"**说明不了任何时序问题** ——
#      看起来一切正常，其实工具根本没有时序目标可比。
#    ⛔ 这与经验库 `L31`（上一个项目 PLL 事故）里那条被忽视的 `PR1014` 是同一类坑：
#      **只看"零 error"会漏掉"时钟/时序压根没被约束"**。⚠️ 注意 `TA1132` 与 `PR1014`
#      是**两个不同的警告**，不要混为一谈（见 `files/20-代码/已知问题与风险清单.md` `K-45`）。
#
# 语法出处：Gowin 自带例程（`<Gowin安装>\IDE\data\examples\led_water\src\led_water.sdc`）
# ─────────────────────────────────────────────────────────────────────────────

# 系统时钟：`clk` 引脚 = 50 MHz（周期 20 ns、上升沿在 0、下降沿在 10）
create_clock -name clk_sys -period 20 -waveform {0 10} [get_ports {clk}]

# ─────────────────────────────────────────────────────────────────────────────
# ⭐ I/O 时序约束（R-10，2026-09-17 补）
#
# ⚠️ 为什么只写 `create_clock` 不够：
#    它只约束**寄存器→寄存器**的路径。**进出引脚的路径**（输出到 DAC、输入复位）
#    在没有 `set_output_delay`/`set_input_delay` 时**不被分析** ——
#    所以"0 违规"**不覆盖**"`HP_DIN` 到 DAC 的建立时间够不够"这类问题。
#    ⚠️ 而我们恰恰刚在 `K-47` 里发现"DAC 侧建立时间"是个真问题（仿真里靠
#    `tb_i2s_tx_timing.sv` 量，但**工具侧也该有约束**才算闭环）。
#
# 📌 取值依据（⚠️ 这些是**外部器件的时序要求**，不是 FPGA 的）：
#    · 输出 `HP_BCK/HP_WS/HP_DIN` → PT8211：手册**没有给 tSU/tHD**，
#      只给了 **BCK 高电平 tH ≥ 25 ns**。我们的数据在 BCK 下降沿变化、DAC 在上升沿采，
#      半周期 = 160 ns ⇒ 给一个**保守的 10 ns** 输出延时预算（远小于 160 ns，不会误报）；
#    · 输出 `PA_EN_n` → 功放使能：**直流控制脚**，无时序要求 ⇒ `set_false_path`；
#    · 输出 `led_heartbeat` → LED：**人眼观测**，无时序要求 ⇒ `set_false_path`；
#    · 输入 `rst_n`：按键，**异步**且已由 `rst_sync` 同步（`K-50`）⇒ 用
#      `set_false_path` 更诚实（⛔ 不要给它编一个假的 input_delay）。
#
# ⚠️ 关于 `set_false_path` 的纪律（⛔ 别拿它当"消警告"的万金油）：
#    只有**确实不要求时序**的路径才配 `false_path`，且必须**写清理由**（上面每条都写了）。
# ─────────────────────────────────────────────────────────────────────────────

# 音频三线 → DAC（保守预算；真实余量由 tb_i2s_tx_timing 实测为 160 ns）
set_output_delay -clock clk_sys -max 10.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 10.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 10.0 [get_ports {HP_DIN}]

# 直流/人眼观测脚：无时序要求（⭐ 理由见上）
set_false_path -to [get_ports {PA_EN_n}]
set_false_path -to [get_ports {led_heartbeat}]

# 复位输入：异步按键 + 已由 rst_sync 同步（K-50）⇒ 不设 input_delay
set_false_path -from [get_ports {rst_n}]

