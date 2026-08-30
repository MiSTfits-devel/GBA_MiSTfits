# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# rfu_daemon: ARM-side half of the AGB-015 Wireless Adapter emulation.
#   make            host binary (for tests / running on a laptop)
#   make mister     static ARM binary for the MiSTer HPS
#   make check      command-layout checks + a real two-process UDP session
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu99
# musl-cross (brew install musl-cross) links statically, so the result needs
# nothing from the MiSTer image. NOT arm-linux-gnueabihf (not installed here).
ARM_CC  ?= arm-linux-musleabihf-gcc

OBJS    = rfu_daemon.o rfu_core.o rfu_net.o
HDRS    = rfu_core.h rfu_net.h rfu_proto.h

all: rfu_daemon

rfu_daemon: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

%.o: %.c $(HDRS)
	$(CC) $(CFLAGS) -c -o $@ $<

# static ARM build for the HPS
mister: rfu_daemon.arm
rfu_daemon.arm: rfu_daemon.c rfu_core.c rfu_net.c $(HDRS)
	$(ARM_CC) $(CFLAGS) -static -o $@ rfu_daemon.c rfu_core.c rfu_net.c

# tests link the semantics + transport directly, without the UART front end
tests/rfu_test: tests/rfu_test.c rfu_core.c rfu_net.c $(HDRS)
	$(CC) $(CFLAGS) -I. -o $@ tests/rfu_test.c rfu_core.c rfu_net.c

check: tests/rfu_test
	@tests/run_tests.sh

clean:
	rm -f rfu_daemon rfu_daemon.arm $(OBJS) tests/rfu_test

.PHONY: all mister check clean
