`timescale 1ns/1ps
// Historical pre-position-follower diagnostic, NOT a current acceptance test.
// This fixture leaves the peer axis unspecified and initially positions=0;
// it also forces am_inc_b, now the multiplexed A/B lookup result, to one target.
// Its three failures therefore do not establish bugs in the current contract.
// Retain the FAIL log as historical evidence; never relabel it as a PASS.
// Current coverage: tb_slide_position_ctrl and tb_slide_position_e2e.
module tb_at_merge_known_bugs;
 reg clk=0, rst=0, pc_rx=1;
 always #10 clk=~clk;
 top #(.SCOPE_MODE(0),.DEMO_CHORD_ON(1),.DEMO_NOTE_DELAY(1000000),.SOURCE_A_SEL(0)) u(
  .clk(clk),.rst_n(rst),.uart_rx(pc_rx),.spi_miso(6'b111111),
  .pluck_up_i(1'b0),.pluck_down_i(1'b0));
 localparam [31:0] A=32'h00c51339;
 reg note_v=0;
 reg [3:0] note_axis=6, slide_axis=6;
 reg trigger=0, tick=0, slide_enable=1;
 reg [31:0] start=A, target=A+1000;
 reg [191:0] positions=0;
 integer n_errors=0, v6=-1, v7=-1, k, changed;
 reg [31:0] before6, before7;
 task clocks(input integer n);
  repeat(n) @(negedge clk);
 endtask
 task check(input [8*100-1:0] label_text,input condition);
  begin
   if(condition) $display("CHECK_PASS %0s",label_text);
   else begin n_errors=n_errors+1; $display("BUG_REPRO %0s",label_text);end
  end
 endtask
 task uart_byte(input [7:0] b);
  integer j;
  begin
   @(negedge clk); pc_rx=0; clocks(100);
   for(j=0;j<8;j=j+1) begin pc_rx=b[j];clocks(100);end
   pc_rx=1;clocks(200);
  end
 endtask
 task pulse_trigger;
  begin @(negedge clk);trigger=1;clocks(1);trigger=0;clocks(128);end
 endtask
 task pulse_tick;
  begin @(negedge clk);tick=1;clocks(1);tick=0;clocks(128);end
 endtask
 task send_note(input [3:0] axis);
  begin note_axis=axis;note_v=1;clocks(1);note_v=0;clocks(2500);end
 endtask
 initial begin
  clocks(12);rst=1;clocks(50);
  if(u.u_uart_ui.mode_o !== 1'b1) $fatal(1,"Bad initial UI mode");
  uart_byte(8'h41);clocks(50);
  $display("A_COMMAND mode=%b accepted=%0d unknown=%0d",u.u_uart_ui.mode_o,
    u.u_calib_cmd.cmd_cnt_o,u.u_calib_cmd.unknown_cnt_o);
  check("serial A must toggle piano to fretboard",u.u_uart_ui.mode_o===1'b0);

  // Inject notes at note_manager's public input; do not force its state.
  force u.g_sound.u_note_manager.note_valid_i=note_v;
  force u.g_sound.u_note_manager.note_axis_i=note_axis;
  force u.g_sound.u_note_manager.note_phase_inc_i=A;
  force u.g_sound.u_note_manager.note_velocity_i=8'd100;
  force u.g_sound.u_note_manager.note_kind_i=2'd0;
  force u.g_sound.u_note_manager.note_src_i=3'd0;
  force u.g_sound.am_mode=1'b1;
  force u.g_sound.ee_slide_v=trigger;
  force u.g_sound.ee_slide_ax=slide_axis;
  force u.g_sound.am_inc=start;
  force u.g_sound.am_inc_b=target;
  force u.g_sound.as_valid=tick;
  force u.g_sound.as_pos=positions;
  force u.slide_on_r=slide_enable;
  force u.g_sound.pe_pitch_v=1'b0;
  force u.g_sound.lp_upd_valid=1'b0;
  send_note(6);send_note(7);
  for(k=0;k<32;k=k+1) begin
   if(u.g_sound.nm_gate[k] && u.g_sound.nm_axis[k*4+:4]==6)v6=k;
   if(u.g_sound.nm_gate[k] && u.g_sound.nm_axis[k*4+:4]==7)v7=k;
  end
  if(v6<0 || v7<0) $fatal(1,"Failed to allocate distinct live axis6/axis7 voices");
  $display("LIVE_VOICES v6=%0d v7=%0d",v6,v7);

  // Sub-EPS move snaps in one tick: final public voice value must equal target.
  slide_axis=6;start=A;target=A+1000;
  @(negedge clk);trigger=1;#1;
  $display("START_TRANSACTION valid=%b value=%08h start=%08h",
    u.g_sound.u_note_manager.pitch_upd_valid_i,u.g_sound.u_note_manager.pitch_upd_value_i,start);
  check("first accepted slide transaction must not carry a stale pitch",
    !u.g_sound.u_note_manager.pitch_upd_valid_i || u.g_sound.u_note_manager.pitch_upd_value_i===start);
  clocks(1);trigger=0;clocks(128);pulse_tick;clocks(3);
  $display("FINAL_TARGET ramp=%08h voice=%08h expected=%08h active=%b",
    u.g_sound.sl_ramp_val,u.g_sound.nm_phase[v6*32+:32],target,u.g_sound.sl_ramp_active);
  check("final snap target must reach the actual voice",u.g_sound.nm_phase[v6*32+:32]===target);

  // Keep a large glide active, then reverse event axis while continuing it.
  target=A+32'h00100000;pulse_trigger;
  repeat(4) pulse_tick;
  before6=u.g_sound.nm_phase[v6*32+:32];
  before7=u.g_sound.nm_phase[v7*32+:32];
  slide_axis=7;start=target;target=A;
  pulse_trigger;repeat(3)pulse_tick;
  $display("REVERSE before6=%08h after6=%08h before7=%08h after7=%08h",
    before6,u.g_sound.nm_phase[v6*32+:32],before7,u.g_sound.nm_phase[v7*32+:32]);
  check("reverse must not modify the independent axis7 voice",u.g_sound.nm_phase[v7*32+:32]===before7);
  check("reverse must continue updating the original axis6 voice",u.g_sound.nm_phase[v6*32+:32]!==before6);

  // Disable only W control. No further pitch transactions are permissible.
  slide_enable=0;clocks(3);changed=0;
  repeat(3) begin
   pulse_tick;
   if(u.g_sound.u_note_manager.pitch_upd_valid_i)changed=changed+1;
  end
  $display("W_OFF pitch_transactions_observed=%0d active=%b",changed,u.g_sound.sl_ramp_active);
  check("W off must stop emitting slide pitch updates",changed==0);

  // Fixed 60:40 calibrated position: independent worked example is 0x66666
  // of a 0x100000 frequency span. Waiting longer must not walk all the way to B.
  slide_enable=1;slide_axis=6;start=A;target=A+32'h00100000;
  positions[6*12+:12]=12'd384;positions[7*12+:12]=12'd256;
  pulse_trigger;repeat(140)pulse_tick;
  $display("POSITION_HOLD posA=384 posB=256 voice=%08h expected=%08h",
    u.g_sound.nm_phase[v6*32+:32],A+32'h00066666);
  check("stationary 60:40 finger position must hold the interpolated pitch",
    u.g_sound.nm_phase[v6*32+:32] >= A+32'h00066666-32'd4096 &&
    u.g_sound.nm_phase[v6*32+:32] <= A+32'h00066666+32'd4096);
  if(n_errors) $fatal(1,"KNOWN_BUGS_REPRODUCED=%0d",n_errors);
  $display("PASS: directed integration requirements");$finish;
 end
 initial begin #1000000;$fatal(1,"Diagnostic timeout");end
endmodule
