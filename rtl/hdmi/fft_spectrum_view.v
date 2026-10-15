`timescale 1ns/1ps
`default_nettype none
// Passive FFT -> frame-owned spectrum -> blanking-time pixel snapshot.
// Default colored fill: 128 grouped maxima, 3 pixels/bar + 1 black gap.
// Normal N=0 shows Fs/4 (x2); Test Mode keeps the full frequency band.
// COLOR_BARS_EN=0 restores outline. PLAY_ZOOM=4 restores its x4 viewport.
// OUTLINE_EN=0 preserves the legacy filled bars and quarter-band repeat.
// Producer never waits for video. An occupied publication drops a DISPLAY
// frame only; the locked publication bank is never overwritten before ack.
module fft_spectrum_view #(parameter integer LOG2_N=11,
 parameter integer OUTLINE_EN=1,parameter integer PLAY_ZOOM=2,
 parameter integer COLOR_BARS_EN=1)(
 input wire sample_clk_i,sample_rst_n_i,
 input wire signed [23:0] sample_i,
 input wire sample_valid_i,
 input wire [5:0] test_n_i,
 input wire pixel_clk_i,pixel_rst_n_i,
 input wire [9:0] x_i,y_i,
 input wire de_i,hs_i,vs_i,
 output reg [7:0] r_o,g_o,b_o,
 output reg de_o,hs_o,vs_o,
 output reg frame_ready_o,
 output reg [15:0] frame_id_o,
 output reg [5:0] test_n_o,
 output wire [31:0] dropped_samples_o,
 output reg [31:0] dropped_frames_o,
 output wire overflow_o
);
 localparam integer N=1<<LOG2_N,BARS=N/4;
 localparam integer NORMAL_SHIFT=(PLAY_ZOOM==4)?(12-LOG2_N):(11-LOG2_N);
 localparam integer NORMAL_FRAC_SHIFT=(PLAY_ZOOM==4)?(LOG2_N-4):(LOG2_N-3);
 wire bin_valid,frame_done,core_busy;
 wire [LOG2_N-1:0] bin_index;
 wire signed [17:0] bin_real,bin_imag;
 wire [15:0] fft_frame;
 fft_spectrum_core #(.LOG2_N(LOG2_N)) u_core(
  .clk_i(sample_clk_i),.rst_n_i(sample_rst_n_i),.enable_i(1'b1),
  .sample_valid_i(sample_valid_i),.sample_i(sample_i[23:8]),
  .bin_valid_o(bin_valid),.bin_index_o(bin_index),.bin_real_o(bin_real),.bin_imag_o(bin_imag),
  .frame_done_o(frame_done),.frame_id_o(fft_frame),.busy_o(core_busy),
  .overflow_o(overflow_o),.dropped_samples_o(dropped_samples_o));
 wire [17:0] abs_real=bin_real[17] ? (~bin_real+18'd1) : bin_real;
 wire [17:0] abs_imag=bin_imag[17] ? (~bin_imag+18'd1) : bin_imag;
 reg [18:0] magnitude_q;
 reg magnitude_valid;
 reg [LOG2_N-1:0] magnitude_index;
 reg [15:0] magnitude_frame,finish_frame;
 reg [5:0] magnitude_n,finish_n;
 reg [5:0] spectrum_n;
 reg [8:0] pair_height;
 reg [8:0] histogram[0:2*BARS-1];
 reg [8:0] display_bars[0:BARS-1];
 // Two snapshot copies, each with one synchronous write and one read.
 reg [8:0] display_right[0:BARS-1];
 reg histogram_we;
 reg [LOG2_N-2:0] histogram_waddr;
 reg [8:0] histogram_wdata;
 reg write_bank,published_bank,publish_toggle,finish_q;
 reg [15:0] published_frame;
 reg [5:0] published_n;
 reg ack_meta,ack_sync;
 reg pixel_ack;
 (* syn_preserve=1 *) reg publish_launch,bank_launch;
 (* syn_preserve=1 *) reg [15:0] frame_launch;
 (* syn_preserve=1 *) reg [5:0] n_launch;
 reg request_meta,request_sync,bank_meta,bank_sync;
 reg [15:0] frame_meta,frame_sync;
 reg [5:0] n_meta,n_sync;
 reg copying,copy_valid_q,copy_bank,copy_request;
 reg [LOG2_N-3:0] copy_index,copy_index_q;
 reg [15:0] copy_frame;
 reg [5:0] copy_n;
 reg [8:0] histogram_q,bar_q;
 reg [8:0] right_q;
 reg [7:0] fraction_q;
 reg [8:0] copy_peak;
 wire [8:0] copy_group_peak=(histogram_q>copy_peak)?histogram_q:copy_peak;
 reg [9:0] x_q,y_q;
 reg de_q,hs_q,vs_q;
 wire [9:0] plot_x=x_i-10'd64;
 wire [LOG2_N-3:0] full_bar_address=plot_x>>(11-LOG2_N);
 wire [LOG2_N-3:0] zoom_bar_address=plot_x>>((OUTLINE_EN!=0)?NORMAL_SHIFT:(13-LOG2_N));
 // Use acknowledged frame metadata, never the live sys-domain test input.
 // Both the local bars and this range change together during vertical blank.
 wire [LOG2_N-3:0] bar_address=(test_n_o==0)?zoom_bar_address:full_bar_address;
 wire [LOG2_N-3:0] right_address=(bar_address==BARS-1)?bar_address:bar_address+1'b1;
 wire [7:0] fraction_i=(test_n_o==0)?(plot_x<<NORMAL_FRAC_SHIFT):(plot_x<<(LOG2_N-3));
 wire signed [9:0] slope=$signed({1'b0,right_q})-$signed({1'b0,bar_q});
 wire signed [18:0] weighted=slope*$signed({1'b0,fraction_q});
 wire signed [18:0] slope_step=(test_n_o==0)?
   ($signed({{9{slope[9]}},slope})<<<NORMAL_FRAC_SHIFT):
   ($signed({{9{slope[9]}},slope})<<<(LOG2_N-3));
 wire signed [18:0] next_weighted=weighted+slope_step;
 wire signed [18:0] line_start=$signed({1'b0,bar_q})+(weighted>>>8);
 wire signed [18:0] line_end=$signed({1'b0,bar_q})+(next_weighted>>>8);
 wire [8:0] line_low=(line_start<line_end)?line_start[8:0]:line_end[8:0];
 wire [8:0] line_high=(line_start>line_end)?line_start[8:0]:line_end[8:0];
 wire [9:0] plot_height=10'd447-y_q;
 wire outline_hit=(line_high!=0 && plot_height>=line_low && plot_height<=({1'b0,line_high}+10'd1));
 function [8:0] height;
  input [18:0] mag;
  reg [4:0] leading;
  reg [4:0] above_floor;
  reg found;
  reg [18:0] normalized;
  reg [9:0] h;
  integer k;
  begin
   leading=0;above_floor=0;found=0;normalized=0;h=0;
   for(k=18;k>=0;k=k-1)if(!found && mag[k])begin leading=k;found=1;end
   if(mag<=8)height=0;
   else begin
    normalized=mag>>(leading-3);
    // Zero height at magnitude 8, then 32 pixels per amplitude octave.
    // Preserve all above-floor bins; this is display scaling, not filtering.
    above_floor=leading-5'd3;
    h={above_floor,5'b0}+{5'b0,normalized[2:0],2'b0};
    height=(h>400)?9'd400:h[8:0];
   end
  end
 endfunction
 wire [8:0] this_height=height(magnitude_q);
 wire [8:0] merged_height=(this_height>pair_height)?this_height:pair_height;
 // Explicit metadata publication on source FALLING edge. The bank/frame/N
 // bundle remains immutable until pixel_ack returns through two sys stages.
 always @(negedge sample_clk_i)begin
  if(!sample_rst_n_i)begin publish_launch<=0;bank_launch<=0;frame_launch<=0;n_launch<=0;end
  else begin publish_launch<=publish_toggle;bank_launch<=published_bank;
   frame_launch<=published_frame;n_launch<=published_n;end
 end
 always @(posedge sample_clk_i)begin
  if(histogram_we)histogram[histogram_waddr]<=histogram_wdata;
  if(!sample_rst_n_i)begin
   magnitude_q<=0;magnitude_valid<=0;magnitude_index<=0;magnitude_frame<=0;magnitude_n<=0;spectrum_n<=0;
   pair_height<=0;write_bank<=0;published_bank<=0;publish_toggle<=0;
   histogram_we<=0;histogram_waddr<=0;histogram_wdata<=0;
   finish_q<=0;finish_frame<=0;finish_n<=0;published_frame<=0;published_n<=0;
   ack_meta<=0;ack_sync<=0;dropped_frames_o<=0;
  end else begin
   ack_meta<=pixel_ack;ack_sync<=ack_meta;
   magnitude_valid<=bin_valid;histogram_we<=0;finish_q<=0;
   if(bin_valid)begin
    magnitude_q<={1'b0,abs_real}+{1'b0,abs_imag};magnitude_index<=bin_index;
    magnitude_frame<=fft_frame;
    if(bin_index==0)begin spectrum_n<=test_n_i;magnitude_n<=test_n_i;end
    else magnitude_n<=spectrum_n;
   end
   if(magnitude_valid)begin
    if(magnitude_index==N/2)begin
     if(!(OUTLINE_EN!=0 && magnitude_n==0))begin
      histogram_we<=1;histogram_waddr<={write_bank,{(LOG2_N-2){1'b1}}};
      histogram_wdata<=merged_height;
     end
     finish_q<=1;
     finish_frame<=magnitude_frame;finish_n<=magnitude_n;
    end else if(OUTLINE_EN!=0 && magnitude_n==0)begin
     if(magnitude_index<BARS)begin
      histogram_we<=1;histogram_waddr<={write_bank,magnitude_index[LOG2_N-3:0]};
      histogram_wdata<=((PLAY_ZOOM!=4)||(magnitude_index<=N/8))?this_height:9'd0;
     end
    end else if(magnitude_index[0])begin
     histogram_we<=1;histogram_waddr<={write_bank,magnitude_index[LOG2_N-2:1]};
     histogram_wdata<=merged_height;pair_height<=merged_height;
    end else pair_height<=this_height;
   end
   // Last histogram word commits on this edge, before the falling-edge launch.
   if(finish_q)begin
    if(publish_toggle==ack_sync)begin
     published_bank<=write_bank;published_frame<=finish_frame;published_n<=finish_n;
     publish_toggle<=~publish_toggle;write_bank<=~write_bank;
    end else if(dropped_frames_o!=32'hffffffff)dropped_frames_o<=dropped_frames_o+32'd1;
   end
  end
 end
 always @(posedge pixel_clk_i)begin
  request_meta<=publish_launch;request_sync<=request_meta;
  bank_meta<=bank_launch;bank_sync<=bank_meta;
  frame_meta<=frame_launch;frame_sync<=frame_meta;n_meta<=n_launch;n_sync<=n_meta;
  histogram_q<=histogram[{copy_bank,copy_index}];
  bar_q<=display_bars[(COLOR_BARS_EN!=0)?(bar_address>>2):bar_address];
  right_q<=display_right[right_address];fraction_q<=fraction_i;
  if(copy_valid_q)begin
   if(COLOR_BARS_EN!=0)begin
    if(copy_index_q[1:0]==0)copy_peak<=histogram_q;
    else copy_peak<=copy_group_peak;
    if(copy_index_q[1:0]==3)display_bars[copy_index_q>>2]<=copy_group_peak;
   end else begin
    display_bars[copy_index_q]<=histogram_q;display_right[copy_index_q]<=histogram_q;
   end
  end
  if(!pixel_rst_n_i)begin
   request_meta<=0;request_sync<=0;bank_meta<=0;bank_sync<=0;
   frame_meta<=0;frame_sync<=0;n_meta<=0;n_sync<=0;
   copying<=0;copy_valid_q<=0;copy_bank<=0;copy_request<=0;copy_index<=0;copy_index_q<=0;copy_peak<=0;
   copy_frame<=0;copy_n<=0;pixel_ack<=0;frame_ready_o<=0;frame_id_o<=0;test_n_o<=0;
  end else begin
   copy_valid_q<=copying;
   if(!copying && x_i==0 && y_i==480 && request_sync!=pixel_ack)begin
    copy_bank<=bank_sync;copy_request<=request_sync;copy_frame<=frame_sync;copy_n<=n_sync;
    copying<=1;copy_index<=0;
   end else if(copying)begin
    copy_index_q<=copy_index;
    if(copy_index==BARS-1)copying<=0;else copy_index<=copy_index+1'b1;
   end
   if(copy_valid_q && copy_index_q==BARS-1)begin
    pixel_ack<=copy_request;frame_ready_o<=1;frame_id_o<=copy_frame;test_n_o<=copy_n;
   end
  end
 end
 function [34:0] glyph;
  input [3:0] id;
  begin case(id)
   0:glyph=35'b11111_10000_10000_11110_10000_10000_10000; // F
   1:glyph=35'b11111_00100_00100_00100_00100_00100_00100; // T
   2:glyph=35'b10001_11001_10101_10011_10001_10001_10001; // N
   3:glyph=35'b00000_00000_11111_00000_11111_00000_00000; // =
   4:glyph=35'b01110_10001_10011_10101_11001_10001_01110; // 0
   5:glyph=35'b00100_01100_00100_00100_00100_00100_01110;
   6:glyph=35'b01110_10001_00001_00010_00100_01000_11111;
   7:glyph=35'b11110_00001_00001_01110_00001_00001_11110;
   8:glyph=35'b00010_00110_01010_10010_11111_00010_00010;
   9:glyph=35'b11111_10000_10000_11110_00001_00001_11110;
   10:glyph=35'b01110_10000_10000_11110_10001_10001_01110;
   11:glyph=35'b11111_00001_00010_00100_01000_01000_01000;
   12:glyph=35'b01110_10001_10001_01110_10001_10001_01110;
   13:glyph=35'b01110_10001_10001_01111_00001_00001_01110;
   default:glyph=0;
  endcase end
 endfunction
 function header_hit;
  input [9:0] x,y;
  input [5:0] n;
  reg [3:0] ch;
  reg [9:0] lx;
  reg [34:0] bits;
  reg [5:0] bitpos;
  reg [2:0] digit_tens,glyph_row;
  reg [5:0] tens_value,digit_ones;
  begin
   header_hit=0;ch=15;lx=0;bits=0;bitpos=0;glyph_row=0;
   // Exact unsigned 6-bit decimal conversion, including non-test N values.
   digit_tens=(n>=60)?3'd6:(n>=50)?3'd5:(n>=40)?3'd4:
              (n>=30)?3'd3:(n>=20)?3'd2:(n>=10)?3'd1:3'd0;
   tens_value={digit_tens,3'b0}+{2'b0,digit_tens,1'b0};
   digit_ones=n-tens_value;
   if(x>=64 && x<160 && y>=8 && y<22)begin
    if(x<76)begin ch=0;lx=x-64;end
    else if(x<88)begin ch=0;lx=x-76;end
    else if(x<100)begin ch=1;lx=x-88;end
    else if(x<112)begin ch=15;lx=x-100;end
    else if(x<124)begin ch=2;lx=x-112;end
    else if(x<136)begin ch=3;lx=x-124;end
    else if(x<148)begin ch=4'd4+{1'b0,digit_tens};lx=x-136;end
    else begin ch=4'd4+digit_ones[3:0];lx=x-148;end
    bits=glyph(ch);glyph_row=6-((y-8)>>1);
    bitpos={1'b0,glyph_row,2'b0}+{3'b0,glyph_row}+6'd4-(lx>>1);
    if(lx<10)header_hit=bits[bitpos];
   end
  end
 endfunction
 function [23:0] frequency_color;
  input [6:0] column;
  reg [7:0] ramp;
  begin
   ramp={column[4:0],3'b0};
   case(column[6:5])
    0:frequency_color={8'hff,(8'd64+(ramp>>2)),(8'd128-(ramp>>1))};
    1:frequency_color={8'hff,(8'd128+(ramp>>1)),8'h00};
    2:frequency_color={(8'd255-ramp),8'hff,8'h00};
    3:frequency_color={8'h00,8'hff,ramp};
   endcase
  end
 endfunction
 wire [9:0] color_plot_x=x_q-10'd64;
 wire [23:0] bar_color=frequency_color(color_plot_x[8:2]);
 always @(posedge pixel_clk_i)begin
  if(!pixel_rst_n_i)begin
   x_q<=0;y_q<=0;de_q<=0;hs_q<=1;vs_q<=1;
   r_o<=0;g_o<=0;b_o<=0;de_o<=0;hs_o<=1;vs_o<=1;
  end else begin
   x_q<=x_i;y_q<=y_i;de_q<=de_i;hs_q<=hs_i;vs_q<=vs_i;
   de_o<=de_q;hs_o<=hs_q;vs_o<=vs_q;r_o<=0;g_o<=0;b_o<=0;
   if(de_q)begin
    if(frame_ready_o && header_hit(x_q,y_q,test_n_o))begin r_o<=8'h80;g_o<=8'hff;b_o<=8'hff;end
    else if(frame_ready_o && x_q>=64 && x_q<576 && y_q>=32 && y_q<=447 &&
            ((COLOR_BARS_EN!=0)?(color_plot_x[1:0]!=3 && bar_q!=0 && y_q>=447-bar_q):
              ((OUTLINE_EN!=0)?outline_hit:(bar_q!=0 && y_q>=447-bar_q))))begin
     if(COLOR_BARS_EN!=0)begin r_o<=bar_color[23:16];g_o<=bar_color[15:8];b_o<=bar_color[7:0];end
     else begin r_o<=0;g_o<=8'hff;b_o<=8'h80;end
    end
    else if(x_q>=64 && x_q<=576 && (y_q==447 || y_q==32))begin r_o<=8'h28;g_o<=8'h28;b_o<=8'h28;end
   end
  end
 end
endmodule
`default_nettype wire
