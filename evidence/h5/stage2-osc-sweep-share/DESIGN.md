# 阶段 2 设计说明：鼓扫频 per-lane → per-voice 共享

> 来源：codex 只读评审 `margin-roadmap-review-20261004`（阶段 2）
> 状态：**前置检查已通过、安全设计已推导完毕、尚未实施**（2026-10-04 09:0x）
> ⛔ 本文件是**待执行规格**，不是已完成记录。

## 1. 前置检查（已完成 ✅）

| 检查项 | 结果 |
|---|---|
| codex 要求：「先检查阶段 1 裁剪后综合器是否已经自动合并 sweep」 | ✅ **没有合并** |
| 证据 | 综合网表 `impl/gwsynthesis/Gowin2026.vg` 里 `sweep_q` 触发器实例 = **1024 个**（64 lane × 16 位） |
| 落点确认 | `rtl/w3b/oscillator_bank.v:290` `for (g = 0; g < LANES; ...) begin : gen_lane`；`VOICE_IDX = g / OSC_PER_VOICE`（L292）、`OSC_IDX = g % OSC_PER_VOICE`（L297） |
| 综合资源 | `oscillator_bank`：Register **4778** / ALU **5318** / LUT **5376**（`Gowin2026_syn_rsc.xml`） |
| ⇒ 结论 | ⭐ **有真实收益**：可省 **512 FF**（1024→512）＋ 一半分类比较器/桶形移位/衰减算术 |

## 2. 为什么可以共享（等价性论证）

同一 voice 的两个 lane：

| 量 | 依赖 | 是否相同 |
|---|---|---|
| `base_inc`（L339-340） | `base_phase_inc_i[VOICE_IDX*PHASE_W +: PHASE_W]` —— ⛔ **不含 `OSC_IDX`** | ✅ **两 lane 完全相同** |
| `is_kick_drum` / `is_tom_drum`（L386-388） | 只由 `base_inc` + `lane_drum[g]` 决定 | ✅ 相同（`lane_drum` 是 per-voice，见 L381-383 注释） |
| `sweep_kick` / `sweep_tom` / `sweep_load`（L394-403） | 只由 `base_inc` 决定 | ✅ 相同 |
| `sweep_dec`（L420-421） | 只由 `sweep_q` 决定 | ✅ 相同（若初值相同） |
| **`sweep_q`（L406）** | **每 lane 各一份** | ⚠️ **当前重复 64 份** |
| `phase_rst_lane`（L314） | `voice_phase_rst_i[VOICE_IDX]` —— per-voice | ✅ 相同 |
| `lane_active` 的上升沿 | 正常模式 = `voice_active_i[VOICE_IDX]`（per-voice）⇒ 相同<br>Test Mode = `test_lane_active_i[g]`（per-lane）⇒ **可能不同** | ⚠️ 见下 |

### ⚠️ codex 指出的反例，以及为什么它不构成障碍

codex 原文：「Test Mode 只激活每 voice 的 lane 0（`test_mode_ctrl.v:78–82`）⇒ 两个 lane 的
`lane_active_d` 在测试模式下不同，退出时可能触发不同的 sweep reload。」

✅ **但 reload 被 `!test_mode_i` 屏蔽**（L530：`if (!test_mode_i && (phase_rst_lane || (lane_active && !lane_active_d)))`）
⇒ 测试模式**期间**两个 lane 都不会 reload（也不会用 sweep —— L430-432 里 Test Mode 直接走
`test_phase_inc_i`，完全绕过 `lane_inc_sweep`）
⇒ **只有在 `test_mode_i == 0` 时**才会 reload，而那时两个 lane 的 `lane_active`
**必然相同**（都是 `voice_active_i[VOICE_IDX]`）
⇒ ⭐ **共享后用 lane 0 的边沿作 per-voice 判据，与逐 lane 版本逐拍等价** ✅

## 3. 待实施的改动（`rtl/w3b/oscillator_bank.v`）

### 3.1 新增：per-voice sweep 生成块（放在 `gen_lane` 循环**之前**）

