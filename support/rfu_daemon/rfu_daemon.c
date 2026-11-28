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
//                                entered, 3 reverse ACK header, 4 watchdog)
//
// Command semantics per docs/agb015_protocol.md.
#include "rfu_core.h"
#include "rfu_net.h"
#include "rfu_proto.h"
#include "netplay_host.h"
#include "netplay_proto.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef B2000000          // PTY tests on development hosts without this rate
#define B2000000 B115200
#endif

#define RFU_UDP_PORT 55440
#define UART_FRAME_MAX (3 + 4 * RFU_MAX_WORDS)
// A maximum-length packet takes <12 ms even at the 115200 baud fallback.
#define UART_FRAME_TIMEOUT_MS 25

static int uart    = -1;
static int verbose = 0;

#define LOG_SLOTS 128u
#define LOG_LINE_MAX 256u
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "RFU log indices must be lock-free");

static struct {
    char line[LOG_SLOTS][LOG_LINE_MAX];
    atomic_uint write_pos, read_pos, dropped;
} logs;

// Timestamp the batch with the event loop's existing clock sample. The
// producer never needs to wake the writer or query the clock itself.
static uint64_t log_time_ms;

// The FPGA waits for each REQ's ACK. Keep one outbound frame intact across
// short writes, and defer dispatching any buffered requests until it drains.
static struct {
    uint8_t frame[UART_FRAME_MAX];
    size_t off, len;
} tx;

static struct {
    uint8_t frame[UART_FRAME_MAX];
    size_t have, need;
    uint32_t deadline;
    uint8_t input[512];
    size_t off, len;
} rx = { .need = 3 };

// --- hooks required by rfu_core.h ----------------------------------------

static uint64_t monotonic_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + ts.tv_nsec / 1000000u;
}

uint32_t rfu_now_ms(void)
{
    return (uint32_t)monotonic_ms();
}

void rfu_log(const char *fmt, ...)
{
    if (!verbose)
        return;

    unsigned pos = atomic_load_explicit(&logs.write_pos, memory_order_relaxed);
    unsigned read = atomic_load_explicit(&logs.read_pos, memory_order_acquire);
    if (pos - read == LOG_SLOTS) {
        // Only the producer increments this counter.
        unsigned dropped = atomic_load_explicit(&logs.dropped, memory_order_relaxed);
        atomic_store_explicit(&logs.dropped, dropped + 1, memory_order_relaxed);
        return;
    }

    char *line = logs.line[pos % LOG_SLOTS];
    int prefix = snprintf(line, LOG_LINE_MAX, "rfu: t_ms=%" PRIu64 " ", log_time_ms);
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line + prefix, LOG_LINE_MAX - (size_t)prefix, fmt, ap);
    va_end(ap);
    // Preserve record boundaries if a diagnostic is truncated.
    if (n < 0 || (size_t)n >= LOG_LINE_MAX - (size_t)prefix) {
        line[LOG_LINE_MAX - 2] = '\n';
        line[LOG_LINE_MAX - 1] = '\0';
    }
    atomic_store_explicit(&logs.write_pos, pos + 1, memory_order_release);
}

static int log_write(const char *line)
{
    size_t left = strlen(line);
    while (left) {
        ssize_t n = write(STDERR_FILENO, line, left);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        line += n;
        left -= (size_t)n;
    }
    return 0;
}

