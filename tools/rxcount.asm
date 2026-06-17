; rxcount.asm -- packet-driver RX throughput probe (DOS .COM, nasm -f bin).
;
; Registers a handle whose receiver upcall counts every delivered frame, then waits a fixed
; BIOS-tick window while the host floods frames at the NIC, and prints the count. The mirror of
; blast.asm (TX). No TCP/peer, so it's immune to the icount-vs-real-server distortion.
;
; Output: "RXFRAMES=XXXXXXXX" (32-bit hex). The host harness turns that into kbit/s:
;   frames * framelen * 8 / window_seconds.
;
; Build: nasm -f bin tools/rxcount.asm -o build/rxcount.com
cpu 8086
bits 16
org 0x100

DURATION  equ 54        ; BIOS ticks ~= 3 s at 18.2 Hz (virtual time under -icount)
RXBUFSZ   equ 1600

start:
        mov     byte [cur_int], 0x60
.scan:
        mov     al, [cur_int]
        mov     ah, 0x35
        int     0x21                    ; ES:BX = INT vector handler
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
        ; register a handle (access_type, fn 2): match all Ethernet types (CX=0), receiver = our
        ; counting upcall.
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     ah, 2
        mov     al, 1                   ; interface class = 1 (DIX/Blue Book Ethernet)
        mov     bx, 0xFFFF              ; interface type = any
        mov     dl, 0                   ; interface number 0
        xor     si, si                  ; DS:SI = type template (unused with CX=0)
        xor     cx, cx                  ; type length 0 = match all
        mov     di, receiver            ; ES:DI = receiver upcall
        int     0x60
        jc      .noacc
        mov     [handle], ax
        ; PEEK1: the slot's recv_seg right after registration (ES = INT 60h handler seg = resident)
        mov     al, 0x60
        mov     ah, 0x35
        int     0x21
        mov     [h60seg], es            ; the INT 60h handler's segment
        mov     bx, [handle]
        mov     ax, [es:bx+2]
        mov     [peek1], ax
.noacc:
        ; start tick (BIOS 0040:006C low word; no wrap in ~3 s)
        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x6C]
        mov     [start_tick], ax
        ; Arm the emulator's RX wire-rate generator (rxgen test feature) NOW that we're registered
        ; and about to start the timed window -- so the flood doesn't swamp DOS while it was loading
        ; us. Select window 1, then write a nonzero word to W1_TIMER (read-only timer reg on real
        ; silicon, so this is a harmless no-op there and when rxgen is disabled). IOBASE hardcoded to
        ; 0x300 (the harness uses /b=300). CLI so an RX IRQ can't switch windows mid-sequence.
        cli
        mov     dx, 0x30E               ; command/status register
        mov     ax, 0x0801              ; SELECT_WINDOW | 1
        out     dx, ax
        mov     dx, 0x30A               ; W1_TIMER
        mov     ax, 0x5247              ; magic 'RG' = arm the generator
        out     dx, ax
        sti
.wait:
        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x6C]
        sub     ax, [start_tick]
        cmp     ax, DURATION
        jae     .done
        sti                             ; let the RX IRQ fire -> driver calls receiver
        hlt
        jmp     .wait
