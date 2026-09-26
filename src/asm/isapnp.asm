; isapnp.asm -- direct ISA Plug-and-Play isolation + 3Com card detection (COLD; %included by
; start.asm under CFG_PNP). The caller gates this to CPU >= 286 (a 3C515 is a 16-bit card);
; the protocol itself is 8086-clean 8-bit port I/O. Shares DS=DGROUP and the BSS scratch in
; start.asm. Reuses io_delay from el3_probe.asm.
;
; The sequence and delays follow Linux drivers/pnp/isapnp/core.c (isapnp_isolate_rdp_select /
; isapnp_isolate), which follow the ISA PnP spec:
;   Wait-for-Key, key, Reset-CSN, 2 ms, Wait-for-Key, key, Wake[0] (CSN-0 cards -> Isolation),
;   Set-RD_DATA (only honoured in Isolation), 1 ms, select the isolation register, 1 ms; then read the
;   72-bit serial identifier as pairs (0x55,0xAA = 1) with 250 us after EVERY read, checking the LFSR
;   checksum; each isolated card gets the next CSN (250 us), then Wake[0] + Set-RD_DATA again for the
;   next card. If nothing isolates on the first pass, the read port moves up by 8 (skipping the
;   NE2000 probe space 0x280-0x380) and the whole selection is redone. Every address-port write is
;   followed by 20 us.
; (Was: Set-RD_DATA sent before Wake[0], ~4 us between isolation reads, a fixed 0x203 read port -- the
; card never learned the read port, so a real PnP-mode 3C515 was never found.)
;
; POLITE so it coexists with a PnP BIOS that already configured cards: Reset-CSN only, never the
; global Reset (which would deactivate cards); an already-active card keeps its I/O/IRQ; Wait-for-Key
; is restored on exit. Timing is by ~1 us ISA reads of port 0x80, independent of the CPU clock.

%include "el3_corkscrew.inc"

; ---- ISA PnP ports + registers ----
PNP_ADDR        equ 0x279       ; address/index port
PNP_WRITE       equ 0xA79       ; write-data port
PNP_RDP_FIRST   equ 0x213       ; first read-data port tried (Linux); must end in binary 11
PNP_RDP_STEP    equ 8           ; isapnptools' step (Linux uses 0x20): on a real IBM PC/AT pnpdump's first
                                ; read port 0x273 failed and 0x27B worked -- a 0x20 step never tries 0x27B
PNP_RDP_SKIP_LO equ 0x280       ; NE2000 probe space: never used as a read port
PNP_RDP_SKIP_HI equ 0x380
PNP_RDP_LAST    equ 0x3FF

PNP_R_SETRDP    equ 0x00        ; set read-data port (port >> 2)
PNP_R_ISOLATE   equ 0x01        ; serial isolation
PNP_R_CONFIG    equ 0x02        ; config control
PNP_R_WAKE      equ 0x03        ; wake[CSN]
PNP_R_CSN       equ 0x06        ; card select number
PNP_R_LDN       equ 0x07        ; logical device number
PNP_R_ACTIVATE  equ 0x30        ; logical device activate (bit0)
PNP_R_IOBASE_HI equ 0x60        ; logical device I/O base 0, high byte
PNP_R_IOBASE_LO equ 0x61        ; logical device I/O base 0, low byte
PNP_R_IRQ       equ 0x70        ; logical device IRQ 0 level
PNP_R_DMA       equ 0x74        ; logical device DMA channel 0 (4 = none)

PNP_CFG_RESETCSN equ 0x04       ; reset all CSNs to 0 (does NOT touch resources/activation)
PNP_CFG_WAITKEY  equ 0x02       ; return cards to Wait-for-Key
PNP_LFSR_SEED    equ 0x6A       ; isolation checksum LFSR seed

PNP_DEF_IRQ      equ 10         ; unless /q= (the I/O base is the first FREE one of pnp_io_cands, or /b=)
PNP_DEF_DMA      equ 5          ; 16-bit channel for the 3C515 bus master (free on a stock AT)

; delays, in ~1 us reads of port 0x80
PNP_US_ADDR      equ 20
PNP_US_READ      equ 250
PNP_US_1MS       equ 1000
PNP_US_2MS       equ 2000
PNP_US_RDP       equ 100

