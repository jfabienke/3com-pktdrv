; rx_pio_386.asm -- EtherLink III PIO receive drain via `rep insd` (386+ / 32-bit-PIO frag).
;
; Emitted instead of the 286 `rep insw` burst (rx_pio_286.asm) when the detected CPU is >=386 --
; the RX FIFO is a dword register, so 32-bit `rep insd` streams the frame in half as many port
; reads (one per dword vs one per word), cutting the per-frame PIO instruction count ~2x. This is
; the RX mirror of tx_pio_386.asm. `insd` in a bits-16 segment is the 0x66-prefixed `insw`.
;
; Unlike TX (which can over-WRITE/pad the FIFO, since the preamble length caps what the card
; sends), RX must read EXACTLY `length` bytes -- over-reading a FIFO consumes the next frame --
; so the 1..3 byte tail after the dword burst is drained with a trailing word + odd byte. The
; card pads the frame to a dword boundary in the FIFO; the ISR's RX_DISCARD flushes the slack.
;
; Patch slot 0 = io_base (sentinel 0xE3A7). In: ES:DI = dest, CX = byte count, DF=0 (set by the
; ISR). Clobbers BX, CX, DX, DI, FLAGS. Selected via frag_lookup (cpu_min=CPU_80386).
bits 16
cpu 386

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; DX = io_base + EL3_W1_RX_FIFO (0)
        mov     bx, cx          ; BX = byte count (leftover word + odd-byte tail)
        shr     cx, 2           ; CX = dword count = byte count / 4
        rep     insd            ; burst from the RX FIFO into ES:DI, 32 bits at a time
        mov     cx, bx
        and     cx, 3           ; leftover bytes (0..3)
        shr     cx, 1           ; CX = leftover words (0 or 1)
        rep     insw            ; drain the leftover word, if any
        test    bx, 1
        jz      .done
        insb                    ; odd trailing byte
.done:  ret
