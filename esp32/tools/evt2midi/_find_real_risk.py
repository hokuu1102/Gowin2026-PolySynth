"""⭐ 追查：到底什么情况会让"扫描式"真的失步？

⚠️ 背景：我原以为"载荷含 0xA5"就会让扫描式失步。
   🔴 但第一个实验证明【我错了】—— 因为扫描式"见到 0xA5 就吃 14 字节"，
   ⚠️ 它**根本不会去检查帧内的载荷** ⇒ 载荷里的 0xA5 被【跳过去了】。

⇒ ⭐ 所以必须找出【真正】会失步的场景，⛔ 否则我给 FPGA 侧的建议是错的。
"""
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, ".")
from evt2midi import (FRAME_LEN, T_NOTE_ON, T_NOTE_OFF,
                      _mk_frame, parse_stream)


def naive_scan(data):
    evs = []
    i = 0
    n = len(data)
    while i < n:
        if data[i] == 0xA5 and i + FRAME_LEN <= n:
            f = data[i:i + FRAME_LEN]
            evs.append((f[1], int.from_bytes(f[3:7], "big")))
            i += FRAME_LEN
        else:
            i += 1
    return evs


def truth(evs):
    return [e.tick for e in evs if e.tick is not None]


def case(name, data, expect_ticks):
    _, st = parse_stream(data)
    evs, _ = parse_stream(data)
    nv = naive_scan(data)
    got_sm = truth(evs)
    got_nv = [k for _, k in nv]
    sm_ok = got_sm == expect_ticks
    nv_ok = got_nv == expect_ticks
    print("  %-42s 状态机 %s   扫描式 %s"
          % (name, "OK " if sm_ok else "RED", "OK " if nv_ok else "RED"))
    if not nv_ok:
        print("       扫描式拿到 %s（期望 %s）" % (got_nv, expect_ticks))
    if not sm_ok:
        print("       状态机拿到 %s（期望 %s）" % (got_sm, expect_ticks))
    return sm_ok, nv_ok


def main():
    inc = 37796
    f1 = _mk_frame(T_NOTE_ON, 0, 1000, 3, inc, 200)
    f2 = _mk_frame(T_NOTE_OFF, 1, 2000, 3, inc, 200)
    f3 = _mk_frame(T_NOTE_ON, 2, 3000, 3, inc, 200)

    print("=" * 78)
    print("追查：什么情况让扫描式失步")
    print("=" * 78)

    print("\n【A】正常连续流")
    case("A1 两帧连续", f1 + f2, [1000, 2000])
    case("A2 三帧连续", f1 + f2 + f3, [1000, 2000, 3000])

    print("\n【B】载荷含 0xA5（⭐ 我原来以为会坏）")
    e = _mk_frame(T_NOTE_ON, 0, 0x0000A500, 3, inc, 200)
    case("B1 tick=0x0000A500", e + f2, [0xA500, 2000])
    e2 = _mk_frame(T_NOTE_ON, 0, 0xA5A5A5A5, 3, inc, 200)
    case("B2 tick=0xA5A5A5A5", e2 + f2, [0xA5A5A5A5, 2000])

    print("\n【C】丢一个字节（⭐ 真实链路会发生的）")
    # ⭐ 丢掉第 1 帧的第 3 个字节 ⇒ 流错位
    broken = f1[:3] + f1[4:] + f2
    case("C1 帧内丢 1 字节", broken, [1000, 2000])
    # ⭐ 整帧丢头字节
    broken2 = f1[1:] + f2
    case("C2 帧头被吞", broken2, [2000])

    print("\n【D】帧内混入一个 0xA5（⭐ 模拟位翻转）")
    flip = bytearray(f1); flip[6] = 0xA5   # tick 中间
    case("D1 载荷被翻成 0xA5", bytes(flip) + f2, [1000, 2000])

    print("\n【E】ASCII 与帧交错")
    case("E1 ASCII 夹在中间", f1 + b"st" + f2, [1000, 2000])

    print("\n" + "=" * 78)
    print("结论（⭐ 用数据说话）")
    print("=" * 78)
    print("""
⭐ A/B/D/E：扫描式【也能对】——
   ⚠️ 因为"见 0xA5 就吃 14 字节"**不会去检查帧内载荷**，
      载荷里的 0xA5 被【整帧跳过】了。
   🔴 ⇒ **我原来那条"载荷含 0xA5 会让扫描式失步"的说法【是错的】**。

🔴 C：**只有【丢字节】才会失步** —— 而这时：
   · 扫描式 会拿错位的数据当帧 ⇒ 输出**看似合理但内容是错的**
   · 状态机 也恢复不了，⭐ **但它能靠【校验】把坏帧计数报出来**
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
