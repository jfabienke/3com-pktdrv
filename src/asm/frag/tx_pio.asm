; tx_pio.asm -- EtherLink III PIO transmit (8086 floor fragment).
;
; Position-independent hot-path building block, composed into the resident image by the
; JIT composer (docs/02-resident-construction.md). Mirrors el3_send_pio() in
; src/hw/el3_core.c -- the C version is the control-plane fallback; this is the emitted
; per-packet path.
;
; Patch slot 0 = io_base (16-bit), encoded as the sentinel 0xE3A7 in `mov bx, imm16`;
; tools/mkfrag.py locates the immediate and frag_patch_t records its offset.
;
; In:  DS:SI = packet bytes, CX = length (bytes)
; Out: frame written to the TX FIFO
; Clobbers: AX, BX, DX, SI, CX, FLAGS
;
; The 3C509B TX/RX FIFO + status all live in Window 1 (operating); the floor keeps W1
; selected, so no window switch is emitted in the hot path.
bits 16
cpu 8086

        mov     bx, 0xE3A7      ; <- io_base (patched at compose time)
        mov     dx, bx          ; DX = io_base + EL3_W1_TX_FIFO (offset 0)
        mov     ax, cx          ; TX preamble word = length
        out     dx, ax          ; outpw(io+0, len)
        xor     ax, ax
        out     dx, ax          ; outpw(io+0, 0)   -- second preamble word
        push    cx
        shr     cx, 1           ; word count
        jcxz    .tail
.wloop: lodsw                   ; AX = [DS:SI], SI += 2
        out     dx, ax
        loop    .wloop
.tail:  pop     cx
        test    cx, 1           ; odd trailing byte?
        jz      .done
        lodsb
        out     dx, al
.done:  ret
