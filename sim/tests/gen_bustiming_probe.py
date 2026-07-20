#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
import subprocess, sys, os

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "bustiming_probe.s")
obj = os.path.join(here, "bustiming_probe.o")
out = os.path.join(here, "bustiming_probe.gba")
logo_donor = os.path.join(here, "LinkCable_basic.gba")

gas = "/opt/homebrew/bin/arm-none-eabi-as"
lld = "/opt/homebrew/bin/arm-none-eabi-ld"
objcopy = "/opt/homebrew/bin/arm-none-eabi-objcopy"

subprocess.run([gas, "-march=armv4t", src, "-o", obj], check=True)
subprocess.run([lld, "-Ttext", "0x08000000", "--entry", "_start", obj,
                "-o", obj + ".elf"], check=True)
subprocess.run([objcopy, "-O", "binary", "--only-section=.text", obj + ".elf",
                out + ".raw"], check=True)

code = bytearray(open(out + ".raw", "rb").read())
os.remove(out + ".raw")
os.remove(obj)
os.remove(obj + ".elf")

logo = open(logo_donor, "rb").read()
code[0x04:0xA0] = logo[0x04:0xA0]
code[0xA0:0xAC] = b"BUSTIMING\0\0\0"
code[0xAC:0xB0] = b"ABTP"
code[0xB0:0xB2] = b"01"
code[0xB2] = 0x96
chk = 0
for i in range(0xA0, 0xBD):
    chk += code[i]
code[0xBD] = (-(chk + 0x19)) & 0xFF

code += b"\xff" * (0x40000 - len(code))
open(out, "wb").write(code)
print(f"{out}: {len(code)} bytes")
