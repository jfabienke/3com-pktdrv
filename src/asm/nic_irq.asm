; nic_irq.asm -- NIC interrupt entry (HOT/resident). Milestone stub: the real ISR is
; JIT-emitted (FRAG_ISR_ENTRY/EOI); this provides a linkable resident vector body.
[BITS 16]
cpu 8086
segment _TEXT public align=2 class=CODE use16
global nic_isr_
nic_isr_:
        push    ax
        mov     al, 0x20        ; non-specific EOI to master PIC
        out     0x20, al
        pop     ax
        iret
