`timescale 1ns/1ps
`default_nettype none

// ═══════════════════════════════════════════════════════════════════════════
// tb_integration_consts -- ⭐ 把 top.v 里那 4 条 `$display` 自检【变成能红的断言】
//
//   🔴 **为什么需要它**（⭐ 两条真问题）：
//      ① ⭐ `top.v` 里那 4 条自检全是 `$display("ERROR [top] …")`
//         ⚠️ 而 **`$display` 在综合期被忽略**（⭐ `WARN (EX3858)`）
//         ⇒ 🔴 **它们只是"仿真里打印一行"，⛔ 没有任何 tb 断言它**
//         ⇒ ⭐ 按"判据必须能红"的纪律，⭐ **它们现在不算判据** ✅
//      ② 🔴 **集成值无人守**：⭐ `top.v` 传 `.POS_FULL(TRAVEL_TARE)`，
//         而 `tb_param_extract.sv` **自己镜像了一份** `POS_FULL = 744`
//         ⇒ ⚠️ **两者可以悄悄分家**（⭐ 改一处、⭐ 忘另一处）
//         ⇒ ⭐ 而**没有任何 tb 验证"顶层到底传下去什么"** ✅
//         📌 这正是上一轮量纲错**漏过回归**的原因 ✅
//
//   ⭐⭐ **判据（6 条，⭐ 全部能红）**
//      A1 ⭐ `TRAVEL_TARE ≤ calib.MAX_TRAVEL(1023)`   ← ⭐ top.v:2392 那条
//      A2 ⭐ `TRAVEL_TARE ≠ CALIB_FULL`               ← ⭐ top.v:2399 那条（⭐ 点名 BATCH 8.2 的错）
//      A3 ⭐ `EVT_TRIG_TH ≤ TRAVEL_TARE`              ← ⭐ top.v:2380 那条
//      A4 ⭐ `EVT_REL_TH < EVT_TRIG_TH`               ← ⭐ top.v:2403 那条（⭐ 迟滞）
//      A5 ⭐⭐ **集成值链路**：⭐ `u_param_extract.POS_FULL == TRAVEL_TARE`
//      A6 ⭐⭐ **镜像一致**：⭐ `TRAVEL_TARE == 744`（⭐ = `tb_param_extract.sv:41` 的镜像）
//
//   ⭐ **非空洞性（⭐ 必做）**：
//      · ⭐ 把 `top.v` 的 `TRAVEL_TARE` 改成 `12'd4095` ⇒ 🔴 **A1/A2/A6 必须 FAIL**
//      · ⭐ 把 `.POS_FULL(TRAVEL_TARE)` 改成 `.POS_FULL(CALIB_FULL)` ⇒ 🔴 **A5 必须 FAIL**
//      · ⭐ 把 `EVT_TRIG_TH` 改成 `12'd1000` ⇒ 🔴 **A3 必须 FAIL**
// ═══════════════════════════════════════════════════════════════════════════

module tb_integration_consts;

    reg clk = 1'b0;
    always #10 clk = ~clk;          // ⭐ 50 MHz
    reg rst_n = 1'b0;

    wire        HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_hb;
    wire        spi_sclk, spi_mosi, miso_l, miso_r;
    wire [5:0]  spi_cs_n;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .SEL_DRUM (0)               // ⭐ 源 B = 节拍器（⭐ 与本 tb 无关，⭐ 只为确定配置）
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

    // ── ⭐⭐ 层次引用（⭐ 常量在 `g_sound` 内 ✅）──────────────────────────────
    //   ⚠️ 用 `wire` 而⛔ 不是 `localparam` —— ⭐ 层次引用**不能进常量表达式** ✅
    wire [11:0] C_TRIG   = u_top.g_sound.EVT_TRIG_TH;
    wire [11:0] C_REL    = u_top.g_sound.EVT_REL_TH;
    wire [11:0] C_TRAVEL = u_top.g_sound.TRAVEL_TARE;
    wire [11:0] C_FULL   = u_top.g_sound.CALIB_FULL;
    //   ⭐⭐ **集成值**：⭐ 顶层**实际传给** `param_extract` 的那个 `POS_FULL` ✅
    wire [11:0] C_POSFULL = u_top.g_sound.u_param_extract.POS_FULL;

    //   ⭐ `tb_param_extract.sv:41` 的镜像值（⭐ 本 tb 断言"两者一致" ✅）
    localparam [11:0] MIRROR_POS_FULL = 12'd744;

    integer errors = 0;
    integer checks = 0;

    task chk;
        input [8*72-1:0] name;
        input            cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    initial begin
        $display("=== tb_integration_consts: top.v self-checks as RED-ABLE assertions ===");
        $display("  INFO: TRIG=%0d REL=%0d TRAVEL=%0d CALIB_FULL=%0d POS_FULL(passed down)=%0d",
                 C_TRIG, C_REL, C_TRAVEL, C_FULL, C_POSFULL);

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ══ A1 ⭐ 实际行程档不许超过 calib.MAX_TRAVEL(1023) ═══════════════
        chk("A1: TRAVEL_TARE <= calib.MAX_TRAVEL(1023)",
            C_TRAVEL <= 12'd1023);

        // ══ A2 ⭐ 不许把【归一档】当成【实际行程档】 ═══════════════════════
        chk("A2: TRAVEL_TARE != CALIB_FULL (the BATCH 8.2 mistake)",
            C_TRAVEL !== C_FULL);

        // ══ A3 ⭐ 触发阈值必须落在实际行程内 ═══════════════════════════════
        chk("A3: EVT_TRIG_TH <= TRAVEL_TARE",
            C_TRIG <= C_TRAVEL);

        // ══ A4 ⭐ 释放阈值严格小于触发阈值（⭐ 迟滞） ═══════════════════════
        chk("A4: EVT_REL_TH < EVT_TRIG_TH (hysteresis)",
            C_REL < C_TRIG);

        // ══ A5 ⭐⭐ 集成值链路：⭐ 顶层真的把 TRAVEL_TARE 传下去了吗 ════════
        chk("A5: top passes TRAVEL_TARE down to param_extract.POS_FULL",
            C_POSFULL === C_TRAVEL);

        // ══ A6 ⭐⭐ 镜像一致：⭐ 与 tb_param_extract 的镜像不许分家 ═════════
        chk("A6: TRAVEL_TARE matches tb_param_extract's mirror (744)",
            C_TRAVEL === MIRROR_POS_FULL);

        // ── ⭐ 汇总 ─────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: integration_consts -- top's self-checks hold AND the value really reaches param_extract");
        else
            $display("FAIL: integration_consts -- %0d of %0d checks failed", errors, checks);
        $display("INFO: checks=%0d errors=%0d", checks, errors);
        $finish;
    end

    // ⭐ 超时兜底
    initial begin
        #200_000;
        $display("FAIL: integration_consts -- TIMEOUT");
        $finish;
    end

endmodule
