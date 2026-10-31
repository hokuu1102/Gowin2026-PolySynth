`timescale 1ns/1ps
// Display snapshots must preserve all values and change only at a clock edge.
module tb_top_ui_snapshot;
  reg clk=0;always #10 clk=~clk;
  reg rst=0;
  reg [15:0] gain=0;
  reg [11:0] depth=0,prate=0;
  reg [7:0] vdepth=0,vrate=7;
  reg [6:0] old_vol,old_pd,old_vd;
  integer i,seed,ev,ep,ed;
  top #(.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .DEMO_NOTE_DELAY(10000000),.AUTOTARE_DELAY_CLK(10000000)) dut(
    .clk(clk),.rst_n(rst),.uart_rx(1'b1),.esp_uart_rx_i(1'b1),
    .spi_miso(6'b111111),.ctrl_col_i(4'b1111),.timbre_btn_i(1'b1),
    .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1),
    .pluck_up_i(1'b0),.pluck_down_i(1'b0));
  initial begin
    force dut.g_sound.master_gain=gain;
    force dut.g_sound.vib_depth_sel=depth;
    force dut.g_sound.trem_depth_eff=vdepth;
    force dut.g_sound.vib_rate_sel=prate;
    force dut.g_sound.trem_rate_eff=vrate;
    seed=30291;
    repeat(20)@(negedge clk);rst=1;repeat(30)@(negedge clk);
    for(i=0;i<1024;i=i+1)begin
      @(negedge clk);
      old_vol=dut.ui_vol_pct;old_pd=dut.ui_pvib_pct;old_vd=dut.ui_vvib_pct;
      gain=$random(seed)&32767;depth=$random(seed);prate=$random(seed);
      vdepth=$random(seed);vrate=$random(seed);
      #1;
      if({dut.ui_vol_pct,dut.ui_pvib_pct,dut.ui_vvib_pct}!=={old_vol,old_pd,old_vd})
        $fatal(1,"display changes combinationally between clock edges");
      ev=(gain*100)/32768;ep=(depth*100)/4096;ed=(vdepth*100)/256;
      @(posedge clk);#1;
      if(dut.ui_vol_pct!==ev[6:0] || dut.ui_pvib_pct!==ep[6:0] || dut.ui_vvib_pct!==ed[6:0]
          || dut.ui_prate_raw!==prate || dut.ui_vrate_eff!==vrate)
        $fatal(1,"display snapshot changed value or introduced extra latency");
    end
    $display("PASS: 1024 exact UI percentage/rate snapshots, stable between edges");
    $finish;
  end
  initial begin #200000;$fatal(1,"UI snapshot watchdog");end
endmodule
