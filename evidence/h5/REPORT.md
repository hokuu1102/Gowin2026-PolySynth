# H5 波形显示实施与验收

任务：`hdmi-h5-scope-20261001b`。日期：2026-10-01。

仓库：`C:\Users\cyx\Documents\ChatGPT\FPGA\Gowin2026-PolySynth-t31b-main`。

## 实现

- `rtl/top.v` 仅增加 HDMI 端口、显示实例和 `master_mix` 输出的被动旁接，
  未删除/重命名原端口，未修改既有音频逻辑。静音配置向显示器提供零样本。
- `rtl/hdmi/waveform_scope.v`：24 位有符号输入、1024 深度环形历史；
  消隐开始时复制最近 640 点，换算为 `clamp(240 - (sample >>> 14), 0, 479)`。
  每列绘制与前一点之间的竖线，第一列不连接上一行的末列；亮绿波形、暗灰基线、黑底。
- 使用独立帧 RAM，避免扫描期间历史被新样本覆盖造成撕裂。
  合成实际推断 2 个 BSRAM。复制约 25.7 µs，远小于 384 点的约 7.86 ms 覆盖余量。
- Gray 写指针及已初始化标志先在系统时钟下降沿寄存，再进入 pixel 域两级同步器。
  与 pixel 上升沿形成约 10 ns 的标称间隔；没有增加 false path 或关闭跨域检查。
  这是首轮 11 条 hold 违例后的修复，未改动音频信号本身。
- 窗口为 13.1072 ms；沿用 25/125 MHz、800×525 总时序，实际刷新 59.5238 Hz。
  未采用可选的零交叉触发：优先显示最新的静音、瞬态和演奏样本，周期波相位可能移动。
  历史首次填满及首帧快照完成前仅画基线。
- `video_timing`、`tmds_encoder`、`tmds_serializer`、`hdmi_clk` 原样迁至 `rtl/hdmi/`；
  主工程、默认 bringup 工程和 H4 工程均引用共享源文件。默认参数未变。
- CST 只追加 D0 J14/H14、D1 J15/H15、D2 K17/J17、时钟 G15/G16、HPD K13。
  沿用 `TLVDS_OBUF`、配对引脚和 `BANK_VCCIO=3.3`；V13 未变。
- SDC 只追加 HDMI 两个生成时钟，分别为 20/8、20/40。
- 主工程原先 `pn` 文字为 C1、内部编号却为 `gw5at60b-003`，实际产出 C2 报告。
  已改为与验证过的 bringup 一致的 `gw5at60b-002`，最终必须以新报告中的 C1 为准。

源码审计：[source-audit.txt](source-audit.txt)。显示接口/时序说明：
[rtl/hdmi/README.md](../../rtl/hdmi/README.md)。

## E1：完整回归

<!-- E1 BEGIN -->
最终完整回归仍在运行。已核实 H5 的 `tb_e2e_key_to_sound` 已 PASS，
基线的 `tb_nm_no_leak` 和 `tb_top_sound` 也已 PASS；尚未取得整批汇总，暂不宣称全绿。
最终日志为 `regression-baseline-final.log` 和 `regression-after-final.log`；
两套脚本已修复跨测试进程误杀，预算与断言不变。
<!-- E1 END -->

原交付基线 `regression-before.log` 原样保留：51,400 字节，SHA-256
`262293c6b8239d074c24d0668cb078ce2c0cdd4cc8c3258c86672726b1b9b0e3`。
它在 `tb_demo_stall_diag` 处截断，没有“通过数/总数”汇总，不能凭该日志推断全绿。
本次以修改前的源码副本 「baseline-src/」（历史引用，当前未收录） 补跑对照，最终回归对两边使用相同的原超时预算。

首轮并行回归发生 H5 的 `tb_e2e_key_to_sound` 600 秒超时，以及基线
`tb_nm_no_leak` 120 秒超时。原脚本超时分支会终止所有 `vvp`，连带中断另一套回归。
这些受影响的运行已停止并保留为 `regression-after.log`、`regression-baseline-complete.log`；
它们不是最终验收通过证据。开发初期仿真模型端口语法错误的原日志也保留在
`regression-after-initial-model-error.log`，错误已修正。

`sim/tb_all.ps1` 的唯一行为修复是按本次仿真镜像的完整参数及进程创建时间清理，
不再终止其他测试；没有修改功能断言、跳过列表或 120/600 秒等原超时预算。

清理缺陷的红绿证据：

