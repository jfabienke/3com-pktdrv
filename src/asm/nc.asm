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
; CONTRACT: nc_mark_region / nc_clear_region clobber AX,BX,CX,DX (both call sites -- the cold re-test and
; f_xms_configure -- are caller-saved). Region 0 only (we need exactly one contiguous NC region; docs/12).

NC_CHIP_NONE        equ 0
NC_CHIP_OPTI391     equ 1       ; OPTi 82C391 / 82C596-7 Viper / 82C381 -- 0x22/0x24, 8 KB gran
NC_CHIP_ETEQ        equ 2       ; Eteq 82C495WB Bengal -- OPTi-compatible encoding, 0x22/0x24
NC_CHIP_UMC491      equ 3       ; UMC UM82C491 -- 0x22/0x23, 8 KB gran, 1 region
NC_CHIP_SIS460      equ 4       ; SiS 85C460 / 85C310 Rabbit -- 0x22/0x23, 64 KB gran
NC_CHIP_SYNTH       equ 0xFE    ; synthetic (CFG_FORCE_NC structural test): no port write, mark always "works"

;------------------------------------------------------------------------------
; nc_mark_region -- fence [base_kb, base_kb+size_kb) non-cacheable on g_nc_chipset (region 0).
;   in : BX = base_kb (granularity-aligned by the caller), CX = size_kb
;   out: CF=0 programmed; CF=1 not encodable -> caller MUST keep the flush (never drop on a failed mark)
; Clobbers AX,BX,CX,DX. Resident.
;------------------------------------------------------------------------------
nc_mark_region:
        mov     al, [g_nc_chipset]
        cmp     al, NC_CHIP_SYNTH
        je      .synth
        cmp     al, NC_CHIP_OPTI391
        je      .opti
        cmp     al, NC_CHIP_ETEQ
        je      .opti                           ; Eteq Bengal == OPTi-compatible encoding
        cmp     al, NC_CHIP_UMC491
        je      .umc
        cmp     al, NC_CHIP_SIS460
        je      .sis
        stc                                     ; unknown id
        ret
.synth:
        clc                                     ; structural test: succeed, touch no port
        ret

        ; OPTi 82C391/Viper/381 + Eteq Bengal. base reg 0x52 = base in 64 KB units (A23:A16); size reg 0x53 =
        ; (code<<4) | (A27:A24 nibble), region = 8 KB << (code-1). !!! base unit UNVERIFIED (cache-kit 64 vs 16).
.opti:
        call    nc_size_code_8k                 ; CX -> AL = code (1..7); CF=1 unrepresentable. BX,CX preserved.
        jc      .fail
        mov     ch, al                          ; CH = size code (stash)
        call    nc_base64_split                 ; BX(base_kb) -> AL=base_val, AH=nibble(A27:A24)
        mov     bl, al                          ; BL = base_val
        mov     al, ch                          ; size code
        call    nc_code_nibble                  ; AL = (code<<4) | nibble(AH) -> size_val
        mov     bh, al                          ; BH = size_val
        mov     cl, 0x52
        mov     ch, bl                          ; reg 0x52 <- base_val
        call    nc_wr_opti
        mov     cl, 0x53
        mov     ch, bh                          ; reg 0x53 <- size_val
        call    nc_wr_opti
        clc
        ret

        ; UMC UM82C491. base reg 0x50 = base in 64 KB units; size reg 0x51 = 0x80(enable) | (code<<4),
        ; region = 8 KB << code (code 0..7). !!! base unit UNVERIFIED (cache-kit). 1 region.
.umc:
        call    nc_size_code_8k_umc             ; CX -> AL = code (0..7); CF=1. BX,CX preserved.
        jc      .fail
        mov     ch, al
        call    nc_base64_split                 ; AL=base_val, AH=nibble
        test    ah, ah
        jnz     .fail                           ; >16 MB base -> 8-bit field overflow (never for conv <1 MB)
        mov     cl, 0x50
                                                ; CH already = base... no: reuse. set CH=base_val
        mov     ch, al                          ; reg 0x50 <- base_val
        call    nc_wr_legacy
        ; rebuild size byte: 0x80 | (code<<4). code was in CH before the write clobbered it -> recompute.
        call    nc_size_code_8k_umc             ; AL = code again (BX,CX still hold base/size)
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        or      al, 0x80
        mov     cl, 0x51
        mov     ch, al                          ; reg 0x51 <- enable|size
        call    nc_wr_legacy
        clc
        ret

        ; SiS 85C460/Rabbit. base reg 0x14 = base in 64 KB units; ctrl reg 0x15 high nibble = code,
        ; region = 64 KB << (code-1). 64 KB granularity.
