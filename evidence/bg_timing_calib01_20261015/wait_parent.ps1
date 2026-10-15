$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$path=Join-Path $repoRoot 'evidence/main_fix_20261014/bg_mix01_full/summary.json'
$deadline=[DateTime]::UtcNow.AddHours(2)
Write-Output 'Waiting for the existing mixer full regression; no build starts before its clean verdict.'
while($true){
 if(Test-Path -LiteralPath $path){
  try{$suite=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json}catch{Start-Sleep -Seconds 5;continue}
  $good=($suite.source -eq 'd16ac80bc0539927b426b911ee029d6468219735' -and $suite.discovered -eq 198 -and $suite.selected -eq 195 -and $suite.pass_count -eq 193 -and $suite.expected_negative_count -eq 1 -and $suite.diagnostic_count -eq 1 -and $suite.snapshot_blobs_verified -eq 310 -and $suite.fail_count -eq 0)
  if(!$good){throw 'Parent full regression is not clean/complete or has the wrong source; candidate blocked'}
  Write-Output 'Parent gate PASS: 193 functional + 1 negative + 1 separate diagnostic, zero failures, 310 blobs.'
  break
 }
 if([DateTime]::UtcNow -ge $deadline){throw 'Parent gate wait timed out; no candidate build authorized by this script'}
 Start-Sleep -Seconds 5
}
