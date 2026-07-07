// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// rfu_daemon: ARM-side half of the GBA Wireless Adapter (AGB-015)
// emulation. The FPGA (rtl/gba_wireless.vhd) implements the link-port
// transport (login, STWI framing, handshakes, clock reversal) and
// forwards every command packet here over the framework UART; this
// daemon owns the RFU state machine -- the same split gpSP uses between
// its SPI transport and rfu.c.
//
// UART framing (see gba_wireless.vhd header):
//   0x01 CC LL <LL words LE>  <- FPGA: REQ from the GBA
//   0x02 CC LL <LL words LE>  -> FPGA: ACK (CC already |0x80, or 0xEE)
//   0x03 CC PP <PP words LE>  -> FPGA: adapter-initiated cmd (reversal)
//   0x04 EV 00                <- FPGA: event (0 ping, 1 login, 2 reversal
//                                entered, 3 GBA acked notify, 4 watchdog)
//
// Command semantics per docs/agb015_protocol.md. Networking (gpSP RFU1
// rooms over RetroArch netpacket / LAN TCP) plugs into net_* below --
// until that lands, this behaves like an adapter with no one else on
// the air: games boot their wireless menus, host, and scan cleanly.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>

#define MAXW 32

#ifndef B921600           // absent on non-Linux dev hosts; target is Linux
#define B921600 B115200
#endif

typedef enum { ST_N, ST_P, ST_PSC, ST_CSP, ST_CCP, ST_C } rfu_state_t;

static int uart = -1;
static rfu_state_t st = ST_N;
static uint16_t own_id = 0;
static uint8_t  avail_slots = 4, max_mframe = 4, mc_timer = 32;
static uint8_t  broadcast[24];
static int      reversed = 0;          // FPGA reported clock reversal
static int      wait_pending = 0;      // GBA parked in 0x27/0x25 wait

// --- networking hooks (RFU1 rooms; TODO: RetroArch netpacket client) ---
static void net_host_start(const uint8_t bc[24]) { (void)bc; }
static void net_host_stop(void) {}
static int  net_scan(uint8_t out[4][28])         { (void)out; return 0; }
static int  net_connect(uint16_t pid)            { (void)pid; return -1; }
static void net_send(const uint32_t *w, int n)   { (void)w; (void)n; }
static int  net_recv(uint32_t *w)                { (void)w; return 0; }

static void put_pkt(uint8_t type, uint8_t b1, uint8_t nwords, const uint32_t *w)
{
    uint8_t buf[3 + 4 * MAXW];
    buf[0] = type; buf[1] = b1; buf[2] = nwords;
    for (int i = 0; i < nwords; i++) {
        buf[3+4*i+0] = w[i] & 0xff;        buf[3+4*i+1] = (w[i] >> 8) & 0xff;
        buf[3+4*i+2] = (w[i] >> 16) & 0xff; buf[3+4*i+3] = (w[i] >> 24) & 0xff;
    }
    if (write(uart, buf, 3 + 4 * nwords) < 0) perror("uart write");
}
static void ack(uint8_t cmd, uint8_t nwords, const uint32_t *w)
{
    put_pkt(0x02, cmd | 0x80, nwords, w);
}
static void reject(uint8_t reason)
{
    uint32_t w = reason;
    put_pkt(0x02, 0xEE, 1, &w);
}

