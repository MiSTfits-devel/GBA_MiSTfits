// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Transport half: drives the DDR3 mailbox the FPGA debug engine polls.
#ifndef GDB_MBOX_H
#define GDB_MBOX_H

#include "gdb_proto.h"

#include <stddef.h>
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
    uint32_t bp_args[GDB_BP_COUNT];
    uint32_t wp_args[GDB_WP_COUNT];
};

int  gdb_mbox_open(struct gdb_mbox *m, unsigned long phys);
int  gdb_mbox_open_mem(struct gdb_mbox *m, void *buf);   // tests
void gdb_mbox_close(struct gdb_mbox *m);

// Returns 0 if the ACK word advertises this protocol, -1 otherwise.
int  gdb_mbox_check_magic(struct gdb_mbox *m);

// Issue one command and block until the engine acknowledges it. Returns the
// engine status byte, or -1 on timeout or a mismatched protocol version.
int  gdb_mbox_cmd(struct gdb_mbox *m, uint8_t op, uint32_t arg,
                  uint64_t addr, uint16_t len);

// Payload window helpers, byte offsets within the 4 KB data area.
void gdb_mbox_read_data (struct gdb_mbox *m, void *dst, int off, int len);
void gdb_mbox_write_data(struct gdb_mbox *m, const void *src, int off, int len);

int gdb_mbox_read_regs(struct gdb_mbox *m, uint32_t regs[GDB_NUM_REGS]);
int gdb_mbox_read_state(struct gdb_mbox *m, struct gdb_state *state);
int gdb_mbox_read_trace(struct gdb_mbox *m, struct gdb_trace *trace);
int gdb_mbox_read_mem(struct gdb_mbox *m, uint32_t addr, int len, uint8_t *out);
int gdb_mbox_write_mem(struct gdb_mbox *m, uint32_t addr, int len, const uint8_t *in);
int gdb_mbox_set_cmp(struct gdb_mbox *m, int wp, int slot, uint32_t addr,
                     int en, int rd, int wr, int core, int both);

// CPSR is word 17 in the active-core savestate (r0 begins at word 1).
static inline uint32_t gdb_state_cpsr(const struct gdb_state *state)
{
    return (uint32_t)(state->savestate[8] >> 32);
}

// Latest published run state.
uint64_t gdb_mbox_state(struct gdb_mbox *m);
int  gdb_mbox_halted(struct gdb_mbox *m);
int  gdb_mbox_stop_reason(struct gdb_mbox *m);
uint32_t gdb_mbox_stop_pc(struct gdb_mbox *m);
int  gdb_mbox_stop_slot(struct gdb_mbox *m);
int  gdb_mbox_stop_core(struct gdb_mbox *m);
int  gdb_mbox_active_core(struct gdb_mbox *m);
int  gdb_mbox_dual_core(struct gdb_mbox *m);
uint64_t gdb_mbox_cycles(struct gdb_mbox *m);

#define GDB_FB0_PHYS  0x38000000ul
#define GDB_FB1_PHYS  0x38080000ul
#define GDB_FB_WIDTH  240
#define GDB_FB_HEIGHT 160
// Copies one unrotated frame, stripping the DDR3 row padding. The result is
// tightly packed little-endian RGB555. Returns -1 and sets errno on failure.
int gdb_mbox_read_fb(unsigned long phys_base, uint8_t *dst, size_t len);

// Hook the tests use to run their fake engine between poll iterations.
extern void (*gdb_mbox_pump)(struct gdb_mbox *m);

#endif
