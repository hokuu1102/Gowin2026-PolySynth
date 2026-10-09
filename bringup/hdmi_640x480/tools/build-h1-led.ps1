# build-h1-led.ps1
# Adds the same V13 liveness LED to the H1 official 720p reference project, so
# the control experiment carries the SAME witness as our own design. Without
# the LED a black screen from H1 cannot be distinguished from "H1 never ran".
#
# The TMDS path itself is untouched: this only adds an output pin and a
# free-running counter in the 50 MHz input clock domain.
#
# ASCII-only; the repo path is built from code points (project K-38).

param([string]$Repo)

$ErrorActionPreference = 'Continue'
if (-not $Repo) {
    $repoName = 'Gowin2026-PolySynth-t31b-main'
    $Repo = 'C:\Users\cyx\Documents\ChatGPT\FPGA\' + $repoName
}
$proj = Join-Path $Repo 'bringup\hdmi_ref_720p'
$top  = Join-Path $proj 'hdmi_ref_top.v'
$cst  = Join-Path $proj 'hdmi_ref_720p.cst'
$log  = Join-Path $PSScriptRoot 'build-h1-led.log'

function Write-Log { param([string]$m)
    $line = "$(Get-Date -Format 'HH:mm:ss') $m"
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    Write-Host $line
}

Write-Log "H1+LED build starting in $proj"
foreach ($p in $top, $cst) { if (-not (Test-Path -LiteralPath $p)) { Write-Log "FATAL missing $p"; exit 1 } }

# 1) add the port
$t = [System.IO.File]::ReadAllText($top, [System.Text.Encoding]::UTF8)
if ($t -notmatch 'led_hb') {
    $t = $t.Replace(
        "    output wire       hpd_en`r`n);",
        "    output wire       hpd_en,`r`n    output wire       led_hb`r`n);")
    if ($t -notmatch 'output wire\s+led_hb') { $t = $t.Replace("    output wire       hpd_en`n);", "    output wire       hpd_en,`n    output wire       led_hb`n);") }
    $t = $t.Replace(
        "endmodule",
        @"
    // Liveness witness on the Console CFG_LED green channel (V13), same code as
    // our own design: free-running in the 50 MHz domain, not gated by rst_n.
    //   ~1 Hz = running AND PLL locked   ~5 Hz = running, PLL NOT locked
    //   dark  = not configured, or no 50 MHz input clock
    reg [24:0] hb_cnt;
    reg        hb_slow, hb_fast;
    always @(posedge clk) begin
        hb_cnt <= (hb_cnt == 25'd24_999_999) ? 25'd0 : hb_cnt + 25'd1;
        if (hb_cnt == 25'd24_999_999) hb_slow <= ~hb_slow;
        if (hb_cnt == 25'd4_999_999)  hb_fast <= ~hb_fast;
    end
    assign led_hb = pll_lock ? hb_slow : hb_fast;

endmodule
"@)
    [System.IO.File]::WriteAllText($top, $t, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log 'patched hdmi_ref_top.v'
} else { Write-Log 'hdmi_ref_top.v already has led_hb' }

if ($t -notmatch 'output wire\s+led_hb') { Write-Log 'FATAL led_hb port not inserted'; exit 1 }
if ($t -notmatch 'assign led_hb')        { Write-Log 'FATAL led_hb logic not inserted'; exit 1 }

# 2) add the pin
$c = [System.IO.File]::ReadAllText($cst, [System.Text.Encoding]::UTF8)
if ($c -notmatch 'led_hb') {
    $c = $c + "`r`n// Liveness witness: Console CFG_LED green = SYS_ACT = V13.`r`nIO_LOC  `"led_hb`" V13;`r`nIO_PORT `"led_hb`" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;`r`n"
    [System.IO.File]::WriteAllText($cst, $c, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log 'patched hdmi_ref_720p.cst'
} else { Write-Log 'cst already has led_hb' }

# 3) build
Write-Log 'running build'
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'build_hdmi_ref.ps1') 2>&1
Write-Log ('build output: ' + (($out | Select-Object -Last 4) -join ' | '))

# 4) warnings
$bl = Join-Path $proj 'impl\gwsynthesis\hdmi_ref_720p.log'
if (Test-Path -LiteralPath $bl) {
    Write-Log '--- synthesis warnings ---'
    Select-String -LiteralPath $bl -Pattern 'WARN|ERROR|PA1019' -ErrorAction SilentlyContinue |
        Select-Object -First 6 | ForEach-Object { Write-Log ('  ' + $_.Line.Trim()) }
}

# 5) archive
$fs = Join-Path $proj 'impl\pnr\hdmi_ref_720p.fs'
$arcDir = 'C:\Users\cyx\Desktop\' + [char]0x5B66 + [char]0x4E60 + '\hdmi_640x480\bitstreams'
if (-not (Test-Path -LiteralPath $arcDir)) { New-Item -ItemType Directory -Force -Path $arcDir | Out-Null }
if (Test-Path -LiteralPath $fs) {
    $i = Get-Item -LiteralPath $fs
    $h = (Get-FileHash -LiteralPath $fs -Algorithm SHA256).Hash.Substring(0, 16)
    Copy-Item $fs (Join-Path $arcDir 'F_720p_official_led.fs') -Force
    Write-Log "archived F_720p_official_led.fs  size=$($i.Length)  sha256=$h"
} else { Write-Log 'FATAL no bitstream produced' }
Write-Log 'H1+LED build finished'
