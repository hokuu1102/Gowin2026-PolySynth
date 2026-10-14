`timescale 1ns/1ps
module nm_compare_probe #(parameter integer W=16, parameter integer SEED=32'h426913af) (output reg done);
  reg clk=0;
  always #10 clk=~clk;
  reg [W-1:0] a,b;
  reg [1:0] cls,bcls;
  reg valid;
  integer i;
  reg [31:0] rnd=SEED;
  function [31:0] step;
    input [31:0] x;
    reg [31:0] t;
    begin t=x^(x<<13); t=t^(t>>17); step=t^(t<<5); end
  endfunction
  note_manager #(.POLY_TARGET(4),.ENV_W(W),.AGE_W(W)) dut (.clk_i(clk),.rst_n_i(1'b0));
  note_manager_af_reference #(.POLY_TARGET(4),.ENV_W(W),.AGE_W(W)) gold (.clk_i(clk),.rst_n_i(1'b0));
  initial begin
    done=0; a=0; b=0; cls=1; bcls=1; valid=1;
    force dut.cand_env=a; force gold.cand_env=a;
    force dut.best_env=b; force gold.best_env=b;
    force dut.cand_cls=cls; force gold.cand_cls=cls;
    force dut.best_cls=bcls; force gold.best_cls=bcls;
    force dut.best_valid=valid; force gold.best_valid=valid;
    force dut.cand_age=a; force gold.cand_age=a;
    force dut.best_age=b; force gold.best_age=b;
    for(i=0;i<100000;i=i+1) begin
      rnd=step(rnd); a=rnd;
      rnd=step(rnd); b=rnd;
      case(i%8)
        0: b=a;
        1: b=a+1'b1;
        2: b=a-1'b1;
        3: b=0;
        4: b={W{1'b1}};
        5: begin
          a=a & ((1<<(W/2))-1);
          b=b & ((1<<(W/2))-1);
        end
      endcase
      if(i%16<8) begin cls=1; bcls=1; valid=1; end
      else begin cls=(i%3); bcls=((i/3)%3); valid=i%2; end
      #1;
      if(dut.cand_env_less !== (a<b))
        $fatal(1,"split compare mismatch width=%0d a=%h b=%h",W,a,b);
      if(dut.cand_age_more !== (a>b))
        $fatal(1,"split age mismatch width=%0d a=%h b=%h",W,a,b);
      if(dut.cand_better !== gold.cand_better)
        $fatal(1,"selection mismatch width=%0d index=%0d",W,i);
    end
    $display("PASS: actual NM comparator width=%0d comparisons=100000",W);
    done=1;
  end
endmodule
module tb_opt04_nm_compare_values;
  wire [3:0] done;
  nm_compare_probe #(.W(1)) a(done[0]);
  nm_compare_probe #(.W(7)) b(done[1]);
  nm_compare_probe #(.W(16)) c(done[2]);
  nm_compare_probe #(.W(17)) d(done[3]);
  initial begin wait(&done); $display("PASS: comparator boundary/random checks 400000"); $finish; end
  initial begin #200000; $fatal(1,"timeout"); end
endmodule
