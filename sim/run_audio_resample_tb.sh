#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SIM_OUT="$(mktemp "${TMPDIR:-/tmp}/tb_audio_resample.XXXXXX.vvp")"
trap 'rm -f "$SIM_OUT"' EXIT

iverilog -g2012 -s tb_audio_resample -o "$SIM_OUT" \
	sys/audio_out.v \
	sim/tb_audio_resample.sv
vvp "$SIM_OUT"
