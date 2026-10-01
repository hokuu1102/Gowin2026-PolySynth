# ============================================================================
# build.ps1 -- ESP32-S3 BLE bridge: build / flash / monitor helper
# ============================================================================
# Usage (PowerShell):
#   .\build.ps1 -Action chipid                 # FIRST: confirm chip = ESP32-S3
#   .\build.ps1 -Action build                  # compile only (mode B default)
#   .\build.ps1 -Action flash  -Port COM7      # compile + flash
#   .\build.ps1 -Action monitor -Port COM7     # open serial monitor
#   .\build.ps1 -Action erase  -Port COM7      # erase whole flash
#   .\build.ps1 -Action menuconfig
#   .\build.ps1 -Action size
#
# Mode switch (default is MODE B / pool since 2026-09-23):
#   .\build.ps1 -Action build -Mode 0          # mode A (passthrough)
#   .\build.ps1 -Action build -Mode 1          # mode B (pool, default)
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
    [string]$Baud = "921600",

    # -1 = do not pass -DBLE_MODE (use ble_config.h default, i.e. mode B)
    [ValidateSet("-1", "0", "1")]
    [string]$Mode = "-1"
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
#   => the RELIABLE way to activate is the profile script that EIM itself wrote.
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
    exit 2
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

Write-Host "IDF_PATH = $env:IDF_PATH"
Write-Host "Project  = $here"
Write-Host "Action   = $Action"
if ($Mode -ne "-1") { Write-Host "Mode     = $Mode (BLE_MODE override)" }
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
    Write-Host "EXPECTED: 'Chip is ESP32-S3'"
    Write-Host "BAD:      'ESP32-D0WD' -> that is the CLASSIC ESP32."
    Write-Host "          This firmware targets S3 (BLE).  Use esp32/bridge/ for SPP."
    Write-Host ""
    Write-Host "ALSO CHECK: does the module have PSRAM?  (needed for mode B pool)"
    Write-Host "  python -m esptool --port $Port flash_id"
    Write-Host "  module marking with 'R' suffix (e.g. N16R8) => has PSRAM"
    exit 0
}

# --- assemble idf.py arguments ----------------------------------------------
$idfArgs = @()
if ($Port) { $idfArgs += @("-p", $Port) }
if ($Mode -ne "-1") { $idfArgs += "-DBLE_MODE=$Mode" }

switch ($Action) {
    "build"      { $idfArgs += "build" }
    "flash"      { $idfArgs += @("-b", $Baud, "flash") }
    "monitor"    { $idfArgs += @("-b", $Baud, "monitor") }
    "menuconfig" { $idfArgs += "menuconfig" }
    "size"       { $idfArgs += "size" }
    "erase"      { $idfArgs += "erase-flash" }
}

# --- NOTE: CMake caches -D values -------------------------------------------
#   Switching -Mode does NOT take effect unless build/ is removed first,
#   because the CMake cache sticks.  See experience base item C61 / T95.
if ($Mode -ne "-1" -and (Test-Path "build")) {
    Write-Host "[i] Removing build/ so the -BLE_MODE change takes effect" -ForegroundColor Yellow
    Remove-Item "build" -Recurse -Force
    Write-Host ""
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
