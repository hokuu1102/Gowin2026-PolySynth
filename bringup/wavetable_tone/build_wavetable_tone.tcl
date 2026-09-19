# W1-2 one-shot synthesis, place-and-route, timing, and bitstream generation.
# Run from the repository root with Gowin gw_sh.

open_project bringup/wavetable_tone/wavetable_tone.gprj
set_option -top_module wavetable_tone_top
run all
exit
