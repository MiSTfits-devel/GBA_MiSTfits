#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# link subsystem unit test with nvc (https://github.com/nickg/nvc)
#   brew install nvc && sim/run_link_tb.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc --work="$WORK" -a \
   rtl/proc_bus_gba.vhd \
   rtl/reggba_serial.vhd \
   rtl/gba_serial.vhd \
   sim/tb_link.vhd

nvc --work="$WORK" -e tb_link
nvc --work="$WORK" -r tb_link --stop-time=30ms --exit-severity=failure
