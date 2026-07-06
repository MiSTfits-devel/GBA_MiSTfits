#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Real-RTL differential bench for rtl/sdram.sv (see sim/tb_sdram_real.v).
# Runs the CURRENT controller and, with REF=<git-ref>, a reference version
# for differential comparison (S3/S4 document the pre-fix live-sampling bug).
#
#   sim/run_sdram_real_tb.sh              # current rtl/sdram.sv
#   REF=86b4c8e sim/run_sdram_real_tb.sh  # that commit's sdram.sv instead
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

RAW=$(mktemp -t sdram_raw).sv
if [ -n "${REF:-}" ]; then
   git show "${REF}:rtl/sdram.sv" > "$RAW"
   echo "== reference controller: ${REF}"
else
   cp rtl/sdram.sv "$RAW"
fi

# icarus cannot procedurally assign an inout: split SDRAM_DQ into an
# internal reg + continuous assign (identical semantics)
SRC=$(mktemp -t sdram_iv).sv
python3 - "$RAW" "$SRC" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = src.replace("inout  reg [15:0] SDRAM_DQ", "inout      [15:0] SDRAM_DQ")
# icarus needs declare-before-use: move the pin assigns below the reg decls,
# right before the main always block
assigns = re.findall(r'^assign SDRAM_\S+.*$|^assign \{SDRAM_DQMH.*$', src, re.M)
for a in assigns:
    src = src.replace(a + "\n", "")
block = "\n".join(assigns) + "\nreg [15:0] SDRAM_DQ_r = 16'bZ;\nassign SDRAM_DQ = SDRAM_DQ_r;\n\n"
src = src.replace("always @(posedge clk) begin", block + "always @(posedge clk) begin", 1)
src = re.sub(r'\bSDRAM_DQ(\s*)<=', r'SDRAM_DQ_r\1<=', src)
open(sys.argv[2], "w").write(src)
PYEOF

OUT=$(mktemp -t tb_sdram_real)
iverilog -g2012 -o "$OUT" "$SRC" sim/tb_sdram_real.v
vvp "$OUT"
