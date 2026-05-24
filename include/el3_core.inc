; el3_core.inc -- EtherLink III SHARED register core (NASM).
;
; The EtherLink III family is a lineage: one windowed register model (command/status at
; 0x0E, eight selectable windows, common command/status bits) shared by every generation,
; plus per-generation deltas. This file is the shared core; each generation gets its own
; header named after 3Com's internal codename, %including this one and adding its delta:
;
;   el3_tomahawk.inc   3C509   EtherLink III ISA        (PIO floor)
;   el3_corkscrew.inc  3C515   Fast EtherLink ISA       (+ Window 7 bus-master ring)
;   el3_vortex.inc     3C59x   EtherLink III PCI        (PIO, permanent window 1)
;   el3_boomerang.inc  3C90x   EtherLink XL             (+ descriptor-ring DMA)
;   el3_cyclone.inc    3C905B  Fast EtherLink XL        (+ HW checksum, NWAY)
;   el3_tornado.inc    3C905C  Fast EtherLink XL        (+ scatter-gather, WoL)
;
; See docs/03-hal-vtable.md (shared core + generational deltas).

%ifndef EL3_CORE_INC
%define EL3_CORE_INC

; ---- shared identity ----
EL3_MFG_ID              equ 0x6D50   ; 3Com manufacturer id (EEPROM word 7), all generations

; ---- frame sizing ----
EL3_MAX_FRAME           equ 1514
EL3_MIN_FRAME           equ 60

; ---- command / status register (accessible in all windows, offset 0x0E) ----
EL3_CMD                 equ 0x0E
EL3_STATUS              equ 0x0E

; ---- register windows ----
EL3_W0_SETUP            equ 0
EL3_W1_OPERATING        equ 1
EL3_W2_STATION_ADDR     equ 2
EL3_W3_CONFIG           equ 3
EL3_W4_MEDIA            equ 4
EL3_W6_STATS            equ 6
EL3_W7_BUSMASTER        equ 7

; ---- commands (high 5 bits select; OR low bits as param) ----
EL3_CMD_GLOBAL_RESET    equ 0x0000
EL3_CMD_SELECT_WINDOW   equ 0x0800
EL3_CMD_RX_ENABLE       equ 0x2000
EL3_CMD_RX_RESET        equ 0x2800
EL3_CMD_RX_DISCARD      equ 0x4000
EL3_CMD_TX_ENABLE       equ 0x4800
EL3_CMD_TX_RESET        equ 0x5800
EL3_CMD_ACK_INTR        equ 0x6800
EL3_CMD_SET_INTR_ENB    equ 0x7000
EL3_CMD_SET_STATUS_ENB  equ 0x7800   ; which status bits are visible in the status register
EL3_CMD_SET_RX_FILTER   equ 0x8000
EL3_CMD_SET_TX_START    equ 0x9800   ; OR with the TX start threshold (bytes)

; TX start threshold: bytes that must be queued before the card begins transmitting. Lower
; = more overlap of the wire transmit with the CPU's PIO fill, but more underrun risk on a
; slow CPU (recovered below, and counted). Tunable; a conservative default for the floor.
EL3_TX_START_THRESH     equ 512      ; early-start (overlap, low latency) -- 3C509/B @ 10 Mbit
; Store-and-forward: a threshold above the max frame so the card never early-starts -- it
; transmits only once the whole frame is buffered, with the CPU already done, so underrun is
; impossible at ANY link speed. Mandatory where the wire can out-drain PIO fill (e.g. a 3C515
; at 100 Mbit: ~12.5 MB/s wire vs ~2-4 MB/s ISA PIO). The 8 KB 3C515 FIFO is sized for this.
EL3_TX_THRESH_SF        equ 1536

; Window-1 register relocation across the lineage. On the 3C509/B the FIFO/status/free block
; is window-relative at +0x00; the Vortex generation (3C515 "Corkscrew" onward) moved it to a
; window-INDEPENDENT bank at +0x10 (which is also why the I/O extent grew 16 -> 32). The
; command/status register (0x0E) and the windowed config registers (Window 0/2/4) are
; unchanged. Applied per detected generation: g_w1_base = io_base + this delta.
EL3_W1_DELTA_3C509      equ 0x00
EL3_W1_DELTA_VORTEX     equ 0x10

; TX status (W1_TX_STATUS, a byte popped off a small stack)
EL3_TXS_COMPLETE        equ 0x80     ; a TX status entry is present
EL3_TXS_RESET_MASK      equ 0x30     ; underrun (0x10) | jabber (0x20) -> needs TxReset

