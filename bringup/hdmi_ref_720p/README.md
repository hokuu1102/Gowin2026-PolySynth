# H1：Tang Console 60K 最小 HDMI/DVI 参考工程

该独立工程用于验证 Tang Console 60K 的板载 HDMI TX 通路，不接入主合成器，因而不会改变已经上板确认的音频链路。

它从 Sipeed 官方 [`TangMega-60K-example/cam_dvi`](https://github.com/sipeed/TangMega-60K-example/tree/main/cam_dvi) 裁剪，只保留：

- 官方 `TMDS_PLL`（见下方“已确认的上游频率差异”）；
- Gowin 官方加密 `DVI_TX_Top` IP；
- 官方 `testpattern` 彩条发生器；
- Console/60K 官方 TMDS 差分脚与 `K13` HPD 控制。

摄像头、DDR3、帧缓冲、I²C 和 LED 状态逻辑均未引入。

## 构建

关闭 Gowin IDE 中打开的同名工程，然后在仓库根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bringup\hdmi_ref_720p\build_hdmi_ref.ps1
```

本机 Gowin 不在默认位置时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bringup\hdmi_ref_720p\build_hdmi_ref.ps1 -GwSh "D:\Gowin\Software\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
```

构建成功后会打印 `hdmi_ref_720p.fs` 的实际路径。将该码流以 SRAM Program 方式烧录，连接板载 HDMI TX；预期显示 1280×720 八色彩条。当前官方 RTL 的实测构建像素时钟为 73.333 MHz，对应标准 1650×750 总时序约 59.26 Hz，因此不能把它写成精确的 720p60。

如果显示器报告无信号，先确认 `hpd_en/K13` 确实为高；Sipeed 官方 `cam_dvi` 文档也特别指出该板可能需要主动拉高 HPD。

## 已确认的上游频率差异

Sipeed 官方 `TMDS_PLL_60HZ.ipc` 和 `TMDS_60HZ.sdc` 声明 74.25/371.25 MHz，但同目录实际提交的 `TMDS_PLL_60HZ.v` 使用 `MDIV=22`、`ODIV0=3`、`ODIV1=15`。在 Gowin 1.9.12.03、正确器件 `GW5AT-LV60PG484AC1/I0` 下，工具推导并实现的是：

- pixel：`50 × 22 / 15 = 73.333 MHz`；
- serializer：`50 × 22 / 3 = 366.667 MHz`。

本工程的 SDC 按实际 RTL 约束，避免用错误的名义频率掩盖时序。H2 应重新生成自己的精确 25.2/126 MHz PLL，而不是继续复制这份旧 PLL 参数。

## H1 与 H2 的边界

这是 H1 的“官方参考移植最小例程”：保持官方 720p 时钟和 IP，先隔离验证 TMDS 物理通路。H2 的目标仍是本项目自己的 `640×480 @ 60 Hz` 参数化彩条实现，不能把本工程冒充为 H2 完成。

## 第三方代码

`vendor/sipeed/` 是从 Sipeed 官方仓库裁剪的最小依赖，仅清理了行尾空白，遵循其 Apache License 2.0；许可证见 [`vendor/sipeed/LICENSE`](vendor/sipeed/LICENSE)。其余包装、约束和构建脚本属于本项目。

## 剩余工具告警

最终构建仍有一条 `PR1014`：官方加密 `DVI_TX_Top` 内部的 `clk_d` 使用了通用布线资源。该告警未造成 setup/hold 违例，但由于相关 IP 已加密、当前尚未完成显示器上板验收，仍应作为 H2 上板阶段的风险项跟踪；本 H1 不据此宣称“已经稳定出图”。
