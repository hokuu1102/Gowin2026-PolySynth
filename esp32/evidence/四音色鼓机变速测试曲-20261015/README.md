# 四音色 + 鼓机 + 变速 + 复音 · house/funk 测试小段子（2026-10-15）

**这是什么**：给「曲谱上位机」（`esp32/tools/score_studio.html`）灌谱用的一小段曲子。
**8 小节、约 17 秒** —— 尽量短，但每一小节都在测东西。

一次把**五件事**都测到：

| # | 测点 | 在曲子里的位置 |
|---|---|---|
| 1 | **四个音色**同时出声（BASS / GUITAR / PIANO / PAD） | 第 4~8 小节 |
| 2 | **鼓机四件**都响（Kick / Snare / HiHat / Tom） | 第 3~6、8 小节 |
| 3 | **变速**（100 → 126 → 108 BPM，三个 tempo 点） | 第 1 / 3 / 7 小节头 |
| 4 | **和弦**（同一时刻多个音，逼上位机把音摊到多条轴） | 第 3 小节起，钢琴每半拍一个三音和弦 |
| 5 | **复音**（能一个一个数出来） | **第 7 小节：每半拍进一个音，最后 10 个音同时响** |

风格：house 律动（反拍踩镲 / 反拍钢琴 stab）+ funk 吉他 riff。

---

## 一、文件清单

| 文件 | 用途 |
|---|---|
| `四音色鼓机变速-house-funk-测试曲.mid` | **交付物**。直接拖进上位机就能灌 |
| `gen_test_piece.py` | 生成上面那份 `.mid`（只用 Python 标准库，改曲子只动 `compose()` 与数据表） |
| `verify_piece.js` | 核对**转换层**（8 项判据）：用网页自己的解析器转一遍 |
| `check_roll.js` | 核对**卷帘显示层**（12 项判据）：真调页面的 `draw()` / `pickHover()` 等 |
| `events.hex` | 网页解析器的产物（435 个字），给 `score_uploader.py` 那条路用 |
| `试听-无鼓-预览.wav` | `tools/evt2wav.py` 渲染的试听（**只有旋律，没有鼓**） |
| `_mid2evt对比/` | `tools/mid2evt.py`（Python 路）的产物，用来对比两条路的差异 |
| `卷帘核对报告-20261015.md` | 卷帘那 6 个缺陷的核对与修复报告 |

> **哪两个文件不在 git 里**：`.mid` 与 `.wav` 都是**生成物**。
> `esp32/.gitignore:32` 的 `*.mid` 规则就是为「evt2midi 的产物不入库」写的
> （二进制进 git 后无法回收），本曲的 `.mid` 同属生成物，故**不强制入库**。
> clone 之后跑一次 `python -X utf8 gen_test_piece.py` 即可重建 `.mid`。

---

## 二、编曲（一小节一个和弦：Am7 Dm7 Fmaj7 E7 Am7 Dm7 Fmaj7 Am7）

| 小节 | 速度 | Pad | Bass | Piano | Guitar | 鼓 |
|---|---|---|---|---|---|---|
| 1 | 100 | ✓ | - | - | - | kick + hat |
| 2 | 100 | ✓ | ✓ | - | - | kick + hat |
| 3 | 126 | ✓ | ✓ | ✓ | - | 全鼓（提速 drop） |
| 4 | 126 | ✓ | ✓ | ✓ | ✓ | 全鼓 |
| 5 | 126 | ✓ | ✓ | ✓ | ✓ | 全鼓 |
| 6 | 126 | ✓ | ✓ | ✓ | ✓ | 全鼓 + tom 过门 |
| **7** | 108 | └── **复音阶梯：每半拍进一个音** ──┘ | | | | kick + hat |
| 8 | 108 | ✓ | ✓ | ✓ | ✓ | 收尾 + 鼓探针 |

音区分工（避免糊在一起）：bass 87~175 Hz · pad 220~392 Hz · piano 262~440 Hz · guitar 330~700 Hz。

