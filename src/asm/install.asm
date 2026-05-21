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
