@@@PRIO=P0|SRC=ANVIL-07|ORIG=P0-1|MOD=rtl/w3a/fader_gear.v
### 给档 0 的接管判据加原始域死区，止住阈值上 ±1 LSB 抖动每帧覆盖串口变调值
- **位置**：rtl/w3a/fader_gear.v:171（判据）、:217（接管 mux）、:235（历史值刷新）、:127-139（阈值表）、:169-173、:213-219、:222-231、:232-236；rtl/w3a/right_analog_ctrl.v（ch2_i 来源）；rtl/top.v:1793；rtl/drivers/adc_farm.sv:51
- **现状**：
```verilog
// rtl/w3a/fader_gear.v:169-173
    // ⭐ ① 推子动过 = ⭐ **量化档位**变了（⭐ 与上一拍不同）
    //   ⭐ ±1 LSB 抖动只要没跨过半音档边界 ⇒ `fader_enc` 不变 ⇒ ⛔ 不接管 ✅
    wire fader_moved = (fader_enc != fader_enc_q);
    // ⭐ ② 刚切进档 0（⭐ `gear_q` 是上一拍档位 ⇒ 该条件只成立**一拍**）
    wire gear0_enter = (gear_o == 2'd0) && (gear_q != 2'd0);
// :213-219
    always @(*) begin
        if      (trans_down_i)   enc_next = down_sat;
        else if (trans_up_i)     enc_next = up_sat;
        else if (trans_abs_i)    enc_next = abs_sat;
        else if (gear_o == 2'd0) enc_next = (fader_moved || gear0_enter) ? fader_enc : enc_r;
        else                     enc_next = enc_r;
    end
// :235（每拍无条件刷新）
            fader_enc_q <= fader_enc;
```
- **为什么是问题**：`gear_step_of()` 是 12 段单调阈值量化器，阈值 = `ceil(4095k/12)`：`k=1..12 → t=342 683 1024 1365 1707 2048 2389 2730 3072 3413 3754 4095`。`ch2_i` 来自 right_analog_ctrl.vibrato_depth_o，每 500 µs 帧更新一次（`CHANNEL_RATE_HZ=2000`，adc_farm.sv:51），而 calib 目前旁路（rtl/top.v:1793 注释"本版先【旁路】标定"）⇒ ADC 抖动没有任何滤波。于是若推子停在阈值 ±1 LSB 内（例如 `ch2_i = 2047 ↔ 2048`，2048 正是 step5/step6 的边界）：拍 n `ch2_i=2047`、step 5、`fader_enc=7`、`fader_enc_q=7`、`fader_moved=0` ⇒ `enc_next=enc_r`；拍 n+1 `ch2_i=2048`、step 6、`fader_enc=6`、`fader_enc_q=7`、`fader_moved=1` ⇒ `enc_next = fader_enc = 6` ⇒ `enc_r` 被改写；拍 n+2 又回到 7 ⇒ **每帧为真 ⇒ 串口值每帧被覆盖**。这正是 P3.2 当初要修的同一个病灶：P3.1 是"原始 12 位比较 ⇒ 每拍为真"，P3.2 改成"量化档位比较 ⇒ 只有跨边界才为真"，但噪声本身就能跨边界 ⇒ 触发窗口只是从 **100%** 缩到 **12 个阈值 × ±1 LSB / 4096 ≈ 0.6%**（噪声若 ±2 LSB ⇒ 1.2%）。文件头 :70-72 写"相当于天然的迟滞/死区" —— 这个"天然迟滞"只在档位中间成立，在阈值上不成立。现有 tb 抓不到（tb/w3a/tb_fader_gear.sv）：H4（:377-383）抖的是 `1999/2001`（两点都在 step5 内部，`fader_enc` 恒 7）；H11（:413-419）抖的是 `2048/2049`（两点都在 step6 内部，恒 6）⇒ H 组刻意避开了"跨边界"这一种抖动，判据存在结构性空洞。
- **改法**（不改 `gear_step_of`、不改 C12 全 4096 点扫描判据，只在"接管判据"上加原始域死区）：
```verilog
//   ⚠️ 必须用 13 位中间量：ch2_taken 最大 4095，+8 会溢出 12 位回绕成 7
localparam [12:0] TAKEOVER_DEADBAND = 13'd8;
reg [11:0] ch2_taken, ch3_taken;
wire raw_moved =
    ( {1'b0, ch2_i} >  ({1'b0, ch2_taken} + TAKEOVER_DEADBAND) ) ||
    ( ({1'b0, ch2_i} + TAKEOVER_DEADBAND) < {1'b0, ch2_taken} ) ||
    ( {1'b0, ch3_i} >  ({1'b0, ch3_taken} + TAKEOVER_DEADBAND) ) ||
    ( ({1'b0, ch3_i} + TAKEOVER_DEADBAND) < {1'b0, ch3_taken} );
// 把 :217 的 fader_moved 换成 raw_moved
        else if (gear_o == 2'd0) enc_next = (raw_moved || gear0_enter) ? fader_enc : enc_r;
// 寄存器块内（:232-236 附近）增加：每次真正接管后，把"已接管值"钉住
        if ((enc_next != enc_r)) begin
            ch2_taken <= ch2_i;
            ch3_taken <= ch3_i;
        end
// 复位（:222-231 段）补：ch2_taken <= 12'd0; ch3_taken <= 12'd0;
```
为什么这个改法零回归（逐条对 tb_fader_gear 的 H 组）：H4 抖动 ±1 LSB < 死区 8 ⇒ `raw_moved=0` ✅；H7/H9/H10 跨 1707/2048 边界 = 341 LSB 级移动 ≫ 8 ⇒ 仍立刻接管 ✅；F8 `ch3` 0→2048 ≫ 8 ⇒ 接管 ✅；C12a/C12b（全 4096 点 == `floor(c*12/4095)`）`gear_step_of` 一字未动 ⇒ 逐值不变 ✅；G4/G10 走 `gear0_enter`，与 `raw_moved` 无关 ⇒ 不变 ✅。
- **预期**：+24 FF（2×12）· +约 24 LUT（4 个 13 位比较 + 4 个 13 位加法）· 接管延迟 **0 拍**（死区是组合的，不引入等待）· 风险低（唯一影响是"推子移动 < 8 LSB 时不再接管" —— 而 8 LSB 在半音行程 341 LSB 下 = **2.3% 的半音行程**，用户不可感）。
- **怎么验**：在 tb/w3a/tb_fader_gear.sv 的 H 组末尾追加（沿用现有 `chk_cnt` 计数式判据）：
```verilog
pulse_abs(8'd24);                       // 串口钉 +12
h_bad = 0;
for (c = 0; c < 24; c = c + 1) begin
    ch2 = (c % 2 == 0) ? 12'd2047 : 12'd2048;   // ⭐ 横跨 step5/step6 边界
    @(negedge clk);
    if (semi != 12) h_bad = h_bad + 1;
end
chk_cnt("H12 [P3.3] +-1 LSB dither STRADDLING the 2048 edge => +12 held EVERY cycle", h_bad);
```
预期：改前 `h_bad = 24`（每拍都丢）⇒ FAIL；改后 `h_bad = 0` ⇒ PASS。
- **来源**：ANVIL-07【P0-1】
@@@END
@@@PRIO=P0|SRC=ANVIL-07|ORIG=P0-2|MOD=rtl/w3a/play_mode_ctrl.v
### 让键盘模式也记账 gate，止住模式切换期间松键被吞导致的挂音
- **位置**：rtl/w3a/play_mode_ctrl.v:51-58（键盘分支）、:59（指板拨弦分支）、:66-67、:76（OFF 判据）；rtl/top.v:938、:3218
- **现状**：
```verilog
// rtl/w3a/play_mode_ctrl.v:48-84
        end else begin
            evt_valid_o <= 1'b0;
            if (!fretboard_mode_i) begin
                // Keyboard: threshold crossing and release are directly musical.
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                end
            end else if (pluck_valid_i && selected_valid) begin
                ...
                gate_valid  <= 1'b1;
                gate_axis   <= selected_axis;
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;
                    selected_depth <= axis_depth_i;
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && (axis_i == gate_axis)) begin   // ← 🔴 只有这一条路能发 OFF
                        evt_valid_o <= 1'b1;
                        ...
                        gate_valid  <= 1'b0;
                    end
                end
            end
        end
```
- **为什么是问题**：①键盘模式（`!fretboard_mode_i`）从不写 `gate_valid`/`gate_axis`（:66-67 只在拨弦分支里写）⇒ 键盘模式下 `gate_valid` 恒 0；②指板模式下的 OFF 事件唯一出口是 :76 的 `gate_valid && (axis_i == gate_axis)` ⇒ `gate_valid=0` 时一个 OFF 都发不出去；③`fretboard_mode_i` 接的是 `play_fretboard_mode = ~ui_mode_piano`（rtl/top.v:938，且 :3218 例化传入）—— 这是运行期信号（音色循环 BASS→GUITAR→PIANO→PAD），不是编译期常量。复现序列：键盘模式下按住一个键（`evt_kind=ON`，voice 起音）→ 切到 PIANO（`fretboard_mode_i=1`）→ 松键：指板分支走 `else if (axis_valid_i)`（`pluck_valid_i` 为 0）；`axis_i == selected_axis` 不成立（键盘模式从没写过 `selected_axis`，保持复位 0，除非恰好是轴 0）；`gate_valid(0) && …` 为假 ⇒ `evt_valid_o` 一拍都不抬 ⇒ 下游永远收不到 `note_off` ⇒ **挂音**。现有 tb 抓不到：tb/w3a/tb_play_mode_ctrl.sv:78 把 `fretboard_mode=1` 设在任何键盘事件之前，此后没再切回 0（:78-92）⇒ "模式切换"这个维度根本没被覆盖。
- **改法**（键盘分支补上"正在响的轴"记账；零回归）：
```verilog
            if (!fretboard_mode_i) begin
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                    // ⭐ 新增：键盘模式也维护"正在响的轴" ⇒ 切到指板模式后 :76 的 gate 判据仍能放掉这个音
                    if (axis_kind_i == KIND_ON) begin
                        gate_valid <= 1'b1;
                        gate_axis  <= axis_i;
                    end else if (axis_kind_i == KIND_OFF) begin
                        gate_valid <= 1'b0;
                    end
                end
            end
```
- **预期**：+1 FF（`gate_valid` 在键盘模式下变活）· 0 LUT 增量（`gate_axis` 的写口从 2 个变 3 个，多一级 mux ≈ 4 LUT）· 对既有判据零影响（键盘模式行为完全不变，因为键盘分支在 if/else if 链最前面，仍然优先转发）。
- **怎么验**：在 tb/w3a/tb_play_mode_ctrl.sv 追加：
```verilog
        fretboard_mode = 1'b0;
        axis_evt(4'd3, 2'd0, 12'd700);            // 键盘 ON ⇒ evt
        fretboard_mode = 1'b1;                    // ⭐ 运行期切模式（PIANO）
        axis_evt(4'd3, 2'd1, 12'd0);              // 松键
        repeat (2) @(posedge clk);
        chk("mode-switch: release still emits note_off", events_kind[event_n-1] == 2'd1);
```
预期：改前 `event_n` 不变 ⇒ FAIL；改后收到一条 `KIND_OFF` ⇒ PASS。
- **来源**：ANVIL-07【P0-2】
@@@END
@@@PRIO=P0|SRC=ANVIL-07|ORIG=P0-3|MOD=rtl/w3a/play_mode_ctrl.v
### 释放判据放宽到"响着的轴或选中的轴"，并发响着的那个轴
- **位置**：rtl/w3a/play_mode_ctrl.v:73-83（尤其 :76 与 :78）、:59-67、:71；tb/w3a/tb_play_mode_ctrl.sv:85-92
- **现状**：
```verilog
// rtl/w3a/play_mode_ctrl.v:73-83
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && (axis_i == gate_axis)) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= axis_i;          // ← 🔴 发的是"被松开的轴"，不是"正在响的轴"
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                    end
                end
```
- **为什么是问题**：`gate_axis` 只在拨弦那一拍被锁存（:67），此后只有再次拨弦才会更新（:59 分支）；而 `selected_axis` 会随每一次 `KIND_ON` 更新（:71）。复现序列（指板模式，滑品不重拨 —— 吉他上极常见）：①`axis_evt(6, ON)` ⇒ `selected_axis=6`，无 evt；②`pluck_evt` ⇒ evt `KIND_PLUCK axis=6`，`gate_valid=1`、`gate_axis=6`（voice 起音）；③`axis_evt(9, ON)` ⇒ `selected_axis=9`（`gate_axis` 仍是 6）；④`axis_evt(9, OFF)` ⇒ `axis_i(9) == selected_axis(9)` ⇒ 清 `selected_valid`；但 `gate_valid(1) && (9 == 6)` = 假 ⇒ 不发 OFF ⇒ 步骤②起的音永远不释放 ⇒ 挂音。现有 tb 抓不到：tb_play_mode_ctrl.sv:89-92 做了步骤③（`axis_evt(4'd9, 2'd0, …)` + 拨弦），但从来没有松开轴 9，测试就结束了 ⇒ "换轴后释放"这一格是空的；:85-87 唯一覆盖的释放是 `axis_evt(4'd6, 2'd1, …)` —— 恰好等于 `gate_axis`。
- **改法**（判据放宽到"响着的轴"或"选中的轴"，并且发的是响着的那个轴）：
```verilog
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && ((axis_i == gate_axis) || (axis_i == selected_axis))) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= gate_axis;    // ⭐ 释放【正在响】的那个轴
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                    end
                end
```
零回归证明：既有 :85-87 的场景里 `axis_i == gate_axis`（都是 6）⇒ `evt_axis_o` 由 `axis_i` 改成 `gate_axis` 得到同一个值 ⇒ 判据不变 ✅。
- **预期**：+0 FF · +约 6 LUT（4 位比较 + 或门 + 4 位 mux 选择）· 风险低。
- **怎么验**：追加
```verilog
        fretboard_mode = 1'b1;
        axis_evt(4'd6, 2'd0, 12'd900);  pluck_evt(1'b1);   // 轴 6 起音
        axis_evt(4'd9, 2'd0, 12'd800);                     // 滑到轴 9（不重拨）
        axis_evt(4'd9, 2'd1, 12'd0);                       // 在轴 9 松开
        repeat (2) @(posedge clk);
        chk("slide-then-release must emit note_off for the SOUNDING axis",
            events_kind[event_n-1] == 2'd1 && events_axis[event_n-1] == 4'd6);
```
预期：改前 `event_n` 不变（无事件）⇒ FAIL；改后收到 `KIND_OFF / axis=6` ⇒ PASS。
- **来源**：ANVIL-07【P0-3】
@@@END
@@@PRIO=P1|SRC=ANVIL-07|ORIG=P1-1|MOD=rtl/w3a/right_analog_ctrl.v,rtl/w3a/fader_gear.v,rtl/top.v
### 把 =1 档 1630 违例的归因从"布局运气"更正为"结构性"
- **位置**：rtl/w3a/right_analog_ctrl.v:98；rtl/w3a/fader_gear.v:258-266；rtl/top.v:1676、:1746、:4155-4156、:1779-1780；sim/evidence/rightboard-vibrato-fix-20261008/README.md:50；impl/gwsynthesis/Gowin2026_syn_rsc.xml；sim/evidence/rightboard-vibrato-fix-20261008/rsc-rightadc-a3.xml
- **现状**：
```verilog
// rtl/top.v:1676   ← ADC_N 只在这里变
        localparam integer ADC_N = (RIGHT_ADC_ENABLE != 0) ? 3 : 2;
// rtl/top.v:1746
            .enable_i         (RIGHT_ADC_ENABLE != 0),
// rtl/w3a/right_analog_ctrl.v:98
        if (!rst_n_i || !enable_i) begin
            master_gain_o   <= 16'h7FFF;
            vibrato_depth_o <= 12'd0;      // ← =0 档：这两个输出被钉成常量 0
            vibrato_rate_o  <= 12'd0;
被更正的对象：README.md:50 原文写 "=0 档时布局运气好（它不在 Top-12）"
```
- **为什么是问题**：`RIGHT_ADC_ENABLE=0` 时 `enable_i` 是常量 0 ⇒ right_analog_ctrl 的两个输出恒为常量 0 ⇒ 沿 `top.v:1779-1780 → fader_gear → top.v:4155-4156 → vibrato_lfo → oscillator_bank` 整条颤音调制数据通路被常量传播折掉。逐模块差分（=0 档 vs =1 档）：`u_adc_farm` 13 FF/1 LUT → 25 FF/25 LUT（**+12 FF / +24 LUT**）；`u_right_analog_ctrl` 不存在(0) → 41 FF/65 LUT；`u_fader_gear` 7 FF/0 ALU/31 LUT → 12 FF/10 ALU/95 LUT；`u_vibrato_lfo` 不存在(0) → 97 FF/96 ALU/286 LUT/**2 DSP**（⭐ 1630 的源头）；`u_oscillator_bank` Alu 4326 → **5350**（**+1024 ALU**，颤音加数进入 32 voice 级加法阵列）；`u_master_mix` 10 FF/43 LUT → 16 FF/28 ALU/73 LUT；TOP 合计 17039 FF/27140 LUT/7 DSP → 17202 FF/27589 LUT/10 DSP（**+163 FF / +449 LUT / +3 DSP**）。⇒ 三条结论：①**=0 档里 u_vibrato_lfo 与 u_right_analog_ctrl 在综合报告里根本不存在** ⇒ 那条 `vibrato_lfo/phase_q_17 → gen_lane[*]` 路径不是"运气好没进 Top-12"，而是**不存在** ⇒ 1630 违例是结构性长路径，⛔ 不是布局噪声；②`ADC_N` 2→3 本身只值 +12 FF / +24 LUT（多一片的 12 位影子寄存器 + 一个上升沿检测扇出），把 1630 归到"多一片 ADC"是错的：真凶是整条右手板控制 + 颤音调制通路从"不存在"变成"存在"；③修法方向已被验证正确（oscillator_bank 颤音链切两级流水 `vibrato_mod_r`/`vib_mul_r`，16+48 FF，把 1630 → 0、46.613 → ≈57.0 MHz），⚠️ 但 +1024 ALU 的加法阵列仍然在（32 voice × 32 位），且 =1 档最差余量只剩 **+0.642 ns** ⇒ 任何再往这条路上加逻辑的改动都危险。
- **改法**：无需改 RTL（流水已落地）。需要改的是归因文档：把 README.md:50 那句改成"=0 档该通路被常量门折掉 ⇒ 不存在；=1 档新增 ⇒ 结构性"。
- **预期**：0 资源。收益 = 防止后续把 =1 档时序问题误判成"重跑布局试试"（那种试法会白烧 ~10 分钟/次的 PnR，而且按 25/25 同源聚类，重跑不可能好）。
- **怎么验**：`diff (Select-String -Path impl\gwsynthesis\Gowin2026_syn_rsc.xml -Pattern 'SubModule') (Select-String -Path sim\evidence\rightboard-vibrato-fix-20261008\rsc-rightadc-a3.xml -Pattern 'SubModule')`；判据：`u_vibrato_lfo` 与 `u_right_analog_ctrl` 只出现在 =1 侧；`u_adc_farm` 两侧都出现且 ΔRegister == **+12**。
- **来源**：ANVIL-07【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-07|ORIG=P1-2|MOD=rtl/drivers/adc_farm.sv
### 删掉 adc_farm 里已死的 miso_shift/cs_r/cs_fall 与那 30 行过时注释
- **位置**：rtl/drivers/adc_farm.sv:135、:152-165、:129-131、:191、:189-193、:137-149、:167-177；impl/gwsynthesis/Gowin2026_syn_rsc.xml；tb/drivers/tb_adc_farm.sv:101-112
- **现状**：
```verilog
// rtl/drivers/adc_farm.sv:129-135
    reg        cs_r;
    always @(posedge clk) cs_r <= adc_cs_n[0];
    wire cs_fall = (cs_r == 1'b1 && adc_cs_n[0] == 1'b0);
    reg [23:0] miso_shift [1:N_ADC-1];
// :153-165 —— 写，但全文件【没有任何一处读】
    always @(posedge clk) begin
        if (!rst_n) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1) miso_shift[gi] <= 24'd0;
        end else if (cs_fall) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1) miso_shift[gi] <= 24'd0;
        end else if (cs_active && sclk_rise) begin
            for (gi = 1; gi < N_ADC; gi = gi + 1) miso_shift[gi] <= {miso_shift[gi][22:0], miso_sync[gi]};
        end
    end
// :189-193 —— 唯一的读口，2026-10-01 已改成 shadow_hold
        for (g = 1; g < N_ADC; g = g + 1) begin : gen_pack
            assign sample_data_packed[g*12 +: 12] = shadow_hold[g][11:0];
        end
```
- **为什么是问题**：`grep miso_shift` ⇒ 命中行只有 135/156/160/163（全是写）与注释，零读。E1（=0 档）`g_sound.u_adc_farm Register="13" Lut="1"`，逐项对：`shadow_hold[1][11:0]` 12 FF ✅留、`shadow_hold[1][23:12]` 12 FF ❌折、`miso_shift[1][23:0]` 24 FF ❌折（无扇出）、`cs_r` 1 FF ❌折（`cs_fall` 只喂已死的 miso_shift）、`sclk_r` 1 FF ✅留（`sclk_rise` 是 shadow_hold 的使能）、`fault_r[1:0]` 2 FF ❌折（恒 0）⇒ 合计 **12 + 1 = 13**，与 E1 精确吻合 ⇒ **综合器已经全部折掉了：资源代价 0、时序代价 0**，所以这条不是资源优化项。它的真实价值是排雷：文件 :137-149 那 30 行注释逐字描述"原缺陷是取 `miso_shift[g][11:0]`、只在 ~1 µs 内有效"，并明说"`shadow_hold` 与 `miso_shift` 逐位相同" —— 一个后来者读到这句，很自然会把 :191 改回 `miso_shift[g][11:0]`（"反正逐位相同、还省 12 个 FF"），于是静默复活那个 1 拍窗口。⚠️ 窗口宽度算准了：第 24 个 SCLK 上升沿 miso_shift 收到第 24 位；该上升沿 → 下降沿 `HALF_DIV` = 25 拍；`STATE_FINISH` 再等 `HALF_DIV` = 25 拍 ⇒ `done`/`sample_valid` 在第 50 拍；下一通道的 `cs_fall` 在第 51 拍 ⇒ **`sample_valid` 恰好落在窗口的最后一拍，余量 = 1 拍 = 20 ns**；同拍读的消费者侥幸正确，晚一拍读就全 0（adc_farm.sv:143-144 的判断成立，只是"1 µs / 0.2% 占空比"的措辞容易让人以为是"很宽的窗口"）。
- **改法**（删死代码，保留修法）：①删 :129-131（cs_r / cs_fall）；②删 :135 的 miso_shift 声明与 :152-165 整段 always；③把 :137-149 的 30 行注释压成 3 行，明确写："shadow_hold 是【唯一】的片 1..N-1 反串行器；它的 [23:12] 无读者（综合器会折掉），但 ⛔ 不要为了省 12 个 FF 把 :191 改回任何会被 cs_fall 清零的副本 —— sample_valid 距下一次 cs_fall 只有 1 拍（20 ns）。"；④同理把 shadow_hold 的声明收窄到实际需要：`reg [11:0] shadow_hold [1:N_ADC-1];` 并同步把移位改成 `{shadow_hold[gh][10:0], miso_sync[gh]}`（行为逐位不变）。
- **预期**：+0 LUT / +0 FF（综合器早已折掉）；收益 = 消除一处可被误用的陷阱 + 让 :167-177 成为唯一的影子实现；代价 = 0（行为逐位不变，tb_adc_farm 应保持 PASS）。
- **怎么验**：①行为不变：`sim/tb_all.ps1` 里 tb_adc_farm 必须仍 PASS（它逐通道比对三片 IDVAL，tb_adc_farm.sv:101-112）；②死逻辑确认：改完再看 impl/gwsynthesis/Gowin2026_syn_rsc.xml，`u_adc_farm` 的 `Register` 必须仍是 13（若从 13 变了，说明对表有误，必须停下来复核）。
- **来源**：ANVIL-07【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-07|ORIG=P1-3|MOD=rtl/drivers/adc_farm.sv,rtl/top.v
### 兑现 adc_farm 的死片检测（现在 fault 恒 0 却汇进心跳灯）
- **位置**：rtl/drivers/adc_farm.sv:216-221；rtl/top.v:1719、:4789、:2219；tb/drivers/tb_adc_farm.sv:168-170
- **现状**：
```verilog
// rtl/drivers/adc_farm.sv:216-221
    // ── 故障（预留 sticky，当前未实现死片检测，保持 0）─────────────────────
    reg [N_ADC-1:0] fault_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
    end
    assign fault = fault_r;
// rtl/top.v:1719
        assign fault_any_w = (|af_fault) | mx_fault;
// rtl/top.v:4789
        else if (fault_any_w)    fault_sticky <= 1'b1;   // ⭐ sticky
```
- **为什么是问题**：`fault_r` 的 always 块只有复位分支、没有 else ⇒ 它被置 0 后永不再赋值 ⇒ `fault ≡ 0`（E1 也印证：`fault_r` 的 2 个 FF 被折掉，`u_adc_farm` 自用只剩 13 FF）。于是 top.v:1719 的 `(|af_fault)` 是常量 0 ⇒ `fault_any_w` 只剩 `mx_fault`（tdm_render_mixer.deadline_fault_o）一条活路 ⇒ 后果：`spi_miso` 被拉死、排线松脱、某片 ADC 未上电 —— 全部不会点亮心跳灯的故障指示；而代码结构（多位 fault 端口 + OR 归并 + sticky 灯）明确暗示"ADC 故障会被抓到"。这跟"已知问题清单"里那条"静默卡死"是同一族。
- **改法**（推荐 (a)：把端口兑现，代价极小）：
```verilog
// (a) 在 adc_farm 里实现"死片"sticky：某片连续 N 帧样本贴死在 0x000/0xFFF ⇒ 置 fault
//     ⚠️ 必须用【帧边界】计数（frame_done），不要用 sample_valid（每通道都来）
    localparam integer DEAD_FRAMES = 64;          // 64 帧 = 32 ms @2 kHz
    reg [N_ADC-1:0] dead_cnt_sat;
    reg [5:0]       dead_run [0:N_ADC-1];
    // 逐片：sample_valid && sample_ch==3'd0 时判 sample_data_packed[i*12+:12] 是否 ∈ {0x000,0xFFF}
    //       是 ⇒ dead_run[i]++（饱和）; 否 ⇒ dead_run[i] <= 0
    //       frame_done 时若 dead_run[i] >= DEAD_FRAMES ⇒ fault_r[i] <= 1'b1（sticky，只置不清）
    always @(posedge clk) begin
        if (!rst_n) fault_r <= {N_ADC{1'b0}};
        else if (frame_done) fault_r <= fault_r | dead_flag;
    end
// (b) 或者：删掉 fault 端口 + 删掉 top.v:1719 的 (|af_fault) 项，并在注释里写明"本版无死片检测"
```
- **预期**：(a) 约 +`N_ADC×6` FF（=1 档 18 FF）+ 约 20 LUT，换来"SPI 挂了能被灯抓到"—— 这正是 top.v:2219 注释里担心的场景（"若 adc_farm 停扫（SPI 挂/排线松）⇒ 采样永不来"）；风险：阈值选错会误报（`0x000/0xFFF` 是真实可达的极端位置 ⇒ 建议 DEAD_FRAMES ≥ 64 帧，且只在 ch0 判，避免正常贴边被误判）。
- **怎么验**：新建/扩展一个 tb（可挂在 tb_adc_farm 上）：把 `adc_miso[1]` 恒接 `1'b0`（模拟片 1 排线断）⇒ 跑 ≥64 帧 ⇒ 断言 `fault[1] == 1'b1`。改前：`fault` 恒 0 ⇒ FAIL（现在 tb_adc_farm.sv:168-170 反而把"`fault==0`"当成通过判据，所以这条判据方向是反的，必须新增反向判据）。
- **来源**：ANVIL-07【P1-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-07|ORIG=P2-1|MOD=rtl/drivers/debounce.sv
### 把 DB_CYC-1 换成显式的 DB_LAST，止住 DB_CYC=0 时去抖器永久冻结
- **位置**：rtl/drivers/debounce.sv:54-55、:76（按键）、:116（编码器）；rtl/top.v:300、:303；tb/drivers/tb_debounce.sv
- **现状**：
```verilog
// rtl/drivers/debounce.sv:54-55
    localparam integer DB_CYC = (CLK_HZ / 1000) * DB_MS;   // 5 ms @50 MHz = 250_000
// :74-81
                if (key_norm[ki] == key_level[ki]) begin
                    key_cnt[ki] <= 32'd0;
                end else if (key_cnt[ki] >= DB_CYC - 1) begin
                    key_level[ki] <= key_norm[ki];
                    key_cnt[ki]   <= 32'd0;
                end else begin
                    key_cnt[ki] <= key_cnt[ki] + 32'd1;
                end
```
- **为什么是问题**：`DB_CYC` 是 integer（32 位有符号）。当 `DB_MS = 0` 或 `CLK_HZ < 1000`（整数除法 `CLK_HZ/1000 == 0`）时：`DB_CYC = 0`、`DB_CYC-1 = -1 ⇒ 32'hFFFFFFFF`（有符号 → 位模式）、`key_cnt` 是 `reg [31:0]`（无符号）。Verilog 规则：只要有一个操作数无符号，比较按无符号做 ⇒ `key_cnt[ki] >= 32'hFFFFFFFF` 只在 `key_cnt == 0xFFFFFFFF` 时为真 ⇒ `key_level` 永不更新、`key_cnt` 停在 0 ⇒ **按键完全死掉，而且没有任何报错/警告**（`enc_cnt` 在 :116 是同一个写法，同样冻结）。交付档目前传 `TIMBRE_BTN_DB_MS = 5` / `PEDAL_DB_MS = 5`（rtl/top.v:300/:303）⇒ 当前不触发；但这是个"参数一改就全静默"的陷阱，且 `CLK_HZ < 1000` 是任何快速单元 tb 都可能踩的（例如想用 10 MHz 以下的时钟做短仿真）。
- **改法**：
```verilog
// rtl/drivers/debounce.sv:54-55 之后插入
    // ⭐ 把"最后一个有效计数值"显式算出来：DB_CYC==0 ⇒ 立刻生效（0 拍去抖），⛔ 不回绕成 -1
    localparam integer DB_LAST = (DB_CYC > 0) ? (DB_CYC - 1) : 0;
```
然后把 :76 与 :116 的 `DB_CYC - 1` 都换成 `DB_LAST`（`DB_CYC==0` 时 `key_cnt >= 0` 恒真 ⇒ 下一拍就跟随输入 ⇒ 语义是"无去抖直通"，比"永久冻结"合理得多）。
- **预期**：0 FF · 0 LUT（常量折叠）· 风险 0。
- **怎么验**：在 tb_debounce 里加一个 `DB_MS=0` 的第二个实例（或临时把 localparam 改 0 跑一次）：`debounce #(.NKEY(1), .CLK_HZ(50_000_000), .DB_MS(0), .ACTIVE_LOW(1)) dut_db0 (...);`，拉低 `key_in[0]` 后几个周期内必须出现 `key_down`。改前：`key_down` 永不出现 ⇒ FAIL；改后：几个周期内出现 ⇒ PASS。
- **来源**：ANVIL-07【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-07|ORIG=P2-2|MOD=rtl/drivers/debounce.sv
### 让 debounce 模块内自保 Z 输入（现在 250000 拍后把 key_level 写成 X）
- **位置**：rtl/drivers/debounce.sv:61-64、:74-78、:92、:105；rtl/top.v:572、:634、:613-614；tb/drivers/tb_debounce.sv:101-102
- **现状**：
```verilog
// rtl/drivers/debounce.sv:61-64
    wire [NKEY-1:0] key_norm;
    integer    ki;
    assign key_norm = ACTIVE_LOW ? ~key_in : key_in;
```
- **为什么是问题**：设 `key_in[i] = 1'bz`、`ACTIVE_LOW=1`：①`~1'bz = 1'bx` ⇒ `key_norm[i] = x`；②:74 的 `if (key_norm[ki] == key_level[ki])` ⇒ `x == 0` 求值为 x ⇒ 在 if 条件里按"假"处理 ⇒ 走 else if；③`key_cnt[ki] >= DB_CYC-1` 在 250 000 拍后为真 ⇒ :77 `key_level[ki] <= key_norm[ki]` = X ⇒ `key_level` 从"确定 0"变成"X"；④`key_down = key_level & ~key_level_d`（:92）⇒ X；下游（例如 rtl/top.v:613-614 的 `timbre_sel_r <= timbre_sel_r + 2'd1`）一旦吃到 X 就永久 X。当前为什么没炸：rtl/top.v:572/:634 在两个例化外面做了 Z-safe 归一（`(x === 1'b0) ? 1'b0 : 1'b1`）⇒ 进 debounce 的已经是确定电平。但这正是问题：模块自身没有防护，而它的文件头（:9-12）只声明"顶层负责 sync_input"，从未声明"顶层还要负责 Z-safe"。任何新调用者（P4 右手板、编码器、辅助按键）只要忘了这一层，就会拿到一个 5 ms 后才变 X 的输入 —— 而 X 在仿真里不会立刻报错。
- **改法**（模块内自保，逐位 Z-safe）：
```verilog
// rtl/drivers/debounce.sv:61-64 替换
    wire [NKEY-1:0] key_norm;
    wire [NKEY-1:0] key_in_z;                 // ⭐ Z/X 一律当"未按下(1)"，与 top.v:572 同口径
    genvar gk;
    generate
        for (gk = 0; gk < NKEY; gk = gk + 1) begin : gen_key_zsafe
            assign key_in_z[gk] = (key_in[gk] === 1'b0) ? 1'b0 : 1'b1;
        end
    endgenerate
    assign key_norm = ACTIVE_LOW ? ~key_in_z : key_in_z;
```
编码器侧同理（`enc_in` 的每一位用 `===` 归一，`enc_sw` 走 ACTIVE_LOW 反转、A/B 保持物理电平 —— ⛔ 别把 A/B 也反过来，那会把正转变反转，见文件 :96-98 的既有纪律）。
- **预期**：`NKEY` 个 LUT（NKEY=1 时 1 个）· 风险 0（`===` 对确定电平与 `==` 完全等价 ⇒ 既有判据不变）。
- **怎么验**：在 tb_debounce 里加一段：
```verilog
        key_in = 4'bzzzz;                       // ⭐ 悬空
        repeat (DB_CYC + 100) @(posedge clk);
        chk(a8_key == 0, "Z input must NOT turn key_level into X");
```
（tb_debounce.sv:101-102 已经有 `chk_xprop` 监视器 `u_a8_key`，直接复用即可。）改前：`a8_key != 0` ⇒ FAIL；改后：保持 0 ⇒ PASS。
- **来源**：ANVIL-07【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-07|ORIG=P2-3|MOD=rtl/drivers/debounce.sv
### 把 EC11 空闲态参数化（现在复位成 000，上电必产生一次非法跳变）
- **位置**：rtl/drivers/debounce.sv:108-111、:147-149、:166-183、:114、:96-98、:24-29；rtl/top.v:597-599；tb/drivers/tb_debounce.sv:192-194、:218
- **现状**：
```verilog
// rtl/drivers/debounce.sv:108-111
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enc_lvl <= 3'b000;                        // ← 🔴 与硬件空闲态不符
            for (ei = 0; ei < 3; ei = ei + 1) enc_cnt[ei] <= 32'd0;
// :147-149
    // ── 正交解码：格雷序列 00 → 01 → 11 → 10 → 00 记为正转（CW）────────────
    // 两位同时变化视为非法跳变，只报 enc_err，不产生计数。
    assign enc_state = {enc_b_lvl, enc_a_lvl};
// :177-181（非法跳变：两位同时变）
                4'b00_11: enc_err <= 1'b1;
                4'b11_00: enc_err <= 1'b1;
```
- **为什么是问题**：硬件事实（.cst + 文件头 :7）：按键/编码器全部上拉输入，EC11 的 A/B 空闲 = `1,1`；而 A/B 不做 ACTIVE_LOW 归一（:96-98 明确纪律：取反会把正转变反转）⇒ `enc_norm[1:0]` 空闲 = `2'b11`。上电后：`enc_lvl = 3'b000`（复位值）≠ `enc_norm = 3'b011` ⇒ :114 不相等 ⇒ `enc_cnt` 开始计数 ⇒ 250 000 拍（5 ms）后 `enc_lvl <= 3'b011` ⇒ `enc_state` 从 00 一步跳到 11 ⇒ `case ({st_d, enc_state})` 命中 `4'b00_11` ⇒ **`enc_err` 拉高一拍**。更严重的后果：解码器的"上一态"起点是错的（真实起点是 11，它以为是从 00 走过来）⇒ 用户上电后的第一个格雷步会被解成 `11→01`/`11→10` 等，方向/步数可能与实际不符。证据（tb 自己承认了）：tb/drivers/tb_debounce.sv:192-194 `// ⭐ 初始 A/B = 00（物理），让正转测试从合法起点开始，避免起始跳变被记为非法`、`enc_a = 1'b0; enc_b = 1'b0;` ⇒ tb 把 A/B 初值设成硬件上不存在的 00 来绕开这个问题（"用激励回避 RTL 缺陷"的典型），:218 还得再走一次 `enc_a=0; enc_b=0; settle;` 才能开始正转测试。当前影响面：.cst 里编码器引脚尚未分配，且 rtl/top.v:597-599 把 `enc_a/enc_b/enc_sw` 全接 `1'b1` ⇒ 交付档不触发（E1 也印证：整个 EC11 半边被折掉，`u_timbre_btn_debounce Register=20` 只等于 `key_cnt(18)+key_level+key_level_d`）⇒ 一旦接上真实编码器就会炸。
- **改法**（把空闲态参数化；⛔ 必须同步改 tb，否则会红 —— 那是正确的契约变更）：
```verilog
// 参数表（:24-29）新增
    parameter [1:0] ENC_IDLE = 2'b11           // ⭐ 硬件上拉空闲态：A=B=1（编码器引脚分配后按实物核对）
// :110 改为
            enc_lvl <= {1'b0, ENC_IDLE};       // [2]=SW 归一后空闲(0)，[1:0]=A/B 物理空闲态
```
并把 tb_debounce.sv:192-195 的初值改成 `enc_a=ENC_IDLE[0]` / `enc_b=ENC_IDLE[1]`（= 1/1），删掉 :218 那次"先走到 00"的额外动作 —— 因为从真实空闲态出发才是正确的正转起点。
- **预期**：0 额外逻辑（只是常量变了）· 代价 = 必须同步改 tb（tb_debounce 的 `enc_err_cnt == 0` 判据会因初值改变而需要重算）。
- **怎么验**：把 `ENC_IDLE` 保持 `2'b11` 但不改 tb，把 tb 的初值改成 `A=B=1` 后直接跑：改前上电后 `enc_err_cnt >= 1` ⇒ "EC11 CW: enc_err == 0" FAIL；改后 0 ⇒ PASS。
- **来源**：ANVIL-07【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-07|ORIG=P2-4|MOD=rtl/drivers/adc_farm.sv
### 给 adc_farm 的 sclk_r/cs_r 补复位分支
- **位置**：rtl/drivers/adc_farm.sv:125-127、:129-131、:169-177；rtl/top.v（rst_n_sync / u_rst_sync）
- **现状**：
```verilog
// rtl/drivers/adc_farm.sv:125-131
    reg        sclk_r;
    always @(posedge clk) sclk_r <= adc_sclk[0];      // ← ⛔ 无 if(!rst_n)
    wire sclk_rise = (sclk_r == 1'b0 && adc_sclk[0] == 1'b1);
    reg        cs_r;
    always @(posedge clk) cs_r <= adc_cs_n[0];        // ← ⛔ 无 if(!rst_n)
    wire cs_fall = (cs_r == 1'b1 && adc_cs_n[0] == 1'b0);
```
- **为什么是问题**：同文件里 `shadow_hold` 的 always（:169-177）有复位分支，而这两个 1 位比较器没有。上电时 `sclk_r = X`，且 `adc_sclk[0]` 在第一个时钟沿之前也是 X（它由 mcp3208_driver 的同步复位寄存器驱动）⇒ 第一拍 `sclk_rise` 可能是 X，从而 `shadow_hold` 的移位使能为 X。为什么现在没炸：:169-177 的 `if (!rst_n)` 分支优先级最高，只要 `rst_n` 在低电平维持 ≥2 拍（top 用的是 `rst_n_sync`，`u_rst_sync` 2 级），X 就进不去。但这是"靠复位宽度兜住"，不是"结构上安全"：任何把 `rst_n` 在 1 拍内释放的用法（单元 tb、仿真激励）都会让 `shadow_hold` 吃到 X ⇒ `sample_data_packed` 变 X。
- **改法**：
```verilog
    always @(posedge clk) begin
        if (!rst_n) begin
            sclk_r <= 1'b0;
            cs_r   <= 1'b1;              // CS 空闲为高（低有效）
        end else begin
            sclk_r <= adc_sclk[0];
            cs_r   <= adc_cs_n[0];
        end
    end
```
- **预期**：+0 LUT（FF 已有，只是补了复位端）· 风险 0。
- **怎么验**：写一个最小 tb：`rst_n` 只低 1 拍（`#20` 后释放），随后断言 `sample_data_packed` 不含 X（复用仓库已有的 `chk_xprop`）。改前：`sclk_r`/`cs_r` 的 X 有机会把 `shadow_hold` 打成 X ⇒ FAIL；改后：PASS。
- **来源**：ANVIL-07【P2-4】
@@@END
@@@PRIO=P2|SRC=ANVIL-07|ORIG=P2-5|MOD=rtl/w3a/play_mode_ctrl.v
### 让同拍的按弦事件先算出来给拨弦用（现在拨弦会用到上一次的 selected_axis）
- **位置**：rtl/w3a/play_mode_ctrl.v:59（拨弦分支优先）、:68（按弦分支）、:71-72；rtl/top.v:3199-3210；rtl/drivers/adc_farm.sv（帧节拍）
- **现状**：
```verilog
// rtl/w3a/play_mode_ctrl.v:59-72
            end else if (pluck_valid_i && selected_valid) begin
                evt_axis_o  <= selected_axis;      // ← 用的是【旧】的选择
                ...
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;      // ← 同拍到达时，这一句根本执行不到
                    selected_depth <= axis_depth_i;
                end
```
- **为什么是问题**：`pluck_valid_i` 来自板外异步比较器（async_pluck_capture，rtl/top.v:3199-3210，任意相位），`axis_valid_i`（`ee_valid`）来自 500 µs 帧节拍（adc_farm → event_extract）。两者落在同一 clk 拍的概率 ≈ `1 / 25000` 每次事件（帧周期 25000 拍）。按每秒 5 次轴事件估算 ⇒ 约 **1 次 / 83 分钟**连续演奏。撞上时：:59 分支优先 ⇒ 按弦的 `selected_*` 不更新 ⇒ 拨弦发出的是上一个音符的轴/力度 ⇒ 听感是"按了 A 键、响的是 B 音"。
- **改法**（把同拍按弦"提前算出来"给拨弦用；⛔ 不要简单地把两个分支换序 —— 那会让"拨弦优先"的既有契约反过来）：
```verilog
// 在 always 之前算"本拍若发生 ON，选中值会变成什么"
    wire              on_now    = axis_valid_i && (axis_kind_i == KIND_ON);
    wire [AXIS_W-1:0] sel_ax_n  = on_now ? axis_i       : selected_axis;
    wire [DEPTH_W-1:0] sel_dp_n = on_now ? axis_depth_i : selected_depth;
    wire              sel_vd_n  = on_now ? 1'b1         : selected_valid;
// :59 分支改用（注意用 sel_vd_n 而不是 selected_valid）
            end else if (pluck_valid_i && sel_vd_n) begin
                evt_axis_o  <= sel_ax_n;
                evt_depth_o <= sel_dp_n;
                gate_axis   <= sel_ax_n;
```
- **预期**：+约 12 LUT（4+12 位 mux 各一级）· 风险低（既有判据不变：:59 在 `on_now=0` 时 `sel_*_n` 与 `selected_*` 逐位相同）。
- **怎么验**：追加同拍激励
```verilog
        fretboard_mode = 1'b1;
        axis_evt(4'd4, 2'd0, 12'd500); repeat (2) @(posedge clk);   // 先选中 4
        // ⭐ 同拍：新轴 ON + 拨弦
        @(negedge clk); axis=4'd11; axis_kind=2'd0; axis_depth=12'd800; axis_valid=1'b1;
                        pluck_up=1'b1; pluck_valid=1'b1;
        @(negedge clk); axis_valid=1'b0; pluck_valid=1'b0;
        repeat (2) @(posedge clk);
        chk("same-cycle press+pluck must play the NEW axis", events_axis[event_n-1] == 4'd11);
```
改前：播的是轴 4 ⇒ FAIL；改后：轴 11 ⇒ PASS。
- **来源**：ANVIL-07【P2-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-07|ORIG=P2-6|MOD=rtl/drivers/mcp3208_scanner.sv
### 给 mcp3208_scanner 的帧周期饱和加一个 sticky overrun 观测位
- **位置**：rtl/drivers/mcp3208_scanner.sv:115-121（饱和）、:139-149（判据）、:17-18（端口）；rtl/mcp3208_driver.sv:25-29；rtl/top.v:3135；tb/drivers/tb_mcp3208_scanner.sv:269-277；tb/drivers/tb_adc_farm.sv:156-159
- **现状**：
```verilog
// rtl/mcp3208_scanner.sv:115-121
                    STATE_WAIT_DRIVER: begin
                        // Measure the frame period from the CH0 start event.
                        // Saturation makes an overrun start the next frame as
                        // soon as the current frame finishes.
                        if (frame_counter < FRAME_PERIOD - 1) begin
                            frame_counter <= frame_counter + 1'b1;
                        end
// :139-149
                    STATE_WAIT_PERIOD: begin
                        if (frame_counter >= FRAME_PERIOD - 1) begin
                            frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};
                            driver_channel <= 3'd0;
                            driver_start   <= 1'b1;
                            state          <= STATE_WAIT_DRIVER;
```
- **为什么是问题**：`FRAME_PERIOD = 50_000_000 / 2000 = 25000` 拍 = 500 µs。8 笔转换 = 8 × 24.5 µs = **196 µs = 9800 拍**（`SCLK_HZ=1 MHz` ⇒ `HALF_DIV=25`，见 mcp3208_driver.sv:25-29）⇒ 正常路径下 `frame_counter` 在 `WAIT_DRIVER` 段只走到 ~9800，不饱和；余下 ~15200 拍在 `WAIT_PERIOD` 空等 ⇒ 帧周期精确 25000 拍（tb_mcp3208_scanner.sv:269-277 与 tb_adc_farm.sv:156-159 都断言 500000 ns，且 PASS）。但若将来把 `SCLK_HZ` 调低（或加片导致单帧转换时间变长）使 8 笔 > 500 µs，则 `frame_counter` 在 `WAIT_DRIVER` 段饱和在 24999，`WAIT_PERIOD` 立刻满足条件 ⇒ 下一帧马上开始 ⇒ 实际通道速率 = 1/转换时间 > 2000 Hz，而 `CHANNEL_RATE_HZ` 这个参数名义上仍写着 2000。下游 rtl/top.v:3135 注释明确说"改采样率会连带影响 VOTE_N/STABLE_NEED/debounce 等" ⇒ 一旦静默超标，这些时间窗全部按错误时基工作，且没有任何信号能告诉你发生了饱和。
- **改法**（加一个 sticky overrun 观测位，成本 1 FF；不改既有节拍）：
```verilog
// 端口（:17-18 附近）新增
    output reg        period_overrun,          // ⭐ sticky：本帧发生过饱和（采样率已被迫提高）
// :119-121 改为
                        if (frame_counter < FRAME_PERIOD - 1) begin
                            frame_counter <= frame_counter + 1'b1;
                        end else begin
                            period_overrun <= 1'b1;   // ⭐ 饱和 ⇒ 记一笔（只置不清，复位清）
                        end
// 复位段补：period_overrun <= 1'b0;
```
（top.v 可把它并进已有的 `fault_any_w`，这样"SPI 慢到改变采样率"就会亮心跳灯。）
- **预期**：+1 FF / +1 LUT；收益 = 把"静默的时基漂移"变成"可观测的 sticky 故障"；风险：top.v 需加一根接线（adc_farm 要把它透传出来）。
- **怎么验**：把 tb_mcp3208_scanner 的 `SCLK_HZ` 改成 `200_000`（8 笔 = 8 × 122.5 µs = 980 µs > 500 µs）⇒ 断言 `period_overrun == 1'b1`。改前：无此信号（或恒 0）⇒ FAIL；改后：1 ⇒ PASS。
- **来源**：ANVIL-07【P2-6】
@@@END
@@@PRIO=P3|SRC=ANVIL-07|ORIG=P3-1|MOD=rtl/drivers/mcp3208_driver.sv
### 把 rx_shift 从 24 位收窄到 12 位
- **位置**：rtl/drivers/mcp3208_driver.sv:38（声明）、:114（移位）、:156（唯一读口）；tb/drivers/tb_mcp3208_driver.sv:136-144
- **现状**：
```verilog
// rtl/drivers/mcp3208_driver.sv:38
    reg [23:0] rx_shift;
// :114
                        rx_shift <= {rx_shift[22:0], adc_miso};
// :155-156
                    //24位接收帧的最低12位就是ADC的采样结果
                    adc_data <= rx_shift[11:0];
```
- **为什么是问题**：E1：`u_scan0 → driver_inst Register="50" Lut="54"`，逐项对 `div_counter(5) + bit_counter(5) + rx_shift(24) + state(2) + adc_data(12) + busy(1) + done(1) = 50` ✅ 精确 ⇒ `tx_shift`(24) 与 `channel_latched`(3) 已经被综合器折掉（tx_shift 由常量装载、只做确定性移位 ⇒ 被替换成 `adc_mosi = f(bit_counter, channel)` 的译码），而 `rx_shift` 仍是 24 位。因为 `rx_shift[23:12]` 的扇出只是它自己的 `[22:0]`（:114），不是死逻辑，所以工具不会删它；但它们在语义上无用 —— 12 次移位就足以把最后 12 位推进 `[11:0]`。
- **改法**：
```verilog
    reg [11:0] rx_shift;                                  // :38
    rx_shift <= {rx_shift[10:0], adc_miso};               // :114
    adc_data <= rx_shift[11:0];                           // :156（不变）
```
- **预期**：**−12 FF**（若工具不折则 −12 LUT 的移位逻辑）· 风险 0（逐位等价：第 13..24 个上升沿把 B11..B0 推进 12 位移位器，第 24 拍时 `[11:0] == 原 24 位版的 [11:0]`）。
- **怎么验**：①等价：tb_mcp3208_driver 必须仍全 PASS（:136-144 逐通道比对 `adc_data == test_value`，8 个通道全查 —— 这条 tb 足够强，是本条的安全网）；②资源：改完看 E1，`driver_inst` 的 `Register` 必须从 **50 → 38**。
- **来源**：ANVIL-07【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-07|ORIG=P3-2|MOD=rtl/drivers/mcp3208_driver.sv
### 让第 1 个 MOSI 位显式来自 tx_shift（现在靠 5 个前导零兜住）
- **位置**：rtl/drivers/mcp3208_driver.sv:79（IDLE 置 0）、:88-95（装载）、:138-139（后续位）、:56（复位）；tb/drivers/tb_mcp3208_driver.sv:126-134
- **现状**：
```verilog
// rtl/drivers/mcp3208_driver.sv:76-101
                STATE_IDLE: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;                 // ← 第 1 位就是它
                    ...
                    if(start) begin
                        ...
                        tx_shift <= {
                            5'b00000,             // ← tx_shift[23:19]
                            1'b1,                 // ← tx_shift[18]  START
                            1'b1,                 // ← tx_shift[17]  SGL/DIFF
                            channel[2],           // ← tx_shift[16]
                            channel[1:0],         // ← tx_shift[15:14]
                            14'd0                 // ← tx_shift[13:0]（含 MSBF/NULL）
                        };
// :138-139
                            adc_mosi <= tx_shift[22];
                            tx_shift <= {tx_shift[22:0], 1'b0};
```
- **为什么是问题**：`adc_mosi` 只在 `STATE_SCLK_HIGH`（下降沿）更新为 `tx_shift[22]`。而第 1 个 SCLK 上升沿发生在 `STATE_SCLK_LOW` 首次计满之后 —— 此时 `adc_mosi` 还是 IDLE 里写的 `1'b0`。推演：上升沿 #1 从机采到 `1'b0`（**IDLE 常量，不是 tx_shift[23]**）、#2 采到 `tx_shift(0)[22]`、#3 `tx_shift(0)[21]`… #24 `tx_shift(0)[0]` ⇒ 帧的第 1 位恰好等于 `tx_shift[23]`，因为 `tx_shift[23]` 被硬写成 0 ⇒ 换任何一个非零前导（例如给别的 SPI 器件改成 `5'b00001`）都会静默错 1 位。唯一的安全网是 tb_mcp3208_driver.sv:126-134 的整帧比对（`captured_mosi !== 24'h06xxxx`）—— 它确实能抓到（因为 `captured_mosi` 会把第 1 位也收进去）⇒ 所以这是可读性/隐式耦合问题，不是隐藏 bug。
- **改法**（让第 1 位显式来自 tx_shift，或至少写死注释）：
```verilog
// 方案 A（最小、零回归）：在 :99 处把 IDLE 的常量写成"与 tx_shift[23] 同源"
                    adc_mosi <= 1'b0;   // ⭐ == tx_shift[23]（前导 5 位恒 0）—— ⛔ 改前导域必须同步改这里
// 方案 B（结构正确）：让 IDLE 也用 tx_shift 的 MSB
                    adc_mosi <= tx_shift[23];   // 复位时 tx_shift=0 ⇒ 上电仍为 0
```
- **预期**：0 FF / 0 LUT · 风险 0（方案 B 需确认复位时 `tx_shift=0`，:56 已复位为 0 ✅）。
- **怎么验**：把 `tx_shift` 的 `5'b00000` 改成 `5'b00001`（一个假想的改动），期望 tb_mcp3208_driver 报 `FAIL CH0: MOSI=860000, expected=060000`：若 tb 报 FAIL ⇒ 安全网有效（当前情况，符合推演）；若 tb 不报 ⇒ 说明有没算到的路径，必须回头复核。（这条判据的价值在于：它同时验证了 tb 的 MOSI 整帧比对是真判据。）
- **来源**：ANVIL-07【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-07|ORIG=P3-3|MOD=rtl/w3a/play_mode_ctrl.v
### 删掉 play_mode_ctrl 里从不读的 pluck_up_i 死端口
- **位置**：rtl/w3a/play_mode_ctrl.v:19-20、:59-67、:61-62；rtl/top.v:3224；impl/gwsynthesis/Gowin2026_syn_rsc.xml（u_play_mode_ctrl 17 FF / 17 LUT）
- **现状**：
```verilog
// rtl/w3a/play_mode_ctrl.v:19-20
    input  wire                   pluck_valid_i,
    input  wire                   pluck_up_i,       // direction retained at capture seam
```
- **为什么是问题**：`grep pluck_up_i rtl/w3a/play_mode_ctrl.v` ⇒ 只命中第 20 行（端口声明）。拨弦分支（:59-67）对两个方向一视同仁（:61-62 注释也承认："Direction has already been resolved by async_pluck_capture (UP priority)"）⇒ 方向信息在这一层被有意丢弃，但端口留着，rtl/top.v:3224 还认真地把 `pluck_up` 接了进来 ⇒ 一个后来者读到这里会以为"方向会影响事件"，从而在错误的前提下改代码。综合代价 0（未使用的输入不产生逻辑）。
- **改法**（二选一）：(a) 删端口：删 :20，并删 rtl/top.v:3224 的 `.pluck_up_i (pluck_up)`；`pluck_up` 在 top 里若还有其他消费者则保留。(b) 兑现语义：把方向带进事件（例如 `evt_depth_o` 的高位或 `evt_kind_o` 扩 1 位），但这会改变下游契约（evt_merge / note_manager），不建议在本摊做。
- **预期**：0 资源；收益 = 消除一处"看起来有语义、实际没有"的接口；风险 0。
- **怎么验**：本条**无法用 tb 变红**（删掉未使用端口不改变任何可观测行为）—— ⚠️ 明确标注它不可红，验证方式只有一条：`grep` 证明零读 + 综合后 `u_play_mode_ctrl` 的 `Register`/`Lut` 不变（E1 的 17 FF / 17 LUT 必须保持）。
- **来源**：ANVIL-07【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-07|ORIG=P3-4|MOD=rtl/drivers/mcp3208_driver.sv
### 给 mcp3208_driver 的不可达 default 分支补清 div_counter/bit_counter
- **位置**：rtl/drivers/mcp3208_driver.sv:42-47（状态编码）、:171-178（default）、:82-83；impl/gwsynthesis/Gowin2026_syn_rsc.xml（driver_inst Lut=54）
- **现状**：
```verilog
// rtl/drivers/mcp3208_driver.sv:42-47
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_SCLK_LOW = 2'd1;
    localparam [1:0] STATE_SCLK_HIGH = 2'd2;
    localparam [1:0] STATE_FINISH = 2'd3;
    reg [1:0] state;
// :171-178
                default: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;
                    busy     <= 1'b0;
                    state    <= STATE_IDLE;
                end
```
- **为什么是问题**：`state` 是 2 位，`2'd0..2'd3` 四个值全部被 case 显式列出 ⇒ `default` 在 RTL 语义上不可达（工具应能证明并折掉；E1 的 `driver_inst Lut=54` 与之相容，但无法单独归因）⇒ 这是防御性写法，本身不是缺陷。唯一实质问题：`default` 里没有 `div_counter <= 0; bit_counter <= 5'd0;`，而其它分支进 IDLE 时都会清（:82-83）⇒ 若将来把状态编码扩到 3 位并新增状态，从 `default` 回 IDLE 会带着陈旧的 `div_counter`/`bit_counter` 重新开始（表现为"第一次转换的 SCLK 周期偏短/位偏移"）。
- **改法**：
```verilog
                default: begin
                    adc_cs_n     <= 1'b1;
                    adc_sclk     <= 1'b0;
                    adc_mosi     <= 1'b0;
                    busy         <= 1'b0;
                    div_counter  <= {DIV_WIDTH{1'b0}};   // ⭐ 补
                    bit_counter  <= 5'd0;                // ⭐ 补
                    state        <= STATE_IDLE;
                end
```
- **预期**：0（不可达分支；补上后若工具仍能证明不可达则仍折掉）· 风险 0。
- **怎么验**：当前不可红（不可达分支）。验证方式：改完确认 E1 的 `driver_inst` 资源不变（若变了说明工具其实没折掉，那这条就从 P3 升级为 P2 —— 这本身就是一次有价值的核查）。
- **来源**：ANVIL-07【P3-4】
@@@END
@@@TOTAL SRC=ANVIL-07 COUNT=16 P0=3 P1=3 P2=6 P3=4
