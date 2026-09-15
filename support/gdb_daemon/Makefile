# Host build:   make
# MiSTer build: make mister        (static ARM binary, musl-cross)
# Tests:        make check
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu99
OBJS     = gdb_daemon.o gdb_rsp.o gdb_mbox.o

ARM_CC  ?= arm-linux-musleabihf-gcc
ARM_CFLAGS ?= -O2 -Wall -Wextra -std=gnu99 -static -march=armv7-a -mfpu=neon -mfloat-abi=hard

all: gdb_daemon

gdb_daemon: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

%.o: %.c gdb_rsp.h gdb_mbox.h gdb_proto.h
	$(CC) $(CFLAGS) -c -o $@ $<

# Cross-build for the MiSTer HPS. Static so it needs nothing from the image.
mister:
	$(ARM_CC) $(ARM_CFLAGS) -o gdb_daemon.arm gdb_daemon.c gdb_rsp.c gdb_mbox.c
	@echo "built gdb_daemon.arm:" && ls -l gdb_daemon.arm

check: tests/gdb_test
	tests/run_tests.sh

# The test binary stands in a fake engine for the fabric, so the protocol runs
# unchanged off-target. GDB_NO_MMAP keeps /dev/mem out of the host build.
tests/gdb_test: tests/gdb_test.c gdb_rsp.c gdb_mbox.c gdb_rsp.h gdb_mbox.h gdb_proto.h
	$(CC) $(CFLAGS) -DGDB_NO_MMAP -I. -o $@ tests/gdb_test.c gdb_rsp.c gdb_mbox.c

clean:
	rm -f gdb_daemon gdb_daemon.arm $(OBJS) tests/gdb_test

.PHONY: all mister check clean
