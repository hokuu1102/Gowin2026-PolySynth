# 四音色 + 鼓机 + 变速 · 测试小段子（2026-10-15）

**这是什么**：给「曲谱上位机」（`esp32/tools/score_studio.html`）灌谱用的一小段曲子。
12 小节、约 28.5 秒，**一次把四件事都测到**：

1. **四个音色同时出声** —— BASS / GUITAR / PIANO / PAD
2. **鼓机四件都响** —— Kick / Snare / HiHat / Tom
3. **变速** —— 100 → 140 → 80 BPM（三个 tempo 点）
4. **和弦** —— 同一时刻多个音，逼上位机把音摊到多条轴

---

## 一、文件清单

| 文件 | 用途 |
|---|---|
| `四音色鼓机变速-测试曲.mid` | **交付物**。直接拖进上位机就能灌 |
| `gen_test_piece.py` | 生成上面那份 `.mid`（只用 Python 标准库，可改谱重生成） |
| `verify_piece.js` | **用网页自己的解析器**核对，并导出 `events.hex` |
| `events.hex` | 网页解析器的产物（479 个字），给 `score_uploader.py` 那条路用 |
| `试听-无鼓-预览.wav` | 用 `tools/evt2wav.py` 渲染的试听（**只有旋律，没有鼓**，见下） |
| `_mid2evt对比/` | `tools/mid2evt.py`（Python 路）的产物，用来对比两条路的差异 |

> **哪两个文件不在 git 里**：`.mid` 与 `.wav` 都是**生成物**。
> `esp32/.gitignore:32` 的 `*.mid` 规则就是为「evt2midi 的产物不入库」写的
> （二进制进 git 后无法回收），本曲的 `.mid` 同属生成物，故**不强制入库**。
> clone 之后跑一次 `python -X utf8 gen_test_piece.py` 即可重建 `.mid`；
> `.wav` 按第三节的命令重建。

---

## 二、这段曲子测什么、在哪一段

| # | 测点 | 位置 | 预期 |
|---|---|---|---|
| 1 | 四音色并发 | 第 5~8 小节四条轨同时进行 | 四个音色都听得出，不是只有一种 |
| 2 | 鼓机四件 | 第 5~12 小节 | Kick/Snare/HiHat/Tom 四件都有声音 |
| 3 | 变速 | tick 0 / 15360 / 30720 | 明显变快再明显变慢，**不是全程一个速度** |
| 4 | 和弦 | 第 1~12 小节每小节的 Pad 都是 4 个音同起 | 四个音**同时**响（不是只响一个） |
| 5 | 同音高重击 | tick 42240（第 11→12 小节交界） | 上一个 A4 正常收掉、新 A4 正常起（不吞音） |
| 6 | 鼓同 tick 多件 | 第 12 小节第 1 拍 | **已知问题探针**，见第五节 |

### 曲式（A 小调，4/4，PPQN 960）

| 小节 | 速度 | 内容 |
|---|---|---|
| 1~4 | 100 BPM | Pad 长和弦 + Bass 半音符；第 3 小节 Piano 进 |
| 5~8 | 140 BPM | 四音色 + 鼓机全上；第 8 小节有 tom 过门 |
| 9~12 | 80 BPM | 慢下来收尾；第 12 小节全奏 + 鼓探针 |

和弦进行：Am – F – C – G（第 12 小节回到 Am）。

---

## 三、离线核对结果（已跑，8 项全过）

```powershell
cd C:\Users\hokuu\Desktop\FPGA\FPGA2026-esp32\esp32\evidence\四音色鼓机变速测试曲-20261015
python -X utf8 gen_test_piece.py                       # 生成 .mid
node verify_piece.js --hex events.hex                  # 用网页解析器核对
```

| 项 | 实测 |
|---|---|
| 轨 | 6 条（1 条只有 tempo + 5 条有音符） |
| 音符轨 | Bass 112 · Guitar 96 · Piano 62 · Pad 96 · Drum 110（on+off 各半） |
| 音色分配 | axis0=BASS · axis1=GUITAR · axis2=PIANO · axis3=PAD（两条路**结果一致**） |
| 鼓 | 全在 axis 15；kick 15 · snare 15 · hihat 22 · tom 3；**兜底 0 个** |
| 变速 | 3 个 tempo 点 → 3 个 `kind=2` 事件（tick_inc 137439 / 192415 / 109951） |
| 事件 | 479 个字（on 238 · off 238 · tempo 3） |
| 时长 | tick 最大 46079 ≈ **28.5 秒**（按变速分段算） |
| 组包 | 479×9 = 4311 B + 总数帧 9 B + 复位序列 36 B = **4356 B / 484 帧** |
| 并发 | 旋律峰值 8；用到轴 0~7（**没用到 axis 14**） |
| 重击 | tick 42240 一处，`off` 排在 `on` 前（反向 0 处） |

判据（`verify_piece.js` 会自己判，不符合打 RED）：
① 四个音色齐全 ② 三个 tempo 点全转 ③ 鼓全在 axis 15 且四件齐
④ 峰值并发 ≤ 15 ⑤ 没用到 axis 14 ⑥ 重击顺序对 ⑦ 鼓同 tick 多件 = 1 处 ⑧ 鼓没走兜底

