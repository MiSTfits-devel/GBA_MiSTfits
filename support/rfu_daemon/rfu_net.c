// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#include "rfu_net.h"
#include "rfu_core.h"
#include "rfu_proto.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define HELLO_PERIOD_FR 60    // once a second
#define PEER_IDLE_FR   900    // 15 s of silence retires a discovered peer

static int sock = -1;
static int bcast_port;
static int lan_disc;
static int hello_ttl;
// Identifies this instance in its own HELLO so it can ignore the copy the
// kernel loops back from its own subnet broadcast (see rfu_net_poll).
static uint32_t self_nonce;

static struct {
    int                used;
    int                pinned;   // came from the command line: never expires
    uint16_t           idle;
    struct sockaddr_in addr;
    char               name[48];
} peers[RFU_NET_MAX_PEERS];

int rfu_net_fd(void) { return sock; }

static void peer_label(int i)
{
    snprintf(peers[i].name, sizeof(peers[i].name), "%s:%u",
             inet_ntoa(peers[i].addr.sin_addr), ntohs(peers[i].addr.sin_port));
}

static int peer_find(const struct sockaddr_in *a)
{
    int i;
    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (peers[i].used &&
            peers[i].addr.sin_addr.s_addr == a->sin_addr.s_addr &&
            peers[i].addr.sin_port == a->sin_port)
            return i;
    return -1;
}

static int peer_intern(const struct sockaddr_in *a)
{
    int i = peer_find(a);
    if (i >= 0)
        return i;
    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (!peers[i].used) {
            peers[i].used   = 1;
            peers[i].pinned = 0;
            peers[i].idle   = 0;
            peers[i].addr   = *a;
            peer_label(i);
            rfu_log("peer %d discovered: %s\n", i, peers[i].name);
            return i;
        }
    return -1;
}

int rfu_net_open(int port, int lan_discovery)
{
    struct sockaddr_in me;
    int on = 1;

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return -1;
    }
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

    memset(&me, 0, sizeof(me));
    me.sin_family      = AF_INET;
    me.sin_addr.s_addr = htonl(INADDR_ANY);
    me.sin_port        = htons(port);
    if (bind(sock, (struct sockaddr *)&me, sizeof(me)) < 0) {
        perror("bind");
        close(sock);
        sock = -1;
        return -1;
    }

    bcast_port = port;
    lan_disc   = lan_discovery;
    hello_ttl  = HELLO_PERIOD_FR;   // announce ourselves right away

    // Nonce must differ per instance, including two daemons started in the
    // same second on different machines, so mix the clock with the pid and
    // the bound port. 0 is reserved as "no nonce" for older peers.
    self_nonce = (uint32_t)rfu_now_ms()
               ^ ((uint32_t)getpid() << 16)
               ^ ((uint32_t)port << 3);
    if (self_nonce == 0)
        self_nonce = 0xA5A5A5A5u;
    return 0;
}

void rfu_net_add_peer(const char *hostport, int default_port)
{
    char host[64];
    const char *colon = strrchr(hostport, ':');
    struct addrinfo hints, *res;
    int port = default_port, i;

    if (colon) {
        size_t n = (size_t)(colon - hostport);
        if (n >= sizeof(host)) n = sizeof(host) - 1;
        memcpy(host, hostport, n);
        host[n] = 0;
        port = atoi(colon + 1);
    } else {
        snprintf(host, sizeof(host), "%s", hostport);
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) {
        fprintf(stderr, "cannot resolve peer '%s'\n", hostport);
        return;
    }

    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (!peers[i].used) {
            peers[i].used   = 1;
            peers[i].pinned = 1;
            peers[i].idle   = 0;
            peers[i].addr   = *(struct sockaddr_in *)res->ai_addr;
            peers[i].addr.sin_port = htons(port);
            peer_label(i);
            rfu_log("peer %d configured: %s\n", i, peers[i].name);
            break;
        }
    freeaddrinfo(res);
}

void rfu_net_send(int peer, const void *buf, size_t len)
{
    int i;
    if (sock < 0)
        return;
    if (peer >= 0) {
        if (peer < RFU_NET_MAX_PEERS && peers[peer].used)
            sendto(sock, buf, len, 0, (struct sockaddr *)&peers[peer].addr,
                   sizeof(peers[peer].addr));
        return;
    }
    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (peers[i].used)
            sendto(sock, buf, len, 0, (struct sockaddr *)&peers[i].addr,
                   sizeof(peers[i].addr));
}

static void send_hello(void)
{
    uint8_t pkt[MRFU_LEN_HELLO];
    struct sockaddr_in to;

    be_put32(&pkt[0], MRFU_MAGIC);
    be_put32(&pkt[4], MRFU_HELLO);
    be_put32(&pkt[8], self_nonce);

    memset(&to, 0, sizeof(to));
    to.sin_family      = AF_INET;
    to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    to.sin_port        = htons(bcast_port);
    sendto(sock, pkt, sizeof(pkt), 0, (struct sockaddr *)&to, sizeof(to));
}

void rfu_net_poll(void)
{
    uint8_t buf[512];
    struct sockaddr_in from;
    socklen_t fromlen;
    ssize_t n;

    if (sock < 0)
        return;

    for (;;) {
        fromlen = sizeof(from);
        n = recvfrom(sock, buf, sizeof(buf), MSG_DONTWAIT,
                     (struct sockaddr *)&from, &fromlen);
        if (n < 12)
            return;

        if (be_get32(buf) == MRFU_MAGIC) {
            // Discovery: learn the sender, and answer once so it learns us
            // too (broadcasts only travel one way through some switches).
            //
            // Ignore our own HELLO first. A subnet broadcast is delivered
            // back to the sending socket, so without this a lone daemon
            // interns ITSELF as a peer -- and then the game finds a phantom
            // parent, joins a session with nobody on the other end, and
            // populates Union Room slots that are backed by no real player.
            // Comparing addresses is not enough (the source address of our
            // own broadcast is a local interface we do not necessarily
            // know), so each instance tags its HELLO with a random nonce.
            if (n >= MRFU_LEN_HELLO && be_get32(&buf[8]) == self_nonce)
                continue;

            int known = peer_find(&from) >= 0;
            int peer  = peer_intern(&from);
            if (peer >= 0) {
                peers[peer].idle = 0;
                if (!known)
                    rfu_net_send(peer, buf, MRFU_LEN_HELLO);
            }
            continue;
        }

        if (be_get32(buf) == RFU1_MAGIC) {
            int peer = peer_intern(&from);
            if (peer >= 0) {
                peers[peer].idle = 0;
                rfu_core_net_receive(peer, buf, (size_t)n);
            }
        }
    }
}

void rfu_net_tick(void)
{
    int i;

    if (lan_disc && ++hello_ttl >= HELLO_PERIOD_FR) {
        hello_ttl = 0;
        send_hello();
    }

    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (peers[i].used && !peers[i].pinned &&
            ++peers[i].idle >= PEER_IDLE_FR) {
            rfu_log("peer %d (%s) went quiet\n", i, peers[i].name);
            peers[i].used = 0;
        }
}

int rfu_net_peer_count(void)
{
    int i, n = 0;
    for (i = 0; i < RFU_NET_MAX_PEERS; i++)
        if (peers[i].used)
            n++;
    return n;
}

const char *rfu_net_peer_name(int peer)
{
    if (peer < 0 || peer >= RFU_NET_MAX_PEERS || !peers[peer].used)
        return "?";
    return peers[peer].name;
}
