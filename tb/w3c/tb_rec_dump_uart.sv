`timescale 1ns/1ps
`default_nettype none
module tb_rec_dump_uart;
    reg clk=0,rst_n=0,req=0;
    always #10 clk=~clk;
    wire push,ready,done,dump_busy,ovf,start,uart_busy,serial,rx_done;
    wire [7:0] byte_value,drop,tx_data,rx_data;
    wire [15:0] frames;
    integer received=0;
    reg [7:0] bytes [0:17];
    always @(posedge clk) if(rx_done) begin
        if(received<18) bytes[received]=rx_data;
        received=received+1;
    end
    rec_dump dut(.clk_i(clk),.rst_n_i(rst_n),.req_i(req),.idle_i(1'b1),
        .cnt_i(16'd2),.data_i(64'h0123456789abcdef),.clip_i(1'b0),
        .ready_i(ready),.push_o(push),.byte_o(byte_value),.busy_o(dump_busy),
        .done_o(done),.frame_cnt_o(frames));
    uart_tx_fifo fifo(.clk_i(clk),.rst_n_i(rst_n),.push_i(push),
        .data_i(byte_value),.ready_o(ready),.busy_i(uart_busy),.ovf_o(ovf),
        .tx_start_o(start),.tx_data_o(tx_data),.drop_cnt_o(drop),.ovf_clr_i(1'b0));
    uart_tx #(.BAUD_DIV(100)) tx(.clk_i(clk),.rst_n_i(rst_n),.tx_start_i(start),
        .tx_data_i(tx_data),.tx_o(serial),.busy_o(uart_busy));
    uart_rx #(.BAUD_DIV(100)) rx(.clk_i(clk),.rst_n_i(rst_n),.rx_i(serial),
        .rx_data_o(rx_data),.rx_done_o(rx_done));
    reg [71:0] expected;
    integer i;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;req=1;
        @(negedge clk);req=0;
        repeat(30000) @(negedge clk);
        if(ovf || drop!=0 || received!=18 || frames!=2)
            $fatal(1,"FAIL: export frames=%0d drop=%0d bytes=%0d",frames,drop,received);
        expected=72'hA50123456789ABCDEF;
        for(i=0;i<9;i=i+1) begin
            if(bytes[i] !== expected[71-i*8 -: 8] || bytes[i+9] !== bytes[i])
                $fatal(1,"FAIL: export byte %0d corrupted",i);
        end
        $display("PASS: two complete 9-byte frames through real FIFO and 500kbps UART");
        $finish;
    end
endmodule
`default_nettype wire
