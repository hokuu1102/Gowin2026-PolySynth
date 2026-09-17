# tb_all.ps1 —— 一条命令跑全部 tb（L0 交付物 T1）
# 用法:  pwsh -File sim\tb_all.ps1            # 跑全部
#        pwsh -File sim\tb_all.ps1 -Filter tlc # 只跑名字含 tlc 的
param([string]$Filter = "")
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommandPath)
$tbDir = Join-Path $root "tb"
$evDir = Join-Path $root "sim\evidence"
New-Item -ItemType Directory -Force -Path $evDir | Out-Null

if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
  Write-Host "⛔ 找不到 iverilog —— 请先安装 Icarus Verilog 并加入 PATH" -ForegroundColor Red; exit 2
}
# RTL 源文件（新增目录时在这里补）
$rtl = @(Get-ChildItem (Join-Path $root "rtl") -Recurse -Filter *.sv,*.v -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -notlike "tb_*" } | ForEach-Object { $_.FullName })
$models = @(Get-ChildItem (Join-Path $root "tb\models") -Recurse -Filter *.sv,*.v -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
$tbs = @(Get-ChildItem $tbDir -Recurse -Filter tb_*.sv -ErrorAction SilentlyContinue |
         Where-Object { $Filter -eq "" -or $_.Name -like "*$Filter*" })

if ($tbs.Count -eq 0) { Write-Host "⚠️ 没找到 tb（tb/**/tb_*.sv）"; exit 0 }

$pass = 0; $fail = @()
foreach ($tb in $tbs) {
  $name = $tb.BaseName
  $vvp  = Join-Path $env:TEMP "$name.vvp"
  Write-Host "`n=== 运行 $name ===" -ForegroundColor Cyan
  & iverilog -g2012 -o $vvp @rtl @models $tb.FullName 2>&1 | Tee-Object -FilePath (Join-Path $evDir "$name.compile.log")
  if ($LASTEXITCODE -ne 0) { $fail += "$name(编译)"; continue }
  $log = Join-Path $evDir "$name.log"
  & vvp $vvp 2>&1 | Tee-Object -FilePath $log
  # ⭐ 判定：非零退出 或 日志里出现 FAIL/ERROR/X 传播
  $txt = (Get-Content $log -Raw -ErrorAction SilentlyContinue)
  if ($LASTEXITCODE -ne 0 -or $txt -match "\bFAIL|ERROR|assertion.*failed") { $fail += $name }
  else { $pass++ }
  Copy-Item (Join-Path $env:TEMP "$name.vcd") $evDir -ErrorAction SilentlyContinue
}
Write-Host "`n================ 汇总 ================" -ForegroundColor Yellow
Write-Host "通过 $pass / 共 $($tbs.Count)"
if ($fail.Count) { Write-Host ("失败: " + ($fail -join ", ")) -ForegroundColor Red; exit 1 }
Write-Host "✅ 全部通过（证据在 sim/evidence/）" -ForegroundColor Green
