# build-i-official-640x480.ps1
# Isolation experiment: take the PROVEN official encrypted DVI_TX_Top design
# (H1, which the user just confirmed displays 1280x720 colour bars on the
# Console) and change ONLY the video timing + PLL to 640x480@60.
#
#   F works  -> the physical layer, pins, LVDS25 buffers, cable and monitor are fine
#   D black  -> something in our own TMDS path or in the 640x480 mode itself
#
# I decides which:
#   I shows bars -> the monitor accepts 640x480; our own RTL path is the fault
#   I stays black-> the monitor/mode is the fault (our RTL is probably innocent)
#
# ASCII-only; repo path built from code points (project K-38).

$ErrorActionPreference = 'Continue'
$repo = 'C:\Users\cyx\Documents\ChatGPT\FPGA\Gowin2026-PolySynth-t31b-main'
$h1   = Join-Path $repo 'bringup\hdmi_ref_720p'
$study = 'C:\Users\cyx\Desktop\' + [char]0x5B66 + [char]0x4E60
# NOTE: H1's build script writes the Gowin Tcl file without Unicode support, so
# a CJK project path turns into "??" and open_project fails. Keep this project
# on an ASCII-only path; only the archive destination may be CJK.
$dst  = 'C:\Users\cyx\Desktop\hdmi_i_640x480'
$arc  = Join-Path $study 'hdmi_640x480\bitstreams'
$log  = Join-Path $PSScriptRoot 'build-i-official-640x480.log'

function Write-Log { param([string]$m)
    $line = "$(Get-Date -Format 'HH:mm:ss') $m"
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    Write-Host $line
}

Write-Log "I build starting; dst=$dst"
New-Item -ItemType Directory -Force -Path $dst, (Join-Path $dst 'vendor\sipeed') | Out-Null

# 1) copy the proven project (sources only, no impl/)
foreach ($f in 'hdmi_ref_top.v','hdmi_ref_720p.cst','hdmi_ref_720p.sdc','hdmi_ref_720p.gprj','build_hdmi_ref.ps1','README.md') {
    Copy-Item (Join-Path $h1 $f) (Join-Path $dst $f) -Force
}
Copy-Item (Join-Path $h1 'vendor\sipeed\*') (Join-Path $dst 'vendor\sipeed\') -Force
Write-Log 'project copied'

# 2) timing -> 640x480@60 (VESA DMT, NEGATIVE sync polarity)
$top = Join-Path $dst 'hdmi_ref_top.v'
$t = [System.IO.File]::ReadAllText($top, [System.Text.Encoding]::UTF8)
$map = @(
  @('.I_h_total  (12''d1650)', '.I_h_total  (12''d800)'),
  @('.I_h_sync   (12''d40)',   '.I_h_sync   (12''d96)'),
  @('.I_h_bporch (12''d220)',  '.I_h_bporch (12''d48)'),
  @('.I_h_res    (12''d1280)', '.I_h_res    (12''d640)'),
  @('.I_v_total  (12''d750)',  '.I_v_total  (12''d525)'),
  @('.I_v_sync   (12''d5)',    '.I_v_sync   (12''d2)'),
  @('.I_v_bporch (12''d20)',   '.I_v_bporch (12''d33)'),
  @('.I_v_res    (12''d720)',  '.I_v_res    (12''d480)'),
  @('.I_hs_pol   (1''b1)',     '.I_hs_pol   (1''b0)'),
  @('.I_vs_pol   (1''b1)',     '.I_vs_pol   (1''b0)')
)
foreach ($p in $map) {
    if (-not $t.Contains($p[0])) { Write-Log "WARN anchor missing: $($p[0])" }
    $t = $t.Replace($p[0], $p[1])
}
[System.IO.File]::WriteAllText($top, $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Log 'timing patched to 640x480'

# 3) PLL -> 50*20/8 = 125 MHz serial, 50*20/40 = 25 MHz pixel
$pll = Join-Path $dst 'vendor\sipeed\TMDS_PLL_60HZ.v'
$p = [System.IO.File]::ReadAllText($pll, [System.Text.Encoding]::UTF8)
$p = $p.Replace('PLLA_inst.ODIV0_SEL = 3;',  'PLLA_inst.ODIV0_SEL = 8;')
$p = $p.Replace('PLLA_inst.ODIV1_SEL = 15;', 'PLLA_inst.ODIV1_SEL = 40;')
$p = $p.Replace('PLLA_inst.MDIV_SEL = 22;',  'PLLA_inst.MDIV_SEL = 20;')
[System.IO.File]::WriteAllText($pll, $p, (New-Object System.Text.UTF8Encoding($false)))
Write-Log 'PLL patched to 20/8/40 (VCO 1000 MHz, legal)'

# 4) SDC generated clocks -> 20/8 and 20/40
$sdc = Join-Path $dst 'hdmi_ref_720p.sdc'
$s = [System.IO.File]::ReadAllText($sdc, [System.Text.Encoding]::UTF8)
$s = $s.Replace('-divide_by 3 -multiply_by 22',  '-divide_by 8 -multiply_by 20')
$s = $s.Replace('-divide_by 15 -multiply_by 22', '-divide_by 40 -multiply_by 20')
[System.IO.File]::WriteAllText($sdc, $s, (New-Object System.Text.UTF8Encoding($false)))
Write-Log 'sdc patched'

# 5) build
Write-Log 'running build'
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'build_hdmi_ref.ps1') 2>&1
Write-Log ('build output: ' + (($out | Select-Object -Last 4) -join ' | '))

# 6) warnings
$bl = Join-Path $dst 'impl\gwsynthesis\hdmi_ref_720p.log'
if (Test-Path -LiteralPath $bl) {
    Write-Log '--- synthesis warnings ---'
    Select-String -LiteralPath $bl -Pattern 'WARN|ERROR|PA1019' -ErrorAction SilentlyContinue |
        Select-Object -First 6 | ForEach-Object { Write-Log ('  ' + $_.Line.Trim()) }
}

# 7) archive
$fs = Join-Path $dst 'impl\pnr\hdmi_ref_720p.fs'
if (-not (Test-Path -LiteralPath $arc)) { New-Item -ItemType Directory -Force -Path $arc | Out-Null }
if (Test-Path -LiteralPath $fs) {
    $i = Get-Item -LiteralPath $fs
    $h = (Get-FileHash -LiteralPath $fs -Algorithm SHA256).Hash.Substring(0,16)
    Copy-Item $fs (Join-Path $arc 'I_640x480_officialIP_led.fs') -Force
    Write-Log "archived I_640x480_officialIP_led.fs  size=$($i.Length)  sha256=$h"
} else { Write-Log 'FATAL no bitstream produced' }
Write-Log 'I build finished'
