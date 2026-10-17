# PnR evidence index (append-only, written by tools/archive_pnr_evidence.ps1)

> WHY: `sim/gowin_build.ps1` wipes `impl/pnr/` every run and `impl/` is
> git-ignored, while `gowin_m0_timing.txt` keeps only three summary
> blocks.  Recovery / Removal / MinPulseWidth / the Setup and Hold path
> tables survive ONLY here.  Call this script right after every build.

| archived | label | setup | hold | paths | Fmax | LL | worst setup slack | fs sha256 | note |
|---|---|---|---|---|---|---|---|---|---|
| 20261017-215116 | respin-2128-192setup | 192 | 0 | 65515 |  |  |  | 978521387D4EB724 | same RTL as 20:46; deterministic respin = 192/0/57.866/15; DO NOT BURN |
| 20261017-215116 | respin-2128-192setup-v2 |  |  |  |  |  |  | 978521387D4EB724 | re-run after fixing empty Fmax/Level/worstSlack; same 21:51 report |
| 20261017-215116 | respin-2128-192setup-v3 | 192 | 0 | 65515 |  |  |  | 978521387D4EB724 | third pass: Next-Cell/ClkSys/WorstSlack parsers fixed; same 21:51 report |
| 20261017-215116 | respin-2128-192setup-v4 | 192 | 0 | 65515 | 57.866(MHz) | 15 | -0.881 | 978521387D4EB724 | v4: anchors without colon + cell-per-line parsers; same 21:51 report |
| 20261017-215116 | respin-2128-192setup-final | 192 | 0 | 65515 | 57.866(MHz) | 15 | -0.881 | 978521387D4EB724 | FINAL: all 6 headline fields + 5 path tables parse correctly; same 21:51 report |
| 20261017-231728 | span-removed-34viol | 34 | 0 | 64980 | 58.740(MHz) | 12 | -0.624 | D9C07ECB0B7C5D9C | span deleted (calib.sv+ctrl_key_map.v) + tmds recovery fix; 192->34 violations, Fmax 58.740 |
