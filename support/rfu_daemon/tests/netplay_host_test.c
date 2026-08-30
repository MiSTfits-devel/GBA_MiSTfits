// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>, Suibatsu Takumi
//
// Wire oracle for the RetroArch netplay HOST implementation.
//
// This test speaks the CLIENT side of RetroArch's netplay protocol exactly as
// netplay_frontend.c does at tag v1.22.2, against our host over a real TCP
// socket. If a stock RetroArch 1.22.2 + gpSP would be rejected, this fails.
//
// The values here are not invented: they are transcribed from
// network/netplay/netplay_frontend.c and netplay_protocol.h.
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include "netplay_proto.h"
#include "netplay_host.h"
#include "rfu_proto.h"

// Host-provided hooks that rfu_core/rfu_net expect from the daemon.
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

static int failures = 0;
#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); failures++; } \
} while (0)

// ---- blocking helpers on the client side ----
static int xread(int fd, void *buf, size_t len)
{
    uint8_t *p = buf; size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}
static int xwrite(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf; size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

// Pump the host until it makes progress; the host is single-threaded and
// non-blocking, so the test drives it explicitly.
static void pump(int times)
{
    for (int i = 0; i < times; i++) {
        netplay_host_poll();
        usleep(2000);
    }
}

int main(void)
{
    printf("== netplay host wire oracle (RetroArch %s, protocol %d) ==\n",
           NETPLAY_TARGET_VERSION, HIGH_NETPLAY_PROTOCOL_VERSION);

    // ---- host comes up on an ephemeral port ----
    int port = netplay_host_open(0);
    CHECK(port > 0, "netplay_host_open failed (%d)", port);
    if (port <= 0) { printf("cannot continue\n"); return 1; }
    printf("host listening on %d\n", port);

    // ---- client connects ----
    int cfd = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(cfd >= 0, "socket()");
    struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port   = htons((uint16_t)port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(connect(cfd, (struct sockaddr *)&sa, sizeof(sa)) == 0, "connect()");
    int one = 1; setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    pump(5);

    // ---- 1. connection header, 6 words, network order ----
    // RetroArch's client sends its HIGHEST supported protocol in the salt
    // field (header[3]) and its LOWEST in header[4] -- see the "HACK ALERT"
    // in netplay_frontend.c. A host that ignores this and answers with a
    // fixed version makes RetroArch abort with "Failed to initialize netplay".
    uint32_t hdr[6];
    hdr[0] = htonl(NETPLAY_MAGIC);
    hdr[1] = htonl(NETPLAY_PLATFORM_MAGIC_LE);
    hdr[2] = htonl(NETPLAY_COMPRESSION_SUPPORTED);
    hdr[3] = htonl(HIGH_NETPLAY_PROTOCOL_VERSION);  // salt hack: our high
    hdr[4] = htonl(LOW_NETPLAY_PROTOCOL_VERSION);   // our low
    hdr[5] = htonl(nph_impl_magic(NETPLAY_TARGET_VERSION,
                                  HIGH_NETPLAY_PROTOCOL_VERSION));
    CHECK(xwrite(cfd, hdr, sizeof(hdr)) == 0, "send client header");
    pump(10);

    uint32_t rhdr[6];
    CHECK(xread(cfd, rhdr, sizeof(rhdr)) == 0, "did not receive host header");
    CHECK(ntohl(rhdr[0]) == NETPLAY_MAGIC,
          "host magic: got 0x%08X want 0x%08X", ntohl(rhdr[0]), NETPLAY_MAGIC);
    CHECK(ntohl(rhdr[1]) == NETPLAY_PLATFORM_MAGIC_LE,
          "platform magic: got 0x%08X want 0x%08X",
          ntohl(rhdr[1]), NETPLAY_PLATFORM_MAGIC_LE);
    // The client rejects the host outright unless the negotiated protocol
    // sits inside its supported window.
    uint32_t neg = ntohl(rhdr[4]);
    CHECK(neg >= LOW_NETPLAY_PROTOCOL_VERSION &&
          neg <= HIGH_NETPLAY_PROTOCOL_VERSION,
          "negotiated protocol %u outside %d..%d -> RetroArch would abort "
          "with 'Failed to initialize netplay'",
          neg, LOW_NETPLAY_PROTOCOL_VERSION, HIGH_NETPLAY_PROTOCOL_VERSION);
    // We advertised 5..7, so a correct host picks 7.
    CHECK(neg == HIGH_NETPLAY_PROTOCOL_VERSION,
          "expected host to negotiate %d, got %u",
          HIGH_NETPLAY_PROTOCOL_VERSION, neg);
    uint32_t want_impl = nph_impl_magic(NETPLAY_TARGET_VERSION,
                                        HIGH_NETPLAY_PROTOCOL_VERSION);
    CHECK(ntohl(rhdr[5]) == want_impl,
          "impl magic: got 0x%08X want 0x%08X",
          ntohl(rhdr[5]), want_impl);
    printf("header ok (protocol=%u impl_magic=0x%08X)\n", neg, want_impl);

    // ---- 2. NICK exchange ----
    struct { uint32_t cmd[2]; char nick[NETPLAY_NICK_LEN]; } nick;
    memset(&nick, 0, sizeof(nick));
    nick.cmd[0] = htonl(NETPLAY_CMD_NICK);
    nick.cmd[1] = htonl(NETPLAY_NICK_LEN);
    snprintf(nick.nick, sizeof(nick.nick), "laptop");
    CHECK(xwrite(cfd, &nick, sizeof(nick)) == 0, "send NICK");
    pump(10);

    memset(&nick, 0, sizeof(nick));
    CHECK(xread(cfd, &nick, sizeof(nick)) == 0, "did not receive host NICK");
    CHECK(ntohl(nick.cmd[0]) == NETPLAY_CMD_NICK,
          "expected NICK, got cmd 0x%08X", ntohl(nick.cmd[0]));
    CHECK(ntohl(nick.cmd[1]) == NETPLAY_NICK_LEN,
          "NICK size: got %u want %u", ntohl(nick.cmd[1]), NETPLAY_NICK_LEN);
    printf("nick ok ('%.*s')\n", NETPLAY_NICK_LEN, nick.nick);

    // ---- 3. INFO: host sends {content_crc, core_name, core_version} ----
    struct info_s { uint32_t cmd[2]; uint32_t content_crc;
                    char core_name[NETPLAY_NICK_LEN];
                    char core_version[NETPLAY_NICK_LEN]; } info;
    memset(&info, 0, sizeof(info));
    CHECK(xread(cfd, &info, sizeof(info)) == 0, "did not receive host INFO");
    CHECK(ntohl(info.cmd[0]) == NETPLAY_CMD_INFO,
          "expected INFO, got cmd 0x%08X", ntohl(info.cmd[0]));
    CHECK(ntohl(info.cmd[1]) == sizeof(info) - sizeof(info.cmd),
          "INFO size: got %u want %zu",
          ntohl(info.cmd[1]), sizeof(info) - sizeof(info.cmd));
    printf("info ok (core='%.*s' ver='%.*s')\n",
           NETPLAY_NICK_LEN, info.core_name,
           NETPLAY_NICK_LEN, info.core_version);

    // client echoes its own INFO back (gpSP identifies itself here)
    memset(&info, 0, sizeof(info));
    info.cmd[0] = htonl(NETPLAY_CMD_INFO);
    info.cmd[1] = htonl(sizeof(info) - sizeof(info.cmd));
    info.content_crc = htonl(0);
    snprintf(info.core_name, sizeof(info.core_name), "gpSP");
    snprintf(info.core_version, sizeof(info.core_version), "v1.1.0-8d268a6");
    CHECK(xwrite(cfd, &info, sizeof(info)) == 0, "send client INFO");
    pump(10);

    // ---- 4. SYNC: host tells the client who it is ----
    // In packet-interface mode the client only needs its own client id.
    uint32_t sync_cmd[2];
    CHECK(xread(cfd, sync_cmd, sizeof(sync_cmd)) == 0, "did not receive SYNC");
    CHECK(ntohl(sync_cmd[0]) == NETPLAY_CMD_SYNC,
          "expected SYNC, got cmd 0x%08X", ntohl(sync_cmd[0]));
    uint32_t sync_len = ntohl(sync_cmd[1]);
    CHECK(sync_len > 0 && sync_len < 4096, "implausible SYNC size %u", sync_len);
    uint8_t *syncbuf = malloc(sync_len ? sync_len : 1);
    CHECK(xread(cfd, syncbuf, sync_len) == 0, "short SYNC body");
    printf("sync ok (%u bytes)\n", sync_len);
    free(syncbuf);
    pump(10);

    // ---- 5. the payoff: a netpacket relays as an RFU1 packet ----
    // The client sends an RFU1 broadcast exactly as gpSP's
    // rfu_net_send_bcast() does: netpacket to 0xffff, 36 bytes.
    uint8_t rfu[RFU1_LEN_BCAST];
    memset(rfu, 0, sizeof(rfu));
    be_put32(rfu + 0, RFU1_MAGIC);
    be_put32(rfu + 4, RFU1_BROADCAST);
    be_put32(rfu + 8, 0xDEADBEEF);   // devid

    uint32_t np[3];
    np[0] = htonl(NETPLAY_CMD_NETPACKET);
    np[1] = htonl(sizeof(rfu));
    np[2] = htonl(NETPLAY_NETPACKET_BROADCAST);
    CHECK(xwrite(cfd, np, sizeof(np)) == 0, "send netpacket header");
    CHECK(xwrite(cfd, rfu, sizeof(rfu)) == 0, "send netpacket body");
    pump(20);

    // The host must have handed those bytes to the RFU layer, addressed by a
    // peer index (the netplay client id).
    const uint8_t *got = NULL; size_t gotlen = 0; int gotpeer = -1;
    CHECK(netplay_host_test_last_rx(&gotpeer, &got, &gotlen) == 0,
          "host never delivered the netpacket to the RFU layer");
    if (got) {
        CHECK(gotlen == sizeof(rfu),
              "relayed length: got %zu want %zu", gotlen, sizeof(rfu));
        CHECK(be_get32(got) == RFU1_MAGIC,
              "relayed magic: got 0x%08X want 0x%08X",
              be_get32(got), RFU1_MAGIC);
        CHECK(be_get32(got + 8) == 0xDEADBEEF,
              "relayed devid: got 0x%08X", be_get32(got + 8));
        CHECK(gotpeer >= 0, "relayed peer index invalid (%d)", gotpeer);
        printf("netpacket relayed ok (peer=%d len=%zu)\n", gotpeer, gotlen);
    }

    // ---- 6. host -> client direction ----
    // What the RFU core sends must arrive as a well-formed netpacket command.
    uint8_t out[RFU1_LEN_CMD];
    memset(out, 0, sizeof(out));
    be_put32(out + 0, RFU1_MAGIC);
    be_put32(out + 4, RFU1_CONNECT_ACK);
    be_put32(out + 8, 0x00010002);
    netplay_host_send(gotpeer >= 0 ? gotpeer : 0, out, sizeof(out));
    pump(20);

    uint32_t rnp[3];
    CHECK(xread(cfd, rnp, sizeof(rnp)) == 0, "no netpacket from host");
    CHECK(ntohl(rnp[0]) == NETPLAY_CMD_NETPACKET,
          "expected NETPACKET, got 0x%08X", ntohl(rnp[0]));
    CHECK(ntohl(rnp[1]) == sizeof(out),
          "netpacket len: got %u want %zu", ntohl(rnp[1]), sizeof(out));
    uint8_t rbody[RFU1_LEN_CMD];
    CHECK(xread(cfd, rbody, sizeof(rbody)) == 0, "short netpacket body");
    CHECK(be_get32(rbody) == RFU1_MAGIC, "downstream magic 0x%08X",
          be_get32(rbody));
    CHECK(be_get32(rbody + 4) == RFU1_CONNECT_ACK, "downstream type %u",
          be_get32(rbody + 4));
    printf("downstream netpacket ok\n");

    close(cfd);
    netplay_host_close();

    if (failures) {
        printf("\n%d CHECK(s) FAILED\n", failures);
        return 1;
    }
    printf("\nNETPLAY HOST WIRE ORACLE PASSED\n");
    return 0;
}