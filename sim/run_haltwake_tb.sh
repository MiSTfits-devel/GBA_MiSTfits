#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

. sim/nvc_libs.sh

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/export.vhd \
   rtl/reg_savestates.vhd \
   rtl/gba_cpu.vhd \
   sim/tb_haltwake.vhd

fails=0

for WS in 0 1 2 3; do
   for WD in 200 201 202 203; do
      echo "--- WAITSTATES=$WS WAKE_DELAY=$WD"
      nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_haltwake -gWAITSTATES=$WS -gWAKE_DELAY=$WD
      OUTPUT="$(nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_haltwake \
         --stop-time=2ms --exit-severity=failure 2>&1)" || true
      printf '%s\n' "$OUTPUT" | grep -E "PASSED|FAILED|TIMEOUT" || true
      case "$OUTPUT" in
         *"HALT-WAKE TEST PASSED"*) ;;
         *) echo "FAIL: WAITSTATES=$WS WAKE_DELAY=$WD produced no pass sentinel" >&2
            fails=$((fails + 1)) ;;
      esac
   done
done

if [ "$fails" -ne 0 ]; then
   echo "$fails of 16 halt-wake combinations failed" >&2
   exit 1
fi
