`timescale 1ns/1ps
module tb_top_fxstat_uart;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,rx=1,capture=0;
  wire tx,esp_tx,rx_done;wire [7:0] rx_data;
  integer accepted=0,received=0,fx_bytes=0,stalls=0,i;
  reg [7:0] expected_stream[0:255],actual_stream[0:255],fx_stream[0:63];
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .DEMO_NOTE_DELAY(10000000),.AUTOTARE_DELAY_CLK(10000000)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.esp_uart_tx_o(esp_tx),
    .esp_uart_rx_i(1'b1),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),
    .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1));
  uart_rx #(.BAUD_DIV(100)) monitor(.clk_i(clk),.rst_n_i(rst),.rx_i(tx),
    .rx_data_o(rx_data),.rx_done_o(rx_done));
  always @(posedge clk)if(rst && capture)begin
    if(tx!==esp_tx)$fatal(1,"public UART mirrors disagree");
    if(dut.tx_req)begin
      if(!dut.txf_ready)$fatal(1,"top pushed to a full UART FIFO");
      expected_stream[accepted]=dut.tx_byte;accepted=accepted+1;
    end
    if(rx_done)begin actual_stream[received]=rx_data;received=received+1;end
    if(dut.fx_push)begin
      fx_stream[fx_bytes]=dut.fx_data;fx_bytes=fx_bytes+1;
      if(dut.tx_req!==1 || dut.tx_byte!==dut.fx_data)$fatal(1,"FX byte lost at top arbitration");
    end
    if(!dut.fx_ready && dut.ui_zfs_req_cnt!=0)stalls=stalls+1;
  end
  task send(input [7:0] value);
    integer k;
    begin
      @(negedge clk);rx=0;repeat(100)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(100)@(negedge clk);end
      rx=1;repeat(100)@(negedge clk);
    end
  endtask
  task query(input [7:0] sub);
    begin send("Z");send(sub);end
  endtask
  task check_fx(input integer offset,input [63:0] frame);
    integer k;
    begin for(k=0;k<8;k=k+1)
      if(fx_stream[offset+k]!==frame[63-k*8 -:8])$fatal(1,"FX frame mismatch at byte %0d",offset+k);
    end
  endtask
  initial begin
    repeat(20)@(negedge clk);rst=1;repeat(100)@(negedge clk);
    send(8'h71);send(8'h10);send(7);send(8'hff);send(8'hff);send(8'hff);
    repeat(2000)@(negedge clk);
    if(dut.ui_fx_mask!==7)$fatal(1,"real UART failed to set FX mask");
    capture=1;
    query(0);repeat(12000)@(negedge clk);
    if(received!=8)$fatal(1,"expected 8 public UART bytes, got %0d",received);
    for(i=0;i<8;i=i+1)
      if(actual_stream[i]!==({"Zz00007",8'h0a} >> ((7-i)*8) & 8'hff))$fatal(1,"public mask frame corrupt at %0d",i);
    query(6);repeat(12000)@(negedge clk);
    query(7);repeat(12000)@(negedge clk);
    // Ordinary packets compete while two FX requests are in flight.
    send("P");query(0);send("V");query(6);
    repeat(60000)@(negedge clk);
    if(received!=accepted)$fatal(1,"UART drain mismatch accepted=%0d received=%0d",accepted,received);
    for(i=0;i<accepted;i=i+1)
      if(actual_stream[i]!==expected_stream[i])$fatal(1,"accepted byte lost/reordered at UART byte %0d",i);
    if(fx_bytes!=40)$fatal(1,"expected 5 FX frames, got %0d bytes",fx_bytes);
    check_fx(0,{"Zz00007",8'h0a});check_fx(8,{"Zz60000",8'h0a});check_fx(16,{"Zz70000",8'h0a});
    check_fx(24,{"Zz00007",8'h0a});check_fx(32,{"Zz60000",8'h0a});
    if(accepted<=40||stalls<10||dut.txf_drop!==0||dut.ui_zfs_drop_cnt!==0)
      $fatal(1,"arbitration coverage/drop failure accepted=%0d stalls=%0d fifo_drop=%0d fx_drop=%0d",accepted,stalls,dut.txf_drop,dut.ui_zfs_drop_cnt);
    $display("PASS: real UART mask7 and Z0/6/7, 40 FX bytes plus ordinary P/V replies, %0d accepted/public bytes identical, %0d ready stalls, no drops",accepted,stalls);
    $finish;
  end
  initial begin #5000000;$fatal(1,"top FXSTAT UART deadline");end
endmodule
