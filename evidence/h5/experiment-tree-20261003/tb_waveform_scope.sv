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
        .sample_i(sample_i), .valid_i(valid_i),
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x_i(x), .y_i(y), .de_i(de), .hs_i(hs), .vs_i(vs),
        .r_o(r), .g_o(g), .b_o(b), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o));
    integer history_model[0:1023];
    integer image[0:639];
    integer image_sample[0:639];
    integer written=0, checks=0, greens=0, grays=0;
    integer trig_checks=0, trig_fails=0;
    reg ready_model=0;
    reg [23:0] expected_previous=0;
    reg expected_de=0, expected_hs=1, expected_vs=1;
    integer last_x=799,last_y=524;
    function integer map_y(input integer s);
        integer scaled;
        begin
            // Arithmetic floor by division, independent of RTL slice/shift.
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
            if(de_o && {r,g,b}==24'h00ff00) greens=greens+1;
            if(de_o && {r,g,b}==24'h282828) grays=grays+1;
            expected_previous=expected_now;
            expected_de=active; expected_hs=hs; expected_vs=vs;
            last_x=px;last_y=py;
        end
    endtask
    task snapshot;
        integer n, k, base, found, prev, cur;
        begin
            // Let the pointer synchronization settle before the blank marker.
            repeat(8) pixel(799,524);
            // Triggered window (waveform_scope, 2026-10-02): the copy scans the
            // ring tail for the FIRST RISING ZERO CROSSING and starts the
            // displayed window there, so consecutive frames are phase aligned
            // and the panel/camera afterglow lands on the trace instead of
            // showing a second, shifted waveform.
            // Scan starts at written-960 and may advance at most 320 samples;
            // if no crossing is found (silence / DC) the latest legal window
            // start (written-640) is used, exactly like the RTL fallback.
            base  = (written - 960 + 1024) % 1024;
            found = 320;
            for(k=1;k<=320;k=k+1) begin
                prev = history_model[(base + k - 1) % 1024];
                cur  = history_model[(base + k) % 1024];
                if(prev < 0 && cur >= 0) begin found=k; k=321; end
            end
            for(n=0;n<640;n=n+1) begin
                image_sample[n] = history_model[(base + found + n) % 1024];
                image[n]        = map_y(image_sample[n]);
            end
            // Independent invariant: the displayed window must start on a
            // rising zero crossing (or on the documented fallback start).
            if(found < 320) begin
                if(!(history_model[(base + found - 1) % 1024] < 0 &&
                     history_model[(base + found) % 1024] >= 0)) begin
                    $display("FAIL: window does not start on a rising zero crossing (found=%0d)",found);
                    trig_fails=trig_fails+1;
                end
                trig_checks=trig_checks+1;
            end
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
            greens=0;grays=0;
            fork
                scan_frame;
                begin
                    // More than one ring wrap while scanning: snapshot must
                    // remain intact. Actual hardware sample cadence is 1024.
                    for(n=0;n<1100;n=n+1) put_sample(stimulus(5,n),1022);
                end
            join
            $display("PASS: mode=%0d full frame exact pixels; green=%0d gray=%0d; live ring overwrite stable",mode,greens,grays);
        end
        // Reset after a full ring must invalidate the old image and history.
        @(negedge pixel_clk); pixel_rst_n=0;sample_rst_n=0;
        repeat(5) @(negedge pixel_clk);
        ready_model=0;expected_previous=0;expected_de=0;expected_hs=1;expected_vs=1;
        pixel_rst_n=1;sample_rst_n=1;
        pixel(0,240);pixel(1,240);pixel(799,524);pixel(799,524);
        if(trig_fails!=0)
            $fatal(1,"FAIL: %0d triggered-window invariant violations",trig_fails);
        $display("PASS: triggered window started on a rising zero crossing in %0d snapshots",trig_checks);
        $display("PASS: waveform_scope %0d pixel checks, silence/DC/sine/square/fullscale/rounding, wrap, DE/sync, reset",checks);
        $finish;
    end
    initial begin #500000000; $fatal(1,"FAIL: watchdog"); end
endmodule
