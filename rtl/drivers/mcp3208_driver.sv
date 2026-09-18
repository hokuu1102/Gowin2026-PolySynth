`timescale 1ns/1ps

module mcp3208_driver #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCLK_HZ = 1_000_000
)(
    //FPGA 内部控制接口
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [2:0]  channel,

    output reg  [11:0] adc_data,
    output reg         busy,
    output reg         done,

    //  MCP3208 SPI 接口
    output reg         adc_cs_n,
    output reg         adc_sclk,
    output reg         adc_mosi,
    input  wire        adc_miso

);

    localparam integer HALF_DIV_RAW =
        CLK_HZ / (2 * SCLK_HZ);

    localparam integer HALF_DIV =
        (HALF_DIV_RAW<1) ? 1 : HALF_DIV_RAW;

    localparam integer DIV_WIDTH =
        (HALF_DIV <= 1) ? 1 :$clog2(HALF_DIV);

    reg [DIV_WIDTH-1:0] div_counter;

    reg [4:0] bit_counter;
    reg [23:0] tx_shift;
    reg [23:0] rx_shift;

    reg[2:0] channel_latched;

    localparam [1:0] STATE_IDLE = 2'd0;             //等待start信号
    localparam [1:0] STATE_SCLK_LOW = 2'd1;         //保持spi时钟为低
    localparam [1:0] STATE_SCLK_HIGH = 2'd2;        //保持spi时钟为高
    localparam [1:0] STATE_FINISH = 2'd3;           //保存结果并产生done信号

    reg [1:0] state;




    always @(posedge clk) begin
        if (!rst_n) begin
            div_counter      <= {DIV_WIDTH{1'b0}};
            bit_counter      <= 5'd0;
            tx_shift         <= 24'd0;
            rx_shift         <= 24'd0;
            channel_latched   <= 3'd0;

            state            <= STATE_IDLE;

            adc_data         <= 12'd0;
            busy             <= 1'b0;
            done             <= 1'b0;

            adc_cs_n         <= 1'b1;
            adc_sclk         <= 1'b0;
            adc_mosi         <= 1'b0;

        end
        else begin
            // done 只允许维持一个系统时钟周期
            done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;
                    busy     <= 1'b0;

                    div_counter <= {DIV_WIDTH{1'b0}};
                    bit_counter <= 5'd0;

                    if(start) begin
                        channel_latched <= channel;

                        tx_shift <= {
                            5'b00000,
                            1'b1,
                            1'b1,
                            channel[2],
                            channel[1:0],
                            14'd0
                        };

                        rx_shift <= 24'd0;
                        adc_cs_n <= 1'b0;
                        adc_sclk <= 1'b0;
                        busy     <= 1'b1;
                        state    <= STATE_SCLK_LOW;
                    end
                end


                STATE_SCLK_LOW: begin
                    if(div_counter == HALF_DIV-1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};

                        //产生spi时钟的上升沿
                        adc_sclk <= 1'b1;

                        //mode 0 :在上升沿读取MISO数据
                        rx_shift <= {rx_shift[22:0], adc_miso};

                        state <= STATE_SCLK_HIGH;
                end
                else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                STATE_SCLK_HIGH: begin
                    if(div_counter == HALF_DIV-1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};

                        //产生spi时钟的下降沿
                        adc_sclk <= 1'b0;

                        if(bit_counter == 5'd23) begin
                            //第24位已经在上一个上升沿完成采样
                            state <= STATE_FINISH;
                end
                else begin
                            //准备传输下一位
                            bit_counter <= bit_counter + 1'b1;

                            adc_mosi <= tx_shift[22];
                            tx_shift <= {tx_shift[22:0], 1'b0};

                            state <= STATE_SCLK_LOW;
                        end
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                STATE_FINISH: begin
                    //结束SPI通信并恢复Mode 0空闲电平
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;

                    //24位接收帧的最低12位就是ADC的采样结果
                    adc_data <= rx_shift[11:0];

                    //保证两次转换之间有足够的CS高电平时间
                    if(div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};

                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= STATE_IDLE;
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                default: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b0;
                    adc_mosi <= 1'b0;
                    busy     <= 1'b0;
                    state    <= STATE_IDLE;

                end
            endcase
        end










    end
















endmodule