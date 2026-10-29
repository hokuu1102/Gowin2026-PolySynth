# 下一轮降 CLS —— 任务规格与靶子（2026-10-04）

## 为什么继续降 CLS

本工程已用**实测**证明：**降 CLS 是提升时序余量的唯一有效方向**（codex 评审判断 + 我 6 次实验验证）。
关键经验：**降幅要够大** —— 小改（CLS −110~−683）会被布局抖动吃掉；
阶段 2 的 Logic −4397 / CLS −1161 / Register −552 才压过抖动（Fmax 52.219 → 53.652），
再把余量预算收紧到 18.181 ns 后进一步到 **56.399 MHz**。

## 当前基线（正式版 `TEST_MODE_EN=0`，**已上板验证** ✅）

| 项 | 值 |
|---|---|
| `clk_sys` | **56.399 MHz** / setup 0 / hold 0 |
| 55 MHz 预算 slack | +0.450 ns |
| Logic / Register / **CLS** | 46283 / 15148 / **25725（86%）** |

## 综合层级资源（最大块）

| 模块 | Register | ALU | LUT | 备注 |
|---|---|---|---|---|
| `g_sound.u_note_manager` | 3281 | 885 | **11208** | ⭐ 最大头 |
| `g_sound.u_envelope_bank` | 608 | **4960** | 5401 | 32×ADSR（每声部 ~139 ALU） |
| `g_sound.u_oscillator_bank` | 4778 | 5318 | 5376 | 阶段 2 已共享扫频 |

## 当前最差路径（正式版报告）

1. `u_note_manager/gate_r_24_s0/Q → u_note_manager/scan_cnt_3_s0/CE`（+0.450）
2. `u_note_manager/retrig_low_26_s1/Q → u_note_manager/best_idx_0_s0/CE`（+0.461）
3. （诊断版另有）`u_tdm_render_mixer/cnt_4_s0/Q → prod_c_0_s/D[12]`（+0.065）

⇒ 三个候选靶子：**`note_manager` 的 LUT 与抢声部锥**、**`envelope_bank` 的 ALU**、
**mixer 的 `cnt → prod_c` 操作数路径**（= codex 评审里的"阶段 3"）。

## 已准备的实施任务

`codex-task-spec.json`（本目录）是**完整的实施任务规格**，已按 DSH→Codex 调度规则
（difficulty = hard）写好，内容包括：必读材料、当前状态、三个靶子的具体落点、
硬约束（⛔ 不改 SDC/CST/门槛/声部数、不删断言、不动 TEST_MODE_EN 机制）、
等价性验证要求（差分 + 红检）、综合资源验收要求、交付物清单。

⚠️ **派发受阻**：本机 xats dispatcher 在 2026-10-04 15:20 前后死亡，重启后未接单
（`dispatcher = 0/2` 反复、任务目录未生成）。⇒ 需要先修复 xats 基础设施，
或由 DSH 侧**直接按本规格实施**。

## 建议的实施顺序

1. **`note_manager` 的 LUT 11208**：先做只读分析找出重复的 per-voice 数组/比较/mux 树，
   给出量化目标；⚠️ 同时注意它正是当前最差路径所在模块。
2. **`envelope_bank` 的 ALU 4960**：codex 上轮给过"139 ALU/声部 → ≤80"的目标；
   当时只做了 decay/release 共减法器且**因 CLS 反增而回退**（存档
   `evidence/h5/cand3-adsr-share-50p035/adsr-shared.v`），**必须重新评估**（上次只降 Logic 没降 CLS）。
3. **mixer 操作数流水**（codex 阶段 3）：切断 `cnt → prod_c`；
   ⚠️ 注意 `tb_tdm_render_mixer.sv:246` 的 `[POLY+3, POLY+8]` 延迟契约。

⛔ 每一步都必须：先等价验证（含红检）→ 再综合筛资源 → 才花 PnR 预算。

---

# cls-reduction-next-20261004

本轮只运行 Icarus 仿真和 `gw_sh` 的 `run syn`。不运行 PnR，不改约束、器件、精度、声部数、TEST_MODE_EN 机制或 build_cli.tcl，不 commit/push，不发送外部消息。

## 基线与诊断

开始时分支 converge-merge，HEAD `5396a10`，工作区干净。已重新阅读外部上一轮评审、阶段 2 DESIGN 和双码流 README；用户本轮提供的正式版上板通过状态优先于旧 README 的“未上板”记录。

实际读取 `impl/gwsynthesis/Gowin2026_syn_rsc.xml`：

| 层级 | Register | ALU | LUT | BSRAM |
|---|---:|---:|---:|---:|
| top 总计 | 15148 | 12142 | 33167 | 29 |
| note_manager | 3281 | 885 | 10787 | 2 |
| envelope_bank | 608 | 4960 | 5622 | 0 |
| oscillator_bank（含子模块） | 4268 | 4870 | 4534 | 10 |
| tdm_render_mixer | 181 | 281 | 1672 | 0 |

这些是综合口径，不能与 PnR 的 Logic 46283、ALU 13121、LUT 33162、Register 15148、BSRAM 31、CLS 25725 混算。特别是本轮 ADSR 已是 **155 ALU/voice**，不是旧评审的 139；oscillator 的共享已经存在。报告快照保存在本目录 `baseline-*`。

已核对 `evidence/h5/margin-18p181-56p399/Gowin2026_tr_content.html:241` 的 gate_r_24→scan_cnt_3/CE +0.450 ns，以及 :253 的 retrig_low_26→best_idx_0/CE +0.461 ns。

### 机会按本轮性价比排序

