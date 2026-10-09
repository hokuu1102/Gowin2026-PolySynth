# ANVIL-04 · 波表与渲染 —— `wavetable_bank.v` / `dds_wavetable_core.v` 时序与逻辑审计

> **代号**：ANVIL-04 · 波表与渲染
> **审计对象**：`rtl/w3b/wavetable_bank.v`（856 行，其中 796 行是 10 张 pROM 的 `INIT_RAM_*` 常量）
> ＋ `rtl/w3b/dds_wavetable_core.v`（48 行）
> **审计口径**：GW5AT-60B / AC1-I0（慢档 0.93 V 0 ℃）· `clk_sys` = 50 MHz（20 ns）·
> `set_max_delay ... 18.181`（挑战档）· 门槛 `Fmax ≥ 51.5 MHz` · 判据 `0 setup / 0 hold`
> **本文所有数字都可复现**，取证命令见 §2。**没有证据的话一条都不写**（见 §5 反证清单）。

---

## 1. 结论速览

| 编号 | 优先级 | 一句话 | 结构性 / 布局运气 | 证据 |
|---|---|---|---|---|
| P0-1 | **P0** | `DEPTH` 是假参数：10 处地址硬编码 `addr_i[9:0]`，改 `DEPTH` 即**静默读错表**，而自检 `$display("ERROR")` **不进任何判据** | N/A（逻辑，非时序） | 探针实测 + `sim/tb_all.ps1:346-353` |
| P1-1 | P1 | `WAVETABLE_BEHAVIORAL` 宏**全仓库无人引用** ⇒ `tb_wavetable_bank_prom` 与 `tb_wavetable_bank` 编译**同一份 RTL**，"pROM 变体"是**空判据** | N/A（判据） | 全仓 grep + `sim/tb_all.ps1:117-121` |
| P1-2 | P1 | `valid_o` 是 `rd_en_i` 的**电平延迟**（不是"一请求一脉冲"）；交付网表里它**悬空**，任何新消费者按脉冲理解就 **64× 过采样** | N/A（语义） | `wavetable_bank.v:839-848` ＋ `oscillator_bank.v:863` |
| P1-3 | P1 | 10 块 pROM 的 `CE` **全部无条件**接 `rd_en_i` ⇒ 每次 TDM 读 **10 块 BSRAM 齐翻转**，而每拍只需 1~2 张表（音色选择在 ROM **之后**） | 功耗，非时序 | `power.html`：BSRAM **64.634 mW / 总 204.092 mW** |
| P1-4 | P1 | `rom_timbre` 由 note_manager 的 **64 bit 顶层网**（未寄存）→ 64:1 mux → `timbre_q`：**跨模块组合穿透 ＋ 跨 32 voice 高扇出 ＋ 单周期约束** | **结构性**（但当前不在关键路径，见 §5 R-1） | `oscillator_bank.v:695-696,744` ＋ `note_manager.v:1647` |
| P1-5 | P1 | `dds_wavetable_core.v` / `voice.v` / `voice_i2s_chain.v` / `wavetable_sine_rom_ip.v` 在 `.gprj` 里 `enable="1"`，但**顶层零实例** ⇒ 交付网表里**根本没有这个模块**；回归在**给不存在的硬件打分** | N/A（覆盖） | `rpt.txt` `--pROM \| 10` ＋ 综合日志无 `Compiling module 'voice'` |
| P1-6 | P1 | 512 点表 ＋ 32 bit 相位累加器 ⇒ 只用 **9 bit 相位、无插值** ⇒ 相位截断杂散 ≈ **−48…−50 dBc**；且这 512 点表与 `wavetable_bank` 的 1024 点纯正弦**同波形双份存储** | N/A（质量/资源） | `dds_wavetable_core.v:42` ＋ `ip/.../wavetable_sine_rom_ip.v:18` |
| P2-1 | P2 | 4 个 `rom_hard_t*` 在交付配置下**没有任何功能消费者**（`FIXED_BLEND_Q=0` ＋ `VELOCITY_BLEND_EN=0`），却**实占 4 个 BSRAM** ≈ **7.8 mW** | 资源/功耗 | `rpt.txt` `--pROM \| 10` ＋ `oscillator_bank.v:86-87,805-812` |
| P2-2 | P2 | `TIMBRE_N` / `SAMPLE_W` 是**装饰参数**（全文只出现在端口宽度自检里）⇒ 改它们没有任何功能后果，也没有任何报错 | N/A | `wavetable_bank.v:17-20,851-852` |
| P2-3 | P2 | `timbre_i` 悬空时 **仿真（`z`→`case` 落 `default`→t3=PAD）** 与 **硅片（未连输入被 tie 0→t0=BASS）行为不同** | N/A（Z 行为） | `wavetable_bank.v:808-815` |
| P2-4 | P2 | `sample_test_o` / `sample_noise_o` **绕过** `timbre_q` mux，在 `oscillator_bank` 里用**未寄存的 `test_mode_i`** 选择 ⇒ 换档那一帧**混表**（一次咔哒） | N/A（毛刺） | `oscillator_bank.v:845-847` |
| P2-5 | P2 | `tb_p5_osc_equiv` 的参数集（`DRUM_TOM_MAX=15M` / `SWEEP_SH=2`）≠ 交付（`top.v` 覆盖成 `20M` / `3`）⇒ 那道"逐位等价"门**不覆盖交付配置** | N/A（判据） | `tb_p5_osc_equiv.sv:59-68` vs `top.v:4204-4205` |
| P2-6 | P2 | `wavetable_bank` 的 `initial` 自检在 Gowin 综合里被**静默丢弃**（综合日志 0 warning，网表照出）⇒ 参数错误**上板前无人拦** | N/A | `impl/gwsynthesis/Gowin2026.log`（`wavetable_bank` 段 0 warning） |
| P2-7 | P2 | 10 块 pROM 共用一条 `addr_i[9:0]`（100 个 AD 负载）＋ 一条 `rd_en_i`（10 个 CE）＋ 一条 `~rst_n_i`（10 个 RESET）⇒ **必须同 region 布局**，否则地址/使能走长线 | 结构性（布局敏感） | `wavetable_bank.v:60,135,…735` |
| P3-1 | P3 | `rom_*_do` / `rom_soft_sel` 声明为 **unsigned**，端口是 **signed** ⇒ 等宽下无影响，任何加宽会**静默零扩展** | N/A | `wavetable_bank.v:33-52,805-807,827-828` |
| P3-2 | P3 | `dds_wavetable_core` 缺 `` `default_nettype none ``（`wavetable_bank` 有）⇒ 端口名拼错会**静默生成隐式线网** | N/A | `dds_wavetable_core.v:1-15` vs `wavetable_bank.v:15,856` |
| P3-3 | P3 | `OCE(1'b1)` 在 `READ_MODE=0` 下**无作用**（bypass 模式的输出寄存器由 `CE` 使能，`OCE` 只管 pipeline 级）⇒ 10 个常量为装饰 | N/A | `tb/models/prom_model.sv:181-185` |
| P3-4 | P3 | `wavetable_bank.v:817-826` 注释块与代码**互斥**；同族 `oscillator_bank.v:814` 说"固定 `rom_hard`"、`:832` 说"`= rom_soft`" —— **代码实际是 `rom_soft`** | N/A（文档） | `oscillator_bank.v:800-812,832` |
| P3-5 | P3 | 死线：`rom_*_inst_dout_w[15:0]` **10 根**只用来凑 32 bit 的 `DO` 端口，从不被读 | N/A | `wavetable_bank.v:34,55,655…` |

**合计 19 条**：P0 × 1 · P1 × 6 · P2 × 7 · P3 × 5。

---

## 2. 取证清单（复现命令）

```powershell
# ① 当前 PnR 时序汇总（Fmax / setup / hold）
Get-Content sim\evidence\gowin_m0_timing.txt -Encoding UTF8

# ② 资源：pROM 到底有几块
Select-String -Path impl\pnr\Gowin2026.rpt.txt -Pattern 'pROM|BSRAM|CLS|Resource'

# ③ 功耗：BSRAM 占比
#    impl/pnr/Gowin2026.power.html → Total 204.092 mW · BSRAM 64.634 mW

# ④ 关键路径到底在哪（按层次统计 50 条路径的节点）
$c = Get-Content impl\pnr\Gowin2026.timing_paths -Encoding UTF8
$c | Where-Object { $_ -match '^\S+/\S+' } | ForEach-Object { ($_ -split '/')[0] } |
  Group-Object | Sort-Object Count -Descending

# ⑤ P0-1 的探针（本报告新增，源码留在 review/raw/_probe_depth.v）
iverilog -g2012 -s tb_probe_depth -o build\sim\probe_anvil04\p.vvp `
  review\raw\_probe_depth.v rtl\w3b\wavetable_bank.v tb\models\prom_model.sv
vvp build\sim\probe_anvil04\p.vvp ; $LASTEXITCODE

# ⑥ 判据为什么抓不住 P0-1 / P2-6
Select-String -Path sim\tb_all.ps1 -Pattern 'failRx|errLines|FAIL:'

# ⑦ P1-1：这个宏到底有没有人用
Get-ChildItem -Recurse -Include *.v,*.sv -Path rtl | Select-String -Pattern 'WAVETABLE_BEHAVIORAL'
```

---

## 3. 逐条

### P0-1 · `DEPTH` 是假参数：10 处地址硬编码 `addr_i[9:0]`，改参数即静默读错表，且自检不进判据

**位置**
- 端口：`rtl/w3b/wavetable_bank.v:26` → `input wire [$clog2(DEPTH)-1:0] addr_i,`
- 地址（10 处，一字不差）：`:60`、`:135`、`:210`、`:285`、`:360`、`:435`、`:510`、`:585`、`:660`、`:735`
- 自检：`:850-854`

**确切代码**
```verilog
26:    input wire [$clog2(DEPTH)-1:0] addr_i,          // ← 宽度【跟着 DEPTH 走】
...
60:        .AD({addr_i[9:0], 4'b0000})                  // ← 但切片【写死 10 bit】
...
850:    initial begin
851:        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
852:            (DEPTH != 1024) || (SAMPLE_W != 16))
853:            $display("ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");
854:    end
```

**机制（带数字）**
- `DEPTH` 在全文只有 **2 处**被引用：`:26` 的 `$clog2(DEPTH)` 和 `:852` 的比较。**它不参与任何地址运算。**
- 10 处 `.AD()` 里的 `addr_i[9:0]` 把字地址写死成 **10 bit = 1024 项**（`$clog2(1024)=10`）。
- Gowin `pROM` 在 `BIT_WIDTH=16` 时用 **`AD[13:4]`** 作字地址（见 §5 R-3 的三重印证），所以
  `{addr_i[9:0], 4'b0000}` 对 `DEPTH=1024` 是**正确**的 —— **坑不在位序，在于"10"这个字面量**。
- 把 `DEPTH` 改成 `2048`：端口自动变成 **11 bit**，但地址仍然只取低 10 bit
  ⇒ **`addr_i[10]` 被静默丢弃** ⇒ `addr 1024` 与 `addr 0` 命中**同一表项**。
- `:851-853` 的守卫**抓不住**，三重失效：
  1. 它是 `$display`，不是 `$error` / `$fatal` ⇒ **`vvp` 退出码仍然是 0**；
  2. `sim/tb_all.ps1:347` 把 `ERROR` 行**只当诊断信息**，判据是
     `sim/tb_all.ps1:346` 的 `(?m)^[ \t]*[^A-Za-z]*FAIL:` 或非零退出码 ⇒ `ERROR` 行**不算失败**；
  3. 就算它算失败，`initial` 块在 Gowin 综合里**被丢弃**（见 P2-6）⇒ 上板前也无人拦。

**实测（本报告新增探针，源码 `review/raw/_probe_depth.v`）**
```
$ iverilog -g2012 -s tb_probe_depth -o ... review\raw\_probe_depth.v \
      rtl\w3b\wavetable_bank.v tb\models\prom_model.sv      → exit=0
$ vvp ...
ERROR [wavetable_bank] fixed pROM contract is 4x1024x16
PROBE addr=0    -> soft=373
PROBE addr=1    -> soft=597
PROBE addr=1024 -> soft=373      ← 与 addr=0 同值（别名）
PROBE addr=1025 -> soft=597      ← 与 addr=1 同值（别名）
$ echo $LASTEXITCODE → 0          ← 守卫没拦住，退出码还是 0
```
（`373` / `597` 与 `tb/w3b/tb_wavetable_bank.sv:307` 的 `read_and_check(2'd0, 10'd0, 16'sd373, …)`
和 `rom_soft_t0` 的 `INIT_RAM_00 = 256'h…02550175` 逐值吻合，证明探针读的就是真表。）

**改法**（参数化，且对 `DEPTH=1024` **逐位等价**）
```verilog
// 10 处统一改成：
.AD({{(14-$clog2(DEPTH)){1'b0}}, addr_i})
// DEPTH=1024 ⇒ {4'b0000, addr_i[9:0]}  —— 与现状逐位相同
// DEPTH=2048 ⇒ {3'b000, addr_i[10:0]} —— 不再丢 bit
```
并把自检从"打印"升级为"能红"：
```verilog
initial begin
    if ((TIMBRE_N != 4) || (TIMBRE_W != 2) || (DEPTH != 1024) || (SAMPLE_W != 16))
        $fatal(1, "ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");
end
```
> ⚠️ `$fatal` 会改掉 `tb_all.ps1` 的退出码语义（`$runExit -ne 0` ⇒ 判失败），这正是想要的；
> 但**必须同时确认**现有 4 个消费者（`oscillator_bank` / `tb_wavetable_bank` /
> `tb_wavetable_bank_prom` / `tb_akwf_wavetables` / `tb_wavetable_timbres`）都用默认参数，
> 否则会误红。

**预期收益**：消除一类**静默错数据**（读到别的表项 ⇒ 音高/波形全错但"有声音"，
与"静音"完全不同，最难定位）。**不是时序收益。**

**验证能红**
1. 探针：改造后 `PROBE addr=1024` 必须 **≠** `PROBE addr=0`（且 `DEPTH=1024` 时全部逐点与
   `tb_wavetable_bank` 的 golden 一致 ⇒ 证明没有回归）。
2. 判据门：把 `$display` 改 `$fatal` 后，用一个 `DEPTH=2048` 的 tb 跑
   `sim\tb_all.ps1 -Filter wavetable` ⇒ 必须出现 `FAIL:` 行且汇总**不是**"通过 N / 共 N"。

**结构性 / 布局运气**：**都不是** —— 这是纯逻辑/参数化缺陷。

**过门要求**：① 综合 `ERROR=0` ② 聚焦 tb（`wavetable_bank` / `wavetable_bank_prom` /
`akwf_wavetables` / `wavetable_timbres` / `oscillator_bank`）全 PASS ③ 一次干净 PnR
（出 `.fs` ＋ 无 `PR0004` ＋ `0/0`）④ 全量回归"通过数 == 共数"。
**⛔ 不需要同步 `tb/models/oscillator_bank_ref.v`**（不改 `oscillator_bank`，逐位等价不受影响）。

---

### P1-1 · `WAVETABLE_BEHAVIORAL` 宏全仓库无人引用 ⇒ "pROM 变体"是空判据

**位置**：`sim/tb_all.ps1:109-122`；`tb/w3b/tb_wavetable_bank_prom.sv:1-24,165-167`；
以及 `sim/check_nonempty.ps1:122`、`sim/check_met_btn_nonempty.ps1:241`、
`build/mut_t3.ps1:37`、`build/mut_t3b.ps1:25`

**确切代码**
```powershell
# sim/tb_all.ps1:117-121
$isPromVariant = $name -like "*_prom*"
if ($isPromVariant) {
  $compileArgs = @("-g2012","-Wall","-s",$name,"-o",$vvpFile) + $rtl + $models + $chk + @($tb.FullName)
} else {
  $compileArgs = @("-g2012","-Wall","-DWAVETABLE_BEHAVIORAL","-s",$name,"-o",$vvpFile) + $rtl + $models + $chk + @($tb.FullName)
}
```

**机制（带数字）**
- 全仓 grep `WAVETABLE_BEHAVIORAL`：命中 **11 处**，全部在 `.ps1` / `.sv` 的**注释和编译参数**里；
  **`rtl/` 下 0 命中**。`rtl/w3b/wavetable_bank.v` 里**没有任何 `` `ifdef ``**。
- ⇒ 两条分支编译的是**同一份 RTL**；`_prom` 变体**只是少传一个没人看的宏**。
- ⇒ `tb_wavetable_bank.sv` 与 `tb_wavetable_bank_prom.sv` 是**同一份判据的两次拷贝**
  （前者的 512 点段被注释掉了，实际只剩后者那 5 条 `read_and_check` ＋ 后者没有的
  噪声表统计判据）。**判据数量在涨，覆盖面积没涨。**
- 这正是 `C83`（探针假绿）的同族：**判据看起来在守"综合分支"，实际守的是同一个分支。**

**改法**（二选一，推荐 A）
- **A · 删掉空壳**：把 `tb_all.ps1:109-122` 的 `$isPromVariant` 分支、以及
  `check_nonempty.ps1` / `check_met_btn_nonempty.ps1` / `mut_t3*.ps1` 里的
  `-DWAVETABLE_BEHAVIORAL` **一并删掉**，并在 `tb_wavetable_bank_prom.sv` 头注释里
  写明"T31b 之后不存在行为级分支，本 tb 与 `tb_wavetable_bank` 同源，保留仅因历史"。
- **B · 让宏真的有分支**：给 `wavetable_bank` 加
  `` `ifdef WAVETABLE_BEHAVIORAL `` 的 `case` 常量表分支 ＋ `else` 的 pROM 分支
  —— 但这等于把"仿真/上板双实现"这个**已知会漂移**的模式再引回来（本项目已经因为
  T31b 合并把它删了），**⛔ 不推荐**。

**预期收益**：消除一条**恒真的判据**。回归从"129 个 tb"里真正少一个**零覆盖**的条目，
或者让这 129 个里每一个都有意义。**不是时序收益。**

**验证能红**：改完后跑 `sim\tb_all.ps1 -Filter wavetable` —— 若只做 A，
`tb_wavetable_bank_prom` 必须**仍然 PASS**（它本来就跑同一份 RTL）；
真正的"能红"判据是：**对 `rtl/w3b/wavetable_bank.v` 注入一个只影响
`INIT_RAM_*` 常量的变异（如把 `rom_soft_t0` 的 `INIT_RAM_00` 末 4 位 `0175`→`0176`），
两个 tb 必须同时变红** —— 若只有 `tb_wavetable_bank` 红而 `_prom` 不红，说明两者真的不同源
（当前会**同时**红，这就是"同源"的实证）。

**结构性 / 布局运气**：都不是，是**判据有效性**问题。

**过门要求**：只改 `sim/` 与 `tb/` 注释 ⇒ **不触发四道门**；但按项目纪律仍需跑一次全量回归
确认"通过数 == 共数"（tb 数可能变化，**以运行时打印的"共 N"为准，⛔ 不要写死数字**）。

---

### P1-2 · `valid_o` 是"电平延迟"不是"请求脉冲"，且交付网表里它悬空

**位置**：`rtl/w3b/wavetable_bank.v:31,839-848`；消费者 `rtl/w3b/oscillator_bank.v:863`

**确切代码**
```verilog
31:    output reg valid_o
...
839:    always @(posedge clk_i) begin
840:        if (!rst_n_i) begin
841:            valid_o  <= 1'b0;
842:            timbre_q <= {TIMBRE_W{1'b0}};
843:        end else begin
844:            valid_o <= rd_en_i;                 // ← 电平延迟，不是脉冲
845:            if (rd_en_i)
846:                timbre_q <= timbre_i;
847:        end
848:    end
```
```verilog
// rtl/w3b/oscillator_bank.v:849-864
863:        .valid_o  ()                            // ← 悬空
```

**机制（带数字）**
- `valid_o` 只是 `rd_en_i` 打一拍。`rd_en_i` 在 `oscillator_bank` 里是
  `req_active = rendering && (cnt < LANES[LW:0])`（`oscillator_bank.v:742`），
  `LANES = POLY_TARGET × OSC_PER_VOICE = 32 × 2 = 64`（`:259`）
  ⇒ **一次采样帧里 `rd_en_i` 连续高 64 拍** ⇒ `valid_o` **连续高 65 拍**。
- 也就是说 `valid_o` **不是** "一次读有效"，而是 "上一次 `rd_en_i` 的电平"。
  `tb_wavetable_bank.sv:287-289` 之所以没踩到，是因为 tb **每读一个点就拉低一拍** `rd_en_i`
  （`:288` 与 `:315` 都显式写 `rd_en_i = 1'b1/0`）。
- 交付网表里它**悬空**（`oscillator_bank.v:863`），所以今天不出错；
  **但这是"判据比消费者强"的典型**：tb 把一个 65 拍的高电平当成"65 次有效"，
  而任何**新**消费者（例如给 `tdm_render_mixer` 加流控、或给 `bringup` 做单点探针）
  按 `valid_o` 计数就会 **64× 过采样**。

**改法**（推荐 A，最小风险）
- **A · 把语义写进名字＋加一个真正的脉冲**：
  ```verilog
  output reg valid_o          // 保持向后兼容：= rd_en_i 延迟 1 拍
  output reg valid_pulse_o    // 新增：只在 rd_en_i 的【上升沿】后 1 拍为高
  ```
  实现：加 `reg rd_en_d;` ⇒ `valid_pulse_o <= rd_en_i & ~rd_en_d;`
  成本 **+1 FF**。老消费者（4 个 tb ＋ `oscillator_bank`）**一行不动**。
- **B · 直接改语义**：`valid_o <= rd_en_i & ~rd_en_d;`
  ⚠️ **会打破** `tb_wavetable_bank.sv:290` / `tb_wavetable_bank_prom.sv:201`
  的 `valid_o !== 1'b1` 判据吗？不会 —— 那些 tb 的 `rd_en_i` 本来就是单拍脉冲，
  上升沿检测后**行为逐位相同**。但 `tb_akwf_wavetables` / `tb_wavetable_timbres`
  若连续拉高 `rd_en_i` 就会红（**必须先读那两个 tb**）。
  ⇒ 选 A 更稳。

**预期收益**：消除一个"名字骗人"的输出。**不是时序收益**（悬空输出会被工具裁掉，
`rpt.txt` 里也看不到它）。

**验证能红**：写一个 5 行的探针 tb：把 `rd_en_i` 连续拉高 **8 拍**，断言
`valid_o` 的高电平拍数。改造前 = **9 拍**（含延迟），改造后 `valid_pulse_o` = **1 拍**。
判据写成 `FAIL:` 行 ⇒ 可被 `tb_all.ps1` 抓。

**结构性 / 布局运气**：都不是。

**过门要求**：改 `wavetable_bank` 只需跑 `wavetable*` 系列 tb ＋ 全量回归；
**⛔ 不需要同步 `oscillator_bank_ref.v`**（`oscillator_bank.v:863` 没接 `valid_o`，
参考副本同样没接 ⇒ 逐位等价不受影响）。

---

### P1-3 · 10 块 pROM 的 `CE` 全部无条件接 `rd_en_i`：每次 TDM 读 10 块 BSRAM 齐翻转

**位置**：`rtl/w3b/wavetable_bank.v:58,133,208,283,358,433,508,583,658,733`（10 处 `.CE(rd_en_i)`）
＋ `:808-815`（音色选择在 ROM **之后**）

**确切代码**
```verilog
54:    pROM rom_soft_t0_inst (
...
58:        .CE(rd_en_i),                       // ← 无条件：所有 10 块一起翻转
...
808:    always @(*) begin                       // ← 选择在【ROM 输出之后】
809:        case (timbre_q)
810:            2'd0: begin rom_soft_sel = rom_soft_t0_inst_do; rom_hard_sel = rom_hard_t0_inst_do; end
...
```

**机制（带数字）**
- TDM 每帧送 **64** 个地址（`LANES=64`），采样率 = 50 MHz / 1024 = **48 828 Hz**
  ⇒ BSRAM 读次数 = 64 × 48 828 ≈ **3.125 M 次/秒**。
- 每次读，**10 块** BSRAM 的地址/输出寄存器**同时**翻转 ⇒ **31.25 M 次 BSRAM 读/秒**。
- 但**每拍真正被消费的只有 1~2 张表**（`rom_dout` 三选一，见 `oscillator_bank.v:845-847`）。
  ⇒ 有效利用率 ≈ **10% ~ 20%**。
- 功耗实测（`impl/pnr/Gowin2026.power.html`）：
  | 块 | 功耗 (mW) |
  |---|---|
  | Logic | 15.821 |
  | **BSRAM** | **64.634** |
  | DSP | 19.557 |
  | **Total** | **204.092** |
  ⇒ **BSRAM 占总功耗 31.7%，是最大单块。**
  `wavetable_bank` 的 10 块 pROM 占全部 33 块 BSRAM 的 **30.3%**
  （`rpt.txt`：`BSRAM 33/118`，其中 `--pROM 10`、`--SDPB 7`、`--SDPX9B 16`）
  ⇒ 折算 ≈ **19.6 mW**，其中 4 块是死的（见 P2-1）。

**改法**（按收益/风险排序）
- **① 按音色门控 CE（推荐，改动最小）**：
  ```verilog
  wire ce_t0 = rd_en_i && (timbre_i == 2'd0);
  wire ce_t1 = rd_en_i && (timbre_i == 2'd1);
  wire ce_t2 = rd_en_i && (timbre_i == 2'd2);
  wire ce_t3 = rd_en_i && (timbre_i == 2'd3);
  // 10 处 .CE(...) 分别接 ce_t0/ce_t1/...（soft 与 hard 同音色共用一条）
  ```
  **为什么安全**：`timbre_q` 选中的**正是**当拍被使能的那一块（两者都在 `rd_en_i` 那拍更新），
  未选中的块保持旧值而**不被选**⇒ 输出逐位不变。
  成本：4 个 2 bit 比较器（≈4 LUT）＋ 4 条 CE 网。
  收益：每次读的**翻转块数从 10 → 2**（soft ＋ hard 同音色）⇒ 读功耗 **−80%**。
- **② 再把 `rom_test_sine` / `rom_noise` 也门控**（`ce_test = rd_en_i && test_mode_i`、
  `ce_noise = rd_en_i && resp_drum`）—— ⚠️ **但它们的选择信号在 `oscillator_bank` 里**
  （`test_mode_i` / `resp_drum_q`），需要**新增 2 个输入端口**，会打破 4 个 tb 的例化
  ⇒ **必须给默认值或用 `===` 兜底**（同 `voice_drum_i` 的 `z` 前科）。
  收益：再 **−20%**。**建议第二步再做，先做①。**

**预期收益**：读功耗从 10 块降到 2 块。按 BSRAM 64.634 mW × 30.3%（wavetable 占块比例）
× 80%（削减比例）**估算 ≈ 15.7 mW**（**估算值，非工具直接输出**；
工具只给总块功耗，不做实例级分解）。**不是时序收益。**

**验证能红**
1. **功能**：`sim\tb_all.ps1 -Filter wavetable` ⇒ 必须全 PASS（输出逐位不变）。
   `tb_wavetable_bank.sv:307-311` 的 5 条 `read_and_check` 会**逐表逐点**验证
   `timbre_i` 切换后取到的是对的表 ⇒ 这是"门控没门错"的直接判据。
2. **功耗**：重跑 PnR，比较 `Gowin2026.power.html` 的 `BSRAM` 行。
   预期从 **64.634 mW 下降**（**注意**：功耗模型依赖仿真激励的翻转率，
   本项目 PnR 不带激励 ⇒ 工具用的是**默认翻转率估计**，
   ⚠️ **这条数字的绝对可信度有限，只能做 A/B 相对比较**）。
3. **非空洞性**：把 `ce_t0` 写成 `rd_en_i && (timbre_i == 2'd1)`（故意门错一格），
   `tb_wavetable_bank` 的 `read_and_check(2'd0, 10'd0, 373, 226)` **必须变红**。

**结构性 / 布局运气**：**功耗类，与时序无关**。
⚠️ 但 CE 门控**会增加** 4 条新的高扇出网（每条 CE 进 2 块 BSRAM），
若 10 块 pROM 跨 region 放置，这 4 条 CE 会变成跨 region 长线 ⇒
**必须与 P2-7 一起评估**。

**过门要求**：改 `wavetable_bank` ⇒ 四道门（综合 `ERROR=0` / 聚焦 tb / 干净 PnR / 全量回归）。
**⛔ 不需要同步 `oscillator_bank_ref.v`**（只改 `wavetable_bank` 内部 CE）。

---

### P1-4 · `rom_timbre` 跨模块组合穿透：note_manager 的 64 bit 顶层网 → 64:1 mux → `timbre_q`

**位置**：`rtl/w3b/oscillator_bank.v:695-696`、`:744`、`:856`；源头 `rtl/w3b/note_manager.v:1647`

**确切代码**
```verilog
// rtl/w3b/note_manager.v:1647
assign voice_timbre_o[g*TIMBRE_W +: TIMBRE_W] = timbre_r[g];      // ← 寄存器输出，64 bit

// rtl/w3b/oscillator_bank.v:695-696   —— 注意：lane_addr 是【寄存器】，lane_timbre 不是
assign lane_addr[g*AW +: AW]       = addr_q;
assign lane_timbre[g*TIMBRE_W +: TIMBRE_W] =
    voice_timbre_i[VOICE_IDX*TIMBRE_W +: TIMBRE_W];               // ← 直穿顶层网，零寄存

// rtl/w3b/oscillator_bank.v:743-744
wire [AW-1:0]      rom_ad     = lane_addr[req_idx*AW +: AW];       // 64:1 × 10 bit
wire [TIMBRE_W-1:0] rom_timbre = lane_timbre[req_idx*TIMBRE_W +: TIMBRE_W];  // 64:1 × 2 bit

// rtl/w3b/oscillator_bank.v:856
.timbre_i (rom_timbre),                                           // → wavetable_bank.timbre_q
```

**机制（带数字）**
- **`lane_addr` 走 `addr_q`（`phase_q` 的寄存器切片），`lane_timbre` 走顶层输入网** ——
  **两条并行数据路径的起点深度不同**（一个在 `oscillator_bank` 内，一个在 `note_manager` 内）。
- 路径长度：`note_manager.timbre_r[g]`（FF）→ **跨模块长线**（64 bit × 2 = 128 根，
  横跨 32 个 voice 的布局区域）→ **64:1 mux**（`req_idx[5:0]` 选择，LUT4 需要
  ⌈log₄64⌉ = **3 级**）→ `wavetable_bank.timbre_i` → **`timbre_q`（FF）**。
- **它是单周期约束路径**（`clk_sys` 20 ns，且被 `set_max_delay 18.181` 再收紧到 **18.181 ns**）。
- **但它的语义是"静态值"**：`voice_timbre_i` 只在 `note_on` 那一刻被
  `note_manager` 改写（`oscillator_bank.v:890-892` 明确写"后续全局音色变化不会改写在响 voice"）
  ⇒ 这条路径**名义上要 1 拍收敛，实际上有 ≥ 1024 拍的语义余量**。
- ⇒ 它是**典型的"假关键路径"**：STA 按单周期卡它，但它的物理需求远低于此。
  **⛔ 不能用 `set_false_path` / `set_multicycle_path` 去"放"它** ——
  `note_on` 提交正好发生在 `sample_tick` 那一拍，而 TDM 读 lane 0 就在**下一拍**
  ⇒ 最短间隔只有 **1 拍**，放松约束会**真的错**（读到旧音色）。

**改法**（把"直穿"变成"寄存"）
```verilog
// 在 gen_voice 里新增每 lane 一份的 2 bit 影子寄存器，与 addr_q 同一个 always 块
reg [TIMBRE_W-1:0] timbre_q_lane;
always @(posedge clk_i) begin
    ...
    timbre_q_lane <= voice_timbre_i[VOICE_IDX*TIMBRE_W +: TIMBRE_W];   // 每拍跟随
end
assign lane_timbre[g*TIMBRE_W +: TIMBRE_W] = timbre_q_lane;
```
- **成本**：64 lane × 2 bit = **+128 FF**（当前 `Register 17039/60780 = 29%`，占比 **+0.2%**）。
- **为什么安全**：`voice_timbre_i` 是静态值 ⇒ 寄存后与直穿**逐位相同**，
  唯一差异是 `note_on` 当拍晚 1 拍生效（那一拍 TDM 还没开始读该 lane，见上面的时序分析）
  ⇒ **`tb_p5_osc_equiv` 的 320 帧逐位等价判据应当仍然 0 mismatch**。
- **⚠️ 必须先验证**：若某个 tb 检查"`voice_timbre_i` 变化后**当拍**就能在
  `osc_sample_bus_o` 上看到新音色"，加寄存器会红 ⇒ **先跑
  `sim\tb_all.ps1 -Filter oscillator` ＋ `-Filter wavetable` ＋ `-Filter p5_osc` 再动手**。

**预期收益**：把一条 **64 bit 宽 × 3 级 mux × 跨模块** 的单周期路径，变成
"本地 FF → 本地 3 级 mux → 本地 FF" ⇒ 路径长度砍掉**跨模块那一段**。
⚠️ **量化收益未知**：见 §5 R-1 —— 这条路径**不在当前 top-50 关键路径里**，
所以**不能宣称 Fmax 提升**。这是**预防性**改动（防止布局运气变差时它冒头）。

**验证能红**
1. `tb_p5_osc_equiv`（320 帧，比 64 lane 样点总线 ＋ `osc_valid_o` ＋ **全部 64 个相位累加器**）
   ⇒ 必须 **0 mismatch**（这是"逐位等价"的硬判据）。
2. **非空洞性**：把新增的 `timbre_q_lane` 故意接成
   `voice_timbre_i[(VOICE_IDX^1)*TIMBRE_W +: TIMBRE_W]`（错一个 voice）
   ⇒ `tb_p5_osc_equiv` 或 `tb_wavetable_bank` **必须变红**。

**结构性 / 布局运气**：**结构性**（跨模块 ＋ 高扇出 ＋ 单周期约束），
**但当前被布局掩盖**（见 R-1）。

**过门要求**：改 `oscillator_bank` ⇒
① 综合 `ERROR=0` ② 聚焦 tb：`-Filter oscillator` / `-Filter wavetable` / `-Filter p5_osc`
③ 干净 PnR ④ 全量回归。
🔴 **必须同步 `tb/models/oscillator_bank_ref.v`** ——
`tb/w3b/tb_p5_osc_equiv.sv:13-16` 明确警告：
> "参考副本 = 改动前的 `oscillator_bank` … **将来若再改 `oscillator_bank`，必须同步换新参考** ——
> 否则'两边同源' ⇒ 本 tb 会**静默恒真**（C83 探针假绿同族）"

⇒ **正确做法**：把**改动前的** `oscillator_bank.v` 复制成新的
`tb/models/oscillator_bank_ref.v`（只改模块名），再改生产文件。
**⛔ 不要**把新实现同时写进两边 —— 那会让 `tb_p5_osc_equiv` 变成恒真。

---

### P1-5 · `dds_wavetable_core` / `voice` / `voice_i2s_chain` / `wavetable_sine_rom_ip` 在 gprj 里但顶层零实例 ⇒ 回归在给不存在的硬件打分

**位置**：`Gowin2026.gprj:62,75,76,77`；`impl/pnr/Gowin2026.rpt.txt` §3；`impl/gwsynthesis/Gowin2026.log`

**确切证据**
```
Gowin2026.gprj:62  <File path="ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v" enable="1"/>
Gowin2026.gprj:75  <File path="rtl/w3b/dds_wavetable_core.v"                   enable="1"/>
Gowin2026.gprj:76  <File path="rtl/w3b/voice.v"                                enable="1"/>
Gowin2026.gprj:77  <File path="rtl/w3b/voice_i2s_chain.v"                      enable="1"/>

rpt.txt §3 Resource Usage Summary:
    BSRAM  33/118
      --SDPB     7
      --SDPX9B  16
      --pROM    10          ← 只有 wavetable_bank 的 10 块；sine ROM 的 pROM 不在
```

**机制（带数字）**
- `wavetable_sine_rom_ip` 唯一的例化点：`dds_wavetable_core.v:36`
  （＋ 老 tb 的模型 `tb/models/wavetable_sine_rom_ip_model.sv`）。
- `dds_wavetable_core` 的例化点：`voice.v:56`、`rtl/bringup/wavetable_tone_top.v:56`。
- `voice` 的例化点：`voice_i2s_chain.v:50`。
- `voice_i2s_chain` 的例化点：**全仓 0 个**（`top.v` 里 `grep voice` 只有注释）。
- 综合日志 `impl/gwsynthesis/Gowin2026.log`：
  - `:17-19` 只是 `Analyzing Verilog file`（**解析**，不是综合）；
  - `:170` 有 `Compiling module 'wavetable_bank'`，**全日志没有**
    `Compiling module 'voice'` / `'dds_wavetable_core'` / `'wavetable_sine_rom_ip'`。
  - ⇒ Gowin 只编译**被例化**的模块 ⇒ 这一整棵子树**不在交付网表里**。
- `pROM` 计数 **10** 就是铁证：若 `wavetable_sine_rom_ip` 进了网表，这个数会是 **11**。
- **后果**：`tb/w3b/tb_dds_wavetable_core.sv`（48 行模块，95 行 tb）、
  `tb/voice/tb_voice_accept.sv`（"T10 real-voice acceptance: DDS + pROM wavetable + ADSR"）
  **全绿**，但它们验证的 RTL **一个门都没进 FPGA**。
  同时，这棵子树里的任何缺陷（含 P1-6）**上板永远暴露不出来**，也不会被四道门抓到。

**改法**（三选一）
- **A · 承认它是死代码并下架**：从 `.gprj` 里把
  `ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v`、`rtl/w3b/dds_wavetable_core.v`、
  `rtl/w3b/voice.v`、`rtl/w3b/voice_i2s_chain.v` 的 `enable` 改 `0`
  （保留文件，`tb_dds_wavetable_core` 仍能跑 —— 它走 `sim/tb_all.ps1` 的
  `Get-HdlSources rtl` 自动收集，**不依赖 gprj**）。
  ⚠️ 注意：`sim/tb_all.ps1:53` 是从 `rtl/` **目录**收集源文件，**不看 gprj** ⇒
  改 `enable` **不影响回归**，只影响 PnR 的编译清单（省编译时间）。
- **B · 把它接进 top**：⛔ **不推荐** —— 会凭空多出 1 块 BSRAM（P1-6 那张 512 点表），
  而且 `voice` 是**单音**架构，与 `oscillator_bank` 的 64 lane 是两条互斥路线。
- **C · 保留现状但在文档里钉住**：在 `rtl/w3b/dds_wavetable_core.v` 头注释里加一行
  `// ⚠️ 本模块【不在】Gowin2026.gprj 的例化树里（pROM 计数 10 可证）—— 它是兼容/参考实现`。
  **这是最低成本、也最诚实的做法。**

**预期收益**：消除"回归在给不存在的硬件打分"这个**认知陷阱**；
若做 A，还能省掉 PnR 的 4 个文件解析时间（**量级很小，几十毫秒**）。
**不是时序收益。**

**验证能红**：做 A 后重跑 PnR ⇒ `rpt.txt` 的 `pROM` 必须**仍然是 10**
（证明这 4 个文件本来就没进网表，也证明改动**没有副作用**）；
`sim\tb_all.ps1 -Filter dds` 必须**仍然 PASS**。

**结构性 / 布局运气**：都不是。

**过门要求**：改 `.gprj` ⇒ **必须走四道门**（`gprj` 进 PnR 的编译清单）；
改注释 ⇒ 只需全量回归。**⛔ 不需要同步 `oscillator_bank_ref.v`**。

---

### P1-6 · 512 点表 ＋ 32 bit 相位累加器 ⇒ 9 bit 相位、无插值 ⇒ 相位截断杂散 ≈ −48…−50 dBc

**位置**：`rtl/w3b/dds_wavetable_core.v:17,31,42`；表 `ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:18,31`

**确切代码**
```verilog
// rtl/w3b/dds_wavetable_core.v
17:    reg [31:0] phase_acc;                                    // 32 bit 累加器
31:                phase_acc <= phase_acc + phase_inc_i;
42:        .ad    (phase_acc[31:23])                            // 只取高 9 bit ⇒ 512 点
```
```verilog
// ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v
18:    input [8:0] ad;                                          // 9 bit = 512 项
31:        .AD({gw_gnd,ad[8:0],gw_gnd,gw_gnd,gw_gnd,gw_gnd})    // AD[13:4] = {1'b0, ad}
```

**机制（带数字）**
- 累加器 **32 bit**，表地址 **9 bit** ⇒ **截断 23 bit**。
- 表本身是**理想正弦的精确四舍五入**（`sine_512x16.hex` 首 4 行 = `0000 0192 0324 04B6`，
  与 `32767·sin(2πk/512)` 逐值吻合；`tb_dds_wavetable_core.sv:71-73` 的期望值
  `0 / 402 / 804` 也印证）⇒ **表没有误差，误差全部来自"用截断后的相位查表"**。
- 截断造成的**最大相位误差 = 半个表步 = π/512 = 0.006136 rad**
  ⇒ 输出误差上界 = `32767 × 0.006136 = 201 LSB`
  ⇒ 误差峰峰值 = **402 LSB**，其基波分量 ≈ `402/π = 128 LSB`
  ⇒ 相对满幅：`20·log10(128/32767) = −48.2 dBc`。
- 标准 DDS 相位截断公式（W = 保留相位位数）：`SFDR ≈ 6.02·W − 3.92 = 6.02×9 − 3.92 = 50.3 dBc`
  ⇒ 两条独立估算**互相印证：约 −48 ~ −50 dBc**。
- 对音频的意义：−48 dBc 的杂散在**单音**下接近可闻阈值，在**复音叠加**时会
  以"非谐波边带"形式堆积 ⇒ 这是"数码味/毛刺感"的经典来源之一。
- **附带资源问题**：这张 512 点表（1 块 BSRAM，8 Kbit 有效容量，装在一个 16 Kbit 的
  BSRAM 里 ⇒ **一半容量闲置**）与 `wavetable_bank` 的 `rom_test_sine_inst`
  （`:654-728`，**1024 点纯正弦**：`memory[0]=0`、`[1]=201`、`[256]=32767`、`[512]=0`、
  `[511]=201`）**是同一条正弦的两个分辨率副本** ⇒ 同一块 FPGA 里存了两份。

**改法**（按性价比）
- **① 加 4 bit 线性插值（推荐，收益最大）**：
  ```verilog
  wire [8:0]  a0 = phase_acc[31:23];
  wire [3:0]  frac = phase_acc[22:19];          // 4 bit 小数
  wire [8:0]  a1 = a0 + 9'd1;
  // 需要第二个读口，或把表读改成 2 拍/双端口 ⇒ 见下方代价说明
  wire signed [16:0] interp = $signed({s0[15], s0}) +
      ((($signed({s1[15], s1}) - $signed({s0[15], s0})) * $signed({1'b0, frac})) >>> 4);
  ```
  ⚠️ **代价**：需要 `s0` 与 `s1` **同拍**，即**两个读口**（pROM 是单口）
  ⇒ 要么加**第 2 块 BSRAM**（+1 块，16 Kbit），要么把 `a0`/`a1` 分两个时钟读
  （**破坏 1 拍读契约**，`tb_dds_wavetable_core` 会红）。
  ⇒ **净收益 ≈ +24 dB SFDR（4 bit × 6 dB），代价 +1 BSRAM ＋ 1 个 17×4 乘法器**。
  但 **P1-5 说这个模块根本不在网表里** ⇒ 收益**当前为 0**。
- **② 换用 `wavetable_bank` 的 1024 点表（若有一天真要把 DDS 接进 top）**：
  `phase_acc[31:22]` 取 10 bit ⇒ 相位误差减半 ⇒ **+6 dB**，且**省 1 块 BSRAM**。
- **③ 什么都不做**：如果确认 `dds_wavetable_core` 永远只是兼容/参考实现
  （见 P1-5 选项 C），**就在头注释里写清"本模块不追求 SFDR，禁止用于交付音频通路"**，
  并把这条列进"已知限制"。

**预期收益**：① 是 **+24 dB SFDR**；② 是 **+6 dB ＋ −1 BSRAM**。
⚠️ **在当前交付配置下两者都是 0**（模块不在网表里）⇒ 这条的优先级**取决于 P1-5 的裁定**。

**验证能红**
1. **离线、可复现**：写一个 20 行脚本读 `rtl/w3b/rom/sine_512x16.hex`，
   算 `max_k |32767·sin(2πk/512) − table[k]|` ⇒ 应当 **≤ 0.5**（证明表精确）。
   再算 `max_k |32767·sin(2πk/512) − 32767·sin(2π·floor(k)/512)|` ⇒ 应当 **= 201**（证明误差来自相位）。
2. **在线**：用 `tools/peak_count.py` / `sim/test_mode_fft.ps1` 的既有 FFT 流程，
   跑一个 1 kHz 纯音，看**非谐波边带地板**。
   改造前应当在 **−48 dBc 附近**出现杂散；加 4 bit 插值后必须**下降到 −70 dBc 以下**。
   **这是"能红"的硬判据**（门限 −60 dBc）。

**结构性 / 布局运气**：都不是（信号质量 + 资源）。

**过门要求**：若做 ①/② ⇒ 改 `dds_wavetable_core` ＋ `ip/` ⇒ **必须走四道门**，
且 `tb_dds_wavetable_core.sv:71-80` 的 6 个期望值（`0/402/804/1206/2009/2811`）
**必须重算**（插值会改变输出值）⇒ 这是**判据改动**，按项目纪律必须写明理由。
**⛔ 不需要同步 `oscillator_bank_ref.v`**。

---

### P2-1 · 4 个 `rom_hard_t*` 在交付配置下无消费者，却实占 4 块 BSRAM

**位置**：`rtl/w3b/oscillator_bank.v:86-87,805-812,845-847`；`rtl/top.v:4190-4191`

**确切代码**
```verilog
// rtl/w3b/oscillator_bank.v
86: parameter integer VELOCITY_BLEND_EN = 0,
87: parameter integer FIXED_BLEND_Q     = 0,
...
803:    wire [8:0] mix_q = (VELOCITY_BLEND_EN != 0) ? velocity_mix_q : FIXED_BLEND_Q_W;
805:    wire signed [WT_W:0] blend_delta = {rom_hard[WT_W-1], rom_hard}
806:                                     - {rom_soft[WT_W-1], rom_soft};
807:    wire signed [WT_W+9:0] blend_product = blend_delta * $signed({1'b0, mix_q});
810:    wire signed [WT_W:0] blend_scaled = blend_product[WT_W+8:8];
811:    wire signed [WT_W:0] blend_sum = {rom_soft[WT_W-1], rom_soft} + blend_scaled;
845:    wire signed [WT_W-1:0] rom_dout = test_mode_i ? rom_test
846:                                                  : (resp_drum_q ? rom_noise
847:                                                                 : blend_sum[WT_W-1:0]);
```
```verilog
// rtl/top.v:4190-4191
.VELOCITY_BLEND_EN(0),
.FIXED_BLEND_Q (0),
```

**机制（带数字）**
- `VELOCITY_BLEND_EN = 0` ⇒ `mix_q = FIXED_BLEND_Q_W = FIXED_BLEND_Q = 9'd0`（**常量**）。
- `blend_product = blend_delta × 0 = 0` ⇒ `blend_scaled = 0`
  ⇒ `blend_sum = {rom_soft[15], rom_soft}` ⇒ **`rom_hard` 没有任何消费者**。
- Gowin **不会**删掉已例化的 `pROM` 原语（`defparam INIT_RAM_*` 是物理配置）
  ⇒ `rpt.txt` 实测 **`--pROM | 10`** = soft×4 ＋ **hard×4** ＋ test ＋ noise。
- 功耗折算：BSRAM 总 **64.634 mW / 33 块** ⇒ 每块均摊 **1.96 mW**
  ⇒ 4 块死的 hard ROM ≈ **7.84 mW**（≈ 总功耗 204.092 mW 的 **3.8%**）
  —— **这是按块数均摊的估算，工具不提供实例级分解。**

**改法**
```verilog
// wavetable_bank 加一个参数，默认关掉 hard 表
parameter integer HARD_ROM_EN = 0,
...
generate if (HARD_ROM_EN) begin : g_hard
    pROM rom_hard_t0_inst ( ... );   // 4 块
end else begin : g_hard_off
    assign rom_hard_t0_inst_do = 16'sd0;   // 4 个常量 0
end endgenerate
```
⚠️ **代价**：`tb_wavetable_bank.sv:307-311` 与 `tb_wavetable_bank_prom.sv:217-220` 的
`read_and_check(..., want_hard)` **8 条判据会红** ⇒ 必须把 hard 期望值改成"仅在
`HARD_ROM_EN=1` 时检查"，**这是判据改动，要写明理由**（同 T3 的先例）。
**更小的改法**：只在 `top.v` 侧不做任何事，而在 `wavetable_bank` 的例化里传
`.HARD_ROM_EN(0)`，并让 `oscillator_bank` 的 `blend_delta` 走
`` `ifdef ``/参数分支 ⇒ 两处联动。

**预期收益**：**−4 块 BSRAM（BSRAM 33→29，28%→24.6%）· 估算 −7.8 mW**。
**不是时序收益。**

**验证能红**
1. PnR：`rpt.txt` 的 `--pROM` 必须 **10 → 6**。
2. `Gowin2026.power.html` 的 `BSRAM` 行必须**下降**（A/B 相对比较）。
3. **非空洞性**：把 `HARD_ROM_EN` 置 1 再跑一遍，`pROM` 必须回到 **10**
   ⇒ 证明这个参数**真的在控制物理资源**，不是装饰。

**结构性 / 布局运气**：资源/功耗类。

**过门要求**：改 `wavetable_bank` ＋ `oscillator_bank` ⇒ **四道门**；
🔴 **必须同步 `tb/models/oscillator_bank_ref.v`**（若 `oscillator_bank` 的
`blend_*` 结构改变 ⇒ 新参考副本；若只改 `wavetable_bank` 内部则不需要）。

---

### P2-2 · `TIMBRE_N` / `SAMPLE_W` 是装饰参数

**位置**：`rtl/w3b/wavetable_bank.v:17-20,851-852`

**确切代码**
```verilog
17:    parameter integer TIMBRE_N = 4,
18:    parameter integer TIMBRE_W = 2,
19:    parameter integer DEPTH = 1024,
20:    parameter integer SAMPLE_W = 16
...
851:        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
852:            (DEPTH != 1024) || (SAMPLE_W != 16))
```

**机制**
- 全文引用次数：`TIMBRE_N` = **2**（`:17` 声明 ＋ `:851` 自检）；`SAMPLE_W` = **2**（`:20` ＋ `:852`）；
  `DEPTH` = **3**（`:19`、`:26` 的 `$clog2`、`:852`）；`TIMBRE_W` = **4**（`:18`、`:25`、`:805`、`:851`）。
- 端口 `sample_soft_o/hard_o/test_o/noise_o` 的宽度是 `[SAMPLE_W-1:0]`，
  但内部的 `rom_soft_sel` / `rom_*_do` 全部是**写死的 `[15:0]`**
  ⇒ `SAMPLE_W ≠ 16` 时端口宽度会变，内部仍是 16 bit ⇒ **静默位宽不匹配**（iverilog 会给 warning）。
- `TIMBRE_N` **完全没有功能作用**：`case` 的分支数由 `TIMBRE_W` 和写死的 `2'd0/1/2` 决定，
  与 `TIMBRE_N` 无关。

**改法**：二选一
- **A（推荐）**：删掉 `TIMBRE_N` 与 `SAMPLE_W` 两个参数（**外部 5 个例化点都用默认值**：
  `oscillator_bank.v:849-852`、`tb_wavetable_bank.sv:170`、`tb_wavetable_bank_prom.sv:186`、
  `tb_akwf_wavetables.sv:23`、`tb_wavetable_timbres.sv:25` ⇒ 删了**零影响**），
  并把内部 `[15:0]` 统一改成 `[SAMPLE_W-1:0]`（若保留 `SAMPLE_W`）。
- **B**：保留参数但把 `:851-853` 的自检改成 `$fatal`（同 P0-1），让它**真的**守住契约。

**预期收益**：消除"改了参数却什么都没发生"的错觉。**零面积、零时序。**

**验证能红**：删掉参数后 5 个例化点必须**编译通过**（`iverilog -Wall` 0 error）；
再故意传 `.SAMPLE_W(12)` ⇒ 必须**编译报错**（而不是静默跑）。

**过门要求**：改 `wavetable_bank` 的端口/参数 ⇒ **四道门 ＋ 全量回归**（5 个 tb 受影响）。
**⛔ 不需要同步 `oscillator_bank_ref.v`**（它自己也有同名参数，但 `oscillator_bank`
传给 `wavetable_bank` 的 `.TIMBRE_N(TIMBRE_N)` 若删掉参数会**编译错** ⇒
`oscillator_bank.v:850` 也要一起改 ⇒ **那就需要同步参考副本**）。

---

### P2-3 · `timbre_i` 悬空时仿真（`z` → `default` → t3=PAD）与硅片（tie 0 → t0=BASS）行为不同

**位置**：`rtl/w3b/wavetable_bank.v:808-815`

**确切代码**
```verilog
808:    always @(*) begin
809:        case (timbre_q)
810:            2'd0: begin rom_soft_sel = rom_soft_t0_inst_do; rom_hard_sel = rom_hard_t0_inst_do; end
811:            2'd1: begin rom_soft_sel = rom_soft_t1_inst_do; rom_hard_sel = rom_hard_t1_inst_do; end
812:            2'd2: begin rom_soft_sel = rom_soft_t2_inst_do; rom_hard_sel = rom_hard_t2_inst_do; end
813:            default: begin rom_soft_sel = rom_soft_t3_inst_do; rom_hard_sel = rom_hard_t3_inst_do; end
814:        endcase
815:    end
```

**机制（带数字）**
- `case`（**不是 `casez`**）对 `2'bzz`：`2'd0/1/2` **都不匹配** ⇒ 落 `default` ⇒ **选 t3 = PAD**。
- 硅片：`oscillator_bank` 若某天忘了接 `.timbre_i(...)`，综合器把该输入 **tie 到 0**
  ⇒ `timbre_q = 2'd0` ⇒ **选 t0 = BASS**。
- ⇒ **仿真给 PAD、上板给 BASS**，且**两条路都不报错**。
- 这正是本项目**已经踩过**的坑的同族：`oscillator_bank.v:699-707` 的
  `voice_drum_i` 悬空 = `z` ⇒ 用 `=== 1'b1` 兜底，注释原文：
  > "🔴 若直接拿 `z` 当三目选择端 ⇒ `rom_dout` 变成 `x` ⇒ **所有老用例集体假红**"

**现状**：**当前 5 个例化点全部接了 `timbre_i`**（`oscillator_bank.v:856`、
`tb_wavetable_bank.sv:172`、`tb_wavetable_bank_prom.sv:188`、
`tb_akwf_wavetables.sv:25`、`tb_wavetable_timbres.sv:27`）
⇒ **今天不发作**。这是**潜伏**项。

**改法**（与 `voice_drum_i` 完全同构）
```verilog
// 加一条与 oscillator_bank 同族的显式口径
wire timbre_valid = (timbre_i === 2'b00) || (timbre_i === 2'b01) ||
                    (timbre_i === 2'b10) || (timbre_i === 2'b11);
wire [TIMBRE_W-1:0] timbre_safe = timbre_valid ? timbre_i : {TIMBRE_W{1'b0}};
...
if (rd_en_i) timbre_q <= timbre_safe;
```
成本：**4 个 2 bit 全等比较器（≈8 LUT）**。
收益：悬空 ⇒ 仿真和硅片**都**给 t0（BASS），行为一致且**显式**。

**验证能红**：写一个只接 `clk_i/rst_n_i/rd_en_i/addr_i` 的探针 tb（**不接 `timbre_i`**），
断言 `sample_soft_o` 等于 **t0 的表**（373）。改造前会得到 **t3 的值（917）** ⇒ 判据红。

**过门要求**：改 `wavetable_bank` ⇒ 四道门。**⛔ 不需要同步 `oscillator_bank_ref.v`**。

---

### P2-4 · `sample_test_o` / `sample_noise_o` 绕过 `timbre_q`，在 `oscillator_bank` 里用未寄存的 `test_mode_i` 选择 ⇒ 换档那一帧混表

**位置**：`rtl/w3b/wavetable_bank.v:830,837`；`rtl/w3b/oscillator_bank.v:845-847`

**确切代码**
```verilog
// wavetable_bank.v
827:    assign sample_soft_o = rom_soft_sel;      // ← 走 timbre_q mux（寄存选择）
828:    assign sample_hard_o = rom_hard_sel;
830:    assign sample_test_o = rom_test_sine_inst_do;   // ← 【绕过】mux
837:    assign sample_noise_o = rom_noise_inst_do;      // ← 【绕过】mux

// oscillator_bank.v
845:    wire signed [WT_W-1:0] rom_dout = test_mode_i ? rom_test          // ← 未寄存
846:                                                  : (resp_drum_q ? rom_noise   // ← 寄存 ✅
847:                                                                 : blend_sum[WT_W-1:0]);
```

**机制（带数字）**
- `resp_drum_q` 是**与 ROM 数据同拍**的寄存标签（`oscillator_bank.v:787-794`），
  所以鼓表切换**帧对齐**。
- `test_mode_i` **没有对应的寄存器标签** ⇒ 它在 TDM 帧的**任意一拍**变化时，
  该帧里 `cnt < k` 的 lane 取正弦表、`cnt ≥ k` 的 lane 取音色表
  ⇒ **一帧（64 个 lane）里混两张表**。
- 一帧 = 1/48828 s ≈ **20.5 µs**，混表 ⇒ 一次宽带咔哒。
- 触发条件：`test_mode_i` 由顶层模式切换驱动（`top.v` 侧），
  **只要在音频播放中切档就会发生**（概率 = 切档发生在 64 拍窗口内的概率 = **64/1024 = 6.25%**）。

**改法**（照抄 `resp_drum_q` 的写法，**零风险**）
```verilog
// oscillator_bank.v：加一个与 ROM 数据同拍的 test 标签
reg resp_test_q;
always @(posedge clk_i) begin
    if (!rst_n_i)         resp_test_q <= 1'b0;
    else if (req_active)  resp_test_q <= test_mode_i;
end
wire signed [WT_W-1:0] rom_dout = resp_test_q ? rom_test
                                              : (resp_drum_q ? rom_noise
                                                             : blend_sum[WT_W-1:0]);
```
成本：**+1 FF**。收益：切档**帧对齐**，杂音从"每次切档 6.25% 概率一次咔哒"降到 **0**。

**验证能红**
1. `sim\tb_all.ps1 -Filter wavetable` / `-Filter oscillator` 全 PASS。
2. **非空洞性**：把 `resp_test_q` 故意换成 `test_mode_i`（即改回旧写法），
   写一个 tb 在**帧中间**（`cnt == 32`）翻转 `test_mode_i`，断言该帧的
   `osc_sample_bus_o` 的 64 个 lane **全部来自同一张表**
   ⇒ 旧写法**必须红**（帧内混表），新写法**绿**。

**过门要求**：改 `oscillator_bank` ⇒ **四道门 ＋ 同步 `tb/models/oscillator_bank_ref.v`**
（`osc_sample_bus_o` 的逐位值在切档那一帧会变 ⇒ `tb_p5_osc_equiv` 的
**E 段（test 档 20 帧）**必须同步更新参考，否则会红）。

---

### P2-5 · `tb_p5_osc_equiv` 的参数集 ≠ 交付配置 ⇒ "逐位等价"门不覆盖交付

**位置**：`tb/w3b/tb_p5_osc_equiv.sv:59-68` vs `rtl/top.v:4204-4205`

**确切代码**
```verilog
// tb/w3b/tb_p5_osc_equiv.sv:59-68
oscillator_bank_ref #(
    ... .VELOCITY_BLEND_EN(0), .FIXED_BLEND_Q(0), .ENABLE_FM(0),
    .DETUNE_ON(1), .DETUNE_SH(9),
    .DRUM_PITCH_ENV_EN(1), .DRUM_SWEEP_SH(10), .DRUM_SWEEP_LSB_SH(8),
    .DRUM_KICK_SWEEP_SH(0), .DRUM_TOM_SWEEP_SH(2),
    .DRUM_KICK_MAX(10_000_000), .DRUM_TOM_MAX(15_000_000),      // ← 15M / 2
    .DRUM_CLICK_EN(0)
) u_ref ( ... );
```
```verilog
// rtl/top.v:4204-4205（交付配置）
.DRUM_TOM_MAX     (20_000_000),      // ← 20M
.DRUM_TOM_SWEEP_SH(3),               // ← 3
```

**机制（带数字）**
- 等价 tb 用的是 `DRUM_TOM_MAX=15_000_000` / `DRUM_TOM_SWEEP_SH=2`
  ⇒ 嗵鼓档上界 **167.6 Hz**、扫频深度 **1/4**。
- 交付是 `20_000_000` / `3` ⇒ 上界 **223.3 Hz**、深度 **1/8**。
- ⇒ `[167.6, 223.3) Hz` 这一段在**交付**里被判成"嗵鼓"，在**等价 tb** 里被判成"军鼓/踩镲"
  ⇒ **一个完整的参数分区在等价判据里是空的**。
- ⇒ 若有人改 `oscillator_bank` 的鼓分档/扫频逻辑，只要**只在 20M/3 区间**出错，
  `tb_p5_osc_equiv` **照样 0 mismatch 绿**，四道门的第②道门**形同虚设**。
- 这是 `C83`（探针假绿）的**参数维度**版本。

**改法**
- **A（推荐）**：把 `tb_p5_osc_equiv.sv:59-68` 的参数**逐项改成 `top.v` 的交付值**
  （`DRUM_TOM_MAX=20_000_000`、`DRUM_TOM_SWEEP_SH=3`，
  并核对 `DRUM_KICK_MAX` / `DRUM_SWEEP_SH` / `DRUM_SWEEP_LSB_SH` / `DETUNE_SH`）。
  ⚠️ **改完必须重跑**，且**必须确认参考副本 `oscillator_bank_ref.v` 支持这些参数**
  （它是改动前的实现，参数列表可能不全 ⇒ 可能需要给参考副本补参数默认值）。
- **B（更强）**：参数化成两套配置各跑 320 帧（交付档 ＋ 边界档）。

**预期收益**：让第②道门**真的覆盖交付配置**。**零面积、零时序。**

**验证能红**：做 A 后，故意把 `oscillator_bank` 的 `DRUM_TOM_MAX` 比较写成
`> 20_000_001`（只影响交付档）⇒ `tb_p5_osc_equiv` **必须变红**。
改造前**不会红**（这就是"能红"的证明）。

**过门要求**：只改 tb ⇒ 不触发四道门，但**必须跑一次全量回归**确认
"通过数 == 共数"；🔴 若同时给 `oscillator_bank_ref.v` 补参数 ⇒
那是改 `tb/models/`，仍只需全量回归。

---

### P2-6 · `wavetable_bank` 的 `initial` 自检在 Gowin 综合里被静默丢弃

**位置**：`rtl/w3b/wavetable_bank.v:850-854`；证据 `impl/gwsynthesis/Gowin2026.log`

**确切代码**
```verilog
850:    initial begin
851:        if ((TIMBRE_N != 4) || (TIMBRE_W != 2) ||
852:            (DEPTH != 1024) || (SAMPLE_W != 16))
853:            $display("ERROR [wavetable_bank] fixed pROM contract is 4x1024x16");
854:    end
```

**机制**
- `impl/gwsynthesis/Gowin2026.log` 里 `wavetable_bank` 段（`:170` 附近）
  **0 条 warning / 0 条 error**，而同一个日志对 `note_manager.v` / `oscillator_bank.v`
  都给了 `WARN (EX3791) Expression size ... truncated`。
  ⇒ Gowin **既没实现也没警告**，直接丢弃了这个 `initial` 块。
- 同一份文件里的 `oscillator_bank.v:902-926` 有 5 个同类自检（`LANES>1024`、
  `TIMBRE_OK`、`DRUM_KICK_MAX` 截断…）—— **全部同一个命运**。
- 项目里已有正确的反例：`tb/models/prom_model.sv` 用 `initial` 做**仿真专用**初始化
  （那是合法的，因为它是 tb 模型），但**生产 RTL 里的 `initial` 自检**
  既拦不住综合也拦不住回归（见 P0-1 第 2/3 点）。

**改法**（三选一，推荐 A）
- **A · 改成 `$fatal` ＋ 在回归里能红**（同 P0-1）：`$fatal(1, "ERROR ...")`
  ⇒ `vvp` 退出码非零 ⇒ `sim/tb_all.ps1:348` 判失败。**这是唯一真正"能红"的写法。**
- **B · 生成期检查**：把契约写进 `tools/gen_t31b_wavetable.py`
  （表生成脚本本来就知道 4×1024×16）⇒ 生成阶段就断言。
- **C · 综合期检查**：用 `` `ifdef `` ＋ `$error`（Gowin 支持 `$error` 在
  elaboration 期报错）—— ⚠️ **需要先验证 Gowin 对 `$error` 的支持**，
  否则又是"看起来能红其实不能"。

**预期收益**：把"参数写错没人拦"变成"参数写错编译不过"。**零面积。**

**验证能红**：把 `:851` 的条件改成永真（`if (1)`）＋ `$fatal` ⇒
`sim\tb_all.ps1 -Filter wavetable` 必须报 `FAIL:` 且汇总不是"通过 N / 共 N"。

**过门要求**：改 `wavetable_bank` ⇒ 四道门。**⛔ 不需要同步 `oscillator_bank_ref.v`**。

---

### P2-7 · 10 块 pROM 共用 `addr_i` / `rd_en_i` / `~rst_n_i` ⇒ 必须同 region 布局

**位置**：`rtl/w3b/wavetable_bank.v:60,135,210,285,360,435,510,585,660,735`（AD）·
`:58,133,…733`（CE）· `:59,134,…734`（RESET）

**机制（带数字）**
- 同一条 `addr_i[9:0]` 驱动 **10 × 10 = 100 个 AD 位**（每块只有 `AD[13:4]` 有效，
  `AD[3:0]` 被 tie 0）。
- 同一条 `rd_en_i` 驱动 **10 个 CE** ＋ `valid_o` FF ＋ `timbre_q` FF 的使能 = **12 个负载**。
- 同一条 `~rst_n_i` 驱动 **10 个 RESET** ＋ 2 个 FF 的复位 = **12 个负载**。
- GW5AT-60B 的 BSRAM 按 **region** 分布；10 块 BSRAM 若被布局器撒到不同 region，
  这 3 条网就变成**跨 region 长线**，其延迟会直接吃掉 `set_max_delay 18.181` 的预算。
- 由于 §5 R-1 说这条锥**当前不在 top-50 关键路径里**，所以**今天没发作** ——
  但它是**布局运气**：同源重跑差 2~3 MHz（`constr/top.sdc:54-55`）说明布局器的自由度很大，
  10 块 BSRAM 的相对位置**没有任何约束**。

**改法**
- **A · 加布局约束**（零 RTL 改动）：在 `constr/top.cst` / 综合属性里把 10 块 pROM
  约束到**同一个 region**（Gowin 用 `INS_LOC`/`REGION` 属性；
  ⚠️ **必须先查本机 Gowin 版本的属性语法**，`build_cli.tcl` 里可能有先例）。
- **B · 合并表结构**（改动大）：把 soft/hard 对合成 2048×16 的单块（`AD[10]` 选档），
  ⛔ **但 soft 与 hard 必须同拍可用**（`blend_delta` 同时要两者）⇒ **B 不可行**，
  除非同时关掉 `VELOCITY_BLEND_EN`（那正是 P2-1 的路线）。
  ⇒ **P2-1 ＋ B 一起做**：关掉 blend ⇒ 每音色只剩 1 张表 ⇒ 4 块 BSRAM
  （1024×16 每块，**没法再合**），总 pROM 从 10 → **6**。
- **C · 门控 CE（P1-3）后**，CE 网从 1 条变成 4 条，每条 2 个负载
  ⇒ **跨 region 风险反而下降**（每条更短），**这是 P1-3 的附带收益**。

**预期收益**：A 是**抗布局噪声**（不提升期望值，但降低方差）；
C 是**降低长线风险**。**都无法量化成 Fmax 提升**（因为当前不在关键路径）。

**验证能红**
1. 做 A 后，看 `impl/pnr/Gowin2026.rpt.html` 的 **Clock Region** 分布，
   10 块 pROM 必须落在同一 region。
2. **A/B 实测**：同一份 RTL 连跑 **2 次 PnR**，比较 `Fmax`
   —— 若加了约束后方差从 **2~3 MHz** 收敛到 **<1 MHz**，则 A 有效。
   ⚠️ **这是唯一能证明"布局运气"的判据，必须跑 A/B/A/B 至少 4 次**。

**过门要求**：改 `constr/` ⇒ 四道门（PnR 是第③道门的主体）。
**⛔ 不需要同步 `oscillator_bank_ref.v`**。

---

### P3-1 · `rom_*_do` / `rom_soft_sel` 是 unsigned，端口是 signed

**位置**：`rtl/w3b/wavetable_bank.v:33-52`（20 根 `wire [15:0]`）· `:805-807`（`reg [15:0]`）
· `:827-828`（`assign` 到 `output wire signed [15:0]`）

**机制**：等宽（16 → 16）赋值只是位拷贝，**signedness 不参与** ⇒ **今天零影响**。
但 `oscillator_bank.v:805-806` 的 `{rom_hard[WT_W-1], rom_hard}` 依赖
**端口**的 signed 语义（`wire signed [WT_W-1:0] rom_hard`，`oscillator_bank.v:754-755`）
—— 这个是正确的。风险在**未来**：若 `WT_W` 改成 17/18（为混音留 headroom），
内部 `[15:0]` 的 unsigned 声明会让 `{rom_hard[16], rom_hard}` 这类扩展**静默零扩展**。

**改法**：把内部线/寄存器统一声明为 `signed`（或统一用 `wire signed [SAMPLE_W-1:0]`）。

**预期收益**：零面积、零时序，纯防错。

**验证能红**：把 `SAMPLE_W` 改成 17 并跑一个 tb ⇒ 改造前会出现
**正半周正确、负半周被抬成正值**（零扩展）⇒ 明显红。

**过门要求**：改 `wavetable_bank` ⇒ 四道门。

---

### P3-2 · `dds_wavetable_core` 缺 `` `default_nettype none ``

**位置**：`rtl/w3b/dds_wavetable_core.v:1-15`；反例 `rtl/w3b/wavetable_bank.v:15,856`

**机制**：`wavetable_bank` 用 `` `default_nettype none `` ＋ 结尾 `` `default_nettype wire ``
（正确的成对写法）。`dds_wavetable_core` **两个都没有** ⇒
端口名拼错（例如把 `.phase_inc_i` 写成 `.phase_in_i`）会**静默生成一个隐式 1 bit 线网**
（Verilog-2001 隐式线网规则），iverilog `-Wall` 只会给一条 warning，**回归不会红**。

**改法**：照抄 `wavetable_bank.v:15` 与 `:856` 的两行。

**预期收益**：零面积，把"拼错端口"从静默变成编译错误。

**验证能红**：加完之后，故意把 `.ad(phase_acc[31:23])` 写成 `.addr(...)`
⇒ 必须**编译报错**（而不是静默）。

**过门要求**：改 `dds_wavetable_core` ⇒ 四道门（但它不在网表里，见 P1-5
⇒ 实际只需 ① 综合 `ERROR=0` ② `-Filter dds` ③④）。

---

### P3-3 · `OCE(1'b1)` 在 `READ_MODE=0` 下无作用

**位置**：`rtl/w3b/wavetable_bank.v:57,132,…732`（10 处）；`rtl/w3b/dds_wavetable_core.v:39`

**机制**：`tb/models/prom_model.sv:173,176-185`：
```verilog
173:    assign DO = (READ_MODE == 1'b0) ? bp_reg : pl_reg;
181:            if (OCE) pl_reg <= bp_reg;          // ← OCE 只控制 pipeline 级
183:            if (CE)  bp_reg <= {16'd0, memory[AD[13:4]]};   // ← bypass 级由 CE 控制
```
`READ_MODE=0` ⇒ `DO = bp_reg`，`OCE` **完全不参与**。
⇒ 10 个 `OCE(1'b1)` 常量是**装饰**（Gowin 会 tie 掉，不占资源）。
⚠️ **但要注意**：真实 Gowin 原语在 `READ_MODE=0` 时 `OCE` 的行为**官方文档没有明说**，
模型是**项目自己写的**。若某天把 `READ_MODE` 改成 1，`OCE(1'b1)` 会让 pipeline 级
**永远使能** ⇒ 变成"无条件 2 拍"，而 `timbre_q` 仍是 1 拍 ⇒ **车道错位**
（正是 `wavetable_bank.v:817-826` 注释警告的 `K-167` 前科）。

**改法**：把 `OCE` 从 `1'b1` 改成与 `CE` 同源（`OCE(rd_en_i)`）
⇒ 无论 `READ_MODE` 怎么改，两级寄存器的使能**永远一致**。
成本：**0**（只是把常量换成已有的 `rd_en_i`，扇出 +10）。
收益：消除"改 `READ_MODE` 就车道错位"的雷。

**验证能红**：把 `READ_MODE` 改成 1（**两级延迟**）⇒ `tb_wavetable_bank.sv:290`
的 `valid_o !== 1'b1` **必须红**（因为数据晚了 1 拍）。
**改造前也红**（`OCE=1'b1` 时 pipeline 级无条件更新）——
所以这条的"能红"是：**改 `READ_MODE=1` 时必须红**，
这证明"1 拍读契约"这个判据是活的。

**过门要求**：改 `wavetable_bank` ⇒ 四道门。

---

### P3-4 · 注释与代码互斥（两处）

**位置 A**：`rtl/w3b/wavetable_bank.v:817-826`
```verilog
817:    // 🔴 2026-10-01 更正：⭐ **旧注释把两种模式写反了**（⭐ 旧文说 `READ_MODE=0` 同拍返回、
818:    //    `READ_MODE=1` 才是 1 拍）⇒ ⛔ 下面才是与代码/模型一致的版本。
819:    // READ_MODE=0 (By-pass) = BRAM 读寄存器 = **1 拍**读延迟，符合
...
822:    // READ_MODE=1 (Pipeline) 会**再加一级输出寄存器 = 2 拍**
```
✅ 这段**与代码/模型一致**（`prom_model.sv:168-173`）—— **不需要改**。

**位置 B（真正的冲突）**：`rtl/w3b/oscillator_bank.v`
```verilog
814:    //   ⭐ `VEL_TIMBRE_BLEND = 0`（默认）⇒ ⭐ **固定 `rom_hard`**（⭐ 音色只由 `timbre` 决定）✅
817:    //  ⚠️⚠️ 2026-09-29 上板实测修正：⭐ **固定用 `rom_hard`，⛔ 不是 `rom_soft`**
...
832:    //   ⭐ `FIXED_BLEND_Q = 0` ⇒ ⭐ `blend_sum = rom_soft` ⇒ ⭐ 用 **AKWF 的 soft 表**（⭐ 平滑档 ✅）
```
**代码实际是哪个**：`FIXED_BLEND_Q = 0` ⇒ `mix_q = 0` ⇒ `blend_product = 0`
⇒ `blend_sum = {rom_soft[15], rom_soft}` ⇒ `rom_dout = blend_sum[15:0] = rom_soft`
⇒ 🔴 **实际交付走 `rom_soft`**，`:814` / `:817-820` 的"固定 `rom_hard`"**是错的**，
`:832` 才是对的。
⇒ 这与项目已知问题 ③（`tdm_render_mixer.v` 注释三项全错）**同一家族**。
⚠️ 附带：`:819-820` 说 `rom_soft` 是"峰值 16384、音量砍半"的旧表 ——
**也不成立**：`rom_soft_t0` 的 `INIT_RAM_10 = 256'h7FD3…` ⇒ 峰值 **32723**，
`rom_hard_t0` 的 `INIT_RAM_10 = 256'h7F69…` ⇒ 峰值 **32617**，**两张都是满幅**。

**改法**：删掉 `oscillator_bank.v:814` 与 `:817-820` 的"固定 `rom_hard`"结论，
统一写成"默认 `FIXED_BLEND_Q=0` ⇒ 走 `rom_soft`（AKWF soft 档），两张表都是满幅"。

**预期收益**：零面积。**但这条会误导后续优化**（例如有人按注释去"修"表选择）。

**验证能红**：写一个 tb 设 `VELOCITY_BLEND_EN=0, FIXED_BLEND_Q=0`，
逐点比对 `osc_sample_bus_o` 与 `rom_soft` 表 ⇒ 必须逐位相等
（证明代码走 soft）；再与 `rom_hard` 比 ⇒ 必须**不等**（证明注释错）。

**过门要求**：只改注释 ⇒ 不触发四道门，但按纪律仍需跑一次全量回归。

---

### P3-5 · 死线：10 根 `rom_*_inst_dout_w[15:0]`

**位置**：`rtl/w3b/wavetable_bank.v:34,39,44,49,50,52,55,130,…655,730`

**机制**：`.DO({rom_soft_t0_inst_dout_w[15:0], rom_soft_t0_inst_do[15:0]})` ——
`DO` 是 32 bit，但 `BIT_WIDTH=16` ⇒ 只有低 16 bit 是数据。
`*_dout_w` 这 10 根线**只出现在拼接里，从不被读**。
✅ **这不是 bug**（Gowin 官方生成器也这么写，见
`ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:20,26`），
且 `DO` 高 16 bit 在真实原语里是 **don't-care**（模型 `prom_model.sv:184` 补 0）。
⇒ **保留即可，⛔ 不要"清理"** —— 删掉会让拼接变成 16 bit，与 32 bit 的 `DO` 端口
宽度不匹配（iverilog 会给 warning，且与官方模板不一致）。

**结论**：**列为"已知无害"，不改。**

---

## 4. 优先级判据（本文用的口径）

| 级别 | 定义 | 本文条目 |
|---|---|---|
| **P0** | **静默失效**：触发即产生错误数据/错误行为，而**四道门里没有任何一道能抓住** | P0-1 |
| **P1** | 触发条件**已经存在**（改参数 / 换配置 / 上层接线一变就错），或**会打破时序**但当前靠余量撑住；或**判据本身失效** | P1-1 ~ P1-6 |
| **P2** | 资源 / 功耗 / 抗布局噪声：不会错也不会破时序，但有**可量化的收益** | P2-1 ~ P2-7 |
| **P3** | 文档 / 一致性 / 防错：零面积，防未来的坑 | P3-1 ~ P3-5 |

---

## 5. 反证清单（**明确"不是 bug"或"没有证据"的项 —— ⛔ 不要再去改**）

### R-1 · **没有任何证据表明 `wavetable_bank` / `oscillator_bank` 在关键路径上**

- `impl/pnr/Gowin2026.timing_paths` 共 **50** 条路径（`=====` 分隔符计数），
  按层次统计节点数：

  | 层次 | 节点数 |
  |---|---|
  | `g_sound.u_note_manager` | **205** |
  | `g_sound.u_tdm_render_mixer` | **139** |
  | `g_sound.u_looper` | 24 |
  | `u_led_indicator` | 12 |
  | `u_ws2812` / `u_i2s_tx` | 6 / 6 |
  | `g_sound.u_master_mix` / `g_sound.u_envelope_bank` | 3 / 3 |
  | **`g_sound.u_oscillator_bank`** | **0** ← |
  | **`g_sound.u_wavetable_bank`** | **0** ← |

- `sim/evidence/gowin_m0_timing.txt`：`clk_sys` **Actual Fmax = 55.313 MHz**，
  **Logic Level = 7**，`Numbers of Setup Violated Endpoints = 0`，
  `Numbers of Hold Violated Endpoints = 0`。
- ⇒ **本文里所有"时序类"条目（P1-4、P2-7）都必须标为"预防性"，
  ⛔ 不许宣称 Fmax 提升。** 要证明收益只能靠 §3 P2-7 的 A/B/A/B 多次 PnR。

### R-2 · "同源重跑差 2~3 MHz"是**布局噪声**，不是 RTL 问题

`constr/top.sdc:54-55` 原文：
> `Fmax` 掉到 **45.815 MHz** ⇒ **PnR FAIL**（门槛 51.5）·
> ⚠️ 而同一份 RTL 在别的布局下 `Fmax` 是 **52.0~55.7** ⇒ **这条约束让结果对布局极度敏感**

⇒ **单次 PnR 的 Fmax 不能作为 RTL 改动的证据**；任何 RTL 收益必须做 **A/B/A/B ≥ 4 次**。

### R-3 · `.AD({addr_i[9:0], 4'b0000})` 的**位序是对的** —— 别再"修"

三重印证（`BIT_WIDTH=16` 时字地址在 `AD[13:4]`）：
1. `ip/wavetable_sine_rom_ip/wavetable_sine_rom_ip.v:31`
   → `.AD({gw_gnd,ad[8:0],gw_gnd,gw_gnd,gw_gnd,gw_gnd})`（1＋9＋4 = 14，9 bit 地址落在 `[12:4]`）
2. `tb/models/prom_model.sv:175,184`
   → `// BIT_WIDTH=16 uses AD[13:4] as the word address` ＋ `memory[AD[13:4]]`
3. 探针实测（§3 P0-1）：`DEPTH=1024` 时 `addr 0/1` 分别读出 `373/597`，
   与 `rom_soft_t0` 的 `INIT_RAM_00 = …0255 0175` 逐值吻合

⇒ `{addr_i[9:0], 4'b0000}` 把 `addr_i` 放进 `AD[13:4]`，**正确**。
**P0-1 的问题只是"9:0"这个字面量，不是位序。**

### R-4 · `rom_test_sine_inst` 是 **1024 点纯正弦**，不是 512 点表零填充

实测（`rtl/w3b/wavetable_bank.v:665-697`）：
`memory[0]=0x0000`、`memory[1]=0x00C9=201`、`memory[256]=0x7FFF=32767`、
`memory[511]=0x00C9=201`、`memory[512]=0x0000`、`memory[513]=0xFF37=−201`。
（📌 取值规则见 `tb/models/prom_model.sv:92-93`：
`memory[base + i] = bits[i*16 +: 16]` ⇒ **每条 `INIT_RAM_*` 的【最右】4 位十六进制 = 该块的第 0 项**。
⛔ 反过来读会得到"峰在 index 271"的错误结论。）
⇒ 步长 **201 ≈ 32767·sin(2π/1024)** ⇒ **1024 点**。
而 `sine_512x16.hex` 的步长是 **402**（`0000 0192 0324 04B6`）⇒ **512 点**。
⇒ 两者是**同波形不同分辨率**（P1-6 提到的是"同波形双份存储"），
⛔ **不是**"1024 = 512 抄两遍"（那会得到 `memory[512]=0` 但 `memory[511]=0`，与实测不符）。

### R-5 · `sine_512x16.hex` 与 `wavetable_sine_rom_ip.v` 的常量**逐值一致**

| 索引 | `rtl/w3b/rom/sine_512x16.hex` | `ip/.../wavetable_sine_rom_ip.v` `INIT_RAM_00` 低位起 |
|---|---|---|
| 0 | `0000` | `0000` |
| 1 | `0192` | `0192` |
| 2 | `0324` | `0324` |
| 3 | `04B6` | `04B6` |

⇒ 目前**没有** sim/硅片漂移。
⚠️ **但机制上仍脆弱**：`tb/models/wavetable_sine_rom_ip_model.sv:17` 用
`$readmemh("rtl/w3b/rom/sine_512x16.hex")` 从**文件**载入，而硅片走 `INIT_RAM_*`
**常量**。任何一方改动而另一方不同步 ⇒ 仿真绿、上板错。
**建议**：在 `tools/` 里加一条"hex ↔ `INIT_RAM_*` 逐值比对"的机械检查
（与 `tools/check_ps1_encoding.ps1` 同一套路）。**这是新增判据，不是 bug。**

### R-6 · `blend_sum` **不会**溢出（我原来的怀疑不成立）

`wire signed [WT_W:0] blend_sum = {rom_soft[15], rom_soft} + blend_scaled;`
`blend_scaled = blend_product[24:8]`，而 `mix_q ≤ 9'd256`
⇒ `blend_scaled = (hard − soft) × 256 / 256 = hard − soft`
⇒ `blend_sum = soft + (hard − soft) = hard ∈ [−32768, 32767]`
⇒ **17 bit 足够，`[15:0]` 截断无损。** ⇒ ⛔ **不要"修"这里。**

### R-7 · `valid_o` / `timbre_q` 与 pROM 数据的**同拍关系是正确的**

`CE = rd_en_i`（`:58`）与 `timbre_q <= timbre_i`（`:846`）在**同一个时钟沿**、
**同一个使能条件**下更新 ⇒ 响应（ROM 数据）与标签（`timbre_q`）**天然对齐**。
`oscillator_bank.v:733-737` 的 `valid_r <= (cnt == LANES[LW:0])` 也与此一致
（`oscillator_bank.v:867-868` 注释"当 `cnt == k+1` 时 `rom_dout` 是 lane k 的样本"）。
⇒ **`tb_wavetable_bank.sv:307-311` 的 5 条 `read_and_check` 与
`tb_p5_osc_equiv` 的 320 帧 0 mismatch 都印证了这一点。** ⛔ 不要动这条协议。

---

## 6. 附录 · P0-1 探针源码与实测输出

**源码**：`review/raw/_probe_depth.v`（本报告新增，保留作证据）

```verilog
`timescale 1ns/1ps
module tb_probe_depth;
    reg clk = 1'b0; reg rst_n = 1'b0; reg rd_en = 1'b0;
    reg [1:0] timbre = 2'd0; reg [10:0] addr = 11'd0;
    wire signed [15:0] s_soft, s_hard, s_test, s_noise; wire valid;
    always #10 clk = ~clk;
    wavetable_bank #(.TIMBRE_N(4), .TIMBRE_W(2), .DEPTH(2048), .SAMPLE_W(16)) dut (
        .clk_i(clk), .rst_n_i(rst_n), .rd_en_i(rd_en), .timbre_i(timbre), .addr_i(addr),
        .sample_soft_o(s_soft), .sample_hard_o(s_hard),
        .sample_test_o(s_test), .sample_noise_o(s_noise), .valid_o(valid));
    task rd; input [10:0] a; begin
        @(negedge clk); addr = a; rd_en = 1'b1; @(negedge clk);
        $display("PROBE addr=%0d -> soft=%0d", a, s_soft); end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1'b1;
        rd(11'd0); rd(11'd1); rd(11'd1024); rd(11'd1025);
        $finish;
    end
endmodule
```

**实测输出**
```
$ iverilog -g2012 -s tb_probe_depth -o build/sim/probe_anvil04/p.vvp `
      review/raw/_probe_depth.v rtl/w3b/wavetable_bank.v tb/models/prom_model.sv
--- exit=0 ---
$ vvp build/sim/probe_anvil04/p.vvp
ERROR [wavetable_bank] fixed pROM contract is 4x1024x16
PROBE addr=0 -> soft=373
PROBE addr=1 -> soft=597
PROBE addr=1024 -> soft=373
PROBE addr=1025 -> soft=597
--- run exit=0 ---
```

**读法**
1. `ERROR` 行**打出来了** ⇒ 守卫**看见了**参数错误；
2. `vvp` **退出码 0** ⇒ `sim/tb_all.ps1:348` 的 `$runExit -ne 0` **不成立**；
3. 日志里**没有 `FAIL:` 行** ⇒ 正则也不成立；
4. `sim/tb_all.ps1:347` 只把 `ERROR` 行**计数**，`:349/:352` 明确写"属诊断信息"/"不算失败"
   ⇒ **四道门全部放行**；
5. 而 `addr 1024` 与 `addr 0` **同值** ⇒ 表读错了。

⇒ **这就是 P0-1 的完整证据链。**

---

*ANVIL-04 · 波表与渲染 · 审计完毕。19 条结论 · 7 条反证 · 1 份可复现探针。*
