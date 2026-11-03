// Screen-side regression: retain every physical UART byte until FF FF FF.
// Legacy acknowledgements and Ee reports must not prefix the next UI command.
`timescale 1ns/1ps
module tb_top_hmi_protocol_boundary;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,rxv=0,mode_req=0,kd=0;
  reg [7:0] rxd=0;
  wire start;wire [7:0] txd;
  localparam B=4;
  reg enc_a=1,enc_b=1;integer legacy_before;
  reg rx=1;wire tx,received_byte;wire [7:0] received_data;
  reg [15:0] pressed=0;wire [3:0] rows;reg [3:0] cols;integer r,c;
  top #(.MAIN_UART_BAUD(12500000),.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),.DEMO_CHORD_ON(1)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.esp_uart_rx_i(1'b1),
    .spi_miso(6'b111111),.ctrl_row_o(rows),.ctrl_col_i(cols),
    .enc_a_i(enc_a),.enc_b_i(enc_b),.enc_sw_i(1'b1),
    .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1));
  defparam dut.u_ctrl_keypad.SCAN_DIV=4;
  defparam dut.u_ctrl_keypad.DEB_N=2;
  defparam dut.u_enc_debounce.CLK_HZ=50000;
  defparam dut.u_enc_debounce.DB_MS=1;
  always @* begin
    cols=4'b1111;
    for(r=0;r<4;r=r+1)if(!rows[r])for(c=0;c<4;c=c+1)if(pressed[r*4+c])cols[c]=0;
  end
  uart_rx #(.BAUD_DIV(B)) monitor(.clk_i(clk),.rst_n_i(rst),.rx_i(tx),.rx_done_o(received_byte),.rx_data_o(received_data));
  reg [7:0] expected[0:32767];reg ui_kind[0:32767];integer produced=0,consumed=0;
  reg ui_accept=0;reg [7:0] ui_byte=0;
  always @(posedge clk)if(rst)begin
    ui_accept<=0;
    if(dut.u_uart_tx.tx_start_i)begin
      if(dut.board_uart_busy)$fatal(1,"physical UART launch while busy");
      expected[produced]=dut.u_uart_tx.tx_data_i;ui_kind[produced]=(dut.diag_owner==3);produced=produced+1;
    end
    if(received_byte)begin
      if(consumed>=produced || received_data!==expected[consumed])$fatal(1,"physical UART byte mismatch");
      begin ui_accept<=1;ui_byte<=received_data;end
      consumed=consumed+1;
    end
  end
  task drain;begin
    repeat(100)@(negedge clk);
    wait(dut.u_uart_ui.ech_pend==0 && !dut.ui_frame_active);
    repeat(60)@(negedge clk);
    wait(dut.diag_owner==0 && dut.txf_idle && !dut.board_uart_busy && produced==consumed);
    repeat(10)@(negedge clk);
  end endtask
  task enc_step(input bit clockwise);begin
    if(clockwise)begin
      @(negedge clk);enc_a=0;enc_b=1;repeat(300)@(negedge clk);
      enc_a=0;enc_b=0;repeat(300)@(negedge clk);
      enc_a=1;enc_b=0;repeat(300)@(negedge clk);
    end else begin
      @(negedge clk);enc_a=1;enc_b=0;repeat(300)@(negedge clk);
      enc_a=0;enc_b=0;repeat(300)@(negedge clk);
      enc_a=0;enc_b=1;repeat(300)@(negedge clk);
    end
    enc_a=1;enc_b=1;repeat(300)@(negedge clk);drain;
  end endtask
  always @(posedge clk)if(rst && dut.diag_owner==5 && dut.u_uart_tx_esp.tx_start_i)
    $fatal(1,"board separator leaked into ESP UART");
  task tap(input integer idx);begin
    @(negedge clk);pressed[idx]=1;repeat(400)@(negedge clk);
    pressed[idx]=0;repeat(400)@(negedge clk);drain;
  end endtask
  string frames[0:255];string packet="";
  integer used=0,tail=0,errors=0;
  always @(negedge clk) if(ui_accept) begin
    if(ui_byte==255)begin
      tail=tail+1;
      if(tail==3)begin frames[used]=packet;used=used+1;packet="";tail=0;end
    end else begin
      if(tail!=0)$fatal(1,"partial terminator");
      packet={packet,ui_byte};
    end
  end
  function automatic string latest(input string prefix);
    integer i;
    string current;
    begin latest="";for(i=0;i<used;i=i+1)begin
      current=frames[i];
      if(current.len()>=prefix.len() && current.substr(0,prefix.len()-1)==prefix)latest=current;
    end end
  endfunction
  task feed(input [7:0] b);integer k;begin
    @(negedge clk);rx=0;repeat(B)@(negedge clk);
    for(k=0;k<8;k=k+1)begin rx=b[k];repeat(B)@(negedge clk);end
    rx=1;repeat(B)@(negedge clk);
  end endtask
  task cmd(input [7:0] id,input [7:0] value);
    begin feed(8'h71);feed(id);feed(value);feed(255);feed(255);feed(255);drain;end
  endtask
  task check_changed(input string label,input string prefix,input string before_value);
    string after_value;
    begin after_value=latest(prefix);
      $display("CHECK %s before=%s after=%s",label,before_value,after_value);
      if(before_value=="" || after_value=="" || before_value==after_value)begin errors=errors+1;$display("FAIL: %s",label);end
    end
  endtask
  string before_mode,before_kd,before_gauge,before_number;
  string gauges[0:5];string numbers[0:5];reg [7:0] ids[0:5];integer j;
  initial begin
    gauges[0]="z_dg.val=";numbers[0]="t_dg_val.txt=";ids[0]=8'h11;
    gauges[1]="z_dt.val=";numbers[1]="t_dt_val.txt=";ids[1]=8'h12;
    gauges[2]="z_cl.val=";numbers[2]="t_cl_val.txt=";ids[2]=8'h18;
    gauges[3]="z_mx.val=";numbers[3]="t_mx_val.txt=";ids[3]=8'h13;
    gauges[4]="z_ll.val=";numbers[4]="t_ll_val.txt=";ids[4]=8'h17;
    gauges[5]="z_lf.val=";numbers[5]="t_lf_val.txt=";ids[5]=8'h14;
    repeat(20)@(negedge clk);rst=1;repeat(600)@(negedge clk);
    legacy_before=consumed;feed(8'h41);drain;
    if(consumed!=legacy_before+1 || expected[legacy_before]!=8'h61)$fatal(1,"pure PC A reply format changed");
    legacy_before=consumed;feed(8'h41);drain;
    if(consumed!=legacy_before+1 || expected[legacy_before]!=8'h61)$fatal(1,"pure PC reverse A reply format changed");
    cmd(6,0);feed(8'h88);feed(255);feed(255);feed(255);drain;
    before_mode=latest("t_mode.txt=");before_kd=latest("t_kd.txt=");
    tap(7);tap(4);
    check_changed("page0 physical mode switch","t_mode.txt=",before_mode);
    check_changed("page0 keydrum state","t_kd.txt=",before_kd);
    before_mode=latest("t_mode.txt=");before_kd=latest("t_kd.txt=");tap(7);tap(4);
    check_changed("page0 reverse mode switch","t_mode.txt=",before_mode);
    check_changed("page0 reverse keydrum","t_kd.txt=",before_kd);
    before_mode=latest("t_slide.txt=");tap(2);
    check_changed("page0 slide ON","t_slide.txt=",before_mode);
    before_mode=latest("t_slide.txt=");tap(2);
    check_changed("page0 slide OFF","t_slide.txt=",before_mode);
    before_mode=latest("b_uplink.txt=");tap(15);
    check_changed("page0 uplink ON","b_uplink.txt=",before_mode);
    before_mode=latest("b_uplink.txt=");tap(15);
    check_changed("page0 uplink OFF","b_uplink.txt=",before_mode);
    before_mode=latest("b_uplink.txt=");feed(8'h4f);drain;
    check_changed("serial O uplink ON","b_uplink.txt=",before_mode);
    before_mode=latest("b_uplink.txt=");feed(8'h4f);drain;
    check_changed("serial O uplink OFF","b_uplink.txt=",before_mode);
    used=0;cmd(6,1);
    for(j=0;j<6;j=j+1)begin
      before_gauge=latest(gauges[j]);before_number=latest(numbers[j]);
      cmd(ids[j],8'd40);
      check_changed(gauges[j],gauges[j],before_gauge);
      check_changed(numbers[j],numbers[j],before_number);
    end
    cmd(8'h11,8'd32);
    feed(8'h6f);feed(0);feed(255);feed(255);feed(255);drain;
    before_gauge=latest("z_dg.val=");before_number=latest("t_dg_val.txt=");
    repeat(4)enc_step(1);drain;
    check_changed("EC11 gain needle after Ee report","z_dg.val=",before_gauge);
    check_changed("EC11 gain number after Ee report","t_dg_val.txt=",before_number);
    before_gauge=latest("z_dg.val=");before_number=latest("t_dg_val.txt=");
    repeat(4)enc_step(0);drain;
    check_changed("EC11 reverse needle after Ee report","z_dg.val=",before_gauge);
    check_changed("EC11 reverse number after Ee report","t_dg_val.txt=",before_number);
    if(errors)$fatal(1,"FAIL: %0d stale/missing display commands",errors);
    $display("PASS: mode, keydrum and six gauge/number pairs update");$finish;
  end
  initial begin #100000000;$fatal(1,"probe watchdog");end
endmodule
