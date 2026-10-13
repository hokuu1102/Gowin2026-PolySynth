# OPT01 — single-module pos_probe performance experiment

Baseline: `be51774`. Only `rtl/w3c/pos_probe.v` is changed in RTL.
Report: `files/20-代码/逐模块无减功能优化记录-20261013.md`.

No feature cuts, no SDC/CST/project-option changes, no automatic programming or push.

## Functional evidence

- `baseline/pos_probe.v`: frozen pre-optimization source; outside the synthesis source tree.
- Baseline and candidate `exhaustive_80.log` / `exhaustive_78.log`: all 4096 values, all 16 channel tags, request snapshot mutation and blocked queue with P/N prefixes.
- `candidate/compile_all_summary.log`: 152/152 compile, not 152 runtime tests.
- `candidate/runtime_summary.log`: 11/11 targeted runtime regressions.
- `candidate/source_sha256.txt`: isolated build source/project/constraint hashes.
- `candidate/Gowin2026_syn_rsc.xml`: synthesis resource view; not the final packed CLS result.

Conversion is fixed 12 clocks rather than 4 clocks (+160 ns at 50 MHz). Packet format and waiting/queue behavior are retained. This is a performance refactor of correct decimal behavior: the same tests pass before and after; no fabricated functional failure is used as a performance baseline.

## Retention rule

`evaluate_result.ps1 -ProjectDir <isolated build>` requires zero setup/hold violations, all four slacks nonnegative, setup slack >=0.060 ns, system Fmax >=56.369 MHz, pixel/serial Fmax >=25/125 MHz, Logic <40173, CLS <=25392, BSRAM <=69 and DSP <=25. Functional regression success is additionally required.

The old timing report parses to its known values and returns Keep=false solely because unchanged resource usage is not an optimization. That is expected, not a failure of the old bitstream.

Final decision: KEEP by the pre-declared gate. Logic 40173→39974, CLS 25392→25315, DSP 25→22, BRAM stays 69, FF +8. System Fmax 56.369→56.389 MHz, setup +0.066 ns, hold +0.134 ns, recovery +1.169 ns, removal +0.055 ns. System timing gain is very small; HDMI removal, hold and pixel/serial Fmax worsened but still pass. Not hardware-accepted.

Candidate: `AD_opt01_posprobe_CANDIDATE_20261013.fs`, SHA256 `0AE5F10A2DFA1D7988456DF953AC8653C94201970535E9BA0277AF05370F5484`, archived beside the unchanged AC bitstream. No automatic programming or push. The newest critical setup path is rec_dump busy → looper ramp_inc write-enable, not P BCD conversion.
