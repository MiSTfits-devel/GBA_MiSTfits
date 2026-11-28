# SPDX-License-Identifier: GPL-3.0-or-later

"""Drive the production poll loop through a PTY and local UDP/TCP sockets."""

import os
import pty
import re
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time
import termios


def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def read_exact(source, count):
    read = source.recv if isinstance(source, socket.socket) else lambda n: os.read(source, n)
    deadline = time.monotonic() + 1
    data = b""
    while len(data) < count:
        if not select.select([source], [], [], max(0, deadline - time.monotonic()))[0]:
            raise AssertionError(f"timed out receiving {count} bytes (got {data.hex()})")
        chunk = read(count - len(data))
        assert chunk, "end of stream"
        data += chunk
    return data


def expect_frame(master, frame_type, cmd, payload=b""):
    expect = bytes((frame_type, cmd, len(payload) // 4)) + payload
    got = read_exact(master, len(expect))
    assert got == expect, f"expected {expect.hex()}, got {got.hex()}"


def connect(port):
    deadline = time.monotonic() + 1
    while True:
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=1)
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.005)


def expect_logs(log, markers):
    deadline = time.monotonic() + 1
    while True:
        # Never move the shared file offset of the daemon's stderr.
        output = os.pread(log.fileno(), os.fstat(log.fileno()).st_size, 0).decode()
        if all(marker in output for marker in markers):
            return output
        assert time.monotonic() < deadline, output
        time.sleep(0.005)


def blocked_stderr(daemon_path):
    master, slave = pty.openpty()
    read_fd, write_fd = os.pipe()
    try:
        # Fill the pipe before spawning the daemon and leave it undrained.
        # Turn blocking back on for the daemon so its writer really stalls.
        os.set_blocking(write_fd, False)
        for size in (4096, 1):
            while True:
                try:
                    os.write(write_fd, b" " * size)
                except BlockingIOError:
                    break
        os.set_blocking(write_fd, True)

        tcp_port = free_port(socket.SOCK_STREAM)
        with subprocess.Popen(
            [daemon_path, "-d", os.ttyname(slave), "-L", "-v",
             "-p", str(free_port(socket.SOCK_DGRAM)), "-N", str(tcp_port)],
            stderr=write_fd
        ) as daemon:
            try:
                with connect(tcp_port) as tcp:
                    # Wrong impl magic still negotiates; its warning must
                    # likewise not write from the UART/netplay loop.
                    tcp.sendall(struct.pack("!6I", 0x52414E50, 0, 0, 7, 5, 0))
                    assert read_exact(tcp, 24)[:4] == b"RANP"
                    # Two log records per HELLO, enough to overflow the ring
                    # regardless of whether the writer has been scheduled.
                    for _ in range(256):
                        os.write(master, b"\x01\x10\x00")
                        expect_frame(master, 2, 0x90)

                output = bytearray()
                deadline = time.monotonic() + 1
                while not re.search(rb"rfu: dropped [1-9][0-9]* log records\n", output):
                    assert select.select([read_fd], [], [], max(0, deadline - time.monotonic()))[0], (
                        "writer never reported the log records dropped while stderr was blocked"
                    )
                    output.extend(os.read(read_fd, 4096))
            finally:
                daemon.kill()
    finally:
        for fd in (master, slave, read_fd, write_fd):
            os.close(fd)


def exercise(master, udp, tcp, udp_port):
    # Noise, an event, and a REQ with both its header and body fragmented.
    os.write(master, b"\xff\x02\xfe\x04\x01\x00\x01")
    time.sleep(0.002)
    os.write(master, b"\x17\x01\x20")
    time.sleep(0.002)
    # Reject malformed event length; its last byte is a new REQ marker.
    # Decode several valid frames from the same increment of input.
    os.write(master, b"\x04\x00\x00\x04\x7f\x01\x12\x00\x01\x19\x00")
    expect_frame(master, 2, 0x97)
    expect_frame(master, 2, 0x92, struct.pack("<I", 0x00830117))
    expect_frame(master, 2, 0x99)

    # Abandon a frame mid-body, as if bytes were dropped by the UART.
    # The daemon still has to serve both sockets before the next UART frame.
    os.write(master, b"\x01\x16\x06\x33")
    time.sleep(0.005)
    udp.sendto(struct.pack("!4I", 0x52465531, 1, 0, 0), ("127.0.0.1", udp_port))
    tcp.sendall(struct.pack("!6I", 0x52414E50, 0, 0, 7, 5, 0))
    assert read_exact(tcp, 24)[:4] == b"RANP", "TCP handler did not answer"
    deadline = time.monotonic() + 1
    while True:
        udp.settimeout(max(0.001, deadline - time.monotonic()))
        data = udp.recv(104)
        if data[:8] == b"RFU1\x00\x00\x00\x02":
            break  # CONNECT_ACK; ignore the earlier host broadcast
        assert time.monotonic() < deadline, "UDP handler did not answer"

    time.sleep(0.06)
    os.write(master, b"\x01\x11\x00")
    expect_frame(master, 2, 0x91, struct.pack("<I", 0xFF))

    # A missing length byte must also time out. Verify notifications still
    # reach the FPGA and carry the empty active/ACKed bitmaps after disconnect.
    os.write(master, b"\x01\x17")
    time.sleep(0.06)
    os.write(master, b"\x01\x30\x01\x01\x00\x00\x00\x01\x27\x00\x04\x02\x00")
    expect_frame(master, 2, 0xB0)
    expect_frame(master, 2, 0xA7)
    expect_frame(master, 3, 0x28, bytes(4))


def main():
    udp_port = free_port(socket.SOCK_DGRAM)
    tcp_port = free_port(socket.SOCK_STREAM)
    master, slave = pty.openpty()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp, tempfile.TemporaryFile() as log:
            udp.bind(("127.0.0.1", 0))
            peer = f"127.0.0.1:{udp.getsockname()[1]}"
            daemon = subprocess.Popen(
                [sys.argv[1], "-d", os.ttyname(slave), "-L", "-v", "-P", peer,
                 "-p", str(udp_port), "-N", str(tcp_port)], stderr=log
            )
            try:
                with connect(tcp_port) as tcp:
                    rate = getattr(termios, "B2000000", termios.B115200)
                    assert termios.tcgetattr(slave)[4:6] == [rate, rate]
                    exercise(master, udp, tcp, udp_port)
                output = expect_logs(log, [
                    "uart=req cmd=0x17 words=1 first=00000420",
                    "drop=timeout have=4 need=27",
                    "drop=timeout have=2 need=3",
                    "cmd=0x28 words=1 param=0x00000000 active=0x0 acked=0x0",
                ])
                timestamps = [int(ms) for ms in re.findall(r"^rfu: t_ms=(\d+) ", output, re.M)]
                assert timestamps and timestamps == sorted(timestamps), output
            finally:
                daemon.kill()
                daemon.wait()
    finally:
        os.close(master)
        os.close(slave)
    blocked_stderr(sys.argv[1])
    print("UART PTY, UDP/TCP service, and blocked stderr logging passed")


if __name__ == "__main__":
    main()
