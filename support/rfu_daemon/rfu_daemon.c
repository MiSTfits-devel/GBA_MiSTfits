// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// rfu_daemon: ARM-side half of the GBA Wireless Adapter (AGB-015)
// emulation. The FPGA (rtl/gba_wireless.vhd) implements the link-port
// transport (login, STWI framing, handshakes, clock reversal) and
// forwards every command packet here over the framework UART; this
// front end owns only the UART and the event loop. All adapter
// semantics live in rfu_core.c and the radio in rfu_net.c -- the same
// split gpSP uses between its SPI transport and rfu.c.
//
// UART framing (see gba_wireless.vhd header):
//   0x01 CC LL <LL words LE>  <- FPGA: REQ from the GBA
//   0x02 CC LL <LL words LE>  -> FPGA: ACK (CC already |0x80, or 0xEE)
//   0x03 CC PP <PP words LE>  -> FPGA: adapter-initiated cmd (reversal)
//   0x04 EV 00                <- FPGA: event (0 ping, 1 login, 2 reversal
//                                entered, 3 GBA acked notify, 4 watchdog)
//
// Command semantics per docs/agb015_protocol.md.
#include "rfu_core.h"
#include "rfu_net.h"
#include "netplay_host.h"
#include "netplay_proto.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef B921600           // absent on non-Linux dev hosts; target is Linux
#define B921600 B115200
#endif

#define RFU_UDP_PORT 55440

static int uart    = -1;
static int verbose = 0;

// --- hooks required by rfu_core.h ----------------------------------------

uint32_t rfu_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

void rfu_log(const char *fmt, ...)
{
    va_list ap;
    if (!verbose)
        return;
    va_start(ap, fmt);
    fprintf(stderr, "rfu: ");
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

// --- UART ----------------------------------------------------------------

static int uart_write_all(const uint8_t *b, size_t n)
{
    while (n) {
        ssize_t w = write(uart, b, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            perror("uart write");
            return -1;
        }
        b += w;
        n -= (size_t)w;
    }
    return 0;
}

// 0x02 ACK / 0x03 adapter-initiated command, payload little endian
static int send_packet(uint8_t type, uint8_t cc, uint8_t nwords, const uint32_t *w)
{
    uint8_t buf[3 + 4 * RFU_MAX_WORDS];
    size_t  n = 0;

    if (nwords > RFU_MAX_WORDS)
        return -1;
    buf[n++] = type;
    buf[n++] = cc;
    buf[n++] = nwords;
    for (int i = 0; i < nwords; i++) {
        buf[n++] = (uint8_t)(w[i]);
        buf[n++] = (uint8_t)(w[i] >> 8);
        buf[n++] = (uint8_t)(w[i] >> 16);
        buf[n++] = (uint8_t)(w[i] >> 24);
    }
    return uart_write_all(buf, n);
}

static void handle_req(uint8_t cmd, uint8_t len, const uint32_t *p)
{
    uint32_t resp[RFU_MAX_WORDS];
    int      n = rfu_core_command(cmd, len, p, resp);

    if (n < 0) {
        // rejection: the FPGA expects the 0xEE command with one reason word
        uint32_t reason = (uint32_t)(-n);
        rfu_log("req %02X len %u -> reject %u\n", cmd, len, reason);
        send_packet(0x02, 0xEE, 1, &reason);
        return;
    }

    rfu_log("req %02X len %u -> ack %d word(s) [%s]\n",
            cmd, len, n, rfu_core_state_name());
    send_packet(0x02, (uint8_t)(cmd | 0x80), (uint8_t)n, resp);

    // 0x25/0x27/0x37 hand the clock to us; arm the wait so the frame loop
    // can inject 0x28/0x29/0x27 once there is something to report.
    if (cmd == 0x25 || cmd == 0x27 || cmd == 0x37)
        rfu_core_wait_begin();
}

static void handle_event(uint8_t ev)
{
    switch (ev) {
    case 0x00:
        rfu_log("event: GPIO ping -> adapter reset\n");
        rfu_core_reset();
        break;
    case 0x01:
        rfu_log("event: login complete\n");
        break;
    case 0x02:
        rfu_log("event: clock reversed (adapter is master)\n");
        break;
    case 0x03:
        rfu_log("event: GBA acked our notify\n");
        break;
    case 0x04:
        rfu_log("event: word watchdog fired\n");
        break;
    default:
        rfu_log("event: unknown %02X\n", ev);
        break;
    }
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s [-d /dev/ttyS1] [-p port] [-P host[:port]] [-N port] [-L] [-v]\n"
        "  -d  UART device (default /dev/ttyS1)\n"
        "  -p  local UDP port (default %d)\n"
        "  -P  peer to talk to; repeatable. Needed only across the internet.\n"
        "  -N  also host a RetroArch netplay session on this TCP port, so a\n"
        "      RetroArch " NETPLAY_TARGET_VERSION " + gpSP client can join the room.\n"
        "  -L  disable LAN discovery (on by default)\n"
        "  -v  log adapter activity to stderr\n",
        argv0, RFU_UDP_PORT);
}

