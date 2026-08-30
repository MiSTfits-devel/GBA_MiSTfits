// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#include "rfu_core.h"
#include "rfu_net.h"
#include "rfu_proto.h"

#include <stdlib.h>

#define MAX_CLIENTS      4
#define MAX_PKTS         4     // RF frames buffered per direction
#define BCAST_PERIOD_FR 30     // announce twice a second, as gpSP does
#define CLIENT_TTL_FR  240     // 4 s without traffic drops a child
#define PEER_TTL_FR    255

#define DEF_TIMEOUT_FR  32     // SystemConfig mcTimer default (~533 ms)
#define DEF_RTXMAX       4

// A wait with "no limit" (mcTimer 0) still has to end: the GBA is parked as
// clock slave and only we can wake it. Fall back to the default window.
#define FRAMES_TO_MS(f) ((uint32_t)(f) * 1000u / 60u)

static int      state;
static uint8_t  cfg_timeout, cfg_rtxmax, cfg_avail_slots;
static uint32_t bdata[6];

static struct {
    uint16_t devid;
    uint8_t  tx_ttl;
    int      entry_open;
    struct {
        int      peer;
        uint16_t devid;
        uint16_t ttl;
        struct { uint8_t len; uint8_t data[16]; } pkts[MAX_PKTS];
    } clients[MAX_CLIENTS];
} host;

static struct {
    uint16_t devid;
    uint16_t clnum;
    int      host_peer;
    struct { uint8_t len; uint8_t data[128]; } pkts[MAX_PKTS];
} client;

static struct {
    uint8_t  valid;
    uint8_t  ttl;
    uint16_t devid;
    uint32_t data[6];
} peer_bcst[RFU_NET_MAX_PEERS];

static struct { uint32_t words[23]; uint8_t blen; } txbuf;

static int      wait_armed;
static uint32_t wait_deadline, rtx_deadline;

static const char *state_names[] = { "IDLE", "HOST", "HOST-OPEN",
                                     "SEARCH", "CONNECTING", "CLIENT" };

int rfu_core_state(void) { return state; }
const char *rfu_core_state_name(void) { return state_names[state]; }

static uint16_t new_devid(void)
{
    uint16_t n;
    do { n = (uint16_t)(rand() >> 5); } while (!n);
    return n;
}

static int is_host(void)
{
    return state == RFU_ST_HOST || state == RFU_ST_HOST_OPEN;
}

// --- RFU1 packet emission (gpsp/rfu.c wire format) -----------------------

static void net_cmd(int peer, uint32_t ptype, uint32_t h)
{
    uint8_t pkt[RFU1_LEN_CMD] = { 0 };
    be_put32(&pkt[0], RFU1_MAGIC);
    be_put32(&pkt[4], ptype);
    be_put32(&pkt[8], h);
    rfu_net_send(peer, pkt, sizeof(pkt));
}

static void net_bcast(void)
{
    uint8_t pkt[RFU1_LEN_BCAST];
    int i;
    be_put32(&pkt[0], RFU1_MAGIC);
    be_put32(&pkt[4], RFU1_BROADCAST);
    be_put32(&pkt[8], host.devid);
    for (i = 0; i < 6; i++)
        be_put32(&pkt[12 + 4 * i], bdata[i]);
    rfu_net_send(RFU_NET_BCAST, pkt, sizeof(pkt));
}

static void net_data(int peer, uint32_t ptype, uint32_t h,
                     const uint32_t *w, unsigned nbytes)
{
    uint8_t pkt[RFU1_LEN_DATA] = { 0 };
    unsigned i;
    be_put32(&pkt[0], RFU1_MAGIC);
    be_put32(&pkt[4], ptype);
    be_put32(&pkt[8], h);
    if (nbytes > 92) nbytes = 92;
    for (i = 0; i < nbytes; i++)
        pkt[12 + i] = (uint8_t)(w[i / 4] >> (8 * (i & 3)));
    rfu_net_send(peer, pkt, sizeof(pkt));
}

// --- lifecycle -----------------------------------------------------------

static void session_clear(void)
{
    memset(&host, 0, sizeof(host));
    memset(&client, 0, sizeof(client));
    client.host_peer = -1;
    memset(&txbuf, 0, sizeof(txbuf));
    state      = RFU_ST_IDLE;
    wait_armed = 0;
}

