`timescale 1ns/1ps
`default_nettype none
module fx_top_audio_fixture #(
    parameter [7:0] MASK=0,
    parameter [15:0] GAIN=4096,
    parameter [15:0] TRIM=32768
)(input wire clk,rst_n,rx,output wire bck,ws,din,bck2,ws2,din2,tx);
    top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
        .PA_ON_AFTER_RESET(0),.PA_ON_DELAY(32),.DEMO_CHORD_ON(1),.SOURCE_A_SEL(1),
        .DEMO_NOTE_DELAY(2000),.DEMO_HOLD_CYC(1000000),.AUTOTARE_DELAY_CLK(10000000),
        .FX_EN_MASK(MASK),.FX_DIST_GAIN(GAIN),.FX_DIST_TRIM(TRIM),.FX_TREM_DEPTH(0)
    ) dut(.clk(clk),.rst_n(rst_n),.timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
        .spi_miso(6'b111111),.ctrl_col_i(4'b1111),.uart_rx(rx),.esp_uart_rx_i(1'b1),.uart_tx(tx),
        .HP_BCK(bck),.HP_WS(ws),.HP_DIN(din),.I2S2_BCK(bck2),.I2S2_LRCK(ws2),.I2S2_DIN(din2));
endmodule

module tb_top_fx_audio;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0,rx=1;
    wire [2:0] b,w,d,b2,w2,d2,tx;
    fx_top_audio_fixture #(.MASK(0)) dry(clk,rst_n,rx,b[0],w[0],d[0],b2[0],w2[0],d2[0],tx[0]);
    // Distortion at unity still traverses the real FX pipeline, unlike compile bypass.
    fx_top_audio_fixture #(.MASK(1),.GAIN(4096),.TRIM(32768)) unity(clk,rst_n,rx,b[1],w[1],d[1],b2[1],w2[1],d2[1],tx[1]);
    fx_top_audio_fixture #(.MASK(1),.GAIN(16384),.TRIM(32768)) driven(clk,rst_n,rx,b[2],w[2],d[2],b2[2],w2[2],d2[2],tx[2]);
    integer cycles=0,ones=0,changed=0,changed2=0;
    always @(negedge clk) if(rst_n) begin
        if(b!=={3{b[0]}} || w!=={3{w[0]}} || b2!=={3{b2[0]}} || w2!=={3{w2[0]}})
            $fatal(1,"FAIL FX changes public I2S clocks/frame schedule");
        if(tx!=={3{tx[0]}}) $fatal(1,"FAIL FX changes public UART response");
        if(d[0]!==d[1] || d2[0]!==d2[1]) $fatal(1,"FAIL FX unity changes public audio bits cycle=%0d",cycles);
        if(d[0]===1'b1) ones=ones+1;
        if(d[0]!==d[2]) changed=changed+1;
        if(d2[0]!==d2[2]) changed2=changed2+1;
        cycles=cycles+1;
    end
    task send_i;
        integer k; reg [7:0] value;
        begin
            value=8'h49; @(negedge clk); rx=0; repeat(100) @(negedge clk);
            for(k=0;k<8;k=k+1) begin rx=value[k]; repeat(100) @(negedge clk); end
            rx=1; repeat(200) @(negedge clk);
        end
    endtask
    initial begin
        repeat(20) @(negedge clk); rst_n=1;
        repeat(18000) @(negedge clk); send_i;
        repeat(60000) @(negedge clk);
        if(ones<100) $fatal(1,"FAIL FX audio comparison was vacuous silence");
        if(changed<100 || changed2<100) $fatal(1,"FAIL FX is not in real output path: board_diff=%0d external_diff=%0d",changed,changed2);
        $display("PASS: top FX public I2S/UART: %0d cycles unity bit-exact, board/external effect differences %0d/%0d, live ones=%0d",cycles,changed,changed2,ones);
        $finish;
    end
    initial begin #2500000; $fatal(1,"FAIL top FX audio timeout"); end
endmodule
`default_nettype wire
