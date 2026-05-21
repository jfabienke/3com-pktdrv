; tx_pio_286.asm -- EtherLink III PIO transmit via `rep outsw` (286+ / 16-bit-ISA fragment).
;
; The composer emits this instead of the 8088 unrolled loop (tx_pio.asm) when the detected
; CPU is >=286 -- i.e. an AT-class machine with a 16-bit ISA bus, where outsw streams the
; frame to the FIFO in single 16-bit bus cycles (no loop, no per-word instruction overhead).
; outsw is an 80186+ instruction; 286 is the gate because that also implies the 16-bit bus.
;
; Patch slot 0 = io_base (sentinel 0xE3A7). In: DS:SI = packet, CX = length, DF=0 (set by
; the handler). Clobbers AX, BX, CX, DX, SI. Selected via frag_lookup (cpu_min=CPU_80286).
bits 16
cpu 286

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; DX = io_base + EL3_W1_TX_FIFO (0)
        mov     ax, cx          ; TX preamble word = length
        out     dx, ax
        xor     ax, ax
        out     dx, ax          ; second preamble word
        mov     bx, cx          ; BX = byte count (odd-byte tail)
        shr     cx, 1           ; CX = word count
        rep     outsw           ; burst the frame to the TX FIFO
        test    bx, 1
        jz      .done
        outsb                   ; odd trailing byte
.done:  ret
