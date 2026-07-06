#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Unit bench for the WP4 dual scanout + pause pacing loop (sim/tb_pause160.vhd).
# Runs the hardware configuration (is_simu = '0') that the full-core benches
# cannot exercise. DUAL=0 runs the single-core control.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DUAL="${DUAL:-1}"
LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc --work=altera_mf:"$LIBS"/ALTERA_MF -a sim/altera_mf_stub.vhd

nvc -L "$LIBS" --work=mem:"$LIBS"/MEM -a --relaxed \
   rtl/dpram.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/gba_ctrl_pause.vhd \
   rtl/videoout160.vhd \
   sim/tb_pause160.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_pause160 -g dual="'$DUAL'"

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_pause160 \
   --stop-time="${STOP_TIME:-400ms}" --exit-severity=failure
