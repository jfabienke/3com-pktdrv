; rx_pio.asm -- EtherLink III PIO receive drain, 4x loop-unrolled (8086 floor fragment).
;
; The pure hot inner loop: drain CX bytes from the RX FIFO (Window 1, io_base+0) into ES:DI.
; The ISR reads RX status/length and does the receiver upcall; this is the io_base-baked
; data mover it calls. FIFO reads are 4-words-per-iteration to amortise the `loop` overhead
; on a slow 8088 (where `rep insw` -- the 186+/286 win -- is unavailable). The 286+
; `rep insw` burst is a separate higher-cpu_min fragment.
;
; Patch slot 0 = io_base (sentinel 0xE3A7). In: ES:DI = dest, CX = byte count.
; Clobbers AX, BX, CX, DX, SI, DI, FLAGS.
bits 16
cpu 8086

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; DX = io_base + EL3_W1_RX_FIFO (0)
        mov     bx, cx          ; BX = byte count (for the odd-byte tail)
        shr     cx, 1           ; CX = word count
        mov     si, cx
        and     si, 3           ; SI = remainder words (0..3)
        shr     cx, 1
        shr     cx, 1           ; CX = words / 4   (8088-safe: shr-by-1 only)
        jcxz    .rem
.u4:    in      ax, dx
        stosw
        in      ax, dx
        stosw
        in      ax, dx
        stosw
        in      ax, dx
        stosw
        loop    .u4
.rem:   mov     cx, si          ; the 0..3 leftover words
        jcxz    .tail
.r1:    in      ax, dx
        stosw
        loop    .r1
.tail:  test    bx, 1           ; odd trailing byte?
        jz      .done
        in      al, dx
        stosb
.done:  ret
