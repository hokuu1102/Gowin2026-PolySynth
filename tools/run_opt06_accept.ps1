param([string]$EvidenceDir = 'evidence/opt06_main_20261013/tests')
$ErrorActionPreference = 'Stop'
# Frozen AF references replace outdated embedded references only; stimuli and
# numerical assertions are unchanged. Legacy transpose/rot32 benches remain.
& (Join-Path $PSScriptRoot 'run_q_adc_regression.ps1') -EvidenceDir $EvidenceDir -Tests @(
    'tb_opt04_nm_compare', 'tb_opt04_nm_compare_values',
    'tb_note_manager_sus', 'tb_note_manager_vel_ramp',
    'tb_note_manager_vel_wrap', 'tb_note_manager_write_share',
    'tb_voice_accept', 'tb_top_scope_live', 'tb_test_mode_top',
    'tb_polyphony_onset_step', 'tb_tdm_render_mixer',
    'tb_opt04_rot32_current_af', 'tb_opt04_transpose_current_af'
)
$repoDir = Split-Path -Parent $PSScriptRoot
$negativeDir = Join-Path $repoDir ($EvidenceDir + '/negative')
New-Item -ItemType Directory -Force -Path $negativeDir | Out-Null
Push-Location $repoDir
try {
    $ErrorActionPreference = 'Continue'
    $compile = & 'D:/iverilog/bin/iverilog.exe' -g2012 -s tb_opt04_nm_age_negative -o ($negativeDir + '/age_negative.vvp') rtl/w3b/note_manager.v tb/models/note_manager_af_reference.v tb/w3b/tb_opt04_nm_age_negative.sv 2>&1
    $compileExit = $LASTEXITCODE
    $compile | Out-File ($negativeDir + '/compile.log') -Encoding utf8
    if ($compileExit -ne 0) { throw 'Negative control compile failed' }
    $output = & 'D:/iverilog/bin/vvp.exe' ($negativeDir + '/age_negative.vvp') 2>&1
    $negativeExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $output | Out-File ($negativeDir + '/expected_failure.log') -Encoding utf8
    if ($negativeExit -eq 0 -or !($output -match 'split age mismatch')) {
        throw 'Negative control did not detect the deliberate mutation'
    }
    Write-Output 'PASS: negative control detected deliberately corrupted age comparison'
} finally { Pop-Location }
