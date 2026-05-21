; install.asm -- TSR install + hardening (COLD; %included by start.asm). Never returns.
;
; Follows the Crynwr/tail.asm discipline: save the previous INT 60h vector (for chaining /
; uninstall), install ours, free the environment block to reclaim memory, then DOS
; terminate-and-stay-resident keeping the (tiny) image. Cold-section reclaim via copy-down
; is a later optimization; the floor keeps the whole image (~2.5 KB).

install:
        ; save the previous owner of the packet interrupt
        mov     ax, 0x3500 | PKTINT             ; AH=35h get-vector
        int     0x21                            ; -> ES:BX
        mov     [old_int_off], bx
        mov     [old_int_seg], es

        ; install our handler (DS = our segment already)
        mov     dx, pkt_handler
        mov     ax, 0x2500 | PKTINT             ; AH=25h set-vector
        int     0x21

        ; --- hook the NIC IRQ vector ---
        ; IRQ 0-7 -> vector 08h+irq (master); IRQ 8-15 -> vector 70h+(irq-8) (slave)
        mov     al, [g_nic_irq]
        cmp     al, 8
        jae     .irq_slave
        add     al, 8
        jmp     .irq_set
.irq_slave:
        add     al, 0x68                        ; 0x70 + (irq - 8)
.irq_set:
        mov     [irq_vec], al
        mov     ah, 0x35                        ; save old IRQ vector (AL=vec -> ES:BX)
        int     0x21
        mov     [old_irq_off], bx
        mov     [old_irq_seg], es
        mov     al, [irq_vec]
        mov     dx, nic_isr
        mov     ah, 0x25                        ; install our ISR
        int     0x21

        ; --- unmask the IRQ at the 8259 PIC ---
        mov     cl, [g_nic_irq]
        cmp     cl, 8
        jae     .pic_slave
        mov     ah, 1
        shl     ah, cl
        not     ah
        in      al, 0x21                        ; master mask
        and     al, ah
        out     0x21, al
        jmp     .pic_done
.pic_slave:
        sub     cl, 8
        mov     ah, 1
        shl     ah, cl
        not     ah
        in      al, 0xA1                        ; slave mask
        and     al, ah
        out     0xA1, al
        in      al, 0x21                        ; also unmask IRQ2 cascade on the master
        and     al, 0xFB
        out     0x21, al
.pic_done:
        ; --- enable the card's RX-complete interrupt (card left in Window 1 by el3_init) ---
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH
        out     dx, ax
        mov     ax, EL3_CMD_SET_STATUS_ENB | 0x00FF
        out     dx, ax

        ; free our environment block (PSP[2Ch] = environment segment)
        mov     es, [psp_seg]
        mov     es, [es:0x2C]
        mov     ah, 0x49
        int     0x21

        ; terminate-and-stay-resident. Keep PSP..top-of-stack = the whole tiny image:
        ;   paragraphs = (SS - PSP) + stack_size/16
        mov     ax, ss
        sub     ax, [psp_seg]
        add     ax, STACK_PARAS                 ; stack is 1024 B = 64 paragraphs
        mov     dx, ax
        mov     ax, 0x3100                      ; AH=31h TSR, AL=0
        int     0x21
