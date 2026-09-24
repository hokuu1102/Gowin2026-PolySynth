# probe_balls.ps1 -- find which ball numbers are LEGAL in this device/package
#
# WHY: the official examples do not all target the same package variant, so a ball that
# appears in an example .cst may still be rejected with CT1113 ("Can't find pad location").
# Guessing is slow and unreliable -- just ask the tool.
#
# Edit the $BALLS list below, then run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File bringup\jishi\probe_balls.ps1
#
# ASCII only (GBK console, see U46).

$BALLS = @("K13", "L14", "L16", "M15", "P16", "T16", "T21", "V18", "V19")

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$gw   = "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$tmp  = Join-Path $root "build\ballprobe"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$v = @"
module probe_top(input wire clk, input wire rst_n, output wire probe);
  reg [3:0] c = 4'd0;
  always @(posedge clk) c <= c + 4'd1;
  assign probe = c[3];
endmodule
"@
[System.IO.File]::WriteAllText((Join-Path $tmp "probe.v"), $v, [System.Text.UTF8Encoding]::new($false))

$gprj = @"
<?xml version="1" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project>
    <Template>FPGA</Template>
    <Version>5</Version>
    <Device name="GW5AT-60B" pn="GW5AT-LV60PG484AC2/I1">gw5at60b-003</Device>
    <FileList>
        <File path="probe.v" type="file.verilog" enable="1"/>
        <File path="probe.cst" type="file.cst" enable="1"/>
    </FileList>
</Project>
"@
[System.IO.File]::WriteAllText((Join-Path $tmp "probe.gprj"), $gprj, [System.Text.UTF8Encoding]::new($false))
$tcl = "open_project build/ballprobe/probe.gprj`nset_option -top_module probe_top`nrun all`nexit`n"
[System.IO.File]::WriteAllText((Join-Path $tmp "probe.tcl"), $tcl, [System.Text.UTF8Encoding]::new($false))

$legal = @()
foreach ($b in $BALLS) {
  $cst = "IO_LOC  `"clk`"   F13;`n" +
         "IO_PORT `"clk`"   IO_TYPE=LVCMOS33 PULL_MODE=NONE BANK_VCCIO=3.3;`n" +
         "IO_LOC  `"rst_n`" D1;`n" +
         "IO_PORT `"rst_n`" IO_TYPE=LVCMOS12 PULL_MODE=UP BANK_VCCIO=1.2;`n" +
         "IO_LOC  `"probe`" $b;`n" +
         "IO_PORT `"probe`" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;`n"
  [System.IO.File]::WriteAllText((Join-Path $tmp "probe.cst"), $cst, [System.Text.UTF8Encoding]::new($false))

  $out = (& $gw (Join-Path $tmp "probe.tcl") 2>&1 | Out-String)
  if ($out -match "CT1113" -or $out -match "PR2017" -or $out -match "PR2028") {
    Write-Host ("  {0,-6} ILLEGAL" -f $b) -ForegroundColor Red
  } else {
    Write-Host ("  {0,-6} legal" -f $b) -ForegroundColor Green
    $legal += $b
  }
}
Write-Host ""
Write-Host ("LEGAL balls: " + ($legal -join ", ")) -ForegroundColor Cyan
