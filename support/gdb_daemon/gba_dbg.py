#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
"""Control the MiSTer GBA debugger over its JSON port (default 2346)."""

import argparse
import json
import math
import socket
import sys
import time


LINE_MAX = 0x2000 + 256
IO_TIMEOUT = 5.0


def uint(value):
    try:
        n = int(value, 16 if value.lower().startswith("0x") else 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected an integer (decimal or 0x-prefixed)") from exc
    if not 0 <= n < (1 << 64):
        raise argparse.ArgumentTypeError("integer outside the unsigned 64-bit range")
    return n


def seconds(value):
    try:
        n = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected a number of seconds") from exc
    if not math.isfinite(n) or n <= 0:
        raise argparse.ArgumentTypeError("expected a positive, finite duration")
    return n


def hex_data(value):
    try:
        return bytes.fromhex(value).hex()
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected complete hexadecimal bytes") from exc


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="daemon host (default: 127.0.0.1)")
    parser.add_argument("--port", type=uint, default=2346, help="JSON port (default: 2346)")
    commands = parser.add_subparsers(dest="action", required=True)

    def add(name, command, help_text):
        sub = commands.add_parser(name, help=help_text, description=help_text)
        sub.set_defaults(cmd=command)
        return sub

    add("status", "status", "Show the last published run/stop state")
    add("halt", "halt", "Halt the target")
    add("cont", "cont", "Resume the target")
    add("state", "rdstate", "Read detailed CPU, video, IRQ and link state")
    add("regs", "rdregs", "Read r0–r15 and CPSR from the selected core")
    add("trace", "trace", "Read up to 64 retired instructions (target must be halted)")

    for name, command, units in (("step", "step", "instructions"),
                                 ("stepc", "step_cycles", "CPU cycles"),
                                 ("stepf", "step_frames", "frames")):
        add(name, command, f"Run for N {units}").add_argument("n", type=uint, nargs="?", default=1)
    p = add("stepl", "step_line", "Run to a scanline (0–227)")
    p.add_argument("line", type=uint)
    p.add_argument("--hblank", action="store_true", help="stop at HBlank instead of line start")

    p = add("wrreg", "wrreg", "Write a register (16 = CPSR, 17 = SPSR)")
    p.add_argument("reg", type=uint)
    p.add_argument("val", type=uint)
    p = add("rdmem", "rdmem", "Read memory as hexadecimal bytes")
    p.add_argument("addr", type=uint)
    p.add_argument("len", type=uint)
    p = add("wrmem", "wrmem", "Write hexadecimal bytes to memory")
    p.add_argument("addr", type=uint)
    p.add_argument("hex", type=hex_data)

    for name, command, title in (("bp", "setbp", "instruction breakpoint"),
                                  ("wp", "setwp", "data watchpoint")):
        p = add(name, command, f"Configure a hardware {title}")
        p.add_argument("slot", type=uint)
        p.add_argument("addr", type=uint)
        p.add_argument("--core", type=uint, choices=(0, 1), help="core (default: selected core)")
        p.add_argument("--both", action="store_true", help="enable the comparator on both cores")
        p.add_argument("--disable", dest="en", action="store_false", help="disable this slot")
        if name == "wp":
            modes = p.add_mutually_exclusive_group()
            modes.add_argument("--read", dest="access", action="store_const", const="read",
                               help="watch reads only")
            modes.add_argument("--write", dest="access", action="store_const", const="write",
                               help="watch writes only (default)")
            modes.add_argument("--access", dest="access", action="store_const", const="both",
                               help="watch both reads and writes")
            p.set_defaults(access="write")

    add("core", "set_core", "Select core 0 or 1").add_argument("core", type=uint, choices=(0, 1))
    p = add("input", "set_input", "Override pressed-high joypad bits")
    p.add_argument("mask", type=uint)
    p.add_argument("val", type=uint)
    p.add_argument("--core", type=uint, choices=(0, 1), help="core (default: selected core)")
    add("reset", "reset", "Reset the target").add_argument("--halt", action="store_true")
    p = add("screenshot", "screenshot", "Save a 240×160 PPM from unrotated framebuffer slot 0")
    p.add_argument("path", help="new output path on the daemon host, not the client")
    p.add_argument("--core", type=uint, choices=(0, 1), default=0)
    p = add("wait-stop", "status", "Poll until the target reports a stop")
    p.add_argument("--timeout", type=seconds, default=10.0, help="deadline in seconds (default: 10)")
    p.add_argument("--interval", type=seconds, default=0.05, help="poll interval (default: 0.05)")

    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    return args


def request(sock, reader, payload):
    data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(data) >= LINE_MAX:
        raise ValueError("request exceeds the daemon's line limit")
    sock.sendall(data + b"\n")
    line = reader.readline(LINE_MAX)
    if not line.endswith(b"\n"):
        raise ValueError("missing or oversized response from the daemon")
    response = json.loads(line)
    if not isinstance(response, dict) or not isinstance(response.get("ok"), bool):
        raise ValueError("invalid response from the daemon")
    if not response["ok"]:
        raise ValueError(response.get("error", "command failed"))
    return response


def wait_stop(sock, reader, payload, deadline, interval):
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("timed out waiting for the target to halt")
        sock.settimeout(min(IO_TIMEOUT, left))
        response = request(sock, reader, payload)
        if response.get("halted") is True:
            return response
        time.sleep(min(interval, max(0, deadline - time.monotonic())))


def main():
    args = arguments()
    payload = {k: v for k, v in vars(args).items()
               if v is not None and k not in {"host", "port", "action", "access", "timeout", "interval"}}
    if args.action == "wp":
        payload.update(rd=args.access in ("read", "both"), wr=args.access in ("write", "both"))
    waiting = args.action == "wait-stop"
    deadline = time.monotonic() + args.timeout if waiting else None
    try:
        connect_timeout = min(IO_TIMEOUT, args.timeout) if waiting else IO_TIMEOUT
        with socket.create_connection((args.host, args.port), timeout=connect_timeout) as sock:
            with sock.makefile("rb") as reader:
                if waiting:
                    response = wait_stop(sock, reader, payload, deadline, args.interval)
                else:
                    response = request(sock, reader, payload)
        print(json.dumps(response, indent=2))
    except (OSError, ValueError) as exc:
        print(f"gba_dbg: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
