; el3_init.asm -- EtherLink III operational bring-up (COLD; %included by start.asm).
;
; After the probe activates the card at g_nic_io, program it to the operational state:
; station MAC -> Window 2, 10BaseT media enable -> Window 4, RX filter + RX/TX enable ->
; Window 1. Lifted from the extracted 3C509B Phase-4 I/O sequence
; (~/Development/3com-packet-driver/.../initialization_sequences.md) and cross-checked
; against the Nestor 8086 driver (set_address_4 / operational enable).
;
; Mostly shared EL3 core behaviour; the media step is the transceiver-specific part (floor
; assumes 10BaseT -- BNC/AUI selection from the EEPROM XCVR bits is a later refinement).
;
; The interrupt MASK is deliberately left disabled here: the ISR is not wired until the
; install milestone, and enabling RX_COMPLETE now would assert an unhandled IRQ. Leaves the
; card in Window 1, which is what the emitted PIO datapath assumes.

el3_init:
        mov     bx, [g_nic_io]              ; BX = I/O base (kept)
        mov     dx, bx
        add     dx, EL3_CMD                 ; DX = command/status register

        ; --- station address: Window 2, write the 6 MAC bytes (offsets 0..5) ---
        mov     ax, EL3_CMD_SELECT_WINDOW | EL3_W2_STATION_ADDR
        out     dx, ax
        push    dx
        mov     dx, bx                      ; DX = io_base + station reg 0
        mov     si, g_mac
        mov     cx, 6
.macw:
        lodsb
        out     dx, al
        inc     dx
        loop    .macw
        pop     dx                          ; DX = command register again

        ; --- media: Window 4, enable 10BaseT link beat + jabber guard ---
        mov     ax, EL3_CMD_SELECT_WINDOW | EL3_W4_MEDIA
        out     dx, ax
        push    dx
        mov     dx, bx
        add     dx, EL3_W4_MEDIA_STATUS
        in      ax, dx
        or      ax, EL3_MEDIA_LBEAT_ENABLE | EL3_MEDIA_JABBER_ENABLE
        out     dx, ax
        pop     dx

        ; --- large frames: set allowLargePackets in MacControl (Window 3, off 6, bit 6) so the MAC
        ;     accepts FDDI-sized (<=4490 B excl FCS) RX instead of flagging oversize at 1518.
        ;     3C515 only (gated in build_plan); MacControl is cleared on reset, so write just the bit.
        cmp     byte [g_use_large], 0
        je      .no_large
        mov     ax, EL3_CMD_SELECT_WINDOW | 3        ; Window 3 (MAC control)
        out     dx, ax
        push    dx
        mov     dx, bx
        add     dx, EL3_CS_W3_MAC_CTRL               ; io_base + 0x06 = MacControl
        mov     ax, EL3_MAC_CTRL_ALLOW_LARGE         ; bit 6 = allowLargePackets
        out     dx, ax
        pop     dx
.no_large:

        ; --- operating: Window 1 (where the PIO datapath runs) ---
        mov     ax, EL3_CMD_SELECT_WINDOW | EL3_W1_OPERATING
        out     dx, ax

        ; accept frames addressed to our station + broadcast
        mov     ax, EL3_CMD_SET_RX_FILTER | EL3_RXF_STATION | EL3_RXF_BROADCAST
        out     dx, ax

        ; clear any latched interrupts
        mov     ax, EL3_CMD_ACK_INTR | 0x07FF
        out     dx, ax

        ; enable receiver and transmitter
        mov     ax, EL3_CMD_RX_ENABLE
        out     dx, ax
        mov     ax, EL3_CMD_TX_ENABLE
        out     dx, ax

        ; TX start threshold (precomputed per generation in build_plan): 3C509/B early-start
        ; for overlap/latency; 3C515 store-and-forward (the wire can out-drain PIO fill).
        mov     ax, [g_tx_start]
        out     dx, ax

        ; NOTE: SET_INTR_ENB is deferred to install (no ISR wired yet).
        ret

;------------------------------------------------------------------------------
; el3_load_mac_io -- read the station MAC (EEPROM words 0..2, big-endian) into g_mac through
; the Window 0 EEPROM interface of a card already activated at g_nic_io. The 3C509 ID-port
; path reads the MAC during contention; the PnP path has no ID port, so it reads here after
; activation, before el3_init writes it back to Window 2.
;
; Generation-aware: the 3C515 (Corkscrew) relocated the EEPROM registers to the +0x2000 ISA
; alias (cmd io+0x200A, data +2), vs the 3C509's io+0x0A/0x0C (Linux 3c515 + iPXE). A fixed
; io_delay (~300 us > the 162 us read latency) covers both, sidestepping the differing busy
; bit. Cold. Clobbers AX, BX, CX, DX, SI, DI, BP.
;------------------------------------------------------------------------------
el3_load_mac_io:
        mov     bx, [g_nic_io]
        mov     dx, bx
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SELECT_WINDOW | EL3_W0_SETUP
        out     dx, ax
        mov     bp, EL3_W0_EE_CMD          ; 3C509: EEPROM cmd at io+0x0A
        cmp     byte [g_nic_gen], 0
        je      .eeoff
        mov     bp, EL3_CS_W0_EE_CMD       ; 3C515: io+0x200A (the +0x2000 ISA alias)
.eeoff:
        xor     di, di                     ; EEPROM word index 0..2
        xor     si, si                     ; byte offset into g_mac
.macw:
        mov     dx, bx
        add     dx, bp                     ; EEPROM command register
        mov     ax, di
        or      ax, EL3_EE_READ            ; 0x80 | word addr -> issue read
        out     dx, ax
        call    io_delay                   ; fixed wait > 162 us EEPROM read latency
        mov     dx, bx
        add     dx, bp
        add     dx, 2                      ; data register = command + 2
        in      ax, dx                     ; AX = word (AH = first MAC byte, big-endian)
        mov     [g_mac + si], ah
        mov     [g_mac + si + 1], al
        add     si, 2
        inc     di
        cmp     di, 3
        jb      .macw
        ret
