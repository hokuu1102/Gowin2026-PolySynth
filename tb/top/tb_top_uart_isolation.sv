`timescale 1ns/1ps
// Real physical UART pins; no producer forcing or copied top-level gating.
module tb_top_uart_isolation;
 reg clk=0,rst=0,board_rx=1,esp_rx=1;
 always #10 clk=~clk;
 top #(.SCOPE_MODE(0),.TEST_MODE_EN(0),.RIGHT_ADC_ENABLE(0),
  .AUTOTARE_DELAY_CLK(10000000),.DEMO_NOTE_DELAY(10000000)) dut(
  .clk(clk),.rst_n(rst),.uart_rx(board_rx),.esp_uart_rx_i(esp_rx),
  .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
  .spi_miso(6'b111111));
 integer events=0,ui_frames=0,k;
 reg [63:0] last_event=0;
 // Observe the real module's public output, not private parser state.
 always @(posedge clk) if(rst && dut.rst_n_sync) begin
  if(dut.u_evt_uart_rx.evt_valid_o===1'bx)
   $fatal(1,"FAIL: unknown score valid");
  if(dut.u_evt_uart_rx.evt_valid_o) begin
   events=events+1;last_event=dut.u_evt_uart_rx.evt_data_o;
  end
 end
 task send_byte;
  input select_esp;
  input [7:0] value;
  integer b;
  begin
   @(negedge clk);if(select_esp)esp_rx=0;else board_rx=0;
   repeat(100) @(negedge clk);
   for(b=0;b<8;b=b+1) begin
    if(select_esp)esp_rx=value[b];else board_rx=value[b];
    repeat(100) @(negedge clk);
   end
   if(select_esp)esp_rx=1;else board_rx=1;
   repeat(100) @(negedge clk);
  end
 endtask
 task screen_frame;
  begin
   // Existing uart_ui numeric-return format, arbitrary payload contains A5.
   send_byte(0,8'h71);send_byte(0,8'h01);send_byte(0,8'hA5);
   send_byte(0,8'hA5);send_byte(0,8'h00);send_byte(0,8'hFF);
   send_byte(0,8'hFF);send_byte(0,8'hFF);send_byte(0,8'hFF);
  end
 endtask
 task score_frame;
  begin
   send_byte(1,8'hA5);send_byte(1,8'h07);send_byte(1,8'h00);
   send_byte(1,8'h10);send_byte(1,8'h00);send_byte(1,8'h20);
   send_byte(1,8'h00);send_byte(1,8'hC8);send_byte(1,8'h00);
  end
 endtask
 initial begin
  repeat(20) @(negedge clk);rst=1;repeat(3000) @(negedge clk);
  for(k=0;k<8;k=k+1)screen_frame;
  repeat(3000) @(negedge clk);
  if(events!=0)$fatal(1,"FAIL: board screen frames injected score events %0d",events);
  ui_frames=dut.u_uart_ui.frame_cnt_o;
  if(ui_frames!=8)$fatal(1,"FAIL: screen frames not actually consumed %0d",ui_frames);
  // Concurrent traffic must neither leak from the board nor block ESP payload.
  fork
   begin for(k=0;k<2;k=k+1)screen_frame;end
   begin score_frame;end
  join
  repeat(3000) @(negedge clk);
  if(events!=1 || last_event!==64'h00c8002000100007)
   $fatal(1,"FAIL: independent ESP frame count/data %0d %016h",events,last_event);
  if(dut.u_uart_ui.frame_cnt_o!==16'd10)
   $fatal(1,"FAIL: simultaneous board frames lost");
  $display("PASS: real top dual UART isolation; ten screen frames, one exact ESP event");
  $finish;
 end
 initial begin #10000000;$fatal(1,"FAIL: dual UART isolation watchdog");end
endmodule
