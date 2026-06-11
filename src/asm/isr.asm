; isr.asm -- NIC interrupt handler + Crynwr receiver upcall (RESIDENT; %included by start).
;
; Hardening (as in the Crynwr skeleton): full register save, DS=CS, a PRIVATE stack (the
; interrupted task's stack may be tiny), a reentrancy guard, and a proper PIC EOI (slave +
; master for IRQ>=8). On RX-complete it runs the two-call receiver upcall for the registered
; receiver -- call 1 (AX=0) requests a buffer, the emitted rx drain fills it, call 2 (AX=1)
; delivers -- then RX_DISCARD. Structure lifted from Nestor 3c509.asm `recv`.
;
; NOTE: the RX path cannot be exercised without a real 3C509 (no emulator has one); this is
; structurally verified (assembles + disassembles) and awaits hardware validation.

%include "el3_core.inc"
%include "el3_corkscrew.inc"
%include "xms_dma.inc"

; Per-interrupt RX work cap: process at most this many frames per ISR entry, then yield. A
; sustained RX flood keeps RX_COMPLETE asserted, so the still-pending IRQ re-fires and the
; next batch runs -- no frame loss, but the foreground app isn't starved. 32 covers a full
; 8 KB FIFO of minimum-size frames.
MAX_RX_WORK     equ 32

nic_isr:
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
        mov     ax, cs
        mov     ds, ax                  ; DS = our segment

        ; --- reentrancy guard FIRST, before any stack switch. A nested IRQ must detect "busy"
        ;     while still on the interrupted task's stack. If we switched first, the nested entry
        ;     would (a) overwrite the outer ISR's saved isr_save_ss/sp and (b) reset SP to the top
        ;     of the private stack the outer ISR is still using -- the busy path would then iret
        ;     through a corrupted frame. The reentrant path needs no private stack: it only EOIs
        ;     and returns, popping the regs it pushed on whatever stack it entered on. ---
        cmp     byte [g_isr_busy], 0
        je      .isr_free
        ; reentrant: skip this entry (the in-flight ISR still sees the pending source)
%ifdef CFG_DEBUG
        mov     al, 'Z'
        call    dbg_logb
%endif
        jmp     .eoi                    ; EOI + iret WITHOUT switching/restoring the private stack
.isr_free:
        inc     byte [g_isr_busy]
        ; --- now safe to switch to a private stack (busy flag bars a reentrant clobber) ---
        mov     [isr_save_ss], ss
        mov     [isr_save_sp], sp
        mov     ss, ax                  ; SS = our segment (ax = cs)
        mov     sp, isr_stack_top
        inc     word [stat_irq]
        mov     byte [isr_work], MAX_RX_WORK   ; bound RX frames processed this entry
%ifdef CFG_DEBUG
        ; visible heartbeat: cycle the top-left text cell on every serviced interrupt
        push    es
        mov     ax, 0xB800
        mov     es, ax
        inc     byte [es:0]
        pop     es
        mov     al, 'I'
        call    dbg_logb
%endif

.recv_loop:
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        in      ax, dx                  ; adapter status
        test    ax, EL3_ST_TX_COMPLETE  ; bus-master TX DMA done
        jz      .no_txdone
        cmp     byte [g_use_dma], 0
        je      .no_txdone              ; PIO mode: no DMA (TxComplete just acked at .recv_done)
        ; 8b.2a: a TX_SUBMIT caller-phys single-transfer takes priority over the ring path on EVERY
        ; tier -- flag its blocking wait and skip tx_ring_adv, so the 486+ ring's count/tail stay
        ; untouched while a submit is in flight (the stack serialises the two; see docs/10).
        cmp     byte [xms_tx_in_flight], 0
        je      .tx_not_submit
        mov     byte [g_tx_done], 1
        jmp     .no_txdone
.tx_not_submit:
        cmp     byte [g_tx_ring], 0
        jne     .tx_ring_adv            ; 486+: advance the non-blocking TX ring
        mov     byte [g_tx_done], 1     ; 286/386 single-transfer: flag dma_tx_single's blocking wait
        jmp     .no_txdone
