#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Differential TX check: run the SAME extended bench (3-byte frame + long idle)
# against a chosen gba_wireless.vhd.  Takes the source file as $1.
set -euo pipefail
SRC="${1:?usage: $0 <gba_wireless.vhd>}"
WT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$WT"
cp "$SRC" "$TMP/gba_wireless.vhd"
nvc --work=work:"$TMP"/lib -a --relaxed \
    "$TMP/gba_wireless.vhd" rtl/gba_wireless_uart.vhd sim/tb_wireless_uart_frame.vhd
nvc --work=work:"$TMP"/lib -e tb_wireless_uart_frame
set +e
OUT="$(nvc --work=work:"$TMP"/lib -r tb_wireless_uart_frame --stop-time=6ms --exit-severity=failure 2>&1)"
rc=$?
set -e
echo "==== source: $SRC exit: $rc ===="
echo "$OUT"
exit 0