### 复音阶梯（第 7 小节）——怎么数

每半拍（480 tick）进一个音，**全部撑到小节末**，所以最后 10 个音**同时响**：

| 进来的时刻 | 轨 | 音 | 累计同时在响 |
|---|---|---|---|
| 拍 1 | Pad | A3 C4 F4（三音一起） | 3 |
| 拍 1 | Bass | F2 | 4 |
| 拍 1.5 | Piano | E4 | 5 |
| 拍 2 | Piano | A4 | 6 |
| 拍 2.5 | Guitar | C5 | 7 |
| 拍 3 | Guitar | E5 | 8 |
| 拍 3.5 | Bass | F3 | 9 |
| 拍 4 | Piano | F5 | **10** |

- 十个音**音高互不重复** ⇒ 不会因同音高相位干涉而听糊，可以一个一个数。
- 10 声 < 可用轴 15 条 ⇒ 不抢轴；也远低于 FPGA 的 32 voice 上限。
- 想单独验复音：**只听第 7 小节**，从 1 数到 10。

---

## 三、离线核对结果（已跑，全过）

```powershell
cd C:\Users\hokuu\Desktop\FPGA\FPGA2026-esp32\esp32\evidence\四音色鼓机变速测试曲-20261015
python -X utf8 gen_test_piece.py                 # 生成 .mid
node verify_piece.js --hex events.hex            # 转换层 8 项
node check_roll.js                               # 卷帘显示层 12 项
```

| 项 | 实测 |
|---|---|
| 轨 | 6 条（1 条只有 tempo + 5 条有音符） |
| 事件 | **435 个字**（on 216 · off 216 · tempo 3） |
| 时长 | tick 最大 30720 = **16.86 秒**（按变速分段积分） |
| 变速 | tick 0 → 100 BPM · tick 7680 → 126 BPM · tick 23040 → 108 BPM |
| 音色 | axis0=BASS · 1=GUITAR · 2=PIANO · 3=PAD（两条转换路结果一致） |
| 鼓 | 全在 axis 15；kick 20 · snare 9 · hihat 30 · tom 6；**兜底 0 个** |
| **复音** | **旋律峰值并发 = 10**（第 7 小节末）；用到轴 0~9，**未用 axis 14** |
| 重击 | 7 处同 tick 同音高（`off` 均排在 `on` 前，反向 0 处） |
| 组包 | 435×9 = 3915 B + 总数帧 9 B + 复位序列 36 B = **3960 B / 440 帧** |

**独立复核**：`python esp32/tools/evt2midi/midi_verify.py --in <文件>`
按 MIDI 规范读回 —— format 1 · 6 轨 · PPQN 960，通过。

**试听（不含鼓）**：

```powershell
python tools\evt2wav.py "esp32\evidence\四音色鼓机变速测试曲-20261015\_mid2evt对比\events.hex" "试听.wav"
```

`evt2wav.py` 自己不渲染鼓（它按 `inc` 当乐音），所以预览用的是**没有鼓的那份 hex**。
用途：上板前先听一遍**旋律 / 变速 / 复音**对不对，上板后再和板子的声音对比。

---

## 四、怎么用

### A. 网页上位机（推荐，**鼓能出声**）

1. 双击 `esp32/tools/start_score_studio.bat`
2. 开 `http://127.0.0.1:8777/score_studio.html`，**`Ctrl+F5` 强刷**
   （卷帘有 6 处修复，不刷会看到旧行为）
3. 点**连接蓝牙** → 选 `FPGA2026-Synth*`
4. 把 `四音色鼓机变速-house-funk-测试曲.mid` **拖进去**，看日志：
   - `MIDI 解析成功：435 个事件 · BPM 100.0 · 960 PPQN`
   - `该谱子有 3 个 tempo 点（变速）—— 已全部转成 kind=2 事件`
   - 轨分配 5 行：Bass→BASS / Guitar→GUITAR / Piano→PIANO / Pad→PAD / Drum→鼓
   - 左下角图例应是 **5 种颜色**（四个音色 + 鼓）
   - 底部总览条应显示 **全长 17s**（⛔ 不是 32s —— 那是修复前的 120BPM 假定）
5. 点**一键上传** → 进度条走到 `3960 B / 440 帧`
6. 点**起播** → 听（判据见下）

### B. Python 路（`score_uploader.py`）—— **注意：鼓会被丢掉**

```powershell
python esp32\tools\score_uploader.py --autotest "esp32\evidence\四音色鼓机变速测试曲-20261015\events.hex"
```

`events.hex` 是**用网页解析器**导出的（含鼓），可以喂给这条路。
但若改用 `tools/mid2evt.py` 自己转，**鼓会被整条丢掉**（实测 `drums_excluded=130`）——
那是 `mid2evt.py` 的已知局限，不是这份曲子的问题。

---

## 五、已知问题的探针（结果要按这个读）

### 1. 鼓同时敲（第 8 小节第 4 拍）

主 groove 里 kick / snare / hat 的落点**互不相同**，不与那个已知问题撞车；
只有**第 8 小节第 4 拍**故意让 `kick + snare + hihat` 同 tick 一起敲。

- 该处听到**三件都响** ⇒ 问题已修
- 只听到**一件** ⇒ 就是 `same_hit` 复用那条未解决项
  （`files/20-代码/ESP32侧追问-同时敲多个鼓与same_hit-20261014.md`）

> ⚠️ 这也是为什么底鼓不是"四踩"：底鼓踩满四拍时，snare 落 2/4 拍**必然**与底鼓同 tick。

### 2. 两条转换路的差异（实测）

| 路 | 四音色 | 变速 | 复音 | 鼓 |
|---|---|---|---|---|
| 网页 `score_studio.html`（本曲判据） | 4 个都对 | 3 个 tempo 点 | 峰值 10 | **有**（axis 15） |
| `tools/mid2evt.py`（Python） | 4 个都对 | 3 个 tempo 点 | 峰值 10 | **整条丢掉**（`drums_excluded=130`） |

⇒ **要测鼓就必须走网页那条**。

---

## 六、上板实测记录（跑完填这里，见 AGENTS.md 0.17）

| 项 | 预期 | 实测 |
|---|---|---|
| 上传进度 | 3960 B / 440 帧，不卡死 | |
| 起播后前 0.6 秒 | 屏/日志开始动 | |
| 四个音色 | 都听得出，音色互不相同 | |
| 鼓四件 | Kick/Snare/HiHat/Tom 都有 | |
| 变速 | 100 → 明显变快 → 明显变慢 | |
| 和弦 | 钢琴 stab 是**三音同响**，不是一个音 | |
| **复音** | **第 7 小节能从 1 数到 10 个音** | |
| 第 8 小节第 4 拍 | 三件鼓都响 / 只响一件 | |
| 重击（同 tick 同音高 7 处） | 不吞音、不挂音 | |

---

## 七、想改这段曲子

改 `gen_test_piece.py` 顶部的数据表（`CH` / `PROG` / `TEMPO_PLAN` / `BASS_HITS` /
`PIANO_HITS` / `GTR_POS` / `DRUM_BARS` / `LADDER`），然后：

```powershell
python -X utf8 gen_test_piece.py && node verify_piece.js --hex events.hex && node check_roll.js
```

**改完必须重跑这两个核对** —— 它们判的是"上位机会把它转成/画成什么"，
⛔ 不是"我打算写什么"。轨名决定音色（`bass`/`guitar`/`piano`/`pad` 关键词），
改轨名会改音色；鼓轨靠轨名含 `drum` 或走 MIDI 通道 10 识别。

⚠️ **复音上限**：可用轴是 `0..14`（15 条，15 是鼓轴），所以同时发声的音**别超过 15 个**；
`check_roll.js` 与 `verify_piece.js` 都会报峰值并发。