int main(int argc, char **argv)
{
    const char *dev  = "/dev/ttyS1";
    int         port = RFU_UDP_PORT;
    int         lan  = 1;
    int         np_port = 0;
    const char *peers[16];
    int         npeers = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc)      dev = argv[++i];
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-P") && i + 1 < argc) {
            if (npeers < (int)(sizeof(peers) / sizeof(peers[0])))
                peers[npeers++] = argv[++i];
            else
                i++;
        }
        else if (!strcmp(argv[i], "-L")) lan = 0;
        else if (!strcmp(argv[i], "-N") && i + 1 < argc) np_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else { usage(argv[0]); return 2; }
    }

    uart = open(dev, O_RDWR | O_NOCTTY);
    if (uart < 0) { perror(dev); return 1; }

    struct termios tio;
    if (tcgetattr(uart, &tio) == 0) {
        cfmakeraw(&tio);
        cfsetspeed(&tio, B921600);
        tio.c_cc[VMIN] = 1;
        tio.c_cc[VTIME] = 0;
        tcsetattr(uart, TCSANOW, &tio);
    }

    rfu_core_init();
    if (rfu_net_open(port, lan) < 0) {
        fprintf(stderr, "rfu_daemon: cannot open udp/%d\n", port);
        return 1;
    }
    for (int i = 0; i < npeers; i++)
        rfu_net_add_peer(peers[i], port);

    fprintf(stderr, "rfu_daemon: %s <-> udp/%d%s\n",
            dev, port, lan ? " (LAN discovery on)" : "");

    if (np_port > 0) {
        int bound = netplay_host_open(np_port);
        if (bound < 0)
            fprintf(stderr, "rfu_daemon: cannot host netplay on tcp/%d (%d)\n",
                    np_port, bound);
        else
            fprintf(stderr, "rfu_daemon: netplay host on tcp/%d "
                            "(RetroArch %s + gpSP may join)\n",
                    bound, NETPLAY_TARGET_VERSION);
    }

    // Single loop over both the UART and the socket. The ~60 Hz housekeeping
    // tick drives session timeouts and, while the clock is reversed, decides
    // when to inject the adapter-initiated notify the GBA is parked waiting
    // for -- so it must keep running even when the UART is silent.
    uint8_t  hdr[3];
    size_t   hgot = 0;
    uint8_t  raw[4 * RFU_MAX_WORDS];
    size_t   rgot = 0, rneed = 0;
    int      in_body = 0;
    uint32_t next_frame = rfu_now_ms();

    for (;;) {
        struct pollfd fds[2 + NETPLAY_HOST_MAX_CLIENTS + 1];
        fds[0].fd = uart;          fds[0].events = POLLIN; fds[0].revents = 0;
        fds[1].fd = rfu_net_fd();  fds[1].events = POLLIN; fds[1].revents = 0;
        int nfds = 2;

        if (np_port > 0) {
            int nplist[NETPLAY_HOST_MAX_CLIENTS + 1];
            int nnp = netplay_host_pollfds(nplist,
                          (int)(sizeof(nplist) / sizeof(nplist[0])));
            for (int i = 0; i < nnp; i++) {
                fds[nfds].fd = nplist[i];
                fds[nfds].events = POLLIN;
                fds[nfds].revents = 0;
                nfds++;
            }
        }

        int timeout = (int)(int32_t)(next_frame - rfu_now_ms());
        if (timeout < 0) timeout = 0;

        // A reversal wait has its own, much shorter deadline: the retransmit
        // window is ~11 ms against a 16 ms frame tick. Sleeping the full tick
        // makes us decide the wait only after that window shut, so a peer's
        // reply that genuinely arrived in time gets reported to the GBA as
        // "no child answered" -- which ends a Pokemon trade in
        // "Communication error". Never sleep past the nearer deadline.
        int wait_ms = rfu_core_wait_next_ms();
        if (wait_ms >= 0 && wait_ms < timeout)
            timeout = wait_ms;

        if (poll(fds, nfds, timeout) < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            return 1;
        }

        if (fds[0].revents & POLLIN) {
            if (!in_body) {
                ssize_t n = read(uart, hdr + hgot, 3 - hgot);
                if (n <= 0) { perror("uart read"); return 1; }
                hgot += (size_t)n;
                if (hgot == 3) {
                    hgot = 0;
                    if (hdr[2] > RFU_MAX_WORDS) {
                        fprintf(stderr, "rfu_daemon: bad length %u\n", hdr[2]);
                    } else {
                        rneed = 4u * hdr[2];
                        rgot  = 0;
                        in_body = 1;
                    }
                }
            }
            if (in_body) {
                while (rgot < rneed) {
                    ssize_t n = read(uart, raw + rgot, rneed - rgot);
                    if (n < 0) {
                        if (errno == EINTR) continue;
                        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                        perror("uart read");
                        return 1;
                    }
                    if (n == 0) { fprintf(stderr, "uart eof\n"); return 1; }
                    rgot += (size_t)n;
                }
                if (rgot == rneed) {
                    in_body = 0;
                    uint32_t w[RFU_MAX_WORDS];
                    for (int i = 0; i < hdr[2]; i++)
                        w[i] = (uint32_t)raw[4*i]
                             | ((uint32_t)raw[4*i+1] << 8)
                             | ((uint32_t)raw[4*i+2] << 16)
                             | ((uint32_t)raw[4*i+3] << 24);
                    if (hdr[0] == 0x01)      handle_req(hdr[1], hdr[2], w);
                    else if (hdr[0] == 0x04) handle_event(hdr[1]);
                }
            }
        }

        if (fds[1].revents & POLLIN)
            rfu_net_poll();

        if (np_port > 0)
            netplay_host_poll();

        if ((int32_t)(rfu_now_ms() - next_frame) >= 0) {
            next_frame += 16;                       // ~60 Hz
            if ((int32_t)(rfu_now_ms() - next_frame) > 100)
                next_frame = rfu_now_ms();          // fell behind; resync
            rfu_core_frame();
            rfu_net_tick();
        }

        // Evaluated EVERY iteration, not just on the frame tick: the wait's
        // retransmit window is shorter than a tick, and gpSP likewise force-
        // polls the network inside its wait ("otherwise we need to wait a
        // full frame!"). Checking this only at 60 Hz loses trades.
        {
            uint8_t  cmd = 0, nparams = 0;
            uint32_t params[RFU_MAX_WORDS];
            if (rfu_core_wait_poll(&cmd, &nparams, params)) {
                rfu_log("inject %02X (%u param words)\n", cmd, nparams);
                send_packet(0x03, cmd, nparams, params);
            }
        }
    }
}
