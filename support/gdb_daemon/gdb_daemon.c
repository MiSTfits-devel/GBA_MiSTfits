// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// gdb_daemon: HPS-side half of the GBA core's gdb stub. The FPGA
// (rtl/gba_gdb.vhd) owns the debug engine -- halting the ARM7TDMI, the
// breakpoint and watchpoint comparators, and access to registers and the GBA
// address space -- and exchanges commands with this process through a mailbox
// in DDR3. This end speaks GDB RSP and a separate JSON control protocol.
//
//   arm-none-eabi-gdb game.elf
//   (gdb) target remote <mister>:2345
//
// Same split rfu_daemon uses: transport and state machine in the fabric,
// protocol and sockets up here.
#define _POSIX_C_SOURCE 200809L

#include "gdb_mbox.h"
#include "gdb_proto.h"
#include "gdb_rsp.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEF_PORT       2345
#define DEF_JSON_PORT  2346
#define POLL_MS        5
#define JSON_LINE_MAX  (GDB_PKT_MAX + 256)

static int verbose;

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    if (!verbose)
        return;
    va_start(ap, fmt);
    fprintf(stderr, "gdb: ");
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

static int set_nonblock(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int listen_on(int port)
{
    struct sockaddr_in me;
    int sock, on = 1;

    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return -1;
    }
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    memset(&me, 0, sizeof(me));
    me.sin_family      = AF_INET;
    me.sin_addr.s_addr = htonl(INADDR_ANY);
    me.sin_port        = htons((uint16_t)port);
    if (bind(sock, (struct sockaddr *)&me, sizeof(me)) < 0) {
        perror("bind");
        close(sock);
        return -1;
    }
    if (listen(sock, 1) < 0 || set_nonblock(sock) < 0) {
        perror("configure listener");
        close(sock);
        return -1;
    }
    return sock;
}

// Each socket has its own input cursor and one response in flight. A socket
// that stops reading or pauses halfway through a packet cannot block the other.
struct client {
    int fd;
    unsigned char in[1024];
    size_t in_pos, in_len;
    char out[JSON_LINE_MAX];
    size_t out_pos, out_len;
};

static int queuef(struct client *c, const char *fmt, ...)
{
    size_t space = sizeof(c->out) - c->out_len;
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(c->out + c->out_len, space, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= space)
        return -1;
    c->out_len += (size_t)n;
    return 0;
}

static int queue_packet(struct client *c, const char *body, int len)
{
    logmsg("-> %s\n", body);
    return queuef(c, "$%s#%02x", body, (unsigned)gdb_checksum(body, len));
}

static int queue_console(void *ctx, const char *text)
{
    struct client *c = ctx;
    char *body = c->out + c->out_len + 1;
    size_t len = strlen(text);
    int encoded = (int)(len * 2 + 1);

    if (encoded > GDB_PKT_MAX || (size_t)encoded + 5 > sizeof(c->out) - c->out_len)
        return -1;
    body[-1] = '$';
    body[0] = 'O';
    gdb_mem2hex((const uint8_t *)text, body + 1, (int)len);
    logmsg("-> %s\n", body);
    snprintf(body + encoded, 4, "#%02x", (unsigned)gdb_checksum(body, encoded));
    c->out_len += (size_t)encoded + 4;
    return 0;
}

struct framer {
    char body[GDB_REPLY_MAX];
    int len, state, escaped, oversized;
    uint8_t checksum;
    char check[3];
};

static int rsp_byte(struct client *c, struct gdb_rsp *rsp, struct framer *f,
                    unsigned char b)
{
    switch (f->state) {
    case 0:
        if (b == 3) {
            logmsg("<- interrupt\n");
            gdb_rsp_interrupt(rsp);
        } else if (b == '$') {
            f->state = 1;
            f->len = f->escaped = f->oversized = f->checksum = 0;
        }
        return 0;
    case 1:
        if (!f->escaped && b == '#') {
            f->state = 2;
            return 0;
        }
        f->checksum += b;
        if (f->escaped) {
            b ^= 0x20;
            f->escaped = 0;
        } else if (b == '}') {
            f->escaped = 1;
            return 0;
        }
        if (f->len < GDB_PKT_MAX)
            f->body[f->len++] = (char)b;
        else
            f->oversized = 1;
        return 0;
    case 2:
        f->check[0] = (char)b;
        f->state = 3;
        return 0;
    default: {
        char reply[GDB_REPLY_MAX];
        uint32_t want;
        int len;

        reply[0] = 0;
        f->check[1] = (char)b;
        f->check[2] = 0;
        f->state = 0;
        if (f->oversized || gdb_hex2int(f->check, NULL, &want) != 2 ||
            want != f->checksum)
            return queuef(c, "-");
        if (queuef(c, "+") < 0)
            return -1;
        f->body[f->len] = 0;
        logmsg("<- %s\n", f->body);
        len = gdb_rsp_packet(rsp, f->body, reply, sizeof(reply));
        if (len > 0 || (!rsp->running && !rsp->detached))
            return queue_packet(c, reply, len);
        return 0;
    }
    }
}

