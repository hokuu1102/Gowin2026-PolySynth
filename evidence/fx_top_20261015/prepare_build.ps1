param(
 [Parameter(Mandatory=$true)][string]$Revision,
 [Parameter(Mandatory=$true)][ValidatePattern('^fx_top_[A-Za-z0-9_]+$')][string]$BuildName,
 [Parameter(Mandatory=$true)][ValidateSet('bypass','all')][string]$FxConfig
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=(git -C $repoRoot rev-parse "$Revision^{commit}").Trim()
if($LASTEXITCODE -ne 0){throw 'Invalid source commit'}
git -C $repoRoot diff --quiet $source -- rtl tb ip constr Gowin2026.gprj sim/tb_all.ps1 tools/build_target_pnr.tcl
if($LASTEXITCODE -ne 0){throw 'Working source differs from frozen revision'}
$buildDir=Join-Path $repoRoot ('build/'+$BuildName)
if(Test-Path -LiteralPath $buildDir){throw 'Fresh build directory required; old results are never reused'}
$base=Import-Csv (Join-Path $repoRoot 'evidence/bj_final_20261015/product_inputs.csv')
$paths=@(@($base | ForEach-Object Path)+@('rtl/w3c/fx_dist.v','rtl/w3c/fx_delay.v','rtl/w3c/fx_trem.v','rtl/w3c/fx_chain.v') | Sort-Object -Unique)
if($paths.Count -ne 80){throw 'Unexpected frozen input set'}
$gprj=[IO.File]::ReadAllText((Join-Path $repoRoot 'Gowin2026.gprj'))
$registered=@([regex]::Matches($gprj,'<File\s+path="([^"]+)"[^>]*enable="1"') | ForEach-Object {$_.Groups[1].Value} | Sort-Object -Unique)
if(@($registered | Where-Object {$_ -notin $paths}).Count){throw 'Enabled project input missing from manifest'}
New-Item -ItemType Directory -Path $buildDir | Out-Null
$manifest=@(foreach($relative in $paths){
 $src=Join-Path $repoRoot $relative; $dst=Join-Path $buildDir $relative
 New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
 Copy-Item -LiteralPath $src -Destination $dst
 $a=(Get-FileHash -LiteralPath $src).Hash; $b=(Get-FileHash -LiteralPath $dst).Hash
 if($a -ne $b){throw ('Copy mismatch: '+$relative)}
 [pscustomobject]@{Path=$relative;SourceSHA256=$a;BuildSHA256=$b}
})
$manifest | Export-Csv -LiteralPath (Join-Path $PSScriptRoot ($FxConfig+'_inputs.csv')) -NoTypeInformation -Encoding UTF8
$override=if($FxConfig -eq 'all'){@{FX_EN_MASK=7;FX_TREM_DEPTH=128}}else{@{FX_EN_MASK=0;FX_TREM_DEPTH=0}}
[ordered]@{Source=$source;FxConfig=$FxConfig;BuildName=$BuildName;BuildDirectory=$buildDir;Inputs=80;
 Overrides=$override;Sealed=$false;PreparedAtUTC=[DateTime]::UtcNow.ToString('o')} |
 ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $PSScriptRoot ($FxConfig+'_source.json')) -Encoding UTF8
Write-Output ('Prepared unsealed '+$FxConfig+' from '+$source+' with 80 exact source inputs')
