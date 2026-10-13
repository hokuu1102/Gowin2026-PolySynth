$ErrorActionPreference = 'Continue'
$sources = @(Get-ChildItem rtl,tb/models,tb/checkers,bringup/dac_tone -Recurse -File -Include *.v,*.sv | Where-Object { $_.Name -notlike 'tb_*' -and $_.FullName -notmatch 'proj_fmt' } | ForEach-Object FullName)
$testFiles = @(Get-ChildItem tb -Recurse -File -Filter tb_*.sv)
New-Item -ItemType Directory -Force audit_review/compile_all | Out-Null
$failed = @()
foreach ($testFile in $testFiles) {
    $testName = $testFile.BaseName
    $defs = @()
    if ($testName -notlike '*_prom*') { $defs += '-DWAVETABLE_BEHAVIORAL' }
    $result = & D:/iverilog/bin/iverilog.exe -g2012 -Wall @defs -s $testName -o audit_review/compile_all/current.vvp @sources $testFile.FullName 2>&1
    $compileExit = $LASTEXITCODE
    $result | Out-File ("audit_review/compile_all/$testName.log") -Encoding utf8
    if ($compileExit -ne 0) { $failed += $testName; Write-Output "FAIL: $testName" }
}
Write-Output "COMPILE total=$($testFiles.Count) passed=$($testFiles.Count-$failed.Count) failed=$($failed.Count)"
if ($failed.Count) { exit 1 }
