// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// GDB remote serial protocol against the FPGA debug engine.
//
// Two things here are deliberately unlike a software stub. Breakpoints always
// take a hardware comparator, even when gdb asks for a software one (Z0), so
// they work in cartridge ROM where patching a trap opcode cannot. And the
// register file is read straight out of the running CPU rather than off a
// saved frame, so what gdb shows is the architectural state at the exact
// instruction boundary the core stopped on.
#include "gdb_rsp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char hexchars[] = "0123456789abcdef";

uint8_t gdb_checksum(const char *p, int len)
{
    uint8_t sum = 0;
    int i;
    for (i = 0; i < len; i++)
        sum = (uint8_t)(sum + (uint8_t)p[i]);
    return sum;
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int gdb_hex2int(const char *p, const char **end, uint32_t *out)
{
    uint32_t v = 0;
    int n = 0, d;

    while ((d = hexval(*p)) >= 0) {
        v = (v << 4) | (uint32_t)d;
        p++;
        n++;
    }
    if (end) *end = p;
    if (out) *out = v;
    return n;
}

void gdb_mem2hex(const uint8_t *src, char *dst, int len)
{
    int i;
    for (i = 0; i < len; i++) {
        *dst++ = hexchars[(src[i] >> 4) & 0xf];
        *dst++ = hexchars[src[i] & 0xf];
    }
    *dst = 0;
}

int gdb_hex2mem(const char *src, uint8_t *dst, int len)
{
    int i;
    for (i = 0; i < len; i++) {
        int hi = hexval(src[i * 2]), lo = hexval(src[i * 2 + 1]);
        if (hi < 0 || lo < 0)
            return -1;
        dst[i] = (uint8_t)((hi << 4) | lo);
    }
    return len;
}

void gdb_rsp_init(struct gdb_rsp *s, struct gdb_mbox *mb)
{
    memset(s, 0, sizeof(*s));
    s->mb = mb;
}

// ---------------------------------------------------------------- target ops

static int read_regs(struct gdb_rsp *s, uint32_t regs[GDB_NUM_REGS])
{
    if (gdb_mbox_cmd(s->mb, GDB_CMD_RDREGS, 0, 0, 0) != GDB_STATUS_OK)
        return -1;
    gdb_mbox_read_data(s->mb, regs, 0, GDB_NUM_REGS * 4);
    return 0;
}

// The engine transfers whole 32bit words from a word-aligned base, so a ragged
// request is widened here and sliced afterwards.
static int read_mem(struct gdb_rsp *s, uint32_t addr, int len, uint8_t *out)
{
    uint32_t base = addr & ~3u;
    int lead = (int)(addr - base);
    int total = (lead + len + 3) & ~3;

    if (total > GDB_DATA_MAX)
        return -1;
    if (gdb_mbox_cmd(s->mb, GDB_CMD_RDMEM, 0, base, (uint16_t)total)
        != GDB_STATUS_OK)
        return -1;

    {
        uint8_t buf[GDB_DATA_MAX];
        gdb_mbox_read_data(s->mb, buf, 0, total);
        memcpy(out, buf + lead, (size_t)len);
    }
    return 0;
}

// Writes start on a word boundary too. A misaligned start is squared up by
// pulling the leading bytes back off the target first; the engine handles a
// ragged tail itself with a read-modify-write on the last word.
static int write_mem(struct gdb_rsp *s, uint32_t addr, int len,
                     const uint8_t *in)
{
    uint32_t base = addr & ~3u;
    int lead = (int)(addr - base);
    int total = lead + len;
    uint8_t buf[GDB_DATA_MAX];

    if (total > GDB_DATA_MAX)
        return -1;
    if (lead && read_mem(s, base, lead, buf) < 0)
        return -1;
    memcpy(buf + lead, in, (size_t)len);

    gdb_mbox_write_data(s->mb, buf, 0, total);
    return gdb_mbox_cmd(s->mb, GDB_CMD_WRMEM, 0, base, (uint16_t)total)
           == GDB_STATUS_OK ? 0 : -1;
}

static int set_comparator(struct gdb_rsp *s, int is_wp, int slot,
                          uint32_t addr, int enable, int rd, int wr)
{
    uint32_t arg = (uint32_t)(slot & 0xf) | (enable ? 0x10u : 0u);
    if (is_wp)
        arg |= (rd ? 0x20u : 0u) | (wr ? 0x40u : 0u);
    return gdb_mbox_cmd(s->mb, is_wp ? GDB_CMD_SETWP : GDB_CMD_SETBP,
                        arg, addr, 0) == GDB_STATUS_OK ? 0 : -1;
}

// ------------------------------------------------------------- stop replies

static int stop_reply(struct gdb_rsp *s, char *reply, int max)
{
    int reason = gdb_mbox_stop_reason(s->mb);
    const char *extra = "";
    char watch[32];

    switch (reason) {
    case GDB_STOP_BP:
        extra = "hwbreak:;";
        break;
    case GDB_STOP_WP: {
        // gdb wants the watched address; the engine only reports which kind
        // of stop it was, so recover it from whichever slot is armed
        int i;
        watch[0] = 0;
        for (i = 0; i < GDB_WP_COUNT; i++)
            if (s->wp[i].used) {
                snprintf(watch, sizeof(watch), "watch:%x;", s->wp[i].addr);
                break;
            }
        extra = watch;
        break;
    }
    default:
        break;
    }

    // SIGTRAP for every stop we generate
    if (snprintf(reply, (size_t)max, "T05%s", extra) >= max)
        return 0;
    return (int)strlen(reply);
}

// ---------------------------------------------------------------- dispatch

static int reply_ok(char *reply, int max)
{
    (void)max;
    strcpy(reply, "OK");
    return 2;
}

static int reply_err(char *reply, int max, int code)
{
    snprintf(reply, (size_t)max, "E%02x", code);
    return (int)strlen(reply);
}

static int handle_query(struct gdb_rsp *s, const char *pkt, char *reply,
                        int max)
{
    (void)s;
    if (!strncmp(pkt, "qSupported", 10)) {
        // hwbreak+ tells gdb it may use Z1 rather than patching memory, which
        // is the only way to break in ROM
        snprintf(reply, (size_t)max,
                 "PacketSize=%x;hwbreak+;swbreak+;qXfer:features:read-",
                 GDB_PKT_MAX);
        return (int)strlen(reply);
    }
    if (!strcmp(pkt, "qAttached"))
        { strcpy(reply, "1"); return 1; }
    if (!strcmp(pkt, "qC"))
        { strcpy(reply, "QC1"); return 3; }
    if (!strcmp(pkt, "qfThreadInfo"))
        { strcpy(reply, "m1"); return 2; }
    if (!strcmp(pkt, "qsThreadInfo"))
        { strcpy(reply, "l"); return 1; }
    if (!strncmp(pkt, "qRcmd", 5))
        return reply_ok(reply, max);
    reply[0] = 0;
    return 0;                        // unknown query: empty reply
}

static int handle_z(struct gdb_rsp *s, const char *pkt, char *reply, int max)
{
    int insert = pkt[0] == 'Z';
    int type   = pkt[1] - '0';
    uint32_t addr = 0;
    const char *p = pkt + 3;         // skip 'Z', type, ','
    int is_wp, rd, wr, i;

    if (pkt[2] != ',' || !gdb_hex2int(p, &p, &addr))
        return reply_err(reply, max, 22);

    switch (type) {
    case 0: case 1: is_wp = 0; rd = 0; wr = 0; break;   // sw/hw breakpoint
    case 2:         is_wp = 1; rd = 0; wr = 1; break;   // write watchpoint
    case 3:         is_wp = 1; rd = 1; wr = 0; break;   // read watchpoint
    case 4:         is_wp = 1; rd = 1; wr = 1; break;   // access watchpoint
    default:
        reply[0] = 0;                // unsupported type: empty reply
        return 0;
    }

    {
        struct gdb_bpslot *tab = is_wp ? s->wp : s->bp;
        int n = is_wp ? GDB_WP_COUNT : GDB_BP_COUNT;

        if (insert) {
            for (i = 0; i < n; i++)
                if (!tab[i].used)
                    break;
            if (i == n)
                return reply_err(reply, max, 28);   // out of comparators
            if (set_comparator(s, is_wp, i, addr, 1, rd, wr) < 0)
                return reply_err(reply, max, 5);
            tab[i].addr = addr;
            tab[i].used = 1;
            tab[i].kind = type;
        } else {
            for (i = 0; i < n; i++)
                if (tab[i].used && tab[i].addr == addr && tab[i].kind == type)
                    break;
            if (i == n)
                return reply_ok(reply, max);        // never set: nothing to do
            if (set_comparator(s, is_wp, i, addr, 0, 0, 0) < 0)
                return reply_err(reply, max, 5);
            tab[i].used = 0;
        }
    }
    return reply_ok(reply, max);
}

int gdb_rsp_packet(struct gdb_rsp *s, const char *pkt, char *reply, int max)
{
    uint32_t regs[GDB_NUM_REGS];

    switch (pkt[0]) {

    case '?':
        // gdb expects the target stopped at attach
        if (!gdb_mbox_halted(s->mb))
            gdb_mbox_cmd(s->mb, GDB_CMD_HALT, 0, 0, 0);
        return stop_reply(s, reply, max);

    case 'g': {
        uint8_t g[GDB_G_BYTES];
        int i;

        if (read_regs(s, regs) < 0)
            return reply_err(reply, max, 5);
        memset(g, 0, sizeof(g));
        for (i = 0; i < 16; i++)
            memcpy(g + i * 4, &regs[i], 4);
        memcpy(g + 164, &regs[16], 4);          // cpsr, past the FPA slots
        if (GDB_G_BYTES * 2 + 1 > max)
            return reply_err(reply, max, 5);
        gdb_mem2hex(g, reply, GDB_G_BYTES);
        return GDB_G_BYTES * 2;
    }

    case 'G': {
        uint8_t g[GDB_G_BYTES];
        int i;

        if ((int)strlen(pkt + 1) < GDB_G_BYTES * 2 ||
            gdb_hex2mem(pkt + 1, g, GDB_G_BYTES) < 0)
            return reply_err(reply, max, 22);
        for (i = 0; i < 16; i++) {
            uint32_t v;
            memcpy(&v, g + i * 4, 4);
            if (gdb_mbox_cmd(s->mb, GDB_CMD_WRREG, v, (uint32_t)i, 0)
                != GDB_STATUS_OK)
                return reply_err(reply, max, 5);
        }
        {
            uint32_t v;
            memcpy(&v, g + 164, 4);
            gdb_mbox_cmd(s->mb, GDB_CMD_WRREG, v, 16, 0);
        }
        return reply_ok(reply, max);
    }

    case 'p': {
        uint32_t n = 0;
        if (!gdb_hex2int(pkt + 1, NULL, &n))
            return reply_err(reply, max, 22);
        if (read_regs(s, regs) < 0)
            return reply_err(reply, max, 5);
        if (n < 16)
            gdb_mem2hex((const uint8_t *)&regs[n], reply, 4);
        else if (n == GDB_REG_CPSR)
            gdb_mem2hex((const uint8_t *)&regs[16], reply, 4);
        else
            strcpy(reply, "00000000");          // FPA slots we do not model
        return (int)strlen(reply);
    }

    case 'P': {
        uint32_t n = 0, v = 0;
        const char *p = pkt + 1;
        uint8_t raw[4];

        if (!gdb_hex2int(p, &p, &n) || *p != '=' ||
            gdb_hex2mem(p + 1, raw, 4) < 0)
            return reply_err(reply, max, 22);
        memcpy(&v, raw, 4);
        if (n >= 16 && n != GDB_REG_CPSR)
            return reply_ok(reply, max);        // silently accept FPA writes
        if (n == GDB_REG_CPSR)
            n = 16;
        return gdb_mbox_cmd(s->mb, GDB_CMD_WRREG, v, n, 0) == GDB_STATUS_OK
               ? reply_ok(reply, max) : reply_err(reply, max, 5);
    }

    case 'm': {
        uint32_t addr = 0, len = 0;
        const char *p = pkt + 1;
        uint8_t buf[GDB_DATA_MAX];

        if (!gdb_hex2int(p, &p, &addr) || *p != ',' ||
            !gdb_hex2int(p + 1, NULL, &len))
            return reply_err(reply, max, 22);
        if (len == 0 || len > GDB_DATA_MAX - 4 || (int)(len * 2 + 1) > max)
            return reply_err(reply, max, 22);
        if (read_mem(s, addr, (int)len, buf) < 0)
            return reply_err(reply, max, 5);
        gdb_mem2hex(buf, reply, (int)len);
        return (int)len * 2;
    }

    case 'M': {
        uint32_t addr = 0, len = 0;
        const char *p = pkt + 1;
        uint8_t buf[GDB_DATA_MAX];

        if (!gdb_hex2int(p, &p, &addr) || *p != ',' ||
            !gdb_hex2int(p + 1, &p, &len) || *p != ':')
            return reply_err(reply, max, 22);
        if (len == 0 || len > GDB_DATA_MAX - 4)
            return reply_err(reply, max, 22);
        if (gdb_hex2mem(p + 1, buf, (int)len) < 0)
            return reply_err(reply, max, 22);
        return write_mem(s, addr, (int)len, buf) == 0
               ? reply_ok(reply, max) : reply_err(reply, max, 5);
    }

    case 'c':
    case 'C':
        gdb_mbox_cmd(s->mb, GDB_CMD_CONT, 0, 0, 0);
        s->running = 1;
        return 0;

    case 's':
    case 'S':
        gdb_mbox_cmd(s->mb, GDB_CMD_STEP, 0, 0, 0);
        s->running = 1;
        return 0;

    case 'v':
        if (!strcmp(pkt, "vCont?")) {
            strcpy(reply, "vCont;c;C;s;S");
            return (int)strlen(reply);
        }
        if (!strncmp(pkt, "vCont;", 6)) {
            char act = pkt[6];
            gdb_mbox_cmd(s->mb, (act == 's' || act == 'S')
                                ? GDB_CMD_STEP : GDB_CMD_CONT, 0, 0, 0);
            s->running = 1;
            return 0;
        }
        reply[0] = 0;
        return 0;

    case 'H':                                   // thread select: single core
    case 'T':
        return reply_ok(reply, max);

    case 'D':
        // leave the core running, and drop every comparator on the way out
        {
            int i;
            for (i = 0; i < GDB_BP_COUNT; i++)
                if (s->bp[i].used) {
                    set_comparator(s, 0, i, 0, 0, 0, 0);
                    s->bp[i].used = 0;
                }
            for (i = 0; i < GDB_WP_COUNT; i++)
                if (s->wp[i].used) {
                    set_comparator(s, 1, i, 0, 0, 0, 0);
                    s->wp[i].used = 0;
                }
        }
        gdb_mbox_cmd(s->mb, GDB_CMD_CONT, 0, 0, 0);
        s->detached = 1;
        return reply_ok(reply, max);

    case 'k':
        gdb_mbox_cmd(s->mb, GDB_CMD_CONT, 0, 0, 0);
        s->detached = 1;
        reply[0] = 0;
        return 0;

    case 'q':
    case 'Q':
        return handle_query(s, pkt, reply, max);

    case 'Z':
    case 'z':
        return handle_z(s, pkt, reply, max);

    default:
        reply[0] = 0;                           // unsupported: empty reply
        return 0;
    }
}

int gdb_rsp_poll(struct gdb_rsp *s, char *reply, int max)
{
    if (!s->running)
        return 0;
    if (!gdb_mbox_halted(s->mb))
        return 0;
    s->running = 0;
    return stop_reply(s, reply, max);
}

void gdb_rsp_interrupt(struct gdb_rsp *s)
{
    gdb_mbox_cmd(s->mb, GDB_CMD_HALT, 0, 0, 0);
}
