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

# 音频三线 → DAC（真实建立/保持余量由 tb_i2s_tx_timing 实测为 160 ns）
#
# 🔴🔴 2026-10-01 更正（⭐ 实测发现原值把设计卡死）：
#   ⚠️ **原文的推理是【反的】** —— 原文写"半周期 160 ns ⇒ 给保守的 10 ns ⇒ 远小于 160 ns
#      不会误报"。🔴 **但 `set_output_delay -max D` 的含义是**：
#          "**外部器件**需要数据在【`clk_sys` 沿】之前 **D** ns 稳定"
#      ⇒ ⭐ **留给 FPGA 内部的时间 = 周期 − D = 20 − 10 = 【10 ns】** ⚠️
#      ⇒ 🔴 **D 越大越紧、D 越小越松** —— ⭐ 与原文的直觉**正好相反** ✅
#   📌 **实测证据**（⭐ 2026-10-01 的 PnR）：
#      · ⭐ 唯一一条 setup 违例就是 `u_i2s_tx/HP_BCK_s1 → HP_BCK_obuf`
#      · ⭐ `required = 10.000 ns`（⭐ 正是 `20 − 10` ✅）· ⭐ `data = 11.827 ns` ⇒ ⭐ slack **−1.827** ❌
#      · ⭐ `Fmax` 掉到 **45.815 MHz** ⇒ ⭐ **PnR FAIL**（⭐ 门槛 51.5）✅
#      · ⚠️ 而同一份 RTL 在别的布局下 `Fmax` 是 52.0~55.7 ⇒ ⭐ **这条约束让结果对布局极度敏感** ✅
#   ⭐ **量纲错在哪**：⭐ BCK 实际周期 **320 ns**（⭐ 3.125 MHz），⭐ 拿它的半周期去论证一个
#      **相对 `clk_sys`** 的约束 ⇒ 🔴 **两者不是同一个参考系** ✅
#   ⭐ **真正的建立/保持要求是 `BCK → DIN`**（⭐ 同域内）—— ⭐ 它**已由 `tb_i2s_tx_timing`
#      实测为 160 ns 余量** ✅ ⇒ ⭐ 工具侧只需一个**能挂住这条路径**的预算即可 ✅
#   ✅ **取值**：⭐ `-max 2.0` ⇒ ⭐ 内部预算 = **18 ns**（⭐ 仍比 11.8 ns 的实测路径紧 ⇒ ⭐ **检查没丢** ✅）
#      ⚠️ **⛔ 不是 `false_path`** —— ⭐ 那会**完全放弃**这条路径的工具侧检查 ✅
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]

# 直流/人眼观测脚：无时序要求（⭐ 理由见上）
set_false_path -to [get_ports {PA_EN_n}]
set_false_path -to [get_ports {led_heartbeat}]

# 复位输入：异步按键 + 已由 rst_sync 同步（K-50）⇒ 不设 input_delay
set_false_path -from [get_ports {rst_n}]


