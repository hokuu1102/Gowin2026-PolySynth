`timescale 1ns/1ps
// Compare the complete display ledger against the original direct interface,
// delayed by exactly one clock. Controls deliberately change between notes.
module tb_top_guide_input_snapshot;
reg clk=0,rst_n=0; always #10 clk=~clk;
top #(.PA_ON_AFTER_RESET(0),.DEMO_CHORD_ON(1),.DEMO_NOTE_DELAY(1000000),.DEMO_HOLD_CYC(1000000),.AUTOTARE_DELAY_CLK(100),.SPAN_WAIT_TIMEOUT_CLK(1000),.HEARTBEAT_DIV(100)) dut(
 .clk(clk),.rst_n(rst_n),.timbre_btn_i(1'b1),.spi_miso(6'b111111),.uart_rx(1'b1),.esp_uart_rx_i(1'b1));
defparam dut.u_guide_lamp.TIMEOUT_CLKS=16;
reg valid=0,alive=1,fb=0; reg [63:0] data=0;
reg signed [4:0] trans=0; reg [15:0] keys=0;
wire [15:0] reference_keys;
guide_lamp #(.TIMEOUT_CLKS(16)) reference(
 .clk_i(clk),.rst_n_i(dut.rst_n_sync),
 .note_valid_i(dut.gl_note_valid_raw),.note_data_i(data),.note_off5_i(data[4:0]),
 .transpose_i(trans),.fb_mode_i(fb),.key_active_i(keys),
 .stream_alive_i(alive|valid),.guide_key_o(reference_keys));
reg [15:0] previous_keys=0; integer count=0,i; reg [31:0] random_state=32'h47f05ace;
always @(posedge clk) begin
 previous_keys=reference_keys;
 #1;
 if(dut.rst_n_sync) begin
  if(dut.u_guide_lamp.guide_key_o !== previous_keys)
   $fatal(1,"FAIL: delayed ledger mismatch cycle %0d expected %h got %h",count,previous_keys,dut.u_guide_lamp.guide_key_o);
  if(dut.gl_guide_vis !== (previous_keys & ~keys))
   $fatal(1,"FAIL: live physical-key mask changed");
  count=count+1;
 end
end
initial begin
 force dut.ps_note_valid=valid; force dut.ps_note_data=data;
 force dut.transpose_semi=trans; force dut.play_fretboard_mode=fb;
 force dut.eb_rd_valid=alive; force dut.ee_key_on=keys;
 force dut.guide_only_r=1'b1;
 repeat(10) @(negedge clk); rst_n=1;
 repeat(50) @(negedge clk);
 for(i=0;i<2048;i=i+1) begin
  @(negedge clk);
  random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
  valid=random_state[0]; fb=random_state[1];
  trans=$signed({1'b0,random_state[5:2]})-8;
  data=0;data[4:0]=random_state[10:6];data[22:19]=random_state[14:11];
  data[10:9]=random_state[16:15]==0 ? 2'd1 : 2'd0;
  keys=random_state[31:16]; alive=1;
 end
 @(negedge clk); valid=0;alive=0;keys=0;
 repeat(40) @(negedge clk);
 if(dut.u_guide_lamp.guide_key_o!==0)$fatal(1,"FAIL: timeout failed to clear");
 rst_n=0;repeat(10)@(negedge clk);rst_n=1;
 repeat(50)@(negedge clk);
 $display("PASS: %0d top snapshot comparisons, metadata, live mask, timeout and reset",count);$finish;
end
initial begin #1000000;$fatal(1,"FAIL: watchdog");end
endmodule
