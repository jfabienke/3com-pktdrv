; resident_dma.asm -- DMA-only RESIDENT code (%included by start.asm just past resident_end_pio).
;
; Everything here is reached only with the bus-master path live (g_use_dma), so it sits in the DMA
; region: the PIO floor drops it (install keeps only up to resident_end_pio there), the 286 and 386+
; DMA keeps retain it. Callers in the always-resident region must gate on g_use_dma first.
;
; V86 bus-master addressing (Phase 2 review F5). Under a paging V86 host seg<<4 is not the bus address.
; The driver's own DMA span [tx_descs, resident_end) is VDS-proven identity (phys == seg<<4) and its lock
; held for the driver's lifetime (cold, dma_v86_forbid_check). A stack buffer posted through AH=F1
; (dma_tx_async) is VDS-locked per send here; the lock is released lazily when its ring slot is reused,
; and all of them at teardown. VDS (INT 4Bh) is only ever called from INT 60h task context, never from
; the ISR.

VDS_LOCK_REGION     equ 0x8103
VDS_UNLOCK_REGION   equ 0x8104
; DDS (DMA descriptor structure) layout, 16 bytes -- matches dos-nvmeotcp vds_dds_t
DDS_SIZE            equ 0           ; dword region size
DDS_OFFSET          equ 4           ; dword offset
DDS_SEGMENT         equ 8           ; word segment/selector
DDS_BUFID           equ 10          ; word buffer id (0 = locked in place, no VDS bounce buffer)
DDS_PHYS            equ 12          ; dword physical address
DDS_LEN             equ 16

;------------------------------------------------------------------------------
; vds_unlock_di -- VDS unlock of the DDS at CS:DI (no copy-back). Ignores the result. Clobbers AX, DX, ES.
;------------------------------------------------------------------------------
vds_unlock_di:
        push    cs
        pop     es
        mov     ax, VDS_UNLOCK_REGION
        xor     dx, dx
        int     0x4B
        ret

