`timescale 1ns/1ps

module tb_adsr;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg         rst_n       = 1'b0;
    reg         sample_tick = 1'b0;
    reg         gate        = 1'b0;
    reg  [7:0]  velocity    = 8'd255;
    wire [15:0] env_level;
    wire        active;

    integer errors = 0;
    integer k;
    reg [15:0] previous;

    adsr #(
        .ATTACK_STEP  (16_384),
        .DECAY_STEP   (8_192),
        .SUSTAIN_Q8   (128),
        .RELEASE_STEP (4_096)
    ) dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .sample_tick_i (sample_tick),
        .gate_i        (gate),
        .velocity_i    (velocity),
        .env_level_o   (env_level),
        .active_o      (active)
    );

    task automatic tick;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
            #1;
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_adsr/tb_adsr.vcd");
        $dumpvars(0, tb_adsr);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        tick();

        if (env_level !== 16'd0 || active !== 1'b0) begin
            $display("FAIL: reset/idle must be level=0 active=0, got %0d/%b", env_level, active);
            errors = errors + 1;
        end

        gate = 1'b1;
        tick();
        if (!active) begin
            $display("FAIL: gate-on must activate the envelope on the next sample tick");
            errors = errors + 1;
        end

        previous = env_level;
        for (k = 0; k < 4; k = k + 1) begin
            tick();
            if (env_level <= previous) begin
                $display("FAIL: attack must rise monotonically, previous=%0d current=%0d", previous, env_level);
                errors = errors + 1;
            end
            previous = env_level;
        end

        if (env_level !== 16'd65280) begin
            $display("FAIL: attack must clamp to the velocity-scaled peak 65280, got %0d", env_level);
            errors = errors + 1;
        end

        previous = env_level;
        for (k = 0; k < 4; k = k + 1) begin
            tick();
            if (env_level >= previous) begin
                $display("FAIL: decay must fall monotonically, previous=%0d current=%0d", previous, env_level);
                errors = errors + 1;
            end
            previous = env_level;
        end

        if (env_level !== 16'd32640) begin
            $display("FAIL: decay must clamp to the 0.5 sustain level 32640, got %0d", env_level);
            errors = errors + 1;
        end

        repeat (3) begin
            tick();
            if (env_level !== 16'd32640) begin
                $display("FAIL: sustain must hold at 32640, got %0d", env_level);
                errors = errors + 1;
            end
        end

        gate = 1'b0;
        tick();
        previous = env_level;
        for (k = 0; k < 8; k = k + 1) begin
            tick();
            if (env_level > previous) begin
                $display("FAIL: release must never rise, previous=%0d current=%0d", previous, env_level);
                errors = errors + 1;
            end
            previous = env_level;
        end

        if (env_level !== 16'd0 || active !== 1'b0) begin
            $display("FAIL: release must finish at level=0 active=0, got %0d/%b", env_level, active);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: ADSR follows attack, decay, sustain, and release through its public interface");
        else
            $display("FAIL: ADSR behavior had %0d error(s)", errors);

        $finish(errors != 0);
    end

    initial begin
        #2_000_000;
        $fatal(1, "FAIL: tb_adsr timeout");
    end

endmodule
