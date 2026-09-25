# ═══════════════════════════════════════════════════════════════════════════
#  build_dac_tone.ps1 —— ⭐ 构建"最小外置 DAC 出声测试"的 bitstream
#
#  ⭐ **独立工程**：⭐ 只读 `bringup/dac_tone/` 下的两个文件
#     ⇒ ⛔ **完全不碰主工程 `Gowin2026.gprj` / `rtl/` / `constr/`**
#  📌 产物：`impl/dac_tone/dac_tone.fs`（⭐ 与主工程的 `impl/pnr/Gowin2026.fs` 分开）
# ═══════════════════════════════════════════════════════════════════════════
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # FPGA2026 根
Set-Location $root

$proj  = Join-Path $root 'bringup\dac_tone\dac_tone.gprj'
$tcl   = Join-Path $root 'build\dac_tone_build.tcl'
$outD  = Join-Path $root 'impl\dac_tone'

Write-Host "=== 构建最小 DAC 出声测试 ===" -ForegroundColor Cyan
Write-Host "工程: $proj"

if (-not (Test-Path $proj)) { Write-Host "🔴 找不到工程文件" -ForegroundColor Red; exit 2 }

New-Item -ItemType Directory -Force -Path $outD | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $tcl) | Out-Null

# ⭐ Gowin Tcl：打开工程 -> 综合 -> 布局布线 -> 出比特流
#   🔴 **2026-09-26 修正**：⭐ 我第一版写 `set_project` ⇒
#      ⚠️ 报 `invalid command name "set_project"` —— ⭐ **该命令不存在**。
#   ⭐ 正确命令是 ⭐ **`open_project`**（⭐ 抄自主工程 `build_cli.tcl`，⛔ 不靠猜）。
$tclBody = @"
open_project $($proj -replace '\\','/')
set_option -top_module dac_tone_top
run all
exit
"@
Set-Content -Path $tcl -Value $tclBody -Encoding ASCII

# ⭐ 找 gw_sh
# ⭐ 复用主工程【已验证】的 gw_sh 路径（⭐ 见 sim/gowin_build.ps1）
#   🔴 我第一版用通配符 `C:\Gowin\*\Gowin_V*\...` ⇒ ⚠️ 匹配不到（⭐ 层级写错）
#      ⇒ 🔴 报"找不到 gw_sh" ⇒ ⭐ 直接硬编码实测路径更可靠。
[string]$GwSh = "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
if (-not (Test-Path $GwSh)) {
    Write-Host "🔴 gw_sh.exe 不在预期位置: $GwSh" -ForegroundColor Red
    Write-Host "   尝试搜索..." -ForegroundColor Yellow
    $found = Get-ChildItem "C:\Gowin" -Recurse -Filter 'gw_sh.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { $GwSh = $found.FullName } else { exit 3 }
}
Write-Host "gw_sh: $GwSh"

& $GwSh $tcl 2>&1 | Tee-Object -FilePath (Join-Path $outD 'build.log')

# ⭐ Gowin 不退出进程 ⇒ 宽限后强杀（⭐ 见 U-31）
Start-Sleep -Seconds 2

$fs = Get-ChildItem -Path $root -Recurse -Filter 'dac_tone.fs' -ErrorAction SilentlyContinue |
      Select-Object -First 1
if ($fs) {
    Write-Host "OK  比特流: $($fs.FullName)" -ForegroundColor Green
    Write-Host "    大小: $($fs.Length) 字节  时间: $($fs.LastWriteTime)"
} else {
    Write-Host "🔴 没生成比特流 —— 看日志" -ForegroundColor Red
    Get-ChildItem -Path $root -Recurse -Filter '*.fs' -ErrorAction SilentlyContinue |
        Select-Object -First 5 | ForEach-Object { Write-Host "   已有: $($_.FullName)" }
    exit 4
}
