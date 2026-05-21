; rx_pio.asm -- EtherLink III PIO receive (8086 floor fragment).
;
; Position-independent hot-path block (docs/02). Mirrors el3_recv_pio() in
; src/hw/el3_core.c. Patch slot 0 = io_base (sentinel 0xE3A7).
;
; In:  ES:DI = destination buffer
; Out: CX = length (bytes), CF = 1 if RX incomplete (no full packet ready)
; Clobbers: AX, BX, DX, DI, CX, FLAGS
bits 16
cpu 8086

        mov     bx, 0xE3A7      ; <- io_base (patched at compose time)
        mov     dx, bx
        add     dx, 0x08        ; EL3_W1_RX_STATUS
        in      ax, dx
        test    ah, 0x80        ; EL3_RX_INCOMPLETE (0x8000)
        jnz     .incomplete
        mov     cx, ax
        and     cx, 0x07FF      ; EL3_RX_LEN_MASK
        mov     dx, bx          ; DX = io_base + EL3_W1_RX_FIFO (offset 0)
        push    cx
        shr     cx, 1           ; word count
        jcxz    .rtail
.rloop: in      ax, dx
        stosw                   ; [ES:DI] = AX, DI += 2
        loop    .rloop
.rtail: pop     cx
        test    cx, 1           ; odd trailing byte?
        jz      .discard
        in      al, dx
        stosb
.discard:
        mov     dx, bx
        add     dx, 0x0E        ; EL3_CMD
        mov     ax, 0x4000      ; EL3_CMD_RX_DISCARD -- pop the packet
        out     dx, ax
        clc
        ret
.incomplete:
        stc
        ret
