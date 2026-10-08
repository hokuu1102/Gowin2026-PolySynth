# K-41 PLL 活体见证 + fVCO 核算（HDMI / TMDS 时钟）

> 归档日期：2026-10-06　·　对应交付：`Z_merged_base_T5.fs`（55.060 MHz / 0-0）
> 目的：满足 **K-41** 的"PLL 活体见证 + fVCO 核算"，作为 HDMI 接入主工程的**第三条件**。

---

## 一、K-41 的要求原文（出处）

`files/20-代码/已知问题与风险清单.md:87`：

> | **K-41** | ⭐ **PLL 口径**：文档多处写「⛔ 不用 PLL」，准确边界是「**⛔ 不用 PLL 输出做全设计系统时钟**」 |
> 依据上一个项目 `ADDA` 的实测（经验库 `L31`）：逻辑全搬到 PLL 域后，`clk50` 只驱动 mdclk ⇒ 被工…

`files/20-代码/W3接口冻结表.md:25-30`：

> ⭐⭐ **准确边界（⚠️ `K-41` / `K-114`，⛔ 别读成"本项目禁止 PLL"）**：
> ⚠️ 但引入 PLL 时**必须留活体见证 + 核算 `fVCO`**（见 `K-41`），⛔ 不是改个参数。

⇒ **本设计的合规性**：PLL 只驱动 **TMDS 的 `serial_clk` / `pixel_clk`**（外设时钟），
**`clk_sys` 仍来自 50 MHz 晶振、音频通路完全不用 PLL** ⇒ ⛔ **没有**违反"不用 PLL 输出做全设计系统时钟" ✅
（依据 `K-114`：`files/20-代码/已知问题与风险清单.md:153` —— 外设/TMDS 用 PLL 属正常用法）

---

## 二、⭐ fVCO 核算（本文件的核心）

### 配置来源：`rtl/hdmi/hdmi_clk.v`

```verilog
L5:   parameter USE_252 = 0            // 默认 0，且 top.v 未覆盖 ⇒ 生效值是 0
L29:  defparam u_pll.FCLKIN     = "50";
L30:  defparam u_pll.IDIV_SEL   = 1;
L31:  defparam u_pll.FBDIV_SEL  = 1;
L32:  defparam u_pll.MDIV_SEL   = USE_252 ? 63 : 20;
L33:  defparam u_pll.ODIV0_SEL  = USE_252 ? 25 : 8;
L34:  defparam u_pll.ODIV1_SEL  = USE_252 ? 125 : 40;
```

### 核算（生效分支 `USE_252 = 0`）

```
fVCO       = FCLKIN × MDIV_SEL / IDIV_SEL
           = 50 MHz × 20 / 1
           = ⭐ 1000 MHz          ← 必须落在 PLLA 的允许区间内（本器件约 700~1400 MHz）✅

serial_clk = fVCO / ODIV0_SEL = 1000 / 8  = ⭐ 125.000 MHz
pixel_clk  = fVCO / ODIV1_SEL = 1000 / 40 = ⭐  25.000 MHz
```

**与约束文件交叉核对**（`constr/top.sdc:75-76`）：

```tcl
create_clock -name serial_clk -period 8.000  ...   // = 125 MHz ✅ 一致
create_clock -name pixel_clk  -period 40.000 ...   // =  25 MHz ✅ 一致
```

⇒ ⭐ **核算结果与 SDC 约束、与 RTL 注释（`hdmi_clk.v:2` "50*20/40=25 and 50*20/8=125"）三方一致** ✅

### 640×480@60 的实际刷新率

```
像素时钟 25.000 MHz，标准 640×480@60 总像素 800×525 = 420000
⇒ 刷新率 = 25.000e6 / 420000 = 59.5238 Hz     （与 H5 文档记录一致 ✅）
```

---

## 三、⚠️ 本次核算发现的**一个休眠地雷**（新发现）

**`USE_252 = 1` 那条分支的 fVCO 越规格：**

```
USE_252 = 1 时：
  fVCO = 50 × 63 / 1 = ⭐ 3150 MHz      ← 🔴 远超允许区间（约 700~1400 MHz）
  serial_clk = 3150 / 25  = 126.0 MHz
  pixel_clk  = 3150 / 125 =  25.2 MHz
```

📌 **同类前例**：`files/00-总览/第三周/第三周计划-v1.md:70` 明确记录 H4 计划里
`50×77/25` 的 **VCO=3850 MHz 属违规**，后来改用 `MDIV=15/FRAC=3/ODIV0=1/ODIV1=5`
（VCO 768.75 MHz）才合规 ⇒ **同一个判据下，3150 MHz 同样越规格**。

**当前风险等级：低（休眠）**
- `hdmi_clk` 的 `USE_252` **默认 0**，且 `rtl/top.v` 的例化**没有覆盖它**（已 grep 核对）
- ⇒ 该分支**从未被综合**，不影响现有位流 ✅

