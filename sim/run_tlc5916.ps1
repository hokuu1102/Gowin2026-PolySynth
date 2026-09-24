param(
    [switch]$OpenWave
)

$ErrorActionPreference = 'Stop'

function Resolve-Tool {
    param(
        [string]$CommandName,
        [string]$FallbackPath
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if (Test-Path -LiteralPath $FallbackPath) {
        return $FallbackPath
    }

    throw "Cannot find $CommandName. Checked PATH and $FallbackPath."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot 'build\sim\tlc5916'
$vvpFile = Join-Path $buildDir 'tlc5916_tb.vvp'
$vcdFile = Join-Path $buildDir 'tlc5916_tb.vcd'

$iverilog = Resolve-Tool 'iverilog' 'D:\iverilog\bin\iverilog.exe'
$vvp = Resolve-Tool 'vvp' 'D:\iverilog\bin\vvp.exe'

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
    & $iverilog `
        -g2012 `
        -Wall `
        -s tb_tlc5916_driver `
        -o $vvpFile `
        'rtl\drivers\tlc5916_driver.sv' `
        'tb\drivers\tb_tlc5916_driver.sv'

    if ($LASTEXITCODE -ne 0) {
        throw "Icarus compilation failed with exit code $LASTEXITCODE."
    }

    & $vvp $vvpFile
    if ($LASTEXITCODE -ne 0) {
        throw "TLC5916 simulation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

if ($OpenWave) {
    $gtkwave = Resolve-Tool 'gtkwave' 'D:\iverilog\gtkwave\bin\gtkwave.exe'
    Start-Process -FilePath $gtkwave -ArgumentList $vcdFile
}
