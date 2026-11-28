#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Soak bench for the AGB-015 Wireless Adapter transport (gba_wireless.vhd):
# 400 x 0x13 + 400 x 0x1A command/ACK exchanges against a UART model that
# reproduces the real gba_wireless_uart transmitter contract, plus forced
# tx_ready stalls and the GPIO-ping recovery path.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
W=sim/nvc_work
nvc --work=work:$W -a --relaxed rtl/proc_bus_gba.vhd rtl/reggba_serial.vhd rtl/gba_serial.vhd rtl/gba_linkport.vhd rtl/gba_wireless.vhd rtl/gba_wireless_uart.vhd sim/tb_wireless_soak.vhd
nvc --work=work:$W -e --jit tb_wireless_soak
nvc --work=work:$W -r tb_wireless_soak --stop-time=3000ms --exit-severity=failure
