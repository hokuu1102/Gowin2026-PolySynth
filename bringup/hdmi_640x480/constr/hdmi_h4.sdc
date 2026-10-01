create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add
# H4: VCO/serial=768.75 MHz, pixel=153.75 MHz, serial/pixel=5 exactly.
create_generated_clock -name serial_clk -source [get_ports {clk}] -master_clock clk -divide_by 8 -multiply_by 123 [get_pins {u_clk/u_pll/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {clk}] -master_clock clk -divide_by 40 -multiply_by 123 [get_pins {u_clk/u_pll/CLKOUT1}]