.tx_ring_adv:
        push    ax                      ; preserve adapter status (drain loop + tx_kick clobber ax)
                                        ; (push BEFORE the debug marker: `mov al,'T'` would otherwise
                                        ; corrupt the saved status -- the .recv_done recheck joins
                                        ; here with AX=0 and must rejoin .no_txdone with AX=0)
%ifdef CFG_DEBUG
        inc     word [txd_cpl_seen]     ; one TxComplete ISR entry reached the ring path
        mov     al, 'T'
        call    dbg_logb
%endif
        ; Drain ALL completed tail descriptors per service, not one. At 100Mbit several down-list
        ; descriptors complete (each sets EL3_DESC_DN_COMPLETE in its status) behind ONE coalesced
        ; TxComplete latch; retiring one-per-IRQ falls behind, the ring looks full, the stack stops
        ; sending -> ~0.5s TX-pacing gaps (515dma100 collapse). DN_COMPLETE is the reliable per-
        ; descriptor completion; TxComplete just says "inspect the ring". This is hardware-correct:
        ; it retires exactly the descriptors that are actually DN_COMPLETE -- on real HW (spaced
        ; completions) that's ~one per IRQ; under the emulator (StartDmaDown sets the next tail's
        ; DN_COMPLETE synchronously) the whole queue drains in one pass.
        ; NOTE: still NO mid-ISR AckIntr(TxComplete). TxComplete is cleared once at .recv_done
        ; (AckIntr 0x00FF); the emulator's IRQ line only toggles on a level TRANSITION, so a mid-loop
        ; ack would lose the next rising edge and stall the ring. We gate on DN_COMPLETE, not the
        ; latch, so coalesced completions are caught without touching the ack.
.tx_drain_loop:
        cmp     word [tx_ring_count], 0
        je      .tx_idle                ; nothing (more) queued -- also guards stale descriptor reads
        mov     bx, [tx_ring_tail]
        mov     cl, 4
        shl     bx, cl                  ; tail * 16 (EL3_DESC_SIZE)
        add     bx, tx_descs            ; bx = &desc[tail]
        test    word [bx + EL3_DESC_STATUS], EL3_DESC_DN_COMPLETE
        jz      .tx_drained             ; tail still in flight -> no more completed; leave it
%ifdef CFG_DEBUG
        inc     word [txd_drained]      ; one descriptor actually retired this pass
        mov     al, 'T'
        call    dbg_logb                ; one 'T' per retired slot (ring-depth visibility)
%endif
        dec     word [tx_ring_count]    ; retire the completed tail slot
        mov     ax, [tx_ring_tail]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .tx_twrap
        xor     ax, ax
.tx_twrap:
        mov     [tx_ring_tail], ax
        cmp     word [tx_ring_count], 0
        je      .tx_idle                ; ring fully drained
        call    tx_kick                 ; start the new tail's DMA (sets its DN_COMPLETE synchronously)
        jmp     .tx_drain_loop          ; re-check: the just-kicked tail is now complete -> drain it
.tx_drained:
        ; tail not yet complete: it is in flight -> its own TxComplete will re-enter the ISR.
        jmp     .tx_acpop
.tx_idle:
        mov     byte [tx_dma_busy], 0
.tx_acpop:
        pop     ax                      ; restore adapter status
.no_txdone:
        test    ax, EL3_ST_UP_COMPLETE
        jz      .no_updone
        cmp     byte [xms_dma_armed], 0
        je      .no_updone
        push    ax                      ; preserve card status across xms_rx_deliver
        call    xms_rx_deliver
        pop     ax
