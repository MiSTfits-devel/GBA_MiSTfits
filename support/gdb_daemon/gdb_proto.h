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
#define GDB_MBOX_SIZE   0x2000u        // 8 KiB mapping, including OFF_DATA

#define GDB_OFF_CMD     0x000
#define GDB_OFF_ADDR    0x008
#define GDB_OFF_LEN     0x010
#define GDB_OFF_ACK     0x018
#define GDB_OFF_STATE   0x020
#define GDB_OFF_CYCLES  0x028
#define GDB_OFF_DATA    0x100

#define GDB_DATA_MAX    4096
#define GDB_MAGIC       0x47424432u
#define GDB_PROTO_VER   2u

// All mailbox words and payload words are little-endian. Submit OFF_ADDR and
// OFF_LEN before OFF_CMD: [7:0] opcode, [15:8] sequence, [63:32] arg0.
// Address and length are qwords; fields not used by a command are ignored.
#define GDB_CMD_NOP          0x00
#define GDB_CMD_HALT         0x01
#define GDB_CMD_CONT         0x02
#define GDB_CMD_STEP         0x03 // arg0 instructions (0 means 1)
#define GDB_CMD_RDMEM        0x04 // word-aligned GBA address; length in bytes
#define GDB_CMD_WRMEM        0x05 // same, with payload at OFF_DATA
#define GDB_CMD_RDREGS       0x06 // r0..r15, CPSR as 17 consecutive u32s
#define GDB_CMD_WRREG        0x07 // address = register index 0..17; arg0 = value
#define GDB_CMD_SETBP        0x08 // address = PC
#define GDB_CMD_SETWP        0x09 // address = watched word
#define GDB_CMD_STEP_CYCLES  0x0A // arg0 nonzero cycle count
#define GDB_CMD_STEP_FRAMES  0x0B // arg0 nonzero VBlank count
#define GDB_CMD_STEP_LINE    0x0C // arg0[7:0] VCOUNT, [8] HBlank instead of start
#define GDB_CMD_BREAK_CYCLE  0x0D // address = absolute u64 cycle, 0 disables
#define GDB_CMD_BREAK_EVENT  0x0E // arg0 = event mask (0 disables)
#define GDB_CMD_RDSTATE      0x0F
#define GDB_CMD_SET_CORE     0x10 // arg0 = 0 or 1 (1 only on a 2P build)
#define GDB_CMD_SET_INPUT    0x11 // active core: arg0[9:0] value, [25:16] mask
#define GDB_CMD_RESET        0x12 // arg0[0] = halt at reset
#define GDB_CMD_RD_TRACE     0x13

// SET_INPUT uses pressed-high values. Mask bit 1 overrides the corresponding
// physical button. From bit 0: A, B, Select, Start, Right, Left, Up, Down, R, L.

// SETBP / SETWP arg0. "Both" takes precedence over the core bit.
#define GDB_CMP_SLOT_MASK    0x0fu
#define GDB_CMP_ENABLE       (1u << 4)
#define GDB_BP_CORE          (1u << 5)
#define GDB_BP_BOTH          (1u << 6)
#define GDB_WP_READ          (1u << 5)
#define GDB_WP_WRITE         (1u << 6)
#define GDB_WP_CORE          (1u << 7)
#define GDB_WP_BOTH          (1u << 8)

// ACK: [7:0] echoed sequence, [15:8] status, [31:16] version, [63:32] magic.
// Nonempty memory access, live register writes and trace reads require halt.
// A run command's ACK confirms that it was accepted; observe STATE for stops.
#define GDB_STATUS_OK       0x00
#define GDB_STATUS_BUSY     0x01
#define GDB_STATUS_BADCMD   0x02
#define GDB_STATUS_BADARG   0x03

