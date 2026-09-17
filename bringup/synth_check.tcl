# synth_check.tcl -- synthesis-only check for EVERY module (see bringup/01-*.md section 3-5)
#
# Usage (from the repository root):
#   "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe" bringup\synth_check.tcl
#
# WHY: Gowin only COMPILES modules reachable from the top module. A file that is merely
#      listed in a project gets "Analyzing ..." but NOT "Compiling module ...", so
#      "I added it to the project and the build passed" is NOT evidence that it
#      synthesises (see K-46).  bringup/synth_check.gprj uses bringup/synth_check_top.v
#      as its top, and that top instantiates every module we want checked.
#
# NOTE: ASCII only (Tcl on a GBK console mangles non-ASCII comments).
# NOTE: synthesis only -- no .cst needed, no bitstream, no board.

open_project bringup/synth_check.gprj
set_option -top_module synth_check_top
run syn
exit
