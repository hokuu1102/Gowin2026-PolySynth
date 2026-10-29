`timescale 1ns/1ps
// Three independent rejection events blocked by a real live UART packet.
module tb_top_reject_notice_queue;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,rx=1,capture=0,ev_valid=0,reject=0;
  wire tx,esp_tx,rx_done;wire [7:0] rx_data;
  reg [7:0] bytes[0:31];reg [7:0] checksum;
  integer count=0,i;
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .DEMO_NOTE_DELAY(10000000),.AUTOTARE_DELAY_CLK(10000000)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.esp_uart_tx_o(esp_tx),
    .esp_uart_rx_i(1'b1),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),
    .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1));
  uart_rx #(.BAUD_DIV(100)) monitor(.clk_i(clk),.rst_n_i(rst),.rx_i(tx),
    .rx_data_o(rx_data),.rx_done_o(rx_done));
  always @(posedge clk)if(rst && capture)begin
    if(tx!==esp_tx)$fatal(1,"UART mirrors differ");
    if(rx_done)begin bytes[count]=rx_data;count=count+1;end
  end
  task send_o;
    integer k;reg [7:0] value;
    begin
      value="O";@(negedge clk);rx=0;repeat(100)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(100)@(negedge clk);end
      rx=1;repeat(100)@(negedge clk);
    end
  endtask
  initial begin
    force dut.g_sound.u_evt_upstream.evt_valid_i=ev_valid;
    force dut.g_sound.u_evt_upstream.evt_axis_i=4'd2;
    force dut.g_sound.u_evt_upstream.evt_phase_inc_i=32'h01234567;
    force dut.g_sound.u_evt_upstream.evt_velocity_i=8'd100;
    force dut.g_sound.u_evt_upstream.evt_kind_i=2'd0;
    force dut.g_sound.u_evt_upstream.evt_timbre_i=2'd1;
    force dut.g_sound.u_evt_upstream.evt_is_drum_i=1'b0;
    force dut.g_sound.rd_reject_event=reject;
    repeat(20)@(negedge clk);rst=1;repeat(100)@(negedge clk);
    send_o();repeat(3000)@(negedge clk);capture=1;
    @(negedge clk);ev_valid=1;@(negedge clk);ev_valid=0;
    wait(dut.up_packet_owner===1);
    for(i=0;i<3;i=i+1)begin
      @(negedge clk);reject=1;@(negedge clk);reject=0;
      repeat(100)@(negedge clk);
      if(dut.up_packet_owner!==1)$fatal(1,"fixture did not block all three notices with live owner");
    end
    repeat(22000)@(negedge clk);
    $write("REJECT_UART count=%0d rejected=%0d bytes=",count,dut.rd_reject_count);
    for(i=0;i<count;i=i+1)$write("%02x ",bytes[i]);$write("\n");
    if(dut.rd_reject_count!==3)$fatal(1,"fixture rejection event count wrong");
    if(count!=17)$fatal(1,"three blocked rejections require live14+3 notices=17 bytes, got %0d",count);
    checksum=0;for(i=0;i<13;i=i+1)checksum=checksum^bytes[i];
    if(bytes[0]!==8'ha5||checksum!==bytes[13])$fatal(1,"notices split live frame");
    if(bytes[14]!==8'h21||bytes[15]!==8'h21||bytes[16]!==8'h21)$fatal(1,"missing three independent rejection notices");
    if(dut.rd_notice_valid!==0||dut.up_packet_owner!==0||dut.txf_drop!==0||dut.txf_idle!==1)
      $fatal(1,"notice queue did not drain cleanly");
    $display("PASS: three rejections retained through real live packet ownership, public UART !!!, clean pending/FIFO drain");
    $finish;
  end
  initial begin #1000000;$fatal(1,"rejection queue deadline");end
endmodule
