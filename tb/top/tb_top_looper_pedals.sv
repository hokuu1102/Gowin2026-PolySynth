`timescale 1ns/1ps
module tb_top_looper_pedals;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,rec=1,play=1;
  integer rec_count=0,play_count=0;
  top #(.DEMO_CHORD_ON(0),.PA_ON_AFTER_RESET(0),.RIGHT_ADC_ENABLE(0),
    .SCOPE_MODE(0),.FFT_ENABLE(0),.PEDAL_DB_MS(0)) dut(
    .clk(clk),.rst_n(rst),.timbre_btn_i(1'b1),.spi_miso(6'b111111),
    .ctrl_col_i(4'b1111),.uart_rx(1'b1),.esp_uart_rx_i(1'b1),
    .pluck_up_i(1'b0),.pluck_down_i(1'b0),.pedal_sus_i(1'b1),
    .pedal_loop_rec_i(rec),.pedal_loop_play_i(play));
  always @(posedge clk) if(rst) begin
    if(dut.cmd_loop_rec_req)rec_count=rec_count+1;
    if(dut.cmd_loop_play_req)play_count=play_count+1;
  end
  initial begin
    repeat(20)@(negedge clk);rst=1;repeat(40)@(negedge clk);
    if(rec_count||play_count)$fatal(1,"idle pedal caused command");
    rec=0;repeat(40)@(negedge clk);
    if(rec_count!=1)$fatal(1,"record pedal is not wired to the real looper command");
    repeat(100)@(negedge clk);
    if(rec_count!=1)$fatal(1,"held record pedal repeated");
    rec=1;repeat(40)@(negedge clk);rec=0;repeat(40)@(negedge clk);
    if(rec_count!=2)$fatal(1,"record pedal did not rearm after release");
    play=0;repeat(40)@(negedge clk);
    if(play_count!=1)$fatal(1,"play pedal is not wired to the real looper command");
    repeat(100)@(negedge clk);
    if(play_count!=1)$fatal(1,"held play pedal repeated");
    rec=1'bz;play=1'bz;repeat(40)@(negedge clk);
    if(rec_count!=2||play_count!=1)$fatal(1,"unplugged pedal caused command");
    rec=0;play=0;repeat(40)@(negedge clk);
    if(rec_count!=3||play_count!=2)$fatal(1,"simultaneous pedals lost a command");
    $display("PASS: real top looper pedal commands, hold/rearm, simultaneous input and unplugged safety");
    $finish;
  end
endmodule