; The 32-byte LFSR initiation key (cards: Wait-for-Key -> Sleep). Standard ISA PnP sequence.
pnp_key:
        db 0x6A,0xB5,0xDA,0xED,0xF6,0xFB,0x7D,0xBE
        db 0xDF,0x6F,0x37,0x1B,0x0D,0x86,0xC3,0x61
        db 0xB0,0x58,0x2C,0x16,0x8B,0x45,0xA2,0xD1
        db 0xE8,0x74,0x3A,0x9D,0xCE,0xE7,0x73,0x39

msg_pnp_card    db 'PnP card ', '$'
msg_pnp_csn     db ' CSN=', '$'
msg_pnp_rdp     db ' read port 0x', '$'
msg_pnp_none    db 'PnP: no card isolated (read ports 0x0213-0x03FB)', 13, 10, '$'
msg_pnp_no3com  db 'PnP: no 3Com card among them', 13, 10, '$'
msg_pnp_busy    db 'PnP: I/O 0x', '$'
msg_pnp_inuse   db ' in use (range check read 0x', '$'
msg_pnp_inuse2  db '), not used', 13, 10, '$'
msg_pnp_nobase  db 'PnP: no free I/O base found -- try another with /b= (and /q=)', 13, 10, '$'

;------------------------------------------------------------------------------
; detect_nic_pnp -- isolate every ISA PnP card, configure + activate the first 3Com one, read its MAC.
; out: CF=0 and g_nic_io / g_nic_irq / g_nic_gen / g_mac set on success; CF=1 if no 3Com PnP card.
; clobbers AX, BX, CX, DX, SI, DI.
;------------------------------------------------------------------------------
detect_nic_pnp:
        mov     dx, msg_crlf                ; our report lines follow the "CPU class=" digit
        call    print_str
        mov     word [pnp_rdp], PNP_RDP_FIRST
        mov     byte [pnp_csn], 0
        mov     byte [pnp_iter], 1
        mov     byte [pnp_found_csn], 0
        call    pnp_rdp_select
        jc      .nocards
.scan:
        call    pnp_isolate_one             ; -> pnp_id[0..8], CF=1 if nothing valid isolated
        jc      .invalid
        inc     byte [pnp_csn]
        mov     al, PNP_R_CSN               ; give this card the next CSN (it leaves Isolation)
        mov     ah, [pnp_csn]
        call    pnp_write_reg
        mov     cx, PNP_US_READ
        call    pnp_delay
        inc     byte [pnp_iter]
        call    pnp_report_card
        cmp     byte [pnp_found_csn], 0
        jne     .next                       ; already have our card: just isolate the rest
        call    pnp_is_3com
        jc      .next
        mov     al, [pnp_csn]
        mov     [pnp_found_csn], al
        ; generation: the 3C509B PnP id is TCM5090 (a 0x90 byte); the 3C515 family has none
        mov     byte [g_nic_gen], 1
        cmp     byte [pnp_id + 2], 0x90
        je      .gen_tomahawk
        cmp     byte [pnp_id + 3], 0x90
        jne     .next
.gen_tomahawk:
        mov     byte [g_nic_gen], 0
.next:
        cmp     byte [pnp_csn], 255
        je      .done
        mov     al, PNP_R_WAKE              ; CSN-0 cards back to Isolation for the next one
        xor     ah, ah
        call    pnp_write_reg
        call    pnp_isolation_setup
        jmp     .scan
.invalid:
        cmp     byte [pnp_iter], 1
        jne     .done                       ; had cards; none left
        add     word [pnp_rdp], PNP_RDP_STEP  ; nothing on this read port: try the next one
        call    pnp_rdp_select
        jc      .nocards
        jmp     .scan
.done:
        cmp     byte [pnp_found_csn], 0
        jne     .configure
        mov     dx, msg_pnp_no3com
        call    print_str
        jmp     .fail
.nocards:
        mov     dx, msg_pnp_none
        call    print_str
.fail:
        call    pnp_wait_key
        stc
        ret

