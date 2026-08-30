#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# Oracle bench: drives gba_wireless with Nintendo's OWN librfu ID-check
# algorithm (pret/pokeemerald src/librfu_sio32id.c), ported literally into
# sim/tb_wireless_librfu.vhd. Unlike sim/run_wireless_tb.sh -- which replays
# gba_wireless's own login table back at it -- this bench is an independent
# authority and its verdict reflects real cartridge behaviour.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
W=sim/nvc_work
STOP_TIME="${STOP_TIME:-200ms}"
nvc --work=work:$W -a --relaxed \
    rtl/proc_bus_gba.vhd rtl/reggba_serial.vhd rtl/gba_serial.vhd \
    rtl/gba_linkport.vhd rtl/gba_wireless.vhd rtl/gba_wireless_uart.vhd \
    sim/tb_wireless_librfu.vhd
nvc --work=work:$W -e --jit tb_wireless_librfu
nvc --work=work:$W -r tb_wireless_librfu --stop-time="$STOP_TIME" --exit-severity=failure
