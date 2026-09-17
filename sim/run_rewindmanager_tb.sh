#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

. sim/nvc_libs.sh

nvc -L "$LIBS" --work="$WORK" -a \
   rtl/gba_statemanager.vhd \
   sim/tb_rewindmanager.vhd

nvc -L "$LIBS" --work="$WORK" -e tb_rewindmanager
nvc -L "$LIBS" --work="$WORK" -r tb_rewindmanager --stop-time=5ms --exit-severity=failure
