# build_cli_restore.tcl -- restore the DEFAULT PnR options.
#
# Why this file exists:
#   set_option PERSISTS into impl/ (Gowin2026_process_config.json and
#   impl/pnr/cmd.do), so a -PnrOpts experiment leaks into every later run
#   and makes the results non-comparable.
#
#   A test run of "gowin_build.ps1 -PnrOpts -place_option 2" left
#   Place_Option = "2" behind (the script exited before its restore block).
#   This file puts the defaults back.
#
# The project default flow is place_option 0 / route_option 0
#   (see files/20-代码/H5显示修复与时序拉锯-记录与方向-20261002.md:344).
#
# ASCII only on purpose: the Tcl shell on a GBK Windows locale chokes on
# non-ASCII comments (see build_cli.tcl).

open_project Gowin2026.gprj

set_option -place_option 0
set_option -route_option 0

# Added 2026-10-13: a test of -correct_hold_violation left this set to true.
# NOTE the option name is -correct_hold_violation (NOT -correct_hold_viol --
#      that one makes the Tcl shell error out).
set_option -correct_hold_violation 0

exit
