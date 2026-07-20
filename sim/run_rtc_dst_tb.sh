#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L sim/nvc_libs --work="$WORK" -a \
   rtl/proc_bus_gba.vhd \
   rtl/reg_savestates.vhd \
   rtl/gba_gpioRTCSolarGyro.vhd \
   sim/tb_rtc_dst.vhd

nvc -L sim/nvc_libs --work="$WORK" -e tb_rtc_dst
nvc -L sim/nvc_libs --work="$WORK" -r tb_rtc_dst --stop-time=2ms --exit-severity=failure
