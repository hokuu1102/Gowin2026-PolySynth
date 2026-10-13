param([string]$Iverilog='D:\iverilog\bin\iverilog.exe', [string]$Vvp='D:\iverilog\bin\vvp.exe',
      [string]$EvidenceDir='evidence/q_adc_fix_20261012',
      [string[]]$Tests=@('tb_adc_fault_window','tb_scope_mode_switch','tb_top_scope_live','tb_adc_farm','tb_waveform_scope','tb_xy_scope','tb_top_m0','tb_right_adc','tb_top_sound','tb_tdm_render_mixer'))
$ErrorActionPreference='Stop'
$repoDir=Split-Path -Parent $PSScriptRoot
$resultDir=Join-Path $repoDir $EvidenceDir
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
$sourceFiles=@(Get-ChildItem (Join-Path $repoDir 'rtl') -Recurse -File -Include *.v,*.sv | ForEach-Object FullName)
$modelFiles=@(Get-ChildItem (Join-Path $repoDir 'tb/models'),(Join-Path $repoDir 'tb/checkers') -Recurse -File -Include *.v,*.sv | Where-Object Name -notlike 'tb_*' | ForEach-Object FullName)
$testNames=$Tests
Push-Location $repoDir
try {
    foreach($testName in $testNames) {
        $testFile=Get-ChildItem tb -Recurse -Filter ($testName+'.sv') -File
        $imageFile=Join-Path $resultDir ($testName+'.vvp')
        # Windows PowerShell treats native stderr warnings as error records.
        # Check the native exit status explicitly instead of failing on warnings.
        $ErrorActionPreference='Continue'
        $compileOutput=& $Iverilog -g2012 -DWAVETABLE_BEHAVIORAL -s $testName -o $imageFile @sourceFiles @modelFiles $testFile.FullName 2>&1
        $compileExit=$LASTEXITCODE
        $ErrorActionPreference='Stop'
        $compileOutput | Out-File (Join-Path $resultDir ($testName+'.compile.log')) -Encoding utf8
        if($compileExit -ne 0) { throw "Compile failed: $testName" }
        # Existing testbenches choose their own waveform output directories.
        $testSource=Get-Content -Raw -Encoding UTF8 $testFile.FullName
        foreach($dump in [regex]::Matches($testSource,'\$dumpfile\s*\(\s*"([^"]+)"')) {
            $dumpDir=Split-Path -Parent $dump.Groups[1].Value
            if($dumpDir) { New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null }
        }
        $ErrorActionPreference='Continue'
        $runOutput=& $Vvp $imageFile 2>&1
        $runExit=$LASTEXITCODE
        $ErrorActionPreference='Stop'
        $runOutput | Out-File (Join-Path $resultDir ($testName+'.log')) -Encoding utf8
        if($runExit -ne 0 -or ($runOutput -match '^\s*FAIL:')) { throw "Runtime failed: $testName" }
        Write-Output "PASS $testName"
    }
    Write-Output ('PASS: '+$testNames.Count+'/'+$testNames.Count+' focused regressions')
} finally { Pop-Location }
