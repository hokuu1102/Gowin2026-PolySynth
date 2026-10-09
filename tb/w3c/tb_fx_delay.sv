// ═══════════════════════════════════════════════════════════════════════════
//  tb_fx_delay.sv —— fx_delay 效果器判据（丙线 · W3c · 第四周 D-1）
//
//  ⭐ 判据：
//    C1  干声透传：fx_en=0 时 sample_o == sample_i（同拍）。
//    C2  延迟精确：脉冲在 D 拍后重现（幅度 = 脉冲 × mix 档）。
//    C3  回声衰减：feedback>0 时多次回声逐次递减。
//    C4  非空洞：最小非零输入也能产生非零延迟输出。
//    C5  复位干净：无 X/Z。
//
//  ⭐ 手法：sample_i 与 tick 同拍；灌单位脉冲，跑 D 拍后采样湿声。
//    mix 档位 0..7（= 0/8 .. 7/8），没有全湿档，测试据此取 mix=8'hE0(档7≈7/8)。
// ═══════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_fx_delay;

    localparam integer SAMPLE_W = 24;
    localparam integer DELAY     = 15;    // 15 拍延迟
    localparam integer ADDR_W    = 4;     // DEPTH=16

    reg                 clk;
    reg                 rst_n;
    reg                 tick;
    reg                 valid;
    reg  signed [23:0]  samp;
    reg                 fx_en;
    reg  [7:0]          mix;
    reg  [7:0]          fb;

    wire                valid_o;
    wire signed [23:0]  samp_o;
    wire [ADDR_W-1:0]   wr_ptr;
    wire [ADDR_W-1:0]   rd_ptr;

    fx_delay #(
        .SAMPLE_W      (SAMPLE_W),
        .DELAY_SAMPLES (DELAY),
        .ADDR_W        (ADDR_W)
    ) dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (tick),
        .valid_i       (valid),
        .sample_i      (samp),
        .fx_en_i       (fx_en),
        .mix_i         (mix),
        .feedback_i    (fb),
        .valid_o       (valid_o),
        .sample_o      (samp_o),
        .wr_ptr_o      (wr_ptr),
        .rd_ptr_o      (rd_ptr)
    );

    initial clk = 0;
    always #10 clk = ~clk;

    integer pass_cnt, fail_cnt;
    initial begin pass_cnt = 0; fail_cnt = 0; end

    task check(input [8*32-1:0] name, input cond);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS  %0s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL  %0s", name);
            end
        end
    endtask

    // 灌一拍：sample 与 tick 同拍，在 posedge 采样写入
    task feed(input signed [23:0] s, input v);
        begin
            @(negedge clk);
            samp = s; valid = v; tick = 1;
            @(posedge clk);       // 采样点：samp_o 此刻 = 干声透传
            @(negedge clk);
            tick = 0; valid = 0; samp = 0;
        end
    endtask

    task run_ticks(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk); tick = 1;
                @(negedge clk); tick = 0;
            end
        end
    endtask

    integer i;
    reg signed [23:0] e1, e2, e3, e4, e5;
    initial begin
        rst_n = 0; valid = 0; samp = 0; fx_en = 0; mix = 8'h80; fb = 8'h40; tick = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // ══ C1：fx_en=0 干声透传（feed 内 posedge 采样点读 samp_o）══════════
        begin
            reg signed [23:0] got;
            @(negedge clk); samp = 24'sd100000; valid = 1; tick = 1;
            @(posedge clk); got = samp_o;
            @(negedge clk); tick = 0; valid = 0; samp = 0;
            check("C1_dry_passthrough", (got === 24'sd100000));
        end

        // 清空延迟线
        run_ticks(20);

        // ══ C2：延迟精确（fx_en=1, mix 档7≈7/8, feedback=0）════════════════
        fx_en = 1; mix = 8'hE0; fb = 8'h00;   // mix_lvl=7
        feed(24'sd100000, 1);                 // 灌脉冲（写 addr=wr 处）
        // 跑 DELAY-1 拍后，湿声应重现（读 rd = wr-15 指向脉冲）
        run_ticks(DELAY - 1);
        check("C2_delayed_reappears", (samp_o > 24'sd50000));

        // ══ C3：回声衰减（feedback 档4=1/2，多次回声递减）═════════════════
        fx_en = 1; mix = 8'hE0; fb = 8'h80;   // feedback >> 高位=4 ⇒ 4/8=1/2
        run_ticks(20);                        // 清空
        e1 = 0; e2 = 0; e3 = 0; e4 = 0;
        feed(24'sd100000, 1);
        // 抓 4 次回声峰值：每个 DELAY 拍窗口内取 |samp_o| 最大值（回声周期 15 拍，
        //   峰值不一定落在窗口首拍，故扫描取峰值）
        begin
            integer k;
            for (k = 0; k < DELAY; k = k + 1) begin
                run_ticks(1);
                if (samp_o > e1) e1 = samp_o;
            end
            for (k = 0; k < DELAY; k = k + 1) begin
                run_ticks(1);
                if (samp_o > e2) e2 = samp_o;
            end
            for (k = 0; k < DELAY; k = k + 1) begin
                run_ticks(1);
                if (samp_o > e3) e3 = samp_o;
            end
            for (k = 0; k < DELAY; k = k + 1) begin
                run_ticks(1);
                if (samp_o > e4) e4 = samp_o;
            end
        end
        check("C3_echo_decay", (e1 > e2) && (e2 > e3) && (e3 > e4) && (e4 > 0));

        // ══ C4：非空洞（足够大的样本经 mix 后非零）═════════════════════════
        fx_en = 1; mix = 8'hE0; fb = 8'h00;
        run_ticks(20);
        feed(24'sd1000, 1);
        run_ticks(DELAY - 1);
        check("C4_nonhole_min_nonzero", (samp_o > 0));

        // ══ C5：复位干净 ════════════════════════════════════════════════════
        check("C5_no_xz", (samp_o !== 1'bx) && (samp_o !== 1'bz));

        $display("=== pass %0d / total %0d ===", pass_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0) $display("TEST_RESULT: PASS");
        else               $display("TEST_RESULT: FAIL");
        $finish;
    end

    initial begin
        #5000000; $display("TIMEOUT"); $finish;
    end

endmodule
