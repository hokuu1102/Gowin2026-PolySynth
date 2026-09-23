# 🔧 工具链与 Gowin 工程（**P1**）

> ⭐ **这份文档解决什么问题**：没有系统板的时候，验收只能靠仿真 —— 但**仿真过 ≠ 能综合**。
> 这里给出**第三条证据腿**：不插板、不看波形，用 Gowin 自己的工具证明
> **① 能综合 ② 能收敛时序 ③ 脚位合法、电平/上下拉真的按我们写的生效**。
>
> 📌 相关：`files/20-代码/代码总览图.md` `P1`（工具链与工程）｜`K-45`（两条警告的准确含义）｜
> `files/20-代码/仿真与验证方案.md` §四（基石板能做什么）

---

## 一、⭐ 一条命令跑全流程（综合 + 布局布线 + bitstream）

```powershell
# ① 推荐：跑构建 + 把关键报告自动抄进 sim/evidence/（可复现、证据不会丢）
powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1

# ② 只要构建（不抄证据）
cd C:\Users\hokuu\Desktop\FPGA\FPGA2026
& "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe" build_cli.tcl
```

> ⚠️ `sim/gowin_build.ps1` **故意写成全 ASCII**（PS 5.1 会把无 BOM 的 UTF-8 按 GBK 解码，中文注释会变乱码并报语法错，`K-38`）。

| 文件 | 作用 | 入不入库 |
|---|---|---|
| `Gowin2026.gprj` | **工程本体**（器件型号 + 源文件清单 + 约束文件清单） | ⭐ **入库**（这是交付物） |
| `constr/top.cst` | 引脚约束 | ⭐ **入库**（交付物） |
| `constr/top.sdc` | **时序约束**（50 MHz 时钟） | ⭐ **入库**（⛔ 见 §三：不写它时序分析是空的） |
| `build_cli.tcl` | 命令行构建脚本（`open_project` → `run all`） | ⭐ **入库** |
| `sim/gowin_build.ps1` | 跑构建 + 抄证据（时序摘要 / 引脚表 / 资源表 / 构建日志） | ⭐ **入库** |
| `rtl/**` | RTL 源 | ⭐ **入库** |
| `impl/**` | 综合网表、报告、bitstream（`Gowin2026.fs`） | ⛔ **不入库**（`.gitignore` 已屏蔽；随时可重建） |
| `sim/evidence/gowin_*` | ⭐ 从 `impl/` 抄出来的**关键证据** | ⭐ **入库**（否则报告随 `impl/` 一起被忽略掉） |

> ⚠️ **`build_cli.tcl` 故意写成全 ASCII**：本机控制台是 GBK，
> Tcl 读**无 BOM 的 UTF-8 中文注释**可能出问题。⛔ 别为了"好看"把中文注释塞进去。
> ⚠️ ⛔ **不要一边开着 Gowin IDE 一边跑这个脚本**（同一个工程会被两边同时写）。

---

## 二、⭐ 通过之后必须看这四样（不然"通过"等于没看）

| # | 看什么 | 在哪 | 判据 |
|---|---|---|---|
| 1 | 综合/布线**零 error** | 控制台 / `impl/pnr/Gowin2026.log` | 进程退出码 `0` |
| 2 | ⭐⭐ **时序**：违规端点 + `Actual Fmax` | `impl/pnr/Gowin2026_tr_content.html` | `Numbers of Setup Violated Endpoints = 0`、`Numbers of Hold Violated Endpoints = 0`、`Max Frequency Summary` 的 `Actual Fmax ≥` 目标频率 |
| 3 | ⭐⭐ **脚位合法**：脚真的存在、`IO_TYPE`/上下拉/驱动按我们写的生效 | 生成目录里的 `Gowin2026.rpt.txt` **§7 Pinout by Port Name**（或 `Gowin2026.pin.html`） | **逐脚核对**（表里有 `Site`/`Bank`/`IO Type`/`Pull Mode`/`Drive`…） |
| 4 | 资源占用 | `impl/gwsynthesis/Gowin2026_syn_rsc.xml` | `Register` / `Alu` / `Lut` 计数 |

> ⭐ 第 2、3 条是**仿真给不了**的东西：
> ② 只有真跑布局布线才知道 `Fmax`；③ 只有综合器才认识 `V22` 这种 ball 号 ——
> **`.cst` 写错一个字母，仿真完全看不出来，这里立刻报错**。

---

## 三、⚠️ 必须有时序约束（`.sdc`）—— 否则"时序分析"是**空的**

2026-09-17 首次跑通时实测到的现象：

```text
<Timing Constraints File>: ---                                   ← 没有约束文件
WARN  (TA1132) :  'clk' was determined to be a clock but was not created.
```

⇒ 此时工具**没有任何时序目标可比**，"布局布线通过 + 生成了 bitstream"**说明不了任何时序问题**。
补上 `constr/top.sdc` 之后：

```text
<Timing Constraints File>: ...\constr\top.sdc                    ← 生效
（TA1132 消失）
```

