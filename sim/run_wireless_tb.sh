#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Unit bench for the AGB-015 Wireless Adapter transport (gba_wireless.vhd)
# against a real gba_serial driven like LinkRawWireless drives the GBA.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
W=sim/nvc_work
nvc --work=work:$W -a --relaxed rtl/proc_bus_gba.vhd rtl/reggba_serial.vhd rtl/gba_serial.vhd rtl/gba_linkport.vhd rtl/gba_wireless.vhd rtl/gba_wireless_uart.vhd sim/tb_wireless.vhd
nvc --work=work:$W -e --jit tb_wireless
nvc --work=work:$W -r tb_wireless --stop-time=100ms --exit-severity=failure
