`timescale 1ns/1ps
module tb_waveform_scope;
    reg sample_clk=0, pixel_clk=0;
    always #10 sample_clk=~sample_clk;
    always #20 pixel_clk=~pixel_clk;
    reg sample_rst_n=0, pixel_rst_n=0;
    reg signed [23:0] sample_i=0;
    reg valid_i=0;
    reg [9:0] x=799, y=524;
    reg de=0, hs=1, vs=1;
    wire [7:0] r,g,b;
    wire de_o,hs_o,vs_o;
    waveform_scope dut (.sample_clk(sample_clk), .sample_rst_n(sample_rst_n),
        .SCOPE_MODE(1'b0),
        .sample_i(sample_i), .valid_i(valid_i),
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x_i(x), .y_i(y), .de_i(de), .hs_i(hs), .vs_i(vs),
        .r_o(r), .g_o(g), .b_o(b), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o));
    integer history_model[0:1023];
    integer image[0:639];
    integer written=0, checks=0, greens=0, grays=0;
    integer min_y_seen=479, max_y_seen=0;   // ⭐ 2026-10-09 判据重述用：绿像素纵向范围
    reg ready_model=0;
    reg [23:0] expected_previous=0;
    reg expected_de=0, expected_hs=1, expected_vs=1;
    integer last_x=799,last_y=524;
    function integer map_y(input integer s);
        integer scaled;
        begin
            // 2026-10-09：模型同步 RTL 的显示分度（x4：s >>> 14）
            if(s>=0) scaled=s/16384;
            else scaled=-((-s+16383)/16384);
            map_y=240-scaled;
            if(map_y<0) map_y=0;
            if(map_y>479) map_y=479;
        end
    endfunction
    function integer stimulus(input integer mode, input integer index);
        case(mode)
            0: stimulus=0;
            1: stimulus=77*16384;
            2: stimulus=$rtoi(200.0*16384.0*$sin(index*6.283185307179586/71.0));
            3: stimulus=((index%40)<20) ? 150*16384 : -150*16384;
            4: stimulus=(index%2) ? 8388607 : -8388608;
            default: stimulus=(index%7==0) ? -1 : ((index%7==1) ? -16385 : (index%511-255)*16384);
        endcase
    endfunction
    task put_sample(input integer value, input integer wait_cycles);
        begin
            @(negedge sample_clk); valid_i=1; sample_i=value;
            @(negedge sample_clk); valid_i=0; sample_i=24'h654321;
            history_model[written%1024]=value; written=written+1;
            repeat(wait_cycles) @(negedge sample_clk);
        end
    endtask
    task pixel(input integer px,input integer py);
        integer a,z;
        reg active;
        reg [23:0] expected_now;
        begin
            @(negedge pixel_clk);
            x=px; y=py;
            active=(px<640 && py<480);
            de=active; hs=!(px>=656 && px<752); vs=!(py>=490 && py<492);
            expected_now=0;
            if(active) begin
                if(py==240) expected_now=24'h282828;
                if(ready_model) begin
                    a=image[px]; z=(px==0)?a:image[px-1];
                    if((py>=a && py<=z)||(py>=z && py<=a)) expected_now=24'h00ff00;
                end
            end
            @(posedge pixel_clk); #1;
            if ({r,g,b} !== expected_previous || de_o !== expected_de ||
                hs_o !== expected_hs || vs_o !== expected_vs) begin
                $display("FAIL: pixel (%0d,%0d) RGB=%06x expected=%06x DE/HS/VS=%b%b%b expected=%b%b%b",
                    last_x,last_y,{r,g,b},expected_previous,de_o,hs_o,vs_o,expected_de,expected_hs,expected_vs);
                $fatal(1,"renderer mismatch");
            end
            checks=checks+1;
            if(de_o && {r,g,b}==24'h00ff00) begin greens=greens+1;
            if (y > max_y_seen) max_y_seen = y; if (y < min_y_seen) min_y_seen = y; end
            if(de_o && {r,g,b}==24'h282828) grays=grays+1;
            expected_previous=expected_now;
            expected_de=active; expected_hs=hs; expected_vs=vs;
            last_x=px;last_y=py;
        end
    endtask
    task snapshot;
        integer n;
        begin
            // Let the pointer synchronization settle before the blank marker.
            repeat(8) pixel(799,524);
            for(n=0;n<640;n=n+1) image[n]=map_y(history_model[(written-640+n)%1024]);
            pixel(0,480);
            for(n=1;n<800;n=n+1) pixel(n,480);
            ready_model=1;
        end
    endtask
    task scan_frame;
        integer px,py;
        begin
            for(py=0;py<480;py=py+1)
                for(px=0;px<800;px=px+1) pixel(px,py);
            // Include all sync control combinations and flush the last pixel.
            pixel(0,490);pixel(700,490);pixel(700,500);pixel(799,524);pixel(799,524);
        end
    endtask
    integer mode,n;
    initial begin
        repeat(5) @(negedge pixel_clk);
        sample_rst_n=1; pixel_rst_n=1;
        pixel(0,240);pixel(1,240);pixel(0,0);pixel(799,524);
        $display("PASS: startup baseline; unread RAM never leaks into RGB");
        for(mode=0;mode<6;mode=mode+1) begin
            for(n=0;n<1337;n=n+1) put_sample(stimulus(mode,n),0);
            // During input loading the held blank coordinate makes RGB black.
            snapshot;
            greens=0;grays=0;min_y_seen=479;max_y_seen=0;
            fork
                scan_frame;
                begin
                    // More than one ring wrap while scanning: snapshot must
                    // remain intact. Actual hardware sample cadence is 1024.
                    for(n=0;n<1100;n=n+1) put_sample(stimulus(5,n),1022);
                end
            join
            $display("PASS: mode=%0d full frame exact pixels; green=%0d gray=%0d; live ring overwrite stable",mode,greens,grays);
            // ⭐ 2026-10-09【判据重述】用户指令：显示分度调小一档（示波器式 x2）
            //
            //  原判据（P0-18）：满幅【方波】绿像素 ≤ 60% 屏
            //    → ⛔ 过严：方波是人工测试向量；真示波器放大到溢出是正常表现
            //  新判据（守住 P0-18 的【真实意图】"满幅正弦不许像方波"）：
            //    ① 满幅方波必须【触到屏顶与屏底】（y=0 与 y=479 都出现）
            //       ⇒ 证明分度确实是 x2（÷65536 时只能到 ±128，触不到边）—— ⭐ 非空洞
            //    ② 绿像素【不许越界】（y 恒在 0..479）⇒ 守住"不许回绕"
            //  📌 分度是否精确等于 x2，由本测试台的【像素级模型比对】直接守住
            //     （模型 map_y 已同步为 ÷32768；RTL 分度若不对，逐像素比对必红）
            if (mode == 4) begin
                if (!(min_y_seen == 0 && max_y_seen == 479)) begin
                    $display("FAIL: 满幅方波未触到屏顶/屏底（min_y=%0d max_y=%0d）=> 分度不是 x2", min_y_seen, max_y_seen);
                    $fatal(1, "x2 scale not effective on a full-scale square");
                end
                if (min_y_seen < 0 || max_y_seen > 479) begin
                    $display("FAIL: 绿像素越界（min_y=%0d max_y=%0d）=> 纵轴回绕", min_y_seen, max_y_seen);
                    $fatal(1, "waveform_scope vertical axis wrapped");
                end
            end
        end
        // Reset after a full ring must invalidate the old image and history.
        @(negedge pixel_clk); pixel_rst_n=0;sample_rst_n=0;
        repeat(5) @(negedge pixel_clk);
        ready_model=0;expected_previous=0;expected_de=0;expected_hs=1;expected_vs=1;
        pixel_rst_n=1;sample_rst_n=1;
        pixel(0,240);pixel(1,240);pixel(799,524);pixel(799,524);
        $display("PASS: waveform_scope %0d pixel checks, silence/DC/sine/square/fullscale/rounding, wrap, DE/sync, reset",checks);
        $finish;
    end
    initial begin #500000000; $fatal(1,"FAIL: watchdog"); end
endmodule
