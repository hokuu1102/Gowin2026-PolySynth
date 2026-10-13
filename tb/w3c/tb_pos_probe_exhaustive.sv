`timescale 1ns/1ps
// Public packet seam: independent decimal oracle for every 12-bit value.
module tb_pos_probe_exhaustive;
    parameter [7:0] PREFIX = 8'h50;
    reg clk=0,rst_n=0,req=0,ready=1,idle=1;
    reg [11:0] pos=0;
    reg [3:0] ch=0;
    always #10 clk=~clk;
    wire push,busy,active;
    wire [7:0] data;
    pos_probe #(.PREFIX(PREFIX),.QUEUE_WHEN_BLOCKED(1)) dut (
        .clk_i(clk),.rst_n_i(rst_n),.probe_req_i(req),.pos_i(pos),.ch_i(ch),
        .push_o(push),.data_o(data),.ready_i(ready),.idle_i(idle),
        .busy_o(busy),.packet_active_o(active));
    integer count=0;
    reg [7:0] bytes[0:7];
    always @(posedge clk) if(rst_n && push) begin
        if(count>=8) $fatal(1,"FAIL: extra packet byte");
        bytes[count]=data;
        count=count+1;
    end
    integer v,k,cycles;
    reg [3:0] requested_ch;
    reg [7:0] expected;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(v=0;v<4096;v=v+1) begin
            count=0;requested_ch=v%16;pos=v;ch=requested_ch;
            idle=(v%17)!=0;
            @(negedge clk);req=1;
            @(negedge clk);req=0;pos=4095-v;ch=~requested_ch;
            if(!idle) begin
                repeat(20) @(negedge clk);
                if(count!=0 || busy!==1 || active!==0)
                    $fatal(1,"FAIL: blocked request not retained value=%0d",v);
                idle=1;
            end
            cycles=0;
            while(count<8 && cycles<100) begin
                @(negedge clk);cycles=cycles+1;
            end
            if(count!=8) $fatal(1,"FAIL: packet timeout value=%0d",v);
            for(k=0;k<8;k=k+1) begin
                case(k)
                    0:expected=PREFIX;
                    1:expected=requested_ch<10 ? 8'h30+requested_ch : 8'h41+requested_ch-10;
                    2:expected=8'h30+v/1000;
                    3:expected=8'h30+(v/100)%10;
                    4:expected=8'h30+(v/10)%10;
                    5:expected=8'h30+v%10;
                    6:expected=8'h0d;
                    7:expected=8'h0a;
                endcase
                if(bytes[k]!==expected)
                    $fatal(1,"FAIL: value=%0d byte=%0d got=%h expected=%h",v,k,bytes[k],expected);
            end
            repeat(4) @(negedge clk);
            if(busy!==0 || active!==0 || push!==0) $fatal(1,"FAIL: packet did not finish");
        end
        $display("PASS: all 4096 values, 16 channel tags, snapshot mutation and blocked queue PREFIX=%h",PREFIX);
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL: exhaustive watchdog");end
endmodule
