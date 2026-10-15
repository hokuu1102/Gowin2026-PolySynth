`timescale 1ns/1ps
`default_nettype none
// Passive, single-clock radix-2 DIT FFT. No audio ready/backpressure port.
// Real signed-16 inputs; complex signed-18 output units = 4*DFT(window*x)/N.
// Per-stage /2 scaling; optional periodic Hann window, unity when WINDOW_EN=0.
// LOG2_N 6..11. Output bins 0..N/2 inclusive, ascending, one frame ID per block.
// Ping-pong input ownership prevents overwrite even with adversarial valid.
// Nominal valid spacing=1024 clocks: processing finishes before the next block.
module fft_spectrum_core #(
 parameter integer LOG2_N=11,
 parameter integer WINDOW_EN=1
)(
 input wire clk_i,rst_n_i,enable_i,sample_valid_i,
 input wire signed [15:0] sample_i,
 output reg bin_valid_o,
 output reg [LOG2_N-1:0] bin_index_o,
 output reg signed [17:0] bin_real_o,bin_imag_o,
 output reg frame_done_o,
 output reg [15:0] frame_id_o,
 output wire busy_o,
 output reg overflow_o,
 output reg [31:0] dropped_samples_o
);
 localparam integer N=1<<LOG2_N;
 localparam [4:0] IDLE=0,LOAD_REQ=1,LOAD_MULT=2,LOAD_STORE=3,
  SETUP=4,A_WAIT=5,A_LATCH=6,B_WAIT=7,B_LATCH=8,MULT=9,
  PRODUCT_SUM=10,ROTATE=11,BUTTERFLY=12,WRITE_A=13,WRITE_B=14,
  OUT_REQ=15,OUT_LATCH=16;
 reg [4:0] state;
 reg signed [15:0] capture_mem[0:2*N-1];
 reg [35:0] work_mem[0:N-1];
 reg wr_bank,read_bank,ready0,ready1;
 reg [LOG2_N-1:0] wr_index,load_index;
 reg [15:0] sequence_next,sequence0,sequence1;
 reg signed [15:0] capture_q;
 reg [35:0] work_q;
 reg [LOG2_N-1:0] read_addr,addr_a,addr_b;
 reg [LOG2_N-1:0] half_span,offset,group_base,out_index;
 reg [3:0] stage,tw_shift;
 reg [9:0] tw_addr;
 wire [31:0] twiddle;
 wire [15:0] window_q;
 wire [10:0] window_addr=load_index << (11-LOG2_N);
 wire signed [15:0] tw_real=twiddle[31:16],tw_imag=twiddle[15:0];
 reg signed [17:0] ar,ai,br,bi,plus_r,plus_i,minus_r,minus_i;
 reg signed [31:0] window_product;
 reg signed [33:0] p0,p1,p2,p3;
 reg signed [34:0] product_r,product_i;
 reg signed [19:0] rotated_r,rotated_i;
 wire [LOG2_N-1:0] group_step=half_span<<1;
 wire [LOG2_N-1:0] last_group={LOG2_N{1'b0}}-group_step;
 wire [10:0] tw_shifted={{(11-LOG2_N){1'b0}},offset}<<tw_shift;
 wire capture_available=wr_bank ? ~ready1 : ~ready0;
 wire release_capture=(state==LOAD_STORE)&&(load_index==N-1);
 wire signed [20:0] apr=($signed(ar)+$signed(rotated_r))>>>1;
 wire signed [20:0] api=($signed(ai)+$signed(rotated_i))>>>1;
 wire signed [20:0] amr=($signed(ar)-$signed(rotated_r))>>>1;
 wire signed [20:0] ami=($signed(ai)-$signed(rotated_i))>>>1;
 wire clipped=(apr>131071)||(apr< -131072)||(api>131071)||(api< -131072)||
              (amr>131071)||(amr< -131072)||(ami>131071)||(ami< -131072);
 function [17:0] saturate;
  input signed [20:0] value;
  begin
   if(value>131071)saturate=18'h1ffff;
   else if(value< -131072)saturate=18'h20000;
   else saturate=value[17:0];
  end
 endfunction
 function [LOG2_N-1:0] reverse_bits;
  input [LOG2_N-1:0] value;
  integer k;
  begin for(k=0;k<LOG2_N;k=k+1)reverse_bits[k]=value[LOG2_N-1-k];end
 endfunction
 wire work_we=(state==LOAD_STORE)||(state==WRITE_A)||(state==WRITE_B);
 wire [LOG2_N-1:0] work_waddr=(state==LOAD_STORE)?reverse_bits(load_index):
                              (state==WRITE_A)?addr_a:addr_b;
 wire signed [31:0] window_scaled=window_product>>>13;
 wire [17:0] load_value=WINDOW_EN ? window_scaled[17:0] : {capture_q,2'b00};
 wire [35:0] work_wdata=(state==LOAD_STORE)?{load_value,18'd0}:
                          (state==WRITE_A)?{plus_r,plus_i}:{minus_r,minus_i};
 assign busy_o=(state!=IDLE);
 fft_coeff_rom coeff(.clk_i(clk_i),.tw_addr_i(tw_addr),
  .window_addr_i(window_addr),.twiddle_o(twiddle),.window_o(window_q));
 // Clean synchronous memory ports; no bulk memory resets.
 always @(posedge clk_i) begin
  if(rst_n_i && enable_i && sample_valid_i && capture_available)
   capture_mem[{wr_bank,wr_index}]<=sample_i;
  capture_q<=capture_mem[{read_bank,load_index}];
  if(rst_n_i && enable_i && work_we)work_mem[work_waddr]<=work_wdata;
  work_q<=work_mem[read_addr];
 end
 always @(posedge clk_i) begin
  if(!rst_n_i || !enable_i) begin
   wr_bank<=0;wr_index<=0;ready0<=0;ready1<=0;
   sequence_next<=0;sequence0<=0;sequence1<=0;dropped_samples_o<=0;
  end else begin
   if(release_capture)begin if(read_bank)ready1<=0;else ready0<=0;end
   if(sample_valid_i)begin
    if(capture_available)begin
     if(wr_index==N-1)begin
      if(wr_bank)begin ready1<=1;sequence1<=sequence_next;end
      else begin ready0<=1;sequence0<=sequence_next;end
      sequence_next<=sequence_next+16'd1;wr_bank<=~wr_bank;wr_index<=0;
     end else wr_index<=wr_index+1'b1;
    end else if(dropped_samples_o!=32'hffffffff)
     dropped_samples_o<=dropped_samples_o+32'd1;
   end
  end
 end
 always @(posedge clk_i) begin
  if(!rst_n_i || !enable_i)begin
   state<=IDLE;read_bank<=0;load_index<=0;read_addr<=0;addr_a<=0;addr_b<=0;
   half_span<=1;offset<=0;group_base<=0;out_index<=0;stage<=0;tw_shift<=10;tw_addr<=0;
   ar<=0;ai<=0;br<=0;bi<=0;p0<=0;p1<=0;p2<=0;p3<=0;product_r<=0;product_i<=0;
   rotated_r<=0;rotated_i<=0;plus_r<=0;plus_i<=0;minus_r<=0;minus_i<=0;
   window_product<=0;bin_valid_o<=0;frame_done_o<=0;frame_id_o<=0;
   bin_index_o<=0;bin_real_o<=0;bin_imag_o<=0;overflow_o<=0;
  end else begin
   bin_valid_o<=0;frame_done_o<=0;
   case(state)
    IDLE:if(ready0 || ready1)begin
     // wr_bank points to the next capture bank: the opposite is the newer
     // completed bank. When both are queued, wr_bank is the older bank.
     if(ready0 && ready1)begin read_bank<=wr_bank;frame_id_o<=wr_bank?sequence1:sequence0;end
     else begin read_bank<=ready1;frame_id_o<=ready1?sequence1:sequence0;end
     load_index<=0;state<=LOAD_REQ;
    end
    LOAD_REQ:state<=LOAD_MULT;
    LOAD_MULT:begin window_product<=$signed(capture_q)*$signed(window_q);state<=LOAD_STORE;end
    LOAD_STORE:begin
     if(load_index==N-1)begin
      half_span<=1;offset<=0;group_base<=0;stage<=0;tw_shift<=10;state<=SETUP;
     end else begin load_index<=load_index+1'b1;state<=LOAD_REQ;end
    end
    SETUP:begin
     addr_a<=group_base|offset;addr_b<=group_base|offset|half_span;
     read_addr<=group_base|offset;tw_addr<=tw_shifted[9:0];state<=A_WAIT;
    end
    A_WAIT:state<=A_LATCH;
    A_LATCH:begin ar<=$signed(work_q[35:18]);ai<=$signed(work_q[17:0]);read_addr<=addr_b;state<=B_WAIT;end
    B_WAIT:state<=B_LATCH;
    B_LATCH:begin br<=$signed(work_q[35:18]);bi<=$signed(work_q[17:0]);state<=MULT;end
    MULT:begin p0<=br*tw_real;p1<=bi*tw_imag;p2<=br*tw_imag;p3<=bi*tw_real;state<=PRODUCT_SUM;end
    PRODUCT_SUM:begin
     product_r<=$signed({p0[33],p0})-$signed({p1[33],p1});
     product_i<=$signed({p2[33],p2})+$signed({p3[33],p3});state<=ROTATE;
    end
    ROTATE:begin rotated_r<=product_r>>>15;rotated_i<=product_i>>>15;state<=BUTTERFLY;end
    BUTTERFLY:begin
     plus_r<=saturate(apr);plus_i<=saturate(api);minus_r<=saturate(amr);minus_i<=saturate(ami);
     if(clipped)overflow_o<=1;state<=WRITE_A;
    end
    WRITE_A:state<=WRITE_B;
    WRITE_B:begin
     if(offset==half_span-1'b1)begin
      offset<=0;
      if(group_base==last_group)begin
       group_base<=0;
       if(stage==LOG2_N-1)begin out_index<=0;read_addr<=0;state<=OUT_REQ;end
       else begin stage<=stage+1'b1;tw_shift<=tw_shift-1'b1;half_span<=half_span<<1;state<=SETUP;end
      end else begin group_base<=group_base+(half_span<<1);state<=SETUP;end
     end else begin offset<=offset+1'b1;state<=SETUP;end
    end
    OUT_REQ:state<=OUT_LATCH;
    OUT_LATCH:begin
     bin_valid_o<=1;bin_index_o<=out_index;bin_real_o<=$signed(work_q[35:18]);bin_imag_o<=$signed(work_q[17:0]);
     if(out_index==N/2)begin frame_done_o<=1;state<=IDLE;end
     else begin out_index<=out_index+1'b1;read_addr<=out_index+1'b1;state<=OUT_REQ;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
