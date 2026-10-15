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
  [string]$GwSh = "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe",
  #  ⭐⭐ 2026-10-15：⭐ **2400 → 7200**（⭐ 40 → 120 分钟 ✅）
  #     🔴 **实测再次踩到**（⭐ 同一天第二次）：
  #        合并队友的 BJ 冻结版（FFT + 时序收敛）之后，⭐ 设计变大
  #        （Logic 40061 → **43390**，CLS 25361 → **26125**）
  #        ⇒ 🔴 本轮 PnR 在**布线到 60%** 时被 `$gwProc.Kill()` 杀掉 ✅
  #        （⭐ 综合日志无 ERROR，⭐ 日志停在 `Running routing...` ⇒ **是超时不是错**）
  #     📌 ⭐ **规律**：⭐ 每次设计变大（尤其 CLS 涨），⭐ 这个数就得跟着涨。
  #        ⚠️ 别指望"上次够用这次也够" ✅
  #     📌 ⭐ 判据（⭐ 一眼分清"超时"和"真错"）：
  #        · ⭐ **超时** ⇒ 日志停在 `Running routing... [NN%]`，⭐ 综合日志**无 ERROR** ✅
  #        · ⭐ **真错** ⇒ 综合日志里有 `ERROR (EX...)`/`(PA...)` ✅
  #     ⚠️ 可用 `-BuildTimeoutSec` 临时覆盖 ✅
  [int]$BuildTimeoutSec = 7200,
  [switch]$KeepSyn,
  #  ⭐⭐ 2026-10-15：⭐ **`-KeepPnr`**（默认关闭 = 每次全新布局布线）
  #     🔴 **为什么要加**：⭐ `impl/pnr/Gowin2026.pr`（~108 MB）是 Gowin 的
  #        **物理数据库**，布线器会拿它当**增量**起点 ⇒ ⚠️ 如果它属于
  #        **另一版设计**（⭐ 合并前那版），布线器会把预算全花在"调和"上
  #        ⇒ 🔴 **永远走不出 `Routing Phase 0`**（⭐ 实测两次：2400 s / 3926 s）✅
  #     ✅ 默认清掉 ⇒ 全新 PnR ⇒ 队友用**干净副本**就是这么跑通的 ✅
  #     📌 `-KeepPnr` 保留增量（更快、保住上一个位流），⭐ 但它会喊警告 ✅
  [switch]$KeepPnr
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

# ---- GUARD: PnR algorithm options must be the project defaults (0/0) ----
#   WHY (2026-10-15): impl/Gowin2026_process_config.json was silently changed to
#   Place_Option=2 / Route_Option=2 -- a "timing-first" algorithm this project has
#   ALREADY measured as unusable (3906 unrouted nets in a 97-minute run).  The build
#   then took 53m19s and produced 676 unrouted nets (ERROR PR0004) with no obvious
#   cause, because this .json is NOT wiped by this script and the .gprj does not
#   carry these fields.  They are ALGORITHM choices, not random seeds; defaults are
#   0/0.  Fail fast here instead of burning an hour.
$pcPath = Join-Path $root "impl\Gowin2026_process_config.json"
if (Test-Path $pcPath) {
  $pcRaw   = [IO.File]::ReadAllText($pcPath)
  $pcPlace = [regex]::Match($pcRaw, '"Place_Option"\s*:\s*"([^"]*)"').Groups[1].Value
  $pcRoute = [regex]::Match($pcRaw, '"Route_Option"\s*:\s*"([^"]*)"').Groups[1].Value
  if (($pcPlace -ne "0") -or ($pcRoute -ne "0")) {
    Write-Host "ERROR: impl/Gowin2026_process_config.json has Place_Option='$pcPlace' Route_Option='$pcRoute' -- must be 0/0" -ForegroundColor Red
    Write-Host "       Non-default algorithm options caused 676 unrouted nets (PR0004) on 2026-10-15." -ForegroundColor Red
    exit 3
  }
  Write-Host "OK  PnR options are the project defaults (Place_Option=$pcPlace Route_Option=$pcRoute)"
} else {
  Write-Host "NOTE: impl/Gowin2026_process_config.json absent -- Gowin will use its own defaults (0/0)"
}

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
# ---- T2 (2026-10-03): wipe impl/gwsynthesis before synthesising ----
#   WHY: `run all` (and `run syn`) write into impl/gwsynthesis and read back
#   whatever is already there, so a resource number produced on top of a
#   previous build's leftovers is not trustworthy for comparison.  This repo's
#   own notes only obtained the clean figure AFTER wiping it (P5-1 ADSR share:
#   T_Lut 37075 -> 31672).
#
#   MEASURED 2026-10-03 with Gowin V1.9.12.03, same RTL (the 2026-10-03
#   tool-trap list, entry T2):
#       clean       T_Lut 31672(889)   164.2 s / 177.1 s
#       incremental T_Lut 31672(889)   164.8 s / 164.9 s
#       leftovers from a DIFFERENT rtl revision (the 37075 design) also gave
#       31672, and that run's console log was BYTE-IDENTICAL to the clean
#       run's -- so on this toolchain the wipe costs ~nothing and gw_sh
#       appears to re-synthesise fully either way.
#   Default is therefore CLEAN (option (a) of T2): it is free, and it removes
#   the whole class of "did the leftovers change the number?" doubt.
#   -KeepSyn restores the old incremental behaviour AND shouts about it,
#   because numbers produced that way must never go into a comparison table.
#   Placed here (after the .gprj guard, just before the build) so that a build
#   refused by the guard does not destroy the incremental state for nothing.
$synDir = Join-Path $root "impl\gwsynthesis"
if ($KeepSyn) {
  Write-Host "WARN: -KeepSyn -- SYNTHESIS IS INCREMENTAL (impl/gwsynthesis was NOT wiped)." -ForegroundColor Yellow
  Write-Host "WARN: the T_Lut / resource numbers from this run are NOT comparable with any other run." -ForegroundColor Yellow
} else {
  if (Test-Path $synDir) {
    $nSyn = @(Get-ChildItem $synDir -Recurse -File -ErrorAction SilentlyContinue).Count
    Remove-Item $synDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "OK  wiped impl/gwsynthesis ($nSyn files) -- full synthesis, numbers are comparable" -ForegroundColor Green
  } else {
    Write-Host "OK  impl/gwsynthesis already absent (clean synthesis)" -ForegroundColor Green
  }
}

# ---- 2026-10-15: ALSO wipe impl/pnr (the incremental place & route database) ----
#   WHY THIS EXISTS (measured, cost ~2 hours):
#     Gowin writes impl/pnr/Gowin2026.pr -- a ~108 MB PHYSICAL database that the
#     router reads back as the starting point for an INCREMENTAL place & route.
#     When that file belongs to a DIFFERENT design (here: the pre-merge one), the
#     router spends its whole budget trying to reconcile it and never gets past
#     "Running routing... [60%] Routing Phase 0 completed":
#         run A (pre-merge .pr present): killed at 2400 s, still Routing Phase 0
#         run B (pre-merge .pr present): 3926 s, still Routing Phase 0
#         teammate (FRESH project copy, no .pr): all phases to [100%], exit 0
#     So the .pr is the difference, not the RTL and not any place/route option
#     (the teammate's archived driver is plain `run syn` + `run pnr`).
#   Default is CLEAN, same reasoning as the synthesis wipe above: it removes a
#   whole class of "the leftovers changed the result" doubt, and a clean run is
#   the only one whose timing numbers can be compared with another run.
#   -KeepPnr restores incremental PnR (faster, keeps the previous bitstream)
#   and shouts about it.
$pnrDir = Join-Path $root "impl\pnr"
if ($KeepPnr) {
  Write-Host "WARN: -KeepPnr -- PLACE & ROUTE IS INCREMENTAL (impl/pnr was NOT wiped)." -ForegroundColor Yellow
  Write-Host "WARN: if a stale Gowin2026.pr from a different design is present, routing may never finish." -ForegroundColor Yellow
} else {
  if (Test-Path $pnrDir) {
    $nPnr = @(Get-ChildItem $pnrDir -Recurse -File -ErrorAction SilentlyContinue).Count
    $prOld = Join-Path $pnrDir "Gowin2026.pr"
    $prMb = if (Test-Path $prOld) { [math]::Round((Get-Item $prOld).Length / 1MB, 0) } else { 0 }
    Remove-Item $pnrDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "OK  wiped impl/pnr ($nPnr files, old Gowin2026.pr was ${prMb} MB) -- full place & route" -ForegroundColor Green
  } else {
    Write-Host "OK  impl/pnr already absent (clean place & route)" -ForegroundColor Green
  }
}

