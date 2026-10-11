# tb_all.ps1 —— 一条命令跑全部 tb（L0 交付物 T1）
#
# ⚠️⚠️ 本文件必须保存为【UTF-8 with BOM】。Windows PowerShell 5.1 对无 BOM 的 .ps1
#     按本地代码页（GBK）解码 ⇒ 中文注释变乱码 ⇒ 直接 `Unexpected token '}'` 解析失败。
#     历史上这个脚本就是因此从没被真正跑通过（T1 一直没验收）。
#
# ⭐ 用法（本机只装了 Windows PowerShell 5.1，⛔ 没有 pwsh 7；下面这条在 5.1 与 7 上都能跑）：
#     powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1
#     powershell -NoProfile -ExecutionPolicy Bypass -File sim\tb_all.ps1 -Filter tlc
#
# ⚠️ 为什么必须带 -ExecutionPolicy Bypass：本机执行策略禁止直接运行 .ps1
#     （`& .\sim\tb_all.ps1` 会报 "running scripts is disabled on this system"）。
#     ⛔ 不要为此去改全局执行策略 —— 带上这个开关就够了。
#
# 做什么：自动发现 tb/**/tb_*.sv → 逐个用 iverilog 编译（RTL + tb/models + tb/checkers + 该 tb）
#         → 跑 vvp → 汇总通过/失败 → 证据落 sim/evidence/。
# 判定（⭐ 结论约定）：**tb 自己给结论** —— 编译/运行非零退出、或日志出现行首 `FAIL` ⇒ 该 tb 失败。
#       ⛔ **不把 `ERROR` 当失败**：T3 的负向测试会**故意**打印 `ERROR [A3]/[A6]/[A8]`，
#          那正是"断言确实会触发"的证据。ERROR 行只做计数与展示。
#       X 传播由 `tb/checkers/chk_xprop.sv`（A8）在每个 tb 里主动监视。
param([string]$Filter = "", [int]$TimeoutSec = 120)

$ErrorActionPreference = "Continue"

# ⭐ 定位仓库根：用 $PSScriptRoot（本脚本在 sim/ 下 ⇒ 上一级即仓库根）。
#    ⛔ 不要用 $MyInvocation.MyCommandPath —— 它在 PS 5.1 下为 $null，
#       会让 $root 变成 null、所有路径失效，表现是"每个 tb 都编译失败"（已踩过）。
$root   = Split-Path -Parent $PSScriptRoot
$tbDir  = Join-Path $root "tb"
$evDir  = Join-Path $root "sim\evidence"
$bldDir = Join-Path $root "build\sim"
New-Item -ItemType Directory -Force -Path $evDir, $bldDir | Out-Null

$iverilogCmd = Get-Command iverilog -ErrorAction SilentlyContinue
$vvpCmd      = Get-Command vvp      -ErrorAction SilentlyContinue
if (-not $iverilogCmd -or -not $vvpCmd) {
  Write-Host "⛔ 找不到 iverilog / vvp —— 请先安装 Icarus Verilog 并加入 PATH" -ForegroundColor Red
  exit 2
}
$iverilog = $iverilogCmd.Source
$vvp      = $vvpCmd.Source

# ── 源文件发现（新增 rtl/ 子目录时不用改这里）──────────────
# ⚠️ 用 -Include（不是 -Filter）：-Filter 只接受【一个】模式，
#    `-Filter *.sv,*.v` 会因参数绑定失败而整条命令报错（已踩过）。
function Get-HdlSources([string]$Dir) {
  @(Get-ChildItem -Path $Dir -Recurse -Include *.sv, *.v -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "tb_*" } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName })
}