// Control requests are a flat JSON object of strings, unsigned integers, and
// booleans. String values are decoded in-place in the line buffer.
struct json_field {
    const char *key, *text;
    uint64_t number;
    enum { JSON_STRING, JSON_UINT, JSON_BOOL } type;
};

static char *json_space(char *p)
{
    return p + strspn(p, " \t\r");
}

static int json_hex4(char **p, unsigned *cp)
{
    uint8_t hex[2];
    if (gdb_hex2mem(*p, hex, 2) < 0)
        return -1;
    *cp = ((unsigned)hex[0] << 8) | hex[1];
    *p += 4;
    return 0;
}

static char *json_string(char **p)
{
    char *s = *p + 1, *d = s, *q = s;

    while (*q && *q != '"') {
        unsigned char c = (unsigned char)*q++;
        if (c < 0x20)
            return NULL;
        if (c != '\\') {
            *d++ = (char)c;
            continue;
        }
        switch (*q++) {
        case '"':  *d++ = '"';  break;
        case '\\': *d++ = '\\'; break;
        case '/':  *d++ = '/';  break;
        case 'b':  *d++ = '\b'; break;
        case 'f':  *d++ = '\f'; break;
        case 'n':  *d++ = '\n'; break;
        case 'r':  *d++ = '\r'; break;
        case 't':  *d++ = '\t'; break;
        case 'u': {
            unsigned cp, low;
            if (json_hex4(&q, &cp) < 0 || cp == 0)
                return NULL;
            if (cp >= 0xd800 && cp <= 0xdbff) {
                if (q[0] != '\\' || q[1] != 'u')
                    return NULL;
                q += 2;
                if (json_hex4(&q, &low) < 0 || low < 0xdc00 || low > 0xdfff)
                    return NULL;
                cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
            } else if (cp >= 0xdc00 && cp <= 0xdfff) {
                return NULL;
            }
            if (cp < 0x80) {
                *d++ = (char)cp;
            } else if (cp < 0x800) {
                *d++ = (char)(0xc0 | (cp >> 6));
                *d++ = (char)(0x80 | (cp & 0x3f));
            } else {
                if (cp >= 0x10000) {
                    *d++ = (char)(0xf0 | (cp >> 18));
                    *d++ = (char)(0x80 | ((cp >> 12) & 0x3f));
                } else {
                    *d++ = (char)(0xe0 | (cp >> 12));
                }
                *d++ = (char)(0x80 | ((cp >> 6) & 0x3f));
                *d++ = (char)(0x80 | (cp & 0x3f));
            }
            break;
        }
        default:
            return NULL;
        }
    }
    if (*q != '"')
        return NULL;
    *d = 0;
    *p = q + 1;
    return s;
}

static struct json_field *json_find(struct json_field *fields, const char *key)
{
    for (; fields->key; fields++)
        if (!strcmp(fields->key, key))
            return fields;
    return NULL;
}

