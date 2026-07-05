#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Build sim/tests/ewram_alias_test.gba from ewram_alias_test.s:
# assemble (clang arm-none-eabi), extract .text, patch a valid GBA header
# (Nintendo logo copied from LinkCable_basic.gba, complement checksum), pad
# to 256KB so the alias probe at ROM+128KB reads deterministic 0xFF data.
import subprocess, sys, os

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "ewram_alias_test.s")
obj = os.path.join(here, "ewram_alias_test.o")
out = os.path.join(here, "ewram_alias_test.gba")
logo_donor = os.path.join(here, "LinkCable_basic.gba")

tool = "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
clang = os.path.join(tool, "clang")
objcopy = "/opt/homebrew/bin/arm-none-eabi-objcopy"

lld = "/opt/homebrew/bin/arm-none-eabi-ld"
subprocess.run([clang, "--target=arm-none-eabi", "-march=armv4t",
                "-c", src, "-o", obj], check=True)
subprocess.run([lld, "-Ttext", "0x0", "--entry", "_start", obj,
                "-o", obj + ".elf"], check=True)
subprocess.run([objcopy, "-O", "binary", "--only-section=.text", obj + ".elf",
                out + ".raw"], check=True)

code = bytearray(open(out + ".raw", "rb").read())
os.remove(out + ".raw")
os.remove(obj)
os.remove(obj + ".elf")

donor = open(logo_donor, "rb").read()
code[0x04:0xA0] = donor[0x04:0xA0]          # Nintendo logo
title = b"EWRAMALIAS"
code[0xA0:0xA0 + len(title)] = title        # title (rest stays 0)
code[0xAC:0xB0] = b"EWAT"                   # game code
code[0xB0:0xB2] = b"01"                     # maker
code[0xB2] = 0x96                           # fixed
chk = 0
for i in range(0xA0, 0xBD):
    chk = (chk - code[i]) & 0xFF
code[0xBD] = (chk - 0x19) & 0xFF            # complement check

code += b"\xff" * (0x40000 - len(code))     # pad to 256KB
open(out, "wb").write(code)
print(f"{out}: {len(code)} bytes, entry {code[3]:02x}{code[2]:02x}{code[1]:02x}{code[0]:02x}")
