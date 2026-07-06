#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# CPU-level 2P link-cable confidence check with nvc (https://github.com/nickg/nvc)
#
# Boots the real homebrew demo sim/tests/LinkCable_basic.gba on two gba_top
# cores wired cable-to-cable and decodes the Multi-Player SIO frames on the
# shared wire to confirm real bidirectional communication.
#
# The default BIOS ("embedded") is the open-source replacement already baked
# into rtl/gba_bios.vhd, with its 120-frame logo-display wait shrunk to one
# frame -- a real BIOS image runs the full ~2s intro, which is hours of sim
# wall time. Point GBA_BIOS at a 16KB image to simulate a specific BIOS.
#
#   brew install nvc
#   sim/run_link2p_cpu_tb.sh
#   GBA_BIOS=~/ROMs/GBA/gba_bios.bin STOP_TIME=3sec sim/run_link2p_cpu_tb.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GBA_BIOS="${GBA_BIOS:-embedded}"

# BIOS and cart ROM as one-word-per-line hex for the testbench's textio
# loader (both derivatives are untracked build artifacts, cheap to redo)
if [ "$GBA_BIOS" = embedded ]; then
   python3 - rtl/gba_bios.vhd sim/tests/bios_words.hex "${SKIP_EWRAM_CLEAR:-0}" <<'PYEOF'
import re, sys
src, dst, skipclear = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
words = [int(m, 16) for m in re.findall(r'x"([0-9A-Fa-f]{8})"', open(src).read())][:4096]
assert len(words) == 4096, f"{src}: expected 4096 init words, got {len(words)}"
# 0x228: mov r1, #0x77 -- the boot logo stays up for 120 frames; make it 1
assert words[0x228 // 4] == 0xE3A01077, "intro wait-loop opcode moved, repatch"
words[0x228 // 4] = 0xE3A01000
patched = "intro wait patched to 1 frame"
if skipclear:
    # same patch as run_gba2p_sdram_tb.sh: skip the boot RegisterRamReset
    # EWRAM wipe (~60ms of sim time) to reach cart code fast
    assert words[0x780 // 4] == 0xE2444008, "EWRAM clear opcode moved, repatch"
    words[0x780 // 4] = 0xE3A04000  # sub r4,r4,#8 -> mov r4,#0
    patched += ", EWRAM clear skipped"
with open(dst, "w") as f:
    for wd in words:
        f.write(f"{wd:08x}\n")
print(f"{dst}: embedded BIOS from {src}, {patched}")
PYEOF
else
   python3 - "$GBA_BIOS" sim/tests/bios_words.hex 16384 <<'PYEOF'
import struct, sys
src, dst, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, "rb").read()
assert len(data) == size, f"{src}: expected {size} bytes, got {len(data)}"
with open(dst, "w") as f:
    for (wd,) in struct.iter_unpack("<I", data):
        f.write(f"{wd:08x}\n")
print(f"{dst}: {len(data)//4} words from {src}")
PYEOF
fi

python3 - sim/tests/LinkCable_basic.gba sim/tests/rom_words.hex <<'PYEOF'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
data += b"\xff" * (-len(data) % 4)
with open(dst, "w") as f:
    for (wd,) in struct.iter_unpack("<I", data):
        f.write(f"{wd:08x}\n")
print(f"{dst}: {len(data)//4} words from {src}")
PYEOF

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

# analysis-only stub so SyncRamDualByteEnable's dead synthesis branch
# type-checks without a Quartus install (see sim/altera_mf_stub.vhd)
nvc --work=altera_mf:"$LIBS"/ALTERA_MF -a sim/altera_mf_stub.vhd

# memory primitives live in their own MEM library
nvc -L "$LIBS" --work=mem:"$LIBS"/MEM -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd \
   rtl/SyncRam.vhd \
   rtl/SyncRamDual.vhd \
   rtl/SyncRamDualByteEnable.vhd \
   rtl/SyncRamDualNotPow2.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/export.vhd \
   rtl/reg_savestates.vhd \
   rtl/reggba_display.vhd \
   rtl/reggba_dma.vhd \
   rtl/reggba_keypad.vhd \
   rtl/reggba_serial.vhd \
   rtl/reggba_sound.vhd \
   rtl/reggba_system.vhd \
   rtl/reggba_timer.vhd \
   rtl/gba_reservedregs.vhd \
   rtl/gba_serial.vhd \
   rtl/gba_linkport.vhd \
   rtl/gba_bios.vhd \
   rtl/cache.vhd \
   rtl/gba_cpu.vhd \
   rtl/gba_dma_module.vhd \
   rtl/gba_dma.vhd \
   rtl/gba_drawer_merge.vhd \
   rtl/gba_drawer_mode0.vhd \
   rtl/gba_drawer_mode2.vhd \
   rtl/gba_drawer_mode345.vhd \
   rtl/gba_drawer_obj.vhd \
   rtl/gba_gpu_drawer.vhd \
   rtl/gba_gpu_timing.vhd \
   rtl/gba_gpu_colorshade.vhd \
   rtl/gba_gpu.vhd \
   rtl/gba_joypad.vhd \
   rtl/gba_sound_ch1.vhd \
   rtl/gba_sound_ch3.vhd \
   rtl/gba_sound_ch4.vhd \
   rtl/gba_sound_dma.vhd \
   rtl/gba_sound.vhd \
   rtl/gba_timer_module.vhd \
   rtl/gba_timer.vhd \
   rtl/gba_gpioRTCSolarGyro.vhd \
   rtl/gba_ctrl_pause.vhd \
   rtl/gba_savestates.vhd \
   rtl/gba_savestates_stub.vhd \
   rtl/gba_statemanager.vhd \
   rtl/gba_cheats.vhd \
   rtl/gba_mem_writerotate.vhd \
   rtl/gba_mem_readrotate.vhd \
   rtl/gba_mem_cheatread.vhd \
   rtl/gba_memorymux.vhd \
   rtl/gba_top.vhd \
   sim/tb_link2p_cpu.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_link2p_cpu

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_link2p_cpu \
   --ieee-warnings=off --stop-time="${STOP_TIME:-40ms}" --exit-severity=failure
