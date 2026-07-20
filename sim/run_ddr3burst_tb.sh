#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc -L "$LIBS" --work=mem:"$LIBS"/MEM -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/DDR3Mux.vhd \
   sim/tb_ddr3burst.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_ddr3burst

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_ddr3burst \
   --ieee-warnings=off --stop-time=10ms --exit-severity=failure
