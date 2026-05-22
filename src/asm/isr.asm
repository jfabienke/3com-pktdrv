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
        test    ax, EL3_ST_ADAPTER_FAILURE
        jnz     .adapter_fail
        test    ax, EL3_ST_RX_COMPLETE
        jz      .recv_done

        mov     dx, [g_w1_base]
        add     dx, EL3_W1_RX_STATUS
        in      ax, dx                  ; RX status: length + flags
        test    ah, 0x80                ; RX_INCOMPLETE (0x8000)
        jnz     .recv_done
        test    ah, 0x40                ; RX_ERROR (0x4000)
        jnz     .rxerr
        mov     cx, ax
        and     cx, EL3_RX_LEN_MASK     ; CX = packet length
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
