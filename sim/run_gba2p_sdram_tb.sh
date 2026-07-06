#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# 2P memory-profile reproduction bench (see sim/tb_gba2p_sdram.vhd) with nvc.
# Boots a real game on both cores in the exact GBA2P memory configuration:
# EWRAM in SDRAM, shared SDRAM port, real memorymux_extern + guest channels.
#
#   sim/run_gba2p_sdram_tb.sh                       # Apotris, the crash ROM
#   GBA_ROM=path/to/game.gba sim/run_gba2p_sdram_tb.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GBA_ROM="${GBA_ROM:-$HOME/gbabak/Apotris.gba}"

# embedded fast-boot BIOS (same generation as run_link2p_cpu_tb.sh).
# SKIP_EWRAM_CLEAR=1 also skips the boot RegisterRamReset EWRAM wipe
# (~60ms of sim time) to reach cart code fast.
python3 - rtl/gba_bios.vhd sim/tests/bios_words.hex "${SKIP_EWRAM_CLEAR:-0}" <<'PYEOF'
import re, sys
src, dst, skipclear = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
words = [int(m, 16) for m in re.findall(r'x"([0-9A-Fa-f]{8})"', open(src).read())][:4096]
assert len(words) == 4096, f"{src}: expected 4096 init words, got {len(words)}"
assert words[0x228 // 4] == 0xE3A01077, "intro wait-loop opcode moved, repatch"
words[0x228 // 4] = 0xE3A01000
patched = "intro wait patched to 1 frame"
if skipclear:
    assert words[0x780 // 4] == 0xE2444008, "EWRAM clear opcode moved, repatch"
    words[0x780 // 4] = 0xE3A04000  # sub r4,r4,#8 -> mov r4,#0
    patched += ", EWRAM clear skipped"
with open(dst, "w") as f:
    for wd in words:
        f.write(f"{wd:08x}\n")
print(f"{dst}: embedded BIOS, {patched}")
PYEOF

ROM_WORDS=$(python3 - "$GBA_ROM" sim/tests/rom2_words.hex <<'PYEOF'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
data += b"\xff" * (-len(data) % 4)
with open(dst, "w") as f:
    for (wd,) in struct.iter_unpack("<I", data):
        f.write(f"{wd:08x}\n")
print(len(data)//4)
PYEOF
)
echo "ROM: $GBA_ROM ($ROM_WORDS words)"

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc --work=altera_mf:"$LIBS"/ALTERA_MF -a sim/altera_mf_stub.vhd

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
   rtl/memorymux_extern.vhd \
   rtl/gba_mem_ewram_sdram.vhd \
   rtl/gba_mem_cart2_sdram.vhd \
   sim/tb_gba2p_sdram.vhd

nvc -H 2g -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_gba2p_sdram \
   -gROM_WORDS="$ROM_WORDS" -gROM_HEX=sim/tests/rom2_words.hex -g ALIAS_32MB="'${ALIAS_32MB:-0}'" -g TURBO="'${TURBO:-0}'"

nvc -H 2g -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_gba2p_sdram \
   --ieee-warnings=off --stop-time="${STOP_TIME:-60ms}" --exit-severity=failure
