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
static uint32_t fake_regs[GDB_NUM_REGS + 1];
static int      fake_halted = 1;
static int      fake_stop_reason = GDB_STOP_HOST;
static int      fake_active_core, fake_dual, fake_stop_slot, fake_stop_core;
static uint64_t fake_cycles = UINT64_C(0x100000040), fake_break_cycle;
static uint32_t fake_hit_addr, fake_input[2], fake_event_mask, fake_line;
static uint32_t fake_frames = 3;
static uint32_t fake_bp[GDB_BP_COUNT], fake_wp[GDB_WP_COUNT];
static int      fake_bp_en[GDB_BP_COUNT], fake_wp_en[GDB_WP_COUNT];
static uint32_t fake_bp_flags[GDB_BP_COUNT], fake_wp_flags[GDB_WP_COUNT];
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
    fput(m, GDB_OFF_CYCLES, fake_cycles);
    fput(m, GDB_OFF_STATE,
         (uint64_t)(fake_halted ? 1 : 0) |
         ((uint64_t)fake_active_core << 1) | ((uint64_t)fake_dual << 2) |
         ((uint64_t)fake_stop_reason << 4) |
         ((uint64_t)fake_stop_slot << 8) | ((uint64_t)fake_stop_core << 12) |
         ((uint64_t)fake_regs[15] << 32));
}

static void fake_ack(struct gdb_mbox *m, uint8_t seq, uint8_t status)
{
    fput(m, GDB_OFF_ACK, ((uint64_t)GDB_MAGIC << 32) |
         ((uint64_t)GDB_PROTO_VER << 16) | ((uint64_t)status << 8) | seq);
}

static void fake_init_sync(struct gdb_mbox *m)
{
    fake_last_seq = (uint8_t)(fget(m, GDB_OFF_CMD) >> 8);
    fake_publish_state(m);
    fake_ack(m, fake_last_seq, GDB_STATUS_OK);
}

