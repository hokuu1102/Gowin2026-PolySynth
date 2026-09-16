`timescale 1ns/1ps

// TLC5916 normal-mode serial writer.
// led_data[n] = 1 enables OUTn. Bits are sent OUT7 first, OUT0 last.
module tlc5916_driver #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer DATA_HZ = 1_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] led_data,
    input  wire       outputs_enable,

    output reg        tlc_clk,
    output reg        tlc_sdi,
    output reg        tlc_le,
    output reg        tlc_oe_n,
    output reg        busy,
    output reg        done
);

    localparam integer HALF_DIV_RAW = CLK_HZ / (DATA_HZ * 2);
    localparam integer HALF_DIV =
        (HALF_DIV_RAW < 1) ? 1 : HALF_DIV_RAW;
    localparam integer DIV_WIDTH =
        (HALF_DIV <= 1) ? 1 : $clog2(HALF_DIV);

    localparam [1:0] STATE_IDLE       = 2'd0;
    localparam [1:0] STATE_CLK_HIGH   = 2'd1;
    localparam [1:0] STATE_CLK_LOW    = 2'd2;
    localparam [1:0] STATE_LATCH_HIGH = 2'd3;

    reg [1:0] state;
    reg [7:0] data_latched;
    reg [2:0] bit_index;
    reg [DIV_WIDTH-1:0] div_counter;

    // rst_n follows the repository-wide active-low synchronous-reset rule.
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= STATE_IDLE;
            data_latched <= 8'h00;
            bit_index    <= 3'd7;
            div_counter  <= {DIV_WIDTH{1'b0}};

            tlc_clk      <= 1'b0;
            tlc_sdi      <= 1'b0;
            tlc_le       <= 1'b0;
            tlc_oe_n     <= 1'b1;
            busy         <= 1'b0;
            done         <= 1'b0;
        end
        else begin
            // Register OE so reset always leaves the LED outputs blanked.
            tlc_oe_n <= ~outputs_enable;
            done     <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    tlc_clk     <= 1'b0;
                    tlc_sdi     <= 1'b0;
                    tlc_le      <= 1'b0;
                    busy        <= 1'b0;
                    div_counter <= {DIV_WIDTH{1'b0}};

                    if (start) begin
                        data_latched <= led_data;
                        bit_index    <= 3'd7;
                        tlc_sdi      <= led_data[7];
                        busy         <= 1'b1;
                        state        <= STATE_CLK_HIGH;
                    end
                end

                STATE_CLK_HIGH: begin
                    if (div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};
                        tlc_clk     <= 1'b1;
                        state       <= STATE_CLK_LOW;
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                STATE_CLK_LOW: begin
                    if (div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};
                        tlc_clk     <= 1'b0;

                        if (bit_index == 3'd0) begin
                            tlc_le <= 1'b1;
                            state  <= STATE_LATCH_HIGH;
                        end
                        else begin
                            bit_index <= bit_index - 1'b1;
                            tlc_sdi   <= data_latched[bit_index - 1'b1];
                            state     <= STATE_CLK_HIGH;
                        end
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                STATE_LATCH_HIGH: begin
                    if (div_counter == HALF_DIV - 1) begin
                        div_counter <= {DIV_WIDTH{1'b0}};
                        tlc_le      <= 1'b0;
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        state       <= STATE_IDLE;
                    end
                    else begin
                        div_counter <= div_counter + 1'b1;
                    end
                end

                default: begin
                    state       <= STATE_IDLE;
                    tlc_clk     <= 1'b0;
                    tlc_sdi     <= 1'b0;
                    tlc_le      <= 1'b0;
                    busy        <= 1'b0;
                    div_counter <= {DIV_WIDTH{1'b0}};
                end
            endcase
        end
    end

endmodule
