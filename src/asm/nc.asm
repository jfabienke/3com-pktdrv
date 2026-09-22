; nc.asm -- non-cacheable (NC) DMA-region marking, RESIDENT primitives (Phase 2 step 4, docs/12+13+17).
;
; OPT-IN ONLY (/n switch -> g_want_nc) and only ever reached when the cold coherency self-test found the
; cache NON-coherent. On a coherent / snooping / no-cache machine (and the QEMU emulator) the self-test
; reads fresh, g_flush_tier stays NONE, NC is never attempted, and none of this runs. The point of NC: on a
; non-coherent 486 ISA board, fencing the DMA ring non-cacheable via the chipset KEN# control removes the
; per-drain WBINVD (~250 us) entirely -- the only real-mode NC mechanism (MTRRs are P6+, PCD needs paging).
;
; SAFETY MODEL (why this ships despite unverified encodings):
;   1. The encodings are LIFTED FROM cache-kit, which has NEVER run on real hardware and flags the in-scope
;      ISA ops (OPTi/UMC/Eteq) "VERIFY on 86Box vs datasheet" -- a historical 4x base-unit error (16 KB vs
;      64 KB units) fenced the WRONG region. So they are RESEARCH-GRADE, not field-proven.
;   2. The driver never trusts them blind: NC is gated by a RE-TEST (phase_validate_coherency re-runs the
;      MAC-loopback probe AFTER marking the region NC; the flush is dropped ONLY if it then reads fresh).
;      A wrong size-code -> the ring stays cacheable -> the re-test reads STALE -> the flush is KEPT. A bad
;      encoding costs the optimization, never correctness.
;   3. The residual risk the re-test can't cover is a WRONG-DEVICE write (misdetection programs 0x22/0x24 on
;      something else). That is why this is OPT-IN (default off): the stock driver never writes a chipset
;      config register. Enable /n only on a board you have validated.
;
; Chipset config space = an index/data port pair the cache controller exposes: OPTi family = 0x22(index)/
; 0x24(data); UMC + SiS legacy = 0x22(index)/0x23(data). Write the register number to 0x22, then the value
; to the data port. Base addresses are in 64 KB units (A23:A16); size is a power-of-two code per family.
;
; REGION POLICY: exactly ONE naturally aligned 64 KB block (review F2). The base registers are in 64 KB
; units, and many decoders mask the base by the size, so a smaller region can only start on a 64 KB boundary
; and a larger one may silently cover a different, size-aligned block. One aligned 64 KB block is correct
; under either decode and pins a single size code per chipset -- the SAME (base, code) shape the cold re-test
; proves, so the live marking reuses a proven encoding. A span crossing a 64 KB boundary gets no NC (CF=1 ->
; the caller keeps the flush). nc_mark_region saves the chipset's previous region-0 registers and
; nc_clear_region restores them (writing 0 could clobber other bits in the SiS/UMC control registers).
;
; Placed in the DMA region (past resident_end_pio): only the cold probe and f_xms_configure/release reach it.
; CONTRACT: nc_span64 clobbers AX,BX,CX,DX; nc_mark_region / nc_clear_region clobber AX,BX,CX,DX (SI saved).

NC_CHIP_NONE        equ 0
NC_CHIP_OPTI391     equ 1       ; OPTi 82C391 / 82C596-7 Viper / 82C381 -- 0x22/0x24
NC_CHIP_ETEQ        equ 2       ; Eteq 82C495WB Bengal -- OPTi-compatible encoding, 0x22/0x24
NC_CHIP_UMC491      equ 3       ; UMC UM82C491 -- 0x22/0x23, 1 region
NC_CHIP_SIS460      equ 4       ; SiS 85C460 / 85C310 Rabbit -- 0x22/0x23
NC_CHIP_SYNTH       equ 0xFE    ; synthetic (CFG_FORCE_NC structural test): no port write, mark always "works"

; per chipset: id, base reg, size reg, data port, size value for ONE 64 KB block
;   OPTi/Eteq: size reg = (code<<4) | A27:A24 nibble, region = 8 KB << (code-1) -> code 4 (nibble 0: <16 MB)
;   UMC:       size reg = 0x80(enable) | (code<<4), region = 8 KB << code       -> code 3
;   SiS:       ctrl reg high nibble = code, region = 64 KB << (code-1)          -> code 1
; !!! base unit UNVERIFIED on real silicon (cache-kit: 64 KB vs 16 KB) -- the cold re-test catches a wrong one.
NC_ENT_LEN          equ 5
nc_tab:
        db      NC_CHIP_OPTI391, 0x52, 0x53, 0x24, 0x40
        db      NC_CHIP_ETEQ,    0x52, 0x53, 0x24, 0x40
        db      NC_CHIP_UMC491,  0x50, 0x51, 0x23, 0xB0
        db      NC_CHIP_SIS460,  0x14, 0x15, 0x23, 0x10
