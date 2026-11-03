`timescale 1ns/1ps
`default_nettype none
// Read-only HMI transport counters. Query: 71 07 00 FF FF FF.
// Reply: HMI SSSSCCCCBBBBBBBBEEEE DD FF (without spaces), CR LF.
// S=start frames, C=physical completed frames, B=accepted bytes,
// E=illegal starts, DD=FIFO drops, FF bit0=FIFO sticky overflow.
module hmi_tx_diag(
    input wire clk_i,rst_n_i,query_i,grant_i,
    input wire ui_active_i,ui_start_i,ui_owned_i,uart_busy_i,uart_done_i,
    input wire [7:0] ui_data_i,fifo_drop_i,
    input wire fifo_overflow_i,
    output reg pending_o,active_o,tx_start_o,
    output reg [7:0] tx_data_o
);
    reg ui_active_q,tail_q;
    reg [1:0] ff_q;
    reg [15:0] starts_q,completed_q,illegal_q;
    reg [31:0] bytes_q;
    reg [95:0] snapshot_q;
    reg [4:0] pos_q;
    reg drain_q;
    wire accepted = ui_start_i && ui_owned_i && !uart_busy_i;
    function [7:0] hexchar;
        input [3:0] v;
        begin hexchar=(v<10) ? (8'd48+{4'd0,v}) : (8'd55+{4'd0,v});end
    endfunction
    always @(posedge clk_i) begin
        if(!rst_n_i)begin
            ui_active_q<=0;tail_q<=0;ff_q<=0;
            starts_q<=0;completed_q<=0;illegal_q<=0;bytes_q<=0;
            pending_o<=0;active_o<=0;tx_start_o<=0;tx_data_o<=0;
            snapshot_q<=0;pos_q<=0;drain_q<=0;
        end else begin
            ui_active_q<=ui_active_i;
            if(ui_active_i && !ui_active_q)starts_q<=starts_q+1'b1;
            if(ui_start_i && (!ui_owned_i || uart_busy_i))illegal_q<=illegal_q+1'b1;
            if(uart_done_i && tail_q)begin completed_q<=completed_q+1'b1;tail_q<=0;end
            if(accepted)begin
                bytes_q<=bytes_q+1'b1;
                if(ui_data_i==8'hff)begin
                    if(ff_q==2)begin ff_q<=0;tail_q<=1;end
                    else ff_q<=ff_q+1'b1;
                end else ff_q<=0;
            end
            tx_start_o<=0;
            if(!active_o && pending_o && grant_i)begin
                snapshot_q<={starts_q,completed_q,bytes_q,illegal_q,fifo_drop_i,7'd0,fifo_overflow_i};
                pending_o<=0;active_o<=1;drain_q<=0;pos_q<=0;
            end else if(active_o && grant_i && !uart_busy_i && !tx_start_o)begin
                if(drain_q)active_o<=0;
                else begin
                    tx_start_o<=1;
                    case(pos_q)
                        0:tx_data_o<="H";1:tx_data_o<="M";2:tx_data_o<="I";3:tx_data_o<=" ";
                        28:tx_data_o<=13;29:tx_data_o<=10;
                        default:tx_data_o<=hexchar(snapshot_q[95-4*(pos_q-4) -: 4]);
                    endcase
                    if(pos_q==29)drain_q<=1;
                    else pos_q<=pos_q+1'b1;
                end
            end
            if(query_i)pending_o<=1; // Coalesce repeated queries; never interrupt a reply.
        end
    end
endmodule
`default_nettype wire
