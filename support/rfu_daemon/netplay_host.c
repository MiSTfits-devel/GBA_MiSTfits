// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>, Suibatsu Takumi
//
// RetroArch netplay HOST for rfu_daemon.
//
// A stock RetroArch (1.22.2) running gpSP emulates the AGB-015 in software and
// tunnels its RF traffic as "RFU1" packets over libretro's netpacket
// interface. Our daemon already speaks RFU1 between MiSTers, so joining the
// two worlds is a transport problem: wrap the same bytes in netplay commands
// and play the server role of RetroArch's handshake.
//
// Wire details transcribed from RetroArch network/netplay/netplay_frontend.c
// at tag v1.22.2. All multi-byte fields are network byte order.
//
// In packet-interface mode RetroArch skips the rollback/savestate machinery,
// so the host only has to: exchange headers, exchange NICK, send INFO, send
// SYNC, then relay netpackets.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include "netplay_host.h"
#include "netplay_proto.h"
#include "rfu_core.h"
#include "rfu_net.h"

#ifndef NETPLAY_HOST_NICK
#define NETPLAY_HOST_NICK "MiSTer"
#endif
// gpSP identifies itself with these; the client compares core names to decide
// whether the session is compatible.
#define NETPLAY_HOST_CORE_NAME    "gpSP"
#define NETPLAY_HOST_CORE_VERSION "v1.1.0-8d268a6"

#define RXBUF_MAX 4096

enum client_state {
    CS_FREE = 0,
    CS_HEADER,   // waiting for the peer's 6-word connection header
    CS_NICK,     // waiting for NICK
    CS_INFO,     // waiting for the client's INFO echo
    CS_PLAYING   // handshake complete: netpackets flow
};

struct client {
    int      fd;
    int      state;
    char     nick[NETPLAY_NICK_LEN + 1];
    uint8_t  rx[RXBUF_MAX];
    size_t   rxlen;
};

static int listen_fd = -1;
static struct client clients[NETPLAY_HOST_MAX_CLIENTS];

// test seam
static uint8_t last_rx[RXBUF_MAX];
static size_t  last_rx_len;
static int     last_rx_peer = -1;
static int     have_last_rx;

// ---- small helpers ----

static void set_nonblock(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// Blocking-ish send: the handshake messages are tiny, and a short write on a
// fresh socket is vanishingly rare, but loop anyway so we never truncate a
// command mid-header.
static int send_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && (errno == EINTR)) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
}

static void drop_client(struct client *c)
{
    if (c->fd >= 0) close(c->fd);
    c->fd    = -1;
    c->state = CS_FREE;
    c->rxlen = 0;
}

// ---- handshake pieces ----

static int send_header(struct client *c)
{
    uint32_t hdr[6];
    hdr[0] = htonl(NETPLAY_MAGIC);
    hdr[1] = htonl(NETPLAY_PLATFORM_MAGIC_LE);
    hdr[2] = htonl(NETPLAY_COMPRESSION_SUPPORTED);
    hdr[3] = htonl(0);   // no password: salt unused
    hdr[4] = htonl(HIGH_NETPLAY_PROTOCOL_VERSION);
    hdr[5] = htonl(nph_impl_magic(NETPLAY_TARGET_VERSION,
                                  HIGH_NETPLAY_PROTOCOL_VERSION));
    return send_all(c->fd, hdr, sizeof(hdr));
}

static int send_nick(struct client *c)
{
    struct { uint32_t cmd[2]; char nick[NETPLAY_NICK_LEN]; } m;
    memset(&m, 0, sizeof(m));
    m.cmd[0] = htonl(NETPLAY_CMD_NICK);
    m.cmd[1] = htonl(NETPLAY_NICK_LEN);
    snprintf(m.nick, sizeof(m.nick), "%s", NETPLAY_HOST_NICK);
    return send_all(c->fd, &m, sizeof(m));
}

static int send_info(struct client *c)
{
    struct { uint32_t cmd[2]; uint32_t content_crc;
             char core_name[NETPLAY_NICK_LEN];
             char core_version[NETPLAY_NICK_LEN]; } m;
    memset(&m, 0, sizeof(m));
    m.cmd[0] = htonl(NETPLAY_CMD_INFO);
    m.cmd[1] = htonl(sizeof(m) - sizeof(m.cmd));
    // content_crc 0 = "no content loaded / don't care", which RetroArch
    // tolerates and which is right for us: the MiSTer holds the cartridge,
    // and RFU sessions deliberately allow different compatible games.
    m.content_crc = htonl(0);
    snprintf(m.core_name,    sizeof(m.core_name),    "%s", NETPLAY_HOST_CORE_NAME);
    snprintf(m.core_version, sizeof(m.core_version), "%s", NETPLAY_HOST_CORE_VERSION);
    return send_all(c->fd, &m, sizeof(m));
}

