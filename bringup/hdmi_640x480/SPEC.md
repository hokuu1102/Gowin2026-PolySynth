# SPEC — H2 + H3：640×480@60 参数化彩条 + 自写 TMDS 编码器

> **这是唯一的需求来源**，与 `bringup/hdmi_ref_720p/` 下的 H1 参考工程配合使用。
> 工作目录：`C:\Users\cyx\Desktop\学习\hdmi_640x480`
> 上游：项目「Gowin2026-PolySynth」第三周计划 H2 / H3（2026-09-29 → 10-05）
> 生成：2026-09-30

---

## 〇、背景与边界（先读）

- 目标器件：**Gowin GW5AT-LV60PG484AC1/I0**（Tang Console 60K 板），系统时钟 **50 MHz**。
- 板载 HDMI TX，TMDS 差分脚见 `bringup/hdmi_ref_720p/hdmi_ref_720p.cst`。
- **H1 已完成**：用 Sipeed 官方参考工程验证了「引脚 + 官方加密 `DVI_TX_Top` IP + 官方 PLL」这条通路，
  能构建出 `.fs`（`bringup/hdmi_ref_720p/`、`bringup/hdmi_ref_720p/README.md`、`files/40-参考资料/HDMI参考实现调研与移植-H1-20260929.md`）。
- **H2 与 H1 的本质区别（本任务的核心）**：
  ⛔ **不许再使用加密的 `DVI_TX_Top` IP，也不许直接用 Sipeed 的 `testpattern.v` 当交付物**。
  H2 必须是**本项目自己写的**参数化彩条 + **自己写的 TMDS 编码器**。
  理由：加密黑盒给不出 RTL 佐证（同类问题见项目 `K-84`），且比赛要求视觉通路**纯 RTL**。
  `bringup/hdmi_ref_720p/vendor/` 下的官方文件**仅供参考**，不得作为交付物的一部分。

---

## 一、目标

| 编号 | 目标 | 判据 |
|---|---|---|
| **H2** | `640×480@60` 彩条输出（必须用 PLL，见 §六） | ✅ **上板验收通过（2026-09-30）**：`J_TOKENFIX_led.fs` 烧入 Console 60K 后屏幕出八色彩条；仿真自证 + PnR 0/0 |
| **H3** | 视频时序**参数化**（`H_ACTIVE`/`H_FP`/`H_SYNC`/`H_BP`/`H_TOTAL` + `V_*`） | 只改参数即可换分辨率，RTL 结构不变 |

---

## 二、时序规格（精确数字，不许"差不多"）

`640×480@60`（VESA DMT 工业标准模式）：

| 项 | 值 |
|---|---|
| 像素时钟（免 PLL 方案） | **25.000 MHz** = 50 MHz ÷ 2 |
| 像素时钟（PLL 方案，备选） | **25.200 MHz** = 50 × 63 / 125 |
| H_ACTIVE | 640 |
| H_FRONT_PORCH | 16 |
| H_SYNC | 96 |
| H_BACK_PORCH | 48 |
| **H_TOTAL** | **800** |
| V_ACTIVE | 480 |
| V_FRONT_PORCH | 10 |
| V_SYNC | 2 |
| V_BACK_PORCH | 33 |
| **V_TOTAL** | **525** |
| **HSYNC 极性** | **负**（同步脉冲期间为低） |
| **VSYNC 极性** | **负**（同步脉冲期间为低） |
| 刷新率（25.000 MHz） | 25e6 / (800×525) = **59.524 Hz** |
| 刷新率（25.200 MHz） | 25.2e6 / (800×525) = **60.000 Hz** |

> ⚠️ **极性是常见错误点**：`640×480@60` 是**负极性**；H1 的 720p 用的是正极性
> （`bringup/hdmi_ref_720p/hdmi_ref_top.v` 里 `I_hs_pol(1'b1)`）—— **⛔ 不要照抄**。

---

## 三、彩条规格

8 条竖彩条，**每条 80 像素**（640 / 8），从左到右：

| # | 颜色 | R | G | B | 像素区间 |
|---|---|---|---|---|---|
| 1 | 白 | 0xFF | 0xFF | 0xFF | 0–79 |
| 2 | 黄 | 0xFF | 0xFF | 0x00 | 80–159 |
| 3 | 青 | 0x00 | 0xFF | 0xFF | 160–239 |
| 4 | 绿 | 0x00 | 0xFF | 0x00 | 240–319 |
| 5 | 品红 | 0xFF | 0x00 | 0xFF | 320–399 |
| 6 | 红 | 0xFF | 0x00 | 0x00 | 400–479 |
| 7 | 蓝 | 0x00 | 0x00 | 0xFF | 480–559 |
| 8 | 黑 | 0x00 | 0x00 | 0x00 | 560–639 |

