; rx_pio.asm -- EtherLink III PIO receive drain (8086 floor fragment).
;
; The pure hot inner loop: drain CX bytes from the RX FIFO (Window 1, io_base+0) into ES:DI.
; The ISR reads the RX status/length and does the Crynwr receiver upcall; this fragment is
; the emitted, io_base-specialised data mover it calls once a buffer is known. Patch slot 0
; = io_base (sentinel 0xE3A7).
;
; In:  ES:DI = dest buffer, CX = byte count
; Out: CX bytes copied to ES:DI ; Clobbers AX, BX, DX, DI, CX
bits 16
cpu 8086

        mov     bx, 0xE3A7      ; <- io_base (patched at compose)
        mov     dx, bx          ; RX FIFO @ io_base + EL3_W1_RX_FIFO (0)
        push    cx
        shr     cx, 1           ; word count
        jcxz    .tail
.w:     in      ax, dx
        stosw
        loop    .w
.tail:  pop     cx
        test    cx, 1           ; odd trailing byte?
        jz      .done
        in      al, dx
        stosb
.done:  ret
