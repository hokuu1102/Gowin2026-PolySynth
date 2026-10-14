param([string]$EvidenceDir='experiment/reproduce')
$ErrorActionPreference='Stop'
# Identical stimuli/public/other internal checks, adapted private target oracle.
& (Join-Path $PSScriptRoot 'run_q_adc_regression.ps1') -EvidenceDir $EvidenceDir -Tests @(
 'tb_opt04_nm_compare','tb_opt04_nm_compare_values','tb_note_manager_sus',
 'tb_note_manager_vel_ramp','tb_note_manager_vel_wrap','tb_opt08_write_share_reused',
 'tb_voice_accept','tb_top_scope_live','tb_test_mode_top','tb_polyphony_onset_step',
 'tb_tdm_render_mixer','tb_opt04_rot32_current_af','tb_opt04_transpose_current_af'
)
$repo=Split-Path -Parent $PSScriptRoot
$dir=Join-Path $repo $EvidenceDir
Push-Location $repo
try {
 $ErrorActionPreference='Continue'
 foreach($negative in @(0,1)) {
  $defs=@('-DOPT08_CACHE')
  if($negative){$defs+='-DOPT08_NEGATIVE'}
  $name=if($negative){'negative'}else{'cache'}
  $compile=& 'D:/iverilog/bin/iverilog.exe' -g2012 @defs -s tb_opt08_target_cache -o ($dir+'/'+$name+'.vvp') rtl/w3b/note_manager.v tb/models/note_manager_ao_reference.v tb/w3b/tb_opt08_target_cache.sv 2>&1
  $rc=$LASTEXITCODE
  $compile | Out-File ($dir+'/'+$name+'.compile.log') -Encoding utf8
  if($rc -ne 0){throw "Compile failed: $name"}
  $output=& 'D:/iverilog/bin/vvp.exe' ($dir+'/'+$name+'.vvp') 2>&1
  $rc=$LASTEXITCODE
  $output | Out-File ($dir+'/'+$name+'.log') -Encoding utf8
  if($negative){if($rc -eq 0 -or !($output -match 'AO public output mismatch')){throw 'Negative guard failed'}}
  elseif($rc -ne 0 -or !($output -match 'PASS: AO/cache differential')){throw 'Cache stress failed'}
 }
 Write-Output 'PASS: cache differential and expected negative failure'
} finally { Pop-Location }
exit 0
