@ SPDX-License-Identifier: GPL-3.0-or-later
@ SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
@ EWRAM/SDRAM diagnostic ROM for the GBA2P build (see gen_ewram_alias_test.py)
@
@ Two tests, results as fullscreen colors (mode 3) and as distinctive
@ infinite-loop PCs for simulation traces:
@
@   Test A - EWRAM integrity: word pattern + byte/halfword pokes (exercises
@            the SDRAM DQM byte-mask write path new in the 2P profile),
@            read back and compare.
@   Test B - ROM alias: write a marker word to EWRAM offset X and read the
@            ROM address space at the same offset. If the marker appears,
@            EWRAM traffic lands in the ROM image (byte-address bit 25
@            aliasing on 512-column SDRAM chips).
@
@   screen  top half      = test A:  green pass, red fail
@   screen  bottom half   = test B:  green clean, red alias
@   verdict loops (PC):   0x08000400 pass, 0x08000410 A-fail, 0x08000420 alias
@
@ The code runs straight from ROM below offset 0x400, uses no stack and no
@ EWRAM outside the probed offsets (64KB+ / 128KB+), so it stays alive even
@ while its own test writes shred the aliased ROM image above 64KB.

.arm
.section .text
.global _start

_start:
   b  start                   @ 0x000: cart entry
   .space 0xBC                @ 0x004-0xBF: header, patched in by the generator

start:                        @ 0x0C0
   ldr   r0, =0x04000000
   ldr   r1, =0x0403          @ mode 3, BG2 on
   str   r1, [r0]

   @ ---------------- test A: EWRAM integrity -------------------------
   ldr   r2, =0x02010000      @ EWRAM + 64KB
   ldr   r3, =0xA5A5A5A5
   mov   r4, #0               @ i
wrloop:
   eor   r5, r3, r4           @ pattern = 0xA5A5A5A5 ^ (i*4)
   str   r5, [r2, r4]
   add   r4, r4, #4
   cmp   r4, #1024
   bne   wrloop

   @ byte/halfword pokes on distinct lanes (be = 0001 / 0010 / 1100 / 0011)
   mov   r5, #0xAA
   strb  r5, [r2, #0]         @ lane 0
   strb  r5, [r2, #5]         @ lane 1
   ldr   r5, =0xBBCC
   strh  r5, [r2, #10]        @ lanes 2+3
   strh  r5, [r2, #16]        @ lanes 0+1

   @ verify the poked words
   ldr   r5, [r2, #0]         @ expect (A5A5A5A4 & ~FF)      | AA
   ldr   r6, =0xA5A5A5AA
   cmp   r5, r6
   bne   fail_a_tramp
   ldr   r5, [r2, #4]         @ expect A5A5A5A1 with byte1 AA -> A5A5AAA1
   ldr   r6, =0xA5A5AAA1
   cmp   r5, r6
   bne   fail_a_tramp
   ldr   r5, [r2, #8]         @ expect A5A5A5AD with hw1 BBCC -> BBCCA5AD
   ldr   r6, =0xBBCCA5AD
   cmp   r5, r6
   bne   fail_a_tramp
   ldr   r5, [r2, #16]        @ expect A5A5A5B5 with hw0 BBCC -> A5A5BBCC
   ldr   r6, =0xA5A5BBCC
   cmp   r5, r6
   bne   fail_a_tramp

   @ verify the untouched pattern words (skip 0,4,8,16)
   mov   r4, #20
rdloop:
   ldr   r5, [r2, r4]
   eor   r6, r3, r4
   cmp   r5, r6
   bne   fail_a_tramp
   add   r4, r4, #4
   cmp   r4, #1024
   bne   rdloop
   b     test_b

fail_a_tramp:
   b     fail_a

   @ ---------------- test B: ROM alias -------------------------------
test_b:
   ldr   r2, =0x02020000      @ EWRAM + 128KB
   ldr   r3, =0x08020000      @ ROM   + 128KB (same offset into the image)
   ldr   r5, =0xDEADBEEF
   str   r5, [r2]
   str   r5, [r2, #4]
   ldr   r6, [r3]             @ fresh ROM read, never touched before
   cmp   r6, r5
   beq   fail_b
   ldr   r6, [r3, #4]
   cmp   r6, r5
   beq   fail_b

   @ ---------------- verdicts ----------------------------------------
   ldr   r7, =0x03E0          @ green
   mov   r8, r7
   bl    paint
   b     loop_pass
   .ltorg

   .org 0x400
loop_pass:
   b     loop_pass

   .org 0x410
fail_a:
   ldr   r7, =0x001F          @ red top
   ldr   r8, =0x03E0          @ (B untested, keep green)
   bl    paint
loop_afail:
   b     loop_afail

   .org 0x420
fail_b:
   ldr   r7, =0x03E0          @ green top (A passed to get here)
   ldr   r8, =0x001F          @ red bottom = alias
   bl    paint
loop_alias:
   b     loop_alias

   @ paint(top r7, bottom r8) - mode 3 fill, no stack
paint:
   ldr   r0, =0x06000000
   orr   r7, r7, r7, lsl #16
   orr   r8, r8, r8, lsl #16
   mov   r1, #9600            @ 240*80 px / 2 px per word
p1:
   str   r7, [r0], #4
   subs  r1, r1, #1
   bne   p1
   mov   r1, #9600
p2:
   str   r8, [r0], #4
   subs  r1, r1, #1
   bne   p2
   bx    lr
   .ltorg
