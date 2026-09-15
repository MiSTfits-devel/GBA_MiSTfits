// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Transport half: drives the DDR3 mailbox the FPGA debug engine polls.
#ifndef GDB_MBOX_H
#define GDB_MBOX_H

#include <stdint.h>

// Backing store for the mailbox. Normally a /dev/mem mapping of the real
// DDR3 window; the unit tests substitute a plain heap buffer plus a fake
// engine so the protocol logic can be exercised off-target.
struct gdb_mbox {
    volatile uint8_t *base;
    int    fd;
    int    map_len;
    uint8_t seq;
    // set by gdb_mbox_open_mem() so close() knows not to munmap
    int    is_memory;
};

int  gdb_mbox_open(struct gdb_mbox *m, unsigned long phys);
int  gdb_mbox_open_mem(struct gdb_mbox *m, void *buf);   // tests
void gdb_mbox_close(struct gdb_mbox *m);

// Issue one command and block until the engine acknowledges it. Returns the
// engine status byte, or -1 on timeout.
int  gdb_mbox_cmd(struct gdb_mbox *m, uint8_t op, uint32_t arg,
                  uint32_t addr, uint16_t len);

// Payload window helpers, byte offsets within the 4 KB data area.
void gdb_mbox_read_data (struct gdb_mbox *m, void *dst, int off, int len);
void gdb_mbox_write_data(struct gdb_mbox *m, const void *src, int off, int len);

// Latest published run state.
int  gdb_mbox_halted(struct gdb_mbox *m);
int  gdb_mbox_stop_reason(struct gdb_mbox *m);
uint32_t gdb_mbox_stop_pc(struct gdb_mbox *m);

// Hook the tests use to run their fake engine between poll iterations.
extern void (*gdb_mbox_pump)(struct gdb_mbox *m);

#endif
