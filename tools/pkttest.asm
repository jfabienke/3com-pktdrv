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

        ; --- v2 dispatch stubs (Phase 8b 8b.0): AH=0xF0, AL=0x03..0x06 are defined but
        ;     unimplemented -> CF=1, DH=XMS_ERR_NOT_V2 (0x0A). A genuinely-unknown AL (0x07)
        ;     -> CF=1, DH=PD_ERR_BADCMD (!= 0x0A). The stub path runs before any g_use_dma
        ;     gate, so this works on a PIO-only install (no /5 /d needed). Expect:
        ;       AL=03 CF=01 DH=0A   AL=06 CF=01 DH=0A   AL=07 CF=01 DH=<not 0A>
        mov     dx, msg_v2hdr
        mov     ah, 9
        int     0x21
        mov     al, 0x03
        call    run_sub
        mov     al, 0x06
        call    run_sub
        mov     al, 0x07
        call    run_sub
        ret

;--- helpers ---
run_sub:                                ; AL = AH=0xF0 sub-function to probe
        mov     [t_al], al
        mov     ah, 0xF0
        pushf
        call far [pkt_off]              ; simulated INT 60h
        pushf
        pop     ax                      ; capture returned FLAGS (CF = bit 0) immediately
        mov     [t_fl], al
        mov     [t_dh], dh              ; and the error code
        mov     dx, msg_sub
        mov     ah, 9
        int     0x21
        mov     al, [t_al]
        call    print_hex8
        mov     dx, msg_cf
        mov     ah, 9
        int     0x21
        mov     al, [t_fl]
        and     al, 1
        call    print_hex8
        mov     dx, msg_dh
        mov     ah, 9
        int     0x21
        mov     al, [t_dh]
        call    print_hex8
        call    print_crlf
        ret


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
msg_v2hdr  db 'v2 dispatch (expect 03/06 DH=0A, 07 DH!=0A):', 13, 10, '$'
msg_sub    db '  AL=', '$'
msg_cf     db ' CF=', '$'
msg_dh     db ' DH=', '$'
crlf       db 13, 10, '$'
cur_int    db 0
pkt_off    dw 0
pkt_seg    dw 0
t_al       db 0
t_fl       db 0
t_dh       db 0
macbuf     times 6 db 0