NC_TAB_N            equ 4

;------------------------------------------------------------------------------
; nc_span64 -- the NC block for a physical span. in: DX:AX = phys start, CX = length (> 0). out: CF=0 ->
; BX = base_kb of the single 64 KB block holding the WHOLE span (< 16 MB); CF=1 -> it crosses a 64 KB
; boundary (or reaches past 16 MB): no NC for it. Clobbers AX,BX,CX,DX.
;------------------------------------------------------------------------------
nc_span64:
        mov     bx, dx                          ; BX = start block (phys >> 16)
        dec     cx
        add     ax, cx
        adc     dx, 0                           ; DX = last byte's block
        cmp     dx, bx
        jne     .x
        cmp     bx, 0x00FF
        ja      .x                              ; base field is A23:A16
        mov     cl, 6
        shl     bx, cl                          ; base_kb
        clc
        ret
.x:     stc
        ret

;------------------------------------------------------------------------------
; nc_mark_region -- fence the 64 KB block at BX = base_kb (64 KB aligned, < 16 MB) non-cacheable on
; g_nc_chipset (region 0), saving the registers it overwrites. out: CF=0 programmed; CF=1 unknown chipset
; -> caller MUST keep the flush. Clobbers AX,BX,CX,DX.
;------------------------------------------------------------------------------
nc_mark_region:
        cmp     byte [g_nc_chipset], NC_CHIP_SYNTH
        je      .ok                             ; structural test: succeed, touch no port
        push    si
        call    nc_find
        jc      .pop
        mov     cl, [si + 1]
        call    nc_rd
        mov     [nc_saved_base], al
        mov     cl, [si + 2]
        call    nc_rd
        mov     [nc_saved_size], al
        mov     byte [nc_saved_ok], 1
        mov     ax, bx
        mov     cl, 6
        shr     ax, cl                          ; AL = base in 64 KB units
        mov     ch, al
        mov     cl, [si + 1]
        call    nc_wr                           ; base first ...
        mov     ch, [si + 4]
        mov     cl, [si + 2]
        call    nc_wr                           ; ... then the size/enable that turns the region on
        clc
.pop:   pop     si
        ret
.ok:    clc
        ret

;------------------------------------------------------------------------------
; nc_clear_region -- restore region 0 to what nc_mark_region found (no-op if nothing is saved).
; Clobbers AX,CX,DX. Resident.
;------------------------------------------------------------------------------
nc_clear_region:
        cmp     byte [nc_saved_ok], 0
        je      .r
        push    si
        call    nc_find
        jc      .pop
        mov     cl, [si + 2]
        mov     ch, [nc_saved_size]
        call    nc_wr                           ; size/enable first (turns our region off) ...
        mov     cl, [si + 1]
        mov     ch, [nc_saved_base]
        call    nc_wr                           ; ... then the base
        mov     byte [nc_saved_ok], 0
.pop:   pop     si
.r:     ret

;------------------------------------------------------------------------------
; helpers. nc_find: SI -> this chipset's nc_tab entry, CF=1 if unknown (clobbers AL, CX).
; nc_wr: out 0x22, CL(reg); out [SI+3], CH(val). nc_rd: out 0x22, CL(reg); in AL, [SI+3]. Clobber AL, DX.
;------------------------------------------------------------------------------
nc_find:
        mov     al, [g_nc_chipset]
        mov     si, nc_tab
        mov     cx, NC_TAB_N
.f:     cmp     al, [si]
        je      .found
        add     si, NC_ENT_LEN
        loop    .f
        stc
        ret
.found: clc
        ret
nc_wr:
        mov     dx, 0x22
        mov     al, cl
        out     dx, al
        mov     dl, [si + 3]
        mov     al, ch
        out     dx, al
        ret
nc_rd:
        mov     dx, 0x22
        mov     al, cl
        out     dx, al
        mov     dl, [si + 3]
        in      al, dx
        ret
