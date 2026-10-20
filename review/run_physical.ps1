$ErrorActionPreference = 'Stop'
$auditRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $auditRoot
# Physical outputs are confined to impl/ and named gowin evidence; simulation
# images and per-test logs are independent. Run against the same frozen source.
$auditRegExit = Join-Path $PSScriptRoot 'regression_exit.json'
$auditRetryExit = Join-Path $PSScriptRoot 'retries_exit.json'
$auditReady = Join-Path $PSScriptRoot 'ready_for_physical.json'
$auditSource = 'cd63b0773480e43b19d47f7b541d202a0a66df4d'
& git diff --quiet $auditSource -- . ':(exclude)review/**' ':(exclude)sim/evidence/**' ':(exclude)evidence/**'
if ($LASTEXITCODE -ne 0) { throw 'Production inputs differ from frozen audit source' }
$auditStart = [DateTime]::UtcNow.ToString('o')
$auditCode = 125
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/gowin_build.ps1 -GwSh 'D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe' *> review/physical.log
    $auditCode = $LASTEXITCODE
} finally {
    $auditResult = [ordered]@{
        source=$auditSource
        started_utc=$auditStart
        finished_utc=[DateTime]::UtcNow.ToString('o')
        actual_exit_code=$auditCode
        regression_exit_file=$auditRegExit
        retry_exit_file=$auditRetryExit
        verification_readiness_file=$auditReady
        command='powershell.exe -NoProfile -ExecutionPolicy Bypass -File sim/gowin_build.ps1 -GwSh D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe'
    }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'physical_exit.json'), ($auditResult | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
exit $auditCode
