// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// RFU1: the on-the-wire packet format gpSP uses to tunnel Wireless Adapter
// traffic between emulator instances (gpsp/rfu.c). Byte-for-byte identical
// here so a MiSTer can sit in the same session as a gpSP peer.
//
// Header words are big endian; RF payload bytes are little endian, exactly
// as gpSP packs them.
#ifndef RFU_PROTO_H
#define RFU_PROTO_H

#include <stdint.h>
#include <string.h>

#define RFU1_MAGIC          0x52465531u  // "RFU1"

#define RFU1_BROADCAST      0x00   // host -> everyone: broadcast announce
#define RFU1_CONNECT_REQ    0x01   // client -> host: connection request
#define RFU1_CONNECT_ACK    0x02   // host -> client: accepted (id | slot<<16)
#define RFU1_CONNECT_NACK   0x03   // host -> client: rejected
#define RFU1_DISCONNECT     0x04   // either way: disconnect notice
#define RFU1_HOST_SEND      0x05   // host -> client data
#define RFU1_CLIENT_SEND    0x06   // client -> host data
#define RFU1_CLIENT_ACK     0x07   // client -> host: keepalive for host data

#define RFU1_LEN_CMD         16
#define RFU1_LEN_BCAST       36
#define RFU1_LEN_DATA       104

// Discovery/keepalive, our own extension. Distinct magic so gpSP peers just
// drop these as malformed instead of misreading them.
#define MRFU_MAGIC          0x4D524631u  // "MRF1"
#define MRFU_HELLO          0x00
#define MRFU_LEN_HELLO       12

static inline uint32_t be_get32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | p[3];
}

static inline void be_put32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static inline uint32_t le_get32(const uint8_t *p)
{
    return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static inline void le_put32(uint8_t *p, uint32_t v)
{
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

#endif
