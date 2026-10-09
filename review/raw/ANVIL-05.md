# ANVIL-05 · 采集与标定 A —— 逐行剖析报告

**范围**：`rtl/w3a/calib_span.v` · `rtl/w3a/calib_cmd.v` · `rtl/w3a/calib_autotare.v` · `rtl/drivers/calib.sv`
**器件**：GW5AT-60B · AC1/I0 慢档 · `clk_sys` = 50 MHz · SDC `set_max_delay 18.181 ns`（≈55 MHz，`constr/top.sdc:101`）
**门槛**：0 setup / 0 hold · Fmax ≥ 51.5 MHz

---

## 0. 取证基线（所有结论都贴这些数）

| 项 | =0 交付档 | =1 档（`RIGHT_ADC_ENABLE=1`） |
|---|---|---|
| Fmax / CLS | **55.060 MHz** / CLS **78%** | **≈57.0 MHz** / CLS **81%** |
| setup / hold 违例 | **0 / 0** | **0 / 0** |
| 最差 setup 路径 | `u_tdm_render_mixer/cnt_4_s0/Q → prod_c_0_s/D[8]`，数据延时 **15.978 ns**，slack **+0.019 ns** | `tdm_render_mixer/cnt_4 → prod_c_0`，slack **+0.642 ns** |
| 第 25 名 setup 路径数据延时 | **15.218 ns**（= Top-25 的门槛） | — |
| DSP 数 | 7 | **10** |
| 最差路径出现本批模块？ | **否**（`u_calib0/u_calib1` 只出现在 Recovery 表） | **否** |

**证据文件**（逐条可回查）：

* `evidence/h5/base-T5-55p060/Gowin2026_tr_content.html:238-247` —— =0 档 55.060 MHz 基线的 Top-1 setup 路径：
  `1 | 0.019 | g_sound.u_tdm_render_mixer/cnt_4_s0/Q | g_sound.u_tdm_render_mixer/prod_c_0_s/D[8] | 18.181 | -0.008 | 15.978`
* 同文件 `:503-511` —— 第 25 名：`25 | 0.851 | ... prod_c_0_s/D[12] | 18.181 | -0.008 | 15.218`
* `sim/evidence/rightboard-vibrato-fix-20261008/README.md:118-128` —— =1 档修后 `TNS 0.000 / 违例 0 / 最差 +0.642 / ≈57.0 MHz / CLS 81% / DSP 10`
* 同 README `:26-31` —— =1 档**修前**：`u_vibrato_lfo/phase_q_17_s0 → gen_lane[*].phase_q_*`，slack **−3.272 ns**，数据延时 **21.4 ns**，**1630 条违例**、TNS −2718.329
* `impl/pnr/Gowin2026_tr_content.html:18579-18580 / :18797-18798` —— **标定乘法器是 DSP 原语**：
  `DSP_R65[12] | g_sound.u_calib0/n840_s/RESET[0]` · `DSP_R47[13] | g_sound.u_calib1/n840_s/RESET[0]`
* `sim/evidence/rightboard-vibrato-fix-20261008/timing-rightadc-fixed.html:17337-17339 / :17394-17396` —— =1 档同一 DSP：`LOC = DSP_R65[30]`，`g_sound.u_calib0/n840_s/CLK[0]`
* `evidence/h5/base-T5-55p060/Gowin2026_tr_content.html:29864-29867` —— 高扇出网：`486 | g_sound.af_sample_ch[2] | 2.028 | 4.641`
* `sim/evidence/synth_check.log:40-41` —— `Extracting RAM for identifier 'zero_r'` / `'gain_r'` ⇒ **分布式 RAM（LUTRAM）**
* `sim/evidence/tb_right_adc.compile.log:31-33` —— `rtl/top.v:1995: warning: Port 5 (sample_data_i) of module calib_autotare expects 24 bit(s), given 36.` + `Pruning 12 high bits of the expression.`
* `tb_calib_still_guard.sv:353-390` —— 多片静止守卫**已有判据**（N13 两段）

> ⚠️ 本项目 PnR 是布局噪声主导（同源重跑差 2~3 MHz）。**下列每条都标注了"结构性"还是"布局运气"。**

---

## P0-1 · `calib_span.v`：**多帧投票的"值"从未被读** —— 写进 `calib` 的是最后那一拍活采样

**位置**：`rtl/w3a/calib_span.v:215` · `:270-271` · `:478`（**全文件仅此三处出现 `vote_lo`，无任何读者**）

```verilog
215:    reg [11:0] vote_lo, vote_hi;
...
270:            vote_lo     <= 12'd0;
271:            vote_hi     <= 12'd0;
...
478:                        vote_lo <= (vmin + vmax) >> 1;
```

**为什么是问题（机制 + 数字）**

1. `vote_lo` 是**唯一**承载"投票代表值"的信号，但它**只被写、从不被读** ⇒ 综合直接剪掉。
2. 真正送进 `calib` 的值是 `S_WAITBUSY` 发脉冲那一拍的**当拍活采样** `raw_i`（`calib.sv:291 den_r <= raw_f - zero_cc;` 里 `raw_f` 就是 `raw` 端口）。⇒ 用户明确要求的"**值不能只取最后一个采样**"（`calib_span.v:3`、`:211-214`）**没有交付**：投票只当了"闸门"（离散度超限就拒），**没有当"取值器"**。
3. 误差量级（硬算）：`top.v:287` 传 `SPAN_VOTE_TOL = 12'd96` ⇒ 允许组内 (max−min) 达 **96 码**。用"最后一个采样"代替中位数，误差可达 **±48 码**。标称行程 `den = raw_底 − zero ≈ 744`（`top.v:2660 TRAVEL_TARE = 12'd744`）⇒ 增益误差 **48/744 = 6.5%** ⇒ 满行程 `pos` 误差 **6.5% × 4095 = 266 码**。而 `top.v:2668` 的触发阈值只允许落在行程的 **5%~12%**（即 37~89 码）——**266 码的标定偏差是触发阈值本身的 3~7 倍**。这正是"同一批键有的灵敏有的要按到底"的机制。
4. 🔴 **顺手挖出的第二颗雷**：`(vmin + vmax) >> 1` 是**12 位加法**。`vmin`/`vmax` 是 `[11:0]` ⇒ 和的位宽 = 12 ⇒ **≥4096 就回绕**。而正常工作点根本不在低半区：`top.v:2069` 记 `触底 1241 ⇒ raw' = 2854`，松手 `1985 ⇒ raw' = 2110`。
   * 底部：`2854 + 2854 = 5708` ⇒ 12 位 = `5708 − 4096 = 1612` ⇒ `>>1 = 806`（正确值 **2854**，差 **2048 码**）
   * 松手：`2110 + 2110 = 4220` ⇒ `4220 − 4096 = 124` ⇒ `>>1 = 62`（正确值 **2110**）
   ⇒ **任何一次正常标定都会踩到回绕**。所以"把 `vote_lo` 接出去"这个显而易见的修法**必须同时加宽加法器**，否则 `806 < zero(2110)` ⇒ `calib` 每个轴都走 `err` ⇒ `'S'` 永远回 `'!'`（R5）。

**怎么改（两处一起改，⛔ 别只改一处）**

```verilog
// ① calib_span.v：加宽加法器 + 把投票值锁进寄存器并引出
reg [12:0] vote_sum;                       // 13 位，够装 2×4095=8190
...
vote_sum <= {1'b0, vmin} + {1'b0, vmax};
vote_lo  <= vote_sum[12:1];                // 等价 (vmin+vmax)>>1，⛔ 不回绕
// ② 新增输出端口，只在发 span 的那一拍有效：
output reg [POS_W-1:0] span_val_o
...
S_WAITBUSY 发脉冲那一段：span_val_o <= vote_lo;
S_DONE / 复位 / abort：span_val_o <= {POS_W{1'b0}};
```
```verilog
// ③ top.v：sp_span 有效那拍把 calib 的 raw 换成投票值（两片各自用同一个投票值不行 ⇒
//    见 P0-3：要么按片各存一份，要么把 span 改成按片单发）
wire [11:0] cal_raw_mux = |sp_span ? sp_span_val : af0_pol;   // u_calib0
```

**收益 / 代价**：收益 = 兑现"多帧投票取值"这条验收要求，把 6.5% 的增益散布压回 ≤1%（`VOTE_TOL/2/744 = 48/744` → 若取中位数则只剩量化误差）。代价 = 13 位加法器（≈13 个 LUT，`vmin+vmax` 本来就在算，只是加宽）+ 12 个 FF（`span_val_o`）+ top 一个 12 位 2:1 mux。
**怎么验证能红**：在 `tb_calib_span.sv` 里加一条 —— 对目标通道送 8 帧，其中 7 帧是 `X`、最后 1 帧是 `X+90`（组内 spread = 90 < `VOTE_TOL=96`，**能过闸**）。断言 `u_calib.den_r == X − zero`（中位数）而**不是** `X+90 − zero`。当前 RTL **必红**（因为值是最后采样）。**现有 tb 测不出来**：`vote_lo` 悬空 + `scan_frame_stable` 给所有通道同一个值（见 P1-6）。
**结构性 or 布局运气**：**结构性功能缺陷**，与布局无关。

---

## P0-2 · `calib_cmd.v`：`GAP_BYTES` 的**单位是"位时间"不是"字节时间"** ⇒ 帧内容忍只有 32 µs（不是文档说的 320 µs）

**位置**：`rtl/w3a/calib_cmd.v:242-245`（同一公式**逐字**复制在 `rtl/w3c/evt_uart_rx.v:114-116`）

```verilog
242:    localparam integer BYTE_CLK_I = (CLK_HZ + BAUD/2) / BAUD;   // ⭐ 四舍五入
243:    localparam integer GAP_CLK_I  = BYTE_CLK_I * GAP_BYTES;
244:    localparam [19:0]  GAP_CLK    = GAP_CLK_I;                  // ⭐ 赋值 ⇒ 自动截断
```
```verilog
265:    wire idle_expired = (idle_q >= GAP_CLK);
```

**为什么是问题（机制 + 数字）**

`CLK_HZ / BAUD` = **一个位的时间**（BAUD = bit/s），**不是**一个字节的时间。`top.v:957-959` 传 `CLK_HZ=50_000_000 / BAUD=500_000 / GAP_BYTES=16`：

* `BYTE_CLK_I = (50_000_000 + 250_000)/500_000 = 100` 拍 = **2 µs = 1 位**
* `GAP_CLK = 100 × 16 = 1600` 拍 = **32 µs**
* 一个字节（8N1 = 10 位）在 500 kbaud 下 = **20 µs** ⇒ **实际容忍只有 1.6 个字节时间**
* 而注释（`:77-79`）和 `evt_uart_rx.v:31/35/37` 都写"`GAP_BYTES` 个**字节**时间"、"容忍 USB/蓝牙分块投递" ⇒ **差了 10 倍**

**后果链（为什么是 P0 而不是 P2）**：`idx_q` 一旦因 >32 µs 的帧内间隔被"空闲归位"清 0（`:462-467`），**剩下的载荷字节就落在"帧外"** ⇒ `byte_is_cmd`（`:394-428`）把它们当命令。18 个命令字母占 256 个字节值的 **7.0%**，其中包含 `'X'`（中止标定）、`'C'`（清 looper 层）、`'R'`（开始录音）、`'S'`（启动 span 标定）、`'M'`（切 Test Mode）。⇒ **一次分块投递就能在演奏中途静默启动一次标定 / 清掉一层 loop**。这正是本模块存在的唯一理由（`:39-42` 自己写的"灾难性"）。