$rtl    = Get-HdlSources (Join-Path $root "rtl")
#   ⭐ 2026-09-26：把 `bringup/dac_tone` 也纳入 RTL 搜索路径。
#   🔴 **为什么**：⭐ 那目录下的 `dac_tone_top.v` 是一个**独立顶层**（⭐ 不属主工程），
#      ⚠️ 而 `tb/bringup/tb_dac_tone_top.sv` 要例化它 ⇒
#      🔴 不加入搜索路径 ⇒ 回归报 `Unknown module type: dac_tone_top`（⭐ 编译失败）。
#   📌 **注意**：⛔ 它**不在** `Gowin2026.gprj` 里（⭐ 独立工程）⇒
#      加进回归**不影响主工程构建**，⭐ 只是让它也有回归保护。
$rtlDac = @(Get-HdlSources (Join-Path $root "bringup\dac_tone") |
            Where-Object { $_ -notmatch 'proj_fmt' })     # ⚠️ 排除构建产物目录
$rtl    = @($rtl) + $rtlDac
$models = Get-HdlSources (Join-Path $root "tb\models")
$chk    = Get-HdlSources (Join-Path $root "tb\checkers")   # T3 的断言 A1~A8
$tbs    = @(Get-ChildItem -Path $tbDir -Recurse -Include tb_*.sv -File -ErrorAction SilentlyContinue |
            Where-Object { $Filter -eq "" -or $_.Name -like "*$Filter*" } |
            Sort-Object FullName)

if ($tbs.Count -eq 0) {
  Write-Host "⚠️ 没找到 tb（tb/**/tb_*.sv）" -ForegroundColor Yellow
  exit 0
}

Write-Host ("RTL " + $rtl.Count + " 个 · 模型 " + $models.Count + " 个 · 检查器 " + $chk.Count + " 个 · tb " + $tbs.Count + " 个") -ForegroundColor DarkGray

