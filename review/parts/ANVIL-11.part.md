@@@PRIO=P0|SRC=ANVIL-11|ORIG=P0-1|MOD=rtl/w3c/tlc5916_bank.sv,rtl/drivers/tlc5916_driver.sv
### 把 tlc5916_bank 给 driver 的 start 做成恰好 1 拍（现在片1 图案被片0 顶替）
- **位置**：rtl/w3c/tlc5916_bank.sv:232-239（S_START）、:250-253（换片处）、:221-230；rtl/drivers/tlc5916_driver.sv:277（pending 置位）、:198；tb/w3c/tb_tlc5916_bank.sv
- **现状**：
```verilog
// tlc5916_bank.sv:232-239
S_START: begin
    drv_start_r <= 1'b1;   // 拉 start（driver 锁进 pending 或直接接受）
    if (drv_busy) begin
        // driver 已接受本片 ⇒ 撤 start，等 done
        drv_start_r <= 1'b0;
        state       <= S_WAIT_BUSY;
    end
end
// tlc5916_driver.sv:277
if (start && busy) pending <= 1'b1;
```
- **为什么是问题**：`drv_busy` 是 driver 内部寄存器，bank 要到下一拍才看得见 ⇒ `start` 实际宽度 = **2 拍 = 40 ns**。时序：离开 S_IDLE 时 `drv_start_r<=0`；S_START 第 1 拍拉 1、第 2 拍仍写 1（此时 driver 还没回 busy）、第 3 拍看到 busy=1 才撤。driver 在第 2 拍采样 `start=1 && busy=0` ⇒ 接受；在第 3 拍采样 `start=1 && busy=1` ⇒ **`pending<=1`（误置）**。回到 STATE_IDLE 后 `if (start || pending)` 立刻再发一帧，且 `data_latched <= led_data` 采的是换片前的值（`chip_sel` 在同一拍才自增）⇒ **重放上一片的图案**。⭐ 实测（build/anvil11-probe/，`pattern = 24'hA5_3C_0F` ⇒ 期望 `F0 / 3C / 95`）：`OBSERVED: n_le=3 n_done=3 n_pending_sets=2 start_high_cycles=4`；`LE[0]: byte=f0 chip_sel=0 <- 对`；`LE[1]: byte=f0 chip_sel=1 <- 🔴 错！应是 3c（片1 的图案永远发不出去）`；`LE[2]: byte=95 chip_sel=2 <- 对`；`VERDICT: BUG REPRODUCED`。
- **改法**（已实测验证，改 build/anvil11-probe/tlc5916_bank_fixed.sv，3 处）：把 `start` 做成恰好 1 拍的脉冲 —— 在离开 S_IDLE / S_WAIT_BUSY 的那一拍拉高，S_START 只负责撤销：
```verilog
S_IDLE: begin
    busy_r      <= 1'b0;
    chip_sel    <= 2'd0;
    drv_start_r <= 1'b0;
    if (pattern_commit_i) begin
        busy_r      <= 1'b1;
        chip_sel    <= 2'd0;
        drv_start_r <= 1'b1;   // FIX: 1 拍 start 脉冲
        state       <= S_START;
    end
end
S_START: begin
    drv_start_r <= 1'b0;       // FIX: start 只宽 1 拍
    state       <= S_WAIT_BUSY;
end
// 换片处同样补一行：drv_start_r <= 1'b1;
```
修后实测：`n_le=3 n_done=3 n_pending_sets=0 start_high_cycles=3`，字节 `f0 / 3c / 95` ⇒ `VERDICT: NO BUG`。⚠️ 1 拍 `start` 是 driver 的既有契约（tlc5916_driver.sv:198 的恢复序列就是按"1 拍 start 会被 pending 记住"写的），所以这个修法是回到契约，不是新语义。
- **预期**：收益 = 片1（键灯高 8 位 = 右手板 8 个键）恢复正确图案；顺带消掉 2 次多余传输。代价 = **0 LUT / 0 FF**（还少一个 `if (drv_busy)` 比较）；`drv_start_r` 路径是 FF→FF 单级，Fmax 无影响。
- **怎么验**：新建 tb/w3c/tb_tlc5916_bank_seq.sv：`pattern = 24'hA5_3C_0F`，在 `led_le_o` 上升沿抓 8 位串行字节并记 `dut.chip_sel`，断言三个字节依次 `== {chip0_out, chip1_out, chip2_out}`（= F0/3C/95）。对未修的 RTL 必须红（已实测 f0/f0/95）。⛔ 现有 tb_tlc5916_bank.sv 抓不到（见 P0-4）。
- **来源**：ANVIL-11【P0-1】
@@@END
@@@PRIO=P0|SRC=ANVIL-11|ORIG=P0-2|MOD=rtl/top.v,rtl/w3c/led_data.v
### 接上 TLC5916 键灯链的三个占位输入（现在 24 路灯永久全灭）
- **位置**：rtl/top.v:4838-4840、:4860、:4854；rtl/w3c/led_data.v:73-85、:92、:101；rtl/w3c/tlc5916_bank.sv:199-205；tb/top/tb_top_led_strip.sv:90-101
- **现状**：
```verilog
// top.v:4838-4840
.guide_key_i     (16'd0),            // ⭐ 占位：待 play_seq（甲）
.key_active_i    (16'd0),            // ⭐ 占位：待 event_extract.key_on（甲）
.status_i        (8'd0),             // ⭐ 占位：待 UI 状态总线
// led_data.v:73-79,85
wire [KEY_N-1:0] blink_keys = guide_key_i & ~key_active_i;
assign key_pattern[ki] = key_active_i[ki] | (blink_keys[ki] & blink_i);
assign pattern_next = {status_i, key_pattern};
// led_data.v:92,101
wire pattern_changed = (pattern_r !== pattern_next);
commit_r  <= pattern_changed;
// tlc5916_bank.sv:199-205
oe_n_r = {OE_N{1'b1}};              // 默认全灭
if (state != S_IDLE && !global_blank_i) begin ... end
```
- **为什么是问题**：三个输入恒 0 ⇒ `key_pattern == 16'd0` ⇒ `pattern_next == 24'd0`；`pattern_r` 复位也是 0 ⇒ `pattern_changed = (0 !== 0) = 0` **恒假** ⇒ `commit_r` 恒 0。`tlc5916_bank` 只在 `S_IDLE && pattern_commit_i` 才启动 ⇒ 一轮都不跑 ⇒ `state` 永为 S_IDLE ⇒ `oe_n_r = 5'b11111`。OE 低有效 ⇒ **24 路 TLC5916 输出（16 键灯 + 8 状态灯）全部永久消隐**。实测数字：0 次写、0 个 LE 脉冲、`led_oe_n[4:0]` 恒 `5'b11111`。⚠️ 而全部 128 个 tb 都会绿：`led_sdi/led_clk/led_le/led_oe_n` 在 tb_top_led_strip.sv:90-101 里连端口都没写（悬空），其余 tb 引出来也不做断言。
- **改法**：接真源，顺序不能反 —— ①先修 P0-3（guide_lamp 的死输入 + .gprj 登记），否则接上去也没用；②`play_seq.note_valid_o / note_data_o` → `guide_lamp.note_valid_i / note_data_i`；③`guide_lamp.guide_key_o` → `led_data.guide_key_i`（替换 16'd0）；④`event_extract` 的 `key_on` 16 位引出 → `led_data.key_active_i`（替换 16'd0）；⑤UI 状态总线 → `led_data.status_i`（替换 8'd0）。⑤可先不做（status_i=8'd0 只是让 8 个状态灯灭），但 ①②③④必须一起上。
- **预期**：收益 = 功能从"没有"到"有"（16 键灯 + 8 状态灯复活）；代价 = guide_lamp 一个模块（约 30~50 LUT + 17 FF）＋ 接线；led_data/tlc5916_bank 本体一行不改（接口早就留好了）。
- **怎么验**：在 tb_top_led_strip.sv 里把 `led_sdi/led_clk/led_le/led_oe_n` 接上，加两条：①断言 `led_oe_n` 在图案变化后出现低脉冲（当前恒高 ⇒ 必红）；②抓一轮串行字节，断言 `== {chip0_out, chip1_out, chip2_out}`（这条同时是 P0-1 的判据）。
- **来源**：ANVIL-11【P0-2】
@@@END
@@@PRIO=P0|SRC=ANVIL-11|ORIG=P0-3|MOD=rtl/w3c/guide_lamp.v,Gowin2026.gprj
### 兑现 guide_lamp 的消隐并把它登记进 .gprj
- **位置**：rtl/w3c/guide_lamp.v:20-21、:42、:45、:72-95；Gowin2026.gprj（无 guide_lamp）、:164、:186-189；tb/w3c/tb_guide_lamp.sv:34-35、:101；sim/evidence/final-batch-20261008/syn.log:176-181；files/10-硬件/LED演奏指引方案.md §4.3；rtl/w3c/led_data.v:73-79
- **现状**：
```verilog
// guide_lamp.v:20-21  ← 注释承诺了两件事
//    · key_active_i 已按下的键 → 消隐（已按就不需要再指引）
//    · blink_i（拍点脉冲）→ 使当前指引位跟随拍点闪烁（可观测节拍）
// guide_lamp.v:41-45  ← 端口确实声明了
input  wire [AXIS_N-1:0]   key_active_i,
input  wire                blink_i,
// guide_lamp.v:72-95  ← 逻辑里【一次都没用到】上面两个输入
always @(posedge clk_i) begin
    if (!rst_n_i) begin guide_key_o <= {AXIS_N{1'b0}}; guide_commit_o <= 1'b0; end
    else begin
        guide_commit_o <= 1'b0;
        if (note_valid_i) begin
            if (is_note_on)       begin guide_key_o[note_axis] <= 1'b1; guide_commit_o <= 1'b1; end
            else if (is_note_off) begin guide_key_o[note_axis] <= 1'b0; guide_commit_o <= 1'b1; end
        end
    end
end
```
- **为什么是问题**：机械计数（本轮实测）：`key_active_i` 全文出现 **2 次**（:42 端口声明 + :20 注释）；`blink_i` 全文 **2 次**（:45 端口声明 + :21 注释）；在 always 块里 **0 次** ⇒ ①"已按下的键消隐"没实现：已按键仍被指引灯点亮 ⇒ 用户分不清"该按的键"和"正在响的键"（正是 LED演奏指引方案.md §4.3 要区分的那两件事）；②"指引位跟随拍点闪烁"没实现：指引是常亮，节拍在灯上不可见；③**双重死亡**：Gowin2026.gprj 里没有 `guide_lamp`（`Select-String -Path Gowin2026.gprj -Pattern "guide"` 只命中一句注释）⇒ sim/evidence/final-batch-20261008/syn.log:176-181 的 `Compiling module` 列表里没有 `guide_lamp` ⇒ **它根本没进网表**；即使甲线把 top.v 接好了，Gowin 也只会报 `EX3937 Instantiating unknown module`（或者更糟：静默丢弃）。⚠️ 更阴的是：tb_guide_lamp.sv 恒给 `key_active=0`、`blink=0`（:34-35 初始化后 :101 起从未改过），所以那 16 条判据全绿 —— C83（探针假绿）的教科书复现。
- **改法**（三处，一次做完）：①消隐（组合，最省）—— 新增一根可见输出，或在 `guide_key_o` 上直接消隐：`assign guide_vis_o = guide_key_o & ~key_active_i;`（若要保持 `guide_key_o` 的端口语义不变，就新增 `guide_vis_o` 端口，`led_data.guide_key_i` 接它）。②闪烁 —— 把拍点做进输出级（与 led_data 的 `blink_i` 语义对齐，⛔ 不要重复实现两个闪烁）；⚠️ **二选一必须与 led_data 商量**：led_data.v:73-79 已经做了 `blink_keys & blink_i`，若 guide_lamp 也做就是两次闪烁串联 ⇒ 实际占空比变成 25%。⭐ 推荐：guide_lamp 只做消隐（①），闪烁留给 led_data（那是它已经写好的职责）；这样 `blink_i` 就该从 guide_lamp 的端口列表里删掉（而不是留着当装饰）。③登记 .gprj：在 Gowin2026.gprj:164 那一组里加 `<File path="rtl/w3c/guide_lamp.v" type="file.verilog" enable="1"/>`，⛔ 必须是 `type="file.verilog"`（.gprj:186-189 已记过这个坑：写 `file.systemverilog` 会静默跳过）。④改完在综合日志里确认出现 `Compiling module 'guide_lamp'`。
- **预期**：①消隐 +16 LUT / 0 FF（一层 AND）；②删 `blink_i` 端口 −0（它本来就没进逻辑）；③登记 .gprj 0。⚠️ 代价另一面：登记后 guide_lamp 进综合，`AXIS_W` 越界问题（P3-2）就要先修，否则 AXIS_N<16 时才炸 —— 当前 AXIS_N=16 是安全的。
- **怎么验**：tb_guide_lamp.sv 现在把 key_active/blink 恒 0 ⇒ 两条判据都没写。加：①`key_active_i = 16'h0008` + `note_on axis=3` ⇒ 断言 `guide_vis_o[3] === 1'b0`（当前 `guide_key_o[3]` 会是 1 ⇒ 对未修 RTL 必红）；②断言"`key_active_i` 的变化会改变输出"（存在性反证）。⛔ 变异证据纪律：把 `& ~key_active_i` 删掉 ⇒ ①必须红（这正是 M137~M139 的补集）。
- **来源**：ANVIL-11【P0-3】
@@@END
@@@PRIO=P0|SRC=ANVIL-11|ORIG=P0-4|MOD=tb/w3c/tb_tlc5916_bank.sv,tb/top/tb_top_led_strip.sv
### 补齐 tb 自述的两条判据并把顶层四个 TLC 引脚接上
- **位置**：tb/w3c/tb_tlc5916_bank.sv:12-14（自述）、:131-150（实际）；tb/top/tb_top_led_strip.sv:90-101（端口列表）；rtl/w3c/tlc5916_bank.sv
- **现状**：
```verilog
// tb_tlc5916_bank.sv:12-14  ← 文件头【自述】有这三条
//   ③ ⭐ 三片逐写：commit 后依次写片0、片1、片2，写完回 IDLE、OE 回全高
//   ④ ⭐ OE 分板：写片0 时 oe[0]=0；写片1 时 oe[1]=0；写片2 时 oe[4]=0
//   ⑤ ⭐ busy 只在写期间为高，写完后回落
// tb_tlc5916_bank.sv:131-150  ← 实际只做了这些
commit = 1'b1; @(negedge clk); commit = 1'b0;
wait (busy === 1'b1);   // 开始
wait (busy === 1'b0);   // 结束
@(negedge clk);
chk("after 3-chip write: OE all high (back to IDLE)", oe_n === {OE_N{1'b1}});
chk("after 3-chip write: busy 0", busy === 1'b0);
// tb_top_led_strip.sv:90-101  ← 端口列表里【没有】led_sdi/led_clk/led_le/led_oe_n
```
- **为什么是问题**：①tb_tlc5916_bank 的 ③④ 从未实现：它只在整轮结束后看一次 `oe_n === 5'b11111` 和 `busy === 0`，既不抓每片的串行数据、也不看每片的 OE。判据②之所以有效，是因为它用层次引用 `dut.chip0_out`（组合表），这恰好绕过了串行链 —— 也就是说：**CH→OUT 表对、串行链全错，它照样全绿**。②tb_top_led_strip 的 `.led_sdi/led_clk/led_le/led_oe_n` 一个都没连 ⇒ 那四根线在 tb 里悬空（z）。③全仓库计数：tb/ 下把 `led_sdi`/`led_clk`/`led_le`/`led_oe_n` 引出来的 tb 只有 3 个（tb_top_t15、tb_pos_probe_axis、tb_vibrato_top），没有任何一个对它们做值断言。⇒ 结论：**TLC5916 总线的顶层波形，判据覆盖率 = 0**。P0-1 因此能 100% 通过 128/128。
- **改法**（只加 tb，0 RTL 代价）：①tb_tlc5916_bank.sv 补 ③④：在 `led_le_o` 上升沿抓 8 位（`{cap[6:0], led_sdi_o}`）并记 `dut.chip_sel`，断言三次 `(byte, chip_sel)` 依次是 `(chip0_out,0) (chip1_out,1) (chip2_out,2)`；同时每次断言 `oe_n[chip] === 1'b0`、其余为 1。②tb_top_led_strip.sv:90-101 把四根线接上，并断言"图案变化后 `led_oe_n` 出现低脉冲 + SDI 位流 == 期望"。
- **预期**：收益 = P0-1/P0-2 从此不可能再溜过；代价 = 0 RTL，tb 运行时间 +≈0（一轮 3 片只有 1353 拍）。⚠️ tb_all.ps1 自动发现 `tb/**/tb_*.sv` ⇒ 新增 tb 会让"共 N"从 128 变成 129，⛔ 判据是"通过数 == 共数"，不是写死 128。
- **怎么验**：把新断言先对当前 RTL 跑 ⇒ 必须红（已实测 f0/f0/95）。这是"新判据不是恒真"的工具控制实验，⛔ 不能省。
- **来源**：ANVIL-11【P0-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-11|ORIG=P1-1|MOD=rtl/w3c/tlc5916_bank.sv
### 把 drv_oe 接成 OE 总闸，让 K-01/K-57 防护重新回到引脚
- **位置**：rtl/w3c/tlc5916_bank.sv:159、:147、:163、:198-207；rtl/drivers/tlc5916_driver.sv:17-25、:159-162、:265-267、:23-24；tb/drivers/tb_tlc5916_driver.sv:46-49
- **现状**：
```verilog
// tlc5916_bank.sv:147,159,163
wire        drv_oe;      // driver 的 OE 输出（我们另外做分板 mux）
    .outputs_enable (1'b1),          // ⭐ 让 driver 自己的 OE 常开；分板靠下面 mux
    .tlc_oe_n       (drv_oe),
// tlc5916_bank.sv:198-207   ← 真正的引脚由【组合】逻辑驱动
reg [OE_N-1:0] oe_n_r;
always @(*) begin
    oe_n_r = {OE_N{1'b1}};
    if (state != S_IDLE && !global_blank_i) begin
        if (chip_sel == 2'd0)      oe_n_r[0] = 1'b0;
        else if (chip_sel == 2'd1) oe_n_r[1] = 1'b0;
        else                        oe_n_r[4] = 1'b0;
    end
end
assign led_oe_n_o = oe_n_r;
// tlc5916_driver.sv:162,267   ← 这两道防护作用在 drv_oe 上
wire oe_quiet = (state == STATE_IDLE) && (tlc_le == 1'b0) && (tlc_clk == 1'b0);
if (oe_quiet) tlc_oe_n <= ~oe_hold;
```
- **为什么是问题**：tlc5916_driver 的防护①（`OE_STABLE = 25` 拍 = **500 ns** 稳定窗，满足手册 `tw(OE) ≥ 500 ns`，K-57）与防护②（只在 `state==IDLE && !tlc_le && !tlc_clk` 时改 OE，K-01 的成因）全部作用在 `tlc_oe_n` 这个输出上。而 bank 把它接给 `drv_oe` 之后 **0 个消费者**（全文只有 :147 声明 + :163 连接），真正的 `led_oe_n[4:0]` 由 `oe_n_r` 组合驱动。⇒ 数字：**500 ns 稳定窗对引脚 0 覆盖**；**"CLK 静止"条件对引脚 0 覆盖**；`drv_oe` = **1 位死网**；`outputs_enable` 恒 1 ⇒ `oe_hold`/`oe_cnt` 那套逻辑是结构上被短路的死逻辑。⚠️ 具体风险：`oe_n_r` 的输入是 `state[2:0]` 与 `chip_sel[1:0]`（都是 FF），组合译码在 state 跳变时可能出毛刺；虽然当前"OE 变化总发生在 driver 回 IDLE（CLK 静止）之后"，但那是时序巧合，⛔ 不是结构保证。
- **改法**（推荐 (a)，0 额外 FF）：(a) 把 `drv_oe` 接成总闸，分板 mux 与它相与：`assign led_oe_n_o = oe_n_r | {OE_N{~drv_oe}};` —— 这样 K-01/K-57 的两道防护重新回到引脚上，且 `drv_oe` 不再是死网。(b) 或把 `oe_n_r` 打一拍成寄存器（消组合毛刺），并仍然接 `drv_oe` 作总闸。⚠️ 无论哪条，tlc5916_bank.sv:159 的 `1'b1` 要改成真正的"总使能"（若暂时没有，用 `~global_blank_i`）。
- **预期**：收益 = 5 根 OE 引脚重新受 K-01/K-57 防护（Special Mode 不可进）；代价 = **约 5 个 OR 门 / 0 FF**；副作用 = OE 变化最多晚 `OE_STABLE` = 25 拍 = 0.5 µs（对"消隐/分板"用途无感，tlc5916_driver.sv:23-24 早已算过这笔账）；`drv_oe` 路径是 FF→OR→引脚，Fmax 无影响。
- **怎么验**：tb_tlc5916_bank.sv 挂上 tb_tlc5916_driver.sv:46-49 那两个检查器：
```verilog
chk_min_pulse #(.NAME("led_oe_n[0]"), .ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1 (.clk(clk), .rst_n(rst_n), .sig(oe_n[0]), .err_cnt(a1));
chk_le_shift  #(.NAME_LE("led_le_o"), .NAME_SCK("led_clk_o"))        u_a2 (.clk(clk), .rst_n(rst_n), .le(le), .sck(clk_o), .err_cnt(a2));
```
再打一个 1 拍 `global_blank_i` 窄脉冲，断言引脚完全不动。对未修 RTL：1 拍 `global_blank_i` 会让 `oe_n_r` 组合翻转 1 拍 ⇒ `chk_min_pulse` 必红。
- **来源**：ANVIL-11【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-11|ORIG=P1-2|MOD=rtl/w3c/tlc5916_bank.sv
### 给 tlc5916_bank 加 pending_commit 补发位（现在忙时的 commit 被静默丢弃）
- **位置**：rtl/w3c/led_data.v:100-101；rtl/w3c/tlc5916_bank.sv:221-230；对照 rtl/drivers/tlc5916_driver.sv:277
- **现状**：
```verilog
// led_data.v:100-101
// ⭐ commit 只在"图案真的变了"那一拍拉高（单周期），⛔ 每拍都刷
commit_r  <= pattern_changed;
// tlc5916_bank.sv:221-230   ← 只有 S_IDLE 分支看 commit
S_IDLE: begin
    drv_start_r <= 1'b0;
    busy_r      <= 1'b0;
    chip_sel    <= 2'd0;
    if (pattern_commit_i) begin
        busy_r   <= 1'b1;
        chip_sel <= 2'd0;
        state    <= S_START;
    end
end
```
- **为什么是问题**：一轮 = 3 片 × (8 bit × 2 半周期 × `HALF_DIV`=25 拍 + `LE_WAIT` 1 拍 + `LATCH_HIGH` 25 拍) = 3 × (400 + 26) ≈ **1353 拍 = 27.1 µs @50 MHz**。这 27.1 µs 里 bank 不在 S_IDLE ⇒ `pattern_commit_i` 被完全忽略，而且**没有 pending 位**（对照 tlc5916_driver.sv:277 的 R-09 是有的）。⚠️ 后果不对称：如果那次变化是"按下并保持"的一次性变化，灯会**永远停在旧图案**，直到下一次图案变化。用 `blink_i` 抖动时（每拍点都变）看不出来；**单手按一个键不动**时就是永久性错误。
- **改法**：给 bank 加 1 位 `pending_commit`（与 driver 的 R-09 同构，语义 = "至少写一次"）：
```verilog
// 在非 IDLE 期间记住请求
if (pattern_commit_i && (state != S_IDLE)) pending_commit <= 1'b1;
// 回 IDLE 时补发
S_IDLE: if (pattern_commit_i || pending_commit) begin
            pending_commit <= 1'b0;
            busy_r <= 1'b1; chip_sel <= 2'd0; state <= S_START;
        end
```
（复位分支加 `pending_commit <= 1'b0;`）
- **预期**：收益 = 消除"偶尔不刷新/永久不刷新"这类极难定位的现象；代价 = **+1 FF + ~2 LUT**；`pending_commit` 是 FF→OR→FSM，Fmax 无影响。
- **怎么验**：tb 里 `commit` 一次 → `wait (busy === 1'b1)` → 在 busy 期间改 `pattern_i` 再 `commit` 一次 → 等整轮结束 → 断言 `oe_n`/SDI 又出现一轮、且最终图案 == 新图案。对未修 RTL：只跑一轮 ⇒ 必红。
- **来源**：ANVIL-11【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-11|ORIG=P1-3|MOD=tb/w3c/tb_tlc5916_bank.sv
### 给 tb_tlc5916_bank 挂上引脚级检查器（A1/A2/A8）
- **位置**：tb/w3c/tb_tlc5916_bank.sv（全文无 chk_* 例化）；对照 tb/drivers/tb_tlc5916_driver.sv:46-62（挂了 8 个）；bringup/mutation_test.ps1:185（M06）
- **现状**：
```verilog
// tb_tlc5916_driver.sv:46-49（对照组的正确写法）
chk_min_pulse #(.NAME("tlc_oe_n"), .ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1 (
    .clk(clk), .rst_n(rst_n), .sig(tlc_oe_n), .err_cnt(a1_err));
chk_le_shift #(.NAME_LE("tlc_le"), .NAME_SCK("tlc_clk")) u_a2 (
    .clk(clk), .rst_n(rst_n), .le(tlc_le), .sck(tlc_clk), .err_cnt(a2_err));
// tb_tlc5916_bank.sv  ——  全文没有任何 chk_min_pulse / chk_le_shift / chk_xprop
```
- **为什么是问题**：tlc5916_bank 是真正驱动引脚的那一级：`led_le_o`/`led_clk_o`/`led_oe_n_o[4:0]`/`led_sdi_o` 都由它出 ⇒ 这三个引脚的 A1（窄脉冲）/A2（LE 在移位期为低）/A8（X 传播）判据覆盖率 = 0。对照：driver 的 tb 对同样的物理引脚（在更下游）挂了 8 个检查器 —— 也就是说防护被挂在了错误的层级（见 P1-1，引脚其实由 bank 驱动）。
- **改法**：把 tb_tlc5916_driver.sv:46-62 那三组照抄到 tb_tlc5916_bank.sv：
```verilog
wire [31:0] a1_le, a1_oe, a2_err, a8_sdi, a8_clk, a8_le, a8_oe;
chk_min_pulse #(.NAME("led_le_o"),   .ACTIVE_LOW(0), .MIN_CYCLES(4)) u_a1l (.clk(clk),.rst_n(rst_n),.sig(le),     .err_cnt(a1_le));
chk_min_pulse #(.NAME("led_oe_n[0]"),.ACTIVE_LOW(1), .MIN_CYCLES(4)) u_a1o (.clk(clk),.rst_n(rst_n),.sig(oe_n[0]),.err_cnt(a1_oe));
chk_le_shift  #(.NAME_LE("led_le_o"),.NAME_SCK("led_clk_o"))         u_a2  (.clk(clk),.rst_n(rst_n),.le(le),.sck(clk_o),.err_cnt(a2_err));
chk_xprop #(.W(1),.NAME("led_sdi")) u_a8s (.clk(clk),.rst_n(rst_n),.sig(sdi),  .err_cnt(a8_sdi));
chk_xprop #(.W(1),.NAME("led_clk")) u_a8c (.clk(clk),.rst_n(rst_n),.sig(clk_o),.err_cnt(a8_clk));
chk_xprop #(.W(1),.NAME("led_le"))  u_a8l (.clk(clk),.rst_n(rst_n),.sig(le),   .err_cnt(a8_le));
chk_xprop #(.W(OE_N),.NAME("led_oe_n")) u_a8o (.clk(clk),.rst_n(rst_n),.sig(oe_n),.err_cnt(a8_oe));
```
并在末尾把它们并进 `errors`。
- **预期**：收益 = 引脚级防护回到真正驱动引脚的模块上；代价 = 只加 tb，运行时间 +≈0。
- **怎么验**：把 bank 的 OE mux 改成 `assign oe_n_r = ~{OE_N{outputs_enable}}`（模拟 K-01 回归）⇒ `chk_min_pulse` 必须红（这正是变异体 M06 的 bank 版本；M06 现在只打在 driver 上）。
- **来源**：ANVIL-11【P1-3】
@@@END
@@@PRIO=P1|SRC=ANVIL-11|ORIG=P1-4|MOD=tb/w3c/tb_led_data.sv
### 给 tb_led_data 挂上 A8（chk_xprop）
- **位置**：tb/w3c/tb_led_data.sv:62-63（无 chk_xprop）；对照 tb/w3a/tb_led_indicator.sv:104-109、tb/w3a/tb_ws2812_driver.sv:60-62；rtl/w3c/led_data.v:92；rtl/top.v:4854
- **现状**：
```verilog
// tb_led_data.sv:62-63   ← 只取了两根线做值比对，没有任何 X/Z 监视
wire [KEY_N-1:0]        key_lights  = pattern[KEY_N-1:0];
wire [STATUS_N-1:0]     status_lights = pattern[KEY_N+STATUS_N-1:KEY_N];
```
- **为什么是问题**：`led_data.pattern_o`（24 位）是唯一驱动 TLC 总线的源（top.v:4854）。它若含 X：`pattern_changed = (pattern_r !== pattern_next)` 用 `!==`（X 参与比较）⇒ 恒真 ⇒ `commit_r` 每拍拉高 ⇒ bank 每 27.1 µs 重写一轮 ⇒ 灯持续闪烁/乱亮，而所有 tb 都绿。⚠️ 顺带裁定：led_data.v:92 用 `!==`（而非 `!=`）在这里是**正确的** —— `!=` 在 X 下会给出 X 并传播进 `commit_r`。⛔ 不要把它"改成 `!=` 更规范"，那会引入真 X 传播。
- **改法**：
```verilog
reg [31:0] a8_err;
chk_xprop #(.W(24), .NAME("led_data.pattern_o")) u_a8 (
    .clk(clk), .rst_n(rst_n), .sig(pattern), .err_cnt(a8_err));
// 末尾：chk("(8) no X/Z on pattern_o/commit after reset (A8)", a8_err == 32'd0);
```
再加一条不变量断言（把 `!==` 的意图钉死）：`status_i` 故意置 `8'hxx` ⇒ 断言 `commit === 1'b1`（不是 `1'bx`）。
- **预期**：收益 = 把"X 输入 ⇒ 灯狂闪"这条路堵上；代价 = 只加 tb。
- **怎么验**：①把 `status_i` 的某一位置 `1'bx` ⇒ `a8_err` 非 0；②把 :92 的 `!==` 改成 `!=`，在同一激励下断言 `commit !== 1'bx` ⇒ 必红。
- **来源**：ANVIL-11【P1-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-11|ORIG=P1-5|MOD=rtl/w3c/ws2812_driver.v
### 堵住 ws2812_driver 只写 7 颗灯时的 13391 拍 X
- **位置**：rtl/w3c/ws2812_driver.v:99-110、:132-143、:16；rtl/top.v:5019-5043、:5012；tb/w3a/tb_ws2812_driver.sv:150-151、:188-189、:222-225、:250；build/anvil11-probe/tb_anvil11_ws_probe.sv
- **现状**：
```verilog
// ws2812_driver.v:16  ← 模块头【自己推荐】的用法
//    (default 16; it must be >= 7 because there are 7 indicators)
// ws2812_driver.v:99-110   ← mem 没有复位
reg [23:0] mem [0:(1<<LW)-1];
reg [23:0] rd_data;
reg [LW-1:0] rd_addr;
always @(posedge clk) begin
    if (wr_en_i && (wr_addr_i < LED_N))
        mem[wr_addr_i[LW-1:0]] <= wr_data_i;
end
always @(posedge clk) begin
    rd_data <= mem[rd_addr];
end
// ws2812_driver.v:132-143   ← 复位块里逐个清，但【没有 mem】
if (!rst_n) begin
    state <= S_IDLE; busy_o <= 1'b0; ld_cnt <= 2'd0; led_i <= 5'd0;
    bit_i <= 5'd23;  bit_t  <= 6'd0; rst_t  <= 16'd0;
    rd_addr <= {LW{1'b0}}; cur_bit <= 1'b0; sh <= 24'd0;
end
```
- **为什么是问题**：`mem[7..15]` 在仿真里是 x ⇒ `rd_data = x` ⇒ `rd_grb = x` ⇒ `sh = x` ⇒ `cur_bit = x` ⇒ `dout_o = (state==S_SEND) && (bit_t < (cur_bit ? T1H : T0H))` = `1 && x` = **x**。预期拍数 = 9 颗未写的灯 × 24 bit × 62 拍 = **13392**。⭐ 实测（build/anvil11-probe/tb_anvil11_ws_probe.sv，只写 LED0..LED6）：`X cycles on dout_o = 13391   (must be 0)`；`VERDICT: X PROPAGATION REPRODUCED`（13391 ≈ 13392，差 1 是最后一位的边界）。⚠️ 为什么现在没炸：top.v:5019-5043 的写口 FSM 每帧把 addr 0..15 全写一遍（LED7..15 写 `24'h000000`，top.v:5012），tb_ws2812_driver.sv:150-151/188-189/222-225 也全写 16 颗 ⇒ 两条路都把 X 掩掉了。但模块头推荐的"LED_N=7 只写 7 颗"用法会直接踩雷，而 tb_ws2812_driver.sv 的 A8 判据（:250）恒绿。
- **改法**（推荐 (b)，最省）：(a) 复位块里清 `mem`：`for (i=0;i<(1<<LW);i=i+1) mem[i] <= 24'd0;` → 0 LUT，但给 384 个 FF 加同步复位端（会让这 384 FF 无法进 BSRAM）。(b) ⭐ 只清读路径（推荐）：
```verilog
always @(posedge clk) begin
    rd_data <= (rd_addr >= LED_N) ? 24'd0 : mem[rd_addr];
end
```
→ **+1 个 LW 位比较器（4 位）+ 24 位 2:1 mux ≈ 6~8 LUT**，0 额外 FF，且顺手把"越界读"也堵死。(c) 或在端口注释里把契约写成"必须写满 LED_N 颗"（0 代价，但改的是契约而不是缺陷，不推荐）。
- **预期**：收益 = 消除"只写一部分灯 ⇒ 线上 X ⇒ 上板灯乱"的整类问题（也是 A8 判据真正生效的前提）；代价 = (b) ≈ 6~8 LUT；(a) 0 LUT 但 384 FF 带复位。⚠️ 对 Fmax：`rd_addr(4 FF) → 比较器 → mux → rd_data(24 FF)` 是 1~2 级 LUT，远短于 18.181 ns，属噪声级。
- **怎么验**：把 build/anvil11-probe/tb_anvil11_ws_probe.sv 提升为正式 tb/w3a/tb_ws2812_partial.sv（只写 LED0..6 + chk_xprop）。未修 ⇒ `x_cnt = 13391`（已实测）；修后 ⇒ `x_cnt = 0`。
- **来源**：ANVIL-11【P1-5】
@@@END
@@@PRIO=P1|SRC=ANVIL-11|ORIG=P1-6|MOD=constr/top.sdc
### 给 9 根 LED 引脚补输出约束或 false_path（现在工具侧零检查）
- **位置**：constr/top.sdc:62-71、:101、:4-12、:39-40、:45-61、:97-98；constr/top.cst:290-309、:470-471、:488-493
- **现状**：
```tcl
# constr/top.sdc:62-71  ← 只覆盖了这些
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_BCK}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_WS}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {HP_DIN}]
set_false_path -to [get_ports {PA_EN_n}]
set_false_path -to [get_ports {led_heartbeat}]
set_false_path -from [get_ports {rst_n}]
# constr/top.sdc:101
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {clk_sys}] 18.181
# 未出现在 sdc 里的 9 个 LED 引脚（全部在 .cst 里有 IO_LOC）：
led_le A21 · led_sdi B21 · led_clk B18 · led_oe_n[4:0] B17/C17/D17/A19/A18 · ctrl_ws_o C22
```
- **为什么是问题**：`set_max_delay -from [get_clocks X] -to [get_clocks X]` 约束的是被 X 采样的路径（寄存器↔寄存器）；**寄存器 → 输出引脚** 不在 `-to [get_clocks]` 的锥里 ⇒ 这 9 根线根本不被分析。而 top.sdc:4-12 早就写明这个教训（"只看零 error 会漏掉时钟/时序压根没被约束"）。实际风险量化：`led_clk` = 1 MHz（半周期 500 ns），TLC5916 的 `tsu(ED2)=8.5 ns / th(ED2)=10 ns` ⇒ SDI 相对 CLK 的偏移必须 < **490 ns** ⇒ 20 ns 的 FPGA 周期绰绰有余；`ctrl_ws_o`：WS2812B 的 `T0H/T1H` 容差 ±150 ns ⇒ 也宽裕。⇒ **物理风险低**，但**工具侧零检查**，违反本仓库 top.sdc:39-40 的明文纪律（"只有确实不要求时序的路径才配 false_path，且必须写清理由"）。
- **改法**（二选一，⛔ 不要留白）：(a) 与 HP_* 同口径，给真有时序含义的三根加预算：
```tcl
set_output_delay -clock clk_sys -max 2.0 [get_ports {led_clk}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {led_sdi}]
set_output_delay -clock clk_sys -max 2.0 [get_ports {led_le}]
```
(b) 给静态/人眼/宽容差的加 false_path 并写明理由：
```tcl
# led_oe_n[*] = 分板消隐，静态电平选择，无相对时序要求（换片只在 CLK 静止后发生）
set_false_path -to [get_ports {led_oe_n[*]}]
# ctrl_ws_o = WS2812B 单线，位容差 ±150 ns >> clk_sys 周期 20 ns
set_false_path -to [get_ports {ctrl_ws_o}]
```
- **预期**：收益 = 补齐工具侧闭环（top.sdc:97-98 的验收三步才成立）；代价 = **0 硬件**；⚠️ 可能让 PnR 新报 1~2 条 setup 违例 —— 那是"暴露了真问题"，不是回归。⚠️ 加 `set_output_delay` 会像 2026-10-01 那次一样让结果对布局更敏感（top.sdc:45-61 的教训）⇒ 建议先用 (b) 把 4 根宽容差的钉成 false_path，(a) 只给 led_clk/led_sdi/led_le。
- **怎么验**：top.sdc:97-98 的验收三步 —— ①Constraints Report 里这 9 个对象全部 Actived 且非空；②Timing Exceptions Report 确认覆盖到目标锥；③对同一份 PnR 结果复算 Fmax 与四类 slack。⛔ 别只看 Fmax 汇总。
- **来源**：ANVIL-11【P1-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-1|MOD=rtl/top.v
### 把顶层 WS2812 从 1.141 kHz 背靠背连发改成"图案变了才发"
- **位置**：rtl/top.v:5019-5045、:5026-5031、:4932、:4999-5014；rtl/w3c/ws2812_driver.v:62；rtl/w3c/led_data.v:92；tb/top/tb_top_led_strip.sv:269-279
- **现状**：
```verilog
// top.v:5026-5031   ← 没有任何"变了才发"的条件
case (ws_ld_state)
    WLS_WAIT: if (!ws_busy) begin
        ws_wr_en    <= 1'b1;
        ws_wr_addr  <= 5'd0;
        ws_ld_state <= WLS_WRITE;
    end
```
- **为什么是问题**：一帧 = 16 颗 × 24 bit × 62 拍 + `RST_CYC` 20000 拍 = 23808 + 20000 = **43808 拍 = 876.2 µs** ⇒ **刷新率 1.141 kHz**；其中 **54.3%** 在发数据（23808/43808）、**45.7%** 在复位低电平。WS2812B 自保持（锁存后不需要刷新，没有看门狗）⇒ 这 1.141 kHz 在功能上是零收益的。代价侧：①`ctrl_ws_o`（C22）每秒翻转 ≈ 1.14k × 24 × 7 ≈ **19 万次/秒**（7 颗灯的平均翻转率）；②`mem` 每秒被重写 1.14k × 16 = **18.3 千次/秒**；③这是一块音频板，C22 与模拟链在同一块控制板上 ⇒ 持续的 800 kHz 码流是可避免的耦合源。
- **改法**：把 `WLS_WAIT` 改成"图案变了才发"（与 led_data 的 commit 同思想）：
```verilog
reg [NCH_LED*24-1:0] led_col_d;
always @(posedge clk) if (!rst_n_sync) led_col_d <= {(NCH_LED*24){1'b0}};
                      else             led_col_d <= led_col_flat;
wire led_dirty = (led_col_flat !== led_col_d);
// WLS_WAIT: if (!ws_busy && led_dirty) begin ... end
```
⚠️ 两条纪律：①比较的是指示层输出之后的 `led_col_flat`（不是状态码），否则快闪变化会被漏掉；②`!==` 而非 `!=`（与 led_data.v:92 同理由，X 输入下仍然"要发"而不是"不发"）。
- **预期**：收益 = 稳态下 C22 活动降到 ≈0（只在图案变化时爆发 876 µs）、mem 写降到 0、省掉整套 FSM 的连续活动；代价 = **+168 FF（影子寄存器）＋ 168 位比较器（≈42 LUT）** ⇒ ⚠️ 在 CLS 78% 的树上净资源是增加的，换的是动态功耗与模拟耦合；若嫌 168 FF 贵，可只比 7×24 = 168 位中的有效位（已经是 168）或改成比"指示层输入状态码"（更省但漏快闪）。⚠️ 风险中等：比较器写错会让灯卡住不更新。
- **怎么验**：tb_top_led_strip.sv 的 (2) 活体判据（:269-279，发裸 'I' 切音色 ⇒ 下一帧 LED0 必须变青）正好就是这条的判据 —— 改完必须仍然绿。再加一条：连续两帧之间若图案没变，断言线上没有新的帧起点（低电平持续 > 10000 拍不被打断）。
- **来源**：ANVIL-11【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-2|MOD=rtl/drivers/tlc5916_driver.sv
### 用自由运行相位计数器替掉恢复序列里的 %50 与 32 位 integer
- **位置**：rtl/drivers/tlc5916_driver.sv:144-145、:224-227、:240-241、:131-138、:201；tb/drivers/tb_tlc5916_driver.sv:431-481、:443-450
- **现状**：
```verilog
// tlc5916_driver.sv:144-145   ← 32 位【有符号】
integer            rec_phase;               // 稳定期之后过了几拍
integer            rec_in_period;           // 在当前 tlc_clk 周期内的相位
// :224-227
rec_phase     = rec_cnt - REC_SETTLE_CLKS;
rec_in_period = rec_phase % REC_CLK_PERIOD;      // ← 对【50】取模（非 2 的幂）
tlc_clk  <= (rec_in_period < HALF_DIV) ? 1'b1 : 1'b0;
// :240-241
tlc_oe_n <= (rec_phase >= REC_OE_FALL_PH &&
             rec_phase <  REC_OE_FALL_PH + REC_CLK_PERIOD) ? 1'b0 : 1'b1;
// :131-138
localparam integer REC_CLK_PERIOD = 2 * HALF_DIV;        // = 50
localparam integer REC_OE_FALL_PH = HALF_DIV + (HALF_DIV / 2);  // = 37
```
- **为什么是问题**：`REC_CLK_PERIOD = 50`（非 2 的幂）⇒ `%` 综合成"减法-移位/比较"网络，而不是取位。`rec_phase` 的实际取值范围是 **0..299**（`REC_TOTAL_CLKS = 8 + 6×50 = 308`），只需 9 位，却按 **32 位有符号**参与 1 次减法 + 1 次取模 + **4 个 32 位比较器**。保守估计多花 **60~100 LUT** 与若干 `T_Alu`。⚠️ 诚实边界：路径是 `rec_cnt(9 FF) → 32 位减 → %50 → 比较 → tlc_clk/tlc_oe_n FF`，估算 3~5 级 LUT ≈ 1.5~2.5 ns，离 18.181 ns 预算很远；而且它只在上电后跑一次（`recovering` 之后永不再置 1，:201）⇒ 对稳态 Fmax 的贡献 = 0。⛔ 不要把它当"时序问题"报。
- **改法**（(a) 最优）：(a) 用自由运行的相位计数器替掉 `%`：
```verilog
reg [5:0] rec_ph;                     // 0..REC_CLK_PERIOD-1
// 在恢复分支里：
rec_ph <= (rec_ph == REC_CLK_PERIOD-1) ? 6'd0 : rec_ph + 6'd1;
tlc_clk  <= (rec_ph < HALF_DIV) ? 1'b1 : 1'b0;
// OE 低窗口仍用【绝对相位】判（保住 K-66 的"跨 1 个上升沿"）
```
(b) 把 `rec_phase`/`rec_in_period` 声明成 `reg [REC_W-1:0]` / `reg [5:0]`（无符号、窄位）⇒ 4 个比较器从 32 位降到 9/6 位。
- **预期**：收益 = 省 ≈ **60~100 LUT**（在 CLS 78% 的树上属拥塞缓解，不是 Fmax 修复）；代价 = (a) **+6 FF**（相位寄存器）；(b) **0 FF**。⚠️⚠️ 改完必须逐条复跑 tb_tlc5916_driver.sv:431-481 的 K-66 五条判据（跨 1 个 CLK 上升沿 / LE 全程低 / OE 低 ≥ 500 ns / ≥5 个 CLK 周期 / 每次复位恰好一次）—— 那五条就是为这段波形写的，⛔ 一条都不能省。
- **怎么验**：把 `%` 改成错的（如 `rec_phase % (REC_CLK_PERIOD - 1)`）⇒ K-66 的"每个恢复窗口恰好跨过 1 个 CLK 上升沿"（:443-450）必红。
- **来源**：ANVIL-11【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-3|MOD=rtl/w3a/led_indicator.v
### 记档：led_indicator 的 −1.148 MHz 是布局/拥塞，不做流水
- **位置**：rtl/w3a/led_indicator.v:128-129、:194-205；sim/evidence/led-indicator-20261003/README.md:40、:53-54、timing.txt:78；sim/evidence/p5-2-osc-20261004/README.md:97-101；sim/evidence/final-batch-20261008/timing.txt:78；tb/w3a/tb_led_indicator.sv:371-372
- **现状**：
```verilog
// led_indicator.v:128-129
reg [23:0] col_c [0:N_CH-1];
reg [1:0]  blk_c [0:N_CH-1];
// :194-205
always @(posedge clk) begin
    if (!rst_n) begin
        led_col_o <= {(N_CH*24){1'b0}};
    end else begin
        for (oi = 0; oi < N_CH; oi = oi + 1) begin
            led_col_o[oi*24 +: 24] <=
                ((blk_c[oi] == BL_FAST) &&  fast_off)  ? C_OFF :
                ((blk_c[oi] == BL_BEAT) && !beat_lit)  ? C_OFF :
                                                         col_c[oi];
        end
    end
end
```
- **为什么是问题**（钉死归属）：加指示层的 A/B 实测：**Fmax 53.187 → 52.039 MHz = −1.148 MHz**；资源 **T_Lut +91 · T_Register +203**。判读依据 1（自身深度）：led_indicator 的组合深度 ≈ 2~3 级 LUT（`col_c[oi]` 的 case 译码 1 级 → `blk_c[oi]` 2 位比较 1 级 → 两级 2:1 mux 各 1 级），折合 ≈1.5 ns，远短于 18.181 ns。判读依据 2（全局关键路径没变）：加它之前与之后的交付树 `clk_sys` 的 `Logic Level` 都是 **10** ⇒ 关键路径根本不在 led_indicator 里。判读依据 3（同批的因果已写明）：p5-2-osc-20261004/README.md:97-101 把随后 **+3.558 MHz** 归因于"少了 724 LUT / 544 FF ⇒ 布局拥塞下降 ⇒ note_manager 那条路径布线大幅变短" ⇒ 反过来说明 +91 LUT 的指示层是加了拥塞，不是加了自己的长路径。⇒ ⭐ 裁定：−1.148 MHz = 布局/拥塞运气，属那 2~3 MHz 的噪声带。
- **改法**：⭐ **不建议做**（收益 < 测量噪声）。若一定要动，唯一有意义的方向是给输出级加写使能（降 168 FF 的翻转与扇出）：
```verilog
wire [N_CH*24-1:0] led_next = /* 上面那个三元表达式向量化 */;
if (led_col_o !== led_next) led_col_o <= led_next;
```
⚠️ 提醒：Gowin 的 FF 有专用 CE 端，所以 CE 版通常不吃 LUT，但会改变 FF 类型（可能影响 CLS 打包）⇒ 净效果正负难料。
- **预期**：收益 ≈ ±0.1~0.3 MHz 量级（测不出来）；代价 = 约 +24 个比较器位（≈6 LUT）+ 一轮 PnR（10 分钟）+ 必须重跑四道门。⇒ ⭐ 结论：不做。这条写出来是为了把"−1.148 MHz"这个数字的归属钉死，防止后续有人把它当"结构性长路径"去加流水（那是纯浪费）。
- **怎么验**：任何改动都必须让 tb_led_indicator.sv 的 7 组判据保持全绿，特别是 (7c) 相邻上升沿间隔恒 == 2^FAST_DIV（:371-372）—— 那是"共享快闪计数器"这个省资源手法的唯一守卫。
- **来源**：ANVIL-11【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-4|MOD=rtl/w3c/tlc5916_bank.sv
### 把 drv_oe 按 P1-1 接成总闸并清理 drv_data_r 别名
- **位置**：rtl/w3c/tlc5916_bank.sv:147、:163、:183、:187-194；bringup/mutation_test.ps1（M126/M127 锚点）
- **现状**：
```verilog
// tlc5916_bank.sv:147,163
wire        drv_oe;      // driver 的 OE 输出（我们另外做分板 mux）
    .tlc_oe_n       (drv_oe),        // ← 全文【再无第二处】引用
// :183,187-194
reg [CHIP_W-1:0] drv_data_r;
always @(*) begin
    case (chip_sel)
        2'd0: drv_data_r = chip0_out;
        2'd1: drv_data_r = chip1_out;
        default: drv_data_r = chip2_out;
    endcase
end
assign drv_data = drv_data_r;        // ← 只是给 reg 起了个 wire 别名
```
- **为什么是问题**：`drv_oe` 消费者 0 个（机械确认：全文 2 处 = 声明 + 连接）⇒ 综合会优化掉它，且 K-01/K-57 的防护跟着一起消失（这正是 P1-1 的根因）。`drv_data_r` 的中间级是纯风格冗余（drv_data 与 drv_data_r 同宽同值），0 逻辑代价。
- **改法**：`drv_oe` ⛔ **不能删** —— 必须按 P1-1 接成 OE 总闸（`assign led_oe_n_o = oe_n_r | {OE_N{~drv_oe}};`）；`drv_data_r` 可改名成 `drv_data` 并去掉别名（纯风格，0 收益，⚠️ 会动到 M126/M127 变异锚点之外的行，安全）。
- **预期**：收益 = 与 P1-1 合并计算（5 个 OR 门恢复 K-01 防护）；本条自身 0；代价 = 0。
- **怎么验**：综合日志里不应再出现 `drv_oe` 相关的 unused/optimized 警告；P1-1 的新增断言（1 拍 `global_blank_i` 引脚不动）同时覆盖它。
- **来源**：ANVIL-11【P2-4】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-5|MOD=rtl/w3c/ws2812_driver.v
### 把 ws2812_driver 的"飞行中写只影响下一帧"降级成前置条件
- **位置**：rtl/w3c/ws2812_driver.v:52-53、:103-110、:202-205、:49-53；rtl/top.v:5027
- **现状**：
```verilog
// ws2812_driver.v:52-53  ← 承诺
//    A write that lands while the frame in flight
//    is being read simply takes effect on the next frame.
// :103-110   ← 读写共用 mem，无互斥
always @(posedge clk) begin
    if (wr_en_i && (wr_addr_i < LED_N))
        mem[wr_addr_i[LW-1:0]] <= wr_data_i;
end
always @(posedge clk) begin
    rd_data <= mem[rd_addr];
end
// :202-205   ← 预取窗口只有 3 拍
if ((bit_i == 5'd0) && (led_i != LED_N - 1)) begin
    if      (bit_t == 6'd56) rd_addr <= led_nxt[LW-1:0];
    else if (bit_t == 6'd58) sh      <= rd_grb;
end
```
- **为什么是问题**：预取是"地址在 bit_t=56 设、数据在 57 落地、sh 在 58 装"⇒ 存在 **3 拍 = 60 ns** 的窗口，窗口内 `rd_data` 的值取决于写口是否恰好在写同一颗灯。若写口在这 3 拍里写 `rd_addr` 指向的同一颗 LED ⇒ 当前帧的那颗灯会**半新半旧**（撕裂）⇒ 承诺（"只影响下一帧"）不成立；真实语义是"当且仅当写口与预取不撞同一颗灯时才只影响下一帧"。⚠️ 今天不炸是因为 top.v:5027 的 `WLS_WAIT: if (!ws_busy)` 把写口挡在帧外 —— 那是调用方的纪律，⛔ 不是模块的保证。⚠️ 而模块头 :49-53 的 USAGE 段落没有把这条写成前置条件，反而用"simply"把它说成保证。
- **改法**：(a) ⭐ 推荐（0 代价）：把承诺降级为前置条件，写进端口注释：`input wire wr_en_i,   // ⚠️ 只在 busy_o == 0 时给；帧内写同一颗 LED 会撕裂当前帧`，并把 :52-53 那句改成"调用方保证 `wr_en_i` 只在 `busy_o==0` 时有效"。(b) 双缓冲（写 shadow，`start_i` 那一拍整体搬运）⇒ **+384 FF**，⛔ 不划算，不做。
- **预期**：收益 = 契约诚实，避免后续调用方（例如把 WS2812 也接到指引链）踩雷；代价 = **0 硬件**（纯注释）；若选 (b) 是 +384 FF（拒绝）。
- **怎么验**：tb 在 `busy_o == 1` 期间、且恰在 `bit_t ∈ {56,57,58}` 时写"正在被预取的那颗"LED，断言该帧线上字节仍等于旧值。对当前 RTL 必红（会取到新值）。
- **来源**：ANVIL-11【P2-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-6|MOD=rtl/w3c/ws2812_driver.v
### 给 ws2812_driver 补参数自检（六个灯模块里唯一没有的）
- **位置**：rtl/w3c/ws2812_driver.v:79-82、:45、:84-85、:87、:89（全文无 initial）；对照 rtl/w3a/led_indicator.v:80-87、rtl/w3c/led_data.v:110-115、rtl/w3c/tlc5916_bank.sv:270-277、rtl/drivers/tlc5916_driver.sv:91-98、:408-420
- **现状**：
```verilog
// ws2812_driver.v:79-82   ← LW 在 5 位封顶
localparam integer LW = (LED_N <=  2) ? 1 :
                        (LED_N <=  4) ? 2 :
                        (LED_N <=  8) ? 3 :
                        (LED_N <= 16) ? 4 : 5;
// :45   ← 注释给的下界
//    This requires BIT_CYC >= 61 (the prefetch window lives below BIT_CYC-1).
// 对照：兄弟模块都有 initial 自检（led_indicator.v:80-87 / led_data.v:110-115 / tlc5916_bank.sv:270-277 / tlc5916_driver.sv:91-98）
```
- **为什么是问题**：`LED_N > 32`：LW 夹在 5 ⇒ mem 深度 32，而 `led_i` 只有 5 位 ⇒ `led_i == LED_N-1` 永不成立 ⇒ 最后一颗之后的边界判断错，图案错位且静默（0 报错、0 警告）。`BIT_CYC < 60`：预取在 `bit_t==58`，且必须落在 `bit_t != BITN-1` 的分支里 ⇒ 需 `58 < BIT_CYC-1` ⇒ 真实下界是 **60**，而注释写的是 **61**（多算了 1 拍）；若真取 59 或更小，预取窗口与边界判断撞车 ⇒ 位周期被拉长、图案错位。`T0H_CYC/T1H_CYC` 被塞进 `localparam [5:0]`（:84-85）⇒ 传 >63 的值静默截断。`RST_CYC` 塞进 `localparam [15:0]`（:87）⇒ 传 >65535 静默截断。
- **改法**（照抄兄弟模块的 PARAM_OK 套路，:89 的 TLC_PARAM_OK 是最佳范例）：
```verilog
localparam WS_PARAM_OK = (LED_N >= 7) && (LED_N <= 32) &&
                         (BIT_CYC >= 60) && (T0H_CYC < T1H_CYC) && (T1H_CYC < BIT_CYC) &&
                         (RST_CYC >= 15000) && (RST_CYC <= 65535) &&
                         (T0H_CYC <= 63) && (T1H_CYC <= 63);
initial begin
    if (LED_N > 32)    $display("ERROR [ws2812] LED_N=%0d > 32 ⇒ LW 封顶 5 位，led_i 表示不了", LED_N);
    if (BIT_CYC < 60)  $display("ERROR [ws2812] BIT_CYC=%0d < 60 ⇒ 预取窗口(bit_t=58)与边界判断撞车", BIT_CYC);
    if (T0H_CYC > 63 || T1H_CYC > 63) $display("ERROR [ws2812] T*H_CYC 超过 6 位 ⇒ 静默截断");
    if (RST_CYC > 65535) $display("ERROR [ws2812] RST_CYC 超过 16 位 ⇒ 静默截断");
end
```
并把 :45 的 `61` 改成 **60**（见 P3-3）。
- **预期**：收益 = 换参数时看得见（而不是上板才发现灯乱）；代价 = **0 硬件**（综合忽略 initial）；⛔ 但仿真侧只是 `$display`，按 K-57 的教训（M14 当年没被抓到）建议在 tb 里把它提成硬断言（tb_tlc5916_driver.sv:408-420 就是那个修法的范例）。
- **怎么验**：仿 `LED_N=40` 实例 ⇒ 必须打印 ERROR；再加 tb 断言 `dut.WS_PARAM_OK === 1'b1` ⇒ 该实例必红。
- **来源**：ANVIL-11【P2-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-7|MOD=rtl/w3c/led_data.v
### 把 led_data 的 STATUS_N 自检从 <0 改成 <1
- **位置**：rtl/w3c/led_data.v:62、:113-114、:54
- **现状**：
```verilog
// led_data.v:62
input  wire [STATUS_N-1:0]      status_i,         // 状态灯（模式/音色/N，已编码）
// :113-114
if (STATUS_N < 0)
    $display("ERROR [led_data] STATUS_N=%0d 必须 >= 0", STATUS_N);
```
- **为什么是问题**：`STATUS_N` 是 integer 参数（:54）⇒ `STATUS_N < 0` 只在传负数时成立。而真正会炸的是 **`STATUS_N = 0`**：此时 `status_i` 的位选范围是 **`[-1:0]`**（非法范围）⇒ 自检对唯一能炸的值不生效，是死代码。⚠️ 顺带：`pattern_o` 的宽度 `[KEY_N+STATUS_N-1:0]` 在 `STATUS_N=0` 时是 `[15:0]`，是合法的 ⇒ 错误只会出现在 `status_i` 的声明上，报错信息离根因很远。
- **改法**：`if (STATUS_N < 1) $display("ERROR [led_data] STATUS_N=%0d 必须 >= 1（=0 会让 status_i 的范围变成 [-1:0]）", STATUS_N);` 或把端口宽度改成 `[((STATUS_N < 1) ? 1 : STATUS_N)-1:0]` 并保留 `STATUS_N>=1` 自检。
- **预期**：收益 = 换参数时报出真因；代价 = **0 硬件**。
- **怎么验**：用 `STATUS_N=0` 实例化 ⇒ 当前会编译期报范围错/综合报错（而不是打印 ERROR）；修后应打印 ERROR 且编译通过。
- **来源**：ANVIL-11【P2-7】
@@@END
@@@PRIO=P2|SRC=ANVIL-11|ORIG=P2-8|MOD=rtl/w3c/tlc5916_bank.sv
### 给 tlc5916_bank 补"片数 ≤ 3"的上限自检
- **位置**：rtl/w3c/tlc5916_bank.sv:181、:245、:187-193、:270-277、:243-254
- **现状**：
```verilog
// tlc5916_bank.sv:181
reg [1:0]  chip_sel;      // 0/1 = 键灯片，2 = 状态灯片
// :243-254   ← 终止条件写死 2'd2
if (!drv_busy && drv_done) begin
    if (chip_sel == 2'd2) begin
        chip_sel <= 2'd0; busy_r <= 1'b0; state <= S_IDLE;
    end else begin
        chip_sel <= chip_sel + 2'd1;
        state    <= S_START;
    end
end
// :270-277   ← 自检没查"片数 <= 3"
if (KEY_CHIPS + STATUS_CHIPS < 1)          $display("ERROR ... 至少 1 片 TLC5916");
if (CHIP_W != 8)                           $display("ERROR ... CHIP_W=%0d 非法", CHIP_W);
if (OE_N < KEY_CHIPS + STATUS_CHIPS)       $display("ERROR ... OE_N=%0d 少于片数 %0d", ...);
// ⛔ 没有：if (KEY_CHIPS + STATUS_CHIPS > 3) ...
```
- **为什么是问题**：`KEY_CHIPS + STATUS_CHIPS > 3` 时（例如 KEY_CHIPS=3, STATUS_CHIPS=1 ⇒ 4 片）：FSM 在 `chip_sel == 2'd2` 就回 S_IDLE ⇒ **第 4 片永远不被写**（0 报错、0 警告、`busy_o` 正常回落）。而 `drv_data_r` 的 `default: drv_data_r = chip2_out;`（:191）会把 ≥2 的所有片都当片2 ⇒ 若将来真扩到 4 片，片3 会拿到片2 的图案。当前配置（2+1=3）正好卡在上限，所以今天不出错 —— 但下一个加片的人会静默踩雷。
- **改法**（(a) 只加护栏，(b) 真参数化）：(a) `if (KEY_CHIPS + STATUS_CHIPS > 3) $display("ERROR [tlc5916_bank] 片数 %0d > 3：FSM 的 chip_sel 与终止条件只支持 3 片", KEY_CHIPS+STATUS_CHIPS);` (b) 真参数化：`localparam integer NCHIP = KEY_CHIPS + STATUS_CHIPS;`、`reg [$clog2(NCHIP)-1:0] chip_sel;`、终止条件改 `chip_sel == NCHIP-1`、`drv_data_r` 的 case 用 generate 展开（⛔ 注意本仓库 K-91：`$clog2` 在 Gowin 里可用，但 `longint'()` 不可用）。
- **预期**：(a) **0 硬件**；(b) +0 FF、+1 个常量比较器，但改动面较大（chip_sel 位宽、OE mux 的 else 分支要一起参数化），风险中等。
- **怎么验**：`KEY_CHIPS=3, STATUS_CHIPS=1` 实例化 ⇒ 必须打印 ERROR；再加 tb 断言"4 片配置下 4 个 chip_sel 都被访问过"⇒ 当前必红（只访问 0/1/2）。
- **来源**：ANVIL-11【P2-8】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-1|MOD=rtl/w3c/guide_lamp.v
### 给 guide_lamp 补 timescale 与 default_nettype none
- **位置**：rtl/w3c/guide_lamp.v:1、:28-30、文件末尾；对照 rtl/w3c/ws2812_driver.v:1、rtl/w3a/led_indicator.v:1、rtl/w3c/led_data.v:1、rtl/w3c/tlc5916_bank.sv:1、rtl/drivers/tlc5916_driver.sv:1；rtl/top.v:741；sim/evidence/final-batch-20261008/regression-full.log
- **现状**：
```verilog
// guide_lamp.v:1   ← 没有 `timescale
// ═══════════════════════════════════════════════════════════════════════════
//  guide_lamp.v —— 音符事件 → 灯位指引映射层（丙线 · P1 · 2026-10-03）
// :28-30
module guide_lamp #(
```
- **为什么是问题**：缺 `timescale` ⇒ iverilog 按编译顺序从前一个文件继承，并每次报 `warning: timescale for guide_lamp inherited from another file.`；实测计数：sim/evidence/final-batch-20261008/regression-full.log 里这一句出现 **250+ 次**（每个 tb 编译一次）。缺 `default_nettype none` ⇒ 打错信号名会静默生成 1 位隐式网线（本仓库 top.v:741 明确记过这个坑）。⚠️ guide_lamp 内部没有延时，所以当前无功能影响 —— 但 250 行噪声会掩盖真警告，这是真实成本。
- **改法**：
```verilog
`timescale 1ns/1ps
`default_nettype none
// ... module ...
`default_nettype wire
```
并在 `default_nettype none` 打开后补上所有中间信号的显式声明（is_note_on/is_note_off/note_kind/note_axis 已是 wire，OK）。
- **预期**：收益 = 回归日志少 250+ 行噪声 + 打错名字会报错；代价 = **0 硬件**。
- **怎么验**：编译时 `warning: timescale for guide_lamp inherited` 必须消失（grep 回归日志计数 == 0）。
- **来源**：ANVIL-11【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-2|MOD=rtl/w3c/guide_lamp.v
### 把 guide_lamp 的 note_axis 从硬编码 4 位改成 $clog2(AXIS_N)
- **位置**：rtl/w3c/guide_lamp.v:31-32、:63、:84、:89；rtl/drivers/tlc5916_driver.sv:71-86（K-91 说明）
- **现状**：
```verilog
// guide_lamp.v:31-32
parameter integer EVT_W = 64,        // 事件数据位宽（与 play_seq 一致）
parameter integer AXIS_N = 16        // 键位数（轴号 0..15）
// :63
wire [3:0]  note_axis = note_data_i[AXIS_SH +: 4];   // 轴号 0..15
// :84,89
guide_key_o[note_axis] <= 1'b1;
guide_key_o[note_axis] <= 1'b0;
```
- **为什么是问题**：`note_axis` 恒为 4 位（0..15），与 `AXIS_N` 无关。若 `AXIS_N < 16`（例如 8）：`guide_key_o[note_axis]` 对 `note_axis >= AXIS_N` 是越界写 ⇒ 仿真静默丢位，综合可能生成错接/锁存。0 报错、0 警告。当前 `AXIS_N = 16`（top.v 未例化，tb 用 16）⇒ 今天安全。
- **改法**：
```verilog
localparam integer AXIS_W = (AXIS_N <= 1) ? 1 : $clog2(AXIS_N);   // AXIS_N=16 ⇒ 4
wire [AXIS_W-1:0] note_axis = note_data_i[AXIS_SH +: AXIS_W];
// 并加自检（当前契约就是 16）
initial if (AXIS_N != 16) $display("ERROR [guide_lamp] AXIS_N=%0d：位域契约固定 4 位（轴 0..15）", AXIS_N);
```
⚠️ 注意本仓库 K-91：`$clog2` 在 Gowin 里可用，但 **`longint` / `longint'()` 不可用**（tlc5916_driver.sv:71-86 记过）。
- **预期**：收益 = 换 AXIS_N 时不会静默错；代价 = **0 硬件**（AXIS_N=16 时 AXIS_W=4，与现状逐位等价）。
- **怎么验**：`AXIS_N=8` 实例 + 喂 `axis=15` 的 `note_on` ⇒ 当前静默无输出（灯不亮且不报错）；修后必须打印 ERROR。
- **来源**：ANVIL-11【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-3|MOD=rtl/w3c/ws2812_driver.v
### 把 ws2812_driver 注释里的预取下界 61 改成 60
- **位置**：rtl/w3c/ws2812_driver.v:44-45、:61；tb/w3a/tb_ws2812_driver.sv:168-169
- **现状**：
```verilog
// ws2812_driver.v:44-45
//    therefore no "reload gap" that would stretch one bit.  This requires
//    BIT_CYC >= 61 (the prefetch window lives below BIT_CYC-1).
// :61
parameter integer BIT_CYC = 62,     // bit period, cycles @50 MHz (>= 61)
```
- **为什么是问题**：预取在 `bit_t == 6'd56`（设地址）与 `bit_t == 6'd58`（装 sh），且这两句在 else（即 `bit_t != BITN-1`）分支里。要保证 `58` 落在这个 else 分支，需 **`58 < BIT_CYC - 1`** ⇒ **`BIT_CYC >= 60`**。注释写 61 是多算了 1 拍（保守，但不准确）。
- **改法**：:45 与 :61 的 `61` 改成 `60`；若想保留保守值，就写成"实际下界 60，这里取 61 留 1 拍余量"。
- **预期**：收益 = 换参数时不会误以为 60 不可用；代价 = 0。
- **怎么验**：用 `BIT_CYC=60` 实例化，跑参数化的位周期判据（== 60 拍）⇒ 当前 RTL 应该通过（即证明 60 是可行的，注释的 61 偏保守）。⚠️ 直接用 tb_ws2812_driver.sv:168-169 的 `62..63` 判据会红 —— 那是参数变了，不是 bug。
- **来源**：ANVIL-11【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-4|MOD=rtl/w3c/ws2812_driver.v
### 保留 ws2812_driver 的不可达 default（并写明将来会变必需）
- **位置**：rtl/w3c/ws2812_driver.v:89-92、:120、:220；对照 rtl/drivers/tlc5916_driver.sv:352-359
- **现状**：
```verilog
// ws2812_driver.v:89-92,120
localparam [1:0] S_IDLE = 2'd0, S_LOAD = 2'd1, S_SEND = 2'd2, S_RST = 2'd3;
reg [1:0]  state;
// :220
default: state <= S_IDLE;
```
- **为什么是问题**：`state` 是 2 位，四个编码 0/1/2/3 全部有定义 ⇒ `default` 分支不可达，综合会删掉它（0 逻辑）。⚠️ 对比 tlc5916_driver.sv:352-359：那里 `state` 是 3 位却有 5 个状态（0..4），`default` 覆盖 3 个未用编码（5/6/7）⇒ 那里是必需的安全网。
- **改法**：**不改**（保留作防御）。⚠️ 但若将来把 `state` 扩成 3 位或加状态，这个 `default` 就变成必需 —— 注释里应写明这一点。
- **预期**：收益 = 防止后来者"清理死代码"时误删安全网；代价 = 0。
- **怎么验**：无行为差异 ⇒ 用综合报告的 "unreachable branch" 类警告作为证据（若有）。
- **来源**：ANVIL-11【P3-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-5|MOD=constr/top.cst,rtl/w3c/tlc5916_bank.sv
### 在 .cst 里注明 led_oe_n[2]/[3] 是恒高预留
- **位置**：rtl/w3c/tlc5916_bank.sv:65、:199-205；constr/top.cst:304-309；tb/w3c/tb_tlc5916_bank.sv
- **现状**：
```verilog
// tlc5916_bank.sv:199-205
oe_n_r = {OE_N{1'b1}};              // 默认全灭
if (state != S_IDLE && !global_blank_i) begin
    if (chip_sel == 2'd0)      oe_n_r[0] = 1'b0;
    else if (chip_sel == 2'd1) oe_n_r[1] = 1'b0;
    else                        oe_n_r[4] = 1'b0;  // 状态灯 = 右手板 B = oe[4]
end
// constr/top.cst:304-309  ← 有 IO_LOC 但没写"恒高预留"
IO_LOC  "led_oe_n[2]" D17;   // ⭐ J9 · N22 · SDRAM0_A11
IO_LOC  "led_oe_n[3]" A19;   // ⭐ J9 · N23 · SDRAM0_A7
```
- **为什么是问题**：`KEY_CHIPS=2 + STATUS_CHIPS=1 = 3` 片 ⇒ 只用到 `[0]`/`[1]`/`[4]`；`oe_n_r[2]` 与 `oe_n_r[3]` 永远是 1（消隐），对应左手板第 3/4 块板（预留）。这是正确的预留行为，但 .cst 里没有说明 ⇒ 将来接线的人可能以为它们会动。
- **改法**：在 constr/top.cst:304-309 旁加一行注释 `// ⭐ 恒高预留：tlc5916_bank 只用 oe[0]/oe[1]/oe[4]（KEY_CHIPS=2,STATUS_CHIPS=1）` ＋ 在 tb_tlc5916_bank.sv 加断言 `oe_n[3:2] === 2'b11` 钉死。
- **预期**：收益 = 防误接；代价 = 0。
- **怎么验**：tb 断言 `oe_n[3:2] === 2'b11`（当前恒真；若有人把 else 分支改错会红）。
- **来源**：ANVIL-11【P3-5】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-6|MOD=rtl/w3a/led_indicator.v
### 把 led_indicator 的 looper 显示改成显式 4 分支（第 4 态给洋红）
- **位置**：rtl/w3a/led_indicator.v:169-176；rtl/top.v:3669-3670、:1261-1263
- **现状**：
```verilog
// led_indicator.v:169-176
case (looper_i)
    2'd1: begin col_c[4] = C_RED;   blk_c[4] = BL_FAST; end   // 录音：红快闪
    2'd2: begin col_c[4] = C_GREEN; blk_c[4] = BL_STEADY; end // 回放：绿常亮
    default: begin
        col_c[4] = C_DIMBLUE;                                     // 空闲：暗蓝常亮
        blk_c[4] = BL_STEADY;
    end
endcase
```
- **为什么是问题**：`looper_i` 是 2 位（4 个编码），只有 0/1/2 有语义；`2'd3` 与 `2'd0` 同色。今天 top.v:3669-3670 只产生 0/1/2 ⇒ 安全。但 looper 若加第 4 态（例如"叠录"），`2'd3` 会被静默显示成"空闲暗蓝" —— 灯在说谎（正是 top.v:1261-1263 记过的 `led_gear_st` 同类坑）。
- **改法**：把 `2'd0:` 显式列出，`2'd3:` 给一个显眼的非法色（例如洋红 `C_MAGENTA`），或在 initial 里加 `if (looper_i > 2) $display("ERROR ...")`（那需要 looper_i 上电值，做不到）⇒ ⭐ 推荐改成显式 4 分支（2'd0/2'd1/2'd2/2'd3），2'd3 用洋红，一眼看出"没人定义这个态"。
- **预期**：收益 = 新态不会被静默吞掉；代价 = **0 LUT**（case 展开不变）+ 1 个颜色常量。
- **怎么验**：tb 加 `drive(..., looper=2'd3, ...)` ⇒ 断言 `col != X_DIMBLUE`。当前必红（就是暗蓝）。
- **来源**：ANVIL-11【P3-6】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-7|MOD=rtl/w3c/tlc5916_bank.sv
### 给 tlc5916_bank 的 S_WAIT_BUSY 加握手看门狗
- **位置**：rtl/w3c/tlc5916_bank.sv:241-255、:267；rtl/top.v:4829、:4861；tb/drivers/tb_tlc5916_driver.sv:164-171
- **现状**：
```verilog
// tlc5916_bank.sv:241-255   ← 无超时，只有 done 才能出去
S_WAIT_BUSY: begin
    drv_start_r <= 1'b0;
    if (!drv_busy && drv_done) begin
        if (chip_sel == 2'd2) begin chip_sel <= 2'd0; busy_r <= 1'b0; state <= S_IDLE; end
        else begin chip_sel <= chip_sel + 2'd1; state <= S_START; end
    end
end
// top.v:4829,4861   ← busy_o 有驱动，但【没有任何消费者】
wire        led_busy;
        .busy_o          (led_busy)
```
- **为什么是问题**：`drv_done` 由 driver 保证（正常路径），但一旦 driver 被改坏（或将来加了别的 start 源），bank 会永久卡在 S_WAIT_BUSY 且 `busy_o` 恒 1；而 `busy_o` 接到 top.v 的 `led_busy` 之后没有任何读取（见 P3-8）⇒ 外部零症状，只能靠 tb 超时（200 ms 后一条泛泛的 FAIL）。正常一轮 ≈ 1353 拍；给个 **4096 拍**（≈82 µs）看门狗绰绰有余。
- **改法**：加 12 位看门狗 + 一个粘滞错误位：
```verilog
reg [11:0] wd;  reg err_sticky;
// S_WAIT_BUSY 里：if (wd == 12'd4095) begin err_sticky <= 1'b1; state <= S_IDLE; busy_r <= 1'b0; end
//                 else wd <= wd + 1'b1;
```
并把 `err_sticky` 引出成端口（或并进某个已有状态总线）供上板观测。
- **预期**：收益 = "卡死"变成"一条清楚的信号"（对照 tb_tlc5916_driver.sv:164-171 的"tb 里任何等待都要有上限"纪律）；代价 = **+12 FF + ~15 LUT**。
- **怎么验**：临时把 driver 的 `done <= 1'b1;` 去掉 ⇒ 看门狗必须置位、`busy_o` 必须回落（当前 tb 只会 200 ms 后报一条泛泛的 timeout）。
- **来源**：ANVIL-11【P3-7】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-8|MOD=rtl/top.v
### 把 top.v 的 led_busy 接进可观测寄存器（或删掉）
- **位置**：rtl/top.v:4829、:4861；rtl/w3c/tlc5916_bank.sv:267
- **现状**：
```verilog
// top.v:4829
wire        led_busy;
// :4861
.busy_o          (led_busy)
// 机械确认：led_busy 全文 2 处 = 声明 + 连接，0 个消费者
```
- **为什么是问题**：综合会把它优化掉（0 逻辑），但它掩盖了 P3-7 —— 若把 `led_busy` 接到一个状态寄存器（像 `reserved_in_r` 那样 `syn_keep`），上板就能观测"TLC 是否在写"。
- **改法**：二选一 —— ①接进一个可观测寄存器（推荐，顺带给 P3-7 的看门狗一个出口）：
```verilog
(* syn_keep = 1 *) reg led_busy_r;
always @(posedge clk) if (!rst_n_sync) led_busy_r <= 1'b0; else led_busy_r <= led_busy;
```
②或删掉 `led_busy` 与 `.busy_o()` 的连接（省一行，但失去观测点）。⛔ 推荐 ①。
- **预期**：收益 = 多一个上板观测点；代价 = **+1 FF**。
- **怎么验**：综合日志里不应再有 `led_busy` unused 警告；P3-7 的看门狗 tb 会用到它。
- **来源**：ANVIL-11【P3-8】
@@@END
@@@PRIO=P3|SRC=ANVIL-11|ORIG=P3-9|MOD=rtl/w3a/led_indicator.v
### 给 led_indicator 的 fast_cnt 加使能（没人闪的时候别烧电）
- **位置**：rtl/w3a/led_indicator.v:108-115；tb/w3a/tb_led_indicator.sv（7c/7d/7f）
- **现状**：
```verilog
// led_indicator.v:108-115
reg [FAST_DIV-1:0] fast_cnt;
always @(posedge clk) begin
    if (!rst_n) fast_cnt <= {FAST_DIV{1'b0}};
    else        fast_cnt <= fast_cnt + 1'b1;
end
wire fast_off = fast_cnt[FAST_DIV-1];
```
- **为什么是问题**：`FAST_DIV=23` ⇒ **23 个 FF 每拍翻转**（50 MHz 下最低位 25 MHz 翻转）。只有 `blk_c[4] == BL_FAST`（= looper 录音）时才需要它；其余 99% 的时间里它在白烧动态功耗。量级很小（23 FF @50 MHz），但这是纯浪费，且它在每个时钟周期都在动。
- **改法**：
```verilog
wire fast_en = (blk_c[4] == BL_FAST);      // N_CH=7 时只有第 4 路用快闪
always @(posedge clk) begin
    if (!rst_n)         fast_cnt <= {FAST_DIV{1'b0}};
    else if (fast_en)   fast_cnt <= fast_cnt + 1'b1;
end
```
⚠️ 副作用：计数器在非录音期间冻结，录音一开始从冻结值继续 ⇒ 第一次闪的相位不确定。⭐ 这**不影响** tb_led_indicator.sv 的 (7c)（它量的是"相邻上升沿间隔恒 == 2^FAST_DIV"，冻结恢复后周期仍精确）。
- **预期**：收益 = 省 23 FF 的持续翻转；代价 = **+1 LUT（fast_en 已经是现成的比较）+ 1 个 CE 门**，且改变了闪烁的绝对相位（视觉上无差别）。⚠️ 若将来有第 2 路用 BL_FAST，`fast_en` 要改成"任意一路是 BL_FAST"。
- **怎么验**：tb_led_indicator.sv 的 (7c)(7d)(7f) 必须仍然全绿；再加一条反证：断言"非录音时 fast_cnt 不变"（当前必红，因为它在跑）。
- **来源**：ANVIL-11【P3-9】
@@@END
@@@TOTAL SRC=ANVIL-11 COUNT=27 P0=4 P1=6 P2=8 P3=9
