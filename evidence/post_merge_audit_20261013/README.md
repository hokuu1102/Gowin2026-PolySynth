# 合并版独立检查证据

对象：`f8fb7b3`，独立 ASCII 快照目录执行，未改功能 RTL。

完整结论：`files/20-代码/合并后独立审查-20261013.md`。

- `gowin_build.log`、`Gowin2026_tr_content.html`、`timing_rows.txt`、`Gowin2026.rpt.txt`：本次干净 Gowin 综合/PnR，0 setup / 0 hold。
- `compile_all_summary.log`：144/144 测试台编译，无运行含义。
- `tb_*.log`：本次 27 项回归和完整音频测试通过，与合并阶段测试存在重叠。
- `test_mode_fft_analysis.log`、`test_mode_n*_peaks.csv`：独立 FFT 计数 4/8/16/32；启用档行为测试，不是启用档 PnR。
- `dump_pitch_roundtrip.log`：真实录制导出/播放器及顶层同式解包，音高回灌错误。
- `dump_uart_backpressure.log`：真实 500 kbps UART 链，2 帧只有 14/18 字节。
- `dump_fifo_backpressure.log`：满边界独立复现；下游固定 busy 是合法压力场景。
- `guide_physical_pulse.log`：真实逻辑图案/物理驱动链，SDI 未发出指引位。

诊断 `FAIL` 是实际故障证据，不是回归通过。诊断 `$finish` 可以返回进程 0，因此必须同时检查内容，不能只看退出码。

复现命令：`powershell -NoProfile -ExecutionPolicy Bypass -File evidence/post_merge_audit_20261013/reproduce_findings.ps1`。当前预期退出 1，4/4 红；这表示已知故障确实存在，不是编译失败。

不包含 .fs 二进制。审核位流归档在既定桌面 bitstreams 文件夹，名称含 `NOT_RELEASE`，未上板，未推送。
