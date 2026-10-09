# Exercise the runner's actual process-selection block with isolated process
# records. Mock termination so the RED test cannot kill real user simulators.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runner = Get-Content (Join-Path $root 'sim/tb_all.ps1') -Raw -Encoding UTF8
$vvpFile = 'C:\task\build\target.vvp'
$stamp = [datetime]'2026-10-01T10:00:00'
$script:killed = @()
$script:records = @(
    [pscustomobject]@{Id=101; ProcessId=101; CommandLine='vvp.exe "C:\task\build\target.vvp"'; CreationDate=$stamp.AddSeconds(1)},
    [pscustomobject]@{Id=202; ProcessId=202; CommandLine='vvp.exe "C:\other\build\target.vvp"'; CreationDate=$stamp.AddSeconds(1)},
    [pscustomobject]@{Id=303; ProcessId=303; CommandLine='vvp.exe "C:\task\build\target.vvp"'; CreationDate=$stamp.AddSeconds(-1)},
    [pscustomobject]@{Id=404; ProcessId=404; CommandLine='vvp.exe "C:\task\build\target.vvp.extra"'; CreationDate=$stamp.AddSeconds(1)}
)
function Get-Process { param($Name, $ErrorAction) $script:records }
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) $script:records }
function Stop-Process {
    param([Parameter(ValueFromPipeline=$true)]$InputObject, [int]$Id, [switch]$Force)
    process { if ($Id) { $script:killed += $Id } else { $script:killed += $InputObject.Id } }
}
$match = [regex]::Match($runner, '(?s)# BEGIN SCOPED VVP CLEANUP(.*?)# END SCOPED VVP CLEANUP')
if ($match.Success) { $block = $match.Groups[1].Value }
else { $block = [regex]::Match($runner, '(?m)^\s*Get-Process vvp[^\r\n]+').Value }
if (-not $block) { throw 'No timeout cleanup block found' }
Invoke-Expression $block
Write-Output ('Terminated simulated PIDs: ' + ($script:killed -join ','))
if (($script:killed -join ',') -ne '101') {
    Write-Output 'FAIL: timeout must stop only the current image started by this run'
    exit 1
}
Write-Output 'PASS: unrelated, older and prefix-matching simulator processes survive'
exit 0