void rfu_core_init(void)
{
    cfg_timeout     = DEF_TIMEOUT_FR;
    cfg_rtxmax      = DEF_RTXMAX;
    cfg_avail_slots = MAX_CLIENTS;
    memset(bdata, 0, sizeof(bdata));
    memset(peer_bcst, 0, sizeof(peer_bcst));
    session_clear();
}

void rfu_core_reset(void)
{
    rfu_log("reset (ping)\n");
    rfu_core_init();
}

// --- data queues ---------------------------------------------------------

static int data_avail(void)
{
    int i;
    if (state == RFU_ST_CLIENT)
        return client.pkts[0].len != 0;
    if (is_host()) {
        for (i = 0; i < MAX_CLIENTS; i++)
            if (host.clients[i].devid && host.clients[i].pkts[0].len)
                return 1;
    }
    return 0;
}

// --- command dispatch ----------------------------------------------------

// DataTx staging: the length lives in the parent field for a host and in
// this unit's own S<n> field for a child (docs/agb015_protocol.md 0x24).
static int stage_tx(uint8_t len, const uint32_t *p)
{
    unsigned nw = len - 1u;
    if (nw > sizeof(txbuf.words) / sizeof(txbuf.words[0]))
        nw = sizeof(txbuf.words) / sizeof(txbuf.words[0]);

    if (is_host())
        txbuf.blen = p[0] & 0x7F;
    else if (state == RFU_ST_CLIENT)
        txbuf.blen = (p[0] >> (8 + client.clnum * 5)) & 0x1F;
    else
        return -1;

    memcpy(txbuf.words, &p[1], nw * sizeof(uint32_t));
    return 0;
}

// Puts the staged frame on the air. 0x24/0x25 send what they just staged,
// 0x37 resends it -- a real adapter keeps retransmitting until the next
// DataTx, so both end up here.
static int transmit_staged(void)
{
    int i;

    if (is_host()) {
        if (txbuf.blen <= 90)
            for (i = 0; i < MAX_CLIENTS; i++)
                if (host.clients[i].devid)
                    net_data(host.clients[i].peer, RFU1_HOST_SEND,
                             txbuf.blen, txbuf.words, txbuf.blen);
    } else if (state == RFU_ST_CLIENT) {
        if (txbuf.blen <= 16)
            net_data(client.host_peer, RFU1_CLIENT_SEND,
                     ((uint32_t)txbuf.blen << 24) |
                     ((uint32_t)client.clnum << 16) | client.devid,
                     txbuf.words, txbuf.blen);
    } else {
        return -1;
    }
    return 0;
}

