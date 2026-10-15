`timescale 1ns/1ps
`default_nettype none
module tb_top_fx_all;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0;
    wire bd,wd,dd,bf,wf,df,b2d,w2d,d2d,b2f,w2f,d2f;
    top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),.PA_ON_AFTER_RESET(0),
        .DEMO_CHORD_ON(1),.SOURCE_A_SEL(1),.DEMO_NOTE_DELAY(2000),
        .DEMO_HOLD_CYC(1000000),.AUTOTARE_DELAY_CLK(10000000),.FX_EN_MASK(0),.FX_TREM_DEPTH(0)
    ) dry(.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.esp_uart_rx_i(1'b1),.spi_miso(6'b111111),
        .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),.ctrl_col_i(4'b1111),
        .HP_BCK(bd),.HP_WS(wd),.HP_DIN(dd),.I2S2_BCK(b2d),.I2S2_LRCK(w2d),.I2S2_DIN(d2d));
    // Same FX settings as the sealed all-effects physical build, including depth128.
    top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),.PA_ON_AFTER_RESET(0),
        .DEMO_CHORD_ON(1),.SOURCE_A_SEL(1),.DEMO_NOTE_DELAY(2000),
        .DEMO_HOLD_CYC(1000000),.AUTOTARE_DELAY_CLK(10000000),.FX_EN_MASK(7),.FX_TREM_DEPTH(128)
    ) wet(.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.esp_uart_rx_i(1'b1),.spi_miso(6'b111111),
        .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),.ctrl_col_i(4'b1111),
        .HP_BCK(bf),.HP_WS(wf),.HP_DIN(df),.I2S2_BCK(b2f),.I2S2_LRCK(w2f),.I2S2_DIN(d2f));
    integer differences=0,differences2=0,wet_ones=0,cycles=0;
    always @(negedge clk) if(rst_n) begin
        if({bd,wd,b2d,w2d}!=={bf,wf,b2f,w2f}) $fatal(1,"FAIL all-effects changes public audio clocks");
        if(dd!==df) differences=differences+1;
        if(d2d!==d2f) differences2=differences2+1;
        if(df===1'b1) wet_ones=wet_ones+1;
        if((^{df,d2f})===1'bx) $fatal(1,"FAIL all-effects public DIN X/Z");
        cycles=cycles+1;
    end
    initial begin
        repeat(20) @(negedge clk); rst_n=1;
        repeat(80000) @(negedge clk);
        if(differences<100 || differences2<100 || wet_ones<100)
            $fatal(1,"FAIL all-effects vacuous/no audio: differences=%0d/%0d wet_ones=%0d",differences,differences2,wet_ones);
        $display("PASS: actual top all-effects mask7/depth128 produces live nonidentical board/external I2S, %0d cycles, differences=%0d/%0d wet_ones=%0d",cycles,differences,differences2,wet_ones);
        $finish;
    end
    initial begin #2500000; $fatal(1,"FAIL all-effects top timeout"); end
endmodule
`default_nettype wire
