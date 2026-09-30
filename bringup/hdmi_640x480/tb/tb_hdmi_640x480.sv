`timescale 1ns/1ps
module tb_hdmi_640x480;
    localparam H_ACTIVE=640, H_FP=16, H_SYNC=96, H_BP=48, H_TOTAL=800;
    localparam V_ACTIVE=480, V_FP=10, V_SYNC=2, V_BP=33, V_TOTAL=525;
    reg clk=0, rst_n=0;
    always #20 clk=~clk;
    wire [9:0] x,y;
    wire de, hs, vs;
    wire [7:0] r,g,b;
    wire [9:0] sr,sg,sb;
    wire dr,dg,db, hr,vr,hg,vg,hb,vb,okr,okg,okb;
    wire [7:0] rr,rg,rb;
    reg [7:0] sweep_data=0;
    reg sweep_de=0;
    wire [9:0] sweep_symbol;
    wire sweep_out_de, sweep_c0, sweep_c1, sweep_valid;
    wire [7:0] sweep_decoded;
    integer xx,yy,k, active_pixels, active_lines, hs_low, vs_low_lines;
    reg exp_de, exp_hs, exp_vs;
    reg [23:0] exp_rgb;
    reg [9:0] exp_blue_token;
    integer bal_r=0, bal_g=0, bal_b=0;
    reg prev_dd = 0;
    function integer ones10;
        input [9:0] s;
        integer j;
        begin
            ones10=0;
            for (j=0;j<10;j=j+1) ones10=ones10+s[j];
        end
    endfunction
    video_timing u_timing (.clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),.hsync(hs),.vsync(vs));
    color_bars u_bars (.x(x),.de(de),.r(r),.g(g),.b(b));
    tmds_encoder u_r (.clk(clk),.rst_n(rst_n),.data(r),.de(de),.c0(1'b0),.c1(1'b0),.symbol(sr));
    tmds_encoder u_g (.clk(clk),.rst_n(rst_n),.data(g),.de(de),.c0(1'b0),.c1(1'b0),.symbol(sg));
    tmds_encoder u_b (.clk(clk),.rst_n(rst_n),.data(b),.de(de),.c0(hs),.c1(vs),.symbol(sb));
    tmds_decoder d_r (.symbol(sr),.de(dr),.c0(hr),.c1(vr),.data(rr),.valid(okr));
    tmds_decoder d_g (.symbol(sg),.de(dg),.c0(hg),.c1(vg),.data(rg),.valid(okg));
    tmds_decoder d_b (.symbol(sb),.de(db),.c0(hb),.c1(vb),.data(rb),.valid(okb));
    tmds_encoder u_sweep (.clk(clk),.rst_n(rst_n),.data(sweep_data),.de(sweep_de),.c0(1'b0),.c1(1'b0),.symbol(sweep_symbol));
    tmds_decoder d_sweep (.symbol(sweep_symbol),.de(sweep_out_de),.c0(sweep_c0),.c1(sweep_c1),.data(sweep_decoded),.valid(sweep_valid));
    function [23:0] bar;
        input integer px;
        begin
            if      (px < 80)  bar=24'hffffff;
            else if (px < 160) bar=24'hffff00;
            else if (px < 240) bar=24'h00ffff;
            else if (px < 320) bar=24'h00ff00;
            else if (px < 400) bar=24'hff00ff;
            else if (px < 480) bar=24'hff0000;
            else if (px < 560) bar=24'h0000ff;
            else               bar=24'h000000;
        end
    endfunction
    function [9:0] token;
        input h,v;
        begin
            case ({v,h})
                2'b00: token=10'b1101010100;
                2'b01: token=10'b0101010100;
                2'b10: token=10'b0010101011;
                2'b11: token=10'b1010101011;
            endcase
        end
    endfunction
    task fail;
        input [255:0] name;
        begin $display("FAIL %0s x=%0d y=%0d",name,xx,yy); $fatal(1); end
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst_n=1;
        active_pixels=0; active_lines=0; vs_low_lines=0;
        for (yy=0; yy<V_TOTAL; yy=yy+1) begin
            hs_low=0;
            for (xx=0; xx<H_TOTAL; xx=xx+1) begin
                #1;
                exp_de=(xx<H_ACTIVE && yy<V_ACTIVE);
                exp_hs=!(xx>=H_ACTIVE+H_FP && xx<H_ACTIVE+H_FP+H_SYNC);
                exp_vs=!(yy>=V_ACTIVE+V_FP && yy<V_ACTIVE+V_FP+V_SYNC);
                exp_rgb=exp_de ? bar(xx) : 24'h000000;
                if (x!==xx || y!==yy) fail("TIMING_COUNT");
                if (de!==exp_de || hs!==exp_hs || vs!==exp_vs) fail("SYNC_POLARITY_DE");
                if ({r,g,b}!==exp_rgb) fail("COLOR_BAR");
                if (!hs) hs_low=hs_low+1;
                if (de) active_pixels=active_pixels+1;
                @(posedge clk); #1;
                if (!okr || !okg || !okb) fail("TMDS_SYMBOL_VALID");
                // Output-observable DC balance, ACTIVE pixels only.
                // Control tokens are checked separately and the encoder resets
                // its disparity
                // during blanking, so the accumulator restarts at each active
                // region. This reads only emitted symbols, never the DUT's
                // internal disparity register, so a broken disparity update
                // that a self-referential bound would miss is caught here.
                if (dr && !prev_dd) begin bal_r = 0; bal_g = 0; bal_b = 0; end
                prev_dd = dr;
                if (dr) begin
                    bal_r = bal_r + (2*ones10(sr) - 10);
                    bal_g = bal_g + (2*ones10(sg) - 10);
                    bal_b = bal_b + (2*ones10(sb) - 10);
                    if (bal_r > 8 || bal_r < -8 || bal_g > 8 || bal_g < -8 ||
                        bal_b > 8 || bal_b < -8) fail("TMDS_DC_BALANCE");
                end
                if (exp_de) begin
                    if (!dr || !dg || !db || {rr,rg,rb}!==exp_rgb) fail("TMDS_PIXEL_ROUNDTRIP");
                    if (u_r.disparity > 8 || u_r.disparity < -8 ||
                        u_g.disparity > 8 || u_g.disparity < -8 ||
                        u_b.disparity > 8 || u_b.disparity < -8) fail("TMDS_DISPARITY");
                end else begin
                    exp_blue_token=token(exp_hs,exp_vs);
                    if (dr || dg || db || hb!==exp_hs || vb!==exp_vs ||
                        hr || vr || hg || vg || sb!==exp_blue_token ||
                        sr!==10'b1101010100 || sg!==10'b1101010100)
                        fail("TMDS_CONTROL_TOKEN");
                    if (u_r.disparity!==0 || u_g.disparity!==0 || u_b.disparity!==0)
                        fail("TMDS_BLANK_RESET");
                end
                @(negedge clk);
            end
            if (hs_low!=H_SYNC) fail("HSYNC_WIDTH");
            if (yy<V_ACTIVE) active_lines=active_lines+1;
            if (yy>=V_ACTIVE+V_FP && yy<V_ACTIVE+V_FP+V_SYNC) vs_low_lines=vs_low_lines+1;
        end
        if (x!==0 || y!==0 || active_pixels!==H_ACTIVE*V_ACTIVE ||
            active_lines!==V_ACTIVE || vs_low_lines!==V_SYNC) fail("FRAME_DIMENSIONS");
        for (k=0; k<256; k=k+1) begin
            sweep_data=k; sweep_de=1;
            @(posedge clk); #1;
            if (!sweep_valid || !sweep_out_de || sweep_decoded!==k[7:0]) fail("TMDS_256_ROUNDTRIP");
            if (u_sweep.disparity > 8 || u_sweep.disparity < -8) fail("TMDS_SWEEP_DISPARITY");
            @(negedge clk);
        end
        $display("PASS frame=%0d pixels=%0d lines=%0d sweep=256",H_TOTAL*V_TOTAL,active_pixels,active_lines);
        $finish;
    end
endmodule
