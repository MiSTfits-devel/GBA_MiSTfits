// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#include "gdb_mbox.h"
#include "gdb_proto.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef GDB_NO_MMAP
#include <sys/mman.h>
#endif

// The engine polls the command word once per 4096 core cycles while the core
// is running (244us at 16.78MHz) and hard while it is halted, so a command
// can take a quarter of a millisecond just to be noticed. Ten milliseconds is
// far past both, and only trips if the core is stopped or the stub is off.
#define ACK_TIMEOUT_MS  10

void (*gdb_mbox_pump)(struct gdb_mbox *m) = NULL;

static uint64_t rd64(struct gdb_mbox *m, int off)
{
    uint64_t v;
    memcpy(&v, (const void *)(m->base + off), sizeof(v));
    return v;
}

static void wr64(struct gdb_mbox *m, int off, uint64_t v)
{
    memcpy((void *)(m->base + off), &v, sizeof(v));
}

int gdb_mbox_open(struct gdb_mbox *m, unsigned long phys)
{
#ifdef GDB_NO_MMAP
    (void)m; (void)phys;
    return -1;
#else
    long   pagesz = sysconf(_SC_PAGESIZE);
    off_t  aligned = (off_t)(phys & ~(unsigned long)(pagesz - 1));
    size_t slop    = (size_t)(phys - (unsigned long)aligned);
    void  *p;

    memset(m, 0, sizeof(*m));
    m->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (m->fd < 0) {
        perror("open /dev/mem");
        return -1;
    }

    m->map_len = (int)(slop + GDB_MBOX_SIZE);
    p = mmap(NULL, (size_t)m->map_len, PROT_READ | PROT_WRITE, MAP_SHARED,
             m->fd, aligned);
    if (p == MAP_FAILED) {
        perror("mmap");
        close(m->fd);
        m->fd = -1;
        return -1;
    }

    m->base = (volatile uint8_t *)p + slop;
    // start from a known state; the engine ignores NOP
    wr64(m, GDB_OFF_CMD, 0);
    wr64(m, GDB_OFF_ACK, 0);
    m->seq = 0;
    return 0;
#endif
}

int gdb_mbox_open_mem(struct gdb_mbox *m, void *buf)
{
    memset(m, 0, sizeof(*m));
    m->base      = (volatile uint8_t *)buf;
    m->fd        = -1;
    m->is_memory = 1;
    m->seq       = 0;
    return 0;
}

void gdb_mbox_close(struct gdb_mbox *m)
{
#ifndef GDB_NO_MMAP
    if (!m->is_memory && m->base)
        munmap((void *)(m->base - (m->map_len - GDB_MBOX_SIZE)),
               (size_t)m->map_len);
#endif
    if (m->fd >= 0)
        close(m->fd);
    m->base = NULL;
    m->fd   = -1;
}

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

int gdb_mbox_cmd(struct gdb_mbox *m, uint8_t op, uint32_t arg,
                 uint32_t addr, uint16_t len)
{
    uint32_t deadline;
    uint8_t  want;

    // sequence 0 never matches a fresh ack word, so skip it on wrap
    if (++m->seq == 0)
        m->seq = 1;
    want = m->seq;

    // address and length first: the engine reads them only after it has seen
    // a new sequence in the command word, so this ordering is the handshake
    wr64(m, GDB_OFF_ADDR, addr);
    wr64(m, GDB_OFF_LEN, len);
    wr64(m, GDB_OFF_CMD, (uint64_t)op | ((uint64_t)want << 8) |
                         ((uint64_t)arg << 32));

    deadline = now_ms() + ACK_TIMEOUT_MS;
    for (;;) {
        uint64_t ack;

        if (gdb_mbox_pump)
            gdb_mbox_pump(m);

        ack = rd64(m, GDB_OFF_ACK);
        if ((ack & 0xff) == want)
            return (int)((ack >> 8) & 0xff);

        if ((int32_t)(now_ms() - deadline) > 0)
            return -1;
    }
}

void gdb_mbox_read_data(struct gdb_mbox *m, void *dst, int off, int len)
{
    memcpy(dst, (const void *)(m->base + GDB_OFF_DATA + off), (size_t)len);
}

void gdb_mbox_write_data(struct gdb_mbox *m, const void *src, int off, int len)
{
    memcpy((void *)(m->base + GDB_OFF_DATA + off), src, (size_t)len);
}

int gdb_mbox_halted(struct gdb_mbox *m)
{
    return (int)(rd64(m, GDB_OFF_STATE) & 1);
}

int gdb_mbox_stop_reason(struct gdb_mbox *m)
{
    return (int)((rd64(m, GDB_OFF_STATE) >> 4) & 0xf);
}

uint32_t gdb_mbox_stop_pc(struct gdb_mbox *m)
{
    return (uint32_t)(rd64(m, GDB_OFF_STATE) >> 32);
}
