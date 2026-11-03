`timescale 1ns/1ps
`default_nettype none
module tb_uart_ui_page_sync;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,rx_done=0;reg [7:0] rx_data=0;
    reg [2:0] st_fxmask=0;
    wire tx_start;wire [7:0] tx_data;
    reg [7:0] cap[0:16383];integer errors=0,nchecks=0;
    uart_ui #(.CLK_HZ(50000000),.BAUD(115200),.HB_MS(1000)) dut(
      .clk_i(clk),.rst_n_i(rst_n),.rx_done_i(rx_done),.rx_data_i(rx_data),
      .tx_busy_i(1'b0),.tx_done_i(1'b0),.tx_start_o(tx_start),.tx_data_o(tx_data),
      .st_fxmask_i(st_fxmask));
    task chk(input [879:0] label,input cond);
      begin nchecks=nchecks+1;if(!cond)begin errors=errors+1;$display("FAIL: %0s",label);end
      else $display("ok: %0s",label);end
    endtask
    task feed(input [7:0] value);
      begin @(negedge clk);rx_data=value;rx_done=1;@(negedge clk);rx_done=0;end
    endtask
    task feed_frame_z(input [7:0] code,input [7:0] id,input [7:0] value);
      begin feed(code);feed(id);feed(value);feed(255);feed(255);feed(255);end
    endtask
    task feed_frame(input [7:0] code,input [7:0] unused0,input [7:0] unused1);
      begin feed(code);feed(255);feed(255);feed(255);end
    endtask
    integer seen=0;
    reg collecting=0;
    always @(negedge clk) if(collecting && tx_start)begin
        cap[seen]=tx_data;seen=seen+1;
    end
    function integer has_command(input [511:0] text,input integer len);
        integer i,k;reg ok;begin
            has_command=0;
            for(i=0;i<=seen-len-3;i=i+1)begin
                ok=(i==0 || (cap[i-1]==255 && cap[i-2]==255 && cap[i-3]==255));
                for(k=0;k<len;k=k+1)if(cap[i+k]!==((text>>(8*(len-1-k)))&255))ok=0;
                if(ok && cap[i+len]==255 && cap[i+len+1]==255 && cap[i+len+2]==255)has_command=has_command+1;
            end
        end
    endfunction
    task settle;
        begin repeat(6000)@(negedge clk);end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
        collecting=1;
        feed_frame_z(8'h71,6,1);feed_frame(8'h88,0,0);settle;
        chk("page1 corrects global memory from actual DSP mask",has_command("fx0=0",5)>0 && has_command("fx1=0",5)>0 && has_command("fx2=0",5)>0);
        chk("page1 headers restore gray",has_command("b_dist_hdr.bco=52857",20)>0 && has_command("b_chor_hdr.bco=52857",20)>0 && has_command("b_dly_hdr.bco=52857",19)>0);
        chk("page1 does not address private page0 controls",has_command("led_dist.val=0",14)==0);
        seen=0;st_fxmask=3'b101;settle;
        chk("external changes correct all remembered bits",has_command("fx0=1",5)==1 && has_command("fx1=0",5)==1 && has_command("fx2=1",5)==1);
        chk("external changes correct loaded header colors",has_command("b_dist_hdr.bco=64608",20)==1 && has_command("b_chor_hdr.bco=52857",20)==1 && has_command("b_dly_hdr.bco=38943",19)==1);
        seen=0;feed_frame_z(8'h71,6,0);settle;
        chk("page0 refresh restores real LEDs",has_command("led_dist.val=1",14)==1 && has_command("led_chor.val=0",14)==1 && has_command("led_dly.val=1",13)==1);
        chk("page0 refresh retains actual memory",has_command("fx0=1",5)==1 && has_command("fx2=1",5)==1);
        chk("page0 does not address private page1 headers",has_command("b_dist_hdr.bco=64608",20)==0);
        seen=0;feed_frame_z(8'h71,6,2);settle;
        chk("invalid page announcement ignored",seen==0);
        if(errors)$fatal(1,"FAIL: page state synchronization %0d",errors);
        $display("PASS: page-scoped effect synchronization (%0d checks)",nchecks);$finish;
    end
    initial begin #20000000;$fatal(1,"page sync watchdog");end
endmodule
`default_nettype wire
