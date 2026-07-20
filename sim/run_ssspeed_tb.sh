#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc -L "$LIBS" --work=mem:"$LIBS"/MEM -a --relaxed \
   rtl/SyncFifo.vhd \
   rtl/SyncFifoFallThrough.vhd \
   rtl/SyncRamDual.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/gba_savestates.vhd \
   sim/tb_ssspeed.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_ssspeed

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_ssspeed \
   --ieee-warnings=off --stop-time=200ms --exit-severity=failure

GOLDEN=sim/tests/ssspeed_golden.hex
IMAGE=sim/tests/ssspeed_image.hex
if [ ! -f "$GOLDEN" ]; then
   cp "$IMAGE" "$GOLDEN"
   echo "SSSPEED: golden image captured ($GOLDEN) -- re-run after RTL changes to compare"
else
   if cmp -s "$GOLDEN" "$IMAGE"; then
      echo "SSSPEED: image identical to golden"
   else
      echo "SSSPEED: IMAGE DIFFERS FROM GOLDEN" >&2
      cmp "$GOLDEN" "$IMAGE" | head >&2
      exit 1
   fi
fi
