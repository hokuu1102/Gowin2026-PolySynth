#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cross-check: the Python model in evt2uart.py vs the real RTL (evt_uart_rx.v).

The Python model is only trustworthy if it agrees with the hardware.  Feed the
SAME byte stream to both and require identical event lists.

Method: generate a byte stream in Python, dump it as a Verilog-readable hex
file, run the real RTL through iverilog feeding bytes at the UART rate, dump the
RTL's events, then compare.

Because driving real baud takes wall-clock-ish sim time, we feed the DUT's
`rx_done`/`rx_data` directly (the framing layer is what we are comparing, and
uart_rx.v is covered by its own tb).
"""
import io
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import evt2uart as E   # noqa: E402

BUILD = os.path.join("build", "sim", "evt_uart_rx")
os.makedirs(BUILD, exist_ok=True)


def make_stream():
    """A stream that exercises the nasty cases, then random traffic."""
    words = []
    # 1. plain
    words.append(0x0123456789ABCDEF)
    # 2. payload full of 0xA5 (but not 9/9)
    words.append(0xA5A5A5A5A5A5A5A4)
    # 3. 0xA5 in the middle only
    words.append(0x00A500A500A500A5)
    # 4. extreme values
    words.append(0xFFFFFFFFFFFFFFFF)
    words.append(0x0000000000000000)
    words.append(0x8000000000000001)
    # 5. random
    rnd = random.Random(0xC0FFEE)
    for _ in range(300):
        w = rnd.getrandbits(64)
        if w == 0xA5A5A5A5A5A5A5A5:
            continue                      # that exact word would be a reset frame
        words.append(w)
    return words


def main():
    words = make_stream()
    stream = b"".join(E.pack_frame(w) for w in words)
    reset = E.build_reset()
    full = reset + stream

    # ---- Python model ----
    py_events, py_stats = E.unpack_stream(full)

    # ---- dump the byte stream for the RTL testbench ----
    hexpath = os.path.join(BUILD, "stream.hex")
    with io.open(hexpath, "w", encoding="ascii", newline="\n") as f:
        for b in full:
            f.write("%02x\n" % b)

    # ---- RTL ----
    tb = r"""
`timescale 1ns/1ps
module tb_cross;
    reg clk = 0;  always #10 clk = ~clk;
    reg rst_n = 0;
    reg [7:0] mem [0:1048576];
    integer nbytes, i;

    reg        done = 0;
    reg [7:0]  rx_data;
    reg        rx_done;

    wire        evt_valid;
    wire [63:0] evt_data;
    wire [15:0] frame_cnt, resync_cnt, hdr_err_cnt, drop_cnt;
    wire [3:0]  idx;
    wire        synced;

    evt_uart_rx #(
        .CLK_HZ(50000000), .BAUD(115200), .GAP_BYTES(16), .HEADER(8'hA5)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .rx_done_i(rx_done), .rx_data_i(rx_data),
        .evt_valid_o(evt_valid), .evt_data_o(evt_data),
        .frame_cnt_o(frame_cnt), .resync_cnt_o(resync_cnt),
        .hdr_err_cnt_o(hdr_err_cnt), .drop_cnt_o(drop_cnt),
        .idx_o(idx), .synced_o(synced)
    );

    integer fd;
    initial begin
        fd = $fopen("build/sim/evt_uart_rx/rtl_events.hex", "w");
        $readmemh("build/sim/evt_uart_rx/stream.hex", mem);
        nbytes = 0;
        // count bytes
        for (i = 0; i < 1048576; i = i + 1) begin
            if (mem[i] !== 8'hxx) nbytes = nbytes + 1;
            else i = 1048576;
        end
        $display("RTL_CROSS bytes=%0d", nbytes);

        rx_data = 8'h00; rx_done = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5)  @(posedge clk);

        for (i = 0; i < nbytes; i = i + 1) begin
            @(negedge clk);
            rx_data = mem[i];
            rx_done = 1'b1;
            @(posedge clk);          // DUT samples rx_done=1 on this edge
            @(negedge clk);          // the registered pulse is visible HERE
            if (evt_valid) $fdisplay(fd, "%016x", evt_data);
            rx_done = 1'b0;
            @(posedge clk);
        end
        @(posedge clk); #1;
        $display("RTL_CROSS frames=%0d drop=%0d hdrerr=%0d resync=%0d",
                 frame_cnt, drop_cnt, hdr_err_cnt, resync_cnt);
        $fclose(fd);
        $finish;
    end
endmodule
"""
    tbpath = os.path.join(BUILD, "tb_cross.sv")
    with io.open(tbpath, "w", encoding="ascii", newline="\n") as f:
        f.write(tb)

    vvp = os.path.join(BUILD, "cross.vvp")
    cp = subprocess.run(["iverilog", "-g2005-sv", "-o", vvp,
                         os.path.join("rtl", "w3c", "evt_uart_rx.v"), tbpath],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        print("COMPILE FAILED:\n%s" % cp.stderr[:900])
        return 2
    rp = subprocess.run(["vvp", vvp], capture_output=True, text=True)
    line = [l for l in rp.stdout.splitlines() if l.startswith("RTL_CROSS frames")]
    print("  " + (line[0] if line else "(no summary)"))

    with io.open(os.path.join(BUILD, "rtl_events.hex"), encoding="utf-8") as f:
        rtl_events = [int(s.strip(), 16) for s in f if s.strip()]

    print()
    print("  python model : %d events" % len(py_events))
    print("  real RTL     : %d events" % len(rtl_events))
    print("  python drops : %d" % py_stats["dropped"])

    if py_events == rtl_events:
        print()
        print("  MATCH -- the Python model reproduces the RTL exactly")
        return 0
    print()
    print("  MISMATCH!")
    for i in range(max(len(py_events), len(rtl_events))):
        a = py_events[i] if i < len(py_events) else None
        b = rtl_events[i] if i < len(rtl_events) else None
        if a != b:
            print("    first diff at %d: python=%s rtl=%s"
                  % (i, "None" if a is None else "%016X" % a,
                     "None" if b is None else "%016X" % b))
            break
    return 1


def _selftest():
    """Entry point used by tools/selftest_all.py (`--selftest`)."""
    rc = main()
    if rc == 0:
        print("PASS: evt2uart.py's Python framing model reproduces evt_uart_rx.v "
              "byte-for-byte on adversarial input")
    else:
        print("FAIL: the Python model and the RTL disagree")
    return rc


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    sys.exit(main())
