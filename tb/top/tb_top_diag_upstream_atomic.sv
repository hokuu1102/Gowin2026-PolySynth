`timescale 1ns/1ps
// Public UART proof that an auxiliary diagnostic cannot split a live frame.
module tb_top_diag_upstream_atomic;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,rx=1,capture=0,ev_valid=0;
  wire tx,esp_tx,rx_done;wire [7:0] rx_data;
  reg [7:0] bytes[0:127];
  reg [7:0] checksum;
  integer count=0,i,j,live_frames=0,fx_frames=0;
  top #(.MAIN_UART_BAUD(500000),.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .DEMO_NOTE_DELAY(10000000),.AUTOTARE_DELAY_CLK(10000000)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.esp_uart_tx_o(esp_tx),
    .esp_uart_rx_i(1'b1),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),
    .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1));
  uart_rx #(.BAUD_DIV(100)) monitor(.clk_i(clk),.rst_n_i(rst),.rx_i(tx),
    .rx_data_o(rx_data),.rx_done_o(rx_done));
  always @(posedge clk)if(rst && capture)begin
    if(tx!==esp_tx)$fatal(1,"public UART mirrors differ");
    if(rx_done)begin bytes[count]=rx_data;count=count+1;end
    if(dut.fx_push)$display("FX_ACCEPT time=%0t byte=%02x owner=%0d",$time,dut.fx_data,dut.diag_owner);
    if(dut.txf_start||dut.up_push_w)$display("TX_START time=%0t fifo=%0d live=%0d busy=%0d byte=%02x",$time,dut.txf_start,dut.up_push_w,dut.board_uart_busy,dut.shared_tx_data);
  end
  task send(input [7:0] value);
    integer k;
    begin
      @(negedge clk);rx=0;repeat(100)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(100)@(negedge clk);end
      rx=1;repeat(100)@(negedge clk);
    end
  endtask
  initial begin
    // Inject one legal event at the real upstream consumer's input seam.
    force dut.g_sound.u_evt_upstream.evt_valid_i=ev_valid;
    force dut.g_sound.u_evt_upstream.evt_axis_i=4'd2;
    force dut.g_sound.u_evt_upstream.evt_phase_inc_i=32'h01234567;
    force dut.g_sound.u_evt_upstream.evt_velocity_i=8'd100;
    force dut.g_sound.u_evt_upstream.evt_kind_i=2'd0;
    force dut.g_sound.u_evt_upstream.evt_timbre_i=2'd1;
    force dut.g_sound.u_evt_upstream.evt_is_drum_i=1'b0;
    repeat(20)@(negedge clk);rst=1;repeat(100)@(negedge clk);
    send("O");repeat(3000)@(negedge clk);
    if(dut.up_enable_r!==1)$fatal(1,"UART O did not enable upstream");
    capture=1;
    @(negedge clk);ev_valid=1;@(negedge clk);ev_valid=0;
    wait(dut.up_push_w);
    send("Z");send(0);
    repeat(40000)@(negedge clk);
    $write("PUBLIC_UART count=%0d bytes=",count);
    for(i=0;i<count;i=i+1)$write("%02x ",bytes[i]);$write("\n");
    for(i=0;i<count;i=i+1)begin
      if(bytes[i]==8'ha5 && i+13<count)begin
        checksum=0;for(j=0;j<13;j=j+1)checksum=checksum^bytes[i+j];
        if(checksum!==bytes[i+13])$fatal(1,"diagnostic split/corrupted live14 frame: XOR expected=%02x got=%02x",checksum,bytes[i+13]);
        if(bytes[i+1]!==1 || bytes[i+7]!==8'h12 ||
          {bytes[i+8],bytes[i+9],bytes[i+10],bytes[i+11]}!==32'h01234567 || bytes[i+12]!==100)
          $fatal(1,"live metadata changed");
        live_frames=live_frames+1;
      end
      if(i+7<count && {bytes[i],bytes[i+1],bytes[i+2],bytes[i+3],bytes[i+4],bytes[i+5],bytes[i+6],bytes[i+7]}=={"Zz00000",8'h0a})
        fx_frames=fx_frames+1;
    end
    if(count!=22||live_frames!=1||fx_frames!=1)$fatal(1,"missing complete live/FX frame count=%0d live=%0d FX=%0d",count,live_frames,fx_frames);
    // A legal empty-Looper Y rejection must wait outside the live packet.
    capture=0;count=0;live_frames=0;
    repeat(2000)@(negedge clk);capture=1;
    @(negedge clk);ev_valid=1;@(negedge clk);ev_valid=0;
    wait(dut.up_push_w);
    // Start Y after several live bytes have physically completed.
    repeat(5000)@(negedge clk);send("Y");
    repeat(40000)@(negedge clk);
    $write("PUBLIC_UART_Y count=%0d bytes=",count);
    for(i=0;i<count;i=i+1)$write("%02x ",bytes[i]);$write("\n");
    if(count!=15)$fatal(1,"Y rejection/live drain mismatch expected15 actual%0d",count);
    if(bytes[0]!==8'ha5||bytes[1]!==1||bytes[7]!==8'h12||bytes[14]!==8'h21)
      $fatal(1,"Y rejection split live14 or missing reject");
    checksum=0;for(j=0;j<13;j=j+1)checksum=checksum^bytes[j];
    if(checksum!==bytes[13])$fatal(1,"Y corrupted live XOR");
    if(dut.up_busy_w!==0||dut.rd_busy!==0||dut.diag_owner!==0||dut.up_packet_owner!==0)
      $fatal(1,"packet owner deadlocked after UART drain");
    $display("PASS: live14 XOR/metadata and FXSTAT8 (22B), empty Y rejection (15B), complete drain with no owner deadlock");
    $finish;
  end
  initial begin #2500000;$fatal(1,"live/diag atomic deadline");end
endmodule
