# AT 主工程应用与回退记录

初始版本：AO，`a42cc32a36bf800973e1ccddc314466034ae17fb`。
状态：AT 已应用于主工程，软件验收、重新综合/布局布线、归档及实际隔离回退测试通过。
本记录用于本地提交；未推送远端，未直接烧录，尚未上板验收。

## 修改范围

产品仅修改 `rtl/w3b/note_manager.v` 与 `constr/top.sdc`。
live 声部复用原 `vtgt_rep` 保存每轴目标镜像，新增 32 个有效位；
live/replay 共享原有 ±8 力度斜坡，保留 9 位比较、同拍写/清除/分配优先级。
权威每轴表保留，公共接口、输出拍数、32 声部、64 个独立振荡器与其它模块不改。
未采用 OPT07 mixer、OPT08 V1 或独立 V2 的时序退步方案。
AT 路径为 AO → note_manager 目标寄存器复用/斜坡共享 → 16.4 ns 实现目标。
真实系统时钟仍为 50 MHz，音频分频不变；不新增 PLL/CPU/HLS，原 HDMI PLL 保留。
81 项构建输入与 AT 候选逐项文本一致，清单见 `build_inputs_sha256.csv`。

## 本次软件验收

本次在主工程重新运行，不只是继承候选结果：

- 12 项原回归和 1 项私有存储表示适配测试，共 13/13 通过。
- 完整实时变调、32 声部轮转、延音、力度、测试模式、示波/混音回归通过。
- 冻结 AO 参考与 DUT 的 15 组公共输出逐拍一致；4/32 声部共 200000 配置周期通过。
- P4 同拍覆盖 overlap=25205 / alloc=7901 / clear=4942；P32 为 9878 / 2219 / 2896。
- 注入错误力度输出后 cycle31 必须失败；负向对照按预期失败，证明检测器有效。
- 私有表示适配测试 24324 拍通过：561 次提交、173 次重触发、734 次同拍冲突，访问全部 32 个声部。

旧 `tb_note_manager_write_share` 没有删除或修改。live 的 `vtgt_rep` 用途改变，
旧私有字段 oracle 在 cycle41 失败；`legacy_oracle` 中记录复制自同 RTL 的 V2 实验，
不是本次重新运行旧测试，也不是新增功能错误被忽略。
适配测试只替换该私有字段 oracle（live 匹配权威轴表，replay 仍匹配旧参考）并检查有效位，
原刺激、公共输出和其它内部断言保持。不能据此宣称所有历史测试全绿。
日志在 `accept/`，摘要在 `acceptance.json`，校验值在 `acceptance_logs_sha256.csv`。
这是选定配置/刺激的仿真验证，不是所有参数、X/Z、温压或硬件的形式证明。

## 构建陷阱与最终核验要求

第一次只运行 `run pnr`，该主工程状态下复用了 AO 综合网表。
即使报告新、退出码为 0，也不是 AT 产品；CLS 仍为 25684，该结果明确排除。
诊断记录保留在 `rejected_cached_netlist/`，不要用于交付。
最终入口 `tools/build_target_pnr.tcl` 已改为显式 `run syn` 后 `run pnr`。
第二次日志确认解析新的 `vtgt_live_vld`，综合资源 XML 与 AT 候选一致。
必须等最终构建退出，再核对报告时间、81 项输入、资源与四类时序检查后归档。

## 最终主工程构建：AU = AT 的重新生成版本

显式综合/布局布线退出 0，最终日志结束时间为 2026-10-14 08:49:46。
报告与烧录文件均晚于本次启动时间；81 项输入在整个构建期间未变。
主工程新产物复现 AT 指标，综合资源 XML 与候选一致。

| 指标 | 原 AO | 主工程 AT（AU） |
|---|---:|---:|
| 内部实现目标 ns | 16.8 | 16.4 |
| 系统 Fmax MHz | 60.741 | 61.006 |
| Setup ns（各自原生预算） | 0.337 | 0.008 |
| Hold ns | 0.198 | 0.094 |
| Recovery / Removal ns | 1.196 / 0.123 | 0.679 / 0.055 |
| Setup / Hold 违例端点 | 0 / 0 | 0 / 0 |
| pixel / serial Fmax MHz | 37.433 / 343.864 | 50.366 / 680.098 |
| Logic / CLS | 40765 / 25684 | 37657 / 24958 |
| Register | 18518 | 18550 |
| DSP / BRAM | 22 / 69 | 22 / 69 |

