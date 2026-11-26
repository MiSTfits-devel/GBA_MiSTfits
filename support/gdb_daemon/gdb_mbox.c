// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#define _POSIX_C_SOURCE 200809L

#include "gdb_mbox.h"
#include "gdb_proto.h"

#include <errno.h>
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
    if (!m->is_memory)
        return *(volatile uint64_t *)(m->base + off);
    uint64_t v;
    memcpy(&v, (const void *)(m->base + off), sizeof(v));
    return v;
}

static void wr64(struct gdb_mbox *m, int off, uint64_t v)
{
    if (!m->is_memory)
        *(volatile uint64_t *)(m->base + off) = v;
    else
        memcpy((void *)(m->base + off), &v, sizeof(v));
}

int gdb_mbox_open(struct gdb_mbox *m, unsigned long phys)
{
#ifdef GDB_NO_MMAP
    (void)m; (void)phys;
    return -1;
#else
    long   pagesz = sysconf(_SC_PAGESIZE);
    off_t  aligned;
    size_t slop;
    void  *p;

    if (pagesz <= 0 || (phys & 7u)) {
        errno = EINVAL;
        return -1;
    }
    aligned = (off_t)(phys & ~(unsigned long)(pagesz - 1));
    slop = (size_t)(phys - (unsigned long)aligned);

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
    // Do not erase the engine's ACK or reuse its last command sequence.
    m->seq = (uint8_t)(rd64(m, GDB_OFF_CMD) >> 8);
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

static int valid_ack(uint64_t ack)
{
    return (uint32_t)(ack >> 32) == GDB_MAGIC &&
           (uint16_t)(ack >> 16) == GDB_PROTO_VER;
}

int gdb_mbox_check_magic(struct gdb_mbox *m)
{
    return valid_ack(rd64(m, GDB_OFF_ACK)) ? 0 : -1;
}

int gdb_mbox_cmd(struct gdb_mbox *m, uint8_t op, uint32_t arg,
                 uint64_t addr, uint16_t len)
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
    if (m->is_memory) {
        wr64(m, GDB_OFF_CMD, (uint64_t)op | ((uint64_t)want << 8) |
                            ((uint64_t)arg << 32));
    } else {
        volatile uint32_t *cmd = (volatile uint32_t *)(m->base + GDB_OFF_CMD);
        // On the 32-bit HPS, commit the sequence last even if a qword store
        // would otherwise publish its low half before the argument.
        cmd[1] = arg;
        __sync_synchronize();
        cmd[0] = (uint32_t)op | ((uint32_t)want << 8);
    }

    deadline = now_ms() + ACK_TIMEOUT_MS;
    for (;;) {
        uint64_t ack;

        if (gdb_mbox_pump)
            gdb_mbox_pump(m);

        ack = rd64(m, GDB_OFF_ACK);
        if ((uint8_t)ack == want) {
            __sync_synchronize(); // ACK publishes the payload and state.
            return valid_ack(ack) ? (int)((ack >> 8) & 0xff) : -1;
        }

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

uint64_t gdb_mbox_state(struct gdb_mbox *m)
{
    return rd64(m, GDB_OFF_STATE);
}

int gdb_mbox_stop_slot(struct gdb_mbox *m)
{
    return (int)((rd64(m, GDB_OFF_STATE) >> 8) & 0xf);
}

int gdb_mbox_stop_core(struct gdb_mbox *m)
{
    return (int)((rd64(m, GDB_OFF_STATE) >> 12) & 1);
}

int gdb_mbox_active_core(struct gdb_mbox *m)
{
    return (int)((rd64(m, GDB_OFF_STATE) >> 1) & 1);
}

int gdb_mbox_dual_core(struct gdb_mbox *m)
{
    return (int)((rd64(m, GDB_OFF_STATE) >> 2) & 1);
}

uint64_t gdb_mbox_cycles(struct gdb_mbox *m)
{
    return rd64(m, GDB_OFF_CYCLES);
}

static int read_payload(struct gdb_mbox *m, uint8_t op, void *data, int len)
{
    int status = gdb_mbox_cmd(m, op, 0, 0, 0);
    if (status == GDB_STATUS_OK)
        gdb_mbox_read_data(m, data, 0, len);
    return status;
}

int gdb_mbox_read_regs(struct gdb_mbox *m, uint32_t regs[GDB_NUM_REGS])
{
    return read_payload(m, GDB_CMD_RDREGS, regs, GDB_NUM_REGS * 4);
}

int gdb_mbox_read_state(struct gdb_mbox *m, struct gdb_state *state)
{
    return read_payload(m, GDB_CMD_RDSTATE, state, GDB_STATE_QWORDS * 8);
}

int gdb_mbox_read_trace(struct gdb_mbox *m, struct gdb_trace *trace)
{
    return read_payload(m, GDB_CMD_RD_TRACE, trace, GDB_TRACE_QWORDS * 8);
}

// The GBA bus transfers whole words. Read at an aligned base, then take
// only the bytes the caller asked for from the mailbox.
int gdb_mbox_read_mem(struct gdb_mbox *m, uint32_t addr, int len, uint8_t *out)
{
    int lead = (int)(addr & 3u), total, status;

    if (len < 0 || len > GDB_DATA_MAX - lead)
        return GDB_STATUS_BADARG;
    total = len ? (lead + len + 3) & ~3 : 0;
    status = gdb_mbox_cmd(m, GDB_CMD_RDMEM, 0, addr & ~3u, (uint16_t)total);
    if (status == GDB_STATUS_OK && len)
        gdb_mbox_read_data(m, out, lead, len);
    return status;
}

int gdb_mbox_write_mem(struct gdb_mbox *m, uint32_t addr, int len, const uint8_t *in)
{
    uint32_t base = addr & ~3u;
    int lead = (int)(addr & 3u), status;

    if (len < 0 || len > GDB_DATA_MAX - lead)
        return GDB_STATUS_BADARG;
    if (len && lead) {
        // RDMEM leaves the leading bytes in the same payload window. The
        // engine preserves any ragged trailing bytes during WRMEM.
        status = gdb_mbox_cmd(m, GDB_CMD_RDMEM, 0, base, 4);
        if (status != GDB_STATUS_OK)
            return status;
    }
    if (len)
        gdb_mbox_write_data(m, in, lead, len);
    return gdb_mbox_cmd(m, GDB_CMD_WRMEM, 0, base, (uint16_t)(len ? lead + len : 0));
}

int gdb_mbox_set_cmp(struct gdb_mbox *m, int wp, int slot, uint32_t addr,
                     int en, int rd, int wr, int core, int both)
{
    uint32_t arg;
    int status;

    if (slot < 0 || slot >= (wp ? GDB_WP_COUNT : GDB_BP_COUNT))
        return GDB_STATUS_BADARG;
    arg = ((uint32_t)slot & GDB_CMP_SLOT_MASK) | (en ? GDB_CMP_ENABLE : 0);
    if (wp)
        arg |= (rd ? GDB_WP_READ : 0) | (wr ? GDB_WP_WRITE : 0) |
               (core ? GDB_WP_CORE : 0) | (both ? GDB_WP_BOTH : 0);
    else
        arg |= (core ? GDB_BP_CORE : 0) | (both ? GDB_BP_BOTH : 0);
    status = gdb_mbox_cmd(m, wp ? GDB_CMD_SETWP : GDB_CMD_SETBP, arg, addr, 0);
    if (status == GDB_STATUS_OK)
        (wp ? m->wp_args : m->bp_args)[slot] = arg;
    return status;
}

int gdb_mbox_read_fb(unsigned long phys_base, uint8_t *dst, size_t len)
{
#ifdef GDB_NO_MMAP
    (void)phys_base; (void)dst; (void)len;
    errno = ENOSYS;
    return -1;
#else
    enum { STRIDE = 256 * 2, ROW_BYTES = GDB_FB_WIDTH * 2 };
    const uint8_t *src;
    int fd, y, saved_errno;
    size_t map_len = GDB_FB_HEIGHT * STRIDE;

    if ((phys_base != GDB_FB0_PHYS && phys_base != GDB_FB1_PHYS) ||
        len < GDB_FB_HEIGHT * ROW_BYTES) {
        errno = EINVAL;
        return -1;
    }
    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0)
        return -1;
    src = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, (off_t)phys_base);
    saved_errno = errno;
    close(fd);
    if (src == MAP_FAILED) {
        errno = saved_errno;
        return -1;
    }
    for (y = 0; y < GDB_FB_HEIGHT; y++)
        memcpy(dst + y * ROW_BYTES, src + y * STRIDE, ROW_BYTES);
    return munmap((void *)src, map_len);
#endif
}
