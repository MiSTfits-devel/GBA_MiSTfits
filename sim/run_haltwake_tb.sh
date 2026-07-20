#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/export.vhd \
   rtl/reg_savestates.vhd \
   rtl/gba_cpu.vhd \
   sim/tb_haltwake.vhd

for WS in 0 1 2 3; do
   for WD in 200 201 202 203; do
      echo "--- WAITSTATES=$WS WAKE_DELAY=$WD"
      nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_haltwake -gWAITSTATES=$WS -gWAKE_DELAY=$WD
      nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_haltwake --stop-time=2ms 2>&1 | grep -E "PASSED|FAILED|TIMEOUT" || true
   done
done
