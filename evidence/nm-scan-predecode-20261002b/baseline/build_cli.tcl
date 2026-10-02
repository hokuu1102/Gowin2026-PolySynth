# build_cli.tcl -- build the whole Gowin project WITHOUT opening the IDE.
#
# Usage (from the repository root):
#   "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe" build_cli.tcl
#
# Why it is worth keeping:
#   1. It verifies "do my changes still pass the toolchain?" (synthesis / PnR /
#      timing / pin legality) with NO board attached.  Simulation passing is NOT
#      the same thing as being synthesisable.
#   2. It is the cheapest way to re-check after editing .cst or adding a module.
#
# NOTE: this file is deliberately ASCII-only -- the Tcl shell on a GBK Windows
#       locale can choke on non-ASCII comments.  The Chinese explanation lives in
#       files/20-代码/代码总览图.md (P1).
#
# NOTE: do NOT run this while the Gowin IDE has the same project open.

open_project Gowin2026.gprj

# Pick the top module explicitly (the project will grow more top levels later).
set_option -top_module top

# Synthesis + place & route + bitstream generation.
run all

exit
