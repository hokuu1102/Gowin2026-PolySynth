`timescale 1ns/1ps
module tb_dump_pitch_roundtrip;
  reg clk=0, rst=0;
  always #10 clk=~clk;
  reg rec=0, stop=0, lv=0, dump=0, feed=0;
  reg [31:0] inc=0;
  reg [15:0] addr=0;
  wire [63:0] data;
  wire clip, nv, rd;
  wire [63:0] nd;
  wire [15:0] cnt;
  // This is the exact production top.v:4064 expression, not the expected value.
  wire [31:0] feedback_inc = {1'b0, nd[43:23], 10'b0};
  looper #(.EVT_MAX(8)) lp (
    .clk_i(clk), .rst_n_i(rst), .tick_i(1'b0), .tick_cnt_i(20'd0),
    .bar_start_i(1'bz), .transport_i(1'b1),
    .live_valid_i(lv), .live_axis_i(4'd0), .live_inc_i(inc),
    .live_vel_i(8'd128), .live_kind_i(2'd0), .live_timbre_i(2'd0),
    .live_vel_valid_i(1'b0), .live_vel_axis_i(4'd0), .live_vel_value_i(8'd0),
    .rec_req_i(rec), .stop_req_i(stop), .play_en_i(1'b0), .clear_req_i(1'b0),
    .evt_cnt_flat_o(cnt), .dump_en_i(dump), .dump_addr_i(addr),
    .dump_data_o(data), .dump_clip_o(clip)
  );
  play_seq ps (.clk_i(clk), .rst_n_i(rst), .tick_i(1'b0), .run_i(1'b1),
    .pos_reset_i(1'b0), .evt_valid_i(feed), .evt_data_i(data),
    .evt_rd_o(rd), .note_valid_o(nv), .note_data_o(nd));
  task check_feedback(input [15:0] a, input [31:0] expected);
    begin
      @(negedge clk); dump=1; addr=a;
      repeat(3) @(negedge clk);
      $display("EXPORT addr=%0d original_inc=%0d wire_inc=%0d clip=%b",a,expected,data[43:23],clip);
      feed=1;
      @(negedge clk); feed=0;
      $display("FEEDBACK valid=%b restored_inc=%0d expected=%0d hz_original=%f hz_restored=%f",nv,feedback_inc,expected,
        expected*48828.125/4294967296.0,feedback_inc*48828.125/4294967296.0);
      if (!nv || feedback_inc !== expected) $display("FAIL: recording-to-score pitch roundtrip");
      else $display("PASS: recording-to-score pitch roundtrip");
    end
  endtask
  initial begin
    repeat(4) @(negedge clk); rst=1; rec=1;
    @(negedge clk); rec=0;
    repeat(3) @(negedge clk);
    inc=32'd2096128; lv=1;
    @(negedge clk); lv=0;
    @(negedge clk); inc=32'd38702809; lv=1;
    @(negedge clk); lv=0;
    @(negedge clk); stop=1;
    @(negedge clk); stop=0;
    repeat(25) @(negedge clk);
    $display("RECORDED cnt=%0d",cnt);
    check_feedback(0,32'd2096128);
    check_feedback(1,32'd38702809);
    $finish;
  end
endmodule
