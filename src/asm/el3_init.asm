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
; activation, before el3_init writes it back to Window 2. Clobbers AX, BX, CX, DX, SI, DI.
;------------------------------------------------------------------------------
el3_load_mac_io:
        mov     bx, [g_nic_io]
        mov     dx, bx
        add     dx, EL3_CMD
        mov     ax, EL3_CMD_SELECT_WINDOW | EL3_W0_SETUP
        out     dx, ax
        xor     di, di                     ; EEPROM word index 0..2
        xor     si, si                     ; byte offset into g_mac
.macw:
        mov     dx, bx
        add     dx, EL3_W0_EE_CMD
        mov     ax, di
        or      ax, EL3_EE_READ            ; 0x80 | word addr -> issue read
        out     dx, ax
        mov     cx, 0                       ; bounded busy poll (~65536 spins)
.busy:
        in      ax, dx
        test    ax, EL3_EE_BUSY
        jz      .ready
        loop    .busy
.ready:
        mov     dx, bx
        add     dx, EL3_W0_EE_DATA
        in      ax, dx                     ; AX = word (AH = first MAC byte, big-endian)
        mov     [g_mac + si], ah
        mov     [g_mac + si + 1], al
        add     si, 2
        inc     di
        cmp     di, 3
        jb      .macw
        ret
