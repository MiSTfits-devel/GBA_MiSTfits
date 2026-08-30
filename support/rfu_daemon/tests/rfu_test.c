// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Drives rfu_core the way the FPGA would, without an FPGA. "unit" checks the
// command layouts locally; "host"/"client" run two processes against each
// other over the real UDP transport and exchange data both ways, which is the
// end-to-end proof that the RFU1 wire format and the session state machine
// agree with each other.
#include "rfu_core.h"
#include "rfu_net.h"
#include "rfu_proto.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;

uint32_t rfu_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

void rfu_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "    | ");
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

#define CHECK(cond, ...) do {                                   \
    if (!(cond)) { failures++;                                  \
        printf("  FAIL %s:%d: ", __func__, __LINE__);           \
        printf(__VA_ARGS__); printf("\n"); }                    \
} while (0)

static int cmd(uint8_t c, uint8_t len, const uint32_t *p, uint32_t *resp)
{
    return rfu_core_command(c, len, p, resp);
}

// Runs the housekeeping tick and the socket for a while, like the daemon does.
static void pump(int ms)
{
    uint32_t end = rfu_now_ms() + (uint32_t)ms;
    while ((int32_t)(rfu_now_ms() - end) < 0) {
        struct timespec ts = { 0, 4 * 1000000 };
        rfu_net_poll();
        rfu_core_frame();
        rfu_net_tick();
        nanosleep(&ts, NULL);
    }
}

// --- local checks ---------------------------------------------------------

static void test_unit(void)
{
    uint32_t r[RFU_MAX_WORDS], p[8];
    int n;

    printf("unit: command layouts\n");
    rfu_core_init();

    // Fresh adapter: neutral, no id.
    n = cmd(0x13, 0, NULL, r);
    CHECK(n == 1 && r[0] == 0, "SystemStatus in N should be 0, got %08x", r[0]);

    // Unknown and out-of-range commands are rejected differently.
    CHECK(cmd(0x11, 0, NULL, r) == 1, "LinkStatus must answer one word");
    CHECK(cmd(0x99, 0, NULL, r) == -2, "0x99 must be 'unknown command'");
    CHECK(cmd(0x1A, 0, NULL, r) == -1, "SC_Polling outside host must reject");

    // Broadcast data round trip.
    for (n = 0; n < 6; n++) p[n] = 0x11111111u * (uint32_t)(n + 1);
    CHECK(cmd(0x16, 6, p, r) == 0, "GameConfig takes no response");

    // SystemConfig: mcTimer / maxMFrame / AvailableSlot, afska's encoding.
    p[0] = 0x003C0000 | (3u << 16) | (4u << 8) | 32u;  // maxPlayers 2
    CHECK(cmd(0x17, 1, p, r) == 0, "SystemConfig takes no response");

    // Host: gets an id, reports P-PSC, one free slot at 0.
    CHECK(cmd(0x19, 0, NULL, r) == 0, "SC_Start takes no response");
    CHECK(rfu_core_state() == RFU_ST_HOST_OPEN, "SC_Start must open the host");
    n = cmd(0x13, 0, NULL, r);
    CHECK(n == 1 && (r[0] >> 24) == RFU_ST_HOST_OPEN && (r[0] & 0xffff),
          "SystemStatus should be state 2 with a nonzero id, got %08x", r[0]);
    n = cmd(0x14, 0, NULL, r);
    CHECK(n == 1 && (r[0] & 0xff) == 0,
          "SlotStatus on an empty host: next slot 0, no children (n=%d)", n);
    CHECK(cmd(0x1A, 0, NULL, r) == 0, "no children yet");

    // A host cannot search or connect.
    CHECK(cmd(0x1C, 0, NULL, r) == -1, "SP_Start while hosting must reject");
    CHECK(cmd(0x1F, 1, p, r) == -1, "CP_Start while hosting must reject");

    // Nothing received yet: DataRx answers empty, not a zero header.
    CHECK(cmd(0x26, 0, NULL, r) == 0, "empty DataRx must have no payload");

    // Closing entry with no children returns to neutral.
    CHECK(cmd(0x1B, 0, NULL, r) == 0, "SC_End with no children");
    CHECK(rfu_core_state() == RFU_ST_IDLE, "empty host must drop to N");

    // Client side: scan finds nothing without peers, connect fails cleanly.
    CHECK(cmd(0x1C, 0, NULL, r) == 0, "SP_Start");
    CHECK(cmd(0x1D, 0, NULL, r) == 0, "SP_Polling with no parents in range");
    p[0] = 0x1234;
    CHECK(cmd(0x1F, 1, p, r) == 0, "CP_Start on a missing parent still ACKs");
    n = cmd(0x20, 0, NULL, r);
    CHECK(n == 1 && r[0] == 0x02000000,
          "CP_Polling must report failure, got %08x", r[0]);

    // StopMode returns to power save.
    CHECK(cmd(0x3D, 0, NULL, r) == 0, "StopMode");
    CHECK(rfu_core_state() == RFU_ST_IDLE, "StopMode must leave state N");

    // Reversal with nobody connected: the wait must always terminate, and
    // from N the adapter reports the connection loss.
    rfu_core_wait_begin();
    {
        uint8_t wc = 0, wn = 0;
        uint32_t wp[RFU_MAX_WORDS];
        CHECK(rfu_core_wait_poll(&wc, &wn, wp) == 1 && wc == 0x29,
              "wait in state N must inject Disconnected&Change, got %02x", wc);
    }
    printf("unit: done\n");
}

// --- two-process session --------------------------------------------------

static void say(const char *who, const char *what) { printf("  %s: %s\n", who, what); }

