`timescale 1ns/1ps

module mcp3208_scanner #(
    parameter integer CLK_HZ          = 50_000_000,
    parameter integer SCLK_HZ         = 1_000_000,
    parameter integer CHANNEL_RATE_HZ = 2_000
)(
    input wire clk,
    input wire rst_n,
    input wire enable,

    // 每完成一个通道时输出
    output reg [2:0]  sample_channel,
    output reg [11:0] sample_data,
    output reg        sample_valid,

    // 完成CH0～CH7一轮扫描
    output reg        frame_done,

    // MCP3208物理接口
    output wire adc_cs_n,
    output wire adc_sclk,
    output wire adc_mosi,
    input  wire adc_miso
);

    reg       driver_start;
    reg [2:0] driver_channel;

    wire [11:0] driver_data;
    wire        driver_busy;
    wire        driver_done;

    // One complete CH0..CH7 frame is started every
    // CLK_HZ / CHANNEL_RATE_HZ system-clock cycles.
    localparam integer FRAME_PERIOD_RAW =
        (CHANNEL_RATE_HZ > 0) ? (CLK_HZ / CHANNEL_RATE_HZ) : 1;

    localparam integer FRAME_PERIOD =
        (FRAME_PERIOD_RAW < 1) ? 1 : FRAME_PERIOD_RAW;

    localparam integer FRAME_CNT_WIDTH =
        (FRAME_PERIOD <= 1) ? 1 : $clog2(FRAME_PERIOD);

    localparam [1:0] STATE_IDLE        = 2'd0;
    localparam [1:0] STATE_WAIT_DRIVER = 2'd1;
    localparam [1:0] STATE_WAIT_PERIOD = 2'd2;

    reg [FRAME_CNT_WIDTH-1:0] frame_counter;
    reg [1:0]                 state;

    mcp3208_driver #(
        .CLK_HZ  (CLK_HZ),
        .SCLK_HZ (SCLK_HZ)
    ) driver_inst (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (driver_start),
        .channel   (driver_channel),

        .adc_data  (driver_data),
        .busy      (driver_busy),
        .done      (driver_done),

        .adc_cs_n  (adc_cs_n),
        .adc_sclk  (adc_sclk),
        .adc_mosi  (adc_mosi),
        .adc_miso  (adc_miso)
    );

    // Repository-wide rule: all sequential logic stays in the clk domain.
    // adc_sclk is only an external protocol signal and is never used as an
    // internal FPGA clock here.
    always @(posedge clk) begin
        if (!rst_n) begin
            driver_start   <= 1'b0;
            driver_channel <= 3'd0;

            sample_channel <= 3'd0;
            sample_data    <= 12'd0;
            sample_valid   <= 1'b0;
            frame_done     <= 1'b0;

            frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};
            state          <= STATE_IDLE;
        end
        else begin
            // These outputs are pulses. Individual states assert them only
            // for the cycle in which an event occurs.
            driver_start <= 1'b0;
            sample_valid <= 1'b0;
            frame_done   <= 1'b0;

            if (!enable) begin
                // Disabling the scanner does not asynchronously abort a
                // conversion already running in the lower-level driver.
                // STATE_IDLE waits for driver_busy to clear before restart.
                driver_channel <= 3'd0;
                frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};
                state          <= STATE_IDLE;
            end
            else begin
                case (state)
                    STATE_IDLE: begin
                        driver_channel <= 3'd0;
                        frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};

                        if (!driver_busy) begin
                            // Start a new frame immediately at CH0.
                            driver_start <= 1'b1;
                            state        <= STATE_WAIT_DRIVER;
                        end
                    end

                    STATE_WAIT_DRIVER: begin
                        // Measure the frame period from the CH0 start event.
                        // Saturation makes an overrun start the next frame as
                        // soon as the current frame finishes.
                        if (frame_counter < FRAME_PERIOD - 1) begin
                            frame_counter <= frame_counter + 1'b1;
                        end

                        if (driver_done) begin
                            sample_channel <= driver_channel;
                            sample_data    <= driver_data;
                            sample_valid   <= 1'b1;

                            if (driver_channel == 3'd7) begin
                                frame_done <= 1'b1;
                                state      <= STATE_WAIT_PERIOD;
                            end
                            else begin
                                driver_channel <= driver_channel + 1'b1;
                                driver_start   <= 1'b1;
                            end
                        end
                    end

                    STATE_WAIT_PERIOD: begin
                        if (frame_counter >= FRAME_PERIOD - 1) begin
                            frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};
                            driver_channel <= 3'd0;
                            driver_start   <= 1'b1;
                            state          <= STATE_WAIT_DRIVER;
                        end
                        else begin
                            frame_counter <= frame_counter + 1'b1;
                        end
                    end

                    default: begin
                        driver_start   <= 1'b0;
                        driver_channel <= 3'd0;
                        frame_counter  <= {FRAME_CNT_WIDTH{1'b0}};
                        state          <= STATE_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