int rfu_core_command(uint8_t cmd, uint8_t len, const uint32_t *p, uint32_t *resp)
{
    int i, n = 0;

    switch (cmd) {
    case 0x10: // Reset / Hello: session back to neutral, login kept
        session_clear();
        return 0;

    case 0x11: // LinkStatus: per-slot signal quality
        resp[0] = 0;
        if (is_host()) {
            for (i = 0; i < MAX_CLIENTS; i++)
                if (host.clients[i].devid)
                    resp[0] |= 0xFFu << (8 * i);
        } else if (state == RFU_ST_CLIENT) {
            resp[0] = 0xFFFFFFFF;
        }
        return 1;

    case 0x12: // VersionStatus
        resp[0] = 0x00830117;
        return 1;

    case 0x13: // SystemStatus: id | ChildUsingSlot<<16 | state<<24
        if (is_host())
            resp[0] = ((uint32_t)state << 24) | host.devid;
        else if (state == RFU_ST_CLIENT)
            resp[0] = ((uint32_t)RFU_ST_CLIENT << 24) |
                      ((uint32_t)(1u << client.clnum) << 16) | client.devid;
        else
            resp[0] = 0;
        return 1;

    case 0x14: // SlotStatus: next free slot, then one word per child
        if (!is_host())
            return 0;
        n = 1;
        resp[0] = 0xFF;
        for (i = 0; i < MAX_CLIENTS; i++) {
            if (host.clients[i].devid)
                resp[n++] = host.clients[i].devid | ((uint32_t)i << 16);
            else if (resp[0] == 0xFF && i < cfg_avail_slots)
                resp[0] = i;
        }
        return n;

    case 0x15: // ConfigStatus: nothing real to report
        memset(resp, 0, 8 * sizeof(uint32_t));
        return 8;

    case 0x16: // GameConfig: the 24 broadcast bytes
        for (i = 0; i < 6 && i < len; i++)
            bdata[i] = p[i];
        return 0;

    case 0x17: // SystemConfig
        if (len >= 1) {
            cfg_timeout     = p[0] & 0xff;
            cfg_rtxmax      = (p[0] >> 8) & 0xff;
            cfg_avail_slots = MAX_CLIENTS - ((p[0] >> 16) & 3);
        }
        return 0;

    case 0x18: // KeySetConfig: key sharing, accepted and ignored
        return 0;

    case 0x19: // SC_Start: host and accept children
        if (state == RFU_ST_CLIENT || state == RFU_ST_CONNECTING)
            return -1;
        if (!is_host()) {
            host.devid = new_devid();
            memset(host.clients, 0, sizeof(host.clients));
            rfu_log("hosting, device id %04x\n", host.devid);
        }
        state           = RFU_ST_HOST_OPEN;
        host.entry_open = 1;
        host.tx_ttl     = BCAST_PERIOD_FR; // announce on the next tick
        return 0;

    case 0x1A: // SC_Polling: every child currently connected
        if (!is_host())
            return -1;
        for (i = 0; i < MAX_CLIENTS; i++)
            if (host.clients[i].devid)
                resp[n++] = host.clients[i].devid | ((uint32_t)i << 16);
        return n;

    case 0x1B: // SC_End: stop accepting, keep the ones we have
        if (!is_host())
            return -1;
        host.entry_open = 0;
        for (i = 0; i < MAX_CLIENTS; i++)
            if (host.clients[i].devid)
                resp[n++] = host.clients[i].devid | ((uint32_t)i << 16);
        state = n ? RFU_ST_HOST : RFU_ST_IDLE;
        return n;

    case 0x1C: // SP_Start: scan for parents
        if (is_host())
            return -1;
        state = RFU_ST_SEARCH;
        return 0;

    case 0x1D: // SP_Polling
    case 0x1E: // SP_End (same response, then stop scanning)
        for (i = 0; i < RFU_NET_MAX_PEERS && n < 4 * 7; i++) {
            if (!peer_bcst[i].valid)
                continue;
            resp[n++] = peer_bcst[i].devid;  // byte2 EntrySlot 0 = accepting
            memcpy(&resp[n], peer_bcst[i].data, sizeof(peer_bcst[i].data));
            n += 6;
        }
        if (cmd == 0x1E)
            state = RFU_ST_IDLE;
        return n;

    case 0x1F: // CP_Start: connect to a parent by device id
        if (is_host())
            return -1;
        if (len >= 1) {
            uint16_t reqid = p[0] & 0xffff;
            for (i = 0; i < RFU_NET_MAX_PEERS; i++)
                if (peer_bcst[i].valid && peer_bcst[i].devid == reqid) {
                    net_cmd(i, RFU1_CONNECT_REQ, reqid);
                    state = RFU_ST_CONNECTING;
                    rfu_log("connecting to %04x (peer %d)\n", reqid, i);
                    return 0;
                }
            rfu_log("connect: no parent %04x in range\n", reqid);
        }
        return 0; // ACK anyway; CP_Polling reports the failure

    case 0x20: // CP_Polling
    case 0x21: // CP_End
        if (is_host())
            return -1;
        if (state == RFU_ST_CLIENT) {
            resp[0] = client.devid | ((uint32_t)client.clnum << 16);
        } else if (state == RFU_ST_CONNECTING && cmd == 0x20) {
            resp[0] = 0x01000000;            // still in process
        } else {
            resp[0] = (cmd == 0x20) ? 0x02000000 : 0x01000000;
            state   = RFU_ST_IDLE;
        }
        return 1;

    case 0x24: // DataTx
    case 0x25: // DataTx & Change (reversal follows the ACK)
        if (!len)
            return 0;
        if (stage_tx(len, p) < 0)
            return -1;
        return transmit_staged();

    case 0x37: // ResumeRetransmit & Change: resend the staged frame
        return transmit_staged();

    case 0x26: { // DataRx
        uint8_t  tmp[MAX_CLIENTS * 16] = { 0 };
        unsigned nbytes = 0;
        if (is_host()) {
            n = 1;
            resp[0] = 0;
            for (i = 0; i < MAX_CLIENTS; i++) {
                unsigned dlen = host.clients[i].pkts[0].len;
                if (dlen > 16) dlen = 16;
                if (!host.clients[i].devid || !dlen)
                    continue;
                memcpy(&tmp[nbytes], host.clients[i].pkts[0].data, dlen);
                nbytes  += dlen;
                resp[0] |= dlen << (8 + i * 5);
                memmove(&host.clients[i].pkts[0], &host.clients[i].pkts[1],
                        (MAX_PKTS - 1) * sizeof(host.clients[i].pkts[0]));
                host.clients[i].pkts[MAX_PKTS - 1].len = 0;
            }
            if (nbytes == 0)
                return 0;   // nothing received: empty ACK, not a zero header
            for (i = 0; i < (int)((nbytes + 3) / 4); i++)
                resp[n++] = le_get32(&tmp[i * 4]);
            return n;
        }
        if (state == RFU_ST_CLIENT) {
            unsigned dlen = client.pkts[0].len;
            if (!dlen)
                return 0;
            n = 1;
            resp[0] = dlen;
            for (i = 0; i < (int)((dlen + 3) / 4); i++)
                resp[n++] = le_get32(&client.pkts[0].data[i * 4]);
            memmove(&client.pkts[0], &client.pkts[1],
                    (MAX_PKTS - 1) * sizeof(client.pkts[0]));
            client.pkts[MAX_PKTS - 1].len = 0;
            return n;
        }
        return 0; }

    case 0x27: // MS_Change: ACK, then reversal
        return 0;

    case 0x30: // Disconnect
        if (state == RFU_ST_CLIENT) {
            net_cmd(client.host_peer, RFU1_DISCONNECT,
                    client.devid | ((uint32_t)client.clnum << 16));
            session_clear();
        } else if (is_host() && len >= 1) {
            for (i = 0; i < MAX_CLIENTS; i++)
                if ((p[0] & (1u << i)) && host.clients[i].devid) {
                    net_cmd(host.clients[i].peer, RFU1_DISCONNECT,
                            host.clients[i].devid | ((uint32_t)i << 16));
                    memset(&host.clients[i], 0, sizeof(host.clients[i]));
                }
        }
        return 0;

    case 0x32: // CPR_Start: link recovery, which we cannot do
        return 0;
    case 0x33: // CPR_Polling: 1 = child id erased, unrecoverable
    case 0x34: // CPR_End: 1 = failed
        resp[0] = 1;
        return 1;

    case 0x3D: // StopMode: back to power conservation
        session_clear();
        return 0;

    default:
        return (cmd >= 0x10 && cmd <= 0x3D) ? -1 : -2;
    }
}

