`timescale 1ns/1ps
module tb_fx_public_contract;
  reg clk=0; always #10 clk=~clk;
  reg rst=0, v=0;
  reg signed [23:0] x=0;
  wire vd0,vd1,vt0,vt1,vc0,vc1;
  wire signed [23:0] yd0,yd1,yt0,yt1,yc0,yc1;
  integer sent=0, cd0=0,cd1=0,ct0=0,ct1=0,cc0=0,cc1=0;
  integer ed0=0,ed1=0,et0=0,et1=0,ec0=0,ec1=0;
  reg signed [23:0] expected[0:15];
  fx_dist d0(.clk_i(clk),.rst_n_i(rst),.valid_i(v),.sample_i(x),
    .en_i(1'b0),.sel_i(2'd0),.gain_i(16'd4096),.trim_i(16'd32768),.valid_o(vd0),.sample_o(yd0));
  fx_dist d1(.clk_i(clk),.rst_n_i(rst),.valid_i(v),.sample_i(x),
    .en_i(1'b1),.sel_i(2'd0),.gain_i(16'd4096),.trim_i(16'd32768),.valid_o(vd1),.sample_o(yd1));
  fx_trem t0(.clk_i(clk),.rst_n_i(rst),.valid_i(v),.sample_i(x),
    .en_i(1'b0),.depth_i(8'd0),.rate_i(8'd0),.valid_o(vt0),.sample_o(yt0));
  fx_trem t1(.clk_i(clk),.rst_n_i(rst),.valid_i(v),.sample_i(x),
    .en_i(1'b1),.depth_i(8'd0),.rate_i(8'd0),.valid_o(vt1),.sample_o(yt1));
  fx_chain #(.AW(10),.AW_CH(10)) c0(.clk_i(clk),.rst_n_i(rst),.valid_i(v),.sample_i(x),
    .en_mask_i(8'd0),.dist_sel_i(2'd0),.dist_gain_i(16'd4096),.dist_trim_i(16'd32768),
    .dly_delay_i(10'd16),.chor_delay_i(10'd16),.dly_mix_i(8'd0),.dly_fb_i(8'd0),
    .trem_depth_i(8'd0),.trem_rate_i(8'd0),.valid_o(vc0),.sample_o(yc0));
  fx_chain #(.AW(10),.AW_CH(10)) c1(.clk_i(clk),.rst_n_i(rst),.valid_i(v),.sample_i(x),
    .en_mask_i(8'd1),.dist_sel_i(2'd0),.dist_gain_i(16'd4096),.dist_trim_i(16'd32768),
    .dly_delay_i(10'd16),.chor_delay_i(10'd16),.dly_mix_i(8'd0),.dly_fb_i(8'd0),
    .trem_depth_i(8'd0),.trem_rate_i(8'd0),.valid_o(vc1),.sample_o(yc1));
  always @(posedge clk) begin
    if(rst && v) begin expected[sent]=x; sent=sent+1; end
    #1;
    if(rst) begin
      if(vd0) begin if(yd0 !== expected[cd0]) ed0=ed0+1; cd0=cd0+1; end
      if(vd1) begin if(yd1 !== expected[cd1]) begin ed1=ed1+1; $display("MISMATCH dist active expected=%0d actual=%0d",expected[cd1],yd1); end cd1=cd1+1; end
      if(vt0) begin if(yt0 !== expected[ct0]) et0=et0+1; ct0=ct0+1; end
      if(vt1) begin if(yt1 !== expected[ct1]) begin et1=et1+1; $display("MISMATCH trem depth0 expected=%0d actual=%0d",expected[ct1],yt1); end ct1=ct1+1; end
      if(vc0) begin if(yc0 !== expected[cc0]) ec0=ec0+1; cc0=cc0+1; end
      if(vc1) begin if(yc1 !== expected[cc1]) ec1=ec1+1; cc1=cc1+1; end
    end
  end
  integer k;
  initial begin
    repeat(5) @(negedge clk); rst=1;
    repeat(10) @(negedge clk);
    for(k=0;k<4;k=k+1) begin
      x=(k+1)*100000; v=1;
      @(negedge clk); v=0; x=0;
      repeat(63) @(negedge clk);
    end
    repeat(30) @(negedge clk);
    $display("sent=%0d received dist_bypass=%0d dist_active=%0d trem_bypass=%0d trem_active=%0d chain_bypass=%0d chain_dist=%0d",sent,cd0,cd1,ct0,ct1,cc0,cc1);
    $display("errors dist_bypass=%0d dist_active=%0d trem_bypass=%0d trem_active=%0d chain_bypass=%0d chain_dist=%0d",ed0,ed1,et0,et1,ec0,ec1);
    if(ed0+ed1+et0+et1+ec0+ec1 != 0 || cd0!=sent || cd1!=sent || ct0!=sent || ct1!=sent || cc0!=sent || cc1!=sent)
      $fatal(1,"FAIL public valid/sample contract: invalid-cycle sample changes corrupt valid output");
    $display("PASS public valid/sample contract"); $finish;
  end
endmodule
