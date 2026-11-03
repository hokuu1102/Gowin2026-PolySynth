`timescale 1ns/1ps
// Readback must retain low mask/activity bits and all 16 counter bits.
module tb_fxstat_wire_values;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,req=0,ready=0,random_ready=0;
  reg [15:0] random_state=16'hACE1;
  reg [7:0] mask=8'h07;
  reg [15:0] lfo=16'hABCD;
  reg [2:0] sub=0;
  wire push;wire [7:0] data;
  reg [7:0] got[0:63];
  reg [15:0] expected[0:7];
  integer n=0,i,j,errors=0,stalled=0;
  wire [15:0] requests,drops;
  uart_ui dut(.clk_i(clk),.rst_n_i(rst),.mode_sw_req_i(1'b0),
    .rx_done_i(1'b0),.rx_data_i(8'd0),.tx_busy_i(1'b0),.tx_done_i(1'b0),
    .fxstat_req_i(req),.fxstat_sub_i(sub),.fx_en_mask_i(mask),.fx_tx_ready_i(ready),
    .fx_dly_active_i(1'b1),.fx_chor_active_i(1'b1),.fx_dly_primed_i(1'b1),
    .fx_dist_clip_i(16'h1234),.fx_trem_lfo_i(lfo),.fx_pipe_i(16'd19),
    .fx_tx_start_o(push),.fx_tx_data_o(data),.zfs_req_cnt_o(requests),.zfs_drop_cnt_o(drops));
  // Capture on the consumer's actual acceptance edge, before FSM NBA updates.
  always @(posedge clk)begin
    if(push)begin
    if(!ready)$fatal(1,"FXSTAT pushed while downstream was stalled");
    if(n>=64)$fatal(1,"FXSTAT response overflow");
    got[n]=data;n=n+1;
    end
    if(rst && !ready)stalled=stalled+1;
  end
  always @(negedge clk)begin
    if(random_ready)begin
      random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
      #1;ready=random_state[0] & random_state[3];
    end
  end
  function [7:0] hex_ascii(input [3:0] value);
    begin hex_ascii=(value<10)?8'h30+value:8'h41+value-10;end
  endfunction
  task request(input [2:0] which);
    begin
      @(posedge clk);#1;sub=which;req=1;
      @(posedge clk);#1;req=0;
    end
  endtask
  task check_frame(input integer offset,input [2:0] which,input [15:0] value);
    begin
      if(got[offset]!==8'h5a||got[offset+1]!==8'h7a||got[offset+2]!==8'h30+which||
        got[offset+3]!==hex_ascii(value[15:12])||got[offset+4]!==hex_ascii(value[11:8])||
        got[offset+5]!==hex_ascii(value[7:4])||got[offset+6]!==hex_ascii(value[3:0])||got[offset+7]!==8'h0a)begin
        errors=errors+1;
        $write("FAIL: FXSTAT offset=%0d sub=%0d expected=%04h bytes=",offset,which,value);
        for(j=offset;j<offset+8;j=j+1)$write("%02x ",got[j]);$write("\n");
      end
    end
  endtask
  initial begin
    expected[0]=16'h0007;expected[1]=16'h1234;expected[2]=16'h0001;
    expected[3]=16'h0003;expected[4]=16'hABCD;expected[5]=16'h0013;
    expected[6]=0;expected[7]=0;
    repeat(3)@(negedge clk);rst=1;random_ready=1;
    for(i=0;i<8;i=i+1)begin
      @(posedge clk);#1;n=0;
      request(i[2:0]);
      repeat(200)@(posedge clk);#1;
      if(n!=8)errors=errors+1;
      else check_frame(0,i[2:0],expected[i]);
    end
    // Stall an active frame, then replace one pending request with the latest.
    @(posedge clk);#1;random_ready=0;ready=0;n=0;
    request(0); // Captures mask=7; must stay intact through later requests.
    repeat(4)@(posedge clk);#1;
    request(1); // Pending 0x1234.
    request(4); // Replaces pending with LFO ABCD; one drop.
    mask=8'h55;lfo=16'h5678; // Both active and pending must be snapshots.
    repeat(10)@(posedge clk);#1;
    if(n!=0)$fatal(1,"stalled response leaked bytes");
    random_ready=1;
    repeat(400)@(posedge clk);#1;
    if(n!=16)$fatal(1,"expected intact active and pending frames, got %0d bytes",n);
    check_frame(0,0,16'h0007);check_frame(8,4,16'hABCD);
    if(requests!==11||drops!==1)$fatal(1,"request/pending counts expected=11/1 actual=%0d/%0d",requests,drops);
    if(stalled<100)$fatal(1,"ready-stall coverage missing");
    if(errors)$fatal(1,"FXSTAT wire values lost/truncated: %0d responses",errors);
    $display("PASS: FXSTAT full 16-bit values, reserved zeros, random ready stalls, intact active/latest pending snapshots and overwrite count");
    $finish;
  end
endmodule