```verilog
//  ⭐⭐ 2026-10-04（codex 阶段 2）：鼓扫频状态**按 voice 共享**（原为 per-lane 重复 64 份）
//  依据：同 voice 两 lane 的 base_inc / 分类 / 装载值 / 衰减**完全相同**（见设计说明 §2）
//  ⚠️ reload 用 lane 0 的 lane_active 边沿 —— 与逐 lane 版本逐拍等价（Test Mode 被 !test_mode_i 屏蔽）
wire [DRUM_SWEEP_W-1:0] voice_sweep_off [0:POLY_TARGET-1];
for (v = 0; v < POLY_TARGET; v = v + 1) begin : gen_voice_sweep
    wire [PHASE_W-1:0] v_base_inc = base_phase_inc_i[v*PHASE_W +: PHASE_W];
    wire v_drum = lane_drum[v*OSC_PER_VOICE];          // 每 voice 的 drum 标志（两 lane 相同）
    wire v_kick = v_drum && (v_base_inc <  DRUM_KICK_MAX_C);
    wire v_tom  = v_drum && (v_base_inc >= DRUM_KICK_MAX_C) && (v_base_inc < DRUM_TOM_MAX_C);
    wire [DRUM_SWEEP_W-1:0] v_sweep_load =
        (DRUM_PITCH_ENV_EN == 0) ? {DRUM_SWEEP_W{1'b0}}
      : v_kick                   ? (v_base_inc >> (DRUM_SWEEP_LSB_SH + DRUM_KICK_SWEEP_SH))
      : v_tom                    ? (v_base_inc >> (DRUM_SWEEP_LSB_SH + DRUM_TOM_SWEEP_SH))
      :                            {DRUM_SWEEP_W{1'b0}};
    reg  [DRUM_SWEEP_W-1:0] v_sweep_q;
    reg                     v_active_d;
    // lane 0 的 active（Test Mode 下 lane 0 才是被激活的那个）
    wire v_active = test_mode_i ? test_lane_active_i[v*OSC_PER_VOICE]
                                : voice_active_i[v];
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            v_sweep_q  <= {DRUM_SWEEP_W{1'b0}};
            v_active_d <= 1'b0;
        end else if (sample_tick_i) begin
            v_active_d <= v_active;
            if (!test_mode_i && (voice_phase_rst_i[v] || (v_active && !v_active_d)))
                v_sweep_q <= v_sweep_load;                       // 起音：装载
            else if (v_sweep_q != 0)
                v_sweep_q <= v_sweep_q - (v_sweep_q >> DRUM_SWEEP_SH) - 1'b1;  // 指数衰减
        end
    end
    assign voice_sweep_off[v] = v_sweep_q << DRUM_SWEEP_LSB_SH;
end
```

### 3.2 删除（`gen_lane` 内）：L386–421 的 `is_kick_drum` / `is_tom_drum` / `sweep_kick` / `sweep_tom` / `sweep_load` / `sweep_q` / `sweep_off` / `sweep_dec`

### 3.3 修改（`gen_lane` 内）：

- L409-410 `sweep_off` ⇒ 改为 `wire [PHASE_W-1:0] sweep_off = {{(PHASE_W-DRUM_SWEEP_W){1'b0}}, voice_sweep_off[VOICE_IDX]};`
  （⚠️ 注意：共享版已在 per-voice 块里左移过，这里**不要重复左移**；按实施时的实际写法二选一，保持**只左移一次**）
- L468 `sweep_q <= 0`（复位分支）⇒ **删除**（状态已移到 per-voice 块）
- L533-536 的 `sweep_q <= sweep_load`（起音分支）⇒ **删除**（同上）

## 4. 前置验证（⛔ 不通过不准进 PnR）

1. **逐沿差分**：新增 `tb/w3b/tb_oscillator_sweep_share.sv`，把「per-lane 版」与「per-voice 版」
   两个模型并排跑，逐系统时钟沿比较**每 lane 的 `phase_q` / `addr_q` / sample 输出**。
   覆盖：鼓类别边界（`base_inc` 恰在 `DRUM_KICK_MAX_C` / `DRUM_TOM_MAX_C` 两侧）、
   失谐开关、颤音正负半周、retrigger、note_off 后再起音、**Test Mode 进出**（含「只激活 lane 0」）。
   必须做**红检**：故意把共享版改成「晚一拍装载」或「用 lane 1 的边沿」都要被抓到。
2. **现有测试台全绿**：`tb_oscillator_bank`、`tb_top_sound`、`tb_timbre_adsr`、
   `tb_e2e_key_to_sound`、`tb_polyphony_onset_step`、`tb_wavetable_bank*`。
3. **综合资源门槛**（codex 要求「先验收资源减量」）：Register 应减少约 **512**（1024→512）；
   CLS 目标：较当前 `TEST_MODE_EN=0` 版（**26287**）再降；⛔ 若 ALU/LUT 没降 ⇒ 立即放弃。
4. **失败即停**：等价失败、资源未降、或 PnR 后全局时序退化且无新假设 ⇒ 回退并归档为研究证据。

## 5. 构建预算位置

按 codex 的 6 次预算表，阶段 2 属于「第 4 次（若 mixer 被跳过则改试阶段 2）」。
当前已用掉：**第 1 次**（margin SDC）、**第 2 次**（`TEST_MODE_EN=0`）。
剩余：第 3 次（`TEST_MODE_EN=1` 诊断版，可推迟到 RTL 定稿后）、第 4 次（本阶段）、
第 5 次（可选 55 MHz 挑战）、第 6 次（保留）。

## 6. 当前基线（实施前的参照点）

| 项 | 值 |
|---|---|
| 提交 | `6796257`（阶段 0 + 阶段 1） |
| 树内配置 | `TEST_MODE_EN = 0`（正式码流） |
| `clk_sys` | 报告 51.551 MHz / setup 0 / hold 0；按 19.417 预算 slack **+0.019** |
| 资源 | Logic 47929 / **CLS 26287（88%）** / Register 15660 / BSRAM 31 / DSP 51 |
| 历史最好余量 | 52.219 MHz（`TEST_MODE_EN=1` + margin SDC，CLS 26886） |
| 归档锚点 | 标签 `timing-53p425-h5-20261002`（53.425 / 0-0） |