**触发条件（诚实标注）**：主机**一次连续 `write()` 写完整 9 字节** ⇒ 桥芯片把 9 个字节背靠背发出，帧内间隔 ≈ 0 ⇒ **不触发**。一旦主机把一帧拆成两次写、或 USB-CDC 的 1 ms 帧边界插进来（`write(header)` + `write(payload)` 的脚本、逐字节写的 Python、ESP32 侧按 task 分批推），间隔就是 **1 ms ≫ 32 µs** ⇒ **必触发**。

**怎么改（两个模块必须同时改，否则"帧边界理解"错配）**

```verilog
// 一个字节 = 10 位（1 起始 + 8 数据 + 1 停止）
localparam integer BIT_CLK_I  = (CLK_HZ + BAUD/2) / BAUD;   // ⭐ 改名：这是【位】时间
localparam integer BYTE_CLK_I = BIT_CLK_I * 10;             // ⭐ 真正的字节时间
localparam integer GAP_CLK_I  = BYTE_CLK_I * GAP_BYTES;     // 16 字节 = 320 µs
```
* 位宽复核：320 µs = **16000 拍** < `2^20−1 = 1_048_575` ⇒ `[19:0] GAP_CLK` **够用**（`GAP_BYTES` 上限 = 1048575/(100×10) ≈ **1048** 字节，够）。
* 同一个改动必须同步 `evt_uart_rx.v:114-116`，否则一个认为已归位、另一个还在帧内 ⇒ 窗口错配（`:78-79` 自己写的纪律）。
* 若不想动 `evt_uart_rx`：把 `GAP_BYTES` 从 16 改成 **160**（两处 `top.v:903/959/1014` + 两个模块默认值），效果等价 —— 但这只是"用错误的单位凑对数值"，⚠️ 不如改公式。

**收益 / 代价**：收益 = 把帧内容忍从 1.6 字节提到 16 字节（320 µs），覆盖"两次 write"与 USB 帧边界。代价 = 归位慢 288 µs（只在半帧残局时才用到，无感）。**风险**：归位窗口变长 ⇒ 一个"发了半帧就断"的残局会把 `idx_q≠0` 状态多保持 288 µs ⇒ 期间真实命令被当载荷丢掉。⚠️ 需在 `tb_calib_cmd.sv` 里补一条"半帧后 200 µs 内发命令 ⇒ 该命令不得被吞"的判据（当前 `:29 GAP_BYTES=4`，tb 里根本没有覆盖这一档）。
**怎么验证能红**：新增 tb 场景 —— 发 `0xA5`，等 **50 µs**（> 32 µs 但 < 320 µs），再发 `'T'` 与剩下 7 个载荷字节。断言 `tare_req` **不得**出脉冲、`resync_cnt == 0`。当前 RTL：第 50 µs 已经归位 ⇒ `'T'` 当命令 ⇒ **必红**。
**结构性 or 布局运气**：**结构性功能缺陷**（常量算式），与布局无关。

---

## P0-3 · `calib_span.v:537` 广播 `span` 到两片 + `cal_err_any` 聚合 ⇒ **标任何一轴都要两块板同一个通道号同时按到底**；且静止门控只覆盖被选中的那一片

**位置**：`rtl/w3a/calib_span.v:536-541` · `rtl/top.v:1846-1847` · `rtl/top.v:2099` · `rtl/top.v:2490/2508`

```verilog
calib_span.v:536:  else if (sample_valid_i && (sample_ch_i == cur_axis[2:0]) && !cal_busy_i) begin
calib_span.v:537:      span_o      <= {N_ADC{1'b1}};          // ⭐ 两片同拍广播
calib_span.v:538:      cal_ch_o    <= cur_axis[2:0];
```
```verilog
top.v:1846:  wire cal_err_any  = (SPAN_CHECK_BOTH != 0) ? (cal0_err  | cal1_err ) : cal0_err;
top.v:1847:  wire cal_busy_all = (SPAN_CHECK_BOTH != 0) ? (cal0_busy & cal1_busy) : cal0_busy;
top.v:2099:  wire [11:0] sp_raw_sel = sp_cur_axis[3] ? af1_pol : af0_pol;
top.v:2490:      .span      (sp_span[0]),     // u_calib0
top.v:2508:      .span      (sp_span[1]),     // u_calib1   ← 同一个 cal_ch_mux
```

**为什么是问题（机制 + 数字）**

1. **两片是两块不同的板**：`top.v:2746-2748` 原文 ——
   ```verilog
   2746:        // ⭐⭐ **本块扫【全部 `VEL_AXIS_N` 个轴】**（⭐ 2026-09-30：8 → **16** ✅）
   2747:        //   ⭐ **为什么现在是 16**：⭐ 左手板有**两块**（⭐ 各 1 片 `MCP3208`，
   2748:        //      `ADC_N = 2`）⇒ 轴 0~7 = 板 1 · 轴 8~15 = 板 2
   ```
   ⇒ **片 0 的 ch k 与片 1 的 ch k 是两个不同的物理键**。`span_o = {2{1'b1}}` + 共用的 `cal_ch_mux`（`top.v:2373`）意味着：标 `轴 8`（片 1 的 ch0）时，**片 0 的 ch0 也同时被标**。
2. 片 0 的 ch0 若没被按下去，`calib.sv:275 err <= (raw_f <= zero_cc)` 判真（松手位 `raw' = zero`）⇒ `cal0_err = 1` ⇒ `cal_err_any = 1` ⇒ `calib_span.v:586` 走 R5 拒绝 ⇒ **整轴作废**。⇒ 操作者**必须把两块板的"同一个通道号"两个键同时按到底并保持**。16 个轴 = 16 次双键同步按压，而且**回包只给 `'0'/'1'/'2'` 片号**（`top.v:2421-2426`），不会告诉操作者"是另一块板没按"。
3. 🔴 **更硬的一条**：`sp_raw_sel`（`top.v:2099`）**只选一片**（`sp_cur_axis[3]`）⇒ `S_SETTLE`/`S_VOTE` 的"连续稳定 + 离散度 ≤ 96"这套门控**只作用于被选中的那一片**。而 `span` 脉冲打到两片、两片的 `den_r`/`span_r` 都在同一拍写入（`calib.sv:291/294`）。⇒ **另一片的 `den_r` 来自一次【未经任何静止判定】的采样**。`calib.sv:41` 自己记着实测 `raw` 偶发跳 **150~550 码** ⇒ 该片增益误差可达 `550/744 = 74%`。⇒ 这正是"板 2 比板 1 小声/大声"的**完整机制**（`top.v:1813-1819` 只讲到"失败被写成 1.0"那一半）。

**怎么改（二选一，推荐 ①）**

```verilog
// ① 按片单发 —— 一行改完，语义最干净
//   calib_span.v 新增输入 chip_sel_i（= cur_axis[3]），或直接用 cur_axis[3]：
span_o <= (cur_axis[3] == 1'b0) ? {N_ADC{1'b1}} & {{(N_ADC-1){1'b0}}, 1'b1}
                                : {N_ADC{1'b1}} & {1'b1, {(N_ADC-1){1'b0}}};
//   等价的干净写法：span_o <= (cur_axis[3]) ? 2'b10 : 2'b01;
// ② top.v 同步把反馈也按片选：
wire cal_err_sel  = sp_cur_axis[3] ? cal1_err  : cal0_err;
wire cal_busy_sel = sp_cur_axis[3] ? cal1_busy : cal0_busy;
//   .cal_err_i(cal_err_sel) / .cal_busy_i(cal_busy_sel)
```
⚠️ **改动代价（必须知道）**：按片单发之后，**另一片的同一个通道号不会被标**⇒ 必须跑满 16 个轴（每片 8 个）才能把两片都标完。而现在"标 8 个轴就顺便把两片都标了"（代价是必须双键同按）。⇒ 这是**语义取舍**，不是纯 bug：请与用户确认"是否接受 16 次单手按压换掉 16 次双手同按"。
**收益 / 代价**：收益 = 单手可标、且每片都拿到**经静止判定**的行程码（消除 74% 量级的静默增益误差）。代价 = 轴数从 8 次双键变成 16 次单键（时间翻倍，但每次更可靠）。
**怎么验证能红**：新增 tb —— 只驱动 `sample_ch`/`raw` 的**片 0** 通道（片 1 恒定在松手位），跑一个轴；断言 `span_o == 2'b01`、`cal0_err == 0`、`done_cnt_o` 递增。当前 RTL：`span_o = 2'b11` ⇒ 片 1 的 `err=1` ⇒ 拒绝 ⇒ **必红**。
**结构性 or 布局运气**：**结构性功能缺陷**（跨模块接线语义），与布局无关。

---

## P1-1 · `calib_span.v` 的 `S_DONE` 没有 `start_i` 出口，而 `top.v` 仍然回 `'s'`（受理）⇒ **`'S'` 第二次起全部静默无效**

**位置**：`rtl/w3a/calib_span.v:639-643` · `rtl/top.v:1970-1971` · `rtl/top.v:2444`

```verilog
calib_span.v:639:  // ═══ ⭐ 收尾（⭐ 自锁，⛔ 不再发任何 `span`）══════════════
calib_span.v:640:  S_DONE: begin
calib_span.v:641:      need_press_o <= 1'b0;
calib_span.v:642:      span_o       <= {N_ADC{1'b0}};
calib_span.v:643:  end
```
```verilog
top.v:1970:  wire       sp_start_gated = cmd_span_req & at_done;
top.v:1971:  wire       sp_start_rejected = cmd_span_req & ~at_done;
top.v:2444:                          : cmd_span_req     ? 8'h73            // 's' ⭐ 受理 span
```

**为什么是问题（机制 + 数字）**

* `S_DONE` 是**自锁终态**：唯一的出口是 `abort_i`（`:315`）或复位。`start_i` 在 `S_DONE` 里**没有任何消费者**。
* `top.v` 的门控只查 `at_done`（= `calib_autotare` 已标完，`top.v:2023`）—— 这个条件在 **span 扫描期间与扫描结束后都恒为 1**。⇒ 第二次发 `'S'`：`sp_start_gated = 1` ⇒ `start_i` 出脉冲 ⇒ `S_DONE` **无视**它；同时 `rep_byte` 走 `cmd_span_req ? 8'h73` ⇒ **回 `'s'`（"受理"）**。
* 现场含义：`'S'` 只能成功一次；失败重来（`REJECT_MAX=8` 用满 ⇒ `S_DONE`、`done_o=0`）之后、或成功之后想重标，**必须先发 `'X'` 回到 `S_IDLE`**。而回包 `'s'` 让操作者以为"已经在标定"⇒ 上板现象就是"发 `'S'` 只回一个 `s`，再也没动静"，与 `:1089` 记的历史现象同族（**静默失败**，`K-87`/`K-106`）。

**怎么改**（`sp_state` 已经是现成的模块级 wire，`top.v:1957`）

```verilog
// top.v
wire sp_idle_w = (sp_state == 3'd0);                       // calib_span.S_IDLE
wire sp_start_gated    = cmd_span_req & at_done & sp_idle_w;
wire sp_start_rejected = cmd_span_req & ~(at_done & sp_idle_w);
```
（若希望"重发 `'S'` 直接重跑"，另一条路是给 `calib_span` 的 `S_DONE` 加 `if (start_i) state <= S_PROMPT;` + 清 `cur_axis/reject_cnt/done_cnt_o` —— ⚠️ 但那就**必须同时保证 `span_o` 不残留**，风险比上面那一行大。）

**收益 / 代价**：收益 = 把"静默无效"变成可见的 `'!'`，并给出正确的操作指引。代价 = 0（一个 3 位比较 + 一个与门）。
**怎么验证能红**：`tb_calib_span.sv` 里加一条 —— 跑完一次 `done_o=1` 后，再发一次 `start_i`，断言 `busy_o` 重新为 1（或 `top` 侧断言 `sp_start_rejected == 1`）。当前 RTL **必红**。
**结构性 or 布局运气**：**结构性功能/可观测性缺陷**。

---

## P1-2 · `calib_autotare` 的 `skip_mask_o`/`fail_o` 在顶层**从未被读** ⇒ "超时跳过"在板级仍然**静默**

**位置**：`rtl/top.v:1954-1955` · `:2020-2022`（**全 top.v 里 `at_skip`/`at_fail` 只出现在这两处，无任何读者**）

```verilog
top.v:1954:        wire [7:0] at_skip;
top.v:1955:        wire       at_fail;
...
top.v:2020:            .skip_mask_o   (at_skip),
top.v:2021:            .fail_o        (at_fail),
top.v:2022:            .busy_o        (at_busy),      // ← at_busy 同样无读者
```
（对照模块自己的声明，`calib_autotare.v:116-121`：`⭐ 必须有这个可观测指示 —— ⛔ 否则"跳过"是**静默**的（⭐ 全局 `K-106`）`）

**为什么是问题**：这三个输出接进了顶层 `wire`，但**没有任何下游** ⇒ 综合把 `skip_mask_o`/`fail_o`/`busy_o` 的驱动逻辑整个剪掉。⇒ 现场"某个轴被跳过（零点没记）"**完全看不到**，而它的症状是"那个键永远不响 / 永久挂音"（`calib_autotare.v:53-56` 自己写的）。⇒ 模块级已经修好、板级又漏掉 —— 典型的"修在错误的一层"。
**怎么改**（`'V'` 回包已经现成，`top.v:2162-2174 span_probe`）：把 `at_fail`/`at_skip` 编进 `span_probe` 的字节流（`span_probe #(.N_BYTES(9))`，多两个十六进制字符），或在 `rep_byte` 里加一条 `(at_fail & ~at_fail_r) ? 8'h46 /* 'F' */`。⚠️ 改 `span_probe` 的字节数要同步 `'V'` 的协议说明。
**收益 / 代价**：收益 = 把"轴被跳过"变成可观测（`K-106` 闭环）。代价 = 回包多 2 字节（≈40 µs @500 kbaud）。
**怎么验证能红**：`tb_right_adc.sv` 或新 tb 里，把 `WAIT_MS` 调到极小让某轴超时，断言 `fail_o==1` 后**串口回包里出现失败标志**。当前 RTL：无任何回包 ⇒ **必红**。
**结构性 or 布局运气**：**结构性可观测性缺陷**（顶层未接线）。

---

## P1-3 · `calib_cmd` 的 5 个可观测输出在顶层**全部悬空** ⇒ 模块注释"上板先看 `resync_cnt`"不可达

**位置**：`rtl/top.v:947-948` · `:992-996`

```verilog
top.v:947:    wire [15:0] cmd_cnt, cmd_in_frame_cnt, cmd_resync_cnt, cmd_unknown_cnt;
top.v:948:    wire [3:0]  cmd_idx;
...
top.v:992:        .cmd_cnt_o      (cmd_cnt),
top.v:993:        .in_frame_cnt_o (cmd_in_frame_cnt),
top.v:994:        .resync_cnt_o   (cmd_resync_cnt),
top.v:995:        .idx_o          (cmd_idx),
top.v:996:        .unknown_cnt_o  (cmd_unknown_cnt)
```
（`cmd_resync_cnt`/`cmd_in_frame_cnt`/`cmd_unknown_cnt`/`cmd_idx`/`cmd_cnt` 在 top.v 里**只出现这两处**，无读者）

**为什么是问题**：`calib_cmd.v:233` 自己写 `resync_cnt_o // ⭐ 空闲归位次数（饱和）— ⚠️ 上板先看这个`，`:66` 又写"本模块把'命令计数 / 帧内忽略 / 空闲归位'**全做成计数器**，⛔ 不静默"。⇒ 计数器的**唯一出口**是这几个端口，而顶层没有任何回传路径 ⇒ 综合剪掉 ⇒ **上板根本看不到**。结合 P0-2（归位阈值实际只有 32 µs）：操作者既看不到"归位在频繁发生"，也看不到"载荷字母被忽略了几次"，⇒ 这个 P0 在现场**无法被发现**。
**怎么改**：把 `cmd_resync_cnt[7:0]` 与 `cmd_unknown_cnt[7:0]` 编进 `'V'` 回包（或新增 `'W'` 诊断命令），两字节十六进制。
**收益 / 代价**：收益 = 让 P0-2 变成可观测（归位计数一涨就是帧内分块）。代价 = 2 字节回包。
**怎么验证能红**：新 tb 或 `tb_uart_calib_chain.sv` —— 造一次半帧归位，断言"归位计数出现在回包里"。当前 RTL：无路径 ⇒ **必红**。
**结构性 or 布局运气**：**结构性可观测性缺陷**。

---

## P1-4 · `tb_calib_span.sv:533` 的判据被**位宽截断掩盖**（假绿），并且**锁死了 RTL 的截断缺陷**

**位置**：`tb/w3a/tb_calib_span.sv:31` · `:533`（对照 RTL `rtl/w3a/calib_span.v:140` · `:614`）

```verilog
tb:31:    localparam integer AXIS_TOTAL = 16;      // ⭐ = NCH × N_ADC（⚠️ 参数自检要求相等）
tb:533:        chk("done_cnt_o == AXIS_TOTAL when done", done_cnt_o == AXIS_TOTAL[3:0]);
```
```verilog
calib_span.v:140:    output reg  [3:0]       done_cnt_o,     // ⭐ 已标定轴数
calib_span.v:614:        done_cnt_o <= done_cnt_o + 4'd1;
```

**为什么是问题（机制 + 数字）**

* `AXIS_TOTAL = 16` ⇒ `AXIS_TOTAL[3:0] = 4'b0000 = 0` ⇒ 判据实际是 **`done_cnt_o == 0`**。
* 而 `done_cnt_o` 是 **4 位**、被加 16 次 ⇒ **15 之后回绕到 0** ⇒ 判据**因为回绕而通过**。
* ⇒ ① 判据是**假绿**（它想验"标完了 16 个轴"，实际验的是"计数器回绕了"）；② 🔴 它把缺陷**锁死**了：一旦把 `done_cnt_o` 加宽到 5 位（正确修法），这条判据立刻变红（16 ≠ 0）⇒ **修 RTL 必须先改 tb**。这是 `K-91`/`C88` 那一族（位宽 + 判据自身掩盖）在 tb 侧的复发。

**怎么改**

```verilog
// ① RTL：端口加宽到 5 位（AXIS_TOTAL 最大 8×6=48 ⇒ 6 位更稳）
output reg  [4:0]       done_cnt_o,     // ⭐ 0..AXIS_TOTAL
// ② tb：改成完整常量比较，⛔ 不再切片
chk("done_cnt_o == AXIS_TOTAL when done", done_cnt_o == AXIS_TOTAL);
```
**收益 / 代价**：收益 = 判据恢复语义（真能验"16 个轴都标完"）+ 操作者看到正确的轴数。代价 = 1 个 FF + 顶层 `sp_done_cnt` 加宽（`top.v:1949`）—— ⚠️ `ev_axis_ok`（`top.v:2385`）用的是"值变化"，加宽**不影响**它。
**怎么验证能红**：把 RTL 加宽、tb 同步改 ⇒ 必须 PASS；再把 RTL 改回 4 位 ⇒ tb 应 **FAIL**（当前是 PASS ⇒ 证明它是假绿）。
**结构性 or 布局运气**：**结构性判据缺陷**。

---

## P1-5 · `calib_cmd.v:426` 的 `'H'` 臂化状态会被**任何非帧字节穿越** ⇒ 下一帧 `payload[0]` 被吃掉当变调值（静默 ±12 半音）

**位置**：`rtl/w3a/calib_cmd.v:426`（置臂）· `:429-434`（未知字节分支**不清臂**）· `:394-428`（命令分支**不清臂**）· `:451-455`（消费）· `:462-471`（唯一清臂路径：空闲归位）

```verilog
calib_cmd.v:426:                        if (byte_is_trans_abs)  abs_arm_q        <= 1'b1;
...
calib_cmd.v:429:                    end else begin
calib_cmd.v:430:                        // ⚠️ 帧外的其他字节（⭐ 比如 PC 敲的回车/换行）
calib_cmd.v:431:                        //   ⭐ **无害**，但⭐ **必须可观测** ⇒ 计数，⛔ 不静默
calib_cmd.v:432:                        unknown_cnt_o <= sat_inc16(unknown_cnt_o);
calib_cmd.v:433:                        idx_q         <= 4'd0;
calib_cmd.v:434:                    end
```

**为什么是问题（机制 + 数字）**

臂只有三条清除路径：**复位** · **`idx_q==1` 消费掉** · **`idle_expired`（`:462-471`）**。而：

* 发一个**命令字母**（`'X'`/`'S'`/`'T'`/…）走 `:394` 分支 ⇒ `idx_q <= 4'd0`、**`abs_arm_q` 不动**；同时 `rx_done_i` 把 `idle_q` 清 0（`:327-328`）⇒ **空闲归位永远不会触发** ⇒ **臂无限期挂着**。
* 发一个**普通字节**（回车 `0x0D`、换行 `0x0A`、任何非 `0xA5`）走 `:429` 分支 ⇒ 同样不清臂、同样把 `idle_q` 清 0。
* ⇒ 之后**第一帧的 `payload[0]` 被 `:451-455` 吃掉当半音值**，而这一帧是**曲谱事件帧**。
* 后果量级：`fader_gear.v:187 abs_sat = (trans_abs_val_i > 8'd24) ? 5'd24 : trans_abs_val_i[4:0];` ⇒ 一个 `0x40`(64) 的载荷被 clamp 到 **24 = +12 半音**；一个 `0x00` 载荷变成 **−12 半音**（`enc_r=0` ⇒ `transpose_semi_o = −12`）。⇒ **整首曲子被静默升降 12 个半音**，且没有任何回包提示。

**触发场景**：串口助手里手打一个 `H`（想设绝对变调）然后按回车；或 `'H'` 与帧之间的任意一个杂字节；或帧首字节丢失导致 `0xA5` 没被识别（此时载荷字节全部走 `:429` 分支）。

**怎么改**（一行）

```verilog
// 在"帧外"的两个分支里，凡不是置臂本身，一律清臂：
if (byte_is_trans_abs) abs_arm_q <= 1'b1;
else                   abs_arm_q <= 1'b0;   // ⭐ 命令/未知字节 ⇒ 臂作废
```
（更严格的做法：只有"紧邻 `0xA5` 之前那一拍"才允许臂存活 —— 即把臂改成"由帧头 `:391-393` 那一拍检查并消费"。但上面那一行已经把暴露面从"无限期"压到"0 个字节"。）

**收益 / 代价**：收益 = 消除一个"整首变调"级别的静默错误。代价 = 0（多一个 else）。
**怎么验证能红**：`tb_calib_cmd.sv` 加一条 —— `send_byte(H)` ⇒ `send_byte(X)` ⇒ `send_frame(8'd17, ...)`，断言 `trans_abs_req` **不得**出脉冲、`trans_abs_val` 保持。当前 RTL **必红**（`ta_seen` 会 +1）。⚠️ 现有 tb 只测了"`'H'` 紧跟帧"和"一次性"，**没有覆盖穿越路径**（`:383-396`）。
**结构性 or 布局运气**：**结构性功能缺陷**。

---

## P1-6 · `tb_calib_span.sv` 的"通道对齐"判据是**空洞的**：所有通道给同一个值（注释与代码矛盾）

**位置**：`tb/w3a/tb_calib_span.sv:192-209`（驱动）· `:176-186`（判据）

