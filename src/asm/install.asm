; install.asm -- TSR install + hardening (COLD; %included by start.asm). Never returns.
;
; Follows the Crynwr/tail.asm discipline: save the previous INT 60h vector (for chaining /
; uninstall), install ours, free the environment block to reclaim memory, then DOS
; terminate-and-stay-resident keeping PSP + the resident region only. The cold section
; (probe / ISA-PnP / composer / init) is linked above resident_end and reclaimed by keeping
; just ceil(resident_end/16)+PSP paragraphs -- currently ~6.4 KB resident (resident_end
; 0x18bc; ~1.4 KB of cold code reclaimed). Copy-down interleaving could trim further later.

install:
        ; Zero resident control flags that live in _TEXT (resb -- NOT load-zeroed by DOS) and are read
        ; before they are written. Done HERE: post-compose (the JIT writes resident_image, so a pre-compose
        ; clear doesn't survive) and pre-ISR-hook (before the vector below goes live). A non-zero
        ; xms_dma_armed makes the first runtime CONFIGURE return ALREADY_CFG -> the conv RX-DMA ring never
        ; arms and RX silently falls back to PIO; a non-zero g_isr_busy makes the ISR skip all RX. The TX
        ; ring counters get the same treatment in tx_ring_init. DS = resident segment.
        mov     byte [xms_dma_armed], 0
        mov     byte [xms_slot_idx], 0
        mov     byte [xms_nslots], 0
        mov     byte [g_rx_irq_masked], 0
        mov     byte [g_isr_busy], 0
        ; resident CPU gate for rx_drain_cksum (the ISR must not read g_cpu_class: cold BSS, freed below)
        mov     byte [g_rx_is386], 0
        cmp     byte [g_cpu_class], CPU_80386
        jb      .cpu_gate_set
        mov     byte [g_rx_is386], 1
.cpu_gate_set:
        ; Phase 2: bind the DMA cache-flush helper from the cold coherency verdict (g_flush_tier, set by
        ; phase_validate_coherency before us). WBINVD on a non-coherent 486+; a bare `ret` (cache_flush_none)
        ; otherwise -- coherent, a snooping cache, no cache, or the emulator. (FLUSH_TIER_EVICT, the non-
        ; coherent-386 software sweep, is deferred per docs/17 step 4 and never selected: a non-coherent
        ; cache with no safe flush drops the driver to the PIO floor instead.) A CFG_FORCE_FLUSH
        ; build forces WBINVD to prove that path executes harmlessly under TCG.
%ifdef CFG_FORCE_FLUSH
        mov     word [g_cache_flush_fn], cache_flush_wbinvd
%else
        mov     word [g_cache_flush_fn], cache_flush_none
        cmp     byte [g_flush_tier], FLUSH_TIER_WBINVD
        jne     .flush_set
        mov     word [g_cache_flush_fn], cache_flush_wbinvd
.flush_set:
%endif
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
        ; --- enable the card's interrupts (card left in Window 1 by el3_init) ---
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH
        cmp     byte [g_use_dma], 0     ; bus-master TX completes via TxComplete IRQ
        je      .intr_set
        or      ax, EL3_ST_TX_COMPLETE
.intr_set:
        out     dx, ax
        ; Status indication: the 8 classic sources, plus (bus-master only) DnComplete/UpComplete (bits 9/10).
        ; A real 3C515 neither shows nor interrupts on a source missing from this mask, so the DMA path needs
        ; them; the PIO floor leaves them out, which also keeps the ISR's UP_COMPLETE branch (it reads
        ; xms_dma_armed, freed memory there) unreachable.
        mov     ax, EL3_CMD_SET_STATUS_ENB | 0x00FF
        cmp     byte [g_use_dma], 0
        je      .stat_set
        mov     ax, EL3_CMD_SET_STATUS_ENB | 0x07FF
.stat_set:
        out     dx, ax

        ; arm bus-master TX DMA (386+ ring only): init the TX descriptors/slots. RX is PIO in all
        ; modes (no RX-DMA arm) -- bidirectional RX-DMA dropped ACKs; see the ISR RX-COMPLETE path.
        cmp     byte [g_use_dma], 0
        je      .no_dma
        call    tx_ring_init            ; any bus-master config: zero the ring counters (386+ copy ring
                                        ; AND the 286/386+ zero-copy async ring use them; the ISR reads
                                        ; tx_ring_count to tell a ring vs a single-transfer completion).
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
        mov     word [tx_completed], 0          ; async completion counter (BSS isn't load-zeroed)
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
