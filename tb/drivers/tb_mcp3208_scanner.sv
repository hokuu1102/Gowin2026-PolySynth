`timescale 1ns/1ps

module tb_mcp3208_scanner;

    localparam integer CLK_PERIOD_NS = 20;
    localparam integer FRAME_PERIOD_NS = 500_000;

    reg clk;
    reg rst_n;
    reg enable;
    reg adc_miso;

    wire [2:0]  sample_channel;
    wire [11:0] sample_data;
    wire        sample_valid;
    wire        frame_done;

    wire adc_cs_n;
    wire adc_sclk;
    wire adc_mosi;

    integer sclk_rising_count;
    integer transaction_count;
    integer sample_count;
    integer frame_count;

    reg [23:0] captured_mosi;
    reg [2:0]  response_channel;
    reg [11:0] response_value;
    reg [2:0]  expected_sample_channel;

    time first_frame_time;
    time second_frame_time;

    mcp3208_scanner #(
        .CLK_HZ          (50_000_000),
        .SCLK_HZ         (1_000_000),
        .CHANNEL_RATE_HZ (2_000)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (enable),

        .sample_channel (sample_channel),
        .sample_data    (sample_data),
        .sample_valid   (sample_valid),
        .frame_done     (frame_done),

        .adc_cs_n       (adc_cs_n),
        .adc_sclk       (adc_sclk),
        .adc_mosi       (adc_mosi),
        .adc_miso       (adc_miso)
    );

    // 这些固定值来自测试规格，不复用DUT内部的通道编码逻辑。
    function automatic [11:0] adc_value_for_channel(
        input [2:0] test_channel
    );
        begin
            case (test_channel)
                3'd0: adc_value_for_channel = 12'h001;
                3'd1: adc_value_for_channel = 12'h123;
                3'd2: adc_value_for_channel = 12'h456;
                3'd3: adc_value_for_channel = 12'h789;
                3'd4: adc_value_for_channel = 12'hABC;
                3'd5: adc_value_for_channel = 12'hA5C;
                3'd6: adc_value_for_channel = 12'hDEF;
                3'd7: adc_value_for_channel = 12'hFFF;
                default: adc_value_for_channel = 12'h000;
            endcase
        end
    endfunction

    function automatic [23:0] command_for_channel(
        input [2:0] test_channel
    );
        begin
            case (test_channel)
                3'd0: command_for_channel = 24'h060000;
                3'd1: command_for_channel = 24'h064000;
                3'd2: command_for_channel = 24'h068000;
                3'd3: command_for_channel = 24'h06C000;
                3'd4: command_for_channel = 24'h070000;
                3'd5: command_for_channel = 24'h074000;
                3'd6: command_for_channel = 24'h078000;
                3'd7: command_for_channel = 24'h07C000;
                default: command_for_channel = 24'h000000;
            endcase
        end
    endfunction

    always #(CLK_PERIOD_NS / 2) begin
        clk = ~clk;
    end

    // 每次CS拉低都开始一笔新的24位SPI事务。
    always @(negedge adc_cs_n) begin
        sclk_rising_count = 0;
        captured_mosi     = 24'd0;
        response_channel  = 3'd0;
        response_value    = 12'd0;
    end

    // MCP3208在SCLK上升沿读取DIN。
    always @(posedge adc_sclk) begin
        if (adc_cs_n == 1'b0) begin
            sclk_rising_count = sclk_rising_count + 1;
            captured_mosi = {
                captured_mosi[22:0],
                adc_mosi
            };
        end
    end

    // MCP3208在SCLK下降沿更新DOUT。
    always @(negedge adc_sclk or posedge adc_cs_n) begin
        if (adc_cs_n) begin
            adc_miso = 1'b0;
        end
        else begin
            // 第10个上升沿后，D2:D0已经全部收到。
            if (sclk_rising_count == 10) begin
                response_channel = captured_mosi[2:0];
                response_value =
                    adc_value_for_channel(captured_mosi[2:0]);
            end

            // 第12个下降沿后送出B11，供第13个上升沿采样。
            if ((sclk_rising_count >= 12) &&
                (sclk_rising_count <= 23)) begin
                adc_miso =
                    response_value[23 - sclk_rising_count];
            end
            else begin
                adc_miso = 1'b0;
            end
        end
    end

    // 在CS回到高电平时验证刚结束的SPI事务。
    always @(posedge adc_cs_n) begin
        if (rst_n && (sclk_rising_count != 0)) begin
            #1;

            if (sclk_rising_count !== 24) begin
                $fatal(
                    1,
                    "FAIL SPI CH%0d: clocks=%0d, expected 24",
                    response_channel,
                    sclk_rising_count
                );
            end

            if (captured_mosi !== command_for_channel(response_channel)) begin
                $fatal(
                    1,
                    "FAIL SPI CH%0d: MOSI=%06h, expected=%06h",
                    response_channel,
                    captured_mosi,
                    command_for_channel(response_channel)
                );
            end

            transaction_count = transaction_count + 1;
        end
    end

    // 只通过扫描器公开输出检查通道顺序和采样结果。
    always @(posedge clk) begin
        if (rst_n) begin
            #1;

            if (sample_valid) begin
                if (sample_channel !== expected_sample_channel) begin
                    $fatal(
                        1,
                        "FAIL sample order: channel=%0d, expected=%0d",
                        sample_channel,
                        expected_sample_channel
                    );
                end

                if (sample_data !==
                    adc_value_for_channel(expected_sample_channel)) begin
                    $fatal(
                        1,
                        "FAIL CH%0d: data=%03h, expected=%03h",
                        expected_sample_channel,
                        sample_data,
                        adc_value_for_channel(expected_sample_channel)
                    );
                end

                sample_count = sample_count + 1;

                if (expected_sample_channel == 3'd7) begin
                    expected_sample_channel = 3'd0;
                end
                else begin
                    expected_sample_channel =
                        expected_sample_channel + 1'b1;
                end
            end

            if (frame_done) begin
                if (!sample_valid || (sample_channel !== 3'd7)) begin
                    $fatal(
                        1,
                        "FAIL: frame_done must coincide with valid CH7"
                    );
                end

                frame_count = frame_count + 1;

                if (frame_count == 1) begin
                    first_frame_time = $time;
                end
                else if (frame_count == 2) begin
                    second_frame_time = $time;
                end
            end
        end
    end

    initial begin
        $dumpfile("build/sim/mcp3208/mcp3208_scanner_tb.vcd");
        $dumpvars(0, tb_mcp3208_scanner);

        clk                     = 1'b0;
        rst_n                   = 1'b0;
        enable                  = 1'b0;
        adc_miso                = 1'b0;
        sclk_rising_count       = 0;
        transaction_count       = 0;
        sample_count            = 0;
        frame_count             = 0;
        captured_mosi           = 24'd0;
        response_channel        = 3'd0;
        response_value          = 12'd0;
        expected_sample_channel = 3'd0;
        first_frame_time        = 0;
        second_frame_time       = 0;

        #100;

        @(negedge clk);
        rst_n  = 1'b1;
        enable = 1'b1;

        wait (frame_count == 2);
        #10;

        if (sample_count !== 16) begin
            $fatal(
                1,
                "FAIL: samples=%0d, expected 16",
                sample_count
            );
        end

        if (transaction_count !== 16) begin
            $fatal(
                1,
                "FAIL: SPI transactions=%0d, expected 16",
                transaction_count
            );
        end

        if ((second_frame_time - first_frame_time) !==
            FRAME_PERIOD_NS) begin
            $fatal(
                1,
                "FAIL: frame period=%0d ns, expected=%0d ns",
                second_frame_time - first_frame_time,
                FRAME_PERIOD_NS
            );
        end

        $display(
            "PASS: 2 frames, 16 samples, frame period=%0d ns",
            second_frame_time - first_frame_time
        );

        #100;
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "FAIL: scanner simulation timeout");
    end

endmodule