static int json_parse(char *p, struct json_field *fields, size_t max)
{
    size_t n = 0;
    p = json_space(p);
    if (*p++ != '{')
        return -1;
    p = json_space(p);
    if (*p == '}')
        return *json_space(p + 1) ? -1 : 0;
    for (;;) {
        struct json_field *f = &fields[n];
        const char *key;

        if (*p != '"' || n == max || !(key = json_string(&p)) || json_find(fields, key))
            return -1;
        f->key = key;
        p = json_space(p);
        if (*p++ != ':')
            return -1;
        p = json_space(p);
        if (*p == '"') {
            f->type = JSON_STRING;
            f->text = json_string(&p);
            if (!f->text)
                return -1;
        } else if (!strncmp(p, "true", 4) || !strncmp(p, "false", 5)) {
            f->type = JSON_BOOL;
            f->number = *p == 't';
            p += f->number ? 4 : 5;
        } else if (*p >= '0' && *p <= '9') {
            f->type = JSON_UINT;
            if (*p == '0' && p[1] >= '0' && p[1] <= '9')
                return -1;
            do {
                unsigned digit = (unsigned)(*p++ - '0');
                if (f->number > (UINT64_MAX - digit) / 10)
                    return -1;
                f->number = f->number * 10 + digit;
            } while (*p >= '0' && *p <= '9');
        } else {
            return -1;
        }
        p = json_space(p);
        if (*p == '}')
            return *json_space(p + 1) ? -1 : 0;
        if (*p++ != ',')
            return -1;
        ++n;
        p = json_space(p);
    }
}

static const char *json_text(struct json_field *fields, const char *key)
{
    struct json_field *f = json_find(fields, key);
    return f && f->type == JSON_STRING ? f->text : NULL;
}

// An absent field yields the supplied default. UINT64_MAX is a valid value
// when explicitly passed as an absolute cycle, so requiredness is separate.
static int json_uint(struct json_field *fields, const char *key, uint64_t max,
                     uint64_t fallback, uint64_t *out)
{
    struct json_field *f = json_find(fields, key);
    if (!f) {
        *out = fallback;
        return fallback <= max ? 0 : -1;
    }
    if (f->type != JSON_UINT || f->number > max)
        return -1;
    *out = f->number;
    return 0;
}

static int json_bool(struct json_field *fields, const char *key, int fallback)
{
    struct json_field *f = json_find(fields, key);
    if (!f)
        return fallback;
    // Accept true/false and numeric 1/0 (the corresponding mailbox bits).
    if ((f->type != JSON_BOOL && f->type != JSON_UINT) || f->number > 1)
        return -1;
    return (int)f->number;
}

static int json_error(struct client *c, const char *error)
{
    c->out_len = 0;
    return queuef(c, "{\"ok\":false,\"error\":\"%s\"}\n", error);
}

static int json_result(struct client *c, int status)
{
    const char *msg;
    switch (status) {
    case GDB_STATUS_OK:     return queuef(c, "{\"ok\":true}\n");
    case GDB_STATUS_BUSY:   msg = "target must be halted"; break;
    case GDB_STATUS_BADCMD: msg = "unknown mailbox opcode"; break;
    case GDB_STATUS_BADARG: msg = "invalid mailbox arguments"; break;
    default:                msg = "no valid mailbox acknowledgement"; break;
    }
    return queuef(c, "{\"ok\":false,\"status\":%d,\"error\":\"%s\"}\n", status, msg);
}

static int json_run_state(struct client *c, uint64_t state, uint64_t cycles)
{
    return queuef(c, "{\"ok\":true,\"halted\":%s,\"active_core\":%u,"
                  "\"dual_core\":%s,\"stop_reason\":%u,\"stop_slot\":%u,"
                  "\"stop_core\":%u,\"stop_pc\":%" PRIu32 ",\"total_cycles\":%" PRIu64,
                  state & 1 ? "true" : "false", (unsigned)(state >> 1) & 1u,
                  state & 4 ? "true" : "false", (unsigned)(state >> 4) & 0xfu,
                  (unsigned)(state >> 8) & 0xfu, (unsigned)(state >> 12) & 1u,
                  (uint32_t)(state >> 32), cycles);
}

