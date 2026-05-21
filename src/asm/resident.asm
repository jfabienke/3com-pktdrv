; resident.asm -- Crynwr Packet Driver INT 60h handler (RESIDENT; %included by start.asm).
;
; Faithfully follows the Crynwr skeleton (Nestor head.asm): the "PKT DRVR" signature at
; offset 3, a full register save into a bp-frame, dispatch through a function table, and the
; carry/error return done by editing the FLAGS image on the stack (so IRET restores the
; handler's CF/DH to the caller). Functions are reached with the caller's registers and
; return values by writing the bp-frame. Runs with DS=CS (single-segment tiny model).
;
; Datapath: send_pkt near-calls the JIT-emitted TX at resident_image+g_off[FRAG_TX_PIO].
; RX delivery (the ISR receiver upcall) is the next milestone (needs real 3c509 hardware).

PKTINT          equ 0x60        ; the packet-driver interrupt we install on

; --- bp-frame offsets (after push ax,bx,cx,dx,si,di,bp,ds,es; mov bp,sp) ---
F_ES   equ 0
F_DS   equ 2
F_BP   equ 4
F_DI   equ 6
F_SI   equ 8
F_DX   equ 10
F_DH   equ 11
F_CX   equ 12
F_CL   equ 12
F_CH   equ 13
F_BX   equ 14
F_AX   equ 16
F_AL   equ 16
F_AH   equ 17
F_FLAGS equ 22
CY     equ 0x0001

; --- Crynwr API constants ---
PD_VERSION      equ 0x000B      ; packet driver spec 1.11 -> 11
PD_CLASS_ETHER  equ 1           ; DIX/Ethernet
PD_TYPE_3C509   equ 0x0009      ; interface type (3Com EtherLink III)
PD_FUNC_BASIC   equ 1           ; basic functionality
PD_ERR_BADCMD   equ 11          ; bad command
PD_NFUNCS       equ 7           ; highest function number handled (1..7)

;------------------------------------------------------------------------------
pkt_handler:
        jmp     short pkt_disp
        nop
        db      'PKT DRVR'              ; signature -- exactly at offset 3
pkt_disp:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        cld
        push    cs
        pop     ds                      ; DS = our segment
        mov     bp, sp
        and     word [bp + F_FLAGS], 0xFFFE   ; default success: clear caller's CY

        mov     bl, [bp + F_AH]         ; function number
        xor     bh, bh
        cmp     bx, PD_NFUNCS
        ja      pkt_bad
        add     bx, bx                  ; *2 -> word index
        call    [pkt_functions + bx]    ; DS=CS
        jc      pkt_error
pkt_return:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret
pkt_error:
        mov     bp, sp
        mov     [bp + F_DH], dh         ; return error code in DH
        or      word [bp + F_FLAGS], CY ; set caller's CY
        jmp     short pkt_return
pkt_bad:
        mov     dh, PD_ERR_BADCMD
        jmp     short pkt_error

pkt_functions:
        dw      f_bad                   ; 0 (unused)
        dw      f_driver_info           ; 1
        dw      f_access_type           ; 2
        dw      f_release_type          ; 3
        dw      f_send_pkt              ; 4
        dw      f_bad                   ; 5 terminate (not yet)
        dw      f_get_address           ; 6
        dw      f_reset                 ; 7

;--- 1: driver_info -- version/class/type/number/name/functionality (via bp-frame) ---
f_driver_info:
        mov     word [bp + F_BX], PD_VERSION
        mov     byte [bp + F_CH], PD_CLASS_ETHER
        mov     byte [bp + F_CL], 0             ; interface number 0
        mov     word [bp + F_DX], PD_TYPE_3C509
        mov     ax, cs
        mov     [bp + F_DS], ax                ; return DS:SI -> name
        mov     word [bp + F_SI], pkt_name
        mov     byte [bp + F_AL], PD_FUNC_BASIC
        clc
        ret

;--- 2: access_type -- register the receiver (ES:DI), return a handle ---
f_access_type:
        mov     ax, [bp + F_ES]
        mov     [g_recv_seg], ax
        mov     ax, [bp + F_DI]
        mov     [g_recv_off], ax
        mov     word [bp + F_AX], 1            ; handle = 1
        clc
        ret

;--- 3: release_type -- drop the receiver ---
f_release_type:
        xor     ax, ax
        mov     [g_recv_seg], ax
        mov     [g_recv_off], ax
        clc
        ret

;--- 4: send_pkt -- DS:SI = packet, CX = length; near-call the emitted TX datapath ---
f_send_pkt:
        mov     cx, [bp + F_CX]               ; length
        mov     si, [bp + F_SI]               ; caller's SI
        mov     ax, [g_off + FRAG_TX_PIO * 2] ; emitted TX offset within resident_image
        add     ax, resident_image            ; -> absolute offset in our segment
        mov     ds, [bp + F_DS]               ; DS = caller's (the packet segment)
        call    ax                            ; CS = our segment; runs emitted tx_pio
        push    cs
        pop     ds                            ; restore our DS
        clc
        ret

;--- 6: get_address -- copy our MAC to the caller's ES:DI, return CX = length ---
f_get_address:
        mov     si, g_mac
        mov     cx, 6
        rep     movsb                         ; DS:SI (g_mac) -> ES:DI (caller, ES/DI live)
        mov     word [bp + F_CX], 6
        clc
        ret

;--- 7: reset_interface -- floor: nothing to do ---
f_reset:
        clc
        ret

f_bad:
        mov     dh, PD_ERR_BADCMD
        stc
        ret

pkt_name        db '3com-pktdrv', 0
