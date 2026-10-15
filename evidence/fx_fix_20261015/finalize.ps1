param([Parameter(Mandatory=$true)][ValidateSet(0,1)][int]$RegressionExitCode)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source='92a77bb182077f8ffebac9c4a30512669adaa602'
$suite=Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'evidence/main_fix_20261014/fx_fixed_full/summary.json') | ConvertFrom-Json
$syn=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'synthesis_exit.json') | ConvertFrom-Json
if($suite.source -ne $source -or $syn.source_commit -ne $source){throw 'Verification source mismatch'}
$manifest=Import-Csv (Join-Path $PSScriptRoot 'synthesis_inputs.csv')
if($manifest.Count -ne 6){throw 'Synthesis input manifest incomplete'}
foreach($row in $manifest){
  if((Get-FileHash -LiteralPath (Join-Path $repoRoot ('build/fx_fix_syn/'+$row.Name))).Hash -ne $row.SHA256){throw ('Synthesis input changed: '+$row.Name)}
}
$functional=($RegressionExitCode -eq 0 -and $suite.discovered -eq 205 -and $suite.selected -eq 202 -and
  $suite.pass_count -eq 200 -and $suite.expected_negative_count -eq 1 -and $suite.diagnostic_count -eq 1 -and
  $suite.fail_count -eq 0 -and $suite.snapshot_blobs_verified -eq 321)
$synOk=($syn.observed_exit_code -eq 0)
$record=[ordered]@{
  Source=$source; RegressionExitCode=$RegressionExitCode; SynthesisExitCode=$syn.observed_exit_code;
  FunctionalAccepted=$functional; FunctionalPass=$suite.pass_count; ExpectedNegative=$suite.expected_negative_count;
  SeparateDiagnostic=$suite.diagnostic_count; Failures=$suite.fail_count; VerifiedSourceBlobs=$suite.snapshot_blobs_verified;
  SynthesisAccepted=$synOk; RepairVerificationAccepted=($functional -and $synOk);
  ProductionModulesChanged=@('rtl/w3c/fx_dist.v','rtl/w3c/fx_trem.v','rtl/w3c/fx_chain.v');
  EffectArithmeticPreserved=$true; PublicPortWidthsPreserved=$true; DistLatencyCycles=5; TremLatencyCycles=3;
  ActualChainLatencyCycles=17; ChainMetadataCorrectedFromCycles=16;
  TopIntegrated=$false; IntegratedTiming='NOT_RUN'; FirmwareGenerated=$false; BoardAcceptance='NOT_RUN';
  BJReplaced=$false; Pushed=$false
}
$record | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $PSScriptRoot 'completion.json')
if(!($functional -and $synOk)){exit 1}
exit 0