static void fake_engine(struct gdb_mbox *m)
{
    uint64_t cmd  = fget(m, GDB_OFF_CMD);
    uint8_t  op   = (uint8_t)(cmd & 0xff);
    uint8_t  seq  = (uint8_t)((cmd >> 8) & 0xff);
    uint32_t arg  = (uint32_t)(cmd >> 32);
    uint64_t raw_addr = fget(m, GDB_OFF_ADDR);
    uint32_t addr = (uint32_t)raw_addr;
    uint16_t len  = (uint16_t)(fget(m, GDB_OFF_LEN) & 0xffff);
    uint8_t  status = GDB_STATUS_OK;

    if (seq == fake_last_seq)
        return;
    fake_last_seq = seq;

    switch (op) {
    case GDB_CMD_NOP:
        break;
    case GDB_CMD_HALT:
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_HOST;
        break;
    case GDB_CMD_CONT:
        fake_halted = 0;
        fake_stop_reason = GDB_STOP_NONE;
        break;
    case GDB_CMD_STEP:
        fake_regs[15] += 4 * (arg ? arg : 1);
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_STEP;
        break;
    case GDB_CMD_STEP_CYCLES:
        fake_cycles += arg;
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_STEP_CYCLE;
        break;
    case GDB_CMD_STEP_FRAMES:
        fake_frames += arg;
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_STEP_FRAME;
        break;
    case GDB_CMD_STEP_LINE:
        fake_line = arg;
        fake_halted = 1;
        fake_stop_reason = GDB_STOP_STEP_LINE;
        break;
    case GDB_CMD_BREAK_CYCLE:
        fake_break_cycle = raw_addr;
        break;
    case GDB_CMD_BREAK_EVENT:
        fake_event_mask = arg;
        break;
    case GDB_CMD_SET_CORE:
        if (arg <= (unsigned)fake_dual)
            fake_active_core = (int)arg;
        else
            status = GDB_STATUS_BADARG;
        break;
    case GDB_CMD_SET_INPUT:
        fake_input[fake_active_core] = arg;
        break;
    case GDB_CMD_RESET:
        fake_halted = (int)(arg & 1);
        fake_stop_reason = fake_halted ? GDB_STOP_RESET_HALT : GDB_STOP_NONE;
        break;
    case GDB_CMD_RDSTATE: {
        struct gdb_state state = {0};
        struct gdb_core_state *cs = &state.core[fake_active_core];
        state.state = fget(m, GDB_OFF_STATE);
        state.cycles = fake_cycles;
        state.insns[0] = 12;
        state.insns[1] = 34;
        state.frames_wp_addr = ((uint64_t)fake_hit_addr << 32) | fake_frames;
        cs->arch_fetch_pc = fake_regs[15];
        cs->bus_dispstat = UINT64_C(0x0042000100000000);
        cs->irq_mem = UINT64_C(0xdeadbeef12345678);
        cs->flags = UINT64_C(1) << 48;
        state.savestate[8] = (uint64_t)fake_regs[16] << 32;
        memcpy((void *)(m->base + GDB_OFF_DATA), &state, GDB_STATE_QWORDS * 8);
        break;
    }
    case GDB_CMD_RD_TRACE: {
        struct gdb_trace trace = {0};
        int i;
        if (!fake_halted) {
            status = GDB_STATUS_BUSY;
            break;
        }
        trace.head = GDB_TRACE_ENTRIES;
        for (i = 0; i < GDB_TRACE_ENTRIES; i++)
            trace.entry[i] = UINT64_C(0x567842ff08001000) + (unsigned)i * 4;
        memcpy((void *)(m->base + GDB_OFF_DATA), &trace, GDB_TRACE_QWORDS * 8);
        break;
    }
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
        memcpy((void *)(m->base + GDB_OFF_DATA), fake_regs, GDB_NUM_REGS * 4);
        break;
    case GDB_CMD_WRREG:
        if (raw_addr <= 17) fake_regs[addr] = arg;
        else                status = GDB_STATUS_BADARG;
        break;
    case GDB_CMD_SETBP: {
        int slot = (int)(arg & 0xf);
        if (slot < (fake_dual ? 2 : GDB_BP_COUNT)) {
            fake_bp[slot]    = addr;
            fake_bp_en[slot] = (arg >> 4) & 1;
            fake_bp_flags[slot] = arg;
        } else status = GDB_STATUS_BADARG;
        break;
    }
    case GDB_CMD_SETWP: {
        int slot = (int)(arg & 0xf);
        if (slot < (fake_dual ? 1 : GDB_WP_COUNT)) {
            fake_wp[slot]    = addr;
            fake_wp_en[slot] = (arg >> 4) & 1;
            fake_wp_flags[slot] = arg;
        } else status = GDB_STATUS_BADARG;
        break;
    }
    default:
        status = GDB_STATUS_BADCMD;
        break;
    }

    fake_publish_state(m);
    fake_ack(m, seq, status);
}

// --------------------------------------------------------------- test cases

static uint8_t mbox_backing[GDB_MBOX_SIZE];

static int ask(struct gdb_rsp *rsp, const char *pkt, char *reply)
{
    return gdb_rsp_packet(rsp, pkt, reply, GDB_REPLY_MAX);
}

static int capture_console(void *ctx, const char *text)
{
    snprintf(ctx, GDB_PKT_MAX / 2, "%s", text);
    return 0;
}

static void monitor(struct gdb_rsp *rsp, const char *cmd, char *reply)
{
    char pkt[128] = "qRcmd,";
    gdb_mem2hex((const uint8_t *)cmd, pkt + 6, (int)strlen(cmd));
    ask(rsp, pkt, reply);
}

