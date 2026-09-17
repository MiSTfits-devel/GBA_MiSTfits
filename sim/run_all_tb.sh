#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# Runs the testbench suite and compares each result against the expected status
# below, so a sweep answers "did anything change" rather than "did anything
# fail". Serial by design: the benches share sim/nvc_libs, and two of them
# analysing into the same WORK at once produces confident nonsense.
#
#   sim/run_all_tb.sh          fast benches only (well under a minute)
#   sim/run_all_tb.sh --all    also the slow full-core ones
#
# A bench listed as SKIP needs something this machine may not have; give it what
# it wants and it runs. Anything not listed is expected to pass.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# bench                     status  reason
EXPECTED=$(cat <<'TABLE'
run_gba2p_sdram_tb.sh       SKIP    needs a ROM: set GBA_ROM=path/to/game.gba
TABLE
)

SLOW="run_bustiming_tb.sh run_link2p_cpu_tb.sh run_gba2p_sdram_tb.sh"

want_slow=0
[ "${1:-}" = "--all" ] && want_slow=1

expected_for() {
   printf '%s\n' "$EXPECTED" | awk -v b="$1" '$1 == b { print $2 }'
}
reason_for() {
   printf '%s\n' "$EXPECTED" | awk -v b="$1" '$1 == b { $1=""; $2=""; sub(/^ +/,""); print }'
}

LOGDIR="${LOGDIR:-$(mktemp -d "${TMPDIR:-/tmp}/gba-suite.XXXXXX")}"
mkdir -p "$LOGDIR"
echo "logs: $LOGDIR"
echo

fails=0
ran=0
SELF="$(basename "$0")"

for path in sim/run_*_tb.sh; do
   bench="$(basename "$path")"
   [ "$bench" = "$SELF" ] && continue

   case " $SLOW " in
      *" $bench "*)
         if [ "$want_slow" -eq 0 ]; then
            printf '%-30s %-8s %s\n' "$bench" "slow" "use --all"
            continue
         fi ;;
   esac

   if [ "$(expected_for "$bench")" = SKIP ] && [ -z "${GBA_ROM:-}" ]; then
      printf '%-30s %-8s %s\n' "$bench" "skip" "$(reason_for "$bench")"
      continue
   fi

   start=$SECONDS
   if bash "$path" >"$LOGDIR/$bench.log" 2>&1; then
      printf '%-30s %-8s %3ss\n' "$bench" "pass" "$((SECONDS - start))"
   else
      rc=$?
      printf '%-30s %-8s %3ss  (rc=%s, see %s)\n' \
         "$bench" "FAIL" "$((SECONDS - start))" "$rc" "$LOGDIR/$bench.log"
      fails=$((fails + 1))
   fi
   ran=$((ran + 1))
done

echo
# tb_bustiming reports hardware-timing deviations as warnings and still exits 0,
# so its findings have to be read out of the log rather than the exit code
if [ -f "$LOGDIR/run_bustiming_tb.sh.log" ]; then
   grep -o 'BUSTIME.*' "$LOGDIR/run_bustiming_tb.sh.log" || true
   echo
fi

if [ "$fails" -ne 0 ]; then
   echo "$fails of $ran benches failed"
   exit 1
fi
echo "all $ran benches passed"