.no_updone:
        test    ax, EL3_ST_ADAPTER_FAILURE
        jnz     .adapter_fail
        test    ax, EL3_ST_RX_COMPLETE
        jz      .recv_done
        ; RX is ALWAYS via the PIO FIFO path, even when TX uses bus-master DMA. The emulator
        ; funnels any frame the card couldn't DMA (RX-DMA unarmed) into the PIO RX FIFO, and the
        ; single-buffer RX-DMA dropped incoming ACKs under bidirectional TCP (one up-descriptor,
        ; re-armed only after the whole upcall -- frames racing into the FIFO meanwhile were
        ; RX_DISCARDed). The PIO path loops and delivers reliably; RX (ACKs) is low-volume for a
        ; sender, so its CPU cost is negligible. (FRAG_RX_PIO is always emitted; see g_plan.)
        mov     dx, [g_w1_base]
        add     dx, EL3_W1_RX_STATUS
        in      ax, dx                  ; RX status: length + flags
        test    ah, 0x80                ; RX_INCOMPLETE (0x8000)
        jnz     .recv_done
        test    ah, 0x40                ; RX_ERROR (0x4000)
        jnz     .rxerr
        mov     cx, ax
        and     cx, [g_rx_len_mask]     ; CX = packet length (0x07FF std / 0x1FFF large)
        mov     [rx_len], cx
        cmp     cx, 14                  ; runt: need a full Ethernet header to demux
        jb      .drop

        ; --- read the 14-byte header into hdr_buf (byte reads; even count keeps the
        ;     FIFO word-aligned for the payload drain) ---
        push    ds
        pop     es                      ; ES = DS = our segment, so stosb targets hdr_buf
        mov     dx, [g_w1_base]         ; Window-1 base = RX FIFO (FIFO is at +0 of the W1 block)
        mov     di, hdr_buf
        mov     cx, 14
.hdr:   in      al, dx
        stosb
        loop    .hdr

        ; --- find a handle whose type matches hdr_buf[12..13] (or matches all) ---
        mov     ax, [hdr_buf + 12]      ; EtherType, same byte order access_type stored
        mov     si, htable
        mov     cx, MAX_HANDLES
.scan:  cmp     word [si + 2], 0        ; recv_seg == 0 -> free slot, skip
        je      .scan_next
        cmp     word [si + 4], 0        ; type 0 -> match all
        je      .scan_hit
        cmp     word [si + 4], ax       ; type == EtherType?
        je      .scan_hit
.scan_next:
        add     si, HANDLE_SIZE
        loop    .scan
        jmp     .drop                   ; no handler for this type

.scan_hit:
        mov     [cur_handle], si

        ; --- upcall 1: AX=0 request a buffer; CX=len, BX=handle, ES:DI=0 ---
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     bx, si
        mov     cx, [rx_len]
        call far [bx]                   ; slot+0/+2 = recv off,seg -> ES:DI = buffer (or 0:0)
        mov     ax, es
        or      ax, di
        jz      .drop                   ; null buffer -> drop (RX_DISCARD flushes the frame)
        mov     [appbuf_seg], es
        mov     [appbuf_off], di

        ; --- prepend the saved header, then drain the payload into the buffer ---
        mov     si, hdr_buf
        mov     cx, 14
        rep     movsb                   ; DS:SI (hdr_buf) -> ES:DI; DI advances past header
        mov     cx, [rx_len]
        sub     cx, 14
        jz      .delivered              ; header-only frame
        mov     ax, [g_off + FRAG_RX_PIO * 2]
        add     ax, resident_image
        call    ax                      ; drain remaining bytes into ES:DI

.delivered:
        ; --- upcall 2: AX=1 deliver; DS:SI=buffer, CX=len, BX=handle ---
        mov     si, [appbuf_off]
        mov     cx, [rx_len]
        mov     bx, [cur_handle]
        mov     ax, 1
        mov     ds, [appbuf_seg]        ; DS:SI = buffer (set DS last)
        call far [cs:bx]
        mov     ax, cs
        mov     ds, ax                  ; restore our DS
        inc     word [stat_rx]
%ifdef CFG_DEBUG
        mov     al, 'R'
        call    dbg_logb
%endif

.discard:
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_RX_DISCARD
        out     dx, ax
        dec     byte [isr_work]
        jz      .recv_done              ; per-interrupt cap hit -> yield; pending IRQ re-fires
        jmp     .recv_loop

.rxerr:
        inc     word [stat_rxerr]
%ifdef CFG_DEBUG
        ; Log 'E' then the RX error cause as one hex nibble. The cause source differs by
        ; generation (confirmed vs the Linux 3c515 driver): the 3C509 keeps it in RxStatus bits
        ; 11-13; the 3C515 has a dedicated RxErrors register (W1 base +0x04 = io+0x14). The ISR
        ; is resident (g_nic_gen is cold/reclaimed), so tell them apart by g_w1_base != g_nic_io.
        mov     al, 'E'
        call    dbg_logb                ; dbg_logb preserves AX (AH still = RX status)
        mov     bx, [g_w1_base]
        cmp     bx, [g_nic_io]
        jne     .err_corkscrew
        mov     cl, 11                  ; 3C509: RxStatus bits 11-13
        shr     ax, cl
        and     al, 7
        jmp     .err_emit
