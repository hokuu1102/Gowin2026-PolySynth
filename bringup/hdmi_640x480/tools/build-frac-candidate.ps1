# build-frac-candidate.ps1
# Builds a candidate clock mode that keeps the PLL VCO inside the legal
# 700-1400 MHz range while getting much closer to the VESA 25.175 MHz pixel
# clock, using the fractional M divider (MDIV_FRAC_SEL, eighths).
#
#   VCO   = 50 * 1 * (17 + 5/8) / 1 = 881.25 MHz   (legal: 700-1400)
#   serial= 881.25 / 7  = 125.892857 MHz
#   pixel = 881.25 / 35 =  25.178571 MHz  (0.014% off 25.175)
#
# It edits rtl/hdmi_clk.v and constr/hdmi_640x480.sdc, builds, captures the
# PnR warnings (PA1019 MUST be absent this time), archives the bitstream, then
# restores the sources. ASCII-only on purpose.

param(
    [string]$WorkDir
)

$ErrorActionPreference = 'Continue'

# Build the path from code points: a literal CJK path inside a BOM-less .ps1
# is read as ANSI by Windows PowerShell 5.1 and becomes mojibake (project K-38).
if (-not $WorkDir) {
    $study = 'C:\Users\cyx\Desktop\' + [char]0x5B66 + [char]0x4E60
    $WorkDir = Join-Path $study 'hdmi_640x480'
}

$log = Join-Path $PSScriptRoot 'build-frac-candidate.log'
function Write-Log { param([string]$m)
    $line = "$(Get-Date -Format 'HH:mm:ss') $m"
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    Write-Host $line
}

$clk = Join-Path $WorkDir 'rtl\hdmi_clk.v'
$sdc = Join-Path $WorkDir 'constr\hdmi_640x480.sdc'
$buildLog = Join-Path $WorkDir 'build\build.log'
$arc = Join-Path $WorkDir 'bitstreams'

Write-Log "frac candidate build starting in $WorkDir"
foreach ($p in $clk, $sdc) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Log "FATAL missing $p"; exit 1 }
}
Copy-Item $clk "$clk.bak" -Force
Copy-Item $sdc "$sdc.bak" -Force

try {
    $t = [System.IO.File]::ReadAllText($clk, [System.Text.Encoding]::UTF8)
    $t = $t.Replace('defparam u_pll.MDIV_SEL = USE_252 ? 63 : 20;',
                    "defparam u_pll.MDIV_SEL = 17;`r`ndefparam u_pll.MDIV_FRAC_SEL = 5;")
    $t = $t.Replace('defparam u_pll.ODIV0_SEL = USE_252 ? 25 : 8;',  'defparam u_pll.ODIV0_SEL = 7;')
    $t = $t.Replace('defparam u_pll.ODIV1_SEL = USE_252 ? 125 : 40;', 'defparam u_pll.ODIV1_SEL = 35;')
    [System.IO.File]::WriteAllText($clk, $t, (New-Object System.Text.UTF8Encoding($false)))

    $s = [System.IO.File]::ReadAllText($sdc, [System.Text.Encoding]::UTF8)
    $s = $s.Replace('divide_by 8 -multiply_by 20',   'divide_by 56 -multiply_by 141')
    $s = $s.Replace('divide_by 40 -multiply_by 20',  'divide_by 280 -multiply_by 141')
    [System.IO.File]::WriteAllText($sdc, $s, (New-Object System.Text.UTF8Encoding($false)))

    # Anchors must actually have matched, otherwise we would "build" the old design.
    if ($t -notmatch 'MDIV_FRAC_SEL = 5;') { Write-Log 'FATAL MDIV anchor did not apply'; exit 1 }
    if ($s -notmatch 'divide_by 56')       { Write-Log 'FATAL sdc anchor did not apply'; exit 1 }

    Write-Log '--- patched hdmi_clk.v ---'
    Select-String -LiteralPath $clk -Pattern 'MDIV_SEL|MDIV_FRAC_SEL|ODIV0_SEL|ODIV1_SEL' |
        ForEach-Object { Write-Log ('  ' + $_.Line.Trim()) }
    Write-Log '--- patched sdc ---'
    Select-String -LiteralPath $sdc -Pattern 'divide_by' | ForEach-Object { Write-Log ('  ' + $_.Line.Trim()) }

    Write-Log 'running build'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WorkDir 'build_hdmi_640x480.ps1') 2>&1
    Write-Log ('build output: ' + (($out | Select-Object -Last 4) -join ' | '))

    Write-Log '--- PnR warning scan (PA1019 must be ABSENT) ---'
    if (Test-Path -LiteralPath $buildLog) {
        $w = Select-String -LiteralPath $buildLog -Pattern 'PA1019|PR1014|EX3791|ERROR' -ErrorAction SilentlyContinue
        if ($w) { $w | ForEach-Object { Write-Log ('  ' + $_.Line.Trim()) } }
        else { Write-Log '  (no matching warnings)' }
    } else { Write-Log "  build.log not found at $buildLog" }

    $fs = Join-Path $WorkDir 'impl\pnr\hdmi_640x480.fs'
    if (Test-Path -LiteralPath $fs) {
        $i = Get-Item -LiteralPath $fs
        $h = (Get-FileHash -LiteralPath $fs -Algorithm SHA256).Hash.Substring(0, 16)
        Copy-Item $fs (Join-Path $arc 'E_25p18_led.fs') -Force
        Write-Log "archived E_25p18_led.fs  size=$($i.Length)  sha256=$h"
    } else { Write-Log 'no bitstream produced' }

    $tr = Join-Path $WorkDir 'impl\pnr\hdmi_640x480_tr_content.html'
    if (Test-Path -LiteralPath $tr) {
        Write-Log '--- achieved frequencies / Fmax ---'
        Select-String -LiteralPath $tr -Pattern 'Actual Fmax|\(MHz\)' | Select-Object -First 6 |
            ForEach-Object { Write-Log ('  ' + ($_.Line -replace '<[^>]+>','').Trim()) }
        Write-Log '--- TNS table ---'
        (Select-String -LiteralPath $tr -Pattern 'Total Negative Slack' -Context 0,26 |
            Select-Object -First 1).Context.PostContext |
            ForEach-Object { ($_ -replace '<[^>]+>','' -replace '&nbsp;',' ').Trim() } |
            Where-Object { $_ -ne '' } | Select-Object -First 26 |
            ForEach-Object { Write-Log ('  ' + $_) }
    }
} finally {
    Move-Item "$clk.bak" $clk -Force
    Move-Item "$sdc.bak" $sdc -Force
    Write-Log 'sources restored'
}
Write-Log 'frac candidate build finished'