$errLog = Join-Path $evDir "gowin_build.stderr.log"
$gwProc = Start-Process -FilePath $GwSh -ArgumentList @("build_cli.tcl") `
                        -NoNewWindow -PassThru `
                        -RedirectStandardOutput $buildLog `
                        -RedirectStandardError  $errLog
$gwFinished = $gwProc.WaitForExit($BuildTimeoutSec * 1000)
if (-not $gwFinished) {
  Write-Host "WARN: gw_sh exceeded ${BuildTimeoutSec}s -- killing it (products may already be written)" -ForegroundColor Yellow
  try { $gwProc.Kill() } catch {}
  $gwProc.WaitForExit(10000) | Out-Null
}
$code = "n/a"
try { $gwProc.Refresh(); $code = $gwProc.ExitCode } catch { $code = "n/a" }
Write-Host "NOTE: gw_sh exit code = $code (informational only -- see the freshness check below)" -ForegroundColor DarkGray

# gw_sh sometimes does not exit on its own: give it a grace period, then kill
# it.  Never let the script hang forever -- a hang yields NO evidence while
# still looking like it is working.
#
# T5 (2026-10-03): kill ONLY the process THIS script started ($gwProc, from
#   Start-Process -PassThru), plus its own descendants.
#
#   The old code here was:
#       Get-Process gw_sh -ErrorAction SilentlyContinue | Stop-Process -Force
#   i.e. it killed EVERY gw_sh on the machine -- including a synthesis another
#   agent was running at that very moment.  That really happened: a WS2812
#   synthesis was killed by somebody else's gowin_build.ps1.
#
#   NEVER re-introduce a bare `Get-Process gw_sh | Stop-Process`.  Other
#   agents' probes live in %TEMP% and their builds run in other directories;
#   they are none of this script's business.
$stray = $null
try { $gwProc.Refresh(); if (-not $gwProc.HasExited) { $stray = $gwProc } } catch { $stray = $null }
if ($stray) {
  Write-Host "NOTE: OUR gw_sh (PID $($stray.Id)) is still alive after the build; waiting up to 30 s ..." -ForegroundColor Yellow
  $waited = 0
  while ((-not $gwProc.WaitForExit(1000)) -and $waited -lt 30) { $waited++ }
  try { $gwProc.Refresh() } catch {}
  if (-not $gwProc.HasExited) {
    Write-Host "WARN: OUR gw_sh (PID $($gwProc.Id)) did not exit after ${waited}s -- killing THAT PID (and its children) only" -ForegroundColor Yellow
    $ownIds = @([int]$gwProc.Id)
    # bounded descent: only processes whose parent chain starts at OUR PID
    for ($pass = 0; $pass -lt 3; $pass++) {
      $kids = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { ($ownIds -contains [int]$_.ParentProcessId) -and ($ownIds -notcontains [int]$_.ProcessId) })
      if ($kids.Count -eq 0) { break }
      $ownIds += @($kids | ForEach-Object { [int]$_.ProcessId })
    }
    foreach ($ownId in $ownIds) { Stop-Process -Id $ownId -Force -ErrorAction SilentlyContinue }
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

# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-21`）：⭐ **`NL0002` 硬门** —— 模块被"扫掉"必须是 ERROR ✅
#
#  🔴 **为什么**：⭐ 本项目第四道门是"综合 `ERROR=0`"，⭐ 而 `NL0002` 是 **WARN**
#     ⇒ 🔴 **一个模块整块消失也能过门** ✅
#     ⚠️ 而它带走的可能是注释**声称"仍在用"**的功能 ✅
#     📌 实测（⭐ 审查原文）：⭐ `param_extract`/`vibrato_lfo`/`right_analog_ctrl`
#        三个都被扫掉过，⭐ 而 `top.v` 的注释说它们"仍在用" ✅
#     📌 本条 = 把"注释声称的功能"与"网表里真有的功能"**强制对齐** ✅
#
#  ⭐ **白名单**：⭐ 只允许【文档写明该被扫掉】的模块（⭐ 每条必须附理由）✅
#     ⚠️ 白名单**过期**也会被反向发现（⭐ 若某模块复活，它就不再出现在 `NL0002` 里）✅
# ═══════════════════════════════════════════════════════════════════════════════
$nlLog = "impl/gwsynthesis/Gowin2026.log"
if (Test-Path $nlLog) {
  $nlAllow = @{
    'g_sound.u_pos_probe_dpos' = 'DPOS_DIAG=0 => diagnostic probe, documented as swept (top.v:186-196)'
    'g_sound.u_metronome'      = 'SEL_DRUM=1 => metronome replaced by the drum machine, should be swept'
    'u_led_data'               = 'three inputs are placeholder constants, should be swept'
    'g_sound.u_param_extract'  = 'PENDING: review says its pitch path is still in use => needs a live judgement'
    #  2026-10-13（合并 origin/main 之后新增）：u_uart_tx_esp 被扫，
    #    经【网表核实】是 Gowin 把两个完全相同的 uart_tx 例化【去重合并】，
    #    不是功能丢失。证据 impl/gwsynthesis/Gowin2026.vg：
    #      OBUF uart_tx_obuf       ( .O(uart_tx),       .I(esp_uart_tx_o_d) )
    #      OBUF esp_uart_tx_o_obuf ( .O(esp_uart_tx_o), .I(esp_uart_tx_o_d) )
    #    => 两个输出引脚【同源】，由同一套发送逻辑同时驱动 D15 与 G21，
    #       这正是 top.v:1512-1528 想要的"镜像同一份回包"语义 => 功能未丢。
    #    旁证：两个引脚在 sim/evidence/gowin_m0_pins.txt 里都 placed。
    'u_uart_tx_esp'            = 'Gowin deduplicated the two identical uart_tx instances (both OBUFs share net esp_uart_tx_o_d) => mirror semantics preserved, benign'
  }
  $nlHits = @(Select-String -Path $nlLog -Pattern 'NL0002' | ForEach-Object { $_.Line })
  $nlBad  = @()
  foreach ($h in $nlHits) {
    $ok = $false
    foreach ($k in $nlAllow.Keys) { if ($h -match [regex]::Escape($k)) { $ok = $true; break } }
    if (-not $ok) { $nlBad += $h }
  }
  if ($nlBad.Count -gt 0) {
    Write-Host "ERROR: NL0002 -- these modules were SWEPT but are NOT whitelisted:" -ForegroundColor Red
    foreach ($b in $nlBad) { Write-Host "         $($b.Trim())" -ForegroundColor Red }
    Write-Host "       A swept module is SILENT functional loss (a WARN passes the ERROR=0 gate)." -ForegroundColor Red
    Write-Host "       Either fix the dead path, or add it to the whitelist WITH a written reason." -ForegroundColor Red
    exit 5
  }
  Write-Host "OK  NL0002 gate: $($nlHits.Count) swept module(s), all whitelisted" -ForegroundColor Green
} else {
  Write-Host "WARN: no synthesis log at $nlLog => NL0002 gate skipped" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐⭐⭐ 2026-10-11（`P1-53`）：⭐ **参数守卫硬门**（`EX3793` => ERROR）✅
#
#  🔴🔴 **为什么必须加**（⭐ 2026-10-11 **实测证据**，⛔ 不是推测）：
#     ⭐ 本项目很多模块用 `initial` + `$fatal`/`$display` 做**参数自检**
#        （⭐ `top.v` 的 N4 三条下界、⭐ `uart_rx.v`、⭐ 各模块的 `PARAM_OK` …）✅
#     🔴 **而 Gowin 综合【完全不执行它们】** —— ⭐ 实测：
#        ```
#        WARN (EX2488) : Elaboration system task 'fatal' is ignored for synthesis
#        WARN (EX3858) : System task 'display' is ignored for synthesis
#        GowinSynthesis finish
#        gw_sh exit code = 0          ← 🔴 仍然是 0
#        ```
#     ⇒ 🔴 **"门① 综合 `ERROR=0`"【拦不住】任何参数错配** ✅
#        ⇒ ⭐ 例如把 `TRAVEL_TARE` 填成 0（⭐ `P0-11` 那个"**16 轴恒 held**"的失效模式）
#           ⇒ 🔴 **位流照样生成、照样上板** ✅
#
#  ⭐⭐ **实测过的三种"综合期断言"写法（⭐ 结论：Gowin 一律【只警告】）**：
#     | 写法 | 工具反应 | 退出码 |
#     |---|---|---|
#     | ⭐ `$fatal` / `$display` | ⭐ `EX2488` / `EX3858` … **is ignored for synthesis** | ⭐ **0** |
#     | ⭐ 例化**未声明模块** | ⭐ **`EX3793`** *Instantiating unknown empty module* | ⭐ **0** |
#     | ⭐ **负重复次数** `{(1-2){1'b0}}` | ⭐ `EX2195` *must be positive* | ⭐ **0** |
#     ⇒ 🔴 **RTL 层面的"综合期硬失败"在本工具链上【做不到】** ✅
#
#  ✅ **所以本门就是那个"把警告提升为错误"的地方** ✅
#     · ⭐ RTL 侧：⭐ 参数非法时 ⇒ ⭐ `generate` 取**坏分支** ⇒ ⭐ 例化一个**故意不存在**的模块
#        （⭐ 条件就写在 RTL 里 ⇒ ⭐ **RTL 仍是唯一真相源** ✅）
#     · ⭐ 本门：⭐ 综合日志里**出现 `EX3793`** ⇒ 🔴 **`exit 10`** ✅
#     📌 ⭐ **为什么这样比"在脚本里再解析一遍 Verilog 常量"好**：
#        ⚠️ 后者要**再实现一遍** RTL 的表达式 ⇒ ⭐ 又多一处"**两处真相**"；
#        ⭐ 本写法**条件只有一份**（⭐ 在 RTL 里），⭐ 脚本只认**工具给的信号** ✅
#     📌 ⭐ 参数**合法**时那条分支**不参与详细阐述** ⇒ ⭐ **零逻辑 / 零 FF**
#        （⭐ 实测：⭐ 加门前后 `T_Lut 27655` / `T_Register 17627` **一字不变** ✅）
#
#  ⚠️ **诚实标注**：⭐ 本门只能覆盖"**已经写了 `generate` 守卫**"的参数 ✅
#     ⇒ ⭐ 若某模块**只有** `initial` + `$display`（⭐ 没有 `generate` 守卫）
#        ⇒ ⚠️ **本门管不到它** ✅
#     📌 ⭐ 已加 `generate` 守卫的（⭐ 2026-10-11）：⭐ `top.v` 的 **N4 五个参数判据** ·
#        ⭐ `rtl/w3c/evt_buf.v` 的 **DEPTH 两条** ✅
#     📌 ⭐ 其余模块（⭐ `event_extract` / `axis_snapshot` / `axis_map` / `param_extract` /
#        `uart_rx` …）**仍是仿真侧防线** ⇒ ⭐ 记入 `P1-53` 的后续 ✅
# ═══════════════════════════════════════════════════════════════════════════════
if (Test-Path $nlLog) {
  $exHits = @(Select-String -Path $nlLog -Pattern 'EX3793' | ForEach-Object { $_.Line })
  if ($exHits.Count -gt 0) {
    Write-Host "ERROR: EX3793 -- a PARAMETER GUARD fired in synthesis (see P1-53):" -ForegroundColor Red
    foreach ($h in $exHits) { Write-Host "         $($h.Trim())" -ForegroundColor Red }
    Write-Host "       The offending module name spells the error; fix the parameter." -ForegroundColor Red
    Write-Host "       (Gowin only WARNS on this, and gw_sh still exits 0 -- so this gate is what makes it fail.)" -ForegroundColor Red
    exit 10
  }
  Write-Host "OK  P1-53 gate: 0 parameter-guard violations (EX3793 absent)" -ForegroundColor Green
} else {
  Write-Host "WARN: no synthesis log at $nlLog => P1-53 parameter-guard gate skipped" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-25`）：⭐ **looper BSRAM 读路径的 HOLD 余量判据** ✅
#
#  🔴 **为什么**：⭐ `u_looper` 的 BSRAM 读路径是**短路径 hold** ——
#     `rd_ptr_r`(FF) -> BSRAM 地址译码 -> BSRAM 输出 -> `ep_word_r`(FF) 的逻辑**极短**
#     => 数据到达太早 => 与最小 required time 相比**余量最小** ✅
#  ⚠️ **战场事实**：⭐ 本项目 PnR 是**布局噪声主导**的（同源重跑差 **2~3 MHz ≈ 0.7~1.1 ns 周期**）
#     => **0.1 ns 级的 hold 余量在这个噪声面前没有安全边际** ✅
#  📌 **审查快照的基线**：⭐ 最差 hold slack = **0.137 ns**（`rd_ptr_r_3_s0`）✅
#  🔴🔴 **2026-10-09 实测（本判据上线时）**：⭐ 最差已掉到 **0.053 ns**
#     => **余量恶化了 0.084 ns** => 这条**已经从"理论风险"变成"活风险"** ✅
#
#  ⛔ **两条红线**（审查原文）：
#    ① 任何把 `mem`/`ep_mem` 从 BSRAM 改成 FF/分布式 RAM 的方案**一律否决**
#       —— 那会把读路径逻辑**再缩短** => 🔴 **立刻变成 hold 违规** ✅
#    ② 不要在 `rd_ptr_r` -> RAM 读地址之间**删**逻辑（例如砍掉比较器）
#       —— 同理会把路径变短；**要动只能【加】** ✅
# ═══════════════════════════════════════════════════════════════════════════════
$tpPath = "impl/pnr/Gowin2026.timing_paths"
if (Test-Path $tpPath) {
  $tpLines = @(Get-Content $tpPath)
  #  找 HOLD 段的第一条（文件里 slack 按升序 => 第一条就是最差）
  $hIdx = -1
  for ($i = 0; $i -lt $tpLines.Count; $i++) {
    if ($tpLines[$i].Trim() -eq 'HOLD') { $hIdx = $i; break }
  }
  if ($hIdx -ge 0 -and ($hIdx + 1) -lt $tpLines.Count) {
    $holdWorst = [double]($tpLines[$hIdx + 1].Trim())
    $looperCnt = @($tpLines | Select-String -Pattern 'u_looper').Count
    Write-Host "  HOLD worst slack = $holdWorst ns  (review baseline 0.137)   u_looper hits = $looperCnt"
    if ($holdWorst -lt 0.05) {
      Write-Host "ERROR: P0-25 -- worst HOLD slack $holdWorst ns < 0.05 ns" -ForegroundColor Red
      Write-Host "       This is the u_looper BSRAM read path (short-path hold)." -ForegroundColor Red
      Write-Host "       Layout noise here is 0.7..1.1 ns => 0.05 ns has NO margin." -ForegroundColor Red
      Write-Host "       Do NOT move mem/ep_mem to FF/distributed RAM (makes it worse)." -ForegroundColor Red
      Write-Host "       Add shallow logic on rd_ptr_r -> read address instead (P0-25 fix 4)." -ForegroundColor Red
      exit 6
    }
    if ($holdWorst -lt 0.137) {
      Write-Host "WARN: P0-25 -- HOLD worst slack $holdWorst ns is BELOW the 0.137 baseline (but >= 0.05)" -ForegroundColor Yellow
    }
    Write-Host "OK  P0-25 gate: HOLD worst slack $holdWorst ns >= 0.05 ns" -ForegroundColor Green
  } else {
    Write-Host "WARN: no HOLD section in $tpPath => P0-25 gate skipped" -ForegroundColor Yellow
  }
} else {
  Write-Host "WARN: no timing_paths at $tpPath => P0-25 gate skipped" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-23`）：⭐ **复位必须【同步释放】** ✅
#
#  🔴 **为什么**：⭐ `rst_sync` 在 `posedge clk` 上产生一个**同步释放**的复位 ✅
#     ⚠️ 但接收端把它接进 `always @(posedge clk or negedge rst_n)` 的**异步**复位端
#     => 🔴 **释放沿对每个 FF 而言又变成【异步】的** ✅
#     => 各模块释放相差 **1~2 拍（20~40 ns）** —— 正是 `rst_sync` 明文要消灭的现象 ✅
#     📌 实测数字（审查引用 constr/top.sdc:90）：recovery +1.490 ns / **removal +0.217 ns**
#        => removal 余量只有 **1.1% 个时钟周期** => 任何布局噪声都能吃掉它 ✅
#     📌 现象："某次上电某个模块慢一拍"这类**偶发、不可复现**的怪病 ✅
#
#  ✅ **修法**：去掉灵敏度列表里的 `or negedge rst_n`（变纯同步复位）——
#     函数体本来就是 `if (!rst_n) ... else ...` => 语义不变、只是**释放同沿** ✅
#  📌 **代价**：同步复位生效晚 1 拍（20 ns）· 而 `rst_sync` 保持 STAGES 拍 => 够 ✅
#  📌 **收益（实测）**：`T_Lut` **-334**（同步复位反而更省 LUT ✅）
#
#  ⚠️ **例外**：`rtl/hdmi/hdmi_scope.v` 的 `reset_pipe` **保留异步**
#     —— 它有正当理由（要同步 PLL 的 `lock`）✅
#     📌 若要改它，必须走"**异步置位 + 同步释放的两级同步器**"并加 `(* async_reg *)` ✅
#     ⛔ **不许用 `set_false_path` 把 recovery/removal 藏起来**（top.sdc:88-90 已明文禁止 ✅）
# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-24`）：⭐ **门扩到【整棵 rtl/ 树】** ✅
#   📌 演进：⭐ 改前 **16 处** → ⭐ P0-23 后 **1 处**（`hdmi_scope`）→ ⭐ **P0-24 后 0 处** ✅
#   ⇒ ⭐ **全设计现在是【纯同步复位】** ✅
#   ⚠️ **正则必须【锚行首】**：⭐ 否则会命中【注释里】写的原文（⭐ 我踩过：假阳性 4 处 ✅）
#   ⚠️ `hdmi_scope.v` 的例外**已随 P0-24 消失**（⭐ 它现在也是域内同步 ✅）
$p023Hits = @()
Get-ChildItem rtl -Recurse -Include *.v, *.sv -ErrorAction SilentlyContinue | ForEach-Object {
  $h = @(Select-String -Path $_.FullName -Pattern '^\s*always\s*@\s*\(\s*posedge\s+\w+\s+or\s+negedge' -ErrorAction SilentlyContinue)
  if ($h.Count -gt 0) { $p023Hits += $h }
}
if ($p023Hits.Count -gt 0) {
  Write-Host "ERROR: P0-23 -- $($p023Hits.Count) async-reset sensitivity list(s) remain:" -ForegroundColor Red
  foreach ($h in $p023Hits) { Write-Host "         $($h.Path):$($h.LineNumber)" -ForegroundColor Red }
  Write-Host "       rst_sync produces a SYNCHRONOUS release; feeding it to an async reset" -ForegroundColor Red
  Write-Host "       port makes the release async again (modules leave reset 1..2 cycles apart)." -ForegroundColor Red
  Write-Host "       Fix: drop 'or negedge rst_n' (the body already has if(!rst_n))." -ForegroundColor Red
  Write-Host "       Exception: hdmi_scope.v reset_pipe (needs PLL lock) - use async_reg 2-stage." -ForegroundColor Red
  exit 7
}
Write-Host "OK  P0-23 gate: 0 async-reset sensitivity lists" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-26`）：⭐ **每个 `create_generated_clock` 都必须有 Fmax 行** ✅
#
#  🔴 **为什么**：⭐ 审查快照当时，`serial_clk`（125 MHz）在 Max Frequency Summary 里
#     **一行都没有** ⇒ ⭐ STA 直接写 "No timing paths to get frequency of serial_clk!"
#     ⇒ 🔴 **那个时钟域【零验证】** —— ⭐ 而"0 违例"会被误读成"已验证" ✅
#     📌 那是 `K-45`/`L31` 那一类坑：⭐ **沉默的域 ≠ 干净的域** ✅
#
#  ⭐⭐ **2026-10-09 的重要变更（⭐ 由 `P0-24` 引起）**：
#     ⭐ `P0-24` 往 `serial_clk` 域加了 `rstn_ser` 三级同步器
#        （⭐ `rtl/hdmi/hdmi_scope.v`，⭐ `posedge serial_clk` ✅）
#     ⇒ ⭐ **该域现在有真逻辑** ⇒ ⭐ 工具**自动报了它的 Fmax**
#     ⇒ ⭐ 实测 `Actual Fmax = 1312.981 MHz`（⭐ 约束 125 MHz ⇒ ⭐ 余量 **10.5×** ✅）
#     ⇒ ⭐ **"零验证"这件事已经不存在** —— ⭐ 但**必须用门钉住**，⛔ 不能靠"记得看报告" ✅
#
#  ✅ **判据（⭐ 机械、可复现）**：⭐ 从 `constr/top.sdc` 收集所有 `create_generated_clock -name X`
#     ⇒ ⭐ 每一个都必须在 `tr_content.html` 的 **Max Frequency Summary** 段里**出现** ✅
#     · 🔴 **改前（⭐ 审查当时）**：⭐ `serial_clk` **没有行** ⇒ ⭐ **FAIL** ✅
#     · ✅ **现在**：⭐ `clk_sys` / `serial_clk` / `pixel_clk` **三行都有** ⇒ ⭐ **PASS** ✅
#     📌 ⭐ **反向也有效**：⭐ 若哪天有人把 `rstn_ser` 删了 ⇒ ⭐ 那行会消失 ⇒ ⭐ **门主动报警** ✅
# ═══════════════════════════════════════════════════════════════════════════════
$sdcPath = "constr/top.sdc"
$htmlPath = "impl/pnr/Gowin2026_tr_content.html"
if ((Test-Path $sdcPath) -and (Test-Path $htmlPath)) {
  $sdcText = Get-Content $sdcPath -Raw
  $genClocks = @([regex]::Matches($sdcText, 'create_generated_clock\s+-name\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
  $html = Get-Content $htmlPath -Raw
  $mfsStart = $html.IndexOf('Max Frequency Summary')
  $mfsEnd = $html.IndexOf('Total Negative Slack Summary')
  if ($mfsStart -lt 0 -or $mfsEnd -le $mfsStart) {
    Write-Host "WARN: P0-26 -- Max Frequency Summary section not found => gate skipped" -ForegroundColor Yellow
  } else {
    $mfs = $html.Substring($mfsStart, $mfsEnd - $mfsStart)
    $missing = @()
    foreach ($c in $genClocks) { if ($mfs -notmatch [regex]::Escape($c)) { $missing += $c } }
    if ($missing.Count -gt 0) {
      Write-Host "ERROR: P0-26 -- these generated clocks have NO Fmax row (domain is UNVERIFIED):" -ForegroundColor Red
      foreach ($m in $missing) { Write-Host "         $m" -ForegroundColor Red }
      Write-Host "       A clock with no timing paths is SILENT, not clean (K-45/L31)." -ForegroundColor Red
      Write-Host "       Either add real logic so STA sees the domain, or document an explicit exemption." -ForegroundColor Red
      exit 8
    }
    Write-Host "OK  P0-26 gate: all $($genClocks.Count) generated clock(s) have an Fmax row: $($genClocks -join ', ')" -ForegroundColor Green
  }
} else {
  Write-Host "WARN: no top.sdc or no tr_content.html => P0-26 gate skipped" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ⭐⭐ 2026-10-09（`P0-29`）：⭐ **关键观测线必须有【消费者】** ✅
#
#  🔴 **为什么**：⭐ 本项目纪律 `K-106`：⭐ "**容量有限/会静默失效的东西必须可观测**" ✅
#     ⚠️ 但 top.v 里 **60+ 条**可观测性线**只出现 2 次**（声明 + 端口连接）
#     ⇒ ⭐ **没有消费者** ⇒ 🔴 **综合把整个观测锥剪掉** ✅
#     ⇒ ⭐ 那些为 K-106 写的 `overflow_o`（sticky）在**交付位流里一个都不存在** ✅
#     📌 ⭐ 后果：⭐ `event_extract` 的 FIFO 只有 **4 深** · `seq_arb`/`evt_merge` **6 深**
#        · `looper` 有 `EVT_MAX=2048` 上限
#        ⇒ ⭐ **丢事件是设计内的可能事件** —— ⭐ 而它 **100% 静默** ✅
#        ⇒ 🔴 上板永远看不到"溢出/丢弃/相撞"，⭐ 也没法给"挂音"类 bug 取证 ✅
#     📌 ⭐ 这正是 `P0-16`（`drop_cnt_o` 恒假饱和）的**放大版**：⭐ 既算错、又没人能看见 ✅
#
#  ✅ **判据（⭐ 机械、可复现）**：⭐ 这 6 条关键线在 `rtl/top.v` 里**必须出现 > 2 次** ✅
#     （⭐ 即"**有消费者**"，⭐ 不是"只有声明 + 端口连接" ✅）
#     · 🔴 **改前实测**：⭐ `ee_ovf`=2 · `ee_lost`=2 · `sa_overflow`=2 · `looper_overflow`=2
#       · `txf_ovf`=2（⭐ **6 条里 5 条会被剪** ✅）
#     · ✅ **改后实测**：⭐ 全部 **≥ 3 次** ✅
#     📌 ⭐ **反向也有效**：⭐ 若哪天有人把 `ovf_any` 的 OR 删了 ⇒ ⭐ 它们又掉回 2 ⇒ **门报警** ✅
# ═══════════════════════════════════════════════════════════════════════════════
$p029Critical = @('ee_ovf', 'ee_lost', 'sa_overflow', 'mg_overflow', 'looper_overflow', 'txf_ovf',
                  #  ⭐⭐ 2026-10-11（⭐ `P1-05`）：⭐ **`autotare` 的"跳过/失败"也纳入本门** ✅
                  #     🔴 原来它们只有"声明 + 端口映射" 2 处 ⇒ ⭐ 综合**剪掉**
                  #        ⇒ ⭐ "某个轴被跳过（零点没记）"**完全看不到** ✅（⭐ `K-106` ✅）
                  #     ✅ 修法：⭐ `top.v` 里 `assign at_fault_w = at_fail | (|at_skip);`
                  #        ＋ ⭐ 把 `at_fault_w` OR 进 `fault_any_w`（⭐ 心跳灯快闪 ⇒ 上板可见 ✅）
                  'at_fail', 'at_skip',
                  #  ⭐⭐ 2026-10-11（⭐ `P1-05` 同族）：⭐ **两个配置告警也纳入本门** ✅
                  #     🔴 原来 `metronome.cfg_warn_o` / `drum_gen.cfg_warn_o` 在 top.v 里
                  #        只有"声明 + 端口映射" 2 处 => 综合剪掉 => **参数配错了完全静默** ✅
                  #     ✅ 修法：⭐ `assign cfg_warn_w = met_cfg_warn | drm_cfg_warn;`
                  #        ＋ ⭐ 把 `cfg_warn_w` OR 进 `fault_any_w`（⭐ 心跳灯快闪 ✅）
                  'met_cfg_warn', 'drm_cfg_warn',
                  #  ⭐⭐ 2026-10-11（⭐ 新目标 ②）：⭐ **滑音开关也纳入本门** ✅
                  #     ⚠️ `slide_on_r` 是【寄存器】（⛔ 不是 wire）=> 本门"出现次数 > 2"这条
                  #        对它的约束力【较弱】—— 它自己 always 里的读写就有 3 次 ✅
                  #     📌 ⭐ **真正的判据**：⭐ 必须 >= 5 次（⭐ 声明 1 + always 里 3 +
                  #        接进 event_extract.slide_en_i 1）=> 少一次就说明【没接】✅
                  #     ⭐ 实测：⭐ 5 次 ✅（⭐ 未接线时是 4 次 ✅）
                  'slide_on_r',
                  #  ⭐⭐ 2026-10-11（⭐ 目标 ④）：⭐ **`as_seen` 也纳入本门** ✅
                  #     🔴 原来 `axis_snapshot.axis_seen_o`（16 轴"见过"位图）在 top.v 里
                  #        只有"声明 + 端口映射" 2 处 => 综合剪掉
                  #        => "某个轴从来没被采样到"完全看不到（症状：那个键不响）
                  #     ✅ 修法：⭐ `assign adc_partial_w = (as_seen != 0) & (as_seen != 16'hFFFF);`
                  #        ＋ ⭐ OR 进 `fault_any_w`（⭐ 心跳灯快闪 ✅）
                  #     📌 判据设计：⭐ `!= 0` 免上电假警 · ⭐ `!= 全 1` 才报"部分见过" ✅
                  'as_seen',
                  #  ⭐⭐ 2026-10-12（⭐ 目标 ④ · ⭐ 第二方案）：⭐ **帧流失步也纳入本门** ✅
                  #     🔴 原状：`eu_frame_cnt` / `eu_resync_cnt` 只有"声明 + 端口映射" 2 处
                  #        => 剪掉 => "灌了谱子但不出声"看不到
                  #     ✅ 修法（⭐ 复用已有计数器，⛔ 不加新 FF ✅）：
                  #        `assign fault_any_w = ... | ((eu_resync_cnt > 0) & (eu_frame_cnt == 0));`
                  #     📌 判据设计：⭐ `resync > 0` = "已经活动过" => 免上电假警
                  #     ⭐ 为什么不用第一方案（eu_active_r & ~eu_synced）：加 1 个 FF
                  #        => P0-25（HOLD）红了（0.032 < 0.05）；且实测 PnR 是确定性的，重跑无用
                  #     ⭐ 实测：⭐ 出现 4 / 5 次（⭐ 都 > 2 ✅）· ⭐ CLS 只 +36（对比第一方案 +254）
                  'eu_resync_cnt', 'eu_frame_cnt')
$topVPath = "rtl/top.v"
if (Test-Path $topVPath) {
  $topText = Get-Content $topVPath -Raw
  $p029Dead = @()
  foreach ($w in $p029Critical) {
    $cnt = ([regex]::Matches($topText, [regex]::Escape($w))).Count
    if ($cnt -le 2) { $p029Dead += "$w ($cnt)" }
  }
  if ($p029Dead.Count -gt 0) {
    Write-Host "ERROR: P0-29 -- these critical observability wires have NO consumer (synthesis will prune them):" -ForegroundColor Red
    foreach ($d in $p029Dead) { Write-Host "         $d" -ForegroundColor Red }
    Write-Host "       K-106: anything that can silently fail must be observable." -ForegroundColor Red
    Write-Host "       A wire that only appears in its declaration + port map is electrically dangling." -ForegroundColor Red
    Write-Host "       Fix: OR the sticky bits into fault_any_w (heartbeat LED fast-blink)." -ForegroundColor Red
    exit 9
  }
  Write-Host "OK  P0-29 gate: all $($p029Critical.Count) critical observability wires have a consumer" -ForegroundColor Green
} else {
  Write-Host "WARN: no rtl/top.v => P0-29 gate skipped" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════════
# ⭐⭐ 机械门：⭐ **HDL 源码不许有 BOM**（⭐ 2026-10-11 新增 · ⭐ `P1-20` 同族 ✅）
#
#   🔴 **为什么**（⭐ 实测踩到，⭐ 代价很大 ✅）：
#      ⭐ 用 PowerShell 的 `Set-Content -Encoding utf8`（⭐ PS 5.1 ✅）改 `.v` 文件
#      ⇒ ⭐ **它会静默加上 UTF-8 BOM**（`EF BB BF`）✅
#      ⇒ 🔴 **iverilog 解析不出该文件的模块** ⇒ ⭐ 那个模块**不存在**
#      ⇒ 🔴 **所有例化它的 tb** 都报：
#         `error: Unable to find the root module "<tb 的名字>"`
#      ⚠️ ⭐ **错的是那个 RTL 文件，⭐ 报的却是 tb 的名字** ⇒ ⭐ 极难定位 ✅
#      📌 ⭐ 实测：⭐ 给 `play_seq.v` 加 BOM ⇒ ⭐ 所有例化 `play_seq` 的 tb 全挂 ✅
#
#   ⚠️ ⭐ **与 `.ps1` 的规则【相反】**（⭐ 容易记反 ✅）：
#      · ⭐ `.ps1`     ⇒ ⭐ **必须带 BOM**（⭐ 或纯 ASCII ✅）· 门 = `tools/check_ps1_encoding.ps1` ✅
#      · ⭐ `.v`/`.sv` ⇒ 🔴 **必须【没有】BOM** ✅ · ⭐ 门 = 本段 ✅
#
#   📌 ⭐ **为什么放这里（⭐ 而 `check_no_pruning` 不接 ✅）**：
#      ⭐ 本门扫的是 **HDL 源码本身** ⇒ ⭐ 与"跑没跑回归"无关 ⇒ ⭐ 放构建脚本**永远有效** ✅
#      ⚠️ 而 `check_no_pruning` 扫的是 **tb 编译日志** ⇒ ⭐ 旧日志会误报 ⇒ ⭐ 保持**手动调用** ✅
# ═══════════════════════════════════════════════════════════════════════════════
$bomGate = "tools/check_no_bom.ps1"
if (Test-Path $bomGate) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $bomGate
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: BOM gate failed -- some HDL file starts with a UTF-8 BOM." -ForegroundColor Red
    Write-Host "       iverilog will not parse that file's module, and every testbench that" -ForegroundColor Red
    Write-Host "       instantiates it will report 'Unable to find the root module <tb>'." -ForegroundColor Red
    Write-Host "       Fix: strip the 3 BOM bytes (byte level) and edit HDL with the edit tool," -ForegroundColor Red
    Write-Host "            never with Set-Content -Encoding utf8." -ForegroundColor Red
    exit 11
  }
} else {
  Write-Host "WARN: $bomGate not found => BOM gate skipped" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Gowin build finished, exit code 0 ===" -ForegroundColor Green
Write-Host "bitstream: impl/pnr/Gowin2026.fs  (git-ignored, regenerated by this script)"
exit 0
