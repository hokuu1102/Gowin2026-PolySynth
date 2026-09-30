module color_bars #(
    parameter integer H_ACTIVE = 640,
    parameter integer X_BITS = $clog2(H_ACTIVE)
) (
    input wire [X_BITS-1:0] x,
    input wire de,
    output reg [7:0] r,
    output reg [7:0] g,
    output reg [7:0] b
);
    // Each bar spans one eighth of the active horizontal interval.
    always @* begin
        {r,g,b} = 24'h000000;
        if (de) begin
            if      (x < H_ACTIVE/8)   {r,g,b} = 24'hffffff;
            else if (x < H_ACTIVE*2/8) {r,g,b} = 24'hffff00;
            else if (x < H_ACTIVE*3/8) {r,g,b} = 24'h00ffff;
            else if (x < H_ACTIVE*4/8) {r,g,b} = 24'h00ff00;
            else if (x < H_ACTIVE*5/8) {r,g,b} = 24'hff00ff;
            else if (x < H_ACTIVE*6/8) {r,g,b} = 24'hff0000;
            else if (x < H_ACTIVE*7/8) {r,g,b} = 24'h0000ff;
        end
    end
endmodule
