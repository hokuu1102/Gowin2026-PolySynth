# check_ps1_encoding.ps1 -- guard for C17 / U46 / K-55 / C72 / C73
#
# WHY THIS EXISTS
#   Windows PowerShell 5.1 decodes a BOM-less .ps1 using the LOCAL CODE PAGE
#   (GBK on a Chinese Windows).  Two distinct failure modes follow:
#
#     1. SYNTAX ERROR  (U46 / K-55)
#        Chinese text becomes mojibake whose bytes can close a quote or brace,
#        so the parser reports an error on an unrelated line.
#
#     2. SILENT ELEMENT LOSS  (C72 -- found 2026-09-24)
#        A non-ASCII run can swallow the following NEWLINE, merging the next
#        line into a comment.  If that next line was an array element @{...},
#        the element simply VANISHES -- no error, no warning, just a shorter
#        array.  Measured: an array with 107 elements was read as 105.
#
#   Both are avoided by the same rule, which is what this script enforces:
#
#       A .ps1 that contains ANY non-ASCII byte MUST carry a UTF-8 BOM.
#
#   Pure-ASCII scripts are fine either way and are reported as OK.
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_ps1_encoding.ps1
#   exit 0 = pass, exit 1 = at least one FAIL
#
# NOTE: keep this file pure ASCII.  It is a BOM-less .ps1 too, so if you add
#       Chinese here you have to add a BOM as well -- the irony is intentional.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Directories that are generated, vendored or temporary -- never audit these.
$skipDirs = @('\.git\', '\build\', '\_wt_oldcheck\', '\impl\', '\sim\evidence\')

$fail = 0
$checked = 0
$rows = @()

Get-ChildItem $root -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
    $path = $_.FullName
    $rel = $path.Substring($root.Length).TrimStart('\')

    $skip = $false
    foreach ($d in $skipDirs) { if ($path -like "*$d*") { $skip = $true } }
    if ($skip) { return }

    $checked++
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    # Count non-ASCII bytes in the BODY only.  The BOM itself is EF BB BF, so
    # counting from index 0 would add 3 to every BOM-carrying file and make the
    # report look wrong (a pure-ASCII file would appear to have 3).
    $start = 0
    if ($hasBom) { $start = 3 }
    $nonAscii = 0
    for ($i = $start; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $nonAscii++ } }

    $verdict = 'OK'
    if ($nonAscii -gt 0 -and -not $hasBom) {
        $verdict = 'FAIL'
        $fail++
    }

    $rows += [pscustomobject]@{
        File     = $rel
        BOM      = if ($hasBom) { 'yes' } else { 'no' }
        NonAscii = $nonAscii
        Verdict  = $verdict
    }
}

Write-Host ""
Write-Host "=== .ps1 encoding audit (rule: non-ASCII requires a UTF-8 BOM) ===" -ForegroundColor Cyan
foreach ($r in ($rows | Sort-Object Verdict, File)) {
    $color = if ($r.Verdict -eq 'FAIL') { 'Red' } else { 'Gray' }
    Write-Host ("  [{0,-4}] {1,-40} BOM={2,-3} non-ASCII={3}" -f $r.Verdict, $r.File, $r.BOM, $r.NonAscii) -ForegroundColor $color
}
Write-Host ""

if ($fail -gt 0) {
    Write-Host ("FAIL: {0} of {1} script(s) contain non-ASCII text without a UTF-8 BOM." -f $fail, $checked) -ForegroundColor Red
    Write-Host "      A BOM-less script is decoded as GBK by PowerShell 5.1, which can" -ForegroundColor Red
    Write-Host "      (a) produce a syntax error on an unrelated line (U46/K-55), or" -ForegroundColor Red
    Write-Host "      (b) SILENTLY swallow a newline and drop an array element (C72)." -ForegroundColor Red
    Write-Host "      Fix: either add a UTF-8 BOM, or make the file pure ASCII." -ForegroundColor Red
    exit 1
}

Write-Host ("OK: {0} script(s) checked, none violate the encoding rule." -f $checked) -ForegroundColor Green
exit 0
