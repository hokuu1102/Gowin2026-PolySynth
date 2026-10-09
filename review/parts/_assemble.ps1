$ErrorActionPreference = 'Stop'
$root     = 'C:\Users\hokuu\Desktop\FPGA\FPGA2026'
$partsDir = Join-Path $root 'review\parts'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function ReadU8([string]$p) { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }

$spec = ReadU8 (Join-Path $partsDir '_assemble_spec.json') | ConvertFrom-Json
$fld  = ReadU8 (Join-Path $partsDir '_fields.json') | ConvertFrom-Json
$outFile = Join-Path $root $spec.out_file

$canon = @($fld.fields_canon)
$aliasKeys = @($fld.field_aliases.PSObject.Properties.Name)
$contKeys  = @($fld.continuation.PSObject.Properties.Name)

function Get-Base([string]$bold) {
    $b = $bold
    while ($b -match '^(.*?)（[^（）]*）$') { $b = $Matches[1] }
    if ($aliasKeys -contains $b) { $b = $fld.field_aliases.$b }
    return $b
}

# ---------------- 1. parse ----------------
$entries = @{}
$parseOrder = New-Object System.Collections.ArrayList
$problems = New-Object System.Collections.ArrayList

foreach ($f in (Get-ChildItem $partsDir -Filter '*.part.md' | Sort-Object Name)) {
    $txt = ReadU8 $f.FullName
    $rx = '(?s)@@@PRIO=(P\d)\|SRC=([^|\r\n]+)\|ORIG=([^|\r\n]+)\|MOD=([^\r\n]+)\r?\n(.*?)@@@END'
    foreach ($m in [regex]::Matches($txt, $rx)) {
        $prio = $m.Groups[1].Value.Trim()
        $src  = $m.Groups[2].Value.Trim()
        $orig = $m.Groups[3].Value.Trim()
        $mod  = $m.Groups[4].Value.Trim()
        $body = $m.Groups[5].Value
        $lines = $body -split "\r?\n"
        $title = $lines[0].Trim()
        if ($title.StartsWith('###')) { $title = $title.Substring(3).Trim() }
        $cur = $null
        $inFence = $false
        $f = @{}
        foreach ($c in $canon) { $f[$c] = '' }
        $cont = ''
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($ln -match '^\s*```') { $inFence = -not $inFence }
            if (-not $inFence -and $ln -match '^-\s*\*\*(.+?)\*\*(.*)$') {
                $bold = $Matches[1]; $rest = $Matches[2]
                $base = Get-Base $bold
                if ($canon -contains $base) {
                    $r = $rest
                    while ($r -match '^\s*（[^（）]*）(.*)$') { $r = $Matches[1] }
                    if ($r -match '^\s*[：:]\s*(.*)$') { $r = $Matches[1] }
                    $cur = $base
                    $f[$cur] = $r.Trim()
                    continue
                }
                if ($contKeys -contains $base) {
                    $r = $rest
                    while ($r -match '^\s*（[^（）]*）(.*)$') { $r = $Matches[1] }
                    if ($r -match '^\s*[：:]\s*(.*)$') { $r = $Matches[1] }
                    $cur = '@cont'
                    $cont = $r.Trim()
                    continue
                }
            }
            if ($cur -eq $null) { continue }
            if ($cur -eq '@cont') { $cont = $cont + "`n" + $ln }
            else { $f[$cur] = $f[$cur] + "`n" + $ln }
        }
        if ($cont.Trim().Length -gt 0) {
            $lbl = $fld.continuation.$($contKeys[0])
            $f['改法'] = $f['改法'] + "`n  " + $fld.merge_marker_prefix + "（" + $lbl + "）" + $cont.Trim()
        }
        foreach ($c in $canon) {
            $v = $f[$c]
            while ($v -match "`n\s*`n\s*$") { $v = $v -replace "`n\s*`n\s*$", '' }
            $f[$c] = $v.TrimEnd()
            if ($f[$c] -match '^[ \t]') { $f[$c] = $f[$c] -replace '^[ \t]+', '' }
        }
        foreach ($c in $canon) { if ($f[$c].Length -eq 0) { [void]$problems.Add("EMPTY FIELD [$c] in $src|$orig") } }
        $key = "$src|$orig"
        if ($entries.ContainsKey($key)) { [void]$problems.Add("DUPLICATE KEY $key") }
        $entries[$key] = [pscustomobject]@{ prio=$prio; src=$src; orig=$orig; mod=$mod; title=$title; f=$f }
        [void]$parseOrder.Add($key)
    }
}