;------------------------------------------------------------------------------
; tx_v86_phys -- bus address for an AH=F1 frame under V86 (dma_tx_async, g_v86 = 1). Locks F_DS:F_SI,
; F_CX with VDS (DX=0: JEMM386 rejects the no-alloc flag; a bounce buffer shows up as buffer_id != 0 and
; is refused -- the card must read the caller's own bytes). Any failure -- no lock, a bounce buffer, or a
; physical end past 16 MB -- falls back to COPYING the frame into this ring slot's own tx_slots buffer
; (VDS-proven identity at install) and posting that, so the send still succeeds with CF=0 (the stack
; treats CF=1 as "ring full" and would retry forever).
; Enter: DS=CS, bp -> INT 60h frame, IF=0, slot [tx_ring_head] free. Out: DX:AX = bus address.
; Preserves BX; clobbers AX, CX, DX (SI/DI/ES saved).
;------------------------------------------------------------------------------
        cpu     386                             ; V86 implies a 386+ (and the ring requires one)
tx_v86_phys:
        push    bx
        push    si
        push    di
        push    es
        mov     si, [tx_ring_head]              ; SI = slot index
        mov     di, si
        mov     cl, 4
        shl     di, cl
        add     di, tx_vds_dds                  ; DI = &tx_vds_dds[head]
        ; the slot is free (count < N): release the lock its previous async post still holds
        cmp     byte [tx_vds_held + si], 0
        je      .lock
        call    vds_unlock_di
        mov     byte [tx_vds_held + si], 0
.lock:
        mov     ax, [bp + F_CX]
        mov     [di + DDS_SIZE], ax
        mov     ax, [bp + F_SI]
        mov     [di + DDS_OFFSET], ax
        mov     ax, [bp + F_DS]
        mov     [di + DDS_SEGMENT], ax
        xor     ax, ax
        mov     [di + DDS_SIZE + 2], ax
        mov     [di + DDS_OFFSET + 2], ax
        mov     [di + DDS_BUFID], ax
        mov     [di + DDS_PHYS], ax
        mov     [di + DDS_PHYS + 2], ax
        push    cs
        pop     es                              ; ES:DI = DDS
        mov     ax, VDS_LOCK_REGION
        xor     dx, dx
        stc                                     ; an unhooked INT 4Bh must read as failure
        int     0x4B
        jc      .copy                           ; CF alone signals failure (JEMM386 leaves AL != 0 on success)
        cmp     word [di + DDS_BUFID], 0
        jne     .unlock_copy                    ; VDS bounce buffer -> not the caller's memory
        mov     ax, [di + DDS_PHYS]
        mov     dx, [di + DDS_PHYS + 2]
        add     ax, [bp + F_CX]
        adc     dx, 0
        sub     ax, 1
        sbb     dx, 0                           ; DX:AX = last byte's physical address
        cmp     dx, 0x00FF
        ja      .unlock_copy                    ; past 16 MB -> ISA bus master can't reach it
        mov     byte [tx_vds_held + si], 1
        mov     ax, [di + DDS_PHYS]
        mov     dx, [di + DDS_PHYS + 2]
        jmp     .out
.unlock_copy:
        call    vds_unlock_di
.copy:
        ; fallback: copy the frame into tx_slots[head] and post the slot (phys = CS<<4 + off, proven)
        mov     ax, si
        mov     dx, TX_SLOT_SZ
        mul     dx                              ; AX = head * TX_SLOT_SZ (< 64 KB)
        mov     di, ax
        add     di, tx_slots                    ; DI = slot offset
        push    di
        push    cs
        pop     es                              ; ES:DI = slot
        mov     cx, [bp + F_CX]
        push    ds
        mov     ds, [bp + F_DS]
        mov     si, [bp + F_SI]
        cld
        mov     bx, cx
        shr     cx, 2
        rep     movsd
        mov     cx, bx
        and     cx, 3
        rep     movsb
        pop     ds                              ; DS = CS
        pop     di                              ; DI = slot offset
        mov     ax, cs
        mov     dx, ax
        shl     ax, 4
        shr     dx, 12
        add     ax, di
        adc     dx, 0                           ; DX:AX = phys(CS:slot)
.out:
        pop     es
        pop     di
        pop     si
        pop     bx
        ret
        cpu     8086

;------------------------------------------------------------------------------
; vds_release -- drop every VDS lock the driver holds: the per-slot AH=F1 locks and the resident DMA
; span lock. Real mode never takes any (all flags 0) -> a few compares. Clobbers AX, CX, DX, SI, DI, ES.
;------------------------------------------------------------------------------
vds_release:
        xor     si, si
        mov     di, tx_vds_dds
.rel_slot:
        cmp     byte [tx_vds_held + si], 0
        je      .rel_next
        call    vds_unlock_di
        mov     byte [tx_vds_held + si], 0
.rel_next:
        add     di, DDS_LEN
        inc     si
        cmp     si, TX_RING_N
        jb      .rel_slot
        cmp     byte [g_vds_span_held], 0
        je      .rel_done
        mov     di, tx_span_dds
        call    vds_unlock_di
        mov     byte [g_vds_span_held], 0
.rel_done:
        ret

;------------------------------------------------------------------------------
; xms_clear_held -- forget every in-place hold (configure / release). Clobbers AX, CX, DI, ES.
;------------------------------------------------------------------------------
xms_clear_held:
        push    cs
        pop     es
        mov     di, xms_held
        mov     cx, RX_RING_N
        xor     al, al
        cld
        rep     stosb
        mov     [xms_nheld], al
        ret

;------------------------------------------------------------------------------
; xms_release_held -- clear STATUS on every slot a receiver took in place (xms_held[i]) and let the
; upload engine continue: a real 3C515/Boomerang stalls on a still-complete descriptor, UpUnstall resumes
; it (the emulator re-offers the frame it was holding back). Enter DS=CS. Clobbers AX, BX, CX, DX, SI, ES.
;------------------------------------------------------------------------------
xms_release_held:
        mov     es, [g_desc_far + 2]
        mov     si, [g_desc_far]                ; ES:SI = &desc[0]
        xor     bx, bx
        mov     cl, [xms_nslots]
        xor     ch, ch
.rh_loop:
        cmp     byte [xms_held + bx], 0
        je      .rh_next
        mov     byte [xms_held + bx], 0
        xor     ax, ax
        mov     [es:si + EL3_DESC_STATUS], ax
        mov     [es:si + EL3_DESC_STATUS + 2], ax
.rh_next:
        add     si, EL3_DESC_SIZE
        inc     bx
        loop    .rh_loop
        mov     byte [xms_nheld], 0
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_UP_UNSTALL
        out     dx, ax
        ret

;------------------------------------------------------------------------------
; xms_release_core -- stop the armed RX ring: zero UpListPtr + StartDmaUp (a null list halts the upload
; engine), drop UP_COMPLETE from the interrupt mask, disarm, then restore the chipset NC region the
; configure marked (after the card has stopped DMAing into it) -- otherwise the block stays uncached after
; the stack frees the pool, slowing whatever DOS puts there next. Enter DS=CS, ring armed.
; Clobbers AX, CX, DX.
;------------------------------------------------------------------------------
xms_release_core:
        mov     dx, [g_nic_io]
        add     dx, EL3_CS_UP_LIST_PTR
        xor     ax, ax
        out     dx, ax
        add     dx, 2
        out     dx, ax
        mov     dx, [g_nic_io]
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_START_DMA_UP
        out     dx, ax
        mov     ax, EL3_CMD_SET_INTR_ENB | EL3_ST_RX_COMPLETE | EL3_ST_INT_LATCH | EL3_ST_TX_COMPLETE
        out     dx, ax                          ; (g_use_dma is set whenever a ring can be armed)
        mov     byte [xms_dma_armed], 0
        mov     byte [g_rx_irq_masked], 0
        call    xms_clear_held                  ; the ring is stopped: forget any in-place holds
        xor     ax, ax
        mov     [xms_cfg_off], ax
        mov     [xms_cfg_seg], ax
        cmp     byte [g_nc_marked], 0
        je      .done
        call    nc_clear_region
        mov     byte [g_nc_marked], 0
.done:
        ret

;------------------------------------------------------------------------------
; dma_teardown -- /u (f_uninstall) with the bus-master path live: stop an armed RX ring (and restore its
; NC region) so the card can't keep bus-mastering into the stack's buffer after the driver is gone, then
; release the VDS locks. Enter DS=CS. Clobbers AX, BX, CX, DX, SI, DI, ES.
;------------------------------------------------------------------------------
dma_teardown:
        cmp     byte [xms_dma_armed], 0
        je      .vds
        call    xms_release_core
.vds:
        call    vds_release
        ret
