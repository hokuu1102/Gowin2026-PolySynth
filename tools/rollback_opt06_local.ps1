param(
    [switch]$Apply,
    [string]$BackupDir = 'C:/Users/cyx/Documents/ChatGPT/FPGA/rollback-pre-opt06-20261013'
)
$ErrorActionPreference = 'Stop'
$repoDir = Split-Path -Parent $PSScriptRoot
$backupDir = $BackupDir
$optimizedInputs = @(Import-Csv (Join-Path $backupDir 'optimized_inputs_sha256.csv'))
if ($optimizedInputs.Count -ne 81) { throw 'Invalid optimized input manifest' }
foreach ($inputFile in $optimizedInputs) {
    if ((Get-FileHash -LiteralPath (Join-Path $repoDir $inputFile.File)).Hash -ne $inputFile.SHA256) {
        throw "Project input changed after OPT06; refusing rollback: $($inputFile.File)"
    }
}
$afImplManifest = @(Import-Csv (Join-Path $backupDir 'af_impl_sha256.csv'))
if (!$afImplManifest.Count) { throw 'Missing AF impl integrity manifest' }
foreach ($implFile in $afImplManifest) {
    if ((Get-FileHash -LiteralPath (Join-Path ($backupDir + '/af-impl') $implFile.File)).Hash -ne $implFile.SHA256) {
        throw "AF backup artifact corrupted: $($implFile.File)"
    }
}
$expected = @{
    'rtl/w3b/note_manager.v' = '3AB61B75ACCB9F0206FA5B34E1A322FCCE6CF221BD9B4E621033EADFB3EDC1CF'
    'constr/top.sdc' = '6EC9FB78E703D0CFF4912341BA1FE051BDA980110FCFAE6C9F7DA3A0635D64AD'
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
        throw "Source changed after OPT06; refusing to overwrite: $relative"
    }
}
$oldFs = Join-Path $backupDir 'af-impl/pnr/Gowin2026.fs'
if ((Get-FileHash -LiteralPath $oldFs).Hash -ne 'C25DD989518C278AF139E0A06190F0BDD3917A87BC7A5598A297D0DD36DB23BC') {
    throw 'Invalid old bitstream backup'
}
Write-Output 'Verified: restore two source/constraint files and matching AF impl artifacts.'
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
Copy-Item -Path (Join-Path $backupDir 'af-impl/*') -Destination (Join-Path $repoDir 'impl') -Recurse -Force
foreach ($relative in $expected.Keys) {
    $row = @($manifest | Where-Object File -eq $relative)
    if ((Get-FileHash -LiteralPath (Join-Path $repoDir $relative)).Hash -ne $row[0].SHA256) {
        throw "Restored source hash mismatch: $relative"
    }
}
if ((Get-FileHash -LiteralPath (Join-Path $repoDir 'impl/pnr/Gowin2026.fs')).Hash -ne (Get-FileHash -LiteralPath $oldFs).Hash) {
    throw 'Restored bitstream hash mismatch'
}
foreach ($implFile in $afImplManifest) {
    if ((Get-FileHash -LiteralPath (Join-Path ($repoDir + '/impl') $implFile.File)).Hash -ne $implFile.SHA256) {
        throw "Restored AF artifact hash mismatch: $($implFile.File)"
    }
}
Write-Output 'Restored pre-OPT06 working source and matching AF impl; hashes verified.'
Write-Output 'Git HEAD is not moved. The source reversal remains visible in git diff.'
Write-Output 'The previous main impl is separately preserved under backup/impl.'
exit 0