static void *log_writer(void *unused)
{
    (void)unused;
    // Losing a pipe reader must not terminate the UART process.
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &mask, NULL);

    unsigned pos = 0, reported_drops = 0;
    for (;;) {
        // Drain a snapshot so drop reports are not starved by a busy producer.
        unsigned end = atomic_load_explicit(&logs.write_pos, memory_order_acquire);
        int idle = pos == end;
        while (pos != end) {
            if (log_write(logs.line[pos % LOG_SLOTS]) < 0)
                return NULL;
            atomic_store_explicit(&logs.read_pos, ++pos, memory_order_release);
        }
        unsigned dropped = atomic_load_explicit(&logs.dropped, memory_order_relaxed);
        if (dropped != reported_drops) {
            char notice[64];
            snprintf(notice, sizeof(notice), "rfu: dropped %u log records\n",
                     dropped - reported_drops);
            if (log_write(notice) < 0)
                return NULL;
            reported_drops = dropped;
        }
        if (idle)
            nanosleep(&(const struct timespec){ .tv_nsec = 4000000 }, NULL);
    }
}

// --- UART ----------------------------------------------------------------

static void log_packet(const char *dir, uint8_t cmd, uint8_t words,
                       const uint32_t *p)
{
    if (!verbose)
        return;
    char first[22] = "-";
    if (words > 1)
        snprintf(first, sizeof(first), "%08" PRIX32 ",%08" PRIX32, p[0], p[1]);
    else if (words)
        snprintf(first, sizeof(first), "%08" PRIX32, p[0]);
    rfu_log("uart=%s cmd=0x%02X words=%u first=%s state=%s\n",
            dir, cmd, words, first, rfu_core_state_name());
}

static int uart_flush(void)
{
    ssize_t n = write(uart, tx.frame + tx.off, tx.len - tx.off);
    if (n > 0) {
        tx.off += (size_t)n;
        if (tx.off == tx.len)
            tx.off = tx.len = 0;
        return 0;
    }
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;  // resume at the same offset on POLLOUT
    if (n == 0)
        errno = EIO;
    rfu_log("uart write failed: errno=%d\n", errno);
    return -1;
}

// 0x02 ACK / 0x03 adapter-initiated command, payload little endian
static int send_packet(uint8_t type, uint8_t cc, uint8_t nwords, const uint32_t *w)
{
    if (nwords > RFU_MAX_WORDS) {
        rfu_log("invalid UART transmit length: %u words\n", nwords);
        return -1;
    }
    tx.frame[0] = type;
    tx.frame[1] = cc;
    tx.frame[2] = nwords;
    for (int i = 0; i < nwords; i++)
        le_put32(tx.frame + 3 + 4 * i, w[i]);
    tx.len = 3 + 4u * nwords;
    return uart_flush();
}

static int handle_req(uint8_t cmd, uint8_t len, const uint32_t *p)
{
    uint32_t resp[RFU_MAX_WORDS];
    log_packet("req", cmd, len, p);
    int n = rfu_core_command(cmd, len, p, resp);

    if (n < 0) {
        // rejection: the FPGA expects the 0xEE command with one reason word
        uint32_t reason = (uint32_t)(-n);
        log_packet("reject", 0xEE, 1, &reason);
        return send_packet(0x02, 0xEE, 1, &reason);
    }

    log_packet("ack", (uint8_t)(cmd | 0x80), (uint8_t)n, resp);

    // Arm on a successful clock-change ACK. The FPGA reports the handoff.
    if (cmd == 0x25 || cmd == 0x27 || cmd == 0x35 || cmd == 0x37)
        rfu_core_wait_begin();
    return send_packet(0x02, (uint8_t)(cmd | 0x80), (uint8_t)n, resp);
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
        // Only now is the GBA listening as clock slave, so only now may the
        // armed wait resolve into an injected notify.
        rfu_core_wait_reversed();
        break;
    case 0x03:
        rfu_log("event: received GBA notify ACK header\n");
        break;
    case 0x04:
        rfu_log("event: word watchdog fired\n");
        rfu_core_wait_cancel();
        break;
    default:
        rfu_log("event: unknown %02X\n", ev);
        break;
    }
}

static int is_uart_sync(uint8_t b)
{
    return b == 0x01 || b == 0x04;
}

static void uart_rx_reset(void)
{
    rx.have = 0;
    rx.need = 3;
}