消隐期间（`DE=0`）像素数据不参与显示，编码器改发控制 token。

---

## 四、TMDS 编码规格

按 **DVI 1.0 规范**的 TMDS 8b/10b 编码，**3 个通道**（R / G / B）各一个编码器实例。

**1) 数据期（`DE=1`）**：8 bit → 10 bit，含
   - 跳变最小化（XOR/XNOR 二选一，由 `d[0]` 与 1 的个数决定）；
   - **DC 平衡**：维护每通道的运行不一致性（running disparity），使其有界。

**2) 消隐期（`DE=0`）**：发**控制 token**，由 `{HSYNC, VSYNC}` 决定：

| (c0,c1) | 10-bit 控制码 |
|---|---|
| (0,0) | `10'b1101010100` |
| (1,0) | `10'b0010101011` |
| (0,1) | `10'b0101010100` |
| (1,1) | `10'b1010101011` |

> ⭐⭐ **2026-09-30 更正（上板黑屏的真根因）**：
> - **原说法**：上表把 `(0,1)` 写成 `0010101011`、`(1,0)` 写成 `0101010100`（**两行写反了**）。
> - **更正**：`(c0,c1)=(1,0)`（HSYNC 有效、VSYNC 无效）应为 **`0010101011`**；
>   `(c0,c1)=(0,1)` 应为 **`0101010100`**。
> - **原因**：编码器 `tmds_encoder.v` 的 `case ({c1,c0})` 按**本表**实现，于是整个行同步脉冲期间
>   （以及场同步期间）蓝通道发出**错误的控制码** ⇒ 接收端解不出同步 ⇒
>   **有信号活动但出不了图（全黑）**，而心跳 LED 与 PLL 一切正常 —— 与实测症状完全一致。
> - **为什么之前没抓到**：tb 的 `token()` 参照表与解码模型 `tmds_decoder.sv` **抄了同一张错表**，
>   编码/解码往返自洽 ⇒ 判据"证明"了错误实现；对抗式复核也只对照了本表。
>   ⇒ 教训：**协议常量必须对照外部权威实现核对，不能只靠往返自证**。
> - **核对来源**：`nand2mario/tangcore` 的 `src/hdmi2/tmds_channel.sv`（hdl-util/HDMI，在本 Console 上实测跑通），
>   其 `control_data = {vsync, hsync}`（即 `{c1,c0}`）配合同一张表。

通道与控制的对应（DVI 规范）：

| 通道 | 消隐期 c0 / c1 |
|---|---|
| **通道 0（Blue）** | `c0 = HSYNC`，`c1 = VSYNC` |
| 通道 1（Green） | `c0 = 0`，`c1 = 0` → 恒 `10'b1101010100` |
| 通道 2（Red） | `c0 = 0`，`c1 = 0` → 恒 `10'b1101010100` |

> ⛔ 不要把 3 个通道写成同一个控制码 —— 只有蓝通道携带 HSYNC/VSYNC。

**参考实现**（可查阅，⛔ 不要整段复制官方加密 IP）：DVI 1.0 规范、Project F 的 DVI/HDMI 系列、
`hdl-util/hdmi`、`bringup/hdmi_ref_720p/vendor/sipeed/testpattern.v`（时序发生器写法）。

---

## 五、串行化与引脚

- 每通道 10 bit 并行 → 串行：用 Gowin **`OSER10`**（10:1，DDR），
  串行时钟 = **5 × 像素时钟**（免 PLL：**125.000 MHz**；PLL 方案：**126.000 MHz**）。
- 差分输出用 Gowin 差分输出原语（`TLVDS_OBUF` / `ELVDS_OBUF` 之类 ——
  **以器件实际可综合的原语为准**，`bringup/hdmi_ref_720p/impl/gwsynthesis/hdmi_ref_720p.vg`（H1 构建产物，不入库） 是 H1 综合后的网表，
  里面能看到官方 IP 实际怎么例化 OSER10 与差分缓冲，**这是查原语写法的第一手材料**）。
- 引脚（照抄 `bringup/hdmi_ref_720p/hdmi_ref_720p.cst`，**不许改**）：