# ---------------- 2. merges ----------------
$secOf = @{}
$mergeReport = New-Object System.Collections.ArrayList
foreach ($g in $spec.merges) {
    $p = $g.p
    if (-not $entries.ContainsKey($p)) { [void]$problems.Add("MERGE PRIMARY MISSING $p"); continue }
    foreach ($s in $g.s) {
        if (-not $entries.ContainsKey($s)) { [void]$problems.Add("MERGE SECONDARY MISSING $s"); continue }
        if ($secOf.ContainsKey($s)) { [void]$problems.Add("SECONDARY TWICE $s"); continue }
        $secOf[$s] = $p
    }
    [void]$mergeReport.Add(("{0}  <==  {1}" -f $p, ($g.s -join ' + ')))
}

foreach ($s in @($secOf.Keys)) {
    $p = $secOf[$s]
    $se = $entries[$s]; $pe = $entries[$p]
    $tag = $fld.merge_marker_prefix + "【" + $se.src + "【" + $se.orig + "】】" + $fld.merge_marker_suffix
    foreach ($c in $canon) {
        $sv = $se.f[$c]
        if ($c -eq '来源') { continue }
        if ($sv.Length -gt 0 -and $sv -ne '（原文未给出）') {
            $pe.f[$c] = $pe.f[$c] + "`n  " + $tag + "：" + $sv
        }
    }
    $pe.f['来源'] = $pe.f['来源'] + " ＋ " + $se.src + "【" + $se.orig + "】"
    $pe.mod = (($pe.mod + ',' + $se.mod) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ','
}

$alive = @($entries.Keys | Where-Object { -not $secOf.ContainsKey($_) })
$mergedCount = $secOf.Count

# ---------------- 3. score & order ----------------
function Get-Score($e) {
    $s = 0
    $hay = $e.title + ' ' + $e.f['为什么是问题'] + ' ' + $e.f['改法']
    foreach ($p in $spec.score_pos) { if ($hay.Contains($p[0])) { $s += [int]$p[1] } }
    foreach ($p in $spec.score_neg) { if ($hay.Contains($p[0])) { $s -= [int]$p[1] } }
    return $s
}
$score = @{}
foreach ($k in $alive) { $score[$k] = Get-Score $entries[$k] }

function Sort-ByScore($keys) {
    return @($keys | Sort-Object -Property @{Expression={ -1 * $script:score[$_] }}, @{Expression={ $script:entries[$_].src }}, @{Expression={ $script:entries[$_].orig }})
}

$ordered = New-Object System.Collections.ArrayList
$p0keys = @($alive | Where-Object { $entries[$_].prio -eq 'P0' })
$p0set = @{}
foreach ($k in $p0keys) { $p0set[$k] = $true }
foreach ($k in $spec.p0_order) {
    if ($p0set.ContainsKey($k)) { [void]$ordered.Add($k); $p0set.Remove($k) }
    else { [void]$problems.Add("P0 ORDER KEY NOT A P0 PRIMARY: $k") }
}
foreach ($k in (Sort-ByScore @($p0set.Keys))) { [void]$ordered.Add($k) }
foreach ($p in @('P1','P2','P3')) {
    $ks = @($alive | Where-Object { $entries[$_].prio -eq $p })
    foreach ($k in (Sort-ByScore $ks)) { [void]$ordered.Add($k) }
}
if ($ordered.Count -ne $alive.Count) { [void]$problems.Add("ORDER COUNT MISMATCH $($ordered.Count) vs $($alive.Count)") }

# ---------------- 4. number ----------------
$num = @{}
$seq = @{ P0=0; P1=0; P2=0; P3=0 }
foreach ($k in $ordered) {
    $p = $entries[$k].prio
    $seq[$p] = $seq[$p] + 1
    $num[$k] = ("[{0}-{1:d2}]" -f $p, $seq[$p])
}

# ---------------- 5. render ----------------
$L = New-Object System.Collections.ArrayList
function Add-Line([string]$s) { [void]$L.Add($s) }

foreach ($h in $spec.doc_header) { Add-Line $h }
$ledger = $spec.ledger.Replace('{MERGED}', "$mergedCount").Replace('{TOTAL}', "$($alive.Count)")
Add-Line $ledger
Add-Line ''
Add-Line $spec.sec0
Add-Line ''
$top15 = @($ordered | Select-Object -First 15)
foreach ($k in $top15) {
    $e = $entries[$k]
    $loc = ($e.f['位置'] -split "`n")[0].Trim()
    Add-Line ("- **{0} {1}** —— 位置：{2}" -f $num[$k], $e.title, $loc)
}
Add-Line ''
Add-Line '---'
Add-Line ''

$secMap = @{ P0=$spec.sec1; P1=$spec.sec2; P2=$spec.sec3; P3=$spec.sec4 }
foreach ($p in @('P0','P1','P2','P3')) {
    Add-Line $secMap[$p]
    Add-Line ''
    foreach ($k in ($ordered | Where-Object { $entries[$_].prio -eq $p })) {
        $e = $entries[$k]
        Add-Line ("### {0} {1}" -f $num[$k], $e.title)
        foreach ($c in $canon) { Add-Line ("- **{0}**：{1}" -f $c, $e.f[$c]) }
        Add-Line ''
    }
    Add-Line '---'
    Add-Line ''
}

Add-Line $spec.sec5
Add-Line ''
$sched = @{}
foreach ($g in $spec.roadmap) {
    Add-Line ("### {0}" -f $g.title)
    Add-Line ''
    $seen = @{}
    foreach ($k0 in $g.keys) {
        $k = $k0
        if ($secOf.ContainsKey($k)) { $k = $secOf[$k] }
        if (-not $num.ContainsKey($k)) { Add-Line ("- ⚠️（找不到条目）：{0}" -f $k0); continue }
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        if ($sched.ContainsKey($k)) { continue }
        $sched[$k] = $true
        $e = $entries[$k]
        Add-Line ("- {0} {1}" -f $num[$k], $e.title)
    }
    Add-Line ''
    Add-Line $g.gates
    Add-Line ''
}
foreach ($n in $spec.gate_note) { Add-Line $n }
Add-Line ''
Add-Line '---'
Add-Line ''

Add-Line $spec.sec6
Add-Line ''
$modMap = @{}
foreach ($k in $ordered) {
    foreach ($mm in ($entries[$k].mod -split ',')) {
        $t = $mm.Trim(); if (-not $t) { continue }
        if (-not $modMap.ContainsKey($t)) { $modMap[$t] = New-Object System.Collections.ArrayList }
        [void]$modMap[$t].Add($k)
    }
}
foreach ($mk in ($modMap.Keys | Sort-Object)) {
    $lst = @($modMap[$mk] | Sort-Object -Property @{Expression={ $ordered.IndexOf($_) }})
    Add-Line ("- ``{0}``（{1} 条）：{2}" -f $mk, $lst.Count, (($lst | ForEach-Object { $num[$_] }) -join ' · '))
}
Add-Line ''
Add-Line '---'
Add-Line ''

Add-Line $spec.sec7
Add-Line ''
foreach ($cat in $spec.categories) {
    $hit = New-Object System.Collections.ArrayList
    foreach ($k in $ordered) {
        $e = $entries[$k]
        $hay = $e.title + ' ' + $e.f['为什么是问题']
        foreach ($w in $cat.kw) { if ($hay.Contains($w)) { [void]$hit.Add($k); break } }
    }
    Add-Line ("### {0}（{1} 条）" -f $cat.name, $hit.Count)
    Add-Line ''
    if ($hit.Count -eq 0) { Add-Line '- （无）'; Add-Line '' ; continue }
    Add-Line ((($hit | ForEach-Object { "{0} {1}" -f $num[$_], $entries[$_].title }) -join "`n- " -replace '^', '- '))
    Add-Line ''
}

$text = ($L -join "`n")
[IO.File]::WriteAllText($outFile, $text, $utf8)

# ---------------- 6. report ----------------
"WROTE $outFile"
"entries_parsed   = $($entries.Count)"
"merged_away      = $mergedCount"
"alive            = $($alive.Count)"
"P0=$($seq['P0']) P1=$($seq['P1']) P2=$($seq['P2']) P3=$($seq['P3'])"
"total_in_doc     = $($seq['P0']+$seq['P1']+$seq['P2']+$seq['P3'])"
"bytes            = $((Get-Item $outFile).Length)"
"top15:"
foreach ($k in $top15) { "  {0} {1}  [{2}]" -f $num[$k], $entries[$k].title, $k }
if ($problems.Count -gt 0) { "PROBLEMS:"; $problems | ForEach-Object { "  $_" } } else { "PROBLEMS: none" }
"MERGE MAP:"; $mergeReport | ForEach-Object { "  $_" }
