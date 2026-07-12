.syntax unified
.cpu cortex-a9
.arm

.section .text, "ax"
.global _start
.type _start, %function

_start:
  ldr r0, =0x43C00000

  ldr r1, =0x00000015
  str r1, [r0, #0x08]
  dsb sy
  mov r5, #0x400
delay_after_reset:
  subs r5, r5, #1
  bne delay_after_reset

  ldr r1, =0x00000011
  str r1, [r0, #0x08]
  dsb sy

  adr r1, rowhandoff_events
  adr r2, rowhandoff_events_end
  add r3, r0, #0x40

write_event_loop:
  ldr r4, [r1], #4
  str r4, [r3]
  dsb sy
  cmp r1, r2
  bne write_event_loop

done_loop:
  wfe
  b done_loop

.align 2
rowhandoff_events:
  .word 0x00000001
  .word 0x00180040
  .word 0x00180008
  .word 0x00180080
  .word 0x00180120
  .word 0x00190040
  .word 0x00190002
  .word 0x00190004
  .word 0x00190080
  .word 0x00190120
  .word 0x001A0040
  .word 0x001A0002
  .word 0x001A0004
  .word 0x001A0080
  .word 0x001A0120
  .word 0x001B0040
  .word 0x001B0002
  .word 0x001B0004
  .word 0x001B0080
  .word 0x001B0120
  .word 0x001C0040
  .word 0x001C0002
  .word 0x001C0004
  .word 0x001C0080
  .word 0x001C0120
  .word 0x001D0040
  .word 0x001D0002
  .word 0x001D0004
  .word 0x001D0080
  .word 0x001D0120
  .word 0x001E0040
  .word 0x001E0002
  .word 0x001E0004
  .word 0x001E0080
  .word 0x001E0120
  .word 0x001F0040
  .word 0x001F0002
  .word 0x001F0004
  .word 0x001F0080
  .word 0x001F0120
  .word 0x00200040
  .word 0x00200002
  .word 0x00200004
  .word 0x00200080
  .word 0x00200120
  .word 0x00210040
  .word 0x00210002
  .word 0x00210004
  .word 0x00210080
  .word 0x00210120
  .word 0x00220040
  .word 0x00220002
  .word 0x00220004
  .word 0x00220080
  .word 0x00220120
  .word 0x00230040
  .word 0x00230002
  .word 0x00230004
  .word 0x00230080
  .word 0x00230120
  .word 0x00240040
  .word 0x00240002
  .word 0x00240004
  .word 0x00240080
  .word 0x00240120
  .word 0x00250040
  .word 0x00250002
  .word 0x00250004
  .word 0x00250080
  .word 0x00250120
  .word 0x00260040
  .word 0x00260002
  .word 0x00260004
  .word 0x00260080
  .word 0x00260120
  .word 0x00270040
  .word 0x00270002
  .word 0x00270004
  .word 0x00270080
  .word 0x00270120
  .word 0x00280040
  .word 0x00280002
  .word 0x00280004
  .word 0x00280080
  .word 0x00280120
  .word 0x00290040
  .word 0x00290002
  .word 0x00290004
  .word 0x00290080
  .word 0x00290120
  .word 0x002A0040
  .word 0x002A0002
  .word 0x002A0004
  .word 0x002A0080
  .word 0x002A0120
  .word 0x002B0040
  .word 0x002B0002
  .word 0x002B0004
  .word 0x002B0080
  .word 0x002B0120
  .word 0x002C0040
  .word 0x002C0002
  .word 0x002C0004
  .word 0x002C0080
  .word 0x002C0120
  .word 0x002D0040
  .word 0x002D0002
  .word 0x002D0004
  .word 0x002D0080
  .word 0x002D0120
  .word 0x002E0010
rowhandoff_events_end:

.ltorg
