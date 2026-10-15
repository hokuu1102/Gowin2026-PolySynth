param([Parameter(Mandatory=$true)][ValidateSet(0)][int]$BuildExitCode)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$projectDir=Join-Path $repoRoot 'build/fft_pnr02_viewopt'
$summaryPath=Join-Path $repoRoot 'evidence/main_fix_20261014/fft_viewopt_full/summary.json'
$expectedSource='9ad44c1189b67362e83431a6d71b50f16616d0b8'
if(!(Test-Path -LiteralPath $summaryPath)){throw 'Combined regression not finished'}
$suite=Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
if($suite.source -ne $expectedSource){throw 'Wrong regression source'}
$manifest=Import-Csv (Join-Path $PSScriptRoot 'view_opt01_inputs.csv')
if($manifest.Count -ne 76){throw 'Unexpected build input count'}
foreach($row in $manifest){
    if((Get-FileHash -LiteralPath (Join-Path $projectDir $row.Path)).Hash -ne $row.SourceSHA256){
        throw ('Frozen build input mismatch: '+$row.Path)
    }
}
$log=Get-Content -Raw -LiteralPath (Join-Path $projectDir 'build.log')
if($log -notmatch 'Placement and routing completed' -or
   $log -notmatch 'Bitstream generation completed' -or
   $log -notmatch 'Generate file.*Gowin2026.tr.html.*completed'){
    throw 'Build log lacks full physical completion'
}
$staText=& (Join-Path $repoRoot 'evidence/main_fix_20261014/read_timing.ps1') `
    -ProjectDir $projectDir -SourceCommit $expectedSource
$staCode=$LASTEXITCODE
$sta=$staText | ConvertFrom-Json
$staText | Out-File (Join-Path $PSScriptRoot 'view_opt01_metrics.json') -Encoding utf8
$reportDir=Join-Path $PSScriptRoot 'view_opt01_reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
foreach($rel in @('impl/pnr/Gowin2026_tr_content.html','impl/pnr/Gowin2026.rpt.txt',
    'impl/pnr/Gowin2026.pin.html','impl/gwsynthesis/Gowin2026_syn_rsc.xml')){
    Copy-Item -LiteralPath (Join-Path $projectDir $rel) -Destination $reportDir
}
Copy-Item -LiteralPath (Join-Path $projectDir 'build.log') -Destination (Join-Path $PSScriptRoot 'view_opt01_build.log')
$suitePass=($suite.selected -eq 182 -and $suite.pass_count -eq 180 -and
    $suite.expected_negative_count -eq 1 -and $suite.diagnostic_count -eq 1 -and
    $suite.fail_count -eq 0 -and $suite.snapshot_blobs_verified -eq 294)
$accepted=($BuildExitCode -eq 0 -and $staCode -eq 0 -and $sta.Accepted -and
    $sta.NativeBudgetNs -eq 16.4 -and $suitePass)
$sourceFs=Join-Path $projectDir 'impl/pnr/Gowin2026.fs'
$record=[ordered]@{Source=$expectedSource;BuildExitCode=$BuildExitCode;
    ProductInputsVerified=76;RegressionPass=$suitePass;Timing=$sta;
    SoftwareAndTimingAccepted=$accepted;BoardAcceptance='NOT_RUN';
    MainReplaced=$false;Pushed=$false;SourceBitstream=$sourceFs}
if($accepted){
    $archiveDir='C:/Users/cyx/Desktop/学习/hdmi_640x480/bitstreams'
    if(!(Test-Path -LiteralPath $archiveDir -PathType Container)){throw 'User bitstream archive is absent'}
    $dest=Join-Path $archiveDir 'BA_fft_2048_VIEWOPT01_TIMING_PASS_BOARD_UNVERIFIED_20261014.fs'
    $sha=(Get-FileHash -LiteralPath $sourceFs).Hash
    if(Test-Path -LiteralPath $dest){
        if((Get-FileHash -LiteralPath $dest).Hash -ne $sha){throw 'Archive filename collision; nothing overwritten'}
    }else{
        Copy-Item -LiteralPath $sourceFs -Destination $dest
    }
    if((Get-FileHash -LiteralPath $dest).Hash -ne $sha){throw 'Bitstream copy hash mismatch'}
    $record['ArchivedBitstream']=$dest
    $record['SHA256']=$sha
    $record['Bytes']=(Get-Item -LiteralPath $dest).Length
}
$record | ConvertTo-Json -Depth 6 | Out-File (Join-Path $PSScriptRoot 'view_opt01_completion.json') -Encoding utf8
$record | ConvertTo-Json -Depth 6
if(!$accepted){exit 1}
exit 0
