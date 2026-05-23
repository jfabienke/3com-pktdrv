; blast.asm -- packet-driver TX throughput probe (DOS .COM, nasm -f bin).
;
; Sends a fixed max-size Ethernet frame via the packet driver (INT 60h send_pkt) in a tight
; loop for a fixed BIOS-tick window, then prints the frame count. There is no TCP and no
; remote peer, so the measurement is immune to the icount-vs-real-server ACK distortion that
; makes TCP throughput unreliable under -icount. Paced only by the driver's TxFree guard
; (i.e. the realtiming wire-rate drain), so frames/window reflects min(wire rate, CPU PIO feed).
;
; Output: "FRAMES=XXXXXXXX LEN=05EA" (32-bit hex count, frame length). The host harness turns
; that into kbit/s: frames * LEN * 8 / window_seconds.
;
; Build: nasm -f bin tools/blast.asm -o build/blast.com
cpu 8086
bits 16
org 0x100

DURATION  equ 54        ; BIOS ticks ~= 3 s at 18.2 Hz (virtual time under -icount)
FRAMELEN  equ 1514       ; full-size Ethernet frame (14 hdr + 1500)

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
        ; --- register a handle (access_type, fn 2). 3Com's own driver requires a handle before
        ; get_address/send; Crynwr tolerates its absence. Match all Ethernet types (CX=0) and
        ; point the receiver upcall at a drop stub (TX-only tool). ---
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
.noacc:
        ; --- fill the source MAC (get_address, fn 6, with the handle) ---
        push    cs
        pop     es
        mov     di, frame + 6
        mov     cx, 6
        mov     bx, [handle]
        mov     ah, 6
        int     0x60

        ; --- start tick (BIOS 0040:006C low word; no wrap in ~3 s) ---
        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x6C]
        mov     [start_tick], ax

.blast:
        mov     ax, 0x40
        mov     es, ax
        mov     ax, [es:0x6C]
        sub     ax, [start_tick]
        cmp     ax, DURATION
        jae     .done
        mov     si, frame
        mov     cx, FRAMELEN
        mov     ah, 4                   ; send_pkt: DS:SI = frame, CX = length
        int     0x60
        add     word [count], 1
        adc     word [count + 2], 0
        jmp     .blast

.done:
        mov     dx, msg_frames
        mov     ah, 9
        int     0x21
        mov     ax, [count + 2]
        call    hex16
        mov     ax, [count]
        call    hex16
        mov     dx, msg_len
        mov     ah, 9
        int     0x21
        mov     ax, FRAMELEN
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

; packet-driver receiver upcall (FAR). AX=0: request buffer -> return ES:DI=0:0 to drop the
; packet (this is a TX-only probe). AX=1: packet delivered (nothing to do). Driver far-calls it.
receiver:
        xor     ax, ax
        mov     es, ax
        mov     di, ax                  ; ES:DI = 0:0 -> driver discards inbound packets
        retf

sig         db 'PKT DRVR'
msg_none    db 'no packet driver', 13, 10, '$'
msg_frames  db 'FRAMES=', '$'
msg_len     db ' LEN=', '$'
nl          db 13, 10, '$'
cur_int     db 0
handle      dw 0
start_tick  dw 0
count       dw 0, 0
frame:      times 6 db 0xFF             ; dst = broadcast
            times 6 db 0x00            ; src  (filled by get_address)
            db 0x08, 0x00              ; ethertype IPv4
            times FRAMELEN - 14 db 0   ; payload
