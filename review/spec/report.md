# 软件 Spec 轴审查：cd63b0773480e43b19d47f7b541d202a0a66df4d

审查固定点：`b6f83bbebf0219d49a77e4fe306f9bffddbecc8e`（初始无代码），使用 `git diff b6f83bb...cd63b07 -- esp32 tools` 与相关提交记录。主程序未改；本报告的探针、依赖环境和输出只写在 `review/spec/`。本软件审阅未连接串口、BLE 或实板，未烧录；主审物理构建及审查材料本地归档见主报告。

## 摘要（Spec）

确认 5 类现行功能问题：回传卷帘丢和弦、MIDI 力度损坏、原始流导出为空、BLE 发送失败丢数据、STOP/RESET 与放水任务竞态。另确认现有回归失效（1类验证债）与历史 Python 回传工具协议漂移（1类历史工具问题）。MIDI 松键配对仅证实特定输入会失败，未证默认生产可达，单列疑点，不计正式发现。没有确认额外需求或范围扩张问题。

四音色分成四个命名 MIDI 轨、旧 byte7 的 64 种轴/音色组合、两小节静音准备、准备段初始 BPM 与中段换速时间轴均通过新增探针。不能把这些通过外推成实板整机通过。

## 可重复执行与证据

在工程根目录运行：

```powershell
python review/spec/run_probes.py
```

脚本将输出每项真实退出码并写 `results.json`。预期整体退出 1，因为探针以正常需求作为断言，当前生产代码会判红；没有把 bug 当成应通过行为。依赖已隔离安装在 `review/spec/venv/`：pyserial、mido、bleak、numpy。最初缺包产生的失败只属环境问题，最终自检已补齐依赖后重跑。C 编译器使用本机已有 `D:/cyx/Dev-Cpp/MinGW64/bin/gcc.exe`；ESP 的内存/锁/时间/UART 调用用宿主桩控制，业务函数来自未修改的生产 C 文件。

完整 runner 连续独立执行两次，结果相同；第一次退出清单为 `results-run1.json`、第二次为 `results.json`，命令汇总在 `repeat-run.log`、`repeat-run2.log`。真实 top→网页卷帘 RED、力度128 RED、bin RED、C notify RED、C STOP/RESET RED 均两轮重复；正控制亦两轮通过。网页共6个红断言含 Q1 疑点与 S1 的不同场景，不等于6个独立正式发现。

| 命令（根目录） | 退出 | 实测 |
|---|---:|---|
| `node review/spec/web_probe.js` | 1 | 6 个 RED 断言；其余控制组/时间轴/分轨/兼容性 PASS |
| `review/spec/venv/Scripts/python.exe review/spec/python_probe.py` | 1 | A4 反算失败；8 种 byte7 元数据未进入 Event |
| `python review/spec/host_probe.py` | 1 | 编译 0；正常发送 PASS；失败发送保留字节 RED |
| `python review/spec/pool_interleave_probe.py` | 1 | 编译 0；无切换 PASS；STOP、RESET 切换均 RED |
| `review/spec/venv/Scripts/python.exe esp32/tools/selftest_all.py -v` | 1 | 44 工具，8 不通过；汇总 913 项 OK、5 项 RED，不能当 913 个独立需求验证 |
| `python esp32/tools/_check_html_js.py` | 0 | 3 个现行网页全部内联 JS 语法通过 |
| `python review/spec/inventory.py` | 0 | 151 软件源码文件清单；全部 Python AST 通过 |

## 已确认问题

### S1 [P1] 真实 top 上行进入网页后丢失和弦

需求原句：`files/20-代码/问题清单-留队友修-20261018.md:33`：“回传（上行）收到的音符，在卷帘（piano roll）上显示不全 —— 看起来比实际收到的少。”

生产原因：`rtl/top.v:7023` 将乐音的 `up_drum_mark_w` 置 0，`:7042` 用其作为上行 axis。网页 `esp32/tools/score_studio.html:4688-4705` 只以 `axis & 15` 存在 `Map` 中，后来的 on 覆盖先前的 on，第一次 off 关闭后其余 off 无匹配。这里的问题是两端组合行为，不单独把旧文档中“低位是鼓标记”判为违规。

真实测试：RTL 审查方执行 `tb_top_axis_review.sv` 后产出 `review/standards/top-axis-frames.hex`；本探针直接读其 56 字节，喂进生产网页完整内联脚本的 `uPushBytes` 和真实 `uDraw`，只用 DOM/canvas 桩记录真实 `fillRect` 调用。4 帧正确解成 on69/on73/off69/off73，axis 全 0，实际音符块 **1**，应为 **2**。独立轴 0/1 的同一组合绘出 **2** 块为正控制；同轴旋律+两件鼓的组合只绘 **1** 块。`web-probe.log` 保存完整事件及画块坐标。可修复保留音符身份的上行字段及网页匹配，不能仅声称前端 axis 修复已经完成。

### S2 [P1] STOP/RESET 与 pump 解锁后发送竞态，停止后仍可发新的 note_on

需求原句：`files/20-代码/上机手册-ESP32与上位机-20261017.md:248`：`0x04` 停止的验收是“声音停；游标停住”。`:245` 清池验收为“FPGA 丢弃已灌的事件；游标归零”。

生产位置：`esp32/ble/main/pool.c:997` 保存池内指针；`:1053` 解锁；`:1059-1062` 仍执行 UART 写并递增全局游标。停止在 `:678-684` 仅按当时已发游标补发 off；它无法覆盖稍后旧 pump 才发送的 on。RESET 同时会清 `s_frames/s_play_idx`，随后旧 pump 又把游标加成 1。

真实测试：`pool_interleave_probe.py` 直接 `#include` 未修改的完整 `pool.c`，在 mutex give 桩上模拟一次合法任务切换，调用真实 `pool_stop()` 或 `pool_reset()`，其余流程继续执行真实 `pool_pump()`。正常对照 tx=1；STOP 后实测 **tx=1、idx=1、running=0**；RESET 后 **tx=1、frames=0、idx=1、running=0**。run=1，日志 `pool-interleave.log`。证明存在可执行竞态；实板出现概率及最终可闻挂音时长未测。

### S3 [P1] BLE notify 失败后，上行字节已被永久消费

需求原句：`esp32/ble/main/up_ring.h:45-46`：“发了的就存进来，需要传回 PC 的时候传回 PC”以及“完整性 > 新鲜度”。`:68` 将 out 定义为“成功出环（已交给 notify）”。

生产位置：`esp32/ble/main/ble_main.c:1733` 先 `up_ring_pop`；`:1749-1754` 发送失败只计数并 break，没有保留未发送部分，pop 已在 `up_ring.c:222-226` 消费数据并增加 out。

真实测试：`host_probe.py` 编译未改 `up_ring.c`，自动逐字提取生产 BLE 放水块并执行，只有 SDK 调用桩。正常 28 字节发送：tx=28、level=0。仅让 notify 返回一次失败：**tx=0、level=0**，out 仍增加 **28**。run=1，日志 `host-probe.log`。失败已计次数，但字节不能重试，out 也不等于成功发送量。未测真实 BLE 拥塞概率。

### S4 [P2] 合法 8 位力度 128 导成 MIDI velocity 0，音符被当成松键

需求原句：`esp32/tools/evt2midi/frame_format.py:40`：“[12] vel 8 位（0..255）”；`rtl/w3c/evt_upstream.v:53` 生产默认 VEL_W=8，`rtl/top.v:7033` 明确同值。MIDI 读侧自身的规范说明 `esp32/tools/evt2midi/midi_verify.py:24`：“note_on 力度 0 = note_off”。

生产位置：`score_studio.html:4805-4806` 用 `e.vel & 0x7F`，不是从 8 位缩放/夹紧。真实帧 vel=128 → 导出 BASS 轨 `90 45 00`，应发声的 note_on 变成 note_off。`web-probe.log`：note=69、status=144、vel=0。必须转换有效范围并保证有效 note_on 不变成零力度。

### S5 [P2] 原始 bin 导出仅保存解析残余，完整收到的数据为零字节

需求原句：现行网页按钮提供“导出 .bin”（`score_studio.html:342` 上行面板按钮；同一保存动作位于 `:4823-4826`），输出名为 `upstream.bin`。

生产位置：`score_studio.html:4823` 用 `U.buf` 构造 Blob；`:4525` 已从 buf 移除正常解析的帧。探针通过真实按钮 onclick、真实 Blob 和 URL.createObjectURL 桩截获导出，不替代按钮实现。输入合法 28 字节、events=2、buf=0，输出 Blob **0 字节**。若最后存在半帧，导出的还只是半帧。独立 `upstream_studio.html:617` 同一错误，现行统一网页为主要问题。日志 `web-probe.log`。

