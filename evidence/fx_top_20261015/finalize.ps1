param([Parameter(Mandatory=$true)][ValidateSet(0,1)][int]$RegressionExitCode)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source='0e98a58a8e69b13d779621de4e756b25707ee056'
$suite=Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'evidence/main_fix_20261014/fx_top_full/summary.json') | ConvertFrom-Json
if($suite.source -ne $source){throw 'Wrong regression source'}
$functional=($RegressionExitCode -eq 0 -and $suite.discovered -eq 207 -and $suite.selected -eq 204 -and
 $suite.pass_count -eq 202 -and $suite.expected_negative_count -eq 1 -and $suite.diagnostic_count -eq 1 -and
 $suite.fail_count -eq 0 -and $suite.snapshot_blobs_verified -eq 323)
$topProbe=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'all_top_exit.json') | ConvertFrom-Json
$probeHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'tb_top_fx_all.sv')).Hash
$probeLog=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'all_top.run.log')
$probeAccepted=($topProbe.Source -eq $source -and $topProbe.ObservedExitCode -eq 0 -and
 $topProbe.FixtureSHA256 -eq $probeHash -and $probeLog -match 'PASS: actual top all-effects mask7/depth128')
$profiles=[ordered]@{}
foreach($fxConfig in @('all','bypass')){
 $meta=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot ($fxConfig+'_source.json')) | ConvertFrom-Json
 $exitRecord=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot ($fxConfig+'_build_exit.json')) | ConvertFrom-Json
 if($meta.Source -ne $source -or !$meta.Sealed -or $exitRecord.Source -ne $source -or
    $exitRecord.FxConfig -ne $fxConfig -or !$exitRecord.ActualProcessExitCaptured){throw 'Physical source or observed termination mismatch'}
 $manifest=Import-Csv (Join-Path $PSScriptRoot ($fxConfig+'_inputs.csv'))
 if($manifest.Count -ne 80){throw 'Incomplete physical manifest'}
 foreach($row in $manifest){
  if((Get-FileHash -LiteralPath (Join-Path $meta.BuildDirectory $row.Path)).Hash -ne $row.BuildSHA256){throw ('Physical input changed: '+$row.Path)}
 }
 $archiveDir=Join-Path $PSScriptRoot ($fxConfig+'_reports')
 New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
 Copy-Item -LiteralPath (Join-Path $meta.BuildDirectory 'build.log') -Destination (Join-Path $archiveDir 'build.log')
 $timing=$null; $toolAccepted=($exitRecord.ObservedExitCode -eq 0)
 if($toolAccepted){
  $log=Get-Content -Raw -LiteralPath (Join-Path $meta.BuildDirectory 'build.log')
  if($log -notmatch 'Placement and routing completed' -or $log -notmatch 'Bitstream generation completed' -or
     $log -notmatch 'Generate file.*Gowin2026.tr.html.*completed'){throw 'Tool exited0 without complete physical reports'}
  $timingText=& (Join-Path $repoRoot 'evidence/main_fix_20261014/read_timing.ps1') -ProjectDir $meta.BuildDirectory -SourceCommit $source
  $timing=$timingText | ConvertFrom-Json
  if($timing.NativeBudgetNs -ne 16.4){throw 'Original timing constraint changed'}
  foreach($name in @('Gowin2026_tr_content.html','Gowin2026.rpt.txt','Gowin2026.timing_paths')){
   Copy-Item -LiteralPath (Join-Path $meta.BuildDirectory ('impl/pnr/'+$name)) -Destination $archiveDir
  }
  Copy-Item -LiteralPath (Join-Path $meta.BuildDirectory 'impl/gwsynthesis/Gowin2026_syn_rsc.xml') -Destination $archiveDir
 }
 $profiles[$fxConfig]=[ordered]@{Source=$source;Overrides=$meta.Overrides;BuildName=$meta.BuildName;
  ActualToolExitCode=$exitRecord.ObservedExitCode;ToolAccepted=$toolAccepted;FrozenInputs=80;Timing=$timing;
  TimingAccepted=($toolAccepted -and $timing.Accepted)}
}
$ramDelta=$null; $enabledMemoryObserved=$false
if($profiles.all.ToolAccepted -and $profiles.bypass.ToolAccepted){
 $ramDelta=$profiles.all.Timing.BSRAM-$profiles.bypass.Timing.BSRAM
 $enabledMemoryObserved=($ramDelta -ge 18)
}
$record=[ordered]@{Source=$source;RegressionExitCode=$RegressionExitCode;FunctionalAccepted=$functional;
 FunctionalPass=$suite.pass_count;ExpectedNegative=$suite.expected_negative_count;SeparateDiagnostic=$suite.diagnostic_count;
 FunctionalFailures=$suite.fail_count;VerifiedSourceBlobs=$suite.snapshot_blobs_verified;
 AllEffectsPublicTopProbeAccepted=$probeAccepted;Profiles=$profiles;EnabledVsBypassBRAMDelta=$ramDelta;
 EnabledMemoryObserved=$enabledMemoryObserved;
 Accepted=($functional -and $probeAccepted -and $profiles.all.TimingAccepted -and $profiles.bypass.TimingAccepted -and $enabledMemoryObserved);
 DefaultCompileBypass=$true;RuntimeControlsAdded=$false;ConstraintsRelaxed=$false;
 BoardAcceptance='NOT_RUN';BJReplaced=$false;FirmwareCopiedToUserArchive=$false;Pushed=$false}
$record | ConvertTo-Json -Depth 10 | Tee-Object -FilePath (Join-Path $PSScriptRoot 'completion.json')
if(!$record.Accepted){exit 1}
exit 0
