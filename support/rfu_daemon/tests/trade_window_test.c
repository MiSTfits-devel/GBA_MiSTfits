// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>, Suibatsu Takumi
//
// Regression test for the trade-time "Communication error".
//
// A netplay/LAN peer's reply can take longer than the local-radio retransmit
// window (~11 ms). Wait for live peers instead of reporting premature failure
// to Emerald, and never imply that slots ACKed when they did not.
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
static unsigned host_sends;
static int last_target;
static unsigned last_byte_count;
static uint32_t last_payload;

void rfu_net_send(int peer, const void *buf, size_t len)
{
    const uint8_t *b = buf;
    if (len < 12 || be_get32(b) != RFU1_MAGIC)
        return;
    if (be_get32(b + 4) == RFU1_CONNECT_ACK) {
        uint32_t h = be_get32(b + 8);
        net_assigned_devid = (uint16_t)(h & 0xffff);
        net_assigned_slot  = (int)((h >> 16) & 3);
    } else if (be_get32(b + 4) == RFU1_HOST_SEND && len >= RFU1_LEN_DATA) {
        host_sends++;
        last_target = peer;
        last_byte_count = be_get32(b + 8);
        last_payload = le_get32(b + 12);
    }
}

// Commands from a gpSP child carry the parent-assigned device ID and slot.
static void child_control(int peer, unsigned type, uint32_t h)
{
    uint8_t pkt[RFU1_LEN_CMD] = { 0 };
    be_put32(pkt, RFU1_MAGIC);
    be_put32(pkt + 4, type);
    be_put32(pkt + 8, h);
    rfu_core_net_receive(peer, pkt, sizeof(pkt));
}

static void child_ack(int peer, int slot, uint16_t devid)
{
    child_control(peer, RFU1_CLIENT_ACK, (uint32_t)slot << 16 | devid);
}

// Set up a host and learn the assigned ID exactly as a child would.
static uint16_t setup_host_with_child(int peer)
{
    uint32_t resp[RFU_MAX_WORDS];
    rfu_core_init();

    rfu_core_command(0x19, 0, NULL, resp);
    net_assigned_slot = -1;
    child_control(peer, RFU1_CONNECT_REQ, 0);
    CHECK(net_assigned_slot == 0, "first child not assigned slot 0");

    return net_assigned_devid;
}

