# 开发中间轮次说明

最终验收使用冻结 RTL 快照的 `tests-diff-age-local/` 与 `tests-regression-age-local/`，避免测试过程中读取到正在修改的主树源码。

- 最初差分运行器的文件列表给路径加引号，Icarus 将引号当作路径一部分，产生编译错误；修复为相对路径列表后重跑。
- 最初差分 TB 的检查循环与激励等待循环共用了 integer j，开发中发现后拆分为 wait_count；最终 TB 无此问题。
- `tests-diff/`：第一版四配置差分全部通过，三项红检全部被检出。
- `tests-diff-final/`：仅将事件使能提到循环外的中间版本，四配置和三红检；该综合尚未完成便被后续局部修正替代，不作为交付版本。
- `tests-regression/` 错用了注释里的旧超时预算：top_sound 300 秒、nm_no_leak 120 秒。原始 TIMEOUT 按失败保留，没有计为通过；transpose 在 300 秒也超时。运行器现使用 sim/tb_all.ps1 的实际 900/300/120 秒预算。
- `tests-nm-no-leak-effective-budget/` 按既定 300 秒重跑第一版，250.64 秒 PASS。
- `tests-top-sound-effective-budget/` 的旧版 top_sound，以及 `tests-regression/` 最后的旧版 e2e，在新变体完整回归开始后被主动终止（2026-10-04 15:53 左右，仅终止明确属于本任务的两个 vvp PID 79552/88688），以免同时写同一路径 CSV。这些退出不能算通过，也不是已证实的 RTL 功能失败；各自运行器记录非零退出。
- `synth-final/` 是仅外提事件使能的中间版本综合，首版资源结果显示年龄共享可能产生额外 ALU 后，主动终止该次 gw_sh（PID 104208，父进程 106860）；未运行 PnR。保留其非零退出记录，不列入资源对比。
- `synth-after/` 是首版完整成功综合；`synth-age-local/` 是恢复 age 本地清零后的变体。所有综合均使用新独立目录，主工程 impl 不受影响。

最终结论以 README 的最终统计为准；不得把上述开发轮次的超时、主动中止或编译错误计成 PASS。
