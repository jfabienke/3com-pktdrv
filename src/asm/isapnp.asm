; isapnp.asm -- direct ISA Plug-and-Play isolation + 3Com card detection (COLD; %included by
; start.asm under CFG_PNP). The caller gates this to CPU >= 286 (a 3C515 is a 16-bit card);
; the protocol itself is 8086-clean 8-bit port I/O. Shares DS=DGROUP and the BSS scratch in
; start.asm. Reuses io_delay from el3_probe.asm.
;
; POLITE by design so it coexists with a PnP BIOS that already configured cards:
;   - Reset-CSN (config 0x04), never global Reset (0x01) which would deactivate cards and
;     discard the BIOS's resource assignment.
;   - read-don't-clobber: if our card is already Active, use its existing I/O/IRQ (inheriting
;     the BIOS's conflict-free assignment for free); only self-assign when it's unconfigured.
;   - always restore Wait-for-Key on exit, leaving the bus as we found it.
;
; Isolation follows the ISA PnP spec: send the 32-byte LFSR key, Reset-CSN, then repeatedly
; Wake[0] + read the 72-bit serial identifier (8 ID bytes + 1 checksum) validating the LFSR
; checksum, assigning a CSN to each card found, until none remain -- taking the first 3Com
; card (vendor 0x6D50). Cross-referenced with the 3Com pnp.c reference and the ISA PnP spec.
;
; UNTESTABLE in emulation (no emulator has a 3C515); structurally verified, awaits hardware.

%include "el3_corkscrew.inc"

; ---- ISA PnP ports + registers ----
PNP_ADDR        equ 0x279       ; address/index port
PNP_WRITE       equ 0xA79       ; write-data port
PNP_READ        equ 0x203       ; relocatable read-data port (port>>2 written to reg 0x00)

PNP_R_SETRDP    equ 0x00        ; set read-data port
PNP_R_ISOLATE   equ 0x01        ; serial isolation
PNP_R_CONFIG    equ 0x02        ; config control
PNP_R_WAKE      equ 0x03        ; wake[CSN]
PNP_R_CSN       equ 0x06        ; card select number
PNP_R_LDN       equ 0x07        ; logical device number
PNP_R_ACTIVATE  equ 0x30        ; logical device activate (bit0)
PNP_R_IOBASE_HI equ 0x60        ; logical device 0 I/O base, high byte
PNP_R_IOBASE_LO equ 0x61        ; logical device 0 I/O base, low byte
PNP_R_IRQ       equ 0x70        ; logical device 0 IRQ level

PNP_CFG_RESETCSN equ 0x04       ; reset all CSNs to 0 (does NOT touch resources/activation)
PNP_CFG_WAITKEY  equ 0x02       ; return cards to Wait-for-Key
PNP_LFSR_SEED    equ 0x6A       ; isolation checksum LFSR seed

; The 32-byte LFSR initiation key (cards: Wait-for-Key -> Sleep). Standard ISA PnP sequence.
pnp_key:
        db 0x6A,0xB5,0xDA,0xED,0xF6,0xFB,0x7D,0xBE
        db 0xDF,0x6F,0x37,0x1B,0x0D,0x86,0xC3,0x61
        db 0xB0,0x58,0x2C,0x16,0x8B,0x45,0xA2,0xD1
        db 0xE8,0x74,0x3A,0x9D,0xCE,0xE7,0x73,0x39

;------------------------------------------------------------------------------
; detect_nic_pnp -- isolate ISA PnP cards, configure the first 3Com one, read its MAC.
; out: CF=0 and g_nic_io / g_nic_irq / g_mac set on success; CF=1 if no 3Com PnP card.
; clobbers AX, BX, CX, DX, SI, DI.
;------------------------------------------------------------------------------
detect_nic_pnp:
        call    pnp_send_key                ; Wait-for-Key -> Sleep
        mov     al, PNP_R_SETRDP            ; set the relocatable read-data port
        mov     ah, (PNP_READ >> 2)
        call    pnp_write_reg
        mov     al, PNP_R_CONFIG           ; polite: Reset-CSN only (NOT global Reset 0x01)
        mov     ah, PNP_CFG_RESETCSN
        call    pnp_write_reg

        mov     byte [pnp_next_csn], 1
