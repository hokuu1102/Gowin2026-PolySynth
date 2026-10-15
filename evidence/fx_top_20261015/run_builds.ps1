$ErrorActionPreference='Stop'
$gw='D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe'
foreach($fxConfig in @('all','bypass')){
 $meta=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot ($fxConfig+'_source.json')) | ConvertFrom-Json
 if(!$meta.Sealed){throw ('Build is not sealed: '+$fxConfig)}
 $exitPath=Join-Path $PSScriptRoot ($fxConfig+'_build_exit.json')
 if(Test-Path -LiteralPath $exitPath){throw 'Do not rerun a finished physical build into old evidence'}
 $started=[DateTime]::UtcNow.ToString('o')
 Push-Location $meta.BuildDirectory
 try{& $gw 'tools/build_target_pnr.tcl' *> build.log; $code=$LASTEXITCODE}finally{Pop-Location}
 [ordered]@{Source=$meta.Source;FxConfig=$fxConfig;ObservedExitCode=$code;StartedAtUTC=$started;
  ObservedAtUTC=[DateTime]::UtcNow.ToString('o');ActualProcessExitCaptured=$true} |
  ConvertTo-Json | Out-File -LiteralPath $exitPath -Encoding UTF8
 Write-Output ('FX_PROFILE='+$fxConfig+' ACTUAL_BUILD_EXIT='+$code+' SOURCE='+$meta.Source)
 # A timing failure may still exit0. A failed all-effects tool run does not justify
 # calling bypass a replacement; it is still useful to measure the second profile.
}
exit 0