```
clk              V22                LVCMOS33
rst_n            AA13               LVCMOS15  PULL_MODE=UP  BANK_VCCIO=1.5
tmds_d_p_0[0]    J14,H14            DRIVE=3.5  BANK_VCCIO=3.3
tmds_d_p_0[1]    J15,H15            DRIVE=3.5  BANK_VCCIO=3.3
tmds_d_p_0[2]    K17,J17            DRIVE=3.5  BANK_VCCIO=3.3
tmds_clk_p_0     G15,G16            DRIVE=3.5  BANK_VCCIO=3.3
hpd_en           K13                PULL_MODE=UP DRIVE=12 BANK_VCCIO=3.3
```

- `hpd_en` 由 FPGA 自己驱动为高（H1 就是 `assign hpd_en = 1'b1`）。

---

## 六、时钟方案（⭐ 2026-09-30 更正：A 不可能「免 PLL」）

> **原说法**：方案 A =「免 PLL：50 MHz ÷ 2 = 25 MHz」，串行 125 MHz 由此得到。
> **更正**：⛔ **做不到**。50 MHz 整数分频只能得到 **25 MHz 的像素时钟**；
> 而 TMDS 串行时钟必须是 **5 × 像素 = 125 MHz**，**50 MHz 无法用整数分频得到 125 MHz**。
> ⇒ **方案 A 也必须用一颗 PLL**（出 25 / 125 MHz）。
> **原因**：TMDS 用 `OSER10`（10:1 DDR）串行化，其时钟是像素时钟的 5 倍；
> 第三周计划 H2 的措辞只算了像素时钟、漏了串行时钟。
> 📌 **佐证**：H1 的 `README.md` 早就写过「H2 应重新生成自己的精确 **25.2/126 MHz PLL**」——
> 即 H1 作者已知需要 PLL。按 `K-114`，**PLL 用于外设 / TMDS 时钟属正常用法**，
> ⛔ 不违反「不用 PLL 输出做全设计系统时钟」的边界。

| 方案 | 像素 / 串行 | 偏差 | PLL 参数 | 状态 |
|---|---|---|---|---|
| **A（默认）** | 25.000 / 125.000 MHz | 0.70% | `MDIV=20 / ODIV0=8 / ODIV1=40` | ✅ 已构建，0 setup / 0 hold |
| **B（备选）** | 25.200 / 126.000 MHz | 0.099% | `MDIV=63 / ODIV0=25 / ODIV1=125` | 已生成 bitstream，但 PnR 报 `PA1019`：VCO 3150 MHz 超出 700–1400 MHz，硬件时钟不可据此视为已验证；切换时仍需同步修改 SDC |

要求：**把时钟源隔离成一个独立模块**（`rtl/hdmi_clk.v`），顶层只依赖它输出的
`pixel_clk` / `serial_clk` / `lock`，两版可互换。默认走方案 A；`USE_252=1` 切方案 B。

---

## 七、交付物（建议结构，可微调但要说明）

```
hdmi_640x480/
  rtl/video_timing.v        # 参数化时序发生器（纯 RTL，⛔ 不含任何 Gowin 原语）
  rtl/color_bars.v          # 8 色彩条（纯 RTL）
  rtl/tmds_encoder.v        # TMDS 8b/10b 编码器（纯 RTL，3 通道）
  rtl/tmds_serializer.v     # OSER10 + 差分输出（原语层）
  rtl/hdmi_clk.v            # 时钟源层（A/B 两版）
  rtl/hdmi_top.v            # 顶层
  constr/hdmi_640x480.cst   # 引脚（照抄 H1）
  constr/hdmi_640x480.sdc   # 时钟约束
  hdmi_640x480.gprj         # Gowin 工程（可参照 bringup/hdmi_ref_720p/hdmi_ref_720p.gprj）
  build_hdmi_640x480.ps1    # 构建脚本（⛔ ASCII-only）
  tb/tb_hdmi_640x480.sv     # 自检 tb（只测纯逻辑层）
  tb/tmds_decoder.sv        # tb 用的 TMDS 解码模型
  tb/run_mutations.ps1      # 缺陷注入脚本（非空洞性证明）
  README.md                 # 说明：结构、怎么跑、已知限制
```

**关键设计要求**：把 RTL 分成
**① 纯逻辑层**（`video_timing` / `color_bars` / `tmds_encoder`，无原语、可仿真）
和 **② 原语层**（`tmds_serializer` / `hdmi_clk`，含 Gowin 原语、只在综合时需要）。
**tb 只测纯逻辑层** —— 这样 iverilog 完全够用，不需要任何 Gowin 原语模型。

---

## 八、验收判据（必须可失败）

