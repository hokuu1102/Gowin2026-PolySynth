`timescale 1ns/1ps

module tb_mcp3208_driver;

    localparam integer CLK_PERIOD_NS = 20;

    reg       clk;
    reg       rst_n;
    reg       start;
    reg [2:0] channel;
    reg       adc_miso;

    wire [11:0] adc_data;
    wire        busy;
    wire        done;

    wire adc_cs_n;
    wire adc_sclk;
    wire adc_mosi;

    integer sclk_rising_count;
    reg [23:0] captured_mosi;
    reg [11:0] model_adc_value;

    mcp3208_driver #(
        .CLK_HZ  (50_000_000),
        .SCLK_HZ (1_000_000)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .channel   (channel),

        .adc_data  (adc_data),
        .busy      (busy),
        .done      (done),

        .adc_cs_n  (adc_cs_n),
        .adc_sclk  (adc_sclk),
        .adc_mosi  (adc_mosi),
        .adc_miso  (adc_miso)
    );

    // 产生50 MHz系统时钟：
    // 10 ns翻转一次，完整周期为20 ns。
    always #(CLK_PERIOD_NS / 2) begin
        clk = ~clk;
    end

        // 统计CS有效期间的SPI上升沿数量
    always @(posedge adc_sclk) begin
        if (adc_cs_n == 1'b0) begin
            sclk_rising_count = sclk_rising_count + 1;

            // MCP3208在SCLK上升沿读取DIN
            captured_mosi = {
                captured_mosi[22:0],
                adc_mosi
            };
        end
    end

        // 模拟MCP3208：在SCLK下降沿更新DOUT
    always @(negedge adc_sclk) begin
        if (adc_cs_n == 1'b0) begin
            if ((sclk_rising_count >= 12) &&
                (sclk_rising_count <= 23)) begin

                adc_miso =
                    model_adc_value[23 - sclk_rising_count];
            end
            else begin
                adc_miso = 1'b0;
            end
        end
        else begin
            adc_miso = 1'b0;
        end
    end

    task automatic run_conversion(
        input [2:0]  test_channel,
        input [11:0] test_value
    );
        reg [23:0] expected_command;

        begin
            // 规格书给出的8组单端通道命令，作为独立预期值。
            case (test_channel)
                3'd0: expected_command = 24'h060000;
                3'd1: expected_command = 24'h064000;
                3'd2: expected_command = 24'h068000;
                3'd3: expected_command = 24'h06C000;
                3'd4: expected_command = 24'h070000;
                3'd5: expected_command = 24'h074000;
                3'd6: expected_command = 24'h078000;
                3'd7: expected_command = 24'h07C000;
                default: expected_command = 24'h000000;
            endcase

            wait (busy === 1'b0);

            sclk_rising_count = 0;
            captured_mosi     = 24'd0;
            model_adc_value   = test_value;

            @(negedge clk);
            channel = test_channel;
            start   = 1'b1;

            @(negedge clk);
            start = 1'b0;

            wait (done === 1'b1);
            #1;

            if (sclk_rising_count !== 24) begin
                $fatal(
                    1,
                    "FAIL CH%0d: clocks=%0d, expected 24",
                    test_channel,
                    sclk_rising_count
                );
            end

            if (captured_mosi !== expected_command) begin
                $fatal(
                    1,
                    "FAIL CH%0d: MOSI=%06h, expected=%06h",
                    test_channel,
                    captured_mosi,
                    expected_command
                );
            end

            if (adc_data !== test_value) begin
                $fatal(
                    1,
                    "FAIL CH%0d: ADC=%03h, expected=%03h",
                    test_channel,
                    adc_data,
                    test_value
                );
            end

            if (busy !== 1'b0) begin
                $fatal(1, "FAIL CH%0d: busy should be low", test_channel);
            end

            if (adc_cs_n !== 1'b1) begin
                $fatal(1, "FAIL CH%0d: CS should be high", test_channel);
            end

            if (adc_sclk !== 1'b0) begin
                $fatal(1, "FAIL CH%0d: SCLK should be low", test_channel);
            end

            $display(
                "PASS CH%0d: clocks=%0d, MOSI=%06h, ADC=%03h",
                test_channel,
                sclk_rising_count,
                captured_mosi,
                adc_data
            );

            // done必须只维持一个系统时钟周期。
            @(posedge clk);
            #1;

            if (done !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL CH%0d: done lasted more than one cycle",
                    test_channel
                );
            end
        end
    endtask

    initial begin
        $dumpfile("build/sim/mcp3208/mcp3208_driver_tb.vcd");
        $dumpvars(0, tb_mcp3208_driver);

        clk               = 1'b0;
        rst_n             = 1'b0;
        start             = 1'b0;
        channel           = 3'd0;
        adc_miso          = 1'b0;
        sclk_rising_count = 0;
        captured_mosi     = 24'd0;
        model_adc_value   = 12'd0;

        // 保持复位100 ns
        #100;

        // 在时钟下降沿释放复位，避开上升沿竞争
        @(negedge clk);
        rst_n = 1'b1;

        #100;

        run_conversion(3'd0, 12'h001);
        run_conversion(3'd1, 12'h123);
        run_conversion(3'd2, 12'h456);
        run_conversion(3'd3, 12'h789);
        run_conversion(3'd4, 12'hABC);
        run_conversion(3'd5, 12'hA5C);
        run_conversion(3'd6, 12'hDEF);
        run_conversion(3'd7, 12'hFFF);

        $display("PASS: all MCP3208 channels completed");

        #100;
        $finish;
    end

    // 防止状态机错误导致wait永久等待
    initial begin
        #500_000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule
