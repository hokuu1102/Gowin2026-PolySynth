$ErrorActionPreference = 'Stop'
$auditRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $auditRoot
$auditSource = 'cd63b0773480e43b19d47f7b541d202a0a66df4d'
# Permit an audit-only archival commit while freezing tracked production inputs.
& git diff --quiet $auditSource -- . ':(exclude)review/**' ':(exclude)sim/evidence/**' ':(exclude)evidence/**'
if ($LASTEXITCODE -ne 0) { throw 'Production inputs differ from frozen audit source' }
$auditStart = [DateTime]::UtcNow.ToString('o')
$auditCode = 125
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/tb_all.ps1 *> review/regression.log
    $auditCode = $LASTEXITCODE
} finally {
    $auditResult = [ordered]@{
        source = $auditSource
        started_utc = $auditStart
        finished_utc = [DateTime]::UtcNow.ToString('o')
        actual_exit_code = $auditCode
        command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/tb_all.ps1'
    }
    $auditJson = $auditResult | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'regression_exit.json'), $auditJson, [Text.UTF8Encoding]::new($false))
}
exit $auditCode
