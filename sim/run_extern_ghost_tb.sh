#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Ghost-hunt unit bench for the ch2 cancel/ghost protocol break
# (sim/tb_extern_ghost.vhd, see sim/HANDOFF_2P_CRASH.md session 3).
# Real memorymux_extern + real gba_mem_ewram_sdram + verbatim gba_wrap mux
# against the instrumented behavioral sdram.sv ch2 model.
#
#   sim/run_extern_ghost_tb.sh                    # both streams, 20ms
#   ENABLE_EWRAM=0 sim/run_extern_ghost_tb.sh     # cart-only control
#   ENABLE_CART=0  sim/run_extern_ghost_tb.sh     # ewram-only control
#   LFSR_SEED=99 JUMP_PERIOD=5 STOP_TIME=50ms sim/run_extern_ghost_tb.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc -L "$LIBS" --work=mem:"$LIBS"/MEM -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd \
   rtl/SyncRam.vhd \
   rtl/SyncRamDual.vhd \
   rtl/SyncRamDualByteEnable.vhd \
   rtl/SyncRamDualNotPow2.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/reg_savestates.vhd \
   rtl/memorymux_extern.vhd \
   rtl/gba_mem_ewram_sdram.vhd \
   rtl/gba_mem_cart2_sdram.vhd \
   sim/tb_extern_ghost.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_extern_ghost \
   -g ENABLE_CART="'${ENABLE_CART:-1}'" \
   -g ENABLE_EWRAM="'${ENABLE_EWRAM:-1}'" \
   -g JUMP_PERIOD="${JUMP_PERIOD:-7}" \
   -g LFSR_SEED="${LFSR_SEED:-305419896}" \
   -g FIX_WRSLOT8="'${FIX_WRSLOT8:-1}'" \
   -g SIM_TRACE="'${SIM_TRACE:-0}'"

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_extern_ghost \
   --ieee-warnings=off --stop-time="${STOP_TIME:-20ms}" --exit-severity=failure
