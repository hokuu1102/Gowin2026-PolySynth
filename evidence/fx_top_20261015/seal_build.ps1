param([Parameter(Mandatory=$true)][ValidateSet('bypass','all')][string]$FxConfig)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$metaPath=Join-Path $PSScriptRoot ($FxConfig+'_source.json')
$meta=Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json
if($meta.FxConfig -ne $FxConfig -or $meta.Inputs -ne 80 -or $meta.BuildName -notmatch '^fx_top_[A-Za-z0-9_]+$'){throw 'Invalid prepared build metadata'}
$buildDir=Join-Path $repoRoot ('build/'+$meta.BuildName)
if($buildDir -ne $meta.BuildDirectory){throw 'Build directory mismatch'}
git -C $repoRoot diff --quiet $meta.Source -- rtl tb ip constr Gowin2026.gprj sim/tb_all.ps1 tools/build_target_pnr.tcl
if($LASTEXITCODE -ne 0){throw 'Frozen source changed'}
$manifest=Import-Csv (Join-Path $PSScriptRoot ($FxConfig+'_inputs.csv'))
if($manifest.Count -ne 80){throw 'Manifest incomplete'}
$utf8=New-Object Text.UTF8Encoding($false,$true)
foreach($row in $manifest){
 $src=Join-Path $repoRoot $row.Path
 if((Get-FileHash -LiteralPath $src).Hash -ne $row.SourceSHA256){throw ('Source hash changed: '+$row.Path)}
 $expectedHash=$row.SourceSHA256
 if($FxConfig -eq 'all' -and $row.Path -eq 'rtl/top.v'){
  $text=$utf8.GetString([IO.File]::ReadAllBytes($src))
  foreach($pair in @(
   @('FX_EN_MASK          = 8''d0','FX_EN_MASK          = 8''d7'),
   @('FX_TREM_DEPTH       = 8''d0','FX_TREM_DEPTH       = 8''d128')
  )){
   if([regex]::Matches($text,[regex]::Escape($pair[0])).Count -ne 1){throw 'Profile default anchor is not unique'}
   $text=$text.Replace($pair[0],$pair[1])
  }
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$expectedHash=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text))).Replace('-','')}finally{$sha.Dispose()}
 }
 $actual=(Get-FileHash -LiteralPath (Join-Path $buildDir $row.Path)).Hash
 if($actual -ne $expectedHash){throw ('Unexpected profile input bytes: '+$row.Path)}
 $row.BuildSHA256=$actual
}
$manifest | Export-Csv -LiteralPath (Join-Path $PSScriptRoot ($FxConfig+'_inputs.csv')) -NoTypeInformation -Encoding UTF8
$meta.Sealed=$true
$meta | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $metaPath -Encoding UTF8
Write-Output ('Sealed '+$FxConfig+': 80 inputs; only declared isolated-copy defaults may differ')
