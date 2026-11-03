`timescale 1ns/1ps
// Real top beat_gen -> looper alignment and all record entry points.
// Only beat_gen PPQN and play_seq default phase increment are accelerated.
// The acquisition event boundary is stimulated; no bar/state is forced.
module tb_top_looper_record_start;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,rx=1,rec=1,play=1;
  reg ev=0;reg [1:0] kind=0;
  integer replayed=0,bars=0,pending_seen=0;
  top #(.DEMO_CHORD_ON(1),.SOURCE_A_SEL(0),.PA_ON_AFTER_RESET(0),
    .RIGHT_ADC_ENABLE(0),.SCOPE_MODE(0),.FFT_ENABLE(0),.PEDAL_DB_MS(0)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.esp_uart_rx_i(1'b1),
    .spi_miso(6'b111111),.ctrl_col_i(4'b1111),.timbre_btn_i(1'b1),
    .pluck_up_i(1'b0),.pluck_down_i(1'b0),.pedal_sus_i(1'b1),
    .pedal_loop_rec_i(rec),.pedal_loop_play_i(play));
  defparam dut.g_sound.u_beat_gen.PPQN=4;
  defparam dut.g_sound.u_play_seq.TICK_INC_DEFAULT=32'h08000000;
  always @(posedge clk)if(rst)begin
    if(dut.g_sound.bg_bar_start)bars=bars+1;
    if(dut.g_sound.lp_recpend_w)pending_seen=pending_seen+1;
    if(dut.g_sound.looper_play_valid)replayed=replayed+1;
    if(dut.g_sound.u_looper.state==1 && dut.led_looper_st!==1)
      $fatal(1,"actual recording not reflected in UI status");
  end
  task send(input [7:0] v);
    integer k;begin
      @(negedge clk);rx=0;repeat(434)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=v[k];repeat(434)@(negedge clk);end
      rx=1;repeat(434)@(negedge clk);
    end
  endtask
  task touch(input [7:0] id);
    begin send(8'h65);send(0);send(id);send(255);send(255);send(255);end
  endtask
  task pulse_rec;
    begin rec=0;repeat(30)@(negedge clk);rec=1;repeat(30)@(negedge clk);end
  endtask
  task event_in(input [1:0] k);
    begin @(negedge clk);kind=k;ev=1;@(negedge clk);ev=0;repeat(50)@(negedge clk);end
  endtask
  task record_and_stop(input integer entry);
    begin
      if(entry==0)pulse_rec;else if(entry==1)touch(9);else send("R");
      wait(dut.g_sound.u_looper.state==1);@(negedge clk);
      if(dut.g_sound.lp_recpend_w || dut.u_uart_ui.st_loop_i!==1)$fatal(1,"armed did not become recording");
      event_in(0);repeat(80)@(negedge clk);event_in(1);
      if(dut.g_sound.looper_evt_cnt<2)$fatal(1,"live notes were not recorded");
      if(entry==0)pulse_rec;else if(entry==1)touch(9);else send("R");
      repeat(1200)@(negedge clk);
      if(dut.g_sound.loop_rec_on_r || dut.g_sound.u_looper.state==1 || dut.g_sound.lp_recpend_w)
        $fatal(1,"stop did not leave recording");
    end
  endtask
  initial begin
    force dut.g_sound.w3a_evt_valid=ev;
    force dut.g_sound.w3a_evt_axis=4'd2;
    force dut.g_sound.w3a_evt_inc=32'h01000000;
    force dut.g_sound.w3a_evt_vel=8'd100;
    force dut.g_sound.w3a_evt_kind=kind;
    repeat(20)@(negedge clk);rst=1;repeat(1800)@(negedge clk);
    if(bars<2 || !dut.g_sound.u_looper.grid_ok_r)$fatal(1,"real bar clock did not establish grid");
    if(!dut.drum_on_r)send("B");
    record_and_stop(0);
    play=0;repeat(30)@(negedge clk);play=1;repeat(2000)@(negedge clk);
    if(!replayed)$fatal(1,"recorded event did not replay");
    send("C");repeat(500)@(negedge clk);
    if(dut.g_sound.looper_evt_cnt || dut.g_sound.loop_rec_on_r)$fatal(1,"clear did not reset recording");
    send("B");repeat(30)@(negedge clk);
    if(dut.drum_on_r!==0)$fatal(1,"drums did not switch off");
    record_and_stop(1);
    send("C");repeat(500)@(negedge clk);
    record_and_stop(2);
    if(!pending_seen)$fatal(1,"alignment pending branch not exercised");
    $display("PASS: real bar alignment, pedal/screen/UART record-stop, notes recorded/replayed, clear, drums off, UI follows REC");$finish;
  end
  initial begin #10000000;$fatal(1,"record start deadline state=%0d bars=%0d",dut.g_sound.u_looper.state,bars);end
endmodule
