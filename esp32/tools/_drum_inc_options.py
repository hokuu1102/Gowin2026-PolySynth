# -*- coding: utf-8 -*-
"""_drum_inc_options.py —— 算清"21 位装不下鼓"的三个方案各自要谁改、改多少。

背景：FPGA 鼓机四件的 phase_inc 是 32 位，而我方【下行】inc 字段只有 21 位。
      四个值全部超出 => 鼓的音色必然不对。
本文件把三条路的【实际代价】摆出来，好判断"要不要 FPGA 改"。
"""
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

FS = 48828.125
TWO32 = 2 ** 32
LIMIT21 = (1 << 21) - 1
DRUMS = [("kick", 5368709), ("snare", 42949673),
         ("hihat", 171798691), ("tom", 17895697)]

print("=" * 76)
print("下行 inc 只有 21 位，而鼓机四件是 32 位 —— 三条路各自要谁改")
print("=" * 76)

print("\n[需求侧] 四个鼓的 inc 到底要多少位：")
for name, inc in DRUMS:
    hz = inc * FS / TWO32
    print("    %-6s inc=%-11d f=%8.2f Hz   需要 %2d bit"
          % (name, inc, hz, inc.bit_length()))
print("    21 位上限 = %d => 最高只能表示 %.2f Hz"
      % (LIMIT21, LIMIT21 * FS / TWO32))
print("    => 要让鼓全塞进下行字段，至少需要 %d bit" %
      max(inc.bit_length() for _, inc in DRUMS))

print("\n" + "-" * 76)
print("方案 A：FPGA 改 —— 收到 axis=15 时，用 inc 低 2 位查表换真 inc")
print("-" * 76)
print("    谁改：⭐ 只有 FPGA 侧（RTL）")
print("    改什么：一个 4 选 1 mux + 一张 4 项常量表")
print("    PC 侧：把鼓件号（0..3）填进 inc 字段低位 —— 已有映射表，改一行")
print("    ⭐ 代价最小：不重排 64 位字、不动协议版本、不需要双方重新冻版")
print("    ⚠️ 但需要他们加逻辑并重跑 PnR")

print("\n" + "-" * 76)
print("方案 B：双方都改 —— 把下行 inc 从 21 位加宽到 28/32 位")
print("-" * 76)
used = 20 + 21 + 4 + 8 + 2 + 2      # tick+inc+axis+vel+kind+timbre
free = 64 - used
print("    当前 64 位字已用 %d 位，空闲 %d 位（bit[%d:0]）" % (used, free, free - 1))
need = max(inc.bit_length() for _, inc in DRUMS) - 21
print("    要把 inc 从 21 加宽到 %d 位，需额外 %d 位 => %s"
      % (21 + need, need, "空闲位不够！" if need > free else "够用"))
print("    => 必然要动其他字段 => 重排整个字")
print("    谁改：⭐ 双方都改，而且要先【冻结新协议】")
print("    改什么：mid2evt.py / RTL 的 evt 解码 / score_word.py / 全部工具")
print("    ⚠️ 代价最大；好处是一劳永逸（将来别的乐器也不会再撞位宽）")

print("\n" + "-" * 76)
print("方案 C：FPGA 改 —— 鼓不走事件字，走【专用命令】")
print("-" * 76)
print("    依据：他们答复 §五 提到键盘 'K' 打鼓【用的是同一组常量】，")
print("          且有判据直接拿 drum_gen 的输出逐件比对。")
print("          ⭐ 说明【键盘打鼓本来就不走下行事件字】。")
print("    那么 PC 侧的鼓可以走【同一条路】（命令 + 鼓件号 + tick）")
print("    ⚠️ 但这需要他们明确那条路的接口（现在只有键盘用它）")
print("    ⭐ 好处：完全不碰 64 位字")

print("\n" + "=" * 76)
print("结论")
print("=" * 76)
print("    ⭐ 三条路【都需要 FPGA 侧动手】—— 因为下行字段是他们在解码，")
print("       而四个鼓值根本放不进 21 位。区别只在【他们改多少】：")
print("         A（低 2 位查表）   最小：几行 RTL")
print("         B（加宽字段）      最大：重排协议、双方同步")
print("         C（走专用命令）    中等：要他们先定义接口")
print()
print("    ⚠️ 我方（PC 侧）无论选哪条都能配合，且改动都很小 ——")
print("       因为映射表已经建好了（esp32/tools/drum_map.py）。")
print("    📌 所以问题不是'要不要他们改'，而是【请他们从三条里挑一条】。")
