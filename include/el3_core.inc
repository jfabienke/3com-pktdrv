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
EL3_CMD_SET_RX_FILTER   equ 0x8000

; ---- status bits ----
EL3_ST_INT_LATCH        equ 0x0001
EL3_ST_TX_COMPLETE      equ 0x0004
EL3_ST_RX_COMPLETE      equ 0x0010
EL3_ST_CMD_BUSY         equ 0x1000

; ---- Window 1: operating (TX/RX FIFO + status) ----
EL3_W1_TX_FIFO          equ 0x00
EL3_W1_RX_FIFO          equ 0x00
EL3_W1_RX_STATUS        equ 0x08
EL3_W1_TX_STATUS        equ 0x0B
EL3_W1_TX_FREE          equ 0x0C

EL3_RX_INCOMPLETE       equ 0x8000
EL3_RX_ERROR            equ 0x4000
EL3_RX_LEN_MASK         equ 0x07FF

EL3_RXF_STATION         equ 0x01
EL3_RXF_BROADCAST       equ 0x04

; ---- EEPROM (shared word layout + read opcode) ----
EL3_EE_READ             equ 0x80     ; OR with word addr to issue a read
EL3_EE_ADDR0            equ 0        ; station address words 0..2 (big-endian)
EL3_EE_ADDR1            equ 1
EL3_EE_ADDR2            equ 2
EL3_EE_PROD_ID          equ 3
EL3_EE_MFG_ID           equ 7
EL3_EE_ADDR_CFG         equ 8        ; io base: 0x200 + ((w & 0x1F) << 4)
EL3_EE_RESOURCE_CFG     equ 9        ; irq in bits 15..12

%endif ; EL3_CORE_INC
