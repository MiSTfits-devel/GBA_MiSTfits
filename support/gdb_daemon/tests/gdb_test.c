// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Protocol tests for gdb_daemon. A fake engine stands in for gba_gdb.vhd:
// it reads the mailbox, services the command and writes the ack, so the real
// gdb_rsp.c and gdb_mbox.c run unmodified against it.
#include "gdb_mbox.h"
#include "gdb_proto.h"
#include "gdb_rsp.h"

#include <stdio.h>
#include <string.h>

static int fails;

#define CHECK(cond, ...) do {                        \
    if (!(cond)) {                                   \
        printf("FAIL %s:%d: ", __FILE__, __LINE__);  \
        printf(__VA_ARGS__);                         \
        printf("\n");                                \
        fails++;                                     \
    }                                                \
} while (0)

// ---------------------------------------------------------- the fake engine

#define FAKE_MEM_BASE  0x03000000u              // IWRAM
#define FAKE_MEM_SIZE  0x8000u

static uint8_t  fake_mem[FAKE_MEM_SIZE];
static uint32_t fake_regs[GDB_NUM_REGS];
static int      fake_halted = 1;
static int      fake_stop_reason = GDB_STOP_HOST;
static uint32_t fake_bp[GDB_BP_COUNT], fake_wp[GDB_WP_COUNT];
static int      fake_bp_en[GDB_BP_COUNT], fake_wp_en[GDB_WP_COUNT];
static uint8_t  fake_last_seq;

static uint64_t fget(struct gdb_mbox *m, int off)
{
    uint64_t v;
    memcpy(&v, (const void *)(m->base + off), sizeof(v));
    return v;
}

static void fput(struct gdb_mbox *m, int off, uint64_t v)
{
    memcpy((void *)(m->base + off), &v, sizeof(v));
}

static void fake_publish_state(struct gdb_mbox *m)
{
    fput(m, GDB_OFF_STATE,
         (uint64_t)(fake_halted ? 1 : 0) |
         ((uint64_t)fake_stop_reason << 4) |
         ((uint64_t)fake_regs[15] << 32));
}

static void fake_engine(struct gdb_mbox *m)
{
    uint64_t cmd  = fget(m, GDB_OFF_CMD);
    uint8_t  op   = (uint8_t)(cmd & 0xff);
    uint8_t  seq  = (uint8_t)((cmd >> 8) & 0xff);
    uint32_t arg  = (uint32_t)(cmd >> 32);
    uint32_t addr = (uint32_t)(fget(m, GDB_OFF_ADDR) & 0x0fffffff);
    uint16_t len  = (uint16_t)(fget(m, GDB_OFF_LEN) & 0xffff);
    uint8_t  status = GDB_STATUS_OK;

    if (seq == fake_last_seq || op == GDB_CMD_NOP)
        return;
    fake_last_seq = seq;

    switch (op) {
    case GDB_CMD_HALT:
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_HOST;
        break;
    case GDB_CMD_CONT:
        fake_halted = 0;
        fake_stop_reason = GDB_STOP_NONE;
        break;
    case GDB_CMD_STEP:
        // one instruction, then stopped again
        fake_regs[15] += 4;
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_STEP;
        break;
    case GDB_CMD_RDMEM: {
        uint32_t i;
        // the engine only ever transfers whole words from a word-aligned base
        CHECK((addr & 3) == 0, "RDMEM addr %08x not word aligned", addr);
        CHECK((len & 3) == 0, "RDMEM len %u not a word multiple", len);
        for (i = 0; i < len; i++) {
            uint32_t a = addr + i - FAKE_MEM_BASE;
            uint8_t  b = a < FAKE_MEM_SIZE ? fake_mem[a] : 0;
            memcpy((void *)(m->base + GDB_OFF_DATA + i), &b, 1);
        }
        break;
    }
    case GDB_CMD_WRMEM: {
        uint32_t i;
        CHECK((addr & 3) == 0, "WRMEM addr %08x not word aligned", addr);
        for (i = 0; i < len; i++) {
            uint32_t a = addr + i - FAKE_MEM_BASE;
            if (a < FAKE_MEM_SIZE)
                fake_mem[a] = *(volatile uint8_t *)(m->base + GDB_OFF_DATA + i);
        }
        break;
    }
    case GDB_CMD_RDREGS:
        memcpy((void *)(m->base + GDB_OFF_DATA), fake_regs, sizeof(fake_regs));
        break;
    case GDB_CMD_WRREG:
        if (addr < GDB_NUM_REGS) fake_regs[addr] = arg;
        else                     status = GDB_STATUS_BADCMD;
        break;
    case GDB_CMD_SETBP: {
        int slot = (int)(arg & 0xf);
        if (slot < GDB_BP_COUNT) {
            fake_bp[slot]    = addr;
            fake_bp_en[slot] = (arg >> 4) & 1;
        } else status = GDB_STATUS_BADCMD;
        break;
    }
    case GDB_CMD_SETWP: {
        int slot = (int)(arg & 0xf);
        if (slot < GDB_WP_COUNT) {
            fake_wp[slot]    = addr;
            fake_wp_en[slot] = (arg >> 4) & 1;
        } else status = GDB_STATUS_BADCMD;
        break;
    }
    default:
        status = GDB_STATUS_BADCMD;
        break;
    }

    fake_publish_state(m);
    fput(m, GDB_OFF_ACK, (uint64_t)seq | ((uint64_t)status << 8));
}

