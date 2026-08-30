#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# Runs the RFU daemon's own tests: local command-layout checks, then a real
# two-process session over UDP (host + client) exchanging data both ways.
set -u
cd "$(dirname "$0")/.."

HOST_PORT=${HOST_PORT:-55461}
CLNT_PORT=${CLNT_PORT:-55462}

make -s tests/rfu_test || exit 1

echo "=== local command layouts ==="
tests/rfu_test unit || exit 1

echo
echo "=== two-process session on udp/$HOST_PORT <-> udp/$CLNT_PORT ==="
tests/rfu_test host "$HOST_PORT" "127.0.0.1:$CLNT_PORT" > /tmp/rfu_host.log 2>&1 &
hpid=$!
sleep 0.2
tests/rfu_test client "$CLNT_PORT" "127.0.0.1:$HOST_PORT" > /tmp/rfu_client.log 2>&1
crc=$?
wait $hpid; hrc=$?

grep -v '^    |' /tmp/rfu_host.log
grep -v '^    |' /tmp/rfu_client.log

if [ $hrc -ne 0 ] || [ $crc -ne 0 ]; then
    echo
    echo "SESSION FAILED (host rc=$hrc client rc=$crc); full logs:"
    echo "--- host ---";   cat /tmp/rfu_host.log
    echo "--- client ---"; cat /tmp/rfu_client.log
    exit 1
fi

echo
echo "ALL RFU DAEMON TESTS PASSED"
