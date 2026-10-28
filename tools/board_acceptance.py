"""Explicit operator-driven UART stimulus and lossless board evidence capture.

No serial port is opened by --selftest or --list-ports. This tool records
observations; it never marks a physical function as passed automatically.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import time

ASCII_COMMANDS = "TSXPVMNRLCIBDKFGEJYWAOU"


def fx_frame(variable: int, value: int) -> bytes:
    if not 0x10 <= variable <= 0x18:
        raise ValueError("FX variable must be 0x10..0x18")
    if not 0 <= value <= 254:
        raise ValueError("FX value must be 0..254; 0xFF is the frame terminator")
    return bytes((0x71, variable, value, 0xFF, 0xFF, 0xFF))


def bpm_frame(value: int) -> bytes:
    if not 40 <= value <= 240:
        raise ValueError("BPM must be 40..240")
    return bytes((ord("Q"), 0xA5, value, 0, 0, 0, 0, 0, 0, 0))


def transpose_frame(value: int) -> bytes:
    if not -12 <= value <= 12:
        raise ValueError("Transpose must be -12..12 semitones")
    return bytes((ord("H"), 0xA5, value + 12, 0, 0, 0, 0, 0, 0, 0))


def selftest() -> None:
    assert fx_frame(0x10, 7) == bytes.fromhex("71 10 07 FF FF FF")
    assert fx_frame(0x15, 128) == bytes.fromhex("71 15 80 FF FF FF")
    assert bpm_frame(120) == bytes.fromhex("51 A5 78 00 00 00 00 00 00 00")
    assert transpose_frame(-12) == bytes.fromhex("48 A5 00 00 00 00 00 00 00 00")
    assert transpose_frame(12) == bytes.fromhex("48 A5 18 00 00 00 00 00 00 00")
    for function, arguments in ((fx_frame, (0x0F, 1)), (fx_frame, (0x10, 255)),
                                (bpm_frame, (39,)), (bpm_frame, (241,)),
                                (transpose_frame, (-13,)), (transpose_frame, (13,))):
        try:
            function(*arguments)
        except ValueError:
            pass
        else:
            raise AssertionError((function.__name__, arguments))
    print("PASS board acceptance frame encoding and range checks; no board accessed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--list-ports", action="store_true")
    parser.add_argument("--port", help="FPGA UART adapter, NOT the ESP32 log port")
    parser.add_argument("--baud", type=int, default=500000)
    parser.add_argument("--seconds", type=float, default=2)
    parser.add_argument("--case", default="observation")
    parser.add_argument("--out", type=Path, default=Path(r"D:\ChatGPT\Outputs\FPGA上板记录"))
    command = parser.add_mutually_exclusive_group()
    command.add_argument("--ascii", choices=list(ASCII_COMMANDS))
    command.add_argument("--fx", nargs=2, type=lambda v: int(v, 0), metavar=("VARIABLE", "VALUE"))
    command.add_argument("--bpm", type=int)
    command.add_argument("--transpose", type=int)
    command.add_argument("--fx-status", type=int, choices=range(8))
    command.add_argument("--param-mode", action="store_true")
    command.add_argument("--param-select", type=int, choices=range(8))
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    if args.list_ports:
        from serial.tools import list_ports
        for port in list_ports.comports():
            print(port.device, port.description, port.hwid)
        return 0
    if not args.port:
        parser.error("--port is required to communicate; use --selftest for offline checks")
    if not 0 < args.seconds <= 3600 or args.baud <= 0:
        parser.error("--seconds must be in (0,3600] and baud must be positive")
    try:
        payload = (args.ascii.encode("ascii") if args.ascii else
                   fx_frame(*args.fx) if args.fx else
                   bpm_frame(args.bpm) if args.bpm is not None else
                   transpose_frame(args.transpose) if args.transpose is not None else
                   bytes((ord('Z'), args.fx_status)) if args.fx_status is not None else
                   b'p' if args.param_mode else
                   bytes((ord('o'), args.param_select)) if args.param_select is not None else b"")
    except ValueError as exc:
        parser.error(str(exc))
    import serial
    started = datetime.now().astimezone()
    received = bytearray()
    connection = serial.Serial(port=None, baudrate=args.baud, bytesize=8,
                               parity="N", stopbits=1, timeout=0.05, write_timeout=3)
    connection.dtr = False
    connection.rts = False
    connection.port = args.port
    try:
        connection.open()
        if payload:
            connection.write(payload)
            connection.flush()
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            received.extend(connection.read(min(max(connection.in_waiting, 1), 65536)))
    finally:
        connection.close()
    args.out.mkdir(parents=True, exist_ok=True)
    case = re.sub(r"[^A-Za-z0-9_-]", "_", args.case)[:60] or "observation"
    stem = started.strftime("%Y%m%d-%H%M%S-%f") + f"-{os.getpid()}-{case}"
    binary = args.out / (stem + ".bin")
    record = args.out / (stem + ".json")
    binary.write_bytes(received)
    record.write_text(json.dumps({"schema": 1, "case": args.case,
        "started": started.isoformat(), "port": args.port, "baud": args.baud,
        "tx_hex": payload.hex(" "), "rx_bytes": len(received),
        "raw_file": binary.name, "rx_hex": received.hex(" "),
        "rx_text_lossy": received.decode("utf-8", errors="replace"),
        "physical_acceptance": "OPERATOR_REVIEW_REQUIRED"}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Recorded {len(received)} bytes. Operator review required.\n{record}\n{binary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
