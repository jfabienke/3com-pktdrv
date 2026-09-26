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
        ; Drain the TX status stack HERE, in every mode. On a real 3C509 TxComplete is cleared ONLY by
        ; popping that stack (AckIntr doesn't touch it): a PIO TX error (underrun, 16 collisions, jabber)
        ; left undrained kept TxComplete up, and the .recv_done re-check looped forever with IF=0. (The
        ; emulator's AckIntr clears it, which hid this.) Bus-master: send_pkt no longer drains -- its pop
        ; would clear a TxComplete that latched while it ran, before this ISR could retire the ring slot.
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

        ; --- read the 14-byte header as seven FIFO words. This is also the access width
        ;     used by the 8088 payload fragment, and leaves the payload word-aligned. ---
        push    ds
        pop     es                      ; ES = DS = our segment, so stosw targets hdr_buf
        mov     dx, [g_w1_base]         ; Window-1 base = RX FIFO (FIFO is at +0 of the W1 block)
        mov     di, hdr_buf
        mov     cx, 7
.hdr:   in      ax, dx
        stosw
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
        mov     cx, 7
        rep     movsw                   ; 14 bytes from hdr_buf -> ES:DI; DI advances past header
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
        call    isr_wait_cmd            ; the card pops the frame while CmdInProgress is set: reading RX
                                        ; status before it clears sees the SAME frame again (Crynwr + Linux
                                        ; wait here; the emulator's discard is instant)
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
        ; --- 8088/286: four FIFO words per loop, preserving the ADC carry chain ---
        mov     bx, cx                          ; BX = byte count (for the odd-byte tail)
        shr     cx, 1                           ; CX = word count
        xor     si, si                          ; SI = 16-bit sum accumulator
        jcxz    .d16_tail
        shr     cx, 1
        shr     cx, 1                           ; CX = groups of four words
        jcxz    .d16_rem
        clc
.d16_u4:
        in      ax, dx
        adc     si, ax
        stosw
        in      ax, dx
        adc     si, ax
        stosw
        in      ax, dx
        adc     si, ax
        stosw
        in      ax, dx
        adc     si, ax
        stosw
        loop    .d16_u4                         ; IN/STOSW/LOOP preserve CF
        adc     si, 0                           ; fold carry before computing the remainder
        adc     si, 0
.d16_rem:
        mov     cx, bx
        shr     cx, 1
        and     cx, 3                           ; 0..3 remaining words
        jcxz    .d16_tail
        clc
.d16_r1:
        in      ax, dx
        adc     si, ax
        stosw
        loop    .d16_r1
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
