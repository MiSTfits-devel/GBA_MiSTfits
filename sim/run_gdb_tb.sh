#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# gdb debug engine unit test with nvc (https://github.com/nickg/nvc)
#   brew install nvc && sim/run_gdb_tb.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc --work="$WORK" -a --relaxed \
   rtl/proc_bus_gba.vhd \
   rtl/gba_gdb.vhd \
   sim/tb_gdb.vhd

nvc --work="$WORK" -e tb_gdb
nvc --work="$WORK" -r tb_gdb --stop-time=20ms --exit-severity=failure
