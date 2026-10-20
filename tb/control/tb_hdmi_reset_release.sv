`timescale 1ns/1ps
module tb_hdmi_reset_release;
  reg clk=0;always #10 clk=~clk;
  reg rst=0;
  wire [2:0] dp,dn;
  wire cp,cn,hpd;
  hdmi_scope dut(.clk(clk),.rst_n(rst),.SCOPE_MODE(1'b0),.FFT_MODE(1'b0),
    .TEST_N(6'd0),.sample_i(24'sd0),.valid_i(1'b0),
    .tmds_d_p_0(dp),.tmds_d_n_0(dn),.tmds_clk_p_0(cp),.tmds_clk_n_0(cn),.hpd_en(hpd));
  integer words=0;
  always @(posedge dut.pixel_clk) words=words+1;
  always @(negedge dut.u_serializer.reset_release) begin
    if(dut.pixel_clk!==1'b1 || words<4)
      $fatal(1,"OSER reset released before word-clock synchronization");
  end
  initial begin
    #41;
    if(dut.u_serializer.reset_release!==1'b1)$fatal(1,"powerup reset missing");
    rst=1;
    repeat(8)@(negedge dut.pixel_clk);
    if(dut.u_serializer.reset_release!==1'b0)$fatal(1,"reset did not release");
    if(hpd!==1'b1)$fatal(1,"HPD");
    $display("PASS: OSER reset starts asserted and releases at a synchronized word boundary");
    $finish;
  end
  initial begin #10000;$fatal(1,"HDMI clock/reset timeout");end
endmodule
