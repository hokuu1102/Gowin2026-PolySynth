# 实时回传按键修正版 · 53.319 MHz

本版将控制板原标定键改为实时回传开关，并修复“关闭后仍持续发送松键事件”。上电关闭，消抖后松手切换一次，长按不连发；屏幕与串口 O 共用实际开关，上电自动标定及串口 T 保留。

关闭后拒收所有新 note_on、note_off 和 pluck，关闭前已接收的队列与帧正常发完。排空后继续按键、松键或拨弦均不产生新回传。没有添加延时补发或 all-notes-off，ESP32 固件、协议、引脚和时钟不变。

## 下载和复核

- [FPGA 烧录文件](firmware/Gowin2026-51-HMI-key15-uplink-disable-fix-50MHz-20261102.fs)
- [实际编译输入 ZIP](source/FPGA-key15-uplink-53m319-build-inputs-20261102.zip)：按原生构建快照逐字节冻结，解压后在该目录运行 `gw_sh build.tcl` 可重建；不承诺重建码流逐字节相同。
- [构建与交付清单](evidence/manifest.json)、[输入哈希](evidence/build-inputs.json)、[目录校验值](SHA256SUMS.txt)
- [10 项相关回归](evidence/regression-summary.json)、[原生时序报告](evidence/native-STA.html)、[时序门禁](evidence/timing-gate.log)
- [修复前复现](evidence/tb_evt_upstream_toggle.before-fix.log)、[修复后验证](evidence/tb_evt_upstream_toggle.after-fix.log)

烧录件 SHA256：`ab4472efe3e2bf70801557bb980935c38b8b1b2f12b323ecc5300aa09f93d5c0`。

## 验证范围

| 项目 | 本次结果 |
|---|---:|
| 实际系统时钟 | 50 MHz，未降低 |
| 报告 Fmax | 53.319 MHz（前一按键版 53.587 MHz） |
| 实际 20 ns 周期建立余量 | +1.245 ns（前版 +1.339 ns） |
| Hold / Recovery / Removal | +0.089 / +0.250 / +0.203 ns |
| 原有实际 50 MHz 门禁 | PASS，退出码 0 |
| 更严的 16.4 ns 布局预算 | 建立余量 -2.355 ns，744 个违例端点 |
| 本次相关回归 | 10 项全部通过，未跑全量回归 |
| 实机按键、BLE、音频和长稳 | 待烧录后验收 |

通过实际 50 MHz 门禁不代表 16.4 ns 优化预算全部通过。原测试、容量及功能不因时序优化而缩减。相对前一按键版，仅删除关闭时放行 OFF 的例外；少 1 个寄存器、1 个 LUT，DSP、RAM、ALU 不变。

本地实际编译提交为 `2d948be1b52d299a97ff22878eb35d7b7fe182d6`，开发存档保留。交付分支整理为相对前次串口屏交付的一个完整提交，生产文件与本次已编译快照一致；精确字节以冻结 ZIP 和哈希为准。旧版本仅供追溯，不作为本次修正版的烧录入口。

本版继承 [串口屏集成版](../20261101-hmi-52m4/README.md)及后续指示灯修复、时序改进。独立分支发布，远端 main 保留其现有更新。