.err_corkscrew:
        mov     dx, bx
        add     dx, EL3_W1_RX_ERRORS    ; 3C515: dedicated RxErrors register
        in      al, dx
        and     al, 0x0F                ; over/length/frame/crc (dribble 0x10 dropped)
.err_emit:
        add     al, '0'                 ; nibble -> hex char
        cmp     al, '9'
        jbe     .err_log
        add     al, 7
.err_log:
        call    dbg_logb
%endif
        jmp     .discard
.drop:
        inc     word [stat_rxdrop]
%ifdef CFG_DEBUG
        mov     al, 'D'
        call    dbg_logb
%endif
        jmp     .discard

.adapter_fail:
        ; RX engine wedged -> self-heal: RxReset, re-apply the RX filter (RxReset clears it),
        ; re-enable the receiver. DX is the command reg (set in .recv_loop; generation-agnostic).
        inc     word [stat_adapterfail]
        mov     ax, EL3_CMD_RX_RESET
        out     dx, ax
        call    isr_wait_cmd            ; RxReset is slow -> bounded poll on CmdInProgress
        mov     ax, EL3_CMD_SET_RX_FILTER | EL3_RXF_STATION | EL3_RXF_BROADCAST
        out     dx, ax
        mov     ax, EL3_CMD_RX_ENABLE
        out     dx, ax
        jmp     .recv_done             ; ack + EOI; a real frame re-fires the IRQ

.recv_done:
%ifdef CFG_DEBUG
        mov     al, 'A'
        call    dbg_logb                ; one 'A' per terminal AckIntr (ack-race forensics)
        ; ISR-stack overflow canary (task #57): the receiver upcall runs arbitrary app code on
        ; this stack; a clobbered bottom word means the upcall chain exceeded it. Log 'O' and
        ; re-arm so each overflow event logs once.
        cmp     word [isr_stack], 0BEEFh
        je      .canary_ok
        mov     al, 'O'
        call    dbg_logb
        mov     word [isr_stack], 0BEEFh
.canary_ok:
%endif
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_ACK_INTR | 0x00FF   ; acknowledge all latched sources
        out     dx, ax
        ; --- closed-window re-check (edge-triggered IRQ). A TxComplete that latches while the
        ; line is already high (mid-ISR) raises no new edge; if it lands after the final status
        ; read, the ack above just cleared it UNPROCESSED and no IRQ will ever re-fire for it --
        ; with no other NIC traffic the ring wedges (proven: connect stalled with the completed
        ; frame on the wire, dr=kk-1, foreground waited the full wedge guard). Descriptor memory
        ; is the truth, the latch is only the doorbell: if the ring tail shows DN_COMPLETE now,
        ; drain it and re-ack. A completion landing AFTER the ack finds the line low and re-fires
        ; normally, so this loop runs only for the would-have-been-lost case and terminates.
        cmp     byte [g_use_dma], 0
        je      .ack_clean
        cmp     byte [g_tx_ring], 0
        je      .ack_clean              ; ring tier only (single-transfer wait is tick-bounded)
        cmp     byte [xms_tx_in_flight], 0
        jne     .ack_clean              ; TX_SUBMIT owns the engine; don't touch ring state
        cmp     word [tx_ring_count], 0
        jne     .rc_queued
%ifdef CFG_DEBUG
        mov     al, 'c'
        call    dbg_logb                ; recheck bail: ring empty at this ack
%endif
        jmp     .ack_clean
.rc_queued:
        mov     bx, [tx_ring_tail]
        mov     cl, 4
        shl     bx, cl
        add     bx, tx_descs
        test    word [bx + EL3_DESC_STATUS], EL3_DESC_DN_COMPLETE
        jnz     .rc_drain
%ifdef CFG_DEBUG
        mov     al, 'n'
        call    dbg_logb                ; recheck bail: tail still in flight (not DN_COMPLETE)
%endif
        jmp     .ack_clean
.rc_drain:
%ifdef CFG_DEBUG
        inc     word [txd_spare]        ; xx = ack-race recoveries (completion saved from loss)
%endif
        xor     ax, ax                  ; drain joins .no_txdone with AX as adapter status:
        jmp     .tx_ring_adv            ;   0 = no other sources -> falls back to .recv_done
.ack_clean:
        ; Bar a nested IRQ across the busy-clear + stack restore. A receiver upcall or a BIOS path
        ; (e.g. INT 15h on the XMS RX route) may have re-enabled IF; a nested entry that saw
        ; g_isr_busy==0 with SS:SP not yet restored would take the full path and switch onto the
        ; private stack the outer ISR is still using. CLI closes that window; the IRET below
        ; restores the caller's IF. (The reentrant path joins at .eoi and never gets here.)
        cli
        dec     byte [g_isr_busy]
        ; restore the interrupted task's stack (ONLY the non-reentrant path switched to the
        ; private stack -- the reentrant path joins at .eoi below and must NOT restore SS:SP).
        mov     ss, [isr_save_ss]
        mov     sp, [isr_save_sp]
