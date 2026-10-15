`timescale 1ns/1ps
module bg_mixer_probe #(parameter P=32, O=16, E=16, SH=1, STEP=1)
 (input clk,output reg done=0);
 reg rst=0,start=0;
 reg [P*2*O-1:0] osc=0;
 reg [P*E-1:0] env=0;
 reg [P-1:0] active=0;
 wire valid,ref_valid,fault,ref_fault;
 wire signed [23:0] sample,ref_sample;
 wire [$clog2(P):0] n,ref_n;
 integer f,c,lane,wave,pk=0,nk=0,pc=0,nc=0;
 tdm_render_mixer #(.POLY_TARGET(P),.OSC_SAMPLE_W(O),.ENV_W(E),
 .OUTPUT_HEADROOM_SH(SH),.NORM_GAIN_STEP(STEP)) dut
 (.clk_i(clk),.rst_n_i(rst),.render_start_i(start),.osc_sample_bus_i(osc),
 .env_level_i(env),.voice_active_i(active),.dry_valid_o(valid),
 .dry_sample_o(sample),.deadline_fault_o(fault),.n_active_o(n));
 tdm_render_mixer_bg_reference #(.POLY_TARGET(P),.OSC_SAMPLE_W(O),.ENV_W(E),
 .OUTPUT_HEADROOM_SH(SH),.NORM_GAIN_STEP(STEP)) bg
 (.clk_i(clk),.rst_n_i(rst),.render_start_i(start),.osc_sample_bus_i(osc),
 .env_level_i(env),.voice_active_i(active),.dry_valid_o(ref_valid),
 .dry_sample_o(ref_sample),.deadline_fault_o(ref_fault),.n_active_o(ref_n));
 always @(posedge clk) begin
 #1;
 if({valid,sample,fault,n}!=={ref_valid,ref_sample,ref_fault,ref_n})
  $fatal(1,"FAIL: BG mixer public cycle mismatch P=%0d O=%0d E=%0d frame=%0d cycle=%0d",P,O,E,f,c);
 if(rst && valid) begin
  if(ref_sample>24'sh700000 && ref_sample<24'sh780000) pk=pk+1;
  if(ref_sample< -24'sh700000 && ref_sample> -24'sh780000) nk=nk+1;
  if(ref_sample==24'sh780000) pc=pc+1;
  if(ref_sample== -24'sh780000) nc=nc+1;
 end
 end
 initial begin
 repeat(4) @(negedge clk);rst=1;
 for(f=0;f<4096;f=f+1) begin
  @(negedge clk);
  wave=((f*37)%65536)-32768;
  if(f%31==0) wave=(1<<(O-1))-1;
  if(f%31==1) wave=-(1<<(O-1));
  for(lane=0;lane<P*2;lane=lane+1) osc[lane*O+:O]=wave;
  env={P*E{1'b1}};active={P{1'b1}};
  if(f%67==0) begin env=0;active=0;end
  if(f%67==1) active=1;
  start=1;
  @(negedge clk);start=0;
  for(c=0;c<P+16;c=c+1) begin
   @(negedge clk);
   // Public inputs change within a render to pin down existing cycle behavior.
   if(f%7==0 && c==P/2) osc=~osc;
   if(f==777 && c==3) rst=0;
   if(f==777 && c==6) rst=1;
  end
 end
 if(E==16 && (pk==0 || nk==0 || pc==0 || nc==0))
  $fatal(1,"FAIL: vacuous mixer knee coverage P=%0d +k=%0d -k=%0d +clip=%0d -clip=%0d",P,pk,nk,pc,nc);
 $display("COVER: mixer P=%0d O=%0d E=%0d positive/negative knee=%0d/%0d ceiling=%0d/%0d",P,O,E,pk,nk,pc,nc);
 done=1;
 end
endmodule
module tb_bg_mixer_cycle_equiv;
 reg clk=0;always #10 clk=~clk;
 wire a,b,c,d;
 bg_mixer_probe production(clk,a);
 bg_mixer_probe #(.P(4),.O(24),.SH(0),.STEP(0)) wide_input(clk,b);
 bg_mixer_probe #(.P(4),.O(15),.E(1),.SH(0),.STEP(0)) legacy_narrow(clk,c);
 bg_mixer_probe #(.P(32),.O(15),.E(1),.SH(0),.STEP(0)) signed_product_edge(clk,d);
 initial begin wait(a&&b&&c&&d);
 $display("PASS: BG mixer samples, valid, fault and active count match every clock");$finish;end
 initial begin #6000000;$fatal(1,"FAIL: BG mixer differential watchdog");end
endmodule
