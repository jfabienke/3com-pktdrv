; DMA-only resident entry points, kept after resident_end_pio.
; All callers gate these paths on g_use_dma or g_async before entering them.

;------------------------------------------------------------------------------
; dma_tx_enqueue -- non-blocking bus-master TX via a software ring (3C515, 386+ real mode).
; Copies the caller's frame into a free ring slot (so the caller can reuse its buffer per the
; Crynwr ABI), fills that slot's descriptor, bumps the ring, and -- if the card is idle -- kicks
; the DMA for the oldest queued slot. It does NOT wait for completion: the TxComplete ISR frees
; finished slots and kicks the next, so the CPU's frame-prep overlaps the card's DMA. Only blocks
; (sti/hlt, bounded by BIOS ticks) when the ring is full. INT 60h runs at IF=0, so the count/busy
; critical section is atomic wrt the ISR (which only fires once the caller restores IF=1).
; Enter: DS = CS, bp -> INT 60h frame (F_DS:F_SI = packet, F_CX = length <= TX_SLOT_SZ).
; Clobbers ax,bx,cx,dx,si,di,es. Leaves DS = CS, IF = 0.
;------------------------------------------------------------------------------
dma_tx_enqueue:
        ; wait for a free slot if the ring is full (bounded by elapsed BIOS ticks)
        xor     ax, ax
        mov     es, ax
        mov     bx, [es:BIOS_TICK_COUNT]        ; start tick for the full-wait timeout
.eq_wait:
        cmp     word [tx_ring_count], TX_RING_N
        jb      .eq_have
        mov     ax, [es:BIOS_TICK_COUNT]
        sub     ax, bx
        cmp     ax, EL3_DMA_TX_TICKS
        jae     .eq_full                        ; ring still full after the timeout -> drop
        sti                                     ; let the TxComplete ISR drain a slot
        hlt
        cli
        jmp     .eq_wait
.eq_full:
        inc     word [stat_txwait]              ; dropped: ring never drained (wedged card)
        ret
