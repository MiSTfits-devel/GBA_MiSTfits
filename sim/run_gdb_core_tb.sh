#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

. sim/nvc_libs.sh

nvc --std=2008 -L "$LIBS" --work=mem:"$LIBS"/MEM -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd \
   rtl/SyncRam.vhd \
   rtl/SyncRamDual.vhd \
   rtl/SyncRamDualByteEnable.vhd \
   rtl/SyncRamDualNotPow2.vhd

nvc --std=2008 -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
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
   rtl/gba_gdb.vhd \
   sim/tb_gdb.vhd \
   sim/tb_gdb_core.vhd

nvc --std=2008 -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_gdb_core
nvc --std=2008 -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_gdb_core \
   --ieee-warnings=off --exit-severity=failure