```verilog
tb:192:    // ⭐ 扫一帧：ch0..ch7，⭐ 每通道给【不同值】⇒ ⚠️ 时机错一拍就串位
tb:194:    task scan_frame_stable;
tb:195:        input [11:0] base;
...
tb:200:                sample_ch    = c[2:0];
tb:201:                raw_in       = base;             // ⭐ 每通道同值 ⇒ 帧间稳定
```
```verilog
tb:178:            if (span_o[0]) begin
tb:180:                // ⭐⭐ 判据④：⭐ `span` 那一拍 `sample_ch` 必须 == `cal_ch`
tb:181:                if (sample_ch === cal_ch_o) align_ok  = align_ok + 1;
```

**为什么是问题**：注释说"每通道给不同值"，代码给的是**同一个 `base`** ⇒ 8 个通道的数据完全相同 ⇒ **"数据串位"这一类缺陷（span 用了别的通道的 raw）在这条判据下永远测不出来**。判据只验了"通道**编号**对齐"，没验"**数据**对齐"。而真正会出事的正是数据（`calib.sv:291 den_r <= raw_f - zero_cc`，`raw` 是当拍组合输入）。这正是 `C83`（探针假绿）那一族。

**为什么现在还没出事（顺带查清的机制，很重要）**：`span_o`/`cal_ch_o` 是**寄存器输出**，所以脉冲出现在"条件成立那一拍的**下一拍**"（`calib_span.v:536-541` 全是非阻塞赋值）。本来这是"晚一拍"的隐患 —— **但它是安全的**，因为：
* 片 0：`mcp3208_scanner.sv:124-126` 把 `sample_channel`/`sample_data`/`sample_valid` **同一拍**更新，之后 `STATE_WAIT_PERIOD` 期间不动（`sample_valid` 由 `:91` 默认清 0，通道/数据保持）⇒ 数据**保持 475 µs**。
* 片 1..N：`adc_farm.sv:169-177` 的 `shadow_hold` 在下一个事务的**第一个 `sclk_rise`** 之前不变 ⇒ 同样保持 ≈475 µs。
⇒ 所以"晚一拍"实际有 **475 µs / 20 ns = 23750 倍**的余量。**结论：不是缺陷，但它是"靠总线保持"而不是"靠结构保证"** —— 见 P2-5。

**怎么改**：把 `raw_in = base;` 改成 `raw_in = base + {6'd0, c[2:0], 3'd0};`（每通道差 8 码，远小于 `STABLE_TOL=48` 不破坏稳定判定、又足以区分通道），并在 `span_o[0]` 那拍额外断言 `u_calib.raw === 期望通道的码`。
**收益 / 代价**：收益 = 判据从"编号对齐"升级到"数据对齐"（真能红）。代价 = tb 内一处改动 + 一条新断言。
**怎么验证能红**：把 RTL 的 `sample_ch_i == cur_axis[2:0]` 改成 `== cur_axis[2:0] + 1` ⇒ 新判据应红；再把 `span_o` 改成组合输出（`assign`）⇒ 数据判据仍应绿。
**结构性 or 布局运气**：**结构性判据缺陷**。

---

## P1-7 · `top.v:2010` 在 =1 档是 **36 位接 24 位端口**（实测 warning）⇒ 片 2 永不进静止守卫，且参数一变就静默失效

**位置**：`rtl/top.v:1676` · `:2010`（对照 `rtl/w3a/calib_autotare.v:96`）

```verilog
top.v:1676:        localparam integer ADC_N = (RIGHT_ADC_ENABLE != 0) ? 3 : 2;
top.v:2010:            .sample_data_i (af_data[ADC_N*12-1:0]),
```
```verilog
calib_autotare.v:96:    input  wire [N_ADC*DW-1:0] sample_data_i,
```
**实测证据**：`sim/evidence/tb_right_adc.compile.log:31-33`
```
rtl/top.v:1995: warning: Port 5 (sample_data_i) of module calib_autotare expects 24 bit(s), given 36.
rtl/top.v:1995:        : Pruning 12 high bits of the expression.
```

**为什么是问题**

* `=1` 档 `ADC_N=3` ⇒ 表达式宽 36 位、端口 24 位（`N_ADC=2`）⇒ **高位 12 位（片 2）被剪掉**。⇒ 静止守卫**只看片 0/片 1**，片 2（右手板）**永不被守卫**。
* 今天**恰好无害**：片 2 没有 `calib` 实例（`top.v:2479/2499` 只有 `u_calib0/u_calib1`）、`tare_o` 也只有 2 位 ⇒ 片 2 本来就不做 `tare`（它走 `right_analog_ctrl`，`top.v:1736/1749`）。
* 🔴 但这是**"参数一变就静默失效"**的形态：哪天把 `calib_autotare.N_ADC` 改成 3（看起来是"跟上 ADC_N"的显然修法），端口变 36 位、`tare_o` 变 3 位 ⇒ 而 `top.v:1870` 的 `wire [1:0] at_tare;` 与只有两个 `calib` 实例 ⇒ **再截断一次**，而且这次是 `tare_o` 被截断（片 2 的 tare 丢失）。⇒ 两次截断方向相反、都不报错。
* 且**综合门抓不到**：这是 iverilog 的 warning，不是 ERROR ⇒ "综合 ERROR=0"这道门放行；而 `tb_right_adc` 7/7 PASS（`README.md:222`）⇒ **四道门全过**。

**怎么改**（显式落定，⛔ 不要靠表达式宽度）

```verilog
// top.v：把"守卫覆盖几片"写成显式常量，并在 PARAM 自检里守它
localparam integer GUARD_ADC_N = 2;                      // ⭐ 与 u_autotare.N_ADC 严格一致
...
.sample_data_i (af_data[GUARD_ADC_N*12-1:0]),            // 24 位，无截断
```
**收益 / 代价**：收益 = 消掉 warning + 消除"改 N_ADC 就静默截断"的陷阱。代价 = 0（纯常量）。
**怎么验证能红**：`tb_right_adc.sv` 的编译日志里 `grep -c "Pruning 12 high bits"` 必须为 **0**；并加一条 `initial` 断言 `calib_autotare` 实例的 `N_ADC == GUARD_ADC_N`（可用 `$display` + PARAM_OK 风格）。
**结构性 or 布局运气**：**结构性接线缺陷**（当前功能影响为零，但是陷阱）。

---

## P2-1 · `calib.sv` 的 `dlim` 漏掉第三种情形（`span_rd > MAX_TRAVEL`）⇒ **静默压缩满行程**

**位置**：`rtl/drivers/calib.sv:337-343`（对照注释 `:331-339` 自称"两种情形都安全"）

```verilog
337:    wire [DW:0] dcode  = (raw_f > zero_rd) ? (raw_f - zero_rd) : {(DW+1){1'b0}};
340:    localparam [DW:0] MAXT = MAX_TRAVEL;
341:    wire [DW:0] dlim = ((span_rd != {(DW+1){1'b0}}) && (span_rd < MAXT))
342:                     ? span_rd : MAXT;
343:    wire [DW:0] dclamp = (dcode > dlim) ? dlim : dcode;
```

**为什么是问题（机制 + 数字）**：注释只分析了 `span_rd == 0` 与 `span_rd != 0` 两种情形，**漏了 `span_rd > MAX_TRAVEL`**。此时 `span_rd < MAXT` 为假 ⇒ `dlim = MAXT = 1023 < span_rd` ⇒ **夹到比真实行程更小的值**：

* 增益 `gain = (4095<<8)/span_rd`，`pos = dclamp × gain >> 8 ≤ MAXT × 4095/span_rd`
* 例：`span_rd = 1500`（换更大行程的磁铁/板）⇒ `pos_max = 1023 × 4095/1500 = 2793` = **满量程的 68%**
* ⇒ 该轴**永远到不了 4095**；而 `top.v:2717-2724` 的触发/释放阈值是按**百分比**校验的（`EVT_TRIG_TH/TRAVEL_TARE ∈ [5%,12%]`）⇒ 阈值对应的物理深度被放大 `4095/2793 = 1.47 倍`（20% 阈值实际要按到 29% 行程）⇒ "手感变沉"。
* 且**没有任何自检**：`calib_span.v:658` 的 `PARAM_OK` 与 `top.v:2680` 的 `TRAVEL_TARE > 1023` 都不覆盖 `span_rd`（它是运行期测出来的）。

**怎么改**：`dlim` 的语义应该是"**标定过就用真实行程，没标定才退回硬上界**"：

```verilog
wire [DW:0] dlim = (span_rd != {(DW+1){1'b0}}) ? span_rd : MAXT;
```
（`MAX_TRAVEL` 的 K-153 保护职责由"未标定"这一支承担；标定过的轴，其真实行程本身就是正确的上界。若担心"标定值被写坏"，正确做法是加一条 `span_rd > 4095` 的饱和守卫，而不是把它压到 1023。）

**收益 / 代价**：收益 = 换板/换磁铁后 `pos` 仍覆盖满量程（阈值语义不漂）。代价 = 0（一个 mux 的输入少一个比较器，**LUT 反而少**）。
**怎么验证能红**：`tb_calib.sv` 加一条 —— `span` 时给 `raw = zero + 1500`，之后喂 `raw = zero + 1500`，断言 `out_val == 4095`（或至少 `> 2793`）。当前 RTL 给 **2793** ⇒ **必红**。
**结构性 or 布局运气**：**结构性功能缺陷**（常量/边界语义），与布局无关。

---

## P2-2 · `calib_span.v` 的 `REJECT_MAX`：**没有参数自检 + 4 位切片 + 比较用旧值** ⇒ 三个独立陷阱

**位置**：`rtl/w3a/calib_span.v:409` · `:442` · `:468` · `:528` · `:590` · `:630`（六处同一形态）· `:658-662`（`PARAM_OK` 不含 `REJECT_MAX`）

```verilog
408:                        reject_cnt <= reject_cnt + 4'd1;
409:                        if (reject_cnt >= REJECT_MAX[3:0]) begin
```
```verilog
658:    localparam PARAM_OK = (VOTE_N >= 2) &&
659:                          (AXIS_TOTAL == NCH * N_ADC) &&
660:                          (VOTE_TOL > 0) &&
661:                          (STABLE_NEED > 0) &&
662:                          (WAIT_TIMEOUT_CLK > 0);
```

**为什么是问题（三个独立机制，都带数字）**

1. **切片截断**：`REJECT_MAX` 是 `integer`，被切到 `[3:0]`。`REJECT_MAX = 16` ⇒ `[3:0] = 0` ⇒ `reject_cnt >= 0` **恒真** ⇒ **第一次超时就直接 `S_DONE` 放弃**（看起来像"标定完全不工作"）。而 `PARAM_OK` **没有**守 `REJECT_MAX` ⇒ 静默。
2. **比较用旧值**：`reject_cnt` 与比较在**同一拍**，非阻塞赋值 ⇒ 比较读的是**加之前**的值。⇒ 默认 `REJECT_MAX=8` 时实际允许 **9 次**拒绝才放弃（`reject_cnt` 从 0 走到 8 需要 9 次进入该分支）。文档 `:67` 写"最多拒绝 8 次" ⇒ 差 1。
3. **计数是全扫描累计、不是每轴**：`reject_cnt` 只在 `S_IDLE` 的 `start_i`（`:341`）、`abort`（`:321`）、复位里清；**成功标完一轴不清**（`:614-621` 只加 `done_cnt_o`）。⇒ 16 个轴共享 8 次拒绝预算；每次拒绝最坏要耗掉 `WAIT_TIMEOUT_CLK = 50M` 拍 = **1 秒** ⇒ 最坏 **9 秒**才放弃，且放弃时 `done_o=0`（全盘作废，需 `'X'` 重来 —— 见 P1-1）。

**怎么改**

