param(
    [string]$GwSh = "D:\Gowin\Software\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe",
    [int]$BuildTimeoutSec = 1200
)

$ErrorActionPreference = 'Stop'
$projectDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $projectDir)
$project = Join-Path $projectDir 'hdmi_ref_720p.gprj'
$buildDir = Join-Path $repoRoot 'build'
$tcl = Join-Path $buildDir 'hdmi_ref_720p_build.tcl'
$log = Join-Path $buildDir 'hdmi_ref_720p_build.log'
$err = Join-Path $buildDir 'hdmi_ref_720p_build.stderr.log'

if (-not (Test-Path -LiteralPath $GwSh)) {
    $fallback = 'C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe'
    if (Test-Path -LiteralPath $fallback) {
        $GwSh = $fallback
    } else {
        throw "gw_sh.exe not found. Pass -GwSh with the installed Gowin IDE path."
    }
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$projectTcl = $project -replace '\\','/'
@(
    "open_project $projectTcl",
    'set_option -top_module hdmi_ref_top',
    'run all',
    'exit'
) | Set-Content -LiteralPath $tcl -Encoding ASCII

$started = Get-Date
$proc = Start-Process -FilePath $GwSh -ArgumentList @($tcl) -WorkingDirectory $repoRoot `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $err

if (-not $proc.WaitForExit($BuildTimeoutSec * 1000)) {
    try { $proc.Kill() } catch {}
    $proc.WaitForExit(10000) | Out-Null
}

$fs = Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter 'hdmi_ref_720p.fs' -File `
    -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $started } `
    | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $fs) {
    Write-Host "HDMI reference build failed. See:" -ForegroundColor Red
    Write-Host "  $log"
    Write-Host "  $err"
    exit 1
}

Write-Host "HDMI reference build passed." -ForegroundColor Green
Write-Host "Bitstream: $($fs.FullName)"
Write-Host "Size: $($fs.Length) bytes"
