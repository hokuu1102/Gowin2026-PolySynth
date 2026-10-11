// ═══════════════════════════════════════════════════════════════════════════
// tb_evt_uart_rx_gate.sv — ⭐ `P0-02` 的**集成级门控判据**（2026-10-09）
//
//   🔴 **缺陷**（审查报告 §一 [P0-02]）：
//      `top.v` 里**同一条** `uart_rx` 的 `ur_done`/`ur_data` 被**三路共用**
//      （`uart_ui` 屏 · `calib_cmd` 命令 · `evt_uart_rx` 曲谱），
//      而 `evt_uart_rx` 的帧头是 **`0xA5`**、⛔ 它**看不到别人的帧边界**
//      ⇒ 别人**合法载荷**里的 `0xA5` 落在它的 `idx==0` 上 ⇒ 🔴 **伪曲谱事件**
//      ⇒ ⭐ 伪事件的源是 `score`(3'd1)，而手弹是 `live`(3'd0)，
//         `note_manager.note_off` 按 `(轴, 源)` 双条件匹配
//      ⇒ 🔴 **手弹的 `note_off` 结构上永远清不掉 `score` 源的 voice** ⇒ **永久挂音**
//      （⭐ 用户实测："按同键不能清 / 按所有键也不能清 / 持续几分钟 / 断电才清"）✅
//
//   ✅ **修法（顶层门控）**：⭐ 别人在帧内时，**不给曲谱接收器字节**：
//      · `uart_ui`   在帧内 ⇒ `ui_in_frame`（⭐ 新引出 `in_frame_o`）
//      · `calib_cmd` 在帧内 ⇒ `cmd_idx != 0`（⭐ 它早就有这个输出）
//      ⇒ `evt_rx_done = ur_done & ~ui_in_frame & (cmd_idx == 0)`
//
//  🔴🔴 **2026-10-11 更正：上面那条 `cmd_idx` 从句是【错的】—— ⚠️ 而本 tb 从来没用过它** ✅
//     ⭐ 本 tb 真正的门控表达式（⭐ 见下方 `:88` 附近）**一直只有** `rx_done & ~ui_in_frame` ✅
//     🔴 而 `top.v` 里**多写了** `& (cmd_idx == 4'd0)` ⇒ ⚠️ **两边【漂移】了** ✅
//     🔴 **后果（⭐ 2026-10-11 实测）**：⭐ `calib_cmd` 的 `idx_q != 0` **只可能**在它看到
//        `0xA5` 时出现（⭐ 它自己的注释写着"事件帧开始 ⇒ 进入帧内"），
//        ⭐ 而**命令只在 `idx_q==0` 时识别、且不推进 `idx_q`**
//        ⇒ ⭐⭐ `cmd_idx != 0` **恰恰等价于"曲谱自己的帧正在收"** ✅
//        ⇒ 🔴 `top.v` 的门控**把曲谱接收器正好在它最需要的时候关掉了**：
//           ⭐ 9 个字节只有第 1 个（`0xA5`）过门 ⇒ ⭐ `evt_uart_rx` 永远收不满一帧
//           ⇒ 🔴 **曲谱链路整体不可用**（⭐ 实测：`eu_idx` 卡在 1、`eu_frame_cnt` 恒 0 ✅）
//     ✅ **已修**：⭐ `top.v` 删掉那个从句 ⇒ ⭐ **与本 tb 的表达式一致** ✅
//        📌 ⭐ 本 tb 的 3 条判据**一字未改**、⭐ 修前修后**都是全绿** ——
//           ⚠️ 这正是它**没能抓住那个缺陷**的原因：🔴 **它比 `top.v` 少了一个从句** ✅
//     ⭐⭐ **教训（⭐ 可复用）**：⭐ **"与 `top.v` 同式接线"必须【逐字符】核对【表达式本身】，
//        ⛔ 不能只核对"例化了哪几个模块"** —— ⚠️ **注释里写着 A、⭐ 代码里写着 B**
//        ⇒ 🔴 **缺陷就藏在 A 与 B 之间** ✅
//
//   ⭐ **本 tb 的判据（双向往返，⛔ 不是单边）**：
//     G1 ⭐ **屏帧不许出事件**：背靠背喂 8 个 `0x71` 数值帧（数据里含 `0xA5`）
//        ⇒ `evt_uart_rx` 的 `evt_valid_o` **必须 0 次脉冲**
//        （🔴 未修实测：**8 次** —— 见 `tb_evt_uart_rx_screen.sv` 的打印证据 ✅）
//     G2 ⭐ **真曲谱帧必须出事件**（⭐ 证明门控没把真东西也挡掉）：
//        在**帧间空隙**（没人在帧内）喂一条合法曲谱包 `0xA5 + 8 字节`
//        ⇒ `evt_valid_o` **必须正好 1 次脉冲**
//     G3 ⭐ **门控真的动过**：`uart_ui` 的 `in_frame_o` 必须**至少为 1 过一拍**
//        （⭐ 否则 G1 是"因为没门控需求"而侥幸通过 ⇒ 空判据）✅
//   📌 本 tb 只例化 `uart_ui` + `evt_uart_rx` 两模块（⭐ 与 `top.v` 同式接线）
//      —— ⛔ 不需要 `uart_rx`（⭐ 字节流由 tb 直接驱动，与 `tb_evt_uart_rx_screen` 同夹具）✅
// ═══════════════════════════════════════════════════════════════════════════

