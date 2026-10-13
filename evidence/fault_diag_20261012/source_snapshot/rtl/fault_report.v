`timescale 1ns/1ps
// Diagnostic observer only. It must not throttle the production TX FIFO.
// !F2 C S F T U A0 A1 A2 A3 A4 A5 A6 A7 CR LF (hexadecimal ADC2 codes)
module fault_report #(
    parameter integer PERIOD_CLKS=5_000_000,
    parameter integer BAUD_DIV=100
) (
    input wire clk_i, rst_n_i,
    input wire [11:0] sources_i,
    input wire normal_tx_i,
    input wire adc_valid_i,
    input wire [2:0] adc_ch_i,
    input wire [11:0] adc_raw_i,
    output wire tx_o
);
    reg [11:0] sticky, first, cur_snap, sticky_snap, first_snap;
    reg [31:0] clocks, first_clock, time_snap, period;
    reg seen, active, waiting, start;
    reg normal_tx_snap;
    reg [5:0] index;
    reg [95:0] adc_capture, adc_live, adc_snap;
    reg [7:0] data;
    wire busy, done;
    function [7:0] hexchar;
        input [3:0] digit;
        begin hexchar=(digit<10)?(8'h30+digit):(8'h41+digit-10); end
    endfunction
    function [7:0] byte_at;
        input [5:0] n;
        begin
            case(n)
                0: byte_at="!"; 1: byte_at="F"; 2: byte_at="2";
                3,7,11,15,24,26,30,34,38,42,46,50,54: byte_at=" ";
                4: byte_at=hexchar(cur_snap[11:8]);
                5: byte_at=hexchar(cur_snap[7:4]);
                6: byte_at=hexchar(cur_snap[3:0]);
                8: byte_at=hexchar(sticky_snap[11:8]);
                9: byte_at=hexchar(sticky_snap[7:4]);
                10: byte_at=hexchar(sticky_snap[3:0]);
                12: byte_at=hexchar(first_snap[11:8]);
                13: byte_at=hexchar(first_snap[7:4]);
                14: byte_at=hexchar(first_snap[3:0]);
                25: byte_at=normal_tx_snap?"1":"0";
                16: byte_at=hexchar(time_snap[31:28]);
                17: byte_at=hexchar(time_snap[27:24]);
                18: byte_at=hexchar(time_snap[23:20]);
                19: byte_at=hexchar(time_snap[19:16]);
                20: byte_at=hexchar(time_snap[15:12]);
                21: byte_at=hexchar(time_snap[11:8]);
                22: byte_at=hexchar(time_snap[7:4]);
                23: byte_at=hexchar(time_snap[3:0]);
                27: byte_at=hexchar(adc_snap[11:8]);
                28: byte_at=hexchar(adc_snap[7:4]);
                29: byte_at=hexchar(adc_snap[3:0]);
                31: byte_at=hexchar(adc_snap[23:20]);
                32: byte_at=hexchar(adc_snap[19:16]);
                33: byte_at=hexchar(adc_snap[15:12]);
                35: byte_at=hexchar(adc_snap[35:32]);
                36: byte_at=hexchar(adc_snap[31:28]);
                37: byte_at=hexchar(adc_snap[27:24]);
                39: byte_at=hexchar(adc_snap[47:44]);
                40: byte_at=hexchar(adc_snap[43:40]);
                41: byte_at=hexchar(adc_snap[39:36]);
                43: byte_at=hexchar(adc_snap[59:56]);
                44: byte_at=hexchar(adc_snap[55:52]);
                45: byte_at=hexchar(adc_snap[51:48]);
                47: byte_at=hexchar(adc_snap[71:68]);
                48: byte_at=hexchar(adc_snap[67:64]);
                49: byte_at=hexchar(adc_snap[63:60]);
                51: byte_at=hexchar(adc_snap[83:80]);
                52: byte_at=hexchar(adc_snap[79:76]);
                53: byte_at=hexchar(adc_snap[75:72]);
                55: byte_at=hexchar(adc_snap[95:92]);
                56: byte_at=hexchar(adc_snap[91:88]);
                57: byte_at=hexchar(adc_snap[87:84]);
                58: byte_at=8'h0d;
                59: byte_at=8'h0a;
                default: byte_at=8'h3f;
            endcase
        end
    endfunction
    uart_tx #(.BAUD_DIV(BAUD_DIV)) u_tx (
        .clk_i(clk_i),.rst_n_i(rst_n_i),.tx_start_i(start),
        .tx_data_i(data),.tx_o(tx_o),.busy_o(busy),.tx_done_o(done));
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            sticky<=0;first<=0;clocks<=0;first_clock<=0;seen<=0;
            cur_snap<=0;sticky_snap<=0;first_snap<=0;time_snap<=0;
            period<=0;active<=0;waiting<=0;start<=0;index<=0;data<=0;
            normal_tx_snap<=1;
            adc_capture<=0;adc_live<=0;adc_snap<=0;
        end else begin
            clocks<=clocks+1'b1;
            sticky<=sticky | sources_i;
            if(adc_valid_i) begin
                case(adc_ch_i)
                    0:adc_capture[11:0]<=adc_raw_i;
                    1:adc_capture[23:12]<=adc_raw_i;
                    2:adc_capture[35:24]<=adc_raw_i;
                    3:adc_capture[47:36]<=adc_raw_i;
                    4:adc_capture[59:48]<=adc_raw_i;
                    5:adc_capture[71:60]<=adc_raw_i;
                    6:adc_capture[83:72]<=adc_raw_i;
                    7:adc_capture[95:84]<=adc_raw_i;
                endcase
                if(adc_ch_i==7) adc_live<={adc_raw_i,adc_capture[83:0]};
            end
            if(!seen && |sources_i) begin
                seen<=1;first<=sources_i;first_clock<=clocks;
            end
            start<=0;
            if(period!=0) period<=period-1'b1;
            if(!active && period==0) begin
                cur_snap<=sources_i;sticky_snap<=sticky | sources_i;
                normal_tx_snap<=normal_tx_i;
                adc_snap<=adc_live;
                first_snap<=(!seen && |sources_i)?sources_i:first;
                time_snap<=(!seen && |sources_i)?clocks:first_clock;
                active<=1;index<=0;period<=PERIOD_CLKS-1;
            end else if(active && !waiting && !busy) begin
                data<=byte_at(index);start<=1;waiting<=1;
            end else if(waiting && done) begin
                waiting<=0;
                if(index==59) active<=0;
                else index<=index+1'b1;
            end
        end
    end
endmodule