.eoi:
        ; PIC end-of-interrupt: slave first (IRQ >= 8), then master
        mov     al, 0x20
        cmp     byte [g_nic_irq], 8
        jb      .master
        out     0xA0, al
.master:
        out     0x20, al
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

;------------------------------------------------------------------------------
; xms_rx_deliver -- handle an XMS up-descriptor completion (UP_COMPLETE interrupt).
; Reads the completed slot's descriptor status to get frame length, delivers to the
; registered receiver, clears the descriptor, and advances the ping-pong index.
; On 286/386 (single-transfer, g_tx_ring=0): re-arms the OTHER slot and issues StartDmaUp
; before processing -- minimises the gap during which the NIC has no armed descriptor.
; Clobbers AX, BX, CX, DX, SI, DI, ES. DS = our segment on entry and exit.
;------------------------------------------------------------------------------
xms_rx_deliver:
; Deliver one XMS up-DMA received frame. Near-called from ISR.
; DS = CS on entry and exit. May clobber AX, BX, CX, DX, SI, DI, ES.
; BP frame: [bp-2]=phys_lo, [bp-4]=phys_hi, [bp-6]=lin_seg, [bp-8]=desc_ptr(SI).
        push    bp
        mov     bp, sp
        sub     sp, 8

        ; --- 1. Select completed slot's descriptor into SI ---
        mov     si, xms_rx_desc0
        cmp     byte [xms_slot_idx], 0
        je      .gd
        mov     si, xms_rx_desc1
.gd:    mov     [bp-8], si              ; save for STATUS clear + phys/lin select

        ; --- 2. Verify UP_COMPLETE in descriptor STATUS ---
        mov     ax, [si + EL3_DESC_STATUS]
        test    ax, EL3_DESC_UP_COMPLETE
        jz      .done

        ; --- 3. Frame length from STATUS[12:0] ---
        and     ax, EL3_DESC_LEN_MASK
        mov     [rx_len], ax
        cmp     ax, 14
        jb      .discard
        ; defense-in-depth: never copy more than the caller's slot holds. CONFIGURE requires
        ; slot_size >= the max frame, so this should be unreachable, but a card that reports a
        ; length past the slot must not make us read/deliver past the buffer -> drop the frame.
        cmp     ax, [xms_slot_sz]
        ja      .discard

        ; --- 4. 286/XMS_COPY single-transfer: pre-arm OTHER slot before processing ---
        ; Skip for CONV_SINGLE (1 slot only; re-arm happens AFTER upcall instead)
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV_SINGLE
        je      .no_prearm
        cmp     byte [g_tx_ring], 0
        jne     .no_prearm
        xor     byte [xms_slot_idx], 1  ; toggle to the OTHER (new) slot
        mov     di, xms_rx_desc0
        cmp     byte [xms_slot_idx], 0
        je      .arm_new
        mov     di, xms_rx_desc1