static int send_sync(struct client *c, int peer)
{
    // SYNC in packet-interface mode: the client needs its own id. Everything
    // else in the frame-sync payload is inert here, so it is sent zeroed.
    struct sync_s {
        uint32_t cmd[2];
        uint32_t frame_count;
        uint32_t paused_and_client_num;   // high bit = paused
        uint32_t devices[16];
        uint8_t  share_modes[16];
        uint32_t controller_devices[16];
        char     nick[NETPLAY_NICK_LEN];
    } m;
    memset(&m, 0, sizeof(m));
    m.cmd[0] = htonl(NETPLAY_CMD_SYNC);
    m.cmd[1] = htonl(sizeof(m) - sizeof(m.cmd));
    m.frame_count = htonl(0);
    // client_num is 1-based on the netplay wire; peer is our 0-based index.
    m.paused_and_client_num = htonl((uint32_t)(peer + 1));
    snprintf(m.nick, sizeof(m.nick), "%s", NETPLAY_HOST_NICK);
    return send_all(c->fd, &m, sizeof(m));
}

// ---- netpacket relay ----

static void deliver_to_rfu(int peer, const uint8_t *buf, size_t len)
{
    if (len > sizeof(last_rx)) len = sizeof(last_rx);
    memcpy(last_rx, buf, len);
    last_rx_len  = len;
    last_rx_peer = peer;
    have_last_rx = 1;

    // rfu_core addresses peers in one flat space shared with UDP peers; our
    // clients live in the reserved band at the top (see rfu_net.h).
    rfu_core_net_receive(RFU_NET_NETPLAY_BASE + peer, buf, len);
}

// Consumes as many complete commands as the buffer holds. Returns 0 to keep
// the client, -1 to drop it.
static int consume(struct client *c, int peer)
{
    for (;;) {
        if (c->state == CS_HEADER) {
            if (c->rxlen < 24) return 0;
            uint32_t magic = nph_get32(c->rx);
            if (magic != NETPLAY_MAGIC) return -1;
            uint32_t their_impl = nph_get32(c->rx + 20);
            uint32_t our_impl   = nph_impl_magic(NETPLAY_TARGET_VERSION,
                                                 HIGH_NETPLAY_PROTOCOL_VERSION);
            if (their_impl != our_impl) {
                fprintf(stderr,
                    "netplay: client impl magic 0x%08X != ours 0x%08X "
                    "(RetroArch version mismatch)\n", their_impl, our_impl);
                return -1;
            }
            memmove(c->rx, c->rx + 24, c->rxlen - 24);
            c->rxlen -= 24;
            c->state = CS_NICK;
            if (send_header(c) < 0) return -1;
            continue;
        }

        if (c->state == CS_NICK) {
            const size_t need = 8 + NETPLAY_NICK_LEN;
            if (c->rxlen < need) return 0;
            if (nph_get32(c->rx) != NETPLAY_CMD_NICK) return -1;
            memcpy(c->nick, c->rx + 8, NETPLAY_NICK_LEN);
            c->nick[NETPLAY_NICK_LEN] = 0;
            memmove(c->rx, c->rx + need, c->rxlen - need);
            c->rxlen -= need;
            c->state = CS_INFO;
            if (send_nick(c) < 0) return -1;
            if (send_info(c) < 0) return -1;
            continue;
        }

        if (c->state == CS_INFO) {
            if (c->rxlen < 8) return 0;
            uint32_t cmd  = nph_get32(c->rx);
            uint32_t size = nph_get32(c->rx + 4);
            if (cmd != NETPLAY_CMD_INFO) {
                // Tolerate anything else the client volunteers here by
                // skipping it, as long as the frame is sane.
                if (size > RXBUF_MAX) return -1;
                if (c->rxlen < 8 + size) return 0;
                memmove(c->rx, c->rx + 8 + size, c->rxlen - 8 - size);
                c->rxlen -= 8 + size;
                continue;
            }
            if (size > RXBUF_MAX) return -1;
            if (c->rxlen < 8 + size) return 0;
            memmove(c->rx, c->rx + 8 + size, c->rxlen - 8 - size);
            c->rxlen -= 8 + size;
            c->state = CS_PLAYING;
            if (send_sync(c, peer) < 0) return -1;
            continue;
        }

        // CS_PLAYING: a stream of {cmd,size,payload}
        if (c->rxlen < 8) return 0;
        uint32_t cmd  = nph_get32(c->rx);
        uint32_t size = nph_get32(c->rx + 4);
        if (size > RXBUF_MAX - 8) return -1;

        if (cmd == NETPLAY_CMD_NETPACKET) {
            // payload = {u32 client_id}{bytes}; size counts only the bytes.
            if (c->rxlen < 8 + 4 + size) return 0;
            // pkt_client_id designates the RECIPIENT (0 or broadcast = host).
            uint32_t pkt_client_id = nph_get32(c->rx + 8);
            const uint8_t *body = c->rx + 12;

            if (pkt_client_id == NETPLAY_NETPACKET_BROADCAST ||
                pkt_client_id == 0) {
                deliver_to_rfu(peer, body, size);
            }
            if (pkt_client_id == NETPLAY_NETPACKET_BROADCAST) {
                // relay to every other playing client
                for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++) {
                    if (i == peer) continue;
                    if (clients[i].state != CS_PLAYING) continue;
                    netplay_host_send(i, body, size);
                }
            }
            size_t used = 8 + 4 + size;
            memmove(c->rx, c->rx + used, c->rxlen - used);
            c->rxlen -= used;
            continue;
        }

        // Anything else (chat, pause, ...) is not meaningful to an RFU
        // session; skip the frame and keep the connection alive.
        if (c->rxlen < 8 + size) return 0;
        memmove(c->rx, c->rx + 8 + size, c->rxlen - 8 - size);
        c->rxlen -= 8 + size;
    }
}

