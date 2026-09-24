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

        ; --- switch to a private stack ---
        mov     [isr_save_ss], ss
        mov     [isr_save_sp], sp
        mov     ss, ax                  ; SS = our segment (ax = cs)
        mov     sp, isr_stack_top

        ; --- reentrancy guard ---
        cmp     byte [g_isr_busy], 0
        jne     .eoi
        inc     byte [g_isr_busy]
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
        ; Ack TxComplete HERE, where it is serviced (every mode). .recv_done's blanket ack leaves it out:
        ; a completion latched between the loop's last status read and that ack was cleared unserviced
        ; -> the ring's in-flight frame never retired, tx_dma_busy stuck at 1, every later send_pkt
        ; waited out its timeout and dropped (a timing-dependent TX wedge).
        push    ax
        mov     ax, EL3_CMD_ACK_INTR | EL3_ST_TX_COMPLETE
        out     dx, ax
        pop     ax
        cmp     byte [g_use_dma], 0
        je      .no_txdone              ; PIO: send_pkt drains the TX status stack
        ; bus-master: drain the TX status stack HERE (send_pkt no longer does -- its pop would clear a
        ; TxComplete that latched while it ran, before this ISR could retire the ring slot)
        push    ax
        push    cx
        push    dx
        call    tx_status_drain
        pop     dx
        pop     cx
        pop     ax
        cmp     byte [g_use_dma], 0
        je      .no_txdone              ; PIO mode: no DMA (TxComplete just acked at .recv_done)
        cmp     word [tx_ring_count], 0 ; ring frames in flight? (386+ copy ring OR 286/386+ async ring)
        jne     .tx_ring_adv            ; yes -> advance the ring (frees a slot, kicks the next)
        mov     byte [g_tx_done], 1     ; no -> a blocking single-transfer (286 send_pkt) completed
        jmp     .no_txdone
.tx_ring_adv:
        push    ax                      ; preserve adapter status (tx_kick clobbers ax)
        cmp     word [tx_ring_count], 0
        je      .tx_idle                ; spurious -- nothing queued
        dec     word [tx_ring_count]    ; the tail slot's DMA finished
        inc     word [tx_completed]     ; ASYNC ext: publish completion so the stack can reuse the buffer
        mov     ax, [tx_ring_tail]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .tx_twrap
        xor     ax, ax
.tx_twrap:
        mov     [tx_ring_tail], ax
        cmp     word [tx_ring_count], 0
        je      .tx_idle                ; ring drained
        call    tx_kick                 ; more queued -> start the next slot's DMA
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
        ; NAPI: don't drain the conv ring in the ISR -- a fast wire would re-fire UP_COMPLETE faster than
        ; the stack's net_poll can process, starving it (receive livelock). Instead MASK UP_COMPLETE and
        ; hand the drain to the task (pkt_xms_poll, AL=0x03), which re-arms when the ring empties. Skip if
        ; already masked (a drain is pending). The .recv_done AckIntr (0x07FF) still clears int_status.
        cmp     byte [g_rx_irq_masked], 0
        jne     .no_updone
        mov     byte [g_rx_irq_masked], 1
        push    ax
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, [g_intr_enb_full]
        and     ax, ~EL3_ST_UP_COMPLETE & 0xFFFF   ; SetIntrEnb with UP_COMPLETE cleared
        out     dx, ax
        pop     dx
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
        cmp     byte [g_rx_cksum], 0
        jne     .drain_cksum            ; RX checksum offload on -> summing drain (AH=0xF2)
        mov     ax, [g_off + FRAG_RX_PIO * 2]
        add     ax, resident_image
        call    ax                      ; drain remaining bytes into ES:DI
        jmp     .delivered
.drain_cksum:
        call    rx_drain_cksum          ; CX=count, ES:DI=dest -> drain + fold sum into g_rx_cksum_val

.delivered:
        ; --- upcall 2: AX=1 deliver; DS:SI=buffer, CX=len, BX=handle ---
        mov     si, [appbuf_off]
        mov     cx, [rx_len]
        mov     bx, [cur_handle]
        mov     ax, 1
        cmp     byte [g_rx_cksum], 0
        je      .deliver_go
        mov     dx, [g_rx_cksum_val]    ; RXCK_FEAT_IPSUM: hand the folded IP+TCP+payload sum to the receiver in DX
.deliver_go:
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
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_ACK_INTR | (0x07FF & ~EL3_ST_TX_COMPLETE)
                                                ; ack all latched sources (11-bit field: incl
                                                ; UpComplete bit 10 / DnComplete bit 9 -- 0x00FF
                                                ; left the bus-master RX IRQ un-acked -> storm)
                                                ; EXCEPT TxComplete, acked only where serviced
        out     dx, ax
        ; A TxComplete that latched after the loop's last read is still pending: service it now. The
        ; PIC is edge-triggered, so leaving with it latched (line already high) would never re-interrupt.
        in      ax, dx
        test    ax, EL3_ST_TX_COMPLETE
        jnz     .recv_loop
        dec     byte [g_isr_busy]