```verilog
// ① 参数自检补上
localparam PARAM_OK = ... && (REJECT_MAX > 0) && (REJECT_MAX <= 15);
//   （并把端口/比较改成显式宽向量，避免 [3:0] 切片）
localparam [3:0] REJECT_MAX_V = REJECT_MAX;
// ② 语义改成"到达上限才放弃"，与文档一致：
if (reject_cnt + 4'd1 >= REJECT_MAX_V) begin ... S_DONE ... end
// ③ 若想"每轴独立预算"，在 S_PROMPT 的推进那一拍加 reject_cnt <= 4'd0;
//    （⚠️ 要先确认这是不是用户要的语义 —— 现在是"全局预算"）
```
**收益 / 代价**：收益 = 消除"`REJECT_MAX=16` 立刻放弃"的静默陷阱 + 文档与行为对齐。代价 = 0。
**怎么验证能红**：`tb_calib_span.sv` 加两条：① `REJECT_MAX(16)` 例化一个 DUT，断言第一次拒绝后**不得** `done`（当前会立刻 `done` ⇒ 红）；② 断言放弃恰好发生在第 `REJECT_MAX` 次拒绝。
**结构性 or 布局运气**：**结构性边界缺陷**。

---

## P2-3 · `calib_autotare.v:204` 的 `(still_cnt >= STILL_N)` 在当前参数下**完全冗余**

**位置**：`rtl/w3a/calib_autotare.v:204-205`

```verilog
204:        enough_r = still_r && ((still_cnt[sample_ch_i] >= STILL_N)
205:                            || ((still_cnt[sample_ch_i] + 1'b1) >= STILL_N));
```

**为什么是问题（机制 + 数字）**

* `top.v:1992` 传 `STILL_FRAMES = 4` ⇒ `SCW = $clog2(5) = 3`（`:169`）⇒ `still_cnt` 是 3 位、**饱和在 `STILL_N = 4`**（`:234-237`）。
* 逻辑上 `(x+1) >= N` 覆盖了 `x >= N`（只要加法不回绕）。`x` 最大 = 4 ⇒ `4+1 = 5`（3 位装得下）⇒ **第一项永远被第二项包含** ⇒ 它是一个**重复比较器 + 冗余项**（会被综合折叠，但它是"重复逻辑"的实证，也是误读风险）。
* 🔴 **唯一的例外**：`STILL_FRAMES = 7` ⇒ `SCW = 3`、`STILL_N = 3'd7`、`still_cnt` 饱和到 7 ⇒ `7+1 = 0`（3 位回绕）⇒ 第一项才**承重**。⇒ 这个"冗余"是**参数相关**的，所以⛔ 不能直接删第一项，而应该**把回绕消除掉**。

**怎么改**

```verilog
// 用 4 位做加法，彻底消除回绕 ⇒ 第一项可安全删除（或保留也不再有参数相关行为）
wire [SCW:0] still_next = {1'b0, still_cnt[sample_ch_i]} + 1'b1;
enough_r = still_r && (still_next >= STILL_N);
```
**收益 / 代价**：收益 = 语义与参数无关、少一个比较器、少一处误读。代价 = 加法器宽 1 位（≈1 LUT）。
**怎么验证能红**：`tb_calib_still_guard.sv` 加一条 `STILL_FRAMES(7)` 的 DUT，断言"第 7 帧静止才捕获"（当前 `7+1=0` ⇒ 靠第一项救回来 ⇒ 行为正确；改成上面的写法后行为不变，但**删掉第二项**的变异体应当变红）。
**结构性 or 布局运气**：**结构性冗余**（零时序收益，但消除参数相关的隐式行为）。

---

## P2-4 · `calib_span` 的三个等待状态**共用同一个 `wait_clk_cnt` 且不清零** ⇒ "每态 1 秒上界"实际是"三态合计 1 秒"，极端情形产生**假 R4 拒绝**

**位置**：`rtl/w3a/calib_span.v:402-405`（S_SETTLE）· `:435-438`（S_VOTE）· `:519-523`（S_WAITBUSY）· `:459-483`（S_FIRE **不加也不清**）

```verilog
402:                    if (wait_clk_cnt != {WCW{1'b1}})
403:                        wait_clk_cnt <= wait_clk_cnt + 1'b1;
...
435:                    if (wait_clk_cnt != {WCW{1'b1}})
436:                        wait_clk_cnt <= wait_clk_cnt + 1'b1;
...
519:                    if (wait_clk_cnt != {WCW{1'b1}})
520:                        wait_clk_cnt <= wait_clk_cnt + 1'b1;
```

**为什么是问题（机制 + 数字）**

* `wait_clk_cnt` **只在 `S_PROMPT` 第 2 拍清 0**（`:382`）与复位/abort 里清。`S_SETTLE → S_VOTE → S_FIRE → S_WAITBUSY` 是**一条直链**，中间**没有任何清零**。
* 而 `S_SETTLE` 与 `S_VOTE` 都在**同一个计数器上累加**（`:402`、`:435`）。⇒ 三个状态共享 50,000,000 拍（1 s）的预算。
* 正常情形影响很小（`STABLE_NEED=8` + `VOTE_N=8` ⇒ 约 18 帧 × 25000 拍 = **45 万拍**，只吃掉 0.9%）。**但极端情形会致命**：若 `S_SETTLE` 用掉 49.9M 拍（≈0.998 s，仍然"成功"）而 `S_VOTE` 只用 0.05M，则进入 `S_WAITBUSY` 时计数已 ≈49.95M ⇒ **只剩 5 万拍 = 1 ms = 2 个采样帧** ⇒ 而 `S_WAITBUSY` 还需要"目标通道的帧 + `!cal_busy_i`"⇒ 极易在 2 帧内凑不齐 ⇒ 报 **R4 `'b'`（等帧超时）**，而这个拒绝的理由是**假的**（帧其实在正常来）。
* 文档 `:78-81` 写"默认 50_000_000 拍 = 1 秒 @50 MHz"给的是**每个等待状态**的口径 ⇒ 与实现不符。

**怎么改**（进每个等待状态时清一次）

```verilog
// S_FIRE → S_WAITBUSY 的那一拍：
vote_lo <= ...;  wait_clk_cnt <= {WCW{1'b0}};   // ⭐ 让 S_WAITBUSY 拿到完整预算
// S_SETTLE → S_VOTE 的那一拍：
state <= S_VOTE;  wait_clk_cnt <= {WCW{1'b0}};
```
**收益 / 代价**：收益 = 三态各自拿到完整的 1 s 上界（契约与实现一致），消除假 R4。代价 = 0（只是把已有赋值挪个位置）。
**怎么验证能红**：`tb_calib_span.sv` 里把 `WAIT_TO` 设成"刚好够 settle+vote、但不够 WAITBUSY"的值（例如 3000），断言**不得**出现 R4 拒绝；当前 RTL 会红。
**结构性 or 布局运气**：**结构性功能缺陷**。

---

## P2-5 · `calib.sv` 的乘法**不按 `valid` 门控** ⇒ 每个时钟都在算（含片 ≥1 在下一事务里的移位垃圾）；且"数据保持"只靠帧间隔

**位置**：`rtl/drivers/calib.sv:369-373`（对照 `:337` 与 `adc_farm.sv:169-177`）

```verilog
369:            v_r   <= valid;
370:            ch_r  <= ch;
373:            prod_r <= dclamp * gain_rd;
```
```verilog
adc_farm.sv:173:        end else if (cs_active && sclk_rise) begin
adc_farm.sv:175:                shadow_hold[gh] <= {shadow_hold[gh][22:0], miso_sync[gh]};
```

**为什么是问题（机制 + 数字）**

1. `prod_r <= dclamp * gain_rd` **无条件**执行（只要不复位）⇒ 即使 `valid = 0`，DSP 也在**每个 20 ns 周期**吃进 `dclamp`/`gain_rd`。⇒ 两个 `calib` 实例各一个 DSP，**每秒 5000 万次无意义翻转**（`dclamp` 来自 `raw`，`raw` 在帧间是**部分移位的垃圾**）。⇒ 纯动态功耗与开关噪声（对一个 78~81% CLS 的拥挤设计不是零代价）。
2. 片 ≥1 的 `raw` 来自 `shadow_hold`（`adc_farm.sv:191`）—— 它**只在 `cs_active && sclk_rise` 时移位、不清零**。⇒ "帧间保持"这句话只在"下一个事务还没开始"这段时间成立；一旦下一事务的第一个 `sclk_rise` 到来，低 12 位就开始混入**新通道的位**（≈475 µs 后）。⇒ **`calib` 拿到的片 1/片 2 数据没有结构性的保持保证，只有一个"帧间隔余量"**（见 P1-6 的同一机制）。
   * 好消息：`v_r <= valid` 保证 `out_valid` 只在正确那一拍有效 ⇒ **功能上不错**。
   * 坏消息：`S_WAITBUSY` 发 `span` 是**寄存器输出**（`calib_span.v:537`，晚一拍），`calib.sv:291 den_r <= raw_f - zero_cc` 用的正是那一拍的 `raw` ⇒ **正确性依赖上面这个"475 µs 余量"**（余量 ≈ 23750 倍，安全，但是隐式契约）。

**怎么改**（两条都是低风险）

```verilog
// ① 用 valid 门控乘法（省动态功耗；⛔ 不改功能，因为 out_valid 已经门控了输出）
if (valid) prod_r <= dclamp * gain_rd;
// ② 让 adc_farm 的打包数据变成"只在 sample_valid 更新"的寄存器（显式保持，替代隐式余量）
//    在 adc_farm 里给 sample_data_packed 加一级 valid 使能的保持寄存器
```
**收益 / 代价**：收益 = ① 省 DSP 的动态翻转（功耗/噪声）；② 把"数据保持"从"余量"变成"结构"。代价 = ① 一个 valid 使能（0 LUT）；② `N_ADC × 12 = 24` 个 FF（`N_ADC=2`）。
**怎么验证能红**：① 功能判据不变（`tb_calib.sv` 必须全绿）；② 在 `tb_calib.sv` 里"在帧间把 `raw` 改成一个野值"（模拟下一事务的移位垃圾），断言 `out_val` 在 `valid` 那拍仍是**本帧**的值 —— 当前 RTL 也能过（靠余量），所以这条判据只能防"把余量吃掉的未来改动"。
**结构性 or 布局运气**：**结构性（功耗 + 隐式契约）**，不是长路径。

---

## P2-6 · `calib.sv:303` 的"商为零 ⇒ gain=1"分支：**在当前参数下不可达**，但在边界上会**写错**（该饱和却给 1）

**位置**：`rtl/drivers/calib.sv:300-305`（对照 `:203` `ITER=24`、`:218` `DIVIDEND = FULL << 8`）

```verilog
300:            if (cnt_r == ITER_CNT) begin
302:                busy <= 1'b0;
303:                if (quo_r[GW-1:0] == 0)         gain_r[div_ch] <= 1;
304:                else if (quo_r[23:GW] != 0)     gain_r[div_ch] <= {GW{1'b1}};  // 饱和
305:                else                            gain_r[div_ch] <= quo_r[GW-1:0];
```

**为什么是问题（机制 + 数字，含可达性证明）**

* 第一分支的本意是"商为 0 ⇒ 避免增益为 0"，但它**只检查低 16 位**（`GW=16`）。
* **不可达性证明**：`DIVIDEND = 4095 << 8 = 1_048_320`，`den_r = raw − zero ≤ 4095` ⇒ `quo = DIVIDEND/den ≥ 1_048_320/4095 = **256.0**` ⇒ 商**永远 ≥ 256**（这也正好解释了 `gain_rd` 的默认值 `1<<8 = 256` 为什么是下界）。⇒ "商为 0"**永不发生** ⇒ 第一分支**永不执行它的本意**。
* **它反而会在边界上写错**：当 `quo` 是 65536 的整数倍时（低 16 位 = 0 而高位 ≠ 0），第一分支命中 ⇒ 写 `gain = 1`（**应为饱和 0xFFFF**）。⚠️ 我算了可达性：`quo = 1_048_320/den`，要 `2^16 | quo` 需 `den | 4095/2^8`，而 4095 是奇数 ⇒ **当前 `FULL=4095` 下不可达**。但 `FULL` 是 `parameter`（`top.v:2479/2499` 没覆盖 ⇒ 4095），一旦有人改 `FULL` 或 `GW`，这个"不可达"立刻变成"静默给 1.0"。
* 顺带：`ITER = 24` 对 20 位的被除数**过度迭代 4 拍**（`2^20 = 1_048_576 > 1_048_320`）⇒ `busy` 多高 4 拍（80 ns/轴，16 轴 = 1.28 µs，可忽略，但它是"常量没折叠干净"的实证）。

