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

function Invoke-Mcp3208Test {
    param(
        [string]$Top,
        [string[]]$Sources
    )

    $vvpFile = Join-Path $buildDir ($Top + '.vvp')

    & $iverilog `
        -g2012 `
        -Wall `
        -s $Top `
        -o $vvpFile `
        @Sources

    if ($LASTEXITCODE -ne 0) {
        throw "$Top compilation failed with exit code $LASTEXITCODE."
    }

    & $vvp $vvpFile
    if ($LASTEXITCODE -ne 0) {
        throw "$Top simulation failed with exit code $LASTEXITCODE."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot 'build\sim\mcp3208'

$iverilog = Resolve-Tool 'iverilog' 'D:\iverilog\bin\iverilog.exe'
$vvp = Resolve-Tool 'vvp' 'D:\iverilog\bin\vvp.exe'

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
    Invoke-Mcp3208Test `
        -Top 'tb_mcp3208_driver' `
        -Sources @(
            'rtl\drivers\mcp3208_driver.sv',
            'tb\drivers\tb_mcp3208_driver.sv'
        )

    Invoke-Mcp3208Test `
        -Top 'tb_mcp3208_scanner' `
        -Sources @(
            'rtl\drivers\mcp3208_driver.sv',
            'rtl\drivers\mcp3208_scanner.sv',
            'tb\drivers\tb_mcp3208_scanner.sv'
        )
}
finally {
    Pop-Location
}

if ($OpenWave) {
    $gtkwave = Resolve-Tool 'gtkwave' 'D:\iverilog\gtkwave\bin\gtkwave.exe'
    Start-Process -FilePath $gtkwave -ArgumentList (Join-Path $buildDir 'mcp3208_driver_tb.vcd')
    Start-Process -FilePath $gtkwave -ArgumentList (Join-Path $buildDir 'mcp3208_scanner_tb.vcd')
}
