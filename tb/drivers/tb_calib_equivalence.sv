`timescale 1ns/1ps
// Same public stimuli, cycle-exact outputs against frozen AE RTL. Covers
// all ADC codes, eight channels, both median settings and varying limits.
module tb_calib_equivalence;
    reg clk=0, rst_n=0, valid=0, tare=0, span=0;
    reg [2:0] ch=0, cal_ch=0;
    reg [11:0] raw=0;
    always #10 clk=~clk;
    wire [3:0] busy_d, busy_r, err_d, err_r, ov_d, ov_r;
    wire [11:0] oc_d, oc_r;
    wire [47:0] val_d, val_r;
    genvar p;
    generate for(p=0;p<4;p=p+1) begin: profile
        localparam integer LIMIT=(p==1)?744:((p==3)?4095:1023);
        localparam integer MEDIAN=(p==1 || p==2)?1:0;
        calib #(.MAX_TRAVEL(LIMIT),.RAW_MEDIAN_EN(MEDIAN)) dut(
            .clk(clk),.rst_n(rst_n),.valid(valid),.ch(ch),.raw(raw),
            .tare(tare),.span(span),.cal_ch(cal_ch),
            .busy(busy_d[p]),.err(err_d[p]),.out_valid(ov_d[p]),
            .out_ch(oc_d[p*3+:3]),.out_val(val_d[p*12+:12]));
        calib_reference #(.MAX_TRAVEL(LIMIT),.RAW_MEDIAN_EN(MEDIAN)) reference(
            .clk(clk),.rst_n(rst_n),.valid(valid),.ch(ch),.raw(raw),
            .tare(tare),.span(span),.cal_ch(cal_ch),
            .busy(busy_r[p]),.err(err_r[p]),.out_valid(ov_r[p]),
            .out_ch(oc_r[p*3+:3]),.out_val(val_r[p*12+:12]));
    end endgenerate
    integer checks=0;
    always @(posedge clk) begin
        #1;
        if({busy_d,err_d,ov_d,oc_d,val_d} !== {busy_r,err_r,ov_r,oc_r,val_r})
            $fatal(1,"FAIL: cycle-exact calib mismatch check=%0d raw=%0d ch=%0d",checks,raw,ch);
        checks=checks+1;
    end
    task drive(input v,input [2:0] c,input [11:0] r,input t,input s);
        begin @(negedge clk); valid=v;ch=c;cal_ch=c;raw=r;tare=t;span=s;end
    endtask
    integer i,j,k;
    reg [31:0] random_state=32'h6e624eb7;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        // Install eight different zero points through the public tare input.
        for(j=0;j<8;j=j+1) begin
            drive(1,j[2:0],j*500,0,0);
            drive(1,j[2:0],j*500,0,0);
            drive(1,j[2:0],j*500,1,0);
            drive(0,j[2:0],j*500,0,0);
        end
        for(i=0;i<4096;i=i+1)
            for(j=0;j<8;j=j+1) drive(1,j[2:0],i[11:0],0,0);
        // Calibrate gain; include valid and rejected span values on each axis.
        for(j=0;j<8;j=j+1) begin
            for(k=0;k<3;k=k+1) drive(1,j[2:0],j*500+100,0,0);
            drive(1,j[2:0],j*500+100,0,1);
            drive(0,j[2:0],0,0,0);
            repeat(30) @(negedge clk);
            drive(1,j[2:0],0,0,1);
            drive(0,j[2:0],0,0,0);
        end
        // Deterministic back-to-back samples, invalid slots, commands during
        // busy, arbitrary cal_ch, repeated reset and channel history changes.
        for(i=0;i<40000;i=i+1) begin
            @(negedge clk);
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            rst_n=(i%997!=0);
            valid=random_state[16];ch=random_state[2:0];cal_ch=random_state[5:3];
            raw=random_state[27:16];
            tare=(random_state[11:7]==0);span=(random_state[15:12]==0);
        end
        @(negedge clk);rst_n=1;valid=0;tare=0;span=0;
        repeat(40) @(negedge clk);
        if(checks<73000) $fatal(1,"FAIL: equivalence coverage vacuous");
        $display("PASS: calib cycle-exact equivalence checks=%0d profiles=4 exhaustive_codes=4096 channels=8",checks);
        $finish;
    end
    initial begin #3000000;$fatal(1,"FAIL: equivalence timeout");end
endmodule
