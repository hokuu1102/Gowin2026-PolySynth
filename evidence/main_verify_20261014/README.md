# main 9d30dd3 本地核验与同步

日期：2026-10-14。被测代码固定为 `9d30dd3c444e2ac80228ae389dcfb49eab9f0d3c`；比较基线为原 AT 合并交付 `7e62f68d6ac919964d3104c8267ed81fa4b2d2e3`。本文是独立核验记录，不采信旧交接文档的过时状态。

## 结论与同步范围

- 已把远端 main 同步到独立 ASCII 工作区和本地分支 `codex/verify-main-20261014`。
- **不是正式验收通过版本**：hold 余量门失败，滑音已有缺陷仍复现，上行新协议未实现。
- 不覆盖原 AT/AV 工程、不修改 RTL/约束、不烧板、不推送远端；FFT 实现仍暂停。
- 原 FFT 两份规划文档留在旧交付工作区，未丢失；它们按旧资源数规划，未来实施应参考本次新余量。
- 本轮166项均执行过；明确正向PASS合计156项，仍有4个长测超时，因此回归不放行。分类详见 `acceptance.json`，不把诊断/负向/编译失败合并成“全绿”。

## 干净综合、PnR 与资源

从新建 worktree 的空 impl 开始，执行 `tools/build_target_pnr.tcl` 的显式 `run syn` + `run pnr`，退出码0。完成于 11:58:28；没有复用之前的综合网表。

| 项 | 本次独立测量 | 旧 AT 合并交付 |
|---|---:|---:|
| 物理系统时钟 | 50 MHz | 50 MHz |
| 内部 max-delay 目标 | 16.4 ns | 16.4 ns |
| sys Fmax | 61.094 MHz | 61.081 MHz |
| pixel Fmax | 49.217 MHz | 41.488 MHz |
| serial Fmax | 358.857 MHz | 807.346 MHz |
| setup slack | +0.032 ns | +0.028 ns |
| hold slack | **+0.047 ns** | +0.142 ns |
| recovery / removal | +1.030 / +0.123 ns | +0.134 / +0.440 ns |
| setup / hold 违例端点 | 0 / 0 | 0 / 0 |
| CLS | 25271 / 29952 | 24889 / 29952 |
| Logic / Register | 38181 / 18627 | 37886 / 18609 |
| BSRAM / DSP | 69 / 22 | 69 / 22 |

当前 CLS 剩余4681，比原交付减少382。Fmax增加0.013 MHz，不能概括成“所有时序余量都提高”。

`sim/gowin_build.ps1` 的项目 hold 门要求 ≥0.05 ns。本次0.047 ns差3 ps，**仍按 FAIL 记录**；零物理hold违例不能替代这个门。最差hold路径为 `g_sound.u_envelope_bank/lvl_sr_496_s10/Q` → `g_sound.u_envelope_bank/lvl_sr_lvl_sr_0_0_s/ADB[9]`，data delay0.263 ns、clock skew−0.185 ns。不能未经实测就把失败归为“布局噪声所以可忽略”。

输入超集的73个文件记录于 `product_inputs.csv`，构建后hash变化0。完整原始报告在 `reports/`，运行日志为 `fresh_build.log`，当前口径为 `metrics.json`。旧 AO 解析器输出单独保存在 `timing_parser_output.json`；其中 AO 比较字段**不是本次比较口径**，不能拿它替代本页 AT 对比或50ps门。

位流由本次构建生成，已归档到用户指定 bitstreams 目录，文件名为 `AW_main_9d30dd3_HOLD_GATE_FAIL_KNOWN_BUGS_UNVERIFIED_20261014.fs`。大小19912631字节，SHA256为 `EB963F9C96D2C8F27323889735C038CDB3A1E0D3793CE3A0B59E01F298924EEB`。详见 `bitstream.json`。它与队友提交说明中的位流hash不同；本次没有获取队友原始fs做逐字节比较，不宣称二者位流相同。

## 功能实证

| 对象 | 本次证据 | 结论边界 |
|---|---|---|
| A模式切换 | `known_bugs.log` 的真实UART刺激；mode=0、accepted=1、unknown=0，A断言通过 | 原A总闸漏接已修；不是板侧串口回包实测 |
| 颤音推子 | raw×120>>12 实接，已有正向测试 | 全行程映射已实现；仍是绝对相位增量偏移，不保证各音区相同cents |
| 手动BPM | 新模块使用真实bg_bar_start，保留曲谱tempo原路；严格wrapper正常用例退出0 | 请求先pending、下一个小节生效；同拍set优先下一小节；未做新上板验收 |
| 滑音 | `known_bugs.log` 退出1，6个失败断言 | 有效数据握手/最终吸附、所属轴、W关闭、位置比例跟随仍未修；6断言不是6个独立根因 |
| ESP32工具 | 独立Python环境：28工具、643项OK、0 RED；额外离线计划5/5通过 | 不含固件编译/刷写，不含实板BLE/串口/屏验证 |
| 14B实时上行、11B批量上行 | 源码和提交说明核对 | 尚未实现，现9B回传不能冒充新协议端到端通过 |

Python首次运行因缺少serial等依赖失败，归为环境问题。只在 `build/verify-env` 安装pyserial/bleak/mido，重新运行通过；`python_requirements.txt` 固定本次环境，不改全局Python。

## Standards

