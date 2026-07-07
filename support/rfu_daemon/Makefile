# cross-build for the MiSTer HPS: make CC=arm-linux-gnueabihf-gcc
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
rfu_daemon: rfu_daemon.c
	$(CC) $(CFLAGS) -o $@ $<
clean:
	rm -f rfu_daemon