**独立复核**：`python esp32/tools/evt2midi/midi_verify.py --in <文件>`
按 MIDI 规范读回 —— format 1 · 6 轨 · PPQN 960 · 音符 476 · tempo 100 BPM，通过。

**试听（不含鼓）**：

```powershell
python tools\evt2wav.py "esp32\evidence\四音色鼓机变速测试曲-20261015\_mid2evt对比\events.hex" "试听.wav"
```

`evt2wav.py` 自己不渲染鼓（它按 `inc` 当乐音），所以预览用的是**没有鼓的那份 hex**。
实测：48828 Hz · 29.7 s · 峰值 18837 · RMS 3027（有声音、不削顶）。
用途：上板前先听一遍**旋律与变速对不对**，上板后再和板子的声音对比。

---

## 四、怎么用

### A. 网页上位机（推荐，**鼓能出声**）

1. 双击 `esp32/tools/start_score_studio.bat`
2. 开 `http://127.0.0.1:8777/score_studio.html`，`Ctrl+F5` 强刷
3. 点**连接蓝牙** → 选 `FPGA2026-Synth*`
4. 把 `四音色鼓机变速-测试曲.mid` **拖进去**，看日志：
   - `MIDI 解析成功：479 个事件 · BPM 100.0 · 960 PPQN`
   - `该谱子有 3 个 tempo 点（变速）—— 已全部转成 kind=2 事件`
   - 轨分配 5 行：Bass→BASS / Guitar→GUITAR / Piano→PIANO / Pad→PAD / Drum→鼓
   - 左下角图例应是 **5 种颜色**（四个音色 + 鼓）
5. 点**一键上传** → 进度条走到 `4356 B / 484 帧`
6. 点**起播** → 听（判据见下）

### B. Python 路（`score_uploader.py`）—— **注意：鼓会被丢掉**

```powershell
python esp32\tools\score_uploader.py --autotest "esp32\evidence\四音色鼓机变速测试曲-20261015\events.hex"
```

`events.hex` 是**用网页解析器**导出的（含鼓），可以喂给这条路。
但若改用 `tools/mid2evt.py` 自己转，**鼓会被整条丢掉**（见下）——那是
`mid2evt.py` 的已知局限，不是这份曲子的问题。

---

## 五、已知问题的探针（结果要按这个读）

### 1. 鼓同时敲（第 12 小节第 1 拍）

主 groove 里 HiHat **只打反拍**，不与 Kick/Snare 撞 tick。
只有**第 12 小节第 1 拍**故意让 `kick + snare + hihat` 同 tick 一起敲。

- 该处听到**三件都响** ⇒ 问题已修
- 只听到**一件** ⇒ 就是 `same_hit` 复用那条未解决项
  （`files/20-代码/ESP32侧追问-同时敲多个鼓与same_hit-20261014.md`）

### 2. 两条转换路的差异（实测）

| 路 | 四音色 | 变速 | 鼓 |
|---|---|---|---|
| 网页 `score_studio.html`（本曲的判据） | 4 个都对 | 3 个 tempo 点 | **有**（axis 15） |
| `tools/mid2evt.py`（Python） | 4 个都对 | 3 个 tempo 点 | **整条丢掉**（`drums_excluded=110`） |

⇒ **要测鼓就必须走网页那条**。`_mid2evt对比/` 里留着那条路的产物作证据。

---

## 六、上板实测记录（跑完填这里，见 AGENTS.md 0.17）

| 项 | 预期 | 实测 |
|---|---|---|
| 上传进度 | 4356 B / 484 帧，不卡死 | |
| 起播后前 0.6 秒 | 屏/日志开始动 | |
| 四个音色 | 都听得出，音色互不相同 | |
| 鼓四件 | Kick/Snare/HiHat/Tom 都有 | |
| 变速 | 100 → 明显变快 → 明显变慢 | |
| 和弦 | Pad 四个音同时响 | |
| 第 12 小节鼓 | 三件都响 / 只响一件 | |
| 重击（tick 42240） | 不吞音、不挂音 | |

---

## 七、想改这段曲子

改 `gen_test_piece.py` 里的 `compose()`（音符是 `(tick, midi, vel, dur)` 的直白写法，
音名表在文件开头的 `N`），然后：

```powershell
python -X utf8 gen_test_piece.py && node verify_piece.js --hex events.hex
```

改完**必须重跑 `verify_piece.js`** —— 它判的是"上位机会把它转成什么"，
不是"我打算写什么"。轨名决定音色（`bass`/`guitar`/`piano`/`pad` 关键词），
改轨名会改音色；鼓轨靠轨名含 `drum` 或走 MIDI 通道 10 识别。

---

## 八、已知的工具小毛病（与本曲无关）

`esp32/tools/_inspect_midi.js` 和 `_diag_concurrency.js` 在 node 里跑时，
末尾会抛 `cv.parentElement.getBoundingClientRect is not a function`
（假 DOM 少一个 `parentElement`）—— 用现有的演示 MIDI 跑同样会抛，
**是工具本身的问题，不是曲子的问题**；报告在抛错前已经打完，可以照看。
