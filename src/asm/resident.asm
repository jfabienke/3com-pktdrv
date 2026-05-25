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
pkt_error:
        mov     bp, sp
        mov     [bp + F_DH], dh         ; return error code in DH
        or      word [bp + F_FLAGS], CY ; set caller CY
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

;--- 4: send_pkt -- DS:SI = packet, CX = length; near-call the emitted TX datapath ---
f_send_pkt:
        ; Recover any pending TX error from a prior (early-start) transmission so an
        ; underrun/jabber doesn't leave the transmitter stuck. Bounded loop -> safe on a
        ; floating bus. DS = our segment here (stat_* and g_nic_io are addressable).
        mov     dx, [g_w1_base]
        add     dx, EL3_W1_TX_STATUS
        mov     cx, 8
.txs:   in      al, dx
        or      al, al
        jz      .txs_done
        test    al, EL3_TXS_RESET_MASK
        jz      .txs_pop
        inc     word [stat_txunderrun]
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
.txs_pop:
        xor     al, al
        out     dx, al                  ; pop this entry off the TX status stack
        loop    .txs
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
        ret
.tx_pio:
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

;------------------------------------------------------------------------------
; dma_tx_enqueue -- non-blocking bus-master TX via a software ring (3C515, 386+ real mode).
; Copies the caller's frame into a free ring slot (so the caller can reuse its buffer per the
; Crynwr ABI), fills that slot's descriptor, bumps the ring, and -- if the card is idle -- kicks
; the DMA for the oldest queued slot. It does NOT wait for completion: the TxComplete ISR frees
; finished slots and kicks the next, so the CPU's frame-prep overlaps the card's DMA. Only blocks
; (sti/hlt, bounded by BIOS ticks) when the ring is full. INT 60h runs at IF=0, so the count/busy
; critical section is atomic wrt the ISR (which only fires once the caller restores IF=1).
; Enter: DS = CS, bp -> INT 60h frame (F_DS:F_SI = packet, F_CX = length <= TX_SLOT_SZ).
; Clobbers ax,bx,cx,dx,si,di,es. Leaves DS = CS, IF = 0.
;------------------------------------------------------------------------------
dma_tx_enqueue:
        ; wait for a free slot if the ring is full (bounded by elapsed BIOS ticks)
        xor     ax, ax
        mov     es, ax
        mov     bx, [es:BIOS_TICK_COUNT]        ; start tick for the full-wait timeout
.eq_wait:
        cmp     word [tx_ring_count], TX_RING_N
        jb      .eq_have
        mov     ax, [es:BIOS_TICK_COUNT]
        sub     ax, bx
        cmp     ax, EL3_DMA_TX_TICKS
        jae     .eq_full                        ; ring still full after the timeout -> drop
        sti                                     ; let the TxComplete ISR drain a slot
        hlt
        cli
        jmp     .eq_wait
.eq_full:
        inc     word [stat_txwait]              ; dropped: ring never drained (wedged card)
        ret