## 待证实疑点，不计正式发现

### Q1 MIDI off 直接采用 off 帧的音高，特定输入下不能关闭对应 on

需求原句：现行代码对上行契约的描述 `score_studio.html:4678-4682`：“note_off 那一拍的 vel 是脏值，inc 同理”“off 的 midi 不可靠”。卷帘已按此改为取 on 的音高，但 MIDI 导出仍未遵守相同语义。

生产位置：`score_studio.html:4802-4806` 对 on/off 均直接写 `e.midi & 0x7F`，没有记住 on 音高。喂合法校验帧 on A4/axis0、off inc0/axis0，导出是 **on69、off0**，69 没有对应 off。日志 `web-probe.log`。这是协议输入探针；没有以实板或端到端真实生成路径证明 off inc0 在默认生产路径可达，因此**不计已确认工程 bug，不声称实板挂音已复现**。非零但改变音高的 off 在函数层受相同影响，亦需生产可达性验证。

## 验证完整性问题与历史工具（单独列示）

### V1 [P2] 现有离线自检不是全绿，部分关键网页检查根本未进入断言

需求原句：`esp32/tools/selftest_all.py:19`：“一条命令跑完全部工具的自检”；`:7`：“不需要硬件”。

补齐依赖后 44 个工具中 8 个退出非零，完整日志 `selftest-complete.log`。4 个 JS 脚本 `_display_check.js:35`、`_midi_parse_check.js:73`、`_upstream_parse_check.js:44`、`_drum_track_check.js:35` 求值导出不存在的 `DRUM_AXIS_BASE`/`drumNameOfInc`，因此在核心断言前退出；`_chord_axis_check.js` 鼓型断言过时；`check_drum_split.py` 被自检执行器无参启动，argparse 退出 2；`run_all_tests.py --selftest` 发现漏登记；`_axis_dep_check.py` 的静态硬断言扫描退出 1（不据此新增功能 bug）。不能使用旧文档中的回归全绿数字代替这次实跑。

### L1 [P3] 历史 Python 回传 CLI 未同步完整上行 phase_inc/元数据

现行主手册 `bringup/39-上机手册-全项目-20261017.md:393`：“上位机只走网页（HTML）”，因此本项不冒充当前主用户路径故障。

CLI 自述需求 `esp32/tools/evt2midi/evt2midi.py:6`：“读上行录制文件 → 解析 → 写成标准 .mid”；生产 `rtl/w3c/evt_upstream.v:26` A4 全宽增量=38702840。`evt2midi.py:123` 仍乘50MHz，实际反算 **450560.357 Hz**，`hz_to_note`=None；应为440Hz/69。真实 Python 函数调用已确认，`python-probe.log`。`:140` Event 字段也没有 timbre/drum_type，`:449-491` 解析后丢弃这些字段；8种输入帧无法保留音色/鼓型。仅 frame_format 的位掩码正确不等于整个 CLI 已兼容。历史工具若继续保留为可执行，应显式标过时或同步；主网页正确的 A4 换算已经通过对照。

## 覆盖与限制

全目录逐文件覆盖清单见 `coverage.csv`：`esp32/`、`tools/` 下 151 个 `.py/.js/.html/.c/.h` 文件，每项注明机械语法检查、真实运行或仅静态清点。**这不是 151 个文件逐条功能全测通过的声明。** 44 个现有自检及新增探针的真实输出、源码、GCC生成的宿主程序都保留在本目录。生产源码散列固定在上述提交；现有 RTL 回归产生的 `sim/evidence/` 修改由主审查任务负责。

已实际执行：现行统一网页的真实解析/绘图/MIDI/保存动作、准备段改写与变速换算；3网页 JS 语法；现有离线自检；真实上行环和发送块；真实 pool 的受控 STOP/RESET 交错。正控制覆盖分离轴可画两音、正常notify传28字节、无交错pump发1帧、四音色4轨、A4音高、byte7旧格式64组合、2小节准备与tempo保留。

未执行：ESP-IDF 全固件构建、GATT 实际回调/MTU/无线吞吐、FreeRTOS双核真实调度压力、UART实际电气波形、串口屏控件和触摸、SPP旧桥实机、WS2812、浏览器真实canvas像素截图、实板录A后录B及loop导出。已确认的问题依照宿主/RTL联合探针范围报告，不把未测硬件条件写成 PASS。录A后录B混入A是否仍存在，应由主RTL审查方和后续实机验收确认。
