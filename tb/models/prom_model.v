// prom_model.v -- behavioural model of the Gowin pROM primitive (SIMULATION ONLY).
//
// WHY: rtl/w3b/wavetable_bank.v instantiates eight Gowin pROM primitives (4 timbres
// x soft/hard).  The vendor primitive is a black box to iverilog, so without this
// model the whole regression fails to elaborate.  This model is NOT synthesised
// (Gowin uses its own primitive); it exists purely so the testbenches can run.
//
// CONTRACT (matches the instance in wavetable_bank.v):
//   READ_MODE = 0  -> registered output, one clock after CE
//   BIT_WIDTH = 16 -> 1024 x 16, only DO[15:0] carries data
//   RESET_MODE = SYNC -> synchronous reset
//
// NOTE: pure ASCII on purpose (no BOM / no GBK decoding trap).

`timescale 1ns/1ps

module pROM #(
    parameter READ_MODE = 1'b0,
    parameter BIT_WIDTH = 16,
    parameter RESET_MODE = "SYNC",
    parameter [255:0] INIT_RAM_00 = 256'h0,
    parameter [255:0] INIT_RAM_01 = 256'h0,
    parameter [255:0] INIT_RAM_02 = 256'h0,
    parameter [255:0] INIT_RAM_03 = 256'h0,
    parameter [255:0] INIT_RAM_04 = 256'h0,
    parameter [255:0] INIT_RAM_05 = 256'h0,
    parameter [255:0] INIT_RAM_06 = 256'h0,
    parameter [255:0] INIT_RAM_07 = 256'h0,
    parameter [255:0] INIT_RAM_08 = 256'h0,
    parameter [255:0] INIT_RAM_09 = 256'h0,
    parameter [255:0] INIT_RAM_0A = 256'h0,
    parameter [255:0] INIT_RAM_0B = 256'h0,
    parameter [255:0] INIT_RAM_0C = 256'h0,
    parameter [255:0] INIT_RAM_0D = 256'h0,
    parameter [255:0] INIT_RAM_0E = 256'h0,
    parameter [255:0] INIT_RAM_0F = 256'h0,
    parameter [255:0] INIT_RAM_10 = 256'h0,
    parameter [255:0] INIT_RAM_11 = 256'h0,
    parameter [255:0] INIT_RAM_12 = 256'h0,
    parameter [255:0] INIT_RAM_13 = 256'h0,
    parameter [255:0] INIT_RAM_14 = 256'h0,
    parameter [255:0] INIT_RAM_15 = 256'h0,
    parameter [255:0] INIT_RAM_16 = 256'h0,
    parameter [255:0] INIT_RAM_17 = 256'h0,
    parameter [255:0] INIT_RAM_18 = 256'h0,
    parameter [255:0] INIT_RAM_19 = 256'h0,
    parameter [255:0] INIT_RAM_1A = 256'h0,
    parameter [255:0] INIT_RAM_1B = 256'h0,
    parameter [255:0] INIT_RAM_1C = 256'h0,
    parameter [255:0] INIT_RAM_1D = 256'h0,
    parameter [255:0] INIT_RAM_1E = 256'h0,
    parameter [255:0] INIT_RAM_1F = 256'h0,
    parameter [255:0] INIT_RAM_20 = 256'h0,
    parameter [255:0] INIT_RAM_21 = 256'h0,
    parameter [255:0] INIT_RAM_22 = 256'h0,
    parameter [255:0] INIT_RAM_23 = 256'h0,
    parameter [255:0] INIT_RAM_24 = 256'h0,
    parameter [255:0] INIT_RAM_25 = 256'h0,
    parameter [255:0] INIT_RAM_26 = 256'h0,
    parameter [255:0] INIT_RAM_27 = 256'h0,
    parameter [255:0] INIT_RAM_28 = 256'h0,
    parameter [255:0] INIT_RAM_29 = 256'h0,
    parameter [255:0] INIT_RAM_2A = 256'h0,
    parameter [255:0] INIT_RAM_2B = 256'h0,
    parameter [255:0] INIT_RAM_2C = 256'h0,
    parameter [255:0] INIT_RAM_2D = 256'h0,
    parameter [255:0] INIT_RAM_2E = 256'h0,
    parameter [255:0] INIT_RAM_2F = 256'h0,
    parameter [255:0] INIT_RAM_30 = 256'h0,
    parameter [255:0] INIT_RAM_31 = 256'h0,
    parameter [255:0] INIT_RAM_32 = 256'h0,
    parameter [255:0] INIT_RAM_33 = 256'h0,
    parameter [255:0] INIT_RAM_34 = 256'h0,
    parameter [255:0] INIT_RAM_35 = 256'h0,
    parameter [255:0] INIT_RAM_36 = 256'h0,
    parameter [255:0] INIT_RAM_37 = 256'h0,
    parameter [255:0] INIT_RAM_38 = 256'h0,
    parameter [255:0] INIT_RAM_39 = 256'h0,
    parameter [255:0] INIT_RAM_3A = 256'h0,
    parameter [255:0] INIT_RAM_3B = 256'h0,
    parameter [255:0] INIT_RAM_3C = 256'h0,
    parameter [255:0] INIT_RAM_3D = 256'h0,
    parameter [255:0] INIT_RAM_3E = 256'h0,
    parameter [255:0] INIT_RAM_3F = 256'h0
) (
    output reg  [31:0] DO,
    input  wire        CLK,
    input  wire        OCE,
    input  wire        CE,
    input  wire        RESET,
    input  wire [13:0] AD
);
    localparam integer WORDS = 1024;
    reg [15:0] mem [0:WORDS-1];
    integer i;

    //  INIT_RAM_xx holds 16 big-endian 16-bit words; _00 covers addresses 0..15.
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'h0000;
        for (i = 0; i < 16; i = i + 1) mem[0 + i] = INIT_RAM_00[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[16 + i] = INIT_RAM_01[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[32 + i] = INIT_RAM_02[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[48 + i] = INIT_RAM_03[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[64 + i] = INIT_RAM_04[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[80 + i] = INIT_RAM_05[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[96 + i] = INIT_RAM_06[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[112 + i] = INIT_RAM_07[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[128 + i] = INIT_RAM_08[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[144 + i] = INIT_RAM_09[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[160 + i] = INIT_RAM_0A[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[176 + i] = INIT_RAM_0B[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[192 + i] = INIT_RAM_0C[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[208 + i] = INIT_RAM_0D[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[224 + i] = INIT_RAM_0E[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[240 + i] = INIT_RAM_0F[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[256 + i] = INIT_RAM_10[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[272 + i] = INIT_RAM_11[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[288 + i] = INIT_RAM_12[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[304 + i] = INIT_RAM_13[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[320 + i] = INIT_RAM_14[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[336 + i] = INIT_RAM_15[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[352 + i] = INIT_RAM_16[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[368 + i] = INIT_RAM_17[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[384 + i] = INIT_RAM_18[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[400 + i] = INIT_RAM_19[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[416 + i] = INIT_RAM_1A[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[432 + i] = INIT_RAM_1B[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[448 + i] = INIT_RAM_1C[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[464 + i] = INIT_RAM_1D[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[480 + i] = INIT_RAM_1E[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[496 + i] = INIT_RAM_1F[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[512 + i] = INIT_RAM_20[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[528 + i] = INIT_RAM_21[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[544 + i] = INIT_RAM_22[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[560 + i] = INIT_RAM_23[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[576 + i] = INIT_RAM_24[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[592 + i] = INIT_RAM_25[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[608 + i] = INIT_RAM_26[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[624 + i] = INIT_RAM_27[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[640 + i] = INIT_RAM_28[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[656 + i] = INIT_RAM_29[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[672 + i] = INIT_RAM_2A[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[688 + i] = INIT_RAM_2B[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[704 + i] = INIT_RAM_2C[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[720 + i] = INIT_RAM_2D[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[736 + i] = INIT_RAM_2E[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[752 + i] = INIT_RAM_2F[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[768 + i] = INIT_RAM_30[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[784 + i] = INIT_RAM_31[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[800 + i] = INIT_RAM_32[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[816 + i] = INIT_RAM_33[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[832 + i] = INIT_RAM_34[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[848 + i] = INIT_RAM_35[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[864 + i] = INIT_RAM_36[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[880 + i] = INIT_RAM_37[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[896 + i] = INIT_RAM_38[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[912 + i] = INIT_RAM_39[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[928 + i] = INIT_RAM_3A[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[944 + i] = INIT_RAM_3B[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[960 + i] = INIT_RAM_3C[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[976 + i] = INIT_RAM_3D[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[992 + i] = INIT_RAM_3E[i*16 +: 16];
        for (i = 0; i < 16; i = i + 1) mem[1008 + i] = INIT_RAM_3F[i*16 +: 16];
    end

    always @(posedge CLK) begin
        if (RESET) begin
            DO <= 32'h0;
        end else if (CE && OCE) begin
            DO[15:0]  <= mem[AD[9:0]];   // BIT_WIDTH=16 -> low half only
            DO[31:16] <= 16'h0;
        end
    end
endmodule
