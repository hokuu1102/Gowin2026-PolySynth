`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_evt_merge_diff.sv —— 差分：**新** `evt_merge` vs **旧** `evt_merge_ref`
//
//   ⭐ 目的（作战计划 §4-1 判据 2）：证明"减宽"是**逐拍逐位等价**的，⛔ 不只是 tb 断言过。
//   ⭐ 手法（与 A1 的差分同一套）：同一份刺激同时喂两个实例，**每拍比全部 12 组输出**；
//      ⭐ 覆盖 **5 种 DEPTH（2/3/4/6/9）**，含 6 = 交付值、4 = `tb_evt_merge` 的值。
//   ⚠️ 非空洞性：把新模块的任意一处位宽改错（例如 `SUM_W` 少一位）⇒ 本 tb 必须报 mismatch。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tb_evt_merge_diff;

    reg clk = 0;
    always #10 clk = ~clk;              // 50 MHz

    reg rst_n = 0;
    integer errors = 0;
    integer checks = 0;
    localparam integer CYCLES = 20000;

    // ── 共享刺激（三个源）────────────────────────────────────────────────
    reg        av, bv, cv;
    reg [3:0]  aax, bax, cax;
    reg [31:0] ain, bin, cin;
    reg [7:0]  ave, bve, cve;
    reg [1:0]  akd, bkd, ckd;
    reg        atv, btv, ctv;
    reg [1:0]  atb, btb, ctb;
    reg [2:0]  asr, bsr, csr;

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : g
            localparam integer D = (gi == 0) ? 2 :
                                   (gi == 1) ? 3 :
                                   (gi == 2) ? 4 :
                                   (gi == 3) ? 6 : 9;

            wire        nv, ntv, novf, rv, rtv, rovf;
            wire [3:0]  nax, rax;
            wire [31:0] nin, rin;
            wire [7:0]  nve, rve;
            wire [1:0]  nkd, rkd, ntb, rtb;
            wire [2:0]  nsr, rsr;
            wire [15:0] ncol, rcol, nmer, rmer, ndrp, rdrp;

            evt_merge #(.DEPTH(D)) u_new (
                .clk_i(clk), .rst_n_i(rst_n),
                .a_valid_i(av), .a_axis_i(aax), .a_phase_inc_i(ain),
                .a_velocity_i(ave), .a_kind_i(akd), .a_timbre_valid_i(atv),
                .a_timbre_i(atb), .a_src_i(asr),
                .b_valid_i(bv), .b_axis_i(bax), .b_phase_inc_i(bin),
                .b_velocity_i(bve), .b_kind_i(bkd), .b_timbre_valid_i(btv),
                .b_timbre_i(btb), .b_src_i(bsr),
                .c_valid_i(cv), .c_axis_i(cax), .c_phase_inc_i(cin),
                .c_velocity_i(cve), .c_kind_i(ckd), .c_timbre_valid_i(ctv),
                .c_timbre_i(ctb), .c_src_i(csr),
                .evt_valid_o(nv), .evt_axis_o(nax), .evt_phase_inc_o(nin),
                .evt_velocity_o(nve), .evt_kind_o(nkd),
                .evt_timbre_valid_o(ntv), .evt_timbre_o(ntb), .evt_src_o(nsr),
                .collision_cnt_o(ncol), .merged_cnt_o(nmer),
                .drop_cnt_o(ndrp), .overflow_o(novf)
            );

            evt_merge_ref #(.DEPTH(D)) u_ref (
                .clk_i(clk), .rst_n_i(rst_n),
                .a_valid_i(av), .a_axis_i(aax), .a_phase_inc_i(ain),
                .a_velocity_i(ave), .a_kind_i(akd), .a_timbre_valid_i(atv),
                .a_timbre_i(atb), .a_src_i(asr),
                .b_valid_i(bv), .b_axis_i(bax), .b_phase_inc_i(bin),
                .b_velocity_i(bve), .b_kind_i(bkd), .b_timbre_valid_i(btv),
                .b_timbre_i(btb), .b_src_i(bsr),
                .c_valid_i(cv), .c_axis_i(cax), .c_phase_inc_i(cin),
                .c_velocity_i(cve), .c_kind_i(ckd), .c_timbre_valid_i(ctv),
                .c_timbre_i(ctb), .c_src_i(csr),
                .evt_valid_o(rv), .evt_axis_o(rax), .evt_phase_inc_o(rin),
                .evt_velocity_o(rve), .evt_kind_o(rkd),
                .evt_timbre_valid_o(rtv), .evt_timbre_o(rtb), .evt_src_o(rsr),
                .collision_cnt_o(rcol), .merged_cnt_o(rmer),
                .drop_cnt_o(rdrp), .overflow_o(rovf)
            );

            // 把 12 组输出打成一条向量再比（顺序：valid/axis/inc/vel/kind/tv/tb/src/col/mer/drop/ovf）
            wire [126:0] pn = {nv, nax, nin, nve, nkd, ntv, ntb, nsr,
                               ncol, nmer, ndrp, novf};
            wire [126:0] pr = {rv, rax, rin, rve, rkd, rtv, rtb, rsr,
                               rcol, rmer, rdrp, rovf};

            always @(posedge clk) begin
                #1;                                  // 等 NBA 落定
                checks = checks + 1;
                if (rst_n && (pn !== pr)) begin
                    errors = errors + 1;
                    if (errors <= 12)
                        $display("  FAIL DEPTH=%0d: new=%h ref=%h", D, pn, pr);
                end
            end
        end
    endgenerate

    integer i;
    initial begin
        av = 0; bv = 0; cv = 0;
        aax = 0; bax = 0; cax = 0;
        ain = 0; bin = 0; cin = 0;
        ave = 0; bve = 0; cve = 0;
        akd = 0; bkd = 0; ckd = 0;
        atv = 0; btv = 0; ctv = 0;
        atb = 0; btb = 0; ctb = 0;
        asr = 3'd0; bsr = 3'd3; csr = 3'd4;      // ⭐ 与 top.v 的常数一致

        repeat (6) @(negedge clk);
        rst_n = 1;

        for (i = 0; i < CYCLES; i = i + 1) begin
            @(negedge clk);
            // ⭐ 三源都频繁来（含大量 2 路 / 3 路同拍）⇒ 覆盖推入/回绕/溢出/轮转
            av = ((($random % 1000) + 1000) % 1000) < 620;
            bv = ((($random % 1000) + 1000) % 1000) < 520;
            cv = ((($random % 1000) + 1000) % 1000) < 380;
            aax = $random; bax = $random; cax = $random;
            ain = $random; bin = $random; cin = $random;
            ave = $random; bve = $random; cve = $random;
            akd = $random; bkd = $random; ckd = $random;
            atv = $random; btv = $random; ctv = $random;
            atb = $random; btb = $random; ctb = $random;
            // 周期性全静默（覆盖空队列 / 不吐垃圾 / 只弹不推）
            if ((i % 811) == 0) begin av = 0; bv = 0; cv = 0; end
            // 周期性单源持续（覆盖溢出 sticky / drop_cnt 饱和路径）
            if ((i % 811) > 700) begin av = 1; bv = 1; cv = 1; end
        end

        repeat (60) @(negedge clk);
        $display("");
        $display("=== evt_merge 逐拍差分：DEPTH 2/3/4/6/9 × %0d 拍 ===", CYCLES);
        $display("    比较次数 = %0d   不一致 = %0d", checks, errors);
        if (errors == 0) begin
            $display("PASS: 新旧 evt_merge 在 5 种 DEPTH 下逐拍逐位相同（12 组输出）");
        end else begin
            $display("FAIL: %0d 处不一致 —— 减宽改变了行为", errors);
        end
        $finish;
    end

endmodule

`default_nettype wire
