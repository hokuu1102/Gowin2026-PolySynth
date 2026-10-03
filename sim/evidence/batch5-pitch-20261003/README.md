BATCH5 · 端到端音高判据（2026-10-03）证据
=========================================
V2（改 fb_inc[13] ⇒ tb_axis_map 应红）: 🔴 RED ✅  FAIL: fb_inc[13] = 0x0116b4ce, expected 0x0107104e
V1（改 kb_inc[13] ⇒ 全量回归应全绿）: 113 个 tb 里【无一个因音高变红】✅（唯一 FAIL = tb_e2e_key_to_sound 的 600s 超时，隔离复跑 PASS/332s）
   ⇒ ⭐ 缺口 A 成立：键盘表跑调无人管
A 落地（tb_axis_map 加 kb_inc 逐项判据）: ✅ ok: keyboard table: all 16 axes match the confirmed keyboard pitches
V3（新判据能否抓到 V1 的变异）: 🔴 RED ✅  FAIL: kb_inc[13] = 0x0116b4ce, expected 0x0107104e
V4（端到端新 tb）: ⏳ 待 B 落地

⚠️ 顺带发现：tb_all.ps1:238 注释写 tb_e2e_key_to_sound 实测 ~50 s，实际 332 s ⇒ 600 s 预算只剩 1.8x 余量 ⇒ 负载下会误报 TIMEOUT
