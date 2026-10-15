param([Parameter(Mandatory=$true)][ValidateSet(0)][int]$BuildExitCode)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$projectDir=Join-Path $repoRoot 'build/fft_pnr07_color'
$source='cf2c62c83dec2e04d1077ed6e6b6b2148b2c9864'
$exitRecord=Get-Content -Raw (Join-Path $PSScriptRoot 'build_exit.json') | ConvertFrom-Json
if($exitRecord.source_commit -ne $source -or $exitRecord.observed_exit_code -ne 0){throw 'Missing true build exit evidence'}
$manifest=Import-Csv (Join-Path $PSScriptRoot 'product_inputs.csv')
if($manifest.Count -ne 76){throw 'Wrong production input count'}
foreach($row in $manifest){
 if((Get-FileHash -LiteralPath (Join-Path $projectDir $row.Path)).Hash -ne $row.SourceSHA256){throw ('Frozen input mismatch: '+$row.Path)}
}
$log=Get-Content -Raw (Join-Path $projectDir 'build.log')
if($log -notmatch 'Placement and routing completed' -or $log -notmatch 'Bitstream generation completed' -or $log -notmatch 'Generate file.*Gowin2026.tr.html.*completed'){throw 'Incomplete physical build'}
$suitePath=Join-Path $repoRoot 'evidence/main_fix_20261014/fft_color_full/summary.json'
$suite=$null;$regressionState='PENDING_NOT_CLAIMED_PASS'
if(Test-Path $suitePath){
 $suite=Get-Content -Raw $suitePath | ConvertFrom-Json
 if($suite.source -ne $source){throw 'Wrong regression source'}
 if($suite.fail_count -ne 0){throw 'Known regression failure; do not deliver firmware'}
 $good=($suite.selected -eq 187 -and $suite.pass_count -eq 185 -and $suite.expected_negative_count -eq 1 -and $suite.diagnostic_count -eq 1 -and $suite.snapshot_blobs_verified -eq 299)
 if(!$good){throw 'Incomplete or inconsistent regression summary'}
 $regressionState='COMPLETE_185_FUNCTIONAL_PASS_1_NEGATIVE_1_DIAGNOSTIC'
}else{
 $testDir=Split-Path $suitePath -Parent
 foreach($result in (Get-ChildItem -LiteralPath $testDir -Recurse -Filter result.json)){
  $row=Get-Content -Raw $result.FullName | ConvertFrom-Json
  if($row.status -notin 'PASS','EXPECTED_NEGATIVE_PASS','DIAGNOSTIC_CONFIRMED'){throw ('Known test failure/inconclusive: '+$row.name+' '+$row.status)}
 }
}
$timing=$null;$timingReadError=$null
try{
 $timingText=& (Join-Path $repoRoot 'evidence/main_fix_20261014/read_timing.ps1') -ProjectDir $projectDir -SourceCommit $source
 $timing=$timingText | ConvertFrom-Json
}catch{$timingReadError=$_.Exception.Message}
# User explicitly requests experimental hardware evaluation before timing repair.
# Keep native constraints and true STA, but do not block experimental copy on STA.
$archive='C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams'
if(!(Test-Path -LiteralPath $archive -PathType Container)){throw 'User archive absent'}
$srcFs=Join-Path $projectDir 'impl/pnr/Gowin2026.fs'
$dstFs=Join-Path $archive 'BF_fft_COLOR_BARS_X2_EXPERIMENT_ONLY_BOARD_UNVERIFIED_20261014.fs'
$hash=(Get-FileHash -LiteralPath $srcFs -Algorithm SHA256).Hash
if(Test-Path -LiteralPath $dstFs){
 if((Get-FileHash -LiteralPath $dstFs -Algorithm SHA256).Hash -ne $hash){throw 'Different previous file exists; not overwritten'}
}else{Copy-Item -LiteralPath $srcFs -Destination $dstFs}
if((Get-FileHash -LiteralPath $dstFs -Algorithm SHA256).Hash -ne $hash){throw 'Copy hash mismatch'}
$record=[ordered]@{Source=$source;BuildExitCode=$BuildExitCode;ProductInputsVerified=76;
 Purpose='USER_AUTHORIZED_EXPERIMENT_ONLY_TIMING_ACCEPTANCE_DEFERRED';
 RegressionState=$regressionState;Timing=$timing;TimingReadError=$timingReadError;
 FormalAcceptance=$false;BoardAcceptance='NOT_RUN';MainReplaced=$false;Pushed=$false;
 ArchivedBitstream=$dstFs;Bytes=(Get-Item -LiteralPath $dstFs).Length;SHA256=$hash}
$record | ConvertTo-Json -Depth 6 | Out-File (Join-Path $PSScriptRoot 'experiment_archive.json') -Encoding utf8
$record | ConvertTo-Json -Depth 6
exit 0
