# `tools/exp/` —— 判据/分析脚本（⭐ 从 `build/exp/` 入库，2026-09-28）

> ⭐ **为什么入库**：`build/` 被 `.gitignore` 整目录排除 ⇒ 这些脚本**此前不在仓库里**。
> ⚠️ 后果：`rtl/w3a/axis_map.v:326/366` 明确引用 `build/exp/kb_map.py` 生成音高常量，
> 但**换音高图后没人能重算**；⭐ 且"分析结论"因脚本缺失而**不可复核**。

---

## 一、⭐ 最该先看（生成类，改动后必须重跑）

| 脚本 | 用途 | 谁引用它 |
|---|---|---|
| ⭐ **`kb_map.py`** | 由 MIDI 号精确算 `phase_inc`，生成 `axis_map` 的 `KB_*` 常量 | ⭐ `rtl/w3a/axis_map.v:326,366` |
| **`gain_chain.py`** | 推导 `tdm_render_mixer` 的归一化基准 **88** | `rtl/w3b/tdm_render_mixer.v:454` |

⚠️ **纪律**：改音高图 / 改归一化基准后，⭐ **必须重跑这两个脚本**并同步 RTL 常量。

---

## 二、校验类（改完跑一遍）

| 脚本 | 判据 |
|---|---|
| **`check_kb_inc.py`** | 核对 `kb_inc` 表是否与 MIDI 计算一致 |
| **`check_pitch_const.py`** | 基频恒定性检查 |
| ⭐ **`adsr_release_time.py`** | ⭐ **ADSR 时间常数计算**（判"卡死/挂死"前**必跑**，见 `C84`） |
| `adsr_timing.py` | 同上（早期版） |

---

## 三、B2/B3 的离线分析

| 脚本 | 用途 |
|---|---|
| ⭐ **`reason_retrig.py`** | 重触发时序推演（B3） |
| ⭐ **`reason_adsr_stuck.py`** | ADSR 为何停在非零（B3） |
| **`trace_stuck_adsr.py`** | 逐拍追 ADSR 内部状态 |
| **`trace_events.py`** | 逐拍追事件产生 |
| **`parse_leak_vcd.py`** | 从 VCD 解析 voice 泄漏 |

---

## 四、波形分析

| 脚本 | 用途 |
|---|---|
| ⭐ **`analyze_ds0004.py`** | ⭐ **DS0004（尖音）分析** —— 孤立单点尖峰、~11 倍、音高一致、无平顶 |
| **`find_waveform_shape.py`** | 找削顶/方波的签名 |
| **`analyze_distortion.py`** | 失真分析 |

---

## 五、⚠️ 使用注意

1. ⭐ **这些脚本读的是绝对路径**（如 `C:\Users\hokuu\Downloads\DS0004.CSV`）
   ⇒ 换机器要改路径。
2. ⭐ **脚本里的结论可能已过时** —— ⛔ 不要把它当权威，
   ⭐ 与 `files/20-代码/重大更正-20260928.md` 冲突时**以更正为准**。
3. ⛔ **不要用这些脚本替代仓库 tb** —— 判据必须能进 `sim/tb_all.ps1` 才算防回归。
