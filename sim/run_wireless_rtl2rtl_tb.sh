#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

nvc --std=2008 --work=work:sim/nvc_work -a --relaxed \
    rtl/proc_bus_gba.vhd rtl/reggba_serial.vhd rtl/gba_serial.vhd \
    rtl/gba_linkport.vhd rtl/gba_wireless.vhd sim/tb_wireless_rtl2rtl.vhd
nvc --std=2008 --work=work:sim/nvc_work -e --jit tb_wireless_rtl2rtl
nvc --std=2008 --work=work:sim/nvc_work -r tb_wireless_rtl2rtl --exit-severity=failure
