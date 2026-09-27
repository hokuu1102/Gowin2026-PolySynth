`timescale 1ns/1ps

// T15 public seam: two asynchronous comparator outputs become one clean pluck
// event.  UP must win when both synchronized edges occur in the same cycle.
module tb_async_pluck_capture;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg up_async = 1'b0;
    reg down_async = 1'b0;
    wire pluck_valid;
    wire pluck_up;
    integer errors = 0;
    integer event_n = 0;
    reg event_dir [0:7];

    always #10 clk = ~clk;

    async_pluck_capture #(.REFRACT_CYC(10)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .pluck_up_async_i(up_async), .pluck_down_async_i(down_async),
        .pluck_valid_o(pluck_valid), .pluck_up_o(pluck_up)
    );

    task chk;
        input [8*96-1:0] name;
        input cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task pulse_up;
        begin
            @(negedge clk); up_async = 1'b1;
            @(negedge clk); up_async = 1'b0;
        end
    endtask

    task pulse_down;
        begin
            @(negedge clk); down_async = 1'b1;
            @(negedge clk); down_async = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && pluck_valid) begin
            event_dir[event_n] = pluck_up;
            event_n = event_n + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        pulse_up;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chk("UP edge produces exactly one pluck", event_n == 1);
        chk("UP edge is labelled UP", event_dir[0] == 1'b1);

        // Repeated comparator chatter during refractory time must not retrigger.
        pulse_down;
        repeat (2) @(posedge clk);
        @(negedge clk);
        chk("refractory suppresses a second immediate edge", event_n == 1);

        // Wait beyond both the synchronizer latency and the full refractory
        // interval before asking for a fresh edge.
        repeat (12) @(posedge clk);
        pulse_down;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chk("edge is accepted again after refractory", event_n == 2);
        chk("DOWN edge is labelled DOWN", event_dir[1] == 1'b0);

        repeat (12) @(posedge clk);
        @(negedge clk); up_async = 1'b1; down_async = 1'b1;
        @(negedge clk); up_async = 1'b0; down_async = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chk("simultaneous UP and DOWN create one event", event_n == 3);
        chk("simultaneous UP and DOWN chooses UP", event_dir[2] == 1'b1);

        if (errors == 0) $display("PASS: async pluck capture synchronizes edges, prioritizes UP, and applies refractory");
        else $fatal(1, "FAIL: async_pluck_capture has %0d error(s)", errors);
        $finish;
    end

    initial begin #5000; $fatal(1, "FAIL: tb_async_pluck_capture timeout"); end
endmodule