.eq_have:
        ; copy caller frame (F_DS:F_SI, F_CX bytes) into slot[head] = tx_slots + head*TX_SLOT_SZ
        mov     ax, [tx_ring_head]
        mov     dx, TX_SLOT_SZ
        mul     dx                              ; dx:ax = head * TX_SLOT_SZ  (< 64 KB -> ax)
        mov     di, ax
        add     di, tx_slots
        mov     ax, cs
        mov     es, ax                          ; ES:DI = slot
        mov     cx, [bp + F_CX]
        push    ds
        mov     ds, [bp + F_DS]
        mov     si, [bp + F_SI]
        cld
        ; slot copy: the ring is 386+ only (286 uses the zero-copy single-transfer path), so always
        ; the 32-bit rep movsd. The per-element copy cost dominated the ring under -icount; wider wins.
        mov     bx, cx                          ; bx = byte count (for the 0..3-byte remainder)
        cpu     386
        shr     cx, 2                           ; dword count
        rep     movsd
        cpu     8086
        mov     cx, bx
        and     cx, 3                           ; trailing bytes
        rep     movsb
        pop     ds                              ; DS = CS again
        ; fill slot[head]'s descriptor: LEN = len, STATUS = 0 (ADDR/NEXT set at install)
        mov     bx, [tx_ring_head]
        mov     cl, 4
        shl     bx, cl                          ; head * 16
        add     bx, tx_descs
        mov     ax, [bp + F_CX]
        mov     [bx + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [bx + EL3_DESC_LEN + 2], ax
        mov     [bx + EL3_DESC_STATUS], ax
        mov     [bx + EL3_DESC_STATUS + 2], ax
        ; advance head (mod N), count++  (IF=0 here -> atomic wrt the ISR)
        mov     ax, [tx_ring_head]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .eq_hwrap
        xor     ax, ax
.eq_hwrap:
        mov     [tx_ring_head], ax
        inc     word [tx_ring_count]
        ; if the card is idle, kick the oldest queued slot
        cmp     byte [tx_dma_busy], 0
        jne     .eq_done
        call    tx_kick
.eq_done:
        ret

;------------------------------------------------------------------------------
; tx_kick -- start the bus-master DMA for the tail (oldest queued) slot: write its descriptor
; phys to DownListPtr and issue StartDmaDown. Sets tx_dma_busy. Enter DS=CS. Clobbers ax,bx,cx,dx.
;------------------------------------------------------------------------------
tx_kick:
        mov     bx, [tx_ring_tail]
        mov     cl, 4
        shl     bx, cl                          ; tail * 16
        add     bx, tx_descs                    ; bx = &desc[tail]
        ; phys(CS:bx) -> dx:ax
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        add     ax, bx
        adc     dx, 0                           ; dx:ax = phys(desc[tail])
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_DOWN_LIST_PTR
        out     dx, ax                          ; DownListPtr low
        pop     ax
        add     dx, 2
        out     dx, ax                          ; DownListPtr high
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_DOWN
        out     dx, ax
        mov     byte [tx_dma_busy], 1
        ret

;------------------------------------------------------------------------------
; dma_tx_single -- blocking zero-copy bus-master TX (3C515 Corkscrew, 286 real mode). The ring's
; per-frame slot copy costs more than a 286 can hide (no movsd; nothing to overlap in a flood), so
; the 286 instead DMAs straight from the caller's buffer: ~+47% at 100 Mbit vs the ring (28668 vs
; 19570 kbit/s). Builds the one-entry down descriptor (reusing tx_descs[0]; the ring is unused on a
; 286), writes DownListPtr, kicks StartDmaDown, then waits IRQ-driven for the TxComplete ISR to set
; g_tx_done before returning -- so the caller can't reuse/free the buffer while the card is still
; DMAing from it. INT 60h is entered with IF=0, so we sti/hlt to let the NIC IRQ fire, then cli. The
; wait is bounded by ELAPSED time (BIOS tick), not wakeup count, so RX IRQs during a TX flood can't
; make it bail before completion.
; Enter: DS = CS (resident), bp -> INT 60h frame (F_DS:F_SI = packet, F_CX = length).
; Both the descriptor and the caller's buffer live <1 MB, so phys = seg*16 + off is 24-bit safe.
; Clobbers ax,bx,cx,dx. Leaves DS = CS, IF = 0.
;------------------------------------------------------------------------------
dma_tx_single:
        ; caller buffer physical address (F_DS:F_SI) -> dx:ax
        mov     bx, [bp + F_DS]
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl                  ; ax = low 16 of (seg << 4)
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl                  ; dx = high 4 of (seg << 4)
        add     ax, [bp + F_SI]
        adc     dx, 0                   ; dx:ax = phys(buffer)
        mov     [tx_descs + EL3_DESC_ADDR], ax
        mov     [tx_descs + EL3_DESC_ADDR + 2], dx
        ; next = 0 (single transfer), status = 0, length high = 0
        xor     ax, ax
        mov     [tx_descs + EL3_DESC_NEXT], ax
        mov     [tx_descs + EL3_DESC_NEXT + 2], ax
        mov     [tx_descs + EL3_DESC_STATUS], ax
        mov     [tx_descs + EL3_DESC_STATUS + 2], ax
        mov     [tx_descs + EL3_DESC_LEN + 2], ax
        mov     ax, [bp + F_CX]         ; length (<= 1514 -> fits the 13-bit field)
        mov     [tx_descs + EL3_DESC_LEN], ax
        ; descriptor physical address (CS:tx_descs) -> dx:ax
        mov     bx, cs
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl
        add     ax, tx_descs
        adc     dx, 0                   ; dx:ax = phys(descriptor)
        ; DownListPtr <- descriptor phys: two 16-bit OUTs (io+0x404 low, io+0x406 high)
        push    dx                      ; save high word
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_DOWN_LIST_PTR
        out     dx, ax                  ; low word
        pop     ax                      ; high word -> ax
        add     dx, 2
        out     dx, ax                  ; high word
        ; arm completion, then kick StartDmaDown (cmd 0x14, param != 0)
        mov     byte [g_tx_done], 0     ; cleared with IF=0, so the ISR can't race ahead
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_DOWN
        out     dx, ax
        ; IRQ-driven wait: the TxComplete ISR sets g_tx_done. sti/hlt yields until an interrupt;
        ; spurious wakeups (RX during a TX flood) just re-loop -- the timeout is ELAPSED BIOS
        ; ticks, not a wakeup count, so only a wedged card escapes.
        xor     ax, ax
        mov     es, ax                  ; ES = 0 -> BIOS data area (frame restores ES on iret)
        mov     bx, [es:BIOS_TICK_COUNT]    ; start tick
