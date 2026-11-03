`timescale 1ns/1ps
// Verify the complete physical UART stream against accepted UI producer bytes.
// Payload correctness is independently checked by tb_uart_ui; HDMI is stubbed
// by the task runner, while the real UART, UI and arbiter remain in circuit.
module tb_top_hmi_long_frames;
`ifdef HMI_FAST_BAUD
  localparam integer B=4;
`else
  localparam integer B=434;
`endif
  reg clk=0; always #10 clk=~clk;
  reg rst=0,rx=1;
  wire tx,done; wire [7:0] data;
  reg [7:0] expected[0:32767];
  reg [1:0] expected_ui[0:32767];integer diag_bytes=0,aux_bytes=0,separator_bytes=0;
  integer produced=0,received=0,frames=0,ff=0,frame_len=0,longest=0;
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .MAIN_UART_BAUD(50000000/B),.DEMO_CHORD_ON((B==4)?1:0),.PA_ON_AFTER_RESET(0)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),
    .esp_uart_rx_i(1'b1),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),
    .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1));
  uart_rx #(.BAUD_DIV(B)) monitor(.clk_i(clk),.rst_n_i(rst),.rx_i(tx),
    .rx_done_o(done),.rx_data_o(data));
  always @(posedge clk) if(rst)begin
    if(dut.ui_tx_start)begin
      if(dut.diag_owner!==3 || dut.board_uart_busy!==0)
        $fatal(1,"UI byte launched without ownership or while busy");
      expected[produced]=dut.ui_tx_data;expected_ui[produced]=1;produced=produced+1;
    end
    if(dut.hmi_diag_push)begin
      if(dut.diag_owner!==4 || dut.board_uart_busy!==0)$fatal(1,"diagnostic ownership lost");
      expected[produced]=dut.hmi_diag_data;expected_ui[produced]=0;produced=produced+1;
    end
    if(dut.ep_push || dut.fx_push)begin
      if(frame_len!=0 && dut.ui_frame_active)$fatal(1,"aux reply inside active UI frame");
      expected[produced]=dut.ep_push ? dut.ep_data : dut.fx_data;
      expected_ui[produced]=2;produced=produced+1;
    end
    if(dut.hmi_sep_start)begin
      if(dut.diag_owner!==5 || dut.board_uart_busy!==0)$fatal(1,"separator launch without ownership or while busy");
      if(dut.u_uart_tx_esp.tx_start_i)$fatal(1,"screen separator leaked to ESP UART");
      expected[produced]=8'hff;expected_ui[produced]=3;produced=produced+1;
    end
    if(done)begin
      if(received>=produced || data!==expected[received])
        $fatal(1,"physical byte %0d mismatch: got %02x expected %02x",received,data,expected[received]);
      if(expected_ui[received]!=1)begin
        if(frame_len!=0)$fatal(1,"diagnostic interleaved inside a screen frame");
        if(expected_ui[received]==0)diag_bytes=diag_bytes+1;else if(expected_ui[received]==2)aux_bytes=aux_bytes+1;else separator_bytes=separator_bytes+1;
      end else begin
      frame_len=frame_len+1;
      if(data==8'hff)ff=ff+1;else ff=0;
      if(ff==3)begin
        frames=frames+1;ff=0;
        if(frame_len>longest)longest=frame_len;
        frame_len=0;
      end
      end
      received=received+1;
    end
  end
  task send(input [7:0] value);
    integer k;begin
      @(negedge clk);rx=0;repeat(B)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(B)@(negedge clk);end
      rx=1;repeat(B)@(negedge clk);
    end
  endtask
  task refresh;
    begin send(8'h88);send(8'hff);send(8'hff);send(8'hff);end
  endtask
  task drain;
    begin
      wait(dut.u_uart_ui.ech_pend==0 && !dut.ui_frame_active && !dut.hmi_diag_pending && !dut.hmi_diag_active);
      repeat(B*12)@(negedge clk);
      wait(dut.diag_owner==0 && !dut.ep_pending && !dut.fx_pending && dut.txf_idle && !dut.ui_tx_start && !dut.board_uart_busy && received==produced);
      repeat(10)@(negedge clk);
      if(frame_len!=0)$fatal(1,"unfinished frame");
    end
  endtask
  integer first_count;
  initial begin
    repeat(20)@(negedge clk);rst=1;repeat(100)@(negedge clk);
    refresh;
    if(B==434)begin
      wait(frames>=10);
      if(longest<36)$fatal(1,"real-baud long frame absent");
      $display("PASS: 115200 physical UART first ten complete frames, %0d bytes longest=%0d",received,longest);$finish;
    end
    // Request read-only counters while a screen frame owns TX.
    send(8'h71);send(7);send(0);send(255);send(255);send(255);
    drain;
    if(diag_bytes!=30)$fatal(1,"diagnostic query did not return one complete snapshot");
    if(frames<58 || longest<36)$fatal(1,"incomplete initial refresh: frames=%0d longest=%0d",frames,longest);
    first_count=received;
    // Refresh during an active frame: its snapshot must finish coherently.
    refresh;wait(dut.ui_tx_start);
    send(8'h6f);send(0);send(8'h70);
    send(8'h71);send(17);send(50);send(255);send(255);send(255);
    send(8'h6f);send(7);
    refresh;drain;
    if(aux_bytes<8 || aux_bytes%8!=0)$fatal(1,"competing EC11 status reply incomplete: %0d",aux_bytes);
    if(frames<116 || received<=first_count)$fatal(1,"refresh did not retransmit state");
    if(dut.txf_drop!==0)$fatal(1,"diagnostic FIFO dropped bytes");
    if(dut.u_hmi_tx_diag.starts_q!==frames || dut.u_hmi_tx_diag.completed_q!==frames || dut.u_hmi_tx_diag.illegal_q!==0)
      $fatal(1,"transport counters disagree with decoded complete frames");
    $display("PASS: complete UART transport (accelerated bit clock), %0d bytes/%0d frames, longest=%0d",received,frames,longest);
    $finish;
  end
  initial begin #600000000;$fatal(1,"long-frame deadline produced=%0d received=%0d frames=%0d",produced,received,frames);end
endmodule