```text
before: Terminated simulated PIDs: 101,202,303,404
FAIL: timeout must stop only the current image started by this run
after:  Terminated simulated PIDs: 101
PASS: unrelated, older and prefix-matching simulator processes survive
```

另有真实的超时 fixture：仍退出 1，旁边的独立 `vvp` 存活。
证据：[timeout-scope-before.log](timeout-scope-before.log)、
[timeout-scope-after.log](timeout-scope-after.log)、
[timeout-live-verdict.txt](timeout-live-verdict.txt)、[timeout-live-run.log](timeout-live-run.log)。

## E2：像素仿真与缺陷注入

**通过。** 最终显示 RTL 的独立像素 oracle 检查了 2,308,886 次像素/DE/同步输出。
参考换算用有符号整数除法独立计算，未复制 RTL 的位切片写法。

| 输入 | 绿色像素 | 暗灰像素 | 判定 |
|---|---:|---:|---|
| 静音 | 640 | 0 | PASS |
| 正直流 | 640 | 640 | PASS |
| 正弦 | 7,822 | 613 | PASS |
| 方波 | 10,240 | 608 | PASS |
| 正负满幅交替 | 306,721 | 1 | PASS |
| 负数舍入/锯齿混合 | 20,800 | 547 | PASS |

同时验证初始未写 RAM 不泄漏、历史回卷、扫描期间持续写入、帧内稳定、第一列边界、
消隐 RGB、DE/HS/VS 延迟和复位。

| 版本 | 退出码 | 原测试输出 |
|---|---:|---|
| 正常 | 0 | `PASS: waveform_scope 2308886 pixel checks` |
| 样本取反 | 1 | `FAIL: pixel (0,163) RGB=000000 expected=00ff00` |
| y 原点 240 改 239 | 1 | `FAIL: pixel (0,239) RGB=00ff00 expected=000000` |
| 取消前后点连线 | 1 | `FAIL: pixel (32,41) RGB=000000 expected=00ff00` |

所有变异均编译成功，失败发生于像素断言，生产源码未被变异。
完整输出：[mutations/good.log](mutations/good.log)、
[invert_sample.log](mutations/invert_sample.log)、[wrong_y_origin.log](mutations/wrong_y_origin.log)、
[disconnect_segments.log](mutations/disconnect_segments.log)、[summary.txt](mutations/summary.txt)。

复现：`python tools/h5_scope_mutations.py`。
顶层音频回归采用 `tb/models/hdmi_primitives_model.sv` 的固定模式功能模型；
此模型不是 PLL 模拟行为、抖动或物理串行时序的证据。

## E3：主工程 Gowin 全流程

<!-- E3 BEGIN -->
正确 C1 的默认算法全流程已完成：0 setup / 0 hold，PA1019=0；
系统 Fmax **50.490 MHz**（余量 **0.98%**），pixel Fmax **118.906 MHz**。
**E3 当前未通过**：系统域未达到 51.5 MHz / 3% 的门槛。
报告及码流见 `build-c1-default-margin-fail/`，码流标为 `UNQUALIFIED`。

最差 setup 路径为既有 `g_sound.u_evt_merge/cnt_q_0_s0` 到
`g_sound.u_evt_merge/mem_mem_RAMREG_1_G[48]_s0`，slack 为 0.194 ns。
没有改动该既有 RTL，也没有放宽时钟约束。
正在用全新构建目录及 `place_option=1 / route_option=1` 进行完整重建，
全部 RTL、IP 和约束均与主工程逐字节一致，待新报告判定。
<!-- E3 END -->

首轮失败记录保存在 [build-initial-c2-hold11/](build-initial-c2-hold11/)：
C2，0 setup / 11 hold，系统 Fmax 61.651 MHz，pixel Fmax 143.572 MHz，PA1019=0。
11 条 hold 均属于显示侧 Gray 指针/初始化标志跨域，最差 slack −0.306 ns。
这些数值不能作为 C1 板卡的验收结果，初始码流明确标为 `UNQUALIFIED`。

## E4：默认 bringup 位流复现

**通过。** 迁移共享源文件后的默认构建已成功。对全部 **17,312,519** 字节比较，
恰好 **14** 个字节不同，全部在文件头 `Created Time` 的 `[635,659)` 范围，
时间字段外差异为 **0**。没有跳过整个文件头、CRC 或配置数据。

```text
Bytes: 17312519; differing bytes: 14; outside timestamp: 0
diff offsets: [635,636,637,639,640,641,643,644,646,647,649,650,652,653]
Reference SHA256: ba11b010d97c63579f861b633d8ae2d361e810bdeb97622b6f646ec62d88ea3e
Built SHA256: ff582b73f2e365beb1e8a6d2d3ca7a96fc777177321ac0057070616d6e16b2c2
PASS: every byte outside the permitted header timestamp matches J_TOKENFIX_led.fs
```

