@@@PRIO=P0|SRC=ANVIL-10|ORIG=P0-1|MOD=rtl/w3c/evt_uart_rx.v,rtl/top.v
### 给曲谱事件接收加"别人帧内"门控，堵住屏数据里的 0xA5 被当帧头
- **位置**：rtl/w3c/evt_uart_rx.v:131、:175-181；rtl/top.v:1011-1028、:4911；tb/w3c/tb_evt_uart_rx_screen.sv:159-168、:162；files/20-代码/审计-top集成与时钟复位-20260928.md:239
- **现状**：
```verilog
// rtl/w3c/evt_uart_rx.v:131
wire [63:0] evt_word = {shift_q[55:0], rx_data_i};
// rtl/w3c/evt_uart_rx.v:175-181
            if (idx_q == 4'd0) begin
                // ---- ⭐ 只在【第 0 字节位置】看帧头（⛔ 不扫描）----------
                if (byte_is_a5) begin
                    idx_q    <= 4'd1;
                    all_a5_q <= 1'b1;      // ⭐ 帧头是 0xA5 ⇒ 起始为真
                    shift_q  <= 64'd0;
// rtl/top.v:1011-1028（u_evt_uart_rx 与 u_uart_ui / u_calib_cmd 接同一个 ur_done/ur_data）
// rtl/top.v:4911：assign esp_uart_tx_o = 1'b1;  ⇒ 方案 A 的"独立曲谱 UART"根本没接
```
- **为什么是问题**：uart_rx 的字节流被三个消费者同时读：evt_uart_rx（认 0xA5）、uart_ui（认 0x65/0x70/0x71/0x88）、calib_cmd（认裸字母）。evt_uart_rx 只在自己的 `idx_q == 0` 位置看 0xA5 —— 这是对的。但"它自己的 idx_q == 0"与"屏帧的边界"完全无关：0x71 数值帧的载荷是多字节小端数值（审计-top集成与时钟复位-20260928.md:239 明写"4 字节小端数值 ⇒ 数值 165 = 0x000000A5 就含 0xA5"）。只要那个 0xA5 恰好落在 `idx_q==0`，后面又跟着 ≥8 个字节（屏背靠背连发两帧时必然满足，因为字节间隙 < GAP_BYTES=16 字节时间，不会触发归位），就会拼出一个完全合法的 64 bit 事件。实测证据（本轮亲跑 tb_evt_uart_rx_screen）：TWO screen frames BACK-TO-BACK ⇒ `n_evt=1 frame_cnt=1 hdr_err=8 resync=0`；long continuous screen stream（8 frames）⇒ `n_evt=8 frame_cnt=8 hdr_err=10 resync=1`；`total evt_valid pulses (spurious events) = 8`；`🔴 CONFIRMED: screen data WAS parsed as a score event!`；`last evt_data = 0xa500ffffffff7107` ⇒ decoded axis = 15（14/15 = reserved, keyboard can NEVER clear it）、decoded inc = 0x1fffff、decoded kind = 0（on）；汇总 `通过 1 / 共 1`。两个后果叠加：①**8 次幻影 note_on**，解码出的 `axis = 15` —— tb_evt_uart_rx_screen.sv:162 自己注明"14/15 = reserved, keyboard can NEVER clear it" ⇒ 这个音一旦起来就永远关不掉；②**回归判它 PASS**（通过 1 / 共 1），tb 只 `$display` 诊断结论、没有任何 `chk()`/`errors++` ⇒ C83（探针假绿）同族：缺陷被完整复现、被完整打印、然后被判通过。
- **改法**（按代价从低到高）：1. 立刻（1 行，纯验证，不改 RTL）：把 tb/w3c/tb_evt_uart_rx_screen.sv:159 的 `if (n_evt > 0) begin $display("   🔴 CONFIRMED: ...");` 改成同时累加失败计数（`errors = errors + 1;`）并在结尾 `$display("FAIL: ...")` ⇒ 现有代码立刻变红，缺陷进入回归视野。2. 真修（最小改动，不动协议）：让 uart_ui / calib_cmd 各输出一个 `in_frame_o`（它们内部已经有 `state`/`body_len`/`idx_q`，只是没引出来），在 top.v 里给 `evt_uart_rx.rx_done_i` 加门控：`wire evt_rx_done = ur_done & ~ui_in_frame & ~cmd_in_frame;`；代价 = uart_ui 多 1 个输出端口（组合，浅）。注意：uart_ui 自己的帧在 0xA5 到达时并不知道那是别人帧的载荷，所以这个门控只能挡住"屏帧内部"的字节；0xA5 出现在 uart_ui 帧体里时 `ui_in_frame=1` ⇒ 正好挡住。3. 根治（已定方案 A）：把曲谱挪到独立 UART（`esp_uart_tx_o` 现在是恒 1'b1 的死线，rtl/top.v:4911）；代价 = 要 ESP32 侧配合 + 一次引脚/PnR。
- **预期**：收益 = 消掉一条会响的错误音（且是关不掉的那种）+ 消掉 8/9 字节吞吐被误吞的隐患；代价 = 方案 2 是 1 个端口 + 2 条 and，方案 3 要动板级。
- **怎么验**：`sim\tb_all.ps1 -Filter evt_uart_rx_screen` —— 当前打印 `🔴 CONFIRMED` 却是 `通过 1 / 共 1`；按第 1 步改 tb 后必须变成 `FAIL`；按第 2/3 步改 RTL 后必须回到 `通过` 且 `n_evt=0`。
- **来源**：ANVIL-10【P0-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-10|ORIG=P1-1|MOD=rtl/w3c/pos_probe.v
### 把 pos_probe 的三处常数乘法换成常量 case 查表，去掉 6 个 MULT12X12
- **位置**：rtl/w3c/pos_probe.v:175-179、:257、:270；impl/gwsynthesis/Gowin2026.vg:39855/:39876/:39897；impl/pnr/Gowin2026.rpt.txt:63-66
- **现状**：
```verilog
    // ⭐ 当前该减多少（⭐ 常数移位加法，⛔ 不用乘法器 ⇒ 时序好）
    //   ⭐ `cur_digit × 100` = `(cur_digit×64) + (cur_digit×32) + (cur_digit×4)`
    //      ⇒ ⚠️ 但为了**可读性**和**资源**，⭐ 直接用 12 位常数乘法 ——
    //         ⚠️ Gowin 会用 LUT 拼，⭐ 而它【在寄存器之间】⇒ 不叠在前级比较器上
    wire [11:0] cur_x100 = {8'd0, cur_digit} * 12'd100;
    rem  <= rem - ({8'd0, cur_thou} * 12'd1000);   // :257
    rem  <= rem - ({8'd0, cur_ten}  * 12'd10);     // :270
```
- **为什么是问题**：`*` 触发 Gowin 的 DSP 推断，三处各自绑死一个硬核乘法器，且 **AREG/BREG/OREG 全部 BYPASS**（纯组合）：`MULT12X12 cur_x100_0_s` 的 `.A(...cur_digit[2:0])`（只有 4 位有效）、`.B(...)` = `0b000001100100` = 100；`MULT12X12 n270_s` .B = 10；`MULT12X12 n212_s` .B = 1000。`pos_probe` 有两个活实例（`u_pos_probe` / `u_pos_probe_cal`，`u_pos_probe_dpos` 因 `DPOS_DIAG=0` 被扫掉）⇒ 3 × 2 = **6 个 MULT12X12**；与 PnR 报告完全对上：`DSP 22/118`，其中 `--MULT12X12 6`。代价是真实的：12×12 硬核只用了 A 端的 4 位，却在固定列位置的 DSP 上占位并引入进出 DSP 的长布线；而本项目 PnR 是布局噪声主导（同源重跑差 2~3 MHz）。另外 `cur_x100` 的位宽是 `[11:0]`（注释写 `12'd100`）⇒ 三处都做了 12 位运算，而实际值域是 `cur_digit ≤ 9 ⇒ ≤ 900`（10 位）、`cur_ten ≤ 90`（7 位）、`cur_thou ≤ 4 ⇒ ≤ 4000`（12 位）。
- **改法**：把三处 `*` 换成常量 case 查表（综合器无法把它变成 DSP）：
```verilog
    reg [11:0] cur_x100;                     // cur_digit 只有 0~9 ⇒ 查表比乘法器更小更快
    always @(*) begin
        case (cur_digit)
            4'd0: cur_x100 = 12'd0;    4'd1: cur_x100 = 12'd100;  4'd2: cur_x100 = 12'd200;
            4'd3: cur_x100 = 12'd300;  4'd4: cur_x100 = 12'd400;  4'd5: cur_x100 = 12'd500;
            4'd6: cur_x100 = 12'd600;  4'd7: cur_x100 = 12'd700;  4'd8: cur_x100 = 12'd800;
            default: cur_x100 = 12'd900;
        endcase
    end
    reg [11:0] cur_x1000;                    // cur_thou ∈ 0..4
    always @(*) begin
        case (cur_thou)
            4'd0: cur_x1000 = 12'd0;    4'd1: cur_x1000 = 12'd1000;
            4'd2: cur_x1000 = 12'd2000; 4'd3: cur_x1000 = 12'd3000;
            default: cur_x1000 = 12'd4000;
        endcase
    end
    reg [7:0] cur_x10;                       // cur_ten ∈ 0..9
    always @(*) begin
        case (cur_ten)
            4'd0: cur_x10 = 8'd0;   4'd1: cur_x10 = 8'd10;  4'd2: cur_x10 = 8'd20;
            4'd3: cur_x10 = 8'd30;  4'd4: cur_x10 = 8'd40;  4'd5: cur_x10 = 8'd50;
            4'd6: cur_x10 = 8'd60;  4'd7: cur_x10 = 8'd70;  4'd8: cur_x10 = 8'd80;
            default: cur_x10 = 8'd90;
        endcase
    end
```
然后 :257 → `rem <= rem - cur_x1000;`、:270 → `rem <= rem - {{4{1'b0}}, cur_x10};`。
- **预期**：`DSP` 22 → **16**（MULT12X12 6 → 0），pos_probe 的两个实例各去掉 3 个硬核及其进出布线；代价 = 约 3 个 10~12 位 4:1/10:1 mux（≈ 30~40 LUT）。⚠️ 这不是当前时序瓶颈（pos_probe 不在最差 25 条榜上，余量 ≥0.85 ns），所以别指望 Fmax 大涨 —— 价值在资源 + 消掉一条固定位置的长布线 + 让注释不再骗人。
- **怎么验**：①改之前 `Select-String -Path impl/gwsynthesis/Gowin2026.vg -Pattern '^\s*MULT12X12\s+\S+'` 应有 6 条；②改之后重跑综合应为 0 条，且 PnR 报告的 DSP 行从 22 变 16；③功能必须逐值回归 0..4095（`-Filter pos_probe`）。
- **来源**：ANVIL-10【P1-1】
@@@END
@@@PRIO=P1|SRC=ANVIL-10|ORIG=P1-2|MOD=rtl/top.v,rtl/w3c/pos_probe.v
### 把 'P' 回包的通道号从 3 位改成 4 位直传（轴 7 与轴 15 现在回包逐字节相同）
- **位置**：rtl/top.v:2123、:2130、:2109-2112；rtl/w3c/pos_probe.v:94-97、:192-193；tb/w3c/tb_pos_probe_axis.sv
- **现状**：
```verilog
// rtl/top.v:2123 / :2130
      wire [11:0] pp_raw_sel = pp_axis_r[3] ? af1_pol : af0_pol;      // :2123  用 bit3 选片
          .ch_i       ({1'b0, pp_axis_r[2:0]}), // ⭐ 与 pp_raw_sel 同源 ✅   // :2130  ← 🔴 丢掉 bit3
// rtl/w3c/pos_probe.v:94-97（端口是 4 位，注释明说 3 位不够）
    //   ⭐⭐ 2026-09-27：⭐ **扩到 4 位** —— `'N'` 用它回传【轴号 0~15】，
    //      ⚠️ 3 位装不下 16 个轴（⭐ 轴 8~15 会与 0~7 混淆 ⇒ 分不清是谁）。
    input  wire [3:0]  ch_i,
// rtl/w3c/pos_probe.v:192-193（ch_lat 是 4 位、能印 0~F，能力是够的）
            4'd1:    tx_byte_c = (ch_lat < 4'd10) ? (8'h30 + {4'd0, ch_lat})
                                                  : (8'h41 + ({4'd0, ch_lat} - 8'd10));
```
- **为什么是问题**：`ch_i = {1'b0, pp_axis_r[2:0]}` ⇒ 打印值 = `axis mod 8`。片 0（af0_pol，轴 0~7）与片 1（af1_pol，轴 8~15）共用同一串通道号 0~7。`pp_raw_sel` 用 `pp_axis_r[3]` 选片，所以位置值来自正确的片；但通道号丢掉了片信息。top.v:2109-2112 的原始缺陷描述是"🔴 'P' 永远只报片 0 ⇒ 诊断板 2 时会给出错误答案（比看不到更危险）"；修法（BATCH 8.1）加了轮转 + 选片，但没有修"回包分不清是哪一片" ⇒ 现在变成了另一种"给出错误答案"：片 1 的读数会被读成片 0 的某个轴。实测证据（本轮亲跑）：`ok : c req 7 pos comes from chip 0  req  7: axis= 7 chip=0 expect pos= 256 -> got P7256`；`ok : c req 15 pos comes from chip 1  req 15: axis=15 chip=1 expect pos=2048 -> got P72048` ⇒ 两个不同轴的 `ch` 字段都是 `'7'`。该 tb 之所以"过"，只是因为作者把两片的码设成了不同值（256 vs 2048）；只要两片读到同一个码，`axis=7` 与 `axis=15` 的回包就完全相同。
- **改法**（1 处，最小）：`.ch_i (pp_axis_r),`（4 位直传：bit3 = 片号，bit2:0 = 片内通道）；pos_probe.tx_byte_c 已经是十六进制一位（0~F），不需要改 pos_probe。若必须保持"'P' 的 ch 是片内 0~7"这个已写进 pos_probe.v:96 的语义，那就把片号并进数值字段或另加一字节，但不能什么都不做。
- **预期**：收益 = 'P' 变成真正可判读的诊断（P + 片/轴 + 4 位十进制）；代价 = **0**（一根线宽 3→4 位）。
- **怎么验**：在 tb/w3c/tb_pos_probe_axis.sv 里把 `af1_pol` 设成与 `af0_pol` 相同（都 256），断言"轴 7 与轴 15 的回包不同" ⇒ 当前实现下二者回包逐字节相同 ⇒ 红；改 `.ch_i(pp_axis_r)` 后 ⇒ 绿。
- **来源**：ANVIL-10【P1-2】
@@@END
@@@PRIO=P1|SRC=ANVIL-10|ORIG=P1-3|MOD=rtl/w3c/pos_probe.v,rtl/w3c/span_probe.v,rtl/top.v
### 给探针请求加锁存补发与丢弃计数，并让轴轮转只在受理时 +1
- **位置**：rtl/w3c/pos_probe.v:227-246；rtl/w3c/span_probe.v:148-157；rtl/top.v:2118-2122、:2876-2880、:2113；rtl/w3c/uart_tx_fifo.v:129、:30-33；rtl/w3c/uart_ui.v:154-159；tb/w3c/tb_pos_probe_axis.sv
- **现状**：
```verilog
// rtl/w3c/pos_probe.v:227-246
                // 🔴🔴 **必须同时满足 `idle_i`**（⭐ 2026-09-24 上板修）
                //   ✅ 修法：⭐ **等 `idle_i`（队列空 且 发送器停）才开新包**
                if (probe_req_i && idle_i) begin
                    pos_lat   <= pos_i;
// rtl/top.v:2118-2122 与 :2876-2880（**无条件**自增，与探针是否受理无关）
      reg  [3:0] pp_axis_r;
      always @(posedge clk) begin
          if (!rst_n_sync)         pp_axis_r <= 4'd0;
          else if (cmd_probe_req)  pp_axis_r <= pp_axis_r + 4'd1;
      end
```
- **为什么是问题**：`idle_i = empty & (~sending) & (~busy_i)`（uart_tx_fifo.v:129）。一个 8 字节包（N_BYTES=8）在 S_SEND 里连续 8 拍推完（`ready_i = ~full`，cnt 从 0 一路到 8），FIFO 随即进入排空：500 kbaud ⇒ 1 字节 = 10 bit × 100 clk × 20 ns = **20 µs** ⇒ 排空 **8 × 20 µs = 160 µs**。这 160 µs 里 `empty = 0` ⇒ `idle_i` 恒 0。而 500 kbaud 下背靠背两个命令字节只隔 20 µs（= 1 个字节时间）：t=0 'P' 字节 rx_done → 探针受理 → 8 拍内灌满 FIFO；t=+20µs 'P' 字节 rx_done → cmd_probe_req 脉冲 → `idle_i==0` ⇒ 🔴 请求被丢，什么都不发生；t=+160µs FIFO 排空 → idle_i 恢复 ⇒ **`'P''P'`（或脚本连发）必然丢第二个**，而 `pp_axis_r` 已经 +1 ⇒ 之后每一次上报的"轴号"都比实际扫过的轴多算一个，"连发 16 次覆盖 16 轴"的契约不成立。同时它违反模块自己的纪律：pos_probe.v 没有任何 `req_drop_cnt`；span_probe.v 同样没有。对照 uart_tx_fifo.v:30-33 的原话"🔴 溢出必须可观测（K-106：能失败的路径必须留下痕迹）……如果只是'悄悄丢'，那和改之前没区别" —— 这里正是"悄悄丢"。
- **改法**（推荐组合 ①+③）：
```verilog
    // ① 请求锁存：丢掉就补发，不再"丢一次少一个轴"
    reg pending_r;
    always @(posedge clk_i) begin
        if (!rst_n_i)                     pending_r <= 1'b0;
        else if (probe_req_i && ~idle_i)  pending_r <= 1'b1;          // 来的时候忙 ⇒ 记账
        else if (pending_r && idle_i)     pending_r <= 1'b0;          // 空闲了 ⇒ 清账（同拍启动）
    end
    wire start_now = (probe_req_i & idle_i) | (pending_r & idle_i);
    // 然后 S_IDLE 里把 `probe_req_i && idle_i` 换成 `start_now`
    // ③ 至少留下痕迹（饱和计数，与 uart_tx_fifo 同一套路）
    output reg [15:0] req_drop_cnt_o;      // probe_req_i 到达时 idle_i==0 的次数
    //   ... else if (probe_req_i && ~idle_i) req_drop_cnt_o <= sat_inc16(req_drop_cnt_o);
```
（span_probe 同法；sat_inc16 可从 uart_ui.v:154-159 直接搬。）同时改 top.v 的轴轮转：把 `pp_axis_r`/`np_axis_r` 的自增条件从 `cmd_probe_req` 换成"探针真的受理"—— 最省事的是给 pos_probe 加一个 `output reg accept_o`（在 S_IDLE → S_BCD 那一拍置 1），top.v 改成 `else if (pp_accept) pp_axis_r <= pp_axis_r + 4'd1;`。
- **预期**：收益 = "连发 16 次扫 16 轴"变成真的；丢请求从"静默"变"可读"；代价 = 1 个 FF + 1 个 16 位饱和计数器 + 1 根 `accept_o` 线。
- **怎么验**：写一个 tb，同一个 `idle_i==0` 窗口内连给两次 `probe_req_i`（间隔 1 拍），断言 `frame_cnt==2`（两包都出来）⇒ 当前只出 1 包 ⇒ 红；加 `pending_r` 后 ⇒ 绿。另断言 `req_drop_cnt_o` 在旧实现下必须为 0（证明它是"静默"的）。
- **来源**：ANVIL-10【P1-3】
@@@END
@@@PRIO=P1|SRC=ANVIL-10|ORIG=P1-4|MOD=rtl/w3c/uart_ui.v,rtl/top.v
### 决定 uart_ui 的 TX 通路与可观测计数器是接上还是删掉
- **位置**：rtl/w3c/uart_ui.v:72-79、:99-103、:189-196、:9-12、:44-45、:95-97；rtl/top.v:918-921、:897-898、:888-896、:922-934、:1354、:1365、:1121、:1336-1338；impl/gwsynthesis/Gowin2026.vg:2260-2290、:3160-3167；tb/w3c/tb_uart_ui.sv:190、:264、:271、:281
- **现状**：
```verilog
// rtl/w3c/uart_ui.v:72-79（TX 口）
    input  wire        tx_busy_i,          // ⭐ tx 忙（⛔ 别喂新字节）
    input  wire        tx_done_i,          // ⭐ tx 发送完成（单周期脉冲）
    output reg         tx_start_o,         // ⭐ 启动发送（单周期脉冲）
    output reg  [7:0]  tx_data_o,          // ⭐ 待发字节
// rtl/w3c/uart_ui.v:99-103（可观测口）
    output reg  [15:0] frame_cnt_o,        // ⭐ 成功解析的返回帧数（饱和）
    output reg  [15:0] resync_cnt_o,       // ⭐ 空闲归位次数（饱和）
    output reg  [15:0] err_cnt_o,          // ⭐ 「该是返回码却不是」的次数（饱和）
    output reg         hb_ready_o          // ⭐ 已收到 0x88 握手（⭐ 屏就绪）
// rtl/top.v:918-921
      .tx_busy_i     (1'b1),       // 本版只接收屏的控制帧
      .tx_done_i     (1'b0),
      .tx_start_o    (ui_tx_start),
      .tx_data_o     (ui_tx_data),
```
- **为什么是问题**（源码级证明，逐条可复现）：1. TX 口纯死：uart_ui.v 的 always 块里从未读 `tx_busy_i`/`tx_done_i`；`tx_start_o`/`tx_data_o` 只有复位值 0 和每拍的 `<= 1'b0`（:189-196）⇒ 永远输出 0；top.v 里 `ui_tx_start`/`ui_tx_data` 只出现在 :897-898（声明）与 :920-921（连线）⇒ 无读者。2. 可观测口纯死：`ui_frame_cnt`/`ui_resync_cnt`/`ui_err_cnt`/`ui_hb_ready`/`ui_mode_commit`/`ui_fx_en`/`ui_fx_sel`/`ui_test_mode`/`ui_test_mode_n` 在 rtl/top.v 全文件里只出现在声明行与例化端口行（:888-896 声明 + :922-934 端口）⇒ 无读者。3. `ui_test_mode_commit` 在交付配置下也无读者：它唯一的读者是 rtl/top.v:1365，而这一整块在 rtl/top.v:1354 的 `if (TEST_MODE_EN != 0) begin : g_test_mode` 里，rtl/top.v:72 是 `parameter integer TEST_MODE_EN = 0`（见 P1-5）⇒ 交付码流里没有读者。4. 网表佐证：综合后 `module uart_ui` 只剩 13 个端口（clk_d / n191_6 / n5639_5 / ur_done / rst_n_sync / byte_is_trans_up_8 / byte_is_tare_7 / ur_data / ui_base_commit / ui_mode_piano / n1095_4 / n1301_5 / ui_base_semi），整个 .vg 里 `commit` 只匹配到 `ui_base_commit` 一条。后果（三条，都是硬的）：①屏的状态回显根本没有物理通路（设计文档要求 `t0.txt="钢琴"` / `t1.txt="8"` / `t2.txt="C5"`，而 uart_ui.v:9-12 的"一个 UART 收发"在代码里只有收）；②触摸控件 2（Test Mode 切档）在交付码流里什么都不做，而 rtl/top.v:1336-1338 的注释声称"两个入口驱动同一状态机"；③`frame_cnt/resync_cnt/err_cnt` 在板上读不到，但 tb/w3c/tb_uart_ui.sv 有 6 条断言压着它们（:190、:264、:271、:281 等）⇒ tb 绿、板上瞎（C83 同族）；uart_ui.v:44-45 写的"任何会失效的路径都必须可观测（K-106）……在交付配置下不成立"。
- **改法**（按代价排序）：1. 最小、收益最大：把 `frame_cnt_o`/`resync_cnt_o`/`err_cnt_o`/`hb_ready_o` 接进 top.v 已有的故障汇总（`fault_any_w`，rtl/top.v:1121）与指示层，或复用 uart_ui 自己的 TX 口做状态回显 —— 后者顺手把设计文档 §4.2 的回显做掉；⚠️ 但注意 top.v:918 把 `tx_busy_i` 硬接 1'b1 ⇒ 一旦真要用 TX，必须改成接 `u_tx_fifo` 的 `ready_o`（或 ~busy），并决定屏和 PC 是否共用同一条 TX。2. 短期不做回显的话，至少把假接口删掉：删 `tx_busy_i`/`tx_done_i`/`tx_start_o`/`tx_data_o` 四个端口（以及 top.v:897-898、:918-921 四条连线），并把 uart_ui.v:9-12 的"复用 uart_tx.v"改成"本版只收不发"。3. `ui_mode_commit`/`ui_fx_*`：fx_* 是声明过的留位（uart_ui.v:95-97 已注明"恒 0"）⇒ 可以留；`ui_mode_commit` 无读者 ⇒ 删端口或接进 `play_fretboard_mode` 的握手。
- **预期**：收益 = 恢复"可观测/可回显"；代价 = 方案 1 要动 top.v 的 TX 仲裁（见 P3-6 的 rep_req 竞争），方案 2 是纯删除（0 风险）。
- **怎么验**：改之前 `Select-String -Path impl/gwsynthesis/Gowin2026.vg -Pattern 'test_mode' -SimpleMatch` 应只有 cmd_test_mode_req / byte_is_test_mode_8；`-Pattern 'ui_tx_start|ui_frame_cnt|ui_hb_ready'` 应为 0 条（全被剪）；改之后应能匹配到，且 module uart_ui 的端口数 > 13。
- **来源**：ANVIL-10【P1-4】
@@@END
@@@PRIO=P1|SRC=ANVIL-10|ORIG=P1-5|MOD=rtl/top.v
### 把 TEST_MODE_EN 的默认值与其注释对齐（现在代码 0、注释说保持 1）
- **位置**：rtl/top.v:72、:1340-1342、:1354、:1336-1338；impl/gwsynthesis/Gowin2026.vg（57 个 module 清单里没有 test_mode_ctrl）
- **现状**：
```verilog
// rtl/top.v:72
parameter integer TEST_MODE_EN       = 0,
// rtl/top.v:1340-1342
      //  ⭐⭐ 2026-10-04（codex 只读评审「阶段 1」）：**`TEST_MODE_EN` 双码流**
      //  📌 诊断码流（`TEST_MODE_EN=1`）**行为与改动前逐字一致**；默认值保持 1，
      //     以免影响现有测试台与上板习惯。
// rtl/top.v:1354
        if (TEST_MODE_EN != 0) begin : g_test_mode
```
- **为什么是问题**：证据：impl/gwsynthesis/Gowin2026.vg 的 57 个 module 清单里没有 `test_mode_ctrl` ⇒ 默认构建里 `g_test_mode` 整块不存在。后果：rtl/top.v:1336-1338 的"串口屏触摸控件 2（`ui_test_mode_commit`）与 'M' 命令（`cmd_test_mode_req`）并联，两个入口驱动同一状态机"在默认码流里是假的。加上 P1-4，屏侧的 Test Mode 按钮有两重失效。
- **改法**：二者取一，必须动一处：若"默认 1"是意图 ⇒ rtl/top.v:72 改 `= 1`，并重跑 PnR（会多回 test_mode_ctrl 那一块逻辑，可能吃掉余量 —— 见 0.102 ns）；若"默认 0"是意图（看起来更像，因为它是当前交付态）⇒ 把 :1341 改成 `//  📌 默认 0 = **关闭**（交付码流不含 Test Mode）；只有出诊断码流时才临时置 1。`
- **预期**：收益 = 消掉一处会误导后续改动的假注释；代价 = 0（纯注释）或一次 PnR（若真开）。
- **怎么验**：`Select-String -Path impl/gwsynthesis/Gowin2026.vg -Pattern '^module test_mode_ctrl'`（现在 0 条）。
- **来源**：ANVIL-10【P1-5】
@@@END
@@@PRIO=P1|SRC=ANVIL-10|ORIG=P1-6|MOD=rtl/w3c/uart_ui.v
### 先上板抓包验证 0x65 帧体布局（现在把第一个帧体字节当控件 ID）
- **位置**：rtl/w3c/uart_ui.v:233-238、:272-274、:14-20、:250；files/30-方案决策/产品形态决议清单.md:660-661；files/20-代码/FPGA侧串口屏UI规划-丙-20260927.md:102、:86-90；tb/w3c/tb_uart_ui.sv:198；bringup/24-上板卡-BA-T2起始音-20261001.md:26
- **现状**：
```verilog
// rtl/w3c/uart_ui.v:233-238
                                RET_TOUCH: begin
                                    // ⭐ 触摸事件：body_q = 控件 ID
                                    //   ⭐ 约定（见 tb）：控件 0 = 模式切换，控件 1 = 起始音，
                                    //      控件 2 = Test Mode 切档（⭐ A1）
                                    if (body_q == 7'd0) begin
                                        mode_o        <= ~mode_o;    // ⭐ 翻转
// rtl/w3c/uart_ui.v:272-274（body_q = **第一个**帧体字节）
                            if (body_len == 6'd0) begin
                                body_q <= rx_data_i[6:0];
                            end
```
- **为什么是问题**：产品形态决议清单.md:660-661 的 §九-3 表只列了返回码与含义（`0x65` = 控件点击事件返回；`0x70`/`0x71` = 字符串/数值变量数据返回），没有任何帧体字节布局。而 `body_q` = 帧体第 0 个字节这个约定，唯一出处是 FPGA侧串口屏UI规划-丙-20260927.md:102（"0x65 → 帧体 = 控件 ID（body_q）"），那份是规划文档（同一份 :86-90 还自己承认 `val_q>>1` 是"待精修点"）。淘晶驰 TJC 的 0x65 触摸返回在公开资料里是 `<page_id> <component_id> <event>` 三字节 —— 若实际如此，`body_q` 拿到的是 page_id（页 0 ⇒ 恒 0）⇒ **每一次触摸都会 `mode_o <= ~mode_o`**，包括点"起始音"和"Test Mode"控件。这正好是"会错"。
- **改法**（先验证，再决定）：1. 验证门（必须做，15 分钟）：把屏接到 J9（TX→N26 / RX→N25 / GND，500000 8N1，与 bringup/24-上板卡-BA-T2起始音-20261001.md:26 同一条），用串口助手原始 hex 抓一次"点控件 0"和"点控件 2"的完整返回帧，逐字节记下来。2. 若帧体第 0 字节确实是控件 ID ⇒ 本条作废，只把 uart_ui.v:233 的注释补上出处（抓到的原始帧）。3. 若帧体是 `page_id component_id event` ⇒ 改 uart_ui.v:272-274 的取字节位置（示例：`if (body_len == 6'd1) body_q <= rx_data_i[6:0];`）并把 :233-238 的注释改成实测布局。4. 无论哪种，都建议加一条"未知控件 ID"的可观测：`body_q` 不在 {0,2} 时计一个 `unknown_ctrl_cnt`（现在静默忽略，uart_ui.v:250 的 end 什么都不做）。
- **预期**：收益 = 把"屏能不能用"这件事从"假设"变成"实测"；代价 = 一次上板抓包。
- **怎么验**：tb/w3c/tb_uart_ui.sv:198 用的是 `feed_frame(8'h65, 8'h00, 8'h00)`（1 个帧体字节），它把假设写进了 tb ⇒ tb 永远测不出这个假设错。改法：把 tb 的帧体改成从实测抓包抄来的真实字节序列（例如 `65 00 02 01 FF FF FF`），并断言"只有 component_id==2 时才切 Test Mode"⇒ 当前实现下若按新字节序，控件 2 的帧会被判成控件 0 ⇒ 红。
- **来源**：ANVIL-10【P1-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-1|MOD=rtl/w3c/uart_ui.v
### 给 uart_ui 补帧长模型并在进帧时清 body_q/val_q
- **位置**：rtl/w3c/uart_ui.v:22-27、:222-281、:271-279、:235、:217、:279；bringup/24-上板卡-BA-T2起始音-20261001.md:30；files/20-代码/审计-top集成与时钟复位-20260928.md:239；tb/w3c/tb_uart_ui.sv
- **现状**：
```verilog
// rtl/w3c/uart_ui.v:22-27（声称的机制）
//     · ⭐ 只在「帧内正确位置」看返回码（⛔ 不在数据中间找）
//     · ⭐ 靠「返回码已知 + 定长/自描述长度」维持同步
// rtl/w3c/uart_ui.v:222-281（实际只有"3 连 0xFF"这一条规则，没有任何长度表）
                S_BODY: begin
                    if (rx_data_i == FRAME_TAIL) begin
                        if (tail_cnt == 3'd2) begin
// rtl/w3c/uart_ui.v:271-279（body_q/val_q 只在 body_len==0/1 时写，帧开始时不清零）
                            if (body_len == 6'd0) begin
                                body_q <= rx_data_i[6:0];
                            end
                            if (body_len == 6'd1) begin
                                val_q <= rx_data_i;
                            end
```
- **为什么是问题**：1. `0xFF` 在载荷里：0x71 的载荷是多字节小端数值（审计-top集成与时钟复位-20260928.md:239）；只要其中任一字节是 0xFF，它就会被 `tail_cnt` 计进去 ⇒ 与真正的帧尾拼成"3 连"⇒ 帧提前一拍结束，剩下的载荷字节落到 S_IDLE 被计成 `err_cnt`（uart_ui.v:217）；0x70（GBK 字符串）里出现 0xFF 的概率不低。2. 无帧体的帧：`body_q`/`val_q` 在进入新帧时不重置；若屏发一帧 `0x65 FF FF FF`（无帧体），:235 的 `if (body_q == 7'd0)` 用的是上一帧的控件 ID ⇒ 上一帧若是控件 2，这一帧就会误切 Test Mode。3. `body_len` 是 6 位、无上界检查（:279），长帧会回绕到 0 并重新捕获 `body_q`/`val_q`。
- **改法**：
```verilog
    //  ⭐ 帧长表（单位：帧体字节数）。必须来自**实测抓包**（见 P1-6）。
    //     ⚠️ 两份仓库文档对 0x71 的载荷长度互相矛盾：
    //        bringup/24-上板卡-BA-T2起始音-20261001.md:30   = `71 01 xx FF FF FF`（1 个数值字节）
    //        files/20-代码/审计-top集成与时钟复位-20260928.md:239 = 4 字节小端数值
    //     ⇒ 先用抓包裁定，再填这张表。未裁定的先填 0（= 只靠 3 连 0xFF，行为不变）。
    function [5:0] body_len_of;
        input [7:0] rc;
        begin
            case (rc)
                RET_TOUCH: body_len_of = 6'd0;   // ⚠️ 待 P1-6 裁定
                RET_NUM:   body_len_of = 6'd5;   // 变量序号 1 + 4 字节数值（待裁定）
                RET_STR:   body_len_of = 6'd0;   // 变长 ⇒ 只能靠 0xFF 帧尾
                default:   body_len_of = 6'd0;
            endcase
        end
    endfunction
    //  S_BODY 里：
    //    wire frame_end = (rx_data_i == FRAME_TAIL && tail_cnt == 3'd2)
    //                   | ((body_len_of(retcode) != 6'd0) && (body_len == body_len_of(retcode)));
    //  并在进入 S_BODY 时清 body_q / val_q：
    //    body_q <= 7'd0;  val_q <= 8'd0;
```
- **预期**：收益 = 消掉"载荷含 0xFF 就错帧"与"无帧体帧用陈旧 ID"两类静默错误；代价 = 一张长度表 + 2 行清零。
- **怎么验**：tb_uart_ui 里加一帧 `feed(8'h71); feed(8'h01); feed(8'h00); feed(8'hFF); feed(8'h00); feed(8'hFF); feed(8'hFF); feed(8'hFF);`（载荷第 2 字节是 0xFF）⇒ 当前实现会提前在第 2 个 0xFF 处结束；断言 `frame_cnt` 只 +1 且 `base_semi` 仍按 LSB=0x00 落地 ⇒ 红。
- **来源**：ANVIL-10【P2-1】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-2|MOD=rtl/w3c/span_probe.v
### 把 span_probe 的 reject 字段从"恒发 '0'"改成十进制两位
- **位置**：rtl/w3c/span_probe.v:119-128、:44-46、:52；tb（span probe）
- **现状**：
```verilog
        case (idx)
            4'd0:    tx_byte_c = 8'h56;              // 'V'
            4'd1:    tx_byte_c = hexch({1'b0, st_lat});
            4'd2:    tx_byte_c = hexch(ax_lat);
            4'd3:    tx_byte_c = hexch(rj_lat);
            4'd4:    tx_byte_c = 8'h30;              // ⭐ reject 低 4 位恒 0（⭐ 0~8）
            4'd5:    tx_byte_c = 8'h0D;              // CR
            default: tx_byte_c = 8'h0A;              // LF
        endcase
// 对照文件头 rtl/w3c/span_probe.v:44-46
//  · `<rej>`    —— ⭐ 1 位 hex：⭐ `reject_cnt` 高位
//  · `<rej2>`   —— ⭐ 1 位 hex：⭐ `reject_cnt` 低位
//      ⇒ ⭐ 合起来 = `reject_cnt` 的 2 位 hex（⭐ 0~8，⭐ `REJECT_MAX=8`）
```
- **为什么是问题**：`idx==3` 已经发了 `hexch(rj_lat)`（`rej_i` 是 4 位，`rj_lat` 0~F 的完整十六进制），`idx==4` 再发一个字面 `'0'` ⇒ 串口上看到的是 `rj_lat` 后面跟一个 0，读起来是 `reject_cnt × 16`。`rej_cnt = 8`（REJECT_MAX）印成 `80`；`rej_cnt = 10` 印成 `A0` ⇒ 这不是"两位 hex"，是"一位 hex + 一个字面 0"。span_probe.v:52 的判读表（"停在 7 ⇒ 已放弃，那 reject_cnt 应该是 8"）会被读成 80。
- **改法**（十进制两位最可读，`rj_lat ≤ 15`）：
```verilog
            4'd3:    tx_byte_c = 8'h30 + {4'd0, (rj_lat / 4'd10)};   // 十位
            4'd4:    tx_byte_c = 8'h30 + {4'd0, (rj_lat % 4'd10)};   // 个位
```
（`/`、`%` 对 4 位常量 10：rej_cnt 只有 0~15 ⇒ 综合成 2 个小比较器，代价可忽略。若坚持十六进制，就把 :44-46 的注释改成"`<rej>` = 十六进制一位，`<rej2>` 恒 '0'"。）
- **预期**：收益 = 诊断读数不再被误读 16 倍；代价 = 2 个 4 位比较器。
- **怎么验**：tb 里喂 `rej_i = 4'hA` ⇒ 当前回包 `V..A0`；断言期望 `V..10`（十进制）⇒ 红。
- **来源**：ANVIL-10【P2-2】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-3|MOD=rtl/w3c/pos_probe.v
### 处理 pos_probe 里只写不读的 pos_lat（删掉或让它真的当锁存）
- **位置**：rtl/w3c/pos_probe.v:125、:209、:238-239、:241；impl/gwsynthesis/Gowin2026.vg
- **现状**：
```verilog
// :125 声明 reg [11:0] pos_lat;
// :209 复位 pos_lat <= 12'd0;
// :238-239 赋值
                        // 🔴 **锁存读数**（⭐ 否则回传期间读数变了 ⇒ 同一行数字不自洽）
                        pos_lat   <= pos_i;
// 全文件没有第三处引用（读者）
```
- **为什么是问题**：`Select-String -Path impl/gwsynthesis/Gowin2026.vg -Pattern pos_lat -SimpleMatch` = **0 条**。真正承担"锁存"职责的是 `rem`（pos_probe.v:241 `rem <= pos_i`），而 BCD 流水把 `rem` 一路减到 0 就销毁了。`pos_lat` 恰好也被赋了同样的值，所以看起来像是"锁存值"，但没有任何逻辑用它。危害是维护陷阱：任何后来想"把锁存值以别的格式（hex/二进制）回传"的人会去读 `pos_lat`，以为它有效；而一旦有人顺手删掉 :239 那行赋值，编译不报错（只写不读的寄存器被删是合法的），`pos_lat` 就变成常量/X —— 静默。
- **改法**（二选一）：1. 纯清理：删掉 :125、:209、:239 三行（综合本来已经删了，源码对齐即可）。2. 保留语义：让 `rem` 从 `pos_lat` 起步，把"锁存"这件事交给它：`:241 改成 rem <= pos_lat;`（pos_lat 变成真锁存，注释才成立）。
- **预期**：收益 = 消掉一个维护陷阱；代价 = 0（方案 1 是删 3 行）。
- **怎么验**：改后综合网表里 `pos_lat` 仍是 0 次（事实）；用 `-Filter pos_probe` 保证功能不变（通过 2 / 共 2）。
- **来源**：ANVIL-10【P2-3】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-4|MOD=rtl/w3c/uart_tx_fifo.v
### 把 uart_tx_fifo 的 AW 从硬编码 3 改成 $clog2(DEPTH) 并补参数自检
- **位置**：rtl/w3c/uart_tx_fifo.v:83-86、:27、:189-193；rtl/top.v:1123、:1327；tb/w3c/tb_uart_tx_fifo.sv
- **现状**：
```verilog
    // ── ⭐ 常量（⛔ 不对 integer 参数做位选 —— `K-91`）──────────────────────
    localparam integer  AW   = 3;                    // ⭐ DEPTH=8 ⇒ 3 位地址
    localparam [AW:0]   DEPTHV = DEPTH[AW:0];        // ⭐ 先算，再赋值给定宽
    localparam [AW-1:0] ONE  = {{(AW-1){1'b0}}, 1'b1};
```
- **为什么是问题**：`DEPTH` 是 integer（32 位），`DEPTH[3:0]` 取低 4 位。`DEPTH=8` ⇒ `8[3:0] = 4'b1000 = 8` ⇒ `full = (cnt==8)` ✅；`DEPTH=16` ⇒ `16[3:0] = 4'b0000 = 0` ⇒ **`full = (cnt==0)`** ⇒ 空的时候判满 ⇒ 每次 `push_i` 都走 :189-193 的溢出分支（`ovf_r<=1`、`drop_r+1`），`cnt` 永远是 0，`wr_ptr` 只有 3 位、`mem[0:15]` 只用前 8 项 ⇒ **FIFO 永久死**，且只在 `ovf_r` 上留痕（而 `ovf_o` 无人读 —— 见 P2-5）；`DEPTH=4` ⇒ `DEPTHV=4`、cnt 4 位、`mem[0:3]`、`wr_ptr` 3 位 ⇒ 能凑合但浪费地址位。⇒ `DEPTH` 参数实际上只支持 2/4/8，uart_tx_fifo.v:27 写的"深度 8（2 的幂 ⇒ 位与代替取模）"暗示它可参数化 —— 不成立。而且这一行正是 uart_tx_fifo.v:83 自己写着"⛔ 不对 integer 参数做位选 —— K-91"的那条禁令。
- **改法**：
```verilog
    localparam integer  AW    = $clog2(DEPTH);       // ⭐ 不写死 3
    localparam [AW:0]   DEPTHV = DEPTH;              // ⭐ 赋值，⛔ 不位选（K-91）
    localparam [AW-1:0] ONE   = {{(AW-1){1'b0}}, 1'b1};
    initial begin
        if (DEPTH < 2 || ((DEPTH & (DEPTH - 1)) != 0))
            $fatal(1, "ERROR [uart_tx_fifo] DEPTH=%0d must be a power of two and >= 2", DEPTH);
    end
```
（`$clog2` 在本工程可用 —— rtl/top.v:1327 已经在用 `$clog2(POLY_TARGET)`。）
- **预期**：收益 = 参数真的能用、K-91 违规消除；代价 = 0（`DEPTH=8` 时综合结果逐位相同）。
- **怎么验**：把 rtl/top.v:1123 改成 `uart_tx_fifo #(.DEPTH(16)) u_tx_fifo (...)` 并跑 `sim\tb_all.ps1 -Filter uart_tx_fifo` ⇒ 当前会红（字节全被丢）；改完 `$clog2` 后应绿。
- **来源**：ANVIL-10【P2-4】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-5|MOD=rtl/top.v,rtl/w3c/uart_tx_fifo.v
### 把 uart_tx_fifo 的溢出计数与探针 busy_o 接上（或删掉）
- **位置**：rtl/w3c/uart_tx_fifo.v:30-33、:1-21；rtl/top.v:1102、:1111、:1133-1135、:2104、:2135、:2142、:2894、:2160、:2173、:2955、:3005、:1121、:2125-2136；rtl/w3c/pos_probe.v:105；rtl/w3c/span_probe.v:92
- **现状**：
```verilog
// rtl/w3c/uart_tx_fifo.v:30-33（它自己定的纪律）
//  ② 🔴 **溢出【必须可观测】**（⭐ `K-106`：能失败的路径必须留下痕迹）
//     · ⭐ `ovf_o`：⭐ **sticky** —— 一旦丢过就置位，⭐ 读到才清
//     · ⭐ `drop_cnt_o`：⭐ **饱和计数** —— ⛔ 不回绕（⭐ 不会"丢 256 个显示 0"）
//     📌 **理由**：⭐ 如果只是"悄悄丢"，⭐ 那和改之前【没区别】
// rtl/top.v:1102 / :1111 / :1133-1135
    wire       txf_ovf;
    wire [7:0] txf_drop;
        .ovf_o     (txf_ovf),
        .drop_cnt_o(txf_drop),
        .ovf_clr_i (1'b0)           // ⚠️ 本版不清（⭐ 置位后保持 ⇒ 上板可观测）
```
- **为什么是问题**：`txf_ovf`/`txf_drop` 在 rtl/top.v 全文件里只有这 4 行（声明 2 + 连线 2），没有读者；`ovf_clr_i` 还硬接 0 ⇒ sticky 标志永远读不到。`pp_busy`（:2104/:2135）、`np_busy`（:2142/:2894）、`vp_busy`（:2160/:2173）、`dp_busy`（:2955/:3005）同样"只声明 + 只连线"。`uart_tx_fifo` 存在的唯一理由（uart_tx_fifo.v:1-21，修 K-126）是"把忙就丢改成排队"；而"排队也会满"这件事的可观测性，就是 `ovf_o` + `drop_cnt_o`。它们被剪掉之后，这条修复的可验证性归零 —— 正好回到它自己写的"那和改之前没区别"。4 个探针的 `busy_o` 同理：top.v:2125-2136 的例化注释依赖 `busy_o` 做可观测，但没人读。
- **改法**（最小、复用现有设施）：
```verilog
    // top.v：接进已有的故障汇总（fault_any_w 已在 :1121 声明、已进心跳/指示层）
    assign fault_any_w = ... | txf_ovf | (txf_drop != 8'd0);
    // 并给 ovf_clr_i 一个"读走清零"脉冲（例如调试命令解析出的一条）
    // 探针 busy_o：若确实不用 ⇒ 从 pos_probe/span_probe 端口表里删掉（省 4 根线 + 4 个 top 网）
```
若暂时不想动 `fault_any_w`，最低限度是把 `txf_drop != 0` 接到一个 LED/指示位 —— 关键是别让它 0 读者。
- **预期**：收益 = K-126 的修复重新变成可验证的；代价 = 1 条 or 链 + 1 条清零脉冲（或纯删除）。
- **怎么验**：`Select-String -Path impl/gwsynthesis/Gowin2026.vg -Pattern 'txf_ovf|txf_drop|pp_busy|vp_busy|np_busy' -SimpleMatch` 现在应全为 0（配合源码"无读者"才是证明），改后应能匹配到。
- **来源**：ANVIL-10【P2-5】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-6|MOD=rtl/w3c/uart_rx.v
### 给 uart_rx 补停止位校验与帧错误输出
- **位置**：rtl/w3c/uart_rx.v:155-170、:100-102、:28-53；rtl/top.v（frame_err_o 接入 fault_any_w）；tb（uart_rx）
- **现状**：
```verilog
                S_DATA: begin
                    if (clk_cnt == MID_CNT) begin
                        rx_data_o[bit_cnt] <= rx_d2;    // ⭐ LSB 先进 ⇒ bit0 在最低位
                        clk_cnt            <= clk_cnt + 16'd1;
                    end else if (clk_cnt == DIV_LAST) begin
                        if (bit_cnt == 3'd7) begin
                            state     <= S_IDLE;        // ⭐ 8 位采完
                            rx_done_o <= 1'b1;          // ⭐ 单周期完成脉冲
                        end else begin
```
- **为什么是问题**：8 位采完当拍就回 S_IDLE，`clk_cnt` 停在 `DIV_LAST`(=99)；停止位（第 10 位，clk_cnt 0..99 的最后一段）从来没有被采样。若对端是 break（rx 长时间拉低），S_IDLE 里 `rx_d2==0` 立刻再进 S_START ⇒ **每 100 拍产出 1 个 rx_done(0x00)**；`BAUD_DIV=100` ⇒ 50 MHz/100 = **500 000 字节/秒**的假 0x00。这会把 uart_ui 的 `err_cnt`（现在是死的，见 P1-4）、calib_cmd 的 `unknown_cnt`、evt_uart_rx 的 `hdr_err_cnt` 全部刷爆，而没有任何一路能区分"帧错误"与"真字节 0x00"。对端波特率不匹配时同理（rtl/w3c/uart_rx.v:28-53 花了大量注释讨论"误码"，但代码里没有误码可观测）。
- **改法**：
```verilog
    output reg        frame_err_o       // ⭐ 新增：停止位不是 1（帧错误 / break）
    //  ⭐ 在采完第 8 位的那一拍同时看停止位采样点
    localparam [15:0] STOP_CNT = DIV_LAST;          // 停止位中点 ≈ DIV_LAST
    S_DATA: begin
        if (clk_cnt == MID_CNT) begin
            rx_data_o[bit_cnt] <= rx_d2;
            clk_cnt            <= clk_cnt + 16'd1;
        end else if ((bit_cnt == 3'd7) && (clk_cnt == STOP_CNT)) begin
            state       <= S_IDLE;
            frame_err_o <= ~rx_d2;                  // ⭐ 停止位应为 1
            rx_done_o   <= ~(~rx_d2);               // ⭐ 帧错误时不产生 rx_done
        end else if (clk_cnt == DIV_LAST) begin
            bit_cnt <= bit_cnt + 3'd1;
            clk_cnt <= 16'd0;
        end else begin
            clk_cnt <= clk_cnt + 16'd1;
        end
    end
```
（`DIV_LAST` 那一档要相应让位；具体拍点按 `MID_CNT=50`/`DIV_LAST=99` 重算，保证 8 个数据位仍是 100 拍一位。）然后在 top.v 里把 `frame_err_o` 接进 `fault_any_w`。
- **预期**：收益 = 第一次拥有"串口链路错误"的硬件可观测（K-47/K-87 那一族问题的根因定位能力）；代价 = 1 个 FF + 1 根线 + 一次 tb 拍点核对。
- **怎么验**：写 tb，发一帧把停止位拉低（rx 在第 10 位仍为 0）⇒ 断言 `rx_done_o` 不产生且 `frame_err_o` 产生 ⇒ 当前实现会红（rx_done_o 照样产生）。
- **来源**：ANVIL-10【P2-6】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-7|MOD=rtl/w3c/uart_ui.v,rtl/w3c/evt_uart_rx.v
### 把 idle_q 的位宽由 GAP_CLK_I 派生（现在 20 位，实际只需 11 位）
- **位置**：rtl/w3c/uart_ui.v:109-111、:134、:136、:141-149；rtl/w3c/evt_uart_rx.v:114-116、:123、:128、:146-154；rtl/w3c/uart_rx.v:26-72；tb（uart / evt）
- **现状**：
```verilog
    localparam integer BYTE_CLK_I = (CLK_HZ + BAUD/2) / BAUD;   // ⭐ 四舍五入
    localparam integer GAP_CLK_I  = BYTE_CLK_I * GAP_BYTES;
    localparam [19:0]  GAP_CLK    = GAP_CLK_I;                  // ⭐ 赋值 ⇒ 自动截断
    reg [19:0] idle_q;         // ⭐ 距上次收到字节的 clk 数（饱和）
    wire idle_expired = (idle_q >= GAP_CLK);
        end else if (!idle_expired) begin
            idle_q <= idle_q + 20'd1;
```
- **为什么是问题**：`CLK_HZ=50_000_000`、`BAUD=500_000` ⇒ `BYTE_CLK_I = (50000000+250000)/500000 = 100`、`GAP_CLK_I = 100 × 16 = 1600` ⇒ 需要 `⌈log2(1601)⌉ = 11 位`。现在是 20 位 ⇒ ①每个模块多 9 个 FF（两个模块共 18 FF）；②`idle_q >= GAP_CLK` 是 20 位比较（其中高 9 位恒与 0 比，综合能折掉一部分）；③`idle_q + 20'd1` 是 20 位进位链，且它和 `idle_expired` 构成每拍的自环；④🔴 更严重的是那句注释"赋值 ⇒ 自动截断"把一个真隐患说成了特性：`GAP_CLK_I ≥ 2^20` 时会静默截断。触发点：`BYTE_CLK_I × GAP_BYTES ≥ 1 048 576`；取 `GAP_BYTES=16` ⇒ `BYTE_CLK_I ≥ 65 536` ⇒ `BAUD ≤ 50e6/65536 ≈ 763 bps`。一旦有人为了兼容老上位机把 BAUD 降到 300（uart_rx.v:26-72 明确说"上板若实测误码要能退档"），`BYTE_CLK_I = 166 667`、`GAP_CLK_I = 2 666 672` ⇒ `& 0xFFFFF = 570 736` ⇒ **归位阈值变成实际字节时间的 3.4 倍**，每帧都会被中途归位（`resync_cnt` 涨、`frame_cnt` 不涨）—— 而 `resync_cnt` 在板上读不到（P1-4）。**静默**。
- **改法**：
```verilog
    localparam integer GAP_CLK_I = BYTE_CLK_I * GAP_BYTES;
    localparam integer IW = $clog2(GAP_CLK_I + 1);      // ⭐ 1600 ⇒ 11
    localparam [IW-1:0] GAP_CLK = GAP_CLK_I;            // ⭐ 宽度由常量决定，⛔ 不写死 20
    reg [IW-1:0] idle_q;
    initial begin
        if (GAP_BYTES < 2)
            $fatal(1, "ERROR [uart_ui] GAP_BYTES=%0d < 2 => 帧内字节间隙会被误判成空闲", GAP_BYTES);
    end
```
（evt_uart_rx 同法；evt_uart_rx 现在一个 initial 自检都没有，与 uart_rx/uart_tx 的风格不一致。）
- **预期**：收益 = 每模块 −9 FF、比较与进位链各 −9 位（约 1 个 LUT 层），并消掉静默截断；代价 = 0（行为逐位相同）。
- **怎么验**：`-Filter uart` / `-Filter evt` 全绿；综合报告里两个模块的 Register 数各降 9。反例验证：把 `GAP_BYTES` 改成 70000 跑一次综合，当前实现不报错（静默截断），加 IW 后 `GAP_CLK_I` 超出时由 `$fatal` 抓住。
- **来源**：ANVIL-10【P2-7】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-8|MOD=rtl/w3c/uart_tx.v,rtl/w3c/uart_rx.v
### 把 uart_tx/uart_rx 的分频计数器从 16 位收窄到 $clog2(BAUD_DIV)
- **位置**：rtl/w3c/uart_tx.v:77-79、:119-120、:151-152、:220；rtl/w3c/uart_rx.v:100-102、:143-168、:196
- **现状**：
```verilog
// uart_tx
    localparam [15:0] DIV_LAST = BAUD_DIV - 1;   // ⭐ 一位的最后一拍
    localparam integer CW = 16;
    reg  [CW-1:0] baud_cnt_q;
    wire baud_tick = active_q && (baud_cnt_q == DIV_LAST);
// uart_rx
    localparam [15:0] MID_CNT   = BAUD_DIV >> 1;        // 位中点
    localparam [15:0] START_MID = (BAUD_DIV >> 1) - 1;  // 起始位中点检查点
    localparam [15:0] DIV_LAST  = BAUD_DIV - 1;         // 一位的最后一拍
```
- **为什么是问题**：`BAUD_DIV = 100` ⇒ 计数值 0..99 ⇒ **7 位足够**。uart_tx：自环 `baud_cnt_q → (==DIV_LAST) → 清 0 / +1 → baud_cnt_q` 上是 16 位等值比较 + 16 位进位链；uart_rx：同一条自环上挂了两个 16 位比较（`clk_cnt==MID_CNT`、`clk_cnt==DIV_LAST`）外加 `clk_cnt+1` 的 16 位进位链。16 位等值比较对常量可折进 LUT4 的 INIT（约 2 层 LUT4：4 个 LUT4 覆盖 16 位 + 1 个收口），进位链走专用 carry ⇒ 实际收益约 1 个 LUT 层 + 18 个 FF（两个模块）。不是大钱，但零风险。⚠️ 诚实边界：这条是结构性的（深度由 RTL 写死的位宽决定，与布局无关），但它不是当前瓶颈 —— uart_tx/uart_rx 不在最差 25 条 setup 路径里，余量 ≥ 0.85 ns ⇒ 收益是余量，不是"修违例"。
- **改法**：
```verilog
    // uart_tx
    localparam integer CW = $clog2(BAUD_DIV);        // 100 ⇒ 7
    localparam [CW-1:0] DIV_LAST = BAUD_DIV - 1;
    // uart_rx
    localparam integer CW = $clog2(BAUD_DIV);
    localparam [CW-1:0] MID_CNT = BAUD_DIV >> 1;
    localparam [CW-1:0] START_MID = (BAUD_DIV >> 1) - 1;
    localparam [CW-1:0] DIV_LAST = BAUD_DIV - 1;
    //  并把 reg [15:0] clk_cnt / [CW-1:0] baud_cnt_q 与所有 16'dX 常量一起改宽
```
（注意 uart_rx.v:196 的 `$fatal` 文案里提到 `START_MID` 回绕到 65535 —— 改宽后那段描述要同步改，否则注释又变成假的。）
- **预期**：收益 = 每模块 −9 FF（16→7）、比较/进位链 −9 位；代价 = 0。
- **怎么验**：`-Filter uart` 全绿 + 综合报告 FF 数下降。
- **来源**：ANVIL-10【P2-8】
@@@END
@@@PRIO=P2|SRC=ANVIL-10|ORIG=P2-9|MOD=rtl/w3c/pos_probe.v
### 按阶段不变量窄化 pos_probe 的三棵十进制比较器树
- **位置**：rtl/w3c/pos_probe.v:134-173（三棵独立树）、:254-278（使用）、:241；tb/w3c/tb_pos_probe.sv、tb_pos_probe_axis.sv
- **现状**：
```verilog
    reg [3:0] cur_digit;
    always @(*) begin
        if      (rem >= 12'd900) cur_digit = 4'd9;
        ...
    end
    reg [3:0] cur_thou;                       // ⭐ 千位比较器 —— ⚠️ 与上面那个分开
    reg [3:0] cur_ten;                        // 🔴 十位比较器 —— 也必须【独立】
    // 使用处（:254-278）
                    case (bcd_stage)
                        3'd0: begin bcd3 <= cur_thou; rem <= rem - ({8'd0, cur_thou} * 12'd1000); end
                        3'd1: begin bcd2 <= cur_digit; rem <= rem - cur_x100; end
                        3'd2: begin bcd1 <= cur_ten; ...
```
- **为什么是问题**：三棵树都是 `rem` 的纯组合函数，都在同一个 always 块里被 case 引用 ⇒ 综合器无法按 `bcd_stage` 裁剪，三棵（9 + 4 + 9 = **22 个 12 位比较器** + 3 个优先 mux）每拍全部实现，而每拍只有一棵的输出去驱动减法。按 12 位 `>= 常量` ≈ 2 个 LUT4 计：约 44 LUT/实例，两个活实例 ≈ 88 LUT，其中约 2/3 是同一拍用不到的（CLS 23303/29952 = 78% —— 这类冗余直接吃最紧的那个资源）。关键不变量（逐值验证过，可安全利用）：`bcd_stage=0` 时 `rem = pos_lat ≤ 4095`（12 位）；`bcd_stage=1` 时 `rem < 1000`（stage0 减掉 `cur_thou*1000`，而 `cur_thou = floor(pos_lat/1000)`）；`bcd_stage=2` 时 `rem < 100`；`bcd_stage=3` 时 `rem < 10`（`bcd0 <= rem[3:0]` 因此正确）⇒ **`cur_digit` 只需要看 `rem[9:0]`，`cur_ten` 只需要看 `rem[6:0]`**。
- **改法**（低风险版：只窄化，不重排）：
```verilog
    wire [9:0] rem_h = rem[9:0];        // 百位：rem<1000 ⇒ 10 位够
    wire [6:0] rem_t = rem[6:0];        // 十位：rem<100  ⇒ 7 位够
    always @(*) begin                    // cur_digit
        if      (rem_h >= 10'd900) cur_digit = 4'd9;
        else if (rem_h >= 10'd800) cur_digit = 4'd8;
        ...
        else                       cur_digit = 4'd0;
    end
    always @(*) begin                    // cur_ten
        if      (rem_t >= 7'd90) cur_ten = 4'd9;
        ...
    end
```
更高收益但风险更高的版本（建议排在 P1-1 之后单独做、并逐值回归 0..4095）：把三棵树合并成一棵共享阈值的译码器 —— 因为阈值集合 `{1000..4000} ∪ {100..900} ∪ {10..90}` 都在同一个 `rem` 上，可以用一次 12→4 的优先编码 + 少量修正代替 22 个独立比较。
- **预期**：低风险版约省 7 个比较器位宽（≈ 8~12 LUT/实例）；高收益版约省 30 LUT/实例（×2 实例）。代价 = 低风险版 0（不变量可证明）；高收益版需要穷举 tb。
- **怎么验**：`-Filter pos_probe` 必须保持 `通过 2 / 共 2`；另加一条穷举：`for (v=0; v<=4095; v=v+1)` 驱动 `pos_i=v`，断言回包十进制 == `v`（4 位补零）—— **这条 tb 现在不存在**，建议无论改不改都先加。
- **来源**：ANVIL-10【P2-9】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-1|MOD=rtl/w3c/pos_probe.v,rtl/w3c/span_probe.v
### 把 N_BYTES[3:0] 位选改成定宽常量并补合法值自检
- **位置**：rtl/w3c/pos_probe.v:288、:199；rtl/w3c/span_probe.v:167、:127
- **现状**：
```verilog
// rtl/w3c/pos_probe.v:288
if (idx == (N_BYTES[3:0] - 4'd1)) begin
// rtl/w3c/span_probe.v:167
if (idx == (N_BYTES[3:0] - 4'd1)) begin
// rtl/w3c/pos_probe.v:199 / rtl/w3c/span_probe.v:127
default: tx_byte_c = 8'h0A;   // LF
```
- **为什么是问题**：`N_BYTES` 是 integer，`N_BYTES[3:0]` 取低 4 位。`N_BYTES=8 ⇒ 8` ✅、`7 ⇒ 7` ✅，但 `N_BYTES=16 ⇒ 0` ⇒ `idx == 4'd15` 永远不成立 ⇒ **状态机永远停在 S_SEND**（`busy_o` 恒 1，探针永久死）。另外 `tx_byte_c` 的 case 只覆盖 `idx = 0..6`，`default` 是 LF ⇒ 若 `N_BYTES>7` 而 `LAST_IDX` 判错，会静默发出 LF 而不是报错。
- **改法**：
```verilog
    localparam [3:0] LAST_IDX = N_BYTES - 1;      // ⭐ 赋值，⛔ 不位选（K-91）
    initial begin
        if (N_BYTES < 7 || N_BYTES > 7)
            $fatal(1, "ERROR [span_probe] N_BYTES=%0d must be 7 (V+state+axis+rej+rej2+CR+LF)", N_BYTES);
    end
```
（pos_probe 的合法值是 8。）
- **预期**：消除一处 K-91 违规 + 一处静默卡死路径；代价 = 0。
- **怎么验**：把 `.N_BYTES(16)` 传进去跑 tb ⇒ 当前会超时/红；加 `$fatal` 后立即在编译期/仿真期停住。
- **来源**：ANVIL-10【P3-1】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-2|MOD=rtl/w3c/pos_probe.v,rtl/w3c/span_probe.v,rtl/w3c/evt_uart_rx.v,rtl/w3c/uart_ui.v,rtl/top.v
### 给四个串口模块补参数自检与跨模块一致性检查
- **位置**：rtl/w3c/pos_probe.v（全文件无 initial）、rtl/w3c/span_probe.v（同）、rtl/w3c/evt_uart_rx.v（同）、rtl/w3c/uart_ui.v（也没有）；对照 rtl/w3c/uart_rx.v:179-205、:185-195、:28-36、rtl/w3c/uart_tx.v:234-243、rtl/top.v:843-850；rtl/w3c/evt_uart_rx.v:80-86
- **现状**：
```
pos_probe / span_probe / evt_uart_rx / uart_ui 全文件无 initial 自检；
对照 uart_rx.v:179-205（BIT_TOO_FEW + $fatal）、uart_tx.v:234-243（PARAM_OK）
evt_uart_rx.v:80-86 写着 "⚠️ 必须 > 1"（只有注释，没有断言）
```
- **为什么是问题**：本项目的既有惯例是"会静默失效的参数必须硬失败"（uart_rx.v:185-195 把 `$display` 升级成 `$fatal` 的理由写得很清楚）。evt_uart_rx 的 `GAP_BYTES`、uart_ui 的 `GAP_BYTES`、pos_probe/span_probe 的 `N_BYTES` —— 全都只有注释，没有断言。
- **改法**（照抄 uart_rx.v:181-205 的写法）：
```verilog
    initial begin
        if (GAP_BYTES < 2)
            $fatal(1, "ERROR [evt_uart_rx] GAP_BYTES=%0d < 2 => 帧内字节间隙会被误判成空闲", GAP_BYTES);
        if (BAUD == 0 || CLK_HZ / BAUD < 4)
            $fatal(1, "ERROR [evt_uart_rx] CLK_HZ/BAUD=%0d < 4 => 与 uart_rx.BAUD_DIV 不匹配", CLK_HZ/BAUD);
    end
```
再加一条跨模块一致性检查（这是本项目反复踩的坑：rtl/w3c/uart_rx.v:28-36、rtl/top.v:843-850 都在讲"四处一起改"）：uart_ui/evt_uart_rx 的 `BYTE_CLK_I` 必须等于 `uart_rx.BAUD_DIV`，可在 top.v 里加 `initial if (100 != (50000000 + 500000/2)/500000) $fatal(1, "BAUD 档位不一致");`。
- **预期**：收益 = 把"静默乱码"变成"构建期硬失败"；代价 = 0。
- **怎么验**：把 evt_uart_rx 的 `.GAP_BYTES(1)` 传进去跑 tb ⇒ 当前不报错（静默行为改变）；加断言后立即 `$fatal`。
- **来源**：ANVIL-10【P3-2】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-3|MOD=rtl/w3c/uart_ui.v
### 把 base_semi_o 的 8 位赋 7 位改成正好 7 位
- **位置**：rtl/w3c/uart_ui.v:258、:83；tb/w3c/tb_uart_ui.sv:216
- **现状**：
```verilog
                                          base_semi_o  <= {1'b0, val_q[7:1]}; // ⚠️ 简化：见 tb 约定
// 端口声明是 output reg [6:0] base_semi_o（rtl/w3c/uart_ui.v:83）
```
- **为什么是问题**：拼接结果是 8 位，赋给 7 位寄存器时最高位被静默丢弃。当前因为那一位恒为 `1'b0`，行为正确，但这是"靠巧合正确"：任何人把 `{1'b0, ...}` 改成 `{1'b1, ...}` 或把 `val_q` 加宽，就会静默丢位。
- **改法**：`base_semi_o <= val_q[7:1];   // ⭐ 7 位正好`
- **预期**：消掉一处"位宽不匹配但综合不报错"；代价 = 0。
- **怎么验**：`-Filter uart` 保持 `通过 8 / 共 8`（tb_uart_ui:216 断言 `base_semi === 7'd12`）。
- **来源**：ANVIL-10【P3-3】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-4|MOD=rtl/w3c/pos_probe.v,rtl/w3c/span_probe.v
### 给两份重复的 hex 字符转换加互指注释（建议不抽模块）
- **位置**：rtl/w3c/span_probe.v:109-115；rtl/w3c/pos_probe.v:192-193；rtl/w3c/uart_tx.v:9-11
- **现状**：
```verilog
// span_probe.v:109-115
    function [7:0] hexch;
        input [3:0] v;
        begin
            hexch = (v < 4'd10) ? (8'h30 + {4'd0, v})
                                : (8'h41 + ({4'd0, v} - 8'd10));
        end
    endfunction
// pos_probe.v:192-193（同一逻辑内联，只是没抽成函数）
            4'd1:    tx_byte_c = (ch_lat < 4'd10) ? (8'h30 + {4'd0, ch_lat})
                                                  : (8'h41 + ({4'd0, ch_lat} - 8'd10));
```
- **为什么是问题**：两个实例各一份 4 位→8 位 hex 译码（≈ 4 LUT/份）。收益很小（<10 LUT），价值在一致性：两处独立实现，将来改一处（比如改成小写 hex）会漂移。
- **改法**：在 pos_probe.v 里也定义一份同名 `hexch` 函数（Verilog-2001 没有跨模块函数共享，所以"消除重复"只能靠抽一个 rtl/w3c/hex_char.v 小模块，或者接受重复但加注释互指）。⚠️ 老实说：抽模块会多一个 .gprj 登记项（uart_tx.v:9-11 明确说过要"少一个文件、少一处登记机会"），所以建议不动，只在 pos_probe.v:192 加一行注释指向 span_probe.v:109 的同一逻辑。
- **预期**：一致性；代价 ≈ 0。
- **怎么验**：`-Filter pos_probe` / `-Filter span` 全绿。
- **来源**：ANVIL-10【P3-4】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-5|MOD=rtl/top.v,rtl/w3c/uart_tx.v
### 处理 uart_tx.tx_done_o 在顶层的悬空
- **位置**：rtl/top.v:1148；rtl/w3c/uart_tx.v:70、:125、:132、:214、:19；rtl/w3c/uart_tx_fifo.v:174-182
- **现状**：
```verilog
// rtl/top.v:1148
        .tx_done_o ()
// rtl/w3c/uart_tx.v:70  output reg tx_done_o —— 模块里认真维护（:125、:132、:214），top.v 直接丢弃
```
- **为什么是问题**：`uart_tx_fifo` 已经用 `busy_i` 的边沿（`busy_seen`，rtl/w3c/uart_tx_fifo.v:174-182）判断完成，确实不需要 `tx_done_o`。但悬空端口意味着：如果将来有人想让 FIFO 改用 `tx_done` 判完成（更直接、少一次 busy_seen 状态），会发现这条线在顶层被优化掉了、而且没有 tb 覆盖 `tx_done_o`。
- **改法**（二选一）：1. 从 uart_tx 删掉 `tx_done_o` 端口与 :125/:132/:214 三处（连同 :19、:70 的注释）。2. 保留但接上：`.tx_done_o(txf_done)` 并让它参与 uart_tx_fifo 的 `sending` 清零（可去掉 `busy_seen` 那个状态）。
- **预期**：方案 1 省 1 个 FF + 3 行；方案 2 简化 FIFO 的 sending 生命周期（少 1 个 FF、少 1 拍延迟）。代价 = 0。
- **怎么验**：`-Filter uart` 全绿（tb_uart_tx.sv 现在有覆盖 tx_done_o，删端口要同步改 tb）。
- **来源**：ANVIL-10【P3-5】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-6|MOD=rtl/top.v,rtl/w3c/uart_tx_fifo.v
### 给 rep_req 与探针 push 同拍的静默丢字节留痕或真互斥
- **位置**：rtl/top.v:2470-2476、:2452-2453、:2433；rtl/w3c/uart_tx_fifo.v:113-114；rtl/w3c/pos_probe.v:11
- **现状**：
```verilog
        assign tx_req  = rep_req | pp_push | vp_push | np_push
                       | ((DPOS_DIAG != 0) ? dp_push : 1'b0);
        //   ⭐ 'N'（`np_push`）优先级最高 —— 它也是独立命令，与其余不同拍。
        assign tx_byte = np_push ? np_data
                       : (((DPOS_DIAG != 0) && dp_push) ? dp_data
                       : (vp_push ? vp_data : (pp_push ? pp_data : rep_byte)));
// rtl/top.v:2452-2453
        //      📌 **为什么要 or 而不是 mux**：⭐ 两者【不会同拍】（⭐ `'P'` 是独立命令，
        //         ⚠️ 而 `rep_req` 由 `calib_span` 事件驱动）⇒ ⭐ 直接 or 更简单
// rtl/w3c/uart_tx_fifo.v:113-114
    wire take_now    = can_launch;              // ⭐ 本拍真的取走一个
    wire push_ok     = push_i & (~full);        // ⭐ 本拍真的推入一个
```
- **为什么是问题**：`tx_req` 是 OR，所以两个来源同拍只产生一次 `push_ok`；`tx_byte` 是优先 mux ⇒ 低优先级的那个字节消失。关键：`push_ok` 仍为 1 ⇒ 不进 `ovf_r`/`drop_r` ⇒ 这条丢字节连 `drop_cnt` 都记不到（即使 P2-5 修好也看不到）。同拍窗口有多大：探针在 S_SEND 里连续 push（`ready_i = ~full`，cnt 从 0 到 8，共 **8 拍**）⇒ 窗口 = **8 拍 = 160 ns**；`rep_req` 是单拍脉冲（rtl/top.v:2433 的 `ev_need = sp_need_press & ~sp_need_r` 是边沿检测）⇒ 命中概率 ≈ `160 ns / 两次回包间隔`。按"'S' 每 1 秒被拒一次"（rtl/w3c/pos_probe.v:11 的实测"每个 ! 正好隔 1 秒"）算：`p ≈ 160e-9 / 1 ≈ 1.6e-7` 每次探针。结论：概率极低，但机制真实、不可观测，且注释把"不会同拍"当成了保证（它只是一个未强制的时序假设）。
- **改法**（任选）：
```verilog
    // ① 被挤掉的那个也留痕（最省）
    wire rep_starved = rep_req & (pp_push | vp_push | np_push | dp_push);
    //    ... 给 rep_starved 一个饱和计数器
    // ② 真互斥：让单字节回包也等探针包发完（复用已有的 txf_idle）
    //    wire rep_go = rep_req & txf_idle;
    //    代价：'!'/'.' 等回包最多晚 160 µs（人眼无感）
```
- **预期**：收益 = 消掉一条"连计数器都记不到"的静默丢字节；代价 = 1 个 16 位饱和计数器（方案 ①）或 1 条 `&`（方案 ②，代价 160 µs 延迟）。
- **怎么验**：tb 里在探针 S_SEND 的某一拍同时给 `probe_req` 与一个 `rep_req`，断言"两个字节都出来" ⇒ 当前只出一个 ⇒ 红。
- **来源**：ANVIL-10【P3-6】
@@@END
@@@PRIO=P3|SRC=ANVIL-10|ORIG=P3-7|MOD=rtl/top.v
### 记档澄清：两个 probe 不会同拍抢 FIFO（避免白干）
- **位置**：rtl/top.v:2957-2971、:2459-2461、:2972-2993
- **现状**：
```
rtl/top.v:2957-2971 声称："① push_o/data_o 接到了死线上" / "② 两个 probe 会同拍抢 FIFO"
rtl/top.v:2459-2461："'Q' 与 'P' 故意错开 400 µs，⛔ 不同拍"
```
- **为什么是问题**（为什么不会发生）：每个探针在 S_SEND 里连续 8 拍推完 8 字节（`ready_i = ~full`），随后立刻回 S_DONE → S_IDLE ⇒ 探针占用"推入口"的总时长 = **8 拍 = 160 ns**。两个探针分别由不同的命令字节触发（`cmd_probe_req`/`cmd_posprobe_req`/`cmd_vstat_req`），而 500 kbaud 下两个字节至少相隔 20 µs = 1000 拍 ⇒ 两个 8 拍窗口在 1000 拍的命令间隔下不可能相交。唯一真正可能同拍的是 `rep_req`（单拍脉冲）落在探针的 8 拍窗口里 —— 见 P3-6（概率 ~1.6×10⁻⁷）。
- **改法**：不改。'Q' 的 400 µs 串行化（rtl/top.v:2972-2993）是冗余保险，保留无害；但不要把它当成"守着一个真实风险"而据此推出"已经解决了共享仲裁" —— 真正没解决的是 P3-6 和 P1-3。
- **预期**：避免为此白做一轮改动/PnR；代价 0。
- **怎么验**：无（本条是澄清，不是缺陷）。
- **来源**：ANVIL-10【P3-7】
@@@END
@@@TOTAL SRC=ANVIL-10 COUNT=23 P0=1 P1=6 P2=9 P3=7