// --------------------------------------------------------------- test cases

static uint8_t mbox_backing[GDB_MBOX_SIZE];

static int ask(struct gdb_rsp *rsp, const char *pkt, char *reply)
{
    return gdb_rsp_packet(rsp, pkt, reply, GDB_REPLY_MAX);
}

int main(void)
{
    struct gdb_mbox mb;
    struct gdb_rsp  rsp;
    char reply[GDB_REPLY_MAX];
    int i;

    memset(mbox_backing, 0, sizeof(mbox_backing));
    gdb_mbox_open_mem(&mb, mbox_backing);
    gdb_mbox_pump = fake_engine;
    gdb_rsp_init(&rsp, &mb);

    for (i = 0; i < GDB_NUM_REGS; i++)
        fake_regs[i] = 0x1000u + (uint32_t)i;
    fake_regs[15] = 0x08000108u;                // pc in ROM
    fake_regs[16] = 0x6000001fu;                // cpsr
    fake_publish_state(&mb);

    // ---- hex helpers
    {
        uint32_t v = 0;
        const char *end;
        CHECK(gdb_hex2int("1a2b", &end, &v) == 4 && v == 0x1a2b,
              "hex2int basic");
        CHECK(*end == 0, "hex2int consumed all input");
        CHECK(gdb_checksum("OK", 2) == (uint8_t)('O' + 'K'), "checksum");
    }

    // ---- '?' reports a stop
    ask(&rsp, "?", reply);
    CHECK(!strncmp(reply, "T05", 3), "stop reply was '%s'", reply);

    // ---- qSupported advertises hardware breakpoints
    ask(&rsp, "qSupported:multiprocess+", reply);
    CHECK(strstr(reply, "hwbreak+") != NULL, "qSupported: '%s'", reply);
    CHECK(strstr(reply, "PacketSize=") != NULL, "qSupported packet size");

    // ---- 'g' places pc and cpsr where gdb's builtin arm layout expects
    {
        int n = ask(&rsp, "g", reply);
        char pc[9], cpsr[9];
        CHECK(n == GDB_G_BYTES * 2, "g length %d, want %d", n, GDB_G_BYTES * 2);
        memcpy(pc, reply + 15 * 4 * 2, 8);   pc[8] = 0;
        memcpy(cpsr, reply + 164 * 2, 8);    cpsr[8] = 0;
        CHECK(!strcmp(pc, "08010008"), "r15 little endian: '%s'", pc);
        CHECK(!strcmp(cpsr, "1f000060"), "cpsr at byte 164: '%s'", cpsr);
    }

    // ---- 'p' single register, and the FPA slots we do not model
    ask(&rsp, "pf", reply);
    CHECK(!strcmp(reply, "08010008"), "p15: '%s'", reply);
    ask(&rsp, "p19", reply);
    CHECK(!strcmp(reply, "1f000060"), "p25 (cpsr): '%s'", reply);
    ask(&rsp, "p10", reply);
    CHECK(!strcmp(reply, "00000000"), "p16 (fpa): '%s'", reply);

    // ---- 'P' writes back
    ask(&rsp, "P0=efbeadde", reply);
    CHECK(!strcmp(reply, "OK"), "P reply '%s'", reply);
    CHECK(fake_regs[0] == 0xdeadbeefu, "P wrote %08x", fake_regs[0]);

    // ---- memory: aligned read
    for (i = 0; i < 32; i++)
        fake_mem[i] = (uint8_t)(0xa0 + i);
    ask(&rsp, "m3000000,4", reply);
    CHECK(!strcmp(reply, "a0a1a2a3"), "aligned read: '%s'", reply);

    // ---- memory: ragged read, both ends off a word boundary
    ask(&rsp, "m3000001,6", reply);
    CHECK(!strcmp(reply, "a1a2a3a4a5a6"), "ragged read: '%s'", reply);

    // ---- memory: aligned write
    ask(&rsp, "M3000010,4:11223344", reply);
    CHECK(!strcmp(reply, "OK"), "aligned write reply '%s'", reply);
    CHECK(fake_mem[0x10] == 0x11 && fake_mem[0x13] == 0x44,
          "aligned write landed: %02x..%02x", fake_mem[0x10], fake_mem[0x13]);

    // ---- memory: misaligned write must not disturb its neighbours
    fake_mem[0x20] = 0xde; fake_mem[0x21] = 0xad;
    fake_mem[0x22] = 0xbe; fake_mem[0x23] = 0xef;
    ask(&rsp, "M3000021,2:5566", reply);
    CHECK(!strcmp(reply, "OK"), "misaligned write reply '%s'", reply);
    CHECK(fake_mem[0x20] == 0xde, "byte before write clobbered: %02x",
          fake_mem[0x20]);
    CHECK(fake_mem[0x21] == 0x55 && fake_mem[0x22] == 0x66,
          "misaligned write landed: %02x %02x", fake_mem[0x21], fake_mem[0x22]);
    CHECK(fake_mem[0x23] == 0xef, "byte after write clobbered: %02x",
          fake_mem[0x23]);

    // ---- breakpoints take a comparator, including a software request in ROM
    ask(&rsp, "Z0,8000108,4", reply);
    CHECK(!strcmp(reply, "OK"), "Z0 reply '%s'", reply);
    CHECK(fake_bp_en[0] && fake_bp[0] == 0x8000108u,
          "Z0 armed slot0 %08x en=%d", fake_bp[0], fake_bp_en[0]);

    ask(&rsp, "Z1,8000200,4", reply);
    CHECK(!strcmp(reply, "OK"), "Z1 reply '%s'", reply);
    CHECK(fake_bp_en[1] && fake_bp[1] == 0x8000200u, "Z1 took slot 1");

    ask(&rsp, "z0,8000108,4", reply);
    CHECK(!strcmp(reply, "OK"), "z0 reply '%s'", reply);
    CHECK(!fake_bp_en[0], "z0 disarmed slot 0");

    // ---- comparators are finite and the stub says so rather than lying
    for (i = 0; i < GDB_BP_COUNT; i++) {
        char pkt[32];
        snprintf(pkt, sizeof(pkt), "Z1,%x,4", 0x9000000 + i * 4);
        ask(&rsp, pkt, reply);
    }
    ask(&rsp, "Z1,9ff0000,4", reply);
    CHECK(reply[0] == 'E', "exhausted comparators should error, got '%s'",
          reply);

    // ---- watchpoints
    ask(&rsp, "Z2,3000040,4", reply);
    CHECK(!strcmp(reply, "OK"), "Z2 reply '%s'", reply);
    CHECK(fake_wp_en[0] && fake_wp[0] == 0x3000040u, "Z2 armed a watchpoint");

    // ---- continue leaves no reply owed until the core halts
    {
        int n = ask(&rsp, "c", reply);
        CHECK(n == 0, "continue must not reply immediately");
        CHECK(rsp.running, "continue should mark the target running");
        CHECK(gdb_rsp_poll(&rsp, reply, sizeof(reply)) == 0,
              "no stop reply while running");

        // engine reports a breakpoint hit
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_BP;
        fake_publish_state(&mb);
        n = gdb_rsp_poll(&rsp, reply, sizeof(reply));
        CHECK(n > 0 && !strncmp(reply, "T05", 3), "stop reply '%s'", reply);
        CHECK(strstr(reply, "hwbreak") != NULL,
              "breakpoint stop should say hwbreak: '%s'", reply);
        CHECK(!rsp.running, "poll should clear running");
    }

    // ---- step advances one instruction and stops again
    {
        uint32_t before = fake_regs[15];
        ask(&rsp, "s", reply);
        CHECK(gdb_rsp_poll(&rsp, reply, sizeof(reply)) > 0, "step stop reply");
        CHECK(fake_regs[15] == before + 4, "step advanced pc to %08x",
              fake_regs[15]);
    }

    // ---- detach releases the core and every comparator
    ask(&rsp, "D", reply);
    CHECK(!strcmp(reply, "OK"), "detach reply '%s'", reply);
    CHECK(!fake_halted, "detach must resume the core");
    for (i = 0; i < GDB_BP_COUNT; i++)
        CHECK(!fake_bp_en[i], "detach left breakpoint %d armed", i);
    for (i = 0; i < GDB_WP_COUNT; i++)
        CHECK(!fake_wp_en[i], "detach left watchpoint %d armed", i);

    // ---- unknown packets get an empty reply, never a bogus one
    {
        int n = ask(&rsp, "vFile:open:2f,0,0", reply);
        CHECK(n == 0 && reply[0] == 0, "unknown packet should reply empty");
    }

    gdb_mbox_close(&mb);

    if (fails) {
        printf("%d test(s) failed\n", fails);
        return 1;
    }
    printf("all gdb_daemon tests passed\n");
    return 0;
}
