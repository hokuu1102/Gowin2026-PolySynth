// One DVI TMDS data lane. c0/c1 are only meaningful while de is low.
module tmds_encoder (
    input wire clk,
    input wire rst_n,
    input wire [7:0] data,
    input wire de,
    input wire c0,
    input wire c1,
    output reg [9:0] symbol
);
    function [3:0] pop8;
        input [7:0] v;
        integer k;
        begin
            pop8 = 0;
            for (k=0; k<8; k=k+1) pop8 = pop8 + v[k];
        end
    endfunction

    reg [8:0] qm;
    reg [9:0] next_symbol;
    reg signed [5:0] disparity, next_disparity;
    reg use_xnor;
    reg [3:0] ones_d, ones_qm;
    integer i;
    always @* begin
        ones_d = pop8(data);
        use_xnor = (ones_d > 4) || ((ones_d == 4) && !data[0]);
        qm[0] = data[0];
        for (i=1; i<8; i=i+1)
            qm[i] = qm[i-1] ^ data[i] ^ use_xnor;
        qm[8] = !use_xnor;
        ones_qm = pop8(qm[7:0]);
        next_symbol = 10'b1101010100;
        next_disparity = 0;
        if (!de) begin
            case ({c1,c0})
                2'b00: next_symbol = 10'b1101010100;
                2'b01: next_symbol = 10'b0010101011;
                2'b10: next_symbol = 10'b0101010100;
                2'b11: next_symbol = 10'b1010101011;
            endcase
        end else if ((disparity == 0) || (ones_qm == 4)) begin
            next_symbol = {~qm[8], qm[8], (qm[8] ? qm[7:0] : ~qm[7:0])};
            if (qm[8]) next_disparity = disparity + (2*ones_qm - 8);
            else       next_disparity = disparity + (8 - 2*ones_qm);
        end else if (((disparity > 0) && (ones_qm > 4)) ||
                     ((disparity < 0) && (ones_qm < 4))) begin
            next_symbol = {1'b1, qm[8], ~qm[7:0]};
            next_disparity = disparity + 2*qm[8] + (8 - 2*ones_qm);
        end else begin
            next_symbol = {1'b0, qm[8], qm[7:0]};
            next_disparity = disparity - 2*(!qm[8]) + (2*ones_qm - 8);
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin symbol <= 10'b1101010100; disparity <= 0; end
        else begin symbol <= next_symbol; disparity <= next_disparity; end
    end
endmodule
