# t3_rsc_delta.ps1 -- archive Gowin synthesis resources and print the delta vs a stored baseline.
#
# WHY THIS EXISTS (2026-10-03):
#   During the T3 transpose work we repeatedly needed "what did this RTL change cost?".
#   Doing it by hand is error prone, and `impl/gwsynthesis/Gowin2026_syn_rsc.xml` is
#   OVERWRITTEN by every synthesis run -- so the comparison data is easy to lose.
#
# USAGE
#   pwsh -File bringup\t3_rsc_delta.ps1 -Label S0-T3-HEAD              # store as baseline
#   pwsh -File bringup\t3_rsc_delta.ps1 -Label EA -Baseline S0-T3-HEAD # store + print delta
#
# NOTES
#   * Pure ASCII on purpose (see AGENTS.md: .ps1 must be UTF-8 BOM or pure ASCII).
#   * Read-only with respect to rtl/: it only READS impl/gwsynthesis and WRITES into
#     sim/evidence/t3-bisect-20261003/.
#   * Judgement reminder: if a variant's numbers fall back to the baseline EXACTLY,
#     the variant removed more than intended (Gowin IGNORES (* syn_keep = 1 *)) --
#     that experiment is INVALID, not a result.

param(
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$Baseline = '',
    [string]$ArchiveDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $ArchiveDir) { $ArchiveDir = Join-Path $repo 'sim\evidence\t3-bisect-20261003' }

$src = Join-Path $repo 'impl\gwsynthesis\Gowin2026_syn_rsc.xml'
if (-not (Test-Path $src)) { Write-Host "FAIL: not found: $src"; exit 1 }
New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null

# ---- parse one xml file into a flat hashtable of the numbers we care about ----
function Get-Rsc([string]$path) {
    $t = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false)))
    $h = @{}
    $m = [regex]::Match($t, '<Module name="top"[^>]*>')
    if ($m.Success) {
        foreach ($k in 'T_Register', 'T_Alu', 'T_Lut', 'T_Bsram', 'T_MULTALU27X18', 'T_MULT12X12', 'T_MULT27X36') {
            $mm = [regex]::Match($m.Value, "$k=`"(\d+)")
            if ($mm.Success) { $h[$k] = [int]$mm.Groups[1].Value }
        }
    }
    $nm = [regex]::Match($t, '<SubModule name="g_sound\.u_note_manager"[^>]*>')
    if ($nm.Success) {
        foreach ($k in 'Register', 'Alu', 'Lut', 'Bsram') {
            $mm = [regex]::Match($nm.Value, "\s$k=`"(\d+)")
            if ($mm.Success) { $h["nm_$k"] = [int]$mm.Groups[1].Value }
        }
    }
    return $h
}

$cur = Get-Rsc $src
$dst = Join-Path $ArchiveDir ("rsc-$Label.xml")
Copy-Item $src $dst -Force
Write-Host ("archived -> {0}" -f $dst)

$keys = 'T_Register', 'T_Alu', 'T_Lut', 'T_Bsram', 'T_MULTALU27X18', 'T_MULT12X12', 'T_MULT27X36', 'nm_Register', 'nm_Alu', 'nm_Lut', 'nm_Bsram'

if ($Baseline) {
    $bp = Join-Path $ArchiveDir ("rsc-$Baseline.xml")
    if (-not (Test-Path $bp)) { Write-Host "FAIL: baseline not archived: $bp"; exit 1 }
    $base = Get-Rsc $bp
    Write-Host ""
    Write-Host ("{0,-16} {1,10} {2,10} {3,10}" -f 'key', $Baseline, $Label, 'delta')
    Write-Host ("-" * 50)
    foreach ($k in $keys) {
        $b = if ($base.ContainsKey($k)) { $base[$k] } else { 0 }
        $c = if ($cur.ContainsKey($k)) { $cur[$k] } else { 0 }
        $d = $c - $b
        $mark = ''
        if ($d -eq 0 -and $k -like 'T_*') { $mark = '  <== UNCHANGED' }
        Write-Host ("{0,-16} {1,10} {2,10} {3,10}{4}" -f $k, $b, $c, $d, $mark)
    }
    $same = $true
    foreach ($k in 'T_Register', 'T_Lut', 'T_MULT27X36') {
        if ($cur[$k] -ne $base[$k]) { $same = $false }
    }
    Write-Host ""
    if ($same) {
        Write-Host "WARNING: T_Register/T_Lut/T_MULT27X36 are IDENTICAL to the baseline."
        Write-Host "         That means this variant removed MORE than intended (Gowin ignores"
        Write-Host "         (* syn_keep = 1 *)) -- treat the experiment as INVALID, not as a result."
    }
} else {
    Write-Host ""
    Write-Host ("baseline stored as '{0}'. keys:" -f $Label)
    foreach ($k in $keys) { if ($cur.ContainsKey($k)) { Write-Host ("  {0,-16} {1}" -f $k, $cur[$k]) } }
}