// --- periodic ------------------------------------------------------------

void rfu_core_frame(void)
{
    int i;

    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (peer_bcst[i].valid && --peer_bcst[i].ttl == 0)
            peer_bcst[i].valid = 0;

    if (state == RFU_ST_HOST_OPEN && ++host.tx_ttl >= BCAST_PERIOD_FR) {
        host.tx_ttl = 0;
        net_bcast();
    }

    if (is_host()) {
        for (i = 0; i < MAX_CLIENTS; i++)
            if (host.clients[i].devid &&
                ++host.clients[i].ttl >= CLIENT_TTL_FR) {
                rfu_log("child slot %d timed out\n", i);
                memset(&host.clients[i], 0, sizeof(host.clients[i]));
            }
    }
}

// --- clock reversal ------------------------------------------------------

void rfu_core_wait_begin(void)
{
    uint32_t now = rfu_now_ms();
    uint8_t  tmo = cfg_timeout ? cfg_timeout : DEF_TIMEOUT_FR;
    wait_armed    = 1;
    wait_deadline = now + FRAMES_TO_MS(tmo);
    rtx_deadline  = now + FRAMES_TO_MS(cfg_rtxmax ? cfg_rtxmax : DEF_RTXMAX) / 6;
}

int rfu_core_wait_poll(uint8_t *cmd, uint8_t *nparams, uint32_t *params)
{
    uint32_t now = rfu_now_ms();

    if (!wait_armed)
        return 0;

    if (state == RFU_ST_IDLE) {
        // Nobody left to talk to: report the connection loss.
        *cmd = 0x29; *nparams = 1; params[0] = 0x0F;
    } else if (data_avail()) {
        *cmd = 0x28; *nparams = 0;
    } else if (is_host() && (int32_t)(now - rtx_deadline) >= 0) {
        // The retransmission window elapsed: send verified, no child answered.
        *cmd = 0x28; *nparams = 1; params[0] = 0x00000F0F;
    } else if ((int32_t)(now - wait_deadline) >= 0) {
        *cmd = 0x27; *nparams = 0;   // MasterChangeTimer expiry
    } else {
        return 0;
    }

    wait_armed = 0;
    return 1;
}

