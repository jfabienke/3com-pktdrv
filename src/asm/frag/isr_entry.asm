; isr_entry.asm -- emitted ISR prologue (8086 floor stub).
;
; Placeholder slot in the emitted ISR. The real prologue (register save, EL3 status read,
; RX-on-interrupt drain into the receiver upcall) lands with the Crynwr receiver protocol
; in the next milestone; for now it occupies its position in the composed image as a no-op.
bits 16
cpu 8086

        nop
