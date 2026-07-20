#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L sim/nvc_libs --work="$WORK" -a \
   rtl/gba_statemanager.vhd \
   sim/tb_rewindmanager.vhd

nvc -L sim/nvc_libs --work="$WORK" -e tb_rewindmanager
nvc -L sim/nvc_libs --work="$WORK" -r tb_rewindmanager --stop-time=5ms --exit-severity=failure
