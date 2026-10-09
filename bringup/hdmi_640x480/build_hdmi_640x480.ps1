param(
    [string]$GwSh = 'D:\Gowin\Software\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe',
    [ValidateSet('640x480', 'H4')][string]$Mode = '640x480'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $GwSh)) { throw "gw_sh.exe not found: $GwSh" }
$projectDir = $PSScriptRoot
$mappedDrive = $null
try {
    if ($projectDir -match '[^\x00-\x7F]') {
        foreach ($letter in @('X','Y','Z','W','V')) {
            if (-not (Test-Path "$letter`:")) { $mappedDrive = "$letter`:"; break }
        }
        if (-not $mappedDrive) { throw 'No free drive letter for ASCII Gowin project path.' }
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        & subst $mappedDrive $repoRoot
        if ($LASTEXITCODE -ne 0) { throw 'subst failed.' }
        $projectDir = "$mappedDrive\bringup\hdmi_640x480"
    }
    $buildDir = Join-Path $projectDir 'build'
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    $tcl = Join-Path $buildDir 'build.tcl'
    $log = Join-Path $buildDir 'build.log'
    $err = Join-Path $buildDir 'build.stderr.log'
    $projectName = if ($Mode -eq 'H4') { 'hdmi_h4' } else { 'hdmi_640x480' }
    $topModule = if ($Mode -eq 'H4') { 'hdmi_h4' } else { 'hdmi_top' }
    $commands = @("open_project $projectName.gprj", "set_option -top_module $topModule")
    $commands += @('run all', 'exit')
    $commands | Set-Content -LiteralPath $tcl -Encoding ASCII
    $started = Get-Date
    $proc = Start-Process -FilePath $GwSh -ArgumentList @('build/build.tcl') -WorkingDirectory $projectDir `
        -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput $log -RedirectStandardError $err
    if ($proc.ExitCode -ne 0) { throw "Gowin exit code $($proc.ExitCode); see $log and $err" }
    $fs = Get-ChildItem -LiteralPath $projectDir -Recurse -Filter "$projectName.fs" -File |
        Where-Object { $_.LastWriteTime -ge $started } | Select-Object -First 1
    if (-not $fs) { throw "No fresh bitstream; see $log and $err" }
    Write-Host "PASS bitstream $($fs.FullName)"
} finally {
    if ($mappedDrive) { & subst $mappedDrive /D }
}
