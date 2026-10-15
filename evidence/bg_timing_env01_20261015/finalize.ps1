param([Parameter(Mandatory=$true)][ValidateSet(0)][int]$BuildExitCode)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source='7e5a4e112bea1a761eaf98261213d0824889192f'
$buildDir=Join-Path $repoRoot 'build/bg_timing_env01_pnr'
$exitRecord=Get-Content -Raw (Join-Path $PSScriptRoot 'build_exit.json') | ConvertFrom-Json
if($exitRecord.source_commit -ne $source -or $exitRecord.observed_exit_code -ne 0){throw 'Missing observed successful build exit'}
$manifest=Import-Csv (Join-Path $PSScriptRoot 'product_inputs.csv')
if($manifest.Count -ne 76){throw 'Wrong frozen input manifest'}
foreach($r in $manifest){
 if((Get-FileHash -LiteralPath (Join-Path $buildDir $r.Path)).Hash -ne $r.SourceSHA256){throw ('Frozen input changed: '+$r.Path)}
}
$log=Get-Content -Raw (Join-Path $buildDir 'build.log')
if($log -notmatch 'Placement and routing completed' -or $log -notmatch 'Bitstream generation completed' -or $log -notmatch 'Generate file.*Gowin2026.tr.html.*completed'){throw 'Incomplete physical build reports'}
$timingText=& (Join-Path $repoRoot 'evidence/main_fix_20261014/read_timing.ps1') -ProjectDir $buildDir -SourceCommit $source
$timing=$timingText | ConvertFrom-Json
if(!$timing -or $timing.NativeBudgetNs -ne 16.4){throw 'Missing timing data or changed native constraint'}
$baseline=Get-Content -Raw (Join-Path $repoRoot 'evidence/fft_teammate_merge_20261014/completion.json') | ConvertFrom-Json
$suite=Get-Content -Raw (Join-Path $repoRoot 'evidence/main_fix_20261014/bg_env01_full/summary.json') | ConvertFrom-Json
$functional=($suite.source -eq $source -and $suite.discovered -eq 197 -and $suite.selected -eq 194 -and $suite.pass_count -eq 192 -and $suite.expected_negative_count -eq 1 -and $suite.diagnostic_count -eq 1 -and $suite.fail_count -eq 0 -and $suite.snapshot_blobs_verified -eq 308)
$accepted=($functional -and $timing.Accepted)
$record=[ordered]@{Source=$source;Baseline=$baseline.Source;BuildExitCode=$BuildExitCode;
 FrozenInputs=76;FunctionalAccepted=$functional;FunctionalPass=$suite.pass_count;
 ExpectedNegative=$suite.expected_negative_count;SeparateDiagnostic=$suite.diagnostic_count;
 Timing=$timing;SetupDeltaNs=($timing.SetupSlack-$baseline.Timing.SetupSlack);
 HoldDeltaNs=($timing.HoldSlack-$baseline.Timing.HoldSlack);CLSDelta=($timing.CLS-$baseline.Timing.CLS);
 Accepted=$accepted;Bitstream=$null;SHA256=$null;BoardAcceptance='NOT_RUN';MainReplaced=$false;Pushed=$false}
if($accepted){
 $archiveDir='C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams'
 if(!(Test-Path -LiteralPath $archiveDir -PathType Container)){throw 'Original archive folder absent'}
 $srcFs=Join-Path $buildDir 'impl/pnr/Gowin2026.fs'
 $dstFs=Join-Path $archiveDir 'BH_BG_ENV01_TIMING_PASS_BOARD_UNVERIFIED_20261015.fs'
 $hash=(Get-FileHash -LiteralPath $srcFs).Hash
 if(Test-Path -LiteralPath $dstFs){
  if((Get-FileHash -LiteralPath $dstFs).Hash -ne $hash){throw 'Different archived file exists; not overwritten'}
 }else{Copy-Item -LiteralPath $srcFs -Destination $dstFs}
 if((Get-FileHash -LiteralPath $dstFs).Hash -ne $hash){throw 'Archived file hash mismatch'}
 $record.Bitstream=$dstFs;$record.SHA256=$hash
}
$record | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $PSScriptRoot 'completion.json')
if(!$accepted){exit 1}
exit 0
