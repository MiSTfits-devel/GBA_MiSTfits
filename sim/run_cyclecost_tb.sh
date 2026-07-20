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
   sim/tb_cyclecost.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_cyclecost
nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_cyclecost --stop-time=5ms
