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

        ; NOTE: SET_INTR_ENB is deferred to install (no ISR wired yet).
        ret
