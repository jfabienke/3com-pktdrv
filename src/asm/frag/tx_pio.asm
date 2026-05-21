; tx_pio.asm -- EtherLink III PIO transmit, 4x loop-unrolled (8086 floor fragment).
;
; Composed into the resident image by the JIT composer (docs/02); send_pkt near-calls it.
; The FIFO writes are 4-words-per-iteration to amortise the `loop` overhead, which is a
; real fraction of per-word cost on a 4.77 MHz 8088 (where `rep outsw` -- the 186+/286 win
; -- is unavailable). The 286+ `rep outsw` burst is a separate higher-cpu_min fragment.
;
; Patch slot 0 = io_base (sentinel 0xE3A7). In: DS:SI = packet, CX = length.
; Clobbers AX, BX, CX, DX, SI, DI, FLAGS. Mirrors el3_send_pio() in src/hw/el3_core.c.
bits 16
cpu 8086

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; DX = io_base + EL3_W1_TX_FIFO (0)
        mov     ax, cx          ; TX preamble word = length
        out     dx, ax
        xor     ax, ax
        out     dx, ax          ; second preamble word
        mov     bx, cx          ; BX = byte count (for the odd-byte tail)
        shr     cx, 1           ; CX = word count
        mov     di, cx
        and     di, 3           ; DI = remainder words (0..3)
        shr     cx, 1
        shr     cx, 1           ; CX = words / 4   (8088-safe: shr-by-1 only)
        jcxz    .rem
.u4:    lodsw
        out     dx, ax
        lodsw
        out     dx, ax
        lodsw
        out     dx, ax
        lodsw
        out     dx, ax
        loop    .u4
.rem:   mov     cx, di          ; the 0..3 leftover words
        jcxz    .tail
.r1:    lodsw
        out     dx, ax
        loop    .r1
.tail:  test    bx, 1           ; odd trailing byte?
        jz      .done
        lodsb
        out     dx, al
.done:  ret
