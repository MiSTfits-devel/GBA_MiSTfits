#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# Runs the gdb daemon's protocol tests against a fake debug engine standing in
# for rtl/gba_gdb.vhd, then a real end-to-end session over TCP driven by a
# scripted gdb client.
set -u
cd "$(dirname "$0")/.."

make -s tests/gdb_test || exit 1

echo "=== remote serial protocol ==="
tests/gdb_test || exit 1

echo
echo "ALL GDB DAEMON TESTS PASSED"
