`timescale 1ns/1ps
module tb_top_key15_uplink;
 reg clk=0,rst_n=0,rx=1;
 always #10 clk=~clk;
 wire [3:0] rows;
 reg [3:0] cols;
 reg [15:0] pressed=0;
 wire sclk,mosi;
 wire [5:0] cs,miso;
 integer r,c,toggles=0,tares=0;
 top dut(.clk(clk),.rst_n(rst_n),.uart_rx(rx),
  .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
  .spi_sclk(sclk),.spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso),
  .ctrl_row_o(rows),.ctrl_col_i(cols),.enc_a_i(1'b1),.enc_b_i(1'b1),.enc_sw_i(1'b1));
 mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
 mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
 mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
 assign miso[5:3]=3'b111;
 defparam dut.u_ctrl_keypad.SCAN_DIV=4;
 defparam dut.u_ctrl_keypad.DEB_N=2;
 defparam dut.u_ctrl_key_map.CLK_HZ=1000;
 defparam dut.u_ctrl_key_map.LONG_MS=20;
 always @* begin
  cols=4'b1111;
  for(r=0;r<4;r=r+1) if(!rows[r])
   for(c=0;c<4;c=c+1) if(pressed[r*4+c]) cols[c]=0;
 end
 always @(posedge clk) if(dut.rst_n_sync) begin
  if(dut.km_uplink_toggle_req) toggles=toggles+1;
  if(dut.cmd_tare_req) tares=tares+1;
 end
 task state_check(input expected);
 begin
  repeat(5) @(negedge clk);
  if(dut.up_enable_r!==expected || dut.u_uart_ui.uplink_sw_o!==expected ||
     dut.g_sound.u_evt_upstream.enable_i!==expected)
   $fatal(1,"FAIL: keypad/screen/transmitter disagree expected=%b",expected);
 end endtask
 task tap;
 begin
  @(negedge clk);pressed[15]=1;repeat(180) @(negedge clk);
  @(negedge clk);pressed[15]=0;repeat(180) @(negedge clk);
 end endtask
 task serial_byte(input [7:0] b);
 integer bitn;
 begin
  @(negedge clk);rx=0;repeat(434) @(negedge clk);
  for(bitn=0;bitn<8;bitn=bitn+1) begin rx=b[bitn];repeat(434) @(negedge clk);end
  rx=1;repeat(650) @(negedge clk);
 end endtask
 initial begin
 repeat(20) @(negedge clk);rst_n=1;repeat(600) @(negedge clk);
 state_check(0);
 tap;state_check(1);
 if(toggles!=1 || tares!=0) $fatal(1,"FAIL: first release must toggle without calibration");
 @(negedge clk);pressed[15]=1;repeat(600) @(negedge clk);
 state_check(1);
 if(toggles!=1 || tares!=0) $fatal(1,"FAIL: long hold repeated command");
 @(negedge clk);pressed[15]=0;repeat(180) @(negedge clk);
 state_check(0);
 if(toggles!=2 || tares!=0) $fatal(1,"FAIL: long release must toggle once");
 serial_byte(8'h4F);state_check(1); // real board UART O
 tap;state_check(0); // physical key toggles state left by serial
 serial_byte(8'h54);repeat(10) @(negedge clk);
 if(tares!=1 || toggles!=3) $fatal(1,"FAIL: serial T calibration was lost");
 // Same-cycle request sources are ORed, not counted as multiple flips.
 force dut.ui_uplink_toggle=1'b1;
 force dut.km_uplink_toggle_req=1'b1;
 @(negedge clk);
 release dut.ui_uplink_toggle;release dut.km_uplink_toggle_req;
 state_check(1);
 $display("PASS: physical matrix idx15 release toggles shared uplink; hold no repeat; screen/TX follow; serial O/T preserved; simultaneous requests toggle once");$finish;
 end
 initial begin #1000000;$fatal(1,"FAIL: key15 top watchdog");end
endmodule