仓库副本中没有 `bitstreams/J_TOKENFIX_led.fs`，实际对照读取了指定桌面工作目录下的
`C:\Users\cyx\Desktop\学习\hdmi_640x480\bitstreams\J_TOKENFIX_led.fs`；
其 SHA-256 与原 bringup README 登记的已上板 J 版本一致。

证据：[bringup-byte-compare.log](bringup-byte-compare.log)、[bringup-build.log](bringup-build.log)、
[bringup-timing.html](bringup-timing.html)。新 bringup 报告为 C1，0 setup / 0 hold。
复现工具：`python tools/h5_compare_bringup.py <J_TOKENFIX_led.fs路径>`。

## E5：上板步骤

步骤与记录表见 [BOARD_CHECK.md](BOARD_CHECK.md)。预期为黑底绿色波形随演奏的幅度、音色和
和弦变化，静音回到中心线，原有音频正常，V13 仍约 1 Hz。

**✅ 2026-10-01 上板验证通过（用户现场观察）。** 烧录的码流是合并后基线构建的
`impl/pnr/Gowin2026.fs`（归档为 `L_h5_scope_merged.fs`，19,118,615 B，
SHA-256 `7F346DBE5F18068B4435A0447DDE3184ACD6EBABEA1BFF082FDBEF1632E5B24D`，
器件 C1/I0，setup/hold 0/0），以 SRAM Program 烧入 Tang Console 60K。

现场确认的现象（逐条对上判据）：

1. **黑底 + 亮绿波形**显示正常；
2. **弹奏时波形随演奏变化**（幅度/形状）；
3. **静音时只剩中心基线**；
4. **原有音频正常**（未影响音频链）；
5. **V13 心跳仍约 1 Hz**（50 MHz 时钟 + PLL 锁定）。

⇒ E5 达成：H5 判据"波形随演奏变化"**上板实测通过**。
⚠️ E4 只证明既有默认彩条设计可复现，⛔ 不能代替本条的硬件验证；本条的独立价值就在这里。

## 合并后基线复验（2026-10-01 21:10，DSH 独立执行）

基线：本提交 on `f91cc21`（队友的器件修正 + T2 起始音）。器件与基线都变了，E1/E3/E4 必须重测。

| 验收 | 结果 | 证据 |
|---|---|---|
| **E1 完整回归** | ✅ **通过 112 / 共 112**（含 H5 的 `tb_waveform_scope`），0 FAIL / 0 超时 / 0 编译失败 | `regression-merged.log` |
| **E3 主工程时序** | ❌ 未达门槛：`clk_sys` **50.110 MHz（+0.22%）**；`pixel_clk` 92.578 MHz（+270%）；setup/hold 0/0；PA1019 = 0；器件 C1/I0 | `merged-base-build.log` + `impl/pnr/Gowin2026_tr_content.html` |
| **E4 bringup 码流复现** | ✅ 17,312,519 B，与已上板验证的 J 仅 13 字节不同，且全部落在文件头时间戳区间（区间外 **0** 字节） | `bringup-rerun.log` |

**关于先前那次 600 秒超时**：本次**串行**重跑（不与 Gowin 构建并行）**零超时** ⇒
`tb_e2e_key_to_sound` 的 600 秒超时由 **CPU 争抢**造成，**不是真挂死**；
该测试的 600 秒预算保持不变即可，⛔ 不需要放宽。

**E3 三方对照（同一器件 C1/I0，同一门槛 51.5 MHz / 3%）**：

| 版本 | `clk_sys` Fmax | 余量 |
|---|---|---|
| 队友（**无** H5，有 T2） | 50.137 MHz | +0.27% |
| 本提交前（有 H5，**无** T2） | 50.490 MHz | +0.98% |
| **合并（T2 + H5）** | **50.110 MHz** | **+0.22%** |

⇒ H5 对 `clk_sys` 的影响约 **0.05%（噪声级）**；余量不足是**既有项目条件**
（队友 K-171 已认定，且已注明"T3 加逻辑前必须先解决"）。

**E5 上板：✅ 已通过（2026-10-01，见上文 E5 段）。** 现场确认黑底绿色波形随演奏变化、
静音回中心线、原有音频正常、V13 仍 ~1 Hz；烧录码流为合并后基线的
`L_h5_scope_merged.fs`（SHA-256 `7F346DBE…E5B24D`）。
