@ SPDX-License-Identifier: GPL-3.0-or-later
@ SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

.arm
.section .text
.global _start

_start:
   b     start
   .space 0xBC

.macro TSTART
   mov   r9, #0
   str   r9, [r8]
   mov   r9, #0x00800000
   str   r9, [r8]
.endm

.macro TSTOP idx
   ldrh  r10, [r8]
   mov   r9, #0
   strh  r9, [r8, #2]
   str   r10, [r11, #4*\idx]
.endm

.macro CALLR12
   mov   lr, pc
   bx    r12
.endm

.macro IWADDR fsym
   ldr   r12, =\fsym
   ldr   r9, =blob_start
   sub   r12, r12, r9
   add   r12, r12, #0x03000000
.endm

start:
   ldr   r0, =blob_start
   ldr   r1, =0x03000000
   ldr   r2, =blob_end
copyloop:
   ldr   r3, [r0], #4
   str   r3, [r1], #4
   cmp   r0, r2
   blo   copyloop

   ldr   r8,  =0x04000100
   mov   r11, #0x03000000
   orr   r11, r11, #0x7800

   TSTART
   TSTOP 0

   IWADDR f_nops256
   TSTART
   CALLR12
   TSTOP 1

   ldr   r0, =0x04000204
   mov   r4, #0
   strh  r4, [r0]
   ldr   r12, =rom_nop256 + 1
   TSTART
   CALLR12
   TSTOP 2

   mov   r4, #0x4000
   strh  r4, [r0]
   TSTART
   CALLR12
   TSTOP 3

   ldr   r4, =0x4014
   strh  r4, [r0]
   ldr   r1, =0x00550055
   ldr   r2, =0x7FFFFFFF
   ldr   r12, =rom_mul64
   TSTART
   CALLR12
   TSTOP 4

   ldr   r0, =0x04000204
   mov   r4, #0x14
   strh  r4, [r0]
   TSTART
   CALLR12
   TSTOP 5

   ldr   r0, =0x04000204
   mov   r4, #0x4000
   strh  r4, [r0]
   ldr   r12, =rom_nop224_nocross + 1
   TSTART
   CALLR12
   TSTOP 6
   ldr   r12, =rom_nop224_cross + 1
   TSTART
   CALLR12
   TSTOP 7

   ldr   r0, =0x04000000
   ldr   r4, =0x0403
   strh  r4, [r0]
   ldr   r7, =0x04000004
   ldr   r3, =0x06000000
   ldr   r2, =0x12341234
   IWADDR f_strh128
wv30a:
   ldrh  r9, [r7, #2]
   cmp   r9, #30
   bne   wv30a
   TSTART
   CALLR12
   TSTOP 8
wv170a:
   ldrh  r9, [r7, #2]
   cmp   r9, #170
   bne   wv170a
   TSTART
   CALLR12
   TSTOP 9

   ldr   r4, =0x1040
   strh  r4, [r0]
   ldr   r3, =0x07000000
wv30b:
   ldrh  r9, [r7, #2]
   cmp   r9, #30
   bne   wv30b
   TSTART
   CALLR12
   TSTOP 10
wv170b:
   ldrh  r9, [r7, #2]
   cmp   r9, #170
   bne   wv170b
   TSTART
   CALLR12
   TSTOP 11

   ldr   r3, =0x02000000
   IWADDR f_ldr128
   TSTART
   CALLR12
   TSTOP 12

wv170c:
   ldrh  r9, [r7, #2]
   cmp   r9, #170
   bne   wv170c
   ldr   r0, =0x040000D4
   ldr   r4, =0x08000000
   str   r4, [r0]
   ldr   r4, =0x03006000
   str   r4, [r0, #4]
   ldr   r5, =0x84000040
   TSTART
   str   r5, [r0, #8]
   TSTOP 13
   ldr   r4, =0x03005000
   str   r4, [r0]
   ldr   r4, =0x03006000
   str   r4, [r0, #4]
   TSTART
   str   r5, [r0, #8]
   TSTOP 14

   b     park0
   .ltorg

.org 0xE00
park0:
   mov   r7, #0x03000000
   orr   r7, r7, #0x7800
   ldmia r7, {r0-r5}
   mov   r6, #800
p0loop:
   subs  r6, r6, #1
   bne   p0loop
   b     park1

.org 0xE40
park1:
   add   r7, r7, #24
   ldmia r7, {r0-r5}
   mov   r6, #800
p1loop:
   subs  r6, r6, #1
   bne   p1loop
   b     park2

.org 0xE80
park2:
   add   r7, r7, #24
   ldmia r7, {r0-r2}
   mov   r3, #0
   mov   r4, #0
   mov   r5, #0
   mov   r6, #800
p2loop:
   subs  r6, r6, #1
   bne   p2loop
   b     done

.org 0xEC0
done:
   b     done

.org 0x1000
.thumb
rom_nop256:
   .rept 256
   mov   r8, r8
   .endr
   bx    lr
.arm

.org 0x1800
rom_mul64:
   .rept 64
   mul   r0, r1, r2
   .endr
   bx    lr

.org 0x1FA00
.thumb
rom_nop224_nocross:
   .rept 224
   mov   r8, r8
   .endr
   bx    lr
.arm

.org 0x1FF00
.thumb
rom_nop224_cross:
   .rept 224
   mov   r8, r8
   .endr
   bx    lr
.arm

.org 0x20400
blob_start:
f_nops256:
   .rept 256
   mov   r0, r0
   .endr
   bx    lr
f_strh128:
   .rept 128
   strh  r2, [r3]
   .endr
   bx    lr
f_ldr128:
   .rept 128
   ldr   r2, [r3]
   .endr
   bx    lr
blob_end:
