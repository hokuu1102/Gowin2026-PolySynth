# FX review evidence (2026-10-15)

Reviewed immutable source: `4a669c7c7dcf767404c1d2d8ee9657d2bdbe839e`.
No production changes or physical build. Original FX tests and guide lead test passed. Two added public-interface probes failed on real defects; these are not counted as successful functional tests.

The two `tb_fx_*.sv` files here are review probes, outside automatic production TB discovery. Logs are unmodified run outputs. Both drive only public input ports.

Reproduce from the repository root with Icarus Verilog:

```powershell
iverilog -g2012 -s tb_fx_public_contract -o build/fx_review/public.vvp rtl/w3c/fx_dist.v rtl/w3c/fx_trem.v rtl/w3c/fx_delay.v rtl/w3c/fx_chain.v evidence/fx_review_20261015/tb_fx_public_contract.sv
vvp build/fx_review/public.vvp
iverilog -g2012 -s tb_fx_clip_valid -o build/fx_review/clip.vvp rtl/w3c/fx_dist.v evidence/fx_review_20261015/tb_fx_clip_valid.sv
vvp build/fx_review/clip.vvp
```

Create the ignored `build/fx_review` output directory before running these commands on a fresh checkout. Both probes must currently exit1 with an explicit FAIL; preserve that red evidence rather than calling it PASS. Original test logs carry separate names and explicit PASS verdicts. See the review report for scope and interpretation.