static void handle_req(uint8_t cmd, uint8_t len, const uint32_t *p)
{
    uint32_t r[MAXW];
    switch (cmd) {
    case 0x10: // Reset/hello
        st = ST_N; own_id = 0;
        ack(cmd, 0, NULL);
        break;
    case 0x11: // LinkStatus: 0xFF for connected slots
        r[0] = (st == ST_C) ? 0xFF : 0;
        ack(cmd, 1, r);
        break;
    case 0x13: // SystemStatus: id | slot bitmap | state
        r[0] = own_id | ((uint32_t)(st == ST_C ? 1 : 0) << 16) |
               ((uint32_t)(st == ST_PSC ? 2 : st == ST_P ? 1 :
                           st == ST_CSP ? 3 : st == ST_CCP ? 4 :
                           st == ST_C   ? 5 : 0) << 24);
        ack(cmd, 1, r);
        break;
    case 0x14: // SlotStatus: EntrySlot + connected children
        r[0] = (st == ST_PSC) ? 0 : 0xFF;
        ack(cmd, 1, r); // no children yet (net layer will add them)
        break;
    case 0x16: // GameConfig: store the 24 broadcast bytes
        for (int i = 0; i < 6 && i < len; i++)
            memcpy(broadcast + 4 * i, &p[i], 4);
        ack(cmd, 0, NULL);
        break;
    case 0x17: // SystemConfig
        if (len >= 1) {
            mc_timer    = p[0] & 0xff;
            max_mframe  = (p[0] >> 8) & 0xff;
            avail_slots = 4 - ((p[0] >> 16) & 3);
        }
        ack(cmd, 0, NULL);
        break;
    case 0x19: // SC_Start: host a room
        st = ST_PSC; own_id = 0x61f1;
        net_host_start(broadcast);
        ack(cmd, 0, NULL);
        break;
    case 0x1A: // SC_Polling: newly connected children (none yet)
        ack(cmd, 0, NULL);
        break;
    case 0x1B: // SC_End: close entry
        st = ST_P;
        ack(cmd, 0, NULL);
        break;
    case 0x1C: // SP_Start: scan
        st = ST_CSP;
        ack(cmd, 0, NULL);
        break;
    case 0x1D: case 0x1E: { // SP_Polling / SP_End: found parents
        uint8_t found[4][28];
        int n = net_scan(found);
        for (int i = 0; i < n; i++)
            memcpy(&r[7*i], found[i], 28);
        if (cmd == 0x1E) st = ST_N;
        ack(cmd, 7 * n, r);
        break; }
    case 0x1F: // CP_Start(pid)
        st = ST_CCP;
        (void)(len >= 1 && net_connect(p[0] & 0xffff));
        ack(cmd, 0, NULL);
        break;
    case 0x20: case 0x21: // CP_Polling / CP_End
        r[0] = 0x03000000; // parent not found (until net layer lands)
        if (cmd == 0x21) st = ST_N;
        ack(cmd, 1, r);
        break;
    case 0x24: case 0x25: // DataTx (&Change)
        if (len >= 1) net_send(p, len);
        ack(cmd, 0, NULL);
        break;
    case 0x26: { // DataRx
        int n = net_recv(r);
        ack(cmd, n, r);
        break; }
    case 0x27: // MS_Change (wait)
        wait_pending = 1;
        ack(cmd, 0, NULL);
        break;
    case 0x30: // Disconnect
        st = (st == ST_C) ? ST_N : st;
        ack(cmd, 0, NULL);
        break;
    case 0x32: case 0x33: case 0x34: // CPR: recovery -> fail cleanly
        r[0] = 1;
        ack(cmd, (cmd == 0x32) ? 0 : 1, r);
        break;
    case 0x3D: // StopMode: back to power-save
        st = ST_N; own_id = 0;
        ack(cmd, 0, NULL);
        break;
    default:
        reject((cmd >= 0x10 && cmd <= 0x3D) ? 1 : 2);
    }
    fprintf(stderr, "req %02X len %d -> state %d\n", cmd, len, st);
}

static void handle_event(uint8_t ev)
{
    fprintf(stderr, "event %d\n", ev);
    switch (ev) {
    case 0: st = ST_N; own_id = 0; reversed = 0; break; // ping reset
    case 2: // reversal entered: nothing to report yet -> hand the clock
            // back with a timeout MS_Change, like a real adapter whose
            // MasterChangeTimer expired (afska: EVENT_WAIT_TIMEOUT).
            // The net layer will instead inject 0x28 when data arrives.
        reversed = 1;
        if (wait_pending) {
            put_pkt(0x03, 0x27, 0, NULL);
            wait_pending = 0;
        }
        break;
    case 3: reversed = 0; break; // GBA acked our injected command
    }
}

int main(int argc, char **argv)
{
    const char *dev = (argc > 1) ? argv[1] : "/dev/ttyS1";
    uart = open(dev, O_RDWR | O_NOCTTY);
    if (uart < 0) { perror(dev); return 1; }

    struct termios tio;
    tcgetattr(uart, &tio);
    cfmakeraw(&tio);
    cfsetspeed(&tio, B921600);
    tio.c_cc[VMIN] = 1; tio.c_cc[VTIME] = 0;
    tcsetattr(uart, TCSANOW, &tio);

    fprintf(stderr, "rfu_daemon on %s\n", dev);

    uint8_t hdr[3];
    for (;;) {
        for (int got = 0; got < 3; ) {
            int n = read(uart, hdr + got, 3 - got);
            if (n <= 0) { perror("uart read"); return 1; }
            got += n;
        }
        uint8_t nwords = hdr[2];
        if (nwords > MAXW) { fprintf(stderr, "bad len %d\n", nwords); continue; }
        uint8_t raw[4 * MAXW];
        for (int got = 0; got < 4 * nwords; ) {
            int n = read(uart, raw + got, 4 * nwords - got);
            if (n <= 0) { perror("uart read"); return 1; }
            got += n;
        }
        uint32_t w[MAXW];
        for (int i = 0; i < nwords; i++)
            w[i] = raw[4*i] | (raw[4*i+1] << 8) | (raw[4*i+2] << 16) |
                   ((uint32_t)raw[4*i+3] << 24);

        if (hdr[0] == 0x01)      handle_req(hdr[1], nwords, w);
        else if (hdr[0] == 0x04) handle_event(hdr[1]);
    }
}