// STATE: [0] halted, [1] selected core, [2] dual core, [7:4] reason,
// [11:8] comparator slot, [12] stopped core, [63:32] stop PC.
// All unspecified bits are zero. Slot applies only to BP/WP.
// CYCLES contains the u64 shared cycle count sampled with STATE.
#define GDB_STOP_NONE         0x0
#define GDB_STOP_HOST         0x1
#define GDB_STOP_BP           0x2
#define GDB_STOP_STEP         0x3
#define GDB_STOP_WP           0x4
#define GDB_STOP_STEP_CYCLE   0x5
#define GDB_STOP_STEP_FRAME   0x6
#define GDB_STOP_STEP_LINE    0x7
#define GDB_STOP_BREAK_CYCLE  0x8
#define GDB_STOP_BREAK_EVENT  0x9
#define GDB_STOP_RESET_HALT   0xA

#define GDB_EV_IRQ            (1u << 0)
#define GDB_EV_SERIAL_IRQ     (1u << 1)
#define GDB_EV_DMA_START      (1u << 2)
#define GDB_EV_LINK_XFER      (1u << 3)
#define GDB_EV_VBLANK         (1u << 4)
#define GDB_EV_HBLANK         (1u << 5)

// Maximum comparator slots (1P). Smaller profiles reject slots with BADARG.
#define GDB_BP_COUNT    8
#define GDB_WP_COUNT    4

// gdb's org.gnu.gdb.arm.core: r0..r15 then cpsr
#define GDB_NUM_REGS    17
#define GDB_SS_WORDS        68
#define GDB_STATE_QWORDS    51 // 408 bytes
#define GDB_TRACE_ENTRIES   64
#define GDB_TRACE_QWORDS    65 // 520 bytes

// CMD_RDSTATE, at OFF_DATA. Use the qword values with shifts/masks rather
// than C bitfields. Values are live while running; halt for a stable read.
struct gdb_core_state {
    uint64_t arch_fetch_pc;   // +0: arch PC [31:0], fetch instruction PC [63:32]
    uint64_t stall_opcode;    // +1: stalled instruction PC [31:0], decode opcode [63:32]
    uint64_t bus_dispstat;    // +2: CPU bus address [31:0], DISPSTAT/VCOUNT [63:32]
    uint64_t irq_mem;         // +3: IF [15:0], IE [31:16], mem_info [63:32]
    uint64_t link_lo;         // +4: link state [63:0]
    uint64_t flags;           // +5: described below
};

// flags [6:0] = link state [70:64], [15:8] = link pins, [23:16] = HALTCNT.
// [24] CE, [25] decode load, [26] execute stall, [27] decode ready,
// [28] fetch ready, [29] Thumb, [33:30] CPU mode, [35:34] CPU bus state,
// [36] CPU done, [37] CPU halt, [38] CPU bus enable, [39] CPU bus read,
// [41:40] CPU bus access size, [42] CPU bus sequential, [43] CPU bus code,
// [44] DMA on, [45] VBlank pulse, [46] HBlank pulse, [47] line pulse,
// [48] IRQ IME, [49] CPU IRQ, [57:50] wireless state (core 0 only).
// All unspecified bits are zero.
struct gdb_state {
    uint64_t state;           // qword 0: same format as OFF_STATE
    uint64_t cycles;          // qword 1: core 0 CE count
    uint64_t insns[2];        // qwords 2..3: retirement counts, core 0 then core 1
    uint64_t frames_wp_addr;  // qword 4: core 0 frames [31:0], watch hit address [63:32]
    struct gdb_core_state core[2]; // qwords 5..10 (core 0), 11..16 (core 1/zero)
    uint64_t savestate[GDB_SS_WORDS / 2]; // qwords 17..50: active-core words
    // At qword 17+i, SS address 2*i is low32, address 2*i+1 is high32.
};

// CMD_RD_TRACE, at OFF_DATA. The trace records whichever core was selected
// at each retirement. After count valid entries, unused entries are zero.
struct gdb_trace {
    uint64_t head; // qword 0: [6:0] count (0..64), [13:8] next write pointer.
    uint64_t entry[GDB_TRACE_ENTRIES]; // qwords 1..64: oldest first
    // Entry: [31:0] retired PC, [39:32] elapsed cycles (saturates at 255),
    // [47:40] VCOUNT, [63:48] interrupt flags. Reserved head bits are zero.
};

#endif
