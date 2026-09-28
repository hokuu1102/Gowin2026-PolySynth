"""精确推演 ADSR 为什么停在 env=140, state=ATTACK, releasing=1。

已知（note_manager + adsr 代码）：
  · retrig_reset_r 只在【RT_LOW 期间】或【ST_COMMIT 那一拍】拉高
  · 实测挂在 dly=1705 / 2046 这两档

观测值：state=1(ATTACK) releasling=1 env=140 peak=51200 sus=12800 gate=0

关键：这是【静默 600 tick 之后】的值 => env 必须是在【稳态循环】
"""

print(__doc__)
print()
print("=== 若 retrig_reset 偶尔拉高一次，env 会怎样？ ===")
print("  tick 0: reset => env=0, rel=0, state=ATTACK")
print("  tick 1: rel=0, gate=0, state=ATTACK")
print("          => 走 '!gate_i && state != IDLE' => rel<=1   (env 不变 = 0)")
print("  tick 2: rel=1 => env(0) <= RELEASE_STEP(2)? 是 => env=0, rel=0, state=IDLE")
print("  tick 3: state=IDLE => env=0, 若 gate=0 则不动")
print("  => 归零，安全。")
print()
print("=== 但实测 env=140 != 0，且 state=ATTACK ===")
print("  => 说明 env 在【被加】(ATTACK 语义) 而非减")
print()
print("  ATTACK 分支：env <= env + 669   (每 sample_tick)")
print("  但要进 ATTACK 分支，需要 rel=0 且 gate=1 ... 而 gate=0")
print()
print("  *** 所以只有一条路：retrig_reset 反复拉高 ***")
print("     reset => state=ATTACK, rel=0, env=0")
print("     下一个 tick: gate=0, rel=0 => 走 else 分支 => case(ATTACK)")
print("        env(0) + 669 >= peak? 0+669=669 < 51200 => env <= env+669 = 669")
print("     再下一个 tick: 若 reset 又拉高 => env=0 (循环)")
print("     => env 只能在 [0, 669] 之间摆，不会停在 140 且【不变】")
print()
print("=== 等等，实测是【采样一次】得到的，不是逐拍 ===")
print("  600 tick 之后读到 env=140 —— 可能正好是一个循环中的某一点")
print("  => 关键判据不是 env 的具体值，而是【它永远不为 0】")
print()
print("=== 结论：retrig_reset 必须一直在拉高 ===")
print("  查 note_manager：retrig_reset_r 在 RT_LOW 期间【电平】拉高")
print("  => 若 retrig_state 卡在 RT_LOW => reset 恒高 => ADSR 永远归零中")
print()
print("  *** 但追踪显示 rt_state=0 (RT_NONE) ***")
print("  => 矛盾！需要再看 voice 0 的 retrig_reset_i 实际值")