.scan:
        call    pnp_isolate_one             ; -> pnp_id[0..8], CF=1 if no more cards
        jc      .none
        mov     al, PNP_R_CSN              ; give this card a CSN (moves it out of isolation)
        mov     ah, [pnp_next_csn]
        call    pnp_write_reg
        inc     byte [pnp_next_csn]
        ; 3Com? vendor = pnp_id[0..1]; accept either byte order (0x6D50 / 0x506D) -- the exact
        ; serial bit order is to be confirmed on hardware, and no other vendor collides.
        mov     al, [pnp_id]
        mov     ah, [pnp_id + 1]
        cmp     al, 0x6D
        jne     .swap
        cmp     ah, 0x50
        je      .is3com
.swap:
        cmp     al, 0x50
        jne     .scan
        cmp     ah, 0x6D
        jne     .scan
.is3com:
        mov     al, [pnp_next_csn]         ; our card's CSN = next_csn - 1
        dec     al
        mov     [pnp_found_csn], al
        ; generation: the 3C509B PnP id is 0x5090 (carries a 0x90 byte); the 3C515 family is
        ; 0x5050..0x5053 (no 0x90). Discriminate byte-order-independently. Confirm on hardware.
        mov     byte [g_nic_gen], 1        ; assume Corkscrew (3C515: registers +0x10, store-fwd)
        cmp     byte [pnp_id + 2], 0x90
        je      .gen_tomahawk
        cmp     byte [pnp_id + 3], 0x90
        jne     .configure                ; no 0x90 byte -> 3C515, gen stays 1
.gen_tomahawk:
        mov     byte [g_nic_gen], 0       ; 3C509B in PnP mode -> Tomahawk layout
        jmp     .configure
.none:
        mov     al, PNP_R_CONFIG          ; restore Wait-for-Key, then fail
        mov     ah, PNP_CFG_WAITKEY
        call    pnp_write_reg
        stc
        ret

.configure:
        mov     al, PNP_R_WAKE            ; Wake[csn] into config, select logical device 0
        mov     ah, [pnp_found_csn]
        call    pnp_write_reg
        mov     al, PNP_R_LDN
        xor     ah, ah
        call    pnp_write_reg
        mov     al, PNP_R_ACTIVATE        ; read-don't-clobber: already active?
        call    pnp_read_reg
        test    al, 1
        jnz     .existing
        ; unconfigured -> assign a default base/IRQ and activate
        mov     al, PNP_R_IOBASE_HI
        mov     ah, 0x03                  ; default I/O base 0x300
        call    pnp_write_reg
        mov     al, PNP_R_IOBASE_LO
        xor     ah, ah
        call    pnp_write_reg
        mov     al, PNP_R_IRQ
        mov     ah, 10                    ; default IRQ 10 (a 16-bit-ISA line)
        call    pnp_write_reg
        mov     al, PNP_R_ACTIVATE
        mov     ah, 1
        call    pnp_write_reg
        mov     word [g_nic_io], 0x300
        mov     word [g_nic_irq], 10
        jmp     .got
.existing:
        ; already active (e.g. a PnP BIOS configured it) -> inherit its resources
        mov     al, PNP_R_IOBASE_HI
        call    pnp_read_reg
        mov     bh, al
        mov     al, PNP_R_IOBASE_LO
        call    pnp_read_reg
        mov     bl, al
        mov     [g_nic_io], bx
        mov     al, PNP_R_IRQ
        call    pnp_read_reg
        and     ax, 0x000F
        mov     [g_nic_irq], ax
.got:
        mov     al, PNP_R_CONFIG          ; quiesce: back to Wait-for-Key (card stays active)
        mov     ah, PNP_CFG_WAITKEY
        call    pnp_write_reg
        call    el3_load_mac_io           ; read the MAC via the now-fixed I/O base
        clc
        ret

