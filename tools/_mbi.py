"""一次性：把 MBI5024 的选型结论写进文档。"""
import subprocess
import os

Q = chr(34)
OLD = ("| ⭐ **恒流 LED 驱动 `TLC5928`**（或引脚兼容的 `MBI5024` 系） | **1** | ⭐ **一颗管 16 路**，恒流 sink，电流由**一颗外接电阻 `R_ext`** 设定 → 目标 **10~14 mA/路**")

NEW = """| ⭐ **恒流 LED 驱动 `MBI5024GF`**（SOP24-1.0） | **1** | ⭐ **一颗管 16 路**，恒流 sink，电流由**一颗外接电阻 `R_ext`** 设定 → 目标 **10~14 mA/路**

⭐⭐ **定案：`MBI5024GF`（选 GF 不选 GP）**
- **GF = SOP24-1.0**，引脚间距 **1.00 mm** → ✅ **手焊友好**
- ⛔ **GP = SSOP24-0.635**，间距 **0.635 mm** → 手焊很难（易连锡），除非用钢网 + 回流焊
- 面积差：GF ≈ 7.6×13.0 mm ／ GP ≈ 6.0×8.7 mm —— 我们板面够，**不值得为省 47 mm² 去焊 0.635 mm**

🔴 **必须同时买：`74HCT125`（或 `74AHCT125` / `74AHCT1G34`）—— 3.3V→5V 电平转换**
- 原因：MBI5024 的 **VDD = 4.5~5.5 V（5V only）**，而 **`VIH(min) = 0.7 × VDD = 3.5 V`**
  → ⛔ **FPGA 的 LVCMOS33 输出（VOH ≈ 2.9~3.1 V）够不到门限**
- 按"**设计用最小/最大值，绝不用典型值**"这条自家规矩 → **必须按 3.5 V 设计 → 必须做电平转换**
- `74HCT125` 的 `VIH = 2.0 V`（输入兼容 3.3V），输出 5V 摆幅；**四路正好够**（`SDI`/`CLK`/`LE`/`OE`）
- ⚠️ `SDO` 是 5V→3.3V 方向，我们**不用**（仅级联用），无需处理

**`R_ext` 取值**（手册第 8 页公式：`Iout = (1.20V / R_ext) × 15`，即 `R_ext(Ω) = 18000 / Iout(mA)`）

| 目标电流 | `R_ext` |
|---|---|
| 10 mA | **1.8 kΩ** |
| 12 mA | **1.5 kΩ** |
| 14 mA | **1.3 kΩ** |

（手册自验：600 Ω→30 mA、1 kΩ→18 mA ✅）"""

PAIRS = [(OLD, NEW)]

tracked = subprocess.run(['git', 'ls-files'], capture_output=True).stdout.decode('utf-8').split('\n')
targets = [p for p in tracked if p.strip().endswith('.md') and not p.startswith('files/历史/')]

for old, new in PAIRS:
    hit = False
    for p in targets:
        if not os.path.isfile(p):
            continue
        t = open(p, encoding='utf-8').read()
        if old in t:
            open(p, 'w', encoding='utf-8', newline='').write(t.replace(old, new))
            print('OK  ' + p)
            hit = True
    if not hit:
        print('MISS ' + old[:60])