`timescale 1ns/1ps

module tb_evt_uart_rx_gate;

    localparam integer CLK_HZ   = 50_000_000;
    localparam integer BAUD     = 500_000;
    localparam integer BYTE_CLK = CLK_HZ / BAUD;      // 100 clk/字节

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;                            // 50 MHz

    reg        rx_done = 0;
    reg  [7:0] rx_data = 0;

    // ── 屏侧（uart_ui）────────────────────────────────────────────────────
    wire        ui_in_frame;
    wire        ui_mode;
    wire [6:0]  ui_base_semi;
    wire        ui_mode_commit, ui_base_commit;
    wire        ui_tx_start;
    wire [7:0]  ui_tx_data;
    wire        ui_fx_en;
    wire [1:0]  ui_fx_sel;
    wire        ui_test_mode;
    wire [1:0]  ui_test_mode_n;
    wire        ui_test_mode_commit;
    wire [15:0] ui_frame_cnt, ui_resync_cnt, ui_err_cnt;
    wire        ui_hb_ready;

    uart_ui #(.MODE_PIANO_DEFAULT(1)) u_ui (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .rx_done_i     (rx_done),
        .rx_data_i     (rx_data),
        .tx_busy_i     (1'b1),
        .tx_done_i     (1'b0),
        .tx_start_o    (ui_tx_start),
        .tx_data_o     (ui_tx_data),
        .mode_o        (ui_mode),
        .base_semi_o   (ui_base_semi),
        .mode_commit_o (ui_mode_commit),
        .base_commit_o (ui_base_commit),
        .fx_en_o       (ui_fx_en),
        .fx_sel_o      (ui_fx_sel),
        .test_mode_o   (ui_test_mode),
        .test_mode_n_o (ui_test_mode_n),
        .test_mode_commit_o(ui_test_mode_commit),
        .frame_cnt_o   (ui_frame_cnt),
        .resync_cnt_o  (ui_resync_cnt),
        .err_cnt_o     (ui_err_cnt),
        .hb_ready_o    (ui_hb_ready),
        .in_frame_o    (ui_in_frame)
    );

    // ── ⭐ 门控（⭐ 与 `top.v` 同式；本 tb 未例化 calib_cmd ⇒ 那一项恒 0）──
    wire evt_rx_done = rx_done & ~ui_in_frame;

    // ── 曲谱侧（evt_uart_rx）──────────────────────────────────────────────
    wire        evt_valid;
    wire [63:0] evt_data;
    wire [15:0] eu_frame_cnt, eu_resync_cnt, eu_hdr_err_cnt, eu_drop_cnt;
    wire [3:0]  eu_idx;
    wire        eu_synced;

    evt_uart_rx #(
        .CLK_HZ   (CLK_HZ),
        .BAUD     (BAUD),
        .GAP_BYTES(16)
    ) u_evt (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .rx_done_i     (evt_rx_done),
        .rx_data_i     (rx_data),
        .evt_valid_o   (evt_valid),
        .evt_data_o    (evt_data),
        .frame_cnt_o   (eu_frame_cnt),
        .resync_cnt_o  (eu_resync_cnt),
        .hdr_err_cnt_o (eu_hdr_err_cnt),
        .drop_cnt_o    (eu_drop_cnt),
        .idx_o         (eu_idx),
        .synced_o      (eu_synced)
    );

    // ── 观测 ──────────────────────────────────────────────────────────────
    integer n_evt_g1 = 0, n_evt_g2 = 0;
    integer n_ui_inframe = 0;
    reg     g1_phase = 1'b1;
    always @(posedge clk) begin
        if (rst_n) begin
            if (ui_in_frame) n_ui_inframe = n_ui_inframe + 1;
            if (evt_valid) begin
                if (g1_phase) n_evt_g1 = n_evt_g1 + 1;
                else          n_evt_g2 = n_evt_g2 + 1;
            end
        end
    end

    task feed_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(negedge clk);
            rx_done = 1'b0;
            repeat (BYTE_CLK) @(negedge clk);
        end
    endtask

    task idle_gap;
        input integer nbytes;
        begin
            repeat (BYTE_CLK * nbytes) @(negedge clk);
        end
    endtask

    integer pass_cnt = 0, fail_cnt = 0;
    task chk;
        input          cond;
        input [1023:0] name;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  ok  : %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    integer k;
    initial begin
        $display("=== tb_evt_uart_rx_gate (P0-02 顶层门控) ===");
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        idle_gap(20);

        // ══ G1：背靠背 8 个屏数值帧（数据里含 0xA5）⇒ 曲谱侧必须【0 条事件】══
        g1_phase = 1'b1;
        for (k = 0; k < 8; k = k + 1) begin
            feed_byte(8'h71);
            feed_byte(k[7:0]);
            feed_byte(8'hA5);              // ⭐ 每帧都含 0xA5
            feed_byte(8'hA5);
            feed_byte(8'h00);
            feed_byte(8'hFF);
            feed_byte(8'hFF);
            feed_byte(8'hFF);
            feed_byte(8'hFF);
        end
        idle_gap(40);
        $display("      [dbg] G1: screen frames=8  ui_inframe_cycles=%0d  spurious_evt=%0d",
                 n_ui_inframe, n_evt_g1);
        chk(n_evt_g1 == 0,
            "G1 screen frames (payload contains 0xA5) produce ZERO score events");
        chk(n_ui_inframe > 0,
            "G3 the gate was actually exercised (uart_ui.in_frame_o was high)");

        // ══ G2：帧间空隙里喂一条【合法曲谱包】⇒ 必须正好 1 条事件 ══════
        g1_phase = 1'b0;
        idle_gap(40);                      // ⭐ 先让两边都归位（帧外）
        feed_byte(8'hA5);                  // ⭐ 合法帧头
        feed_byte(8'h07);                  // ⭐ 轴 3（0x07 低 4 位 = axis，见解码）
        feed_byte(8'h00);
        feed_byte(8'h10);
        feed_byte(8'h00);
        feed_byte(8'h20);
        feed_byte(8'h00);
        feed_byte(8'hC8);                  // ⭐ 力度 200
        feed_byte(8'h00);
        idle_gap(40);
        $display("      [dbg] G2: legal score packet  evt=%0d  (frame_cnt=%0d hdr_err=%0d)",
                 n_evt_g2, eu_frame_cnt, eu_hdr_err_cnt);
        chk(n_evt_g2 == 1,
            "G2 a LEGAL score packet (sent between frames) still produces exactly 1 event");

        $display("");
        if (fail_cnt == 0)
            $display("PASS: tb_evt_uart_rx_gate — %0d/%0d judgements held (P0-02 门控双向验证)",
                     pass_cnt, pass_cnt + fail_cnt);
        else
            $display("FAIL: tb_evt_uart_rx_gate — %0d pass / %0d fail", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_evt_uart_rx_gate TIMEOUT");
        $finish;
    end

endmodule
