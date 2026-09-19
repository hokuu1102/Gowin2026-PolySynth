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
param([string]$Filter = "")

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
  $compileArgs = @("-g2012", "-Wall", "-DWAVETABLE_BEHAVIORAL", "-s", $name, "-o", $vvpFile) + $rtl + $models + $chk + @($tb.FullName)
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
  $runOut  = & $vvp $vvpFile 2>&1
  $runExit = $LASTEXITCODE
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
Write-Host ("通过 " + $pass + " / 共 " + $tbs.Count)
if ($fail.Count) {
  Write-Host ("失败: " + ($fail -join ", ")) -ForegroundColor Red
  exit 1
}
Write-Host "✅ 全部通过（证据在 sim/evidence/）" -ForegroundColor Green
exit 0
