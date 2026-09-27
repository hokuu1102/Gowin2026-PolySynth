`timescale 1ns/1ps
// T15 semantic controller.  It deliberately owns the distinction between
// selection events and playing events so downstream voice allocation receives
// one unambiguous note_on/note_off/pluck stream.
`default_nettype none

module play_mode_ctrl #(
    parameter integer AXIS_W  = 4,
    parameter integer DEPTH_W = 12
) (
    input  wire                   clk_i,
    input  wire                   rst_n_i,
    input  wire                   fretboard_mode_i, // 0=keyboard, 1=fretboard

    input  wire                   axis_valid_i,
    input  wire [AXIS_W-1:0]      axis_i,
    input  wire [1:0]             axis_kind_i,      // 0=on, 1=off
    input  wire [DEPTH_W-1:0]     axis_depth_i,
    input  wire                   pluck_valid_i,
    input  wire                   pluck_up_i,       // direction retained at capture seam

    output reg                    evt_valid_o,
    output reg  [AXIS_W-1:0]      evt_axis_o,
    output reg  [1:0]             evt_kind_o,       // 0=on, 1=off, 2=pluck
    output reg  [DEPTH_W-1:0]     evt_depth_o
);
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_PLUCK = 2'd2;

    reg                  selected_valid;
    reg [AXIS_W-1:0]     selected_axis;
    reg [DEPTH_W-1:0]    selected_depth;
    reg                  gate_valid;
    reg [AXIS_W-1:0]     gate_axis;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            selected_valid <= 1'b0;
            selected_axis  <= {AXIS_W{1'b0}};
            selected_depth <= {DEPTH_W{1'b0}};
            gate_valid     <= 1'b0;
            gate_axis      <= {AXIS_W{1'b0}};
            evt_valid_o    <= 1'b0;
            evt_axis_o     <= {AXIS_W{1'b0}};
            evt_kind_o     <= KIND_ON;
            evt_depth_o    <= {DEPTH_W{1'b0}};
        end else begin
            evt_valid_o <= 1'b0;

            if (!fretboard_mode_i) begin
                // Keyboard: threshold crossing and release are directly musical.
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                end
            end else if (pluck_valid_i && selected_valid) begin
                // Fretboard: a pluck is the musical trigger. Direction has
                // already been resolved by async_pluck_capture (UP priority).
                evt_valid_o <= 1'b1;
                evt_axis_o  <= selected_axis;
                evt_kind_o  <= KIND_PLUCK;
                evt_depth_o <= selected_depth;
                gate_valid  <= 1'b1;
                gate_axis   <= selected_axis;
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;
                    selected_depth <= axis_depth_i;
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    if (gate_valid && (axis_i == gate_axis)) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= axis_i;
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
