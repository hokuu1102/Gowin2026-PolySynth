# ═══════════════════════════════════════════════════════════════════════════
#  build_all_formats.ps1 —— ⭐ 一次生成【三种 I2S 格式】的 bitstream
#
#  ⭐ 为什么：⭐ 模块简介说"左对齐"，⚡ 而数据手册的 `FMT` 脚说"低 = I2S"
#     ⇒ ⚠️ **两者矛盾** ⇒ ⭐ **最省事的办法是三种都出一版，逐个烧来听**。
#
#  ⭐ 产物（⭐ 都在 `bringup/dac_tone/impl/pnr/`）：
#     · `dac_tone_fmt0.fs`  —— ⭐ 标准 I2S（Philips，MSB 延后 1 BCK）
#     · `dac_tone_fmt1.fs`  —— ⭐ 左对齐（MSB 就在第 1 个 BCK）
#     · `dac_tone_fmt2.fs`  —— ⭐ 右对齐（LSBJ，数据贴时隙尾部）
#
#  📌 用法：⭐ `powershell -File bringup\dac_tone\build_all_formats.ps1`
#     ⚠️ 每个 ~2 分钟（⭐ 只有 1 个模块，比主工程快得多）
# ═══════════════════════════════════════════════════════════════════════════
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent $here)
Set-Location $root

[string]$GwSh = "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
if (-not (Test-Path $GwSh)) { Write-Host "ERROR: gw_sh not found: $GwSh" -ForegroundColor Red; exit 3 }

$srcV   = Join-Path $here 'dac_tone_top.v'
$cst    = Join-Path $here 'dac_tone.cst'
$outD   = Join-Path $here 'impl\pnr'
$tcl    = Join-Path $root 'build\dac_tone_all.tcl'

New-Item -ItemType Directory -Force -Path $outD | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $tcl) | Out-Null

#   ⭐ 先备份原文件（⭐ 每次改完必须还原 —— ⚠️ 否则源码被留在最后一档）
$origV = [System.IO.File]::ReadAllText($srcV)

foreach ($fmt in 0, 1, 2) {
    Write-Host ""
    Write-Host "════ FORMAT_SEL = $fmt ════" -ForegroundColor Cyan

    #   ⭐ 改参数（⭐ 只动 `.FORMAT_SEL (n)` 那一行的默认值）
    #      📌 `dac_tone_top` 的 `FORMAT_SEL` 是【参数默认值】，
    #         ⚠️ 而参数不能在 Tcl 里覆盖 ⇒ ⭐ **改源码**最直接。
    $patched = $origV -replace 'parameter integer FORMAT_SEL\s*=\s*\d+',
                              "parameter integer FORMAT_SEL     = $fmt"
    if ($patched -eq $origV -and $fmt -ne 0) {
        # 0 是原值，replace 结果相同是正常的；非 0 若没变说明正则没命中
        $hit = [regex]::IsMatch($origV, 'parameter integer FORMAT_SEL\s*=\s*\d+')
        if (-not $hit) { Write-Host "ERROR: FORMAT_SEL not found in source" -ForegroundColor Red; exit 4 }
    }
    [System.IO.File]::WriteAllText($srcV, $patched)

    #   ⭐ 每档一个独立工程目录 ⇒ ⭐ 产物不互相覆盖
    $projDir = Join-Path $here "proj_fmt$fmt"
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    Copy-Item $srcV  (Join-Path $projDir 'dac_tone_top.v') -Force
    Copy-Item $cst   (Join-Path $projDir 'dac_tone.cst')   -Force

    $gprj = Join-Path $projDir 'dac_tone.gprj'
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project>
    <Template>FPGA</Template>
    <Version>5</Version>
    <Device name="GW5AT-60B" pn="GW5AT-LV60PG484AC1/I0">gw5at60b-002</Device>
    <FileList>
        <File path="dac_tone_top.v" type="file.verilog" enable="1"/>
        <File path="dac_tone.cst" type="file.cst" enable="1"/>
    </FileList>
</Project>
"@
    Set-Content -Path $gprj -Value $xml -Encoding ASCII

    $tclBody = @"
open_project $($gprj -replace '\\','/')
set_option -top_module dac_tone_top
run all
exit
"@
    Set-Content -Path $tcl -Value $tclBody -Encoding ASCII

    & $GwSh $tcl 2>&1 | Tee-Object -FilePath (Join-Path $outD "build_fmt$fmt.log") | Out-Null

    $fs = Get-ChildItem -Path $projDir -Recurse -Filter '*.fs' -ErrorAction SilentlyContinue |
          Select-Object -First 1
    if ($fs) {
        $dest = Join-Path $outD "dac_tone_fmt$fmt.fs"
        Copy-Item $fs.FullName $dest -Force
        Write-Host "OK  fmt$fmt -> $dest  ($($fs.Length) bytes)" -ForegroundColor Green
    } else {
        Write-Host "FAIL fmt$fmt (no bitstream)" -ForegroundColor Red
    }
}

#   ⭐ **还原源码**（⭐ 关键：⛔ 不能让仓库被留在"最后一档"的状态）
[System.IO.File]::WriteAllText($srcV, $origV)
Write-Host ""
Write-Host "restored $srcV to FORMAT_SEL=0" -ForegroundColor Yellow

Write-Host ""
Write-Host "=== 产物 ===" -ForegroundColor Cyan
Get-ChildItem $outD -Filter 'dac_tone_fmt*.fs' | ForEach-Object {
    Write-Host "  $($_.Name)  $($_.Length) bytes  $($_.LastWriteTime)"
}