.sis:
        call    nc_size_code_64k                ; CX -> AL = code (1..8); CF=1. BX,CX preserved.
        jc      .fail
        mov     ch, al
        call    nc_base64_split
        test    ah, ah
        jnz     .fail
        mov     cl, 0x14
        mov     ch, al                          ; reg 0x14 <- base_val
        call    nc_wr_legacy
        call    nc_size_code_64k                ; AL = code again
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1                           ; code<<4
        mov     cl, 0x15
        mov     ch, al                          ; reg 0x15 <- ctrl
        call    nc_wr_legacy
        clc
        ret
.fail:
        stc
        ret

;------------------------------------------------------------------------------
; nc_clear_region -- disable region 0 (size code 0 = off) on g_nc_chipset. Undo a marking whose re-test
; FAILED. Clobbers AX,CX,DX. Resident.
;------------------------------------------------------------------------------
nc_clear_region:
        mov     al, [g_nc_chipset]
        xor     ch, ch                          ; value 0 = region disabled
        cmp     al, NC_CHIP_OPTI391
        je      .copti
        cmp     al, NC_CHIP_ETEQ
        je      .copti
        cmp     al, NC_CHIP_UMC491
        je      .culeg
        cmp     al, NC_CHIP_SIS460
        je      .csleg
        ret                                     ; NONE / SYNTH -> nothing to clear
.copti:
        mov     cl, 0x53                        ; OPTi size reg
        jmp     nc_wr_opti
.culeg:
        mov     cl, 0x51                        ; UMC size/enable reg
        jmp     nc_wr_legacy
.csleg:
        mov     cl, 0x15                        ; SiS ctrl reg
        jmp     nc_wr_legacy

;------------------------------------------------------------------------------
; helpers (resident). nc_wr_* : out 0x22, CL(reg) ; out data_port, CH(val). Clobber AX,DX; preserve BX,CX.
;------------------------------------------------------------------------------
nc_wr_opti:
        mov     dx, 0x22
        mov     al, cl
        out     dx, al
        mov     dx, 0x24
        mov     al, ch
        out     dx, al
        ret
nc_wr_legacy:
        mov     dx, 0x22
        mov     al, cl
        out     dx, al
        mov     dx, 0x23
        mov     al, ch
        out     dx, al
        ret

; nc_base64_split -- BX(base_kb) -> AL = base in 64 KB units (low 8 bits), AH = A27:A24 nibble. Clobbers AX,CX.
nc_base64_split:
        mov     ax, bx
        mov     cl, 6
        shr     ax, cl                          ; AX = base_kb >> 6 (64 KB units)
        and     ah, 0x0F                        ; AH = A27:A24 nibble
        ret

; nc_code_nibble -- AL(code) -> AL = (code<<4) | (AH nibble). Clobbers nothing else.
nc_code_nibble:
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        or      al, ah
        ret

; nc_size_code_8k -- CX(size_kb) -> AL = OPTi code 1..7, region = 8 KB << (code-1) (8 KB..512 KB), rounded UP.
; CF=1 if size_kb > 512. Clobbers AX,DX; BX,CX preserved.
nc_size_code_8k:
        mov     al, 1
        mov     dx, 8
.l:     cmp     dx, cx
        jae     .ok
        cmp     al, 7
        jae     .bad
        inc     al
        shl     dx, 1
        jmp     .l
.ok:    clc
        ret
.bad:   stc
        ret

; nc_size_code_8k_umc -- CX -> AL = UMC code 0..7, region = 8 KB << code (8 KB..1 MB), rounded UP. CF=1 if
; >1 MB. Clobbers AX,DX; BX,CX preserved.
nc_size_code_8k_umc:
        mov     al, 0
        mov     dx, 8
.l:     cmp     dx, cx
        jae     .ok
        cmp     al, 7
        jae     .bad
        inc     al
        shl     dx, 1
        jmp     .l
.ok:    clc
        ret
.bad:   stc
        ret

; nc_size_code_64k -- CX -> AL = SiS code 1..8, region = 64 KB << (code-1), rounded UP. CF=1 if >8 MB.
; Clobbers AX,DX; BX,CX preserved. (Capped at code 8 so DX can't overflow 16 bits; ample for a DMA ring.)
nc_size_code_64k:
        mov     al, 1
        mov     dx, 64
.l:     cmp     dx, cx
        jae     .ok
        cmp     al, 8
        jae     .bad
        inc     al
        shl     dx, 1
        jmp     .l
.ok:    clc
        ret
.bad:   stc
        ret
