; rx_pio_286.asm -- EtherLink III PIO receive drain via `rep insw` (286+ / 16-bit-ISA frag).
;
; Emitted instead of the 8088 unrolled loop (rx_pio.asm) when the detected CPU is >=286
; (AT-class, 16-bit ISA): insw streams from the RX FIFO in single 16-bit bus cycles. insw is
; 80186+; 286 is the gate because it also implies the 16-bit bus. The ISR reads RX
; status/length and does the receiver upcall; this is the io_base-baked data mover it calls.
;
; Patch slot 0 = io_base (sentinel 0xE3A7). In: ES:DI = dest, CX = byte count, DF=0.
; Clobbers AX, BX, CX, DX, DI. Selected via frag_lookup (cpu_min=CPU_80286).
bits 16
cpu 286

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; DX = io_base + EL3_W1_RX_FIFO (0)
        mov     bx, cx          ; BX = byte count (odd-byte tail)
        shr     cx, 1           ; CX = word count
        rep     insw            ; burst from the RX FIFO into ES:DI
        test    bx, 1
        jz      .done
        insb                    ; odd trailing byte
.done:  ret
