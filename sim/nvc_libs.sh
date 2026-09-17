# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
# Shared nvc library setup, sourced by the sim/run_*_tb.sh benches that build
# into sim/nvc_libs. Sets $LIBS and guarantees the altera_mf library inside it
# was analysed by the same nvc that is about to read it.
#
# sim/nvc_libs is a build artifact, not a checked-in one (see .gitignore), and
# MEM/WORK get rebuilt by whichever bench is running. ALTERA_MF was the
# exception: no bench owned it, so it survived as whatever some older nvc had
# once written, and nvc refuses to load a design unit from an earlier
# serialised format --
#
#   ** Fatal: sim/nvc_libs/ALTERA_MF/ALTERA_MF.ALTERA_MF_COMPONENTS: serialised
#      format digest is c8021580 expected 815123dd. This design unit uses a
#      library format from an earlier version of nvc and should be reanalysed.
#
# -- which broke every bench analysing rtl/SyncRamDualByteEnable.vhd or
# rtl/dpram.vhd (the only two files that need altera_mf) after an nvc upgrade.
#
# The library holds one analysis-only stub package, so that those files' dead
# synthesis branch type-checks without a Quartus install (see
# sim/altera_mf_stub.vhd). Reanalysing it costs ~20ms, so rebuild it every run
# rather than guess whether it is current.

LIBS=sim/nvc_libs
mkdir -p "$LIBS"

if ! nvc --work=altera_mf:"$LIBS"/ALTERA_MF -a sim/altera_mf_stub.vhd 2>/dev/null; then
   # library format too old for this nvc to open at all: start it from scratch
   rm -rf "${LIBS:?}/ALTERA_MF"
   nvc --work=altera_mf:"$LIBS"/ALTERA_MF -a sim/altera_mf_stub.vhd
fi
