#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Unit bench for the GBA Multiboot sender (gba_multiboot.vhd) against a
# behavioural model of a real GBA in its BIOS multiboot slave loop.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
W=sim/nvc_work
mkdir -p "$W"
nvc --work=work:$W -a --relaxed rtl/gba_linkport.vhd rtl/gba_multiboot.vhd sim/tb_multiboot.vhd
nvc --work=work:$W -e --jit tb_multiboot
nvc --work=work:$W -r tb_multiboot --stop-time=400ms --exit-severity=failure
