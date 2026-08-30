// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>, Suibatsu Takumi
//
// RetroArch netplay HOST: lets a stock RetroArch + gpSP client join the
// MiSTer's emulated Wireless Adapter session.
//
// Mirrors the rfu_net.h transport contract (peers addressed by small index,
// RFU1 packets in and out) so rfu_core does not care which transport carried
// a packet.
#ifndef NETPLAY_HOST_H
#define NETPLAY_HOST_H

#include <stddef.h>
#include <stdint.h>

#define NETPLAY_HOST_MAX_CLIENTS 8

// Opens the listening socket. port 0 picks an ephemeral port.
// Returns the bound port on success, negative on failure.
int  netplay_host_open(int port);
void netplay_host_close(void);

// Accepts connections, advances handshakes, and dispatches complete
// netpackets to rfu_core_net_receive(). Non-blocking; call from the main loop.
void netplay_host_poll(void);

// Sends RFU1 bytes to one peer, or to every playing peer when peer < 0.
void netplay_host_send(int peer, const void *buf, size_t len);

int  netplay_host_client_count(void);
const char *netplay_host_client_name(int peer);

// Fills fds[] with the listening socket plus every live client socket so the
// daemon's poll() wakes on netplay traffic instead of waiting out its tick.
// Returns how many were written (at most max).
int  netplay_host_pollfds(int *fds, int max);

// Test seam: reports the most recent netpacket handed to the RFU layer.
// Returns 0 when one is available. Used by tests/netplay_host_test.c so the
// oracle can assert on real relayed bytes instead of a mock.
int  netplay_host_test_last_rx(int *peer, const uint8_t **buf, size_t *len);

#endif