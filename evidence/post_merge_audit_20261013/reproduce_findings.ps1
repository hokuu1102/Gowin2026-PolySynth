# Diagnostic runner: exit 1 means the known production failures reproduced.
$ErrorActionPreference = 'Continue'
$repoDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resultDir = Join-Path $PSScriptRoot 'repro'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
$sources = @(Get-ChildItem (Join-Path $repoDir 'rtl'),(Join-Path $repoDir 'tb/models') -Recurse -File -Include *.v,*.sv | Where-Object Name -notlike 'tb_*' | ForEach-Object FullName)
$tests = @('tb_dump_pitch_roundtrip','tb_dump_fifo_backpressure','tb_dump_uart_backpressure','tb_guide_physical_pulse')
$redCount = 0
Push-Location $repoDir
try {
    foreach ($testName in $tests) {
        $testFile = Join-Path $PSScriptRoot ($testName + '.sv')
        $imageFile = Join-Path $resultDir ($testName + '.vvp')
        $compileOutput = & D:/iverilog/bin/iverilog.exe -g2012 -DWAVETABLE_BEHAVIORAL -s $testName -o $imageFile @sources $testFile 2>&1
        $compileExit = $LASTEXITCODE
        $compileOutput | Out-File (Join-Path $resultDir ($testName+'.compile.log')) -Encoding utf8
        if ($compileExit -ne 0) { Write-Output "ERROR: compile failed $testName"; exit 2 }
        $runOutput = & D:/iverilog/bin/vvp.exe $imageFile 2>&1
        $runExit = $LASTEXITCODE
        $runOutput | Out-File (Join-Path $resultDir ($testName+'.log')) -Encoding utf8
        if ($runOutput -match '^\s*FAIL:') { $redCount++; Write-Output "RED: $testName" }
        elseif ($runExit -ne 0) { Write-Output "ERROR: unexpected simulation crash $testName"; exit 2 }
        else { Write-Output "NOT REPRODUCED: $testName" }
    }
    Write-Output "Known-failure diagnostics red=$redCount/$($tests.Count)"
    if ($redCount) { exit 1 }
} finally { Pop-Location }
