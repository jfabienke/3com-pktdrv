; install.asm -- TSR install + hardening (COLD; %included by start.asm). Never returns.
;
; Follows the Crynwr/tail.asm discipline: save the previous INT 60h vector (for chaining /
; uninstall), install ours, free the environment block to reclaim memory, then DOS
; terminate-and-stay-resident keeping PSP + the resident region only. The cold section
; (probe / ISA-PnP / composer / init) is linked above resident_end and reclaimed by keeping
; just ceil(resident_end/16)+PSP paragraphs -- currently ~6.4 KB resident (resident_end
; 0x18bc; ~1.4 KB of cold code reclaimed). Copy-down interleaving could trim further later.

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

        ; --- record our IRQ line's current PIC mask bit so uninstall can restore it exactly
        ;     (a line already unmasked -- e.g. shared -- must be left unmasked, not re-masked) ---
        mov     cl, [g_nic_irq]
        mov     dx, 0x21                        ; master mask port
        cmp     cl, 8
        jb      .save_mask
        sub     cl, 8
        mov     dx, 0xA1                        ; slave mask port
.save_mask:
        mov     ah, 1
        shl     ah, cl
        in      al, dx
        and     al, ah                          ; isolate our bit
        mov     [pic_mask_orig], al             ; 0 = was unmasked, nonzero = was masked

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
        ; save IRQ2's current mask bit, then unmask the master IRQ2 cascade (a slave IRQ can't
        ; reach the CPU without it). Uninstall restores IRQ2 to this saved state.
        in      al, 0x21                        ; master mask
        mov     ah, al
        and     ah, 0x04                        ; isolate IRQ2 cascade bit (bit 2)
        mov     [pic_casc_orig], ah             ; 0 = IRQ2 was unmasked, nonzero = was masked
        and     al, 0xFB                        ; unmask IRQ2 cascade on the master
        out     0x21, al
.pic_done:
        ; --- enable the card's interrupts (card left in Window 1 by el3_init) ---
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH
        cmp     byte [g_use_dma], 0     ; bus-master TX completes via TxComplete IRQ
        je      .intr_set
        or      ax, EL3_ST_TX_COMPLETE
.intr_set:
        out     dx, ax
        mov     ax, EL3_CMD_SET_STATUS_ENB | 0x00FF
        out     dx, ax

        ; arm bus-master TX DMA (386+ ring only): init the TX descriptors/slots. RX is PIO in all
        ; modes (no RX-DMA arm) -- bidirectional RX-DMA dropped ACKs; see the ISR RX-COMPLETE path.
        cmp     byte [g_use_dma], 0
        je      .no_dma
        mov     byte [g_tx_in_flight], 0 ; clear re-entrance guard before TSR activates
        cmp     byte [g_tx_ring], 0
        je      .no_dma                 ; 286 single-transfer: nothing to arm (RX is PIO, no ring)
        call    tx_ring_init            ; 386+ ring: init the TX descriptors/slots
.no_dma:

        ; free our environment block (PSP[2Ch] = environment segment)
        mov     es, [psp_seg]
        mov     es, [es:0x2C]
        mov     ah, 0x49
        int     0x21

        ; terminate-and-stay-resident. Keep PSP + the RESIDENT region only (handler, ISR,
        ; resident state, emitted datapath); the cold composer/probe/init is reclaimed. Three keep
        ; boundaries: PIO floor (no DMA) drops the whole TX-DMA region; 286 DMA keeps tx_descs +
        ; XMS state (resident_end_xms_single) and drops the ring's TX slots; 386+ ring DMA keeps
        ; everything through the TX slots + ring vars. (RX is PIO in all modes -- no RX-DMA buffer.)
        ;   paragraphs = PSP(0x10) + ceil(boundary / 16)
        mov     ax, resident_end_pio            ; PIO floor: drop the whole bus-master DMA region
        cmp     byte [g_use_dma], 0
        je      .keep_calc
        mov     ax, resident_end_xms_single     ; 286 single-transfer DMA: keep XMS state, drop TX ring slots
        cmp     byte [g_tx_ring], 0
        je      .keep_calc
        mov     ax, resident_end                ; 386+ ring DMA: keep through the TX slots + ring vars
.keep_calc:
        add     ax, 15
        mov     cl, 4
        shr     ax, cl
        add     ax, 0x10                        ; + PSP (256 bytes)
%ifdef CFG_DEBUG
        push    ax
        mov     dx, msg_keep
        call    print_str
        pop     ax
        push    ax
        call    print_hex16                     ; resident paragraphs
        mov     dx, msg_inst
        call    print_str
        mov     al, [irq_vec]
        xor     ah, ah
        call    print_hex16                     ; NIC IRQ vector number
        mov     dx, msg_crlf
        call    print_str
        pop     ax
%endif
        mov     dx, ax
        mov     ax, 0x3100                      ; AH=31h TSR, AL=0
        int     0x21

;------------------------------------------------------------------------------
; tx_ring_init -- one-time init of the non-blocking TX ring (DMA mode). Each slot's descriptor
; gets a fixed buffer phys (= slot phys) and NEXT/STATUS=0; head/tail/count/busy are zeroed.
; send_pkt only fills LEN per frame thereafter. Cold (called from install); DS=CS. Clobbers regs.
;------------------------------------------------------------------------------
tx_ring_init:
        mov     word [tx_ring_head], 0
        mov     word [tx_ring_tail], 0
        mov     word [tx_ring_count], 0
        mov     byte [tx_dma_busy], 0
        mov     si, tx_descs                    ; descriptor walker
        mov     di, tx_slots                    ; slot walker
        mov     bx, TX_RING_N                   ; remaining slots
.tri_loop:
        mov     ax, cs                          ; phys(CS:di) -> dx:ax
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        add     ax, di
        adc     dx, 0
        mov     [si + EL3_DESC_ADDR], ax
        mov     [si + EL3_DESC_ADDR + 2], dx
        xor     ax, ax
        mov     [si + EL3_DESC_NEXT], ax
        mov     [si + EL3_DESC_NEXT + 2], ax
        mov     [si + EL3_DESC_STATUS], ax
        mov     [si + EL3_DESC_STATUS + 2], ax
        add     si, EL3_DESC_SIZE
        add     di, TX_SLOT_SZ
        dec     bx
        jnz     .tri_loop
        ret