1. 新 `tb_bpm_bar_quant` 用 `if (!cond)` 和部分 `==`，未知态会假绿；也没有按验证规范接A8。`tb_bpm_x_verdict_probe.sv` 强制输出X，原判据仍退出0并报PASS。`tb_bpm_strict_probe.sv` 是仅用于核验的wrapper：正常输入退出0，注入X时退出1，证明独立严格监视器能抓住错误。**没有把原台改好，也不是宣称正常RTL会产生X。**
2. 项目hold50ps门失败；详见干净PnR。
3. 默认回归跳过真实故障诊断只能是分类，不能证明故障消失；本次已单独重跑并记录。

判断性问题：旧write-share台和OPT08台重复镜像断言，需保持同步；新增 `bpm_pending_obs` 只有内部连线，未送到UART/LED/屏，不能称板侧可观测。新RTL继续使用系统50MHz、同步低有效复位，没有新增PLL/CPU/HLS。

## Spec

新增A、H/Q废臂、颤音行程、手动BPM小节对齐在源码中均实接，未发现新增明确规格违背。

已有未满足项分别是：用户确认的校准行程比例跟随；滑音的握手/轴归属/关闭行为；新上行协议闭环。不得借新增功能回归通过而删去这些已有问题。交接文档称钢琴模式可顺带验滑音也不能盲从，实际接线仍要求指板模式。

两轴静态评审统计：Standards硬验收缺口3项、判断性问题2项；Spec已有未满足要求3组。原始测试执行中发现的测试分类/超时等问题另列，不合并为同一优先级排名。

## 回归执行方式与边界

原 `sim/tb_all.ps1` 在主核验工作区运行，发现169台、默认跳过3台（其中2个音频导出工具、1个真实故障诊断）。日志 `full_regression.log`。Windows Job宿主也可能导致“已经出现PASS但Wait-Job超时”，这种情况不自动放行。

为减少串行等待，在 `build/verification_source` 的9d30dd3源码快照运行8-worker独立Icarus核验；原源码、ROM、模型、宏及逐台timeout规则不改。268个相关Git blob校验通过，仅允许Windows CRLF checkout差异。结果在 `parallel_full/`，总日志 `parallel_regression.log`；执行器 `run_parallel_snapshot.py` 另外要求正向PASS结论，故与原执行器无结论退出0即通过的口径可能不同，需分别统计。

已观察到的分类：

- `tb_ctrl_keypad`：已有Icarus对continue语法的编译兼容问题，不是新矩阵功能已集成的证明。
- `tb_opt04_nm_age_negative`：源码主动force错误age比较，预期触发fatal的变异诊断；原默认执行器未单独分类，不能算普通正向PASS，也不等于优化后的实际比较逻辑错误。
- 三个span诊断台及 `tb_evt_uart_rx_screen` 退出0，但不打印统一PASS；后者明确复现未门控解析器对屏数据的误解析，并提示另一个gate台负责保护。四者分别记录为诊断结论，不能悄悄改成正向全绿。
- 墙钟TIMEOUT与功能断言FAIL分别统计；未得到完整结论不算通过，延长预算重测要保留原失败记录。

### 最终回归数字

| 类别 | 数量 | 结论 |
|---|---:|---|
| 初次明确PASS | 149 | 原始结果保留在 `parallel_full/` |
| 超时延长墙钟后PASS | 7 | 不改RTL/宏/激励/断言，只把墙钟预算改为1500秒；复测在 `parallel_retry/` |
| 无统一PASS的诊断台 | 4 | 单独保留具体观察，不计正式正向PASS |
| 预期fatal的age变异台 | 1 | 负向诊断捕获生效，不计普通正向PASS |
| Icarus编译兼容失败 | 1 | ctrl_keypad的continue；不能写成矩阵功能已通过 |
| 尚未完成的长测 | 4 | e2e_key_to_sound、looper_replay_tail、top_sound、transpose |
| 本轮执行总数 | 166 | 合计156个明确PASS，**不是166/166验收通过** |

四个剩余长测在原墙钟预算内未取得完成结论，本轮没有再普遍放宽预算，不能把它们推定为功能通过，也没有据此认定新增RTL故障。原默认执行器总共发现169台，另跳过3台；其中真实滑音诊断已额外单跑。166个编译日志中Pruning/implicit definition命中0，记录于 `compile_width_checks.json`。

Test Mode真实合成仿真产出的8192点样本另经原 `csv_fft.py` / `peak_count.py` 判据验证，4/8/16/32四档的谱峰数全部符合；证据在 `test_mode_fft/`。这不是新实时FFT功能，也不是最终I2S实板采集。

原串行执行器为交叉核对而启动，后因隔离快照已完成全部166项，停止了本任务自己的重复执行器及子进程；`full_regression.log` 是**中断的部分日志，不是全量结果**。PID记录在 `serial_duplicate_stopped.json`。它改写的48份已跟踪生成物和19份新生成物已归档到 `serial_partial/`，默认sim/evidence已恢复到被测提交，避免污染旧证据。部分超时输出/CSV可能为空，不能当成功证据。

本轮同时运行的所有核验进程现已结束；没有留待后台自动完成的验收承诺。

## 尚未包含的BLE分支

main已吸收较早的ESP32工作，但和 `origin/feat/s3-ble` 的 `7cdede3` 仍有5个文件差异：build.ps1、ble_main.c、pool.c、pool.h、sdkconfig.defaults。包括随机地址、进度总tick、pump诊断/调度以及FreeRTOS tick=1000Hz等修改；**本次没有擅自合入该分支**。不能把main工具离线通过扩大成“最新BLE固件已集成通过”。

## 后续

先补实回归中的分类/超时结论及BPM台X检查，再决定是否修复hold门；滑音按此前分工交给队友。只有明确标注这些条件，才能选择该候选为FFT开发起点。正式出声主工程和原AT/AV位流保持可回退。
