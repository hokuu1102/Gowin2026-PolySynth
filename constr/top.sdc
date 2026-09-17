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
