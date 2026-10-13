param([string]$Port='COM14', [int]$Seconds=4)
$ErrorActionPreference='Stop'
$repoDir=Split-Path -Parent $PSScriptRoot
$resultDir=Join-Path $repoDir 'evidence/fault_diag_20261012'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
$serial=New-Object System.IO.Ports.SerialPort $Port,500000,None,8,One
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$serial.ReadTimeout=200
$raw=''
try {
    $serial.Open()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $Seconds) {
        try { $raw += $serial.ReadLine()+"`n" }
        catch [TimeoutException] { }
    }
} finally { if($serial.IsOpen) { $serial.Close() }; $serial.Dispose() }
$raw | Out-File (Join-Path $resultDir 'live_uart.log') -Encoding utf8
Write-Output $raw
$frames=[regex]::Matches($raw,'!F[12] ([0-9A-F]{3}) ([0-9A-F]{3}) ([0-9A-F]{3}) ([0-9A-F]{8})')
if($frames.Count -eq 0) { throw 'No valid diagnostic frames: verify SRAM image, baud and COM port; not a zero-fault verdict' }
$frame=$frames[$frames.Count-1]
$names=@('ADC0','ADC1','ADC2','MIXER_DEADLINE','EVENT_FIFO','EVENT_LOST','SCORE_ARBITER','LOOPER','EVENT_MERGE','TX_FIFO')
foreach($column in 1..3) {
    $mask=[Convert]::ToInt32($frame.Groups[$column].Value,16)
    $sources=@(for($bit=0;$bit -lt $names.Count;$bit++) { if($mask -band (1 -shl $bit)) { $names[$bit] } })
    $label=@('','current','sticky','first')[$column]
    Write-Output ("$label=$($frame.Groups[$column].Value) [$($sources -join ',')]")
}
$tick=[Convert]::ToUInt32($frame.Groups[4].Value,16)
Write-Output ('first_fault_ms='+($tick/50000.0))
$stickyMask=[Convert]::ToInt32($frame.Groups[2].Value,16)
if($stickyMask -ne 0) {
    Write-Output 'FAIL: actual hardware latched a fault; source mask above is the diagnosis input'
    exit 1
}
Write-Output 'PASS: no fault observed in this capture window (not a complete board acceptance)'
