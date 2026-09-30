// ─────────────────────────────────────────────────────────────────────────────
// tb_met_start_top.sv · ⭐ 「节拍器从【第一拍/强拍】开始」+「每拍都真的起音」契约
//                       （2026-09-28 新增）
//
// 🔴 **为什么必须新增这个 tb**（⭐ 两条都是用户上板实测反馈）
//
//   ① ⭐ 用户原话：*"节拍器是从第二拍开始响的，希望最好从第一拍开始响"*
//      🔎 根因：`beat_gen` 是 **free-running**（`run_i = 1'b1`）
//         ⇒ ⭐ 按 S2 时 `tick_cnt_q` 可能停在 1/2/3
//         ⇒ ⭐ 下一个 tick **⛔ 不是 `bar_start`** ⇒ **第一声是弱拍**。
//      ✅ 修法：`met_on_r` **上升沿**给 `beat_gen.pos_reset_i` 发 **1 拍脉冲**
//         ⇒ ⭐ 相位 + `tick_cnt_q` 归零 ⇒ 下一个 tick 的 `tick_cnt_q == 0`
//         ⇒ `bar_start_o = 1` ⇒ ⭐ **第一声就是强拍**。
//
//   ② ⭐ 用户原话：*"就算不按按键，节拍器的声音也不太均衡，有时候会变弱"*
//      ⭐ 本 tb 用一条**可失败**的判据把它钉住：
//         **每一个节拍器事件都必须【真的触发一次】`perc_env_bank`**
//         ⇒ ⚠️ 若某一拍没触发 ⇒ 🔴 那一拍就"变弱/没了"。
//
// ⭐ **手法（⭐ 全部离线、秒级）**
//    · ⛔ **不等真实节拍**（120 BPM ⇒ 每拍 2500 万拍，太慢）
//    · ⭐ **`force` 直接驱动 `bg_beat`/`bg_bar_start`** 来"造拍"
//    · ⭐ **`force` `met_on_r`** 来跳过按键（按键本身由 `tb_met_btn_top` 验）
//    · ⭐ **`force` `phase_q` 到进位附近** 让下一个 tick 立刻到来
//
// ⚠️⚠️ **`force` 必须离开时钟沿**（⭐ `U74` 的教训）：
//    与 `@(posedge clk)` 同刻会被 **delta 竞争**吃掉 ⇒ 1 拍脉冲谁都看不见。
//    ⇒ 本 tb 一律 `@(posedge clk); #5; force ...`
//
// ⚠️ **判据名必须纯 ASCII**；**Verilog-2001**（`K-91`）
// ⚠️ **非空洞性**：见文件末「变异记录」（MUT6 = 退回 `pos_reset_i(1'b0)`）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_met_start_top;

    localparam integer NAME_W  = 8*90;
    //  ⭐⭐ 2026-09-30：⭐ `120/72` ⇒ **`180/108`**（⭐ 用户："节拍器的声音有一点太小了"）
    //     ⚠️ **必须与 `rtl/w3c/metronome.v` 的 `VEL_ACCENT`/`VEL_NORMAL` 逐字一致** ——
    //        ⭐ 本 tb 判的就是"**回放出来的力度 = 那两个参数**"（⭐ 模式判据 T5）✅
    //     📌 比例仍是 **5:3**（⭐ 强拍更响），⭐ 所以判据的**语义一字未改** ✅
    localparam integer V_ACC   = 180;      // ⭐ = metronome.VEL_ACCENT
    localparam integer V_NRM   = 108;      // ⭐ = metronome.VEL_NORMAL
    //  ⚠️ **`integer` 参数【不做位选】**（`K-91`）⇒ ⭐ 另给 8 位常量供比较用
    localparam [7:0]   V_ACC8  = 8'd180;
    localparam [7:0]   V_NRM8  = 8'd108;
    localparam integer BEAT_GAP = 3000;    // ⚠️ > 2 个 sample_tick(1024) ⇒ 让重触发走完

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

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
    // DUT
    // ═════════════════════════════════════════════════════════════════════════
    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0] spi_cs_n;

    //  ⭐⭐ 2026-09-30：⭐ **显式选定"源 B = 节拍器"**（⭐ 本 tb 的被测对象）
    //     🔴 **为什么必须显式写**（⭐ 本次回归唯一红的根因，⭐ 已实测定位）：
    //        `top.SEL_DRUM` 的默认值曾被鼓机工作改成 **1 = 鼓机**（⭐ 出鼓机诊断档
    //        `.fs` 用的，⭐ cherry-pick 时没改回）⇒ ⚠️ 源 B（节拍器/鼓机）是
    //        **二选一** ⇒ 🔴 **节拍器的 8 个事件根本到不了 `note_manager`**
    //        （⭐ 实测：`evt_merge` 出口只有 `axis=15` 的鼓机事件）⇒ 🔴 T6 只能看到
    //        鼓机在**小节头**砸的那 2 下 ⇒ ⭐ 现象 = "**只有强拍触发 `perc_env_bank`**"
    //        （⭐ 看起来像 `note_manager`/`perc_env_bank` 坏了，⚠️ 其实不是 ✅）。
    //     ✅ **已裁定（2026-09-30）**：⭐ 主树默认档 = **0（节拍器）**；⭐ 验鼓机
    //        另编 `SEL_DRUM=1` 的 `.fs`（⭐ 见 `top.v` 参数处注释）✅
    //     📌 **本行保留的理由（⛔ 不是多余）**：⭐ 本 tb 的被测对象是**节拍器**，
    //        ⭐ "**自己需要哪一路就显式声明哪一路**" 是纪律 —— ⚠️ 依赖顶层默认值
    //        一旦默认值变动，tb 就测了**别的**源，⭐ 而判据是**红的**，
    //        看起来像被测模块坏了（⭐ 本次白查一轮的教训 ✅）
    top #(
        .SEL_DRUM              (0),
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
    // 探针（⭐ 路径已核实）
    // ═════════════════════════════════════════════════════════════════════════
    wire        met_start = u_top.met_start;
    wire [15:0] tcq       = u_top.g_sound.u_beat_gen.tick_cnt_q;
    wire        bstart    = u_top.g_sound.u_beat_gen.bar_start_o;
    wire        met_vld   = u_top.g_sound.met_evt_valid;
    wire [7:0]  met_vel   = u_top.g_sound.met_evt_vel;
    wire        p_trig    = u_top.g_sound.perc_trig[0];

    //  ⭐ 监视器：`met_start` 是 1 拍脉冲 ⇒ 必须用**锁存**的监视器来观测
    reg saw_start = 1'b0;
    //  ⭐ 每个节拍器事件的力度（按顺序）
    reg [7:0] vpat [0:15];
    integer   vcnt = 0;
    //  ⭐ `perc_env_bank` 被触发的次数（⭐ 判据②的核心）
    integer   tcnt = 0;

    always @(posedge clk) begin
        if (met_start) saw_start <= 1'b1;
        if (rst_n && met_vld) begin
            if (vcnt < 16) vpat[vcnt] = met_vel;
            vcnt = vcnt + 1;
        end
        if (rst_n && p_trig) tcnt = tcnt + 1;
    end

    integer i;
    integer tcnt_prev = 0;

    //  ⭐ 造一拍（`is_bar=1` ⇒ 强拍）：⛔ 不依赖 `beat_gen` 的真实速率
    //  ⚠️⚠️ **`beat_i` 是【电平】，必须只保持【一个】posedge**
    //     🔴 已实测踩到：保持两个 posedge ⇒ `evt_valid_o <= fire` 会在**两拍都置 1**
    //        ⇒ ⭐ **每拍发 2 个事件** ⇒ T4/T5/T6 全红（⚠️ 而 RTL 是对的）
    //     📌 同族：`U74`（force 与时钟沿的 delta 竞争）
    task one_beat;
        input is_bar;
        begin
            @(posedge clk); #5;                       // ⭐ 离开时钟沿（U74）
            force u_top.g_sound.bg_beat      = 1'b1;
            force u_top.g_sound.bg_bar_start = is_bar;
            @(posedge clk);                           // ⭐ 恰好一个 posedge 采样
            #5;                                       // ⭐ 立刻撤销 ⇒ 下一拍 fire=0
            release u_top.g_sound.bg_beat;
            release u_top.g_sound.bg_bar_start;
            repeat (BEAT_GAP) @(posedge clk);         // ⚠️ 让重触发走完（> 2 个 tick）
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_met_start_top/tb_met_start_top.vcd");
        $dumpvars(0, tb_met_start_top);

        rst_n = 1'b0;
        repeat (200) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // ── T0：先造出"按 S2 时正停在半小节"的现场 ──────────────────────
        //    ⭐ 把 `tick_cnt_q` 强成 5000 ⇒ `at_bar_start` = 0
        //    ⚠️ 这正是"第一声会是弱拍"的原因（⛔ 修复前就是这样）
        @(posedge clk); #5;
        force u_top.g_sound.u_beat_gen.tick_cnt_q = 16'd5000;
        repeat (10) @(posedge clk);
        chk("T0 precondition: mid-bar position held (tick_cnt_q==5000)", tcq === 16'd5000);
        release u_top.g_sound.u_beat_gen.tick_cnt_q;
        @(posedge clk);

        // ── T1/T2：开节拍器 ⇒ `met_start` 脉冲 ⇒ 位置复位 ───────────────
        force u_top.met_on_r = 1'b0;
        @(posedge clk); #5;
        force u_top.met_on_r = 1'b1;          // ⭐ 上升沿
        repeat (6) @(posedge clk);
        chk("T1 met_on_r rising edge produced a met_start pulse", saw_start === 1'b1);
        chk("T2 pos_reset cleared the bar position (tick_cnt_q==0)", tcq === 16'd0);

        // ── T3：让下一个 tick 立刻到来 ⇒ 第一声必须是【强拍】───────────
        //    ⭐ 强制相位到进位附近（只 1 拍）⇒ 下一个 tick 的 tick_cnt_q == 0
        @(posedge clk); #5;
        force u_top.g_sound.u_beat_gen.phase_q = 32'hFFFFF000;
        @(posedge clk);
        release u_top.g_sound.u_beat_gen.phase_q;
        repeat (10) @(posedge clk);
        chk("T3 the first tick after enabling IS a bar_start (accent position)",
            (bstart === 1'b1) || (vcnt > 0 && vpat[0] === V_ACC8));
        chk("T3b the FIRST metronome event carries the ACCENT velocity",
            (vcnt > 0) && (vpat[0] === V_ACC8));

        // ── T4/T5：连造 8 拍 ⇒ 力度模式必须是 强-弱-弱-弱 ×2 ────────────
        vcnt = 0;
        tcnt = 0;
        //  ⚠️ 先让 T3 那一拍的【重触发】走完（`retrig_low` 要等 `sample_tick`，最多 1024 拍）
        //     ⛔ 否则 T3 的事件会和循环第一拍【合并】⇒ 触发次数少 1（⚠️ 是 tb 时序问题，不是 RTL）
        repeat (BEAT_GAP) @(posedge clk);
        vcnt = 0;
        tcnt = 0;
        for (i = 0; i < 8; i = i + 1) begin
            tcnt_prev = tcnt;
            one_beat((i % 4) == 0);
            $display("  info: beat %0d (bar=%0d)  vcnt=%0d  tcnt=%0d  triggers_this_beat=%0d",
                     i, ((i % 4) == 0), vcnt, tcnt, (tcnt - tcnt_prev));
        end
        chk("T4 exactly ONE metronome event per emulated beat (8 events)",
            vcnt == 8);
        chk("T5 velocity pattern is accent-weak-weak-weak (180,108,108,108 x2)",
            (vpat[0] === V_ACC8) && (vpat[1] === V_NRM8) &&
            (vpat[2] === V_NRM8) && (vpat[3] === V_NRM8) &&
            (vpat[4] === V_ACC8) && (vpat[5] === V_NRM8) &&
            (vpat[6] === V_NRM8) && (vpat[7] === V_NRM8));

        // ── T6：⭐⭐ 每一拍都必须【真的触发】打击包络 ────────────────────
        //    ⚠️ 若某拍没触发 ⇒ 🔴 那一拍就"变弱/没了"
        //       （⭐ 这正是用户说的"有时候会变弱"）
        chk("T6 EVERY beat really fired the perc envelope (8 triggers for 8 events)",
            tcnt == 8);

        release u_top.met_on_r;

        if (errors == 0)
            $display("PASS: met_start_top -- metronome starts on the DOWNBEAT and every beat fires");
        else
            $fatal(1, "FAIL: met_start_top has %0d error(s)", errors);

        #200;
        $finish;
    end

endmodule

// ─────────────────────────────────────────────────────────────────────────────
// 变异记录（⭐ 非空洞性：`C21`/`C83` —— 判据必须【能红】）
//
//   ⭐ 工具：`sim/check_met_btn_nonempty.ps1`（⭐ 变异副本机制，⛔ 不碰 `rtl/`）
//
//   | 变异 | 改什么 | ⭐ 预期变红的判据 |
//   |---|---|---|
//   | **MUT6** | `.pos_reset_i (met_start)` ⇒ `.pos_reset_i (1'b0)` | ✅ **T2 / T3b** |
//     ⭐ 即"**退回修复前**"（`beat_gen` 自由跑、位置不复位）
//        ⇒ ⭐ `tick_cnt_q` 停在 5000 ⇒ 下一个 tick **不是** `bar_start`
//        ⇒ ⭐ **第一声是弱拍** ⇒ **T3b 必红** ✅
//
//   | **MUT7** | `met_vel` 相关：把 `metronome.VEL_NORMAL` 改成 `VEL_ACCENT` | ✅ **T5** |
//     ⭐ 即"每一拍都是强拍" ⇒ ⭐ 力度模式不再是 强-弱-弱-弱 ⇒ **T5 必红**
// ─────────────────────────────────────────────────────────────────────────────