static int json_state(struct client *c, struct gdb_mbox *mb)
{
    struct gdb_state state;
    unsigned i, cores;
    int status = gdb_mbox_read_state(mb, &state);
    if (status != GDB_STATUS_OK)
        return json_result(c, status);
    if (json_run_state(c, state.state, state.cycles) < 0 ||
        queuef(c, ",\"insns_c0\":%" PRIu64 ",\"insns_c1\":%" PRIu64
               ",\"frames\":%" PRIu32 ",\"wp_hit_addr\":%" PRIu32
               ",\"cpsr\":%" PRIu32 ",\"cores\":[", state.insns[0], state.insns[1],
               (uint32_t)state.frames_wp_addr, (uint32_t)(state.frames_wp_addr >> 32),
               gdb_state_cpsr(&state)) < 0)
        return -1;
    cores = state.state & 4 ? 2 : 1;
    for (i = 0; i < cores; i++) {
        const struct gdb_core_state *cs = &state.core[i];
        if (queuef(c, "%s{\"pc\":%" PRIu32 ",\"fetch_pc\":%" PRIu32
                   ",\"stall_pc\":%" PRIu32 ",\"opcode\":%" PRIu32
                   ",\"bus_addr\":%" PRIu32 ",\"dispstat\":%u,\"vcount\":%u,"
                   "\"ie\":%u,\"if\":%u,\"ime\":%u,\"dma\":%u,"
                   "\"link_state\":\"%02x%016" PRIx64 "\",\"link_pins\":%u,"
                   "\"mem_info\":%" PRIu32 ",\"flags\":%" PRIu64 "}",
                   i ? "," : "", (uint32_t)cs->arch_fetch_pc,
                   (uint32_t)(cs->arch_fetch_pc >> 32), (uint32_t)cs->stall_opcode,
                   (uint32_t)(cs->stall_opcode >> 32), (uint32_t)cs->bus_dispstat,
                   (unsigned)(cs->bus_dispstat >> 32) & 0xffffu,
                   (unsigned)(cs->bus_dispstat >> 48) & 0xffu,
                   (unsigned)(cs->irq_mem >> 16) & 0xffffu,
                   (unsigned)cs->irq_mem & 0xffffu, (unsigned)(cs->flags >> 48) & 1u,
                   (unsigned)(cs->flags >> 44) & 1u, (unsigned)cs->flags & 0x7fu,
                   cs->link_lo, (unsigned)(cs->flags >> 8) & 0xffu,
                   (uint32_t)(cs->irq_mem >> 32), cs->flags) < 0)
            return -1;
    }
    if (queuef(c, "],\"savestate\":[") < 0)
        return -1;
    for (i = 0; i < GDB_SS_WORDS; i++)
        if (queuef(c, "%s%" PRIu32, i ? "," : "",
                   (uint32_t)(state.savestate[i / 2] >> ((i % 2) * 32))) < 0)
            return -1;
    return queuef(c, "]}\n");
}

static int json_trace(struct client *c, struct gdb_mbox *mb)
{
    struct gdb_trace trace;
    unsigned i, count;
    int status = gdb_mbox_read_trace(mb, &trace);
    if (status != GDB_STATUS_OK)
        return json_result(c, status);
    count = (unsigned)trace.head & 0x7fu;
    if (count > GDB_TRACE_ENTRIES)
        return json_error(c, "invalid trace count");
    if (queuef(c, "{\"ok\":true,\"count\":%u,\"next\":%u,\"entries\":[",
               count, (unsigned)(trace.head >> 8) & 0x3fu) < 0)
        return -1;
    for (i = 0; i < count; i++) {
        uint64_t e = trace.entry[i];
        if (queuef(c, "%s{\"pc\":%" PRIu32 ",\"cycles\":%u,\"vcount\":%u,\"if\":%u}",
                   i ? "," : "", (uint32_t)e, (unsigned)(e >> 32) & 0xffu,
                   (unsigned)(e >> 40) & 0xffu, (unsigned)(e >> 48)) < 0)
            return -1;
    }
    return queuef(c, "]}\n");
}

static uint8_t expand5(unsigned c)
{
    return (uint8_t)((c << 3) | (c >> 2));
}

static int json_screenshot(struct client *c, int core, const char *path)
{
    uint8_t frame[GDB_FB_HEIGHT * GDB_FB_WIDTH * 2], row[GDB_FB_WIDTH * 3];
    FILE *file;
    int fd, x, y, ok;

    if (gdb_mbox_read_fb(core ? GDB_FB1_PHYS : GDB_FB0_PHYS, frame, sizeof(frame)) < 0)
        return json_error(c, "cannot read DDR3 framebuffer");
    // The daemon runs as root; never replace an existing file or follow a
    // symlink at the destination. The path is local to the daemon.
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0)
        return json_error(c, "cannot create screenshot (path must not exist)");
    file = fdopen(fd, "wb");
    if (!file) {
        close(fd);
        return json_error(c, "cannot open screenshot stream");
    }
    ok = fprintf(file, "P6\n%d %d\n255\n", GDB_FB_WIDTH, GDB_FB_HEIGHT) >= 0;
    for (y = 0; ok && y < GDB_FB_HEIGHT; y++) {
        const uint8_t *in = frame + y * GDB_FB_WIDTH * 2;
        for (x = 0; x < GDB_FB_WIDTH; x++) {
            unsigned p = in[x * 2] | ((unsigned)in[x * 2 + 1] << 8);
            row[x * 3]     = expand5((p >> 10) & 31);
            row[x * 3 + 1] = expand5((p >> 5) & 31);
            row[x * 3 + 2] = expand5(p & 31);
        }
        ok = fwrite(row, 1, sizeof(row), file) == sizeof(row);
    }
    if (fclose(file) != 0 || !ok)
        return json_error(c, "cannot write screenshot");
    return queuef(c, "{\"ok\":true,\"width\":%d,\"height\":%d}\n",
                  GDB_FB_WIDTH, GDB_FB_HEIGHT);
}