.configure:
        mov     al, PNP_R_WAKE            ; Wake[csn] into Config, select logical device 0
        mov     ah, [pnp_found_csn]
        call    pnp_write_reg
        mov     al, PNP_R_LDN
        xor     ah, ah
        call    pnp_write_reg
        ; The base must be FREE: another card decoding the same ports (an XT-IDE sits at 0x300 by default)
        ; shares every access with the NIC -- on a real IBM PC/AT that hung the disk and corrupted the CF.
        ; Deactivate first so only other devices answer, then check the range reads all 0xFF. An already-
        ; active card (a PnP BIOS, or our previous run surviving a warm boot) keeps its base if that is free.
        mov     al, PNP_R_ACTIVATE
        call    pnp_read_reg
        mov     bx, 0
        test    al, 1
        jz      .inactive
        mov     al, PNP_R_IOBASE_HI       ; active: remember its base, then take it off the bus
        call    pnp_read_reg
        mov     bh, al
        mov     al, PNP_R_IOBASE_LO
        call    pnp_read_reg
        mov     bl, al
        mov     al, PNP_R_ACTIVATE
        xor     ah, ah
        call    pnp_write_reg
        mov     cx, PNP_US_READ
        call    pnp_delay
.inactive:
        cmp     byte [g_manual], 1        ; /b= given: that base, or nothing
        jne     .pick
        mov     bx, [g_nic_io]
        call    pnp_io_free
        jnc     .have_base
        call    pnp_say_busy
        jmp     .nobase
.pick:
        ; (no preference for a previous base: on the AT that was our own earlier placement on the XT-IDE)
.cands:
        mov     si, pnp_io_cands
.cand:
        lodsw
        or      ax, ax
        jz      .nobase
        mov     bx, ax
        call    pnp_io_free
        jnc     .have_base
        call    pnp_say_busy
        jmp     .cand
.nobase:
        mov     dx, msg_pnp_nobase
        call    print_str
        jmp     .fail
.have_base:
        mov     [g_nic_io], bx
        mov     al, PNP_R_IOBASE_HI
        mov     ah, bh
        call    pnp_write_reg
        mov     al, PNP_R_IOBASE_LO
        mov     ah, bl
        call    pnp_write_reg
        mov     ax, [g_nic_irq]           ; /q= if given, else the default
        or      ax, ax
        jnz     .irq
        mov     ax, PNP_DEF_IRQ
        mov     [g_nic_irq], ax
.irq:
        mov     ah, al
        mov     al, PNP_R_IRQ
        call    pnp_write_reg
        mov     al, PNP_R_DMA
        mov     ah, PNP_DEF_DMA
        call    pnp_write_reg
        mov     al, PNP_R_ACTIVATE
        mov     ah, 1
        call    pnp_write_reg
        mov     cx, PNP_US_READ           ; activation settle (Linux: 250 us)
        call    pnp_delay
        call    pnp_wait_key              ; quiesce: back to Wait-for-Key (the card stays active)
        call    el3_load_mac_io           ; read the MAC via the now-live I/O base
        clc
        ret

; pnp_io_free -- CF=0 if nothing else decodes I/O [BX, BX+0x20), by the ISA PnP I/O range check: with the
; card inactive and base BX programmed, register 0x31 bit1 makes the card answer every read in its range with
; a test pattern (bit0 selects 0x55 or 0xAA) -- another device driving those ports corrupts it. Both
; patterns are checked. (Floating-bus 0xFF reads don't work: a real IBM PC/AT returns bus leftovers from
; empty ports, so every base looked busy.) On a mismatch [pnp_bad] = the value read. The card must be in
; Config with logical device 0 selected. Clobbers AX, CX, DX.
PNP_R_IOCHECK   equ 0x31
pnp_io_free:
        mov     al, PNP_R_IOBASE_HI
        mov     ah, bh
        call    pnp_write_reg
        mov     al, PNP_R_IOBASE_LO
        mov     ah, bl
        call    pnp_write_reg
        mov     al, PNP_R_IOCHECK         ; pattern A
        mov     ah, 0x02
        call    pnp_write_reg
        mov     dx, bx
        in      al, dx
        mov     [pnp_bad], al
        cmp     al, 0x55
        je      .pa
        cmp     al, 0xAA
        jne     .busy                     ; not a range-check pattern: another card (or no range check)
.pa:    mov     ah, al                    ; AH = pattern A (0x55 or 0xAA)
        call    .all
        jc      .busy
        mov     al, PNP_R_IOCHECK         ; pattern B must be the other one
        push    ax
        mov     ah, 0x03
        call    pnp_write_reg
        pop     ax
        not     ah
        call    .all
        jc      .busy
        call    .off
        clc
        ret
.busy:
        call    .off
        stc
        ret
