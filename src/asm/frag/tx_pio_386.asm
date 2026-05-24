; tx_pio_386.asm -- EtherLink III PIO transmit via `rep outsd` (386+ / 32-bit-PIO fragment).
;
; The composer emits this instead of the 286 `rep outsw` burst (tx_pio_286.asm) when the detected
; CPU is >=386 -- the TX/RX FIFO is a dword register, so 32-bit `rep outsd` streams the frame in
; half as many port writes (one per dword vs one per word), cutting the per-frame PIO instruction
; count ~2x. The card consumes the FIFO in dwords; the preamble is a single dword {length, 0} and
; the frame data is padded up to a dword boundary (the card sends exactly the preamble length).
;
; Patch slot 0 = io_base (sentinel 0xE3A7). In: DS:SI = packet, CX = length, DF=0 (set by the
; handler). Clobbers EAX, BX, CX, DX, SI. Selected via frag_lookup (cpu_min=CPU_80386).
bits 16
cpu 386

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; DX = io_base + EL3_W1_TX_FIFO (0)
        movzx   eax, cx         ; EAX = length (preamble dword: low word = length, high word = 0)
        out     dx, eax         ; 32-bit preamble write {length, 0} in one OUT
        add     cx, 3
        shr     cx, 2           ; CX = dword count = roundup4(length) / 4
        rep     outsd           ; burst the frame to the TX FIFO, 32 bits at a time
        ret
