#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Production-boundary regression: verifies gba_wireless holds each byte until
# gba_wireless_uart accepts it. A GPIO ping must emerge on the physical UART
# as the complete three-byte event frame 04 00 00.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/gba-wireless-uart-frame.XXXXXX")"
trap 'rm -rf "$TMP_WORK"' EXIT
W="$TMP_WORK/work"
STOP_TIME="${STOP_TIME:-12ms}"
nvc --work=work:"$W" -a --relaxed \
    rtl/gba_wireless.vhd rtl/gba_wireless_uart.vhd \
    sim/tb_wireless_uart_frame.vhd
nvc --work=work:"$W" -e tb_wireless_uart_frame
OUTPUT="$(nvc --work=work:"$W" -r tb_wireless_uart_frame \
    --stop-time="$STOP_TIME" --exit-severity=failure 2>&1)" || {
    rc=$?
    printf '%s\n' "$OUTPUT"
    exit "$rc"
}
printf '%s\n' "$OUTPUT"
case "$OUTPUT" in
    *"WIRELESS UART FRAME TEST PASSED"*) ;;
    *) echo "FAIL: simulation ended without the UART frame pass sentinel" >&2; exit 1 ;;
esac
