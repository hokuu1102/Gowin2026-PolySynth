`timescale 1ns/1ps
// Real 115200 UART touch traffic, 51 pedal coexistence, and screen TX isolation.
module tb_top_hmi_integration;
  reg clk=0; always #10 clk=~clk;
  reg rst=0,rx=1,rec=1,play=1,check_screen=0;
  wire tx,esp_tx,done; wire [7:0] data;
  integer rec_count=0,play_count=0,screen_bytes=0,ff_count=0,frames=0;
  reg [7:0] prefix[0:5];
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .DEMO_CHORD_ON(0),.PEDAL_DB_MS(0),.PA_ON_AFTER_RESET(0)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.esp_uart_tx_o(esp_tx),
    .esp_uart_rx_i(1'b1),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),
    .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(rec),.pedal_loop_play_i(play));
  uart_rx #(.BAUD_DIV(434)) monitor(.clk_i(clk),.rst_n_i(rst),.rx_i(tx),
    .rx_done_o(done),.rx_data_o(data));
  always @(posedge clk) if(rst)begin
    if(dut.cmd_loop_rec_req)rec_count=rec_count+1;
    if(dut.cmd_loop_play_req)play_count=play_count+1;
    if(check_screen)begin
      if(esp_tx!==1'b1)$fatal(1,"screen text leaked onto ESP UART");
      if(dut.txf_drop!==0)$fatal(1,"screen backpressure overflowed diagnostic FIFO");
      if(done)begin
        if(screen_bytes<6)prefix[screen_bytes]=data;
        screen_bytes=screen_bytes+1;
        if(data==8'hff)ff_count=ff_count+1;else ff_count=0;
        if(ff_count==3)begin frames=frames+1;ff_count=0;end
      end
    end
  end
  task send(input [7:0] value);
    integer k;
    begin
      @(negedge clk);rx=0;repeat(434)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(434)@(negedge clk);end
      rx=1;repeat(434)@(negedge clk);
    end
  endtask
  task touch(input [7:0] control_id);
    begin send(8'h65);send(0);send(control_id);send(8'hff);send(8'hff);send(8'hff);
      repeat(30)@(negedge clk);end
  endtask
  initial begin
    repeat(20)@(negedge clk);rst=1;repeat(100)@(negedge clk);
    if(dut.up_enable_r!==0 || dut.u_uart_ui.uplink_sw_o!==0)
      $fatal(1,"upstream boot state differs from 51 or UI");
    touch(15);
    if(dut.up_enable_r!==1 || dut.u_uart_ui.uplink_sw_o!==1)
      $fatal(1,"touch uplink did not enable real switch");
    send("O");repeat(30)@(negedge clk);
    if(dut.up_enable_r!==0 || dut.u_uart_ui.uplink_sw_o!==0)
      $fatal(1,"O command did not synchronize UI");
    touch(9);touch(10);
    rec=0;play=0;repeat(50)@(negedge clk);
    if(rec_count!=2 || play_count!=2)$fatal(1,"screen and pedal controls do not coexist");
    rec=1;play=1;
    touch(4);if(dut.slide_on_r!==1)$fatal(1,"screen slide toggle missing");
    touch(5);touch(5);touch(5);touch(5);
    if(dut.drum_on_r!==0)$fatal(1,"drum off state missing");
    touch(5);if(dut.drum_on_r!==1 || dut.drum_pattern_r!==0)
      $fatal(1,"drum restart did not return to I");
    // Reset clears previous diagnostic replies; boot acknowledgement starts screen echo.
    rst=0;repeat(20)@(negedge clk);rst=1;repeat(100)@(negedge clk);
    check_screen=1;send(8'h88);send(8'hff);send(8'hff);send(8'hff);
    wait(frames>=3);
    if({prefix[0],prefix[1],prefix[2],prefix[3],prefix[4],prefix[5]}!=="t_mode")
      $fatal(1,"first screen command lost or duplicated a byte");
    if(screen_bytes<30)$fatal(1,"vacuous screen transmission");
    $display("PASS: 115200 touch/O state sync, pedal coexistence, five-state drum, screen framing and ESP isolation");
    $finish;
  end
  initial begin #30000000;$fatal(1,"HMI integration deadline");end
endmodule