static int json_command(struct client *c, struct gdb_rsp *rsp, struct gdb_mbox *mb,
                        char *line)
{
    struct json_field fields[9] = {{0}};
    const char *cmd, *text;
    uint64_t a, b, core;
    int status, flag;
    uint8_t op;

    if (json_parse(line, fields, sizeof(fields) / sizeof(fields[0]) - 1) < 0 ||
        !(cmd = json_text(fields, "cmd")))
        return json_error(c, "expected a JSON command object");

    if (!strcmp(cmd, "status")) {
        if (gdb_mbox_check_magic(mb) < 0)
            return json_result(c, -1);
        if (json_run_state(c, gdb_mbox_state(mb), gdb_mbox_cycles(mb)) < 0)
            return -1;
        return queuef(c, "}\n");
    }
    if (!strcmp(cmd, "rdstate"))
        return json_state(c, mb);
    if (!strcmp(cmd, "trace"))
        return json_trace(c, mb);
    if (!strcmp(cmd, "rdregs")) {
        uint32_t regs[GDB_NUM_REGS];
        int i;
        status = gdb_mbox_read_regs(mb, regs);
        if (status != GDB_STATUS_OK)
            return json_result(c, status);
        if (queuef(c, "{\"ok\":true,\"regs\":[") < 0)
            return -1;
        for (i = 0; i < GDB_NUM_REGS; i++)
            if (queuef(c, "%s%" PRIu32, i ? "," : "", regs[i]) < 0)
                return -1;
        return queuef(c, "]}\n");
    }
    if (!strcmp(cmd, "rdmem") || !strcmp(cmd, "wrmem")) {
        uint8_t data[GDB_DATA_MAX];
        size_t n;
        if (json_uint(fields, "addr", UINT32_MAX, UINT64_MAX, &a) < 0)
            goto badarg;
        if (cmd[0] == 'r') {
            if (json_uint(fields, "len", GDB_DATA_MAX, UINT64_MAX, &b) < 0)
                goto badarg;
            status = gdb_mbox_read_mem(mb, (uint32_t)a, (int)b, data);
            if (status != GDB_STATUS_OK)
                return json_result(c, status);
            if (queuef(c, "{\"ok\":true,\"hex\":\"") < 0)
                return -1;
            gdb_mem2hex(data, c->out + c->out_len, (int)b);
            c->out_len += (size_t)b * 2;
            return queuef(c, "\"}\n");
        }
        if (!(text = json_text(fields, "hex")))
            goto badarg;
        n = strlen(text);
        if (n > 2 * GDB_DATA_MAX || n % 2 || gdb_hex2mem(text, data, (int)(n / 2)) < 0)
            goto badarg;
        return json_result(c, gdb_mbox_write_mem(mb, (uint32_t)a, (int)(n / 2), data));
    }
    if (!strcmp(cmd, "setbp") || !strcmp(cmd, "setwp")) {
        int wp = cmd[3] == 'w', both, rd = 0, wr = 0;
        if (json_uint(fields, "slot", (wp ? GDB_WP_COUNT : GDB_BP_COUNT) - 1,
                      UINT64_MAX, &a) < 0 ||
            json_uint(fields, "addr", UINT32_MAX, UINT64_MAX, &b) < 0 ||
            json_uint(fields, "core", 1, (unsigned)gdb_mbox_active_core(mb), &core) < 0 ||
            (flag = json_bool(fields, "en", 1)) < 0 ||
            (both = json_bool(fields, "both", 0)) < 0 ||
            (wp && ((rd = json_bool(fields, "rd", 0)) < 0 ||
                    (wr = json_bool(fields, "wr", 1)) < 0)))
            goto badarg;
        status = gdb_mbox_set_cmp(mb, wp, (int)a, (uint32_t)b, flag, rd, wr, (int)core, both);
        if (status == GDB_STATUS_OK)
            (wp ? rsp->wp : rsp->bp)[a].used = 0; // JSON now owns this slot.
        return json_result(c, status);
    }
    if (!strcmp(cmd, "set_input")) {
        int previous = gdb_mbox_active_core(mb);
        if (json_uint(fields, "core", 1, (unsigned)previous, &core) < 0 ||
            json_uint(fields, "mask", 0x3ff, UINT64_MAX, &a) < 0 ||
            json_uint(fields, "val", 0x3ff, UINT64_MAX, &b) < 0)
            goto badarg;
        if ((int)core != previous) {
            status = gdb_mbox_cmd(mb, GDB_CMD_SET_CORE, (uint32_t)core, 0, 0);
            if (status != GDB_STATUS_OK)
                return json_result(c, status);
        }
        status = gdb_mbox_cmd(mb, GDB_CMD_SET_INPUT, (uint32_t)((a << 16) | b), 0, 0);
        if ((int)core != previous) {
            int restore = gdb_mbox_cmd(mb, GDB_CMD_SET_CORE, (uint32_t)previous, 0, 0);
            if (status == GDB_STATUS_OK)
                status = restore;
        }
        return json_result(c, status);
    }
    if (!strcmp(cmd, "screenshot")) {
        if (json_uint(fields, "core", (unsigned)gdb_mbox_dual_core(mb),
                      0, &core) < 0 || !(text = json_text(fields, "path")) || !*text)
            goto badarg;
        return json_screenshot(c, (int)core, text);
    }

    a = b = 0;
    if (!strcmp(cmd, "halt")) {
        op = GDB_CMD_HALT;
    } else if (!strcmp(cmd, "cont")) {
        op = GDB_CMD_CONT;
    } else if (!strcmp(cmd, "step") || !strcmp(cmd, "step_cycles") ||
               !strcmp(cmd, "step_frames")) {
        op = !cmd[4] ? GDB_CMD_STEP : cmd[5] == 'c' ? GDB_CMD_STEP_CYCLES : GDB_CMD_STEP_FRAMES;
        if (json_uint(fields, "n", UINT32_MAX, 1, &a) < 0 || (op != GDB_CMD_STEP && !a))
            goto badarg;
    } else if (!strcmp(cmd, "step_line")) {
        op = GDB_CMD_STEP_LINE;
        if (json_uint(fields, "line", 227, UINT64_MAX, &a) < 0 ||
            (flag = json_bool(fields, "hblank", 0)) < 0)
            goto badarg;
        a |= (uint64_t)flag << 8;
    } else if (!strcmp(cmd, "break_cycle")) {
        op = GDB_CMD_BREAK_CYCLE;
        if (!json_find(fields, "cycle") || json_uint(fields, "cycle", UINT64_MAX, 0, &b) < 0)
            goto badarg;
    } else if (!strcmp(cmd, "break_event")) {
        op = GDB_CMD_BREAK_EVENT;
        if (json_uint(fields, "mask", 0x3f, UINT64_MAX, &a) < 0)
            goto badarg;
    } else if (!strcmp(cmd, "wrreg")) {
        op = GDB_CMD_WRREG;
        if (json_uint(fields, "reg", 17, UINT64_MAX, &b) < 0 ||
            json_uint(fields, "val", UINT32_MAX, UINT64_MAX, &a) < 0)
            goto badarg;
    } else if (!strcmp(cmd, "set_core")) {
        op = GDB_CMD_SET_CORE;
        if (json_uint(fields, "core", 1, UINT64_MAX, &a) < 0)
            goto badarg;
    } else if (!strcmp(cmd, "reset")) {
        op = GDB_CMD_RESET;
        if ((flag = json_bool(fields, "halt", 0)) < 0)
            goto badarg;
        a = (uint64_t)flag;
    } else {
        return json_error(c, "unknown command");
    }
    return json_result(c, gdb_mbox_cmd(mb, op, (uint32_t)a, b, 0));

badarg:
    return json_error(c, "missing or invalid arguments");
}

