; pktdbg.asm -- Packet Driver debug dumper (DOS .COM, nasm -f bin).
;
; For out-of-house hardware testing: finds the resident driver, prints its MAC, sends one
; test frame (exercises TX + counters), then dumps get_statistics (fn 24) and the debug
; event-log ring (vendor fn 0x7F, present only in CFG_DEBUG builds). Run it after exercising
; the network, redirect to a file, and send the file back.  Build:
;   nasm -f bin tools/pktdbg.asm -o build/pktdbg.com
cpu 8086
bits 16
org 0x100

start:
        mov     byte [cur_int], 0x60
.scan:
        mov     al, [cur_int]
        mov     ah, 0x35
        int     0x21
        mov     di, bx
        add     di, 3
        mov     si, sig
        mov     cx, 8
        cld
        repe    cmpsb
        je      .found
        inc     byte [cur_int]
        cmp     byte [cur_int], 0x81
        jb      .scan
        mov     dx, msg_none
        mov     ah, 9
        int     0x21
        ret
.found:
        mov     [pkt_off], bx
        mov     [pkt_seg], es
        mov     dx, msg_found
        mov     ah, 9
        int     0x21
        mov     al, [cur_int]
        call    hex8
        call    crlf

        ; --- get_address (6) -> MAC ---
        push    cs
        pop     es
        mov     di, macbuf
        mov     cx, 6
        mov     ah, 6
        int     0x60
        mov     dx, msg_mac
        mov     ah, 9
        int     0x21
        mov     si, macbuf
        mov     cx, 6
.pm:    push    cx
        lodsb
        call    hex8
        pop     cx
        loop    .pm
        call    crlf

        ; --- send one test frame (exercises TX + stat_tx + the event log) ---
        mov     si, testpkt
        mov     cx, testpkt_len
        mov     ah, 4                   ; send_pkt: DS:SI = packet, CX = length
        int     0x60

        ; --- get_statistics (24) -> DS:SI = stats struct ---
        mov     ah, 24
        int     0x60
        ; DS now holds the driver's segment, so capture the far pointer in registers
        ; BEFORE restoring our DS (else [blk_*] would address the driver's segment).
        mov     bx, ds
        mov     dx, si
        push    cs
        pop     ds                      ; restore our DS
        mov     [blk_seg], bx
        mov     [blk_off], dx
        mov     dx, msg_stats
        call    pstr
        les     bx, [blk_off]           ; ES:BX -> stats (dword fields)
        mov     dx, msg_in
        call    pstr
        mov     ax, [es:bx + 0]
        call    hex16
        mov     dx, msg_out
        call    pstr
        mov     ax, [es:bx + 4]
        call    hex16
        mov     dx, msg_err
        call    pstr
        mov     ax, [es:bx + 16]
        call    hex16
        mov     dx, msg_lost
        call    pstr
        mov     ax, [es:bx + 24]
        call    hex16
        call    crlf

        ; --- debug event log (vendor fn 0x7F; absent in release builds) ---
        mov     ah, 0x7F
        int     0x60
        jc      .done                   ; not a debug build -> no log
        mov     bx, ds                  ; capture before restoring our DS
        mov     dx, si
        push    cs
        pop     ds
        mov     [blk_seg], bx
        mov     [blk_off], dx
        mov     dx, msg_log
        mov     ah, 9
        int     0x21
        les     bx, [blk_off]           ; ES:BX -> dbg block: sig[8], head(word), ring
        mov     bp, [es:bx + 8]         ; ring head (oldest entry)
        mov     cx, 512                 ; DBG_LOG_SIZE
        xor     si, si                  ; i
.logloop:
        mov     di, bp
        add     di, si
        and     di, 511                 ; (head + i) mod 512
        mov     al, [es:bx + 10 + di]   ; ring byte
        or      al, al
        jz      .lognext                ; skip unwritten slots
        call    pchar
.lognext:
        inc     si
        loop    .logloop
        call    crlf
.done:
        ret

;--- helpers ---
pstr:   mov     ah, 9                   ; DS:DX -> '$' string
        int     0x21
        ret
pchar:  mov     dl, al                  ; AL char
        mov     ah, 2
        int     0x21
        ret
hex8:   push    ax                      ; AL -> 2 hex
        mov     cl, 4
        shr     al, cl
        call    hnib
        pop     ax
        call    hnib
        ret
hex16:  push    ax                      ; AX -> 4 hex
        mov     al, ah
        call    hex8
        pop     ax
        call    hex8
        ret
hnib:   and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .e
        add     al, 7
.e:     mov     dl, al
        mov     ah, 2
        int     0x21
        ret
crlf:   mov     dx, nl
        mov     ah, 9
        int     0x21
        ret

sig        db 'PKT DRVR'
msg_found  db 'driver at INT 0x', '$'
msg_none   db 'no packet driver found', 13, 10, '$'
msg_mac    db 'MAC=', '$'
msg_stats  db 'stats:', '$'
msg_in     db ' in=', '$'
msg_out    db ' out=', '$'
msg_err    db ' err=', '$'
msg_lost   db ' lost=', '$'
msg_log    db 'log: ', '$'
nl         db 13, 10, '$'
cur_int    db 0
pkt_off    dw 0
pkt_seg    dw 0
blk_off    dw 0
blk_seg    dw 0
macbuf     times 6 db 0
testpkt    times 60 db 0xFF            ; dummy broadcast-ish frame
testpkt_len equ $ - testpkt