.eq_have:
        ; copy caller frame (F_DS:F_SI, F_CX bytes) into slot[head] = tx_slots + head*TX_SLOT_SZ
        mov     ax, [tx_ring_head]
        mul     word [g_tx_slot_sz]             ; dx:ax = head * slot size  (< 64 KB -> ax)
        mov     di, ax
        add     di, tx_slots
        mov     ax, cs
        mov     es, ax                          ; ES:DI = slot
        mov     cx, [bp + F_CX]
        push    ds
        mov     ds, [bp + F_DS]
        mov     si, [bp + F_SI]
        cld
        ; slot copy: the ring is 386+ only (286 uses the zero-copy single-transfer path), so always
        ; the 32-bit rep movsd. The per-element copy cost dominated the ring under -icount; wider wins.
        mov     bx, cx                          ; bx = byte count (for the 0..3-byte remainder)
        cpu     386
        shr     cx, 2                           ; dword count
        rep     movsd
        cpu     8086
        mov     cx, bx
        and     cx, 3                           ; trailing bytes
        rep     movsb
        pop     ds                              ; DS = CS again
        ; fill slot[head]'s descriptor: ADDR = phys(slot), LEN = len, STATUS = 0 (NEXT set at install).
        ; ADDR is re-stamped every time: an AH=F1 zero-copy post (dma_tx_async) shares these descriptors
        ; and leaves the CALLER's buffer address in ADDR, so a later send_pkt through the same slot would
        ; otherwise transmit that stale buffer (seen as the FIN after an async blast: CLOSE=FAIL).
        mov     bx, [tx_ring_head]
        mov     cl, 4
        shl     bx, cl                          ; head * 16
        add     bx, tx_descs
        mov     ax, [tx_ring_head]
        mul     word [g_tx_slot_sz]
        add     ax, tx_slots                    ; ax = slot offset
        mov     cx, cs
        mov     dx, cx
        cpu     386
        shl     cx, 4
        shr     dx, 12
        cpu     8086
        add     ax, cx
        adc     dx, 0                           ; dx:ax = phys(CS:slot)
        mov     [bx + EL3_DESC_ADDR], ax
        mov     [bx + EL3_DESC_ADDR + 2], dx
        mov     ax, [bp + F_CX]
        mov     [bx + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [bx + EL3_DESC_LEN + 2], ax
        mov     [bx + EL3_DESC_STATUS], ax
        mov     [bx + EL3_DESC_STATUS + 2], ax
        ; advance head (mod N), count++  (IF=0 here -> atomic wrt the ISR)
        mov     ax, [tx_ring_head]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .eq_hwrap
        xor     ax, ax
.eq_hwrap:
        mov     [tx_ring_head], ax
        inc     word [tx_ring_count]
        ; if the card is idle, kick the oldest queued slot
        cmp     byte [tx_dma_busy], 0
        jne     .eq_done
        call    tx_kick
.eq_done:
        ret

;------------------------------------------------------------------------------
; tx_kick -- start the bus-master DMA for the tail (oldest queued) slot: write its descriptor
; phys to DownListPtr and issue StartDmaDown. Sets tx_dma_busy. Enter DS=CS. Clobbers ax,bx,cx,dx.
;------------------------------------------------------------------------------
tx_kick:
        ; Phase 2: write back the frame bytes + descriptor before the bus master reads them (a write-back
        ; cache could still hold the CPU's writes). Coherent/write-through/emulator -> a bare `ret`. Helper
        ; preserves all GP regs + flags. (One flush per slot kick; a future opt could batch a burst.)
        call    word [g_cache_flush_fn]
        mov     bx, [tx_ring_tail]
        mov     cl, 4
        shl     bx, cl                          ; tail * 16
        add     bx, tx_descs                    ; bx = &desc[tail]
        ; phys(CS:bx) -> dx:ax
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        add     ax, bx
        adc     dx, 0                           ; dx:ax = phys(desc[tail])
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_DOWN_LIST_PTR
        out     dx, ax                          ; DownListPtr low
        pop     ax
        add     dx, 2
        out     dx, ax                          ; DownListPtr high
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_DOWN
        out     dx, ax
        mov     byte [tx_dma_busy], 1
        ret

;------------------------------------------------------------------------------
; dma_tx_async -- non-blocking ZERO-COPY bus-master TX (3C515, 386+). The async ABI's enqueue.
; Like dma_tx_enqueue but posts the caller's buffer (F_DS:F_SI) DIRECTLY as desc[head].ADDR -- no
; rep-movsd slot copy -- and returns CF=1 (ring full) WITHOUT blocking; the caller owns a buffer pool
; and throttles on tx_completed. Contract: the caller must not touch the buffer until its TxComplete
; bumps tx_completed past this post. IF=0 here (INT 60h) -> the count/busy update is atomic wrt the ISR.
; Enter: DS=CS, bp -> INT 60h frame (F_DS:F_SI = buffer, F_CX = length). Clobbers ax,bx,cx,dx.
; Returns: CF=0 queued, CF=1 ring full. Leaves DS=CS.
;------------------------------------------------------------------------------
dma_tx_async:
        cmp     word [tx_ring_count], TX_RING_N
        jb      .have
        stc                                     ; ring full -> caller throttles (no block)
        ret
.have:
        mov     bx, [tx_ring_head]
        mov     cl, 4
        shl     bx, cl                          ; head * 16
        add     bx, tx_descs                    ; bx = &desc[head]
        ; ADDR = phys(F_DS:F_SI): the card DMAs straight from the caller's pooled buffer (<1 MB, 24-bit).
        ; Under V86 seg<<4 is not the bus address -> VDS-lock the frame (tx_v86_phys, DMA region).
        cmp     byte [g_v86], 0
        jne     .v86_addr
        mov     ax, [bp + F_DS]
        mov     dx, ax
        mov     cl, 4
        shl     ax, cl                          ; ax = (seg << 4) low 16
        mov     cl, 12
        shr     dx, cl                          ; dx = seg >> 12 (high 4 bits of seg*16)
        add     ax, [bp + F_SI]
        adc     dx, 0                           ; dx:ax = phys(buffer)
.addr_set:
        mov     [bx + EL3_DESC_ADDR], ax
        mov     [bx + EL3_DESC_ADDR + 2], dx
        ; LEN = F_CX, STATUS = 0
        mov     ax, [bp + F_CX]
        mov     [bx + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [bx + EL3_DESC_LEN + 2], ax
        mov     [bx + EL3_DESC_STATUS], ax
        mov     [bx + EL3_DESC_STATUS + 2], ax
        ; advance head (mod N), count++
        mov     ax, [tx_ring_head]
        inc     ax
        cmp     ax, TX_RING_N
        jb      .hwrap
        xor     ax, ax
.hwrap:
        mov     [tx_ring_head], ax
        inc     word [tx_ring_count]
        ; kick the DMA if the card is idle
        cmp     byte [tx_dma_busy], 0
        jne     .ok
        call    tx_kick
.ok:
        clc
        ret
.v86_addr:
        call    tx_v86_phys                     ; dx:ax = VDS-locked phys (or the slot copy's); keeps bx
        jmp     .addr_set

;------------------------------------------------------------------------------
; dma_tx_single -- blocking zero-copy bus-master TX (3C515 Corkscrew, 286 real mode). The ring's
; per-frame slot copy costs more than a 286 can hide (no movsd; nothing to overlap in a flood), so
; the 286 instead DMAs straight from the caller's buffer: ~+47% at 100 Mbit vs the ring (28668 vs
; 19570 kbit/s). Builds the one-entry down descriptor (reusing tx_descs[0]; the ring is unused on a
; 286), writes DownListPtr, kicks StartDmaDown, then waits IRQ-driven for the TxComplete ISR to set
; g_tx_done before returning -- so the caller can't reuse/free the buffer while the card is still
; DMAing from it. INT 60h is entered with IF=0, so we sti/hlt to let the NIC IRQ fire, then cli. The
; wait is bounded by ELAPSED time (BIOS tick), not wakeup count, so RX IRQs during a TX flood can't
; make it bail before completion.
; Enter: DS = CS (resident), bp -> INT 60h frame (F_DS:F_SI = packet, F_CX = length).
; Both the descriptor and the caller's buffer live <1 MB, so phys = seg*16 + off is 24-bit safe.
; Clobbers ax,bx,cx,dx. Leaves DS = CS, IF = 0.
;------------------------------------------------------------------------------
dma_tx_single:
        ; caller buffer physical address (F_DS:F_SI) -> dx:ax
        mov     bx, [bp + F_DS]
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl                  ; ax = low 16 of (seg << 4)
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl                  ; dx = high 4 of (seg << 4)
        add     ax, [bp + F_SI]
        adc     dx, 0                   ; dx:ax = phys(buffer)
        mov     [tx_descs + EL3_DESC_ADDR], ax
        mov     [tx_descs + EL3_DESC_ADDR + 2], dx
        ; next = 0 (single transfer), status = 0, length high = 0
        xor     ax, ax
        mov     [tx_descs + EL3_DESC_NEXT], ax
        mov     [tx_descs + EL3_DESC_NEXT + 2], ax
        mov     [tx_descs + EL3_DESC_STATUS], ax
        mov     [tx_descs + EL3_DESC_STATUS + 2], ax
        mov     [tx_descs + EL3_DESC_LEN + 2], ax
        mov     ax, [bp + F_CX]         ; length (<= 1514 -> fits the 13-bit field)
        mov     [tx_descs + EL3_DESC_LEN], ax
        ; descriptor physical address (CS:tx_descs) -> dx:ax
        mov     bx, cs
        mov     ax, bx
        mov     cl, 4
        shl     ax, cl
        mov     dx, bx
        mov     cl, 12
        shr     dx, cl
        add     ax, tx_descs
        adc     dx, 0                   ; dx:ax = phys(descriptor)
        ; DownListPtr <- descriptor phys: two 16-bit OUTs (io+0x404 low, io+0x406 high)
        push    dx                      ; save high word
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_DOWN_LIST_PTR
        out     dx, ax                  ; low word
        pop     ax                      ; high word -> ax
        add     dx, 2
        out     dx, ax                  ; high word
        ; Phase 2: write back the caller's frame + the descriptor before the card reads them (write-back
        ; cache hazard). Coherent/write-through/emulator -> bare `ret`. Preserves all GP regs + flags.
        call    word [g_cache_flush_fn]
        ; arm completion, then kick StartDmaDown (cmd 0x14, param != 0)
        mov     byte [g_tx_done], 0     ; cleared with IF=0, so the ISR can't race ahead
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_DOWN
        out     dx, ax
        ; IRQ-driven wait: the TxComplete ISR sets g_tx_done. sti/hlt yields until an interrupt;
        ; spurious wakeups (RX during a TX flood) just re-loop -- the timeout is ELAPSED BIOS
        ; ticks, not a wakeup count, so only a wedged card escapes.
        xor     ax, ax
        mov     es, ax                  ; ES = 0 -> BIOS data area (frame restores ES on iret)
        mov     bx, [es:BIOS_TICK_COUNT]    ; start tick
.dma_wait:
        cmp     byte [g_tx_done], 0
        jne     .dma_done
        mov     ax, [es:BIOS_TICK_COUNT]
        sub     ax, bx                  ; elapsed ticks
        cmp     ax, EL3_DMA_TX_TICKS
        jae     .dma_timeout
        sti                             ; (sti has a 1-instr delay: no IRQ between sti and hlt)
        hlt
        jmp     .dma_wait
.dma_timeout:
        inc     word [stat_txwait]      ; no TxComplete in time (wedged card) -- counted, not fatal
.dma_done:
        cli                             ; restore the INT 60h handler's IF=0 invariant
        ret

;--- XMS DMA QUERY: return capability flags in BX, max slot size in DX ---
f_xms_query:
        ; CONV (conventional zero-copy ring) uses the same UpList DMA + in-place deliver as VCPI/DPMI,
        ; so advertise it alongside the base caps. Only reached with g_use_dma set (pkt_do_xms gate);
        ; VCPI/DPMI/RING additionally need the 386+ ring (CONFIGURE enforces the same split).
        mov     bx, XMS_CAP_XMS_COPY | XMS_CAP_SINGLE | XMS_CAP_CONV
        cmp     byte [g_tx_ring], 0
        je      .no_ring
        or      bx, XMS_CAP_RING | XMS_CAP_VCPI | XMS_CAP_DPMI
.no_ring:
        mov     [bp + F_BX], bx
        ; DX = the SLOT size the stack should use (also its CONV ring stride), not the max frame: 1536 =
        ; the max frame rounded up to a 32-byte multiple, so every CONV slot starts cache-line + paragraph
        ; aligned (xms_rx_deliver finds a slot's CPU segment as lin >> 4 and reads it at offset 0).
        mov     word [bp + F_DX], TX_SLOT_SZ
        cmp     byte [g_use_large], 0
        je      .q_slot
        mov     word [bp + F_DX], XMS_SLOT_LARGE     ; /j: a slot must hold an FDDI-sized frame
.q_slot:
        clc
        ret

;--- XMS DMA CONFIGURE: ES:DI -> xms_rx_cfg_t; build descriptors + arm UP_LIST_PTR ---
f_xms_configure:
        ; check not already armed
        cmp     byte [xms_dma_armed], 0
        jne     .ecfg
        ; ES:DI from caller's frame
        mov     bx, [bp + F_DI]         ; cfg offset
        mov     es, [bp + F_ES]         ; cfg segment  (ES saved on bp-frame)
        ; validate version (v1 = legacy: no descriptor block reserved -> never relocate / mark NC)
        mov     al, [es:bx + XMS_CFG_version]
        cmp     al, XMS_CFG_VERSION_MIN
        jb      .ever
        cmp     al, XMS_CFG_VERSION
        ja      .ever
        mov     [xms_cfg_ver], al
        ; validate policy (0=VCPI 1=DPMI 2=XMS_COPY 3=CONV; CONV = conventional-memory zero-copy ring)
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_MAX
        ja      .epol
        ; VCPI/DPMI (policies 0/1) are advertised only on the 386+ ring (QUERY) -> reject them without it
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_XMS_COPY
        jae     .pol_ok
        cmp     byte [g_tx_ring], 0
        je      .epol
.pol_ok:
        ; validate phys0 < 16 MB: byte[3] of the 32-bit physical address must be 0
        ; (if phys[31:24]=0 then phys ≤ 0x00FFFFFF = 16MB-1, within ISA DMA range)
        cmp     byte [es:bx + XMS_CFG_phys0 + 3], 0
        jne     .ephys
        ; validate phys1 < 16 MB
        cmp     byte [es:bx + XMS_CFG_phys1 + 3], 0
        jne     .ephys
        ; validate slot_size: 1..TX_SLOT_SZ (the QUERY value); the CONV/COMMONBUF ring is contiguous with
        ; stride = slot_size, so there it must also be a 32-byte multiple (a 1514 stride puts slots 1..N-1
        ; off a paragraph -> the lin >> 4 in-place delivery reads the wrong bytes)
        mov     ax, [es:bx + XMS_CFG_slot_size]
        or      ax, ax
        jz      .esz
        cmp     byte [g_use_large], 0
        je      .slot_std
        cmp     ax, EL3_MAX_FRAME_LARGE          ; /j: every slot must hold an FDDI-sized frame
        jb      .esz
        cmp     ax, XMS_SLOT_LARGE
        ja      .esz
        jmp     .slot_max
.slot_std:
        cmp     ax, TX_SLOT_SZ
        ja      .esz
.slot_max:
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_CONV
        jb      .slot_ok
        test    al, 0x1F
        jnz     .esz
.slot_ok:
        ; CONV/COMMONBUF: validate the contiguous span the driver will address. lin0 is a real-mode LINEAR
        ; (seg<<4) the ISR turns back into segments -> nonzero, paragraph-aligned, span below 1 MB; phys0 span
        ; below 16 MB (ISA bus master); CONV (real mode, identity) needs lin0 == phys0 and no V86 host.
        ; span = nslots*slot_size (+ the descriptor block a v2 producer reserves).
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_CONV
        jb      .span_ok
        mov     ax, 2                           ; 286 single-transfer: 2 slots
        cmp     byte [g_tx_ring], 0
        je      .span_n
        mov     ax, RX_RING_N                   ; 386+ deep ring
.span_n:
        mul     word [es:bx + XMS_CFG_slot_size]    ; AX = ring bytes (<= 8*1536, DX = 0)
        cmp     byte [xms_cfg_ver], 2
        jb      .span_v1
        add     ax, XMS_RX_DESC_BLOCK
.span_v1:
        mov     cx, ax
        dec     cx                              ; CX = span - 1
        mov     ax, [es:bx + XMS_CFG_lin0]
        mov     dx, [es:bx + XMS_CFG_lin0 + 2]
        test    al, 0x0F
        jnz     .elin
        mov     si, ax
        or      si, dx
        jz      .elin                           ; lin0 == 0
        add     ax, cx
        adc     dx, 0
        cmp     dx, 0x000F
        ja      .elin                           ; last byte >= 1 MB
        mov     ax, [es:bx + XMS_CFG_phys0]
        mov     dx, [es:bx + XMS_CFG_phys0 + 2]
        add     ax, cx
        adc     dx, 0
        cmp     dx, 0x00FF
        ja      .ephys                          ; last byte >= 16 MB
        cmp     byte [es:bx + XMS_CFG_policy], XMS_POLICY_CONV
        jne     .span_ok
        cmp     byte [g_v86], 0
        jne     .elin                           ; CONV under V86: seg<<4 is not the bus address
        mov     ax, [es:bx + XMS_CFG_lin0]
        cmp     ax, [es:bx + XMS_CFG_phys0]
        jne     .elin
        mov     ax, [es:bx + XMS_CFG_lin0 + 2]
        cmp     ax, [es:bx + XMS_CFG_phys0 + 2]
        jne     .elin
.span_ok:
        ; save config pointer + fields
        mov     ax, [es:bx + XMS_CFG_slot_size]
        mov     [xms_slot_sz], ax
        mov     al, [es:bx + XMS_CFG_policy]
        mov     [xms_rx_policy], al
        mov     [xms_cfg_off], bx
        mov     ax, es
        mov     [xms_cfg_seg], ax
        ; Phase 2 4b: descriptor-block location defaults = the cached CS-resident array (g_desc_far =
        ; CS:xms_rx_descs, g_desc_phys = phys of it) and the RX flush = the TX tier helper. The NC branch
        ; below overrides these (pool end + no RX flush) only once the pool is marked. Preserves ES:BX (= cfg).
        mov     word [g_desc_far], xms_rx_descs
        mov     [g_desc_far + 2], cs
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        mov     dx, cs
        mov     cl, 12
        shr     dx, cl
        add     ax, xms_rx_descs
        adc     dx, 0
        mov     [g_desc_phys], ax
        mov     [g_desc_phys + 2], dx
        mov     ax, [g_cache_flush_fn]
        mov     [g_rx_flush_fn], ax
        mov     byte [g_nc_marked], 0
        ; Phase 2 4b: when the cold re-test proved NC effective, fence the pool's 64 KB block NC FIRST and only
        ; if that succeeds relocate the descriptors into the pool end (past the slots, where a v2 producer
        ; reserves XMS_RX_DESC_BLOCK) and drop the per-drain RX flush -- the card then writes UP_COMPLETE and
        ; the payload into NC memory. Any miss (no NC, 286 2-slot, v1 pool, a span crossing a 64 KB boundary,
        ; an unknown chipset) leaves the default path above untouched: cached descriptors + the flush kept.
        cmp     byte [g_nc_effective], 0
        je      .desc_default
        cmp     byte [g_tx_ring], 0
        je      .desc_default
        cmp     byte [xms_cfg_ver], 2
        jb      .desc_default
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV
        jb      .desc_default                   ; CONV or COMMONBUF only (one contiguous physical pool)
        push    bx
        mov     ax, RX_RING_N
        mul     word [xms_slot_sz]
        add     ax, XMS_RX_DESC_BLOCK
        mov     cx, ax                          ; CX = pool span (slots + descriptor block)
        mov     ax, [es:bx + XMS_CFG_phys0]
        mov     dx, [es:bx + XMS_CFG_phys0 + 2]
        call    nc_span64                       ; BX = base_kb of the one 64 KB block holding it all
        jc      .nc_no
        call    nc_mark_region
        jc      .nc_no
        pop     bx
        mov     byte [g_nc_marked], 1
        mov     ax, RX_RING_N
        mul     word [xms_slot_sz]              ; dx:ax = RX_RING_N * slot_size = ring_bytes (fits ax; conv ring <64K)
        mov     cx, ax                          ; cx = ring_bytes (offset of the desc block past the slots)
        mov     ax, [es:bx + XMS_CFG_phys0]     ; g_desc_phys = phys0 + ring_bytes (card-facing, in the NC pool)
        add     ax, cx
        mov     dx, [es:bx + XMS_CFG_phys0 + 2]
        adc     dx, 0
        mov     [g_desc_phys], ax
        mov     [g_desc_phys + 2], dx
        mov     ax, [es:bx + XMS_CFG_lin0]      ; CPU linear of the desc block = lin0 + ring_bytes
        add     ax, cx
        mov     dx, [es:bx + XMS_CFG_lin0 + 2]
        adc     dx, 0                           ; dx:ax = lin0 + ring_bytes
        push    bx
        mov     bx, ax
        and     bx, 0x000F
        mov     [g_desc_far], bx               ; g_desc_far offset (32-aligned -> 0)
        pop     bx
        mov     cl, 4
        shr     ax, cl                          ; lin_lo >> 4
        mov     cl, 12
        shl     dx, cl                          ; lin_hi << 12
        or      ax, dx
        mov     [g_desc_far + 2], ax           ; g_desc_far segment
        mov     word [g_rx_flush_fn], cache_flush_none   ; descriptors now in NC -> drop the per-drain RX flush
        jmp     .desc_default
.nc_no:
        pop     bx
.desc_default:
        ; --- descriptor build: CONV uses ONE contiguous block (cfg.phys0 = base; slot i at base +
        ; i*slot_size), so it has its own builder (.build_conv) that derives every slot from the base --
        ; 386+ gets a deep RX_RING_N NEXT-chained ring, the 286 gets 2 contiguous single-transfer slots
        ; (cfg.phys1 is 0 for CONV, so the 2-slot-from-cfg path below MUST NOT be used for it). XMS_COPY/
        ; VCPI/DPMI keep the 2 explicit-from-cfg slots (phys0/phys1 = two separate EMBs). ---
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV
        je      .build_conv
        cmp     byte [xms_rx_policy], XMS_POLICY_COMMONBUF      ; VDS-locked conv ring (same contiguous builder)
        je      .build_conv
.build_2slot:
        mov     byte [xms_nslots], 2
        ; build descriptor 0: ADDR=phys0, LEN=slot_size, STATUS=0, NEXT set below
        mov     ax, [es:bx + XMS_CFG_phys0]
        mov     [xms_rx_desc0 + EL3_DESC_ADDR], ax
        mov     ax, [es:bx + XMS_CFG_phys0 + 2]
        mov     [xms_rx_desc0 + EL3_DESC_ADDR + 2], ax
        mov     ax, [xms_slot_sz]
        mov     [xms_rx_desc0 + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [xms_rx_desc0 + EL3_DESC_LEN + 2], ax
        mov     [xms_rx_desc0 + EL3_DESC_STATUS], ax
        mov     [xms_rx_desc0 + EL3_DESC_STATUS + 2], ax
        ; build descriptor 1: ADDR=phys1, LEN=slot_size, STATUS=0
        mov     ax, [es:bx + XMS_CFG_phys1]
        mov     [xms_rx_desc1 + EL3_DESC_ADDR], ax
        mov     ax, [es:bx + XMS_CFG_phys1 + 2]
        mov     [xms_rx_desc1 + EL3_DESC_ADDR + 2], ax
        mov     ax, [xms_slot_sz]
        mov     [xms_rx_desc1 + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [xms_rx_desc1 + EL3_DESC_LEN + 2], ax
        mov     [xms_rx_desc1 + EL3_DESC_STATUS], ax
        mov     [xms_rx_desc1 + EL3_DESC_STATUS + 2], ax
        ; set NEXT fields based on g_tx_ring (ring vs single-transfer)
        cmp     byte [g_tx_ring], 0
        je      .single_next
        ; 386+ ring: desc0.NEXT = desc1, desc1.NEXT = desc0 -- both from g_desc_phys (the card-facing base)
        mov     ax, [g_desc_phys]
        mov     dx, [g_desc_phys + 2]
        mov     [xms_rx_desc1 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc1 + EL3_DESC_NEXT + 2], dx
        add     ax, EL3_DESC_SIZE
        adc     dx, 0
        mov     [xms_rx_desc0 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc0 + EL3_DESC_NEXT + 2], dx
        jmp     .next_done
.single_next:
        ; 286 single-transfer: NEXT = 0 (no chain; ISR re-arms manually)
        xor     ax, ax
        mov     [xms_rx_desc0 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc0 + EL3_DESC_NEXT + 2], ax
        mov     [xms_rx_desc1 + EL3_DESC_NEXT], ax
        mov     [xms_rx_desc1 + EL3_DESC_NEXT + 2], ax
.next_done:
        ; pre-set GDT access bytes for INT 15h AH=87h (entries 2 and 3, src and dst)
        mov     byte [xms_gdt + 21], 0x93   ; source descriptor access byte (present, read/write)
        mov     byte [xms_gdt + 29], 0x93   ; destination descriptor access byte
        ; zero all other GDT bytes (entries 0,1,4,5)
        xor     ax, ax
        mov     [xms_gdt +  0], ax
        mov     [xms_gdt +  2], ax
        mov     [xms_gdt +  4], ax
        mov     [xms_gdt +  6], ax
        mov     [xms_gdt +  8], ax
        mov     [xms_gdt + 10], ax
        mov     [xms_gdt + 12], ax
        mov     [xms_gdt + 14], ax
        mov     word [xms_gdt + 16], 0   ; src limit
        mov     [xms_gdt + 18], ax       ; src base 0-15
        mov     [xms_gdt + 20], al       ; src base 16-23
        ; access byte [21] already set above
        mov     [xms_gdt + 22], ax       ; src base 24-31 / reserved
        mov     word [xms_gdt + 24], 0   ; dst limit
        mov     [xms_gdt + 26], ax       ; dst base 0-15
        mov     [xms_gdt + 28], al       ; dst base 16-23
        ; access byte [29] already set above
        mov     [xms_gdt + 30], ax       ; dst base 24-31 / reserved
        mov     [xms_gdt + 32], ax
        mov     [xms_gdt + 34], ax
        mov     [xms_gdt + 36], ax
        mov     [xms_gdt + 38], ax
        mov     [xms_gdt + 40], ax
        mov     [xms_gdt + 42], ax
        mov     [xms_gdt + 44], ax
        mov     [xms_gdt + 46], ax
        ; slot index = 0, no in-place holds
        mov     byte [xms_slot_idx], 0
        call    xms_clear_held
        ; close the copybreak autotune loop: hand the emulator our autotuned threshold T so its size-
        ; routing (len<=T -> PIO FIFO, len>T -> this DMA ring) matches the driver's live decision. The
        ; el3 model register at EL3_CS_RX_COPYBREAK consumes it; a real 3C515 ignores base+0x3C (the
        ; driver does the routing itself on real silicon), so this is a harmless write there.
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_RX_COPYBREAK
        mov     ax, [g_copybreak_t]
        out     dx, ax
        ; Phase 2 (docs/17 Piece 3, write side): write back the just-built descriptors (ADDR/LEN/STATUS)
        ; BEFORE the card can fetch them. On a write-back cache those writes could still sit in cache, so the
        ; bus master would read a STALE buffer address and DMA frames to the wrong physical memory. This runs
        ; after the NC mark (marking evicts nothing: lines cached before it stay dirty) and before UpListPtr
        ; is written (the upload engine may fetch as soon as it has a list pointer). It stays g_cache_flush_fn
        ; (not the droppable per-drain g_rx_flush_fn). Coherent / emulator -> a bare `ret`.
        call    word [g_cache_flush_fn]
        ; arm UP_LIST_PTR <- g_desc_phys (descriptor block base; phys(CS:xms_rx_descs) by default, the NC
        ; pool when relocated -- step 4b)
        mov     ax, [g_desc_phys]
        mov     dx, [g_desc_phys + 2]
        push    dx
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_UP_LIST_PTR
        out     dx, ax
        pop     ax
        add     dx, 2
        out     dx, ax
        ; issue StartDmaUp
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_UP
        out     dx, ax
        ; enable UP_COMPLETE interrupt (add to existing interrupt mask)
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH | EL3_ST_UP_COMPLETE
        cmp     byte [g_use_dma], 0
        je      .intr_no_tx
        or      ax, EL3_ST_TX_COMPLETE
.intr_no_tx:
        mov     [g_intr_enb_full], ax           ; save the full mask: ISR masks UP_COMPLETE out of it under
                                                ; load, pkt_xms_poll re-arms with it (NAPI livelock guard)
        mov     byte [g_rx_irq_masked], 0       ; start in interrupt mode
        out     dx, ax
        ; mark armed
        mov     byte [xms_dma_armed], 1
        mov     al, [g_nc_marked]       ; BX = 1 -> the pool is fenced NC, descriptors relocated, RX flush off
        xor     ah, ah
        mov     [bp + F_BX], ax
        mov     ax, cs
        mov     es, ax                  ; restore ES = our segment
        clc
        ret

        ; --- CONV builder: descriptors carved from the ONE contiguous block (cfg.phys0 = base; slot i at
        ; base + i*slot_size). Depth = RX_RING_N on a 386+ (ring-mode, NEXT-chained), or 2 on a 286 (single-
        ; transfer, NEXT=0 -> the ISR re-arms). ES:BX = cfg on entry. The running 32-bit slot phys is stashed
        ; in xms_gdt[0..3]: CONV never uses the INT 15h GDT, and .next_done overwrites it with the (unused-
        ; for-CONV) GDT setup afterward, so it is free cold scratch. ---
.build_conv:
        ; Phase 2 4b: g_lin_delta = cfg.lin0 - cfg.phys0 (the in-place delivery linear-vs-physical offset).
        ; 0 for CONV (lin0 == phys0, identity-mapped real mode); the V86 offset for COMMONBUF (lin0 = the
        ; V86 linear the CPU polls, phys0 = the VDS bus address). The ISR adds it to each descriptor phys.
        mov     ax, [es:bx + XMS_CFG_lin0]
        sub     ax, [es:bx + XMS_CFG_phys0]
        mov     [g_lin_delta], ax
        mov     ax, [es:bx + XMS_CFG_lin0 + 2]
        sbb     ax, [es:bx + XMS_CFG_phys0 + 2]
        mov     [g_lin_delta + 2], ax
        mov     byte [xms_nslots], 2            ; 286 single-transfer default
        cmp     byte [g_tx_ring], 0
        je      .conv_depth_set
        mov     byte [xms_nslots], RX_RING_N    ; 386+ deep ring
.conv_depth_set:
        mov     ax, [es:bx + XMS_CFG_phys0]     ; running slot phys := phys0 (contiguous block base)
        mov     [xms_gdt + 0], ax
        mov     ax, [es:bx + XMS_CFG_phys0 + 2]
        mov     [xms_gdt + 2], ax
        xor     bx, bx                          ; i = 0 (BX = loop counter; cfg no longer needed)
        les     si, [g_desc_far]               ; ES:SI = &desc[0] (CS:xms_rx_descs, or the NC pool when relocated)
.cloop:
        mov     ax, [xms_gdt + 0]               ; ADDR = running slot phys
        mov     [es:si + EL3_DESC_ADDR], ax
        mov     ax, [xms_gdt + 2]
        mov     [es:si + EL3_DESC_ADDR + 2], ax
        mov     ax, [xms_slot_sz]               ; LEN = slot_size (high word 0)
        mov     [es:si + EL3_DESC_LEN], ax
        xor     ax, ax
        mov     [es:si + EL3_DESC_LEN + 2], ax
        mov     [es:si + EL3_DESC_STATUS], ax   ; STATUS = 0
        mov     [es:si + EL3_DESC_STATUS + 2], ax
        ; NEXT: 386+ ring -> g_desc_phys + ((i+1) mod nslots)*EL3_DESC_SIZE; 286 single-transfer -> 0
        cmp     byte [g_tx_ring], 0
        jne     .cnext_ring
        xor     ax, ax
        mov     [es:si + EL3_DESC_NEXT], ax
        mov     [es:si + EL3_DESC_NEXT + 2], ax
        jmp     .cnext_done
.cnext_ring:
        mov     al, bl                          ; next = (i+1) mod nslots
        inc     al
        cmp     al, [xms_nslots]
        jb      .cnowrap
        xor     al, al
.cnowrap:
        mov     ah, EL3_DESC_SIZE
        mul     ah                              ; ax = next * EL3_DESC_SIZE (next <= RX_RING_N-1 -> fits AL*AH)
        add     ax, [g_desc_phys]               ; NEXT = g_desc_phys + next*EL3_DESC_SIZE (the card-facing base)
        mov     dx, [g_desc_phys + 2]
        adc     dx, 0
        mov     [es:si + EL3_DESC_NEXT], ax
        mov     [es:si + EL3_DESC_NEXT + 2], dx
.cnext_done:
        mov     ax, [xms_slot_sz]               ; running slot phys += slot_size
        add     [xms_gdt + 0], ax
        adc     word [xms_gdt + 2], 0
        add     si, EL3_DESC_SIZE
        inc     bx
        cmp     bl, [xms_nslots]
        jb      .cloop
        jmp     .next_done

.ever:  mov     dh, XMS_ERR_BAD_VERSION
        jmp     .err
.epol:  mov     dh, XMS_ERR_BAD_POLICY
        jmp     .err
.ephys: mov     dh, XMS_ERR_PHYS_RANGE
        jmp     .err
.esz:   mov     dh, XMS_ERR_SLOT_SIZE
        jmp     .err
.elin:  mov     dh, XMS_ERR_BAD_LIN
        jmp     .err
.ecfg:  mov     dh, XMS_ERR_ALREADY_CFG
.err:   mov     ax, cs
        mov     es, ax
        stc
        ret

;--- XMS DMA RELEASE: stop DMA, clear UP_LIST_PTR, disarm ---
f_xms_release:
        cmp     byte [xms_dma_armed], 0
        je      .enot
        call    xms_release_core                ; stop up-DMA, disarm, restore NC (DMA region)
        clc
        ret
.enot:  mov     dh, XMS_ERR_NOT_CFG
        stc
        ret

;--- XMS DMA POLL (AL=0x03): NAPI drain. The ISR masks UP_COMPLETE under RX load (so the interrupt can't
;    preempt-starve the stack's net_poll -> receive livelock) and defers the work here. Drain EVERY
;    completed conv-ring slot from task context -- driven by the descriptor STATUS bit, so it's immune to
;    the el3 coalescing several slot-completions into one UP_COMPLETE int bit -- then re-arm the IRQ. The
;    stack calls this from net_poll when its receiver ring runs dry. DS=CS. No CF error. ---
f_xms_poll:
        cmp     byte [xms_dma_armed], 0
        je      .p_ret                  ; ring not configured -> nothing to drain
        ; Hold off ISR reentrancy on the shared receiver ring while we drain + upcall (the ISR honours
        ; g_isr_busy and no-ops; the level-triggered source re-fires after we clear it).
        mov     byte [g_isr_busy], 1
        ; Release the slots the receiver took IN PLACE at the previous poll: it calls us again only after
        ; consuming (and releasing) every frame we handed it, so their STATUS can be cleared now -- before
        ; the batched flush below, which then also writes the cleared descriptors back to memory.
        cmp     byte [xms_nheld], 0
        je      .p_noheld
        call    xms_release_held
.p_noheld:
        ; Phase 2: ONE batched cache invalidate before reading any descriptor STATUS or slot payload, so a
        ; non-coherent cache doesn't spin on a stale descriptor (the card wrote UP_COMPLETE) or read a stale
        ; slot. Coherent/emulator -> a bare `ret` (nil cost). Helper preserves all GP regs + flags. RX-side,
        ; so g_rx_flush_fn: drops to none once the descriptors live in the NC pool (step 4b relocation).
        call    word [g_rx_flush_fn]
.p_loop:
        mov     al, [xms_slot_idx]      ; desc[idx] via g_desc_far (CS:xms_rx_descs, or the NC pool when relocated)
        mov     ah, EL3_DESC_SIZE
        mul     ah
        mov     es, [g_desc_far + 2]
        mov     si, [g_desc_far]
        add     si, ax
        test    word [es:si + EL3_DESC_STATUS], EL3_DESC_UP_COMPLETE
        jz      .p_drained              ; current slot not filled -> ring drained
        call    xms_rx_deliver          ; deliver desc[xms_slot_idx] (upcall); advances xms_slot_idx
        ; 286 2-slot ping-pong: delivering a slot re-arms the OTHER one, which must not still be held --
        ; so at most one in-place frame per poll there (the receiver releases it before polling again)
        cmp     byte [g_tx_ring], 0
        jne     .p_loop
        cmp     byte [xms_nheld], 0
        jne     .p_drained
        jmp     .p_loop
.p_drained:
        mov     byte [g_isr_busy], 0
        ; re-arm UP_COMPLETE if the ISR masked it (return to interrupt mode now the ring is empty)
        cmp     byte [g_rx_irq_masked], 0
        je      .p_ret
        mov     byte [g_rx_irq_masked], 0
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, [g_intr_enb_full]   ; SetIntrEnb with UP_COMPLETE re-enabled
        out     dx, ax
.p_ret:
        clc
        ret

