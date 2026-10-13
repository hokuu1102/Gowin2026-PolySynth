// ─────────────────────────────────────────────────────────────────────────────
// tb_perc_env_top.sv · ⭐ 「保留池 voice 走打击包络」在 `top.v` 里的行为契约
//                      （2026-09-28 新增 · ⭐ 修 `K-144`）
//
// 🔴 **为什么必须新增这个 tb**：
//    用户上板实测 —— *"开了节拍器之后会挂音"*。
//    根因：`perc_env_bank.v`（"一击到底、衰到 0 自动结束"的打击包络）
//    **全工程从未例化**（`K-144`）⇒ 节拍器走**普通 `adsr`** ⇒ 衰到 sustain
//    **停住不归零**，而 `metronome.v` 的 `EVT_KIND` 是常量 `note_on`、
//    ⛔ **永不发 `note_off`** ⇒ 🔴 **voice 永久 held = 挂音**。
//    修法：在 `top.v` 里把**保留池那 5 路**的包络电平换成 `perc_env_bank`
//    （⭐ 键盘那 27 路**逐位透传**）。
//    ⇒ ⭐ 本 tb 就是这条修法的**契约**：**"保留池必须一击到底"**。
//
// ⭐ **手法：用 `force` 直接驱动保留池第 0 路的 `nm_gate`/`nm_vel`**
//    · ⛔ 不等真实节拍（120 BPM ⇒ 每拍 0.5 s ⇒ 仿真 2500 万拍，太慢）
//    · ⭐ 且**力度强制成 1**（峰值 = `1<<8` = 256）⇒ `256/67 = 4` 个
//      `tick_audio` 就归零 ⇒ ⭐ **整个 tb 只要几千拍**（秒级）✅
//
// ⭐ **判据清单（逐条机械可判；⛔ 全部用 `===` ⇒ 见到 `x`/`z` 也算 FAIL）**
//    P1  键盘那 27 路 `env_level_mix[431:0] === env_level[431:0]`
//        （⭐ 逐位透传 ⇒ ⭐ 键盘音色/音量**零变化**）
//    P2  保留池第 0 路起音到峰值 **256**（`vel=1 ⇒ 1<<8`）
//    P3  ⭐⭐ **峰值之后必须衰到 0**（⭐ **这条就是"不挂音"的契约**）
//        ⚠️ **顺序不能反**：必须先证明"到过峰值"，再证明"回到 0" ——
//           ⛔ 否则电平**一直为 0** 也会让 P3 通过（⭐ 空洞判据）
//    P4  ⭐ 上升沿检测**恰好触发 1 次**（⛔ 不是电平触发 ⇒ 否则会每拍重装峰值）
//    P5  衰到 0 之后 `perc_active[0]` **落下**（⭐ `perc_env_bank` 的收尾状态机）
//
// ⭐⭐ **非空洞性（`C21`/`C83`）** —— 见文件末「变异记录」
//
// ⚠️ **判据名必须纯 ASCII**（`chk()` 走位向量→字符串通路）
// ⚠️ **语法纪律**：Verilog-2001，⛔ 不用 SV 专有构造（`K-91`）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_perc_env_top;

    localparam integer NAME_W   = 8*90;
    //  ⭐ 与 `top.v` 的 `RES_BASE = POLY_TARGET - PERC_N = 32 - 5 = 27` 同值
    localparam integer RES_BASE = 27;
    localparam integer VTEST    = 1;          // ⭐ 强制力度 1 ⇒ 峰值 256
    localparam integer PEAK      = VTEST << 8;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    integer errors = 0;
    integer trig_cnt = 0;

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
    // DUT：完整 `top`（⚠️ `met_btn_i` **故意不接** ⇒ `Z` ⇒ 顺便复验 Z-safe）
    // ═════════════════════════════════════════════════════════════════════════
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0] spi_cs_n;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .AUTOTARE_DELAY_CLK    (100_000),
        .SPAN_WAIT_TIMEOUT_CLK (50_000),
        .SPAN_STABLE_NEED      (4),
        .SPAN_VOTE_N           (4)
    ) u_top (
        .clk           (clk),
        .rst_n         (rst_n),
        .HP_BCK        (HP_BCK),
        .HP_WS         (HP_WS),
        .HP_DIN        (HP_DIN),
        .PA_EN_n       (PA_EN_n),
        .led_heartbeat (led_hb),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      ({4'b1111, miso_r, miso_l}),
        .spi_cs_n      (spi_cs_n),
        .uart_rx       (1'b1),
        .uart_tx       ()
    );

    assign spi_cs_n[5:2] = 4'b1111;

    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_l (
        .cs_n(spi_cs_n[0]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_l),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );
    mcp3208_model #(.IDVAL(12'h7C1)) u_adc_r (
        .cs_n(spi_cs_n[1]), .sclk(spi_sclk), .mosi(spi_mosi), .miso(miso_r),
        .ovr_en_i(1'b0), .ovr_val_i(12'h7C1)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // 层次化探针（⭐ 路径已核实：都在 `g_sound` 块内）
    //
    // 🔴🔴 **探针必须打在【契约点】，⛔ 不是中间信号**（⭐ 2026-09-28 实测踩到）：
    //    第一版我把探针打在 `env_level_mix` 上 ⇒ ⚠️ 非空洞性检查里
    //    "把混音器输入退回 `env_level`"这个变异 **P3 照样全绿**
    //    ⇒ ⭐ 因为 `env_level_mix` **仍然跟着打击包络走** ⇒ **判据测错了对象**。
    //    ✅ 修法：⭐ 直接读**混音器自己的输入端口** `u_tdm_render_mixer.env_level_i`
    //    📌 同族：`C83`（探针假绿）、`C36`（探针位置）、`L88`（采样点）
    // ═════════════════════════════════════════════════════════════════════════
    wire [15:0] lvl_res  = u_top.g_sound.u_tdm_render_mixer.env_level_i[RES_BASE*16 +: 16];
    wire [15:0] lvl_adsr = u_top.g_sound.env_level[RES_BASE*16 +: 16];      // ADSR（对照）
    wire        p_active = u_top.g_sound.perc_active[0];
    wire        p_trig   = u_top.g_sound.perc_trig[0];

    //  ⭐ 触发脉冲计数（⭐ P4 的"恰好一次"契约）
    always @(posedge clk) if (rst_n && p_trig) trig_cnt = trig_cnt + 1;

    //  ⭐ 有界轮询：等到 `lvl_res === target`，最多 `maxn` 拍
    //     ⚠️ 用**有界**循环 ⇒ ⛔ 不会挂死（⭐ 同 `K-94` 精神）
    task poll_level;
        input  [15:0] target;
        input  [31:0] maxn;
        output        ok;
        integer       n;
        begin
            ok = 1'b0;
            for (n = 0; n < maxn; n = n + 1) begin
                @(posedge clk);
                if (lvl_res === target) begin
                    ok = 1'b1;
                    n  = maxn;                 // ⭐ 提前退出
                end
            end
        end
    endtask

    integer ok_peak, ok_zero;

    initial begin
        $dumpfile("build/sim/tb_perc_env_top/tb_perc_env_top.vcd");
        $dumpvars(0, tb_perc_env_top);

        rst_n = 1'b0;
        repeat (200) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // ── P1：键盘那 27 路【逐位透传】──────────────────────────────────
        //    ⚠️ 同样读**混音器的输入口**（⭐ 契约点），⛔ 不读中间信号
        chk("P1 keyboard_27_slots_are_BIT_IDENTICAL_to_adsr",
            (u_top.g_sound.u_tdm_render_mixer.env_level_i[RES_BASE*16-1:0] ===
             u_top.g_sound.env_level                       [RES_BASE*16-1:0]));

        // ── 强制保留池第 0 路的"起音"（⭐ 模拟节拍器的一次 note_on）──────
        force u_top.g_sound.nm_vel [RES_BASE*8+7 : RES_BASE*8] = VTEST[7:0];
        force u_top.g_sound.nm_gate                           = 32'd0;
        repeat (5) @(posedge clk);
        //  ⚠️⚠️ **必须在拍【中间】强制，⛔ 不能在 `@(posedge clk)` 同一时刻**
        //     🔴 **已实测踩到（⭐ 这一条是本 tb 最难查的地方）**：
        //        若 `force` 与 posedge 同刻 ⇒ ⭐ `nm_gate_d` 的采样与
        //        `perc_env_bank` 对 `trigger_i` 的采样**在同一时间步抢 delta**
        //        ⇒ ⭐ 那个**只有 1 拍的 `perc_trig` 脉冲谁都看不见** ⇒ **永不触发**。
        //     🔎 **现场特征（⭐ 一眼认出来）**：`gate` 与 `gate_d` **永远显示同拍**
        //        ⇒ 看起来"上升沿检测根本不存在"，⚠️ 极易误判成 RTL 写错。
        //     ✅ **修法**：`@(posedge clk)` 之后 `#5`（拍中间）再 `force`。
        #5;
        force u_top.g_sound.nm_gate                           = (32'd1 << RES_BASE);

        // ── P2：先到峰值（⛔ 顺序不能反，否则 P3 会空洞）────────────────
        poll_level(PEAK[15:0], 32'd40, ok_peak);
        chk("P2 perc_slot_attacks_to_PEAK_256 (vel=1 => 1<<8)", ok_peak == 1);

        // ── P3：⭐⭐ 峰值之后【必须衰到 0】（"不挂音"的核心契约）──────────
        //    ⭐ 预算 20000 拍：`256/67 = 4` 个 tick（每 tick 1024 拍）≈ 4096 拍
        //    🔴 若保留池仍走 ADSR ⇒ 会停在 sustain(64) ⇒ **永远到不了 0** ⇒ 本判据 FAIL
        poll_level(16'd0, 32'd20000, ok_zero);
        chk("P3 perc_slot_decays_to_ZERO_after_peak (K-144 no-hang contract)",
            (ok_peak == 1) && (ok_zero == 1));

        // ── P4：上升沿检测【恰好触发一次】（⛔ 不是电平触发）────────────
        chk("P4 edge_detect_fired_EXACTLY_ONCE (not level-triggered)", trig_cnt == 1);

        // ── P5：衰到 0 后 `perc_active` 落下（收尾状态机）────────────────
        chk("P5 perc_active_drops_after_decay", p_active === 1'b0);

        // ── 撤销 force ──────────────────────────────────────────────────
        release u_top.g_sound.nm_gate[RES_BASE];
        release u_top.g_sound.nm_vel [RES_BASE*8+7 : RES_BASE*8];

        if (errors == 0)
            $display("PASS: perc_env_top -- reserved pool is one-shot percussive (K-144 fixed)");
        else
            $fatal(1, "FAIL: perc_env_top has %0d error(s)", errors);

        #200;
        $finish;
    end

endmodule

// ─────────────────────────────────────────────────────────────────────────────
// 变异记录（⭐ 非空洞性：`C21`/`C83` —— 判据必须【能红】）
//
//   ⭐ 工具：`sim/check_met_btn_nonempty.ps1`（⭐ 同一套"**变异副本**"机制：
//      ⛔ 不碰 `rtl/`，⭐ 在 `build/_mut_metbtn/<id>/` 下生成 `top.v` 的副本再编译）
//
//   | 变异 | 改什么 | ⭐ **实测**变红的判据 |
//   |---|---|---|
//   | **MUT5** | `.env_level_i (env_level_mix)` ⇒ `.env_level_i (env_level)` | ✅ **P3** |
//     ⭐ 即"**退回 K-144 的旧行为**"（保留池走 ADSR）⇒ ⭐ 峰值之后停在 sustain(64)
//        ⇒ **永远到不了 0** ⇒ **P3 必红** ✅ 这正是本 tb 存在的意义。
//
//   ⚠️ **P1 的空洞性防线**：⭐ P1 是"27 路逐位相等" ⇒ ⚠️ 若**整条 `env_level_mix`
//      都接 `env_level`**，P1 **照样通过**（⭐ 两边一模一样）
//      ⇒ ⭐ **所以 P1 ⛔ 不能单独作为"透传正确"的证据** —— 必须与 P3 一起看。
//      📌 **教训**：⭐ "相等"类判据**天生对"两边都错成一样"免疫**。
// ─────────────────────────────────────────────────────────────────────────────
