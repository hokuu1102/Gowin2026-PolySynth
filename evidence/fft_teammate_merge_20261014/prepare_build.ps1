$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$buildDir=Join-Path $repoRoot 'build/fft_teammate_merge_pnr01'
if(Test-Path -LiteralPath $buildDir){throw 'Build directory already exists; never reuse stale reports'}
$source=(git -C $repoRoot rev-parse HEAD).Trim()
if($source -notmatch '^fa0dec8'){throw 'Wrong source revision'}
$paths=@('Gowin2026.gprj','tools/build_target_pnr.tcl')
$paths+=@(Import-Csv (Join-Path $repoRoot 'evidence/fft_color_20261014/product_inputs.csv') | ForEach-Object Path)
$projectText=Get-Content -Raw (Join-Path $repoRoot 'Gowin2026.gprj')
$paths+=@([regex]::Matches($projectText,'<File path="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$paths=@($paths | Sort-Object -Unique)
New-Item -ItemType Directory -Path $buildDir | Out-Null
$manifest=@(foreach($relative in $paths){
 $src=Join-Path $repoRoot $relative
 if(!(Test-Path -LiteralPath $src -PathType Leaf)){throw ('Missing production file: '+$relative)}
 $dst=Join-Path $buildDir $relative
 New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
 Copy-Item -LiteralPath $src -Destination $dst
 $srcHash=(Get-FileHash -LiteralPath $src).Hash
 $dstHash=(Get-FileHash -LiteralPath $dst).Hash
 if($srcHash -ne $dstHash){throw ('Frozen input mismatch: '+$relative)}
 [pscustomobject]@{Path=$relative;SourceSHA256=$srcHash;BuildSHA256=$dstHash}
})
$manifest | Export-Csv (Join-Path $PSScriptRoot 'product_inputs.csv') -NoTypeInformation -Encoding utf8
[ordered]@{Source=$source;BuildDirectory=$buildDir;Inputs=$manifest.Count;PreparedAt=(Get-Date).ToString('o');MainReplaced=$false;Pushed=$false} |
 ConvertTo-Json | Out-File (Join-Path $PSScriptRoot 'build_source.json') -Encoding utf8
Write-Output ('Frozen source '+$source+' with '+$manifest.Count+' inputs at '+$buildDir)
