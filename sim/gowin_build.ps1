# gowin_build.ps1 -- build the Gowin project from the command line and copy the
#                    evidence (timing / pins / resources) into sim/evidence/.
#
# Usage (from anywhere):
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\gowin_build.ps1
#
# WHY: impl/** is git-ignored (it is regenerated), so the *evidence* would be lost.
#      This script keeps the four things a reviewer actually needs:
#        sim/evidence/gowin_build.log        full console output of the build
#        sim/evidence/gowin_m0_timing.txt    violated endpoints + Fmax + clock summary
#        sim/evidence/gowin_m0_pins.txt      pinout by port name (are the pins legal?)
#        sim/evidence/gowin_m0_rsc.xml       resource usage
#
# NOTE: this file is deliberately ASCII-only. PowerShell 5.1 decodes BOM-less
#       UTF-8 as the local code page (GBK), which turns Chinese comments into
#       mojibake and breaks the parser.  See K-38.
#
# NOTE: do NOT run this while the Gowin IDE has the same project open.

param(
  [string]$GwSh = "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$evDir = Join-Path $root "sim\evidence"
New-Item -ItemType Directory -Force -Path $evDir | Out-Null

if (-not (Test-Path $GwSh)) {
  Write-Host "ERROR: gw_sh.exe not found: $GwSh" -ForegroundColor Red
  exit 2
}

Push-Location $root

# ---- ⭐ GUARD: files instantiated by top.v must be registered in the .gprj ----
#   WHY (2026-09-22): play_seq.v was created, its tb passed, the regression was
#   green -- and the PnR run silently did NOT include it, so the timing evidence
#   was byte-identical to the previous build (same Fmax to 3 decimals, same LUT
#   count).  The .gprj even has a comment warning about this trap ("write the
#   wrong type and Gowin skips the file without an error"), yet nothing ENFORCED
#   it.  A green PnR that did not compile the new file is worse than no PnR.
#
#   SCOPE: only files that top.v actually INSTANTIATES.
#     - rtl/bringup/*      -> separate bringup projects, not part of delivery
#     - adc_farm/calib     -> not instantiated by top.v today (T47 audits this)
#   Flagging those would block legitimate builds and train people to ignore the
#   check (the "crying wolf" failure this project has hit before).
$gprjPath = Join-Path $root "Gowin2026.gprj"
$topPath  = Join-Path $root "rtl\top.v"
if ((Test-Path $gprjPath) -and (Test-Path $topPath)) {
  $gprjText = Get-Content $gprjPath -Raw
  $topText  = Get-Content $topPath  -Raw
  $rtlFiles = Get-ChildItem -Path (Join-Path $root "rtl") -Recurse -Include *.v, *.sv -File |
              Where-Object { $_.Name -notlike "tb_*" -and
                             $_.DirectoryName -notmatch '\\bringup$' -and
                             $_.Name -ne 'top.v' }
  $missing = @()
  foreach ($f in $rtlFiles) {
    $mod = $f.BaseName
    # only care if top.v instantiates this module by name
    if ($topText -notmatch ("(?m)^\s*" + [regex]::Escape($mod) + "\s*#?\s*\(")) { continue }
    $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
    if ($gprjText -notmatch [regex]::Escape($rel)) { $missing += $rel }
  }
  if ($missing.Count -gt 0) {
    Write-Host "ERROR: top.v instantiates these, but they are NOT in Gowin2026.gprj:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "         $m" -ForegroundColor Red }
    Write-Host "       The build would SILENTLY omit them (no error, wrong timing evidence)." -ForegroundColor Red
    Write-Host "       Register each as type=`"file.verilog`" (also for .sv) and re-run." -ForegroundColor Red
    Pop-Location
    exit 3
  }
}

Write-Host "=== gowin build (synthesis + PnR + bitstream) ===" -ForegroundColor Cyan
$buildLog = Join-Path $evDir "gowin_build.log"

# Record the pre-build mtime so we can verify the report was regenerated.
#   PITFALL (2026-09-22): gw_sh finished its work but did NOT exit, so
#   `& $GwSh ... | Tee-Object` never returned, the script blocked on the next
#   line, and the timing extraction below NEVER RAN.  gowin_m0_timing.txt still
#   held the PREVIOUS build's numbers, and they were reported as the new ones.
#   The number looked perfectly normal -- the worst kind of wrong.
$trPathPre = Join-Path $root "impl\pnr\Gowin2026_tr_content.html"
$trTimePre = if (Test-Path $trPathPre) { (Get-Item $trPathPre).LastWriteTime } else { $null }

# ⭐⭐ 2026-09-28 修复（实测再次踩到，L80-84 记录过但修得不彻底）：
#   🔴 原写法 `& $GwSh build_cli.tcl 2>&1 | Tee-Object` ——
#      gw_sh 构建【成功完成后】有时既不退出、也【不关闭 stdout】
#      ⇒ ⭐ 管道【永久阻塞】⇒ 下面所有步骤（含证据提取）永远不执行。
#      ⚠️ 而 L91-105 的"等 30 s 再强杀"在管道【之后】⇒ 管道不返回时根本轮不到。
#      📌 实测（2026-09-28）：构建 15:34:48 就完成，但 gw_sh 保持存活、
#         12 秒内 CPU 增量 = 0 ⇒ 脚本一直卡着，证据文件停在【上一版】。
#
#   ✅ 修法：⭐ 不用管道，改成【重定向到文件】+ ⭐ 【硬超时】。
#      超时后强杀 gw_sh —— 此时产物通常已落盘，由下面的【新鲜度检查】裁决成败。
$buildTimeoutSec = 1200        # ⭐ 20 min：正常构建 ~10 min ⇒ 留 2× 余量；卡死时最多损失 20 min
$errLog = Join-Path $evDir "gowin_build.stderr.log"
$gwProc = Start-Process -FilePath $GwSh -ArgumentList @("build_cli.tcl") `
                        -NoNewWindow -PassThru `
                        -RedirectStandardOutput $buildLog `
                        -RedirectStandardError  $errLog
$gwFinished = $gwProc.WaitForExit($buildTimeoutSec * 1000)
if (-not $gwFinished) {
  Write-Host "WARN: gw_sh exceeded ${buildTimeoutSec}s -- killing it (products may already be written)" -ForegroundColor Yellow
  try { $gwProc.Kill() } catch {}
  $gwProc.WaitForExit(10000) | Out-Null
}
$code = "n/a"
try { $gwProc.Refresh(); $code = $gwProc.ExitCode } catch { $code = "n/a" }
Write-Host "NOTE: gw_sh exit code = $code (informational only -- see the freshness check below)" -ForegroundColor DarkGray

# gw_sh sometimes does not exit on its own: give it a grace period, then kill
# it.  Never let the script hang forever -- a hang yields NO evidence while
# still looking like it is working.
$stray = Get-Process gw_sh -ErrorAction SilentlyContinue
if ($stray) {
  Write-Host "NOTE: gw_sh still alive after the pipe returned; waiting up to 30 s ..." -ForegroundColor Yellow
  $waited = 0
  while ((Get-Process gw_sh -ErrorAction SilentlyContinue) -and $waited -lt 30) {
    Start-Sleep -Seconds 1; $waited++
  }
  if (Get-Process gw_sh -ErrorAction SilentlyContinue) {
    Write-Host "WARN: gw_sh did not exit after ${waited}s -- killing it (reports are already written)" -ForegroundColor Yellow
    Get-Process gw_sh -ErrorAction SilentlyContinue | Stop-Process -Force
  }
}

Pop-Location

# Freshness check: stronger than an exit code against stale evidence.
#   Criterion: the PnR report must be NEWER than it was before the build.
#
# ⭐⭐ 2026-09-28 修复：把"新鲜度"提升为【唯一判据】，并让它【压过】退出码。
#   🔴 原缺陷：新鲜度检查已通过，但紧接着 `if ($code -ne 0)` 又报 "build failed"
#      ⇒ ⚠️ 实测：gw_sh 构建成功后不退出 ⇒ 被超时强杀 ⇒ 退出码非 0
#      ⇒ 🔴 明明产物是【新的、完整的】，脚本却报失败并 exit 1，
#         ⭐ 而且【证据提取步骤被跳过】⇒ 证据文件停在上一版。
#   📌 纪律：⭐ 判"构建成功"要看【产物】，⛔ 不看工具的退出码（同族 C30 / U52 / L74）。
$freshOk = $false
$trPathNow = Join-Path $root "impl\pnr\Gowin2026_tr_content.html"
if (-not (Test-Path $trPathNow)) {
  Write-Host "ERROR: no PnR report at $trPathNow -- the build produced nothing" -ForegroundColor Red
  exit 4
}
$trTimeNow = (Get-Item $trPathNow).LastWriteTime
if (-not $trTimePre) {
  Write-Host "NOTE: no pre-build timestamp (first build) -- accepting the report as fresh" -ForegroundColor Yellow
  $freshOk = $true
} elseif ($trTimeNow -le $trTimePre) {
  Write-Host "ERROR: impl/pnr/Gowin2026_tr_content.html was NOT regenerated by this run" -ForegroundColor Red
  Write-Host "       (before=$trTimePre  after=$trTimeNow)" -ForegroundColor Red
  Write-Host "       Refusing to publish timing evidence -- it would be from an OLDER build." -ForegroundColor Red
  exit 4
} else {
  Write-Host "OK  PnR report is fresh (regenerated at $trTimeNow)" -ForegroundColor Green
  $freshOk = $true
}

if ($code -ne 0) {
  if ($freshOk) {
    Write-Host "NOTE: gw_sh exit code = $code -- IGNORED (killed after the build finished; the PnR report is fresh)" -ForegroundColor Yellow
  } else {
    Write-Host "ERROR: gowin build failed, exit code $code -- see $buildLog" -ForegroundColor Red
    exit $code
  }
}

# ---- warnings we must never ignore (see K-45 in the risk list) ----
$logText = Get-Content $buildLog -Raw
foreach ($w in @("TA1132", "PR1014")) {
  if ($logText -match $w) {
    Write-Host "WARN: $w present -- see K-45 / the toolchain doc before judging the result" -ForegroundColor Yellow
  }
}

# ---- strip HTML into plain rows ----
function Get-ReportRows([string]$path) {
  $raw = Get-Content $path -Raw
  $t = $raw -replace '(?i)</t[dh]>', ' | ' -replace '(?i)</tr>', "`n" -replace '<[^>]+>', '' -replace '[ \t]+', ' '
  @($t -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}
function Get-Block($rows, [string]$from, [string]$to, [int]$max = 40) {
  $i = -1; $j = -1
  for ($k = 0; $k -lt $rows.Count; $k++) {
    if ($i -lt 0 -and $rows[$k] -like "*$from*") { $i = $k }
    elseif ($i -ge 0 -and $to -ne "" -and $rows[$k] -like "*$to*") { $j = $k; break }
  }
  if ($i -lt 0) { return @("(section not found: $from)") }
  if ($j -lt 0) { $j = [Math]::Min($i + $max, $rows.Count - 1) }
  return $rows[$i..$j]
}

$trPath = Join-Path $root "impl\pnr\Gowin2026_tr_content.html"
$rptTxt = Join-Path $root "impl\pnr\Gowin2026.rpt.txt"
$rscXml = Join-Path $root "impl\gwsynthesis\Gowin2026_syn_rsc.xml"

# ---- timing summary ----
if (Test-Path $trPath) {
  $rows = Get-ReportRows $trPath
  $timing = @()
  $timing += "# Gowin timing evidence (generated by sim/gowin_build.ps1)"
  $timing += "# source: impl/pnr/Gowin2026_tr_content.html"
  $timing += ""
  $timing += "== STA tool run summary (setup/hold violations) =="
  $timing += Get-Block $rows "STA Tool Run Summary:" "Clock Summary:"
  $timing += ""
  $timing += "== clock summary (is our .sdc in effect?) =="
  $timing += Get-Block $rows "Clock Summary:" "Max Frequency Summary:"
  $timing += ""
  $timing += "== max frequency summary (Fmax) =="
  $timing += Get-Block $rows "Max Frequency Summary:" "" 12
  $timing | Out-File -FilePath (Join-Path $evDir "gowin_m0_timing.txt") -Encoding utf8
  Write-Host "OK  sim/evidence/gowin_m0_timing.txt"
} else {
  Write-Host "WARN: no timing report at $trPath" -ForegroundColor Yellow
}

# ---- pinout by port name ----
if (Test-Path $rptTxt) {
  $lines = Get-Content $rptTxt
  $a = ($lines | Select-String "7. Pinout by Port Name" | Select-Object -First 1).LineNumber
  $b = ($lines | Select-String "8. All Package Pins" | Select-Object -First 1).LineNumber
  if ($a -and $b -and $b -gt $a) {
    $hdr = @(
      "# Gowin pinout evidence (generated by sim/gowin_build.ps1)",
      "# source: impl/pnr/Gowin2026.rpt.txt section 7",
      "# every port must show the Loc./bank we wrote in constr/top.cst",
      ""
    )
    ($hdr + $lines[($a + 1)..($b - 2)]) | Out-File -FilePath (Join-Path $evDir "gowin_m0_pins.txt") -Encoding utf8
    Write-Host "OK  sim/evidence/gowin_m0_pins.txt"
  } else {
    Write-Host "WARN: pinout section not found in rpt.txt" -ForegroundColor Yellow
  }
} else {
  Write-Host "WARN: no PnR report at $rptTxt" -ForegroundColor Yellow
}

# ---- resources ----
if (Test-Path $rscXml) {
  Copy-Item $rscXml (Join-Path $evDir "gowin_m0_rsc.xml") -Force
  Write-Host "OK  sim/evidence/gowin_m0_rsc.xml"
} else {
  Write-Host "WARN: no resource report at $rscXml" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Gowin build finished, exit code 0 ===" -ForegroundColor Green
Write-Host "bitstream: impl/pnr/Gowin2026.fs  (git-ignored, regenerated by this script)"
exit 0
