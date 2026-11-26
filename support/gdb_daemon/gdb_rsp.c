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

#include <errno.h>
#include <inttypes.h>
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
        if (v > UINT32_MAX >> 4)
            return 0;
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
        int hi = hexval(src[i * 2]), lo;
        if (hi < 0 || (lo = hexval(src[i * 2 + 1])) < 0)
            return -1;
        dst[i] = (uint8_t)((hi << 4) | lo);
    }
    return len;
}

void gdb_rsp_init(struct gdb_rsp *s, struct gdb_mbox *mb)
{
    memset(s, 0, sizeof(*s));
    s->mb = mb;
    s->continue_core = -1;
}

void gdb_rsp_disconnect(struct gdb_rsp *s)
{
    int i;

    if (s->detached)
        return;
    for (i = 0; i < GDB_BP_COUNT; i++)
        if (s->bp[i].used)
            gdb_mbox_set_cmp(s->mb, 0, i, 0, 0, 0, 0, 0, 0);
    for (i = 0; i < GDB_WP_COUNT; i++)
        if (s->wp[i].used)
            gdb_mbox_set_cmp(s->mb, 1, i, 0, 0, 0, 0, 0, 0);
    gdb_mbox_cmd(s->mb, GDB_CMD_CONT, 0, 0, 0);
    s->detached = 1;
}

// ------------------------------------------------------------- stop replies

