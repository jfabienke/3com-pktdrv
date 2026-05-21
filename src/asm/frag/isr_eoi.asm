; isr_eoi.asm -- PIC end-of-interrupt + return from interrupt (8086 floor fragment).
;
; Tail of the emitted ISR. Non-specific EOI to the master PIC, then IRET. Slave-PIC EOI
; (for IRQ >= 8) and the RX-drain body land in the next milestone.
bits 16
cpu 8086

        mov     al, 0x20        ; non-specific EOI
        out     0x20, al        ; master PIC command port
        iret