struct json_line {
    char buf[JSON_LINE_MAX];
    size_t len;
    int invalid;
};

static int json_byte(struct client *c, struct gdb_rsp *rsp, struct gdb_mbox *mb,
                     struct json_line *line, unsigned char b)
{
    int rc;
    if (b != '\n') {
        if (b == 0 || line->len == sizeof(line->buf) - 1)
            line->invalid = 1;
        if (!line->invalid)
            line->buf[line->len++] = (char)b;
        return 0;
    }
    line->buf[line->len] = 0;
    rc = line->invalid ? json_error(c, "invalid or oversized JSON line")
                       : json_command(c, rsp, mb, line->buf);
    line->len = 0;
    line->invalid = 0;
    return rc;
}

static int client_read(struct client *c)
{
    ssize_t n = read(c->fd, c->in, sizeof(c->in));
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;
    if (n <= 0)
        return -1;
    c->in_pos = 0;
    c->in_len = (size_t)n;
    return 0;
}

static int client_write(struct client *c)
{
    ssize_t n = write(c->fd, c->out + c->out_pos, c->out_len - c->out_pos);
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;
    if (n <= 0)
        return -1;
    c->out_pos += (size_t)n;
    if (c->out_pos == c->out_len)
        c->out_pos = c->out_len = 0;
    return 0;
}

