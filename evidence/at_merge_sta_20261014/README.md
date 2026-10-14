# AT + 队友 main：新布局布线与功能诊断（2026-10-14）

固定产品源：集成提交 `031cf36`，两方父提交为 AT `0cdf8c6` 与队友 `9bf2de6`。
本次只运行验证并增加诊断测试/证据，不改产品 RTL、约束、IP 或器件参数。
84 项产品输入见 `inputs_before.csv`，结束后逐项确认构建期间未变。
原 AT/AU 主工程、AO 回退备份与 68 条未提交状态保持不变。

## 时序状态

已以 `tools/build_target_pnr.tcl` 显式 `run syn` 后 `run pnr` 完整重建，退出 0。
本工作区开始时不存在 impl，不复用历史综合网表或报告。
内部实现目标仍为 16.4 ns，实际系统为 50 MHz；既有 HDMI PLL 保留。
完成时间：2026-10-14 09:39:00；所有最终报告、网表与 fs 都晚于本次构建启动时间。
84 项产品输入在构建期间未变；后续证据提交不改变固定的 031cf36 产品内容。
AT 历史结果为 sys Fmax 61.006 MHz、CLS 24958、Register 18550、DSP 22、BRAM 69，
以下使用本次新报告，不使用上述历史产物作为合并版证据。

| 指标 | AT/AU | 本合并版 |
|---|---:|---:|
| sys Fmax MHz | 61.006 | 61.081 |
| pixel / serial Fmax MHz | 50.366 / 680.098 | 41.488 / 807.346 |
| Setup ns（同为16.4 ns预算） | 0.008 | 0.028 |
| Hold ns | 0.094 | 0.142 |
| Recovery / Removal ns | 0.679 / 0.055 | 0.134 / 0.440 |
| Setup / Hold 违例端点 | 0 / 0 | 0 / 0 |
| Logic / CLS | 37657 / 24958 | 37886 / 24889 |
| Register | 18550 | 18609 |
| DSP / BRAM | 22 / 69 | 22 / 69 |

系统 Fmax 增加 0.075 MHz、CLS 减少 69，可用 CLS 为 5063。
同时 Logic 增加 229、寄存器增加 59；新增功能不是零逻辑成本，CLS 变化是实现后的装箱/布局结果。
当前16.4 ns目标、四类时序检查及项目 Hold>=0.05 ns 门均通过。
实际系统仍50 MHz，pixel/serial仍25/125 MHz；28 ps是严格实现目标余量，不是实际50 MHz只剩28 ps。
没有另跑解除16.4 ns目标的20 ns全局STA，不把算术换算当成实测全局余量。
Recovery 裕量和 pixel Fmax 比 AT 小，不能称全部指标改善，也不保证未实现的新功能一定放得下。

本次最差路径已变为 `u_calib_cmd.loop_rec_req_o` → looper计数/录制节拍与组合控制 →
`g_sound.u_looper.ramp_mask_1`，数据延迟16.323 ns、skew=-0.008 ns、Setup=+0.028 ns。
次级路径包括 ADC通道→校准限幅、回传busy→诊断状态、BPM→play_seq tick_inc。
后续如继续单模块优化，先评估 looper 的录音入口组合链；本次没有实施此优化。
原始报告、最差路径与指标见 `reports/`、`metrics.json`、`build_run.json`。
`metrics_ao_comparison.json` 是旧解析器的 AO 对照输出；本次结论以 metrics.json 的 AT 对照为准。

## 功能诊断：不能把旧测试绿等同于新功能正确

`tb/top/tb_at_merge_known_bugs.sv` 实例化真实 top，串口 A 通过真实 500000 baud UART 输入。
其它案例在滑音/快照和 note_manager 公共输入边界注入定向激励，
不 force note_manager 内部状态；观察公开的 packed voice 输出，并等待 128 拍避免轮转观察过早。
这是定向连线/语义诊断，不是 ADC 真实手势、声音听感或硬件验收。
当前版本该诊断台应失败，不能算作验收通过测试。

