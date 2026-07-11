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

PKTINT          equ 0x60        ; the packet-driver interrupt we install on

; --- bp-frame offsets (after push ax,bx,cx,dx,si,di,bp,ds,es; mov bp,sp) ---
F_ES   equ 0
F_DS   equ 2
F_BP   equ 4
F_DI   equ 6
F_SI   equ 8
F_DX   equ 10
F_DL   equ 10
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

; --- Crynwr API constants (kept in sync with include/pktdrv.h) ---
PD_VERSION      equ 0x0111      ; packet driver spec v1.11 (== PKT_API_VERSION in pktdrv.h)
PD_CLASS_ETHER  equ 1           ; DIX/Ethernet
PD_TYPE_3C509   equ 0x0009      ; interface type (3Com EtherLink III)
PD_FUNC_EXT     equ 2           ; basic + extended (we provide get_statistics)
PD_ERR_BADHANDLE equ 1          ; PDE_BAD_HANDLE
PD_ERR_NOCLASS  equ 2           ; PDE_NO_CLASS  (interface class not supported)
PD_ERR_NOTYPE   equ 3           ; PDE_NO_TYPE   (interface type not supported)
PD_ERR_NONUMBER equ 4           ; PDE_NO_NUMBER (interface number not present)
PD_ERR_BADTYPE  equ 5           ; PDE_BAD_TYPE  (bad packet type)
PD_ERR_NOSPACE  equ 9           ; PDE_NO_SPACE  (no free handle; 10 = PDE_TYPE_INUSE, do NOT use)
PD_ERR_BADCMD   equ 11          ; PDE_BAD_COMMAND
PD_ERR_CANTSEND equ 12          ; PDE_CANT_SEND (frame too large / TX rejected)
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
        mov     al, [bp + F_AL]         ; sub-function in AL
        cmp     al, XMS_DMA_QUERY
        je      .xq
        cmp     al, XMS_DMA_CONFIGURE
        je      .xc
        cmp     al, XMS_DMA_RELEASE
        je      .xr
        cmp     al, XMS_DMA_TX_CONFIGURE   ; 0x04 (8b.2a)
        je      .xtc
        cmp     al, XMS_DMA_TX_SUBMIT      ; 0x05 (8b.2a)
        je      .xts
        cmp     al, XMS_DMA_CSUM_CTL       ; 0x07 (Cyclone HW checksum on/off)
        je      .xcs
        ; 0x03 RX_CONFIGURE2 and 0x06 RX_REFILL are defined but not implemented in this build:
        ; return XMS_ERR_NOT_V2 (distinct from PD_ERR_BADCMD) so the client can tell "v2 known,
        ; unimplemented" from a genuinely bad command. al is in {0x03,0x06} here (0x00-0x02/0x04/0x05
        ; already dispatched above); a higher AL falls through to PD_ERR_BADCMD.
        cmp     al, XMS_DMA_RX_REFILL   ; 0x06 = top of the reserved v2 range
        jbe     .xstub
        mov     dh, PD_ERR_BADCMD
        stc
        jmp     pkt_error
.xstub:
        mov     dh, XMS_ERR_NOT_V2
        stc
        jmp     pkt_error
.xq:    call    f_xms_query
        jmp     pkt_xms_ret
.xc:    call    f_xms_configure
        jmp     pkt_xms_ret
.xr:    call    f_xms_release
        jmp     pkt_xms_ret
.xtc:   call    f_xms_tx_configure
        jmp     pkt_xms_ret
.xts:   call    f_xms_tx_submit
        jmp     pkt_xms_ret
.xcs:   call    f_xms_csum_ctl
        jmp     pkt_xms_ret
pkt_xms_ret:
        jc      pkt_error
        jmp     pkt_return
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
        ; --- validate the interface selectors before allocating a handle. We are a single
        ;     DIX-Ethernet interface, number 0; reject anything else with the proper Crynwr code
        ;     rather than handing back a handle for an unsupported request. ---
        cmp     byte [bp + F_AL], PD_CLASS_ETHER   ; if_class
        jne     .at_noclass
        mov     ax, [bp + F_BX]                    ; if_type
        cmp     ax, 0xFFFF                         ; 0xFFFF = any type for this class
        je      .at_type_ok
        cmp     ax, PD_TYPE_3C509                  ; or our specific interface type
        jne     .at_notype
.at_type_ok:
        cmp     byte [bp + F_DL], 0                ; if_number -- we expose interface 0 only
        jne     .at_nonumber
        cmp     word [bp + F_CX], 1                ; typelen 1 cannot form a 2-byte EtherType and
        je      .at_badtype                        ;   would read one byte past the caller template
        ; --- find a free handle slot ---
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
        mov     cx, [bp + F_CX]              ; caller's type length (0, or >= 2)
        jcxz    .at_all
        mov     bx, [bp + F_SI]              ; caller's SI -> type template (>= 2 bytes)
        mov     ds, [bp + F_DS]              ; caller's DS (briefly)
        mov     ax, [bx]                     ; the first 2 EtherType bytes (wire order)
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
.at_noclass:
        mov     dh, PD_ERR_NOCLASS
        stc
        ret
.at_notype:
        mov     dh, PD_ERR_NOTYPE
        stc
        ret
.at_nonumber:
        mov     dh, PD_ERR_NONUMBER
        stc
        ret
.at_badtype:
        mov     dh, PD_ERR_BADTYPE
        stc
        ret

;--- 3: release_type -- BX = handle (slot offset); free the slot ---
f_release_type:
        mov     bx, [bp + F_BX]
        cmp     bx, htable
        jb      .rt_bad
        cmp     bx, htable + MAX_HANDLES * HANDLE_SIZE
        jae     .rt_bad
        ; must be a slot boundary: (bx - htable) mod HANDLE_SIZE == 0. An interior address (e.g.
        ; htable+1) is in range but would zero [bx+2] across two slots, corrupting a neighbouring
        ; handle's recv_seg / far-call pointer. (clobbers ax,cx,dx -- all caller-saved on the frame.)
        mov     ax, bx
        sub     ax, htable
        xor     dx, dx
        mov     cx, HANDLE_SIZE
        div     cx                           ; dx = (bx - htable) mod HANDLE_SIZE
        or      dx, dx
        jnz     .rt_bad
        mov     word [bx + 2], 0             ; recv_seg = 0 -> slot free
        clc
        ret
