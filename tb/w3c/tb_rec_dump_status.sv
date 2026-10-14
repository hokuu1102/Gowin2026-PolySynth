`timescale 1ns/1ps
module tb_rec_dump_status;
    reg clk=0,rst_n=0,req=0;
    always #10 clk=~clk;
    wire push,busy,uart_busy,serial,rx_done;
    wire [7:0] value,rx_data;
    integer received=0;
    reg [7:0] bytes[0:47];      // ⭐ 2026-10-14：⭐ 2×14 帧 ＋ 14 状态 = **42 字节**（⭐ 原 32 ✅）
    always @(posedge clk) if(rx_done) begin
        if(received<48) bytes[received]=rx_data;
        received=received+1;
    end
    rec_dump #(.STATUS_ENABLE(1)) dut(.clk_i(clk),.rst_n_i(rst_n),.req_i(req),
        .idle_i(1'b1),.cnt_i(16'd2),.data_i(64'h0123456789abcdef),
        .clip_i(1'b1),.reject_count_i(16'd3),.ready_i(!uart_busy),
        .push_o(push),.byte_o(value),.busy_o(busy));
    uart_tx #(.BAUD_DIV(100)) tx(.clk_i(clk),.rst_n_i(rst_n),.tx_start_i(push),
        .tx_data_i(value),.tx_o(serial),.busy_o(uart_busy));
    uart_rx #(.BAUD_DIV(100)) rx(.clk_i(clk),.rst_n_i(rst_n),.rx_i(serial),
        .rx_data_o(rx_data),.rx_done_o(rx_done));
    reg [111:0] expected="y000200020003\n";
    integer i;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;req=1;
        @(negedge clk);req=0;
        //  ⭐ 2026-10-14：⭐ 帧从 9 B 变成 **14 B** ⇒ ⚠️ 同样的 2 帧要多发 10 个字节
        //     ⇒ 🔴 **实测：原来的 36000 拍不够**（⭐ 只收到 36/42）⇒ ⭐ 加长到 52000 ✅
        repeat(52000) @(negedge clk);
        //  ⭐ 2026-10-14：⭐ 帧宽 **9 B → 14 B** ⇒ ⭐ 2×14 ＋ 14 = **42 字节**（⭐ 原 32 ✅）
        if(received!=42 || busy) $fatal(1,"FAIL: status byte count %0d (expected 42)",received);
        //  ⭐ 第 0 帧头在 0、⭐ 第 1 帧头在 **14**（⭐ 原来是 9 ✅）
        if(bytes[0]!=8'hA5 || bytes[14]!=8'hA5) $fatal(1,"FAIL: frame headers (bytes[14] should be the 2nd frame's 0xA5)");
        //  ⭐ 尾部状态文本跟在 **28** 字节之后（⭐ 原来是 18 ✅）
        for(i=0;i<14;i=i+1)
            if(bytes[i+28]!==expected[111-i*8 -: 8]) $fatal(1,"FAIL: footer byte %0d",i);
        $display("PASS: atomic record frames and public frame/loss/reject footer");$finish;
    end
endmodule