.arm_new:
        xor     ax, ax
        mov     [di + EL3_DESC_STATUS], ax
        mov     [di + EL3_DESC_STATUS + 2], ax
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        add     ax, di
        adc     dx, 0                   ; dx:ax = phys(new descriptor)
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_UP_LIST_PTR
        out     dx, ax
        pop     ax
        add     dx, 2
        out     dx, ax
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_UP
        out     dx, ax
        ; SI still points to the COMPLETED (old) slot

.no_prearm:
        ; --- 5. Load phys + lin for the completed slot from cfg ---
        push    es
        mov     es, [xms_cfg_seg]
        mov     bx, [xms_cfg_off]
        mov     si, [bp-8]              ; completed descriptor ptr
        cmp     si, xms_rx_desc0
        jne     .addrs1
        mov     ax, [es:bx + XMS_CFG_phys0]
        mov     cx, [es:bx + XMS_CFG_phys0 + 2]
        mov     di, [es:bx + XMS_CFG_lin0]
        mov     dx, [es:bx + XMS_CFG_lin0 + 2]
        jmp     .addrs_got
.addrs1:
        mov     ax, [es:bx + XMS_CFG_phys1]
        mov     cx, [es:bx + XMS_CFG_phys1 + 2]
        mov     di, [es:bx + XMS_CFG_lin1]
        mov     dx, [es:bx + XMS_CFG_lin1 + 2]
.addrs_got:
        pop     es
        ; ax=phys_lo, cx=phys_hi, di=lin_lo, dx=lin_hi (for lin<1MB: dx=0)
        mov     [bp-2], ax              ; phys_lo
        mov     [bp-4], cx              ; phys_hi
        ; lin_seg = ((dx << 12) | (di >> 4))  -- valid because lin_N is page-aligned
        push    dx
        mov     cl, 12
        shl     dx, cl
        mov     cl, 4
        shr     di, cl
        or      di, dx
        pop     dx                      ; (restore dx; value discarded -- used only as scratch above)
        mov     [bp-6], di              ; lin_seg

        ; --- 6. Read 14-byte Ethernet header into hdr_buf ---
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_RING
        jae     .hdr_int15

        ; CONV_SINGLE/CONV_RING: read 14 bytes from lin_seg:0 into hdr_buf
        mov     es, [bp-6]              ; ES = lin_seg
        xor     bx, bx                  ; source offset = 0
        mov     di, hdr_buf
        mov     cx, 14
.vcpi_hdr:
        mov     al, [es:bx]
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jnz     .vcpi_hdr
        push    cs
        pop     es
        jmp     .scan

.hdr_int15:
        ; XMS_COPY: INT 15h AH=87h: 7 words, phys_N -> phys(hdr_buf)
        ; src descriptor at xms_gdt+16
        mov     ax, [bp-2]
        mov     cl, [bp-4]              ; phys[23:16] in cl
        mov     word [xms_gdt + 16], 13
        mov     [xms_gdt + 18], ax
        mov     [xms_gdt + 20], cl
        xor     al, al
        mov     [xms_gdt + 22], al
        mov     [xms_gdt + 23], al
        ; dst descriptor at xms_gdt+24: phys(hdr_buf)
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     bx, cs
        mov     cl, 12
        shr     bx, cl
        add     ax, hdr_buf
        adc     bx, 0
        mov     word [xms_gdt + 24], 13
        mov     [xms_gdt + 26], ax
        mov     [xms_gdt + 28], bl
        xor     al, al
        mov     [xms_gdt + 30], al
        mov     [xms_gdt + 31], al
        push    ds
        pop     es
        mov     si, xms_gdt
        mov     cx, 7
        mov     ah, 0x87
        int     0x15
        push    cs
        pop     es

.scan:
        ; --- 7. Scan htable for EtherType ---
        mov     ax, [hdr_buf + 12]
        mov     si, htable
        mov     cx, MAX_HANDLES
.scan_loop:
        cmp     word [si + 2], 0
        je      .scan_next
        cmp     word [si + 4], 0
        je      .scan_hit
        cmp     word [si + 4], ax
        je      .scan_hit
.scan_next:
        add     si, HANDLE_SIZE
        loop    .scan_loop
        jmp     .discard

