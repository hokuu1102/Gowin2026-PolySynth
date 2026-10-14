param(
    [switch]$Apply,
    [string]$BackupDir = 'C:/Users/cyx/Documents/ChatGPT/FPGA/rollback-pre-at-20261013'
)
$ErrorActionPreference = 'Stop'
$repoDir = Split-Path -Parent $PSScriptRoot
$backupDir = $BackupDir
$optimizedInputs = @(Import-Csv (Join-Path $backupDir 'optimized_inputs_sha256.csv'))
if ($optimizedInputs.Count -ne 81) { throw 'Invalid optimized input manifest' }
foreach ($inputFile in $optimizedInputs) {
    if ((Get-FileHash -LiteralPath (Join-Path $repoDir $inputFile.File)).Hash -ne $inputFile.SHA256) {
        throw "Project input changed after AT; refusing rollback: $($inputFile.File)"
    }
}
$aoImplManifest = @(Import-Csv (Join-Path $backupDir 'ao_impl_sha256.csv'))
if (!$aoImplManifest.Count) { throw 'Missing AO impl integrity manifest' }
foreach ($implFile in $aoImplManifest) {
    if ((Get-FileHash -LiteralPath (Join-Path ($backupDir + '/ao-impl') $implFile.File)).Hash -ne $implFile.SHA256) {
        throw "AO backup artifact corrupted: $($implFile.File)"
    }
}
$expected = @{
    'rtl/w3b/note_manager.v' = '1B271EB83A3179CD60EF3BC9E7E90885E42DEBCA1F140E9518EC68ADE3B8218D'
    'constr/top.sdc' = '9CB6B4C9553A50998DEC4DB20477D8E0786D8B2094B7A32CA5A5EF67226FA99E'
}
$manifest = Import-Csv (Join-Path $backupDir 'worktree_sha256.csv')
foreach ($relative in $expected.Keys) {
    $current = Join-Path $repoDir $relative
    $original = Join-Path ($backupDir + '/worktree') $relative
    $row = @($manifest | Where-Object File -eq $relative)
    if ($row.Count -ne 1 -or (Get-FileHash -LiteralPath $original).Hash -ne $row[0].SHA256) {
        throw "Invalid rollback backup: $relative"
    }
    if ((Get-FileHash -LiteralPath $current).Hash -ne $expected[$relative]) {
        throw "Source changed after AT; refusing to overwrite: $relative"
    }
}
$oldFs = Join-Path $backupDir 'ao-impl/pnr/Gowin2026.fs'
if ((Get-FileHash -LiteralPath $oldFs).Hash -ne '17DE0189B4AB8D367B9F35413AED7B86498557D838D44A4D6BA21B7FE1BFF625') {
    throw 'Invalid old bitstream backup'
}
Write-Output 'Verified: restore two source/constraint files and matching AO impl artifacts.'
Write-Output 'Unrelated working files, added tests and Git history will remain untouched.'
if (!$Apply) {
    Write-Output 'Dry run only. Add -Apply to restore. Close Gowin IDE/build processes first.'
    exit 0
}
if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -match '^(gw_sh|gowin|GowinDesigner)$').Count) {
    throw 'Close Gowin IDE/build processes before restoring'
}
# Preserve the current implementation as well; no recursive deletion or reset.
$savedImpl = Join-Path $backupDir ('optimized-impl-before-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
if (Test-Path -LiteralPath (Join-Path $repoDir 'impl')) {
    Copy-Item -LiteralPath (Join-Path $repoDir 'impl') -Destination $savedImpl -Recurse
}
foreach ($relative in $expected.Keys) {
    Copy-Item -LiteralPath (Join-Path ($backupDir + '/worktree') $relative) -Destination (Join-Path $repoDir $relative)
}
Copy-Item -Path (Join-Path $backupDir 'ao-impl/*') -Destination (Join-Path $repoDir 'impl') -Recurse -Force
foreach ($relative in $expected.Keys) {
    $row = @($manifest | Where-Object File -eq $relative)
    if ((Get-FileHash -LiteralPath (Join-Path $repoDir $relative)).Hash -ne $row[0].SHA256) {
        throw "Restored source hash mismatch: $relative"
    }
}
if ((Get-FileHash -LiteralPath (Join-Path $repoDir 'impl/pnr/Gowin2026.fs')).Hash -ne (Get-FileHash -LiteralPath $oldFs).Hash) {
    throw 'Restored bitstream hash mismatch'
}
foreach ($implFile in $aoImplManifest) {
    if ((Get-FileHash -LiteralPath (Join-Path ($repoDir + '/impl') $implFile.File)).Hash -ne $implFile.SHA256) {
        throw "Restored AO artifact hash mismatch: $($implFile.File)"
    }
}
Write-Output 'Restored AO working source and matching AO impl; hashes verified.'
Write-Output 'Git HEAD is not moved. The source reversal remains visible in git diff.'
Write-Output 'AO implementation is preserved under backup/ao-impl; AT implementation saved before rollback.'
exit 0
