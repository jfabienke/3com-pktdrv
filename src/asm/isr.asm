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
        cmp     byte [g_use_dma], 0
        je      .no_txdone              ; PIO mode: no DMA (TxComplete just acked at .recv_done)
        cmp     byte [g_tx_ring], 0
        jne     .tx_ring_adv            ; 386+: advance the non-blocking TX ring
        mov     byte [g_tx_done], 1     ; 286 single-transfer: flag dma_tx_single's blocking wait
        jmp     .no_txdone
.tx_ring_adv:
        push    ax                      ; preserve adapter status (tx_kick clobbers ax)
        cmp     word [tx_ring_count], 0
        je      .tx_idle                ; spurious -- nothing queued
        dec     word [tx_ring_count]    ; the tail slot's DMA finished
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
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_ACK_INTR | 0x00FF   ; acknowledge all latched sources
        out     dx, ax
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
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        jae     .hdr_int15

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
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
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
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
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
        ; 386+ ring: toggle slot index AFTER delivery
        cmp     byte [g_tx_ring], 0
        je      .done                   ; 286: already toggled during pre-arm
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
