`timescale 1ns/1ps
// Public UART/ADC seam: three pending packets must drain without interleaving.
module tb_top_probe_queue;
    reg clk=0,rst_n=0,command_rx=1;
    reg [11:0] hall=12'h7c1;
    always #10 clk=~clk;
    wire sck,mosi,board_tx,esp_tx;
    wire [5:0] cs,miso;
    top #(.SCOPE_MODE(0),.TEST_MODE_EN(0),.RIGHT_ADC_ENABLE(0),
        .AUTOTARE_DELAY_CLK(100000),.DEMO_NOTE_DELAY(10000000)) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(command_rx),.uart_tx(board_tx),
        .esp_uart_rx_i(1'b1),.esp_uart_tx_o(esp_tx),.timbre_btn_i(1'b1),
        .pluck_up_i(1'b0),.pluck_down_i(1'b0),.spi_sclk(sck),
        .spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso));
    mcp3208_model #(.IDVAL(12'h7c1)) adc0(.cs_n(cs[0]),.sclk(sck),.mosi(mosi),
        .miso(miso[0]),.ch_mask_i(8'h01),.ch_val_i(hall));
    mcp3208_model #(.IDVAL(12'h7c1)) adc1(.cs_n(cs[1]),.sclk(sck),.mosi(mosi),.miso(miso[1]));
    assign miso[5:2]=4'b1111;
    wire rx_done;
    wire [7:0] rx_data;
    uart_rx #(.BAUD_DIV(100)) monitor(.clk_i(clk),.rst_n_i(rst_n),.rx_i(board_tx),
        .rx_data_o(rx_data),.rx_done_o(rx_done));
    integer count=0;
    reg capture=0;
    reg [7:0] bytes[0:255];
    always @(posedge clk) if(rst_n) begin
        if(board_tx!==esp_tx) $fatal(1,"FAIL: UART mirrors disagree");
        if(capture && rx_done) begin
            if(count<256) bytes[count]=rx_data;
            count=count+1;
        end
    end
    task send(input [7:0] b);
        integer k;
        begin
            @(negedge clk);command_rx=0;repeat(100) @(negedge clk);
            for(k=0;k<8;k=k+1) begin command_rx=b[k];repeat(100) @(negedge clk);end
            command_rx=1;repeat(150) @(negedge clk);
        end
    endtask
    task decimal_packet(input integer offset,input [7:0] prefix);
        integer k,value;
        begin
            if(bytes[offset]!==prefix || bytes[offset+1]!=="0" ||
               bytes[offset+6]!==13 || bytes[offset+7]!==10)
                $fatal(1,"FAIL: packet framing offset=%0d",offset);
            value=0;
            for(k=offset+2;k<offset+6;k=k+1) begin
                if(bytes[k]<"0" || bytes[k]>"9") $fatal(1,"FAIL: packet digits");
                value=value*10+bytes[k]-"0";
            end
            if(value>4095) $fatal(1,"FAIL: 12-bit probe out of range");
            if(prefix=="P" && (value<2103 || value>2110))
                $fatal(1,"FAIL: first P snapshot overwritten by duplicate P");
        end
    endtask
    integer i;
    reg [111:0] footer="y000200020004\n";
    initial begin
        repeat(12) @(negedge clk);rst_n=1;
        repeat(200000) @(negedge clk);
        send("R");
        hall=12'h4d9;repeat(60000) @(negedge clk);
        hall=12'h7c1;repeat(60000) @(negedge clk);
        send("R");repeat(2000) @(negedge clk);
        capture=1;count=0;
        send("Y");send("P");send("N");send("V");send("P");
        send("L");send("R");send("C");send("E");
        repeat(80000) @(negedge clk);
        //  ⭐⭐ 2026-10-14：⭐ **帧宽 9 B → 14 B ⇒ 偏移全部 +10，总数 59 → 69** ✅
        //     📌 新账：2×14 = 28 事件字节 ＋ 14 尾 ＋ 4 拒绝通知 ＋ N(8) ＋ V(7) ＋ P(8)
        //        = **69** ✅（⭐ 旧账 2×9 = 18 ⇒ 59 ✅）
        if(count!=69 || bytes[0]!==8'hA5 || bytes[14]!==8'hA5)
            $fatal(1,"FAIL: queued packet count/framing count=%0d",count);
        for(i=0;i<14;i=i+1)
            if(bytes[i+28]!==footer[111-i*8 -: 8]) $fatal(1,"FAIL: export footer %0d",i);
        for(i=42;i<46;i=i+1)
            if(bytes[i]!=="!") $fatal(1,"FAIL: rejection notice %0d",i);
        decimal_packet(46,"N");
        if({bytes[54],bytes[55],bytes[56],bytes[57],bytes[58],bytes[59],bytes[60]}
           !==56'h56303030300d0a) $fatal(1,"FAIL: V snapshot/packet interleaved got=%h",
               {bytes[54],bytes[55],bytes[56],bytes[57],bytes[58],bytes[59],bytes[60]});
        decimal_packet(61,"P");
        $display("PASS: atomic export, bounded duplicate rejection, complete ordered N/V/P packets");
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL: probe queue watchdog");end
endmodule
