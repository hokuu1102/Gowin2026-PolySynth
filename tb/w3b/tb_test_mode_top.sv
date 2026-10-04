`timescale 1ns/1ps
// End-to-end physical Test Mode acceptance:
// PC UART ('M') -> uart_rx -> calib_cmd -> top state -> test_mode_ctrl
// -> envelope/oscillator inputs.  This intentionally tests the actual top,
// not a duplicate test-only state machine.
module tb_test_mode_top;
    localparam integer BIT_CYC = 100;  // top UART: 500 kbaud @ 50 MHz

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg uart_rx = 1'b1;
    always #10 clk = ~clk;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN_n, led_heartbeat;
    wire I2S2_BCK, I2S2_LRCK, I2S2_DIN;

    top #(
        .PA_ON_AFTER_RESET     (0),
        // ⭐⭐ 2026-10-04（合并 main 后）：⭐ **必须显式传 `TEST_MODE_EN(1)`**
        //   🔴 为什么：⭐ `top.v` 的**交付默认值**现在是 **`0`**（正式码流 —— 整条 Test Mode
        //      通路**不进网表**，⭐ 见 `top.v` 的 `TEST_MODE_EN` 说明 ＋
        //      `evidence/h5/testmode1-18p181-55p198/README.md`）
        //   ⭐ 而本 tb 的**全部判据**都建立在"**Test Mode 真的存在**"之上
        //      （⭐ 它用**物理 UART 的 `M` 命令**去驱动 4/8/16/32 档 ✅）
        //   ⇒ ⭐ 不传它 ⇒ 本 tb 会**整片假红**（⚠️ 不是功能坏了，⭐ 是配置不对）
        //   📌 **两个配置都仍被覆盖**：
        //      · `TEST_MODE_EN = 0`（⭐ 交付档）⇒ 由**其它所有顶层 tb** 覆盖
        //        （`tb_top_m0` / `tb_top_sound` / `tb_top_led_strip` / … 都用默认值 ✅）
        //      · `TEST_MODE_EN = 1`（⭐ 诊断档）⇒ ⭐ **由本 tb 覆盖** ✅
        //   ⛔ 本改动**只改配置、⛔ 不改任何判据**（⭐ 5 条判据一字未动 ✅）
        .TEST_MODE_EN          (1),
        .DEMO_CHORD_ON         (1), // instantiate the real sound chain
        .DEMO_NOTE_DELAY       (1_000_000), // keep demo notes out of this test
        .DEMO_HOLD_CYC         (1_000_000),
        .AUTOTARE_DELAY_CLK    (100),
        .SPAN_WAIT_TIMEOUT_CLK (1_000),
        .HEARTBEAT_DIV         (100)
    ) dut (
        .clk(clk), .rst_n(rst_n), .timbre_btn_i(1'b1),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN_n(PA_EN_n),
        .I2S2_BCK(I2S2_BCK), .I2S2_LRCK(I2S2_LRCK), .I2S2_DIN(I2S2_DIN),
        .led_heartbeat(led_heartbeat),
        .spi_miso(6'b111111), .spi_sclk(), .spi_mosi(), .spi_cs_n(),
        .led_sdi(), .led_clk(), .led_le(), .led_oe_n(),
        .uart_rx(uart_rx), .uart_tx()
    );

    integer errors = 0;
    integer i;
    integer gate_count;
    integer lane_count;

    task chk;
        input [8*100-1:0] name;
        input condition;
        begin
            if (condition) $display("  ok  : %0s", name);
            else begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    task pc_send_byte;
        input [7:0] b;
        integer bit_i;
        begin
            // Extra idle time lets the synchronizer settle before each start bit.
            repeat (4) @(posedge clk);
            uart_rx = 1'b0;
            repeat (BIT_CYC) @(posedge clk);
            for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
                uart_rx = b[bit_i];
                repeat (BIT_CYC) @(posedge clk);
            end
            uart_rx = 1'b1;
            repeat (BIT_CYC + 40) @(posedge clk);
        end
    endtask

    task count_test_inputs;
        begin
            gate_count = 0;
            lane_count = 0;
            for (i = 0; i < 32; i = i + 1) begin
                if (dut.g_sound.tm_gate[i] === 1'b1) gate_count = gate_count + 1;
                if (dut.g_sound.tm_lane_active[i*2] === 1'b1) lane_count = lane_count + 1;
            end
        end
    endtask

    task check_mode;
        input expected_enable;
        input [1:0] expected_code;
        input integer expected_n;
        begin
            repeat (8) @(posedge clk);
            count_test_inputs();
            chk("top Test Mode enable state", dut.g_sound.tm_enable_r === expected_enable);
            chk("top Test Mode count code", dut.g_sound.tm_n_code_r === expected_code);
            chk("test_mode_ctrl active count", dut.g_sound.tm_active_n === expected_n);
            chk("selected test voices equal active count", gate_count == expected_n);
            chk("one oscillator lane per selected voice", lane_count == expected_n);
            // This is the critical physical wiring assertion: controller gates
            // must reach the real envelope bank, not merely a debug net.
            chk("Test Mode gate mux reaches envelope bank",
                expected_enable ?
                    (dut.g_sound.u_envelope_bank.gate_i === dut.g_sound.tm_gate) :
                    (dut.g_sound.u_envelope_bank.gate_i === dut.g_sound.nm_gate));
            chk("Test Mode velocity mux reaches envelope bank",
                expected_enable ?
                    (dut.g_sound.u_envelope_bank.velocity_i === dut.g_sound.tm_vel) :
                    (dut.g_sound.u_envelope_bank.velocity_i === dut.g_sound.nm_vel));
            chk("controller lanes reach oscillator bank",
                dut.g_sound.u_oscillator_bank.test_lane_active_i === dut.g_sound.tm_lane_active);
        end
    endtask

    initial begin
        $display("=== tb_test_mode_top (physical UART integration) ===");
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        check_mode(1'b0, 2'b00, 0);

        // A complete event frame containing 'M' is payload, never a command.
        pc_send_byte(8'hA5);
        pc_send_byte(8'h4D);
        for (i = 0; i < 7; i = i + 1) pc_send_byte(8'h00);
        check_mode(1'b0, 2'b00, 0);

        pc_send_byte(8'h4D); check_mode(1'b1, 2'b00, 4);
        pc_send_byte(8'h4D); check_mode(1'b1, 2'b01, 8);
        pc_send_byte(8'h4D); check_mode(1'b1, 2'b10, 16);
        pc_send_byte(8'h4D); check_mode(1'b1, 2'b11, 32);
        pc_send_byte(8'h4D); check_mode(1'b0, 2'b00, 0);

        if (errors == 0)
            $display("PASS: physical UART M command controls 4/8/16/32 Test Mode in top");
        else
            $fatal(1, "FAIL: physical Test Mode integration has %0d error(s)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "FAIL: tb_test_mode_top timeout");
    end
endmodule
