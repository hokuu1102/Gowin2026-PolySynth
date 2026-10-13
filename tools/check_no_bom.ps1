# check_no_bom.ps1 -- gate: no UTF-8 BOM in any HDL source file.
#
# WHY (2026-10-11, found the hard way):
#   I edited rtl/w3c/play_seq.v with PowerShell's `Set-Content -Encoding utf8`
#   (PS 5.1) -- which SILENTLY PREPENDS a UTF-8 BOM (EF BB BF).
#   iverilog then failed to parse that file's module, so:
#     * every testbench that instantiates play_seq reported
#         error: Unable to find the root module "<tb name>"
#     * the error names the TESTBENCH, not the broken RTL file => very confusing.
#   Reproduced cleanly: a 6-line probe tb created with Set-Content -Encoding utf8
#   failed with "Unable to find the root module"; stripping the 3 BOM bytes made
#   it pass immediately.
#
# RULE (note: this is the OPPOSITE of the .ps1 rule):
#   * .ps1  -> must carry a UTF-8 BOM **or** be pure ASCII (tools/check_ps1_encoding.ps1)
#   * .v/.sv/.vh -> must have NO BOM at all (this gate)
#
# USAGE:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_no_bom.ps1
#   exit 0 = pass, exit 1 = violation(s)
#
# NOTE: this file is PURE ASCII on purpose -- project rule: a .ps1 must either
#   carry a UTF-8 BOM or be pure ASCII.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$dirs = @('rtl', 'tb', 'bringup', 'sim')
$exts = @('.v', '.sv', '.vh', '.svh')

$scanned = 0
$bad = @()

foreach ($d in $dirs) {
    $p = Join-Path $root $d
    if (-not (Test-Path $p)) { continue }
    $files = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $exts -contains $_.Extension.ToLower() }
    foreach ($f in $files) {
        $scanned = $scanned + 1
        try {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            $buf = New-Object byte[] 3
            $n = $fs.Read($buf, 0, 3)
            $fs.Close()
        } catch {
            continue
        }
        if ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) {
            $bad += $f.FullName.Replace($root + '\', '')
        }
    }
}

if ($bad.Count -gt 0) {
    Write-Host "FAIL: $($bad.Count) HDL file(s) start with a UTF-8 BOM (iverilog will not parse them):"
    foreach ($b in $bad) { Write-Host ("  " + $b) }
    Write-Host ""
    Write-Host "WHY THIS IS FATAL: the module in that file disappears, so every testbench"
    Write-Host "that instantiates it fails with 'Unable to find the root module <tb>', which"
    Write-Host "names the TESTBENCH rather than the broken RTL file."
    Write-Host ""
    Write-Host "FIX (byte level, do NOT use Set-Content):"
    Write-Host '  $p = (Resolve-Path <file>).Path'
    Write-Host '  $b = [System.IO.File]::ReadAllBytes($p)'
    Write-Host '  [System.IO.File]::WriteAllBytes($p, $b[3..($b.Length-1)])'
    Write-Host ""
    Write-Host "PREVENT: edit HDL with the edit tool, never with Set-Content -Encoding utf8."
    exit 1
}

Write-Host "OK  check_no_bom: 0 BOM in $scanned HDL file(s)"
exit 0
