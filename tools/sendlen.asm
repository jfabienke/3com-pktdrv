; sendlen.asm -- send_pkt / async-send length-guard probe (DOS .COM, nasm -f bin).
;
; Calls the packet driver at INT 60h with send_pkt (AH=4) and, when available, the async zero-copy send
; (AH=0xF1 AL=1) for a set of frame lengths, and prints one line per call:
;   SENDLEN fn=04 len=05DC cf=0 dh=00
; Lengths 1..1514 must succeed (cf=0); 0 and anything above 1514 must fail with CANT_SEND (cf=1 dh=0C)
; without touching a datapath. The frame is a broadcast with a zero payload. Build:
;   nasm -f bin tools/sendlen.asm -o build/sendlen.com
cpu 8086
bits 16
org 0x100

PKTINT  equ 0x60

start:
        ; broadcast destination, our source is don't-care, type 0x0800
        mov     di, frame
        mov     cx, 6
        mov     al, 0xFF
        push    cs
        pop     es
        cld
        rep     stosb
        ; send_pkt over every length
        mov     si, lens
.sl:    lodsw
        cmp     ax, 0xFFFF
        je      .async
        push    si
        mov     cx, ax
        mov     [cur_len], ax
        mov     si, frame
        mov     ah, 4
        int     PKTINT
        mov     byte [cur_fn], 0x04
        call    report
        pop     si
        jmp     .sl
.async:
        ; ASYNC_INFO: CF=1 -> no async ring on this driver config -> done
        mov     ax, 0xF100
        int     PKTINT
        jc      .done
        mov     si, lens
.al:    lodsw
        cmp     ax, 0xFFFF
        je      .drain
        push    si
        mov     cx, ax
        mov     [cur_len], ax
        mov     si, frame
        mov     ax, 0xF101                      ; ASYNC_SEND: DS:SI = frame, CX = length
        int     PKTINT
        mov     byte [cur_fn], 0xF1
        call    report
        ; the accepted frames stay posted until TxComplete: wait a tick before reusing the buffer slot
        call    tick_wait
        pop     si
        jmp     .al
.drain:
        call    tick_wait
.done:
        mov     ax, 0x4C00
        int     0x21

; report -- print "SENDLEN fn=XX len=XXXX cf=N dh=XX" from the flags/DH the call left
report:
        pushf
        pop     bx                              ; BX = flags (CF = bit 0)
        push    dx                              ; DH = error code
        mov     dx, msg_pre
        mov     ah, 9
        int     0x21
        mov     al, [cur_fn]
        call    print_hex8
        mov     dx, msg_len
        mov     ah, 9
        int     0x21
        mov     ax, [cur_len]
        push    ax
        mov     al, ah
        call    print_hex8
        pop     ax
        call    print_hex8
        mov     dx, msg_cf
        mov     ah, 9
        int     0x21
        mov     dl, '0'
        test    bl, 1
        jz      .cf0
        mov     dl, '1'
.cf0:   mov     ah, 2
        int     0x21
        mov     dx, msg_dh
        mov     ah, 9
        int     0x21
        pop     dx
        mov     al, dh
        test    bl, 1
        jnz     .dh
        xor     al, al                          ; DH is only meaningful on failure
.dh:    call    print_hex8
        mov     dx, msg_crlf
        mov     ah, 9
        int     0x21
        ret

; tick_wait -- wait for the BIOS tick to advance twice (~55-110 ms)
tick_wait:
        push    es
        xor     ax, ax
        mov     es, ax
        mov     bx, [es:0x046C]
.tw:    mov     ax, [es:0x046C]
        sub     ax, bx
        cmp     ax, 2
        jb      .tw
        pop     es
        ret

; print_hex8 -- AL as two hex digits
print_hex8:
        push    ax
        mov     cl, 4
        shr     al, cl
        call    .nib
        pop     ax
        and     al, 0x0F
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     .out
        add     al, 7
.out:   mov     dl, al
        mov     ah, 2
        int     0x21
        ret

lens:     dw 60, 1514, 0, 1515, 1600, 0xFFFF
msg_pre:  db 'SENDLEN fn=$'
msg_len:  db ' len=$'
msg_cf:   db ' cf=$'
msg_dh:   db ' dh=$'
msg_crlf: db 13, 10, '$'
cur_fn:   db 0
cur_len:  dw 0
frame:    times 6 db 0
          times 6 db 0x52
          db 0x08, 0x00
          times 1600 - 14 db 0
