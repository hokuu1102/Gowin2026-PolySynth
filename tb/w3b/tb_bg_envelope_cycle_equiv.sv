`timescale 1ns/1ps
module bg_env_probe #(parameter POLY=32, parameter FALLBACK=0, parameter DEC=4)
 (input clk, output reg done=0);
 reg rst=0,tick=0;
 reg [POLY-1:0] gate=0,retrigger=0;
 reg [POLY*8-1:0] vel=0;
 reg [POLY*2-1:0] timbre=0;
 wire [POLY*16-1:0] actual,reference;
 wire [POLY-1:0] active,ref_active;
 reg [31:0] rng=32'h179A2053;
 integer frame,c,v;
 envelope_bank #(.POLY_TARGET(POLY),.DECAY_STEP(DEC)) dut
 (.clk_i(clk),.rst_n_i(rst),.sample_tick_i(tick),.gate_i(gate),
 .velocity_i(vel),.retrig_reset_i(retrigger),.timbre_i(timbre),
 .env_level_o(actual),.env_active_o(active));
 envelope_bank_bg_reference #(.POLY_TARGET(POLY),.DECAY_STEP(DEC)) ref_bg
 (.clk_i(clk),.rst_n_i(rst),.sample_tick_i(tick),.gate_i(gate),
 .velocity_i(vel),.retrig_reset_i(retrigger),.timbre_i(timbre),
 .env_level_o(reference),.env_active_o(ref_active));
 always @(posedge clk) begin
 #1;
 if(actual!==reference || active!==ref_active)
 $fatal(1,"FAIL: BG envelope public cycle mismatch poly=%0d fallback=%0d frame=%0d cycle=%0d",POLY,FALLBACK,frame,c);
 end
 task advance_random;
 begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};end
 endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;
 for(v=0;v<POLY;v=v+1) begin vel[v*8+:8]=255-v*5;timbre[v*2+:2]=v%4;end
 if(FALLBACK) timbre={POLY*2{1'bz}};
 gate={POLY{1'b1}};
 // Long holds reach decay and sustain for all four production timbres.
 for(frame=0;frame<42000;frame=frame+1) begin
  @(negedge clk);tick=1;
  @(negedge clk);tick=0;
  for(c=0;c<POLY+3;c=c+1) begin
   @(negedge clk);
   if(frame>=40000) begin
    advance_random;
    gate=rng;retrigger=(rng & 32'h01000401);
    for(v=0;v<POLY;v=v+1) begin
     advance_random;vel[v*8+:8]=rng[7:0];
     if(!FALLBACK) timbre[v*2+:2]=rng[9:8];
    end
   end
  end
  if(frame==12000) vel={POLY{8'd60}};
  if(frame==22000) vel={POLY{8'd240}};
  if(frame==32000) gate=0;
  if(frame==38000) begin gate={POLY{1'b1}};retrigger={POLY{1'b1}};end
  if(frame==38001) retrigger=0;
 end
 done=1;
 end
endmodule
module tb_bg_envelope_cycle_equiv;
 reg clk=0;
 always #10 clk=~clk;
 wire a,b,c;
 bg_env_probe #(.POLY(32)) p32(clk,a);
 bg_env_probe #(.POLY(4),.FALLBACK(1),.DEC(8192)) p4(clk,b);
 bg_env_probe #(.POLY(4),.FALLBACK(1),.DEC(131071)) edge_config(clk,c);
 initial begin
 wait(a&&b&&c);
 $display("PASS: BG envelope equivalence every clock, 32 voices, four timbres and fallback boundaries");$finish;
 end
 initial begin #40000000;$fatal(1,"FAIL: BG envelope equivalence watchdog");end
endmodule