$pass = 0
$fail = @()
#   ⭐ 2026-09-26：被【默认跳过】的 tb（⭐ 工具 tb，⛔ 不是失败）—— ⭐ 汇总结算时不计入总数
$skipped = @()
foreach ($tb in $tbs) {
  $name   = $tb.BaseName
  $outDir = Join-Path $bldDir $name
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  $vvpFile    = Join-Path $outDir ($name + ".vvp")
  $compileLog = Join-Path $evDir ($name + ".compile.log")
  $runLog     = Join-Path $evDir ($name + ".log")
  $stamp      = Get-Date

  Write-Host ("`n=== 编译 " + $name + " ===") -ForegroundColor Cyan
  # ⭐ tb 自己写死了 $dumpfile 的路径（如 build/sim/tlc5916/xxx.vcd），而 iverilog/vvp
  #    **不会替它建目录** —— 目录不存在就报 "Unable to open ... for output"，
  #    而且是**运行时**才报（编译一切正常），表现为"tb 莫名失败"。
  #    ⇒ 按 tb 源码里的 $dumpfile 先把目录建出来（通用写法，新增 tb 不用改这里）。
  # Never allow a failed compile to fall through to a stale simulation image.
  if (Test-Path -LiteralPath $vvpFile) { Remove-Item -LiteralPath $vvpFile -Force }
  $src = Get-Content -LiteralPath $tb.FullName -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($src)) {
    "FAIL: empty testbench source: $($tb.FullName)" | Out-File -FilePath $compileLog -Encoding utf8
    Write-Host "    ⛔ tb 源文件为空 —— 拒绝运行旧仿真产物" -ForegroundColor Red
    $fail += ($name + "(空文件)")
    continue
  }
  foreach ($m in [regex]::Matches($src, '\$dumpfile\s*\(\s*"([^"]+)"')) {
    $dumpPath = $m.Groups[1].Value
    if (-not [System.IO.Path]::IsPathRooted($dumpPath)) { $dumpPath = Join-Path $root $dumpPath }
    $dumpDir = Split-Path -Parent $dumpPath
    if ($dumpDir) { New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null }
  }
  # Normal regression uses the portable table. Gowin synthesis does not set
  # this macro, so hardware takes the generated pROM branch instead.
  # ⭐ T48（2026-09-22）：名字带 `_prom` 的 tb 是「pROM 变体编译」——
  #    ⛔ 不传 `-DWAVETABLE_BEHAVIORAL` ⇒ `wavetable_bank` 走综合用的 pROM 分支；
  #    ⭐ 仿真用的 pROM 模型 `tb/models/wavetable_sine_rom_ip_model.sv`
  #       （`$readmemh` 载 hex，替代真实 Gowin 黑盒）已由 `$models` 自动收集。
  #    这样「行为级 case 表」与「综合 pROM」两条路径都被回归覆盖，
  #    ⛔ 不再出现"仿真全绿、上板（走 pROM）出错"这类盲区。
  $isPromVariant = $name -like "*_prom*"
  if ($isPromVariant) {
    $compileArgs = @("-g2012", "-Wall", "-s", $name, "-o", $vvpFile) + $rtl + $models + $chk + @($tb.FullName)
  } else {
    $compileArgs = @("-g2012", "-Wall", "-DWAVETABLE_BEHAVIORAL", "-s", $name, "-o", $vvpFile) + $rtl + $models + $chk + @($tb.FullName)
  }
  $compileOut  = & $iverilog @compileArgs 2>&1
  $compileExit = $LASTEXITCODE
  $compileOut | Out-File -FilePath $compileLog -Encoding utf8
  $compileOut | Where-Object { "$_" -match "\S" } | ForEach-Object { Write-Host "    $_" }
  if ($compileExit -ne 0) {
    Write-Host ("    ⛔ 编译失败 —— 见 sim/evidence/" + $name + ".compile.log") -ForegroundColor Red
    $fail += ($name + "(编译)")
    continue
  }

  Write-Host ("=== 运行 " + $name + " ===") -ForegroundColor Cyan
  # ⭐⭐ 看门狗（K-94，2026-09-21 补）：
  #   ⚠️ 原来这里是**裸的** `& $vvp $vvpFile` —— ⛔ **没有任何超时**。
  #   后果：**任何一个 tb 挂死（死循环 / 无限等待），整个回归就永久静默阻塞**
  #         （没有输出、没有报错、退出码也没有），看起来就像"跑得慢"。
  #   ⚠️ 尤其危险的是**变异测试**：它要跑 N 遍本脚本 ⇒
  #      一个变异体让 tb 进入死循环 ⇒ 整套变异测试**永远跑不完**，
  #      而且**看起来只是在慢慢跑**（K-87 家族：验收工具自身失效却无人察觉）。
  #   ⇒ 做法：后台起进程 + 限时等待；超时就杀掉并**判该 tb 失败**（⛔ 不是"通过"）。
  #   📌 纪律：**"没有结论"必须算失败**，⛔ 不能算通过（同 C29：跳过≠通过）。
  #
  #   ⚠️⚠️ 2026-09-24 实测踩坑（**第四次修复** —— 超时判据本身误报）：
  #     🔴 现象：全量回归报 4 个 tb `TIMEOUT`（tb_top_sound / tb_e2e /
  #        tb_calib_span / tb_uart_calib_chain），
  #        ⚠️ **但它们的日志末尾明明写着 `PASS:` 和 `$finish called at ...`**
  #        ⇒ 🔴 **仿真已经【成功结束】，只是没在 120 s 内返回**。
  #     ⭐ 根因：**120 s 的预算对重 tb 太紧** ——
  #        · `tb_top_sound` 单独跑实测 **93 s**（⭐ 它要采 2048 个 I2S 样点）
  #        · 全量回归时机器同时在跑别的（编译下一个 tb / 变异测试 / PnR）
  #        ⇒ ⚠️ 一超 120 s 就被判"挂死" ⇒ 🔴 **验收工具自己误报了**
  #     📌 这正是 `K-94` 的**反面**：
  #        原来担心的是"挂了却算通过"，⚠️ 现在踩的是"**过了却算挂**"。
  #        ⇒ ⭐ 两者都是"判据不可靠"，⭐ 必须一起防。
  #     ⇒ ⭐ 修法：**按 tb 分类给预算**（见下方 `$tbTimeoutSec`），
  #        并在超时消息里**带上已产出的行数**（⭐ 一眼看出"有没有 PASS 过"）。
  #
  #   ⚠️⚠️ 2026-09-21 实测踩坑（`K-94` 的**第二次修复**）：
  #     `Start-Job` 的子进程 **工作目录不是仓库根** ⇒ ⛔ **相对路径的 `$dumpfile` 打不开**
  #     （实测：`VCD Error: Unable to open build/sim/tb_xxx/tb_xxx.vcd for output`）。
  #     ⭐ 危害：**波形证据静默丢失**，而 tb 本身仍"通过"（⚠️ 判定只看 `FAIL:` 行）
  #     ⇒ 这种"验收通过了、证据却没了"正是本项目最忌讳的一类。
  #     ⇒ ⭐ 修法：`Start-Job` 里**先 `Set-Location $root`**（把仓库根传进去）。
  #
  #   ⚠️⚠️ 2026-09-21 实测踩坑（`K-97`，**第三次修复**）：
  #     我第一版把 `$runExit` **硬设成 0**（理由是"`Start-Job` 里拿不到退出码"），
  #     只剩 `FAIL:` 正则兜底 ⇒ 🔴 **任何"跑挂了但没打印 `FAIL:`"的情况都会被判 PASS**：
  #       · tb 崩溃 / 段错误（没有任何输出）
  #       · 脚本本身解析失败（⚠️ 我实测时正好踩到：编辑 BOM 被剥掉 ⇒ 整脚本不执行）
  #       · `$finish` 但**没给出结论**（既没 PASS 也没 FAIL）
  #     ⭐ 实测后果：变异体 **M07 报 `GREEN(LEAK!)`** —— 看起来像"判据漏了"，
  #        实际是"**运行根本没产生结论，却被当成通过**"。
  #     ⇒ ⭐ 修法：**在 job 里显式取回真实退出码**（用一行标记传出来），
  #       并**把"没有结论"也判失败**。
  #
  #   ⭐⭐ 2026-09-24 新增：**按 tb 分类给超时预算**（修上面"第四次修复"那个误报）
  #     ⚠️ 默认 120 s 对【重 tb】不够 —— 它们仿真时间就长（如 `tb_top_sound`
  #        要采 2048 个 I2S 样点 ⇒ 42 ms 仿真时间 ⇒ vvp 实测 93 s）。
  #     ⇒ ⭐ 重 tb 给 300 s；⭐ 其余仍 120 s（⭐ 保持"真挂死能快速抓出来"）。
  #     📌 判据：⭐ 只有【已知仿真时间长】的 tb 才加进来，⛔ 不要普遍调大
  #        （⚠️ 否则真挂死时要等更久才被发现）。
  $heavyTb = @(
    'tb_transpose',           # P1(2026-10-03)：实测 159 s（⭐ 改动前就已 134.6 s ⇒ 既有缺口）⇒ 必须 300 s 档
    'tb_top_sound',              # ⭐ 采 2048 点 @48.8 kHz ⇒ 实测 93 s
    'tb_e2e_key_to_sound',       # ⭐ 端到端手弹链（含演示和弦等待）⇒ 实测 ~50 s
    'tb_calib_span',             # ⭐ 16 轴标定（含超时/拒绝等负向用例）
    'tb_span_realistic',         # ⭐ K-129：同比例超时复现（跑 3 场景 × 4000 帧）⇒ 实测 ~90 s
    'tb_span_multiaxis_noise',   # ⭐ 多轴 + 逐通道噪声扫描（6 个幅度 × 3000 帧）⇒ 实测 ~115 s
    'tb_uart_calib_chain',       # ⭐ 串口 + 标定链
    'tb_latency_m2',             # ⭐ 50 次延迟测量
    'tb_note_manager',           # ⭐ 含 FIFO 溢出突发用例
    'tb_i2s_tx_prbs',            # ⭐ 512 帧随机 + 位扫描
    'tb_wavetable_bank_prom',    # ⭐ pROM 变体
    'tb_met_btn_top',            # ⭐ 2026-09-28 新增：S2/AB13 节拍器开关（⭐ 4 个 5 ms 去抖窗口）
                                 #    ⇒ ⭐ 实测 **172 s**（⛔ 远超默认 120 s ⇒ ⭐ 必须在本表里）
    'tb_test_mode_fft'           # ⭐ 2026-10-09 新增：⭐ Test Mode 波表 + FFT 验收
                                 #    ⇒ ⭐ 实测 **158 s**（⛔ 超默认 120 s ⇒ ⭐ 2026-10-09 回归里
                                 #      被误判成 `TIMEOUT`；⭐ 单独给 600 s 预算 ⇒ **PASS** ✅）
    #   ⚠️ 注意：⭐ `tb_export_wav` **不在本表里** —— ⭐ 它【默认被跳过】（见下方 `$skipByDefault`）
  )
  # ═══════════════════════════════════════════════════════════════════════════
  #   🔴🔴 2026-09-26：⭐ **`tb_export_wav` 默认【跳过】**（⭐ 用户要求）
  #
  #   ⭐ **为什么跳过而不是给长超时**：
  #      · ⚠️ 它要导 **0.5 秒真实音频** ⇒ ⭐ `24414 样点 × 1024 clk ≈ 2500 万拍`
  #        ⇒ 🔴 **实测 ~30 分钟 CPU** —— ⚠️ **比整个回归其余部分加起来还慢**
  #      · ⭐ 而它**不是验收 tb** —— ⭐ 它是**工具**（⭐ 产出 WAV 给人**听**，
  #        ⛔ 不产生 PASS/FAIL 判据）
  #      ⇒ ⭐ **把它放进每轮回归，只是让回归慢一倍，⛔ 换不来任何判据。**
  #
  #   ⭐ **怎么单独跑它**（⭐ 需要导 WAV 时）：
  #      `powershell -File sim\tb_all.ps1 -Filter tb_export_wav`
  #      ⭐ 那时 `-Filter` 会把它**显式选中** ⇒ ⭐ 跳过逻辑不生效（⭐ 见下）
  #   📌 **纪律**：⭐ **它的"能编译 + 能产出有效 WAV"仍然受保护** ——
  #      ⚠️ 只是不每轮都跑（⭐ 与"变异测试用 `-Filter` 缩短"同一思路）。
  # ═══════════════════════════════════════════════════════════════════════════
  #   ⭐ **工具 tb**（⭐ 产出 WAV 给人听，⛔ 不产生验收判据）⇒ ⭐ **默认跳过**：
  #      · `tb_export_wav`     —— 导自检和弦（⭐ 2500 万拍）
  #      · `tb_export_key_wav` —— 导按键出声（⭐ 2026-09-26 新增，⭐ 同样天生慢）
  #   📌 **要单独跑**：⭐ `powershell -File sim\tb_all.ps1 -Filter tb_export_key_wav`
  #      （⭐ `-Filter` 显式选中时不跳过）
  #   ⚠️ **它们仍要能编译** —— ⭐ 所以⛔ 不是"从工程里删掉"，⭐ 只是不每轮跑。
  # ═══════════════════════════════════════════════════════════════════════════
  $skipByDefault = @('tb_export_wav', 'tb_export_key_wav')
  if (($Filter -eq "") -and ($skipByDefault -contains $name)) {
    Write-Host ("  [skip] {0}  (工具 tb，默认跳过；用 -Filter {0} 单独跑)" -f $name) -ForegroundColor DarkYellow
    $script:skipped += $name
    continue
  }

  #   ⚠️ `tb_export_wav` 需要**远超 300 s** 的预算 ⇒ 单独给 1800 s
  #   ⚠️ `tb_met_btn_top` 实测 **172 s**，⚠️ 而全量回归时机器上**还并行跑着 PnR /
  #      其它仿真** ⇒ ⭐ 给 **600 s**（3.5× 余量）⛔ 否则会**误报 TIMEOUT**（K-94 反面）
  $tbTimeoutSec = if ($name -eq 'tb_export_wav') { 1800 }
                  elseif ($name -eq 'tb_met_btn_top') { 600 }
                  #  ⭐⭐ 2026-09-29 新增；⭐⭐ 2026-10-03 实测复校：
                  #     🔴 注释里那个 **~50 s** 是错的 —— 隔离重跑（机器空载）实测 **332 s**（2026-10-03）
                  #     ⇒ 600 s 的余量其实只有 **1.8×** ⇒ 机器一忙就误报
                  #       （⭐ 2026-10-03 的全量回归就撞了一次，而日志里其实已有 `PASS:` ✅）
                  #     📌 ⭐ 与 `tb_top_sound` **同一处置**（它已抬到 900 s，见下）
                  #     ⇒ ⭐ 抬到 **900 s**（2.7× 实测）⛔ 否则会**误报 TIMEOUT**（⭐ 见 `K-161` / `K-94`）
                  elseif ($name -eq 'tb_e2e_key_to_sound') { 900 }
                  #  ⭐⭐ 2026-09-29 同日：⭐ `tb_top_sound` 的注释实测值是 **93 s**，
                  #     ⚠️ 但同一轮回归里实测**已耗 CPU 155 s**（⭐ 机器负载 ✅）
                  #     ⇒ ⭐ 300 s 的余量只剩 ~2× ⚠️ ⇒ ⭐ 与 `tb_e2e` / `tb_met_btn_top` **同一处置**：给 600 s ✅
                  #  ⭐⭐ 2026-10-02 实测复校（A1 验证时**隔离重跑、机器空载**）：
                  #     ⭐ `tb_top_sound` 单独跑 **641 s** ⇒ 🔴 **600 s 仍然不够**（差 41 s）
                  #     ⇒ 🔴 全量回归因此报 `TIMEOUT`（⚠️ 而日志里其实已有 `PASS:`，K-94/K-161 同族）
                  #     ⇒ ⭐ 抬到 **900 s**（1.4× 实测）
                  elseif ($name -eq 'tb_top_sound') { 900 }
                  #  ⭐⭐ 2026-10-08 新增：⭐ `tb_right_adc`（⭐ `RIGHT_ADC_ENABLE` 双实例差分）
                  #     ⚠️ 它**同时例化两个 `top`**（一个 `=1` 一个 `=0`）⇒ 天然是重 tb
                  #     ⭐ 实测（机器带负载）**85 s** ⇒ ⭐ 给 **300 s**（3.5× 余量）
                  #     ⛔ 不给就会在机器忙时**误报 TIMEOUT**（⭐ `K-94` / `K-161` 同族）✅
                  elseif ($name -eq 'tb_right_adc') { 300 }
                  #  ⭐⭐ 2026-10-02 新增：⭐ `tb_nm_no_leak` 隔离重跑实测 **182 s**，
                  #     ⚠️ 而它此前**不在任何特例里** ⇒ 用默认 120 s
                  #     ⇒ 🔴 同一次回归报 `TIMEOUT`（⭐ 同样"日志里已有 PASS"）
                  #     ⇒ ⭐ 抬到 **300 s**（1.6× 实测）
                  elseif ($name -eq 'tb_nm_no_leak') { 300 }
                  #  ⭐⭐ 2026-10-01 新增：⭐ `tb_demo_stall_diag`（⭐ 诊断型，⭐ 打印量大）
                  #     ⚠️ 实测：⭐ 它**已经打出 `PASS:`**（⭐ 结构上 `:701-704` 打印判决
                  #        ⇒ `:706 #1000` ⇒ `:707 $finish` ✅ ⭐ 不是挂死），⚠️ 但 120 s 不够
                  #     🔴 症状与上面三条**完全同一类**：⭐ 撞预算 ⇒ 报 `TIMEOUT`
                  #        （⭐ 而日志里已有 `PASS:` ✅）⇒ ⭐ 这是 `K-94` 的**反面误报** ⚠️
                  #     ⇒ ⭐ 给 **600 s**（⭐ 5× 余量）⛔ 否则机器负载高时必误报
                  elseif ($name -eq 'tb_demo_stall_diag') { 600 }
                  elseif ($heavyTb -contains $name) { 300 }
                  else { $TimeoutSec }

  $job = Start-Job -ScriptBlock {
    param($exe, $img, $wd)
    Set-Location -LiteralPath $wd      # ⭐ 关键：让相对 $dumpfile 落在仓库根下
    $o = & $exe $img 2>&1 | Out-String
    $c = $LASTEXITCODE
    if ($null -eq $c) { $c = 0 }
    # ⭐ 把真实退出码用标记行带出来（⛔ 不能用 $LASTEXITCODE 跨 job 边界）
    "$o`n__VVP_EXIT__=$c"
  } -ArgumentList $vvp, $vvpFile, $root

  $done = Wait-Job -Job $job -Timeout $tbTimeoutSec
  if (-not $done) {
    Stop-Job  -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    # ⚠️ vvp 可能留下子进程，一并清掉（否则会拖慢后续 tb）
    # BEGIN SCOPED VVP CLEANUP
    # A timeout must never kill another regression's simulator. Match the
    # literal image argument and require creation after this test started.
    $imageArg = '(?:^|\s)"?' + [regex]::Escape($vvpFile) + '"?(?:\s|$)'
    Get-CimInstance Win32_Process -Filter "Name = 'vvp.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CreationDate -ge $stamp -and $_.CommandLine -match $imageArg } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # END SCOPED VVP CLEANUP
    # ⭐⭐ 2026-09-24：超时消息里带上【已产出的日志】——
    #    ⚠️ 若里面已经有 `PASS:` ⇒ 说明**仿真其实成功了**，只是没在预算内返回
    #    ⇒ ⭐ 一眼就能区分"真挂死"和"预算太紧"（⭐ 这正是第四次修复要防的误判）
    $partial = ""
    if (Test-Path $runLog) {
      $tail = (Get-Content $runLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
      if ($tail -match "(?m)^PASS:") {
        $partial = "  [!!] 但日志里已出现 PASS: —— 很可能是【超时预算太紧】而不是真挂死，请人工确认"
      } elseif ($tail -match "(?m)^FAIL:") {
        $partial = "  [!!] 日志里有 FAIL: —— 这是真失败"
      }
    }
    $runOut  = @("FAIL: TIMEOUT after $tbTimeoutSec s -- testbench hung (no verdict is a FAILURE, see K-94)$partial")
    $runExit = 124
    Write-Host ("    ⛔ 超时 " + $tbTimeoutSec + " s（本 tb 预算）—— 判失败（挂死不是通过，见 K-94）") -ForegroundColor Red
    if ($partial) { Write-Host ("    " + $partial) -ForegroundColor Yellow }
  } else {
    $raw = Receive-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $rawTxt = ($raw | Out-String)
    # ⭐ 取回真实退出码（见 K-97）
    $runExit = 0
    if ($rawTxt -match "__VVP_EXIT__=(-?\d+)") {
      $runExit = [int]$Matches[1]
      $rawTxt  = $rawTxt -replace "(?m)^__VVP_EXIT__=-?\d+\s*$", ""
    } else {
      # ⭐ 标记行都没出现 ⇒ job 本身异常 ⇒ **判失败**（⛔ 不能当通过）
      $runExit = 125
      $rawTxt = $rawTxt + "`nFAIL: runner could not read vvp exit code (job异常) -- no verdict is a FAILURE (K-97)"
    }
    $runOut = @($rawTxt)
  }
  $runOut | Out-File -FilePath $runLog -Encoding utf8
  $runOut | ForEach-Object { Write-Host "    $_" }

  $txt = ($runOut | Out-String)
  # ⭐ 只有"非零退出"或"FAIL 行"才算失败 —— 见文件头的结论约定
  #
  # ⚠️⚠️ 判定正则的加固（2026-09-17 实测后改，**两轮才定下来**）：
  #    原来是 `(?m)^\s*FAIL`。三个问题：
  #      ① **`\s` 在多行模式下会匹配换行符** ⇒ `^\s*FAIL` 可能**跨行**匹配；
  #      ② 它要求 `FAIL` 前面**只有空白** ⇒ 一旦有人写成 `$display("  ⛔ FAIL: …")`
  #         就会**静默漏判**（该失败却报通过）；
  #      ③ ⚠️ 但**放宽成"行内含 FAIL 就算失败"也不行**：实测 `tb_i2s_tx_sweep`
  #         会打印说明性文字 `<- MUST FAIL`（讲"这一档本来就应该失败"），
  #         被误判成失败（tb 其实 PASS）—— **假失败**。
  #    ⭐ 最终口径（**与 tb 的打印约定配套**）：
  #      判据 = 行首（允许空白）出现的 **`FAIL:`（带冒号）**，或 `$fatal` 的非零退出。
  #      ⇒ ① tb 给结论必须用 **`FAIL:`（带冒号）**；
  #        ② 日志里讲"本来该失败"请写 `MUST FAIL`（字母前缀，不会被抓）或别打印到 stdout。
  #      两条纪律已写进 `files/20-代码/仿真与验证方案.md` §五。
  #    ⚠️ 为什么用 `[^A-Za-z]*` 而不是 `.*`：`.*` 会把 `<- MUST FAIL` 这类
  #       **说明性文字**也判成失败（实测踩过：`tb_i2s_tx_sweep` 因此假失败）；
  #       而 `[^A-Za-z]*` 既允许 `⛔ FAIL:`（装饰符）又排除 `MUST FAIL`（字母）。
  $failRx   = [regex]"(?m)^[ \t]*[^A-Za-z]*FAIL:"
  $errLines = ([regex]::Matches($txt, "(?m)^[ \t]*ERROR")).Count
  if ($runExit -ne 0 -or $failRx.IsMatch($txt)) {
    if ($errLines -gt 0) { Write-Host ("    （日志另有 " + $errLines + " 行 ERROR，属诊断信息）") -ForegroundColor DarkGray }
    $fail += $name
  } else {
    if ($errLines -gt 0) { Write-Host ("    ℹ️ 日志含 " + $errLines + " 行 ERROR —— 负向测试的预期结果，不算失败") -ForegroundColor DarkGray }
    $pass++
  }

  # 波形证据：本 tb 这次跑出来的 .vcd（tb 自带 $dumpfile ⇒ 落在 build/ 或仓库根）
  # ⚠️ 必须排除 sim/evidence/ 自身 —— 否则第二轮扫描会把它当成源文件，
  #    报 "Cannot overwrite the item ... with itself"。
  foreach ($d in @($bldDir, $root)) {
    Get-ChildItem -Path $d -Filter *.vcd -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $stamp -and $_.FullName -notlike ($evDir + "\*") } |
      ForEach-Object { Copy-Item $_.FullName (Join-Path $evDir $_.Name) -Force }
  }
}

Write-Host "`n================ 汇总 ================" -ForegroundColor Yellow
#   ⭐ 跳过的 tb **不计入"共 N 个"** —— ⚠️ 否则会给人"少跑了一个"的错觉。
#      📌 判据口径：⭐ **通过数 / 实际跑的个数**（⭐ 跳过的单独列出）。
$ranCount = $tbs.Count - $skipped.Count
Write-Host ("通过 " + $pass + " / 共 " + $ranCount)
if ($skipped.Count) {
  Write-Host ("跳过（工具 tb，非验收）: " + ($skipped -join ", ")) -ForegroundColor DarkYellow
  Write-Host ("  ⭐ 要跑它: powershell -File sim\tb_all.ps1 -Filter " + $skipped[0]) -ForegroundColor DarkGray
}
if ($fail.Count) {
  Write-Host ("失败: " + ($fail -join ", ")) -ForegroundColor Red
  exit 1
}
Write-Host "✅ 全部通过（证据在 sim/evidence/）" -ForegroundColor Green
exit 0