**怎么改**

```verilog
// ① 把"零商保护"写成真正的零比较（或直接删掉 —— 它不可达）
if (quo_r[23:GW] != 0)  gain_r[div_ch] <= {GW{1'b1}};   // 饱和优先
else                    gain_r[div_ch] <= quo_r[GW-1:0];
// ② ITER 按被除数实际位宽定：ITER = $clog2(FULL<<8) + 1  （4095<<8 ⇒ 20 ⇒ ITER=20）
```
**收益 / 代价**：收益 = 消除"边界上给 1.0 而不是饱和"的静默错，并把 `busy` 缩短 4 拍。代价 = 0（少一个比较器）。
**怎么验证能红**：⚠️ **用默认参数（`FULL=4095`）造不出红的激励** —— `den = 1` 时商 = `1_048_320 = 0x0FFF00`，低 16 位 = `0xFF00 ≠ 0` ⇒ 走的是**饱和**分支（行为正确）。要触发第一分支必须让商是 65536 的整数倍，而上面已证**不可达**。
⇒ 唯一的红法：用**参数化 DUT**（例如 `calib #(.FULL(65536), .GW(16))`，此时 `DIVIDEND = 65536<<8 = 16_777_216`，`den = 256` ⇒ 商 = 65536 = `0x010000`，低 16 位 = 0、高位 ≠ 0）⇒ 断言 `gain_r == 16'hFFFF`（饱和），当前 RTL 会给 **1** ⇒ **必红**。
⇒ 结论（诚实标注）：**在当前交付参数下这是"不可达的死分支 + 参数化陷阱"，不是可触发的错**；它的价值在于"改 `FULL`/`GW` 时会静默给 1.0"，所以要么删掉第一分支，要么用上面的参数化 DUT 把它钉住。
**结构性 or 布局运气**：**结构性死逻辑 + 参数化陷阱**（当前零功能影响）。

---

## P2-7 · `af_sample_ch[2]` 高扇出 486 / worst slack **2.028 ns**（=0 档）→ 3.331 ns（=1 档）：**布局运气主导的第二梯队**，但它就是 `calib` 链能拿到的最紧证据

**位置/证据**：`evidence/h5/base-T5-55p060/Gowin2026_tr_content.html:29864-29867` 与 `sim/evidence/rightboard-vibrato-fix-20261008/timing-rightadc-fixed.html:26876-26879`

```
=0 档（55.060 MHz）: 486 | g_sound.af_sample_ch[2] | 2.028 | 4.641
=1 档（≈57.0 MHz） : 490 | g_sound.af_sample_ch[2] | 3.331 | 3.929
（对照 =0 档同表：clk_d 16957 / rst_n_sync 13958 / tick_audio 1415）
```

**怎么解读（含"结构性 vs 布局运气"的判据）**

* 该锥体的最差端点 slack 在 **2.028 → 3.331 ns** 之间摆动（**+64%**），而**同一根网络**的最大延时从 **4.641 → 3.929 ns** 同步变化（**−15%**）。两次 PnR 的 RTL 差异只有 `RIGHT_ADC_ENABLE` 与颤音流水。⇒ **差异的主因是这根网的布线**（4.641 ns 的网络延时占 18.181 ns 预算的 **25.5%**）⇒ **布局运气主导，不是结构性长路径**。
* 但它是本批 4 个模块能拿到的**最紧**数字：`af_sample_ch` 正是 `u_calib0.ch`/`u_calib1.ch`（LUTRAM 地址）、`u_calib_span.sample_ch_i`、`u_calib_autotare.sample_ch_i` 的输入（`top.v:2257/2483/2503/1999`）。⇒ **2.028 ns 的 slack 意味着该锥体里有端点只差 2 ns**，而 `calib` 的"LUTRAM 地址 → 读 → 比较/减 → 夹紧 → DSP"是这条锥体里最长的一支（见下）。
* **明确不含**：`u_calib0/u_calib1/u_calib_span/u_calib_autotare` 在两档的 **Top-25 setup 表里一次都没出现**（只在 Recovery 表出现，slack **13.044 ns**，`impl/pnr/Gowin2026_tr_content.html:910/921`）⇒ **它们不是 Fmax 限制者**。
* ⚠️ 这份报告只给"锥体最差 slack"，**不点名是哪一条路径** ⇒ 我**不下"就是 calib"的结论**（无证据不写）。要钉死它，需要在 PnR 后跑一次 `report_timing -max_paths 200` 并按 `u_calib` 过滤。

**怎么改/怎么守**：把这条网做成**每次 PnR 后的机械判据**（`sim/gowin_build.ps1` 里 grep 高扇出表）：

```powershell
# 判据：af_sample_ch[2] 的 worst slack ≥ 1.0 ns 且 max delay ≤ 5.5 ns
Select-String -Path impl\pnr\Gowin2026_tr_content.html -Pattern 'af_sample_ch\[2\]' -Context 0,2
```
若某次 PnR 掉到 < 1.0 ns ⇒ 优先查"是不是 `calib` 的 LUTRAM 地址读被拉长"（可用 `set_max_delay` 分组或给 `ch` 打一拍）。
**收益 / 代价**：收益 = 把"第二梯队"变成可监控量（而不是每次靠运气）。代价 = 0（只加一条日志判据）。
**结构性 or 布局运气**：**布局运气主导**（同源重跑摆动 64%），但**余量只有 2 ns 是事实**。

---

## P3-1 · `vote_hi` 是**彻底的死寄存器**（声明 + 复位，从不赋值、从不读）

**位置**：`rtl/w3a/calib_span.v:215` · `:271`

```verilog
215:    reg [11:0] vote_lo, vote_hi;
271:            vote_hi     <= 12'd0;
```
**机制**：`vote_hi` 全文件只有这两处（见 P0-1 的 grep 结果）。⇒ 综合会剪掉，但**源码里留着它**会让人以为"投票有上下界两个结果"。⇒ 12 个 FF 的噪声 + 误读风险。
**怎么改**：删掉 `vote_hi`（`vote_lo` 见 P0-1 要**接出去**）。
**验证**：综合报告里不应出现 `vote_hi`（`report` 里 grep）。
**结构性/布局**：结构性噪声，零时序影响。

---

## P3-2 · `calib_span.v:645` 的 `default` 分支**静态不可达**（8 个状态用满 3 位编码）；`calib_autotare` 的 `default` 才是**可达**的

**位置**：`rtl/w3a/calib_span.v:156-163` + `:645`；对照 `rtl/w3a/calib_autotare.v:134-136` + `:325`

```verilog
calib_span.v:156:    localparam [2:0] S_IDLE    = 3'd0;
... (S_PROMPT 1 · S_SETTLE 2 · S_VOTE 3 · S_FIRE 4 · S_WAITBUSY 5 · S_NEXT 6 · S_DONE 7)
calib_span.v:645:                default: state <= S_IDLE;
```
```verilog
calib_autotare.v:134:    localparam [1:0] ST_WAIT  = 2'd0;
calib_autotare.v:135:    localparam [1:0] ST_SWEEP = 2'd1;
calib_autotare.v:136:    localparam [1:0] ST_DONE  = 2'd2;     // ← 2'd3 未用
```
**机制**：`calib_span` 的 `state` 是 `[2:0]`、8 个编码**全部**被 `S_IDLE..S_DONE` 用掉 ⇒ `default` 在**结构上永不进入**（是防御性死代码，无害但会让人误以为"有非法态恢复"）。`calib_autotare` 的 `state` 是 `[1:0]` 而只用 3 个编码 ⇒ `2'd3` **未覆盖** ⇒ 它的 `default: state <= ST_WAIT;`（`:325`）**是可达的**（SEU/毛刺/未初始化时兜底）⇒ 这一条**必须保留**（且 `tare_o` 已由 `:224` 的默认赋值清零 ⇒ 兜底时不漏 `tare`）。
**怎么改**：`calib_span` 的 `default` 保留（零代价、防未初始化）；若要更省，可写成 `default: state <= S_IDLE;` 并接受它是死代码。**不必动**。
**验证**：无（不需要判据）。
**结构性/布局**：结构性死代码，零影响。

---

## P3-3 · `calib_span` 的 `S_SETTLE` 用**旧** `stable_cnt` 比较 ⇒ 实际需要 `STABLE_NEED + 1` 帧

**位置**：`rtl/w3a/calib_span.v:419-426`

```verilog
419:                            if ((raw_i > prev_val ? raw_i - prev_val : prev_val - raw_i) < STABLE_TOL)
420:                                stable_cnt <= stable_cnt + 6'd1;
421:                            else
422:                                stable_cnt <= 6'd0;      // ⚠️ 动了 ⇒ 重新计
423:                        end
424:                        prev_val <= raw_i;
425:                        if (stable_cnt >= STABLE_NEED[5:0])
426:                            state <= S_VOTE;             // ⭐ 稳住了 ⇒ 开始投票
```
**机制 + 数字**：`:425` 读的是**加之前**的 `stable_cnt`。第 1 帧 `prev_val == 12'hFFF` 哨兵 ⇒ 只写 `prev_val`、不加计数（`:418`）。⇒ 从第 2 帧开始每帧 +1，第 k 帧后 `stable_cnt = k−1`。要满足 `stable_cnt >= 8` 需要 `k−1 = 8` ⇒ `k = 10` ⇒ **需要 10 个连续帧**，而 `top.v:284` 传 `SPAN_STABLE_NEED = 8`，注释 `:60` 写"8 帧 ≈ 4 ms"。⇒ 实际是 **10 帧 = 5 ms**（差 1 帧 + 哨兵 1 帧）。⇒ 操作者等待比设计值多 1 ms（可感但不致命）。
**怎么改**：`if (stable_cnt + 6'd1 >= STABLE_NEED[5:0])`（并同步 `:60` 的注释），或把哨兵帧也算一次。
**收益/代价**：收益 = 行为与文档一致（4 ms）。代价 = 0。
**验证**：`tb_calib_span.sv` 加一条"从第 1 帧算起恰好 N 帧进入 `S_VOTE`"的计数判据。
**结构性/布局**：结构性边界差 1。

---

## P3-4 · `done_cnt_o` 4 位回绕 + 在**除法器还没跑完**就置 `done`（提前 25 拍）

**位置**：`rtl/w3a/calib_span.v:612-621`（对照 `calib.sv:299-305`）