// ---- public API ----

int netplay_host_open(int port)
{
    struct sockaddr_in sa;
    int one = 1;

    for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++) {
        clients[i].fd = -1;
        clients[i].state = CS_FREE;
        clients[i].rxlen = 0;
    }
    have_last_rx = 0;
    last_rx_peer = -1;
    last_rx_len  = 0;

    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) return -1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    memset(&sa, 0, sizeof(sa));
    sa.sin_family      = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port        = htons((uint16_t)(port > 0 ? port : 0));
    if (bind(listen_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(listen_fd); listen_fd = -1; return -2;
    }
    if (listen(listen_fd, 4) < 0) {
        close(listen_fd); listen_fd = -1; return -3;
    }
    set_nonblock(listen_fd);

    socklen_t sl = sizeof(sa);
    if (getsockname(listen_fd, (struct sockaddr *)&sa, &sl) < 0) {
        close(listen_fd); listen_fd = -1; return -4;
    }
    return ntohs(sa.sin_port);
}

void netplay_host_close(void)
{
    for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++)
        if (clients[i].fd >= 0) drop_client(&clients[i]);
    if (listen_fd >= 0) close(listen_fd);
    listen_fd = -1;
}

void netplay_host_poll(void)
{
    if (listen_fd < 0) return;

    // accept
    for (;;) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) break;
        int slot = -1;
        for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++)
            if (clients[i].state == CS_FREE) { slot = i; break; }
        if (slot < 0) { close(fd); continue; }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        set_nonblock(fd);
        clients[slot].fd    = fd;
        clients[slot].state = CS_HEADER;
        clients[slot].rxlen = 0;
        clients[slot].nick[0] = 0;
    }

    // service
    for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++) {
        struct client *c = &clients[i];
        if (c->state == CS_FREE) continue;
        for (;;) {
            if (c->rxlen >= sizeof(c->rx)) { drop_client(c); break; }
            ssize_t n = recv(c->fd, c->rx + c->rxlen,
                             sizeof(c->rx) - c->rxlen, 0);
            if (n > 0) {
                c->rxlen += (size_t)n;
                if (consume(c, i) < 0) { drop_client(c); break; }
                continue;
            }
            if (n == 0) { drop_client(c); break; }
            if (errno == EINTR) continue;
            break;  // EAGAIN
        }
    }
}

void netplay_host_send(int peer, const void *buf, size_t len)
{
    uint32_t cmd[3];
    cmd[0] = htonl(NETPLAY_CMD_NETPACKET);
    cmd[1] = htonl((uint32_t)len);
    // Host -> client: the field carries the SOURCE id, and 0 means the host.
    cmd[2] = htonl(0);

    for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++) {
        if (peer >= 0 && i != peer) continue;
        if (clients[i].state != CS_PLAYING) continue;
        if (send_all(clients[i].fd, cmd, sizeof(cmd)) < 0 ||
            (len && send_all(clients[i].fd, buf, len) < 0))
            drop_client(&clients[i]);
    }
}

int netplay_host_client_count(void)
{
    int n = 0;
    for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS; i++)
        if (clients[i].state == CS_PLAYING) n++;
    return n;
}

const char *netplay_host_client_name(int peer)
{
    if (peer < 0 || peer >= NETPLAY_HOST_MAX_CLIENTS) return "";
    return clients[peer].nick;
}

int netplay_host_pollfds(int *fds, int max)
{
    int n = 0;
    if (!fds || max <= 0) return 0;
    if (listen_fd >= 0 && n < max) fds[n++] = listen_fd;
    for (int i = 0; i < NETPLAY_HOST_MAX_CLIENTS && n < max; i++)
        if (clients[i].state != CS_FREE && clients[i].fd >= 0)
            fds[n++] = clients[i].fd;
    return n;
}

int netplay_host_test_last_rx(int *peer, const uint8_t **buf, size_t *len)
{
    if (!have_last_rx) return -1;
    if (peer) *peer = last_rx_peer;
    if (buf)  *buf  = last_rx;
    if (len)  *len  = last_rx_len;
    return 0;
}