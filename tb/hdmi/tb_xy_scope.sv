`timescale 1ns/1ps
// tb_xy_scope.sv -- 李萨如（XY）显示验收（SCOPE_MODE=1）
//
// 依据 files/20-代码/李萨如显示-设计-20261009.md 第七节。
// 验证方式：直接读 DUT 内部的 XY 帧缓冲（层次引用，与本工程既有 tb 风格一致），
// 统计"被点亮的像素"的包围盒与数量 —— ⛔ 不需要逐像素回读整屏。
//
// 四条判据：
//   ① 单频正弦 ⇒ 点云构成【闭合椭圆】：X/Y 跨度都够大、点数够多
//   ② 直流     ⇒ 所有点【塌成一点】：点数极少
//   ③ 满幅方波 ⇒ Y 必须【触到 0 与 239 两条边】（映射 + 饱和夹取生效）
//   ④ 非空洞   ⇒ ① 与 ② 的点数必须【差一个数量级以上】（否则判据没在测东西）
module tb_xy_scope;
    localparam integer FB_WPR = 20;    // ⭐ 640/32 = 每行字数（32 像素/字）
    localparam integer FB_N  = 9600;

    reg sample_clk = 0, sample_rst_n = 0;
    reg pixel_clk  = 0, pixel_rst_n  = 0;
    reg signed [23:0] sample_i = 0;
    reg valid_i = 0;
    reg [9:0] x_i = 0, y_i = 0;
    reg de_i = 0, hs_i = 1, vs_i = 1;
    wire [7:0] r_o, g_o, b_o;
    wire de_o, hs_o, vs_o;

    integer errors = 0, checks = 0;

    waveform_scope #(.XY_DELAY(64), .XY_GAIN(8)) dut (
        .sample_clk(sample_clk), .sample_rst_n(sample_rst_n),
        .SCOPE_MODE(1'b1),
        .sample_i(sample_i), .valid_i(valid_i),
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x_i(x_i), .y_i(y_i), .de_i(de_i), .hs_i(hs_i), .vs_i(vs_i),
        .r_o(r_o), .g_o(g_o), .b_o(b_o), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o));

    always #10 sample_clk = ~sample_clk;      // 50 MHz
    always #20 pixel_clk  = ~pixel_clk;       // 25 MHz

    task chk(input [8*80-1:0] name, input cond);
        begin
            checks = checks + 1;
            if (!cond) begin errors = errors + 1; $display("  FAIL: %0s", name); end
            else $display("  ok  : %0s", name);
        end
    endtask

    // ── 视频时序（640×480 有效 / 800×525 总）───────────────────────────────
    //  ⚠️ 用【阻塞赋值】：计数器在 negedge 立即更新，等待循环才能看到新值
    //     （⛔ 若用非阻塞，while 条件会慢一拍 ⇒ 容易写出死等）
    task step_pixel;
        begin
            @(negedge pixel_clk);
            if (x_i == 799) begin
                x_i = 0;
                y_i = (y_i == 524) ? 10'd0 : (y_i + 10'd1);
            end else x_i = x_i + 10'd1;
            de_i = (x_i < 640) && (y_i < 480);
            hs_i = ~((x_i >= 656) && (x_i < 752));
            vs_i = ~((y_i >= 490) && (y_i < 492));
        end
    endtask

    task run_pixels(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) step_pixel;
        end
    endtask

    // ── 激励 ───────────────────────────────────────────────────────────────
    integer m, n, d;
    reg signed [23:0] v;
    task feed(input integer mode, input integer count);
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                case (mode)
                    //  ⭐ 周期取 640 = 窗口长度 ⇒ 窗口内正好【一个完整周期】、画出一条完整闭合椭圆
                    //     ⚠️ 幅度要让椭圆【不削边】：XY_GAIN=4 时 2e6 给出 X 跨度 244、Y 跨度 228
                    //        （用 8e6 会削到边缘 ⇒ 测不出"椭圆形状"，只测到夹取）
                    0: v = $rtoi(2_000_000.0 * $sin(i * 6.283185307179586 / 640.0)); // 正弦，周期 640
                    1: v = 24'sd500_000;                                              // 直流
                    2: v = (i % 2) ? 24'sd8_388_607 : -24'sd8_388_608;                // 满幅方波
                    //  ⭐ 快信号：周期 20 ⇒ 相邻样本跳 ~38 帧缓冲像素
                    //     ⚠️ 周期必须与 XY_DELAY(64) 不成整数比，否则 Y=X 退化成对角线
                    //     · 640 样本 = 32 个周期 ⇒ 只有 20 个【不同相位点】
                    //     · ⛔ 无连线：最多 ~20 个像素；✅ 有连线：每段补 ≤12 px ⇒ ~240
                    3: v = $rtoi(2_000_000.0 * $sin(i * 6.283185307179586 / 20.0));
                    default: v = 0;
                endcase
                @(negedge sample_clk); valid_i = 1; sample_i = v;
                @(negedge sample_clk); valid_i = 0;
            end
        end
    endtask

    // ── 统计帧缓冲 ─────────────────────────────────────────────────────────
    integer set_cnt, min_x, max_x, min_y, max_y, idx, bx, by, bit_i;
    reg [31:0] word_v;
    task scan_fb;
        begin
            set_cnt = 0; min_x = 9999; max_x = -1; min_y = 9999; max_y = -1;
            for (idx = 0; idx < FB_N; idx = idx + 1) begin
                word_v = dut.xy_fb[idx];
                if (word_v != 32'h0) begin
                    by = idx / FB_WPR;
                    bx = (idx % FB_WPR) * 32;
                    for (bit_i = 0; bit_i < 32; bit_i = bit_i + 1) begin
                        if (word_v[bit_i]) begin
                            set_cnt = set_cnt + 1;
                            if (bx + bit_i < min_x) min_x = bx + bit_i;
                            if (bx + bit_i > max_x) max_x = bx + bit_i;
                            if (by < min_y) min_y = by;
                            if (by > max_y) max_y = by;
                        end
                    end
                end
            end
        end
    endtask

    // ── 一次完整的"喂样本 → 等 vblank → 等打点完成 → 统计" ────────────────
    //  ⚠️ 一帧 = 800×525 = 420,000 拍 ⇒ ⛔ 不能用"跑固定几千拍"来碰 vblank，
    //     必须【显式等】`x_i==0 && y_i==480`（打点 FSM 的启动条件）
    task wait_vblank;
        begin
            while (!dut.full_sync) @(negedge pixel_clk);          // 等 CDC 就绪
            // ⭐ 必须【自己推进像素】去等 —— 计数器只在 step_pixel 里动
            while (!((x_i == 0) && (y_i == 480))) step_pixel;
            step_pixel;                                           // 让 vblank_start 被采样
        end
    endtask

    task run_case(input integer mode);
        begin
            feed(mode, 2048);                    // 灌满环形缓冲（> 1024）
            wait_vblank;                         // 打点 FSM 在此启动
            run_pixels(20000);                   // 清屏 9600 + 打点 640×6 ≈ 13440 ⇒ 留足
            scan_fb;
        end
    endtask

    initial begin
        sample_rst_n = 0; pixel_rst_n = 0;
        repeat (10) @(negedge pixel_clk);
        sample_rst_n = 1; pixel_rst_n = 1;
        x_i = 0; y_i = 479;                       // 从有效行末尾起，下一步进 vblank

        $display("== 李萨如（XY）显示验收：SCOPE_MODE=1, XY_DELAY=64 ==");

        // ① 单频正弦 ⇒ 闭合椭圆
        run_case(0);
        $display("     [xy] sine  : set=%0d  x=[%0d,%0d]  y=[%0d,%0d]", set_cnt, min_x, max_x, min_y, max_y);
        chk("sine: point cloud spans a wide X range (>=150 px)", (max_x - min_x) >= 150);
        chk("sine: point cloud spans a wide Y range (>=100 px)", (max_y - min_y) >= 100);
        chk("sine: enough points to form a curve (>=200)", set_cnt >= 200);
        m = set_cnt;                               // 记下来给判据④

        // ② 直流 ⇒ 塌成一点
        run_case(1);
        $display("     [xy] dc    : set=%0d  x=[%0d,%0d]  y=[%0d,%0d]", set_cnt, min_x, max_x, min_y, max_y);
        chk("dc: all points collapse (<=4 pixels)", set_cnt <= 4);
        d = set_cnt;                                   // ⭐ 记下直流点数给非空洞判据用

        // ③ 满幅方波 ⇒ 必须触到【两个轴的四条边】（映射 + 饱和夹取生效）
        //    ⭐ XY_GAIN=4 后满幅会削到帧缓冲边缘 ⇒ 夹取在 X/Y 两轴都被激发（判据更强）
        run_case(2);
        $display("     [xy] square: set=%0d  x=[%0d,%0d]  y=[%0d,%0d]", set_cnt, min_x, max_x, min_y, max_y);
        chk("full-scale square: reaches BOTH Y edges (0 and 479)", (min_y == 0) && (max_y == 479));
        chk("full-scale square: reaches BOTH X edges (0 and 639)", (min_x == 0) && (max_x == 639));

        // ④ ⭐⭐ 快信号 ⇒ 必须靠【连线】补出大量像素（这条才是真正验"连线"的判据）
        //    · 周期 20、窗口 640 ⇒ 只有 **20 个不同相位点**
        //    🔴 没有连线 ⇒ 帧缓冲里最多 ~20 个像素
        //    ✅ 有连线   ⇒ 每段补 ≤12 px ⇒ ~240 个像素（差一个数量级）
        run_case(3);
        $display("     [xy] fast  : set=%0d  x=[%0d,%0d]  y=[%0d,%0d]", set_cnt, min_x, max_x, min_y, max_y);
        chk("fast signal: LINE DRAWING fills gaps (set >= 150; no-line would be ~20)", set_cnt >= 150);

        // ⑤ 非空洞：正弦的点数必须远多于直流
        $display("     [xy] sine set=%0d  vs  dc set=%0d", m, d);
        chk("non-vacuous: sine point count >> dc point count (>=20x)", m >= 20 * d);

        if (errors == 0) $display("PASS: xy_scope acceptance (%0d checks) - all judgements held", checks);
        else             $fatal(1, "FAIL: xy_scope acceptance has %0d error(s)", errors);
        #200; $finish;
    end
    initial begin #200000000; $fatal(1, "FAIL: watchdog"); end
endmodule