.off:                                     ; range check off
        push    ax
        mov     al, PNP_R_IOCHECK
        xor     ah, ah
        call    pnp_write_reg
        pop     ax
        ret
.all:                                     ; every port of [BX, BX+0x20) must read AH; CF=1 + [pnp_bad] if not
        mov     dx, bx
        mov     cx, 0x20
.a:     in      al, dx
        cmp     al, ah
        jne     .bad
        inc     dx
        loop    .a
        clc
        ret
.bad:   mov     [pnp_bad], al
        stc
        ret

; pnp_say_busy -- "PnP: I/O 0x0300 in use (range check read 0x..)" for base BX. Preserves BX, SI.
pnp_say_busy:
        push    ax
        push    dx
        mov     dx, msg_pnp_busy
        call    print_str
        mov     ax, bx
        call    print_hex16
        mov     dx, msg_pnp_inuse
        call    print_str
        mov     al, [pnp_bad]
        xor     ah, ah
        call    print_hex16
        mov     dx, msg_pnp_inuse2
        call    print_str
        pop     dx
        pop     ax
        ret

; Bases to try, all inside the 3C515's PnP range 0x280-0x3E0 (32-byte aligned), skipping the ones holding
; standard devices (0x2E0 COM4/COM2, 0x360 LPT1, 0x3A0-0x3DF MDA/CGA/VGA, 0x3E0 COM3/floppy), rarely-used
; ones first. The range check only catches a device that out-drives the 3C515 on the bus -- on a real AT an
; XT-IDE at 0x300 passed it (the 3C515 won the contention) -- so the usual homes of XT-IDE, NE2000 clones and
; the MPU-401 (0x330) come last.
pnp_io_cands:
        dw 0x2A0, 0x2C0, 0x340, 0x280, 0x380, 0x300, 0x320, 0

;------------------------------------------------------------------------------
; pnp_rdp_select -- (Linux isapnp_isolate_rdp_select) reset CSNs, re-key, Wake[0], and set the read
; port [pnp_rdp] (advanced past the NE2000 space). CF=1 when no read port is left. Clobbers AX,CX,DX,SI.
;------------------------------------------------------------------------------
pnp_rdp_select:
        call    pnp_wait_key
        call    pnp_send_key
        mov     al, PNP_R_CONFIG           ; Reset-CSN only (NOT the global Reset 0x01)
        mov     ah, PNP_CFG_RESETCSN
        call    pnp_write_reg
        mov     cx, PNP_US_2MS
        call    pnp_delay
        call    pnp_wait_key
        call    pnp_send_key
        mov     al, PNP_R_WAKE             ; CSN-0 cards -> Isolation (Set-RD_DATA is valid only there)
        xor     ah, ah
        call    pnp_write_reg
.adj:
        mov     ax, [pnp_rdp]
        cmp     ax, PNP_RDP_LAST
        ja      .none
        cmp     ax, PNP_RDP_SKIP_LO
        jb      .ok
        cmp     ax, PNP_RDP_SKIP_HI
        ja      .ok
        add     word [pnp_rdp], PNP_RDP_STEP
        jmp     .adj
.ok:
        call    pnp_isolation_setup
        clc
        ret
.none:
        call    pnp_wait_key
        stc
        ret

; pnp_isolation_setup -- Set-RD_DATA = [pnp_rdp], 100 us + 1 ms, select the isolation register, 1 ms.
pnp_isolation_setup:
        mov     ax, [pnp_rdp]
        shr     ax, 1
        shr     ax, 1
        mov     ah, al
        mov     al, PNP_R_SETRDP
        call    pnp_write_reg
        mov     cx, PNP_US_RDP
        call    pnp_delay
        mov     cx, PNP_US_1MS
        call    pnp_delay
        mov     al, PNP_R_ISOLATE
        call    pnp_set_addr
        mov     cx, PNP_US_1MS
        call    pnp_delay
        ret

;------------------------------------------------------------------------------
; pnp_isolate_one -- read one card's 72-bit serial identifier (250 us after every read) and check the
; LFSR checksum (Linux: valid if checksum != 0 and it matches the 9th byte).
; out: CF=0 and pnp_id[0..8] filled if a card isolated; CF=1 if none. clobbers AX,BX,CX,DX,DI.
;------------------------------------------------------------------------------
pnp_isolate_one:
        mov     byte [pnp_lfsr], PNP_LFSR_SEED
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

        mov     al, [pnp_lfsr]
        or      al, al
        jz      .nocard                   ; a zero checksum is never valid (Linux)
        cmp     al, [pnp_id + 8]          ; computed checksum must match the read byte
        jne     .nocard
        clc
        ret
