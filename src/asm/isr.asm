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

.recv_loop:
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        in      ax, dx                  ; adapter status
        test    ax, EL3_ST_RX_COMPLETE
        jz      .recv_done

        mov     dx, [g_nic_io]
        add     dx, EL3_W1_RX_STATUS
        in      ax, dx                  ; RX status: length + flags
        test    ah, 0x80                ; RX_INCOMPLETE (0x8000)
        jnz     .recv_done
        test    ah, 0x40                ; RX_ERROR (0x4000)
        jnz     .discard
        mov     cx, ax
        and     cx, EL3_RX_LEN_MASK     ; packet length

        ; receiver registered?
        mov     ax, [g_recv_off]
        or      ax, [g_recv_seg]
        jz      .discard

        ; --- upcall 1: AX=0 request a buffer; CX=len, BX=handle, ES:DI=0 ---
        push    cx
        xor     ax, ax
        mov     bx, 1
        xor     di, di
        mov     es, di
        call far [g_recv_off]           ; -> ES:DI = buffer (or 0:0)
        pop     cx
        mov     ax, es
        or      ax, di
        jz      .discard                ; null buffer -> drop

        ; --- drain CX bytes into ES:DI via the emitted rx fragment ---
        push    es
        push    di
        push    cx
        mov     ax, [g_off + FRAG_RX_PIO * 2]
        add     ax, resident_image
        call    ax
        pop     cx
        pop     si
        pop     ds                      ; DS:SI = buffer (es->ds, di->si)

        ; --- upcall 2: AX=1 deliver; DS:SI=buffer, CX=len, BX=handle ---
        mov     ax, 1
        mov     bx, 1
        call far [cs:g_recv_off]
        mov     ax, cs
        mov     ds, ax                  ; restore DS

.discard:
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_RX_DISCARD
        out     dx, ax
        jmp     .recv_loop

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
