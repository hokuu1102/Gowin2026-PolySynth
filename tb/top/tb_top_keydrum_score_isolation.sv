`timescale 1ns/1ps
// K changes live keyboard interpretation; score metadata must survive unchanged.
module tb_top_keydrum_score_isolation;
  reg clk=0; always #10 clk=~clk;
  reg rst_n=0, rx=1, inject_valid=0;
  reg [63:0] inject_data=0;
  integer seen=0, failures=0, drum_type;
  integer melodic_on=0,melodic_off=0,drum_on=0,drum_off=0;
  top #(.MAIN_UART_BAUD(500000),.SCOPE_MODE(0),.FFT_ENABLE(0),.RIGHT_ADC_ENABLE(0),
    .DEMO_CHORD_ON(1),.DEMO_NOTE_DELAY(10000000),.SOURCE_A_SEL(0),.PA_ON_AFTER_RESET(0)) dut(
    .clk(clk),.rst_n(rst_n),.uart_rx(rx),.esp_uart_rx_i(1'b1),
    .timbre_btn_i(1'b1),.spi_miso(6'b111111),.ctrl_col_i(4'b1111),
    .pluck_up_i(1'b0),.pluck_down_i(1'b0),.pedal_sus_i(1'b1),
    .pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1));
  task send_k;
    integer k;
    reg [7:0] value;
    begin
      value=8'h4b;
      @(negedge clk);rx=0;repeat(100)@(negedge clk);
      for(k=0;k<8;k=k+1)begin rx=value[k];repeat(100)@(negedge clk);end
      rx=1;repeat(150)@(negedge clk);
    end
  endtask
  task score_note(input [1:0] kind,input is_drum,input [1:0] dtype);
    begin
      @(negedge clk);
      inject_data=0;inject_data[22:19]=4'd2;
      inject_data[43:23]=21'd12345;inject_data[18:11]=8'd60;
      inject_data[10:9]=kind;inject_data[5]=is_drum;
      inject_data[8:7]=dtype;inject_data[4:0]=5'd7;inject_valid=1;
      @(negedge clk);inject_valid=0;
      repeat(12)@(negedge clk);
    end
  endtask
  always @(negedge clk) if(rst_n && dut.g_sound.sa_valid) begin
    seen=seen+1;
    if(dut.g_sound.sa_src===3'd1)begin
      if(dut.g_sound.sa_inc!==(32'd12345<<10))$fatal(1,"fixture melodic pitch mismatch");
      if(dut.g_sound.sa_kind==0)melodic_on=melodic_on+1;
      else if(dut.g_sound.sa_kind==1)melodic_off=melodic_off+1;
    end else if(dut.g_sound.sa_src===3'd5)begin
      if(dut.g_sound.sa_kind==0)drum_on=drum_on+1;
      else if(dut.g_sound.sa_kind==1)drum_off=drum_off+1;
    end else $fatal(1,"fixture did not inject a score");
    if(dut.g_sound.src_a_axis!==dut.g_sound.sa_axis ||
       dut.g_sound.src_a_inc!==dut.g_sound.sa_inc ||
       dut.g_sound.src_a_vel!==dut.g_sound.sa_vel ||
       dut.g_sound.src_a_src!==dut.g_sound.sa_src ||
       dut.g_sound.src_a_kind!==dut.g_sound.sa_kind ||
       dut.g_sound.src_a_timbre_valid!==dut.g_sound.sa_timbre_valid ||
       dut.g_sound.src_a_timbre!==dut.g_sound.sa_timbre)begin
      failures=failures+1;
      $display("FAIL: score source=%0d kind=%0d changed with K=%0d: axis=%0d inc=%0d vel=%0d src=%0d timbre=%0d",
        dut.g_sound.sa_src,dut.g_sound.sa_kind,dut.key_drum_r,dut.g_sound.src_a_axis,dut.g_sound.src_a_inc,
        dut.g_sound.src_a_vel,dut.g_sound.src_a_src,dut.g_sound.src_a_timbre);
    end
  end
  initial begin
    force dut.ps_note_valid=inject_valid;
    force dut.ps_note_data=inject_data;
    repeat(20)@(negedge clk);rst_n=1;repeat(40)@(negedge clk);
    score_note(0,0,1);
    send_k();if(dut.key_drum_r!==1)$fatal(1,"UART K did not enable key drums");
    score_note(1,0,1); // K changed between melodic ON and OFF.
    score_note(0,0,1);
    for(drum_type=0;drum_type<4;drum_type=drum_type+1)begin
      score_note(0,1,drum_type[1:0]);
      score_note(1,1,drum_type[1:0]);
    end
    send_k();if(dut.key_drum_r!==0)$fatal(1,"UART K did not disable key drums");
    score_note(1,0,1); // K changed back between melodic ON and OFF.
    if(seen!=12 || melodic_on!=2 || melodic_off!=2 || drum_on!=4 || drum_off!=4)
      $fatal(1,"score coverage mismatch: total=%0d melodic=%0d/%0d drum=%0d/%0d",
        seen,melodic_on,melodic_off,drum_on,drum_off);
    if(failures)$fatal(1,"key-drum mode corrupted %0d score events",failures);
    $display("PASS: UART K preserves melodic ON/OFF and all four native score drum ON/OFF identities and metadata");
    $finish;
  end
  initial begin #1000000;$fatal(1,"score isolation deadline");end
endmodule