static int accept_client(int listener, struct client *c)
{
    int fd = accept(listener, NULL, NULL), on = 1;
    if (fd < 0)
        return 0;
    if (c->fd >= 0 || fd >= FD_SETSIZE || set_nonblock(fd) < 0) {
        close(fd);
        return 0;
    }
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    c->fd = fd;
    c->in_pos = c->in_len = c->out_pos = c->out_len = 0;
    return 1;
}

static void client_close(struct client *c)
{
    if (c->fd >= 0)
        close(c->fd);
    c->fd = -1;
}

static int serve(int gdb_listener, int json_listener, struct gdb_mbox *mb)
{
    struct client gdb = {.fd = -1}, json = {.fd = -1};
    struct framer fr = {0};
    struct json_line line = {0};
    struct gdb_rsp rsp;

    gdb_rsp_init(&rsp, mb);
    for (;;) {
        fd_set readers, writers;
        struct timeval timeout = {0, POLL_MS * 1000};
        int maxfd = gdb_listener, rc;

        if (gdb.fd >= 0) {
            if (!gdb.out_len && rsp.running && gdb_mbox_halted(mb)) {
                char reply[GDB_REPLY_MAX];
                int len = gdb_rsp_poll(&rsp, reply, sizeof(reply));
                if (len > 0 && queue_packet(&gdb, reply, len) < 0)
                    client_close(&gdb);
            }
            while (gdb.fd >= 0 && !rsp.detached && !gdb.out_len && gdb.in_pos < gdb.in_len)
                if (rsp_byte(&gdb, &rsp, &fr, gdb.in[gdb.in_pos++]) < 0) {
                    client_close(&gdb);
                    break;
                }
            if (rsp.detached && !gdb.out_len)
                client_close(&gdb);
            if (gdb.fd < 0)
                gdb_rsp_disconnect(&rsp);
        }
        while (json.fd >= 0 && !json.out_len && json.in_pos < json.in_len)
            if (json_byte(&json, &rsp, mb, &line, json.in[json.in_pos++]) < 0) {
                client_close(&json);
                break;
            }

        FD_ZERO(&readers);
        FD_ZERO(&writers);
        FD_SET(gdb_listener, &readers);
        if (json_listener >= 0) {
            FD_SET(json_listener, &readers);
            if (json_listener > maxfd) maxfd = json_listener;
        }
        if (gdb.fd >= 0) {
            FD_SET(gdb.fd, gdb.out_len ? &writers : &readers);
            if (gdb.fd > maxfd) maxfd = gdb.fd;
        }
        if (json.fd >= 0) {
            FD_SET(json.fd, json.out_len ? &writers : &readers);
            if (json.fd > maxfd) maxfd = json.fd;
        }
        rc = select(maxfd + 1, &readers, &writers, NULL,
                    gdb.fd >= 0 && rsp.running ? &timeout : NULL);
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            perror("select");
            break;
        }
        if (gdb.fd >= 0 &&
            ((FD_ISSET(gdb.fd, &writers) && client_write(&gdb) < 0) ||
             (FD_ISSET(gdb.fd, &readers) && client_read(&gdb) < 0))) {
            client_close(&gdb);
            gdb_rsp_disconnect(&rsp);
        }
        if (json.fd >= 0 &&
            ((FD_ISSET(json.fd, &writers) && client_write(&json) < 0) ||
             (FD_ISSET(json.fd, &readers) && client_read(&json) < 0)))
            client_close(&json);
        if (FD_ISSET(gdb_listener, &readers) && accept_client(gdb_listener, &gdb)) {
            memset(&fr, 0, sizeof(fr));
            gdb_rsp_init(&rsp, mb);
            rsp.console = queue_console;
            rsp.console_ctx = &gdb;
        }
        if (json_listener >= 0 && FD_ISSET(json_listener, &readers) &&
            accept_client(json_listener, &json)) {
            line.len = 0;
            line.invalid = 0;
        }
    }
    if (gdb.fd >= 0)
        gdb_rsp_disconnect(&rsp);
    client_close(&gdb);
    client_close(&json);
    return 1;
}

