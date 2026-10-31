`timescale 1ns/1ps
module tb_top_hmi_bpm;
  reg clk=0; always #10 clk=~clk;
  reg rst=0;
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.DEMO_CHORD_ON(0),.RIGHT_ADC_ENABLE(0)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(1'b1),.esp_uart_rx_i(1'b1),
    .spi_miso(6'b111111),.ctrl_col_i(4'b1111),.timbre_btn_i(1'b1),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1),
    .pluck_up_i(1'b0),.pluck_down_i(1'b0));
  task up;
    begin force dut.ui_bpm_up_req=1;@(negedge clk);release dut.ui_bpm_up_req;
      repeat(2)@(negedge clk);end
  endtask
  initial begin
    repeat(20)@(negedge clk);rst=1;repeat(50)@(negedge clk);
    up;
    if(dut.ui_bpm_val!==125)$fatal(1,"first screen BPM step");
    up;
    if(dut.ui_bpm_val!==130)$fatal(1,"rapid screen BPM steps lost");
    force dut.ps_bpm_w=8'd160;repeat(3)@(negedge clk);up;
    if(dut.ui_bpm_val!==165)$fatal(1,"screen used stale BPM after encoder/score change");
    force dut.cmd_bpm_val=8'd255;force dut.cmd_bpm_set=1;
    @(negedge clk);release dut.cmd_bpm_set;release dut.cmd_bpm_val;
    repeat(2)@(negedge clk);up;
    if(dut.ui_bpm_val!==240)$fatal(1,"out-of-range Q made +5 wrap around");
    force dut.ui_bpm_pending=1;force dut.ps_bpm_w=8'd100;
    repeat(3)@(negedge clk);up;
    if(dut.ui_bpm_val!==240)$fatal(1,"old applied BPM erased pending screen request");
    release dut.ui_bpm_pending;release dut.ps_bpm_w;
    $display("PASS: rapid BPM steps, live tempo synchronization, pending value preservation and clamping");
    $finish;
  end
  initial begin #100000;$fatal(1,"BPM control watchdog");end
endmodule
