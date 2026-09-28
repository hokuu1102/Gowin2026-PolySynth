"""完整推演 note_manager 的重触发状态机，找出【所有】能导致 gate 残留的路径。

相关信号（note_manager.v）：
  L206  hold_mask[mg] = retrig_hold & (retrig_idx == mg)     -- 只有 1 个 voice
  L207  gate_mask[mg] = gate_r[mg] & ~hold_mask[mg]
  L208  live_mask[mg] = gate_r[mg] | hold_mask[mg] | env_active_i[mg]

状态转换：
  retrig_hold  : L365(复位)=0 · L485(RT_LOW→RT_HIGH)=0 · L519(note_off)=0 · L526(重触发)=1
  retrig_state : L364(复位)=NONE · L484(LOW→HIGH) · L489(HIGH→NONE,需sample_tick)
                 L518(note_off→NONE) · L525(DECIDE→LOW)
  retrig_idx   : L366(复位)=0 · L527(DECIDE)=same_idx

gate_r 的写入点：
  L353 复位=0
  L475 (f) RT_LOW  期间 = 0
  L483 (f) RT_LOW + sample_tick => 1
  L488 (f) RT_HIGH => 1
  L516 note_off 循环 => 0   ★ 用 gate_mask 门控
  L524 (g) DECIDE same_valid => 0
  L559 (g) ST_COMMIT => 1
"""

print(__doc__)
print()
print("=" * 70)
print(" 逐一推演：note_off 到达时 retrig 处于各状态，gate 会不会残留")
print("=" * 70)
print()
print("前提：note_off 在 ST_DECIDE 被处理（L510 分支）")
print()

cases = [
    ("retrig_state = RT_NONE, hold=0",
     "gate_mask = gate_r & ~0 = gate_r",
     "若 gate_r=1 => gate_mask=1 => 清掉  OK"),
    ("retrig_state = RT_LOW, hold=1, idx=N",
     "gate_mask[N] = gate_r[N] & ~1 = 0",
     "*** 跳过 voice N  ***  然后 L518 清 retrig_state/hold"),
    ("retrig_state = RT_HIGH, hold=0, idx=N",
     "gate_mask[N] = gate_r[N] & ~0 = 1",
     "若 gate_r[N]=1 => 清掉 OK"),
]

for (a, b, c) in cases:
    print("  %-42s" % a)
    print("      %-40s" % b)
    print("      %s" % c)
    print()

print("=" * 70)
print(" 关键：RT_LOW 期间 hold=1，是唯一让 gate_mask=0 的状态")
print("=" * 70)
print()
print("  ⭐ 而 L518 会把 retrig_state 清成 RT_NONE、hold 清 0")
print("  🔴 但【gate_r[N] 那一拍没被清】=> 之后没人再清它")
print()
print("  后续会怎样？看 (f) 段：")
print("    · retrig_state 已被 L518 清成 RT_NONE")
print("    => (f) 段两个分支都不成立")
print("    => gate_r[N] 保持【note_off 之前的值】")
print()
print("  note_off 之前 gate_r[N] 是什么？")
print("    · 进 RT_LOW 时 L524 把它清成 0")
print("    · 若此时 sample_tick 还没到 => 仍是 0")
print("    · 若 sample_tick 到了 => L483 抬成 1")
print("  🔴 => 关键是【note_off 落在 RT_LOW 的哪一段】")
print()
print("  ★ 若 note_off 在 RT_LOW 且 sample_tick 已过 => gate_r[N]=1 => 残留 => 挂音")
print("  ★ 若 note_off 在 RT_LOW 且 sample_tick 未过 => gate_r[N]=0 => 安全")
print()
print("  实测 dly 窗口 = 1703..2046 => 落在 RT_LOW 的【后段】")
print("  ⭐ 与上面推论一致")
