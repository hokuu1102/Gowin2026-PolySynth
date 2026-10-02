# 阶段 1 证据归档：evt_merge 同族减宽（2026-10-02）

| 文件 | 内容 |
|---|---|
| `source-hashes.txt` | 改动前 7 个源/约束文件的 SHA256 |
| `regression-serial-full.txt` | **串行**全量回归原始输出（`通过 112 / 共 112`，exit 0） |
| `gowin_build.log` | 只综合门证据（ERROR=0；`Compiling module 'evt_merge(DEPTH=6)'`） |
| `gowin_m0_timing.txt` / `gowin_m0_rsc.xml` | 时序汇总（0/0）与资源报告 |
| `pnr_run_attempt1.log` | PnR 驱动日志（一次干净构建，9 min） |
| `Gowin2026.fs` | 位流 sha256 `9e8a91883f0e3845dc8c3b74937e919918f242c00bf271d5fbfabd597d7dbfeb`（`*.fs` 被 .gitignore 忽略 ⇒ 只在磁盘归档） |
| `pnr-impl/` | 完整 `impl/pnr` + `impl/gwsynthesis`（165.6 MB ⇒ 只在磁盘归档） |

关键结论：Fmax **58.581 MHz** · setup **0** / hold **0** · SETUP #1 slack **2.930** / HOLD #1 slack **0.058** · `evt_merge` 族 **23 → 0**（退出 Top25）。