static void usage(const char *me)
{
    fprintf(stderr,
        "usage: %s [-p port] [-j port] [-a phys] [-v]\n"
        "  -p port  TCP port to serve gdb on (default %d)\n"
        "  -j port  JSON control port (default %d, 0 disables)\n"
        "  -a phys  DDR3 mailbox physical address (default 0x%08X)\n"
        "  -v       trace packets to stderr\n"
        "Use only on a trusted network: both ports grant control of the core.\n",
        me, DEF_PORT, DEF_JSON_PORT, GDB_MBOX_PHYS);
}

static int option_uint(const char *str, int base, unsigned long *value)
{
    char *end;
    if (*str < '0' || *str > '9')
        return -1;
    errno = 0;
    *value = strtoul(str, &end, base);
    return errno || *end ? -1 : 0;
}

int main(int argc, char **argv)
{
    int gdb_port = DEF_PORT, json_port = DEF_JSON_PORT, i;
    int gdb_listener, json_listener = -1, rc = 1;
    unsigned long phys = GDB_MBOX_PHYS;
    struct gdb_mbox mb;

    for (i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "-p") || !strcmp(argv[i], "-j")) && i + 1 < argc) {
            int is_json = argv[i][1] == 'j';
            unsigned long port;
            if (option_uint(argv[++i], 10, &port) < 0 || port > 65535 ||
                (!is_json && port == 0)) {
                usage(argv[0]);
                return 1;
            }
            if (is_json) json_port = (int)port;
            else         gdb_port = (int)port;
        } else if (!strcmp(argv[i], "-a") && i + 1 < argc) {
            if (option_uint(argv[++i], 0, &phys) < 0) {
                usage(argv[0]);
                return 1;
            }
        } else if (!strcmp(argv[i], "-v"))
            verbose = 1;
        else {
            usage(argv[0]);
            return 1;
        }
    }

    signal(SIGPIPE, SIG_IGN);

    if (gdb_mbox_open(&mb, phys) < 0) {
        fprintf(stderr, "gdb: cannot map mailbox at 0x%08lx "
                        "(run as root, and enable the GDB Stub OSD option)\n",
                phys);
        return 1;
    }

    // A fresh sequence also verifies that a stale ACK was not left behind by
    // a disabled or unloaded FPGA engine.
    if (gdb_mbox_cmd(&mb, GDB_CMD_NOP, 0, 0, 0) != GDB_STATUS_OK ||
        gdb_mbox_check_magic(&mb) < 0) {
        fprintf(stderr, "gdb: no protocol v%u mailbox at 0x%08lx "
                        "(enable the GDB Stub OSD option)\n", GDB_PROTO_VER, phys);
        gdb_mbox_close(&mb);
        return 1;
    }

    gdb_listener = listen_on(gdb_port);
    if (gdb_listener < 0)
        goto done;
    if (json_port) {
        json_listener = listen_on(json_port);
        if (json_listener < 0)
            goto done;
    }
    if (gdb_listener >= FD_SETSIZE || json_listener >= FD_SETSIZE) {
        fprintf(stderr, "gdb: listener descriptor exceeds select capacity\n");
        goto done;
    }
    fprintf(stderr, "gdb: RSP port %d, mailbox 0x%08lx\n", gdb_port, phys);
    if (json_listener >= 0)
        fprintf(stderr, "gdb: JSON control port %d\n", json_port);
    rc = serve(gdb_listener, json_listener, &mb);

done:
    if (json_listener >= 0)
        close(json_listener);
    if (gdb_listener >= 0)
        close(gdb_listener);
    gdb_mbox_close(&mb);
    return rc;
}