# H5: same PLL divisors as verified 640x480 bringup; CDC remains timed.
create_generated_clock -name serial_clk -source [get_ports {clk}] -master_clock clk_sys -divide_by 8 -multiply_by 20 [get_pins {u_hdmi/u_clk/u_pll/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {clk}] -master_clock clk_sys -divide_by 40 -multiply_by 20 [get_pins {u_hdmi/u_clk/u_pll/CLKOUT1}]

# ═════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-26`）：⭐ **`serial_clk`（125 MHz）域的验证状态** ✅
#
#  🔴🔴 **重要变更（⭐ 2026-10-09，⭐ 由 `P0-24` 引起）**：
#     ⭐ 审查快照当时报 **"No timing paths to get frequency of serial_clk!"**
#        —— ⭐ 那时该域**只有 `OSER10` 的 `FCLK`**，⭐ **不承载寄存器逻辑** ✅
#     ⭐ **但 `P0-24` 往该域加了 `rstn_ser` 三级同步器**
#        （⭐ `rtl/hdmi/hdmi_scope.v`，⭐ 用 `posedge serial_clk` ✅）
#        ⇒ ⭐ **该域现在有真逻辑了** ✅
#     ⇒ ⭐ 工具**已经自动报了它的 Fmax**（⭐ 实测 `1312.981 MHz`，⭐ 约束 `125 MHz` ✅）
#     ⇒ ⭐ **"零验证"这件事【已经不存在】** —— ⭐ 本条的原始前提**已失效** ✅
#
#  ✅ **现在的状态**：⭐ `serial_clk` **在 Max Frequency Summary 里有一行**
#     （⭐ `tr_content.html` 的 "Max Frequency Summary" 段 ✅）
#     · ⭐ 实测 `Actual Fmax = 1312.981 MHz` · ⭐ `Logic Level = 1`
#     · ⭐ 约束 `125.000 MHz` ⇒ ⭐ **余量 10.5×** ✅
#
#  🔴 **纪律（⭐ 机械门）**：⭐ `sim/gowin_build.ps1` 的 **`P0-26` 门**断言 ——
#     ⭐ **每一条 `create_generated_clock` 都必须在 Max Frequency Summary 里有一行** ✅
#     · 🔴 **改前**：⭐ `serial_clk` **没有行** ⇒ ⭐ **FAIL**（⭐ 这正是审查当时的状态 ✅）
#     · ✅ **现在**：⭐ `clk_sys` / `serial_clk` / `pixel_clk` **三行都有** ⇒ ⭐ **PASS** ✅
#     📌 ⭐ 若哪天有人把 `rstn_ser` 删了 ⇒ ⭐ 那行会**消失** ⇒ ⭐ **门主动报警** ✅
#
#  📌 **速率余量论证（⭐ 上板闭环的便宜替代）**：⭐ H4 已在 **6.15×** 速率上出图
#     （⭐ 1537.5 Mb/s ÷ 250 Mb/s ⇒ ⭐ 见 `bringup/hdmi_640x480/`）✅
#  📌 ⭐ **唯一真判据是【仪器】**：⭐ 量 `tmds_clk_p` 的 **125 MHz**
#     ＋ ⭐ `tmds_d_p_0` 的 **250 Mb/s 眼宽**（⭐ 记录到 `evidence/h5/`）✅
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# ⭐⭐ 2026-10-04：**余量预算（margin）约束** —— 独立实验，物理时钟不变
#
# 🔴 动机（实测）：布局器只按 `clk_sys` 20 ns 优化，报告里那个 Fmax（52.219 MHz）
#    只是**外推值** ⇒ 它**没有为 51.5 MHz 门槛做任何优化**。
#    ⇒ 这里给"起止都在 `clk_sys` 域"的路径加一条**更紧的预算**，让布局器真正去争。
#
# ⚠️ 三条纪律（来自 codex 只读评审 `margin-roadmap-review-20261004`）：
#   ① **物理不变**：50 MHz 晶振、PLL 与 `1024` 分频都不动 ⇒ 板子照跑 50 MHz；
#      本约束只改**优化目标**（故意过约束），⛔ 不改任何硬件行为。
#   ② ⛔ **不许**用 `set_clock_groups -asynchronous` 把 `clk_sys` 与 HDMI 整组切开 ——
#      那会连 `u_rst_sync → OSER10/RESET` 的**真实 recovery/removal** 检查一起删掉
#      （当前 recovery +1.490 ns、removal +0.217 ns，都是必须保留的检查）。
#   ③ `gray_launch`/`full_launch` 走的是 `negedge sample_clk` 半周期预算（10 ns，
#      见 `rtl/hdmi/waveform_scope.v:38-43`）⇒ 必须**显式钉住 10 ns**，
#      否则会被下面那条 19.417 意外放宽。
#
# 📌 取值：19.417 ns ≈ 51.5 MHz（精确值 19.4174757 ⇒ 这里**略紧**）。
#    挑战档 = 18.181 ns（≈55 MHz，精确 18.1818182 ⇒ **略松**，确保严格达标）。
# ⚠️ 验收三步：① Constraints Report 全部 Actived 且对象非空；
#    ② Timing Exceptions Report 确认 max-delay 真正覆盖目标锥（⛔ 不能只看 Fmax 汇总）；
#    ③ 对**同一份 PnR 结果**按 nominal 口径复算 Fmax 与四类 slack。
# ═════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-10：⭐ **过约束实验** —— 18.181 → **17.0**（55.0 → 58.8 MHz）✅
#   📌 **为什么**：⭐ 原 `18.181 ns` 是**目标**，⛔ 不是能力 ——
#      ⭐ 工具**只要满足它就停手** ✅ ⇒ ⭐ 报告 Fmax 恰好 ≈ 55 MHz ✅
#      ⭐ 最差 slack 只剩 **+0.028 ns** ⇒ ⭐ **余量薄是"没让它更拼"造成的** ✅
#   ✅ **收紧到 17.0 ns** ⇒ ⭐ 工具更努力 ⇒ ⭐ 报告 Fmax 涨 + ⭐ 真实余量变厚 ✅
#   ⚠️ **代价**：⭐ PnR 时间可能变长 · ⭐ 若不收敛 ⇒ ⭐ 回退 ✅
#   📌 ⭐ 参考：⭐ 本项目历史最高 `Fmax = 60.784 MHz` ⇒ ⭐ 58.8 是**可达的** ✅
#  ⭐⭐ 2026-10-10：⭐ **过约束标定实验（⭐ 第 2 次：17.0 → 17.8）** ✅
#   📌 **两次实验的数据**：
#      · ⭐ 目标 `18.181 ns`（55.0 MHz）⇒ ⭐ 实测 `Fmax 55.087` · ⭐ slack **+0.028** · ⭐ 0 违例 ✅
#      · ⭐ 目标 `17.0 ns`（58.8 MHz）⇒ ⭐ 实测 `Fmax 57.203` · ⭐ slack **−0.481** · 🔴 14 违例 ❌
#   ⇒ ⭐ **设计的真实上限 ≈ 57.2 MHz** ✅（⭐ 17.48 ns ✅）
#   ⇒ ⭐ **18.181 那个目标【太松】** —— ⭐ 工具一到就收工 ⇒ ⭐ 余量只有 +0.028 ✅
#   ✅ **取 17.8 ns**（56.2 MHz ✅）—— ⭐ 比上限低 ~1 MHz，⭐ 留收敛余量 ✅
#      ⇒ ⭐ 工具会干到接近极限 ⇒ ⭐ **相对 50 MHz 时钟的真实余量 ≈ 20 − 17.8 = +2.2 ns** ✅
#   📌 ⭐ 这是**唯一**能真抬余量的杠杆（⭐ PnR 是确定性的 ⇒ ⭐ "重跑抽签"无效 ✅）
# OPT08: placement target only; physical clk_sys remains 50 MHz.
# Native slack uses 16.4 ns, not the AO 16.8 ns comparison budget.
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 16.4
set_max_delay -from [get_clocks {clk_sys}] -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0 u_hdmi/u_scope/full_launch_s0 u_hdmi/u_scope/mode_launch_s0}] 10.000