减少 726 CLS（约 2.83%）、3108 Logic；寄存器增加 32。
系统 Fmax 增加 0.265 MHz，限制周期折算缩短约 0.0715 ns。
可用 CLS 从 4268 增加至 4994；不承诺未实现的新功能一定放得下。
四类时序检查均通过，但 Hold/Recovery/Removal 比 AO 小，不能称所有裕量都改善。
两列 Setup 预算不同，不直接相减；16.4 ns 下的 8 ps 不等于 50 MHz 只剩 8 ps。
没有另跑同一 16.8 ns 预算的全局 STA，不把周期算术当作实测全局 Slack。
原 CT2065/CT1094/PR1014 等告警仍保留，没有新增告警类别。
关键瓶颈仍为 note_manager.scan_cnt → cand_env 选择/比较 → best_env。
详见 `metrics.json`、`build_run.json`、`build.log` 与 `reports/`。

归档文件（中文路径仅用于成品存档）：
`C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams/AU_main_opt08_AT_CANDIDATE_UNVERIFIED_20261014.fs`。
SHA256：`7FFC7960C254CD2BF1B47EA39862C1195DE5415D000AA162E75DA67D8C7A6467`。
归档与主工程 `impl/pnr/Gowin2026.fs` 原始字节 SHA256 相同。
与 AT 候选相比，规范化 CRLF/LF 并去掉 Created Time 头后整份文件完全一致；
实际配置没有变化。AU 是归档序号，不是额外叠加的新优化。
旧 AO、AT 文件均保留；新文件明确标记尚未上板。

## 回退保障

AO 快照：`C:/Users/cyx/Documents/ChatGPT/FPGA/rollback-pre-at-20261013`。
包括 3473 个原工作区文件、24 个 AO 实现文件、SHA256 清单和验证过的完整 Git bundle。
本地回退分支：`codex/rollback-pre-at-20261013`，指向 AO。
原 68 条未提交状态属于用户，未并入本次提交；非目标的 3471 个原文件已核对不变。
原 AO 与 AT 烧录文件保留，不覆盖。

在主工程目录运行：

```powershell
& ./tools/rollback_at_local.ps1          # 仅预检查
& ./tools/rollback_at_local.ps1 -Apply   # 确认后恢复 AO，先关闭 Gowin/构建进程
```

脚本校验全部 81 项 AT 输入及 AO 备份，若后续有产品改动则拒绝覆盖。
恢复两份源码/约束与配套 AO 实现；恢复前另存当前实现。
不移动 Git HEAD，不删除其它源码、测试或历史；回退后源码反向改动会出现在 git diff。
隔离副本已实际执行本脚本恢复 AO：81 项 AO 输入、24 个实现文件与原 AO fs 校验全部通过。
预检查与拒绝覆盖后续修改的测试均通过，无关哨兵文件保留；主工程 AT 输入/fs 未受影响。
日志见 `rollback_apply_selftest.log`、`rollback_refusal.log`、`rollback_selftest.json`。
现有 OPT06 → AF 回退与备份继续保留；AT 需先通过本脚本回到 AO。

## 复现与待验收

在主工程的 ASCII 路径下运行：

```powershell
& ./tools/run_opt08_accept.ps1 -EvidenceDir evidence/opt08_retest
& 'D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe' tools/build_target_pnr.tcl
```

适配测试仅清理末尾空格后又单独复测通过，记录见 `format_retest/`。
尚未上板、未直接烧录、未推送远端。
上板仍需验正常演奏/压力变化、E 波形切换、B 节拍、Q 帧式参数、W 滑音和 Y 记录导出等原功能，
并观察三片 ADC 与指示灯；本次软件通过不替代实板验收。
