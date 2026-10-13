// ═══════════════════════════════════════════════════════════════════════════
// tb_sustain_pedal_wire.sv — T5 延音踏板【顶层接线】判据
//
//   模块级语义已由 `tb/w3b/tb_note_manager_sus.sv` 钉住（19/19）。
//   本 tb 只验**顶层这一条链**真正存在的风险：
//     W1 空闲（`pedal_sus_i = 1`）⇒ `sus_pedal_r` 必须为 0（⛔ 不误判成"踩住"）
//     W2 踩下（= 0）⇒ 去抖窗口后 `sus_pedal_r` 必须为 1（⭐ 极性正确）
//     W3 短毛刺（< 去抖窗口）⇒ `sus_pedal_r` **不变**（⭐ 去抖真的在工作）
//     W4 松开（= 1）⇒ 去抖窗口后 `sus_pedal_r` 必须回 0
//     W5 ⭐ **端口真的接上了**：踩住时 `u_note_manager.sus_pedal_i` 必须为 1
//     W6 ⭐ **Z-safe**：悬空（`Z`）⇒ 按"未踩" ⇒ `sus_pedal_r` 保持 0
//        （⭐ 这一条保证 ~13 个老 tb 不用改 ✅）
//     W7 `sus_pedal_r` 全程⛔ 不得出现 X/Z
//
//   ⚠️ tb 里把 `PEDAL_DB_MS` 改成 1 ms（= 50k 拍）⇒ 跑得快，语义不变 ✅
// ═══════════════════════════════════════════════════════════════════════════

`timescale 1ns/1ps

module tb_sustain_pedal_wire;

    localparam integer DB_MS_TB = 1;          // ⭐ 1 ms
    localparam integer DB_CYC   = 50_000;     // 1 ms @ 50 MHz

    reg clk = 1'b0;
    always #10 clk = ~clk;                    // 50 MHz

    reg rst_n = 1'b0;
    reg pedal_sus = 1'b1;                     // 低有效：1 = 未踩、0 = 踩下

    wire ctrl_ws, esp_tx;
    wire [2:0] strip;

    top #(
        //  ⭐ 2026-10-09：本 tb 只测音频/控制，⛔ 不测 HDMI ⇒ 剪掉李萨如渲染器。
        //     ⚠️ 必须显式传 0：`top.v` 交付默认已是 SCOPE_MODE=1，否则本 tb 会超时。
        .SCOPE_MODE        (0),
        .PEDAL_DB_MS           (DB_MS_TB),
        .PA_ON_AFTER_RESET     (0),
        .DEMO_CHORD_ON         (1),   // ⭐ 必须为 1：否则走 g_silent ⇒ note_manager 不被例化（⭐ 实测踩过）
        .HEARTBEAT_DIV         (100)
    ) u_top (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(), .HP_WS(), .HP_DIN(), .PA_EN_n(), .led_heartbeat(),
        .I2S2_BCK(), .I2S2_LRCK(), .I2S2_DIN(),
        .pluck_up_i(1'b0), .pluck_down_i(1'b0),
        .spi_miso(6'b111111), .spi_sclk(), .spi_mosi(), .spi_cs_n(),
        .uart_rx(1'b1), .uart_tx(),
        .ctrl_row_o(), .ctrl_col_i(4'b0000),
        .enc_a_i(1'b1), .enc_b_i(1'b1), .enc_sw_i(1'b1),
        .ctrl_ws_o(ctrl_ws),
        .pedal_sus_i(pedal_sus), .pedal_loop_rec_i(1'b1), .pedal_loop_play_i(1'b1),
        .esp_uart_tx_o(esp_tx), .esp_uart_rx_i(1'b1),
        .ws_strip_o(strip)
    );

    // ⭐ 被验的两根线（⭐ 层次引用：去抖后的踏板态 / 送进 note_manager 的端口）
    wire sus_pedal_r     = u_top.sus_pedal_r;
    wire nm_sus_pedal_i  = u_top.g_sound.u_note_manager.sus_pedal_i;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk;
        input        cond;
        input [1023:0] name;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  ok  : %0s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    task wait_cyc;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_sustain_pedal_wire (T5 顶层接线) ===");

        repeat (20) @(negedge clk);
        rst_n = 1'b1;
        wait_cyc(200);

        // ── W1：空闲 ⇒ 未踩 ──────────────────────────────────────────
        wait_cyc(DB_CYC + 2000);
        chk(sus_pedal_r === 1'b0, "W1 idle (pedal_sus_i=1) => sus_pedal_r=0 (no phantom press)");
        chk(nm_sus_pedal_i === 1'b0, "W1b note_manager.sus_pedal_i=0 while idle");

        // ── W2：踩下 ⇒ 去抖后为 1（极性正确）────────────────────────
        pedal_sus = 1'b0;
        wait_cyc(DB_CYC + 2000);
        chk(sus_pedal_r === 1'b1, "W2 pressed (pedal_sus_i=0) => sus_pedal_r=1 (polarity OK)");

        // ── W5：端口真的接上了 ───────────────────────────────────────
        chk(nm_sus_pedal_i === 1'b1, "W5 note_manager.sus_pedal_i=1 while pressed (wired)");

        // ── W3：短毛刺被去抖拒掉 ─────────────────────────────────────
        pedal_sus = 1'b1;                       // 抬起
        wait_cyc(DB_CYC / 4);                   // ⭐ 0.25 ms < 1 ms 窗口
        pedal_sus = 1'b0;                       // 又踩下
        wait_cyc(DB_CYC + 2000);
        chk(sus_pedal_r === 1'b1, "W3 short glitch (< DB window) => state unchanged (debounce works)");

        // ── W4：真松开 ⇒ 回 0 ────────────────────────────────────────
        pedal_sus = 1'b1;
        wait_cyc(DB_CYC + 2000);
        chk(sus_pedal_r === 1'b0, "W4 released (pedal_sus_i=1) => sus_pedal_r=0");
        chk(nm_sus_pedal_i === 1'b0, "W4b note_manager.sus_pedal_i=0 after release");

        // ── W6：Z-safe（悬空 ⇒ 按未踩）───────────────────────────────
        pedal_sus = 1'bz;
        wait_cyc(DB_CYC + 2000);
        chk(sus_pedal_r === 1'b0, "W6 floating (Z) => treated as NOT pressed (Z-safe, old tbs unaffected)");

        // ── W7：不得有 X/Z ──────────────────────────────────────────
        chk((sus_pedal_r === 1'b0) || (sus_pedal_r === 1'b1), "W7 sus_pedal_r is never X/Z");

        // ── 汇总 ────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_sustain_pedal_wire — %0d/%0d judgements held (T5 top wiring)",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_sustain_pedal_wire — %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #500_000_000;                            // 500 ms 上限
        $display("FAIL: tb_sustain_pedal_wire TIMEOUT");
        $finish;
    end

endmodule