```verilog
612:                    else if (cal_busy_i) begin
613:                        //   ⭐ 本轴成功 ⇒ 计数 + 进入下一轴
614:                        done_cnt_o <= done_cnt_o + 4'd1;
615:                        if (cur_axis == AXIS_TOTAL[3:0] - 4'd1) begin
616:                            state  <= S_DONE;
617:                            done_o <= 1'b1;
```
**机制 + 数字**：① `done_cnt_o` 4 位、加 16 次 ⇒ 回绕到 0（见 P1-4）。② `cal_busy_i` 在 `span` 后**第 2 拍**就升起（`calib.sv:288 busy <= 1'b1`），而除法器还要 **25 拍**才写完 `gain_r`（`ITER=24` + 写回）⇒ 最后一轴 `done_o=1` 时，**该轴的增益还没落盘**（提前 **25 拍 = 500 ns**）。⇒ 若操作者立刻发 `'N'`（回传 `pos`）或 `'P'`，可能读到**未写完的增益**。
**怎么改**：① 端口加宽到 5 位（同 P1-4）；② 判据改成"`busy` 起过 **并且** 已落"—— 即把 `S_NEXT` 的"成功"条件改成 `span_sent_r2 && ~cal_busy_i && cal_busy_seen_r`（用一个 `busy_seen` 标志），或干脆等到 `~cal_busy_i` 且 `err==0`。
**收益/代价**：收益 = `done_o`/轴计数与"增益已落盘"严格同拍，消除 500 ns 的读取竞态。代价 = 1 个 FF + 判据复杂一点（⚠️ 会与 P1-1 的"必须重发 `'X'`"耦合，改动要一起测）。
**验证**：`tb_calib_span.sv` 断言"`done_o` 那一拍 `u_calib.gain_r[cur]` 已是最终值"。
**结构性/布局**：结构性时序契约（不是长路径）。

---

## P3-5 · `calib_autotare.v` 在**边沿块**里用阻塞赋值写组合量（`dlt_r`/`still_r`/`enough_r`）—— 依赖"先赋值后读"的纪律

**位置**：`rtl/w3a/calib_autotare.v:179-205`

```verilog
179:    reg [DW-1:0]  dlt_r;                 // ⭐ 本拍算出的帧间差 = **所有片的【最大】值**
180:    reg           still_r;               // ⭐ 本拍该通道是否"静止"
181:    reg           enough_r;              // ⭐ 本拍静止帧数是否已达 `STILL_N`
...
193:        dlt_r = {DW{1'b0}};
194:        for (g = 0; g < N_ADC; g = g + 1) begin
...
203:        still_r  = seen_r[sample_ch_i] && (dlt_r <= STILL_TOL_V);
204:        enough_r = still_r && ((still_cnt[sample_ch_i] >= STILL_N)
```
**机制**：这三个量在 `always @(posedge clk)` 里用阻塞赋值 ⇒ 它们**要么被综合成组合网、要么被当成 FF**。当前**正确**，因为①`dlt_r` 每拍先无条件 `= 0` 再累加（**无未赋值分支 ⇒ 不会推 latch**）②`still_r`/`enough_r` 在**同一块内、赋值之后**才被读 ⇒ 读到的是"本拍新值"。⇒ 一旦将来在 `:194-202` 的 `if/else` 里加一条**不赋值 `dlt_r`** 的分支（或提前读 `dlt_r`），语义立刻变成"上一拍的值"（`still_cnt` 的判定会晚一拍）⇒ **静默错**。
**怎么改**（零代价、消除脆弱性）：把 `:188-205` 拆成独立的 `always @(*)` 组合块，`dlt_r`/`still_r`/`enough_r` 改 `wire`/`reg` + 连续赋值。
**收益/代价**：收益 = 语义不再依赖书写顺序；综合结果**逐位不变**（可用 `tb_calib_still_guard` 6 条判据锁住）。代价 = 0（综合本来就把它当组合网）。
**验证**：改完跑 `tb_calib_still_guard`（6 条必须全绿）+ `tb_calib_autotare`；并用变异测试"把 `dlt_r = 0;` 那行删掉"⇒ 必须变红。
**结构性/布局**：结构性编码风险（当前零影响）。

---

## P3-6 · `calib_span` 的超时比较**两种写法混用**（切片 vs 未切片）

**位置**：`rtl/w3a/calib_span.v:405` · `:438` · `:523`（切片）对 `:626`（未切片）

```verilog
405:                    if (wait_clk_cnt >= WAIT_TIMEOUT_CLK[WCW-1:0]) begin
...
626:                    else if (span_sent_r && (wait_clk_cnt >= WAIT_TIMEOUT_CLK)) begin
```
**机制**：`WAIT_TIMEOUT_CLK` 是 `integer`（32 位），`wait_clk_cnt` 是 `[WCW-1:0]`。`:405` 显式切片成 26 位；`:626` 不切片 ⇒ 比较时**双方扩到 32 位**。当前**等价**（`WCW = $clog2(WAIT_TIMEOUT_CLK+1)` ⇒ 值一定装得下），综合会折叠成同一个常量比较。⇒ 零功能影响，但**两种写法并存**是个陷阱（若哪天把 `WCW` 手改成常量，`:405` 会静默截断而 `:626` 不会）。
**怎么改**：统一成 `WAIT_TIMEOUT_CLK[WCW-1:0]`，或引入 `localparam [WCW-1:0] WAIT_TO = WAIT_TIMEOUT_CLK;` 后到处用它。
**收益/代价**：收益 = 一致性（可读 + 抗未来改动）。代价 = 0。
**验证**：综合后 `report` 里 `wait_clk_cnt` 的比较器应只有一个（`grep` 网表）。
**结构性/布局**：结构性可读性。

---

## P3-7 · `calib.sv` 的冗余常量别名（`MAXT` / `FULL_EXT` / `FULL_CODE`）

**位置**：`rtl/drivers/calib.sv:324-325` · `:340`

```verilog
324:    localparam [PW-1:0] FULL_EXT  = FULL;
325:    localparam [DW-1:0] FULL_CODE = FULL;
340:    localparam [DW:0] MAXT = MAX_TRAVEL;
```
**机制**：这三个是"为了 Verilog-2001 位宽显式化"的必要别名（`K-91`：⛔ 不能对 `integer` 参数做位选），**本身是对的**。⚠️ 但 `MAXT` 与注释里的 `MAX_TRAVEL` 是**两个名字指同一个数**（`:335-339` 的注释混用两者）⇒ 改一处常量时容易只改一半的语义理解。零综合代价。
**怎么改**：把注释里的 `MAX_TRAVEL` 统一写成 `MAXT`（或在 `:341-342` 直接用 `MAX_TRAVEL` 的比较形式并保留别名仅供位宽）。**纯可读性**。
**验证**：无。
**结构性/布局**：零影响。

---

## P3-8 · 复位域差异（记录用）：`calib` 用**异步复位**、其余三个模块**同步复位**；`calib` 的三个数组**刻意不复位**

**位置**：`rtl/drivers/calib.sv:175` · `:257` · `:345`（`negedge rst_n`）对 `rtl/w3a/calib_span.v:253` · `calib_cmd.v:324/335` · `calib_autotare.v:188`（同步）；数组不复位见 `calib.sv:350-355` 注释与 `:399-405` 的 `initial`

```verilog
calib.sv:175:            always @(posedge clk or negedge rst_n) begin
calib_span.v:253:    always @(posedge clk) begin
```
**机制（为什么这是**安全**的，但要记录）**：
* 四者共用同一个 `rst_n_sync`（`top.v:1997/2245/2481/2501` 全部接 `rst_n_sync`）⇒ **单一复位域，无跨域**。用"已同步的复位"去驱动异步复位脚是标准做法（reset synchronizer 模式）⇒ ✅。
* `zero_r`/`gain_r`/`span_r` **不在任何复位分支里**（`:350-355` 明说）⇒ 逻辑复位**清不掉它们**；正确性由 `zero_vld`/`gain_vld`/`span_vld` 三张**会被复位**的位图门控（`:353-355`、`:128-131`）⇒ 复位后**每一个可观测输出都等于冷启动值**（`zero_eff=0` / `gain_eff=256` / `span_eff=0`）⇒ ✅ **无 X 传播**（读侧走的是常量默认值，不是数组内容）。
* ⚠️ 唯一残留差异：`rst_n` 拉低瞬间，`calib` 的位图**立即**清（异步），而 `calib_span` 的 `span_o` 要等下一拍才清 ⇒ 理论上存在 ≤1 拍窗口里"`span=1` 而位图已清"。⇒ 但该窗口内 `busy`/`gain_vld`/`span_vld` 仍被**拉低的异步复位**按在复位值 ⇒ **不产生任何写入** ⇒ 无害。
**怎么改**：**不必改**（记录在案即可）。若要做成完全同域，把 `calib` 的复位改成同步（⚠️ 代价：三个数组的写使能要重新处理，风险大于收益）。
**验证**：`tb_calib_still_guard.sv:436-466`（判据 2）已经机械验证了"逻辑复位 == 冷启动" ✅。
**结构性/布局**：结构性记录项，零时序影响。

---

## 附：四个重点问题的硬结论（贴数字）

### ① span 归一化的除法/比例运算组合深度 —— **除法是"时间串行"，不是"组合串行链"；乘法在 DSP 上**

* **除法**（`calib.sv:299-318`）：**恢复型移位-减法**，每拍出 1 位商，`ITER=24` ⇒ `busy` 高 **25 拍 ≈ 500 ns/轴**（16 轴合计 8 µs）。每拍的组合深度 = 一次 25 位比较 + 一次 24 位减法 + mux ≈ **3~4 级 LUT + 进位链 ≈ 1.5~2.5 ns** ⇒ **⛔ 不是长路径**。它是**故意的时间串行**（面积换时间），代价是 500 ns/轴，不是 Fmax。
* **比例运算**（`calib.sv:337-343` + `:373`）：`raw → zero_rd(LUTRAM 读) → dcode(减+比较) → dclamp(比较+mux) → × gain_rd(DSP) → prod_r`。**乘法被推断成硬 DSP**（`T_MULTALU27X18`），**证据**：`impl/pnr/Gowin2026_tr_content.html:18579-18580` 的 `DSP_R65[12] | g_sound.u_calib0/n840_s/RESET[0]`、`:18797-18798` 的 `DSP_R47[13] | g_sound.u_calib1/...`；=1 档同一实例在 `DSP_R65[30]`（`timing-rightadc-fixed.html:17337-17339`）。⇒ **⛔ 不是 LUT 乘法树**。
* **`zero_r`/`gain_r` 是分布式 RAM**（`synth_check.log:40-41` `Extracting RAM for identifier 'zero_r'/'gain_r'`）⇒ 读是 8:1 LUTRAM（≈2 级）。
* **总判据**：`u_calib0/u_calib1/u_calib_span/u_calib_autotare` 在 **=0 档与 =1 档的 Top-25 setup 表里都一次没出现**（`impl/pnr/Gowin2026_tr_content.html` 全文 `grep u_calib` 只命中 Recovery 表 `:910/921`，slack **+13.044 ns**）。而两档的 Top-25 门槛是 **15.218 ns** 数据延时 ⇒ **本批 4 个模块的组合深度 < 15 ns，且不是限制者**。
* **真正的限制者（贴数字）**：=0 档 `u_tdm_render_mixer/cnt_4_s0/Q → prod_c_0_s/D[8]`，**15.978 ns / slack +0.019 ns**（`base-T5-55p060:238-247`）；=1 档修前 `u_vibrato_lfo/phase_q_17_s0 → gen_lane[*].phase_q_*`，**21.4 ns / slack −3.272 ns / 1630 条违例**（`README.md:26-31`）。⇒ **55.06 / 57.0 MHz 与 CLS 78% / 81% 由颤音链与 mixer 决定，⛔ 不由标定链决定**；而 CLS 78→81% 是"=1 档多一片 ADC + 多 3 个 DSP"带来的布线拥挤（`README.md:136-137`），**与这 4 个模块的结构无关**。

### ② tare 的静止守卫（历史缺陷"只看片 0"）—— **已修、且有判据；但 span 侧仍只覆盖一片**

