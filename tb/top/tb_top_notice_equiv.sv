`timescale 1ns/1ps
module tb_top_notice_equiv;
    reg clk=0,rst_n=0,command_rx=1;
    reg [11:0] hall=12'h7c1;
    always #10 clk=~clk;
    wire sck,mosi,board_tx,esp_tx;
    wire [5:0] cs,miso;
    top #(.SCOPE_MODE(0),.TEST_MODE_EN(0),.RIGHT_ADC_ENABLE(0),
        .AUTOTARE_DELAY_CLK(10000),.DEMO_NOTE_DELAY(10000000)) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(command_rx),.uart_tx(board_tx),
        .esp_uart_rx_i(1'b1),.esp_uart_tx_o(esp_tx),.timbre_btn_i(1'b1),
        .pluck_up_i(1'b0),.pluck_down_i(1'b0),.spi_sclk(sck),
        .spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso));
    // Simulation-only peripheral acceleration. System/audio/UART clocks unchanged.
    defparam dut.g_sound.u_adc_farm.CHANNEL_RATE_HZ=20000;
    defparam dut.g_sound.u_adc_farm.SCLK_HZ=5000000;
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
    reg [7:0] first_dump[0:17];
    // Optional public-pin trace for cycle-exact before/after timing experiments.
    // No internal register or simulated producer is forced.
    integer trace_fd=0;
    reg [4095:0] trace_path;
    initial begin
        if($value$plusargs("TRACE_PATH=%s",trace_path)) begin
            trace_fd=$fopen(trace_path,"w");
            if(!trace_fd) $fatal(1,"FAIL: cannot open public-pin trace");
        end
    end
    always @(negedge clk) if(rst_n && trace_fd)
        $fdisplay(trace_fd,"%b%b%b%b%b%b%b%b",board_tx,esp_tx,cs,sck,mosi,
                  dut.HP_BCK,dut.HP_WS,dut.HP_DIN);
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
    integer i;
    integer probe_value;
    reg [111:0] footer="y000200020003\n";
    initial begin
        repeat(12) @(negedge clk);rst_n=1;
        repeat(40000) @(negedge clk);
        send("R");
        hall=12'h4d9;repeat(12000) @(negedge clk);
        hall=12'h7c1;repeat(12000) @(negedge clk);
        send("R");repeat(2000) @(negedge clk);
        capture=1;count=0;
        send("Y");send("P");send("L");send("R");send("C");send("E");
        repeat(40000) @(negedge clk);
        if(count!=43 || bytes[0]!==8'hA5 || bytes[9]!==8'hA5)
            $fatal(1,"FAIL: atomic export absent/corrupt count=%0d",count);
        for(i=0;i<14;i=i+1)
            if(bytes[i+18]!==footer[111-i*8 -: 8])
                $fatal(1,"FAIL: footer/interleaving at %0d got=%02h",i,bytes[i+18]);
        for(i=0;i<18;i=i+1) first_dump[i]=bytes[i];
        // Probe reports the chip's live scan value. At rest, every channel in
        // this external ADC model is in 1985..1992 (inverted 2103..2110).
        if({bytes[32],bytes[33],bytes[34],bytes[35],bytes[36]} !== "!!!P0" ||
            bytes[41]!=13 || bytes[42]!=10) $fatal(1,"FAIL: deferred probe framing");
        probe_value=0;
        for(i=37;i<=40;i=i+1) begin
            if(bytes[i]<"0" || bytes[i]>"9") $fatal(1,"FAIL: probe digits");
            probe_value=probe_value*10+bytes[i]-"0";
        end
        if(probe_value<2103 || probe_value>2110) $fatal(1,"FAIL: deferred probe snapshot %0d",probe_value);
        count=0;send("Y");repeat(40000) @(negedge clk);
        if(count<32) $fatal(1,"FAIL: R/L/C changed layer while exporting");
        for(i=0;i<18;i=i+1)
            if(bytes[i]!==first_dump[i]) $fatal(1,"FAIL: recording changed at byte %0d",i);
        $display("PASS: accelerated public-pin notification equivalence fixture, legacy 9-byte dump and three notices");
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL: top dump watchdog");end
endmodule