static void uart_rx_expire(uint32_t now)
{
    if (rx.have && (int32_t)(now - rx.deadline) >= 0) {
        rfu_log("uart=rx drop=timeout have=%zu need=%zu\n", rx.have, rx.need);
        // The UART format has no checksum or escaped sync bytes. Payload
        // cannot be scanned for headers; recover at the next frame boundary.
        uart_rx_reset();
    }
}

static int uart_dispatch(uint32_t now)
{
    while (rx.off < rx.len && !tx.len) {
        if (!rx.have) {
            uint8_t b = rx.input[rx.off++];
            if (!is_uart_sync(b))
                continue;
            rx.frame[rx.have++] = b;
            rx.deadline = now + UART_FRAME_TIMEOUT_MS;
        }

        size_t n = rx.need - rx.have;
        if (n > rx.len - rx.off)
            n = rx.len - rx.off;
        if (n) {
            memcpy(rx.frame + rx.have, rx.input + rx.off, n);
            rx.have += n;
            rx.off += n;
        }
        if (rx.have != rx.need)
            break;

        uint8_t type = rx.frame[0], cmd = rx.frame[1], words = rx.frame[2];
        if (rx.need == 3) {
            if (words > RFU_MAX_WORDS || (type == 0x04 && words != 0)) {
                rfu_log("uart=rx drop=bad_header type=0x%02X cmd=0x%02X words=%u\n",
                        type, cmd, words);
                uart_rx_reset();
                // Keep any suffix that can start a new header.
                if (is_uart_sync(cmd)) {
                    rx.frame[0] = cmd;
                    rx.frame[1] = words;
                    rx.have = 2;
                } else if (is_uart_sync(words)) {
                    rx.frame[0] = words;
                    rx.have = 1;
                }
                rx.deadline = now + UART_FRAME_TIMEOUT_MS;
                continue;
            }
            if (words) {
                rx.need += 4u * words;
                continue;
            }
        }

        uart_rx_reset();
        if (type == 0x04) {
            handle_event(cmd);
        } else {
            uint32_t w[RFU_MAX_WORDS];
            for (int i = 0; i < words; i++)
                w[i] = le_get32(rx.frame + 3 + 4 * i);
            if (handle_req(cmd, words, w) < 0)
                return -1;
        }
    }
    return 0;
}