`constr/top.sdc` 内容（语法出处：Gowin 自带例程 `IDE\data\examples\led_water\src\led_water.sdc`）：

```tcl
create_clock -name clk_sys -period 20 -waveform {0 10} [get_ports {clk}]
```

> ⭐ **可迁移的教训**：**"零 error" ≠ "没问题"** ——
> 上一个项目（经验库 `L31`）就是"综合/布线零 error、板子却全死"。
> 以后只要看到"时钟没被创建 / 时钟被降级"这类警告，**先查清楚再往下走**。

---

## 四、⭐ M0 实测基线（2026-09-17，`top.v` = `clk_gen` + `i2s_tx` + 安全态 + 心跳）

| 项 | 结果 |
|---|---|
| 器件 | `GW5AT-60B` / `GW5AT-LV60PG484AC2/I1`（器件名 `gw5at60b-003`）· Device Version **B** |
| 全流程 | 综合 → 布局布线 → **bitstream 生成**：**全部完成、退出码 0** |
| ⭐ 时序 | 时钟 `clk_sys` = 50 MHz（period 20 ns）；**Setup 违规端点 0 / Hold 违规端点 0**；**`Actual Fmax = 325.9 MHz`（逻辑级数 5）** —— ⚠️⚠️ **这是"只算寄存器→寄存器"的乐观值**，见下方 §四-b |
| 资源 | `Register 55` / `Alu 40` / `Lut 35`（含 `rst_sync` 的 2 FF）；时钟资源 `PRIMARY 1/8` |

> ### ⭐⭐ §四-b **Fmax 的两个口径（2026-09-17 实测，别被大数字骗了）**
>
> | 口径 | Fmax | 说明 |
> |---|---|---|
> | **只约束 `create_clock`**（寄存器→寄存器） | **325.9 MHz** | ⚠️ **不含进出引脚的路径** —— 因为它**压根没被分析** |
> | **补上 I/O 约束**（`set_output_delay` 等，见 `constr/top.sdc`） | **55.96 MHz** | ⭐ 这才是"到 DAC 引脚"的真实可达频率 |
>
> **两次都是"0 违规"**，但含义完全不同：前者是"没查外部路径所以没违规"，
> 后者是"查了、而且 50 MHz 目标下**确实没有违规**"。
> ⇒ ⭐ **纪律：报告里的 Fmax 必须连同"它约束了什么"一起引用**。
> ⛔ 只写 `create_clock` 就说"时序余量 6.5 倍"是**错的**（那是漏检）。
> 📌 本设计实测余量 = **55.96 / 50 = 1.12×** —— 达标但**不宽裕**，
> 所以**每加一个模块都要重跑**（这条基线就是给 32 voice 用的）。
>
> ⚠️ 最差路径实测是 `u_i2s_tx/ch_s2 → HP_WS_obuf`（2.130 ns 建立裕量），
> 也就是**输出到 DAC 的路径**——这正是"只算内部路径会漏掉"的那一类。
| ⭐ 脚位 | **7 个脚全部按 `.cst` 落位**：`clk=V22`、`rst_n=AA13`、`HP_BCK=Y17`、`HP_WS=AB17`、`HP_DIN=AA16`、🔴 旧 `PA_EN_n=AB16` → ⭐ **`PA_EN=Y14`**（⚠️ `LVCMOS15`/1.5 V，⭐ **高电平 = 出声**）、🔴 旧 `led_heartbeat=T18` → ⭐ **`V13`**（`SYS_ACT`）。⚠️ **换板后这两条都变了**，见 `Console引脚查证-20260922.md` |

> ⭐ 这条基线的用处：以后**每加一个模块**（`voice`/`mixer`/`tlc5916`/`adc`…）都重跑一次，
> 就能看出"资源涨了多少、Fmax 掉到多少" —— 32 voice 的资源与余量预算（`K-28`）从此有实测锚点。

---

## 五、⚠️ 器件料号：**手上板 ≠ 赛题板**（先别搞混）

| 板子 | 料号 | 状态 |
|---|---|---|
| **手上这块**（高云 `DK_START` 基石板，带龙芯 LS2K1000） | `GW5AT-LV60PG484AC2/I1` | ✅ 丝印/官方 `.cst` 自述确认 |
| **赛题板**（Sipeed `Tang Mega 60K` Dock） | 报道为 `GW5AT-LV60PG484AC1/I0` | ⚠️ **尚未按实板丝印确认**（`files/20-代码/RTL规划前仓库事实核验.md` 已记录这处漂移） |

- ✅ **同 die、同封装（GW5AT-60B / PBGA484A）** ⇒
  **可综合性、脚位合法性、资源占用**这三样结论**两块板通用**（晶体管的"能不能装下"和"脚在不在"与速度级无关）。
- ⚠️ **时序数字乐观**：`AC2/I1` 比 `AC1/I0` 快 ⇒ 我们量到的 `Fmax 332.9 MHz` 在 Dock 上会低一些。
  ⭐ 但我们有 **6.7 倍余量**，这点速度级差异不影响结论。
