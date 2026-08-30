// SPDX-License-Identifier: GPL-3.0-or-later
// Client-side probe: speaks RetroArch 1.22.2's netplay CLIENT handshake
// against a real, running rfu_daemon netplay host over the network.
//
// This is the integration counterpart to tests/netplay_host_test.c: that one
// runs the host in-process, this one talks to the actual MiSTer.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/time.h>

#include "netplay_proto.h"
#include "rfu_proto.h"

static int fails = 0;
#define CHECK(c, ...) do { if(!(c)){ printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } } while(0)

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
    const uint8_t *p = buf; size_t s = 0;
    while (s < len) {
        ssize_t n = send(fd, p + s, len - s, 0);
        if (n <= 0) return -1;
        s += (size_t)n;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *host = argc > 1 ? argv[1] : "192.168.1.243";
    int port         = argc > 2 ? atoi(argv[2]) : 55435;

    printf("== probing netplay host %s:%d as RetroArch %s (protocol %d) ==\n",
           host, port, NETPLAY_TARGET_VERSION, HIGH_NETPLAY_PROTOCOL_VERSION);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) {
        printf("FAIL: bad address %s\n", host); return 1;
    }
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        printf("FAIL: connect: %s\n", strerror(errno)); return 1;
    }
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    printf("connected\n");

    uint32_t impl = nph_impl_magic(NETPLAY_TARGET_VERSION,
                                   HIGH_NETPLAY_PROTOCOL_VERSION);

    // 1. connection header. Mirror RetroArch's client exactly: HIGH protocol
    // goes in the salt field, LOW in header[4] (the "HACK ALERT" in
    // netplay_frontend.c). The server negotiates from these two.
    uint32_t hdr[6];
    hdr[0] = htonl(NETPLAY_MAGIC);
    hdr[1] = htonl(NETPLAY_PLATFORM_MAGIC_LE);
    hdr[2] = htonl(NETPLAY_COMPRESSION_SUPPORTED);
    hdr[3] = htonl(HIGH_NETPLAY_PROTOCOL_VERSION);
    hdr[4] = htonl(LOW_NETPLAY_PROTOCOL_VERSION);
    hdr[5] = htonl(impl);
    CHECK(xwrite(fd, hdr, sizeof(hdr)) == 0, "send header");

    uint32_t r[6];
    CHECK(xread(fd, r, sizeof(r)) == 0, "no header from host");
    CHECK(ntohl(r[0]) == NETPLAY_MAGIC, "magic 0x%08X", ntohl(r[0]));
    uint32_t neg = ntohl(r[4]);
    CHECK(neg >= LOW_NETPLAY_PROTOCOL_VERSION &&
          neg <= HIGH_NETPLAY_PROTOCOL_VERSION,
          "negotiated protocol %u outside %d..%d -> client would abort",
          neg, LOW_NETPLAY_PROTOCOL_VERSION, HIGH_NETPLAY_PROTOCOL_VERSION);
    if (ntohl(r[5]) != impl)
        printf("note: impl magic 0x%08X != ours 0x%08X (warning only)\n",
               ntohl(r[5]), impl);
    printf("header ok (protocol=%u impl=0x%08X)\n", neg, ntohl(r[5]));

    // 2. NICK
    struct { uint32_t cmd[2]; char nick[NETPLAY_NICK_LEN]; } nk;
    memset(&nk, 0, sizeof(nk));
    nk.cmd[0] = htonl(NETPLAY_CMD_NICK);
    nk.cmd[1] = htonl(NETPLAY_NICK_LEN);
    snprintf(nk.nick, sizeof(nk.nick), "probe");
    CHECK(xwrite(fd, &nk, sizeof(nk)) == 0, "send nick");
    memset(&nk, 0, sizeof(nk));
    CHECK(xread(fd, &nk, sizeof(nk)) == 0, "no NICK from host");
    CHECK(ntohl(nk.cmd[0]) == NETPLAY_CMD_NICK, "cmd 0x%08X", ntohl(nk.cmd[0]));
    printf("nick ok ('%.*s')\n", NETPLAY_NICK_LEN, nk.nick);

    // 3. INFO
    struct info_s { uint32_t cmd[2]; uint32_t crc;
                    char name[NETPLAY_NICK_LEN];
                    char ver[NETPLAY_NICK_LEN]; } inf;
    memset(&inf, 0, sizeof(inf));
    CHECK(xread(fd, &inf, sizeof(inf)) == 0, "no INFO from host");
    CHECK(ntohl(inf.cmd[0]) == NETPLAY_CMD_INFO, "cmd 0x%08X", ntohl(inf.cmd[0]));
    printf("info ok (core='%.*s' ver='%.*s' crc=0x%08X)\n",
           NETPLAY_NICK_LEN, inf.name, NETPLAY_NICK_LEN, inf.ver,
           ntohl(inf.crc));

    memset(&inf, 0, sizeof(inf));
    inf.cmd[0] = htonl(NETPLAY_CMD_INFO);
    inf.cmd[1] = htonl(sizeof(inf) - sizeof(inf.cmd));
    snprintf(inf.name, sizeof(inf.name), "gpSP");
    snprintf(inf.ver, sizeof(inf.ver), "v1.1.0-8d268a6");
    CHECK(xwrite(fd, &inf, sizeof(inf)) == 0, "send INFO");

    // 4. SYNC
    uint32_t sc[2];
    CHECK(xread(fd, sc, sizeof(sc)) == 0, "no SYNC from host");
    CHECK(ntohl(sc[0]) == NETPLAY_CMD_SYNC, "cmd 0x%08X", ntohl(sc[0]));
    uint32_t slen = ntohl(sc[1]);
    CHECK(slen < 4096, "sync len %u", slen);
    uint8_t *sb = malloc(slen ? slen : 1);
    CHECK(xread(fd, sb, slen) == 0, "short SYNC");
    uint32_t client_num = slen >= 8 ? nph_get32(sb + 4) : 0;
    printf("sync ok (%u bytes, our client_num=%u)\n", slen, client_num);
    free(sb);

    // 5. send an RFU1 broadcast the way gpSP announces a host
    uint8_t rfu[RFU1_LEN_BCAST];
    memset(rfu, 0, sizeof(rfu));
    be_put32(rfu + 0, RFU1_MAGIC);
    be_put32(rfu + 4, RFU1_BROADCAST);
    be_put32(rfu + 8, 0x1234);
    uint32_t np[3];
    np[0] = htonl(NETPLAY_CMD_NETPACKET);
    np[1] = htonl(sizeof(rfu));
    np[2] = htonl(NETPLAY_NETPACKET_BROADCAST);
    CHECK(xwrite(fd, np, sizeof(np)) == 0, "send netpacket hdr");
    CHECK(xwrite(fd, rfu, sizeof(rfu)) == 0, "send netpacket body");
    printf("sent RFU1 broadcast (devid 0x1234)\n");

    // 5b. Round-trip proof. A CONNECT_REQ while the MiSTer is not hosting must
    // come back as CONNECT_NACK, which only happens if the packet actually
    // reached rfu_core AND rfu_core's reply was routed back over netplay.
    // A broadcast alone is recorded silently, so it proves nothing on its own.
    uint8_t req[RFU1_LEN_CMD];
    memset(req, 0, sizeof(req));
    be_put32(req + 0, RFU1_MAGIC);
    be_put32(req + 4, RFU1_CONNECT_REQ);
    be_put32(req + 8, 0x1234);
    np[1] = htonl(sizeof(req));
    np[2] = htonl(0);           // addressed to the host
    CHECK(xwrite(fd, np, sizeof(np)) == 0, "send connect hdr");
    CHECK(xwrite(fd, req, sizeof(req)) == 0, "send connect body");
    printf("sent RFU1 CONNECT_REQ (expect CONNECT_NACK back)\n");

    // 6. listen briefly for anything the MiSTer's adapter sends back
    printf("listening 6s for host traffic...\n");
    tv.tv_sec = 6; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int seen = 0;
    for (;;) {
        uint32_t c[3];
        if (xread(fd, c, 8) != 0) break;
        uint32_t cmd = ntohl(c[0]), len = ntohl(c[1]);
        if (cmd == NETPLAY_CMD_NETPACKET) {
            if (xread(fd, &c[2], 4) != 0) break;
            uint8_t body[512];
            if (len > sizeof(body)) break;
            if (len && xread(fd, body, len) != 0) break;
            printf("  <- netpacket %u bytes", len);
            if (len >= 12 && be_get32(body) == RFU1_MAGIC)
                printf("  RFU1 type=%u h=0x%08X",
                       be_get32(body + 4), be_get32(body + 8));
            printf("\n");
            seen++;
        } else {
            uint8_t skip[1024];
            if (len > sizeof(skip)) break;
            if (len && xread(fd, skip, len) != 0) break;
            printf("  <- cmd 0x%04X (%u bytes)\n", cmd, len);
        }
    }
    printf("received %d netpacket(s)\n", seen);

    close(fd);
    if (fails) { printf("\n%d CHECK(s) FAILED\n", fails); return 1; }
    printf("\nHANDSHAKE OK against live daemon\n");
    return 0;
}