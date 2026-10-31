`timescale 1ns/1ps
module tb_fft_top_modes;
 reg clk=0,rst=0,rx=1;
 always #10 clk=~clk;
 wire b0,w0,d0,t0,b1,w1,d1,t1;
 top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.DEMO_NOTE_DELAY(2000),
  .DEMO_HOLD_CYC(10000000),.AUTOTARE_DELAY_CLK(10000000)) baseline(
  .clk(clk),.rst_n(rst),.uart_rx(rx),.esp_uart_rx_i(1'b1),.uart_tx(t0),
  .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),.spi_miso(6'b111111),
  .HP_BCK(b0),.HP_WS(w0),.HP_DIN(d0));
 top #(.SCOPE_MODE(0),.FFT_ENABLE(1),.DEMO_NOTE_DELAY(2000),
  .DEMO_HOLD_CYC(10000000),.AUTOTARE_DELAY_CLK(10000000)) fft_top(
  .clk(clk),.rst_n(rst),.uart_rx(rx),.esp_uart_rx_i(1'b1),.uart_tx(t1),
  .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),.spi_miso(6'b111111),
  .HP_BCK(b1),.HP_WS(w1),.HP_DIN(d1));
 integer cycles=0,ones=0;
 always @(negedge clk) if(rst)begin
  if({b0,w0,d0,t0}!=={b1,w1,d1,t1})$fatal(1,"FAIL: FFT changes public audio/UART cycle %0d",cycles);
  cycles=cycles+1;if(d1)ones=ones+1;
 end
 task send_e;
  integer k;
  reg [7:0] value;
  begin
   // 115200 board UART: 434 clk/bit (2026-10-28 re-baud, tb adapted)
   value=8'h45;@(negedge clk);rx=0;repeat(434)@(negedge clk);
   for(k=0;k<8;k=k+1)begin rx=value[k];repeat(434)@(negedge clk);end
   rx=1;repeat(4000)@(negedge clk);
  end
 endtask
 initial begin
  repeat(20)@(negedge clk);rst=1;repeat(3000)@(negedge clk);
  send_e;
  if(fft_top.u_hdmi.SCOPE_MODE!==1 || fft_top.u_hdmi.FFT_MODE!==0)
   $fatal(1,"FAIL: E first selects XY");
  send_e;
  if(fft_top.u_hdmi.SCOPE_MODE!==0 || fft_top.u_hdmi.FFT_MODE!==1)
   $fatal(1,"FAIL: E second selects FFT");
  send_e;
  if(fft_top.u_hdmi.SCOPE_MODE!==0 || fft_top.u_hdmi.FFT_MODE!==0)
   $fatal(1,"FAIL: E third returns to wave");
  repeat(80000)@(negedge clk);
  if(ones==0)$fatal(1,"FAIL: audio invariance tested only silence");
  $display("PASS: actual UART E cycles three modes; %0d audio/UART cycles identical, %0d live DIN ones",cycles,ones);
  $finish;
 end
 initial begin #5000000;$fatal(1,"FAIL: FFT top-mode watchdog");end
endmodule