static int stop_reply(struct gdb_rsp *s, char *reply, int max)
{
    struct gdb_mbox *mb = s->mb;
    int reason = gdb_mbox_stop_reason(mb), n;
    const char *extra = "";
    char watch[32], thread[24] = "";

    if (reason == GDB_STOP_BP) {
        extra = "hwbreak:;";
    } else if (reason == GDB_STOP_WP) {
        struct gdb_state state;
        int slot = gdb_mbox_stop_slot(mb);
        if (slot < GDB_WP_COUNT && gdb_mbox_read_state(mb, &state) == GDB_STATUS_OK) {
            uint32_t access = mb->wp_args[slot] & (GDB_WP_READ | GDB_WP_WRITE);
            const char *kind = access == GDB_WP_READ ? "rwatch" :
                               access == GDB_WP_WRITE ? "watch" : "awatch";
            snprintf(watch, sizeof(watch), "%s:%" PRIx32 ";",
                     kind, (uint32_t)(state.frames_wp_addr >> 32));
            extra = watch;
        }
    }
    if (gdb_mbox_dual_core(mb))
        snprintf(thread, sizeof(thread), "thread:%d;", gdb_mbox_stop_core(mb) + 1);

    // SIGTRAP for every stop we generate.
    n = snprintf(reply, (size_t)max, "T05%s%s", extra, thread);
    return n >= 0 && n < max ? n : 0;
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

static int monitor_uint(const char *s, int base, uint64_t max, uint64_t *out)
{
    char *end;
    unsigned long long v;

    if (!s || hexval(*s) < 0)
        return -1;
    if (base == 0)
        base = s[0] == '0' && (s[1] == 'x' || s[1] == 'X') ? 16 : 10;
    errno = 0;
    v = strtoull(s, &end, base);
    if (*end || errno || v > max)
        return -1;
    *out = (uint64_t)v;
    return 0;
}

static int monitor_cmd(struct gdb_rsp *s, const char *hex, char *reply, int max)
{
    struct gdb_mbox *mb = s->mb;
    char cmd[96], *argv[4], *p;
    char text[(GDB_PKT_MAX - 1) / 2 + 1];
    size_t len = strlen(hex);
    int argc = 0;
    uint8_t op;
    uint64_t a = 0, b = 0, addr = 0;

    if (len % 2 || len / 2 >= sizeof(cmd) ||
        gdb_hex2mem(hex, (uint8_t *)cmd, (int)(len / 2)) < 0 ||
        memchr(cmd, '\0', len / 2))
        return reply_err(reply, max, 22);
    cmd[len / 2] = 0;
    p = strtok(cmd, " \t");
    while (p && argc < 4) {
        argv[argc++] = p;
        p = strtok(NULL, " \t");
    }
    if (argc == 0 || argc > 3)
        return reply_err(reply, max, 22);

    if (argc == 1 && (!strcmp(argv[0], "cycles") || !strcmp(argv[0], "state"))) {
        struct gdb_state state;
        if (gdb_mbox_read_state(mb, &state) != GDB_STATUS_OK)
            return reply_err(reply, max, 5);
        if (!strcmp(argv[0], "cycles")) {
            snprintf(text, sizeof(text), "total_cycles=%" PRIu64
                     " insns_c0=%" PRIu64 " insns_c1=%" PRIu64 " frames=%" PRIu32 "\n",
                     state.cycles, state.insns[0], state.insns[1],
                     (uint32_t)state.frames_wp_addr);
        } else {
            int core = (int)((state.state >> 1) & 1);
            const struct gdb_core_state *cs = &state.core[core];
            snprintf(text, sizeof(text),
                     "core=%d PC=%08" PRIx32 " CPSR=%08" PRIx32
                     " VCOUNT=%u DISPSTAT=%04x\n"
                     "IE=%04x IF=%04x IME=%u DMA=%u link=%02x%016" PRIx64
                     " pins=%02x mem_info=%08" PRIx32 "\n",
                     core, (uint32_t)cs->arch_fetch_pc, gdb_state_cpsr(&state),
                     (unsigned)(cs->bus_dispstat >> 48) & 0xffu,
                     (unsigned)(cs->bus_dispstat >> 32) & 0xffffu,
                     (unsigned)(cs->irq_mem >> 16) & 0xffffu,
                     (unsigned)cs->irq_mem & 0xffffu,
                     (unsigned)(cs->flags >> 48) & 1u,
                     (unsigned)(cs->flags >> 44) & 1u,
                     (unsigned)cs->flags & 0x7fu, cs->link_lo,
                     (unsigned)(cs->flags >> 8) & 0xffu,
                     (uint32_t)(cs->irq_mem >> 32));
        }
    } else if (argc == 1 && !strcmp(argv[0], "trace")) {
        struct gdb_trace trace;
        unsigned count, i;
        if (gdb_mbox_read_trace(mb, &trace) != GDB_STATUS_OK)
            return reply_err(reply, max, 5);
        count = (unsigned)trace.head & 0x7fu;
        if (count > GDB_TRACE_ENTRIES)
            return reply_err(reply, max, 5);
        len = (size_t)snprintf(text, sizeof(text), "trace (%u entries, oldest first)\n", count);
        for (i = 0; i < count; i++) {
            uint64_t e = trace.entry[i];
            len += (size_t)snprintf(text + len, sizeof(text) - len,
                                    "%02u PC=%08" PRIx32 " cycles=%u VCOUNT=%u IF=%04x\n",
                                    i, (uint32_t)e, (unsigned)(e >> 32) & 0xffu,
                                    (unsigned)(e >> 40) & 0xffu, (unsigned)(e >> 48));
        }
    } else {
        if ((!strcmp(argv[0], "stepc") || !strcmp(argv[0], "stepf")) && argc == 2 &&
            monitor_uint(argv[1], 0, UINT32_MAX, &a) == 0 && a) {
            op = argv[0][4] == 'c' ? GDB_CMD_STEP_CYCLES : GDB_CMD_STEP_FRAMES;
        } else if (!strcmp(argv[0], "stepl") && argc >= 2 &&
                   monitor_uint(argv[1], 0, 227, &a) == 0 &&
                   (argc == 2 || !strcmp(argv[2], "hblank"))) {
            op = GDB_CMD_STEP_LINE;
            a |= argc == 3 ? 0x100u : 0;
        } else if (!strcmp(argv[0], "breakc") && argc == 2 &&
                   monitor_uint(argv[1], 0, UINT64_MAX, &addr) == 0) {
            op = GDB_CMD_BREAK_CYCLE;
        } else if (!strcmp(argv[0], "breakev") && argc == 2 &&
                   monitor_uint(argv[1], 16, 0x3f, &a) == 0) {
            op = GDB_CMD_BREAK_EVENT;
        } else if (!strcmp(argv[0], "core") && argc == 2 &&
                   monitor_uint(argv[1], 10, 1, &a) == 0) {
            op = GDB_CMD_SET_CORE;
        } else if (!strcmp(argv[0], "input") && argc == 3 &&
                   monitor_uint(argv[1], 16, 0x3ff, &a) == 0 &&
                   monitor_uint(argv[2], 16, 0x3ff, &b) == 0) {
            op = GDB_CMD_SET_INPUT;
            a = (a << 16) | b;
        } else if (!strcmp(argv[0], "reset") &&
                   (argc == 1 || (argc == 2 && !strcmp(argv[1], "halt")))) {
            op = GDB_CMD_RESET;
            a = argc == 2;
        } else {
            return reply_err(reply, max, 22);
        }
        if (gdb_mbox_cmd(mb, op, (uint32_t)a, addr, 0) != GDB_STATUS_OK)
            return reply_err(reply, max, 5);
        return reply_ok(reply, max);
    }

    if (s->console)
        return s->console(s->console_ctx, text) == 0
               ? reply_ok(reply, max) : reply_err(reply, max, 5);
    len = strlen(text);
    if (len * 2 + 1 > (size_t)max)
        return reply_err(reply, max, 5);
    gdb_mem2hex((const uint8_t *)text, reply, (int)len);
    return (int)(len * 2);
}

// RSP thread IDs are 1-based; zero and -1 designate no specific core.
static int thread_core(struct gdb_rsp *s, const char *id)
{
    if (!strcmp(id, "0") || !strcmp(id, "-1")) return -1;
    if (!strcmp(id, "1")) return 0;
    if (!strcmp(id, "2") && gdb_mbox_dual_core(s->mb)) return 1;
    return -2;
}

static int run_target(struct gdb_rsp *s, uint8_t op, int core, char *reply, int max)
{
    if (core >= 0 && gdb_mbox_active_core(s->mb) != core &&
        gdb_mbox_cmd(s->mb, GDB_CMD_SET_CORE, (uint32_t)core, 0, 0) != GDB_STATUS_OK)
        return reply_err(reply, max, 5);
    if (gdb_mbox_cmd(s->mb, op, 0, 0, 0) != GDB_STATUS_OK)
        return reply_err(reply, max, 5);
    s->running = 1;
    return 0;
}

static int handle_vcont(struct gdb_rsp *s, const char *p, char *reply, int max)
{
    uint8_t op = GDB_CMD_CONT;
    int core = -1, have_step = 0;

    // All-stop hardware: a step takes precedence over continue actions. Only
    // one core can be the source of step events even when both run.
    do {
        int step, which = -1;
        switch (*p++) {
        case 'c': case 'C': step = 0; break;
        case 's': case 'S': step = 1; break;
        default: return reply_err(reply, max, 22);
        }
        if (p[-1] == 'C' || p[-1] == 'S') {
            if (!gdb_hex2int(p, &p, NULL))
                return reply_err(reply, max, 22);
        }
        if (*p == ':') {
            const char *end = p + 1 + strcspn(p + 1, ";");
            char id[3];
            if (end - (p + 1) >= (int)sizeof(id))
                return reply_err(reply, max, 22);
            memcpy(id, p + 1, (size_t)(end - p - 1));
            id[end - p - 1] = 0;
            which = thread_core(s, id);
            if (which < -1)
                return reply_err(reply, max, 22);
            p = end;
        }
        if (*p && *p != ';')
            return reply_err(reply, max, 22);
        if (step) {
            if (have_step)
                return reply_err(reply, max, 22);
            have_step = 1;
            op = GDB_CMD_STEP;
            core = which;
        } else if (!have_step && core < 0) {
            core = which;
        }
        if (*p == ';')
            p++;
    } while (*p);

    return run_target(s, op, core, reply, max);
}

static int handle_query(struct gdb_rsp *s, const char *pkt, char *reply,
                        int max)
{
    struct gdb_mbox *mb = s->mb;
    if (!strncmp(pkt, "qSupported", 10)) {
        // hwbreak+ tells gdb it may use Z1 rather than patching memory, which
        // is the only way to break in ROM
        snprintf(reply, (size_t)max,
                 "PacketSize=2000;qRcmd+;vContSupported+;hwbreak+;swbreak+");
        return (int)strlen(reply);
    }
    if (!strcmp(pkt, "qAttached"))
        { strcpy(reply, "1"); return 1; }
    if (!strcmp(pkt, "qC"))
        return snprintf(reply, (size_t)max, "QC%d", gdb_mbox_active_core(mb) + 1);
    if (!strcmp(pkt, "qfThreadInfo"))
        return snprintf(reply, (size_t)max, "%s", gdb_mbox_dual_core(mb) ? "m1,2" : "m1");
    if (!strcmp(pkt, "qsThreadInfo"))
        { strcpy(reply, "l"); return 1; }
    if (!strncmp(pkt, "qRcmd,", 6))
        return monitor_cmd(s, pkt + 6, reply, max);
    reply[0] = 0;
    return 0;                        // unknown query: empty reply
}

static int handle_z(struct gdb_rsp *s, const char *pkt, char *reply, int max)
{
    int insert = pkt[0] == 'Z';
    int type   = pkt[1] - '0';
    uint32_t addr = 0;
    const char *p;
    int is_wp, rd, wr, i;

    if (!pkt[1] || pkt[2] != ',')
        return reply_err(reply, max, 22);
    p = pkt + 3;
    if (!gdb_hex2int(p, &p, &addr) || *p != ',')
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
        const uint32_t *args = is_wp ? s->mb->wp_args : s->mb->bp_args;
        int n = is_wp ? GDB_WP_COUNT : GDB_BP_COUNT;

        if (insert) {
            int core = gdb_mbox_active_core(s->mb);
            int status;
            // Ordinary GDB breakpoint packets have no thread qualifier;
            // make them global in this all-stop target.
            int both = gdb_mbox_dual_core(s->mb);
            for (i = 0; i < n; i++)
                if (tab[i].used && tab[i].addr == addr && tab[i].kind == type)
                    return reply_ok(reply, max);
            for (i = 0; i < n; i++)
                if (!(args[i] & GDB_CMP_ENABLE))
                    break;
            if (i == n)
                return reply_err(reply, max, 28);   // out of comparators
            status = gdb_mbox_set_cmp(s->mb, is_wp, i, addr, 1, rd, wr, core, both);
            // With a 32-bit address and a valid core/slot encoding, BADARG
            // means this profile implements fewer comparators than our table.
            if (status == GDB_STATUS_BADARG)
                return reply_err(reply, max, 28);
            if (status != GDB_STATUS_OK)
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
            if (gdb_mbox_set_cmp(s->mb, is_wp, i, addr, 0, rd, wr,
                                 (args[i] & (is_wp ? GDB_WP_CORE : GDB_BP_CORE)) != 0,
                                 (args[i] & (is_wp ? GDB_WP_BOTH : GDB_BP_BOTH)) != 0)
                != GDB_STATUS_OK)
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
        if (!gdb_mbox_halted(s->mb) &&
            gdb_mbox_cmd(s->mb, GDB_CMD_HALT, 0, 0, 0) != GDB_STATUS_OK)
            return reply_err(reply, max, 5);
        return stop_reply(s, reply, max);

    case 'g': {
        uint8_t g[GDB_G_BYTES];
        int i;

        if (gdb_mbox_read_regs(s->mb, regs) != GDB_STATUS_OK)
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
            if (gdb_mbox_cmd(s->mb, GDB_CMD_WRREG, v, 16, 0) != GDB_STATUS_OK)
                return reply_err(reply, max, 5);
        }
        return reply_ok(reply, max);
    }

    case 'p': {
        uint32_t n = 0;
        if (!gdb_hex2int(pkt + 1, NULL, &n))
            return reply_err(reply, max, 22);
        if (gdb_mbox_read_regs(s->mb, regs) != GDB_STATUS_OK)
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
        if (len > GDB_DATA_MAX || (int)(len * 2 + 1) > max)
            return reply_err(reply, max, 22);
        if (gdb_mbox_read_mem(s->mb, addr, (int)len, buf) != GDB_STATUS_OK)
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
        if (len > GDB_DATA_MAX)
            return reply_err(reply, max, 22);
        if (gdb_hex2mem(p + 1, buf, (int)len) < 0)
            return reply_err(reply, max, 22);
        return gdb_mbox_write_mem(s->mb, addr, (int)len, buf) == GDB_STATUS_OK
               ? reply_ok(reply, max) : reply_err(reply, max, 5);
    }

    case 'c':
    case 'C':
        return run_target(s, GDB_CMD_CONT, s->continue_core, reply, max);

    case 's':
    case 'S':
        return run_target(s, GDB_CMD_STEP, s->continue_core, reply, max);

    case 'v':
        if (!strcmp(pkt, "vCont?")) {
            strcpy(reply, "vCont;c;C;s;S");
            return (int)strlen(reply);
        }
        if (!strncmp(pkt, "vCont;", 6))
            return handle_vcont(s, pkt + 6, reply, max);
        reply[0] = 0;
        return 0;

    case 'H': {
        int core;
        if (pkt[1] != 'g' && pkt[1] != 'c')
            return reply_err(reply, max, 22);
        core = thread_core(s, pkt + 2);
        if (core < -1)
            return reply_err(reply, max, 22);
        if (core >= 0 && gdb_mbox_cmd(s->mb, GDB_CMD_SET_CORE, (uint32_t)core, 0, 0)
                         != GDB_STATUS_OK)
            return reply_err(reply, max, 5);
        if (pkt[1] == 'c')
            s->continue_core = core;
        return reply_ok(reply, max);
    }
    case 'T':
        return thread_core(s, pkt + 1) >= 0 ? reply_ok(reply, max) : reply_err(reply, max, 22);

    case 'D':
        gdb_rsp_disconnect(s);
        return reply_ok(reply, max);

    case 'k':
        gdb_rsp_disconnect(s);
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
