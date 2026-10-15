`timescale 1ns/1ps
// Real UART A/W + ADC SPI + comparator -> module public voice bus + I2S.
// Only peripheral scan timing is accelerated; no internal registers are forced.
module tb_slide_position_e2e;
    localparam integer FRAME_CYC=2500;
    localparam [11:0] REST=12'h7c1, DOWN=12'h4d9, MID=12'h64d;
    localparam [31:0] INC_A=32'h00c51339, INC_B=32'h00d0cb35;
    reg clk=0,rst_n=0,rx=1,pluck=0;
    always #10 clk=~clk;
    wire bck,ws,din,pa,sclk,mosi;
    wire [5:0] cs;
    wire [2:0] miso;
    reg [7:0] mask=0;
    reg [11:0] depth=DOWN;
    top #(.SCOPE_MODE(0),.DEMO_CHORD_ON(1),.DEMO_NOTE_DELAY(200),
          .DEMO_HOLD_CYC(200000),.SOURCE_A_SEL(0),.AUTOTARE_DELAY_CLK(20000),
          .SPAN_WAIT_TIMEOUT_CLK(50000),.SPAN_STABLE_NEED(4),.SPAN_VOTE_N(4)) u_top (
        .clk(clk),.rst_n(rst_n),.uart_rx(rx),.esp_uart_rx_i(1'b1),
        .timbre_btn_i(1'b1),.ctrl_col_i(4'b1111),
        .enc_a_i(1'b1),.enc_b_i(1'b1),.enc_sw_i(1'b1),
        .pedal_sus_i(1'b1),.pedal_loop_rec_i(1'b1),.pedal_loop_play_i(1'b1),
        .pluck_up_i(pluck),.pluck_down_i(1'b0),
        .HP_BCK(bck),.HP_WS(ws),.HP_DIN(din),.PA_EN_n(pa),
        .spi_sclk(sclk),.spi_mosi(mosi),.spi_cs_n(cs),.spi_miso({3'b111,miso}));
    defparam u_top.g_sound.u_adc_farm.CHANNEL_RATE_HZ=20000;
    // Five system clocks per half period leave room for MISO synchronization.
    // Hardware remains at 1 MHz; only this external-model fixture is accelerated.
    defparam u_top.g_sound.u_adc_farm.SCLK_HZ=5000000;
    mcp3208_model #(.IDVAL(REST)) adc_l(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]),
        .ovr_en_i(1'b0),.ovr_val_i(12'd0),.ch_mask_i(mask),.ch_val_i(depth));
    mcp3208_model #(.IDVAL(REST)) adc_r(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]),
        .ovr_en_i(1'b0),.ovr_val_i(12'd0),.ch_mask_i(8'd0),.ch_val_i(12'd0));
    mcp3208_model #(.IDVAL(12'h800)) adc_ctl(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]),
        .ovr_en_i(1'b0),.ovr_val_i(12'd0),.ch_mask_i(8'd0),.ch_val_i(12'd0));
    integer checks=0,voice=-1,k,slides=0,pitches=0,audio_ones=0;
    wire signed [23:0] pcm_l,pcm_r;
    wire pcm_l_valid,pcm_r_valid;
    integer audible_samples=0;
    reg capture_audio=0;
    i2s_rx_model #(.DATA_BITS(16),.JUSTIFY(1),.MSB_DELAY(1)) audio_monitor(
        .clk(clk),.rst_n(rst_n),.bck(bck),.ws(ws),.din(din),
        .sample_l(pcm_l),.sample_r(pcm_r),.valid_l(pcm_l_valid),.valid_r(pcm_r_valid),
        .recon_l(),.recon_r());
    always @(posedge clk) if(capture_audio && pcm_l_valid===1'b1) begin
        if((^pcm_l)===1'bx) $fatal(1,"FAIL: I2S decoded PCM contains unknown bits");
        if(pcm_l!=24'sd0) audible_samples=audible_samples+1;
    end
    // Module public outputs, not note_manager storage arrays.
    wire [31:0] gates=u_top.g_sound.nm_gate;
    wire [127:0] axes=u_top.g_sound.nm_axis;
    wire [1023:0] phases=u_top.g_sound.nm_phase;
    always @(posedge clk) begin
        if(rst_n && u_top.g_sound.ee_slide_v===1'b1) slides=slides+1;
`ifdef LEGACY_AUTORAMP
        // Baseline-only diagnostic. Acceptance uses decoded voice/I2S outputs;
        // this counter merely avoids referencing a port absent before repair.
        if(rst_n && u_top.g_sound.sl_ramp_active===1'b1) pitches=pitches+1;
`else
        if(rst_n && u_top.g_sound.sl_pitch_v===1'b1) pitches=pitches+1;
`endif
    end
    always @(negedge bck) if(rst_n && din===1'b1) audio_ones=audio_ones+1;
    task check(input [8*120-1:0] label_text,input condition);
        begin
            if(condition!==1'b1) $fatal(1,"FAIL: %0s",label_text);
            checks=checks+1;$display("ok: %0s",label_text);
        end
    endtask
    task clocks(input integer n); repeat(n) @(negedge clk); endtask
    task frames(input integer n); clocks(n*FRAME_CYC); endtask
    task command(input [7:0] b);
        integer j;
        begin
            @(negedge clk);rx=0;clocks(100);
            for(j=0;j<8;j=j+1) begin rx=b[j];clocks(100);end
            rx=1;clocks(200);
        end
    endtask
    task keys(input [7:0] m,input [11:0] d);
        begin @(negedge clk);mask=m;depth=d;end
    endtask
    task find_owner;
        begin
            voice=-1;
            for(k=0;k<32;k=k+1)
                if(gates[k]===1'b1 && axes[k*4+:4]===4'd6) voice=k;
            check("pluck allocated original axis 6",voice>=0);
        end
    endtask
    reg [31:0] middle,held;
    integer count_before;
    initial begin
        clocks(10);rst_n=1;
        wait(u_top.g_sound.at_done===1'b1);frames(4);
        command("A");command("W");
        check("UART A selects fretboard",u_top.play_fretboard_mode===1'b1);
        check("UART W enables slide",u_top.slide_on_r===1'b1);
        keys(8'h40,DOWN);frames(6);
        pluck=1;clocks(100);pluck=0;clocks(200);
        find_owner();
        capture_audio=1;
        check("initial pitch uses fretboard axis 6",phases[voice*32+:32]===INC_A);
        keys(8'hc0,MID);frames(8);
        middle=phases[voice*32+:32];
        $display("INFO middle=%08h slides=%0d pitches=%0d",middle,slides,pitches);
        check("real ADC gesture produced a slide",slides>0 && pitches>0);
        check("two middle-depth axes produce an interior pitch",
              middle>INC_A+32'd10000 && middle<INC_B-32'd10000);
        frames(8);held=phases[voice*32+:32];
        check("stationary finger holds pitch rather than auto-ramping",held===middle);
        check("original voice still gated at midpoint",gates[voice]===1'b1);
        keys(8'h80,DOWN);frames(8);
        check("A released but B held keeps original voice",gates[voice]===1'b1);
        check("B-only endpoint is exact",phases[voice*32+:32]===INC_B);
        // Current project is the Console bring-up target: its PA control is
        // intentionally high. Do not apply the different Dock polarity here.
        $display("INFO I2S ones=%0d PA=%b",audio_ones,pa);
        check("real I2S output decodes into nonzero known PCM samples",
              audio_ones>0 && audible_samples>8 && (pa===1'b0 || pa===1'b1));
        keys(8'h00,DOWN);frames(8);
        check("both axes released closes original gate",gates[voice]===1'b0);
        count_before=pitches;command("W");frames(2);
        check("disabled slide emits no pitch transactions",pitches==count_before);
        command("A");command("W");count_before=pitches;frames(2);
        check("keyboard mode blocks slide even with W enabled",
              u_top.play_fretboard_mode===1'b0 && pitches==count_before);
        $display("PASS: real UART/SPI/comparator slide-to-I2S path, %0d checks",checks);
        $finish;
    end
    initial begin clocks(220000);$fatal(1,"FAIL: bounded slide e2e watchdog");end
endmodule
