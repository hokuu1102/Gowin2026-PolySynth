@@@PRIO=P0|SRC=ANVIL-08|ORIG=P0-1|MOD=rtl/w3c/evt_merge.v,rtl/w3c/seq_arb.v
### 修掉 drop_cnt_o 的恒假饱和判据（16 位计数器回绕、可观测性撒谎）
- **位置**：rtl/w3c/evt_merge.v:361-373、:363-365；rtl/w3c/seq_arb.v:376-384、:378-380；对照正确写法 evt_merge.v:322-323、seq_arb.v:318-329、looper.v:1193-1194
- **现状**：
```verilog
// evt_merge.v:363-365
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                   : drop_cnt_o + push_n;
// seq_arb.v:378-380
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                   : (drop_cnt_o + push_n);
```
- **为什么是问题**：Verilog 自决定位宽规则：`drop_cnt_o`(16) `+` `push_n`(2) ⇒ 和是 **16 位**；`>` 的两个操作数都是 16 位无符号 ⇒ **`x > 16'hFFFF` 恒为假** ⇒ 三元的真分支（那个 `16'hFFFF`）是永远取不到的死代码，计数器就是裸的 16 位加法 ⇒ 回绕。本机 iverilog 实测（%TEMP%\anvil08_probe\t1.v）：`drop=ffff push=3 -> r=0002 (sat would be FFFF)`、`drop=fffe push=3 -> r=0001`、`drop=fffd push=3 -> r=0000`、`T1b: (drop+push)>65535 evaluates to 0 ; (drop==FFFF) is 1`。同一个文件里正确的写法就在旁边（用 `==` 先判满）：evt_merge.v:322-323 `merged_cnt_o <= (merged_cnt_o == 16'hFFFF) ? merged_cnt_o : merged_cnt_o + 16'd1;` ✅；seq_arb.v:318-329 ✅；looper.v:1193-1194 `if (drop_r != 16'hFFFF) drop_r <= drop_r + 16'd1;` ✅ ⇒ 只有 `drop_cnt_o` 这两行写错。后果：`overflow_o` 是 sticky 的（还能看见"曾经溢出过"），但 **`drop_cnt_o` 会在第 65536 次丢弃时静默归零**，随后继续从 0 往上爬 —— 上板/回读诊断会看到"丢了 3 条"，实际丢了 65539 条。这正是 K-106（"容量有限的东西必须能看见"）要防的可观测性撒谎，比"没有计数器"更坏。
- **改法**（两处同改，用同族已验写法，零风险）：
```verilog
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o == 16'hFFFF) ? drop_cnt_o
                                                           : ((drop_cnt_o + push_n > 16'hFFFF)
                                                                 ? 16'hFFFF
                                                                 : (drop_cnt_o + push_n));
```
或更省事、与 looper.v:1193 完全同构：
```verilog
                    overflow_o <= 1'b1;
                    if (drop_cnt_o != 16'hFFFF)
                        drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                      : (drop_cnt_o + push_n);
```
⚠️ 注意第二行仍然要用 17 位中间量（`push_n` 最大 3，`16'hFFFF + 3` 会进位），所以"先判 `!= 0xFFFF` 再走原式"最省心（原式在 `drop_cnt_o ≤ 0xFFFC` 时不会溢出，而 `0xFFFC+3=0xFFFF` 正好不丢）。
- **预期**：收益 = 诊断数字变真（无时序/面积代价，`push_n` 已是现成信号，多一个 16 位比较器 ≈ 16 ALU ≈ 与原有的那个恒假比较器等量替换）；代价 = 0；风险 = 0。
- **怎么验**：①在 tb/w3c/tb_evt_merge.sv 的 DEPTH9 段（:514-539）与 tb/w3c/tb_seq_arb.sv 的 DEPTH9 段（:496-530）各加一条饱和判据：持续制造溢出 ≥ 65536/`push_n` 拍（`push_n=2` ⇒ 32768 拍 ≈ 655 µs 仿真，秒级），然后 `$fatal` unless `drop_cnt_o == 16'hFFFF`；**未修复代码跑出来是 0x0000（32768×2 mod 65536）⇒ 必红**。②反向自证（C83 口径）：把修复回退，日志必须出现你新加的 `FAIL: drop_cnt saturation`。③全量回归 `sim\tb_all.ps1` → "通过数 == 共数"。
- **来源**：ANVIL-08【P0-1】
@@@END
@@@PRIO=P0|SRC=ANVIL-08|ORIG=P0-2|MOD=rtl/w3c/looper.v
### 把 looper 的 BSRAM 读路径 hold 余量做成每次 PnR 后的机械判据
- **位置**：rtl/w3c/looper.v:562（mem 读口）、:596（ep_mem 读口）、:708-709（ep_mem 写口）；impl/pnr/Gowin2026.timing_paths（HOLD 段 :1188-1388）
- **现状**：
```verilog
// looper.v:561-562
    reg [EW-1:0] e_word_r;
    always @(posedge clk_i) e_word_r <= mem[rd_ptr_r];
// looper.v:595-596
    reg [EP_W-1:0] ep_word_r;
    always @(posedge clk_i) ep_word_r <= ep_mem[rd_ptr_r];
```
- **为什么是问题**：impl/pnr/Gowin2026.timing_paths 的 HOLD 段按 slack 升序（最差在前），全表 25 条中 **13 条**的起点是 `u_looper`：第 1 名 slack **0.137** `u_looper/rd_ptr_r_3_s0 → u_looper/ep_mem_ep_mem_0_5_s`（:1188-1199）；第 2 名 0.190 `rd_ptr_r_4_s0 → ep_mem_ep_mem_0_6_s`；第 3 名 0.194 `play_upd_inc_o_9_s0 → u_note_manager/phase_r[31]_9_s1`（跨模块）；第 4 名 0.195 `play_upd_inc_o_11_s0 → u_note_manager/phase_r[31]_11_s1`；第 5~13 名 0.201~0.232 `rd_ptr_r_{2,6,5,8,0,6,5,3,1}_s0 → {ep_,}mem_mem_0_{5,6}_s`。机制：这是短路径 hold —— `rd_ptr_r`(FF) → BSRAM 地址译码 → BSRAM 输出 → `ep_word_r`(FF) 的逻辑极短，数据到达太早 ⇒ 与最小 required time 相比余量最小；hold slack 含时钟偏斜 ⇒ 与布局强相关。战场事实：同源重跑差 **2~3 MHz ≈ 0.7~1.1 ns 周期**，0.137 ns 的 hold 余量在这个噪声面前没有安全边际。交付门槛是 **0 hold**，所以这条是本报告里唯一"会破时序"的候选。
- **改法**（这是约束，不是让你去改 looper 的逻辑）：1. ⛔ 红线：任何把 `mem`/`ep_mem` 从 BSRAM 改成 FF/分布式 RAM 的方案一律否决 —— 那会把读路径逻辑再缩短（BSRAM Tco + 译码 ≈ 2.19 ns 里的一大块直接消失）⇒ 立刻变成 hold 违规（这条直接约束 P3-8 的"共享寄存器阵列"方案）。2. ⛔ 红线：不要在 `rd_ptr_r` → RAM 读地址之间删逻辑（例如把 `rd_ptr_r < cnt_r` 的比较器砍掉），同理会把路径变短；要动只能加。3. ⭐ 可执行动作：P0-2 是验证/流程问题，不是 RTL 问题 —— 每次 PnR 后专门 grep hold 段：
```powershell
Select-String -Path impl\pnr\Gowin2026.timing_paths -Pattern 'u_looper' |
  Where-Object { $_.LineNumber -gt 1187 }        # 1188 起是 HOLD 段
# 判据：条数 ≤ 13 且最小 slack 不下降（记录 0.137 作为基线）
```
若某次重跑 slack 掉到 < 0.05 ns，先怀疑布局、不要先怀疑 RTL（同源重跑差 2~3 MHz 是已知事实），但如果换了 RTL 才掉的，那就是本条的命中。4. ⭐ 若确实需要人为加余量（只在 slack < 0.05 ns 时才做）：在 `rd_ptr_r` 到读地址之间插入一级不可被优化掉的浅逻辑（例如 `(* keep *) wire [CNT_W-1:0] rd_addr = rd_ptr_r | 16'd0;` 之类），代价是 setup 侧 +0.3~0.5 ns —— 安全，因为该路径的 setup slack ≥ 0.851 ns。
- **预期**：收益 = 把交付门槛里"0 hold"这条从"运气"变成"可观测的余量管理"；代价 = 0（本条不改 RTL）；风险 = 不加余量则某次重跑可能 hold 违规。
- **怎么验**：①`sim\gowin_build.ps1` → 看 sim/evidence/gowin_m0_timing.txt 的 `Numbers of Hold Violated Endpoints`（当前 0）与 impl/pnr/Gowin2026.timing_paths 的 HOLD 段首条 slack（当前 0.137）。②制造红（自证判据有效）：临时把 looper.v:562/:596 改成异步读（`wire [EW-1:0] e_word = mem[rd_ptr_r];`）⇒ 读路径逻辑暴增 ⇒ hold 段会立刻不再由 looper 主导（同时综合可能报 IF0008）—— 这条只用来证明"这条路径确实被工具看见"，验完必须回退。③注意：本条任何验证都不要跑 bringup/mutation_test.ps1（它会就地改 rtl/，与本条的红线冲突）。
- **来源**：ANVIL-08【P0-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-08|ORIG=P1-1|MOD=rtl/w3c/seq_arb.v
### 把 tail_plus 的三次条件减法收成一次，并删掉死代码 tail_3
- **位置**：rtl/w3c/seq_arb.v:257-273（tail_plus + tail_1/2/3）、:374；rtl/top.v:3677
- **现状**：
```verilog
// seq_arb.v:258-273
    function [PTR_W-1:0] tail_plus;
        input [PTR_W-1:0] t;
        input [1:0] n;
        reg [SUM_W-1:0] r;
        begin
            r = {{(SUM_W-PTR_W){1'b0}}, t} + {{(SUM_W-2){1'b0}}, n};
            if (r >= DEPTH_C) r = r - DEPTH_C;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            tail_plus = r[PTR_W-1:0];
        end
    endfunction
    wire [PTR_W-1:0] tail_1 = tail_plus(tail_q, 2'd1);
    wire [PTR_W-1:0] tail_2 = tail_plus(tail_q, 2'd2);
    wire [PTR_W-1:0] tail_3 = tail_plus(tail_q, 2'd3);      // 🔴 全文件唯一出现处，从未被读
```
- **为什么是问题**：交付参数 `DEPTH=6`（rtl/top.v:3677）⇒ `PTR_W=3`、`SUM_W=4`、`DEPTH_C=4'd6`。`r = t + n` 的最大值 = `(6-1)+3 = 8` ⇒ 第一次减法后 `r ≤ 2 < 6` ⇒ **第 2、3 次 `if` 的比较结果恒假**（对 `DEPTH=9` 亦然：`8+3=11 → 2 < 9`）。本机穷举验证（%TEMP%\anvil08_probe\t5.v，DEPTH 3..16 × t 0..D-1 × n 0..3）：`T5 one-subtract vs three-subtract mismatches = 0 / 532` ⇒ 三次减法与一次减法逐值等价（`DEPTH ≥ 3` 时）。代价是三份串联的"比较器 + 减法器"直接落在 FIFO 写地址上：`push_*` → `off_*` → `tail_plus` → `mem[]` 地址译码 → FF；每次 `cmp+sub` 在 Gowin 上是 1 级 ALU + 1 级 mux（SUM_W=4 位）⇒ 每次多余的 `if` 给这条路径加 ~2 级，两次 = **~4 级**。而且 `tail_3` 是声明了从没被读的死逻辑（唯一的"三槽写"用的是 `tail_q`/`tail_1`/`tail_2`）。
- **改法**：
```verilog
    function [PTR_W-1:0] tail_plus;
        input [PTR_W-1:0] t;
        input [1:0] n;
        reg [SUM_W-1:0] r;
        begin
            // ⚠️ 前置条件（本模块已由注释要求 DEPTH ≥ 3）：t ≤ DEPTH-1、n ≤ 3
            //    ⇒ r ≤ DEPTH+2 < 2*DEPTH ⇒ 【一次】条件减法必够（穷举 532/532 已证）
            r = {{(SUM_W-PTR_W){1'b0}}, t} + {{(SUM_W-2){1'b0}}, n};
            if (r >= DEPTH_C) r = r - DEPTH_C;
            tail_plus = r[PTR_W-1:0];
        end
    endfunction
```
并删掉 seq_arb.v:273 的 `tail_3`（连同它的 1 个加法器 + 2 个比较器 + 2 个减法器）。`DEPTH` 必须在文件头的参数注释里把"≥3"升格成硬约束（现在只是注释，见 P2-6）。
- **预期**：收益 = FIFO 写地址路径 **−4 级**（`tail_plus` 3 处调用 + `tail_q <=` 1 处 ⇒ 共 4 份，去掉的 2 次 `if` × 4 份 = 8 组 `cmp+sub`，约 **−32 ALU/LUT**）+ 死代码清理；代价 = 0（`DEPTH ≥ 3` 是既有约束）；风险 = 若有人把 `DEPTH` 设成 2 会静默错（现在也错，见 P2-6）。
- **怎么验**：①`sim\tb_all.ps1 -Filter seq_arb` → 判据②同拍相撞不丢（:226）+ DEPTH9 位宽契约（:509）与覆盖 `wraps=%0d`（:528-530）—— DEPTH9 段正好压到"回绕"这条路径，是本改动的天然保护。②反向自证：把 `tail_plus` 的唯一那次减法删掉（不补），DEPTH9 的 `wraps` 计数必须变红。③PnR：`sim\gowin_build.ps1` → 0/0；Gowin2026.rpt.txt 的 `LUT,ALU` 应从 34507 略降。
- **来源**：ANVIL-08【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-08|ORIG=P1-2|MOD=rtl/w3c/seq_arb.v
### 把 seq_arb 的 mem 写从 7 分支优先级链改成 evt_merge 式紧凑写入
- **位置**：rtl/w3c/seq_arb.v:333-375（节选 :338-371）、:242、:320、:528；对照 rtl/w3c/evt_merge.v:338-354、:243-255、:247-252
- **现状**：
```verilog
// seq_arb.v:338-371（链共 7 支，节选）
                    if (push_live && push_score && push_demo) begin
                        if (live_first) begin
                            mem[tail_q] <= pack_src(SRC_LIVE,  live_axis_i,  ...);
                            mem[tail_1] <= pack_src(SRC_SCORE, score_axis_i, ...);
                            mem[tail_2] <= pack_src(SRC_DEMO,  demo_axis_i,  ...);
                        end else begin
                            mem[tail_q] <= pack_src(SRC_SCORE, ...);
                            mem[tail_1] <= pack_src(SRC_LIVE,  ...);
                            mem[tail_2] <= pack_src(SRC_DEMO,  ...);
                        end
                    end else if (push_live && push_score) begin
                        ...
                    end else if (push_live && push_demo) begin
                        mem[tail_q] <= pack_src(SRC_LIVE, ...);
                        mem[tail_1] <= pack_src(SRC_DEMO, ...);
                    end else if (push_score && push_demo) begin
                        ...
                    end else if (push_live) begin
                        ...
                    end else if (push_score) begin
                        ...
                    end else begin
                        mem[tail_q] <= pack_src(SRC_DEMO, ...);
                    end
```
- **为什么是问题**：`mem[tail_q]` 这一个槽的写数据在 always 块里被赋了 **7 次**（8 个分支覆盖它），非阻塞赋值"后写覆盖先写" ⇒ 综合出 **7 级优先级的 2:1 mux 树**，宽度 = `ENT2_W = 3+4+32+8+2+1+2 = 52` 位 ⇒ 单槽数据路径 ≈ 52 × 7 = 364 个 mux 输入 ≈ **7 级 LUT4**；`mem[tail_1]` 另有 4 次赋值（4 级）。而 evt_merge 用同一套功能只写了 3 条语句：
```verilog
// evt_merge.v:338-354（同样 8 种组合，3 条写语句）
                    if (push_a) mem[tail_off(tail_q, off_a)] <= pack_evt(a_src_i, ...);
                    if (push_b) mem[tail_off(tail_q, off_b)] <= pack_evt(b_src_i, ...);
                    if (push_c) mem[tail_off(tail_q, off_c)] <= pack_evt(c_src_i, ...);
```
evt_merge.v:243-255 的"先算槽位、再各写一条"把 8 个分支 × 3 次写 = 24 条压成 3 条，且 evt_merge.v:247-252 自己写了理由："⭐ 3 条写语句覆盖全部 8 种组合，⭐ 且结构上不可能漏" ⇒ 这是同一作者对同一类问题给出的两个不同解法，seq_arb 用了差的那个。
- **改法**（照抄 evt_merge 的手法，语义逐位不变）：
```verilog
    // 槽位：live/score 之间仍由 prio_score_r 定先后（复用已有的 live_first，见 :242），demo 固定占最后一槽
    wire [1:0] off_live  = (push_score && ~live_first) ? 2'd1 : 2'd0;
    wire [1:0] off_score = (push_live  &&  live_first) ? 2'd1 : 2'd0;
    wire [1:0] off_demo  = (push_live ? 2'd1 : 2'd0) + (push_score ? 2'd1 : 2'd0);
                    if (push_live)  mem[tail_plus(tail_q, off_live )] <= pack_src(SRC_LIVE,  ...);
                    if (push_score) mem[tail_plus(tail_q, off_score)] <= pack_src(SRC_SCORE, ...);
                    if (push_demo)  mem[tail_plus(tail_q, off_demo )] <= pack_src(SRC_DEMO,  ...);
```
⚠️ 必须逐条核对三种顺序（`live_first` 的 0/1 × 三源可达组合），`off_demo` 在"live+score+demo 全到"时必须 = 2（而 `off_live`/`off_score` 是 {0,1}），这与现在的 `tail_q/tail_1/tail_2` 分配逐位相同（现在的 3 路分支正是 `live_first? live@0,score@1 : score@0,live@1`，demo@2）⇒ 改完 `push_n`、`tail_q <=`、`cnt_q <=` 三处一个字都不用动。
- **预期**：收益 = 单槽写数据路径 **7 级 → 3 级**（`mem[tail_q]`）、`mem[tail_1]` 4 级 → 3 级；`pack_src` 的 6/6/5 次重复实例由综合 CSE 掉，但 mux 树是真的；代码从 34 行压到 6 行；代价 = 多 3 个 2 位加法器（`off_*`）≈ 6 LUT，远小于省下的 mux；风险 = 中（要逐组合核对槽位），但 tb_seq_arb 的判据③（三源同拍 :320）与 DEPTH9 覆盖（:528）正好压这三路。
- **怎么验**：①`sim\tb_all.ps1 -Filter seq_arb` → 判据③（三源同拍，:320）+ ④b（演示单独，:253）+ ⑦（演示让位，:242）+ ⑪（分源计数，:376）必须全绿；**判据⑪是关键**：它按 `pop_src` 校验"谁在发"，能抓住槽位错配。②反向自证：故意把 `off_demo` 写成 `off_live`（制造两源写同一槽）⇒ 判据②/③的条数必须变红。③PnR：`LUT,ALU` 应从 34507 下降；Fmax 见 §0.1（本模块不在关键路径上 ⇒ Fmax 大概率不动，别拿 Fmax 当收益证据）。
- **来源**：ANVIL-08【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-08|ORIG=P1-3|MOD=rtl/w3c/looper.v
### 把插值向上取整从 (x+2^f-1)>>f 换成 ((x-1)>>f)+1，整块消掉 2^f
- **位置**：rtl/w3c/looper.v:493（2^f 产生）、:508-515（pa_pw 寄存器）、:524-535（使用）、:528-535（x=0 守卫）、:960（pa_pw 装载）
- **现状**：
```verilog
// looper.v:492-493
    wire [4:0]         ramp_f     = flog2(ramp_left);       // ⭐ f = floor(log2(left))
    wire [TICK_W-1:0]  ramp_pw    = {{(TICK_W-5){1'b0}}, 5'd1} << ramp_f;   // ⭐ 2^f
// looper.v:526-527
    wire [PHASE_W:0]   pb_qinc  = (pa_dinc + pa_pw - 1'b1) >> pa_f;
    wire [VEL_W:0]     pb_qvel  = (pa_dvel + pa_pw - 1'b1) >> pa_f;
```
- **为什么是问题**：`ramp_pw`/`pa_pw` 在整个文件里只有上面两处用到（`ramp_pw` 定义 + `pa_pw` 装载 + 2 次使用），它的唯一作用就是 `+2^f-1` 这个"向上取整"项。数学恒等式：对 `x ≥ 1`，`ceil(x/2^f) = ((x-1) >> f) + 1`（**精确相等，不是近似**）。本机穷举验证（%TEMP%\anvil08_probe\t2.v，f 0..6 × x 1..400）：`T2 ceil-identity mismatches = 0 / 2800`。而 `x = 0` 的情形原代码已单独挡掉（looper.v:528-535 的 `pa_dinc[PHASE_W-1:0] == 0 ? 0 : ...`）⇒ 替换后逐位等价。代价：`ramp_pw` 是"常量 1 变长左移"，综合成 **5→20 译码器**（约 10~20 个 LUT4、**2 级**），外加 `pa_pw` 寄存器 **20 FF**，以及阶段 B 里 33 位加法器多出来的一个加数（`+pa_pw` 比 `-1` 多一级进位链参与）。⭐ 注意：这不是那个大头桶形移位器（真正贵的是 `>> pa_f` 对 33 位做 5 级桶形移位 ≈ 165 LUT4），本条只砍 `2^f` 那一块，别夸大。
- **改法**：
```verilog
// ① 删掉 looper.v:493 的 ramp_pw，以及 :514 的 pa_pw 声明、:960 的 pa_pw <= ramp_pw;
// ② 阶段 B 改成：
    wire [PHASE_W:0]   pb_qinc  = ((pa_dinc - 1'b1) >> pa_f) + 1'b1;
    wire [VEL_W:0]     pb_qvel  = ((pa_dvel - 1'b1) >> pa_f) + 1'b1;
// ③ :528-535 的"|diff|==0 ⇒ step=0"守卫原样保留（x=0 时 (x-1) 是全 1，必须靠它挡）
```
- **预期**：收益 = 阶段 A **−2 级** + **−20 FF** + ~20 LUT4；阶段 B 少一个加数；代价 = 0；风险 = 低（`x≥1` 已穷举证；`x=0` 守卫未动）。
- **怎么验**：①`sim\tb_all.ps1 -Filter looper` → tb/w3c/tb_looper.sv 判据⑨（:662-689）：`upd_n > 8`、`upd_vel[0] ∈ [80,240)`、`upd_vel[last] == 240`、`upd_distinct >= 8`、同一轴 —— 这些逐值判据正是"取整方式"的守门员，改错一位就会红。②tb/w3c/tb_looper_tail.sv:598（尾音包络对齐）也要过。③反向自证：把 `+1` 去掉（即变成 floor），`upd_vel[last] == 240` 必须红（到不了终点）。④PnR：`Register` 应从 17039 **−20** 左右。
- **来源**：ANVIL-08【P1-3】
@@@END
@@@PRIO=P1|SRC=ANVIL-08|ORIG=P1-4|MOD=rtl/w3c/looper.v
### 合并 ramp_snap_c 与 ramp_left 的两个 20 位比较器
- **位置**：rtl/w3c/looper.v:488-491、:505-506；阶段 A 定义 :455-457
- **现状**：
```verilog
// looper.v:488-491
    wire [TICK_W-1:0]  ramp_left  = (rend_tick_c > play_tick_r)
                                  ? (rend_tick_c - play_tick_r)
                                  : {TICK_W{1'b0}};
// looper.v:505-506
    wire               ramp_snap_c= (play_tick_r >= rend_tick_c);
```
- **为什么是问题**：`(play >= rend) ≡ ~(rend > play)`（两态下严格等价）⇒ 第二个 20 位无符号比较器是冗余的。一个 20 位比较器在 Gowin 上是 **20 位 ALU/进位链 + 1~2 级**，并且它俩都在阶段 A（looper.v:455-457 把阶段 A 定义为"取操作数 + left + f + 2^f + |diff| + 方向"，实测 **6.2 ns**）；同一个比较结果被算了两遍、还都进阶段 A 的组合锥。
- **改法**：
```verilog
    wire               ramp_gt_c = (rend_tick_c > play_tick_r);   // ⭐ 唯一一次比较
    wire [TICK_W-1:0]  ramp_left = ramp_gt_c ? (rend_tick_c - play_tick_r)
                                             : {TICK_W{1'b0}};
    ...
    wire               ramp_snap_c = ~ramp_gt_c;                  // ⭐ 复用
```
⚠️ 保留 `~` 而不是改成 `<=`：`~` 在 X 传播下与原式同口径（都是 X），换成 `<=` 也是 X，等价；用 `~` 更能一眼看出"复用同一个比较"。
- **预期**：收益 = 阶段 A **−20 ALU、−1~2 级**；代价 = 0；风险 = 0（恒等式，无需仿真证明）。
- **怎么验**：①`sim\tb_all.ps1 -Filter looper` → 判据⑨ 的 `upd_n`/`upd_vel[last]`（:662-666）；以及 tb_looper_tail 的"回放尾音与手弹一致"（:598）—— 吸附点错一位就会红。②反向自证：把 `ramp_snap_c` 恒置 0 ⇒ `ramp_mask` 永不清 ⇒ `upd_n` 必须暴涨到红。
- **来源**：ANVIL-08【P1-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-08|ORIG=P1-5|MOD=rtl/w3c/looper.v
### 删掉插值的 dn 那一臂（阶段 A 少两个比较器、阶段 C 少一级选择）
- **位置**：rtl/w3c/looper.v:495-502（ramp_dn/vel_dn）、:516/:521（pa_dn/pa_vdn）、:539-546（阶段 C）、:946-947/:961-962（装载）
- **现状**：
```verilog
// looper.v:495-502
    wire               ramp_up    = (rtgt_inc_c > ramp_inc_c);
    wire               ramp_dn    = (rtgt_inc_c < ramp_inc_c);
    wire [PHASE_W:0]   ramp_dinc  = ramp_up ? ({1'b0, rtgt_inc_c} - {1'b0, ramp_inc_c})
                                            : ({1'b0, ramp_inc_c} - {1'b0, rtgt_inc_c});
    wire               vel_up     = (rtgt_vel_c > ramp_vel_c);
    wire               vel_dn     = (rtgt_vel_c < ramp_vel_c);
// looper.v:539-546
    wire [PHASE_W-1:0] pc_inc_w =
          pb_up ? ((pb_inc + pb_sinc >= pb_tgt) ? pb_tgt : (pb_inc + pb_sinc))
        : pb_dn ? ((pb_inc - pb_sinc <= pb_tgt) ? pb_tgt : (pb_inc - pb_sinc))
        :         pb_inc;
```
- **为什么是问题**：当 `rtgt == ramp` 时 `dinc = 0` ⇒ 由 looper.v:528-535 的守卫得 `sinc = 0` ⇒ `pb_inc - 0 = pb_inc`，而 `pb_inc == pb_tgt` ⇒ `(pb_inc <= pb_tgt)` 为真 ⇒ 输出 `pb_tgt == pb_inc` ⇒ "都不动"这一支与"dn 支"的输出完全相同，`pb_dn` 那一臂可以删掉。本机穷举验证（%TEMP%\anvil08_probe\t4.v，f 0..4 × cur 0..60 × tgt 0..60，步长 3）：`T4 two-arm equivalence mismatches = 0 / 2205`。收益：阶段 A 少 **1 个 32 位比较器 + 1 个 8 位比较器**（≈ 40 ALU + 1~2 级），少 **4 个 FF**（`pa_dn`/`pa_vdn`/`pb_dn`/`pb_dvn`），阶段 C 的三元选择从 3 选 1 变 2 选 1。
- **改法**：
```verilog
// ① 删掉 ramp_dn / vel_dn（:496、:500）与 pa_dn/pa_vdn/pb_dn/pb_dvn（:516、:521 及全部装载）
// ② 阶段 C 改两臂（语义含"相等"那一支）：
    wire [PHASE_W-1:0] pc_inc_w =
          pb_up ? ((pb_inc + pb_sinc >= pb_tgt) ? pb_tgt : (pb_inc + pb_sinc))
                : ((pb_inc - pb_sinc <= pb_tgt) ? pb_tgt : (pb_inc - pb_sinc));
    wire [VEL_W-1:0]   pc_vel_w =
          pb_vup ? ((pb_vel + pb_svel >= pb_tv) ? pb_tv : (pb_vel + pb_svel))
                 : ((pb_vel - pb_svel <= pb_tv) ? pb_tv : (pb_vel - pb_svel));
```
⚠️ 必须同时删 `pb_dn`/`pb_dvn` 的装载语句（:946-947、:961-962），否则它们变成没人读的死寄存器。
- **预期**：收益 = **−40 ALU、−4 FF、阶段 A −1~2 级**；代价 = 0；风险 = 低（穷举证）。
- **怎么验**：①同 P1-4 的①②（判据⑨ 的 `upd_distinct >= 8` 对"相等轴不再发脉冲"敏感 —— 若等价性搞错，`ramp_mask` 会在起音==终点时被打开或永远不动）。②反向自证：把两臂写反（`pb_up` 分支用减法），`upd_vel[0] < 8'd240` 与 `upd_vel[last]==240` 必红。
- **来源**：ANVIL-08【P1-5】
@@@END
@@@PRIO=P1|SRC=ANVIL-08|ORIG=P1-6|MOD=rtl/w3c/evt_merge.v
### 合并 evt_merge 里两份互斥的环形回绕实现
- **位置**：rtl/w3c/evt_merge.v:260-270（tail_off，2 次减法）与 :279-283（tail_next，1 次减法）、:258-259 与 :357-358（互斥注释）、:339/:345/:351、:359
- **现状**：
```verilog
// evt_merge.v:260-270
    function [PTR_W-1:0] tail_off;
        input [PTR_W-1:0] t;
        input [OFF_W-1:0] n;
        reg   [SUM_W-1:0] r;
        begin
            r = {{(SUM_W-PTR_W){1'b0}}, t} + {{(SUM_W-OFF_W){1'b0}}, n};
            if (r >= DEPTH_C) r = r - DEPTH_C;
            if (r >= DEPTH_C) r = r - DEPTH_C;
            tail_off = r[PTR_W-1:0];
        end
    endfunction
// evt_merge.v:279-283
    wire [SUM_W-1:0] tail_sum   = {{(SUM_W-PTR_W){1'b0}}, tail_q}
                                + {{(SUM_W-2){1'b0}}, push_n};
    wire [SUM_W-1:0] tail_wrap  = tail_sum - DEPTH_C;
    wire [PTR_W-1:0] tail_next  = (tail_sum >= DEPTH_C) ? tail_wrap[PTR_W-1:0]
                                                        : tail_sum[PTR_W-1:0];
```
- **为什么是问题**：`tail_next` 在数学上就是 `tail_off(tail_q, push_n)`（同一函数、同一输入域），但一个写了 **2 次**条件减法、另一个写了 **1 次**；:258-259 的注释还专门论证"最多减两次"就够，而 :357-358 的注释又说"最多减一次"就够 —— **同一个文件里两个互斥的结论**。两份实现都要进 FIFO 写路径：`tail_off` 的 3 个调用（:339/:345/:351）在写地址上，`tail_next`（:359）在 `tail_q` 更新上。穷举结论（同 P1-1 的 t5.v）：`n ≤ 2`（OFF_W=2）时 **1 次减法对所有 DEPTH ≥ 2 都够**；`n ≤ 3`（push_n）时 1 次对 `DEPTH ≥ 3` 够（DEPTH ≥ 3 已是本模块的既有要求）。
- **改法**：二选一，⛔ 不要两份都留。方案 A（推荐，改动最小）：把 `tail_off` 的第二次 `if` 删掉（注释同步改成"1 次，前置 DEPTH ≥ 3"），并把 :359 的 `tail_q <= tail_next;` 换成 `tail_q <= tail_off(tail_q, push_n);`，删掉 :279-283 的 `tail_sum`/`tail_wrap`/`tail_next`（同时 :357-358 的矛盾注释一起删）。方案 B：保留 `tail_next`，把 `tail_off` 改成"先算 `tail_next`、再用 3:1 mux 选槽位"。
- **预期**：收益 = 写地址路径 **−2 级**（3 个 `tail_off` 各少 1 组 `cmp+sub`）+ 删掉一份重复实现（≈ 4 位 ALU ×3）；代价 = 0；风险 = 低（穷举证 + tb_evt_merge 的 DEPTH9 回绕覆盖 :536）。
- **怎么验**：①`sim\tb_all.ps1 -Filter evt_merge` → 判据"碰撞不丢"（:211）、"轮转"（:251）、"单周期"（:270）、"溢出可见"（:288-293）、"三路不丢"（:319）、**DEPTH9 覆盖 `wraps`**（:536）。②反向自证：把 `tail_off` 的减法整块删掉（不补），DEPTH9 的 `wraps=%0d` 必须变红。
- **来源**：ANVIL-08【P1-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-1|MOD=rtl/w3c/evt_merge.v,rtl/w3c/seq_arb.v
### 溢出时按剩余空槽收事件，别再"把本来装得下的也全丢"
- **位置**：rtl/w3c/evt_merge.v:335-374、:272-284、:361-365；rtl/w3c/seq_arb.v:333-385；rtl/top.v:3923；tb/w3c/tb_evt_merge.sv:288-293、:539
- **现状**：
```verilog
// evt_merge.v:272-284
    wire [CNT_W-1:0] cnt_after_pop = pop_now ? (cnt_q - CNT_ONE) : cnt_q;
    wire [SUM_W-1:0] cnt_next      = {{(SUM_W-CNT_W){1'b0}}, cnt_after_pop}
                                   + {{(SUM_W-2){1'b0}}, push_n};
    wire        will_overflow  = (cnt_next > DEPTH_C);
// evt_merge.v:361-365
                end else begin
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                   : drop_cnt_o + push_n;
```
- **为什么是问题**：交付 `DEPTH=6`（rtl/top.v:3923）。最坏情形：`cnt_q = 6`（满）、`pop_now = 1`、`push_n = 3` ⇒ `cnt_after_pop = 5`、`cnt_next = 8 > 6` ⇒ 走溢出分支 ⇒ **3 条全丢**。但弹出之后队列只剩 5 条 ⇒ 实际有 1 个空槽，本可以按优先级收下 1 条（`push_a` 优先）⇒ 每次最坏溢出多丢 1 条、`drop_cnt_o` 多加 2。`DEPTH=6` 时一般情形：溢出时可收 `DEPTH - cnt_after_pop = 6 - cnt_after_pop` 条。
- **改法**（先算能收几条，再按优先级收；⛔ 不要一次改两处，先改 evt_merge）：
```verilog
    wire [SUM_W-1:0] room_w = DEPTH_C - {{(SUM_W-CNT_W){1'b0}}, cnt_after_pop};
    // room_w >= 1 时至少能收 1 条；按 a→b→c 优先级收 min(push_n, room_w) 条
```
配合 :338-354 的三条独立 `if`，只需给每条 `if` 加上"还剩几个名额"的条件（`acc_a = push_a; acc_b = acc_a + push_b; acc_c = acc_b + push_c;` 再比 `room_w`）。`drop_cnt_o` 改成只加 `push_n - 实收条数`。
- **预期**：收益 = 极端过载下少丢事件 + 诊断数字变准（与本项目"能证明的上界"口径一致）；代价 = 多 1 个 `SUM_W` 位减法 + 3 个比较器（≈ 12 ALU）；风险 = **中**（会改变溢出时的行为，tb_evt_merge.sv:288-293 只判"`overflow_o` 置位且 `drop_cnt_o != 0`"，不会红；但 DEPTH9 的软件参考模型（:539）可能比精确条数 ⇒ 必须先在 DEPTH9 段跑一遍再改）。
- **怎么验**：①`sim\tb_all.ps1 -Filter evt_merge` → 若 DEPTH9 参考模型比条数，它会红（那就说明该模型把"全丢"当契约了，本改动应放弃或同步更新参考模型 —— 这是决策点，不是 bug）。②新加判据：构造"满队列 + 弹出 + 3 路同拍"，断言至少 1 条被收下且 `drop_cnt_o == 2`（而不是 3）；未修复代码给 `drop_cnt_o == 3` ⇒ 红。
- **来源**：ANVIL-08【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-2|MOD=rtl/w3c/looper.v
### 让 rec_tick_r 饱和并给出可见性（现在 9.1 分钟后静默坏掉）
- **位置**：rtl/w3c/looper.v:1129-1130、:676-678、:388-389、:729、:736、:1383-1388、:166-178；rtl/top.v:3600、:1506；对照 rtl/w3c/play_seq.v:173-175；tb/w3c/tb_looper.sv
- **现状**：
```verilog
// looper.v:1129-1130
                    if (tick_i)
                        rec_tick_r <= rec_tick_r + 1'b1;
// looper.v:676-678
    wire [TICK_W-1:0] quant_len_w = quant_ok_w
                                  ? (quant_up_w ? (rec_bar_tick_r + bar_len_r) : rec_bar_tick_r)
                                  : rec_tick_r;
```
- **为什么是问题**：`TICK_W = 20`（rtl/top.v:3600）⇒ `rec_tick_r` 在 **1 048 576 tick** 处回绕到 0；`quant_len_w = rec_bar_tick_r + bar_len_r` 是 20 位加法，同样会回绕。本工程 tick 率是常数 `TICK_INC_120BPM`（rtl/top.v:1506）⇒ tick = `2^32 / 164927 = 26042` 拍 = **520.85 µs** ⇒ 回绕时间 = 1 048 576 × 520.85 µs = **546 s = 9.10 分钟**。录音长度只受 `EVT_MAX=2048` 条数限制、不受时间限制 ⇒ 一段"慢速、稀疏"的 10 分钟录音会踩到。踩到后的现象（代码级可推）：`loop_len_r` 变成一个小值（或 0），而 `mem` 里的事件 tick 仍然很大 ⇒ `e_ready` 的 `(e_tick == play_tick_r)` 永远不成立（:729）、`e_more_this_tick` 也永远为 0（:736）⇒ 每个 tick 都推进 `play_tick_r`、`rd_ptr_r` 却卡在第一条大 tick 事件上，只在回绕（:1383-1388）时被清零重来 ⇒ **回放静默变哑**，而 `overflow_o`/`full_o`/`drop_cnt_o` 一个都不会亮。对比同族纪律：play_seq.v:173-175 对同类计数器显式饱和并写进注释（"到上限就不回绕 … 由 `cur_tick_o` 可见"）⇒ looper 这里是口径不一致 + K-106 违反。
- **改法**（照抄 play_seq 的饱和口径）：
```verilog
// ① 录制自增改成饱和（并在饱和时置一个 sticky 标志）
                    if (tick_i && (rec_tick_r != {TICK_W{1'b1}}))
                        rec_tick_r <= rec_tick_r + 1'b1;
                    else if (tick_i)
                        tick_over_o <= 1'b1;         // ⭐ 新增 sticky 观测（或复用 overflow_o）
// ② quant_len_w 的加法改成饱和加法（或直接断言 rec_bar_tick_r + bar_len_r 不溢出）
// ③ 在 :166-178 的 PARAM_OK 区加一条：
        if ((1 << TICK_W) / TICKS_PER_BAR < EVT_MAX)
            $display("ERROR [looper] TICK_W=%0d only covers %0d ticks ...", TICK_W, (1<<TICK_W));
```
- **预期**：收益 = 把"9 分钟后静默变哑"变成"看得见的饱和 + 一条 ERROR"；代价 = 1 个 20 位比较器 + 1 FF；风险 = 低（改的是不可能在正常曲子里发生的分支）。⚠️ 不要为了省事把 `TICK_W` 加宽 —— 那会同时加宽 `rend_tick`/`rec_bar_tick` 等 16×20 FF 与比较器，与 P0-2 的 hold 余量冲突。
- **怎么验**：在 tb/w3c/tb_looper.sv 加一条：把 `tick_i` 连续打 `2^20 + 100` 拍（或直接 `force dut.rec_tick_r = 20'hFFFFF;` 再打 2 拍 tick），断言①`rec_tick_r` 停在 `20'hFFFFF`（不回绕）②新标志置位；未修复代码 `rec_tick_r` 变 0 ⇒ 红。⛔ 跑完必须确认 sim\evidence\tb_looper.log 里有 `PASS:`。
- **来源**：ANVIL-08【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-3|MOD=rtl/w3c/looper.v,rtl/top.v
### 把避让手弹流下移到阶段 C（三级流水打破了"结构上不可能撞"）
- **位置**：rtl/w3c/looper.v:785-789、:929-934、:898-900、:135、:397-408；rtl/top.v:4096-4119、:4113-4115、:2796-2809、:4080；tb/w3c/tb_looper.sv:662-676
- **现状**：
```verilog
// looper.v:785-789
    wire evt_wr_w   = playing && e_ready;
    wire evt_hitA_w = evt_wr_w && (e_axis == ramp_sc);
    wire evt_hitB_w = evt_wr_w && (e_axis == pa_ax);
    wire eng_en_w   = playing && ramp_go && ~live_busy && ~pa_last && ~pb_last;   // ← 避让只在【装载】这一级
// looper.v:929-934（输出来自阶段 C，即 2 拍前装载的那一批）
                    play_upd_valid_o <= pb_msk;
                    play_upd_axis_o  <= pb_ax;
                    play_upd_inc_o   <= pc_inc_w;
                    play_upd_vel_o   <= pc_vel_w;
// top.v:4096-4098 + :4116（碰撞时【手弹赢】，looper 那条被丢掉）
            .vel_upd_valid_i   (vu_valid_r | lp_upd_valid),
            .vel_upd_axis_i    (vu_valid_r ? vu_axis_r : lp_upd_axis),
            .vel_upd_value_i   (vu_valid_r ? vu_val_r  : lp_upd_vel),
            .vel_upd_src_i     (vu_valid_r ? 3'd0 : 3'd4),
```
- **为什么是问题**：`live_busy` 只挡阶段 A 的装载（`eng_en_w`）；而 `play_upd_valid_o` 由阶段 C 发出，其数据是 **2 拍前**装进阶段 A 的 ⇒ `live_busy` 高的那一拍，阶段 C 照样可以发一条 `play_upd_valid` ⇒ looper.v:898-900 与 top.v:4113-4115 两处注释都写的"结构上不可能撞""这里的 mux 只是兜底"**是不成立的**；top.v:4096-4119 的 mux 在真撞上时把 looper 那条更新整条丢掉（`vu_*` 赢），而 looper 自己的注释（:135）写的纪律是"⛔ 不许静默丢"。量级（别夸大）：`vu_valid_r` 是"每 `tick_audio` 扫一个轴"的单拍脉冲（top.v:2796-2809，`tick_audio` = 20.48 µs = 1024 拍）⇒ P(vu 高) = 1/1024；looper 每 tick 连续发 16 条更新（16~18 拍），tick = 26042 拍 ⇒ P(lp 高) = 18/26042 ≈ 1/1447 ⇒ 同拍概率 ≈ 6.8e-7/拍 ⇒ 50 MHz 下 **≈ 34 次/秒**；相对 looper 总更新量（16 × 1920/s = 30720/s）≈ **0.11%**。听感影响可忽略（note_manager 每采样拍 ±8 平滑，top.v:4080），但这是"声称的不变式不成立 + 静默丢"，属于本项目明确要抓的那一类。
- **改法**（三选一，按风险从低到高）：方案 A（推荐，0 风险）：把避让下移到阶段 C：`play_upd_valid_o <= pb_msk && ~live_busy;`（即"要发的那一刻再让"）；代价 = 该轴本 tick 的这一拍更新被跳过，下一 tick 重算（自校正语义已由 looper.v:397-408 的"每拍重算步长"保证）；同时把 :898-900 与 top.v:4113-4115 的注释改成事实。方案 B：把 `live_busy` 打 2 拍（`live_busy_d2`）后再与 `~live_busy` 相或，覆盖整条流水线；代价 = 2 FF，行为 = "手弹脉冲前后 3 拍都不发"，丢得更多但仍是自校正。方案 C：不动 looper，改 top.v 的 mux 为"谁都不是丢"（例如 `vel_upd_valid_i` 用两次脉冲排队）—— ⛔ 不建议：note_manager 只有一组 `vel_upd_*` 端口，要加队列就是改冻结接口。
- **预期**：收益 = 不变式变真、消除 34 次/秒的静默丢；代价 = 方案 A 多 1 个与门；被跳过的更新由"逐 tick 自校正"补回（tb_looper 的 `upd_n > 8` 判据留有余量）。
- **怎么验**：①`sim\tb_all.ps1 -Filter looper` → 判据⑨ 的 `upd_n > 8` / `upd_distinct >= 8`（:662-676）：方案 A 会让 `upd_n` 略微下降，必须仍 > 8（这是"余量"的量化检查）。②新加一条对撞判据（本条核心）：在 tb 里让 `live_vel_valid_i` 与 looper 的更新扫掠故意同拍，断言 `play_upd_valid_o` 那一拍不为 1（方案 A）；未修复代码会给 1 ⇒ 红。③反向自证：把 `eng_en_w` 里的 `~live_busy` 删掉，新判据必红。
- **来源**：ANVIL-08【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-4|MOD=rtl/w3c/looper.v
### 给 looper 的 FSM 未译码状态 6/7 加兜底与可见性
- **位置**：rtl/w3c/looper.v:199-223（状态编码）、:999-1409（整条 if/else if 链）、:1409、:1315、:1419、:162-178；tb/w3c/tb_looper.sv
- **现状**：
```verilog
// looper.v:1409
            end
        end
    end
// looper.v:1315
            end else if (state == ST_HOLD) begin
```
⇒ 链是 `br_leave_w → br_clear_w → br_recpend_w → br_reccancel_w → br_rec_w → br_recst_w → br_close_w → (state==ST_LCLOSE) → (state==ST_HOLD)`，最后一个 `end` 之前没有 `else`。
- **为什么是问题**：`state` 是 3 位，只用到 0..5（ST_IDLE/ST_REC/ST_CLOSE/ST_HOLD/ST_LCLOSE/ST_RECPEND）⇒ **6 与 7 无译码**。若 `state` 因任何原因变成 6/7（单粒子、综合/优化异常、将来加状态时漏改），所有分支都不命中 ⇒ 该拍所有寄存器保持（综合成"使能恒 0"）⇒ **模块永久冻结**，且 `layer_state_o`（:1419）只会报 0，没有任何可见性。本项目自己的纪律是 K-106"⛔ 不许静默失效"，且 looper.v:162-178 已有 PARAM_OK 自检的习惯 —— 唯独 FSM 没有兜底。
- **改法**：
```verilog
            end else begin
                // ⭐ 兜底：未译码状态（3'd6 / 3'd7）⇒ 回到安全态，并【可见】
                state      <= ST_IDLE;
                cnt_r      <= {CNT_W{1'b0}};
                rd_ptr_r   <= {CNT_W{1'b0}};
                play_tick_r<= {TICK_W{1'b0}};
                tick_pend_r<= 1'b0;
                rd_adv_r   <= 1'b0;
                close_mask_r <= 16'd0;
                play_active_r<= 16'd0;
                ramp_mask  <= 16'd0;
                fsm_bad_o  <= 1'b1;          // ⭐ 新增 sticky 观测（或复用 overflow_o）
            end
```
（把现在的 `end else if (state == ST_HOLD) begin ... end` 的最后那个 `end` 后面补 `else` 分支即可，⚠️ 注意 `state == ST_HOLD` 那一支必须仍在 `else if` 里，不能被兜底抢走。）
- **预期**：收益 = 消除"永久冻结且不可见"；代价 = 约 10 个 FF + 一个 3 位 `==` 译码（~8 LUT）；风险 = 低；但必须确认 `state` 只能由本 FSM 赋值（全文件只有 `state <=` 这一处 always 块 ⇒ 成立）。
- **怎么验**：在 tb/w3c/tb_looper.sv 里 `force dut.state = 3'd6;`（或用 deposit）打一拍时钟，断言①`state == ST_IDLE`②新 sticky 标志置位；未修复代码：`state` 仍是 6、且后续所有播放/录制命令全部无响应 ⇒ 红。（`chk_xprop`（A8）不会抓这条，必须显式判据。）
- **来源**：ANVIL-08【P2-4】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-5|MOD=rtl/w3c/looper.v
### 给 ramp_sc 的选轴单独做一级流水，削掉高扇出
- **位置**：rtl/w3c/looper.v:483-487（ramp_sc 的 8 个阵列读）、:1209-1224＋:697-705（close_scan_r 的 6 个阵列读）、:437-447（历史最差路径记录）；tb/w3c/tb_looper.sv:662-676
- **现状**：
```verilog
// looper.v:483-487
    wire [PHASE_W-1:0] ramp_inc_c = ramp_inc[ramp_sc];
    wire [VEL_W-1:0]   ramp_vel_c = ramp_vel[ramp_sc];
    wire [PHASE_W-1:0] rtgt_inc_c = rtgt_inc[ramp_sc];
    wire [VEL_W-1:0]   rtgt_vel_c = rtgt_vel[ramp_sc];
    wire [TICK_W-1:0]  rend_tick_c= rend_tick[ramp_sc];
// looper.v:1209 / :1210-1224 / :697-702
                if (close_mask_r[close_scan_r]) begin
                        mem[cnt_r] <= {..., last_inc_r[close_scan_r], vel_max_r[close_scan_r]};
    wire [CNT_W-1:0] ep_wa_w = ep_w_cls_w ? on_addr_r[close_scan_r]
                             : ep_w_off_w ? on_addr_r[live_axis_i]
                             :              cnt_r;
```
- **为什么是问题**：`ramp_sc` 一次要选 **5 个阵列共 100 位**（32+8+32+8+20）；一个 16:1 mux 每 bit 是 5 个 LUT4、选择位 0/1 各驱动 4 个 LUT（第一级 4 个 4:1）、选择位 2/3 各驱动 1 个 ⇒ `ramp_sc[0..3]` 每根驱动 **100~400 个 LUT 输入**。`close_scan_r` 类似：`close_mask_r[..]`、`on_addr_r[..]`、`last_inc_r[..]`、`vel_max_r[..]`、外加 :697 的 `on_addr_r[close_scan_r]` ⇒ 6 个阵列读。这不是猜：looper.v:437-447 自己记录了历史上的最差路径正是 `u_looper/ramp_sc_0_s1/Q → u_looper/play_upd_inc_o_27_s0/D`（Data Delay **22.852 ns**）—— 扇出与选择逻辑就是那条路径的起点。当前已通过流水解决（setup 段 0 命中），但 `ramp_sc` 仍是本模块最大的单一扇出源，且它现在还在阶段 A 的第一级。
- **改法**（按风险从低到高）：方案 A（推荐，改动小）：把"选轴"单独做一级流水 —— 新增 `reg [3:0] rd_ax_r;`，在 `eng_en_w` 那拍 `rd_ax_r <= ramp_sc;`，下一拍用 `rd_ax_r` 去读 5 个阵列；代价 = 1 拍延迟（每 tick 16 轴 → 17 拍；而每 tick 有 26042 拍预算，且现有实现本来就有 `pa_last`/`pb_last` 造成的 2 个空拍 ⇒ 塞得进去）+ 4 FF；收益 = 把 100 位的 16:1 选择从"与 flog2/减法同拍"里独立出来 ⇒ 阶段 A 明显变浅。方案 B（不推荐）：one-hot 预译码（`sel = 16'b1 << ramp_sc`）；选择位扇出降到 ~6，但每 bit 的 mux 从 5 个 LUT4 涨到约 13 个 ⇒ **+800 LUT**，本器件 LUT 已 57% ⇒ 负收益。方案 C（P3 级）：给 `close_scan_r` 也做同样处理（它只在 ST_CLOSE/ST_LCLOSE 的 16 拍里活，不是每 tick 的稳态路径）⇒ 优先级低于 `ramp_sc`。
- **预期**：收益 = 阶段 A 更浅 + 拥塞下降（CLS 78% 是拥塞指标）；代价 = 方案 A 的 1 拍延迟 + 4 FF；必须复跑 tb_looper 的 `upd_n` 判据（`upd_n > 8` 有余量，但 :676 的 `upd_distinct >= 8` 要盯着）；风险 = 中（动的是插值引擎的时序，不是行为）。
- **怎么验**：①`sim\tb_all.ps1 -Filter looper` → 判据⑨ 全绿（尤其 `upd_distinct >= 8`）。②`sim\gowin_build.ps1` → 0/0 + 看 Gowin2026.rpt.txt 的 `LUT,ALU` 与 Fmax；⚠️ 诚实提醒：本模块 setup slack ≥ 0.851 ns ⇒ Fmax 大概率不动（真正的瓶颈在 note_manager/g_t3 与 tdm_render_mixer，见 §0 表）⇒ 别把 Fmax 当本条的验收证据，用逻辑级数/拥塞看。③反向自证：把方案 A 的 `rd_ax_r` 改回 `ramp_sc`（即取消那一级），PnR 的 `Logic Level` 若从 7 涨回 ≥8，说明这条路径确实被工具看见。
- **来源**：ANVIL-08【P2-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-6|MOD=rtl/w3c/evt_merge.v,rtl/w3c/seq_arb.v
### 给 evt_merge 的 DEPTH 补参数自检并统一互斥的下限注释
- **位置**：rtl/w3c/evt_merge.v:76（参数注释）vs :42-44（文件头）、:107、:284；rtl/w3c/seq_arb.v:78-80；rtl/top.v:3923；tb/w3c/tb_evt_merge.sv:319；tb_all.ps1:18
- **现状**：
```verilog
// evt_merge.v:76
    // ⭐ FIFO 深度。⚠️ 必须 ≥ 2（⚠️ 否则"待发 1 条 + 同拍来 2 条"就装不下 —— 那正是第一版的 bug）
    parameter integer DEPTH   = 4
// evt_merge.v:42-44
//   📌 **深度 4 够不够（⭐ 算过）**：⭐ 要求 `DEPTH ≥ 3`（⭐ "队列空 + 同拍来 3 条"）
//      ⇒ ⭐ 4 满足；⚠️ 而**任何有限深度**在"队列已满 + 同拍来 3 条"时都会溢出
```
- **为什么是问题**：:76 说 ≥2、:42 说 ≥3 —— 同一个文件里两个互斥的下限。真实下限由源数决定：2026-09-30 加了源 C（evt_merge.v:107）⇒ 每拍最多推 **3** 条 ⇒ `DEPTH=2` 时"空队列 + 同拍 3 条"必然溢出 1 条（:284 的 `cnt_next=3 > DEPTH_C=2`）。`DEPTH=2` 是参数允许值（`localparam integer CNT_W = (DEPTH < 2) ? 1 : ...` 还专门为 DEPTH<2 兜了底）。而 rtl/top.v:3923 传的是 6 ⇒ 今天没暴露。同族的 looper.v:162-178 / seq_arb.v:78-80 都有参数自检的传统（PARAM_OK），唯独 evt_merge 没有。
- **改法**（两行）：
```verilog
    initial begin
        if (DEPTH < 3)
            $display("ERROR [evt_merge] DEPTH=%0d < 3 => a 3-source same-cycle burst cannot fit (see file header)", DEPTH);
        if (SUM_W < $clog2(DEPTH + 3))
            $display("ERROR [evt_merge] SUM_W too small for DEPTH=%0d", DEPTH);
    end
```
并把 :76 的"≥2"改成"≥3"，:42 与 :76 的措辞统一。
- **预期**：收益 = 消除"参数踩坑静默丢事件"（K-91/K-106 家族）；代价 = 0（仅 $display）；风险 = 0。
- **怎么验**：用 `evt_merge #(.DEPTH(2))` 例化一个副本跑 tb_evt_merge，日志里必须出现新的 `ERROR [evt_merge] DEPTH=2 < 3`；同时判据"三路不丢"（:319）在 `DEPTH=2` 下必然红（证明 ≥3 是真下限，不是文字游戏）。⚠️ 按 tb_all.ps1:18 的口径，`ERROR` 行本身不算失败，所以这条判据要显式看 ERROR 行。
- **来源**：ANVIL-08【P2-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-7|MOD=rtl/w3c/seq_arb.v
### 在 seq_arb 的溢出分支里优先收 note_off（防挂音保证被溢出推翻）
- **位置**：rtl/w3c/seq_arb.v:230-238（让位规则）、:376-384（溢出分支）、:234-236、:255；tb/w3c/tb_seq_arb.sv:290-301
- **现状**：
```verilog
// seq_arb.v:230-238
    //  ⭐⭐ **2026-09-28 修（防挂音，P1-2）：`note_off` 绝不让位**
    //  🔴 原写法 `demo_valid_i & ~others_going` 会把演示和弦的 3 个 `note_off` 在撞上手弹时【直接丢掉】...
    wire demo_is_off = (demo_kind_i == 2'd1);
    wire push_demo  = demo_valid_i & (~others_going | demo_is_off);
// seq_arb.v:376-384
                end else begin
                    // 🔴 **溢出**：⭐ 丢弃并**记数 + 置 sticky 标志**（⛔ 不静默）
                    overflow_o <= 1'b1;
                    drop_cnt_o <= (drop_cnt_o + push_n > 16'hFFFF) ? 16'hFFFF
                                                                   : (drop_cnt_o + push_n);
                    cnt_q <= cnt_after_pop;
                end
```
- **为什么是问题**：`demo_is_off` 只解决了"准入"（让 `note_off` 能参与推入），但没有解决"准入之后装不下"：一旦 `will_overflow`（:255）为真，`drop_cnt_o += push_n` 把同拍的 demo `note_off` 一起丢掉（:379）⇒ 那个 voice 的 `gate_r` 永久为 1 ⇒ **开机自检后留下常驻音** —— 正是 2026-09-28 那次修复要防的现象。触发条件：队列里已有 `DEPTH-1` 条（DEPTH=6 ⇒ 5 条）且本拍 live+score+demo_off 三条同到，且弹出不足以腾位。实际速率下（手弹 ~10 次/s、曲谱 ≤1/tick）极难发生，但"结构上不可能"与"概率极低"是两回事，而代码注释（:234-236）写的是前者（"允许它与手弹同拍推入（FIFO 深 6，实测占用 ≤2 ⇒ 有富余）"）。
- **改法**（与 P2-1 同一处改动，建议一起做）：在溢出分支里优先收 `note_off`：
```verilog
                end else begin
                    overflow_o <= 1'b1;
                    // ⭐ 释放语义优先：note_off 先占唯一的空槽（如果有）
                    if (demo_is_off && (cnt_after_pop != DEPTH_C)) begin
                        mem[tail_q] <= pack_src(SRC_DEMO, ...);
                        tail_q  <= tail_plus(tail_q, 2'd1);
                        cnt_q   <= cnt_after_pop + CNT_ONE;
                        drop_cnt_o <= (drop_cnt_o + push_n - 2'd1 > 16'hFFFF) ? ... ;
                    end else begin
                        cnt_q <= cnt_after_pop;
                        drop_cnt_o <= ...;   // 见 P0-1 的修正
                    end
                end
```
⚠️ 这条与 P2-1 的"按优先级收满"是同一个机制，实现时合并成一处（先算 `room_w`，再按 `note_off > live > score > demo_on` 的次序收）。
- **预期**：收益 = 让"防挂音"从"概率低"升级成"结构上优先"；代价 = 溢出分支多一个 2 位比较 + 一条写（~8 LUT）；风险 = 中（改的是溢出语义 ⇒ 同 P2-1 的 DEPTH9 参考模型风险）。
- **怎么验**：在 tb/w3c/tb_seq_arb.sv 的⑨溢出段（:290-301）加一条：先把队列灌到 `DEPTH-1`，再在同一拍给 live+score+demo(note_off) 三路，断言输出流里一定出现那条 `kind=1 & src=2`（demo off）；未修复代码必丢 ⇒ 红。
- **来源**：ANVIL-08【P2-7】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-8|MOD=rtl/w3c/evt_merge.v,rtl/w3c/seq_arb.v
### 用隐式扩展替掉参数依赖的零宽复制 {{0{1'b0}}, ...}
- **位置**：rtl/w3c/evt_merge.v:273-275、:260-270、:279-283；rtl/w3c/seq_arb.v:253-254、:258-273；rtl/top.v:3923；rtl/w3c/looper.v:1415；tb/w3c/tb_evt_merge.sv、tb/w3c/tb_seq_arb.sv（DEPTH9 段）
- **现状**：
```verilog
// evt_merge.v:273-275
    wire [CNT_W-1:0] cnt_after_pop = pop_now ? (cnt_q - CNT_ONE) : cnt_q;
    wire [SUM_W-1:0] cnt_next      = {{(SUM_W-CNT_W){1'b0}}, cnt_after_pop}
                                   + {{(SUM_W-2){1'b0}}, push_n};
// seq_arb.v:253-254
    wire [SUM_W-1:0] cnt_next = {{(SUM_W-CNT_W){1'b0}}, cnt_after_pop}
                             + {{(SUM_W-2){1'b0}}, push_n};
```
- **为什么是问题**：`CNT_W = $clog2(DEPTH+1)`、`SUM_W = $clog2(DEPTH+3)` ⇒ `SUM_W - CNT_W` 在很多 DEPTH 上正好是 0：DEPTH=**4（evt_merge 的默认值）** CNT_W=3 SUM_W=3 ⇒ 差 0 🔴 是零宽复制；DEPTH=5 差 0 🔴；DEPTH=6（交付值）CNT_W=3 SUM_W=4 ⇒ 差 1 ✅；DEPTH=**9（两个 tb 的 DEPTH9 段）** CNT_W=4 SUM_W=4 ⇒ 差 0 🔴；DEPTH=10~13 差 0 🔴。本机 iverilog 实测（%TEMP%\anvil08_probe\t3.v）：`T3 DEPTH=4 CNT_W=3 SUM_W=3  zero-repl width = 0 -> z=3` ⇒ iverilog 接受零宽复制（静默按"无扩展"处理）。但本项目自己的硬纪律写在 looper.v:1415："⛔ 不用 `{{0{...}}}` 那种零宽复制 —— 非法"，且 K-91 的教训正是"iverilog 全绿、Gowin 静默丢弃整个模块" ⇒ 这是潜伏的：rtl/top.v:3923 传 DEPTH=6（安全），但①evt_merge 的默认参数就是 4 ⇒ 任何人 `evt_merge u_x (...)` 不写 `.DEPTH()` 就命中；②tb_evt_merge.sv / tb_seq_arb.sv 的 DEPTH9 段也命中 —— 而它们现在编译通过，正好演示了"仿真过了 ≠ 能综合"。
- **改法**（三处，最稳的是统一用显式向量）：正确做法是避开拼接，改成"先扩位再赋值"：
```verilog
    wire [SUM_W-1:0] cnt_pop_x = cnt_after_pop;        // ⭐ 隐式零扩展（合法且无零宽问题）
    wire [SUM_W-1:0] push_x    = push_n;               // ⭐ 同上
    wire [SUM_W-1:0] cnt_next  = cnt_pop_x + push_x;
```
（Verilog 的赋值上下文会自动零扩展，不需要手写 `{{n{1'b0}}, x}`。）同样处理 `tail_plus`/`tail_off` 里的 `{{(SUM_W-PTR_W){1'b0}}, t}` 与 `{{(SUM_W-OFF_W){1'b0}}, n}`：其中 `{{(SUM_W-PTR_W){1'b0}}, t}` **在 DEPTH=9 时同样是零宽**（`PTR_W = $clog2(9) = 4`、`SUM_W = $clog2(12) = 4`）⇒ DEPTH9 段一次踩 2~3 处；`{{(SUM_W-OFF_W){1'b0}}, n}` 只在 `DEPTH ≤ 1` 时零宽（不可达，非问题）。
- **预期**：收益 = 消除"参数一改就静默/编译失败"的地雷（K-91 家族，本项目最贵的坑）；代价 = 0（隐式扩展比手写拼接更短）；风险 = 0（逐位等价）。
- **怎么验**：把 `evt_merge #(.DEPTH(4))`（默认）与 `#(.DEPTH(9))` 各跑一次综合（sim\gowin_build.ps1 目前只跑 top.v 的 DEPTH=6 ⇒ 需要临时改 top.v:3923 或写一个最小顶层）；判据：综合 `ERROR=0`。未修复 + Gowin 若按 2001 严格拒绝 ⇒ 编译报错；若它静默接受 ⇒ 现象与本条描述一致（无法验证），那就按 looper.v:1415 的既有纪律直接改掉（成本为零，没必要赌）。
- **来源**：ANVIL-08【P2-8】
@@@END
@@@PRIO=P2|SRC=ANVIL-08|ORIG=P2-9|MOD=rtl/top.v,rtl/w3c/looper.v,rtl/w3c/seq_arb.v,rtl/w3c/evt_merge.v
### 把 looper/seq_arb/evt_merge 的观测输出接进串口诊断（现在顶层悬空被剪）
- **位置**：rtl/top.v:3585-3591、:3653-3657（looper）、:3754-3760（seq_arb）、:3979-3984（evt_merge）；对照 rtl/w3c/pos_probe.v、rtl/w3c/span_probe.v
- **现状**：
```verilog
// top.v:3585-3591
        //  ⭐ 可观测（`K-106`：⛔ 不许静默失效）—— ⚠️ **暂未接上板观测口**
        //     📌 待办：⭐ 接到串口回传（⭐ 与 `'P'`/`'N'` 诊断同一套路）⇒ 现在先留线，⛔ 不悬空
        wire        looper_layer_state;
        wire [15:0] looper_evt_cnt;
        wire        looper_full;
        wire [15:0] looper_drop_cnt;
        wire        looper_overflow;
```
- **为什么是问题**：全 rtl/ 里对这 5 根 looper 观测线 + `sa_*`(6 根) + `mg_*`(4 根) 的唯一出现处就是"声明 + 端口连接"（全仓 grep 核实；top.v 内没有任何 $display/诊断通路/引脚读它们）⇒ 综合把整个观测锥剪掉（寄存器无负载 ⇒ 优化掉）⇒ 三个模块里为 K-106 写的 `overflow_o`（sticky）/`drop_cnt_o`（饱和）/`collision_cnt_o`/`merged_cnt_o` **在交付的比特流里一个都不存在**，上板永远看不到溢出/丢弃/相撞。注释说"现在先留线，⛔ 不悬空"—— 语法上没悬空，但电气上等价于悬空。这正好把 P0-1 的后果放大：`drop_cnt_o` 既算错、又没人能看见。
- **改法**（按成本从低到高）：1. ⭐ 最低成本（推荐先做）：把三组观测或进已有的串口诊断回传（'P'/'N' 那一套）或接进 `led_data` 的调试状态位，让"至少有一个能看见"。2. 或者把它们接进已有的 pos_probe/span_probe 式探针模块（rtl/w3c/pos_probe.v 是现成范式）。3. ⛔ 不要为了让综合"保留"而加 `(* keep *)` —— 那会白烧 FF/LUT 且仍然看不见。
- **预期**：收益 = K-106 在集成层真正成立（这是交付后唯一能定位现场故障的手段）；代价 = 一条串口回传（复用现有通路 ⇒ 几乎为 0）；若走新引脚 ⇒ 见 constr/top.cst 的引脚预算；风险 = 低（只加观测，不碰数据通路）。
- **怎么验**：①综合后看 Gowin2026.rpt.txt 的 `Register` 数：若观测通路被接上，`Register` 应上升（当前 17039）；没上升 ⇒ 还是被剪掉了，说明改动没生效。②加一条"探针必须会变"的判据（C83 口径）：在 tb 里制造一次溢出，断言新的诊断口能读到 `drop_cnt_o != 0`；在未修复代码里这条判据必须红（因为它读不到）。
- **来源**：ANVIL-08【P2-9】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-1|MOD=rtl/w3c/looper.v
### 给 br_clear_w 补状态限定（别再靠"clear_req 恰好是单周期脉冲"）
- **位置**：rtl/w3c/looper.v:632-654、:632-634、:1203、:1242、:990-995；rtl/w3a/calib_cmd.v:373、:408；tb/w3c/tb_looper.sv
- **现状**：
```verilog
// looper.v:632-634
    wire br_leave_w = ((clear_req_i[0]) || (rec_req_i[0] && (state != ST_REC)))
                      && (state == ST_HOLD) && (play_active_r != 16'd0);
    wire br_clear_w = ~br_leave_w && clear_req_i[0];
```
- **为什么是问题**：`br_leave_w` 有 `state == ST_HOLD` 限定，`br_recpend_w`/`br_reccancel_w`/`br_rec_w` 也都有状态限定，只有 `br_clear_w` 没有；而它在优先级链里排在 `ST_CLOSE`（:1203）与 `ST_LCLOSE`（:1242）之前 ⇒ 若 `clear_req_i` 在 `ST_CLOSE`/`ST_LCLOSE` 的 16 拍扫描窗口内再拉高一次，扫描会被中途打断，`close_mask_r` 里还没扫到的轴拿不到 `note_off` ⇒ 挂音。今天不可达：calib_cmd.v:373/:408 把 `loop_clear_req_o` 做成单周期脉冲，而 `ST_LCLOSE` 只有 16 拍 = 320 ns，串口一个字节要 87 µs ⇒ 撞不上 ⇒ 属于"靠约定而不是靠结构"，与本模块自己的纪律（looper.v:990-995："所有'离开回放'的请求一律先转成 ST_LCLOSE"）相悖。
- **改法**：`wire br_clear_w = ~br_leave_w && clear_req_i[0] && (state != ST_CLOSE) && (state != ST_LCLOSE);`（或把 `br_clear_w` 的分支挪到链尾 —— 但那样 `ST_HOLD` 的"无音在响直接清"就抢不到，不推荐）。
- **预期**：收益 = 不变式变真；代价 = 2 个 3 位比较（~8 LUT）。
- **怎么验**：在 tb 里于 `ST_LCLOSE` 中途再打一次 `clear_req_i`，断言仍然发满 `play_active_r` 里所有轴的 `note_off`；未修复 ⇒ 少发 ⇒ 红。
- **来源**：ANVIL-08【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-2|MOD=rtl/w3c/looper.v
### 让 tick_pend_r 能计数（现在丢 tick 不可见）
- **位置**：rtl/w3c/looper.v:242、:1372-1389、:1372-1378、:479、:166-178；rtl/top.v:1506；tb/w3c/tb_looper.sv
- **现状**：
```verilog
// looper.v:1372-1378
                    if (tick_i)
                        tick_pend_r <= 1'b1;
                    if (tick_pend_r && rd_drained) begin
                        play_tick_r <= play_tick_nxt;
                        tick_pend_r <= 1'b0;
```
- **为什么是问题**：`tick_pend_r` 是"有 tick 待推进"的布尔，不是计数器。若两个 `tick_i` 落在"本 tick 的事件还没排空"的窗口内（窗口长度 = 该 tick 的事件数 × 2 拍，和弦最多 24 条 ⇒ **≤48 拍**），第二个 tick 会被静默吞掉（`play_tick_r` 只 +1）⇒ loop 相对节拍永久滞后一个 tick，无任何可见性。今天不可达：top.v:1506 把 `tick_inc_i` 钉成常数 `TICK_INC_120BPM` ⇒ tick 周期 = **26042 拍**，而 48 ≪ 26042。但 looper.v:479 的注释写的是"tick ≥ 12 拍"—— 这个界太松，且没有任何东西守着它。
- **改法**：把 `tick_pend_r` 改成 2 位计数（`tick_pend_r <= tick_pend_r + 1`，推进时 −1），饱和时置一个 sticky `tick_lost_o`；或在 PARAM_OK 里加"tick 周期 ≥ 64 拍"的编译期自检。
- **预期**：收益 = K-106 覆盖；代价 = 1 FF + 1 加法器（或 0，用 $display 自检）。
- **怎么验**：tb 里把 `tick_i` 间隔压到 20 拍并给一个 24 条同 tick 的和弦，断言 `play_tick_r` 不掉拍；未修复 ⇒ 掉拍 ⇒ 红。
- **来源**：ANVIL-08【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-3|MOD=rtl/w3c/play_seq.v
### 给 play_seq 的 evt_cnt_o / tempo_cnt_o 补饱和
- **位置**：rtl/w3c/play_seq.v:184、:197、:183-184、:196-197、:60；对照 rtl/w3c/evt_merge.v:322-323、rtl/w3c/seq_arb.v:318-329、rtl/w3c/looper.v:1193；tb/w3c/tb_play_seq.sv
- **现状**：
```verilog
// play_seq.v:183-184
            if (emit_now) begin
                evt_cnt_o    <= evt_cnt_o + 16'd1;
// play_seq.v:196-197
                        tempo_applied_o <= 1'b1;
                        tempo_cnt_o     <= tempo_cnt_o + 16'd1;
```
- **为什么是问题**：同族的 `merged_cnt_o`（evt_merge.v:322-323）、`live/score/demo_cnt_o`（seq_arb.v:318-329）、`drop_r`（looper.v:1193）全部饱和，只有 play_seq 这两个是裸加法 ⇒ 65536 条后归零。play_seq.v:60 自己写着"⭐ 任何'容量有限'的计数器都必须可观测（K-106）"。
- **改法**：照抄 evt_merge.v:322-323 的 `== 16'hFFFF ? :` 写法（两处）。
- **预期**：0 FF / 0 LUT；收益 = 计数器不再撒谎。
- **怎么验**：tb_play_seq.sv 里喂 65536 条事件后断言 `evt_cnt_o == 16'hFFFF`；未修复 ⇒ 0 ⇒ 红。
- **来源**：ANVIL-08【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-4|MOD=rtl/w3c/play_seq.v
### 给 play_seq 的追赶语义加节流（迟到事件现在按 20 ns/条倾泻）
- **位置**：rtl/w3c/play_seq.v:136-145、:136-145；tb/w3c/tb_play_seq.sv
- **现状**：
```verilog
// play_seq.v:136-145
    //   ⭐ `evt_tick <= cur_tick_r` ⇒ 本拍该发（⛔ 不用等下一个 `tick_i`）
    //   ⚠️ 用 `<=`（⛔ 不是 `==`）：⭐ **PC 送晚了的条目【照样发】**（追赶），
    wire evt_due = evt_valid_i & (evt_tick <= cur_tick_r);
    wire emit_now = run_i & evt_due;
    assign evt_rd_o = emit_now;
```
- **为什么是问题**：`<=` 的追赶语义本身是对的（防死锁）。但没有任何速率限制：若 PC 一次性灌入整首曲子而 `cur_tick_r` 已经走到第 500 拍，那么所有 `tick ≤ 500` 的事件会在连续 500 个时钟（20 ns/条）内倾泻，下游 `evt_merge`（深度 6、1 条/拍出口）刚好能跟上（不溢出），但 `note_manager` 会收到 **50 M 事件/秒** 的突发 ⇒ voice 抢占/复用风暴（听感是"炸一下"）。
- **改法**：给 `emit_now` 加一个"每 tick 最多 N 条"或"每 M 拍最多 1 条"的节流（N 取最大和弦数 24 即可，余量巨大：一个 tick 有 26042 拍）；或加一个"落后超过 K 个 tick 就重置 `cur_tick_r` 到队首 tick"的追赶上限。
- **预期**：收益 = 消灭突发洪水；代价 = 一个计数器 + 比较器（~20 LUT）。
- **怎么验**：tb_play_seq.sv 加一条：先把 `cur_tick_r` 推到 500 再灌 100 条 `tick=0` 的事件，断言"单位时间内的发出条数 ≤ N"；未修复 ⇒ 100 条连发 ⇒ 红。⚠️ 本条只在 play_seq 接入 top.v 后才影响比特流（§0.1）。
- **来源**：ANVIL-08【P3-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-5|MOD=rtl/w3c/evt_merge.v
### 统一 evt_merge 三路 push 的 Z 防护口径
- **位置**：rtl/w3c/evt_merge.v:219-229、:223-228；tb/w3c/tb_evt_merge_diff.sv
- **现状**：
```verilog
// evt_merge.v:219-229
    wire push_a_first = ~prio_b_r;
    wire push_a = a_valid_i;
    wire push_b = b_valid_i;
    //   ⚠️ **用 `=== 1'b1` 判定**（⛔ 不是直接取用）—— ⭐ 这是**向后兼容**的关键一步：
    wire push_c = (c_valid_i === 1'b1);
```
- **为什么是问题**：`push_c` 的 `===` 是为"老 tb 不接新端口（悬空 = z）"做的防护，理由写在 :223-228。但 `a_valid_i`/`b_valid_i` 用的是裸取用 ⇒ 口径不一致：若某天有人写一个只接 C 的 tb（或不接 A/B），`push_a = 1'bz` ⇒ `push_n` 变 x ⇒ 整个 FIFO 计数污染。
- **改法**：三路统一 —— 要么都 `=== 1'b1`，要么在文件头写明"只有 C 允许悬空"。
- **预期**：0 FF / 0 LUT（`===` 在综合里退化为 `==`）。
- **怎么验**：tb_evt_merge_diff.sv 里把 `a_valid_i` 悬空，断言输出无 X（现有 A8 检查器 `chk_xprop` 会抓）；未修复 ⇒ X 传播 ⇒ 红。
- **来源**：ANVIL-08【P3-5】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-6|MOD=rtl/w3c/seq_arb.v
### 修正 seq_arb 里"此路实际不可达"的过时注释
- **位置**：rtl/w3c/seq_arb.v:338-341、:238；tb/w3c/tb_seq_arb.sv:320
- **现状**：
```verilog
// seq_arb.v:338-341
                    if (push_live && push_score && push_demo) begin
                        // ⭐ 三条全到（⚠️ 极罕见：演示只在"没别的"时才推 ⇒ 此路实际不可达，
                        //    ⭐ 但**保留** ⇒ ⭐ 不给"将来改让位规则"留坑）
```
- **为什么是问题**：`push_demo` 现在是 `demo_valid_i & (~others_going | demo_is_off)`（:238）⇒ demo 的 `note_off` 在 live+score 都在时照样参与推入 ⇒ "三路全到"**是可达的**（live + score + demo_off）。注释是 2026-09-26 写的，2026-09-28 改让位规则时没同步。危险在于：读注释的人会以为这条分支是死代码，从而在重构时删掉它 ⇒ 三路同拍时丢事件。
- **改法**：注释改成"三路全到 = live + score + demo_off，**可达**（见 `demo_is_off`）"。
- **预期**：0 资源；收益 = 防止重构时误删可达分支。
- **怎么验**：tb_seq_arb.sv 判据③（:320 三源同拍）正是压这条分支，改注释后跑一次它必须仍绿；反过来，若有人真删了这条分支，判据③必红。
- **来源**：ANVIL-08【P3-6】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-7|MOD=rtl/w3c/looper.v
### 把 looper 两个 33 位减法器收成 32 位
- **位置**：rtl/w3c/looper.v:497-502、:494-502
- **现状**：
```verilog
// looper.v:497-502
    wire [PHASE_W:0]   ramp_dinc  = ramp_up ? ({1'b0, rtgt_inc_c} - {1'b0, ramp_inc_c})
                                            : ({1'b0, ramp_inc_c} - {1'b0, rtgt_inc_c});
```
- **为什么是问题**：两个操作数都是 32 位且 `ramp_up` 保证被减数 ≥ 减数 ⇒ 差的第 33 位恒为 0（`ramp_dn` 那一支同理）⇒ `PHASE_W+1` 位的减法器高 1 位是死逻辑（≈ 2 ALU/位 × 2 条）。
- **改法**：`ramp_dinc` 收成 `[PHASE_W-1:0]`，只在 `pb_qinc` 的"`+2^f-1`（或 P1-3 后的 `-1`）"那一步扩到 33 位。⚠️ 注意与 P1-5 合并做（P1-5 会删掉 `ramp_dn` 那一支）。
- **预期**：收益 ≈ **−4 ALU**；代价 = 0。
- **怎么验**：同 P1-5（判据⑨ 的逐值判据）。
- **来源**：ANVIL-08【P3-7】
@@@END
@@@PRIO=P3|SRC=ANVIL-08|ORIG=P3-8|MOD=rtl/w3c/looper.v
### 让 looper 的录制侧与回放侧阵列物理复用（受 P0-2 红线约束）
- **位置**：rtl/w3c/looper.v:357-374、:999-1409、:551-562、:599-624；tb/w3c/（5 个 looper tb）
- **现状**：
```verilog
// looper.v:357-374（8 个 16 项阵列）
    reg [PHASE_W-1:0] last_inc_r [0:15];   // 录制侧 32
    reg [VEL_W-1:0]   vel_max_r [0:15];    // 录制侧 8
    reg [CNT_W-1:0]   on_addr_r  [0:15];   // 录制侧 16
    reg [PHASE_W-1:0] ramp_inc  [0:15];    // 回放侧 32
    reg [VEL_W-1:0]   ramp_vel  [0:15];    // 回放侧 8
    reg [PHASE_W-1:0] rtgt_inc  [0:15];    // 回放侧 32
    reg [VEL_W-1:0]   rtgt_vel  [0:15];    // 回放侧 8
    reg [TICK_W-1:0]  rend_tick [0:15];    // 回放侧 20
```
- **为什么是问题**：合计 `16 × (32+8+16+32+8+32+8+20) = 16 × 156 = 2496 FF`。而录制与回放由 FSM 保证互斥（ST_REC vs ST_HOLD，looper.v:999-1409）⇒ `last_inc_r`/`vel_max_r`/`on_addr_r`（56 位）可以与 `ramp_inc`/`ramp_vel`/`rend_tick`（60 位）物理复用 ⇒ 省 `16 × 56 = 896 FF`（占全设计寄存器 17039 的 **5.3%**）+ 3 组 16:1 读 mux + 3 组写译码（≈ 300~500 LUT）。
- **改法**：把录制侧与回放侧阵列合并成 3 个物理阵列 + 一个"当前是录还是放"的模式信号（`playing` 已现成）进 6 个读写口。
- **预期**：收益 = −896 FF + 约 300~500 LUT；代价 = 模式信号进 6 个读写口；风险 = **中高**（别名 bug 很难查，且必须重跑全部 5 个 looper tb）。🔴 红线（与 P0-2 联动）：这个改动**不能**顺手动 `mem`/`ep_mem` 的 BSRAM 结构；一旦把 `ep_mem` 变成 FF，全设计最薄的 hold 路径（0.137 ns）会立刻恶化 ⇒ 必须先跑一次 PnR 基线再评估。
- **怎么验**：`sim\tb_all.ps1 -Filter looper` 的 5 个 tb 全绿 + `Register` 应从 17039 降到 ~16143。
- **来源**：ANVIL-08【P3-8】
@@@END
@@@TOTAL SRC=ANVIL-08 COUNT=25 P0=2 P1=6 P2=9 P3=8