;------------------------------------------------------------------------------
; pnp_isolate_one -- Wake[0] + read one card's 72-bit serial identifier with checksum check.
; out: CF=0 and pnp_id[0..8] filled if a card isolated; CF=1 if none. clobbers AX,BX,CX,DX,DI.
;------------------------------------------------------------------------------
pnp_isolate_one:
        mov     al, PNP_R_WAKE            ; CSN-0 cards -> Isolation
        xor     ah, ah
        call    pnp_write_reg
        mov     al, PNP_R_ISOLATE        ; subsequent reads stream the isolation sequence
        call    pnp_set_addr
        call    io_delay                  ; isolation settle

        mov     byte [pnp_lfsr], PNP_LFSR_SEED
        mov     byte [pnp_saw], 0
        mov     di, pnp_id
        mov     cx, 9                     ; 8 ID bytes + 1 checksum byte
.byteL:
        push    cx
        mov     bl, 0                     ; byte accumulator
        mov     ch, cl                    ; ch = outer index (9..1); ==1 on the checksum byte
        mov     cl, 8                     ; 8 bits, LSB first
.bitL:
        call    pnp_read_data            ; data1 -> AL
        mov     dh, al
        call    pnp_read_data            ; data2 -> AL
        xor     bh, bh                    ; this data bit (0/1)
        cmp     dh, 0x55
        jne     .b0
        cmp     al, 0xAA
        jne     .b0
        mov     bh, 1
        mov     byte [pnp_saw], 1
.b0:
        cmp     ch, 1                     ; checksum LFSR over the first 64 bits only
        je      .nocsum
        mov     al, [pnp_lfsr]
        mov     ah, al
        shr     ah, 1                     ; ah.0 = lfsr.1
        xor     al, ah                    ; al.0 = lfsr.0 ^ lfsr.1
        xor     al, bh                    ;       ^ databit
        and     al, 1                     ; newbit
        mov     ah, [pnp_lfsr]
        shr     ah, 1                     ; lfsr >> 1
        ror     al, 1                     ; newbit -> bit7 (0x80 or 0x00)
        or      ah, al
        mov     [pnp_lfsr], ah
.nocsum:
        shr     bh, 1                     ; databit -> carry
        rcr     bl, 1                     ; carry -> accumulator bit7 (LSB-first packing)
        dec     cl
        jnz     .bitL
        mov     [di], bl
        inc     di
        pop     cx
        loop    .byteL

        cmp     byte [pnp_saw], 0         ; a card must have driven the bus
        je      .nocard
        mov     al, [pnp_lfsr]            ; computed checksum must match the read byte
        cmp     al, [pnp_id + 8]
        jne     .nocard
        clc
        ret
.nocard:
        stc
        ret

;------------------------------------------------------------------------------
; low-level ISA PnP port helpers
;------------------------------------------------------------------------------
pnp_send_key:                            ; reset the key LFSR, then clock the 32-byte key
        mov     dx, PNP_ADDR
        xor     al, al
        out     dx, al
        out     dx, al
        mov     si, pnp_key
        mov     cx, 32
.k:     lodsb                            ; DS:SI -> key (DS = DGROUP)
        out     dx, al
        loop    .k
        ret

pnp_write_reg:                           ; AL=register, AH=data
        push    dx
        mov     dx, PNP_ADDR
        out     dx, al
        mov     dx, PNP_WRITE
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        pop     dx
        ret

pnp_set_addr:                            ; AL=register
        push    dx
        mov     dx, PNP_ADDR
        out     dx, al
        pop     dx
        ret

pnp_read_reg:                            ; AL=register -> AL=value
        call    pnp_set_addr
        call    pnp_read_data
        ret

pnp_read_data:                           ; -> AL. Brief settle first (ISA PnP read timing;
        push    dx                       ; tune the count on hardware). Preserves DH, CX.
        push    cx
        mov     cx, 4
.d:     in      al, 0x80                 ; ~1 us POST-port reads, bus-bound
        loop    .d
        mov     dx, PNP_READ
        in      al, dx
        pop     cx
        pop     dx
        ret
