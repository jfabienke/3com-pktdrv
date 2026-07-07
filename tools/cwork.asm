; cwork.asm -- Parallel Tasking CONCURRENCY probe (DOS .COM, nasm -f bin).
;
; Floods frames via the packet driver AND runs a fixed CPU "work" loop, counting how many
; work-units complete in a fixed BIOS-tick (virtual-time) window. The point: a SYNCHRONOUS driver
; blocks the caller inside send_pkt (busy-waiting on TxFree) so few work-units finish; 3Com's
; ASYNC driver queues + returns, so the wire time runs in the ISR and the foreground keeps
; completing work-units. WORK/FRAMES is the concurrency factor (sync ~1, async >> 1).
;
; Output: "FRAMES=XXXXXXXX WORK=XXXXXXXX". Same window/driver for all three drivers -> compare WORK.
; Build: nasm -f bin tools/cwork.asm -o build/cwork.com
cpu 8086
bits 16
org 0x100

DURATION  equ 9          ; BIOS ticks ~= 0.5 s virtual (the async flood is wall-slow)
FRAMELEN  equ 1514
WORKLEN   equ 200        ; iterations per work-unit (fixed CPU cost per unit)

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
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     ah, 2                   ; access_type: register a handle + drop-receiver
        mov     al, 1
        mov     bx, 0xFFFF
        mov     dl, 0
        xor     si, si
        xor     cx, cx
        mov     di, receiver
        int     0x60
        jc      .noacc
        mov     [handle], ax
.noacc:
        push    cs
        pop     es
        mov     di, frame + 6
        mov     cx, 6
        mov     bx, [handle]
        mov     ah, 6                   ; get_address -> src MAC
        int     0x60

        push    cs
        pop     ds                      ; DS = CS for frame + counters + scratch

        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x6C]
        mov     [start_tick], ax

.loop:
        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x6C]
        sub     ax, [start_tick]
        cmp     ax, DURATION
        jae     .done

        ; --- attempt one send (count only successful sends) ---
        mov     si, frame
        mov     cx, FRAMELEN
        mov     bx, [handle]
        mov     ah, 4
        int     0x60
        jc      .work                   ; CF = couldn't send (async queue full) -> just do work
        add     word [frames], 1
        adc     word [frames + 2], 0

        ; --- one fixed work-unit (foreground CPU the app would spend on real work) ---
.work:
        mov     cx, WORKLEN
.wloop:
        add     word [scratch], 3       ; trivial, fixed-cost compute touching memory
        loop    .wloop
        add     word [work], 1
        adc     word [work + 2], 0
        jmp     .loop

.done:
        mov     dx, msg_frames
        mov     ah, 9
        int     0x21
        mov     ax, [frames + 2]
        call    hex16
        mov     ax, [frames]
        call    hex16
        mov     dx, msg_work
        mov     ah, 9
        int     0x21
        mov     ax, [work + 2]
        call    hex16
        mov     ax, [work]
        call    hex16
        call    crlf
        ret

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

receiver:
        xor     ax, ax
        mov     es, ax
        mov     di, ax
        retf

sig         db 'PKT DRVR'
msg_none    db 'no packet driver', 13, 10, '$'
msg_frames  db 'FRAMES=', '$'
msg_work    db ' WORK=', '$'
nl          db 13, 10, '$'
cur_int     db 0
handle      dw 0
start_tick  dw 0
frames      dw 0, 0
work        dw 0, 0
scratch     dw 0
frame:      times 6 db 0xFF
            times 6 db 0x00
            db 0x08, 0x00
            times FRAMELEN - 14 db 0
