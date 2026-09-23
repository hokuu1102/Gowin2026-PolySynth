# mutation_result_watchdog.ps1 -- independent verdict observer for the mutation run.
# ASCII only.  (PS 5.1 decodes BOM-less UTF-8 as GBK -> non-ASCII can change syntax.)
#
# WHY: mutation_test.ps1 writes per-mutant verdicts ONLY to stdout.  It does not
#      persist anything.  So the result exists solely in whatever pipeline the
#      caller happened to build -- and if that pipeline's process is killed (or
#      the caller used a blocking wait that tore down the tree), the verdicts are
#      LOST even though the RTL work already happened.  That is exactly what
#      happened on 2026-09-23: a 4-hour run died with zero recoverable output.
#
# WHAT: Independent observer.  It does NOT touch rtl/, tb/, or the lock.  It only
#       READS.  Run it alongside a mutation run; it snapshots the tee'd log to a
#       separate append-only file, and captures the final exit code.
#
# USAGE: powershell -NoProfile -ExecutionPolicy Bypass -File bringup\mutation_result_watchdog.ps1

param(
  [string]$LogPath = "build\mutation_run_20260923.log",
  [string]$OutPath = "build\mutation_verdicts.txt",
  [int]$PollSec = 60,
  [int]$MaxHours = 6
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

$log = Join-Path $root $LogPath
$out = Join-Path $root $OutPath
$deadline = (Get-Date).AddHours($MaxHours)
$seen = @{}

"# mutation verdict snapshot -- started $(Get-Date -Format o)" |
  Out-File -FilePath $out -Encoding utf8 -Append

while ((Get-Date) -lt $deadline) {

  if (Test-Path -LiteralPath $log) {
    # Read tolerant of the file being appended to concurrently.
    $lines = @()
    try {
      $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      $sr = New-Object System.IO.StreamReader($fs)
      $content = $sr.ReadToEnd()
      $sr.Close(); $fs.Close()
      $lines = $content -split "`r?`n"
    } catch { $lines = @() }

    foreach ($l in $lines) {
      # Per-mutant verdict lines look like: "  [M01] RED  (caught)  <why>"
      if ($l -match '\[(M\d+)\]\s+(RED|GREEN|SKIP|!!)') {
        $id = $Matches[1]
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $l.Trim() | Out-File -FilePath $out -Encoding utf8 -Append }
      }
      elseif ($l -match '^\s*(PASS|FAIL):') {
        if (-not $seen.ContainsKey($l)) { $seen[$l] = $true; $l.Trim() | Out-File -FilePath $out -Encoding utf8 -Append }
      }
    }
  }

  if (-not (Test-Path -LiteralPath (Join-Path $root "build\mutation\.lock"))) {
    "DONE: lock released $(Get-Date -Format o) -- total verdicts captured: $($seen.Count)" |
      Out-File -FilePath $out -Encoding utf8 -Append
    break
  }

  Start-Sleep -Seconds $PollSec
}

exit 0
