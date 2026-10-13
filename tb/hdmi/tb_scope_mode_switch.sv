`timescale 1ns/1ps
module tb_scope_mode_switch;
    reg sample_clk=0,pixel_clk=0,rst_n=0,mode=1,valid=0;
    always #10 sample_clk=~sample_clk;
    always #20 pixel_clk=~pixel_clk;
    reg [9:0] x=1,y=479;
    reg de=0;
    wire [7:0] r,g,b;
    wire deo,hso,vso;
    integer i,errors=0;
    waveform_scope dut (
        .sample_clk(sample_clk),.sample_rst_n(rst_n),.SCOPE_MODE(mode),
        .sample_i(24'sd1261568),.valid_i(valid),
        .pixel_clk(pixel_clk),.pixel_rst_n(rst_n),
        .x_i(x),.y_i(y),.de_i(de),.hs_i(1'b1),.vs_i(1'b1),
        .r_o(r),.g_o(g),.b_o(b),.de_o(deo),.hs_o(hso),.vs_o(vso));
    task blank;
        begin
            @(negedge pixel_clk);de=0;x=0;y=480;
            @(negedge pixel_clk);x=1;
            repeat(35000) @(negedge pixel_clk);
        end
    endtask
    task probe(input integer px,input integer py,input [23:0] expected);
        begin
            @(negedge pixel_clk);x=px;y=py;de=1;
            repeat(4) @(negedge pixel_clk);
            if({r,g,b}!==expected) begin
                $display("FAIL: mode=%b pixel(%0d,%0d) got=%h expected=%h",mode,px,py,{r,g,b},expected);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(8) @(negedge sample_clk);rst_n=1;
        for(i=0;i<1024;i=i+1) begin
            @(negedge sample_clk);valid=1;
            @(negedge sample_clk);valid=0;
        end
        repeat(12) @(negedge pixel_clk);
        @(negedge pixel_clk);de=0;x=0;y=480;
        @(negedge pixel_clk);x=1;
        repeat(11000) @(negedge pixel_clk);
        // Request waveform after clearing, while XY plotting is in flight.
        // It must finish the old frame instead of freezing a write condition.
        mode=0;
        repeat(24000) @(negedge pixel_clk);
        probe(320,100,24'h282828); // XY centre cross.
        probe(474,95,24'h00ff00); // Known positive-DC XY point at gain 8.
        // The request must not change the current frame's renderer.
        repeat(12) @(negedge pixel_clk);
        probe(320,100,24'h282828);
        blank;
        probe(300,163,24'h00ff00); // 240 - 77 = 163, positive DC trace.
        probe(320,100,24'h000000); // No vertical cross in waveform mode.
        @(negedge pixel_clk);mode=1;
        repeat(12) @(negedge pixel_clk);
        probe(300,163,24'h00ff00);
        blank;
        probe(320,100,24'h282828);
        if(errors) $fatal(1,"FAIL: frame-atomic mode switching errors=%0d",errors);
        $display("PASS: XY/waveform/XY switch at frame boundaries and waveform displays real samples");
        $finish;
    end
    initial begin #6000000;$fatal(1,"FAIL: scope mode test timeout");end
endmodule
