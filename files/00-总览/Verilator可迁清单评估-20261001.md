# 🔬 Verilator 可迁清单评估 · 2026-10-01

> **任务**：`P1 ②` —— 评估「哪些 tb 可以迁到 Verilator」
> **性质**：只读评估 ＋ 探针实跑（⛔ 未改 `rtl/`、⛔ 未改 `tb/`、⛔ 未 `git add`）
> **环境**：Verilator **5.052**（`C:\verilator`，已在 PATH）· iverilog 作对照
> **⚠️ 背景约束**：本次评估期间**全量变异测试正在主树里跑** ⇒ `rtl/w3b/note_manager.v` 处于**临时变异态**。
> 除该文件外 `rtl/`/`tb/` 均未被本评估改动（已用 `git status --porcelain -- rtl/ tb/` 复核 ✅）。
> 探针产物一律写在 **`build/verilator_probe/`**（gitignored），⛔ 未污染工作区。

---

## 〇、⭐⭐ 结论先行

| ⭐ | 结论 |
|---|---|
| **1** | ⭐ Verilator **能原样编译并运行本工程**（⛔ 无需改一行 RTL/tb）✅ —— 命令见 §五 |
| **2** | 🔴 **交接文档里「本项目有 228 处 X/Z 判据」这个数字【复现不出来】** ⇒ 见 §一。本文件**所有数字都是本轮实测** |
| **3** | 🔴 **「只迁不含 X/Z 判据的 tb」这条口径** —— ⭐ **已被实验证伪** ⇒ 见 §三 |
| **4** | ⭐ 正确的迁移判据只能是 **「双跑对判据」**：同一 tb 在 iverilog 与 Verilator 下**各跑一次，比对 PASS/FAIL**。⛔ **静态扫描不够** |
| **5** | ⚠️ **Verilator 的 PASS 比 iverilog 的 PASS 弱**：`chk_xprop`（A8）在 2 态下**恒不触发却仍打印 `ok`** ⇒ 见 §四 |
| **6** | ⚡ **不是普遍加速**：iverilog 编译 ~0.3 s，Verilator 编译 ~10 s ⇒ ⭐ **只有 vvp 运行 ≫ 10 s 的重 tb 才划算** |
| **7** | ✅ **建议**：⛔ **不要把回归门换成 Verilator**。把它当 ①**第二模拟器做差分验证**（本轮靠它抓到 `tb_adsr` 的隐式 X 依赖）②**少数重 tb 的加速通道** |

---

## 一、🔴 核查：「228 处 X/Z 判据」

⚠️ 该数字**只出现在** `files/00-总览/交接文档-20261001.md:119` 与 `:269` —— ⭐ **没有任何数据文件支撑它**。

本轮实测（全量 `tb/` 与 `rtl/`）：

| ⭐ 口径 | ⭐ 实测值 | = 228? |
|---|---|---|
| tb X/Z 字面量（`1'bx`/`1'bz`/`'bx`/`'bz`） | **43** | ⛔ |
| tb `chk_xprop` 出现次数 | **54** | ⛔ |
| tb `$isunknown` | **2** | ⛔ |
| tb 中 X/Z 判据站点（`=== 1'bx` 等，去重后） | **45** | ⛔ |
| `rtl/` 的 `===` | 178 | ⛔ |
| `rtl/` 的 `!==` | 3 | ⛔ |
| `tb/` 的 `===` | 2112 | ⛔ |
| `tb/` 的 `!==` | 387 | ⛔ |
| 合计尝试 ① X/Z字面量 + chk_xprop | 97 | ⛔ |
| 合计尝试 ② rtl`===` + rtl`!==` + tb X/Z字面量 | **224**（最接近） | ⛔ |
| 合计尝试 ③ rtl`===` + tb X/Z字面量 + chk_xprop | 275 | ⛔ |

⭐ **结论**：**复现不出来**（最接近的一次差 4）。⇒ ⭐ 按 `C88`（**真契约 vs 派生常量**），
**⛔ 不要再引用「228」这个数字**，改引用本表。

