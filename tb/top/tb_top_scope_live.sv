`timescale 1ns/1ps
// Real UART -> command parser -> display input boundary. Check that E never
// removes audio sample commits from the HDMI module's public input port.
module tb_top_scope_live;
    reg clk=0,rst_n=0,rx=1;
    always #10 clk=~clk;
    wire sclk,mosi;
    wire [5:0] cs,miso;
    integer commits=0,errors=0;
    top dut(.clk(clk),.rst_n(rst_n),.uart_rx(rx),
        .timbre_btn_i(1'b1),.pluck_up_i(1'b0),.pluck_down_i(1'b0),
        .spi_sclk(sclk),.spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso));
    mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3]=3'b111;
    always @(posedge clk) if(rst_n && dut.u_hdmi.valid_i) commits=commits+1;
    task send_byte(input [7:0] cmd);
        integer bit_index;
        begin
            @(negedge clk);rx=0;repeat(100) @(negedge clk);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                rx=cmd[bit_index];repeat(100) @(negedge clk);
            end
            rx=1;repeat(150) @(negedge clk);
        end
    endtask
    task check_stream;
        begin
            commits=0;repeat(8192) @(negedge clk);
            if(commits<7 || commits>9) begin
                $display("FAIL: live HDMI input must receive one commit/frame after E, got=%0d",commits);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(12) @(negedge clk);rst_n=1;
        repeat(2048) @(negedge clk);check_stream;
        send_byte(8'h45);
        if(dut.u_hdmi.SCOPE_MODE!==1'b0 || dut.u_hdmi.FFT_MODE!==1'b1) begin
            $display("FAIL: first real UART E from default XY did not select FFT at HDMI input");
            errors=errors+1;
        end
        check_stream;
        send_byte(8'h45);
        if(dut.u_hdmi.SCOPE_MODE!==1'b0 || dut.u_hdmi.FFT_MODE!==1'b0) begin
            $display("FAIL: second real UART E did not select waveform at HDMI input");
            errors=errors+1;
        end
        check_stream;
        send_byte(8'h45);
        if(dut.u_hdmi.SCOPE_MODE!==1'b1 || dut.u_hdmi.FFT_MODE!==1'b0)
            $fatal(1,"FAIL: third real UART E did not return to XY at HDMI input");
        check_stream;
        send_byte(8'h51); // Q arms BPM, never switches the renderer.
        if(dut.u_hdmi.SCOPE_MODE!==1'b1 || dut.u_hdmi.FFT_MODE!==1'b0)
            $fatal(1,"FAIL: Q BPM command switched scope");
        send_byte(8'hA5);
        send_byte(8'd140);
        repeat(7) send_byte(8'd0);
        //  ⭐⭐ 2026-10-14：⭐ **手动 BPM 改成【对齐小节线】**（⭐ 用户要求）✅
        //     ⇒ ⭐ 载荷到达时**只挂起**，⛔ 不许立刻改 `play_seq.tick_inc_o` ✅
        //     📌 **分工**：⭐ "挂起 ⇒ 到小节线真的生效" 由**聚焦 tb** `tb_bpm_bar_quant`
        //        穷举验证（⭐ 22 条判据，⭐ 含"`set_i` 单独到达不许装载"这条核心 ✅）
        //        ⭐ 而**本 tb 负责证明【顶层接线】**：⭐ 真 UART 的载荷确实进了对齐器 ✅
        //     ⚠️ **为什么这里⛔ 不等一个小节**：⭐ 120 BPM 一小节 ≈ **100M clk ≈ 2 秒**，
        //        而本 tb 的总预算只有 **2 ms**（`#2000000`）⇒ ⚠️ 差 **1000 倍** ✅
        //        ⇒ ⭐ 硬等会把"接线正确"与"等够时间"混成一件事，⭐ 反而更难定位 ✅
        //     📌 复位默认 `tick_inc` = `TICK_INC_DEFAULT` = 164927（= 120 BPM）✅
        if(dut.g_sound.u_play_seq.tick_inc_o!==32'd164927)
            $fatal(1,"FAIL: manual Q must NOT change the tempo immediately (bar-aligned since 2026-10-14)");
        if(dut.g_sound.u_bpm_bar_quant.pending_o!==1'b1)
            $fatal(1,"FAIL: real UART Q payload did not reach the bar aligner (pending_o)");
        if(dut.u_hdmi.SCOPE_MODE!==1'b1 || dut.u_hdmi.FFT_MODE!==1'b0)
            $fatal(1,"FAIL: framed BPM payload switched scope");
        send_byte(8'h57);
        if(dut.slide_on_r!==1'b1) $fatal(1,"FAIL: real UART W did not enable slide");
        send_byte(8'h57);
        if(dut.slide_on_r!==1'b0) $fatal(1,"FAIL: real UART W did not disable slide");
        check_stream;
        if(errors) $fatal(1,"FAIL: E interrupted live audio display input");
        $display("PASS: real UART E three-mode live stream, Q framed BPM=140 and W slide toggle coexist");
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: top scope stream timeout");end
endmodule
