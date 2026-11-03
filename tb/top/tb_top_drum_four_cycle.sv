`timescale 1ns/1ps
module tb_top_drum_four_cycle;
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

 integer i;
 task tap_key(input integer idx);
 begin
  @(negedge clk);pressed[idx]=1;repeat(180) @(negedge clk);
  @(negedge clk);pressed[idx]=0;repeat(180) @(negedge clk);
 end endtask
 task check_visible(input expected_on,input [1:0] expected_pattern);
 begin
  if(dut.drum_on_r!==expected_on || dut.led_drum_on!==expected_on ||
     dut.u_uart_ui.st_drum_i!=={expected_on,expected_pattern})
   $fatal(1,"FAIL: actual switch, LED and screen disagree on drum state");
 end endtask
 initial begin
  repeat(20) @(negedge clk);rst_n=1;repeat(600) @(negedge clk);
  if(dut.met_on_r!==0 || dut.drum_pattern_r!==0) $fatal(1,"FAIL: initial drum setup");
  tap_key(0); // independent master switch, matrix idx0 / serial B
  check_visible(1,0);
  for(i=1;i<=8;i=i+1) begin
   tap_key(8); // pattern key only
   $display("PATTERN press=%0d pattern=%0d drum_on=%b master_on=%b",i,dut.drum_pattern_r,dut.drum_on_r,dut.met_on_r);
   if(dut.met_on_r!==1 || dut.drum_on_r!==1 || dut.drum_pattern_r!==(i%4))
    $fatal(1,"FAIL: four-pattern cycle must wrap IV to I without disabling drums");
   check_visible(1,i%4);
  end
  // Exercise the actual event gate, not only its status registers.
  force dut.g_sound.drm_evt_valid=1'b1;
  #1;if(dut.g_sound.src_b_valid!==1) $fatal(1,"FAIL: enabled drum events were blocked");
  release dut.g_sound.drm_evt_valid;
  tap_key(0);check_visible(0,0);
  force dut.g_sound.drm_evt_valid=1'b1;
  #1;if(dut.g_sound.src_b_valid!==0) $fatal(1,"FAIL: independent switch failed to stop drum events");
  release dut.g_sound.drm_evt_valid;
  tap_key(8);tap_key(8);check_visible(0,2);
  if(dut.met_on_r!==0) $fatal(1,"FAIL: changing pattern while off enabled drums");
  tap_key(0);check_visible(1,2);
  if(dut.drum_pattern_r!==2) $fatal(1,"FAIL: opening master switch reset selected pattern");
  tap_key(0);check_visible(0,2);
  $display("PASS: physical drum key cycles four patterns twice, independent start/stop preserves selection, off-state pattern changes stay silent, screen/LED and actual event gate agree");$finish;
 end
 initial begin #1000000;$fatal(1,"FAIL: watchdog");end
endmodule
