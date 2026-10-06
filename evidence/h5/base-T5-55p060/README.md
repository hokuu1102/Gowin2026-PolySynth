# 回到合并版基线 + 队友 T5 —— 交付（2026-10-06）

## 用户要求
"回退到合并版时序 56 多的那一个版本，加上队友远端的新提交"

## 实际做了什么

| 项 | 结果 |
|---|---|
| 远端新提交 | ⚠️ **没有** —— 队友的 `340f193`(T5) + `0d0c168` 早已合入，本地 = 远端 |
| 56.351 基线提交 | `2be631f` |
| 回退内容 | 只回退**我自己的 4 个音频文件**到 `2be631f`（见下） |
| 保留内容 | 队友 T5（`rtl/top.v` +72 / `rtl/w3b/note_manager.v` +48）+ 全部 evidence 文档 |

**回退的 4 个文件**（`git checkout 2be631f --`）：
- `rtl/w3b/tdm_render_mixer.v` ← 电平感知归一化（`gain_lin_lut` / `n_eff` / 迟滞）
- `rtl/w3b/envelope_bank.v` ← C 方案（包络总线原子提交 / `env_lvl_shadow`）
- `tb/w3b/tb_tdm_render_mixer.sv` ← 新增的第 6 段判据
- `tb/w3b/tb_p5_adsr_diff.sv` ← 为 C 方案改的契约

**刻意没动的**：`rtl/top.v`（差异逐行核对过，**只**是队友 T5，无 `OUTPUT_HEADROOM_SH` 行）、
`note_manager.v`、队友的两个 T5 测试台。

## ⚠️ 一个必须说清的事实

**"56.351 + T5" 不等于 56.351。**

```
56.351 MHz 是【不含 T5】那一版的时序（2be631f）
T5 延音踏板实打实加了 RTL（top.v +72 行 / note_manager.v +48 行）
⇒ 把 T5 加回来，Fmax 必然下降
```

## 本次实测

| 项 | 合并版（无 T5，`2be631f`） | **本版（基线 + T5）** |
|---|---|---|
| `clk_sys` | 56.351 | **55.060 MHz** |
| setup / hold | 0 / 0 | **0 / 0** ✅ |
| Logic | 34471 | 34647（+176） |
| Register | 16922 | 16975（+53） |
| CLS | 23343 | 23228（−115） |
| DSP | 22 | 22 |
| 码流 | 19,408,479 B | 19,336,303 B |

⇒ ⭐ **55.060 MHz 仍远高于 51.5 MHz 门槛（+6.9%）**，0/0 违例 ✅

## 码流
| 项 | 值 |
|---|---|
| 文件 | `Z_merged_base_T5.fs`（19,336,303 B） |
| sha256 | `1F938F5D0C0B5D398B97F792D947C9FFE026E008A93F73E1219F730AAB7C3D90` |
| 参数 | `TEST_MODE_EN=0` · `RIGHT_ADC_ENABLE=0` · `OUTPUT_HEADROOM_SH=1` · margin 18.181 ns |

## 回归（回退后的状态）
`tb_tdm_render_mixer` · `tb_p5_adsr_diff` · `tb_envelope_bank` · `tb_note_manager_sus` · `tb_top_m0` 全绿 ✅

## 版本对照（`Desktop\学习\hdmi_640x480\bitstreams\`）

| 文件 | 内容 | `clk_sys` |
|---|---|---|
| ⭐ **`Z_merged_base_T5.fs`** | **合并版基线（无我的音频实验）+ 队友 T5** | **55.060** |
| `R_merged_56p351.fs` | 合并版基线（**不含 T5**） | 56.351 |
| `Y_merged_Conly.fs` | 基线 + 我的 C 方案（已回退） | 55.406 |
| `X_merged_A.fs` / `W_merged_atomic.fs` / `V_merged_levelaware2.fs` | 我的音频实验（均已回退） | 55.899 / 55.406 / 55.294 |

## 说明

我的音频实验（电平感知归一化 / C 方案 / A 方案）**全部已从 RTL 回退**，
但**证据与文档保留**在 `evidence/h5/` 下（不参与综合），包括那条**已锁定的根因**：

> 用户测试 B 实测：按住键时**霍尔位置读数持续变化** ⇒ 力度目标持续更新
> ⇒ ADSR 的 SUSTAIN 电平持续移动 ⇒ 高 sustain 音色（0.70/0.90）幅度摆幅最大 ⇒ "收音机滋滋声"