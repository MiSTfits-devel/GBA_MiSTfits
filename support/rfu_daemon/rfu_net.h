// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// UDP transport for RFU1 packets. Peers are addressed by a small index that
// plays the role of gpSP's libretro client_id: it is what the RFU state
// machine uses to remember who broadcast what and where to send replies.
#ifndef RFU_NET_H
#define RFU_NET_H

#include <stddef.h>
#include <stdint.h>

#define RFU_NET_MAX_PEERS 32
#define RFU_NET_BCAST     -1

// rfu_core addresses every peer by an index in [0, RFU_NET_MAX_PEERS). The top
// slots are reserved for RetroArch netplay clients so a laptop running gpSP
// and another MiSTer on UDP can share one room without colliding: UDP peers
// are allocated from 0 upward and stop below this base.
#define RFU_NET_NETPLAY_BASE 24

// port, then zero or more "host[:port]" peers to talk to. lan_discovery
// broadcasts a HELLO on the local segment so two MiSTers find each other
// with no configuration.
int  rfu_net_open(int port, int lan_discovery);
void rfu_net_add_peer(const char *hostport, int default_port);
int  rfu_net_fd(void);

// peer < 0 sends to every known peer.
void rfu_net_send(int peer, const void *buf, size_t len);

// Drains the socket, dispatching each RFU1 packet to rfu_core_net_receive().
void rfu_net_poll(void);

// Periodic housekeeping: LAN discovery HELLO, peer expiry.
void rfu_net_tick(void);

int  rfu_net_peer_count(void);
const char *rfu_net_peer_name(int peer);

#endif
