// ═══════════════════════════════════════════════════════════════════════════
//  tb_span_retry_reemits_axis —— ⭐ 守 `K-132`：⭐ **重试时必须【重新发轴号】**
//
//  🔴 **上板现象（⭐ 用户实测 2026-09-25）**：
//     发 `'S'` ⇒ ⭐ **只回一个 `s`，⭐ 没有轴号，⭐ 也没有 `!`**
//
//  🔴 **根因（`K-132`）**：
//     `calib_span.v` 的 `S_PROMPT` 原来只写 `need_press_o <= 1'b1`，
//     ⚠️ 而从 `S_SETTLE` 超时**重试回到 `S_PROMPT`** 时 `need_press_o` **本来就是 1**
//     ⇒ 🔴 **没有 0→1 跳变** ⇒ `top.v` 的 `ev_need = sp_need_press & ~sp_need_r`
//        （⭐ **上升沿检测**）**不产生事件** ⇒ 🔴 **轴号不再回发**。
//
//  ⭐ **修法**：⭐ `S_PROMPT` 停留 **2 拍**（⭐ `prompt_phase` 标记）：
//     · 第 1 拍：`need_press_o <= 0`
//     · 第 2 拍：`need_press_o <= 1`  ⇒ ⭐ 干净的上升沿
//
//  ⭐⭐ **本 tb 的判据（⭐ 这是回归保护）**：
//     ⭐ 统计"`need_press_o` 的上升沿次数"，⭐ 必须 **≥ 重试次数 + 1**
//     ⇒ 🔴 若有人把这个两拍逻辑改回去，⭐ 上升沿次数会掉到 1 ⇒ **本 tb 变红**。
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_span_retry_reemits_axis;

    localparam integer NCH = 8, N_ADC = 2, AXIS_TOTAL = 16;
    localparam integer STABLE_NEED = 8;
    localparam [11:0]  STABLE_TOL  = 12'd48;
    localparam integer VOTE_N      = 8;
    localparam [11:0]  VOTE_TOL    = 12'd96;
    localparam integer REJECT_MAX  = 8;

    // ⭐ 故意用短超时 ⇒ 让它【快速反复重试】⇒ 正好检验"重试时会不会重发轴号"
    localparam integer TIMEOUT = 300;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg start_i = 0, abort_i = 0;
    reg sample_valid_i = 0;
    reg [2:0] sample_ch_i = 0;
    reg [11:0] raw_i = 0;
    wire [N_ADC-1:0] span_o;
    wire [2:0] cal_ch_o;
    reg cal_busy_i = 0, cal_err_i = 0;
    wire busy_o, done_o, reject_o, need_press_o;
    wire [3:0] cur_axis_o, done_cnt_o, rej_cnt_o;
    wire [2:0] state_o;

    calib_span #(
        .NCH(NCH), .N_ADC(N_ADC), .AXIS_TOTAL(AXIS_TOTAL),
        .STABLE_NEED(STABLE_NEED), .VOTE_N(VOTE_N),
        .WAIT_TIMEOUT_CLK(TIMEOUT),
        .STABLE_TOL(STABLE_TOL), .VOTE_TOL(VOTE_TOL),
        .REJECT_MAX(REJECT_MAX), .POS_W(12)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_i(start_i), .abort_i(abort_i),
        .sample_valid_i(sample_valid_i), .sample_ch_i(sample_ch_i), .raw_i(raw_i),
        .span_o(span_o), .cal_ch_o(cal_ch_o),
        .cal_busy_i(cal_busy_i), .cal_err_i(cal_err_i),
        .busy_o(busy_o), .done_o(done_o),
        .reject_o(reject_o), .need_press_o(need_press_o),
        .cur_axis_o(cur_axis_o), .done_cnt_o(done_cnt_o), .rej_cnt_o(rej_cnt_o),
        .state_o(state_o)
    );

    // ⭐⭐ 复刻 `top.v` 的边沿检测，⭐ 数"轴号会回发几次"
    //    top.v:  ev_need = sp_need_press & ~sp_need_r
    //            rep_byte = ev_need ? axis_char : ...
    reg sp_need_r = 0;
    integer ev_need_cnt = 0;
    integer prompt_entries = 0;
    reg [2:0] ps = 3'd7;

    always @(posedge clk) begin
        if (rst_n) begin
            sp_need_r <= need_press_o;
            if (need_press_o & ~sp_need_r) ev_need_cnt = ev_need_cnt + 1;
            if (state_o == 3'd1 && ps != 3'd1) prompt_entries = prompt_entries + 1;
            ps <= state_o;
        end
    end

    // ⭐ 永远给"抖动"的读数 ⇒ 必定稳不住 ⇒ 必定反复超时重试
    localparam integer FRAME = 20;
    reg [2:0] sweep_ch = 0;
    integer tick = 0;
    always @(negedge clk) tick = tick + 1;

    initial begin
        forever begin
            repeat (FRAME) @(negedge clk);
            @(negedge clk);
            sample_ch_i = sweep_ch;
            // ⭐ 轴 0 给剧烈跳变（⭐ 保证稳不住 ⇒ 必超时）
            raw_i = (sweep_ch == 3'd0) ? (12'd2000 + ((tick % 2) ? 12'd300 : 12'd0))
                                       : 12'd300;
            sample_valid_i = 1'b1;
            @(negedge clk);
            sample_valid_i = 1'b0;
            sweep_ch = sweep_ch + 3'd1;
        end
    end

    integer fails = 0;
    initial begin
        $display("=== tb_span_retry_reemits_axis（守 K-132）===");
        $display("⭐ 给【抖动】读数 ⇒ 必定反复超时重试");
        $display("⭐ 判据：⭐ 每次进 S_PROMPT 都必须产生一次 need_press 上升沿");
        $display("        （⭐ 即 ev_need_cnt 必须 ≈ prompt_entries，⛔ 不是 1）");
        $display("");

        rst_n = 0; start_i = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);
        @(negedge clk); start_i = 1;
        @(negedge clk); start_i = 0;

        // ⭐ 跑够多次重试
        repeat (6000) @(negedge clk);

        $display("--------------------------------------------------");
        $display("  进 S_PROMPT 次数        = %0d", prompt_entries);
        $display("  ev_need 次数（= 回轴号） = %0d", ev_need_cnt);
        $display("  reject 次数              = %0d", rej_cnt_o);
        $display("--------------------------------------------------");

        if (prompt_entries < 3) begin
            $display("FAIL: 重试次数太少（%0d）⇒ 本 tb 没测到东西", prompt_entries);
            fails = fails + 1;
        end else if (ev_need_cnt >= prompt_entries - 1) begin
            $display("ok  : 每次重试都重新发了轴号（%0d 次 / %0d 次进 PROMPT）",
                     ev_need_cnt, prompt_entries);
        end else begin
            $display("FAIL: 🔴 轴号漏发！只发了 %0d 次，但有 %0d 次提示机会",
                     ev_need_cnt, prompt_entries);
            $display("      ⇒ 这正是 K-132：need_press 没有 0->1 跳变");
            fails = fails + 1;
        end

        $display("==================================================");
        if (fails == 0) $display("PASS: 重试时轴号会重新回发（K-132 已修）");
        else            $display("FAIL: %0d 项不达标", fails);
        $finish;
    end

    initial begin
        #10000000;
        $display("FAIL: tb 自身超时");
        $finish;
    end

endmodule