.done:
        ; NOTE: do NOT disarm the generator here. The emulator-side measurement reports [RXGEN] when
        ; its own 2.966 s virtual window elapses (and self-disarms then); a disarm here would race it
        ; and delete the generator timer before it can report on fast cells. The harness kills QEMU
        ; once [RXGEN] is seen, so teardown speed doesn't matter.
        ; PEEK2: the slot's recv_seg NOW (after the wait)
        mov     al, 0x60
        mov     ah, 0x35
        int     0x21
        mov     bx, [handle]
        mov     ax, [es:bx+2]
        mov     [peek2], ax
        mov     dx, msg_hnd             ; HANDLE=  (the registered slot, 0 = failed)
        mov     ah, 9
        int     0x21
        mov     ax, [handle]
        call    hex16
        call    crlf
        mov     dx, msg_pk1             ; recv_seg right after registration
        mov     ah, 9
        int     0x21
        mov     ax, [peek1]
        call    hex16
        call    crlf
        mov     dx, msg_pk2             ; recv_seg after the wait
        mov     ah, 9
        int     0x21
        mov     ax, [peek2]
        call    hex16
        call    crlf
        mov     dx, msg_req             ; REQ=  (buffer requests = handle matches)
        mov     ah, 9
        int     0x21
        mov     ax, [count0]
        call    hex16
        call    crlf
        mov     dx, msg_rx
        mov     ah, 9
        int     0x21
        mov     ax, [count + 2]
        call    hex16
        mov     ax, [count]
        call    hex16
        call    crlf
        ; DEBUG: what the ISR saw for slot 0 (BIOS scratch 0040:00F0/F2/F4)
        mov     ax, 0x40
        mov     es, ax
        mov     dx, msg_iseg
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xF0]
        call    hex16
        call    crlf
        mov     dx, msg_ityp
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xF2]
        call    hex16
        call    crlf
        mov     dx, msg_itab
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xF4]
        call    hex16
        call    crlf
        mov     dx, msg_fes             ; F_ES as access_type saw it
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xF6]
        call    hex16
        call    crlf
        mov     dx, msg_aslot           ; the slot access_type wrote
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xF8]
        call    hex16
        call    crlf
        mov     dx, msg_ics             ; ISR's CS (IRQ-vector segment)
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xFA]
        call    hex16
        call    crlf
        mov     dx, msg_acs             ; access_type's CS (INT 60h-vector segment)
        mov     ah, 9
        int     0x21
        mov     ax, [es:0xFC]
        call    hex16
        call    crlf
        ; release the handle (fn 3)
        mov     ah, 3
        mov     bx, [handle]
        int     0x60
        ret

; packet-driver receiver upcall (FAR). The driver far-calls it twice per frame:
;   AX=0: request buffer -> return ES:DI = rxbuf (CX = incoming length). 0:0 would drop.
;   AX=1: the frame has been copied into that buffer -> count it.
; The spec lets the handler destroy AX-DX/SI/DI/DS/ES, so no save/restore needed.
receiver:
        or      ax, ax
        jnz     .deliv
        inc     word [cs:count0]        ; AX=0: buffer requested (proves the handle matched)
        push    cs
        pop     es
        mov     di, rxbuf               ; ES:DI = our receive buffer
        retf
.deliv:
        inc     word [cs:count]         ; AX=1: frame delivered
        adc     word [cs:count + 2], 0
        retf

hex16:  push    ax
        mov     al, ah
        call    hex8
        pop     ax
        call    hex8
        ret
hex8:   push    ax
        mov     cl, 4
        shr     al, cl
        call    hnib
        pop     ax
        call    hnib
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

sig         db 'PKT DRVR'
msg_none    db 'no packet driver', 13, 10, '$'
msg_rx      db 'RXFRAMES=', '$'
msg_hnd     db 'HANDLE=', '$'
msg_req     db 'REQ=', '$'
msg_iseg    db 'ISRSEG=', '$'
msg_ityp    db 'ISRTYP=', '$'
msg_itab    db 'ISRTAB=', '$'
msg_fes     db 'ATFES=', '$'
msg_aslot   db 'ATSLOT=', '$'
msg_ics     db 'ISRCS=', '$'
msg_acs     db 'ACCS=', '$'
msg_pk1     db 'PEEK1=', '$'
msg_pk2     db 'PEEK2=', '$'
peek1       dw 0
peek2       dw 0
h60seg      dw 0
msg_h60     db 'H60SEG=', '$'
nl          db 13, 10, '$'
cur_int     db 0
handle      dw 0
start_tick  dw 0
count       dw 0, 0
count0      dw 0
rxbuf       times RXBUFSZ db 0