.eoi:
        ; restore the interrupted task's stack
        mov     ss, [isr_save_ss]
        mov     sp, [isr_save_sp]
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
; On 286 (single-transfer, g_tx_ring=0): re-arms the OTHER slot and issues StartDmaUp
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

        ; --- 1. Select completed slot's descriptor: desc[xms_slot_idx] (array-indexed -> handles the
        ; 2-slot ping-pong AND the deep CONV ring uniformly). At entry xms_slot_idx = the completed slot
        ; for every path (the cycle/286-toggle happens later). ---
        mov     al, [xms_slot_idx]
        mov     ah, EL3_DESC_SIZE
        mul     ah                      ; ax = idx * EL3_DESC_SIZE (idx <= RX_RING_N-1 -> fits AL*AH)
        mov     es, [g_desc_far + 2]    ; ES:SI = &desc[idx] (CS:xms_rx_descs, or the NC pool when relocated)
        mov     si, [g_desc_far]
        add     si, ax
        mov     [bp-8], si              ; save the offset (ES reloaded from g_desc_far where it's clobbered)

        ; --- 2. Verify UP_COMPLETE in descriptor STATUS ---
        mov     ax, [es:si + EL3_DESC_STATUS]
        test    ax, EL3_DESC_UP_COMPLETE
        jz      .done

        ; --- 3. Frame length from STATUS[12:0] ---
        and     ax, EL3_DESC_LEN_MASK
        mov     [rx_len], ax
        cmp     ax, 14
        jb      .discard

        ; --- 4. 286 single-transfer: pre-arm OTHER slot before processing ---
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
        mov     ax, di
        sub     ax, xms_rx_desc0        ; 0 or EL3_DESC_SIZE
        add     ax, [g_desc_phys]
        mov     dx, [g_desc_phys + 2]
        adc     dx, 0                   ; dx:ax = phys(new descriptor) = g_desc_phys + idx*EL3_DESC_SIZE
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
        ; --- 5. Load phys from the completed descriptor; derive lin_seg ---
        ; The descriptor ADDR field holds the slot phys for EVERY policy (f_xms_configure wrote it), so
        ; this works for the deep CONV ring (slots 2..N-1 aren't in the 2-entry cfg) and is identical to
        ; cfg.phys0/phys1 for the 2-slot paths.
        mov     si, [bp-8]              ; completed descriptor ptr (offset)
        mov     es, [g_desc_far + 2]   ; ES = descriptor segment (reload; cleared on some delivery paths)
        mov     ax, [es:si + EL3_DESC_ADDR]
        mov     [bp-2], ax              ; phys_lo
        mov     cx, [es:si + EL3_DESC_ADDR + 2]
        mov     [bp-4], cx              ; phys_hi
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV
        je      .lin_conv
        cmp     byte [xms_rx_policy], XMS_POLICY_COMMONBUF
        jne     .lin_from_cfg
.lin_conv:
        ; CONV/COMMONBUF: the slot is delivered IN PLACE; the CPU's segment = lin >> 4 where lin = the
        ; descriptor's bus phys + g_lin_delta. Delta is 0 for CONV (identity-mapped real mode) and the V86
        ; linear-vs-physical offset for COMMONBUF (VDS-locked under a paging VMM). conv buffer < 1 MB so the
        ; result fits a 16-bit segment.
        mov     ax, [bp-2]              ; phys_lo
        add     ax, [g_lin_delta]
        mov     dx, [bp-4]              ; phys_hi
        adc     dx, [g_lin_delta + 2]  ; dx:ax = lin (CPU V86 linear of the slot)
        mov     cl, 4
        shr     ax, cl                  ; ax = lin_lo >> 4
        mov     cl, 12
        shl     dx, cl                  ; dx = lin_hi << 12  (lin < 1 MB -> lin_hi <= 0x000F)
        or      ax, dx
        mov     [bp-6], ax              ; lin_seg
        jmp     .addrs_got
.lin_from_cfg:
        ; VCPI/DPMI (lin = V86 mapping) / XMS_COPY (lin unused): take lin from the 2-entry cfg.
        push    es
        mov     es, [xms_cfg_seg]
        mov     bx, [xms_cfg_off]
        cmp     si, xms_rx_desc0
        jne     .lin1
        mov     di, [es:bx + XMS_CFG_lin0]
        mov     dx, [es:bx + XMS_CFG_lin0 + 2]
        jmp     .lin_got
.lin1:
        mov     di, [es:bx + XMS_CFG_lin1]
        mov     dx, [es:bx + XMS_CFG_lin1 + 2]
.lin_got:
        pop     es
        ; lin_seg = ((lin_hi << 12) | (lin_lo >> 4))  -- valid because lin_N is page-aligned
        mov     cl, 12
        shl     dx, cl
        mov     cl, 4
        shr     di, cl
        or      di, dx
        mov     [bp-6], di              ; lin_seg
.addrs_got:

        ; --- 6. Read 14-byte Ethernet header into hdr_buf ---
        ; ONLY XMS_COPY (slot in XMS) needs INT 15h; VCPI/DPMI/CONV slots are CPU-addressable at lin_seg:0
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        je      .hdr_int15

        ; VCPI/DPMI: read 14 bytes from lin_seg:0 into hdr_buf
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
        ; Every CPU-addressable slot is offered IN PLACE as the hint lin_seg:0 (VCPI/DPMI/CONV/COMMONBUF);
        ; only XMS_COPY (slot not CPU-addressable) asks for the receiver's own buffer. A receiver that
        ; returns the hint takes the slot in place (no copy) and holds it until its next AH=F0/03 poll --
        ; the slot's STATUS is left complete (the upload engine stalls on it, the emulator backpressures)
        ; and released at the top of that poll (xms_release_held). A receiver that returns its OWN buffer
        ; gets the one-pass copy (step 9) and the slot is recycled at once, as before.
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        je      .up1_no_hint
        jb      .up1_hint               ; VCPI/DPMI: always hinted (the original in-place path)
        cmp     byte [xms_cfg_ver], 3   ; CONV/COMMONBUF: only a v3 producer queues in-place slots
        jb      .up1_no_hint            ; (an older receiver's single hint slot would be overrun)
.up1_hint:
        mov     es, [bp-6]              ; hint: the slot itself, lin_seg:0
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
        mov     byte [xms_inplace], 0
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        je      .copy_dispatch
        ; hinted slot (VCPI/DPMI/CONV/COMMONBUF): taken in place (returned exactly the hint lin_seg:0)?
        or      di, di
        jnz     .copy_dispatch
        mov     ax, es
        cmp     ax, [bp-6]
        jne     .copy_dispatch
        mov     byte [xms_inplace], 1
        jmp     .no_copy

.copy_dispatch:
        ; --- 9. Frame copy into the receiver buffer (the one mandatory payload-extraction pass):
        ; VCPI/DPMI reference the slot in place (no copy); XMS_COPY copies via INT 15h (XMS slot not
        ; CPU-addressable); CONV copies via a fast rep movs (conv slot IS addressable -> no INT 15h). ---
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        jb      .no_copy                ; VCPI/DPMI: in-place reference
        ja      .conv_copy              ; CONV declined the hint: rep movs conv-slot -> appbuf
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
        xor     dx, dx                  ; DX = 0: no RX checksum-offload sum for DMA frames (AH=F2 sums
                                        ; only the PIO drain; 0 is never a real folded sum -> the stack
                                        ; falls back to its own verify instead of trusting garbage)
        mov     ds, [appbuf_seg]
        call far [cs:bx]
        mov     ax, cs
        mov     ds, ax
        inc     word [stat_rx]
        cmp     byte [xms_inplace], 0
        je      .release_now
        ; in place: leave STATUS complete (the receiver still reads the slot); release at the next poll
        mov     bl, [xms_slot_idx]
        cmp     byte [g_tx_ring], 0
        jne     .held_idx
        xor     bl, 1                   ; 286: the pre-arm already toggled idx -> the completed slot is the other
.held_idx:
        xor     bh, bh
        mov     byte [xms_held + bx], 1
        inc     byte [xms_nheld]
        jmp     .advance

.discard:
        inc     word [stat_rxdrop]      ; receiver declined the frame (0:0) or runt
.release_now:
        ; --- 11. Clear completed slot STATUS ---
        mov     si, [bp-8]              ; completed descriptor ptr (offset)
        mov     es, [g_desc_far + 2]   ; ES = descriptor segment (reload; the hdr/lin paths clobbered ES)
        xor     ax, ax
        mov     [es:si + EL3_DESC_STATUS], ax
        mov     [es:si + EL3_DESC_STATUS + 2], ax
.advance:
        ; 386+ ring: advance to the next slot AFTER delivery -- (idx+1) mod nslots. nslots=2 for the
        ; XMS_COPY ring (cycles 0/1) and RX_RING_N for the deep CONV ring (0..N-1).
        cmp     byte [g_tx_ring], 0
        je      .done                   ; 286: already advanced during pre-arm
        mov     al, [xms_slot_idx]
        inc     al
        cmp     al, [xms_nslots]
        jb      .idx_ok
        xor     al, al
.idx_ok:
        mov     [xms_slot_idx], al

.done:
        mov     sp, bp
        pop     bp
        ret

.conv_copy:
        ; CONV one-pass copy: conventional slot (lin_seg:0, CPU-addressable) -> receiver buffer (appbuf).
        ; Done HERE in the ISR (before the STATUS clear + re-arm below), so the slot is fully read before
        ; the emulator can recycle it -- no deferred-read race, and no INT 15h (fast rep movs). DS=CS in,
        ; DS=CS out. All DS-relative operands are read before DS is repointed at the slot.
        mov     ax, [bp-6]              ; lin_seg (conv slot segment)
        mov     es, [appbuf_seg]        ; ES:DI = receiver buffer (copy destination)
        mov     di, [appbuf_off]
        mov     cx, [rx_len]
        mov     ds, ax                  ; DS:SI = conv slot, offset 0
        xor     si, si
        shr     cx, 1                   ; word count (CF = odd trailing byte)
        rep     movsw
        jnc     .conv_dn
        movsb
.conv_dn:
        push    cs
        pop     ds                      ; restore DS = CS
        jmp     .no_copy                ; -> Upcall 2 (deliver appbuf)

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

;------------------------------------------------------------------------------
; rx_drain_cksum -- drain CX bytes from the RX FIFO into ES:DI while folding the 16-bit ones-complement
; sum (native-LE) of the drained bytes into [g_rx_cksum_val] (RX checksum offload, AH=0xF2). Mirrors
; cksum16/cksum32: continuous-carry-fold chain (IN/STOS/LOOP preserve CF). On real ISA hardware the
; `adc` hides behind the ~1 us `in`, so the checksum is nearly free; the stack then skips its
; whole-segment verify pass. In: CX=byte count, ES:DI=dest, DS=resident, DF=0. CPU-gated (insd vs insw).
; Clobbers AX BX CX DX SI (EAX/EBX saved+restored on the 386 path). DI advances past the drained bytes.
;------------------------------------------------------------------------------
rx_drain_cksum:
        mov     dx, [g_w1_base]                 ; DX = RX FIFO port (Window-1 base + 0)
        cmp     byte [g_rx_is386], 0            ; resident copy: g_cpu_class is cold BSS, freed at install
        je      .d16
cpu 386
        ; --- 386+: 32-bit insd burst + 32-bit carry-fold (0x66-prefixed; only runs on 386+) ---
        push    eax                             ; preserve upper halves (ISR only saved the 16-bit regs)
        push    ebx
        push    cx                              ; save byte count for the <4-byte tail
        shr     cx, 2                           ; CX = whole-dword count
        xor     ebx, ebx                        ; EBX = 32-bit sum accumulator
        jcxz    .d32_folded
        clc
.d32_lp:
        in      eax, dx                         ; read a dword from the FIFO
        adc     ebx, eax                        ; fold into the running sum
        stosd                                   ; copy to ES:DI
        loop    .d32_lp                         ; IN/STOSD/LOOP preserve CF -> carry chain holds
        adc     ebx, 0                          ; fold the pending 2^32 carry
        adc     ebx, 0
.d32_folded:
        mov     eax, ebx
        shr     eax, 16
        add     bx, ax                          ; BX += high 16 bits
        adc     bx, 0
        adc     bx, 0                           ; BX = folded 16-bit sum of the dword body
        pop     cx                              ; CX = original byte count
        and     cx, 3                           ; CX = leftover bytes (0..3)
        test    cx, 2
        jz      .d32_byte
        in      ax, dx                          ; trailing word
        add     bx, ax
        adc     bx, 0
        stosw
.d32_byte:
        test    cx, 1
        jz      .d32_store
        in      al, dx                          ; trailing odd byte (native low position)
        xor     ah, ah
        add     bx, ax
        adc     bx, 0
        stosb
.d32_store:
        mov     [g_rx_cksum_val], bx
        pop     ebx                             ; restore upper halves (value already saved)
        pop     eax
        ret
cpu 8086
.d16:
        ; --- 8088/286: 16-bit insw + carry-fold ---
        mov     bx, cx                          ; BX = byte count (for the odd-byte tail)
        shr     cx, 1                           ; CX = word count
        xor     si, si                          ; SI = 16-bit sum accumulator
        jcxz    .d16_tail
        clc
.d16_lp:
        in      ax, dx
        adc     si, ax
        stosw
        loop    .d16_lp                         ; IN/STOSW/LOOP preserve CF
        adc     si, 0
        adc     si, 0
.d16_tail:
        test    bx, 1
        jz      .d16_store
        in      al, dx                          ; trailing odd byte
        xor     ah, ah
        add     si, ax
        adc     si, 0
        stosb
.d16_store:
        mov     [g_rx_cksum_val], si
        ret