⭐ **顺带一条事实**：`rtl/` 里 **X/Z 字面量 = 0**（`===` 有 178 处，但**都不与 x/z 比较**）。
⇒ ⭐ **X/Z 语义完全只影响 `tb/`**，⛔ 不影响综合产物。

---

## 二、⭐ 静态分级（110 个 tb）—— 只能当【初筛】，⛔ 不能当结论

**分级口径**（对 `tb/**/tb_*.sv` 逐个静态扫描）：

| 级 | 定义 | 数量 |
|---|---|---|
| **L3-BLOCKED** | 含**显式** X/Z 判据（`=== 1'bx` / `!== 1'bx` / `1'bz` / `$isunknown`） | **17** |
| **L2-PARTIAL** | 不含显式 X/Z 判据，但**例化了 `chk_xprop`** ⇒ 该 tb 的 A8 检查在 Verilator 下失效 | **17** |
| **L1-CLEAN** | 两者都没有 ⇒ **静态上**看不到任何 X/Z 依赖 | **76** |

✅ **交叉验证**：`17 + 17 + 76 = 110` ＝ `tb/**/tb_*.sv` 总数 ✅；
且 **L2 的 17 个恰好等于「引用 `chk_xprop` 的 tb」的 17 个**（独立扫描得到同一集合）✅

### L3-BLOCKED（17 个，逐条已核对匹配文本，无假阳性 ✅）

| tb | X/Z 站点 | tb | X/Z 站点 |
|---|---|---|---|
| `tb/w3b/tb_pool_by_src.sv` | 12 | `tb/w3b/tb_dds_wavetable_core.sv` | 2 |
| `tb/w3c/tb_pos_probe_axis.sv` | 4 | `tb/e2e/tb_e2e_key_to_sound.sv` | 1 |
| `tb/w3b/tb_wavetable_bank.sv` | 3 | `tb/w3c/tb_seq_arb.sv` | 1 |
| `tb/w3c/tb_uart_tx_fifo.sv` | 3 | `tb/w3b/tb_note_manager.sv` | 1 |
| `tb/w3b/tb_wavetable_bank_prom.sv` | 3 | `tb/w3b/tb_w1_interfaces.sv` | 1 |
| `tb/bringup/tb_dac_tone_top.sv` | 3 | `tb/bringup/tb_wavetable_tone_top.sv` | 1 |
| `tb/w3b/tb_timbre_adsr.sv` | 2 | `tb/w3c/tb_drum_gen.sv` | 1 |
| `tb/w3c/tb_pos_probe.sv` | 2 | `tb/voice/tb_pitch_shift_accept.sv` | 2 |
| `tb/w3b/tb_nm_no_leak.sv` | 2 | | |

⭐ **典型用法（`tb_pool_by_src`）**：它**故意把总线打成 X**（`{POLY{1'bx}}`）当**传感手段** ——
"这条线到底有没有被驱动？" ⇒ ⭐ **这种 tb 的判据完全建立在 4 态上**，迁 Verilator **必然失效**。

### L2-PARTIAL（17 个）

`tb/checkers/tb_checkers.sv` · `tb/clk_gen/tb_clk_gen.sv` · `tb/drivers/tb_calib.sv` ·
`tb/drivers/tb_debounce.sv` · `tb/drivers/tb_tlc5916_driver.sv` · `tb/latency/tb_latency_m2.sv` ·
`tb/top/tb_top_m0.sv` · `tb/voice/tb_voice_accept.sv` · `tb/w3b/tb_test_mode_ctrl.sv` ·
`tb/w3c/tb_evt_merge.sv` · `tb/w3c/tb_evt_uart_rx.sv` · `tb/w3c/tb_i2s_tx.sv` ·
`tb/w3c/tb_i2s_tx_prbs.sv` · `tb/w3c/tb_i2s_tx_sweep.sv` · `tb/w3c/tb_i2s_tx_timing.sv` ·
`tb/w3c/tb_looper.sv` · `tb/w3c/tb_play_seq.sv`

