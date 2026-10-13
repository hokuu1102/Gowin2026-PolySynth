# Build in the ASCII checkout. Copy the qualified output to the user archive
# only AFTER checking this run's timing report and bitstream fingerprint.
file mkdir build
set backup build/fault_diag_project_backup.gprj
if {[file exists $backup]} { error "Existing diagnostic backup: resolve before retry" }
file copy Gowin2026.gprj $backup
set failed [catch {
    open_project Gowin2026.gprj
    set_option -top_module top
    rm_file rtl/top.v
    add_file -type verilog bringup/fault_diag/top_diag_include.v
    run all
} result]
# Gowin rm_file/add_file save the project automatically. Restore its exact
# bytes so a later ordinary build cannot silently become diagnostic.
file copy -force $backup Gowin2026.gprj
file delete $backup
if {$failed} { error $result }
exit
