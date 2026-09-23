# ============================================================================
# build.ps1 -- ESP32 firmware build / flash / monitor helper
# ============================================================================
# Usage (PowerShell):
#   .\build.ps1 -Action build          # compile only
#   .\build.ps1 -Action flash          # compile + flash
#   .\build.ps1 -Action monitor        # open serial monitor
#   .\build.ps1 -Action chipid         # * confirm chip model (do this FIRST)
#   .\build.ps1 -Action erase          # erase whole flash
#   .\build.ps1 -Action menuconfig     # open menuconfig
#   .\build.ps1 -Action size           # show binary size
#
# NOTE: this file MUST stay pure ASCII.
#   PowerShell 5.1 decodes BOM-less UTF-8 as GBK, so non-ASCII comments
#   may change the parse result.  See experience base item U61.
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("build", "flash", "monitor", "chipid", "erase", "menuconfig", "size")]
    [string]$Action,

    [string]$Port = "",
    [string]$Baud = "921600"
)

$ErrorActionPreference = "Stop"

# --- locate ESP-IDF ---------------------------------------------------------
#
# NOTE (learned the hard way on this machine, 2026-09-23):
#   ESP-IDF v5.5 was installed with the Espressif Installer (EIM) to C:\Espressif,
#   and the tools live in C:\Espressif\tools  (NOT the default ~\.espressif).
#   Running esp-idf\export.ps1 fails with:
#       "ESP-IDF Python virtual environment ...\.espressif\python_env\... not found"
#   because export.ps1 assumes the default IDF_TOOLS_PATH.
#
#   => the RELIABLE way to activate is the profile script that EIM itself wrote,
#      whose path is recorded in C:\Espressif\tools\eim_idf.json.
#   => this script auto-detects it.
#
$eimProfile = "C:\Espressif\tools\Microsoft.v5.5.PowerShell_profile.ps1"

if (-not $env:IDF_PATH) {
    if (Test-Path $eimProfile) {
        Write-Host "Activating ESP-IDF via EIM profile:" -ForegroundColor Cyan
        Write-Host "  $eimProfile"
        . $eimProfile
        Write-Host ""
    }
}

if (-not $env:IDF_PATH) {
    Write-Host "[!] ESP-IDF is not activated." -ForegroundColor Red
    Write-Host ""
    Write-Host "    Tried EIM profile: $eimProfile  (exists: $(Test-Path $eimProfile))"
    Write-Host ""
    Write-Host "    Activate manually, then re-run:"
    Write-Host "      . `"$eimProfile`""
    Write-Host "    Or, if you used a different install location:"
    Write-Host "      . `$env:IDF_PATH\export.ps1     (needs IDF_TOOLS_PATH to match the install)"
    exit 2
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

Write-Host "IDF_PATH = $env:IDF_PATH"
Write-Host "Project  = $here"
Write-Host "Action   = $Action"
Write-Host ""

# --- chipid: the very first thing to do on a new board ----------------------
if ($Action -eq "chipid") {
    if (-not $Port) {
        Write-Host "[!] -Port is required for chipid (e.g. -Port COM7)" -ForegroundColor Red
        exit 2
    }
    Write-Host "Reading chip ID on $Port ..."
    Write-Host ""
    python -m esptool --port $Port chip_id
    Write-Host ""
    Write-Host "EXPECTED: 'Chip is ESP32-D0WD-V3'  (or ESP32-D0WD / ESP32-D0WDQ6)"
    Write-Host "BAD:      'ESP32-S3' or 'ESP32-S2' -> WRONG CHIP."
    Write-Host "          S3/S2 have NO Classic Bluetooth, so SPP is impossible."
    exit 0
}

# --- assemble idf.py arguments ----------------------------------------------
$idfArgs = @()
if ($Port) { $idfArgs += @("-p", $Port) }

switch ($Action) {
    "build"      { $idfArgs += "build" }
    "flash"      { $idfArgs += @("-b", $Baud, "flash") }
    "monitor"    { $idfArgs += @("-b", $Baud, "monitor") }
    "menuconfig" { $idfArgs += "menuconfig" }
    "size"       { $idfArgs += "size" }
    "erase"      { $idfArgs += "erase-flash" }
}

Write-Host "idf.py $($idfArgs -join ' ')"
Write-Host ""

if (-not (Get-Command idf.py -ErrorAction SilentlyContinue)) {
    Write-Host "[!] idf.py not available." -ForegroundColor Red
    Write-Host "    IDF_PATH = $env:IDF_PATH"
    Write-Host "    Activate with:  . `"$eimProfile`""
    exit 2
}

& idf.py @idfArgs
exit $LASTEXITCODE