static void setup_child(int peer, unsigned slot)
{
    uint8_t bcast[RFU1_LEN_BCAST] = {0};
    uint32_t resp[RFU_MAX_WORDS], pid = 0x5678;
    rfu_core_init();
    be_put32(bcast, RFU1_MAGIC);
    be_put32(bcast + 4, RFU1_BROADCAST);
    be_put32(bcast + 8, pid);
    rfu_core_net_receive(peer, bcast, sizeof(bcast));
    CHECK(rfu_core_command(0x1F, 1, &pid, resp) == 0, "child CP_Start failed");
    child_control(peer, RFU1_CONNECT_ACK, (slot << 16) | 0x1234);
    CHECK(rfu_core_state() == RFU_ST_CLIENT, "failed to connect as child");
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

    const uint32_t frame[] = { 4, 0x12345678 };
    printf("== trade-window regression ==\n");

    // ---- 1. a live peer gets the full wait deadline ----
    fake_ms = 1000;
    uint16_t devid = setup_host_with_child(peer);
    CHECK(net_assigned_slot >= 0, "core never sent CONNECT_ACK");
    printf("child assigned devid=%04x slot=%d\n", devid, net_assigned_slot);
    rfu_core_command(0x25, 2, frame, params);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();

    int next = rfu_core_wait_next_ms();
    CHECK(next >= 0, "no wait deadline reported while a wait is armed");
    // With a live peer we intentionally hold out for the full timeout rather
    // than the ~11 ms retransmit window: that window models a local radio, but
    // our peer is a TCP round trip away. (An earlier version of this test
    // asserted next < 16 and drove exactly the regression that killed trades
    // on their first exchange.)
    CHECK(next > 100,
          "wait deadline %d ms is short enough to fire the retransmit path "
          "while a live peer's reply is still in flight", next);
    printf("wait_next_ms = %d (live peer: full timeout)\n", next);

    // ---- 2. a reply inside the window counts as DATA, not silence ----
    // The GBA parks as slave; the child's answer arrives 5 ms later, well
    // inside the ~11 ms retransmit window.
    fake_ms += 5;
    uint8_t payload[16] = { 0xDE, 0xAD, 0xBE, 0xEF };
    child_ack(peer, net_assigned_slot, devid);
    child_sends(peer, net_assigned_slot, devid, payload, 8);

    int got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 1, "wait did not resolve after the child answered");
    CHECK(cmd == 0x28, "expected 0x28 (data available), got 0x%02X", cmd);
    CHECK(nparams == 0, "expected a plain data notify, got %u param word(s)",
          nparams);
    printf("in-window reply -> cmd=0x%02X nparams=%u\n", cmd, nparams);

    // ---- 3. genuine silence must still report 'no child answered' ----
    // Guards against "fixing" the bug by never reporting the timeout at all.
    // "Silence" now means the peer is genuinely GONE, not merely slow: the
    // child disconnects, so there is nobody left who could answer.
    uint32_t drain[64];
    rfu_core_command(0x26, 0, params, drain);

    child_control(peer, RFU1_DISCONNECT, (uint32_t)net_assigned_slot << 16 | devid);
    CHECK(!rfu_core_peer_live(), "peer still reported live after DISCONNECT");

    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    fake_ms += 200;                       // past the retransmit deadline
    cmd = 0; nparams = 0;
    params[0] = 0;
    got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 1, "silent wait never resolved");
    CHECK(cmd == 0x28, "expected 0x28 on silence, got 0x%02X", cmd);
    CHECK(nparams == 1 && params[0] == 0,
          "expected empty active and ACKed slot masks on silence "
          "(nparams=%u params[0]=0x%08X)", nparams, params[0]);
    printf("silence (peer gone) -> cmd=0x%02X nparams=%u params[0]=0x%08X\n",
           cmd, nparams, nparams ? params[0] : 0);

    // ---- 4. with no wait armed there is no deadline to honour ----
    CHECK(rfu_core_wait_next_ms() < 0,
          "reported a deadline with no wait armed");

    // Re-attach a child for the remaining latency tests.
    devid = setup_host_with_child(peer);

    // ---- 5. a LAN round trip must not read as "no child answered" ----
    // This is the real-hardware failure. The retransmit window is ~11 ms, but
    // a MiSTer<->laptop reply realistically lands tens of milliseconds later.
    // Reporting a failed transmission before that reply makes Emerald
    // abandon the trade on its first exchange.
    rfu_core_command(0x25, 2, frame, params);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();

    fake_ms += 40;                                 // past rtx (11 ms), not the
                                                   // ~533 ms overall deadline
    cmd = 0; nparams = 0; params[0] = 0;
    got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 0, "resolved 40ms into the wait while the peer was still live");

    // and when the reply finally lands, it must read as data
    child_ack(peer, net_assigned_slot, devid);
    child_sends(peer, net_assigned_slot, devid, payload, 8);
    cmd = 0; nparams = 0;
    got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 1 && cmd == 0x28 && nparams == 0,
          "late-but-valid reply not reported as data (got=%d cmd=0x%02X "
          "nparams=%u)", got, cmd, nparams);
    printf("late reply -> cmd=0x%02X nparams=%u\n", cmd, nparams);

    // ---- 6. the wait must not resolve before the clock actually reverses ----
    // wait_begin() runs at ACK time, but the GBA only becomes clock slave when
    // the FPGA reports the reversal. Resolving in between injects a notify
    // into a GBA that is not listening yet.
    rfu_core_command(0x26, 0, params, drain);      // drain
    rfu_core_wait_begin();                         // armed, NOT yet reversed
    child_sends(peer, net_assigned_slot, devid, payload, 8);
    cmd = 0; nparams = 0;
    got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 0,
          "wait resolved before the clock reversed (cmd=0x%02X) -- the notify "
          "would be injected while the GBA is still master", cmd);
    CHECK(rfu_core_wait_next_ms() < 0, "reported a deadline before reversal");
    printf("pre-reversal poll -> held (correct)\n");

    rfu_core_wait_reversed();
    got = rfu_core_wait_poll(&cmd, &nparams, params);
    CHECK(got == 1 && cmd == 0x28,
          "wait did not resolve once the reversal landed (got=%d cmd=0x%02X)",
          got, cmd);
    printf("post-reversal poll -> cmd=0x%02X\n", cmd);

    // ---- 7. DRAC partial ACK, resume, fresh Tx and slot reuse ----
    uint16_t first = setup_host_with_child(peer);
    child_control(peer + 1, RFU1_CONNECT_REQ, 0);
    uint16_t second = net_assigned_devid;
    CHECK(net_assigned_slot == 1, "second child not assigned slot 1");

    rfu_core_command(0x25, 2, frame, params);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    child_ack(peer, 0, first);
    child_ack(peer, 1, second);          // right CID, wrong peer
    child_sends(peer + 1, 1, second, payload, 8); // data is not an RFU1 ACK
    fake_ms += 40;
    CHECK(!rfu_core_wait_poll(&cmd, &nparams, params),
          "partial exchange resolved before the network grace period");
    fake_ms += 500;
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0x00000301,
          "expected active=0x3 acked=0x1; got cmd=0x%02X words=%u param=0x%08X",
          cmd, nparams, params[0]);
    CHECK(rfu_core_command(0x26, 0, NULL, drain) == 3 &&
          drain[0] == (8u << 13), "partial exchange lost slot 1's queued data");

    rfu_core_command(0x37, 0, NULL, params);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    child_ack(peer + 1, 1, second);
    fake_ms += 11;                        // no payload needed once all ACKed
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 && !nparams,
          "resuming retransmit lost slot 0's ACK or required inbound data");

    rfu_core_command(0x25, 2, frame, params);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    child_ack(peer, 0, first);
    child_control(peer, RFU1_DISCONNECT, first);
    child_control(peer + 2, RFU1_CONNECT_REQ, 0);
    CHECK(net_assigned_slot == 0, "disconnected slot was not reused");
    child_ack(peer + 2, 0, net_assigned_devid); // replacement wasn't sent this frame
    fake_ms += 533;
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0x00000200,
          "fresh Tx/reused slot inherited an ACK: 0x%08X", params[0]);

    const uint32_t disconnect_slot0 = 1;
    rfu_core_command(0x30, 1, &disconnect_slot0, params);
    rfu_core_command(0x25, 2, frame, params);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    fake_ms += 533;
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0x00000200,
          "expected only slot 1 active after local Disconnect: 0x%08X", params[0]);

    for (int i = 0; i < 240; i++)
        rfu_core_frame();
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    fake_ms += 11;
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0,
          "expired child remained active: 0x%08X", params[0]);

    // A child joining after DataTx neither delays the response nor receives
    // a staged frame on ResumeRetransmit. Do not report it as ACKed.
    first = setup_host_with_child(peer);
    CHECK(rfu_core_command(0x25, 2, frame, params) == 0, "valid DataTx rejected");
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    child_control(peer + 1, RFU1_CONNECT_REQ, 0);
    child_ack(peer, 0, first);
    fake_ms += 11;
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0x00000101,
          "new child was included in existing Tx: 0x%08X", params[0]);
    unsigned before = host_sends;
    CHECK(rfu_core_command(0x37, 0, NULL, params) == 0 && host_sends == before,
          "resend went to a non-target or to a child that already ACKed");

    // gpSP sends its final ACK just before Disconnect, while the parent is
    // still waiting for the result of DataTx & Change.
    first = setup_host_with_child(peer);
    CHECK(rfu_core_command(0x25, 2, frame, params) == 0, "final DataTx rejected");
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    child_ack(peer, 0, first);
    child_control(peer, RFU1_DISCONNECT, first);
    fake_ms += 11;
    CHECK(!rfu_core_peer_live(), "withdrawn child still live");
    CHECK(rfu_core_command(0x11, 0, NULL, drain) == 1 && drain[0] == 0,
          "LinkStatus still reports the withdrawn child");
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0x00000001,
          "final ACK lost on withdrawal: 0x%08X", params[0]);
    before = host_sends;
    CHECK(rfu_core_command(0x37, 0, NULL, params) == 0 && host_sends == before,
          "resend went to the withdrawn child");
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    fake_ms += 11;
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x28 &&
          nparams == 1 && params[0] == 0,
          "withdrawn child's ACK leaked into another report");

    // A malformed byte count must neither read stale data nor replace the
    // last valid frame while the game decides whether to resume retransmit.
    setup_host_with_child(peer);
    CHECK(rfu_core_command(0x25, 2, frame, params) == 0, "valid staged frame rejected");
    const uint32_t short_frame[] = { 8, 0xAABBCCDD };
    uint32_t oversized[24] = { 88 };
    before = host_sends;
    CHECK(rfu_core_command(0x25, 2, short_frame, params) == -1 &&
          rfu_core_command(0x24, 24, oversized, params) == -1 &&
          rfu_core_command(0x25, 0, NULL, params) == -1 && host_sends == before,
          "invalid DataTx was accepted/sent");
    CHECK(rfu_core_command(0x37, 0, NULL, params) == 0 && host_sends == before + 1 &&
          last_target == peer && last_payload == frame[1],
          "malformed DataTx overwrote the staged frame");

    // Retail librfu sends only the length word for a parent keepalive.
    // Stage a fresh null LLSF, including for reversal and retransmit, rather
    // than sending the first byte of the previous DataTx.
    const uint32_t null_frame = 1;
    const uint32_t missing_payload = 2;
    before = host_sends;
    CHECK(rfu_core_command(0x24, 1, &null_frame, params) == 0 &&
          host_sends == before + 1 && last_byte_count == 1 && last_payload == 0xFF,
          "DataTx did not send the retail null LLSF");
    CHECK(rfu_core_command(0x25, 2, frame, params) == 0, "valid DataTx rejected");
    before = host_sends;
    CHECK(rfu_core_command(0x25, 1, &null_frame, params) == 0 &&
          host_sends == before + 1 && last_byte_count == 1 && last_payload == 0xFF,
          "DataTx & Change did not send the retail null LLSF");
    CHECK(rfu_core_command(0x24, 1, &missing_payload, params) == -1 &&
          host_sends == before + 1, "other truncated DataTx accepted");
    CHECK(rfu_core_command(0x37, 0, NULL, params) == 0 &&
          host_sends == before + 2 && last_byte_count == 1 && last_payload == 0xFF,
          "retransmit did not preserve the retail null LLSF");

    static const uint32_t bad_child_frame[6] = { 17u << 18 };
    setup_child(peer, 2);
    CHECK(rfu_core_command(0x25, 6, bad_child_frame, params) == -1,
          "DataTx accepted a 17-byte child frame");
    rfu_core_wait_begin();
    child_control(peer, RFU1_DISCONNECT, (2u << 16) | 0x1234);
    CHECK(!rfu_core_wait_poll(&cmd, &nparams, params), "disconnect notify sent before reversal");
    rfu_core_wait_reversed();
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x29 &&
          nparams == 1 && params[0] == 0x00000004,
          "RFU1 disconnect stranded wait or lost CID-erased slot: 0x%08X", params[0]);

    setup_child(peer, 3);
    rfu_core_wait_begin();
    rfu_core_wait_reversed();
    rfu_core_peer_disconnected(peer);
    CHECK(rfu_core_wait_poll(&cmd, &nparams, params) && cmd == 0x29 &&
          nparams == 1 && params[0] == 0x00000108,
          "transport drop stranded wait or lost link-loss slot: 0x%08X", params[0]);

    if (failures) {
        printf("\n%d CHECK(s) FAILED\n", failures);
        return 1;
    }
    printf("\nTRADE WINDOW TEST PASSED\n");
    return 0;
}