- ⛔ **板子到手后**：按**实板丝印**把 `.gprj` 里 `pn=` 那一个字段改掉，**重跑一次**，把新报告存进 `sim/evidence/`。

---

## 六、怎么加一个新模块（一行）—— ⚠️ 这里有个**静默**陷阱

在 `Gowin2026.gprj` 的 `<FileList>` 里加一行：

```xml
<File path="rtl/xxx.v"  type="file.verilog" enable="1"/>
<File path="rtl/xxx.sv" type="file.verilog" enable="1"/>   <!-- ⭐ .sv 也是 file.verilog！ -->
```

> ### ⛔⛔ 陷阱：文件 `type` 写错时，高云**不报错、直接静默跳过**（2026-09-17 实测）
> 我一开始把 `.sv` 猜成 `type="file.systemverilog"` —— 构建**照样 exit 0、照样出 bitstream**，
> 但日志里**既没有** `Analyzing … xxx.sv`、**也没有** `Compiling module 'xxx'`。
> 也就是说：**文件"看起来登记进工程了"，其实压根没被读**。
> ⇒ 如果 `top` 例化了它，就会变成"例化了一个不存在的模块"；如果没例化，你会以为"我的模块过了工具链"，**其实没有**。
>
> ✅ **正确做法**（依据：Gowin 自带例程 `<Gowin安装>\IDE\data\examples\cpu\cpu.gprj` —— 它的 `.sv` 全部登记为 `type="file.verilog"`）：
> 1. `.v` 与 `.sv` **都用 `type="file.verilog"`**；
> 2. ⭐ **每次加完文件，去日志里确认那两行真的出现了**：
>    ```text
>    Analyzing Verilog file '…\rtl\drivers\tlc5916_driver.sv'
>    Compiling module 'tlc5916_driver'(…)
>    ```
>    只有第 1 行 = **只做了语法解析**；两行都有 = 真的进了综合。

> ### ⚠️ 第二条（同样重要）：**"被解析" ≠ "被综合"**
> 没有被顶层例化到的模块，Gowin **只分析、不编译**（实测：`tlc5916_driver.sv` 登记正确后，
> 日志只有 `Analyzing`、没有 `Compiling module 'tlc5916_driver'`）。
> ⇒ **"这个模块能综合"这句话，只有在它被顶层可达地例化之后才成立。**
> ⛔ 别拿"我把它加进工程了、构建过了"当"它能综合"的证据。

> ⭐ **只加"顶层真正会例化到"的模块**（`clk_gen` / `i2s_tx` / `top` 就是全部）
> —— 把别人的半成品加进来，既不能被综合，出错时还分不清是谁的问题。

---

## 七、⭐ `PR1014` 到底要不要担心（**别和 `K-41` 的 PLL 事故混为一谈**）

任何一次构建都会看到这条：

```text
WARN  (PR1014) : Generic routing resource will be used to clock signal 'clk_d'
                 by the specified constraint. And then it may lead to the excessive delay or skew
```

**已查清的因果（用工具自己的数据佐证，⛔ 不是猜的）**：

| 证据 | 数据 |
|---|---|
| 专用时钟输入脚长什么样 | 包的其它脚 `CFG` 列写着 `GCLKT_0`/`GCLKC_1`…（`B17/B18/D17/C17/C18/C19/E19`…） |
| 我们的时钟脚 | ⭐ `V22` 的 `CFG` 列写的是 **`EMCCLK`** —— **不是**专用时钟输入脚 |
| 时钟资源占用 | `GCLK_PIN 0/40` ⇒ 时钟**没有**走专用时钟输入通道 |
| 但时钟树上了没有 | `Global Clock Signals: clk_d | PRIMARY | BR BL` ⇒ ⭐ **上了全局时钟主干** |
| 后果有多严重 | Setup/Hold 违规端点 **0**、`Actual Fmax 332.9 MHz` ⇒ **实际无害** |

⇒ 结论：**`PR1014` = "时钟经通用布线进主干"，成因是板载 50 MHz 晶振接在 `V22`（非专用时钟脚）上**，
这是**板子的既定事实、我们改不了**（⛔ 也**不许**为了消警告把时钟挪到别的脚 —— 那样板子直接不工作）。
单时钟域 + 只有 50 MHz ⇒ 额外插入延迟/偏斜不构成问题，**由时序报告背书**。

> ⚠️ **与 `K-41` 的区别**（两件事长得像，但完全不是一回事）：
> 上一个项目那次是 **PLL 输出做全设计系统时钟 ⇒ 全设计无时钟、板子全死**，
> `PR1014` 只是**同时出现的一个现象**，⛔ 它本身**不是**"板子坏了"的证据。
> ⇒ 以后看到 `PR1014`：**先看"时钟上没上全局主干 + 违规端点是不是 0"**，再决定要不要处理。
