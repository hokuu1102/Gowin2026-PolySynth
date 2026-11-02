`timescale 1ns/1ps
module tb_top_screen_gear;
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

 task tap_key(input integer idx);
 begin
  @(negedge clk);pressed[idx]=1;repeat(180) @(negedge clk);
  @(negedge clk);pressed[idx]=0;repeat(180) @(negedge clk);
 end endtask

 task send(input [7:0] v);
 integer k;
 begin @(negedge clk);rx=0;repeat(434)@(negedge clk);
 for(k=0;k<8;k=k+1)begin rx=v[k];repeat(434)@(negedge clk);end
 rx=1;repeat(434)@(negedge clk);end endtask
 task select_gear(input [7:0] v);
 begin send(8'h71);send(5);send(v);send(8'hff);send(8'hff);send(8'hff);
 repeat(30)@(negedge clk);end endtask
 initial begin
 repeat(20)@(negedge clk);rst_n=1;repeat(600)@(negedge clk);
 force dut.g_sound.vib_depth_raw=12'h800;
 force dut.g_sound.vib_rate_raw=12'h400;
 repeat(20)@(negedge clk);
 select_gear(2);
 if(dut.led_gear_st!==2 || dut.fg_hold!==3'b010)$fatal(1,"screen did not select/lock original pitch gear");
 force dut.g_sound.vib_depth_raw=12'hA00;
 force dut.g_sound.vib_rate_raw=12'h600;
 repeat(20)@(negedge clk);
 select_gear(0);
 if(dut.led_gear_st!==0 || dut.fg_hold!==3'b110 ||
 dut.g_sound.u_vibrato_lfo.depth_raw_i!==12'h800 ||
 dut.g_sound.u_fx.trem_depth_i!==8'hA0 || dut.g_sound.u_fx.trem_rate_i!==8'h0C)
 $fatal(1,"screen departure did not retain both actual audio effects");
 force dut.g_sound.vib_depth_raw=12'h000;
 force dut.g_sound.vib_rate_raw=12'h800;
 repeat(20)@(negedge clk);
 if(dut.transpose_semi!==5'sd6)$fatal(1,"transpose setup failed");
 select_gear(1);
 force dut.g_sound.vib_rate_raw=12'h000;
 repeat(20)@(negedge clk);
 if(dut.led_gear_st!==1 || dut.fg_hold!==3'b111 || dut.transpose_semi!==5'sd6 ||
 dut.g_sound.u_vibrato_lfo.depth_raw_i!==12'h800 || dut.g_sound.u_fx.trem_depth_i!==8'hA0)
 $fatal(1,"returning to locked gear lost a retained effect");
 tap_key(9);
 if(dut.fg_hold!==3'b101 || dut.g_sound.u_vibrato_lfo.depth_raw_i!==0)
 $fatal(1,"manual unlock after screen switch failed");
 select_gear(1);
 if(dut.fg_hold!==3'b101)$fatal(1,"reselect must not lock the current gear");
 select_gear(5);
 if(dut.led_gear_st!==1 || dut.fg_hold!==3'b101)$fatal(1,"invalid screen selection changed audio gear");
 $display("PASS: real 115200 screen selects audio gear, locks departing effects, retains transpose/pitch/volume and permits physical unlock");$finish;
 end
 initial begin #20000000;$fatal(1,"FAIL: screen gear watchdog");end
endmodule
