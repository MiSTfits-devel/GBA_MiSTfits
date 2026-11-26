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
#include <poll.h>

#define NETPLAY_HOST_MAX_CLIENTS 8

// Opens the listening socket. port 0 picks an ephemeral port.
// Returns the bound port on success, negative on failure.
int  netplay_host_open(int port);
void netplay_host_close(void);

// Service the readiness returned by poll() on the slice filled below.
void netplay_host_poll(const struct pollfd *fds, int count);

// Queues RFU1 bytes for a peer, or every playing peer when peer < 0.
void netplay_host_send(int peer, const void *buf, size_t len);

int  netplay_host_client_count(void);
const char *netplay_host_client_name(int peer);

// Fill the listener/client poll descriptors, including POLLOUT for queued TX.
int netplay_host_pollfds(struct pollfd *fds, int max);

// Test seam: reports the most recent netpacket handed to the RFU layer.
// Returns 0 when one is available. Used by tests/netplay_host_test.c so the
// oracle can assert on real relayed bytes instead of a mock.
int  netplay_host_test_last_rx(int *peer, const uint8_t **buf, size_t *len);

#endif