* ✅ 修复到位：`calib_autotare.v:193-202` 的 `dlt_r` 取**所有片**的最大帧间差；`top.v:2010` 把**打包的多片数据**接进去。
* ✅ **有判据**：`tb_calib_still_guard.sv:373-390`（N13）两段式 —— 片 0 静止 + 片 1 每帧跳 ⇒ **不得捕获**；两片都静止 ⇒ **必须捕获**（非空洞）。⇒ 这条历史缺陷**已闭环**。
* 🔴 **残留缺口 1**：`=1` 档 `ADC_N=3` 而 `N_ADC=2` ⇒ **片 2 的数据被剪掉**（实测 warning `tb_right_adc.compile.log:31-33`）⇒ 片 2 永不进守卫（当前无害，因为片 2 没有 `calib`；但参数一变就静默失效）。见 **P1-7**。
* 🔴 **残留缺口 2**：`span` 的静止门控（`S_SETTLE`/`S_VOTE`）**只作用于被 `sp_raw_sel` 选中的那一片**（`top.v:2099`），而 `span` 脉冲**打到两片**（`calib_span.v:537`）⇒ 另一片的 `den_r` 来自**未经任何静止判定**的采样。见 **P0-3**。

### ③ 多片锁步状态机 —— **存储天然分开（每片一份 `calib`），但"同拍广播"把两片的标定绑在一起**

* ✅ `calib` 是**每片一份实例**（`top.v:2479 u_calib0` / `:2499 u_calib1`，各自 `.raw(af0_pol)` / `.raw(af1_pol)`）⇒ `zero_r`/`gain_r`/`span_r` 是**实例内私有**的 ⇒ **同通道号不会互相覆盖**（这一点我特意查了，是正确的）。
* ✅ `adc_farm` 真的**同拍给齐所有片**：`sample_valid = s0_valid`、`sample_ch = s0_ch`（`adc_farm.sv:183-184`），片 i 的数据是 `sample_data_packed[i*12 +: 12]`（`:187-193`）⇒ 用"等 `sample_ch == cur_ch`"来对齐**在原理上成立**。
* 🔴 **代价**：`span_o <= {N_ADC{1'b1}}` + 共用 `cal_ch_mux`（`top.v:2373`）⇒ 标一个轴 = **两块板同通道号的两个键同时按到底**；且 `cal_err_any = cal0_err | cal1_err`（`top.v:1846`）⇒ 任一片失败就整轴作废。见 **P0-3**（含按片单发的具体改法）。
* ✅ **跨模块组合环已切断**：`cal_ch_mux` 用的是**打过一拍的** `sp_busy_r`（`top.v:2332-2348/2373`），不是组合的 `sp_busy` ⇒ 那条"`cal_ch_mux → calib → 采集 → calib_span → sp_busy → cal_ch_mux`"的环**不存在**（这正是 `:2355-2371` 记的那次挂死）。我逐条核了本批模块与顶层的所有跨模块组合穿透，**没有发现新的环**。
* ⚠️ `cal_ch_mux` 的仲裁**晚一拍**（用 `sp_busy_r`）—— 我核了时序：`span_o`/`cal_ch_o` 在 `N` 拍决策、`N+1` 拍生效，此时 `sp_busy_r = sp_busy(N) = 1`（`N` 拍在 `S_WAITBUSY`）⇒ `cal_ch_mux = sp_ch`（正是 `N+1` 拍刚写入的 `cal_ch_o`）⇒ **对齐成立**。✅ 不是缺陷。

### ④ 命令解析 FSM 覆盖 / 未覆盖状态 / 默认分支 / 比较器边界

| 项 | 结论 | 证据 |
|---|---|---|
| **未覆盖状态** | `calib_cmd.idx_q` 只取 **0..8**（4 位里的 9..15 **不可达**：复位 0、帧头置 1、`IDX_LAST(8)` 后回 0）⇒ **无未覆盖状态** | `calib_cmd.v:245` · `:393` · `:456-460` |
| **未覆盖状态（span）** | `calib_span` 3 位编码 **8/8 用满** ⇒ `default` **静态不可达** | `calib_span.v:156-163` · `:645` |
| **未覆盖状态（autotare）** | `calib_autotare` 2 位编码只用 3 个 ⇒ `2'd3` **未覆盖**，`default` **可达且必要** | `calib_autotare.v:134-136` · `:325` |
| **默认分支** | `calib_span`/`calib_autotare` 有 `default`；`calib_cmd` 用 `if/else`（无 case）⇒ 结构上由 `if (idx_q == 4'd0) … else …` 覆盖全部 | `calib_cmd.v:389/435` |
| **`idle_q >= GAP_CLK`（`>=` 不是 `>`）** | ✅ 正确：`idle_q` 饱和在 `GAP_CLK`，用 `>=` 才能到；若写 `>` 则**永不归位**（`idle_q` 停在 `GAP_CLK`） | `calib_cmd.v:265/329-331` |
| **`vote_cnt >= VOTE_N − 1`** | ✅ 正确：比较在自增**之前** ⇒ 恰好收满 `VOTE_N` 帧才转 `S_FIRE`（`VOTE_N=8` ⇒ 8 帧） | `calib_span.v:452-454` |
| **`idx_q == IDX_LAST(8)`** | ✅ 正确：一帧 = `0xA5` + **8** 载荷 = 9 字节 | `calib_cmd.v:456-460` |
| **`reject_cnt >= REJECT_MAX[3:0]`** | 🔴 三个陷阱（切片/旧值/全局累计） | **P2-2** |
| **`cur_axis == AXIS_TOTAL[3:0] − 1`** | ⚠️ 靠**模 16 回绕**才等于 15（`16[3:0]=0`，`0−1=15`）⇒ 当前配置正确，但 `AXIS_TOTAL=20` 就会在轴 3 收工 | `calib_span.v:615` |
| **`stable_cnt >= STABLE_NEED[5:0]`** | ⚠️ 用旧值 ⇒ 实际 `STABLE_NEED+1` 帧 | **P3-3** |
| **18 个命令字母查重** | ✅ **18/18 全部列进 `cmd_tab`**（我逐项数过：T/S/X/P/V/M/N/R/L/C/I/B/D/K/F/G/H/J），无重复、无等于 `0xA5` | `calib_cmd.v:501-524` |
| **`cmd_tab` 的查重保护** | 🔴 它是 `reg [7:0] cmd_tab [0:17]` + `initial` ⇒ **只存在于仿真**；综合里**没有**这层保护 ⇒ "加新字母忘了进表"在**上板时不会报**，只在跑 tb 时报 | `calib_cmd.v:502-543` |
| **`byte_is_cmd` 的完整度** | ✅ 18 个字母**全部**在或树里（含 `'H'`）⇒ 帧内出现任一命令字母都会 `in_frame_cnt_o++`（边界跟踪的证据不丢） | `calib_cmd.v:296-306` |
| **组合深度** | `rx_data_i`（`uart_rx` 寄存器输出）→ 18 个 8 位比较器 + 或树 → `*_req_o`（寄存器）≈ **2 级 LUT** ⇒ **⛔ 不是长路径**；`rx_data_i[7:0]` 扇出 144 个 LUT 输入，可忽略 | `calib_cmd.v:271-306` |

---

## 附 2：已逐条核对为"干净"的项（避免误改）

1. **复位覆盖完整性**：`calib_span` 复位体（`:254-279`）覆盖**全部 15 个 reg**（`state/cur_axis/reject_cnt/prev_val/vmin/vmax/stable_cnt/vote_cnt/vote_lo/vote_hi/wait_clk_cnt/span_sent_r/span_sent_r2/prompt_phase` + 4 个输出 reg），**无遗漏**；`calib_cmd` 复位体（`:336-361`）覆盖全部 23 个 `output reg` + `idx_q` + `abs_arm_q`，**无遗漏**；`calib_autotare`（`:207-221`）覆盖全部寄存器 + `for` 清三张表，**无遗漏**。✅
2. **上电 X 传播**：`calib` 的三个数组不复位，但读侧被**会被复位**的位图门控（`:128-131`）⇒ 复位后输出 = 常量默认值 ⇒ **无 X**（`tb_calib_still_guard.sv:436-466` 已机械验证）。✅
3. **跨时钟域**：四个模块全部单时钟（`clk_sys`），唯一的异步输入是 `rst_n_sync`（已同步）⇒ **本批模块无 CDC 采样**。`adc_farm` 的 `MISO` 有 2 级 `sync_input`（`adc_farm.sv:89-93`）—— 不属本批。✅
4. **意外推断 latch**：`calib_autotare` 的阻塞赋值块**每拍先无条件赋 `dlt_r = 0`**（`:193`）⇒ 无未赋值分支 ⇒ **不推 latch**（`still_r`/`enough_r` 也都被无条件赋值）。✅（脆弱性见 P3-5）
5. **悬空端口 Z**：本批 4 个模块的所有端口在 `top.v` 里**都接了**（我逐端口核过 `u_calib_cmd`/`u_autotare`/`u_calib_span`/`u_calib0/1`）；没有 `z`。⚠️ `g_silent` 档不例化 `calib_cmd` ⇒ 那里的 `cmd_*` 悬空（`top.v:690`/`:736` 已记录），但那不是本批的例化。✅
6. **跨 32 voice 的高扇出**：本批 4 个模块**不接触** voice 阵列。全设计最高扇出是 `clk_d`(16957) / `rst_n_sync`(13958) / `tick_audio`(1415)（`base-T5-55p060:29846-29890`）；本批相关的只有 `af_sample_ch[2]`(**486**，见 P2-7)。✅
7. **毛刺敏感路径**：本批所有对外输出都是**寄存器**（`span_o`/`cal_ch_o`/`tare_o`/`*_req_o`/`out_*`）⇒ 无"组合输出被上层当脉冲采样"的毛刺面。`idle_expired` 虽是组合量，但只被时钟沿采样，其源 `idle_q` 是寄存器 ⇒ 无毛刺。✅
8. **有符号/无符号**：本批模块**没有有符号运算**（`calib_span`/`calib_autotare`/`calib`/`calib_cmd` 全是无符号比较与加减；`med3` 的 `sum` 是显式加宽的 `[DW+1:0]`，`RAW_MEDIAN_EN=0` 时整块被编译期删除 ⇒ 零代价）。✅
9. **计数器回绕**：`wait_clk_cnt`（26 位）有饱和守卫 `!= {WCW{1'b1}}`；`idle_q`（20 位）有 `!idle_expired` 守卫；`sat_inc16` 显式饱和；`still_cnt` 饱和在 `STILL_N`。**只有 `done_cnt_o`（4 位）会回绕** ⇒ 见 P1-4/P3-4。✅（其余干净）
10. **可折叠常量 / 可共享比较器**：`WAIT_TIMEOUT_CLK[WCW-1:0]` 的 4 处比较会被折成同一常量；`REJECT_MAX[3:0]` 的 6 处同理；`(1<<8)`、`FULL<<8`、`INVERT_AXIS` 的三目都是编译期常量。⇒ **无浪费**（唯一冗余项是 P2-3 的 `still_cnt >= STILL_N`）。✅

---

## 附 3：本批**没有**发现的问题（明确声明，防止被"补齐"）

* ❌ 未发现**新的跨模块组合环**（`cal_ch_mux` 已用 `sp_busy_r` 切断）。
* ❌ 未发现**本批模块导致的 setup/hold 违例**（两档 0/0，且本批模块不在 Top-25）。
* ❌ 未发现**本批模块的 latch 推断**或**非预期 BSRAM/大 mux**（`zero_r`/`gain_r` 是**有意的** LUTRAM，`DSP` 是**有意的**乘法器）。
* ❌ 未发现**CDC**、**有符号/无符号**、**悬空端口 Z** 类问题。
* ❌ 未发现 `calib_span` 的**复位遗漏**、`calib_cmd` 的**命令字母重复**、`calib_autotare` 的**超时溢出**（`WAIT_CLK = 1000 × 50000 = 5e7` 已在 `:165-166` 用"先除后乘"修好，并有 `:364-366` 的反除自检）。

---

**ANVIL-05 · 采集与标定 A · 完**
