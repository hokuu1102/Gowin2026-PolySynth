# C 方案（包络总线原子提交）—— **已落地**（2026-10-06）

## 码流
| 项 | 值 |
|---|---|
| 文件 | `W_merged_atomic.fs`（18,973,975 B） |
| sha256 | `EEAD4045B659BC93D982B53B08CF12ECD20349AEEC1859DB5C4D1F2B0036E200` |
| `clk_sys` | **55.406 MHz** / setup 0 / hold 0 |
| 资源 | Logic 34678 · Register **17547** · CLS 23726（80%）· DSP 22 |

## 治的根因（治本）

`rtl/w3b/envelope_bank.v` L25-29 **自己记录的契约**：

```
CONTRACT CHANGE: env_level_o / env_active_o are fully updated only 33 clocks
after sample_tick_i (voice 0 at +2, voice 31 at +33)
```

⇒ ⭐ 每次 tick 后的 **33 拍（33/1024 ≈ 3.2%）**内，输出总线是"**已服务的新帧 + 未服务的旧帧**"的**混合**
（这个 3.2% 正是甲 §七#5 写的"~3%/次分配"）
⇒ 消费者（`tdm_render_mixer` / `note_manager`）在该窗口读 ⇒ 包络幅度**突跳**
⇒ 顶到 **87.5% 软限幅** ⇒ 听感 **"收音机滋滋声"**

### 为什么只有音色 0 和 3

四个音色里，**唯一把 {0,3} 与 {1,2} 分开的参数就是 `sustain`**（`adsr.v:75-78`）：

| 音色 | sustain | 持续电平 | 与软膝(87.5%)距离 |
|---|---|---|---|
| **0 BASS** | **0.70** | ~86% | ⭐ 几乎贴着 |
| 1 GUITAR | 0.30 | ~40% | 远 |
| 2 PIANO | 0.40 | ~50% | 远 |
| **3 PAD** | **0.90** | ~87% | ⭐ 几乎贴着 |

⇒ 高 sustain 音色"**住在软膝旁边**" ⇒ 任何突跳直接越界；
低 sustain 音色衰减到软膝很下面 ⇒ **同样的突跳够不到** ✅

## 修法

```verilog
reg [POLY_TARGET*ENV_W-1:0] env_lvl_shadow;   // +512 FF
reg [POLY_TARGET-1:0]       env_act_shadow;
...
// 本轮包络先写【影子】（逐拍写的条件与原来完全相同）
env_lvl_shadow[svc_i*ENV_W +: ENV_W] <= lvl_n;
// 轮转结束【一次性提交】（voice 31 的新值直接拼进高位 ⇒ 仍在 tick+33 完成）
if (cnt == CNT_STOP) begin
    env_level_o  <= {lvl_n, env_lvl_shadow[POLY_TARGET*ENV_W-1-ENV_W:0]};
    env_active_o <= {act_n, env_act_shadow[POLY_TARGET-2:0]};
end
```

⇒ ⭐ 消费者**任何时刻读到的都是一整帧**（要么全是上一帧、要么全是本帧）
⇒ **"新旧混合"在结构上不可能出现** ✅
⇒ 时序契约**不变**（仍 tick+33）⇒ 现有 testbench 的"等 34 拍"约定不受影响 ✅

## tb 契约更新（**加强**，不是放宽）

`tb_p5_adsr_diff` 原来断言 **"voice v 在 `c = 3+v` 逐拍落盘"** —— 那正是本方案要消除的行为。
改为断言：
- 轮转期间（`c <= 33`）：整条总线必须**逐位等于上一整帧**（⛔ 任何 voice 提前换值即失败）
- `c >= 34`：整条总线**原子**变成新一整帧

⭐ 实测 **frames compared = 3000 / mismatches = 0** ✅
（同时满足甲 §七#3 的纪律：改 `envelope_bank` 必须同步处理该测试的参考）

## 回归（全绿）

`tb_p5_adsr_diff` · `tb_envelope_bank` · `tb_adsr` · `tb_timbre_adsr` · `tb_p5_osc_equiv` ·
`tb_perc_env_bank` · `tb_drum_pitch_env` · `tb_drum_timbre_top` · `tb_dac_tone_top` ·
`tb_met_start_top` · `tb_perc_env_top` · `tb_test_mode_top` · `tb_top_led_strip` · `tb_top_m0` ·
**`tb_top_sound`** · `tb_top_t15` · `tb_top_test_mode_pipe` · `tb_top_timbre_button` ·
`tb_vel_top_stream` · `tb_vibrato_top` · `tb_wavetable_tone_top` · `tb_tdm_render_mixer` ·
`tb_voice_accept` · `tb_key_drum` · `tb_polyphony_onset_step`

⚠️ `tb_e2e_key_to_sound` 报 `TIMEOUT after 900 s`，但**日志里已出现 PASS** ——
这是该项目已知的"超时预算太紧"假报警（`K-94` 同族），⛔ **不是本次改动引入**。

## 代价

| 项 | 上一版 | 本版 | 差 |
|---|---|---|---|
| `clk_sys` | 55.294 | **55.406** | +0.112 |
| Logic | 34584 | 34678 | +94 |
| Register | 17020 | **17547** | **+527**（= 影子数组 512 + 少量） |
| CLS | 23539 | 23726 | +187 |
| DSP | 22 | 22 | 0 |

## 上板验证要点

| # | 测试 | 预期 |
|---|---|---|
| **1** | **3+ 复音 + 音色 0(BASS) / 3(PAD)**，重按长按，**多次** | ⭐ **"收音机滋滋声"应消失** |
| **2** | **单音 / 双音** | ⭐ **音量与旧版完全相同**（本方案不动增益） |
| **3** | 音色 1/2 | 无变化 |
| 4 | 16 键 / 4~8 复音 | 应稳定 |
| 5 | 整体音色 | 应无变化（ADSR 数学逐位等价，3000 帧 0 失配） |