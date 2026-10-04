# ⚠️ 阶段 2（鼓扫频共享）在合并甲的分支时被覆盖 —— 需要重新施加

## 发生了什么（2026-10-04 16:50）

甲推送了 `2b29fac`（timing/converge-h5：逻辑优化 ADSR 共享 + P5-② + T3 变调 + 灯带指示层）
与 `97e16bf`（补回被本线删除的 26 个 evidence/h5 文件）。
合并进 `converge-merge` 时（merge commit `25c0681`）：

| 我的改动 | 合并后 | 判定 |
|---|---|---|
| `TEST_MODE_EN` 编译期裁剪（阶段 1） | ✅ 在（值 = 0） | 幸存 |
| margin SDC（18.181 ns，阶段 0） | ✅ 在 | 幸存 |
| ⭐ **阶段 2 扫频 per-voice 共享** | ❌ **不在**（`voice_sweep_q`/`gen_voice_sweep` 均无） | **被覆盖** |

**原因**：甲的 `rtl/w3b/oscillator_bank.v` 改动量是 **+155/−155**，基于**我们阶段 2 之前**的状态，
git 合并时该区域取了他的版本（未报冲突）。

## 丢失的收益（实测过）

| 项 | 阶段 2 前 | 阶段 2 后 |
|---|---|---|
| Logic | 47929 | **46283（−1646）** |
| CLS | 26287 | **25725（−552）** |
| Register | 15660 | **15148（−512）** |
| `clk_sys` | 51.551 | **53.652**（再叠加 18.181 预算后到 56.399） |

## 怎么恢复（下一轮执行）

1. **改动已完整归档**：`evidence/h5/stage2-sweep-share-53p652/oscillator_bank-shared.v`
   （阶段 2 之后、且**尚未叠加甲改动**的版本）。
2. ⚠️ **⛔ 不要直接拷贝覆盖** —— 甲在 `oscillator_bank.v` 里也有自己的改动（+155/−155），
   直接覆盖会**丢掉他的改动**。
3. ✅ **正确做法：重新施加那两处编辑**（本目录 `DESIGN.md` 与提交 `f38c509` 的说明里有完整内容）：
   - 在 `gen_lane` 循环**之前**插入 `gen_voice_sweep` 生成块（per-voice 共享扫频状态与
     分类/装载/衰减算术，用**打包向量** `voice_sweep_q` 索引）；
   - 把 `gen_lane` 内的 `sweep_off` 改为读 `voice_sweep_q[VOICE_IDX*DRUM_SWEEP_W +: DRUM_SWEEP_W]`
     （仍先零扩展到 `PHASE_W` 再左移）；
   - ⛔ 不要嵌套 `generate`；⛔ 衰减要引用本块寄存器而非本块驱动的输出 wire
     （这两个坑 2026-10-03/04 都踩过）。
4. 施加后：跑 `tb_oscillator_bank` / `tb_soft_hard_blend` / `tb_wavetable_bank` / `tb_top_m0` /
   `tb_polyphony_onset_step`（阶段 2 当时这些全绿），再综合筛资源（Register 应回到 ~15148），
   然后才花 PnR 预算。

## 另外：甲这次也做了 ADSR 共享（= codex 的候选 ②）

甲的分支信息里写了「**ADSR 共享** + P5-② + T3 变调 + 灯带指示层」——
这正是 codex 评审里的**候选 ②**（`adsr.v` 合并目标比较与饱和加减）。
⇒ 恢复阶段 2 后，**必须先重新测量**（甲的逻辑优化可能已经把余量又推高一截，也可能带来新的瓶颈），
不要拿旧数字外推。