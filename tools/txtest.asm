; txtest.asm -- raw-frame harness for the Phase 8b.2a TX_CONFIGURE/TX_SUBMIT path (DOS .COM).
;
; Finds the resident packet driver, QUERYs caps (expects XMS_CAP_XMS_TX), registers a conventional
; TX pool via TX_CONFIGURE, then exercises TX_SUBMIT: a valid broadcast frame (with a magic payload
; so the runner can confirm on the wire that the card DMA'd from the submitted phys), an out-of-pool
; submit (expects DH=XMS_ERR_TX_RANGE), and an oversized submit (expects DH=XMS_ERR_SLOT_SIZE).
; Needs g_use_dma=1 -> run under QEMU with a 3C515 (el3); the driver must be loaded /5 /d.
;   nasm -f bin tools/txtest.asm -o build/txtest.com
cpu 8086
bits 16
org 0x100

POOLSZ      equ 2048

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
        jmp     .die
.found:
        mov     [pkt_off], bx
        mov     [pkt_seg], es

        ; --- QUERY caps ---
        mov     ah, 0xF0
        mov     al, 0x00
        pushf
        call far [pkt_off]
        pushf
        pop     ax
        mov     [t_fl], al                  ; CF
        mov     [q_caps], bx                ; BX = caps (valid only if CF=0)
        mov     dx, msg_caps
        call    pstr
        mov     ax, [q_caps]
        call    phex16
        ; XMSTX present?  (bit 0x0080)
        mov     dx, msg_xmstx
        call    pstr
        mov     ax, [q_caps]
        and     ax, 0x0080
        jz      .xmstx0
        mov     al, '1'
        jmp     .xmstxp
.xmstx0:
        mov     al, '0'
.xmstxp:
        call    pchar
        call    pcrlf

        ; --- compute phys(pool) -> [pool_phys] (dx:ax) ---
        mov     bx, cs
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl
        add     ax, pool
        adc     dx, 0                        ; dx:ax = phys(pool)
        mov     [pool_phys], ax
        mov     [pool_phys + 2], dx

        ; --- build xms_tx_cfg_t: version=1, flags=0, rsv=0, pool_phys, pool_len ---
        mov     byte [txcfg + 0], 1         ; version
        mov     byte [txcfg + 1], 0         ; flags
        mov     word [txcfg + 2], 0         ; rsv
        mov     ax, [pool_phys]
        mov     [txcfg + 4], ax
        mov     ax, [pool_phys + 2]
        mov     [txcfg + 6], ax
        mov     word [txcfg + 8], POOLSZ
        mov     word [txcfg + 10], 0

        ; --- TX_CONFIGURE (AL=0x04, ES:DI -> txcfg) ---
        push    cs
        pop     es
        mov     di, txcfg
        mov     ah, 0xF0
        mov     al, 0x04
        pushf
        call far [pkt_off]
        call    report                      ; prints " CFG CF=x DH=xx" using msg slot
        mov     dx, msg_cfg
        call    plabel

        ; --- build a broadcast frame in pool: dst=FF*6, src, type=0x88B5, payload "TXOKtxok..." ---
        mov     di, pool
        mov     cx, 6
        mov     al, 0xFF
        rep     stosb                       ; dst broadcast
        mov     si, srcmac
        mov     cx, 6
        rep     movsb                       ; src
        mov     byte [pool + 12], 0x88      ; ethertype 0x88B5 (experimental)
        mov     byte [pool + 13], 0xB5
        mov     si, magic
        mov     di, pool + 14
        mov     cx, magiclen
        rep     movsb                       ; magic payload right after the header

        ; --- TX_SUBMIT valid: DX:CX = phys(pool), BX = 64 ---
        mov     cx, [pool_phys]
        mov     dx, [pool_phys + 2]
        mov     bx, 64
        mov     ah, 0xF0
        mov     al, 0x05
        pushf
        call far [pkt_off]
        call    report
        mov     dx, msg_sub
        call    plabel

        ; --- TX_SUBMIT out-of-pool: DX:CX = pool_phys + POOLSZ, BX = 64 (frame_end past pool) ---
        mov     ax, [pool_phys]
        add     ax, POOLSZ
        mov     cx, ax
        mov     ax, [pool_phys + 2]
        adc     ax, 0
        mov     dx, ax
        mov     bx, 64
        mov     ah, 0xF0
        mov     al, 0x05
        pushf
        call far [pkt_off]
        call    report
        mov     dx, msg_oor
        call    plabel

        ; --- TX_SUBMIT oversized: DX:CX = phys(pool), BX = 2000 (> std max frame) ---
        mov     cx, [pool_phys]
        mov     dx, [pool_phys + 2]
        mov     bx, 2000
        mov     ah, 0xF0
        mov     al, 0x05
        pushf
        call far [pkt_off]
        call    report
        mov     dx, msg_big
        call    plabel

        mov     dx, msg_done
        call    pstr
        ret
.die:
        call    pstr
        ret

;--- report: capture CF + DH from the just-returned call into t_fl/t_dh (call immediately after) ---
report:
        pushf
        pop     ax
        mov     [t_fl], al
        mov     [t_dh], dh
        ret

;--- plabel: DX -> label "$"; prints "<label> CF=<c> DH=<dh>\r\n" from t_fl/t_dh ---
plabel:
        call    pstr                        ; the label
        mov     dx, msg_cf
        call    pstr
        mov     al, [t_fl]
        and     al, 1
        call    phex8
        mov     dx, msg_dh
        call    pstr
        mov     al, [t_dh]
        call    phex8
        call    pcrlf
        ret

;--- helpers ---
pstr:   mov     ah, 9
        int     0x21
        ret
pchar:  mov     dl, al
        mov     ah, 2
        int     0x21
        ret
pcrlf:  mov     dx, crlf
        jmp     pstr
phex16:                                     ; AX -> 4 hex digits
        push    ax
        mov     al, ah
        call    phex8
        pop     ax
        call    phex8
        ret
phex8:                                      ; AL -> 2 hex digits
        push    ax
        mov     cl, 4
        shr     al, cl
        call    pnib
        pop     ax
        call    pnib
        ret
pnib:   and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .e
        add     al, 7
.e:     mov     dl, al
        mov     ah, 2
        int     0x21
        ret

sig        db 'PKT DRVR'
srcmac     db 0x02, 0x60, 0x8C, 0x77, 0x88, 0x99
magic      db 'TXOKtxtest-8b2a-magic'
magiclen   equ $ - magic
msg_none   db 'No packet driver found', 13, 10, '$'
msg_caps   db 'CAPS=0x', '$'
msg_xmstx  db ' XMSTX=', '$'
msg_cfg    db 'CFG', '$'
msg_sub    db 'SUB(valid)', '$'
msg_oor    db 'OOR(expect DH=09)', '$'
msg_big    db 'BIG(expect DH=04)', '$'
msg_cf     db ' CF=', '$'
msg_dh     db ' DH=', '$'
msg_done   db 'TXTEST-DONE', 13, 10, '$'
crlf       db 13, 10, '$'
cur_int    db 0
pkt_off    dw 0
pkt_seg    dw 0
q_caps     dw 0
t_fl       db 0
t_dh       db 0
pool_phys  dd 0
txcfg      times 12 db 0
                align 16
pool       times POOLSZ db 0