.scan_hit:
        mov     [cur_handle], si

        ; --- 8. Upcall 1 (AX=0): request buffer ---
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_RING
        jae     .up1_no_hint
        mov     es, [bp-6]              ; VCPI/DPMI hint: lin_seg:0
        xor     di, di
        jmp     .up1_call
.up1_no_hint:
        xor     ax, ax
        mov     es, ax
        xor     di, di
.up1_call:
        xor     ax, ax
        mov     bx, [cur_handle]
        mov     cx, [rx_len]
        call far [bx]
        mov     ax, es
        or      ax, di
        jz      .discard
        mov     [appbuf_seg], es
        mov     [appbuf_off], di

        ; --- 9. XMS_COPY: INT 15h to copy full frame into appbuf ---
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_RING
        jb      .no_copy
        ; src: phys_N, limit = rx_len - 1
        mov     ax, [bp-2]
        mov     cl, [bp-4]
        mov     bx, [rx_len]
        dec     bx
        mov     [xms_gdt + 16], bx
        mov     [xms_gdt + 18], ax
        mov     [xms_gdt + 20], cl
        xor     al, al
        mov     [xms_gdt + 22], al
        mov     [xms_gdt + 23], al
        ; dst: phys(appbuf) = appbuf_seg*16 + appbuf_off
        mov     ax, [appbuf_seg]
        mov     cl, 4
        shl     ax, cl
        mov     bx, [appbuf_seg]
        mov     cl, 12
        shr     bx, cl
        add     ax, [appbuf_off]
        adc     bx, 0
        mov     cx, [rx_len]
        dec     cx
        mov     [xms_gdt + 24], cx
        mov     [xms_gdt + 26], ax
        mov     [xms_gdt + 28], bl
        xor     al, al
        mov     [xms_gdt + 30], al
        mov     [xms_gdt + 31], al
        ; CX = ceil(rx_len / 2) words
        mov     cx, [rx_len]
        shr     cx, 1
        adc     cx, 0
        push    ds
        pop     es
        mov     si, xms_gdt
        mov     ah, 0x87
        int     0x15
        push    cs
        pop     es

.no_copy:
        ; --- 10. Upcall 2 (AX=1): deliver ---
        mov     si, [appbuf_off]
        mov     cx, [rx_len]
        mov     bx, [cur_handle]
        mov     ax, 1
        mov     ds, [appbuf_seg]
        call far [cs:bx]
        mov     ax, cs
        mov     ds, ax
        inc     word [stat_rx]

.discard:
        ; --- 11. Clear completed slot STATUS ---
        mov     si, [bp-8]              ; completed descriptor ptr (saved at start)
        xor     ax, ax
        mov     [si + EL3_DESC_STATUS], ax
        mov     [si + EL3_DESC_STATUS + 2], ax

        ; --- 12. CONV_SINGLE: post-deliver re-arm desc0 + StartDmaUp ---
        ; (1 slot only; xms_slot_idx stays 0; gap is acceptable at 10 Mbps)
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV_SINGLE
        jne     .toggle
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
        add     dx, EL3_CS_UP_LIST_PTR
        out     dx, ax
        pop     ax
        add     dx, 2
        out     dx, ax
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_UP
        out     dx, ax
        jmp     .done                   ; no slot toggle for CONV_SINGLE

        ; --- 13. Slot toggle for ring and XMS_COPY+286/386 ---
.toggle:
        cmp     byte [g_tx_ring], 0
        je      .done                   ; XMS_COPY+286/386: already toggled during pre-arm
        xor     byte [xms_slot_idx], 1

.done:
        mov     sp, bp
        pop     bp
        ret

;------------------------------------------------------------------------------
; isr_wait_cmd -- bounded poll on CmdInProgress (EL3_ST_CMD_BUSY) after a slow command.
; in: DX = command/status register. Clobbers AX (CX preserved). Bounded so a wedged card
; can't hang the ISR.
;------------------------------------------------------------------------------
isr_wait_cmd:
        push    cx
        xor     cx, cx                  ; 65536-spin ceiling
.wc:    in      ax, dx
        test    ax, EL3_ST_CMD_BUSY
        jz      .wc_done
        loop    .wc
.wc_done:
        pop     cx
        ret
