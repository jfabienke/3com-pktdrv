; el3_probe.asm -- 3C509 (Tomahawk) ISA ID-port probe + activation. COLD; %included by
; start.asm. Self-contained, 8088-clean. Shares DS=DGROUP and the BSS globals in start.asm.
;
; The 3C509 has no fixed I/O base at power-on; it answers on a shared "ID port" (0x110)
; until activated. Sequence (verified against the Nestor 8086 3c509 driver): clock the ID
; pattern to move cards into ID state, global-reset, re-clock the pattern, clear tags, read
; & validate the EEPROM (which also drives per-card contention), then tag + activate the
; winner at the I/O base its own EEPROM specifies.

%include "el3_tomahawk.inc"

;------------------------------------------------------------------------------
; detect_nic -- probe & activate one 3C509.
; out: CF=0 and g_nic_io / g_nic_irq / g_mac[6] set on success; CF=1 if no card.
; clobbers AX, BX, CX, DX, SI, DI.
;------------------------------------------------------------------------------
detect_nic:
        call    write_id_pat                ; clock cards into ID state
        mov     dx, EL3_ID_PORT
        mov     al, EL3_ID_GLOBAL_RESET     ; 0xC0: reset the adapter(s)
        out     dx, al
        call    reset_delay
        call    write_id_pat                ; re-clock into ID-CMD state

        mov     dx, EL3_ID_PORT
        mov     al, EL3_ID_TAG_BASE         ; 0xD0: clear all board tags
        out     dx, al

        mov     al, EL3_EE_PROD_ID          ; confirm product id (word 3, masked)
        call    id_read_eeprom
        and     ax, EL3_PRODID_MASK
%ifdef CFG_DEBUG
        push    ax                          ; show the raw IDs even on a mismatch
        mov     dx, msg_eeprod
        call    print_str
        pop     ax
        push    ax
        call    print_hex16
        pop     ax
%endif
        cmp     ax, EL3_PRODID_3C509B
        jne     .nocard

        mov     al, EL3_EE_MFG_ID           ; confirm manufacturer id (word 7)
        call    id_read_eeprom
%ifdef CFG_DEBUG
        push    ax
        mov     dx, msg_eeid
        call    print_str
        pop     ax
        push    ax
        call    print_hex16
        pop     ax
%endif
        cmp     ax, EL3_MFG_ID
        jne     .nocard

        ; station address: EEPROM words 0..2, stored big-endian into g_mac
        xor     si, si                      ; byte index into g_mac
        xor     di, di                      ; EEPROM word index
.macloop:
        mov     ax, di
        call    id_read_eeprom              ; ax = word (MSB first)
        mov     [g_mac + si], ah
        mov     [g_mac + si + 1], al
        add     si, 2
        inc     di
        cmp     di, 3
        jb      .macloop

        ; I/O base from address-config word 8: 0x200 + ((w & 0x1F) << 4)
        mov     al, EL3_EE_ADDR_CFG
        call    id_read_eeprom
        and     ax, 0x001F
        mov     cl, 4
        shl     ax, cl
        add     ax, 0x200
        mov     [g_nic_io], ax

        ; IRQ from resource-config word 9: bits 15..12
        mov     al, EL3_EE_RESOURCE_CFG
        call    id_read_eeprom
        mov     cl, 12
        shr     ax, cl
        mov     [g_nic_irq], ax

        mov     dx, EL3_ID_PORT
        mov     al, EL3_ID_TAG_BASE + 1     ; tag this card (a rescan then skips it)
        out     dx, al
        mov     al, EL3_ID_ACTIVATE_CFG     ; 0xFF: activate at the EEPROM-configured base
        out     dx, al

        clc
        ret
.nocard:
        stc
        ret

;------------------------------------------------------------------------------
; write_id_pat -- select the ID port and clock out the 3c509 ID pattern: a 9-bit LFSR
; (poly 0xCF) emitted low-byte-first for 255 cycles. Carry-feedback form (matches Nestor).
;------------------------------------------------------------------------------
write_id_pat:
        mov     dx, EL3_ID_PORT
        xor     al, al
        out     dx, al                      ; select the ID port
        out     dx, al                      ; reset the pattern generator
        mov     cx, 255
        mov     al, 0xFF                     ; lrs_state
.wp:
        out     dx, al
        shl     al, 1                       ; bit 7 -> carry
        jnc     .wpnf
        xor     al, 0xCF
.wpnf:
        loop    .wp
        ret

