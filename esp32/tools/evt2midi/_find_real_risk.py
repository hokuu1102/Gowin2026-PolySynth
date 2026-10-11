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


def case(name, data, expect_sm, expect_nv=None, note=""):
    """
    ⭐ 对照跑一遍：⭐ **状态机（本工具）** vs **扫描式（无校验）**。

    ⚠️ 2026-10-01（加固）：⭐ `expect_sm` 与 `expect_nv` **分开给** ——
       🔴 旧版两边共用一个期望值 ⇒ ⚠️ 于是"**状态机正确地拒收坏帧**"
       会被打成 RED（🔴 把**正确行为**当成失败），⭐ 结论就反了。
       ⭐ 正确的期望：⭐ **被破坏的那一帧，数据真的丢了** ⇒
       状态机应当**只报出剩下的好帧 + 坏帧计数**，⛔ 而不是"还原"出原始值。
    """
    if expect_nv is None:
        expect_nv = expect_sm
    evs, st = parse_stream(data)
    nv = naive_scan(data)
    got_sm = truth(evs)
    got_nv = [k for _, k in nv]
    sm_ok = got_sm == expect_sm
    nv_ok = got_nv == expect_nv
    print("  %-42s 状态机 %s   扫描式 %s"
          % (name, "OK " if sm_ok else "RED", "OK " if nv_ok else "RED"))
    if not nv_ok:
        print("       扫描式拿到 %s（期望 %s）" % (got_nv, expect_nv))
    if not sm_ok:
        print("       状态机拿到 %s（期望 %s）" % (got_sm, expect_sm))
    if note:
        print("       ⭐ %s" % note)
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
    # ⚠️ 这一帧的数据**真的被破坏了** ⇒ ⭐ 期望：状态机只留【剩下的好帧】+ 坏帧计数
    broken = f1[:3] + f1[4:] + f2
    case("C1 帧内丢 1 字节", broken, [2000], [256003],
         "🔴 扫描式输出 256003（⚠️ 看似合理，⭐ 其实那帧已经坏了）")
    # ⭐ 整帧丢头字节
    broken2 = f1[1:] + f2
    case("C2 帧头被吞", broken2, [2000], [2000],
         "⭐ 两边都只剩第二帧（⭐ 第一帧的头没了，谁也认不出来）")

    print("\n【D】帧内混入一个 0xA5（⭐ 模拟位翻转）")
    flip = bytearray(f1); flip[6] = 0xA5   # tick 中间
    case("D1 载荷被改成 0xA5", bytes(flip) + f2, [2000], [933, 2000],
         "🔴 **933 就是这里来的** —— ⭐ 扫描式拿错位数据当帧头，"
         "读出 933（⚠️ 看起来像个正常值，⭐ 但它是错的）")

    print("\n【E】ASCII 与帧交错")
    case("E1 ASCII 夹在中间", f1 + b"st" + f2, [1000, 2000])

    print("\n" + "=" * 78)
    print("结论（⭐ 用数据说话）")
    print("=" * 78)
    print("""
⭐ A/B/E：两边【都能对】——
   ⚠️ 因为"见 0xA5 就吃 14 字节"**不会去检查帧内载荷**，
      载荷里的 0xA5 被【整帧跳过】了。
   🔴 ⇒ **我原来那条"载荷含 0xA5 会让扫描式失步"的说法【是错的】**。

🔴 C/D：**真正的问题是"坏数据伪装成好数据"** ——
   · ⭐ 扫描式（无校验）：⭐ **照样输出一个数**（C1 得 256003、D1 得 **933**），
     🔴 而且**它没有任何办法知道自己错了**（⚠️ 这才是最危险的）
   · ⭐ 状态机（本工具）：⭐ **拒收坏帧 + 计数**，⭐ 只输出能确认的好帧
     ⚠️ 它**救不回**被破坏的那一帧（数据真的丢了），
     ⭐ 但它**会告诉你丢了** ⇒ 🔴 这就是"可判"与"不可判"的差别

📌 一句话：🔴 **风险不是"失步"（那你看得出来），而是"错值看起来正常"（你看不出来）。**
   ⇒ ⭐ 所以本工具的核心是 **校验 + 坏帧记账**，⭐ 而不是"怎么找帧头"。
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
