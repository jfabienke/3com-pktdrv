; pkttest.asm -- minimal Packet Driver probe (DOS .COM, nasm -f bin).
;
; Scans INT 60h..80h for the "PKT DRVR" signature at handler+3, then calls the driver's
; get_address (AH=6) and prints the returned MAC. Validates that our resident INT 60h
; handler is installed, detectable, and dispatches correctly. Build:
;   nasm -f bin tools/pkttest.asm -o build/pkttest.com
cpu 8086
bits 16
org 0x100

start:
        mov     byte [cur_int], 0x60    ; AH=35h returns BX, so keep the counter in memory
.scan:
        mov     al, [cur_int]
        mov     ah, 0x35                ; get interrupt vector AL -> ES:BX
        int     0x21
        mov     di, bx
        add     di, 3                   ; handler+3 = signature offset
        mov     si, sig
        mov     cx, 8
        cld
        repe    cmpsb                   ; DS:SI (sig) vs ES:DI (handler+3)
        je      .found
        inc     byte [cur_int]
        cmp     byte [cur_int], 0x81
        jb      .scan

        mov     dx, msg_none
        mov     ah, 9
        int     0x21
        ret

.found:
        mov     [pkt_off], bx           ; save handler far pointer
        mov     [pkt_seg], es
        mov     dx, msg_found
        mov     ah, 9
        int     0x21
        mov     al, [cur_int]           ; the INT number we found it on
        call    print_hex8
        call    print_crlf

        ; get_address: AH=6, ES:DI = buffer, CX = buffer length
        push    cs
        pop     es
        mov     di, macbuf
        mov     cx, 6
        mov     ah, 6
        pushf
        call far [pkt_off]              ; invoke the packet driver (simulated INT)

        mov     dx, msg_mac
        mov     ah, 9
        int     0x21
        mov     si, macbuf
        mov     cx, 6
.pm:
        push    cx
        lodsb
        call    print_hex8
        pop     cx
        loop    .pm
        call    print_crlf
        ret

;--- helpers ---
print_hex8:                             ; AL -> 2 hex digits
        push    ax
        mov     cl, 4
        shr     al, cl
        call    print_nib
        pop     ax
        call    print_nib
        ret
print_nib:
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .e
        add     al, 7
.e:
        mov     dl, al
        mov     ah, 2
        int     0x21
        ret
print_crlf:
        mov     dx, crlf
        mov     ah, 9
        int     0x21
        ret

sig        db 'PKT DRVR'
msg_found  db 'PKT DRVR found at INT 0x', '$'
msg_none   db 'No packet driver found', 13, 10, '$'
msg_mac    db 'get_address MAC=', '$'
crlf       db 13, 10, '$'
cur_int    db 0
pkt_off    dw 0
pkt_seg    dw 0
macbuf     times 6 db 0
