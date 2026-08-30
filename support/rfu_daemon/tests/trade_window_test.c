// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>, Suibatsu Takumi
//
// Regression test for the trade-time "Communication error".
//
// A netplay/LAN peer's reply lands a few milliseconds after the GBA parks
// itself as clock slave. The adapter's retransmit window is ~11 ms, but the
// daemon used to evaluate the wait only on its 16 ms frame tick, so it always
// looked AFTER the window had closed and told the game "no child answered"
// (0x28 with 0x0F0F) even though the data arrived in time. Pokemon Emerald
// asks for one retransmit (0x37) and then drops the link.
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "rfu_core.h"
#include "rfu_net.h"
#include "rfu_proto.h"

static int failures;

// Controllable clock so the test is deterministic instead of wall-clock racy.
static uint32_t fake_ms;
uint32_t rfu_now_ms(void) { return fake_ms; }

void rfu_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "    | ");
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

#define CHECK(c, ...) do { \
    if (!(c)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); failures++; } \
} while (0)

// Intercept the transport so we can read CONNECT_ACK exactly as a gpSP child
// would, instead of reaching into core internals. Overrides the real
// rfu_net_send() at link time.
static uint16_t net_assigned_devid;
static int      net_assigned_slot = -1;

void rfu_net_send(int peer, const void *buf, size_t len)
{
    const uint8_t *b = buf;
    (void)peer;
    if (len >= 12 && be_get32(b) == RFU1_MAGIC &&
        be_get32(b + 4) == RFU1_CONNECT_ACK) {
        uint32_t h = be_get32(b + 8);
        net_assigned_devid = (uint16_t)(h & 0xffff);
        net_assigned_slot  = (int)((h >> 16) & 3);
    }
}

// Drive the core into a hosting session with one child attached.
// Returns the devid the core ASSIGNED to the child: a real gpSP child learns
// this from CONNECT_ACK and echoes it back in every CLIENT_SEND, and the host
// validates the slot against it.
static uint16_t setup_host_with_child(int peer)
{
    uint32_t resp[64];
    uint8_t  bc[RFU1_LEN_BCAST];
    uint8_t  rq[RFU1_LEN_CMD];
    uint32_t params[8];

    rfu_core_init();

    params[0] = 0;
    rfu_core_command(0x10, 0, params, resp);       // Hello/reset
    rfu_core_command(0x16, 0, params, resp);       // config (defaults)
    rfu_core_command(0x19, 0, params, resp);       // start hosting
    rfu_core_command(0x1A, 0, params, resp);       // poll host state

    memset(bc, 0, sizeof(bc));
    be_put32(bc + 0, RFU1_MAGIC);
    be_put32(bc + 4, RFU1_BROADCAST);
    be_put32(bc + 8, 0x87ae);
    rfu_core_net_receive(peer, bc, sizeof(bc));

    memset(rq, 0, sizeof(rq));
    be_put32(rq + 0, RFU1_MAGIC);
    be_put32(rq + 4, RFU1_CONNECT_REQ);
    be_put32(rq + 8, 0x87ae);
    rfu_core_net_receive(peer, rq, sizeof(rq));

    rfu_core_command(0x1A, 0, params, resp);

    // 0x11 (LinkStatus) reports a nonzero byte per occupied slot, which is how
    // we confirm the child really landed without reaching into core internals.
    if (rfu_core_command(0x11, 0, params, resp) >= 1 && (resp[0] & 0xFF) == 0)
        printf("WARNING: no child in slot 0 after CONNECT_REQ\n");

    return net_assigned_devid;
}

// Deliver a CLIENT_SEND frame the way a gpSP child answers the host.
static void child_sends(int peer, int slot, uint16_t devid,
                        const uint8_t *data, unsigned blen)
{
    uint8_t pkt[RFU1_LEN_DATA];
    memset(pkt, 0, sizeof(pkt));
    be_put32(pkt + 0, RFU1_MAGIC);
    be_put32(pkt + 4, RFU1_CLIENT_SEND);
    be_put32(pkt + 8, ((uint32_t)blen << 24) | ((uint32_t)slot << 16) | devid);
    memcpy(pkt + 12, data, blen);
    rfu_core_net_receive(peer, pkt, sizeof(pkt));
}

int main(void)
{
    uint8_t  cmd = 0, nparams = 0;
    uint32_t params[16];
    const int peer = RFU_NET_NETPLAY_BASE;   // a RetroArch netplay client

    printf("== trade-window regression ==\n");

    // ---- 1. the daemon must not sleep past the retransmit window ----
    fake_ms = 1000;
    uint16_t devid = setup_host_with_child(peer);
    CHECK(net_assigned_slot >= 0, "core never sent CONNECT_ACK");
    printf("child assigned devid=%04x slot=%d\n", devid, net_assigned_slot);
    rfu_core_wait_begin();

    int next = rfu_core_wait_next_ms();
    CHECK(next >= 0, "no wait deadline reported while a wait is armed");
    CHECK(next < 16, "wait deadline %d ms is >= the 16 ms frame tick, so the "
                     "daemon would sleep past the retransmit window and "
                     "report 'no child answered' before the reply lands", next);
    printf("wait_next_ms = %d (must be < 16)\n", next);

    // ---- 2. a reply inside the window counts as DATA, not silence ----
    // The GBA parks as slave; the child's answer arrives 5 ms later, well
    // inside the ~11 ms retransmit window.
    fake_ms += 5;
    uint8_t payload[16] = { 0xDE, 0xAD, 0xBE, 0xEF };
    child_sends(peer, net_assigned_slot, devid, payload, 8);

    int got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 1, "wait did not resolve after the child answered");
    CHECK(cmd == 0x28, "expected 0x28 (data available), got 0x%02X", cmd);
    CHECK(nparams == 0,
          "expected a plain data notify, got %u param word(s)%s",
          nparams,
          (nparams == 1 && params[0] == 0x0F0F)
              ? " = 0x0F0F 'no child answered' -- the child DID answer" : "");
    printf("in-window reply -> cmd=0x%02X nparams=%u\n", cmd, nparams);

    // ---- 3. genuine silence must still report 'no child answered' ----
    // Guards against "fixing" the bug by never reporting the timeout at all.
    // Drain the queued packet first via 0x26 (DataRx), otherwise data_avail()
    // legitimately fires on the frame we just delivered.
    uint32_t drain[64];
    rfu_core_command(0x26, 0, params, drain);

    rfu_core_wait_begin();
    fake_ms += 200;                       // far past every deadline
    cmd = 0; nparams = 0;
    params[0] = 0;
    got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 1, "silent wait never resolved");
    CHECK(cmd == 0x28, "expected 0x28 on silence, got 0x%02X", cmd);
    CHECK(nparams == 1 && params[0] == 0x0F0F,
          "expected the 0x0F0F 'no child answered' notify on real silence "
          "(nparams=%u params[0]=0x%08X)", nparams, params[0]);
    printf("silence -> cmd=0x%02X nparams=%u params[0]=0x%08X\n",
           cmd, nparams, nparams ? params[0] : 0);

    // ---- 4. with no wait armed there is no deadline to honour ----
    CHECK(rfu_core_wait_next_ms() < 0,
          "reported a deadline with no wait armed");

    if (failures) {
        printf("\n%d CHECK(s) FAILED\n", failures);
        return 1;
    }
    printf("\nTRADE WINDOW TEST PASSED\n");
    return 0;
}