### L1-CLEAN（76 个）

<details>
<summary>点开看全部 76 个</summary>

`tb/clk_gen/tb_clk_gen_badparam.sv` · `tb/drivers/tb_adc_farm.sv` · `tb/drivers/tb_mcp3208_driver.sv` ·
`tb/drivers/tb_mcp3208_scanner.sv` · `tb/e2e/tb_demo_stall_diag.sv` · `tb/models/tb_mcp3208_model.sv` ·
`tb/top/tb_am_pipe.sv` · `tb/top/tb_export_key_wav.sv` · `tb/top/tb_export_wav.sv` · `tb/top/tb_top_sound.sv` ·
`tb/top/tb_top_t15.sv` · `tb/top/tb_top_timbre_button.sv` · `tb/voice/tb_voice_i2s_chain.sv` ·
`tb/w3a/tb_async_pluck_capture.sv` · `tb/w3a/tb_axis_map.sv` · `tb/w3a/tb_axis_snapshot.sv` ·
`tb/w3a/tb_calib_autotare.sv` · `tb/w3a/tb_calib_cmd.sv` · `tb/w3a/tb_calib_span.sv` ·
`tb/w3a/tb_calib_span_err.sv` · `tb/w3a/tb_calib_still_guard.sv` · `tb/w3a/tb_ee_adj.sv` ·
`tb/w3a/tb_event_extract.sv` · `tb/w3a/tb_param_extract.sv` · `tb/w3a/tb_play_mode_ctrl.sv` ·
`tb/w3a/tb_right_analog_ctrl.sv` · `tb/w3a/tb_span_alignment_gap.sv` · `tb/w3a/tb_span_axis_over_uart.sv` ·
`tb/w3a/tb_span_cross_channel.sv` · `tb/w3a/tb_span_multiaxis_noise.sv` · `tb/w3a/tb_span_need_press_width.sv` ·
`tb/w3a/tb_span_realistic.sv` · `tb/w3a/tb_span_released_stable.sv` · `tb/w3a/tb_span_retry_reemits_axis.sv` ·
`tb/w3a/tb_span_vote_offbyone.sv` · `tb/w3a/tb_span_with_real_adc_farm.sv` · `tb/w3a/tb_uart_calib_chain.sv` ·
`tb/w3b/tb_adsr.sv` · `tb/w3b/tb_akwf_wavetables.sv` · `tb/w3b/tb_drum_pitch_env.sv` ·
`tb/w3b/tb_envelope_bank.sv` · `tb/w3b/tb_nm_off_in_hold.sv` · `tb/w3b/tb_nm_reuse_tail.sv` ·
`tb/w3b/tb_oscillator_bank.sv` · `tb/w3b/tb_polyphony_onset_step.sv` · `tb/w3b/tb_retrig_reset_span.sv` ·
`tb/w3b/tb_soft_hard_blend.sv` · `tb/w3b/tb_tdm_render_mixer.sv` · `tb/w3b/tb_test_mode_fft.sv` ·
`tb/w3b/tb_test_mode_top.sv` · `tb/w3b/tb_timbre_event_path.sv` · `tb/w3b/tb_vel_pos_follow.sv` ·
`tb/w3b/tb_vel_top_stream.sv` · `tb/w3b/tb_velocity_headroom.sv` · `tb/w3b/tb_velocity_lane_isolation.sv` ·
`tb/w3b/tb_velocity_tone_decoupling.sv` · `tb/w3b/tb_vibrato_lfo.sv` · `tb/w3b/tb_vibrato_top.sv` ·
`tb/w3b/tb_wavetable_timbres.sv` · `tb/w3c/tb_beat_gen.sv` · `tb/w3c/tb_drum_timbre_top.sv` ·
`tb/w3c/tb_evt_uart_rx_screen.sv` · `tb/w3c/tb_led_data.sv` · `tb/w3c/tb_looper_bar_align.sv` ·
`tb/w3c/tb_looper_replay_tail.sv` · `tb/w3c/tb_looper_tail.sv` · `tb/w3c/tb_master_mix.sv` ·
`tb/w3c/tb_met_start_top.sv` · `tb/w3c/tb_metronome.sv` · `tb/w3c/tb_perc_env_bank.sv` ·
`tb/w3c/tb_perc_env_top.sv` · `tb/w3c/tb_score_looper_coexist.sv` · `tb/w3c/tb_tlc5916_bank.sv` ·
`tb/w3c/tb_uart_rx.sv` · `tb/w3c/tb_uart_tx.sv` · `tb/w3c/tb_uart_ui.sv`