static int uart_read_input(void)
{
    ssize_t n = read(uart, rx.input, sizeof(rx.input));
    if (n > 0) {
        rx.off = 0;
        rx.len = (size_t)n;
        return 0;
    }
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;
    if (n == 0)
        rfu_log("uart eof\n");
    else
        rfu_log("uart read failed: errno=%d\n", errno);
    return -1;
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

    uart = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (uart < 0) { perror(dev); return 1; }

    struct termios tio;
    if (tcgetattr(uart, &tio) < 0) {
        perror("uart tcgetattr");
        return 1;
    }
    cfmakeraw(&tio);
    tio.c_cc[VMIN] = 1;
    tio.c_cc[VTIME] = 0;
    if (cfsetspeed(&tio, B2000000) < 0 || tcsetattr(uart, TCSANOW, &tio) < 0) {
        perror("uart tcsetattr");
        return 1;
    }

    if (verbose) {
        pthread_t writer;
        int error = pthread_create(&writer, NULL, log_writer, NULL);
        if (error) {
            fprintf(stderr, "rfu_daemon: cannot start log writer: %s\n", strerror(error));
            return 1;
        }
        log_time_ms = monotonic_ms();
    }

    rfu_core_init();
    if (rfu_net_open(port, lan) < 0) {
        fprintf(stderr, "rfu_daemon: cannot open udp/%d\n", port);
        return 1;
    }
    for (int i = 0; i < npeers; i++)
        rfu_net_add_peer(peers[i], port);

    if (verbose)
        rfu_log("rfu_daemon: %s <-> udp/%d%s\n",
                dev, port, lan ? " (LAN discovery on)" : "");
    else
        fprintf(stderr, "rfu_daemon: %s <-> udp/%d%s\n",
                dev, port, lan ? " (LAN discovery on)" : "");

    if (np_port > 0) {
        int bound = netplay_host_open(np_port);
        if (bound < 0) {
            if (verbose)
                rfu_log("rfu_daemon: cannot host netplay on tcp/%d (%d)\n", np_port, bound);
            else
                fprintf(stderr, "rfu_daemon: cannot host netplay on tcp/%d (%d)\n", np_port, bound);
        } else if (verbose) {
            rfu_log("rfu_daemon: netplay host on tcp/%d (RetroArch %s + gpSP may join)\n",
                    bound, NETPLAY_TARGET_VERSION);
        } else {
            fprintf(stderr, "rfu_daemon: netplay host on tcp/%d (RetroArch %s + gpSP may join)\n",
                    bound, NETPLAY_TARGET_VERSION);
        }
    }

    // Single loop over both the UART and the socket. The ~60 Hz housekeeping
    // tick drives session timeouts and, while the clock is reversed, decides
    // when to inject the adapter-initiated notify the GBA is parked waiting
    // for -- so it must keep running even when the UART is silent.
    uint32_t next_frame = rfu_now_ms();

    for (;;) {
        struct pollfd fds[2 + NETPLAY_HOST_MAX_CLIENTS + 1];
        fds[0].fd = uart;
        fds[0].events = tx.len ? POLLOUT : POLLIN;
        fds[0].revents = 0;
        fds[1].fd = rfu_net_fd();  fds[1].events = POLLIN; fds[1].revents = 0;
        int nfds = 2;

        if (np_port > 0)
            nfds += netplay_host_pollfds(fds + nfds, NETPLAY_HOST_MAX_CLIENTS + 1);

        uint32_t now = rfu_now_ms();
        int timeout = (int32_t)(next_frame - now);
        if (rx.have) {
            int rx_ms = (int32_t)(rx.deadline - now);
            if (rx_ms < timeout)
                timeout = rx_ms;
        }
        if (timeout < 0 || (!tx.len && rx.off < rx.len))
            timeout = 0;

        // A reversal can be due before the next housekeeping tick.
        int wait_ms = tx.len ? -1 : rfu_core_wait_next_ms();
        if (wait_ms >= 0 && wait_ms < timeout)
            timeout = wait_ms;

        if (poll(fds, nfds, timeout) < 0) {
            if (errno == EINTR) continue;
            rfu_log("poll failed: errno=%d\n", errno);
            return 1;
        }

        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            rfu_log("uart poll error: revents=0x%X\n", fds[0].revents);
            return 1;
        }
        log_time_ms = monotonic_ms();
        now = (uint32_t)log_time_ms;
        uart_rx_expire(now);
        if ((fds[0].revents & POLLOUT) && uart_flush() < 0)
            return 1;
        // At most one bounded read per iteration; even a continuously ready
        // UART must give the UDP/TCP sockets and housekeeping their turn.
        if (!tx.len) {
            if (rx.off == rx.len && (fds[0].revents & POLLIN) &&
                uart_read_input() < 0)
                return 1;
            if (uart_dispatch(now) < 0)
                return 1;
        }

        if (fds[1].revents & POLLIN)
            rfu_net_poll();

        if (np_port > 0)
            netplay_host_poll(fds + 2, nfds - 2);

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
        if (!tx.len) {
            uint8_t  cmd = 0, nparams = 0;
            uint32_t params[RFU_MAX_WORDS];
            if (rfu_core_wait_poll(&cmd, &nparams, params)) {
                if (cmd != 0x28) // the core logs this notify with its bitmaps
                    log_packet("notify", cmd, nparams, params);
                if (send_packet(0x03, cmd, nparams, params) < 0)
                    return 1;
            }
        }
    }
}