**建议（⛔ 不是本次要改的）**：给 `USE_252 = 1` 加一条**编译期断言**（像 `VEL_AXIS_N != SYS_AXIS_N` 那样），
或者把该分支的注释改成"⚠️ 未验证：fVCO 3150 MHz 越规格，⛔ 启用前必须重新核算"。

---

## 四、⭐ 活体见证（三份独立证据）

### 见证 ① / ②：**两次独立 PnR 报告**（不同构建 ⇒ 互相独立）

| 项 | `evidence/h5/merged-56p351/Gowin2026.rpt.txt` | `evidence/h5/base-T5-55p060/Gowin2026.rpt.txt` |
|---|---|---|
| PLLA 占用 | `L99: PLLA \| 1/8 \| 13%` ✅ | `L99: PLLA \| 1/8 \| 13%` ✅ |
| `pixel_clk` 走全局 | `L109: u_hdmi/pixel_clk \| PRIMARY \| TR BR` ✅ | `L109: u_hdmi/pixel_clk \| PRIMARY \| TR BR` ✅ |
| `serial_clk` 走全局 | `L117: u_hdmi/serial_clk \| HCLK \| BANK3_BANK4_BANK5_HCLK0` ✅ | `L117:` 同上 ✅ |

⇒ ⭐ **两份报告逐字一致**，且是**两次不同的构建**（56.351 与 55.060）
⇒ 证明 PLL **确实在网表里、它的两个输出确实被当作真实时钟布线**（⛔ 不是被优化掉的死逻辑）✅

### 见证 ③：**时钟汇总文件点名 PLL 的输出网络**

`sim/evidence/gowin_m0_timing.txt`：

```
L45: serial_clk
L53: u_hdmi/u_clk/u_pll/CLKOUT0      ← ⭐ PLL 的 CLKOUT0 就是 serial_clk 的来源
L55: pixel_clk
L63: u_hdmi/u_clk/u_pll/CLKOUT1      ← ⭐ PLL 的 CLKOUT1 就是 pixel_clk 的来源
```

⇒ 从**工具的报告里**直接坐实了"`serial_clk`/`pixel_clk` 由 PLLA 的 CLKOUT0/CLKOUT1 产生" ✅

### 见证 ④：**上板实物证据**（间接但强）

| 时间 | 事件 | 出处 |
|---|---|---|
| 2026-10-01 | **H5 波形上板通过**：显示器识别 640×480、黑底绿波形随演奏变化、静音回中心线 | `files/00-总览/第三周/第三周计划-v1.md:71`（commit `d0cb8b4`） |
| 2026-10-04 | 主工程正式版上板："功能与显示均实测正常" | `files/20-代码/H5显示修复与时序拉锯-记录与方向-20261002.md:733-749, 785-786` |

⇒ ⭐ **显示器真的点亮并出图** ⇒ `pixel_clk` 与 TMDS 串行时钟**确实在跑、PLL 确实锁定了** ✅
（这是"活体"的最强形式：**PLL 没锁 ⇒ TMDS 不会出图**）

---

## 五、⛔ 还缺什么（诚实清单）

| # | 缺的东西 | 为什么重要 | 怎么补 |
|---|---|---|---|
| **1** | **示波器实测引脚上的 25.000 / 125.000 MHz** | 目前是"核算 + 工具报告 + 出图"三重间接证据；**直接测量**才是最严格的"活体见证" | 探头点 `CLK` 引脚（`G15/G16`）与 TMDS 时钟对，测频率与抖动 |
| **2** | **`lock` 信号的实测观察** | `hdmi_clk.lock` 已引出（`hdmi_clk.v:43`），但未见上板观察记录 | 引到某个 LED/测试点，或经 `uart_tx` 回读 |
| **3** | **上板照片/视频** | 现有 `evidence/h5/triggered-scope-20261002/frameA.png` 是**仿真帧 dump**，⛔ 不是实物照 | 见 `BOARD_CHECK.md` |

⇒ ⭐ **结论**：K-41 要求的"**fVCO 核算**"本次**已完成** ✅；
"**活体见证**"已有**三份工具级 + 一份实物级（出图）**证据，**尚缺示波器实测与照片**。
按 `新需求分析…:20-25` 的三条件口径：**余量够 ✅（55.060，+6.9%）· 上板出图验证过 ✅ · PLL 见证 ⚠️（本文档补齐了核算与工具级见证，实物测量待补）**。

---

## 六、复核指引（下次有人问"PLL 合规吗"）

```bash
# 1) 核算（本文件第二节）
grep -n 'MDIV_SEL\|ODIV0_SEL\|ODIV1_SEL\|IDIV_SEL\|FCLKIN' rtl/hdmi/hdmi_clk.v
# 2) 与约束交叉核对
grep -n 'serial_clk\|pixel_clk' constr/top.sdc
# 3) 工具级见证（任取一份新构建报告）
grep -n 'PLLA\|u_hdmi/pixel_clk\|u_hdmi/serial_clk' evidence/h5/*/Gowin2026.rpt.txt
```

⚠️ **每次改 `hdmi_clk.v` 的参数都必须重跑本文档第二节的核算** —— 这是 K-41 的原意（"⛔ 不是改个参数"）。