// --- inbound RFU1 --------------------------------------------------------

void rfu_core_net_receive(int peer, const void *buf, size_t len)
{
    const uint8_t *b = buf;
    uint32_t ptype, h;
    int i;

    if (len < 12 || be_get32(b) != RFU1_MAGIC || peer < 0 ||
        peer >= RFU_NET_MAX_PEERS)
        return;

    ptype = be_get32(&b[4]);
    h     = be_get32(&b[8]);

    switch (ptype) {
    case RFU1_BROADCAST:
        if (len < RFU1_LEN_BCAST)
            return;
        peer_bcst[peer].devid = h & 0xffff;
        peer_bcst[peer].valid = 1;
        peer_bcst[peer].ttl   = PEER_TTL_FR;
        for (i = 0; i < 6; i++)
            peer_bcst[peer].data[i] = be_get32(&b[12 + 4 * i]);
        break;

    case RFU1_CONNECT_REQ:
        if (state != RFU_ST_HOST_OPEN || !host.entry_open) {
            net_cmd(peer, RFU1_CONNECT_NACK, 0);
            return;
        }
        for (i = 0; i < MAX_CLIENTS; i++)
            if (host.clients[i].devid && host.clients[i].peer == peer)
                return;                       // already in, ignore the retry
        for (i = 0; i < cfg_avail_slots; i++)
            if (!host.clients[i].devid) {
                host.clients[i].devid = new_devid();
                host.clients[i].peer  = peer;
                host.clients[i].ttl   = 0;
                rfu_log("child joined slot %d as %04x (peer %d)\n",
                        i, host.clients[i].devid, peer);
                net_cmd(peer, RFU1_CONNECT_ACK,
                        host.clients[i].devid | ((uint32_t)i << 16));
                return;
            }
        net_cmd(peer, RFU1_CONNECT_NACK, 0);
        break;

    case RFU1_CONNECT_ACK:
        if (state != RFU_ST_CONNECTING)
            return;
        memset(&client, 0, sizeof(client));
        client.devid     = h & 0xffff;
        client.clnum     = (h >> 16) & 3;
        client.host_peer = peer;
        state            = RFU_ST_CLIENT;
        rfu_log("connected as child %d, id %04x\n", client.clnum, client.devid);
        break;

    case RFU1_CONNECT_NACK:
        if (state == RFU_ST_CONNECTING)
            state = RFU_ST_IDLE;
        break;

    case RFU1_DISCONNECT:
        if (is_host()) {
            int slot = (h >> 16) & 3;
            if (host.clients[slot].devid == (h & 0xffff)) {
                rfu_log("child slot %d left\n", slot);
                memset(&host.clients[slot], 0, sizeof(host.clients[slot]));
            }
        } else if (state == RFU_ST_CLIENT) {
            rfu_log("host dropped us\n");
            session_clear();
        }
        break;

    case RFU1_HOST_SEND: {
        unsigned blen = h & 0x7f;
        if (state != RFU_ST_CLIENT || len < blen + 12 || blen > 128)
            return;
        net_cmd(peer, RFU1_CLIENT_ACK,
                client.devid | ((uint32_t)client.clnum << 16));
        for (i = 0; i < MAX_PKTS; i++)
            if (!client.pkts[i].len) {
                memcpy(client.pkts[i].data, &b[12], blen);
                client.pkts[i].len = blen;
                return;
            }
        rfu_log("dropped a host frame (queue full)\n");
        break; }

    case RFU1_CLIENT_SEND: {
        unsigned blen = h >> 24;
        int slot = (h >> 16) & 3;
        if (!is_host() || len < blen + 12 || blen > 16)
            return;
        if (host.clients[slot].devid != (h & 0xffff))
            return;
        host.clients[slot].ttl = 0;
        for (i = 0; i < MAX_PKTS; i++)
            if (!host.clients[slot].pkts[i].len) {
                memcpy(host.clients[slot].pkts[i].data, &b[12], blen);
                host.clients[slot].pkts[i].len = blen;
                return;
            }
        rfu_log("dropped a child frame (queue full)\n");
        break; }

    case RFU1_CLIENT_ACK: {
        int slot = (h >> 16) & 3;
        if (is_host() && host.clients[slot].devid == (h & 0xffff))
            host.clients[slot].ttl = 0;
        break; }
    }
}