static int test_host(int port, const char *peer)
{
    uint32_t r[RFU_MAX_WORDS], p[8];
    int i, n, deadline;

    rfu_core_init();
    if (rfu_net_open(port, 0) < 0)
        return 1;
    rfu_net_add_peer(peer, port);

    cmd(0x10, 0, NULL, r);
    for (i = 0; i < 6; i++) p[i] = 0xA0A0A0A0u + (uint32_t)i;
    cmd(0x16, 6, p, r);
    p[0] = 0x003C0000 | (4u << 8) | 32u;
    cmd(0x17, 1, p, r);
    cmd(0x19, 0, NULL, r);
    say("host", "broadcasting");

    for (deadline = 0; deadline < 100; deadline++) {
        pump(50);
        n = cmd(0x1A, 0, NULL, r);
        if (n >= 1)
            break;
    }
    if (n < 1) { printf("  FAIL host: no child joined\n"); return 1; }
    printf("  host: child %04x in slot %u\n", r[0] & 0xffff, (r[0] >> 16) & 3);

    // SlotStatus must now show one child and the next free slot.
    n = cmd(0x14, 0, NULL, r);
    if (n != 2 || (r[0] & 0xff) != 1) {
        printf("  FAIL host: SlotStatus n=%d word0=%08x\n", n, r[0]);
        return 1;
    }

    // Parent -> child: 8 bytes. Header bits 6:0 carry the parent's length.
    p[0] = 8;
    p[1] = 0xDEADBEEF;
    p[2] = 0x12345678;
    cmd(0x25, 3, p, r);
    say("host", "sent 8 bytes to the child");

    // Child -> parent: expect 4 bytes reported in the S0 field.
    for (deadline = 0; deadline < 100; deadline++) {
        pump(50);
        n = cmd(0x26, 0, NULL, r);
        if (n >= 2)
            break;
    }
    if (n < 2) { printf("  FAIL host: no child data arrived\n"); return 1; }
    printf("  host: DataRx header %08x payload %08x\n", r[0], r[1]);
    if (((r[0] >> 8) & 0x1F) != 4) {
        printf("  FAIL host: S0 length should be 4, header %08x\n", r[0]);
        return 1;
    }
    if (r[1] != 0xCAFEF00D) {
        printf("  FAIL host: payload should be CAFEF00D, got %08x\n", r[1]);
        return 1;
    }
    say("host", "PASS");
    pump(300);   // stay up while the child finishes its own checks
    return 0;
}

static int test_client(int port, const char *peer)
{
    uint32_t r[RFU_MAX_WORDS], p[8];
    int n, deadline;
    uint16_t pid = 0;

    rfu_core_init();
    if (rfu_net_open(port, 0) < 0)
        return 1;
    rfu_net_add_peer(peer, port);

    cmd(0x10, 0, NULL, r);
    cmd(0x1C, 0, NULL, r);
    say("client", "scanning");

    for (deadline = 0; deadline < 100; deadline++) {
        pump(50);
        n = cmd(0x1D, 0, NULL, r);
        if (n >= 7) { pid = r[0] & 0xffff; break; }
    }
    if (!pid) { printf("  FAIL client: found no parent\n"); return 1; }
    printf("  client: found parent %04x, broadcast[0]=%08x\n", pid, r[1]);
    if (r[1] != 0xA0A0A0A0) {
        printf("  FAIL client: broadcast payload wrong (%08x)\n", r[1]);
        return 1;
    }

    cmd(0x1E, 0, NULL, r);
    p[0] = pid;
    cmd(0x1F, 1, p, r);

    for (deadline = 0; deadline < 100; deadline++) {
        pump(50);
        n = cmd(0x20, 0, NULL, r);
        if (n == 1 && r[0] != 0x01000000)
            break;
    }
    if (r[0] == 0x02000000 || (r[0] & 0xff000000) == 0x02000000) {
        printf("  FAIL client: connection refused (%08x)\n", r[0]);
        return 1;
    }
    printf("  client: connected, id %04x slot %u -> player %u\n",
           r[0] & 0xffff, (r[0] >> 16) & 3, ((r[0] >> 16) & 3) + 1);
    cmd(0x21, 0, NULL, r);

    n = cmd(0x13, 0, NULL, r);
    if (n != 1 || (r[0] >> 24) != RFU_ST_CLIENT) {
        printf("  FAIL client: SystemStatus should be state 5, got %08x\n", r[0]);
        return 1;
    }

    // Child -> parent: 4 bytes, length in the S<clnum> field.
    p[0] = 4u << 8;          // slot 0
    p[1] = 0xCAFEF00D;
    cmd(0x25, 2, p, r);
    say("client", "sent 4 bytes to the parent");

    for (deadline = 0; deadline < 100; deadline++) {
        pump(50);
        n = cmd(0x26, 0, NULL, r);
        if (n >= 2)
            break;
    }
    if (n < 2) { printf("  FAIL client: no parent data arrived\n"); return 1; }
    printf("  client: DataRx header %08x payload %08x %08x\n", r[0], r[1], r[2]);
    if ((r[0] & 0x7f) != 8 || r[1] != 0xDEADBEEF || r[2] != 0x12345678) {
        printf("  FAIL client: parent payload wrong\n");
        return 1;
    }
    say("client", "PASS");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "unit")) {
        test_unit();
        printf(failures ? "UNIT FAILED (%d)\n" : "UNIT PASSED\n", failures);
        return failures ? 1 : 0;
    }
    if (argc == 4 && !strcmp(argv[1], "host"))
        return test_host(atoi(argv[2]), argv[3]);
    if (argc == 4 && !strcmp(argv[1], "client"))
        return test_client(atoi(argv[2]), argv[3]);

    fprintf(stderr, "usage: %s unit | host PORT PEER | client PORT PEER\n", argv[0]);
    return 2;
}
