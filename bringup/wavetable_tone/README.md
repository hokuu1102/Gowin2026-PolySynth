# W1-2 波表单音上板工程

> **当前状态（2026-09-20）**：RTL、仿真、综合、布局布线、时序分析和码流生成均已完成；
> 因 Tang Mega 60K Dock 板卡尚未到手，实物烧录、440 Hz 听音及示波器测量均为
> **未执行（NOT RUN / DEFERRED）**。在完成下方“上板验收”前，不得标记为“已上板通过”。

这个独立工程用于验证真实链路：

`50 MHz → DDS 相位累加器 → Gowin pROM → I2S → PT8211 → NS4263`

它不会替换正式顶层 `rtl/top.v`。外部端口与正式顶层相同，因此直接复用已经核验的 Dock 引脚与时序约束：

- `clk=V22`，50 MHz；
- `rst_n=AA13`；
- `HP_BCK=Y17`；
- `HP_WS=AB17`；
- `HP_DIN=AA16`；
- `PA_EN_n=AB16`，低有效且有上拉；
- `led_heartbeat=T18`。

## 固定测试配置

- 采样率：`50 MHz / 1024 = 48.828125 kHz`；
- BCLK：`3.125 MHz`；
- 波表：512 点、16 bit、有符号、单周期正弦；
- `phase_inc=38,702,809`，输出约 440 Hz；
- 数字幅度：满量程的 1/4；
- 左右声道输出相同；
- 功放在复位释放约 21 ms 后只产生一个下降沿，进入 AB 桥式模式。

## 重新生成码流

在仓库根目录运行：

```powershell
& '<Gowin安装目录>\IDE\bin\gw_sh.exe' 'bringup\wavetable_tone\build_wavetable_tone.tcl'
```

本机已使用 Gowin EDA `V1.9.12.03` 完成综合、布局布线、时序分析和码流生成。

生成的码流位于：

```text
bringup/wavetable_tone/impl/pnr/wavetable_tone.fs
```

`impl/` 是可再生成的大文件目录，已被 `.gitignore` 排除。

## 上板验收

当前因板卡未到而延期，以下项目均未执行：

1. 先把耳机或扬声器音量调到最低；
2. 使用 Gowin Programmer 下载 `wavetable_tone.fs`；
3. 确认心跳灯闪烁，并逐渐调高音量；
4. 应听到连续稳定的约 440 Hz 正弦音；
5. 断电后重新上电并再次下载，声音仍应一致；
6. 若有示波器，确认 BCLK 为 3.125 MHz、WS 为约 48.828 kHz、DIN 持续变化。

上板听到声音后，才算完成“pROM 初始化数据真实进入芯片并被音频链读取”的最终证明。
