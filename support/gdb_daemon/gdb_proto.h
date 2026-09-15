// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Mailbox layout shared with rtl/gba_gdb.vhd. Keep the two in step.
//
// The FPGA's DDR3 master hardwires the top nibble of its address to 0b0011
// (see DDR3Mux.vhd), so a core byte address X is HPS physical 0x30000000 + X.
// The engine's mailbox sits at core 0xC800000, hence 0x3C800000 here.
#ifndef GDB_PROTO_H
#define GDB_PROTO_H

#include <stdint.h>

#define GDB_MBOX_PHYS   0x3C800000u
#define GDB_MBOX_SIZE   0x2000u        // 8 KB: header page plus the 4 KB window

#define GDB_OFF_CMD     0x000
#define GDB_OFF_ADDR    0x008
#define GDB_OFF_LEN     0x010
#define GDB_OFF_ACK     0x018
#define GDB_OFF_STATE   0x020
#define GDB_OFF_DATA    0x100

#define GDB_DATA_MAX    4096

// CMD word: [7:0] opcode, [15:8] sequence, [63:32] argument
#define GDB_CMD_NOP     0x00
#define GDB_CMD_HALT    0x01
#define GDB_CMD_CONT    0x02
#define GDB_CMD_STEP    0x03
#define GDB_CMD_RDMEM   0x04
#define GDB_CMD_WRMEM   0x05
#define GDB_CMD_RDREGS  0x06
#define GDB_CMD_WRREG   0x07
#define GDB_CMD_SETBP   0x08
#define GDB_CMD_SETWP   0x09

// ACK word: [7:0] sequence echoed, [15:8] status
#define GDB_STATUS_OK      0x00
#define GDB_STATUS_BADCMD  0x02

// STATE word: [0] halted, [7:4] stop reason, [63:32] stop PC
#define GDB_STOP_NONE   0x0
#define GDB_STOP_HOST   0x1
#define GDB_STOP_BP     0x2
#define GDB_STOP_STEP   0x3
#define GDB_STOP_WP     0x4

// hardware comparator slots, must match the generics on gba_gdb
#define GDB_BP_COUNT    8
#define GDB_WP_COUNT    4

// gdb's org.gnu.gdb.arm.core: r0..r15 then cpsr
#define GDB_NUM_REGS    17

#endif