; ---- status bits ----
EL3_ST_INT_LATCH        equ 0x0001
EL3_ST_ADAPTER_FAILURE  equ 0x0002   ; RX engine wedged -> needs RX_RESET (ISR self-heals)
EL3_ST_TX_COMPLETE      equ 0x0004
EL3_ST_RX_COMPLETE      equ 0x0010
EL3_ST_CMD_BUSY         equ 0x1000

; ---- Window 1: operating (TX/RX FIFO + status) ----
EL3_W1_TX_FIFO          equ 0x00
EL3_W1_RX_FIFO          equ 0x00
EL3_W1_RX_STATUS        equ 0x08
EL3_W1_TX_STATUS        equ 0x0B
EL3_W1_TX_FREE          equ 0x0C
; Vortex/Corkscrew only: a dedicated RX error-cause register, W1-base-relative +0x04 (= the
; 3C515's io+0x14). The 3C509 has no such register -- its error code is in RxStatus bits 11-13.
EL3_W1_RX_ERRORS        equ 0x04

EL3_RX_INCOMPLETE       equ 0x8000
EL3_RX_ERROR            equ 0x4000
; RX length field: 11-bit on the 3C509, 13-bit (0x1FFF) on the 3C515. 0x07FF is correct for
; both with standard Ethernet (max 1514 < 2047); the wider 13-bit field exists for FDDI-sized
; large packets -- a hardware feature enabled via allowLargePackets in MacControl on the PCI/EISA
; bus-master parts (<=4494 B; 3C515 unverified), which this driver deliberately does NOT enable
; (Ethernet-only, like Linux 3c59x). So one mask serves both.
EL3_RX_LEN_MASK         equ 0x07FF
; 3C515 RxErrors register bits (read as a byte from EL3_W1_RX_ERRORS):
EL3_RXERR_OVERRUN       equ 0x01
EL3_RXERR_LENGTH        equ 0x02
EL3_RXERR_FRAME         equ 0x04
EL3_RXERR_CRC           equ 0x08
EL3_RXERR_DRIBBLE       equ 0x10

EL3_RXF_STATION         equ 0x01
EL3_RXF_BROADCAST       equ 0x04

; ---- Window 2: station address (6 byte registers at offsets 0..5) ----
EL3_W2_STATION_REG      equ 0x00

; ---- Window 4: media / transceiver ----
EL3_W4_MEDIA_STATUS     equ 0x0A     ; media type/status register
EL3_MEDIA_LBEAT_ENABLE  equ 0x0080   ; enable 10BaseT link beat
EL3_MEDIA_JABBER_ENABLE equ 0x0040   ; enable 10BaseT jabber guard

; ---- EEPROM (shared word layout + read opcode) ----
EL3_EE_READ             equ 0x80     ; OR with word addr to issue a read
; EEPROM access through a card already at a fixed I/O base (Window 0) -- used after a PnP
; card is activated, where the ID-port read path no longer applies. Write (0x80|addr) to the
; command register, poll the busy bit clear, then read the 16-bit word from the data register.
EL3_W0_EE_CMD           equ 0x0A     ; Window 0 EEPROM command register (3C509)
EL3_W0_EE_DATA          equ 0x0C     ; Window 0 EEPROM data register (3C509)
EL3_EE_BUSY             equ 0x8000   ; command register busy bit (clear when read done)
; The 3C515 (Corkscrew) relocated the Window-0 EEPROM to the +0x2000 ISA alias (cmd at
; io+0x200A, data = cmd+2). Verified against the Linux 3c515 driver + iPXE. (We poll a fixed
; io_delay rather than the busy bit, so the differing busy-bit position doesn't matter.)
EL3_CS_W0_EE_CMD        equ 0x200A   ; 3C515 EEPROM command register (data at +2 = 0x200C)
EL3_EE_ADDR0            equ 0        ; station address words 0..2 (big-endian)
EL3_EE_ADDR1            equ 1
EL3_EE_ADDR2            equ 2
EL3_EE_PROD_ID          equ 3
EL3_EE_MFG_ID           equ 7
EL3_EE_ADDR_CFG         equ 8        ; io base: 0x200 + ((w & 0x1F) << 4)
EL3_EE_RESOURCE_CFG     equ 9        ; irq in bits 15..12

%endif ; EL3_CORE_INC