;------------------------------------------------------------------------------
; id_read_eeprom -- read one 16-bit EEPROM word through the ID port.
; in: AL = word index ; out: AX = word (MSB first). clobbers BX, CX, DX.
;------------------------------------------------------------------------------
id_read_eeprom:
        mov     dx, EL3_ID_PORT
        add     al, EL3_EE_READ             ; 0x80 | index
        out     dx, al
        call    io_delay                    ; EEPROM read latency (~162 us)
        xor     bx, bx
        mov     cx, 16
.rbit:
        in      al, dx                      ; data bit in bit 0
        shr     al, 1                       ; bit 0 -> carry
        rcl     bx, 1                       ; carry -> bx (MSB first)
        loop    .rbit
        mov     ax, bx
        ret

;------------------------------------------------------------------------------
; io_delay -- busy-wait covering the EEPROM read latency (~162 us) + ID-port settle. It reads the
; POST port (0x80) in a loop; each read is an ISA bus cycle, so wall-time is bus-bound (~inversely
; proportional to the ISA clock) plus a small per-iteration CPU cost. It is therefore NOT
; CPU/bus-speed-independent: on a fast CPU + fast bus (Pentium on a 16 MHz ISA bus) a too-short
; count clears before the EEPROM is ready and the driver reads the 0x8000 busy value as the MAC.
; The count is sized for the fast end (>=162 us even on a 16 MHz bus); on a slow CPU/8 MHz bus it
; merely over-waits, harmless for one-time cold init.
; reset_delay -- ~8x that, for the post-global-reset settle.
;------------------------------------------------------------------------------
;------------------------------------------------------------------------------
; detect_nic_corkscrew -- find a 3C515 at its legacy (non-PnP) I/O base. The 3C515 takes no part in
; the 3C509 ID-port isolation: it answers at the base its EEPROM configures. Scan 0x100..0x3E0 step
; 0x20 as Linux 3c515 does: the window-independent resource-config mirror at base+0x2002 must hold
; the base's bits 4-8, then EEPROM word 7 (via base+0x200A/0x200C) must be 3Com's 0x6D50. A PnP-mode
; card on a board with no PnP BIOS stays inactive until isolated -- that needs the pnp build.
; out: CF=0 with g_nic_io, g_nic_gen=1, g_nic_irq (from the card unless /q= gave one) and g_mac;
; CF=1 if none. Cold, >=286 only (a 16-bit card). Clobbers AX, BX, CX, DX, SI, DI, BP.
;------------------------------------------------------------------------------
detect_nic_corkscrew:
        mov     bx, EL3_CS_SCAN_FIRST
.next:
        mov     dx, bx
        add     dx, EL3_CS_RESCFG
        in      ax, dx
        mov     di, ax                      ; keep: bits 0-3 = the card's IRQ
        xor     ax, bx
        test    ax, EL3_CS_RESCFG_IOMASK
        jnz     .skip                       ; nothing (0xFFFF) or not configured for this base
        ; A card decoding only 10 address bits (an XT-IDE, most 8-bit cards) answers base+0x2002 exactly
        ; as base+0x0002. Never send it the EEPROM read below (a write into its registers): skip a base
        ; whose +0x2002 reads the same as +0x0002.
        mov     dx, bx
        add     dx, 2
        in      ax, dx
        cmp     ax, di
        je      .skip
        mov     dx, bx
        add     dx, EL3_CS_W0_EE_CMD
        mov     ax, EL3_EE_READ | EL3_EE_MFG_ID
        out     dx, ax
        call    io_delay                    ; >= 162 us before the first poll (Linux)
        xor     cx, cx
.busy:
        in      ax, dx
        test    ax, EL3_CS_EE_BUSY
        jz      .ready
        loop    .busy
.ready:
        add     dx, 2                       ; EEPROM data register
        in      ax, dx
        cmp     ax, EL3_MFG_ID
        je      .found
.skip:
        add     bx, EL3_CS_SCAN_STEP
        cmp     bx, EL3_CS_SCAN_END
        jb      .next
        stc
        ret
.found:
        mov     [g_nic_io], bx
        mov     byte [g_nic_gen], 1
        cmp     word [g_nic_irq], 0
        jne     .irq_given
        and     di, 0x000F
        mov     [g_nic_irq], di
.irq_given:
        call    el3_load_mac_io
        clc
        ret

io_delay:
        push    cx
        mov     cx, 1024
.dly:
        in      al, 0x80
        loop    .dly
        pop     cx
        ret

reset_delay:
        push    cx
        mov     cx, 8
.rs:
        call    io_delay
        loop    .rs
        pop     cx
        ret
