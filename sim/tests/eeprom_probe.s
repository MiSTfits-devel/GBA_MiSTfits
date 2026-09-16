@ SPDX-License-Identifier: GPL-3.0-or-later
@ SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
@
@ Full EEPROM round trip the way a game does it: DMA3 the 81 bit write command
@ to 0x0DFFFF00, DMA3 the 17 bit read request, DMA3 the 68 bit readout back,
@ then reassemble the 64 data bits and check them against what was written.
@ Runs from IWRAM so nothing fetches from the cartridge mid transfer.
@
@ Splitting the verdict matters: the testbench separately checks what the
@ EEPROM *received*, so a mismatch says which direction is broken rather than
@ just that something is.

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

.equ EE_BLOCK, 5
.equ PAT_HI,   0x01234567
.equ PAT_LO,   0x89ABCDEF

blob_start:
main_iw:
   @ the aggressive wait states homebrew actually uses (Apotris and friends):
   @ WS0 and WS2 N=3 S=1, prefetch on
   ldr   r0, =0x04000204
   ldr   r1, =0x4595
   strh  r1, [r0]

   @ ---------- build the 81 halfword write command at 0x03001000 ----------
   ldr   r0, =0x03001000
   mov   r2, #1
   strh  r2, [r0], #2            @ "1"
   mov   r2, #0
   strh  r2, [r0], #2            @ "0"  -> write
   mov   r3, #EE_BLOCK
   mov   r1, #14
waddr:
   sub   r1, r1, #1
   mov   r2, r3, lsr r1
   and   r2, r2, #1
   strh  r2, [r0], #2
   cmp   r1, #0
   bne   waddr
   ldr   r5, =PAT_HI
   ldr   r6, =PAT_LO
   mov   r1, #32
wdhi:
   sub   r1, r1, #1
   mov   r2, r5, lsr r1
   and   r2, r2, #1
   strh  r2, [r0], #2
   cmp   r1, #0
   bne   wdhi
   mov   r1, #32
wdlo:
   sub   r1, r1, #1
   mov   r2, r6, lsr r1
   and   r2, r2, #1
   strh  r2, [r0], #2
   cmp   r1, #0
   bne   wdlo
   mov   r2, #0
   strh  r2, [r0], #2            @ stop bit

   @ ---------- build the 17 halfword read request at 0x03001800 ----------
   ldr   r0, =0x03001800
   mov   r2, #1
   strh  r2, [r0], #2            @ "1"
   strh  r2, [r0], #2            @ "1"  -> read
   mov   r3, #EE_BLOCK
   mov   r1, #14
raddr:
   sub   r1, r1, #1
   mov   r2, r3, lsr r1
   and   r2, r2, #1
   strh  r2, [r0], #2
   cmp   r1, #0
   bne   raddr
   mov   r2, #0
   strh  r2, [r0], #2            @ stop bit

   ldr   r4, =0x040000D4

   @ ---------- DMA the write command ----------
   ldr   r0, =0x03001000
   str   r0, [r4]
   ldr   r0, =0x0DFFFF00
   str   r0, [r4, #4]
   mov   r0, #81
   strh  r0, [r4, #8]
   mov   r0, #0x8000
   strh  r0, [r4, #10]

   mov   r1, #64
w1:subs  r1, r1, #1
   bne   w1

   @ ---------- DMA the read request ----------
   ldr   r0, =0x03001800
   str   r0, [r4]
   ldr   r0, =0x0DFFFF00
   str   r0, [r4, #4]
   mov   r0, #17
   strh  r0, [r4, #8]
   mov   r0, #0x8000
   strh  r0, [r4, #10]

   mov   r1, #64
w2:subs  r1, r1, #1
   bne   w2

   @ ---------- DMA the 68 bit readout ----------
   ldr   r0, =0x0DFFFF00
   str   r0, [r4]
   ldr   r0, =0x03002000
   str   r0, [r4, #4]
   mov   r0, #68
   strh  r0, [r4, #8]
   mov   r0, #0x8000
   strh  r0, [r4, #10]

   mov   r1, #64
w3:subs  r1, r1, #1
   bne   w3

   @ ---------- reassemble: 4 dummy bits, then 64 data bits MSB first ----------
   ldr   r0, =0x03002000
   add   r0, r0, #8
   mov   r5, #0
   mov   r6, #0
   mov   r1, #32
rdhi:
   ldrh  r2, [r0], #2
   and   r2, r2, #1
   mov   r5, r5, lsl #1
   orr   r5, r5, r2
   subs  r1, r1, #1
   bne   rdhi
   mov   r1, #32
rdlo:
   ldrh  r2, [r0], #2
   and   r2, r2, #1
   mov   r6, r6, lsl #1
   orr   r6, r6, r2
   subs  r1, r1, #1
   bne   rdlo

   @ ---------- publish the verdict ----------
   ldr   r0, =0x03007800
   str   r5, [r0, #4]            @ what came back, high word
   str   r6, [r0, #8]            @ what came back, low word
   ldr   r1, =0xDEADBEEF
   str   r1, [r0]                @ done marker last
spin:
   b     spin

.ltorg
blob_end:
