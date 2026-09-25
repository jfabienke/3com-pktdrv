; resident.asm -- Crynwr Packet Driver INT 60h handler (RESIDENT; %included by start.asm).
;
; Follows the Crynwr skeleton (Nestor head.asm): "PKT DRVR" signature at offset 3, full
; register save into a bp-frame, table dispatch, and carry/error return via the stacked
; FLAGS. Functions reached with the caller's registers; return values written to the frame.
; Runs with DS=CS (single-segment tiny model). send_pkt near-calls the JIT-emitted TX.
;
; Instrumentation: send_pkt bumps stat_tx and (CFG_DEBUG) logs an event; get_statistics
; (fn 24) exposes the counters; a vendor fn (0x7F, CFG_DEBUG) hands out the debug block.

%include "el3_core.inc"         ; EL3 command/status constants (guarded; also used by isr.asm)
%include "el3_corkscrew.inc"    ; 3C515 DMA registers + descriptor constants (guarded)
%include "xms_dma.inc"          ; XMS DMA extension constants (guarded)
%include "async_tx.inc"         ; async zero-copy TX extension constants (AH=0xF1)

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
PD_FUNC_EXT     equ 2           ; basic + extended (we provide get_statistics)
PD_ERR_BADHANDLE equ 1          ; bad handle
PD_ERR_NOSPACE  equ 10         ; no free handle
PD_ERR_BADCMD   equ 11          ; bad command
PD_ERR_CANTSEND equ 12          ; cannot send (async ring full -> caller throttles + retries)
PD_NFUNCS       equ 7           ; functions 1..7 handled via the table
PD_GET_STATS    equ 24          ; get_statistics
PD_DBG_BLOCK    equ 0x7F        ; vendor: return the debug block pointer (CFG_DEBUG)
PD_UNINSTALL    equ 0x82        ; vendor: tear down (restore vectors, mask IRQ) -> BX = PSP

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
        and     word [bp + F_FLAGS], 0xFFFE   ; default success: clear caller CY

        mov     al, [bp + F_AH]
        cmp     al, PD_GET_STATS
        je      pkt_do_stats
        cmp     al, PD_UNINSTALL
        je      pkt_do_uninstall
%ifdef CFG_DEBUG
        cmp     al, PD_DBG_BLOCK
        je      pkt_do_dbg
%endif
        cmp     al, XMS_DMA_FUNC        ; proprietary XMS DMA extension (AH=0xF0)
        je      pkt_do_xms
        cmp     al, ASYNC_TX_FUNC       ; proprietary async zero-copy TX extension (AH=0xF1)
        je      pkt_do_async
        cmp     al, RX_CKSUM_FUNC       ; proprietary RX checksum-offload extension (AH=0xF2)
        je      pkt_do_rx_cksum
        cmp     al, PD_NFUNCS
        ja      pkt_bad
        mov     bl, al
        xor     bh, bh
        add     bx, bx                  ; *2 -> word index
        call    [pkt_functions + bx]
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
pkt_do_stats:
        call    f_get_statistics
        jmp     pkt_return
pkt_do_uninstall:
        call    f_uninstall
        jmp     pkt_return
%ifdef CFG_DEBUG
pkt_do_dbg:
        call    f_dbg
        jmp     pkt_return
%endif
pkt_do_xms:
        ; The whole extension exists only while the bus-master path is live: on the PIO floor install keeps
        ; only up to resident_end_pio, so xms_dma_armed / xms_rx_descs / xms_gdt are freed memory (and a
        ; 3C509 has no UpList registers at io+0x38..0x3C). One gate covers QUERY/CONFIGURE/RELEASE/POLL.
        cmp     byte [g_use_dma], 0
        je      .xbad
        mov     al, [bp + F_AL]         ; sub-function in AL
        cmp     al, XMS_DMA_QUERY
        je      .xq
        cmp     al, XMS_DMA_CONFIGURE
        je      .xc
        cmp     al, XMS_DMA_RELEASE
        je      .xr
        cmp     al, XMS_DMA_POLL
        je      .xp
.xbad:  mov     dh, PD_ERR_BADCMD
        stc
        jmp     pkt_error
.xq:    call    f_xms_query
        jmp     pkt_xms_ret
.xc:    call    f_xms_configure
        jmp     pkt_xms_ret
.xr:    call    f_xms_release
        jmp     pkt_xms_ret
.xp:    call    f_xms_poll
        jmp     pkt_xms_ret
pkt_xms_ret:
        jc      pkt_error
        jmp     pkt_return

;--- AH=0xF1: async zero-copy TX extension. AL sub-function in F_AL. See include/async_tx.inc. ---
pkt_do_async:
        mov     al, [bp + F_AL]                 ; sub-function
        cmp     al, ASYNC_SEND
        je      .a_send
        cmp     al, ASYNC_INFO
        je      .a_info
        mov     dh, PD_ERR_BADCMD
        jmp     pkt_error
.a_info:
        ; async TX exists only on the 386+ non-blocking DMA ring; else CF=1 -> caller uses send_pkt
        cmp     byte [g_async], 0      ; zero-copy async ring available? (any bus-master config, >=286)
        je      .a_unsup
        mov     word [bp + F_AX], TX_RING_N             ; pool depth the stack should allocate
        mov     word [bp + F_BX], ASYNC_FEAT_ZEROCOPY
        ; DX:CX -> resident tx_completed counter (general regs: reliably returned via int86x out_regs)
        mov     word [bp + F_CX], tx_completed         ; counter offset
        mov     ax, cs
        mov     word [bp + F_DX], ax                   ; counter segment (resident CS)
        jmp     pkt_return                             ; CF=0 (cleared at entry)
.a_send:
        cmp     byte [g_async], 0      ; zero-copy async ring available? (any bus-master config, >=286)
        je      .a_unsup
        call    tx_len_ok               ; 1..EL3_MAX_FRAME, else CANT_SEND
        jc      .a_err
        call    dma_tx_async                          ; F_DS:F_SI = frame, F_CX = len; CF=1 if ring full
        jc      .a_full
        jmp     pkt_return                            ; CF=0 queued
.a_full:
        mov     dh, PD_ERR_CANTSEND
.a_err: jmp     pkt_error                             ; CF=1 -> caller throttles on tx_completed, retries
.a_unsup:
        mov     dh, PD_ERR_BADCMD
        jmp     pkt_error                             ; CF=1 -> caller falls back to send_pkt

;--- AH=0xF2: RX checksum-offload extension. AL sub-function in F_AL. See include/rx_cksum.inc. ---
pkt_do_rx_cksum:
        mov     al, [bp + F_AL]                 ; sub-function
        cmp     al, RX_CKSUM_QUERY
        je      .rc_query
        cmp     al, RX_CKSUM_ENABLE
        je      .rc_enable
        cmp     al, RX_CKSUM_DISABLE
        je      .rc_disable
        mov     dh, PD_ERR_BADCMD
        jmp     pkt_error
.rc_query:
        mov     word [bp + F_AX], 1                    ; supported
        mov     word [bp + F_BX], RXCK_FEAT_IPSUM      ; feature: DX=folded sum over IP+TCP+payload
        jmp     pkt_return                             ; CF=0 (cleared at entry)
.rc_enable:
        mov     byte [g_rx_cksum], 1                   ; ISR now sums frames during the PIO drain
        jmp     pkt_return
.rc_disable:
        mov     byte [g_rx_cksum], 0
        jmp     pkt_return
pkt_error:
        mov     bp, sp
        mov     [bp + F_DH], dh         ; return error code in DH
        or      word [bp + F_FLAGS], CY ; set caller CY
        jmp     pkt_return
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

;--- 1: driver_info ---
f_driver_info:
        mov     word [bp + F_BX], PD_VERSION
        mov     byte [bp + F_CH], PD_CLASS_ETHER
        mov     byte [bp + F_CL], 0             ; interface number 0
        mov     word [bp + F_DX], PD_TYPE_3C509
        mov     ax, cs
        mov     [bp + F_DS], ax                ; DS:SI -> name
        mov     word [bp + F_SI], pkt_name
        mov     byte [bp + F_AL], PD_FUNC_EXT
        clc
        ret

;--- 2: access_type -- register a receiver (ES:DI) for a type, return a handle ---
; In: AL=if_class, BX=if_type, DL=if_number, DS:SI -> type template, CX = type length,
;     ES:DI = receiver upcall. We demux on the 2-byte EtherType only (CX>=2 -> match
;     SI[0..1]; CX==0 -> match all). The handle returned is the slot offset in htable.
f_access_type:
        mov     di, htable
        mov     cx, MAX_HANDLES
.at_find:
        cmp     word [di + 2], 0              ; recv_seg == 0 -> free slot
        je      .at_got
        add     di, HANDLE_SIZE
        loop    .at_find
        mov     dh, PD_ERR_NOSPACE           ; handle table full
        stc
        ret
.at_got:
        mov     ax, [bp + F_DI]
        mov     [di + 0], ax                 ; recv_off
        mov     ax, [bp + F_ES]
        mov     [di + 2], ax                 ; recv_seg (claims the slot)
        mov     cx, [bp + F_CX]              ; caller's type length
        jcxz    .at_all
        mov     bx, [bp + F_SI]              ; caller's SI -> type template
        mov     ds, [bp + F_DS]              ; caller's DS (briefly)
        mov     ax, [bx]                     ; the 2 EtherType bytes (wire order)
        push    cs
        pop     ds                           ; restore our DS
        mov     [di + 4], ax
        jmp     .at_done
.at_all:
        mov     word [di + 4], 0             ; type 0 -> match all
.at_done:
        mov     [bp + F_AX], di              ; handle = slot offset
        clc
        ret

;--- 3: release_type -- BX = handle (slot offset); free the slot ---
f_release_type:
        mov     bx, [bp + F_BX]
        cmp     bx, htable
        jb      .rt_bad
        cmp     bx, htable + MAX_HANDLES * HANDLE_SIZE
        jae     .rt_bad
        mov     word [bx + 2], 0             ; recv_seg = 0 -> slot free
        clc
        ret
.rt_bad:
        mov     dh, PD_ERR_BADHANDLE
        stc
        ret

;------------------------------------------------------------------------------
; tx_status_drain -- pop the TX status stack (up to 8 entries); an underrun/jabber entry resets and
; re-enables the transmitter so it isn't left stuck, and an underrun raises the TX start threshold by
; EL3_TX_START_STEP (up to store-and-forward). Bounded -> safe on a floating bus. Called by the ISR while
; servicing TxComplete (every mode: on a real 3C509 only this pop clears TxComplete), and by PIO send_pkt.
; Enter DS=CS. Clobbers AX, CX, DX.
;------------------------------------------------------------------------------
tx_status_drain:
        mov     dx, [g_w1_base]
        add     dx, EL3_W1_TX_STATUS
        mov     cx, 8
.txs:   in      al, dx
        or      al, al
        jz      .done
        test    al, EL3_TXS_RESET_MASK
        jz      .pop
        inc     word [stat_txunderrun]
        test    al, EL3_TXS_UNDERRUN
        jz      .restart                ; jabber: restart at the same threshold
        cmp     word [g_tx_start], EL3_CMD_SET_TX_START | (EL3_TX_THRESH_SF - EL3_TX_START_STEP)
        ja      .restart                ; already store-and-forward
        add     word [g_tx_start], EL3_TX_START_STEP   ; the fill can't stay ahead: start later
.restart:
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_TX_RESET
        out     dx, ax
        mov     ax, EL3_CMD_TX_ENABLE
        out     dx, ax
        mov     ax, [g_tx_start]              ; per-generation TX-start (early vs store-forward)
        out     dx, ax
        pop     dx
.pop:
        xor     al, al
        out     dx, al                  ; pop this entry off the TX status stack
        loop    .txs
.done:
        ret

;------------------------------------------------------------------------------
; tx_len_ok -- validate a TX length before any datapath touches it: 1..EL3_MAX_FRAME (1514), or
; 1..EL3_MAX_FRAME_LARGE (4490) with /j (the TX ring slots are then TX_SLOT_LARGE). Nothing else bounds the
; ring's slot copy, and a zero length builds a zero-length descriptor. (PIO refuses > 1514 separately.) Enter bp -> INT 60h frame.
; out: CF=0 ok; CF=1 + DH = PD_ERR_CANTSEND. Clobbers AX.
;------------------------------------------------------------------------------
tx_len_ok:
        mov     ax, [bp + F_CX]
        or      ax, ax
        jz      .bad
        cmp     byte [g_use_large], 0
        jne     .large
        cmp     ax, EL3_MAX_FRAME
        ja      .bad
        clc
        ret
.large:
        cmp     ax, EL3_MAX_FRAME_LARGE         ; /j: FDDI-sized frames (the TX slots are sized for them)
        ja      .bad
        clc
        ret
.bad:   mov     dh, PD_ERR_CANTSEND
        stc
        ret

;--- 4: send_pkt -- DS:SI = packet, CX = length; near-call the emitted TX datapath ---
f_send_pkt:
        call    tx_len_ok               ; 1..EL3_MAX_FRAME, else CANT_SEND (no datapath is entered)
        jc      .ret
        ; PIO: recover any pending TX error from a prior (early-start) transmission. NOT on the
        ; bus-master path: popping the TX status stack also clears TxComplete, so a DMA completion
        ; that latched while we're in here (IF=0) would be consumed before the ISR retires its ring
        ; slot -> the ring wedges. There the ISR drains the stack when it services TxComplete.
        cmp     byte [g_use_dma], 0
        jne     .txs_done
        call    tx_status_drain
.txs_done:
        inc     word [stat_tx]
        cmp     byte [g_use_dma], 0     ; bus-master DMA TX path (3C515, >=286)?
        je      .tx_pio
        cmp     byte [g_tx_ring], 0     ; 386+ -> non-blocking ring; 286 -> zero-copy single-transfer
        je      .tx_single
        call    dma_tx_enqueue          ; 386+: copy to a ring slot, ISR drains the card (non-blocking)
        clc
        ret
.tx_single:
        call    dma_tx_single           ; 286: zero-copy DMA straight from the caller's buffer (blocking)
        clc
.ret:   ret
.tx_pio:
        ; an FDDI-sized (/j) frame can never fit the ~2 KB TX FIFO (TxFree never reaches len+4): only the
        ; bus-master paths carry it -- refuse it here (a /j 3C515 may run PIO when /d is absent)
        cmp     word [bp + F_CX], EL3_MAX_FRAME
        jbe     .tx_pio_len
        mov     dh, PD_ERR_CANTSEND
        stc
        ret
.tx_pio_len:
        ; --- wait for FIFO room before bursting. With early-start enabled the card may still
        ; be draining a prior frame; a fast 286+ doing `rep outsw` can outrun a 2 KB FIFO
        ; (an 8088 loop never does). Require TxFree >= length + 4 (the 2 preamble words).
        ; Bounded so a wedged card can't hang the caller; a timeout is counted, not fatal. ---
        mov     bx, [bp + F_CX]
        add     bx, 4
        mov     dx, [g_w1_base]
        add     dx, EL3_W1_TX_FREE
        xor     cx, cx                  ; 65536-spin ceiling
.txfree:
        in      ax, dx
        cmp     ax, bx
        jae     .txready
        loop    .txfree
        inc     word [stat_txwait]      ; FIFO never freed in time (card stalled)
.txready:
%ifdef CFG_DEBUG
        mov     al, 'T'
        call    dbg_logb
%endif
        mov     cx, [bp + F_CX]
        mov     si, [bp + F_SI]
        mov     ax, [g_off + FRAG_TX_PIO * 2]
        add     ax, resident_image
        mov     ds, [bp + F_DS]               ; DS = caller's (packet segment)
        call    ax
        push    cs
        pop     ds
        clc
        ret

;--- 6: get_address -- copy our MAC to the caller's ES:DI, return CX = length ---
f_get_address:
        mov     si, g_mac
        mov     cx, 6
        rep     movsb                         ; DS:SI (g_mac) -> ES:DI (caller)
        mov     word [bp + F_CX], 6
        clc
        ret

;--- 7: reset_interface ---
f_reset:
        clc
        ret

;--- 24: get_statistics -- refresh + return DS:SI -> the Crynwr stats struct ---
f_get_statistics:
        mov     ax, [stat_rx]
        mov     [pkt_stats + 0], ax           ; packets in
        mov     ax, [stat_tx]
        mov     [pkt_stats + 4], ax           ; packets out
        mov     ax, [stat_rxerr]
        mov     [pkt_stats + 16], ax          ; errors in
        mov     ax, [stat_rxdrop]
        mov     [pkt_stats + 24], ax          ; packets lost
        mov     ax, [stat_txunderrun]
        mov     [pkt_stats + 20], ax          ; errors out (TX underrun/jabber)
        mov     ax, cs
        mov     [bp + F_DS], ax
        mov     word [bp + F_SI], pkt_stats
        clc
        ret

;--- 0x82 (vendor): tear down -- restore vectors, mask the IRQ, quiet the NIC.
; Returns BX = our PSP so the cold re-run can free the resident block. DS = our segment.
f_uninstall:
        ; restore the previous INT 60h owner
        mov     dx, [old_int_off]
        mov     ax, [old_int_seg]
        push    ds
        mov     ds, ax
        mov     ax, 0x2500 | PKTINT
        int     0x21                          ; DS:DX -> old handler
        pop     ds
        ; restore the previous NIC IRQ owner
        mov     al, [irq_vec]
        mov     dx, [old_irq_off]
        mov     bx, [old_irq_seg]
        push    ds
        mov     ds, bx
        mov     ah, 0x25
        int     0x21
        pop     ds
        ; mask the NIC's IRQ at the PIC so the now-stale vector is never entered
        mov     cl, [g_nic_irq]
        mov     ah, 1
        cmp     cl, 8
        jae     .un_slave
        shl     ah, cl
        in      al, 0x21
        or      al, ah
        out     0x21, al
        jmp     .un_card
.un_slave:
        sub     cl, 8
        shl     ah, cl
        in      al, 0xA1
        or      al, ah
        out     0xA1, al
.un_card:
        ; bus-master path live -> release the DMA-side state (VDS locks) before the card is idled
        cmp     byte [g_use_dma], 0
        je      .un_nodma
        call    dma_teardown
.un_nodma:
        ; disable all NIC interrupt sources (leave the card otherwise idle)
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB      ; | 0 -> no sources enabled
        out     dx, ax
        mov     bx, [psp_seg]
        mov     [bp + F_BX], bx               ; hand the PSP back to the caller
        clc
        ret

%ifdef CFG_DEBUG
;--- 0x7F (vendor): return DS:SI -> debug block (sig, ring head, ring) ---
f_dbg:
        mov     ax, cs
        mov     [bp + F_DS], ax
        mov     word [bp + F_SI], dbg_sig
        clc
        ret

; dbg_logb -- append AL to the event-log ring. DS = our segment. Preserves AX/BX.
dbg_logb:
        push    ax
        push    bx
        mov     bx, [dbg_log_head]
        mov     [dbg_log + bx], al
        inc     bx
        cmp     bx, DBG_LOG_SIZE
        jb      .ok
        xor     bx, bx
.ok:    mov     [dbg_log_head], bx
        pop     bx
        pop     ax
        ret
%endif

f_bad:
        mov     dh, PD_ERR_BADCMD
        stc
        ret

pkt_name        db '3com-pktdrv', 0
