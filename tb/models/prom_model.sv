`timescale 1ns/1ps

// Simulation-only model for the Gowin pROM primitive used by the generated
// four-timbre bank.  The project file never includes tb/models, so this cannot
// replace or shadow the silicon primitive during synthesis/PnR.
module pROM #(
    parameter READ_MODE = 1'b0,
    parameter integer BIT_WIDTH = 16,
    parameter RESET_MODE = "SYNC",
    parameter [255:0] INIT_RAM_00 = 256'd0,
    parameter [255:0] INIT_RAM_01 = 256'd0,
    parameter [255:0] INIT_RAM_02 = 256'd0,
    parameter [255:0] INIT_RAM_03 = 256'd0,
    parameter [255:0] INIT_RAM_04 = 256'd0,
    parameter [255:0] INIT_RAM_05 = 256'd0,
    parameter [255:0] INIT_RAM_06 = 256'd0,
    parameter [255:0] INIT_RAM_07 = 256'd0,
    parameter [255:0] INIT_RAM_08 = 256'd0,
    parameter [255:0] INIT_RAM_09 = 256'd0,
    parameter [255:0] INIT_RAM_0A = 256'd0,
    parameter [255:0] INIT_RAM_0B = 256'd0,
    parameter [255:0] INIT_RAM_0C = 256'd0,
    parameter [255:0] INIT_RAM_0D = 256'd0,
    parameter [255:0] INIT_RAM_0E = 256'd0,
    parameter [255:0] INIT_RAM_0F = 256'd0,
    parameter [255:0] INIT_RAM_10 = 256'd0,
    parameter [255:0] INIT_RAM_11 = 256'd0,
    parameter [255:0] INIT_RAM_12 = 256'd0,
    parameter [255:0] INIT_RAM_13 = 256'd0,
    parameter [255:0] INIT_RAM_14 = 256'd0,
    parameter [255:0] INIT_RAM_15 = 256'd0,
    parameter [255:0] INIT_RAM_16 = 256'd0,
    parameter [255:0] INIT_RAM_17 = 256'd0,
    parameter [255:0] INIT_RAM_18 = 256'd0,
    parameter [255:0] INIT_RAM_19 = 256'd0,
    parameter [255:0] INIT_RAM_1A = 256'd0,
    parameter [255:0] INIT_RAM_1B = 256'd0,
    parameter [255:0] INIT_RAM_1C = 256'd0,
    parameter [255:0] INIT_RAM_1D = 256'd0,
    parameter [255:0] INIT_RAM_1E = 256'd0,
    parameter [255:0] INIT_RAM_1F = 256'd0,
    parameter [255:0] INIT_RAM_20 = 256'd0,
    parameter [255:0] INIT_RAM_21 = 256'd0,
    parameter [255:0] INIT_RAM_22 = 256'd0,
    parameter [255:0] INIT_RAM_23 = 256'd0,
    parameter [255:0] INIT_RAM_24 = 256'd0,
    parameter [255:0] INIT_RAM_25 = 256'd0,
    parameter [255:0] INIT_RAM_26 = 256'd0,
    parameter [255:0] INIT_RAM_27 = 256'd0,
    parameter [255:0] INIT_RAM_28 = 256'd0,
    parameter [255:0] INIT_RAM_29 = 256'd0,
    parameter [255:0] INIT_RAM_2A = 256'd0,
    parameter [255:0] INIT_RAM_2B = 256'd0,
    parameter [255:0] INIT_RAM_2C = 256'd0,
    parameter [255:0] INIT_RAM_2D = 256'd0,
    parameter [255:0] INIT_RAM_2E = 256'd0,
    parameter [255:0] INIT_RAM_2F = 256'd0,
    parameter [255:0] INIT_RAM_30 = 256'd0,
    parameter [255:0] INIT_RAM_31 = 256'd0,
    parameter [255:0] INIT_RAM_32 = 256'd0,
    parameter [255:0] INIT_RAM_33 = 256'd0,
    parameter [255:0] INIT_RAM_34 = 256'd0,
    parameter [255:0] INIT_RAM_35 = 256'd0,
    parameter [255:0] INIT_RAM_36 = 256'd0,
    parameter [255:0] INIT_RAM_37 = 256'd0,
    parameter [255:0] INIT_RAM_38 = 256'd0,
    parameter [255:0] INIT_RAM_39 = 256'd0,
    parameter [255:0] INIT_RAM_3A = 256'd0,
    parameter [255:0] INIT_RAM_3B = 256'd0,
    parameter [255:0] INIT_RAM_3C = 256'd0,
    parameter [255:0] INIT_RAM_3D = 256'd0,
    parameter [255:0] INIT_RAM_3E = 256'd0,
    parameter [255:0] INIT_RAM_3F = 256'd0
) (
    output wire [31:0] DO,
    input wire CLK,
    input wire OCE,
    input wire CE,
    input wire RESET,
    input wire [13:0] AD
);
    reg [15:0] memory [0:1023];
    reg [31:0] bp_reg;
    reg [31:0] pl_reg;
    integer init_index;

    task load_block;
        input integer base;
        input [255:0] bits;
        integer word_index;
        begin
            for (word_index = 0; word_index < 16; word_index = word_index + 1)
                memory[base + word_index] = bits[word_index*16 +: 16];
        end
    endtask

    initial begin
        bp_reg = 32'd0;
        pl_reg = 32'd0;
        for (init_index = 0; init_index < 1024; init_index = init_index + 1)
            memory[init_index] = 16'd0;
        load_block(0, INIT_RAM_00);
        load_block(16, INIT_RAM_01);
        load_block(32, INIT_RAM_02);
        load_block(48, INIT_RAM_03);
        load_block(64, INIT_RAM_04);
        load_block(80, INIT_RAM_05);
        load_block(96, INIT_RAM_06);
        load_block(112, INIT_RAM_07);
        load_block(128, INIT_RAM_08);
        load_block(144, INIT_RAM_09);
        load_block(160, INIT_RAM_0A);
        load_block(176, INIT_RAM_0B);
        load_block(192, INIT_RAM_0C);
        load_block(208, INIT_RAM_0D);
        load_block(224, INIT_RAM_0E);
        load_block(240, INIT_RAM_0F);
        load_block(256, INIT_RAM_10);
        load_block(272, INIT_RAM_11);
        load_block(288, INIT_RAM_12);
        load_block(304, INIT_RAM_13);
        load_block(320, INIT_RAM_14);
        load_block(336, INIT_RAM_15);
        load_block(352, INIT_RAM_16);
        load_block(368, INIT_RAM_17);
        load_block(384, INIT_RAM_18);
        load_block(400, INIT_RAM_19);
        load_block(416, INIT_RAM_1A);
        load_block(432, INIT_RAM_1B);
        load_block(448, INIT_RAM_1C);
        load_block(464, INIT_RAM_1D);
        load_block(480, INIT_RAM_1E);
        load_block(496, INIT_RAM_1F);
        load_block(512, INIT_RAM_20);
        load_block(528, INIT_RAM_21);
        load_block(544, INIT_RAM_22);
        load_block(560, INIT_RAM_23);
        load_block(576, INIT_RAM_24);
        load_block(592, INIT_RAM_25);
        load_block(608, INIT_RAM_26);
        load_block(624, INIT_RAM_27);
        load_block(640, INIT_RAM_28);
        load_block(656, INIT_RAM_29);
        load_block(672, INIT_RAM_2A);
        load_block(688, INIT_RAM_2B);
        load_block(704, INIT_RAM_2C);
        load_block(720, INIT_RAM_2D);
        load_block(736, INIT_RAM_2E);
        load_block(752, INIT_RAM_2F);
        load_block(768, INIT_RAM_30);
        load_block(784, INIT_RAM_31);
        load_block(800, INIT_RAM_32);
        load_block(816, INIT_RAM_33);
        load_block(832, INIT_RAM_34);
        load_block(848, INIT_RAM_35);
        load_block(864, INIT_RAM_36);
        load_block(880, INIT_RAM_37);
        load_block(896, INIT_RAM_38);
        load_block(912, INIT_RAM_39);
        load_block(928, INIT_RAM_3A);
        load_block(944, INIT_RAM_3B);
        load_block(960, INIT_RAM_3C);
        load_block(976, INIT_RAM_3D);
        load_block(992, INIT_RAM_3E);
        load_block(1008, INIT_RAM_3F);
    end

    // Match Gowin's official gw5a primitive model:
    //   READ_MODE=0 (bypass)   -> the BRAM read register, one clock latency.
    //   READ_MODE=1 (pipeline) -> one extra output register, two clocks.
    // The old test double ignored READ_MODE and always modeled one clock,
    // which hid a real TDM lane/data misalignment from simulation.
    assign DO = (READ_MODE == 1'b0) ? bp_reg : pl_reg;

    // BIT_WIDTH=16 uses AD[13:4] as the word address in Gowin's primitive.
    always @(posedge CLK) begin
        if (RESET) begin
            bp_reg <= 32'd0;
            pl_reg <= 32'd0;
        end else begin
            if (OCE)
                pl_reg <= bp_reg;
            if (CE)
                bp_reg <= {16'd0, memory[AD[13:4]]};
        end
    end
endmodule