.rt_bad:
        mov     dh, PD_ERR_BADHANDLE
        stc
        ret

;--- 4: send_pkt -- DS:SI = packet, CX = length; near-call the emitted TX datapath ---
f_send_pkt:
        ; --- length guard: reject oversized frames BEFORE any TX work. The 486+ ring DMA path copies
        ;     the caller frame into fixed TX_SLOT_SZ ring slots (dma_tx_enqueue does not re-check),
        ;     so an oversized CX would overrun resident memory. Cap = the interoperable large-frame
        ;     max (FDDI, < the card's oversize threshold) when /j is active, else a standard
        ;     Ethernet frame. Both caps are <= TX_SLOT_SZ so the slot copy is always safe. Return
        ;     Crynwr CANT_SEND. ---
        mov     ax, EL3_MAX_FRAME
        cmp     byte [g_use_large], 0
        je      .sp_cap
        mov     ax, EL3_MAX_FRAME_LARGE
.sp_cap:
        cmp     word [bp + F_CX], ax
        jbe     .sp_len_ok
        mov     dh, PD_ERR_CANTSEND
        stc
        ret
.sp_len_ok:
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
        jnz     .txs_err
        ; Non-error TX status. On the bus-master path do NOT pop it: TxStatus and the TxComplete
        ; interrupt are the same machinery (TxComplete asserts while the stack is non-empty;
        ; popping the last entry deasserts it). This preamble runs in the FOREGROUND on every
        ; send, racing the DMA completion -- popping a successful completion here eats a pending
        ; TxComplete edge before the ISR can service it (the request vanishes mid-INTA -> the PIC
        ; delivers spurious IRQ15 -> the completion is lost; 409/409 causal match in the traced
        ; run). The ring's completion accounting is descriptor-based (DN_COMPLETE) and the latch
        ; is acked by the ISR -- a success status is simply none of our business here.
        cmp     byte [g_use_dma], 0
        jnz     .txs_done
        jmp     .txs_pop                ; PIO floor: pop successes too (keep the 4-deep stack clear)
.txs_err:
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
        ; stat_tx ("packets out") is bumped at each SUCCESS exit below, not here: a frame that
        ; reaches a CANT_SEND reject (oversized at the top guard, or a large frame falling to PIO)
        ; must not be reported as transmitted by get_statistics.
        cmp     byte [g_use_dma], 0     ; bus-master DMA TX path (3C515, >=286)?
        je      .tx_pio
        ; ISR upcall context: limit ring enqueue to keep at least one slot free for the
        ; main-loop ring-full wait (STI/HLT) to escape. Without this, the pattern is:
        ;   TX_COMPLETE drains count N→N-1, then RX upcall enqueues N-1→N, main loop
        ;   re-checks and still sees count=N — the W-wait never exits.
        ; Fix: in the ISR, only enqueue if count < TX_RING_N-1 so that after enqueue
        ; count ≤ TX_RING_N-1 < TX_RING_N and the main-loop wait can escape.
        ; When count ≥ TX_RING_N-1, fall through to PIO for this frame.
        cmp     byte [g_isr_busy], 0
        jz      .tx_check_ring          ; not in ISR: use ring unconditionally
        cmp     word [tx_ring_count], TX_RING_N - 1
        jae     .tx_pio                 ; ISR + count ≥ N-1: PIO to leave room for main loop
.tx_check_ring:
        cmp     byte [g_tx_ring], 0     ; 486+ -> non-blocking ring; 286/386 -> zero-copy single-transfer
        je      .tx_single
        call    dma_tx_enqueue          ; 486+: copy to a ring slot, ISR drains the card (non-blocking)
        jnc     .tx_enqueued            ; CF=0: frame is in a ring slot, FIFO order preserved
        ; CF=1: dma_tx_enqueue could not place the frame. Two cases, distinguished by context:
        ;  - ISR/reentrancy (g_isr_busy): the completion ISR can't fire to drain a slot, so waiting
        ;    would deadlock -> PIO this frame (the only safe option in ISR context).
        ;  - Foreground: the ring stayed full for the full WEDGE guard (dead card). Do NOT PIO -- a
        ;    PIO burst jumps the FIFO ahead of the frames queued in the DMA ring -> out-of-order TX
        ;    -> dupack/retransmit storm (the 515dma100 write collapse). Reject CANT_SEND (honest
        ;    CF=1, NOT a silent CF=0 drop); the TCP stack retransmits in order. FIFO order across the
        ;    TX path is non-negotiable for TCP.
        cmp     byte [g_isr_busy], 0
        jnz     .tx_pio                 ; ISR/reentrancy context -> PIO
        mov     dh, PD_ERR_CANTSEND     ; foreground wedge -> reject, never reorder
        stc
        ret
.tx_enqueued:
        inc     word [stat_tx]          ; success: frame accepted into the ring
        clc                             ; enqueued -> the TxComplete ISR drains it
        ret
.tx_single:
        cmp     byte [g_tx_in_flight], 0
        jne     .tx_pio                 ; re-entrant call from upcall: fall back to PIO for this frame
        call    dma_tx_single           ; 286/386: zero-copy DMA straight from the caller's buffer (blocking)
        inc     word [stat_tx]          ; success: single-transfer DMA issued
        clc
        ret
.tx_pio:
        ; --- PIO is only FIFO-safe for standard-size frames. The tx_pio fragment bursts the whole
        ; frame with a blind `rep outsw`, and TxFree can never reach (len+4) for a frame larger than
        ; the ~2 KB FIFO -- the wait below would time out and the burst would overflow the FIFO mid
        ; frame. A large (/j FDDI) frame MUST use a bus-master DMA path (ring or 286/386 single-transfer);
        ; if it reached PIO (no DMA at all, a ring-full/ISR fallback, or 286/386 reentrancy) we cannot
        ; send it safely. Return Crynwr CANT_SEND (honest CF=1) rather than silently corrupt-send.
        ; DMA frames up to EL3_MAX_FRAME_LARGE are handled in full by the ring/single paths above. ---
        cmp     word [bp + F_CX], EL3_MAX_FRAME
        jbe     .tx_pio_room
        mov     dh, PD_ERR_CANTSEND
        stc
        ret
.tx_pio_room:
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
        inc     word [stat_tx]          ; success: PIO burst issued
        clc
        ret

;------------------------------------------------------------------------------
; dma_tx_enqueue -- non-blocking bus-master TX via a software ring (3C515, 486+ real mode).
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
        ; Inside the NIC ISR upcall (g_isr_busy>0), the DMA completion ISR can't fire:
        ; reentrancy guard takes the 'Z' path (EOI, no TX_COMPLETE processing) and the
        ; edge-triggered PIC never re-fires. STI/HLT would spin the full 9-tick timeout
        ; without ever draining a slot. Signal the caller to fall back to PIO instead.
        cmp     byte [g_isr_busy], 0
        jnz     .eq_isr_full
        ; --- self-heal: a TxComplete EDGE can be lost outright (edge-triggered ISA: a latch that
        ; rises and drops mid-INTA resolves as spurious IRQ15 and is gone forever -- reproduced
        ; deterministically under the emulator, and a classic failure mode on real edge-triggered
        ; hardware). The descriptor still shows DN_COMPLETE in memory, so don't wait on an IRQ
        ; that will never come: retire the completed tail + kick the next INLINE. IF=0 here, so
        ; this can't race the ISR's drain; retire-oldest/kick-next is exactly the ISR's order, so
        ; FIFO order is preserved. With every edge lost (worst case) the ring still cycles via
        ; these foreground drains; the wedge guard below remains for a genuinely dead card. ---
        mov     bx, [tx_ring_tail]
        mov     cl, 4
        shl     bx, cl                          ; tail * 16
        add     bx, tx_descs
        test    word [bx + EL3_DESC_STATUS_HI], EL3_DESC_DN_COMPLETE_HI
        jz      .eq_wtick                       ; tail genuinely in flight -> wait for the IRQ
        dec     word [tx_ring_count]            ; retire the completed tail (ring full -> count>0 after)
        mov     ax, [tx_ring_tail]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .eq_twr
        xor     ax, ax
.eq_twr:
        mov     [tx_ring_tail], ax
        call    tx_kick                         ; start the new tail (count > 0: ring was full)
%ifdef CFG_DEBUG
        inc     word [txd_drained]              ; self-heal retires count in dr alongside ISR ones
        mov     al, 'H'
        call    dbg_logb                        ; 'H' = foreground self-heal retire (lost edge)
%endif
        jmp     .eq_wait                        ; slot freed -> .eq_have on the next pass
.eq_wtick:
        mov     ax, [es:BIOS_TICK_COUNT]
        sub     ax, bx
        cmp     ax, EL3_DMA_TX_WEDGE_TICKS      ; ONLY a genuine-wedge escape (~5 s), NOT a tuning timeout:
        jae     .eq_full                        ; the foreground waits for the ring to drain (see below)
%ifdef CFG_DEBUG
        inc     word [txd_full_spins]           ; foreground blocked, ring full, waiting on a drain
        mov     al, 'W'
        call    dbg_logb
%endif
        sti                                     ; let the TxComplete ISR drain a slot
        hlt
        cli
        jmp     .eq_wait
.eq_isr_full:
%ifdef CFG_DEBUG
        inc     word [txd_busy_stuck]           ; ring full while we can't drain (ISR ctx) -> PIO
%endif
        stc                                     ; ISR context, ring full: tell caller to use PIO
        ret
.eq_full:
        ; Foreground only (the ISR path branched to .eq_isr_full above), and only after the ring
        ; stayed full for the full WEDGE guard (~5 s) -- i.e. the card is genuinely dead, not a normal
        ; deferred-completion stall. Return CF=1: the caller rejects this frame with CANT_SEND (it must
        ; NOT PIO -- a PIO burst would jump the FIFO ahead of the frames still queued in the ring ->
        ; out-of-order TX -> TCP dupack/retransmit storm, the 515dma100 write collapse). FIFO order
        ; across the TX path is non-negotiable for TCP; the stack retransmits the rejected frame in order.
        inc     word [stat_txwait]              ; count ring-full wedge rejects (was: PIO fallbacks)
%ifdef CFG_DEBUG
        inc     word [txd_pio_fallb]            ; (txdiag: now counts foreground wedge rejects)
        mov     al, 'P'
        call    dbg_logb
%endif
        stc                                     ; -> caller: foreground wedge -> CANT_SEND (never PIO)
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
        ; slot copy: the ring is 486+ only (286/386 use the zero-copy single-transfer path), so always
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
        ; fill slot[head]'s descriptor (ADDR/NEXT set at install): LEN = len | lastFrag,
        ; FSH = TxIndicate (request TxComplete), FSH high word cleared (clears dnComplete)
        mov     bx, [tx_ring_head]
        mov     cl, 4
        shl     bx, cl                          ; head * 16
        add     bx, tx_descs
        mov     ax, [bp + F_CX]
        mov     [bx + EL3_DESC_LEN], ax
        mov     ax, EL3_DESC_LAST_FRAG_HI
        mov     [bx + EL3_DESC_LEN_HI], ax
        mov     ax, EL3_FSH_TX_INDICATE
        mov     [bx + EL3_DESC_STATUS], ax
        call    csum_fsh_hi                     ; 0 unless Cyclone csum mode (preserves BX)
        mov     [bx + EL3_DESC_STATUS_HI], ax
        ; advance head (mod N), count++  (IF=0 here -> atomic wrt the ISR)
        mov     ax, [tx_ring_head]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .eq_hwrap
        xor     ax, ax
.eq_hwrap:
        mov     [tx_ring_head], ax
        inc     word [tx_ring_count]
%ifdef CFG_DEBUG
        mov     ax, [tx_ring_count]             ; track ring-depth high-water for the diagnostic
        cmp     ax, [txd_max_count]
        jbe     .eq_nomax
        mov     [txd_max_count], ax
.eq_nomax:
%endif
        ; if the card is idle, kick the oldest queued slot
        cmp     byte [tx_dma_busy], 0
        jne     .eq_queued
        call    tx_kick
        clc                                     ; success (kicked): caller must NOT fall back to PIO
        ret
.eq_queued:
        ; DMA in progress: frame queued, no kick needed (CFG_DEBUG logs 'q')
%ifdef CFG_DEBUG
        mov     al, 'q'
        call    dbg_logb
%endif
        clc                                     ; success (queued): caller must NOT fall back to PIO
        ret

;------------------------------------------------------------------------------
; tx_kick -- start the bus-master DMA for the tail (oldest queued) slot: write its descriptor
; phys to DownListPtr and issue StartDmaDown. Sets tx_dma_busy. Enter DS=CS. Clobbers ax,bx,cx,dx.
;------------------------------------------------------------------------------
tx_kick:
%ifdef CFG_DEBUG
        inc     word [txd_kick]         ; one StartDmaDown issued
        mov     al, 'K'
        call    dbg_logb
%endif
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
        ; HARDWARE-TRUE start: writing the list pointer starts the down engine (the
        ; high-half write completes it) -- no StartDmaDown command (that is the Wn7
        ; single-shot interface; issuing it here on real silicon would start the
        ; MasterAddr engine with garbage). Busy flag set BEFORE the engine can run.
        mov     byte [tx_dma_busy], 1
        push    dx
        mov     dx, [g_nic_io]
        add     dx, [g_dnlist_off]              ; per-gen: 0x404 ISA 515, 0x24 PCI 90x
        out     dx, ax                          ; DownListPtr low
        pop     ax
        add     dx, 2
        out     dx, ax                          ; DownListPtr high -> engine starts
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
        ; next = 0 (end of list), FSH = TxIndicate (request TxComplete; high word cleared
        ; = dnComplete cleared), length = len | lastFrag (single fragment)
        xor     ax, ax
        mov     [tx_descs + EL3_DESC_NEXT], ax
        mov     [tx_descs + EL3_DESC_NEXT + 2], ax
        call    csum_fsh_hi                     ; 0 unless Cyclone csum mode
        mov     [tx_descs + EL3_DESC_STATUS_HI], ax
        mov     ax, EL3_FSH_TX_INDICATE
        mov     [tx_descs + EL3_DESC_STATUS], ax
        mov     ax, EL3_DESC_LAST_FRAG_HI
        mov     [tx_descs + EL3_DESC_LEN_HI], ax
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
        ; arm completion BEFORE starting: the list-pointer high-half write starts the
        ; engine (hardware-true; no StartDmaDown -- that is the Wn7 single-shot cmd).
        mov     byte [g_tx_done], 0     ; cleared with IF=0, so the ISR can't race ahead
        mov     byte [g_tx_in_flight], 1 ; mark channel busy before the engine can run
        push    dx                      ; save high word
        mov     dx, [g_nic_io]
        add     dx, [g_dnlist_off]      ; per-gen: 0x404 ISA 515, 0x24 PCI 90x
        out     dx, ax                  ; DownListPtr low
        pop     ax                      ; high word -> ax
        add     dx, 2
        out     dx, ax                  ; DownListPtr high -> engine starts
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
        mov     byte [g_tx_in_flight], 0
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
        ; Teardown order matters: quiet the interrupt SOURCE before touching any vector. The old
        ; code restored INT 60h + the NIC IRQ vector first, so an IRQ arriving mid-teardown would
        ; dispatch to a stale/previous handler. Sequence now: (1) disable NIC sources, (2) mask the
        ; PIC line, (3) restore the vectors (now safe), (4) restore the line's ORIGINAL PIC mask.

        ; (1) disable all NIC interrupt sources at the card
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB      ; | 0 -> no sources enabled
        out     dx, ax

        ; (2) mask our IRQ line at the PIC (temporary; restored to original state in step 4)
        mov     cl, [g_nic_irq]
        mov     dx, 0x21
        cmp     cl, 8
        jb      .un_mask
        sub     cl, 8
        mov     dx, 0xA1
.un_mask:
        mov     ah, 1
        shl     ah, cl
        in      al, dx
        or      al, ah
        out     dx, al

        ; (3) restore the previous NIC IRQ owner, then the previous INT 60h owner
        mov     al, [irq_vec]
        mov     dx, [old_irq_off]
        mov     bx, [old_irq_seg]
        push    ds
        mov     ds, bx
        mov     ah, 0x25
        int     0x21
        pop     ds
        mov     dx, [old_int_off]
        mov     ax, [old_int_seg]
        push    ds
        mov     ds, ax
        mov     ax, 0x2500 | PKTINT
        int     0x21                          ; DS:DX -> old handler
        pop     ds

        ; (4) restore the line's PIC mask to its state at install: a line we found unmasked
        ;     (e.g. shared) is unmasked again; one we found masked is left masked.
        mov     cl, [g_nic_irq]
        mov     dx, 0x21
        cmp     cl, 8
        jb      .un_restore
        sub     cl, 8
        mov     dx, 0xA1
.un_restore:
        mov     ah, 1
        shl     ah, cl                        ; ah = our bit
        in      al, dx
        cmp     byte [pic_mask_orig], 0
        jne     .un_done                      ; was masked at install -> leave masked (bit set)
        not     ah
        and     al, ah                        ; was unmasked at install -> clear our bit
        out     dx, al
        jmp     .un_psp
.un_done:
        or      al, ah                        ; ensure our bit stays set (masked)
        out     dx, al
.un_psp:
        ; (4b) slave IRQ only: install also unmasked the master IRQ2 cascade. Restore it -- if IRQ2
        ;      was masked before install, re-mask it (else leave it unmasked). Otherwise a /u leaks
        ;      IRQ2 unmasked. (docs/01-constraints.md: "save and restore both PIC masks".)
        cmp     byte [g_nic_irq], 8
        jb      .un_ret                       ; master IRQ -> IRQ2 cascade never touched
        cmp     byte [pic_casc_orig], 0
        je      .un_ret                       ; IRQ2 was unmasked at install -> leave it unmasked
        in      al, 0x21                      ; IRQ2 was masked at install -> re-mask it
        or      al, 0x04                      ; master bit 2 = IRQ2 cascade
        out     0x21, al
.un_ret:
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

;--- XMS DMA QUERY: return capability flags in BX, max slot size in DX ---
f_xms_query:
        ; DMA extension requires bus-master NIC (3C515); 3C509 is PIO-only
        cmp     byte [g_use_dma], 0
        je      .no_dma
        ; Caps are fixed by JIT fragment selection at install time; the ring tier keys off
        ; g_tx_ring (486+ since Phase 8b.1). XMS_TX (caller-phys blocking TX, 8b.2a) is a
        ; single-transfer path, so it is advertised on every DMA tier (286/386/486+).
        ; 286/386: CONV_SINGLE + XMS_TX
        ; 486+:    + XMS_RING + RING + CONV_RING
        mov     bx, XMS_CAP_CONV_SINGLE | XMS_CAP_XMS_TX
        cmp     byte [g_tx_ring], 0
        je      .no_ring
        or      bx, XMS_CAP_XMS_RING | XMS_CAP_RING | XMS_CAP_CONV_RING
.no_ring:
        ; PCI generations (Boomerang/Cyclone): withhold the RX-DMA policy caps -- RX stays
        ; PIO (the project's proven RX-always-PIO policy for TCP; the RX-DMA vertical on
        ; PCI is deferred with #6: level-INTx re-entry double-delivers on the upcall path).
        ; TX keeps the full DMA ring + XMS_TX; Cyclone csum rides the TX DPDs.
        cmp     word [g_uplist_off], EL3_UP_LIST_PCI
        jne     .rx_caps_ok
        and     bx, ~(XMS_CAP_CONV_SINGLE | XMS_CAP_CONV_RING | XMS_CAP_XMS_RING | XMS_CAP_RING)
.rx_caps_ok:
        cmp     byte [g_csum_ok], 0        ; Cyclone: HW checksum insertion available
        je      .no_csum_cap
        or      bx, XMS_CAP_HWCSUM
.no_csum_cap:
        mov     [bp + F_BX], bx
        mov     ax, EL3_MAX_FRAME
        cmp     byte [g_use_large], 0
        je      .done
        mov     ax, TX_SLOT_SZ          ; max slot size = 4608 (FDDI-sized ring buffer)
.done:
        mov     [bp + F_DX], ax
        clc
        ret
.no_dma:
        stc
        ret

;--- XMS DMA CONFIGURE: ES:DI -> xms_rx_cfg_t; build descriptors + arm UP_LIST_PTR ---
f_xms_configure:
        ; check not already armed
        cmp     byte [xms_dma_armed], 0
        jne     .ecfg
        ; ES:DI from caller's frame
        mov     bx, [bp + F_DI]         ; cfg offset
        mov     es, [bp + F_ES]         ; cfg segment  (ES saved on bp-frame)
        ; validate version
        cmp     byte [es:bx + XMS_CFG_version], XMS_CFG_VERSION
        jne     .ever
        ; validate policy (0=CONV_SINGLE, 1=CONV_RING, 2=XMS_RING)
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_XMS_RING
        ja      .epol
        ; ring / XMS-ring policies require the 486+ TX ring. The 286/386 single-transfer tier
        ; advertises only CONV_SINGLE via QUERY, so reject a ring policy here too -- otherwise a
        ; caller that skips QUERY could arm a mode this tier cannot honour.
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_CONV_SINGLE
        je      .pol_ok
        cmp     byte [g_tx_ring], 0
        je      .epol
.pol_ok:
        ; validate phys0 < 16 MB: byte[3] of the 32-bit physical address must be 0
        ; (if phys[31:24]=0 then phys ≤ 0x00FFFFFF = 16MB-1, within ISA DMA range)
        cmp     byte [es:bx + XMS_CFG_phys0 + 3], 0
        jne     .ephys
        ; validate phys1 < 16 MB
        cmp     byte [es:bx + XMS_CFG_phys1 + 3], 0
        jne     .ephys
        ; validate slot_size against BOTH bounds, both mode-dependent so CONFIGURE never accepts a
        ; slot QUERY did not advertise (public contract, xms_dma.h: slot_size <= QUERY's DX):
        ;   lower = the active max RX frame -- the slot must hold the largest deliverable frame, else
        ;           a card completion the ISR copies out could overrun the caller's buffer;
        ;   upper = QUERY's advertised DX = EL3_MAX_FRAME (std) / TX_SLOT_SZ (/j large).
        ; In std mode the two coincide, so slot_size must equal EL3_MAX_FRAME (exactly what QUERY
        ; returns, which is also what the reference caller passes back).
        cmp     byte [g_use_large], 0
        jne     .slotchk_large
        cmp     word [es:bx + XMS_CFG_slot_size], EL3_MAX_FRAME
        jne     .esz                            ; std: must equal the QUERY-advertised max (= max frame)
        jmp     .slotchk_ok
.slotchk_large:
        cmp     word [es:bx + XMS_CFG_slot_size], EL3_MAX_FRAME_LARGE
        jb      .esz                            ; smaller than the FDDI max frame -> RX overrun risk
        cmp     word [es:bx + XMS_CFG_slot_size], TX_SLOT_SZ
        ja      .esz                            ; larger than QUERY advertised (TX_SLOT_SZ)
.slotchk_ok:
        ; save config pointer + fields
        mov     ax, [es:bx + XMS_CFG_slot_size]
        mov     [xms_slot_sz], ax
        mov     al, [es:bx + XMS_CFG_policy]
        mov     [xms_rx_policy], al
        mov     [xms_cfg_off], bx
        mov     ax, es
        mov     [xms_cfg_seg], ax
        ; build descriptor 0: ADDR=phys0, LEN=slot_size, STATUS=0, NEXT set below
        mov     ax, [es:bx + XMS_CFG_phys0]
        mov     [xms_rx_desc0 + EL3_DESC_ADDR], ax
        mov     ax, [es:bx + XMS_CFG_phys0 + 2]
        mov     [xms_rx_desc0 + EL3_DESC_ADDR + 2], ax
        mov     ax, [xms_slot_sz]
        mov     [xms_rx_desc0 + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [xms_rx_desc0 + EL3_DESC_LEN + 2], ax
        mov     [xms_rx_desc0 + EL3_DESC_STATUS], ax
        mov     [xms_rx_desc0 + EL3_DESC_STATUS + 2], ax
        ; build descriptor 1: ADDR=phys1, LEN=slot_size, STATUS=0
        mov     ax, [es:bx + XMS_CFG_phys1]
        mov     [xms_rx_desc1 + EL3_DESC_ADDR], ax
        mov     ax, [es:bx + XMS_CFG_phys1 + 2]
        mov     [xms_rx_desc1 + EL3_DESC_ADDR + 2], ax
        mov     ax, [xms_slot_sz]
        mov     [xms_rx_desc1 + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [xms_rx_desc1 + EL3_DESC_LEN + 2], ax
        mov     [xms_rx_desc1 + EL3_DESC_STATUS], ax
        mov     [xms_rx_desc1 + EL3_DESC_STATUS + 2], ax
        ; set NEXT fields: CONV_SINGLE(0) is the only single-transfer policy
        ;   CONV_SINGLE(0) → NEXT=0 (ISR re-arms post-upcall)
        ;   CONV_RING(1), XMS_RING(2) → chain desc0→desc1→desc0
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV_SINGLE
        je      .single_next
.do_ring:
        ; ring: phys(CS:xms_rx_desc1) -> desc0.NEXT; phys(CS:xms_rx_desc0) -> desc1.NEXT
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        push    dx
        push    ax
        ; desc0.NEXT = phys(xms_rx_desc1)
        pop     ax
        pop     dx
        push    dx
        push    ax
        add     ax, xms_rx_desc1
        adc     dx, 0
        mov     [xms_rx_desc0 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc0 + EL3_DESC_NEXT + 2], dx
        ; desc1.NEXT = phys(xms_rx_desc0)
        pop     ax
        pop     dx
        add     ax, xms_rx_desc0
        adc     dx, 0
        mov     [xms_rx_desc1 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc1 + EL3_DESC_NEXT + 2], dx
        jmp     .next_done
.single_next:
        xor     ax, ax
        mov     [xms_rx_desc0 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc0 + EL3_DESC_NEXT + 2], ax
        mov     [xms_rx_desc1 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc1 + EL3_DESC_NEXT + 2], ax
.next_done:
        ; GDT for INT 15h AH=87h: only XMS_RING(2); CONV_SINGLE(0) and CONV_RING(1) skip
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_RING
        jne     .skip_gdt
        mov     byte [xms_gdt + 21], 0x93   ; source descriptor access byte
        mov     byte [xms_gdt + 29], 0x93   ; destination descriptor access byte
        xor     ax, ax
        mov     [xms_gdt +  0], ax
        mov     [xms_gdt +  2], ax
        mov     [xms_gdt +  4], ax
        mov     [xms_gdt +  6], ax
        mov     [xms_gdt +  8], ax
        mov     [xms_gdt + 10], ax
        mov     [xms_gdt + 12], ax
        mov     [xms_gdt + 14], ax
        mov     word [xms_gdt + 16], 0
        mov     [xms_gdt + 18], ax
        mov     [xms_gdt + 20], al
        mov     [xms_gdt + 22], ax
        mov     word [xms_gdt + 24], 0
        mov     [xms_gdt + 26], ax
        mov     [xms_gdt + 28], al
        mov     [xms_gdt + 30], ax
        mov     [xms_gdt + 32], ax
        mov     [xms_gdt + 34], ax
        mov     [xms_gdt + 36], ax
        mov     [xms_gdt + 38], ax
        mov     [xms_gdt + 40], ax
        mov     [xms_gdt + 42], ax
        mov     [xms_gdt + 44], ax
        mov     [xms_gdt + 46], ax
.skip_gdt:
        ; slot index = 0
        mov     byte [xms_slot_idx], 0
        ; arm UP_LIST_PTR <- phys(CS:xms_rx_desc0)
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        add     ax, xms_rx_desc0
        adc     dx, 0
        push    dx
        mov     dx, [g_nic_io]
        add     dx, [g_uplist_off]      ; per-gen: 0x418 ISA 515, 0x38 PCI 90x
        out     dx, ax
        pop     ax
        add     dx, 2
        out     dx, ax                  ; UpListPtr high -> up engine armed (hardware-true)
        ; enable UP_COMPLETE interrupt (add to existing interrupt mask)
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH | EL3_ST_UP_COMPLETE
        cmp     byte [g_use_dma], 0
        je      .intr_no_tx
        or      ax, EL3_ST_TX_COMPLETE
.intr_no_tx:
        out     dx, ax
        ; mark armed
        mov     byte [xms_dma_armed], 1
        mov     ax, cs
        mov     es, ax                  ; restore ES = our segment
        clc
        ret
.ever:  mov     dh, XMS_ERR_BAD_VERSION
        jmp     .err
.epol:  mov     dh, XMS_ERR_BAD_POLICY
        jmp     .err
.ephys: mov     dh, XMS_ERR_PHYS_RANGE
        jmp     .err
.esz:   mov     dh, XMS_ERR_SLOT_SIZE
        jmp     .err
.ecfg:  mov     dh, XMS_ERR_ALREADY_CFG
.err:   mov     ax, cs
        mov     es, ax
        stc
        ret

;--- XMS DMA RELEASE: stop DMA, clear UP_LIST_PTR, disarm ---
f_xms_release:
        cmp     byte [xms_dma_armed], 0
        je      .enot
        ; zero UP_LIST_PTR (two 16-bit OUTs) -- a null list pointer halts the up engine
        mov     dx, [g_nic_io]
        add     dx, [g_uplist_off]
        xor     ax, ax
        out     dx, ax
        add     dx, 2
        out     dx, ax
        ; remove UP_COMPLETE from interrupt enable
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH
        cmp     byte [g_use_dma], 0
        je      .rel_intr
        or      ax, EL3_ST_TX_COMPLETE
.rel_intr:
        out     dx, ax
        ; clear state
        mov     byte [xms_dma_armed], 0
        xor     ax, ax
        mov     [xms_cfg_off], ax
        mov     [xms_cfg_seg], ax
        clc
        ret
.enot:  mov     dh, XMS_ERR_NOT_CFG
        stc
        ret

;--- XMS DMA TX_CONFIGURE (AL=0x04): ES:DI -> xms_tx_cfg_t; register the caller TX pool (8b.2a) ---
; Validates version + that the whole pool is ISA-reachable (< 16 MB), stores pool_phys/pool_len, and
; sets xms_tx_armed. No DMA is armed here -- TX_SUBMIT issues one blocking single-transfer per frame.
; g_use_dma is checked FIRST: the TX state lives in the XMS region, NOT resident on the PIO floor.
; ES:DI is the caller's live cfg pointer (the dispatch preserves it). Returns CF=0, or CF=1 + DH.
f_xms_tx_configure:
        cmp     byte [g_use_dma], 0
        je      .txc_ehw                ; no bus-master engine (3C509 / PIO): TX DMA unavailable
        cmp     byte [es:di + XMS_TXCFG_version], XMS_TX_CFG_VERSION
        jne     .txc_ever
        ; pool base < 16 MB: high word of pool_phys must be below the 24-bit ISA limit
        mov     ax, [es:di + XMS_TXCFG_pool_phys + 2]
        cmp     ax, DMA_ISA_16M_LIMIT
        jae     .txc_erange
        ; pool_len must be nonzero
        mov     ax, [es:di + XMS_TXCFG_pool_len]
        or      ax, [es:di + XMS_TXCFG_pool_len + 2]
        jz      .txc_erange
        ; pool end = pool_phys + pool_len must be <= 16 MB (dx:ax = end, exclusive)
        mov     ax, [es:di + XMS_TXCFG_pool_phys]
        mov     dx, [es:di + XMS_TXCFG_pool_phys + 2]
        add     ax, [es:di + XMS_TXCFG_pool_len]
        adc     dx, [es:di + XMS_TXCFG_pool_len + 2]
        cmp     dx, DMA_ISA_16M_LIMIT
        ja      .txc_erange
        jb      .txc_store
        or      ax, ax                  ; dx == 0x0100: end ok only if low word == 0 (exactly 16 MB)
        jnz     .txc_erange
.txc_store:
        mov     ax, [es:di + XMS_TXCFG_pool_phys]
        mov     [xms_tx_pool_phys], ax
        mov     ax, [es:di + XMS_TXCFG_pool_phys + 2]
        mov     [xms_tx_pool_phys + 2], ax
        mov     ax, [es:di + XMS_TXCFG_pool_len]
        mov     [xms_tx_pool_len], ax
        mov     ax, [es:di + XMS_TXCFG_pool_len + 2]
        mov     [xms_tx_pool_len + 2], ax
        mov     byte [xms_tx_armed], 1
        clc
        ret
.txc_ehw:   mov dh, PD_ERR_BADCMD       ; QUERY won't advertise XMS_TX without g_use_dma; defense-in-depth
        stc
        ret
.txc_ever:  mov dh, XMS_ERR_BAD_VERSION
        stc
        ret
.txc_erange: mov dh, XMS_ERR_PHYS_RANGE
        stc
        ret

;--- XMS DMA TX_SUBMIT (AL=0x05): DX:CX = caller frame phys (hi:lo), BX = length; blocking (8b.2a) ---
; Requires a registered pool. Range-checks the frame is wholly inside the pool, then DMAs it via a
; blocking caller-phys single-transfer (dma_tx_caller; independent of g_tx_ring, never the ring path).
; DX:CX/BX are the caller's live registers (the dispatch preserves them). Returns CF=0 on completion,
; CF=1 + DH=XMS_ERR_* on a validation failure, a busy channel, or a TX timeout.
f_xms_tx_submit:
        cmp     byte [g_use_dma], 0     ; PIO floor: the xms_tx_* state is NOT resident -- never touch it
        je      .txs_ehw
        cmp     byte [xms_tx_armed], 0
        je      .txs_enotcfg
        ; length: 0 < bx <= max frame (std, or FDDI-large when /j)
        or      bx, bx
        jz      .txs_esize
        mov     ax, EL3_MAX_FRAME
        cmp     byte [g_use_large], 0
        je      .txs_lcap
        mov     ax, EL3_MAX_FRAME_LARGE
.txs_lcap:
        cmp     bx, ax
        ja      .txs_esize
        ; range (1): phys (dx:cx) >= pool_phys
        cmp     dx, [xms_tx_pool_phys + 2]
        jb      .txs_erange
        ja      .txs_ge_ok
        cmp     cx, [xms_tx_pool_phys]
        jb      .txs_erange
.txs_ge_ok:
        ; range (2): frame_end = phys + len  <=  pool_end = pool_phys + pool_len. Scratch: ax,si,di
        ; (the dispatch frame restores caller si/di on iret, so clobbering them is safe).
        mov     di, cx
        add     di, bx
        mov     si, dx
        adc     si, 0                   ; si:di = frame_end (phys + len)
        mov     ax, [xms_tx_pool_phys]
        add     ax, [xms_tx_pool_len]   ; CF = carry out of the low add
        mov     ax, [xms_tx_pool_phys + 2]
        adc     ax, [xms_tx_pool_len + 2]   ; ax = pool_end.high
        cmp     si, ax
        ja      .txs_erange             ; frame_end.high > pool_end.high
        jb      .txs_submit             ; frame_end.high < pool_end.high -> in range
        mov     ax, [xms_tx_pool_phys]
        add     ax, [xms_tx_pool_len]   ; ax = pool_end.low (recomputed; only ax is free here)
        cmp     di, ax
        ja      .txs_erange             ; equal high, frame_end.low > pool_end.low
.txs_submit:
        call    dma_tx_caller           ; dx:cx = phys, bx = len; blocking; CF/DH set by it
        ret
.txs_ehw:   mov dh, PD_ERR_BADCMD       ; no bus-master engine (PIO floor): TX DMA unavailable
        stc
        ret
.txs_enotcfg: mov dh, XMS_ERR_TX_NOT_CFG
        stc
        ret
.txs_esize: mov dh, XMS_ERR_SLOT_SIZE
        stc
        ret
.txs_erange: mov dh, XMS_ERR_TX_RANGE
        stc
        ret

;------------------------------------------------------------------------------
; dma_tx_caller -- blocking caller-phys bus-master TX (the TX_SUBMIT engine). A caller-phys variant
; of dma_tx_single: the down descriptor's ADDR/LEN come from DX:CX/BX, not phys(CS:tx_slots). Uses a
; DEDICATED descriptor (xms_tx_desc), never the ring's tx_descs[], and is independent of g_tx_ring.
; Completion is the TxComplete ISR (the emulator does not write a pollable down-descriptor bit):
; xms_tx_in_flight diverts that IRQ to g_tx_done on every tier, so the wait is uniform and the 486+
; ring's bookkeeping is untouched.
; Enter: DX:CX = frame phys (DX high, CX low), BX = length; DS = CS.
; Exit:  CF=0 on completion; CF=1 + DH on busy/timeout. Clobbers ax,bx,cx,dx,si,di,es. IF=0.
;------------------------------------------------------------------------------
dma_tx_caller:
        cmp     byte [g_tx_in_flight], 0
        jne     .tc_busy                ; another single-transfer in flight (transient)
        ; build the dedicated TX descriptor: ADDR = dx:cx, LEN = bx | lastFrag, NEXT = 0,
        ; FSH = TxIndicate (high word cleared = dnComplete cleared)
        mov     [xms_tx_desc + EL3_DESC_ADDR], cx
        mov     [xms_tx_desc + EL3_DESC_ADDR + 2], dx
        xor     ax, ax
        mov     [xms_tx_desc + EL3_DESC_NEXT], ax
        mov     [xms_tx_desc + EL3_DESC_NEXT + 2], ax
        mov     [xms_tx_desc + EL3_DESC_STATUS_HI], ax
        mov     ax, EL3_FSH_TX_INDICATE
        mov     [xms_tx_desc + EL3_DESC_STATUS], ax
        mov     ax, EL3_DESC_LAST_FRAG_HI
        mov     [xms_tx_desc + EL3_DESC_LEN_HI], ax
        mov     [xms_tx_desc + EL3_DESC_LEN], bx
        ; descriptor phys (CS:xms_tx_desc) -> dx:ax
        mov     bx, cs
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl
        add     ax, xms_tx_desc
        adc     dx, 0                   ; dx:ax = phys(xms_tx_desc)
        ; arm completion BEFORE starting (IF=0 so the ISR can't race); the list-pointer
        ; high-half write starts the engine (hardware-true; no StartDmaDown command)
        mov     byte [g_tx_done], 0
        mov     byte [g_tx_in_flight], 1
        mov     byte [xms_tx_in_flight], 1   ; divert TxComplete -> g_tx_done (all tiers)
        push    dx
        mov     dx, [g_nic_io]
        add     dx, [g_dnlist_off]      ; per-gen: 0x404 ISA 515, 0x24 PCI 90x
        out     dx, ax
        pop     ax
        add     dx, 2
        out     dx, ax                  ; DownListPtr high -> engine starts
        ; IRQ-driven wait, bounded by elapsed BIOS ticks (same shape as dma_tx_single)
        xor     ax, ax
        mov     es, ax
        mov     bx, [es:BIOS_TICK_COUNT]
.tc_wait:
        cmp     byte [g_tx_done], 0
        jne     .tc_done
        mov     ax, [es:BIOS_TICK_COUNT]
        sub     ax, bx
        cmp     ax, EL3_DMA_TX_TICKS
        jae     .tc_timeout
        sti
        hlt
        jmp     .tc_wait
.tc_timeout:
        ; wedged card: abort the down channel so it stops reading the caller's slot, then report.
        mov     dx, [g_nic_io]
        add     dx, [g_dnlist_off]
        xor     ax, ax
        out     dx, ax
        add     dx, 2
        out     dx, ax
        inc     word [stat_txwait]
        mov     byte [xms_tx_in_flight], 0
        mov     byte [g_tx_in_flight], 0
        cli
        mov     dh, XMS_ERR_TX_TIMEOUT
        stc
        ret
.tc_done:
        mov     byte [xms_tx_in_flight], 0
        mov     byte [g_tx_in_flight], 0
        cli
        inc     word [stat_tx]
        clc
        ret
.tc_busy:
        mov     dh, XMS_ERR_TX_BUSY
        stc
        ret

;------------------------------------------------------------------------------
; f_xms_csum_ctl -- XMS_DMA_CSUM_CTL (0x07): BX=1 enable / 0 disable the Cyclone
; HW checksum insertion mode. While enabled, every IP TX frame on the DMA path
; gets FSH AddIPChksum (+AddTCP/AddUDP by protocol) and the STACK must leave the
; checksum fields zero. Rejected (XMS_ERR_NO_CSUM) unless the NIC is a Cyclone
; with DMA active (insertion rides the DPD; PIO TX has no FSH).
;------------------------------------------------------------------------------
f_xms_csum_ctl:
        cmp     byte [g_csum_ok], 0
        jne     .cs_ok
        mov     dh, XMS_ERR_NO_CSUM
        stc
        ret
.cs_ok:
        mov     ax, [bp + F_BX]
        and     al, 1
        mov     [g_csum_mode], al
        clc
        ret

;------------------------------------------------------------------------------
; csum_fsh_hi -- AX = FSH high word (Cyclone checksum-request bits) for the
; caller frame at F_DS:F_SI, or 0 when the mode is off / the frame isn't IP.
; IP -> AddIP; +AddTCP or +AddUDP by the protocol byte. Preserves DS/SI/BX/CX/DX.
;------------------------------------------------------------------------------
csum_fsh_hi:
        xor     ax, ax
        cmp     byte [g_csum_mode], 0
        je      .cf_done
        push    ds
        push    si
        mov     si, [bp + F_SI]
        mov     ds, [bp + F_DS]
        cmp     word [si + 12], 0x0008      ; EtherType 0x0800 (big-endian on the wire)
        jne     .cf_pop
        mov     ax, EL3_FSH_ADD_IP_HI
        cmp     byte [si + 23], 6           ; IP protocol: TCP
        jne     .cf_udp
        or      ax, EL3_FSH_ADD_TCP_HI
        jmp     .cf_pop
.cf_udp:
        cmp     byte [si + 23], 17          ; UDP
        jne     .cf_pop
        or      ax, EL3_FSH_ADD_UDP_HI
.cf_pop:
        pop     si
        pop     ds
.cf_done:
        ret

f_bad:
        mov     dh, PD_ERR_BADCMD
        stc
        ret

pkt_name        db '3com-pktdrv', 0
