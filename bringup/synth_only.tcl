# synth_only.tcl -- synthesis-only check of the REAL delivery project.
#
# Usage (from the repository root):
#   "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe" bringup\synth_only.tcl
#
# WHY: the real project's top instantiates calib, so `run syn` ALONE catches
#      multiple-driver errors (EX2000 / EX1999) in about a minute, instead of
#      waiting for a full PnR (10 minutes) only to have it die in synthesis.
#      This is the "run synthesis BEFORE PnR" gate.
#
# NOTE: ASCII only (Tcl on a GBK console mangles non-ASCII comments).
# NOTE: synthesis only -- no .cst, no placement, no routing, no bitstream.

open_project Gowin2026.gprj
run syn
exit