1. **note_manager 分配／重触发共用写数据通路（实施）**。原文件 :1160–1197、:1281–1309，当前共享选择 :795 起、写入 :1319 起。原有 ST_RETRIG 和 ST_COMMIT2 分别写 src/phase/vel/timbre/age/vtgt_rep；两个状态互斥，但每个目的声部都可能保留独立数据 mux。把 payload 的选择前移到全局公共通路，每声部只保留写使能和本地其它更新优先级。改前模块为 10787 LUT/885 ALU/3281 FF；结构估算可减少约 **700–1600 LUT**，无新增 FF，不承诺 CLS 数字。失败判据：任何逐沿差分或回归失败；同配置综合 Logic/LUT 不降；PnR 后 CLS 不降或时序不能通过（后者由 DSH 验）。保留所有数组，完全不碰扫描候选、same_hit、池划分和 best 比较，所以不是直接切断当前最差路径；目标是减少同一大模块的布局压力。
2. **ADSR 合并目标比较及饱和加减（未实施）**。`rtl/w3b/adsr.v:158–214` 的 release、attack、decay、sustain 有多组加减与比较。当前 4960 ALU/5622 LUT/608 FF；若达 ≤80 ALU/voice，理论少 **至少 2400 ALU**，但可能新增约数百至千级 mux LUT，净收益未知。不能重复引用 `evidence/h5/cand3-adsr-share-50p035/adsr-shared.v` 的共用 decay/release 减法器就声称达标；该版本未消除宽比较器，且历史 CLS 已反增。安全路线须保持 :134–136 的前一系统拍 sustain 乘积、tick 更新时刻、retrigger/release 优先级及所有位宽溢出规则；需要四音色、全部电平及边界参数的实际 RTL 差分。失败判据：任一边界反例，或 LUT 抵消 ALU 减量，立即回退。TDM ADSR 会延迟 note_manager 的反馈，本轮不采用。
3. **mixer 操作数流水（未实施）**。`rtl/w3b/tdm_render_mixer.v:210–280、304–332、857–863`，模块 181 FF/281 ALU/1672 LUT。预计增加约 34 个操作数 FF及 valid/control，**预期 CLS 削减为零**，因此不优先用于本任务。它可切 cnt→prod_c，但须把累加有效区间 1…POLY 改为 2…POLY+1，排空加一拍；当前 valid_d 已五级，不能再次无依据延长。`tb/w3b/tb_tdm_render_mixer.sv:246` 的 [POLY+3,POLY+8] 契约需要另行明确修改，不能只放宽超时。必须证实首尾声部、符号/满幅、reset 中断和 I2S 下一帧装载 deadline；差分/延迟或全局时序失败则放弃。

note_manager 的扫描已经有寄存 one-hot 和八声部分组（原 :686–723），FIFO 已映射 2 BSRAM；这些不再按“首次去 mux/首次 RAM 化”重复估算收益。力度斜坡也虽有两套分支，却有既往小减量被布局抖动抵消的记录，未与本项混做。

## 等价性

对每个声部 i，旧版公共字段的下一状态依序是：复位；一般更新（age、力度 ramp、pitch、回放 target）；若 ST_RETRIG 且 same_en 且 same_idx=i，则写当前事件；若 ST_COMMIT2 且 cmt_en 且 cmt_idx=i，则写提交寄存器。两个状态不可能同时成立。新版先选择同一组 payload，在 case 之后用同一条件写 i，因此 NBA 的优先级和时钟沿完全相同。未新增状态，也没有改读数快照。

- gate、axis、retrig_low、retrig_reset、alloc、vtgt_vld 仍保留原位置和条件。
- 非目标声部继续接受自己的更新；全局 payload 不会覆盖其它 voice 的 pitch/ramp。
- 在 reset 后，scan/same/cmt 索引及 FSM 都是确定值，归纳保持；对非法或未知内部状态不声称形式等价。
- 新 TB 实例化真实 `note_manager` 和冻结旧版 `note_manager_reference`。参考仅改模块名，来自本轮改动前源码，未从新实现反推模型。
- 每个系统上升沿后 #1 比较全部 14 个输出及 FSM、扫描/最佳声部、FIFO 指针/计数、门/来源/音高/力度/音色/年龄/目标数组。覆盖真实 32 声部、4 声部、非 2 幂 7 声部和 T3 开启，所有声部写入都必须命中。
- 定向制造事件写入与 sample_tick/pitch/velocity 同拍碰撞；随机注入 FIFO 满、off/on/pluck、五种来源、音色、包络反馈、base/transpose 和运行中 reset。
- 三个真实 RTL 变异体分别破坏分配 phase、重触发 velocity、pitch 写优先级；必须编译成功，并以明确的 DIFF + 非零退出被检出，超时不算红检成功。

## 测试与综合结果

结果以 `tests-diff/results.json`、`tests-regression/results.json` 及其原始日志为准。最终统计与综合表将在验收结束后补齐。

复现命令（仓库根目录）：

```powershell
python evidence/h5/cls-next-20261004/run_tests.py diff
python evidence/h5/cls-next-20261004/run_tests.py regression
python evidence/h5/cls-next-20261004/run_synth.py fresh-before --baseline
python evidence/h5/cls-next-20261004/run_synth.py fresh-after
```

`run_synth.py` 要求新的目录名，复制 rtl/ip/constr 和工程文件，仅执行 `run syn`。主工程 impl 完全不改；set_option 只留在各自独立副本。**不要拿实验目录的 impl 回填主工程**。DSH 后续按双码流纪律用全新工程/impl 和原始 build_cli.tcl 默认选项构建。

## 未验证项

最终 CLS、PnR Fmax/setup/hold/recovery/removal、诊断码流物理验收和上板均不在本轮综合结果内。综合 Logic 降低不保证 CLS 或 Fmax 改善；当前最差扫描锥、诊断 mixer 锥仍存在。DSH 构建建议将在综合验收结束后给出。
