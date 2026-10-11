// ═════════════════════════════════════════════════════════════════════════════
//  tb_pos_probe_axis.sv · ⭐ `'P'` 诊断探针【按轴轮转】+【片 1 可观测】契约
//                          （⭐ 2026-10-01 新增）
//
//  🔴 **为什么必须新增这个 tb**（⭐ 给刚做的修复补"能红"的判据）
//
//    · 缺陷（⭐ `top.v` 改之前）：`'P'` 探针的 `.pos_i` **只接了 `af0_pol`（片 0）**
//      ⇒ 🔴 `'P'` **永远只回片 0 的原始码** ⇒ ⭐ **诊断板 2 时会给出【错误答案】**
//        （⚠️ 比"看不到"更危险 —— 会让人以为板 2 的轴是好的 ✅）
//
//    · 修法（⭐ 已改好，⭐ 见 `top.v:1749-1777`）：
//        `reg [3:0] pp_axis_r;` ⭐ 每次 `cmd_probe_req` **+1**
//        `wire [11:0] pp_raw_sel = pp_axis_r[3] ? af1_pol : af0_pol;`
//        `.pos_i(pp_raw_sel)` ＋ `.ch_i({1'b0, pp_axis_r[2:0]})`（⭐ 与 `pos_i` 同源）
//      ⇒ ⭐ 第 k 次（0 基）`'P'` 的真实语义（⭐ 逐字读代码得出）：
//          · **片** = (k >= 8) ? 1 : 0        （⭐ `pp_raw_sel` 用 `pp_axis_r[3]` 选片）
//          · **回包 CH 字符** = `k % 8`        （⭐ `ch_i` 只取 `pp_axis_r[2:0]`
//             ⇒ ⚠️ 轴 8 回包里的 CH 也是 `'0'` —— ⭐ 所以【CH 字段⛔ 不能唯一标识轴】，
//                必须靠"第几次请求"来定位 ⚠️）
//          · **pos** = 该片极性校正后的原始码（⭐ `af0_pol` / `af1_pol`）
//
//  ⭐⭐ 判据（⭐ 全部必须能红 —— `K-56` / `C21` / `C83`）
//    a ⭐ **轴轮转**：连发 16 次 ⇒ 回包 CH 字段依次 `0,1,…,7,0,1,…,7`
//       （⭐ 且每包仍是 `'P' + CH + 4 位数字 + CR + LF` = 8 字节）
//    b ⭐⭐ **片 1 可观测（⭐ 核心判据）**：第 9 次（⭐ 轴 8）回的 `pos`
//       必须**来自片 1**（⭐ 本 tb 让两片的码差得很远：`256` vs `2048`）
//    c ⭐ **同源性**：16 次里**每一次**的 `pos` 都等于**该次所选那片**的原始码
//       （⭐ 即 `ch_i` 与 `pos_i` 指向同一个轴 ⇒ ⛔ 不会"通道说 0、位置却是别的"）
//    d ⭐ **复位**：复位后 `pp_axis_r == 0` ⇒ ⭐ 第一次 `'P'` 回轴 0（片 0 通道 0）
//
//  🔴🔴 **"能红"论证（⭐ 这是本 tb 存在的唯一理由）**
//
//    ⭐ 把 `top.v` 的 `.pos_i(pp_raw_sel)` **改回 `.pos_i(af0_pol)`**
//       （⚠️ 只退回这一根线、**保留** `pp_axis_r`）⇒
//         · a → ⭐ **仍绿**（CH 字段仍来自 `pp_axis_r`，轮转没变 ✅）
//         · b → 🔴 **必红**（第 9 次会回片 0 的 `0256`，而期望是 `2048`）
//         · c → 🔴 **必红**（第 9~16 次的 `pos` 全变成片 0 的值）
//         · d → ⭐ **仍绿**（第一次本来就是轴 0 ⇒ 片 0）
//       ⇒ ⭐ **b/c 就是"修复前后行为不同"的那两条** ✅
//
//    ⭐ 若把整个修法退回（**连 `pp_axis_r` 一起删掉**）⇒
//       🔴 **本 tb 编译失败**（⭐ 引用了 `u_top.g_sound.pp_axis_r`）
//       ⇒ ⭐ 回归判"编译失败" = 红 ✅
//       ⚠️ 但**编译红 ⛔ 不能替代 b/c 的断言红** —— ⚠️ 两者都要记在案。
//
//    ⭐⭐ **实测记录（⭐ 2026-10-01，⭐ 不碰 `rtl/`：⭐ 在本 tb 里
//       `force u_top.g_sound.pp_raw_sel = u_top.g_sound.af0_pol;`
//       ⇒ ⭐ 与"把 `.pos_i` 改回 `af0_pol`"**逐位等价**）**：
//       ```
//       FAIL: b1 request 9 pos field == 2048 (chip1 code), NOT 256 (chip0 code)
//       FAIL: b2 request 9 is NOT the chip0 code 0256 (the pre-fix wrong answer)
//       FAIL: c1 all 16 replies: ch == axis%8 AND pos == the selected chip's code
//       FAIL: c req 8..15 expected pos=2048 (chip 1) but the reply bytes are wrong
//       ok  : a1 ... CH = 0,1,..,7,0,1,..,7      <- ⭐ 仍绿（⭐ 与预测一致）
//       ok  : d1..d8                              <- ⭐ 仍绿（⭐ 与预测一致）
//       FAIL: tb_pos_probe_axis had 11 error(s)   (通过 0 / 共 1)
//       ```
//       ⇒ ⭐ **判据确实能红**（⭐ `C83` / `C21`）✅ —— 移除该 `force` 后恢复全绿 ✅
//
//    ⭐ **非空洞性前置（⭐ P0 三条）**：⭐ 片 0 与片 1 的原始码**必须不同**
//       （⚠️ 否则"回的是哪片"**根本不可分辨** ⇒ 判据会假绿 —— 见 `C83`）
//
//  ⚠️⚠️ **为什么要 `force af_data` 而⛔ 不用 ADC 模型的"逐片覆盖"**
//
//    ⭐ 本 tb 一开始用 `mcp3208_model` 的 `ovr_en_i/ovr_val_i` 给两片不同的码
//       （⭐ 片 0 = `0xEFF`、片 1 = `0x7FF`）—— ⚠️ **结果片 1 读出来恒为 0**。
//    🔎 **实测定位（⭐ 这不是 tb 的问题，⭐ 是 `adc_farm` 的【真实不对称】）**：
//       · ⭐ 片 0 走 `mcp3208_scanner.sample_data` —— ⭐ 是**寄存器、会保持** ✅
//       · ⭐ 片 1..N-1 走 `adc_farm` 的**影子反串行器** `miso_shift[g]`：
//           `assign sample_data_packed[g*12 +: 12] = miso_shift[g][11:0];`
//         ⚠️ 而 `miso_shift[g]` **每次 `cs_fall` 都被清零**
//           （⭐ `adc_farm.sv:142-145`）⇒ 🔴 **它只在"最后一次 SCLK 上升沿
//           → 下一次 `cs_fall`"这 ~1 µs 内保持正确值**
//           （⭐ 一个通道事务 24.5 µs、一帧 500 µs ⇒ 有效占空比 ≈ **0.2%**）
//       · 📌 **实测证据**（⭐ 本 tb 的探针打印）：
//           `af_sample_valid` 那一拍：`af_data=7ffeff  shift1=0007ff  cs1=1` ✅
//           仅 4 拍之后（同一通道）：`af_data=000eff  shift1=000000  cs1=0` 🔴
//       ⇒ 🔴🔴 **结论：`af1_pol` 不是一个"保持"的信号** ——
//          ⭐ 所以**即使 `.pos_i` 改成了按片选**，⭐ 上板发 `'P'` 时
//          （⭐ 请求时刻与 `sample_valid` **无关**）第 9 次仍会**大概率**回
//          `P04095`（⭐ = `0xFFF - 0`），⛔ 而不是片 1 的真实码。
//          ⚠️ **本次修复是【必要】的，⚠️ 但【不充分】** —— 已单独报告（见交付说明）。
//    ✅ **本 tb 的处置**：⭐ **直接 `force u_top.g_sound.af_data`** 把两片的码
//       钉成常量 ⇒ ⭐ `af0_pol`/`af1_pol` 变成**稳定**信号 ⇒
//       ⭐ 被测对象（⭐ `top.v` 的**选片逻辑**）**可被干净地判定** ✅
//       📌 依据：⭐ 本 tb 的被测对象是 `top.v` 的选片/选轴接线，
//          ⛔ **不是 `adc_farm` 的采样时序**（⭐ 那个另案）。
//
//  ⚠️ **其它手法说明**
//    · ⭐ `'P'` 是串口命令，⭐ 这里按任务书允许的简化做法：⭐ **force `cmd_probe_req`**
//      （⭐ 它就是 `calib_cmd.probe_req_o` 那根线 ⇒ ⭐ 与真命令**同一条路**）✅
//    · ⭐ 把 `txf_idle`/`txf_ready` **force 成常 1**：⭐ `pos_probe` 自己的
//      `ready_i`/`idle_i` 握手语义**已由 `tb_pos_probe.sv` 覆盖** ⇒
//      ⭐ 这里去掉"等 8 字节 160 µs 串口发完"这个无关依赖 ⇒
//      ⭐ 仿真时间从 ~3.2 ms 降到 **~10 µs**（⚠️ 默认 120 s 预算内绰绰有余）✅
//    · ⚠️ `force` 一律**离开时钟沿**（`U74`）：本 tb 在 `negedge` 拉、`negedge` 放
//
//  ⚠️ **判据名纯 ASCII、`$display` 纯 ASCII**（⭐ 本机 `vvp` 会把非 ASCII 打乱）
//  ⚠️ **Verilog-2001 风格**（`K-91`）：声明先于使用、⛔ 不用 `logic`
// ═════════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_pos_probe_axis;

    localparam integer NAME_W = 8*110;

    // ── ⭐ 两片的码值（⭐ 用 `top.axis_polarity()` 的真实公式对齐）────────────
    //   `INVERT_AXIS = 1` ⇒ `pol = 12'hFFF - raw`
    localparam [11:0] RAW0 = 12'hEFF;   // ⭐ 片 0 的 ADC 原始码
    localparam [11:0] RAW1 = 12'h7FF;   // ⭐ 片 1 的 ADC 原始码
    localparam [11:0] POL0 = 12'h100;   // ⭐ 0xFFF - 0xEFF = 256  ⇒ 回包 "0256"
    localparam [11:0] POL1 = 12'h800;   // ⭐ 0xFFF - 0x7FF = 2048 ⇒ 回包 "2048"

    localparam integer NPKT   = 16;     // ⭐ 判据 a/b/c 的包数
    localparam integer NEXTRA = 3;      // ⭐ 判据 d 之前把 `pp_axis_r` 推到 3

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;              // ⭐ 50 MHz

    integer errors = 0;

    task chk;
        input [NAME_W-1:0] name;
        input              cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // DUT（⭐ 端口**接全** —— ⚠️ 悬空 ⇒ `z` ⇒ 判据假红）
    // ═════════════════════════════════════════════════════════════════════════
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;
    wire led_sdi, led_clk, led_le, uart_tx;
    wire [4:0] led_oe_n;
    wire spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0] spi_cs_n;

    top #(
        //  ⭐⭐ 纪律（⭐ `top.v:108-120`）：⭐ **凡"验某一路"的 tb 必须显式声明自己
        //     需要的档**，⛔ 不依赖顶层默认值（⭐ 默认值一改，tb 就测了别的东西）。
        //  · `DEMO_CHORD_ON=1` ⇒ ⭐ 走 `g_sound` 分支（⚠️ `0` 走 `g_silent`，
        //    那个分支里 `pp_push` 恒 0 ⇒ 🔴 本 tb **什么都收不到**）
        //  · `SEL_DRUM=0` ⇒ ⭐ 源 B = 节拍器（⭐ 默认关闭 ⇒ 串口安静，⛔ 不干扰）
        .DEMO_CHORD_ON         (1),
        .SEL_DRUM              (0),
        .AUTOTARE_DELAY_CLK    (100_000),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .timbre_btn_i  (1'b1),          // ⭐ 未按下（低有效）
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .I2S2_BCK      (I2S2_BCK),
        .I2S2_LRCK     (I2S2_LRCK),
        .I2S2_DIN      (I2S2_DIN),
        .pluck_up_i    (1'b0),
        .pluck_down_i  (1'b0),
        .led_heartbeat (led_hb),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        .led_sdi       (led_sdi),
        .led_clk       (led_clk),
        .led_le        (led_le),
        .led_oe_n      (led_oe_n),
        .uart_rx       (1'b1),          // ⭐ 空闲高
        .uart_tx       (uart_tx)
    );
    //  ⚠️ `spi_cs_n[5:2]` **由 `top.v` 自己驱动**（`:1404`）
    //     ⇒ ⛔ 这里**不能再 `assign`**（⭐ 会变成双驱动）

    // ═════════════════════════════════════════════════════════════════════════
    // MCP3208 模型：⭐ 保留例化只为**驱动 `spi_miso`**（⭐ 避免悬空 ⇒ X）
    //   ⚠️ 它的数据**不影响判据** —— `af_data` 已被 `force` 覆盖（⭐ 见文件头）
    // ═════════════════════════════════════════════════════════════════════════
    mcp3208_model #(.IDVAL(RAW0)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(1'b0), .ovr_val_i(RAW0),
        .ch_mask_i(8'h00), .ch_val_i(12'h000)
    );
    mcp3208_model #(.IDVAL(RAW1)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(1'b0), .ovr_val_i(RAW1),
        .ch_mask_i(8'h00), .ch_val_i(12'h000)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // 探针（⭐ 全部层次引用 —— ⛔ 不改任何 RTL）
    // ═════════════════════════════════════════════════════════════════════════
    wire        pp_push = u_top.g_sound.u_pos_probe.push_o;
    wire [7:0]  pp_data = u_top.g_sound.u_pos_probe.data_o;
    wire [3:0]  pp_axis = u_top.g_sound.pp_axis_r;      // ⭐ 被测的"探针轴"
    wire [11:0] af0_pol = u_top.g_sound.af0_pol;        // ⭐ 片 0（极性校正后）
    wire [11:0] af1_pol = u_top.g_sound.af1_pol;        // ⭐ 片 1（极性校正后）

    // ── ⭐ 收 `'P'` 探针推出来的字节 ──────────────────────────────────────────
    reg [7:0] got [0:255];
    integer   n_got = 0;
    always @(posedge clk) begin
        if (pp_push === 1'b1) begin
            got[n_got] = pp_data;
            n_got      = n_got + 1;
        end
    end

    // ═════════════════════════════════════════════════════════════════════════
    // 任务
    // ═════════════════════════════════════════════════════════════════════════

    // ⭐ 发一次 `'P'`：⭐ 等探针回到 `S_IDLE` ⇒ ⭐ 离开时钟沿 force ⇒ 一个 posedge
    integer fw_k;
    task fire;
        begin
            fw_k = 0;
            while ((u_top.g_sound.u_pos_probe.state !== 3'd0) && (fw_k < 200)) begin
                @(posedge clk); fw_k = fw_k + 1;
            end
            @(negedge clk);
            force u_top.cmd_probe_req = 1'b1;
            @(negedge clk);
            release u_top.cmd_probe_req;
        end
    endtask

    integer wb_k;
    task wait_bytes;
        input integer want;
        input integer maxc;
        begin
            wb_k = 0;
            while ((n_got < want) && (wb_k < maxc)) begin
                @(posedge clk); wb_k = wb_k + 1;
            end
        end
    endtask

    // ⭐ 整包校验：⭐ `'P' + CH + 4 位十进制 + CR + LF`，且
    //    ⭐⭐ **2026-10-09（`P1-80`）修正**：⭐ `CH` = **轴号的十六进制一位（0~F）** ✅
    //      🔴 **原判据写的是 `CH == k % 8`** —— ⚠️ 那**正是缺陷本身** ✅
    //         （⭐ `ch_i = {1'b0, pp_axis_r[2:0]}` ⇒ ⭐ 片 1 的读数被读成片 0 的某个轴 ✅）
    //      ✅ **修后**：⭐ `ch_i = pp_axis_r`（4 位直传：⭐ bit3 = 片号 ✅）
    //         ⇒ ⭐ CH = `k` 的十六进制一位 ⇒ ⭐ 轴 7 ⇒ `'7'` · ⭐ 轴 15 ⇒ `'F'` ✅
    //      📌 ⭐ **本判据在【未修复】代码上必红**（⭐ 它给的是 `k%8` ✅）
    //         ⇒ ⭐ 这正是铁律① 要的"未修复能红" ✅
    integer e3, e2, e1, e0, exp_pos, bad, base, exp_ch;
    task chk_pkt;
        input integer k;
        begin
            base    = k * 8;
            exp_pos = (k >= 8) ? POL1 : POL0;
            //  ⭐ 期望的 CH 字符：⭐ 0~9 ⇒ '0'~'9' · ⭐ 10~15 ⇒ 'A'~'F' ✅
            exp_ch  = (k < 10) ? (8'h30 + k) : (8'h41 + (k - 10));
            e3 = exp_pos / 1000;
            e2 = (exp_pos % 1000) / 100;
            e1 = (exp_pos % 100) / 10;
            e0 = exp_pos % 10;
            bad = 0;
            if (got[base+0] !== 8'h50) bad = bad + 1;                  // 'P'
            if (got[base+1] !== exp_ch) bad = bad + 1;                 // ⭐ CH（P1-80 修后）
            if (got[base+2] !== (8'h30 + e3)) bad = bad + 1;
            if (got[base+3] !== (8'h30 + e2)) bad = bad + 1;
            if (got[base+4] !== (8'h30 + e1)) bad = bad + 1;
            if (got[base+5] !== (8'h30 + e0)) bad = bad + 1;
            if (got[base+6] !== 8'h0D) bad = bad + 1;
            if (got[base+7] !== 8'h0A) bad = bad + 1;
            $display("    req %0d: axis=%0d chip=%0d expect pos=%0d expect ch=%c -> got %c%c%c%c%c%c%c%c",
                     k, k, (k >= 8), exp_pos, exp_ch,
                     got[base+0], got[base+1], got[base+2], got[base+3],
                     got[base+4], got[base+5], got[base+6], got[base+7]);
            if (bad == 0) begin
                $display("  ok  : c req %0d pos comes from chip %0d", k, (k >= 8));
            end else begin
                $display("  FAIL: c req %0d expected ch=%c pos=%0d (chip %0d) but the reply bytes are wrong",
                         k, exp_ch, exp_pos, (k >= 8));
                errors = errors + 1;
            end
        end
    endtask

    integer k, nbad, expd, d3, d2, d1, d0;
    integer ch_seq_bad;

    initial begin
        $display("=== tb_pos_probe_axis ===");

        // ── 复位 ────────────────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (200) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // ═══ ⭐⭐ 造"两片码值明显不同"的现场 ═════════════════════════════════
        //   ⭐ `af_data` 是 packed（片 i = [i*12 +: 12]）⇒
        //      `af_data[11:0]` = 片 0 原始码、`af_data[23:12]` = 片 1 原始码
        //   ⚠️ 为什么直接 force 而不用 ADC 的逐片覆盖：见文件头（⭐ `miso_shift`
        //      每次 `cs_fall` 被清零 ⇒ `af1_pol` 只在 ~1 µs 窗口内有效）
        force u_top.g_sound.af_data = {RAW1, RAW0};
        // ⭐ 去掉"等串口把 8 字节发完"这个与被测对象无关的依赖（⭐ 见文件头）
        force u_top.txf_idle  = 1'b1;
        force u_top.txf_ready = 1'b1;
        repeat (4) @(posedge clk);

        // ═══ P0：⭐ 非空洞性前置 —— ⭐ 两片的码必须不同 ═══
        $display("== P0: non-vacuous precondition ==");
        chk("P0 af0_pol == 256 (chip0 raw 0xEFF inverted)", af0_pol === POL0);
        chk("P0 af1_pol == 2048 (chip1 raw 0x7FF inverted)", af1_pol === POL1);
        chk("P0 the two chips carry DIFFERENT codes (else b/c are vacuous)",
            af0_pol !== af1_pol);
        chk("P0 pp_axis_r == 0 right after reset", pp_axis === 4'd0);

        // ═══ d：⭐ 复位后第一次 `'P'` 回轴 0（片 0 通道 0）════════════════
        $display("== d: first 'P' after reset -> axis 0 ==");
        n_got = 0;
        fire();
        wait_bytes(8, 4000);
        chk("d1 first 'P' after reset pushed exactly 8 bytes", n_got === 8);
        chk("d2 first 'P' after reset: ch='0' and pos=0256 (chip 0 code)",
            (got[0] === 8'h50) && (got[1] === 8'h30) &&
            (got[2] === 8'h30) && (got[3] === 8'h32) &&
            (got[4] === 8'h35) && (got[5] === 8'h36) &&
            (got[6] === 8'h0D) && (got[7] === 8'h0A));
        chk("d3 pp_axis_r advanced to 1 after one request", pp_axis === 4'd1);

        // ═══ a/b/c：⭐ 连发到 16 次 ══════════════════════════════════════════
        $display("== a/b/c: 16 requests cover both chips ==");
        for (k = 1; k < NPKT; k = k + 1) begin
            fire();
            wait_bytes((k + 1) * 8, 4000);
        end
        chk("a0 16 requests produced 8 bytes each (128 total)", n_got === (NPKT * 8));
        chk("a0b pp_axis_r wrapped back to 0 after 16 requests", pp_axis === 4'd0);

        // ── a：⭐ 帧结构 + CH 序列 0..7,0..7 ────────────────────────────────
        ch_seq_bad = 0;
        for (k = 0; k < NPKT; k = k + 1) begin
            if (got[k*8+0] !== 8'h50)             ch_seq_bad = ch_seq_bad + 1;
            if (got[k*8+1] !== ((k < 10) ? (8'h30 + k) : (8'h41 + (k - 10)))) ch_seq_bad = ch_seq_bad + 1;
            if (got[k*8+6] !== 8'h0D)             ch_seq_bad = ch_seq_bad + 1;
            if (got[k*8+7] !== 8'h0A)             ch_seq_bad = ch_seq_bad + 1;
        end
        chk("a1 16 replies are 'P'+CH+4digits+CRLF with CH = 0..F (P1-80 修后)",
            ch_seq_bad === 0);

        // ── b：⭐⭐ 第 9 次（轴 8）必须来自【片 1】────────────────────────────
        //   🔴 修前（`.pos_i(af0_pol)`）这里回的是 `0256`（片 0）⇒ **必红**
        $display("== b: request 9 (axis 8) must come from chip 1 ==");
        chk("b1 request 9 pos field == 2048 (chip1 code), NOT 256 (chip0 code)",
            (got[8*8+2] === 8'h32) && (got[8*8+3] === 8'h30) &&
            (got[8*8+4] === 8'h34) && (got[8*8+5] === 8'h38));
        chk("b2 request 9 is NOT the chip0 code 0256 (the pre-fix wrong answer)",
            !((got[8*8+2] === 8'h30) && (got[8*8+3] === 8'h32) &&
              (got[8*8+4] === 8'h35) && (got[8*8+5] === 8'h36)));
        chk("b3 request 1 came from chip 0 (pos == 0256, non-vacuous)",
            (got[2] === 8'h30) && (got[3] === 8'h32) &&
            (got[4] === 8'h35) && (got[5] === 8'h36));

        // ── c：⭐ 同源性 —— 每一次的 pos 都等于"该次所选那片"的原始码 ────────
        $display("== c: every reply's pos == the raw code of the chip it selected ==");
        nbad = 0;
        for (k = 0; k < NPKT; k = k + 1) begin
            expd = (k >= 8) ? POL1 : POL0;
            d3 = expd / 1000;
            d2 = (expd % 1000) / 100;
            d1 = (expd % 100) / 10;
            d0 = expd % 10;
            if (got[k*8+1] !== ((k < 10) ? (8'h30 + k) : (8'h41 + (k - 10)))) nbad = nbad + 1;
            if (got[k*8+2] !== (8'h30 + d3))      nbad = nbad + 1;
            if (got[k*8+3] !== (8'h30 + d2))      nbad = nbad + 1;
            if (got[k*8+4] !== (8'h30 + d1))      nbad = nbad + 1;
            if (got[k*8+5] !== (8'h30 + d0))      nbad = nbad + 1;
        end
        chk("c1 all 16 replies: ch == axis (hex 0..F) AND pos == the selected chip's code",
            nbad === 0);
        //   ⭐ 逐包明细（⭐ 失败时能一眼看出是哪一包）
        for (k = 0; k < NPKT; k = k + 1) chk_pkt(k);

        // ═══ d（后半）：⭐ 把 `pp_axis_r` 推到 3，再复位 ⇒ 必须归 0 ═══════════
        $display("== d: reset clears the rotation ==");
        for (k = NPKT; k < (NPKT + NEXTRA); k = k + 1) begin
            fire();
            wait_bytes((k + 1) * 8, 4000);
        end
        chk("d4 after 19 requests pp_axis_r == 3 (non-zero, so d5/d6 are not vacuous)",
            pp_axis === 4'd3);

        rst_n = 1'b0;
        repeat (200) @(posedge clk);
        chk("d5 pp_axis_r == 0 while reset is asserted", pp_axis === 4'd0);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);
        chk("d6 pp_axis_r == 0 after reset release", pp_axis === 4'd0);
        //   ⭐ `force` 不随复位失效 ⇒ ⭐ 刺激仍在（⭐ 这一条同时证明"复位没打乱现场"）
        chk("d7 af0_pol is still 256 after the reset", af0_pol === POL0);

        n_got = 0;
        fire();
        wait_bytes(8, 4000);
        chk("d8 first 'P' after the 2nd reset returns axis 0 / chip 0 code 0256",
            (n_got === 8) && (got[0] === 8'h50) && (got[1] === 8'h30) &&
            (got[2] === 8'h30) && (got[3] === 8'h32) &&
            (got[4] === 8'h35) && (got[5] === 8'h36) &&
            (got[6] === 8'h0D) && (got[7] === 8'h0A));

        // ═══ A8：⭐ 无 X/Z ═══════════════════════════════════════════════════
        $display("== A8: no X/Z ==");
        chk("A8 pp_data has no X/Z", ^pp_data !== 1'bx);
        chk("A8 pp_axis_r has no X/Z", ^pp_axis !== 1'bx);
        chk("A8 af0_pol/af1_pol have no X/Z", (^af0_pol !== 1'bx) && (^af1_pol !== 1'bx));

        release u_top.g_sound.af_data;
        release u_top.txf_idle;
        release u_top.txf_ready;

        $display("");
        if (errors == 0)
            $display("PASS: pos_probe_axis -- 'P' rotates over 16 axes and reports the raw code of the chip selected by axis[3] (chip 1 observable)");
        else begin
            $display("FAIL: tb_pos_probe_axis had %0d error(s)", errors);
            $fatal(1, "FAIL: tb_pos_probe_axis");
        end
        #200;
        $finish;
    end

    // ⭐ 兜底超时（`K-94`）
    initial begin
        #2_000_000;
        $display("FAIL: tb_pos_probe_axis timeout (no verdict)");
        $fatal(1, "FAIL: timeout");
    end

endmodule