.dma_wait:
        cmp     byte [g_tx_done], 0
        jne     .dma_done
        mov     ax, [es:BIOS_TICK_COUNT]
        sub     ax, bx                  ; elapsed ticks
        cmp     ax, EL3_DMA_TX_TICKS
        jae     .dma_timeout
        sti                             ; (sti has a 1-instr delay: no IRQ between sti and hlt)
        hlt
        jmp     .dma_wait
.dma_timeout:
        inc     word [stat_txwait]      ; no TxComplete in time (wedged card) -- counted, not fatal
.dma_done:
        cli                             ; restore the INT 60h handler's IF=0 invariant
        ret

;------------------------------------------------------------------------------
; post_rx_dma -- (re)post the bus-master RX up-descriptor and arm StartDmaUp. Builds dma_updesc
; pointing at rx_dma_buf (capacity RXDMA_BUFSZ), writes UpListPtr (two 16-bit OUTs at io+0x38/0x3A),
; kicks StartDmaUp. The card DMAs the next received frame straight into rx_dma_buf and writes
; UP_COMPLETE|length into the descriptor status. Enter DS=CS. Clobbers AX,BX,CX,DX. Used at install
; and after each RX-DMA delivery in the ISR.
;------------------------------------------------------------------------------
post_rx_dma:
        xor     ax, ax
        mov     [dma_updesc + EL3_DESC_NEXT], ax
        mov     [dma_updesc + EL3_DESC_NEXT + 2], ax
        mov     [dma_updesc + EL3_DESC_STATUS], ax
        mov     [dma_updesc + EL3_DESC_STATUS + 2], ax
        ; addr = phys(rx_dma_buf) = cs*16 + offset
        mov     bx, cs
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl
        add     ax, rx_dma_buf
        adc     dx, 0
        mov     [dma_updesc + EL3_DESC_ADDR], ax
        mov     [dma_updesc + EL3_DESC_ADDR + 2], dx
        mov     word [dma_updesc + EL3_DESC_LEN], RXDMA_BUFSZ
        mov     word [dma_updesc + EL3_DESC_LEN + 2], 0
        ; UpListPtr <- phys(dma_updesc)
        mov     bx, cs
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl
        add     ax, dma_updesc
        adc     dx, 0
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_UP_LIST_PTR
        out     dx, ax
        pop     ax
        add     dx, 2
        out     dx, ax
        ; StartDmaUp
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_UP
        out     dx, ax
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
