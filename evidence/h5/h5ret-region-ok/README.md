# H5 + 队友时序优化合并后的 clk_sys 违例：定向区域约束修复记录（2026-10-02）

## 问题
`main`(H5, d0cb8b4) 与队友分支 `timing/evt_merge-20261002`(d9a5808) 合并（本地 2780907）后，
同一份源码连续两次构建结果逐位一致：

- `clk_sys` Actual Fmax **44.757 MHz**，setup 违例 **21**，hold 0
- 最差路径 `g_sound.u_calib_span/reject_o_s0/Q → u_tx_fifo/mem_mem_RAMREG_*_G[1]_s0/D`，
  slack −2.343 ns，**数据路径 22.080 ns（其中布线 20.303 ns ≈ 92%、组合逻辑仅 1.447 ns、
  时钟偏斜 0.000 ns）**；该网在芯片上反复横跨：
  R58C3 → R52C146(+5.532) → R50C38(+3.985) → R50C146(+3.992) → R57C22(+4.822)

对照：队友分支（无 H5）= 58.581 MHz / 0 违例（全路径 slack ≥ +2.930）；
合并前我们的 H5（无队友优化）= 50.110 MHz / 0 违例。
逐文件比对确认：合并后的 RTL 与队友分支**只差 H5 的新增**（rtl/hdmi/* 7 个文件 + top.v 15 行），
`calib_span` / `u_tx_fifo` 双方都没改；无模块重名、工程无 tb 混入、BSRAM 仅用 31/118。

⇒ 结论（经 codex 只读分析复核）：**布线延迟主导的全局布局退化**，不是 SDC 约束错、
也不是合并改坏了回传功能；同时综合映射确有变化（`u_tx_fifo` LUT 65→66、`calib_span` 262→259、
looper 4225→4184）。

## 修复：对回传锥加【宽松、非 exclusive】区域约束
写入 `constr/top.cst`：

```text
GROUP h5_ret = { "tx_byte_*" "u_tx_fifo/*" "g_sound.u_calib_span/reject_o_*" };
GRP_LOC h5_ret R[45:73]C[1:148];
```

Gowin 语法要点（SUG1018 §2.4.1，印刷页 10–12；两句缺一则约束无效）：
- 对象必须是**原语实例**（LUT/DFF/BSRAM/PLL…），⛔ 不能用 `u_tx_fifo` 这类模块名；
- 多个对象写在**一个花括号内、空格分隔**（⛔ 逗号会 CT2000 语法错）；
- 必须带**层次路径**（`u_tx_fifo/*` 可以，裸 `push_ok_*` 会 CT1135 找不到）；
- 区域坐标的列上限为 **148**（超了会 CT1101 `out of chip range(148)`）。

## 结果
| 版本 | clk_sys Fmax | setup 违例 | 最差路径 slack |
|---|---|---|---|
| 合并（无约束） | 44.757 MHz | 21 | −2.343 |
| **合并 + 区域约束** | **50.040 MHz** | **0** | **+0.016**（`note_manager/scan_cnt → best_env/CE`） |

`pixel_clk` 127.906 MHz；器件 C1/I0；`PA1019`/`ERROR` = 0。
原最差路径 `calib_span → u_tx_fifo` **已退出最差路径** ⇒ 定向约束确实治好了它。

## 仍未解决
`clk_sys` 50.040 MHz（+0.08%）**仍低于项目门槛 51.5 MHz / 3%**，且最差 slack 仅 +0.016 ns。
队友在无 H5 时为 58.581 MHz ⇒ H5 的加入仍吃掉约 15%。这是"靠布局救回来"，不是设计余量足够。
按 codex 的建议，正式收敛应由时序优化线在**含 H5 的完整树**上处理（例如在 `top.v:2164–2178`
之后寄存 `{rep_req, rep_byte}` 再参与最终仲裁，并单独处理 looper 的 CE 路径）。