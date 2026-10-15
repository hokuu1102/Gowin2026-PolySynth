param([Parameter(Mandatory=$true)][ValidateSet(0)][int]$BuildExitCode)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source='fa0dec8d255dee7ca99a0490de9f0f19ef6846cc'
$buildDir=Join-Path $repoRoot 'build/fft_teammate_merge_pnr01'
$exitRecord=Get-Content -Raw (Join-Path $PSScriptRoot 'build_exit.json') | ConvertFrom-Json
if($exitRecord.source_commit -ne $source -or $exitRecord.observed_exit_code -ne 0){throw 'Missing actual successful build exit evidence'}
$manifest=Import-Csv (Join-Path $PSScriptRoot 'product_inputs.csv')
if($manifest.Count -ne 76){throw 'Wrong frozen input count'}
foreach($row in $manifest){
 if((Get-FileHash -LiteralPath (Join-Path $buildDir $row.Path)).Hash -ne $row.SourceSHA256){throw ('Frozen input changed: '+$row.Path)}
}
$log=Get-Content -Raw (Join-Path $buildDir 'build.log')
if($log -notmatch 'Placement and routing completed' -or $log -notmatch 'Bitstream generation completed' -or $log -notmatch 'Generate file.*Gowin2026.tr.html.*completed'){throw 'Physical reports incomplete'}
$suite=Get-Content -Raw (Join-Path $repoRoot 'evidence/main_fix_20261014/fft_merge_full/summary.json') | ConvertFrom-Json
if($suite.source -ne $source -or $suite.selected -ne 193 -or $suite.pass_count -ne 191 -or $suite.expected_negative_count -ne 1 -or $suite.diagnostic_count -ne 1 -or $suite.snapshot_blobs_verified -ne 306 -or $suite.fail_count -ne 0){throw 'Merged functional acceptance is not complete and clean'}
$timingText=& (Join-Path $repoRoot 'evidence/main_fix_20261014/read_timing.ps1') -ProjectDir $buildDir -SourceCommit $source
$timing=$timingText | ConvertFrom-Json
if(!$timing){throw 'Missing timing report; do not invent a result'}
# Timing failure is explicitly permitted for this experiment, never relabeled PASS.
$dstDir='C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams'
if(!(Test-Path -LiteralPath $dstDir -PathType Container)){throw 'Original archive folder absent'}
$srcFs=Join-Path $buildDir 'impl/pnr/Gowin2026.fs'
$dstFs=Join-Path $dstDir 'BG_fft_COLOR_X2_TEAMMATE_MERGE_EXPERIMENT_BOARD_UNVERIFIED_20261014.fs'
$hash=(Get-FileHash -LiteralPath $srcFs).Hash
if(Test-Path -LiteralPath $dstFs){
 if((Get-FileHash -LiteralPath $dstFs).Hash -ne $hash){throw 'Different old firmware exists; not overwritten'}
}else{Copy-Item -LiteralPath $srcFs -Destination $dstFs}
if((Get-FileHash -LiteralPath $dstFs).Hash -ne $hash){throw 'Archived firmware hash mismatch'}
[ordered]@{Source=$source;BuildExitCode=$BuildExitCode;ProductInputsVerified=76;
 FunctionalPass=191;ExpectedNegativePass=1;SeparateDiagnostic=1;Timing=$timing;
 FormalBoardAcceptance='NOT_RUN';MainReplaced=$false;Pushed=$false;
 Bitstream=$dstFs;SHA256=$hash;Purpose='FUNCTIONALLY_VERIFIED_EXPERIMENT_TIMING_NOT_A_DELIVERY_GATE'} |
 ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $PSScriptRoot 'completion.json')
