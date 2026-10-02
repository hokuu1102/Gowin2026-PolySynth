// test_mode_ctrl.v
// Deterministic N=4/8/16/32 test-tone configuration source.
// n_code_i mapping is 00/01/10/11 -> TEST_N0/1/2/3. In Test Mode only
// oscillator 0 of each selected voice is enabled; flat-bus ordering is the
// same voice-major lane order used by oscillator_bank.
//
// The frequency plan is aligned to bins of an 8192-point FFT at 48_828.125 Hz:
//   bin(v) = 80 + 117*v, v=0..31  =>  476.84 Hz .. 22_095.03 Hz.
// Because gcd(80,117)=1, no two selected fundamentals are low-order integer
// harmonics of each other.  Exact bin alignment also makes the four acceptance
// spectra stable and easy to count with tools/peak_count.py.
`timescale 1ns/1ps

module test_mode_ctrl #(
    parameter integer POLY_TARGET   = 32,
    parameter integer OSC_PER_VOICE = 2,
    parameter integer PHASE_W       = 32,
    parameter integer VEL_W         = 8,
    parameter integer TEST_N0       = 4,
    parameter integer TEST_N1       = 8,
    parameter integer TEST_N2       = 16,
    parameter integer TEST_N3       = 32
) (
    input  wire                                         clk_i,
    input  wire                                         rst_n_i,
    input  wire                                         sample_tick_i,
    input  wire                                         enable_i,
    input  wire [1:0]                                   n_code_i,
    output wire [POLY_TARGET-1:0]                       test_voice_gate_o,
    output wire [POLY_TARGET*VEL_W-1:0]                 test_velocity_o,
    output wire [POLY_TARGET*OSC_PER_VOICE-1:0]         test_lane_active_o,
    output wire [POLY_TARGET*OSC_PER_VOICE*PHASE_W-1:0] test_phase_inc_o,
    output wire [5:0]                                   active_n_o
);

    // One FFT bin is 2^32 / 8192 = 2^19 phase-increment units.
    localparam [PHASE_W-1:0] PHASE_INC_BASE = 32'h0280_0000; // bin 80
    localparam [PHASE_W-1:0] PHASE_INC_STEP = 32'h03A8_0000; // 117 bins

    // Clamp parameterised modes to the physically available voice count so
    // active_n_o can never disagree with the gate population.
    wire [5:0] test_n0_c = (TEST_N0 > POLY_TARGET) ? POLY_TARGET : TEST_N0;
    wire [5:0] test_n1_c = (TEST_N1 > POLY_TARGET) ? POLY_TARGET : TEST_N1;
    wire [5:0] test_n2_c = (TEST_N2 > POLY_TARGET) ? POLY_TARGET : TEST_N2;
    wire [5:0] test_n3_c = (TEST_N3 > POLY_TARGET) ? POLY_TARGET : TEST_N3;

    reg [5:0] selected_n_r;
    always @(*) begin
        case (n_code_i)
            2'b00: selected_n_r = test_n0_c;
            2'b01: selected_n_r = test_n1_c;
            2'b10: selected_n_r = test_n2_c;
            default: selected_n_r = test_n3_c;
        endcase
    end

    // Combinational configuration is intentional: disabling Test Mode mutes
    // every test output immediately, and a mode switch settles within one
    // sample period. clk_i/sample_tick_i remain on the frozen interface for
    // integration symmetry with the rendering chain.
    wire mode_enabled = rst_n_i & enable_i;
    assign active_n_o = mode_enabled ? selected_n_r : 6'd0;

    genvar v;
    genvar o;
    generate
        for (v = 0; v < POLY_TARGET; v = v + 1) begin : gen_test_voice
            localparam [PHASE_W-1:0] VOICE_INC = PHASE_INC_BASE + v*PHASE_INC_STEP;
            // Keep a local decode for each voice instead of merging equal
            // modes into one control net shared by hundreds of ADSR loads.
            // This is combinational: mode switching retains the same cycle.
            (* syn_keep = 1 *) wire selected = mode_enabled && (v < selected_n_r);

            assign test_voice_gate_o[v] = selected;
            assign test_velocity_o[v*VEL_W +: VEL_W] =
                selected ? {VEL_W{1'b1}} : {VEL_W{1'b0}};

            for (o = 0; o < OSC_PER_VOICE; o = o + 1) begin : gen_test_lane
                localparam integer LANE = v*OSC_PER_VOICE + o;
                assign test_lane_active_o[LANE] = selected && (o == 0);
                assign test_phase_inc_o[LANE*PHASE_W +: PHASE_W] =
                    (selected && (o == 0)) ? VOICE_INC : {PHASE_W{1'b0}};
            end
        end
    endgenerate

endmodule
