; DMA-only receive delivery, kept after resident_end_pio.
; Called only by f_xms_poll while the DMA extension is configured.

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

        ; --- 1. Select completed slot's descriptor: desc[xms_slot_idx] (array-indexed -> handles the
        ; 2-slot ping-pong AND the deep CONV ring uniformly). At entry xms_slot_idx = the completed slot
        ; for every path (the cycle/286-toggle happens later). ---
        mov     al, [xms_slot_idx]
        mov     ah, EL3_DESC_SIZE
        mul     ah                      ; ax = idx * EL3_DESC_SIZE (idx <= RX_RING_N-1 -> fits AL*AH)
        mov     es, [g_desc_far + 2]    ; ES:SI = &desc[idx] (CS:xms_rx_descs, or the NC pool when relocated)
        mov     si, [g_desc_far]
        add     si, ax
        mov     [bp-8], si              ; save the offset (ES reloaded from g_desc_far where it's clobbered)

        ; --- 2. Verify UP_COMPLETE in descriptor STATUS ---
        mov     ax, [es:si + EL3_DESC_STATUS]
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
        mov     ax, di
        sub     ax, xms_rx_desc0        ; 0 or EL3_DESC_SIZE
        add     ax, [g_desc_phys]
        mov     dx, [g_desc_phys + 2]
        adc     dx, 0                   ; dx:ax = phys(new descriptor) = g_desc_phys + idx*EL3_DESC_SIZE
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
        mov     ax, [rx_len]
        cmp     ax, [xms_slot_sz]
        ja      .discard                ; longer than the posted slot (the card truncated it) -> drop
                                        ; (after the 286 pre-arm, so the other slot stays armed)
        ; --- 5. Load phys from the completed descriptor; derive lin_seg ---
        ; The descriptor ADDR field holds the slot phys for EVERY policy (f_xms_configure wrote it), so
        ; this works for the deep CONV ring (slots 2..N-1 aren't in the 2-entry cfg) and is identical to
        ; cfg.phys0/phys1 for the 2-slot paths.
        mov     si, [bp-8]              ; completed descriptor ptr (offset)
        mov     es, [g_desc_far + 2]   ; ES = descriptor segment (reload; cleared on some delivery paths)
        mov     ax, [es:si + EL3_DESC_ADDR]
        mov     [bp-2], ax              ; phys_lo
        mov     cx, [es:si + EL3_DESC_ADDR + 2]
        mov     [bp-4], cx              ; phys_hi
        cmp     byte [xms_rx_policy], XMS_POLICY_CONV
        je      .lin_conv
        cmp     byte [xms_rx_policy], XMS_POLICY_COMMONBUF
        jne     .lin_from_cfg
.lin_conv:
        ; CONV/COMMONBUF: the slot is delivered IN PLACE; the CPU's segment = lin >> 4 where lin = the
        ; descriptor's bus phys + g_lin_delta. Delta is 0 for CONV (identity-mapped real mode) and the V86
        ; linear-vs-physical offset for COMMONBUF (VDS-locked under a paging VMM). conv buffer < 1 MB so the
        ; result fits a 16-bit segment.
        mov     ax, [bp-2]              ; phys_lo
        add     ax, [g_lin_delta]
        mov     dx, [bp-4]              ; phys_hi
        adc     dx, [g_lin_delta + 2]  ; dx:ax = lin (CPU V86 linear of the slot)
        mov     cl, 4
        shr     ax, cl                  ; ax = lin_lo >> 4
        mov     cl, 12
        shl     dx, cl                  ; dx = lin_hi << 12  (lin < 1 MB -> lin_hi <= 0x000F)
        or      ax, dx
        mov     [bp-6], ax              ; lin_seg
        jmp     .addrs_got
.lin_from_cfg:
        ; VCPI/DPMI (lin = V86 mapping) / XMS_COPY (lin unused): take lin from the 2-entry cfg.
        push    es
        mov     es, [xms_cfg_seg]
        mov     bx, [xms_cfg_off]
        cmp     si, xms_rx_desc0
        jne     .lin1
        mov     di, [es:bx + XMS_CFG_lin0]
        mov     dx, [es:bx + XMS_CFG_lin0 + 2]
        jmp     .lin_got
.lin1:
        mov     di, [es:bx + XMS_CFG_lin1]
        mov     dx, [es:bx + XMS_CFG_lin1 + 2]
.lin_got:
        pop     es
        ; lin_seg = ((lin_hi << 12) | (lin_lo >> 4))  -- valid because lin_N is page-aligned
        mov     cl, 12
        shl     dx, cl
        mov     cl, 4
        shr     di, cl
        or      di, dx
        mov     [bp-6], di              ; lin_seg
.addrs_got:

        ; --- 6. Read 14-byte Ethernet header into hdr_buf ---
        ; ONLY XMS_COPY (slot in XMS) needs INT 15h; VCPI/DPMI/CONV slots are CPU-addressable at lin_seg:0
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        je      .hdr_int15

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
        ; Every CPU-addressable slot is offered IN PLACE as the hint lin_seg:0 (VCPI/DPMI/CONV/COMMONBUF);
        ; only XMS_COPY (slot not CPU-addressable) asks for the receiver's own buffer. A receiver that
        ; returns the hint takes the slot in place (no copy) and holds it until its next AH=F0/03 poll --
        ; the slot's STATUS is left complete (the upload engine stalls on it, the emulator backpressures)
        ; and released at the top of that poll (xms_release_held). A receiver that returns its OWN buffer
        ; gets the one-pass copy (step 9) and the slot is recycled at once, as before.
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        je      .up1_no_hint
        jb      .up1_hint               ; VCPI/DPMI: always hinted (the original in-place path)
        cmp     byte [xms_cfg_ver], 3   ; CONV/COMMONBUF: only a v3 producer queues in-place slots
        jb      .up1_no_hint            ; (an older receiver's single hint slot would be overrun)
.up1_hint:
        mov     es, [bp-6]              ; hint: the slot itself, lin_seg:0
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
        mov     byte [xms_inplace], 0
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        je      .copy_dispatch
        ; hinted slot (VCPI/DPMI/CONV/COMMONBUF): taken in place (returned exactly the hint lin_seg:0)?
        or      di, di
        jnz     .copy_dispatch
        mov     ax, es
        cmp     ax, [bp-6]
        jne     .copy_dispatch
        mov     byte [xms_inplace], 1
        jmp     .no_copy

.copy_dispatch:
        ; --- 9. Frame copy into the receiver buffer (the one mandatory payload-extraction pass):
        ; VCPI/DPMI reference the slot in place (no copy); XMS_COPY copies via INT 15h (XMS slot not
        ; CPU-addressable); CONV copies via a fast rep movs (conv slot IS addressable -> no INT 15h). ---
        cmp     byte [xms_rx_policy], XMS_POLICY_XMS_COPY
        jb      .no_copy                ; VCPI/DPMI: in-place reference
        ja      .conv_copy              ; CONV declined the hint: rep movs conv-slot -> appbuf
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
        xor     dx, dx                  ; DX = 0: no RX checksum-offload sum for DMA frames (AH=F2 sums
                                        ; only the PIO drain; 0 is never a real folded sum -> the stack
                                        ; falls back to its own verify instead of trusting garbage)
        mov     ds, [appbuf_seg]
        call far [cs:bx]
        mov     ax, cs
        mov     ds, ax
        inc     word [stat_rx]
        cmp     byte [xms_inplace], 0
        je      .release_now
        ; in place: leave STATUS complete (the receiver still reads the slot); release at the next poll
        mov     bl, [xms_slot_idx]
        cmp     byte [g_tx_ring], 0
        jne     .held_idx
        xor     bl, 1                   ; 286: the pre-arm already toggled idx -> the completed slot is the other
.held_idx:
        xor     bh, bh
        mov     byte [xms_held + bx], 1
        inc     byte [xms_nheld]
        jmp     .advance

.discard:
        inc     word [stat_rxdrop]      ; receiver declined the frame (0:0) or runt
.release_now:
        ; --- 11. Clear completed slot STATUS ---
        mov     si, [bp-8]              ; completed descriptor ptr (offset)
        mov     es, [g_desc_far + 2]   ; ES = descriptor segment (reload; the hdr/lin paths clobbered ES)
        xor     ax, ax
        mov     [es:si + EL3_DESC_STATUS], ax
        mov     [es:si + EL3_DESC_STATUS + 2], ax
.advance:
        ; 386+ ring: advance to the next slot AFTER delivery -- (idx+1) mod nslots. nslots=2 for the
        ; XMS_COPY ring (cycles 0/1) and RX_RING_N for the deep CONV ring (0..N-1).
        cmp     byte [g_tx_ring], 0
        je      .done                   ; 286: already advanced during pre-arm
        mov     al, [xms_slot_idx]
        inc     al
        cmp     al, [xms_nslots]
        jb      .idx_ok
        xor     al, al
.idx_ok:
        mov     [xms_slot_idx], al

.done:
        mov     sp, bp
        pop     bp
        ret

.conv_copy:
        ; CONV one-pass copy: conventional slot (lin_seg:0, CPU-addressable) -> receiver buffer (appbuf).
        ; Done HERE in the ISR (before the STATUS clear + re-arm below), so the slot is fully read before
        ; the emulator can recycle it -- no deferred-read race, and no INT 15h (fast rep movs). DS=CS in,
        ; DS=CS out. All DS-relative operands are read before DS is repointed at the slot.
        mov     ax, [bp-6]              ; lin_seg (conv slot segment)
        mov     es, [appbuf_seg]        ; ES:DI = receiver buffer (copy destination)
        mov     di, [appbuf_off]
        mov     cx, [rx_len]
        mov     ds, ax                  ; DS:SI = conv slot, offset 0
        xor     si, si
        shr     cx, 1                   ; word count (CF = odd trailing byte)
        rep     movsw
        jnc     .conv_dn
        movsb
.conv_dn:
        push    cs
        pop     ds                      ; restore DS = CS
        jmp     .no_copy                ; -> Upcall 2 (deliver appbuf)

