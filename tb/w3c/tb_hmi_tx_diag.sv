`timescale 1ns/1ps
module tb_hmi_tx_diag;
  reg clk=0;always #10 clk=~clk;
  reg rst=0,query=0,grant=0,ui_active=0,ui_start=0,owned=1,ui_busy=0;
  reg [7:0] ui_data=0;
  wire tx_start,active,pending;
  wire [7:0] tx_data;
  reg [7:0] drop=8'h12; reg overflow=1;
  reg [7:0] expected[0:29];integer count=0,hold=0;
  reg tx_busy=0;
  reg uart_done=0;
  hmi_tx_diag dut(.clk_i(clk),.rst_n_i(rst),.query_i(query),.grant_i(grant),
    .ui_active_i(ui_active),.ui_start_i(ui_start),.ui_owned_i(owned),
    .uart_busy_i(ui_busy|tx_busy),.uart_done_i(uart_done),.ui_data_i(ui_data),
    .fifo_drop_i(drop),.fifo_overflow_i(overflow),.pending_o(pending),
    .active_o(active),.tx_start_o(tx_start),.tx_data_o(tx_data));
  always @(posedge clk)if(rst)begin
    if(hold>0)begin hold<=hold-1;if(hold==1)tx_busy<=0;end
    if(tx_start)begin
      if(tx_busy || !grant)$fatal(1,"diagnostic starts while blocked");
      if(count>=30 || tx_data!==expected[count])$fatal(1,"diagnostic byte %0d got %02x expected %02x",count,tx_data,expected[count]);
      count=count+1;tx_busy<=1;hold<=5;
    end
  end
  task byte_in(input [7:0] b);
    begin @(negedge clk);ui_data=b;ui_start=1;@(negedge clk);ui_start=0;end
  endtask
  reg [239:0] reply;
  integer i;
  initial begin
    repeat(4)@(negedge clk);rst=1;
    ui_active=1;byte_in("x");byte_in(255);byte_in(255);byte_in(255);ui_active=0;
    // The last FF is accepted, but the frame is not yet physically complete.
    repeat(3)@(negedge clk);
    if(dut.completed_q!==0)$fatal(1,"frame completed before physical TX done");
    uart_done=1;@(negedge clk);uart_done=0;
    ui_busy=1;byte_in("!");ui_busy=0;
    owned=0;byte_in("!");owned=1;
    query=1;@(negedge clk);query=0;repeat(5)@(negedge clk);
    if(!pending || active || count)$fatal(1,"query did not wait for ownership");
    reply={"HMI 000100010000000400021201",8'd13,8'd10};
    for(i=0;i<30;i=i+1)expected[i]=reply>>(8*(29-i));
    grant=1;
    wait(active);drop=0;overflow=0; // Snapshot must survive changing inputs.
    wait(!active);repeat(10)@(negedge clk);
    if(count!=30 || pending)$fatal(1,"incomplete diagnostic reply");
    $display("PASS: physical completion accounting, illegal starts, snapshot, ownership and backpressure");$finish;
  end
  initial begin #100000;$fatal(1,"diagnostic deadline");end
endmodule
