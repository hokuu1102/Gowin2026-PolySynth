`timescale 1ns/1ps
// Regression at the real top-level score/audio/guide split: a mapped short
// note in the beat's dark interval must still reach the physical LED output.
module tb_top_guide_flash;
reg clk=0,rst_n=0;always #10 clk=~clk;
top #(.PA_ON_AFTER_RESET(0),.DEMO_CHORD_ON(1),.DEMO_NOTE_DELAY(1000000),.DEMO_HOLD_CYC(1000000),.AUTOTARE_DELAY_CLK(100),.SPAN_WAIT_TIMEOUT_CLK(1000),.HEARTBEAT_DIV(100)) dut(
 .clk(clk),.rst_n(rst_n),.timbre_btn_i(1'b1),.spi_miso(6'b111111),.uart_rx(1'b1),.esp_uart_rx_i(1'b1));
reg v=0;reg [63:0] data=0;
integer audio_hits=0,visible=0;reg [7:0] shifted=0,latched=0;
always @(posedge dut.led_clk) shifted={shifted[6:0],dut.led_sdi};
always @(posedge dut.led_le) latched=shifted;
always @(posedge clk)if(rst_n)begin
 if(dut.g_sound.u_seq_arb.score_valid_i && data[10:9]==0)audio_hits=audio_hits+1;
 if(!dut.led_oe_n[0] && latched[2])visible=visible+1;
end
task send(input bit off);begin
 @(negedge clk);data={20'd0,21'd10000,4'd0,8'd100,1'b0,off,2'b00,1'b0,1'b0,5'd3};v=1;
 @(negedge clk);v=0;
end endtask
initial begin
 force dut.ps_note_valid=v;force dut.ps_note_data=data;
 force dut.ee_key_on=16'd0;force dut.play_fretboard_mode=0;force dut.transpose_semi=0;
 force dut.guide_only_r=0;force dut.g_sound.bg_beat=0;
 repeat(10)@(negedge clk);rst_n=1;repeat(50)@(negedge clk);
 dut.g_sound.guide_flash_count=0;
 send(0);repeat(30)@(negedge clk);
 if(audio_hits!=1 || !dut.gl_guide_vis[5])$fatal(1,"FAIL: missing score/guide event before display");
 if(!dut.led_pattern[5])$fatal(1,"FAIL: mapped audible note hidden by dark beat window");
 send(1);repeat(10)@(negedge clk);
 if(dut.gl_guide_vis[5])$fatal(1,"FAIL: OFF did not close original guide ledger");
 if(!dut.led_pattern[5])$fatal(1,"FAIL: short note has no minimum visible pulse");
 repeat(5000)@(negedge clk);
 if(visible==0)$fatal(1,"FAIL: pulse never reaches serial latch plus board OE");
 force dut.ps_new_score=1'b1;repeat(3)@(negedge clk);release dut.ps_new_score;
 repeat(3)@(negedge clk);
 if(dut.led_pattern[5])$fatal(1,"FAIL: new score left a pulse tail");
 send(0);repeat(20)@(negedge clk);
 if(audio_hits!=2 || !dut.led_pattern[5])$fatal(1,"FAIL: replay did not retrigger audio and guide");
 $display("PASS: top dark-phase note, audio acceptance, short-note tail, physical latch/OE, new-score clear and replay");$finish;
end
initial begin #10000000;$fatal(1,"FAIL: timeout");end
endmodule
