# 双码流交付说明（2026-10-04）

## 两个配置（同一份源码 `d1da5d4` 之后）

| 配置 | 切换方式 | `clk_sys` | 55 MHz 预算 | setup/hold | Logic | CLS | 用途 |
|---|---|---|---|---|---|---|---|
| **正式版** | `rtl/top.v` 里 `parameter integer TEST_MODE_EN = 0` | **56.399 MHz** | ✅ +0.450 ns | 0/0 | 46283 | **86%** | 上板交付（Test Mode 编译裁剪） |
| **诊断版** | 同上改回 `= 1`（**当前默认值**） | **55.198 MHz** | ✅ +0.065 ns | 0/0 | 48823 | 89% | 保留完整 Test Mode（FFT 验收等） |

## 构建方法（切换后必须用全新 impl）

```
1) 改 rtl/top.v 的 TEST_MODE_EN 默认值（0 = 正式 / 1 = 诊断）
2) 删除整个 impl/ 目录（⛔ 只删 impl/pnr 不够 —— set_option 会持久化进 impl/）
3) gw_sh build_cli.tcl
4) 验收：setup 0 / hold 0、cmd.do 里 place=0/route=0、报告创建时间晚于本轮开始
```

## 余量预算（`constr/top.sdc`）

```tcl
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
set_max_delay -from [get_clocks {clk_sys}] -to [get_regs {u_hdmi/u_scope/gray_launch_*_s0
                                                          u_hdmi/u_scope/full_launch_s0}] 10.000
```

- 18.181 ns ≈ **55 MHz**（精确 18.1818182 ⇒ 略松，确保严格达标）
- ⛔ 物理 50 MHz 晶振与 PLL 分频**一字未动** —— 它只是**优化目标与验收预算**
- ⛔ 未用 `set_clock_groups -asynchronous`（会删掉 `u_rst_sync→OSER10/RESET` 的真实 recovery/removal 检查）
- ⭐ 实测规律：约束**比设计能力更松**时它只是验收尺；**一旦收紧到超过能力，布局器会真的重新布局**
  （19.417 → 18.181 让 Fmax 从 53.652 跳到 56.399）

## 累计提升（相对合并树基线）

| 指标 | 基线 | 现在（正式版） |
|---|---|---|
| `clk_sys` | 52.219 MHz | **56.399 MHz**（+8.0%） |
| 余量 vs 51.5 门槛 | +1.40% | **+9.51%** |
| 余量 vs 50 MHz 物理时钟 | +4.44% | **+12.8%** |
| CLS | 26886 (90%) | **25725 (86%)** |
| Logic | 50680 | **46283** |
| Register | 15700 | **15148** |

## ⚠️ 未完成 / 待办

1. **正式版的码流需要重建一次**：本目录归档的是**诊断版**码流；
   正式版（56.399）的**报告已归档**在 `evidence/h5/margin-18p181-56p399/`，
   但其 `.fs` 在构建诊断版时被覆盖 ⇒ 需要按上面方法重跑一次才能拿到正式版码流。
2. **上板验证**：两个码流都还没上板。
3. **进一步降 CLS**：当前最差路径已换成 `note_manager`（`gate_r/retrig_low → scan_cnt/best_idx`
   抢声部逻辑）与 `tdm_render_mixer`（`cnt → prod_c`）⇒ 这两个是下一轮的靶子。