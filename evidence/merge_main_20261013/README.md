# 2026-10-13 远端 main 合并记录

## 输入与保留范围

- 本地父提交：`ef55c63`；远端 main：`7a861b41201aec70d8a5a8afc50c8fffe2e27071`。
- 本地备份分支：`codex/backup-before-main-merge-20261013`。
- 合并前未提交的日志与未跟踪文件存入 `pre-main-merge-20261013-user-work` stash；完成合并后恢复，不加入合并提交。
- 按明确的合并要求保留双方历史，不 rebase、不强制推送。

## 冲突处理

| 位置 | 原冲突 | 合并结果与理由 |
|---|---|---|
| `rtl/top.v` | 本地事件告警与远端新增曲谱缓冲告警 | 保留既有告警，增加 `eb_ovf` 与 `eb_drop`；不屏蔽 ADC 告警 |
| `rtl/w3a/calib_cmd.v` | 双方各自将命令数增加到 19，并占用槽位 18 | 命令数改为 20，Y 用槽位 18、Q 用槽位 19，保留两者的复位与单拍脉冲 |
| 七份历史仿真日志 | 同名文件来自不同版本或不同机器 | 使用远端历史日志；它们不是本次合并版本的验证证据。本次日志独立保存在此目录 |

本地持续采样 `scope_valid = mm_valid`、像素域帧边界切换、ADC 全通道端点判断与 200 ms 启动保护、相关 SDC 均保留。远端独立 ESP32 UART、曲谱缓冲/播放、音高量纲修正、录制回传和鼓机修复均纳入。

## 验证边界

- 本次针对合并代码运行回归：20/20 通过；结果以本目录各测试日志为准。
- 测试清单：`tb_adc_fault_window`、`tb_scope_mode_switch`、`tb_top_scope_live`、`tb_adc_farm`、`tb_waveform_scope`、`tb_xy_scope`、`tb_top_m0`、`tb_right_adc`、`tb_tdm_render_mixer`、`tb_top_score_path`、`tb_evt_buf`、`tb_rec_dump`、`tb_score_chain`、`tb_drum_gen_posreset`、`tb_key_drum`、`tb_calib_cmd`、`tb_calib_cmd_q_y`、`tb_looper`、`tb_drum_sweep_window`、`tb_pool_by_src`。
- 本次没有重新跑完整测试集或长时间 `tb_top_sound` 音频验收；20 项通过不等同于全量回归通过。
- 新增 `tb_calib_cmd_q_y` 检查 Q/Y 独立单拍脉冲、帧内载荷不触发命令、帧后命令恢复，并用重复字母负向实例证明查重表覆盖两者。该实例的预期 ERROR 不是正式实例失败。
- 文档引用检查：165 处硬错误，未通过；合并前记录为 159 处。完整输出见 `doc_refs.log`，本次不扩大到修整历史文档。
- 人名检查：本机没有 `names.local.txt`，跳过，不计作通过。
- 未重新运行 Gowin 综合/PnR，未生成新烧录文件，未上板验收，未推送。
- 旧 X/Y 位流均不是本次合并后的位流，不能据其结果声称新版本已上板。
