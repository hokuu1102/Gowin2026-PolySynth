`timescale 1ns/1ps
`default_nettype none
module runtime_fx_fixture(input wire clk,rst_n,rx,
    output wire bck,ws,din,bck2,ws2,din2);
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .PA_ON_AFTER_RESET(0),.PA_ON_DELAY(32),.DEMO_CHORD_ON(1),.SOURCE_A_SEL(1),
    .DEMO_NOTE_DELAY(2000),.DEMO_HOLD_CYC(1000000),.AUTOTARE_DELAY_CLK(10000000),
    .FX_EN_MASK(0),.FX_DIST_GAIN(16384),.FX_DIST_TRIM(32768),.FX_TREM_DEPTH(0)) dut(
    .clk(clk),.rst_n(rst_n),.timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .spi_miso(6'b111111),.ctrl_col_i(4'b1111),.uart_rx(rx),.esp_uart_rx_i(1'b1),
    .HP_BCK(bck),.HP_WS(ws),.HP_DIN(din),.I2S2_BCK(bck2),.I2S2_LRCK(ws2),.I2S2_DIN(din2));
endmodule
module tb_top_fx_runtime;
  reg clk=0;always #10 clk=~clk;
  reg rst_n=0,rx=1;
  wire [1:0] b,w,d,b2,w2,d2;
  runtime_fx_fixture dry(clk,rst_n,1'b1,b[0],w[0],d[0],b2[0],w2[0],d2[0]);
  runtime_fx_fixture live(clk,rst_n,rx,b[1],w[1],d[1],b2[1],w2[1],d2[1]);
  integer phase=0,diff=0,diff2=0,ones=0;
  always @(negedge clk) if(rst_n) begin
    if(b[0]!==b[1]||w[0]!==w[1]||b2[0]!==b2[1]||w2[0]!==w2[1])
      $fatal(1,"runtime FX changed I2S clocks");
    if(phase==1||phase==3) begin
      if(d[0]!==d[1]||d2[0]!==d2[1])$fatal(1,"runtime bypass was not bit-identical");
      if(d[0]===1'b1)ones=ones+1;
    end
    if(phase==2)begin
      if(d[0]!==d[1])diff=diff+1;
      if(d2[0]!==d2[1])diff2=diff2+1;
    end
  end
  task byte_out(input [7:0] value);
    integer k;
    begin
      @(negedge clk);rx=0;repeat(100)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(100)@(negedge clk);end
      rx=1;repeat(100)@(negedge clk);
    end
  endtask
  task mask_out(input [7:0] value);
    begin byte_out(8'h71);byte_out(8'h10);byte_out(value);
      byte_out(8'hff);byte_out(8'hff);byte_out(8'hff);end
  endtask
  initial begin
    repeat(20)@(negedge clk);rst_n=1;
    repeat(18000)@(negedge clk);phase=1;repeat(16000)@(negedge clk);
    phase=0;mask_out(1);
    if(live.dut.ui_fx_mask!==8'h01)$fatal(1,"UART did not enable runtime FX");
    repeat(5000)@(negedge clk);phase=2;repeat(45000)@(negedge clk);
    if(diff<100||diff2<100)$fatal(1,"runtime FX did not reach both public audio outputs");
    phase=0;mask_out(0);
    if(live.dut.ui_fx_mask!==0)$fatal(1,"UART did not disable runtime FX");
    repeat(5000)@(negedge clk);phase=3;repeat(16000)@(negedge clk);
    if(ones<100)$fatal(1,"runtime bypass comparison was silent/vacuous");
    $display("PASS: default firmware UART FX enable/disable, public I2S differences %0d/%0d, bypass bit-exact",diff,diff2);
    $finish;
  end
  initial begin #4000000;$fatal(1,"runtime FX simulation deadline");end
endmodule
`default_nettype wire
