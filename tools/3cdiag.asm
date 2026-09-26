; 3cdiag.com -- field diagnostic for a loaded 3cpd (DOS .COM, nasm -f bin). Run it after a network program
; failed (e.g. mTCP DHCP "no packets were seen"): it reads the resident driver's counters and the card's own
; registers, so link, MAC-level TX/RX, the interrupt path and the PIC can be told apart.
;
;   DRV   the driver's counters (via the INT 60h vector; offsets of this 3cpd build, checked against the
;         driver's own I/O base): frames delivered/sent, RX errors/drops, IRQs serviced, TX underruns ...
;   CARD  status register (+ current window)
;   W4    media status (link beat detected = the cable and link partner are seen), net diagnostics
;   W3    InternalConfig (transceiver select), reset options (available media), MAC control
;   W5    interrupt mask, RX filter, status (indication) mask as programmed
;   W6    the card's hardware statistics (read-to-clear): frames TX OK / RX OK, collisions, overruns
;   W1    RX status (a complete frame waiting = received but not serviced), TX status, TX free
;   PIC   slave/master mask, request and in-service bits (IRQ 8-15 on the slave)
;
; Interrupts are off while the card is switched between windows; Window 1 (the driver's) is restored.
; Build: nasm -f bin tools/3cdiag.asm -o build/3cdiag.com
cpu 8086
bits 16
org 0x100

PKTINT          equ 0x60
; resident offsets in this 3cpd build (default and pnp profiles alike -- see the NASM listing)
OFF_NIC_IO      equ 0x05E6
OFF_W1_BASE     equ 0x05EA
OFF_STAT_RX     equ 0x07DC          ; rx, tx, rxerr, rxdrop, irq, txunderrun, txwait, adapterfail (words)

start:  cld
        mov     dx, m_title
        call    pstr
        ; --- find the driver ---
        mov     ax, 0x3500 | PKTINT
        int     0x21                        ; ES:BX = handler
        mov     di, bx
        add     di, 3
        mov     si, sig
        mov     cx, 8
        repe    cmpsb
        je      .have
        mov     dx, m_nodrv
        call    pstr
        jmp     exit
.have:
        mov     [drvseg], es
        mov     ax, [es:OFF_NIC_IO]
        mov     [io], ax
        mov     ax, [es:OFF_W1_BASE]
        mov     [w1], ax
        ; sanity: a 3cpd of this layout has W1 = io or io+0x10, io in 0x100..0x3F0
        mov     ax, [io]
        cmp     ax, 0x100
        jb      .layout
        cmp     ax, 0x3F0
        ja      .layout
        mov     bx, [w1]
        sub     bx, ax
        cmp     bx, 0x10
        ja      .layout
        jmp     .layout_ok
.layout:
        mov     dx, m_layout
        call    pstr
        jmp     exit
.layout_ok:
        mov     dx, m_drvat
        call    pstr
        mov     ax, [drvseg]
        call    phex16
        mov     dx, m_io
        call    pstr
        mov     ax, [io]
        call    phex16
        mov     dx, m_w1
        call    pstr
        mov     ax, [w1]
        call    phex16
        call    crlf

        ; --- driver counters ---
        mov     dx, m_drv
        call    pstr
        push    ds
        mov     ds, [drvseg]
        mov     si, OFF_STAT_RX
        mov     cx, 8
        mov     di, drvstats
        push    cs
        pop     es
        rep     movsw
        pop     ds
        mov     si, drvnames
        mov     bx, drvstats
        mov     cx, 8
.dl:    call    pname
        mov     ax, [bx]
        call    pdec
        add     bx, 2
        loop    .dl
        call    crlf

        ; --- card registers (IF=0 across the window switches) ---
        cli
        mov     dx, [io]
        add     dx, 0x0E
        in      ax, dx
        mov     [r_status], ax
        mov     ax, 0x0804                  ; Window 4
        out     dx, ax
        mov     bx, 0x0A
        call    rdw
        mov     [r_media], ax
        mov     bx, 0x06
        call    rdw
        mov     [r_netdiag], ax
        mov     ax, 0x0803                  ; Window 3
        call    selw
        mov     bx, 0x00
        call    rdw
        mov     [r_cfg_lo], ax
        mov     bx, 0x02
        call    rdw
        mov     [r_cfg_hi], ax
        mov     bx, 0x08
        call    rdw
        mov     [r_options], ax
        mov     bx, 0x06
        call    rdw
        mov     [r_macctl], ax
        mov     ax, 0x0805                  ; Window 5
        call    selw
        mov     bx, 0x0A
        call    rdw
        mov     [r_intmask], ax
        mov     bx, 0x08
        call    rdw
        mov     [r_rxfilter], ax
        mov     bx, 0x0C
        call    rdw
        mov     [r_statmask], ax
        mov     bx, 0x00
        call    rdw
        mov     [r_txstart], ax
        mov     ax, 0x0806                  ; Window 6: hardware statistics (read-to-clear)
        call    selw
        mov     di, w6
        xor     bx, bx
.w6:    mov     dx, [io]
        add     dx, bx
        in      al, dx
        mov     [di], al
        inc     di
        inc     bx
        cmp     bx, 10
        jb      .w6
        mov     bx, 0x0A
        call    rdw
        mov     [w6_rxbytes], ax
        mov     bx, 0x0C
        call    rdw
        mov     [w6_txbytes], ax
        mov     ax, 0x0801                  ; back to Window 1 (the driver's)
        call    selw
        mov     dx, [w1]
        add     dx, 0x08
        in      ax, dx
        mov     [r_rxstat], ax
        mov     dx, [w1]
        add     dx, 0x0B
        in      al, dx
        mov     [r_txstat], al
        mov     dx, [w1]
        add     dx, 0x0C
        in      ax, dx
        mov     [r_txfree], ax
        ; PIC
        in      al, 0xA1
        mov     [p_simr], al
        mov     al, 0x0A                    ; OCW3: read IRR
        out     0xA0, al
        in      al, 0xA0
        mov     [p_sirr], al
        mov     al, 0x0B                    ; OCW3: read ISR
        out     0xA0, al
        in      al, 0xA0
        mov     [p_sisr], al
        mov     al, 0x0A
        out     0xA0, al                    ; leave the slave reading IRR (BIOS default)
        in      al, 0x21
        mov     [p_mimr], al
        sti

        ; --- report ---
        mov     dx, m_card
        call    pstr
        mov     ax, [r_status]
        call    phex16
        mov     dx, m_win
        call    pstr
        mov     ax, [r_status]
        mov     cl, 13
        shr     ax, cl
        add     al, '0'
        call    pchar
        call    crlf

        mov     dx, m_w4
        call    pstr
        mov     ax, [r_media]
        call    phex16
        mov     dx, m_lbok
        test    word [r_media], 0x0800
        jnz     .lb
        mov     dx, m_lbno
.lb:    call    pstr
        mov     dx, m_netdiag
        call    pstr
        mov     ax, [r_netdiag]
        call    phex16
        call    crlf

        mov     dx, m_w3
        call    pstr
        mov     ax, [r_cfg_hi]
        call    phex16
        mov     ax, [r_cfg_lo]
        call    phex16
        mov     dx, m_xcvr
        call    pstr
        mov     ax, [r_cfg_hi]
        mov     cl, 4
        shr     ax, cl
        and     al, 7
        add     al, '0'
        call    pchar
        mov     dx, m_options
        call    pstr
        mov     ax, [r_options]
        call    phex16
        mov     dx, m_macctl
        call    pstr
        mov     ax, [r_macctl]
        call    phex16
        call    crlf

        mov     dx, m_w5
        call    pstr
        mov     ax, [r_intmask]
        call    phex16
        mov     dx, m_rxfilter
        call    pstr
        mov     ax, [r_rxfilter]
        call    phex16
        mov     dx, m_statmask
        call    pstr
        mov     ax, [r_statmask]
        call    phex16
        mov     dx, m_txstart
        call    pstr
        mov     ax, [r_txstart]
        call    phex16
        call    crlf

        mov     dx, m_w6
        call    pstr
        mov     si, w6names
        mov     bx, w6order
        mov     cx, 8
.w6p:   call    pname
        push    bx
        mov     bl, [bx]
        xor     bh, bh
        mov     al, [w6 + bx]
        xor     ah, ah
        call    pdec
        pop     bx
        inc     bx
        loop    .w6p
        mov     dx, m_bytes
        call    pstr
        mov     ax, [w6_rxbytes]
        call    pdec
        mov     dx, m_slash
        call    pstr
        mov     ax, [w6_txbytes]
        call    pdec
        call    crlf

        mov     dx, m_w1r
        call    pstr
        mov     ax, [r_rxstat]
        call    phex16
        mov     dx, m_txstat
        call    pstr
        mov     al, [r_txstat]
        xor     ah, ah
        call    phex16
        mov     dx, m_txfree
        call    pstr
        mov     ax, [r_txfree]
        call    phex16
        call    crlf

        mov     dx, m_pic
        call    pstr
        mov     al, [p_simr]
        call    phex8
        mov     dx, m_irr
        call    pstr
        mov     al, [p_sirr]
        call    phex8
        mov     dx, m_isr
        call    pstr
        mov     al, [p_sisr]
        call    phex8
        mov     dx, m_mimr
        call    pstr
        mov     al, [p_mimr]
        call    phex8
        call    crlf
exit:
        mov     ax, 0x4C00
        int     0x21

; selw: AX = SelectWindow command -> command register. Clobbers DX.
selw:   mov     dx, [io]
        add     dx, 0x0E
        out     dx, ax
        ret
; rdw: AX = word at [io + BX]. Clobbers DX.
rdw:    mov     dx, [io]
        add     dx, bx
        in      ax, dx
        ret

; pname: print the next '$'-terminated name at SI, advance SI past it
pname:  push    ax
        push    dx
        mov     dx, si
        call    pstr
.n:     lodsb
        cmp     al, '$'
        jne     .n
        pop     dx
        pop     ax
        ret
pstr:   push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret
crlf:   push    dx
        mov     dx, m_crlf
        call    pstr
        pop     dx
        ret
pchar:  push    ax
        push    dx
        mov     dl, al
        mov     ah, 2
        int     0x21
        pop     dx
        pop     ax
        ret
phex16: push    ax
        mov     al, ah
        call    phex8
        pop     ax
phex8:  push    ax
        push    cx
        mov     cl, 4
        push    ax
        shr     al, cl
        call    .nib
        pop     ax
        call    .nib
        pop     cx
        pop     ax
        ret
.nib:   and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .o
        add     al, 7
.o:     jmp     pchar
; pdec: AX unsigned decimal
pdec:   push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d:     xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d
.p:     pop     ax
        add     al, '0'
        call    pchar
        loop    .p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

sig         db 'PKT DRVR'
m_title     db '3CDIAG -- 3cpd + card state', 13, 10, '$'
m_nodrv     db 'No packet driver at INT 60h: load 3cpd first', 13, 10, '$'
m_layout    db 'The INT 60h driver is not this 3cpd build (layout mismatch)', 13, 10, '$'
m_drvat     db 'driver seg ', '$'
m_io        db '  I/O ', '$'
m_w1        db '  W1 ', '$'
m_drv       db 'DRV', '$'
drvnames    db ' rx=$', ' tx=$', ' rxerr=$', ' rxdrop=$', ' irq=$', ' txunder=$', ' txwait=$', ' adfail=$'
m_card      db 'CARD status=', '$'
m_win       db ' window=', '$'
m_w4        db 'W4 media=', '$'
m_lbok      db ' (link beat DETECTED)', '$'
m_lbno      db ' (NO link beat)', '$'
m_netdiag   db ' netdiag=', '$'
m_w3        db 'W3 config=', '$'
m_xcvr      db ' xcvr=', '$'
m_options   db ' options=', '$'
m_macctl    db ' macctl=', '$'
m_w5        db 'W5 intmask=', '$'
m_rxfilter  db ' rxfilter=', '$'
m_statmask  db ' statmask=', '$'
m_txstart   db ' txstart=', '$'
m_w6        db 'W6', '$'
w6names     db ' txok=$', ' rxok=$', ' carrier=$', ' sqe=$', ' coll1=$', ' collN=$', ' late=$', ' overrun=$'
w6order     db 6, 7, 0, 1, 3, 2, 4, 5
m_bytes     db ' bytes rx/tx=', '$'
m_slash     db '/', '$'
m_w1r       db 'W1 rxstatus=', '$'
m_txstat    db ' txstatus=', '$'
m_txfree    db ' txfree=', '$'
m_pic       db 'PIC slave IMR=', '$'
m_irr       db ' IRR=', '$'
m_isr       db ' ISR=', '$'
m_mimr      db '  master IMR=', '$'
m_crlf      db 13, 10, '$'

drvseg      dw 0
io          dw 0
w1          dw 0
drvstats    times 8 dw 0
r_status    dw 0
r_media     dw 0
r_netdiag   dw 0
r_cfg_lo    dw 0
r_cfg_hi    dw 0
r_options   dw 0
r_macctl    dw 0
r_intmask   dw 0
r_rxfilter  dw 0
r_statmask  dw 0
r_txstart   dw 0
r_rxstat    dw 0
r_txfree    dw 0
r_txstat    db 0
w6          times 10 db 0
w6_rxbytes  dw 0
w6_txbytes  dw 0
p_simr      db 0
p_sirr      db 0
p_sisr      db 0
p_mimr      db 0
