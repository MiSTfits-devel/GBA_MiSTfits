#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/gba_cart_phys.vhd \
   sim/tb_cart_phys.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_cart_phys
nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_cart_phys \
   --ieee-warnings=off --stop-time="${STOP_TIME:-2ms}" --exit-severity=failure
