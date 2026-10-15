param([Parameter(Mandatory=$true)][string]$Revision)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=(git -C $repoRoot rev-parse "$Revision^{commit}").Trim()
$head=(git -C $repoRoot rev-parse HEAD).Trim()
if($head -ne $source){throw 'Requested source is not the working HEAD'}
$changed=@(git -C $repoRoot diff --name-only 7e5a4e1 $source -- rtl ip constr Gowin2026.gprj)
if($changed.Count -ne 1 -or $changed[0] -ne 'rtl/w3b/tdm_render_mixer.v'){throw 'Candidate must change only tdm_render_mixer production module'}
git -C $repoRoot diff --quiet -- rtl ip constr Gowin2026.gprj
if($LASTEXITCODE -ne 0){throw 'Uncommitted production changes'}
$buildDir=Join-Path $repoRoot 'build/bg_timing_mix01_pnr'
if(Test-Path -LiteralPath $buildDir){throw 'Fresh build directory required'}
New-Item -ItemType Directory -Path $buildDir | Out-Null
$paths=@(Import-Csv (Join-Path $repoRoot 'evidence/bg_timing_env01_20261015/product_inputs.csv') | ForEach-Object Path)
if($paths.Count -ne 76){throw 'Unexpected baseline manifest'}
$manifest=@(foreach($relative in $paths){
 $src=Join-Path $repoRoot $relative
 $dst=Join-Path $buildDir $relative
 New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
 Copy-Item -LiteralPath $src -Destination $dst
 $srcHash=(Get-FileHash -LiteralPath $src).Hash
 $dstHash=(Get-FileHash -LiteralPath $dst).Hash
 if($srcHash -ne $dstHash){throw ('Frozen input mismatch: '+$relative)}
 [pscustomobject]@{Path=$relative;SourceSHA256=$srcHash;BuildSHA256=$dstHash}
})
$manifest | Export-Csv (Join-Path $PSScriptRoot 'product_inputs.csv') -NoTypeInformation -Encoding utf8
$old=Import-Csv (Join-Path $repoRoot 'evidence/bg_timing_env01_20261015/product_inputs.csv')
$different=@(foreach($r in $manifest){$o=$old | Where-Object Path -eq $r.Path;if($o.SourceSHA256 -ne $r.SourceSHA256){$r.Path}})
if($different.Count -ne 1 -or $different[0] -ne 'rtl/w3b/tdm_render_mixer.v'){throw 'Frozen inputs differ beyond the single intended module'}
[ordered]@{Source=$source;Baseline='7e5a4e112bea1a761eaf98261213d0824889192f';BuildDirectory=$buildDir;Inputs=76;ChangedInputs=$different;PreparedAt=(Get-Date).ToString('o')} |
 ConvertTo-Json | Out-File (Join-Path $PSScriptRoot 'build_source.json') -Encoding utf8
Write-Output ('Frozen '+$source+'; exactly one production input differs from envelope candidate')
