param([Parameter(Mandatory=$true)][string]$ProjectDir,
      [Parameter(Mandatory=$true)][string]$SourceCommit)
$ErrorActionPreference='Stop'
$html=Get-Content -Raw -LiteralPath (Join-Path $ProjectDir 'impl/pnr/Gowin2026_tr_content.html')
$pnr=Get-Content -Raw -LiteralPath (Join-Path $ProjectDir 'impl/pnr/Gowin2026.rpt.txt')
function Cells([string]$row) {
    @([regex]::Matches($row,'(?s)<t[dh][^>]*>(.*?)</t[dh]>') | ForEach-Object {
        [System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>',' ')).Trim()
    })
}
$rows=@([regex]::Matches($html,'(?s)<tr[^>]*>.*?</tr>') | ForEach-Object { ,(Cells $_.Value) })
$setupRow=@($rows | Where-Object { $_[0] -eq 'Numbers of Setup Violated Endpoints' })
$holdRow=@($rows | Where-Object { $_[0] -eq 'Numbers of Hold Violated Endpoints' })
if($setupRow.Count -ne 1 -or $holdRow.Count -ne 1){throw 'Missing STA endpoint summaries'}
$result=[ordered]@{Source=$SourceCommit; PhysicalSystemClockMHz=50; RequiredHoldNs=0.05; SetupViolations=[int]$setupRow[0][1]; HoldViolations=[int]$holdRow[0][1]}
foreach($check in @('Setup','Hold','Recovery','Removal')) {
    $section=[regex]::Match($html,'(?s)<h3><a name="'+$check+'_Slack_Table".*?</table>')
    if(!$section.Success){throw "Missing $check section"}
    $slacks=@([regex]::Matches($section.Value,'(?s)<tr[^>]*>.*?</tr>') | ForEach-Object {
        $cells=Cells $_.Value
        if($cells.Count -gt 1 -and $cells[0] -match '^\d+$'){[double]$cells[1]}
    })
    if(!$slacks.Count){throw "No $check paths analyzed"}
    $result[$check+'Slack']=($slacks | Measure-Object -Minimum).Minimum
}
foreach($clock in @('clk_sys','pixel_clk','serial_clk')) {
    $clockRows=@($rows | Where-Object { $_.Count -ge 4 -and $_[1] -eq $clock -and $_[3] -match 'MHz' })
    if($clockRows.Count -ne 1){throw "Missing Fmax row $clock"}
    $result[$clock+'Fmax']=[double]([regex]::Match($clockRows[0][3],'[\d.]+').Value)
}
foreach($resource in @('Logic','CLS','Register','BSRAM','DSP')) {
    $match=[regex]::Match($pnr,'(?m)^\s*'+$resource+'\s*\|\s*(\d+)/')
    if(!$match.Success){throw "Missing resource $resource"}
    $result[$resource]=[int]$match.Groups[1].Value
}
$result['TimingPass']=($result.SetupViolations -eq 0 -and $result.HoldViolations -eq 0 -and
    $result.SetupSlack -ge 0 -and $result.HoldSlack -ge 0 -and
    $result.RecoverySlack -ge 0 -and $result.RemovalSlack -ge 0 -and
    $result.clk_sysFmax -ge 50 -and $result.pixel_clkFmax -ge 25 -and $result.serial_clkFmax -ge 125)
$constraint = Get-Content -Raw -LiteralPath (Join-Path $ProjectDir 'constr/top.sdc')
$budget = [regex]::Match($constraint, '(?m)^set_max_delay -from \[get_clocks \{clk_sys\}\] -to \[get_clocks \{clk_sys\}\] ([\d.]+)')
if (!$budget.Success) { throw 'Missing native sys timing budget' }
$result['NativeBudgetNs']=[double]$budget.Groups[1].Value
$result['HoldMargin50psGate']=($result.HoldSlack -ge 0.05)
$result['Accepted']=($result.TimingPass -and $result.HoldMargin50psGate)
$result | ConvertTo-Json
if(!$result.Accepted){exit 1}
exit 0