| 问题 | 合并版实测 | 是否由 AT 合并引入 |
|---|---|---|
| A 不能切模式 | mode=1，accepted=0，unknown=1 | 队友原版相同 |
| 起始/收尾数据有效握手错位 | 首次valid=1却送0而非起点；收尾ramp=0x00c51721、voice=0x00c51339 | 队友原版相同 |
| 反向滑动更新错轴/声部 | 原轴6停在0x00c8b729，独立轴7从0x00c51339变到0x00c8131c | 队友原版相同 |
| W 关闭后仍更新 | 开关0后仍观察到3次 pitch valid，active=1 | 队友原版相同 |
| 固定两轴比例不保持位置 | posA=384、posB=256，40%目标0x00cb799f，实际走到0x00d503e1 | 队友原版相同 |

五类问题对应七个失败断言（握手起始/收尾、错误更新另一轴/原轴停止分别断言）。
同一诊断台在未合并的队友工作区 `9bf2de6` 运行也失败；关键数值、失败标签逐项完全一致。
结果在 `diagnostic/tb_at_merge_known_bugs.log`、`remote_known_bugs.log`、`known_bugs.json`。
此前静态疑点已在上述受控激励边界复现，不冒充实际 ADC/实板复现。
两轴比例跟随是此前已确认的要求，现有实现仅以 B 表值为终点，功能尚未完成。

诊断台初版误将 DEMO_CHORD_ON=0（会移除整个 g_sound），其编译失败仅是测试配置问题；
现已改为 sound 引擎存在、SOURCE_A_SEL=0，相关旧日志带 harness 标记，不算产品缺陷。
初次观察等待过短的日志也只作 harness 调整记录；最终对照均使用相同的 128 拍等待。
此前 `tb_ctrl_keypad` 的 Icarus continue 编译问题及实体矩阵模块未接 top 的边界仍保留，
本次没有代改队友功能，也不宣称完整 suite 全绿。

## 已运行检查

新增集成回归 7/7 通过：slide_e2e、slide_top_pitch、event_extract_slide、
top_merge_startup、calib_equivalence、calib_cmd、calib_cmd_q_y。
含校准等价、启动、滑音触发/接线与协议已有判据；这些判据不覆盖上表全部缺陷。
AT 的 13 项选定回归通过，含完整变调、32 声部轮转、延音、力度、混音和显示已有判据。
4/32 声部共 200000 配置周期差分通过；注错后 cycle31 被抓到，负向守卫按预期失败。
本次共 20 个不同测试台的选定回归通过，不含故意暴露五类缺陷的诊断台，也不含 keypad 已知编译失败。
日志分别在 `integration/`、`at_accept/`。

新网表已确认：`g_sound.u_slide_ramp` 存在（58 Register / 65 ALU / 110 LUT），
`vtgt_live_vld` 被解析；不存在模块没进工程却引用旧报告的情况。
`u_uart_tx_esp` 被合并优化，但 uart_tx 与 esp_uart_tx_o 两个 OBUF 都接 esp_uart_tx_o_d，
镜像回传端口未丢失。其它旧扫除项和 CT1094/PR1014 等告警必须继续审视，不能称为无告警构建。

## 交付边界

不推送、不替换原主工程、不直接烧板，不在此轮实施 bug 修复。
新 fs 已归档到 `C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams/AV_merge_AT_teammate_KNOWN_BUGS_UNVERIFIED_20261014.fs`。
SHA256：`667A6360AED54C84EE67209B52DAD95B613CD24391AEEC067488D34A81DEF968`。
归档文件与本工程 impl/pnr/Gowin2026.fs 原始字节一致；原 AU 未替换，中文路径仅成品存档。
名称明确标注已知功能 bug 和尚未上板，不能当成已完成验收的替代版本。
布局布线通过也不能改变上述新功能失败结论；尚未上板验收。
