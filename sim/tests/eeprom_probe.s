@ SPDX-License-Identifier: GPL-3.0-or-later
@ SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
@
@ Drives a real EEPROM save sequence the way a game does: DMA3 of the command
@ stream to 0x0DFFFF00, then DMA3 of the 68 bit readout back. Runs from IWRAM
@ so nothing fetches from the cartridge while the transfers are in flight.

.arm
.section .text
.global _start

_start:
   b     start
   .space 0xBC

start:
   ldr   r0, =blob_start
   ldr   r1, =0x03000000
   ldr   r2, =blob_end
copyloop:
   ldr   r3, [r0], #4
   str   r3, [r1], #4
   cmp   r0, r2
   blo   copyloop

   ldr   r12, =main_iw
   ldr   r9,  =blob_start
   sub   r12, r12, r9
   add   r12, r12, #0x03000000
   bx    r12

.ltorg

blob_start:
main_iw:
   @ The aggressive wait states homebrew actually uses (Apotris and friends):
   @ WS0 and WS2 N=3 S=1, prefetch on. Real hardware is fine with this, and the
   @ cartridge master must still return correct data when a game asks for a
   @ window shorter than the one it gives the chip.
   ldr   r0, =0x04000204
   ldr   r1, =0x4595
   strh  r1, [r0]

   @ 81 halfwords: "10" + 14 address bits + 64 data bits + stop bit.
   @ Only bit 0 of each halfword reaches the chip; alternate it so a dropped
   @ or duplicated beat shows up in the readback.
   ldr   r0, =0x03001000
   mov   r1, #81
   mov   r2, #1
bitloop:
   strh  r2, [r0], #2
   eor   r2, r2, #1
   subs  r1, r1, #1
   bne   bitloop

   ldr   r4, =0x040000D4

   @ ---- command stream: IWRAM -> 0x0DFFFF00, 81 halfwords ----
   ldr   r0, =0x03001000
   str   r0, [r4]
   ldr   r0, =0x0DFFFF00
   str   r0, [r4, #4]
   mov   r0, #81
   strh  r0, [r4, #8]
   mov   r0, #0x8000            @ enable, 16 bit, src/dst increment, immediate
   strh  r0, [r4, #10]

   mov   r1, #32
wait1:
   subs  r1, r1, #1
   bne   wait1

   @ ---- readout: 0x0DFFFF00 -> IWRAM, 68 halfwords ----
   ldr   r0, =0x0DFFFF00
   str   r0, [r4]
   ldr   r0, =0x03002000
   str   r0, [r4, #4]
   mov   r0, #68
   strh  r0, [r4, #8]
   mov   r0, #0x8000
   strh  r0, [r4, #10]

   mov   r1, #32
wait2:
   subs  r1, r1, #1
   bne   wait2

   ldr   r0, =0x03007800
   ldr   r1, =0xDEADBEEF
   str   r1, [r0]
spin:
   b     spin

.ltorg
blob_end:
