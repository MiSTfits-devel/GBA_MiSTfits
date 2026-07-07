#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# sound PWM output stage unit test with nvc (https://github.com/nickg/nvc)
#   brew install nvc && sim/run_soundpwm_tb.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK=sim/nvc_work
mkdir -p "$WORK"

nvc -L sim/nvc_libs --work="$WORK" -a \
   rtl/proc_bus_gba.vhd \
   rtl/reggba_sound.vhd \
   rtl/reg_savestates.vhd \
   rtl/gba_sound_ch1.vhd \
   rtl/gba_sound_ch3.vhd \
   rtl/gba_sound_ch4.vhd \
   rtl/gba_sound_dma.vhd \
   rtl/gba_sound.vhd \
   sim/tb_soundpwm.vhd

nvc -L sim/nvc_libs --work="$WORK" -e tb_soundpwm
nvc -L sim/nvc_libs --work="$WORK" -r tb_soundpwm --stop-time=5ms --exit-severity=failure