</details>

### 🔴 为什么这份分级**不能**当结论

⭐ **`tb/w3b/tb_adsr.sv` 是 L1-CLEAN**（X/Z 站点 = 0、未用 `chk_xprop`），
⭐ **而它在 Verilator 下 `FAIL`**（10 条错）—— ⚠️ 原因见 §三。
⇒ ⭐ **L1 ≠ 可迁**。静态扫描**查不出隐式 X 依赖**。

---

## 三、🔴 决定性实验：`tb_adsr` 的**隐式** X 依赖

### 现象

| 模拟器 | 判定 |
|---|---|
| iverilog | ✅ `PASS: ADSR follows attack, decay, sustain, and release…` |
| Verilator 5.052 | 🔴 `FAIL: ADSR behavior had 10 error(s)`（`$finish at 961ns`） |

Verilator 的失败细节：包络**每次只涨 448**（应为 16384）⇒ 攻击段永远到不了 65280。

```
FAIL: attack must clamp to the velocity-scaled peak 65280, got 1792
FAIL: decay must fall monotonically, previous=1792 current=2240      ← 还在【涨】
FAIL: decay must clamp to the 0.5 sustain level 32640, got 3584
FAIL: release must finish at level=0 active=0, got 4880/1
```

### 根因（已定位到行）

`tb/w3b/tb_adsr.sv:19-32` 例化 `adsr` 时**没有连接 `.timbre_i`**（`retrig_reset_i` 同样未接）。
而 `rtl/w3b/adsr.v:45-56`：

```verilog
function [ENV_W:0] attack_for_timbre;
    input [1:0] timbre;
    begin
        case (timbre)
            2'd0: attack_for_timbre = 17'd448; // BASS:   ~3 ms
            ...
            default: attack_for_timbre = ATTACK_STEP;   // ← 16384
        endcase
    end
endfunction
```

| 模拟器 | 未连接的 `timbre_i` 取值 | `case` 命中 | `attack_step` | 结果 |
|---|---|---|---|---|
| **iverilog（4 态）** | **`2'bxx`** | ⭐ **X 不匹配任何分支** ⇒ 落 `default:` | **16384** | ✅ PASS |
| **Verilator（2 态）** | **`2'd0`** | ⭐ 命中 `2'd0`（BASS 配方） | **448** | 🔴 FAIL |

⭐ `448` **正是观测到的增量** ⇒ 机制完全闭合 ✅

### ⭐⭐ 能红验证（判据必须能红 —— 铁律 #2）

把 `tb_adsr.sv` **复制**到 `build/verilator_probe/tb_adsr_t0.sv`（⛔ 未动 `tb/`），
只插入一行 `.timbre_i(2'd0)`，然后用 **iverilog** 跑：

```
FAIL: attack must clamp to the velocity-scaled peak 65280, got 1792
FAIL: decay must fall monotonically, previous=1792 current=2240
...
FAIL: ADSR behavior had 10 error(s)
```

⇒ ⭐⭐ **与 Verilator 的输出【逐行一致】** ✅
⇒ ⭐ **证明**：`tb_adsr` 在 iverilog 下通过，**完全依赖 X 落到 `default:` 分支** ——
⭐ **X 是【承重】的**，⛔ 不是"无关紧要的 4 态残留"。

### 📌 方法论后果

