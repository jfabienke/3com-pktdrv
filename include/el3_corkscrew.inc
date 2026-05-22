; el3_corkscrew.inc -- 3C515 "Corkscrew" Fast EtherLink ISA delta (3Com codename).
;
; Second generation in the EL3 lineage: 16-bit ISA, 10/100, ISA Plug-and-Play. It keeps the
; shared windowed register core (command/status at 0x0E, the same windows and commands), so
; in PIO mode its operational bring-up is the 3C509's (Window 2 MAC, Window 4 media, Window 1
; FIFO datapath). The deltas are: it is a PnP-era card (no legacy ID-port contention -- found
; via ISA PnP isolation, see isapnp.asm), a 32-byte I/O extent, and a bus-master DMA engine
; at base+0x400 that PIO mode ignores entirely.
;
; PIO mode is a deliberate stepping stone: get the card detected, configured, and moving
; frames over the shared Window-1 FIFO path first; the bus-master ring datapath (and all the
; VDS / cache-coherency / 386+ machinery it needs) is a later milestone.
;
; Identity values from the 3Com driver references (~/Development/3com-packet-driver); the
; bus-master register map is documented for the future DMA milestone, not used here.

%ifndef EL3_CORKSCREW_INC
%define EL3_CORKSCREW_INC

%include "el3_core.inc"

; ---- identity ----
; The 3C515 is detected via ISA PnP, so identity comes from the PnP serial id, not the legacy
; EEPROM product-id path. 3Com's compressed EISA vendor id is 0x6D50 ("TCM") -- the shared
; EL3_MFG_ID, the same field that flags any card in the lineage as ours. The device portion
; selects the variant within the family.
EL3_PNP_VENDOR_3COM     equ EL3_MFG_ID   ; 0x6D50 -- 3Com ("TCM"), shared across the lineage

; Corkscrew PnP device ids (low word of the EISA product id; family TCM50xx):
EL3_PNP_DEV_3C515TX     equ 0x5050   ; TCM5050  3c515-TX
EL3_PNP_DEV_3C515FX     equ 0x5051   ; TCM5051  3c515-FX
EL3_PNP_DEV_3C515TXP    equ 0x5052   ; TCM5052  3c515-TX+
EL3_PNP_DEV_3C515TXEU   equ 0x5053   ; TCM5053  3c515-TX (EU)

EL3_IO_EXTENT_CORKSCREW equ 32       ; I/O port range per NIC (vs 16 on the 3C509)

; ---- bus-master DMA register block (base+0x400) -- RESERVED for the bus-master milestone.
; Untouched in PIO mode; listed so the future ring datapath has the map in one place.
EL3_CS_DMA_BASE         equ 0x400    ; DMA register window offset from io_base
EL3_CS_DOWN_LIST_PTR    equ 0x404    ; TX descriptor list pointer
EL3_CS_UP_LIST_PTR      equ 0x418    ; RX descriptor list pointer

; ---- Window 3 MAC control (Corkscrew has it; PIO floor leaves duplex at default) ----
EL3_CS_W3_MAC_CTRL      equ 0x06     ; Window 3 MAC control register
EL3_CS_FULL_DUPLEX      equ 0x20     ; set = full duplex (optional; not set by the PIO floor)

%endif ; EL3_CORKSCREW_INC