int main(void)
{
    struct gdb_mbox mb;
    struct gdb_rsp  rsp;
    char reply[GDB_REPLY_MAX];
    char console[GDB_PKT_MAX / 2];
    int i;

    memset(mbox_backing, 0, sizeof(mbox_backing));
    gdb_mbox_open_mem(&mb, mbox_backing);
    gdb_mbox_pump = fake_engine;
    gdb_rsp_init(&rsp, &mb);

    for (i = 0; i < GDB_NUM_REGS; i++)
        fake_regs[i] = 0x1000u + (uint32_t)i;
    fake_regs[15] = 0x08000108u;                // pc in ROM
    fake_regs[16] = 0x6000001fu;                // cpsr
    CHECK(gdb_mbox_check_magic(&mb) < 0, "zero ACK must not pass v2 check");
    fput(&mb, GDB_OFF_ACK, ((uint64_t)GDB_MAGIC << 32) | (UINT64_C(1) << 16));
    CHECK(gdb_mbox_check_magic(&mb) < 0, "old ACK version must be rejected");
    fake_init_sync(&mb);
    CHECK(gdb_mbox_check_magic(&mb) == 0, "INIT_SYNC should advertise v2");
    CHECK(gdb_mbox_cycles(&mb) == fake_cycles, "published cycle count truncated");
    rsp.console = capture_console;
    rsp.console_ctx = console;

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
    CHECK(strstr(reply, "PacketSize=2000;qRcmd+;vContSupported+") != NULL,
          "qSupported v2 capabilities: '%s'", reply);

    ask(&rsp, "qfThreadInfo", reply);
    CHECK(!strcmp(reply, "m1"), "single-core threads: '%s'", reply);
    ask(&rsp, "Hg2", reply);
    CHECK(reply[0] == 'E', "thread 2 allowed in single-core mode");

    monitor(&rsp, "cycles", reply);
    CHECK(!strcmp(reply, "OK") &&
          !strcmp(console, "total_cycles=4294967360 insns_c0=12 insns_c1=34 frames=3\n"),
          "monitor cycles: '%s'", reply);
    monitor(&rsp, "state", reply);
    CHECK(!strcmp(reply, "OK") && strstr(console, "PC=08000108 CPSR=6000001f") &&
          strstr(console, "VCOUNT=66 DISPSTAT=0001") &&
          strstr(console, "IE=1234 IF=5678 IME=1") && strstr(console, "mem_info=deadbeef"),
          "monitor state: '%s'", reply);
    monitor(&rsp, "trace", reply);
    CHECK(!strcmp(reply, "OK") && strstr(console, "trace (64 entries") &&
          strstr(console, "63 PC=080010fc cycles=255 VCOUNT=66 IF=5678"),
          "monitor trace: '%s'", reply);
    monitor(&rsp, "stepc 17", reply);
    CHECK(!strcmp(reply, "OK") && gdb_mbox_stop_reason(&mb) == GDB_STOP_STEP_CYCLE &&
          gdb_mbox_cycles(&mb) == UINT64_C(0x100000051), "monitor stepc: '%s'", reply);
    monitor(&rsp, "stepf 2", reply);
    CHECK(!strcmp(reply, "OK") && fake_frames == 5, "monitor stepf: '%s'", reply);
    monitor(&rsp, "stepl 227 hblank", reply);
    CHECK(!strcmp(reply, "OK") && fake_line == (0x100 | 227), "monitor stepl: '%s'", reply);
    monitor(&rsp, "breakc 0x100001234", reply);
    CHECK(!strcmp(reply, "OK") && fake_break_cycle == UINT64_C(0x100001234),
          "monitor breakc truncated the target cycle");
    monitor(&rsp, "breakev 2a", reply);
    CHECK(!strcmp(reply, "OK") && fake_event_mask == 0x2a, "monitor breakev: '%s'", reply);
    monitor(&rsp, "reset halt", reply);
    CHECK(!strcmp(reply, "OK") && fake_stop_reason == GDB_STOP_RESET_HALT,
          "monitor reset halt: '%s'", reply);

    CHECK(gdb_mbox_set_cmp(&mb, 0, 7, 0x08000000, 1, 0, 0, 0, 0) == GDB_STATUS_OK &&
          fake_bp_en[7], "1P lost breakpoint slot 7");
    CHECK(gdb_mbox_set_cmp(&mb, 1, 3, 0x03000000, 1, 1, 1, 0, 0) == GDB_STATUS_OK &&
          fake_wp_en[3], "1P lost watchpoint slot 3");
    CHECK(gdb_mbox_set_cmp(&mb, 0, 7, 0, 0, 0, 0, 0, 0) == GDB_STATUS_OK &&
          gdb_mbox_set_cmp(&mb, 1, 3, 0, 0, 0, 0, 0, 0) == GDB_STATUS_OK,
          "could not release 1P comparators");

    fake_dual = 1;
    fake_publish_state(&mb);
    ask(&rsp, "qfThreadInfo", reply);
    CHECK(!strcmp(reply, "m1,2"), "dual-core threads: '%s'", reply);
    ask(&rsp, "qsThreadInfo", reply);
    CHECK(!strcmp(reply, "l"), "end of thread list: '%s'", reply);
    ask(&rsp, "Hg2", reply);
    CHECK(!strcmp(reply, "OK") && gdb_mbox_active_core(&mb) == 1, "Hg2: '%s'", reply);
    ask(&rsp, "qC", reply);
    CHECK(!strcmp(reply, "QC2"), "qC on core 1: '%s'", reply);
    ask(&rsp, "Hc1", reply);
    CHECK(!strcmp(reply, "OK") && fake_active_core == 0, "Hc1: '%s'", reply);
    monitor(&rsp, "core 1", reply);
    CHECK(!strcmp(reply, "OK") && fake_active_core == 1, "monitor core: '%s'", reply);
    monitor(&rsp, "input 3ff 101", reply);
    CHECK(!strcmp(reply, "OK") && fake_input[1] == UINT32_C(0x03ff0101) && !fake_input[0],
          "monitor input on core 1: '%s'", reply);

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
    CHECK(fake_bp_flags[0] == (GDB_CMP_ENABLE | GDB_BP_BOTH | GDB_BP_CORE),
          "RSP breakpoint must cover both cores");

    ask(&rsp, "Z1,8000200,4", reply);
    CHECK(!strcmp(reply, "OK"), "Z1 reply '%s'", reply);
    CHECK(fake_bp_en[1] && fake_bp[1] == 0x8000200u, "Z1 took slot 1");

    ask(&rsp, "z0,8000108,4", reply);
    CHECK(!strcmp(reply, "OK"), "z0 reply '%s'", reply);
    CHECK(!fake_bp_en[0], "z0 disarmed slot 0");

    // ---- comparators are finite and the stub says so rather than lying
    ask(&rsp, "Z1,9000000,4", reply);
    CHECK(!strcmp(reply, "OK") && fake_bp_en[0], "freed 2P breakpoint slot was not reused");
    ask(&rsp, "Z1,9ff0000,4", reply);
    CHECK(!strcmp(reply, "E1c"), "third 2P breakpoint should report exhaustion, got '%s'", reply);

    // ---- the one 2P watchpoint still supports all three access modes
    {
        static const char *stops[] = {"watch:3000043;", "rwatch:3000047;", "awatch:300004b;"};
        for (i = 0; i < 3; i++) {
            char pkt[32];
            unsigned addr = 0x03000040u + (unsigned)i * 4;
            snprintf(pkt, sizeof(pkt), "Z%d,%x,4", i + 2, addr);
            ask(&rsp, pkt, reply);
            CHECK(!strcmp(reply, "OK") && fake_wp_en[0] && fake_wp[0] == addr,
                  "watchpoint kind %d did not arm slot 0: '%s'", i + 2, reply);
            if (i == 0) {
                CHECK(fake_wp_flags[0] == (GDB_CMP_ENABLE | GDB_WP_WRITE | GDB_WP_CORE | GDB_WP_BOTH),
                      "RSP write watchpoint flags are wrong");
                ask(&rsp, "Z3,3000044,4", reply);
                CHECK(!strcmp(reply, "E1c"), "second 2P watchpoint should report exhaustion, got '%s'", reply);
            }
            fake_stop_reason = GDB_STOP_WP;
            fake_stop_slot = 0;
            fake_stop_core = 1;
            fake_hit_addr = addr + 3;
            fake_publish_state(&mb);
            ask(&rsp, "?", reply);
            CHECK(strstr(reply, stops[i]) && strstr(reply, "thread:2;"),
                  "watchpoint stop for kind %d: '%s'", i + 2, reply);
            if (i < 2) {
                pkt[0] = 'z';
                ask(&rsp, pkt, reply);
                CHECK(!strcmp(reply, "OK") && !fake_wp_en[0],
                      "watchpoint kind %d did not release slot 0: '%s'", i + 2, reply);
            }
        }
    }

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

    ask(&rsp, "vCont;s:2;c", reply);
    CHECK(fake_active_core == 1 && gdb_rsp_poll(&rsp, reply, sizeof(reply)) > 0,
          "thread-qualified vCont step must select core 1");

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