| ⭐ | 后果 |
|---|---|
| **1** | ⛔ **文本扫描无法判定可迁性** —— 隐式 X（未连接端口 / 未驱动网 / 未初始化寄存器）**在文本里看不见** |
| **2** | ⭐ 唯一可靠判据 = **双跑对判据**（iverilog vs Verilator，比对 PASS/FAIL） |
| **3** | ⭐ 顺带发现一个**独立缺陷**：`tb_adsr` 的通过**依赖 X 语义**，本身就是**脆弱判据**（见 §八·待办） |

---

## 四、⚠️ A8（`chk_xprop`）在 Verilator 下**静默失效** —— 实证

`tb/checkers/chk_xprop.sv:37-48` 的核心：

```verilog
always @(posedge clk) begin
    if (rst_n === 1'b1) begin
        if (^sig === 1'bx) begin          // ← 缩位异或为 x ⇒ 有 X/Z
            err_cnt = err_cnt + 32'd1;
            $display("ERROR [A8] %0s 出现 X/Z：%b (t=%0t)", NAME, sig, $time);
        end
    end
end
```

🔴 **2 态下 `^sig` 永远不是 x** ⇒ `=== 1'bx` **恒假** ⇒ `err_cnt` 恒 0 ⇒ **A8 完全失效**。

### 实证：它**仍然打印绿字**

`tb_debounce` 在 Verilator 下的真实输出（`build/verilator_probe/tb_debounce.vrun.log`）：

```
ok : A8: no X/Z on key_level/enc_state
```

🔴 ⭐ **这是一行"看着通过、其实什么都没验"的证据**（`C83` 探针假绿的变体）。
⚠️ 而它与 iverilog 的输出**长得一样** ⇒ ⛔ **不比对模拟器就发现不了**。

**影响面**：**17 个 tb** 例化了 `chk_xprop`（= L2 名单）⇒ 迁移后这 17 个 tb 的 **A8 覆盖全部静默清零**。

---

## 五、⭐ 复现命令（可复制）

```powershell
$root = 'C:\Users\hokuu\Desktop\FPGA\FPGA2026'
function Get-HdlSources([string]$Dir) {
  @(Get-ChildItem -Path $Dir -Recurse -Include *.sv,*.v -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "tb_*" } | Sort-Object FullName | ForEach-Object { $_.FullName })
}
$rtl    = @(Get-HdlSources "$root\rtl") +
          @(Get-HdlSources "$root\bringup\dac_tone" | Where-Object { $_ -notmatch 'proj_fmt' })
$models = Get-HdlSources "$root\tb\models"
$chk    = Get-HdlSources "$root\tb\checkers"

$tb = "$root\tb\w3b\tb_adsr.sv"
$name = [IO.Path]::GetFileNameWithoutExtension($tb)

# ⭐ 注意三条：① 必须 --timing（否则 #delay 全部被忽略）② _prom 变体⛔ 不传 WAVETABLE_BEHAVIORAL
#             ③ -Wno-fatal 否则 lint 警告会挡住编译
& verilator --binary --timing -j 4 -Wno-fatal -Wno-lint `
    --top-module $name --Mdir "$root\build\verilator_probe\$name" -o $name `
    -DWAVETABLE_BEHAVIORAL @rtl @models @chk $tb

& "$root\build\verilator_probe\$name\$name"    # ⭐ 直接跑出的可执行文件
```

---

## 六、⭐ 探针实测数据（6 个 tb）

| tb | 等级 | iverilog 编译 | vvp 运行 | Verilator 编译 | Verilator 运行 | iverilog 判定 | Verilator 判定 | 一致? |
|---|---|---|---|---|---|---|---|---|
| `tb_adsr` | **L1** | 0.3 s | <0.1 s | **19.3 s** | ~0.001 s | ✅ PASS | 🔴 **FAIL(10)** | 🔴 **否** |
| `tb_calib_autotare` | **L1** | 0.2 s | <0.1 s | 12.2 s | ~0.001 s | ✅ PASS | ✅ PASS | ✅ 是 |
| `tb_clk_gen` | **L2** | 0.2 s | <0.1 s | 12.0 s | 0.006 s | ✅ PASS | ✅ PASS | ✅ 是 |
| `tb_pool_by_src` | **L3** | 0.2 s | <0.1 s | 16.9 s | ~1 s | ✅ PASS | 🔴 **FAIL(a5/a6/a7)** | 🔴 **否** |
| `tb_top_m0`（全 top） | **L2** | 0.3 s | **9.8 s** | 10.1 s | **0.4 s** | ✅ PASS | ✅ PASS | ✅ 是 |
| `tb_drivers/tb_debounce` | **L2** | 0.3 s | **18.3 s** | 9.4 s | **0.8 s** | ✅ PASS | ✅ PASS | ✅ 是 |

