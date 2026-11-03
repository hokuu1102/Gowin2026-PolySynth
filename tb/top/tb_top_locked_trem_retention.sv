`timescale 1ns/1ps
module tb_top_locked_trem_retention;
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
 initial begin
  repeat(20) @(negedge clk);rst_n=1;repeat(600) @(negedge clk);
  force dut.g_sound.vib_depth_raw=12'h800;
  force dut.g_sound.vib_rate_raw=12'h400;
  repeat(20) @(negedge clk);
  tap_key(9);
  if(dut.fg_hold!==3'b010) $fatal(1,"FAIL: physical lock key did not lock gear1");
  force dut.g_sound.vib_depth_raw=12'h000;
  force dut.g_sound.vib_rate_raw=12'h000;
  repeat(20) @(negedge clk);
  if(dut.g_sound.u_vibrato_lfo.depth_raw_i!==12'h800 || dut.g_sound.u_vibrato_lfo.rate_raw_i!==12'h400)
   $fatal(1,"FAIL: pitch-vibrato lock does not freeze actual LFO inputs");
  tap_key(5);
  if(dut.led_gear_st!==2 || dut.g_sound.u_vibrato_lfo.depth_raw_i!==12'h800)
   $fatal(1,"FAIL: pitch vibrato lost when changing gear");
  $display("PASS pitch-vibrato: physical lock works; moving faders and switching gear preserve actual LFO inputs");
  force dut.g_sound.vib_depth_raw=12'hA00;
  force dut.g_sound.vib_rate_raw=12'h600;
  repeat(20) @(negedge clk);
  tap_key(9);
  if(dut.fg_hold!==3'b110) $fatal(1,"FAIL: physical lock key did not lock gear2");
  force dut.g_sound.vib_depth_raw=12'h000;
  force dut.g_sound.vib_rate_raw=12'h000;
  repeat(20) @(negedge clk);
  $display("BEFORE gear switch: gear=%0d locks=%b held_depth=%h actual_FX_depth=%h rate=%h",dut.led_gear_st,dut.fg_hold,dut.trem_depth_f,dut.g_sound.u_fx.trem_depth_i,dut.g_sound.u_fx.trem_rate_i);
  if(dut.g_sound.u_fx.trem_depth_i!==8'hA0 || dut.g_sound.u_fx.trem_rate_i!==8'h0C)
   $fatal(1,"FAIL: volume-vibrato lock failed while still in gear2");
  tap_key(5);
  $display("AFTER gear switch: gear=%0d locks=%b held_depth=%h actual_FX_depth=%h rate=%h",dut.led_gear_st,dut.fg_hold,dut.trem_depth_f,dut.g_sound.u_fx.trem_depth_i,dut.g_sound.u_fx.trem_rate_i);
  if(dut.g_sound.u_fx.trem_depth_i!==8'hA0 || dut.g_sound.u_fx.trem_rate_i!==8'h0C)
   $fatal(1,"FAIL: locked volume vibrato no longer reaches audio FX after switching gear");
  // All three effects coexist: lock transpose, then zero both physical faders.
  force dut.g_sound.vib_depth_raw=12'h000;
  force dut.g_sound.vib_rate_raw=12'h800;
  repeat(20) @(negedge clk);
  if(dut.transpose_semi!==5'sd6) $fatal(1,"FAIL: transpose setup");
  tap_key(9);
  if(dut.fg_hold!==3'b111) $fatal(1,"FAIL: per-gear locks not independent");
  force dut.g_sound.vib_depth_raw=12'h000;
  force dut.g_sound.vib_rate_raw=12'h000;
  repeat(20) @(negedge clk);
  tap_key(5);
  if(dut.led_gear_st!==1 || dut.transpose_semi!==5'sd6 ||
     dut.g_sound.u_vibrato_lfo.depth_raw_i!==12'h800 ||
     dut.g_sound.u_vibrato_lfo.rate_raw_i!==12'h400 ||
     dut.g_sound.u_fx.trem_depth_i!==8'hA0 ||
     dut.g_sound.u_fx.trem_rate_i!==8'h0C)
   $fatal(1,"FAIL: locked transpose, pitch vibrato and volume tremolo must coexist");
  // Pending screen/UART values must not replace locked gear2 values.
  force dut.ui_fx_depth=8'h35;
  force dut.ui_fx_rate=8'h1A;
  repeat(20) @(negedge clk);
  if(dut.g_sound.u_fx.trem_depth_i!==8'hA0 || dut.g_sound.u_fx.trem_rate_i!==8'h0C)
   $fatal(1,"FAIL: screen values overrode a locked fader effect");
  // Unlock in gear2: immediately follow the current (zero) faders.
  tap_key(5);
  tap_key(9);
  if(dut.led_gear_st!==2 || dut.fg_hold!==3'b011 ||
     dut.g_sound.u_fx.trem_depth_i!==0 || dut.g_sound.u_fx.trem_rate_i!==0)
   $fatal(1,"FAIL: unlocking gear2 must immediately follow the current faders");
  // Unlocked + outside gear2 keeps the existing screen/UART priority.
  tap_key(5);
  if(dut.g_sound.u_fx.trem_depth_i!==8'h35 || dut.g_sound.u_fx.trem_rate_i!==8'h1A)
   $fatal(1,"FAIL: unlocked off-gear screen/UART control regressed");
  if(dut.transpose_semi!==5'sd6 || dut.g_sound.u_vibrato_lfo.depth_raw_i!==12'h800)
   $fatal(1,"FAIL: unlocking volume tremolo changed other locked effects");
  $display("PASS: actual audio controls retain all three locked effects across physical gear changes; unlock and existing screen/UART fallback preserved");$finish;

 end
 initial begin #1000000;$fatal(1,"FAIL: watchdog");end
endmodule
