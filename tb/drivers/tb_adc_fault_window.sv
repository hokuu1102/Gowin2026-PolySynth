`timescale 1ns/1ps
module tb_adc_fault_window;
    reg clk=0, rst_n=0, stuck=0;
    reg startup_rail=1;
    always #10 clk=~clk;
    wire [2:0] cs,sck,mosi,miso,fault,ch;
    wire valid,done;
    wire [35:0] data;
    integer frames=0, errors=0;
    wire [0:0] startup_cs,startup_sck,startup_mosi,startup_miso,startup_fault;
    adc_farm #(.N_ADC(1), .FAULT_STARTUP_MS(10)) startup_dut (
        .clk(clk),.rst_n(rst_n),.enable(1'b1),
        .adc_cs_n(startup_cs),.adc_sclk(startup_sck),.adc_mosi(startup_mosi),
        .adc_miso(startup_miso),.fault(startup_fault));
    mcp3208_model #(.IDVAL(12'h200)) startup_adc (
        .cs_n(startup_cs[0]),.sclk(startup_sck[0]),.mosi(startup_mosi[0]),
        .miso(startup_miso[0]),.ovr_en_i(startup_rail),.ovr_val_i(12'd0));
    adc_farm #(.N_ADC(3), .FAULT_STARTUP_MS(0)) dut (
        .clk(clk),.rst_n(rst_n),.enable(1'b1),
        .adc_cs_n(cs),.adc_sclk(sck),.adc_mosi(mosi),.adc_miso(miso),
        .sample_valid(valid),.sample_ch(ch),.sample_data_packed(data),
        .frame_done(done),.fault(fault));
    mcp3208_model #(.IDVAL(12'h000)) adc0 (
        .cs_n(cs[0]),.sclk(sck[0]),.mosi(mosi[0]),.miso(miso[0]),
        .ovr_en_i(stuck),.ovr_val_i(12'd0));
    mcp3208_model #(.IDVAL(12'h400)) adc1 (
        .cs_n(cs[1]),.sclk(sck[1]),.mosi(mosi[1]),.miso(miso[1]),
        .ovr_en_i(stuck),.ovr_val_i(12'hfff));
    mcp3208_model #(.IDVAL(12'hfff)) adc2 (
        .cs_n(cs[2]),.sclk(sck[2]),.mosi(mosi[2]),.miso(miso[2]));
    always @(posedge clk) if(rst_n && done) frames=frames+1;
    initial begin
        repeat(10) @(negedge clk);rst_n=1;
        wait(frames>=18);repeat(10) @(negedge clk);
        if(fault!==0) begin
            $display("FAIL: healthy ADC with legal CH0=0/FFF was declared dead: fault=%b",fault);
            errors=errors+1;
        end
        if(startup_fault!==0) begin
            $display("FAIL: analogue startup rails must not latch a fault before settling window");
            errors=errors+1;
        end
        startup_rail=0;
        stuck=1;
        wait(frames>=38);repeat(10) @(negedge clk);
        if(fault!==3'b011) begin
            $display("FAIL: all-channel zero/full-scale suspicion should affect only chips0/1: fault=%b",fault);
            errors=errors+1;
        end
        if(startup_fault!==0) begin
            $display("FAIL: recovered ADC retained a startup false alarm");
            errors=errors+1;
        end
        if(errors) $fatal(1,"FAIL: ADC fault window errors=%0d",errors);
        $display("PASS: legal CH0 endpoint is accepted; sustained all-channel endpoint is reported separately");
        $finish;
    end
    initial begin #22000000;$fatal(1,"FAIL: ADC fault test timeout");end
endmodule
