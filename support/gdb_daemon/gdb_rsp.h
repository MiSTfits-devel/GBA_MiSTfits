// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// GDB remote serial protocol, target side.
#ifndef GDB_RSP_H
#define GDB_RSP_H

#include "gdb_mbox.h"
#include "gdb_proto.h"

// gdb's built-in (no target description) ARM layout, which every
// arm-none-eabi-gdb agrees on without negotiation:
//   0..15  r0..r15          4 bytes each
//   16..23 f0..f7          12 bytes each, FPA, reported as zero
//   24     fps              4 bytes,      reported as zero
//   25     cpsr             4 bytes
#define GDB_G_BYTES     (16 * 4 + 8 * 12 + 4 + 4)   // 168
#define GDB_REG_CPSR    25

#define GDB_REPLY_MAX   (GDB_G_BYTES * 2 + 64)
#define GDB_PKT_MAX     (GDB_DATA_MAX * 2 + 64)

struct gdb_bpslot {
    uint32_t addr;
    int      used;
    int      kind;      // Z-packet type that claimed it
};

struct gdb_rsp {
    struct gdb_mbox  *mb;
    int  running;       // target resumed, stop reply still owed to gdb
    int  detached;
    struct gdb_bpslot bp[GDB_BP_COUNT];
    struct gdb_bpslot wp[GDB_WP_COUNT];
};

void gdb_rsp_init(struct gdb_rsp *s, struct gdb_mbox *mb);

// Handle one packet body (no $ ... # framing). Writes a NUL-terminated reply
// into `reply`. Returns the reply length, or 0 when no reply is owed yet
// (the target was resumed; the stop reply comes from gdb_rsp_poll).
int  gdb_rsp_packet(struct gdb_rsp *s, const char *pkt, char *reply, int max);

// Called while the target runs. Returns a stop-reply length once the core has
// halted, otherwise 0.
int  gdb_rsp_poll(struct gdb_rsp *s, char *reply, int max);

// Ctrl-C from gdb: stop the target. Reply comes from gdb_rsp_poll.
void gdb_rsp_interrupt(struct gdb_rsp *s);

// exposed for the unit tests
int  gdb_hex2int(const char *p, const char **end, uint32_t *out);
void gdb_mem2hex(const uint8_t *src, char *dst, int len);
int  gdb_hex2mem(const char *src, uint8_t *dst, int len);
uint8_t gdb_checksum(const char *p, int len);

#endif