📌 **iverilog 侧判定的来源**：清洁代码下回归 **108/108 全绿**（交接文档）；
其中 `tb_adsr` 本轮我**另外一手复跑**确认 `HAS-PASS` ✅

### ⭐ 速度结论（⛔ 与直觉相反）

| tb 类型 | iverilog 总时间 | Verilator 总时间 | 谁快 |
|---|---|---|---|
| 小 tb（4 个探针） | **0.3 s** | **12 ~ 19 s** | ⭐ **iverilog 快 40~60×** |
| 全 top（`tb_top_m0`） | **10.1 s** | **10.5 s** | ⭐ **打平** |
| 重 tb（`tb_debounce`） | **18.6 s** | **10.2 s** | ⭐ **Verilator 快 1.8×** |

🔴 **根因**：iverilog 编译几乎免费（~0.3 s），Verilator 要生成 C++ 再 g++ 编译（~10 s）。
⭐ 而 Verilator **运行**确实快得多（`tb_top_m0` 9.8 s → 0.4 s，**25×**）；
⇒ ⭐ **两者的交点约为「vvp 运行 ≈ 10 s」**。

📌 项目自报的重 tb 清单（`sim/tb_all.ps1:183-194`）：`tb_top_sound` ~93 s ·
`tb_e2e_key_to_sound` ~50 s · `tb_span_realistic` ~90 s · `tb_span_multiaxis_noise` ~115 s
⇒ ⭐ **只有这 4~10 个重 tb 有真实加速空间**（预期 5~10×）。

---

## 七、⭐ 二级阻断因子（静态扫描，L1+L2 池 93 个）

| 因子 | 命中文件数 | Verilator 处置 |
|---|---|---|
| `#delay`（`#\d`） | **93 / 93** | 🔴 **必须 `--timing`** —— ⛔ 否则**所有延时被忽略**、激励时序全塌 |
| `$dumpvars`/`$dumpfile` | 39 | ⚠️ 需 `--trace`；不加则打印 `$dumpvar ignored`（⛔ 无害但会刷屏） |
| `force`/`release` | 19 | ⚠️ 支持有限 |
| `real` / `$realtime` | 18 | ⚠️ 需确认语义一致 |
| `wait(...)` | 11 | ⚠️ 支持有限 |
| `fork` | 3 | ⚠️ 支持有限 |
| `$readmem` | 1 | ✅ 支持 |

🔴 **`--timing` 是硬前提**，而它**本身就会改变时间语义** ⇒ ⭐ 必须靠**双跑**验证，⛔ 不能假定等价。

---

## 八、⭐⭐ 结论与建议

### 分档

| 档 | 范围 | 建议 |
|---|---|---|
| 🔴 **不要迁** | **L3 的 17 个**（判据建立在 X/Z 上） | ⭐ `tb_pool_by_src` 这类**故意造 X 当传感器**的 tb，迁过去**判据直接失效** |
| ⚠️ **暂不迁** | **L2 的 17 个** | ⭐ A8 会静默清零；除非接受"这 17 个 tb 不再查 X/Z" |
| ⭐ **可做差分** | **全部 110 个** | ⭐ **一次性差分战役**：Verilator 侧各编译+运行一次，与 iverilog 比对判定 ⇒ 得到**实测**可迁清单 |
| ⚡ **可加速** | ⭐ **重 tb（vvp > 10 s）** | ⭐ `tb_top_sound` / `tb_span_multiaxis_noise` / `tb_span_realistic` / `tb_e2e_key_to_sound` 等，预期 5~10× |

