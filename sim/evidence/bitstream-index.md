# Bitstream index (append-only, written by tools/archive_bitstream.ps1)

> WHY: `sim/gowin_build.ps1` WIPES `impl/pnr/` at the start of every run,
> and `impl/` is git-ignored -- so an un-archived bitstream is gone forever.
> Archive BEFORE starting a new build.

| archived | label | size MB | sha256 | note |
|---|---|---|---|---|
| 20261016-220458 | v3-cstfix | 19.7 | `316FE958A45C4A8C2F4D29D285783E742F48E1DEA315953341796B9EB3F7AE80` | h5_scope restored; b0cac597 |
| 20261016-220458 | v3-cstfix-2fix | 19.7 | `316FE958A45C4A8C2F4D29D285783E742F48E1DEA315953341796B9EB3F7AE80` | slide+LED fixes NOT yet in this fs; archived before rebuild |
| 20261017-231724 | 20261017-2317-span-removed-release | 19.8 | `D9C07ECB0B7C5D9C37ED835776F59E7F171082873E26DA25A8505040DBB839AE` | span deleted + tmds recovery fix; 34 EP vs 16.4 over-constraint but REAL slack +2.976ns vs 20ns clock; Fmax 58.740; setup gate P0-30 PASS by real-clock criterion |
| 20261018-012818 | 20261018-gear3-lock-3gear-16p4 | 19.7 | `E9466B8FA4DC5285A27A5460A597B77258D21CEC2629DB193376C5E6ADC40D18` | 推子三档+每档锁定+双颤音共存+音量颤音档; EP 28 real slack +3.026ns Fmax 58.913; NOT board verified |
| 20261018-174507 | 20261018-lampA-52p2 | 19.7 | `791692ABB15DD3A36E21E9E3A5A3D2E601DE62CC5F74C17067A0903E82AD1DD9` | piano same-note dual lamp (top.v impl); real slack +0.850 hold 0.183 Fmax 52.218; all gates PASS; NOT board verified |
| 20261018-225540 | 20261018-guide-table-timbre-release | 19.7 | `3BABD6A74B19E4A837E22B7B71EB7822E65CA7DF39E992A08C9C0A9F4009C565` | guide lamp points to the OTHER same-note key (E3->3, B3->11); hand-play unchanged; upstream byte[7] now carries timbre; real slack +3.121 hold 0.183 Fmax 59.245; ALL gates PASS; NOT board verified |
