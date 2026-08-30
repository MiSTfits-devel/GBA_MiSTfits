// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>, Suibatsu Takumi
//
// RetroArch netplay host protocol (the wire a stock RetroArch client speaks),
// reconstructed from libretro/RetroArch network/netplay/ and confirmed against
// netplay_frontend.c. We implement the HOST side so a laptop running RetroArch
// 1.17+ + the gpSP core can join the MiSTer's Union Room as if it were another
// adapter: gpSP emulates the Wireless Adapter and tunnels "RFU1" radio packets
// over RetroArch's netpacket interface; the daemon that already tunnels RFU1
// between MiSTers just needs to wrap the same bytes in netplay commands.
//
// All multi-byte fields on the wire are NETWORK byte order.
#ifndef NETPLAY_PROTO_H
#define NETPLAY_PROTO_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// ---- connection header (6 x u32) ----
#define NETPLAY_MAGIC          0x52414E50u  // "RANP"
// Endianness bit + sizeof(size_t)<<15 + sizeof(long). 16.78 MHz targets are
// little endian; we compute it inline below the same way RetroArch does.
#define NETPLAY_PLATFORM_MAGIC_LE  (uint32_t)( ((uint32_t)0 << 30) | ((uint32_t)sizeof(size_t) << 15) | (uint32_t)sizeof(long) )

#define NETPLAY_COMPRESSION_SUPPORTED 0u  // no zlib in the daemon

// RetroArch protocol versions (netplay_protocol.h). Confirmed unchanged at
// tag v1.22.2, which is the build we target.
#define LOW_NETPLAY_PROTOCOL_VERSION   5
#define HIGH_NETPLAY_PROTOCOL_VERSION  7

// The peer we are being built against. netplay_impl_magic() hashes this exact
// string, so it must match the client's PACKAGE_VERSION or RetroArch refuses
// the connection outright.
#define NETPLAY_TARGET_VERSION "1.22.2"

#define NETPLAY_NICK_LEN       32
#define NETPLAY_PASS_HASH_LEN  32

// ---- commands (netplay_private.h) ----
#define NETPLAY_CMD_NICK        0x0020u
#define NETPLAY_CMD_PASSWORD    0x0021u
#define NETPLAY_CMD_INFO        0x0022u
#define NETPLAY_CMD_SYNC        0x0023u
#define NETPLAY_CMD_MODE        0x0026u
#define NETPLAY_CMD_MODE_REFUSED 0x0027u
#define NETPLAY_CMD_NETPACKET   0x0048u

#define NETPLAY_CMD_MODE_BIT_YOU     (1u << 31)  // 1 => peer is the "you" side
#define NETPLAY_CMD_MODE_BIT_PLAYING (1u << 30)
#define NETPLAY_CMD_MODE_BIT_SLAVE   (1u << 29)

#define NETPLAY_NETPACKET_BROADCAST 0xFFFFu

// Netpacket payload: { uint32 client_id (network order), bytes... }
// Extracted from netplay_send_cmd_netpacket():  cmdbuf = {CMD, len, client_id}
// then the raw bytes.  On receive the payload is:  client_id u32 + payload.

// ---- helpers ----

static inline uint32_t nph_get32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | p[3];
}
static inline void nph_put32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

// impl_magic: netplay_impl_magic() in RetroArch = XOR hash of the PACKAGE_VERSION
// string (the RetroArch version string) with the protocol version mixed in.
// The host must emit the SAME value the laptop's client computes, or RetroArch
// refuses the connection. Because it depends on the client's exact build this
// is supplied by the caller (obtained from the client's INFO during handshake).
static inline uint32_t nph_impl_magic(const char *version, uint32_t protocol)
{
    uint32_t res = 0;
    size_t i;
    for (i = 0; version && version[i]; i++)
        res ^= ((uint32_t)(uint8_t)version[i]) << (i & 0xf);
    res ^= protocol << (i & 0xf);
    return res;
}

#endif