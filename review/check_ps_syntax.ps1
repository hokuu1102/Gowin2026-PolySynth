$ErrorActionPreference = 'Stop'
$auditRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $auditRoot
$auditNames = & git -c core.quotePath=false ls-files '*.ps1'
$auditResults = @()
foreach ($auditName in $auditNames) {
    $auditTokens = $null
    $auditErrors = $null
    $auditPath = Join-Path $auditRoot $auditName
    [Management.Automation.Language.Parser]::ParseFile($auditPath, [ref]$auditTokens, [ref]$auditErrors) | Out-Null
    $auditResults += [pscustomobject]@{path=$auditName; errors=@($auditErrors | ForEach-Object { [pscustomobject]@{line=$_.Extent.StartLineNumber; message=$_.Message} })}
}
$auditBad = @($auditResults | Where-Object {$_.errors.Count -gt 0})
$auditReport = [ordered]@{version=$PSVersionTable.PSVersion.ToString(); files=$auditResults.Count; failed=$auditBad.Count; results=$auditResults}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'powershell_syntax.json'), ($auditReport | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output ("PowerShell parser: {0} files, {1} failures" -f $auditResults.Count,$auditBad.Count)
foreach ($auditItem in $auditBad) { Write-Output $auditItem.path; $auditItem.errors | Format-Table }
if ($auditBad.Count) {exit 1}
exit 0