### 8.1 仿真（必做）

`tb/tb_hdmi_640x480.sv` 必须：把 `tmds_encoder` 输出的 10 bit 流**解码回 8 bit 像素 + DE/HS/VS**，
然后断言：

1. **时序计数精确**：每行 800 个像素时钟、HSYNC 低电平宽 96、每帧 525 行、VSYNC 低电平宽 2 行、
   每行有效像素 640、每帧有效行 480。
2. **`DE` 只在有效区为高**。
3. **彩条逐像素正确**：按 §三 的区间表逐点比对（不是"看一眼像彩条"）。
4. **TMDS 编码可逆**：256 个数据值全部 `decode(encode(v)) == v`。
5. **控制 token 精确**：消隐期 3 个通道输出的 10 bit 值 == §四 的表（含蓝通道携带 HSYNC/VSYNC）。
6. **DC 平衡有界**：每通道运行不一致性不超过规范界。

### 8.2 非空洞性（必做，**这是硬要求**）

必须证明这套判据**抓得住错**：至少注入 **3 个**不同缺陷，逐个给出「必红」的证据，然后还原。
建议的 3 个：

- 把 `H_TOTAL` 从 800 改成 799（计数判据必红）；
- 把两个彩条颜色对调（彩条判据必红）；
- 把 HSYNC 极性写反（极性/时序判据必红）。

⭐ **2026-09-30 补：上面 3 条只覆盖时序/彩条，没有一条打 TMDS ⇒ token 与 DC 平衡判据的
非空洞性未被证明。** 已补 3 条（`tb/run_mutations.ps1` 现共 **6** 条）：

| # | 缺陷 | 必红判据 |
|---|---|---|
| 4 | `TOKEN_CTL10`：把 `(c0,c1)=(1,0)` 的控制码换成别的 | `TMDS_CONTROL_TOKEN` |
| 5 | `TOKEN_CTL00`：把消隐期 `(0,0)` 的 `1101010100` 换掉 | `TMDS_CONTROL_TOKEN` |
| 6 | `DISPARITY_ZERO`：把 disparity 更新写成恒 0 | `TMDS_DC_BALANCE` |

> ⚠️ 第 6 条是**复核时发现的判据盲区**：原判据 `u_*.disparity` 读的是 **DUT 内部寄存器**，
> 属自指 —— 把 disparity 更新改成恒 0 时它反而恒真（|0| ≤ 8 永远成立）。
> ⇒ 已改为**输出可观测**的 DC 平衡：统计**每个已发出符号**的真实 `(ones − zeros)` 累计和，
> **只统计有效像素**（控制 token 由规范固定、不参与 disparity 平衡，且编码器在消隐期清零），
> 每段有效区重新起算，界为 **±8**。第 6 条注入证明它抓得住。

证据形式：命令 + 输出里的 `FAIL` 行（判据名请用**纯 ASCII**，见 §九）。

### 8.3 综合/PnR（能做到就做）

若你的沙箱能访问 Gowin 工具链（`D:\Gowin\Software\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe`），
跑一次 `run all`，报告 **0 setup / 0 hold** 与 Fmax。
**若被沙箱挡住，明确说出来**（不要假装跑过），把命令与报错原文贴上。

---

## 九、硬约束（违反即返工）

1. ⛔ **只在本工作目录内写文件**（`C:\Users\cyx\Desktop\学习\hdmi_640x480\`）。
2. ⛔ **`.ps1` 脚本一律 ASCII-only** —— Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI 读，
   中文注释会让解析器直接崩（本项目 `K-38` 就是这个坑）。
3. ⛔ 判据名 / 日志关键字**一律纯 ASCII**，且 ≤ 128 字节（本项目实测：非 ASCII 会被 `vvp` 破坏性转换）。
4. ⛔ **不要用加密的 `DVI_TX_Top` IP**，也不要直接拿 `bringup/hdmi_ref_720p/vendor/sipeed/testpattern.v` 当交付物。
5. ⛔ **不要改 `bringup/hdmi_ref_720p/` 下的 H1 参考工程**（只读）。
6. 不确定的地方**写进 README 的"未验证/已知限制"**，⛔ 不要写成"已验证"。

---

## 十、报告格式（每步都要）

- 改了/新增了哪些文件（完整路径）
- 实际执行的**命令原文**
- 结果：通过/失败 + 关键输出行
- **未完成项 / 被阻塞项**（写清阻塞原因，例如"沙箱不允许访问 D:\Gowin"）
- ⛔ 不要把没跑过的东西写成跑过了