.nocard:
        stc
        ret

; pnp_is_3com -- CF=0 if pnp_id is a 3Com vendor id (compressed EISA "TCM", 0x50 0x6D; either byte
; order accepted). Clobbers AX.
pnp_is_3com:
        mov     al, [pnp_id]
        mov     ah, [pnp_id + 1]
        cmp     ax, 0x6D50                ; bytes 0x50, 0x6D
        je      .yes
        cmp     ax, 0x506D                ; swapped
        je      .yes
        stc
        ret
.yes:
        clc
        ret

; pnp_report_card -- "PnP card TCM5051 CSN=1 read port 0x0213" for the card just isolated.
; The EISA id: bytes 0-1 (big-endian) pack 3 letters as 5-bit fields ('A' = 1), bytes 2-3 the product.
pnp_report_card:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dx, msg_pnp_card
        call    print_str
        mov     bh, [pnp_id]
        mov     bl, [pnp_id + 1]          ; BX = vendor, big-endian
        mov     ax, bx
        mov     cl, 10
        shr     ax, cl
        call    .letter
        mov     ax, bx
        mov     cl, 5
        shr     ax, cl
        call    .letter
        mov     ax, bx
        call    .letter
        mov     al, [pnp_id + 2]
        call    .hex2
        mov     al, [pnp_id + 3]
        call    .hex2
        mov     dx, msg_pnp_csn
        call    print_str
        mov     al, [pnp_csn]
        add     al, '0'
        call    print_char
        mov     dx, msg_pnp_rdp
        call    print_str
        mov     ax, [pnp_rdp]
        call    print_hex16
        mov     dx, msg_crlf
        call    print_str
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
.letter:
        and     al, 0x1F
        add     al, '@'
        call    print_char
        ret
.hex2:
        push    ax
        mov     cl, 4
        shr     al, cl
        call    .nib
        pop     ax
.nib:
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .pc
        add     al, 7
.pc:
        call    print_char
        ret

;------------------------------------------------------------------------------
; low-level ISA PnP port helpers
;------------------------------------------------------------------------------
; pnp_delay -- CX x ~1 us (one ISA read of port 0x80 each, CPU-speed independent). Preserves AX.
pnp_delay:
        push    ax
.d:     in      al, 0x80
        loop    .d
        pop     ax
        ret

pnp_wait_key:                            ; all cards -> Wait-for-Key. Clobbers AX, CX.
        mov     al, PNP_R_CONFIG
        mov     ah, PNP_CFG_WAITKEY
        call    pnp_write_reg
        ret

pnp_send_key:                            ; 1 ms, reset the key LFSR (two 0 writes), 32 key bytes
        push    si
        mov     cx, PNP_US_1MS
        call    pnp_delay
        xor     al, al
        call    pnp_set_addr
        xor     al, al
        call    pnp_set_addr
        mov     si, pnp_key
        mov     cx, 32
.k:     lodsb                            ; DS:SI -> key (DS = DGROUP)
        push    cx
        call    pnp_set_addr
        pop     cx
        loop    .k
        pop     si
        ret

pnp_write_reg:                           ; AL=register, AH=data. Clobbers CX.
        push    dx
        push    ax
        call    pnp_set_addr
        pop     ax
        mov     dx, PNP_WRITE
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        pop     dx
        ret

pnp_set_addr:                            ; AL=register; 20 us after the write (Linux). Clobbers CX.
        push    dx
        mov     dx, PNP_ADDR
        out     dx, al
        mov     cx, PNP_US_ADDR
        call    pnp_delay
        pop     dx
        ret

pnp_read_reg:                            ; AL=register -> AL=value. Clobbers CX.
        call    pnp_set_addr
        push    dx
        mov     dx, [pnp_rdp]
        in      al, dx
        pop     dx
        ret

pnp_read_data:                           ; one isolation read from [pnp_rdp], then 250 us. -> AL.
        push    dx                       ; Preserves CX, DH (the caller keeps data1 in DH).
        push    cx
        mov     dx, [pnp_rdp]
        in      al, dx
        mov     cx, PNP_US_READ
        call    pnp_delay
        pop     cx
        pop     dx
        ret
