# 主工程 OPT06 优化通路交付

## 范围与来源

原合并版 AE → 校准优化 AF（基线 commit `3c945614f371757a1f4320a70a01e7a5bc26611f`）
→ note_manager 的 env/age 无符号分半比较 → clk_sys 内部实现目标 16.8 ns。

此次主工程已有 AF 校准优化，新增产品改动仅 `rtl/w3b/note_manager.v`、
`constr/top.sdc`；不纳入被排除的 envelope/mixer 实验。声部数、振荡器数、
音色、流水拍数和控制接口不变，不削减功能。真实系统时钟仍为 50 MHz，
音频分频不变；原 HDMI PLL 保留，没有新增 PLL。CST 和 GPRJ 不变。
78 个 RTL/IP/资源输入与 OPT06 候选一致。

## 本次主目录重新构建

2026-10-13 19:21:11 主目录 `build_cli.tcl` 完整综合、布局布线、
烧录文件生成结束，退出 0；13/13 回归通过，负向对照按预期退出 1。
最终时序门通过，不用既有候选报告代替此次重新构建结果。

| 指标 | 主工程重建结果 |
|---|---:|
| clk_sys 实际 Fmax | 60.741 MHz |
| pixel_clk / serial_clk 实际 Fmax | 37.433 / 343.864 MHz |
| 原生 Setup / Hold | +0.337 / +0.198 ns |
| Recovery / Removal | +1.196 / +0.123 ns |
| Setup / Hold 违规端点 | 0 / 0 |
| Logic / CLS | 40765 / 25684 |
| BSRAM / DSP | 69 / 22 |

以上 Setup 是 **16.8 ns 实现目标**下的值，不能直接与 17.8 ns 目标的
Slack 相减。相比 OPT04 V2 系统 Fmax +1.557 MHz，折算限制周期缩短
约 0.433 ns，资源不增加；实际系统时钟不提频。CLS 仍约占 86%，
此方案主要增加时序余量，不宣称腾出了物理资源。
CT2065、CT1094、PR1014 等原有告警仍存在，没有新增告警类别，
不宣称所有外部接口/CDC/温压条件全部完成闭环。

主目录新 fs 与原 AN 候选的文件哈希不同，但经完整文本核对，差异仅为
创建时间及 CRLF/LF 换行；除此之外配置内容完全一致。
时序路径报告 `Gowin2026.timing_paths` 哈希亦完全一致。

### 新烧录文件

主目录输出：`impl/pnr/Gowin2026.fs`。
已复制到原烧录文件目录，旧版本不覆盖：

`C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams/AO_main_opt06_CANDIDATE_UNVERIFIED_20261013.fs`

SHA256：`17DE0189B4AB8D367B9F35413AED7B86498557D838D44A4D6BA21B7FE1BFF625`。
目标器件沿用本工程 `GW5AT-LV60PG484AC1/I0`、B 版本，不改板型或引脚。
此文件尚未上板验收。原始构建/STA/仿真记录保存在本目录。

## 可复现检查

从主目录运行：

```powershell
& ./tools/run_opt06_accept.ps1
& 'D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe' build_cli.tcl
& ./tools/read_opt06_timing.ps1 -ProjectDir (Get-Location).Path
```

验收包括 NM 逐拍公共输出等价、1/7/16/17 位共 400000 组比较、延音、
力度斜坡/回绕、共享写、voice、顶层波形、Test Mode、复音起音、TDM mixer、
50266 拍 32 声部轮转和 1815845 拍完整变调。保留原激励和数值断言；
轮转与变调的对照模块冻结到当前 AF，原旧测试不改动。
旧 transpose/rot32 内嵌参考版本已过时，已有历史失败，不能称全部旧套件全绿。
负向对照故意强制年龄比较错误，应报 `split age mismatch`、退出 1。

## 回退保障

改动前完整跟踪/未跟踪文件共 3427 份已备份并核对哈希；原有 68 条
未提交状态不纳入本次交付。备份位置（ASCII 路径）：

`C:/Users/cyx/Documents/ChatGPT/FPGA/rollback-pre-opt06-20261013`

其中 「worktree/」（历史引用，当前未收录） 是原文件；`repository.bundle` 保存 Git 全历史；
本地回退分支为 `codex/rollback-pre-opt06-20261013`。
原主目录 `impl/` 另存于备份的 `impl/`，其旧 fs 早于 AF 源码，
不要误标为 AF 构建；额外备份的 「af-impl/」（历史引用，当前未收录） 与 AF 的 78 项输入一致，
用于恢复匹配的 AF 构建结果。

回退脚本默认仅校验，不改动。需要回退时，先关闭 Gowin IDE/构建进程：

```powershell
& ./tools/rollback_opt06_local.ps1
& ./tools/rollback_opt06_local.ps1 -Apply
```

脚本核对 81 项当前源码/工程/约束及 AF 备份完整性，若后续修改了任何
这些输入则拒绝覆盖；先保存当前 impl，再恢复两项产品文件及匹配 AF impl。
不会移动 Git HEAD、删除历史、切换分支或覆盖无关工作文件；新增测试与证据保留。
因此回退结果以反向工作区差异显示，后续可单独提交，不使用 reset --hard。
AF 烧录文件 SHA256：
`C25DD989518C278AF139E0A06190F0BDD3917A87BC7A5598A297D0DD36DB23BC`。

回退脚本在独立副本 `rollback-opt06-selftest-20261013` 实际执行通过，
两项源码及所有 AF impl 备份条目、fs 均恢复并核对哈希；主工程未因此回退。
再次校验原先 3427 个文件，除本次授权修改的两项产品文件外，哈希变化为零。

## 上板状态

尚未上板，本地仿真/STA 不等同于实板验收，也不把原 AE 的上板结论转移过来。
烧录前接好左右手 ADC 板，缺右手板会产生正常故障告警。
重点检查复位/故障灯、16 键演奏与灯、E 波形切换、Test Mode N=4/8/16/32、
数字音量与颤音、B 节拍器/Q BPM、W 滑音和 Y 录制回传，
按原合并版已有验收方式逐项对照；这不是新增功能的声明。
保留旧烧录文件，不覆盖旧文件名。此次不推送远端。
