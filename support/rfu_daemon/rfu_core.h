// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// AGB-015 command semantics. The FPGA (rtl/gba_wireless.vhd) owns the link
// port and hands us whole STWI packets; everything a real adapter would do
// with them -- device IDs, host slots, broadcast tables, RF data queues,
// timeouts -- lives here. Command layouts follow docs/agb015_protocol.md;
// the network behaviour follows gpsp/rfu.c so the two interoperate.
#ifndef RFU_CORE_H
#define RFU_CORE_H

#include <stddef.h>
#include <stdint.h>

#define RFU_MAX_WORDS 32   // matches the FPGA's pktbuf depth

// Adapter session state, as reported by SystemStatus (0x13) byte3.
enum {
    RFU_ST_IDLE       = 0,   // N
    RFU_ST_HOST       = 1,   // P: hosting, entry closed
    RFU_ST_HOST_OPEN  = 2,   // P-PSC: hosting, accepting children
    RFU_ST_SEARCH     = 3,   // CSP
    RFU_ST_CONNECTING = 4,   // CCP
    RFU_ST_CLIENT     = 5    // C
};

void rfu_core_init(void);
void rfu_core_reset(void);      // GPIO ping: back to power-save defaults

// Executes one REQ. Returns the ACK payload length in words (written to
// resp), or a negative rejection reason (1 = illegal here, 2 = unknown).
int  rfu_core_command(uint8_t cmd, uint8_t len, const uint32_t *p, uint32_t *resp);

void rfu_core_frame(void);      // ~60 Hz housekeeping
void rfu_core_net_receive(int peer, const void *buf, size_t len);

// Clock-reversal wait: armed when the GBA issues 0x25/0x27/0x37, then polled
// until it yields the adapter-initiated command to inject.
void rfu_core_wait_begin(void);
int  rfu_core_wait_poll(uint8_t *cmd, uint8_t *nparams, uint32_t *params);

// Milliseconds until the reversal wait needs a decision, or -1 when no wait is
// armed. The daemon must not sleep past this: the retransmit window is ~11 ms,
// shorter than a 16 ms frame tick, so polling only on the tick makes us report
// "no child answered" while the peer's reply is still in flight.
int  rfu_core_wait_next_ms(void);

int  rfu_core_state(void);
const char *rfu_core_state_name(void);

// Provided by the host program (daemon or test harness).
uint32_t rfu_now_ms(void);
void     rfu_log(const char *fmt, ...);

#endif
