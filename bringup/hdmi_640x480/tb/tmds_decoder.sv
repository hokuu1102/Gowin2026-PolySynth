// Independent testbench-only inverse of one DVI TMDS symbol.
module tmds_decoder (
    input wire [9:0] symbol,
    output reg de,
    output reg c0,
    output reg c1,
    output reg [7:0] data,
    output reg valid
);
    reg [7:0] qm;
    integer i;
    always @* begin
        de = 0; c0 = 0; c1 = 0; data = 0; valid = 1;
        case (symbol)
            10'b1101010100: begin c0=0; c1=0; end
            10'b0010101011: begin c0=1; c1=0; end
            10'b0101010100: begin c0=0; c1=1; end
            10'b1010101011: begin c0=1; c1=1; end
            default: begin
                de = 1;
                qm = symbol[9] ? ~symbol[7:0] : symbol[7:0];
                data[0] = qm[0];
                for (i=1; i<8; i=i+1)
                    data[i] = qm[i] ^ qm[i-1] ^ !symbol[8];
            end
        endcase
    end
endmodule
