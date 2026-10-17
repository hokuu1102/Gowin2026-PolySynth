# Bitstream index (append-only, written by tools/archive_bitstream.ps1)

> WHY: `sim/gowin_build.ps1` WIPES `impl/pnr/` at the start of every run,
> and `impl/` is git-ignored -- so an un-archived bitstream is gone forever.
> Archive BEFORE starting a new build.

| archived | label | size MB | sha256 | note |
|---|---|---|---|---|
| 20261016-220458 | v3-cstfix | 19.7 | `316FE958A45C4A8C2F4D29D285783E742F48E1DEA315953341796B9EB3F7AE80` | h5_scope restored; b0cac597 |
| 20261016-220458 | v3-cstfix-2fix | 19.7 | `316FE958A45C4A8C2F4D29D285783E742F48E1DEA315953341796B9EB3F7AE80` | slide+LED fixes NOT yet in this fs; archived before rebuild |
| 20261017-231724 | 20261017-2317-span-removed-release | 19.8 | `D9C07ECB0B7C5D9C37ED835776F59E7F171082873E26DA25A8505040DBB839AE` | span deleted + tmds recovery fix; 34 EP vs 16.4 over-constraint but REAL slack +2.976ns vs 20ns clock; Fmax 58.740; setup gate P0-30 PASS by real-clock criterion |
