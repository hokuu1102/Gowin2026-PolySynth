create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

// The checked-in Sipeed PLL RTL uses MDIV=22, ODIV0=3, ODIV1=15.
// Constrain the frequencies implemented by that RTL, not the stale nominal
// 74.25/371.25 MHz values in the upstream SDC/IPC metadata.
create_generated_clock -name clk_tmds_5x -source [get_ports {clk}] -master_clock clk -divide_by 3 -multiply_by 22 [get_pins {u_tmds_pll/PLLA_inst/CLKOUT0}]
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 15 -multiply_by 22 [get_pins {u_tmds_pll/PLLA_inst/CLKOUT1}]

// Match the clock grouping used by Sipeed's official cam_dvi reference.
set_clock_groups -asynchronous -group [get_clocks {clk_tmds_5x}] -group [get_clocks {clk_pixel}] -group [get_clocks {clk}]