### ⭐ 建议动作（按性价比）

1. ⭐⭐ **保留 iverilog 作为【唯一发布门】** —— ⛔ **绝不用 Verilator 出验收证据**：
   它**看不见 X**，而本项目已证明 **X 是承重的**（§三）。⭐ 一旦换门，`tb_adsr` 这类
   "靠 X 通过"的 tb 会**变成红的**（还看得见），⛔ 更危险的是反过来 —— **绿了但没验**（§四）。
2. ⭐⭐ **做一次「双跑对判据」差分战役**（⛔ 不要靠静态名单）：
   - 成本：110 tb × ~10 s 编译 ≈ **18 min**（可并行压到 ~3 min）
   - 产出：**实测**的「一致 / 分歧」表 ⇒ ⭐ **那才是真正的可迁清单**
   - ⚠️ **不能在变异测试期间跑**（会抢 CPU 且结论基于变异态 `rtl/`）
3. ⭐ **把重 tb 的加速作为第二个独立目标**：只对 `vvp > 10 s` 的 tb 上 Verilator，
   且**逐 tb 双跑通过后**才启用。
4. 🔴 **顺手补一个独立缺陷**（本轮新发现，⛔ 不在原计划里）：
   `tb/w3b/tb_adsr.sv` 的**通过依赖 X 语义**（`timbre_i` 未连接）⇒ 它是**脆弱判据**。
   ⭐ 建议在 BATCH 6.2 一并修：给 `tb_adsr` 显式接上 `.timbre_i(2'd0)`，
   ⭐ **并把期望值改成 BASS 配方（448）**，让它的通过**不再依赖 X**。

---

## 九、⭐ 我不确定的 / 本轮没做的

| ⭐ | 事项 |
|---|---|
| **1** | ⚠️ **其余 104 个 tb 我【没有实跑】** —— ⚠️ 只跑了 6 个探针。⇒ 「L1 里还有多少个像 `tb_adsr` 那样隐式依赖 X」**本轮答不了**，必须靠 §八·2 的差分战役 |
| **2** | ⚠️ **Verilator 在变异测试上的可用性未评估** —— 直觉上**不适合**（每个变异体都要重编译 110 个 Verilator 模型 ≈ 18 min），⛔ 但**我没有实测**，不敢下结论 |
| **3** | ⚠️ **`--timing` 的语义等价性没有独立验证** —— 我只知道它让 6 个探针跑出了与 iverilog 一致/不一致的结果，**没有证明**它在所有 tb 上等价 |
| **4** | ⚠️ **探针运行在变异态 `rtl/` 下** —— 已核对 `adsr.v` **不在变异目录表**（`note_manager.v` 才在），且 6 个探针的层次都不含 `note_manager` ⇒ ⭐ 结论有效 ✅。但若**将来**要跑含 `top`/`note_manager` 的差分，**必须等变异测试结束** |
| **5** | ⚠️ **「228」的原始口径我没找到** —— 只证了它复现不出来（§一）。⛔ 若原意是别的口径，请以那份口径为准，⭐ 但**请先给出可复现的算式** |
| **6** | ⚠️ 探针用的是 `-j 2`/`-j 4` —— ⭐ **高并行（`-j 8`）可能显著缩短编译**，本轮未做参数扫描 |

---

## 十、⭐ 一句话总结

> ⭐ Verilator **能跑**，但**它的价值不是"更快"**（小 tb 反而慢 40~60×，只有重 tb 快 1.8~10×）；
> ⭐ 它的价值是**第二模拟器**：本轮靠它抓到 **`tb_adsr` 的隐式 X 依赖**（X 落到 `default:` 才通过）——
> ⭐ 而那正是**文本扫描查不出**、⭐ 也正是**把它当发布门就看不见**的那类问题。
> ⇒ ⭐ **iverilog 继续当门；Verilator 当差分检查器；先跑一次双跑战役再谈"可迁清单"** ✅
