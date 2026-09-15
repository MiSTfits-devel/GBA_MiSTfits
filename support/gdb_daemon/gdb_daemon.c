// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// gdb_daemon: HPS-side half of the GBA core's gdb stub. The FPGA
// (rtl/gba_gdb.vhd) owns the debug engine -- halting the ARM7TDMI, the
// breakpoint and watchpoint comparators, and access to registers and the GBA
// address space -- and exchanges commands with this process through a mailbox
// in DDR3. This end speaks the gdb remote serial protocol over TCP.
//
//   arm-none-eabi-gdb game.elf
//   (gdb) target remote <mister>:2345
//
// Same split rfu_daemon uses: transport and state machine in the fabric,
// protocol and sockets up here.
#include "gdb_mbox.h"
#include "gdb_proto.h"
#include "gdb_rsp.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEF_PORT   2345
#define POLL_MS    5

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
    if (listen(sock, 1) < 0) {
        perror("listen");
        close(sock);
        return -1;
    }
    return sock;
}

static int send_all(int fd, const char *buf, int len)
{
    int done = 0;
    while (done < len) {
        ssize_t n = write(fd, buf + done, (size_t)(len - done));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        done += (int)n;
    }
    return 0;
}

static int send_packet(int fd, const char *body)
{
    char frame[GDB_PKT_MAX + 8];
    int len = (int)strlen(body);
    uint8_t sum = gdb_checksum(body, len);

    if (len + 5 > (int)sizeof(frame))
        return -1;
    snprintf(frame, sizeof(frame), "$%s#%02x", body, sum);
    logmsg("-> %s\n", body);
    return send_all(fd, frame, len + 4);
}

// Feed received bytes through the framing state machine. Complete packets are
// dispatched; '+'/'-' acks and stray bytes are dropped.
struct framer {
    char buf[GDB_PKT_MAX + 8];
    int  len;
    int  in_packet;
    int  esc;
};

static void serve(int fd, struct gdb_rsp *rsp)
{
    struct framer fr;
    char reply[GDB_REPLY_MAX];
    int  on = 1;

    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    memset(&fr, 0, sizeof(fr));

    while (!rsp->detached) {
        struct pollfd pfd;
        char in[512];
        ssize_t n;
        int i;

        pfd.fd     = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, POLL_MS) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        // stop reply owed once the core actually halts
        if (gdb_rsp_poll(rsp, reply, sizeof(reply)) > 0 &&
            send_packet(fd, reply) < 0)
            break;

        if (!(pfd.revents & POLLIN))
            continue;

        n = read(fd, in, sizeof(in));
        if (n <= 0)
            break;

        for (i = 0; i < (int)n; i++) {
            char c = in[i];

            if (!fr.in_packet) {
                if (c == 0x03) {            // Ctrl-C
                    logmsg("<- interrupt\n");
                    gdb_rsp_interrupt(rsp);
                } else if (c == '$') {
                    fr.in_packet = 1;
                    fr.len = 0;
                    fr.esc = 0;
                }
                continue;
            }

            if (c == '#') {
                // two checksum bytes follow; consume them and dispatch
                int need = 2, got = 0;
                char ck[2];
                while (got < need) {
                    if (++i < (int)n) {
                        ck[got++] = in[i];
                    } else {
                        ssize_t k = read(fd, ck + got, (size_t)(need - got));
                        if (k <= 0)
                            return;
                        got += (int)k;
                    }
                }
                fr.buf[fr.len] = 0;
                fr.in_packet = 0;

                // gdb tolerates us not verifying, but a bad checksum means a
                // corrupt link and a retry is cheaper than a wrong command
                {
                    uint8_t want = (uint8_t)strtoul(
                        (char[3]){ ck[0], ck[1], 0 }, NULL, 16);
                    if (gdb_checksum(fr.buf, fr.len) != want) {
                        if (send_all(fd, "-", 1) < 0)
                            return;
                        continue;
                    }
                }
                if (send_all(fd, "+", 1) < 0)
                    return;

                logmsg("<- %s\n", fr.buf);
                {
                    int rl = gdb_rsp_packet(rsp, fr.buf, reply, sizeof(reply));
                    if (rl > 0 || (rl == 0 && !rsp->running && reply[0] == 0)) {
                        if (send_packet(fd, reply) < 0)
                            return;
                    }
                }
                continue;
            }

            if (fr.len < (int)sizeof(fr.buf) - 1) {
                // 0x7d escapes the next byte with bit 5 flipped
                if (fr.esc) {
                    fr.buf[fr.len++] = (char)(c ^ 0x20);
                    fr.esc = 0;
                } else if (c == 0x7d) {
                    fr.esc = 1;
                } else {
                    fr.buf[fr.len++] = c;
                }
            }
        }
    }
}

static void usage(const char *me)
{
    fprintf(stderr,
        "usage: %s [-p port] [-a phys] [-v]\n"
        "  -p port  TCP port to serve gdb on (default %d)\n"
        "  -a phys  DDR3 mailbox physical address (default 0x%08X)\n"
        "  -v       trace packets to stderr\n",
        me, DEF_PORT, GDB_MBOX_PHYS);
}

int main(int argc, char **argv)
{
    int port = DEF_PORT, lsock, i;
    unsigned long phys = GDB_MBOX_PHYS;
    struct gdb_mbox mb;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-p") && i + 1 < argc)
            port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-a") && i + 1 < argc)
            phys = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-v"))
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

    lsock = listen_on(port);
    if (lsock < 0) {
        gdb_mbox_close(&mb);
        return 1;
    }
    fprintf(stderr, "gdb: listening on port %d, mailbox 0x%08lx\n", port, phys);

    for (;;) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        struct gdb_rsp rsp;
        int fd = accept(lsock, (struct sockaddr *)&peer, &plen);

        if (fd < 0) {
            if (errno == EINTR)
                continue;
            perror("accept");
            break;
        }
        fprintf(stderr, "gdb: connected from %s\n", inet_ntoa(peer.sin_addr));

        gdb_rsp_init(&rsp, &mb);
        // gdb always expects to find the target stopped
        gdb_mbox_cmd(&mb, GDB_CMD_HALT, 0, 0, 0);
        serve(fd, &rsp);
        close(fd);

        // never leave the core frozen because a session dropped
        gdb_mbox_cmd(&mb, GDB_CMD_CONT, 0, 0, 0);
        fprintf(stderr, "gdb: disconnected\n");
    }

    close(lsock);
    gdb_mbox_close(&mb);
    return 0;
}
