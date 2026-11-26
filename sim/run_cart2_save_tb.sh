#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

. sim/nvc_libs.sh

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -a --relaxed \
   rtl/gba_mem_cart2_sdram.vhd \
   sim/tb_cart2_save.vhd

nvc -L "$LIBS" --work=work:"$LIBS"/WORK -e tb_cart2_save
nvc -L "$LIBS" --work=work:"$LIBS"/WORK -r tb_cart2_save --exit-severity=failure
